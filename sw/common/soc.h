/* ============================================================================
 * Small helpers shared by the programs in sw/
 * ============================================================================
 * Register access, the UART and the watchdog, on the addresses that
 * tools/register_map.py generates into lockstep_soc_regs.h from the same
 * table as the RTL's.
 * ========================================================================== */

#ifndef LOCKSTEP_SOC_H
#define LOCKSTEP_SOC_H

#include <stdint.h>

#include "lockstep_soc_regs.h"

#define REG(address) (*(volatile uint32_t *)(address))

/* WD_STATUS 4:0 is counter 15:11, so 20 means the counter is past 40960: the
 * kick window (HSI WD-01) is open */
#define WD_WINDOW_OPEN 20u

/* Access faults taken since the start, counted by start.S */
extern volatile uint32_t trap_count;

static inline void uart_put(char c)
{
    while ((REG(LOCKSTEP_UART_STATUS) & 1u) != 0u) {
    }
    REG(LOCKSTEP_UART_TX_DATA) = (uint32_t)(unsigned char)c;
}

static inline void uart_puts(const char *s)
{
    while (*s != '\0') {
        uart_put(*s);
        s++;
    }
}

static inline uint32_t wd_phase(void)
{
    return REG(LOCKSTEP_WD_STATUS) & 0x1Fu;
}

/* Wait for the window, kick once, and wait for the kick to land */
static inline void wd_kick_in_window(void)
{
    while (wd_phase() != WD_WINDOW_OPEN) {
    }
    REG(LOCKSTEP_WD_KICK) = LOCKSTEP_WD_KICK_KEY;
    while (wd_phase() == WD_WINDOW_OPEN) {
    }
}

#endif
