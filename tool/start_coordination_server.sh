#!/bin/sh
# Start the agent-signer coordination server with a chosen token, port, and
# optional persistent store, then print the URL the demo and agent connect to.
#
# Usage:
#   tool/start_coordination_server.sh --token <token> [--port <n>] [--store <path>]
#
# Configuration (flags take precedence over the matching environment variable):
#   --token <token>   COORDINATION_TOKEN   bearer token (required, no default)
#   --port  <n>       PORT                 TCP port (default 8787)
#   --store <path>    COORDINATION_STORE   JSON file to persist requests (optional)
#
# The token is never hard-coded here: supply it via --token or COORDINATION_TOKEN.
# For local development the demo and agent default to the well-known token
# "dev-token-change-me"; pass that value here to match. Use a strong, secret
# value in any shared environment.
#
# The server binds 0.0.0.0 so it is reachable from emulators, devices, and
# browsers on the LAN. For a physical device, point the demo at this host's LAN
# IP via --dart-define=COORDINATION_URL=http://<lan-ip>:<port>.

set -eu

usage() {
  # Print the leading comment block (from line 2 until the first non-comment
  # line), stripping the leading "# ".
  awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"
  exit "${1:-0}"
}

# Resolve the coordination_server directory relative to this script.
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_DIR=$(dirname "$SCRIPT_DIR")
SERVER_DIR="$REPO_DIR/coordination_server"

TOKEN="${COORDINATION_TOKEN:-}"
PORT="${PORT:-8787}"
STORE="${COORDINATION_STORE:-}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --token)
      [ "$#" -ge 2 ] || { echo "error: --token needs a value" >&2; exit 2; }
      TOKEN="$2"; shift 2 ;;
    --token=*) TOKEN="${1#--token=}"; shift ;;
    --port)
      [ "$#" -ge 2 ] || { echo "error: --port needs a value" >&2; exit 2; }
      PORT="$2"; shift 2 ;;
    --port=*) PORT="${1#--port=}"; shift ;;
    --store)
      [ "$#" -ge 2 ] || { echo "error: --store needs a value" >&2; exit 2; }
      STORE="$2"; shift 2 ;;
    --store=*) STORE="${1#--store=}"; shift ;;
    -h|--help) usage 0 ;;
    *) echo "error: unknown argument '$1'" >&2; usage 2 ;;
  esac
done

if [ -z "$TOKEN" ]; then
  echo "error: no bearer token. Pass --token <value> or set COORDINATION_TOKEN." >&2
  echo "       (local development default: dev-token-change-me)" >&2
  exit 2
fi

if ! command -v dart >/dev/null 2>&1; then
  echo "error: 'dart' not found on PATH. Add the Flutter/Dart SDK bin to PATH." >&2
  exit 127
fi

if [ ! -d "$SERVER_DIR" ]; then
  echo "error: coordination_server directory not found at $SERVER_DIR" >&2
  exit 1
fi

cd "$SERVER_DIR"

# Resolve dependencies on first run (no-op once .dart_tool is populated).
if [ ! -f ".dart_tool/package_config.json" ]; then
  echo "Resolving coordination_server dependencies (dart pub get)..."
  dart pub get
fi

echo "Starting coordination_server on http://localhost:${PORT}"
echo "  bind:  0.0.0.0:${PORT} (reachable on the LAN)"
if [ -n "$STORE" ]; then
  echo "  store: ${STORE} (persistent)"
else
  echo "  store: in-memory only"
fi
echo "  token: (provided; matches COORDINATION_TOKEN on the agent/demo)"
echo "Stop with Ctrl-C."

set -- --token "$TOKEN" --port "$PORT"
if [ -n "$STORE" ]; then
  set -- "$@" --store "$STORE"
fi

# exec so Ctrl-C / SIGTERM reach the server directly for a clean shutdown.
exec dart run bin/server.dart "$@"
