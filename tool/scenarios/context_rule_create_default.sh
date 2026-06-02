#!/usr/bin/env bash
# Scenario 19 — context_rule_create_default
#
# Self-contained Context Rule Builder flow: create a new rule with the
# default context type ("Default — Any Operation"), no policies, and a
# single delegated G-address signer. Exercises the simplest builder path —
# no policy attachment, no multi-signer routing.
#
# Why delegated and not passkey: the form requires at least one signer
# before the submit CTA becomes enabled, and a delegated G-address only
# needs the address typed into the field — no extra WebAuthn ceremony
# beyond the one already triggered by submit. The new rule's signer set
# does NOT affect this scenario's submit path because the CREATE itself
# is authorised by the existing default rule (which the connected passkey
# satisfies). Once the new rule is created, future operations matching the
# Default context type could be authorised by either rule.
#
# Phases:
#   A. Setup        — fresh browser session, virtual WebAuthn authenticator.
#   B. Create       — register passkey, deploy + fund + mint via relayer.
#   C. Navigate     — main → Context Rules → "+ Add Rule" (Context Rule
#                     Builder screen).
#   D. Fill         — Rule Name + Signer Type=Delegated + delegated address.
#   E. Submit       — click "Create Context Rule"; wait for "Transaction
#                     Successful" success card (passkey ceremony +
#                     simulation + submission).
#
# Exit:
#   0 on PASS — success card with "Transaction Successful" heading visible.
#   1 on FAIL — diagnostics dumped into artifact dir.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"

scenario_init "context_rule_create_default"

ensure_dev_server || scenario_fail "dev server failed to start"

DELEGATED_SIGNER="GAIH3ULLFQ4DGSECF2AR555KZ4KNDGEKN4AFI4SU2M7B43MGK3QJZNSR"
# Rule names are capped at 20 bytes by the on-chain contract (B-10 was
# surfaced by a longer name overflowing this limit). Use the last 8 digits
# of the epoch timestamp to stay well under the cap while keeping the name
# unique enough for parallel scenario runs.
RULE_NAME="agt-$(date +%s | tail -c 9)"

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

echo "Phase B: creating wallet for the context-rule-create-default scenario..."

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
# Phase C: navigate to Context Rule Builder
# -----------------------------------------------------------------------------

echo "Phase C: navigating to Context Rule Builder..."
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

wait_for_body_pattern '1 context rule.s. loaded' 30 || \
  scenario_fail "Context Rules list did not load"
screenshot "04_rules_list"

# Click "+ Add Rule" to open the builder.
ADD_SNAP="$(snapshot)"
ADD_REF="$(printf '%s\n' "${ADD_SNAP}" | \
  grep -oE 'button "\+ Add Rule" \[ref=e[0-9]+\]' | \
  head -n1 | grep -oE 'e[0-9]+')"
if [[ -z "${ADD_REF}" ]]; then scenario_fail "could not locate '+ Add Rule' button"; fi
agent-browser --session "${SESSION_NAME}" click "@${ADD_REF}" > /dev/null
sleep 2

wait_for_body_pattern 'Add Context Rule' 10 || \
  scenario_fail "Context Rule Builder screen did not render"
screenshot "05_builder_screen"

# -----------------------------------------------------------------------------
# Phase D: fill form
# -----------------------------------------------------------------------------

echo "Phase D: filling Rule Name + Delegated Signer..."

# Fill Rule Name. Leave Context Type at its default (Default — Any Operation).
NAME_BUILDER_SNAP="$(snapshot)"
RULE_NAME_REF="$(printf '%s\n' "${NAME_BUILDER_SNAP}" | \
  grep -oE 'textbox "Rule Name[^"]*" \[ref=e[0-9]+\]' | \
  head -n1 | grep -oE 'ref=e[0-9]+' | sed 's/ref=//')"
if [[ -z "${RULE_NAME_REF}" ]]; then scenario_fail "could not locate Rule Name textbox"; fi
agent-browser --session "${SESSION_NAME}" fill "@${RULE_NAME_REF}" "${RULE_NAME}" > /dev/null
sleep 1

# The Signer Type dropdown defaults to "Delegated (G-address)" — exactly what
# we want for this scenario. Fill the Stellar Address field directly.
ADDR_SNAP="$(snapshot)"
ADDR_REF="$(printf '%s\n' "${ADDR_SNAP}" | \
  grep -oE 'textbox "Stellar Address[^"]*" \[ref=e[0-9]+\]' | \
  head -n1 | grep -oE 'ref=e[0-9]+' | sed 's/ref=//')"
if [[ -z "${ADDR_REF}" ]]; then scenario_fail "could not locate Stellar Address (G-address) textbox"; fi
agent-browser --session "${SESSION_NAME}" fill "@${ADDR_REF}" "${DELEGATED_SIGNER}" > /dev/null
sleep 1

# Click "Add Delegated Signer" to stage the signer.
STAGE_SNAP="$(snapshot)"
STAGE_REF="$(printf '%s\n' "${STAGE_SNAP}" | \
  grep -oE 'button "Add Delegated Signer" \[ref=e[0-9]+\]' | \
  head -n1 | grep -oE 'e[0-9]+')"
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
  head -n1 | grep -oE 'e[0-9]+')"
if [[ -z "${SUBMIT_REF}" ]]; then scenario_fail "could not locate Create Context Rule submit button"; fi
agent-browser --session "${SESSION_NAME}" click "@${SUBMIT_REF}" > /dev/null

echo "Waiting for context rule creation to complete (passkey + simulate + sign + submit, up to 120s)..."
# The success card surfaces a Semantics(header:true) "Transaction Successful"
# title which Flutter Web exposes to the snapshot's heading list.
i=0
SUCCESS=0
while [[ ${i} -lt 60 ]]; do
  POLL_SNAP="$(snapshot)"
  if printf '%s' "${POLL_SNAP}" | grep -q 'Transaction Successful'; then
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

echo "Context rule '${RULE_NAME}' created on contract ${DEPLOYED_ADDRESS}."

body_text > "${ARTIFACT_DIR}/rule_created_body.txt" || true
snapshot > "${ARTIFACT_DIR}/rule_created_snapshot.txt" || true

scenario_pass
