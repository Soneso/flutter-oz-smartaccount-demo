#!/usr/bin/env bash
# Scenario 2 — wallet_create
#
# First passkey-gated scenario. Boots the Flutter web demo, attaches a Chrome
# virtual WebAuthn authenticator over CDP, then drives the Create Wallet flow
# end-to-end on Stellar testnet:
#
#   1. Navigate to the Create Wallet screen from the main screen.
#   2. Enter a unique passkey name.
#   3. Tap Create Wallet, triggering the passkey ceremony against the
#      virtual authenticator, the relayer-sponsored deploy, and the
#      DEMO-token mint via FriendBot-funded admin.
#   4. Wait for the "Wallet Created Successfully" result card (up to 180s
#      to absorb RPC round-trips, first-ever admin funding, and indexer
#      propagation).
#   5. Verify the Contract Address and Transaction Hash are surfaced.
#
# Authenticator is detached automatically on exit via the EXIT trap
# registered in _lib.sh::attach_virtual_authenticator.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"

scenario_init "wallet_create"

ensure_dev_server || scenario_fail "dev server failed to start"

# Fresh browser profile per run so no prior IndexedDB credential or
# half-created wallet bleeds in.
close_session
open_app

# Snapshot the main screen so the artifact dir captures the no-wallet
# baseline alongside the post-create result.
screenshot "01_main_no_wallet"

attach_virtual_authenticator || scenario_fail "could not attach virtual authenticator"

echo "Navigating to Create Wallet screen..."
NAV_SNAP="$(snapshot)"
NAV_REF="$(printf '%s\n' "${NAV_SNAP}" | \
  grep -oE 'button "Create Wallet" \[ref=e[0-9]+\]' | \
  head -n1 | grep -oE 'e[0-9]+')"
if [[ -z "${NAV_REF}" ]]; then
  scenario_fail "could not locate 'Create Wallet' button on main screen"
fi
agent-browser --session "${SESSION_NAME}" click "@${NAV_REF}" > /dev/null
sleep 2

if ! wait_for_body_pattern 'Wallet Creation' 15; then
  scenario_fail "Create Wallet screen did not render (no 'Wallet Creation' heading)"
fi
screenshot "02_create_wallet_screen"

# Pick a unique passkey name per run so repeated scenario invocations do not
# alias each other under the indexer's username → contract mapping.
PASSKEY_NAME="agent-$(date +%s)"
echo "Filling passkey name: ${PASSKEY_NAME}"
# Flutter Web concatenates form-label semantics into the textbox node's
# accessibility name, so match on the textbox whose name begins with
# "Passkey Name " (trailing space anchors on the field label rather than a
# stray substring elsewhere in the tree).
NAME_SNAP="$(snapshot)"
NAME_REF="$(printf '%s\n' "${NAME_SNAP}" | \
  grep -oE 'textbox "Passkey Name [^"]*" \[ref=e[0-9]+\]' | \
  head -n1 | grep -oE 'ref=e[0-9]+' | sed 's/ref=//')"
if [[ -z "${NAME_REF}" ]]; then
  scenario_fail "could not locate 'Passkey Name' textbox ref"
fi
agent-browser --session "${SESSION_NAME}" fill "@${NAME_REF}" "${PASSKEY_NAME}" > /dev/null

echo "Tapping Create Wallet (triggers passkey ceremony + relayer deploy + mint)..."
# The Create Wallet button on this screen carries the same accessibility name
# as the main-screen CTA. Re-snapshot after the fill so refs are fresh.
sleep 1
CREATE_SNAP="$(snapshot)"
CREATE_REF="$(printf '%s\n' "${CREATE_SNAP}" | \
  grep -oE 'button "Create Wallet" \[ref=e[0-9]+\]' | \
  tail -n1 | grep -oE 'e[0-9]+')"
if [[ -z "${CREATE_REF}" ]]; then
  scenario_fail "could not locate the on-screen 'Create Wallet' button ref"
fi
agent-browser --session "${SESSION_NAME}" click "@${CREATE_REF}" > /dev/null

echo "Waiting for the deployment + mint to complete (up to 180s)..."
# The success card surfaces its title via a Semantics(label:) which is not
# captured by DOM body text; assert instead on the rendered Contract Address
# row, Transaction Hash row, and the post-success "Go to Main Screen" CTA.
if ! wait_for_body_pattern 'Contract Address:' 180; then
  scenario_fail "Contract Address did not appear within 180s (deploy still pending or failed)"
fi
screenshot "03_wallet_created"

echo "Verifying result card markers..."
if ! assert_body_contains \
    "Credential ID:" \
    "Contract Address:" \
    "Transaction Hash:" \
    "Go to Main Screen"; then
  scenario_fail "expected result-card markers missing from body"
fi

# Extract the deployed C-address and tx hash so the artifact log carries them
# explicitly (handy when triaging downstream connect/transfer scenarios).
DEPLOY_SUMMARY="${ARTIFACT_DIR}/deploy_summary.txt"
{
  echo "passkey_name=${PASSKEY_NAME}"
  body_text | tr '\n' ' ' | grep -oE 'Contract Address: C[A-Z2-7]{55}' | head -n1
  body_text | tr '\n' ' ' | grep -oE 'Transaction Hash: [0-9a-f]{64}' | head -n1
} > "${DEPLOY_SUMMARY}" 2>/dev/null || true
echo "Deploy summary written to ${DEPLOY_SUMMARY}"

# Capture the final body text + snapshot so the artifact dir preserves the
# rendered contract address and hash for downstream inspection.
body_text > "${ARTIFACT_DIR}/post_create_body.txt" || true
snapshot > "${ARTIFACT_DIR}/post_create_snapshot.txt" || true

scenario_pass
