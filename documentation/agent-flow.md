# Agent-signer flow: end-to-end runbook

This is the authoritative guide for running the full agent-signer flow: an
autonomous agent acts under a scoped, user-delegated authority; its over-limit
call is rejected on-chain; it escalates to a coordination server; the user
reviews and approves in the demo; the call is re-submitted under the user's
Default rule; and the agent learns the outcome.

Five pieces cooperate. Read the component docs for the detail behind each:

- Coordination server — [`coordination_server/README.md`](../coordination_server/README.md)
- Reference agent — [`reference_agent/README.md`](../reference_agent/README.md)
- Demo delegation (step 2) — [`smart-accounts/agent-delegation-demo.md`](smart-accounts/agent-delegation-demo.md)
- Demo coordination config — `lib/config/demo_config.dart`
- Convenience launcher — [`tool/start_coordination_server.sh`](../tool/start_coordination_server.sh)

Commands assume `flutter` and `dart` are on `PATH` (the toolchain lives at
`/Users/chris/flutter/bin`). Everything below targets Stellar **testnet**; the
defaults in `lib/config/demo_config.dart` and `AgentDefaults` are testnet-only
and public by design.

## What is automatable, and what is device-only

Most of this flow needs a real passkey (WebAuthn) and on-chain submission, so it
runs on a device or simulator by hand. The HTTP coordination seam alone is
covered by an opt-in integration test —
`test/integration/coordination_e2e_test.dart` — which starts the real server and
drives it with the demo's real client; run it with
`RUN_COORDINATION_E2E=true flutter test test/integration/coordination_e2e_test.dart`.
The steps that stay manual are called out as **device-only** below: creating the
smart account (passkey), delegating to the agent (passkey), and approving the
escalation (passkey).

## Prerequisites

- Flutter `>=3.35.0`, Dart `>=3.8.0` (this toolchain ships Dart 3.9).
- A run target with passkey support: an iOS simulator, an Android emulator
  (API 28+), or Chrome with `--dart-define=RP_ID=localhost`. See the demo
  `README.md` for platform entitlements.
- Dependencies resolved once per package: `flutter pub get` in the repo root and
  `dart pub get` in `coordination_server/` (the launcher script does the latter
  on first run).

## Shared configuration

Every value below must agree across the three processes or the flow breaks. The
network/contract values already share a default in both
`lib/config/demo_config.dart` and `AgentDefaults`; the per-run identity values
are produced during the flow and copied between processes.

| Value | Coordination server | Reference agent | Demo app | Must agree because |
|-------|---------------------|-----------------|----------|--------------------|
| Coordination URL | bind `0.0.0.0:$PORT` (`--port`, default 8787) | `AGENT_COORDINATION_URL` | `--dart-define=COORDINATION_URL` | agent posts and demo polls the same server |
| Coordination token | `COORDINATION_TOKEN` / `--token` (required) | `AGENT_COORDINATION_TOKEN` | `--dart-define=COORDINATION_TOKEN` | every `/requests*` call is bearer-authenticated |
| Agent seed | — | `AGENT_SECRET_SEED` (`S...`, secret) | — | the agent signs with this key |
| Agent public key | — | derived from the seed | pasted into Delegate-to-agent | the demo registers it as the Ed25519 external signer |
| Smart account | — | `AGENT_SMART_ACCOUNT` (`C...`) | the connected account's "Contract address" | the agent connects to the account it was delegated on |
| Credential ID | — | `AGENT_CREDENTIAL_ID` (base64url) | the connected passkey's "Credential ID" | the agent connects headlessly via this credential |
| Destination | — | `AGENT_DESTINATION` (`G...`/`C...`) | — | the transfer recipient |
| Scoped token | — | `AGENT_TOKEN_CONTRACT` (default XLM SAC) | the token chosen in Delegate-to-agent | the call must hit the one token the rule scopes |
| Spending cap vs. amount | — | `AGENT_AMOUNT` (default `1`) | the cap entered in Delegate-to-agent | **`AGENT_AMOUNT` must EXCEED the cap** so the call is policy-rejected |
| RPC URL | — | `AGENT_RPC_URL` | `rpcUrl` | same testnet RPC (default matches) |
| Network passphrase | — | `AGENT_NETWORK_PASSPHRASE` | `networkPassphrase` | same network (default matches) |
| Relayer URL | — | `AGENT_RELAYER_URL` | `defaultRelayerUrl` | gasless submission via the same relayer (default matches) |

The agent's static network/verifier/token defaults already mirror the demo, so a
normal run only sets the per-run identity values plus an over-cap `AGENT_AMOUNT`.

## Step 0 — Start the coordination server (preflight)

Pick a token (for local development the demo and agent default to
`dev-token-change-me`). The launcher binds `0.0.0.0` and prints the URL:

```sh
tool/start_coordination_server.sh --token dev-token-change-me --port 8787
# optional persistent store:
tool/start_coordination_server.sh --token dev-token-change-me --port 8787 \
  --store ./coordination_server/requests.store.json
```

Equivalently, by hand:

```sh
cd coordination_server
COORDINATION_TOKEN=dev-token-change-me dart run bin/server.dart --port 8787
```

Confirm it is up: `curl http://localhost:8787/health` returns `200`.

## Step 1 — Get the agent's public key (bootstrap)

Before a full live config exists, obtain the agent's identity. With no seed set,
this generates a fresh one and prints BOTH the seed (to copy into the agent
config) and the `G...` public key (to paste into the demo):

```sh
cd reference_agent
AGENT_PRINT_KEY=true flutter test test/agent_print_key_test.dart
```

Output (look for the `[agent] [KEY]` lines):

```
[agent] [KEY] Generated a new agent Ed25519 keypair.
[agent] [KEY] AGENT_SECRET_SEED (copy into the agent config, keep secret): S...
[agent] [KEY] Agent public key (paste into Delegate-to-agent): G...
```

To re-derive the public key for a seed you already hold (the secret is never
printed back):

```sh
AGENT_PRINT_KEY=true AGENT_SECRET_SEED=S... \
  flutter test test/agent_print_key_test.dart
```

Keep the seed secret; share only the `G...` address with the wallet.

## Step 2 — Create/connect the account, then delegate to the agent (device-only)

Run the demo (see "Running the demo" below). In the app:

1. **Create or connect a smart account** with a passkey.
2. From the **Context Rules** screen, open **Delegate to agent** and:
   - paste the agent's `G...` public key from step 1;
   - scope the rule to the demo token (the field defaults to the DEMO token);
   - set a **small** spending cap (this is what the agent must exceed);
   - set an expiry (for example ~24h);
   - submit with the passkey.

This installs one context rule that scopes the agent to one token, caps its
spend, and expires on its own. The mechanics are in
[`smart-accounts/agent-delegation-demo.md`](smart-accounts/agent-delegation-demo.md).

Copy two values the agent needs from the demo's wallet status card: the account
**Contract address** (`C...`) and the connected **Credential ID** (base64url).

## Step 3 — Configure and run the agent so its call is rejected

Set `AGENT_AMOUNT` ABOVE the cap from step 2 so the spending-limit policy
rejects the call. The agent escalates the rejection and polls:

```sh
cd reference_agent
AGENT_RUN_LIVE=true \
AGENT_SMART_ACCOUNT=C...           # account "Contract address" from step 2 \
AGENT_CREDENTIAL_ID=<base64url>    # "Credential ID" from step 2 \
AGENT_SECRET_SEED=S...             # the agent seed from step 1 \
AGENT_DESTINATION=G...             # transfer recipient \
AGENT_AMOUNT=1000                  # MUST exceed the delegated cap \
AGENT_COORDINATION_URL=http://localhost:8787 \
AGENT_COORDINATION_TOKEN=dev-token-change-me \
flutter test test/agent_live_run_test.dart
```

If the scoped token is not the default XLM SAC, also set `AGENT_TOKEN_CONTRACT`
to the same token chosen in step 2. The agent logs the rejection code, posts the
escalation, prints the request id, and begins polling.

## Step 4 — Review and approve in the demo (device-only)

In the demo, tap the **bell** in the app bar to open the approval inbox:

1. The pending escalation appears with the decoded call (target, function,
   from/to addresses, amount) and the rejection reason.
2. **Approve** it. The demo re-submits the same call under the user's **Default
   rule** with the passkey, gasless via the relayer, and reports the resulting
   transaction hash back to the coordination server.

## Step 5 — The agent learns the outcome

The agent's poll sees the request resolve to `approved` with the `resultHash`
and returns `AgentEscalationApproved`. The agent does NOT re-submit — the demo
did, under the Default rule. (A rejection in the inbox returns
`AgentEscalationRejected`; no resolution within the poll budget returns
`AgentEscalationPending`.)

## Running the demo

Pick a target and pass the coordination config as `--dart-define`s so they match
the server from step 0:

```sh
# iOS simulator
flutter run -d "iPhone 16" \
  --dart-define=COORDINATION_URL=http://localhost:8787 \
  --dart-define=COORDINATION_TOKEN=dev-token-change-me

# Android emulator (API 28+)
flutter run -d emulator-5554 \
  --dart-define=COORDINATION_URL=http://localhost:8787 \
  --dart-define=COORDINATION_TOKEN=dev-token-change-me

# Web (passkeys need RP_ID=localhost)
flutter run -d chrome --dart-define=RP_ID=localhost \
  --dart-define=COORDINATION_URL=http://localhost:8787 \
  --dart-define=COORDINATION_TOKEN=dev-token-change-me
```

Without the `--dart-define`s the demo falls back to
`http://localhost:8787` and the development token `dev-token-change-me`
(`coordinationServerUrl` / `coordinationToken` in `lib/config/demo_config.dart`).

**Physical device:** `localhost` points at the device, not your machine. Start
the server (it binds `0.0.0.0`), find your machine's LAN IP, and point the demo
at it:

```sh
flutter run -d <device-id> \
  --dart-define=COORDINATION_URL=http://<lan-ip>:8787 \
  --dart-define=COORDINATION_TOKEN=dev-token-change-me
```

The agent (typically on the same machine as the server) keeps
`AGENT_COORDINATION_URL=http://localhost:8787`.

## Troubleshooting

- **Server unreachable / connection refused.** Confirm step 0 is running and
  `curl http://localhost:8787/health` returns `200`. On a physical device,
  `localhost` is the device itself — use the machine's LAN IP (see above) and
  check the host firewall allows the port.
- **`401 Unauthorized` on `/requests*`.** The token differs across processes.
  The server's `--token`/`COORDINATION_TOKEN`, the agent's
  `AGENT_COORDINATION_TOKEN`, and the demo's
  `--dart-define=COORDINATION_TOKEN` must be identical.
- **Account mismatch / agent cannot connect or sign.** `AGENT_SMART_ACCOUNT`
  and `AGENT_CREDENTIAL_ID` must be the exact "Contract address" and
  "Credential ID" of the account you delegated on in step 2, and the agent's
  `G...` (from `AGENT_SECRET_SEED`) must be the key you pasted into
  Delegate-to-agent. Re-derive it with `AGENT_PRINT_KEY=true` (step 1).
- **No rejection — the call succeeds instead of escalating.** `AGENT_AMOUNT` is
  at or below the delegated cap, so the spending-limit policy permits it. Raise
  `AGENT_AMOUNT` above the cap, or lower the cap in a new delegation. Also
  confirm `AGENT_TOKEN_CONTRACT` matches the token the rule scopes; a call to a
  different token is not governed by that rule.
- **Demo refuses to construct the coordination client (release/profile).** The
  release guard (`coordinationConfigShipBlocker` in `demo_config.dart`) blocks
  the development token and non-HTTPS URLs outside debug builds. For local
  development run a debug build (`flutter run` is debug by default). For a shared
  environment, set a strong `--dart-define=COORDINATION_TOKEN` and an `https://`
  `--dart-define=COORDINATION_URL`.
- **Agent stops with `AgentEscalationPending`.** No one approved within
  `AGENT_POLL_INTERVAL_SECONDS` × `AGENT_POLL_MAX_ATTEMPTS` (default 3s × 40 =
  2 min). Approve sooner, or raise the poll budget.
