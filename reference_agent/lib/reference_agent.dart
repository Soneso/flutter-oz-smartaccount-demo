// Copyright 2026 Soneso. Reference agent for the OZ smart-account demo.
//
// Autonomous reference agent: connects to an existing OpenZeppelin smart
// account headlessly, signs a scoped contract call as an Ed25519 external
// signer through the verifier-contract path, classifies the on-chain outcome,
// and escalates policy rejections to the coordination server, then polls for
// the user's resolution.
library;

export 'src/agent.dart';
export 'src/agent_config.dart';
export 'src/agent_ed25519_signer_adapter.dart';
export 'src/agent_runner.dart';
export 'src/coordination_client.dart';
export 'src/outcome.dart';
