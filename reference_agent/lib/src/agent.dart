// Copyright 2026 Soneso. Reference agent for the OZ smart-account demo.

import 'package:http/http.dart' as http;
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import 'agent_config.dart';
import 'agent_ed25519_signer_adapter.dart';
import 'agent_runner.dart';
import 'coordination_client.dart';

/// Production [WalletSession] that connects an [OZSmartAccountKit] headlessly.
///
/// Uses the explicit `(credentialId, contractId)` connect path, which bypasses
/// session restore and the WebAuthn cascade — no passkey ceremony is needed.
class KitWalletSession implements WalletSession {
  /// Constructs a session for [kit] connecting to [contractId] via
  /// [credentialId].
  KitWalletSession({
    required OZSmartAccountKit kit,
    required String credentialId,
    required String contractId,
  })  : _kit = kit,
        _credentialId = credentialId,
        _contractId = contractId;

  final OZSmartAccountKit _kit;
  final String _credentialId;
  final String _contractId;

  @override
  Future<String> connect() async {
    final result = await _kit.walletOperations.connectWallet(
      options: OZConnectWalletOptions(
        credentialId: _credentialId,
        contractId: _contractId,
      ),
    );
    switch (result) {
      case OZConnectWalletConnected(:final contractId):
        return contractId;
      case OZConnectWalletAmbiguous():
        throw StateError(
          'connectWallet returned multiple candidates for an explicit '
          'contractId; this should not happen.',
        );
      case null:
        throw StateError(
          'connectWallet returned null for an explicit credential/contract '
          'pair; the contract may not exist on-chain.',
        );
    }
  }
}

/// Production [MultiSignerContractCallType] backed by [OZMultiSignerManager].
class MultiSignerContractCallAdapter implements MultiSignerContractCallType {
  /// Constructs the adapter from a live [OZMultiSignerManager].
  const MultiSignerContractCallAdapter(this._manager);

  final OZMultiSignerManager _manager;

  @override
  Future<OZTransactionResult> multiSignerContractCall({
    required String target,
    required String targetFn,
    required List<XdrSCVal> targetArgs,
    required List<OZSelectedSigner> selectedSigners,
  }) {
    return _manager.multiSignerContractCall(
      target: target,
      targetFn: targetFn,
      targetArgs: targetArgs,
      selectedSigners: selectedSigners,
    );
  }
}

/// Production assembly of the reference agent.
///
/// Wires an [OZSmartAccountKit] (in-memory storage, no WebAuthn provider, the
/// agent's [AgentEd25519SignerAdapter] supplied as the Ed25519 adapter), an
/// [HttpCoordinationClient], and an [AgentRunner]. Owns the kit and HTTP
/// resources; call [dispose] when finished.
class Agent {
  Agent._({
    required this.runner,
    required OZSmartAccountKit kit,
    required CoordinationClient coordination,
  })  : _kit = kit,
        _coordination = coordination;

  /// The configured runner.
  final AgentRunner runner;

  final OZSmartAccountKit _kit;
  final CoordinationClient _coordination;

  /// Builds a fully wired agent from [config].
  ///
  /// Throws [AgentConfigException] when [config] is missing a value required
  /// for a live run. Supply [httpClient] to inject a coordination HTTP client
  /// (otherwise one is created and closed by [dispose]).
  factory Agent.fromConfig(
    AgentConfig config, {
    AgentLogger logger = const StdoutAgentLogger(),
    http.Client? httpClient,
  }) {
    config.validateForLiveRun();

    final agentKeypair = KeyPair.fromSecretSeed(config.agentSecretSeed!);
    final signerAdapter = AgentEd25519SignerAdapter();

    final ozConfig = OZSmartAccountConfig(
      rpcUrl: config.rpcUrl,
      networkPassphrase: config.networkPassphrase,
      accountWasmHash: config.accountWasmHash,
      webauthnVerifierAddress: config.webauthnVerifierAddress,
      relayerUrl: config.relayerUrl.isEmpty ? null : config.relayerUrl,
      storage: OZInMemoryStorageAdapter(),
      externalEd25519Adapter: signerAdapter,
    );
    final kit = OZSmartAccountKit.create(config: ozConfig);

    final coordination = HttpCoordinationClient(
      baseUrl: config.coordinationBaseUrl,
      token: config.coordinationToken,
      httpClient: httpClient,
    );

    final runner = AgentRunner(
      config: config,
      session: KitWalletSession(
        kit: kit,
        credentialId: config.credentialId!,
        contractId: config.smartAccountContractId!,
      ),
      contractCall: MultiSignerContractCallAdapter(kit.multiSignerManager),
      coordination: coordination,
      signerAdapter: signerAdapter,
      agentKeypair: agentKeypair,
      logger: logger,
    );

    return Agent._(runner: runner, kit: kit, coordination: coordination);
  }

  /// Runs one agent cycle.
  Future<AgentResult> run() => runner.run();

  /// Releases the coordination HTTP client and the kit's held resources.
  Future<void> dispose() async {
    await _coordination.close();
    await _kit.close();
  }
}
