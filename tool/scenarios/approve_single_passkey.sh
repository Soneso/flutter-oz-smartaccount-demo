#!/usr/bin/env bash
# Scenario 13 — approve_single_passkey
#
# Self-contained single-signer passkey allowance approval flow. Builds a
# fresh wallet (which mints DEMO tokens to the account), navigates into the
# Approve screen, grants a DEMO allowance to a test spender, and asserts the
# success card surfaces with the post-approve "Current Allowance" read-only
# fetch resolved to the expected value.
#
# Because the read-only allowance fetch has no standalone UI path (it only
# fires inside the post-approve success card), this scenario also subsumes
# the originally-planned scenario 12 ("Read-only Current Allowance fetch and
# display") — the post-approve verification step exercises that read path.
#
# Spender: GAIH3ULLFQ4DGSECF2AR555KZ4KNDGEKN4AFI4SU2M7B43MGK3QJZNSR — the
# canonical Stellar SDK testnet example account (same address scenario 8
# uses as the transfer recipient). Any G- or C-address works since the
# spender is only stored in the SAC allowance ledger; it does not need to
# pre-exist for an Approve.
#
# Phases:
#   A. Setup       — fresh browser session, virtual WebAuthn authenticator.
#   B. Create      — register passkey, deploy + fund + mint via relayer.
#                    Captures the deployed contract address (DEMO token is
#                    minted as part of this phase).
#   C. Navigate    — open success-card "Go to Main Screen", click the
#                    Approve card on WalletStatusCard.
#   D. Approve     — fill Spender + Amount, keep default Expiration,
#                    click Approve; verify the success card appears.
#   E. Verify      — wait for the "Current Allowance" row to resolve away
#                    from "Loading..." to the approved amount (read-only
#                    SAC `allowance(from, spender)` simulation).
#
# Exit:
#   0 on PASS — success card visible with "New Approve" button + Current
#               Allowance matching the approved amount.
#   1 on FAIL — diagnostics dumped into artifact dir.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"

scenario_init "approve_single_passkey"

ensure_dev_server || scenario_fail "dev server failed to start"

SPENDER="GAIH3ULLFQ4DGSECF2AR555KZ4KNDGEKN4AFI4SU2M7B43MGK3QJZNSR"
AMOUNT="5.0"

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

echo "Phase B: creating wallet for the approve scenario..."

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
# Phase C: navigate to Approve screen
# -----------------------------------------------------------------------------

echo "Phase C: navigating to Approve screen..."
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

MAIN_SNAP="$(snapshot)"
APPROVE_CARD_REF="$(printf '%s\n' "${MAIN_SNAP}" | \
  grep -oE 'button "Approve\. Grant a token spending allowance" \[ref=e[0-9]+\]' | \
  head -n1 | grep -oE 'e[0-9]+')"
if [[ -z "${APPROVE_CARD_REF}" ]]; then scenario_fail "could not locate Approve card on main screen"; fi
agent-browser --session "${SESSION_NAME}" click "@${APPROVE_CARD_REF}" > /dev/null
sleep 2

wait_for_body_pattern 'Token Allowance' 10 || \
  scenario_fail "Approve screen did not render (no 'Token Allowance' heading)"
screenshot "04_approve_screen"

# -----------------------------------------------------------------------------
# Phase D: fill form + submit approve
# -----------------------------------------------------------------------------

echo "Phase D: filling Spender Address and Amount fields..."

FORM_SNAP="$(snapshot)"
SPENDER_REF="$(printf '%s\n' "${FORM_SNAP}" | \
  grep -oE 'textbox "Spender Address[^"]*" \[ref=e[0-9]+\]' | \
  head -n1 | grep -oE 'ref=e[0-9]+' | sed 's/ref=//')"
if [[ -z "${SPENDER_REF}" ]]; then scenario_fail "could not locate Spender Address textbox"; fi
agent-browser --session "${SESSION_NAME}" fill "@${SPENDER_REF}" "${SPENDER}" > /dev/null
sleep 1

AMOUNT_SNAP="$(snapshot)"
AMOUNT_REF="$(printf '%s\n' "${AMOUNT_SNAP}" | \
  grep -oE 'textbox "Amount[^"]*" \[ref=e[0-9]+\]' | \
  head -n1 | grep -oE 'ref=e[0-9]+' | sed 's/ref=//')"
if [[ -z "${AMOUNT_REF}" ]]; then scenario_fail "could not locate Amount textbox"; fi
agent-browser --session "${SESSION_NAME}" fill "@${AMOUNT_REF}" "${AMOUNT}" > /dev/null
sleep 1
screenshot "05_form_filled"

# Click the Approve FilledButton (not the screen-title "Approve" AppBar).
SUBMIT_SNAP="$(snapshot)"
SUBMIT_REF="$(printf '%s\n' "${SUBMIT_SNAP}" | \
  grep -oE 'button "Approve" \[ref=e[0-9]+\]' | \
  head -n1 | grep -oE 'e[0-9]+')"
if [[ -z "${SUBMIT_REF}" ]]; then scenario_fail "could not locate Approve submit button"; fi
agent-browser --session "${SESSION_NAME}" click "@${SUBMIT_REF}" > /dev/null

echo "Waiting for approve to complete (passkey + simulate + sign + submit, up to 120s)..."
# Same Flutter-Web semantics nuance as scenario 8: bare Text widgets inside
# Cards do not surface to body text or the snapshot tree. The "New Approve"
# button is unique to the success card and surfaces reliably.
i=0
SUCCESS=0
while [[ ${i} -lt 60 ]]; do
  POLL_SNAP="$(snapshot)"
  if printf '%s' "${POLL_SNAP}" | grep -q 'button "New Approve"'; then
    SUCCESS=1
    break
  fi
  sleep 2
  i=$((i + 1))
done
if [[ ${SUCCESS} -ne 1 ]]; then
  scenario_fail "Approve success card did not appear within 120s (no 'New Approve' button in snapshot)"
fi
screenshot "06_approve_success"

# -----------------------------------------------------------------------------
# Phase E: verify post-approve Current Allowance read-only fetch
# -----------------------------------------------------------------------------

echo "Phase E: waiting for post-approve Current Allowance read-only fetch..."
# The success card's "Current Allowance" row starts as "Loading..." and
# resolves to "<amount> DEMO" once the SAC `allowance(from, spender)`
# simulation completes. This row is wrapped in Semantics(liveRegion: true)
# which DOES surface to body text on Flutter Web. The displayed amount
# strips trailing zeros (e.g. "5.0" approve → "5 DEMO" allowance), so the
# integer-prefix form is the right thing to match against.
AMOUNT_INT="${AMOUNT%.*}"
EXPECTED_DISPLAY="${AMOUNT_INT} DEMO"
i=0
ALLOWANCE_RESOLVED=0
while [[ ${i} -lt 30 ]]; do
  POLL_BODY="$(body_text)"
  if printf '%s' "${POLL_BODY}" | grep -qF "${EXPECTED_DISPLAY}"; then
    ALLOWANCE_RESOLVED=1
    break
  fi
  if printf '%s' "${POLL_BODY}" | grep -q "Unable to fetch"; then
    scenario_fail "Current Allowance read-only fetch failed (success card shows 'Unable to fetch')"
  fi
  sleep 2
  i=$((i + 1))
done
if [[ ${ALLOWANCE_RESOLVED} -ne 1 ]]; then
  scenario_fail "Current Allowance did not resolve to '${EXPECTED_DISPLAY}' within 60s"
fi

echo "Approve of ${AMOUNT} DEMO to ${SPENDER:0:8}... committed; read-only allowance fetch returned ${EXPECTED_DISPLAY}."

body_text > "${ARTIFACT_DIR}/approve_success_body.txt" || true
snapshot > "${ARTIFACT_DIR}/approve_success_snapshot.txt" || true

scenario_pass
