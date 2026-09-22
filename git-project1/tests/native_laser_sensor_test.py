"""Execute the real v1.7 Laser::Update plus our bridge in an isolated x86 emulator.

Build src/native/laser_sensor_selftest.c + laser_sensor.c with the project's x86 TCC,
then pass --plan-exe and --inject-dll. This never starts or opens the game.
pefile and unicorn may be installed under work/input-fix/python as for other
native tests, or installed in the selected Python environment with pip.
"""
import argparse
import hashlib
import math
from pathlib import Path
import struct
import subprocess
import sys

PROJECT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT / "work" / "input-fix" / "python"))
import pefile
from unicorn import Uc, UC_ARCH_X86, UC_MODE_32, UC_HOOK_CODE
from unicorn.x86_const import (
    UC_X86_REG_EAX, UC_X86_REG_EBX, UC_X86_REG_ECX, UC_X86_REG_EDX,
    UC_X86_REG_ESI, UC_X86_REG_EDI, UC_X86_REG_EBP, UC_X86_REG_ESP,
    UC_X86_REG_EFLAGS, UC_X86_REG_XMM0, UC_X86_REG_XMM1, UC_X86_REG_FPCW,
)

UPSTREAM_SHA256 = "2ba67f1f80ebe53f978dc6843777764b5ead911a688c89c9cd68cc8c2d9cae00"
GATEWAY, HELPER, STOP = 0x20000000, 0x20001000, 0x20001FF0
OBJECT, RAW, BODY, STACK = 0x30000100, 0x30001000, 0x30002000, 0x3000F000
REGISTERS = (UC_X86_REG_EAX, UC_X86_REG_EBX, UC_X86_REG_ECX, UC_X86_REG_EDX,
             UC_X86_REG_ESI, UC_X86_REG_EDI, UC_X86_REG_EBP, UC_X86_REG_ESP,
             UC_X86_REG_EFLAGS, UC_X86_REG_XMM0, UC_X86_REG_XMM1, UC_X86_REG_FPCW)


def generate_plan(executable, base):
    output = subprocess.check_output([str(executable), "--dump", hex(base), hex(GATEWAY), hex(HELPER)], text=True)
    return {kind: (int(address, 16), bytes.fromhex(data))
            for kind, address, data in (line.split() for line in output.splitlines())}


def execute(image, base, plan, raw_values, patched):
    cpu = Uc(UC_ARCH_X86, UC_MODE_32)
    cpu.mem_map(base, (len(image) + 0xFFF) & ~0xFFF)
    cpu.mem_write(base, image)
    cpu.mem_map(GATEWAY, 0x2000)
    cpu.mem_map(0x30000000, 0x10000)

    def put32(address, value): cpu.mem_write(address, struct.pack("<I", value))
    def get32(address): return struct.unpack("<I", cpu.mem_read(address, 4))[0]
    def getf(address): return struct.unpack("<f", cpu.mem_read(address, 4))[0]
    def putf(address, value): cpu.mem_write(address, struct.pack("<f", value))

    assert cpu.mem_read(*[plan["EXPECTED"][0], len(plan["EXPECTED"][1])]) == plan["EXPECTED"][1]
    assert get32(base + 0x61C74 + 5 * 4) == base + 0x20510
    assert getf(base + 0x62BBC) == 0.5
    if patched:
        cpu.mem_write(*plan["PATCH"])
        cpu.mem_write(*plan["CODE"])
    cpu.mem_write(HELPER, b"\xC3")
    cpu.mem_write(RAW, bytes([0xA5]) * 0x59C)
    cpu.mem_write(BODY, bytes([0x5A]) * 24)
    put32(OBJECT + 8, RAW + 0x548)
    put32(OBJECT + 0x0C, RAW)
    put32(OBJECT + 0x10, BODY)
    for offset, value in zip((0x548, 0x54C, 0x554, 0x558, 0x55C, 0x564), raw_values):
        putf(RAW + offset, value)
    before_raw = bytes(cpu.mem_read(RAW, 0x59C))
    calls = []

    def helper(machine, address, size, data):
        if address != HELPER:
            return
        argument = get32(machine.reg_read(UC_X86_REG_ESP) + 4)
        assert argument == OBJECT, "bridge passes saved ECX, not a clobbered register"
        origin_x, origin_y = getf(RAW + 0x548), getf(RAW + 0x54C)
        angle, length1 = getf(RAW + 0x554), getf(RAW + 0x558)
        putf(BODY + 4, origin_x + length1 * math.cos(angle))
        putf(BODY + 8, origin_y + length1 * math.sin(angle))
        calls.append(argument)
        # Cdecl may destroy volatile GPRs/flags, SSE and x87 control state.
        # The real helper's numerical code is separately tested natively.
        for register in (UC_X86_REG_EAX, UC_X86_REG_ECX, UC_X86_REG_EDX):
            machine.reg_write(register, 0xDEADBEEF)
        machine.reg_write(UC_X86_REG_EFLAGS, 0x246)
        machine.reg_write(UC_X86_REG_XMM0, 0xFEDCBA9876543210)
        machine.reg_write(UC_X86_REG_XMM1, 0x8877665544332211)
        machine.reg_write(UC_X86_REG_FPCW, 0x077F)

    cpu.hook_add(UC_HOOK_CODE, helper)
    for i, register in enumerate(REGISTERS[:7]):
        cpu.reg_write(register, 0x60000000 + i * 0x111111)
    cpu.reg_write(UC_X86_REG_ECX, OBJECT)
    cpu.reg_write(UC_X86_REG_ESP, STACK)
    cpu.reg_write(UC_X86_REG_EFLAGS, 0x202)
    cpu.reg_write(UC_X86_REG_XMM0, 0x1234567812345678)
    cpu.reg_write(UC_X86_REG_XMM1, 0x11112222333344445555666677778888)
    cpu.reg_write(UC_X86_REG_FPCW, 0x037F)
    put32(STACK, STOP)
    cpu.emu_start(base + 0x20510, STOP, count=500)
    assert cpu.reg_read(UC_X86_REG_ESP) == STACK + 4, "stack imbalance"
    assert bytes(cpu.mem_read(RAW, 0x59C)) == before_raw, "game laser was written"
    assert len(calls) == int(patched), "helper must run once, only with patched code"
    return bytes(cpu.mem_read(BODY, 24)), tuple(cpu.reg_read(r) for r in REGISTERS)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan-exe", required=True, type=Path)
    parser.add_argument("--inject-dll", required=True, type=Path)
    args = parser.parse_args()
    assert hashlib.sha256(args.inject_dll.read_bytes()).hexdigest() == UPSTREAM_SHA256
    cases = 0
    for base in (0x10000000, 0x15000000):
        pe = pefile.PE(str(args.inject_dll))
        pe.relocate_image(base)
        image = pe.get_memory_mapped_image()
        plan = generate_plan(args.plan_exe, base)
        for angle in (0, math.pi / 2, -math.pi / 2, math.pi, 0.8, -0.8):
            for length1 in (0, 80, 300):
                values = (-100, 448, angle, length1, length1 + 40, 16)
                original, registers = execute(image, base, plan, values, False)
                corrected, corrected_registers = execute(image, base, plan, values, True)
                assert corrected[:4] == original[:4] and corrected[12:] == original[12:]
                assert registers == corrected_registers, "original register/FPU/SSE results changed"
                actual_angle = struct.unpack("<f", struct.pack("<f", angle))[0]
                x, y, width, height, exported_angle = struct.unpack("<5f", corrected[4:])
                assert abs(x - (-100 + length1 * math.cos(actual_angle))) < 0.00005
                assert abs(y - (448 + length1 * math.sin(actual_angle))) < 0.00005
                assert width == 40 and height == 8 and exported_angle == actual_angle
                cases += 1
    print(f"PASS: {cases} original-DLL/bridge cases; relocated base, angular anchors, quarter-width, register/FPU/SSE and raw-memory preservation")


if __name__ == "__main__":
    main()
