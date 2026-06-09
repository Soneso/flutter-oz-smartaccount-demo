import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_account_demo/util/context_rule_format.dart';
import 'package:smart_account_demo/util/policy_params_decoder.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

// A valid contract (C-address) used as the external verifier.
const String _verifier =
    'CB26VN37RCVNTHJZDEPK6IRO2MMTS3Z2IEO5JD5BINY2OOJ5KKJG7NKY';
// A valid account (G-address) used as a delegated signer.
const String _gAddress =
    'GA7QYNF7SOWQ3GLR2BGMZEHXAVIRZA4KVWLTJJFC7MGXUA74P7UJVSGZ';

// An Ed25519 32-byte key with a distinct first byte for display assertions.
final Uint8List _ed25519Key = () {
  final k = Uint8List(32);
  k[0] = 0xAB;
  k[1] = 0xCD;
  for (var i = 2; i < 32; i++) {
    k[i] = i & 0xFF;
  }
  return k;
}();

// A WebAuthn key: 65-byte secp256r1 public key (0x04 prefix) followed by a
// 20-byte credential ID.
final Uint8List _webAuthnKeyData = () {
  final bytes = Uint8List(85);
  bytes[0] = 0x04; // uncompressed secp256r1 prefix
  for (var i = 1; i < 85; i++) {
    bytes[i] = i & 0xFF;
  }
  return bytes;
}();

// ---- SCVal constructors ----------------------------------------------------

XdrSCVal _externalSignerScVal(Uint8List keyData) {
  return XdrSCVal.forVec([
    XdrSCVal.forSymbol('External'),
    XdrSCVal.forAddress(Address.forContractId(_verifier).toXdr()),
    XdrSCVal.forBytes(keyData),
  ]);
}

XdrSCVal _delegatedSignerScVal(String address) {
  final xdrAddr = StrKey.isValidContractId(address)
      ? Address.forContractId(address).toXdr()
      : Address.forAccountId(address).toXdr();
  return XdrSCVal.forVec([
    XdrSCVal.forSymbol('Delegated'),
    XdrSCVal.forAddress(xdrAddr),
  ]);
}

/// Helper: builds a weighted_threshold SCVal from a threshold and a list of
/// (signerScVal, weight) pairs.
XdrSCVal _weightedThresholdScVal(
  int threshold,
  List<(XdrSCVal, int)> entries,
) {
  return XdrSCVal.forMap([
    XdrSCMapEntry(
      XdrSCVal.forSymbol('threshold'),
      XdrSCVal.forU32(threshold),
    ),
    XdrSCMapEntry(
      XdrSCVal.forSymbol('signer_weights'),
      XdrSCVal.forMap([
        for (final (key, weight) in entries)
          XdrSCMapEntry(key, XdrSCVal.forU32(weight)),
      ]),
    ),
  ]);
}

void main() {
  // ---------------------------------------------------------------------------
  // reconstructSignerFromScVal
  // ---------------------------------------------------------------------------

  group('reconstructSignerFromScVal', () {
    test('delegated G-address signer reconstructs to OZDelegatedSigner', () {
      final scVal = _delegatedSignerScVal(_gAddress);
      final signer = reconstructSignerFromScVal(scVal);
      expect(signer, isNotNull);
      expect(signer, isA<OZDelegatedSigner>());
      expect((signer! as OZDelegatedSigner).address, _gAddress);
    });

    test('hex contract address in delegated signer is re-encoded to C-strkey',
        () {
      // Address.forContractId stores the C-strkey, which round-trips via XDR
      // as a 32-byte hash. Address.fromXdr then returns the hex of that hash,
      // and our code must convert it back to a C-strkey.
      final scVal = _delegatedSignerScVal(_verifier);
      final signer = reconstructSignerFromScVal(scVal);
      expect(signer, isNotNull);
      expect(signer, isA<OZDelegatedSigner>());
      // The address must be a valid C-address, not a raw hex string.
      final addr = (signer! as OZDelegatedSigner).address;
      expect(StrKey.isValidContractId(addr), isTrue);
    });

    test('Ed25519 external signer (32-byte key) reconstructs correctly', () {
      final scVal = _externalSignerScVal(_ed25519Key);
      final signer = reconstructSignerFromScVal(scVal);
      expect(signer, isNotNull);
      expect(signer, isA<OZExternalSigner>());
      final ext = signer! as OZExternalSigner;
      expect(ext.keyData, equals(_ed25519Key));
      expect(StrKey.isValidContractId(ext.verifierAddress), isTrue);
    });

    test('WebAuthn external signer (>65-byte key) reconstructs correctly', () {
      final scVal = _externalSignerScVal(_webAuthnKeyData);
      final signer = reconstructSignerFromScVal(scVal);
      expect(signer, isNotNull);
      expect(signer, isA<OZExternalSigner>());
      final ext = signer! as OZExternalSigner;
      expect(ext.keyData.length, 85);
      expect(StrKey.isValidContractId(ext.verifierAddress), isTrue);
    });

    test('returns null for an unrecognised Vec symbol', () {
      final scVal = XdrSCVal.forVec([
        XdrSCVal.forSymbol('Unknown'),
        XdrSCVal.forAddress(Address.forAccountId(_gAddress).toXdr()),
      ]);
      expect(reconstructSignerFromScVal(scVal), isNull);
    });

    test('returns null for a non-Vec SCVal', () {
      expect(reconstructSignerFromScVal(XdrSCVal.forSymbol('hello')), isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // formatSignerForDisplay on reconstructed signers
  // ---------------------------------------------------------------------------

  group('formatSignerForDisplay on reconstructed signers', () {
    test('delegated G-address renders G-Address badge + truncated address', () {
      final signer = OZDelegatedSigner(_gAddress);
      final info = formatSignerForDisplay(signer);
      expect(info.typeLabel, 'G-Address');
      // Truncated at chars=6: first 6 + '...' + last 6.
      expect(info.displayValue, startsWith(_gAddress.substring(0, 6)));
      expect(
        info.displayValue,
        endsWith(_gAddress.substring(_gAddress.length - 6)),
      );
    });

    test('Ed25519 external signer renders Ed25519 badge + key:<hex8>...', () {
      final signer = OZExternalSigner(_verifier, _ed25519Key);
      final info = formatSignerForDisplay(signer);
      expect(info.typeLabel, 'Ed25519');
      expect(info.displayValue, startsWith('key:'));
      // First 8 hex chars of the key bytes.
      final expectedHex =
          _ed25519Key.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      expect(info.displayValue, 'key:${expectedHex.substring(0, 8)}...');
    });

    test('WebAuthn external signer renders Passkey badge + credential-ID snippet',
        () {
      final signer = OZExternalSigner(_verifier, _webAuthnKeyData);
      final info = formatSignerForDisplay(signer);
      expect(info.typeLabel, 'Passkey');
      // Credential ID is the bytes after the 65-byte secp256r1 public key;
      // non-empty and truncated.
      expect(info.displayValue, isNotEmpty);
      expect(info.displayValue.length, lessThan(85));
    });
  });

  // ---------------------------------------------------------------------------
  // parseWeightedThresholdParams
  // ---------------------------------------------------------------------------

  group('parseWeightedThresholdParams', () {
    test('produces WeightedSignerEntry list with correct weights', () {
      final scVal = _weightedThresholdScVal(2, [
        (_delegatedSignerScVal(_gAddress), 3),
        (_externalSignerScVal(_ed25519Key), 1),
      ]);

      final params = parseWeightedThresholdParams(scVal);
      expect(params, isNotNull);
      expect(params!.threshold, 2);
      final weights = params.signerWeights;
      expect(weights, isNotNull);
      expect(weights!.length, 2);

      final delegatedEntry = weights.firstWhere(
        (e) => e.signer is OZDelegatedSigner,
      );
      expect(delegatedEntry.weight, 3);
      expect(delegatedEntry.displayInfo.typeLabel, 'G-Address');

      final ed25519Entry = weights.firstWhere(
        (e) =>
            e.signer is OZExternalSigner &&
            (e.signer! as OZExternalSigner).keyData.length == 32,
      );
      expect(ed25519Entry.weight, 1);
      expect(ed25519Entry.displayInfo.typeLabel, 'Ed25519');
    });

    test('delegated entry stableKey is the signer uniqueKey', () {
      final scVal = _weightedThresholdScVal(1, [
        (_delegatedSignerScVal(_gAddress), 2),
      ]);

      final params = parseWeightedThresholdParams(scVal);
      final entry = params!.signerWeights!.single;
      expect(entry.signer, isNotNull);
      expect(entry.stableKey, entry.signer!.uniqueKey);
    });

    test('WebAuthn signer entry renders Passkey badge', () {
      final scVal = _weightedThresholdScVal(1, [
        (_externalSignerScVal(_webAuthnKeyData), 5),
      ]);

      final params = parseWeightedThresholdParams(scVal);
      final entry = params!.signerWeights!.single;
      expect(entry.weight, 5);
      expect(entry.displayInfo.typeLabel, 'Passkey');
    });

    test('unrecognised SCVal produces fallback entry with non-empty display',
        () {
      // A Symbol val (not a Vec) is unrecognised.
      final scVal = _weightedThresholdScVal(1, [
        (XdrSCVal.forSymbol('unrecognised'), 7),
      ]);

      final params = parseWeightedThresholdParams(scVal);
      expect(params, isNotNull);
      final weights = params!.signerWeights;
      expect(weights, isNotNull);
      expect(weights!.length, 1);
      final entry = weights.single;
      expect(entry.signer, isNull);
      expect(entry.fallbackDisplay, isNotEmpty);
      expect(entry.displayInfo.typeLabel, 'Unknown');
      expect(entry.weight, 7);
    });

    test('returns null for non-map SCVal', () {
      expect(parseWeightedThresholdParams(XdrSCVal.forU32(5)), isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // Hex contract-ID → C-strkey reconstruction (covers _hexToContractStrkey)
  // ---------------------------------------------------------------------------

  group('hex contract-ID round-trip via reconstructSignerFromScVal', () {
    test('verifier hex recovered from XDR is re-encoded as a valid C-strkey',
        () {
      // _externalSignerScVal encodes _verifier (C-address) into XDR as a
      // 32-byte hash. Address.fromXdr then returns the hex of that hash.
      // reconstructSignerFromScVal must convert hex → C-strkey before
      // constructing OZExternalSigner (which rejects non-C-address verifiers).
      final scVal = _externalSignerScVal(_ed25519Key);
      final signer = reconstructSignerFromScVal(scVal);
      expect(signer, isA<OZExternalSigner>());
      final verifierStrkey = (signer! as OZExternalSigner).verifierAddress;
      expect(
        StrKey.isValidContractId(verifierStrkey),
        isTrue,
        reason: 'verifierAddress must be a C-strkey, not a hex string',
      );
    });
  });
}
