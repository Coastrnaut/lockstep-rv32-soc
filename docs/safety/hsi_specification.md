# ============================================================================
# ASIL-V HSI Specification
# ============================================================================
# ISO 26262 Part 4: Hardware Safety Requirements Specification
# Document ID: HSI-ASIL-V-001
# Revision: 1.0
# ============================================================================

## 1. SCOPE & APPLICABILITY

### 1.1 System Overview
The ASIL-V dual-core lockstep SoC is designed for automotive safety-critical
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
| 0x00   | KICK          | W   | Write 0xDEAD to kick watchdog        |
| 0x04   | STATUS        | R   | Watchdog status and counter          |
| 0x08   | RESET_SRC     | R   | Reset source (early/late/normal)     |

### 3.4 CAN Controller Registers

| Offset | Name          | R/W | Description                          |
|--------|---------------|-----|--------------------------------------|
| 0x00   | MAILBOX_ID    | RW  | CAN frame ID (11-bit)               |
| 0x04   | MAILBOX_DLC   | RW  | Data length code                     |
| 0x08   | MAILBOX_DATA  | RW  | Frame data (up to 8 bytes)           |
| 0x0C   | STATUS        | R   | TX/RX status and error flags         |

### 3.5 Safe UART Registers

| Offset | Name          | R/W | Description                          |
|--------|---------------|-----|--------------------------------------|
| 0x00   | TX_DATA       | W   | TX data register (8-bit)             |
| 0x04   | STATUS        | R   | TX busy and error status             |
| 0x08   | PARITY        | R   | Parity check result                  |

---

## 4. INTERRUPT CHANNELS

| IRQ # | Name          | Priority | Description                          |
|-------|---------------|----------|--------------------------------------|
| 0     | NMI_LOCKSTEP  | Highest  | Lockstep comparator fault            |
| 1     | NMI_ECC_DBE   | Highest  | ECC double-bit error (fatal)         |
| 2     | WD_TIMEOUT    | High     | Watchdog timeout                     |
| 3     | CAN_ERROR     | Medium   | CAN bus error                        |
| 4     | UART_ERROR    | Low      | UART parity error                    |

---

## 5. MEMORY MAP

| Base     | Size     | Region               | Protection     |
|----------|----------|----------------------|----------------|
| 0x00000000 | 64K   | Boot ROM             | ECC protected  |
| 0x20000000 | 256K  | SRAM (data)          | ECC protected  |
| 0x40000000 | 4K    | Peripheral registers | No ECC         |
| 0x60000000 | 1M    | Flash (program)      | ECC protected  |

---

## 6. STARTUP TIMING

| Phase          | Duration     | Description                          |
|----------------|--------------|--------------------------------------|
| Power-on reset | 1024 clk     | Global reset deassertion             |
| Lockstep init  | 2 clk        | Comparator self-test                 |
| ECC init       | 1 clk        | Parity generator self-test           |
| Watchdog start | Immediate    | WD counter begins on first clock     |
| Total boot     | 1027 clk     | System ready at ~20.5 µs @ 50 MHz    |

---

## 7. SAFETY GOALS

| SG ID | Safety Goal                              | ASIL |
|-------|------------------------------------------|------|
| SG-01 | Prevent unintended vehicle motion        | D    |
| SG-02 | Detect computational divergence          | D    |
| SG-03 | Detect memory corruption                 | D    |
| SG-04 | Detect software lockup                   | D    |
| SG-05 | Ensure fault-free communication          | D    |
