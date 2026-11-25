package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"io"
	"net"
	"net/netip"
	"testing"
	"time"

	"gvisor.dev/gvisor/pkg/tcpip/adapters/gonet"
)

func TestSOCKSGreetingAtFlowCapacity(t *testing.T) {
	listener, err := net.ListenTCP("tcp4", &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	client, err := net.DialTCP("tcp4", nil, listener.Addr().(*net.TCPAddr))
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	conn, err := listener.AcceptTCP()
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	handshakes := make(chan struct{}, 1)
	active := make(chan struct{}, 1)
	handshakes <- struct{}{}
	active <- struct{}{}
	vpn := &tunnel{}
	go vpn.handle(context.Background(), conn, handshakes, active)
	client.SetDeadline(time.Now().Add(2 * time.Second))
	client.Write([]byte{5, 1, 0})
	var greeting [2]byte
	if _, err := io.ReadFull(client, greeting[:]); err != nil || greeting != [2]byte{5, 0} {
		t.Fatalf("greeting under load = %v, %v", greeting, err)
	}
	client.Write(addressMessage([]byte{5, connect, 0}, netip.MustParseAddrPort("10.0.0.1:443")))
	var reply [10]byte
	if _, err := io.ReadFull(client, reply[:]); err != nil || reply[1] != 1 {
		t.Fatalf("request at capacity = %v, %v", reply, err)
	}
}

func TestDefaultIPv6RouteWithoutAddress(t *testing.T) {
	t.Setenv("INTERNAL_IP4_ADDRESS", "10.0.0.2")
	t.Setenv("INTERNAL_IP6_ADDRESS", "::")
	t.Setenv("INTERNAL_IP6_NETMASK", "::/0")
	vpn, err := newTunnel(maxVPNDatagram)
	if err != nil {
		t.Fatal(err)
	}
	defer vpn.stack.Destroy()
	defer vpn.link.Close()
	if !vpn.supports(netip.MustParseAddr("10.0.0.1")) || vpn.supports(netip.MustParseAddr("fd00::1")) {
		t.Fatal("the advertised IPv6 default route must not disable IPv4 or enable IPv6 without a source address")
	}
}

func TestSOCKSTunnel(t *testing.T) {
	t.Setenv("INTERNAL_IP4_MTU", "1400")
	t.Setenv("INTERNAL_IP4_DNS", "10.0.0.1")
	t.Setenv("INTERNAL_IP6_DNS", "")
	makeTunnel := func(v4, v6 string) *tunnel {
		t.Setenv("INTERNAL_IP4_ADDRESS", v4)
		t.Setenv("INTERNAL_IP6_ADDRESS", v6)
		vpn, err := newTunnel(maxVPNDatagram)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(vpn.stack.Destroy)
		t.Cleanup(vpn.link.Close)
		return vpn
	}
	vpn := makeTunnel("10.0.0.2", "fd00::2/64")
	peer := makeTunnel("10.0.0.1", "fd00::1")
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	linkA, linkB := net.Pipe()
	t.Cleanup(func() { linkA.Close(); linkB.Close() })
	go vpn.receive(linkA)
	go vpn.transmit(ctx, linkA)
	go peer.receive(linkB)
	go peer.transmit(ctx, linkB)
	listener, err := net.ListenTCP("tcp4", &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close() })
	go vpn.serve(ctx, listener)
	dnsAddress := netip.MustParseAddrPort("10.0.0.1:53")
	dnsLocal := fullAddress(dnsAddress)
	dnsServer, err := gonet.DialUDP(peer.stack, &dnsLocal, nil, networkProtocol(dnsAddress.Addr()))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { dnsServer.Close() })
	go serveTestDNS(dnsServer)
	t.Run("DNS through tunnel", func(t *testing.T) {
		results := vpn.resolve(ctx, destination{host: "dual-stack.invalid", port: 8080})
		want := []netip.AddrPort{netip.MustParseAddrPort("10.0.0.1:8080"), netip.MustParseAddrPort("[fd00::1]:8080")}
		if len(results) != 2 || !(results[0] == want[0] && results[1] == want[1] || results[0] == want[1] && results[1] == want[0]) {
			t.Fatalf("resolved %v; want %v in either order", results, want)
		}
	})

	openControl := func(t *testing.T, command byte, endpoint netip.AddrPort) (*net.TCPConn, destination) {
		t.Helper()
		conn, err := net.DialTCP("tcp4", nil, listener.Addr().(*net.TCPAddr))
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { conn.Close() })
		conn.SetDeadline(time.Now().Add(5 * time.Second))
		conn.Write([]byte{5, 1, 0})
		var choice [2]byte
		if _, err := io.ReadFull(conn, choice[:]); err != nil || choice != [2]byte{5, 0} {
			t.Fatalf("method: %v, %v", choice, err)
		}
		conn.Write(addressMessage([]byte{5, command, 0}, endpoint))
		var response [4]byte
		if _, err := io.ReadFull(conn, response[:]); err != nil || response[0] != 5 || response[1] != 0 {
			t.Fatalf("reply: %v, %v", response, err)
		}
		bound, err := readDestination(conn, response[3])
		if err != nil {
			t.Fatal(err)
		}
		return conn, bound
	}

	for _, literal := range []string{"10.0.0.1", "fd00::1"} {
		addr := netip.MustParseAddr(literal)
		endpoint := netip.AddrPortFrom(addr, 8080)
		t.Run("TCP/"+literal, func(t *testing.T) {
			server, err := gonet.ListenTCP(peer.stack, fullAddress(endpoint), networkProtocol(addr))
			if err != nil {
				t.Fatal(err)
			}
			defer server.Close()
			go func() {
				conn, err := server.Accept()
				if err == nil {
					defer conn.Close()
					io.Copy(conn, conn)
				}
			}()
			conn, bound := openControl(t, connect, endpoint)
			if bound.ip.Is4() != addr.Is4() {
				t.Fatalf("wrong reply address family: %v", bound.ip)
			}
			conn.Write([]byte("tcp"))
			conn.CloseWrite()
			if got, err := io.ReadAll(conn); err != nil || string(got) != "tcp" {
				t.Fatalf("echo: %q, %v", got, err)
			}
		})

		t.Run("UDP/"+literal, func(t *testing.T) {
			local := fullAddress(endpoint)
			server, err := gonet.DialUDP(peer.stack, &local, nil, networkProtocol(addr))
			if err != nil {
				t.Fatal(err)
			}
			defer server.Close()
			go func() {
				var packet [32]byte
				for {
					n, source, err := server.ReadFrom(packet[:])
					if err != nil {
						return
					}
					server.WriteTo(packet[:n], source)
				}
			}()
			control, bound := openControl(t, udpAssociate, netip.AddrPortFrom(netip.IPv4Unspecified(), 0))
			relayAddr := net.UDPAddrFromAddrPort(netip.AddrPortFrom(bound.ip, bound.port))
			for index := range 2 {
				relay, err := net.DialUDP("udp4", nil, relayAddr)
				if err != nil {
					t.Fatal(err)
				}
				defer relay.Close()
				relay.SetDeadline(time.Now().Add(time.Second))
				if index == 0 {
					// The fixture DNS drops this request, which must not stall other flows.
					unresolved := append([]byte{0, 0, 0, addressName, 15}, "unknown.invalid"...)
					relay.Write(binary.BigEndian.AppendUint16(unresolved, 53))
				}
				want := append(addressMessage([]byte{0, 0, 0}, endpoint), byte(index))
				relay.Write(want)
				var packet [64]byte
				n, err := relay.Read(packet[:])
				if err != nil || !bytes.Equal(packet[:n], want) {
					t.Fatalf("echo: %x, %v; want %x", packet[:n], err, want)
				}
			}
			control.Close()
		})
	}
}

func serveTestDNS(conn *gonet.UDPConn) {
	// This fixture answers only the A and AAAA queries for dual-stack.invalid.
	question := []byte("\x0adual-stack\x07invalid\x00")
	var packet [512]byte
	for {
		n, source, err := conn.ReadFrom(packet[:])
		if err != nil {
			return
		}
		end := 12 + len(question) + 4
		if n < end || !bytes.Equal(packet[12:12+len(question)], question) {
			continue
		}
		var answer netip.Addr
		switch binary.BigEndian.Uint16(packet[end-4 : end-2]) {
		case 1:
			answer = netip.MustParseAddr("10.0.0.1")
		case 28:
			answer = netip.MustParseAddr("fd00::1")
		default:
			continue
		}
		response := append([]byte{}, packet[:end]...)
		response[2], response[3], response[7], response[11] = 0x81, 0x80, 1, 0
		response = append(response, 0xc0, 12)
		response = append(response, packet[end-4:end]...)
		response = append(response, 0, 0, 0, 30, 0, byte(answer.BitLen()/8))
		conn.WriteTo(append(response, answer.AsSlice()...), source)
	}
}
