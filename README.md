# OpenZeppelin Smart Account Demo - Flutter Stellar SDK

A Flutter application for testing the OpenZeppelin smart-account support in the Flutter Stellar SDK with WebAuthn passkey authentication on Stellar testnet. The app covers wallet creation, token transfers, multi-signer authorization, and on-chain context rule management.

The primary purpose of this app is to test and validate the SDK's smart-account support. It is not intended as a production application template.

Supported platforms: iOS 16.0+, Android (API 28+), and Web (any modern WebAuthn-capable browser).

## Features

The demo includes 8 screens:

### 1. Main Dashboard

Wallet status display with XLM and DEMO token balances, navigation to all other screens, activity log showing SDK operations in real time, balance refresh, and wallet disconnect.

### 2. Wallet Creation

Collects a username, registers a passkey via the platform's WebAuthn provider, deploys a smart account contract to testnet, funds the wallet with XLM via Friendbot, and mints 10,000 DEMO tokens. Displays the credential ID, contract address, transaction hash, and initial balances on completion.

### 3. Wallet Connection

Four connection strategies:
- **Auto Connect** -- restores a saved session if one exists, otherwise authenticates with a passkey and tries to resolve the contract address automatically.
- **Connect via Indexer** -- authenticates with a passkey first, then looks up the associated contract address through the indexer service.
- **Connect with Address** -- recovery flow where the user provides a known contract address and authenticates with any registered passkey.
- **Retry Pending Deployment** -- retries contract deployment for credentials where the passkey was registered but the on-chain deployment did not complete.

### 4. Transfer

Send XLM or DEMO tokens from the connected smart account to any Stellar address. When the account has multiple signers (from context rules), a signer picker allows selecting which signers co-authorize the transaction. Supports both single-passkey and multi-signer transfer paths. Signing with a passkey signer triggers a WebAuthn authentication ceremony to sign the Soroban authorization entry.

### 5. Context Rules

Lists all on-chain authorization rules for the connected account. Each rule card shows its ID, name, context type (Default, CallContract, CreateContract), signers, policies, and expiry. Supports expanding rules for detail view, removing rules (with a safety check preventing removal of the last rule), and navigating to the rule builder for creating or editing rules.

### 6. Context Rule Builder

Form for creating or editing a context rule. Configure the context type, rule name, optional expiry (as a ledger offset converted to an absolute ledger number), signers (passkey, delegated G-address, raw Ed25519), and policy contracts (threshold, spending limit, weighted threshold) with their parameters. In edit mode, you can rename the rule, change its expiry, add or remove signers, and add, remove, or modify policies; each change is applied as a separate on-chain transaction.

### 7. Account Signers

Displays all unique signers registered across all context rules. Each signer entry shows its type (passkey, delegated G-address, raw Ed25519), identifier, and the list of context rules it belongs to. Signers are deduplicated across rules using stable signer keys.

### 8. Approve

Grants a SEP-41 token spending allowance that delegates spending authority over the smart account's tokens to another address. This screen demonstrates an arbitrary contract call: unlike Transfer (which uses the dedicated transfer helper), Approve invokes the token's `approve` function through the generic contract-call path, with both single-signer and multi-signer support.

## Architecture

```
flutter-oz-smartaccount-demo/
├── lib/
│   ├── main.dart                # Entry point: providers, platform deps, runApp
│   ├── config/                  # Network, contracts, RP config, knownPolicies
│   ├── flows/                   # Primary SDK consumer (most SDK calls live here)
│   ├── screens/                 # User-facing ConsumerStatefulWidget screens
│   ├── widgets/                 # Reusable Material widgets (cards, sheets, forms)
│   ├── state/                   # Riverpod notifiers and providers (DemoState, ActivityLogState)
│   ├── theme/                   # Material 3 light and dark themes, spacing constants
│   ├── token/                   # DemoTokenService (deterministic deploy + balance)
│   ├── util/                    # Helpers (formatting, clipboard, URL, policy decoders)
│   ├── wallet/                  # External wallet abstraction (Reown mobile, Freighter web)
│   └── navigation/              # go_router config and route paths
├── ios/                         # iOS Runner project (entitlements, Podfile)
├── android/                     # Android Gradle project (manifest, build.gradle.kts)
├── web/                         # Web entry (index.html, manifest.json, icons)
├── test/                        # Widget, flow, util tests
├── tool/                        # Helper scripts (web dev server, agent-browser harnesses)
└── pubspec.yaml
```

Screens compose widgets and call flows. Flows call the SDK and emit events into `DemoState` and `ActivityLogState`. Screens and widgets get SDK types through the flow-types layer's typedef re-exports (for example `lib/flows/context_rule_builder_types.dart`).

Riverpod injects the platform-specific `WebAuthnProvider`, `StorageAdapter`, and `WalletConnector` implementations at startup; web and mobile each supply their own.

## Prerequisites

- Flutter `>=3.35.0`
- Dart SDK `>=3.8.0 <4.0.0`
- iOS: Xcode 15.0+, iOS 16.0+ deployment target
- Android: Android SDK with API 28+ (`minSdk = 28`, required for the SDK's `AndroidStorageAdapter` built on `EncryptedSharedPreferences` (API 23+) and for the WebAuthn FIDO2 Credential Manager API (API 28+)). `compileSdk` and `targetSdk` follow the Flutter Gradle plugin defaults.
- Web: a modern WebAuthn-capable browser (Chrome 67+, Firefox 60+, Safari 14+)
- Passkey (WebAuthn) features require the Associated Domains / Digital Asset Links configuration in [PASSKEY_SETUP.md](PASSKEY_SETUP.md). The demo is preconfigured for the `soneso.com` relying party.

## Building and Running

### iOS simulator

```bash
flutter run -d "iPhone 16"
```

### Android emulator (API 28+)

```bash
flutter run -d emulator-5554
```

### Web (Chrome) for interactive development

```bash
flutter run -d chrome --dart-define=RP_ID=localhost
```

### Web dev server (release bundle)

```bash
# Start (RP_ID=localhost)
./tool/run_web_dev.sh
# Stop the background server
./tool/run_web_dev.sh stop
# Override RP ID
RP_ID=demo.example.com ./tool/run_web_dev.sh
```

The script runs `flutter build web --release --pwa-strategy=none` (avoiding stale service-worker caches during dev) and serves `build/web/` through `python3 -m http.server`.

### Production web builds

The build command is:

```bash
flutter build web --release --pwa-strategy=none --dart-define=RP_ID=<your-rp-id>
```

Whoever hosts the output is responsible for serving Content-Security-Policy and Permissions-Policy response headers. See [PASSKEY_SETUP.md](PASSKEY_SETUP.md) for the recommended header values.

### Physical device signing

The Android release build currently uses the debug signing configuration. Switch to a release keystore and update the `assetlinks.json` SHA-256 fingerprint at the RP domain before any Play Store submission.

The iOS build does not pin an Apple Developer Team. To build or run on a physical iOS device, select your team in Xcode (Runner target → Signing & Capabilities → Team), or pass `DEVELOPMENT_TEAM=<id>` to `flutter build`.

## Passkey / WebAuthn Configuration

Passkeys are bound to a Relying Party (RP) ID. Each platform requires a domain association to link the app to the RP domain.

| Platform | Association Mechanism | Dev Configuration |
|----------|----------------------|-------------------|
| Web | Origin-based (automatic) | Works on `localhost` and `127.0.0.1` |
| Android | Digital Asset Links (`assetlinks.json`) | Requires a hosted domain |
| iOS | Associated Domains entitlement + `apple-app-site-association` | `?mode=developer` suffix (simulator / local device) |

Demo defaults:

- **RP ID**: `soneso.com` (`defaultRpId` in `lib/config/demo_config.dart`; override at build time with `--dart-define=RP_ID=<value>`)
- **RP name**: `Smart Account Kit Demo`
- **iOS entitlement**: `webcredentials:soneso.com?mode=developer` (developer mode for local builds; bypasses AASA validation so passkeys work on the simulator and dev-mode devices regardless of bundle ID — the release gate blocks distribution until it is removed)
- **AASA**: hosted at `https://soneso.com/.well-known/apple-app-site-association`

See [PASSKEY_SETUP.md](PASSKEY_SETUP.md) for full configuration including custom domain setup.

## Configuration

All configuration lives in `lib/config/demo_config.dart`.

| Setting | Description |
|---------|-------------|
| `rpcUrl` | Soroban RPC endpoint |
| `networkPassphrase` | Stellar testnet passphrase |
| `accountWasmHash` | Smart account contract WASM hash (OZ stellar-contracts v0.7.0) |
| `webauthnVerifierAddress` | On-chain WebAuthn (secp256r1) signature verifier contract |
| `ed25519VerifierAddress` | On-chain Ed25519 signature verifier contract |
| `nativeTokenContract` | XLM Stellar Asset Contract (SAC) address on testnet |
| `defaultRelayerUrl` | Relayer proxy for fee-sponsored transaction submission. An empty string disables the relayer and leaves the connected wallet to pay its own fees. |
| `defaultIndexerUrl` | Credential-to-contract address lookup service. An empty string disables the indexer and falls back to an on-chain scan. |
| `defaultRpId` | WebAuthn Relying Party ID (`soneso.com`). Override with `--dart-define=RP_ID=<value>`. |
| `rpName` | Display name for passkey prompts |
| `reownProjectId` | Reown (WalletConnect) project ID for external-wallet connect. Empty by default; register a free project ID at [cloud.reown.com](https://cloud.reown.com) and set it. External-wallet connect is disabled (and its UI hidden) when unset. |
| `maxContextRuleScanId` | Upper bound on rule-ID iteration when scanning the chain (default `25`) |

DEMO token settings (`demoToken*`) control the deterministic deployment and minting of a custom Soroban token used for testing transfers. The token admin seed is intentionally public; the demo is testnet-only and the admin key has no monetary value.

Known policy contracts (threshold, spending limit, weighted threshold) are defined in `knownPolicies`.

## External Wallet Connection

The demo supports connecting an external Stellar wallet (Freighter) as a delegated signer, as an alternative to entering a secret key manually.

| Platform | Method | Requirement |
|----------|--------|-------------|
| Web | Freighter browser extension | Install from [freighter.app](https://www.freighter.app/) |
| iOS | WalletConnect v2 (Reown) | Freighter Mobile on the same device |
| Android | WalletConnect v2 (Reown) | Freighter Mobile on the same device |

- The Web build uses the Freighter extension directly through `@stellar/freighter-api@6`; Reown is not used on Web.
- Wallet connection buttons are hidden on simulators and emulators because WalletConnect requires the wallet app on a real device.
- Wallet connection buttons are also hidden on mobile while `reownProjectId` is unset: external-wallet connect is disabled until you provide your own project ID.

### Reown Project ID

External-wallet connect on mobile requires your own Reown (WalletConnect) project ID; the demo does not ship one. Register a free project ID at [cloud.reown.com](https://cloud.reown.com), add the bundle ID `com.soneso.stellar.smartaccount.demo.flutter` (one ID covers both iOS and Android) to its allowlist, and set `reownProjectId` in `lib/config/demo_config.dart`. While `reownProjectId` is unset, external-wallet connect is disabled and the connect / import-from-wallet UI hides.

### iOS App Group

On iOS, register the App Group `group.com.soneso.stellar.smartaccount.demo.flutter` at [developer.apple.com](https://developer.apple.com/account/resources/identifiers/list/applicationGroup) and refresh the App Group capability in Xcode (Signing & Capabilities → App Groups → refresh).

## Quick Reference

| Task | Command |
|------|---------|
| Install dependencies | `flutter pub get` |
| Run on iOS simulator | `flutter run -d "iPhone 16"` |
| Run on Android emulator | `flutter run -d emulator-5554` |
| Run on Web (interactive) | `flutter run -d chrome --dart-define=RP_ID=localhost` |
| Web dev server (background) | `./tool/run_web_dev.sh` |
| Stop web dev server | `./tool/run_web_dev.sh stop` |
| Build web (production) | `flutter build web --release --pwa-strategy=none --dart-define=RP_ID=<your-rp-id>` |
| Reset iOS simulator install | `xcrun simctl uninstall booted com.soneso.stellar.smartaccount.demo.flutter` |

## License

Copyright 2026 Soneso

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE).
