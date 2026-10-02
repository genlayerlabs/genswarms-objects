# GenLayer wallet object — 0.1.0 experimental

One native GenSwarms object, one bundled Node runtime, one independent encrypted
wallet per configured sender. No MetaMask login or wallet-provider API credential.
Requires Node >=24 and a GenSwarms host with Jason. Runtime JS dependencies are
bundled; consumers do not run npm install. Operator-managed hot custody, testnet
only (chain 4221). This is not a production security certification.

## What ships

- Native `Genswarms.GenLayer` handler and `swarm-object.json` loader entry.
- `schema.json` action reference, generated agent `SKILL.md`, input validation.
- Pinned GenLayerJS 1.1.8 + viem 2.56.8 bundled into `runtime.mjs` (~1.1 MB).
- Encrypted independent keys, SQLite wallet bindings/proposals/execution journal.
- Live capability discovery, native balances, configured EVM/intelligent reads,
  configured EVM writes via prepare → submit → status.
- Expiring sender-bound preparations, simulation and gas preview, operation
  permissions defined by host recipes, idempotency, pending nonce allocation,
  canonical receipt/depth checks, restart-safe uncertain transaction tracking.

No GenSwap deployment addresses or assumed ABIs are embedded. The host supplies
verified read/write recipes for its contracts. `assets` lists configured recipes,
not every token on GenSwap. This version does not submit intelligent-contract
writes, provide arbitrary raw signing, automatically rebroadcast or replace
transactions, export keys to agents, or promise market profitability.

## Install and configure

Resolve `swarmidx:genlayerlabs/genlayer@0.1.0` through your host's normal package
loader. The package manifest describes `kind: handler`. Alternatively, load
`genlayer.ex` from an intact package directory using `Code.require_file/1`.

1. Copy `example.json` OUTSIDE the package into an operator-owned directory.
   Set stable swarm_id, agents, private storage_dir and master_key_file paths.
2. Run `node /package/path/scripts/setup.mjs /path/operator-config.json` on the
   trusted host. It exclusively creates a 32-byte master key if absent, creates
   independent wallets and prints public addresses only. Existing wallets persist.
3. Back up the encrypted storage and master key separately. Validate restoration
   before funding. Never mount either path into agent containers. Stop the runtime
   before copying SQLite files, or use a proper SQLite online backup; copying a
   live database without its WAL is not a backup procedure.
4. Attach the bundled skill to each authorized agent and wire both topology edges.
5. Discover/read first. Fund with testnet GEN only; writes remain off until enabled
   with explicit recipes, per-action value and fee ceilings and a gas reserve.

Example host fragment (merge into your swarm definition):

```elixir
config = File.read!("/operator/path/genlayer.json") |> Jason.decode!()
%{
  objects: [%{name: :genlayer, handler: Genswarms.GenLayer, config: config}],
  # In the existing alice/bob definitions:
  # skills: ["/package/path/SKILL.md", ...personality_skills]
  topology: [
    {:alice, :genlayer}, {:genlayer, :alice},
    {:bob, :genlayer}, {:genlayer, :bob}
  ]
}
```

The package's skill field makes its usage guide discoverable in SwarmIDX; installing
an object does not automatically add skills to existing agents. `interface/0`
provides introspection, not authorization or automatic LLM tool registration.

## Host recipes

`recipes` is immutable host configuration, never agent-controlled input. A recipe
has mode `read` or `write`, address, ABI, function, args, and declared input fields.
Each argument is a literal or `{ "field": "amount" }`. Fields accept bounded
`uint` base-unit strings, `address` with an explicit allowed list, or `enum`.
Every declared field is required; unknown fields fail. Literals can include fixed
arrays (for example, a swap path). Native transfer recipes use kind `native`, a
fixed recipient, and value. Intelligent read recipes use kind `intelligent`.

Example native test transfer recipe:

```json
{
  "pay_test_recipient": {
    "kind": "native", "mode": "write",
    "address": "0x0000000000000000000000000000000000000123",
    "value": {"field": "amount"},
    "fields": {"amount": {"type":"uint", "min":"1", "max":"1000"}}
  }
}
```

Do not use that example address for actual funding. For ERC-20 approvals, the
recipe must fix the spender and bound the allowance field. For swaps, fix the
router/path/recipient and bound input, minimum output and deadline appropriately.
A recipe is authority to call that contract, not a generic security scanner.
Fee/value ceilings are per operation, not a rolling daily token budget. Only
configure contracts/operations whose complete effects you intend to authorize.

## Messaging and recovery

`swarm-msg ask genlayer '{"action":"describe"}'` immediately returns an object
request ID in an accepted response. Work completes asynchronously as a routed
message to the originating sender. `result` retrieves missed replies from a
bounded process-local cache. Both topology directions are necessary.

The object stays responsive while its Node process performs RPC requests. Maximum
64 pending object requests; completed reply cache 256. Responses/errors never
contain raw keys, unlocking secrets or signed transaction bytes. Keep object config
and logs operator-only; transaction previews are private to their sender.

Three identifiers have different lifetimes:
- object request ID: delivery correlation, process-local result cache;
- prepare request_id: caller idempotency key, permanent in the wallet journal;
- prepared_id: durable action/execution identity, used by submit and status.

One unresolved transaction per wallet. Signed bytes/hash are persisted BEFORE
broadcast. Timeout means uncertain, not failed. After restart, submit of the same
prepared_id returns its stored status; `status` queries receipts without sending.
Different wallets can progress independently. A pre-sign crash leaves `signing`
blocked for operator recovery; never delete the journal to free a nonce. No dropped
transaction resolver or automatic replacement exists in 0.1.0. Stop, inspect signed
bytes/hash and on-chain nonce history before any manual recovery.

`confirmed` means the EVM receipt is in its canonical block and meets configured
confirmation depth. It is not GenLayer intelligent-contract finality. Once marked
confirmed, deeper reorg correction is not implemented. Re-read balances after
confirmation; a decision or broadcast alone is not a portfolio change.

## Custody and operating boundary

The host maps routed sender + configured stable swarm_id + chain to a wallet key.
Reusing a swarm_id intentionally shares bindings; use unique IDs across swarms.
No wallet selector is accepted in agent requests. Enforce engine API authentication
and isolated agent filesystem/network access: topology alone is not an OS sandbox.
The signer subprocess shares host custody; it is not a hardware enclave. Master
key compromise affects all wallets. JavaScript may retain private-key copies in
memory; buffer clearing is best effort. Key files are AES-GCM authenticated to
identity, atomically created, and 0600; storage/master permissions fail closed.
No keys or runtime databases belong in package/config snapshots or Git.

## Validation

```sh
npm ci --prefix packages/genlayer --ignore-scripts
npm test --prefix packages/genlayer
GENLAYER_EVM_TEST=1 npm test --prefix packages/genlayer # requires anvil
npm run build --prefix packages/genlayer
node packages/genlayer/scripts/skill.mjs --check
mix run checks/genlayer_test.exs
# In a GenSwarms host (not this library-only repo):
mix run --no-start /path/packages/genlayer/test/engine.exs
```

Tests cover 20 wallet identities, restoration, tampering, sender boundaries,
expiry, policy drift, duplicate requests, wrong chain, insufficient balance,
uncertain-broadcast restart recovery, and real local-EVM transfers/contract writes.
The engine probe traverses actual Router → ObjectServer → bundled runtime → reply.
The probe uses a deterministic sink, not an LLM; no model-comprehension claim is made.
No funded Bradbury trade or GenSwap buy/sell/token launch has been verified by this
release. Runtime source and generated bundle ship together; CI checks reproducibility.
