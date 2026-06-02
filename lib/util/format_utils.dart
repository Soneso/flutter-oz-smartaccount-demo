/// Formatting utilities: addresses, amounts, signers, and hex encoding.
library;

import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart'
    show StrKey;

/// Number of stroops in one XLM (Stellar's 7-decimal native unit).
const int stroopsPerXlm = 10000000;

/// [BigInt] form of [stroopsPerXlm] for divisor use in the high-precision
/// I128 stroop formatter.
final BigInt _stroopsPerXlmBigInt = BigInt.from(stroopsPerXlm);

// ---------------------------------------------------------------------------
// Input validation
// ---------------------------------------------------------------------------

/// Returns true if [input] is a non-blank, valid Stellar contract address.
///
/// Delegates to [StrKey.isValidContractId] which performs full StrKey base32
/// decoding and CRC-16 checksum verification. Trims surrounding whitespace
/// before validating.
bool isValidContractAddress(String input) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) return false;
  return StrKey.isValidContractId(trimmed);
}

/// Returns true if [input] is a non-blank, valid Stellar account address.
///
/// An account address (G-address) starts with 'G' and is 56 characters long.
bool isValidAccountAddress(String input) {
  if (input.isEmpty) return false;
  if (input[0] != 'G') return false;
  if (input.length != 56) return false;
  final base32Chars = RegExp(r'^[A-Z2-7]+$');
  return base32Chars.hasMatch(input);
}

/// Returns true if [input] is composed exclusively of lowercase hexadecimal
/// characters (`0`-`9`, `a`-`f`). An empty string returns false.
///
/// Callers should lowercase the input first if they wish to accept
/// upper-case hex; this helper deliberately matches only the lowercase
/// alphabet so it can be paired with `text.trim().toLowerCase()`.
bool isValidHex(String input) {
  if (input.isEmpty) return false;
  return _lowerHexPattern.hasMatch(input);
}

final RegExp _lowerHexPattern = RegExp(r'^[0-9a-f]+$');

/// Compiled regex matching a non-negative decimal amount with up to seven
/// fractional digits (Stellar's stroop precision). Rejects scientific
/// notation, leading signs, and any input containing more than seven
/// digits after the decimal point.
final RegExp stellarDecimalAmountPattern = RegExp(r'^\d+(\.\d{1,7})?$');

// ---------------------------------------------------------------------------
// Address truncation
// ---------------------------------------------------------------------------

/// Truncates an address to [chars] characters on each end for display.
///
/// Example: truncateAddress('GABCDEFGHIJKLMNOPQRSTUVWXYZ', chars: 4)
/// → 'GABC...WXYZ'.
/// Returns [address] unchanged when its length is [chars]*2 + 3 or less.
String truncateAddress(String address, {int chars = 4}) {
  if (address.length <= chars * 2 + 3) return address;
  final start = address.substring(0, chars);
  final end = address.substring(address.length - chars);
  return '$start...$end';
}

// ---------------------------------------------------------------------------
// Amount formatting
// ---------------------------------------------------------------------------

/// Formats a stroops amount as an XLM display string.
///
/// Uses integer arithmetic to avoid floating-point precision issues.
/// 1 XLM = [stroopsPerXlm] stroops (7 decimal places).
///
/// Handles [int.minValue] as an edge case to avoid negation overflow.
/// Examples: 1 XLM in stroops → "1.0", 500 000 stroops → "0.05".
String formatStroopsAsXlm(int stroops) {
  if (stroops == -9223372036854775808) {
    // int.minValue cannot be negated without overflow.
    return '-922337203685.4775808';
  }
  final negative = stroops < 0;
  final absStroops = negative ? -stroops : stroops;
  final wholePart = absStroops ~/ stroopsPerXlm;
  final fractionalPart = absStroops % stroopsPerXlm;
  final fractionalStr = fractionalPart
      .toString()
      .padLeft(7, '0')
      .replaceAll(RegExp(r'0+$'), '');
  final fractional = fractionalStr.isEmpty ? '0' : fractionalStr;
  final prefix = negative ? '-' : '';
  return '$prefix$wholePart.$fractional';
}

/// [BigInt] overload of [formatStroopsAsXlm].
///
/// Used by paths that read an I128 stroop amount from an SCVal and must
/// preserve the full 128-bit range without truncating to [int]. Trailing
/// zeros in the fractional component are stripped; when the amount has no
/// fractional remainder the integer portion is returned by itself (e.g.
/// `"100"` rather than `"100.0"`).
String formatStroopsBigIntAsXlm(BigInt stroops) {
  // 1 XLM = 10_000_000 stroops; held as a [BigInt] to avoid lifting the
  // input into a fixed-width integer.
  final divisor = _stroopsPerXlmBigInt;
  final negative = stroops.sign < 0;
  final absStroops = negative ? -stroops : stroops;
  final whole = absStroops ~/ divisor;
  final remainder = absStroops % divisor;
  final prefix = negative ? '-' : '';
  if (remainder == BigInt.zero) return '$prefix$whole';
  final fractional = remainder
      .toString()
      .padLeft(7, '0')
      .replaceAll(RegExp(r'0+$'), '');
  if (fractional.isEmpty) return '$prefix$whole';
  return '$prefix$whole.$fractional';
}

/// Converts a regex-validated decimal amount string to integer stroops using
/// split-then-multiply integer arithmetic.
///
/// Returns null when the lift would overflow int64 (whole > 922337203685) or
/// when either component fails to parse. The fractional portion is padded
/// to seven digits before being combined with the whole portion.
///
/// Input must already be regex-validated by [stellarDecimalAmountPattern]
/// or equivalent so this helper can assume the format is well-formed.
int? decimalToStroops(String amountRaw) {
  final parts = amountRaw.split('.');
  final wholeStr = parts[0];
  final fracStr = parts.length == 2 ? parts[1] : '';
  final whole = int.tryParse(wholeStr);
  final fracPadded = fracStr.padRight(7, '0');
  final frac = fracPadded.isEmpty ? 0 : int.tryParse(fracPadded);
  if (whole == null || frac == null) return null;
  // Safe multiplication: whole values up to ~9.2e11 stroops worth of XLM
  // still fit in int64 after the * 10_000_000 lift.
  if (whole > 922337203685) return null;
  return whole * stroopsPerXlm + frac;
}

// ---------------------------------------------------------------------------
// Truncation helpers
// ---------------------------------------------------------------------------

/// Returns the display form of a WebAuthn credential ID.
///
/// Format: `'${credentialId.substring(0, 12)}...${credentialId.substring(len - 8)}'`
/// followed by `' (${nickname})'` when a nickname is set.
/// Returns [credentialId] unchanged when it is 20 characters or shorter.
String truncateCredentialId(String credentialId, {String? nickname}) {
  final String base;
  if (credentialId.length > 20) {
    base =
        '${credentialId.substring(0, 12)}...${credentialId.substring(credentialId.length - 8)}';
  } else {
    base = credentialId;
  }
  if (nickname != null && nickname.isNotEmpty) {
    return '$base ($nickname)';
  }
  return base;
}

/// Returns the display form of a contract ID (C-address).
///
/// Format: `'${contractId.substring(0, 12)}...${contractId.substring(len - 12)}'`
/// or `'Unknown'` when null.
/// Returns [contractId] unchanged when it is 24 characters or shorter.
String truncateContractId(String? contractId) {
  if (contractId == null) return 'Unknown';
  if (contractId.length > 24) {
    return '${contractId.substring(0, 12)}...${contractId.substring(contractId.length - 12)}';
  }
  return contractId;
}

// ---------------------------------------------------------------------------
// Redaction helpers
// ---------------------------------------------------------------------------

/// Returns a short redacted representation of [id] for assistive-technology
/// labels and activity-log entries.
///
/// Keeps the first 8 and last 8 characters separated by "..." so the value
/// remains identifiable without reading the full opaque string aloud.
/// Returns [id] unchanged when it is 16 characters or shorter.
String redactId(String id) {
  if (id.length <= 16) return id;
  return '${id.substring(0, 8)}...${id.substring(id.length - 8)}';
}

// ---------------------------------------------------------------------------
// Hex encoding
// ---------------------------------------------------------------------------

/// Converts a hex string to a [List<int>] (byte list).
///
/// [hex] must have even length and contain only valid hex characters.
/// Throws [ArgumentError] on odd-length or invalid input.
List<int> hexToBytes(String hex) {
  if (hex.length % 2 != 0) {
    throw ArgumentError('Hex string must have even length: $hex');
  }
  final result = <int>[];
  for (var i = 0; i < hex.length; i += 2) {
    result.add(int.parse(hex.substring(i, i + 2), radix: 16));
  }
  return result;
}

/// Converts a [List<int>] to a lowercase hex string.
String bytesToHex(List<int> bytes) {
  final buffer = StringBuffer();
  for (final byte in bytes) {
    buffer.write((byte & 0xFF).toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}
