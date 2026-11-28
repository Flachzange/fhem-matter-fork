# Thread neighbor identities and parent display

## Protocol evidence (inspected 2026-11-28)

- The connectedhomeip data model at revision
  [`1a3676179fd52d1323395364554581a2a8d9e8d7`](https://github.com/project-chip/connectedhomeip/tree/1a3676179fd52d1323395364554581a2a8d9e8d7),
  [`thread-network-diagnostics-cluster.xml`](https://github.com/project-chip/connectedhomeip/blob/1a3676179fd52d1323395364554581a2a8d9e8d7/src/app/zap-templates/zcl/data-model/chip/thread-network-diagnostics-cluster.xml),
  defines cluster 53: RoutingRole=1, ExtendedPanId=4, NeighborTable=7,
  RouteTable=8, own ExtAddress=63 and own Rloc16=64. ExtAddress/Rloc16
  are provisional in this model and cannot be assumed on deployed devices.
  Neighbor entries contain ExtAddress (tag 0), Rloc16 (2), LQI (5),
  AverageRssi (6), LastRssi (7) and IsChild (13).
- [`GeneralDiagnostics.NetworkInterfaces`](https://github.com/project-chip/connectedhomeip/blob/1a3676179fd52d1323395364554581a2a8d9e8d7/src/app/zap-templates/zcl/data-model/chip/general-diagnostics-cluster.xml)
  is path `0/51/0`: IsOperational=tag 1, HardwareAddress=4, Type=7;
  Thread is interface type 4. The ESP32
  [`DiagnosticDataProviderImpl_OT.cpp`](https://github.com/project-chip/connectedhomeip/blob/1a3676179fd52d1323395364554581a2a8d9e8d7/src/platform/ESP32/DiagnosticDataProviderImpl_OT.cpp)
  fills hardwareAddress with GetPrimary802154MACAddress. The OpenThread
  [`GenericThreadStackManagerImpl_OpenThread.hpp`](https://github.com/project-chip/connectedhomeip/blob/1a3676179fd52d1323395364554581a2a8d9e8d7/src/platform/OpenThread/GenericThreadStackManagerImpl_OpenThread.hpp)
  implementation obtains it from `otLinkGetExtendedAddress`, i.e. the
  current Thread extended address, not an inferred factory EUI-64.
- matterjs-server revision
  [`fc8aa79611aebbe3090a30813e7211f707b2131f`](https://github.com/matter-js/matterjs-server/tree/fc8aa79611aebbe3090a30813e7211f707b2131f),
  [`Converters.ts`](https://github.com/matter-js/matterjs-server/blob/fc8aa79611aebbe3090a30813e7211f707b2131f/packages/ws-controller/src/server/Converters.ts),
  serializes struct members by numeric TLV tags and byte strings as Base64.
  The parser also accepts named fields. Eight hardware-address bytes use
  canonical 12-character padded Base64; they are decoded in network byte order.
- [OpenThread IPv6 addressing](https://openthread.io/guides/thread-primer/ipv6-addressing)
  describes the Router ID in the upper six Rloc16 bits, the reserved bit
  and nine Child ID bits. A child uses its parent's Router ID. Hence
  `parentRloc16 = ownRloc16 & 0xfc00`, provided the locator is an allocated
  child locator and the role is an end device or REED. This implementation
  requires one matching non-child entry; RSSI order does not select a parent.
- [OpenThread CLI reference](https://openthread.io/reference/cli/commands#nexthop-get)
  describes next-hop lookup for a particular destination. Neither a neighbor
  table nor the strongest RSSI proves the route of a specific Matter command.

These are source/specification observations, not evidence that every device
or server reports those fields correctly or keeps them current.

## Implementation and limits

`threadExtAddress` is the own address as 16 lowercase hex digits; uint64
values are converted with core Math::BigInt without numeric/float coercion.
The existing JSON decoder must still preserve the received integer/string:
already rounded upstream numbers cannot be recovered. `threadRloc16` is the
own decimal locator. Both are root-only opt-in diagnostic readings.
No new module dependency outside Perl core is needed (MIME::Base64 is already
used by the IO module).

Only accepted reports with diagnostics enabled populate a bounded runtime
cache. Names require unique addresses on the same IO and ExtendedPanId;
network names alone do not prove network identity. Both peers must have
accepted current-session metadata and diagnostics enabled. Duplicate identities
remain hex. Multiple distinct usable interface addresses produce `unknown`;
missing/malformed hardware bytes do not overwrite a prior valid address.
Unrecognized neighbor addresses are displayed as `unknown`, not arbitrary
unvalidated strings. A THBR without a known Matter root remains an address.

The last received own address source wins; normally the interface and Thread
cluster report the same address. This is a display aid, never a permission
or evidence of live physical contact. Snapshots may be cached. Enabling
opt-in does not replay old data. Offline, IO loss, identity/network change
and opt-out discard runtime topology; existing public readings are retained.
Root names are looked up anew rather than persisted in an address registry.
Metadata, rename and delete can change the formatted list without a new
neighbor report; the list timestamp denotes a display change.

Parent marking requires accepted role, own child Rloc16 and one matching
neighbor Rloc16. Sleepy End Device, End Device and REED roles qualify when
attached as a child; Router/Leader do not. Missing, reserved, unallocated or
ambiguous locators yield no parent mark. The best non-child RSSI/LQI policy
is unchanged. No complete path, active router next hop or historical command
route is claimed. The list still includes at most 16 usable neighbors,
strongest first, with a 600-character bound; the count includes all reported
rows (up to 256). No new request, timer, persistent topology or migration.

## FHEMWEB neighbor links

The existing `MATTERDevice_FWDetail` root hook adds a **Thread neighbors**
table only when diagnostics is enabled and accepted usable runtime data is
available. It also works on roots without functional endpoints. Endpoint
navigation remains independent. Missing/empty data and endpoints have no
Thread table. Disabling diagnostics hides it on the next page load even if
old public readings remain; re-enabling does not replay saved readings.

`MATTERDevice_ThreadNeighborRows` supplies the same first 16 normalized,
resolved rows to the plain reading and HTML renderer. No name is recovered
by parsing the possibly truncated reading. Known devices have native relative
`?detail=` links using FHEMWEB's `urlEncode`; text uses `FW_htmlEscape`.
Unknown or ambiguous peers have no link. Role/parent and RSSI are shared with
the reading, which retains its 600-character plain-text bound. The HTML table
shows complete cells for the same first 16 entries.

Rendering does not write readings or start requests/timers. As with the
existing endpoint table, updates are visible on opening/reloading the detail
page, without a separate live-update implementation. HTML is not stored in
readings, events, JSON or database values.

Framework source: pinned FHEM `8b257af4a681169a4162610b158ca6d4d103d489`,
`01_FHEMWEB.pm`: `FW_doDetail` calls the registered `FW_detailFn` and includes
its returned HTML while `FW_deviceOverview=1` retains the standard overview.
`FW_makeTable` normally escapes reading values but allows `<html>…</html>`;
using that wrapper would store HTML in the reading itself. The link rendering
therefore extends the existing hook and its native URL/escaping helpers.

## Verification

`t/matter_node_sync.t` covers IO-routed snapshots/events, uint64 boundaries,
named/tagged structures, canonical Base64, late identity and role/locator
reports, weaker parent versus stronger RSSI, ambiguous candidates/identities,
multiple IOs/networks, opt-out, offline/identity invalidation and no new
requests/timers. Existing pending-read/snapshot regressions exercise the
shared pure attribute-conversion acceptance path.

`t/matter_display_core.t` uses the pinned actual FHEM core from CI in unicode
and bytestream modes. Synthetic reports exercise real readings, native rename,
modify, delete and statefile/rereadcfg behavior, including rebuilding runtime
topology from new reports rather than restored public readings.

Additional callback and actual-FHEMWEB HTTP cases cover known/unknown and
ambiguous links, role/RSSI cells, no reading writes, diagnostics gating,
roots without endpoints and rename targets. The linked pages are reachable
through the native FHEMWEB detail URLs in both encoding modes.

No live Matter server, Thread hardware or configDB validation was performed.
