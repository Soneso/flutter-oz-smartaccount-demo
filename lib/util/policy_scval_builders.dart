/// XDR SCVal builders for the three built-in OpenZeppelin policy types.
///
/// Each builder produces an [XdrSCVal] map matching the on-chain schema
/// expected by the policy contracts deployed on testnet.
///
/// On-chain schemas (symbol-keyed maps):
///
/// **SimpleThreshold:**
///   `{ "threshold": U32(n) }`
///
/// **SpendingLimit:**
///   `{ "period_ledgers": U32(n), "spending_limit": I128(stroops) }`
///
/// **WeightedThreshold:**
///   `{ "signer_weights": Map[Signer -> U32], "threshold": U32(n) }`
///   — signer_weights map entries are sorted by XDR byte order.
///
/// [OZPolicyManager.sortMapByKeyXdr] is used for deterministic key ordering in
/// the weighted threshold builder, ensuring deterministic, contract-required
/// key ordering.
library;

import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import 'policy_type.dart';

/// Builds the [XdrSCVal] for a simple threshold policy.
///
/// Validates that [threshold] >= 1, then encodes:
/// `{ "threshold": U32(threshold) }`.
///
/// On-chain schema: a single-entry SCVal map with a Symbol key.
///
/// Throws [ValidationException.invalidInput] when [threshold] < 1.
XdrSCVal buildSimpleThresholdScVal({required int threshold}) {
  // Delegate validation to the SDK builder, which throws [ValidationException]
  // with a consistent error message when threshold < 1.
  OZSmartAccountBuilders.createThresholdParams(threshold);

  final entries = <XdrSCMapEntry>[
    XdrSCMapEntry(
      XdrSCVal.forSymbol(PolicyType.threshold),
      XdrSCVal.forU32(threshold),
    ),
  ];
  return XdrSCVal.forMap(entries);
}

/// Builds the [XdrSCVal] for a spending limit policy.
///
/// [limit] is the maximum spending amount in stroops. [periodLedgers] is the
/// reset period in ledgers.
///
/// Encodes:
/// `{ "period_ledgers": U32(periodLedgers), "spending_limit": I128(limit) }`
///
/// The current deployed policy contract enforces a per-ledger global spending
/// limit — there is no per-token field in the on-chain map.
///
/// Throws [ValidationException.invalidInput] when [periodLedgers] < 1.
/// Throws [ValidationException.invalidAmount] when [limit] is not positive.
XdrSCVal buildSpendingLimitScVal({
  required int limit,
  required int periodLedgers,
}) {
  if (limit <= 0) {
    throw ValidationException.invalidAmount(
      limit.toString(),
      reason: 'must be greater than zero',
    );
  }
  if (periodLedgers < 1) {
    throw ValidationException.invalidInput(
      'periodLedgers',
      'Period must be at least 1 ledger, got: $periodLedgers',
    );
  }

  // I128 encoding of the limit value in stroops.
  final limitI128 = Util.stroopsToI128ScVal(BigInt.from(limit));

  final entries = <XdrSCMapEntry>[
    XdrSCMapEntry(
      XdrSCVal.forSymbol('period_ledgers'),
      XdrSCVal.forU32(periodLedgers),
    ),
    XdrSCMapEntry(
      XdrSCVal.forSymbol(PolicyType.spendingLimit),
      limitI128,
    ),
  ];
  return XdrSCVal.forMap(entries);
}

/// Builds the [XdrSCVal] for a weighted threshold policy.
///
/// [weights] is a list of `(signer, weight)` records where each [signer] is the
/// on-chain SCVal representation of the signer (produced by
/// [OZSmartAccountSigner.toScVal] or any other XDR value acceptable to the
/// policy contract) and [weight] is a positive integer. [threshold] is the
/// minimum total weight required for authorization.
///
/// Encodes:
/// `{ "signer_weights": Map[Signer -> U32(weight)], "threshold": U32(threshold) }`
///
/// The signer_weights inner map entries are sorted by XDR byte order (required
/// by the on-chain contract for deterministic hashing). The outer map keys
/// are fixed-order symbol strings.
///
/// Throws [ValidationException.invalidInput] when:
/// - [threshold] < 1
/// - any [weight] < 1
/// - [weights] is empty
/// - the total weight < [threshold]
XdrSCVal buildWeightedThresholdScVal({
  required List<({XdrSCVal signer, int weight})> weights,
  required int threshold,
}) {
  if (threshold < 1) {
    throw ValidationException.invalidInput(
      PolicyType.threshold,
      'Threshold must be at least 1, got: $threshold',
    );
  }
  if (weights.isEmpty) {
    throw ValidationException.invalidInput(
      'weights',
      'At least one signer weight must be provided',
    );
  }

  var totalWeight = 0;
  for (final entry in weights) {
    if (entry.weight < 1) {
      throw ValidationException.invalidInput(
        'weights',
        'All weights must be positive integers, got: ${entry.weight}',
      );
    }
    totalWeight += entry.weight;
  }

  if (totalWeight < threshold) {
    throw ValidationException.invalidInput(
      'weights',
      'Sum of weights ($totalWeight) must be >= threshold ($threshold)',
    );
  }

  // Build the signer_weights inner map entries. Sort by XDR key byte order
  // so the contract hash is deterministic regardless of input order.
  final weightEntries = <XdrSCMapEntry>[
    for (final entry in weights)
      XdrSCMapEntry(
        entry.signer,
        XdrSCVal.forU32(entry.weight),
      ),
  ];
  final sortedWeightEntries = OZPolicyManager.sortMapByKeyXdr(weightEntries);

  final outerEntries = <XdrSCMapEntry>[
    XdrSCMapEntry(
      XdrSCVal.forSymbol('signer_weights'),
      XdrSCVal.forMap(sortedWeightEntries),
    ),
    XdrSCMapEntry(
      XdrSCVal.forSymbol(PolicyType.threshold),
      XdrSCVal.forU32(threshold),
    ),
  ];
  return XdrSCVal.forMap(outerEntries);
}
