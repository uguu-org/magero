#!/bin/bash

if [[ $# -ne 1 ]]; then
   echo "$0 {remove_mutable_bg.exe}"
   exit 1
fi
TOOL=$1

set -euo pipefail
TEST_DIR=$(mktemp -d)

function die
{
   echo "$1"
   rm -rf "$TEST_DIR"
   exit 1
}

# Generate test image.
# [##][##][##][##][##][##]
# [##][##][##][##][##][##]
pgmmake 0 192 64 > "$TEST_DIR/z.pgm"
pnmtopng "$TEST_DIR/z.pgm" > "$TEST_DIR/input.png"

# Generate test metadata.
#     (rr)(gg)(yy)(cc)(mm)
#     [rr][gg]    [cc][mm]
convert "$TEST_DIR/input.png" \
   -fill red     -draw "circle 48,16 48,8" \
   -fill green   -draw "circle 80,16 80,8" \
   -fill yellow  -draw "circle 112,16 112,8" \
   -fill cyan    -draw "circle 144,16 144,8" \
   -fill magenta -draw "circle 176,16 176,8" \
   -fill red     -draw "rectangle 40,40 55,55" \
   -fill green   -draw "rectangle 72,40 87,55" \
   -fill cyan    -draw "rectangle 136,40 151,55" \
   -fill magenta -draw "rectangle 168,40 183,55" \
   "$TEST_DIR/metadata.png"

# Generate expected output.
# [##]            [##][##]
# [##][##]    [##][##][##]
pnmtopng -alpha="$TEST_DIR/z.pgm" "$TEST_DIR/z.pgm" > "$TEST_DIR/z.png"
convert "$TEST_DIR/z.png" \
   -fill black -draw "rectangle 0,0 31,31" \
   -fill black -draw "rectangle 128,0 191,31" \
   -fill black -draw "rectangle 0,32 63,63" \
   -fill black -draw "rectangle 96,32 191,63" \
   "$TEST_DIR/expected.png"

# Run tool.
"./$TOOL" \
   "$TEST_DIR/metadata.png" \
   "$TEST_DIR/input.png" \
   "$TEST_DIR/actual.png" \
   || die "$LINENO: $TOOL failed: $?"

# Compare pixels.
pngtopnm "$TEST_DIR/expected.png" | pamdepth 255 > "$TEST_DIR/expected.ppm"
pngtopnm "$TEST_DIR/actual.png" | pamdepth 255 > "$TEST_DIR/actual.ppm"
if ! ( diff -q --binary "$TEST_DIR/expected.ppm" "$TEST_DIR/actual.ppm" ); then
   die "$LINENO: Mismatched pixels"
fi

# Compare alpha.
pngtopnm -alpha "$TEST_DIR/expected.png" | pamdepth 255 > "$TEST_DIR/expected.ppm"
pngtopnm -alpha "$TEST_DIR/actual.png" | pamdepth 255 > "$TEST_DIR/actual.ppm"
if ! ( diff -q --binary "$TEST_DIR/expected.ppm" "$TEST_DIR/actual.ppm" ); then
   die "$LINENO: Mismatched alpha"
fi

# Cleanup.
rm -rf "$TEST_DIR"
exit 0
