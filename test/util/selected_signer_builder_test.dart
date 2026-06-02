import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_account_demo/flows/transfer_flow.dart'
    show SignerInfo, SignerKind;
import 'package:smart_account_demo/util/selected_signer_builder.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

/// Valid testnet WebAuthn verifier contract address (C-address). Used only as
/// a syntactically valid verifier for [OZExternalSigner] construction.
const String _verifierAddress =
    'CB26VN37RCVNTHJZDEPK6IRO2MMTS3Z2IEO5JD5BINY2OOJ5KKJG7NKY';

/// Returns a deterministic 65-byte uncompressed secp256r1 public key.
Uint8List _publicKey({int seed = 0xAB}) {
  final bytes = Uint8List(65);
  bytes[0] = 0x04;
  for (var i = 1; i < 65; i++) {
    bytes[i] = (seed + i) & 0xFF;
  }
  return bytes;
}

/// Returns a deterministic credential-ID byte sequence.
Uint8List _credentialIdBytes({int length = 20, int seed = 0x10}) {
  final bytes = Uint8List(length);
  for (var i = 0; i < length; i++) {
    bytes[i] = (seed + i) & 0xFF;
  }
  return bytes;
}

/// Builds a passkey [SignerInfo] whose raw signer is a real WebAuthn
/// [OZExternalSigner]. The returned [SignerInfo.credentialId] is the
/// Base64URL string used as the storage key for transport lookups.
SignerInfo _passkeySignerInfo() {
  final signer = OZExternalSigner.webAuthn(
    verifierAddress: _verifierAddress,
    publicKey: _publicKey(),
    credentialId: _credentialIdBytes(),
  );
  final credentialIdString =
      OZSmartAccountBuilders.getCredentialIdStringFromSigner(signer);
  return SignerInfo(
    displayLabel: 'Passkey',
    address: '',
    kind: SignerKind.passkey,
    isConnectedCredential: false,
    credentialId: credentialIdString,
    rawSigner: signer,
  );
}

void main() {
  group('SelectedSignerBuilder.fromInfos — passkey transports lookup', () {
    test('forwards stored transports for a passkey credential', () async {
      final info = _passkeySignerInfo();
      final storage = InMemoryStorageAdapter();
      await storage.save(
        StoredCredential(
          credentialId: info.credentialId!,
          publicKey: _publicKey(),
          transports: const ['internal', 'hybrid'],
        ),
      );

      final signers =
          await SelectedSignerBuilder.fromInfos([info], storage: storage);

      expect(signers, hasLength(1));
      final passkey = signers.single as SelectedSignerPasskey;
      expect(passkey.transports, equals(const ['internal', 'hybrid']));
    });

    test('transports is null when the credential stored none', () async {
      final info = _passkeySignerInfo();
      final storage = InMemoryStorageAdapter();
      await storage.save(
        StoredCredential(
          credentialId: info.credentialId!,
          publicKey: _publicKey(),
          // No transports persisted.
        ),
      );

      final signers =
          await SelectedSignerBuilder.fromInfos([info], storage: storage);

      final passkey = signers.single as SelectedSignerPasskey;
      expect(passkey.transports, isNull);
    });

    test('transports is null when the credential is not in storage', () async {
      final info = _passkeySignerInfo();
      final storage = InMemoryStorageAdapter();

      final signers =
          await SelectedSignerBuilder.fromInfos([info], storage: storage);

      final passkey = signers.single as SelectedSignerPasskey;
      expect(passkey.transports, isNull);
    });

    test('transports is null when no storage adapter is supplied', () async {
      final info = _passkeySignerInfo();

      final signers = await SelectedSignerBuilder.fromInfos([info]);

      final passkey = signers.single as SelectedSignerPasskey;
      expect(passkey.transports, isNull);
    });
  });
}
