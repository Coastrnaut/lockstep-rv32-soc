"""Wrapper: convert Windows backslash -P/--workdir paths to forward slashes
for GHDL 6.0.0 in MSYS bash which cannot parse C:\\... paths."""
import os
import sys

REAL_GHDL = os.path.join(os.environ.get("USERPROFILE", ""),
                         "..", "GIT", "ghdl-mcode-6.0.0-ucrt64",
                         "bin", "ghdl.exe")
REAL_GHDL = os.path.abspath(REAL_GHDL)

def convert_path(p):
    return p.replace("\\", "/")

args = []
i = 0
while i < len(sys.argv):
    arg = sys.argv[i]
    if arg.startswith("-P"):
        if len(arg) > 2:
            args.append(f"-P{convert_path(arg[2:])}")
        else:
            i += 1
            if i < len(sys.argv):
                args.append(f"-P{convert_path(sys.argv[i])}")
    elif arg.startswith("--workdir="):
        args.append(f"--workdir={convert_path(arg[10:])}")
    else:
        args.append(arg)
    i += 1

os.execv(REAL_GHDL, [REAL_GHDL] + args)
