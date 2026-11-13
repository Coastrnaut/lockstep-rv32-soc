#!/usr/bin/env python3
"""Write the VSG configuration: every rule, defined and enabled.

    python sim/scripts/vsg_config.py

VSG (pinned in sim/requirements.txt) has 972 rules in its rule groups. This
script asks the installed VSG for the definition of every one (vsg -oc), turns
every rule on, sets the options that describe this repository's conventions,
and writes:

    sim/vsg_config.yaml     every rule with every option, for all first-party VHDL
    sim/vsg_testbench.yaml  the few rules VUnit benches cannot follow, read after
                            sim/vsg_config.yaml for the files in sim/testbenches

A rule is off only for a reason given in OFF or BENCH_OFF below: it is the
alternative half of a pair that no name can satisfy together (a prefix rule
and a suffix rule for the same kind of name), or it would change behaviour.
Every rule's severity is Error. sim/scripts/check_fixtures.py regenerates both
files and fails if they differ, so a rule cannot be switched off by editing the
YAML by hand.
"""
import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CONFIG = ROOT / "sim" / "vsg_config.yaml"
BENCH = ROOT / "sim" / "vsg_testbench.yaml"

# Options that state this repository's conventions
OPTIONS = {
    "alias_declaration_600": {"prefixes": ["a_"]},
    "architecture_025": {"names": ["rtl", "structural", "behavior", "tb"]},
    "block_601": {"prefixes": ["b_"]},
    "constant_015": {"prefixes": ["c_", "st_"]},
    "generate_017": {"prefixes": ["gen_"]},
    "generic_020": {"prefixes": ["g_"], "exceptions": ["runner_cfg"]},
    "generic_map_601": {"prefixes": ["g_"], "exceptions": ["runner_cfg"]},
    "instantiation_034": {"method": "entity"},
    "instantiation_036": {"action": "remove"},
    "instantiation_601": {"prefixes": ["i_"]},
    "loop_statement_600": {"prefixes": ["loop_"]},
    "loop_statement_602": {"prefixes": ["lv_"]},
    "package_016": {"suffixes": ["_pkg", "_types"]},
    "port_025": {"suffixes": ["_i", "_o", "_io"]},
    "port_605": {"suffixes": ["_i"]},
    "port_606": {"suffixes": ["_o"]},
    "port_607": {"suffixes": ["_io"]},
    "process_029": {"clock": "edge"},
    "process_036": {"prefixes": ["p_"]},
    "signal_008": {"prefixes": ["w_", "r_"]},
    "subtype_004": {"prefixes": ["t_"]},
    "type_015": {"prefixes": ["t_"]},
    "use_clause_001": {"names": ["std_logic_arith", "std_logic_unsigned", "std_logic_signed"]},
    "variable_012": {"prefixes": ["v_"]},
}

_PREFIXED = "this repository names these with a prefix ({}), and no name can carry both"
OFF = {
    "after_001": "adds `after 1 ns` to every clocked assignment: a simulation-only delay that "
                 "would move every register's update and the benches' sampling with it",
    "after_003": "the same delay for unclocked assignments",
    "alias_declaration_601": _PREFIXED.format("alias_declaration_600"),
    "block_600": _PREFIXED.format("block_601"),
    "constant_600": _PREFIXED.format("constant_015"),
    "generate_600": _PREFIXED.format("generate_017"),
    "generate_602": _PREFIXED.format("generate_601"),
    "generic_600": _PREFIXED.format("generic_020"),
    "generic_map_600": _PREFIXED.format("generic_map_601"),
    "instantiation_600": _PREFIXED.format("instantiation_601"),
    "interface_incomplete_type_declaration_601": _PREFIXED.format("interface_incomplete_type_declaration_600"),
    "loop_statement_601": _PREFIXED.format("loop_statement_600"),
    "loop_statement_603": _PREFIXED.format("loop_statement_602"),
    "package_017": "packages are named with a suffix (package_016), and no name can carry both",
    "package_body_601": "package bodies follow their package's suffix (package_body_600)",
    "package_instantiation_601": "follows package_instantiation_600's suffix",
    "process_600": _PREFIXED.format("process_036"),
    "signal_600": _PREFIXED.format("signal_008"),
    "subtype_600": _PREFIXED.format("subtype_004"),
    "type_600": _PREFIXED.format("type_015"),
    "variable_600": _PREFIXED.format("variable_012"),
    "function_600": "functions and procedures are named for what they do, with no prefix or suffix "
                    "(function_601 is the suffix alternative)",
    "function_601": "see function_600",
    "port_011": "ports are named with a direction suffix (port_025, port_605 to port_607), and no "
                "port can carry both a prefix and a suffix",
    "port_600": "see port_011", "port_601": "see port_011", "port_602": "see port_011",
    "port_603": "buffer ports are not used; a prefix contradicts the suffix rules (port_011)",
    "port_604": "linkage ports are not used; see port_603",
    "port_608": "buffer ports are not used, and the suffix rule port_025 lists the allowed suffixes",
    "port_609": "linkage ports are not used; see port_608",
}

# For files in sim/testbenches only, read after sim/vsg_config.yaml
BENCH_OFF = {
    "signal_008": "bench signals carry the name of the DUT port they drive or watch, so a "
                  "failing check names the port",
    "alias_declaration_600": "aliases of external names keep the name of the RTL signal they reach",
    "length_003": "VUnit runs every test of a bench from one process, so a bench's process grows "
                  "with its test count",
}

GROUPS = ["after", "alias_declaration", "architecture", "assert", "attribute", "block", "case",
          "comment", "component", "concurrent", "constant", "context", "entity", "exit", "file",
          "function", "generate", "generic", "if", "instantiation", "library", "loop_statement",
          "package", "port", "procedure", "process", "range", "report", "return", "sequential",
          "signal", "subtype", "type", "use_clause", "variable", "wait", "whitespace"]


def defaults():
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / "rules.json"
        subprocess.run(["vsg", "-oc", str(out)], check=True, capture_output=True)
        data = json.loads(out.read_text(encoding="utf-8"))
    version = subprocess.run(["vsg", "--version"], capture_output=True, text=True).stdout.strip()
    return data, version


def scalar(value):
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return str(value)
    return json.dumps(str(value))


def emit(name, cfg, lines, reason=None):
    if reason:
        lines.append(f"  # off: {reason}")
    lines.append(f"  {name}:")
    for key in sorted(cfg):
        value = cfg[key]
        if isinstance(value, list):
            lines.append(f"    {key}: [{', '.join(scalar(v) for v in value)}]")
        elif isinstance(value, dict):
            lines.append(f"    {key}:")
            for k2 in sorted(value):
                lines.append(f"      {k2}: {scalar(value[k2])}")
        else:
            lines.append(f"    {key}: {scalar(value)}")


def main():
    data, version = defaults()
    rules = data["rule"]
    unknown = sorted((set(OPTIONS) | set(OFF) | set(BENCH_OFF)) - set(rules))
    if unknown:
        sys.exit(f"rules not in this VSG: {unknown}")

    lines = [
        "# Generated by sim/scripts/vsg_config.py from " + version.splitlines()[0] + ". Do not edit:",
        "# change the script. Every VSG rule is listed with all of its options. Every rule",
        "# is on, at severity Error, except the few marked 'off' with their reason.",
        "# Indentation is VSG's default.",
        "",
    ]
    lines += ["rule:"]
    enabled = 0
    for name in sorted(rules):
        cfg = {k: v for k, v in rules[name].items() if k not in ("fixable", "phase")}
        cfg.update(OPTIONS.get(name, {}))
        cfg["disable"] = name in OFF
        cfg["severity"] = "Error"
        enabled += name not in OFF
        emit(name, cfg, lines, OFF.get(name))
    CONFIG.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")

    bench = [
        "# Generated by sim/scripts/vsg_config.py. Read after sim/vsg_config.yaml for the",
        "# VUnit benches in sim/testbenches; it turns off only these rules there.",
        "",
        "rule:",
    ]
    for name in sorted(BENCH_OFF):
        bench.append(f"  # off in benches: {BENCH_OFF[name]}")
        bench.append(f"  {name}:")
        bench.append("    disable: true")
    BENCH.write_text("\n".join(bench) + "\n", encoding="utf-8", newline="\n")
    print(f"{len(rules)} rules: {enabled} on, {len(OFF)} off; {len(BENCH_OFF)} more off in benches")


if __name__ == "__main__":
    main()
