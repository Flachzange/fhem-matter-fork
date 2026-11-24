# Device limits: protocol evidence

Endpoint limit readings come from validated Matter reports and snapshots.
They are not local command permissions or configurable device-limit overrides.

## Protocol evidence

- [Matter Application Cluster Specification 1.4.2](https://csa-iot.org/wp-content/uploads/2025/08/3-27350_matter-1-4-2-adopted-application-cluster-specification.pdf),
  sections 1.6.4.2, 1.6.6 and 3.2.7.20–21: Lighting uses levels 1..254;
  generic MaxLevel is an optional read-only uint8 with fallback 254.
  MinFrequency/MaxFrequency are read-only uint16 data for the Frequency feature;
  numerical zero is undefined. ColorTempPhysicalMinMireds/MaxMireds are
  read-only CT hardware limits in mireds (maximum 65279).
- [DimmableLight model](https://github.com/project-chip/connectedhomeip/blob/master/data_model/1.4/device_types/DimmableLight.xml)
  explicitly constrains MaxLevel to 254.
- [DoorLock model](https://github.com/project-chip/connectedhomeip/blob/master/data_model/1.4/clusters/DoorLock.xml)
  declares PIN/RFID min/max lengths as read-only uint8 values. The
  [CSA 1.3 specification](https://csa-iot.org/wp-content/uploads/2024/05/matter-application-cluster-specification.pdf),
  sections 5.2.9.16–19, specifies byte lengths; no local credential policy or
  credential-management operation is inferred from these properties.

The module accepts integer report values within its declared parameter ranges
and retains last valid readings on malformed/null reports. A usable scale
requires a positive maximum. CT requires a positive minimum and ordered bounds;
levelFrequency requires positive ordered bounds. Missing bounds retain advertised
commands with text input rather than inventing device-specific slider ranges.
Valid stored readings may be used before runtime AttributeList restoration;
a subsequently advertised AttributeList and feature metadata take precedence.
Neither cached readings nor server snapshots prove fresh physical contact.
Since V0.23, unknown/offline availability blocks reports and protects local
values. A valid online report resumes ordinary snapshots and explicit reads.
Accepted online level, limit and metadata updates may recalculate percentage
from the reported native dimmer level; there is no persistent snapshot quarantine.

## Verification scope

`t/matter_node_sync.t` models actual IO dispatch to roots/endpoints, reported
updates, rejection of all ten removed attributes, metadata rebuild, commands/payloads,
Lighting versus generic MaxLevel, invalid data, missing/reversed ranges,
endpoint isolation, offline protection and online snapshot/live recovery.
Reading persistence is modeled by retaining READINGS while rebuilding helper
metadata; no actual FHEM restart, configDB, browser or device hardware test is
claimed. The change adds no polling, recovery timer or automatic physical read.

The controlled frequency reading/setter is `levelFrequency` in native
units. `frequency` is reserved for the electrical measurement in Hz. Dimmer
percent uses `level` on mixed illuminance endpoints and `brightness` otherwise;
`dimmerPct` separates dim percent from covering percent. See
[reading-conventions.md](reading-conventions.md) for the complete interface transition.
