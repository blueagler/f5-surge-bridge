package main

import (
	"context"
	"fmt"
	"net"
	"net/netip"
	"os"
	"strconv"
	"strings"
	"time"

	"gvisor.dev/gvisor/pkg/buffer"
	"gvisor.dev/gvisor/pkg/tcpip"
	"gvisor.dev/gvisor/pkg/tcpip/adapters/gonet"
	"gvisor.dev/gvisor/pkg/tcpip/header"
	"gvisor.dev/gvisor/pkg/tcpip/link/channel"
	"gvisor.dev/gvisor/pkg/tcpip/network/ipv4"
	"gvisor.dev/gvisor/pkg/tcpip/network/ipv6"
	"gvisor.dev/gvisor/pkg/tcpip/stack"
	"gvisor.dev/gvisor/pkg/tcpip/transport/icmp"
	"gvisor.dev/gvisor/pkg/tcpip/transport/tcp"
	"gvisor.dev/gvisor/pkg/tcpip/transport/udp"
)

const vpnNIC = 1

type tunnel struct {
	stack     *stack.Stack
	link      *channel.Endpoint
	protocols map[tcpip.NetworkProtocolNumber]bool
	dns       []netip.Addr
}

func newTunnel() (*tunnel, error) {
	mtu := 1400
	if raw := os.Getenv("INTERNAL_IP4_MTU"); raw != "" && raw != "0" {
		value, err := strconv.Atoi(raw)
		if err != nil || value < 576 || value > 65535 {
			return nil, fmt.Errorf("invalid tunnel MTU %q", raw)
		}
		mtu = value
	}
	vpn := &tunnel{
		stack: stack.New(stack.Options{
			NetworkProtocols:   []stack.NetworkProtocolFactory{ipv4.NewProtocol, ipv6.NewProtocol},
			TransportProtocols: []stack.TransportProtocolFactory{tcp.NewProtocol, udp.NewProtocol, icmp.NewProtocol4, icmp.NewProtocol6},
		}),
		link:      channel.New(256, uint32(mtu), ""),
		protocols: make(map[tcpip.NetworkProtocolNumber]bool),
	}
	if err := vpn.stack.CreateNIC(vpnNIC, vpn.link); err != nil {
		return nil, fmt.Errorf("create virtual link: %v", err)
	}
	var routes []tcpip.Route
	for _, key := range []string{"INTERNAL_IP4_ADDRESS", "INTERNAL_IP6_ADDRESS"} {
		raw := os.Getenv(key)
		// Some OpenConnect IPv6 configuration exports an address with /prefix.
		if raw == "" && key == "INTERNAL_IP6_ADDRESS" {
			raw = os.Getenv("INTERNAL_IP6_NETMASK")
		}
		if raw == "" {
			continue
		}
		literal, _, _ := strings.Cut(raw, "/")
		addr, err := netip.ParseAddr(literal)
		if err != nil || addr.Zone() != "" || addr.Is4() != (key == "INTERNAL_IP4_ADDRESS") || addr.Is4In6() {
			return nil, fmt.Errorf("invalid %s %q", key, raw)
		}
		// F5 can advertise a default IPv6 route (::/0) without assigning an address.
		if addr.IsUnspecified() {
			continue
		}
		address := tcpip.AddrFromSlice(addr.AsSlice())
		protocol := networkProtocol(addr)
		if err := vpn.stack.AddProtocolAddress(vpnNIC, tcpip.ProtocolAddress{
			Protocol: protocol, AddressWithPrefix: address.WithPrefix(),
		}, stack.AddressProperties{}); err != nil {
			return nil, fmt.Errorf("configure %s: %v", key, err)
		}
		vpn.protocols[protocol] = true
		subnet := header.IPv6EmptySubnet
		if addr.Is4() {
			subnet = header.IPv4EmptySubnet
		}
		routes = append(routes, tcpip.Route{Destination: subnet, NIC: vpnNIC})
	}
	if len(routes) == 0 {
		return nil, fmt.Errorf("OpenConnect provided no tunnel addresses")
	}
	vpn.stack.SetRouteTable(routes)
	for _, raw := range strings.Fields(os.Getenv("INTERNAL_IP4_DNS") + " " + os.Getenv("INTERNAL_IP6_DNS")) {
		if addr, err := netip.ParseAddr(raw); err == nil && vpn.supports(addr.Unmap()) {
			vpn.dns = append(vpn.dns, addr.Unmap())
		}
	}
	return vpn, nil
}

func networkProtocol(addr netip.Addr) tcpip.NetworkProtocolNumber {
	if addr.Is4() {
		return ipv4.ProtocolNumber
	}
	return ipv6.ProtocolNumber
}

func (t *tunnel) supports(addr netip.Addr) bool {
	return addr.IsValid() && !addr.IsUnspecified() && addr.Zone() == "" && t.protocols[networkProtocol(addr)]
}

func (t *tunnel) receive(conn net.Conn) error {
	packet := make([]byte, 65535)
	for {
		n, err := conn.Read(packet)
		if err != nil {
			return err
		}
		if n == 0 {
			continue
		}
		var protocol tcpip.NetworkProtocolNumber
		switch header.IPVersion(packet[:n]) {
		case 4:
			protocol = ipv4.ProtocolNumber
		case 6:
			protocol = ipv6.ProtocolNumber
		}
		if t.protocols[protocol] {
			pkt := stack.NewPacketBuffer(stack.PacketBufferOptions{Payload: buffer.MakeWithData(packet[:n])})
			t.link.InjectInbound(protocol, pkt)
			pkt.DecRef()
		}
	}
}

func (t *tunnel) transmit(ctx context.Context, conn net.Conn) error {
	for {
		pkt := t.link.ReadContext(ctx)
		if pkt == nil {
			return ctx.Err()
		}
		view := pkt.ToView()
		pkt.DecRef()
		_, err := conn.Write(view.AsSlice())
		view.Release()
		if err != nil {
			return err
		}
	}
}

func (t *tunnel) dialTCP(ctx context.Context, addr netip.AddrPort) (*gonet.TCPConn, error) {
	return gonet.DialContextTCP(ctx, t.stack, fullAddress(addr), networkProtocol(addr.Addr()))
}

func (t *tunnel) dialUDP(addr netip.AddrPort) (*gonet.UDPConn, error) {
	remote := fullAddress(addr)
	return gonet.DialUDP(t.stack, nil, &remote, networkProtocol(addr.Addr()))
}

func fullAddress(addr netip.AddrPort) tcpip.FullAddress {
	return tcpip.FullAddress{NIC: vpnNIC, Addr: tcpip.AddrFromSlice(addr.Addr().AsSlice()), Port: addr.Port()}
}

func (t *tunnel) resolve(ctx context.Context, target destination) []netip.AddrPort {
	if target.ip.IsValid() {
		if t.supports(target.ip) {
			return []netip.AddrPort{netip.AddrPortFrom(target.ip, target.port)}
		}
		return nil
	}
	for _, dns := range t.dns {
		server := netip.AddrPortFrom(dns, 53)
		resolver := net.Resolver{PreferGo: true, Dial: func(ctx context.Context, network, _ string) (net.Conn, error) {
			if strings.HasPrefix(network, "tcp") {
				return t.dialTCP(ctx, server)
			}
			return t.dialUDP(server)
		}}
		network := "ip"
		if !t.protocols[ipv6.ProtocolNumber] {
			network = "ip4"
		} else if !t.protocols[ipv4.ProtocolNumber] {
			network = "ip6"
		}
		lookupCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
		// The trailing dot prevents host search domains from affecting VPN lookups.
		addresses, _ := resolver.LookupNetIP(lookupCtx, network, strings.TrimSuffix(target.host, ".")+".")
		cancel()
		var results []netip.AddrPort
		for _, addr := range addresses {
			if addr = addr.Unmap(); t.supports(addr) {
				results = append(results, netip.AddrPortFrom(addr, target.port))
			}
		}
		if len(results) > 0 {
			return results
		}
	}
	return nil
}
