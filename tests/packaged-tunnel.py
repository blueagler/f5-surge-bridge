#!/usr/bin/env python3
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import time


def start_tunnel(app, home, port, ipv6, send_buffer=1000, rule_stem="test-rules"):
    resources = app / "Contents" / "Resources" / "bin"
    left, right = socket.socketpair(socket.AF_UNIX, socket.SOCK_DGRAM)
    right.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, send_buffer)
    assert right.getsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF) == send_buffer
    env = os.environ.copy()
    env.update({
        "HOME": str(home),
        "VPNFD": str(right.fileno()),
        "INTERNAL_IP4_ADDRESS": "10.0.0.2",
        "INTERNAL_IP4_MTU": "1400",
        "INTERNAL_IP4_DNS": "10.0.0.1",
        "INTERNAL_IP6_ADDRESS": ipv6,
        "INTERNAL_IP6_NETMASK": "::/0" if ipv6 == "::" else "",
        "INTERNAL_IP6_DNS": "fd00::53",
        "CISCO_DEF_DOMAIN": "example.test",
        "CISCO_SPLIT_INC": "1",
        "CISCO_SPLIT_INC_0_ADDR": "10.20.0.0",
        "CISCO_SPLIT_INC_0_MASKLEN": "16",
        "CISCO_IPV6_SPLIT_INC": "1",
        "CISCO_IPV6_SPLIT_INC_0_ADDR": "fd20::",
        "CISCO_IPV6_SPLIT_INC_0_MASKLEN": "64",
        "CISCO_SPLIT_EXC": "1",
        "CISCO_SPLIT_EXC_0_ADDR": "10.30.0.0",
        "CISCO_SPLIT_EXC_0_MASKLEN": "24",
        "CISCO_IPV6_SPLIT_EXC": "1",
        "CISCO_IPV6_SPLIT_EXC_0_ADDR": "fd30::",
        "CISCO_IPV6_SPLIT_EXC_0_MASKLEN": "64",
    })
    proc = subprocess.Popen(
        [str(resources / "tun-bridge.sh"), "fixture", str(port), rule_stem],
        env=env,
        pass_fds=(right.fileno(),),
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    right.close()
    return proc, left


def wait_for_greeting(proc, port):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            raise AssertionError(f"packaged helper exited: {proc.stdout.read()}")
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2) as client:
                client.settimeout(2)
                client.sendall(b"\x05\x01\x00")
                assert client.recv(2) == b"\x05\x00"
                return
        except OSError:
            time.sleep(0.02)
    raise AssertionError("packaged helper did not accept SOCKS5 connections")


def stop_tunnel(proc, peer):
    if proc.poll() is None:
        proc.send_signal(signal.SIGHUP)
    try:
        output = proc.communicate(timeout=5)[0]
    except subprocess.TimeoutExpired:
        proc.kill()
        output = proc.communicate()[0]
        raise AssertionError(f"packaged helper did not stop: {output}")
    peer.close()
    assert proc.returncode == 0, output


def rule_lines(home, suffix):
    path = home / "Library" / "Application Support" / "UWVPN" / f"test-rules-{suffix}.list"
    assert path.is_file(), f"missing {path}"
    return [line for line in path.read_text().splitlines() if not line.startswith("#")]


def main():
    assert len(sys.argv) == 2, "usage: tests/packaged-tunnel.py path/to/UWVPN.app"
    app = Path(sys.argv[1]).resolve()
    for name in ("tun-bridge.sh", "tun-socks"):
        assert os.access(app / "Contents" / "Resources" / "bin" / name, os.X_OK), f"missing packaged {name}"
    with tempfile.TemporaryDirectory(prefix="uwvpn-packaged-") as temporary:
        isolated = Path(temporary)
        home = isolated / "home"
        home.mkdir()
        probe = socket.socket()
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
        probe.close()
        for ipv6, send_buffer, expected_v6 in (
            ("::", 1000, []),
            ("fd00::2/64", 1000, []),
            ("fd00::2/64", 8192, [
                "IP-CIDR6,fd20::/64,no-resolve",
                "IP-CIDR6,fd30::/64,no-resolve",
            ]),
        ):
            proc, peer = start_tunnel(app, home, port, ipv6, send_buffer)
            try:
                wait_for_greeting(proc, port)
                split = rule_lines(home, "split")
                exclude = rule_lines(home, "exclude")
                assert "IP-CIDR,10.20.0.0/16,no-resolve" in split, split
                assert "DOMAIN-SUFFIX,example.test" in split, split
                assert "IP-CIDR,10.30.0.0/24,no-resolve" in exclude, exclude
                actual_v6 = [line for line in split + exclude if "IP-CIDR6" in line]
                assert actual_v6 == expected_v6, (ipv6, actual_v6)
                print(f"PASS SO_SNDBUF={send_buffer} IPv6={ipv6 or 'unconfigured'} rules={actual_v6}")
            finally:
                stop_tunnel(proc, peer)

        blocker = socket.socket()
        blocker.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        blocker.bind(("127.0.0.1", 0))
        blocker.listen()
        occupied = blocker.getsockname()[1]
        for path in (home / "Library" / "Application Support" / "UWVPN").glob("test-rules-*.list"):
            path.unlink()
        proc, peer = start_tunnel(app, home, occupied, "fd00::2/64")
        try:
            output = proc.communicate(timeout=5)[0]
            assert proc.returncode != 0, "occupied SOCKS port unexpectedly started"
            assert not list((home / "Library" / "Application Support" / "UWVPN").glob("test-rules-*.list")), output
            print("PASS occupied SOCKS port publishes no split rules")
        finally:
            peer.close()
            if proc.poll() is None:
                proc.kill()
                proc.wait()
            blocker.close()

        proc, peer = start_tunnel(app, home, port, "::", rule_stem="")
        try:
            wait_for_greeting(proc, port)
            assert not list((home / "Library" / "Application Support" / "UWVPN").glob("*.list"))
            print("PASS gateway with split rules disabled publishes no rules")
        finally:
            stop_tunnel(proc, peer)


if __name__ == "__main__":
    main()
