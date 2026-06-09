/// Widget tests for [SignerManagementSection].
///
/// Covers: header strings, empty-state, add-delegated happy path, validation
/// errors, Ed25519 verifier helper text, passkey card visibility, Reuse
/// Signer empty state, and remove flow.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_account_demo/flows/context_rule_builder_types.dart';
import 'package:smart_account_demo/flows/context_rule_edit_types.dart';
import 'package:smart_account_demo/widgets/signer_management_section.dart';
import 'package:stellar_flutter_sdk/stellar_flutter_sdk.dart'
    show OZSmartAccountBuilders;

import '../flows/context_rule_test_support.dart';

/// Build a widget host that gives the section a useful canvas size.
Future<void> _pump(
  WidgetTester tester, {
  required List<StagedSigner> signers,
  String? fieldError,
  bool isSubmitting = false,
  int maxSigners = 15,
  String? ed25519VerifierAddress =
      'CAW2Z46INPO5VIJEILMYSSEOLBVJIIII5GOE3TN5EUURSRM2FJCF7AJ6',
  OZSmartAccountSigner Function(String)? buildDelegatedSigner,
  OZSmartAccountSigner Function(Uint8List)? buildEd25519Signer,
  String? Function(StagedSigner)? onAddSigner,
  void Function(StagedSigner)? onRemoveSigner,
  Future<List<OZExternalSigner>> Function()? loadPasskeySigners,
  Future<OZSmartAccountSigner> Function(String)? registerPasskeySigner,
}) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: SignerManagementSection(
              signers: signers,
              fieldError: fieldError,
              isSubmitting: isSubmitting,
              maxSigners: maxSigners,
              ed25519VerifierAddress: ed25519VerifierAddress,
              buildDelegatedSigner:
                  buildDelegatedSigner ?? OZDelegatedSigner.new,
              buildEd25519Signer: buildEd25519Signer ??
                  (publicKey) => OZExternalSigner.ed25519(
                        verifierAddress: ed25519VerifierAddress ??
                            'CAW2Z46INPO5VIJEILMYSSEOLBVJIIII5GOE3TN5EUURSRM2FJCF7AJ6',
                        publicKey: publicKey,
                      ),
              onAddSigner: onAddSigner ?? (_) => null,
              onRemoveSigner: onRemoveSigner ?? (_) {},
              loadPasskeySigners:
                  loadPasskeySigners ?? () async => const <OZExternalSigner>[],
              registerPasskeySigner: registerPasskeySigner ??
                  (name) async => throw UnimplementedError(),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  // ---------------------------------------------------------------------------
  // Header / Empty state
  // ---------------------------------------------------------------------------

  group('SignerManagementSection — header and empty state', () {
    testWidgets('shows verbatim header strings', (tester) async {
      await _pump(tester, signers: const <StagedSigner>[]);
      expect(find.text('Signers'), findsOneWidget);
      expect(
        find.text(
          'Add signers who can authorize operations matching this context. '
          'At least one signer is required. Maximum 15.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('shows empty-state body when signers is empty', (tester) async {
      await _pump(tester, signers: const <StagedSigner>[]);
      expect(
        find.text('No signers added yet. Add at least one signer below.'),
        findsOneWidget,
      );
    });

    testWidgets('renders fieldError when set', (tester) async {
      await _pump(
        tester,
        signers: const <StagedSigner>[],
        fieldError: 'At least one signer is required',
      );
      expect(find.text('At least one signer is required'), findsOneWidget);
    });
  });

  // ---------------------------------------------------------------------------
  // Add Signer dropdown labels
  // ---------------------------------------------------------------------------

  group('SignerManagementSection — Signer Type dropdown', () {
    testWidgets('starts on Delegated form', (tester) async {
      await _pump(tester, signers: const <StagedSigner>[]);
      expect(find.text('Stellar Address (G-address)'), findsOneWidget);
      expect(find.text('Add Delegated Signer'), findsOneWidget);
    });
  });

  // ---------------------------------------------------------------------------
  // Delegated add flow
  // ---------------------------------------------------------------------------

  group('SignerManagementSection — delegated add', () {
    testWidgets('rejects invalid address with G-address error',
        (tester) async {
      await _pump(tester, signers: const <StagedSigner>[]);
      await tester.enterText(find.byType(TextField).first, 'X');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add Delegated Signer'));
      await tester.pumpAndSettle();
      expect(
        find.text('Must be a valid G-address (56 characters)'),
        findsOneWidget,
      );
    });

    testWidgets('valid G-address calls onAddSigner once', (tester) async {
      var captured = 0;
      String? capturedIdentifier;
      await _pump(
        tester,
        signers: const <StagedSigner>[],
        onAddSigner: (s) {
          captured++;
          capturedIdentifier = s.identifier;
          return null;
        },
      );
      await tester.enterText(
        find.byType(TextField).first,
        fixtureDelegatedAddress1,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add Delegated Signer'));
      await tester.pumpAndSettle();
      expect(captured, 1);
      expect(capturedIdentifier, isNotNull);
    });
  });

  // ---------------------------------------------------------------------------
  // Ed25519 form
  // ---------------------------------------------------------------------------

  group('SignerManagementSection — Ed25519 form', () {
    testWidgets('shows verifier helper text when ed25519 mode is selected',
        (tester) async {
      await _pump(tester, signers: const <StagedSigner>[]);
      // Tap the dropdown and select Ed25519
      await tester.tap(find.text('Delegated (G-address)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ed25519 Public Key').last);
      await tester.pumpAndSettle();

      expect(find.text('Ed25519 Public Key (hex)'), findsOneWidget);
      // Verifier text is truncated; check the leading literal.
      expect(find.textContaining('Uses verifier:'), findsOneWidget);
      expect(find.text('Add Ed25519 Signer'), findsOneWidget);
    });

    testWidgets('rejects non-hex characters with inline error',
        (tester) async {
      await _pump(tester, signers: const <StagedSigner>[]);
      await tester.tap(find.text('Delegated (G-address)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ed25519 Public Key').last);
      await tester.pumpAndSettle();

      final fieldFinder =
          find.widgetWithText(TextField, 'Ed25519 Public Key (hex)');
      await tester.enterText(fieldFinder, 'g' * 64);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add Ed25519 Signer'));
      await tester.pumpAndSettle();
      expect(find.text('Invalid hex characters'), findsOneWidget);
    });

    testWidgets(
        'shows inline error and does not invoke buildEd25519Signer when '
        'verifier is null', (tester) async {
      var addInvoked = false;
      var builderInvoked = false;
      await _pump(
        tester,
        signers: const <StagedSigner>[],
        ed25519VerifierAddress: null,
        buildEd25519Signer: (_) {
          builderInvoked = true;
          throw StateError(
            'buildEd25519Signer must not be called when verifier is null',
          );
        },
        onAddSigner: (_) {
          addInvoked = true;
          return null;
        },
      );
      await tester.tap(find.text('Delegated (G-address)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ed25519 Public Key').last);
      await tester.pumpAndSettle();

      // Confirm the helper text reflects the missing verifier.
      expect(find.text('Uses verifier: not configured'), findsOneWidget);

      final fieldFinder =
          find.widgetWithText(TextField, 'Ed25519 Public Key (hex)');
      // 64-char valid hex public key passes all surface validation.
      await tester.enterText(fieldFinder, '0' * 64);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add Ed25519 Signer'));
      await tester.pumpAndSettle();

      expect(
        find.text('Ed25519 verifier is not configured for this account.'),
        findsOneWidget,
      );
      expect(addInvoked, isFalse,
          reason: 'onAddSigner must not be invoked when the inline guard '
              'rejects the submission.');
      expect(builderInvoked, isFalse,
          reason: 'buildEd25519Signer must not be invoked when the inline '
              'guard rejects the submission; calling it would turn a '
              'graceful UI error into an uncaught exception.');
    });
  });

  // ---------------------------------------------------------------------------
  // Passkey form / Reuse Signer
  // ---------------------------------------------------------------------------

  group('SignerManagementSection — Passkey form', () {
    testWidgets('shows create-mode helper text and Register New button',
        (tester) async {
      await _pump(tester, signers: const <StagedSigner>[]);
      await tester.tap(find.text('Delegated (G-address)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Passkey (WebAuthn)').last);
      await tester.pumpAndSettle();

      expect(find.text('Passkey (WebAuthn) Signer'), findsOneWidget);
      expect(
        find.text(
          'You can reuse an account signer that is already stored in an '
          'existing context rule, or register a new passkey signer for '
          'this context rule.',
        ),
        findsOneWidget,
      );
      expect(find.text('Reuse Signer'), findsOneWidget);
      expect(find.text('Register New'), findsOneWidget);
    });

    testWidgets('Reuse Signer empty result shows empty-state message',
        (tester) async {
      await _pump(
        tester,
        signers: const <StagedSigner>[],
        loadPasskeySigners: () async => const <OZExternalSigner>[],
      );
      await tester.tap(find.text('Delegated (G-address)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Passkey (WebAuthn)').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reuse Signer'));
      await tester.pump();
      await tester.pump();
      expect(
        find.text('No existing passkey signers found on this account.'),
        findsOneWidget,
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Remove flow
  // ---------------------------------------------------------------------------

  group('SignerManagementSection — staged signer rows', () {
    testWidgets('renders signer count summary and remove tap callback',
        (tester) async {
      final staged = StagedSigner(
        type: StagedSignerType.delegated,
        identifier: 'GA12...AB34',
        signer: OZDelegatedSigner(fixtureDelegatedAddress1),
      );
      var removedKey = '';
      await _pump(
        tester,
        signers: [staged],
        onRemoveSigner: (s) => removedKey = s.uniqueKey,
      );
      expect(find.text('1 signer(s) added'), findsOneWidget);
      // Tap the close button on the staged row.
      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();
      expect(removedKey, staged.uniqueKey);
    });
  });

  // ---------------------------------------------------------------------------
  // Edit-mode signer rows
  // ---------------------------------------------------------------------------

  group('SignerManagementSection — edit-mode signer rows', () {
    testWidgets('shows "(on-chain)" badge only for entries with isOriginal=true',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final originalSigner = OZDelegatedSigner(fixtureDelegatedAddress1);
      final addedSigner = OZDelegatedSigner(fixtureDelegatedAddress2);

      await tester.pumpWidget(ProviderScope(child: MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: SignerManagementSection(
              signers: [
                StagedSigner(
                  type: StagedSignerType.delegated,
                  identifier: fixtureDelegatedAddress1,
                  signer: originalSigner,
                ),
                StagedSigner(
                  type: StagedSignerType.delegated,
                  identifier: fixtureDelegatedAddress2,
                  signer: addedSigner,
                ),
              ],
              fieldError: null,
              isSubmitting: false,
              maxSigners: 15,
              ed25519VerifierAddress: null,
              buildDelegatedSigner: OZDelegatedSigner.new,
              buildEd25519Signer: (_) => throw UnimplementedError(),
              onAddSigner: (_) => null,
              onRemoveSigner: (_) {},
              loadPasskeySigners: () async => const <OZExternalSigner>[],
              registerPasskeySigner: (_) async => throw UnimplementedError(),
              editEntries: [
                EditSignerEntry(
                  signer: originalSigner,
                  onChainId: 1,
                  isOriginal: true,
                ),
                EditSignerEntry(
                  signer: addedSigner,
                  onChainId: null,
                  isOriginal: false,
                ),
              ],
            ),
          ),
        ),
      )));
      await tester.pump();

      // Exactly one (on-chain) badge should appear because only one entry
      // is flagged isOriginal=true.
      expect(find.text('(on-chain)'), findsOneWidget);
    });

    testWidgets('shows "You" label when connectedCredentialId matches entry',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final publicKey = ContextRuleFixtures.makeWebAuthnPublicKey();
      final credentialBytes = ContextRuleFixtures.makeCredentialIdBytes();
      final passkey = OZExternalSigner.webAuthn(
        verifierAddress:
            'CAW2Z46INPO5VIJEILMYSSEOLBVJIIII5GOE3TN5EUURSRM2FJCF7AJ6',
        publicKey: publicKey,
        credentialId: credentialBytes,
      );
      final connectedCredentialId =
          OZSmartAccountBuilders.getCredentialIdStringFromSigner(passkey);
      expect(connectedCredentialId, isNotNull);

      await tester.pumpWidget(ProviderScope(child: MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: SignerManagementSection(
              signers: [
                StagedSigner(
                  type: StagedSignerType.passkey,
                  identifier: 'Passkey',
                  signer: passkey,
                ),
              ],
              fieldError: null,
              isSubmitting: false,
              maxSigners: 15,
              ed25519VerifierAddress: null,
              buildDelegatedSigner: OZDelegatedSigner.new,
              buildEd25519Signer: (_) => throw UnimplementedError(),
              onAddSigner: (_) => null,
              onRemoveSigner: (_) {},
              loadPasskeySigners: () async => const <OZExternalSigner>[],
              registerPasskeySigner: (_) async => throw UnimplementedError(),
              editEntries: [
                EditSignerEntry(
                  signer: passkey,
                  onChainId: 1,
                  isOriginal: true,
                ),
              ],
              connectedCredentialId: connectedCredentialId,
            ),
          ),
        ),
      )));
      await tester.pump();

      // The "You" label is rendered in place of the remove icon when the
      // edit-mode row matches the connected credential.
      expect(find.text('You'), findsOneWidget);
    });

    testWidgets('no "You" label when connectedCredentialId does not match',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final publicKey = ContextRuleFixtures.makeWebAuthnPublicKey();
      final credentialBytes = ContextRuleFixtures.makeCredentialIdBytes();
      final passkey = OZExternalSigner.webAuthn(
        verifierAddress:
            'CAW2Z46INPO5VIJEILMYSSEOLBVJIIII5GOE3TN5EUURSRM2FJCF7AJ6',
        publicKey: publicKey,
        credentialId: credentialBytes,
      );

      await tester.pumpWidget(ProviderScope(child: MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: SignerManagementSection(
              signers: [
                StagedSigner(
                  type: StagedSignerType.passkey,
                  identifier: 'Passkey',
                  signer: passkey,
                ),
              ],
              fieldError: null,
              isSubmitting: false,
              maxSigners: 15,
              ed25519VerifierAddress: null,
              buildDelegatedSigner: OZDelegatedSigner.new,
              buildEd25519Signer: (_) => throw UnimplementedError(),
              onAddSigner: (_) => null,
              onRemoveSigner: (_) {},
              loadPasskeySigners: () async => const <OZExternalSigner>[],
              registerPasskeySigner: (_) async => throw UnimplementedError(),
              editEntries: [
                EditSignerEntry(
                  signer: passkey,
                  onChainId: 1,
                  isOriginal: true,
                ),
              ],
              connectedCredentialId: 'some-other-credential-id',
            ),
          ),
        ),
      )));
      await tester.pump();

      expect(find.text('You'), findsNothing);
    });
  });
}

