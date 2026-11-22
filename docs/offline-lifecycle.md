# Availability and synchronization (#27)

The last reported `available` reading is persisted by FHEM. It is not
current permission to import device data after restart or IO loss.
The root's runtime `helper.available` is the update authority.

| Input / lifecycle | Device data and reads | Administration |
| --- | --- | --- |
| Unknown availability | Block values and getConfig; retain/create identity and endpoints | Root unknown; saved readings retained |
| Valid false report | Block snapshots and live attributes | Root offline; local corrections retained |
| IO loss, removal, INITIALIZED/REREADCFG | Invalidate runtime availability and old read epochs | Root unknown/removed; saved available retained |
| Valid true report | Accept ordinary snapshots, node_updated attributes, live reports and explicit getConfig | Root online; no extra per-attribute permission |
| Missing/null/malformed availability | Keep the current authority unchanged | Do not fabricate a boolean |

All roots belonging to a closing IO are invalidated before its first reading
event because FHEM notifications can synchronously reenter the module. Another
IO, including one with the same node ID, is unaffected. Valid online reports
resume synchronization directly; there is no persistent snapshot quarantine.

Existing FUUID/availability-epoch request checks and per-path live ordering
reject obsolete responses. Missing commands after a known offline/online
transition retain the bounded event-driven metadata-only recovery (at most
three attempts, at least 15 seconds apart). Explicit getConfig is an ordinary
online read and may update physical values. No new polling is introduced.

## Matter-server evidence

Inspected 2026-11-22 at
[`matterjs-server@fc8aa79611aebbe3090a30813e7211f707b2131f`](https://github.com/matter-js/matterjs-server/tree/fc8aa79611aebbe3090a30813e7211f707b2131f).
`ControllerCommandHandler.#refreshAfterFirstReport` rebuilds the attribute
cache before a restored node becomes available. The accompanying
[`RestoredNodeCacheTest`](https://github.com/matter-js/matterjs-server/blob/fc8aa79611aebbe3090a30813e7211f707b2131f/packages/ws-controller/test/RestoredNodeCacheTest.ts)
explicitly tests the current OnOff value in node_updated without an additional
attribute_updated event. Requiring that extra event in FHEM would reject the
valid update and could leave the displayed state stale.

During an ordinary peer reconnection, the server can publish availability
before its full cache rebuild. This transient ordering does not establish a
need to reject all online snapshots indefinitely. FHEM accepts the server's
online data model; cached values are not a new physical-contact guarantee.
The user's installed server revision has not been matched to this upstream
inspection, so no deployed-firmware behavior is claimed.

## FHEM evidence and test limits

[`fhem/fhem-mirror@5544e24cc71f2e3cebd786001778fe18eea5e62e`](https://github.com/fhem/fhem-mirror/blob/5544e24cc71f2e3cebd786001778fe18eea5e62e/fhem/fhem.pl),
inspected 2026-11-22, restores state before INITIALIZED and reloads before
REREADCFG. Existing module callbacks invalidate runtime permission after
restoration, without replacing FHEM's reading persistence.

The focused regression exercises the actual IO/device parsers with modeled
FHEM functions: unknown/offline preservation, reconnect, retained readings
with rebuilt helpers, INITIALIZED/REREADCFG, synchronous notification reentry,
member removal, multiple roots and same-node-ID IO separation. It explicitly
accepts a valid online node_updated without a subsequent attribute event.
Existing tests verify full explicit getConfig, metadata-only automatic
recovery, old-epoch rejection and newer-live-over-older-response ordering.

No physical device, running FHEM restart, configuration-file/configDB backend
or real event loop was exercised. A modeled restoration is not hardware or
configDB validation. No migration, recurring timer or new public setting is
introduced.
