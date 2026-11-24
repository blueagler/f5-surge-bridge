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
	"syscall"
	"time"

	"gvisor.dev/gvisor/pkg/tcpip/adapters/gonet"
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
		if literal, err := netip.ParseAddr(target.host); err == nil {
			target.ip, target.host = literal.Unmap(), ""
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
	handshakes := make(chan struct{}, 32)
	for {
		conn, err := listener.AcceptTCP()
		if err != nil {
			if errors.Is(err, syscall.ECONNABORTED) || errors.Is(err, syscall.EINTR) {
				continue
			}
			if errors.Is(err, syscall.EMFILE) || errors.Is(err, syscall.ENFILE) || errors.Is(err, syscall.ENOBUFS) {
				select {
				case <-ctx.Done():
					return ctx.Err()
				case <-time.After(100 * time.Millisecond):
					continue
				}
			}
			return err
		}
		select {
		case handshakes <- struct{}{}:
			go func() {
				defer conn.Close()
				t.handle(ctx, conn, handshakes, active)
			}()
		default:
			conn.Close()
		}
	}
}

func (t *tunnel) handle(ctx context.Context, conn *net.TCPConn, handshakes, active chan struct{}) {
	command, target, ok := readRequest(conn)
	<-handshakes
	if !ok {
		return
	}
	select {
	case active <- struct{}{}:
		defer func() { <-active }()
	default:
		reply(conn, 1, netip.AddrPort{})
		return
	}
	conn.SetDeadline(time.Now().Add(15 * time.Second))
	switch command {
	case connect:
		t.connect(ctx, conn, target)
	case udpAssociate:
		t.associate(ctx, conn, target)
	default:
		reply(conn, 7, netip.AddrPort{})
	}
}

func readRequest(conn net.Conn) (byte, destination, bool) {
	conn.SetDeadline(time.Now().Add(3 * time.Second))
	var greeting [2]byte
	if _, err := io.ReadFull(conn, greeting[:]); err != nil || greeting[0] != socksVersion {
		return 0, destination{}, false
	}
	var methods [255]byte
	if _, err := io.ReadFull(conn, methods[:greeting[1]]); err != nil {
		return 0, destination{}, false
	}
	method := byte(0)
	if !bytes.Contains(methods[:greeting[1]], []byte{0}) {
		method = 0xff
	}
	if _, err := conn.Write([]byte{socksVersion, method}); err != nil || method != 0 {
		return 0, destination{}, false
	}
	var request [4]byte
	if _, err := io.ReadFull(conn, request[:]); err != nil || request[0] != socksVersion || request[2] != 0 {
		return 0, destination{}, false
	}
	target, err := readDestination(conn, request[3])
	if err != nil {
		if errors.Is(err, errAddressType) {
			reply(conn, 8, netip.AddrPort{})
		}
		return 0, destination{}, false
	}
	return request[1], target, true
}

func (t *tunnel) connect(ctx context.Context, client *net.TCPConn, target destination) {
	if target.port == 0 || (target.ip.IsValid() && !t.supports(target.ip)) {
		reply(client, 8, netip.AddrPort{})
		return
	}
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	remote := t.dialTCPFamilies(ctx, t.resolve(ctx, target))
	if remote == nil {
		reply(client, 4, netip.AddrPort{})
		return
	}
	defer remote.Close()
	if reply(client, 0, remote.LocalAddr().(*net.TCPAddr).AddrPort()) != nil {
		return
	}
	client.SetDeadline(time.Time{})
	client.SetKeepAliveConfig(net.KeepAliveConfig{Enable: true, Idle: 2 * time.Minute, Interval: 15 * time.Second, Count: 4})
	done := make(chan struct{})
	go func() {
		if _, err := io.Copy(remote, client); err != nil {
			remote.Close()
		}
		remote.CloseWrite()
		remote.SetReadDeadline(time.Now().Add(2 * time.Minute))
		close(done)
	}()
	if _, err := io.Copy(client, remote); err != nil {
		client.Close()
	}
	client.CloseWrite()
	client.SetReadDeadline(time.Now().Add(2 * time.Minute))
	<-done
}

func (t *tunnel) dialTCPFamilies(ctx context.Context, addrs []netip.AddrPort) *gonet.TCPConn {
	if len(addrs) == 0 {
		return nil
	}
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	var preferred, alternate []netip.AddrPort
	for _, addr := range addrs {
		if addr.Addr().Is4() == addrs[0].Addr().Is4() {
			preferred = append(preferred, addr)
		} else {
			alternate = append(alternate, addr)
		}
	}
	result := make(chan *gonet.TCPConn)
	dial := func(candidates []netip.AddrPort) {
		for _, addr := range candidates {
			attempt, stop := context.WithTimeout(ctx, 3*time.Second)
			remote, err := t.dialTCP(attempt, addr)
			stop()
			if err == nil {
				select {
				case result <- remote:
				case <-ctx.Done():
					remote.Close()
				}
				return
			}
			if ctx.Err() != nil {
				return
			}
		}
		select {
		case result <- nil:
		case <-ctx.Done():
		}
	}
	go dial(preferred)
	if len(alternate) == 0 {
		select {
		case remote := <-result:
			return remote
		case <-ctx.Done():
			return nil
		}
	}
	timer := time.NewTimer(250 * time.Millisecond)
	defer timer.Stop()
	remaining := 2
	select {
	case remote := <-result:
		if remote != nil {
			return remote
		}
		remaining--
	case <-timer.C:
	case <-ctx.Done():
		return nil
	}
	go dial(alternate)
	for range remaining {
		select {
		case remote := <-result:
			if remote != nil {
				return remote
			}
		case <-ctx.Done():
			return nil
		}
	}
	return nil
}
