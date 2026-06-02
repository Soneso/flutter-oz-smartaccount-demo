/// Adapter interfaces and default kit-backed implementations consumed by
/// [ContextRuleFlow] for context-rule reads, mutations, edits, and builder
/// environment lookups.
///
/// The interfaces in this file (`ContextRuleFlowManagerType`,
/// `ContextRuleBuilderEnvironmentType`) form the seam the flow uses to
/// invoke the SDK. Tests inject lightweight mocks of these interfaces; the
/// production adapters (`ContextRuleManagerFlowAdapter`,
/// `ContextRuleBuilderEnvironmentAdapter`) are backed by a live
/// [OZSmartAccountKit].
library;

import 'dart:typed_data';

import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import '../config/demo_config.dart' as config;
import '../util/error_utils.dart';

// ---------------------------------------------------------------------------
// ContextRuleFlowManagerType
// ---------------------------------------------------------------------------

/// Abstraction over the SDK managers used by [ContextRuleFlow] for both
/// read / removal / create paths and the per-operation edit paths.
abstract interface class ContextRuleFlowManagerType {
  /// Returns all active context rules for the connected account.
  Future<List<ParsedContextRule>> listContextRules();

  /// Removes the rule with [id], optionally with explicit [selectedSigners].
  Future<TransactionResult> removeContextRule({
    required int id,
    List<SelectedSigner> selectedSigners,
  });

  /// Submits a new context rule with the given signer/policy configuration.
  Future<TransactionResult> addContextRule({
    required ContextRuleType contextType,
    required String name,
    int? validUntil,
    required List<OZSmartAccountSigner> signers,
    Map<String, XdrSCVal> policies,
    List<SelectedSigner> selectedSigners,
  });

  // ---- Per-operation edit methods ----

  /// Updates the human-readable name of an existing rule.
  Future<TransactionResult> updateContextRuleName({
    required int ruleId,
    required String name,
    List<SelectedSigner> selectedSigners,
  });

  /// Removes a signer from a rule by its on-chain ID.
  Future<TransactionResult> removeSignerFromRule({
    required int ruleId,
    required int signerId,
    List<SelectedSigner> selectedSigners,
  });

  /// Adds a delegated signer (G-address) to an existing rule.
  Future<TransactionResult> addDelegatedSignerToRule({
    required int ruleId,
    required String address,
    List<SelectedSigner> selectedSigners,
  });

  /// Adds an Ed25519 signer to an existing rule.
  Future<TransactionResult> addEd25519SignerToRule({
    required int ruleId,
    required Uint8List publicKey,
    List<SelectedSigner> selectedSigners,
  });

  /// Adds a passkey (WebAuthn) signer to an existing rule using an
  /// already-registered passkey.
  Future<TransactionResult> addPasskeySignerToRule({
    required int ruleId,
    required Uint8List publicKey,
    required Uint8List credentialId,
    List<SelectedSigner> selectedSigners,
  });

  /// Removes a policy from a rule by its on-chain ID.
  Future<TransactionResult> removePolicyFromRule({
    required int ruleId,
    required int policyId,
    List<SelectedSigner> selectedSigners,
  });

  /// Adds a policy with the given install parameters to an existing rule.
  Future<TransactionResult> addPolicyToRule({
    required int ruleId,
    required String policyAddress,
    required XdrSCVal installParams,
    List<SelectedSigner> selectedSigners,
  });

  /// Updates the expiry (`valid_until` ledger) of an existing rule. Pass
  /// `null` for [validUntil] to clear the expiry.
  Future<TransactionResult> updateContextRuleValidUntil({
    required int ruleId,
    int? validUntil,
    List<SelectedSigner> selectedSigners,
  });

  /// Invokes `set_threshold` on a threshold policy contract on behalf of
  /// the smart account, applying the new threshold value in a single
  /// transaction. Used for threshold-only policy modifications.
  Future<TransactionResult> setPolicyThreshold({
    required int ruleId,
    required String policyAddress,
    required int newThreshold,
    List<SelectedSigner> selectedSigners,
  });
}

// ---------------------------------------------------------------------------
// ContextRuleBuilderEnvironmentType
// ---------------------------------------------------------------------------

/// Abstraction over kit-derived environment values needed by the builder
/// flow. Allows unit tests to inject deterministic ledger values, fake
/// WebAuthn providers, synthetic verifier addresses, and stubbed
/// contract-data reads without a live kit.
abstract interface class ContextRuleBuilderEnvironmentType {
  /// Returns the configured WebAuthn (secp256r1) verifier C-address.
  String get webauthnVerifierAddress;

  /// Returns the configured Ed25519 verifier C-address.
  String get ed25519VerifierAddress;

  /// Returns the configured WebAuthn provider, or null when none is set.
  WebAuthnProvider? get webauthnProvider;

  /// Returns the current absolute ledger sequence on the network.
  Future<int> getCurrentLedger();

  /// Reads a persistent contract-data ledger entry from the network.
  ///
  /// Returns the stored [XdrSCVal] for the entry identified by
  /// [contractAddress] and [storageKey], or null when no entry exists at
  /// that key. Implementations must not throw on missing entries; only
  /// network or decoding failures should surface as exceptions.
  Future<XdrSCVal?> readContractDataValue({
    required String contractAddress,
    required XdrSCVal storageKey,
  });
}

// ---------------------------------------------------------------------------
// ContextRuleBuilderEnvironmentAdapter
// ---------------------------------------------------------------------------

/// Default production adapter for the builder environment. Backed by the
/// live [OZSmartAccountKit] instance held on [DemoStateNotifier].
final class ContextRuleBuilderEnvironmentAdapter
    implements ContextRuleBuilderEnvironmentType {
  /// Constructs the adapter from a live kit.
  const ContextRuleBuilderEnvironmentAdapter(this._kit);

  final OZSmartAccountKit _kit;

  @override
  String get webauthnVerifierAddress => _kit.config.webauthnVerifierAddress;

  @override
  String get ed25519VerifierAddress => config.ed25519VerifierAddress;

  @override
  WebAuthnProvider? get webauthnProvider => _kit.config.webauthnProvider;

  @override
  Future<int> getCurrentLedger() async {
    final response = await _kit.sorobanServer.getLatestLedger();
    final sequence = response.sequence;
    if (sequence == null) {
      throw const DemoError(
        message: 'Could not read current ledger from the network.',
        category: DemoErrorCategory.network,
      );
    }
    return sequence;
  }

  @override
  Future<XdrSCVal?> readContractDataValue({
    required String contractAddress,
    required XdrSCVal storageKey,
  }) async {
    final entry = await _kit.sorobanServer.getContractData(
      contractAddress,
      storageKey,
      XdrContractDataDurability.PERSISTENT,
    );
    if (entry == null) return null;
    return entry.ledgerEntryDataXdr.contractData?.val;
  }
}

// ---------------------------------------------------------------------------
// ContextRuleManagerFlowAdapter
// ---------------------------------------------------------------------------

/// Default production adapter backed by the [OZSmartAccountKit] managers.
final class ContextRuleManagerFlowAdapter
    implements ContextRuleFlowManagerType {
  /// Constructs the adapter from the live [OZSmartAccountKit] instance.
  const ContextRuleManagerFlowAdapter(this._kit);

  final OZSmartAccountKit _kit;

  OZContextRuleManager get _ruleManager => _kit.contextRuleManager;
  OZSignerManager get _signerManager => _kit.signerManager;
  OZPolicyManager get _policyManager => _kit.policyManager;
  OZTransactionOperations get _txOps => _kit.transactionOperations;
  OZMultiSignerManager get _multiSigner => _kit.multiSignerManager;

  @override
  Future<List<ParsedContextRule>> listContextRules() =>
      _ruleManager.listContextRules();

  @override
  Future<TransactionResult> removeContextRule({
    required int id,
    List<SelectedSigner> selectedSigners = const <SelectedSigner>[],
  }) =>
      _ruleManager.removeContextRule(
        id: id,
        selectedSigners: selectedSigners,
      );

  @override
  Future<TransactionResult> addContextRule({
    required ContextRuleType contextType,
    required String name,
    int? validUntil,
    required List<OZSmartAccountSigner> signers,
    Map<String, XdrSCVal> policies = const <String, XdrSCVal>{},
    List<SelectedSigner> selectedSigners = const <SelectedSigner>[],
  }) =>
      _ruleManager.addContextRule(
        contextType: contextType,
        name: name,
        validUntil: validUntil,
        signers: signers,
        policies: policies,
        selectedSigners: selectedSigners,
      );

  @override
  Future<TransactionResult> updateContextRuleName({
    required int ruleId,
    required String name,
    List<SelectedSigner> selectedSigners = const <SelectedSigner>[],
  }) =>
      _ruleManager.updateName(
        id: ruleId,
        name: name,
        selectedSigners: selectedSigners,
      );

  @override
  Future<TransactionResult> removeSignerFromRule({
    required int ruleId,
    required int signerId,
    List<SelectedSigner> selectedSigners = const <SelectedSigner>[],
  }) =>
      _signerManager.removeSigner(
        contextRuleId: ruleId,
        signerId: signerId,
        selectedSigners: selectedSigners,
      );

  @override
  Future<TransactionResult> addDelegatedSignerToRule({
    required int ruleId,
    required String address,
    List<SelectedSigner> selectedSigners = const <SelectedSigner>[],
  }) =>
      _signerManager.addDelegated(
        contextRuleId: ruleId,
        address: address,
        selectedSigners: selectedSigners,
      );

  @override
  Future<TransactionResult> addEd25519SignerToRule({
    required int ruleId,
    required Uint8List publicKey,
    List<SelectedSigner> selectedSigners = const <SelectedSigner>[],
  }) =>
      _signerManager.addEd25519(
        contextRuleId: ruleId,
        verifierAddress: config.ed25519VerifierAddress,
        publicKey: publicKey,
        selectedSigners: selectedSigners,
      );

  @override
  Future<TransactionResult> addPasskeySignerToRule({
    required int ruleId,
    required Uint8List publicKey,
    required Uint8List credentialId,
    List<SelectedSigner> selectedSigners = const <SelectedSigner>[],
  }) =>
      _signerManager.addPasskey(
        contextRuleId: ruleId,
        publicKey: publicKey,
        credentialId: credentialId,
        selectedSigners: selectedSigners,
      );

  @override
  Future<TransactionResult> removePolicyFromRule({
    required int ruleId,
    required int policyId,
    List<SelectedSigner> selectedSigners = const <SelectedSigner>[],
  }) =>
      _policyManager.removePolicy(
        contextRuleId: ruleId,
        policyId: policyId,
        selectedSigners: selectedSigners,
      );

  @override
  Future<TransactionResult> addPolicyToRule({
    required int ruleId,
    required String policyAddress,
    required XdrSCVal installParams,
    List<SelectedSigner> selectedSigners = const <SelectedSigner>[],
  }) =>
      _policyManager.addPolicy(
        contextRuleId: ruleId,
        policyAddress: policyAddress,
        installParams: installParams,
        selectedSigners: selectedSigners,
      );

  @override
  Future<TransactionResult> updateContextRuleValidUntil({
    required int ruleId,
    int? validUntil,
    List<SelectedSigner> selectedSigners = const <SelectedSigner>[],
  }) =>
      _ruleManager.updateValidUntil(
        id: ruleId,
        validUntil: validUntil,
        selectedSigners: selectedSigners,
      );

  @override
  Future<TransactionResult> setPolicyThreshold({
    required int ruleId,
    required String policyAddress,
    required int newThreshold,
    List<SelectedSigner> selectedSigners = const <SelectedSigner>[],
  }) async {
    // Fetch the on-chain ContextRule SCVal — the policy contract requires
    // it as the second argument of set_threshold for binding.
    final contextRuleScVal = await _ruleManager.getContextRule(ruleId);
    final smartAccountAddress = _kit.contractId;
    if (smartAccountAddress == null) {
      throw const DemoError(
        message:
            'Wallet not connected. Cannot resolve smart account address.',
        category: DemoErrorCategory.validation,
      );
    }

    final targetArgs = <XdrSCVal>[
      XdrSCVal.forU32(newThreshold),
      contextRuleScVal,
      XdrSCVal.forAddress(
        Address.forContractId(smartAccountAddress).toXdr(),
      ),
    ];

    if (selectedSigners.isEmpty) {
      return _txOps.executeAndSubmit(
        target: policyAddress,
        targetFn: 'set_threshold',
        targetArgs: targetArgs,
      );
    }
    return _multiSigner.multiSignerExecuteAndSubmit(
      target: policyAddress,
      targetFn: 'set_threshold',
      targetArgs: targetArgs,
      selectedSigners: selectedSigners,
    );
  }
}
