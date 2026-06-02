#!/usr/bin/env python3
"""Persistent CDP WebSocket holder for the virtual WebAuthn authenticator.

The Chrome DevTools Protocol scopes `WebAuthn.enable` to a single WebSocket
session — when the connection closes, the virtual authenticator added through
that session is destroyed. Browser test scenarios therefore need a process
that:

  1. Connects to the page's CDP WebSocket.
  2. Enables the WebAuthn domain on that session.
  3. Adds a virtual authenticator and reports its id.
  4. Keeps the connection open until killed by the launching shell.
  5. Lets the OS close the WebSocket on exit, which CDP-cleans the authenticator.

The launching shell (`_lib.sh::attach_virtual_authenticator`) detects ready
state by polling the helper's stdout for a `READY <authenticatorId>` line.
Failures are reported as `ERROR <detail>` and exit code 1.

Usage:
  python3 _cdp_webauthn_holder.py <page-websocket-url>
"""

from __future__ import annotations

import asyncio
import json
import signal
import sys

try:
    import websockets
except ImportError:
    print("ERROR websockets package not installed (pip install websockets)", flush=True)
    sys.exit(1)


AUTHENTICATOR_OPTIONS = {
    "protocol": "ctap2",
    "transport": "internal",
    "hasResidentKey": True,
    "hasUserVerification": True,
    "isUserVerified": True,
}


async def run(ws_url: str) -> int:
    async with websockets.connect(ws_url) as ws:
        # Step 1: enable the WebAuthn CDP domain on this session.
        await ws.send(json.dumps({
            "id": 1,
            "method": "WebAuthn.enable",
            "params": {"enableUI": False},
        }))
        enable_response = json.loads(await asyncio.wait_for(ws.recv(), timeout=5))
        if "error" in enable_response:
            print(f"ERROR WebAuthn.enable failed: {enable_response['error']}", flush=True)
            return 1

        # Step 2: add the virtual authenticator and capture its id.
        await ws.send(json.dumps({
            "id": 2,
            "method": "WebAuthn.addVirtualAuthenticator",
            "params": {"options": AUTHENTICATOR_OPTIONS},
        }))
        add_response = json.loads(await asyncio.wait_for(ws.recv(), timeout=5))
        if "error" in add_response:
            print(f"ERROR WebAuthn.addVirtualAuthenticator failed: {add_response['error']}", flush=True)
            return 1

        authenticator_id = add_response.get("result", {}).get("authenticatorId", "")
        if not authenticator_id:
            print(f"ERROR addVirtualAuthenticator returned no authenticatorId: {add_response}", flush=True)
            return 1

        print(f"READY {authenticator_id}", flush=True)

        # Step 3: hold the connection open until SIGTERM/SIGINT. CDP destroys
        # the virtual authenticator automatically when this WebSocket closes.
        stop = asyncio.Event()
        loop = asyncio.get_running_loop()
        for sig in (signal.SIGTERM, signal.SIGINT):
            loop.add_signal_handler(sig, stop.set)
        await stop.wait()
        return 0


def main() -> int:
    if len(sys.argv) != 2:
        print("ERROR usage: _cdp_webauthn_holder.py <page-websocket-url>", flush=True)
        return 1
    ws_url = sys.argv[1]
    try:
        return asyncio.run(run(ws_url))
    except Exception as exc:  # noqa: BLE001 — surface all failures to launcher
        print(f"ERROR {type(exc).__name__}: {exc}", flush=True)
        return 1


if __name__ == "__main__":
    sys.exit(main())
