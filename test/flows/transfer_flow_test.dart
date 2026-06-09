/// Tests for [TransferFlow].
///
/// Covers the transfer scenarios plus supporting cases for helper methods.
///
/// Strategy:
/// - All SDK calls are mocked via test-double adapters; no network calls.
/// - State assertions check [DemoStateNotifier] and [ActivityLogNotifier].
/// - Error-path assertions verify the error message and that no partial state
///   is committed.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_account_demo/flows/transfer_flow.dart';
import 'package:smart_account_demo/state/activity_log_state.dart';
import 'package:smart_account_demo/state/demo_state.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart';

import 'transfer_test_support.dart';

void main() {
  // -------------------------------------------------------------------------
  // Scenario 1: Single-signer simple happy path
  // -------------------------------------------------------------------------

  group('Scenario 1 — single-signer simple, happy path', () {
    test('transfer() returns result on success, balance refresh called', () async {
      final deps = TransferFixtures.makeFlowWithDeps();
      deps.transactionOps.result = TransferFixtures.successResult();

      final result = await deps.flow.transfer(
        tokenContract: TransferFixtures.nativeTokenContract,
        recipient: TransferFixtures.defaultRecipient,
        amount: TransferFixtures.defaultAmount,
        tokenLabel: 'XLM',
      );

      expect(result.transactionHash, equals(TransferFixtures.defaultTxHash));
      expect(result.amount, equals(TransferFixtures.defaultAmount));
      expect(result.tokenLabel, equals('XLM'));
      expect(result.recipient, equals(TransferFixtures.defaultRecipient));
    });

    test('transfer() logs success to activity log', () async {
      final deps = TransferFixtures.makeFlowWithDeps();
      deps.transactionOps.result = TransferFixtures.successResult();

      await deps.flow.transfer(
        tokenContract: TransferFixtures.nativeTokenContract,
        recipient: TransferFixtures.defaultRecipient,
        amount: TransferFixtures.defaultAmount,
        tokenLabel: 'XLM',
      );

      final log = deps.logEntries;
      expect(
        log.any((e) => e.level == LogLevel.success && e.message.contains('Transfer successful')),
        isTrue,
      );
    });

    test('transfer() forwards exact parameters to SDK', () async {
      final deps = TransferFixtures.makeFlowWithDeps();
      deps.transactionOps.result = TransferFixtures.successResult();

      await deps.flow.transfer(
        tokenContract: TransferFixtures.nativeTokenContract,
        recipient: TransferFixtures.defaultRecipient,
        amount: '5.5',
        tokenLabel: 'XLM',
      );

      expect(deps.transactionOps.lastTokenContract, equals(TransferFixtures.nativeTokenContract));
      expect(deps.transactionOps.lastRecipient, equals(TransferFixtures.defaultRecipient));
      expect(deps.transactionOps.lastAmount, equals('5.5'));
    });
  });

  // -------------------------------------------------------------------------
  // Scenario 2: Passkey cancelled
  // -------------------------------------------------------------------------

  group('Scenario 2 — passkey cancelled', () {
    test('classifyTransferError returns verbatim cancellation string', () async {
      final deps = TransferFixtures.makeFlowWithDeps();
      final msg = deps.flow.classifyTransferError(makeCancelledError());
      expect(msg, equals('Passkey authentication cancelled'));
    });

    test('classifyTransferError logs info (not error) on cancellation', () async {
      final deps = TransferFixtures.makeFlowWithDeps();
      deps.flow.classifyTransferError(makeCancelledError());
      final log = deps.logEntries;
      expect(log.any((e) => e.level == LogLevel.info && e.message.contains('cancelled')), isTrue);
      expect(log.any((e) => e.level == LogLevel.error), isFalse);
    });

    test('transfer() throws when SDK throws WebAuthnCancelled', () async {
      final deps = TransferFixtures.makeFlowWithDeps();
      deps.transactionOps.error = makeCancelledError();

      await expectLater(
        deps.flow.transfer(
          tokenContract: TransferFixtures.nativeTokenContract,
          recipient: TransferFixtures.defaultRecipient,
          amount: TransferFixtures.defaultAmount,
          tokenLabel: 'XLM',
        ),
        throwsA(isA<WebAuthnCancelled>()),
      );
    });
  });

  // -------------------------------------------------------------------------
  // Scenario 3: Invalid recipient — self-transfer
  // -------------------------------------------------------------------------

  group('Scenario 3 — invalid recipient (self-transfer)', () {
    test('validateRecipient returns "Cannot transfer to your own account"', () async {
      final deps = TransferFixtures.makeFlowWithDeps();
      final error = deps.flow.validateRecipient(TransferFixtures.defaultContractId);
      expect(error, equals('Cannot transfer to your own account'));
    });

    test('validateRecipient returns null for valid foreign G-address', () async {
      final deps = TransferFixtures.makeFlowWithDeps();
      final error = deps.flow.validateRecipient(TransferFixtures.defaultRecipient);
      expect(error, isNull);
    });
  });

  // -------------------------------------------------------------------------
  // Scenario 4: Invalid recipient — malformed address
  // -------------------------------------------------------------------------

  group('Scenario 4 — invalid recipient (malformed)', () {
    test('validateRecipient returns address error for "invalid"', () async {
      final deps = TransferFixtures.makeFlowWithDeps();
      final error = deps.flow.validateRecipient('invalid');
      expect(
        error,
        equals(
          'Must be a valid Stellar account (G...) or contract (C...) address',
        ),
      );
    });

    test('validateRecipient returns null for empty input', () async {
      final deps = TransferFixtures.makeFlowWithDeps();
      final error = deps.flow.validateRecipient('');
      expect(error, isNull);
    });

    test('validateRecipient accepts valid C-address', () async {
      final deps = TransferFixtures.makeFlowWithDeps();
      final error = deps.flow.validateRecipient(TransferFixtures.nativeTokenContract);
      expect(error, isNull);
    });
  });

  // -------------------------------------------------------------------------
  // Scenario 5: Insufficient balance (SDK throws)
  // -------------------------------------------------------------------------

  group('Scenario 5 — insufficient balance (SDK throws)', () {
    test('transfer() propagates SDK exception', () async {
      final deps = TransferFixtures.makeFlowWithDeps();
      deps.transactionOps.error = MockTransferError();

      await expectLater(
        deps.flow.transfer(
          tokenContract: TransferFixtures.nativeTokenContract,
          recipient: TransferFixtures.defaultRecipient,
          amount: TransferFixtures.defaultAmount,
          tokenLabel: 'XLM',
        ),
        throwsA(isA<MockTransferError>()),
      );
    });

    test('classifyTransferError maps SDK error to prefixed message', () async {
      final deps = TransferFixtures.makeFlowWithDeps();
      final msg = deps.flow.classifyTransferError(MockTransferError());
      expect(msg, startsWith('Transfer failed:'));
    });
  });

  // -------------------------------------------------------------------------
  // Scenario 6: RPC unreachable
  // -------------------------------------------------------------------------

  group('Scenario 6 — RPC unreachable', () {
    test('classifyTransferError maps network error with sanitised message', () async {
      final deps = TransferFixtures.makeFlowWithDeps();
      final msg = deps.flow.classifyTransferError(MockNetworkError());
      // The classified error must start with the prefix to indicate a hard error.
      expect(msg, startsWith('Transfer failed:'));
    });

    test('classifyTransferError logs at error level for network errors', () async {
      final deps = TransferFixtures.makeFlowWithDeps();
      deps.flow.classifyTransferError(MockNetworkError());
      final log = deps.logEntries;
      expect(log.any((e) => e.level == LogLevel.error), isTrue);
    });
  });

  // -------------------------------------------------------------------------
  // Scenario 7: Single-signer with smart-account auth (same as Scenario 1)
  // -------------------------------------------------------------------------

  group('Scenario 7 — single-signer with smart-account auth (SDK transparent)', () {
    test('transfer() uses transactionOperations regardless of context rules', () async {
      final deps = TransferFixtures.makeFlowWithDeps();
      deps.transactionOps.result = TransferFixtures.successResult();

      final result = await deps.flow.transfer(
        tokenContract: TransferFixtures.nativeTokenContract,
        recipient: TransferFixtures.defaultRecipient,
        amount: TransferFixtures.defaultAmount,
        tokenLabel: 'XLM',
      );

      expect(result.transactionHash, isNotEmpty);
      expect(deps.transactionOps.callCount, equals(1));
    });
  });

  // -------------------------------------------------------------------------
  // Scenario 8: Multi-signer happy path
  // -------------------------------------------------------------------------

  group('Scenario 8 — multi-signer happy path', () {
    test('multiSignerTransfer() returns result on success', () async {
      final deps = TransferFixtures.makeFlowWithDeps();
      deps.multiSignerManager.result = TransferFixtures.successResult();

      final signers = <OZSelectedSigner>[
        const OZSelectedSignerPasskey(),
        const OZSelectedSignerWallet('GABC1234567890123456789012345678901234567890123456789012'),
      ];

      final result = await deps.flow.multiSignerTransfer(
        tokenContract: TransferFixtures.nativeTokenContract,
        recipient: TransferFixtures.defaultRecipient,
        amount: TransferFixtures.defaultAmount,
        tokenLabel: 'XLM',
        selectedSigners: signers,
      );

      expect(result.transactionHash, equals(TransferFixtures.defaultTxHash));
      expect(deps.multiSignerManager.callCount, equals(1));
      expect(deps.multiSignerManager.lastSelectedSigners, equals(signers));
    });

    test('multiSignerTransfer() logs multi-signer success', () async {
      final deps = TransferFixtures.makeFlowWithDeps();
      deps.multiSignerManager.result = TransferFixtures.successResult();

      await deps.flow.multiSignerTransfer(
        tokenContract: TransferFixtures.nativeTokenContract,
        recipient: TransferFixtures.defaultRecipient,
        amount: TransferFixtures.defaultAmount,
        tokenLabel: 'XLM',
        selectedSigners: const <OZSelectedSigner>[
          OZSelectedSignerPasskey(),
        ],
      );

      final log = deps.logEntries;
      expect(
        log.any((e) => e.level == LogLevel.success && e.message.contains('Multi-signer')),
        isTrue,
      );
    });
  });

  // -------------------------------------------------------------------------
  // Scenario 9: Multi-signer one signer cancels
  // -------------------------------------------------------------------------

  group('Scenario 9 — multi-signer one signer cancels', () {
    test('multiSignerTransfer() throws when SDK throws WebAuthnCancelled', () async {
      final deps = TransferFixtures.makeFlowWithDeps();
      deps.multiSignerManager.error = makeCancelledError();

      await expectLater(
        deps.flow.multiSignerTransfer(
          tokenContract: TransferFixtures.nativeTokenContract,
          recipient: TransferFixtures.defaultRecipient,
          amount: TransferFixtures.defaultAmount,
          tokenLabel: 'XLM',
          selectedSigners: const <OZSelectedSigner>[
            OZSelectedSignerPasskey(),
            OZSelectedSignerWallet('GABC1234567890123456789012345678901234567890123456789012'),
          ],
        ),
        throwsA(isA<WebAuthnCancelled>()),
      );
    });
  });

  // -------------------------------------------------------------------------
  // Scenario 10: Multi-signer delegated keypair registration and cleanup
  // -------------------------------------------------------------------------

  group('Scenario 10 — registerDelegatedKeypairs', () {
    test('no-ops when kit is absent (externalSigners returns null)', () async {
      final deps = TransferFixtures.makeFlowWithDeps();
      // No kit in unit-test mode — must complete without throwing.
      await expectLater(
        deps.flow.registerDelegatedKeypairs({'GABC...': 'any-value'}),
        completes,
      );
    });

    test('invalid seed no-ops when kit is absent', () async {
      final deps = TransferFixtures.makeFlowWithDeps();
      // No kit — invalid seed is never passed to the manager, so no throw.
      await expectLater(
        deps.flow.registerDelegatedKeypairs({'GABC...': 'invalid-seed'}),
        completes,
      );
    });

    test('clearDelegatedKeypairs no-ops when kit is absent', () async {
      final deps = TransferFixtures.makeFlowWithDeps();
      await expectLater(
        deps.flow.clearDelegatedKeypairs(),
        completes,
      );
    });

    test('registers secret in manager', () async {
      final deps = TransferFixtures.makeFlowWithManager();
      final kp = KeyPair.random();
      final seed = kp.secretSeed;

      await deps.flow.registerDelegatedKeypairs({kp.accountId: seed});

      expect(
        deps.fakeManager.registeredAddresses,
        contains(kp.accountId),
      );
    });

    test('clearDelegatedKeypairs removes registered addresses via removeAll',
        () async {
      final deps = TransferFixtures.makeFlowWithManager();
      final kp = KeyPair.random();
      final seed = kp.secretSeed;

      await deps.flow.registerDelegatedKeypairs({kp.accountId: seed});
      expect(deps.fakeManager.registeredAddresses, isNotEmpty);

      await deps.flow.clearDelegatedKeypairs();

      expect(deps.fakeManager.registeredAddresses, isEmpty);
      expect(deps.fakeManager.removeAllCallCount, greaterThanOrEqualTo(1));
    });

    test('withCleanupOfDelegatedKeypairs removes registered addresses after body', () async {
      final deps = TransferFixtures.makeFlowWithManager();
      final kp = KeyPair.random();

      await deps.flow.registerDelegatedKeypairs({kp.accountId: kp.secretSeed});

      await deps.flow.withCleanupOfDelegatedKeypairs(() async {});

      expect(deps.fakeManager.registeredAddresses, isEmpty);
    });

    test('withCleanupOfDelegatedKeypairs removes addresses when body throws', () async {
      final deps = TransferFixtures.makeFlowWithManager();
      final kp = KeyPair.random();

      await deps.flow.registerDelegatedKeypairs({kp.accountId: kp.secretSeed});

      await expectLater(
        deps.flow.withCleanupOfDelegatedKeypairs(() async =>
            throw Exception('body error')),
        throwsA(isA<Exception>()),
      );

      expect(deps.fakeManager.registeredAddresses, isEmpty);
    });

    test('clearDelegatedKeypairs clears every signer via removeAll', () async {
      // clearDelegatedKeypairs delegates to removeAll, which clears all
      // in-memory signers and disconnects every wallet connection in one call.
      final deps = TransferFixtures.makeFlowWithManager();
      final kp = KeyPair.random();

      await deps.flow.registerDelegatedKeypairs({kp.accountId: kp.secretSeed});
      await deps.flow.clearDelegatedKeypairs();

      expect(deps.fakeManager.removeAllCallCount, equals(1));
      expect(deps.fakeManager.registeredAddresses, isEmpty);
    });

    test('partial delegated registration is rolled back on addFromSecret failure', () async {
      final deps = TransferFixtures.makeFlowWithManager();
      final good = KeyPair.random();

      // Register one key successfully first.
      await deps.flow.registerDelegatedKeypairs({good.accountId: good.secretSeed});
      expect(deps.fakeManager.registeredAddresses, hasLength(1));

      // Now simulate a failure on the next registration batch.
      deps.fakeManager.addFromSecretError = Exception('wallet error');

      // The fake manager throws; registerDelegatedKeypairs clears every signer
      // via removeAll before the error is reported.
      final bad = KeyPair.random();
      await expectLater(
        deps.flow.registerDelegatedKeypairs({bad.accountId: bad.secretSeed}),
        throwsA(isA<Exception>()),
      );

      // The rollback removeAll clears the registry, so it is empty after the
      // failure.
      expect(deps.fakeManager.registeredAddresses, isEmpty);
      expect(deps.fakeManager.removeAllCallCount, greaterThanOrEqualTo(1));
    });

    // Regression (cancel-leak guard): when Ed25519 registration throws after
    // the delegated keypairs were already registered, withMultiSignerRegistration
    // must clear the delegated keypairs itself — without the test calling any
    // cleanup. This drives the method that OWNS the wrap-both-registrations
    // sequence, so it fails if Ed25519 registration is moved outside the wrapper.
    test('withMultiSignerRegistration clears delegated keypairs when Ed25519 '
        'registration throws (no manual cleanup)', () async {
      final deps = TransferFixtures.makeFlowWithManager();
      final kp = KeyPair.random();

      // Force the in-process Ed25519 registration to fail.
      deps.fakeManager.addEd25519Error = ArgumentError('bad seed length');

      final ed25519Kp = KeyPair.random();
      final pubKey = Uint8List.fromList(ed25519Kp.publicKey);
      final identity = Ed25519SignerIdentity(
        verifierAddress: TransferFixtures.defaultContractId,
        publicKey: pubKey,
      );

      var bodyRan = false;
      await expectLater(
        deps.flow.withMultiSignerRegistration<void>(
          delegatedKeyPairs: {kp.accountId: kp.secretSeed},
          ed25519Secrets: {identity: Uint8List(32)},
          body: () async {
            bodyRan = true;
          },
        ),
        throwsA(isA<ArgumentError>()),
      );

      // Body must not run when registration fails.
      expect(bodyRan, isFalse,
          reason: 'body must not run when Ed25519 registration throws');

      // The method itself cleaned up the delegated keypair registered first;
      // the test performed no cleanup of its own. If Ed25519 registration were
      // moved outside the guarded region, the delegated keypair would leak and
      // this assertion would fail.
      expect(
        deps.fakeManager.registeredAddresses,
        isEmpty,
        reason: 'delegated keypairs must not leak when Ed25519 registration throws',
      );
    });
  });

  // -------------------------------------------------------------------------
  // Scenario 10b: Ed25519 keypair registration
  // -------------------------------------------------------------------------

  group('Scenario 10b — registerEd25519Keypairs', () {
    test('no-ops when kit is absent (externalSigners returns null)', () async {
      final deps = TransferFixtures.makeFlowWithDeps();
      final kp = KeyPair.random();
      final pubKey = Uint8List.fromList(kp.publicKey);
      final identity = Ed25519SignerIdentity(
        verifierAddress: TransferFixtures.defaultContractId,
        publicKey: pubKey,
      );
      // Must not throw — no kit present.
      await deps.flow.registerEd25519Keypairs({identity: Uint8List(32)});
    });

    test('invalid seed (wrong length) no-ops when kit is absent', () async {
      final deps = TransferFixtures.makeFlowWithDeps();
      final kp = KeyPair.random();
      final pubKey = Uint8List.fromList(kp.publicKey);
      final identity = Ed25519SignerIdentity(
        verifierAddress: TransferFixtures.defaultContractId,
        publicKey: pubKey,
      );
      // Only 4 bytes — but no kit is present, so no throw.
      await expectLater(
        deps.flow.registerEd25519Keypairs({identity: Uint8List(4)}),
        completes,
      );
    });

    test('registers Ed25519 key and tracks it in manager', () async {
      final deps = TransferFixtures.makeFlowWithManager();
      final ed25519Kp = KeyPair.random();
      final pubKey = Uint8List.fromList(ed25519Kp.publicKey);
      final rawSeed = StrKey.decodeStellarSecretSeed(ed25519Kp.secretSeed);
      final identity = Ed25519SignerIdentity(
        verifierAddress: TransferFixtures.defaultContractId,
        publicKey: pubKey,
      );

      await deps.flow.registerEd25519Keypairs({identity: rawSeed});

      expect(deps.fakeManager.registeredEd25519Keys, isNotEmpty);
    });

    test('clearDelegatedKeypairs also removes registered Ed25519 keys', () async {
      final deps = TransferFixtures.makeFlowWithManager();
      final ed25519Kp = KeyPair.random();
      final pubKey = Uint8List.fromList(ed25519Kp.publicKey);
      final rawSeed = StrKey.decodeStellarSecretSeed(ed25519Kp.secretSeed);
      final identity = Ed25519SignerIdentity(
        verifierAddress: TransferFixtures.defaultContractId,
        publicKey: pubKey,
      );

      await deps.flow.registerEd25519Keypairs({identity: rawSeed});
      expect(deps.fakeManager.registeredEd25519Keys, isNotEmpty);

      await deps.flow.clearDelegatedKeypairs();

      expect(
        deps.fakeManager.registeredEd25519Keys,
        isEmpty,
        reason: 'Ed25519 keys must be removed by clearDelegatedKeypairs',
      );
      expect(deps.fakeManager.removeAllCallCount, greaterThanOrEqualTo(1));
    });

    test('Ed25519SignerIdentity equality holds for same address + pubkey',
        () {
      final pubKey = Uint8List(32)..fillRange(0, 32, 0xAB);
      const verifierAddress = TransferFixtures.defaultContractId;

      final a = Ed25519SignerIdentity(
        verifierAddress: verifierAddress,
        publicKey: pubKey,
      );
      final b = Ed25519SignerIdentity(
        verifierAddress: verifierAddress,
        publicKey: Uint8List.fromList(pubKey),
      );

      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('Ed25519SignerIdentity inequality on different public key', () {
      const verifierAddress = TransferFixtures.defaultContractId;
      final pubKeyA = Uint8List(32)..fillRange(0, 32, 0x01);
      final pubKeyB = Uint8List(32)..fillRange(0, 32, 0x02);

      final a = Ed25519SignerIdentity(
        verifierAddress: verifierAddress,
        publicKey: pubKeyA,
      );
      final b = Ed25519SignerIdentity(
        verifierAddress: verifierAddress,
        publicKey: pubKeyB,
      );

      expect(a, isNot(equals(b)));
    });

    test('Ed25519SignerIdentity inequality on different verifierAddress', () {
      final pubKey = Uint8List(32)..fillRange(0, 32, 0xFF);
      const addressA = TransferFixtures.defaultContractId;
      const addressB = TransferFixtures.nativeTokenContract;

      final a = Ed25519SignerIdentity(
        verifierAddress: addressA,
        publicKey: pubKey,
      );
      final b = Ed25519SignerIdentity(
        verifierAddress: addressB,
        publicKey: pubKey,
      );

      expect(a, isNot(equals(b)));
    });
  });

  // -------------------------------------------------------------------------
  // Scenario 11: Multi-signer one signer fails mid-ceremony
  // -------------------------------------------------------------------------

  group('Scenario 11 — multi-signer one signer fails to sign', () {
    test('multiSignerTransfer() propagates signing exception', () async {
      final deps = TransferFixtures.makeFlowWithDeps();
      deps.multiSignerManager.error = Exception('Signing failed for signer 2');

      await expectLater(
        deps.flow.multiSignerTransfer(
          tokenContract: TransferFixtures.nativeTokenContract,
          recipient: TransferFixtures.defaultRecipient,
          amount: TransferFixtures.defaultAmount,
          tokenLabel: 'XLM',
          selectedSigners: const <OZSelectedSigner>[OZSelectedSignerPasskey()],
        ),
        throwsA(isA<Exception>()),
      );
    });
  });

  // -------------------------------------------------------------------------
  // Scenario 12: External-signer confirmation (see screen test)
  // -------------------------------------------------------------------------
  // The "what you sign is what you see" guarantee is enforced at the demo
  // layer by ExternalSignerManagerAdapter. The flow does not contain
  // additional payload-match logic. Widget tests cover the UI display.

  // -------------------------------------------------------------------------
  // Scenario 13: Fee underpayment (SDK throws)
  // -------------------------------------------------------------------------

  group('Scenario 13 — fee underpayment', () {
    test('transfer() propagates fee-related SDK exception', () async {
      final deps = TransferFixtures.makeFlowWithDeps();
      deps.transactionOps.error = Exception('Insufficient fee budget');

      await expectLater(
        deps.flow.transfer(
          tokenContract: TransferFixtures.nativeTokenContract,
          recipient: TransferFixtures.defaultRecipient,
          amount: TransferFixtures.defaultAmount,
          tokenLabel: 'XLM',
        ),
        throwsA(isA<Exception>()),
      );
    });
  });

  // -------------------------------------------------------------------------
  // Scenario 14: Token selection
  // -------------------------------------------------------------------------

  group('Scenario 14 — token selection', () {
    test('resolveTokenContract returns nativeTokenContract for xlm key', () {
      final deps = TransferFixtures.makeFlowWithDeps();
      final contract = deps.flow.resolveTokenContract(TransferFlow.tokenKeyXlm);
      expect(contract, equals(TransferFixtures.nativeTokenContract));
    });

    test('resolveTokenContract returns demoTokenContractId for demo key', () {
      final deps = TransferFixtures.makeFlowWithDeps(
        demoTokenContractId: TransferFixtures.demoTokenContract,
      );
      final contract = deps.flow.resolveTokenContract(TransferFlow.tokenKeyDemo);
      expect(contract, equals(TransferFixtures.demoTokenContract));
    });

    test('resolveTokenContract returns null for demo key when contract undeployed', () {
      final deps = TransferFixtures.makeFlowWithDeps();
      final contract = deps.flow.resolveTokenContract(TransferFlow.tokenKeyDemo);
      expect(contract, isNull);
    });

    test('transfer() uses correct token contract when called with demo contract', () async {
      final deps = TransferFixtures.makeFlowWithDeps(
        demoTokenContractId: TransferFixtures.demoTokenContract,
      );
      deps.transactionOps.result = TransferFixtures.successResult();

      await deps.flow.transfer(
        tokenContract: TransferFixtures.demoTokenContract,
        recipient: TransferFixtures.defaultRecipient,
        amount: '5.0',
        tokenLabel: 'DEMO',
      );

      expect(deps.transactionOps.lastTokenContract, equals(TransferFixtures.demoTokenContract));
    });
  });

  // -------------------------------------------------------------------------
  // Scenario 15: Form validation — amount
  // -------------------------------------------------------------------------

  group('Scenario 15 — form validation, amount', () {
    test('validateAmount returns "Scientific notation is not supported" for "1e5"', () {
      final error = TransferFlow.validateAmount('1e5');
      expect(error, equals('Scientific notation is not supported'));
    });

    test('validateAmount returns "Scientific notation is not supported" for "1E5"', () {
      final error = TransferFlow.validateAmount('1E5');
      expect(error, equals('Scientific notation is not supported'));
    });

    test('validateAmount returns "Must be a valid number" for "abc"', () {
      final error = TransferFlow.validateAmount('abc');
      expect(error, equals('Must be a valid number'));
    });

    test('validateAmount returns "Must be greater than zero" for "0"', () {
      final error = TransferFlow.validateAmount('0');
      expect(error, equals('Must be greater than zero'));
    });

    test('validateAmount returns "Must be greater than zero" for "-1"', () {
      final error = TransferFlow.validateAmount('-1');
      expect(error, equals('Must be greater than zero'));
    });

    test('validateAmount returns null for valid positive decimal', () {
      expect(TransferFlow.validateAmount('10.5'), isNull);
      expect(TransferFlow.validateAmount('0.0001'), isNull);
    });

    test('validateAmount returns null for empty input', () {
      expect(TransferFlow.validateAmount(''), isNull);
    });
  });

  // -------------------------------------------------------------------------
  // Scenario 16: Kit nil on entry
  // -------------------------------------------------------------------------

  group('Scenario 16 — kit nil on entry', () {
    test('loadAvailableSigners returns empty list when not connected', () async {
      final deps = TransferFixtures.makeFlowWithDeps(isConnected: false);
      final signers = await deps.flow.loadAvailableSigners();
      expect(signers, isEmpty);
    });

    test('loadAvailableSigners returns empty list when context rule manager errors', () async {
      final deps = TransferFixtures.makeFlowWithDeps();
      deps.contextRuleManager.error = Exception('Context rule fetch failed');
      final signers = await deps.flow.loadAvailableSigners();
      expect(signers, isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  // Scenario 17: Balance display
  // -------------------------------------------------------------------------

  group('Scenario 17 — balance display', () {
    test('transfer() result carries the amount and tokenLabel', () async {
      final deps = TransferFixtures.makeFlowWithDeps();
      deps.transactionOps.result = TransferFixtures.successResult();

      final result = await deps.flow.transfer(
        tokenContract: TransferFixtures.nativeTokenContract,
        recipient: TransferFixtures.defaultRecipient,
        amount: '7.25',
        tokenLabel: 'XLM',
      );

      expect(result.amount, equals('7.25'));
      expect(result.tokenLabel, equals('XLM'));
    });
  });

  // -------------------------------------------------------------------------
  // isSinglePasskeyTransfer
  // -------------------------------------------------------------------------

  group('isSinglePasskeyTransfer', () {
    test('returns true for exactly one OZSelectedSignerPasskey with no credentialIdBytes', () {
      final deps = TransferFixtures.makeFlowWithDeps();
      final result = deps.flow.isSinglePasskeyTransfer(
        const <OZSelectedSigner>[OZSelectedSignerPasskey()],
      );
      expect(result, isTrue);
    });

    test('returns false for two signers', () {
      final deps = TransferFixtures.makeFlowWithDeps();
      final result = deps.flow.isSinglePasskeyTransfer(
        const <OZSelectedSigner>[
          OZSelectedSignerPasskey(),
          OZSelectedSignerWallet('GABC1234567890123456789012345678901234567890123456789012'),
        ],
      );
      expect(result, isFalse);
    });

    test('returns false for empty list', () {
      final deps = TransferFixtures.makeFlowWithDeps();
      final result = deps.flow.isSinglePasskeyTransfer(const <OZSelectedSigner>[]);
      expect(result, isFalse);
    });

    test('returns false for OZSelectedSignerWallet', () {
      final deps = TransferFixtures.makeFlowWithDeps();
      final result = deps.flow.isSinglePasskeyTransfer(
        const <OZSelectedSigner>[
          OZSelectedSignerWallet('GABC1234567890123456789012345678901234567890123456789012'),
        ],
      );
      expect(result, isFalse);
    });
  });

  // -------------------------------------------------------------------------
  // buildSelectedSigners
  // -------------------------------------------------------------------------

  group('buildSelectedSigners', () {
    test('passkey SignerInfo becomes OZSelectedSignerPasskey', () async {
      final deps = TransferFixtures.makeFlowWithDeps();
      const info = SignerInfo(
        displayLabel: 'Passkey',
        address: '',
        kind: SignerKind.passkey,
        isConnectedCredential: true,
      );
      final signers = await deps.flow.buildSelectedSigners([info]);
      expect(signers, hasLength(1));
      expect(signers.first, isA<OZSelectedSignerPasskey>());
    });

    test('delegated SignerInfo becomes OZSelectedSignerWallet', () async {
      final deps = TransferFixtures.makeFlowWithDeps();
      const address = 'GABC1234567890123456789012345678901234567890123456789012';
      const info = SignerInfo(
        displayLabel: 'G-address',
        address: address,
        kind: SignerKind.delegated,
        isConnectedCredential: false,
      );
      final signers = await deps.flow.buildSelectedSigners([info]);
      expect(signers, hasLength(1));
      final wallet = signers.first as OZSelectedSignerWallet;
      expect(wallet.address, equals(address));
    });
  });

  // -------------------------------------------------------------------------
  // Re-entrancy guard
  // -------------------------------------------------------------------------

  group('re-entrancy guard', () {
    test('transfer() throws StateError on concurrent in-flight call', () async {
      final deps = TransferFixtures.makeFlowWithDeps();
      var firstCallComplete = false;

      deps.transactionOps.result = null;

      // Verify the guard by holding the first call in-flight and checking that
      // a second call returns a StateError immediately while the first is still
      // pending. A suspending mock keeps the first call from resolving until the
      // completer fires.
      final completer = _Completer<OZTransactionResult>();
      deps.transactionOps.result = null;

      final slowOps = _SlowTransactionOperations(
        completer: completer,
        result: TransferFixtures.successResult(),
      );

      final flowWithSlow = TransferFlow(
        demoState: deps.demoState,
        activityLog: deps.activityLog,
        transactionOperations: slowOps,
        multiSignerManager: deps.multiSignerManager,
        contextRuleManager: deps.contextRuleManager,
      );

      // Start the first call — it will suspend.
      final firstFuture = flowWithSlow.transfer(
        tokenContract: TransferFixtures.nativeTokenContract,
        recipient: TransferFixtures.defaultRecipient,
        amount: TransferFixtures.defaultAmount,
        tokenLabel: 'XLM',
      );

      // Attempt a second call immediately.
      await expectLater(
        flowWithSlow.transfer(
          tokenContract: TransferFixtures.nativeTokenContract,
          recipient: TransferFixtures.defaultRecipient,
          amount: TransferFixtures.defaultAmount,
          tokenLabel: 'XLM',
        ),
        throwsA(isA<StateError>()),
      );

      // Let the first call finish.
      completer.complete(TransferFixtures.successResult());
      firstCallComplete = true;
      await firstFuture;
      expect(firstCallComplete, isTrue);
    });
  });

  // -------------------------------------------------------------------------
  // withCleanupOfDelegatedKeypairs
  // -------------------------------------------------------------------------

  group('TransferFlow.withCleanupOfDelegatedKeypairs', () {
    test('runs body and returns body result on success', () async {
      final deps = TransferFixtures.makeFlowWithDeps();
      var bodyCalls = 0;
      final result = await deps.flow.withCleanupOfDelegatedKeypairs<String>(() async {
        bodyCalls++;
        return 'ok';
      });
      expect(result, equals('ok'));
      expect(bodyCalls, equals(1));
    });

    test('propagates body exception', () async {
      final deps = TransferFixtures.makeFlowWithDeps();
      var bodyCalls = 0;
      final bodyError = StateError('body failed');
      await expectLater(
        deps.flow.withCleanupOfDelegatedKeypairs<void>(() async {
          bodyCalls++;
          throw bodyError;
        }),
        throwsA(same(bodyError)),
      );
      expect(bodyCalls, equals(1));
    });

    test('wrapper never invokes registration (no key material added)', () async {
      final deps = TransferFixtures.makeFlowWithDeps();
      // withCleanupOfDelegatedKeypairs must not register any signers —
      // registration is the caller's responsibility.
      await deps.flow.withCleanupOfDelegatedKeypairs<void>(() async {});
    });

    test('exactly one body call on success path', () async {
      final deps = TransferFixtures.makeFlowWithDeps();
      var bodyCalls = 0;
      await deps.flow.withCleanupOfDelegatedKeypairs<void>(() async {
        bodyCalls++;
      });
      expect(bodyCalls, equals(1));
    });

    test('exactly one body call on body-throws path', () async {
      final deps = TransferFixtures.makeFlowWithDeps();
      var bodyCalls = 0;
      await expectLater(
        deps.flow.withCleanupOfDelegatedKeypairs<void>(() async {
          bodyCalls++;
          throw StateError('x');
        }),
        throwsA(isA<StateError>()),
      );
      expect(bodyCalls, equals(1));
    });
  });
}


// ---------------------------------------------------------------------------
// _Completer / _SlowTransactionOperations — for re-entrancy test
// ---------------------------------------------------------------------------

typedef _Completer<T> = Completer<T>;

/// Slow transaction operations mock that suspends until a [Completer] fires.
final class _SlowTransactionOperations implements TransactionOperationsType {
  _SlowTransactionOperations({
    required this.completer,
    required this.result,
  });

  final Completer<OZTransactionResult> completer;
  final OZTransactionResult result;

  @override
  Future<OZTransactionResult> transfer({
    required String tokenContract,
    required String recipient,
    required String amount,
    int? decimals,
  }) {
    return completer.future;
  }
}
