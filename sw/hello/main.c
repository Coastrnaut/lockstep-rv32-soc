/* ============================================================================
 * Hello, world
 * ============================================================================
 * The smallest program for the SoC: both cores, in lockstep, print one line
 * on the UART, then keep the watchdog content. A starting point for a new
 * program: copy this folder, and add it to PROGRAMS in sw/build.py.
 *
 *     python sw/build.py
 * ========================================================================== */

#include "soc.h"

int main(void)
{
    uart_puts("Hello, world!\r\n");

    for (;;) {
        wd_kick_in_window();
    }
}
