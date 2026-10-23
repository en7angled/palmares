#!/usr/bin/env python3
"""Host-side half of the node-socket bridge: UNIX socket -> TCP.

The node socket lives in a NAMED Docker volume because a UNIX socket in a macOS bind mount does not
work (experiments/dbsync-preprod/compose.yaml:55). `palmares-nodefwd` publishes it as TCP on
127.0.0.1:13001; this relay puts a UNIX socket back on the host so Atlas's `GYNodeKupo` provider,
which takes a filesystem `socketPath`, can reach it.

The path is short on purpose: macOS caps sun_path at ~104 bytes, and the session scratchpad path is
longer than that on its own.

ponytail: stdlib asyncio, no socat install. Throwaway plumbing for a host-run CLI; a Linux host or a
containerised admin needs none of it.
"""

import asyncio
import os
import signal

UNIX_PATH = "/tmp/palmares-node.socket"
TCP_HOST = "127.0.0.1"
TCP_PORT = 13001

conns = 0


async def pump(reader, writer):
    try:
        while True:
            chunk = await reader.read(65536)
            if not chunk:
                break
            writer.write(chunk)
            await writer.drain()
    except (ConnectionResetError, BrokenPipeError, asyncio.CancelledError):
        pass
    finally:
        try:
            writer.close()
        except Exception:
            pass


async def handle(client_reader, client_writer):
    global conns
    conns += 1
    n = conns
    try:
        up_reader, up_writer = await asyncio.open_connection(TCP_HOST, TCP_PORT)
    except Exception as exc:
        print(f"[{n}] upstream {TCP_HOST}:{TCP_PORT} refused: {exc}", flush=True)
        client_writer.close()
        return
    print(f"[{n}] bridged", flush=True)
    await asyncio.gather(
        pump(client_reader, up_writer),
        pump(up_reader, client_writer),
    )
    print(f"[{n}] closed", flush=True)


async def main():
    if os.path.exists(UNIX_PATH):
        os.unlink(UNIX_PATH)
    server = await asyncio.start_unix_server(handle, path=UNIX_PATH)
    print(f"relay up: {UNIX_PATH} -> {TCP_HOST}:{TCP_PORT}", flush=True)

    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, stop.set)

    async with server:
        await stop.wait()
    if os.path.exists(UNIX_PATH):
        os.unlink(UNIX_PATH)
    print("relay down", flush=True)


asyncio.run(main())
