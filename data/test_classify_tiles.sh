#!/bin/bash

if [[ $# -ne 1 ]]; then
   echo "$0 {classify_tiles.exe}"
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

function compare
{
   expected=$1
   actual=$2
   pngtopnm "$expected" | ppmtoppm | pamdepth 255 > "$TEST_DIR/expected.ppm"
   pngtopnm "$actual" | ppmtoppm | pamdepth 255 > "$TEST_DIR/actual.ppm"
   if ! ( diff -q --binary "$TEST_DIR/expected.ppm" "$TEST_DIR/actual.ppm" ); then
      die "Mismatched pixels"
   fi

   pngtopnm -alpha "$expected" | ppmtoppm | pamdepth 255 > "$TEST_DIR/expected.ppm"
   pngtopnm -alpha "$actual" | ppmtoppm | pamdepth 255 > "$TEST_DIR/actual.ppm"
   if ! ( diff -q --binary "$TEST_DIR/expected.ppm" "$TEST_DIR/actual.ppm" ); then
      die "Mismatched alpha"
   fi
}

# Generate input images.
#
# i1.png:         i2.png:
# [00][11][00]    [11][00][00][11][11][11][11][11]
# [11][11][11]    [11][11][11][11][11][11][11][11]
# [22][00][00]
pgmmake 0 32 32 > "$TEST_DIR/z.pgm"
pnmtopng -alpha="$TEST_DIR/z.pgm" "$TEST_DIR/z.pgm" > "$TEST_DIR/blank.png"
pgmmake 1 32 32 | pnmtopng > "$TEST_DIR/t1.png"
convert "$TEST_DIR/blank.png" \
   -fill white -draw "rectangle 0,15 31,16" \
   "$TEST_DIR/t2.png"

convert \
   "(" "$TEST_DIR/blank.png" \
       "$TEST_DIR/t1.png" \
       "$TEST_DIR/blank.png" \
       +append ")" \
   "(" "$TEST_DIR/t1.png" \
       "$TEST_DIR/t1.png" \
       "$TEST_DIR/t1.png" \
       +append ")" \
   "(" "$TEST_DIR/t2.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       +append ")" \
   -append \
   "$TEST_DIR/i1.png"

convert \
   "(" "$TEST_DIR/t1.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/t1.png" \
       "$TEST_DIR/t1.png" \
       "$TEST_DIR/t1.png" \
       "$TEST_DIR/t1.png" \
       "$TEST_DIR/t1.png" \
       +append ")" \
   "(" "$TEST_DIR/t1.png" \
       "$TEST_DIR/t1.png" \
       "$TEST_DIR/t1.png" \
       "$TEST_DIR/t1.png" \
       "$TEST_DIR/t1.png" \
       "$TEST_DIR/t1.png" \
       "$TEST_DIR/t1.png" \
       "$TEST_DIR/t1.png" \
       +append ")" \
   -append \
   "$TEST_DIR/i2.png"

# Generate expected output images.
convert "$TEST_DIR/i1.png" \
   -colorspace RGB \
   -fill "xc:#00ff00" -draw "rectangle 32,0 63,31" \
   -fill "xc:#ff00ff" -draw "rectangle 0,79 31,80" \
   "$TEST_DIR/expected_i1.png"

convert "$TEST_DIR/i2.png" \
   -colorspace RGB \
   "$TEST_DIR/expected_i2.png"

cat <<EOT > "$TEST_DIR/expected_stats.txt"
tile table size = 2
$TEST_DIR/i1.png: 5 tiles, 2 new, 1 unique, 0 rare, 0 sparse, 0 uncommon, 1 common
$TEST_DIR/i2.png: 14 tiles, 0 new, 0 unique, 0 rare, 0 sparse, 0 uncommon, 0 common
EOT

# Run tool.
"./$TOOL" "$TEST_DIR/i1.png" "$TEST_DIR/i2.png" > "$TEST_DIR/actual_stats.txt"

# Check output.
compare "$TEST_DIR/expected_i1.png" "$TEST_DIR/t_tiles_i1.png"
compare "$TEST_DIR/expected_i2.png" "$TEST_DIR/t_tiles_i2.png"
diff "$TEST_DIR/expected_stats.txt" "$TEST_DIR/actual_stats.txt" \
   || die "Stats mismatched"

# Cleanup.
rm -rf "$TEST_DIR"
exit 0
