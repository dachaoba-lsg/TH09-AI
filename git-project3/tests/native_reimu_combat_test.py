"""Execute verified TH09 x86 combat kernels on synthetic memory with Unicorn.

The game file is read-only: it is never launched, injected or redistributed.
Only animation bookkeeping is mocked in the shot/death query; geometry, raw
damage, activation reduction, non-piercing state, and homing math are original
game instructions. Requires pefile + unicorn (work/input-fix/python supported).
"""
import argparse
import hashlib
import math
from pathlib import Path
import struct
import sys

PROJECT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT / "work/input-fix/python"))
import pefile
from unicorn import Uc, UC_ARCH_X86, UC_MODE_32, UC_HOOK_CODE
from unicorn.x86_const import *

SHA = "10350095bcf95edb59e03bee9849a2dc8a7714b4927ad5909c569c550fce6822"
PLAYER, ENEMY, DATA, STACK, STOP = 0x20000000, 0x20040000, 0x20050000, 0x2006F000, 0x20070000
SHOT = PLAYER + 0xC11C
checks = 0


def check(ok, message):
    global checks
    checks += 1
    if not ok:
        raise AssertionError(message)


def f32(v): return struct.unpack("<f", struct.pack("<f", v))[0]


class Machine:
    def __init__(self, image):
        self.cpu = c = Uc(UC_ARCH_X86, UC_MODE_32)
        c.mem_map(0x400000, (len(image) + 0xFFF) & ~0xFFF)
        c.mem_write(0x400000, image)
        c.mem_map(PLAYER, 0x80000)
        c.reg_write(UC_X86_REG_ESP, STACK)
        c.reg_write(UC_X86_REG_EBP, STACK + 0x100)
        c.reg_write(UC_X86_REG_FPCW, 0x37F)
        self.put(STACK, STOP)
        self.stops = {STOP}
        self.spawn_count = 0
        self.slot_addresses = None
        c.hook_add(UC_HOOK_CODE, self.hook)

    def put(self, a, v): self.cpu.mem_write(a, struct.pack("<I", v & 0xFFFFFFFF))
    def put16(self, a, v): self.cpu.mem_write(a, struct.pack("<H", v))
    def f(self, a, v): self.cpu.mem_write(a, struct.pack("<f", v))
    def get(self, a): return struct.unpack("<I", self.cpu.mem_read(a, 4))[0]
    def get16(self, a): return struct.unpack("<H", self.cpu.mem_read(a, 2))[0]
    def gf(self, a): return struct.unpack("<f", self.cpu.mem_read(a, 4))[0]
    def ret(self, pop=0):
        c = self.cpu
        esp = c.reg_read(UC_X86_REG_ESP)
        c.reg_write(UC_X86_REG_EIP, self.get(esp))
        c.reg_write(UC_X86_REG_ESP, esp + 4 + pop)

    def hook(self, c, address, size, _):
        if address in self.stops:
            c.emu_stop()
        elif address == 0x410870 and self.slot_addresses is not None:
            # Skip per-enemy AI/animation; execute the original loop control.
            self.slot_addresses.append(c.reg_read(UC_X86_REG_EBX))
            c.reg_write(UC_X86_REG_EIP, 0x41162A)
        elif address == 0x403E00:  # hit animation reset; no combat result
            self.ret(8)
        elif address == 0x40CC00:  # death animation; no combat result
            self.ret(16)
        elif address == 0x41D110:  # record circle creation, no circle simulation
            self.spawn_count += 1
            self.ret(24)

    def run(self, address):
        self.cpu.emu_start(address, 0, count=100000)
        check(self.cpu.reg_read(UC_X86_REG_EIP) in self.stops, f"kernel {address:x} reached stop")

    def shot(self, x=0, y=0, damage=30, shot_type=0, slot=0):
        s = SHOT + slot * 0x484
        self.f(s + 0x2A4, x); self.f(s + 0x2A8, y)
        self.f(s + 0x430, 48); self.f(s + 0x434, 48)
        self.f(s + 0x43C, 0); self.f(s + 0x440, -.5)
        self.put16(s + 0x460, damage); self.put16(s + 0x462, 1)
        self.put16(s + 0x464, shot_type)
        self.put(PLAYER + 0x303C8, 0); self.put(PLAYER + 0x303D0, 1)

    def query(self, x=0, y=0, w=16, h=24):
        c = self.cpu
        self.f(DATA, x); self.f(DATA + 4, y)
        self.f(DATA + 0x10, w); self.f(DATA + 0x14, h)
        c.reg_write(UC_X86_REG_ESP, STACK); self.put(STACK, STOP)
        for i, arg in enumerate([DATA, DATA + 0x10, DATA + 0x20, DATA + 0x24, DATA + 0x28]):
            self.put(STACK + 4 + i * 4, arg)
        c.reg_write(UC_X86_REG_ECX, PLAYER)
        self.run(0x41FCD0)
        return c.reg_read(UC_X86_REG_EAX), self.get(DATA + 0x20)


def shot_tests(image):
    # Both directions, both axes: widths are full dimensions and equality hits.
    for axis, boundary in [(0, 32), (1, 36)]:
        for sign in [-1, 1]:
            for delta in [-.0001, 0, .0001]:
                m = Machine(image); m.shot()
                xy = [0, 0]; xy[axis] = sign * (boundary + delta)
                result = m.query(*xy)
                hit = delta <= 0
                check(result == ((30, 30) if hit else (0, 0)), f"AABB boundary axis{axis} sign{sign} delta{delta}: {result}")
                check(m.get16(SHOT + 0x462) == (2 if hit else 1), "type0 consumed exactly on hit")
    m = Machine(image); m.shot()
    check(m.query() == (30, 30) and m.query() == (0, 0), "type0 cannot damage a second overlapping enemy")
    for kind in [2, 3]:
        m = Machine(image); m.shot(shot_type=kind)
        check(m.query() == (30, 30) and m.query() == (30, 30) and m.get16(SHOT + 0x462) == 1, "type2/3 piercing distinct from Reimu type0")
    m = Machine(image); m.shot(); m.shot(slot=1)
    check(m.query() == (60, 60), "equal geometry distinct shot slots both contribute")
    m = Machine(image); m.shot(x=50)
    check(m.query(w=16) == (0, 0) and m.query(w=80) == (30, 30) and m.query(x=50) == (0, 0), "secondary AABB consumes missed primary shot before later enemy")
    # Execute actual enemy caller around both AABB queries. Secondary EAX is
    # discarded even though it consumes the shot and overwrites shot-only sum.
    for sx, expected_total in [(0, 30), (50, 0)]:
        m = Machine(image); m.shot(x=sx)
        m.f(ENEMY + 0x2DBC, 16); m.f(ENEMY + 0x2DC0, 24)
        m.f(ENEMY + 0x2DC8, 80); m.f(ENEMY + 0x2DCC, 24)
        m.put(ENEMY + 0x337C, 0x49)
        m.put(STACK + 0x100 - 4, DATA)
        m.put(DATA + 0x320, DATA + 0x400); m.put(DATA + 0x404, PLAYER)
        m.cpu.reg_write(UC_X86_REG_EBX, ENEMY)
        m.stops = {0x411033}
        m.run(0x410FAB)
        check(m.cpu.reg_read(UC_X86_REG_EDI) == expected_total and m.get16(SHOT + 0x462) == 2, "actual secondary call preserves only primary total and consumes shot")
        check(m.get(ENEMY + 0x2E5C) == (0 if sx == 0 else 30), "actual secondary call overwrites raw shot classification")


def damage_tests(image):
    for flags2, divisor in [(0, 1), (0x40, 4), (0x1040, 2)]:
        for shot_sum in [1, 29, 30, 31, 60, 90, 120]:
            for circle in [0, 5]:
                m = Machine(image)
                m.put(ENEMY + 0x2E48, 200)
                m.put(ENEMY + 0x337C, 0x49); m.put(ENEMY + 0x3380, flags2)
                m.put(ENEMY + 0x2E5C, shot_sum)
                m.cpu.reg_write(UC_X86_REG_EBX, ENEMY)
                m.cpu.reg_write(UC_X86_REG_ESI, ENEMY + 0x2E5C)
                m.cpu.reg_write(UC_X86_REG_EDI, shot_sum + circle)
                m.stops = {0x4110E5, 0x4110EC}
                m.run(0x411033)
                expected = shot_sum // divisor + circle * (4 if flags2 else 1)
                check(m.get(ENEMY + 0x2E48) == 200 - expected, f"HP divisor {divisor} raw{shot_sum} circle{circle}")
    for protection, flags in [(0, 0x41), (1, 0x49)]:
        m = Machine(image); m.put(ENEMY + 0x2E48, 20)
        m.put(ENEMY + 0x337C, flags); m.put(ENEMY + 0x53B0, protection)
        m.put(ENEMY + 0x2E5C, 30)
        m.cpu.reg_write(UC_X86_REG_EBX, ENEMY); m.cpu.reg_write(UC_X86_REG_ESI, ENEMY + 0x2E5C); m.cpu.reg_write(UC_X86_REG_EDI, 30)
        m.stops = {0x4110E5, 0x4110EC}; m.run(0x411033)
        check(m.get(ENEMY + 0x2E48) == 20, "HP protected while shot geometry still consumes")
    for flags2 in [0, 0x40, 0x1040]:
        for classification in [0, 1, 2]:
            m = Machine(image); m.put(ENEMY + 0x3380, flags2)
            m.put(ENEMY, DATA); m.put(DATA + 0x320, DATA + 0x400)
            m.cpu.reg_write(UC_X86_REG_ESI, ENEMY); m.cpu.reg_write(UC_X86_REG_EBX, classification)
            m.stops = {0x4104B4}; m.run(0x4103B7)
            check(m.spawn_count == int(flags2 != 0x40 or classification == 0), "unactivated direct-shot deaths skip circle creation")


def movement_model(vx, vy, speed, x, y, tx, ty, age, previous):
    if age < 40 or age == previous:
        return vx, vy, speed
    if tx > -900:
        dx, dy = f32(tx - x), f32(ty - y)
        distance = math.sqrt(f32(dx * dx + dy * dy))
        gain = 1 / max(distance / (speed * .25), 1)
        nx, ny = f32(vx + dx * gain), f32(vy + dy * gain)
        norm = math.sqrt(f32(nx * nx + ny * ny))
        speed = f32(max(1, min(norm, 10)))
        return f32(nx * speed / norm), f32(ny * speed / norm), speed
    if speed < 10:
        new_speed = f32(speed + f32(1 / 3))
        norm = math.sqrt(f32(vx * vx + vy * vy))
        return f32(vx * new_speed / norm), f32(vy * new_speed / norm), new_speed
    return vx, vy, speed


def movement_tests(image):
    for age, previous in [(39, 38), (40, 39), (40, 40), (41, 40)]:
        for tx, ty in [(0, -100), (100, 0), (.01, .01), (-999, -999), (-900, 0)]:
            for vx, vy, speed in [(0, -.5, .5), (6, 8, 10), (0, -9.9, 9.9)]:
                values = tuple(map(f32, (vx, vy, speed, 0, 0, tx, ty)))
                vx, vy, speed, x, y, tx, ty = values
                m = Machine(image); m.shot()
                m.f(SHOT + 0x43C, vx); m.f(SHOT + 0x440, vy); m.f(SHOT + 0x44C, speed)
                m.put(SHOT + 0x454, previous); m.put(SHOT + 0x45C, age)
                m.f(PLAYER + 0x30364, tx); m.f(PLAYER + 0x30368, ty)
                m.cpu.reg_write(UC_X86_REG_ECX, PLAYER); m.cpu.reg_write(UC_X86_REG_EDX, SHOT)
                # Angle atan2 is not needed for the next position; all velocity
                # and speed calculations through 441795 remain original x86.
                m.stops = {0x441795}; m.run(0x4415E0)
                actual = tuple(m.gf(SHOT + offset) for offset in [0x43C, 0x440, 0x44C])
                expected = movement_model(*values, age, previous)
                check(all(abs(a - b) < .00001 for a, b in zip(actual, expected)), f"Reimu original motion age{age}/{previous} target{tx,ty} speed{speed}: {actual}!={expected}")


def target_tests(image):
    # Start-address LEA and the original 128-slot increment/branch loop.
    check(image[0x10852:0x10858] == bytes.fromhex("8d9e58570000"), "enemy pool starts container+5758")
    m = Machine(image); m.cpu.reg_write(UC_X86_REG_EBX, ENEMY)
    m.cpu.reg_write(UC_X86_REG_EDI, 0); m.slot_addresses = []
    m.stops = {0x411642}; m.run(0x41086D)
    check(m.slot_addresses == [ENEMY + i * 0x5430 for i in range(128)], "actual enemy update traverses increasing pool slots")
    # Actual target selection follows even a zero-damage query. Ties retain
    # the prior (therefore lower-slot) target, not the closer-to-shot enemy.
    for candidates in [[(10, 0), (-10, 0)], [(50, 0), (0, 20)], [(0, 20), (50, 0)]]:
        m = Machine(image); m.f(PLAYER + 0x30364, -999); m.f(PLAYER + 0x30368, -999)
        m.put(DATA + 0x320, DATA + 0x400); m.put(DATA + 0x404, PLAYER)
        m.put(STACK + 0x100 - 4, DATA)
        m.stops = {0x411166}
        best, best_d = (-999, -999), 999 ** 2 * 2
        for xy in candidates:
            m.f(ENEMY + 0x2DD4, xy[0]); m.f(ENEMY + 0x2DD8, xy[1])
            m.cpu.reg_write(UC_X86_REG_EBX, ENEMY); m.cpu.reg_write(UC_X86_REG_EDI, 0)
            m.cpu.reg_write(UC_X86_REG_ESP, STACK); m.cpu.reg_write(UC_X86_REG_EBP, STACK + 0x100)
            m.run(0x411033)
            d = xy[0] ** 2 + xy[1] ** 2
            if d < best_d: best, best_d = xy, d
            check((m.gf(PLAYER + 0x30364), m.gf(PLAYER + 0x30368)) == best, "actual nearest-to-player target with lower-slot tie and zero damage")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--game-exe", type=Path, required=True)
    args = parser.parse_args()
    raw = args.game_exe.read_bytes()
    check(hashlib.sha256(raw).hexdigest() == SHA, "verified game executable hash")
    pe = pefile.PE(data=raw)
    check(pe.OPTIONAL_HEADER.ImageBase == 0x400000, "verified game image base")
    image = pe.get_memory_mapped_image()
    shot_tests(image); damage_tests(image); movement_tests(image); target_tests(image)
    print(f"native_reimu_combat_test: PASS ({checks} actual x86 geometry, consumption, HP, activation and motion checks; no game process)")


if __name__ == "__main__":
    main()
