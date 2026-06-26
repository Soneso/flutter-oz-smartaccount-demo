# Smart account demo: agent-shaped delegation

This document explains how the demo's "Delegate to agent" screen (step 2 of the
agent-signer flow) hands an autonomous agent a narrow, revocable authority on a
smart account. It is a worked example of one `addContextRule` call that
combines four constraints. The same composition lives in
`lib/flows/delegate_to_agent_flow.dart`.

## Agent-shaped delegation

An agent runs unattended, so the authority it holds must be scoped, capped, and
time-bounded. A single context rule expresses all three: it scopes the agent to
one token, caps how much it may move, and expires on its own.

The agent owns its Ed25519 secret. It never leaves the agent process. Only the
agent's **public key** is shared with the wallet, as a Stellar `G...` address
(StrKey, checksummed). The reference agent prints it on startup:

```
[agent] [INFO] Agent public key (paste into Delegate-to-agent): GA7QYNF7SOWQ3GLR2BGMZEHXAVIRZA4KVWLTJJFF36LPGADB4QLE3VG
```

The wallet pastes that `G...` value, decodes it to the raw 32-byte Ed25519 key
the verifier contract expects, and registers it as an external signer:

```dart
// G-address -> raw 32-byte Ed25519 public key.
final agentKey = KeyPair.fromAccountId(agentGAddress).publicKey;

// Cap (decimal string) -> base units at the token's scale (DEMO uses 7).
final cap = OZTransactionOperations.amountToBaseUnits('100', decimals: 7);

// validUntil: an absolute ledger, ~24h from the current one.
final current = (await sorobanServer.getLatestLedger()).sequence!;
final validUntil = current + Util.ledgersPerDay;

await kit.contextRuleManager.addContextRule(
  // 1. Scope — match only calls to the one token the agent may touch.
  contextType: OZContextRuleTypeCallContract(
    'CDLZFC3SYJYDZT7K67VZ75HPJVIEUVNIXF47ZG2FB2RMQQVU2HHGCYSC',
  ),
  name: 'Agent',

  // 4. Expiry — the rule stops applying after this ledger.
  validUntil: validUntil,

  // 2. Signer — the agent's Ed25519 key, verified through the Ed25519
  //    verifier contract. This is an EXTERNAL signer, not a delegated one.
  signers: [
    OZExternalSigner.ed25519(
      verifierAddress:
          'CAW2Z46INPO5VIJEILMYSSEOLBVJIIII5GOE3TN5EUURSRM2FJCF7AJ6',
      publicKey: agentKey, // raw 32 bytes
    ),
  ],

  // 3. Policy — a spending-limit cap over a rolling ledger window.
  policies: {
    'CBQE7L3UNP5IR4I7IBKLS7NV256WHR5TTH26HTMUIK7WXJC6J64RSE2L':
        OZSpendingLimitPolicyParams(
      spendingLimit: cap,
      periodLedgers: Util.ledgersPerDay,
    ),
  },

  // Submitted by the connected passkey — single-signer path.
  selectedSigners: const [],
);
```

### The four parts

1. **Scope — `OZContextRuleTypeCallContract(token)`.** The rule only matches
   invocations of this one token contract. The agent cannot use it to authorize
   calls to any other contract. Here the token is the testnet XLM Stellar Asset
   Contract; the demo screen defaults the field to the DEMO token instead.

2. **Signer — `OZExternalSigner.ed25519(verifierAddress, publicKey)`.** The
   agent is an *external* Ed25519 signer: signatures are verified on-chain by
   the Ed25519 verifier contract
   `CAW2Z46INPO5VIJEILMYSSEOLBVJIIII5GOE3TN5EUURSRM2FJCF7AJ6`. `publicKey` is
   the raw 32-byte key decoded from the agent's `G...` address. This is
   deliberately not `OZDelegatedSigner`: a delegated signer is a Stellar
   account that authorizes natively, whereas the agent authorizes through the
   verifier-contract path the SDK's multi-signer pipeline drives.

3. **Policy — `OZSpendingLimitPolicyParams`.** The spending-limit policy
   contract `CBQE7L3UNP5IR4I7IBKLS7NV256WHR5TTH26HTMUIK7WXJC6J64RSE2L` caps the
   total the agent may move to `spendingLimit` base units over each rolling
   `periodLedgers` window. `spendingLimit` is the cap converted to base units
   at the token's decimal scale (`OZTransactionOperations.amountToBaseUnits`).

4. **Expiry — `validUntil`.** An absolute ledger sequence past which the rule
   no longer applies. Computed from the current ledger plus an offset
   (`Util.ledgersPerDay` for ~24h), so the delegation lapses on its own even if
   the user never revokes it.

Together these mean: the agent can sign transfers of this one token, up to the
spending cap per period, until the rule expires — and nothing else.

The agent then connects headlessly and submits its scoped call as an
`OZSelectedSignerEd25519` against the same `(verifierAddress, publicKey)` slot.
See `reference_agent/` for that side of the flow.
