// Copyright 2026 Soneso. Reference agent for the OZ smart-account demo.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reference_agent/reference_agent.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

void main() {
  group('defaults', () {
    test('a bare config carries the demo testnet defaults', () {
      const config = AgentConfig();
      expect(config.rpcUrl, AgentDefaults.rpcUrl);
      expect(config.networkPassphrase, AgentDefaults.networkPassphrase);
      expect(config.accountWasmHash, AgentDefaults.accountWasmHash);
      expect(config.webauthnVerifierAddress,
          AgentDefaults.webauthnVerifierAddress);
      expect(config.ed25519VerifierAddress, AgentDefaults.ed25519VerifierAddress);
      expect(config.relayerUrl, AgentDefaults.relayerUrl);
      expect(config.tokenContractId, AgentDefaults.nativeTokenContract);
      expect(config.tokenDecimals, 7);
      expect(config.coordinationBaseUrl, AgentDefaults.coordinationBaseUrl);
      expect(config.coordinationToken, AgentDefaults.coordinationToken);
      // Per-run identity values have no default.
      expect(config.smartAccountContractId, isNull);
      expect(config.isCompleteForLiveRun, isFalse);
    });

    test('toString redacts the seed and coordination token', () {
      final config = AgentConfig(
        agentSecretSeed: KeyPair.random().secretSeed,
        coordinationToken: 'super-secret',
      );
      final text = config.toString();
      expect(text, contains('agentSecretSeed: ***'));
      expect(text, contains('coordinationToken: ***'));
      expect(text, isNot(contains('super-secret')));
    });
  });

  group('resolve precedence', () {
    test('empty inputs fall back to defaults', () {
      final config = AgentConfig.resolve(env: const <String, String>{});
      expect(config.rpcUrl, AgentDefaults.rpcUrl);
      expect(config.smartAccountContractId, isNull);
    });

    test('environment overrides defaults', () {
      final config = AgentConfig.resolve(
        env: const <String, String>{
          'AGENT_RPC_URL': 'https://env.example/rpc',
          'AGENT_SMART_ACCOUNT': 'CENV',
          'AGENT_AMOUNT': '42',
          'AGENT_POLL_INTERVAL_SECONDS': '7',
        },
      );
      expect(config.rpcUrl, 'https://env.example/rpc');
      expect(config.smartAccountContractId, 'CENV');
      expect(config.amount, '42');
      expect(config.pollInterval, const Duration(seconds: 7));
    });

    test('args override environment', () {
      final config = AgentConfig.resolve(
        args: const <String>['--rpc-url=https://arg.example/rpc', '--amount', '9'],
        env: const <String, String>{
          'AGENT_RPC_URL': 'https://env.example/rpc',
          'AGENT_AMOUNT': '42',
        },
      );
      expect(config.rpcUrl, 'https://arg.example/rpc');
      expect(config.amount, '9');
    });

    test('json file sits below env and args but above defaults', () async {
      final dir = await Directory.systemTemp.createTemp('agent_cfg');
      addTearDown(() async => dir.delete(recursive: true));
      final file = File('${dir.path}/agent.json');
      await file.writeAsString(jsonEncode(<String, dynamic>{
        'rpcUrl': 'https://json.example/rpc',
        'tokenContractId': 'CJSONTOKEN',
        'amount': '100',
      }));

      final config = AgentConfig.resolve(
        args: const <String>['--amount=5'],
        env: const <String, String>{},
        jsonPath: file.path,
      );
      // json wins over default for rpcUrl and token...
      expect(config.rpcUrl, 'https://json.example/rpc');
      expect(config.tokenContractId, 'CJSONTOKEN');
      // ...but the CLI arg wins over json for amount.
      expect(config.amount, '5');
    });

    test('non-integer poll interval is rejected', () {
      expect(
        () => AgentConfig.resolve(
          env: const <String, String>{'AGENT_POLL_INTERVAL_SECONDS': 'soon'},
        ),
        throwsA(isA<AgentConfigException>()),
      );
    });

    test('missing config file path is rejected', () {
      expect(
        () => AgentConfig.resolve(
          env: const <String, String>{},
          jsonPath: '/no/such/file.json',
        ),
        throwsA(isA<AgentConfigException>()),
      );
    });
  });

  group('validateForLiveRun', () {
    AgentConfig completeConfig() => AgentConfig(
          smartAccountContractId: AgentDefaults.nativeTokenContract,
          credentialId: 'demo-credential',
          agentSecretSeed: KeyPair.random().secretSeed,
          destinationAddress: KeyPair.random().accountId,
        );

    test('passes for a complete configuration', () {
      expect(completeConfig().isCompleteForLiveRun, isTrue);
      expect(completeConfig().validateForLiveRun, returnsNormally);
    });

    test('requires the smart account', () {
      expect(
        completeConfig().copyWith(smartAccountContractId: '').validateForLiveRun,
        throwsA(isA<AgentConfigException>()),
      );
    });

    test('rejects an invalid agent seed', () {
      final bad = AgentConfig(
        smartAccountContractId: AgentDefaults.nativeTokenContract,
        credentialId: 'demo-credential',
        agentSecretSeed: 'not-a-seed',
        destinationAddress: KeyPair.random().accountId,
      );
      expect(bad.validateForLiveRun, throwsA(isA<AgentConfigException>()));
    });

    test('rejects an invalid destination address', () {
      final bad = completeConfig().copyWith(destinationAddress: 'nonsense');
      expect(bad.validateForLiveRun, throwsA(isA<AgentConfigException>()));
    });

    test('accepts a contract destination address', () {
      final ok = completeConfig()
          .copyWith(destinationAddress: AgentDefaults.nativeTokenContract);
      expect(ok.validateForLiveRun, returnsNormally);
    });
  });
}
