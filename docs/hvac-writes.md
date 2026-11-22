# HVAC commands and write responses (#33, V0.25)

## Device model and command policy

Only locally mapped standard writable attributes, actually present in the
endpoint AttributeList, authorize these setters. Heating/cooling setpoints
add their corresponding FeatureMap condition. Attribute presence does not
prove controller ACL permission or acceptance of a specific value.

| Command | Standard target | Additional selection |
| --- | --- | --- |
| desired-temp | Thermostat OccupiedHeatingSetpoint (18) | Heating feature |
| desired-temp-cool | Thermostat OccupiedCoolingSetpoint (17) | Cooling feature |
| mode | Thermostat SystemMode (28) | FeatureMap plus ControlSequenceOfOperation (27) |
| fan_mode | FanControl FanMode (0) | FeatureMap plus FanModeSequence (1) |
| fan_pct | FanControl PercentSetting (2) | PercentCurrent (3) alone never authorizes a write |

Temperature commands accept Celsius with up to two decimals, encoded as
centidegrees in the protocol domain -273.15 through 327.67. These are text
inputs rather than the previous arbitrary 5–30 slider. Device-specific
temperature limits remain server/device constraints; a write outside them
must not be shown as successful when the device refuses it.

Thermostat control sequences 0/1 exclude heating modes; 2/3 exclude cooling;
4/5 permit both, subject to Heating/Cooling features. Auto additionally needs
AutoMode. The existing optional emergency_heat choice remains limited to
heating-compatible configurations; metadata cannot guarantee support for
every optional SystemMode enum. Device rejection remains authoritative.

FanModeSequence defines its off/low/medium/high/auto subset. Auto additionally
needs its feature bit. Deprecated On (enum 4) is no longer offered as a write;
use an offered speed such as high instead. Existing reported enum decoding
is retained. PercentSetting and PercentCurrent stay separate readings.

Mode sequence values are validated and kept in the existing endpoint capability
cache, not inferred from the current physical mode. Missing metadata hides
the mode control; partial/malformed reports preserve earlier valid metadata.
Normal supplied snapshots or explicit getConfig on the affected endpoint
obtain the sequences. Full configuration replies reconcile removed metadata;
newer valid sequence reports supersede older discovery/read data. There are
no new probe requests or timers. Existing bounded global-metadata recovery
also notices missing FeatureMap when an advertised HVAC setter needs it;
it does not start reading physical values or sequence attributes automatically.

Identify remains an AcceptedCommandList-gated command with a 15-second payload.

## Correlated response policy

Writes retain request-ID, FUUID and IO ownership checks. Pending writes now
record the exact requested endpoint/cluster/attribute path. For these unicast,
single-attribute writes, a status list must contain exactly one matching Path
with a valid Status. Only Status 0 clears lastError; nonzero Status is reported
as failed, including a supplied ClusterStatus. Missing, malformed, empty,
duplicate or mismatched results do not claim success.

The previously accepted null result remains an API acknowledgement. It is
not a physical-state confirmation and contains no per-device status. Both
acknowledgement forms leave setpoint/mode/speed readings untouched; only
device telemetry updates them. Timeout/disconnect retain an unknown outcome,
and replies with removed correlation IDs cannot turn that into success.

## Primary evidence

Inspected 2026-11-22:

- [Matter 1.4 Thermostat](https://github.com/project-chip/connectedhomeip/blob/master/data_model/1.4/clusters/Thermostat.xml),
  content blob `257171beeb90c2d3d3596a5b170e4a6e2c4f3fa6`: writable targets,
  Heating/Cooling/AutoMode, SystemMode and ControlSequenceOfOperation.
- [Matter 1.4 FanControl](https://github.com/project-chip/connectedhomeip/blob/master/data_model/1.4/clusters/FanControl.xml),
  content blob `d9339163bc93f515f516684d79661daa4822ebaa`: FanModeSequence,
  Auto, writable FanMode/PercentSetting and read-only PercentCurrent.
- [OHF WebSocket API](https://github.com/matter-js/matterjs-server/blob/fc8aa79611aebbe3090a30813e7211f707b2131f/docs/websockets_api.md)
  and [write handler](https://github.com/matter-js/matterjs-server/blob/fc8aa79611aebbe3090a30813e7211f707b2131f/packages/ws-controller/src/server/WebSocketControllerHandler.ts):
  Path/Status response list, optional ClusterStatus, constraints and access
  refusals returned as Matter status.
- [Python server SDK wrapper](https://github.com/matter-js/python-matter-server/blob/4c820ed12bac349dda372031e9757c67b9fd9048/matter_server/server/sdk.py)
  types write results as a list or None; its
  [controller handler](https://github.com/matter-js/python-matter-server/blob/4c820ed12bac349dda372031e9757c67b9fd9048/matter_server/server/device_controller.py)
  also returns None for imported test nodes. Null support preserves the prior
  FHEM contract; this inspection does not prove hardware success for null ACKs.

The installed server revision was not matched to these upstream revisions.
Existing FHEM callbacks, asynchronous SetFn synthetic-event suppression and
reading APIs are reused; the source-backed core contracts are recorded in
AGENTS.md and the prior lifecycle evidence document.

## Verification and remaining limits

The actual module parsers/setters are exercised with modeled FHEM callbacks
and socket-backed IO fixtures. Coverage includes heating/cooling/combined
devices, all six standard mode sequences, missing metadata and feature bits,
read-only fields, unsupported explicit commands, centidegrees, write status
and path validation, metadata replacement/late replies, timeout/disconnect,
same-node multi-IO isolation and report-only physical readings.

No physical thermostat, fan or Identify device, real FHEM/configDB process or
live Matter-server connection was exercised. Hardware is **ungetestet / untested**.
No generic attribute-writing UI, optional mode discovery protocol, schedules,
controller logic or automatic retries are added.
