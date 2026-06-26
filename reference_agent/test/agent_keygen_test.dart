// Copyright 2026 Soneso. Reference agent for the OZ smart-account demo.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reference_agent/reference_agent.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

/// Matches a raw 32-byte value rendered as 64-character lowercase hex.
final RegExp _hex64 = RegExp(r'^[0-9a-f]{64}$');

void main() {
  group('resolveAgentKey', () {
    test('generates a fresh keypair as 64-hex public key + 64-hex seed', () {
      final result = resolveAgentKey();
      expect(result.generated, isTrue);
      expect(result.secretSeedHex, isNotNull);
      expect(result.secretSeedHex, matches(_hex64));
      expect(result.publicKeyHex, matches(_hex64));
      // The reported public key is the one derived from the generated seed.
      final derived = KeyPair.fromSecretSeedList(
        Util.hexToBytes(result.secretSeedHex!),
      );
      expect(Util.bytesToHex(Uint8List.fromList(derived.publicKey)),
          result.publicKeyHex);
    });

    test('derives the hex public key from a supplied seed and does not echo it',
        () {
      final seedHex = resolveAgentKey().secretSeedHex!;
      final result = resolveAgentKey(seed: seedHex);
      expect(result.generated, isFalse);
      expect(result.secretSeedHex, isNull);
      expect(result.publicKeyHex, matches(_hex64));
      // The derived public key matches a direct keypair construction.
      final direct =
          KeyPair.fromSecretSeedList(Util.hexToBytes(seedHex));
      expect(Util.bytesToHex(Uint8List.fromList(direct.publicKey)),
          result.publicKeyHex);
    });

    test('accepts an upper-case hex seed and derives the same public key', () {
      final seedHex = resolveAgentKey().secretSeedHex!;
      final lower = resolveAgentKey(seed: seedHex);
      final upper = resolveAgentKey(seed: seedHex.toUpperCase());
      expect(upper.publicKeyHex, lower.publicKeyHex);
    });

    test('treats an empty seed as "generate a fresh key"', () {
      final result = resolveAgentKey(seed: '');
      expect(result.generated, isTrue);
      expect(result.secretSeedHex, isNotNull);
      expect(result.secretSeedHex, matches(_hex64));
    });

    test('rejects a non-hex seed', () {
      expect(
        () => resolveAgentKey(seed: 'not-a-seed'),
        throwsA(isA<AgentConfigException>()),
      );
    });

    test('rejects a wrong-length hex seed', () {
      // Valid hex but only 4 characters (2 bytes), not 64.
      expect(
        () => resolveAgentKey(seed: 'abcd'),
        throwsA(isA<AgentConfigException>()),
      );
      // 62 hex characters — one byte short of a 32-byte seed.
      expect(
        () => resolveAgentKey(seed: 'a' * 62),
        throwsA(isA<AgentConfigException>()),
      );
    });

    test('two generated seeds differ', () {
      expect(
        resolveAgentKey().secretSeedHex,
        isNot(resolveAgentKey().secretSeedHex),
      );
    });
  });

  group('formatAgentKeyOutput', () {
    test('a generated key prints the hex seed and the hex public key', () {
      final result = resolveAgentKey();
      final seedHex = result.secretSeedHex;
      expect(seedHex, isNotNull);
      final out = formatAgentKeyOutput(result).join('\n');
      expect(out, contains(seedHex));
      expect(out, contains(result.publicKeyHex));
      expect(out, contains('Delegate-to-agent'));
    });

    test('a supplied seed prints only the hex public key, never the secret',
        () {
      final seedHex = resolveAgentKey().secretSeedHex!;
      final result = resolveAgentKey(seed: seedHex);
      final out = formatAgentKeyOutput(result).join('\n');
      expect(out, contains(result.publicKeyHex));
      expect(out, isNot(contains(seedHex)));
    });
  });

  group('shouldPrintAgentKey', () {
    test('honors AGENT_PRINT_KEY=true (case-insensitive)', () {
      expect(
        shouldPrintAgentKey(env: const <String, String>{'AGENT_PRINT_KEY': 'true'}),
        isTrue,
      );
      expect(
        shouldPrintAgentKey(env: const <String, String>{'AGENT_PRINT_KEY': 'TRUE'}),
        isTrue,
      );
    });

    test('honors the --print-key argument', () {
      expect(shouldPrintAgentKey(args: const <String>['--print-key']), isTrue);
    });

    test('is false without either trigger', () {
      expect(shouldPrintAgentKey(), isFalse);
      expect(
        shouldPrintAgentKey(env: const <String, String>{'AGENT_PRINT_KEY': 'false'}),
        isFalse,
      );
    });
  });
}
