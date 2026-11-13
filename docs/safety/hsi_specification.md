# ============================================================================
# lockstep-rv32-soc HSI Specification
# ============================================================================
# ISO 26262 Part 4: Hardware Safety Requirements Specification
# Document ID: HSI-LRS-001
# Revision: 1.2 (1.1 added section 8, the bus and safe-output contract;
#           1.2 adds section 8.5, ECC repair and telemetry)
# ============================================================================

Sections 1 to 7 keep the revision 1.0 requirements. Where they disagree with
section 8, section 8 is the implemented contract and the earlier text records
intent.

## 1. SCOPE & APPLICABILITY

### 1.1 System Overview
The lockstep-rv32-soc dual-core lockstep SoC is designed towards automotive
safety-critical control units, with **ASIL-D** as the design intent. No ASIL has
been assessed. The evidence that exists is simulation evidence, listed in
`docs/verification/milestone_0_1.md`. It provides a hardware-
hardened computational core for steer-by-wire, brake-by-wire, and autonomous
safety-gate monitors.

### 1.2 Item Definition
The item is the **lockstep-rv32-soc** hardware platform comprising:
- Dual NEORV32 RISC-V cores (cycle-accurate lockstep)
- Lockstep comparator with a hardware fault pin (`nmi_fault_o`) within 2 clock cycles
- SECDED Hamming ECC on the shared data RAM (the instruction memories have none, section 5)
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
| HSR_LOCKSTEP_001   | Core B shall execute what core A does, exactly 2 clocks later  | D    |
| HSR_LOCKSTEP_002   | Comparator shall detect bus mismatch within 1 clock cycle      | D    |
| HSR_LOCKSTEP_003   | NMI shall assert within 2 clock cycles of mismatch             | D    |
| HSR_LOCKSTEP_004   | Once fault tripped, system shall remain latched until reset     | D    |
| HSR_LOCKSTEP_005   | System bus shall be isolated on fault (valid deasserted)       | D    |
| HSR_LOCKSTEP_006   | A glitch on both cores shall not change both the same way      | D    |
| HSR_LOCKSTEP_007   | Cores shall not start unless the comparator passes a self-test | D    |

Core B runs two clocks behind core A. Reset, read data, the bus acknowledge and
the interrupts all reach it two clocks late, so it is an exact copy of core A at
an earlier moment, and a glitch that hits both at once finds them at different
points in the program. Core A's bus waits two clocks to meet core B's at the
comparator, and goes on to the system bus from there.

Nothing leaves the cores before it has been compared. A bus cycle found bad stops
in that same cycle, so a store that the cores disagree on never reaches a
peripheral. `bus_valid_o` moves a clock later, because it reaches the CAN pin and
the compare can glitch.

The latencies above count from the comparator, as the verification specification
does. From core A's pins, a fault takes two clocks longer to reach it. Every load
and store now keeps a core waiting 3 clocks rather than 1.

The delay protects against a glitch of up to two clocks on both cores. It cannot
help with a fault in data they share. A wrong value upstream of core B's delay
line reaches both cores the same way, which is why the RAM has its own ECC.

The comparator tests itself after every cold reset, with the cores in reset. It
flips each of the 70 bits of the compare in turn, and then raises the fatal fault
input, and each time checks that it trips, that the trip holds once the cause has
gone, and that a reset clears it. If any of that fails, the cores never start,
`actuator_safe_o` stays high and `nmi_fault_o` goes high. A watchdog reset does
not repeat the test. A fault that appears in the comparator after the test stays
hidden until the next cold reset, so that is the latent fault interval.

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

**Planned, not implemented.** The block at 0x40000000 is reserved, and an access
to it ends in ERR (section 8.1, BUS-08).

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
| 0x10   | FIRST_INFO    | R   | First error: 31 valid, 9:8 cause, 7:0 syndrome |
| 0x14   | FIRST_ADDR    | R   | First error: address of its 64-bit word |
| 0x18   | FIRST_TIME    | R   | First error: clocks since cold reset |
| 0x1C   | PATROL        | R   | 31:16 completed patrol passes, 0 the patrol found an uncorrectable word |

SBE_COUNT and DBE_COUNT count in bits 15:0 and stop at 0xFFFF. SYNDROME holds bit
7 set if parity failed, and in bits 6:0 the position of the flipped bit. STATUS
keeps the worst error seen. Only a cold reset clears them, so they outlast a
watchdog reset. A double-bit error shuts the bus, as section 4 describes, so
software cannot read these registers afterwards; the diagnostic port of section
8.5 can.

Offsets 0x10 to 0x1C are revision 1.2 (section 8.5). SBE_COUNT counts single-bit
errors found by an access or by the patrol. DBE_COUNT and STATUS count only
accesses; an uncorrectable word the patrol finds sets PATROL bit 0 instead. The
FIRST_INFO causes are 0 a single-bit error found by an access, 1 one found by the
patrol, 2 an uncorrectable word found by an access, 3 one found by the patrol.
FIRST_TIME counts from the cold reset in 32 bits and wraps after about 86 s at
50 MHz.

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
| 0x18   | RX_ID         | R   | Received identifier, 11 or 29 bits   |
| 0x1C   | RX_INFO       | R   | 5 = extended, 4 = remote, 3:0 = DLC  |
| 0x20   | RX_DATA       | R   | Data bytes 0-3, byte 0 in bits 31:24 |
| 0x24   | RX_DATA_HI    | R   | Data bytes 4-7, byte 4 in bits 31:24 |
| 0x28   | RX_STATUS     | RW  | 1 = overrun, 0 = frame waiting. A word write releases the frame |
| 0x2C   | RX_IRQ_EN     | RW  | 0 = a waiting frame raises CAN_ERROR's line |

The mailbox registers are locked from TX_REQUEST until the frame has been sent
without error, so that a failed frame is sent again unchanged. They keep their
contents afterwards, so that another TX_REQUEST sends the same frame again. A
drop of the safety gate clears them.

The controller receives and acknowledges every good frame on the bus, base or
extended, data or remote, whatever its identifier: there is no acceptance filter.
The receive registers hold one frame, and keep it until a word write to RX_STATUS
releases it. Reading does not. A frame that arrives while one is waiting is still
acknowledged, but it is dropped and RX_STATUS shows the overrun, so that the frame
software is reading cannot change under it.

Reception follows ISO 11898-1. A stuff, CRC or form error, or an ACK of its own
that does not reach the bus, makes the node send an error flag, recessive if it is
error passive. The receive error counter in STATUS adds 1 for the error, and 8 if
the bus is dominant straight after the flag, and it stops at 255. A good frame
takes away 1, and brings it back to 127 from anything above that. The node is
error passive once either counter reaches 128. It hard-synchronises on a SOF, and
within a frame it follows each recessive to dominant edge by up to 1/8 of a bit,
so it can follow a sender 1.5% away from its own bit rate. It does not send
overload frames, but an overload flag from another node just puts off the next
frame. A safety gate drop or bus-off stops reception and keeps the node off the
bus, and neither ACKs nor flags go out.

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

The names are historical: none of these is a RISC-V NMI. MEI is a maskable
notification, and containment never depends on it (section 8.2, FLT-02).

Both cores receive these on their RISC-V interrupt lines, whose fixed priority
gives the order above: NMI_LOCKSTEP on MEI, CAN_ERROR on MSI and UART_ERROR on
MTI. A received frame has no line of its own, because all three RISC-V lines are
taken. It shares MSI with CAN_ERROR if RX_IRQ_EN is set, and it is off otherwise,
so a handler has to look at RX_STATUS and release any frame it finds, or the line
stays up. NMI_ECC_DBE shares MEI with NMI_LOCKSTEP, because a double-bit error trips
the same latch in the comparator: the bus shuts and `actuator_safe_o` goes high
until a cold reset. Both cores read the same word from the RAM, so they would not
disagree about it. WD_TIMEOUT is not an interrupt: a watchdog violation resets
the SoC, as section 6 describes, and RESET_SRC reports it afterwards. CAN_ERROR
and UART_ERROR stay set until software writes the block's STATUS register, and
reading it does not clear them, so that polling cannot lose an interrupt.

---

## 5. MEMORY MAP

| Base     | Size     | Region               | Protection     | Implemented |
|----------|----------|----------------------|----------------|-------------|
| 0x00000000 | 64K   | Boot ROM             | ECC protected  | No: each core's NEORV32 IMEM, 16 KB, no ECC, outside the compared bus |
| 0x20000000 | 256K  | SRAM (data)          | ECC protected  | Yes |
| 0x40000000 | 4K    | Peripheral registers | No ECC         | Yes, the registers of section 5.1; the rest answers ERR |
| 0x60000000 | 1M    | Flash (program)      | ECC protected  | No; an access answers ERR |

The SoC implements the SRAM, on the system bus behind the comparator, so both
cores share it and every load and store is compared. Each word is 64 data bits
and 8 check bits, and every store is a read-modify-write, written the clock after
the strobe, so a store the cores disagree on never lands. It takes byte, halfword
and word stores, and answers in the cycle after the strobe, like the peripherals.
The Boot ROM above is NEORV32's IMEM for now, 16 KB in each core with no ECC. An
upset there makes the cores disagree, so the comparator catches it rather than
the ECC correcting it. There is no Flash yet.

The SRAM starts as zeros on an FPGA, and zeros are valid words. An ASIC would have
to clear it before use.

### 5.1 Peripheral Register Window

Each block has 0x100 bytes of the window at 0x40000000:

| Base       | Block               | Decoded in hardware  |
|------------|---------------------|----------------------|
| 0x40000000 | Lockstep comparator | Reserved             |
| 0x40000100 | ECC controller      | Offsets 0x00 to 0x1C |
| 0x40000200 | Watchdog            | Offsets 0x00 to 0x08 |
| 0x40000300 | CAN controller      | Offsets 0x00 to 0x2C |
| 0x40000400 | Safe UART           | Offsets 0x00 to 0x08 |

Both peripherals share one bus and act only on a write to exactly their address,
so a write to any other address, including the rest of their 0x100 bytes, does
nothing:

- **CAN:** the registers in section 3.4, up to offset 0x2C.
- **UART:** the registers in section 3.5, with the byte for TX_DATA in bits 7:0.

Data for a read is ready in the cycle after the strobe. An address in the
window that is not a register answers ERR (section 8.1, BUS-08; revision 1.0 read
it as zero). These status registers have the following bits:

| Address    | Register    | Bits                                                    |
|------------|-------------|---------------------------------------------------------|
| 0x40000204 | WD STATUS   | 7 = violation held, 6 = early, 5 = late, 4:0 = counter 15:11 |
| 0x40000208 | RESET_SRC   | 1:0 = 0 for no watchdog reset, 1 for early, 2 for late  |
| 0x4000030C | CAN STATUS  | 31:24 = REC, 16:8 = TEC, 3 = interrupt, 2 = bus-off, 1 = error passive, 0 = busy |
| 0x40000404 | UART STATUS | 1 = parity error interrupt, 0 = busy                    |
| 0x40000408 | UART PARITY | 0 = the byte held for transmission has good parity      |

The CAN registers take word stores only, so a byte or halfword store to one of
them does nothing. TX_DATA takes any store that includes byte 0.

---

## 6. STARTUP TIMING

| Phase          | Duration     | Description                          |
|----------------|--------------|--------------------------------------|
| Power-on reset | 1024 clk     | Global reset deassertion. **Not in RTL**: the reset is as long as the `rst_n_i` pulse |
| Reset release  | 4 clk        | Rising edges before w_rst_n rises    |
| Lockstep init  | 288 clk      | Comparator self-test                 |
| ECC init       | 1 clk        | Parity generator self-test. **Not in RTL** |
| Watchdog start | Immediate    | WD counter begins on first clock     |
| Total boot     | 1317 clk     | System ready at ~26.3 µs @ 50 MHz. **Planned**: without the power-on stretch, the cores start about 300 clocks after the pin |

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

---

## 8. BUS, RESPONSE AND SAFE-OUTPUT CONTRACT (REVISION 1.1)

This section fixes the observable behaviour that milestone 1 of
`docs/ROADMAP.md` implements and tests. It keeps every address constant, the
CAN and UART wire formats, the two-clock core offset and the behaviour of every
mapped register. The decisions marked **changed** differ from revision 1.0.

### 8.1 Request and response

Edges are rising edges of `clk_i`. "Core A's request" is core A's XBus request
after the two-clock delay that aligns it with core B's at the comparator.

| ID | Decision |
|----|----------|
| BUS-01 | **Acceptance edge.** A request is accepted at the edge where the gated system bus carries `valid = 1`. That needs core A's delayed request to equal core B's in address, data, byte enables, write enable and strobe, the comparator state to be `SYSTEM_OK`, no trip in that cycle (mismatch, fatal input or illegal state), and the warm reset `w_rst_n` released. |
| BUS-02 | **Selected slave.** The fabric decodes the accepted address at the acceptance edge and registers it with the request. Targets are the RAM block (SRAM `0x20000000`–`0x2003FFFF` and the ECC register words `0x40000100`–`0x4000011C`), the watchdog (`0x40000200`–`0x40000208`), CAN (`0x40000300`–`0x4000032C`), the UART (`0x40000400`–`0x40000408`), or none. Register targets compare address bits 31:2 with a register's word address. |
| BUS-03 | **Response edge.** The response is driven in the cycle after acceptance and sampled by core A at the next edge. It is one record of read data, ACK and ERR, taken from the selected target only, and replaces the OR of every slave's read data. Core B receives the same record two clocks later through the temporal-diversity delay line. |
| BUS-04 | **ACK/ERR exclusivity.** Every accepted request gets exactly one response cycle, with exactly one of ACK or ERR. Read data is zero with ERR and for any store. |
| BUS-05 | **Write commit.** CAN, UART and watchdog registers commit a store at the acceptance edge. The RAM reads the word at the acceptance edge and commits the merged word at the response edge, only if that word has no uncorrectable error, the comparator gate is still open and the warm reset is still released. |
| BUS-06 | **Byte lanes.** Byte enables pass unchanged to the slaves. The RAM merges only the enabled lanes. The CAN registers take word stores only, so a byte or halfword store to one of them, including the byte store to TX_REQUEST in the smoke firmware, is acknowledged and does nothing. TX_DATA takes any store that enables byte 0. KICK takes only a word store of `0x0000DEAD`. Loads return the whole word and the core selects lanes. |
| BUS-07 | **Register directions.** A mapped address is always acknowledged. Reading a write-only register (KICK, TX_REQUEST, TX_DATA) returns zero. Writing a read-only register (ECC registers, watchdog STATUS and RESET_SRC, CAN RX registers) does nothing. |
| BUS-08 | **Address holes. Changed.** An accepted request to any other external address gets ERR in its response cycle and has no side effect. This covers the reserved comparator block `0x40000000`–`0x400000FF`, unused offsets in each block, the rest of the peripheral window, addresses next to the SRAM and aliases that differ from a mapped address in any of bits 31:2. Revision 1.0 answered these with ACK and zero. The pinned NEORV32 turns ERR into a load or store access fault (`mcause` 5 or 7) and does not write the destination register. |
| BUS-09 | **Fatal RAM response.** A double-bit error in the response cycle of an accepted RAM load or store makes that response ERR with zero data, and the RAM writes nothing. The same cycle trips the comparator, so no later request is accepted. Single-bit errors return corrected data with ACK, as before. |
| BUS-10 | **Denied requests.** A request that is not accepted reaches no slave and gets no response from the fabric. The core's own XBus timeout (2048 clocks in the pinned configuration) ends it with an access fault. Containment never depends on that. |
| BUS-11 | **Warm reset.** A watchdog reset or a cold reset clears the transaction state, which is the pending response and the RAM's pending read-modify-write. A store whose commit edge falls in a reset is dropped and nothing answers it. The ECC counters, SYNDROME, STATUS and RESET_SRC are cleared only by a cold reset. |
| BUS-12 | **CYC, CTI and TAG.** These are neither compared nor forwarded. With the A extension and the caches disabled, NEORV32 issues only single accesses, so the fabric treats every strobe as one. |

### 8.2 Fault indication and interrupts

| ID | Decision |
|----|----------|
| FLT-01 | **`nmi_fault_o` keeps its name.** It is the external fault indication pin, driven by hardware, and is not a RISC-V NMI. **Changed:** it now comes from the comparator's registered fault state, so comparator settling cannot glitch the pin. It rises at the first edge after a trip is detected, within the two clocks of HSR_LOCKSTEP_003. The self-test still checks the comparator's combinational trip in its own cycle. |
| FLT-02 | **MEI is a maskable notification.** The same registered fault reaches both cores as the machine external interrupt, core B two clocks after core A. Software may mask it with `mstatus.MIE` or `mie.MEIE`. Bus isolation, `actuator_safe_o`, `nmi_fault_o` and the CAN and UART pins never depend on an interrupt being taken, a trap handler or any MMIO access. |
| FLT-03 | **Illegal comparator state. Changed.** Any value of the comparator's state register other than `0x5A` (`SYSTEM_OK`) or `0xA5` (`FAULT_TRIPPED`) is a fault. So is a set fault latch with a healthy state, which moves the state to `FAULT_TRIPPED` at the next edge, and either register on its own is enough to report the fault (found by the formal proof, `docs/verification/formal.md`). The bus closes at once, the fault latches, and the next edge moves the state to `FAULT_TRIPPED`. Revision 1.0 closed the bus and later made the actuators safe without ever raising `nmi_fault_o`. |
| FLT-04 | **Sticky until cold reset.** A latched fault survives a watchdog reset. Only a cold reset clears it, after which the startup self-test qualifies the comparator again before the cores start. |

### 8.3 Safe outputs

`actuator_safe_o` high, `can_tx_o` recessive and `uart_tx_o` at mark are the
safe output levels.

| Condition | `actuator_safe_o` | `nmi_fault_o` | `can_tx_o` | `uart_tx_o` | Cores and system bus | Ends with |
|-----------|-------------------|---------------|------------|-------------|----------------------|-----------|
| Cold reset pin low, with or without `clk_i` | 1 at once | 0 from the first clock edge. The comparator resets synchronously, so with `clk_i` stopped the pin keeps its last value | Recessive at once | Mark at once | Cores in reset | Pin release, then the self-test |
| Startup self-test running | 1 | 0 | Recessive | Mark | Cores in reset | Self-test pass |
| Self-test failed | 1 | 1 | Recessive | Mark | Cores never start | Cold reset |
| Normal operation | 0 | 0 | Traffic | Traffic | Open | |
| Lockstep mismatch or double-bit error | 1 from the edge after detection | 1 from the same edge | Recessive from that edge. The mailbox clears and the frame cannot resume. | **Changed:** mark from that edge. The byte in progress and any pending byte are discarded. | Closed from the detection cycle. Later requests are denied. | Cold reset only |
| Illegal comparator state | 1 at once | 1 at once, from the state register | Recessive at once | Mark at once, byte discarded | Closed at once | Cold reset only |
| Watchdog reset | 1 during the 16-clock pulse and until the reset is released | Keeps a latched fault | Recessive | Mark, byte discarded | Cores reset, comparator kept | Pulse end. A latched fault stays. |

A reset asserts asynchronously and holds the CAN and UART pins safe without a
system clock. A lockstep trip needs system clock edges, because the comparator
is synchronous. A stopped system clock is caught by the watchdog, which resets
the SoC from `wd_clk_i` alone and keeps the outputs safe while the clock stays
stopped.

### 8.4 Watchdog window

| ID | Decision |
|----|----------|
| WD-01 | **Inclusive window. Changed.** The counter counts watchdog clocks since the last accepted kick or watchdog restart. A kick is decided at the watchdog clock edge that samples the synchronised kick pulse, by the counter value at that edge. A kick sampled at a count from 40,000 to 50,000 inclusive is accepted and restarts the count. One sampled below 40,000 is early. With no kick, the count reaching 50,000 is the timeout. The counter and the supervisor take the same decision at the same edge. Revision 1.0 let the supervisor see a timeout at 50,000 while the counter accepted the kick. |
| WD-02 | **Duplicate kicks.** A kick made while an earlier one is still crossing to the watchdog clock counts as the same kick. |
| WD-03 | **Reset cause.** RESET_SRC is 1 after an early kick and 2 after a timeout. Its copy on the system side is valid before the 16-clock reset pulse ends, and only a cold reset clears it. |
| ACT-01 | **Two actuator channels.** `actuator_safe_o` (high: safe) and `actuator_en_o` (high: may be powered) are of opposite polarity; the actuator may be powered only while `actuator_en_o` is high and `actuator_safe_o` is low. `actuator_en_o` is low in any reset, without a clock, and on any trip or read-back fault (TSR_ACTUATOR_001). |
| ACT-02 | **Read-back.** `actuator_fb_i` is `actuator_safe_o` as the actuator's driver sees it. After two clocks of synchronising, it must match the command delayed as long, within 8 clocks; otherwise the comparators trip and the fault holds until a cold reset. An open line on the Arty reads safe (pull-up), and so faults when the actuator is released. |
| WD-04 | **Absent watchdog clock. Open assumption.** If `wd_clk_i` never runs, the SoC still starts and runs, but has no watchdog. If it stops later, the watchdog stops and STATUS stops changing. Containment of a lost watchdog clock needs an independent supervisor on the board, which is a target requirement that is not met here. |

### 8.5 ECC repair and telemetry (revision 1.2)

Roadmap R4.1. Evidence: `docs/verification/memory_protection.md`.

| ID | Decision |
|----|----------|
| ECC-05 | **Writeback.** A load that finds a single-bit error returns the corrected data and writes the corrected word back in its response cycle, so the error does not stay in the RAM. A store already writes back the corrected word it merges into. |
| ECC-06 | **Patrol.** In every clock without a RAM strobe, out of cold reset, the RAM reads the next word in turn and, if it holds a single-bit error, writes it back corrected in the next clock. It counts the error in SBE_COUNT. An uncorrectable word it finds sets PATROL bit 0 and the first-fault record, and is not reported on `dbe_fatal_o`: nothing has used it, and an access that does trips as in section 8.2. A pass over the 256 KB RAM takes 32,768 idle clocks, 0.66 ms at 50 MHz, and at most 65,536 clocks, 1.31 ms, under back-to-back core accesses, which leave every other clock idle. |
| ECC-07 | **Arbitration.** A bus access always has the RAM's read port, so the patrol never delays an access or changes its response cycle. A patrol write can meet a bus read of the same word in one clock; both see a correctable word with the same corrected data. |
| ECC-08 | **First-fault telemetry and diagnostic port.** The first error since cold reset is kept with its cause, word address, syndrome and time, and later errors do not replace it. A warm reset keeps it. A read-only SPI port on its own pins (`diag_cs_n_i`, `diag_sck_i`, `diag_sdo_o`; mode 0, at most a tenth of `clk_i`) shifts out FIRST_INFO, FIRST_ADDR, FIRST_TIME, PATROL and the two counts, 160 bits, most significant first, from a snapshot taken when chip select falls. It does not use the system bus and can write nothing, so it works with the bus shut by a fault without reopening it. |

### 8.6 Read data parity (revision 1.3)

Roadmap R2.3. Both cores read the same data, so a fault in it after the slave
reaches both the same way and lockstep cannot see it. The fault campaign showed
it: a bit of the shared response stuck from one response on corrupted the
outputs, and nothing in the SoC noticed (`docs/verification/fault_campaign.md`).
The RAM's ECC protects the RAM, not the path from it.

| ID | Decision |
|----|----------|
| PAR-01 | **Parity with the data.** The response carries `rpar`, which makes its read data's parity even in every cycle. The fabric takes it from the addressed slave's own data before the selection, and selects it apart from the data, so the data's selection and everything after it are checked. With no read data, data and `rpar` are 0. |
| PAR-02 | **Checked at each core.** Core A's read data, and core B's copy of it after the two-clock delay line, are each checked against the parity that came with them, in every clock, read or not, so a bit that sticks is found while the bus is idle. A mismatch trips the comparator through its fatal input, as an uncorrectable RAM word does (section 8.2): the bus closes, the fault pin rises at the next edge, and only a cold reset clears it. |
| PAR-03 | **Not covered.** A fault inside a slave before its data reaches the fabric (the RAM has ECC; the register slaves have none), a fault in the fabric's target register, which selects data and parity alike, and an even number of flipped bits. |

