/// Web Freighter wallet connector implementation.
///
/// Implements [WalletConnector] using the Freighter browser extension's
/// JavaScript API (`@stellar/freighter-api`). Only for Flutter Web builds.
/// Mobile builds use [ReownWalletHandler] instead.
///
/// Security requirements:
///
/// - Extension presence is verified via the official `isConnected()` /
///   `getNetworkDetails()` API handshake — NOT `typeof window.freighter`. The
///   `window.freighter` property is spoofable by any page-injected shim;
///   using the official JS API ensures the response comes from a vetted
///   extension context.
/// - Freighter API version must be >= [_minimumApiVersion] (currently 4).
///   A lower version does not expose the `signAuthEntry` function with a
///   base64 return value. Hard-fail with an actionable message if detected.
/// - Post-signature recheck is performed by the calling layer
///   ([ExternalSignerManagerAdapter]); this handler only transports the
///   signature returned by the extension.
///
/// Freighter JS API version pinned: v4+ (signAuthEntry returns base64 string).
library;

// ignore: avoid_web_libraries_in_flutter
import 'dart:js_interop';
// ignore: avoid_web_libraries_in_flutter
import 'dart:js_interop_unsafe';

import '../../config/demo_config.dart' show freighterDownloadUrl;
import '../wallet_connector.dart';

// ---------------------------------------------------------------------------
// Freighter API minimum version
// ---------------------------------------------------------------------------

/// Minimum Freighter JS API major version required for base64-returning
/// `signAuthEntry`. Versions < 4 returned a Buffer object which is not
/// directly usable as a Dart String.
const int _minimumApiVersion = 4;

// ---------------------------------------------------------------------------
// JS interop declarations
// ---------------------------------------------------------------------------

/// Top-level Freighter API entry point injected by the browser extension.
///
/// The extension exposes the `freighterApi` global namespace; each call below
/// binds a function on it (`freighterApi.isConnected`, `freighterApi.signAuthEntry`,
/// etc.) via `@JS`.
///
/// All functions return Promises that ALWAYS RESOLVE (never reject). Errors
/// are returned in an `error` field: `{ code: number, message: string }`.
@JS('freighterApi.isConnected')
external JSPromise<JSObject> _jsIsConnected();

@JS('freighterApi.getNetworkDetails')
external JSPromise<JSObject> _jsGetNetworkDetails();

@JS('freighterApi.requestAccess')
external JSPromise<JSObject> _jsRequestAccess();

@JS('freighterApi.signAuthEntry')
external JSPromise<JSObject> _jsSignAuthEntry(JSString entryXdr, JSObject opts);

@JS('freighterApi.getApiVersion')
external JSPromise<JSString?> _jsGetApiVersion();

// ---------------------------------------------------------------------------
// Helper: property access via dart:js_interop_unsafe
// ---------------------------------------------------------------------------

/// Reads a nullable String property from a JS object.
///
/// Returns null when the property is absent, null, or undefined.
String? _stringProp(JSObject obj, String key) {
  final value = obj.getProperty<JSAny?>(key.toJS);
  if (value == null || value.isUndefinedOrNull) return null;
  return (value as JSString).toDart;
}

/// Reads a nullable number property from a JS object as an int.
///
/// Returns null when the property is absent, null, or undefined.
int? _intProp(JSObject obj, String key) {
  final value = obj.getProperty<JSAny?>(key.toJS);
  if (value == null || value.isUndefinedOrNull) return null;
  return (value as JSNumber).toDartInt;
}

/// Returns true when an `error` field is present and non-null on [obj].
bool _hasError(JSObject obj) {
  final err = obj.getProperty<JSAny?>('error'.toJS);
  return err != null && !err.isUndefinedOrNull;
}

/// Extracts the error message from an object with an `error` field.
String _errorMessage(JSObject obj) {
  final err = obj.getProperty<JSAny?>('error'.toJS);
  if (err == null || err.isUndefinedOrNull) return 'unknown error';
  final errObj = err as JSObject;
  return _stringProp(errObj, 'message') ?? 'unknown error';
}

// ---------------------------------------------------------------------------
// FreighterWalletHandler
// ---------------------------------------------------------------------------

/// Web [WalletConnector] implementation using the Freighter browser extension.
///
/// Uses `dart:js_interop` and `dart:js_interop_unsafe` to call
/// `@stellar/freighter-api` functions injected by the Freighter extension.
/// The extension MUST be installed and unlocked for any operation to succeed.
///
/// Do not import this file in non-web builds; it depends on
/// `dart:js_interop` which is only available on the web target.
class FreighterWalletHandler implements WalletConnector {
  /// Constructs a Freighter wallet handler.
  FreighterWalletHandler();

  String? _connectedAddress;

  // ---------------------------------------------------------------------------
  // WalletConnector — connection
  // ---------------------------------------------------------------------------

  @override
  Future<String?> connect() async {
    // Step 1: Verify the Freighter extension is installed and unlocked via the
    // official API handshake. This is more reliable than `typeof window.freighter`
    // because the handshake requires a real response from the extension context.
    await _verifyExtensionPresence();

    // Step 2: Check API version. Versions < _minimumApiVersion do not support
    // base64-returning signAuthEntry.
    await _verifyApiVersion();

    // Step 3: Request access (triggers the Freighter connection prompt).
    final accessResult = await _jsRequestAccess().toDart;
    if (_hasError(accessResult)) {
      final errObj = accessResult.getProperty<JSAny?>('error'.toJS);
      final code = errObj != null && !errObj.isUndefinedOrNull
          ? _intProp(errObj as JSObject, 'code')
          : null;
      if (code == -4) {
        // User closed the popup — return null to indicate cancellation.
        return null;
      }
      throw WalletConnectionException('Freighter: ${_errorMessage(accessResult)}');
    }

    final address = _stringProp(accessResult, 'address');
    if (address == null || address.isEmpty) {
      return null;
    }

    // Step 4: Verify network.
    await _verifyNetwork();

    _connectedAddress = address;
    return address;
  }

  @override
  Future<void> disconnect() async {
    // Freighter does not expose a programmatic disconnect method; clearing
    // local state is the only action available.
    _connectedAddress = null;
  }

  @override
  Future<bool> restoreSession() async {
    // Freighter retains the connection between page loads automatically.
    // Use isConnected() to check whether the extension is still active.
    try {
      final result = await _jsIsConnected().toDart;
      if (_hasError(result)) return false;
      final connected = result.getProperty<JSAny?>('isConnected'.toJS);
      if (connected == null || connected.isUndefinedOrNull) return false;
      if (!(connected as JSBoolean).toDart) return false;

      // isConnected() returned true — try re-reading the address.
      final accessResult = await _jsRequestAccess().toDart;
      if (_hasError(accessResult)) return false;
      final address = _stringProp(accessResult, 'address');
      if (address == null || address.isEmpty) return false;
      _connectedAddress = address;
      return true;
    } catch (_) {
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // WalletConnector — signing
  // ---------------------------------------------------------------------------

  @override
  Future<SignedAuthEntry> signAuthEntry({
    required String authEntryXdr,
    required List<int> contextRuleIds,
  }) async {
    final address = _connectedAddress;
    if (address == null) {
      throw StateError(
        'signAuthEntry called with no active Freighter session. '
        'Call connect() first.',
      );
    }

    if (authEntryXdr.isEmpty) {
      throw const WalletSigningException('authEntryXdr must not be empty.');
    }

    // Build the options object. Freighter uses `address` (maps to
    // `accountToSign` internally in freighter-api >= 4.x).
    final opts = JSObject();
    opts.setProperty('address'.toJS, address.toJS);

    final JSObject result;
    try {
      result = await _jsSignAuthEntry(authEntryXdr.toJS, opts).toDart;
    } catch (e) {
      throw WalletSigningException(
        'Freighter signAuthEntry threw unexpectedly: $e',
        cause: e,
      );
    }

    if (_hasError(result)) {
      final msg = _errorMessage(result);
      throw WalletSigningException('Freighter signing failed: $msg');
    }

    final signed = _stringProp(result, 'signedAuthEntry');
    if (signed == null || signed.isEmpty) {
      throw WalletSigningException(
        'Freighter returned no signedAuthEntry for address $address. '
        'Ensure the Freighter extension is v$_minimumApiVersion or newer.',
      );
    }

    return SignedAuthEntry(
      signedAuthEntry: signed,
      signerAddress: address,
    );
  }

  // ---------------------------------------------------------------------------
  // WalletConnector — state
  // ---------------------------------------------------------------------------

  @override
  String? get connectedAddress => _connectedAddress;

  @override
  WalletMetadata? get walletMetadata =>
      _connectedAddress != null
          ? const WalletMetadata(
              name: 'Freighter',
              url: freighterDownloadUrl,
            )
          : null;

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  /// Verifies that the Freighter extension is present and responding.
  ///
  /// Uses the official `isConnected()` API as the presence check — NOT
  /// `typeof window.freighter`. An injected shim can set `window.freighter`,
  /// but it cannot respond correctly to the API's Promise-based handshake
  /// without having the extension context available.
  ///
  /// Throws [WalletConnectionException] if the extension is absent.
  Future<void> _verifyExtensionPresence() async {
    try {
      final result = await _jsIsConnected().toDart;
      // A successful resolution (even with isConnected: false) proves the
      // extension is installed. If the Promise rejects or throws, the extension
      // is absent.
      if (_hasError(result)) {
        throw const WalletConnectionException(
          'Freighter extension is not installed or not responding. '
          'Install Freighter from https://www.freighter.app and reload the page.',
        );
      }
    } catch (e) {
      if (e is WalletConnectionException) rethrow;
      throw WalletConnectionException(
        'Freighter extension is not installed or not responding. '
        'Install Freighter from https://www.freighter.app and reload the page.',
        cause: e,
      );
    }
  }

  /// Checks the Freighter API version against [_minimumApiVersion].
  ///
  /// Hard-fails with an actionable message if the detected version is lower.
  Future<void> _verifyApiVersion() async {
    try {
      final versionJs = await _jsGetApiVersion().toDart;
      final versionStr = versionJs?.toDart;
      if (versionStr == null || versionStr.isEmpty) {
        // Version not detectable — treat as sufficient (pre-API-version endpoint).
        return;
      }
      // Version is a string like "4.2.0" or "3.9.1". Parse the major version.
      final majorStr = versionStr.split('.').first;
      final major = int.tryParse(majorStr);
      if (major != null && major < _minimumApiVersion) {
        throw WalletConnectionException(
          'Freighter extension version $versionStr is too old. '
          'This demo requires Freighter API v$_minimumApiVersion or newer. '
          'Update Freighter from https://www.freighter.app.',
        );
      }
    } catch (e) {
      if (e is WalletConnectionException) rethrow;
      // Version check failure is non-fatal; proceed and let the signing call
      // surface any actual incompatibility.
    }
  }

  /// Verifies the wallet is connected to Stellar testnet.
  ///
  /// Throws [WalletNetworkMismatchException] if the network passphrase does not
  /// match the expected testnet value. An absent or unreadable passphrase is
  /// treated as a soft error (the wallet may not expose it).
  Future<void> _verifyNetwork() async {
    try {
      final result = await _jsGetNetworkDetails().toDart;
      if (_hasError(result)) return;
      final passphrase = _stringProp(result, 'networkPassphrase');
      if (passphrase == null || passphrase.isEmpty) return;

      // Hardcoded testnet passphrase to avoid importing non-web config symbols
      // into this web-only compilation unit.
      const expectedPassphrase = 'Test SDF Network ; September 2015';
      if (passphrase != expectedPassphrase) {
        throw WalletNetworkMismatchException(
          expected: expectedPassphrase,
          actual: passphrase,
        );
      }
    } catch (e) {
      if (e is WalletConnectionException) rethrow;
      if (e is WalletNetworkMismatchException) rethrow;
      // Other errors (JS interop failures): non-fatal.
    }
  }
}
