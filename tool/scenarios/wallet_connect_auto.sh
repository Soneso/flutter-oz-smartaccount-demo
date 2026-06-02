#!/usr/bin/env bash
# Scenario 4 — wallet_connect_auto
#
# Self-contained Auto Connect flow. Builds its own fresh wallet (so the
# scenario can run standalone without depending on a prior wallet_create
# run), disconnects, then verifies that the Auto Connect section on the
# Wallet Connection screen finds the credential and re-establishes the
# session against the same on-chain contract.
#
# Phases:
#   A. Setup       — fresh browser session, virtual WebAuthn authenticator.
#   B. Create      — register passkey, deploy + fund + mint via relayer.
#                    Capture the deployed contract address.
#   C. Disconnect  — return to main screen, tap Disconnect; verify the app
#                    drops back to the no-wallet state. IndexedDB credential
#                    survives; virtual authenticator credential survives.
#   D. Auto Connect — open Connect Wallet, tap Auto Connect; verify the same
#                     smart account contract is restored on the main screen.
#
# Exit:
#   0 on PASS — re-connected contract address (truncated form) matches the
#               address captured in phase B.
#   1 on FAIL — diagnostics dumped into artifact dir.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"

scenario_init "wallet_connect_auto"

ensure_dev_server || scenario_fail "dev server failed to start"

# -----------------------------------------------------------------------------
# Phase A: setup
# -----------------------------------------------------------------------------

close_session
open_app
screenshot "01_main_no_wallet"

attach_virtual_authenticator || scenario_fail "could not attach virtual authenticator"

# -----------------------------------------------------------------------------
# Phase B: create wallet (inlined from wallet_create.sh so the scenario is
# self-contained and independently runnable)
# -----------------------------------------------------------------------------

echo "Phase B: creating wallet to seed the credential for Auto Connect..."

NAV_SNAP="$(snapshot)"
NAV_REF="$(printf '%s\n' "${NAV_SNAP}" | \
  grep -oE 'button "Create Wallet" \[ref=e[0-9]+\]' | \
  head -n1 | grep -oE 'e[0-9]+')"
if [[ -z "${NAV_REF}" ]]; then scenario_fail "could not locate 'Create Wallet' button on main screen"; fi
agent-browser --session "${SESSION_NAME}" click "@${NAV_REF}" > /dev/null
sleep 2

wait_for_body_pattern 'Wallet Creation' 15 || \
  scenario_fail "Create Wallet screen did not render"

PASSKEY_NAME="agent-$(date +%s)"
NAME_SNAP="$(snapshot)"
NAME_REF="$(printf '%s\n' "${NAME_SNAP}" | \
  grep -oE 'textbox "Passkey Name [^"]*" \[ref=e[0-9]+\]' | \
  head -n1 | grep -oE 'ref=e[0-9]+' | sed 's/ref=//')"
if [[ -z "${NAME_REF}" ]]; then scenario_fail "could not locate 'Passkey Name' textbox"; fi
agent-browser --session "${SESSION_NAME}" fill "@${NAME_REF}" "${PASSKEY_NAME}" > /dev/null
sleep 1

CREATE_SNAP="$(snapshot)"
CREATE_REF="$(printf '%s\n' "${CREATE_SNAP}" | \
  grep -oE 'button "Create Wallet" \[ref=e[0-9]+\]' | \
  tail -n1 | grep -oE 'e[0-9]+')"
if [[ -z "${CREATE_REF}" ]]; then scenario_fail "could not locate on-screen 'Create Wallet' CTA"; fi
agent-browser --session "${SESSION_NAME}" click "@${CREATE_REF}" > /dev/null

echo "Waiting for deployment + mint to complete (up to 180s)..."
wait_for_body_pattern 'Contract Address:' 180 || \
  scenario_fail "deploy did not complete within 180s"
screenshot "02_wallet_created"

# Capture the deployed C-address so we can assert post-reconnect that the
# same wallet was restored.
DEPLOYED_ADDRESS="$(body_text | tr -d '\n' | \
  grep -oE 'Contract Address: C[A-Z2-7]{55}' | \
  head -n1 | sed 's/^Contract Address: //')"
if [[ -z "${DEPLOYED_ADDRESS}" || ${#DEPLOYED_ADDRESS} -ne 56 ]]; then
  scenario_fail "could not capture deployed contract address (got: '${DEPLOYED_ADDRESS}')"
fi
echo "Captured deployed contract: ${DEPLOYED_ADDRESS}"
echo "${DEPLOYED_ADDRESS}" > "${ARTIFACT_DIR}/deployed_contract.txt"

# Truncated address form used to verify reconnection. The activity log
# entries (and the kit's WalletConnected event payload) use a 4...4
# truncation, which surfaces reliably in both the semantic snapshot and the
# body-text dump. The WalletStatusCard's full address is wrapped in a
# Semantics(label:) that Flutter Web does not surface to either.
DEPLOYED_TRUNC="${DEPLOYED_ADDRESS:0:4}...${DEPLOYED_ADDRESS: -4}"

# -----------------------------------------------------------------------------
# Phase C: disconnect
# -----------------------------------------------------------------------------

echo "Phase C: disconnecting..."
# Click the success-card "Go to Main Screen" button to navigate home.
GO_MAIN_SNAP="$(snapshot)"
GO_MAIN_REF="$(printf '%s\n' "${GO_MAIN_SNAP}" | \
  grep -oE 'button "Go to Main Screen" \[ref=e[0-9]+\]' | \
  head -n1 | grep -oE 'e[0-9]+')"
if [[ -z "${GO_MAIN_REF}" ]]; then scenario_fail "could not locate 'Go to Main Screen' button on success card"; fi
agent-browser --session "${SESSION_NAME}" click "@${GO_MAIN_REF}" > /dev/null
sleep 2

# WalletStatusCard renders the Contract Address label inside a Flutter
# Semantics(label:) which does not surface to body text. Use the "Copy
# contract address" button as the connected-state marker instead — it is
# unique to the connected main screen.
wait_for_body_pattern 'Copy contract address' 10 || \
  scenario_fail "main-screen WalletStatusCard did not render after navigating home"
screenshot "03_main_connected"

DISCONNECT_SNAP="$(snapshot)"
DISCONNECT_REF="$(printf '%s\n' "${DISCONNECT_SNAP}" | \
  grep -oE 'button "Disconnect" \[ref=e[0-9]+\]' | \
  tail -n1 | grep -oE 'e[0-9]+')"
if [[ -z "${DISCONNECT_REF}" ]]; then scenario_fail "could not locate 'Disconnect' button on main screen"; fi
agent-browser --session "${SESSION_NAME}" click "@${DISCONNECT_REF}" > /dev/null

wait_for_body_pattern 'No wallet connected' 10 || \
  scenario_fail "main screen did not return to no-wallet state after disconnect"
screenshot "04_disconnected"

# -----------------------------------------------------------------------------
# Phase D: Auto Connect
# -----------------------------------------------------------------------------

echo "Phase D: triggering Auto Connect..."
CONN_SNAP="$(snapshot)"
CONN_REF="$(printf '%s\n' "${CONN_SNAP}" | \
  grep -oE 'button "Connect Wallet" \[ref=e[0-9]+\]' | \
  head -n1 | grep -oE 'e[0-9]+')"
if [[ -z "${CONN_REF}" ]]; then scenario_fail "could not locate 'Connect Wallet' button on main screen"; fi
agent-browser --session "${SESSION_NAME}" click "@${CONN_REF}" > /dev/null
sleep 2

wait_for_body_pattern 'Auto Connect' 10 || \
  scenario_fail "Wallet Connection screen did not render (no 'Auto Connect' section)"
screenshot "05_wallet_connection_screen"

AUTO_SNAP="$(snapshot)"
AUTO_REF="$(printf '%s\n' "${AUTO_SNAP}" | \
  grep -oE 'button "Auto Connect" \[ref=e[0-9]+\]' | \
  head -n1 | grep -oE 'e[0-9]+')"
if [[ -z "${AUTO_REF}" ]]; then scenario_fail "could not locate 'Auto Connect' button"; fi
agent-browser --session "${SESSION_NAME}" click "@${AUTO_REF}" > /dev/null

echo "Waiting for Auto Connect to re-establish the session (up to 60s)..."
# Auto Connect should: (1) trigger the passkey ceremony against our virtual
# authenticator (which still holds the credential from Phase B), (2) look up
# the contract via the indexer or restored session, (3) navigate back to the
# main screen with the WalletStatusCard rendered. Wait for the connected-
# state main screen to come back.
i=0
RECONNECTED=0
while [[ ${i} -lt 30 ]]; do
  BODY="$(body_text)"
  if printf '%s' "${BODY}" | grep -q "Copy contract address"; then
    RECONNECTED=1
    break
  fi
  sleep 2
  i=$((i + 1))
done
if [[ ${RECONNECTED} -ne 1 ]]; then
  scenario_fail "Auto Connect did not return to connected main screen within 60s"
fi
screenshot "06_reconnected"

# Verify the SAME wallet was restored. The activity log contains a
# "Wallet connected: <truncated-address>" entry for the post-reconnect
# session; matching the deployed address's 4...4 truncation against either
# the body text or the semantic snapshot proves the reconnection returned
# the same contract.
RECONNECT_BODY="$(body_text)"
if ! printf '%s' "${RECONNECT_BODY}" | grep -qF "Wallet connected: ${DEPLOYED_TRUNC}"; then
  scenario_fail "activity log does not contain 'Wallet connected: ${DEPLOYED_TRUNC}' (likely connected to a different wallet)"
fi

echo "Auto Connect restored contract ${DEPLOYED_ADDRESS}."

body_text > "${ARTIFACT_DIR}/post_reconnect_body.txt" || true
snapshot > "${ARTIFACT_DIR}/post_reconnect_snapshot.txt" || true

scenario_pass
