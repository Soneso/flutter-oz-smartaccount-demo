# Passkey (WebAuthn) Domain Setup

This document describes the Relying Party (RP) domain configuration required for WebAuthn passkeys to function on each platform. Passkeys are bound to a specific RP ID (typically a domain name), and the authenticator only allows credential use when the requesting origin matches that RP ID.

## Overview

WebAuthn passkeys require a trust relationship between the app and a domain. The RP ID identifies which domain "owns" the passkey credentials. On the web, the browser enforces this automatically from the page origin. On mobile, each platform has its own mechanism for associating an app with a domain: iOS uses Associated Domains with a hosted `apple-app-site-association` file, and Android uses Digital Asset Links with a hosted `assetlinks.json` file.

| Platform | RP ID Default | Association Mechanism | Dev Configuration |
|----------|---------------|----------------------|-------------------|
| Web | Page origin hostname | Origin-based (automatic) | Works on `localhost` and `127.0.0.1` |
| iOS | Must be set explicitly | Associated Domains entitlement + `apple-app-site-association` | `?mode=developer` suffix (simulator / local device); removed for Release |
| Android | Must be set explicitly | Digital Asset Links (`assetlinks.json`) | Requires a hosted domain |

---

## Web

### RP ID

On the web, the RP ID defaults to the page origin's hostname. If the demo runs at `http://localhost:5173`, the RP ID is `localhost`. The repo sets `defaultRpId` to `soneso.com` in `lib/config/demo_config.dart`; override at build time with `--dart-define=RP_ID=<value>`.

```bash
flutter run -d chrome --dart-define=RP_ID=localhost
```

### HTTPS Requirement

WebAuthn requires a secure context:

- `localhost` and `127.0.0.1` work without HTTPS (browser exception for development).
- All other origins require HTTPS with a valid TLS certificate.

### `.well-known/webauthn`

The `.well-known/webauthn` endpoint is only relevant when using a registrable domain RP ID that differs from the page origin (cross-origin passkey requests). For standard same-origin usage, this file is not required.

### Permissions-Policy (hosted deployments)

Serve this response header from the host:

```
Permissions-Policy: publickey-credentials-get=(*), publickey-credentials-create=(*)
```

### Content-Security-Policy (hosted deployments)

Serve this response header from the host:

```
Content-Security-Policy:
  default-src 'self';
  connect-src 'self'
    https://soroban-testnet.stellar.org
    https://smart-account-indexer.sdf-ecosystem.workers.dev
    https://smart-account-relayer-proxy.soneso.workers.dev
    https://esm.sh;
  script-src 'self' https://esm.sh 'wasm-unsafe-eval';
  style-src 'self';
  img-src 'self' data:;
  frame-ancestors 'none';
```

Notes:

- `https://esm.sh` appears in `connect-src` and `script-src` because the web build dynamically imports `@stellar/freighter-api@6` from that CDN.
- `'wasm-unsafe-eval'` is required for Soroban WASM contract execution.
- No `unsafe-eval` or `unsafe-inline` is used; the Flutter web build does not need either.
- There is no `<meta>` CSP tag in `web/index.html`. Content-Security-Policy must be served as a response header by the hosting layer.

---

## iOS

iOS uses the AuthenticationServices framework (`ASAuthorizationPlatformPublicKeyCredentialProvider`) for passkey operations. The app must be associated with the RP domain through Associated Domains.

### Step 1: Set the RP ID

The RP ID is set on `PlatformWebAuthnProvider(rpId: ...)`. In this demo, `defaultRpId` from `DemoConfig` is used (overridable via `--dart-define=RP_ID=<value>`).

### Step 2: Associated Domains entitlement

The entitlement is already configured at `ios/Runner/Runner.entitlements` and uses developer mode:

```xml
<key>com.apple.developer.associated-domains</key>
<array>
    <string>webcredentials:soneso.com?mode=developer</string>
</array>
```

The `?mode=developer` suffix makes iOS bypass the hosted-AASA check, so passkeys for the RP domain work on the simulator and on dev-mode devices without `soneso.com`'s AASA listing this bundle ID. Replace `soneso.com` with your RP ID for a custom domain.

This developer-mode suffix must not ship in a Release build: the Podfile Release gate fails the build while it is present (see the Release-build gate section below). Before distributing, remove `?mode=developer`, switch the RP ID to a domain you control, and host its AASA.

### Step 3: Host `apple-app-site-association`

Serve a JSON file (no `.json` extension) at:

```
https://<rp-id>/.well-known/apple-app-site-association
```

Contents:

```json
{
  "webcredentials": {
    "apps": [
      "<TEAM_ID>.com.soneso.stellar.smartaccount.demo.flutter"
    ]
  }
}
```

Replace `<TEAM_ID>` with your Apple Developer Team ID.

Requirements for this file:

- Served over HTTPS with a valid TLS certificate.
- Content-Type `application/json`.
- File path exactly `/.well-known/apple-app-site-association` (no `.json` extension).

### Team ID

Find your Apple Developer Team ID at:

- The Apple Developer Portal under Membership Details.
- Or in Xcode: select the project, open Signing & Capabilities, note the Team field.

### iOS Simulator notes

- The iOS Simulator supports passkeys starting with Xcode 14 / iOS 16 Simulator.
- Simulator passkeys are stored locally and do not sync through iCloud Keychain.
- The committed developer-mode entitlement (see Step 2) lets the simulator work without the domain listing this bundle ID; network access is still required. See Apple's [supporting associated domains](https://developer.apple.com/documentation/xcode/supporting-associated-domains) for the full validation matrix.

### Release-build gate

The Podfile post-install hook installs a build phase (`ios/Podfile`) that fails any Release build while `?mode=developer` is still present in the entitlements file. The check runs at code-sign time. Do not remove the gate. Because the committed entitlement ships with `?mode=developer`, Debug builds work out of the box but a Release build is intentionally blocked until you remove the suffix and switch to your own RP domain (see below).

To ship a Release build:

1. Update the AASA on the RP domain to include the production bundle ID and Team ID.
2. Wait for Apple's CDN to pick up the change (up to 24 hours on first publish).
3. Remove the `?mode=developer` suffix from `Runner.entitlements`.
4. Rebuild for Release.

---

## Android

Android uses the Credential Manager API (API 28+) for passkey operations. The app must be associated with the RP domain through Digital Asset Links.

### Step 1: Set the RP ID

The RP ID is set on `PlatformWebAuthnProvider(rpId: ...)`. In this demo, `defaultRpId` from `DemoConfig` is used (overridable via `--dart-define=RP_ID=<value>`).

### Step 2: Host `assetlinks.json`

Serve the file at:

```
https://<rp-id>/.well-known/assetlinks.json
```

Contents:

```json
[
  {
    "relation": ["delegate_permission/common.get_login_creds"],
    "target": {
      "namespace": "android_app",
      "package_name": "com.soneso.stellar.smartaccount.demo.flutter",
      "sha256_cert_fingerprints": ["<SHA256_OF_SIGNING_KEY>"]
    }
  }
]
```

Replace `<SHA256_OF_SIGNING_KEY>` with the SHA-256 fingerprint of your signing certificate.

### Step 3: Obtain the SHA-256 fingerprint

For a release build:

```bash
keytool -list -v -keystore <your.keystore> -alias <alias>
```

For the local debug keystore:

```bash
keytool -list -v -keystore ~/.android/debug.keystore -alias androiddebugkey -storepass android
```

### Step 4: Verify the asset link

Once published, verify the file is reachable through the Google Digital Asset Links API:

```
https://digitalassetlinks.googleapis.com/v1/statements:list?source.web.site=https://<rp-id>&relation=delegate_permission/common.get_login_creds
```

### Android Emulator notes

Passkeys on Android emulators require:

- Google Play Services (use a "Google APIs" system image; "Google Play" images may be locked down).
- A Google account signed in on the emulator.
- Network access so the emulator can reach the RP domain for `assetlinks.json` verification.

The emulator cannot verify `assetlinks.json` against `localhost`. Use a real domain even during development.

---

## Reown App Group (iOS)

The entitlement `group.com.soneso.stellar.smartaccount.demo.flutter` is configured in `ios/Runner/Runner.entitlements` and is required by the Reown SDK for relay-session storage.

To run on a physical iOS device:

1. Go to `https://developer.apple.com/account/resources/identifiers/list/applicationGroup`.
2. Register `group.com.soneso.stellar.smartaccount.demo.flutter` under Identifiers → App Groups.
3. In Xcode, refresh the App Group capability (Signing & Capabilities → App Groups → refresh).

This is not needed for simulator builds (wallet connection is hidden on simulators).

## Reown project allowlist

External-wallet connect on mobile requires your own Reown (WalletConnect) project ID; the demo does not ship one. Register a free project ID at [cloud.reown.com](https://cloud.reown.com), add the bundle ID `com.soneso.stellar.smartaccount.demo.flutter` (one ID covers both iOS and Android) to its allowlist, and set `reownProjectId` in `lib/config/demo_config.dart`. While `reownProjectId` is unset, external-wallet connect is disabled and the connect / import-from-wallet UI hides.

---

## Permissions matrix

| Capability | iOS | Android | Web |
|---|---|---|---|
| Associated Domains (AASA) | Required | Not applicable | Not applicable |
| Digital Asset Links | Not applicable | Required | Not applicable |
| App Groups | Required (Reown relay-session storage) | Not applicable | Not applicable |
| Network (outbound) | Implicit (App Transport Security) | Implicit (targetSdk ≥ 23) | Implicit |
| Camera | Not requested | Not requested | Not requested |
| Clipboard read | Not requested | Not requested | Not requested |
| `publickey-credentials-get` | Entitlement | Credential Manager | Permissions-Policy |
| `publickey-credentials-create` | Entitlement | Credential Manager | Permissions-Policy |

---

## Custom Domain Setup (Production)

When deploying to production, replace `soneso.com` with your production domain.

### What Changes Per Platform

| Item | Web | iOS | Android |
|------|-----|-----|---------|
| `rpId` on provider | Set to your domain | Set to your domain | Set to your domain |
| `rpName` on provider | Set display name | Set display name | Set display name |
| Domain file | `.well-known/webauthn` (only if cross-origin) | `.well-known/apple-app-site-association` | `.well-known/assetlinks.json` |
| App config | None | Team ID + bundle ID in association file | Package name + signing fingerprint in `assetlinks.json` |
| Entitlement | None | `webcredentials:<domain>` | None |
| TLS | Required (except localhost) | Required | Required |

### Steps

1. **Register a domain** and configure DNS to point to your server.
2. **Obtain a TLS certificate** (for example through Let's Encrypt) for the domain.
3. **Set the RP ID** by passing `--dart-define=RP_ID=<your-domain>` at build time (or by changing `defaultRpId` in `lib/config/demo_config.dart`).
4. **Host the domain association files** as described in each platform section above. All files must be served over HTTPS.
5. **Update app identifiers**:
   - iOS: update the Team ID and bundle identifier in `apple-app-site-association`; set the Associated Domains entitlement to `webcredentials:<your-domain>` and ensure no `?mode=developer` suffix is present.
   - Android: update `package_name` and `sha256_cert_fingerprints` in `assetlinks.json` for your release signing key.
6. **Test on real devices.** Simulators and emulators behave differently from physical hardware for biometric prompts and credential sync.

### RP ID Scope

The RP ID must be a registrable domain or a subdomain of the page origin (web). Mobile RP IDs follow the same scope rule against the hosted association files. For example:

- A page at `https://app.example.com` can use RP ID `example.com` or `app.example.com`.
- A page at `https://app.example.com` cannot use RP ID `other.com`.

Choose the RP ID carefully. Passkey credentials are permanently bound to the RP ID used at creation time. Changing the RP ID later invalidates all existing passkeys.

### Cross-Platform Passkey Sharing

Passkeys created on one platform can be used on another when:

- The same RP ID is used on all platforms.
- The credentials sync (iCloud Keychain on Apple platforms, Google Password Manager on Android and Chrome).
- The domain association files are correctly configured for each platform.

This lets a user create a passkey on the web and later use it on iOS, or vice versa.

