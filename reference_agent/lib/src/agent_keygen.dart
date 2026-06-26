// Copyright 2026 Soneso. Reference agent for the OZ smart-account demo.
//
// AGENT BOOTSTRAP (print-key / keygen mode).
//
// Lets an operator obtain the agent's public key (a Stellar G-address) — and a
// fresh secret seed when none exists yet — BEFORE a full live configuration is
// available. The G-address is pasted into the demo's "Delegate to agent"
// screen, which registers it as the Ed25519 external signer the agent then
// signs with. The seed is copied into the agent config (AGENT_SECRET_SEED).
//
// This is the only part of the agent that does not need the rest of the live
// config: it derives or generates a keypair and nothing more.

import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import 'agent_config.dart';

/// Outcome of resolving the agent's signing identity for the print-key mode.
class AgentKeyResult {
  /// Constructs a key result.
  const AgentKeyResult({
    required this.accountId,
    required this.generated,
    this.secretSeed,
  });

  /// Stellar public key as a checksummed `G...` address (StrKey).
  final String accountId;

  /// Whether the key was newly generated (`true`) or derived from a supplied
  /// seed (`false`).
  final bool generated;

  /// The secret seed (`S...`) to copy into the agent config. Non-null ONLY when
  /// [generated] is `true`: a seed supplied by the operator is never echoed
  /// back, since they already hold it.
  final String? secretSeed;
}

/// Resolves the agent's identity for the print-key bootstrap mode.
///
/// When [seed] is a non-empty, valid Stellar secret seed, derives and returns
/// its `G...` address; [AgentKeyResult.generated] is `false` and
/// [AgentKeyResult.secretSeed] is `null` (the operator already holds the seed,
/// so it is not echoed). Otherwise generates a fresh Ed25519 keypair and
/// returns both the new seed and its `G...` address.
///
/// Throws [AgentConfigException] when [seed] is non-empty but malformed.
AgentKeyResult resolveAgentKey({String? seed}) {
  if (seed != null && seed.isNotEmpty) {
    if (!StrKey.isValidStellarSecretSeed(seed)) {
      throw const AgentConfigException(
        'AGENT_SECRET_SEED is set but is not a valid Stellar secret seed (S...).',
      );
    }
    final keypair = KeyPair.fromSecretSeed(seed);
    return AgentKeyResult(accountId: keypair.accountId, generated: false);
  }
  final keypair = KeyPair.random();
  return AgentKeyResult(
    accountId: keypair.accountId,
    generated: true,
    secretSeed: keypair.secretSeed,
  );
}

/// Formats [result] into operator-facing console lines.
///
/// For a generated key both the seed (to copy into `AGENT_SECRET_SEED`) and the
/// `G...` address (to paste into the demo's Delegate-to-agent screen) are
/// shown. For a supplied seed only the derived `G...` address is shown — the
/// secret is never printed.
List<String> formatAgentKeyOutput(AgentKeyResult result) {
  if (result.generated) {
    return <String>[
      'Generated a new agent Ed25519 keypair.',
      'AGENT_SECRET_SEED (copy into the agent config, keep secret): '
          '${result.secretSeed}',
      'Agent public key (paste into Delegate-to-agent): ${result.accountId}',
    ];
  }
  return <String>[
    'Derived the agent public key from AGENT_SECRET_SEED.',
    'Agent public key (paste into Delegate-to-agent): ${result.accountId}',
  ];
}

/// Whether the print-key bootstrap mode is requested, via [env]
/// (`AGENT_PRINT_KEY=true`, case-insensitive) or [args] (`--print-key`).
bool shouldPrintAgentKey({
  Map<String, String> env = const <String, String>{},
  List<String> args = const <String>[],
}) {
  final fromEnv = (env['AGENT_PRINT_KEY'] ?? '').toLowerCase() == 'true';
  final fromArgs = args.contains('--print-key');
  return fromEnv || fromArgs;
}
