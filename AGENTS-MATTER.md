# AGENTS-MATTER.md — FHEM Matter integration rules

**Mandatory companion to [AGENTS.md](AGENTS.md).** Read both documents before any implementation, documentation, review, issue, or PR task. This file adds Matter-specific context; reusable FHEM engineering rules belong only in the central source. The repository's active branch and actual code take precedence over historical descriptions of its behavior.

## Project identity and boundaries

- Repository: `Flachzange/fhem-matter-fork`; upstream project: `zeppelin1979/fhem-matter` on GitLab. This is a fork, not a separate Matter server implementation. Keep upstream and fork changes identifiable; do not push to upstream or merge/release without explicit maintainer approval.
- Module sources: `FHEM/97_MATTER.pm` (FHEM `MATTER` IO device) and `FHEM/97_MATTERDevice.pm` (logical `MATTERDevice` node/endpoint devices). Preserve the `MATTER_` and `MATTERDevice_` callback namespaces and FHEM module registration.
- The IO module communicates with a separate Matter controller/server over a WebSocket/JSON API (typically port 5580); it is **not** itself an OpenThread Border Router, Matter controller implementation, or BLE commissioner. Confirm API operations against the actual server/version (especially matter.js versus python-matter-server) rather than treating the README's compatibility claims as proof.
- **Deliberately lean client scope:** This project only integrates an externally operated Matter server with FHEM. It maps device/endpoint identities, reported attributes, Matter events and everyday standard Matter commands into idiomatic FHEM readings and controls. The Matter server remains the authority for the fabric, commissioning infrastructure, OTBR, bridge functionality, server lifecycle and administrative operations. Do not implement a server installer, expose FHEM devices as a Matter bridge, or create a general-purpose Matter administration UI.
- **Explicitly limited client conveniences:** Existing IO commissioning support stays intact; targeted OTA update discovery and installation using the external server's existing API (never firmware uploads), device Identify, native LevelControl dim commands and opt-in network diagnostics are within scope. Add no framework, server-specific background polling, universal write/command console, or parallel firmware manager merely to expose all API operations.
- **Prioritize device use over completeness:** Cover common Matter sensors and events, and standard device classes with clear FHEM semantics. Keep optional device-specific or diagnostic capabilities separate and narrow. Automatic FHEMWEB icons are explicitly out of scope.
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
- Keep autocreate collision handling and endpoint ownership explicit. Do not assume that the name derived from a remote node label is unique. When adding a room default, only set `room Matter` for **newly created** devices; do not override a manually chosen room. New autocreated roots and endpoints already default to room `Matter`; this is implemented, not a pending enhancement.
- Coordinated naming of all endpoints after renaming a root is a **proposed feature**, not existing guaranteed behavior. Before implementing it, define a stable root/endpoint naming contract and decide how manually renamed endpoints are protected. Do not rename unrelated devices by prefix alone.

## Capabilities, commands, readings

- `97_MATTERDevice.pm` maps Matter cluster/attribute/command IDs to FHEM readings and `set` capabilities. Verify ID, datatype, unit, scaling, feature-map and command support from the relevant Matter specification and actual server data; distinguish supported, advertised, implemented, and hardware-tested behavior.
- Device command availability relies exclusively on the per-endpoint Matter `AcceptedCommandList` plus applicable `FeatureMap` / `ClusterRevision` conditions. Do not restore retired `has_*` capability attributes, overrides or fallback permission logic. Saved old `has_*` entries are inert in module logic and must not be deleted automatically. Document manual cleanup **before a restart** because removed AttrList entries can be rejected when FHEM restores the old configuration. Preserve supported `max_*` and `color_temp_*` bounds as separate user settings, never as evidence of command support. Keep discovery/getConfig, reconnect and dynamic set lists coherent; do not infer commands from one observed value.
- Preserve endpoint-specific values and update semantics. Never publish a command as confirmed hardware state without readback/event evidence. Do not collapse unknown, null, unsupported, stale, or unreachable status into `0`, `off`, or success.
- Root nodes expose a native `state` reading (`online`/`offline` only for valid node-wide `available` reports; `unknown` for missing fresh reachability or IO loss; `removed` for confirmed absence from the server's node list). Keep raw `available` readings unchanged on disconnect and never modify endpoints' physical `state`. Do not auto-create `stateFormat`; respect user overrides. Migrate the V0.15 `stateFormat available` default only after config/statefile restoration (`INITIALIZED`/`REREADCFG`), using an explicit legacy predicate, and test startup, reconnect, multiple IO devices, event order, and migration.
- Treat pending reads, live updates, discovery snapshots, and node availability as separate sources of evidence. Reconcile event order and freshness deliberately rather than overwriting newer readings with late responses. In offline quarantine, keep cached device-state snapshots blocked; on a validated transition back online, make at most one event-driven, global-Matter-metadata-only `read_attribute` request per recovery epoch to restore endpoint commands. A matched `getConfig` read while online may restore only metadata during quarantine, never cached states. Reject reads while offline and discard replies from earlier availability epochs, replaced roots, or old IO connections. The server's current metadata is not proof of a fresh physical device interview; do not introduce a `has_*` fallback, extra polling, or reading churn.
- Do not silently add mandatory support for device classes or clusters merely because the Matter specification defines them. Extend mappings with focused tests and verified device/server evidence.

- Optional Thread/Wi-Fi diagnostics and unmatched raw Matter attributes must not flood FHEM readings by default. Prefer explicit per-node opt-in, already supplied server attribute reports, bounded formatting and no new periodic polling. Do not mistake server/OTBR-level topology diagnostics for the diagnostic cluster attributes of a Matter endpoint.
- Keep change sets and issues clustered by coherent device behavior (sensor readings, switch events, actuation, diagnostics, OTA), but ensure each change has independently verifiable acceptance criteria; avoid duplicate tickets for the same behavior.

## Matter-specific regression reminders

These are recurring Matter integration failures. General security, lifecycle,
validation and test-fidelity rules are already in `AGENTS.md`; do not duplicate
them here. For relevant changes, test both the intended protection **and** that
unrelated valid data is still processed.

- **IO identity and reentrancy:** An IO rename must preserve existing root and
  endpoint identities, `IODev`, `defptr` and `%selectlist`, including after
  discovery. Synchronous FHEM reading events cannot reopen a disabled IO.
- **Request acceptance and secrets:** Distinguish socket queue acceptance from
  server/device success. Reject disconnected/failed sends and correlate
  message IDs. Prevent pairing codes and Wi-Fi passwords from entering FHEM's
  synthetic `set` events as well as logs.
- **Snapshot freshness without lost updates:** A delayed `getConfig` reply
  must not overwrite a newer live attribute, but must retain unrelated
  attributes and updated capability metadata. A partial `node_updated`
  (such as `available` only) must not suppress the rest of a complete
  discovery snapshot or removal of an *unrelated* missing node. Repeated
  discovery requests must not grow unbounded pending state.
- **Matter data integrity:** Reject invalid/null OnOff, level, metadata and
  JSON shapes without manufacturing state changes; keep `pct` within 0–100
  even when a device reports a level exceeding a configured maximum.
  Malformed or rejected credential-list responses must preserve prior
  credential readings.
- **WebSocket correctness:** Distinguish split TCP reads from continuation
  frames; check the HTTP accept key, FIN/control-frame rules, size limits
  and cleanup on close. Verify these with independent protocol fixtures.

## Tests, review, and deployment

- Inspect actual tests and workflows on the branch. `t/matter_node_sync.t` and `.github/workflows/perl-tests.yml` provide modeled FHEM callback and WebSocket regression coverage; run `prove -v t/matter_node_sync.t` in an environment with the Perl JSON dependency. Do not equate modeled callbacks or syntax checks with live FHEM integration. Add focused regression tests for any behavior changed, with faithful FHEM callback and WebSocket framing/correlation behavior.
- For transport changes cover split/coalesced frames, extended payload lengths, malformed/oversized frames, EOF, reconnect, delayed responses and timer/FD cleanup. For model changes cover duplicate discovery, multiple nodes/IO devices, endpoint routing, collisions, manual renames, attribute changes, and backward compatibility. Scope tests to the change; avoid speculative scaffolding.
- Validate Perl syntax with the actual FHEM dependencies available, and document dependency gaps if a standalone `perl -c` cannot load the module. Verify on a real FHEM + Matter server only when feasible, and state which integration/hardware paths remain untested.
- Keep PRs narrow: provide observed problem, source evidence, changed paths, tests run/not run, and compatibility risk. Do a second review of both modules and their interaction after modifications. Avoid changing Matter server or Thread Border Router repositories as part of a FHEM module fix without separate explicit authorization.

## Matter documentation and release metadata

- In both German and English commandref, **explicitly label every documented device class or behavior without confirmed maintainer-owned hardware validation as `ungetestet` / `untested`**. Existing support is not proof of testing. Mark the actual device/function combinations tested rather than implying validation of an entire Matter cluster, and keep unsupported/unverified classes visible instead of silently labeling them supported. Automated callback tests, a claimed standard feature and real-device verification are separate evidence levels. Recheck the status when extending a class or when hardware evidence becomes available.
- For each user-visible module change, review and update `README.md` and the German/English FHEM command reference embedded in `FHEM/97_MATTER.pm` and `FHEM/97_MATTERDevice.pm` as applicable. Describe only behavior supported by the current source and tests. Distinguish implemented functionality, automated regression coverage and real-world behavior where that distinction affects understanding; remove stale statements instead of accumulating contradictory claims. Avoid repetitive caveats about missing live hardware tests: document test scope once in the development/testing section and mention an unverified behavior elsewhere only when it is a concrete limitation or relevant to a deployment decision.
- For a functional Matter-module release, review and advance the existing FHEM-visible `$MATTER_version` declaration in `FHEM/97_MATTER.pm`, using the actual release date. It currently populates the existing `VERSION` internal; preserve that interface rather than introducing a duplicate version field without a separate justification. Check whether the version also needs to change when only `97_MATTERDevice.pm` changes. Do not bump the module version for documentation-only changes.
- Preserve the complete user-facing change history in `CHANGELOG.md`. Keep the root `CHANGED` limited to concise notes for the **current published release on that branch** (`testing` or `main`); replace its previous release notes on publication rather than accumulating the entire history. FHEM compares the remote file with its global local `CHANGED`, not a per-source baseline, so this is release-specific output, **not** a guaranteed per-installation delta. Do not include `CHANGED` in `controls_matter.txt` or overwrite FHEM's own `CHANGED`.
- After editing any `FHEM/*.pm` file, regenerate `controls_matter.txt` with `bash make_controls.sh` and check it with `bash make_controls.sh --check`; include its resulting changes in the same commit so the FHEM updater publishes the correct module bytes.
- Review README installation/update instructions against the tracked release source (`main`), including the original Zeppelin source and any FHEM security consequences. Never claim a live Matter/Thread/BLE commissioning test took place based only on modeled Perl tests.

## Shared rules management

- Keep `AGENTS.md` byte-identical to the accepted central `Flachzange/FHEM_Agent_Rules` revision in `.github/agent-rules.json`. Never edit generic rules locally.
- Put Matter-specific decisions here. Propose genuinely reusable FHEM lessons in the central repository through a separate authorized review/PR; adoption remains manual through the central distribution draft PRs.
- The `.github/workflows/agent-rules.yml` check validates central source provenance and this supplement. A successful documentation check is not evidence of Matter runtime correctness.
