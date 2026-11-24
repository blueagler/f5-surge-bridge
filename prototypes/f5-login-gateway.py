"""Loopback-only CONNECT relay for the UW F5 gateway on a physical interface."""

import selectors
import socket
import socketserver
import struct
import subprocess
import sys


GATEWAY = "huskyonnet.uw.edu"
IP_BOUND_IF = 25  # macOS <netinet/in.h>


def active_physical_interface() -> str:
    output = subprocess.check_output(["/usr/sbin/netstat", "-rn", "-f", "inet"], text=True)
    for line in output.splitlines():
        fields = line.split()
        if len(fields) >= 4 and fields[0] == "default" and fields[-1].startswith("en"):
            return fields[-1]
    raise RuntimeError("No active physical default interface found")


def resolve_gateway(interface_bytes: bytes) -> str:
    address = socket.gethostbyname(GATEWAY)
    octets = address.split(".")
    if len(octets) == 4 and octets[0] == "198" and octets[1] in {"18", "19"}:
        # Surge Enhanced Mode may return a 198.18.0.0/15 fake IP; query 1.1.1.1 directly on the physical NIC.
        labels = b"".join(bytes([len(p)]) + p.encode("ascii") for p in GATEWAY.split(".")) + b"\x00"
        query = b"\xab\xcd\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00" + labels + b"\x00\x01\x00\x01"
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as dns:
            dns.setsockopt(socket.IPPROTO_IP, IP_BOUND_IF, interface_bytes)
            dns.settimeout(5)
            dns.sendto(query, ("1.1.1.1", 53))
            resp, _ = dns.recvfrom(512)
        pos = 12
        while pos < len(resp) and resp[pos] != 0:
            pos += 1 + resp[pos]
        pos += 5
        ancount = struct.unpack("!H", resp[6:8])[0]
        for _ in range(ancount):
            if pos >= len(resp):
                break
            pos += 2 if (resp[pos] & 0xC0) == 0xC0 else 1
            rtype, _, _, rdlen = struct.unpack("!HHIH", resp[pos:pos + 10])
            pos += 10
            if rtype == 1 and rdlen == 4:
                return socket.inet_ntoa(resp[pos:pos + 4])
            pos += rdlen
    return address


class GatewayRelay(socketserver.StreamRequestHandler):
    def handle(self):
        self.connection.settimeout(12)
        request = self.rfile.readline(4096).split()
        if len(request) != 3 or request[:2] != [b"CONNECT", b"huskyonnet.uw.edu:443"]:
            self.wfile.write(b"HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n")
            return

        for _ in range(50):
            line = self.rfile.readline(8192)
            if line == b"\r\n":
                break
            if not line.endswith(b"\r\n"):
                return
        else:
            return

        try:
            address = resolve_gateway(self.server.interface)
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as remote:
                remote.setsockopt(socket.IPPROTO_IP, IP_BOUND_IF, self.server.interface)
                remote.settimeout(12)
                remote.connect((address, 443))
                remote.settimeout(None)
                self.connection.settimeout(None)
                self.wfile.write(b"HTTP/1.1 200 Connection Established\r\n\r\n")
                self.forward(remote)
        except OSError:
            return

    def forward(self, remote):
        with selectors.DefaultSelector() as selector:
            selector.register(self.connection, selectors.EVENT_READ, remote)
            selector.register(remote, selectors.EVENT_READ, self.connection)
            while events := selector.select():
                for key, _ in events:
                    data = key.fileobj.recv(16384)
                    if not data:
                        return
                    key.data.sendall(data)


if __name__ == "__main__":
    if sys.platform != "darwin" or len(sys.argv) != 2:
        sys.exit("Usage: python3 f5-login-gateway.py <physical-interface|auto>")
    iface = active_physical_interface() if sys.argv[1] == "auto" else sys.argv[1]
    with socketserver.ThreadingTCPServer(("127.0.0.1", 0), GatewayRelay) as server:
        server.daemon_threads = True
        server.allow_reuse_address = True
        server.interface = struct.pack("=I", socket.if_nametoindex(iface))
        print(server.server_address[1], flush=True)
        server.serve_forever()
