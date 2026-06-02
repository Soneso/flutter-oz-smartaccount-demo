/// Entry point for the Smart Account Demo app.
///
/// Platform-specific dependencies (WebAuthn provider and storage adapter) are
/// resolved and injected into [DemoStateNotifier] BEFORE [runApp] is called.
/// This ensures the Riverpod container is bootstrapped with valid singletons
/// when the first widget tree is built.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import 'config/demo_config.dart' as config;
import 'navigation/routes.dart';
import 'state/demo_state.dart';
import 'state/theme_mode_provider.dart';
import 'theme/app_theme.dart';
import 'util/platform_runtime.dart';
import 'wallet/wallet_import_connector.dart';

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

Future<void> main() async {
  // Ensure Flutter engine bindings are initialised before accessing platform
  // channels or the asset bundle.
  WidgetsFlutterBinding.ensureInitialized();

  // Resolve simulator/emulator vs physical-device status once, before the
  // first frame, so UI gating reads a stable value. The call is cheap (~tens
  // of ms on first hit, cached thereafter) and lets the wallet-pairing UI
  // hide cleanly on hosts that cannot deep-link to a real wallet app.
  final isPhysicalDevice = await detectIsPhysicalDevice();

  // On Web, Flutter renders to a canvas and emits no semantic DOM nodes by
  // default; assistive technology has to ask for them first. Enabling
  // semantics up-front means screen readers work without the user having to
  // click the placeholder "Enable accessibility" button, and external
  // accessibility-tree consumers can introspect the rendered UI immediately.
  // On native platforms, the OS already routes semantics through platform
  // channels — no opt-in needed.
  if (kIsWeb) {
    SemanticsBinding.instance.ensureSemantics();
  }

  // Construct the Riverpod container early so platform singletons can be
  // injected before the first frame is rendered.
  final container = ProviderContainer();

  // Resolve the platform-appropriate WebAuthn provider and storage adapter.
  // These are set once at startup and never replaced during the app's lifetime.
  final (webAuthnProvider, storageAdapter) = _resolvePlatformDependencies();

  // Inject into the notifier's plain fields so the kit factory in
  // MainScreenFlow can access them at initializeKit() time.
  final connector = createImportConnector();
  container.read(demoStateProvider.notifier)
    ..webAuthnProvider = webAuthnProvider
    ..storage = storageAdapter
    ..walletConnector = connector
    ..isPhysicalDevice = isPhysicalDevice;

  // Eagerly bring up the connector's relay WebSocket at process start so
  // it is already connected by the time the user pairs with an external
  // wallet. Fire-and-forget; the lazy-init guard inside the handler still
  // covers the race window if warm-up has not completed by then.
  unawaited(
    warmUpImportConnector(connector).catchError(
      (Object error, StackTrace stackTrace) {
        debugPrint('[wallet.connector] warm-up failed: $error');
      },
    ),
  );

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const SmartAccountDemoApp(),
    ),
  );
}

// ---------------------------------------------------------------------------
// Platform dependency resolution
// ---------------------------------------------------------------------------

/// Returns the (WebAuthnProvider, StorageAdapter) pair for the current platform.
///
/// On Web: BrowserWebAuthnProvider + IndexedDBStorageAdapter.
///   BrowserWebAuthnProvider drives navigator.credentials in the browser.
///   IndexedDBStorageAdapter persists credentials to IndexedDB (no sensitive
///   signing material is stored — metadata only).
///
/// On mobile (iOS, Android): PlatformWebAuthnProvider + PlatformStorageAdapter.
///   Both dispatch to the native SDK method-channel plugins:
///   - iOS: Keychain (kSecAttrAccessibleAfterFirstUnlock, no iCloud sync).
///   - Android: EncryptedSharedPreferences (AES-256-GCM, Keystore-backed).
(WebAuthnProvider, StorageAdapter) _resolvePlatformDependencies() {
  if (kIsWeb) {
    return (
      BrowserWebAuthnProvider(
        rpId: config.defaultRpId,
        rpName: config.rpName,
      ),
      IndexedDBStorageAdapter(),
    );
  }
  return (
    PlatformWebAuthnProvider(
      rpId: config.defaultRpId,
      rpName: config.rpName,
    ),
    PlatformStorageAdapter(),
  );
}

// ---------------------------------------------------------------------------
// Root application widget
// ---------------------------------------------------------------------------

/// Root widget for the Smart Account Demo.
///
/// Configures the Material 3 light + dark themes and mounts the go_router
/// navigator. The active [ThemeMode] is observed from
/// [themeModeProvider] so the in-AppBar toggle takes effect immediately.
/// No business logic lives here — all flows are in [lib/flows/].
class SmartAccountDemoApp extends ConsumerStatefulWidget {
  const SmartAccountDemoApp({super.key});

  @override
  ConsumerState<SmartAccountDemoApp> createState() =>
      _SmartAccountDemoAppState();
}

class _SmartAccountDemoAppState extends ConsumerState<SmartAccountDemoApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    // Wake the connector's relay WebSocket on foreground so queued
    // session-settle / signing-response messages surface immediately
    // rather than waiting for the SDK heartbeat to notice the dead socket.
    final connector = ref.read(demoStateProvider.notifier).walletConnector;
    unawaited(
      resumeImportConnector(connector).catchError(
        (Object error, StackTrace stackTrace) {
          debugPrint('[wallet.connector] resume reconnect failed: $error');
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(themeModeProvider);
    return MaterialApp.router(
      title: 'Smart Account Demo',
      debugShowCheckedModeBanner: false,
      theme: buildLightTheme(),
      darkTheme: buildDarkTheme(),
      themeMode: mode,
      routerConfig: appRouter,
    );
  }
}
