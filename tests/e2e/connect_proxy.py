"""Tiny HTTP CONNECT proxy standing in for tinyproxy on the VM (e2e tests only).

usage: python3 -I connect_proxy.py <port> [--record <file>]
Answers CONNECT host:port with 200 and splices bytes both ways; anything else
gets 405. Listens on 127.0.0.1 only. With --record, every request line is
appended to <file> and CONNECT is refused (403) - to see where a client sends
its traffic without letting it through.
"""
import asyncio
import sys

RECORD = None


async def pipe(reader, writer):
    try:
        while data := await reader.read(65536):
            writer.write(data)
            await writer.drain()
    except (ConnectionError, asyncio.CancelledError):
        pass
    finally:
        writer.close()


async def handle(reader, writer):
    try:
        head = await reader.readuntil(b"\r\n\r\n")
        line = head.split(b"\r\n", 1)[0].decode("latin-1")
        method, target, _ = line.split(" ", 2)
        if RECORD:
            with open(RECORD, "a") as f:
                f.write(line + "\n")
            writer.write(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n")
            await writer.drain()
            writer.close()
            return
        if method != "CONNECT":
            writer.write(b"HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\n\r\n")
            await writer.drain()
            writer.close()
            return
        host, port = target.rsplit(":", 1)
        up_reader, up_writer = await asyncio.wait_for(asyncio.open_connection(host, int(port)), 10)
    except Exception:
        writer.write(b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n")
        writer.close()
        return
    writer.write(b"HTTP/1.1 200 Connection established\r\n\r\n")
    await writer.drain()
    await asyncio.gather(pipe(reader, up_writer), pipe(up_reader, writer))


async def main(port):
    server = await asyncio.start_server(handle, "127.0.0.1", port)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[2] == "--record":
        RECORD = sys.argv[3]
    asyncio.run(main(int(sys.argv[1])))
