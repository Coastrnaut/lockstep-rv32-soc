# Item definition: torque-enable supervisor for an EV traction inverter

Document ID: ITM-LRS-001, revision 1.0, 2026-11-13. Roadmap M5.1.

An ASIL claim needs an item: a function at vehicle level, with its hazards,
its safety goals and the time a fault may take to become one. This repository
is a reference SoC, not a product, so no integrator has given it one. This
document chooses a **reference item**, the one the SoC fits best, and carries
its hazard analysis through to the SoC's requirements. An integrator with a
real item replaces this document with its own; nothing below is a claim about
a vehicle.

## 1. Options considered

| Option | What the SoC would be | Fit | Verdict |
|--------|-----------------------|-----|---------|
| A. Steer-by-wire road-wheel controller | The controller that turns the wheels | Needs **fail-operational** behaviour: steering must continue after a fault. Lockstep is **fail-silent**: it detects and stops | Rejected: needs a second channel that keeps working |
| B. Brake-by-wire controller | The controller that builds braking force | Fail-operational, as A | Rejected, as A |
| C. Electric parking brake (EPB) | Applies and releases the parking brake on CAN command | Fail-silent works, but the safe state depends on the situation: holding a parked car needs the brake, a moving car must not get it | Possible; the safe state needs vehicle-speed logic the SoC does not have |
| D. Generic safety-gate monitor | Gates any actuator enable on CAN | Fits the RTL, but too vague to rate hazards against | Rejected: no hazards to derive |
| **E. Torque-enable supervisor for an EV traction inverter** | Decides whether the inverter's gate drivers may switch, from CAN torque requests; removes torque on any fault (safe torque off) | Fail-silent is right: **no torque is safe** in every driving situation the item covers. The two actuator channels map onto the inverter's two independent gate-driver disable paths. CAN, watchdog and the diagnostic UART all have a role | **Chosen** |

## 2. The item

**Function.** The vehicle's propulsion controller sends torque requests over
CAN. The torque-enable supervisor (this SoC, with its board) checks each
request and permits the traction inverter's gate drivers to switch only while
the request is valid, current, and agrees with its own plausibility checks.
The inverter's own motor-control processor computes the switching; the
supervisor can only allow it or stop it.

**Boundary.**

| Part | Inside the item | Interface on the SoC |
|------|-----------------|----------------------|
| Torque-enable supervisor (this SoC) | Yes | Everything below |
| Gate-driver disable path 1 (pulse block of the high side) | Yes | `actuator_safe_o` (1 = blocked), read back on `actuator_fb_i` |
| Gate-driver disable path 2 (driver supply enable) | Yes | `actuator_en_o` (1 = supplied) |
| Propulsion controller sending torque requests | No (an assumed source) | `can_rx_i`, `can_tx_o` |
| Board supervisor: power, reset, watchdog clock | Yes | `rst_n_i`, `wd_clk_i` |
| External fault indicator to the vehicle | Yes | `nmi_fault_o` |
| Inverter motor-control processor | No | none |

**Operating modes.** Off; start (cold reset, comparator self-test, actuator
line check); run (requests accepted); safe (torque removed, held until a cold
reset).

**Safe state.** No torque: both gate-driver disable paths active
(`actuator_safe_o` = 1, `actuator_en_o` = 0). It is reachable from every
mode and needs nothing from software. The vehicle coasts.

## 3. Hazard analysis and risk assessment

Severity (S), exposure (E) and controllability (C) per ISO 26262-3, rated for
a passenger car. These are the reference item's ratings; an integrator
re-rates them for a real vehicle.

| ID | Malfunction | Situation | Hazardous event | S | E | C | ASIL |
|----|-------------|-----------|-----------------|---|---|---|------|
| H-01 | Torque applied when not requested | Driving in traffic, any speed | Unintended acceleration into other road users | S3 | E4 | C3 | **D** |
| H-02 | Torque applied when not requested | Standing, pedestrians near (car park, crossing) | Vehicle moves off while standing | S3 | E3 | C3 | **C** |
| H-03 | Torque in the wrong direction | Low-speed manoeuvring | Unintended reverse or forward movement | S2 | E3 | C3 | **B** |
| H-04 | Torque higher than requested | Driving | Unintended acceleration, larger than asked | S3 | E4 | C2 | **C** |
| H-05 | Torque removed when requested | Driving, overtaking | Loss of propulsion | S2 | E3 | C1 | **A** |

H-05 is the price of fail-silent behaviour. It is rated, and accepted: the
safe state of every other hazard is H-05's malfunction, and loss of
propulsion is controllable (C1) at the vehicle level.

## 4. Safety goals

| Goal | Statement | ASIL | Safe state | FTTI | Hazards |
|------|-----------|------|------------|------|---------|
| SG-01 | Prevent torque, and so vehicle motion, that the propulsion controller did not request | D | No torque | 100 ms | H-01, H-02, H-04 |
| SG-02 | Detect a computation in the supervisor that has diverged, before it reaches the gate drivers | D | No torque | 100 ms | H-01 to H-04 |
| SG-03 | Detect memory corruption in the supervisor before it is used | D | No torque | 100 ms | H-01 to H-04 |
| SG-04 | Detect a supervisor that has stopped running, or runs at the wrong rate | D | No torque | 100 ms | H-01 to H-04 |
| SG-05 | Detect a corrupted, lost or stale torque request | D | No torque | 100 ms | H-01 to H-04 |

SG-01 to SG-05 are the goals the traceability matrix already uses; this
document gives them their hazards, ASIL, safe state and FTTI. H-03 (B) and
H-05 (A) are covered by the same goals at a lower ASIL, or accepted.

## 5. From the FTTI to the SoC

FTTI is the fault-tolerant time interval: the time from a fault to a
hazardous event if nothing reacts. 100 ms is the reference value for
unintended torque; it is an assumption of this document.

| Path | Detection | Reaction to the safe state | Worst case | Within 100 ms |
|------|-----------|----------------------------|------------|---------------|
| Core divergence (SG-02) | Comparator, the cycle it reaches the bus | Same cycle: bus closed; next clock: both channels | 2 clocks (40 ns) | Yes |
| Comparator failure after start (SG-02) | The other comparator, at the first divergence | As above | 2 clocks after the divergence | Yes |
| Uncorrectable RAM word (SG-03) | ECC, on the access | Comparator trip | 2 clocks | Yes |
| RAM word never read (SG-03) | The patrol, one pass | Comparator trip | One patrol pass (`docs/verification/memory_protection.md`) | Yes, at the measured pass time |
| System clock stopped or wrong (SG-04) | Clock monitor, two windows of 256 watchdog clocks | SoC held in reset, no clock needed | 0.5 ms at 1 MHz; 1.0 ms with CFGMCLK 50 % slow | Yes |
| Software stopped (SG-04) | Watchdog timeout, 50,000 watchdog clocks | SoC reset | 49 ms at 1.016 MHz; **98 ms with CFGMCLK 50 % slow** | Yes, with no margin on the Arty |
| Actuator line stuck (SG-01) | Read-back at the next demand, or at start | Comparator trip; second channel cuts power at once | 10 clocks after the demand | Yes |
| Torque request corrupted or stale (SG-05) | Software: CRC, counter and timeout of the request (AoU-05) | Software stops kicking the watchdog, or requests the safe state | Set by the software's timeout | The integrator's budget |

The watchdog path shows why the board's watchdog clock matters: on the Arty,
CFGMCLK's ±50 % (DS181, Table 66) stretches a 49 ms timeout to 98 ms. A
product needs a watchdog clock from an oscillator of its own with a known
tolerance (AoU-03).

## 6. Assumptions of use

What the SoC needs from the item around it. Each is an open requirement on
the integrator.

| ID | Assumption |
|----|------------|
| AoU-01 | Gate-driver disable path 1 blocks all switching while `actuator_safe_o` is high, and its state is fed back to `actuator_fb_i` from the driver side |
| AoU-02 | Gate-driver disable path 2 removes the drivers' supply while `actuator_en_o` is low, independently of path 1 |
| AoU-03 | `wd_clk_i` comes from an oscillator independent of `clk_i`, with a known tolerance; the clock monitor's tolerances are set from both clocks' |
| AoU-04 | A board supervisor drives `rst_n_i` with a filtered, monitored reset, and watches the watchdog clock (HSI WD-04) |
| AoU-05 | The software checks each torque request's CRC, sequence counter and age (an end-to-end protection profile), and reacts within the FTTI |
| AoU-06 | `nmi_fault_o` reaches a vehicle-level warning |
| AoU-07 | The item is cold-reset at every key-on, so the startup tests (comparator self-test, actuator line check) run once per drive cycle |

## 7. What stays with an integrator

- A real item, rated by the integrator's own HARA, replacing sections 2 to 4.
- The target technology's failure rates for the FMEDA (`docs/safety/fmeda_inputs.csv`).
- The software (AoU-05) and its own safety case.
- The board (AoU-01 to AoU-04) and its hardware metrics.
