# Baseline: Matter device-completeness work (2026-11-17)

This branch was created directly from the **testing** branch at commit
[`8096ede4249125e2f35695517d6cecfe9803bbdd`](https://github.com/Flachzange/fhem-matter-fork/commit/8096ede4249125e2f35695517d6cecfe9803bbdd),
after merging PR #29. This is a reference snapshot, not a new copy of the modules.

| Source | Git blob SHA at baseline |
| --- | --- |
| `AGENTS.md` | `c1095b580dac1d224fc42c680e99ff5f45bd0165` |
| `AGENTS-MATTER.md` | `4ea98330a379fc90af90c1d12ace6f35d3b0b759` |
| `FHEM/97_MATTER.pm` | `f0cebb469b1fcfe93278bb72832b26b39cfce1bd` |
| `FHEM/97_MATTERDevice.pm` | `fb11a61634a8e4858bec87d1d87d7a6e6165e7b0` |
| `t/matter_node_sync.t` | `f39bb3613ded875052eb9b51b249de6beb2618e9` |
| `.github/workflows/perl-tests.yml` | `8935e2929cf9381e730eea5f4bc884dcc215dee8` |
| `controls_matter.txt` | `3d2563a8f36fcbe5439f3bde18a9b0cc3a460864` |

## Planned implementation sequence

- #37: commandref hardware-test evidence and explicit untested labels
- #27: suppress stale device data from offline nodes
- #30: core sensor clusters, #31: switch events
- #32: additional environment measurements, #33: thermostat/fan/identify, #34: LevelControl dimming
- #28: ICD support, #35: optional Thread/Wi-Fi diagnostics and raw readings, #36: OTA check/install without upload

Each issue is to have a separate commit and whole-module regression review. No changes to the external Matter server, OTBR, synchronized generic `AGENTS.md`, or other repositories.
