/// Formatting utilities: addresses, amounts, signers, and hex encoding.
library;

import 'dart:typed_data';

import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart'
    show StrKey, Util, XdrSCVal, isHexString;

/// Decimal scale of the native XLM token (7). Used to convert native-token
/// amounts to base units without an on-chain `decimals()` round trip.
const int nativeTokenDecimals = 7;

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
/// Delegates to [StrKey.isValidStellarAccountId] which performs full StrKey
/// base32 decoding and CRC-16 checksum verification of the G-address.
bool isValidAccountAddress(String input) {
  return input.isNotEmpty && StrKey.isValidStellarAccountId(input);
}

/// Returns true if [input] is composed exclusively of lowercase hexadecimal
/// characters (`0`-`9`, `a`-`f`). An empty string returns false.
///
/// Callers should lowercase the input first if they wish to accept
/// upper-case hex; this helper deliberately matches only the lowercase
/// alphabet so it can be paired with `text.trim().toLowerCase()`.
/// Delegates to the SDK `isHexString` but adds the lowercase-only contract.
bool isValidHex(String input) {
  if (input.isEmpty) return false;
  return isHexString(input) && input == input.toLowerCase();
}

/// Compiled regex matching a non-negative decimal amount with up to seven
/// fractional digits (Stellar's stroop precision). Rejects scientific
/// notation, leading signs, and any input containing more than seven
/// digits after the decimal point.
final RegExp stellarDecimalAmountPattern = RegExp(r'^\d+(\.\d{1,7})?$');

// ---------------------------------------------------------------------------
// Address validation
// ---------------------------------------------------------------------------

/// Validates [value] as a Stellar G-address or C-address.
///
/// Returns null when:
/// - [value] is empty (field is not yet filled — forms should not flag on
///   initial render).
/// - [value] is a valid Stellar G-address ([StrKey.isValidStellarAccountId])
///   or C-address ([StrKey.isValidContractId]).
///
/// Returns the validation error string when [value] is a non-empty,
/// non-address string.
///
/// When [selfAddress] is provided, returns a self-transfer error when
/// [value] equals [selfAddress].
String? validateStellarAddress(String value, {String? selfAddress}) {
  if (value.isEmpty) return null;
  if (!StrKey.isValidStellarAccountId(value) &&
      !StrKey.isValidContractId(value)) {
    return 'Must be a valid Stellar account (G...) or contract (C...) address';
  }
  if (selfAddress != null && value == selfAddress) {
    return 'Cannot transfer to your own account';
  }
  return null;
}

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

/// Converts a base-units [BigInt] amount to a decimal display string at the
/// given [decimals] scale.
///
/// Strips trailing fractional zeros. When there is no fractional remainder
/// the integer portion is returned without a decimal point (e.g. `"100"` not
/// `"100.0"`).
String formatBaseUnitsAsDecimal(BigInt baseUnits, {required int decimals}) {
  if (decimals <= 0) return baseUnits.toString();
  final divisor = BigInt.from(10).pow(decimals);
  final negative = baseUnits.sign < 0;
  final abs = negative ? -baseUnits : baseUnits;
  final whole = abs ~/ divisor;
  final remainder = abs % divisor;
  final prefix = negative ? '-' : '';
  if (remainder == BigInt.zero) return '$prefix$whole';
  final fractional = remainder
      .toString()
      .padLeft(decimals, '0')
      .replaceAll(RegExp(r'0+$'), '');
  if (fractional.isEmpty) return '$prefix$whole';
  return '$prefix$whole.$fractional';
}

/// Formats a stroops [BigInt] amount as an XLM display string at the native
/// 7-decimal scale.
///
/// Reads an I128 stroop amount from an SCVal while preserving the full
/// 128-bit range. Trailing zeros in the fractional component are stripped;
/// when the amount has no fractional remainder the integer portion is
/// returned by itself (e.g. `"100"` rather than `"100.0"`).
String formatStroopsBigIntAsXlm(BigInt stroops) {
  return Util.stroopsToDecimalString(stroops);
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
// Address helpers
// ---------------------------------------------------------------------------

/// Encodes a Stellar address StrKey as an address [XdrSCVal].
///
/// Delegates to [XdrSCVal.forAddressStrKey], which detects the StrKey type
/// (G-account, C-contract, muxed, claimable balance, or liquidity pool) and
/// throws on an unrecognised StrKey. The caller is responsible for supplying
/// a valid Stellar address.
XdrSCVal addressToScVal(String address) {
  return XdrSCVal.forAddressStrKey(address);
}

// ---------------------------------------------------------------------------
// SCVal helpers
// ---------------------------------------------------------------------------

/// Decodes an i128 [XdrSCVal] into a signed [BigInt].
///
/// Returns null when [value] is not a 128-bit or 256-bit integer SCVal. The
/// decode is two's-complement sign-aware, so negative i128 values round-trip
/// correctly across the full 128-bit signed range.
BigInt? scValI128ToBigIntOrNull(XdrSCVal value) {
  return value.toBigInt();
}

// ---------------------------------------------------------------------------
// Hex encoding
// ---------------------------------------------------------------------------

/// Converts a hex string to a [Uint8List] of bytes.
///
/// [hex] must have even length and contain only valid hex characters.
/// Throws [FormatException] on odd-length or invalid input.
Uint8List hexToBytes(String hex) {
  return Util.hexToBytes(hex);
}

/// Converts a [List<int>] to a lowercase hex string.
String bytesToHex(List<int> bytes) {
  return Util.bytesToHex(Uint8List.fromList(bytes));
}
