/* tools/m68ksim.c — Musashi MC68030 bus-cycle reference log generator
 *
 * Loads a $readmemh hex file (one 32-bit word per line) at address 0,
 * runs the 68030 until it halts, and prints every external bus cycle:
 *
 *   BUS R 00000000 00010000 fc=110 siz=00
 *   BUS W 00001000 deadbeef fc=101 siz=00
 *
 * Format matches cosim73_tb.sv's bus logger exactly.
 *
 * 32-bit bus simulation:
 *   The DUT testbench asserts DSACK0+DSACK1 simultaneously (32-bit bus).
 *   The 68030 protocol: when a word (SIZ=10) is requested with a 32-bit ack,
 *   the bus transfers 4 bytes in 1 cycle and the address advances by 4.
 *   To replicate this, m68k_read_memory_16 caches 32-bit reads and emits one
 *   log line per 4-byte-aligned block (siz=10, full 32-bit data) — matching
 *   the DUT bus logger's output for instruction fetches.
 *
 * Usage:
 *   ./tools/m68ksim tests/smoke.hex [max_cycles]
 */

#define M68K_EMULATE_FC 1

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

#include "m68k.h"

/* ── Memory model — 4 KB (1024 × 32-bit words) at address 0 ─────────────── */
#define MEM_WORDS 1024
static uint32_t g_mem[MEM_WORDS];

/* ── FC tracking ──────────────────────────────────────────────────────────── */
static unsigned int g_fc = 0;
static void fc_callback(unsigned int fc) { g_fc = fc; }

/* ── Memory helpers ───────────────────────────────────────────────────────── */
static uint32_t mem_r32(uint32_t a) { return g_mem[(a >> 2) & (MEM_WORDS - 1)]; }
static uint16_t mem_r16(uint32_t a) { uint32_t w = mem_r32(a); return (a & 2) ? (uint16_t)w : (uint16_t)(w >> 16); }
static uint8_t  mem_r8 (uint32_t a) { uint32_t w = mem_r32(a); return (uint8_t)(w >> ((3 - (a & 3)) * 8)); }
static void mem_w32(uint32_t a, uint32_t d)  { g_mem[(a >> 2) & (MEM_WORDS - 1)] = d; }
static void mem_w16(uint32_t a, uint16_t d)  { uint32_t *p = &g_mem[(a >> 2) & (MEM_WORDS - 1)]; if (a & 2) *p = (*p & 0xFFFF0000u) | d; else *p = (*p & 0x0000FFFFu) | ((uint32_t)d << 16); }
static void mem_w8 (uint32_t a, uint8_t d)   { uint32_t *p = &g_mem[(a >> 2) & (MEM_WORDS - 1)]; int sh = (3-(a&3))*8; *p = (*p & ~(0xFFu<<sh)) | ((uint32_t)d<<sh); }

/* ── FC/SIZ formatting ────────────────────────────────────────────────────── */
static void print_fc(void) { putchar('0'+((g_fc>>2)&1)); putchar('0'+((g_fc>>1)&1)); putchar('0'+(g_fc&1)); }

/* ── 32-bit bus cache for word reads ─────────────────────────────────────── */
static uint32_t g_lw_addr = 0xFFFFFFFFu;
static uint32_t g_lw_data = 0;

/* ── Musashi callbacks ────────────────────────────────────────────────────── */
unsigned int m68k_read_memory_8(unsigned int a) {
    uint8_t v = mem_r8(a);
    printf("BUS R %08x %02x fc=", a, v); print_fc(); printf(" siz=01\n");
    return v;
}

/* Word reads: simulate 32-bit bus response (DSACK0+DSACK1 both asserted).
 * One BUS R log line per 4-byte-aligned block with full 32-bit data, siz=10.
 * This matches what the DUT testbench produces for instruction fetch cycles. */
unsigned int m68k_read_memory_16(unsigned int a) {
    uint32_t aligned = a & ~3u;
    if (aligned != g_lw_addr) {
        g_lw_addr = aligned;
        g_lw_data = mem_r32(aligned);
        printf("BUS R %08x %08x fc=", aligned, g_lw_data); print_fc(); printf(" siz=10\n");
    }
    return (a & 2) ? (g_lw_data & 0xFFFF) : (uint16_t)(g_lw_data >> 16);
}

unsigned int m68k_read_memory_32(unsigned int a) {
    uint32_t v = mem_r32(a);
    printf("BUS R %08x %08x fc=", a, v); print_fc(); printf(" siz=00\n");
    return v;
}

/* Disassembler reads (used internally, not logged) */
unsigned int m68k_read_disassembler_8(unsigned int a)  { return mem_r8(a); }
unsigned int m68k_read_disassembler_16(unsigned int a) { return mem_r16(a); }
unsigned int m68k_read_disassembler_32(unsigned int a) { return mem_r32(a); }

void m68k_write_memory_8(unsigned int a, unsigned int v) {
    printf("BUS W %08x %02x fc=", a, v); print_fc(); printf(" siz=01\n");
    mem_w8(a, (uint8_t)v);
}
void m68k_write_memory_16(unsigned int a, unsigned int v) {
    printf("BUS W %08x %04x fc=", a, v); print_fc(); printf(" siz=10\n");
    mem_w16(a, (uint16_t)v);
}
void m68k_write_memory_32(unsigned int a, unsigned int v) {
    printf("BUS W %08x %08x fc=", a, v); print_fc(); printf(" siz=00\n");
    mem_w32(a, v);
}

/* ── main ─────────────────────────────────────────────────────────────────── */
int main(int argc, char *argv[]) {
    if (argc < 2) { fprintf(stderr, "usage: %s <file.hex> [max_cycles]\n", argv[0]); return 1; }
    int max_cycles = (argc >= 3) ? atoi(argv[2]) : 300;

    for (int i = 0; i < MEM_WORDS; i++) g_mem[i] = 0x4E714E71u;
    FILE *f = fopen(argv[1], "r");
    if (!f) { perror(argv[1]); return 1; }
    char line[64]; int idx = 0;
    while (fgets(line, sizeof(line), f) && idx < MEM_WORDS) {
        unsigned long v;
        if (sscanf(line, "%lx", &v) == 1) g_mem[idx++] = (uint32_t)v;
    }
    fclose(f);

    m68k_init();
    m68k_set_cpu_type(M68K_CPU_TYPE_68030);
    m68k_set_fc_callback(fc_callback);
    m68k_pulse_reset();
    m68k_execute(max_cycles);
    return 0;
}
