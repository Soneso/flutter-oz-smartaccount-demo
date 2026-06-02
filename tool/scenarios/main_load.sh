#!/usr/bin/env bash
# Scenario 1 — main_load
#
# Boots the Flutter web dev server, opens the app in agent-browser, and
# verifies the main screen renders in the no-wallet state. No passkey
# ceremony, no virtual authenticator. Foundational smoke test that proves
# the harness wiring works end-to-end before any passkey-gated scenario.
#
# Assertions:
#   - App title "Stellar Smart Account Demo" is visible.
#   - Sub-title "Testnet" is visible.
#   - No-wallet branch is rendered ("No wallet connected" + the two CTAs
#     "Create Wallet" and "Connect Wallet").
#
# Exit:
#   0 on PASS — baseline screenshot landed in artifact dir.
#   1 on FAIL — diagnostics (screenshot, body text, accessibility snapshot)
#               dumped into artifact dir.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"

scenario_init "main_load"

ensure_dev_server || scenario_fail "dev server failed to start"

# Close any stale session for this scenario so each run starts from a fresh
# browser profile (no IndexedDB credentials from prior runs).
close_session

open_app

echo "Waiting for Flutter to render the main screen..."
if ! wait_for_body_pattern 'Stellar Smart Account Demo' 30; then
  scenario_fail "main screen did not render within 30s"
fi

echo "Asserting no-wallet branch markers..."
if ! assert_body_contains \
    "Stellar Smart Account Demo" \
    "Testnet" \
    "No wallet connected" \
    "Create Wallet" \
    "Connect Wallet"; then
  scenario_fail "expected no-wallet state markers missing from body"
fi

screenshot "main_no_wallet"

scenario_pass
