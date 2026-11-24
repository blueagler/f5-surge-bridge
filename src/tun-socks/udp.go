package main

import (
	"bytes"
	"context"
	"net"
	"net/netip"
	"sync"
	"time"

	"gvisor.dev/gvisor/pkg/tcpip/adapters/gonet"
)

const udpIdleTimeout = 2 * time.Minute

type udpAssociation struct {
	relay *net.UDPConn
	mu    sync.Mutex
	flows map[destination]*gonet.UDPConn
}

func (t *tunnel) associate(ctx context.Context, control *net.TCPConn, target destination) {
	peer := control.RemoteAddr().(*net.TCPAddr).AddrPort().Addr()
	if !target.ip.IsValid() || (!target.ip.IsUnspecified() && target.ip != peer) {
		reply(control, 2, netip.AddrPort{})
		return
	}
	relay, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		reply(control, 1, netip.AddrPort{})
		return
	}
	defer relay.Close()
	if reply(control, 0, relay.LocalAddr().(*net.UDPAddr).AddrPort()) != nil {
		return
	}
	control.SetDeadline(time.Time{})
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	go func() {
		var unused [1]byte
		control.Read(unused[:])
		cancel()
		relay.Close()
	}()
	association := udpAssociation{relay: relay, flows: make(map[destination]*gonet.UDPConn)}
	defer association.closeFlows()
	wantedPort := target.port
	packet := make([]byte, 65535)
	for {
		n, client, err := relay.ReadFromUDPAddrPort(packet)
		if err != nil {
			return
		}
		if client.Addr() != peer || (wantedPort != 0 && client.Port() != wantedPort) || n < 4 ||
			packet[0] != 0 || packet[1] != 0 || packet[2] != 0 {
			continue
		}
		payload := bytes.NewReader(packet[4:n])
		remote, err := readDestination(payload, packet[3])
		if err != nil || remote.port == 0 {
			continue
		}
		wantedPort = client.Port()
		association.send(ctx, t, client, remote, packet[n-payload.Len():n])
	}
}

func (a *udpAssociation) send(ctx context.Context, t *tunnel, client netip.AddrPort, target destination, payload []byte) {
	a.mu.Lock()
	conn := a.flows[target]
	full := len(a.flows) >= 64
	a.mu.Unlock()
	if conn == nil && !full {
		for _, addr := range t.resolve(ctx, target) {
			var err error
			conn, err = t.dialUDP(addr)
			if err != nil {
				continue
			}
			conn.SetReadDeadline(time.Now().Add(udpIdleTimeout))
			a.mu.Lock()
			a.flows[target] = conn
			a.mu.Unlock()
			go a.receive(conn, client, target, addr)
			break
		}
	}
	if conn != nil {
		conn.SetReadDeadline(time.Now().Add(udpIdleTimeout))
		conn.Write(payload)
	}
}

func (a *udpAssociation) receive(conn *gonet.UDPConn, client netip.AddrPort, target destination, remote netip.AddrPort) {
	defer func() {
		conn.Close()
		a.mu.Lock()
		delete(a.flows, target)
		a.mu.Unlock()
	}()
	header := addressMessage([]byte{0, 0, 0}, remote)
	packet := make([]byte, 65535)
	copy(packet, header)
	for {
		n, err := conn.Read(packet[len(header):])
		if err != nil {
			return
		}
		if _, err := a.relay.WriteToUDPAddrPort(packet[:len(header)+n], client); err != nil {
			return
		}
		conn.SetReadDeadline(time.Now().Add(udpIdleTimeout))
	}
}

func (a *udpAssociation) closeFlows() {
	a.mu.Lock()
	defer a.mu.Unlock()
	for _, conn := range a.flows {
		conn.Close()
	}
}
