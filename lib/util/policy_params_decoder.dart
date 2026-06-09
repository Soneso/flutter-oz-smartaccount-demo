/// Decoders for the on-chain installation parameters of OZ smart-account
/// policy contracts.
///
/// These helpers consume the raw [XdrSCVal] read from a policy's persistent
/// storage entry (under the `AccountContext` key) and produce a typed
/// [PolicyParams]. They are pure functions with no class state or network
/// dependencies; failures return `null` so callers can fall through to an
/// empty pre-populated form rather than aborting an edit load.
library;

import 'dart:typed_data';

import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import '../flows/context_rule_edit_types.dart';
import 'context_rule_format.dart';
import 'format_utils.dart';
import 'policy_type.dart';

/// Average number of ledgers closed per day on the Stellar network.
const int _ledgersPerDay = Util.ledgersPerDay;

/// Parses a `threshold` policy stored value (bare U32).
PolicyParams? parseThresholdParams(XdrSCVal value) {
  final u32 = value.u32?.uint32;
  if (u32 == null) return null;
  return PolicyParams(type: PolicyType.threshold, threshold: u32);
}

/// Parses a `spending_limit` policy stored value.
///
/// The stored shape is a map containing a `spending_limit` I128 (base units)
/// and a `period_ledgers` U32. The decoded result formats the limit to a
/// decimal string at [decimals] scale, so the inline editor pre-populates with
/// the exact stored amount regardless of the guarded token's precision.
/// The period is converted to whole days, clamped to at least 1.
///
/// [decimals] must be the decimal scale of the guarded token. For the native
/// XLM token pass [nativeTokenDecimals] (7). A failed scale resolution at the
/// call site should return null rather than passing a wrong value here.
PolicyParams? parseSpendingLimitParams(XdrSCVal value, {required int decimals}) {
  final entries = value.map;
  if (entries == null) return null;

  BigInt? limitBaseUnits;
  int? periodLedgers;

  for (final entry in entries) {
    final symbol = entry.key.sym;
    if (symbol == PolicyType.spendingLimit) {
      limitBaseUnits = scValToI128BigInt(entry.val);
    } else if (symbol == 'period_ledgers') {
      periodLedgers = entry.val.u32?.uint32;
    }
  }

  if (limitBaseUnits == null || periodLedgers == null) return null;

  final amountStr = formatBaseUnitsAsDecimal(limitBaseUnits, decimals: decimals);
  final periodDays = (periodLedgers ~/ _ledgersPerDay).clamp(1, 1 << 31);

  return PolicyParams(
    type: PolicyType.spendingLimit,
    spendingLimit: amountStr,
    periodDays: periodDays,
  );
}

/// Parses a `weighted_threshold` policy stored value.
///
/// The stored shape is a map containing a `threshold` U32 and a
/// `signer_weights` map keyed by signer SCVal. Each signer SCVal is
/// reconstructed into a typed [OZSmartAccountSigner] (or a fallback display
/// entry when reconstruction fails) so the form can render per-signer rows
/// identically to the Signers section.
PolicyParams? parseWeightedThresholdParams(XdrSCVal value) {
  final entries = value.map;
  if (entries == null) return null;

  int? threshold;
  List<WeightedSignerEntry>? weights;

  for (final entry in entries) {
    final symbol = entry.key.sym;
    if (symbol == PolicyType.threshold) {
      threshold = entry.val.u32?.uint32;
    } else if (symbol == 'signer_weights') {
      final inner = entry.val.map;
      if (inner == null) continue;
      final parsed = <WeightedSignerEntry>[];
      for (final wEntry in inner) {
        final weight = wEntry.val.u32?.uint32;
        if (weight == null) continue;
        parsed.add(_weightedEntryFromScVal(wEntry.key, weight));
      }
      weights = parsed;
    }
  }

  if (threshold == null) return null;
  return PolicyParams(
    type: PolicyType.weightedThreshold,
    threshold: threshold,
    signerWeights: weights,
  );
}

/// Reconstructs a [WeightedSignerEntry] from a signer SCVal and its weight.
///
/// Attempts to construct a typed [OZSmartAccountSigner] from the on-chain
/// Vec shape. When reconstruction succeeds [WeightedSignerEntry.signer] is
/// non-null and [WeightedSignerEntry.displayInfo] is derived from
/// [formatSignerForDisplay]. When reconstruction fails, display info is
/// synthesised from the raw SCVal so the row always renders something.
WeightedSignerEntry _weightedEntryFromScVal(XdrSCVal scVal, int weight) {
  try {
    final signer = reconstructSignerFromScVal(scVal);
    if (signer != null) {
      final info = formatSignerForDisplay(signer);
      return WeightedSignerEntry(
        weight: weight,
        signer: signer,
        displayInfo: info,
        stableKey: signer.uniqueKey,
      );
    }
  } catch (_) {
    // Fall through to the fallback path below.
  }

  // Reconstruction failed: synthesise a display-only entry from the raw SCVal.
  final fallback = _signerScValFallbackKey(scVal);
  return WeightedSignerEntry(
    weight: weight,
    fallbackDisplay: fallback,
    displayInfo: SignerDisplayInfo(
      typeLabel: 'Unknown',
      displayValue: truncateAddress(fallback, chars: 6),
    ),
    stableKey: fallback,
  );
}

/// Attempts to reconstruct a typed [OZSmartAccountSigner] from a signer SCVal.
///
/// The on-chain signer shape is `Vec([Symbol(type), Address, (Bytes?)])`.
///
/// - `Vec([Symbol("Delegated"), Address(G-or-C-address)])` → [OZDelegatedSigner]
/// - `Vec([Symbol("External"), Address(verifier-contract), Bytes(keyData)])` →
///   [OZExternalSigner]
///
/// Contract addresses in the XDR come back as hex strings from
/// [Address.fromXdr]; they are converted to C-strkeys via
/// [StrKey.encodeContractIdHex] before constructing the signer. Account
/// addresses come back as G-strkeys and are passed through unchanged.
///
/// Returns null when the shape is unrecognised or when the SDK constructor
/// rejects the address / key data.
OZSmartAccountSigner? reconstructSignerFromScVal(XdrSCVal scVal) {
  final vec = scVal.vec;
  if (vec == null || vec.isEmpty) return null;

  final type = vec[0].sym;
  if (type == null) return null;

  if (type == 'Delegated' && vec.length >= 2) {
    final xdrAddr = vec[1].address;
    if (xdrAddr == null) return null;
    final addr = Address.fromXdr(xdrAddr);
    // Account addresses decode to G-strkeys directly; contract addresses
    // decode to a hex string and must be re-encoded as C-strkeys.
    final strkey =
        addr.accountId ?? _hexToContractStrkey(addr.contractId ?? '');
    if (strkey == null) return null;
    return OZDelegatedSigner(strkey);
  }

  if (type == 'External' && vec.length >= 3) {
    final xdrVerifier = vec[1].address;
    final keyBytes = vec[2].bytes?.sCBytes;
    if (xdrVerifier == null || keyBytes == null || keyBytes.isEmpty) {
      return null;
    }
    final verifierAddr = Address.fromXdr(xdrVerifier);
    // Verifier addresses are always contract addresses; convert hex → C-strkey.
    final verifierStrkey =
        _hexToContractStrkey(verifierAddr.contractId ?? '');
    if (verifierStrkey == null) return null;
    return OZExternalSigner(verifierStrkey, Uint8List.fromList(keyBytes));
  }

  return null;
}

/// Converts a 32-byte lowercase hex contract ID to a C-strkey.
///
/// Returns null when [hex] is empty, odd-length, or [StrKey.encodeContractIdHex]
/// throws (i.e. not a valid 32-byte hex string).
String? _hexToContractStrkey(String hex) {
  if (hex.isEmpty) return null;
  try {
    return StrKey.encodeContractIdHex(hex);
  } catch (_) {
    return null;
  }
}

/// Raw fallback key for a signer SCVal when typed reconstruction fails.
///
/// Produces a human-readable string from the SCVal structure so the edit
/// form never displays a blank row. Not used for any on-chain operation.
String _signerScValFallbackKey(XdrSCVal scVal) {
  try {
    final vec = scVal.vec;
    if (vec == null || vec.isEmpty) return scVal.discriminant.toString();
    final type = vec[0].sym ?? '?';
    if (vec.length >= 2) {
      final addr = vec[1].address;
      if (addr != null) {
        final a = Address.fromXdr(addr);
        final raw = a.accountId ?? a.contractId ?? '';
        return '$type:${truncateAddress(raw)}';
      }
    }
    return type;
  } catch (_) {
    return scVal.discriminant.toString();
  }
}

/// Converts an I128 [XdrSCVal] to a [BigInt]. Returns null when [value] is
/// not an I128.
BigInt? scValToI128BigInt(XdrSCVal value) => scValI128ToBigIntOrNull(value);
