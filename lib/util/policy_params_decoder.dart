/// Decoders for the on-chain installation parameters of OZ smart-account
/// policy contracts.
///
/// These helpers consume the raw [XdrSCVal] read from a policy's persistent
/// storage entry (under the `AccountContext` key) and produce a typed
/// [PolicyParams]. They are pure functions with no class state or network
/// dependencies; failures return `null` so callers can fall through to an
/// empty pre-populated form rather than aborting an edit load.
library;

import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import '../flows/context_rule_edit_types.dart';
import 'format_utils.dart';
import 'policy_type.dart';
import 'signer_type_label.dart';

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
/// The stored shape is a map containing a `spending_limit` I128 (stroops)
/// and a `period_ledgers` U32. The decoded result converts the limit to a
/// decimal XLM string and the period to whole days (clamped to at least 1).
PolicyParams? parseSpendingLimitParams(XdrSCVal value) {
  final entries = value.map;
  if (entries == null) return null;

  BigInt? limitStroops;
  int? periodLedgers;

  for (final entry in entries) {
    final symbol = entry.key.sym;
    if (symbol == PolicyType.spendingLimit) {
      limitStroops = scValToI128BigInt(entry.val);
    } else if (symbol == 'period_ledgers') {
      periodLedgers = entry.val.u32?.uint32;
    }
  }

  if (limitStroops == null || periodLedgers == null) return null;

  final xlm = formatStroopsBigIntAsXlm(limitStroops);
  final periodDays = (periodLedgers ~/ _ledgersPerDay).clamp(1, 1 << 31);

  return PolicyParams(
    type: PolicyType.spendingLimit,
    spendingLimit: xlm,
    periodDays: periodDays,
  );
}

/// Parses a `weighted_threshold` policy stored value.
///
/// The stored shape is a map containing a `threshold` U32 and a
/// `signer_weights` map keyed by signer SCVal. Signer keys are flattened to
/// display-only strings via [signerScValKey] so the form can render them
/// even when the underlying signer is no longer present on the rule.
PolicyParams? parseWeightedThresholdParams(XdrSCVal value) {
  final entries = value.map;
  if (entries == null) return null;

  int? threshold;
  Map<String, int>? weights;

  for (final entry in entries) {
    final symbol = entry.key.sym;
    if (symbol == PolicyType.threshold) {
      threshold = entry.val.u32?.uint32;
    } else if (symbol == 'signer_weights') {
      final inner = entry.val.map;
      if (inner == null) continue;
      final parsed = <String, int>{};
      for (final wEntry in inner) {
        final key = signerScValKey(wEntry.key);
        final weight = wEntry.val.u32?.uint32;
        if (weight != null) parsed[key] = weight;
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

/// Returns the canonical display key for a signer encoded as an SCVal.
///
/// The on-chain shape is `Vec([Symbol(type), Address, (Bytes?)])`. The
/// returned string is suitable as a Map key in
/// [PolicyParams.signerWeights]; it does not need to be parseable back to
/// an SDK signer.
String signerScValKey(XdrSCVal scVal) {
  try {
    final vec = scVal.vec;
    if (vec == null || vec.isEmpty) {
      return scVal.discriminant.toString();
    }
    final type = vec[0].sym;
    String addressKey(XdrSCVal entry) {
      final addr = entry.address;
      if (addr == null) return '';
      final asAddress = Address.fromXdr(addr);
      return asAddress.accountId ?? asAddress.contractId ?? '';
    }

    if (type == 'Delegated' && vec.length >= 2) {
      return addressKey(vec[1]);
    }
    if (type == SignerTypeLabel.external && vec.length >= 3) {
      final verifier = addressKey(vec[1]);
      final keyDataLen = vec[2].bytes?.sCBytes.length ?? 0;
      return 'External:$verifier:$keyDataLen';
    }
    return scVal.discriminant.toString();
  } catch (_) {
    return scVal.discriminant.toString();
  }
}

/// Converts an I128 [XdrSCVal] to a [BigInt]. Returns null when [value] is
/// not an I128. Both hi/lo accessors already return [BigInt].
BigInt? scValToI128BigInt(XdrSCVal value) {
  final i128 = value.i128;
  if (i128 == null) return null;
  final lo = i128.lo.uint64;
  final hi = i128.hi.int64;
  return (hi << 64) | lo;
}
