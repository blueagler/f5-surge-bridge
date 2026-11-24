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
	flows map[udpFlowKey]*udpFlow
}

type udpFlowKey struct {
	client netip.AddrPort
	target destination
}

type udpFlow struct {
	packets chan []byte
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
	association := udpAssociation{relay: relay, flows: make(map[udpFlowKey]*udpFlow)}
	packet := make([]byte, 65535)
	for {
		n, client, err := relay.ReadFromUDPAddrPort(packet)
		if err != nil {
			return
		}
		if client.Addr() != peer || (target.port != 0 && client.Port() != target.port) || n < 4 ||
			packet[0] != 0 || packet[1] != 0 || packet[2] != 0 {
			continue
		}
		payload := bytes.NewReader(packet[4:n])
		remote, err := readDestination(payload, packet[3])
		if err != nil || remote.port == 0 {
			continue
		}
		association.send(ctx, t, client, remote, packet[n-payload.Len():n])
	}
}

func (a *udpAssociation) send(ctx context.Context, t *tunnel, client netip.AddrPort, target destination, payload []byte) {
	key := udpFlowKey{client: client, target: target}
	a.mu.Lock()
	defer a.mu.Unlock()
	flow := a.flows[key]
	if flow == nil {
		if len(a.flows) >= 64 {
			return
		}
		flow = &udpFlow{packets: make(chan []byte, 8)}
		a.flows[key] = flow
		go a.runFlow(ctx, t, key, flow)
	}
	if len(flow.packets) < cap(flow.packets) {
		flow.packets <- bytes.Clone(payload)
	}
}

func (a *udpAssociation) runFlow(ctx context.Context, t *tunnel, key udpFlowKey, flow *udpFlow) {
	var conn *gonet.UDPConn
	defer func() {
		a.mu.Lock()
		delete(a.flows, key)
		a.mu.Unlock()
		if conn != nil {
			conn.Close()
		}
	}()
	var remote netip.AddrPort
	for _, addr := range t.resolve(ctx, key.target) {
		candidate, err := t.dialUDP(addr)
		if err == nil {
			conn, remote = candidate, addr
			break
		}
	}
	if conn == nil || ctx.Err() != nil {
		return
	}

	conn.SetReadDeadline(time.Now().Add(udpIdleTimeout))
	done := make(chan struct{})
	go func() {
		defer close(done)
		a.receive(conn, key.client, remote)
	}()
	for {
		select {
		case <-ctx.Done():
			return
		case <-done:
			return
		case payload := <-flow.packets:
			conn.SetReadDeadline(time.Now().Add(udpIdleTimeout))
			if _, err := conn.Write(payload); err != nil {
				return
			}
		}
	}
}

func (a *udpAssociation) receive(conn *gonet.UDPConn, client netip.AddrPort, remote netip.AddrPort) {
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
