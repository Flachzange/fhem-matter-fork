# Matter implementation review — 2026-11-17

## Scope and sources

The branch `feature/matter-device-completeness-20261117` was created from the pinned
`testing` baseline `8096ede4249125e2f35695517d6cecfe9803bbdd`.
The implementation follows `AGENTS.md`, `AGENTS-MATTER.md` and the
external matterjs-server WebSocket schema. fhempy test fixtures and cluster
converters were reviewed for missing cases; no fhempy source code or test
files were copied into the fork.

## Issue-by-issue implementation review

| Issue | Covered path(s) | Regression focus | Remaining hardware evidence |
| --- | --- | --- | --- |
| #37 | EN/DE POD commandref, README | Class-level untested labelling, no generic bridge/server promises | Device-specific real-hardware verification absent |
| #30 | Device cluster table, parser, typed BooleanState | Contacts, leaks, rain, temperature, humidity, lux, occupancy, invalid sentinels, endpoint ordering | Physical sensors untested |
| #31 | IO `node_event` routing and per-endpoint `button` event | Repeated identical values, multiple endpoints, malformed event payloads | Physical switches untested |
| #32 | Environmental measurement cluster table | hPa, CO2, PM2.5, TVOC, unit conversions and invalid readings | Physical environment sensors untested |
| #34 | LevelControl native `Move`, `Step`, `Stop` | Advertised commands, step/move payload, rate override, stop, no FHEM timer | Device-specific dimming variants untested |
| #33 | Thermostat/FanControl/Identify, `write_attribute` request correlation | Readings, valid and invalid writes, asynchronous server errors, no optimistic state changes | HVAC/fan/Identify devices untested |
| #27 | Root-availability gate ahead of all attribute and metadata effects | Offline snapshots, manual updates, delayed events, live recovery, node separation | Matter server / device live reconnection still untested |
| #35 | Opt-in diagnostics and raw data processing | Disabled default, enable/disable, Thread neighbors/RSSI/LQI and Wi-Fi RSSI, bounded raw readings | Thread and Wi-Fi device diagnostics untested |
| #28 | ICD capability parsing, schema gating, correlated `get_icd_state` and administration | SIT/LIT, feature-map and spec version, sleeping vs unavailable, pending/error path | LIT/SIT device and administrative server behavior untested |
| #36 | Server-side `check_node_update`, `update_node`, OTA progress and software version | Available / no update, explicit install, request correlation, reported progress and version | Real OTA installation untested |

## Cross-module review

- The IO remains a nonblocking WebSocket client of an **external** Matter server.
  No Thread/Matter server, BLE proxy, firmware upload handler or Matter bridge
  was introduced.
- All new device types use the existing `MATTERDevice` root/endpoint identity,
  `IODev`, FHEM readings and `%MATTER_CLUSTERS` mapping.
- Request-response correlation remains per IO `message_id` and validates
  FHEM device FUUID, node ID and current IO owner. Explicit requests are
  serialized by node and time out; a successful queued send is not treated
  as confirmation of a device state.
- Unreachable device attributes and capabilities are quarantined before
  parsing side effects. Root availability, server membership and FHEM
  associations remain live. After an offline/online transition no cached
  snapshot is accepted as a guaranteed fresh device report; per-attribute
  live reports can update stored values.
- Diagnostic/unknown raw attribute Readings are opt-in and bounded; no new
  background polling.
- No automatic icons or generic arbitrary-write command console were added.

## Test and review limits

The GitHub Actions Perl suite runs a modeled FHEM environment with simulated
WebSocket responses, not a hardware/Thread commissioning test. Regression
coverage is useful for syntax, callbacks, request correlation and many
edge cases, but does not prove feature support on arbitrary Matter firmware.
The DE/EN commandref explicitly labels such classes **ungetestet/untested**.

The implementation deliberately relies on `attribute_updated` as the most
specific available freshness signal; the server does not prove that every
cached field in a subsequent node snapshot was reread from hardware.
Therefore rarely reporting attributes may remain unchanged until a new
report arrives. This is an accepted conservative behavior rather than a
periodic FHEM poll.
