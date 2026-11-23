# Matter fork changelog

This file preserves the history of user-facing changes to the FHEM Matter fork.
The root `CHANGED` file contains only the currently published update notes
for the branch and is read by FHEM's updater. FHEM does not track a separate
installed CHANGED baseline for each additional update source, so its output is
**not** an exact per-installation delta.

## History

- 2026-11-23  MATTER V0.40 (#81): Bind explicit reads to the requesting FHEM instance and endpoint scope using the shared request-owner check. Cancel owner reads on Undef/identity change/disable and exclude deleted endpoints from old shared responses. Preserve rename and stop processing after reentrant replacement.

- 2026-11-23  MATTER V0.40 (#80): Merge partial getConfig metadata per path instead of resetting endpoint capabilities. Preserve omitted/invalid values; valid empty lists and endpoint Descriptor.ServerList revoke support. Read ServerList for endpoints and preserve newer lists across delayed reads/discovery and disable exclusions.

- 2026-11-23  MATTER V0.40 (#79): Invalidate permissions, offers and control-relevant reported metadata on actual IO/node/endpoint identity changes. Retain physical readings and local policy; preserve renames and unchanged definitions. Reject occupied root identities before modify and cancel the old owner's operations.

- 2026-11-23  MATTER V0.39 (#78): Add endpoint-only disable: pause controls, reads, functional updates and events while preserving identity and readings. Reuse existing request registries to discard endpoint requests and exclude stale shared replies on both transitions; synchronize once on online activation without polling or replay. Keep root/siblings and readOnly independent. Add regression coverage and DE/EN help; hardware untested.

- 2026-11-23  MATTER V0.38 (#77): Add endpoint-only readOnly control protection with central command/write enforcement, dynamic set lists and preserved reads, reports, events and in-flight completions. Block unsent compound components if protection is enabled during a synchronous callback. Add focused regression coverage and DE/EN attribute help; hardware untested.

- 2026-11-22  MATTER V0.37 (#66): Remove the empty IO get callback and unused capability and disconnect code.

- 2026-11-22  MATTER V0.36 (#65): Consolidate device command construction and RGB brightness scaling.

- 2026-11-22  MATTER V0.35 (#64): Skip redundant endpoint group and root metadata synchronization on routine device reports.

- 2026-11-22  MATTER V0.34 (#63): Reuse decoded server messages for discovery, live reports, switch events and configuration read replies.

- 2026-11-22  MATTER V0.33 (#62): Reject surplus arguments for all noArg device setters before registering or sending a request.

- 2026-11-22  MATTER V0.32 (#61): Release deleted IO definitions by sending device commands and reads through the existing JSON sender.

- 2026-11-22  MATTER V0.31 (#60): Preserve valid endpoint capability lists across malformed reports and delayed reads. Valid empty lists revoke their entries.

- 2026-11-22  MATTER V0.30 (#59): Expose physical Window Covering lift and tilt limits as endpoint readings.

- 2026-11-22  MATTER V0.29 (#58): Route incoming node reports and read replies to the current IO owner. Moving a root resets its availability and rejects occupied destination IDs.

- 2026-11-22  MATTER V0.28 (#57): Preserve newer node_updated attribute values when applying delayed getConfig replies, including unrelated attributes and capability metadata from the reply.

- 2026-11-22  MATTER IO/Device V0.27 (#36): gate manual OTA by current backend/schema and reported root capability, independently of local reachability. Validate uint32 offers, handle matterjs version objects and null acknowledgements, consume install offers once and preserve device-confirmed installation across reordered replies. Require a fresh check after timeout or server reconnect. Add lifecycle coverage and bilingual commandref. Hardware untested.

- 2026-11-22  Tests/documentation (#35): clarify raw reading exclusions and per-value limits. Cover diagnostic table boundaries, invalid reports and isolation between Matter IOs.

- 2026-11-22  MATTER IO/Device V0.26 (draft): consolidate all device-command and attribute-write sends, IDs, ownership and reply/timeout/disconnect completion in a shared request path. Permit overlapping everyday setters/writes; retain each response association while only the latest setter publishes lastError. Aggregate RGB level/color results without hiding component failure. Accept successful device-command replies with any result value. Preserve API-specific write status/path validation, report-only physical readings and existing OTA/ICD administrative policies. Validate native dim arguments/rate and retain regular/WithOnOff selection, native steps and immediate Stop. Update DE/EN documentation, evidence and targeted all-setter/lifecycle regression tests; no extra polling, dim timers or retries. Real hardware remains untested.

- 2026-11-22  MATTER IO/Device V0.25 (draft): add feature-gated desired-temp-cool writes; constrain thermostat/fan mode choices using standard writable targets, FeatureMap and operation/mode sequences, shared by FHEMWEB and explicit setters. Replace the arbitrary heating slider with Celsius text inputs. Correlate write status lists with the requested attribute path and reject nonzero/malformed/mismatched results; retain existing null acknowledgements and report-only telemetry. Keep bounded global metadata recovery aware of missing HVAC features. Add focused regression coverage and DE/EN documentation; hardware remains untested.

- 2026-11-22  Tests/documentation (#32): verify existing pressure, CO2, PM2.5 and TVOC readings through snapshots and live reports, valid zero versus null/invalid values, pressure type bounds, sibling endpoints, separately supplied/unknown units and qualitative-only concentration features. No runtime, V0.24, commandref or updater change; hardware remains untested.

- 2026-11-22  Tests/documentation (#30): verify persisted/manual contact, leak, rain, occupancy, temperature, humidity and illuminance readings through INITIALIZED/REREADCFG, offline/online snapshots and live reports. Cover saved DeviceTypeList interpretation, renamed devices, unknown BooleanState types, null/invalid values and same-node multi-IO isolation, including reading write counts. Existing V0.24 module behavior, commandref and updater manifest remain unchanged; real FHEM/configDB/hardware integration remains untested.

- 2026-11-22  MATTER IO/Device V0.24 (draft): reconcile prior ICD support from valid root Descriptor.ServerList, preserving partial/invalid reports and newer live metadata over older responses. Read ServerList in the existing root getConfig request. Require current-connection OHF matterjs-server identification plus schema >= 12 for controller ICD get/set operations; clear that authority before disconnect events. Preserve dynamic ICD readings and their normal timestamps. Add focused regression coverage and DE/EN documentation; real ICD hardware remains untested.

- 2026-11-22  MATTER IO/Device V0.23 (draft): use current-session availability after FHEM restart, IO reconnect and node removal, without persistent snapshot quarantine. Unknown/offline nodes retain local values; a valid online report resumes normal snapshots, node_updated attributes, live updates and full explicit getConfig. Preserve response ordering, availability epochs and bounded missing-command recovery. Add lifecycle and online-snapshot regression coverage, including synchronization without a separate attribute_updated event. Real FHEM/configDB integration remains untested.

- 2026-11-22  MATTER IO/Device V0.22 (draft): add automatic root-only `networkType` from operational GeneralDiagnostics.NetworkInterfaces entries, supporting Wi-Fi, Thread, Ethernet, Cellular and sorted combinations. Accept tag-based and named server structs; preserve prior readings on malformed/null data and existing offline quarantine. Record valid live attribute updates in pending discovery snapshots as well as explicit reads so late replies cannot replace newer values. Keep bridge transport on the root, independent of opt-in diagnostics and without extra requests or timers. Modeled callback coverage added; physical-device validation outstanding.

- 2026-11-19  MATTER IO/Device V0.21 (testing): replace ten auto-created device-limit attributes with validated endpoint readings. Remove all ten attribute declarations without compatibility or migration; document manual cleanup and save before restart. Never copy or automatically delete old settings. Build CT/frequency widgets from valid device limits, otherwise offer text input; remove arbitrary widget bounds. Use reported MaxLevel for non-Lighting endpoints and standardized 254 for Lighting, consistently across brightness/percentage/RGB. Preserve offline quarantine and update correlation; add focused regression coverage and DE/EN migration documentation. Hardware not verified.

- 2026-11-19  Documentation: describe all nine root-only Thread/Wi-Fi diagnostic readings in German and English commandref, including units, derived roles/types, neighbor limits, RSSI/LQI selection, passive updates and cached/stale value semantics. No runtime or version change.
- 2026-11-19  Documentation: add native FHEMWEB inline help for every declared MATTER/MATTERDevice attribute in German and English, with defaults, scope and the actual use of reported limits; correct German commandref block endings. Module runtime and V0.20 remain unchanged.

- 2026-11-18  MATTER IO/Device V0.20: expose conventional per-device receive internals (`<IODev>_TIME`, `LASTInputDev`, `MSGCNT`, `<IODev>_MSGCNT`). Count each incoming server message once per root/addressed endpoint, including unchanged values, cached/quarantined snapshots and correlated replies; do not treat mirrored availability or local disconnects as endpoint traffic. Runtime-only internals add no reading events. The timestamp indicates server reception, not confirmed physical-device contact. Modeled regression coverage includes routing, response correlation, offline protection, multiple IOs and IO rename; live FHEM verification remains outstanding.

- 2026-11-17  MATTER IO/Device V0.19 (testing): after offline → online, restore missing per-endpoint command/attribute capabilities with targeted global Matter metadata reads while keeping all stale device states and measurements quarantined. Skip reads when usable metadata is already known; ignore empty capability hashes generated by dynamic set-list probes. Allow up to three event-driven attempts per recovery epoch at least 15 seconds apart when reads fail or return incomplete results; no polling or timers. Explicit `getConfig` while online and quarantined restores only global metadata, not cached physical device values. Reject reads while offline and replies from an older availability epoch. Tests cover offline startup, known complete lists, missing feature maps, empty responses, failed sends, bounded retry, outdated availability epochs and late auto reads following newer manual responses; not yet hardware-validated.

- 2026-11-17  MATTER IO/Device V0.18 (testing): retire the original developer's `has_*` capability attribute declarations, automatic population, user command overrides and positive fallback permissions. Require a valid per-endpoint Matter `AcceptedCommandList` and relevant feature/revision metadata for command availability. Old saved `has_*` attributes are ignored but not automatically deleted; they may be removed manually after reviewing the configuration. Commands may initially be absent after restart until server metadata arrives. Update DE/EN commandref, regression tests and `AGENTS-MATTER.md`. No physical-device validation performed for this change.

- 2026-11-17  MATTER IO/Device V0.17 (draft): add common sensor/occupancy/BooleanState readings and transient Switch events (#30, #31); add environmental measurement clusters with units (#32); add Thermostat, FanControl and Identify (#33), native LevelControl move/step/stop (#34), opt-in Thread/Wi-Fi/raw diagnostics (#35), ICD capability and controller state operations (#28), and manual server-backed OTA check/install without image upload (#36). Prevent cached device data from overwriting offline nodes or manual edits (#27). Expand DE/EN commandref with explicit untested hardware labels (#37) and correlate writes/administrative requests. Tests model FHEM callbacks and matterjs-server responses; hardware remains separately unverified.

- 2026-11-15  MATTER IO/Device V0.16: replace automatic root stateFormat with a native online/offline/unknown/removed state reading; invalidate stale reachability after IO disconnect without falsifying raw availability or endpoint states; migrate the V0.15 autogenerated stateFormat after FHEM initialization and preserve custom formatting.

- 2026-11-15  MATTER IO/Device V0.15: show node-wide availability as the default FHEM Root status on newly defined and existing roots, preserve custom stateFormat and endpoint display, without inventing reachability when the Matter IO is disconnected.

- 2026-11-15  MATTER IO/Device V0.14: preserve root/endpoint ownership on IO rename; suppress Wi-Fi password set events; reject invalid telemetry and disconnected commands; correlate requests; reconcile delayed reads and partial discovery events per attribute/node without discarding unrelated data; preserve credential readings on malformed replies; bound brightness percentages; validate WebSocket upgrade/fragmentation; simplify unused metadata and add focused regression tests.

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
