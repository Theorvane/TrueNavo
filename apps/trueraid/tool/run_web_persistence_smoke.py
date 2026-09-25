#!/usr/bin/env python3
"""Serve a Web build and verify its Drift success marker via CDP."""

from __future__ import annotations

import argparse
import base64
import hashlib
import http.server
import json
import os
import pathlib
import socket
import socketserver
import struct
import subprocess
import tempfile
import threading
import time
import urllib.request
from urllib.parse import urlparse

SUCCESS = "TRUERAID_WEB_PERSISTENCE_OK"
FAILURE = "TRUERAID_WEB_PERSISTENCE_FAILED"


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, format: str, *args: object) -> None:
        print(f"http: {format % args}")


def _free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def _read_http_headers(sock: socket.socket) -> bytes:
    data = bytearray()
    while b"\r\n\r\n" not in data:
        chunk = sock.recv(4096)
        if not chunk:
            break
        data.extend(chunk)
    return bytes(data)


def _connect_websocket(url: str) -> socket.socket:
    parsed = urlparse(url)
    sock = socket.create_connection((parsed.hostname, parsed.port), timeout=5)
    key = base64.b64encode(os.urandom(16)).decode("ascii")
    path = parsed.path + (f"?{parsed.query}" if parsed.query else "")
    request = (
        f"GET {path} HTTP/1.1\r\n"
        f"Host: {parsed.hostname}:{parsed.port}\r\n"
        "Upgrade: websocket\r\nConnection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
    )
    sock.sendall(request.encode("ascii"))
    response = _read_http_headers(sock)
    expected = base64.b64encode(
        hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()
    )
    if not response.startswith(b"HTTP/1.1 101") or expected not in response:
        sock.close()
        raise RuntimeError("Chrome DevTools WebSocket handshake failed")
    return sock


def _send_text(sock: socket.socket, text: str) -> None:
    payload = text.encode("utf-8")
    mask = os.urandom(4)
    length = len(payload)
    header = bytearray([0x81])
    if length < 126:
        header.append(0x80 | length)
    elif length < 65536:
        header.append(0x80 | 126)
        header.extend(struct.pack("!H", length))
    else:
        header.append(0x80 | 127)
        header.extend(struct.pack("!Q", length))
    header.extend(mask)
    header.extend(byte ^ mask[index % 4] for index, byte in enumerate(payload))
    sock.sendall(header)


def _receive_text(sock: socket.socket) -> str:
    first = sock.recv(2)
    if len(first) != 2:
        raise RuntimeError("Chrome DevTools WebSocket closed")
    opcode = first[0] & 0x0F
    length = first[1] & 0x7F
    if length == 126:
        length = struct.unpack("!H", sock.recv(2))[0]
    elif length == 127:
        length = struct.unpack("!Q", sock.recv(8))[0]
    masked = bool(first[1] & 0x80)
    mask = sock.recv(4) if masked else b""
    payload = bytearray()
    while len(payload) < length:
        payload.extend(sock.recv(length - len(payload)))
    if masked:
        payload = bytearray(
            byte ^ mask[index % 4] for index, byte in enumerate(payload)
        )
    if opcode == 0x8:
        raise RuntimeError("Chrome DevTools WebSocket closed")
    if opcode != 0x1:
        return ""
    return payload.decode("utf-8")


def _wait_for_page(debug_port: int, deadline: float) -> str:
    endpoint = f"http://127.0.0.1:{debug_port}/json"
    while time.monotonic() < deadline:
        try:
            with urllib.request.urlopen(endpoint, timeout=1) as response:
                targets = json.load(response)
            for target in targets:
                if (
                    target.get("type") == "page"
                    and str(target.get("url", "")).startswith("http://127.0.0.1:")
                    and target.get("webSocketDebuggerUrl")
                ):
                    print(
                        f"cdp: target url={target.get('url')} "
                        f"title={target.get('title')}"
                    )
                    return str(target["webSocketDebuggerUrl"])
        except Exception:
            time.sleep(0.1)
    raise RuntimeError("Chrome DevTools page target did not become ready")


def _wait_for_marker(websocket_url: str, deadline: float) -> None:
    sock = _connect_websocket(websocket_url)
    sock.settimeout(2)
    request_id = 0
    last_value = ""
    diagnostics: list[str] = []
    try:
        for method in ("Runtime.enable", "Log.enable", "Network.enable"):
            request_id += 1
            _send_text(sock, json.dumps({"id": request_id, "method": method}))
        while time.monotonic() < deadline:
            request_id += 1
            _send_text(
                sock,
                json.dumps(
                    {
                        "id": request_id,
                        "method": "Runtime.evaluate",
                        "params": {"expression": "document.title"},
                    }
                ),
            )
            while time.monotonic() < deadline:
                message = _receive_text(sock)
                if not message:
                    continue
                payload = json.loads(message)
                method = payload.get("method")
                if method in {
                    "Runtime.exceptionThrown",
                    "Log.entryAdded",
                    "Network.loadingFailed",
                }:
                    diagnostics.append(json.dumps(payload)[:2000])
                if payload.get("id") != request_id:
                    continue
                value = (
                    payload.get("result", {})
                    .get("result", {})
                    .get("value", "")
                )
                last_value = str(value)
                if SUCCESS in last_value:
                    return
                if FAILURE in last_value:
                    detail = " | ".join(diagnostics[-5:])
                    raise RuntimeError(
                        f"Web persistence smoke reported failure; diagnostics={detail}"
                    )
                break
            time.sleep(0.1)
    finally:
        sock.close()
    detail = " | ".join(diagnostics[-5:])
    raise RuntimeError(
        f"Web persistence smoke timed out; title={last_value!r}; diagnostics={detail}"
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True)
    parser.add_argument("--chrome", required=True)
    args = parser.parse_args()

    root = pathlib.Path(args.root).resolve(strict=True)
    for name in ("index.html", "sqlite3.wasm", "drift_worker.js"):
        if not (root / name).is_file():
            raise SystemExit(f"missing Web smoke artifact: {name}")

    handler = lambda *values, **kwargs: QuietHandler(  # noqa: E731
        *values, directory=str(root), **kwargs
    )
    with socketserver.ThreadingTCPServer(("127.0.0.1", 0), handler) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        debug_port = _free_port()
        with tempfile.TemporaryDirectory(prefix="trueraid-web-smoke-") as profile:
            chrome = subprocess.Popen(
                [
                    args.chrome,
                    "--headless=new",
                    "--disable-gpu",
                    "--no-sandbox",
                    "--remote-allow-origins=*",
                    f"--remote-debugging-port={debug_port}",
                    f"--user-data-dir={profile}",
                    f"http://127.0.0.1:{server.server_address[1]}/",
                ],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            deadline = time.monotonic() + 60
            try:
                websocket_url = _wait_for_page(debug_port, deadline)
                _wait_for_marker(websocket_url, deadline)
            finally:
                chrome.terminate()
                try:
                    chrome.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    chrome.kill()
                    chrome.wait(timeout=5)
        server.shutdown()

    print(SUCCESS)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
