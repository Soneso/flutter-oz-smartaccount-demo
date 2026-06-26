/// Demo configuration: Stellar testnet defaults for the smart account demo.
///
/// All values here are testnet constants that are public by design — the repos
/// are private and the contracts are deployed on testnet only. Do NOT add
/// mainnet RPC URLs, signing seeds, or real credentials to this file.
library;

import '../util/policy_type.dart';

// ---------------------------------------------------------------------------
// Network
// ---------------------------------------------------------------------------

/// Soroban RPC endpoint for testnet. All SDK operations target this URL.
const String rpcUrl = 'https://soroban-testnet.stellar.org';

/// Stellar testnet network passphrase. Used for transaction signing and
/// deterministic contract address derivation.
const String networkPassphrase = 'Test SDF Network ; September 2015';

// ---------------------------------------------------------------------------
// Smart Account Contract
// ---------------------------------------------------------------------------

/// WASM hash of the multisig smart account contract deployed on testnet.
/// Passed to OZSmartAccountConfig.accountWasmHash for wallet deployment.
const String accountWasmHash =
    '86b49fe03f7df0ad1c2a28bd8361b923ab57096e09f397f92f0c00ae3bd06d28';

// ---------------------------------------------------------------------------
// Verifier Contracts
// ---------------------------------------------------------------------------

/// WebAuthn (secp256r1) signature verifier contract address.
/// Validates passkey signatures on-chain.
const String webauthnVerifierAddress =
    'CB26VN37RCVNTHJZDEPK6IRO2MMTS3Z2IEO5JD5BINY2OOJ5KKJG7NKY';

/// Ed25519 signature verifier contract address.
/// Validates Ed25519 signer signatures on-chain.
const String ed25519VerifierAddress =
    'CAW2Z46INPO5VIJEILMYSSEOLBVJIIII5GOE3TN5EUURSRM2FJCF7AJ6';

// ---------------------------------------------------------------------------
// Token Contracts
// ---------------------------------------------------------------------------

/// XLM native token Stellar Asset Contract (SAC) address on testnet.
/// Used for XLM transfers via the SAC token interface.
const String nativeTokenContract =
    'CDLZFC3SYJYDZT7K67VZ75HPJVIEUVNIXF47ZG2FB2RMQQVU2HHGCYSC';

// ---------------------------------------------------------------------------
// Demo Token
// ---------------------------------------------------------------------------
//
// DemoTokenService deploys a custom Soroban token for transfer testing.
// All values below are used to deterministically deploy and mint the token.
// The contract address is derived from the admin seed, salt seed, and network
// passphrase — identical inputs produce identical addresses on every platform.
//
// The admin keypair is derived from [demoTokenAdminSeed] via SHA-256.
// It is intentionally public: testnet-only and documented in README.

/// Display name passed to the token contract constructor.
const String demoTokenName = 'Demo Token';

/// Ticker symbol passed to the token contract constructor.
const String demoTokenSymbol = 'DEMO';

/// Decimal places for the demo token (7 = same as XLM, so 10 000 000 = 1 token).
const int demoTokenDecimals = 7;

/// Amount minted per wallet creation: 10 000 DEMO in stroops (10 000 * 10^7).
const int demoTokenMintAmount = 100000000000;

/// Seed string for deriving the token admin keypair via SHA-256.
/// The admin deploys the token contract and has mint authority.
const String demoTokenAdminSeed = 'soneso smart account demo token admin v1';

/// Seed string for deriving the deployment salt via SHA-256.
/// Combined with the admin public key and network passphrase, this produces
/// a deterministic token contract address.
const String demoTokenSaltSeed = 'soneso smart account demo token v1';

// ---------------------------------------------------------------------------
// Services
// ---------------------------------------------------------------------------

/// Relayer proxy for fee-sponsored transaction submission. The relayer wraps
/// transactions in a fee-bump so users do not need XLM to pay fees.
///
/// Empty string disables the relayer: the kit is constructed with
/// `relayerUrl: null` and the SDK submits transactions directly via the
/// Soroban RPC endpoint, so the connected wallet pays its own fees. Set to
/// `''` to test the RPC-only submission path.
const String defaultRelayerUrl =
    'https://smart-account-relayer-proxy.soneso.workers.dev';

/// Indexer for credential-to-contract address lookup. Maps a passkey
/// credential ID to its deployed smart account contract address.
///
/// Empty string disables the indexer: the kit is constructed with
/// `indexerUrl: null` and credential-to-contract lookup falls back to the
/// on-chain scan path.
const String defaultIndexerUrl =
    'https://smart-account-indexer.sdf-ecosystem.workers.dev';

// ---------------------------------------------------------------------------
// Coordination Server (agent-signer flow, steps 4 + 5)
// ---------------------------------------------------------------------------
//
// The coordination server brokers policy-rejected smart-account calls between
// the autonomous reference agent and this demo's approval inbox. The agent
// posts a rejected call; the inbox polls the pending requests, lets the user
// approve (re-submit the call under the Default rule) or reject, and reports
// the outcome back. See `coordination_server/README.md` for the wire contract.

/// Base URL of the coordination server. The approval inbox client targets this
/// host for all `/requests*` endpoints. The server binds `0.0.0.0:8787` by
/// default and is reachable from emulators, devices, and browsers on the LAN.
///
/// Override via `--dart-define=COORDINATION_URL=<value>` to point the demo at a
/// server on another host (for example a LAN IP for a physical device).
const String coordinationServerUrl = String.fromEnvironment(
  'COORDINATION_URL',
  defaultValue: 'http://localhost:8787',
);

/// Local-development bearer token shipped as the default for
/// [coordinationToken]. A release build must override it via
/// `--dart-define=COORDINATION_TOKEN`; shipping it would let anyone with the
/// well-known value drive the approval inbox.
const String devCoordinationToken = 'dev-token-change-me';

/// Bearer token presented on every coordination `/requests*` call. Must match
/// the `COORDINATION_TOKEN` the server was started with.
///
/// The default matches the server README's local-development token. Override
/// via `--dart-define=COORDINATION_TOKEN=<value>` for any shared or deployed
/// environment; never ship the development token to production.
const String coordinationToken = String.fromEnvironment(
  'COORDINATION_TOKEN',
  defaultValue: devCoordinationToken,
);

/// Returns a human-readable reason the coordination configuration is unsafe to
/// ship outside a debug build, or null when it is safe.
///
/// A release/profile build must not fall back to the development token or talk
/// to a cleartext (non-HTTPS) endpoint: either would silently ship the
/// local-development defaults. The approval-inbox client provider calls this in
/// non-debug builds and refuses to construct a client when it returns non-null.
/// Debug/demo runs skip the check so localhost development still works.
String? coordinationConfigShipBlocker({
  String token = coordinationToken,
  String url = coordinationServerUrl,
}) {
  if (token.isEmpty || token == devCoordinationToken) {
    return 'the development coordination token is still in use; set '
        'COORDINATION_TOKEN via --dart-define';
  }
  final parsed = Uri.tryParse(url);
  if (parsed == null || parsed.scheme.toLowerCase() != 'https') {
    return 'the coordination server URL is not HTTPS; set an https:// '
        'COORDINATION_URL via --dart-define';
  }
  return null;
}

// ---------------------------------------------------------------------------
// WebAuthn
// ---------------------------------------------------------------------------

/// Relying Party ID for passkey registration and authentication.
/// Must match the domain in AASA (iOS) and assetlinks.json (Android).
/// Override via `--dart-define=RP_ID=<value>` for non-production hosts
/// (for example `localhost` when running against the dev web server).
const String defaultRpId =
    String.fromEnvironment('RP_ID', defaultValue: 'soneso.com');

/// Display name shown to users during passkey registration prompts.
const String rpName = 'Smart Account Kit Demo';

// ---------------------------------------------------------------------------
// Context Rule Discovery
// ---------------------------------------------------------------------------

/// Maximum context rule ID scanned when iterating rules by ID.
/// Acts as a safety cap to prevent unbounded iteration if the active count
/// is stale. Contract uses monotonically increasing IDs with gaps from
/// removed rules.
const int maxContextRuleScanId = 25;

// ---------------------------------------------------------------------------
// Reown (WalletConnect)
// ---------------------------------------------------------------------------

/// Reown (WalletConnect) project ID for external wallet connection.
///
/// Required for Reown pairing on Android and iOS real devices. Not needed
/// for simulators, emulators, or Web (which uses the Freighter browser
/// extension). Empty by default: register a free project ID at
/// https://cloud.reown.com (add the bundle IDs to its allowlist) and set it here.
/// While this is blank, external-wallet connect is disabled — the connector
/// is not created and the "Connect Wallet" / import-from-wallet UI hides.
const String reownProjectId = '';

/// Display name advertised to Reown-compatible wallets during pairing.
const String reownAppName = 'Smart Account Demo';

/// Short description advertised to Reown-compatible wallets during pairing.
const String reownAppDescription = 'Stellar OZ Smart Account demo app';

/// Public URL advertised to Reown-compatible wallets during pairing.
const String reownAppUrl = 'https://soneso.com';

/// Download / homepage URL surfaced for the Freighter browser extension.
const String freighterDownloadUrl = 'https://www.freighter.app';

// ---------------------------------------------------------------------------
// Known Policy Contracts
// ---------------------------------------------------------------------------

/// Metadata for a known policy contract deployed on testnet.
final class PolicyInfo {
  const PolicyInfo({
    required this.type,
    required this.name,
    required this.description,
    required this.address,
  });

  final String type;
  final String name;
  final String description;
  final String address;
}

/// Known policy contracts available for installation on testnet.
const List<PolicyInfo> knownPolicies = [
  PolicyInfo(
    type: PolicyType.threshold,
    name: 'Threshold (M-of-N)',
    description: 'Requires M signatures out of N total signers.',
    address: 'CAZJ3UVRY3R3S5C5BH32GMYBRSN23N75ZEEXEOLXOUUAHDFIMVP4AXUC',
  ),
  PolicyInfo(
    type: PolicyType.spendingLimit,
    name: 'Spending Limit',
    description: 'Limits spending to a maximum amount per time period.',
    address: 'CBQE7L3UNP5IR4I7IBKLS7NV256WHR5TTH26HTMUIK7WXJC6J64RSE2L',
  ),
  PolicyInfo(
    type: PolicyType.weightedThreshold,
    name: 'Weighted Threshold',
    description:
        'Requires minimum total weight from signers with different voting weights.',
    address: 'CAF4OCRIB73T5777UWAQS7KGOG6WVIZ3EFXNNUYSPFSBKW2Q5XEIOSPW',
  ),
];
