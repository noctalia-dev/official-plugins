#!/usr/bin/env python3
"""Stream a Wallhaven preview with a draggable monitor-aspect crop box.

The shell sends pointer positions through panel.luau as a small JSON state file;
this process redraws the overlay and serves the RGBA frames over Noctalia's
pixel-stream protocol.  Keeping the image work out of the plugin runtime avoids
blocking the UI while the crop box moves.
"""

from __future__ import annotations

import argparse
import array
import fcntl
import json
import math
import mmap
import os
import shutil
import signal
import socket
import struct
import subprocess
import sys
import threading
import time
from pathlib import Path

IDLE_SECONDS = 600.0

# ImageMagick 7 exposes `magick`; ImageMagick 6 exposes `convert` and `identify`.
MAGICK = shutil.which("magick")
CONVERT = [MAGICK] if MAGICK else ([shutil.which("convert")] if shutil.which("convert") else [])
IDENTIFY = [MAGICK, "identify"] if MAGICK else ([shutil.which("identify")] if shutil.which("identify") else [])


def clamp(value: float, low: float, high: float) -> float:
    return max(low, min(value, high))


def as_float(value: object, default: float = 0.0) -> float:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return default
    return number if math.isfinite(number) else default


def identify(path: Path) -> tuple[int, int]:
    if not IDENTIFY:
        raise RuntimeError("ImageMagick identify not found")
    result = subprocess.run(
        [*IDENTIFY, "-format", "%w %h", str(path)],
        check=True,
        capture_output=True,
        text=True,
    )
    parts = result.stdout.split()
    if len(parts) < 2:
        raise ValueError("could not read image dimensions")
    return int(parts[0]), int(parts[1])


DARKEN_TABLE = bytes(min(255, value * 45 // 100) for value in range(256))


def darken(raw: bytes) -> bytes:
    output = bytearray(raw)
    for channel in range(3):
        output[channel::4] = raw[channel::4].translate(DARKEN_TABLE)
    return bytes(output)


def load_frame(
    path: Path,
    width: int,
    height: int,
    image_width: int | None = None,
    image_height: int | None = None,
) -> tuple[bytes, bytes, int, int, int, int, int, int]:
    if image_width is None or image_height is None:
        image_width, image_height = identify(path)
    if image_width <= 0 or image_height <= 0:
        raise ValueError("invalid image dimensions")
    scale = min(width / image_width, height / image_height)
    display_width = max(1, round(image_width * scale))
    display_height = max(1, round(image_height * scale))
    if not CONVERT:
        raise RuntimeError("ImageMagick not found")
    raw = subprocess.run(
        [
            *CONVERT,
            # Let libjpeg decode large JPEGs at a reduced scale; the preview
            # does not need the full source resolution.
            "-define", f"jpeg:size={width * 2}x{height * 2}",
            str(path),
            "-filter", "Triangle",
            "-resize", f"{display_width}x{display_height}!",
            "-background", "none",
            "-gravity", "center",
            "-extent", f"{width}x{height}",
            # Source images can be 16-bit (for example PNG gradients); the pixel
            # stream expects tightly packed 8-bit RGBA.
            "-depth", "8",
            "rgba:-",
        ],
        check=True,
        capture_output=True,
    ).stdout
    expected = width * height * 4
    if len(raw) != expected:
        raise ValueError(f"expected {expected} bytes, got {len(raw)}")
    display_x = (width - display_width) // 2
    display_y = (height - display_height) // 2
    return raw, darken(raw), display_width, display_height, display_x, display_y, image_width, image_height


class FrameServer:
    def __init__(self, path: Path, width: int, height: int):
        if not (0 < width <= 4096 and 0 < height <= 4096 and width * height <= 4194304):
            raise ValueError("invalid frame size")
        self.path = path
        self.width = width
        self.height = height
        self.stopped = threading.Event()
        self.condition = threading.Condition()
        self.latest: bytes | None = None
        self.version = 0
        self.clients: set[socket.socket] = set()
        self.clients_lock = threading.Lock()
        self.last_client = time.monotonic()
        self.ever_connected = False
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
        try:
            if self.path.exists():
                probe = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
                try:
                    probe.connect(str(self.path))
                except OSError:
                    self.path.unlink(missing_ok=True)
                finally:
                    probe.close()
            self.server.bind(str(self.path))
            os.chmod(self.path, 0o600)
            self.identity = self.path.lstat()
            self.server.listen(4)
            self.server.settimeout(0.25)
        except Exception:
            self.server.close()
            try:
                self.path.unlink(missing_ok=True)
            except OSError:
                pass
            raise
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()

    def update(self, frame: bytes) -> None:
        with self.condition:
            self.latest = frame
            self.version += 1
            self.condition.notify_all()

    def receive(self, client: socket.socket, *, deadline: float | None = None) -> tuple[int, int] | None:
        while not self.stopped.is_set():
            if deadline is not None and time.monotonic() >= deadline:
                return None
            try:
                data, ancillary, flags, _ = client.recvmsg(8, socket.CMSG_SPACE(16), socket.MSG_CMSG_CLOEXEC)
            except socket.timeout:
                continue
            for level, kind, value in ancillary:
                if level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS:
                    descriptors = array.array("i")
                    descriptors.frombytes(value[: len(value) // descriptors.itemsize * descriptors.itemsize])
                    for descriptor in descriptors:
                        os.close(descriptor)
            if len(data) != 8 or ancillary or flags & (socket.MSG_TRUNC | socket.MSG_CTRUNC):
                return None
            return struct.unpack("<II", data)
        return None

    def stream(self, client: socket.socket) -> None:
        if self.receive(client, deadline=time.monotonic() + 2) != (1, 1):
            return
        size = self.width * self.height * 4
        descriptor = os.memfd_create("wallhaven-crop", os.MFD_CLOEXEC | os.MFD_ALLOW_SEALING)
        try:
            os.ftruncate(descriptor, size)
            fcntl.fcntl(descriptor, fcntl.F_ADD_SEALS, fcntl.F_SEAL_SHRINK | fcntl.F_SEAL_GROW | fcntl.F_SEAL_SEAL)
            with mmap.mmap(descriptor, size, access=mmap.ACCESS_WRITE) as buffer:
                sent, attached = -1, False
                while self.receive(client) == (2, 0):
                    with self.condition:
                        self.condition.wait_for(
                            lambda: self.stopped.is_set() or (self.latest is not None and sent != self.version)
                        )
                        if self.stopped.is_set():
                            return
                        frame, sent = self.latest, self.version
                    buffer[:] = frame
                    if not attached:
                        message = struct.pack("<IIII", 1, 0, self.width, self.height)
                        rights = [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array("i", [descriptor]))]
                        if client.sendmsg([message], rights) != len(message):
                            return
                        attached = True
                    if client.send(struct.pack("<II", 2, 0)) != 8:
                        return
        finally:
            os.close(descriptor)

    def handle_client(self, client: socket.socket) -> None:
        # A re-created widget can overlap the previous client for a frame, so each
        # connection gets its own thread instead of replacing the active stream.
        try:
            with client:
                self.stream(client)
        except (OSError, ValueError):
            pass
        finally:
            with self.clients_lock:
                self.clients.discard(client)
                idle = not self.clients
            if idle:
                self.last_client = time.monotonic()

    def serve(self) -> None:
        while not self.stopped.is_set():
            try:
                client, _ = self.server.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            try:
                credentials = client.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i"))
            except OSError:
                client.close()
                continue
            if struct.unpack("3i", credentials)[1] != os.geteuid():
                client.close()
                continue
            self.ever_connected = True
            client.settimeout(0.25)
            with self.clients_lock:
                self.clients.add(client)
            threading.Thread(target=self.handle_client, args=(client,), daemon=True).start()

    def has_clients(self) -> bool:
        with self.clients_lock:
            return bool(self.clients)

    def stop(self) -> None:
        self.stopped.set()
        with self.condition:
            self.condition.notify_all()
        with self.clients_lock:
            clients = list(self.clients)
        for client in clients:
            try:
                client.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
        self.server.close()
        self.thread.join(timeout=2)
        try:
            current = self.path.lstat()
            if (current.st_dev, current.st_ino) == (self.identity.st_dev, self.identity.st_ino):
                self.path.unlink()
        except FileNotFoundError:
            pass


def make_frame(
    base: bytes,
    dark: bytes,
    width: int,
    height: int,
    display_width: int,
    display_height: int,
    display_x: int,
    display_y: int,
    image_width: int,
    image_height: int,
    state: dict,
) -> bytes:
    if not state.get("fit", True):
        return base

    monitor_width = as_float(state.get("monitorWidth"))
    monitor_height = as_float(state.get("monitorHeight"))
    if monitor_width <= 0 or monitor_height <= 0:
        monitor_width, monitor_height = display_width, display_height

    scale = min(1.0, image_width / monitor_width, image_height / monitor_height)
    display_scale = display_width / image_width
    box_width = monitor_width * scale * display_scale
    box_height = monitor_height * scale * display_scale
    box_width = max(1.0, min(box_width, float(display_width)))
    box_height = max(1.0, min(box_height, float(display_height)))

    center_x = display_x + clamp(as_float(state.get("cx"), 0.5), 0.0, 1.0) * display_width
    center_y = display_y + clamp(as_float(state.get("cy"), 0.5), 0.0, 1.0) * display_height
    x0 = round(center_x - box_width / 2)
    y0 = round(center_y - box_height / 2)
    x0 = max(0, max(display_x, min(x0, display_x + display_width - round(box_width))))
    y0 = max(0, max(display_y, min(y0, display_y + display_height - round(box_height))))
    x0 = min(x0, width - 1)
    y0 = min(y0, height - 1)
    x1 = max(x0 + 1, min(width, x0 + round(box_width)))
    y1 = max(y0 + 1, min(height, y0 + round(box_height)))

    frame = bytearray(base)
    for y in range(height):
        row = y * width * 4
        if y < y0 or y >= y1:
            frame[row : row + width * 4] = dark[row : row + width * 4]
        else:
            frame[row : row + x0 * 4] = dark[row : row + x0 * 4]
            frame[row + x1 * 4 : row + width * 4] = dark[row + x1 * 4 : row + width * 4]
    return bytes(frame)


def read_state(path: Path) -> tuple[int, dict] | None:
    try:
        mtime = path.stat().st_mtime_ns
        state = json.loads(path.read_text())
    except (FileNotFoundError, OSError, json.JSONDecodeError):
        return None
    if not isinstance(state, dict):
        return None
    return mtime, state


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True)
    parser.add_argument("--state", required=True)
    parser.add_argument("--image", required=True)
    parser.add_argument("--image-width", type=int)
    parser.add_argument("--image-height", type=int)
    parser.add_argument("--width", type=int, required=True)
    parser.add_argument("--height", type=int, required=True)
    args = parser.parse_args()

    image_path = Path(args.image)
    socket_path = Path(args.socket)
    state_path = Path(args.state)
    pid_path = Path(f"{state_path}.pid")
    try:
        pid_path.write_text(str(os.getpid()))
    except OSError:
        pass
    try:
        base, dark, display_width, display_height, display_x, display_y, image_width, image_height = load_frame(
            image_path, args.width, args.height, args.image_width, args.image_height
        )
        server = FrameServer(socket_path, args.width, args.height)
    except Exception as error:
        try:
            pid_path.unlink(missing_ok=True)
        except OSError:
            pass
        print(f"wallhaven crop stream: {error}", file=sys.stderr)
        return 1

    stop = threading.Event()

    def shutdown(_signum, _frame):
        stop.set()

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    started = time.monotonic()
    last_mtime: int | None = None
    last_state: dict | None = None
    try:
        while not stop.is_set():
            current = read_state(state_path)
            if current is not None:
                mtime, state = current
                if mtime != last_mtime:
                    last_mtime = mtime
                    if state.get("quit"):
                        break
                    if state != last_state:
                        last_state = state
                        server.update(make_frame(
                            base, dark, args.width, args.height,
                            display_width, display_height, display_x, display_y,
                            image_width, image_height, state,
                        ))
            now = time.monotonic()
            if not server.has_clients() and server.ever_connected and now - server.last_client > IDLE_SECONDS:
                break
            if not server.ever_connected and now - started > IDLE_SECONDS:
                break
            stop.wait(0.03)
    finally:
        try:
            server.stop()
        finally:
            # The socket is removed by stop(); remove the matching state file too.
            try:
                state_path.unlink()
            except OSError:
                pass
            try:
                pid_path.unlink(missing_ok=True)
            except OSError:
                pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
