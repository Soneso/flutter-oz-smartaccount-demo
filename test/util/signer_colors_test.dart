import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_account_demo/util/signer_colors.dart';

void main() {
  group('signerTypeColor', () {
    test('Passkey (WebAuthn) returns purple', () {
      expect(signerTypeColor('Passkey (WebAuthn)'), equals(const Color(0xFF9C27B0)));
    });

    test('Stellar Account returns blue', () {
      expect(signerTypeColor('Stellar Account'), equals(const Color(0xFF2196F3)));
    });

    test('Ed25519 returns teal', () {
      expect(signerTypeColor('Ed25519'), equals(const Color(0xFF009688)));
    });

    test('unknown signer type returns blue-grey fallback', () {
      expect(signerTypeColor('Unknown'), equals(const Color(0xFF607D8B)));
    });

    test('empty string returns blue-grey fallback', () {
      expect(signerTypeColor(''), equals(const Color(0xFF607D8B)));
    });

    test('partial match does not return the match color (case-sensitive)', () {
      // 'passkey' (lowercase) must not match 'Passkey (WebAuthn)'.
      expect(signerTypeColor('passkey'), equals(const Color(0xFF607D8B)));
    });
  });
}
