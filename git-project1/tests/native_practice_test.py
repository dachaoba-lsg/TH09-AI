"""Offline x86 practice-gate tests against supported original TH09 machine code.

Build tests/practice_plan_dump.c with src/native/practice_patches.c using the
32-bit project compiler, then pass --plan-exe and --game-exe. Dependencies are
the same pefile/unicorn packages as native_input_test.py. Only sound/graphics,
RNG and synthetic collision-list input are mocked; HP, hurt-state, timers and
combo settlement/reset execute the game's original instructions.
"""
import argparse
import hashlib
from pathlib import Path
import struct
import subprocess
import sys

PROJECT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT / "work" / "input-fix" / "python"))
import pefile
from unicorn import Uc, UC_ARCH_X86, UC_MODE_32, UC_HOOK_CODE
from unicorn.x86_const import UC_X86_REG_EAX, UC_X86_REG_ECX, UC_X86_REG_ESI, UC_X86_REG_ESP

SUPPORTED_SHA256 = "10350095bcf95edb59e03bee9849a2dc8a7714b4927ad5909c569c550fce6822"


def generate_plan(executable, no_damage, invincible):
    lines = subprocess.check_output([str(executable), str(int(no_damage)), str(int(invincible))], text=True).splitlines()
    result = []
    for line in lines:
        fields = line.split()
        result.append((fields[0], int(fields[1], 16), *[bytes.fromhex(value) for value in fields[2:]]))
    return result


def execute(image, plan, side, hp, hit=True, original_invincible=False):
    cpu = Uc(UC_ARCH_X86, UC_MODE_32)
    cpu.mem_map(0x400000, 0x600000)
    cpu.mem_write(0x400000, image)
    cpu.mem_map(0x1000000, 0x100000)
    sentinel = 0x600FFF
    player = 0x700000 if side == 0 else 0x740000
    stage, board, scoreboard, collision, bullet = 0x800000, 0x880000, 0x890000, 0x891000, 0x892000
    def put32(address, value): cpu.mem_write(address, struct.pack("<I", value))
    def get32(address): return struct.unpack("<I", cpu.mem_read(address, 4))[0]
    for entry in plan:
        if entry[0] == "CODE" and len(entry) == 3:
            cpu.mem_write(entry[1], entry[2])
        elif entry[0] == "PATCH":
            assert cpu.mem_read(entry[1], len(entry[2])) == entry[2]
            cpu.mem_write(entry[1], entry[3])
    if original_invincible:
        cpu.mem_write(0x41E8EC, b"\x90" * 5)  # Official THprac's skip-call behavior.
    cpu.mem_write(0x600800, b"\xC3")  # Cdecl diagnostic callback, recorded below.
    # Sound/rendering and win notification do not decide damage; isolate them.
    for address, argc in ((0x43E380, 8), (0x415D70, 4), (0x40CD70, 16), (0x43E2F0, 8), (0x41A380, 4)):
        cpu.mem_write(address, b"\xC2" + struct.pack("<H", argc))
    cpu.mem_write(0x40D4F0, b"\x31\xC0\xC3")  # Match continues.
    cpu.mem_write(0x406200, b"\xD9\xEE\xC2\x04\x00")  # Zero knockback angle, x87 result.
    cpu.mem_write(0x41DA70, b"\xB8" + struct.pack("<I", collision if hit else 0) + b"\xC3")
    put32(0x4A7E38, stage)
    put32(0x4A7E48, 2)
    put32(player, 0)
    put32(player + 8, side)
    put32(player + 0xC, board)
    put32(player + 0xA8, hp)
    put32(board + 0x1C, scoreboard)
    put32(scoreboard + 8, 100)
    put32(player + 0x30410, player)
    put32(player + 0x30414, 42)
    put32(player + 0x3041C, 600000)
    put32(player + 0x30420, 123450)
    put32(collision + 0x2C, bullet)
    records = []
    calls = {"hurt": 0, "death": 0, "reset": 0}
    def trace(machine, address, size, user_data):
        if address == 0x600800:
            stack = machine.reg_read(UC_X86_REG_ESP)
            mode, target = get32(stack + 4), get32(stack + 8)
            records.append((mode, get32(target + 8), get32(target + 0xA8)))
        elif address == 0x41E420: calls["hurt"] += 1
        elif address == 0x415D70: calls["death"] += 1
        elif address == 0x41D7E0: calls["reset"] += 1
    cpu.hook_add(UC_HOOK_CODE, trace)
    stack = 0x1080000
    put32(stack, sentinel)
    cpu.reg_write(UC_X86_REG_ESP, stack)
    cpu.reg_write(UC_X86_REG_ESI, player)
    cpu.reg_write(UC_X86_REG_ECX, player)
    cpu.emu_start(0x41E8B0, sentinel, count=10000)
    assert cpu.reg_read(UC_X86_REG_ESP) == stack + 4, "Stack imbalance"
    return {"hp": get32(player + 0xA8), "state": get32(player), "combo": get32(player + 0x30414),
            "spell_point": get32(player + 0x3041C), "ledger": get32(scoreboard + 8),
            "collision": cpu.reg_read(UC_X86_REG_EAX), "records": records, "calls": calls,
            "player_bytes": bytes(cpu.mem_read(player, 0x31000))}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--game-exe", required=True, type=Path)
    parser.add_argument("--plan-exe", required=True, type=Path)
    args = parser.parse_args()
    data = args.game_exe.read_bytes()
    assert hashlib.sha256(data).hexdigest() == SUPPORTED_SHA256
    image = pefile.PE(data=data).get_memory_mapped_image()
    cases = 0
    for hp in (1, 2, 10):
        p2_baseline = execute(image, [], 1, hp)
        for no_damage, invincible in ((False, False), (True, False), (False, True), (True, True)):
            plan = generate_plan(args.plan_exe, no_damage, invincible)
            p1 = execute(image, plan, 0, hp)
            p2 = execute(image, plan, 1, hp)
            assert p2 == p2_baseline, ("2P changed", hp, no_damage, invincible)
            assert p1["collision"] == 1
            assert p1["combo"] == p1["spell_point"] == 0
            assert p1["ledger"] == 12445, "Must use normal combo settlement"
            if invincible:
                assert p1["hp"] == hp and p1["state"] == 0
                assert p1["calls"] == {"hurt": 0, "death": 0, "reset": 1}
                assert p1["records"] == [(2, 0, hp)]
            elif no_damage:
                assert p1["hp"] == hp and p1["state"] == 4
                assert p1["calls"] == {"hurt": 1, "death": 0, "reset": 1}
                assert p1["records"] == [(1, 0, hp)]
            else:
                assert p1["hp"] == (0 if hp == 1 else max(1, hp - 2))
                assert p1["state"] == 4 and not p1["records"]
            for side in (0, 1):
                miss = execute(image, plan, side, hp, hit=False)
                assert miss["hp"] == hp and miss["state"] == 0
                assert miss["combo"] == 42 and miss["spell_point"] == 600000
                assert miss["ledger"] == 100 and not miss["records"]
                assert miss["collision"] == 0
            cases += 1
    thprac = execute(image, [], 0, 10, original_invincible=True)
    assert thprac["combo"] == 42 and thprac["spell_point"] == 600000
    print(f"PASS: {cases} mode/HP combinations, both players, hit and miss, original TH09 collision/hurt code.")
    print("PASS: no_damage preserves HP even at 1 HP while retaining hurt state and normal combo settlement.")
    print("PASS: invincible avoids hurt state, resets combo via original routine, and overrides no_damage; 2P byte-identical.")
    print("PASS: official THprac skip-call alone does not reset combo in this collision path; the explicit reset is necessary.")


if __name__ == "__main__":
    main()
