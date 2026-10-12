"""Runs tests/run.lua under Lua 5.1 and LuaJIT 2.1 via the lupa package.

    pip install lupa
    python tests/run_lupa.py
"""
import importlib
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
RUNTIMES = ["lupa.lua51", "lupa.luajit21"]

failed = 0
for name in RUNTIMES:
    try:
        lua = importlib.import_module(name).LuaRuntime()
    except ImportError:
        print(f"{name}: not available, skipped")
        continue
    lua.globals().ROOT = str(ROOT)
    print(f"== {name} ({lua.eval('_VERSION')})")
    failed += lua.eval(f"dofile([[{ROOT / 'tests' / 'run.lua'}]])") or 0
sys.exit(1 if failed else 0)
