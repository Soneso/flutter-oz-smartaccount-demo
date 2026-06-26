/// Unit tests for [DelegateToAgentFlow].
///
/// Asserts that the flow composes the CORRECT single `addContextRule` call:
/// 1. CallContract(token) context type.
/// 2. The Ed25519 external signer carrying the pasted agent key, under the
///    configured verifier.
/// 3. The spending-limit policy with the cap converted to base units.
/// 4. The validUntil bound resolved from the current ledger.
///
/// Plus: bad-key validation, amount/ledger conversion, default policy address,
/// failure surfacing, and the single-signer (selectedSigners empty) path.
/// Everything is mocked — no testnet, no network.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_account_demo/config/demo_config.dart' as config;
import 'package:smart_account_demo/flows/context_rule_flow.dart'
    show ledgersPerDay, ledgersPerHour;
import 'package:smart_account_demo/flows/delegate_to_agent_flow.dart';
import 'package:smart_account_demo/util/policy_type.dart' show PolicyType;
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import 'context_rule_test_support.dart';

// ---------------------------------------------------------------------------
// Fixtures / helpers
// ---------------------------------------------------------------------------

const String _ed25519Verifier =
    'CAW2Z46INPO5VIJEILMYSSEOLBVJIIII5GOE3TN5EUURSRM2FJCF7AJ6';

/// The testnet XLM Stellar Asset Contract (a real demo token contract from
/// the demo config), used as the scoped token in the composition tests.
const String _tokenContract =
    'CDLZFC3SYJYDZT7K67VZ75HPJVIEUVNIXF47ZG2FB2RMQQVU2HHGCYSC';

/// The spending-limit policy address from the demo configuration.
String get _spendingLimitPolicy => config.knownPolicies
    .firstWhere((p) => p.type == PolicyType.spendingLimit)
    .address;

final class _FlowHarness {
  _FlowHarness({
    required this.flow,
    required this.manager,
    required this.environment,
    required this.agentKeypair,
  });

  final DelegateToAgentFlow flow;
  final MockContextRuleFlowManager manager;
  final MockBuilderEnvironment environment;
  final KeyPair agentKeypair;

  /// The agent's raw 32-byte Ed25519 public key as 64-character hex — the form
  /// the Delegate-to-agent screen accepts.
  String get agentPublicKey =>
      Util.bytesToHex(Uint8List.fromList(agentKeypair.publicKey));
  Uint8List get agentPublicKeyBytes =>
      Uint8List.fromList(agentKeypair.publicKey);
}

_FlowHarness _makeHarness({
  int currentLedger = 50000,
  KeyPair? agentKeypair,
}) {
  final manager = MockContextRuleFlowManager()
    ..addResult = successResult(hash: 'delegationhash');
  // MockBuilderEnvironment defaults its verifier to [_ed25519Verifier]; the
  // assertions below pin that value explicitly.
  final environment = MockBuilderEnvironment(currentLedger: currentLedger);
  final deps = ContextRuleFixtures.makeFlowWithDeps(
    manager: manager,
    environment: environment,
  );
  final flow = DelegateToAgentFlow(
    contextRuleFlow: deps.flow,
    activityLog: deps.activityLog,
  );
  return _FlowHarness(
    flow: flow,
    manager: manager,
    environment: environment,
    agentKeypair: agentKeypair ?? KeyPair.random(),
  );
}

void main() {
  // -------------------------------------------------------------------------
  // validateAgentPublicKey / validateAmount
  // -------------------------------------------------------------------------

  group('DelegateToAgentFlow.validateAgentPublicKey', () {
    test('empty input is not flagged', () {
      final h = _makeHarness();
      expect(h.flow.validateAgentPublicKey(''), isNull);
      expect(h.flow.validateAgentPublicKey('   '), isNull);
    });

    test('valid 64-hex key passes', () {
      final h = _makeHarness();
      expect(h.flow.validateAgentPublicKey(h.agentPublicKey), isNull);
      // Upper-case hex is accepted (normalised to lower-case).
      expect(
        h.flow.validateAgentPublicKey(h.agentPublicKey.toUpperCase()),
        isNull,
      );
    });

    test('malformed key returns an error', () {
      final h = _makeHarness();
      // Too short and non-hex.
      expect(h.flow.validateAgentPublicKey('not-a-key'), isNotNull);
      // A C-address is not 64 hex characters.
      expect(h.flow.validateAgentPublicKey(_tokenContract), isNotNull);
      // A 64-length string with non-hex characters is rejected.
      expect(h.flow.validateAgentPublicKey('z' * 64), isNotNull);
      // A 63-character hex string is the wrong length.
      expect(h.flow.validateAgentPublicKey('a' * 63), isNotNull);
    });
  });

  group('DelegateToAgentFlow.validateAmount', () {
    test('empty is not flagged; valid passes; bad values rejected', () {
      expect(DelegateToAgentFlow.validateAmount(''), isNull);
      expect(DelegateToAgentFlow.validateAmount('100.0'), isNull);
      expect(DelegateToAgentFlow.validateAmount('1e3'), isNotNull);
      expect(DelegateToAgentFlow.validateAmount('abc'), isNotNull);
      expect(DelegateToAgentFlow.validateAmount('0'), isNotNull);
      expect(DelegateToAgentFlow.validateAmount('-5'), isNotNull);
    });
  });

  // -------------------------------------------------------------------------
  // spendingLimitPolicyAddress
  // -------------------------------------------------------------------------

  test('spendingLimitPolicyAddress matches the demo config policy', () {
    final h = _makeHarness();
    expect(h.flow.spendingLimitPolicyAddress, _spendingLimitPolicy);
    expect(
      h.flow.spendingLimitPolicyAddress,
      'CBQE7L3UNP5IR4I7IBKLS7NV256WHR5TTH26HTMUIK7WXJC6J64RSE2L',
    );
  });

  // -------------------------------------------------------------------------
  // delegateToAgent — happy path composition
  // -------------------------------------------------------------------------

  group('DelegateToAgentFlow.delegateToAgent composes addContextRule', () {
    test('CallContract scope + Ed25519 signer + spending-limit + validUntil',
        () async {
      final h = _makeHarness();

      final result = await h.flow.delegateToAgent(
        agentPublicKey: h.agentPublicKey,
        tokenContract: _tokenContract,
        amount: '100',
        periodLedgers: ledgersPerDay,
        validUntilOffsetLedgers: ledgersPerDay,
        tokenDecimals: 7,
      );

      expect(result.success, isTrue);
      expect(result.hash, 'delegationhash');
      expect(h.manager.addCallCount, 1);

      // 1. CallContract(token) context type.
      final ctx = h.manager.lastAddedContextType;
      expect(ctx, isA<OZContextRuleTypeCallContract>());
      expect((ctx! as OZContextRuleTypeCallContract).contractAddress,
          _tokenContract);

      // 2. Single Ed25519 external signer carrying the pasted key.
      final signers = h.manager.lastAddedSigners!;
      expect(signers, hasLength(1));
      final signer = signers.single;
      expect(signer, isA<OZExternalSigner>());
      final ext = signer as OZExternalSigner;
      expect(ext.verifierAddress, _ed25519Verifier);
      // Ed25519 keyData is exactly the 32-byte public key (no credential id).
      expect(ext.keyData, equals(h.agentPublicKeyBytes));
      expect(ext.keyData, hasLength(32));

      // 3. Spending-limit policy with the cap in base units.
      final policies = h.manager.lastAddedPolicies!;
      expect(policies.keys, [_spendingLimitPolicy]);
      final policy = policies[_spendingLimitPolicy];
      expect(policy, isA<OZSpendingLimitPolicyParams>());
      final sl = policy! as OZSpendingLimitPolicyParams;
      // 100 * 10^7 = 1_000_000_000.
      expect(sl.spendingLimit, BigInt.from(1000000000));
      expect(sl.periodLedgers, ledgersPerDay);

      // 4. validUntil = currentLedger + offset.
      expect(h.manager.lastAddedValidUntil, 50000 + ledgersPerDay);

      // Single-signer path: selectedSigners empty, submitted via passkey.
      expect(h.manager.lastAddedSelectedSigners, isEmpty);
      expect(h.manager.lastAddedName, defaultDelegationRuleName);
    });

    test('summary captures the authorised rule for the confirmation', () async {
      final h = _makeHarness(currentLedger: 12345);

      final result = await h.flow.delegateToAgent(
        agentPublicKey: h.agentPublicKey,
        tokenContract: _tokenContract,
        amount: '50',
        periodLedgers: ledgersPerHour,
        validUntilOffsetLedgers: ledgersPerDay,
        tokenDecimals: 7,
      );

      expect(result.success, isTrue);
      final summary = result.summary!;
      expect(summary.agentPublicKey, h.agentPublicKey);
      expect(summary.tokenContract, _tokenContract);
      expect(summary.amount, '50');
      expect(summary.periodLedgers, ledgersPerHour);
      expect(summary.validUntilLedger, 12345 + ledgersPerDay);
      expect(summary.ruleName, defaultDelegationRuleName);
      expect(summary.spendingLimitPolicyAddress, _spendingLimitPolicy);
      expect(summary.verifierAddress, _ed25519Verifier);
    });

    test('fractional amount converts to base units at the token scale',
        () async {
      final h = _makeHarness();

      await h.flow.delegateToAgent(
        agentPublicKey: h.agentPublicKey,
        tokenContract: _tokenContract,
        amount: '1.5',
        periodLedgers: ledgersPerDay,
        validUntilOffsetLedgers: ledgersPerDay,
        tokenDecimals: 7,
      );

      final policy = h.manager.lastAddedPolicies![_spendingLimitPolicy]!
          as OZSpendingLimitPolicyParams;
      // 1.5 * 10^7 = 15_000_000.
      expect(policy.spendingLimit, BigInt.from(15000000));
    });

    test('zero expiry offset produces no validUntil and no ledger read',
        () async {
      final h = _makeHarness();

      await h.flow.delegateToAgent(
        agentPublicKey: h.agentPublicKey,
        tokenContract: _tokenContract,
        amount: '10',
        periodLedgers: ledgersPerDay,
        validUntilOffsetLedgers: 0,
        tokenDecimals: 7,
      );

      expect(h.manager.lastAddedValidUntil, isNull);
      expect(h.environment.getCurrentLedgerCallCount, 0);
    });
  });

  // -------------------------------------------------------------------------
  // delegateToAgent — validation + failure paths
  // -------------------------------------------------------------------------

  group('DelegateToAgentFlow.delegateToAgent guards', () {
    test('rejects a malformed agent key without calling the SDK', () async {
      final h = _makeHarness();

      final result = await h.flow.delegateToAgent(
        agentPublicKey: 'not-a-valid-key',
        tokenContract: _tokenContract,
        amount: '10',
        periodLedgers: ledgersPerDay,
        validUntilOffsetLedgers: ledgersPerDay,
        tokenDecimals: 7,
      );

      expect(result.success, isFalse);
      expect(result.error, contains('hex'));
      expect(h.manager.addCallCount, 0);
    });

    test('surfaces an on-chain failure result as a sanitised error', () async {
      final h = _makeHarness();
      h.manager.addResult =
          failureResult(errorMessage: 'simulation rejected the rule');

      final result = await h.flow.delegateToAgent(
        agentPublicKey: h.agentPublicKey,
        tokenContract: _tokenContract,
        amount: '10',
        periodLedgers: ledgersPerDay,
        validUntilOffsetLedgers: ledgersPerDay,
        tokenDecimals: 7,
      );

      expect(result.success, isFalse);
      expect(result.error, contains('simulation rejected the rule'));
      expect(result.summary, isNull);
    });

    test('invalid spending-limit amount fails before submission', () async {
      final h = _makeHarness();

      final result = await h.flow.delegateToAgent(
        agentPublicKey: h.agentPublicKey,
        tokenContract: _tokenContract,
        amount: '0',
        periodLedgers: ledgersPerDay,
        validUntilOffsetLedgers: ledgersPerDay,
        tokenDecimals: 7,
      );

      expect(result.success, isFalse);
      expect(h.manager.addCallCount, 0);
    });
  });

  // -------------------------------------------------------------------------
  // resolveTokenDecimals
  // -------------------------------------------------------------------------

  group('DelegateToAgentFlow.resolveTokenDecimals', () {
    test('native token resolves without a fetch', () async {
      final h = _makeHarness();
      final decimals =
          await h.flow.resolveTokenDecimals(config.nativeTokenContract);
      expect(decimals, 7);
      expect(h.environment.fetchTokenDecimalsCallCount, 0);
    });

    test('custom (non-native) token fetches the on-chain decimals', () async {
      final h = _makeHarness();
      h.environment.tokenDecimals = 6;
      // fixtureContractId is a generic C-address, not the native SAC, so the
      // flow resolves decimals via an on-chain fetch.
      final decimals = await h.flow.resolveTokenDecimals(fixtureContractId);
      expect(decimals, 6);
      expect(h.environment.fetchTokenDecimalsCallCount, 1);
      expect(h.environment.lastFetchTokenDecimalsContract, fixtureContractId);
    });
  });
}
