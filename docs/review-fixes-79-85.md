# Sequential review fixes (#79–85)

Base: `testing@9ddec223b47b1f6d93133a07577400cfc814987b` (V0.39).
One fix branch; each issue is implemented and critically reviewed before the
next issue. No merge or live hardware validation is implied.

## #79: identity ownership

Actual IO-instance, node-ID and endpoint-ID changes invalidate runtime
capabilities, OTA offers/targets and pending owner operations. Saved metadata
which authorizes control or interpretation (device types, ICD permission,
software version and reported limits) is discarded for the new identity.
Physical readings such as state, model and measurements, FUUID, local readOnly
and disable policy remain. IO/device rename and unchanged/legacy DEF confirmation
do not change identity. Occupied root targets are checked before modifying state.

The FHEM AttrFn-before-commit, Modify rollback and Rename ownership contracts
were checked against the core sources recorded in AGENTS.md and the prior
review (`fhem/fhem-mirror@5544e24cc71f2e3cebd786001778fe18eea5e62e`).
No new FHEM interface is assumed; no match to an installed revision is claimed.

Post-implementation review traced Define/Attr/Notify, autocreate temporary IO
assignment, read/command registration, OTA/ICD gates and rename/rebind through
both modules. It found and fixed cancellation of another root's read during
temporary auto-assignment, and cleared persisted control metadata which could
otherwise authorize or scale controls for the new identity.

Verification: new identity regression failed on the base; full callback suite
passes 1,015 top-level entries after the fix. Existing readOnly/disable,
availability, IO separation and request tests remain active. Tests model FHEM
callbacks and server responses; no live FHEM/configDB restart, hardware or
firmware installation was performed.

## #80: partial attribute reads

Removed the full capability-cache reset. A successful read can omit individual
failed paths, so missing values are not a revocation. Valid empty metadata
lists still replace old entries. A valid Descriptor.ServerList is authoritative
for cluster removal at every endpoint; explicit getConfig includes this list.
Newer lists are applied after old cluster data in both read and discovery
reconciliation, with endpoint-disable exclusions applied last.

Protocol evidence: matterjs-server
`fc8aa79611aebbe3090a30813e7211f707b2131f`,
[handleReadAttributes](https://github.com/matter-js/matterjs-server/blob/fc8aa79611aebbe3090a30813e7211f707b2131f/packages/ws-controller/src/controller/ControllerCommandHandler.ts#L1420)
collects values and omits per-path attr-status failures;
[WebSocket handler](https://github.com/matter-js/matterjs-server/blob/fc8aa79611aebbe3090a30813e7211f707b2131f/packages/ws-controller/src/server/WebSocketControllerHandler.ts#L1497)
accepts a nonempty result. This changes the full-read assumption in #60.

Post-implementation review traced every metadata path, root ICD/OTA removal,
HVAC modes, readOnly/disable and delayed snapshots through both modules and
their tests/docs. It extended the existing root-list ordering to all endpoints
and fixed replay of a reconciled endpoint list after disable/re-enable.
Two old fixtures were corrected: recovery must actually have missing metadata,
and a root ServerList advertising Identify must include that cluster.

The new partial-read regression and changed omission expectation failed before
the fix. The full suite passes 1,016 top-level entries, including explicit
revocation, malformed/omitted metadata, delayed lists and disable exclusion.
No live server/device test was performed.
