# Device limits: protocol evidence and V0.21 transition

Inspected 2026-11-19. This change covers ten previously auto-created FHEM
attributes, not Matter capability/command overrides. The ten obsolete AttrList
entries remain temporarily to load old configurations without unknown-attribute
errors. They have no runtime effect. No existing values are copied to readings
or deleted; users can review and remove saved values manually. This is a
behavior change for installations with manual overrides or AttrVal automation.

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
frequency requires positive ordered bounds. Missing bounds retain advertised
commands with text input rather than inventing device-specific slider ranges.
Valid stored readings may be used before runtime AttributeList restoration;
a subsequently advertised AttributeList and feature metadata take precedence.
Neither cached readings nor server snapshots prove fresh physical contact.
During snapshot quarantine, only an accepted CurrentLevel report recalculates
percentage. Limit or metadata recovery must not derive physical state from
cached brightness or overwrite a manual percentage edit.

## Verification scope

`t/matter_node_sync.t` models actual IO dispatch to roots/endpoints, reported
updates, obsolete configuration loading, metadata rebuild, commands/payloads,
Lighting versus generic MaxLevel, invalid data, missing/reversed ranges,
endpoint isolation, offline quarantine and subsequent live recovery.
Reading persistence is modeled by retaining READINGS while rebuilding helper
metadata; no actual FHEM restart, configDB, browser or device hardware test is
claimed. The change adds no polling, recovery timer or automatic physical read.
