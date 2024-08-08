#!/bin/bash

if [[ $# -ne 1 ]]; then
   echo "$0 {show_empty_tiles.exe}"
   exit 1
fi
TOOL=$1
TEST_DIR=$(mktemp -d)

set -euo pipefail

function die
{
   echo "$1"
   rm -rf "$TEST_DIR"
   exit 1
}


# Generate input:
# [nonempty] [empty]    [nonempty]
# [empty]    [empty]    [empty]
# [nonempty] [empty]    [nonempty]
# [nonempty] [nonempty] [empty]
# [nonempty] [nonempty] [empty]
convert \
   -size 96x160 xc:"rgba(0,0,0,0)" \
   -fill black -draw "rectangle 31,31 31,31" \
   -fill black -draw "rectangle 64,31 64,31" \
   -fill black -draw "rectangle 31,64 31,64" \
   -fill black -draw "rectangle 64,64 64,64" \
   -fill white -draw "rectangle 0,96 63,159" \
   -fill xc:"rgba(255,255,255,0)" -draw "rectangle 64,96 95,159" \
   -depth 8 \
   "$TEST_DIR/input.png"

convert \
   -size 96x160 xc:"rgba(0,0,0,255)" \
   -fill white -draw "rectangle   32,0  63,31" \
   -fill white -draw "rectangle   0,32  95,63" \
   -fill white -draw "rectangle  32,64  63,95" \
   -fill white -draw "rectangle  64,96 95,159" \
   -depth 8 \
   "$TEST_DIR/expected_pixels.png"

convert \
   -size 96x160 xc:"rgba(255,255,255,255)" \
   -depth 8 \
   "$TEST_DIR/expected_alpha.png"

# Run tool.
"./$TOOL" "$TEST_DIR/input.png" "$TEST_DIR/output.png" \
   || due "$LINENO: $TOOL failed: $?"

# Check output.
expected=$(pngtopnm "$TEST_DIR/expected_pixels.png" | ppmtopgm | md5sum)
actual=$(pngtopnm "$TEST_DIR/output.png" | ppmtopgm | md5sum)
if [[ "$expected" != "$actual" ]]; then
   die "$LINENO: pixels mismatched"
fi

expected=$(pngtopnm "$TEST_DIR/expected_alpha.png" | ppmtopgm | md5sum)
actual=$(pngtopnm -alpha "$TEST_DIR/output.png" | ppmtopgm | md5sum)
if [[ "$expected" != "$actual" ]]; then
   die "$LINENO: alpha mismatched"
fi

# Test stdin/stdout.
cat "$TEST_DIR/input.png" | "./$TOOL" - "$TEST_DIR/output1.png"
if ! ( diff -q "$TEST_DIR/output.png" "$TEST_DIR/output1.png" ); then
   die "$LINENO: error reading from stdin"
fi
"./$TOOL" "$TEST_DIR/input.png" - > "$TEST_DIR/output2.png"
if ! ( diff -q "$TEST_DIR/output.png" "$TEST_DIR/output2.png" ); then
   die "$LINENO: error writing to stdout"
fi

# Dimension check.
convert -size 32x31 xc:"rgba(0,0,0,0)" -depth 8 "$TEST_DIR/bad_height.png"
"./$TOOL" "$TEST_DIR/bad_height.png" /dev/null > "$TEST_DIR/error1.txt" \
   && die "$LINENO: unexpected success"
if ! ( grep -q "Image dimension" "$TEST_DIR/error1.txt" ); then
   die "$LINENO: missing expected error message"
fi
convert -size 65x32 xc:"rgba(0,0,0,0)" -depth 8 "$TEST_DIR/bad_width.png"
"./$TOOL" "$TEST_DIR/bad_width.png" /dev/null > "$TEST_DIR/error2.txt" \
   && die "$LINENO: unexpected success"
if ! ( grep -q "Image dimension" "$TEST_DIR/error2.txt" ); then
   die "$LINENO: missing expected error message"
fi

# Cleanup.
rm -rf "$TEST_DIR"
exit 0
