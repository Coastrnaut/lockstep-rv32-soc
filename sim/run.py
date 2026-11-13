#!/usr/bin/env python3
"""Regression runner for lockstep-rv32-soc: GHDL and Vivado xsim, plain VHDL.

    python run.py                    lint gates, then every test on every simulator found
    python run.py tb_soc_ecc.*       the tests that match, on every simulator found
    python run.py --sim ghdl         one simulator only (ghdl, xsim, or both)
    python run.py --list             the tests, and stop
    python run.py --lint             GHDL lint only (ghdl -Wall, ghdl --synth), then exit
    python run.py --vsg              VSG style lint only, then exit
    python run.py --vsg-fix          let VSG fix what it can, then exit
    python run.py --compile          compile only

Options: -p N parallel simulations (default: one per CPU), --xunit-xml FILE,
--no-compare.

Every bench is plain VHDL-2008 on sim/tb/lib/tb_pkg.vhd, so the same files
run on both simulators. Benches are found by the wildcard sim/tb/tb_*.vhd, and
their tests by their run("...") calls. Each test runs in its own folder under
sim/out/<simulator>/<build>/. A test passes when its simulation prints
"TB PASS <test>". An assertion of severity error from the RTL fails it too,
except in the fault campaign, where faults are meant to trip them.

When both simulators run, each test's verdict and every line it printed with
tb_pkg (TB INFO, TB PASS, TB FAIL, with simulation times) must match between
them, or the run fails. --no-compare turns that off.

Simulators are found from:
  GHDL    GHDL_BIN (the folder), then on Windows C:/GIT/ghdl-mcode-6.0.0-ucrt64/bin or
          C:/GIT/ghdl-mcode-6.0.0-rc2-mingw64/bin, then ghdl on PATH
  Vivado  VIVADO_BIN (the bin folder), XILINX_VIVADO, xvhdl on PATH, then the
          default install folders (C:/AMDDesignTools/*/Vivado/bin and others)

Environment: LOCKSTEP_NO_LINT=1 skips the lint gates (the mutation and fault
campaigns set it). LOCKSTEP_CAMPAIGN=<manifest.csv> runs the fault campaign's
trials instead of the regression (sim/scripts/fault_campaign.py sets it).
"""
import argparse
import concurrent.futures
import csv
import fnmatch
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass, field
from pathlib import Path
from xml.sax.saxutils import escape, quoteattr

ROOT = Path(__file__).resolve().parents[1]
SIM = ROOT / "sim"
OUT = SIM / "out"
NEORV32 = ROOT / "rtl" / "core" / "neorv32"

# Analysis order within the lockstep library: a block comes after any block it instantiates
WRAPPERS = ("automotive_can_controller", "ecc_data_ram", "watchdog_supervisor", "dual_comparator")
# The bench library's shared code, in analysis order, before the benches
TB_LIB = [SIM / "tb" / "lib" / f for f in ("tb_pkg.vhd", "tb_random_pkg.vhd", "can_test_pkg.vhd")]
TB_LIB_AFTER = [SIM / "tb" / "lib" / f for f in ("can_test_node.vhd", "trace_compare.vhd")]

# The builds, each with its own IMEM image and benches. "check" is the test
# framework's own check, with no SoC: its tests say in their names what the
# runner must make of them (expect_pass_, expect_fail_).
BUILDS = {
    "check": {"image": None, "benches": lambda: [SIM / "tb" / "lib" / "tb_pkg_check.vhd"]},
    "sim": {"image": SIM / "firmware" / "neorv32_imem_image.vhd",
            "benches": lambda: sorted((SIM / "tb").glob("tb_*.vhd"))},
    "board": {"image": ROOT / "fpga" / "arty_a7_100t" / "board_imem_image.vhd",
              "benches": lambda: [ROOT / "fpga" / "arty_a7_100t" / "sim" / "tb_board_firmware.vhd"]},
    "hello": {"image": ROOT / "sw" / "hello" / "hello_imem_image.vhd",
              "benches": lambda: [ROOT / "sw" / "hello" / "tb_hello_world.vhd"]},
}

# Benches that run some tests under named generic configurations: (config, generics, tests)
CONFIGS = {
    "tb_soc_fabric": [
        ("ram_256k", {"g_ram_addr_bits": 15}, ["probes_get_one_response_each_and_unmapped_ones_change_nothing"]),
        ("ram_32k", {"g_ram_addr_bits": 12}, ["probes_get_one_response_each_and_unmapped_ones_change_nothing"]),
    ],
}

# The longest bench runs about 30 ms of simulated time
STOP_TIME_MS = 50
WINDOWS_GHDL = [Path("C:/GIT/ghdl-mcode-6.0.0-ucrt64/bin"), Path("C:/GIT/ghdl-mcode-6.0.0-rc2-mingw64/bin")]
VIVADO_GLOBS = [("C:/AMDDesignTools", "*/Vivado/bin"), ("C:/Xilinx/Vivado", "*/bin"), ("C:/Xilinx", "*/Vivado/bin"),
                ("/tools/Xilinx/Vivado", "*/bin"), ("/tools/Xilinx", "*/Vivado/bin"), ("/opt/Xilinx/Vivado", "*/bin")]

TB_LINE = re.compile(r"TB (INFO|PASS|FAIL|SKIP|EXPECT)\b.*")
# A force or release statement, which xsim cannot simulate, on one line:
# indent, target, force or release, value
FORCE = re.compile(r"^([ \t]*)(?!--)([^;\n]*?)\s*<=\s*(force|release)\b\s*([^;\n]*);", re.M)
# An alias of an external name: alias name, path
EXT_ALIAS = re.compile(r"\balias\s+(\w+)\s+is\s+<<\s*signal\s+([^:]+?)\s*:")
# The Tcl script for every xsim run. A bench built by tcl_forces pauses at each
# force or release after writing it to tb_force.txt; this applies it and runs
# on to the stop time.
RUN_TCL = """set ids [dict create]
run {ms} ms
while {{[file exists tb_force.txt]}} {{
  set fh [open tb_force.txt r]; set req [split [string trim [read $fh]] " "]; close $fh
  file delete tb_force.txt
  set op [lindex $req 0]; set path [lindex $req 1]; set now [lindex $req end]
  if {{[dict exists $ids $path]}} {{ remove_forces [dict get $ids $path]; dict unset ids $path }}
  if {{$op eq "force"}} {{
    if {{[catch {{add_force -radix [lindex $req 2] $path [lindex $req 3]}} id]}} {{
      puts "Error: cannot force $path: $id"
      quit
    }}
    dict set ids $path $id
  }}
  set left [expr {{{ms} * 1000000 - $now}}]
  if {{$left <= 0}} break
  run $left ns
}}
quit
"""
# An assertion or report of severity error: GHDL, then xsim
ASSERT_ERROR = re.compile(r"\((?:assertion|report) error\)|^Error: (?!\[)", re.M)


# ---------------------------------------------------------------------------
# Simulators
# ---------------------------------------------------------------------------
def find_ghdl():
    if os.environ.get("GHDL_BIN"):
        for name in ("ghdl", "ghdl.exe"):
            if (Path(os.environ["GHDL_BIN"]) / name).is_file():
                return str(Path(os.environ["GHDL_BIN"]) / name)
        sys.exit(f"ERROR: GHDL_BIN={os.environ['GHDL_BIN']} holds no ghdl")
    if os.name == "nt":
        for folder in WINDOWS_GHDL:
            if (folder / "ghdl.exe").is_file():
                return str(folder / "ghdl.exe")
    return shutil.which("ghdl")


def _vivado_tool(bindir, name):
    exe = Path(bindir) / (name + (".bat" if os.name == "nt" else ""))
    return str(exe) if exe.is_file() else None


def find_vivado():
    """The Vivado bin folder holding xvhdl, xelab and xsim, or None."""
    candidates = []
    if os.environ.get("VIVADO_BIN"):
        candidates.append(Path(os.environ["VIVADO_BIN"]))
    if os.environ.get("XILINX_VIVADO"):
        candidates.append(Path(os.environ["XILINX_VIVADO"]) / "bin")
    if shutil.which("xvhdl"):
        candidates.append(Path(shutil.which("xvhdl")).parent)
    for anchor, pattern in VIVADO_GLOBS:
        if Path(anchor).is_dir():
            candidates.extend(sorted(Path(anchor).glob(pattern), reverse=True))
    for c in candidates:
        if all(_vivado_tool(c, t) for t in ("xvhdl", "xelab", "xsim")):
            return c
    return None


def remove_tree(path):
    """Delete a test folder, removing (not entering) its link to the shared xsim.dir."""
    link = Path(path) / "xsim.dir"
    try:
        os.unlink(link)  # a symbolic link
    except OSError:
        try:
            os.rmdir(link)  # a Windows junction: rmdir removes the link only
        except OSError:
            pass
    shutil.rmtree(path, ignore_errors=True)


def posix(path):
    return str(path).replace("\\", "/")


def run_process(cmd, cwd, timeout):
    """Run a command; on a timeout, stop it and everything it started."""
    group = {"creationflags": subprocess.CREATE_NEW_PROCESS_GROUP} if os.name == "nt" else {"start_new_session": True}
    with subprocess.Popen(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                          encoding="utf-8", errors="replace", **group) as proc:
        try:
            out, _ = proc.communicate(timeout=timeout)
            return proc.returncode, out
        except subprocess.TimeoutExpired:
            if os.name == "nt":
                subprocess.run(["taskkill", "/F", "/T", "/PID", str(proc.pid)], capture_output=True, check=False)
            else:
                os.killpg(proc.pid, 9)
            return None, proc.communicate()[0]


# ---------------------------------------------------------------------------
# Sources and tests
# ---------------------------------------------------------------------------
def rtl_files():
    """(library, file) for our RTL before NEORV32, and the two units after it."""
    before = [("lockstep", ROOT / "rtl" / "pkg" / "package_soc_types.vhd")]
    for folder in ("safety", "peripherals"):
        for f in sorted((ROOT / "rtl" / folder).glob("*.vhd"), key=lambda f: (f.stem in WRAPPERS, f.stem)):
            before.append(("lockstep", f))
    after = [("lockstep", ROOT / "rtl" / "soc" / "lockstep_core.vhd"),
             ("lockstep", ROOT / "rtl" / "soc" / "top_automotive_soc.vhd")]
    return before, after


def neorv32_files(image):
    files = [("neorv32", image)]
    for line in (NEORV32 / "rtl" / "file_list_core.f").read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("--") and not line.endswith("neorv32_imem_image.vhd"):
            files.append(("neorv32", Path(line.replace("$NEORV32_HOME", str(NEORV32)))))
    return files


def compile_order(build):
    if BUILDS[build]["image"] is None:
        return [("sim_lib", TB_LIB[0])] + [("sim_lib", f) for f in BUILDS[build]["benches"]()]
    before, after = rtl_files()
    tb = [("sim_lib", f) for f in TB_LIB]
    tb += [("sim_lib", f) for f in sorted((SIM / "generated").glob("*.vhd"))]
    tb += [("sim_lib", f) for f in TB_LIB_AFTER]
    tb += [("sim_lib", f) for f in BUILDS[build]["benches"]()]
    return before + neorv32_files(BUILDS[build]["image"]) + after + tb


def tests_of(path):
    names = re.findall(r'\brun\("([^"]+)"\)', path.read_text(encoding="utf-8"))
    return list(dict.fromkeys(names)) or ["all"]


@dataclass
class Job:
    build: str
    bench: str
    test: str
    config: str = ""
    generics: dict = field(default_factory=dict)
    allow_errors: bool = False

    @property
    def name(self):
        return ".".join(p for p in (self.bench, self.config, self.test) if p)

    @property
    def unit(self):
        """What has to be elaborated: the bench with its generics."""
        return self.bench + (f"__{self.config}" if self.config else "")

    def __hash__(self):
        return hash(self.name)


def discover():
    jobs = []
    campaign = os.environ.get("LOCKSTEP_CAMPAIGN")
    if campaign:
        with open(campaign, newline="") as fh:
            for row in csv.DictReader(fh):
                generics = {f"g_{k}": int(row[k]) for k in ("trial", "site", "bit", "kind", "duration",
                                                              "inject_ns", "run_us")}
                jobs.append(Job("sim", "tb_fault_campaign", "trial", f"trial_{int(row['trial']):04d}", generics, True))
        return jobs
    for build, spec in BUILDS.items():
        for path in spec["benches"]():
            bench = path.stem
            configured = {}
            for config, generics, tests in CONFIGS.get(bench, []):
                for test in tests:
                    configured.setdefault(test, []).append((config, generics))
            for test in tests_of(path):
                for config, generics in configured.get(test, [("", {})]):
                    jobs.append(Job(build, bench, test, config, generics, test.startswith("assertion_")))
            if build == "check":
                # A name the bench does not have must fail too
                jobs.append(Job(build, bench, "expect_fail_a_test_the_bench_does_not_have"))
    return jobs


def select(jobs, patterns):
    if not patterns:
        return jobs
    pats = [p[len("sim_lib."):] if p.startswith("sim_lib.") else p for p in patterns]
    return [j for j in jobs if any(fnmatch.fnmatchcase(j.name, p) or fnmatch.fnmatchcase(j.bench, p) for p in pats)]


# ---------------------------------------------------------------------------
# Compile, elaborate and run, per simulator
# ---------------------------------------------------------------------------
class Ghdl:
    name = "ghdl"

    def __init__(self, exe):
        self.exe = exe

    def compile(self, build, libdir):
        libdir.mkdir(parents=True, exist_ok=True)
        for old in libdir.glob("*.cf"):
            old.unlink()
        # Consecutive files of one library go to GHDL in one call
        chunks = []
        for lib, f in compile_order(build):
            if chunks and chunks[-1][0] == lib:
                chunks[-1][1].append(posix(f))
            else:
                chunks.append((lib, [posix(f)]))
        for lib, files in chunks:
            rc, out = run_process([self.exe, "-a", "--std=08", f"--work={lib}"] + files, libdir, 900)
            if rc != 0:
                return False, out
        return True, ""

    def elaborate(self, units, libdir, jobs):
        # mcode elaborates when it runs
        return {}

    def run(self, job, libdir, rundir):
        cmd = [self.exe, "--elab-run", "--std=08", f"--workdir={posix(libdir)}", f"-P{posix(libdir)}",
               "--work=sim_lib", job.bench, f"--stop-time={STOP_TIME_MS}ms",
               f"--assert-level={'failure' if job.allow_errors else 'error'}", f"-gg_test={job.test}"]
        cmd += [f"-g{k}={v}" for k, v in job.generics.items()]
        return run_process(cmd, rundir, 1800)


def split_target(target):
    """A force target as its name and its suffixes: ('.', field) or ('()', text)."""
    m = re.match(r"\s*(\w+)", target)
    if not m:
        raise ValueError(f"cannot read the force target {target!r}")
    name, rest, parts = m.group(1), target[m.end():].strip(), []
    while rest:
        if rest[0] == ".":
            m = re.match(r"\.\s*(\w+)", rest)
            parts.append((".", m.group(1)))
            rest = rest[m.end():].strip()
        elif rest[0] == "(":
            depth = 0
            for i, c in enumerate(rest):
                depth += {"(": 1, ")": -1}.get(c, 0)
                if depth == 0:
                    break
            parts.append(("()", rest[1:i].strip()))
            rest = rest[i + 1:].strip()
        else:
            raise ValueError(f"cannot read the force target {target!r}")
    return name, parts


def xsim_path(bench, aliases, target):
    """A VHDL string expression for the xsim object path of a force target:
    instances joined by '/', a generate scope as an extended identifier
    (\\gen(0)\\), record fields by '.', an index or a slice in parentheses with
    ':' for the range, the index evaluated by the bench."""
    name, parts = split_target(target)
    if name in aliases:
        ext = re.sub(r"\s+", "", aliases[name])
        if ext.startswith(("^", ".", "@")):
            raise ValueError(f"cannot map the external name {ext!r} to an xsim path")
        scopes = [f"\\{s}\\" if "(" in s else s for s in ext.split(".")]
        path = f"/{bench}/" + "/".join(scopes)
    else:
        path = f"/{bench}/{name}"

    def image(expr):
        return expr if re.fullmatch(r"\d+", expr) else f"\" & integer'image({expr}) & \""
    for kind, text in parts:
        if kind == ".":
            path += "." + text
        else:
            path += "(" + ":".join(image(r.strip()) for r in re.split(r"\s+(?:downto|to)\s+", text)) + ")"
    return f'"{path}"'


def tcl_forces(text, bench):
    """The bench with every force and release as a tb_force or tb_release call.
    An alias is looked up at its latest declaration above the statement, which
    may span lines."""
    declared = [(m.start(), m.group(1), m.group(2)) for m in EXT_ALIAS.finditer(text)]
    aliases, out, pos = {}, [], 0
    for line in text.splitlines(keepends=True):
        while declared and declared[0][0] < pos:
            _, name, ext = declared.pop(0)
            aliases[name] = ext
        pos += len(line)
        m = FORCE.match(line)
        if m:
            indent, target, op, value = m.groups()
            path = xsim_path(bench, aliases, target)
            if op == "release":
                call = f"tb_release({path});"
            else:
                value = re.sub(r"^(?:in|out)\b\s*", "", value.strip())
                call = f"tb_force({path}, {target.strip()}, {value});"
            line = indent + call + line[m.end():]
        out.append(line)
    return "".join(out)


class Xsim:
    name = "xsim"

    def __init__(self, bindir, coverage=False):
        self.forcing = set()
        self.coverage = coverage
        self.bindir = bindir
        self.xvhdl = _vivado_tool(bindir, "xvhdl")
        self.xelab = _vivado_tool(bindir, "xelab")
        self.xsim = _vivado_tool(bindir, "xsim")

    def compile(self, build, libdir):
        shutil.rmtree(libdir / "xsim.dir", ignore_errors=True)
        libdir.mkdir(parents=True, exist_ok=True)
        lines = [f'vhdl2008 {lib} "{posix(self.source(Path(f), libdir))}"' for lib, f in compile_order(build)]
        (libdir / "all.prj").write_text("\n".join(lines + ["nosort"]) + "\n", encoding="utf-8")
        rc, out = run_process([self.xvhdl, "-prj", "all.prj", "--relax", "--nolog"], libdir, 1800)
        errors = [l for l in out.splitlines() if l.startswith("ERROR")]
        return rc == 0 and not errors, "\n".join(errors) or out[-3000:]

    def source(self, path, libdir):
        """The file xsim compiles. xsim cannot elaborate a VHDL-2008 force, so a
        bench that forces a signal goes in as a copy with each force and release
        as a tb_force or tb_release call, which the run's Tcl script carries out."""
        path = path.resolve()
        text = path.read_text(encoding="utf-8")
        if not FORCE.search(text):
            return path
        bench = re.search(r"^entity\s+(\w+)\s+is", text, re.M | re.I).group(1)
        self.forcing.add(bench)
        copy = libdir / "tcl_force" / path.name
        copy.parent.mkdir(parents=True, exist_ok=True)
        copy.write_text(tcl_forces(text, bench), encoding="utf-8")
        return copy.resolve()

    def elaborate(self, units, libdir, jobs):
        """xelab each bench and configuration once; returns {unit: error text}."""
        def one(unit):
            (bench, config), generics = unit
            snap = bench + (f"__{config}" if config else "")
            # Tcl can force a signal only with debug access to it
            debug = "typical" if bench in self.forcing else "off"
            cmd = [self.xelab, "--relax", "--debug", debug, "--nolog", "-L", "sim_lib", "-L", "lockstep",
                   "-L", "neorv32", f"sim_lib.{bench}", "-s", snap]
            if self.coverage:
                # Statement, branch, condition and toggle coverage, one database per
                # snapshot; every run of the snapshot adds to it
                cmd += ["-cc_type", "sbct", "-cc_db", snap, "-cc_dir", posix(libdir / "codecov")]
            if generics:
                # In a file: Windows' .bat wrapper would split name=value at the '='
                opts = libdir / f"{snap}.opts"
                opts.write_text("".join(f'-generic_top "{k}={v}"\n' for k, v in generics.items()), encoding="utf-8")
                cmd += ["-f", posix(opts)]
            rc, out = run_process(cmd, libdir, 1800)
            errors = [l for l in out.splitlines() if l.startswith("ERROR")]
            return snap, ("\n".join(errors) or out[-2000:]) if rc != 0 or errors else None

        failed = {}
        with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, jobs)) as pool:
            for snap, error in pool.map(one, units):
                if error:
                    failed[snap] = error
        return failed

    def run(self, job, libdir, rundir):
        # xsim's engine looks for xsim.dir in the folder it runs in, so each test's
        # folder gets a link to the one compiled snapshot
        link = rundir / "xsim.dir"
        if os.name == "nt":
            import _winapi
            _winapi.CreateJunction(str(libdir / "xsim.dir"), str(link))
        else:
            link.symlink_to(libdir / "xsim.dir", target_is_directory=True)
        (rundir / "tb_select.txt").write_text(job.test, encoding="utf-8")
        (rundir / "run.tcl").write_text(RUN_TCL.format(ms=STOP_TIME_MS), encoding="utf-8")
        # No --onfinish quit: xsim would take std.env.stop for the end, and run.tcl quits
        cmd = [self.xsim, job.unit, "--nolog", "--onerror", "quit", "-tclbatch", "run.tcl"]
        rc, out = run_process(cmd, rundir, 1800)
        # Now and then, under load, xsim loads the snapshot and stops at its prompt
        # without sourcing run.tcl: nothing was simulated. That is xsim failing to
        # start, not the test failing, so it gets one more try, and says so.
        if rc is not None and out is not None and "source run.tcl" not in out:
            first = out
            rc, out = run_process(cmd, rundir, 1800)
            out = f"run.py: xsim did not source run.tcl, so the test ran again\n{first}\n{out or ''}"
        return rc, out


def expected_outcome(sim, job, ok, msg):
    """A framework check passes when the test did what its name says it must."""
    kind = job.test.split("_")[1]
    wanted = {"pass": True, "fail": False}[kind]
    seen = {True: "passed", False: "failed", None: "was skipped"}[ok]
    if ok is wanted:
        return True, ""
    return False, f"the framework check {seen}, and should have {kind}ed" + (f": {msg}" if msg else "")


def verdict(job, rc, out):
    """(True passed, False failed or None skipped, message, the TB lines it printed)"""
    lines = [m.group(0).strip() for m in TB_LINE.finditer(out or "")]
    if rc is None:
        return False, "timed out", lines
    skips = [l for l in lines if l.startswith("TB SKIP")]
    if skips:
        return None, skips[0][len("TB SKIP "):], lines
    fails = [l for l in lines if l.startswith("TB FAIL")]
    if fails:
        return False, fails[0][len("TB FAIL "):], lines
    if job.test.startswith("assertion_"):
        # The test makes RTL assertions fire on purpose: exactly the ones it expects
        expected = [l[len("TB EXPECT "):].strip() for l in lines if l.startswith("TB EXPECT")]
        errors = [out[out.rfind("\n", 0, m.start()) + 1: out.find("\n", m.end())].strip()
                  for m in ASSERT_ERROR.finditer(out or "")]
        if not expected:
            return False, "an assertion_ test must say what it expects with expect_assertion", lines
        missing = [e for e in expected if not any(e in err for err in errors)]
        if missing:
            return False, f"expected assertion did not fire: {missing[0]}", lines
        others = [err for err in errors if not any(e in err for e in expected)]
        if others:
            return False, "unexpected assertion error: " + others[0][:200], lines
    elif not job.allow_errors:
        m = ASSERT_ERROR.search(out)
        if m:
            line = out[out.rfind("\n", 0, m.start()) + 1: out.find("\n", m.end())]
            return False, "assertion error: " + line.strip()[:200], lines
    if f"TB PASS {job.test}" in lines:
        return True, "", lines
    last = next((l.strip() for l in reversed((out or "").splitlines()) if l.strip()), "")
    return False, f"no result (exit {rc}): {last[:200]}", lines


# ---------------------------------------------------------------------------
# Lint gates
# ---------------------------------------------------------------------------
def ghdl_lint(ghdl):
    """ghdl -a -Wall over our RTL (an incomplete sensitivity list is an error), then ghdl --synth of each block."""
    before, after = rtl_files()
    print(f"\n{'=' * 60}\nSemantic Safety Lint: ghdl -a --std=08 -Wall, then ghdl --synth\n{'=' * 60}")
    with tempfile.TemporaryDirectory(prefix="lockstep_lint_") as tmp:
        ours = [ghdl, "-a", "--std=08", "-Wall", "-Werror=sensitivity", "--work=lockstep"]
        steps = [(ours, [f for _, f in before]),
                 ([ghdl, "-a", "--std=08", "-Wall", "--work=neorv32"],
                  [f for _, f in neorv32_files(BUILDS["sim"]["image"])]),
                 (ours, [f for _, f in after])]
        for cmd, files in steps:
            r = subprocess.run(cmd + [posix(f) for f in files], cwd=tmp, capture_output=True, text=True)
            if r.returncode != 0:
                print(r.stdout + r.stderr)
                print("\nLINT FAILED.")
                return False
        units = [f.stem for _, f in before[1:]] + [f.stem for _, f in after]
        for unit in units:
            r = subprocess.run([ghdl, "--synth", "--std=08", "--work=lockstep", unit], cwd=tmp,
                               capture_output=True, text=True)
            if r.returncode != 0:
                print(r.stderr)
                print(f"\nLINT FAILED synthesising {unit}.")
                return False
    print("\nLint passed: no semantic safety issues found.\n")
    return True


def vsg_files():
    rtl = sorted((ROOT / "rtl" / "pkg").glob("*.vhd"))
    for folder in ("safety", "peripherals", "soc"):
        rtl += sorted((ROOT / "rtl" / folder).glob("*.vhd"))
    rtl += [ROOT / "fpga" / "arty_a7_100t" / "arty_a7_top.vhd"]
    benches = sorted((SIM / "tb").glob("*.vhd")) + sorted((SIM / "tb" / "lib").glob("*.vhd"))
    # The board bench and the programs' benches; not the UNISIM stand-in, which
    # copies Xilinx's component declarations as they are
    benches += [ROOT / "fpga" / "arty_a7_100t" / "sim" / "tb_board_firmware.vhd"]
    benches += sorted((ROOT / "sw").glob("*/tb_*.vhd"))
    return rtl, benches


def run_vsg(fix=False):
    """VSG over every first-party VHDL file. sim/vsg_config.yaml enables every rule (tools/vsg_config.py
    writes it); the benches also read sim/vsg_testbench.yaml."""
    vsg = shutil.which("vsg")
    if not vsg:
        print("ERROR: vsg not found. pip install -r sim/requirements.txt")
        return False
    rtl, benches = vsg_files()
    config, bench_config = str(SIM / "vsg_config.yaml"), str(SIM / "vsg_testbench.yaml")
    print(f"\n{'=' * 60}\nStyle Lint: vsg{' --fix' if fix else ''}\nFiles: {len(rtl)} RTL, {len(benches)} benches\n"
          f"{'=' * 60}")
    ok = True
    for files, configs in ((rtl, [config]), (benches, [config, bench_config])):
        # vsg takes --fix or -ap (report every phase), not both
        r = subprocess.run([vsg, "-c"] + configs + (["--fix"] if fix else ["-ap"]) + ["-f"] + [posix(f) for f in files],
                           capture_output=True, text=True)
        if r.returncode != 0:
            print(r.stdout + r.stderr)
            ok = False
    print("\nVSG passed: no style violations found.\n" if ok else "\nVSG FAILED.")
    return ok


# ---------------------------------------------------------------------------
# The regression
# ---------------------------------------------------------------------------
def write_xunit(path, results):
    cases = []
    for (sim, job), (ok, msg, _, secs) in results.items():
        body = ("" if ok else f"<skipped message={quoteattr(msg)}/>" if ok is None
                else f"<failure message={quoteattr(msg)}>{escape(msg)}</failure>")
        name = sim + "." + ".".join(p for p in (job.config, job.test) if p)
        cases.append(f"  <testcase classname={quoteattr(job.bench)} name={quoteattr(name)} "
                     f'time="{secs:.1f}">{body}</testcase>')
    failures = sum(1 for ok, *_ in results.values() if ok is False)
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    Path(path).write_text(f'<?xml version="1.0" encoding="utf-8"?>\n<testsuite name="lockstep-rv32-soc" '
                          f'tests="{len(results)}" failures="{failures}">\n' + "\n".join(cases) + "\n</testsuite>\n",
                          encoding="utf-8")


def regression(sims, jobs, workers, compare, compile_only):
    """Returns (all passed and agreed, results), or None if a compile failed."""
    builds = sorted({j.build for j in jobs})
    for sim in sims:
        for build in builds:
            start = time.time()
            ok, err = sim.compile(build, OUT / sim.name / build / "lib")
            if not ok:
                print(f"Compile failed: {sim.name} {build}\n{err}")
                return None
            print(f"compiled {build} for {sim.name} ({time.time() - start:.0f} s)", flush=True)
    if compile_only:
        return True, {}

    def task(sim, job, broken):
        rundir = OUT / sim.name / job.build / job.name
        remove_tree(rundir)
        rundir.mkdir(parents=True)
        start = time.time()
        if job.unit in broken:
            return sim, job, (False, "elaboration failed: " + broken[job.unit][:300], [], 0.0)
        rc, out = sim.run(job, OUT / sim.name / job.build / "lib", rundir)
        (rundir / "output.txt").write_text(out or "", encoding="utf-8")
        ok, msg, lines = verdict(job, rc, out)
        if job.build == "check":
            ok, msg = expected_outcome(sim, job, ok, msg)
        return sim, job, (ok, msg, lines, time.time() - start)

    results = {}
    for sim in sims:
        mine = jobs
        broken = {}
        for build in builds:
            units = sorted({((j.bench, j.config), tuple(sorted(j.generics.items()))) for j in mine if j.build == build})
            start = time.time()
            failed = sim.elaborate([(u, dict(g)) for u, g in units], OUT / sim.name / build / "lib", workers)
            broken.update(failed)
            if sim.name == "xsim":
                print(f"elaborated {len(units)} units of {build} for xsim ({time.time() - start:.0f} s)", flush=True)
            for unit, error in failed.items():
                print(f"Elaboration failed: xsim {unit}\n{error[:1500]}")
        # With coverage, a snapshot's runs all add to its one database, so they run
        # one after another; different snapshots still run side by side
        if getattr(sim, "coverage", False):
            groups = {}
            for job in mine:
                groups.setdefault((job.build, job.unit), []).append(job)
            batches = list(groups.values())
        else:
            batches = [[job] for job in mine]
        with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
            futures = [pool.submit(lambda b, s=sim: [task(s, j, broken) for j in b], batch) for batch in batches]
            for fut in concurrent.futures.as_completed(futures):
                for s, job, res in fut.result():
                    results[(s.name, job.name)] = (job, res)
                    ok, msg, _, secs = res
                    word = {True: "pass", False: "fail", None: "skip"}[ok]
                    print(f"{word} {s.name} {job.name} ({secs:.1f} s)" + ("" if ok else f": {msg}"), flush=True)

    ok_all = True
    print()
    for sim in sims:
        mine = sorted(((n, r) for (s, n), r in results.items() if s == sim.name))
        passed = sum(1 for _, (_, r) in mine if r[0] is True)
        skipped = sum(1 for _, (_, r) in mine if r[0] is None)
        print(f"pass {passed} of {len(mine) - skipped} on {sim.name}"
              + (f"; {skipped} skipped: they force a signal, which {sim.name} cannot simulate" if skipped else ""))
        ok_all &= passed == len(mine) - skipped
        for n, (_, r) in mine:
            if r[0] is False:
                print(f"  fail {n}: {r[1]}")

    if compare and len(sims) == 2:
        differ = []
        both = [j for j in jobs if j.build != "check" and results[(sims[0].name, j.name)][1][0] is not None
                and results[(sims[1].name, j.name)][1][0] is not None]
        for job in both:
            a, b = results[(sims[0].name, job.name)][1], results[(sims[1].name, job.name)][1]
            if a[0] != b[0] or a[2] != b[2]:
                first = next((f"{x!r} / {y!r}" for x, y in zip(a[2], b[2]) if x != y), None)
                if first is None:
                    first = (f"{len(a[2])} lines / {len(b[2])} lines" if len(a[2]) != len(b[2])
                             else f"verdict {a[0]} / {b[0]}")
                differ.append(f"{job.name}: {first}")
        if differ:
            ok_all = False
            print(f"\nDIFFER: {len(differ)} of {len(both)} tests differ between {sims[0].name} and {sims[1].name}:")
            for d in differ:
                print("  " + d)
        else:
            print(f"same: all {len(both)} tests run on both gave the same verdict and the same TB lines on "
                  f"{sims[0].name} and {sims[1].name}")
    flat = {(s, job): res for (s, _), (job, res) in results.items()}
    return ok_all, flat


COVERED_RTL = ("rtl/pkg/", "rtl/safety/", "rtl/peripherals/", "rtl/soc/")
COVERAGE_KINDS = ("Statement", "Branch", "Condition", "Toggle")


def read_xcrg(folder):
    """One xcrg text report: {file: {"stmt": {line: (count, source)}, "branch": {key: {"T"/"F"/"E": count}}}}."""
    found = {}
    heading = re.compile(r"(\w+) Coverage (?:Summary )?(?:of|for) File(?: \d+)? : (.+?)\s*\|?\s*$")
    for report in sorted((folder / "codeCoverageReport").glob("file*.txt")):
        kind, rel, last_line = None, None, 0
        for line in report.read_text(encoding="utf-8", errors="replace").splitlines():
            m = heading.search(line)
            if m:
                path = m.group(2).replace("\\", "/")
                rel = path.split(ROOT.as_posix() + "/", 1)[-1]
                kind = m.group(1) if rel.startswith(COVERED_RTL) else None
                continue
            if kind not in ("Statement", "Branch"):
                continue
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            entry = found.setdefault(rel, {"stmt": {}, "branch": {}})
            if kind == "Statement":
                # line | source | execution count | statements on the line
                if len(cells) == 4 and cells[0].isdigit() and cells[3].isdigit() and not cells[1].isdigit():
                    count = int(cells[2]) if cells[2].isdigit() else 0
                    old = entry["stmt"].get(int(cells[0]), (0, cells[1]))[0]
                    entry["stmt"][int(cells[0])] = (old + count, cells[1])
            elif len(cells) >= 4:
                # line | source | Branch n count | outcomes, e.g. "25T 71F"; a missing else
                # carries its count in the last cell
                if cells[0].isdigit():
                    last_line = int(cells[0])
                if "MISSING ELSE" in cells[1]:
                    key, outcomes = (last_line, "else"), {"E": int(cells[-1]) if cells[-1].isdigit() else 0}
                elif cells[2].startswith("Branch"):
                    key = (last_line, "if")
                    outcomes = {k: int(v) for v, k in re.findall(r"(\d+)([TF])", cells[3])}
                else:
                    continue
                merged = entry["branch"].setdefault(key, {})
                for k, v in outcomes.items():
                    merged[k] = merged.get(k, 0) + v
    return found


GHDL_GCC_WSL = "~/tools/ghdl-gcc-*/bin/ghdl"


def elaboration_lines(files):
    """{file: lines run} when each file's entity is elaborated by GHDL's GCC
    backend with gcov on: the code xsim cannot count. Empty when that GHDL is
    not found. GHDL_GCC names it (and GHDL_GCC_LIBS its library path); on
    Windows it is also looked for in each WSL distribution."""
    if not files:
        return {}
    ghdl, libs, wsl = os.environ.get("GHDL_GCC"), os.environ.get("GHDL_GCC_LIBS", ""), None
    if not ghdl and os.name == "nt" and shutil.which("wsl"):
        listing = subprocess.run(["wsl", "-l", "-q"], capture_output=True)
        for name in listing.stdout.decode("utf-16-le", errors="ignore").replace("\0", "").split():
            found = subprocess.run(["wsl", "-d", name, "-e", "sh", "-c", f"ls {GHDL_GCC_WSL} 2>/dev/null | head -1"],
                                   capture_output=True, text=True).stdout.strip()
            if found:
                ghdl, wsl = found, ["wsl", "-d", name, "-e"]
                if not libs:
                    libs = subprocess.run(wsl + ["sh", "-c", "dirname $(ls ~/tools/libgnat-*/usr/lib/*/libgnat-*.so "
                                                 "2>/dev/null | head -1) 2>/dev/null"],
                                          capture_output=True, text=True).stdout.strip()
                break
    if not ghdl:
        print("note: no GHDL GCC backend for elaboration coverage (GHDL_GCC); elaboration lines stay waived")
        return {}

    def as_seen(path):
        p = Path(path).resolve()
        return "/mnt/" + p.drive[0].lower() + p.as_posix()[2:] if wsl else p.as_posix()

    result = {}
    for rel in files:
        work = OUT / "coverage" / "elaboration" / Path(rel).stem
        remove_tree(work)
        work.mkdir(parents=True)
        entity = re.search(r"^entity\s+(\w+)\s+is", (ROOT / rel).read_text(encoding="utf-8"), re.M | re.I).group(1)
        script = (f"set -e; export LD_LIBRARY_PATH={libs}; cd {as_seen(work)}; "
                  f"{ghdl} -a --std=08 --work=lockstep -g -fprofile-arcs -ftest-coverage {as_seen(ROOT / rel)}; "
                  f"{ghdl} -e --std=08 --work=lockstep -Wl,-lgcov {entity}; "
                  f"./{entity} --stop-time=0ns > /dev/null 2>&1 || true; "
                  f"gcov -o . {Path(rel).stem} > /dev/null")
        cmd = (wsl or []) + ["bash", "-c", script]
        rc = subprocess.run(cmd, capture_output=True, text=True)
        report = work / f"{Path(rel).name}.gcov"
        if rc.returncode != 0 or not report.is_file():
            print(f"note: elaboration coverage of {rel} failed:\n{(rc.stdout + rc.stderr)[-800:]}")
            continue
        lines = set()
        for line in report.read_text(encoding="utf-8", errors="replace").splitlines():
            m = re.match(r"\s*(\d+)\*?:\s*(\d+):", line)
            if m and int(m.group(1)) > 0:
                lines.add(int(m.group(2)))
        result[rel] = lines
    return result


def coverage_report(sim, builds):
    """Report every snapshot's code coverage with xcrg, merge them line by line, and
    summarise the first-party RTL: a statement is covered if any test ran it, and a
    branch outcome if any test took it. (xcrg's own merge of databases with
    different hierarchies keeps one instance per file, and loses the rest.)"""
    out = OUT / "coverage"
    remove_tree(out)
    out.mkdir(parents=True)
    xcrg = _vivado_tool(sim.bindir, "xcrg")
    dbs = []
    for build in builds:
        cc = OUT / "xsim" / build / "lib" / "codecov"
        dbs += [(build, cc, db.name) for db in sorted((cc / "xsim.codeCov").glob("*"))]

    def one(item):
        build, cc, db = item
        folder = out / "xcrg" / f"{build}.{db}"
        rc, text = run_process([xcrg, "-report_format", "text", "-cc_report", posix(folder),
                                "-cc_dir", posix(cc), "-cc_db", db], out, 3600)
        return item, rc, text, folder

    merged = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, os.cpu_count() or 4)) as pool:
        for (build, _, db), rc, text, folder in pool.map(one, dbs):
            if rc != 0:
                print(f"ERROR: xcrg failed on {build}.{db}:\n{text[-1500:]}")
                return False
            for rel, data in read_xcrg(folder).items():
                target = merged.setdefault(rel, {"stmt": {}, "branch": {}})
                for n, (count, source) in data["stmt"].items():
                    target["stmt"][n] = (target["stmt"].get(n, (0, source))[0] + count, source)
                for key, outcomes in data["branch"].items():
                    into = target["branch"].setdefault(key, {})
                    for k, v in outcomes.items():
                        into[k] = into.get(k, 0) + v

    # Statements no passing simulation can execute, each with its reason:
    # sim/coverage_waivers.txt; "*" matches every file
    waivers = []
    for line in (SIM / "coverage_waivers.txt").read_text(encoding="utf-8").splitlines():
        if line.strip() and not line.startswith("#"):
            where, _, reason = line.partition("#")
            path_part, _, pattern = where.strip().partition(" ")
            waivers.append((path_part, pattern.strip(), reason.strip()))

    def waiver(rel, source):
        return next((r for wf, wp, r in waivers if wf in (rel, "*") and source.startswith(wp)), None)

    # What elaboration runs, which xsim cannot count: GHDL's GCC backend can
    elab = elaboration_lines(sorted({wf for wf, _, _ in waivers if wf != "*"}))

    rows, missed, waived, branch_missed, at_elab = [], [], [], [], []
    for rel in sorted(merged):
        stmt, branch = merged[rel]["stmt"], merged[rel]["branch"]
        counted = hit = 0
        for n in sorted(stmt):
            count, source = stmt[n]
            reason = waiver(rel, source)
            if reason and count == 0 and n in elab.get(rel, set()):
                counted += 1
                hit += 1
                at_elab.append((rel, n, source))
                continue
            if reason and count == 0:
                waived.append((rel, n, source, reason))
                continue
            counted += 1
            hit += count > 0
            if count == 0:
                missed.append((rel, n, source))
        # A waived line's branches go with it, and so do a waived branch line's (a
        # case arm, say), matched against the source as it is
        source_lines = (ROOT / rel).read_text(encoding="utf-8").splitlines()
        skip = {n for f, n, _, _ in waived if f == rel}
        skip |= {key[0] for key in branch if 0 < key[0] <= len(source_lines)
                 and waiver(rel, source_lines[key[0] - 1].strip())
                 and all(v == 0 for v in branch[key].values())}
        outcomes = [(key, k, v) for key, d in branch.items() for k, v in d.items() if key[0] not in skip]
        b_hit = sum(1 for _, _, v in outcomes if v > 0)
        branch_missed += [(rel, key[0], k) for key, k, v in outcomes if v == 0]
        rows.append((rel, counted, hit, len(outcomes), b_hit))

    def pct(total, got):
        return f"{got} of {total} ({100.0 * got / total:.1f} %)" if total else "-"
    md = ["# RTL code coverage", "",
          "Every test of the regression on xsim (`python sim/run.py --coverage`), merged line by line",
          "over all snapshots. A statement line counts once, covered if any test ran it; a branch",
          "outcome (true, false, or a missing else) is covered if any test took it.", "",
          "| File | Statement lines | Branch outcomes |", "|------|------:|------:|"]
    tot = [0, 0, 0, 0]
    for rel, counted, hit, b_total, b_hit in rows:
        md.append(f"| `{rel}` | {pct(counted, hit)} | {pct(b_total, b_hit)} |")
        tot = [tot[0] + counted, tot[1] + hit, tot[2] + b_total, tot[3] + b_hit]
    md.append(f"| **All** | {pct(tot[0], tot[1])} | {pct(tot[2], tot[3])} |")
    md += ["", "## Statements never executed", "", "| File | Line | Source |", "|------|-----:|--------|"]
    md += [f"| `{f}` | {n} | `{s.replace('|', '/')}` |" for f, n, s in missed]
    md += ["", "## Branch outcomes never taken", "", "| File | Line | Outcome |", "|------|-----:|---------|"]
    names = {"T": "true", "F": "false", "E": "the implicit else"}
    md += [f"| `{f}` | {n} | {names[k]} |" for f, n, k in branch_missed]
    md += ["", "## Run at elaboration (counted by GHDL's GCC backend, not xsim)", "",
           "| File | Line | Source |", "|------|-----:|--------|"]
    md += [f"| `{f}` | {n} | `{s.replace('|', '/')}` |" for f, n, s in at_elab]
    md += ["", "## Waived", "", "| File | Line | Source | Why |", "|------|-----:|--------|-----|"]
    md += [f"| `{f}` | {n} | `{s.replace('|', '/')}` | {r} |" for f, n, s, r in waived]
    (out / "summary.md").write_text("\n".join(md) + "\n", encoding="utf-8")
    print("\n".join(md[:len(rows) + 9]))
    print(f"\n{len(missed)} statements never executed, {len(branch_missed)} branch outcomes never taken, "
          f"{len(at_elab)} counted at elaboration, {len(waived)} waived; the report is {out / 'summary.md'}")
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("patterns", nargs="*", help="bench.test patterns, with * and ?")
    parser.add_argument("--sim", choices=("auto", "ghdl", "xsim", "both"), default="auto")
    parser.add_argument("-p", "--jobs", type=int, default=os.cpu_count() or 4)
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--lint", action="store_true")
    parser.add_argument("--vsg", action="store_true")
    parser.add_argument("--vsg-fix", action="store_true")
    parser.add_argument("--compile", action="store_true")
    parser.add_argument("--no-compare", action="store_true")
    parser.add_argument("--no-color", action="store_true", help="accepted; the output has no colour")
    parser.add_argument("-x", "--xunit-xml")
    parser.add_argument("--coverage", action="store_true",
                        help="xsim only: code coverage of the RTL over the tests run, in sim/out/coverage")
    parser.add_argument("--coverage-report", action="store_true",
                        help="only rebuild the coverage summary from the last --coverage run's databases")
    args = parser.parse_args()
    if args.coverage_report:
        vivado = find_vivado()
        if not vivado:
            print("ERROR: Vivado not found.")
            return 1
        builds = sorted(b for b in BUILDS if (OUT / "xsim" / b / "lib" / "codecov").is_dir())
        return 0 if coverage_report(Xsim(vivado), builds) else 1
    if args.coverage:
        args.sim = "xsim"
        args.no_compare = True

    ghdl = find_ghdl()
    if args.vsg or args.vsg_fix:
        return 0 if run_vsg(fix=args.vsg_fix) else 1
    if args.lint:
        if not ghdl:
            print("ERROR: GHDL not found.")
            return 1
        return 0 if ghdl_lint(ghdl) else 1

    jobs = select(discover(), args.patterns)
    if args.list:
        for job in jobs:
            print(job.name)
        print(f"{len(jobs)} tests")
        return 0
    if not jobs:
        print("No test matches.")
        return 1

    vivado = find_vivado()
    wanted = {"auto": ("ghdl", "xsim"), "both": ("ghdl", "xsim"), "ghdl": ("ghdl",), "xsim": ("xsim",)}[args.sim]
    sims = []
    if "ghdl" in wanted:
        if ghdl:
            sims.append(Ghdl(ghdl))
        elif args.sim != "auto":
            print("ERROR: GHDL not found.")
            return 1
    if "xsim" in wanted:
        if vivado:
            sims.append(Xsim(vivado, coverage=args.coverage))
        elif args.sim != "auto":
            print("ERROR: Vivado not found. Set VIVADO_BIN to its bin folder.")
            return 1
    if not sims:
        print("ERROR: no simulator found.")
        return 1
    print("Simulators: " + ", ".join(f"{s.name} ({ghdl if s.name == 'ghdl' else vivado})" for s in sims), flush=True)

    if not os.environ.get("LOCKSTEP_NO_LINT") and not args.patterns and not args.compile:
        if not ghdl or not ghdl_lint(ghdl) or not run_vsg():
            return 1

    outcome = regression(sims, jobs, max(1, args.jobs), not args.no_compare, args.compile)
    if outcome is None:
        return 1
    ok, results = outcome
    if args.xunit_xml and results:
        write_xunit(args.xunit_xml, results)
    if args.coverage and results:
        ok &= coverage_report(sims[0], sorted({j.build for j in jobs}))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
