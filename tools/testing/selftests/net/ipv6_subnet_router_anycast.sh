#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Test IPv6 subnet_router_anycast interface property
#
# Verifies that the subnet_router_anycast sysctl correctly controls whether
# the kernel automatically joins the Subnet-Router Anycast group when IPv6
# forwarding is enabled on an interface.
#
# Test scenarios:
#   1. Default (subnet_router_anycast=1): anycast group is joined when
#      forwarding is enabled.
#   2. Disabled (subnet_router_anycast=0): anycast group is NOT joined even
#      when forwarding is enabled.
#   3. Re-enabling (0 -> 1 while forwarding is on): anycast group is joined
#      immediately.
#   4. Disabling at run-time (1 -> 0 while forwarding is on): anycast group
#      is left immediately.

source lib.sh

cleanup() {
	cleanup_ns $ns1
}

trap cleanup EXIT

setup_test() {
	setup_ns ns1

	ip link add name veth0 type veth peer name veth1
	ip link set veth0 netns $ns1

	ip -n $ns1 addr add 2001:db8:1::1/64 dev veth0 nodad
	ip -n $ns1 link set veth0 up

	# Ensure forwarding is off initially
	ip netns exec $ns1 sysctl -qw net.ipv6.conf.all.forwarding=0
}

# Helper: check whether the Subnet-Router Anycast address for the given prefix
# is present in the interface's anycast list.
# Returns 0 (true) if found, 1 (false) if not found.
anycast_present() {
	local ns=$1
	local dev=$2
	local anycast_addr=$3   # e.g. "2001:db8:1::"

	ip -n "$ns" -6 addr show dev "$dev" | grep -q "anycast $anycast_addr"
}

test_default_joins_on_forwarding() {
	local ret=0

	echo "TEST: default (subnet_router_anycast=1) -- anycast joined when forwarding enabled"

	# Ensure sysctl is at default
	ip netns exec $ns1 sysctl -qw net.ipv6.conf.veth0.subnet_router_anycast=1

	# Enable forwarding
	ip netns exec $ns1 sysctl -qw net.ipv6.conf.veth0.forwarding=1

	if anycast_present $ns1 veth0 "2001:db8:1::"; then
		echo "PASS: Subnet-Router Anycast joined with forwarding=1 (default)"
	else
		echo "FAIL: Subnet-Router Anycast NOT joined with forwarding=1 (default)"
		ret=1
	fi

	# Disable forwarding for next test
	ip netns exec $ns1 sysctl -qw net.ipv6.conf.veth0.forwarding=0

	return $ret
}

test_disabled_no_join() {
	local ret=0

	echo "TEST: subnet_router_anycast=0 -- anycast NOT joined when forwarding enabled"

	# Disable subnet_router_anycast before enabling forwarding
	ip netns exec $ns1 sysctl -qw net.ipv6.conf.veth0.subnet_router_anycast=0

	# Enable forwarding
	ip netns exec $ns1 sysctl -qw net.ipv6.conf.veth0.forwarding=1

	if anycast_present $ns1 veth0 "2001:db8:1::"; then
		echo "FAIL: Subnet-Router Anycast joined despite subnet_router_anycast=0"
		ret=1
	else
		echo "PASS: Subnet-Router Anycast NOT joined with subnet_router_anycast=0"
	fi

	# Leave forwarding on for the next test
	return $ret
}

test_reenable_joins_immediately() {
	local ret=0

	echo "TEST: re-enabling subnet_router_anycast=1 while forwarding on -- anycast joined"

	# forwarding is still on from previous test, subnet_router_anycast=0
	ip netns exec $ns1 sysctl -qw net.ipv6.conf.veth0.subnet_router_anycast=1

	if anycast_present $ns1 veth0 "2001:db8:1::"; then
		echo "PASS: Subnet-Router Anycast joined immediately on subnet_router_anycast=1"
	else
		echo "FAIL: Subnet-Router Anycast NOT joined after re-enabling subnet_router_anycast"
		ret=1
	fi

	return $ret
}

test_disable_leaves_immediately() {
	local ret=0

	echo "TEST: disabling subnet_router_anycast=0 while forwarding on -- anycast left"

	# forwarding is on, subnet_router_anycast=1 (from previous test)
	ip netns exec $ns1 sysctl -qw net.ipv6.conf.veth0.subnet_router_anycast=0

	if anycast_present $ns1 veth0 "2001:db8:1::"; then
		echo "FAIL: Subnet-Router Anycast still present after subnet_router_anycast=0"
		ret=1
	else
		echo "PASS: Subnet-Router Anycast left immediately on subnet_router_anycast=0"
	fi

	# Clean up
	ip netns exec $ns1 sysctl -qw net.ipv6.conf.veth0.forwarding=0
	ip netns exec $ns1 sysctl -qw net.ipv6.conf.veth0.subnet_router_anycast=1

	return $ret
}

echo "IPv6 subnet_router_anycast test"
echo "================================"

# Check if the sysctl is available
setup_test

if ! ip netns exec $ns1 test -f /proc/sys/net/ipv6/conf/veth0/subnet_router_anycast; then
	echo "SKIP: subnet_router_anycast sysctl not available"
	exit $ksft_skip
fi

overall_ret=0

test_default_joins_on_forwarding || overall_ret=1
test_disabled_no_join             || overall_ret=1
test_reenable_joins_immediately   || overall_ret=1
test_disable_leaves_immediately   || overall_ret=1

if [ $overall_ret -eq 0 ]; then
	echo "OK"
	exit 0
else
	echo "FAIL"
	exit 1
fi
