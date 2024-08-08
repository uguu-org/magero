#!/bin/bash

if [[ $# -ne 1 ]]; then
   echo "$0 {list_annotated_tiles.exe}"
   exit 1
fi
TOOL=$1

set -euo pipefail

# Generate test input.
#     (rr)(gg)(yy)(cc)(mm)  b
#     [rr]        [cc][mm]   b
#
INPUT=$(mktemp --suffix=.png)
convert \
   -size 256x96 xc:"rgba(0,0,0,0)" \
   -fill red     -draw "circle 48,16 48,8" \
   -fill green   -draw "circle 80,16 80,8" \
   -fill yellow  -draw "circle 112,16 112,8" \
   -fill cyan    -draw "circle 144,16 144,8" \
   -fill magenta -draw "circle 176,16 176,8" \
   -fill blue    -draw "circle 223,16 223,8" \
   -fill red     -draw "rectangle 40,40 55,55" \
   -fill cyan    -draw "rectangle 136,40 151,55" \
   -fill magenta -draw "rectangle 168,40 183,55" \
   -fill blue    -draw "circle 240,64 240,56" \
   "$INPUT"

# Generate expected output.
EXPECTED_OUTPUT=$(mktemp --suffix=.txt)
cat <<EOT > "$EXPECTED_OUTPUT"
32,0: breakable
64,0: collectible
96,0: throwable
128,0: chain reaction
160,0: breakable chain reaction
223,16: starting position
32,32: ghost collision
128,32: terminal reaction
160,32: terminal breakable chain reaction
240,64: teleport station
EOT

# Run tool and check output.
if ! ( "./$TOOL" "$INPUT" | diff "$EXPECTED_OUTPUT" - ); then
   echo "Output mismatched"
   rm -f "$INPUT" "$EXPECTED_OUTPUT"
   exit 1
fi

# Cleanup.
rm -f "$INPUT" "$EXPECTED_OUTPUT"
exit 0
