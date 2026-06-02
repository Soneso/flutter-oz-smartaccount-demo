import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:smart_account_demo/util/url_opener.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

// ---------------------------------------------------------------------------
// Mock UrlLauncherPlatform
//
// Extends UrlLauncherPlatform and mixes in MockPlatformInterfaceMixin so that
// PlatformInterface.verify() accepts the substitution in tests.
// Records the most-recently-launched URL and launch options.
// ---------------------------------------------------------------------------

class _MockUrlLauncherPlatform extends UrlLauncherPlatform
    with MockPlatformInterfaceMixin {
  String? lastLaunchedUrl;
  LaunchOptions? lastOptions;
  bool canLaunchResponse = true;

  @override
  Future<bool> canLaunch(String url) async => canLaunchResponse;

  @override
  Future<bool> supportsMode(PreferredLaunchMode mode) async => true;

  @override
  Future<bool> supportsCloseForMode(PreferredLaunchMode mode) async => false;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    lastLaunchedUrl = url;
    lastOptions = options;
    return true;
  }

  @override
  LinkDelegate? get linkDelegate => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _MockUrlLauncherPlatform mockLauncher;

  setUp(() {
    mockLauncher = _MockUrlLauncherPlatform();
    UrlLauncherPlatform.instance = mockLauncher;
  });

  // ---------------------------------------------------------------------------
  // openUrl
  // ---------------------------------------------------------------------------

  group('openUrl', () {
    test('valid URL is launched with inAppBrowserView mode', () async {
      await openUrl('https://stellar.expert/explorer/testnet');
      expect(
        mockLauncher.lastLaunchedUrl,
        equals('https://stellar.expert/explorer/testnet'),
      );
      expect(
        mockLauncher.lastOptions?.mode,
        equals(PreferredLaunchMode.inAppBrowserView),
      );
    });

    test('empty string URL throws ArgumentError (Uri.tryParse returns null)', () async {
      // Uri.tryParse returns null only for empty string; that triggers the guard.
      await expectLater(
        openUrl(''),
        throwsArgumentError,
      );
    });

    test('URL that cannot be launched returns silently (no throw)', () async {
      mockLauncher.canLaunchResponse = false;
      // Should return without throwing when canLaunch is false.
      await openUrl('https://stellar.expert/');
      // launchUrl should not have been called.
      expect(mockLauncher.lastLaunchedUrl, isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // openTxInExplorer
  // ---------------------------------------------------------------------------

  group('openTxInExplorer', () {
    test('opens correct Stellar Expert testnet TX URL', () async {
      const txHash = 'abc123def456';
      await openTxInExplorer(txHash);
      expect(
        mockLauncher.lastLaunchedUrl,
        equals('https://stellar.expert/explorer/testnet/tx/$txHash'),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // openContractInExplorer
  // ---------------------------------------------------------------------------

  group('openContractInExplorer', () {
    test('opens correct Stellar Expert testnet contract URL', () async {
      const contractId =
          'CAAAB5A5XLD4TVJNQJGLXFBH3SCPJBHBPLKQACQ6VLLHLZJOLILPIXQ';
      await openContractInExplorer(contractId);
      expect(
        mockLauncher.lastLaunchedUrl,
        equals(
          'https://stellar.expert/explorer/testnet/contract/$contractId',
        ),
      );
    });
  });
}
