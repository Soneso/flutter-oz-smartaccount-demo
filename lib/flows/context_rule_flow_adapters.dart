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
import 'context_rule_edit_types.dart' show PolicyWeightedEntry;

// ---------------------------------------------------------------------------
// ContextRuleFlowManagerType
// ---------------------------------------------------------------------------

/// Abstraction over the SDK managers used by [ContextRuleFlow] for both
/// read / removal / create paths and the per-operation edit paths.
abstract interface class ContextRuleFlowManagerType {
  /// Returns all active context rules for the connected account.
  Future<List<OZParsedContextRule>> listContextRules();

  /// Removes the rule with [id], optionally with explicit [selectedSigners].
  Future<OZTransactionResult> removeContextRule({
    required int id,
    List<OZSelectedSigner> selectedSigners,
  });

  /// Submits a new context rule with the given signer/policy configuration.
  Future<OZTransactionResult> addContextRule({
    required OZContextRuleType contextType,
    required String name,
    int? validUntil,
    required List<OZSmartAccountSigner> signers,
    Map<String, XdrSCVal> policies,
    List<OZSelectedSigner> selectedSigners,
  });

  // ---- Per-operation edit methods ----

  /// Updates the human-readable name of an existing rule.
  Future<OZTransactionResult> updateContextRuleName({
    required int ruleId,
    required String name,
    List<OZSelectedSigner> selectedSigners,
  });

  /// Removes a signer from a rule by its on-chain ID.
  Future<OZTransactionResult> removeSignerFromRule({
    required int ruleId,
    required int signerId,
    List<OZSelectedSigner> selectedSigners,
  });

  /// Adds a delegated signer (G-address) to an existing rule.
  Future<OZTransactionResult> addDelegatedSignerToRule({
    required int ruleId,
    required String address,
    List<OZSelectedSigner> selectedSigners,
  });

  /// Adds an Ed25519 signer to an existing rule.
  Future<OZTransactionResult> addEd25519SignerToRule({
    required int ruleId,
    required Uint8List publicKey,
    List<OZSelectedSigner> selectedSigners,
  });

  /// Adds a passkey (WebAuthn) signer to an existing rule using an
  /// already-registered passkey.
  Future<OZTransactionResult> addPasskeySignerToRule({
    required int ruleId,
    required Uint8List publicKey,
    required Uint8List credentialId,
    List<OZSelectedSigner> selectedSigners,
  });

  /// Removes a policy from a rule by its on-chain ID.
  Future<OZTransactionResult> removePolicyFromRule({
    required int ruleId,
    required int policyId,
    List<OZSelectedSigner> selectedSigners,
  });

  /// Adds a simple-threshold policy to an existing rule.
  ///
  /// Delegates to [OZPolicyManager.addSimpleThreshold]. Used for the
  /// EDIT "add new policy" and "re-add after remove" paths.
  Future<OZTransactionResult> addSimpleThresholdToRule({
    required int ruleId,
    required String policyAddress,
    required int threshold,
    List<OZSelectedSigner> selectedSigners,
  });

  /// Adds a weighted-threshold policy to an existing rule.
  ///
  /// Delegates to [OZPolicyManager.addWeightedThreshold]. The [entries]
  /// list is mapped to [OZSignerWeightEntry] inside the production adapter.
  Future<OZTransactionResult> addWeightedThresholdToRule({
    required int ruleId,
    required String policyAddress,
    required List<PolicyWeightedEntry> entries,
    required int threshold,
    List<OZSelectedSigner> selectedSigners,
  });

  /// Adds a spending-limit policy to an existing rule.
  ///
  /// Delegates to [OZPolicyManager.addSpendingLimit]. The SDK converts
  /// [amount] (decimal string) to base units using [decimals].
  Future<OZTransactionResult> addSpendingLimitToRule({
    required int ruleId,
    required String policyAddress,
    required String amount,
    required int decimals,
    required int periodLedgers,
    List<OZSelectedSigner> selectedSigners,
  });

  /// Updates the expiry (`valid_until` ledger) of an existing rule. Pass
  /// `null` for [validUntil] to clear the expiry.
  Future<OZTransactionResult> updateContextRuleValidUntil({
    required int ruleId,
    int? validUntil,
    List<OZSelectedSigner> selectedSigners,
  });

  /// Invokes `set_threshold` on a threshold policy contract on behalf of
  /// the smart account, applying the new threshold value in a single
  /// transaction. Used for threshold-only policy modifications.
  Future<OZTransactionResult> setPolicyThreshold({
    required int ruleId,
    required String policyAddress,
    required int newThreshold,
    List<OZSelectedSigner> selectedSigners,
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

  /// Reads the `decimals()` value of the token contract at [tokenContract]
  /// via a read-only simulation.
  Future<int> fetchTokenDecimals(String tokenContract);

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
    final server = SorobanServer(config.rpcUrl);
    try {
      final response = await server.getLatestLedger();
      final sequence = response.sequence;
      if (sequence == null) {
        throw const DemoError(
          message: 'Could not read current ledger from the network.',
          category: DemoErrorCategory.network,
        );
      }
      return sequence;
    } finally {
      server.close();
    }
  }

  @override
  Future<int> fetchTokenDecimals(String tokenContract) =>
      _kit.transactionOperations.fetchTokenDecimals(tokenContract);

  @override
  Future<XdrSCVal?> readContractDataValue({
    required String contractAddress,
    required XdrSCVal storageKey,
  }) async {
    final server = SorobanServer(config.rpcUrl);
    try {
      final entry = await server.getContractData(
        contractAddress,
        storageKey,
        XdrContractDataDurability.PERSISTENT,
      );
      if (entry == null) return null;
      return entry.ledgerEntryDataXdr.contractData?.val;
    } finally {
      server.close();
    }
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
  Future<List<OZParsedContextRule>> listContextRules() =>
      _ruleManager.listContextRules();

  @override
  Future<OZTransactionResult> removeContextRule({
    required int id,
    List<OZSelectedSigner> selectedSigners = const <OZSelectedSigner>[],
  }) =>
      _ruleManager.removeContextRule(
        id: id,
        selectedSigners: selectedSigners,
      );

  @override
  Future<OZTransactionResult> addContextRule({
    required OZContextRuleType contextType,
    required String name,
    int? validUntil,
    required List<OZSmartAccountSigner> signers,
    Map<String, XdrSCVal> policies = const <String, XdrSCVal>{},
    List<OZSelectedSigner> selectedSigners = const <OZSelectedSigner>[],
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
  Future<OZTransactionResult> updateContextRuleName({
    required int ruleId,
    required String name,
    List<OZSelectedSigner> selectedSigners = const <OZSelectedSigner>[],
  }) =>
      _ruleManager.updateName(
        id: ruleId,
        name: name,
        selectedSigners: selectedSigners,
      );

  @override
  Future<OZTransactionResult> removeSignerFromRule({
    required int ruleId,
    required int signerId,
    List<OZSelectedSigner> selectedSigners = const <OZSelectedSigner>[],
  }) =>
      _signerManager.removeSigner(
        contextRuleId: ruleId,
        signerId: signerId,
        selectedSigners: selectedSigners,
      );

  @override
  Future<OZTransactionResult> addDelegatedSignerToRule({
    required int ruleId,
    required String address,
    List<OZSelectedSigner> selectedSigners = const <OZSelectedSigner>[],
  }) =>
      _signerManager.addDelegated(
        contextRuleId: ruleId,
        address: address,
        selectedSigners: selectedSigners,
      );

  @override
  Future<OZTransactionResult> addEd25519SignerToRule({
    required int ruleId,
    required Uint8List publicKey,
    List<OZSelectedSigner> selectedSigners = const <OZSelectedSigner>[],
  }) =>
      _signerManager.addEd25519(
        contextRuleId: ruleId,
        verifierAddress: config.ed25519VerifierAddress,
        publicKey: publicKey,
        selectedSigners: selectedSigners,
      );

  @override
  Future<OZTransactionResult> addPasskeySignerToRule({
    required int ruleId,
    required Uint8List publicKey,
    required Uint8List credentialId,
    List<OZSelectedSigner> selectedSigners = const <OZSelectedSigner>[],
  }) =>
      _signerManager.addPasskey(
        contextRuleId: ruleId,
        publicKey: publicKey,
        credentialId: credentialId,
        selectedSigners: selectedSigners,
      );

  @override
  Future<OZTransactionResult> removePolicyFromRule({
    required int ruleId,
    required int policyId,
    List<OZSelectedSigner> selectedSigners = const <OZSelectedSigner>[],
  }) =>
      _policyManager.removePolicy(
        contextRuleId: ruleId,
        policyId: policyId,
        selectedSigners: selectedSigners,
      );

  @override
  Future<OZTransactionResult> addSimpleThresholdToRule({
    required int ruleId,
    required String policyAddress,
    required int threshold,
    List<OZSelectedSigner> selectedSigners = const <OZSelectedSigner>[],
  }) =>
      _policyManager.addSimpleThreshold(
        contextRuleId: ruleId,
        policyAddress: policyAddress,
        threshold: threshold,
        selectedSigners: selectedSigners,
      );

  @override
  Future<OZTransactionResult> addWeightedThresholdToRule({
    required int ruleId,
    required String policyAddress,
    required List<PolicyWeightedEntry> entries,
    required int threshold,
    List<OZSelectedSigner> selectedSigners = const <OZSelectedSigner>[],
  }) {
    // Convert the flat list of [PolicyWeightedEntry] to the Map shape the SDK
    // expects. Insertion order is preserved so the on-chain encoding is stable.
    final signerWeights = <OZSmartAccountSigner, int>{
      for (final e in entries) e.signer: e.weight,
    };
    return _policyManager.addWeightedThreshold(
      contextRuleId: ruleId,
      policyAddress: policyAddress,
      signerWeights: signerWeights,
      threshold: threshold,
      selectedSigners: selectedSigners,
    );
  }

  @override
  Future<OZTransactionResult> addSpendingLimitToRule({
    required int ruleId,
    required String policyAddress,
    required String amount,
    required int decimals,
    required int periodLedgers,
    List<OZSelectedSigner> selectedSigners = const <OZSelectedSigner>[],
  }) =>
      _policyManager.addSpendingLimit(
        contextRuleId: ruleId,
        policyAddress: policyAddress,
        spendingLimit: amount,
        periodLedgers: periodLedgers,
        decimals: decimals,
        selectedSigners: selectedSigners,
      );

  @override
  Future<OZTransactionResult> updateContextRuleValidUntil({
    required int ruleId,
    int? validUntil,
    List<OZSelectedSigner> selectedSigners = const <OZSelectedSigner>[],
  }) =>
      _ruleManager.updateValidUntil(
        id: ruleId,
        validUntil: validUntil,
        selectedSigners: selectedSigners,
      );

  @override
  Future<OZTransactionResult> setPolicyThreshold({
    required int ruleId,
    required String policyAddress,
    required int newThreshold,
    List<OZSelectedSigner> selectedSigners = const <OZSelectedSigner>[],
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
