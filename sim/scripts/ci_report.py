#!/usr/bin/env python3
"""Evidence for a regression run: a tool manifest and a pass/fail summary.

    python sim/scripts/ci_report.py manifest OUT.json
        Tool and source versions behind the run: Python, VUnit and the OSVVM it
        compiles, VSG, GHDL, the commit, and both submodule pins.

    python sim/scripts/ci_report.py summary XUNIT.xml [--log RUN.log]
        Counts of discovered, passed, failed and skipped tests, and benches, from
        VUnit's xUnit file. With --log, GHDL warnings are counted by where the
        source lives: first-party, NEORV32, or VUnit and its OSVVM. The summary is
        printed, and appended to $GITHUB_STEP_SUMMARY when that is set. The exit
        status is 1 when a test failed or none ran.

Uses only the standard library, so it runs before anything is installed.
"""
import argparse
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def _run(cmd, cwd=ROOT):
    try:
        r = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return f"unavailable ({exc.__class__.__name__})"
    return (r.stdout or r.stderr).strip()


def _ghdl():
    """The GHDL that sim/run.py would use: VUNIT_GHDL_PATH, then PATH."""
    path = os.environ.get("VUNIT_GHDL_PATH")
    if path:
        for name in ("ghdl", "ghdl.exe"):
            candidate = Path(path) / name
            if candidate.is_file():
                return str(candidate)
    return shutil.which("ghdl")


def _package_version(name):
    try:
        from importlib.metadata import version
        return version(name)
    except Exception:  # noqa: BLE001 - absent package is a manifest entry, not an error
        return None


def manifest(out):
    ghdl = _ghdl()
    osvvm = None
    try:
        import vunit
        osvvm = str(Path(vunit.__file__).parent / "vhdl" / "osvvm")
    except ImportError:
        pass

    submodules = {}
    for line in _run(["git", "submodule", "status"]).splitlines():
        parts = line.strip().lstrip("+-U").split()
        if len(parts) >= 2:
            submodules[parts[1]] = parts[0]

    data = {
        "commit": _run(["git", "rev-parse", "HEAD"]),
        "platform": platform.platform(),
        "python": platform.python_version(),
        "vunit_hdl": _package_version("vunit_hdl"),
        "vsg": _package_version("vsg"),
        "ghdl": _run([ghdl, "--version"]).splitlines()[0] if ghdl else None,
        "ghdl_backend": next((l.strip() for l in _run([ghdl, "--version"]).splitlines()
                              if "code generator" in l), None) if ghdl else None,
        # sim/run.py calls vu.add_osvvm(), so this is the OSVVM that is compiled.
        # sim/OsvvmLibraries is a pinned submodule that the runner does not use.
        "osvvm_compiled_from": osvvm,
        "submodules": submodules,
    }
    Path(out).parent.mkdir(parents=True, exist_ok=True)
    Path(out).write_text(json.dumps(data, indent=2) + "\n")
    print(json.dumps(data, indent=2))
    missing = [k for k in ("vunit_hdl", "vsg", "ghdl") if not data[k]]
    if missing:
        print(f"manifest: missing {', '.join(missing)}", file=sys.stderr)
        return 1
    return 0


# A path can hold a drive letter, so match up to the first .vhd(l):line:col
WARNING = re.compile(r"^(?P<path>.+?\.vhdl?):\d+:\d+:(@[^:]*:)?\s*(\(assertion )?warning", re.IGNORECASE)


def _provenance(path):
    p = path.replace("\\", "/").lower()
    if "rtl/core/neorv32" in p:
        return "NEORV32 (upstream)"
    if "vunit" in p or "osvvm" in p:
        return "VUnit and OSVVM (upstream)"
    if "/src/ieee" in p or p.startswith("../../src/"):
        return "GHDL libraries (upstream)"
    return "first-party"


def summary(xunit, log=None):
    tree = ET.parse(xunit)
    passed = failed = skipped = 0
    benches = Counter()
    failures = []
    for case in tree.iter("testcase"):
        bench = case.get("classname", "")
        benches[bench] += 1
        if case.find("failure") is not None or case.find("error") is not None:
            failed += 1
            failures.append(f"{bench}.{case.get('name')}")
        elif case.find("skipped") is not None:
            skipped += 1
        else:
            passed += 1
    total = passed + failed + skipped

    lines = [
        "## Regression",
        "",
        "| Discovered | Passed | Failed | Skipped | Benches |",
        "| --- | --- | --- | --- | --- |",
        f"| {total} | {passed} | {failed} | {skipped} | {len(benches)} |",
    ]
    if failures:
        lines += ["", "Failed:", ""] + [f"- `{name}`" for name in failures]

    if log:
        warnings = Counter()
        for line in Path(log).read_text(errors="replace").splitlines():
            m = WARNING.match(line.strip())
            if m:
                warnings[_provenance(m.group("path"))] += 1
        lines += ["", "| GHDL warnings by provenance | Count |", "| --- | --- |"]
        for origin in ("first-party", "NEORV32 (upstream)", "VUnit and OSVVM (upstream)",
                       "GHDL libraries (upstream)"):
            lines.append(f"| {origin} | {warnings.get(origin, 0)} |")

    text = "\n".join(lines) + "\n"
    print(text)
    step = os.environ.get("GITHUB_STEP_SUMMARY")
    if step:
        with open(step, "a", encoding="utf-8") as fh:
            fh.write(text)
    return 1 if failed or total == 0 else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)
    m = sub.add_parser("manifest")
    m.add_argument("out")
    s = sub.add_parser("summary")
    s.add_argument("xunit")
    s.add_argument("--log")
    args = parser.parse_args()
    if args.cmd == "manifest":
        return manifest(args.out)
    return summary(args.xunit, args.log)


if __name__ == "__main__":
    sys.exit(main())
