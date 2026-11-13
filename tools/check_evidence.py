#!/usr/bin/env python3
"""Check that the evidence the documents cite still exists.

    python tools/check_evidence.py

The safety and verification documents name tests as `tb_bench.test_name`,
benches as `tb_bench`, formal properties by ID, and files by path. This script
fails if a named bench, test, property or file is not in the repository, so a
renamed or deleted test cannot leave a document claiming it as evidence.

Tests are found as run("...") in sim/tb/<bench>.vhd, and in the
configurations sim/run.py adds (a test named `tb_x.config.test` is checked as
`tb_x.test`). Properties are the CMP-, BUS-P and COM- IDs in sim/formal/*.sv.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DOCS = (sorted((ROOT / "docs").glob("*.md")) + sorted((ROOT / "docs" / "safety").glob("*.md"))
        + sorted((ROOT / "docs" / "verification").glob("*.md")) + [ROOT / "README.md"])
BENCHES = ROOT / "sim" / "tb"
# The board image bench, which has one unnamed test
PLAIN_BENCHES = [ROOT / "fpga" / "arty_a7_100t" / "sim", ROOT / "sw" / "hello"]
# The test framework: its packages and the names it declares
LIB = BENCHES / "lib"
FORMAL = ROOT / "sim" / "formal"

# Configuration names that sim/run.py puts between a bench and its test
CONFIGS = {"ram_256k", "ram_32k"}


def tests_of(bench):
    path = BENCHES / f"{bench}.vhd"
    if not path.is_file():
        path = LIB / f"{bench}.vhd"
    if not path.is_file():
        if any(re.search(rf"\b{bench}\b", f.read_text(encoding="utf-8")) for f in LIB.glob("tb_pkg*.vhd")):
            return set()
        if any((d / f"{bench}.vhd").is_file() for d in PLAIN_BENCHES):
            return set()
        return None
    return set(re.findall(r'run\("([^"]+)"\)', path.read_text(encoding="utf-8")))


def properties():
    ids = set()
    for sv in FORMAL.glob("*.sv"):
        ids.update(re.findall(r"\b((?:CMP|COM)-\d\d|BUS-P\d)\b", sv.read_text(encoding="utf-8")))
    return ids


def main():
    problems = []
    cache = {}
    props = properties()
    checked = 0
    for doc in DOCS:
        if not doc.is_file():
            continue
        text = doc.read_text(encoding="utf-8")
        rel = doc.relative_to(ROOT).as_posix()
        # A bench, a bench and a test, or a bench, a configuration and a test
        for m in re.finditer(r"\b(tb_[a-z0-9_]+)(?:\.([a-z0-9_]+))?(?:\.([a-z0-9_]+))?", text):
            bench, first, second = m.groups()
            test = second if first in CONFIGS else first
            if test in ("vhd", "py", "txt"):
                test = None
            if bench not in cache:
                cache[bench] = tests_of(bench)
            if cache[bench] is None:
                problems.append(f"{rel}: bench {bench} does not exist")
                continue
            checked += 1
            if test and test not in cache[bench]:
                problems.append(f"{rel}: {bench} has no test {test}")
        for m in re.finditer(r"\b((?:CMP|COM)-\d\d|BUS-P\d)\b", text):
            checked += 1
            if m.group(1) not in props:
                problems.append(f"{rel}: formal property {m.group(1)} is not in sim/formal")
        # Repository paths in backticks
        for m in re.finditer(r"`((?:rtl|sim|docs|fpga|tools|sw)/[A-Za-z0-9_./-]+\.(?:vhd|py|md|sv|sby|tcl|xdc|csv|h))`", text):
            checked += 1
            if not (ROOT / m.group(1)).is_file():
                problems.append(f"{rel}: file {m.group(1)} does not exist")
    for p in sorted(set(problems)):
        print("EVIDENCE:", p)
    if problems:
        print(f"{len(set(problems))} broken reference(s)")
        return 1
    print(f"ok: {checked} references to benches, tests, properties and files in {len(DOCS)} documents")
    return 0


if __name__ == "__main__":
    sys.exit(main())
