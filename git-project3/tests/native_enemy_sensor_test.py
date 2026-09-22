"""Real upstream SetEnemyFields / injected bridge, in isolated x86 Unicorn.

Never loads inject.dll into Windows or opens/starts the game. The actual
compiler-fastcall routine exports its scalar fields and nested tables using
mock Lua C APIs. Getter/shared_ptr lifetime plumbing and hit-body virtual
getters are mocked; those are not changed by this patch. The compiled C
snapshot reader + actual table writer + native bridge run in the companion
enemy_sensor_selftest.exe. Requires pefile + unicorn (work/input-fix/python
or `pip install pefile unicorn`).
"""
import argparse
import hashlib
from pathlib import Path
import struct
import subprocess
import sys

PROJECT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT / "work/input-fix/python"))
import pefile
from unicorn import Uc, UC_ARCH_X86, UC_MODE_32, UC_HOOK_CODE
from unicorn.x86_const import (
    UC_X86_REG_EAX, UC_X86_REG_EBX, UC_X86_REG_ECX, UC_X86_REG_EDX,
    UC_X86_REG_ESI, UC_X86_REG_EDI, UC_X86_REG_EBP, UC_X86_REG_ESP,
    UC_X86_REG_EFLAGS, UC_X86_REG_EIP, UC_X86_REG_XMM0, UC_X86_REG_XMM1,
    UC_X86_REG_FPCW,
)

SHA = "2ba67f1f80ebe53f978dc6843777764b5ead911a688c89c9cd68cc8c2d9cae00"
GATE, HELPER, STOP = 0x20000000, 0x20001000, 0x20001FF0
L, OBJECT, RAW, FEATURE, CHARACTER, STACK = 0x30000100, 0x30000200, 0x30010000, 0x30050000, 0x30050100, 0x3006F000
REGS = (UC_X86_REG_EAX, UC_X86_REG_EBX, UC_X86_REG_ECX, UC_X86_REG_EDX,
        UC_X86_REG_ESI, UC_X86_REG_EDI, UC_X86_REG_EBP, UC_X86_REG_ESP,
        UC_X86_REG_EFLAGS, UC_X86_REG_XMM0, UC_X86_REG_XMM1, UC_X86_REG_FPCW)


def execute(image, base, plan, patched, prior_tables, helper_noop=False):
    cpu = Uc(UC_ARCH_X86, UC_MODE_32)
    cpu.mem_map(0, 0x1000)  # isolated x86 FS:[0] SEH chain, not host memory
    cpu.mem_map(base, (len(image) + 0xFFF) & ~0xFFF)
    cpu.mem_write(base, image)
    cpu.mem_map(GATE, 0x2000)
    cpu.mem_map(0x30000000, 0x70000)

    def u32(a): return struct.unpack("<I", cpu.mem_read(a, 4))[0]
    def put(a, value): cpu.mem_write(a, struct.pack("<I", value))
    def f(a, value): cpu.mem_write(a, struct.pack("<f", value))
    def cstring(a):
        b = bytearray()
        while cpu.mem_read(a, 1) != b"\0":
            b += cpu.mem_read(a, 1)
            a += 1
        return b.decode("ascii")

    put(OBJECT, 0); put(OBJECT + 4, 123456789); put(OBJECT + 8, RAW)
    f(RAW + 0x2D74, 17.5); f(RAW + 0x2D78, 300.25)
    f(RAW + 0x2D8C, 1.25); f(RAW + 0x2D90, -0.75)
    f(RAW + 0x2D98, 2.5); f(RAW + 0x2D9C, -1.5)
    put(RAW + 0x337C, 0x400049); put(RAW + 0x3380, 0x1040)
    raw_before = bytes(cpu.mem_read(RAW, 0x5430))
    lua = [({"hitBody": {"old": 1}} if prior_tables else {})]
    api_calls, helpers = [], []

    def return_call(pop=0):
        esp = cpu.reg_read(UC_X86_REG_ESP)
        cpu.reg_write(UC_X86_REG_EIP, u32(esp))
        cpu.reg_write(UC_X86_REG_ESP, esp + 4 + pop)

    def hook(machine, address, size, data):
        rva = address - base
        sp = machine.reg_read(UC_X86_REG_ESP)
        arg = lambda n: u32(sp + 4 + n * 4)
        signed = lambda n: n if n < 0x80000000 else n - 0x100000000
        if address == HELPER:
            assert (arg(0), arg(1)) == (L, OBJECT)
            assert len(lua) == 1 and "isActivatedSpirit" in lua[-1]
            helpers.append((arg(0), arg(1)))
            if not helper_noop:
                lua[-1]["combat"] = {"apiVersion": 1, "valid": True, "id": lua[-1]["id"]}
                for r in (UC_X86_REG_EAX, UC_X86_REG_ECX, UC_X86_REG_EDX):
                    machine.reg_write(r, 0xDEADBEEF)
                machine.reg_write(UC_X86_REG_EFLAGS, 0x246)
                machine.reg_write(UC_X86_REG_XMM0, 0xFEDCBA9876543210)
                machine.reg_write(UC_X86_REG_XMM1, 0x8877665544332211)
                machine.reg_write(UC_X86_REG_FPCW, 0x077F)
            return_call()
        elif rva in (0x1D990,):
            # thiscall returns shared_ptr into caller-owned hidden result.
            assert machine.reg_read(UC_X86_REG_ECX) == OBJECT
            result = arg(0)
            put(result, 0); put(result + 4, 0)
            machine.reg_write(UC_X86_REG_EAX, result)
            return_call(4)
        elif rva == 0x1DF70:
            assert machine.reg_read(UC_X86_REG_ECX) == L
            lua[-1]["body_exported"] = True
            return_call()
        elif rva in (0x1860, 0x17E0, 0x19D0, 0x1C60, 0x1A40, 0x13E0, 0x1200, 0x1B50, 0x13B0):
            assert arg(0) == L, hex(address)
            api_calls.append(rva)
            if rva == 0x1860: lua.append(cstring(arg(1)))
            elif rva == 0x17E0: lua.append(struct.unpack("<d", machine.mem_read(sp + 8, 8))[0])
            elif rva == 0x19D0: lua.append(bool(arg(1)))
            elif rva == 0x1C60:
                target = lua[signed(arg(1))]
                value, key = lua.pop(), lua.pop()
                target[key] = value
            elif rva == 0x1A40:
                target = lua[signed(arg(1))]
                key = lua.pop()
                lua.append(target.get(key))
            elif rva == 0x13E0:
                machine.reg_write(UC_X86_REG_EAX, 5 if isinstance(lua[signed(arg(1))], dict) else 0)
            elif rva == 0x1200:
                index = signed(arg(1))
                new_top = index if index >= 0 else len(lua) + index + 1
                del lua[new_top:]
            elif rva == 0x1B50: lua.append({})
            elif rva == 0x13B0: lua.append(lua[signed(arg(1))])
            return_call()

    cpu.hook_add(UC_HOOK_CODE, hook)
    if patched:
        cpu.mem_write(*plan["PATCH"])
        cpu.mem_write(*plan["CODE"])
    for index, reg in enumerate(REGS[:7]): cpu.reg_write(reg, 0x60000000 + index * 0x111111)
    cpu.reg_write(UC_X86_REG_ECX, L); cpu.reg_write(UC_X86_REG_EDX, OBJECT)
    cpu.reg_write(UC_X86_REG_ESP, STACK); cpu.reg_write(UC_X86_REG_EFLAGS, 0x202)
    cpu.reg_write(UC_X86_REG_FPCW, 0x037F)
    cpu.reg_write(UC_X86_REG_XMM0, 0x1234123412341234)
    cpu.reg_write(UC_X86_REG_XMM1, 0x11112222333344445555666677778888)
    put(STACK, STOP); put(0, 0xFFFFFFFF)
    cpu.emu_start(base + 0x1E630, STOP, count=100000)
    assert len(lua) == 1
    assert u32(0) == 0xFFFFFFFF, "upstream SEH chain restored"
    assert raw_before == bytes(cpu.mem_read(RAW, 0x5430)), "no raw enemy writes"
    assert len(helpers) == int(patched)
    assert lua[0]["id"] == 123456789 and lua[0]["x"] == 17.5
    assert lua[0]["isActivatedSpirit"] and lua[0]["enabled"] and lua[0]["vx"] == 2.5
    return lua[0], tuple(cpu.reg_read(r) for r in REGS), api_calls


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--plan-exe", type=Path, required=True)
    parser.add_argument("--inject-dll", type=Path, default=PROJECT / "vendor/release/ka_ai_duka/inject.dll")
    args = parser.parse_args()
    assert hashlib.sha256(args.inject_dll.read_bytes()).hexdigest() == SHA
    subprocess.run([str(args.plan_exe)], check=True)
    cases = 0
    for base in (0x10000000, 0x14000000, 0x65000000):
        pe = pefile.PE(str(args.inject_dll))
        pe.relocate_image(base)
        image = pe.get_memory_mapped_image()
        dump = subprocess.check_output([str(args.plan_exe), "--dump", hex(base), hex(GATE), hex(HELPER)], text=True)
        plan = {kind: (int(address, 16), bytes.fromhex(code))
                for kind, address, code in (line.split() for line in dump.splitlines())}
        for prior in (False, True):
            original, original_regs, original_calls = execute(image, base, plan, False, prior)
            reference, reference_regs, reference_calls = execute(image, base, plan, True, prior, helper_noop=True)
            patched, patched_regs, patched_calls = execute(image, base, plan, True, prior)
            sensor = patched.pop("combat")
            assert sensor == {"apiVersion": 1, "valid": True, "id": 123456789}
            assert original == patched and original_calls == patched_calls
            assert original == reference and original_calls == reference_calls
            # The void fastcall routine leaves caller-saved EAX pointing into
            # its own stack and ECX containing a stack-derived security cookie.
            # The bridge's saved arguments shift that dead frame by 8 bytes;
            # compare its exact post-original context with a no-op callback.
            assert reference_regs == patched_regs, "helper leaked GPR/flags/SSE/x87 changes"
            for index in (1, 4, 5, 6, 7):
                assert original_regs[index] == patched_regs[index], "callee-saved register/stack changed"
            cases += 1
    print(f"native_enemy_sensor_test: PASS ({cases} real upstream code / relocated ABI cases)")


if __name__ == "__main__": main()
