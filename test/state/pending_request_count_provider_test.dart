/// Unit tests for [pendingRequestCountProvider] — the inbox bell badge count.
///
/// The coordination client is overridden with a [FakeCoordinationClient] and a
/// connected demo state so the account-scoped count refresh runs without a
/// network. Verifies the count tracks the server, that a failed refresh leaves
/// the previous count in place, the initial value is zero (no badge), and the
/// `set`/`reset` mutators that avoid a redundant fetch.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_account_demo/services/coordination_client.dart';
import 'package:smart_account_demo/state/coordination_client_provider.dart';
import 'package:smart_account_demo/state/demo_state.dart';
import 'package:smart_account_demo/state/pending_request_count_provider.dart';

import '../flows/approval_inbox_test_support.dart';

/// A [DemoStateNotifier] reporting a fixed connected account (or disconnected),
/// so the account-scoped count refresh has an account to filter against.
final class _ConnectedDemoState extends DemoStateNotifier {
  _ConnectedDemoState(this._account);

  final String? _account;

  @override
  WalletConnectionState build() {
    final account = _account;
    if (account == null) return const WalletConnectionState.disconnected();
    return WalletConnectionState(
      isConnected: true,
      isDeployed: true,
      contractId: account,
      credentialId: 'cred',
    );
  }
}

ProviderContainer _container(
  FakeCoordinationClient fake, {
  String? account = fixtureSmartAccount,
}) {
  final container = ProviderContainer(
    overrides: [
      coordinationClientProvider.overrideWithValue(fake),
      demoStateProvider.overrideWith(() => _ConnectedDemoState(account)),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('starts at zero so no badge is shown', () {
    final container = _container(FakeCoordinationClient());
    expect(container.read(pendingRequestCountProvider), 0);
  });

  test('refresh reflects the number of pending escalations for the account',
      () async {
    final fake = FakeCoordinationClient(
      pending: <CoordinationRequest>[
        buildRequest(id: 'a'),
        buildRequest(id: 'b'),
        buildRequest(id: 'c'),
      ],
    );
    final container = _container(fake);

    await container.read(pendingRequestCountProvider.notifier).refresh();

    expect(container.read(pendingRequestCountProvider), 3);
  });

  test('refresh counts only escalations for the connected account', () async {
    final fake = FakeCoordinationClient(
      pending: <CoordinationRequest>[
        // buildRequest defaults to smartAccount == fixtureSmartAccount.
        buildRequest(id: 'mine'),
        buildRequest(id: 'other', smartAccount: fixtureTarget),
      ],
    );
    final container = _container(fake);

    await container.read(pendingRequestCountProvider.notifier).refresh();

    expect(container.read(pendingRequestCountProvider), 1);
  });

  test('refresh is zero when disconnected (no account to scope to)', () async {
    final fake = FakeCoordinationClient(
      pending: <CoordinationRequest>[buildRequest(id: 'a')],
    );
    final container = _container(fake, account: null);

    await container.read(pendingRequestCountProvider.notifier).refresh();

    expect(container.read(pendingRequestCountProvider), 0);
  });

  test('a failed refresh leaves the previous count in place', () async {
    final fake = FakeCoordinationClient(
      pending: <CoordinationRequest>[buildRequest(id: 'a')],
    );
    final container = _container(fake);

    await container.read(pendingRequestCountProvider.notifier).refresh();
    expect(container.read(pendingRequestCountProvider), 1);

    // Server goes down: the badge keeps its last known value.
    fake.listError = const CoordinationException('down');
    await container.read(pendingRequestCountProvider.notifier).refresh();
    expect(container.read(pendingRequestCountProvider), 1);
  });

  test('set updates the badge without a network call', () {
    final fake = FakeCoordinationClient(
      pending: <CoordinationRequest>[buildRequest(id: 'a'), buildRequest(id: 'b')],
    );
    final container = _container(fake);

    container.read(pendingRequestCountProvider.notifier).set(5);

    expect(container.read(pendingRequestCountProvider), 5);
    // No GET was issued: the count came from the caller, not the server.
    expect(fake.listCount, 0);
  });

  test('set clamps negative values to zero', () {
    final container = _container(FakeCoordinationClient());
    container.read(pendingRequestCountProvider.notifier).set(-3);
    expect(container.read(pendingRequestCountProvider), 0);
  });

  test('reset returns the badge to zero', () {
    final container = _container(FakeCoordinationClient());
    final notifier = container.read(pendingRequestCountProvider.notifier);

    notifier.set(4);
    expect(container.read(pendingRequestCountProvider), 4);

    notifier.reset();
    expect(container.read(pendingRequestCountProvider), 0);
  });
}
