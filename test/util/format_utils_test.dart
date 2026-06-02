import 'package:flutter_test/flutter_test.dart';
import 'package:smart_account_demo/util/format_utils.dart';

void main() {
  // ---------------------------------------------------------------------------
  // truncateAddress
  // ---------------------------------------------------------------------------

  group('truncateAddress', () {
    test('long address is truncated to start...end', () {
      const addr = 'GABC1234567890WXYZ'; // 18 chars — longer than 4+3+4=11
      final result = truncateAddress(addr);
      expect(result, 'GABC...WXYZ');
    });

    test('short address is returned unchanged', () {
      const addr = 'GABCWXYZ'; // 8 chars <= 4*2+3=11
      final result = truncateAddress(addr);
      expect(result, addr);
    });

    test('empty address returns empty string', () {
      expect(truncateAddress(''), '');
    });

    test('address exactly at boundary returned unchanged', () {
      // chars=4: boundary = 4*2+3 = 11
      const addr = 'GABC1234WXY'; // exactly 11 chars
      expect(truncateAddress(addr), addr);
    });

    test('custom chars parameter controls cut', () {
      const addr = 'GABCDE12345WXYZ';
      // chars=3: start=GAB, end=XYZ → 'GAB...XYZ'
      final result = truncateAddress(addr, chars: 3);
      expect(result, equals('GAB...XYZ'));
    });

    test('full 56-char Stellar G-address is truncated', () {
      const addr = 'GBBD47IF6LWK7P7MDEVSCWR7DPUWV3NY3DTQEVFL4NAT4AQH3ZLLFLA5';
      expect(addr, hasLength(56));
      final result = truncateAddress(addr);
      // Default chars=4: first 4 = 'GBBD', last 4 = 'FLA5'.
      expect(result, equals('GBBD...FLA5'));
    });
  });

  // ---------------------------------------------------------------------------
  // isValidContractAddress
  // ---------------------------------------------------------------------------

  group('isValidContractAddress', () {
    test('valid C-prefix 56-char address returns true', () {
      // StrKey.encodeContractId(Uint8List(32)) — all-zeroes 32-byte buffer,
      // produces a fully checksummed C-address that passes CRC-16 verification.
      const addr = 'CAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABSC4';
      expect(addr, hasLength(56));
      expect(isValidContractAddress(addr), isTrue);
    });

    test('G-prefix address returns false', () {
      const addr = 'GBBD47IF6LWK7P7MDEVSCWR7DPUWV3NY3DTQEVFL4NAT4AQH3ZLLFLA5';
      expect(isValidContractAddress(addr), isFalse);
    });

    test('wrong length returns false', () {
      expect(isValidContractAddress('CABC'), isFalse);
    });

    test('empty string returns false', () {
      expect(isValidContractAddress(''), isFalse);
    });

    test('contains lowercase returns false', () {
      // base32 must be uppercase; lowercase = invalid
      final mixed = 'C${'a' * 55}';
      expect(isValidContractAddress(mixed), isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // isValidAccountAddress
  // ---------------------------------------------------------------------------

  group('isValidAccountAddress', () {
    test('valid G-prefix 56-char address returns true', () {
      const addr = 'GBBD47IF6LWK7P7MDEVSCWR7DPUWV3NY3DTQEVFL4NAT4AQH3ZLLFLA5';
      expect(addr, hasLength(56));
      expect(isValidAccountAddress(addr), isTrue);
    });

    test('C-prefix address returns false', () {
      const addr = 'CAAAB5A5XLD4TVJNQJGLXFBH3SCPJBHBPLKQACQ6VLLHLZJOLILPIXQ';
      expect(isValidAccountAddress(addr), isFalse);
    });

    test('wrong length returns false', () {
      expect(isValidAccountAddress('GABC'), isFalse);
    });

    test('empty string returns false', () {
      expect(isValidAccountAddress(''), isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // formatStroopsAsXlm
  // ---------------------------------------------------------------------------

  group('formatStroopsAsXlm', () {
    test('zero returns 0.0', () {
      expect(formatStroopsAsXlm(0), '0.0');
    });

    test('1 XLM in stroops returns 1.0', () {
      expect(formatStroopsAsXlm(10000000), '1.0');
    });

    test('fractional XLM', () {
      expect(formatStroopsAsXlm(500000), '0.05');
    });

    test('negative amount', () {
      expect(formatStroopsAsXlm(-10000000), '-1.0');
    });

    test('int.minValue does not overflow', () {
      expect(
        formatStroopsAsXlm(-9223372036854775808),
        equals('-922337203685.4775808'),
      );
    });

    test('trailing zeros are trimmed', () {
      // 1.5 XLM = 15000000 stroops → '1.5', not '1.5000000'
      expect(formatStroopsAsXlm(15000000), equals('1.5'));
    });

    test('all-zero fractional part displays as whole number', () {
      expect(formatStroopsAsXlm(20000000), equals('2.0'));
    });
  });

  // ---------------------------------------------------------------------------
  // hexToBytes / bytesToHex round-trip
  // ---------------------------------------------------------------------------

  group('hexToBytes', () {
    test('lowercase hex decodes correctly', () {
      expect(hexToBytes('deadbeef'), equals([0xDE, 0xAD, 0xBE, 0xEF]));
    });

    test('uppercase hex decodes correctly', () {
      expect(hexToBytes('DEADBEEF'), equals([0xDE, 0xAD, 0xBE, 0xEF]));
    });

    test('empty hex returns empty list', () {
      expect(hexToBytes(''), isEmpty);
    });

    test('odd-length hex throws ArgumentError', () {
      expect(() => hexToBytes('abc'), throwsArgumentError);
    });

    test('invalid character throws FormatException', () {
      expect(() => hexToBytes('zz'), throwsA(isA<FormatException>()));
    });
  });

  group('bytesToHex', () {
    test('known bytes produce lowercase hex', () {
      expect(bytesToHex([0xDE, 0xAD, 0xBE, 0xEF]), equals('deadbeef'));
    });

    test('empty list produces empty string', () {
      expect(bytesToHex([]), equals(''));
    });

    test('single zero byte produces 00', () {
      expect(bytesToHex([0x00]), equals('00'));
    });
  });

  group('hexToBytes / bytesToHex round-trip', () {
    test('arbitrary bytes survive a round-trip', () {
      final original = [0x00, 0x01, 0x7F, 0x80, 0xFF];
      expect(hexToBytes(bytesToHex(original)), equals(original));
    });
  });
}
