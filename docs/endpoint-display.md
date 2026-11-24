# Endpoint display defaults (#89; reading updates #91 and V0.43)

`STATE` is the presentation of an endpoint's existing readings. This change
adds no redundant physical readings, no stateFormat attribute, no polling and no
Matter requests. V0.42 replaces numeric lock_state with functional text state;
this is a reading-interface change, not another display-derived state copy. Existing on/off and binary-sensor `state` readings/events
remain unchanged. The user can override the entire presentation with the
normal FHEM `stateFormat` attribute; deleting it restores the default.

During configuration loading the initial STATE is left to the core/statefile
loader. After INITIALIZED/REREADCFG, endpoints derive their default from the
restored readings, or the core evaluates the configured stateFormat. Cached
readings never establish current reachability. Offline/disable data gates
continue to protect readings and timestamps. Root endpoint 0 retains the
existing online/offline/unknown/removed state.

## Complete current type policy

All rows describe implemented formatting, **hardware untested**. Functional
availability of a particular device/cluster is a separate question: a known
label or an `unknown` display does not establish device support.

The functional rows below are in selection order. Descriptor/report ordering
cannot change the selected primary type. Structural companions do not compete.
The temperature/humidity combination is selected at the temperature row.
Missing primary data stays unknown; it does not select a different type.
Within one type, an alternative source is used only while higher-priority
source readings are absent. Invalid/null reports retain last-valid readings.

| Device type IDs | Display source and format |
| --- | --- |
| Smoke CO Alarm 0x0076 | alarm_expressed_state: normal, smoke_alarm, co_alarm, battery_alert, testing, hardware_fault, end_of_service, interconnect_smoke, interconnect_co. No locally synthesized alarm priority. |
| Water leak 0x0043 | Existing state: leak/dry. |
| Rain 0x0044 | Existing state: rain/dry. |
| Door lock 0x000A | state: not_fully_locked/locked/unlocked/unlatched. Door contact is a separate value. |
| Window covering 0x0202 | Reported lift pct (100=open, 0=closed) and tilt (native 0..100), preferring fine reports over integer percentages. Both axes appear if supplied. If only absolute positions exist they are explicitly labelled raw; otherwise the readable wc_operational_status reading is used directly, e.g. global: opening / lift: opening / tilt: stopped. No target-position echo. The same inverted lift convention is used by the pct setter; targets are never echoed. |
| Thermostat 0x0301 | mode; measured: measured-temp °C; heat/cool: applicable desired-temp / desired-temp-cool °C. Auto shows both setpoints, off shows no setpoint. Missing components are unknown. |
| Fan 0x002B | fan_mode; actual fan_pct %, if supplied. fan_pct_setting is never substituted for the actual percentage. |
| Lights 0x0100, 0x0101, 0x010C, 0x010D | Existing on/off state. |
| Plugs 0x010A, 0x010B | Existing on/off state, even with an electrical-sensor companion type. |
| Contact 0x0015 | Existing open/closed state. |
| Occupancy 0x0107 | Existing motion/nomotion state. |
| On/Off sensor 0x0850 | Existing own state, otherwise boolean_state as neutral 0/1. |
| Generic switch 0x000F | Own last button event, explicitly `last: short`, etc. No inferred steady actuator state. |
| Controllers 0x0103, 0x0104, 0x0105 | Own state if actually supplied, otherwise own last button event or unknown. A client/controller type does not imply a server-side OnOff or Switch cluster. |
| Air quality 0x002C | Reported air_quality enum: unknown/good/fair/moderate/poor/very_poor/extremely_poor. If no qualitative reading exists, supplied co2/pm25/tvoc values appear in that order with their reported units. Missing unit = unknown, never an implicit ppm. No local threshold classification. |
| Electrical sensor 0x0510 | power W, otherwise energy kWh, voltage V, current A. Valid zero remains primary. Existing scaling is unchanged. |
| Temperature 0x0302 | temperature °C. With 0x0307: temperature °C / humidity %, with unknown for a missing component. |
| Humidity 0x0307 | humidity %. |
| Pressure 0x0305 | pressure hPa. |
| Illuminance 0x0106 | brightness lx, with recorded source provenance. |
| Flow 0x0306 | unknown: currently only a label, no FlowMeasurement parser. |
| Structural 0x000E, 0x0011, 0x0012, 0x0013, 0x0014, 0x0016 | Ignore as companions to functional types; if no known functional type is present, retain an existing own state or show unknown. Root behavior depends on endpoint ID 0, not a type label. |
| Unknown/vendor types | Existing own state, otherwise unknown; no arbitrary reading/name-based guessing. |

The current parser now validates the displayed air-quality, ExpressedState and
lock enums, current covering position bounds and OperationalStatus fields.
Rejection uses the same pure conversion used by read/discovery freshness
tracking, so invalid data cannot suppress an older valid outstanding result.
ExpressedState, AirQuality and OperationalStatus are decoded once in the
shared attribute-to-reading conversion. The standard display reuses the
readable reading values; it has no private numeric-to-text lookup. The movement
bitmap retains global/lift/tilt fields instead of discarding axis information. No invented zero/off/closed/locked/normal is introduced.

## Audit of semantic decoding in defaults

| Default family | Result |
| --- | --- |
| Smoke/CO alarm | alarm_expressed_state is decoded at ingestion and used directly; reading/event/display have the same text. |
| Air quality | air_quality is decoded at ingestion and used directly; concentration fallback still formats measurements with their reported units. |
| Covering movement fallback | wc_operational_status is decoded at ingestion, retaining all three fields, and used directly when no current position is available. |
| Locks, on/off, contacts, occupancy, leaks, rain | Functional state/contact/motion readings already carry the interpreted values. No display-only numeric conversion remains. |
| Thermostats and fans | mode and fan_mode already carry readable values; defaults only select/format the reported mode, actual values and applicable setpoints. |
| Buttons/controllers | button already carries a readable event. The last: prefix labels event semantics; it does not decode a numeric value. |
| Measurement, position, concentration and electrical defaults | Existing converted quantities are combined with units/labels. This is formatting rather than another state interpretation. |
| Root, structural, label-only and unknown types | Existing state or explicit unknown policy; no display-only enum decoding. |

## Core integration and source evidence

Inspected on 2026-11-23 against `mhop/fhem-mirror` commit
`8b257af4a681169a4162610b158ca6d4d103d489`:

- [fhem.pl](https://github.com/mhop/fhem-mirror/blob/8b257af4a681169a4162610b158ca6d4d103d489/fhem/fhem.pl):
  `readingsEndUpdate` runs userReadings and evalStateFormat before DoTrigger.
  Without stateFormat, core uses the state reading if one exists. There is no
  module-default stateFormat callback. Ending silently clears event arrays
  outside a trigger. The small module EndUpdate adapter retains the original
  CHANGED/CHANGETIME array references, calls core EndUpdate silently, computes
  the default and publishes those same events through DoTrigger. It does not
  synthesize another state event or skip userReadings/event filtering.
- The companion SingleUpdate adapter uses core Begin/Bulk and the same
  EndUpdate adapter. Root and explicit-stateFormat updates delegate the end
  of the transaction directly to core. Node membership mirroring in the IO
  uses this same endpoint-aware adapter; root/IO reachability is not derived
  from the display. The Matter IO calls the device parsers directly.
- Core CommandAttr evaluates a set stateFormat after committing the attribute.
  CommandDeleteAttr calls AttrFn before deletion and does not evaluate the
  format afterwards. The module handles requested pattern/all-attribute
  deletion and recomputes defaults on post-commit global events. Startup also
  reevaluates explicit formats after reading restoration.
- [01_FHEMWEB.pm](https://github.com/mhop/fhem-mirror/blob/8b257af4a681169a4162610b158ca6d4d103d489/fhem/FHEM/01_FHEMWEB.pm):
  FW_devState renders STATE in room/detail views; FW_Notify sends that rendered
  state in live status notifications for the original reading events. The
  default must therefore be present before DoTrigger, not assigned afterwards.
- FHEM supports unicode and legacy bytestream modes. Degree units use the
  matching internal representation; no ASCII approximation or extra reading
  is necessary. The HTTP tests use gzip as a normal browser does; the inspected
  core encodes unicode HTTP output on its compression path.

Matter primary-source definitions inspected on 2026-11-23:

| Source | Verified interpretation | Content blob |
| --- | --- | --- |
| [AirQuality.xml](https://github.com/project-chip/connectedhomeip/blob/master/data_model/1.4/clusters/AirQuality.xml) | AirQualityEnum 0..6 | 62a0842d15e027696d86f78815816d0f494e81d9 |
| [SmokeCOAlarm.xml](https://github.com/project-chip/connectedhomeip/blob/master/data_model/1.4/clusters/SmokeCOAlarm.xml) | ExpressedStateEnum 0..8; normal, battery, test, fault, end-of-service and interconnect values are distinct | 838f0b2e69d4b1506424672da02213acccb8c4af |
| [DoorLock.xml](https://github.com/project-chip/connectedhomeip/blob/master/data_model/1.4/clusters/DoorLock.xml) | LockStateEnum 0..3, distinct from DoorState | d1986c4bd6208d5614b2e7ce1dc854b19492ef23 |
| [WindowCovering.xml](https://github.com/project-chip/connectedhomeip/blob/master/data_model/1.4/clusters/WindowCovering.xml) | Current percent100ths/percent attributes, nullable bounds and three two-bit OperationalStatus fields | 0f1026b5a9447292bcf3cca8ce6388773109125d |
| [WindowCoveringCluster.h](https://github.com/project-chip/connectedhomeip/blob/master/src/app/clusters/window-covering-server/WindowCoveringCluster.h) | OperationalState 0=stopped, 1=opening, 2=closing, 3=reserved | fea09bcbd169eed8717a8452f0d907ee7143bc66 |
| [WindowCoveringCluster.cpp](https://github.com/project-chip/connectedhomeip/blob/master/src/app/clusters/window-covering-server/WindowCoveringCluster.cpp) | Increasing current-to-target percentage means closing | 0bd9f978489d5f9db1f45ca822a0e663f965b76b |

V0.42 functional reading names, battery/frequency conversion and lift orientation
are documented in [reading-conventions.md](reading-conventions.md); other
measurement scaling/units remain unchanged;
see also [environment-measurements.md](environment-measurements.md) and
[sensor-lifecycle.md](sensor-lifecycle.md). Source blobs identify the inspected
content; links to master may later change.

## Verification

The modeled callback/WebSocket suite remains:

```sh
prove -v t/matter_node_sync.t
```

The separate suite starts an actual FHEM process with localhost-only FHEMWEB,
loads this branch's modules and sends synthetic snapshots/reports through the
real module parsers. It exercises all 30 named types plus structural/unknown
IDs, null/invalid/zero, enums, measured/target distinctions, mixed-type
priority, user formats, repeated buttons, native notify, userReadings,
event-on-change, room/detail HTTP and longpoll, disable/offline/IO loss,
multi-IO isolation, and actual save/rereadcfg statefile loading.

CI checks out the pinned core above and runs both encodings. Locally, set
FHEM_CORE_DIR to that checkout (the directory containing its `fhem` directory):

```sh
FHEM_CORE_DIR=/path/to/fhem-mirror prove -v t/matter_display_core.t
FHEM_CORE_DIR=/path/to/fhem-mirror FHEM_TEST_ENCODING=bytestream prove -v t/matter_display_core.t
```

Without FHEM_CORE_DIR this additional suite explicitly skips; the modeled
suite remains independently executable. The integration test uses Perl JSON,
HTTP::Tiny and Compress::Zlib, with no runtime module dependency added.
No physical Matter device, external Matter server, configDB or complete OS /
FHEM process restart is tested. Existing statefile/configuration loading is
actually executed through rereadcfg, not simulated by copying device hashes.

## V0.41 completion review (historical)

A separate consistency review covered the complete new presentation policy,
the existing IO/device dispatch and attribute/read-response paths, root and
endpoint lifecycle callbacks, membership/availability mirroring, shared
setter-completion reading updates, tests/CI, README, both commandref languages,
release/updater metadata and the agent instructions. The review checked that
STATE remains presentation only and never authorizes commands or data import.
The startup override path, unicode/bytestream representation, preserved
notification arrays and reserved enum/position values were reconciled with
the actual core/protocol sources and regression cases. The central AGENTS.md
copy remains unchanged and passes its provenance check.

Validation at V0.41 completion: 1,023 modeled callback/WebSocket entries plus 181
actual-core assertions (1,204 combined), and the same 181 core assertions in
bytestream mode. Removing the default before event publication and ignoring
the user-format guard each causes the actual-core suite to fail as expected.
The real-core suite also proves native eventMap behavior and all-attribute
format deletion. Perl harness syntax, UTF-8/POD-block checks, unique module
callback names, updater manifest validation/generation regressions and shared
rule provenance checks pass. The full documented hardware/configDB/process-
restart limitations above remain; no physical compatibility claim is made.

## Readable source correction (V0.43)

The separate review against testing@da49af7f6271148f697bfe4e2d30e46fc5aef312
found three display-only interpretations: ExpressedState, AirQuality and the
covering movement bitmap. They now use the same shared attribute conversion
as the published reading. The private display enum table/closure and movement
bit decoding have been removed from DefaultState. The audit table above
records why the other default families need no semantic correction.

The review traced both module call paths for snapshots, live reports,
node_updated and explicit getConfig responses, shared validity/freshness
reconciliation, source/position selection, reading publication, user formats,
offline/disable, persisted readings and native FHEM notification. It also
reconciled tests/CI, README, both commandref languages, reading conventions,
agent guidance and version/updater metadata. Bitmap axis information is
preserved rather than silently reduced to the global movement field.

Validation: 1,025 callback/WebSocket entries, including the new 80-assertion
source/reading subtest, plus 216 actual-FHEM/FHEMWEB assertions (1,241 together).
The same 216 core assertions also pass in bytestream mode. Reading and default
are checked against explicit expected text, not just against each other;
actual notify, plain/Perl stateFormat and statefile restoration also observe
the readable reading values. All 27 valid movement bit combinations and
reserved fields are covered. Invalid live data cannot suppress a valid read,
and a later valid live enum still wins over an older response.

Returning numeric alarm values again, or discarding the movement axis fields,
causes the actual-core suite to fail as expected. Manifest generation/checks,
shared-rule provenance, Perl harness syntax and UTF-8/POD checks pass. No
additional protocol requests, timers, text aliases or derived state readings
were added. Physical Matter hardware/external server/configDB/full-process
restart limits remain as described above.
