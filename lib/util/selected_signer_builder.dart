import 'dart:typed_data';

import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import '../flows/transfer_flow.dart' show SignerInfo, SignerKind;

/// Converts a list of [SignerInfo] choices into [SelectedSigner] entries.
///
/// Centralised, shared by [TransferFlow] and [ContextRuleFlow].
abstract class SelectedSignerBuilder {
  SelectedSignerBuilder._();

  /// Extracts the 32-byte Ed25519 public key from [raw] when it is an
  /// [OZExternalSigner] carrying exactly [SmartAccountConstants.ed25519PublicKeySize]
  /// bytes in its [OZExternalSigner.keyData] field.
  ///
  /// Returns null when [raw] is null, is not an [OZExternalSigner], or carries
  /// key data of the wrong length.
  static Uint8List? ed25519PublicKeyFor(Object? raw) {
    if (raw is! OZExternalSigner) return null;
    if (raw.keyData.length != SmartAccountConstants.ed25519PublicKeySize) {
      return null;
    }
    return raw.keyData;
  }

  /// Maps each [SignerInfo] in [signers] to the corresponding [SelectedSigner]
  /// subtype:
  ///
  /// - [SignerKind.passkey] → [SelectedSignerPasskey] (with credential data
  ///   when the raw signer is an [OZExternalSigner]). When [storage] is
  ///   provided, the stored credential's authenticator [transports] are looked
  ///   up by credential ID and forwarded so that additional passkey signers can
  ///   offer cross-device authentication (e.g. the `hybrid` transport drives
  ///   the browser's "use a passkey on another device" prompt).
  /// - [SignerKind.ed25519] → [SelectedSignerEd25519] (when the raw signer is
  ///   an [OZExternalSigner] carrying a 32-byte Ed25519 public key).
  /// - All other kinds → [SelectedSignerWallet] keyed by address.
  ///
  /// [storage] is the platform-injected [StorageAdapter] the kit was created
  /// with. When null, or when a credential is not present in storage, passkey
  /// transports fall back to null (the correct behaviour for credentials that
  /// were never persisted locally).
  static Future<List<SelectedSigner>> fromInfos(
    List<SignerInfo> signers, {
    StorageAdapter? storage,
  }) async {
    final result = <SelectedSigner>[];
    for (final info in signers) {
      if (info.kind == SignerKind.passkey) {
        final raw = info.rawSigner;
        if (raw is OZExternalSigner) {
          result.add(
            SelectedSignerPasskey(
              credentialId: info.credentialId,
              credentialIdBytes:
                  OZSmartAccountBuilders.getCredentialIdFromSigner(raw),
              keyData: raw.keyData,
              transports: await _lookupTransports(storage, info.credentialId),
            ),
          );
          continue;
        }
        result.add(const SelectedSignerPasskey());
        continue;
      }
      if (info.kind == SignerKind.ed25519) {
        final raw = info.rawSigner;
        if (raw is OZExternalSigner &&
            raw.keyData.length ==
                SmartAccountConstants.ed25519PublicKeySize) {
          result.add(
            SelectedSignerEd25519(
              verifierAddress: info.address,
              publicKey: raw.keyData,
            ),
          );
          continue;
        }
      }
      result.add(SelectedSignerWallet(info.address));
    }
    return List<SelectedSigner>.unmodifiable(result);
  }

  /// Reads the stored authenticator [StoredCredential.transports] for
  /// [credentialId] from [storage].
  ///
  /// Returns null when [storage] is null, [credentialId] is null, the
  /// credential is not in storage, or the lookup throws. A null result is the
  /// correct fallback: the SDK treats absent transports as "no hint".
  static Future<List<String>?> _lookupTransports(
    StorageAdapter? storage,
    String? credentialId,
  ) async {
    if (storage == null || credentialId == null) return null;
    try {
      final stored = await storage.get(credentialId);
      return stored?.transports;
    } catch (_) {
      return null;
    }
  }
}
