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

GHDL 6.0, 240 trials and the reference, 2 min 28 s on 16 cores, with the read
data parity of HSI 8.6 in the RTL. Sites 1 to 15 are the first campaign's;
sites 16 to 20 were added after it, at the end of the draw, so the seed draws
the same trials for the first fifteen. "Detected of effective" counts detected
trials out of those that reached the pins or were detected.

| Class | Site | In time | Late | Undet. corrupted | Undet. missing | Corrected | Latent | Masked | Invalid | Wrong output first | Detected of effective | Latency µs (min / median / max) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Burst | ECC RAM word, three-bit burst, at an access | 0 | 0 | 2 | 0 | 0 | 0 | 10 | 0 | 2 | 0 of 2 | - |
| Burst | core A XBus write data, four-bit burst, at a store | 12 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 12 of 12 | 0.06 / 0.06 / 0.06 |
| CPU-private | core A instruction fetch data, at a fetch | 2 | 0 | 0 | 0 | 0 | 1 | 9 | 0 | 0 | 2 of 2 | 0.16 / 0.21 / 0.26 |
| CPU-private | core A register write data, at a write | 1 | 0 | 0 | 0 | 0 | 10 | 1 | 0 | 0 | 1 of 1 | 0.18 / 0.18 / 0.18 |
| CPU-private | core B register write data, at a write | 0 | 0 | 0 | 0 | 0 | 12 | 0 | 0 | 0 | - | - |
| Common cause | both cores' instruction fetch data, same bit at once | 3 | 0 | 0 | 0 | 0 | 1 | 8 | 0 | 0 | 3 of 3 | 0.12 / 0.16 / 0.16 |
| Common cause | both cores' register write data, same bit at once | 0 | 0 | 1 | 0 | 0 | 11 | 0 | 0 | 1 | 0 of 1 | - |
| Comparator | comparator state register | 12 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 12 of 12 | 0.00 / 0.00 / 0.00 |
| Delay line | core A bus after the delay line, at a store | 12 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 12 of 12 | 0.02 / 0.02 / 0.02 |
| ECC word | ECC RAM word, one bit, at an access | 0 | 0 | 0 | 0 | 3 | 0 | 9 | 0 | 0 | - | - |
| ECC word | ECC RAM word, two bits, at an access | 4 | 0 | 0 | 0 | 0 | 0 | 8 | 0 | 0 | 4 of 4 | 0.02 / 0.02 / 0.02 |
| Output logic | CAN TX bit register | 0 | 0 | 6 | 0 | 0 | 0 | 6 | 0 | 6 | 0 of 6 | - |
| Output logic | UART shift register | 0 | 0 | 3 | 0 | 0 | 0 | 9 | 0 | 3 | 0 of 3 | - |
| Reset | reset synchroniser stage | 0 | 0 | 12 | 0 | 0 | 0 | 0 | 0 | 12 | 0 of 12 | - |
| Self-test | self-test result register | 12 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 12 of 12 | 0.00 / 0.00 / 0.00 |
| Shared response | shared bus response data, at a response | 12 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 12 of 12 | 0.02 / 0.02 / 0.02 |
| Shared response | shared bus response data, stuck from a response on | 4 | 0 | 0 | 0 | 0 | 0 | 8 | 0 | 0 | 4 of 4 | 0.02 / 0.02 / 0.02 |
| Watchdog | watchdog counter | 0 | 0 | 0 | 0 | 0 | 0 | 12 | 0 | 0 | - | - |
| XBus | core A XBus address | 12 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 12 of 12 | 0.06 / 0.06 / 0.06 |
| XBus | core A XBus write data, at a store | 12 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 12 of 12 | 0.06 / 0.06 / 0.06 |
| **All** | | 98 | 0 | 24 | 0 | 3 | 35 | 80 | 0 | 24 | 98 of 122 | |

## What it shows

- **Everything that reaches the comparator is caught, in nanoseconds.** Faults
  on core A's bus, before or after the delay line, a four-bit burst on its write
  data, double-bit RAM errors, and upsets of the comparator's state or the
  self-test result were all detected, well inside the budget, with no wrong
  output first.
- **The shared read data is now covered.** Both cores read the same data, so a
  fault in it after the slave reaches both alike and lockstep cannot see it.
  Before the parity of HSI 8.6, a bit of the response stuck from one response
  on corrupted the outputs in 4 of 12 trials, and nothing noticed. With it,
  every one of those is detected 20 ns after the injection, and so is every
  transient flip of the response (12 of 12). The other 8 stuck trials held a
  bit at 0 that was never read as 1: no effect, and nothing to detect.
- **A common disturbance is mostly caught by the two-clock offset, but not
  always.** The same bit flipped in both cores' fetched instruction at the same
  instant was detected 3 times out of 3 that mattered: core B is two clocks
  behind, so the flip hit different instructions in the two cores. The same flip
  in both cores' register write data hit different instructions too, but in
  one trial they were a dependent `lui` and `addi` writing the same register,
  so both cores ended with the same wrong value and identical bus traffic. The
  UART printed `m` for `M` and nothing noticed. The retirement trace comparison
  saw the two cores diverge before the wrong byte started: a retirement comparator in
  hardware would catch this; the bus comparator cannot. The other 11 were
  latent: the cores diverged in registers and never on the bus within the run.
- **CPU-private faults are often latent.** Most corrupted register writes
  never reached the bus within the run, which the trace comparison saw and the
  bus comparator did not (`docs/verification/trace.md`). They become dangerous
  only if a later access uses the value, and the bus comparator then catches
  them.
- **A three-bit RAM burst is beyond SECDED.** In 2 of 12 trials the decoder took
  it for a single-bit error and "corrected" it: the firmware's SBE count went
  from 0 to 1, and the data the cores read was wrong. Nothing else in these runs
  used it. The FMEDA's ECC coverage assumes faults of at most two bits per word;
  adjacent-bit upsets are why RAMs interleave the bits of a word physically, a
  property of the target RAM, not of this RTL.
- **The output paths and the reset synchroniser are not covered.** Upsets in
  the UART and CAN output registers corrupted the bytes and frames on the pins,
  and nothing in the SoC saw it: nothing checks the output after the comparator.
  A CAN receiver rejects a corrupted frame on its CRC, and the item adds
  end-to-end protection (`docs/safety/item_definition.md`); the UART is
  diagnostic only. An upset in the reset synchroniser restarted the cores with
  no fault reported. The outputs went safe for the reset, so the effect is a
  lost function, not a wrong one.
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
