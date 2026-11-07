# ============================================================================
# lockstep-rv32-soc HSI Specification
# ============================================================================
# ISO 26262 Part 4: Hardware Safety Requirements Specification
# Document ID: HSI-LRS-001
# Revision: 1.0
# ============================================================================

## 1. SCOPE & APPLICABILITY

### 1.1 System Overview
The lockstep-rv32-soc dual-core lockstep SoC is designed for automotive safety-critical
control units targeting **ASIL-D** per ISO 26262-6. It provides a hardware-
hardened computational core for steer-by-wire, brake-by-wire, and autonomous
safety-gate monitors.

### 1.2 Item Definition
The item is the **lockstep-rv32-soc** hardware platform comprising:
- Dual NEORV32 RISC-V cores (cycle-accurate lockstep)
- Lockstep comparator with NMI within 2 clock cycles
- SECDED Hamming ECC on all memory buses
- Windowed hardware watchdog on isolated RC oscillator
- Fault-hardened CAN 2.0B controller
- Parity-protected diagnostic UART

### 1.3 Operational Profile
| Parameter          | Value                    |
|--------------------|--------------------------|
| Operating voltage  | 3.3V ±5%                |
| Operating temp     | -40°C to +125°C         |
| Clock frequency    | 50 MHz (primary)        |
| Watchdog clock     | Independent RC oscillator |
| Fault response     | < 2 clock cycles        |
| Memory protection  | SECDED (72,64) Hamming  |

---

## 2. HARDWARE SAFETY REQUIREMENTS

### 2.1 Lockstep Comparator (ASIL-D)

| Req ID             | Requirement                                                    | ASIL |
|--------------------|----------------------------------------------------------------|------|
| HSR_LOCKSTEP_001   | Dual cores shall execute identical instructions cycle-by-cycle | D    |
| HSR_LOCKSTEP_002   | Comparator shall detect bus mismatch within 1 clock cycle      | D    |
| HSR_LOCKSTEP_003   | NMI shall assert within 2 clock cycles of mismatch             | D    |
| HSR_LOCKSTEP_004   | Once fault tripped, system shall remain latched until reset     | D    |
| HSR_LOCKSTEP_005   | System bus shall be isolated on fault (valid deasserted)       | D    |

### 2.2 ECC Memory Protection (ASIL-D)

| Req ID             | Requirement                                                    | ASIL |
|--------------------|----------------------------------------------------------------|------|
| HSR_ECC_001        | All memory buses shall use SECDED Hamming (72,64)              | D    |
| HSR_ECC_002        | Single-bit errors shall be corrected transparently             | D    |
| HSR_ECC_003        | Double-bit errors shall be flagged as fatal (no correction)    | D    |
| HSR_ECC_004        | Syndrome decoder shall detect errors on every read cycle       | D    |

### 2.3 Watchdog Timer (ASIL-D)

| Req ID             | Requirement                                                    | ASIL |
|--------------------|----------------------------------------------------------------|------|
| HSR_WD_001         | Watchdog shall run on independent clock source                 | D    |
| HSR_WD_002         | Kick window: early kicks shall trigger reset                   | D    |
| HSR_WD_003         | Kick window: late kicks (timeout) shall trigger reset          | D    |
| HSR_WD_004         | Watchdog counter shall be 16-bit with configurable min/max     | D    |

### 2.4 Safety-Gated Peripherals (ASIL-D)

| Req ID             | Requirement                                                    | ASIL |
|--------------------|----------------------------------------------------------------|------|
| HSR_CAN_001        | CAN TX shall be gated by lockstep comparator output            | D    |
| HSR_CAN_002        | CAN TX shall force recessive when safety gate drops            | D    |
| HSR_UART_001       | UART TX shall verify parity before transmission                | D    |
| HSR_UART_002       | UART shall flag error on parity mismatch                       | D    |

---

## 3. REGISTER MAP

### 3.1 Lockstep Comparator Registers

| Offset | Name          | R/W | Description                          |
|--------|---------------|-----|--------------------------------------|
| 0x00   | STATUS        | R   | Fault status (bit 0 = NMI latched)   |
| 0x04   | CORE_A_VALID  | R   | Core A bus validity                  |
| 0x08   | CORE_B_VALID  | R   | Core B bus validity                  |
| 0x0C   | SAFE_STATE    | R   | Safe state encoding                  |

### 3.2 ECC Controller Registers

| Offset | Name          | R/W | Description                          |
|--------|---------------|-----|--------------------------------------|
| 0x00   | SBE_COUNT     | R   | Single-bit error count               |
| 0x04   | DBE_COUNT     | R   | Double-bit error count               |
| 0x08   | SYNDROME      | R   | Last syndrome value                  |
| 0x0C   | STATUS        | R   | ECC status (0=no err, 1=SBE, 2=DBE)  |

### 3.3 Watchdog Registers

| Offset | Name          | R/W | Description                          |
|--------|---------------|-----|--------------------------------------|
| 0x00   | KICK          | W   | Write 0x0000DEAD to kick watchdog    |
| 0x04   | STATUS        | R   | Watchdog status and counter          |
| 0x08   | RESET_SRC     | R   | Why the watchdog last reset the SoC  |

Only a word store of exactly that value to KICK counts, and any other write does
nothing. A kick has to land between 40,000 and 50,000 watchdog clocks after the
one before it, or after the reset for the first one. Too early or too late and
the watchdog resets the SoC. Kicks take a few watchdog clocks to arrive, and one
made while another is still on its way counts as the same kick.

STATUS and RESET_SRC are copies a few watchdog clocks old. If STATUS stops
changing, the oscillator has stopped: the watchdog cannot act, and software has
to treat that as a fault.

### 3.4 CAN Controller Registers

| Offset | Name          | R/W | Description                          |
|--------|---------------|-----|--------------------------------------|
| 0x00   | MAILBOX_ID    | RW  | CAN frame ID (11-bit)               |
| 0x04   | MAILBOX_DLC   | RW  | Data length code                     |
| 0x08   | MAILBOX_DATA  | RW  | Data bytes 0-3, byte 0 in bits 31:24 |
| 0x0C   | STATUS        | RW  | Error counter and state, busy. A word write clears the interrupt |
| 0x10   | MAILBOX_DATA_HI | RW | Data bytes 4-7, byte 4 in bits 31:24 |
| 0x14   | TX_REQUEST    | W   | Any write sends the mailbox's frame  |

The mailbox registers are locked from TX_REQUEST until the frame has been sent
without error, so that a failed frame is sent again unchanged. They keep their
contents afterwards, so that another TX_REQUEST sends the same frame again. A
drop of the safety gate clears them.

### 3.5 Safe UART Registers

| Offset | Name          | R/W | Description                          |
|--------|---------------|-----|--------------------------------------|
| 0x00   | TX_DATA       | W   | TX data register (8-bit)             |
| 0x04   | STATUS        | RW  | TX busy and error status. A write clears the interrupt |
| 0x08   | PARITY        | R   | Parity check result                  |

---

## 4. INTERRUPT CHANNELS

| IRQ # | Name          | Priority | Description                          |
|-------|---------------|----------|--------------------------------------|
| 0     | NMI_LOCKSTEP  | Highest  | Lockstep comparator fault            |
| 1     | NMI_ECC_DBE   | Highest  | ECC double-bit error (fatal)         |
| 2     | WD_TIMEOUT    | High     | Watchdog timeout                     |
| 3     | CAN_ERROR     | Medium   | A CAN frame failed: bit or ACK error |
| 4     | UART_ERROR    | Low      | UART parity error                    |

Both cores receive these on their RISC-V interrupt lines, whose fixed priority
gives the order above: NMI_LOCKSTEP on MEI, CAN_ERROR on MSI and UART_ERROR on
MTI. NMI_ECC_DBE is not connected, because the ECC wrapper is not in the SoC yet.
WD_TIMEOUT is not an interrupt either: a watchdog violation resets the SoC, as
section 6 describes, and RESET_SRC reports it afterwards. CAN_ERROR and UART_ERROR
stay set until software writes the block's STATUS register, and reading it does
not clear them, so that polling cannot lose an interrupt.

---

## 5. MEMORY MAP

| Base     | Size     | Region               | Protection     |
|----------|----------|----------------------|----------------|
| 0x00000000 | 64K   | Boot ROM             | ECC protected  |
| 0x20000000 | 256K  | SRAM (data)          | ECC protected  |
| 0x40000000 | 4K    | Peripheral registers | No ECC         |
| 0x60000000 | 1M    | Flash (program)      | ECC protected  |

### 5.1 Peripheral Register Window

Each block has 0x100 bytes of the window at 0x40000000:

| Base       | Block               | Decoded in hardware  |
|------------|---------------------|----------------------|
| 0x40000000 | Lockstep comparator | Reserved             |
| 0x40000100 | ECC controller      | Reserved             |
| 0x40000200 | Watchdog            | Offsets 0x00 to 0x08 |
| 0x40000300 | CAN controller      | Offsets 0x00 to 0x14 |
| 0x40000400 | Safe UART           | Offsets 0x00 to 0x08 |

Both peripherals share one bus and act only on a write to exactly their address,
so a write to any other address, including the rest of their 0x100 bytes, does
nothing:

- **CAN:** the registers in section 3.4, up to offset 0x14.
- **UART:** the registers in section 3.5, with the byte for TX_DATA in bits 7:0.

Data for a read is ready in the cycle after the strobe, and any other address
reads zero. These status registers have the following bits:

| Address    | Register    | Bits                                                    |
|------------|-------------|---------------------------------------------------------|
| 0x40000204 | WD STATUS   | 7 = violation held, 6 = early, 5 = late, 4:0 = counter 15:11 |
| 0x40000208 | RESET_SRC   | 1:0 = 0 for no watchdog reset, 1 for early, 2 for late  |
| 0x4000030C | CAN STATUS  | 16:8 = TEC, 3 = interrupt, 2 = bus-off, 1 = error passive, 0 = busy |
| 0x40000404 | UART STATUS | 1 = parity error interrupt, 0 = busy                    |
| 0x40000408 | UART PARITY | 0 = the byte held for transmission has good parity      |

The CAN registers take word stores only, so a byte or halfword store to one of
them does nothing. TX_DATA takes any store that includes byte 0.

---

## 6. STARTUP TIMING

| Phase          | Duration     | Description                          |
|----------------|--------------|--------------------------------------|
| Power-on reset | 1024 clk     | Global reset deassertion             |
| Reset release  | 4 clk        | Rising edges before w_rst_n rises    |
| Lockstep init  | 2 clk        | Comparator self-test                 |
| ECC init       | 1 clk        | Parity generator self-test           |
| Watchdog start | Immediate    | WD counter begins on first clock     |
| Total boot     | 1031 clk     | System ready at ~20.6 µs @ 50 MHz    |

A reset takes effect at once, even with the clock stopped: `can_tx_o` goes
recessive and `actuator_safe_o` goes high. A pulse of any length restarts the
whole SoC, and `actuator_safe_o` stays high until the reset has been released.

There are two kinds of reset. A cold reset comes from the `rst_n_i` pin and clears
everything. A watchdog reset lasts 16 watchdog clocks and restarts both cores, the
CAN controller, the UART and the watchdog's counter, but it leaves two things
alone: RESET_SRC, which cold starts clear, and the lockstep comparator, so a
tripped comparator stays tripped until a cold reset.

The watchdog runs from `wd_clk_i` alone. If `clk_i` stops, it still times out and
makes the SoC safe, and it stays that way, because a reset needs clock edges to be
released. Nothing can turn the watchdog off, so software has to start kicking it.

---

## 7. SAFETY GOALS

| SG ID | Safety Goal                              | ASIL |
|-------|------------------------------------------|------|
| SG-01 | Prevent unintended vehicle motion        | D    |
| SG-02 | Detect computational divergence          | D    |
| SG-03 | Detect memory corruption                 | D    |
| SG-04 | Detect software lockup                   | D    |
| SG-05 | Ensure fault-free communication          | D    |
