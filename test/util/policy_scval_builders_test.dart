/// XDR encoding tests for [buildSimpleThresholdScVal],
/// [buildSpendingLimitScVal], and [buildWeightedThresholdScVal].
///
/// These tests pin the exact on-chain encoding produced by each builder. Any
/// drift between the Flutter and iOS [PolicyScValBuilders] implementations will
/// surface when comparing XDR bytes against the shared fixture constants below.
/// The fixture values were computed once from the SDK's XDR encoder and are
/// byte-identical to the iOS test fixtures in
/// `Tests/UtilTests/PolicyScValBuildersTests.swift`.
///
/// Tests do not require network access — all assertions are pure in-process
/// XDR encoding.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_account_demo/util/policy_scval_builders.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

// ---------------------------------------------------------------------------
// Cross-platform XDR base64 fixture constants
// ---------------------------------------------------------------------------

/// XDR base64 fixture for [buildSimpleThresholdScVal] with threshold=3:
///   SCVal::Map [ Symbol("threshold") => U32(3) ]
///
/// Byte-identical to [PolicyScValBuildersTests.simpleThreshold3Fixture] in
/// the iOS implementation.
const _simpleThreshold3Fixture =
    'AAAAEQAAAAEAAAABAAAADwAAAAl0aHJlc2hvbGQAAAAAAAADAAAAAw==';

/// XDR base64 fixture for [buildSpendingLimitScVal] with limit=1_000_000,
/// periodLedgers=100:
///   SCVal::Map [ Symbol("period_ledgers") => U32(100),
///                Symbol("spending_limit") => I128(0, 1_000_000) ]
///
/// Byte-identical to [PolicyScValBuildersTests.spendingLimit1mPer100Fixture]
/// in the iOS implementation.
const _spendingLimit1mPer100Fixture =
    'AAAAEQAAAAEAAAACAAAADwAAAA5wZXJpb2RfbGVkZ2VycwAAAAAAAwAAAGQAAAAP'
    'AAAADnNwZW5kaW5nX2xpbWl0AAAAAAAKAAAAAAAAAAAAAAAAAA9CQA==';

/// XDR base64 fixture for [buildWeightedThresholdScVal] with
/// weights=[(Bytes([0xAA,0xBB]) => 1)], threshold=1:
///   SCVal::Map [ Symbol("signer_weights") => Map[ Bytes([0xAA,0xBB]) => U32(1) ],
///                Symbol("threshold")      => U32(1) ]
///
/// Byte-identical to [PolicyScValBuildersTests.weightedThreshold1Fixture] in
/// the iOS implementation.
const _weightedThreshold1Fixture =
    'AAAAEQAAAAEAAAACAAAADwAAAA5zaWduZXJfd2VpZ2h0cwAAAAAAEQAAAAEAAAAB'
    'AAAADQAAAAKquwAAAAAAAwAAAAEAAAAPAAAACXRocmVzaG9sZAAAAAAAAAMAAAAB';

// ---------------------------------------------------------------------------
// Helper: XDR-encode an XdrSCVal to base64
// ---------------------------------------------------------------------------

String _xdrBase64(XdrSCVal val) {
  final stream = XdrDataOutputStream();
  XdrSCVal.encode(stream, val);
  return base64Encode(stream.bytes);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('buildSimpleThresholdScVal', () {
    test('encodes threshold as U32 in a map', () {
      final val = buildSimpleThresholdScVal(threshold: 2);
      expect(val.discriminant, XdrSCValType.SCV_MAP);
      final map = val.map!;
      expect(map.length, 1);
      expect(map[0].key.sym, 'threshold');
      expect(map[0].val.u32?.uint32, 2);
    });

    test('threshold 1 is the minimum allowed', () {
      expect(() => buildSimpleThresholdScVal(threshold: 1), returnsNormally);
    });

    test('threshold 0 throws SmartAccountValidationException', () {
      expect(
        () => buildSimpleThresholdScVal(threshold: 0),
        throwsA(isA<SmartAccountValidationException>()),
      );
    });

    test('large threshold encodes correctly', () {
      final val = buildSimpleThresholdScVal(threshold: 255);
      expect(val.map![0].val.u32?.uint32, 255);
    });

    test('XDR base64 matches pinned cross-platform fixture (threshold=3)', () {
      final val = buildSimpleThresholdScVal(threshold: 3);
      expect(_xdrBase64(val), equals(_simpleThreshold3Fixture));
    });

    test('XDR bytes are stable across multiple calls', () {
      final v1 = buildSimpleThresholdScVal(threshold: 3);
      final v2 = buildSimpleThresholdScVal(threshold: 3);
      expect(_xdrBase64(v1), equals(_xdrBase64(v2)));
    });
  });

  group('buildSpendingLimitScVal', () {
    test('encodes period_ledgers and spending_limit in a map', () {
      final val = buildSpendingLimitScVal(
        limit: 1000000000, // 100 DEMO in stroops
        periodLedgers: 100,
      );
      expect(val.discriminant, XdrSCValType.SCV_MAP);
      final map = val.map!;
      expect(map.length, 2);

      final periodEntry = map.firstWhere(
        (e) => e.key.sym == 'period_ledgers',
      );
      expect(periodEntry.val.u32?.uint32, 100);

      final limitEntry = map.firstWhere(
        (e) => e.key.sym == 'spending_limit',
      );
      expect(limitEntry.val.discriminant, XdrSCValType.SCV_I128);
    });

    test('limit 0 throws SmartAccountValidationException', () {
      expect(
        () => buildSpendingLimitScVal(limit: 0, periodLedgers: 10),
        throwsA(isA<SmartAccountValidationException>()),
      );
    });

    test('negative limit throws SmartAccountValidationException', () {
      expect(
        () => buildSpendingLimitScVal(limit: -1, periodLedgers: 10),
        throwsA(isA<SmartAccountValidationException>()),
      );
    });

    test('period_ledgers 0 throws SmartAccountValidationException', () {
      expect(
        () => buildSpendingLimitScVal(limit: 100, periodLedgers: 0),
        throwsA(isA<SmartAccountValidationException>()),
      );
    });

    test('i128 encoding for large limit', () {
      // 100_000 DEMO = 10^12 stroops — requires 128-bit int.
      final val = buildSpendingLimitScVal(
        limit: 1000000000000,
        periodLedgers: 1,
      );
      final limitEntry = val.map!.firstWhere(
        (e) => e.key.sym == 'spending_limit',
      );
      expect(limitEntry.val.discriminant, XdrSCValType.SCV_I128);
    });

    test(
      'XDR base64 matches pinned cross-platform fixture '
      '(limit=1_000_000, periodLedgers=100)',
      () {
        final val = buildSpendingLimitScVal(limit: 1000000, periodLedgers: 100);
        expect(_xdrBase64(val), equals(_spendingLimit1mPer100Fixture));
      },
    );

    test('XDR bytes are stable for same inputs', () {
      final v1 = buildSpendingLimitScVal(limit: 500, periodLedgers: 50);
      final v2 = buildSpendingLimitScVal(limit: 500, periodLedgers: 50);
      expect(_xdrBase64(v1), equals(_xdrBase64(v2)));
    });

    test('XDR bytes differ for different limits', () {
      final v1 = buildSpendingLimitScVal(limit: 100, periodLedgers: 50);
      final v2 = buildSpendingLimitScVal(limit: 200, periodLedgers: 50);
      expect(_xdrBase64(v1), isNot(equals(_xdrBase64(v2))));
    });
  });

  group('buildWeightedThresholdScVal', () {
    test('single signer with weight >= threshold is valid', () {
      final signerScVal = XdrSCVal.forBytes(
        Uint8List.fromList([0x01, 0x02, 0x03]),
      );
      final val = buildWeightedThresholdScVal(
        weights: [(signer: signerScVal, weight: 3)],
        threshold: 2,
      );
      expect(val.discriminant, XdrSCValType.SCV_MAP);
      final map = val.map!;
      expect(map.length, 2);

      final weightsEntry = map.firstWhere((e) => e.key.sym == 'signer_weights');
      expect(weightsEntry.val.discriminant, XdrSCValType.SCV_MAP);

      final threshEntry = map.firstWhere((e) => e.key.sym == 'threshold');
      expect(threshEntry.val.u32?.uint32, 2);
    });

    test('threshold 0 throws SmartAccountValidationException', () {
      final signerScVal = XdrSCVal.forBytes(
        Uint8List.fromList([0x01]),
      );
      expect(
        () => buildWeightedThresholdScVal(
          weights: [(signer: signerScVal, weight: 1)],
          threshold: 0,
        ),
        throwsA(isA<SmartAccountValidationException>()),
      );
    });

    test('empty weights throws SmartAccountValidationException', () {
      expect(
        () => buildWeightedThresholdScVal(weights: const [], threshold: 1),
        throwsA(isA<SmartAccountValidationException>()),
      );
    });

    test('weight of 0 throws SmartAccountValidationException', () {
      final signerScVal = XdrSCVal.forBytes(Uint8List.fromList([0x01]));
      expect(
        () => buildWeightedThresholdScVal(
          weights: [(signer: signerScVal, weight: 0)],
          threshold: 1,
        ),
        throwsA(isA<SmartAccountValidationException>()),
      );
    });

    test('total weight less than threshold throws SmartAccountValidationException', () {
      final s1 = XdrSCVal.forBytes(Uint8List.fromList([0x01]));
      final s2 = XdrSCVal.forBytes(Uint8List.fromList([0x02]));
      expect(
        () => buildWeightedThresholdScVal(
          weights: [
            (signer: s1, weight: 1),
            (signer: s2, weight: 1),
          ],
          threshold: 3,
        ),
        throwsA(isA<SmartAccountValidationException>()),
      );
    });

    test('two signers with total weight equal to threshold passes', () {
      final s1 = XdrSCVal.forBytes(Uint8List.fromList([0x01]));
      final s2 = XdrSCVal.forBytes(Uint8List.fromList([0x02]));
      expect(
        () => buildWeightedThresholdScVal(
          weights: [
            (signer: s1, weight: 2),
            (signer: s2, weight: 1),
          ],
          threshold: 3,
        ),
        returnsNormally,
      );
    });

    test('signer_weights inner map entry count matches signers', () {
      final s1 = XdrSCVal.forBytes(Uint8List.fromList([0x01]));
      final s2 = XdrSCVal.forBytes(Uint8List.fromList([0x02]));
      final val = buildWeightedThresholdScVal(
        weights: [
          (signer: s1, weight: 1),
          (signer: s2, weight: 2),
        ],
        threshold: 1,
      );
      final weightsEntry =
          val.map!.firstWhere((e) => e.key.sym == 'signer_weights');
      expect(weightsEntry.val.map!.length, 2);
    });

    test(
      'XDR base64 matches pinned cross-platform fixture '
      '([(Bytes([0xAA,0xBB])=>1)], threshold=1)',
      () {
        final signerScVal = XdrSCVal.forBytes(
          Uint8List.fromList([0xAA, 0xBB]),
        );
        final val = buildWeightedThresholdScVal(
          weights: [(signer: signerScVal, weight: 1)],
          threshold: 1,
        );
        expect(_xdrBase64(val), equals(_weightedThreshold1Fixture));
      },
    );

    test('inner map is sorted by XDR byte order', () {
      // The smaller XDR signer (0x00) must appear before the larger (0xFF).
      final small = XdrSCVal.forBytes(Uint8List.fromList([0x00]));
      final large = XdrSCVal.forBytes(Uint8List.fromList([0xFF]));

      // Pass in reverse order — expect sorted output.
      final val = buildWeightedThresholdScVal(
        weights: [
          (signer: large, weight: 1),
          (signer: small, weight: 2),
        ],
        threshold: 1,
      );

      final weightsEntry =
          val.map!.firstWhere((e) => e.key.sym == 'signer_weights');
      final innerMap = weightsEntry.val.map!;
      // First inner entry should be the small signer (XdrSCVal.bytes.sCBytes).
      expect(innerMap.first.key.bytes?.sCBytes, Uint8List.fromList([0x00]));
    });

    test('XDR bytes are stable for same inputs', () {
      final signerScVal = XdrSCVal.forBytes(
        Uint8List.fromList([0xAA, 0xBB]),
      );
      final v1 = buildWeightedThresholdScVal(
        weights: [(signer: signerScVal, weight: 1)],
        threshold: 1,
      );
      final v2 = buildWeightedThresholdScVal(
        weights: [(signer: signerScVal, weight: 1)],
        threshold: 1,
      );
      expect(_xdrBase64(v1), equals(_xdrBase64(v2)));
    });

    test('XDR bytes differ for different thresholds', () {
      final signerScVal = XdrSCVal.forBytes(Uint8List.fromList([0x01]));
      final v1 = buildWeightedThresholdScVal(
        weights: [(signer: signerScVal, weight: 2)],
        threshold: 1,
      );
      final v2 = buildWeightedThresholdScVal(
        weights: [(signer: signerScVal, weight: 2)],
        threshold: 2,
      );
      expect(_xdrBase64(v1), isNot(equals(_xdrBase64(v2))));
    });
  });
}
