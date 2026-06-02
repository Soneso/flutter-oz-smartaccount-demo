/// Adapter types for wrapping SDK wallet operations in the creation flow.
///
/// Separating these types from [WalletCreationFlow] avoids a circular import
/// between [MainScreenFlow] (which constructs the adapter) and
/// [WalletCreationFlow] (which consumes it).
library;

import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

// ---------------------------------------------------------------------------
// WalletOperationsType
// ---------------------------------------------------------------------------

/// Abstraction over the SDK wallet operations used by [WalletCreationFlow].
///
/// Exists so unit tests can inject a mock without instantiating a real
/// [OZSmartAccountKit]. The interface exposes only the subset of
/// [OZWalletOperations] that the flow requires.
///
/// Production code passes [kit.walletOperations] through a
/// [WalletOperationsAdapter]. Tests inject a [MockWalletOperations].
abstract interface class WalletOperationsType {
  /// Creates a new smart account wallet.
  ///
  /// This is a subset of [OZWalletOperations.createWallet]. The [forceMethod]
  /// parameter is intentionally omitted; the flow always relies on the kit's
  /// default submission method.
  Future<CreateWalletResult> createWallet({
    required String userName,
    required bool autoSubmit,
    required bool autoFund,
    String? nativeTokenContract,
  });
}

// ---------------------------------------------------------------------------
// WalletOperationsAdapter
// ---------------------------------------------------------------------------

/// Production adapter that forwards [WalletOperationsType] calls to the
/// underlying [OZWalletOperations].
final class WalletOperationsAdapter implements WalletOperationsType {
  /// Constructs an adapter wrapping [inner].
  const WalletOperationsAdapter(this._inner);

  final OZWalletOperations _inner;

  @override
  Future<CreateWalletResult> createWallet({
    required String userName,
    required bool autoSubmit,
    required bool autoFund,
    String? nativeTokenContract,
  }) {
    return _inner.createWallet(
      userName: userName,
      autoSubmit: autoSubmit,
      autoFund: autoFund,
      nativeTokenContract: nativeTokenContract,
    );
  }
}
