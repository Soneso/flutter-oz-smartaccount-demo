#!/usr/bin/env bash
# Scenario 23 — context_rule_edit_name_expiry
#
# Self-contained Context Rule Editor flow: edit the default rule's name AND
# add an expiry preset. Exercises the edit-mode path of the Context Rule
# Builder (renamed `Edit Context Rule` in the AppBar when entered with a
# rule id).
#
# Phases:
#   A. Setup        — fresh browser session, virtual WebAuthn authenticator.
#   B. Create       — register passkey, deploy + fund + mint via relayer.
#   C. Navigate     — main → Context Rules. Default rule is the only rule
#                     and its Edit/Last-Rule buttons surface even when the
#                     card is collapsed because `canRemove` is false.
#   D. Edit         — click Edit Rule → wait for the edit-mode builder →
#                     replace Rule Name → check Set Expiry → pick the
#                     "10 days" preset.
#   E. Apply        — click Apply Changes; wait for the edit-mode success
#                     card with the "All Changes Applied" heading (each
#                     diff step runs as its own on-chain operation; the
#                     full-success variant only renders when every step
#                     succeeded).
#
# Exit:
#   0 on PASS — "All Changes Applied" success card visible.
#   1 on FAIL — diagnostics dumped into artifact dir.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"

scenario_init "context_rule_edit_name_expiry"

ensure_dev_server || scenario_fail "dev server failed to start"

# New name fits within the 20-byte on-chain cap (B-10).
NEW_RULE_NAME="ed-$(date +%s | tail -c 9)"

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

echo "Phase B: creating wallet for the context-rule-edit scenario..."

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
# Phase C: navigate to Context Rules
# -----------------------------------------------------------------------------

echo "Phase C: navigating to Context Rules..."
MAIN_SNAP="$(snapshot)"
RULES_CARD_REF="$(printf '%s\n' "${MAIN_SNAP}" | \
  grep -oE 'button "Context Rules\. View and manage signing rules" \[ref=e[0-9]+\]' | \
  head -n1 | grep -oE 'e[0-9]+')"
if [[ -z "${RULES_CARD_REF}" ]]; then scenario_fail "could not locate Context Rules card on main screen"; fi
agent-browser --session "${SESSION_NAME}" click "@${RULES_CARD_REF}" > /dev/null
sleep 2

wait_for_body_pattern '1 context rule.s. loaded' 30 || \
  scenario_fail "Context Rules list did not load with the default rule"
screenshot "03_rules_list"

# -----------------------------------------------------------------------------
# Phase D: enter the editor and modify name + expiry
# -----------------------------------------------------------------------------

echo "Phase D: opening the editor..."
EDIT_SNAP="$(snapshot)"
EDIT_REF="$(printf '%s\n' "${EDIT_SNAP}" | \
  grep -oE 'button "Edit Rule" \[ref=e[0-9]+\]' | \
  head -n1 | grep -oE 'e[0-9]+')"
if [[ -z "${EDIT_REF}" ]]; then scenario_fail "could not locate 'Edit Rule' button on the default rule card"; fi
agent-browser --session "${SESSION_NAME}" click "@${EDIT_REF}" > /dev/null
sleep 2

wait_for_body_pattern 'Edit Context Rule' 15 || \
  scenario_fail "edit-mode Context Rule Builder did not render"
screenshot "04_editor_loaded"

# Replace the rule name. The TextField is pre-filled with the existing
# name; `fill` clears + writes, so the new name overwrites cleanly.
NAME_BUILDER_SNAP="$(snapshot)"
RULE_NAME_REF="$(printf '%s\n' "${NAME_BUILDER_SNAP}" | \
  grep -oE 'textbox "Rule Name[^"]*" \[ref=e[0-9]+\]' | \
  head -n1 | grep -oE 'ref=e[0-9]+' | sed 's/ref=//')"
if [[ -z "${RULE_NAME_REF}" ]]; then scenario_fail "could not locate Rule Name textbox"; fi
agent-browser --session "${SESSION_NAME}" fill "@${RULE_NAME_REF}" "${NEW_RULE_NAME}" > /dev/null
sleep 1

# Check "Set Expiry" so the expiry dropdown surfaces.
EXPIRY_SNAP="$(snapshot)"
EXPIRY_CHECK_REF="$(printf '%s\n' "${EXPIRY_SNAP}" | \
  grep -oE 'checkbox "Set Expiry"[^[]*\[checked=false, ref=e[0-9]+\]' | \
  head -n1 | grep -oE 'ref=e[0-9]+' | sed 's/ref=//')"
if [[ -z "${EXPIRY_CHECK_REF}" ]]; then scenario_fail "could not locate 'Set Expiry' checkbox"; fi
agent-browser --session "${SESSION_NAME}" check "@${EXPIRY_CHECK_REF}" > /dev/null
sleep 1

# Open the "Time from now" expiry dropdown. The dropdown surfaces as a
# Flutter combobox (DropdownButtonFormField); the accessible label is
# "Time from now" but Flutter Web exposes it under the `button` tag.
DROPDOWN_SNAP="$(snapshot)"
DROPDOWN_REF="$(printf '%s\n' "${DROPDOWN_SNAP}" | \
  grep -oE 'button "Time from now[^"]*" \[[^]]*ref=e[0-9]+\]' | \
  head -n1 | grep -oE 'ref=e[0-9]+' | sed 's/ref=//')"
if [[ -z "${DROPDOWN_REF}" ]]; then scenario_fail "could not locate 'Time from now' expiry dropdown"; fi
agent-browser --session "${SESSION_NAME}" click "@${DROPDOWN_REF}" > /dev/null
sleep 1

# The dropdown is now open as an overlay menu — items surface as
# menuitem (not button) entries with the semantic label
# "<label> expiry preset." that the builder declares on each DropdownMenuItem.
PRESET_SNAP="$(snapshot)"
PRESET_REF="$(printf '%s\n' "${PRESET_SNAP}" | \
  grep -oE 'menuitem "10 days[^"]*" \[ref=e[0-9]+\]' | \
  head -n1 | grep -oE 'e[0-9]+')"
if [[ -z "${PRESET_REF}" ]]; then scenario_fail "could not locate '10 days' expiry preset"; fi
agent-browser --session "${SESSION_NAME}" click "@${PRESET_REF}" > /dev/null
sleep 1
screenshot "05_form_edited"

# -----------------------------------------------------------------------------
# Phase E: submit + verify
# -----------------------------------------------------------------------------

echo "Phase E: submitting 'Apply Changes'..."
APPLY_SNAP="$(snapshot)"
APPLY_REF="$(printf '%s\n' "${APPLY_SNAP}" | \
  grep -oE 'button "Apply Changes" \[ref=e[0-9]+\]' | \
  head -n1 | grep -oE 'e[0-9]+')"
if [[ -z "${APPLY_REF}" ]]; then scenario_fail "could not locate 'Apply Changes' submit button"; fi
agent-browser --session "${SESSION_NAME}" click "@${APPLY_REF}" > /dev/null

echo "Waiting for edit to complete (passkey + N on-chain ops, up to 180s)..."
# Edit-mode submits the diff as separate on-chain operations (one per
# changed field: name, expiry, signers, policies). Each requires its own
# passkey + sign + submit round-trip. With 2 diffs (name + expiry) the
# total is ~30-60s; cap generously at 180s. The "All Changes Applied"
# title is wrapped in Semantics(header:) but Flutter Web collapses it into
# a parent generic node and it does not surface to body text or the
# snapshot tree. The full-success-only "Done" button (semantic label
# "Done. Close edit context rule screen.") IS exposed and is unique to the
# success card, so poll for it instead.
i=0
SUCCESS=0
while [[ ${i} -lt 90 ]]; do
  POLL_SNAP="$(snapshot)"
  if printf '%s' "${POLL_SNAP}" | grep -q 'Done\. Close edit context rule screen'; then
    SUCCESS=1
    break
  fi
  sleep 2
  i=$((i + 1))
done
if [[ ${SUCCESS} -ne 1 ]]; then
  scenario_fail "edit-mode success card did not appear within 180s (no 'Done' button in snapshot)"
fi
# Verify both edit operations submitted by counting "Copy transaction hash"
# entries on the success card — one per applied diff step (name + expiry =
# two hashes).
FINAL_SNAP="$(snapshot)"
HASH_COUNT="$(printf '%s\n' "${FINAL_SNAP}" | \
  grep -cE 'button "Copy transaction hash"' || true)"
if [[ "${HASH_COUNT}" -lt 2 ]]; then
  scenario_fail "expected at least 2 transaction-hash entries on success card (name + expiry), got ${HASH_COUNT}"
fi
screenshot "06_edit_applied"

echo "Context rule edited: name → '${NEW_RULE_NAME}', expiry → 10 days, on contract ${DEPLOYED_ADDRESS}."

body_text > "${ARTIFACT_DIR}/edit_success_body.txt" || true
snapshot > "${ARTIFACT_DIR}/edit_success_snapshot.txt" || true

scenario_pass
