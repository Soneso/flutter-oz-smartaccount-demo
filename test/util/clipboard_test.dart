import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_account_demo/util/clipboard.dart';

void main() {
  // The Clipboard.setData implementation is backed by a platform channel.
  // In tests we use TestWidgetsFlutterBinding (set up automatically by
  // flutter_test) which installs a no-op binary messenger that records
  // channel calls via SystemChannels.platform.
  //
  // We intercept the 'flutter/platform' channel's 'Clipboard.setData' call and
  // capture the text that was passed.

  TestWidgetsFlutterBinding.ensureInitialized();

  String? capturedText;

  setUp(() {
    capturedText = null;

    // Install a mock handler on the platform channel that Clipboard uses.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        if (call.method == 'Clipboard.setData') {
          final args = call.arguments as Map<dynamic, dynamic>;
          capturedText = args['text'] as String?;
        }
        return null;
      },
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  // ---------------------------------------------------------------------------
  // copyToClipboard
  // ---------------------------------------------------------------------------

  group('copyToClipboard', () {
    test('copies text to clipboard', () async {
      await copyToClipboard('hello world');
      expect(capturedText, equals('hello world'));
    });

    test('markSensitive: true still copies the text', () async {
      await copyToClipboard('sensitive data', markSensitive: true);
      // The sensitive flag must not block or alter the copy.
      expect(capturedText, equals('sensitive data'));
    });

    test('default markSensitive copies the text', () async {
      await copyToClipboard('public data');
      expect(capturedText, equals('public data'));
    });

    test('copies empty string', () async {
      await copyToClipboard('');
      expect(capturedText, equals(''));
    });
  });

  // ---------------------------------------------------------------------------
  // copyTxHash
  // ---------------------------------------------------------------------------

  group('copyTxHash', () {
    test('copies transaction hash', () async {
      const hash = 'abc123def456abc123def456abc123def456abc123def456abc123def456abc1';
      await copyTxHash(hash);
      expect(capturedText, equals(hash));
    });
  });

  // ---------------------------------------------------------------------------
  // copyCredentialId
  // ---------------------------------------------------------------------------

  group('copyCredentialId', () {
    test('copies truncated credential ID', () async {
      const credId = 'AbCdEfGh...WxYzAbCd';
      await copyCredentialId(credId);
      expect(capturedText, equals(credId));
    });
  });
}
