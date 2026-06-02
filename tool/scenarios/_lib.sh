#!/usr/bin/env bash
# Shared helpers for browser-test scenarios under tool/scenarios/.
#
# Source this file from each scenario script:
#
#   #!/usr/bin/env bash
#   set -euo pipefail
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "${SCRIPT_DIR}/_lib.sh"
#   scenario_init "main_load"
#
# scenario_init creates the artifact directory and sets the following exports:
#   SCENARIO_NAME         — passed-in name
#   SESSION_NAME          — derived agent-browser session name
#   BASE_URL              — dev server URL (http://127.0.0.1:5173)
#   ARTIFACT_DIR          — tool/scenarios/artifacts/<scenario>-<UTC-timestamp>/
#   REPO_DIR              — flutter-oz-smartaccount-demo repo root
#
# Helpers (all expect SESSION_NAME and ARTIFACT_DIR to be set):
#   ensure_dev_server            — start tool/run_web_dev.sh if not already up; poll until ready
#   open_app                     — agent-browser open BASE_URL
#   close_session                — agent-browser close on the current session
#   body_text                    — print current page body text
#   log_box                      — print current .log-box text (empty string if no such element)
#   snapshot                     — print interactive accessibility snapshot
#   screenshot <name>            — write screenshot to ARTIFACT_DIR/<name>.png
#   dump_diagnostics             — capture screenshot + body text + snapshot for failure triage
#   wait_for_body_pattern <re> <attempts>
#                                — poll body text until regex matches; returns 0 on hit, 1 on timeout
#   assert_body_contains <text> [<text> ...]
#                                — fail the scenario if any literal text is missing from body
#   scenario_pass                — print PASS line and exit 0
#   scenario_fail <message>      — dump_diagnostics, print FAIL line, exit 1

# Resolve repo root from the location of this lib file.
__LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${__LIB_DIR}/../.." && pwd)"

# WebAuthn requires the rpId (defaults to "localhost" via tool/run_web_dev.sh)
# to be a registrable suffix of the origin's effective domain. IP addresses
# are not valid rpId derivations, so the page must be served at
# http://localhost:5173/ rather than http://127.0.0.1:5173/ even though both
# resolve to the same loopback address.
BASE_URL="${BASE_URL:-http://localhost:5173}"

scenario_init() {
  local name="$1"
  if [[ -z "${name}" ]]; then
    echo "scenario_init: missing scenario name" >&2
    return 2
  fi
  SCENARIO_NAME="${name}"
  SESSION_NAME="smartaccount-${name}"
  local ts
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  ARTIFACT_DIR="${REPO_DIR}/tool/scenarios/artifacts/${name}-${ts}"
  mkdir -p "${ARTIFACT_DIR}"
  echo "Scenario:   ${SCENARIO_NAME}"
  echo "Session:    ${SESSION_NAME}"
  echo "Artifacts:  ${ARTIFACT_DIR}"
  echo "Base URL:   ${BASE_URL}"
  # Always install the cleanup trap: even scenarios that never attach a
  # virtual authenticator open an agent-browser session that holds a
  # long-lived Chrome instance (30+ helper processes, hundreds of MB of
  # resident memory). The trap closes the session on any exit path so
  # repeated runs do not accumulate orphan browser instances.
  trap scenario_cleanup EXIT
}

ensure_dev_server() {
  # Poll the dev server; if it answers within 2 seconds, assume it is up.
  if curl -fsS --max-time 2 "${BASE_URL}/" > /dev/null 2>&1; then
    echo "Dev server already running at ${BASE_URL}"
    return 0
  fi
  echo "Starting dev server via tool/run_web_dev.sh..."
  "${REPO_DIR}/tool/run_web_dev.sh" > "${ARTIFACT_DIR}/dev_server.log" 2>&1 || true
  # Poll up to 120 seconds for the server to become reachable. Flutter web's
  # --release build can take ~60 seconds the first time the cache is cold.
  local i
  for i in $(seq 1 120); do
    if curl -fsS --max-time 2 "${BASE_URL}/" > /dev/null 2>&1; then
      echo "Dev server is ready (after ${i}s)."
      return 0
    fi
    sleep 1
  done
  echo "Dev server did not become reachable within 120s." >&2
  echo "See ${ARTIFACT_DIR}/dev_server.log for compile output." >&2
  return 1
}

open_app() {
  echo "Opening ${BASE_URL} in session ${SESSION_NAME}..."
  agent-browser --session "${SESSION_NAME}" open "${BASE_URL}/" > /dev/null
  # Flutter Web renders to a fixed-height canvas inside a single DOM
  # container; content beyond the viewport is not surfaced in the
  # accessibility tree. The default agent-browser viewport (1280x577 on
  # macOS) is short enough to clip the WalletStatusCard's Disconnect button
  # and the Activity Log on the connected-state main screen. A 1280x1800
  # viewport keeps the full demo content within the visible region for all
  # nine screens without forcing scroll handling in every scenario.
  agent-browser --session "${SESSION_NAME}" set viewport 1280 1800 > /dev/null
  # The app calls SemanticsBinding.instance.ensureSemantics() at startup on
  # web, so the accessibility tree is populated automatically. Give Flutter a
  # beat to render the first frame before the caller starts querying.
  sleep 2
}

close_session() {
  agent-browser --session "${SESSION_NAME}" close > /dev/null 2>&1 || true
}

body_text() {
  agent-browser --session "${SESSION_NAME}" get text body 2>/dev/null || true
}

log_box() {
  agent-browser --session "${SESSION_NAME}" get text .log-box 2>/dev/null || true
}

snapshot() {
  agent-browser --session "${SESSION_NAME}" snapshot -i 2>/dev/null || true
}

screenshot() {
  local name="$1"
  agent-browser --session "${SESSION_NAME}" screenshot "${ARTIFACT_DIR}/${name}.png" > /dev/null 2>&1 || true
}

dump_diagnostics() {
  echo "Dumping diagnostics into ${ARTIFACT_DIR}..."
  screenshot "failure"
  body_text > "${ARTIFACT_DIR}/body_text.txt" 2>&1 || true
  snapshot > "${ARTIFACT_DIR}/snapshot.txt" 2>&1 || true
  log_box > "${ARTIFACT_DIR}/log_box.txt" 2>&1 || true
}

wait_for_body_pattern() {
  local pattern="$1"
  local attempts="${2:-30}"
  local i
  for i in $(seq 1 "${attempts}"); do
    local body
    body="$(body_text)"
    if printf '%s\n' "${body}" | grep -qE "${pattern}"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

assert_body_contains() {
  local body
  body="$(body_text)"
  local missing=()
  local term
  for term in "$@"; do
    if ! printf '%s\n' "${body}" | grep -qF "${term}"; then
      missing+=("${term}")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Body missing expected text:" >&2
    local m
    for m in "${missing[@]}"; do
      echo "  - ${m}" >&2
    done
    return 1
  fi
  return 0
}

scenario_pass() {
  echo ""
  echo "PASS  ${SCENARIO_NAME}  (artifacts: ${ARTIFACT_DIR})"
  exit 0
}

scenario_fail() {
  local message="${1:-scenario failed}"
  echo "" >&2
  echo "FAIL  ${SCENARIO_NAME}: ${message}" >&2
  dump_diagnostics
  echo "FAIL  ${SCENARIO_NAME}  (artifacts: ${ARTIFACT_DIR})" >&2
  exit 1
}

# -----------------------------------------------------------------------------
# Virtual WebAuthn authenticator (CDP)
#
# Attaches a Chromium virtual authenticator (ctap2 / internal / resident keys
# / user-verified) to the current agent-browser session via the Chrome
# DevTools Protocol. Required for any scenario that triggers a passkey
# ceremony (create wallet, add passkey signer, multi-sig with passkey).
#
# Mirrors the standalone tool/agent_browser_webauthn.sh helper so passkey
# scenarios can be authored as single self-contained scripts.
#
# Requirements:
#   - Python 3 with the 'websockets' package (pip install websockets)
#   - curl
#   - The dev page must already be open in the agent-browser session
#     (call open_app first) — the CDP query filters page targets by URL
#     prefix and requires exactly one match.
#
# Lifecycle:
#   - attach_virtual_authenticator: registers an EXIT trap that detaches
#     automatically when the scenario shell exits (pass, fail, or signal).
#   - The credential is ephemeral per CDP session; the next scenario run
#     starts from a clean authenticator state.
# -----------------------------------------------------------------------------

VIRTUAL_AUTHENTICATOR_ID=""
VIRTUAL_AUTHENTICATOR_PID=""

attach_virtual_authenticator() {
  # agent-browser exposes CDP on a dynamic port per session; discover it via
  # `get cdp-url` which returns the browser WebSocket URL like
  # `ws://127.0.0.1:<port>/devtools/browser/<uuid>`.
  local cdp_url
  cdp_url="$(agent-browser --session "${SESSION_NAME}" get cdp-url 2>/dev/null | tr -d '\r\n')"
  if [[ -z "${cdp_url}" ]]; then
    echo "Error: agent-browser get cdp-url returned empty. Is the session running?" >&2
    return 1
  fi
  local cdp_port
  cdp_port="$(printf '%s' "${cdp_url}" | sed -nE 's|^ws://[^:]+:([0-9]+)/.*$|\1|p')"
  if [[ -z "${cdp_port}" ]]; then
    echo "Error: could not parse CDP port from '${cdp_url}'." >&2
    return 1
  fi

  local dev_url_prefix="${BASE_URL}/"
  echo "Attaching virtual WebAuthn authenticator (CDP port ${cdp_port}, target prefix ${dev_url_prefix})..."

  local json_list
  json_list="$(curl -s "http://127.0.0.1:${cdp_port}/json/list" 2>/dev/null || echo '[]')"

  # Find the single page target whose URL matches the dev prefix.
  local page_ws_url
  page_ws_url="$(CDP_JSON_LIST="${json_list}" python3 - "${dev_url_prefix}" <<'PYEOF'
import sys, json, os
prefix = sys.argv[1]
raw = os.environ.get('CDP_JSON_LIST', '')
try:
    targets = json.loads(raw)
except json.JSONDecodeError:
    targets = []
matches = [t for t in targets if t.get("type") == "page" and t.get("url", "").startswith(prefix)]
if len(matches) == 0:
    print("__NONE__")
elif len(matches) > 1:
    print("__MANY__")
else:
    print(matches[0].get("webSocketDebuggerUrl", ""))
PYEOF
)"

  case "${page_ws_url}" in
    __NONE__)
      echo "Error: no CDP page target found at prefix '${dev_url_prefix}'. Did you call open_app?" >&2
      return 1
      ;;
    __MANY__)
      echo "Error: multiple CDP page targets match '${dev_url_prefix}'." >&2
      return 1
      ;;
    "")
      echo "Error: matched page target has no webSocketDebuggerUrl." >&2
      return 1
      ;;
  esac

  # Spawn the persistent CDP holder. CDP destroys the virtual authenticator
  # as soon as its session WebSocket closes, so we keep the connection alive
  # for the scenario's lifetime via this background process.
  local holder_log="${ARTIFACT_DIR}/cdp_webauthn.log"
  python3 -u "${__LIB_DIR}/_cdp_webauthn_holder.py" "${page_ws_url}" \
    > "${holder_log}" 2>&1 &
  VIRTUAL_AUTHENTICATOR_PID=$!
  disown "${VIRTUAL_AUTHENTICATOR_PID}" 2>/dev/null || true

  # Wait up to 10s for the holder to print READY <authenticatorId>.
  local i ready_line
  for i in $(seq 1 50); do
    if ! kill -0 "${VIRTUAL_AUTHENTICATOR_PID}" 2>/dev/null; then
      echo "Error: virtual authenticator holder exited prematurely. Log:" >&2
      cat "${holder_log}" >&2 || true
      VIRTUAL_AUTHENTICATOR_PID=""
      return 1
    fi
    ready_line="$(grep '^READY ' "${holder_log}" 2>/dev/null | head -n1 || true)"
    if [[ -n "${ready_line}" ]]; then
      VIRTUAL_AUTHENTICATOR_ID="${ready_line#READY }"
      echo "Virtual authenticator attached (id: ${VIRTUAL_AUTHENTICATOR_ID}, pid: ${VIRTUAL_AUTHENTICATOR_PID})."
      return 0
    fi
    sleep 0.2
  done

  echo "Error: virtual authenticator did not become ready within 10s. Log:" >&2
  cat "${holder_log}" >&2 || true
  detach_virtual_authenticator
  return 1
}

detach_virtual_authenticator() {
  if [[ -z "${VIRTUAL_AUTHENTICATOR_PID}" ]]; then
    return 0
  fi
  echo "Detaching virtual authenticator (id: ${VIRTUAL_AUTHENTICATOR_ID}, pid: ${VIRTUAL_AUTHENTICATOR_PID})..."
  kill "${VIRTUAL_AUTHENTICATOR_PID}" 2>/dev/null || true
  wait "${VIRTUAL_AUTHENTICATOR_PID}" 2>/dev/null || true
  VIRTUAL_AUTHENTICATOR_ID=""
  VIRTUAL_AUTHENTICATOR_PID=""
}

# Combined cleanup invoked from the EXIT trap installed by
# attach_virtual_authenticator. Detaches the authenticator AND closes the
# agent-browser session so the underlying Chrome instance terminates;
# without this every scenario run leaks a long-lived headed Chrome
# instance per session, adding 30+ helper processes and several hundred
# MB of resident memory each.
scenario_cleanup() {
  detach_virtual_authenticator
  if [[ -n "${SESSION_NAME:-}" ]]; then
    agent-browser --session "${SESSION_NAME}" close 2>&1 || true
  fi
}
