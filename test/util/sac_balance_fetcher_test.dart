import 'package:flutter_test/flutter_test.dart';
import 'package:smart_account_demo/util/sac_balance_fetcher.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

void main() {
  // -------------------------------------------------------------------------
  // extractI128AsBigInt — unit tests for lossless i128 decoding
  // -------------------------------------------------------------------------

  group('SACBalanceFetcher.extractI128AsBigInt', () {
    // Helper: build an XdrSCVal with an i128 from explicit hi/lo BigInt values.
    XdrSCVal makeI128(BigInt hi, BigInt lo) {
      return XdrSCVal.forI128(XdrInt128Parts.forHiLo(hi, lo));
    }

    test('zero balance returns BigInt.zero', () {
      final val = makeI128(BigInt.zero, BigInt.zero);
      expect(SACBalanceFetcher.extractI128AsBigInt(val), equals(BigInt.zero));
    });

    test('small positive balance returns exact BigInt', () {
      // 100_000_000 stroops = 10 XLM
      final val = makeI128(BigInt.zero, BigInt.from(100000000));
      expect(
        SACBalanceFetcher.extractI128AsBigInt(val),
        equals(BigInt.from(100000000)),
      );
    });

    test('lo at the 53-bit boundary is returned exactly', () {
      // 2^53 - 1 = 9_007_199_254_740_991. Native Dart int holds this exactly;
      // Dart-on-web cannot. BigInt preserves it on both targets.
      final boundary = BigInt.parse('1FFFFFFFFFFFFF', radix: 16);
      final val = makeI128(BigInt.zero, boundary);
      expect(
        SACBalanceFetcher.extractI128AsBigInt(val),
        equals(boundary),
      );
    });

    test('lo above the 53-bit boundary is returned exactly', () {
      // 2^53: exceeds Number-safe integer range on web. BigInt preserves it.
      final value = BigInt.parse('20000000000000', radix: 16);
      final val = makeI128(BigInt.zero, value);
      expect(
        SACBalanceFetcher.extractI128AsBigInt(val),
        equals(value),
      );
    });

    test('lo at the 64-bit boundary (0xFFFFFFFFFFFFFFFF) returns 2^64 - 1', () {
      // Maximum unsigned 64-bit lo with hi=0 is 2^64 - 1.
      final maxU64 = BigInt.parse('FFFFFFFFFFFFFFFF', radix: 16);
      final val = makeI128(BigInt.zero, maxU64);
      expect(
        SACBalanceFetcher.extractI128AsBigInt(val),
        equals(maxU64),
      );
    });

    test('hi=1 lo=0 reconstructs as 2^64', () {
      // (1 << 64) + 0 = 2^64 exactly.
      final val = makeI128(BigInt.one, BigInt.zero);
      expect(
        SACBalanceFetcher.extractI128AsBigInt(val),
        equals(BigInt.one << 64),
      );
    });

    test('hi=1 lo=42 reconstructs as 2^64 + 42', () {
      final val = makeI128(BigInt.one, BigInt.from(42));
      expect(
        SACBalanceFetcher.extractI128AsBigInt(val),
        equals((BigInt.one << 64) + BigInt.from(42)),
      );
    });

    test('large positive hi reconstructs the full 128-bit value', () {
      final hi = BigInt.from(0xDEADBEEF);
      final lo = BigInt.from(12345);
      final expected = (hi << 64) + lo;
      final val = makeI128(hi, lo);
      expect(
        SACBalanceFetcher.extractI128AsBigInt(val),
        equals(expected),
      );
    });

    test('maximum positive i128 (hi=2^63-1, lo=2^64-1) is returned exactly', () {
      // i128 max = (2^127) - 1
      final hi = (BigInt.one << 63) - BigInt.one;
      final lo = (BigInt.one << 64) - BigInt.one;
      final val = makeI128(hi, lo);
      expect(
        SACBalanceFetcher.extractI128AsBigInt(val),
        equals((BigInt.one << 127) - BigInt.one),
      );
    });

    test('negative i128 (hi=-1, lo=0) reconstructs as -2^64', () {
      // hi is signed 64-bit, so a negative hi produces a negative result.
      final val = makeI128(-BigInt.one, BigInt.zero);
      expect(
        SACBalanceFetcher.extractI128AsBigInt(val),
        equals(-(BigInt.one << 64)),
      );
    });

    test('non-i128 SCVal throws unexpectedReturnType error', () {
      final val = XdrSCVal.forU32(42);
      expect(
        () => SACBalanceFetcher.extractI128AsBigInt(val),
        throwsA(
          isA<SACBalanceFetcherError>().having(
            (e) => e.kind,
            'kind',
            SACBalanceFetcherErrorKind.unexpectedReturnType,
          ),
        ),
      );
    });

    test('symbol SCVal throws unexpectedReturnType error', () {
      final val = XdrSCVal.forSymbol('balance');
      expect(
        () => SACBalanceFetcher.extractI128AsBigInt(val),
        throwsA(isA<SACBalanceFetcherError>()),
      );
    });
  });

  // -------------------------------------------------------------------------
  // SACBalanceFetcherError — formatting
  // -------------------------------------------------------------------------

  group('SACBalanceFetcherError', () {
    test('simulationFailed has accessible message and kind', () {
      const err = SACBalanceFetcherError(
        kind: SACBalanceFetcherErrorKind.simulationFailed,
        message: 'RPC returned 500',
      );
      expect(err.kind, equals(SACBalanceFetcherErrorKind.simulationFailed));
      expect(err.message, equals('RPC returned 500'));
      expect(err.toString(), contains('simulationFailed'));
      expect(err.toString(), contains('RPC returned 500'));
    });

    test('unexpectedReturnType has accessible message and kind', () {
      const err = SACBalanceFetcherError(
        kind: SACBalanceFetcherErrorKind.unexpectedReturnType,
        message: 'expected i128',
      );
      expect(err.kind, equals(SACBalanceFetcherErrorKind.unexpectedReturnType));
      expect(err.message, equals('expected i128'));
      expect(err.toString(), contains('unexpectedReturnType'));
      expect(err.toString(), contains('expected i128'));
    });
  });
}
