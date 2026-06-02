#!/usr/bin/env bash
# Scenario 17 — context_rules_remove
#
# Self-contained Context Rules remove flow. Builds a fresh wallet (which
# has one default rule), creates a second rule via the builder, removes
# the second rule via the single-signer passkey path, then verifies the
# last-rule guard prevents removal of the remaining rule.
#
# Phases:
#   A. Setup        — fresh browser session, virtual WebAuthn authenticator.
#   B. Create       — register passkey, deploy + fund + mint via relayer.
#   C. Add 2nd rule — Context Rules → + Add Rule → fill name + delegated
#                     signer → Create Context Rule → Go Back. Verify list
#                     rebuilds with 2 rules.
#   D. Remove       — expand the newly-added rule → Remove Rule → confirm
#                     in dialog → wait for single-signer passkey removal.
#                     Verify list rebuilds to 1 rule.
#   E. Guard        — expand the remaining rule → assert the Remove button
#                     is replaced by a disabled "Last Rule" button (the
#                     screen-level last-rule guard).
#
# Exit:
#   0 on PASS — second rule removed, last-rule guard verified disabled.
#   1 on FAIL — diagnostics dumped into artifact dir.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"

scenario_init "context_rules_remove"

ensure_dev_server || scenario_fail "dev server failed to start"

DELEGATED_SIGNER="GAIH3ULLFQ4DGSECF2AR555KZ4KNDGEKN4AFI4SU2M7B43MGK3QJZNSR"
# Rule names are capped at 20 bytes by the on-chain contract (B-10). Use a
# short prefix + epoch tail so parallel runs do not collide.
RULE_NAME="rm-$(date +%s | tail -c 9)"

# -----------------------------------------------------------------------------
# Phase A: setup
# -----------------------------------------------------------------------------

close_session
open_app
screenshot "01_main_no_wallet"

attach_virtual_authenticator || scenario_fail "could not attach virtual authenticator"

# -----------------------------------------------------------------------------
# Phase B: create wallet
# -----------------------------------------------------------------------------

echo "Phase B: creating wallet for the context-rules-remove scenario..."

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
# Phase C: navigate to Context Rules, add a second rule
# -----------------------------------------------------------------------------

echo "Phase C: navigating to Context Rules and adding a second rule..."
MAIN_SNAP="$(snapshot)"
RULES_CARD_REF="$(printf '%s\n' "${MAIN_SNAP}" | \
  grep -oE 'button "Context Rules\. View and manage signing rules" \[ref=e[0-9]+\]' | \
  head -n1 | grep -oE 'e[0-9]+')"
if [[ -z "${RULES_CARD_REF}" ]]; then scenario_fail "could not locate Context Rules card on main screen"; fi
agent-browser --session "${SESSION_NAME}" click "@${RULES_CARD_REF}" > /dev/null
sleep 2

wait_for_body_pattern '1 context rule.s. loaded' 30 || \
  scenario_fail "Context Rules list did not initially load with 1 default rule"
screenshot "03_rules_one"

# Click "+ Add Rule".
ADD_SNAP="$(snapshot)"
ADD_REF="$(printf '%s\n' "${ADD_SNAP}" | \
  grep -oE 'button "\+ Add Rule" \[ref=e[0-9]+\]' | \
  head -n1 | grep -oE 'e[0-9]+')"
if [[ -z "${ADD_REF}" ]]; then scenario_fail "could not locate '+ Add Rule' button"; fi
agent-browser --session "${SESSION_NAME}" click "@${ADD_REF}" > /dev/null
sleep 2

wait_for_body_pattern 'Add Context Rule' 10 || \
  scenario_fail "Context Rule Builder did not render"

# Fill rule name.
NAME_BUILDER_SNAP="$(snapshot)"
RULE_NAME_REF="$(printf '%s\n' "${NAME_BUILDER_SNAP}" | \
  grep -oE 'textbox "Rule Name[^"]*" \[ref=e[0-9]+\]' | \
  head -n1 | grep -oE 'ref=e[0-9]+' | sed 's/ref=//')"
if [[ -z "${RULE_NAME_REF}" ]]; then scenario_fail "could not locate Rule Name textbox"; fi
agent-browser --session "${SESSION_NAME}" fill "@${RULE_NAME_REF}" "${RULE_NAME}" > /dev/null
sleep 1

# Default Signer Type is "Delegated (G-address)". Fill the address.
ADDR_SNAP="$(snapshot)"
ADDR_REF="$(printf '%s\n' "${ADDR_SNAP}" | \
  grep -oE 'textbox "Stellar Address[^"]*" \[ref=e[0-9]+\]' | \
  head -n1 | grep -oE 'ref=e[0-9]+' | sed 's/ref=//')"
if [[ -z "${ADDR_REF}" ]]; then scenario_fail "could not locate Stellar Address textbox"; fi
agent-browser --session "${SESSION_NAME}" fill "@${ADDR_REF}" "${DELEGATED_SIGNER}" > /dev/null
sleep 1

STAGE_SNAP="$(snapshot)"
STAGE_REF="$(printf '%s\n' "${STAGE_SNAP}" | \
  grep -oE 'button "Add Delegated Signer" \[ref=e[0-9]+\]' | \
  head -n1 | grep -oE 'e[0-9]+')"
if [[ -z "${STAGE_REF}" ]]; then scenario_fail "could not locate 'Add Delegated Signer' button"; fi
agent-browser --session "${SESSION_NAME}" click "@${STAGE_REF}" > /dev/null
sleep 1

# Submit "Create Context Rule".
SUBMIT_SNAP="$(snapshot)"
SUBMIT_REF="$(printf '%s\n' "${SUBMIT_SNAP}" | \
  grep -oE 'button "Create Context Rule" \[ref=e[0-9]+\]' | \
  head -n1 | grep -oE 'e[0-9]+')"
if [[ -z "${SUBMIT_REF}" ]]; then scenario_fail "could not locate Create Context Rule submit button"; fi
agent-browser --session "${SESSION_NAME}" click "@${SUBMIT_REF}" > /dev/null

echo "Waiting for context rule creation (passkey + simulate + sign + submit, up to 120s)..."
i=0
CREATED=0
while [[ ${i} -lt 60 ]]; do
  POLL_SNAP="$(snapshot)"
  if printf '%s' "${POLL_SNAP}" | grep -q 'Transaction Successful'; then
    CREATED=1
    break
  fi
  sleep 2
  i=$((i + 1))
done
if [[ ${CREATED} -ne 1 ]]; then
  scenario_fail "second-rule creation did not surface a success card within 120s"
fi
screenshot "04_second_rule_created"

# Go Back to Context Rules list.
BACK_SNAP="$(snapshot)"
BACK_REF="$(printf '%s\n' "${BACK_SNAP}" | \
  grep -oE 'button "Go Back" \[ref=e[0-9]+\]' | \
  head -n1 | grep -oE 'e[0-9]+')"
if [[ -z "${BACK_REF}" ]]; then scenario_fail "could not locate 'Go Back' button on success card"; fi
agent-browser --session "${SESSION_NAME}" click "@${BACK_REF}" > /dev/null
sleep 2

wait_for_body_pattern '2 context rule.s. loaded' 30 || \
  scenario_fail "Context Rules list did not refresh to 2 rules after creating the second one"
screenshot "05_rules_two"

# -----------------------------------------------------------------------------
# Phase D: remove the second rule
# -----------------------------------------------------------------------------

echo "Phase D: expanding the second rule and removing it..."

# There are two "Expand" buttons in the snapshot — one per card. The second
# card is the newly-added rule (`listContextRules` returns rules in id
# ascending order so the newer rule with the larger id comes second).
EXPAND_SNAP="$(snapshot)"
SECOND_EXPAND_REF="$(printf '%s\n' "${EXPAND_SNAP}" | \
  grep -oE 'button "Expand" \[ref=e[0-9]+\]' | \
  tail -n1 | grep -oE 'e[0-9]+')"
if [[ -z "${SECOND_EXPAND_REF}" ]]; then scenario_fail "could not locate second 'Expand' button"; fi
agent-browser --session "${SESSION_NAME}" click "@${SECOND_EXPAND_REF}" > /dev/null
sleep 1

REMOVE_SNAP="$(snapshot)"
REMOVE_REF="$(printf '%s\n' "${REMOVE_SNAP}" | \
  grep -oE 'button "Remove Rule" \[ref=e[0-9]+\]' | \
  head -n1 | grep -oE 'e[0-9]+')"
if [[ -z "${REMOVE_REF}" ]]; then scenario_fail "could not locate 'Remove Rule' button on expanded card"; fi
agent-browser --session "${SESSION_NAME}" click "@${REMOVE_REF}" > /dev/null
sleep 1

wait_for_body_pattern 'Remove Context Rule' 5 || \
  scenario_fail "Remove Context Rule confirmation dialog did not appear"

# Confirm the removal — the dialog's confirm button is labelled "Remove"
# (the cancel button is labelled "Cancel").
DIALOG_SNAP="$(snapshot)"
CONFIRM_REF="$(printf '%s\n' "${DIALOG_SNAP}" | \
  grep -oE 'button "Remove" \[ref=e[0-9]+\]' | \
  head -n1 | grep -oE 'e[0-9]+')"
if [[ -z "${CONFIRM_REF}" ]]; then scenario_fail "could not locate dialog 'Remove' confirm button"; fi
agent-browser --session "${SESSION_NAME}" click "@${CONFIRM_REF}" > /dev/null
sleep 2

# The flow's available-signers extractor returns the UNION across all rules
# on the smart account. With two rules (default-passkey + delegated-G-addr)
# the screen routes through the multi-signer SignerPickerSheet so the user
# can decide which signer(s) co-authorize. For this scenario we want only
# the connected passkey to sign, so uncheck the delegated checkbox before
# confirming.
wait_for_body_pattern 'Select Signers' 5 || \
  scenario_fail "Signer Picker sheet did not surface"
PICKER_SNAP="$(snapshot)"
DELEGATED_REF="$(printf '%s\n' "${PICKER_SNAP}" | \
  grep -oE 'checkbox "GAIH[^"]*" \[checked=true, ref=e[0-9]+\]' | \
  head -n1 | grep -oE 'ref=e[0-9]+' | sed 's/ref=//')"
if [[ -z "${DELEGATED_REF}" ]]; then
  scenario_fail "could not locate delegated-signer checkbox in picker"
fi
agent-browser --session "${SESSION_NAME}" uncheck "@${DELEGATED_REF}" > /dev/null
sleep 1

CONFIRM_PICKER_SNAP="$(snapshot)"
CONFIRM_PICKER_REF="$(printf '%s\n' "${CONFIRM_PICKER_SNAP}" | \
  grep -oE 'button "Confirm" \[ref=e[0-9]+\]' | \
  head -n1 | grep -oE 'e[0-9]+')"
if [[ -z "${CONFIRM_PICKER_REF}" ]]; then scenario_fail "could not locate Confirm button in picker"; fi
agent-browser --session "${SESSION_NAME}" click "@${CONFIRM_PICKER_REF}" > /dev/null

echo "Waiting for removal (passkey + simulate + sign + submit, up to 120s)..."
i=0
REMOVED=0
while [[ ${i} -lt 60 ]]; do
  POLL_BODY="$(body_text)"
  if printf '%s' "${POLL_BODY}" | grep -qE '1 context rule.s. loaded'; then
    REMOVED=1
    break
  fi
  sleep 2
  i=$((i + 1))
done
if [[ ${REMOVED} -ne 1 ]]; then
  scenario_fail "context rules list did not return to 1 rule after removal"
fi
screenshot "06_back_to_one_rule"

# -----------------------------------------------------------------------------
# Phase E: verify the last-rule guard
# -----------------------------------------------------------------------------

echo "Phase E: expanding the remaining rule to verify the last-rule guard..."
GUARD_SNAP="$(snapshot)"
LAST_EXPAND_REF="$(printf '%s\n' "${GUARD_SNAP}" | \
  grep -oE 'button "Expand" \[ref=e[0-9]+\]' | \
  head -n1 | grep -oE 'e[0-9]+')"
if [[ -z "${LAST_EXPAND_REF}" ]]; then scenario_fail "could not locate 'Expand' on the remaining rule"; fi
agent-browser --session "${SESSION_NAME}" click "@${LAST_EXPAND_REF}" > /dev/null
sleep 1

# The remaining rule's remove button should be the disabled "Last Rule"
# button (not "Remove Rule"). Assert both: "Last Rule" is present in the
# snapshot AND tagged [disabled], and "Remove Rule" is NOT present.
LAST_RULE_SNAP="$(snapshot)"
if ! printf '%s' "${LAST_RULE_SNAP}" | grep -qE 'button "Last Rule" \[disabled'; then
  scenario_fail "last-rule guard not active: expected a disabled 'Last Rule' button, snapshot did not contain one"
fi
if printf '%s' "${LAST_RULE_SNAP}" | grep -q 'button "Remove Rule"'; then
  scenario_fail "last-rule guard inactive: snapshot still contains an enabled 'Remove Rule' button"
fi
screenshot "07_last_rule_guard"

echo "Last-rule guard verified: 'Remove Rule' replaced by disabled 'Last Rule' button."

body_text > "${ARTIFACT_DIR}/final_body.txt" || true
snapshot > "${ARTIFACT_DIR}/final_snapshot.txt" || true

scenario_pass
