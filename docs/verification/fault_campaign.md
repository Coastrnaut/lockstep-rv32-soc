# Fault campaign (roadmap R2.3)

A repeatable campaign of single faults on the running SoC, classified by what
reached the pins. It replaces neither formal proof nor a gate-level campaign:
faults are VHDL `force`s on named RTL signals, one per trial.

## How it runs

```bash
python sim/scripts/fault_campaign.py --per-site 12 --seed 2026     # about 2 minutes on 16 cores
```

1. **Manifest.** The seed draws, for each of 15 sites, a bit, a time between
   20 and 400 µs after reset, a duration, and a kind: flipped, or stuck at 0
   or 1 for the rest of the run. Trial 0 has no fault and is the reference.
   `sim/campaign/<name>/manifest.csv` keeps every draw, so a campaign repeats
   exactly.
2. **Trials.** Each trial is one configuration of
   `sim/testbenches/tb_fault_campaign.vhd`. The bench runs the simulation
   firmware for 700 µs with both trace ports on. Where a site is only used at
   times, such as a register write, an instruction fetch, a store, a bus
   response or a RAM access, the fault waits for its next use, so it meets
   activity. The bench records when `nmi_fault_o` and `actuator_safe_o` rose,
   every UART byte and CAN frame with its time, and when the cores'
   retirements first differed.
3. **Classes.** `results.csv` and `report.md` sort each trial by comparing it
   with the reference:

| Class | Meaning |
|-------|---------|
| Detected in time | `nmi_fault_o` rose within 50 µs of the injection, the provisional SoC fault-response target |
| Detected late | It rose later |
| Undetected, corrupted | No detection, and a UART byte or CAN frame differed from the reference |
| Undetected, missing | No detection, and outputs stopped short |
| Corrected | A single-bit RAM error the ECC corrected: the only difference is the SBE count the firmware prints |
| Latent | Outputs as the reference, but the cores' retirements diverged: the fault was activated and stayed hidden |
| Masked | No effect seen |
| Invalid | No result, or a flip of a bit that held no defined value in simulation |

"Wrong output first" counts detected trials in which a whole wrong byte or
frame left before the fault pin rose. A byte cut short by the safe state does
not count.

## Result: seed 2026, 12 trials per site

GHDL 6.0, 180 trials and the reference, 2 min 13 s on 16 cores. "Detected of
effective" counts detected trials out of those that reached the pins or were
detected.

| Class | Site | In time | Late | Undet. corrupted | Undet. missing | Corrected | Latent | Masked | Invalid | Wrong output first | Detected of effective | Latency µs (min / median / max) |
|-------|------|---|---|---|---|---|---|---|---|---|---|---|
| CPU-private | Core A instruction fetch data, at a fetch | 2 | 0 | 0 | 0 | 0 | 1 | 9 | 0 | 0 | 2 of 2 | 0.16 / 0.21 / 0.26 |
| CPU-private | Core A register write data, at a write | 1 | 0 | 0 | 0 | 0 | 10 | 1 | 0 | 0 | 1 of 1 | 0.18 |
| CPU-private | Core B register write data, at a write | 0 | 0 | 0 | 0 | 0 | 12 | 0 | 0 | 0 | - | - |
| Comparator | Comparator state register | 12 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 12 of 12 | 0.00 |
| Delay line | Core A bus after the delay line, at a store | 12 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 12 of 12 | 0.02 |
| ECC word | RAM word, one bit, at an access | 0 | 0 | 0 | 0 | 3 | 0 | 9 | 0 | 0 | - | - |
| ECC word | RAM word, two bits, at an access | 4 | 0 | 0 | 0 | 0 | 0 | 8 | 0 | 0 | 4 of 4 | 0.02 |
| Output logic | CAN TX bit register | 0 | 0 | 6 | 0 | 0 | 0 | 6 | 0 | 6 | 0 of 6 | - |
| Output logic | UART shift register | 0 | 0 | 3 | 0 | 0 | 0 | 9 | 0 | 3 | 0 of 3 | - |
| Reset | Reset synchroniser stage | 0 | 0 | 12 | 0 | 0 | 0 | 0 | 0 | 12 | 0 of 12 | - |
| Self-test | Self-test result register | 12 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 12 of 12 | 0.00 |
| Shared response | Shared bus response data, at a response | 0 | 0 | 0 | 0 | 0 | 0 | 12 | 0 | 0 | - | - |
| Watchdog | Watchdog counter | 0 | 0 | 0 | 0 | 0 | 0 | 12 | 0 | 0 | - | - |
| XBus | Core A XBus address | 12 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 12 of 12 | 0.06 |
| XBus | Core A XBus write data, at a store | 12 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 12 of 12 | 0.06 |
| **All** | | **67** | 0 | **21** | 0 | 3 | 23 | 66 | 0 | 21 | **67 of 88** | |

## What it shows

- **Everything that reaches the comparator is caught, in nanoseconds.** Faults
  on core A's bus, before or after the delay line, double-bit RAM errors, and
  upsets of the comparator's state or the self-test result were all detected,
  well inside the budget, with no wrong output first.
- **CPU-private faults are often latent.** Most corrupted register writes
  never reached the bus within the run: 23 latent trials in all, which the trace
  comparison saw and the bus comparator did not (`docs/verification/trace.md`).
  They become dangerous only if a later access uses the value. The bus
  comparator then catches them, or never does if the value is never used.
- **The output paths and the reset synchroniser are not covered.** Upsets in
  the UART and CAN output registers corrupted the bytes and frames on the pins,
  and nothing in the SoC saw it: no read-back or independent check exists after
  the comparator. A CAN receiver would reject a corrupted frame on its CRC, but
  that is the bus protecting itself, not the SoC detecting the fault. An upset
  in the reset synchroniser restarted the cores with no fault reported: the
  outputs went safe for the reset, and the program started again.
- **Shared response data was masked** in these 12 draws, because the corrupted
  bits were not ones the firmware used. A shared fault reaches both cores the
  same way, so where it does matter, lockstep cannot see it. The RAM's ECC
  covers the RAM, but no check covers the response path itself.
- **The watchdog counter** upsets would show only after the run, which ends
  long before the 50,000-clock timeout.

Each gap is a candidate for the safety analysis of milestone 5: output
read-back or a checked output path, an independent check of the reset tree, and
integrity protection on the response path. Each is roadmap work, not done here.

## Limits

| Item | Status |
|------|--------|
| Fault model | Single forced bits in RTL simulation. No gate-level, multi-bit-burst or timing faults |
| Workload | One firmware, 700 µs. Latent faults that a longer run would expose stay latent |
| Denominators | Per site, from the seed. 12 trials per site is a sample, not a coverage estimate for an FMEDA |
| Seeds | Every manifest is kept; seed 2026 reproduces the table above |
| Undefined values | Data on the XBus is 'U' between accesses in simulation, so flips wait for activity. An earlier random-time draw put 24 trials there; they are counted invalid, not masked |
