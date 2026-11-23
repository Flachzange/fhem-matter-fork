# Sensor acceptance evidence (#30)

The remaining acceptance check was performed against the existing
[`testing@24ea05c` implementation](https://github.com/Flachzange/fhem-matter-fork/tree/24ea05cfd20f6712e20610d038b38a20d8c7cad8),
V0.24, on 2026-11-22. The added regression passes without changes to either
module. There is no module release, updater change or migration in this work.

## Covered mappings

The table records modeled module output, not physical-device validation.

| Device/cluster | Reading | Representative input and expected output |
| --- | --- | --- |
| Contact / BooleanState | contact and endpoint state | true -> closed; false -> open |
| Water leak / BooleanState | water_leak and endpoint state | true -> leak; false -> dry |
| Rain / BooleanState | rain and endpoint state | true -> rain; false -> dry |
| OccupancySensing | motion and endpoint state | 3/5 -> motion; 2 -> nomotion (bit 0) |
| TemperatureMeasurement | temperature | 2234 -> 22.34; -550 -> -5.5 |
| RelativeHumidityMeasurement | humidity | 4350 -> 43.5; 0 -> 0 |
| IlluminanceMeasurement | brightness (lux) | 30001 -> 1000; 20001 -> 100; 0 -> 0 |
| Unknown device type / BooleanState | boolean_state | Generic 1/0; no inferred contact reading |

## Lifecycle acceptance matrix

The `Issue 30: persisted sensors follow the shared availability lifecycle`
subtest in `t/matter_node_sync.t` uses the actual IO/device parsers and modeled
FHEM callbacks. Its fixture includes eight endpoints and two IO devices with
the same node ID. A root and its contact endpoint are renamed before the
restoration/recovery checks.

| Case | Expected and verified behavior |
| --- | --- |
| Initial online discovery | Descriptor types are applied before values; all sensor mappings are populated. |
| IO loss | Manual sensor readings and binary endpoint states are retained. |
| Modeled restoration / INITIALIZED | Saved readings and device types survive rebuilt runtime helpers; root status is unknown. |
| Initial snapshot with absent/null/false availability | Manual values, saved timestamps and write counters remain unchanged. |
| Valid online node_updated | Its supplied values replace manual corrections without requiring separate attribute events. |
| Device type omitted after restoration | Persisted type still maps BooleanState to contact/leak/rain rather than guessing from names. |
| Online null/invalid/omitted values | Existing readings and timestamps are retained without extra writes. |
| Live sensor reports | Values reach the correct endpoint; sibling endpoints and the other IO retain their readings. |
| Offline live reports and node_updated | Manual corrections remain unchanged for every covered sensor. |
| Offline -> online | Normal snapshot synchronization resumes for every sensor. |
| REREADCFG | Data remains protected until valid availability is reported again. |
| Renamed root/endpoint | Existing device identity is preserved. |
| Another IO with the same node ID | Sensor readings and their write counts remain isolated throughout. |
| Outbound traffic | Supplied data is sufficient; no additional reads or commands are sent by this fixture. |

The common reading stub uses a fixed timestamp. The fixture therefore checks
write counters in addition to retained values and explicit saved timestamps;
an unwanted rewrite cannot pass merely because the timestamp text is equal.
The shared availability policy and source inspection are documented in
[offline-lifecycle.md](offline-lifecycle.md).

## Scope and limits

Restoration is modeled by retaining device hashes/readings and rebuilding
runtime helpers before invoking INITIALIZED. REREADCFG uses the real module
callback. The test does not execute FHEM's configuration/statefile loader,
configDB, a process restart, a real event loop or a Matter-server connection.
Socket pairs establish the modeled active IO state; sensor payloads enter
through the real JSON parsers, not via physical sensor transmissions.

No physical contact, leak, rain, occupancy or measurement device was tested.
Hardware status remains **ungetestet / untested**, as already stated in the
German/English commandref. This acceptance check needs no further runtime
logic and makes no new guarantee about the freshness of the server's data.

V0.42 renames the illuminance reading to brightness; mixed dimmer sources use level.
See [reading-conventions.md](reading-conventions.md) for source provenance and upgrade behavior.
