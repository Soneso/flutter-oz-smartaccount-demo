/// Web implementation of [detectIsPhysicalDevice].
///
/// On Web the Freighter browser extension fills the role of a "real" signing
/// source and lives in the same process as the dApp, so no simulator gating
/// is needed; always return `true`.
library;

Future<bool> detectIsPhysicalDevice() async => true;
