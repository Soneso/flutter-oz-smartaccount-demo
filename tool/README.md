# tool — Developer scripts for the Smart Account Demo

## Contents

| File | Purpose |
|---|---|
| `run_web_dev.sh` | Start / stop the Flutter web dev server |
| `agent_browser_webauthn.sh` | Attach a virtual WebAuthn authenticator to an agent-browser session |
| `scenarios/` | End-to-end browser test scenarios (one script per user flow); see [scenarios/README.md](scenarios/README.md) |

External wallet connection uses `reown_core` + `reown_sign` (WalletConnect) on
mobile and the Freighter browser extension on web.

## End-to-end browser scenarios

The `tool/scenarios/` directory holds executable end-to-end scenario scripts
that drive a real Chrome browser through full user flows (wallet creation,
transfers, allowance approvals, context-rule edits, and more) on Stellar
testnet and assert the expected UI state. Each script auto-builds the web
bundle, starts the static server, attaches a virtual WebAuthn authenticator,
runs the flow, and prints `PASS` / `FAIL`. See
[scenarios/README.md](scenarios/README.md) for the list, prerequisites, and
usage.

---

## Starting the web dev server

```bash
cd /path/to/flutter-oz-smartaccount-demo
./tool/run_web_dev.sh
```

This runs `flutter build web --release --pwa-strategy=none --dart-define=RP_ID=<value>`
to produce the static bundle under `build/web/`, then serves that directory with
`python3 -m http.server 5173 --bind localhost` detached in the background. The
server PID is saved to `tool/.web_dev.pid` and build output is logged to
`tool/.web_dev.log`. `--pwa-strategy=none` disables the service worker so the
browser does not cache a stale shell between iterations. `RP_ID` defaults to
`localhost`; override it in the environment before launching (for example
`RP_ID=demo.example.com ./tool/run_web_dev.sh`).

To stop:

```bash
./tool/run_web_dev.sh stop
```

The default origin for development is `http://localhost:5173`.

For incremental dev iteration with hot reload, run `flutter run -d chrome`
interactively from your own terminal instead.

---

## Attaching agent-browser

Prerequisites:
- `agent-browser` CLI installed and on PATH
- `websocat` installed (`brew install websocat`) for CDP communication

```bash
# 1. Start the web dev server (see above)
./tool/run_web_dev.sh

# 2. Open the app in an agent-browser session
agent-browser --session smart-account-demo open http://localhost:5173

# 3. Run a command with the virtual authenticator attached
./tool/agent_browser_webauthn.sh --session smart-account-demo -- \
    agent-browser --session smart-account-demo snapshot
```

---

## Using the WebAuthn virtual authenticator helper

The `agent_browser_webauthn.sh` script:
1. Queries agent-browser for the CDP WebSocket URL of the current page.
2. Sends `WebAuthn.enable` + `WebAuthn.addVirtualAuthenticator` via CDP.
3. Runs the wrapped command (or an interactive bash shell if no command given).
4. Sends `WebAuthn.removeVirtualAuthenticator` on exit.

### Example: take a snapshot with the authenticator active

```bash
./tool/agent_browser_webauthn.sh --session smart-account-demo -- \
    agent-browser --session smart-account-demo snapshot -i
```

### Example: run an interactive session

```bash
./tool/agent_browser_webauthn.sh --session smart-account-demo
# (virtual authenticator is active inside the bash shell)
# Type "exit" to remove the authenticator and return
```

---

## What the agent-browser harness covers

The following scenarios can be tested with the virtual authenticator:

- WebAuthn credential creation (passkey registration ceremony)
- WebAuthn credential assertion (passkey authentication ceremony)
- Screen navigation (main screen to sentinel destinations)
- In-app state transitions (connected / disconnected UI)
- Error UI rendering (network errors, invalid input)
- IndexedDB credential persistence within a single browser session

---

## What the harness does NOT cover

The following scenarios require manual testing on a real device or a separate
test environment:

| Scenario | Reason |
|---|---|
| Real Reown WalletConnect pairing | Requires a real wallet app on the same network |
| IndexedDB persistence across separate browser sessions | Virtual authenticator credential store is ephemeral per CDP session |
| Multi-signer flows requiring two separate identities | A single virtual authenticator holds one identity |
| Deep-link / URL-scheme return flows from a wallet app | Requires a real wallet app |
| Real network failures (testnet, indexer, relayer outages) | Requires controlled network partition or test doubles |

These gaps are accepted and documented. Manual testing on device covers them.
