#!/bin/sh
# SPDX-License-Identifier: MIT OR Apache-2.0
# SPDX-FileCopyrightText: 2026 Howard M. Harte
#
# Bring up and check the PL Ethernet port (RJ2): GEM1 over EMIO, through the
# gmii_to_rgmii core in the full bitstream, to PHY2.
#
# ⚠ eth0 is taken DOWN while this runs, and brought back at the end. When
# both ports are on the same LAN and eth0 is up, a ping or a DHCP lease "over
# eth1" can quietly go out of eth0 instead. With eth0 down, every packet that
# gets an answer crossed the new port. Run this from the serial console, not
# over SSH on eth0.
#
# It walks all three link speeds, because switching the core's speed is the
# converter driver's whole job: xilinx_gmii2rgmii writes the negotiated speed
# into the core's register (MDIO address 8) after every PHY status read, and a
# core left at the wrong speed passes no traffic. The core's own status
# (sub-block 2, index 13 of the register file) shows what it was told.
#
# Usage:  eth2test.sh [-k]      -k  leave eth1 up and eth0 down at the end
#
# Throughput is measured from the host: with eth1 addressed, run
#     iperf3 -s                      (here)
#     iperf3 -c <eth1 address>       (host, and again with -R)

set -u
KEEP=0
[ "${1:-}" = "-k" ] && KEEP=1

die()  { echo "eth2test: $*" >&2; restore; exit 1; }
restore() {
    [ $KEEP -eq 1 ] && return
    ip addr flush dev eth1 2>/dev/null
    ip link set eth1 down 2>/dev/null
    ip link set eth0 up
    udhcpc -i eth0 -n -q >/dev/null 2>&1
}

state=$(cat /sys/class/fpga_manager/fpga0/state 2>/dev/null || echo unknown)
[ "$state" = "operating" ] || { echo "eth2test: fpga_manager is '$state'" >&2; exit 1; }
[ -d /sys/class/net/eth1 ] || { echo "eth2test: no eth1 -- device tree without &gem1?" >&2; exit 1; }

# The converter bound? It announces nothing itself, but the PHY's driver name
# is the real PHY's, and the converter's device appears on GEM1's MDIO bus.
bus=$(ls /sys/bus/mdio_bus/devices/ 2>/dev/null | grep '^e000c000' | head -1)
echo "GEM1 MDIO devices: $(ls /sys/bus/mdio_bus/devices/ 2>/dev/null | grep '^e000c000' | tr '\n' ' ')"
[ -n "$bus" ] || echo "  ⚠ none -- the PHY scan found nothing through the core"

# GEM1's clocks must come from EMIO (S15fpga sets these). Check the SOURCE
# selects only: GEM1_CLK_CTRL's CLKACT (bit 0) belongs to the kernel's clock
# gate, which clears it whenever eth1 is down and sets it again on the next
# 'ip link set up'. It also rewrites the dividers for each link speed, which
# is harmless with the EMIO source selected.
rclk=$(( $(devmem 0xF800013C 32) )); clk=$(( $(devmem 0xF8000144 32) ))
printf 'GEM1_RCLK_CTRL 0x%08x (EMIO %s)   GEM1_CLK_CTRL 0x%08x (EMIO %s)\n' \
    $rclk $([ $((rclk & 0x10)) -ne 0 ] && echo yes || echo NO) \
    $clk  $([ $((clk  & 0x40)) -ne 0 ] && echo yes || echo NO)
[ $((rclk & 0x10)) -ne 0 ] && [ $((clk & 0x40)) -ne 0 ] || \
    die "GEM1 is not clocked from EMIO -- S15fpga did not run, or does not route GEM1's clocks"

aux() {   # the gmii_to_rgmii core's status, sub-block 2 index 13
    a=$(devmem 0x801000F4 32)
    printf 'core: MMCM %s, speed register %s, in-band link %d speed %d duplex %d' \
        $([ $((a & 0x10)) -ne 0 ] && echo locked || echo UNLOCKED) \
        $(case $(((a >> 5) & 3)) in 2) echo 1000;; 1) echo 100;; *) echo 10;; esac) \
        $((a & 1)) $(((a >> 1) & 3)) $(((a >> 3) & 1))
}
echo "$(aux)"

echo ""
echo "=== eth0 down, eth1 up"
ip link set eth0 down
ip link set eth1 up

fail=0
# -------------------------------------------------------------------------
for speed in 1000 100 10; do
    echo ""
    echo "=== $speed Mb/s"
    case $speed in
        1000) adv=0x020 ;;   # 1000baseT/Full
        100)  adv=0x008 ;;   # 100baseT/Full
        10)   adv=0x002 ;;   # 10baseT/Full
    esac
    ethtool -s eth1 autoneg on advertise $adv 2>/dev/null
    n=0
    while [ "$(cat /sys/class/net/eth1/carrier 2>/dev/null)" != "1" ]; do
        n=$((n + 1)); [ $n -gt 15 ] && break; sleep 1
    done
    got=$(ethtool eth1 2>/dev/null | sed -n 's/.*Speed: *//p')
    echo "  link: $got, carrier $(cat /sys/class/net/eth1/carrier 2>/dev/null)"
    echo "  $(aux)"
    ip addr flush dev eth1
    if ! udhcpc -i eth1 -n -q -t 5 >/dev/null 2>&1; then
        echo "  RESULT: FAIL -- no DHCP lease over eth1 at $speed"
        fail=1; continue
    fi
    addr=$(ip -4 addr show eth1 | sed -n 's/.*inet \([0-9.]*\).*/\1/p')
    gw=$(ip route | sed -n 's/^default via \([0-9.]*\).*/\1/p' | head -1)
    before=$(cat /sys/class/net/eth1/statistics/rx_errors)
    if ping -c 20 -i 0.2 -q "$gw" 2>/dev/null | grep -q " 0% packet loss"; then
        echo "  lease $addr, gateway $gw: 20/20 pings answered"
    else
        echo "  RESULT: FAIL -- pings to $gw lost at $speed"; fail=1
    fi
    after=$(cat /sys/class/net/eth1/statistics/rx_errors)
    [ "$after" -eq "$before" ] || { echo "  RESULT: FAIL -- rx_errors $before -> $after"; fail=1; }
done

# Leave it at 1000 for any throughput test.
ethtool -s eth1 autoneg on advertise 0x020 2>/dev/null
echo ""
if [ $KEEP -eq 1 ]; then
    n=0; while [ "$(cat /sys/class/net/eth1/carrier)" != "1" ] && [ $n -lt 15 ]; do n=$((n+1)); sleep 1; done
    udhcpc -i eth1 -n -q >/dev/null 2>&1
    echo "eth1 left up at $(ip -4 addr show eth1 | sed -n 's/.*inet \([0-9.]*\).*/\1/p'), eth0 DOWN (-k)"
else
    restore
    echo "eth1 down, eth0 restored"
fi
[ $fail -eq 0 ] && echo "RESULT: PASS -- DHCP and ping over the PL port at 1000, 100 and 10 Mb/s" \
                || echo "RESULT: FAIL"
exit $fail
