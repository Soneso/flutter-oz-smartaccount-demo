// Copyright 2026 Soneso. Reference agent for the OZ smart-account demo.

import 'package:http/http.dart' as http;
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import 'agent_config.dart';
import 'agent_ed25519_signer_adapter.dart';
import 'agent_runner.dart';
import 'coordination_client.dart';

/// Production [WalletSession] that connects an [OZSmartAccountKit] headlessly.
///
/// Uses the contract-address-only [OZWalletOperations.connectToContract] path:
/// no passkey credential, no WebAuthn ceremony, no session restore. The agent
/// operates the account through the multi-signer / external-signer pipeline.
class KitWalletSession implements WalletSession {
  /// Constructs a session for [kit] connecting headlessly to [contractId].
  KitWalletSession({
    required OZSmartAccountKit kit,
    required String contractId,
  })  : _kit = kit,
        _contractId = contractId;

  final OZSmartAccountKit _kit;
  final String _contractId;

  @override
  Future<String> connect() async {
    final result =
        await _kit.walletOperations.connectToContract(_contractId);
    return result.contractId;
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

    final agentKeypair =
        KeyPair.fromSecretSeedList(Util.hexToBytes(config.agentSecretSeed!));
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
