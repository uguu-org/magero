#!/bin/bash

if [[ $# -ne 1 ]]; then
   echo "$0 {remove_hidden_tiles.exe}"
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

# Generate test input:
#     [11][22]          [22] is fully hidden.
# [33]
# [44]    [55]          [44] is fully hidden.  [55] is partially visible.
#             [66]      [66] is fully hidden.
pgmmake 0 128 128 > "$TEST_DIR/z.pgm"
pnmtopng -alpha="$TEST_DIR/z.pgm" "$TEST_DIR/z.pgm" > "$TEST_DIR/bg.png"
convert "$TEST_DIR/bg.png" \
   -fill "xc:#111111" -draw "rectangle 32,0 63,31" \
   -fill "xc:#222222" -draw "rectangle 64,0 95,31" \
   -fill "xc:#333333" -draw "rectangle 0,32 31,63" \
   -fill "xc:#444444" -draw "rectangle 0,64 31,95" \
   -fill "xc:#555555" -draw "rectangle 64,64 74,74" \
   -fill "xc:#666666" -draw "rectangle 96,96 106,106" \
   "$TEST_DIR/bottom.png"
convert "$TEST_DIR/bg.png" \
   -fill "xc:#111111" -draw "rectangle 32,0 63,31" \
   -fill "xc:#444444" -draw "rectangle 0,64 31,95" \
   -fill "xc:#555555" -draw "rectangle 64,64 96,66" \
   -fill "xc:#666666" -draw "rectangle 96,96 108,128" \
   "$TEST_DIR/top.png"
convert "$TEST_DIR/bg.png" \
   -fill "xc:#222222" -draw "rectangle 64,0 95,31" \
   -fill "xc:#333333" -draw "rectangle 0,32 31,63" \
   -fill "xc:#555555" -draw "rectangle 64,64 74,74" \
   "$TEST_DIR/expected.png"

# Run tool.
"./$TOOL" \
   "$TEST_DIR/top.png" \
   "$TEST_DIR/bottom.png" \
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

# Test reading from stdin.
cat "$TEST_DIR/top.png" \
   | "./$TOOL" - "$TEST_DIR/bottom.png" "$TEST_DIR/output1.png" \
   || die "$LINENO: $TOOL failed: $?"
if ! ( diff -q --binary "$TEST_DIR/actual.png" "$TEST_DIR/output1.png" ); then
   die "$LINENO: Bad handling of stdin"
fi
cat "$TEST_DIR/bottom.png" \
   | "./$TOOL" "$TEST_DIR/top.png" - "$TEST_DIR/output2.png" \
   || die "$LINENO: $TOOL failed: $?"
if ! ( diff -q --binary "$TEST_DIR/actual.png" "$TEST_DIR/output2.png" ); then
   die "$LINENO: Bad handling of stdin"
fi

# Test writing to stdout.
"./$TOOL" \
   "$TEST_DIR/top.png" \
   "$TEST_DIR/bottom.png" \
   - > "$TEST_DIR/output3.png" \
   || die "$LINENO: $TOOL failed: $?"
if ! ( diff -q --binary "$TEST_DIR/actual.png" "$TEST_DIR/output3.png" ); then
   die "$LINENO: Bad handling of stdout"
fi

# Cleanup.
rm -rf "$TEST_DIR"
exit 0
