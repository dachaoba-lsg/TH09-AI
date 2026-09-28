"""Execute guarded upstream x86 Lua entry points in isolated Unicorn memory.

No DLL entry point, game process, or real process injection is executed. The
actual upstream function, relocations, prologue and guarded trampoline execute;
only Lua input access, the monitor's replay query, and two Win32 APIs are mocks.
"""
from __future__ import annotations

import argparse
import hashlib
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "work/input-fix/python"))
import pefile
from unicorn import Uc, UC_ARCH_X86, UC_MODE_32, UC_HOOK_CODE
from unicorn.x86_const import *

ORIGINAL_SHA = "2ba67f1f80ebe53f978dc6843777764b5ead911a688c89c9cd68cc8c2d9cae00"
GUARD_SHA = "3f7499b450787ebd603fba73f31528cb852d16cd430a6395f5c38759cedef376"
DATA, STACK, APIS = 0x20000000, 0x60000000, 0x70000000
RAW, MONITOR, VTABLE = DATA + 0x1000, DATA + 0x100, DATA + 0x200
GET_MODULE, GET_PROC, AUTH, REPLAY, END = [APIS + i * 0x100 for i in range(1, 6)]
checks = cases = 0


def check(condition, message):
    global checks
    checks += 1
    if not condition:
        raise AssertionError(message)


def put32(buf, offset, value):
    struct.pack_into("<I", buf, offset, value & 0xFFFFFFFF)


def validate_builder(builder, original, guarded):
    check(hashlib.sha256(original).hexdigest() == ORIGINAL_SHA, "upstream SHA")
    check(hashlib.sha256(guarded).hexdigest() == GUARD_SHA, "canonical guarded SHA")
    with tempfile.TemporaryDirectory(prefix="th09-inject-guard-") as directory:
        directory = Path(directory)
        source, target = directory / "input.dll", directory / "output.dll"
        for contents in (original, guarded):
            source.write_bytes(contents)
            result = subprocess.run([str(builder), str(source), str(target)], capture_output=True)
            check(result.returncode == 0, "builder accepts exact pinned input")
            check(target.read_bytes() == guarded, "builder produces canonical bytes")
        result = subprocess.run([str(builder), str(target), str(target)], capture_output=True)
        check(result.returncode == 0 and target.read_bytes() == guarded, "guarded in-place validation")
        source.write_bytes(original)
        result = subprocess.run([str(builder), str(source), str(source)], capture_output=True)
        check(result.returncode != 0 and source.read_bytes() == original, "upstream never rewritten in place")
        # Every class of changed byte is checked: old headers, body, patched
        # entry, new section header, guard code, strings, and raw padding.
        for offset in (0, 0x104, 0x138, 0x2A8, 0x2A8 + 39, 0x1CDB0, 0x1CDB5,
                       0x8000, 443392, 443420, 443480, 443540, len(guarded) - 1):
            damaged = bytearray(guarded)
            damaged[offset] ^= 1
            source.write_bytes(damaged)
            target.write_bytes(b"untouched")
            result = subprocess.run([str(builder), str(source), str(target)], capture_output=True)
            check(result.returncode != 0, f"reject changed byte {offset:x}")
            check(target.read_bytes() == b"untouched", "failed validation cannot overwrite target")
        for damaged in (original[:-1], guarded[:-1], guarded + b"x"):
            source.write_bytes(damaged)
            result = subprocess.run([str(builder), str(source), str(target)], capture_output=True)
            check(result.returncode != 0, "reject unexpected size")


def validate_pe(original, guarded):
    old, new = pefile.PE(data=original), pefile.PE(data=guarded)
    check(len(new.sections) == len(old.sections) + 1, "one new section")
    check(new.sections[-1].Name == b".aiguard", "named guard section")
    check(new.sections[-1].Characteristics == 0x60000020, "RX, not writable, guard section")
    check(new.OPTIONAL_HEADER.AddressOfEntryPoint == old.OPTIONAL_HEADER.AddressOfEntryPoint, "DllMain untouched")
    for before, after in zip(old.sections, new.sections):
        check(before.get_data() == after.get_data() or before.Name.startswith(b".text"), "original section data")
        check(before.__pack__() == after.__pack__(), "original section layout")
    for olddir, newdir in zip(old.OPTIONAL_HEADER.DATA_DIRECTORY, new.OPTIONAL_HEADER.DATA_DIRECTORY):
        check(olddir.VirtualAddress == newdir.VirtualAddress and olddir.Size == newdir.Size, "data directory unchanged")
    modified = [i for i, (a, b) in enumerate(zip(original, guarded)) if a != b]
    permitted = set(range(0xEE, 0xF0)) | set(range(0x104, 0x108)) | set(range(0x138, 0x13C))
    permitted |= set(range(0x2A8, 0x2D0)) | set(range(0x1CDB0, 0x1CDB6))
    check(set(modified) <= permitted, "only explicit headers and six entry bytes changed")
    imports = {item.name: item.address - new.OPTIONAL_HEADER.ImageBase
               for desc in new.DIRECTORY_ENTRY_IMPORT for item in desc.imports if item.name}
    check(imports[b"GetModuleHandleW"] == 0x4C0C4, "exact existing module IAT")
    check(imports[b"GetProcAddress"] == 0x4C018, "exact existing proc IAT")
    check(not any(0x1D9B0 <= entry.rva < 0x1D9B6 for block in new.DIRECTORY_ENTRY_BASERELOC
                  for entry in block.entries), "replaced instructions have no relocations")


class Runner:
    def __init__(self, guarded, base):
        self.base = base
        image = pefile.PE(data=guarded)
        image.relocate_image(base)
        self.cpu = Uc(UC_ARCH_X86, UC_MODE_32)
        self.cpu.mem_map(base, 0x73000)
        self.cpu.mem_write(base, image.get_memory_mapped_image())
        for address, size in ((DATA, 0x10000), (STACK, 0x10000), (APIS, 0x10000)):
            self.cpu.mem_map(address, size)
        # Simulated Win32 routines preserve the real stdcall stack contract.
        for address, code in ((GET_MODULE, b"\xc2\x04\x00"), (GET_PROC, b"\xc2\x08\x00"),
                              (AUTH, b"\xc3"), (REPLAY, b"\x31\xc0\xc3")):
            self.cpu.mem_write(address, code)
        self.cpu.mem_write(base + 0x4C0C4, struct.pack("<I", GET_MODULE))
        self.cpu.mem_write(base + 0x4C018, struct.pack("<I", GET_PROC))
        self.cpu.mem_write(base + 0x6B5BC, struct.pack("<I", MONITOR))
        self.cpu.mem_write(MONITOR, struct.pack("<III", VTABLE, 0, RAW))
        self.cpu.mem_write(VTABLE + 16, struct.pack("<I", REPLAY))
        self.cpu.mem_write(base + 0x1450, b"\xb8\x01\x00\x00\x00\xc3")
        self.cpu.mem_write(base + 0x1540, b"\xdd\x05" + struct.pack("<I", DATA + 0x20) + b"\xc3")
        self.scenario = 0
        self.calls = []
        self.cpu.hook_add(UC_HOOK_CODE, self.hook)

    def hook(self, cpu, address, size, unused):
        esp = cpu.reg_read(UC_X86_REG_ESP)
        if address == GET_MODULE:
            arg = struct.unpack("<I", cpu.mem_read(esp + 4, 4))[0]
            check(bytes(cpu.mem_read(arg, 38)) == "window_support.dll\0".encode("utf-16le"), "module name exact")
            cpu.reg_write(UC_X86_REG_EAX, 0 if self.scenario == 0 else 0xCAFE)
            self.calls.append("module")
        elif address == GET_PROC:
            module, name = struct.unpack("<II", cpu.mem_read(esp + 4, 8))
            check(module == 0xCAFE, "module result passed to lookup")
            check(bytes(cpu.mem_read(name, 25)) == b"Th09NativeSideAuthorized\0", "read-only export name exact")
            cpu.reg_write(UC_X86_REG_EAX, 0 if self.scenario == 1 else AUTH)
            self.calls.append("proc")
        elif address == AUTH:
            value = {2: 0, 3: 1, 4: 0xFFFFFFFF, 5: 2}[self.scenario]
            cpu.reg_write(UC_X86_REG_EAX, value)
            self.calls.append("auth")
        elif address in (self.base + 0x1450, self.base + 0x1540):
            self.calls.append("lua")
        elif address == self.base + 0x1D9B6:
            # The exact original six-byte prologue ran after state restore.
            check(cpu.reg_read(UC_X86_REG_EAX) == 0x11223344, "EAX restored before original continuation")
            check(cpu.reg_read(UC_X86_REG_ECX) == 0x22334455, "ECX restored before original continuation")
            check(cpu.reg_read(UC_X86_REG_EDX) == 0x33445566, "EDX restored before original continuation")
            check(cpu.reg_read(UC_X86_REG_EBP) == STACK + 0xFFF0 - 4, "original frame pointer")
            check(cpu.reg_read(UC_X86_REG_ESP) == STACK + 0xFFF0 - 12, "original frame allocation")

    def run(self, scenario, side, exclusive, mask, previous):
        global cases
        self.scenario, self.calls = scenario, []
        cpu, base = self.cpu, self.base
        cpu.mem_write(base + 0x1DA0E, b"\x66\x89\x70\x2c" if exclusive and side == 0 else b"\x66\x09\x70\x2c")
        cpu.mem_write(base + 0x1DAAE, b"\x66\x89\xb0\xba\x00\x00\x00" if exclusive and side == 1 else b"\x66\x09\xb0\xba\x00\x00\x00")
        # Code mutation requires explicit translation-cache invalidation.
        cpu.ctl_remove_cache(base + 0x1D9B0, base + 0x1DB00)
        before = bytearray(b"\xa5" * (3 * 0x8E))
        struct.pack_into("<HH", before, side * 0x8E + 0x2C, 0xA5A5, previous)
        cpu.mem_write(RAW, bytes(before))
        cpu.mem_write(DATA + 0x20, struct.pack("<d", mask | 0x8000))
        registers = ((UC_X86_REG_EAX, 0x11223344), (UC_X86_REG_ECX, 0x22334455),
                     (UC_X86_REG_EDX, 0x33445566), (UC_X86_REG_EBX, 0x44556677),
                     (UC_X86_REG_ESI, 0x55667788), (UC_X86_REG_EDI, 0x66778899),
                     (UC_X86_REG_EBP, 0x778899AA))
        for register, value in registers:
            cpu.reg_write(register, value)
        cpu.reg_write(UC_X86_REG_EFLAGS, 0x202)
        cpu.reg_write(UC_X86_REG_ESP, STACK + 0xFFF0)
        cpu.mem_write(STACK + 0xFFF0, struct.pack("<II", END, DATA + 0x20))
        cpu.emu_start(base + (0x1D9B0 if side == 0 else 0x1DA50), END, count=200)
        allowed = side == 1 or scenario == 3
        check(cpu.reg_read(UC_X86_REG_EIP) == END, "normal cdecl return")
        check(cpu.reg_read(UC_X86_REG_ESP) == STACK + 0xFFF4, "stack balanced")
        check(cpu.reg_read(UC_X86_REG_EAX) == 0, "Lua returns zero results")
        for register, value in registers[3:]:
            check(cpu.reg_read(register) == value, "callee-saved register preserved")
        expected = before[:]
        if allowed:
            desired = mask & 0xF7
            if not exclusive:
                desired |= 0xA5A5
            delta = desired ^ previous
            offset = side * 0x8E
            struct.pack_into("<H", expected, offset + 0x2C, desired)
            struct.pack_into("<HH", expected, offset + 0x32, delta & desired, delta & ~desired)
        check(bytes(cpu.mem_read(RAW, len(before))) == bytes(expected), "exact key and edge writes; other sides untouched")
        check(self.calls.count("lua") == (2 if allowed else 0), "unauthorized return precedes Lua and monitor access")
        if side == 1:
            check(self.calls == ["lua", "lua"], "2P has no authorization lookup")
        cases += 1


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--guarded", type=Path, default=ROOT / "work/native-tests/inject-guarded.dll")
    parser.add_argument("--builder", type=Path, default=ROOT / "work/native-tests/inject_guard_builder.exe")
    args = parser.parse_args()
    original = (ROOT / "vendor/release/ka_ai_duka/inject.dll").read_bytes()
    guarded = args.guarded.read_bytes()
    validate_builder(args.builder, original, guarded)
    validate_pe(original, guarded)
    for base in (0x10000000, 0x31000000, 0x52000000):
        runner = Runner(guarded, base)
        for scenario in range(6):
            for mask in range(256):
                for previous in (0, 0xFF):
                    runner.run(scenario, 0, True, mask, previous)
        for side in (0, 1):
            for exclusive in (False, True):
                for mask in range(256):
                    for previous in (0, 1, 2, 0x7F, 0xFF, 0xFFFF):
                        runner.run(3 if side == 0 else 0, side, exclusive, mask, previous)
        print(f"PASS relocated base 0x{base:08x}: cumulative {cases} actual x86 calls", flush=True)
    print(f"PASS: {checks} checks; {cases} actual x86 calls; canonical generation, tamper rejection, "
          "missing/denied authorization, exact-1 acceptance, real key writes, registers, stack and relocation.")


if __name__ == "__main__":
    main()
