// Copyright 2026 Soneso. Reference agent for the OZ smart-account demo.
//
// AGENT BOOTSTRAP (print-key / keygen mode).
//
// Lets an operator obtain the agent's Ed25519 public key — and a fresh secret
// seed when none exists yet — BEFORE a full live configuration is available.
// The public key is rendered as raw 64-character hex and pasted into the demo's
// "Delegate to agent" screen, which registers it as the Ed25519 external signer
// the agent then signs with. The seed is copied into the agent config
// (AGENT_SECRET_SEED).
//
// This is the only part of the agent that does not need the rest of the live
// config: it derives or generates a keypair and nothing more.

import 'dart:math';
import 'dart:typed_data';

import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import 'agent_config.dart';

/// Number of hex characters in a raw 32-byte Ed25519 value (public key or seed).
const int agentHexKeyLength = 64;

/// Outcome of resolving the agent's signing identity for the print-key mode.
class AgentKeyResult {
  /// Constructs a key result.
  const AgentKeyResult({
    required this.publicKeyHex,
    required this.generated,
    this.secretSeedHex,
  });

  /// The agent's raw 32-byte Ed25519 public key as 64-character lowercase hex.
  final String publicKeyHex;

  /// Whether the key was newly generated (`true`) or derived from a supplied
  /// seed (`false`).
  final bool generated;

  /// The raw 32-byte secret seed as 64-character lowercase hex, to copy into the
  /// agent config (`AGENT_SECRET_SEED`). Non-null ONLY when [generated] is
  /// `true`: a seed supplied by the operator is never echoed back, since they
  /// already hold it.
  final String? secretSeedHex;
}

/// Resolves the agent's identity for the print-key bootstrap mode.
///
/// When [seed] is a non-empty, valid 64-character hex seed, derives and returns
/// its public key hex; [AgentKeyResult.generated] is `false` and
/// [AgentKeyResult.secretSeedHex] is `null` (the operator already holds the
/// seed, so it is not echoed). Otherwise generates a fresh Ed25519 keypair from
/// a cryptographically secure 32-byte seed and returns both the new seed hex and
/// its public key hex.
///
/// Throws [AgentConfigException] when [seed] is non-empty but malformed.
AgentKeyResult resolveAgentKey({String? seed}) {
  if (seed != null && seed.isNotEmpty) {
    final normalized = seed.trim();
    if (!_isValidHexSeed(normalized)) {
      throw const AgentConfigException(
        'AGENT_SECRET_SEED is set but is not a valid 64-character hex '
        'Ed25519 seed.',
      );
    }
    final keypair = KeyPair.fromSecretSeedList(Util.hexToBytes(normalized));
    return AgentKeyResult(
      publicKeyHex: _publicKeyHex(keypair),
      generated: false,
    );
  }
  final seedBytes = _generateSeedBytes();
  final keypair = KeyPair.fromSecretSeedList(seedBytes);
  return AgentKeyResult(
    publicKeyHex: _publicKeyHex(keypair),
    generated: true,
    secretSeedHex: Util.bytesToHex(seedBytes),
  );
}

/// Formats [result] into operator-facing console lines.
///
/// For a generated key both the seed (to copy into `AGENT_SECRET_SEED`) and the
/// public key hex (to paste into the demo's Delegate-to-agent screen) are
/// shown. For a supplied seed only the derived public key hex is shown — the
/// secret is never printed.
List<String> formatAgentKeyOutput(AgentKeyResult result) {
  if (result.generated) {
    return <String>[
      'Generated a new agent Ed25519 keypair.',
      'AGENT_SECRET_SEED (copy into the agent config, keep secret): '
          '${result.secretSeedHex}',
      'Agent public key (paste into Delegate-to-agent): ${result.publicKeyHex}',
    ];
  }
  return <String>[
    'Derived the agent public key from AGENT_SECRET_SEED.',
    'Agent public key (paste into Delegate-to-agent): ${result.publicKeyHex}',
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

/// The keypair's raw 32-byte public key as 64-character lowercase hex.
String _publicKeyHex(KeyPair keypair) =>
    Util.bytesToHex(Uint8List.fromList(keypair.publicKey));

/// Whether [value] is exactly 64 hex characters (a raw 32-byte seed).
bool _isValidHexSeed(String value) =>
    value.length == agentHexKeyLength && isHexString(value);

/// Generates a cryptographically secure raw 32-byte Ed25519 seed.
Uint8List _generateSeedBytes() {
  final random = Random.secure();
  final seed = Uint8List(32);
  for (var i = 0; i < seed.length; i++) {
    seed[i] = random.nextInt(256);
  }
  return seed;
}
