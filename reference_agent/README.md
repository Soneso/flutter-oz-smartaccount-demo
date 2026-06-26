# reference_agent

Autonomous reference agent for the OpenZeppelin smart-account demo. It is the
standalone implementation of step 3 of the five-step agent flow: an autonomous
process that acts within scoped, user-delegated authority.

Given an existing smart account and its own delegated Ed25519 key, the agent:

1. Connects to the smart account headlessly (in-memory storage, no WebAuthn
   provider) using the account's public credential ID and contract ID.
2. Registers its Ed25519 keypair as an external signer through the
   verifier-contract path, via the same adapter callback the demo app uses.
3. Attempts a scoped contract call (token `transfer`) through the multi-signer
   pipeline with an Ed25519 selected signer, routed through the relayer
   (gasless).
4. Classifies the outcome. On success it logs the transaction hash. On a policy
   rejection it parses the on-chain contract error code and matches it against
   `OZContractErrorCodes`.
5. Escalates a rejection to the coordination server, then polls until the user
   resolves it. The agent does **not** re-submit on approval — the mobile app
   re-submits the call under the Default rule; the agent only learns the
   outcome by polling.

## Run mechanism

The agent is a Flutter package. The `stellar_flutter_sdk` barrel transitively
imports `package:flutter` (`dart:ui`), so a plain `dart run` cannot resolve the
program. The agent therefore runs headlessly under `flutter test`.

The primary run entry is `test/agent_live_run_test.dart`. With a complete live
configuration it builds the production agent and runs one full cycle; without
one it is skipped, so the default `flutter test` never touches the network.

```sh
# Unit tests (no network, all mocked):
flutter test

# Live end-to-end run (testnet + a running coordination server):
AGENT_RUN_LIVE=true \
AGENT_SMART_ACCOUNT=C... \
AGENT_CREDENTIAL_ID=<base64url credential id> \
AGENT_SECRET_SEED=S... \
AGENT_DESTINATION=G... \
AGENT_COORDINATION_URL=http://localhost:8787 \
AGENT_COORDINATION_TOKEN=dev-token-change-me \
flutter test test/agent_live_run_test.dart
```

A `flutter run -d macos` desktop target is intentionally not provided: the SDK
pulls plugin packages (path_provider and friends) whose macOS runner requires
CocoaPods and signing scaffolding. That is a follow-up if a non-test launcher
is needed; the `flutter test` entry is the reliable run path today.

## Bootstrap: get the agent's public key (print-key mode)

Before a full live config exists, obtain the agent's identity. The print-key
mode derives or generates an Ed25519 keypair and nothing else — it does not
need the rest of the live config. It runs under `flutter test` like the other
entries, gated on `AGENT_PRINT_KEY` so the default `flutter test` run never
generates a key as a side effect.

```sh
# Generate a fresh seed + G-address (no other config needed):
AGENT_PRINT_KEY=true flutter test test/agent_print_key_test.dart
```

Look for the `[agent] [KEY]` lines:

```
[agent] [KEY] Generated a new agent Ed25519 keypair.
[agent] [KEY] AGENT_SECRET_SEED (copy into the agent config, keep secret): S...
[agent] [KEY] Agent public key (paste into Delegate-to-agent): G...
```

Copy the `S...` seed into `AGENT_SECRET_SEED` (keep it secret) and paste the
`G...` public key into the demo's Delegate-to-agent screen. To re-derive the
public key for a seed you already hold — the secret is never printed back:

```sh
AGENT_PRINT_KEY=true AGENT_SECRET_SEED=S... \
  flutter test test/agent_print_key_test.dart
```

The keygen itself lives in `lib/src/agent_keygen.dart` (`resolveAgentKey`,
`formatAgentKeyOutput`, `shouldPrintAgentKey`); `shouldPrintAgentKey` also
honors a `--print-key` argument for any non-test launcher. It is unit-tested in
`test/agent_keygen_test.dart`.

## Configuration

`AgentConfig.resolve()` layers configuration sources, highest precedence first:
command-line arguments (`--kebab-key=value`) over environment variables
(`AGENT_UPPER_SNAKE`) over an optional JSON file (`--config` /
`AGENT_CONFIG_FILE`, keys are the camelCase field names) over the built-in
defaults.

### Static defaults (testnet, from the demo's `lib/config/demo_config.dart`)

| Field | Env var | Default |
|-------|---------|---------|
| `rpcUrl` | `AGENT_RPC_URL` | `https://soroban-testnet.stellar.org` |
| `networkPassphrase` | `AGENT_NETWORK_PASSPHRASE` | `Test SDF Network ; September 2015` |
| `accountWasmHash` | `AGENT_ACCOUNT_WASM_HASH` | `86b49fe0…3bd06d28` |
| `webauthnVerifierAddress` | `AGENT_WEBAUTHN_VERIFIER` | `CB26VN37…G7NKY` |
| `ed25519VerifierAddress` | `AGENT_ED25519_VERIFIER` | `CAW2Z46I…F7AJ6` |
| `relayerUrl` | `AGENT_RELAYER_URL` | `https://smart-account-relayer-proxy.soneso.workers.dev` (empty disables) |
| `tokenContractId` | `AGENT_TOKEN_CONTRACT` | `CDLZFC3S…GCYSC` (XLM SAC) |
| `tokenDecimals` | `AGENT_TOKEN_DECIMALS` | `7` |
| `amount` | `AGENT_AMOUNT` | `1` |
| `coordinationBaseUrl` | `AGENT_COORDINATION_URL` | `http://localhost:8787` |
| `coordinationToken` | `AGENT_COORDINATION_TOKEN` | `dev-token-change-me` |
| `pollIntervalSeconds` | `AGENT_POLL_INTERVAL_SECONDS` | `3` |
| `pollMaxAttempts` | `AGENT_POLL_MAX_ATTEMPTS` | `40` |

The known testnet policy contract addresses (threshold, spending-limit,
weighted-threshold) are available as `AgentDefaults.knownPolicies` for operators
wiring up delegation; the agent does not install policies itself.

### Per-run values (no default — supplied for each run)

These identify the specific account and the agent's own delegated identity.
They are produced by the mobile demo's step-2 delegation flow, which registers
the agent's Ed25519 key as a scoped signer on the smart account.

| Field | Env var | Description |
|-------|---------|-------------|
| `smartAccountContractId` | `AGENT_SMART_ACCOUNT` | Deployed smart-account C-address |
| `credentialId` | `AGENT_CREDENTIAL_ID` | Base64URL credential ID of the account's connected passkey |
| `agentSecretSeed` | `AGENT_SECRET_SEED` | Agent Ed25519 secret seed (Stellar `S...`) |
| `destinationAddress` | `AGENT_DESTINATION` | Transfer recipient (`G...` or `C...`) |

`AgentConfig.validateForLiveRun()` checks that these are present and
well-formed; `Agent.fromConfig` calls it before wiring the kit.

## Rejection, escalation, and polling

When the scoped call is rejected with an on-chain contract error code, the agent
posts the rejected call to the coordination server and polls for resolution.

- `POST /requests` body: `{ smartAccount, target, targetFn, args, amount, reason }`.
  `args` is the list of base64-encoded `XdrSCVal` strings — the exact call
  arguments, so the mobile inbox can rebuild the call verbatim. `reason` is the
  integer contract error code.
- The server returns the created object with a server-assigned `id` and
  `status: "pending"`.
- The agent then polls `GET /requests/{id}` every `pollInterval` until `status`
  becomes `approved` (with a `resultHash`) or `rejected`, or until
  `pollMaxAttempts` is exhausted.

All `/requests*` calls send `Authorization: Bearer <coordinationToken>`. See
`coordination_server/README.md` for the full wire contract.

The run returns a terminal `AgentResult`:

- `AgentCallSucceeded(hash)` — confirmed on-chain; no escalation.
- `AgentCallFailed(message)` — non-policy failure (e.g. network); not escalated.
- `AgentEscalationApproved(requestId, resultHash, errorCode)` — user approved;
  the mobile app re-submitted under the Default rule.
- `AgentEscalationRejected(requestId, note, errorCode)` — user declined.
- `AgentEscalationPending(requestId, errorCode, attempts)` — no resolution
  within the poll budget.

## Architecture

The SDK submission and the coordination HTTP client sit behind small interfaces
(`WalletSession`, `MultiSignerContractCallType`, `CoordinationClient`), mirroring
the demo's adapter pattern, so the orchestration in `AgentRunner` is unit-tested
across the success, rejection, escalate-and-approved, and escalate-and-rejected
paths without a network or a live account. `Agent.fromConfig` wires the
production implementations: an `OZSmartAccountKit`, an `HttpCoordinationClient`,
and the agent's `AgentEd25519SignerAdapter`.

```
lib/
  reference_agent.dart                 barrel export
  src/
    agent.dart                         production assembly + SDK-backed adapters
    agent_config.dart                  config + defaults + resolution
    agent_ed25519_signer_adapter.dart  OZExternalEd25519SignerAdapter
    agent_keygen.dart                  print-key bootstrap (derive/generate key)
    agent_runner.dart                  orchestration + interfaces + results
    coordination_client.dart           coordination REST client + model
    outcome.dart                       contract-call outcome classification
test/
  agent_live_run_test.dart             primary run entry (skipped without config)
  agent_print_key_test.dart            print-key run entry (gated on AGENT_PRINT_KEY)
  agent_keygen_test.dart               keygen derive/generate/format unit tests
  agent_runner_test.dart               success / rejection / escalation paths
  coordination_client_test.dart        REST wire-format tests (MockClient)
  agent_config_test.dart               config resolution + validation
  kit_construction_test.dart           headless kit build under flutter test
  outcome_test.dart                    error-code parsing + classification
```

## Status

The agent code and its unit tests stand alone. A full live end-to-end run
additionally requires a smart account that already has the agent's Ed25519 key
registered as a scoped signer — produced by the step-2 delegation flow, which is
built next.
