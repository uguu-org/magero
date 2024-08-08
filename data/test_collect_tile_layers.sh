#!/bin/bash

if [[ $# -ne 1 ]]; then
   echo "$0 {collect_tile_layers.exe}"
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

# Generate layer 1.
# [##][##][rr]
# [##][##][##]
convert \
   -size 96x64 xc:"rgba(0,0,0,0)" \
   -fill red -draw "rectangle 64,0 95,31" \
   "$TEST_DIR/layer1.png"

# Generate layer 2.
# [##][##][gg]
# [gg][##][##]
convert \
   -size 96x64 xc:"rgba(0,0,0,0)" \
   -fill green -draw "rectangle 64,0 95,31" \
   -fill green -draw "rectangle 0,32 31,63" \
   "$TEST_DIR/layer2.png"

# Generate layer 3.
# (bb)[##][##]
# [##][##](bb)
convert \
   -size 96x64 xc:"rgba(0,0,0,0)" \
   -fill blue -draw "circle 16,16 16,10" \
   -fill blue -draw "circle 80,48 80,38" \
   "$TEST_DIR/layer3.png"

# Generate input coordinates.
cat <<EOT > "$TEST_DIR/points.txt"
64,0
0,32
0,0
64,32
EOT

# Generate expected output.
# [rr][gg][##]
# [##][gg][##]
# [##][##](bb)
# [##][##](bb)
convert \
   -size 96x128 xc:"rgba(0,0,0,0)" \
   -fill red   -draw "rectangle 0,0    31,31" \
   -fill green -draw "rectangle 32,0   63,31" \
   -fill green -draw "rectangle 32,32  63,63" \
   -fill blue  -draw "circle    80,80  80,74" \
   -fill blue  -draw "circle    80,112 80,102" \
   "$TEST_DIR/expected.png"

# Run tool.
"./$TOOL" \
   "$TEST_DIR/output.png" \
   "$TEST_DIR/points.txt" \
   "$TEST_DIR/layer1.png" \
   "$TEST_DIR/layer2.png" \
   "$TEST_DIR/layer3.png" \
   || die "$TOOL failed: $?"

# Trim the label column output.  We don't check the labels since it
# depends on local font settings.
convert "$TEST_DIR/output.png" -crop "96x128+160+0" "$TEST_DIR/actual.png"

# Compare pixels.
pngtopnm "$TEST_DIR/expected.png" | pamdepth 255 > "$TEST_DIR/expected.ppm"
pngtopnm "$TEST_DIR/actual.png" | pamdepth 255 > "$TEST_DIR/actual.ppm"
if ! ( diff -q --binary "$TEST_DIR/expected.ppm" "$TEST_DIR/actual.ppm" ); then
   die "Mismatched pixels"
fi

# Compare alpha.
pngtopnm -alpha "$TEST_DIR/expected.png" | pamdepth 255 > "$TEST_DIR/expected.ppm"
pngtopnm -alpha "$TEST_DIR/actual.png" | pamdepth 255 > "$TEST_DIR/actual.ppm"
if ! ( diff -q --binary "$TEST_DIR/expected.ppm" "$TEST_DIR/actual.ppm" ); then
   die "Mismatched alpha"
fi

# Verify that bad input files are flagged.
echo "no points" > "$TEST_DIR/points.txt"
"./$TOOL" \
   "$TEST_DIR/output.png" \
   "$TEST_DIR/points.txt" \
   "$TEST_DIR/layer1.png" \
   >/dev/null 2>&1 && die "Unexpected success with unusable input file"

# Verify that bad input coordinates are flagged.
for bad_point in "-1,0" "0,-1" "10000,0" "0,10000" "256,0" "0,256"; do
   echo "$bad_point" > "$TEST_DIR/points.txt"
   "./$TOOL" \
      "$TEST_DIR/output.png" \
      "$TEST_DIR/points.txt" \
      "$TEST_DIR/layer1.png" \
      >/dev/null 2>&1 && die "Unexpected success with: $bad_point"
done

# Cleanup.
rm -rf "$TEST_DIR"
exit 0
