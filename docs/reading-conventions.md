# Functional reading conventions (#91; readable default sources V0.43)

These are public interface changes. The battery names follow FHEM's agreed
battery convention; the other names combine established FHEM practice with
explicit project choices, including `brightness` for measured illuminance.
No protocol read, polling, timer or automatic configuration change is added.
Hardware validation of the changed mappings: **untested**.

## Functional data

| Reading | Source | Value |
| --- | --- | --- |
| `batteryPercent` | PowerSource BatPercentRemaining | Integer 0..100 %. Divide native 0..200 by two and round half up; 101 becomes 51. |
| `batteryVoltage` | PowerSource BatVoltage | Volts, native mV divided by 1000; 2987 becomes 2.987. |
| `batteryState` | Same-endpoint battery warnings | `ok` or `low`, without numeric percent/voltage thresholds. |
| `ct` | ColorControl ColorTemperatureMireds | Positive mireds 1..65279, matching the setter. Unknown/invalid zero does not replace a valid value. |
| `hue` / `sat` | ColorControl CurrentHue / CurrentSaturation | Native integers 0..254, neither Hue bridge 0..65535 nor degrees/percent. |
| `brightness` | IlluminanceMeasurement | Lux; raw 30001 becomes 1000 lx through the logarithmic conversion. |
| `pct` | WindowCovering current lift percentage | Percent open: 100=open, 0=closed. Hundredths divided by 100 and subtracted from 100. |
| `tilt` | WindowCovering current tilt percentage | Native 0..100 %, hundredths divided by 100, without lift inversion or angle conversion. |
| `state` | DoorLock LockState | 0=not_fully_locked, 1=locked, 2=unlocked, 3=unlatched. Door contact is separate. |
| `frequency` | ElectricalPowerMeasurement Frequency | Hz, native mHz divided by 1000; 50000 becomes 50. Range 0..1000 Hz; zero is valid. |
| `levelFrequency` | LevelControl CurrentFrequency | Native uint16 units; zero means unknown. The matching setter accepts 1..65535. |
| `alarm_expressed_state` | SmokeCOAlarm ExpressedState | normal / smoke_alarm / co_alarm / battery_alert / testing / hardware_fault / end_of_service / interconnect_smoke / interconnect_co (protocol values 0..8). |
| `air_quality` | AirQuality AirQuality | unknown / good / fair / moderate / poor / very_poor / extremely_poor (protocol values 0..6). |
| `wc_operational_status` | WindowCovering OperationalStatus | Text retaining each two-bit field, e.g. global: opening / lift: opening / tilt: closing. Field values 0/1/2 mean stopped/opening/closing; reserved 3 is rejected. |

The covering `pct` setter accepts percent **open** and sends
`(100 - pct) * 100` to Matter. Open/close commands retain their physical meaning;
`tilt` uses native tilt percentage. Percentage setters accept integers; fractional
reports retain their precision. Target positions and command acknowledgements
never become measured positions. Absolute-only devices keep explicitly labelled
raw-position display rather than invented percentages.

When both position resolutions are reported, a valid fine position wins over
coarse reports for that identity/axis, including after restoration. Null/invalid
fine reports do not downgrade it to a coarse value.

## Multiple functions on one endpoint

| Reported functions | Native LevelControl reading / setter | Dimming-percent reading / setter | Other functional readings |
| --- | --- | --- | --- |
| Dimmer | `brightness` | `pct` | None |
| Dimmer + illuminance | `level` | `pct` | `brightness` in lux |
| Dimmer + covering | `brightness` | `dimmerPct` | Covering `pct` / `tilt` |
| Dimmer + illuminance + covering | `level` | `dimmerPct` | `brightness` lux, covering `pct` / `tilt` |

The same mapping supplies setter names and widget readings. Ordinary command
capability checks remain mandatory: source metadata cannot enable a command.
A valid illuminance report establishes the lux role; valid covering attributes
or global cluster metadata establish the covering role. Report order can reveal
additional functions later, but the resulting names and units are deterministic.
Roles remain assigned once observed for this identity; omitted reports or partial
capability lists cannot repurpose a saved reading with another unit.

The hidden `.matterReadingSources` reading persists the few origins needed for
these collisions, position precision and battery warning reconciliation. FHEM
saves it through its ordinary statefile mechanism; it emits no standalone event.
It is interpretation metadata, never command permission or fresh availability.
Changing the actual IO/Matter identity clears it; rename preserves it.

When a second function appears, only a value with recorded provenance may move
to `level` or `dimmerPct`. The original measurement timestamp is retained via
FHEM's explicit `readingsBulkUpdate` timestamp argument. Notifications see the
completed batch and the correct quantities. No automatic command is sent.

## Battery health

Sources on the **same endpoint** are PowerSource BatChargeLevel (0 normal,
1 warning, 2 critical), BatReplacementNeeded (boolean), and SmokeCoAlarm
BatteryAlert (0 normal, 1 warning, 2 critical). Any known warning/replacement
request means `low`; `ok` requires at least one valid source and no known
warning. An unchanged normal source cannot hide another source's warning.

The three detailed source readings `battery_charge_level`,
`battery_replacement_needed` (0/1) and `alarm_battery` remain because they
preserve cause/severity not expressible by `ok/low`. Restored sources from this
mapping still participate in a partial update. Origin metadata prevents old
warnings from a different identity being adopted. No thresholds are inferred
from percent or voltage; these measurements alone create no `batteryState`.
There is no node-wide aggregation or cross-endpoint battery mirroring.

## Persistence and display

Source metadata and functional readings restore through FHEM's ordinary
statefile handling. Source interpretation is independent of fresh availability:
offline/unknown availability and endpoint disable continue to protect values.
ReadOnly restricts commands, not reports. A normal online snapshot/getConfig
uses the same mapping as a live event, without additional automatic reads.
Explicit user stateFormat remains authoritative.

Functional enums and the covering movement bitmap are decoded in the same pure
attribute conversion used by live reports, snapshots, getConfig and freshness
checks. Reading values, reading events and default display therefore use the
same state names. All meaningful movement fields are retained in the one
existing reading; no extra text aliases or derived state readings are created.
Invalid/null input preserves the last valid value/timestamp; valid enum zero
has its specified meaning (normal or unknown), not an inferred success state.

The central display policy from #89 uses functional readings. DoorLock has a
textual state reading; its display uses that reading. Display formatting creates
no further redundant readings or stateFormat attribute. Root state remains node
reachability.

## Evidence and verification

Inspected 2026-11-23:

- [FHEM battery convention](https://wiki.fhem.de/wiki/DevelopmentGuidelinesReadings):
  batteryState/batteryPercent/batteryVoltage; other suggestions on that page
  are explicitly distinguished from the agreed battery contract.
- Matter 1.4 data models in project-chip/connectedhomeip:
  [PowerSourceCluster.xml](https://github.com/project-chip/connectedhomeip/blob/master/data_model/1.4/clusters/PowerSourceCluster.xml)
  (blob e24b63b8a16c1a1115b475cf31df808949fc0759),
  [ColorControl.xml](https://github.com/project-chip/connectedhomeip/blob/master/data_model/1.4/clusters/ColorControl.xml)
  (f284f5a33156f478299fbc2368c73f115d9197e7),
  [LevelControl.xml](https://github.com/project-chip/connectedhomeip/blob/master/data_model/1.4/clusters/LevelControl.xml)
  (fc6fc7a8f12a6768ba75b4c149ed0393f965e16f),
  [ElectricalPowerMeasurement.xml](https://github.com/project-chip/connectedhomeip/blob/master/data_model/1.4/clusters/ElectricalPowerMeasurement.xml)
  (1dcc420d7a8f2d229ab09acb7254c8e2235330e6).
  These establish numeric bounds, enums and attribute identity. DoorLock,
  SmokeCoAlarm and WindowCovering enum/direction evidence is also recorded in
  [endpoint-display.md](endpoint-display.md).
- Manufacturer descriptions:
  [PowerSource](https://developers.home.google.com/reference/kotlin/com/google/home/matter/standard/PowerSourceTrait.Attributes),
  [ElectricalPowerMeasurement](https://developers.home.google.com/reference/kotlin/com/google/home/matter/standard/ElectricalPowerMeasurementTrait.Attributes),
  [LevelControl](https://developers.home.google.com/reference/kotlin/com/google/home/matter/standard/LevelControlTrait.Attributes).
  Electrical Frequency is mHz; LevelControl describes an independent native
  frequency value with no SI scaling specified in these inspected definitions.
  It is therefore explicitly kept in native units, without claiming Hz or 10 Hz.
- FHEM core pinned at 8b257af4a681169a4162610b158ca6d4d103d489:
  `readingsBulkUpdate` accepts an optional explicit measurement timestamp;
  dot readings are silent by default; `readingsDelete` removes a reading without
  its own event. Reading batches evaluate userReadings/stateFormat before
  normal notification. The actual-core suite checks this behavior.

The callback/WebSocket suite covers conversions, warnings, invalid data,
source ordering, mixed controls, snapshots/getConfig, offline/disable and
identity invalidation. The actual-core/FHEMWEB suite checks reading/event names,
coherent notification values, original timestamps during source relocation,
user formats, and actual save/rereadcfg restoration of hidden source metadata.
Both unicode and bytestream modes are tested. See CI and endpoint-display.md
for reproducible commands. Synthetic reports are used; physical Matter devices,
external server integration, configDB and a full process/OS restart are untested.

## Implementation review record

The separate consistency pass traced both modules' dispatch, shared pure
attribute validation/freshness reconciliation, snapshot/getConfig/live routing,
source interpretation, battery aggregation, position priority, identity and
availability invalidation, dynamic setters/widgets, central display and
FHEM callbacks. It reconciled affected tests, CI, README, DE/EN commandref,
agent guidance and updater/release metadata. Boolean replacement-needed
validation was consolidated into the existing shared boolean path during
review; no second numeric/boolean conversion exception remains.

Validation at V0.42 completion: 1,024 callback/WebSocket entries (including a 67-assertion #91
subtest) plus 202 actual-core assertions; the same 202 core assertions also
pass in bytestream mode. Removing electrical frequency scaling or merging
lux with native level causes the corresponding tests to fail as expected.
Both test files pass Perl syntax checks; both modules successfully load in the
actual FHEM process. Standalone module perl -c without FHEM globals/HttpUtils
context is not an independent supported syntax check. UTF-8, unique callbacks,
DE/EN commandref blocks, updater manifest generation/staleness regressions and
the pinned shared-rule provenance check pass. The physical/server/configDB/full
process-restart limitations stated above remain.
