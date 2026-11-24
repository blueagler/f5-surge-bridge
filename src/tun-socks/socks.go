package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"net/netip"
	"strings"
	"time"
)

const (
	socksVersion = 5
	connect      = 1
	udpAssociate = 3
	addressIPv4  = 1
	addressName  = 3
	addressIPv6  = 4
)

type destination struct {
	ip   netip.Addr
	host string
	port uint16
}

var errAddressType = errors.New("unsupported SOCKS5 address type")

func readDestination(r io.Reader, kind byte) (destination, error) {
	var target destination
	var size int
	switch kind {
	case addressIPv4:
		size = 4
	case addressIPv6:
		size = 16
	case addressName:
		var length [1]byte
		if _, err := io.ReadFull(r, length[:]); err != nil {
			return target, err
		}
		size = int(length[0])
	default:
		return target, errAddressType
	}
	var data [257]byte
	if _, err := io.ReadFull(r, data[:size+2]); err != nil {
		return target, err
	}
	target.port = binary.BigEndian.Uint16(data[size : size+2])
	if kind == addressName {
		target.host = strings.ToLower(string(data[:size]))
		if target.host == "" || strings.ContainsAny(target.host, "\x00 \r\n\t") {
			return target, errAddressType
		}
	} else {
		addr, _ := netip.AddrFromSlice(data[:size])
		target.ip = addr.Unmap()
	}
	return target, nil
}

func addressMessage(prefix []byte, address netip.AddrPort) []byte {
	if !address.IsValid() {
		address = netip.AddrPortFrom(netip.IPv4Unspecified(), 0)
	}
	kind := byte(addressIPv6)
	if address.Addr().Is4() {
		kind = addressIPv4
	}
	prefix = append(prefix, kind)
	prefix = append(prefix, address.Addr().AsSlice()...)
	return binary.BigEndian.AppendUint16(prefix, address.Port())
}

func reply(conn net.Conn, status byte, address netip.AddrPort) error {
	_, err := conn.Write(addressMessage([]byte{socksVersion, status, 0}, address))
	return err
}

func (t *tunnel) serve(ctx context.Context, listener *net.TCPListener) error {
	active := make(chan struct{}, 256)
	for {
		conn, err := listener.AcceptTCP()
		if err != nil {
			return err
		}
		select {
		case active <- struct{}{}:
			go func() {
				defer func() { <-active }()
				defer conn.Close()
				t.handle(ctx, conn)
			}()
		default:
			conn.Close()
		}
	}
}

func (t *tunnel) handle(ctx context.Context, conn *net.TCPConn) {
	conn.SetDeadline(time.Now().Add(15 * time.Second))
	var greeting [2]byte
	if _, err := io.ReadFull(conn, greeting[:]); err != nil || greeting[0] != socksVersion {
		return
	}
	var methods [255]byte
	if _, err := io.ReadFull(conn, methods[:greeting[1]]); err != nil {
		return
	}
	method := byte(0)
	if !bytes.Contains(methods[:greeting[1]], []byte{0}) {
		method = 0xff
	}
	if _, err := conn.Write([]byte{socksVersion, method}); err != nil || method != 0 {
		return
	}
	var request [4]byte
	if _, err := io.ReadFull(conn, request[:]); err != nil || request[0] != socksVersion || request[2] != 0 {
		return
	}
	target, err := readDestination(conn, request[3])
	if err != nil {
		if errors.Is(err, errAddressType) {
			reply(conn, 8, netip.AddrPort{})
		}
		return
	}
	switch request[1] {
	case connect:
		t.connect(ctx, conn, target)
	case udpAssociate:
		t.associate(ctx, conn, target)
	default:
		reply(conn, 7, netip.AddrPort{})
	}
}

func (t *tunnel) connect(ctx context.Context, client *net.TCPConn, target destination) {
	if target.port == 0 || (target.ip.IsValid() && !t.supports(target.ip)) {
		reply(client, 8, netip.AddrPort{})
		return
	}
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	for _, addr := range t.resolve(ctx, target) {
		// Limit each attempt so an unreachable address leaves time to try the next one.
		attempt, stop := context.WithTimeout(ctx, 3*time.Second)
		remote, err := t.dialTCP(attempt, addr)
		stop()
		if err != nil {
			continue
		}
		defer remote.Close()
		bound := remote.LocalAddr().(*net.TCPAddr).AddrPort()
		if reply(client, 0, bound) != nil {
			return
		}
		client.SetDeadline(time.Time{})
		done := make(chan struct{})
		go func() {
			if _, err := io.Copy(remote, client); err != nil {
				remote.Close()
			}
			remote.CloseWrite()
			close(done)
		}()
		if _, err := io.Copy(client, remote); err != nil {
			client.Close()
		}
		client.CloseWrite()
		<-done
		return
	}
	reply(client, 4, netip.AddrPort{})
}
