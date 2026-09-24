#!/usr/bin/env bash
# Uses only the isolated test engine, ports and disposable map from lib.sh.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
setup_sandbox
trap stop_server EXIT
start_server
python3 "$ROOT/test/rcon.py" '/silent-command rcon.print("warmup")' >/dev/null
python3 - "$ROOT" <<'PY'
from pathlib import Path
import subprocess
import sys

root = Path(sys.argv[1])
body = (root / 'test/bench-rosters.lua').read_text()
command = ('/silent-command __tank-squads__ local ok,result=pcall(function() '
           + body + ' end) rcon.print(ok and result or ("FAIL: "..tostring(result)))')
result = subprocess.run([sys.executable, str(root / 'test/rcon.py'), command],
                        capture_output=True, text=True, check=True)
print(result.stdout, end='')
if 'FAIL:' in result.stdout or 'PASS roster benchmarks completed' not in result.stdout:
    sys.exit(1)
PY
