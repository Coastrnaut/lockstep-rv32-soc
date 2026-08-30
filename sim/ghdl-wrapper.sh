#!/bin/bash
# ghdl-wrapper.sh: Convert Windows backslash -P paths to forward slashes
# for GHDL 6.0.0 in MSYS bash, which cannot parse C:\... paths.
REAL_GHDL="/c/GIT/ghdl-mcode-6.0.0-ucrt64/bin/ghdl.exe"
args=()
for arg in "$@"; do
    # Convert -P with backslashes
    if [[ "$arg" == -P* && "$arg" == *\\* ]]; then
        # Strip -P, convert path, re-add -P
        path="${arg#-P}"
        path="${path//\\/\/}"
        args+=("-P$path")
    else
        args+=("$arg")
    fi
done
exec "$REAL_GHDL" "${args[@]}"
