/// Riverpod provider for the shared [DemoTokenService] adapter.
///
/// Both [MainScreenFlow] (Deploy Now path) and the [WalletCreationFlow]
/// factory in [WalletCreationScreen] read this provider so they share a
/// single [DemoTokenService] instance. Sharing keeps the deterministic
/// admin keypair and the cached deployed-contract id consistent across the
/// two entry points instead of two independent service instances racing on
/// the same on-chain contract.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/demo_config.dart' as config;
import '../token/demo_token_service.dart';
import 'demo_state.dart';

/// Provider for the shared [DemoTokenServiceType] adapter.
///
/// Created lazily on first read; lives for the lifetime of the
/// [ProviderContainer]. Tests override this provider to inject a mock.
final demoTokenServiceProvider = Provider<DemoTokenServiceType>((ref) {
  return DemoTokenServiceAdapter(
    DemoTokenService(
      rpcUrl: config.rpcUrl,
      networkPassphrase: config.networkPassphrase,
    ),
  );
});

/// The demo token's contract address: its deployed contract id when known,
/// otherwise the deterministic derived address, so callers (e.g. a token
/// field default) always have a concrete address without reaching into the
/// SDK-wrapping [DemoTokenService] from the UI layer.
final demoTokenAddressProvider = Provider<String>((ref) {
  final deployed =
      ref.watch(demoStateProvider.select((s) => s.demoTokenContractId));
  return deployed ?? DemoTokenService.deriveContractAddress();
});
