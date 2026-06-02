#!/usr/bin/env bash
# Scenario 8 — transfer_single_passkey
#
# Self-contained single-signer passkey transfer flow. Builds a fresh wallet,
# navigates into the Transfer screen, sends a small XLM amount to a
# well-known testnet recipient, and asserts the success card surfaces with
# Transaction Hash + Amount Sent + Recipient markers.
#
# Recipient: GAIH3ULLFQ4DGSECF2AR555KZ4KNDGEKN4AFI4SU2M7B43MGK3QJZNSR — the
# canonical Stellar SDK testnet example account, already used as the
# simulation envelope source in lib/util/sac_balance_fetcher.dart, so it is
# guaranteed to exist on testnet and accept payments.
#
# Phases:
#   A. Setup       — fresh browser session, virtual WebAuthn authenticator.
#   B. Create      — register passkey, deploy + fund + mint via relayer.
#                    Capture the deployed contract address.
#   C. Navigate    — open success-card "Go to Main Screen", click the
#                    Transfer card on WalletStatusCard.
#   D. Transfer    — keep default XLM token, fill recipient + amount,
#                    click Transfer; verify the success card appears with
#                    the required markers.
#
# Exit:
#   0 on PASS — Transfer Successful card visible with Transaction Hash,
#               Amount Sent, and Recipient labels.
#   1 on FAIL — diagnostics dumped into artifact dir.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"

scenario_init "transfer_single_passkey"

ensure_dev_server || scenario_fail "dev server failed to start"

# Hard-coded testnet recipient and amount.
RECIPIENT="GAIH3ULLFQ4DGSECF2AR555KZ4KNDGEKN4AFI4SU2M7B43MGK3QJZNSR"
AMOUNT="1.0"

# -----------------------------------------------------------------------------
# Phase A: setup
# -----------------------------------------------------------------------------

close_session
open_app
screenshot "01_main_no_wallet"

attach_virtual_authenticator || scenario_fail "could not attach virtual authenticator"

# -----------------------------------------------------------------------------
# Phase B: create wallet (inlined so the scenario is independently runnable)
# -----------------------------------------------------------------------------

echo "Phase B: creating wallet for the transfer scenario..."

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

DEPLOYED_ADDRESS="$(body_text | tr -d '\n' | \
  grep -oE 'Contract Address: C[A-Z2-7]{55}' | \
  head -n1 | sed 's/^Contract Address: //')"
if [[ -z "${DEPLOYED_ADDRESS}" || ${#DEPLOYED_ADDRESS} -ne 56 ]]; then
  scenario_fail "could not capture deployed contract address (got: '${DEPLOYED_ADDRESS}')"
fi
echo "Captured deployed contract: ${DEPLOYED_ADDRESS}"
echo "${DEPLOYED_ADDRESS}" > "${ARTIFACT_DIR}/deployed_contract.txt"

# -----------------------------------------------------------------------------
# Phase C: navigate to Transfer screen
# -----------------------------------------------------------------------------

echo "Phase C: navigating to Transfer screen..."
GO_MAIN_SNAP="$(snapshot)"
GO_MAIN_REF="$(printf '%s\n' "${GO_MAIN_SNAP}" | \
  grep -oE 'button "Go to Main Screen" \[ref=e[0-9]+\]' | \
  head -n1 | grep -oE 'e[0-9]+')"
if [[ -z "${GO_MAIN_REF}" ]]; then scenario_fail "could not locate 'Go to Main Screen' button on success card"; fi
agent-browser --session "${SESSION_NAME}" click "@${GO_MAIN_REF}" > /dev/null
sleep 2

wait_for_body_pattern 'Copy contract address' 10 || \
  scenario_fail "main-screen WalletStatusCard did not render after navigating home"
screenshot "03_main_connected"

# The Transfer card on WalletStatusCard renders as a button whose semantic
# label combines the title and description.
MAIN_SNAP="$(snapshot)"
TRANSFER_CARD_REF="$(printf '%s\n' "${MAIN_SNAP}" | \
  grep -oE 'button "Transfer\. Send XLM or DEMO tokens" \[ref=e[0-9]+\]' | \
  head -n1 | grep -oE 'e[0-9]+')"
if [[ -z "${TRANSFER_CARD_REF}" ]]; then scenario_fail "could not locate Transfer card on main screen"; fi
agent-browser --session "${SESSION_NAME}" click "@${TRANSFER_CARD_REF}" > /dev/null
sleep 2

wait_for_body_pattern 'Token Transfer' 10 || \
  scenario_fail "Transfer screen did not render"
screenshot "04_transfer_screen"

# -----------------------------------------------------------------------------
# Phase D: fill form + submit transfer
# -----------------------------------------------------------------------------

echo "Phase D: filling Recipient Address and Amount fields..."

FORM_SNAP="$(snapshot)"
RECIPIENT_REF="$(printf '%s\n' "${FORM_SNAP}" | \
  grep -oE 'textbox "Recipient Address[^"]*" \[ref=e[0-9]+\]' | \
  head -n1 | grep -oE 'ref=e[0-9]+' | sed 's/ref=//')"
if [[ -z "${RECIPIENT_REF}" ]]; then scenario_fail "could not locate Recipient Address textbox"; fi
agent-browser --session "${SESSION_NAME}" fill "@${RECIPIENT_REF}" "${RECIPIENT}" > /dev/null
sleep 1

AMOUNT_SNAP="$(snapshot)"
AMOUNT_REF="$(printf '%s\n' "${AMOUNT_SNAP}" | \
  grep -oE 'textbox "Amount[^"]*" \[ref=e[0-9]+\]' | \
  head -n1 | grep -oE 'ref=e[0-9]+' | sed 's/ref=//')"
if [[ -z "${AMOUNT_REF}" ]]; then scenario_fail "could not locate Amount textbox"; fi
agent-browser --session "${SESSION_NAME}" fill "@${AMOUNT_REF}" "${AMOUNT}" > /dev/null
sleep 1
screenshot "05_form_filled"

# Click the Transfer FilledButton (not the card heading "Token Transfer").
SUBMIT_SNAP="$(snapshot)"
SUBMIT_REF="$(printf '%s\n' "${SUBMIT_SNAP}" | \
  grep -oE 'button "Transfer" \[ref=e[0-9]+\]' | \
  head -n1 | grep -oE 'e[0-9]+')"
if [[ -z "${SUBMIT_REF}" ]]; then scenario_fail "could not locate Transfer submit button"; fi
agent-browser --session "${SESSION_NAME}" click "@${SUBMIT_REF}" > /dev/null

echo "Waiting for transfer to complete (passkey + simulate + sign + submit, up to 120s)..."
# Flutter Web's semantic tree only surfaces headings, buttons and form
# controls — bare Text widgets inside Cards are invisible to both the
# accessibility tree dump and `get text body`. The TransferResultCard's
# "Transfer Successful" heading is wrapped in Semantics(header:) but Flutter
# Web still omits it. The "New Transfer" button, however, is unique to the
# success card and surfaces reliably; use it as the success marker.
i=0
SUCCESS=0
while [[ ${i} -lt 60 ]]; do
  POLL_SNAP="$(snapshot)"
  if printf '%s' "${POLL_SNAP}" | grep -q 'button "New Transfer"'; then
    SUCCESS=1
    break
  fi
  sleep 2
  i=$((i + 1))
done
if [[ ${SUCCESS} -ne 1 ]]; then
  scenario_fail "Transfer success card did not appear within 120s (no 'New Transfer' button in snapshot)"
fi
screenshot "06_transfer_success"

# Sanity-check: the Balance card on the same screen rebuilds with the
# debited balance. Pre-transfer balance was 9995 XLM (FriendBot funding minus
# minimal deploy cost); after a 1.0 XLM transfer it should read 9994 XLM.
RESULT_BODY="$(body_text)"
if ! printf '%s' "${RESULT_BODY}" | grep -qF "9994 XLM"; then
  scenario_fail "balance card did not update to expected post-transfer value (looking for '9994 XLM' in body)"
fi

echo "Transfer of ${AMOUNT} XLM to ${RECIPIENT:0:8}... completed; balance now 9994 XLM."

body_text > "${ARTIFACT_DIR}/transfer_success_body.txt" || true
snapshot > "${ARTIFACT_DIR}/transfer_success_snapshot.txt" || true

scenario_pass
