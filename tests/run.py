"""AuctionJudge tests under Lua 5.1 (lupa).

1. Syntax check: every .lua in AuctionJudge/ must compile with Lua 5.1.
2. Unit tests of the pure model and the item search queue (test_model.lua, test_queue.lua).
3. Smoke test: the whole addon in a fake client (smoke.lua).

Setup: py -3.13 -m venv tests\\.venv && tests\\.venv\\Scripts\\python.exe -m pip install lupa
Run:   tests\\.venv\\Scripts\\python.exe tests\\run.py
"""
import pathlib
import sys

from lupa import lua51

ROOT = pathlib.Path(__file__).resolve().parent.parent
ADDON = ROOT / "AuctionJudge"
TESTS = ROOT / "tests"
SUITES = ["test_model.lua", "test_queue.lua", "test_level.lua", "smoke.lua"]


def runtime():
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    lua.globals().ROOT = ROOT.as_posix()
    return lua


def syntax_check():
    lua = runtime()
    compile_ = lua.eval("function(src, name) local f, err = loadstring(src, '@' .. name); return err end")
    failures = 0
    files = sorted(ADDON.glob("*.lua"))
    for path in files:
        err = compile_(path.read_text(encoding="utf-8"), path.name)
        if err:
            failures += 1
            print(f"  FAIL {path.name}: {err}")
    print(f"syntax: {len(files) - failures}/{len(files)} files compile")
    return failures + (0 if files else 1)


def run_suite(name):
    lua = runtime()
    run = lua.eval(
        "function(harness, suite) local H = dofile(harness); local f = assert(loadfile(suite)); return f(H) end"
    )
    H = run((TESTS / "harness.lua").as_posix(), (TESTS / name).as_posix())
    results = H.results
    failures = 0
    total = len(results)
    for i in range(1, total + 1):
        r = results[i]
        if r.ok:
            print(f"  ok   {r.name}")
        else:
            failures += 1
            print(f"  FAIL {r.name}\n       {r.err}")
    print(f"{name}: {total - failures}/{total} passed")
    return failures


def main():
    failures = syntax_check()
    for suite in SUITES:
        print()
        try:
            failures += run_suite(suite)
        except Exception as exc:  # a suite that cannot even load
            failures += 1
            print(f"  FAIL {suite} did not run: {exc}")
    print()
    print("ALL PASSED" if failures == 0 else f"{failures} FAILURE(S)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
