# FHEM Matter Integration (`MATTER` & `MATTERDevice`)

This repository provides custom FHEM modules to integrate **Matter** smart home devices via a central WebSocket-based Matter server. 

The architecture consists of two modules:

1. **`97_MATTER.pm` (IO-Device):** Manages the raw TCP/WebSocket connection to the Matter server, handles handshakes, keeps-alives, and routes messages.
2. **`97_MATTERDevice.pm` (Child-Device):** Represents individual Matter nodes (e.g., lights, switches), dynamically adapts its controls based on supported clusters, and synchronizes states.

---

## Features

* **WebSocket Communication:** Native raw-socket handling with automatic handshake and JSON payload exchange.
* **Auto-Discovery:** Automatically queries the Matter server for nodes and creates corresponding FHEM devices (`MATTERDevice`).
* **Dynamic Set-Lists:** Automatically detects device capabilities (OnOff, LevelControl, ColorControl/CT/RGB) and adjusts FHEM's `set` options and sliders accordingly.
* **Auto-Reconnect:** Built-in resilient connection recovery with safe interval timers.
* **FHEM Updater Support:** Seamless integration into the FHEM update mechanism.

---

## Installation & Setup

### 1. Add the Repository to FHEM
Open your FHEM command line and add this repository to your update sources:

```text
update add [https://gitlab.com/zeppelin1979/fhem-matter/-/raw/main/controls_matter.txt](https://gitlab.com/zeppelin1979/fhem-matter/-/raw/main/controls_matter.txt)
