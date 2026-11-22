# Environmental measurement acceptance evidence (#32)

Checked on 2026-11-22 against existing
[`testing@7658b00`](https://github.com/Flachzange/fhem-matter-fork/tree/7658b007e514c480b3fd2f9f78b240d14d5ca591),
V0.24. The new tests pass without changes to either module. This work adds
tests/documentation only, with no new module version or updater bytes.

## Covered readings

| Cluster | Reading | Presentation exercised |
| --- | --- | --- |
| PressureMeasurement (0x0403) | pressure | Existing hPa presentation; integer raw MeasuredValue retained, e.g. 1013 -> 1013. |
| CarbonDioxideConcentrationMeasurement (0x040D) | co2, co2_unit | Raw numeric value plus supplied unit; ppm and mg/m3 exercised independently. |
| Pm25ConcentrationMeasurement (0x042A) | pm25, pm25_unit | Raw decimal value plus supplied ug/m3. |
| TotalVolatileOrganicCompoundsConcentrationMeasurement (0x042E) | tvoc, tvoc_unit | Raw decimal value plus supplied ppb. |

Concentration values are not converted to an assumed unit. In particular,
0.75 with unit mg/m3 remains 0.75 mg/m3, not a manufactured ppm value. A
measurement may arrive before its unit; until a valid unit is supplied, no
unit reading is created. An invalid unit does not erase the last valid unit
or refresh its timestamp. Measurement and unit readings retain their own
last-valid-report semantics; these tests do not establish fresh physical data.

## Acceptance matrix

The focused `Issue 32: environmental values, units and optional numeric
measurements` subtest uses the real module JSON dispatch and parser paths.

| Case | Verified behavior |
| --- | --- |
| Initial snapshot | All four measurements and supplied units map to separate endpoints. |
| Online snapshot with explicit zero | Each zero is accepted as a numeric measurement. |
| Live values | Each report updates its intended endpoint; sibling readings/units retain values, timestamps and write counts. |
| node_updated without repeated FeatureMap | Supplied measurements update normally without another metadata report. |
| Null, negative concentration, malformed or omitted data | Last valid values are preserved without additional reading writes. |
| Pressure boundaries | Null sentinel -32768, fractional values and out-of-int16 values are ignored; -32767/32767 are retained as type-boundary examples. |
| Missing, unknown or null initial unit | No implicit ppm or other unit is generated. |
| Unit before/after value | The provided unit is retained; a unit alone does not create a numeric zero or rewrite the measured value. |
| Qualitative-only CO2, PM2.5 and TVOC | FeatureMap LEV plus LevelValue creates neither a numeric concentration nor a measurement unit. |
| Outbound traffic | Fixture sends no extra read/command requests. |

The qualitative cases supply FeatureMap bit 1 and attribute 10 only. They
verify that a missing numeric MeasuredValue is not invented; they do not add
or claim a generic FeatureMap-based rejection of otherwise supplied values.
No new level-reading feature, conversion engine or polling is introduced.

## Source evidence and limits

Matter 1.4 data-model definitions inspected 2026-11-22:

- [ConcentrationMeasurement.xml](https://github.com/project-chip/connectedhomeip/blob/master/data_model/1.4/clusters/ConcentrationMeasurement.xml),
  content blob `4a699cce0b7a27753332ae49eb720333d638317a`: cluster IDs,
  NumericMeasurement/LevelIndication bits, numeric attribute 0, unit attribute
  8, LevelValue attribute 10 and the relevant MeasurementUnitEnum values.
- [PressureMeasurement.xml](https://github.com/project-chip/connectedhomeip/blob/master/data_model/1.4/clusters/PressureMeasurement.xml),
  content blob `c9d657a1df8d82d01eff354801d24b77df82c22f`:
  cluster 0x0403 and nullable int16 MeasuredValue. The tests exercise the
  module's existing hPa presentation and type validation; they do not validate
  physical device accuracy or sensor-specific Min/MaxMeasuredValue limits.

FHEM functions are modeled by the existing test harness. Reading write counts
are checked in addition to values/timestamps because its clock is fixed.
Socket pairs supply the modeled active connection; no real FHEM event loop,
Matter server, sensor hardware or configDB is exercised. Hardware status
remains **ungetestet / untested**, as in the unchanged German/English commandref.
