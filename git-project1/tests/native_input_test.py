"""Execute TH09's original x86 input routine without starting or modifying TH09.

Usage: python tests/native_input_test.py --game-exe "C:/games/TH09/th09.exe"
Dependencies: python -m pip install --target work/input-fix/python pefile unicorn
Global installations also work. Mock WinAPI/DirectInput devices provide input;
all mapping and edge-event code is actual TH09 machine code.
"""
import argparse
import hashlib
import re
import struct
import sys
from pathlib import Path

PROJECT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT / "work" / "input-fix" / "python"))
try:
    import pefile
    from unicorn import Uc, UC_ARCH_X86, UC_MODE_32, UC_HOOK_CODE
    from unicorn.x86_const import UC_X86_REG_ESP, UC_X86_REG_EAX, UC_X86_REG_ECX
except ImportError as exc:
    raise SystemExit("Install dependencies: python -m pip install --target work/input-fix/python pefile unicorn") from exc

SUPPORTED_SHA256 = "10350095bcf95edb59e03bee9849a2dc8a7714b4927ad5909c569c550fce6822"


class GameInputMachine:
    def __init__(self, game_bytes):
        pe = pefile.PE(data=game_bytes)
        self.cpu = Uc(UC_ARCH_X86, UC_MODE_32)
        self.cpu.mem_map(0x400000, 0x600000)
        self.cpu.mem_write(0x400000, pe.get_memory_mapped_image())
        self.cpu.mem_map(0x1000000, 0x100000)
        self.cpu.mem_map(0x2000000, 0x1000)
        self.put32(0x48E228, 0x2000000)  # GetKeyboardState import.
        self.put32(0x4B30B8, 1)  # Foreground/input-active flag.
        self.cpu.mem_write(0x2000000, b"\xc2\x04\x00")
        self.cpu.mem_write(0x2000010, b"\xc2\x10\x00")
        self.cpu.mem_write(0x2000020, b"\xc2\x04\x00")
        self.put32(0x500000, 0x500100)  # Fake IDirectInputDevice vtable.
        self.put32(0x500124, 0x2000010)  # GetDeviceState.
        self.put32(0x50011C, 0x2000020)  # Acquire.
        self.pressed = []
        self.cpu.hook_add(UC_HOOK_CODE, self.device_hook, begin=0x2000000, end=0x2000020)

    def put32(self, address, value):
        self.cpu.mem_write(address, struct.pack("<I", value))

    def get32(self, address):
        return struct.unpack("<I", self.cpu.mem_read(address, 4))[0]

    def device_hook(self, cpu, address, size, user_data):
        stack = cpu.reg_read(UC_X86_REG_ESP)
        if address == 0x2000000:
            destination = self.get32(stack + 4)
        elif address == 0x2000010:
            destination = self.get32(stack + 12)
        elif address == 0x2000020:
            cpu.reg_write(UC_X86_REG_EAX, 0)
            return
        else:
            return
        keys = bytearray(256)
        for key in self.pressed:
            keys[key] = 0x80
        cpu.mem_write(destination, bytes(keys))
        cpu.reg_write(UC_X86_REG_EAX, 0 if address == 0x2000010 else 1)

    def read_input(self, side, keyboard_type, keys, direct_input=False, clear=True):
        self.pressed = keys
        if clear:
            self.cpu.mem_write(0x4ACE18, b"\x00" * 0x1AA)
        self.cpu.mem_write(0x4B353F + side, bytes([keyboard_type]))
        self.put32(0x4B3110, 0x500000 if direct_input else 0)
        stack = 0x1080000
        self.put32(stack, 0x2000FFF)
        self.cpu.reg_write(UC_X86_REG_ESP, stack)
        self.cpu.reg_write(UC_X86_REG_ECX, side)
        self.cpu.emu_start(0x42B850, 0x2000FFF, count=3000)
        return self.cpu.reg_read(UC_X86_REG_EAX) & 0xFFFF


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--game-exe", type=Path, required=True)
    args = parser.parse_args()
    game_bytes = args.game_exe.read_bytes()
    assert hashlib.sha256(game_bytes).hexdigest() == SUPPORTED_SHA256, "Unsupported game executable"
    machine = GameInputMachine(game_bytes)
    read = machine.read_input
    header = PROJECT / "src" / "native" / "input_patches.h"
    patches = []
    expression = r"\{(0x[0-9A-F]+),\s*(\d+),\s*\{([^}]+)\},\s*\{([^}]+)\}\}"
    for match in re.finditer(expression, header.read_text(encoding="utf-8")):
        address, size = int(match[1], 16), int(match[2])
        before, after = (bytes(int(x.strip(), 16) for x in match[g].split(",")) for g in (3, 4))
        assert len(before) == size == len(after)
        assert machine.cpu.mem_read(address, size) == before, f"Original bytes differ at {address:08X}"
        patches.append((address, after))
    assert len(patches) == 22, "Unexpected patch manifest"
    baseline = {(di, side, key): read(side, 2 if side == 0 else 3, [key], di)
                for di in (False, True) for side in (0, 1) for key in range(256)}
    for address, replacement in patches:
        machine.cpu.mem_write(address, replacement)
    machine.cpu.ctl_remove_cache(0x42B850, 0x42BE33)
    expected_vk = {0x4A: 1, 0x4B: 2, 0x4C: 4, 0x1B: 8, 0x57: 16, 0x53: 32, 0x41: 64, 0x44: 128}
    expected_di = {0x24: 1, 0x25: 2, 0x26: 4, 0x01: 8, 0x11: 16, 0x1F: 32, 0x1E: 64, 0x20: 128}
    for di in (False, True):
        for key in range(256):
            p1 = read(0, 2, [key], di)
            p2 = read(1, 3, [key], di)
            assert p1 == baseline[di, 0, key], ("1P changed", di, hex(key), hex(p1))
            expected = (expected_di if di else expected_vk).get(key, 0)
            assert p2 & 255 == expected, ("2P incorrect", di, hex(key), hex(p2), hex(expected))
            assert p2 & 0xFF00 == baseline[di, 1, key] & 0xFF00, ("System key changed", di, hex(key))
        p1_keys = ([0x2C, 0x2D, 0x2A, 0xC8, 0xD0, 0xCB, 0xCD] if di else
                   [0x5A, 0x58, 0x10, 0x26, 0x28, 0x25, 0x27])
        p2_keys = ([0x24, 0x25, 0x26, 0x11, 0x1F, 0x1E, 0x20] if di else
                   [0x4A, 0x4B, 0x4C, 0x57, 0x53, 0x41, 0x44])
        for chord in range(128):
            p1_chord = [key for bit, key in enumerate(p1_keys) if chord & (1 << bit)]
            p2_chord = [key for bit, key in enumerate(p2_keys) if chord & (1 << bit)]
            expected = (chord & 7) | ((chord & 0x78) << 1)
            assert read(0, 2, p1_chord, di) & 255 == expected
            assert read(1, 3, p1_chord, di) & 255 == 0, "1P chord leaked into 2P"
            assert read(0, 2, p2_chord, di) & 255 == 0, "2P chord leaked into 1P"
            assert read(1, 3, p2_chord, di) & 255 == expected
        up_key = 0x11 if di else 0x57
        read(1, 3, [up_key], di)
        state = 0x4ACE18 + 0x8E
        assert struct.unpack("<H", machine.cpu.mem_read(state + 6, 2))[0] == 16
        read(1, 3, [up_key], di, clear=False)
        assert struct.unpack("<H", machine.cpu.mem_read(state + 6, 2))[0] == 0
        read(1, 3, [], di, clear=False)
        assert struct.unpack("<H", machine.cpu.mem_read(state + 8, 2))[0] == 16
    print("PASS: 22 checked patches match supported original TH09 v1.50a machine code.")
    print("PASS: WinAPI and DirectInput: 256 individual keys, 128 chords per player, no gameplay leakage.")
    print("PASS: 1P FULL/shared system keys unchanged; 2P mapping and press/hold/release edges verified.")


if __name__ == "__main__":
    main()
