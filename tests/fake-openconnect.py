#!/usr/bin/env python3
import os
import signal
import socket
import sys

sys.stdin.readline()
parent = os.getpid()
with socket.socket() as listener:
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", int(os.environ["UWVPN_FIXTURE_PORT"])))
    ready, release = os.pipe()
    child = os.fork()
    if child == 0:
        os.close(release)
        if not os.read(ready, 1):
            sys.exit(1)
        os.close(ready)
        listener.listen()
        while True:
            with listener.accept()[0] as client:
                with client.makefile("rb") as request:
                    if request.read(3) == b"\x05\x01\x00":
                        client.sendall(b"\x05\x00")

    def stop(signum, frame):
        try:
            os.kill(child, signal.SIGTERM)
        except ProcessLookupError:
            pass
        os.waitpid(child, 0)
        sys.exit(0)

    signal.signal(signal.SIGHUP, stop)
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGALRM, stop)
    signal.alarm(20)
    listener.close()
    os.close(ready)
    with open(os.environ["UWVPN_FIXTURE_PIDS"], "w", encoding="utf-8") as record:
        print(parent, child, file=record)
    os.write(release, b"1")
    os.close(release)
    while True:
        signal.pause()
