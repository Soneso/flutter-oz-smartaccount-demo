/// WASM asset loading helper.
///
/// Loads the bundled Soroban token contract WASM from the Flutter asset bundle.
/// The asset path must be registered in pubspec.yaml under [flutter.assets].
library;

import 'package:flutter/services.dart';

// ---------------------------------------------------------------------------
// Asset path constant
// ---------------------------------------------------------------------------

/// Asset path for the Soroban token contract WASM binary.
///
/// Must match the entry in pubspec.yaml's [flutter.assets] block.
const String _tokenContractWasmAsset = 'assets/wasm/soroban_token_contract.wasm';

// ---------------------------------------------------------------------------
// Loader
// ---------------------------------------------------------------------------

/// Loads the Soroban token contract WASM bytes from the Flutter asset bundle.
///
/// Returns a [Uint8List] suitable for passing to SDK deployment operations.
/// Throws a [FlutterError] if the asset is missing from the bundle (typically
/// means pubspec.yaml is missing the asset entry or a hot-restart is needed).
Future<Uint8List> loadTokenContractWasm() async {
  final data = await rootBundle.load(_tokenContractWasmAsset);
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}
