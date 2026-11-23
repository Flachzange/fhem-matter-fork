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
