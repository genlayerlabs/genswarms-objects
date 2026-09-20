import {readFile,writeFile} from 'node:fs/promises';
const root=new URL('../',import.meta.url);
const schema=JSON.parse(await readFile(new URL('schema.json',root),'utf8'));
const content=`---
name: genlayer-use
description: Use the shared GenLayer object for your own wallet, reads and permitted EVM transactions.
---

# GenLayer object protocol v${schema.version}

This skill teaches mechanics, not investment strategy. Keep your own strategy,
hypotheses and decision journal. Never put private decision notes in object requests.

## Discover before acting

Use the object name wired by your host (default: genlayer). Start with:

\`\`\`sh
swarm-msg ask genlayer '{"action":"describe"}'
\`\`\`

The engine wraps replies in its ask envelope. The object's initial result is
\`{"ok":true,"status":"accepted","request_id":"..."}\`: this means queued,
NOT successful and NOT a trade. The object subsequently messages you an envelope
with the same ID and either \`ok:true,result:...\` or \`ok:false,error:...\`.
To retrieve a missed result within the current object lifetime:

\`\`\`sh
swarm-msg ask genlayer '{"action":"result","request_id":"THE_OBJECT_REQUEST_ID"}'
\`\`\`

Wait/back off if unknown or pending; do not spin. The bounded result cache lasts
only for this object process. For money-moving work, durable prepared_id and
transaction status are the recovery mechanism across restarts.

Use only your actual discovered capabilities. A null wallet is unprovisioned;
write_enabled=false means read-only. Notify the operator when provisioning or
funding is missing. You cannot provision wallets, export keys or change permissions.
You do not send a wallet identity: the runtime's routed sender chooses your wallet.

## Actions (generated from schema.json)

${Object.entries(schema.actions).map(([name,a])=>`- **${name}** — ${a.description} Required: ${a.required.join(', ')||'none'}. Optional: ${a.optional.join(', ')||'none'}.`).join('\n')}

## Plan, prepare, submit, reconcile

1. Read balances and host-configured recipes with assets. This is NOT a complete
   token index. Read recipes expose contract views; writes are explicit host grants.
2. Obtain current quotes through configured read recipes where available. All
   amounts are integer base-unit strings; never infer decimals or use floats.
3. Choose an allowed write recipe. Supply exactly its declared fields. Limits,
   slippage/minimum output and recipient rules are host-defined, not overridable.
4. Prepare with a unique request_id for this economic decision. Reuse that ID for
   delivery retries of the SAME parameters. Save the returned prepared_id.
5. Review the concrete transaction and preview (simulation output, fees, amount,
   recipe arguments, expiry). A simulation is not a guarantee of execution.
6. Submit that prepared_id. Repeated submit returns its existing execution.
7. Query status until confirmed/reverted or an operator-recoverable unresolved
   state. Do NOT create another action to retry an uncertain transaction.
8. Re-read holdings after confirmation and adapt from actual outcomes and costs.
   Keep intended actions distinct from signed, broadcast and confirmed actions.

## Error recovery

- quote_expired: prepare anew with a new request_id; do not submit an expired ID.
- idempotency_conflict: you reused an ID with different inputs; inspect your journal.
- insufficient_balance / gas_cost_limit / amount_outside_limits: revise the plan.
- policy_changed / writes_disabled: rediscover capabilities; never evade limits.
- wallet_busy: query the existing pending execution from describe or balance.
- uncertain / signed / broadcast: track status; absence of a receipt is not failure.
- signing after a restart: operator reconciliation needed; do not duplicate it.
- rejected: no transaction was broadcast by this attempt; inspect error and revise.
- reverted: an included transaction failed and may have spent gas; inspect and learn.
- runtime_unavailable / request_timeout: outcome may be unknown; preserve IDs.

Confirmed here means an EVM receipt with the configured confirmation depth, not
GenLayer intelligent-contract finality. Version 0.1 supports intelligent reads,
not intelligent writes. Never describe unsupported operations as completed.
`;
if(process.argv.includes('--check')){
 if(await readFile(new URL('SKILL.md',root),'utf8')!==content)throw Error('skill/schema drift');
}else await writeFile(new URL('SKILL.md',root),content);
