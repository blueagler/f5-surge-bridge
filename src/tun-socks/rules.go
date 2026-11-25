package main

import (
	"bytes"
	"fmt"
	"net/netip"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"gvisor.dev/gvisor/pkg/tcpip"
	"gvisor.dev/gvisor/pkg/tcpip/network/ipv4"
	"gvisor.dev/gvisor/pkg/tcpip/network/ipv6"
)

type routeRules struct {
	environment string
	protocol    tcpip.NetworkProtocolNumber
	kind        string
}

func (t *tunnel) publishSplitRules(stem string) error {
	if len(stem) > 80 || strings.ContainsFunc(stem, func(r rune) bool {
		return !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '-' || r == '_')
	}) {
		return fmt.Errorf("invalid split rule file stem")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return fmt.Errorf("find home directory: %w", err)
	}
	directory := filepath.Join(home, "Library", "Application Support", "UWVPN")
	for _, set := range []struct {
		suffix  string
		heading string
		domains bool
		routes  []routeRules
	}{
		{
			suffix:  "split",
			heading: "Derived from F5 BIG-IP protocol options",
			domains: true,
			routes: []routeRules{
				{"CISCO_SPLIT_INC", ipv4.ProtocolNumber, "IP-CIDR"},
				{"CISCO_IPV6_SPLIT_INC", ipv6.ProtocolNumber, "IP-CIDR6"},
			},
		},
		{
			suffix:  "exclude",
			heading: "Derived from F5 BIG-IP split-exclude options",
			routes: []routeRules{
				{"CISCO_SPLIT_EXC", ipv4.ProtocolNumber, "IP-CIDR"},
				{"CISCO_IPV6_SPLIT_EXC", ipv6.ProtocolNumber, "IP-CIDR6"},
			},
		},
	} {
		var contents bytes.Buffer
		fmt.Fprintf(&contents, "# %s\n", set.heading)
		if set.domains {
			for _, domain := range strings.Fields(os.Getenv("CISCO_DEF_DOMAIN")) {
				if !strings.ContainsFunc(domain, func(r rune) bool {
					return !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '-' || r == '.')
				}) {
					fmt.Fprintf(&contents, "DOMAIN-SUFFIX,%s\n", domain)
				}
			}
		}
		for _, route := range set.routes {
			if !t.protocols[route.protocol] {
				continue
			}
			count, _ := strconv.Atoi(os.Getenv(route.environment))
			for i := 0; i < min(count, 65536); i++ {
				address := os.Getenv(fmt.Sprintf("%s_%d_ADDR", route.environment, i))
				mask := os.Getenv(fmt.Sprintf("%s_%d_MASKLEN", route.environment, i))
				if prefix, err := netip.ParsePrefix(address + "/" + mask); err == nil && networkProtocol(prefix.Addr()) == route.protocol {
					fmt.Fprintf(&contents, "%s,%s,no-resolve\n", route.kind, prefix.Masked())
				}
			}
		}
		path := filepath.Join(directory, stem+"-"+set.suffix+".list")
		if err := replaceRuleFile(path, contents.Bytes()); err != nil {
			return err
		}
	}
	return nil
}

func replaceRuleFile(path string, contents []byte) error {
	file, err := os.CreateTemp(filepath.Dir(path), filepath.Base(path)+".")
	if err != nil {
		return fmt.Errorf("create %s: %w", path, err)
	}
	temporary := file.Name()
	defer os.Remove(temporary)
	if _, err := file.Write(contents); err != nil {
		file.Close()
		return fmt.Errorf("write %s: %w", path, err)
	}
	if err := file.Close(); err != nil {
		return fmt.Errorf("close %s: %w", path, err)
	}
	if err := os.Rename(temporary, path); err != nil {
		return fmt.Errorf("replace %s: %w", path, err)
	}
	return nil
}
