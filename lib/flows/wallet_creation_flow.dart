/// Business logic for the wallet creation screen.
///
/// [WalletCreationFlow] is the single entry point for wallet creation. The
/// [WalletCreationScreen] delegates every SDK interaction here; screens must
/// not call into the SDK directly.
///
/// Re-entrancy:
/// [createWallet] uses a boolean [_isCreating] flag to reject concurrent calls.
/// Any call that arrives while creation is in flight throws
/// [WalletCreationError.creationFailed] immediately without entering the async
/// body. The screen's [LoadingButton] also prevents double-tap; the flag is an
/// additional safeguard for callers outside the screen.
///
/// Failure modes (see [WalletCreationError]):
/// - [WalletCreationError.invalidUsername] — before any SDK call.
/// - [WalletCreationError.userCanceled] — passkey sheet dismissed by user.
/// - [WalletCreationError.webAuthnKeyFormatInvalid] — structural key check.
/// - [WalletCreationError.creationFailed] — SDK or network error; or reentrancy.
library;

import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import '../config/demo_config.dart' as config;
import '../state/activity_log_state.dart';
import '../state/demo_state.dart';
import '../token/demo_token_service.dart';
import '../util/error_utils.dart';
import '../util/format_utils.dart';
import '../wallet/wallet_operations_adapter.dart';
import 'main_screen_flow.dart';

// ---------------------------------------------------------------------------
// WalletCreationResult
// ---------------------------------------------------------------------------

/// Successful outcome of a [WalletCreationFlow.createWallet] call.
///
/// All fields are populated when [createWallet] returns without throwing.
/// When [autoSubmit] was false, [isDeployed] is false and the user must
/// trigger deployment later via the Pending Deployment flow.
final class WalletCreationResult {
  /// Constructs a wallet-creation result.
  const WalletCreationResult({
    required this.contractAddress,
    required this.credentialId,
    required this.isDeployed,
    this.xlmBalance,
    this.demoTokenBalance,
    this.transactionHash,
  });

  /// Smart account contract address (C-address) of the newly created wallet.
  final String contractAddress;

  /// Base64URL-encoded WebAuthn credential identifier.
  final String credentialId;

  /// True when the deploy transaction was submitted and confirmed on-chain
  /// ([autoSubmit] was true); false when deployment is pending.
  final bool isDeployed;

  /// XLM balance string after creation, or null when unavailable.
  final String? xlmBalance;

  /// DEMO token balance string after minting, or null when not minted or
  /// balance unavailable.
  final String? demoTokenBalance;

  /// On-chain transaction hash for the deploy transaction, or null when the
  /// contract was not deployed (autoSubmit was false) or the SDK did not
  /// surface a hash.
  final String? transactionHash;
}

// ---------------------------------------------------------------------------
// WalletCreationError
// ---------------------------------------------------------------------------

/// Errors thrown by [WalletCreationFlow.createWallet].
///
/// Each variant carries an [actionableMessage] suitable for displaying in an
/// error banner or the activity log. Cases are ordered from most-recoverable
/// (user action needed) to least-recoverable (SDK/network failure).
sealed class WalletCreationError implements Exception {
  const WalletCreationError._();

  // ---- Variants ----

  /// The username field failed local validation before any SDK call.
  ///
  /// Trigger: username is empty or whitespace-only.
  /// Recovery: user corrects the input and retries.
  const factory WalletCreationError.invalidUsername(String reason) =
      _InvalidUsernameError;

  /// The user dismissed the passkey ceremony sheet before completing it.
  ///
  /// Trigger: [WebAuthnCancelled] thrown by the platform authenticator.
  /// Recovery: show a neutral "cancelled" message; re-enable Create button.
  const factory WalletCreationError.userCanceled() = _UserCanceledError;

  /// The demo-layer credential public key format check failed.
  ///
  /// Trigger: the public key returned by the SDK is not a valid 65-byte
  /// uncompressed secp256r1 key with the required 0x04 prefix. This indicates
  /// malformed attestation data or an unexpected key format from the passkey
  /// ceremony. The platform authenticator and the SDK independently enforce
  /// origin/type/crossOrigin and COSE key validity before this check runs.
  ///
  /// Recovery: surfaced as an error banner; user may retry.
  const factory WalletCreationError.webAuthnKeyFormatInvalid(String reason) =
      _WebAuthnKeyFormatInvalidError;

  /// The SDK [createWallet] call threw an error unrelated to user cancellation
  /// or credential format. Also thrown by the reentrancy guard.
  ///
  /// Trigger: network error, RPC failure, storage failure, deploy failure, or
  /// a concurrent [createWallet] call while [_isCreating] is true.
  /// Recovery: show [actionableMessage] in error banner; user may retry.
  const factory WalletCreationError.creationFailed(String reason) =
      _CreationFailedError;

  // ---- Common interface ----

  /// Short, actionable message suitable for display in an error banner or log.
  String get actionableMessage;

  /// True when this error represents a user-initiated cancellation.
  ///
  /// Screens use this to show a neutral "cancelled" banner rather than an error
  /// banner. All other [WalletCreationError] variants show an error banner.
  bool get isUserCanceled => false;

  /// True when this error is a local input validation failure.
  ///
  /// Screens may use this to focus the offending field or show an inline hint.
  bool get isInvalidUsername => false;

  /// The bare reason string, without any error-category prefix.
  ///
  /// For [invalidUsername], this is the raw validation message (e.g. "Username
  /// must not be empty."). For all other variants it equals [actionableMessage].
  /// Screens that use [isInvalidUsername] to show an inline field hint should
  /// prefer [reason] over [actionableMessage] to avoid the "Invalid username:"
  /// prefix.
  String get reason => actionableMessage;
}

final class _InvalidUsernameError extends WalletCreationError {
  const _InvalidUsernameError(this._rawReason) : super._();
  final String _rawReason;

  @override
  bool get isInvalidUsername => true;

  /// Returns the bare validation reason without the "Invalid username:" prefix.
  @override
  String get reason => _rawReason;

  @override
  String get actionableMessage => 'Invalid username: $_rawReason';

  @override
  String toString() => 'WalletCreationError.invalidUsername($_rawReason)';
}

final class _UserCanceledError extends WalletCreationError {
  const _UserCanceledError() : super._();

  @override
  bool get isUserCanceled => true;

  @override
  String get actionableMessage => 'Wallet creation was cancelled.';

  @override
  String toString() => 'WalletCreationError.userCanceled';
}

final class _WebAuthnKeyFormatInvalidError extends WalletCreationError {
  const _WebAuthnKeyFormatInvalidError(this._reason) : super._();
  final String _reason;

  @override
  String get reason => _reason;

  @override
  String get actionableMessage => 'Passkey key format invalid: $_reason';

  @override
  String toString() => 'WalletCreationError.webAuthnKeyFormatInvalid($_reason)';
}

final class _CreationFailedError extends WalletCreationError {
  const _CreationFailedError(this._reason) : super._();
  final String _reason;

  @override
  String get reason => _reason;

  @override
  String get actionableMessage => _reason;

  @override
  String toString() => 'WalletCreationError.creationFailed($_reason)';
}

// ---------------------------------------------------------------------------
// WalletCreationFlow
// ---------------------------------------------------------------------------

/// Business logic for the wallet creation screen.
///
/// Construct once per screen instance, passing the Riverpod notifiers and
/// required SDK adapter as direct dependencies. This makes the flow fully
/// unit-testable without requiring a widget environment.
///
/// The [WalletCreationScreen] builds this flow in its action handler via
/// [WalletOperationsAdapter], and passes the shared [MainScreenFlow] so that
/// the post-creation balance refresh runs through the canonical refresh path.
///
/// See [WalletCreationScreen] for a usage example.
final class WalletCreationFlow {
  /// Constructs a flow with injected dependencies.
  ///
  /// [demoState] and [activityLog] are the Riverpod notifiers. [walletOperations]
  /// is the SDK adapter. [demoTokenService] is the optional DEMO token service;
  /// when provided, minting is always attempted after successful creation (mint
  /// failure is non-fatal). [mainScreenFlow] is the shared flow whose
  /// [refreshBalances] is called after successful creation.
  WalletCreationFlow({
    required DemoStateNotifier demoState,
    required ActivityLogNotifier activityLog,
    required WalletOperationsType walletOperations,
    DemoTokenServiceType? demoTokenService,
    MainScreenFlow? mainScreenFlow,
  })  : _demoState = demoState,
        _activityLog = activityLog,
        _walletOperations = walletOperations,
        _demoTokenService = demoTokenService,
        _mainScreenFlow = mainScreenFlow;

  final DemoStateNotifier _demoState;
  final ActivityLogNotifier _activityLog;
  final WalletOperationsType _walletOperations;
  final DemoTokenServiceType? _demoTokenService;
  final MainScreenFlow? _mainScreenFlow;

  // ---- Re-entrancy guard ----

  /// True while [createWallet] is executing.
  ///
  /// Prevents a concurrent second call from starting a second creation attempt.
  /// The [LoadingButton] already guards against double-tap; this flag is an
  /// additional safeguard for any non-screen caller.
  bool _isCreating = false;

  // -------------------------------------------------------------------------
  // Public: createWallet
  // -------------------------------------------------------------------------

  /// Creates a new smart account wallet.
  ///
  /// Happy path:
  /// 1. Validates [username] (non-empty, non-whitespace-only).
  /// 2. Calls [walletOperations.createWallet] which triggers the passkey
  ///    ceremony and, when [autoSubmit] is true, deploys the contract.
  ///    [autoFund] mirrors [autoSubmit] — funding runs iff deployment runs.
  /// 3. Runs the demo-layer credential public key format check on the returned
  ///    public key (verifies 65-byte uncompressed secp256r1 format with 0x04
  ///    prefix). The platform authenticator and the SDK independently enforce
  ///    origin/type/crossOrigin and COSE key validity before this check runs.
  /// 4. Updates [DemoStateNotifier] to the connected state.
  /// 5. Calls [mainScreenFlow.refreshBalances] to populate both the XLM and
  ///    DEMO token balances via the canonical balance-refresh path.
  /// 6. Attempts [demoTokenService.ensureTokenAndMint] when autoSubmit is true
  ///    and the service is non-null. Mint failure is non-fatal: it is logged at
  ///    error level and does not prevent the [WalletCreationResult] from being
  ///    returned.
  ///
  /// Throws [WalletCreationError].
  ///
  /// [onProgress] is called with a short status string at two long-running
  /// transitions: once at the start of the SDK call, and once just before the
  /// demo token mint step (autoSubmit path only). Callers may use this to
  /// update button labels or progress indicators. The callback is always
  /// invoked synchronously on the caller's event loop; no post-frame scheduling
  /// is required.
  Future<WalletCreationResult> createWallet({
    required String username,
    required bool autoSubmit,
    Function(String)? onProgress,
  }) async {
    if (_isCreating) {
      throw const WalletCreationError.creationFailed('already in progress');
    }
    _isCreating = true;
    try {
      final trimmed = _validateUsername(username);
      // autoFund mirrors autoSubmit — funding only makes sense when the
      // contract is deployed immediately.
      final autoFund = autoSubmit;
      onProgress?.call('Creating wallet...');
      final sdkResult = await _invokeSDK(
        userName: trimmed,
        autoSubmit: autoSubmit,
        autoFund: autoFund,
      );
      _verifyCredentialPublicKey(sdkResult);
      _commitConnectionState(sdkResult: sdkResult, autoSubmit: autoSubmit);
      await _refreshBalancesIfPossible();
      // Capture balance after refresh so the result card can display them.
      final xlmBalance = _demoState.currentState.xlmBalance;
      String? demoTokenBalance;
      if (autoSubmit) {
        onProgress?.call('Deploying demo token...');
        demoTokenBalance = await _attemptMint(sdkResult: sdkResult);
      }
      return WalletCreationResult(
        contractAddress: sdkResult.contractId,
        credentialId: sdkResult.credentialId,
        isDeployed: autoSubmit,
        xlmBalance: xlmBalance,
        demoTokenBalance: demoTokenBalance,
        transactionHash: sdkResult.transactionHash,
      );
    } finally {
      _isCreating = false;
    }
  }

  // -------------------------------------------------------------------------
  // Private: createWallet sub-steps
  // -------------------------------------------------------------------------

  /// Validates the username and returns the trimmed value.
  ///
  /// Throws [WalletCreationError.invalidUsername] when empty after trimming.
  String _validateUsername(String username) {
    final trimmed = username.trim();
    if (trimmed.isEmpty) {
      throw const WalletCreationError.invalidUsername(
        'Username must not be empty.',
      );
    }
    return trimmed;
  }

  /// Calls [_walletOperations.createWallet] and maps any error to a typed
  /// [WalletCreationError].
  ///
  /// [WebAuthnCancelled] is mapped to [WalletCreationError.userCanceled] and
  /// logged at info level. All other errors are mapped to
  /// [WalletCreationError.creationFailed] and logged at error level.
  Future<OZCreateWalletResult> _invokeSDK({
    required String userName,
    required bool autoSubmit,
    required bool autoFund,
  }) async {
    final safeName = safeUserNameForLog(userName);
    _activityLog.info('Creating wallet for "$safeName"...');
    try {
      return await _walletOperations.createWallet(
        userName: userName,
        autoSubmit: autoSubmit,
        autoFund: autoFund,
        nativeTokenContract: autoFund ? config.nativeTokenContract : null,
      );
    } catch (e) {
      final mapped = _mapCreationError(e);
      _logCreationError(mapped, original: e);
      throw mapped;
    }
  }

  /// Logs the mapped creation error at the appropriate severity level.
  ///
  /// User cancellations are logged at info (neutral); all other errors at error.
  void _logCreationError(WalletCreationError mapped, {required Object original}) {
    if (mapped is _UserCanceledError) {
      _activityLog.info('Wallet creation cancelled by user.');
    } else {
      final classified = classifyError(original);
      _activityLog.error('Wallet creation failed: ${classified.message}');
    }
  }

  /// Maps a raw error to a [WalletCreationError].
  ///
  /// Only the typed [WebAuthnCancelled] exception maps to
  /// [WalletCreationError.userCanceled]. Relying solely on the typed exception
  /// prevents heuristic message matching from misclassifying real RPC failures
  /// whose text happens to contain cancellation-adjacent substrings such as
  /// "not allowed", "abort", or "dismissed".
  ///
  /// All other errors map to [WalletCreationError.creationFailed] with the
  /// actionable message produced by [classifyError].
  WalletCreationError _mapCreationError(Object error) {
    if (error is WebAuthnCancelled) {
      return const WalletCreationError.userCanceled();
    }
    final classified = classifyError(error);
    return WalletCreationError.creationFailed(classified.message);
  }

  /// Verifies that the credential public key is a valid 65-byte uncompressed
  /// secp256r1 key with the required 0x04 prefix.
  ///
  /// This is a structural format check, not a ceremony or freshness check.
  /// The platform authenticator enforces origin binding, type, and crossOrigin
  /// at the ceremony layer; the SDK independently validates COSE key extraction.
  /// This check provides an additional guard that the returned key bytes match
  /// the expected secp256r1 uncompressed format before the key is registered
  /// on-chain.
  ///
  /// Note: [clientDataJSON] fields (origin, type, crossOrigin) cannot be
  /// re-verified here because [OZCreateWalletResult] does not surface
  /// [clientDataJSON] or [attestationObject]. The structural ceiling for
  /// registration-time demo-layer rechecks is this key-format guard.
  ///
  /// Throws [WalletCreationError.webAuthnKeyFormatInvalid] when the key does
  /// not pass the 65-byte / 0x04-prefix check.
  void _verifyCredentialPublicKey(OZCreateWalletResult sdkResult) {
    final key = sdkResult.publicKey;
    final isValid = key.length == 65 && key[0] == 0x04;
    if (!isValid) {
      final reason =
          'Credential public key is not a valid uncompressed secp256r1 key '
          '(expected 65 bytes starting with 0x04, got ${key.length} bytes).';
      _activityLog.error('Credential key format check failed: $reason');
      throw WalletCreationError.webAuthnKeyFormatInvalid(reason);
    }
  }

  /// Updates [DemoStateNotifier] to the connected state and logs success.
  void _commitConnectionState({
    required OZCreateWalletResult sdkResult,
    required bool autoSubmit,
  }) {
    _demoState.setConnected(
      contractId: sdkResult.contractId,
      credentialId: sdkResult.credentialId,
      isDeployed: autoSubmit,
    );
    final shortAddr = truncateAddress(sdkResult.contractId);
    final safeCredId = _redactCredentialId(sdkResult.credentialId);
    if (autoSubmit) {
      _activityLog.success(
        'Wallet created and deployed: $shortAddr (cred: $safeCredId)',
      );
    } else {
      _activityLog.success(
        'Passkey registered: $shortAddr (cred: $safeCredId) '
        '— deployment pending.',
      );
    }
  }

  /// Refreshes XLM and DEMO token balances by delegating to [_mainScreenFlow].
  ///
  /// When [_mainScreenFlow] is null (unit tests with no main screen) the refresh
  /// is skipped. Errors are non-fatal and logged by [MainScreenFlow] internally.
  Future<void> _refreshBalancesIfPossible() async {
    await _mainScreenFlow?.refreshBalances();
  }

  /// Attempts to mint DEMO tokens when [_demoTokenService] is non-null.
  ///
  /// Delegates to [provisionDemoTokens] so the orchestration is identical to
  /// the main-screen Deploy Now path. Mint failure is non-fatal: the shared
  /// helper logs the curated [DemoTokenServiceException.message] when present
  /// and returns null.
  Future<String?> _attemptMint({
    required OZCreateWalletResult sdkResult,
  }) {
    return provisionDemoTokens(
      service: _demoTokenService,
      demoState: _demoState,
      activityLog: _activityLog,
      onRefreshBalances: () async =>
          _mainScreenFlow?.refreshBalances() ?? Future<void>.value(),
      recipientContractId: sdkResult.contractId,
    );
  }

  // -------------------------------------------------------------------------
  // Helpers (pure, static — testable without a flow instance)
  // -------------------------------------------------------------------------

  /// Returns a log-safe representation of [username].
  ///
  /// Truncates to 32 characters, strips non-ASCII characters and newlines
  /// (prevents RTL/zero-width injections and avoids echoing multi-KB or
  /// credential-shaped display names), then passes through [redactMessage].
  static String safeUserNameForLog(String username) {
    final truncated = username.length > 32
        ? username.substring(0, 32)
        : username;
    final buffer = StringBuffer();
    for (final codeUnit in truncated.codeUnits) {
      // Accept only printable ASCII (0x20–0x7E), exclude newlines and control
      // characters.
      if (codeUnit >= 0x20 && codeUnit <= 0x7E) {
        buffer.writeCharCode(codeUnit);
      }
    }
    return redactMessage(buffer.toString());
  }

  /// Truncates a credential ID to a safe display form (first 8 / last 8 chars).
  static String _redactCredentialId(String credentialId) {
    if (credentialId.length <= 16) return credentialId;
    final start = credentialId.substring(0, 8);
    final end = credentialId.substring(credentialId.length - 8);
    return '$start...$end';
  }
}
