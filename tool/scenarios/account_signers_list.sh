#!/usr/bin/env bash
# Scenario 27+28 — account_signers_list
#
# Self-contained read-only Account Signers list flow. Builds a fresh wallet
# (which has one default rule with the connected passkey signer),
# navigates into the Account Signers screen, and asserts the signer list
# renders the connected passkey.
#
# Plan merger note: the original plan split scenarios #27 (Account Signers)
# and #28 (Known Signers) into separate test cases, but the demo renders
# both views from the same `KnownSignersScreen` reachable at the
# `/account-signers` route — there is no separate "Known Signers" screen.
# This scenario therefore covers both planned IDs in a single run.
#
# Pure read-only — no on-chain mutation. The screen calls
# `accountSignersFlow.loadAccountSigners()` which simulates a
# `list_context_rules` read and de-duplicates the signers across all rules.
#
# Phases:
#   A. Setup       — fresh browser session, virtual WebAuthn authenticator.
#   B. Create      — register passkey, deploy + fund + mint via relayer.
#   C. Navigate    — main → Account Signers via the WalletStatusCard card.
#   D. Verify      — assert the signers count header reads "1 signer"
#                    (the connected passkey from the default rule).
#
# Exit:
#   0 on PASS — signer list rendered with the connected passkey.
#   1 on FAIL — diagnostics dumped into artifact dir.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"

scenario_init "account_signers_list"

ensure_dev_server || scenario_fail "dev server failed to start"

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

echo "Phase B: creating wallet for the account-signers-list scenario..."

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

# Navigate back to the main screen.
GO_MAIN_SNAP="$(snapshot)"
GO_MAIN_REF="$(printf '%s\n' "${GO_MAIN_SNAP}" | \
  grep -oE 'button "Go to Main Screen" \[ref=e[0-9]+\]' | \
  head -n1 | grep -oE 'e[0-9]+')"
if [[ -z "${GO_MAIN_REF}" ]]; then scenario_fail "could not locate 'Go to Main Screen' button on success card"; fi
agent-browser --session "${SESSION_NAME}" click "@${GO_MAIN_REF}" > /dev/null
sleep 2

wait_for_body_pattern 'Copy contract address' 10 || \
  scenario_fail "main-screen WalletStatusCard did not render"

# -----------------------------------------------------------------------------
# Phase C: navigate to Account Signers
# -----------------------------------------------------------------------------

echo "Phase C: navigating to Account Signers..."
MAIN_SNAP="$(snapshot)"
SIGNERS_CARD_REF="$(printf '%s\n' "${MAIN_SNAP}" | \
  grep -oE 'button "Account Signers\. View all signers on this account" \[ref=e[0-9]+\]' | \
  head -n1 | grep -oE 'e[0-9]+')"
if [[ -z "${SIGNERS_CARD_REF}" ]]; then scenario_fail "could not locate Account Signers card on main screen"; fi
agent-browser --session "${SESSION_NAME}" click "@${SIGNERS_CARD_REF}" > /dev/null
sleep 2

wait_for_body_pattern 'Account Signers' 10 || \
  scenario_fail "Account Signers screen did not render"
screenshot "03_signers_screen"

# -----------------------------------------------------------------------------
# Phase D: verify the default-rule passkey signer is listed
# -----------------------------------------------------------------------------

echo "Phase D: waiting for the signer list to load..."
# The screen kicks off `loadAccountSigners()` on mount; the count header
# "<N> signer" / "<N> signers" appears once the simulation returns. For a
# brand-new wallet with the default rule (1 passkey signer), the header
# reads exactly "1 signer". The header is wrapped in Semantics(header:)
# which surfaces to Flutter Web's body text.
i=0
LOADED=0
while [[ ${i} -lt 20 ]]; do
  POLL_BODY="$(body_text)"
  if printf '%s' "${POLL_BODY}" | grep -qE '(^|[^0-9])1 signer($|[^s])'; then
    LOADED=1
    break
  fi
  if printf '%s' "${POLL_BODY}" | grep -q 'Failed to load signers'; then
    scenario_fail "Account Signers load failed (error card surfaced)"
  fi
  sleep 2
  i=$((i + 1))
done
if [[ ${LOADED} -ne 1 ]]; then
  scenario_fail "Account Signers list did not load within 40s (expected '1 signer' header)"
fi
screenshot "04_signers_loaded"

echo "Account Signers list loaded with 1 signer for contract ${DEPLOYED_ADDRESS}."

body_text > "${ARTIFACT_DIR}/signers_loaded_body.txt" || true
snapshot > "${ARTIFACT_DIR}/signers_loaded_snapshot.txt" || true

scenario_pass
