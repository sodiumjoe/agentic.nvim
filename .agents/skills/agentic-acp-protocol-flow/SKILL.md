---
name: agentic-acp-protocol-flow
description: >
  Rules for the ACP client, transport, and provider flow. Use before editing
  ACPClient, ACPTransport, AgentInstance, ACP provider flow, tool-call parsing,
  permission requests, provider switch, reconnect, or ACP subprocess lifecycle.
---

# Agentic ACP Protocol Flow

Use this skill for ACP runtime behavior. For schema facts, also load
`agentic-acp-docs-and-schema`.

## Provider model

- External ACP CLI tools are spawned as subprocesses.
- The plugin does not install providers.
- All providers use the generic `ACPClient` in `acp_client.lua`.
- There are no per-provider adapter files. See ADR 0005.
- Add a provider with a `config_default.lua` entry under `acp_providers` unless
  the provider deviates from ACP in a new way.
- Provider quirks live in protected `ACPClient` methods, not adapter files.

## Pipeline

Read in this order. Each step calls the next:

1. `lua/agentic/acp/acp_transport.lua` - stdout reader, line framing, calls
   `callbacks.on_message`
2. `ACPClient:_handle_message` - response vs request vs notification
3. `ACPClient:_handle_notification`, then `ACPClient:__handle_session_update`
4. `SessionManager:_build_handlers` - the subscriber; `_on_session_update`
5. `MessageWriter`, `PermissionManager`, `TodoList`, `ChatHistory` - render

## Load references by edit target

- `references/client-lifecycle.md`: `ACPClient.state`, ready listeners, sync vs
  async dispatch, reconnect, pending callback draining.
- `references/transport-framing.md`: stdio line framing, partial chunks,
  subprocess process-group termination.
- `references/tool-calls-permissions.md`: `session/update` routing, tool-call
  lifecycle, permission request normalization, provider quirks.
- `references/provider-switch-options.md`: provider switch replay, modes/models,
  thought level, config options.

## Protected methods

Current extension points:

| Method                        | Behavior                                                                                                                                                                                                                                                                                                  |
| ----------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `__handle_tool_call`          | Builds ToolCallBlock, notifies subscriber                                                                                                                                                                                                                                                                 |
| `__build_tool_call_message`   | Parses ACP fields and quirk fallbacks                                                                                                                                                                                                                                                                     |
| `__handle_tool_call_update`   | Builds partial, notifies subscriber                                                                                                                                                                                                                                                                       |
| `__handle_request_permission` | Sends permission result to provider                                                                                                                                                                                                                                                                       |
| `__handle_session_update`     | Routes by `sessionUpdate` type                                                                                                                                                                                                                                                                            |
| `__handle_unknown_method`     | Answers or ignores an unrecognized method; subclasses receive `(message_id, method, params)` and may override it to handle vendor extensions                                                                                                                                                              |
| `__request_params`            | Lets a subclass decorate outgoing session/new, session/load, session/prompt and session/cancel params (e.g. `_meta`); main loop, except `cancel_session` from a late startup reply in a fast event, so no `vim.api`, `vim.fn`, `vim.v` or `vim.o` access for session/cancel                               |
| `__on_state_change`           | Receives `(old, new)` on each real state transition, before pending callbacks and ready listeners are drained; also fires during `ACPClient.new`; may run in a fast event, so no `vim.api`, `vim.fn`, `vim.v` or `vim.o` access; must not throw (pcall-guarded): update Lua state, `vim.schedule` UI work |

Only subclass or extend these when a real provider deviation requires it.

Public methods that hand a session id between subscribers, `cancel_session` and
`transfer_subscriber`, carry an ownership contract documented in
`lua/agentic/acp/AGENTS.md`, section "A release MUST pass the caller's handlers".

## Provider quirks

Handle protocol deviations inline in `__build_tool_call_message`.

- OpenCode `rawInput` fallback builds diffs when `content` is missing for edit
  tool calls.
- `locations` fallback extracts `file_path` from `update.locations[0].path`.
- Unknown tool kinds log a warning so users can report the provider behavior.
