#!/usr/bin/env python3
"""FMEDA input table: check it, and compute the metrics once it is complete.

    python sim/scripts/fmeda.py              check the table, then report
    python sim/scripts/fmeda.py --check      check only (CI)
    python sim/scripts/fmeda.py --selftest   check the arithmetic on a worked table

docs/safety/fmeda_inputs.csv has one row per failure mode (roadmap milestone 5).
Each row names the element, the mode, the safety goals it can violate, how it
is classified, the mechanism that covers it, the coverages, the diagnostic
interval, its failure rate in FIT with the rate's source, the source of the
coverage figure, and an evidence file in this repository.

Classifications:

    safe          cannot violate a safety goal (or is not safety-related)
    single-point  violates a goal, and nothing covers it
    covered       a mechanism covers it: dc_rf of it is detected, the rest
                  is residual
    mechanism     a fault in a safety mechanism itself: a multiple-point
                  fault, dc_latent of which is detected, the rest latent

TBD is allowed for fit and the coverages, and is how the table stands until a
target, a mission profile and a failure-rate source are chosen. The metrics
are computed only when every safety-related row has its numbers:

    SPFM = 1 - sum(SPF + RF) / sum(safety-related)
    LFM  = 1 - sum(latent MPF) / sum(safety-related - SPF - RF)
    PMHF >= sum(SPF + RF)    the dual-point term needs exposure times and is
                             not computed here, so this is a lower bound
"""
import argparse
import csv
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TABLE = ROOT / "docs" / "safety" / "fmeda_inputs.csv"
COLUMNS = ["id", "element", "failure_mode", "safety_goal", "classification", "mechanism", "dc_rf",
           "dc_latent", "diagnostic_interval", "fit", "fit_source", "coverage_source", "evidence"]
CLASSES = {"safe", "single-point", "covered", "mechanism"}
GOALS = {"SG-01", "SG-02", "SG-03", "SG-04", "SG-05"}


def number(value):
    """A float, None for TBD, or the string itself for '-' (not applicable)."""
    if value == "TBD":
        return None
    if value == "-":
        return "-"
    return float(value)


def check(rows):
    problems = []
    seen = set()
    for r in rows:
        where = r.get("id", "?")
        if list(r.keys()) != COLUMNS:
            problems.append(f"{where}: columns are {list(r.keys())}, not {COLUMNS}")
            continue
        if r["id"] in seen:
            problems.append(f"{where}: duplicate id")
        seen.add(r["id"])
        if r["classification"] not in CLASSES:
            problems.append(f"{where}: classification '{r['classification']}' is not one of {sorted(CLASSES)}")
        goals = [g for g in r["safety_goal"].split(";") if g != "-"]
        for g in goals:
            if g not in GOALS:
                problems.append(f"{where}: unknown safety goal '{g}'")
        if not goals and r["classification"] != "safe":
            problems.append(f"{where}: only a safe row may name no safety goal")
        for field in ("dc_rf", "dc_latent", "fit"):
            try:
                v = number(r[field])
            except ValueError:
                problems.append(f"{where}: {field} '{r[field]}' is not a number, TBD or -")
                continue
            if isinstance(v, float) and field != "fit" and not 0 <= v <= 1:
                problems.append(f"{where}: {field} {v} is outside 0 to 1")
            if isinstance(v, float) and field == "fit" and v < 0:
                problems.append(f"{where}: negative fit")
        if r["fit"] == "-":
            problems.append(f"{where}: fit cannot be '-': give a rate or TBD")
        if r["classification"] == "covered" and r["dc_rf"] == "-":
            problems.append(f"{where}: a covered mode needs dc_rf (a number or TBD)")
        if r["classification"] == "mechanism" and r["dc_latent"] == "-":
            problems.append(f"{where}: a mechanism fault needs dc_latent (a number or TBD)")
        if r["fit"] != "TBD" and r["fit_source"] in ("", "TBD"):
            problems.append(f"{where}: a failure rate needs its source")
        evidence = r["evidence"].split("#")[0]
        if not evidence or not (ROOT / evidence).is_file():
            problems.append(f"{where}: evidence '{r['evidence']}' is not a file in the repository")
    return problems


def metrics(rows):
    """SPFM, LFM and the PMHF lower bound, or None and the rows that lack numbers."""
    missing = []
    total = spf_rf = latent = 0.0
    for r in rows:
        if r["classification"] == "safe":
            continue
        fit = number(r["fit"])
        dc_rf = number(r["dc_rf"])
        dc_latent = number(r["dc_latent"])
        need = [("fit", fit)]
        if r["classification"] == "covered":
            need.append(("dc_rf", dc_rf))
        if r["classification"] == "mechanism":
            need.append(("dc_latent", dc_latent))
        lacking = [name for name, v in need if v is None]
        if lacking:
            missing.append(f"{r['id']} ({', '.join(lacking)})")
            continue
        total += fit
        if r["classification"] == "single-point":
            spf_rf += fit
        elif r["classification"] == "covered":
            spf_rf += fit * (1 - dc_rf)
        else:
            latent += fit * (1 - dc_latent)
    if missing:
        return None, missing
    spfm = 1 - spf_rf / total if total else None
    rest = total - spf_rf
    lfm = 1 - latent / rest if rest else None
    return {"spfm": spfm, "lfm": lfm, "pmhf_lower_fit": spf_rf, "total_fit": total}, []


def selftest():
    rows = [
        dict(zip(COLUMNS, ["T-1", "a", "m", "SG-01", "single-point", "-", "-", "-", "-", "1", "x", "x", "README.md"])),
        dict(zip(COLUMNS, ["T-2", "b", "m", "SG-01", "covered", "y", "0.99", "-", "-", "100", "x", "x", "README.md"])),
        dict(zip(COLUMNS, ["T-3", "c", "m", "SG-01", "mechanism", "y", "-", "0.9", "-", "10", "x", "x", "README.md"])),
        dict(zip(COLUMNS, ["T-4", "d", "m", "-", "safe", "-", "-", "-", "-", "1000", "x", "x", "README.md"])),
    ]
    assert check(rows) == [], check(rows)
    m, missing = metrics(rows)
    assert not missing
    # SPF + RF = 1 + 100 * 0.01 = 2 of 111; latent = 10 * 0.1 = 1 of 109
    assert abs(m["spfm"] - (1 - 2 / 111)) < 1e-12, m
    assert abs(m["lfm"] - (1 - 1 / 109)) < 1e-12, m
    assert abs(m["pmhf_lower_fit"] - 2) < 1e-12, m
    bad = [dict(rows[0], classification="maybe"), dict(rows[1], dc_rf="1.5"), dict(rows[2], evidence="nope.md")]
    assert len(check(bad)) == 3, check(bad)
    print("selftest: ok (SPFM, LFM and PMHF lower bound on a worked table; three bad rows rejected)")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true", help="check the table and stop")
    parser.add_argument("--selftest", action="store_true", help="check the arithmetic and stop")
    args = parser.parse_args()
    if args.selftest:
        selftest()
        return 0
    with open(TABLE, newline="", encoding="utf-8") as fh:
        rows = list(csv.DictReader(fh))
    problems = check(rows)
    for p in problems:
        print("FMEDA:", p)
    if problems:
        return 1
    by_class = {c: sum(r["classification"] == c for r in rows) for c in sorted(CLASSES)}
    print(f"ok: {len(rows)} failure modes in {TABLE.relative_to(ROOT).as_posix()}: "
          + ", ".join(f"{n} {c}" for c, n in by_class.items()))
    if args.check:
        return 0
    m, missing = metrics(rows)
    if m is None:
        print(f"metrics: not computed, {len(missing)} safety-related rows lack numbers: {', '.join(missing)}")
    else:
        print(f"SPFM {m['spfm']:.4%}, LFM {m['lfm']:.4%}, PMHF >= {m['pmhf_lower_fit']:.3g} FIT "
              f"of {m['total_fit']:.3g} FIT safety-related")
    return 0


if __name__ == "__main__":
    sys.exit(main())
