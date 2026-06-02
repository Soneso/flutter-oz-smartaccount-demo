import 'package:flutter_test/flutter_test.dart';
import 'package:smart_account_demo/util/error_utils.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

void main() {
  // ---------------------------------------------------------------------------
  // DemoError
  // ---------------------------------------------------------------------------

  group('DemoError', () {
    test('toString includes category and message', () {
      const err = DemoError(
        message: 'test message',
        category: DemoErrorCategory.network,
      );
      expect(err.toString(), contains('network'));
      expect(err.toString(), contains('test message'));
    });
  });

  // ---------------------------------------------------------------------------
  // classifyError — cancel keywords
  // ---------------------------------------------------------------------------

  group('classifyError — user cancellation', () {
    test('typed WebAuthnCancelled is classified as userCancelled', () {
      const err = WebAuthnCancelled(message: 'User cancelled passkey ceremony');
      final result = classifyError(err);
      expect(result.category, equals(DemoErrorCategory.userCancelled));
      expect(result.message, contains('Cancelled'));
    });

    test('context prefix is prepended to WebAuthnCancelled message', () {
      const err = WebAuthnCancelled(message: 'User dismissed the sheet');
      final result = classifyError(err, context: 'Passkey registration');
      expect(result.message, startsWith('Passkey registration:'));
    });

    // The typed check is the only signal for cancellation. Plain exceptions
    // that happen to contain "cancel", "abort", or "not allowed" in their
    // message are NOT classified as userCancelled — they fall through to
    // network or unexpected. This prevents an adversarial relayer response
    // from silently downgrading a hard error.
    test('plain exception containing "cancel" is NOT classified as userCancelled', () {
      final err = Exception('User cancelled the operation');
      final result = classifyError(err);
      expect(result.category, isNot(equals(DemoErrorCategory.userCancelled)));
    });

    test('plain exception containing "not allowed" is NOT classified as userCancelled', () {
      final err = Exception('NotAllowedError: The operation is not allowed');
      final result = classifyError(err);
      expect(result.category, isNot(equals(DemoErrorCategory.userCancelled)));
    });

    test('plain exception containing "abort" is NOT classified as userCancelled', () {
      final err = Exception('AbortError from platform');
      final result = classifyError(err);
      expect(result.category, isNot(equals(DemoErrorCategory.userCancelled)));
    });
  });

  // ---------------------------------------------------------------------------
  // classifyError — network keywords
  // ---------------------------------------------------------------------------

  group('classifyError — network error', () {
    test('exception containing "socket" is classified as network', () {
      final err = Exception('SocketException: connection refused');
      final result = classifyError(err);
      expect(result.category, equals(DemoErrorCategory.network));
      expect(result.message, contains('Network error'));
    });

    test('exception containing "timeout" is classified as network', () {
      final err = Exception('Request timeout after 30s');
      final result = classifyError(err);
      expect(result.category, equals(DemoErrorCategory.network));
    });

    test('exception containing "host lookup" is classified as network', () {
      final err = Exception('Failed host lookup: soroban-testnet.stellar.org');
      final result = classifyError(err);
      expect(result.category, equals(DemoErrorCategory.network));
    });

    test('exception containing "connection" is classified as network', () {
      final err = Exception('Connection reset by peer');
      final result = classifyError(err);
      expect(result.category, equals(DemoErrorCategory.network));
    });

    test('exception containing "unreachable" is classified as network', () {
      final err = Exception('Network unreachable');
      final result = classifyError(err);
      expect(result.category, equals(DemoErrorCategory.network));
    });
  });

  // ---------------------------------------------------------------------------
  // classifyError — DemoError passthrough
  // ---------------------------------------------------------------------------

  group('classifyError — DemoError passthrough', () {
    test('DemoError is returned unchanged', () {
      const original = DemoError(
        message: 'On-chain failure',
        category: DemoErrorCategory.onChain,
      );
      final result = classifyError(original);
      expect(result, same(original));
    });
  });

  // ---------------------------------------------------------------------------
  // classifyError — unexpected fallback
  // ---------------------------------------------------------------------------

  group('classifyError — unexpected', () {
    test('unknown exception is classified as unexpected', () {
      final err = Exception('Some internal error with no keyword');
      final result = classifyError(err);
      expect(result.category, equals(DemoErrorCategory.unexpected));
      // The fallback now surfaces the underlying error's toString() so demo
      // developers can diagnose unknown failures.
      expect(result.message, startsWith('Unexpected error: '));
      expect(result.message, contains('Some internal error with no keyword'));
    });

    test('unexpected error cause is preserved', () {
      final cause = Exception('raw cause');
      final result = classifyError(cause);
      expect(result.cause, same(cause));
    });

    test('context is prepended to unexpected message', () {
      final err = Exception('mystery');
      final result = classifyError(err, context: 'Deploy');
      expect(result.message, startsWith('Deploy:'));
    });
  });
}
