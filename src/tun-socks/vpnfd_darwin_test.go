package main

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net"
	"net/netip"
	"os"
	"os/exec"
	"strconv"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

func TestVPNFDProcess(t *testing.T) {
	if port := os.Getenv("TEST_TUN_SOCKS_PORT"); port != "" {
		os.Args = []string{"tun-socks", port}
		if err := run(); err != nil {
			t.Fatal(err)
		}
		return
	}
	listener, err := net.ListenTCP("tcp4", &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	address := listener.Addr().(*net.TCPAddr)
	listener.Close()
	fds, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_DGRAM, 0)
	if err != nil {
		t.Fatal(err)
	}
	peer := os.NewFile(uintptr(fds[0]), "OpenConnect VPNFD")
	defer peer.Close()
	helper := os.NewFile(uintptr(fds[1]), "tun-socks VPNFD")
	defer helper.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	proc := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestVPNFDProcess$")
	proc.Env = append(os.Environ(), "TEST_TUN_SOCKS_PORT="+strconv.Itoa(address.Port), "VPNFD=3",
		"INTERNAL_IP4_ADDRESS=10.0.0.2", "INTERNAL_IP6_ADDRESS=", "INTERNAL_IP6_NETMASK=")
	proc.ExtraFiles = []*os.File{helper}
	var output bytes.Buffer
	proc.Stdout, proc.Stderr = &output, &output
	if err := proc.Start(); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- proc.Wait() }()
	deadline := time.Now().Add(4 * time.Second)
	for {
		conn, err := net.DialTimeout("tcp4", address.String(), 100*time.Millisecond)
		if err == nil {
			conn.SetDeadline(deadline)
			conn.Write([]byte{5, 1, 0})
			var reply [2]byte
			_, err = io.ReadFull(conn, reply[:])
			conn.Close()
			if err != nil || reply != [2]byte{5, 0} {
				t.Fatalf("helper greeting = %v, %v", reply, err)
			}
			break
		}
		select {
		case err := <-done:
			t.Fatalf("helper exited before listening: %v\n%s", err, &output)
		case <-time.After(20 * time.Millisecond):
		}
		if time.Now().After(deadline) {
			t.Fatal("helper did not start listening")
		}
	}
	if err := proc.Process.Signal(unix.SIGHUP); err != nil {
		t.Fatal(err)
	}
	if err := <-done; err != nil {
		t.Fatalf("helper did not detach cleanly: %v\n%s", err, &output)
	}
}

func TestVPNFDSurvivesDatagramBackpressure(t *testing.T) {
	t.Setenv("INTERNAL_IP4_ADDRESS", "10.0.0.2")
	t.Setenv("INTERNAL_IP6_ADDRESS", "")
	t.Setenv("INTERNAL_IP6_NETMASK", "")
	t.Setenv("INTERNAL_IP4_MTU", "9000")
	vpn, err := newTunnel(maxVPNDatagram)
	if err != nil {
		t.Fatal(err)
	}
	defer vpn.stack.Destroy()
	defer vpn.link.Close()
	if got := vpn.link.MTU(); got != maxVPNDatagram {
		t.Fatalf("VPNFD MTU = %d, want %d", got, maxVPNDatagram)
	}
	fds, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_DGRAM, 0)
	if err != nil {
		t.Fatal(err)
	}
	open := func(fd int) net.Conn {
		file := os.NewFile(uintptr(fd), "VPNFD")
		defer file.Close()
		conn, err := net.FileConn(file)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { conn.Close() })
		return conn
	}
	out, peer := open(fds[0]), open(fds[1])
	filler := bytes.Repeat([]byte{0xee}, 1400)
	queued := 0
	for ; queued < 1000; queued++ {
		if _, err := out.Write(filler); errors.Is(err, unix.ENOBUFS) {
			break
		} else if err != nil {
			t.Fatal(err)
		}
	}
	if queued == 1000 {
		t.Fatal("expected ENOBUFS with a full Unix datagram socket")
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	udp, err := vpn.dialUDP(netip.MustParseAddrPort("10.0.0.1:53"))
	if err != nil {
		t.Fatal(err)
	}
	defer udp.Close()
	if _, err := udp.Write(filler); err != nil {
		t.Fatal(err)
	}
	// Wait until the actual transmit loop has attempted the full-socket write.
	observed := &observedDatagramConn{Conn: out, writes: make(chan error, 1)}
	go func() { done <- vpn.transmit(ctx, observed) }()
	select {
	case err := <-observed.writes:
		if !errors.Is(err, unix.ENOBUFS) {
			t.Fatalf("transmit error = %v, want ENOBUFS", err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("transmit never attempted a write")
	}
	peer.SetReadDeadline(time.Now().Add(3 * time.Second))
	packet := make([]byte, maxVPNDatagram)
	for range queued {
		if _, err := peer.Read(packet); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := udp.Write([]byte("after backpressure")); err != nil {
		t.Fatal(err)
	}
	n, err := peer.Read(packet)
	if err != nil || !bytes.HasSuffix(packet[:n], []byte("after backpressure")) {
		select {
		case exit := <-done:
			t.Fatalf("transmit exited: %v", exit)
		default:
			t.Fatalf("could not forward the next datagram: %v", err)
		}
	}
	cancel()
	if err := <-done; !errors.Is(err, context.Canceled) {
		t.Fatalf("transmit returned %v after cancel", err)
	}
}

type observedDatagramConn struct {
	net.Conn
	writes chan error
}

func (c *observedDatagramConn) Write(data []byte) (int, error) {
	n, err := c.Conn.Write(data)
	select {
	case c.writes <- err:
	default:
	}
	return n, err
}
