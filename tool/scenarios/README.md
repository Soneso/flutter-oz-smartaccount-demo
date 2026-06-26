# Browser test scenarios

End-to-end browser scenarios for the Flutter web build of the smart-account
demo. Each scenario is an executable bash script that drives a real Chrome
browser through a user flow (wallet creation, transfers, allowance
approvals, context-rule edits, etc.) on Stellar testnet, then asserts the
expected UI state.

## Quick start

```
./tool/scenarios/main_load.sh
```

The script auto-builds the Flutter web bundle, starts a static server on
`localhost:5173`, spawns a Chrome instance via `agent-browser`, runs the
flow, and prints `PASS` / `FAIL` on exit. Artifacts (screenshots, body-text
dumps, snapshot dumps) land in
`tool/scenarios/artifacts/<scenario>-<utc-timestamp>/`. On `FAIL` the
artifact dir also contains `failure.png`, `body_text.txt`, `snapshot.txt`,
and `log_box.txt`.

## Prerequisites

- **Vercel `agent-browser` CLI** on `PATH` (the harness was developed
  against v0.27.0). Confirm with `agent-browser --help`. If the CLI is
  installed but not on `PATH`, add the install dir or symlink the binary
  into `~/.local/bin`.
- **Google Chrome** (the regular desktop install — `agent-browser` drives
  the system Chrome).
- **Flutter SDK** (the harness was built against 3.35.x). `flutter doctor`
  should pass.
- **Python 3** (used by `tool/run_web_dev.sh` to serve the built bundle
  via `python3 -m http.server`).
- **Stellar testnet access** — no auth, the relayer + indexer + Friendbot
  endpoints are public.

## Architecture

```
+-----------------------------+
| ./tool/scenarios/X.sh       |
|   sources _lib.sh           |
|   calls helpers + agent-    |
|   browser CLI               |
+--------------+--------------+
               |
               | spawns / re-uses
               v
+-----------------------------+
| agent-browser session       |
| (= one Chrome instance      |
| with CDP enabled)           |
+--------------+--------------+
               |
               | drives via CDP
               v
+-----------------------------+
| Chrome → http://localhost:5173/
|   Flutter web bundle (built |
|   via `flutter build web    |
|   --release`)               |
+--------------+--------------+
               |
               | http
               v
+-----------------------------+
| python3 -m http.server 5173 |
| serving build/web/          |
+-----------------------------+
```

For passkey-gated scenarios, a persistent Python subprocess
(`_cdp_webauthn_holder.py`) holds a CDP WebSocket open and registers a
virtual WebAuthn authenticator inside Chrome via the `WebAuthn.enable` +
`WebAuthn.addVirtualAuthenticator` CDP commands. The holder keeps the
WebSocket alive for the scenario's lifetime so the virtual authenticator
survives multiple CDP commands; without this Chrome tears the authenticator
down between calls. The holder PID is killed by the EXIT trap in
`_lib.sh::scenario_cleanup`.

## Scenario anatomy

Every script follows the same skeleton:

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"

scenario_init "name"          # registers cleanup trap
ensure_dev_server || scenario_fail "dev server failed to start"

close_session                 # kill any stale session for this name
open_app                      # fresh GET on $BASE_URL at 1280x1800
screenshot "01_initial"

attach_virtual_authenticator || scenario_fail "..."  # passkey scenarios only

# Phase B, C, D, ... — interact with the UI:
SNAP="$(snapshot)"
REF="$(printf '%s\n' "${SNAP}" | grep -oE 'button "Label" \[ref=e[0-9]+\]' \
  | head -n1 | grep -oE 'e[0-9]+')"
if [[ -z "${REF}" ]]; then scenario_fail "could not locate Label"; fi
agent-browser --session "${SESSION_NAME}" click "@${REF}" > /dev/null
sleep 2

wait_for_body_pattern 'Expected text' 30 || scenario_fail "did not render"
screenshot "02_after_click"

scenario_pass
```

### `_lib.sh` helpers

| Helper | Purpose |
|---|---|
| `scenario_init <name>` | Sets `SCENARIO_NAME`, `SESSION_NAME` (`smartaccount-<name>`), creates `ARTIFACT_DIR`, installs the `EXIT` trap that closes the browser session and detaches the authenticator |
| `ensure_dev_server` | Starts `tool/run_web_dev.sh` if `localhost:5173` is not already answering. Idempotent |
| `close_session` | `agent-browser --session "$SESSION_NAME" close` (silent on no-op) — clears any prior state for this scenario name |
| `open_app` | Opens `$BASE_URL` in a fresh session, sets viewport to 1280x1800. The tall viewport is required: Flutter Web does not expose offscreen widgets to the semantic tree, and the default 1280x577 height clipped buttons during scenario authoring |
| `attach_virtual_authenticator` | Discovers the per-session CDP port via `agent-browser get cdp-url`, then launches `_cdp_webauthn_holder.py` as a background subprocess. Polls the holder log for the `READY <authenticatorId>` line (10s timeout) |
| `detach_virtual_authenticator` | Kills the holder PID (idempotent) |
| `scenario_cleanup` | EXIT-trap target — calls `detach_virtual_authenticator` then `agent-browser close` |
| `screenshot "<name>"` | Saves PNG to `$ARTIFACT_DIR/<name>.png` (preferred prefix: `NN_` for ordering) |
| `snapshot` | Returns the accessibility-tree snapshot to stdout — use as `SNAP="$(snapshot)"` |
| `body_text` | Returns the visible-text dump — use as `BODY="$(body_text)"` |
| `wait_for_body_pattern '<pattern>' <attempts>` | Polls `body_text` once per second; matches via `grep -qE` (extended regex). Returns 0 on match, 1 on timeout |
| `assert_body_contains '<pattern>'` | One-shot version that calls `scenario_fail` on miss |
| `scenario_pass` | Prints the green `PASS` line and `exit 0` |
| `scenario_fail "<msg>"` | Dumps `body_text.txt`, `snapshot.txt`, `failure.png`, `log_box.txt` to `$ARTIFACT_DIR`, prints `FAIL` line, `exit 1` |

## Flutter Web snapshot patterns

The `agent-browser snapshot` command returns Chrome's accessibility tree.
Element forms relevant to this codebase:

```
- heading "Section title" [level=2, ref=e1]
- button "Click me" [ref=e2]
- button "Click me" [disabled, ref=e3]
- button "Expand category" [expanded=false, ref=e4]
- textbox "Label" [ref=e5]                 # empty field
- textbox "Hint or label" [ref=e6]: value  # filled field
- checkbox "Toggle name" [checked=true, ref=e7]
- menuitem "Dropdown option label" [ref=e8]   # only when dropdown is open
- generic "..." [ref=e9]                       # collapsed container — see below
```

Ref numbers (`eN`) are sequential within a single `snapshot` call and are
**not stable across calls**. Always capture a fresh snapshot immediately
before grep-extracting refs.

### What surfaces to body text vs snapshot

Flutter Web's accessibility tree is incomplete for production builds. Key
patterns discovered while authoring the existing scenarios:

| Widget | In body text? | In snapshot? | Notes |
|---|---|---|---|
| `Text` inside a `Semantics(header: true)` | Sometimes | Often as `heading` | Reliable for top-of-screen titles; collapses into a `generic` parent inside cards |
| `FilledButton(child: Text("Foo"))` | Yes | Yes as `button "Foo"` | The most reliable click target |
| `LoadingButton(label: "Foo")` | Yes | Yes as `button "Foo"` (with `label` from inner `Semantics`) | Same as above |
| `TextField(decoration: InputDecoration(labelText: "X"))` | Sometimes | Yes as `textbox "X"` | Use the label as the grep anchor |
| `DropdownButtonFormField(items: [DropdownMenuItem(...)])` | Yes (collapsed selection) | Closed: `button "X"`. Open: items render as `menuitem` not `button` | **Important pitfall** — when opened, options are `menuitem`, not `button` |
| `Semantics(liveRegion: true, child: Text(...))` | Yes | Yes if inside a labeled wrapper | Activity log entries appear here |
| Bare `Text` inside a `Card` (e.g. result-card field values) | **No** | Often collapsed into parent `generic` | "Transfer Successful", "All Changes Applied", "Contract Address: C..." all disappear here — use a sibling button as the marker instead |

### Reliable success markers (catalogue)

These are the buttons / strings that have proven robust across runs:

- **Wallet creation success**: body-text `Contract Address:` (heading label
  outside Card), and then the unique button `Go to Main Screen`
- **Main screen connected state**: button `Copy contract address` (the only
  place this label appears)
- **Main screen disconnected state**: body-text `No wallet connected`
- **Auto-connect / Indexer reconnect verification**: activity-log entry
  `Wallet connected: <truncated-address>` (4-char prefix + `...` + 4-char
  suffix; the WalletStatusCard's full address is wrapped in
  `Semantics(label:)` and does not surface)
- **Transfer success**: button `New Transfer` (only on success card) +
  balance debit in body text (`9994 XLM` after a `1.0` transfer)
- **Approve success**: button `New Approve`, then poll body text for
  `<amount-int> DEMO` once the read-only allowance simulation resolves
- **Context-rule create success**: heading `Transaction Successful`
- **Context-rule edit success**: button
  `Done. Close edit context rule screen.` plus `Copy transaction hash`
  count == number of edit diffs (e.g. name + expiry → 2 hashes)
- **Context-rules list count**: body-text `N context rule.s. loaded` (the
  `(s)` parens must be escaped in extended-regex; `.s.` works)
- **Last-rule guard active**: snapshot contains `button "Last Rule"
  [disabled` AND lacks `button "Remove Rule"`

## Authoring a new scenario

1. Copy the nearest existing scenario whose phase pattern matches:

   ```
   cp tool/scenarios/main_load.sh tool/scenarios/my_thing.sh
   chmod +x tool/scenarios/my_thing.sh
   ```

2. Update the header comment block to describe the new flow and the
   `scenario_init "..."` argument.

3. Pick a single thing to assert per phase. The canonical phases are:
   - **A** — Setup (`close_session`, `open_app`, screenshot,
     `attach_virtual_authenticator`)
   - **B** — Create wallet (inline from `wallet_create.sh` if needed so the
     scenario is independently runnable)
   - **C..** — Scenario-specific UI driving
   - **Final** — `scenario_pass`

4. For each UI element interaction:
   - Capture a fresh snapshot.
   - Grep the snapshot for the target element using the patterns above.
   - Guard the captured ref with `if [[ -z ... ]]; then scenario_fail ...; fi`.
   - Call `agent-browser --session "${SESSION_NAME}" {click|fill|check|uncheck} "@${REF}"`.
   - Brief `sleep 1` or `sleep 2` for the UI to react.

5. Use `wait_for_body_pattern` for state transitions that may take time
   (deploy, mint, RPC submission). The pattern is matched via `grep -qE`,
   so escape extended-regex specials:
   - `(s)` → `.s.` (literal parens in extended regex need escaping; the dot
     form is simpler and safe)
   - `.` → `\.` if you specifically need a literal dot

6. End with `scenario_pass`.

## Bash gotchas with `set -euo pipefail`

The harness uses strict mode. The two common ways to get a silent exit (no
`FAIL` line) are:

- **Empty `$(grep ...)` substitution** — when grep finds nothing, the
  substitution itself fails and `set -e` triggers before your `if -z`
  check runs. Fix: append `|| true` to the substitution:

  ```bash
  REF="$(printf '%s\n' "${SNAP}" | grep -oE '...' | head -n1 \
    | grep -oE 'e[0-9]+' || true)"
  if [[ -z "${REF}" ]]; then scenario_fail "..."; fi
  ```

  Or wrap with `set +o pipefail` / `set -o pipefail` around the
  substitution. (The existing scenarios use the `|| true` form.)

- **`[[ ... ]] && cmd`** — when `[[ ... ]]` evaluates false the whole
  expression is non-zero, and `set -e` kills the script. Always write
  `if [[ ... ]]; then ...; fi` instead.

## Bug-fix workflow

A scenario that fails after the UI was driven correctly usually means a
real demo bug. Workflow that has been validated across 11 fixes in this
harness:

1. **Surface the underlying error.** Demo flows route exceptions through
   `lib/util/error_utils.dart::classifyError`, which collapses unknown
   Exception types to "An unexpected error occurred. Please try again."
   The actionable SDK message gets hidden. Temporarily widen the catch
   site's log to include the raw error:

   ```dart
   } catch (e) {
     final classified = classifyError(e, context: 'Failed to do X');
     // TEMPORARY DIAGNOSTIC — revert after root cause is identified.
     _activityLog.error('${classified.message} (raw: $e)');
     ...
   }
   ```

   Rebuild, re-run the scenario, capture the real SDK error from the
   activity log or banner. Then revert the diagnostic.

2. **Identify the root cause.** If it is an SDK-typed error, the message
   field carries the contract error code (e.g.
   `SmartAccountException [5001]: ...HostError: Error(Contract, #3015)`).
   Look up the code in the OpenZeppelin smart-account contract's
   `SmartAccountError` enum. Common codes encountered so far:
   - `3015` — `NameTooLong` (context rule name > 20 bytes)
   - `3016` — `UnauthorizedSigner`
   - `3011` — `TooManyPolicies`

3. **Fix the demo** (and/or the SDK if the bug originates there).

4. **Cross-platform parity check.** Whenever a Flutter bug is fixed,
   inspect the iOS/macOS demo for the same pattern. File-path mapping:

   | Flutter | iOS / macOS |
   |---|---|
   | `lib/flows/X.dart` | `Sources/Flows/X.swift` |
   | `lib/screens/X.dart` | `Sources-iOS/Screens/X.swift` + `Sources-macOS/Screens/X.swift` (or `Sources/Components/X.swift` if shared) |
   | `lib/util/X.dart` | `Sources/Util/X.swift` |
   | `lib/state/X.dart` | `Sources/State/X.swift` |
   | `lib/token/X.dart` | `Sources/Token/X.swift` |

   If iOS has the same shape: port the fix and run
   `xcodebuild -project SmartAccountDemo.xcodeproj -scheme SmartAccountDemoMac
   -destination 'platform=macOS' test CODE_SIGN_IDENTITY="-"
   CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO` plus
   `swiftlint --strict`. If iOS is structurally immune (Swift `Result`
   matching, `Task.cancel`, etc.), document why in the bug entry.

## Common UI references in the demo

Anchors that surface in `snapshot` and are useful for grep templates:

```
button "Create Wallet" [ref=eN]                 # main screen + on-screen CTA
button "Connect Wallet" [ref=eN]                # main screen disconnected
button "Disconnect" [ref=eN]                    # main screen connected (one of two)
button "Copy contract address" [ref=eN]         # main screen connected (unique)
button "Go to Main Screen" [ref=eN]             # post-success cards
button "Context Rules. View and manage signing rules" [ref=eN]
button "Transfer. Send XLM or DEMO tokens" [ref=eN]
button "Approve. Grant a token spending allowance" [ref=eN]
button "Account Signers. View all signers on this account" [ref=eN]
button "+ Add Rule" [ref=eN]                    # context rules list
button "Edit Rule" [ref=eN]                     # context rule card (expanded or default-only)
button "Remove Rule" [ref=eN]                   # context rule card expanded (enabled)
button "Last Rule" [disabled, ref=eN]           # context rule card when only 1 rule remains
button "Expand" [ref=eN]                        # context rule card collapsed
button "Add Delegated Signer" [ref=eN]          # context rule builder
button "Create Context Rule" [ref=eN]           # builder submit (create-mode)
button "Apply Changes" [ref=eN]                 # builder submit (edit-mode)
button "Done. Close edit context rule screen." [ref=eN]  # edit success card
textbox "Passkey Name" [ref=eN]                 # wallet creation
textbox "Rule Name" [ref=eN]                    # context rule builder
textbox "Stellar Address (G-address)" [ref=eN]  # delegated signer input
textbox "Amount" [ref=eN]                       # transfer + approve
textbox "Recipient Address" [ref=eN]            # transfer
textbox "Spender Address" [ref=eN]              # approve
textbox "Contract Address" [ref=eN]             # connect-with-address path
checkbox "Set Expiry" [checked=false, ref=eN]   # builder
menuitem "10 days expiry preset." [ref=eN]      # expiry dropdown open
```

## Known Flutter Web semantics quirks (catalogue)

Workarounds applied across the existing scenarios — consult before
authoring a similar verification step.

1. **Card-internal Text widgets do not surface to body text.** The
   "Transfer Successful", "All Changes Applied", "Wallet Created
   Successfully", and "Contract Address: C..." labels are all bare
   `Text` widgets inside Cards. Use a sibling button as the success
   marker (e.g. `New Transfer`, `Done`, `Copy transaction hash`).

2. **Activity log entries DO surface as buttons** — each one is a
   tappable row labeled with the full message including timestamp.
   Useful for verifying past events (e.g.
   `Wallet connected: CATA...3TUW`).

3. **Truncated address format**: the kit emits events with a 4-char
   prefix + `...` + 4-char suffix (e.g. `CATA...3TUW` from
   `CATA7DZ4TZ5G...6CCGVFOU3TUW`). Use `${ADDR:0:4}...${ADDR: -4}` to
   build the expected pattern in bash.

4. **Activity log timestamps use the local clock**, not UTC. Don't try to
   match them across the wall clock — just grep for the message
   substring.

5. **Dropdown items only appear as `menuitem` after the dropdown is
   clicked open.** The `DropdownButtonFormField` surfaces as `button`
   when closed, and the options become `menuitem` only while the overlay
   is open. The semantic label for each item is
   `"<text> <description>"` joined.

6. **TextField pre-filled values render as
   `textbox "<label>" [ref=eN]: <value>`.** Same field also appears as
   the inner Material text field with the hint as label. Either ref
   works for `fill`.

7. **Disabled buttons render with `[disabled` in the bracket suffix.**
   Use this for guard-state assertions
   (e.g. `button "Last Rule" [disabled`).

8. **The accessibility-tree snapshot is fresh per `snapshot` call** but
   refs are not stable across calls. Always capture a snapshot
   immediately before grep-extracting refs you intend to act on.
