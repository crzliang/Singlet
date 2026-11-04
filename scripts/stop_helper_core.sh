#!/bin/bash
# Free Clash API / mixed ports held by Privileged Helper.
set -euo pipefail
python3 - <<'PY'
import json, socket, sys

def rpc(obj):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(5)
    s.connect("/var/run/com.singlet.helper.sock")
    s.sendall((json.dumps(obj) + "\n").encode())
    data = s.recv(8192).decode()
    s.close()
    print(data.strip())
    return json.loads(data.strip().split("\n")[0])

try:
    print("status:", end=" ")
    rpc({"op": "status"})
    print("stop:", end=" ")
    rpc({"op": "stop"})
    print("status:", end=" ")
    rpc({"op": "status"})
except Exception as e:
    print(f"helper rpc failed: {e}", file=sys.stderr)
    sys.exit(1)
PY

echo "--- listeners ---"
lsof -nP -iTCP:9090 -sTCP:LISTEN 2>/dev/null || echo "9090 free"
lsof -nP -iTCP:7890 -sTCP:LISTEN 2>/dev/null || echo "7890 free"
lsof -nP -iTCP:17890 -sTCP:LISTEN 2>/dev/null || echo "17890 free"
