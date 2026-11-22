# Native LevelControl dimming (#34, V0.26)

## Commands and device behavior

| FHEM command | Preferred Matter command | Advertised alternative | Fields besides zero OptionsMask/OptionsOverride |
| --- | --- | --- | --- |
| dim_up | Move (1) | MoveWithOnOff (5) | moveMode 0, rate dimRate |
| dim_down | Move (1) | MoveWithOnOff (5) | moveMode 1, rate dimRate |
| dim_step_up | Step (2) | StepWithOnOff (6) | stepMode 0, stepSize 20, transitionTime 0 |
| dim_step_down | Step (2) | StepWithOnOff (6) | stepMode 1, stepSize 20, transitionTime 0 |
| dim_stop | Stop (3) | StopWithOnOff (7) | no additional fields |

All commands address the current endpoint's LevelControl cluster (8) and take
no FHEM arguments. `dimRate` retains its existing policy: integer 1–254,
default 30, native level units per second. It is checked only for continuous
Move, so an invalid Move rate cannot prevent Stop or Step. Step size is 20
native units, not 20 percent. The device applies its own level limits.

Menus and direct setters use AcceptedCommandList and the existing command
support checks. MoveToLevel support does not imply Move, Step or Stop. If
both variants are advertised, the regular variant wins; WithOnOff can also
affect switching. Zero option mask/override leaves device options in effect;
regular dim commands may therefore leave a switched-off light unchanged.
These six commands have no additional feature prerequisite in the inspected
Matter 1.4 cluster definition; no guessed OnOff feature gate is added.

## Responses and failure semantics

These commands use the [shared device request path](device-requests.md),
exactly like on/off, colors, coverings, locks, Identify and attribute writes.
Each request remains independently correlated until response/timeout/IO loss.
A pending Move does not block Stop. Only the latest setter changes lastError;
older replies are still handled and retired, without overwriting that result.
A successful reply acknowledges the command. Physical state/brightness/pct require
actual device reports. No persistent motion flag, polling, extra timer, replay
or automatic Stop is added.

## Inspected sources, 2026-11-22

- [Matter 1.4 LevelControl definition](https://github.com/project-chip/connectedhomeip/blob/master/data_model/1.4/clusters/LevelControl.xml),
  revision 6: command IDs, direction enums, option fields and mandatory
  conformance. The [CHIP ZAP command definitions](https://github.com/project-chip/connectedhomeip/blob/master/src/app/zap-templates/zcl/data-model/chip/level-control-cluster.xml)
  include the WithOnOff payload fields omitted by the compact data model XML.
- OHF matterjs-server at `fc8aa79611aebbe3090a30813e7211f707b2131f`:
  [ControllerCommandHandler](https://github.com/matter-js/matterjs-server/blob/fc8aa79611aebbe3090a30813e7211f707b2131f/packages/ws-controller/src/controller/ControllerCommandHandler.ts)
  throws on a non-success command status and returns no data on status success;
  [WebSocketControllerHandler](https://github.com/matter-js/matterjs-server/blob/fc8aa79611aebbe3090a30813e7211f707b2131f/packages/ws-controller/src/server/WebSocketControllerHandler.ts)
  converts absent command response data to null and preserves request IDs.
  The [WebSocket API](https://github.com/matter-js/matterjs-server/blob/fc8aa79611aebbe3090a30813e7211f707b2131f/docs/websockets_api.md)
  describes device_command errors and payloads.
- The inspected [Python server handler](https://github.com/matter-js/python-matter-server/blob/4c820ed12bac349dda372031e9757c67b9fd9048/matter_server/server/device_controller.py)
  forwards send_command responses; imported test nodes return None. This is
  not a hardware compatibility test of the Python SDK or installed server.
- Existing FHEM callback/reading contracts are recorded in AGENTS.md and
  [lifecycle evidence](offline-lifecycle.md). Relevant DoSet behavior was
  inspected in fhem/fhem-mirror at `5544e24cc71f2e3cebd786001778fe18eea5e62e`:
  SetFn runs in list context and a true second return suppresses its synthetic
  event. The installed FHEM/server revision was not matched to these sources.

## Verification and limits

The full suite passes 888 top-level entries, including 170 focused native
variant/lifecycle assertions and 249 shared request assertions. Modeled FHEM
callbacks exercise real module setters/parsers, socket-backed IOs and an
injected WebSocket response. Tests cover regular/WithOnOff preference,
partial/replaced command lists, exact payloads, argument/rate rejection and
boundaries, Move followed immediately by Stop, delayed/malformed/error replies,
failed enqueue, timeout, reconnect, endpoint/IO isolation and report-only state.
All-setter correlation and compound RGB results are documented separately.
No physical dimmable device, running FHEM/configDB or installed Matter server
was exercised. Hardware behavior remains **ungetestet / untested**.
