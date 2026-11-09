// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
//
// Test the RK-ZYNQ7100's PL DDR3 (1 GB at 0x4000_0000 through M_AXI_GP0) from
// Linux userspace.
//
//     arm-buildroot-linux-gnueabihf-gcc -O2 -static -o memtest memtest.c
//
// ⚠ Why a C program and not `dd if=/dev/mem`: on this memory, dd fails with
// "Bad address" and moves zero records. /dev/mem's read()/write() path goes
// through xlate_dev_mem_ptr(), which returns NULL for a physical address that
// is not kernel RAM, so the copy gets -EFAULT. mmap() of the same range works
// -- which is why busybox `devmem`, which mmaps, reads and writes it fine.
// Anything bulk therefore has to mmap.
//
// The mapping is uncached device memory (the kernel maps non-RAM that way), so
// the throughput printed here is the floor, not the DRAM's ability: every
// access crosses a 32-bit AXI bus at 100 MHz with no cache to amortize it.
//
// Four tests, cheapest and most diagnostic first:
//
//   1. address bus   one marker per address bit. A stuck or swapped address
//                    line makes two different addresses the same cell, which
//                    a pattern test over one region cannot see at all: the
//                    aliased write lands on top and the read still matches.
//   2. data bus      walking ones and zeros at a single address; names the
//                    exact bit when a DQ line is stuck or shorted.
//   3. whole device  one word per 4 KiB page across the full gigabyte, all
//                    written before any is read, so late aliasing shows up.
//   4. bulk          a block written, read back and timed.

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#define BASE        0x40000000UL           /* PL DDR3 through M_AXI_GP0 */
#define SIZE        (1024UL * 1024 * 1024) /* 1 GiB */
#define WINDOW      (32UL * 1024 * 1024)   /* mmap this much at a time */
#define PAGE_STRIDE 4096UL
#define BULK_BYTES  (8UL * 1024 * 1024)

static int fd = -1;
static void *win_p = MAP_FAILED;
static unsigned long win_off = ~0UL;   /* offset of the mapped window */

static double now(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + 1e-9 * ts.tv_nsec;
}

/* Map the WINDOW-aligned window holding `off`, and return a pointer into it. */
static volatile uint32_t *at(unsigned long off)
{
    unsigned long base = off & ~(WINDOW - 1);

    if (base != win_off) {
        if (win_p != MAP_FAILED)
            munmap(win_p, WINDOW);
        win_p = mmap(NULL, WINDOW, PROT_READ | PROT_WRITE, MAP_SHARED,
                     fd, (off_t)(BASE + base));
        if (win_p == MAP_FAILED) {
            fprintf(stderr, "mmap at +0x%lx failed: %s\n", base, strerror(errno));
            exit(1);
        }
        win_off = base;
    }
    return (volatile uint32_t *)((char *)win_p + (off - win_off));
}

static int fails;

static void check(unsigned long off, uint32_t want)
{
    uint32_t got = *at(off);
    if (got != want) {
        if (fails < 16)
            printf("   MISMATCH at 0x%08lx: read 0x%08x, wrote 0x%08x\n",
                   BASE + off, got, want);
        fails++;
    }
}

/* ------------------------------------------------------------------ */
static void test_address_bus(void)
{
    unsigned long offs[32];
    int n = 0;

    printf("== address bus\n");
    offs[n++] = 0;
    for (unsigned b = 2; (1UL << b) < SIZE; b++)
        offs[n++] = 1UL << b;

    /* Every marker written before any is read: that is the point. */
    for (int i = 0; i < n; i++)
        *at(offs[i]) = 0xAA550000u | (uint32_t)i;
    for (int i = 0; i < n; i++)
        check(offs[i], 0xAA550000u | (uint32_t)i);

    printf("   %d addresses (offset 0 and each power of two to 0x%lx)\n",
           n, offs[n - 1]);
}

static void test_data_bus(void)
{
    printf("== data bus\n");
    for (int b = 0; b < 32; b++) {
        uint32_t v = 1u << b;
        *at(0) = v;
        if (*at(0) != v) { printf("   DQ%d stuck low?\n", b);  fails++; }
        *at(0) = ~v;
        if (*at(0) != ~v) { printf("   DQ%d stuck high?\n", b); fails++; }
    }
    printf("   walking ones and zeros, 32 bits\n");
}

static void test_whole_device(void)
{
    unsigned long off;
    double t0 = now();

    printf("== whole device, one word per %lu bytes over %lu MiB\n",
           PAGE_STRIDE, SIZE >> 20);

    for (off = 0; off < SIZE; off += PAGE_STRIDE)
        *at(off) = (uint32_t)(off ^ 0x5A710000UL);
    for (off = 0; off < SIZE; off += PAGE_STRIDE)
        check(off, (uint32_t)(off ^ 0x5A710000UL));

    printf("   %lu words, %.1f s\n", SIZE / PAGE_STRIDE, now() - t0);
}

static void test_bulk(unsigned long off, const char *where)
{
    unsigned long i, words = BULK_BYTES / 4;
    volatile uint32_t *p;
    double t0, twr, trd;
    uint32_t seed = 12345u ^ (uint32_t)off, x;

    printf("== bulk %lu MiB at %s (0x%08lx)\n",
           BULK_BYTES >> 20, where, BASE + off);

    p = at(off);            /* BULK_BYTES <= WINDOW, so one window covers it */

    t0 = now();
    for (i = 0, x = seed; i < words; i++) { x = x * 1103515245u + 12345u; p[i] = x; }
    twr = now() - t0;

    t0 = now();
    for (i = 0, x = seed; i < words; i++) {
        x = x * 1103515245u + 12345u;
        if (p[i] != x) {
            if (fails < 16)
                printf("   MISMATCH at 0x%08lx: read 0x%08x, wrote 0x%08x\n",
                       BASE + off + i * 4, p[i], x);
            fails++;
        }
    }
    trd = now() - t0;

    printf("   write %.1f MB/s, read+verify %.1f MB/s (uncached)\n",
           BULK_BYTES / twr / 1e6, BULK_BYTES / trd / 1e6);
}

int main(void)
{
    fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) {
        fprintf(stderr, "open /dev/mem: %s\n", strerror(errno));
        return 1;
    }

    printf("PL DDR3 at 0x%08lx, %lu MiB\n\n", BASE, SIZE >> 20);

    test_address_bus();
    test_data_bus();
    test_whole_device();
    test_bulk(0, "the bottom");
    test_bulk(SIZE - WINDOW, "the top");

    printf("\n%s: %d mismatches\n", fails ? "FAILED" : "PASSED", fails);
    return fails ? 1 : 0;
}
