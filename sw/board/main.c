/* ============================================================================
 * The Arty A7-100T board program (roadmap R3.3)
 * ============================================================================
 * Both cores run it, in lockstep, from boot mode 2:
 *
 *   1. "LS" and RESET_SRC as a digit: 0 after a cold start, 1 after an early
 *      kick, 2 after a timeout.
 *   2. "E" and the ECC RAM result: a pattern and its complement written to
 *      the RAM and read back, through the comparator, with the error counts:
 *      0 good, 1 read back wrong, 2 corrected errors, 3 an uncorrectable one.
 *   3. "C" and the CAN result: one Classical CAN frame (ID 0x123, "LS"), sent
 *      and waited for: 0 sent with an ACK and no errors, 1 not done in time
 *      or with errors (no other node on the bus, or no transceiver).
 *   4. A watchdog kick and a "." in every window, for ever.
 *
 * On a bench this shows reset release, the first instructions, the RAM, the
 * CAN bus, the watchdog window and a running program, on the UART alone.
 * Build it with:
 *
 *     python sw/build.py
 * ========================================================================== */

#include "soc.h"

#define TEST_WORDS  16u
#define CAN_TIMEOUT 100000u

static char ecc_check(void)
{
    volatile uint32_t *ram = (volatile uint32_t *)(LOCKSTEP_RAM_BASE + 0x100u);
    uint32_t i;
    char result = '0';

    for (i = 0u; i < TEST_WORDS; i++) {
        ram[i] = 0xA5A55A5Au ^ (i * 0x01010101u);
    }
    for (i = 0u; i < TEST_WORDS; i++) {
        if (ram[i] != (0xA5A55A5Au ^ (i * 0x01010101u))) {
            result = '1';
        }
        ram[i] = ~ram[i];
    }
    for (i = 0u; i < TEST_WORDS; i++) {
        if (ram[i] != ~(0xA5A55A5Au ^ (i * 0x01010101u))) {
            result = '1';
        }
    }
    if (result == '0' && REG(LOCKSTEP_ECC_SBE_COUNT) != 0u) {
        result = '2';
    }
    if (REG(LOCKSTEP_ECC_DBE_COUNT) != 0u) {
        result = '3';
    }
    return result;
}

static char can_check(void)
{
    uint32_t wait;

    REG(LOCKSTEP_CAN_ID) = 0x123u;
    REG(LOCKSTEP_CAN_DLC) = 2u;
    REG(LOCKSTEP_CAN_DATA) = ((uint32_t)'L' << 24) | ((uint32_t)'S' << 16);
    REG(LOCKSTEP_CAN_TX_REQUEST) = 1u;

    /* STATUS: 0 busy, 16:8 transmit error count */
    for (wait = 0u; wait < CAN_TIMEOUT; wait++) {
        if ((REG(LOCKSTEP_CAN_STATUS) & 1u) == 0u) {
            break;
        }
    }
    if (wait == CAN_TIMEOUT || (REG(LOCKSTEP_CAN_STATUS) & 0x1FF00u) != 0u) {
        return '1';
    }
    return '0';
}

int main(void)
{
    uart_puts("LS");
    uart_put((char)('0' + REG(LOCKSTEP_WD_RESET_SRC)));
    uart_put('E');
    uart_put(ecc_check());
    uart_put('C');
    uart_put(can_check());

    for (;;) {
        wd_kick_in_window();
        uart_put('.');
    }
}
