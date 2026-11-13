/* ============================================================================
 * The Arty A7-100T board program (roadmap R3.3)
 * ============================================================================
 * Both cores run it, in lockstep, from boot mode 2:
 *
 *   1. Print "LS" and RESET_SRC as a digit on the UART: 0 after a cold start,
 *      1 after an early kick, 2 after a timeout.
 *   2. Wait for the watchdog window to open, kick, wait for the kick to land,
 *      and print "." for each kick, for ever.
 *
 * On a bench this shows reset release, the first instructions, the watchdog
 * window and a running program, on the UART alone. The addresses come from
 * sw/include/lockstep_soc_regs.h, which tools/register_map.py generates from
 * the same table as the RTL's. Build it with:
 *
 *     python sw/build.py
 * ========================================================================== */

#include <stdint.h>

#include "lockstep_soc_regs.h"

#define REG(address) (*(volatile uint32_t *)(address))

/* WD_STATUS 4:0 is counter 15:11, so 20 means the counter is past 40960: the
 * kick window (HSI WD-01) is open */
#define WD_WINDOW_OPEN 20u

/* Access faults taken since the start (start.S) */
volatile uint32_t trap_count;

static void uart_put(char c)
{
    while ((REG(LOCKSTEP_UART_STATUS) & 1u) != 0u) {
    }
    REG(LOCKSTEP_UART_TX_DATA) = (uint32_t)(unsigned char)c;
}

static uint32_t wd_phase(void)
{
    return REG(LOCKSTEP_WD_STATUS) & 0x1Fu;
}

int main(void)
{
    uart_put('L');
    uart_put('S');
    uart_put((char)('0' + REG(LOCKSTEP_WD_RESET_SRC)));

    for (;;) {
        while (wd_phase() != WD_WINDOW_OPEN) {
        }
        REG(LOCKSTEP_WD_KICK) = LOCKSTEP_WD_KICK_KEY;
        while (wd_phase() == WD_WINDOW_OPEN) {
        }
        uart_put('.');
    }
}
