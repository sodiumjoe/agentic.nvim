# Provider system

Generic ACP client: one `ACPClient` for every provider, no per-provider
adapters (ADR 0005). Provider quirks live in protected `ACPClient` methods.

Adding a provider is a config entry under `acp_providers` in
`lua/agentic/config_default.lua`. Runtime flow, lifecycle, and framing: skill
`agentic-acp-protocol-flow`.

## `__on_state_change` runs in a fast event

`ACPClient:_set_state` calls the protected `__on_state_change(old, new)` once
per real transition, a repeated state excluded, and BEFORE it fails pending
callbacks and ready listeners. A subclass marks its sessions unavailable there,
so their pending prompt callbacks see a dead attachment when they run with
`TRANSPORT_ERROR`.

`_set_state` runs in a libuv fast event on process exit, transport read errors
and the `initialize` reply. An override MUST NOT touch `vim.api`, `vim.fn`,
`vim.v` or `vim.o` there, not only `nvim_*` calls (see "Banned calls" in
`lua/agentic/AGENTS.md`): update Lua state synchronously and `vim.schedule` any
UI work.

The hook also fires during construction. `ACPClient.new` calls `_connect`,
which moves the client to `connecting`, `connected` and `initializing`, or to
`error` when the spawn fails, before `new` returns. A subclass constructor that
calls the parent `new` and then sets its own fields has not set them yet when
those calls arrive: the override must tolerate missing fields.

An override MUST NOT throw. `_set_state` calls it under `pcall` and reports a
failure with `Logger.notify`, so a throw no longer skips the drains and
strands pending callbacks, but the guard is a safety net, not a contract to
rely on.

Regressions:

- `lua/agentic/acp/acp_client.test.lua::"reports a repeated state once"`
- `lua/agentic/acp/acp_client.test.lua::"runs before pending callbacks are failed"`
- `lua/agentic/acp/acp_client.test.lua::"fails pending callbacks when the hook throws"`

## A release MUST pass the caller's handlers

`ACPClient:cancel_session(session_id, handlers)` releases only while `handlers`
are still `subscribers[session_id]`, and sends nothing when the id has no
subscriber. Several managers can subscribe one session id in turn, the last
write winning (`ACPClient:_subscribe`). A release without handlers drops
whatever is subscribed: a predecessor's teardown then silences its successor
and sends `session/cancel` for the successor's turn. Every teardown that owns a
subscriber passes it.

`SessionStartAttempt:_cancel_provider_session` can call `cancel_session` from a
late startup reply in a fast event, so `__request_params("session/cancel", ...)`
runs there too, and an override for that method falls under the fast-event ban
in `lua/agentic/AGENTS.md`, section "Banned calls".

`ACPClient:transfer_subscriber(session_id, from, to)` is the one handover:
it moves the id to `to` only while `from` owns it, and sends nothing. A rolled-back
reattach uses it to give the id back to the kept source before the target's
release runs (ADR 0008).

Regressions:

- `lua/agentic/acp/acp_client.test.lua::"keeps a subscriber the given handlers do not own"`
- `lua/agentic/acp/acp_client.test.lua::"sends nothing for handlers when the id has no subscriber"`
- `lua/agentic/session_manager.test.lua::"keeps the successor subscribed when a predecessor on its session id is destroyed"`
- `lua/agentic/acp/acp_client.test.lua::"moves the subscriber only while the giver owns it"`
- `lua/agentic/session_registry.test.lua::"hands the session back to the source when the commit rolls back"`

## Protocol contracts

- `set_config_option(session_id, config_id, ...)` takes `ConfigOption.id`,
  never the category string (`"mode"`, `"model"`). `id` and `category` are
  different fields.
- The `session/request_permission` response is double-nested on purpose, per
  the ACP spec: `{ outcome = { outcome = "selected", optionId = ... } }`.
- Sessions live only with the provider, listed via `session/list`. Local session
  persistence was removed in PR #169; do not add a disk cache fallback.
- The raw-input diff fallback reads `replace_all` (snake_case) only. No known
  provider sends `replaceAll`.

## A request handler MUST always answer; a notification handler need not

`ACPClient:_handle_notification` dispatches two shapes of inbound JSON-RPC
message, and they carry opposite obligations:

- A **notification** (`session/update`) has no `id`. Nothing is waiting on it, so
  dropping it when the subscriber is gone is correct.
- A **request** (`session/request_permission`) has an `id`. The provider blocks
  until that `id` is answered, and the subprocess is **shared across every
  session** (ADR 0004), so one unanswered request hangs the agent for all of them.
  Every exit path owes a `__send_result`.

`ACPClient:__with_subscriber` therefore takes an `on_missing` callback:

```lua
--- @param on_missing fun()|nil Runs when no subscriber answers
function ACPClient:__with_subscriber(session_id, callback, on_missing)
```

It fires on **both** misses — the synchronous one (no subscriber when the message
arrives) and the deferred one (the subscriber was dropped while the `vim.schedule`
body sat in the queue). The subscriber is re-resolved **inside** the schedule for
exactly that reason; `cancel_session` nils it mid-flight.

Only `__handle_request_permission` passes `on_missing`, answering
`{ outcome = "cancelled" }`. The three notification call sites pass nothing and
keep returning silently.

Regression:
`lua/agentic/acp/acp_client.test.lua::"answers cancelled when the subscriber is gone"`.

### The dispatch body MUST answer even when it throws

A missing subscriber is not the only way to strand the `id`. The pre-dispatch
type guard in `__handle_request_permission` only validates the payload's **top
level**; everything below it runs unchecked inside the `vim.schedule` body, where
three reachable throws left the `id` unanswered:

- `subscriber.on_request_permission` throws (a UI defect)
- `subscriber.on_tool_call_update` throws (same)
- `__build_tool_call_message` throws on a payload the type guard accepts.
  `update.content` is type-checked but its **elements** are not, so
  `toolCall = { toolCallId = "t1", content = { 5 } }` indexes a number.

`vim.schedule` swallows the error, so the transport read loop survives — which is
why this failed silently rather than crashing. The shared subprocess (ADR 0004)
just waits, and every session hangs with it.

The dispatch body is therefore wrapped in a `pcall` that answers
`{ outcome = "cancelled" }` on failure. Two rules govern it:

- It MUST `Logger.notify` the error, **including when `answer` is already a
  no-op**. A silent cancel hides genuine UI bugs in `on_request_permission`
  behind a permission prompt that merely "didn't appear".
- `answer` MUST be idempotent. The subscriber can invoke its callback and _then_
  throw; the `id` is already answered at that point, and a second `__send_result`
  on one `id` is a protocol violation. The guard's cancel is a no-op once
  answered, so a real `selected` outcome is never overwritten.

Do NOT harden `__build_tool_call_message` instead. One guard at the dispatch
boundary closes all three variants; hardening the builder is a larger diff for
the same bug and still would not cover a throwing subscriber callback.

Regressions:

- `lua/agentic/acp/acp_client.test.lua::"answers cancelled when on_request_permission throws"`
- `lua/agentic/acp/acp_client.test.lua::"answers cancelled when on_tool_call_update throws"`
- `lua/agentic/acp/acp_client.test.lua::"answers cancelled when the nested tool call content is malformed"`
- `lua/agentic/acp/acp_client.test.lua::"answers once when the handler answers and then throws"`

### Permission state is per-`id`, never shared

An agent can leave several `session/request_permission` requests outstanding at
once, and the user may answer them in any order — or never answer some. The
`PermissionManager` keys `pending` by `tool_call_id` and supports out-of-order
`resolve`, so the ACP layer must match it.

`answered` and `answer` are therefore **locals of each
`__handle_request_permission` invocation**, closing over that invocation's
`message_id`. Hoisting either onto `self` (or any module-level table) crosses the
wires: a shared `answered` swallows the second answer, and a shared `message_id`
pairs one request's `optionId` with another's `id`.

Each outstanding request also owns its failures. A throw in one dispatch cancels
only that `id`, and a subscriber dropped between two dispatches cancels only the
one still queued — the sibling holding a live `answer` closure resolves normally.

`PermissionManager:clear()` fires **every** pending callback with `nil`, so all
outstanding `id`s answer `cancelled`. That is correct on teardown: each `answer`
is a distinct closure, so the manager's fan-out maps one-to-one onto the
outstanding requests with no double-send.

Regressions in
`lua/agentic/acp/acp_client.test.lua::"__handle_request_permission concurrency"`,
notably `"answers two outstanding requests in reverse order"`.
