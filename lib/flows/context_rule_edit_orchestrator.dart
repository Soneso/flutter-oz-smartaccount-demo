part of 'context_rule_flow.dart';

/// Result of running one edit step. Returned by [ContextRuleFlow._runStep].
///
/// `completed` is the new value the orchestrator should adopt — it is either
/// `priorCompleted + 1` on success or `priorCompleted` on failure / precondition
/// skip. `failure` is non-null only when the step failed (precondition,
/// `!success` manager result, or thrown exception).
typedef _StepOutcome = ({int completed, ContextRuleEditResult? failure});

/// Private orchestrator helpers for [ContextRuleFlow.submitContextRuleEdits].
///
/// These members run as private methods on [ContextRuleFlow] so they may
/// read instance state ([_activityLog], [_contextRuleManager],
/// [_environment]) without threading it through each call. The split into
/// this file is purely physical: the symbols remain private to the class.
extension _ContextRuleEditOrchestrator on ContextRuleFlow {
  /// Builds the partial-success result emitted when the auth-context guard
  /// pauses edit submission after adding signers.
  ContextRuleEditResult _authGuardPartialResult({
    required int completed,
    required int totalOps,
    required List<String> hashes,
  }) {
    const authGuardMessage = 'Signer changes were applied successfully. '
        'Policy and expiration updates were skipped because adding '
        "signers changes the rule's authorization requirements. Please "
        'edit the rule again to apply the remaining changes.';
    _activityLog.info(authGuardMessage);
    return ContextRuleEditResult(
      success: true,
      completedOperations: completed,
      totalOperations: totalOps,
      partialDueToAuthGuard: true,
      authGuardMessage: authGuardMessage,
      error: null,
      failedStep: null,
      transactionHashes: List<String>.unmodifiable(hashes),
    );
  }

  /// Combined pre-flight for the non-threshold modified-policy branch.
  ///
  /// Returns a non-null failure when either `onChainId` or `scVal` is missing
  /// on [entry] — both inputs are required to run the remove + re-add pair,
  /// and a missing input must short-circuit the WHOLE iteration so the re-add
  /// never runs without its remove. The two null branches surface distinct
  /// `failedStep` strings so the activity log identifies which input was
  /// missing: `onChainId == null` reports the remove half, `scVal == null`
  /// reports the re-add half.
  ContextRuleEditResult? _modifiedPolicyDualPreflight({
    required EditPolicyEntry entry,
    required String removeStep,
    required String readdStep,
    required int completed,
    required int totalOps,
    required List<String> hashes,
  }) {
    if (entry.onChainId == null) {
      return _editFailure(
        completedOps: completed,
        totalOps: totalOps,
        failedStep: removeStep,
        rawError: 'Policy is missing its on-chain ID.',
        hashes: hashes,
      );
    }
    if (entry.scVal == null) {
      return _editFailure(
        completedOps: completed,
        totalOps: totalOps,
        failedStep: readdStep,
        rawError: 'Policy is missing install parameters.',
        hashes: hashes,
      );
    }
    return null;
  }

  /// Success result for the no-op case where the diff carries no changes.
  ContextRuleEditResult _emptyDiffSuccessResult() =>
      const ContextRuleEditResult(
        success: true,
        completedOperations: 0,
        totalOperations: 0,
        partialDueToAuthGuard: false,
        authGuardMessage: null,
        error: null,
        failedStep: null,
      );

  /// True when [diff] has any policy or expiry change still pending after
  /// signer mutations have been applied.
  bool _hasPolicyOrExpiryWork(ContextRuleEditDiff diff) =>
      diff.removedPolicies.isNotEmpty ||
      diff.newPolicies.isNotEmpty ||
      diff.modifiedPolicies.isNotEmpty ||
      diff.expiryChanged;

  /// Pre-flight failure builder for `onChainId` nullability checks on signer
  /// and policy steps. Returns null when [onChainId] is set.
  ContextRuleEditResult? _requireOnChainId(
    int? onChainId,
    String stepName,
    String rawError, {
    required int completed,
    required int totalOps,
    required List<String> hashes,
  }) =>
      onChainId == null
          ? _editFailure(
              completedOps: completed,
              totalOps: totalOps,
              failedStep: stepName,
              rawError: rawError,
              hashes: hashes,
            )
          : null;

  /// Pre-flight failure builder for `scVal` nullability checks on policy
  /// install steps. Returns null when [scVal] is set.
  ContextRuleEditResult? _requireScVal(
    XdrSCVal? scVal,
    String stepName, {
    required int completed,
    required int totalOps,
    required List<String> hashes,
  }) =>
      scVal == null
          ? _editFailure(
              completedOps: completed,
              totalOps: totalOps,
              failedStep: stepName,
              rawError: 'Policy is missing install parameters.',
              hashes: hashes,
            )
          : null;

  /// Appends [hash] to [hashes] when non-null and non-empty.
  void _appendHash(List<String> hashes, String? hash) {
    if (hash == null || hash.isEmpty) return;
    hashes.add(hash);
  }

  /// Runs one edit step on behalf of [submitContextRuleEdits].
  ///
  /// When [precondition] is provided and returns non-null, the helper
  /// short-circuits: it returns that [ContextRuleEditResult] as the failure
  /// value without invoking [call] and without advancing `completed`. This is
  /// the slot for `onChainId == null` / `scVal == null` / `newThreshold ==
  /// null` pre-flight checks performed before the step's on-chain call.
  ///
  /// On `call` success, the result hash is appended to [hashes] (mutated in
  /// place) and the helper returns `(completed: priorCompleted + 1,
  /// failure: null)`.
  ///
  /// On `call` returning a `!success` [TransactionResult], the helper returns
  /// `(completed: priorCompleted, failure: _editFailure(...))`.
  ///
  /// On `call` throwing, the helper returns
  /// `(completed: priorCompleted, failure: _editFailureFromException(...))`.
  ///
  /// The caller MUST reassign `completed` from the returned outcome on every
  /// step. Dart `int` is value-typed, so the helper cannot mutate the caller's
  /// local; the outcome's `completed` field is the only way the new value
  /// reaches the orchestrator.
  Future<_StepOutcome> _runStep({
    required String stepName,
    required int totalOps,
    required int priorCompleted,
    required List<String> hashes,
    required Future<TransactionResult> Function() call,
    ContextRuleEditResult? Function()? precondition,
  }) async {
    if (precondition != null) {
      final preflight = precondition();
      if (preflight != null) {
        return (completed: priorCompleted, failure: preflight);
      }
    }
    try {
      final result = await call();
      if (!result.success) {
        return (
          completed: priorCompleted,
          failure: _editFailure(
            completedOps: priorCompleted,
            totalOps: totalOps,
            failedStep: stepName,
            rawError: result.error,
            hashes: hashes,
          ),
        );
      }
      _appendHash(hashes, result.hash);
      return (completed: priorCompleted + 1, failure: null);
    } catch (e) {
      return (
        completed: priorCompleted,
        failure: _editFailureFromException(
          completedOps: priorCompleted,
          totalOps: totalOps,
          failedStep: stepName,
          error: e,
          hashes: hashes,
        ),
      );
    }
  }

  /// Dispatches an `add signer` operation to the correct typed SDK call
  /// based on the runtime type of [EditSignerEntry.signer] and, for
  /// external signers, the verifier address.
  Future<TransactionResult> _dispatchAddSigner({
    required int ruleId,
    required EditSignerEntry entry,
    required List<SelectedSigner> selectedSigners,
  }) async {
    final signer = entry.signer;
    if (signer is OZDelegatedSigner) {
      return _contextRuleManager.addDelegatedSignerToRule(
        ruleId: ruleId,
        address: signer.address,
        selectedSigners: selectedSigners,
      );
    }
    if (signer is OZExternalSigner) {
      final env = _requireEnvironment('addSignerToRule');
      final webauthnVerifier = env.webauthnVerifierAddress;
      final ed25519Verifier = env.ed25519VerifierAddress;

      if (signer.verifierAddress == webauthnVerifier) {
        // External WebAuthn: keyData is laid out as [public key | credential
        // ID]. The Base64URL credential ID is canonical for on-chain
        // identification, so we recover the raw bytes by decoding the
        // helper-derived string rather than slicing the keyData suffix
        // (which assumes a fixed public-key length and is easy to skew if
        // the SDK ever switches to a longer COSE encoding).
        final credentialIdString =
            OZSmartAccountBuilders.getCredentialIdStringFromSigner(signer);
        if (credentialIdString == null) {
          throw const DemoError(
            message: 'Passkey signer is missing a credential ID.',
            category: DemoErrorCategory.validation,
          );
        }
        const pubKeyLen = 65;
        if (signer.keyData.length <= pubKeyLen) {
          throw const DemoError(
            message: 'Passkey signer keyData is too short to extract a '
                'public key and credential ID.',
            category: DemoErrorCategory.validation,
          );
        }
        final publicKey =
            Uint8List.fromList(signer.keyData.sublist(0, pubKeyLen));
        final Uint8List credentialId;
        try {
          credentialId = base64Url.decode(credentialIdString);
        } on FormatException {
          throw const DemoError(
            message: 'Passkey signer credential ID is not valid Base64URL.',
            category: DemoErrorCategory.validation,
          );
        }
        return _contextRuleManager.addPasskeySignerToRule(
          ruleId: ruleId,
          publicKey: publicKey,
          credentialId: credentialId,
          selectedSigners: selectedSigners,
        );
      }
      if (signer.verifierAddress == ed25519Verifier) {
        return _contextRuleManager.addEd25519SignerToRule(
          ruleId: ruleId,
          publicKey: Uint8List.fromList(signer.keyData),
          selectedSigners: selectedSigners,
        );
      }
      throw const DemoError(
        message: 'Signer verifier is not configured for this account.',
        category: DemoErrorCategory.validation,
      );
    }
    throw DemoError(
      message: 'Unsupported signer type: ${signer.runtimeType}',
      category: DemoErrorCategory.validation,
    );
  }

  /// Builds a failure [ContextRuleEditResult] from a manager error string.
  ContextRuleEditResult _editFailure({
    required int completedOps,
    required int totalOps,
    required String failedStep,
    required String? rawError,
    required List<String> hashes,
  }) {
    final raw = rawError ?? 'Unknown error';
    _activityLog.error('Edit failed at $failedStep: $raw');
    return ContextRuleEditResult(
      success: false,
      completedOperations: completedOps,
      totalOperations: totalOps,
      partialDueToAuthGuard: false,
      authGuardMessage: null,
      error: raw,
      failedStep: failedStep,
      transactionHashes: List<String>.unmodifiable(hashes),
    );
  }

  /// Builds a failure [ContextRuleEditResult] from a thrown exception.
  ContextRuleEditResult _editFailureFromException({
    required int completedOps,
    required int totalOps,
    required String failedStep,
    required Object error,
    required List<String> hashes,
  }) {
    final String message;
    if (error is WebAuthnCancelled) {
      message = 'Passkey authentication cancelled';
      _activityLog.info(message);
    } else if (error is DemoError) {
      message = error.message;
      _activityLog.error('Edit failed at $failedStep: $message');
    } else {
      final classified = classifyError(error);
      message = classified.message;
      _activityLog.error('Edit failed at $failedStep: $message');
    }
    return ContextRuleEditResult(
      success: false,
      completedOperations: completedOps,
      totalOperations: totalOps,
      partialDueToAuthGuard: false,
      authGuardMessage: null,
      error: message,
      failedStep: failedStep,
      transactionHashes: List<String>.unmodifiable(hashes),
    );
  }

  /// Extracts the threshold value from a `{ symbol("threshold"): U32 }`
  /// install-params map. Returns null when the input cannot be parsed.
  int? _extractThresholdFromScVal(XdrSCVal? scVal) {
    if (scVal == null) return null;
    final entries = scVal.map;
    if (entries == null) return null;
    for (final entry in entries) {
      final keySymbol = entry.key.sym;
      if (keySymbol == PolicyType.threshold) {
        return entry.val.u32?.uint32;
      }
    }
    return null;
  }
}
