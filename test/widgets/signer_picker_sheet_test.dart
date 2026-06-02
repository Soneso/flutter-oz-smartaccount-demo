/// Widget tests for [SignerPickerSheet].
///
/// Strategy:
/// - Layout: title, description, and close icon visible.
/// - Initial selection: only the active passkey is checked at open; all other
///   rows start unchecked.
/// - Section headers grouped by [SignerKind] (passkey / delegated / Ed25519).
/// - Badges and chips: "Active" on the connected passkey, "WebAuthn" chip on
///   every passkey row, "Ed25519" chip on every Ed25519 row.
/// - Confirm button label includes the selected count and is disabled when
///   no signers are selected.
/// - Delegated state machine: toggle disabled before authorization; Enter Key
///   + Verify path; Connect wallet path; single-wallet invariant; dismiss
///   cleanup.
/// - Confirm / Cancel button paths.
library;

import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_account_demo/flows/transfer_flow.dart';
import 'package:smart_account_demo/wallet/wallet_connector.dart';
import 'package:smart_account_demo/widgets/signer_picker_sheet.dart';

/// Chip / subtitle text the picker derives from [defaultWalletConnectLabel].
/// Mirrors the runtime "strip Connect " logic in the picker.
const String _walletShortLabel = kIsWeb ? 'Freighter' : 'Wallet';

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const _activeCredentialId = 'abc123';

const _passkeySigner = SignerInfo(
  displayLabel: 'abc123...xyz789',
  address: '',
  kind: SignerKind.passkey,
  isConnectedCredential: true,
  credentialId: _activeCredentialId,
);

const _otherPasskeySigner = SignerInfo(
  displayLabel: 'def456...uvw012',
  address: '',
  kind: SignerKind.passkey,
  isConnectedCredential: false,
  credentialId: 'def456',
);

// StrKey-valid G-address (Stellar testnet account, verified via StrKey CRC).
const _delegatedSignerAddress =
    'GCKE5G7SSH4O4QBJWS32UY3C2MOMTULMSPMJD6ZJ426FOHXH5YCUNMPM';

const _delegatedSigner = SignerInfo(
  displayLabel: 'GCKE...NMPM',
  address: _delegatedSignerAddress,
  kind: SignerKind.delegated,
  isConnectedCredential: false,
);

// Second StrKey-valid G-address used by single-wallet invariant tests.
const _delegatedSignerAddressTwo =
    'GDQNY3PBOJOKYZSRMK2S7LHV4WDZNNYK2ROOXY6ULSOLY63MXRSGYRWP';

const _delegatedSignerTwo = SignerInfo(
  displayLabel: 'GDQN...YRWP',
  address: _delegatedSignerAddressTwo,
  kind: SignerKind.delegated,
  isConnectedCredential: false,
);

// StrKey-valid C-address used to stand in for an Ed25519 verifier contract.
const _ed25519VerifierAddress =
    'CDLZFC3SYJYDZT7K67VZ75HPJVIEUVNIXF47ZG2FB2RMQQVU2HHGCYSC';

const _ed25519Signer = SignerInfo(
  displayLabel: 'CDLZ...CYSC',
  address: _ed25519VerifierAddress,
  kind: SignerKind.ed25519,
  isConnectedCredential: false,
);

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

// ---------------------------------------------------------------------------
// Fake wallet connector
// ---------------------------------------------------------------------------

/// In-memory [WalletConnector] used by widget tests.
///
/// The connect / disconnect / sign behaviour is driven by configurable
/// callbacks so each test can choreograph success, mismatch, exception, and
/// cancellation paths without touching real wallet infrastructure.
final class _FakeWalletConnector implements WalletConnector {
  _FakeWalletConnector({
    required this.connectImpl,
    Future<void> Function()? disconnectImpl,
  }) : _disconnectImpl = disconnectImpl ?? (() async {});

  /// Function executed by [connect]. May return an address, return null
  /// (simulates user cancel), or throw a [WalletConnectionException] /
  /// [WalletNetworkMismatchException].
  final Future<String?> Function() connectImpl;

  /// Optional disconnect hook, defaults to a no-op completer.
  final Future<void> Function() _disconnectImpl;

  String? _connectedAddress;
  int connectCallCount = 0;
  int disconnectCallCount = 0;

  @override
  Future<String?> connect() async {
    connectCallCount += 1;
    try {
      final addr = await connectImpl();
      _connectedAddress = addr;
      return addr;
    } catch (_) {
      _connectedAddress = null;
      rethrow;
    }
  }

  @override
  Future<void> disconnect() async {
    disconnectCallCount += 1;
    _connectedAddress = null;
    await _disconnectImpl();
  }

  @override
  Future<bool> restoreSession() async => false;

  @override
  Future<SignedAuthEntry> signAuthEntry({
    required String authEntryXdr,
    required List<int> contextRuleIds,
  }) async {
    throw UnimplementedError('signAuthEntry is not used by the picker widget');
  }

  @override
  String? get connectedAddress => _connectedAddress;

  @override
  WalletMetadata? get walletMetadata =>
      const WalletMetadata(name: 'Fake', url: 'https://example.test');
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// No-op secret validator for tests that do not exercise validation.
String? _noOpValidator(String address, String seed) => null;

/// No-op Ed25519 secret validator for tests that do not exercise Ed25519
/// secret validation. Always returns a successful result with a fake seed.
({Uint8List? rawSeed, String? error}) _noOpEd25519Validator(
  Uint8List expectedPublicKey,
  String hexInput,
) =>
    (rawSeed: Uint8List(32), error: null);

/// Validator that accepts a fixed [secret] for the given [expectedAddress]
/// and reports an error for everything else.
String? Function(String, String) _matchingValidator({
  required String expectedAddress,
  required String secret,
}) {
  return (address, seed) {
    if (address == expectedAddress && seed == secret) return null;
    return 'Secret key does not match this signer\'s address.';
  };
}

/// Sets a large enough viewport so the picker contents do not overflow when
/// the row layout grows.
void _useLargeSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// Walks up the widget tree from the element backing [finder] until it
/// finds an enclosing [OutlinedButton] (which subsumes the icon-variant
/// subclass returned by `OutlinedButton.icon`) and returns it.
OutlinedButton _findEnclosingOutlinedButton(
  WidgetTester tester,
  Finder finder,
) {
  final element = tester.element(finder);
  OutlinedButton? found;
  element.visitAncestorElements((ancestor) {
    final widget = ancestor.widget;
    if (widget is OutlinedButton) {
      found = widget;
      return false;
    }
    return true;
  });
  if (found == null) {
    throw StateError(
      'No enclosing OutlinedButton found for finder $finder',
    );
  }
  return found!;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('SignerPickerSheet — layout', () {
    testWidgets('shows title "Select Signers"', (tester) async {
      await tester.pumpWidget(
        _wrap(
          SignerPickerSheet(
            availableSigners: const [_passkeySigner],
            connectedCredentialId: _activeCredentialId,
            onConfirm: (signers, keypairs, ed25519Secrets) {},
            onCancel: () {},
            validateDelegatedSecret: _noOpValidator,
            validateEd25519Secret: _noOpEd25519Validator,
          ),
        ),
      );
      expect(find.text('Select Signers'), findsOneWidget);
    });

    testWidgets('shows verbatim description', (tester) async {
      await tester.pumpWidget(
        _wrap(
          SignerPickerSheet(
            availableSigners: const [_passkeySigner],
            connectedCredentialId: _activeCredentialId,
            onConfirm: (signers, keypairs, ed25519Secrets) {},
            onCancel: () {},
            validateDelegatedSecret: _noOpValidator,
            validateEd25519Secret: _noOpEd25519Validator,
          ),
        ),
      );
      expect(
        find.textContaining(
          'Choose which signers co-authorize this operation.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('shows close icon in the header', (tester) async {
      await tester.pumpWidget(
        _wrap(
          SignerPickerSheet(
            availableSigners: const [_passkeySigner],
            connectedCredentialId: _activeCredentialId,
            onConfirm: (signers, keypairs, ed25519Secrets) {},
            onCancel: () {},
            validateDelegatedSecret: _noOpValidator,
            validateEd25519Secret: _noOpEd25519Validator,
          ),
        ),
      );
      expect(find.byIcon(Icons.close), findsOneWidget);
    });

    testWidgets(
      'shows Cancel button and Confirm label with selected count',
      (tester) async {
        await tester.pumpWidget(
          _wrap(
            SignerPickerSheet(
              availableSigners: const [_passkeySigner],
              connectedCredentialId: _activeCredentialId,
              onConfirm: (signers, keypairs, ed25519Secrets) {},
              onCancel: () {},
              validateDelegatedSecret: _noOpValidator,
              validateEd25519Secret: _noOpEd25519Validator,
            ),
          ),
        );
        expect(find.text('Cancel'), findsOneWidget);
        // Active passkey is preselected, so count is 1.
        expect(find.text('Confirm (1 selected)'), findsOneWidget);
      },
    );

    testWidgets('shows empty-state copy when no signers are available',
        (tester) async {
      await tester.pumpWidget(
        _wrap(
          SignerPickerSheet(
            availableSigners: const [],
            connectedCredentialId: null,
            onConfirm: (signers, keypairs, ed25519Secrets) {},
            onCancel: () {},
            validateDelegatedSecret: _noOpValidator,
            validateEd25519Secret: _noOpEd25519Validator,
          ),
        ),
      );
      expect(
        find.text('No signers available for this context.'),
        findsOneWidget,
      );
    });
  });

  group('SignerPickerSheet — initial selection', () {
    testWidgets('only the active passkey is checked at open', (tester) async {
      _useLargeSurface(tester);
      await tester.pumpWidget(
        _wrap(
          SignerPickerSheet(
            availableSigners: const [
              _passkeySigner,
              _otherPasskeySigner,
              _delegatedSigner,
              _ed25519Signer,
            ],
            connectedCredentialId: _activeCredentialId,
            onConfirm: (signers, keypairs, ed25519Secrets) {},
            onCancel: () {},
            validateDelegatedSecret: _noOpValidator,
            validateEd25519Secret: _noOpEd25519Validator,
          ),
        ),
      );

      final checkboxes = tester
          .widgetList<Checkbox>(find.byType(Checkbox))
          .toList(growable: false);
      expect(checkboxes, hasLength(4));
      // Active passkey first (preselected), the rest unchecked.
      expect(checkboxes[0].value, isTrue);
      expect(checkboxes[1].value, isFalse);
      expect(checkboxes[2].value, isFalse);
      expect(checkboxes[3].value, isFalse);
    });

    testWidgets('no rows are preselected when no active credential matches',
        (tester) async {
      _useLargeSurface(tester);
      await tester.pumpWidget(
        _wrap(
          SignerPickerSheet(
            availableSigners: const [
              _otherPasskeySigner,
              _delegatedSigner,
            ],
            connectedCredentialId: _activeCredentialId,
            onConfirm: (signers, keypairs, ed25519Secrets) {},
            onCancel: () {},
            validateDelegatedSecret: _noOpValidator,
            validateEd25519Secret: _noOpEd25519Validator,
          ),
        ),
      );

      final checkboxes = tester
          .widgetList<Checkbox>(find.byType(Checkbox))
          .toList(growable: false);
      expect(checkboxes.every((c) => c.value == false), isTrue);
    });
  });

  group('SignerPickerSheet — section headers', () {
    testWidgets('renders only the headers for non-empty kind buckets',
        (tester) async {
      _useLargeSurface(tester);

      await tester.pumpWidget(
        _wrap(
          SignerPickerSheet(
            availableSigners: const [
              _passkeySigner,
              _delegatedSigner,
              _ed25519Signer,
            ],
            connectedCredentialId: _activeCredentialId,
            onConfirm: (signers, keypairs, ed25519Secrets) {},
            onCancel: () {},
            validateDelegatedSecret: _noOpValidator,
            validateEd25519Secret: _noOpEd25519Validator,
          ),
        ),
      );

      expect(find.text('Passkey Signers'), findsOneWidget);
      expect(find.text('Stellar Account Signers'), findsOneWidget);
      expect(find.text('Ed25519 Signers'), findsOneWidget);
    });

    testWidgets('omits headers for empty buckets', (tester) async {
      await tester.pumpWidget(
        _wrap(
          SignerPickerSheet(
            availableSigners: const [_passkeySigner],
            connectedCredentialId: _activeCredentialId,
            onConfirm: (signers, keypairs, ed25519Secrets) {},
            onCancel: () {},
            validateDelegatedSecret: _noOpValidator,
            validateEd25519Secret: _noOpEd25519Validator,
          ),
        ),
      );

      expect(find.text('Passkey Signers'), findsOneWidget);
      expect(find.text('Stellar Account Signers'), findsNothing);
      expect(find.text('Ed25519 Signers'), findsNothing);
    });
  });

  group('SignerPickerSheet — chips and badges', () {
    testWidgets('shows "Active" badge on the connected passkey row',
        (tester) async {
      await tester.pumpWidget(
        _wrap(
          SignerPickerSheet(
            availableSigners: const [_passkeySigner],
            connectedCredentialId: _activeCredentialId,
            onConfirm: (signers, keypairs, ed25519Secrets) {},
            onCancel: () {},
            validateDelegatedSecret: _noOpValidator,
            validateEd25519Secret: _noOpEd25519Validator,
          ),
        ),
      );
      expect(find.text('Active'), findsOneWidget);
    });

    testWidgets('shows "WebAuthn" chip on every passkey row', (tester) async {
      _useLargeSurface(tester);

      await tester.pumpWidget(
        _wrap(
          SignerPickerSheet(
            availableSigners: const [_passkeySigner, _otherPasskeySigner],
            connectedCredentialId: _activeCredentialId,
            onConfirm: (signers, keypairs, ed25519Secrets) {},
            onCancel: () {},
            validateDelegatedSecret: _noOpValidator,
            validateEd25519Secret: _noOpEd25519Validator,
          ),
        ),
      );
      expect(find.text('WebAuthn'), findsNWidgets(2));
    });

    testWidgets('shows "Ed25519" chip on Ed25519 rows', (tester) async {
      await tester.pumpWidget(
        _wrap(
          SignerPickerSheet(
            availableSigners: const [_ed25519Signer],
            connectedCredentialId: null,
            onConfirm: (signers, keypairs, ed25519Secrets) {},
            onCancel: () {},
            validateDelegatedSecret: _noOpValidator,
            validateEd25519Secret: _noOpEd25519Validator,
          ),
        ),
      );
      expect(find.text('Ed25519'), findsOneWidget);
    });
  });

  group('SignerPickerSheet — signer display', () {
    testWidgets('shows passkey signer label', (tester) async {
      await tester.pumpWidget(
        _wrap(
          SignerPickerSheet(
            availableSigners: const [_passkeySigner],
            connectedCredentialId: _activeCredentialId,
            onConfirm: (signers, keypairs, ed25519Secrets) {},
            onCancel: () {},
            validateDelegatedSecret: _noOpValidator,
            validateEd25519Secret: _noOpEd25519Validator,
          ),
        ),
      );
      expect(find.text(_passkeySigner.displayLabel), findsOneWidget);
    });

    testWidgets('shows delegated signer label', (tester) async {
      await tester.pumpWidget(
        _wrap(
          SignerPickerSheet(
            availableSigners: const [_delegatedSigner],
            connectedCredentialId: null,
            onConfirm: (signers, keypairs, ed25519Secrets) {},
            onCancel: () {},
            validateDelegatedSecret: _noOpValidator,
            validateEd25519Secret: _noOpEd25519Validator,
          ),
        ),
      );
      expect(find.text(_delegatedSigner.displayLabel), findsOneWidget);
    });
  });

  group('SignerPickerSheet — delegated state machine', () {
    testWidgets('delegated row checkbox starts disabled when not authorized',
        (tester) async {
      await tester.pumpWidget(
        _wrap(
          SignerPickerSheet(
            availableSigners: const [_delegatedSigner],
            connectedCredentialId: null,
            onConfirm: (signers, keypairs, ed25519Secrets) {},
            onCancel: () {},
            validateDelegatedSecret: _noOpValidator,
            validateEd25519Secret: _noOpEd25519Validator,
          ),
        ),
      );
      final checkbox = tester.widget<Checkbox>(find.byType(Checkbox));
      expect(checkbox.value, isFalse);
      expect(checkbox.onChanged, isNull);
      expect(
        find.text('Enter secret key or connect wallet to enable signing'),
        findsOneWidget,
      );
    });

    testWidgets('shows Enter Key button and hides Connect when no connector',
        (tester) async {
      await tester.pumpWidget(
        _wrap(
          SignerPickerSheet(
            availableSigners: const [_delegatedSigner],
            connectedCredentialId: null,
            onConfirm: (signers, keypairs, ed25519Secrets) {},
            onCancel: () {},
            validateDelegatedSecret: _noOpValidator,
            validateEd25519Secret: _noOpEd25519Validator,
          ),
        ),
      );
      expect(find.text('Enter Key'), findsOneWidget);
      expect(find.text(defaultWalletConnectLabel), findsNothing);
    });

    testWidgets('shows Connect Freighter when a wallet connector is provided',
        (tester) async {
      final connector = _FakeWalletConnector(
        connectImpl: () async => _delegatedSignerAddress,
      );
      await tester.pumpWidget(
        _wrap(
          SignerPickerSheet(
            availableSigners: const [_delegatedSigner],
            connectedCredentialId: null,
            onConfirm: (signers, keypairs, ed25519Secrets) {},
            onCancel: () {},
            validateDelegatedSecret: _noOpValidator,
            validateEd25519Secret: _noOpEd25519Validator,
            walletConnector: connector,
          ),
        ),
      );
      expect(find.text('Enter Key'), findsOneWidget);
      expect(find.text(defaultWalletConnectLabel), findsOneWidget);
    });

    testWidgets('Enter Key + Verify enables the row and shows Verified chip',
        (tester) async {
      const secret = 'SCSEED12345EXAMPLE';
      await tester.pumpWidget(
        _wrap(
          SignerPickerSheet(
            availableSigners: const [_delegatedSigner],
            connectedCredentialId: null,
            onConfirm: (signers, keypairs, ed25519Secrets) {},
            onCancel: () {},
            validateDelegatedSecret: _matchingValidator(
              expectedAddress: _delegatedSignerAddress,
              secret: secret,
            ),
            validateEd25519Secret: _noOpEd25519Validator,
          ),
        ),
      );

      await tester.tap(find.text('Enter Key'));
      await tester.pump();
      expect(find.text('Secret Key'), findsOneWidget);

      await tester.enterText(find.byType(TextField), secret);
      await tester.tap(find.widgetWithText(FilledButton, 'Verify'));
      // First pump flips into the validating state, second resolves the
      // delayed validator microtask.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));

      expect(find.text('Verified'), findsOneWidget);
      expect(find.text('Ready to sign'), findsOneWidget);
      expect(find.text('Clear key'), findsOneWidget);
      final checkbox = tester.widget<Checkbox>(find.byType(Checkbox));
      expect(checkbox.value, isTrue);
      expect(checkbox.onChanged, isNotNull);
    });

    testWidgets('Verify with mismatched secret keeps row disabled',
        (tester) async {
      await tester.pumpWidget(
        _wrap(
          SignerPickerSheet(
            availableSigners: const [_delegatedSigner],
            connectedCredentialId: null,
            onConfirm: (signers, keypairs, ed25519Secrets) {},
            onCancel: () {},
            validateDelegatedSecret: _matchingValidator(
              expectedAddress: _delegatedSignerAddress,
              secret: 'EXPECTED_SECRET',
            ),
            validateEd25519Secret: _noOpEd25519Validator,
          ),
        ),
      );

      await tester.tap(find.text('Enter Key'));
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'WRONG_SECRET');
      await tester.tap(find.widgetWithText(FilledButton, 'Verify'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));

      expect(find.text('Verified'), findsNothing);
      expect(
        find.text('Secret key does not match this signer\'s address.'),
        findsOneWidget,
      );
      final checkbox = tester.widget<Checkbox>(find.byType(Checkbox));
      expect(checkbox.onChanged, isNull);
    });

    testWidgets(
      'Connect Freighter success enables the row and shows Freighter chip',
      (tester) async {
        _useLargeSurface(tester);
        final connector = _FakeWalletConnector(
          connectImpl: () async => _delegatedSignerAddress,
        );
        await tester.pumpWidget(
          _wrap(
            SignerPickerSheet(
              availableSigners: const [_delegatedSigner],
              connectedCredentialId: null,
              onConfirm: (signers, keypairs, ed25519Secrets) {},
              onCancel: () {},
              validateDelegatedSecret: _noOpValidator,
              validateEd25519Secret: _noOpEd25519Validator,
              walletConnector: connector,
            ),
          ),
        );

        await tester.tap(find.text(defaultWalletConnectLabel));
        // Resolve the awaited Future microtask.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 10));

        expect(find.text(_walletShortLabel), findsOneWidget);
        expect(find.text('$_walletShortLabel - Ready to sign'), findsOneWidget);
        expect(find.text('Disconnect'), findsOneWidget);
        final checkbox = tester.widget<Checkbox>(find.byType(Checkbox));
        expect(checkbox.value, isTrue);
        expect(checkbox.onChanged, isNotNull);
        expect(connector.connectCallCount, equals(1));
      },
    );

    testWidgets(
      'Connect Freighter address mismatch keeps row disabled and shows error',
      (tester) async {
        const otherAddress =
            'GDQNY3PBOJOKYZSRMK2S7LHV4WDZNNYK2ROOXY6ULSOLY63MXRSGYRWP';
        final connector = _FakeWalletConnector(
          connectImpl: () async => otherAddress,
        );
        await tester.pumpWidget(
          _wrap(
            SignerPickerSheet(
              availableSigners: const [_delegatedSigner],
              connectedCredentialId: null,
              onConfirm: (signers, keypairs, ed25519Secrets) {},
              onCancel: () {},
              validateDelegatedSecret: _noOpValidator,
              validateEd25519Secret: _noOpEd25519Validator,
              walletConnector: connector,
            ),
          ),
        );

        await tester.tap(find.text(defaultWalletConnectLabel));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 10));

        expect(find.text(_walletShortLabel), findsNothing);
        expect(
          find.textContaining('does not match this signer'),
          findsOneWidget,
        );
        final checkbox = tester.widget<Checkbox>(find.byType(Checkbox));
        expect(checkbox.value, isFalse);
        expect(checkbox.onChanged, isNull);
        // Mismatch path issues a best-effort disconnect.
        expect(connector.disconnectCallCount, equals(1));
      },
    );

    testWidgets(
      'Connect Freighter cancellation reverts to none without error',
      (tester) async {
        _useLargeSurface(tester);
        final connector = _FakeWalletConnector(
          connectImpl: () async => null,
        );
        await tester.pumpWidget(
          _wrap(
            SignerPickerSheet(
              availableSigners: const [_delegatedSigner],
              connectedCredentialId: null,
              onConfirm: (signers, keypairs, ed25519Secrets) {},
              onCancel: () {},
              validateDelegatedSecret: _noOpValidator,
              validateEd25519Secret: _noOpEd25519Validator,
              walletConnector: connector,
            ),
          ),
        );

        await tester.tap(find.text(defaultWalletConnectLabel));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 10));

        expect(find.text(_walletShortLabel), findsNothing);
        expect(find.textContaining('Error:'), findsNothing);
        expect(find.text(defaultWalletConnectLabel), findsOneWidget);
      },
    );

    testWidgets(
      'single-wallet invariant disables Connect on other rows',
      (tester) async {
        _useLargeSurface(tester);
        final connector = _FakeWalletConnector(
          connectImpl: () async => _delegatedSignerAddress,
        );
        await tester.pumpWidget(
          _wrap(
            SignerPickerSheet(
              availableSigners: const [
                _delegatedSigner,
                _delegatedSignerTwo,
              ],
              connectedCredentialId: null,
              onConfirm: (signers, keypairs, ed25519Secrets) {},
              onCancel: () {},
              validateDelegatedSecret: _noOpValidator,
              validateEd25519Secret: _noOpEd25519Validator,
              walletConnector: connector,
            ),
          ),
        );

        // Connect first delegated signer.
        await tester.tap(find.text(defaultWalletConnectLabel).first);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 10));

        // First row is now walletConnected; the second row's Connect button
        // is the only remaining "Connect Freighter" text. Walk up to the
        // nearest OutlinedButton (OutlinedButton.icon is a subclass that
        // satisfies the predicate match) and assert it is disabled.
        final remainingConnectText = find.text(defaultWalletConnectLabel);
        expect(remainingConnectText, findsOneWidget);
        final connectButton = _findEnclosingOutlinedButton(
          tester,
          remainingConnectText,
        );
        expect(connectButton.onPressed, isNull);
      },
    );

    testWidgets(
      'Disconnect reverts the row to none and re-enables other rows',
      (tester) async {
        _useLargeSurface(tester);
        final connector = _FakeWalletConnector(
          connectImpl: () async => _delegatedSignerAddress,
        );
        await tester.pumpWidget(
          _wrap(
            SignerPickerSheet(
              availableSigners: const [
                _delegatedSigner,
                _delegatedSignerTwo,
              ],
              connectedCredentialId: null,
              onConfirm: (signers, keypairs, ed25519Secrets) {},
              onCancel: () {},
              validateDelegatedSecret: _noOpValidator,
              validateEd25519Secret: _noOpEd25519Validator,
              walletConnector: connector,
            ),
          ),
        );

        await tester.tap(find.text(defaultWalletConnectLabel).first);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 10));

        await tester.tap(find.text('Disconnect'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 10));

        expect(find.text(_walletShortLabel), findsNothing);
        expect(find.text('Disconnect'), findsNothing);
        // Both rows show a Connect button again, both must be pressable.
        final connectTexts = find.text(defaultWalletConnectLabel);
        expect(connectTexts, findsNWidgets(2));
        for (var i = 0; i < 2; i++) {
          final button =
              _findEnclosingOutlinedButton(tester, connectTexts.at(i));
          expect(button.onPressed, isNotNull);
        }
        expect(connector.disconnectCallCount, greaterThanOrEqualTo(1));
      },
    );

    testWidgets(
      'Clear key reverts a verified delegated row to none',
      (tester) async {
        const secret = 'SCSEED12345EXAMPLE';
        await tester.pumpWidget(
          _wrap(
            SignerPickerSheet(
              availableSigners: const [_delegatedSigner],
              connectedCredentialId: null,
              onConfirm: (signers, keypairs, ed25519Secrets) {},
              onCancel: () {},
              validateDelegatedSecret: _matchingValidator(
                expectedAddress: _delegatedSignerAddress,
                secret: secret,
              ),
              validateEd25519Secret: _noOpEd25519Validator,
            ),
          ),
        );

        await tester.tap(find.text('Enter Key'));
        await tester.pump();
        await tester.enterText(find.byType(TextField), secret);
        await tester.tap(find.widgetWithText(FilledButton, 'Verify'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 10));

        expect(find.text('Verified'), findsOneWidget);

        await tester.tap(find.text('Clear key'));
        await tester.pump();

        expect(find.text('Verified'), findsNothing);
        expect(find.text('Enter Key'), findsOneWidget);
        final checkbox = tester.widget<Checkbox>(find.byType(Checkbox));
        expect(checkbox.value, isFalse);
        expect(checkbox.onChanged, isNull);
      },
    );
  });

  group('SignerPickerSheet — confirm button state', () {
    testWidgets('confirm button is disabled when no signers are selected',
        (tester) async {
      await tester.pumpWidget(
        _wrap(
          SignerPickerSheet(
            availableSigners: const [_delegatedSigner],
            connectedCredentialId: null,
            onConfirm: (signers, keypairs, ed25519Secrets) {},
            onCancel: () {},
            validateDelegatedSecret: _noOpValidator,
            validateEd25519Secret: _noOpEd25519Validator,
          ),
        ),
      );
      expect(find.text('Confirm (0 selected)'), findsOneWidget);
      final button = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(button.onPressed, isNull);
    });

    testWidgets('confirm button label updates with the selected count',
        (tester) async {
      _useLargeSurface(tester);
      await tester.pumpWidget(
        _wrap(
          SignerPickerSheet(
            availableSigners: const [_passkeySigner, _otherPasskeySigner],
            connectedCredentialId: _activeCredentialId,
            onConfirm: (signers, keypairs, ed25519Secrets) {},
            onCancel: () {},
            validateDelegatedSecret: _noOpValidator,
            validateEd25519Secret: _noOpEd25519Validator,
          ),
        ),
      );
      // Only the active passkey starts selected → 1.
      expect(find.text('Confirm (1 selected)'), findsOneWidget);

      // Toggle the second (non-active) passkey on → 2.
      final checkboxFinder = find.byType(Checkbox);
      await tester.tap(checkboxFinder.at(1));
      await tester.pump();
      expect(find.text('Confirm (2 selected)'), findsOneWidget);
    });

    testWidgets('uses the caller-provided verb in the confirm label',
        (tester) async {
      await tester.pumpWidget(
        _wrap(
          SignerPickerSheet(
            availableSigners: const [_passkeySigner],
            connectedCredentialId: _activeCredentialId,
            onConfirm: (signers, keypairs, ed25519Secrets) {},
            onCancel: () {},
            validateDelegatedSecret: _noOpValidator,
            validateEd25519Secret: _noOpEd25519Validator,
            confirmLabel: 'Apply Edit',
          ),
        ),
      );
      expect(find.text('Apply Edit (1 selected)'), findsOneWidget);
    });
  });

  group('SignerPickerSheet — confirmation flow', () {
    testWidgets(
      'onConfirm called with active passkey selected by default',
      (tester) async {
        List<SignerInfo>? selectedSigners;
        Map<String, String>? delegatedKeyPairs;

        await tester.pumpWidget(
          _wrap(
            SignerPickerSheet(
              availableSigners: const [_passkeySigner],
              connectedCredentialId: _activeCredentialId,
              onConfirm: (s, d, e) {
                selectedSigners = s;
                delegatedKeyPairs = d;
              },
              onCancel: () {},
              validateDelegatedSecret: _noOpValidator,
              validateEd25519Secret: _noOpEd25519Validator,
            ),
          ),
        );

        await tester.tap(find.text('Confirm (1 selected)'));
        await tester.pump();

        expect(selectedSigners, isNotNull);
        expect(selectedSigners, hasLength(1));
        expect(selectedSigners!.first.kind, equals(SignerKind.passkey));
        expect(delegatedKeyPairs, isEmpty);
      },
    );

    testWidgets(
      'confirm omits wallet-authorized addresses from delegatedKeyPairs',
      (tester) async {
        _useLargeSurface(tester);
        Map<String, String>? capturedKeyPairs;
        List<SignerInfo>? capturedSigners;
        final connector = _FakeWalletConnector(
          connectImpl: () async => _delegatedSignerAddress,
        );

        await tester.pumpWidget(
          _wrap(
            Navigator(
              onGenerateRoute: (_) => MaterialPageRoute(
                builder: (context) => SignerPickerSheet(
                  availableSigners: const [_delegatedSigner],
                  connectedCredentialId: null,
                  onConfirm: (s, d, e) {
                    capturedSigners = s;
                    capturedKeyPairs = d;
                  },
                  onCancel: () {},
                  validateDelegatedSecret: _noOpValidator,
              validateEd25519Secret: _noOpEd25519Validator,
                  walletConnector: connector,
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.text(defaultWalletConnectLabel));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 10));

        await tester.tap(find.widgetWithText(FilledButton, 'Confirm (1 selected)'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 10));

        expect(capturedSigners, isNotNull);
        expect(capturedSigners!.single.address, equals(_delegatedSignerAddress));
        // Wallet-backed rows must NOT appear in delegatedKeyPairs.
        expect(capturedKeyPairs, isEmpty);
        // Successful confirm must not disconnect — the caller still needs
        // the active session.
        expect(connector.disconnectCallCount, equals(0));
      },
    );
  });

  group('SignerPickerSheet — cancellation and dismiss', () {
    testWidgets('onCancel called when Cancel tapped', (tester) async {
      var cancelled = false;
      await tester.pumpWidget(
        _wrap(
          SignerPickerSheet(
            availableSigners: const [_passkeySigner],
            connectedCredentialId: _activeCredentialId,
            onConfirm: (signers, keypairs, ed25519Secrets) {},
            onCancel: () => cancelled = true,
            validateDelegatedSecret: _noOpValidator,
            validateEd25519Secret: _noOpEd25519Validator,
          ),
        ),
      );

      await tester.tap(find.text('Cancel'));
      await tester.pump();

      expect(cancelled, isTrue);
    });

    testWidgets('close icon dismisses and triggers onCancel', (tester) async {
      var cancelled = false;
      await tester.pumpWidget(
        _wrap(
          SignerPickerSheet(
            availableSigners: const [_passkeySigner],
            connectedCredentialId: _activeCredentialId,
            onConfirm: (signers, keypairs, ed25519Secrets) {},
            onCancel: () => cancelled = true,
            validateDelegatedSecret: _noOpValidator,
            validateEd25519Secret: _noOpEd25519Validator,
          ),
        ),
      );

      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();

      expect(cancelled, isTrue);
    });

    testWidgets(
      'disposing the sheet with an active wallet triggers disconnect',
      (tester) async {
        _useLargeSurface(tester);
        final connector = _FakeWalletConnector(
          connectImpl: () async => _delegatedSignerAddress,
        );

        // Build inside its own Navigator so we can pop the route to trigger
        // disposal.
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (rootContext) => Scaffold(
                body: SignerPickerSheet(
                  availableSigners: const [_delegatedSigner],
                  connectedCredentialId: null,
                  onConfirm: (s, d, e) {},
                  onCancel: () {},
                  validateDelegatedSecret: _noOpValidator,
              validateEd25519Secret: _noOpEd25519Validator,
                  walletConnector: connector,
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.text(defaultWalletConnectLabel));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 10));
        expect(connector.disconnectCallCount, equals(0));

        // Force disposal of the SignerPickerSheet by swapping the home.
        await tester.pumpWidget(const MaterialApp(home: SizedBox()));
        // Allow the fire-and-forget disconnect to run.
        await tester.pump(const Duration(milliseconds: 10));

        expect(connector.disconnectCallCount, equals(1));
      },
    );
  });
}
