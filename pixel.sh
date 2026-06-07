#!/bin/bash
# PIXEL - MiSTer FPGA frame capture client
# Usage: ./pixel.sh [-a HOST:PORT] [-s out.raw] [--game TITLE] [--no-compress] [--once] [--stop]
# Wraps pixel.py so it can be copy-pasted to the MiSTer and run with no
# separate .py file. The script body is fed to python on fd 3 (not stdin), so
# stdin stays connected to the keyboard for the launcher key prompt. Body below
# is a verbatim copy of pixel.py — regenerate with ./build.sh after editing it.
export PIXEL_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 /dev/fd/3 "$@" 3<< 'PYEOF'
#!/usr/bin/env python3
"""
Captures a raw frame from MiSTer's scaler shared memory (replicating the logic
of the C++ scaler.cpp code), gathers useful context about the running game and
sends everything to the PIXEL server for OCR + translation.

Design constraints:
- stdlib ONLY (no third-party imports) so this can be Nuitka-compiled into a
  standalone binary and run on the MiSTer without a Python install.
- The client stays "thin": pixels are sent as native RGB (optionally
  zlib-compressed); all heavy processing (color handling, OCR, translation)
  happens server-side.
- Must run on the MiSTer's Python 3.9: a few C builtins are positional-only
  there (int.to_bytes/from_bytes, str.partition, os.sysconf) and raise
  TypeError if called with keywords. Those calls deliberately pass args
  positionally even though the rest of the repo favors keyword arguments.
"""
import os
import sys
import json
import zlib
import mmap
import time
import signal
import hashlib
import asyncio
import argparse
import subprocess
import http.client
from datetime import datetime, timezone
from typing import NamedTuple, Optional, Tuple

CLIENT_VERSION = "0.9.3"

# --- Constants from the C++ code (shmem.h) ---------------------------------
MISTER_SCALER_BASEADDR = 0x20000000
MISTER_SCALER_BUFFERSIZE = 0x1000000  # 16MB

# --- Protocol / client identity --------------------------------------------
PROTOCOL_VERSION = 3  # bump whenever the wire format changes (server must match)
DEFAULT_PORT = 9999

# ---------------------------------------------------------------------------
# Bootstrap settings — edit these constants before deploying to your MiSTer.
# server/web_port are the only thing the client truly needs to know. The capture
# constants are just local fallbacks/defaults (used by --once): in daemon mode
# the authoritative per-device capture settings arrive with each trigger from the
# server. Translation language lives server-side too (set it from the web Devices
# tab), so the client never sends it. No config file is written on the device.
# ---------------------------------------------------------------------------
CONF_SERVER = "192.168.1.5"          # server as host[:port], e.g. "192.168.1.10:9999"
CONF_WEB_PORT                = 8080          # web UI port on the server
CONF_CAPTURE_METHOD          = "fifo"        # fallback "fifo" (firmware PNG) or "mem" (raw /dev/mem)
CONF_DELETE_SCREENSHOT_AFTER = True          # fallback: delete firmware PNG after sending

# --- Local files -----------------------------------------------------------
# The client persists NO config file: bootstrap lives in the CONF_* constants
# above, and per-device settings (language, capture method, delete-after) live
# server-side — the capture ones arrive with each trigger (see runDaemon). The
# only file written is the per-device auth token below.
# The per-device auth token, issued by the server at link time, stored on its own.
# It's the credential for the TCP frame channel and the /api/wait poll.
TOKEN_FILENAME = "pixel_token"
# Where the detached daemon writes its log (the launcher terminal is gone by
# then). Lives next to the script.
LOG_FILENAME = "pixel.log"
# Records the running daemon's PID so a later launch replaces it instead of
# stacking another poll loop on the MiSTer (single-instance guard).
PIDFILE_NAME = "pixel.pid"
# The daemon also records its CLIENT_VERSION next to the PID, so a later launch
# from an updated pixel.sh can tell an OUTDATED daemon apart and replace it even
# when it's linked and otherwise healthy. Without this, a deployed code change
# (e.g. the move to trigger-carried capture settings) silently never takes effect
# because launch() leaves a working linked daemon running. A missing file means a
# pre-versioning daemon → treated as outdated.
VERSIONFILE_NAME = "pixel.version"
# Current core name written by MiSTer (reliable). Verified in user_io.cpp.
CORENAME_PATH = "/tmp/CORENAME"
# The Main binary does NOT write the loaded game's name/path anywhere under
# /tmp. With `log_file_entry=1` in MiSTer.ini it writes /tmp/GAMEID, but that
# holds only CRC32 + Serial (precise ROM IDs, no human title) — ideal for a
# server-side DB lookup, useless as a display name. (Verified against
# Main_MiSTer user_io.cpp.) PIXEL is self-contained: it relies only on stock
# MiSTer files, never on third-party add-ons.
GAMEID_PATH = "/tmp/GAMEID"
# Network interfaces, used to derive a stable per-device id (see detectDeviceId).
NET_SYSFS_DIR = "/sys/class/net"

# --- Native screenshot via the firmware (default capture method) -----------
# `echo screenshot > /dev/MiSTer_cmd` makes Main save a PNG under
# SCREENSHOT_DIR/<core>/<datecode>-<name>.png (verified in scaler.cpp /
# file_io.cpp). We trigger it, watch the core's folder for the new PNG, and
# read that instead of /dev/mem.
CMD_FIFO = "/dev/MiSTer_cmd"
SCREENSHOT_DIR = "/media/fat/screenshots"
SCREENSHOT_TIMEOUT = 5.0   # seconds to wait for the PNG before falling back
SCREENSHOT_POLL = 0.1      # how often to poll the folder

# --- Capture sanity limits (guard against torn / garbage reads) ------------
MAX_DIMENSION = 2048


class CapturedImage(NamedTuple):
    """An image ready to send, plus how it's encoded.

    encoding is "png" (firmware screenshot, bytes are the PNG file) or "raw"
    (native RGB, 3 B/px, as captureRaw produces). The server decodes per the
    `image_encoding` metadata field. `path` is the on-disk PNG (so the caller
    can delete it after sending); None for raw captures.
    """
    data: bytes
    encoding: str          # "png" | "raw"
    width: int
    height: int
    path: Optional[str] = None


# ---------------------------------------------------------------------------
# Config & context
# ---------------------------------------------------------------------------
def defaultConfig() -> dict:
    """Return a fresh cfg dict built from the built-in user constants (CONF_*)."""
    return {
        "server":                  CONF_SERVER,
        "game":                    None,    # manual title override (--game only)
        "web_port":                CONF_WEB_PORT,
        "capture_method":          CONF_CAPTURE_METHOD,
        "delete_screenshot_after": CONF_DELETE_SCREENSHOT_AFTER,
        "token":                   None,   # per-device auth token (loaded from TOKEN_FILENAME)
    }


def loadConfig(scriptDir: str) -> dict:
    """Build the runtime config: the CONF_* constants plus the stored token.

    There is no config file to read. Bootstrap (server/web_port) and the local
    capture defaults are the CONF_* constants at the top of this file; the
    authoritative per-device capture settings arrive with each trigger over
    /api/wait (the CONF_* values are only fallbacks, used by --once). The
    per-device token lives in its own file.
    """
    cfg = defaultConfig()
    cfg["token"] = loadToken(scriptDir=scriptDir)
    return cfg


def loadToken(scriptDir: str) -> Optional[str]:
    """Return the stored per-device token, or None if not yet linked."""
    try:
        with open(file=os.path.join(scriptDir, TOKEN_FILENAME), mode="r") as f:
            return f.read().strip() or None
    except OSError:
        return None


def saveToken(scriptDir: str, token: str) -> bool:
    """Persist the per-device token (temp-file+rename). Returns True on success."""
    path = os.path.join(scriptDir, TOKEN_FILENAME)
    tmp = path + ".tmp"
    try:
        with open(file=tmp, mode="w") as f:
            f.write(token)
        os.replace(tmp, path)
    except OSError as e:
        print(f"Could not write {TOKEN_FILENAME}: {e}", flush=True)
        return False
    return True


def deleteToken(scriptDir: str) -> None:
    """Remove the stored token (e.g. after it's been revoked). Best-effort."""
    try:
        os.remove(os.path.join(scriptDir, TOKEN_FILENAME))
    except OSError:
        pass


# Capture settings (capture_method, delete_screenshot_after) are web-controlled
# per device and NOT persisted here: the server stores them and sends them with
# each trigger (applied in runDaemon).


def readFirstLine(path: str) -> Optional[str]:
    """Return the stripped first line of a file, or None if unavailable."""
    try:
        with open(file=path, mode="r") as f:
            return f.readline().strip() or None
    except OSError:
        return None


def detectCore() -> Optional[str]:
    """Detect the currently running MiSTer core (e.g. 'SNES', 'Genesis')."""
    return readFirstLine(path=CORENAME_PATH)


def parseGameId() -> dict:
    """Parse /tmp/GAMEID, written by Main when `log_file_entry=1` in MiSTer.ini.

    Format (verified verbatim in user_io.cpp `user_io_write_gameid`): only the
    two lines below are written to the FILE. The loaded ROM's basename goes to
    Main's stdout (printf), NOT into the file — so there is no readable title
    here, only precise IDs:
        CRC32: <8 hex>   (only when the CRC is non-zero)
        Serial: <str>    (only for cores that expose one, e.g. CD games)
    When neither is available Main writes '# No game ID available'.

    Returns rom_crc32 / rom_serial when present; {} if the file is absent or
    holds no IDs. These let the server resolve a canonical game name.
    """
    info: dict = {}
    try:
        with open(file=GAMEID_PATH, mode="r") as f:
            lines = f.read().splitlines()
    except OSError:
        return info

    for line in lines:
        line = line.strip()
        # split() args positional to stay safe on the MiSTer's 3.9.
        if line.startswith("CRC32:"):
            info["rom_crc32"] = line.split(":", 1)[1].strip()
        elif line.startswith("Serial:"):
            info["rom_serial"] = line.split(":", 1)[1].strip()
    return info


def detectGame(override: Optional[str]) -> Optional[str]:
    """Return an explicit human-readable game title, if provided.

    Only honors --game / CONF_GAME: stock MiSTer exposes no readable title
    (see parseGameId). Without an override this returns None and the server
    resolves a canonical name from rom_crc32/rom_serial via its offline DB.
    """
    return override


def detectDeviceId() -> Optional[str]:
    """Derive a stable identifier unique to this MiSTer.

    Combines the MAC addresses of all real network interfaces (e.g. eth0 and
    wlan0) so the same unit reports the same id whether connected by cable or
    Wi-Fi. MACs are sorted before hashing, so interface ordering doesn't matter.
    Loopback and zero MACs are ignored. Returns a short hex digest, or None if
    no usable MAC is found.
    """
    macs = []
    try:
        names = os.listdir(NET_SYSFS_DIR)
    except OSError:
        return None
    for name in names:
        if name == "lo":
            continue
        mac = readFirstLine(path=os.path.join(NET_SYSFS_DIR, name, "address"))
        # Skip empty and all-zero MACs (down/virtual interfaces).
        if mac and mac != "00:00:00:00:00:00":
            macs.append(mac.lower())
    if not macs:
        return None
    joined = "|".join(sorted(set(macs)))
    return hashlib.sha256(joined.encode("utf-8")).hexdigest()[:16]


def buildMetadata(cfg: dict, image: CapturedImage) -> dict:
    """Assemble the context blob sent alongside the image.

    More context = better translation. Anything not available degrades to None
    so the server (and the VLM) can still use whatever is present. The
    `image_encoding` field tells the server how to decode the payload ("png" or
    "raw"); for "raw" the pixels are native RGB, 3 B/px.
    """
    gameid = parseGameId()  # rom_crc32 / rom_serial (or {})
    # No identity is sent in the frame: the server resolves both the device and
    # its account from the per-device token, so the client can't claim to be a
    # different device/account.
    # Translation language is intentionally absent: the server holds it per
    # device (resolved from our token), so it's authoritative and we don't echo it.
    metadata = {
        "protocol_version": PROTOCOL_VERSION,
        "timestamp": datetime.now(tz=timezone.utc).isoformat(),
        "core": detectCore(),
        "image_encoding": image.encoding,
    }
    if image.encoding == "raw":
        metadata["pixel_format"] = "RGB"
        metadata["bytes_per_pixel"] = 3
    # Only include a manual title override when one is set (--game / CONF_GAME);
    # stock MiSTer has no readable title, so the server resolves it from the CRC.
    game = detectGame(override=cfg["game"])
    if game:
        metadata["game"] = game
    # Precise ROM identifiers (CRC32/Serial) when available, for server-side
    # game lookup. Absent unless log_file_entry=1 is set in MiSTer.ini.
    metadata.update(gameid)
    return metadata


# ---------------------------------------------------------------------------
# Capture
# ---------------------------------------------------------------------------
def captureRaw(retries: int = 3) -> CapturedImage:
    """Capture a frame from the scaler shared memory as native RGB.

    Validates the header and re-checks it after the copy to reject torn frames
    (a frame written while we were reading it). Raises RuntimeError on a
    persistently invalid/unstable frame.
    """
    pagesize = os.sysconf("SC_PAGE_SIZE")  # 3.9: sysconf is positional-only
    if pagesize <= 0:
        pagesize = 4096

    offset = MISTER_SCALER_BASEADDR
    map_start = offset & ~(pagesize - 1)
    map_off = offset - map_start
    num_bytes = MISTER_SCALER_BUFFERSIZE

    with open(file="/dev/mem", mode="r+b") as f:
        mem = mmap.mmap(f.fileno(), num_bytes + map_off,
                        mmap.MAP_SHARED, mmap.PROT_READ,
                        offset=map_start)
        try:
            last_error = "unknown error"
            for _attempt in range(retries):
                header = mem[map_off:map_off + 16]

                # Magic bytes
                if header[0] != 1 or header[1] != 1:
                    last_error = "invalid scaler header (magic bytes)"
                    continue

                data_offset = (header[2] << 8) | header[3]
                width = (header[6] << 8) | header[7]
                height = (header[8] << 8) | header[9]
                line = (header[10] << 8) | header[11]

                # Sanity checks: reject garbage / torn dimensions
                if not (0 < width <= MAX_DIMENSION and 0 < height <= MAX_DIMENSION):
                    last_error = f"implausible dimensions {width}x{height}"
                    continue
                if line < width * 3:
                    last_error = f"implausible line stride {line} (width {width})"
                    continue
                if map_off + data_offset + height * line > num_bytes + map_off:
                    last_error = "frame exceeds scaler buffer"
                    continue

                # Bulk per-row copy: O(height) slice ops, no per-pixel loop.
                # Scaler memory is already laid out as R,G,B per pixel, so a row
                # slice of width*3 bytes is valid RGB (row padding dropped).
                out = bytearray(width * height * 3)
                base = map_off + data_offset
                row_len = width * 3
                for y in range(height):
                    src = base + y * line
                    out[y * row_len:(y + 1) * row_len] = mem[src:src + row_len]

                # Tearing check: header must be unchanged after the copy
                header_after = mem[map_off:map_off + 16]
                if header_after[:12] == header[:12]:
                    return CapturedImage(data=bytes(out), encoding="raw",
                                         width=width, height=height, path=None)
                last_error = "frame changed during capture (tearing)"

            raise RuntimeError(last_error)
        finally:
            mem.close()


# ---------------------------------------------------------------------------
# Capture via the firmware's native screenshot (FIFO)
# ---------------------------------------------------------------------------
def pngDimensions(data: bytes) -> Tuple[int, int]:
    """Read (width, height) from a PNG's IHDR header. (0, 0) if not a PNG.

    Avoids needing an image library on the client: the IHDR width/height are two
    big-endian uint32 at a fixed offset right after the 8-byte signature + chunk.
    """
    if len(data) < 24 or data[:8] != b"\x89PNG\r\n\x1a\n":
        return 0, 0
    width = int.from_bytes(data[16:20], "big")
    height = int.from_bytes(data[20:24], "big")
    return width, height


def screenshotDir(core: Optional[str]) -> str:
    """The folder where the firmware saves this core's screenshots."""
    return os.path.join(SCREENSHOT_DIR, core or "")


def listScreenshots(folder: str) -> set:
    """Return the set of .png file paths currently in a folder (empty if none)."""
    try:
        names = os.listdir(folder)
    except OSError:
        return set()
    return set(os.path.join(folder, n) for n in names if n.lower().endswith(".png"))


def waitFileStable(path: str, timeout: float = 2.0) -> bool:
    """Wait until a file's size stops changing (fully written). True if stable.

    The firmware writes the PNG on a worker thread, so a freshly-appeared file
    may still be growing; reading it too early gives a truncated image.
    """
    deadline = time.time() + timeout
    last_size = -1
    while time.time() < deadline:
        try:
            size = os.path.getsize(path)
        except OSError:
            size = -1
        if size > 0 and size == last_size:
            return True
        last_size = size
        time.sleep(SCREENSHOT_POLL)
    return False


def captureScreenshot(core: Optional[str]) -> Optional[CapturedImage]:
    """Trigger a native screenshot and return the resulting PNG, or None.

    Asks Main via the command FIFO, then watches the core's screenshot folder
    for a new .png. Returns None on timeout so the caller can fall back to
    captureRaw. Does not delete the file (the caller decides, after sending).
    """
    folder = screenshotDir(core=core)
    before = listScreenshots(folder=folder)

    try:
        with open(file=CMD_FIFO, mode="w") as f:
            f.write("screenshot\n")
    except OSError as e:
        print(f"Could not write {CMD_FIFO}: {e}")
        return None

    deadline = time.time() + SCREENSHOT_TIMEOUT
    while time.time() < deadline:
        new = listScreenshots(folder=folder) - before
        if new:
            path = max(new, key=lambda p: os.path.getmtime(p))
            if not waitFileStable(path=path):
                continue
            try:
                with open(file=path, mode="rb") as f:
                    data = f.read()
            except OSError:
                return None
            width, height = pngDimensions(data=data)
            if width <= 0 or height <= 0:
                print("Screenshot PNG had no readable dimensions")
                return None
            return CapturedImage(data=data, encoding="png",
                                 width=width, height=height, path=path)
        time.sleep(SCREENSHOT_POLL)

    print(f"Screenshot did not appear within {SCREENSHOT_TIMEOUT}s")
    return None


def capture(cfg: dict) -> CapturedImage:
    """Capture a frame using the configured method, with fallback.

    "fifo" (default): native firmware screenshot (PNG). On timeout/failure it
    falls back to "mem". "mem": raw RGB from the scaler. Always returns a
    CapturedImage (raises only if even the mem fallback fails).
    """
    method = cfg.get("capture_method", "fifo")
    if method == "fifo":
        core = detectCore()
        shot = captureScreenshot(core=core)
        if shot is not None:
            print(f"Captured via screenshot: {shot.width}x{shot.height} PNG "
                  f"({len(shot.data)} bytes)")
            return shot
        print("Falling back to /dev/mem capture")

    return captureRaw()


def cleanupScreenshot(cfg: dict, image: CapturedImage) -> None:
    """Delete the firmware PNG after sending, if delete_screenshot_after is on.

    Only touches files we captured via the screenshot method (image.path set);
    raw captures have no file. Best-effort: a failure is logged, not fatal.
    """
    if not cfg.get("delete_screenshot_after", True):
        return
    if not image.path:
        return
    try:
        os.remove(image.path)
    except OSError as e:
        print(f"Could not delete screenshot {image.path}: {e}")


# ---------------------------------------------------------------------------
# Output: save / send
# ---------------------------------------------------------------------------
def saveCapture(image: CapturedImage, filepath: str, metadata: dict) -> bool:
    """Save the captured image to disk, plus a '<filepath>.json' metadata sidecar.

    A PNG capture is written verbatim. A raw capture uses the legacy layout:
    width (4 B LE) + height (4 B LE) + RGB pixel data (so Misc/raw2jpg.py reads it).
    """
    try:
        with open(file=filepath, mode="wb") as f:
            if image.encoding == "raw":
                # 3.9: int.to_bytes args are positional-only (keywords in 3.11)
                f.write(image.width.to_bytes(4, "little"))
                f.write(image.height.to_bytes(4, "little"))
            f.write(image.data)
        with open(file=filepath + ".json", mode="w") as f:
            json.dump(obj=metadata, fp=f, ensure_ascii=False, indent=2)
    except Exception as e:
        print(f"Error saving file: {e}")
        return False
    print(f"Saved to: {filepath} (+ .json)")
    return True


async def sendImage(cfg: dict, host: str, port: int, image: CapturedImage,
                    metadata: dict, compress: bool = True) -> bool:
    """Send the captured image + context to the server and print its response.

    Wire format (little-endian):
        1  protocol version
        1  token length
        N  device token (UTF-8)  -- per-device credential; authenticates the frame
        4  metadata length
        M  metadata (JSON, UTF-8)
        4  width
        4  height
        4  payload length
        P  payload (raw RGB optionally zlib-compressed, OR a PNG file as-is)

    PNG payloads are already compressed, so zlib is skipped for them; the server
    decodes per metadata.image_encoding / metadata.compression.
    """
    token = cfg.get("token") or ""
    token_bytes = token.encode()
    if not token_bytes:
        print("No device token — link the device from the web first.")
        return False
    if len(token_bytes) > 255:
        print("Device token too long (max 255 bytes)")
        return False

    payload = image.data
    metadata = dict(metadata)
    metadata["raw_size"] = len(image.data)
    # zlib only helps raw RGB; a PNG is already deflate-compressed.
    if compress and image.encoding == "raw":
        payload = zlib.compress(image.data, level=6)
        metadata["compression"] = "zlib"
    else:
        metadata["compression"] = "none"
    meta_bytes = json.dumps(obj=metadata, ensure_ascii=False).encode("utf-8")

    try:
        reader, writer = await asyncio.open_connection(host=host, port=port)
    except (ConnectionRefusedError, OSError) as e:
        print(f"Connection to {host}:{port} failed: {e}")
        return False

    try:
        # 3.9: int.to_bytes args are positional-only (keywords added in 3.11)
        writer.write(data=PROTOCOL_VERSION.to_bytes(1, "little"))
        writer.write(data=len(token_bytes).to_bytes(1, "little"))
        writer.write(data=token_bytes)
        writer.write(data=len(meta_bytes).to_bytes(4, "little"))
        writer.write(data=meta_bytes)
        writer.write(data=image.width.to_bytes(4, "little"))
        writer.write(data=image.height.to_bytes(4, "little"))
        writer.write(data=len(payload).to_bytes(4, "little"))
        writer.write(data=payload)
        await writer.drain()
        print(f"Sent: {image.width}x{image.height} {image.encoding}, payload "
              f"{len(payload)} bytes (raw {len(image.data)}, "
              f"compression={metadata['compression']})")

        # 3.9: int.from_bytes args are positional-only (keywords added in 3.11)
        response_len = int.from_bytes(await reader.readexactly(4), "little")
        response = await reader.readexactly(n=response_len)
        print(f"Response: {response.decode(errors='replace')}")
    except Exception as e:
        print(f"Error during exchange with {host}:{port}: {e}")
        return False
    finally:
        try:
            writer.close()
            await writer.wait_closed()
        except Exception as e:
            print(f"Error closing connection: {e}")
    return True


# ---------------------------------------------------------------------------
# Daemon: register, then capture on web-triggered requests
# ---------------------------------------------------------------------------
# The MiSTer firmware owns the screen and grabs all input devices, so PIXEL
# can't show anything on-screen or read a controller button (both verified on
# hardware). Instead the user's phone/PC is the display AND the remote: the web
# page has a "Translate now" button. The daemon registers with the server, gets
# a short pairing code (shown once via the menu-Scripts launcher), then keeps a
# long-poll open to the server; when the user taps the button, the server
# answers the poll and the daemon captures + sends a frame.

def httpRequest(host: str, port: int, method: str, path: str,
                body: Optional[dict] = None, timeout: float = 35.0,
                headers: Optional[dict] = None) -> Tuple[int, dict]:
    """Make one HTTP request to the server and return (status, json_dict).

    stdlib-only (http.client), so the client stays Nuitka-friendly. Returns
    (-1, {}) on a connection/transport error rather than raising. `headers`
    carries secrets (e.g. the device token) so they stay out of the URL/logs.
    """
    data = None
    headers = dict(headers) if headers else {}
    if body is not None:
        data = json.dumps(obj=body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    conn = http.client.HTTPConnection(host, port, timeout=timeout)
    try:
        conn.request(method, path, body=data, headers=headers)
        resp = conn.getresponse()
        raw = resp.read()
        try:
            parsed = json.loads(raw.decode("utf-8")) if raw else {}
        except ValueError:
            parsed = {}
        return resp.status, parsed
    except ConnectionRefusedError:
        print(f"Server {host}:{port} unreachable — not started, or wrong address/port")
        return -1, {}
    except TimeoutError:
        print(f"Server {host}:{port} not responding (timeout) — check network and address")
        return -1, {}
    except OSError as e:
        print(f"Network error to {host}:{port}: {e}")
        return -1, {}
    except Exception as e:
        print(f"HTTP {method} {path} failed: {e}")
        return -1, {}
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# Self-update: the web area arms it, the server delivers {version,url,sha256}
# over /api/wait, and we fetch the new pixel.sh over HTTPS, verify it, swap it
# in and relaunch. The actual code comes from GitHub over TLS (not our plain-HTTP
# server), and the sha256 (computed server-side from the same source) is checked
# before anything is written — a tampered/corrupt download is refused, the old
# build kept. Running as root, this is a code-execution channel, so verification
# is mandatory, not optional.
# ---------------------------------------------------------------------------
def downloadHttps(url: str, timeout: float = 60.0, _redirects: int = 3) -> Optional[bytes]:
    """GET an HTTPS URL (stdlib http.client) and return the body, or None.

    HTTPS only — the update artifact must arrive over TLS so it can't be swapped
    in transit; an http:// URL is refused. Follows a few redirects (raw GitHub
    may 302 to a CDN). Returns None on any error rather than raising.
    """
    from urllib.parse import urlsplit  # stdlib; parse host/path only
    parts = urlsplit(url)
    if parts.scheme != "https" or not parts.hostname:
        print(f"Refusing non-HTTPS update URL: {url}", flush=True)
        return None
    conn = http.client.HTTPSConnection(parts.hostname, parts.port or 443, timeout=timeout)
    path = parts.path + (f"?{parts.query}" if parts.query else "")
    try:
        conn.request("GET", path or "/", headers={"User-Agent": "MiSTerPIXEL-client"})
        resp = conn.getresponse()
        if resp.status in (301, 302, 303, 307, 308) and _redirects > 0:
            loc = resp.getheader("Location")
            resp.read()
            if not loc:
                return None
            if loc.startswith("/"):
                loc = f"https://{parts.hostname}{loc}"
            return downloadHttps(url=loc, timeout=timeout, _redirects=_redirects - 1)
        if resp.status != 200:
            print(f"Update download HTTP {resp.status} for {url}", flush=True)
            return None
        return resp.read()
    except Exception as e:
        print(f"Update download error: {e}", flush=True)
        return None
    finally:
        conn.close()


def applyUpdate(scriptDir: str, host: str, tcp_port: int, version: str,
                url: str, sha256_expected: str) -> None:
    """Install a new pixel.sh and relaunch. Best-effort, never raises.

    Downloads over HTTPS, verifies the sha256, atomically replaces pixel.sh
    (keeping a .bak), then spawns the new pixel.sh detached: its launch() sees
    THIS still-running daemon on a different recorded version and replaces it via
    the single-instance + version-mismatch path — so the new code takes over with
    no manual restart. Any failure leaves the running build untouched.
    """
    target = os.path.join(scriptDir, "pixel.sh")
    print(f"[update] requested -> {version}; downloading {url}", flush=True)
    data = downloadHttps(url=url)
    if data is None:
        print("[update] aborted: download failed.", flush=True)
        return
    got = hashlib.sha256(data).hexdigest()
    if got != (sha256_expected or "").lower():
        print(f"[update] aborted: sha256 mismatch "
              f"(expected {sha256_expected}, got {got}).", flush=True)
        return

    tmp = target + ".new"
    bak = target + ".bak"
    try:
        with open(file=tmp, mode="wb") as f:
            f.write(data)
        os.chmod(tmp, 0o755)
        try:  # one-deep backup for manual rollback (best-effort)
            if os.path.exists(target):
                with open(file=target, mode="rb") as src, open(file=bak, mode="wb") as dst:
                    dst.write(src.read())
        except OSError:
            pass
        os.replace(tmp, target)  # atomic on the same filesystem
    except OSError as e:
        print(f"[update] aborted: could not install pixel.sh: {e}", flush=True)
        try: os.remove(tmp)
        except OSError: pass
        return

    print(f"[update] installed {version}; relaunching new daemon...", flush=True)
    try:
        # Detached: survives this daemon's imminent SIGTERM (the new launch()
        # stops us). -a makes it self-sufficient; CONF_* in the new file cover
        # the rest. keyPrompt() returns 'enter' with no tty, so it proceeds.
        subprocess.Popen([target, "-a", f"{host}:{tcp_port}"],
                         stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True, close_fds=True)
    except OSError as e:
        print(f"[update] installed but relaunch failed: {e}. "
              f"Restart PIXEL from the MiSTer menu to finish.", flush=True)


def registerClient(cfg: dict, host: str, web_port: int
                   ) -> tuple:  # (code: Optional[str], new_device: bool)
    """Register this client with the server; return (code, new_device).

    The server generates the code and stores it bound to our device_id. No
    settings are sent: they're server-authoritative per device (capture ones
    arrive with each trigger). The account is never sent or stored client-side —
    the server derives it from our device_id.
    """
    body = {"device_id": detectDeviceId(),
            "client_version": CLIENT_VERSION}
    status, data = httpRequest(host=host, port=web_port, method="POST",
                               path="/api/register", body=body)
    if status == 200 and data.get("code"):
        return data["code"], data.get("new_device", False)
    print(f"Registration failed (status {status}).")
    return None, False


def keyPrompt(running: bool) -> str:
    """Wait for a single keypress and return 'r', 's' or 'enter'.

    Run from the MiSTer Scripts menu. Any key starts the client; when a daemon is
    already running, R restarts it and S stops it (any other key leaves it
    running). Reads one keystroke in cbreak mode, blocking until pressed; if no
    terminal is available it returns 'enter' so a non-interactive launch still
    proceeds.
    """
    print()
    if running:
        print("  Press any key to continue   ·   [R] restart   ·   [S] stop", flush=True)
    else:
        print("  Press any key to start the PIXEL client...", flush=True)

    import termios
    import tty as tty_module

    # Pick an input fd: stdin if it's a tty (pixel.sh keeps it free via fd 3),
    # otherwise the controlling terminal. close_fd tells us to close it after.
    fd = None
    close_fd = False
    if sys.stdin.isatty():
        try:
            fd = sys.stdin.fileno()
        except (OSError, ValueError):
            fd = None
    if fd is None:
        try:
            fd = os.open("/dev/tty", os.O_RDONLY | os.O_NOCTTY)
            close_fd = True
        except OSError:
            fd = None
    if fd is None:
        return "enter"  # no terminal -> just proceed

    try:
        saved = termios.tcgetattr(fd)
    except termios.error:
        if close_fd:
            try: os.close(fd)
            except OSError: pass
        return "enter"

    try:
        tty_module.setcbreak(fd)
        ch = os.read(fd, 1).decode("utf-8", errors="ignore")  # block for ONE key
        print(flush=True)
        if running and ch in ("r", "R"):
            return "r"      # restart
        if running and ch in ("s", "S"):
            return "s"      # stop
        return "enter"      # any other key (incl. EOF): proceed
    except (termios.error, OSError, ValueError):
        return "enter"
    finally:
        try:
            termios.tcsetattr(fd, termios.TCSADRAIN, saved)
        except (termios.error, OSError, ValueError):
            pass
        if close_fd:
            try:
                os.close(fd)
            except OSError:
                pass


def _pidfilePath(scriptDir: str) -> str:
    return os.path.join(scriptDir, PIDFILE_NAME)


def readDaemonPid(scriptDir: str) -> Optional[int]:
    """Return the PID recorded by a previous daemon, or None."""
    try:
        with open(file=_pidfilePath(scriptDir), mode="r") as f:
            return int(f.read().strip())
    except (OSError, ValueError):
        return None


def writeDaemonPid(scriptDir: str) -> None:
    """Record this (detached) daemon's PID so a later launch can replace it."""
    try:
        with open(file=_pidfilePath(scriptDir), mode="w") as f:
            f.write(str(os.getpid()))
    except OSError as e:
        print(f"Could not write {PIDFILE_NAME}: {e}", flush=True)


def removeDaemonPid(scriptDir: str) -> None:
    """Delete the PID file (on graceful shutdown). Best-effort, never raises."""
    try:
        os.remove(_pidfilePath(scriptDir))
    except OSError:
        pass


def _versionfilePath(scriptDir: str) -> str:
    return os.path.join(scriptDir, VERSIONFILE_NAME)


def readDaemonVersion(scriptDir: str) -> Optional[str]:
    """Return the CLIENT_VERSION the running daemon recorded, or None.

    None = a pre-versioning daemon (started before this file existed) or none at
    all; launch() treats that as outdated so an update always replaces it.
    """
    try:
        with open(file=_versionfilePath(scriptDir), mode="r") as f:
            return f.read().strip() or None
    except OSError:
        return None


def writeDaemonVersion(scriptDir: str) -> None:
    """Record this daemon's CLIENT_VERSION next to its PID (update detection)."""
    try:
        with open(file=_versionfilePath(scriptDir), mode="w") as f:
            f.write(CLIENT_VERSION)
    except OSError as e:
        print(f"Could not write {VERSIONFILE_NAME}: {e}", flush=True)


def removeDaemonVersion(scriptDir: str) -> None:
    """Delete the version file (on graceful shutdown). Best-effort, never raises."""
    try:
        os.remove(_versionfilePath(scriptDir))
    except OSError:
        pass


def _pidAlive(pid: int) -> bool:
    """True if the process exists (signal 0 is a liveness probe, sends nothing)."""
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def _looksLikePixel(pid: int) -> bool:
    """True if pid is a live python/pixel process (guards against PID reuse).

    Reads /proc/<pid>/comm (the process name): we only ever signal a PID we wrote
    ourselves AND that still looks like our interpreter/binary, so a recycled
    PID belonging to something unrelated is left alone.
    """
    try:
        with open(file=f"/proc/{pid}/comm", mode="r") as f:
            name = f.read().strip().lower()
    except OSError:
        return False
    return name.startswith("python") or "pixel" in name


def _terminatePid(pid: int) -> bool:
    """Stop a process: SIGTERM, then escalate to SIGKILL. True once it's gone.

    The graceful SIGTERM lets the daemon's handler remove its PID file and exit
    cleanly; if it hasn't died within the grace window we force SIGKILL so the
    caller is GUARANTEED a single instance (never two daemons left running).
    """
    try:
        os.kill(pid, signal.SIGTERM)
    except OSError:
        return True  # already gone
    for _ in range(20):  # ~2 s graceful grace period
        if not _pidAlive(pid):
            return True
        time.sleep(0.1)
    try:
        os.kill(pid, signal.SIGKILL)  # didn't go gracefully -> force it
    except OSError:
        return True
    for _ in range(10):  # ~1 s for the kernel to reap it
        if not _pidAlive(pid):
            return True
        time.sleep(0.1)
    return False  # extremely unlikely (stuck in uninterruptible sleep)


def stopExistingDaemon(scriptDir: str) -> bool:
    """Terminate a previously-launched PIXEL daemon, so only one ever runs.

    Each pixel.sh launch replaces the prior daemon (and shows a fresh code)
    rather than stacking another long-poll loop — N stacked daemons would mean N
    duplicate captures per trigger and N idle polls on the MiSTer. Only signals
    the recorded PID when it's still a live python/pixel process (PID-reuse safe).
    Returns True if a running daemon was found and stopped, False otherwise.
    """
    pid = readDaemonPid(scriptDir=scriptDir)
    if not pid or pid == os.getpid() or not _looksLikePixel(pid=pid):
        return False
    return _terminatePid(pid)


def isDaemonRunning(scriptDir: str) -> bool:
    """True if a PIXEL daemon from a previous launch is still alive."""
    pid = readDaemonPid(scriptDir=scriptDir)
    return bool(pid and pid != os.getpid() and _looksLikePixel(pid=pid) and _pidAlive(pid))


def installShutdownHandler(scriptDir: str) -> None:
    """Make the daemon remove its PID/version files and exit cleanly on SIGTERM/SIGINT.

    So a replace/stop leaves no stale PID/version file behind, and termination is graceful
    (the process is almost always blocked in the long-poll, where the signal
    interrupts the syscall and runs this handler immediately).
    """
    def handler(signum, frame):
        removeDaemonPid(scriptDir=scriptDir)
        removeDaemonVersion(scriptDir=scriptDir)
        os._exit(0)
    signal.signal(signal.SIGTERM, handler)
    signal.signal(signal.SIGINT, handler)


def daemonize(scriptDir: str) -> bool:
    """Detach the current process from the terminal (double-fork + setsid).

    The launcher calls this AFTER showing the pairing code: the parent returns
    (so the MiSTer Scripts menu sees EOF and goes back to the OSD) while the
    child keeps running the poll loop with stdio redirected to pixel.log.
    Returns True in the surviving daemon child, False is never returned (the
    parent exits). Uses only os/stdlib so the client stays dependency-free.
    """
    # First fork: parent returns to the caller (the menu), child continues.
    if os.fork() > 0:
        os._exit(0)
    os.setsid()  # new session, detach from the controlling tty
    # Second fork: prevent the daemon from ever re-acquiring a terminal.
    if os.fork() > 0:
        os._exit(0)

    # Redirect stdio to the log file so prints don't go to the (gone) terminal.
    log_path = os.path.join(scriptDir, LOG_FILENAME)
    sys.stdout.flush()
    sys.stderr.flush()
    devnull = os.open(os.devnull, os.O_RDONLY)
    logfd = os.open(log_path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
    os.dup2(devnull, 0)
    os.dup2(logfd, 1)
    os.dup2(logfd, 2)
    os.close(devnull)
    os.close(logfd)
    return True


def printReady(host: str, web_port: int, code: str, new_device: bool,
               running: bool, linked: bool) -> None:
    """Print the 'PIXEL is ready' banner with the pairing code + URL."""
    print("=" * 44)
    print("  PIXEL is ready.")
    print(f"  On your phone/PC open:  http://{host}:{web_port}")
    print(f"  Enter this code:        {code}")
    if new_device:
        print("  New device — complete registration in your browser.")
    if running:
        print(f"  (a PIXEL client is already running — {'linked' if linked else 'pairing'})")
    print("=" * 44)


def runAsDaemon(cfg: dict, scriptDir: str, host: str, tcp_port: int, web_port: int,
                code: str, compress: bool = True) -> int:
    """Detach into the background and run the poll loop (become THE daemon).

    The parent exits so the MiSTer Scripts menu returns to the OSD; the detached
    child records its PID, installs the clean-shutdown handler, and long-polls
    forever, logging to pixel.log.
    """
    daemonize(scriptDir=scriptDir)
    writeDaemonPid(scriptDir=scriptDir)          # record the detached child's PID
    writeDaemonVersion(scriptDir=scriptDir)      # ...and its version (update detection)
    installShutdownHandler(scriptDir=scriptDir)  # clean exit + remove PID/version files
    print(f"[{datetime.now().isoformat()}] PIXEL daemon started (code {code}).",
          flush=True)
    daemonLoop(cfg=cfg, scriptDir=scriptDir, host=host, tcp_port=tcp_port,
               web_port=web_port, code=code, compress=compress)
    return 0


def launch(cfg: dict, scriptDir: str, host: str, tcp_port: int, web_port: int,
           compress: bool = True) -> int:
    """Scripts-menu entry: register, show the code, wait for a keypress, then act.

    A running daemon on the CURRENT version is NOT restarted by default (wasteful)
    — it's left alone. At the prompt the user can press R to restart it, S to stop
    it, or any other key to proceed. On proceed: start the daemon if none is
    running; if one is running, linked AND on this CLIENT_VERSION, leave it (it
    uses its token, not the code); if it's still pairing OR an OUTDATED build
    (different/missing recorded version, e.g. after a pixel.sh update), replace it
    so the new code actually takes effect — this is what makes a deployed update
    reach the long-poll, not a wasteful restart.
    """
    running = isDaemonRunning(scriptDir=scriptDir)
    linked = bool(cfg.get("token"))

    code, new_device = registerClient(cfg=cfg, host=host, web_port=web_port)
    if not code:
        return 1
    printReady(host=host, web_port=web_port, code=code, new_device=new_device,
               running=running, linked=linked)

    choice = keyPrompt(running=running)

    if running and choice == "s":
        stopExistingDaemon(scriptDir=scriptDir)
        removeDaemonPid(scriptDir=scriptDir)
        removeDaemonVersion(scriptDir=scriptDir)
        print("PIXEL daemon stopped.")
        return 0
    if running and choice == "r":
        stopExistingDaemon(scriptDir=scriptDir)
        print("Restarting the PIXEL client...")
        running = False  # fall through and become the new daemon

    if running:
        running_version = readDaemonVersion(scriptDir=scriptDir)
        if linked and running_version == CLIENT_VERSION:
            # Working linked daemon on the current build: leave it (no wasteful
            # restart). Its token, not the code, keeps it authenticated.
            print("PIXEL is already running — left active.")
            return 0
        # Either mid-pairing (needs the fresh code to fetch its token), or an
        # OUTDATED build (different/missing recorded version after a pixel.sh
        # update): replace it so the new code runs. This is the path that makes a
        # deployed change — e.g. trigger-carried capture settings — actually apply.
        if linked and running_version != CLIENT_VERSION:
            print(f"Updating the running PIXEL client "
                  f"({running_version or 'pre-versioning'} -> {CLIENT_VERSION})...")
        stopExistingDaemon(scriptDir=scriptDir)

    return runAsDaemon(cfg=cfg, scriptDir=scriptDir, host=host, tcp_port=tcp_port,
                       web_port=web_port, code=code, compress=compress)


def fetchDeviceToken(host: str, web_port: int, device_id: str,
                     code: Optional[str]) -> Optional[str]:
    """Exchange the pairing code for this device's auth token (once linked).

    The code (server-issued, shown on the MiSTer screen) proves device
    possession, so a spoofed device_id alone can't obtain the token. Returns the
    token, or None if the device isn't linked yet / the code is no longer valid.
    """
    if not code:
        print("Cannot fetch token: no pairing code available.", flush=True)
        return None
    status, data = httpRequest(host=host, port=web_port, method="POST",
                               path="/api/device-token",
                               body={"device_id": device_id, "code": code})
    if status == 200 and data.get("token"):
        return data["token"]
    print(f"Token fetch failed (status {status}): {data.get('error')}", flush=True)
    return None


def daemonLoop(cfg: dict, scriptDir: str, host: str, tcp_port: int, web_port: int,
               code: Optional[str] = None, compress: bool = True) -> None:
    """The detached poll loop: capture on web trigger, apply settings changes.

    Two phases, both keyed off this device's identity (never an account id):
      * BOOTSTRAP (no token yet): long-poll /api/wait?device_id= until the device
        is linked from the web; then exchange the pairing `code` for the
        per-device token (fetchDeviceToken) and store it.
      * LINKED (has token): long-poll /api/wait authenticating with the token in
        the X-Pixel-Token header (kept out of the URL/logs). On a trigger we
        capture + send (the frame is authenticated by the same token); on a
        settings change we persist + reload. A revoked token (after an unlink)
        is dropped and the loop falls back to bootstrap. Runs until killed.
    """
    device_id = detectDeviceId()
    if not device_id:
        print("Cannot poll: no device_id available (no usable network MAC). "
              "Daemon exiting.", flush=True)
        return

    while True:
        token = cfg.get("token")

        # --- BOOTSTRAP: no token yet ---
        if not token:
            status, data = httpRequest(host=host, port=web_port, method="GET",
                                       path=f"/api/wait?device_id={device_id}", timeout=40.0)
            if status == -1:
                time.sleep(3)
                continue
            if data.get("linked"):
                new_token = fetchDeviceToken(host=host, web_port=web_port,
                                             device_id=device_id, code=code)
                if new_token and saveToken(scriptDir=scriptDir, token=new_token):
                    cfg = loadConfig(scriptDir=scriptDir)
                    print("Device linked — secure token stored.", flush=True)
                else:
                    print("Linked but token fetch failed (pairing code expired?). "
                          "Relaunch PIXEL on the MiSTer to re-pair.", flush=True)
                    time.sleep(5)
            continue  # still unlinked, or just acquired the token: re-poll

        # --- LINKED: authenticate with the per-device token ---
        status, data = httpRequest(host=host, port=web_port, method="GET",
                                   path="/api/wait", timeout=40.0,
                                   headers={"X-Pixel-Token": token})
        if status == -1:
            time.sleep(3)
            continue
        if status == 401 or data.get("error") == "invalid_token":
            print("Device token rejected (unlinked from the web?). Re-bootstrapping.",
                  flush=True)
            deleteToken(scriptDir=scriptDir)
            cfg = loadConfig(scriptDir=scriptDir)
            continue

        # Self-update (web-armed) takes priority over a capture. applyUpdate swaps
        # pixel.sh and spawns the new daemon, which SIGTERMs us; if it returns,
        # the update was refused/failed and we just keep polling on the old build.
        upd = data.get("update")
        if upd:
            applyUpdate(scriptDir=scriptDir, host=host, tcp_port=tcp_port,
                        version=upd.get("version", "?"), url=upd.get("url", ""),
                        sha256_expected=upd.get("sha256", ""))
            continue

        if not data.get("triggered"):
            continue  # timed out; poll again

        # The trigger carries this device's capture instructions (server-
        # authoritative, per device), so a web change applies on the very next
        # trigger. Fall back to the CONF_* defaults if a field is absent.
        if data.get("capture_method"):
            cfg["capture_method"] = data["capture_method"]
        if "delete_screenshot_after" in data:
            cfg["delete_screenshot_after"] = bool(data["delete_screenshot_after"])

        print("Trigger received — capturing...", flush=True)
        try:
            image = capture(cfg=cfg)
        except Exception as e:
            print(f"Capture failed: {e}", flush=True)
            continue
        metadata = buildMetadata(cfg=cfg, image=image)
        asyncio.run(main=sendImage(cfg=cfg, host=host, port=tcp_port, image=image,
                                   metadata=metadata, compress=compress))
        cleanupScreenshot(cfg=cfg, image=image)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    # When run via pixel.sh the source arrives on stdin (no __file__ dir), so
    # the wrapper exports PIXEL_SCRIPT_DIR; fall back to __file__ otherwise.
    scriptDir = os.environ.get("PIXEL_SCRIPT_DIR") or os.path.dirname(p=os.path.abspath(path=__file__))
    cfg = loadConfig(scriptDir=scriptDir)

    parser = argparse.ArgumentParser(description="Capture a MiSTer frame, save and/or send it for translation")
    parser.add_argument("-a", "--server-address", default=cfg["server"],
                        help="Server as host[:port] (default from CONF_SERVER in pixel.sh)")
    parser.add_argument("-s", "--save-path", default=None,
                        help="Path to save the captured raw frame")
    parser.add_argument("--game", default=None,
                        help="Override the detected game title")
    parser.add_argument("--no-compress", action="store_true",
                        help="Send uncompressed RGB instead of zlib")
    parser.add_argument("--once", action="store_true",
                        help="Capture a single frame and send/save it, then exit "
                             "(default is daemon mode)")
    parser.add_argument("--save-only", action="store_true",
                        help="With --once, only save locally (don't send to the server)")
    parser.add_argument("--stop", action="store_true",
                        help="Stop the running PIXEL daemon and exit")
    args = parser.parse_args()

    # --stop: terminate the running daemon (if any) and exit. Explicit, safe
    # shutdown (SIGTERM->SIGKILL escalation) for a 'Stop PIXEL' Scripts entry.
    if args.stop:
        stopped = stopExistingDaemon(scriptDir=scriptDir)
        removeDaemonPid(scriptDir=scriptDir)      # clear any stale PID file too
        removeDaemonVersion(scriptDir=scriptDir)  # ...and the version marker
        print("PIXEL daemon stopped." if stopped else "No running PIXEL daemon found.")
        sys.exit(0)

    if args.game:
        cfg["game"] = args.game

    # Default mode: the Scripts-menu launcher — register, show the pairing code +
    # URL, wait for a keypress (R restart / S stop / any other key proceeds), then
    # start or leave the daemon. One-shot capture is opt-in via --once (tests/debug).
    if not args.once:
        if not args.server_address:
            print("No server configured: edit CONF_SERVER in pixel.sh or pass -a HOST[:PORT]")
            sys.exit(1)
        host, sep, port_str = args.server_address.partition(":")
        tcp_port = int(port_str) if sep and port_str else DEFAULT_PORT
        sys.exit(launch(cfg=cfg, scriptDir=scriptDir, host=host, tcp_port=tcp_port,
                        web_port=cfg["web_port"], compress=not args.no_compress))

    # --once: single capture. Sends to the server unless --save-only / -s only.
    if not args.server_address and not args.save_path:
        print("No action: specify --server-address (or edit CONF_SERVER in pixel.sh) and/or --save-path\n")
        parser.print_help()
        sys.exit(1)

    try:
        image = capture(cfg=cfg)
    except Exception as e:
        print(f"Capture failed: {e}")
        sys.exit(1)
    print(f"Captured: {image.width}x{image.height}, {len(image.data)} bytes "
          f"({image.encoding})")

    metadata = buildMetadata(cfg=cfg, image=image)
    if metadata.get("core") or metadata.get("game"):
        print(f"Context: core={metadata.get('core')} game={metadata.get('game')}")

    if args.save_path:
        saveCapture(image=image, filepath=args.save_path, metadata=metadata)

    ok = True
    do_send = args.server_address and not args.save_only
    if do_send:
        if not cfg.get("token"):
            print("No device token: link this device from the web first "
                  "(run PIXEL as a daemon and complete pairing).")
            sys.exit(1)
        # 3.9: str.partition is positional-only (it never accepted keywords)
        host, sep, port_str = args.server_address.partition(":")
        port = int(port_str) if sep and port_str else DEFAULT_PORT
        ok = asyncio.run(main=sendImage(cfg=cfg, host=host, port=port, image=image,
                                        metadata=metadata, compress=not args.no_compress))

    cleanupScreenshot(cfg=cfg, image=image)
    if do_send:
        sys.exit(0 if ok else 1)
PYEOF
