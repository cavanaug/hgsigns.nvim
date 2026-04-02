#!/usr/bin/env bash
# Sets up throwaway hg repos used by the VHS recordings.
# Re-runnable: blows away and recreates each time.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_DIR="$SCRIPT_DIR/demo_repos"
rm -rf "$DEMO_DIR"
mkdir -p "$DEMO_DIR"

HG_USER="Demo User <demo@example.com>"
HG_DATE="2024-01-01 12:00 +0000"

# ── helpers ─────────────────────────────────────────────────────────────────
hg_init() {
  local dir="$1"
  mkdir -p "$dir"
  hg init "$dir"
  cat > "$dir/.hg/hgrc" <<EOF
[ui]
username = $HG_USER
EOF
}

hg_commit() {
  local dir="$1"; shift
  hg --cwd "$dir" commit -d "2024-01-01 12:00 +0000" -m "$@"
}

# ── demo-hunks: file with add/change/delete hunks ───────────────────────────
HUNKS="$DEMO_DIR/hunks"
hg_init "$HUNKS"

cat > "$HUNKS/demo.py" <<'EOF'
#!/usr/bin/env python3
"""Mercurial demo: hunk actions."""

import os
import sys
from pathlib import Path


def greet(name: str) -> str:
    """Return a greeting string."""
    return f"Hello, {name}!"


def farewell(name: str) -> str:
    """Return a farewell string."""
    return f"Goodbye, {name}!"


def process_items(items: list) -> list:
    """Filter and transform a list of items."""
    result = []
    for item in items:
        if item is not None:
            result.append(str(item).strip())
    return result


def read_config(path: str) -> dict:
    """Read a simple key=value config file."""
    config = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith('#'):
                key, _, value = line.partition('=')
                config[key.strip()] = value.strip()
    return config


def main():
    print(greet("world"))
    print(farewell("world"))


if __name__ == "__main__":
    main()
EOF

hg --cwd "$HUNKS" add demo.py
hg_commit "$HUNKS" "Initial commit"

# Now make changes that produce add/change/delete signs
cat > "$HUNKS/demo.py" <<'EOF'
#!/usr/bin/env python3
"""Mercurial demo: hunk actions — modified version."""

import os
import sys
import json
from pathlib import Path


def greet(name: str, formal: bool = False) -> str:
    """Return a greeting string, optionally formal."""
    if formal:
        return f"Good day, {name}."
    return f"Hello, {name}!"


def process_items(items: list) -> list:
    """Filter and transform a list of items."""
    result = []
    for item in items:
        if item is not None:
            result.append(str(item).strip())
    return result


def read_config(path: str) -> dict:
    """Read a simple key=value config file."""
    config = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith('#'):
                key, _, value = line.partition('=')
                config[key.strip()] = value.strip()
    return config


def write_config(path: str, config: dict) -> None:
    """Write a config dict to a key=value file."""
    with open(path, 'w') as f:
        for key, value in config.items():
            f.write(f"{key} = {value}\n")


def main():
    print(greet("world"))
    print(greet("Alice", formal=True))


if __name__ == "__main__":
    main()
EOF

echo "hunks repo ready: $HUNKS/demo.py"

# ── demo-blame: file with multi-author history ───────────────────────────────
BLAME="$DEMO_DIR/blame"
hg_init "$BLAME"

cat > "$BLAME/server.py" <<'EOF'
#!/usr/bin/env python3
"""Minimal HTTP request handler."""

import http.server
import socketserver
import json
import logging

PORT = 8080
logger = logging.getLogger(__name__)


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"OK")
EOF

hg --cwd "$BLAME" add server.py
HG_DATE="2023-06-01 09:00 +0000"
hg --cwd "$BLAME" commit -d "$HG_DATE" -u "Alice <alice@example.com>" -m "Initial server skeleton"

cat >> "$BLAME/server.py" <<'EOF'


def parse_body(data: bytes) -> dict:
    """Parse a JSON request body, returning {} on error."""
    try:
        return json.loads(data.decode('utf-8'))
    except (ValueError, UnicodeDecodeError):
        logger.warning("Failed to parse request body")
        return {}
EOF

HG_DATE="2023-09-15 14:30 +0000"
hg --cwd "$BLAME" commit -d "$HG_DATE" -u "Bob <bob@example.com>" -m "Add JSON body parser"

cat >> "$BLAME/server.py" <<'EOF'


class RateLimitedHandler(Handler):
    """Handler with per-IP rate limiting."""

    _requests: dict = {}
    LIMIT = 100  # requests per minute

    def do_GET(self):
        ip = self.client_address[0]
        count = self._requests.get(ip, 0) + 1
        self._requests[ip] = count
        if count > self.LIMIT:
            self.send_response(429)
            self.end_headers()
            return
        super().do_GET()
EOF

HG_DATE="2023-12-20 11:00 +0000"
hg --cwd "$BLAME" commit -d "$HG_DATE" -u "Carol <carol@example.com>" -m "Add rate limiting"

cat >> "$BLAME/server.py" <<'EOF'


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    with socketserver.TCPServer(("", PORT), RateLimitedHandler) as httpd:
        logger.info("Serving on port %d", PORT)
        httpd.serve_forever()
EOF

HG_DATE="2024-03-10 16:45 +0000"
hg --cwd "$BLAME" commit -d "$HG_DATE" -u "Demo User <demo@example.com>" -m "Add main entry point"

echo "blame repo ready: $BLAME/server.py"
echo "Done."
