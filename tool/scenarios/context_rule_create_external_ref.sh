#!/usr/bin/env bash
# Scenario context_rule_create_external_ref
#
# Self-contained Context Rule Builder flow for the "Create Contract from
# Reference" context type: create a rule that matches contract deployments
# from the executable reference an owner contract stores under a tag, see the
# rule's label in the Context Rules list, then reopen it in the editor and
# see the stored owner and tag again.
#
# The rule stores the owner address and the tag without resolving the
# reference, so any contract address serves as the owner. The scenario uses
# the testnet XLM Stellar Asset Contract. The single delegated G-address
# signer only satisfies the builder's "at least one signer" gate; the CREATE
# itself is authorised by the wallet's default rule (connected passkey).
#
# Phases:
#   A. Setup        - fresh browser session, virtual WebAuthn authenticator.
#   B. Create       - register passkey, deploy + fund + mint via relayer.
#   C. Navigate     - main -> Context Rules -> "+ Add Rule".
#   D. Fill         - Rule Name, Context Type "Create Contract from Reference",
#                     Executable Owner, Executable Tag, delegated signer.
#   E. Submit       - "Create Context Rule"; wait for "Transaction
#                     Successful".
#   F. List         - Go Back; wait for 2 rules; assert the new rule's card
#                     label "Create Contract from Ref: <owner> / <tag>".
#   G. Reopen       - Edit Rule on the new rule; assert the editor shows the
#                     stored context type and the owner and tag fields,
#                     read-only. Screenshot 09 records the field values,
#                     which Flutter web does not expose to the tree.
#
# Exit:
#   0 on PASS - rule created, listed with its label, reopened in the editor.
#   1 on FAIL - diagnostics dumped into artifact dir.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"

scenario_init "context_rule_create_external_ref"

ensure_dev_server || scenario_fail "dev server failed to start"

DELEGATED_SIGNER="GAIH3ULLFQ4DGSECF2AR555KZ4KNDGEKN4AFI4SU2M7B43MGK3QJZNSR"
REF_OWNER="CDLZFC3SYJYDZT7K67VZ75HPJVIEUVNIXF47ZG2FB2RMQQVU2HHGCYSC"
# Rule names are capped at 20 bytes by the on-chain contract. The epoch tail
# keeps the name and the tag unique per run.
RUN_ID="$(date +%s | tail -c 9)"
RULE_NAME="ref-${RUN_ID}"
REF_TAG="tag-${RUN_ID}"
EXPECTED_LABEL="Create Contract from Ref: ${REF_OWNER:0:4}...${REF_OWNER: -4} / ${REF_TAG}"

# Full accessibility tree, static text included. The interactive snapshot of
# _lib.sh::snapshot leaves out the rule card's context-type pill.
full_snapshot() {
  agent-browser --session "${SESSION_NAME}" snapshot 2>/dev/null || true
}

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

echo "Phase B: creating wallet for the context-rule-create-external-ref scenario..."

NAV_SNAP="$(snapshot)"
NAV_REF="$(printf '%s\n' "${NAV_SNAP}" | \
  grep -oE 'button "Create Wallet" \[ref=e[0-9]+\]' | \
  head -n1 | grep -oE 'e[0-9]+' || true)"
if [[ -z "${NAV_REF}" ]]; then scenario_fail "could not locate 'Create Wallet' button on main screen"; fi
agent-browser --session "${SESSION_NAME}" click "@${NAV_REF}" > /dev/null
sleep 2

wait_for_body_pattern 'Wallet Creation' 15 || \
  scenario_fail "Create Wallet screen did not render"

PASSKEY_NAME="agent-$(date +%s)"
NAME_SNAP="$(snapshot)"
NAME_REF="$(printf '%s\n' "${NAME_SNAP}" | \
  grep -oE 'textbox "Passkey Name [^"]*" \[ref=e[0-9]+\]' | \
  head -n1 | grep -oE 'ref=e[0-9]+' | sed 's/ref=//' || true)"
if [[ -z "${NAME_REF}" ]]; then scenario_fail "could not locate 'Passkey Name' textbox"; fi
agent-browser --session "${SESSION_NAME}" fill "@${NAME_REF}" "${PASSKEY_NAME}" > /dev/null
sleep 1

CREATE_SNAP="$(snapshot)"
CREATE_REF="$(printf '%s\n' "${CREATE_SNAP}" | \
  grep -oE 'button "Create Wallet" \[ref=e[0-9]+\]' | \
  tail -n1 | grep -oE 'e[0-9]+' || true)"
if [[ -z "${CREATE_REF}" ]]; then scenario_fail "could not locate on-screen 'Create Wallet' CTA"; fi
agent-browser --session "${SESSION_NAME}" click "@${CREATE_REF}" > /dev/null

echo "Waiting for deployment + mint to complete (up to 180s)..."
wait_for_body_pattern 'Contract Address:' 180 || \
  scenario_fail "deploy did not complete within 180s"
screenshot "02_wallet_created"

DEPLOYED_ADDRESS="$(body_text | tr -d '\n' | \
  grep -oE 'Contract Address: C[A-Z2-7]{55}' | \
  head -n1 | sed 's/^Contract Address: //' || true)"
if [[ -z "${DEPLOYED_ADDRESS}" || ${#DEPLOYED_ADDRESS} -ne 56 ]]; then
  scenario_fail "could not capture deployed contract address (got: '${DEPLOYED_ADDRESS}')"
fi
echo "Captured deployed contract: ${DEPLOYED_ADDRESS}"
echo "${DEPLOYED_ADDRESS}" > "${ARTIFACT_DIR}/deployed_contract.txt"

# -----------------------------------------------------------------------------
# Phase C: navigate to Context Rule Builder
# -----------------------------------------------------------------------------

echo "Phase C: navigating to Context Rule Builder..."
GO_MAIN_SNAP="$(snapshot)"
GO_MAIN_REF="$(printf '%s\n' "${GO_MAIN_SNAP}" | \
  grep -oE 'button "Go to Main Screen" \[ref=e[0-9]+\]' | \
  head -n1 | grep -oE 'e[0-9]+' || true)"
if [[ -z "${GO_MAIN_REF}" ]]; then scenario_fail "could not locate 'Go to Main Screen' button on success card"; fi
agent-browser --session "${SESSION_NAME}" click "@${GO_MAIN_REF}" > /dev/null
sleep 2

wait_for_body_pattern 'Copy contract address' 10 || \
  scenario_fail "main-screen WalletStatusCard did not render after navigating home"
screenshot "03_main_connected"

# Depending on the Flutter version, the card's accessible name carries its
# subtitle ("Context Rules. View and manage signing rules") or only the title.
MAIN_SNAP="$(snapshot)"
RULES_CARD_REF="$(printf '%s\n' "${MAIN_SNAP}" | \
  grep -oE 'button "Context Rules(\. View and manage signing rules)?" \[ref=e[0-9]+\]' | \
  head -n1 | grep -oE 'e[0-9]+' || true)"
if [[ -z "${RULES_CARD_REF}" ]]; then scenario_fail "could not locate Context Rules card on main screen"; fi
agent-browser --session "${SESSION_NAME}" click "@${RULES_CARD_REF}" > /dev/null
sleep 2

wait_for_body_pattern '1 context rule.s. loaded' 30 || \
  scenario_fail "Context Rules list did not load"
screenshot "04_rules_list"

ADD_SNAP="$(snapshot)"
ADD_REF="$(printf '%s\n' "${ADD_SNAP}" | \
  grep -oE 'button "\+ Add Rule" \[ref=e[0-9]+\]' | \
  head -n1 | grep -oE 'e[0-9]+' || true)"
if [[ -z "${ADD_REF}" ]]; then scenario_fail "could not locate '+ Add Rule' button"; fi
agent-browser --session "${SESSION_NAME}" click "@${ADD_REF}" > /dev/null
sleep 2

wait_for_body_pattern 'Add Context Rule' 10 || \
  scenario_fail "Context Rule Builder screen did not render"
screenshot "05_builder_screen"

# -----------------------------------------------------------------------------
# Phase D: fill form
# -----------------------------------------------------------------------------

echo "Phase D: filling Rule Name, Context Type, owner, tag and signer..."

NAME_BUILDER_SNAP="$(snapshot)"
RULE_NAME_REF="$(printf '%s\n' "${NAME_BUILDER_SNAP}" | \
  grep -oE 'textbox "Rule Name[^"]*" \[ref=e[0-9]+\]' | \
  head -n1 | grep -oE 'ref=e[0-9]+' | sed 's/ref=//' || true)"
if [[ -z "${RULE_NAME_REF}" ]]; then scenario_fail "could not locate Rule Name textbox"; fi
agent-browser --session "${SESSION_NAME}" fill "@${RULE_NAME_REF}" "${RULE_NAME}" > /dev/null
sleep 1

# Open the Context Type dropdown. The closed DropdownButtonFormField
# surfaces as a button labeled with the field label and the selection.
TYPE_SNAP="$(snapshot)"
TYPE_REF="$(printf '%s\n' "${TYPE_SNAP}" | \
  grep -oE 'button "Context Type[^"]*" \[[^]]*ref=e[0-9]+\]' | \
  head -n1 | grep -oE 'ref=e[0-9]+' | sed 's/ref=//' || true)"
if [[ -z "${TYPE_REF}" ]]; then scenario_fail "could not locate 'Context Type' dropdown"; fi
agent-browser --session "${SESSION_NAME}" click "@${TYPE_REF}" > /dev/null
sleep 1

# While open, the options surface as menuitem entries labeled
# "<displayName>. <description>".
OPTION_SNAP="$(snapshot)"
OPTION_REF="$(printf '%s\n' "${OPTION_SNAP}" | \
  grep -oE 'menuitem "Create Contract from Reference\.[^"]*" \[ref=e[0-9]+\]' | \
  head -n1 | grep -oE 'ref=e[0-9]+' | sed 's/ref=//' || true)"
if [[ -z "${OPTION_REF}" ]]; then scenario_fail "could not locate 'Create Contract from Reference' option"; fi
agent-browser --session "${SESSION_NAME}" click "@${OPTION_REF}" > /dev/null
sleep 1

OWNER_SNAP="$(snapshot)"
OWNER_REF="$(printf '%s\n' "${OWNER_SNAP}" | \
  grep -oE 'textbox "Executable Owner[^"]*" \[ref=e[0-9]+\]' | \
  head -n1 | grep -oE 'ref=e[0-9]+' | sed 's/ref=//' || true)"
if [[ -z "${OWNER_REF}" ]]; then scenario_fail "could not locate 'Executable Owner' textbox"; fi
agent-browser --session "${SESSION_NAME}" fill "@${OWNER_REF}" "${REF_OWNER}" > /dev/null
sleep 1

TAG_SNAP="$(snapshot)"
TAG_REF="$(printf '%s\n' "${TAG_SNAP}" | \
  grep -oE 'textbox "Executable Tag[^"]*" \[ref=e[0-9]+\]' | \
  head -n1 | grep -oE 'ref=e[0-9]+' | sed 's/ref=//' || true)"
if [[ -z "${TAG_REF}" ]]; then scenario_fail "could not locate 'Executable Tag' textbox"; fi
agent-browser --session "${SESSION_NAME}" fill "@${TAG_REF}" "${REF_TAG}" > /dev/null
sleep 1

ADDR_SNAP="$(snapshot)"
ADDR_REF="$(printf '%s\n' "${ADDR_SNAP}" | \
  grep -oE 'textbox "Stellar Address[^"]*" \[ref=e[0-9]+\]' | \
  head -n1 | grep -oE 'ref=e[0-9]+' | sed 's/ref=//' || true)"
if [[ -z "${ADDR_REF}" ]]; then scenario_fail "could not locate Stellar Address (G-address) textbox"; fi
agent-browser --session "${SESSION_NAME}" fill "@${ADDR_REF}" "${DELEGATED_SIGNER}" > /dev/null
sleep 1

STAGE_SNAP="$(snapshot)"
STAGE_REF="$(printf '%s\n' "${STAGE_SNAP}" | \
  grep -oE 'button "Add Delegated Signer" \[ref=e[0-9]+\]' | \
  head -n1 | grep -oE 'e[0-9]+' || true)"
if [[ -z "${STAGE_REF}" ]]; then scenario_fail "could not locate 'Add Delegated Signer' button"; fi
agent-browser --session "${SESSION_NAME}" click "@${STAGE_REF}" > /dev/null
sleep 1
screenshot "06_form_filled"

# -----------------------------------------------------------------------------
# Phase E: submit + verify success
# -----------------------------------------------------------------------------

echo "Phase E: submitting 'Create Context Rule'..."
SUBMIT_SNAP="$(snapshot)"
SUBMIT_REF="$(printf '%s\n' "${SUBMIT_SNAP}" | \
  grep -oE 'button "Create Context Rule" \[ref=e[0-9]+\]' | \
  head -n1 | grep -oE 'e[0-9]+' || true)"
if [[ -z "${SUBMIT_REF}" ]]; then scenario_fail "could not locate Create Context Rule submit button"; fi
agent-browser --session "${SESSION_NAME}" click "@${SUBMIT_REF}" > /dev/null

echo "Waiting for context rule creation to complete (passkey + simulate + sign + submit, up to 120s)..."
i=0
SUCCESS=0
while [[ ${i} -lt 60 ]]; do
  POLL_SNAP="$(snapshot)"
  if grep -q 'Transaction Successful' <<< "${POLL_SNAP}"; then
    SUCCESS=1
    break
  fi
  sleep 2
  i=$((i + 1))
done
if [[ ${SUCCESS} -ne 1 ]]; then
  scenario_fail "Transaction Successful card did not appear within 120s"
fi
screenshot "07_rule_created"

# -----------------------------------------------------------------------------
# Phase F: list label
# -----------------------------------------------------------------------------

echo "Phase F: returning to the Context Rules list..."
BACK_SNAP="$(snapshot)"
BACK_REF="$(printf '%s\n' "${BACK_SNAP}" | \
  grep -oE 'button "Go Back" \[ref=e[0-9]+\]' | \
  head -n1 | grep -oE 'e[0-9]+' || true)"
if [[ -z "${BACK_REF}" ]]; then scenario_fail "could not locate 'Go Back' button on success card"; fi
agent-browser --session "${SESSION_NAME}" click "@${BACK_REF}" > /dev/null
sleep 2

wait_for_body_pattern '2 context rule.s. loaded' 30 || \
  scenario_fail "Context Rules list did not refresh to 2 rules after creating the rule"
screenshot "08_rules_two"

# Each rule card surfaces as one group named "#<id> <name> <type label> ...".
LIST_TREE="$(full_snapshot)"
printf '%s\n' "${LIST_TREE}" > "${ARTIFACT_DIR}/rules_two_full_snapshot.txt"
if ! grep -qF "group \"#1 ${RULE_NAME} ${EXPECTED_LABEL} " <<< "${LIST_TREE}"; then
  scenario_fail "rule list does not show the label '${EXPECTED_LABEL}' on rule '${RULE_NAME}'"
fi
echo "Rule list shows '${EXPECTED_LABEL}'."

# -----------------------------------------------------------------------------
# Phase G: reopen in the editor
# -----------------------------------------------------------------------------

echo "Phase G: reopening the rule in the editor..."
# listContextRules returns rules in id-ascending order, so the new rule is
# the second card and its "Edit Rule" button is the last one.
EDIT_SNAP="$(snapshot)"
EDIT_REF="$(printf '%s\n' "${EDIT_SNAP}" | \
  grep -oE 'button "Edit Rule" \[ref=e[0-9]+\]' | \
  tail -n1 | grep -oE 'e[0-9]+' || true)"
if [[ -z "${EDIT_REF}" ]]; then scenario_fail "could not locate the new rule's 'Edit Rule' button"; fi
agent-browser --session "${SESSION_NAME}" click "@${EDIT_REF}" > /dev/null
sleep 2

wait_for_body_pattern 'Edit Context Rule' 15 || \
  scenario_fail "edit-mode Context Rule Builder did not render"

# The editor loads the rule from the chain before it fills the form. Flutter
# web leaves the DOM value of an unfocused text field empty, and the edit
# mode disables the owner and tag fields, so their values cannot be read
# here; screenshot 09 records them. The check covers what the tree exposes:
# the stored context type and both fields, read-only. The textbox names are
# the field labels, which the leftover inputs of the create step (named by
# their hints) do not carry.
i=0
REOPENED=0
while [[ ${i} -lt 15 ]]; do
  REOPEN_TREE="$(full_snapshot)"
  if grep -qF 'button "Context Type Create Contract from Reference ' <<< "${REOPEN_TREE}" && \
     grep -qF 'textbox "Executable Owner (C...)" [disabled' <<< "${REOPEN_TREE}" && \
     grep -qF 'textbox "Executable Tag" [disabled' <<< "${REOPEN_TREE}"; then
    REOPENED=1
    break
  fi
  sleep 2
  i=$((i + 1))
done
printf '%s\n' "${REOPEN_TREE}" > "${ARTIFACT_DIR}/rule_reopened_full_snapshot.txt"
screenshot "09_rule_reopened"
if [[ ${REOPENED} -ne 1 ]]; then
  scenario_fail "editor does not show the 'Create Contract from Reference' type with read-only owner and tag fields"
fi

echo "Context rule '${RULE_NAME}' (owner ${REF_OWNER}, tag ${REF_TAG}) created, listed and reopened on contract ${DEPLOYED_ADDRESS}."

body_text > "${ARTIFACT_DIR}/rule_reopened_body.txt" || true
snapshot > "${ARTIFACT_DIR}/rule_reopened_snapshot.txt" || true

scenario_pass
