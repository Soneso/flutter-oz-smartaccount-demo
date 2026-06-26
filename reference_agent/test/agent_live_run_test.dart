// Copyright 2026 Soneso. Reference agent for the OZ smart-account demo.
//
// PRIMARY RUN ENTRY.
//
// This is the headless run path for the reference agent. The agent is a
// Flutter package (the stellar_flutter_sdk barrel transitively imports
// package:flutter / dart:ui, so a plain `dart run` cannot resolve), so it runs
// under `flutter test`.
//
// Live run (hits testnet + a running coordination server):
//
//   AGENT_RUN_LIVE=true \
//   AGENT_SMART_ACCOUNT=C... \
//   AGENT_SECRET_SEED=<64-hex> \
//   AGENT_DESTINATION=G... \
//   AGENT_COORDINATION_URL=http://localhost:8787 \
//   AGENT_COORDINATION_TOKEN=dev-token-change-me \
//   flutter test test/agent_live_run_test.dart
//
// A live run requires a smart account that already has the agent's Ed25519 key
// registered as a scoped signer (the step-2 delegation flow, built next).
// Without AGENT_RUN_LIVE and a complete config this test is skipped, so the
// default `flutter test` run never touches the network.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reference_agent/reference_agent.dart';

void main() {
  final config = AgentConfig.resolve();
  final runLive =
      (Platform.environment['AGENT_RUN_LIVE'] ?? '').toLowerCase() == 'true';
  final shouldRun = runLive && config.isCompleteForLiveRun;

  test(
    'agent runs end-to-end and reaches a terminal result',
    () async {
      final agent = Agent.fromConfig(config);
      addTearDown(agent.dispose);

      final result = await agent.run();
      printOnFailure('Agent result: $result');

      // The run reached one of the terminal classifications.
      expect(
        result,
        anyOf(
          isA<AgentCallSucceeded>(),
          isA<AgentCallFailed>(),
          isA<AgentEscalationApproved>(),
          isA<AgentEscalationRejected>(),
          isA<AgentEscalationPending>(),
        ),
      );
    },
    // A rejected call escalates and the agent polls for the user's decision, so
    // the run can take up to (pollInterval x pollMaxAttempts). The framework's
    // default 30s timeout is shorter than that window and would kill the run
    // before a manual approval lands, so derive the timeout from the polling
    // bound plus a margin for the connect/simulate/submit round-trips.
    timeout: Timeout(
      config.pollInterval * config.pollMaxAttempts +
          const Duration(minutes: 1),
    ),
    skip: shouldRun
        ? null
        : 'Set AGENT_RUN_LIVE=true and supply a complete live config '
            '(smart account with the agent registered as a scoped signer, plus '
            'a running coordination server) to exercise the end-to-end run.',
  );
}
