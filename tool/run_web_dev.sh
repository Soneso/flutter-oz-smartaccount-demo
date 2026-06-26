#!/usr/bin/env bash
# Builds and serves the Flutter web bundle on http://127.0.0.1:5173.
#
# Usage:
#   ./tool/run_web_dev.sh                      — build and start the server
#   WEB_BUILD_MODE=debug ./tool/run_web_dev.sh — build a debug bundle (required
#                                                for the agent-flow approval inbox)
#   ./tool/run_web_dev.sh stop                 — kill a previously started server
#
# WEB_BUILD_MODE selects the build mode (release default, or debug/profile). The
# agent-signer approval inbox requires a DEBUG build: its ship-blocker guard
# (coordinationConfigShipBlocker in lib/config/demo_config.dart) refuses the
# local dev coordination token and non-HTTPS coordination URL in release/profile
# builds, so the inbox cannot start there.
#
# Runs `flutter build web --<mode> --pwa-strategy=none --dart-define=RP_ID=<value>` to produce
# the static bundle under build/web/, then serves it via Python's stdlib
# http.server. The Python server is fully detached from the launching shell
# so it survives parent process exit (unlike `flutter run -d web-server`,
# which exits the moment its stdin closes).
#
# The server PID is saved to tool/.web_dev.pid so the stop sub-command can
# terminate it cleanly. The .pid file is excluded from git via .gitignore.
#
# For incremental dev iteration with hot reload, run `flutter run -d chrome`
# (or `-d web-server`) interactively from your own terminal instead.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "${SCRIPT_DIR}")"
PID_FILE="${SCRIPT_DIR}/.web_dev.pid"

stop_server() {
  if [ -f "${PID_FILE}" ]; then
    local pid
    pid="$(cat "${PID_FILE}")"
    if kill -0 "${pid}" 2>/dev/null; then
      echo "Stopping web dev server (PID ${pid})..."
      kill "${pid}"
      rm -f "${PID_FILE}"
      echo "Server stopped."
    else
      echo "No running server found for PID ${pid}."
      rm -f "${PID_FILE}"
    fi
  else
    echo "No PID file found. Server may not be running."
  fi
}

if [ "${1:-}" = "stop" ]; then
  stop_server
  exit 0
fi

# Ensure any previous server is stopped before starting a new one.
if [ -f "${PID_FILE}" ]; then
  old_pid="$(cat "${PID_FILE}")"
  if kill -0 "${old_pid}" 2>/dev/null; then
    echo "Stopping previous server (PID ${old_pid})..."
    kill "${old_pid}"
    sleep 1
  fi
  rm -f "${PID_FILE}"
fi

cd "${REPO_DIR}"

# RP_ID defaults to localhost so WebAuthn ceremonies succeed when the page is
# served from 127.0.0.1. Override by setting RP_ID in the environment before
# launching this script (for example RP_ID=demo.example.com when serving over
# HTTPS from a registered subdomain).
RP_ID="${RP_ID:-localhost}"
LOG_FILE="${SCRIPT_DIR}/.web_dev.log"

# Build mode: release (default), debug, or profile. Use WEB_BUILD_MODE=debug for
# the agent-flow approval inbox (the ship-blocker guard rejects the local dev
# coordination token / non-HTTPS URL outside debug builds).
BUILD_MODE="${WEB_BUILD_MODE:-release}"
case "${BUILD_MODE}" in
  release|debug|profile) ;;
  *)
    echo "Invalid WEB_BUILD_MODE='${BUILD_MODE}' (expected release, debug, or profile)." >&2
    exit 2
    ;;
esac

echo "Building Flutter web bundle (mode=${BUILD_MODE}, RP_ID=${RP_ID})..." | tee "${LOG_FILE}"
# --pwa-strategy=none disables the service worker registration so the
# browser does not cache stale shells between dev iterations.
if ! flutter build web --"${BUILD_MODE}" --pwa-strategy=none \
    --dart-define=RP_ID="${RP_ID}" \
    >> "${LOG_FILE}" 2>&1; then
  echo "flutter build web failed. See ${LOG_FILE} for compile output." >&2
  exit 1
fi
echo "Build complete." | tee -a "${LOG_FILE}"

echo "Starting static server at http://127.0.0.1:5173 ..." | tee -a "${LOG_FILE}"

# Detach from the launching shell so the server survives after this script
# exits. Python's http.server has no interactive prompt, so just redirect
# stdin/stdout/stderr and disown.
nohup python3 -m http.server 5173 \
  --bind localhost \
  --directory "${REPO_DIR}/build/web" \
  < /dev/null >> "${LOG_FILE}" 2>&1 &

SERVER_PID=$!
echo "${SERVER_PID}" > "${PID_FILE}"
disown "${SERVER_PID}" 2>/dev/null || true
echo "Server started (PID ${SERVER_PID}). Logs: ${LOG_FILE}"
echo "Stop with: ./tool/run_web_dev.sh stop"
