# AGENTS-MATTER.md — FHEM Matter integration rules

**Mandatory companion to [AGENTS.md](AGENTS.md).** Read both documents before any implementation, documentation, review, issue, or PR task. This file adds Matter-specific context; reusable FHEM engineering rules belong only in the central source. The repository's active branch and actual code take precedence over historical descriptions of its behavior.

## Project identity and boundaries

- Repository: `Flachzange/fhem-matter-fork`; upstream project: `zeppelin1979/fhem-matter` on GitLab. This is a fork, not a separate Matter server implementation. Keep upstream and fork changes identifiable; do not push to upstream or merge/release without explicit maintainer approval.
- Module sources: `FHEM/97_MATTER.pm` (FHEM `MATTER` IO device) and `FHEM/97_MATTERDevice.pm` (logical `MATTERDevice` node/endpoint devices). Preserve the `MATTER_` and `MATTERDevice_` callback namespaces and FHEM module registration.
- The IO module communicates with a separate Matter controller/server over a WebSocket/JSON API (typically port 5580); it is **not** itself an OpenThread Border Router, Matter controller implementation, or BLE commissioner. Confirm API operations against the actual server/version (especially matter.js versus python-matter-server) rather than treating the README's compatibility claims as proof.
- Preserve the existing FHEM update layout: `controls_matter.txt` and `make_controls.sh`; inspect the generated content and release/install paths when touching distribution. Do not change version metadata for documentation-only work. The upstream `LICENSE` is MIT; preserve attribution and license.
- Review the exact target branch before editing. `main` and topic branches can contain different behavior; never assume a fix in an unmerged branch is present on `main`. Separate unrelated fixes into focused branches/PRs.

## WebSocket transport and request lifecycle

- Trace `MATTER_Open`, `MATTER_Close`, `MATTER_Read`, `MATTER_SendWebSocketText`, `MATTER_SendJsonCommand`, `MATTER_ParseMessage`, the `%selectlist` registration, and all involved FHEM timers together before changing connection behavior.
- Treat the WebSocket TCP stream as partial and coalesced data: verify incremental HTTP upgrade handling, RFC 6455 frame lengths (including 64-bit lengths), masking, ping/pong, close, and any fragmentation and size limits against the actual code. Never assume a `sysread` or `syswrite` transfers a complete frame. Do not add unbounded buffering or block the FHEM event loop.
- A successful TCP connection is not a completed WebSocket handshake; an accepted command send is not a confirmed device state. Only publish connection/state/command results supported by a matching server response or device telemetry.
- Keep socket, `FD`, `BUF`, `websocket`, `ws_status`, `%selectlist`, timers, and pending requests consistent across connect failure, disconnect, reconnect, disable, undefine, FHEM restart, and server restart. Avoid duplicate reconnect timers and stale correlation IDs. Evaluate actual timeout/cancellation behavior before introducing more retry machinery.
- Keep `message_id` correlation for `get_nodes`, `read_attribute`/`getConfig`, commissioning, and credential operations unambiguous. Handle mismatched, unsolicited, failed, or late responses without silently treating them as successful. Distinguish WebSocket transport delivery, server command responses, and Matter device reachability.
- Wi-Fi/Thread credentials and commissioning data are sensitive. Never log plaintext passwords, keys, setup codes, or full credential-bearing JSON; use sanitized examples in tests and PRs. Authentication and network trust assumptions must be documented, not inferred from LAN-only usage.

## Device model, discovery, and FHEM ownership

- The Matter server owns its nodes and Matter fabric. The FHEM IO device owns the connection and dispatch; a root `MATTERDevice` represents endpoint 0, and endpoint children represent additional endpoints. Do not conflate node IDs, endpoint IDs, FHEM names, server labels, and stable device identity.
- Current routing uses `$modules{MATTERDevice}{defptr}` keyed by IO name and node ID for root nodes, plus per-root endpoint references. Check this exact routing path, including multiple IO devices and stale references, before changing discovery, rebind, rename, or deletion behavior. Preserve user-defined device names, FUUIDs, readings, and attributes wherever possible.
- `get_nodes` discovery and live `attribute_updated` events have different payload shapes and ordering. Validate `node_id`, endpoint/cluster/attribute paths, payload types, and the intended IO before routing or autocreating. An unknown node/event is not a reason to create or overwrite an unrelated existing FHEM device.
- Keep autocreate collision handling and endpoint ownership explicit. Do not assume that the name derived from a remote node label is unique. When adding a room default, only set `room Matter` for **newly created** devices; do not override a manually chosen room. This is a desired enhancement, not a claim that the current module implements it.
- Coordinated naming of all endpoints after renaming a root is a **proposed feature**, not existing guaranteed behavior. Before implementing it, define a stable root/endpoint naming contract and decide how manually renamed endpoints are protected. Do not rename unrelated devices by prefix alone.

## Capabilities, commands, readings

- `97_MATTERDevice.pm` maps Matter cluster/attribute/command IDs to FHEM readings and `set` capabilities. Verify ID, datatype, unit, scaling, feature-map and command support from the relevant Matter specification and actual server data; distinguish supported, advertised, implemented, and hardware-tested behavior.
- Existing `has_*`, `max_*`, and `color_temp_*` attributes influence exposed controls. Respect explicit user overrides and keep discovery/getConfig behavior coherent; do not infer unsupported commands from one observed attribute. Check dynamic set lists after a capability change or reconnect.
- Preserve endpoint-specific values and update semantics. Never publish a command as confirmed hardware state without readback/event evidence. Do not collapse unknown, null, unsupported, stale, or unreachable status into `0`, `off`, or success.
- Treat pending reads, live updates, discovery snapshots, and node availability as separate sources of evidence. Reconcile event order and freshness deliberately rather than overwriting newer readings with late responses.
- Do not silently add mandatory support for device classes or clusters merely because the Matter specification defines them. Extend mappings with focused tests and verified device/server evidence.

## Tests, review, and deployment

- Inspect actual tests and workflows on the branch; the currently inspected `main` has no established Perl test suite. Do not invent an existing test command or claim live coverage from syntax checks. Add focused regression tests for any behavior changed, with faithful FHEM callback and WebSocket framing/correlation behavior.
- For transport changes cover split/coalesced frames, extended payload lengths, malformed/oversized frames, EOF, reconnect, delayed responses and timer/FD cleanup. For model changes cover duplicate discovery, multiple nodes/IO devices, endpoint routing, collisions, manual renames, attribute changes, and backward compatibility. Scope tests to the change; avoid speculative scaffolding.
- Validate Perl syntax with the actual FHEM dependencies available, and document dependency gaps if a standalone `perl -c` cannot load the module. Verify on a real FHEM + Matter server only when feasible, and state which integration/hardware paths remain untested.
- Keep PRs narrow: provide observed problem, source evidence, changed paths, tests run/not run, and compatibility risk. Do a second review of both modules and their interaction after modifications. Avoid changing Matter server or Thread Border Router repositories as part of a FHEM module fix without separate explicit authorization.

## Shared rules management

- Keep `AGENTS.md` byte-identical to the accepted central `Flachzange/FHEM_Agent_Rules` revision in `.github/agent-rules.json`. Never edit generic rules locally.
- Put Matter-specific decisions here. Propose genuinely reusable FHEM lessons in the central repository through a separate authorized review/PR; adoption remains manual through the central distribution draft PRs.
- The `.github/workflows/agent-rules.yml` check validates central source provenance and this supplement. A successful documentation check is not evidence of Matter runtime correctness.
