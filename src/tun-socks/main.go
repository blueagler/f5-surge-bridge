package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

func main() {
	log.SetPrefix("tun-socks: ")
	if err := run(); err != nil {
		var code syscall.Errno
		errors.As(err, &code)
		// The macOS app records only this numeric diagnostic in its unified log.
		fmt.Fprintf(os.Stderr, "tun-socks: fatal errno=%d\n", code)
		log.Fatal(err)
	}
}

func run() error {
	if len(os.Args) != 2 {
		return fmt.Errorf("usage: tun-socks port")
	}
	port, err := strconv.ParseUint(os.Args[1], 10, 16)
	if err != nil || port == 0 {
		return fmt.Errorf("invalid SOCKS5 port")
	}
	fd, err := strconv.Atoi(os.Getenv("VPNFD"))
	if err != nil || fd < 3 {
		return fmt.Errorf("invalid OpenConnect VPNFD")
	}
	sendCapacity, err := unix.GetsockoptInt(fd, unix.SOL_SOCKET, unix.SO_SNDBUF)
	if err != nil || sendCapacity < 576 {
		return fmt.Errorf("invalid VPNFD send buffer: %d (%v)", sendCapacity, err)
	}
	file := os.NewFile(uintptr(fd), "VPNFD")
	packetConn, err := net.FileConn(file)
	file.Close()
	if err != nil {
		return fmt.Errorf("open VPNFD: %w", err)
	}
	defer packetConn.Close()
	packetSocket, ok := packetConn.(*net.UnixConn)
	if !ok || packetConn.LocalAddr().Network() != "unixgram" {
		return fmt.Errorf("VPNFD is not a Unix datagram socket")
	}
	_ = packetSocket.SetReadBuffer(256 * 1024)

	vpn, err := newTunnel(min(sendCapacity, maxVPNDatagram))
	if err != nil {
		return err
	}
	listener, err := net.ListenTCP("tcp4", &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1), Port: int(port)})
	if err != nil {
		return err
	}
	defer listener.Close()

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGHUP, syscall.SIGTERM, os.Interrupt)
	defer cancel()
	errors := make(chan error, 3)
	go func() { errors <- vpn.receive(packetConn) }()
	go func() { errors <- vpn.transmit(ctx, packetConn) }()
	go func() { errors <- vpn.serve(ctx, listener) }()
	// OpenConnect normally signals the script's process group. Also release the
	// listener if it is killed before it can send SIGHUP.
	ticker := time.NewTicker(250 * time.Millisecond)
	defer ticker.Stop()
	for os.Getppid() != 1 {
		select {
		case <-ctx.Done():
			return nil
		case err := <-errors:
			return err
		case <-ticker.C:
		}
	}
	return nil
}
