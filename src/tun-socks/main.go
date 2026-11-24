package main

import (
	"context"
	"fmt"
	"log"
	"net"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"
)

func main() {
	if err := run(); err != nil {
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
	file := os.NewFile(uintptr(fd), "VPNFD")
	packetConn, err := net.FileConn(file)
	file.Close()
	if err != nil {
		return fmt.Errorf("open VPNFD: %w", err)
	}
	defer packetConn.Close()
	if _, ok := packetConn.(*net.UnixConn); !ok || packetConn.LocalAddr().Network() != "unixgram" {
		return fmt.Errorf("VPNFD is not a Unix datagram socket")
	}

	vpn, err := newTunnel()
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
	ticker := time.NewTicker(time.Second)
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
