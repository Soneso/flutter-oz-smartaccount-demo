/// Shared multi-signer registration ceremony helpers.
///
/// [MultiSignerRegistrar] consolidates the register / cleanup contract used
/// by [TransferFlow], [ContextRuleFlow], and [ApproveFlow]:
///
/// - [registerDelegatedKeypairs] — add G-address keypairs to the kit manager.
/// - [clearDelegatedKeypairs]   — remove all registered keypairs (+ optional
///                                extra cleanup via [extraClear]).
/// - [withCleanupOfDelegatedKeypairs] — run a body and always clear afterwards.
/// - [withMultiSignerRegistration]    — register both key types, run body, clear.
///
/// The Ed25519 registration strategy is parameterised: callers supply a
/// [registerEd25519] callback that is invoked inside the guarded region.
/// [TransferFlow] and [ContextRuleFlow] pass the in-process-manager path;
/// [ApproveFlow] passes the adapter path. This preserves the distinct custody
/// semantics for each flow without collapsing them.
library;

import 'dart:typed_data';

import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import '../state/demo_state.dart';
import 'ed25519_signer_identity.dart';

/// Mixin that provides the multi-signer registration / cleanup ceremony.
///
/// Mixing in classes must provide [registrarDemoState] (the live notifier)
/// and may optionally override [extraClear] to run additional cleanup alongside
/// [clearDelegatedKeypairs] (e.g. clearing the [DemoEd25519Adapter]).
mixin MultiSignerRegistrar {
  /// The live [DemoStateNotifier] used to access [externalSigners].
  DemoStateNotifier get registrarDemoState;

  /// Optional extra cleanup invoked at the start of [clearDelegatedKeypairs].
  ///
  /// Override in mixing-in classes that manage additional custody (e.g.
  /// [ApproveFlow] clears [DemoEd25519Adapter] here). The default is a no-op.
  void extraClear() {}

  // -------------------------------------------------------------------------
  // registerDelegatedKeypairs
  // -------------------------------------------------------------------------

  /// Registers delegated signer keypairs as in-memory keypairs on the
  /// kit-owned external signer manager.
  ///
  /// Calls [OZExternalSignerManager.addFromSecret] for each entry with a
  /// non-empty seed. No-ops silently when the kit is not initialised.
  ///
  /// If any [addFromSecret] call fails, every signer registered on the manager
  /// is removed via [OZExternalSignerManager.removeAll] before rethrowing so
  /// the manager is never left in a partial state.
  ///
  /// Throws the original exception after cleanup — callers must not proceed
  /// after an error is thrown.
  Future<void> registerDelegatedKeypairs(
    Map<String, String> delegatedKeyPairs,
  ) async {
    final manager = registrarDemoState.externalSigners;
    if (manager == null) return;

    try {
      for (final entry in delegatedKeyPairs.entries) {
        final seed = entry.value;
        if (seed.isNotEmpty) {
          await manager.addFromSecret(seed);
        }
      }
    } catch (e) {
      // Partial registration — roll back to prevent a corrupt signer state.
      await manager.removeAll();
      rethrow;
    }
  }

  // -------------------------------------------------------------------------
  // clearDelegatedKeypairs
  // -------------------------------------------------------------------------

  /// Removes every signer registered on the kit-owned manager and invokes
  /// [extraClear] for any flow-specific cleanup.
  ///
  /// Calls [OZExternalSignerManager.removeAll], which clears all in-memory
  /// keypair and Ed25519 signers, disconnects every external wallet
  /// connection, and clears the persisted wallet connections from storage.
  /// No-ops silently when neither the kit nor any extra custody is initialised.
  Future<void> clearDelegatedKeypairs() async {
    extraClear();
    await registrarDemoState.externalSigners?.removeAll();
  }

  // -------------------------------------------------------------------------
  // withCleanupOfDelegatedKeypairs
  // -------------------------------------------------------------------------

  /// Runs [body] and guarantees [clearDelegatedKeypairs] is called even if
  /// [body] throws. Failures from [clearDelegatedKeypairs] are swallowed so
  /// the cleanup never masks an in-flight error from [body].
  ///
  /// Call this AFTER registration has completed successfully. The wrapper does
  /// not register anything itself; that stays at the call site so the call site
  /// can classify register-time failures with its own context before invoking
  /// the body.
  Future<R> withCleanupOfDelegatedKeypairs<R>(
    Future<R> Function() body,
  ) async {
    try {
      return await body();
    } finally {
      try {
        await clearDelegatedKeypairs();
      } catch (_) {
        // Swallow cleanup failures — they must never mask body errors.
      }
    }
  }

  // -------------------------------------------------------------------------
  // runWithMultiSignerRegistration (protected helper for subclasses)
  // -------------------------------------------------------------------------

  /// Registers all multi-signer signing material, runs [body], then clears
  /// the registered material in a `finally`.
  ///
  /// Registers the delegated G-address keypairs via [registerDelegatedKeypairs]
  /// and calls [registerEd25519] with the Ed25519 secrets (the caller provides
  /// the appropriate custody strategy). Both registrations run inside the
  /// guarded region so a failure during Ed25519 registration still clears the
  /// delegated keypairs that were registered first; nothing leaks on success,
  /// failure, or cancellation.
  ///
  /// Registration failures propagate to the caller after cleanup so the call
  /// site can classify them with its own context. [body] is invoked only when
  /// both registrations succeed.
  ///
  /// Mixing-in classes expose this as `withMultiSignerRegistration` with their
  /// own fixed [registerEd25519] strategy so callers do not supply it.
  Future<R> runWithMultiSignerRegistration<R>({
    required Map<String, String> delegatedKeyPairs,
    required Map<Ed25519SignerIdentity, Uint8List> ed25519Secrets,
    required Future<void> Function(Map<Ed25519SignerIdentity, Uint8List>)
        registerEd25519,
    required Future<R> Function() body,
  }) {
    return withCleanupOfDelegatedKeypairs(() async {
      await registerDelegatedKeypairs(delegatedKeyPairs);
      await registerEd25519(ed25519Secrets);
      return body();
    });
  }
}
