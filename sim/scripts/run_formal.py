#!/usr/bin/env python3
"""Formal checks (roadmap R2.1): GHDL turns each VHDL block into Verilog, and
SymbiYosys proves the properties of sim/formal/fv_*.sv against it.

    python sim/scripts/run_formal.py                 every job
    python sim/scripts/run_formal.py comparator      jobs whose name contains this
    python sim/scripts/run_formal.py --broken        also check that deliberately
                                                     broken RTL makes each proof fail

Each job runs a "prove" task (k-induction with smtbmc and z3: a PASS is a proof
for every depth) and a "cover" task that reaches every cover statement, which
shows that each property's antecedent can happen. Results go to
sim/formal/build/results.json and results.md; the build directory is not
tracked.

Tools: GHDL from VUNIT_GHDL_PATH, the Windows install or PATH, as sim/run.py
picks it. Yosys and SymbiYosys natively (yosys, sby) if both are on PATH, else
YoWASP (pip install -r sim/requirements-formal.txt). z3 from PATH or from the
Python environment's bin directory.

The RTL's own clocked "FORMAL FAIL" assertions are simulation checks that
assume a reset first. GHDL keeps them as $fatal calls, which Yosys cannot read,
so they are removed from the netlist; the harnesses state the properties
without that assumption.
"""
import argparse
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FORMAL = ROOT / "sim" / "formal"
BUILD = FORMAL / "build"

PKG = "config/package_soc_types.vhd"
VHDL = {
    "lockstep_comparator": [PKG, "rtl/safety_blocks/lockstep_comparator.vhd"],
    "soc_bus_fabric": [PKG, "rtl/safety_blocks/soc_bus_fabric.vhd"],
    "ecc_data_ram": [PKG, "rtl/safety_blocks/hamming_ecc_wrapper.vhd", "rtl/safety_blocks/ecc_data_ram.vhd"],
}

# name, sby file, the Verilog it needs (entity, generics, free memory), and a
# deliberately broken RTL that the prove task must reject: (file, pattern, replacement)
JOBS = [
    {
        "name": "lockstep_comparator",
        "sby": "lockstep_comparator.sby",
        "netlists": [("lockstep_comparator", {}, False)],
        # Revision 1.0's fault output: the latch only, so an illegal state that
        # closes the bus is not reported in that cycle
        "broken": ("rtl/safety_blocks/lockstep_comparator.vhd",
                   r"w_fault_reg <= '1' when \(r_fault_latched = '1' or r_current_state /= ST_SYSTEM_OK\) else",
                   "w_fault_reg <= '1' when (r_fault_latched = '1') else"),
    },
    {
        "name": "soc_bus_fabric",
        "sby": "soc_bus_fabric.sby",
        "netlists": [("soc_bus_fabric", {}, False)],
        "broken": ("rtl/safety_blocks/soc_bus_fabric.vhd",
                   r"\(r_target\(c_tgt_none\) = '1' or \(", "(false or ("),
    },
    {
        "name": "store_commit",
        "sby": "store_commit.sby",
        "netlists": [("lockstep_comparator", {}, False), ("ecc_data_ram", {"g_addr_bits": 4}, True)],
        "broken": ("rtl/safety_blocks/ecc_data_ram.vhd",
                   r"w_commit <= '1' when \(r_write = '1' and bus_ok_i = '1' and",
                   "w_commit <= '1' when (r_write = '1' and"),
    },
]

WINDOWS_GHDL = Path(r"C:\GIT\ghdl-mcode-6.0.0-ucrt64\bin\ghdl.exe")


def find_ghdl():
    explicit = os.environ.get("VUNIT_GHDL_PATH")
    if explicit:
        for name in ("ghdl", "ghdl.exe"):
            if (Path(explicit) / name).is_file():
                return str(Path(explicit) / name)
    if os.name == "nt" and WINDOWS_GHDL.is_file():
        return str(WINDOWS_GHDL)
    return shutil.which("ghdl")


def tool_env():
    """Environment for SymbiYosys: native tools if present, else YoWASP."""
    env = dict(os.environ)
    # pip's z3-solver puts z3 in <prefix>/bin, which is not on PATH on Windows
    extra = [str(Path(sys.prefix) / "bin"), str(Path(sys.executable).parent)]
    env["PATH"] = os.pathsep.join(extra + [env.get("PATH", "")])
    if shutil.which("sby", path=env["PATH"]) and shutil.which("yosys", path=env["PATH"]):
        return env, ["sby"], "native"
    if shutil.which("yowasp-sby", path=env["PATH"]):
        env.update(YOSYS="yowasp-yosys", SMTBMC="yowasp-yosys-smtbmc", WITNESS="yowasp-yosys-witness")
        return env, ["yowasp-sby"], "yowasp"
    sys.exit("SymbiYosys not found: pip install -r sim/requirements-formal.txt")


def first_line(cmd, env=None):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, env=env, timeout=120)
        return (r.stdout or r.stderr).strip().splitlines()[0]
    except (OSError, IndexError, subprocess.TimeoutExpired):
        return None


def strip_checks(text, free_memory):
    """Remove the RTL's simulation assertions, and optionally the array's zeros.

    GHDL 6 names a record port's fields as escaped identifiers, such as
    \\bus_i[addr], where GHDL 4.1 writes bus_i_addr. Both become the 4.1 form,
    which the harnesses use, so they work with either version.
    """
    text = re.sub(r"\\(\w+)\[(\w+)\] ", r"\1_\2 ", text)
    text = re.sub(r'\$fatal\(1, "[^"]*"\);', ";", text)
    if free_memory:
        text = re.sub(r"initial begin\n(\s*\w+\[\d+\] = \d+'b[01]+;\n)+\s*end\n", "", text)
    return text


def synthesise(ghdl, src_root, workdir, entity, generics, free_memory):
    workdir.mkdir(parents=True, exist_ok=True)
    for cf in workdir.glob("*.cf"):
        cf.unlink()
    files = [str(src_root / f) for f in VHDL[entity]]
    r = subprocess.run([ghdl, "-a", "--std=08", "--work=lockstep"] + files,
                       cwd=workdir, capture_output=True, text=True)
    if r.returncode:
        sys.exit(f"GHDL analysis failed for {entity}:\n{r.stderr}")
    gargs = [f"-g{k}={v}" for k, v in generics.items()]
    r = subprocess.run([ghdl, "--synth", "--std=08", "--work=lockstep", "--out=verilog"] + gargs + [entity],
                       cwd=workdir, capture_output=True, text=True)
    if r.returncode:
        sys.exit(f"GHDL synthesis failed for {entity}:\n{r.stderr}")
    (workdir / f"{entity}.v").write_text(strip_checks(r.stdout, free_memory), encoding="utf-8")


def run_job(job, ghdl, env, sby, src_root, tag):
    workdir = BUILD / (job["name"] + tag)
    shutil.rmtree(workdir, ignore_errors=True)
    for entity, generics, free_memory in job["netlists"]:
        synthesise(ghdl, src_root, workdir, entity, generics, free_memory)
    shutil.copy2(FORMAL / job["sby"], workdir)
    for harness in FORMAL.glob("fv_*.sv"):
        shutil.copy2(harness, workdir)
    began = time.monotonic()
    r = subprocess.run(sby + ["-f", job["sby"]], cwd=workdir, env=env, capture_output=True, text=True)
    elapsed = time.monotonic() - began
    log = r.stdout + r.stderr
    (workdir / "sby.log").write_text(log, encoding="utf-8")
    results = {}
    for task in ("prove", "cover"):
        status_file = workdir / f"{Path(job['sby']).stem}_{task}" / "status"
        status = status_file.read_text().split()[0] if status_file.is_file() else "ERROR"
        results[task] = {
            "status": status,
            "failed": sorted(set(re.findall(rf"\[{Path(job['sby']).stem}_{task}\] summary:\s+failed assertion \S+ at (\S+)", log))),
            "unreached": sorted(set(re.findall(rf"\[{Path(job['sby']).stem}_{task}\].*Unreached cover statement at \S+: (\S+)", log))),
            "reached": len(set(re.findall(rf"\[{Path(job['sby']).stem}_{task}\].*Reached cover statement .* at \S+: (\S+)", log))),
        }
    return results, elapsed


def properties(harness):
    text = (FORMAL / harness).read_text(encoding="utf-8")
    return re.findall(r"//\s*(CMP-\d+|BUS-P\d+|COM-\d+)\s*(?:\([^)]*\))?:?\s*(.*)", text)


def broken_copy(job):
    """A copy of the RTL with this job's deliberate break in it."""
    rel, pattern, replacement = job["broken"]
    copy = BUILD / ("src_broken_" + job["name"])
    shutil.rmtree(copy, ignore_errors=True)
    for part in ("config", "rtl/safety_blocks"):
        shutil.copytree(ROOT / part, copy / part)
    path = copy / rel
    text = path.read_text(encoding="utf-8").replace("\r\n", "\n")
    mutated, count = re.subn(pattern, replacement, text, count=1, flags=re.S)
    if count != 1:
        sys.exit(f"broken pattern for {job['name']} no longer matches {rel}")
    path.write_text(mutated, encoding="utf-8")
    return copy


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("names", nargs="*", help="run only the jobs whose name contains one of these")
    parser.add_argument("--broken", action="store_true",
                        help="also run each prove task on deliberately broken RTL, which must fail")
    args = parser.parse_args()

    ghdl = find_ghdl()
    if not ghdl:
        sys.exit("GHDL not found")
    env, sby, flavour = tool_env()
    yosys = "yowasp-yosys" if flavour == "yowasp" else "yosys"
    tools = {
        "ghdl": first_line([ghdl, "--version"]),
        "yosys": first_line([shutil.which(yosys, path=env["PATH"]) or yosys, "-V"], env),
        "symbiyosys": flavour,
        "z3": first_line([shutil.which("z3", path=env["PATH"]) or "z3", "--version"], env),
        "python": platform.python_version(),
        "platform": platform.platform(),
    }
    for name in ("yowasp-yosys", "z3-solver"):
        try:
            from importlib.metadata import version
            tools[name] = version(name)
        except Exception:  # noqa: BLE001 - absent package is recorded as absent
            tools[name] = None

    jobs = [j for j in JOBS if not args.names or any(n in j["name"] for n in args.names)]
    BUILD.mkdir(parents=True, exist_ok=True)
    report = {"tools": tools, "jobs": []}
    ok = True
    for job in jobs:
        print(f"{job['name']}: ", end="", flush=True)
        results, elapsed = run_job(job, ghdl, env, sby, ROOT, "")
        entry = {"job": job["name"], "sby": job["sby"], "elapsed_s": round(elapsed, 1), "results": results,
                 "properties": properties("fv_" + job["name"] + ".sv")}
        good = results["prove"]["status"] == "PASS" and results["cover"]["status"] == "PASS"
        print(f"prove {results['prove']['status']}, cover {results['cover']['status']} "
              f"({results['cover']['reached']} reached) in {elapsed:.0f} s")
        if args.broken:
            broken, _ = run_job(job, ghdl, env, sby, broken_copy(job), "_broken")
            entry["broken"] = {"change": job["broken"][0], "prove": broken["prove"]["status"],
                               "failed": broken["prove"]["failed"]}
            caught = broken["prove"]["status"] == "FAIL"
            print(f"  broken RTL: prove {broken['prove']['status']} "
                  f"({'caught' if caught else 'NOT CAUGHT'}: {', '.join(broken['prove']['failed'])})")
            good = good and caught
        ok = ok and good
        report["jobs"].append(entry)

    (BUILD / "results.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    lines = ["# Formal results", "", "| Tool | Version |", "| --- | --- |"]
    lines += [f"| {k} | {v} |" for k, v in tools.items()]
    lines += ["", "| Job | Prove (k-induction) | Cover | Broken RTL caught | Time |", "| --- | --- | --- | --- | --- |"]
    for e in report["jobs"]:
        caught = "-" if "broken" not in e else ("yes" if e["broken"]["prove"] == "FAIL" else "NO")
        lines.append(f"| {e['job']} | {e['results']['prove']['status']} | {e['results']['cover']['status']} "
                     f"({e['results']['cover']['reached']} reached) | {caught} | {e['elapsed_s']} s |")
    (BUILD / "results.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("\n".join(lines))
    step = os.environ.get("GITHUB_STEP_SUMMARY")
    if step:
        with open(step, "a", encoding="utf-8") as fh:
            fh.write("\n".join(lines) + "\n")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
