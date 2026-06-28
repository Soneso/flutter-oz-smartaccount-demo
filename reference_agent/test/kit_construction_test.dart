// Copyright 2026 Soneso. Reference agent for the OZ smart-account demo.
//
// Proves the agent compiles and builds against the Stellar Flutter SDK in the
// chosen run mechanism: an OZSmartAccountKit is constructed headlessly under
// `flutter test`, with in-memory storage, no WebAuthn provider, and the
// agent's Ed25519 adapter — exactly as the production agent wires it. No
// network is touched (construction makes no RPC calls).

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reference_agent/reference_agent.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

void main() {
  test('kit constructs headlessly with in-memory storage and Ed25519 adapter',
      () {
    final adapter = AgentEd25519SignerAdapter();
    final config = OZSmartAccountConfig(
      rpcUrl: AgentDefaults.rpcUrl,
      networkPassphrase: AgentDefaults.networkPassphrase,
      accountWasmHash: AgentDefaults.accountWasmHash,
      webauthnVerifierAddress: AgentDefaults.webauthnVerifierAddress,
      relayerUrl: AgentDefaults.relayerUrl,
      storage: OZInMemoryStorageAdapter(),
      externalEd25519Adapter: adapter,
    );

    final kit = OZSmartAccountKit.create(config: config);
    addTearDown(() async => kit.close());

    // The kit is constructed but not connected (no passkey, no session).
    expect(kit.isConnected, isFalse);
    expect(kit.contractId, isNull);
    // The unified external-signer manager is available immediately.
    expect(kit.externalSigners, isNotNull);
    // The adapter is wired in and registers/clears the agent keypair.
    final keypair = KeyPair.random();
    adapter.add(AgentDefaults.ed25519VerifierAddress, keypair);
    expect(
      adapter.canSignFor(AgentDefaults.ed25519VerifierAddress,
          Uint8List.fromList(keypair.publicKey)),
      isTrue,
    );
    adapter.clearAll();
    expect(
      adapter.canSignFor(AgentDefaults.ed25519VerifierAddress,
          Uint8List.fromList(keypair.publicKey)),
      isFalse,
    );
  });

  test('agent Ed25519 adapter signs the auth digest with the registered key',
      () async {
    final adapter = AgentEd25519SignerAdapter();
    final keypair = KeyPair.random();
    adapter.add(AgentDefaults.ed25519VerifierAddress, keypair);

    final digest = Uint8List.fromList(List<int>.generate(32, (i) => i));
    final signature = await adapter.signAuthDigest(
      digest,
      Uint8List.fromList(keypair.publicKey),
    );

    expect(signature, hasLength(64));
    // The signature verifies against the registered public key.
    expect(keypair.verify(digest, signature), isTrue);
  });

  test('adapter rejects a public-only keypair', () {
    final adapter = AgentEd25519SignerAdapter();
    final publicOnly = KeyPair.fromAccountId(KeyPair.random().accountId);
    expect(
      () => adapter.add(AgentDefaults.ed25519VerifierAddress, publicOnly),
      throwsA(isA<ArgumentError>()),
    );
  });
}
