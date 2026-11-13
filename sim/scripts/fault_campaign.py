#!/usr/bin/env python3
"""Fault campaign (roadmap R2.3): inject, run, classify, report.

    python sim/scripts/fault_campaign.py --per-site 8 --seed 1    generate, run, report
    python sim/scripts/fault_campaign.py --report-only             report the last run again

Each trial is one run of sim/testbenches/tb_fault_campaign.vhd: the simulation
firmware on the SoC, with one fault injected at a site, bit, time and duration
drawn from the seed. Trial 0 has no fault and is the reference. The manifest
(manifest.csv) and the results (results.csv, report.md) go to
sim/campaign/<name>/, named after the seed unless --name says otherwise.

Classes, judged against the reference run:

    detected in time   nmi_fault_o rose within the budget (50 us) of the injection
    detected late      it rose, but later
    undetected, corrupted   no detection, and a UART byte or CAN frame differed
    undetected, missing     no detection, and outputs stopped short of the reference
    latent             no detection, outputs as the reference, but the cores'
                       retirements diverged: activated, and hidden at the pins
    corrected          a single-bit RAM error that the ECC corrected: the only
                       difference is the SBE count the firmware prints, 1 for 0
    masked             no detection, outputs as the reference, no divergence
    invalid            the trial produced no result, or flipped a bit that held
                       no defined value in simulation ('U' or 'X'), which
                       hardware never has

"Wrong output first" marks a detected trial in which a wrong byte or frame
left the SoC before the fault pin rose.
"""
import argparse
import csv
import os
import random
import re
import statistics
import subprocess
import sys
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SIM = ROOT / "sim"
BUDGET_PS = 50_000_000  # 50 us, the provisional SoC fault-response target
UART_BYTE_PS = 11 * 434 * 20_000  # start, 8 data, parity and stop bits at 50 MHz

# site: (name, fault class, bits, durations to draw from)
SITES = {
    1: ("core A register write data, at a write", "CPU-private", 32, [1]),
    2: ("core A instruction fetch data, at a fetch", "CPU-private", 32, [1]),
    3: ("core A XBus write data, at a store", "XBus", 32, [1, 3]),
    4: ("core A XBus address", "XBus", 32, [1, 3]),
    5: ("core A bus after the delay line, at a store", "Delay line", 32, [1]),
    6: ("comparator state register", "Comparator", 8, [1]),
    7: ("shared bus response data, at a response", "Shared response", 32, [1]),
    8: ("ECC RAM word, one bit, at an access", "ECC word", 72, [1]),
    9: ("ECC RAM word, two bits, at an access", "ECC word", 72, [1]),
    10: ("watchdog counter", "Watchdog", 16, [1]),
    11: ("UART shift register", "Output logic", 11, [1, 0]),
    12: ("CAN TX bit register", "Output logic", 1, [1, 0]),
    13: ("reset synchroniser stage", "Reset", 2, [1]),
    14: ("self-test result register", "Self-test", 8, [1]),
    15: ("core B register write data, at a write", "CPU-private", 32, [1]),
}
FIELDS = ["trial", "site", "bit", "kind", "duration", "inject_ns", "run_us"]


def generate(per_site, seed, run_us):
    rng = random.Random(seed)
    rows = [dict(trial=0, site=0, bit=0, kind=2, duration=1, inject_ns=50_000, run_us=run_us)]
    trial = 1
    for site, (_, _, bits, durations) in SITES.items():
        for _ in range(per_site):
            duration = rng.choice(durations)
            rows.append(dict(trial=trial, site=site, bit=rng.randrange(bits),
                             kind=2 if duration else rng.choice([0, 1]),
                             duration=duration,
                             inject_ns=rng.randrange(20_000, 400_000, 20),
                             run_us=run_us))
            trial += 1
    return rows


def parse(path):
    text = path.read_text(encoding="utf-8")
    head = dict(re.findall(r"(\w+)=(\S+)", text.split("\n", 2)[0] + " " + text.split("\n", 2)[1]))
    trace = re.search(r"trace_ps=(-?\d+)", text)
    retired = re.search(r"retired=(\d+)", text)
    return {
        "trial": int(head["trial"]),
        "before": head.get("before", "'-'").strip("'"),
        "inject_ps": int(head["inject_ps"]),
        "nmi_ps": int(head["nmi_ps"]),
        "safe_ps": int(head["safe_ps"]),
        "trace_ps": int(trace.group(1)) if trace else -1,
        "retired": int(retired.group(1)) if retired else 0,
        "uart": [(int(t), b) for t, b in re.findall(r"^uart (\d+) (\w+)", text, re.M)],
        "can": [int(t) for t in re.findall(r"^can (\d+)", text, re.M)],
        "frame": (re.search(r"^can_frame (.*)$", text, re.M) or [None, None])[1],
    }


# The firmware's third UART byte is SBE_COUNT as a digit
SBE_BYTE = 2


def corrected(r, ref):
    """Outputs as the reference but for SBE_COUNT going from 0 to 1."""
    mine = [b for _, b in r["uart"]]
    theirs = [b for _, b in ref["uart"]]
    if len(mine) != len(theirs) or len(mine) <= SBE_BYTE:
        return False
    rest_same = all(a == b for i, (a, b) in enumerate(zip(mine, theirs)) if i != SBE_BYTE)
    return rest_same and theirs[SBE_BYTE] == "30" and mine[SBE_BYTE] == "31" and r["frame"] == ref["frame"]


def classify(r, ref, site):
    detected = r["nmi_ps"] >= 0
    limit = r["nmi_ps"] if detected else float("inf")
    wrong_first = False
    # A byte counts once it has finished: one cut short by the safe state is not
    # a wrong byte that got out
    for i, (t, b) in enumerate(r["uart"]):
        if t + UART_BYTE_PS < limit and (i >= len(ref["uart"]) or b != ref["uart"][i][1]):
            wrong_first = True
    if r["can"] and r["can"][0] < limit and r["frame"] != ref["frame"]:
        wrong_first = True
    if detected:
        cls = "detected in time" if r["nmi_ps"] - r["inject_ps"] <= BUDGET_PS else "detected late"
        return cls, wrong_first
    if site == 8 and corrected(r, ref):
        return "corrected", False
    same_bytes = [b for _, b in r["uart"]] == [b for _, b in ref["uart"]]
    same_frames = len(r["can"]) == len(ref["can"]) and r["frame"] == ref["frame"]
    if same_bytes and same_frames:
        return ("latent" if r["trace_ps"] >= 0 else "masked"), False
    shorter = (len(r["uart"]) < len(ref["uart"]) or len(r["can"]) < len(ref["can"])) and not wrong_first
    return ("undetected, missing" if shorter else "undetected, corrupted"), wrong_first


def run(manifest, jobs):
    env = dict(os.environ, LOCKSTEP_CAMPAIGN=str(manifest), LOCKSTEP_NO_LINT="1")
    cmd = [sys.executable, "run.py", "sim_lib.tb_fault_campaign.*", "-p", str(jobs)]
    r = subprocess.run(cmd, cwd=SIM, env=env, capture_output=True, text=True)
    (manifest.parent / "run.log").write_text(r.stdout + r.stderr, encoding="utf-8")
    return r.returncode


def report(folder, manifest_rows, seed):
    results = {}
    for path in (SIM / "vunit_out" / "test_output").glob("sim_lib.tb_fault_campaign.*/fault_result.txt"):
        r = parse(path)
        results[r["trial"]] = r
    if 0 not in results:
        sys.exit("no result for trial 0, the fault-free reference")
    ref = results[0]

    rows = []
    for m in manifest_rows:
        t = int(m["trial"])
        site = int(m["site"])
        if t == 0:
            continue
        name, fclass, _, _ = SITES[site]
        r = results.get(t)
        if r is None:
            cls, wrong, latency = "invalid", False, None
        elif int(m["kind"]) == 2 and r["before"] not in ("0", "1"):
            cls, wrong, latency = "invalid", False, None
        else:
            cls, wrong = classify(r, ref, site)
            latency = (r["nmi_ps"] - r["inject_ps"]) / 1e6 if r["nmi_ps"] >= 0 else None
        rows.append(dict(m, site_name=name, fault_class=fclass, outcome=cls, wrong_output_first=wrong,
                         latency_us=latency, trace_divergence=(r is not None and r["trace_ps"] >= 0)))

    with open(folder / "results.csv", "w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)

    outcomes = ["detected in time", "detected late", "undetected, corrupted", "undetected, missing",
                "corrected", "latent", "masked", "invalid"]
    by_site = defaultdict(Counter)
    lat = defaultdict(list)
    wrong = Counter()
    for row in rows:
        by_site[(row["fault_class"], row["site_name"])][row["outcome"]] += 1
        if row["latency_us"] is not None:
            lat[(row["fault_class"], row["site_name"])].append(row["latency_us"])
        if row["wrong_output_first"]:
            wrong[(row["fault_class"], row["site_name"])] += 1

    lines = [f"# Fault campaign, seed {seed}", "",
             f"{len(rows)} trials and a fault-free reference. Budget for 'in time': "
             f"{BUDGET_PS / 1e6:.0f} us from injection to nmi_fault_o.", "",
             "| Class | Site | " + " | ".join(outcomes) + " | Wrong output first | Detected of effective | Latency us (min / median / max) |",
             "| --- | --- | " + " | ".join("---" for _ in outcomes) + " | --- | --- | --- |"]
    total = Counter()
    for key in sorted(by_site):
        c = by_site[key]
        total.update(c)
        effective = sum(c[o] for o in outcomes[:4])
        detected = c["detected in time"] + c["detected late"]
        ratio = f"{detected} of {effective}" if effective else "-"
        l = lat.get(key)
        latency = f"{min(l):.2f} / {statistics.median(l):.2f} / {max(l):.2f}" if l else "-"
        lines.append(f"| {key[0]} | {key[1]} | " + " | ".join(str(c[o]) for o in outcomes) +
                     f" | {wrong[key]} | {ratio} | {latency} |")
    effective = sum(total[o] for o in outcomes[:4])
    detected = total["detected in time"] + total["detected late"]
    lines.append(f"| **All** | | " + " | ".join(str(total[o]) for o in outcomes) +
                 f" | {sum(wrong.values())} | {detected} of {effective} | |")
    lines += ["", "'Effective' counts the trials whose fault reached the pins or was detected: "
              "detected, or undetected with corrupted or missing outputs. Latent and masked trials "
              "had no effect at the pins in the run, and corrected trials only the SBE count they report."]
    (folder / "report.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("\n".join(lines))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--per-site", type=int, default=8)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--run-us", type=int, default=700)
    parser.add_argument("--name")
    parser.add_argument("-p", "--jobs", type=int, default=os.cpu_count() or 4)
    parser.add_argument("--report-only", action="store_true")
    args = parser.parse_args()

    folder = SIM / "campaign" / (args.name or f"seed{args.seed}")
    folder.mkdir(parents=True, exist_ok=True)
    manifest = folder / "manifest.csv"
    if not args.report_only:
        rows = generate(args.per_site, args.seed, args.run_us)
        with open(manifest, "w", newline="", encoding="utf-8") as fh:
            writer = csv.DictWriter(fh, fieldnames=FIELDS)
            writer.writeheader()
            writer.writerows(rows)
        print(f"{len(rows)} trials in {manifest}", flush=True)
        rc = run(manifest, args.jobs)
        print(f"run.py exit {rc} (a failing trial is not a failing campaign)")
    with open(manifest, newline="", encoding="utf-8") as fh:
        report(folder, list(csv.DictReader(fh)), args.seed)
    return 0


if __name__ == "__main__":
    sys.exit(main())
