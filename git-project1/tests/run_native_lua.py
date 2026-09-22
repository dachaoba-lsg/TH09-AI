"""Run a test in native (non-JIT) Lua 5.1, matching the runtime language.

Install test-only dependency without altering the system Python environment:
  python -m pip install --target work/lua-test-python lupa==2.8
Then, from the project root:
  python tests/run_native_lua.py tests/dodge_perf_test.lua

The performance clock is Python's monotonic, high-resolution perf_counter.
This is a native 64-bit Lua microbenchmark, not a game FPS measurement and
not the actual 32-bit injected runtime or its C++ hitTest table conversion.
"""
import argparse
import os
from pathlib import Path
import sys
import time

project = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(project / "work" / "lua-test-python"))
from lupa.lua51 import LuaRuntime  # noqa: E402

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("script", help="Lua test path, relative to project root")
parser.add_argument("--old-iterations", type=int, default=3)
parser.add_argument("--new-iterations", type=int, default=50)
options = parser.parse_args()
script = Path(options.script)
if not script.is_absolute():
    script = project / script
os.chdir(project / "src" / "ai")
lua = LuaRuntime(unpack_returned_tuples=True)
lua.globals().perf_now = time.perf_counter
lua.globals().BENCH_OLD_ITERATIONS = options.old_iterations
lua.globals().BENCH_NEW_ITERATIONS = options.new_iterations
print("Runtime: native Lua 5.1 (Lupa 2.8, 64-bit, no JIT)", flush=True)
lua.globals().dofile(str(script))
