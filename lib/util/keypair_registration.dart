import 'dart:typed_data';

import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import '../flows/ed25519_signer_identity.dart';

/// Stateless helper for registering demo Ed25519 signing key material
/// between multi-signer flow methods.
///
/// Centralised, shared by [TransferFlow] and [ContextRuleFlow].
///
/// Operates on [OZExternalSignerManager] directly — the kit-owned instance
/// accessed via [DemoStateNotifier.externalSigners]. Material registered here
/// is released after each ceremony via [OZExternalSignerManager.removeAll].
abstract class KeypairRegistration {
  KeypairRegistration._();

  /// Registers each Ed25519 secret seed into [manager]'s in-process registry.
  ///
  /// Calls [OZExternalSignerManager.addEd25519FromRawKey] for each entry.
  /// If any registration fails, every signer registered on the manager is
  /// removed via [OZExternalSignerManager.removeAll] before rethrowing so the
  /// manager is never left in a partial state.
  ///
  /// No-ops silently when [manager] is null.
  ///
  /// Throws the original exception after cleanup — callers must not proceed
  /// with a multi-signer call after an error is thrown.
  static Future<void> registerEd25519Keypairs(
    OZExternalSignerManager? manager,
    Map<Ed25519SignerIdentity, Uint8List> secrets,
  ) async {
    if (manager == null) return;

    try {
      for (final entry in secrets.entries) {
        manager.addEd25519FromRawKey(
          secretKeyBytes: entry.value,
          verifierAddress: entry.key.verifierAddress,
        );
      }
    } catch (e) {
      // Partial registration — clear all signers before rethrowing.
      await manager.removeAll();
      rethrow;
    }
  }
}
