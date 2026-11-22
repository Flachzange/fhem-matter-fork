# Offline lifecycle acceptance (#27)

The last reported `available` reading is persisted by FHEM. It is not
evidence of reachability in a new FHEM process or IO connection. The update
gate now uses the root's current-session `helper.available` instead.

| Input / lifecycle | Device data and reads | Administration |
| --- | --- | --- |
| New node, missing/invalid availability | Blocked; retain/create identity and endpoints only | No fabricated online state |
| Valid false report | Blocked, including live attributes | Root offline; last physical readings retained |
| IO loss, removal, INITIALIZED/REREADCFG | Invalidate runtime availability and old read epochs; quarantine snapshots | Root unknown/removed; saved available retained |
| Valid true report after invalidation | Permit individual live attributes and metadata-only command recovery; cached physical snapshots remain blocked | Root online; endpoint association retained |
| Missing/null/malformed availability | Does not change runtime authority | No invented boolean |

All roots belonging to a closing IO are invalidated before its first reading
event. This matters because FHEM notifications can synchronously reenter the
module. Another IO, including one with the same numeric node ID, is unaffected.
An accepted live BasicInformation model report explicitly updates child
model readings; availability-only mirroring never replays a cached model.

## Framework evidence

Inspected 2026-11-22 against
[`fhem/fhem-mirror@5544e24cc71f2e3cebd786001778fe18eea5e62e`](https://github.com/fhem/fhem-mirror/blob/5544e24cc71f2e3cebd786001778fe18eea5e62e/fhem/fhem.pl).
Startup restores configuration/state before `finish_init()` and the global
`INITIALIZED` event, before the normal event loop. `CommandRereadCfg` likewise
calls `finish_init()` and triggers `REREADCFG` after reloading. These existing
MATTERDevice lifecycle callbacks therefore invalidate restored permissions
without replacing FHEM's reading persistence or its `STATE` restoration.
The installed user's exact FHEM revision was not inspected.

The existing Matter-server freshness limitation is unchanged: a validated
availability report does not prove that every cached attribute was reread
from hardware. The client accepts later individual `attribute_updated`
reports, but cannot prove physical contact beyond that API signal. It adds
no device polling or server-side cache manipulation.

## Validation and limits

The regression suite runs the actual module parsers/callbacks with modeled
FHEM functions. The focused lifecycle subtest retains readings while rebuilding
runtime helpers, delivers INITIALIZED/REREADCFG, injects reentrant callbacks
and reconnects modeled IOs. It covers unknown/invalid availability, local
state/sensor/model values, type metadata, metadata recovery, member removal,
multiple roots and same-node-ID IO separation. Existing tests cover stale
read epochs, offline live events, node list ordering and bounded recovery.

Physical device firmware, a running FHEM restart, configuration-file/configDB
loading and the real event loop were not exercised. A modeled restoration is
not a claim of end-to-end hardware or configDB verification. No new migration,
timer, public reading or module attribute is introduced.
