#!/usr/bin/env python3
"""Run pure Lua regression tests without a Factorio installation or server.

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
lua.execute((ROOT / "test/unit.lua").read_text())
