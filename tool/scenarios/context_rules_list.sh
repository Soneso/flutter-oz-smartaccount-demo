#!/usr/bin/env bash
# Scenario 16 — context_rules_list
#
# Self-contained read-only Context Rules list flow. Builds a fresh wallet
# (which has a single default context rule installed during deployment),
# navigates into the Context Rules screen, and asserts the list rendered
# exactly one rule.
#
# This is a pure read-only scenario — no passkey ceremony beyond the wallet
# creation, no on-chain mutation. The screen calls
# `contextRuleManager.listContextRules` which is a simulated read against
# the smart account's storage.
#
# Phases:
#   A. Setup       — fresh browser session, virtual WebAuthn authenticator.
#   B. Create      — register passkey, deploy + fund + mint via relayer.
#   C. Navigate    — open success-card "Go to Main Screen", click the
#                    Context Rules card on WalletStatusCard.
#   D. Verify      — assert the rule-count summary reads "1 context rule(s)
#                    loaded" (default rule only).
#
# Exit:
#   0 on PASS — rule list rendered with the default rule present.
#   1 on FAIL — diagnostics dumped into artifact dir.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"

scenario_init "context_rules_list"

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

echo "Phase B: creating wallet for the context-rules-list scenario..."

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
# Phase C: navigate to Context Rules screen
# -----------------------------------------------------------------------------

echo "Phase C: navigating to Context Rules screen..."
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
RULES_CARD_REF="$(printf '%s\n' "${MAIN_SNAP}" | \
  grep -oE 'button "Context Rules\. View and manage signing rules" \[ref=e[0-9]+\]' | \
  head -n1 | grep -oE 'e[0-9]+')"
if [[ -z "${RULES_CARD_REF}" ]]; then scenario_fail "could not locate Context Rules card on main screen"; fi
agent-browser --session "${SESSION_NAME}" click "@${RULES_CARD_REF}" > /dev/null
sleep 2

wait_for_body_pattern 'On-Chain Authorization Rules' 10 || \
  scenario_fail "Context Rules screen did not render"
screenshot "04_context_rules_screen"

# -----------------------------------------------------------------------------
# Phase D: verify the default rule is listed
# -----------------------------------------------------------------------------

echo "Phase D: waiting for context rules list to load..."
# The screen kicks off `listContextRules()` on mount; the rule-count summary
# appears once the simulation returns. Poll for the "1 context rule(s) loaded"
# text (the default rule is installed during wallet creation).
i=0
LOADED=0
while [[ ${i} -lt 20 ]]; do
  POLL_BODY="$(body_text)"
  if printf '%s' "${POLL_BODY}" | grep -qF "1 context rule(s) loaded"; then
    LOADED=1
    break
  fi
  if printf '%s' "${POLL_BODY}" | grep -q "Failed to load context rules"; then
    scenario_fail "list context rules failed (error card surfaced)"
  fi
  sleep 2
  i=$((i + 1))
done
if [[ ${LOADED} -ne 1 ]]; then
  scenario_fail "context rules list did not load within 40s (expected '1 context rule(s) loaded')"
fi
screenshot "05_rules_loaded"

echo "Context Rules list loaded with 1 default rule for contract ${DEPLOYED_ADDRESS}."

body_text > "${ARTIFACT_DIR}/rules_loaded_body.txt" || true
snapshot > "${ARTIFACT_DIR}/rules_loaded_snapshot.txt" || true

scenario_pass
