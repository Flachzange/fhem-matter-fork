# Matter node network type

`networkType` describes the root node's reported operational interfaces,
not the route of an individual session. It stays on endpoint 0, including
on Matter bridges. It does not identify the radio protocol of bridged
devices. Existing snapshots, `node_updated`, `attribute_updated` and
correlated `getConfig` results supply the data; no request is added.

## Protocol evidence

Inspected 2026-11-22, matterjs-server revision
[`fc8aa79611aebbe3090a30813e7211f707b2131f`](https://github.com/matter-js/matterjs-server/tree/fc8aa79611aebbe3090a30813e7211f707b2131f):

- [`GeneralDiagnostics.py`](https://github.com/matter-js/matterjs-server/blob/fc8aa79611aebbe3090a30813e7211f707b2131f/python_client/chip/clusters/cluster_defs/GeneralDiagnostics.py)
  defines cluster `0x0033`, attribute `0`, the NetworkInterface fields
  `isOperational` (tag 1) and `type` (tag 7), and enum values Unspecified=0,
  WiFi=1, Ethernet=2, Cellular=3, Thread=4.
- [`Converters.ts`](https://github.com/matter-js/matterjs-server/blob/fc8aa79611aebbe3090a30813e7211f707b2131f/packages/ws-controller/src/server/Converters.ts)
  converts known structs to numeric TLV tag keys in attribute payloads.
  The parser also accepts the corresponding named fields. This is not
  evidence that every device supplies a usable list or reports changes.

Only operational entries participate. Multiple types are sorted and
deduplicated. A valid list with no operational entries yields `unknown`;
unspecified and unrecognized active types also contribute `unknown`.
Malformed/null lists preserve the previous value. Before any usable list,
the reading is absent. It uses ordinary FHEM reading persistence and writes
only on value changes. Cached values and snapshot quarantine follow the
existing device parser; this feature does not weaken freshness rules.

NetworkCommissioning feature flags express supported interfaces, not a
current active route, so they are deliberately not a fallback.

Live `attribute_updated` events now use the existing per-path pending
discovery tracking, just like `node_updated` attributes. This prevents a
late discovery reply from reverting newer values and applies to other
valid Matter attributes as well. Invalid network-interface lists are not
allowed to suppress valid values from pending discovery/read results.

## Automated coverage and limits

`t/matter_node_sync.t` routes synthetic payloads through the actual IO and
device parser callbacks. The focused subtest covers initial discovery,
named/tag fields, booleans, active/inactive interfaces, multiple types,
unknown types, malformed/null lists, root/bridge scope, unchanged-value
suppression, delayed discovery and correlated-read responses, invalid-live
negative controls, offline/recovery quarantine, multiple IOs, and absence
of additional timers/reads.

Tests use the repository's existing modeled FHEM callbacks; they do not
establish real FHEM event delivery, statefile/configDB persistence or device
firmware compliance. Physical Wi-Fi/Thread/Ethernet/Cellular devices and a
live matterjs-server connection remain **untested** for this feature.
