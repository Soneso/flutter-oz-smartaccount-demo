/// Shared test support for [ContextRuleFlow] tests.
///
/// Provides mock implementations of [ContextRuleFlowManagerType], fixture
/// builders for [OZParsedContextRule], and helpers for assembling test
/// dependencies.
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_account_demo/flows/context_rule_flow.dart';
import 'package:smart_account_demo/flows/signer_info.dart'
    show SignerInfo, SignerKind;
import 'package:smart_account_demo/state/activity_log_state.dart';
import 'package:smart_account_demo/state/demo_state.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import 'transfer_test_support.dart' show FakeOZExternalSignerManager;

// ---------------------------------------------------------------------------
// MockContextRuleFlowManager
// ---------------------------------------------------------------------------

/// Configurable mock for [ContextRuleFlowManagerType].
final class MockContextRuleFlowManager
    implements ContextRuleFlowManagerType {
  List<OZParsedContextRule> rules = const <OZParsedContextRule>[];
  Object? listError;
  Object? removeError;
  OZTransactionResult? removeResult;

  int listCallCount = 0;
  int removeCallCount = 0;
  int? lastRemovedId;
  List<OZSelectedSigner>? lastSelectedSigners;

  @override
  Future<List<OZParsedContextRule>> listContextRules() async {
    listCallCount++;
    final e = listError;
    if (e != null) throw e;
    return rules;
  }

  @override
  Future<OZTransactionResult> removeContextRule({
    required int id,
    List<OZSelectedSigner> selectedSigners = const <OZSelectedSigner>[],
  }) async {
    removeCallCount++;
    lastRemovedId = id;
    lastSelectedSigners = selectedSigners;
    final e = removeError;
    if (e != null) throw e;
    final r = removeResult;
    if (r == null) {
      throw StateError(
        'MockContextRuleFlowManager: neither removeResult nor removeError '
        'configured.',
      );
    }
    return r;
  }

  // ---- addContextRule mock state ----

  /// Configured to throw before returning addResult when non-null.
  Object? addError;

  /// Configured to return as the addContextRule result. Required when
  /// addError is null.
  OZTransactionResult? addResult;

  int addCallCount = 0;
  OZContextRuleType? lastAddedContextType;
  String? lastAddedName;
  int? lastAddedValidUntil;
  List<OZSmartAccountSigner>? lastAddedSigners;
  Map<String, OZPolicyInstallParams>? lastAddedPolicies;
  List<OZSelectedSigner>? lastAddedSelectedSigners;

  @override
  Future<OZTransactionResult> addContextRule({
    required OZContextRuleType contextType,
    required String name,
    int? validUntil,
    required List<OZSmartAccountSigner> signers,
    Map<String, OZPolicyInstallParams> policies =
        const <String, OZPolicyInstallParams>{},
    List<OZSelectedSigner> selectedSigners = const <OZSelectedSigner>[],
  }) async {
    addCallCount++;
    lastAddedContextType = contextType;
    lastAddedName = name;
    lastAddedValidUntil = validUntil;
    lastAddedSigners = signers;
    lastAddedPolicies = policies;
    lastAddedSelectedSigners = selectedSigners;

    final e = addError;
    if (e != null) throw e;
    final r = addResult;
    if (r == null) {
      throw StateError(
        'MockContextRuleFlowManager: neither addResult nor addError '
        'configured.',
      );
    }
    return r;
  }

  // ---- Per-op edit hooks ---------------------------------------------------

  /// Map from a textual operation name to either a [OZTransactionResult] or an
  /// [Object] to throw.
  ///
  /// Operation names: `updateName`, `removeSigner`, `addDelegated`,
  /// `addEd25519`, `addPasskey`, `removePolicy`, `addPolicy`,
  /// `updateValidUntil`, `setPolicyThreshold`.
  ///
  /// Tests configure either an [editResult] or an [editError] per
  /// operation; when neither is set, the per-op method throws a
  /// [StateError] so configuration gaps surface loudly.
  final Map<String, OZTransactionResult> editResults = <String, OZTransactionResult>{};
  final Map<String, Object> editErrors = <String, Object>{};

  /// Per-operation call counters keyed by the same operation names as
  /// [editResults].
  final Map<String, int> editCallCounts = <String, int>{};

  /// The ordered list of operation invocations as they occurred. Each entry
  /// is a `(op, args)` record where `args` is a map of the call's arguments
  /// for assertion convenience.
  final List<EditCallRecord> editCalls = <EditCallRecord>[];

  Future<OZTransactionResult> _runEditOp(
    String op,
    Map<String, Object?> args,
  ) async {
    editCallCounts[op] = (editCallCounts[op] ?? 0) + 1;
    editCalls.add(EditCallRecord(op: op, args: args));
    final e = editErrors[op];
    if (e != null) throw e;
    final r = editResults[op];
    if (r != null) return r;
    throw StateError(
      'MockContextRuleFlowManager: no editResult or editError configured '
      'for operation: $op',
    );
  }

  @override
  Future<OZTransactionResult> updateContextRuleName({
    required int ruleId,
    required String name,
    List<OZSelectedSigner> selectedSigners = const <OZSelectedSigner>[],
  }) =>
      _runEditOp('updateName', <String, Object?>{
        'ruleId': ruleId,
        'name': name,
        'selectedSigners': selectedSigners,
      });

  @override
  Future<OZTransactionResult> removeSignerFromRule({
    required int ruleId,
    required int signerId,
    List<OZSelectedSigner> selectedSigners = const <OZSelectedSigner>[],
  }) =>
      _runEditOp('removeSigner', <String, Object?>{
        'ruleId': ruleId,
        'signerId': signerId,
        'selectedSigners': selectedSigners,
      });

  @override
  Future<OZTransactionResult> addDelegatedSignerToRule({
    required int ruleId,
    required String address,
    List<OZSelectedSigner> selectedSigners = const <OZSelectedSigner>[],
  }) =>
      _runEditOp('addDelegated', <String, Object?>{
        'ruleId': ruleId,
        'address': address,
        'selectedSigners': selectedSigners,
      });

  @override
  Future<OZTransactionResult> addEd25519SignerToRule({
    required int ruleId,
    required Uint8List publicKey,
    List<OZSelectedSigner> selectedSigners = const <OZSelectedSigner>[],
  }) =>
      _runEditOp('addEd25519', <String, Object?>{
        'ruleId': ruleId,
        'publicKey': publicKey,
        'selectedSigners': selectedSigners,
      });

  @override
  Future<OZTransactionResult> addPasskeySignerToRule({
    required int ruleId,
    required Uint8List publicKey,
    required Uint8List credentialId,
    List<OZSelectedSigner> selectedSigners = const <OZSelectedSigner>[],
  }) =>
      _runEditOp('addPasskey', <String, Object?>{
        'ruleId': ruleId,
        'publicKey': publicKey,
        'credentialId': credentialId,
        'selectedSigners': selectedSigners,
      });

  @override
  Future<OZTransactionResult> removePolicyFromRule({
    required int ruleId,
    required int policyId,
    List<OZSelectedSigner> selectedSigners = const <OZSelectedSigner>[],
  }) =>
      _runEditOp('removePolicy', <String, Object?>{
        'ruleId': ruleId,
        'policyId': policyId,
        'selectedSigners': selectedSigners,
      });

  @override
  Future<OZTransactionResult> addSimpleThresholdToRule({
    required int ruleId,
    required String policyAddress,
    required int threshold,
    List<OZSelectedSigner> selectedSigners = const <OZSelectedSigner>[],
  }) =>
      _runEditOp('addSimpleThreshold', <String, Object?>{
        'ruleId': ruleId,
        'policyAddress': policyAddress,
        'threshold': threshold,
        'selectedSigners': selectedSigners,
      });

  @override
  Future<OZTransactionResult> addWeightedThresholdToRule({
    required int ruleId,
    required String policyAddress,
    required List<PolicyWeightedEntry> entries,
    required int threshold,
    List<OZSelectedSigner> selectedSigners = const <OZSelectedSigner>[],
  }) =>
      _runEditOp('addWeightedThreshold', <String, Object?>{
        'ruleId': ruleId,
        'policyAddress': policyAddress,
        'entries': entries,
        'threshold': threshold,
        'selectedSigners': selectedSigners,
      });

  @override
  Future<OZTransactionResult> addSpendingLimitToRule({
    required int ruleId,
    required String policyAddress,
    required String amount,
    required int decimals,
    required int periodLedgers,
    List<OZSelectedSigner> selectedSigners = const <OZSelectedSigner>[],
  }) =>
      _runEditOp('addSpendingLimit', <String, Object?>{
        'ruleId': ruleId,
        'policyAddress': policyAddress,
        'amount': amount,
        'decimals': decimals,
        'periodLedgers': periodLedgers,
        'selectedSigners': selectedSigners,
      });

  @override
  Future<OZTransactionResult> updateContextRuleValidUntil({
    required int ruleId,
    int? validUntil,
    List<OZSelectedSigner> selectedSigners = const <OZSelectedSigner>[],
  }) =>
      _runEditOp('updateValidUntil', <String, Object?>{
        'ruleId': ruleId,
        'validUntil': validUntil,
        'selectedSigners': selectedSigners,
      });

  @override
  Future<OZTransactionResult> setPolicyThreshold({
    required int ruleId,
    required String policyAddress,
    required int newThreshold,
    List<OZSelectedSigner> selectedSigners = const <OZSelectedSigner>[],
  }) =>
      _runEditOp('setPolicyThreshold', <String, Object?>{
        'ruleId': ruleId,
        'policyAddress': policyAddress,
        'newThreshold': newThreshold,
        'selectedSigners': selectedSigners,
      });
}

/// Record of a single per-op edit call captured by [MockContextRuleFlowManager].
final class EditCallRecord {
  /// Constructs a captured call.
  const EditCallRecord({required this.op, required this.args});

  /// Operation name (e.g. `updateName`, `addPasskey`).
  final String op;

  /// Arguments passed to the call, keyed by parameter name.
  final Map<String, Object?> args;
}

// ---------------------------------------------------------------------------
// MockBuilderEnvironment
// ---------------------------------------------------------------------------

/// Configurable mock for [ContextRuleBuilderEnvironmentType].
final class MockBuilderEnvironment
    implements ContextRuleBuilderEnvironmentType {
  MockBuilderEnvironment({
    this.webauthnVerifierAddress =
        'CB26VN37RCVNTHJZDEPK6IRO2MMTS3Z2IEO5JD5BINY2OOJ5KKJG7NKY',
    this.ed25519VerifierAddress =
        'CAW2Z46INPO5VIJEILMYSSEOLBVJIIII5GOE3TN5EUURSRM2FJCF7AJ6',
    this.webauthnProvider,
    this.currentLedger = 50000,
    this.getLedgerError,
  });

  @override
  String webauthnVerifierAddress;

  @override
  String ed25519VerifierAddress;

  @override
  WebAuthnProvider? webauthnProvider;

  int currentLedger;
  Object? getLedgerError;
  int getCurrentLedgerCallCount = 0;

  @override
  Future<int> getCurrentLedger() async {
    getCurrentLedgerCallCount++;
    final e = getLedgerError;
    if (e != null) throw e;
    return currentLedger;
  }

  /// Decimals returned by [fetchTokenDecimals] for a custom guarded token.
  int tokenDecimals = 7;

  /// Optional error to throw on the next [fetchTokenDecimals] call.
  Object? fetchTokenDecimalsError;

  int fetchTokenDecimalsCallCount = 0;
  String? lastFetchTokenDecimalsContract;

  @override
  Future<int> fetchTokenDecimals(String tokenContract) async {
    fetchTokenDecimalsCallCount++;
    lastFetchTokenDecimalsContract = tokenContract;
    final e = fetchTokenDecimalsError;
    if (e != null) throw e;
    return tokenDecimals;
  }

  /// Map from `policyAddress` to the [XdrSCVal] this mock returns for a
  /// `readContractDataValue` call against that address. Entries default to
  /// `null` when absent (no entry stored).
  final Map<String, XdrSCVal?> contractDataValues = <String, XdrSCVal?>{};

  /// Optional error to throw on the next [readContractDataValue] call.
  Object? readContractDataValueError;

  int readContractDataValueCallCount = 0;
  String? lastReadContractAddress;
  XdrSCVal? lastReadStorageKey;

  @override
  Future<XdrSCVal?> readContractDataValue({
    required String contractAddress,
    required XdrSCVal storageKey,
  }) async {
    readContractDataValueCallCount++;
    lastReadContractAddress = contractAddress;
    lastReadStorageKey = storageKey;
    final e = readContractDataValueError;
    if (e != null) throw e;
    if (!contractDataValues.containsKey(contractAddress)) return null;
    return contractDataValues[contractAddress];
  }
}

// ---------------------------------------------------------------------------
// MockWebAuthnProvider
// ---------------------------------------------------------------------------

/// Minimal [WebAuthnProvider] for builder-flow tests. Only the [register]
/// path is exercised; [authenticate] throws to surface unexpected calls.
final class MockWebAuthnProvider implements WebAuthnProvider {
  MockWebAuthnProvider({
    this.registerResult,
    this.registerError,
  });

  WebAuthnRegistrationResult? registerResult;
  Object? registerError;
  int registerCallCount = 0;
  String? lastRegisterUserName;

  @override
  Future<WebAuthnRegistrationResult> register({
    required Uint8List challenge,
    required Uint8List userId,
    required String userName,
  }) async {
    registerCallCount++;
    lastRegisterUserName = userName;
    final e = registerError;
    if (e != null) throw e;
    final r = registerResult;
    if (r == null) {
      throw StateError(
        'MockWebAuthnProvider: neither registerResult nor registerError '
        'configured.',
      );
    }
    return r;
  }

  @override
  Future<WebAuthnAuthenticationResult> authenticate({
    required Uint8List challenge,
    List<WebAuthnAllowCredential>? allowCredentials,
  }) async {
    throw UnimplementedError(
      'MockWebAuthnProvider.authenticate is not used in builder tests.',
    );
  }
}

// ---------------------------------------------------------------------------
// Error stubs
// ---------------------------------------------------------------------------

/// Simulates a WebAuthn passkey cancellation.
WebAuthnCancelled makeCancelledError() =>
    const WebAuthnCancelled(message: 'User cancelled the passkey ceremony.');

/// Simulates a generic network error.
final class MockNetworkError implements Exception {
  @override
  String toString() => 'Network unreachable: connection timeout.';
}

/// Simulates a generic on-chain failure.
final class MockRuleRemovalError implements Exception {
  @override
  String toString() => 'Context rule removal failed on-chain.';
}

// ---------------------------------------------------------------------------
// Fixture constants
// ---------------------------------------------------------------------------

/// Contract address fixture (valid C-address).
const String fixtureContractId =
    'CAAQEAYEAUDAOCAJBIFQYDIOB4IBCEQTCQKRMFYYDENBWHA5DYPSBFLM';

/// Credential ID fixture.
const String fixtureCredentialId = 'dGVzdC1jcmVkZW50aWFsLWlkLWZpeHR1cmU';

/// Delegated signer address fixture 1.
const String fixtureDelegatedAddress1 =
    'GCKE5G7SSH4O4QBJWS32UY3C2MOMTULMSPMJD6ZJ426FOHXH5YCUNMPM';

/// Delegated signer address fixture 2.
const String fixtureDelegatedAddress2 =
    'GBBD47IF6LWK7P7MDEVSCWR7DPUWV3NY3DTQEVFL4NAT4AQH3ZLLFLA5';

/// A successful [OZTransactionResult].
OZTransactionResult successResult({String? hash}) => OZTransactionResult(
      success: true,
      hash: hash ?? 'deadbeef' * 8,
    );

/// A failed [OZTransactionResult].
OZTransactionResult failureResult({String? errorMessage}) => OZTransactionResult(
      success: false,
      error: errorMessage ?? 'Rule removal failed on-chain.',
    );

// ---------------------------------------------------------------------------
// OZParsedContextRule fixture builders
// ---------------------------------------------------------------------------

/// Builds a [OZParsedContextRule] with defaults.
OZParsedContextRule makeRule({
  int id = 1,
  OZContextRuleType? contextType,
  String name = 'test-rule',
  List<OZSmartAccountSigner>? signers,
  List<String>? policies,
  int? validUntil,
}) {
  return OZParsedContextRule(
    id: id,
    contextType: contextType ?? const OZContextRuleTypeDefault(),
    name: name,
    signers: signers ?? [OZDelegatedSigner(fixtureDelegatedAddress1)],
    signerIds: [id],
    policies: policies ?? const <String>[],
    policyIds: const [],
    validUntil: validUntil,
  );
}

/// Builds a rule with zero signers (policy-only).
OZParsedContextRule makePolicyOnlyRule({
  int id = 10,
  String name = 'policy-only',
  List<String>? policies,
}) {
  return OZParsedContextRule(
    id: id,
    contextType: const OZContextRuleTypeDefault(),
    name: name,
    signers: const [],
    signerIds: const [],
    policies: policies ?? [fixtureContractId],
    policyIds: const [1],
  );
}

/// Builds a rule with zero policies (signer-only).
OZParsedContextRule makeSignerOnlyRule({
  int id = 20,
  String name = 'signer-only',
}) {
  return OZParsedContextRule(
    id: id,
    contextType: const OZContextRuleTypeDefault(),
    name: name,
    signers: [OZDelegatedSigner(fixtureDelegatedAddress1)],
    signerIds: const [1],
    policies: const [],
    policyIds: const [],
  );
}

/// Builds a rule with an expiry ledger.
OZParsedContextRule makeRuleWithExpiry({
  int id = 30,
  String name = 'expiring-rule',
  int validUntil = 99999,
}) {
  return OZParsedContextRule(
    id: id,
    contextType: const OZContextRuleTypeDefault(),
    name: name,
    signers: [OZDelegatedSigner(fixtureDelegatedAddress1)],
    signerIds: const [1],
    policies: const [],
    policyIds: const [],
    validUntil: validUntil,
  );
}

/// Builds a [CallContract] context rule.
OZParsedContextRule makeCallContractRule({
  int id = 40,
  String name = 'call-contract-rule',
  String? contractAddress,
}) {
  return OZParsedContextRule(
    id: id,
    contextType:
        OZContextRuleTypeCallContract(contractAddress ?? fixtureContractId),
    name: name,
    signers: [OZDelegatedSigner(fixtureDelegatedAddress1)],
    signerIds: const [1],
    policies: const [],
    policyIds: const [],
  );
}

// ---------------------------------------------------------------------------
// ContextRuleFlowTestDeps
// ---------------------------------------------------------------------------

/// All dependencies for a [ContextRuleFlow] test.
final class ContextRuleFlowTestDeps {
  const ContextRuleFlowTestDeps({
    required this.flow,
    required this.demoState,
    required this.activityLog,
    required this.manager,
    required this.container,
    this.environment,
  });

  final ContextRuleFlow flow;
  final DemoStateNotifier demoState;
  final ActivityLogNotifier activityLog;
  final MockContextRuleFlowManager manager;
  final ProviderContainer container;
  final MockBuilderEnvironment? environment;

  WalletConnectionState get state => demoState.currentState;
  List<LogEntry> get logEntries => container.read(activityLogProvider);
}

// ---------------------------------------------------------------------------
// ContextRuleFixtures
// ---------------------------------------------------------------------------

/// Shared test-fixture builders for context-rule flow tests.
final class ContextRuleFixtures {
  ContextRuleFixtures._();

  /// Builds a [ContextRuleFlow] with minimal dependencies for unit tests.
  static ContextRuleFlowTestDeps makeFlowWithDeps({
    MockContextRuleFlowManager? manager,
    String? contractId,
    String? credentialId,
    bool isConnected = true,
    bool isDeployed = true,
    MockBuilderEnvironment? environment,
    Random? secureRandom,
  }) {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final demoState = container.read(demoStateProvider.notifier);
    final activityLog = container.read(activityLogProvider.notifier);

    if (isConnected) {
      demoState.setConnected(
        contractId: contractId ?? fixtureContractId,
        credentialId: credentialId ?? fixtureCredentialId,
        isDeployed: isDeployed,
      );
    }

    final mgr = manager ?? MockContextRuleFlowManager();

    final flow = ContextRuleFlow(
      demoState: demoState,
      activityLog: activityLog,
      contextRuleManager: mgr,
      environment: environment,
      secureRandom: secureRandom,
    );

    return ContextRuleFlowTestDeps(
      flow: flow,
      demoState: demoState,
      activityLog: activityLog,
      manager: mgr,
      container: container,
      environment: environment,
    );
  }

  /// Returns a deterministic 65-byte uncompressed secp256r1 public key
  /// suitable for WebAuthn fixtures.
  static Uint8List makeWebAuthnPublicKey({int seed = 0xAB}) {
    final bytes = Uint8List(65);
    bytes[0] = 0x04;
    for (var i = 1; i < 65; i++) {
      bytes[i] = (seed + i) & 0xFF;
    }
    return bytes;
  }

  /// Returns a deterministic credential-ID byte sequence.
  static Uint8List makeCredentialIdBytes({int length = 20, int seed = 0x10}) {
    final bytes = Uint8List(length);
    for (var i = 0; i < length; i++) {
      bytes[i] = (seed + i) & 0xFF;
    }
    return bytes;
  }

  /// Returns a [SignerInfo] that represents the connected passkey.
  static SignerInfo connectedPasskeySigner() => const SignerInfo(
        displayLabel: 'Connected Passkey',
        address: '',
        kind: SignerKind.passkey,
        isConnectedCredential: true,
        credentialId: fixtureCredentialId,
      );

  /// Returns a [SignerInfo] that represents a delegated G-address signer.
  static SignerInfo delegatedSigner({String? address}) => SignerInfo(
        displayLabel: address ?? fixtureDelegatedAddress1,
        address: address ?? fixtureDelegatedAddress1,
        kind: SignerKind.delegated,
        isConnectedCredential: false,
      );

  /// Builds a [ContextRuleFlow] wired with a [FakeOZExternalSignerManager].
  ///
  /// Allows cleanup and leak behaviour to be tested without a live kit.
  static ContextRuleFlowWithManagerDeps makeFlowWithManager({
    MockContextRuleFlowManager? manager,
    MockBuilderEnvironment? environment,
  }) {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final demoState = container.read(demoStateProvider.notifier);
    final activityLog = container.read(activityLogProvider.notifier);

    demoState.setConnected(
      contractId: fixtureContractId,
      credentialId: fixtureCredentialId,
      isDeployed: true,
    );

    final fakeManager = FakeOZExternalSignerManager();
    demoState.injectFakeExternalSigners(fakeManager);

    final mgr = manager ?? MockContextRuleFlowManager();
    final env = environment ?? MockBuilderEnvironment();

    final flow = ContextRuleFlow(
      demoState: demoState,
      activityLog: activityLog,
      contextRuleManager: mgr,
      environment: env,
    );

    return ContextRuleFlowWithManagerDeps(
      flow: flow,
      demoState: demoState,
      fakeManager: fakeManager,
      container: container,
    );
  }
}

// ---------------------------------------------------------------------------
// ContextRuleFlowWithManagerDeps
// ---------------------------------------------------------------------------

/// Dependencies for context-rule flow tests that inject a [FakeOZExternalSignerManager].
final class ContextRuleFlowWithManagerDeps {
  const ContextRuleFlowWithManagerDeps({
    required this.flow,
    required this.demoState,
    required this.fakeManager,
    required this.container,
  });

  final ContextRuleFlow flow;
  final DemoStateNotifier demoState;
  final FakeOZExternalSignerManager fakeManager;
  final ProviderContainer container;
}

/// Constant-stream RNG so flows that call [Random.nextInt] do so
/// deterministically in tests.
final class FixedRandom implements Random {
  FixedRandom(this._value);

  final int _value;

  @override
  bool nextBool() => _value.isOdd;

  @override
  double nextDouble() => 0.0;

  @override
  int nextInt(int max) => _value % max;
}
