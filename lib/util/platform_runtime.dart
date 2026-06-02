/// Runtime detection of the host platform's physicality.
///
/// Exposes [detectIsPhysicalDevice] which returns `true` when the demo runs
/// on a real device (or on Web, where the Freighter browser extension is a
/// real signing source) and `false` on the iOS Simulator or an Android
/// emulator. The wallet-pairing UI (Reown / Freighter Mobile deep links) is
/// gated on the returned value because the deep link cannot reach a real
/// wallet app from a simulated environment.
///
/// Conditional implementation:
/// - On non-native (Web) builds: always `true`.
/// - On native platforms (`dart.library.io`): consults `device_info_plus`
///   for the platform-specific `isPhysicalDevice` flag.
library;

export 'platform_runtime_stub.dart'
    if (dart.library.io) 'platform_runtime_io.dart';
