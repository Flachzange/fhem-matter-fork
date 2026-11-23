# Sequential review fixes (#79–85)

Base: `testing@9ddec223b47b1f6d93133a07577400cfc814987b` (V0.39).
One fix branch; each issue is implemented and critically reviewed before the
next issue. No merge or live hardware validation is implied.

## #79: identity ownership

Actual IO-instance, node-ID and endpoint-ID changes invalidate runtime
capabilities, OTA offers/targets and pending owner operations. Saved metadata
which authorizes control or interpretation (device types, ICD permission,
software/specification versions and reported limits) is discarded for the new identity.
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

## #81: explicit read ownership

Explicit reads now retain the owner hash/FUUID and use the same stable
RequestOwner check as device commands. Results are scoped to the requested
endpoint; root reads remain endpoint-zero reads. Per-message owner validation
also stops the remaining paths if synchronous reading notifications replace
or rebind the requester. Renaming the same instance remains valid.

The existing disable cancellation was shared with Undef and identity changes:
owner requests are cancelled and old shared replies exclude the endpoint.
Root-FUUID and availability-epoch checks remain separate evidence. No new
persistent generation or timeout mechanism was introduced.

Post-implementation review traced both explicit and automatic read senders,
receive internals, public ParseFn, owner completion, registry cleanup and the
readOnly/disable paths. Tests independently restore an old cancelled entry to
exercise the ownership guard and force replacement on the first Descriptor
reading before other reply paths. The new regression failed before the fix;
the full suite passes 1,017 top-level entries. No live FHEM/configDB/hardware
test was performed.

## #82: shared acceptance rules

AttributeValue is a pure conversion of supplied data, shared by pending-path
freshness and publication. It reuses the mapping table's transforms/ranges,
ID-list parsing, Descriptor type parsing and network/diagnostic mappings.
Unknown/raw values retain their independent schema; no generic numeric rule
is applied to them. Global metadata publication returns its accepted value,
including zero and empty sets, for root capability derivation.

Post-implementation review traced live, node_updated, discovery, explicit
read and automatic metadata paths, including compound Descriptor updates,
ICD and diagnostic opt-in. It removed redundant validation before checking
whether requests are pending and avoided autovivifying unknown clusters in
the static mapping table. Diagnostic mapping is pure; opt-in and writes stay
in its publisher. Nested energy validation remains the separate next issue.

The new six-sensor/limit/unit matrix failed before the fix for both live event
forms and discovery. After the fix all 1,018 top-level entries pass, including
pure/no-side-effect checks, valid-newer precedence, unrelated response values
and invalid diagnostic masking. No live FHEM/hardware validation is claimed.

## #83: nested energy integers

The energy transform validates its named/TLV inner value as a decimal integer
before arithmetic. It accepts zero and bounds to the EnergyMeasurementStruct
range 0..2^62 mWh. Decimal length/lexical comparison rejects overflow without
requiring a new dependency or relying on floating-point boundary rounding.
The existing division to kWh is retained; this does not add arbitrary-precision
output or rewrite historical data.

Source inspected 2026-11-23:
[Matter 1.4 ElectricalEnergyMeasurement](https://github.com/project-chip/connectedhomeip/blob/master/data_model/1.4/clusters/ElectricalEnergyMeasurement.xml),
content blob `fc56b5171700f8ee0f647f8913186192a4e776a4`, EnergyMeasurementStruct.
The server's generated ElectricalEnergyMeasurement.py at
`fc8aa79611aebbe3090a30813e7211f707b2131f` also represents the inner energy
field as an integer. No installed server revision is inferred.

Post-implementation review traced both field names, numeric boundaries, pure
conversion, pending-read freshness and offline/endpoint isolation. It replaced
a weak maximum-boundary assertion with actual write-count/value checks.
The new negative control failed before the fix; all 1,019 top-level entries
pass after it, including malformed outer/inner data and warning capture.
No physical meter, live FHEM or database migration was exercised.

## #84: single event endpoint lookup

The IO resolves only the root and forwards the decoded event. The device
path validates the event envelope, resolves the addressed endpoint once and
records root/endpoint reception before Switch-specific filtering or writes.
Unmapped events still count; unknown endpoints are not autocreated.

Post-implementation review traced both parser entry points and all early
returns, disabled endpoints, invalid multi-press payloads, repeated events
and receive-before-notify ordering. No new persistent cache, index or timer
was introduced. README/DE-/EN-commandref reception semantics remain applicable;
there is no new public control or changed event vocabulary to document.
The new instrumented regression failed before the change; all 1,020 top-level
entries pass after it. The measured claim is one global lookup instead of two
per valid event, not a real-world latency or hardware benchmark.

## #85: one internal read-request representation

Removed the scalar pending_config branch and its redundant hash checks. Both
production writers already register structured requests: explicit getConfig
with its device owner and automatic metadata recovery with root/epoch scope.
The unrelated mixed pending_command registry and external JSON shape checks
retain their type guards.

Post-implementation review searched every registry writer, reader and cleanup
path. The remaining no-owner endpoint-specific cancellation fallback had no
producer either and was removed. The old scalar metadata test now sends an
actual getConfig request; response fixtures include the owner, FUUID, epoch
and timestamp appropriate to their explicit or automatic request type.
All 1,021 top-level entries pass, including read errors, empty responses,
reception accounting, freshness, cancellation and identity changes. This is
an internal simplification with no new public option or migration, so README
and commandref need no further behavior description.

## Combined final review

Re-read the affected lifecycle, registration/cancellation, response routing,
capability/command gates, mapping/conversion, reception and event paths in
both modules, their callers and the existing/new regression fixtures. Reviewed
README, both commandref languages, current-release notes, manifest generation,
CI workflows and both AGENTS documents for consistency. Shared rules and
project supplement are unchanged.

This pass found one further #79 defect: a new ICD FeatureMap could combine
with the previous identity's persisted specification_version to publish an
incorrect LIT capability. Identity invalidation now also removes that version.
The added negative control failed before this correction; the new device's
own specification report still derives LIT normally afterwards.

Final verification: all 1,021 top-level entries of matter_node_sync.t pass,
Perl test-harness syntax is valid, make_controls.sh --check and manifest
generation tests pass, and git diff --check is clean. The harness loads both
module sources with modeled FHEM/HttpUtils callbacks; this is not a standalone
syntax/integration check with an installed FHEM core. No live FHEM, configDB
restart, physical device/firmware operation, or server-version compatibility
matrix was exercised. No transport or server implementation was changed.

## Follow-up: structural revocation during automatic recovery

A newer live ServerList was reconciled into automatic replies but ignored by
the metadata-only consumer. That consumer now applies structural lists last,
using the existing attribute publisher. It still ignores physical values.
Reviewed IO reconciliation, metadata application, explicit-read ordering and
disable exclusions. Regression covers actual offline/online-triggered recovery,
revocation, useful sibling metadata and rejection of physical reply values.
All 1,022 top-level tests pass; no live hardware validation.

## Follow-up: cancellation during explicit reply publication

An explicit reply stays temporarily reachable in the existing pending_config
registry while its attributes publish synchronous FHEM events. A localized
processing flag rejects reentrant duplicate delivery. Cancellation marks the
active request itself; the existing per-path owner check then stops its
remainder even after disable/enable of the same device. Perl local removes
the temporary registration on every scope exit. There is no endpoint epoch,
new registry, persistent generation, timer or retry.

Post-fix review traced registry allocation, freshness, duplicate detection,
owner cancellation, nested enable reads and normal/error early returns in
both modules. Existing rename/replacement, IO-close and disable tests remain
green. README and DE/EN commandref already specify this behavior and need no
new option or compatibility promise. The two review reproductions are now
tracked regressions, additionally checking sibling metadata, metadata-only
scope, duplicate delivery, actual callback execution and registry cleanup.
All 1,023 top-level tests, test-harness syntax, manifest validation/tests and
diff checks pass. Callback tests are modeled; no live FHEM/configDB/hardware
validation was performed.
