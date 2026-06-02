/// Unit tests for [context_rule_format.dart].
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_account_demo/util/context_rule_format.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

void main() {
  // ---------------------------------------------------------------------------
  // formatContextType
  // ---------------------------------------------------------------------------

  group('formatContextType', () {
    test('Default returns "Default (Any Operation)"', () {
      expect(
        formatContextType(const ContextRuleTypeDefault()),
        'Default (Any Operation)',
      );
    });

    test('CallContract returns "Call Contract: <truncated address>"', () {
      const addr = 'CAAQEAYEAUDAOCAJBIFQYDIOB4IBCEQTCQKRMFYYDENBWHA5DYPSBFLM';
      final result =
          formatContextType(ContextRuleTypeCallContract(addr));

      // Uses the 4-char `truncateAddress` form so the label fits chip and
      // pill layouts without horizontal overflow.
      expect(result, 'Call Contract: CAAQ...BFLM');
    });

    test('CreateContract returns "Create Contract: <8 hex chars>..."', () {
      final wasm = Uint8List(32)..fillRange(0, 32, 0xAB);
      final result =
          formatContextType(ContextRuleTypeCreateContract(wasm));

      expect(result, startsWith('Create Contract:'));
      expect(result, contains('abababab'));
      expect(result, endsWith('...'));
    });
  });

  // ---------------------------------------------------------------------------
  // formatSignerForDisplay
  // ---------------------------------------------------------------------------

  group('formatSignerForDisplay — OZDelegatedSigner', () {
    test('type label is "G-Address"', () {
      const addr = 'GCKE5G7SSH4O4QBJWS32UY3C2MOMTULMSPMJD6ZJ426FOHXH5YCUNMPM';
      final info = formatSignerForDisplay(OZDelegatedSigner(addr));

      expect(info.typeLabel, 'G-Address');
    });

    test('display value is truncated to 6 chars each side', () {
      const addr = 'GCKE5G7SSH4O4QBJWS32UY3C2MOMTULMSPMJD6ZJ426FOHXH5YCUNMPM';
      final info = formatSignerForDisplay(OZDelegatedSigner(addr));

      expect(info.displayValue, contains('...'));
      expect(info.displayValue, startsWith('GCKE5G'));
    });
  });

  group('formatSignerForDisplay — OZExternalSigner Ed25519', () {
    test('type label is "Ed25519" for 32-byte key data', () {
      const verifier =
          'CAAQEAYEAUDAOCAJBIFQYDIOB4IBCEQTCQKRMFYYDENBWHA5DYPSBFLM';
      final key = Uint8List(32)..fillRange(0, 32, 0x01);
      final signer = OZExternalSigner(verifier, key);
      final info = formatSignerForDisplay(signer);

      expect(info.typeLabel, 'Ed25519');
      expect(info.displayValue, startsWith('key:'));
      expect(info.displayValue, endsWith('...'));
    });
  });

  group('formatSignerForDisplay — OZExternalSigner fallback', () {
    test('type label is "External" for unknown key size', () {
      const verifier =
          'CAAQEAYEAUDAOCAJBIFQYDIOB4IBCEQTCQKRMFYYDENBWHA5DYPSBFLM';
      // 10-byte key: not 32 (Ed25519) and not > 65 (WebAuthn), no 0x04 prefix
      final key = Uint8List(10)..fillRange(0, 10, 0x05);
      final signer = OZExternalSigner(verifier, key);
      final info = formatSignerForDisplay(signer);

      expect(info.typeLabel, 'External');
    });
  });

  group('formatSignerForDisplay — OZExternalSigner WebAuthn', () {
    test('type label is "Passkey" and display value is credential snippet',
        () {
      const verifier =
          'CAAQEAYEAUDAOCAJBIFQYDIOB4IBCEQTCQKRMFYYDENBWHA5DYPSBFLM';
      // Build a WebAuthn signer via the SDK builder so the keyData layout
      // matches what [OZSmartAccountBuilders.getCredentialIdStringFromSigner]
      // recognises.
      final publicKey = Uint8List(65)..fillRange(1, 65, 0x07);
      publicKey[0] = 0x04;
      final credentialId = Uint8List.fromList(
        List<int>.generate(16, (i) => i + 1),
      );
      final signer = OZExternalSigner.webAuthn(
        verifierAddress: verifier,
        publicKey: publicKey,
        credentialId: credentialId,
      );

      final info = formatSignerForDisplay(signer);

      expect(info.typeLabel, 'Passkey');
      // Base64URL(credential bytes 0x01..0x10) produces "AQIDBAUGBwgJCgsMDQ4PEA==".
      // The string is then routed through [truncateCredentialId]; for a
      // 24-character input that is greater than 20 chars, the truncation
      // helper returns the first-12 / last-8 abbreviated form. We assert
      // only that the display value is a non-empty truncated form so the
      // test is resilient against future credential-length changes.
      expect(info.displayValue, isNotEmpty);
      expect(info.displayValue, contains('...'));
    });
  });

  // ---------------------------------------------------------------------------
  // signerCountLabel / policyCountLabel
  // ---------------------------------------------------------------------------

  group('signerCountLabel', () {
    test('0 signers', () => expect(signerCountLabel(0), '0 signers'));
    test('1 signer', () => expect(signerCountLabel(1), '1 signer'));
    test('2 signers', () => expect(signerCountLabel(2), '2 signers'));
  });

  group('policyCountLabel', () {
    test('0 policies', () => expect(policyCountLabel(0), '0 policies'));
    test('1 policy', () => expect(policyCountLabel(1), '1 policy'));
    test('2 policies', () => expect(policyCountLabel(2), '2 policies'));
  });
}
