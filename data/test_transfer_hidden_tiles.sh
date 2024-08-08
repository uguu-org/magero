#!/bin/bash

if [[ $# -ne 1 ]]; then
   echo "$0 {transfer_hidden_tiles.exe}"
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

# Bottom input:
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
   -fill "xc:#444444" -draw "rectangle 0,64 31,74" \
   -fill "xc:#555555" -draw "rectangle 64,64 95,95" \
   -fill "xc:#666666" -draw "rectangle 96,96 106,106" \
   "$TEST_DIR/bottom.png"

# Top input:
# [77]    [88]
#
# [99]    [aa]
#             [bb]
convert "$TEST_DIR/bg.png" \
   -fill "xc:#777777" -draw "rectangle 0,0 31,31" \
   -fill "xc:#888888" -draw "rectangle 64,0 95,31" \
   -fill "xc:#999999" -draw "rectangle 0,64 31,80" \
   -fill "xc:#aaaaaa" -draw "rectangle 64,64 80,95" \
   -fill "xc:#bbbbbb" -draw "rectangle 96,96 108,128" \
   "$TEST_DIR/top.png"

# Bottom output:
# [77][11][88]
# [33]
# [99]    [55]          [44] is fully hidden.  [55] is partially visible.
#             [bb]      [66] is fully hidden.
convert "$TEST_DIR/bg.png" \
   -fill "xc:#777777" -draw "rectangle 0,0 31,31" \
   -fill "xc:#111111" -draw "rectangle 32,0 63,31" \
   -fill "xc:#888888" -draw "rectangle 64,0 95,31" \
   -fill "xc:#333333" -draw "rectangle 0,32 31,63" \
   -fill "xc:#999999" -draw "rectangle 0,64 31,80" \
   -fill "xc:#555555" -draw "rectangle 64,64 95,95" \
   -fill "xc:#bbbbbb" -draw "rectangle 96,96 108,128" \
   "$TEST_DIR/expected_bottom.png"

# Top output:
#
#
#         [aa]
#
convert "$TEST_DIR/bg.png" \
   -fill "xc:#aaaaaa" -draw "rectangle 64,64 80,95" \
   "$TEST_DIR/expected_top.png"

# Run tool.
"./$TOOL" \
   "$TEST_DIR/top.png" \
   "$TEST_DIR/bottom.png" \
   "$TEST_DIR/actual_top.png" \
   "$TEST_DIR/actual_bottom.png" \
   || die "$LINENO: $TOOL failed: $?"

# Compare pixels.
pngtopnm "$TEST_DIR/expected_bottom.png" \
   | pamdepth 255 > "$TEST_DIR/expected.ppm"
pngtopnm "$TEST_DIR/actual_bottom.png" \
   | pamdepth 255 > "$TEST_DIR/actual.ppm"
if ! ( diff -q --binary "$TEST_DIR/expected.ppm" "$TEST_DIR/actual.ppm" ); then
   die "$LINENO: Mismatched pixels"
fi
pngtopnm "$TEST_DIR/expected_top.png" \
   | pamdepth 255 > "$TEST_DIR/expected.ppm"
pngtopnm "$TEST_DIR/actual_top.png" \
   | pamdepth 255 > "$TEST_DIR/actual.ppm"
if ! ( diff -q --binary "$TEST_DIR/expected.ppm" "$TEST_DIR/actual.ppm" ); then
   die "$LINENO: Mismatched pixels"
fi

# Compare alpha.
pngtopnm -alpha "$TEST_DIR/expected_bottom.png" \
   | pamdepth 255 > "$TEST_DIR/expected.ppm"
pngtopnm -alpha "$TEST_DIR/actual_bottom.png" \
   | pamdepth 255 > "$TEST_DIR/actual.ppm"
if ! ( diff -q --binary "$TEST_DIR/expected.ppm" "$TEST_DIR/actual.ppm" ); then
   die "$LINENO: Mismatched alpha"
fi
pngtopnm -alpha "$TEST_DIR/expected_top.png" \
   | pamdepth 255 > "$TEST_DIR/expected.ppm"
pngtopnm -alpha "$TEST_DIR/actual_top.png" \
   | pamdepth 255 > "$TEST_DIR/actual.ppm"
if ! ( diff -q --binary "$TEST_DIR/expected.ppm" "$TEST_DIR/actual.ppm" ); then
   die "$LINENO: Mismatched alpha"
fi

# Test reading from stdin.
cat "$TEST_DIR/top.png" \
   | "./$TOOL" - "$TEST_DIR/bottom.png" "$TEST_DIR/1a.png" "$TEST_DIR/1b.png" \
   || die "$LINENO: $TOOL failed: $?"
if ! ( diff -q --binary "$TEST_DIR/actual_top.png" "$TEST_DIR/1a.png" ); then
   die "$LINENO: Bad handling of stdin"
fi
if ! ( diff -q --binary "$TEST_DIR/actual_bottom.png" "$TEST_DIR/1b.png" ); then
   die "$LINENO: Bad handling of stdin"
fi
cat "$TEST_DIR/bottom.png" \
   | "./$TOOL" "$TEST_DIR/top.png" - "$TEST_DIR/2a.png" "$TEST_DIR/2b.png" \
   || die "$LINENO: $TOOL failed: $?"
if ! ( diff -q --binary "$TEST_DIR/actual_top.png" "$TEST_DIR/2a.png" ); then
   die "$LINENO: Bad handling of stdin"
fi
if ! ( diff -q --binary "$TEST_DIR/actual_bottom.png" "$TEST_DIR/2b.png" ); then
   die "$LINENO: Bad handling of stdin"
fi

# Cleanup.
rm -rf "$TEST_DIR"
exit 0
