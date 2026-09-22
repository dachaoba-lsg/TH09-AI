"""Read-only TH09 v1.50a telemetry. Never injects, writes process memory or sends input.

Known offsets are from vendor/ka_ai_duka-src/inject/th09types.h and th09address.h,
plus the state field confirmed at original 0x435EC0 (mov eax,[ecx]).
"""
import argparse
import ctypes as c
from ctypes import wintypes as w
import json
import math
from pathlib import Path
import struct
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument("--expected-exe", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--seconds", type=float, default=45)
    args = parser.parse_args()
    if not 0 < args.seconds <= 45:
        raise SystemExit("Duration must be in (0, 45] seconds")
    kernel = c.WinDLL("kernel32", use_last_error=True)
    kernel.OpenProcess.argtypes = [w.DWORD, w.BOOL, w.DWORD]
    kernel.OpenProcess.restype = w.HANDLE
    kernel.CloseHandle.argtypes = [w.HANDLE]
    kernel.QueryFullProcessImageNameW.argtypes = [w.HANDLE, w.DWORD, w.LPWSTR, c.POINTER(w.DWORD)]
    kernel.GetExitCodeProcess.argtypes = [w.HANDLE, c.POINTER(w.DWORD)]
    kernel.ReadProcessMemory.argtypes = [w.HANDLE, c.c_void_p, c.c_void_p, c.c_size_t, c.POINTER(c.c_size_t)]
    handle = kernel.OpenProcess(0x0010 | 0x1000, False, args.pid)  # VM_READ | QUERY_LIMITED_INFORMATION only.
    if not handle:
        raise c.WinError(c.get_last_error())
    try:
        size = w.DWORD(32768)
        name = c.create_unicode_buffer(size.value)
        if not kernel.QueryFullProcessImageNameW(handle, 0, name, c.byref(size)):
            raise c.WinError(c.get_last_error())
        if Path(name.value).resolve() != args.expected_exe.resolve():
            raise SystemExit(f"Refusing unexpected process path: {name.value}")
        def read(address, count):
            result = c.create_string_buffer(count)
            actual = c.c_size_t()
            if not kernel.ReadProcessMemory(handle, address, result, count, c.byref(actual)) or actual.value != count:
                raise OSError(f"ReadProcessMemory failed at 0x{address:08X}: {c.get_last_error()}")
            return result.raw
        def player(side):
            address = struct.unpack("<I", read(0x4A7D94 + side * 0x38, 4))[0]
            if address < 0x10000:
                return {"available": False, "pointer": address}
            head = read(address, 0xB0)
            actual_side = struct.unpack_from("<I", head, 8)[0]
            if actual_side != side:
                return {"available": False, "pointer": address, "unexpected_side": actual_side}
            position = struct.unpack("<fff", read(address + 0x1B88, 12))
            if not all(math.isfinite(value) for value in position):
                return {"available": False, "pointer": address, "position_nonfinite": True}
            combo, unknown, spell = struct.unpack("<III", read(address + 0x30414, 12))
            return {"available": True, "pointer": address, "side": side,
                    "state": struct.unpack_from("<I", head, 0)[0],
                    "hp": struct.unpack_from("<I", head, 0xA8)[0],
                    "combo": combo, "spell_point": spell, "position": position}
        print(json.dumps({"verified_pid": args.pid, "exe": name.value, "seconds": args.seconds}, ensure_ascii=False), flush=True)
        started = time.perf_counter()
        previous = None
        total = 0
        with args.output.open("x", encoding="utf-8") as output:
            while time.perf_counter() - started < args.seconds:
                exit_code = w.DWORD()
                if not kernel.GetExitCodeProcess(handle, c.byref(exit_code)) or exit_code.value != 259:
                    print("STOP: verified process exited; no replacement process will be opened", flush=True)
                    break
                row = {"elapsed": round(time.perf_counter() - started, 4), "pid": args.pid}
                for side in (0, 1):
                    try:
                        row[f"p{side + 1}"] = player(side)
                    except OSError as error:
                        row[f"p{side + 1}"] = {"available": False, "read_error": str(error)}
                output.write(json.dumps(row, ensure_ascii=False) + "\n")
                total += 1
                current = tuple((row[f"p{i}"].get("state"), row[f"p{i}"].get("hp")) for i in (1, 2))
                if current != previous:
                    print(json.dumps(row, ensure_ascii=False), flush=True)
                    output.flush()
                    previous = current
                time.sleep(1 / 60)
        print(json.dumps({"samples": total, "output": str(args.output)}, ensure_ascii=False), flush=True)
    finally:
        kernel.CloseHandle(handle)


if __name__ == "__main__":
    main()
