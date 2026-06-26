// Copyright 2026 Soneso. Reference agent for the OZ smart-account demo.

import 'package:flutter_test/flutter_test.dart';
import 'package:reference_agent/reference_agent.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

void main() {
  group('resolveAgentKey', () {
    test('derives the G-address from a supplied seed and does not echo it', () {
      final keypair = KeyPair.random();
      final result = resolveAgentKey(seed: keypair.secretSeed);
      expect(result.generated, isFalse);
      expect(result.secretSeed, isNull);
      expect(result.accountId, keypair.accountId);
    });

    test('generates a fresh, valid keypair when no seed is supplied', () {
      final result = resolveAgentKey();
      expect(result.generated, isTrue);
      expect(result.secretSeed, isNotNull);
      expect(StrKey.isValidStellarSecretSeed(result.secretSeed!), isTrue);
      expect(StrKey.isValidStellarAccountId(result.accountId), isTrue);
      // The reported G-address is the one derived from the generated seed.
      expect(
        KeyPair.fromSecretSeed(result.secretSeed!).accountId,
        result.accountId,
      );
    });

    test('treats an empty seed as "generate a fresh key"', () {
      final result = resolveAgentKey(seed: '');
      expect(result.generated, isTrue);
      expect(result.secretSeed, isNotNull);
    });

    test('rejects a malformed seed', () {
      expect(
        () => resolveAgentKey(seed: 'not-a-seed'),
        throwsA(isA<AgentConfigException>()),
      );
    });

    test('two generated keys differ', () {
      expect(resolveAgentKey().secretSeed, isNot(resolveAgentKey().secretSeed));
    });
  });

  group('formatAgentKeyOutput', () {
    test('a generated key prints the seed and the G-address', () {
      final result = resolveAgentKey();
      final seed = result.secretSeed;
      expect(seed, isNotNull);
      final out = formatAgentKeyOutput(result).join('\n');
      expect(out, contains(seed));
      expect(out, contains(result.accountId));
      expect(out, contains('Delegate-to-agent'));
    });

    test('a supplied seed prints only the G-address, never the secret', () {
      final keypair = KeyPair.random();
      final result = resolveAgentKey(seed: keypair.secretSeed);
      final out = formatAgentKeyOutput(result).join('\n');
      expect(out, contains(keypair.accountId));
      expect(out, isNot(contains(keypair.secretSeed)));
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
