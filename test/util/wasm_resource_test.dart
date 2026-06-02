import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_account_demo/util/wasm_resource.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Registers a fake asset response on the [rootBundle] for [assetKey].
///
/// Flutter asset loading is backed by the 'flutter/assets' binary messenger
/// channel. In tests, we intercept that channel and return [bytes] encoded
/// as a raw ByteData, which is the format [rootBundle.load] expects.
///
/// Pass null for [bytes] to simulate a missing asset (the channel returns null,
/// causing rootBundle.load to throw a FlutterError).
void _registerFakeAsset(String assetKey, Uint8List? bytes) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMessageHandler('flutter/assets', (ByteData? message) async {
    if (message == null) return null;

    const codec = StringCodec();
    final key = codec.decodeMessage(message);
    if (key != assetKey) return null;

    if (bytes == null) return null;

    final bd = ByteData(bytes.length);
    for (var i = 0; i < bytes.length; i++) {
      bd.setUint8(i, bytes[i]);
    }
    return bd;
  });
}

void _clearFakeAsset() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMessageHandler('flutter/assets', null);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(_clearFakeAsset);

  // ---------------------------------------------------------------------------
  // loadTokenContractWasm — success path
  // ---------------------------------------------------------------------------

  group('loadTokenContractWasm', () {
    test('returns non-empty Uint8List when asset is present', () async {
      // Use a realistic minimal WASM magic header (4 bytes).
      final fakeWasm = Uint8List.fromList([0x00, 0x61, 0x73, 0x6D]);
      _registerFakeAsset(
        'assets/wasm/soroban_token_contract.wasm',
        fakeWasm,
      );

      final result = await loadTokenContractWasm();
      expect(result, isA<Uint8List>());
      expect(result, isNotEmpty);
      expect(result, equals(fakeWasm));
    });

    test('returns correct byte content', () async {
      final expected = Uint8List.fromList(
        List.generate(32, (i) => i),
      );
      _registerFakeAsset(
        'assets/wasm/soroban_token_contract.wasm',
        expected,
      );

      final result = await loadTokenContractWasm();
      expect(result, equals(expected));
    });

    // -------------------------------------------------------------------------
    // Missing asset path
    // -------------------------------------------------------------------------

    test('throws FlutterError when asset is missing from the bundle', () async {
      // Register null to simulate a missing asset.
      _registerFakeAsset('assets/wasm/soroban_token_contract.wasm', null);

      await expectLater(
        loadTokenContractWasm,
        throwsA(isA<FlutterError>()),
      );
    });
  });
}
