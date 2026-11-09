#!/bin/sh
# SPDX-License-Identifier: MIT OR Apache-2.0
# SPDX-FileCopyrightText: 2026 Howard M. Harte
#
# Exercise the PL's AXI BIST engines from Linux: S_AXI_HP1 and HP2 into PS
# DRAM (engines 0 and 1), and the MIG into PL DDR3 (engine 2).
#
# Usage:
#   bisttest.sh [-b <regbase>] [-t <target>] [-m <megabytes>] [-e <engines>]
#
#   -b  register base. Default 0x80100000, where the full design puts the
#       register file on M_AXI_GP1; the ddr design uses 0x80000000.
#   -t  buffer to aim at. Default 0x3F000000, the reserved-memory region in
#       the device tree. Engine 2 takes an offset into PL DDR3 instead,
#       default 0 (the CPU sees it at 0x40000000).
#   -m  megabytes to move. Default 8.
#   -e  which engines, e.g. "0 1". Default: whatever CAPS says is fitted.
#
# ⚠ THE ENGINES HAVE NO BOUNDS CHECK. Whatever -t points at gets overwritten
# at up to 64 bits a clock. Aim them at the reserved region or at PL DDR3, never at
# an address Linux is using.
#
# ⚠ The HP ports are not coherent with the CPU's caches. The reserved region
# is marked `no-map` so /dev/mem hands it back uncached; if you point this at
# ordinary memory instead, a CPU-side check may read stale cache lines and
# blame the fabric.

set -u

REGBASE=0x80100000
TARGET=""
MB=8
ENGINES=""

while [ $# -gt 0 ]; do
    case "$1" in
        -b) REGBASE=$2; shift 2 ;;
        -t) TARGET=$2;  shift 2 ;;
        -m) MB=$2;      shift 2 ;;
        -e) ENGINES=$2; shift 2 ;;
        *) echo "bisttest: unknown option $1" >&2; exit 2 ;;
    esac
done

fails=0
note() { printf '  %s\n' "$*"; }
bad()  { printf '  FAIL  %s\n' "$*"; fails=$((fails + 1)); }
ok()   { printf '  ok    %s\n' "$*"; }

rd() { devmem "$1" 32; }
wr() { devmem "$1" 32 "$2"; }

# engine n's register window
# ⚠ Engine 2 does NOT follow the 64-byte stride. The full design keeps the
# capture, camera and Ethernet status in the window that would be its own, so
# the engine on the MIG sits in the next one, at +0x140; the ddr design has
# nothing to put there and leaves it at +0xC0. The register base says which
# design this is: the ddr one puts its file at 0x8000_0000.
E2OFF=0x140
[ "$REGBASE" = "0x80000000" ] && E2OFF=0xC0
ebase() {
    if [ "$1" = "2" ]; then printf '0x%X' $(( REGBASE + E2OFF ))
    else                    printf '0x%X' $(( REGBASE + 0x40 * ($1 + 1) )); fi
}
ereg()  { printf '0x%X' $(( $(ebase "$1") + $2 )); }

CTRL=0x00; ADDR=0x04; BURSTS=0x08; SEED=0x0C; STATUS=0x10
ERRORS=0x14; CYCLES=0x18; ERRBITS=0x1C; BADADDR=0x20
BADEXP=0x24; BADGOT=0x28; BEATS=0x2C; ACK=0x30

AUX=$(printf '0x%X' $(( REGBASE + 0x3C )))

# ------------------------------------------------- the MIG ownership switch
# Engine 2 shares the MIG's single AXI port with the CPU (see axi_owner.v).
# AUX[0] asks for the handover; AUX[16] says who actually has it, and the
# switch is DEFERRED until the bus is idle, so both of these poll.
#
# ⚠ While the engine owns it, any CPU access to PL DDR3 is answered SLVERR.
# That is deliberate -- a master left waiting on the PL bus on this board
# means a JTAG reset -- but it does mean nothing else may touch 0x40000000
# until it is handed back.
# AUX's low half is shared: [15] is the camera guard's bypass in the full
# design. Only bit 0 is changed here, and the read-only high half is not
# written back.
aux_bit0() {
    wr $AUX $(printf '0x%X' $(( ($(printf '%d' $(rd $AUX)) & 0xFFFE) | $1 )))
}

take_mig() {
    aux_bit0 1
    _i=0
    while [ $_i -lt 100 ]; do
        [ $(( $(printf '%d' $(rd $AUX)) & 0x10000 )) -ne 0 ] && {
            ok "engine 2 owns the MIG"; return 0; }
        _i=$((_i + 1))
    done
    bad "the MIG was never handed to engine 2 (AUX=$(rd $AUX))"
    return 1
}

give_mig_back() {
    aux_bit0 0
    _i=0
    while [ $_i -lt 100 ]; do
        [ $(( $(printf '%d' $(rd $AUX)) & 0x10000 )) -eq 0 ] && return 0
        _i=$((_i + 1))
    done
    bad "the MIG was never handed back to the CPU (AUX=$(rd $AUX))"
    return 1
}

state=$(cat /sys/class/fpga_manager/fpga0/state 2>/dev/null || echo unknown)
[ "$state" = "operating" ] || {
    echo "bisttest: fpga_manager state is '$state' -- load a bitstream first" >&2
    exit 1
}

id=$(rd $REGBASE)
caps=$(rd $(printf '0x%X' $((REGBASE + 0x38))))
echo "register file at $REGBASE: ID=$id CAPS=$caps"
[ "$id" = "0x5A710002" ] || bad "ID is $id, expected 0x5A710002"

if [ -z "$ENGINES" ]; then
    ENGINES=""
    for n in 0 1 2; do
        if [ $(( $(printf '%d' $caps) & (1 << n) )) -ne 0 ]; then
            ENGINES="$ENGINES $n"
        fi
    done
fi
echo "engines fitted:$ENGINES"

# ---------------------------------------------------------------- one run
# run <engine> <target> <bursts> <seed> <mode>
run() {
    _e=$1; _t=$2; _b=$3; _s=$4; _m=$5
    wr $(ereg $_e $ADDR)   "$_t"
    wr $(ereg $_e $BURSTS) "$_b"
    wr $(ereg $_e $SEED)   "$_s"
    wr $(ereg $_e $ACK)    0x1
    # CTRL: start | mode<<8   (irq left off here; the interrupt is tested
    # separately, because blocking on /dev/uio needs the run to be in flight)
    wr $(ereg $_e $CTRL) $(printf '0x%X' $(( 1 | (_m << 8) )))
    _i=0
    while [ $_i -lt 2000 ]; do
        _st=$(rd $(ereg $_e $STATUS))
        [ $(( $(printf '%d' $_st) & 2 )) -ne 0 ] && return 0
        _i=$((_i + 1))
    done
    bad "engine $_e never reported done (STATUS=$_st)"
    return 1
}

report() {
    _e=$1; _bytes_per_beat=$2
    _err=$(printf '%d' $(rd $(ereg $_e $ERRORS)))
    _cyc=$(printf '%d' $(rd $(ereg $_e $CYCLES)))
    _bts=$(printf '%d' $(rd $(ereg $_e $BEATS)))
    _st=$(rd $(ereg $_e $STATUS))
    _bytes=$((_bts * _bytes_per_beat))
    if [ "$_cyc" -gt 0 ]; then
        # 100 MHz: MB/s = bytes * 100 / cycles
        _mbs=$((_bytes * 100 / _cyc))
    else
        _mbs=0
    fi
    # ⚠ To stderr on purpose. This function's STDOUT is captured by the caller
    # to get the error count back, so anything printed there would disappear
    # into a variable instead of reaching the console.
    printf '  engine %d: %d errors, %d beats, %d bytes, %d cycles -> %d MB/s\n' \
           "$_e" "$_err" "$_bts" "$_bytes" "$_cyc" "$_mbs" >&2
    echo "$_err"
}

# The watchdog is checked here, in the caller's shell: report runs inside
# $(...), so a failure it counted would be lost with the subshell.
watchdog_clear() {
    _st=$(rd $(ereg $1 $STATUS))
    [ $(( $(printf '%d' $_st) & 8 )) -eq 0 ] && return 0
    bad "engine $1: watchdog fired -- the slave stopped answering (STATUS=$_st)"
    return 1
}

for e in $ENGINES; do
    echo ""
    echo "=== engine $e ==="

    if [ "$e" = "2" ]; then
        # ⚠ Engine 2 addresses the MIG DIRECTLY, so its addresses are
        # OFFSETS INTO THE DRAM, starting at 0. The CPU reaches the same
        # memory at 0x40000000 because that is where M_AXI_GP0's window sits
        # and the MIG only sees the low 30 bits. Pointing this engine at
        # 0x40000000 would wrap to offset 0 anyway -- right answer, wrong
        # reasoning -- so it is written out properly here.
        tgt=${TARGET:-0x00000000}        # PL DDR3, as an offset
        cpu_base=0x40000000              # ... and where the CPU sees it
        bpb=4                            # the MIG slave is 32 bits wide
        take_mig || continue
    else
        tgt=${TARGET:-0x3F000000}        # the reserved region in PS DRAM
        cpu_base=$tgt
        bpb=8                            # S_AXI_HP is 64 bits wide
    fi
    bursts=$(( MB * 1024 * 1024 / (16 * bpb) ))
    echo "  target $tgt, $MB MB, $bursts bursts of 16 x $bpb bytes"

    # --- 1. write then read back, checking as it goes
    run "$e" "$tgt" "$bursts" 0x12345678 2 || continue
    errs=$(report "$e" "$bpb" | tail -1)
    if ! watchdog_clear "$e"; then
        :
    elif [ "$errs" = "0" ]; then
        ok "engine $e: write + verify clean"
    else
        bad "engine $e: $errs mismatching beats"
        printf '        first bad: addr=%s exp=%s got=%s errbits=%s\n' \
            "$(rd $(ereg $e $BADADDR))" "$(rd $(ereg $e $BADEXP))" \
            "$(rd $(ereg $e $BADGOT))"  "$(rd $(ereg $e $ERRBITS))"
    fi

    # --- 2. the CPU can see what the fabric wrote, and it is not all one value
    # ⚠ Read through the CPU's OWN view. For engine 2 that is a different
    # address from the one the engine was given, and it is only reachable once
    # the MIG has been handed back -- while the engine owns it, a CPU access
    # to PL DDR3 is answered SLVERR and turns into a bus error.
    [ "$e" = "2" ] && give_mig_back
    w0=$(rd "$cpu_base")
    w1=$(rd $(printf '0x%X' $(( $(printf '%d' $cpu_base) + 8 ))))
    w2=$(rd $(printf '0x%X' $(( $(printf '%d' $cpu_base) + 4096 ))))
    if [ "$w0" = "$w1" ] || [ "$w0" = "$w2" ] || [ "$w0" = "0x00000000" ]; then
        bad "engine $e: memory looks wrong from the CPU at $cpu_base ($w0 $w1 $w2)"
    else
        ok "engine $e: CPU sees varying data at $cpu_base ($w0 $w1 $w2)"
    fi

    # --- 3. the check is live: corrupt one word and require a complaint.
    # This also proves the engine and the CPU are talking about the SAME
    # memory, which a self-contained write-then-read cannot show.
    save=$w0
    wr "$cpu_base" 0xDEADBEEF
    [ "$e" = "2" ] && { take_mig || continue; }
    run "$e" "$tgt" "$bursts" 0x12345678 1 || continue
    errs2=$(report "$e" "$bpb" | tail -1)
    if ! watchdog_clear "$e"; then
        :
    elif [ "$errs2" = "0" ]; then
        bad "engine $e: a word the CPU changed went unnoticed -- the check is not checking"
    else
        ok "engine $e: noticed the word the CPU changed ($errs2 errors)"
    fi
    [ "$e" = "2" ] && give_mig_back
    wr "$cpu_base" "$save"
done

# ------------------------------------------------- engines 0 and 1 agree
case "$ENGINES" in
    *0*1*)
        echo ""
        echo "=== the two HP ports see the same memory ==="
        tgt=${TARGET:-0x3F000000}
        bursts=$(( MB * 1024 * 1024 / 128 ))
        run 0 "$tgt" "$bursts" 0xA5A5F00D 0 || true      # engine 0 writes
        run 1 "$tgt" "$bursts" 0xA5A5F00D 1 || true      # engine 1 checks
        e1=$(printf '%d' $(rd $(ereg 1 $ERRORS)))
        if [ "$e1" = "0" ]; then
            ok "HP2 verified what HP1 wrote"
        else
            bad "HP2 found $e1 errors in what HP1 wrote"
        fi
        ;;
esac

# ------------------------------------------------------------- interrupts
echo ""
echo "=== the fabric interrupt ==="
if [ ! -e /dev/uio0 ]; then
    note "no /dev/uio0 -- CONFIG_UIO_PDRV_GENIRQ off, or the device tree"
    note "nodes are missing. Skipped, not failed."
else
    for u in 0 1; do
        e=$u
        case " $ENGINES " in *" $e "*) ;; *) continue ;; esac
        [ -e /dev/uio$u ] || { note "no /dev/uio$u"; continue; }
        tgt=${TARGET:-0x3F000000}

        # Clear anything already pending, at BOTH ends. The engine's irq is a
        # level held until ACK, and uio_pdrv_genirq masks the GIC line in its
        # handler and leaves userspace to re-arm it by writing a 4-byte 1.
        # Re-arming before clearing the engine would just re-fire instantly.
        wr $(ereg $e $ACK) 0x1
        printf '\001\000\000\000' > /dev/uio$u 2>/dev/null || true

        before=$(cat /sys/class/uio/uio$u/event 2>/dev/null || echo 0)

        # ⚠ The reader has to be blocked in read() BEFORE the engine is
        # started. uio records the event count at open(), so an interrupt that
        # arrives first is already accounted for and the next read() blocks
        # forever. A run finishes in microseconds, far quicker than a shell
        # can start `dd`, so a reader started afterward blocks forever on
        # hardware that did interrupt; /proc/interrupts (GIC 61 and 62) shows
        # the difference.
        # ⚠ No `timeout` here: this board's busybox does not have it, and
        # `timeout 5 dd ...` exits 127 immediately, which looks exactly like
        # "the interrupt never arrived" and sends you looking at working
        # hardware. This watchdog uses only sleep and kill.
        dd if=/dev/uio$u bs=4 count=1 >/dev/null 2>&1 &
        ddpid=$!
        ( sleep 5; kill $ddpid 2>/dev/null ) &
        killer=$!
        sleep 1

        wr $(ereg $e $ADDR)   "$tgt"
        wr $(ereg $e $BURSTS) 1024
        wr $(ereg $e $SEED)   0x5EED
        # irq_en | start, mode 2
        wr $(ereg $e $CTRL) $(printf '0x%X' $(( 1 | (1 << 4) | (2 << 8) )))

        if wait $ddpid; then
            kill $killer 2>/dev/null
            after=$(cat /sys/class/uio/uio$u/event 2>/dev/null || echo 0)
            ok "engine $e interrupted the CPU (uio$u events $before -> $after)"
        else
            kill $killer 2>/dev/null
            bad "engine $e did not interrupt within 5 s (uio$u)"
        fi
        wr $(ereg $e $ACK) 0x1
        printf '\001\000\000\000' > /dev/uio$u 2>/dev/null || true
    done
fi

echo ""
if [ $fails -eq 0 ]; then
    echo "bisttest: PASS"
else
    echo "bisttest: FAIL -- $fails check(s)"
fi
exit $fails
