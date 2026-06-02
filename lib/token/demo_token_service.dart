/// Demo token service — deploys and mints the DEMO Soroban token.
///
/// Manages a deterministic demo token contract for testing smart account
/// transfers. The contract address is fully deterministic: the same deployer
/// keypair and salt always produce the same address, regardless of platform or
/// app instance, so all demo installations share one token contract.
///
/// Admin keypair derivation:
///   adminSeed  = SHA-256([DemoConfig.demoTokenAdminSeed])
///   adminKeyPair = Ed25519(adminSeed)
///
/// Contract salt derivation:
///   salt = SHA-256([DemoConfig.demoTokenSaltSeed])
///
/// Contract address derivation follows the Soroban ContractID preimage protocol:
///   1. networkId = SHA-256(networkPassphrase)
///   2. preimage  = ContractID { networkId, FromAddress { admin, salt } }
///   3. tokenContractId = SHA-256(XDR-encode(preimage))
///   4. C-address = StrKey.encodeContractId(tokenContractId)
///
/// This is a testnet-only service. [ensureTokenAndMint] hard-fails at
/// construction time if [networkPassphrase] is not the Stellar testnet
/// passphrase.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import '../config/demo_config.dart' as config;
import '../state/activity_log_state.dart';
import '../state/demo_state.dart';
import '../util/error_utils.dart';
import '../util/format_utils.dart';
import '../util/wasm_resource.dart';

// ---------------------------------------------------------------------------
// Exceptions
// ---------------------------------------------------------------------------

/// Thrown by [DemoTokenService] when a precondition or operation fails.
sealed class DemoTokenServiceException implements Exception {
  const DemoTokenServiceException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() =>
      cause != null
          ? '$runtimeType: $message (cause: $cause)'
          : '$runtimeType: $message';

  /// Thrown when the service is used against a non-testnet network.
  ///
  /// [DemoTokenService] is testnet-only and hard-fails immediately when
  /// configured with any other network passphrase.
  factory DemoTokenServiceException.notTestnet(String actual) =
      _NotTestnetException;

  /// Thrown when the token contract address does not match the expected
  /// deterministic address after deployment. Indicates a derivation bug.
  factory DemoTokenServiceException.addressMismatch({
    required String expected,
    required String actual,
  }) = _AddressMismatchException;

  /// Thrown when a Soroban RPC call fails during token deployment or minting.
  factory DemoTokenServiceException.rpcError(
    String detail, {
    Object? cause,
  }) = _RpcErrorException;
}

final class _NotTestnetException extends DemoTokenServiceException {
  const _NotTestnetException(String actual)
      : super(
          'DemoTokenService is testnet-only. '
          'Expected network passphrase: "${config.networkPassphrase}". '
          'Got: "$actual". '
          'Switch your SDK config to testnet before using DemoTokenService.',
        );
}

final class _AddressMismatchException extends DemoTokenServiceException {
  const _AddressMismatchException({
    required String expected,
    required String actual,
  }) : super(
          'Deployed token contract address ($actual) does not match the '
          'pre-derived deterministic address ($expected). '
          'This is a bug in the salt/deployer derivation logic.',
        );
}

final class _RpcErrorException extends DemoTokenServiceException {
  const _RpcErrorException(super.detail, {super.cause});
}

// ---------------------------------------------------------------------------
// Result type
// ---------------------------------------------------------------------------

/// Result of [DemoTokenService.ensureTokenAndMint].
final class DemoTokenResult {
  const DemoTokenResult({
    required this.tokenContractId,
    required this.amountMinted,
    required this.alreadyExisted,
  });

  /// C-address of the DEMO token contract.
  final String tokenContractId;

  /// Amount minted in stroops (7 decimals: divide by 10^7 for display).
  final int amountMinted;

  /// True when the contract was already deployed before this call.
  final bool alreadyExisted;
}

// ---------------------------------------------------------------------------
// DemoTokenService
// ---------------------------------------------------------------------------

/// Manages the deterministic DEMO token contract for the smart account demo.
///
/// The admin keypair is derived from [config.demoTokenAdminSeed] via SHA-256.
/// It is intentionally public — testnet-only and documented in README. Do not
/// use this service or its derived admin key on any other network.
///
/// Usage:
/// ```dart
/// final service = DemoTokenService(
///   rpcUrl: config.rpcUrl,
///   networkPassphrase: config.networkPassphrase,
/// );
/// final result = await service.ensureTokenAndMint(
///   recipientContractId: contractAddress,
/// );
/// ```
class DemoTokenService {
  /// Constructs the service and validates the network passphrase.
  ///
  /// Throws [DemoTokenServiceException.notTestnet] immediately if
  /// [networkPassphrase] is not the Stellar testnet passphrase.
  DemoTokenService({
    required String rpcUrl,
    required String networkPassphrase,
  }) : _rpcUrl = rpcUrl,
       _networkPassphrase = networkPassphrase {
    // Hard-fail at construction time so the error surfaces immediately,
    // not on the first async network call.
    if (networkPassphrase != config.networkPassphrase) {
      throw DemoTokenServiceException.notTestnet(networkPassphrase);
    }
  }

  final String _rpcUrl;
  final String _networkPassphrase;

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Ensures the DEMO token contract is deployed and mints to [recipientContractId].
  ///
  /// Deploy is idempotent: if the contract already exists on-chain,
  /// deployment is skipped. Mint is additive: each call mints
  /// [config.demoTokenMintAmount] stroops to the recipient.
  ///
  /// Throws [DemoTokenServiceException] when deployment or minting fails.
  Future<DemoTokenResult> ensureTokenAndMint({
    required String recipientContractId,
  }) async {
    final adminKeyPair = _deriveAdminKeyPair();
    final adminId = adminKeyPair.accountId;
    final salt = _deriveTokenSalt();
    final tokenContractId = _deriveTokenContractAddress(
      deployerPublicKey: adminId,
      salt: salt,
    );

    final server = SorobanServer(_rpcUrl);

    // Fund the admin account if it does not yet exist on testnet.
    // FriendBot is idempotent for already-funded accounts.
    //
    // SorobanServer.getAccount returns null (not throw) for accounts not yet on the ledger; the null branch triggers FriendBot funding.
    Account? adminAccount;
    try {
      adminAccount = await server.getAccount(adminId);
    } on Exception {
      adminAccount = null;
    }
    if (adminAccount == null) {
      await FriendBot.fundTestAccount(adminId);
      // Allow the network time to process the funding transaction.
      await Future<void>.delayed(const Duration(seconds: 5));
    }

    final alreadyExisted =
        await _contractExistsOnChain(server, tokenContractId);

    if (!alreadyExisted) {
      final wasmBytes = await loadTokenContractWasm();
      await _deployTokenContract(
        server: server,
        adminKeyPair: adminKeyPair,
        salt: salt,
        wasmBytes: wasmBytes,
        expectedContractId: tokenContractId,
      );
    }

    await _mintTokens(
      server: server,
      adminKeyPair: adminKeyPair,
      tokenContractId: tokenContractId,
      recipientContractId: recipientContractId,
    );

    return DemoTokenResult(
      tokenContractId: tokenContractId,
      amountMinted: config.demoTokenMintAmount,
      alreadyExisted: alreadyExisted,
    );
  }

  // ---------------------------------------------------------------------------
  // Static / pure helpers exposed for testing
  // ---------------------------------------------------------------------------

  /// Returns the G-address of the deterministic token admin.
  ///
  /// Useful for balance queries and as a simulation source account.
  static String adminAddress() => _deriveAdminKeyPair().accountId;

  /// Derives the deterministic DEMO token contract C-address.
  ///
  /// Pure computation — no network call. Identical inputs always produce the
  /// same output on every platform.
  static String deriveContractAddress() {
    final kp = _deriveAdminKeyPair();
    final salt = _deriveTokenSalt();
    return _deriveTokenContractAddress(
      deployerPublicKey: kp.accountId,
      salt: salt,
    );
  }

  // ---------------------------------------------------------------------------
  // Private derivation helpers (static — no instance state needed)
  // ---------------------------------------------------------------------------

  /// Derives the token admin keypair from [config.demoTokenAdminSeed].
  ///
  /// SHA-256 of the seed string produces a stable 32-byte raw secret that
  /// is the same on every run. The admin account can be funded once and reused.
  static KeyPair _deriveAdminKeyPair() {
    final seedBytes = Uint8List.fromList(
      crypto.sha256.convert(utf8.encode(config.demoTokenAdminSeed)).bytes,
    );
    return KeyPair.fromSecretSeedList(seedBytes);
  }

  /// Derives the 32-byte deployment salt from [config.demoTokenSaltSeed].
  ///
  /// SHA-256 of the seed string produces a fixed 32-byte salt. Because the
  /// Soroban ContractID derivation uses the same salt, the resulting contract
  /// address is always identical regardless of when or where deployment runs.
  static Uint8List _deriveTokenSalt() {
    return Uint8List.fromList(
      crypto.sha256.convert(utf8.encode(config.demoTokenSaltSeed)).bytes,
    );
  }

  /// Derives the Soroban contract C-address for [deployerPublicKey] + [salt].
  ///
  /// Follows the Soroban ContractID preimage protocol:
  ///   networkId  = SHA-256(networkPassphrase)
  ///   preimage   = ContractID { networkId, FromAddress { deployer, salt } }
  ///   contractId = SHA-256(XDR-encode(preimage))
  ///   C-address  = StrKey.encodeContractId(contractId)
  ///
  /// This is the same derivation used by the Soroban host and by the SDK's
  /// [SmartAccountUtils.deriveContractAddress] (which computes the salt from a
  /// credential ID). Here we pass the raw salt directly.
  static String _deriveTokenContractAddress({
    required String deployerPublicKey,
    required Uint8List salt,
  }) {
    // Step 1: network ID = SHA-256(networkPassphrase).
    final networkIdBytes = Uint8List.fromList(
      crypto.sha256.convert(utf8.encode(config.networkPassphrase)).bytes,
    );

    // Step 2: deployer SCAddress.
    final deployerAddress = XdrSCAddress.forAccountId(deployerPublicKey);

    // Step 3: ContractIDPreimage::FromAddress { deployer, salt }.
    final fromAddress = XdrContractIDPreimageFromAddress(
      deployerAddress,
      XdrUint256(salt),
    );
    final contractIdPreimage = XdrContractIDPreimage(
      XdrContractIDPreimageType.CONTRACT_ID_PREIMAGE_FROM_ADDRESS,
    );
    contractIdPreimage.fromAddress = fromAddress;

    // Step 4: HashIDPreimage::ContractID.
    final hashIdPreimageContractId = XdrHashIDPreimageContractID(
      XdrHash(networkIdBytes),
      contractIdPreimage,
    );
    final preimage = XdrHashIDPreimage(
      XdrEnvelopeType.ENVELOPE_TYPE_CONTRACT_ID,
    );
    preimage.contractID = hashIdPreimageContractId;

    // Step 5: XDR-encode the preimage.
    final stream = XdrDataOutputStream();
    XdrHashIDPreimage.encode(stream, preimage);
    final encodedPreimage = Uint8List.fromList(stream.bytes);

    // Step 6: SHA-256 the encoded preimage.
    final contractIdBytes = Uint8List.fromList(
      crypto.sha256.convert(encodedPreimage).bytes,
    );

    // Step 7: encode as C-address.
    return StrKey.encodeContractId(contractIdBytes);
  }

  // ---------------------------------------------------------------------------
  // Private network helpers
  // ---------------------------------------------------------------------------

  /// Returns true when the contract instance entry exists on-chain.
  Future<bool> _contractExistsOnChain(
    SorobanServer server,
    String contractId,
  ) async {
    try {
      final entry = await server.getContractData(
        contractId,
        XdrSCVal.forLedgerKeyContractInstance(),
        XdrContractDataDurability.PERSISTENT,
      );
      return entry != null;
    } catch (_) {
      // Any exception (contract not found, RPC error) means not deployed.
      return false;
    }
  }

  /// Deploys the token contract with a deterministic salt.
  ///
  /// Uses direct host-function construction (no ContractClient or higher-level
  /// transaction abstractions) to hand-roll the upload + deploy sequence.
  /// This gives full control over submission timing and error handling.
  Future<void> _deployTokenContract({
    required SorobanServer server,
    required KeyPair adminKeyPair,
    required Uint8List salt,
    required Uint8List wasmBytes,
    required String expectedContractId,
  }) async {
    final adminId = adminKeyPair.accountId;

    // Step A: Upload the WASM (install host function).
    // The upload operation returns a WASM hash; if the hash already exists on
    // the network, the upload is a no-op (re-upload is idempotent).
    try {
      await _submitInstallAndWait(
        server: server,
        adminKeyPair: adminKeyPair,
        wasmBytes: wasmBytes,
      );
    } catch (e) {
      // If upload fails because the WASM is already installed, that is fine —
      // proceed to deploy. Other errors surface here.
      if (!_isAlreadyExistsError(e)) {
        throw DemoTokenServiceException.rpcError(
          'WASM upload failed: $e',
          cause: e,
        );
      }
    }

    // Step B: Compute the WASM hash (SHA-256 of raw WASM bytes).
    final wasmHashBytes = Uint8List.fromList(
      crypto.sha256.convert(wasmBytes).bytes,
    );
    final wasmHashHex = _bytesToHex(wasmHashBytes);

    // Step C: Deploy the contract using CreateContractV2 with constructor args.
    final deployedAddress = await _submitDeployAndWait(
      server: server,
      adminKeyPair: adminKeyPair,
      wasmHashHex: wasmHashHex,
      salt: salt,
      adminId: adminId,
    );

    // Verify determinism — deployed address must match pre-derived address.
    if (deployedAddress != expectedContractId) {
      throw DemoTokenServiceException.addressMismatch(
        expected: expectedContractId,
        actual: deployedAddress,
      );
    }
  }

  /// Submits a WASM install (upload) operation and waits for inclusion.
  Future<void> _submitInstallAndWait({
    required SorobanServer server,
    required KeyPair adminKeyPair,
    required Uint8List wasmBytes,
  }) async {
    final adminId = adminKeyPair.accountId;
    final account = await server.getAccount(adminId);
    if (account == null) {
      throw DemoTokenServiceException.rpcError(
        'Admin account $adminId not found. It may not be funded yet.',
      );
    }

    // Build the install-WASM host function using the concrete subclass.
    final hostFunction = UploadContractWasmHostFunction(wasmBytes);
    final invokeOp = InvokeHostFuncOpBuilder(hostFunction).build();
    final tx = TransactionBuilder(account).addOperation(invokeOp).build();

    // Simulate to get the transaction footprint and fees.
    final simResponse = await server.simulateTransaction(
      SimulateTransactionRequest(tx),
    );
    if (simResponse.error != null) {
      throw DemoTokenServiceException.rpcError(
        'WASM install simulation failed: ${simResponse.error}',
      );
    }

    // Apply the simulated footprint and fees, then sign and submit.
    final preparedTx = _applySimulation(tx, simResponse);
    preparedTx.sign(adminKeyPair, Network(_networkPassphrase));
    await _submitAndPoll(server, preparedTx);
  }

  /// Submits a deploy-contract operation and returns the deployed C-address.
  Future<String> _submitDeployAndWait({
    required SorobanServer server,
    required KeyPair adminKeyPair,
    required String wasmHashHex,
    required Uint8List salt,
    required String adminId,
  }) async {
    final account = await server.getAccount(adminId);
    if (account == null) {
      throw DemoTokenServiceException.rpcError(
        'Admin account $adminId not found after WASM install.',
      );
    }

    // Build CreateContractV2 host function with constructor args.
    // The token constructor takes: admin (address), decimal (u32),
    // name (string), symbol (string).
    final constructorArgs = <XdrSCVal>[
      XdrSCVal.forAccountAddress(adminId),
      XdrSCVal.forU32(config.demoTokenDecimals),
      XdrSCVal.forString(config.demoTokenName),
      XdrSCVal.forString(config.demoTokenSymbol),
    ];

    // CreateContractWithConstructorHostFunction wraps the CreateContractV2
    // XDR host function. The salt must match the salt used in address
    // derivation so the deployed address is deterministic.
    final hostFunction = CreateContractWithConstructorHostFunction(
      Address.forAccountId(adminId),
      wasmHashHex,
      constructorArgs,
      salt: XdrUint256(salt),
    );

    final invokeOp = InvokeHostFuncOpBuilder(hostFunction).build();
    final tx = TransactionBuilder(account).addOperation(invokeOp).build();

    final simResponse = await server.simulateTransaction(
      SimulateTransactionRequest(tx),
    );
    if (simResponse.error != null) {
      throw DemoTokenServiceException.rpcError(
        'Contract deploy simulation failed: ${simResponse.error}',
      );
    }

    // Apply simulation results (footprint, fees, auth entries).
    final authEntries = simResponse.getSorobanAuth() ?? <SorobanAuthorizationEntry>[];
    // Sign any auth entries that belong to the admin keypair.
    for (final entry in authEntries) {
      if (_entryNeedsSignature(entry, adminId)) {
        entry.sign(adminKeyPair, Network(_networkPassphrase));
      }
    }

    // Build a new operation with the signed auth entries.
    final signedOp = InvokeHostFuncOpBuilder(hostFunction, auth: authEntries)
        .build();
    final preparedTx = _applySimulationToOp(tx, signedOp, simResponse);
    preparedTx.sign(adminKeyPair, Network(_networkPassphrase));
    await _submitAndPoll(server, preparedTx);

    // Return the pre-derived address — Soroban does not return it in the
    // transaction result in a convenient form.
    return _deriveTokenContractAddress(
      deployerPublicKey: adminId,
      salt: salt,
    );
  }

  /// Mints [config.demoTokenMintAmount] DEMO to [recipientContractId].
  Future<void> _mintTokens({
    required SorobanServer server,
    required KeyPair adminKeyPair,
    required String tokenContractId,
    required String recipientContractId,
  }) async {
    final adminId = adminKeyPair.accountId;
    final account = await server.getAccount(adminId);
    if (account == null) {
      throw DemoTokenServiceException.rpcError(
        'Admin account $adminId not found during mint.',
      );
    }

    // mint(to: Address, amount: i128)
    final invokeArgs = <XdrSCVal>[
      XdrSCVal.forContractAddress(recipientContractId),
      XdrSCVal.forI128BigInt(BigInt.from(config.demoTokenMintAmount)),
    ];

    final hostFunction = InvokeContractHostFunction(
      tokenContractId,
      'mint',
      arguments: invokeArgs,
    );

    final invokeOp = InvokeHostFuncOpBuilder(hostFunction).build();
    final tx = TransactionBuilder(account).addOperation(invokeOp).build();

    final simResponse = await server.simulateTransaction(
      SimulateTransactionRequest(tx),
    );
    if (simResponse.error != null) {
      throw DemoTokenServiceException.rpcError(
        'Mint simulation failed: ${simResponse.error}',
      );
    }

    // Apply auth entries from simulation (admin authorization required for mint).
    final authEntries = simResponse.getSorobanAuth() ?? <SorobanAuthorizationEntry>[];
    for (final entry in authEntries) {
      if (_entryNeedsSignature(entry, adminId)) {
        entry.sign(adminKeyPair, Network(_networkPassphrase));
      }
    }

    final signedOp = InvokeHostFuncOpBuilder(hostFunction, auth: authEntries)
        .build();
    final preparedTx = _applySimulationToOp(tx, signedOp, simResponse);
    preparedTx.sign(adminKeyPair, Network(_networkPassphrase));
    await _submitAndPoll(server, preparedTx);
  }

  // ---------------------------------------------------------------------------
  // Transaction helpers
  // ---------------------------------------------------------------------------

  /// Applies simulation results (footprint, resource fee) to [tx].
  ///
  /// Replaces the operation in [tx] with [signedOp] (which carries signed
  /// auth entries), then applies the simulated footprint and fees.
  Transaction _applySimulationToOp(
    Transaction tx,
    InvokeHostFunctionOperation signedOp,
    SimulateTransactionResponse sim,
  ) {
    // Replace the first (and only) operation with the signed version.
    tx.operations[0] = signedOp;

    // Apply the soroban footprint data from simulation.
    if (sim.transactionData != null) {
      tx.sorobanTransactionData = sim.transactionData;
    }

    // Add resource fee on top of the base fee.
    if (sim.minResourceFee != null) {
      tx.addResourceFee(sim.minResourceFee!);
    }

    return tx;
  }

  /// Applies simulation results (footprint, resource fee) to [tx].
  ///
  /// Used for WASM upload where no auth entry signing is needed.
  Transaction _applySimulation(
    Transaction tx,
    SimulateTransactionResponse sim,
  ) {
    if (sim.transactionData != null) {
      tx.sorobanTransactionData = sim.transactionData;
    }
    if (sim.minResourceFee != null) {
      tx.addResourceFee(sim.minResourceFee!);
    }
    return tx;
  }

  /// Returns true when [entry] has address credentials matching [accountId].
  ///
  /// Only entries with [SorobanCredentials.addressCredentials] pointing at
  /// the given G-address need to be signed by that keypair. Contract-type
  /// credentials are handled on-chain by the contract itself.
  bool _entryNeedsSignature(
    SorobanAuthorizationEntry entry,
    String accountId,
  ) {
    final addrCreds = entry.credentials.addressCredentials;
    if (addrCreds == null) return false;
    final address = addrCreds.address;
    if (address.type != Address.TYPE_ACCOUNT) return false;
    return address.accountId == accountId;
  }

  /// Submits [tx] and polls until success, failure, or timeout.
  Future<void> _submitAndPoll(SorobanServer server, Transaction tx) async {
    final sendResponse = await server.sendTransaction(tx);
    if (sendResponse.status == SendTransactionResponse.STATUS_ERROR) {
      throw DemoTokenServiceException.rpcError(
        'Transaction submission failed: ${sendResponse.errorResultXdr}',
      );
    }

    final hash = sendResponse.hash;
    if (hash == null) {
      throw DemoTokenServiceException.rpcError(
        'Transaction submission returned no hash.',
      );
    }

    // Poll for inclusion with up to 30 attempts (approximately 150 seconds).
    for (var i = 0; i < 30; i++) {
      await Future<void>.delayed(const Duration(seconds: 5));
      final txResponse = await server.getTransaction(hash);

      if (txResponse.status == GetTransactionResponse.STATUS_SUCCESS) {
        return;
      }
      if (txResponse.status == GetTransactionResponse.STATUS_FAILED) {
        throw DemoTokenServiceException.rpcError(
          'Transaction $hash failed on-chain: ${txResponse.resultXdr}',
        );
      }
      // STATUS_NOT_FOUND means still pending — keep polling.
    }

    throw DemoTokenServiceException.rpcError(
      'Timed out waiting for transaction $hash to be included.',
    );
  }

  /// Returns true when [error] indicates the WASM is already uploaded.
  bool _isAlreadyExistsError(Object error) {
    final msg = error.toString().toLowerCase();
    return msg.contains('already exists') ||
        msg.contains('duplicate') ||
        msg.contains('exists');
  }

  /// Converts [bytes] to a lowercase hex string.
  static String _bytesToHex(Uint8List bytes) {
    final buffer = StringBuffer();
    for (final b in bytes) {
      buffer.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }
}

// ---------------------------------------------------------------------------
// DemoTokenServiceType + adapter
// ---------------------------------------------------------------------------

/// Test-seam interface over [DemoTokenService] used by the demo flows.
///
/// Allows unit tests to inject a mock without running real network operations.
abstract interface class DemoTokenServiceType {
  /// Ensures the DEMO token contract is deployed and mints tokens to the
  /// recipient.
  Future<DemoTokenResult> ensureTokenAndMint({
    required String recipientContractId,
  });
}

/// Default production implementation backed by [DemoTokenService].
final class DemoTokenServiceAdapter implements DemoTokenServiceType {
  /// Constructs the adapter from a live [DemoTokenService].
  const DemoTokenServiceAdapter(this._service);

  final DemoTokenService _service;

  @override
  Future<DemoTokenResult> ensureTokenAndMint({
    required String recipientContractId,
  }) {
    return _service.ensureTokenAndMint(
      recipientContractId: recipientContractId,
    );
  }
}

// ---------------------------------------------------------------------------
// provisionDemoTokens
// ---------------------------------------------------------------------------

/// Orchestrates the DEMO-token deploy + mint for [recipientContractId].
///
/// Used by both the wallet-creation auto-deploy path and the main-screen
/// Deploy Now path so both report identical activity-log lines, write the
/// same demo-state updates, and chain the same balance refresh on success.
///
/// Returns the DEMO balance string after the post-mint refresh, or null when:
/// - [service] is null (caller chose to skip provisioning), OR
/// - the mint failed at any step — failure is non-fatal: an error entry is
///   appended to [activityLog] (using the [DemoTokenServiceException.message]
///   field when the exception carries one) and the function returns.
///
/// On success the DEMO token contract id is written into [demoState] via
/// [DemoStateNotifier.updateDemoTokenContract] and [onRefreshBalances] is
/// awaited so the DEMO balance label populates immediately.
Future<String?> provisionDemoTokens({
  required DemoTokenServiceType? service,
  required DemoStateNotifier demoState,
  required ActivityLogNotifier activityLog,
  required Future<void> Function() onRefreshBalances,
  required String recipientContractId,
}) async {
  if (service == null) return null;

  activityLog.info('Minting DEMO tokens...');
  try {
    final tokenResult = await service.ensureTokenAndMint(
      recipientContractId: recipientContractId,
    );
    demoState.updateDemoTokenContract(tokenResult.tokenContractId);
    final shortAddr = truncateAddress(recipientContractId);
    final shortToken = truncateAddress(tokenResult.tokenContractId);
    activityLog.success(
      'DEMO tokens minted to $shortAddr. Contract: $shortToken',
    );
    await onRefreshBalances();
    return demoState.currentState.demoTokenBalance;
  } catch (e) {
    final detail = e is DemoTokenServiceException
        ? e.message
        : classifyError(e).message;
    activityLog.error('DEMO mint failed: $detail');
    return null;
  }
}
