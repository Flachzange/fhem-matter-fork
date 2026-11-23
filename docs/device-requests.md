# Shared device request correlation (V0.26)

Device commands, explicit configuration reads and automatic capability reads pass their IO and payload to `MATTER_SendJsonCommand`. The IO encodes the payload and returns the WebSocket enqueue result. Each caller owns its request registration and cleanup.

## Responsibilities

| Path | Responsibility |
| --- | --- |
| MATTERDevice_Set | Validate ordinary actuation and build payloads without request IDs or command-specific response registries; reads remain separate |
| MATTERDevice_SendRequests | Allocate IDs, register ownership, send, group compound setter results and handle failed enqueue |
| MATTERDevice_CompleteRequest | Match current FHEM owner/IO, account for incoming replies, retire group components and publish only the latest setter result |
| MATTERDevice_RequestError / WriteResponseError | Decode API errors and operation result types; no FHEM command-name dispatch |
| MATTERDevice_HandleNodeOperation | Apply existing OTA/ICD results; their wrapper preserves explicit administrative serialization |
| MATTER IO parser / heartbeat / close | Remove each pending entry and call the same completion function for reply, timeout or IO loss |

All ordinary device_command and write_attribute setters use this path:
on/off/toggle/effects, levels/colors/frequency, coverings, locks, Identify,
native dimming and thermostat/fan writes. OTA/ICD use the same sender and
completion functions while retaining their administrative operation policy.
Read-only getConfig/capability requests keep their existing read reconciliation
with availability epochs and newer-report protection; IO commissioning and
credentials retain their own established request contracts.

## Ownership, parallel requests and diagnostics

### Endpoint readOnly control protection (V0.38, #77)

`readOnly=1` is a local policy for endpoints greater than 0. A single policy
check supplies the direct SetFn error, the restricted dynamic set list and the
shared sender guard. The sender checks before allocating IDs and before each
component send: a synchronous reply/notify can enable protection during RGB.
An initially blocked invocation leaves readings and request state unchanged.
If a component was already sent, the ordinary group completion reports the
unsent remainder as failed and retains correlation of any outstanding part.

For readOnly, no capability, availability, receive or completion gate is added. Explicit
getConfig and automatic metadata reads retain their separate paths; normal
reports/events and results of previously sent commands continue. Unlocking
needs no read, replay, timer or transient mode state. Roots reject the attribute.
This does not restrict root administration, other controllers, direct server
access or physical controls. Endpoint disable is described below.

FHEM `DoSet` calls SetFn in list context and returns a nonempty error before
synthesizing a command event. `CommandAttr`/`CommandDeleteAttr` call AttrFn
before changing the attribute map; readOnly validation has no side effects.
Inspected 2026-11-23 in
[fhem.pl](https://github.com/fhem/fhem-mirror/blob/main/fhem/fhem.pl),
Git blob `07b16fbc7fc14fe95553b1b365f5bdb398220817`.
The #77 regression covers every current setter family, internal command/write
callers, compound send reentry, reads, live/snapshot/button reception, prior
completions, modeled attribute restoration and endpoint/multi-IO isolation.
Live FHEM/configDB and hardware validation remain **ungetestet / untested**.

### Endpoint disable (V0.39, #78)

`disable=1` pauses functional endpoint updates and all sends/reads. A shared
control check covers direct calls and the common sender; attribute, metadata,
snapshot reset, button and root-mirroring paths skip disabled targets. Physical
state, readings/timestamps and capabilities remain unchanged. Structural root
association and receive internals remain active.

Both transitions retire owned commands and endpoint reads in the existing IO
registries. Outstanding shared reads and discovery snapshots gain an endpoint
exclusion, so late replies cannot update a re-enabled child or destroy valid
sibling data. Exclusions expire with those existing requests; no persistent
generation or second request registry is introduced. Local exclusions alone
must not prevent authoritative missing-node detection.

AttrFn sets one transient `enable_sync` marker for a real disabled-to-enabled
transition. Notify consumes it after the attribute commit and before publishing
anything, mirrors current root status and invokes existing endpoint getConfig
once if connected/online. Startup or offline activation does not probe; ordinary
online synchronization supplies subsequent data. There are no new timers,
background retries or command replays. readOnly remains independent. Previously
sent commands may still execute physically; canceling correlation is local only.

### Correlation and results

Every API request has a unique connection-scoped message_id. Its pending
entry retains the owner hash, FUUID, node, endpoint, API operation, write path,
status reading, start time and timeout. Completion checks that the hash is
still registered under its current name with the same FUUID/node/endpoint/IO.
A device rename keeps its identity; deletion/replacement, rebind or changed
node/endpoint cannot redirect an old response to the new owner.

Ordinary commands and attribute writes are not serialized. On followed by
Off, Move followed by Stop and consecutive setpoint writes can all be in
flight. Each response remains individually correlated, decoded and retired;
an older reply never overwrites a newer setter's diagnostic result. This is
not a device execution-order guarantee and does not cancel older commands.

Each setter invocation has one small result group. Usually it has one request;
RGB can have separate level/color requests. A group error remains visible even
when the other component succeeds, in either order. Success is published only
when every component has acknowledged. A later independent setter supersedes
only diagnostic publication, not correlation of earlier requests. There is no
persistent motion state or separate dim-specific registry.

Server refusals and malformed responses produce lastError `failed: ...`.
Timeout reports `timeout (outcome unknown)`; IO loss reports
`interrupted (outcome unknown)`. A later successful setter reports `none`.
Repeated identical diagnostics do not rewrite the status reading. No reading
is reset optimistically at send time; physical state/brightness/setpoints and
their timestamps change only from actual server/device reports. Asynchronous
SetFn returns `(undef, 1)` in FHEM list context to suppress the synthetic
command event.

## API results and failure limits

- For device_command, an API error reports failure. A reply with a result
  field acknowledges the request regardless of its value, including null.
  A reply missing both an error and a result is malformed.
- write_attribute keeps the V0.25 path/status-list validation, including
  nonzero Matter/cluster status and the existing null-acknowledgement contract.
- OTA/ICD have their existing operation-specific result processing. Neither
  API acknowledgement nor transport delivery proves physical completion.

The existing heartbeat expires ordinary requests after 120 seconds; OTA
installation retains its longer timeout. No additional timer, probe, polling,
automatic retry, readback or Stop is introduced. Reconnect does not replay
commands. Duplicate/late responses whose IDs have already been retired are
ignored.

The IO registry allows at most 1024 pending entries for device sends. Exceeding
capacity returns an explicit error before sending; this is a resource bound,
not a response serialization policy. Request allocation/sends can also fail.
For RGB, partial enqueue is possible: an unsent component marks the setter as
failed, while an already-sent component remains correlated. If the transport
closes during enqueue, the existing close path completes each registered
component once. No rollback of an already-sent hardware command is claimed.

## Evidence and verification — inspected 2026-11-22

- The relevant commands in Matter 1.4
  [OnOff](https://github.com/project-chip/connectedhomeip/blob/master/data_model/1.4/clusters/OnOff.xml),
  [LevelControl](https://github.com/project-chip/connectedhomeip/blob/master/data_model/1.4/clusters/LevelControl.xml),
  [ColorControl](https://github.com/project-chip/connectedhomeip/blob/master/data_model/1.4/clusters/ColorControl.xml),
  [WindowCovering](https://github.com/project-chip/connectedhomeip/blob/master/data_model/1.4/clusters/WindowCovering.xml),
  [DoorLock](https://github.com/project-chip/connectedhomeip/blob/master/data_model/1.4/clusters/DoorLock.xml)
  and [Identify](https://github.com/project-chip/connectedhomeip/blob/master/data_model/1.4/clusters/Identify.xml)
  use standard status responses for the commands currently exposed by FHEM.
- OHF matterjs-server at `fc8aa79611aebbe3090a30813e7211f707b2131f`:
  [ControllerCommandHandler](https://github.com/matter-js/matterjs-server/blob/fc8aa79611aebbe3090a30813e7211f707b2131f/packages/ws-controller/src/controller/ControllerCommandHandler.ts)
  throws on nonzero cmd-status and returns undefined on success;
  [WebSocketControllerHandler](https://github.com/matter-js/matterjs-server/blob/fc8aa79611aebbe3090a30813e7211f707b2131f/packages/ws-controller/src/server/WebSocketControllerHandler.ts)
  returns null for absent command response data and returns the message_id.
  Write status and FHEM DoSet evidence are linked in
  [HVAC writes](hvac-writes.md) and [native dimming](native-dimming.md).
- 888 top-level suite entries pass, including 249 shared-path assertions and
  170 native-dimming assertions. Tests cover all ordinary setter families,
  exact ownership, concurrent command/write IDs, both late-reply directions,
  compound success/failure/partial-send cases, synchronous completion, rename,
  registry capacity, timeout and transport close during enqueue. Existing
  OTA/ICD, discovery, credential and transport regressions remain in the suite.

These are modeled FHEM callback and socket-backed tests. No live FHEM/configDB,
physical hardware or installed Matter server was exercised. Hardware/server
integration remains **ungetestet / untested**; no end-to-end reliability or
physical execution-order guarantee is inferred from these tests.
