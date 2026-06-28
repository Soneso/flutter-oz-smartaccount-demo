// Copyright 2026 Soneso. Reference agent for the OZ smart-account demo.

import 'dart:convert';
import 'dart:io';

import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

/// Static testnet defaults shared by every reference-agent run.
///
/// Every value mirrors a constant already published in the demo app's
/// `lib/config/demo_config.dart` (or the coordination server README). They are
/// testnet-only, public by design, and safe to ship as defaults. Per-run
/// identity values (smart account, agent seed, destination) have no static
/// default and must be supplied explicitly.
abstract final class AgentDefaults {
  /// Soroban RPC endpoint for testnet.
  static const String rpcUrl = 'https://soroban-testnet.stellar.org';

  /// Stellar testnet network passphrase.
  static const String networkPassphrase = 'Test SDF Network ; September 2015';

  /// WASM hash of the multisig smart-account contract deployed on testnet.
  static const String accountWasmHash =
      '86b49fe03f7df0ad1c2a28bd8361b923ab57096e09f397f92f0c00ae3bd06d28';

  /// WebAuthn (secp256r1) signature verifier contract address. Required by
  /// [OZSmartAccountConfig] even though the headless agent never signs with a
  /// passkey.
  static const String webauthnVerifierAddress =
      'CB26VN37RCVNTHJZDEPK6IRO2MMTS3Z2IEO5JD5BINY2OOJ5KKJG7NKY';

  /// Ed25519 signature verifier contract address. The agent registers as an
  /// `External(ed25519VerifierAddress, publicKey)` signer under this verifier.
  static const String ed25519VerifierAddress =
      'CAW2Z46INPO5VIJEILMYSSEOLBVJIIII5GOE3TN5EUURSRM2FJCF7AJ6';

  /// Relayer proxy for fee-sponsored (gasless) submission. The empty string
  /// disables the relayer and submits directly via the RPC endpoint.
  static const String relayerUrl =
      'https://smart-account-relayer-proxy.soneso.workers.dev';

  /// XLM native token Stellar Asset Contract (SAC) on testnet. Used as the
  /// default scoped-call target token.
  static const String nativeTokenContract =
      'CDLZFC3SYJYDZT7K67VZ75HPJVIEUVNIXF47ZG2FB2RMQQVU2HHGCYSC';

  /// Decimal scale used when converting the human-readable [AgentConfig.amount]
  /// to base units (7 = same scale as XLM and the DEMO token).
  static const int tokenDecimals = 7;

  /// Default human-readable transfer amount.
  static const String amount = '1';

  /// Coordination server base URL. Matches the server's default bind port.
  static const String coordinationBaseUrl = 'http://localhost:8787';

  /// Coordination server bearer token. Matches the server README's documented
  /// development token. Override in any shared or deployed environment.
  static const String coordinationToken = 'dev-token-change-me';

  /// Seconds between successive escalation polls.
  static const int pollIntervalSeconds = 3;

  /// Maximum number of escalation polls before the agent gives up waiting.
  static const int pollMaxAttempts = 40;

  /// Known testnet policy contracts, by policy type. Informational reference
  /// for operators wiring up the step-2 delegation flow; the agent does not
  /// install policies itself.
  static const Map<String, String> knownPolicies = <String, String>{
    'threshold': 'CAZJ3UVRY3R3S5C5BH32GMYBRSN23N75ZEEXEOLXOUUAHDFIMVP4AXUC',
    'spendingLimit': 'CBQE7L3UNP5IR4I7IBKLS7NV256WHR5TTH26HTMUIK7WXJC6J64RSE2L',
    'weightedThreshold':
        'CAF4OCRIB73T5777UWAQS7KGOG6WVIZ3EFXNNUYSPFSBKW2Q5XEIOSPW',
  };
}

/// Thrown when an [AgentConfig] cannot satisfy the requirements of a live run.
class AgentConfigException implements Exception {
  /// Constructs a config exception with a user-facing [message].
  const AgentConfigException(this.message);

  /// Human-readable description of the configuration problem.
  final String message;

  @override
  String toString() => 'AgentConfigException: $message';
}

/// Immutable configuration for a single reference-agent run.
///
/// Construct directly for tests, or via [AgentConfig.resolve] to layer
/// command-line arguments over environment variables over an optional JSON
/// file over the [AgentDefaults]. Precedence, highest first:
/// CLI args > environment > JSON file > defaults.
class AgentConfig {
  /// Constructs a configuration. Static network values fall back to
  /// [AgentDefaults]; per-run identity values default to `null` and must be
  /// supplied for a live run (see [validateForLiveRun]).
  const AgentConfig({
    this.rpcUrl = AgentDefaults.rpcUrl,
    this.networkPassphrase = AgentDefaults.networkPassphrase,
    this.accountWasmHash = AgentDefaults.accountWasmHash,
    this.webauthnVerifierAddress = AgentDefaults.webauthnVerifierAddress,
    this.ed25519VerifierAddress = AgentDefaults.ed25519VerifierAddress,
    this.relayerUrl = AgentDefaults.relayerUrl,
    this.tokenContractId = AgentDefaults.nativeTokenContract,
    this.tokenDecimals = AgentDefaults.tokenDecimals,
    this.amount = AgentDefaults.amount,
    this.smartAccountContractId,
    this.agentSecretSeed,
    this.destinationAddress,
    this.coordinationBaseUrl = AgentDefaults.coordinationBaseUrl,
    this.coordinationToken = AgentDefaults.coordinationToken,
    this.pollInterval = const Duration(seconds: AgentDefaults.pollIntervalSeconds),
    this.pollMaxAttempts = AgentDefaults.pollMaxAttempts,
  });

  /// Soroban RPC endpoint URL.
  final String rpcUrl;

  /// Stellar network passphrase.
  final String networkPassphrase;

  /// 64-character hex WASM hash of the smart-account contract.
  final String accountWasmHash;

  /// WebAuthn signature verifier contract address (C-address).
  final String webauthnVerifierAddress;

  /// Ed25519 signature verifier contract address (C-address).
  final String ed25519VerifierAddress;

  /// Relayer URL for gasless submission; the empty string disables it.
  final String relayerUrl;

  /// Contract address of the token the agent calls (`transfer`).
  final String tokenContractId;

  /// Decimal scale of [tokenContractId] used for amount conversion.
  final int tokenDecimals;

  /// Human-readable transfer amount (decimal string, e.g. `"1"` or `"10.5"`).
  final String amount;

  /// Deployed smart-account contract address (C-address). Required for a live
  /// run.
  final String? smartAccountContractId;

  /// Agent Ed25519 secret seed as raw 64-character hex (32 bytes). Required for
  /// a live run.
  final String? agentSecretSeed;

  /// Transfer recipient address (G- or C-address). Required for a live
  /// `transfer` call.
  final String? destinationAddress;

  /// Coordination server base URL.
  final String coordinationBaseUrl;

  /// Coordination server bearer token.
  final String coordinationToken;

  /// Delay between escalation polls.
  final Duration pollInterval;

  /// Maximum escalation polls before the agent stops waiting.
  final int pollMaxAttempts;

  /// Whether every value required for a live, end-to-end run is present.
  bool get isCompleteForLiveRun {
    try {
      validateForLiveRun();
      return true;
    } on AgentConfigException {
      return false;
    }
  }

  /// Validates that the per-run identity values are present and well-formed.
  ///
  /// Throws [AgentConfigException] describing the first problem found.
  void validateForLiveRun() {
    final smartAccount = smartAccountContractId;
    if (smartAccount == null || smartAccount.isEmpty) {
      throw const AgentConfigException('smartAccountContractId is required.');
    }
    if (!StrKey.isValidContractId(smartAccount)) {
      throw AgentConfigException(
        'smartAccountContractId is not a valid contract address: $smartAccount',
      );
    }

    final seed = agentSecretSeed;
    if (seed == null || seed.isEmpty) {
      throw const AgentConfigException('agentSecretSeed is required.');
    }
    if (seed.length != 64 || !isHexString(seed)) {
      throw const AgentConfigException(
        'agentSecretSeed is not a valid 64-character hex Ed25519 seed.',
      );
    }

    final destination = destinationAddress;
    if (destination == null || destination.isEmpty) {
      throw const AgentConfigException('destinationAddress is required.');
    }
    if (!StrKey.isValidStellarAccountId(destination) &&
        !StrKey.isValidContractId(destination)) {
      throw AgentConfigException(
        'destinationAddress is not a valid G- or C-address: $destination',
      );
    }

    if (!StrKey.isValidContractId(ed25519VerifierAddress)) {
      throw AgentConfigException(
        'ed25519VerifierAddress is not a valid contract address: '
        '$ed25519VerifierAddress',
      );
    }
    if (!StrKey.isValidContractId(tokenContractId)) {
      throw AgentConfigException(
        'tokenContractId is not a valid contract address: $tokenContractId',
      );
    }
    if (coordinationBaseUrl.isEmpty) {
      throw const AgentConfigException('coordinationBaseUrl is required.');
    }
    if (coordinationToken.isEmpty) {
      throw const AgentConfigException('coordinationToken is required.');
    }
  }

  /// Returns a copy of this configuration with the given fields replaced.
  AgentConfig copyWith({
    String? rpcUrl,
    String? networkPassphrase,
    String? accountWasmHash,
    String? webauthnVerifierAddress,
    String? ed25519VerifierAddress,
    String? relayerUrl,
    String? tokenContractId,
    int? tokenDecimals,
    String? amount,
    String? smartAccountContractId,
    String? agentSecretSeed,
    String? destinationAddress,
    String? coordinationBaseUrl,
    String? coordinationToken,
    Duration? pollInterval,
    int? pollMaxAttempts,
  }) {
    return AgentConfig(
      rpcUrl: rpcUrl ?? this.rpcUrl,
      networkPassphrase: networkPassphrase ?? this.networkPassphrase,
      accountWasmHash: accountWasmHash ?? this.accountWasmHash,
      webauthnVerifierAddress:
          webauthnVerifierAddress ?? this.webauthnVerifierAddress,
      ed25519VerifierAddress:
          ed25519VerifierAddress ?? this.ed25519VerifierAddress,
      relayerUrl: relayerUrl ?? this.relayerUrl,
      tokenContractId: tokenContractId ?? this.tokenContractId,
      tokenDecimals: tokenDecimals ?? this.tokenDecimals,
      amount: amount ?? this.amount,
      smartAccountContractId:
          smartAccountContractId ?? this.smartAccountContractId,
      agentSecretSeed: agentSecretSeed ?? this.agentSecretSeed,
      destinationAddress: destinationAddress ?? this.destinationAddress,
      coordinationBaseUrl: coordinationBaseUrl ?? this.coordinationBaseUrl,
      coordinationToken: coordinationToken ?? this.coordinationToken,
      pollInterval: pollInterval ?? this.pollInterval,
      pollMaxAttempts: pollMaxAttempts ?? this.pollMaxAttempts,
    );
  }

  /// Resolves a configuration by layering, highest precedence first:
  /// [args] (`--kebab-key=value`) > [env] (`AGENT_UPPER_SNAKE`) > the JSON file
  /// at `--config`/`AGENT_CONFIG_FILE`/[jsonPath] > [AgentDefaults].
  ///
  /// [env] defaults to [Platform.environment]. The JSON file, when present,
  /// must decode to a JSON object whose keys are the camelCase field names.
  static AgentConfig resolve({
    List<String> args = const <String>[],
    Map<String, String>? env,
    String? jsonPath,
  }) {
    final environment = env ?? Platform.environment;
    final argMap = _parseArgs(args);

    final resolvedJsonPath = argMap['config'] ??
        environment['AGENT_CONFIG_FILE'] ??
        jsonPath;
    final Map<String, dynamic> json = resolvedJsonPath == null
        ? const <String, dynamic>{}
        : _readJsonFile(resolvedJsonPath);

    String? pick(String argKey, String envKey, String jsonKey) {
      final fromArg = argMap[argKey];
      if (fromArg != null) return fromArg;
      final fromEnv = environment[envKey];
      if (fromEnv != null) return fromEnv;
      final fromJson = json[jsonKey];
      if (fromJson != null) return fromJson.toString();
      return null;
    }

    int pickInt(String argKey, String envKey, String jsonKey, int fallback) {
      final raw = pick(argKey, envKey, jsonKey);
      if (raw == null) return fallback;
      final parsed = int.tryParse(raw);
      if (parsed == null) {
        throw AgentConfigException('$jsonKey must be an integer, got: $raw');
      }
      return parsed;
    }

    final pollSeconds = pickInt(
      'poll-interval-seconds',
      'AGENT_POLL_INTERVAL_SECONDS',
      'pollIntervalSeconds',
      AgentDefaults.pollIntervalSeconds,
    );

    return AgentConfig(
      rpcUrl: pick('rpc-url', 'AGENT_RPC_URL', 'rpcUrl') ?? AgentDefaults.rpcUrl,
      networkPassphrase:
          pick('network-passphrase', 'AGENT_NETWORK_PASSPHRASE',
                  'networkPassphrase') ??
              AgentDefaults.networkPassphrase,
      accountWasmHash:
          pick('account-wasm-hash', 'AGENT_ACCOUNT_WASM_HASH',
                  'accountWasmHash') ??
              AgentDefaults.accountWasmHash,
      webauthnVerifierAddress:
          pick('webauthn-verifier', 'AGENT_WEBAUTHN_VERIFIER',
                  'webauthnVerifierAddress') ??
              AgentDefaults.webauthnVerifierAddress,
      ed25519VerifierAddress:
          pick('ed25519-verifier', 'AGENT_ED25519_VERIFIER',
                  'ed25519VerifierAddress') ??
              AgentDefaults.ed25519VerifierAddress,
      relayerUrl: pick('relayer-url', 'AGENT_RELAYER_URL', 'relayerUrl') ??
          AgentDefaults.relayerUrl,
      tokenContractId:
          pick('token-contract', 'AGENT_TOKEN_CONTRACT', 'tokenContractId') ??
              AgentDefaults.nativeTokenContract,
      tokenDecimals: pickInt('token-decimals', 'AGENT_TOKEN_DECIMALS',
          'tokenDecimals', AgentDefaults.tokenDecimals),
      amount: pick('amount', 'AGENT_AMOUNT', 'amount') ?? AgentDefaults.amount,
      smartAccountContractId:
          pick('smart-account', 'AGENT_SMART_ACCOUNT', 'smartAccountContractId'),
      agentSecretSeed:
          pick('secret-seed', 'AGENT_SECRET_SEED', 'agentSecretSeed'),
      destinationAddress:
          pick('destination', 'AGENT_DESTINATION', 'destinationAddress'),
      coordinationBaseUrl:
          pick('coordination-url', 'AGENT_COORDINATION_URL',
                  'coordinationBaseUrl') ??
              AgentDefaults.coordinationBaseUrl,
      coordinationToken:
          pick('coordination-token', 'AGENT_COORDINATION_TOKEN',
                  'coordinationToken') ??
              AgentDefaults.coordinationToken,
      pollInterval: Duration(seconds: pollSeconds),
      pollMaxAttempts: pickInt('poll-max-attempts', 'AGENT_POLL_MAX_ATTEMPTS',
          'pollMaxAttempts', AgentDefaults.pollMaxAttempts),
    );
  }

  /// Parses `--key=value` and `--key value` argument pairs into a map keyed by
  /// the kebab-case option name (without the leading `--`).
  static Map<String, String> _parseArgs(List<String> args) {
    final map = <String, String>{};
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (!arg.startsWith('--')) continue;
      final body = arg.substring(2);
      final eq = body.indexOf('=');
      if (eq >= 0) {
        map[body.substring(0, eq)] = body.substring(eq + 1);
      } else if (i + 1 < args.length && !args[i + 1].startsWith('--')) {
        map[body] = args[i + 1];
        i++;
      } else {
        // A bare boolean-style flag; record its presence as "true".
        map[body] = 'true';
      }
    }
    return map;
  }

  /// Reads and decodes a JSON object from [path].
  static Map<String, dynamic> _readJsonFile(String path) {
    final file = File(path);
    if (!file.existsSync()) {
      throw AgentConfigException('Config file not found: $path');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(file.readAsStringSync());
    } catch (e) {
      throw AgentConfigException('Failed to parse JSON config $path: $e');
    }
    if (decoded is! Map<String, dynamic>) {
      throw AgentConfigException(
        'JSON config $path must decode to an object, got: ${decoded.runtimeType}',
      );
    }
    return decoded;
  }

  @override
  String toString() {
    // Redacts the agent seed and bearer token so the config is safe to log.
    return 'AgentConfig(rpcUrl: $rpcUrl, network: $networkPassphrase, '
        'smartAccount: $smartAccountContractId, '
        'ed25519Verifier: $ed25519VerifierAddress, '
        'token: $tokenContractId, amount: $amount, '
        'destination: $destinationAddress, '
        'relayer: ${relayerUrl.isEmpty ? '(disabled)' : relayerUrl}, '
        'coordination: $coordinationBaseUrl, '
        'agentSecretSeed: ${agentSecretSeed == null ? 'null' : '***'}, '
        'coordinationToken: ***, '
        'pollInterval: $pollInterval, pollMaxAttempts: $pollMaxAttempts)';
  }
}
