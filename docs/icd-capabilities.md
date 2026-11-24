# ICD capability reconciliation and backend support (#28)

## Implemented policy (V0.24)

- Capability detection remains passive and root-only. A valid
  `Descriptor.ServerList` (`0/29/1`) containing cluster 70 establishes ICD
  support. A list excluding it revokes prior support and removes the ICD
  command metadata. An omitted or malformed list is not negative evidence.
  Ordinary non-ICD roots do not acquire extra negative ICD readings.
- The full list is authoritative even when delivered inside a partial
  `node_updated`. Both snapshot parser paths process it after the other
  attributes. Newer live lists are retained in pending discovery/read
  reconciliation so old ICD FeatureMaps cannot undo removal.
- Root `getConfig` reads ServerList in its existing request. This adds a
  path, not another request, background query or polling timer. Offline and
  unknown-availability data gates remain unchanged.
- `get icdState` requires positively recognized ICD support and a current
  OHF matterjs-server connection reporting schema >= 12 and the SDK format
  `matter-server/<version> (matter.js/<version>)`. Administrative operations
  additionally require the Check-In feature. The same command-list checks
  govern explicit commands. Backend permission is cleared before disconnect
  events; restored `schemaVersion`/`sdkVersion` readings cannot enable it.
- This SDK-format check identifies the known backend; it is not an API
  command inventory or a guarantee about arbitrary compatible forks. Unknown
  identifiers keep passive device detection without these server operations.
  Server rejections still use the existing correlated error handling.
- Historical device mode/duration and controller observations remain stored.
  Controller values describe the last explicit query, with normal FHEM
  timestamps. Reconnect neither refreshes them nor adds another stale flag.
  `awake=false` does not change ordinary root/endpoint state. No automatic
  register, unregister, resync or state query is introduced.

## Primary evidence

Inspected 2026-11-22:

- [Matter 1.4 Descriptor definition](https://github.com/project-chip/connectedhomeip/blob/master/data_model/1.4/clusters/Descriptor-Cluster.xml),
  inspected content blob `782bf997e794637491bdca8a80c2d4a856b6b4bb`:
  attribute 1 is ServerList, a list of cluster IDs.
- [Generated Descriptor type at matterjs-server fc8aa796](https://github.com/matter-js/matterjs-server/blob/fc8aa79611aebbe3090a30813e7211f707b2131f/python_client/chip/clusters/cluster_defs/Descriptor.py):
  cluster 29, attribute 1, list of unsigned cluster IDs.
- [WebSocket server identity](https://github.com/matter-js/matterjs-server/blob/fc8aa79611aebbe3090a30813e7211f707b2131f/packages/ws-controller/src/server/WebSocketControllerHandler.ts):
  `getServerInfo` generates the SDK string above. The parser establishes the
  runtime permission before publishing any server-info readings.
- [ICD API and response types](https://github.com/matter-js/matterjs-server/blob/fc8aa79611aebbe3090a30813e7211f707b2131f/packages/ws-client/src/models/model.ts):
  controller ICD state is explicitly OHF-server-only.
- [Administrative API](https://github.com/matter-js/matterjs-server/blob/fc8aa79611aebbe3090a30813e7211f707b2131f/docs/websockets_api.md):
  registration uses conservative defaults, unregister has no forced local
  bypass, and resync may wait for the next idle interval. Existing behavior
  is retained.

The existing schema >= 12 client floor is retained; a schema number alone
does not identify these backend extensions. The installed backend revision
has not been matched to the upstream inspection.

## Verification and limits

`t/matter_node_sync.t` exercises the actual modules with modeled FHEM callbacks
and socket-backed connection fixtures. Focused cases cover backend identities,
invalid server information, persisted server readings, disconnect/reconnect,
root/endpoint and multi-IO isolation, passive removal/restoration, malformed
and partial lists, same-payload ordering, older getConfig/discovery responses,
conservative administrative payloads, and unchanged historical readings.

No real ICD hardware, running FHEM event loop, installed backend connection or
configDB restart was exercised. Hardware support remains **untested**.
