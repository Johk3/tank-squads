#!/usr/bin/env python3
"""Run pure Lua regression tests without a Factorio installation or server.

Usage: python3 test/unit.py [-v] [FILTER]
Prints only failures and a summary. FILTER runs only the tests whose name
contains it, such as "rings:". -v also prints a line for every passing test.

Requires lupa (pip install lupa), or a local copy under test/.work/python.
The tests replace only the Factorio API boundary, not the mod modules.
"""
from pathlib import Path
import os
import sys

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "test/.work/python"))
try:
    from lupa.lua52 import LuaRuntime
except ImportError:
    sys.exit("Install lupa to run the server-free Lua regression tests.")
os.chdir(ROOT)
lua = LuaRuntime(unpack_returned_tuples=True)
args = sys.argv[1:]
if "-v" in args:
    args.remove("-v")
    lua.globals().UNIT_VERBOSE = True
if len(args) > 1:
    sys.exit("usage: python3 test/unit.py [-v] [FILTER]")
if args:
    lua.globals().UNIT_FILTER = args[0]
lua.execute((ROOT / "test/unit.lua").read_text())
