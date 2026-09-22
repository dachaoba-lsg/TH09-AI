"""Run every offline Lua regression in a fresh native Lua 5.1 process.

Works from any working directory. Logs and JSON results are written below
work/test-results (ignored by Git). This does not start or access the game.
Install the isolated test dependency from the repository root first:
  python -m pip install --target work/lua-test-python lupa==2.8
Then run:
  python tests/run_all_lua.py
  python tests/run_all_lua.py --list

Historical snapshots under work/ are optional and are not distributed. Missing
snapshot comparisons are reported as SKIP; current-version assertions still run.
Performance timings are synthetic native 64-bit Lua timings, not game FPS.
"""

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time


PROJECT = Path(__file__).resolve().parent.parent
TESTS = PROJECT / "tests"
HELPERS = {"upstream_hit_test.lua"}  # Returns a hitTest function, not a suite.
OPTIONAL_BASELINE = re.compile(r'''(?:old_path|baseline_path)\s*=\s*["'](\.\./\.\./work/[^"']+)["']''')


def positive_int(value):
    result = int(value)
    if result < 1:
        raise argparse.ArgumentTypeError("must be at least 1")
    return result


def baselines_for(script):
    rows = []
    for value in sorted(set(OPTIONAL_BASELINE.findall(script.read_text(encoding="utf-8-sig")))):
        path = (PROJECT / "src" / "ai" / value).resolve()
        rows.append({"path": path.relative_to(PROJECT).as_posix(), "available": path.is_file()})
    return rows


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--list", action="store_true", help="list suites and baseline availability without importing Lupa")
    parser.add_argument("--old-iterations", type=positive_int, default=3, help="old-version benchmark iterations (default: 3)")
    parser.add_argument("--new-iterations", type=positive_int, default=50, help="current-version benchmark iterations (default: 50)")
    parser.add_argument("--timeout", type=positive_int, default=600, help="timeout in seconds per suite (default: 600)")
    args = parser.parse_args()
    scripts = sorted(path for path in TESTS.glob("*_test.lua") if path.name not in HELPERS)
    if not scripts:
        parser.error("no Lua regression suites found")
    baseline_map = {script.name: baselines_for(script) for script in scripts}
    skipped = [{"suite": suite, **row} for suite, rows in baseline_map.items() for row in rows if not row["available"]]
    print(f"Offline suites: {len(scripts)}; helper excluded: upstream_hit_test.lua", flush=True)
    for row in skipped:
        print(f"SKIP optional historical comparison: {row['suite']} -> {row['path']}", flush=True)
    if skipped:
        print("Current-version checks will still run. Historical old-time columns of 0 mean unavailable, not measured.", flush=True)
    if args.list:
        for script in scripts:
            print(script.relative_to(PROJECT).as_posix())
        print("LIST ONLY: no tests were executed.")
        return 0

    dependency = PROJECT / "work" / "lua-test-python"
    # Require this repository's isolated dependency, not a coincidental global
    # installation with another Lupa version or a different Lua backend.
    probe = (
        "import pathlib,sys; root=pathlib.Path(sys.argv[1]).resolve(); "
        "sys.path.insert(0,str(root)); import lupa; "
        "assert pathlib.Path(lupa.__file__).resolve().is_relative_to(root), 'Lupa is not installed in work/lua-test-python'; "
        "assert lupa.__version__ == '2.8', 'Expected Lupa 2.8, found '+lupa.__version__; "
        "from lupa.lua51 import LuaRuntime; "
        "assert LuaRuntime().eval('_VERSION') == 'Lua 5.1'"
    )
    checked = subprocess.run([sys.executable, "-c", probe, str(dependency)], cwd=PROJECT, capture_output=True, text=True)
    if checked.returncode:
        print("Test dependency unavailable. From this repository root run:", file=sys.stderr)
        print("  python -m pip install --target work/lua-test-python lupa==2.8", file=sys.stderr)
        print(checked.stderr.strip(), file=sys.stderr)
        return 2

    run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ") + f"-{os.getpid()}"
    log_dir = PROJECT / "work" / "test-results" / run_id
    log_dir.mkdir(parents=True)
    environment = dict(os.environ, PYTHONIOENCODING="utf-8")
    results = []
    for index, script in enumerate(scripts, 1):
        command = [sys.executable, str(TESTS / "run_native_lua.py"), str(script),
                   "--old-iterations", str(args.old_iterations), "--new-iterations", str(args.new_iterations)]
        log = log_dir / (script.stem + ".log")
        started = time.perf_counter()
        print(f"[{index}/{len(scripts)}] {script.name}", flush=True)
        with log.open("w", encoding="utf-8", newline="\n") as output:
            for row in baseline_map[script.name]:
                if not row["available"]:
                    output.write(f"SKIP optional historical comparison: {row['path']}\n")
            output.flush()
            try:
                completed = subprocess.run(command, cwd=PROJECT, env=environment, stdout=output,
                                           stderr=subprocess.STDOUT, timeout=args.timeout)
                code = completed.returncode
            except subprocess.TimeoutExpired:
                code = 124
                output.write(f"\nFAIL: suite timed out after {args.timeout} seconds\n")
            except OSError as error:
                code = 125
                output.write(f"\nFAIL: could not start helper: {error}\n")
        elapsed = round(time.perf_counter() - started, 3)
        results.append({"suite": script.name, "exit_code": code, "elapsed_seconds": elapsed,
                        "log": log.relative_to(PROJECT).as_posix(), "optional_baselines": baseline_map[script.name]})
        print(f"  {'PASS' if code == 0 else 'FAIL'} ({elapsed:.3f}s)", flush=True)
        if code:
            print("\n".join(log.read_text(encoding="utf-8", errors="replace").splitlines()[-12:]), flush=True)

    failures = [row for row in results if row["exit_code"]]
    summary = {"runtime": "Lupa 2.8 / native Lua 5.1 / 64-bit / no JIT", "suite_count": len(results),
               "passed": len(results) - len(failures), "failed": len(failures),
               "old_iterations": args.old_iterations, "new_iterations": args.new_iterations,
               "optional_historical_comparisons_skipped": skipped, "results": results}
    (log_dir / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Result: {summary['passed']}/{len(results)} suites passed; {len(failures)} failed; "
          f"{len(skipped)} optional historical comparisons skipped.", flush=True)
    print(f"Logs: {log_dir}", flush=True)
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
