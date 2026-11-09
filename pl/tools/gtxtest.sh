#!/bin/sh
# SPDX-License-Identifier: MIT OR Apache-2.0
# SPDX-FileCopyrightText: 2026 Howard M. Harte
#
# Exercise the SFP+ cages' GTX transceivers with the PRBS exerciser in
# gtx_prbs.v (register block 3, at 0x100 in the full design), at 3.125, 6.25
# or 10.3125 Gb/s.
#
# Two stages at each rate, and the second only means something if the first
# passes:
#
#   1. NEAR-END PMA LOOPBACK on each channel. No cable, no module: the
#      pattern goes through the PLL, the serializer, the deserializer and the
#      CDR and never leaves the chip. A failure here is the transceiver or
#      its clocking, not anything outside.
#
#   2. EXTERNAL, through whatever joins SFP1 (J1) to SFP2 (J4) -- a passive
#      DAC cable, or two modules and a lead. Each channel's checker then
#      grades what the OTHER channel transmitted.
#
# ⚠ A CHECKER THAT IS NOT CHECKING REPORTS ZERO ERRORS. So every stage
# injects a single TX bit error and requires it to be counted at the RIGHT
# end and nowhere else: in stage 2, an error injected on SFP1 must be counted
# by SFP2's checker and not by SFP1's. That is what proves the pattern really
# crossed the cable, rather than coming back through an internal loopback.
#
# ⚠ ONE injected bit error is counted as a small BURST, not as one. The
# transceiver's PRBS checker is self-synchronizing: it predicts each bit from
# bits it has already received, so a bad bit is flagged again each time it is
# used as a tap -- PRBS-31 (x^31 + x^28 + 1) has two. The count is the same
# for every injection while a link stays up, and depends on the word
# alignment the link settles into after a reset, so this accepts 1 to
# MAXBURST.
#
# WHAT THE NUMBERS MEAN. The checker flags erroneous 40-bit WORDS, so a
# count of zero over N words bounds the bit error rate from above. By the
# rule of three, zero errors in B bits means BER < 3/B at 95% confidence.
# The counters are 32 bits in the user clock (the line rate / 40) and
# saturate after 16.7 s at 10.3125 Gb/s, so keep -t below that there.
#
# RATES. Writing RATE (0x30) runs the exerciser's own sequence per channel:
# the receiver CDR's settings and the divider over the DRP, then the PLL, then
# a full reset. 0 = 3.125 Gb/s (CPLL, /2), 1 = 6.25 (CPLL, /1), 2 = 10.3125
# (the quad's QPLL, /1). Both channels are always set to the same rate, as a
# cable between them needs.
#
# Usage:  gtxtest.sh [-r 0|1|2|all] [-t seconds] [-s] [-b regbase]
#   -r  rate, or all three in turn (default 0)
#   -t  seconds per stage (default 10)
#   -s  skip stage 1
#   -b  register base (default 0x80100000)

set -u

REGBASE=0x80100000
SECS=10
SKIP_NEAR=0
MAXBURST=8
RATES=0
while [ $# -gt 0 ]; do
    case "$1" in
        -r) RATES=$2; shift 2 ;;
        -t) SECS=$2; shift 2 ;;
        -s) SKIP_NEAR=1; shift ;;
        -b) REGBASE=$2; shift 2 ;;
        *)  echo "usage: $0 [-r 0|1|2|all] [-t seconds] [-s] [-b regbase]" >&2; exit 2 ;;
    esac
done
[ "$RATES" = all ] && RATES="0 1 2"

die() { echo "gtxtest: $*" >&2; exit 1; }

# ⚠ An AXI access to an unconfigured PL hangs the CPU outright -- not a bus
# error, a dead board that needs a system reset over JTAG.
state=$(cat /sys/class/fpga_manager/fpga0/state 2>/dev/null || echo unknown)
[ "$state" = "operating" ] || die "fpga_manager is '$state' -- load the bitstream first"

B=$((REGBASE + 0x100))
rd() { devmem $(printf '0x%08x' $((B + $1))) 32; }
wr() { devmem $(printf '0x%08x' $((B + $1))) 32 "$2"; }

# Per-channel register offsets
ctrl()  { [ "$1" = 0 ] && echo 0x08 || echo 0x1C; }
pulse() { [ "$1" = 0 ] && echo 0x0C || echo 0x20; }
stat()  { [ "$1" = 0 ] && echo 0x10 || echo 0x24; }
errs()  { [ "$1" = 0 ] && echo 0x14 || echo 0x28; }
cycs()  { [ "$1" = 0 ] && echo 0x18 || echo 0x2C; }
name()  { [ "$1" = 0 ] && echo "SFP1" || echo "SFP2"; }
RATE=0x30; RATE_STAT=0x34
gbps()  { case $1 in 0) echo 3.125 ;; 1) echo 6.25 ;; 2) echo 10.3125 ;; esac; }

id=$(rd 0x00)
[ "$id" = "0x47580003" ] || die "ID reads $id, expected 0x47580003 -- this bitstream has no multi-rate GTX exerciser"

# The counts are copied across every 4096 user clocks (52 us at the slowest
# rate), so wait a little past that before trusting a read.
settle() { usleep 100000 2>/dev/null || sleep 1; }

# set_rate <r>: both channels to rate r, and wait for both sequences.
set_rate() {
    wr $RATE $(printf '0x%x' $(( $1 | ($1 << 4) )))
    n=0
    while [ $(( $(rd $RATE_STAT) & 0x3 )) -ne 0 ]; do
        n=$((n + 1)); [ $n -gt 50 ] && die "rate sequence did not finish: RATE_STAT=$(rd $RATE_STAT)"
        settle
    done
    s=$(( $(rd $RATE_STAT) ))
    [ $(( s & 0x30 )) -eq 0 ] || die "rate sequence failed (DRP timeout): RATE_STAT=$(printf 0x%08x $s)"
    [ $(( (s >> 16) & 3 )) -eq $1 ] && [ $(( (s >> 20) & 3 )) -eq $1 ] ||
        die "rate not in effect: RATE_STAT=$(printf 0x%08x $s)"
    if [ $1 -eq 2 ]; then
        [ $(( s & 0x100 )) -ne 0 ] || die "the QPLL is not locked: RATE_STAT=$(printf 0x%08x $s)"
    fi
}

# set_mode <loopback> : PRBS-31 both ways on both channels, then reset the
# receivers so the new loopback path takes effect, then wait for them.
PRBS=4        # PRBS-31: the pattern with the longest run lengths
wait_up() {
    n=0
    while :; do
        s0=$(( $(rd $(stat 0)) & 0x1F )); s1=$(( $(rd $(stat 1)) & 0x1F ))
        [ $s0 -eq 31 ] && [ $s1 -eq 31 ] && return 0
        n=$((n + 1)); [ $n -gt 50 ] && return 1
        settle
    done
}
set_mode() {
    lb=$1
    v=$(( lb | (PRBS << 4) | (PRBS << 8) | (TXPOL << 12) | (RXPOL << 13) ))
    wr $(ctrl 0) $(printf '0x%x' $v)
    wr $(ctrl 1) $(printf '0x%x' $v)
    wr 0x04 0xA        # both receivers into reset...
    settle
    wr 0x04 0x0        # ...and out
    wait_up || die "receivers did not come up: STAT0=$(rd $(stat 0)) STAT1=$(rd $(stat 1))"
}

clear_counts() { wr $(pulse 0) 0x2; wr $(pulse 1) 0x2; settle; }

# One window of SECS seconds, printed per channel.
measure() {
    clear_counts
    sleep "$SECS"
    for c in 0 1; do
        e=$(( $(rd $(errs $c)) )); y=$(( $(rd $(cycs $c)) ))
        awk -v n="$(name $c)" -v e="$e" -v y="$y" 'BEGIN {
            bits = y * 40
            if (y == 0) { printf "    %s: NO CYCLES COUNTED -- receiver not up\n", n; exit }
            if (y == 4294967295) printf "    %s: ⚠ the cycle count saturated -- shorten -t\n", n
            if (e == 0)
                printf "    %s: 0 word errors in %.3g bits  -> BER < %.1e (95%%)\n", n, bits, 3 / bits
            else
                printf "    %s: %d word errors in %.3g bits -> word error rate %.3g\n", n, e, bits, e / y
        }'
        eval "E$c=$e; Y$c=$y"
    done
}

# inject <tx channel> : one TX error; report which checkers counted it.
inject() {
    clear_counts
    wr $(pulse $1) 0x1
    settle
    i0=$(( $(rd $(errs 0)) )); i1=$(( $(rd $(errs 1)) ))
}

# burst_at <channel>: the last injection was counted by that channel's
# checker as a burst of 1..MAXBURST words, and by the other one not at all.
burst_at() {
    if [ "$1" = 0 ]; then here=$i0; there=$i1; else here=$i1; there=$i0; fi
    [ "$here" -ge 1 ] && [ "$here" -le $MAXBURST ] && [ "$there" -eq 0 ]
}

echo "GTX exerciser: ID $id, register block at $(printf '0x%08x' $B)"
for c in 0 1; do
    s=$(( $(rd $(stat $c)) ))
    printf '  %s: STAT 0x%02x  cplllock=%d  cage LOS=%d\n' \
        "$(name $c)" $s $((s & 1)) $(((s >> 7) & 1))
done
[ $(( $(rd $(stat 0)) & 1 )) -eq 1 ] || die "SFP1's CPLL is not locked -- no reference clock?"
[ $(( $(rd $(stat 1)) & 1 )) -eq 1 ] || die "SFP2's CPLL is not locked -- no reference clock?"

# test_rate <r>: both stages at one rate; sets RFAIL.
test_rate() {
    RFAIL=0
    set_rate $1
    echo ""
    echo "##### $(gbps $1) Gb/s (RATE $1)"
    TXPOL=0; RXPOL=0

    if [ $SKIP_NEAR -eq 0 ]; then
        echo ""
        echo "=== 1. near-end PMA loopback, PRBS-31, ${SECS}s -- no cable involved"
        set_mode 2
        measure
        [ "$E0" -eq 0 ] && [ "$E1" -eq 0 ] || { echo "  RESULT: FAIL -- errors inside the chip"; RFAIL=1; }
        inject 0
        echo "    an error injected on SFP1's TX: SFP1 counted $i0, SFP2 counted $i1"
        burst_at 0 || { echo "  RESULT: FAIL -- SFP1's checker is not seeing its own TX"; RFAIL=1; }
        inject 1
        echo "    an error injected on SFP2's TX: SFP1 counted $i0, SFP2 counted $i1"
        burst_at 1 || { echo "  RESULT: FAIL -- SFP2's checker is not seeing its own TX"; RFAIL=1; }
        [ $RFAIL -eq 0 ] && echo "  RESULT: PASS -- both transceivers are sound internally"
    fi

    echo ""
    echo "=== 2. external, SFP1 <-> SFP2 through the cable, PRBS-31, ${SECS}s"
    # A P/N swap anywhere on either path would make every word wrong, so if
    # the normal polarity fails outright, try the other three combinations
    # before concluding anything. Polarity is set on the RECEIVE side.
    found=0
    for pol in "0 0" "0 1" "1 0" "1 1"; do
        set -- $pol
        RX0=$1; RX1=$2
        v0=$(( 0 | (PRBS << 4) | (PRBS << 8) | (RX0 << 13) ))
        v1=$(( 0 | (PRBS << 4) | (PRBS << 8) | (RX1 << 13) ))
        wr $(ctrl 0) $(printf '0x%x' $v0)
        wr $(ctrl 1) $(printf '0x%x' $v1)
        wr 0x04 0xA; settle; wr 0x04 0x0
        wait_up
        clear_counts; sleep 1
        e0=$(( $(rd $(errs 0)) )); y0=$(( $(rd $(cycs 0)) ))
        e1=$(( $(rd $(errs 1)) )); y1=$(( $(rd $(cycs 1)) ))
        printf '    RX polarity SFP1=%s SFP2=%s: 1 s probe, errors %s / %s\n' "$RX0" "$RX1" "$e0" "$e1"
        if [ "$e0" -eq 0 ] && [ "$e1" -eq 0 ] && [ "$y0" -gt 0 ] && [ "$y1" -gt 0 ]; then
            found=1; break
        fi
    done

    if [ $found -eq 0 ]; then
        echo "  RESULT: FAIL -- no polarity combination gives a clean link."
        echo "          With a passive DAC: is it seated in BOTH cages? LOS is not"
        echo "          informative for a DAC. Check stage 1 passed first."
        RFAIL=1
        return
    fi
    [ "$RX0$RX1" = "00" ] || echo "    ⚠ needed RX polarity SFP1=$RX0 SFP2=$RX1: a P/N swap on the path"

    measure
    [ "$E0" -eq 0 ] && [ "$E1" -eq 0 ] || { echo "  RESULT: errors over the cable"; RFAIL=1; }

    # The decisive check: an error sent from one cage must arrive at the OTHER.
    inject 0
    echo "    an error injected on SFP1's TX: SFP1 counted $i0, SFP2 counted $i1"
    burst_at 1 || { echo "  RESULT: FAIL -- SFP1's TX is not what SFP2 receives"; RFAIL=1; }
    inject 1
    echo "    an error injected on SFP2's TX: SFP1 counted $i0, SFP2 counted $i1"
    burst_at 0 || { echo "  RESULT: FAIL -- SFP2's TX is not what SFP1 receives"; RFAIL=1; }
}

fail=0
summary=
for r in $RATES; do
    case $r in 0|1|2) ;; *) die "rate $r: use 0, 1, 2 or all" ;; esac
    test_rate $r
    [ $RFAIL -eq 0 ] && summary="$summary $(gbps $r):PASS" || { summary="$summary $(gbps $r):FAIL"; fail=1; }
done

echo ""
if [ $fail -eq 0 ]; then
    echo "RESULT: PASS --$summary Gb/s -- both ways through the cable, and"
    echo "        each cage's errors arrive at the other one."
else
    echo "RESULT: FAIL --$summary"
fi
exit $fail
