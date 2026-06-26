// Copyright 2026 Soneso. Reference agent for the OZ smart-account demo.
//
// AGENT BOOTSTRAP ENTRY (print-key mode).
//
// Obtain the agent's public key (and a fresh seed when none exists yet) BEFORE
// a full live configuration is available. Runs headlessly under `flutter test`
// like the other agent entries (the stellar_flutter_sdk barrel transitively
// imports package:flutter, so a plain `dart run` cannot resolve).
//
//   # Generate a fresh seed + G-address (no other config needed):
//   AGENT_PRINT_KEY=true flutter test test/agent_print_key_test.dart
//
//   # Show the G-address for an existing seed (no secret is printed back):
//   AGENT_PRINT_KEY=true AGENT_SECRET_SEED=S... \
//     flutter test test/agent_print_key_test.dart
//
// Gated on AGENT_PRINT_KEY so the default `flutter test` run never generates a
// key as a side effect. The keygen itself lives in lib/src/agent_keygen.dart
// and is unit-tested in test/agent_keygen_test.dart.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reference_agent/reference_agent.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

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

      expect(StrKey.isValidStellarAccountId(result.accountId), isTrue);
      if (result.generated) {
        expect(result.secretSeed, isNotNull);
        expect(StrKey.isValidStellarSecretSeed(result.secretSeed!), isTrue);
      } else {
        expect(result.secretSeed, isNull);
      }
    },
    skip: printKey
        ? null
        : 'Set AGENT_PRINT_KEY=true to print the agent key. Optionally set '
            'AGENT_SECRET_SEED=S... to show the G-address for an existing seed.',
  );
}
