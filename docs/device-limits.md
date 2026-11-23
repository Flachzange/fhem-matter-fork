# Device limits: protocol evidence and V0.21 transition

Inspected 2026-11-19. This change covers ten previously auto-created FHEM
attributes, not Matter capability/command overrides. All ten declarations are
removed from AttrList without compatibility or automatic migration. No existing
values are copied to readings or deleted by the module. Review manual overrides
and AttrVal automation before updating.

## Configuration cleanup before restart

Before restarting into V0.21, save any old settings needed for reference, remove
the ten attributes and save the configuration. FHEM may reject saved attribute
lines during startup otherwise. Execute each line separately in the **FHEM
command line**, not in the DEF editor or a shell:

```text
deleteattr TYPE=MATTERDevice (color_temp_(min|max)|(min|max)_(brightness|frequency|pin_code_length|rfid_code_length))
save
```

The native `deleteattr` command accepts a device specification and an attribute
regular expression. This expression matches exactly the ten retired names on
MATTERDevice devices; it does not remove readings or other attributes. Verified
against `fhem/fhem-mirror` `fhem/fhem.pl`, blob
`07b16fbc7fc14fe95553b1b365f5bdb398220817`, inspected 2026-11-19:
`CommandDeleteAttr` expands `devspec2array`, invokes `AttrFn` before deletion,
anchors the attribute expression and emits the normal configuration-change
events. `save` persists the cleanup for file-based configuration or configDB.
There is no module-side loading alias, copying or automatic deletion.

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

Since V0.42, the controlled frequency reading/setter is `levelFrequency` in native
units. `frequency` is reserved for the electrical measurement in Hz. Dimmer
percent uses `level` on mixed illuminance endpoints and `brightness` otherwise;
`dimmerPct` separates dim percent from covering percent. See
[reading-conventions.md](reading-conventions.md) for the complete interface transition.
