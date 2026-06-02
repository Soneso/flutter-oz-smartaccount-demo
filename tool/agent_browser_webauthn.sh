#!/usr/bin/env bash
# Standalone wrapper for agent-browser WebAuthn virtual-authenticator testing.
#
# Attaches a Chromium virtual authenticator to the given agent-browser session
# via the Chrome DevTools Protocol (CDP), runs a wrapped command or interactive
# shell, then detaches the authenticator automatically on exit.
#
# Usage:
#   ./tool/agent_browser_webauthn.sh --session <name> [-- <command> [args...]]
#
# Arguments:
#   --session <name>   agent-browser session name (e.g. smart-account-demo)
#   --                 separator; everything after is the command to run
#                      (omit to drop into an interactive bash shell)
#
# Environment variables:
#   AGENT_BROWSER_CDP_PORT       CDP port for the agent-browser (default: 9222)
#   AGENT_BROWSER_DEV_URL_PREFIX URL prefix to filter valid page targets
#                                (default: http://127.0.0.1:5173/)
#
# Examples:
#   # Open a session, attach virtual authenticator, run a snapshot:
#   ./tool/agent_browser_webauthn.sh --session demo -- \
#       agent-browser --session demo snapshot
#
#   # Start an interactive session with the virtual authenticator attached:
#   ./tool/agent_browser_webauthn.sh --session demo
#
# How it works:
#   1. Queries CDP /json/list for page targets whose URL starts with
#      AGENT_BROWSER_DEV_URL_PREFIX (exactly one match required).
#   2. Sends a WebAuthn.enable + WebAuthn.addVirtualAuthenticator CDP command
#      to that page target via the Python websockets library.
#   3. Runs the inner command (or drops into bash).
#   4. Sends WebAuthn.removeVirtualAuthenticator on EXIT trap.
#
# Requirements:
#   - Python 3 with the 'websockets' package (pip install websockets)
#   - curl on PATH
#
# Limitations documented in tool/README.md:
#   - Virtual authenticator credentials are ephemeral: they exist only for the
#     duration of this script. Credentials do not persist to IndexedDB.
#   - Only one virtual authenticator can be active per page target.
#   - Multi-signer flows requiring two identities cannot be tested with a
#     single virtual authenticator.

set -euo pipefail

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

SESSION_NAME=""
INNER_CMD=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --session)
      SESSION_NAME="$2"
      shift 2
      ;;
    --)
      shift
      INNER_CMD=("$@")
      break
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [ -z "${SESSION_NAME}" ]; then
  echo "Usage: $0 --session <name> [-- <command> [args...]]" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

CDP_PORT="${AGENT_BROWSER_CDP_PORT:-9222}"
DEV_URL_PREFIX="${AGENT_BROWSER_DEV_URL_PREFIX:-http://127.0.0.1:5173/}"

# ---------------------------------------------------------------------------
# Locate the page WebSocket URL via CDP /json/list
#
# Filters to targets whose URL starts with DEV_URL_PREFIX to avoid attaching
# to unrelated browser windows (personal tabs, other devtools sessions, etc.).
# Exactly one matching target is required — zero or multiple both fail loudly.
# ---------------------------------------------------------------------------

echo "Querying CDP at 127.0.0.1:${CDP_PORT} for dev target (prefix: ${DEV_URL_PREFIX})..."

# Capture the full JSON list so we can surface useful diagnostics on failure.
JSON_LIST=$(curl -s "http://127.0.0.1:${CDP_PORT}/json/list" 2>/dev/null || echo "[]")

# Extract matching targets: url, webSocketDebuggerUrl pairs.
MATCHED=$(python3 - "${DEV_URL_PREFIX}" <<'PYEOF'
import sys, json

prefix = sys.argv[1]
raw = sys.stdin.read().strip()
try:
    targets = json.loads(raw)
except json.JSONDecodeError:
    targets = []

matches = [
    t for t in targets
    if t.get("type") == "page" and t.get("url", "").startswith(prefix)
]

for m in matches:
    print(m.get("url", ""), m.get("webSocketDebuggerUrl", ""))
PYEOF
<<< "${JSON_LIST}")

MATCH_COUNT=$(echo "${MATCHED}" | grep -c . || true)

if [ "${MATCH_COUNT}" -eq 0 ]; then
  echo "Error: no page target found whose URL starts with '${DEV_URL_PREFIX}'." >&2
  echo "  Ensure the dev server is running: ./tool/run_web_dev.sh" >&2
  echo "  Then open the app at ${DEV_URL_PREFIX} in the agent-browser session." >&2
  exit 1
fi

if [ "${MATCH_COUNT}" -gt 1 ]; then
  echo "Error: multiple page targets match '${DEV_URL_PREFIX}':" >&2
  while IFS= read -r line; do
    TARGET_URL=$(echo "${line}" | awk '{print $1}')
    echo "  ${TARGET_URL}" >&2
  done <<< "${MATCHED}"
  echo "Close the extra tabs and retry." >&2
  exit 1
fi

# Extract the WebSocket URL from the single matching line.
PAGE_WS_URL=$(echo "${MATCHED}" | awk '{print $2}')

if [ -z "${PAGE_WS_URL}" ]; then
  echo "Error: matched target has no webSocketDebuggerUrl." >&2
  echo "  The browser may not have been started with --remote-debugging-port=${CDP_PORT}." >&2
  exit 1
fi

echo "Found dev target: $(echo "${MATCHED}" | awk '{print $1}')"
echo "WebSocket URL: ${PAGE_WS_URL}"

# ---------------------------------------------------------------------------
# CDP helper: send a command and read the response
#
# The WebSocket URL is passed via sys.argv to avoid shell string interpolation
# inside the Python source, which would allow a malicious local CDP response
# to inject code into the embedded Python script.
# ---------------------------------------------------------------------------

AUTHENTICATOR_ID=""

cdp_send() {
  local payload="$1"
  python3 - "${PAGE_WS_URL}" <<PYEOF
import asyncio, json, sys

ws_url = sys.argv[1]
payload = '''${payload}'''

try:
    import websockets
except ImportError:
    print(json.dumps({"error": "websockets not installed — run: pip install websockets"}))
    sys.exit(1)

async def send():
    async with websockets.connect(ws_url) as ws:
        await ws.send(payload)
        resp = await asyncio.wait_for(ws.recv(), timeout=5)
        print(resp)

asyncio.run(send())
PYEOF
}

# ---------------------------------------------------------------------------
# Attach virtual authenticator
# ---------------------------------------------------------------------------

attach_authenticator() {
  echo "Enabling WebAuthn virtual environment..."
  cdp_send '{"id":1,"method":"WebAuthn.enable","params":{"enableUI":false}}' > /dev/null

  echo "Adding virtual authenticator (ctap2, internal, resident keys)..."
  response=$(cdp_send '{
    "id": 2,
    "method": "WebAuthn.addVirtualAuthenticator",
    "params": {
      "options": {
        "protocol": "ctap2",
        "transport": "internal",
        "hasResidentKey": true,
        "hasUserVerification": true,
        "isUserVerified": true
      }
    }
  }')

  AUTHENTICATOR_ID=$(python3 -c "
import sys, json
d = json.loads(sys.stdin.read())
print(d.get('result', {}).get('authenticatorId', ''))
" <<< "${response}" 2>/dev/null || echo "")

  if [ -z "${AUTHENTICATOR_ID}" ]; then
    echo "Warning: could not retrieve authenticator ID from response:" >&2
    echo "${response}" >&2
  else
    echo "Virtual authenticator attached (ID: ${AUTHENTICATOR_ID})"
  fi
}

# ---------------------------------------------------------------------------
# Cleanup on exit
# ---------------------------------------------------------------------------

detach_authenticator() {
  if [ -n "${AUTHENTICATOR_ID}" ]; then
    echo "Removing virtual authenticator (ID: ${AUTHENTICATOR_ID})..."
    cdp_send "{\"id\":3,\"method\":\"WebAuthn.removeVirtualAuthenticator\",\
\"params\":{\"authenticatorId\":\"${AUTHENTICATOR_ID}\"}}" > /dev/null || true
    echo "Virtual authenticator removed."
  fi
}

trap detach_authenticator EXIT

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

attach_authenticator

if [ "${#INNER_CMD[@]}" -gt 0 ]; then
  echo "Running: ${INNER_CMD[*]}"
  "${INNER_CMD[@]}"
else
  echo ""
  echo "Virtual authenticator is active. Entering interactive shell."
  echo "Exit the shell to remove the authenticator."
  echo ""
  bash
fi
