# Matter fork changelog

This file preserves the history of user-facing changes to the FHEM Matter fork.
The root `CHANGED` file contains only the currently published update notes
for the branch and is read by FHEM's updater. FHEM does not track a separate
installed CHANGED baseline for each additional update source, so its output is
**not** an exact per-installation delta.

## History

- 2026-11-15  MATTER IO/Device V0.14: preserve root/endpoint ownership and active socket on IO rename; suppress Wi-Fi password set events; reject malformed state/brightness and disconnected commands; avoid cross-request ID collisions and stale discovery/read results; validate WebSocket upgrade response and fragmented frames; extend lifecycle/security regression rules and tests.

- 2026-11-15  MATTERDevice: show each endpoint's root through FHEM's native 'Probably associated with' links using persistent associatedWith readings; preserve user links and FHEM rename behavior.
- 2026-11-15  MATTER IO: defer the initial TCP/WebSocket connection until FHEM's event loop starts, preventing handshake timeouts during configuration load; preserve immediate manual connect and existing reconnect behavior.
- 2026-11-15  MATTERDevice: persist Descriptor DeviceTypeList IDs in the device_type_ids reading; restore endpoint type labels and automatic groups from FHEM's statefile without new Matter server data.
- 2026-11-15  MATTERDevice: use node and endpoint IDs in DEF; automatically normalize legacy root-name definitions on load (save once afterward). Match endpoint ownership by IODev and node identity.
- 2026-11-15  MATTERDevice: preserve FHEM's initial STATE placeholder so the statefile can restore the previous display state after restart.
- 2026-11-15  MATTER IO: add commissionMode (network/auto) attribute for the default commissionCode mode; explicit mode arguments override it.
- 2026-11-15  MATTER IO: expose correlated commissioning status, mode, node ID, duration and sanitized errors; mark lost connections as unknown outcome and serialize attempts per IO.
- 2026-11-14  Documentation: clarify Matter architecture, security, supported commands, hardware validation and upstream attribution; update MATTER IO version to V0.3 (14.11.2026).
- 2026-11-14  FHEM updater: publish fork modules via controls_matter.txt; add deterministic manifest generation and CI validation (PR #12).
- 2026-11-14  Documentation: show THBR BLE proxy and IPv6 Thread border-routing paths; link original THBR and THBR-ETH fork (PR #12).
- 2026-11-14  MATTER IO: support commissionCode network (default) or auto (IP plus optional BLE proxy); protect pairing codes in module logs and FHEM set events (PR #11).
- 2026-11-14  MATTER IO: reconnect automatically, detect stale WebSocket connections via Ping/Pong, and restore event subscriptions (PR #10).
- 2026-11-14  MATTERDevice: group node endpoints and provide endpoint navigation from root devices (PR #9).
- 2026-11-14  MATTERDevice: extend cluster capabilities, measurement readings, node availability, and RGB brightness handling (PR #8).
- 2026-11-14  MATTER IO: synchronize nodes automatically on connect and from server events; retain manual discovery and existing device names (PR #5).
