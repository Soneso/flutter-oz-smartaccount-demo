// Copyright 2026 Soneso. Reference agent for the OZ smart-account demo.
//
// AGENT BOOTSTRAP ENTRY (print-key mode).
//
// Obtain the agent's public key (and a fresh seed when none exists yet) BEFORE
// a full live configuration is available. Runs headlessly under `flutter test`
// like the other agent entries (the stellar_flutter_sdk barrel transitively
// imports package:flutter, so a plain `dart run` cannot resolve).
//
//   # Generate a fresh 64-hex seed + 64-hex public key (no other config needed):
//   AGENT_PRINT_KEY=true flutter test test/agent_print_key_test.dart
//
//   # Show the hex public key for an existing seed (no secret is printed back):
//   AGENT_PRINT_KEY=true AGENT_SECRET_SEED=<64-hex> \
//     flutter test test/agent_print_key_test.dart
//
// Gated on AGENT_PRINT_KEY so the default `flutter test` run never generates a
// key as a side effect. The keygen itself lives in lib/src/agent_keygen.dart
// and is unit-tested in test/agent_keygen_test.dart.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reference_agent/reference_agent.dart';

/// Matches a raw 32-byte value rendered as 64-character lowercase hex.
final RegExp _hex64 = RegExp(r'^[0-9a-f]{64}$');

void main() {
  final env = Platform.environment;
  final printKey = shouldPrintAgentKey(env: env);

  test(
    'prints the agent public key (and a fresh seed when none is supplied)',
    () {
      final result = resolveAgentKey(seed: env['AGENT_SECRET_SEED']);
      for (final line in formatAgentKeyOutput(result)) {
        // ignore: avoid_print
        print('[agent] [KEY] $line');
      }

      expect(result.publicKeyHex, matches(_hex64));
      if (result.generated) {
        expect(result.secretSeedHex, isNotNull);
        expect(result.secretSeedHex, matches(_hex64));
      } else {
        expect(result.secretSeedHex, isNull);
      }
    },
    skip: printKey
        ? null
        : 'Set AGENT_PRINT_KEY=true to print the agent key. Optionally set '
            'AGENT_SECRET_SEED=<64-hex> to show the public key for an existing '
            'seed.',
  );
}
