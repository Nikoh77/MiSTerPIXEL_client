# MiSTer PIXEL — Client

> **Translate retro game text on your MiSTer FPGA in real time.**

MiSTer PIXEL captures a screenshot from the game core currently running on your [MiSTer FPGA](https://github.com/MiSTer-devel/Main_MiSTer) and sends it to a companion server that performs OCR and translation via a VLM/AI model. The translated text is displayed on your phone or PC — no modification to the MiSTer firmware required.

This repository contains the **client** that runs on the MiSTer. The server component lives in a separate repository.

---

## How it works

```
MiSTer FPGA                          Your phone / PC
┌────────────────────────────┐       ┌──────────────────────────┐
│  pixel.sh (daemon)         │  TCP  │  PIXEL server            │
│  ┌──────────────────────┐  │──────▶│  ├── OCR                 │
│  │ Capture screenshot   │  │       │  ├── Translation (VLM)   │
│  │ (firmware FIFO or    │  │       │  └── Web UI              │
│  │  /dev/mem fallback)  │  │       └──────────────────────────┘
│  │ Gather core/ROM info │  │  HTTP long-poll (triggers)
│  │ Long-poll server     │◀─┘
│  └──────────────────────┘
└────────────────────────────┘
```

1. The daemon registers with the server and displays a short pairing code on the MiSTer Scripts menu.
2. You open the web UI on your phone/PC, enter the code, and the device is linked.
3. Tap **Translate now** in the web UI — the daemon captures the current frame and sends it.
4. The server replies with the translated text, shown instantly in the browser.

---

## Features

- **Two capture methods**
  - `fifo` *(default)*: asks the MiSTer firmware to take a native PNG screenshot via `/dev/MiSTer_cmd`; automatically falls back to `mem` on timeout
  - `mem`: reads raw RGB directly from the scaler shared memory (`/dev/mem`)
- **Zero dependencies**: pure Python 3.9 stdlib — no pip, no virtualenv; can be compiled to a standalone binary with [Nuitka](https://nuitka.net/)
- **Thin client**: all heavy processing (OCR, colour handling, translation) happens server-side
- **Single-instance daemon**: replaces any previously running PIXEL client on launch
- **Zero-conf, server-driven settings**: nothing is configured or persisted on the device beyond the bootstrap server address. Translation language and capture settings are **per device**, set from the web UI and stored server-side — the capture instructions arrive **with each trigger**, so changes take effect on the next capture with no SSH and no local file
- **Secure token auth**: per-device token issued at pairing — no shared API key; each frame authenticates with the device's own token. The bootstrap server address is never web-writable

---

## Requirements

- MiSTer FPGA with stock firmware (no third-party add-ons required)
- Python 3.9 (pre-installed on MiSTer) — *or* the Nuitka-compiled binary
- A running MiSTer PIXEL server

---

## Installation

1. Copy `pixel.sh` to your MiSTer (e.g. `/media/fat/Scripts/`):

   ```bash
   scp pixel.sh root@<mister-ip>:/media/fat/Scripts/
   ```

2. Edit the bootstrap constants at the top of `pixel.sh` to point at your server:

   ```python
   CONF_SERVER   = "192.168.1.10:9999"   # host[:port] of the PIXEL server
   CONF_WEB_PORT = 8080                   # web UI port on the server
   ```

   There is **no** separate config file to create and **no** API key: the client
   authenticates with a per-device token issued when you pair it from the web UI.

3. Make the script executable:

   ```bash
   chmod +x /media/fat/Scripts/pixel.sh
   ```

---

## Usage

### From the MiSTer Scripts menu

Select **pixel** from the OSD Scripts menu. A pairing code and URL are shown. Open the URL on your phone/PC, enter the code, and the client starts polling in the background.

| Key | Action |
|-----|--------|
| Any key | Start / continue |
| `R` | Restart the daemon |
| `S` | Stop the daemon |

### Command line (SSH)

```bash
# Start daemon (default mode)
./pixel.sh

# Stop a running daemon
./pixel.sh --stop

# Single capture and send (debug / test)
./pixel.sh --once -a 192.168.1.10:9999

# Single capture, save locally only
./pixel.sh --once --save-only -s /tmp/frame.raw

# Override game title
./pixel.sh --game "Final Fantasy VI"

# Send without zlib compression
./pixel.sh --once --no-compress -a 192.168.1.10:9999
```

---

## Configuration

All bootstrap settings live as `CONF_*` constants at the top of `pixel.py`
(`pixel.sh`) — edit them before deploying. There is **no** hand-edited config
file and **no** API key.

### `CONF_*` constants *(edit in `pixel.sh`)*

| Constant | Meaning |
|----------|---------|
| `CONF_SERVER` | Server as `host[:port]` |
| `CONF_WEB_PORT` | Web UI port on the server (must match the server's `[web]` port) |
| `CONF_CAPTURE_METHOD` | Fallback `fifo`/`mem` — only used by `--once`; daemon mode gets this from the server per trigger |
| `CONF_DELETE_SCREENSHOT_AFTER` | Fallback for `--once` (same as above) |

### Per-device settings *(web UI, server-side)*

`target_lang`, `source_lang`, `capture_method` and `delete_screenshot_after` are
**per device** and stored on the server. Set them from the **Devices** tab in the
web UI. The client persists none of them: the translation language is applied
server-side, and the capture settings are sent to the client **with each
trigger** — so a change takes effect on the next capture. (In `mem` mode no PNG
is written, so `delete_screenshot_after` doesn't apply and the UI disables it.)

---

## Runtime files

| File | Description |
|------|-------------|
| `pixel_token` | Per-device auth token (issued at pairing time) — the only state on the device |
| `pixel.log` | Daemon log (stdout/stderr after detach) |
| `pixel.pid` | PID of the running daemon |

---

## Protocol

Frames are sent over a raw TCP connection (little-endian):

```
[1 B]  protocol_version
[1 B]  token_length  +  [N B] token (UTF-8)
[4 B]  metadata_length  +  [M B] JSON metadata
[4 B]  width  +  [4 B] height
[4 B]  payload_length  +  [P B] payload
```

Payload is either **raw RGB zlib-compressed** (`image_encoding = "raw"`) or a **verbatim PNG** (`image_encoding = "png"`). The server decodes according to the `image_encoding` and `compression` fields in the metadata.

The `protocol_version` field must match between client and server. Bump it whenever the wire format changes. Versions are managed via git tags.

---

## Contributing

Pull requests are welcome. Please keep the client dependency-free (stdlib only) and Python 3.9 compatible. Positional-only stdlib calls (e.g. `int.to_bytes`, `os.sysconf`) must remain positional — see the note at the top of `pixel.py`.

Edit `pixel.py` (the source of truth), then run `./build.sh` to regenerate `pixel.sh` — the deployed wrapper embeds a verbatim copy of `pixel.py`, so the two must stay in sync (commit both).

---

## License

This project is licensed under the **GNU General Public License v3.0** — see [LICENSE](LICENSE) for details.
