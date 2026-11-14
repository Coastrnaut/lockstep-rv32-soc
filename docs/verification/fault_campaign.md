# Fault campaign (roadmap R2.3)

A repeatable campaign of single faults on the running SoC, classified by what
reached the pins. It replaces neither formal proof nor a gate-level campaign:
faults are VHDL `force`s on named RTL signals, one per trial.

## How it runs

```bash
python sim/scripts/fault_campaign.py --per-site 12 --seed 2026     # about 2.5 minutes on 16 cores
```

1. **Manifest.** The seed draws, for each of 20 sites, a bit, a time between
   20 and 400 µs after reset, a duration, and a kind: flipped, or stuck at 0
   or 1 for the rest of the run. Trial 0 has no fault and is the reference.
   `sim/campaign/<name>/manifest.csv` keeps every draw, so a campaign repeats
   exactly.
2. **Trials.** Each trial is one configuration of
   `sim/tb/tb_fault_campaign.vhd`. The bench runs the simulation
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

GHDL 6.0, 240 trials and the reference, about 2.5 minutes on 16 cores, with the
read data parity (HSI 8.6), the retirement comparator (HSI FLT-05) and the
unasked-reset check (HSI RST-01) in the RTL. Sites 1 to 15 are the first campaign's; sites 16 to 20 were added after
it, at the end of the draw, so the seed draws the same trials for the first
fifteen. "Detected of effective" counts detected trials out of those that
reached the pins or were detected.

| Class | Site | In time | Late | Undet. corrupted | Undet. missing | Corrected | Latent | Masked | Invalid | Wrong output first | Detected of effective | Latency µs (min / median / max) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Burst | ECC RAM word, three-bit burst, at an access | 0 | 0 | 2 | 0 | 0 | 0 | 10 | 0 | 2 | 0 of 2 | - |
| Burst | core A XBus write data, four-bit burst, at a store | 12 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 12 of 12 | 0.06 / 0.06 / 0.06 |
| CPU-private | core A instruction fetch data, at a fetch | 3 | 0 | 0 | 0 | 0 | 0 | 9 | 0 | 0 | 3 of 3 | 0.16 / 0.26 / 0.28 |
| CPU-private | core A register write data, at a write | 11 | 0 | 0 | 0 | 0 | 0 | 1 | 0 | 0 | 11 of 11 | 0.10 / 0.10 / 0.10 |
| CPU-private | core B register write data, at a write | 12 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 12 of 12 | 0.06 / 0.06 / 0.06 |
| Common cause | both cores' instruction fetch data, same bit at once | 4 | 0 | 0 | 0 | 0 | 0 | 8 | 0 | 0 | 4 of 4 | 0.12 / 0.16 / 0.24 |
| Common cause | both cores' register write data, same bit at once | 12 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 12 of 12 | 0.06 / 0.10 / 0.10 |
| Comparator | comparator state register | 12 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 12 of 12 | 0.00 / 0.00 / 0.00 |
| Delay line | core A bus after the delay line, at a store | 12 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 12 of 12 | 0.02 / 0.02 / 0.02 |
| ECC word | ECC RAM word, one bit, at an access | 0 | 0 | 0 | 0 | 3 | 0 | 9 | 0 | 0 | - | - |
| ECC word | ECC RAM word, two bits, at an access | 4 | 0 | 0 | 0 | 0 | 0 | 8 | 0 | 0 | 4 of 4 | 0.02 / 0.02 / 0.02 |
| Output logic | CAN TX bit register | 0 | 0 | 6 | 0 | 0 | 0 | 6 | 0 | 6 | 0 of 6 | - |
| Output logic | UART shift register | 0 | 0 | 3 | 0 | 0 | 0 | 9 | 0 | 3 | 0 of 3 | - |
| Reset | reset synchroniser stage | 12 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 12 of 12 | 0.04 / 0.04 / 0.06 |
| Self-test | self-test result register | 12 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 12 of 12 | 0.00 / 0.00 / 0.00 |
| Shared response | shared bus response data, at a response | 12 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 12 of 12 | 0.02 / 0.02 / 0.02 |
| Shared response | shared bus response data, stuck from a response on | 4 | 0 | 0 | 0 | 0 | 0 | 8 | 0 | 0 | 4 of 4 | 0.02 / 0.02 / 0.02 |
| Watchdog | watchdog counter | 0 | 0 | 0 | 0 | 0 | 0 | 12 | 0 | 0 | - | - |
| XBus | core A XBus address | 12 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 12 of 12 | 0.06 / 0.06 / 0.06 |
| XBus | core A XBus write data, at a store | 12 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 12 of 12 | 0.06 / 0.06 / 0.06 |
| **All** | | 146 | 0 | 11 | 0 | 3 | 0 | 80 | 0 | 11 | 146 of 157 | |

How the three mechanisms changed it, on the same 240 trials:

| RTL | Detected of effective | Latent | Undetected, corrupted |
|-----|-----------------------|--------|-----------------------|
| Bus comparator only (before the bench fix below) | 82 of 110 | 35 | 28 |
| With read data parity | 98 of 122 | 35 | 24 |
| With parity and the retirement comparator | 134 of 157 | 0 | 23 |
| With all three, and the unasked-reset check | 146 of 157 | 0 | 11 |

"Effective" grows as detection improves: a latent fault the retirement
comparator catches is now a detected one.

## What it shows

- **Everything that reaches the comparator is caught, in nanoseconds.** Faults
  on core A's bus, before or after the delay line, a four-bit burst on its write
  data, double-bit RAM errors, and upsets of the comparator's state or the
  self-test result were all detected, well inside the budget, with no wrong
  output first.
- **Faults inside the cores are now caught at the instruction.** Before the
  retirement comparator, most corrupted register writes stayed latent: the
  cores' registers differed and no bus access used the value within the run,
  35 trials in all. Each one is now detected within 0.1 µs, when the corrupted
  instruction retires on core B and differs from core A's.
- **The shared read data is now covered.** Both cores read the same data, so a
  fault in it after the slave reaches both alike and lockstep cannot see it.
  Before the parity, a bit of the response stuck from one response on
  corrupted the outputs in 4 of 12 trials, and nothing noticed. With it, every
  one of those is detected 20 ns after the injection, and so is every
  transient flip of the response (12 of 12). The other 8 stuck trials held a
  bit at 0 that was never read as 1: no effect, and nothing to detect.
- **A common disturbance is caught.** The same bit flipped in both cores at the
  same instant meets different instructions, because core B is two clocks
  behind. With the bus comparator alone that was not always enough: in one
  trial the flips hit a dependent `lui` and `addi` writing the same register,
  both cores ended with the same wrong value and identical bus traffic, and the
  UART printed `m` for `M` with nothing noticing. The retirement comparator
  sees the two instructions' results differ, and now detects all 12 register
  trials and every fetch trial that mattered.
- **A three-bit RAM burst is beyond SECDED.** In 2 of 12 trials the decoder took
  it for a single-bit error and "corrected" it: the firmware's SBE count went
  from 0 to 1, and the data the cores read was wrong. Nothing else in these runs
  used it. The FMEDA's ECC coverage assumes faults of at most two bits per word;
  adjacent-bit upsets are why RAMs interleave the bits of a word physically, a
  property of the target RAM, not of this RTL.
- **An upset in the reset synchroniser is now reported.** It restarts the cores
  with the outputs safe for the reset, a lost function rather than a wrong one,
  and before the check of HSI RST-01 nothing said why: 12 of 12 were
  undetected restarts. The cores' reset now falling while every reset request
  is still high is a fault, and all 12 are detected within 0.06 µs.
- **The output registers after the comparator are not covered.** Upsets in
  the UART and CAN output registers corrupted the bytes and frames on the pins,
  and nothing in the SoC saw it: nothing checks the output after the comparator.
  A CAN receiver rejects a corrupted frame on its CRC, and the item adds
  end-to-end protection (`docs/safety/item_definition.md`); the UART is
  diagnostic only. These 9 and the two three-bit bursts are the 11 undetected
  trials left.
- **The watchdog counter** upsets would show only after the run, which ends
  long before the 50,000-clock timeout.

### A defect in the bench, found and fixed

The first campaign reported every one of its 12 transient response flips as
masked. Part of that was the bench: it waited for ACK and chose the flipped
value in the same delta cycle, one delta before the fabric's read data
settled, so a bit about to become 1 was "flipped" to 1 and nothing changed.
It now waits 1 ns into the response cycle first (sites 7 and 18). The fix
showed up as one undetected flip that the parity check should have caught;
reproducing that trial alone found the cause.

## Limits

| Item | Status |
|------|--------|
| Fault model | Forced bits in RTL simulation: single bits, four- and three-bit bursts, and the same bit in both cores at once. No gate-level or timing faults |
| Workload | One firmware, 700 µs. Latent faults that a longer run would expose stay latent |
| Denominators | Per site, from the seed. 12 trials per site is a sample, not a coverage estimate for an FMEDA |
| Seeds | Every manifest is kept; seed 2026 reproduces the table above |
| Undefined values | Data on the XBus is 'U' between accesses in simulation, so flips wait for activity. An earlier random-time draw put 24 trials there; they are counted invalid, not masked |
