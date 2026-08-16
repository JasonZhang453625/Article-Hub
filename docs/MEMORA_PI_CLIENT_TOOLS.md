# Memora Pi device-client tools (protocol v3)

This document records the exact client-side contract. The backend harness
document remains authoritative for the complete Pi loop and provider prompts.

## Exact client prompt

The Flutter asset `assets/prompts/chat/agent_system.txt` is sent only for a
hosted, attachment-free protocol-v3 run. At runtime it substitutes:

- `knowledgeMode`: exactly `only` or `hybrid`;
- `lengthRule`: the existing concise/detailed prompt asset;
- `webRule`: the explicit per-chat web-search permission;
- `langHint`: the configured answer-language instruction.

The backend appends its device-tool policy and owns the tool schemas. Attachment
runs never enable `local_knowledge`; BYOK continues to use the legacy local RAG
path.

## Privacy and ownership

The Memora article vault is device-local, not account-partitioned. A newly
signed-in account on the same device may deliberately start a new run against
that device vault. An existing run, opaque article reference, or receipt is
bound to the immutable `(ownerUserId, ownerDeviceId, runId)` tuple, so account
or device switching cannot take over earlier work.

Only whitelisted memory evidence is returned to Pi. The client never returns
the real article id, URL, notes, local path, tags, or attachment metadata.
`article_ref` is random and run-scoped; it is removed before chat history, UI,
or retrieval logs are persisted. A terminal answer maps validated `[n]`
citations back to still-existing local article ids and then deletes the run's
reference and receipt records.

Logout and account switching suspend execution and close active transports;
they do not cancel the server run or destroy a ready receipt. Stop and chat
deletion revoke local execution immediately, while the existing durable chat
cancellation/tombstone flow remains the single owner of backend cancellation.

## Recovery invariant

REST pending/claim/call-status/result endpoints are the source of truth. The
app-global host consumes `client_tool.pending` SSE events only as payload-free
wake signals and immediately fetches authoritative REST pending. It also polls
REST every 800 ms, so a lost SSE event, closed ChatScreen, or process recovery
still makes progress. Before a
claim request the client persists a random
`claimRequestKey`. Before PUT it persists the strict result and a random
`resultReceiptKey`. Lost responses and process restarts therefore replay the
same key and payload. The host validates its auth user/device generation
before and after every asynchronous boundary and runs at most two calls in
parallel globally. A same-owner access-token refresh stays inside that
generation so the transport can replay the exact durable idempotency key and
payload; another user or device is fenced before replay.

If a durable receipt is absent from `pending`, the host queries its exact
token-free call status. `completed` acknowledges only the receipt and keeps
run-scoped article references for final citation resolution; `pending`
authorizes a new claim/result key; `claimed` replays only an existing local
token/result for the same lease epoch; `cancelled` and `expired` never execute.

The error-code policy is intentionally narrow:

- `client_tool_lease_expired` and `client_tool_fenced` preserve the durable
  result and wait for an explicit `pending` transition before reclaim;
- `client_tool_claim_key_expired` rotates the key only after this exact call
  was already observed `pending`;
- `client_tool_result_token_limit_exceeded`,
  `client_tool_result_too_large`, `invalid_client_tool_result`,
  `client_tool_result_budget_exceeded`, and `IDEMPOTENCY_CONFLICT` quarantine
  the receipt and never hot-replay it.
