#!/bin/bash

if [[ $# -ne 1 ]]; then
   echo "$0 {generate_world_tiles.exe}"
   exit 1
fi
TOOL=$1
TEST_DIR=$(mktemp -d)
COMMON_HEADER="$TEST_DIR/header.lua"
EXPECTED_TEXT="$TEST_DIR/expected.lua"
EXPECTED_IMAGE="$TEST_DIR/expected.png"
ACTUAL_TEXT="$TEST_DIR/actual.lua"
ACTUAL_IMAGE="$TEST_DIR/actual.png"

set -euo pipefail

function die
{
   echo "$1"
   rm -rf "$TEST_DIR"
   exit 1
}

function check_output
{
   local test_id=$1

   if ! [[ -s "$ACTUAL_TEXT" ]]; then
      die "FAIL: $test_id: output text is missing or empty"
   fi
   if ! [[ -s "$ACTUAL_IMAGE" ]]; then
      die "FAIL: $test_id: output image is missing or empty"
   fi

   # Compare expected text after stripping out map info section.
   #
   # It's a pain to make the test data match that bit of text exactly,
   # so we don't bother.
   grep -A999 -F "{{{ Constants" "$ACTUAL_TEXT" \
      | grep -B999 -F "}}} End constants" \
      > "$TEST_DIR/canonicalized_text.lua"
   grep -A999 -F "}}} End map info" "$ACTUAL_TEXT" \
      | sed -e '1d' \
      >> "$TEST_DIR/canonicalized_text.lua"
   if ! ( cat "$COMMON_HEADER" "$EXPECTED_TEXT" | \
          diff -w - "$TEST_DIR/canonicalized_text.lua" ); then
      die "FAIL: $test_id: text mismatched"
   fi

   # Compare expected image in two steps (pixels and alpha).
   local expected=$(pngtopnm "$EXPECTED_IMAGE" | ppmtopgm | md5sum)
   local actual=$(pngtopnm "$ACTUAL_IMAGE" | ppmtopgm | md5sum)
   if [[ "$expected" != "$actual" ]]; then
      die "FAIL: $test_id: pixels mismatched"
   fi

   expected=$(pngtopnm -alpha "$EXPECTED_IMAGE" | ppmtopgm | md5sum)
   actual=$(pngtopnm -alpha "$ACTUAL_IMAGE" | ppmtopgm | md5sum)
   if [[ "$expected" != "$actual" ]]; then
      die "FAIL: $test_id: alpha mismatched"
   fi
}


# ................................................................
# Generate common test tiles.

pgmmake 0 32 32 > "$TEST_DIR/z.pgm"
pnmtopng -alpha="$TEST_DIR/z.pgm" "$TEST_DIR/z.pgm" > "$TEST_DIR/blank.png"
pnmtopng "$TEST_DIR/z.pgm" > "$TEST_DIR/solid.png"

cat <<EOT | perl > "$TEST_DIR/z.pgm"
print "P2\n32 32\n255\n";
for(\$y = 0; \$y < 32; \$y++)
{
   for(\$x = 0; \$x < 32; \$x++)
   {
      print \$x <= \$y ? " 255" : " 0";
   }
   print "\n";
}
EOT
pnminvert "$TEST_DIR/z.pgm" \
   | pnmtopng -alpha="$TEST_DIR/z.pgm" - > "$TEST_DIR/ur.png"
convert "$TEST_DIR/ur.png" -flip "$TEST_DIR/dr.png"
convert "$TEST_DIR/ur.png" -flop "$TEST_DIR/ul.png"
convert "$TEST_DIR/ul.png" -flip "$TEST_DIR/dl.png"


# ................................................................
# Test error cases.

"./$TOOL" > /dev/null && die "$LINENO: argument count 1"
"./$TOOL" /dev/null > /dev/null && die "$LINENO: argument count 2"
"./$TOOL" /dev/null /dev/null > /dev/null && die "$LINENO: argument count 3"

"./$TOOL" "$ACTUAL_TEXT" "$ACTUAL_IMAGE" /dev/null > /dev/null && \
   die "$LINENO: read error"

ppmmake rgb:ff/ff/ff 31 32 | pnmtopng > "$TEST_DIR/input.png"
"./$TOOL" "$ACTUAL_TEXT" "$ACTUAL_IMAGE" "$TEST_DIR/input.png" > /dev/null && \
   die "$LINENO: bad width"

ppmmake rgb:ff/ff/ff 32 31 | pnmtopng > "$TEST_DIR/input.png"
"./$TOOL" "$ACTUAL_TEXT" "$ACTUAL_IMAGE" "$TEST_DIR/input.png" > /dev/null && \
   die "$LINENO: bad height"

ppmmake rgb:ff/ff/ff 32 64 | pnmtopng > "$TEST_DIR/input1.png"
ppmmake rgb:ff/ff/ff 64 64 | pnmtopng > "$TEST_DIR/input2.png"
"./$TOOL" "$ACTUAL_TEXT" "$ACTUAL_IMAGE" \
          "$TEST_DIR/input1.png" "$TEST_DIR/input2.png" > /dev/null && \
   die "$LINENO: nonuniform input sizes"

"./$TOOL" "$ACTUAL_TEXT" "$ACTUAL_IMAGE" "$TEST_DIR/blank.png" > /dev/null && \
   die "$LINENO: empty tiles"


# ................................................................
# Load common header.

# Run tool on a simple input file, then extract the first section as the
# common header.  Doing it this way (as opposed to just hardcoding the
# generated text) means we don't have to update the test whenever we
# update the list of constants.
#
# The first grep finds the start of constants section, second grep finds
# the end of the constants section, and third grep removes all comments.
ppmmake rgb:00/00/00 32 32 | pnmtopng > "$TEST_DIR/input.png"
"./$TOOL" "$ACTUAL_TEXT" "$ACTUAL_IMAGE" "$TEST_DIR/input.png"
grep -A999 -F "{{{ Constants" "$ACTUAL_TEXT" \
   | grep -B999 -F "}}} End constants" \
   > "$COMMON_HEADER"


# ................................................................
# Test single tiles.

# Black tile.
ppmmake rgb:00/00/00 32 32 | pnmtopng > "$TEST_DIR/input.png"
cat <<EOT > "$EXPECTED_TEXT"
world.input =
{
   1,
   1,
}
EOT

pgmmake 0 $((1920-32)) 32 > "$TEST_DIR/t.pgm"
pnmtopng -alpha="$TEST_DIR/t.pgm" "$TEST_DIR/t.pgm" > "$TEST_DIR/trailer.png"
convert +append "$TEST_DIR/input.png" "$TEST_DIR/trailer.png" "$EXPECTED_IMAGE"

"./$TOOL" "$ACTUAL_TEXT" "$ACTUAL_IMAGE" "$TEST_DIR/input.png"
check_output "$LINENO: black tile"

# White tile.
ppmmake rgb:ff/ff/ff 32 32 | pnmtopng > "$TEST_DIR/input.png"
convert +append "$TEST_DIR/input.png" "$TEST_DIR/trailer.png" "$EXPECTED_IMAGE"
"./$TOOL" "$ACTUAL_TEXT" "$ACTUAL_IMAGE" "$TEST_DIR/input.png"
check_output "$LINENO: white tile"


# ................................................................
# Test blank handling.

convert \
   "(" "$TEST_DIR/blank.png" \
       "$TEST_DIR/solid.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/solid.png" \
       +append ")" \
   "(" "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/solid.png" \
       "$TEST_DIR/solid.png" \
       +append ")" \
   -append \
   "$TEST_DIR/input.png"

cat <<EOT > "$EXPECTED_TEXT"
world.input =
{
   8,
   -1, 1, -1, 1, -2, 65537,
}
EOT

pgmmake 0 $((1920-32)) 32 > "$TEST_DIR/t.pgm"
pnmtopng -alpha="$TEST_DIR/t.pgm" "$TEST_DIR/t.pgm" > "$TEST_DIR/trailer.png"
convert +append "$TEST_DIR/solid.png" "$TEST_DIR/trailer.png" "$EXPECTED_IMAGE"

"./$TOOL" "$ACTUAL_TEXT" "$ACTUAL_IMAGE" "$TEST_DIR/input.png"
check_output "$LINENO: transparency"


# ................................................................
# Test duplicate tile detection.

# Generate 10 unique tiles.  This is done by taking 10 different crops
# from a rectangle consistent of black and white regions.
#
# Alternatively, we can use ImageMagick to draw unique tiles, like this:
#   magick -size 32x32 label:123 123.pbm
#
# But doing crops with netpbm is much faster (saves us about 2 seconds).
pgmmake 0 31 32 > "$TEST_DIR/a.pgm"
pgmmake 1 31 32 | pnmcat -lr "$TEST_DIR/a.pgm" - > "$TEST_DIR/b.pgm"
for i in $(seq 10); do
   pamcut -left $i -top 0 -width 32 -height 32 "$TEST_DIR/b.pgm" \
      > "$TEST_DIR/$i.pgm"
done

pnmcat -lr \
   "$TEST_DIR/1.pgm" \
   "$TEST_DIR/2.pgm" \
   "$TEST_DIR/3.pgm" \
   "$TEST_DIR/4.pgm" \
   "$TEST_DIR/5.pgm" \
   "$TEST_DIR/6.pgm" \
   "$TEST_DIR/7.pgm" \
   "$TEST_DIR/8.pgm" \
   "$TEST_DIR/9.pgm" \
   "$TEST_DIR/10.pgm" \
   > "$TEST_DIR/row1.pgm"
convert \
   "(" "$TEST_DIR/1.pgm" \
       "$TEST_DIR/2.pgm" \
       "$TEST_DIR/3.pgm" \
       "$TEST_DIR/4.pgm" \
       "$TEST_DIR/5.pgm" \
       "$TEST_DIR/6.pgm" \
       "$TEST_DIR/7.pgm" \
       "$TEST_DIR/8.pgm" \
       "$TEST_DIR/9.pgm" \
       "$TEST_DIR/10.pgm" \
       +append ")" \
   "(" "$TEST_DIR/1.pgm" \
       "$TEST_DIR/4.pgm" \
       "$TEST_DIR/1.pgm" \
       "$TEST_DIR/5.pgm" \
       "$TEST_DIR/9.pgm" \
       "$TEST_DIR/2.pgm" \
       "$TEST_DIR/6.pgm" \
       "$TEST_DIR/5.pgm" \
       "$TEST_DIR/3.pgm" \
       "$TEST_DIR/5.pgm" \
       +append ")" \
   "(" "$TEST_DIR/8.pgm" \
       "$TEST_DIR/9.pgm" \
       "$TEST_DIR/7.pgm" \
       "$TEST_DIR/9.pgm" \
       "$TEST_DIR/3.pgm" \
       "$TEST_DIR/2.pgm" \
       "$TEST_DIR/3.pgm" \
       "$TEST_DIR/8.pgm" \
       "$TEST_DIR/4.pgm" \
       "$TEST_DIR/6.pgm" \
       +append ")" \
   -append \
   "$TEST_DIR/n.png"

cat <<EOT > "$EXPECTED_TEXT"
world.n =
{
   30,
   65538, 196612, 327686, 458760, 589834, 65540, 65541, 589826, 393221, 196613,
   524297, 458761, 196610, 196616, 262150,
}
EOT

pgmmake 0 $((1920-32*10)) 32 > "$TEST_DIR/t.pgm"
pnmtopng -alpha="$TEST_DIR/t.pgm" "$TEST_DIR/t.pgm" > "$TEST_DIR/trailer.png"
convert +append "$TEST_DIR/row1.pgm" "$TEST_DIR/trailer.png" "$EXPECTED_IMAGE"

"./$TOOL" "$ACTUAL_TEXT" "$ACTUAL_IMAGE" "$TEST_DIR/n.png"
check_output "$LINENO: duplicate tiles"


# ................................................................
# Test multiple output rows.

# Generate a 320x32 image with 10 unique tiles.
pgmmake 0 31 32 > "$TEST_DIR/a.pgm"
pgmmake 1 31 32 | pnmcat -lr "$TEST_DIR/a.pgm" - > "$TEST_DIR/b.pgm"
pnmcat -lr \
   "$TEST_DIR/b.pgm" \
   "$TEST_DIR/b.pgm" \
   "$TEST_DIR/b.pgm" \
   "$TEST_DIR/b.pgm" \
   "$TEST_DIR/b.pgm" \
   "$TEST_DIR/b.pgm" \
   | pamcut -left 0 -top 0 -width 320 -height 32 > "$TEST_DIR/c.pgm"

# Combine this 320x32 image with a solid rectangle.
pgmmake 1 320 32 | pnmcat -tb "$TEST_DIR/c.pgm" - > "$TEST_DIR/d.pgm"

# Generate 10 unique rows of 320x32 images by taking different crops
# of the 320x64 image above.
for i in $(seq 10); do
   pamcut -left 0 -top $i -width 320 -height 32 "$TEST_DIR/d.pgm" \
      > "$TEST_DIR/$i.pgm"
done

# Combine all rows into a 320x320 PNG.  All 100 32x32 tiles are unique.
pnmcat -tb $(seq -f "$TEST_DIR/%.0f.pgm" 10) | pnmtopng > "$TEST_DIR/input.png"

cat <<EOT > "$EXPECTED_TEXT"
world.input =
{
   100,
   65538, 196612, 327686, 458760, 589834, 720908, 851982, 983056, 1114130, 1245204,
   1376278, 1507352, 1638426, 1769500, 1900574, 2031648, 2162722, 2293796, 2424870, 2555944,
   2687018, 2818092, 2949166, 3080240, 3211314, 3342388, 3473462, 3604536, 3735610, 3866684,
   3997758, 4128832, 4259906, 4390980, 4522054, 4653128, 4784202, 4915276, 5046350, 5177424,
   5308498, 5439572, 5570646, 5701720, 5832794, 5963868, 6094942, 6226016, 6357090, 6488164,
}
EOT

pgmmake 0 $((1920-40*32)) 32 > "$TEST_DIR/t.pgm"
pnmtopng -alpha="$TEST_DIR/t.pgm" "$TEST_DIR/t.pgm" > "$TEST_DIR/trailer.png"
convert \
   "(" "$TEST_DIR/1.pgm" \
       "$TEST_DIR/2.pgm" \
       "$TEST_DIR/3.pgm" \
       "$TEST_DIR/4.pgm" \
       "$TEST_DIR/5.pgm" \
       "$TEST_DIR/6.pgm" \
       +append ")" \
   "(" "$TEST_DIR/7.pgm" \
       "$TEST_DIR/8.pgm" \
       "$TEST_DIR/9.pgm" \
       "$TEST_DIR/10.pgm" \
       "$TEST_DIR/trailer.png" \
       +append ")" \
   -append \
   "$EXPECTED_IMAGE"

"./$TOOL" "$ACTUAL_TEXT" "$ACTUAL_IMAGE" "$TEST_DIR/input.png"
check_output "$LINENO: multiple rows"


# ................................................................
# Test collision bits.

# Build a concave map.
#  1: [##][##][##][##][##][##][##][##][##][##][##]
#  2: [##][##][##][dr]            [dl][##][##][##]
#  3: [##][##][dr]                    [dl][##][##]
#  4: [##][dr]                            [dl][##]
#  5: [##]                                    [##]
#  6: [##]                                    [##]
#  7: [##]                                    [##]
#  8: [##][ur]                            [ul][##]
#  9: [##][##][ur]                    [ul][##][##]
# 10: [##][##][##][ur]            [ul][##][##][##]
# 11: [##][##][##][##][##][##][##][##][##][##][##]
convert +append \
   "$TEST_DIR/solid.png" \
   "$TEST_DIR/solid.png" \
   "$TEST_DIR/solid.png" \
   "$TEST_DIR/solid.png" \
   "$TEST_DIR/solid.png" \
   "$TEST_DIR/solid.png" \
   "$TEST_DIR/solid.png" \
   "$TEST_DIR/solid.png" \
   "$TEST_DIR/solid.png" \
   "$TEST_DIR/solid.png" \
   "$TEST_DIR/solid.png" \
   "$TEST_DIR/row1.png"
convert +append \
   "$TEST_DIR/solid.png" \
   "$TEST_DIR/solid.png" \
   "$TEST_DIR/solid.png" \
   "$TEST_DIR/dr.png" \
   "$TEST_DIR/blank.png" \
   "$TEST_DIR/blank.png" \
   "$TEST_DIR/blank.png" \
   "$TEST_DIR/dl.png" \
   "$TEST_DIR/solid.png" \
   "$TEST_DIR/solid.png" \
   "$TEST_DIR/solid.png" \
   "$TEST_DIR/row2.png"
convert +append \
   "$TEST_DIR/solid.png" \
   "$TEST_DIR/solid.png" \
   "$TEST_DIR/dr.png" \
   "$TEST_DIR/blank.png" \
   "$TEST_DIR/blank.png" \
   "$TEST_DIR/blank.png" \
   "$TEST_DIR/blank.png" \
   "$TEST_DIR/blank.png" \
   "$TEST_DIR/dl.png" \
   "$TEST_DIR/solid.png" \
   "$TEST_DIR/solid.png" \
   "$TEST_DIR/row3.png"
convert +append \
   "$TEST_DIR/solid.png" \
   "$TEST_DIR/dr.png" \
   "$TEST_DIR/blank.png" \
   "$TEST_DIR/blank.png" \
   "$TEST_DIR/blank.png" \
   "$TEST_DIR/blank.png" \
   "$TEST_DIR/blank.png" \
   "$TEST_DIR/blank.png" \
   "$TEST_DIR/blank.png" \
   "$TEST_DIR/dl.png" \
   "$TEST_DIR/solid.png" \
   "$TEST_DIR/row4.png"
convert +append \
   "$TEST_DIR/solid.png" \
   "$TEST_DIR/blank.png" \
   "$TEST_DIR/blank.png" \
   "$TEST_DIR/blank.png" \
   "$TEST_DIR/blank.png" \
   "$TEST_DIR/blank.png" \
   "$TEST_DIR/blank.png" \
   "$TEST_DIR/blank.png" \
   "$TEST_DIR/blank.png" \
   "$TEST_DIR/blank.png" \
   "$TEST_DIR/solid.png" \
   "$TEST_DIR/row5.png"
# row6 and row7 are same as row5.
convert +append \
   "$TEST_DIR/solid.png" \
   "$TEST_DIR/ur.png" \
   "$TEST_DIR/blank.png" \
   "$TEST_DIR/blank.png" \
   "$TEST_DIR/blank.png" \
   "$TEST_DIR/blank.png" \
   "$TEST_DIR/blank.png" \
   "$TEST_DIR/blank.png" \
   "$TEST_DIR/blank.png" \
   "$TEST_DIR/ul.png" \
   "$TEST_DIR/solid.png" \
   "$TEST_DIR/row8.png"
convert +append \
   "$TEST_DIR/solid.png" \
   "$TEST_DIR/solid.png" \
   "$TEST_DIR/ur.png" \
   "$TEST_DIR/blank.png" \
   "$TEST_DIR/blank.png" \
   "$TEST_DIR/blank.png" \
   "$TEST_DIR/blank.png" \
   "$TEST_DIR/blank.png" \
   "$TEST_DIR/ul.png" \
   "$TEST_DIR/solid.png" \
   "$TEST_DIR/solid.png" \
   "$TEST_DIR/row9.png"
convert +append \
   "$TEST_DIR/solid.png" \
   "$TEST_DIR/solid.png" \
   "$TEST_DIR/solid.png" \
   "$TEST_DIR/ur.png" \
   "$TEST_DIR/blank.png" \
   "$TEST_DIR/blank.png" \
   "$TEST_DIR/blank.png" \
   "$TEST_DIR/ul.png" \
   "$TEST_DIR/solid.png" \
   "$TEST_DIR/solid.png" \
   "$TEST_DIR/solid.png" \
   "$TEST_DIR/row10.png"
# row11 is same as row1.
convert -append \
   "$TEST_DIR/row1.png" \
   "$TEST_DIR/row2.png" \
   "$TEST_DIR/row3.png" \
   "$TEST_DIR/row4.png" \
   "$TEST_DIR/row5.png" \
   "$TEST_DIR/row5.png" \
   "$TEST_DIR/row5.png" \
   "$TEST_DIR/row8.png" \
   "$TEST_DIR/row9.png" \
   "$TEST_DIR/row10.png" \
   "$TEST_DIR/row1.png" \
   "$TEST_DIR/input.png"

cat <<EOT > "$EXPECTED_TEXT"
world.input =
{
   121,
   65537, 65537, 65537, 65537, 65537, 65537, 65537, 2, -3, 196609,
   65537, 65537, 2, -5, 196609, 65537, 2, -7, 196609, 1,
   -9, 65537, -9, 65537, -9, 65537, 4, -7, 327681, 65537,
   4, -5, 327681, 65537, 65537, 4, -3, 327681, 65537, 65537,
   65537, 65537, 65537, 65537, 1,
}
EOT
pgmmake 0 $((1920-5*32)) 32 > "$TEST_DIR/t.pgm"
pnmtopng -alpha="$TEST_DIR/t.pgm" "$TEST_DIR/t.pgm" > "$TEST_DIR/trailer.png"
convert +append \
   "$TEST_DIR/solid.png" \
   "$TEST_DIR/dr.png" \
   "$TEST_DIR/dl.png" \
   "$TEST_DIR/ur.png" \
   "$TEST_DIR/ul.png" \
   "$TEST_DIR/trailer.png" \
   "$EXPECTED_IMAGE"

"./$TOOL" "$ACTUAL_TEXT" "$ACTUAL_IMAGE" "$TEST_DIR/input.png"
check_output "$LINENO: concave room"

cp "$TEST_DIR/input.png" "$TEST_DIR/metadata.png"
cat <<EOT >> "$EXPECTED_TEXT"
world.metadata =
{
   {  1,  1,  1,  1,  1, 33,  1,  1,  1,  1,  1},
   {  1,  1,  1,  5,  0,  0,  0,  4,  1,  1,  1},
   {  1,  1,165,  0,  0,  0,  0,  0,100,  1,  1},
   {  1,  5,  0,  0,  0,  0,  0,  0,  0,  4,  1},
   {  1,  0,  0,  0,  0,  0,  0,  0,  0,  0,  1},
   {129,  0,  0,  0,  0,  0,  0,  0,  0,  0, 65},
   {  1,  0,  0,  0,  0,  0,  0,  0,  0,  0,  1},
   {  1,  3,  0,  0,  0,  0,  0,  0,  0,  2,  1},
   {  1,  1,147,  0,  0,  0,  0,  0, 82,  1,  1},
   {  1,  1,  1,  3,  0,  0,  0,  2,  1,  1,  1},
   {  1,  1,  1,  1,  1, 17,  1,  1,  1,  1,  1},
}
EOT
"./$TOOL" "$ACTUAL_TEXT" "$ACTUAL_IMAGE" \
          "$TEST_DIR/input.png" "$TEST_DIR/metadata.png"
check_output "$LINENO: concave room with metadata"

# Double-sided horizontal surface.
# 1:
# 2:
# 3:    [##][##][##][##][##]
# 4:
# 5:
convert \
   "(" "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       +append ")" \
   "(" "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       +append ")" \
   "(" "$TEST_DIR/blank.png" \
       "$TEST_DIR/solid.png" \
       "$TEST_DIR/solid.png" \
       "$TEST_DIR/solid.png" \
       "$TEST_DIR/solid.png" \
       "$TEST_DIR/solid.png" \
       "$TEST_DIR/blank.png" \
       +append ")" \
   "(" "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       +append ")" \
   "(" "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       +append ")" \
   -append \
   "$TEST_DIR/input.png"

cat <<EOT > "$EXPECTED_TEXT"
world.input =
{
   21,
   -15, 65537, 65537, 1, -1,
}
EOT
pgmmake 0 $((1920-32)) 32 > "$TEST_DIR/t.pgm"
pnmtopng -alpha="$TEST_DIR/t.pgm" "$TEST_DIR/t.pgm" > "$TEST_DIR/trailer.png"
convert +append "$TEST_DIR/solid.png" "$TEST_DIR/trailer.png" "$EXPECTED_IMAGE"

"./$TOOL" "$ACTUAL_TEXT" "$ACTUAL_IMAGE" "$TEST_DIR/input.png"
check_output "$LINENO: double sided horizontal"

cp "$TEST_DIR/input.png" "$TEST_DIR/metadata.png"
cat <<EOT >> "$EXPECTED_TEXT"
world.metadata =
{
   { 0,  0,  0,  0,  0,  0,  0},
   { 0,  0,  0,  0,  0,  0,  0},
   { 0,  1, 49, 49, 49,  1,  0},
   { 0,  0,  0,  0,  0,  0,  0},
   { 0,  0,  0,  0,  0,  0,  0},
}
EOT
"./$TOOL" "$ACTUAL_TEXT" "$ACTUAL_IMAGE" \
          "$TEST_DIR/input.png" "$TEST_DIR/metadata.png"
check_output "$LINENO: double sided horizontal with metadata"

# Double-sided vertical surface.
# 1:
# 2:        [##]
# 3:        [##]
# 4:        [##]
# 5:        [##]
# 6:        [##]
# 7:
convert \
   "(" "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       -append ")" \
   "(" "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       -append ")" \
   "(" "$TEST_DIR/blank.png" \
       "$TEST_DIR/solid.png" \
       "$TEST_DIR/solid.png" \
       "$TEST_DIR/solid.png" \
       "$TEST_DIR/solid.png" \
       "$TEST_DIR/solid.png" \
       "$TEST_DIR/blank.png" \
       -append ")" \
   "(" "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       -append ")" \
   "(" "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       -append ")" \
   +append \
   "$TEST_DIR/input.png"

cat <<EOT > "$EXPECTED_TEXT"
world.input =
{
   30,
   -7, 1, -4, 1, -4, 1, -4, 1, -4, 1,
   -2,
}
EOT
"./$TOOL" "$ACTUAL_TEXT" "$ACTUAL_IMAGE" "$TEST_DIR/input.png"
check_output "$LINENO: double sided vertical"

cp "$TEST_DIR/input.png" "$TEST_DIR/metadata.png"
cat <<EOT >> "$EXPECTED_TEXT"
world.metadata =
{
   {  0,  0,   0,  0,  0},
   {  0,  0,   1,  0,  0},
   {  0,  0, 193,  0,  0},
   {  0,  0, 193,  0,  0},
   {  0,  0, 193,  0,  0},
   {  0,  0,   1,  0,  0},
   {  0,  0,   0,  0,  0},
}
EOT
"./$TOOL" "$ACTUAL_TEXT" "$ACTUAL_IMAGE" \
          "$TEST_DIR/input.png" "$TEST_DIR/metadata.png"
check_output "$LINENO: double sided vertical with metadata"

# Double sided diagonals.
#  1:
#  2:         [##]
#  3:         [dl][ur]
#  4:             [dl][ur]
#  5:                 [dl][ur]
#  6:                     [dl][##][##]
#  7: [##]
#  8:                     [##]
#  9:                 [ul][dr]
# 10:             [ul][dr]
# 11:         [ul][dr]
convert \
   "(" "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       +append ")" \
   "(" "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/solid.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       +append ")" \
   "(" "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/dl.png" \
       "$TEST_DIR/ur.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       +append ")" \
   "(" "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/dl.png" \
       "$TEST_DIR/ur.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       +append ")" \
   "(" "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/dl.png" \
       "$TEST_DIR/ur.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       +append ")" \
   "(" "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/dl.png" \
       "$TEST_DIR/solid.png" \
       "$TEST_DIR/solid.png" \
       +append ")" \
   "(" "$TEST_DIR/solid.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       +append ")" \
   "(" "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/solid.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       +append ")" \
   "(" "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/ul.png" \
       "$TEST_DIR/dr.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       +append ")" \
   "(" "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/ul.png" \
       "$TEST_DIR/dr.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       +append ")" \
   "(" "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/ul.png" \
       "$TEST_DIR/dr.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       +append ")" \
   -append \
   "$TEST_DIR/input.png"

cat <<EOT > "$EXPECTED_TEXT"
world.input =
{
   88,
   -10, 1, -7, 131075, -7, 131075, -7, 131075, -7, 131073,
   65537, -12, 1, -6, 262149, -5, 262149, -5, 262149, -4,
}
EOT

pgmmake 0 $((1920-5*32)) 32 > "$TEST_DIR/t.pgm"
pnmtopng -alpha="$TEST_DIR/t.pgm" "$TEST_DIR/t.pgm" > "$TEST_DIR/trailer.png"
convert +append \
   "$TEST_DIR/solid.png" \
   "$TEST_DIR/dl.png" \
   "$TEST_DIR/ur.png" \
   "$TEST_DIR/ul.png" \
   "$TEST_DIR/dr.png" \
   "$TEST_DIR/trailer.png" \
   "$EXPECTED_IMAGE"

"./$TOOL" "$ACTUAL_TEXT" "$ACTUAL_IMAGE" "$TEST_DIR/input.png"
check_output "$LINENO: double sided diagonals"

cp "$TEST_DIR/input.png" "$TEST_DIR/metadata.png"
cat <<EOT >> "$EXPECTED_TEXT"
world.metadata =
{
   {  0,  0,  0,  0,  0,  0,  0,  0},
   {  0,  0,  1,  0,  0,  0,  0,  0},
   {  0,  0,  4,  3,  0,  0,  0,  0},
   {  0,  0,  0,100,147,  0,  0,  0},
   {  0,  0,  0,  0,100,  3,  0,  0},
   {  0,  0,  0,  0,  0,  4,  1,  1},
   {  1,  0,  0,  0,  0,  0,  0,  0},
   {  0,  0,  0,  0,  0,  1,  0,  0},
   {  0,  0,  0,  0,  2,  5,  0,  0},
   {  0,  0,  0, 82,  5,  0,  0,  0},
   {  0,  0,  2,  5,  0,  0,  0,  0},
}
EOT
"./$TOOL" "$ACTUAL_TEXT" "$ACTUAL_IMAGE" \
          "$TEST_DIR/input.png" "$TEST_DIR/metadata.png"
check_output "$LINENO: double sided diagonals with metadata"


# ................................................................
# Extra tests for diagonal mounts.

# Diagonal mounts with obstacles that are a bishop's move away.
#  1:
#  2:             [##]
#  3:                         [ul][##]
#  4:                     [ul][dr]
#  5:                 [ul][dr]
#  6:             [ul][dr]
#  7:         [ul][dr]
#  8:         [dr]
#  9:                     [##]
# 10:
convert \
   "(" "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       +append ")" \
   "(" "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/solid.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       +append ")" \
   "(" "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/ul.png" \
       "$TEST_DIR/solid.png" \
       "$TEST_DIR/blank.png" \
       +append ")" \
   "(" "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/ul.png" \
       "$TEST_DIR/dr.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       +append ")" \
   "(" "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/ul.png" \
       "$TEST_DIR/dr.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       +append ")" \
   "(" "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/ul.png" \
       "$TEST_DIR/dr.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       +append ")" \
   "(" "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/ul.png" \
       "$TEST_DIR/dr.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       +append ")" \
   "(" "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/dr.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       +append ")" \
   "(" "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/solid.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       +append ")" \
   "(" "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       +append ")" \
   -append \
   "$TEST_DIR/bishop1.png"

cat <<EOT > "$EXPECTED_TEXT"
world.bishop1 =
{
   81,
   -12, 1, -11, 131073, -6, 131075, -6, 131075, -6, 131075,
   -6, 131075, -7, 3, -11, 1, -3,
}
EOT

pgmmake 0 $((1920-3*32)) 32 > "$TEST_DIR/t.pgm"
pnmtopng -alpha="$TEST_DIR/t.pgm" "$TEST_DIR/t.pgm" > "$TEST_DIR/trailer.png"
convert +append \
   "$TEST_DIR/solid.png" \
   "$TEST_DIR/ul.png" \
   "$TEST_DIR/dr.png" \
   "$TEST_DIR/trailer.png" \
   "$EXPECTED_IMAGE"

"./$TOOL" "$ACTUAL_TEXT" "$ACTUAL_IMAGE" "$TEST_DIR/bishop1.png"
check_output "$LINENO: diagonal mount (bishop 1)"

cp "$TEST_DIR/bishop1.png" "$TEST_DIR/metadata.png"
cat <<EOT >> "$EXPECTED_TEXT"
world.metadata =
{
   {  0,  0,  0,  0,  0,  0,  0,  0,  0},
   {  0,  0,  0,  1,  0,  0,  0,  0,  0},
   {  0,  0,  0,  0,  0,  0,  2,  1,  0},
   {  0,  0,  0,  0,  0,  2,  5,  0,  0},
   {  0,  0,  0,  0,  2,165,  0,  0,  0},
   {  0,  0,  0, 82,  5,  0,  0,  0,  0},
   {  0,  0,  2,  5,  0,  0,  0,  0,  0},
   {  0,  0,  5,  0,  0,  0,  0,  0,  0},
   {  0,  0,  0,  0,  0,  1,  0,  0,  0},
   {  0,  0,  0,  0,  0,  0,  0,  0,  0},
}
EOT
"./$TOOL" "$ACTUAL_TEXT" "$ACTUAL_IMAGE" \
          "$TEST_DIR/bishop1.png" "$TEST_DIR/metadata.png"
check_output "$LINENO: diagonal mount with metadata (bishop 1)"

# Diagonal mounts with obstacles that are a knight's move away.
#  1:
#  2:
#  3:             [##]        [ul][##]
#  4:                     [ul][dr]
#  5:                 [ul][dr]
#  6:             [ul][dr]
#  7:         [ul][dr]
#  8:         [dr]        [##]
#  9:
# 10:
convert \
   "(" "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       +append ")" \
   "(" "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       +append ")" \
   "(" "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/solid.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/ul.png" \
       "$TEST_DIR/solid.png" \
       "$TEST_DIR/blank.png" \
       +append ")" \
   "(" "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/ul.png" \
       "$TEST_DIR/dr.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       +append ")" \
   "(" "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/ul.png" \
       "$TEST_DIR/dr.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       +append ")" \
   "(" "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/ul.png" \
       "$TEST_DIR/dr.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       +append ")" \
   "(" "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/ul.png" \
       "$TEST_DIR/dr.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       +append ")" \
   "(" "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/dr.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/solid.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       +append ")" \
   "(" "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       +append ")" \
   "(" "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       +append ")" \
   -append \
   "$TEST_DIR/knight1.png"

cat <<EOT > "$EXPECTED_TEXT"
world.knight1 =
{
   72,
   -21, 1, -2, 131073, -6, 131075, -6, 131075, -6, 131075,
   -6, 131075, -7, 3, -2, 1, -3,
}
EOT

"./$TOOL" "$ACTUAL_TEXT" "$ACTUAL_IMAGE" "$TEST_DIR/knight1.png"
check_output "$LINENO: diagonal mount (knight 1)"

cp "$TEST_DIR/knight1.png" "$TEST_DIR/metadata.png"
cat <<EOT >> "$EXPECTED_TEXT"
world.metadata =
{
   {  0,  0,  0,  0,  0,  0,  0,  0,  0},
   {  0,  0,  0,  0,  0,  0,  0,  0,  0},
   {  0,  0,  0,  1,  0,  0,  2,  1,  0},
   {  0,  0,  0,  0,  0,  2,  5,  0,  0},
   {  0,  0,  0,  0,  2,  5,  0,  0,  0},
   {  0,  0,  0,  2,  5,  0,  0,  0,  0},
   {  0,  0,  2,  5,  0,  0,  0,  0,  0},
   {  0,  0,  5,  0,  0,  1,  0,  0,  0},
   {  0,  0,  0,  0,  0,  0,  0,  0,  0},
   {  0,  0,  0,  0,  0,  0,  0,  0,  0},
}
EOT
"./$TOOL" "$ACTUAL_TEXT" "$ACTUAL_IMAGE" \
          "$TEST_DIR/knight1.png" "$TEST_DIR/metadata.png"
check_output "$LINENO: diagonal mount with metadata (knight 1)"

# Retry the bishop obstacle positions for the other two orientations.
#  1:
#  2:                     [##]
#  3:     [##][ur]
#  4:         [dl][ur]
#  5:             [dl][ur]
#  6:                 [dl][ur]
#  7:                     [dl][ur]
#  8:                         [dl]
#  9:             [##]
# 10:
convert "$TEST_DIR/bishop1.png" -flop "$TEST_DIR/bishop2.png"

cat <<EOT > "$EXPECTED_TEXT"
world.bishop2 =
{
   81,
   -14, 1, -4, 65538, -8, 196610, -8, 196610, -8, 196610,
   -8, 196610, -8, 3, -5, 1, -5,
}
EOT

convert +append \
   "$TEST_DIR/solid.png" \
   "$TEST_DIR/ur.png" \
   "$TEST_DIR/dl.png" \
   "$TEST_DIR/trailer.png" \
   "$EXPECTED_IMAGE"

"./$TOOL" "$ACTUAL_TEXT" "$ACTUAL_IMAGE" "$TEST_DIR/bishop2.png"
check_output "$LINENO: diagonal mount (bishop 2)"

cp "$TEST_DIR/bishop2.png" "$TEST_DIR/metadata.png"
cat <<EOT >> "$EXPECTED_TEXT"
world.metadata =
{
   {  0,  0,  0,  0,  0,  0,  0,  0,  0},
   {  0,  0,  0,  0,  0,  1,  0,  0,  0},
   {  0,  1,  3,  0,  0,  0,  0,  0,  0},
   {  0,  0,  4,  3,  0,  0,  0,  0,  0},
   {  0,  0,  0,100,  3,  0,  0,  0,  0},
   {  0,  0,  0,  0,  4,147,  0,  0,  0},
   {  0,  0,  0,  0,  0,  4,  3,  0,  0},
   {  0,  0,  0,  0,  0,  0,  4,  0,  0},
   {  0,  0,  0,  1,  0,  0,  0,  0,  0},
   {  0,  0,  0,  0,  0,  0,  0,  0,  0},
}
EOT
"./$TOOL" "$ACTUAL_TEXT" "$ACTUAL_IMAGE" \
          "$TEST_DIR/bishop2.png" "$TEST_DIR/metadata.png"
check_output "$LINENO: diagonal mount with metadata (bishop 2)"

# Retry the knight obstacle positions for the other two orientations.
#  1:
#  2:
#  3:     [##][ur]        [##]
#  4:         [dl][ur]
#  5:             [dl][ur]
#  6:                 [dl][ur]
#  7:                     [dl][ur]
#  8:             [##]        [dl]
#  9:
# 10:
convert "$TEST_DIR/knight1.png" -flop "$TEST_DIR/knight2.png"

cat <<EOT > "$EXPECTED_TEXT"
world.knight2 =
{
   72,
   -19, 65538, -2, 1, -5, 196610, -8, 196610, -8, 196610,
   -8, 196610, -5, 1, -2, 3, -2,
}
EOT

"./$TOOL" "$ACTUAL_TEXT" "$ACTUAL_IMAGE" "$TEST_DIR/knight2.png"
check_output "$LINENO: diagonal mount (knight 2)"

cp "$TEST_DIR/knight2.png" "$TEST_DIR/metadata.png"
cat <<EOT >> "$EXPECTED_TEXT"
world.metadata =
{
   {  0,  0,  0,  0,  0,  0,  0,  0,  0},
   {  0,  0,  0,  0,  0,  0,  0,  0,  0},
   {  0,  1,  3,  0,  0,  1,  0,  0,  0},
   {  0,  0,  4,  3,  0,  0,  0,  0,  0},
   {  0,  0,  0,  4,  3,  0,  0,  0,  0},
   {  0,  0,  0,  0,  4,  3,  0,  0,  0},
   {  0,  0,  0,  0,  0,  4,  3,  0,  0},
   {  0,  0,  0,  1,  0,  0,  4,  0,  0},
   {  0,  0,  0,  0,  0,  0,  0,  0,  0},
   {  0,  0,  0,  0,  0,  0,  0,  0,  0},
}
EOT
"./$TOOL" "$ACTUAL_TEXT" "$ACTUAL_IMAGE" \
          "$TEST_DIR/knight2.png" "$TEST_DIR/metadata.png"
check_output "$LINENO: diagonal mount with metadata (knight 2)"


# ................................................................
# Test obstacles.

# 1: [##][##][##][##][##][##][##]
# 2:         <rr>    <gg>
# 3:
pgmmake 0 $((7*32)) 32 > "$TEST_DIR/blank_row.pgm"
pnmtopng "$TEST_DIR/blank_row.pgm" > "$TEST_DIR/row1.png"
pnmtopng -alpha="$TEST_DIR/blank_row.pgm" "$TEST_DIR/blank_row.pgm" \
   > "$TEST_DIR/row23.png"
convert -append \
   "$TEST_DIR/row1.png" \
   "$TEST_DIR/row23.png" \
   "$TEST_DIR/row23.png" \
   "$TEST_DIR/input1.png"
convert "$TEST_DIR/input1.png" \
   -fill black -draw "rectangle 64,32 96,64" \
   -fill red -draw "circle 80,48 80,40" \
   -fill green -draw "circle 144,48 144,40" \
   "$TEST_DIR/metadata1.png"

cat <<EOT > "$EXPECTED_TEXT"
world.input1 =
{
   7,
   65537, 65537, 65537, 1,
}
world.metadata1 =
{
   {1, 33, 33, 33, 33, 33,  1},
   {0,  0,  9,  0,512,  0,  0},
   {0,  0,  0,  0,  0,  0,  0},
}
EOT

pgmmake 0 $((1920-32)) 32 > "$TEST_DIR/t.pgm"
pnmtopng -alpha="$TEST_DIR/t.pgm" "$TEST_DIR/t.pgm" > "$TEST_DIR/trailer.png"
convert +append "$TEST_DIR/solid.png" "$TEST_DIR/trailer.png" "$EXPECTED_IMAGE"

"./$TOOL" "$ACTUAL_TEXT" "$ACTUAL_IMAGE" \
          "$TEST_DIR/input1.png" "$TEST_DIR/metadata1.png"
check_output "$LINENO: obstacles (down)"

convert -flip "$TEST_DIR/input1.png" "$TEST_DIR/input2.png"
convert -flip "$TEST_DIR/metadata1.png" "$TEST_DIR/metadata2.png"

cat <<EOT > "$EXPECTED_TEXT"
world.input2 =
{
   21,
   -14, 65537, 65537, 65537, 1,
}
world.metadata2 =
{
   {0,  0,  0,  0,  0,  0,  0},
   {0,  0,  9,  0,256,  0,  0},
   {1, 17, 17, 17, 17, 17,  1},
}
EOT

"./$TOOL" "$ACTUAL_TEXT" "$ACTUAL_IMAGE" \
          "$TEST_DIR/input2.png" "$TEST_DIR/metadata2.png"
check_output "$LINENO: obstacles (up)"

convert -transpose "$TEST_DIR/input2.png" "$TEST_DIR/input3.png"
convert -transpose "$TEST_DIR/metadata2.png" "$TEST_DIR/metadata3.png"

cat <<EOT > "$EXPECTED_TEXT"
world.input3 =
{
   21,
   -2, 1, -2, 1, -2, 1, -2, 1, -2, 1,
   -2, 1, -2, 1,
}
world.metadata3 =
{
   {0,   0,  1},
   {0,   0, 65},
   {0,   9, 65},
   {0,   0, 65},
   {0,1024, 65},
   {0,   0, 65},
   {0,   0,  1},
}
EOT

"./$TOOL" "$ACTUAL_TEXT" "$ACTUAL_IMAGE" \
          "$TEST_DIR/input3.png" "$TEST_DIR/metadata3.png"
check_output "$LINENO: obstacles (left)"

convert -flop "$TEST_DIR/input3.png" "$TEST_DIR/input4.png"
convert -flop "$TEST_DIR/metadata3.png" "$TEST_DIR/metadata4.png"

cat <<EOT > "$EXPECTED_TEXT"
world.input4 =
{
   21,
   1, -2, 1, -2, 1, -2, 1, -2, 1, -2,
   1, -2, 1, -2,
}
world.metadata4 =
{
   {  1,   0, 0},
   {129,   0, 0},
   {129,   9, 0},
   {129,   0, 0},
   {129,2048, 0},
   {129,   0, 0},
   {  1,   0, 0},
}
EOT

"./$TOOL" "$ACTUAL_TEXT" "$ACTUAL_IMAGE" \
          "$TEST_DIR/input4.png" "$TEST_DIR/metadata4.png"
check_output "$LINENO: obstacles (right)"

# 1: [##][##][##][##][##][##][##]
# 2:         <rr><rr><gg><rr>
# 3:             <rr><rr><rr>
cp "$TEST_DIR/input1.png" "$TEST_DIR/input5.png"
convert "$TEST_DIR/metadata1.png" \
   -fill black -draw "rectangle 96,32 128,64" \
   -fill black -draw "rectangle 160,32 192,64" \
   -fill black -draw "rectangle 96,64 192,96" \
   -fill red -draw "circle 112,48 112,40" \
   -fill red -draw "circle 112,80 112,72" \
   -fill red -draw "circle 144,80 144,72" \
   -fill red -draw "circle 176,48 176,40" \
   -fill red -draw "circle 176,80 176,72" \
   "$TEST_DIR/metadata5.png"

cat <<EOT > "$EXPECTED_TEXT"
world.input5 =
{
   7,
   65537, 65537, 65537, 1,
}
world.metadata5 =
{
   {1, 33, 33, 33, 33, 33,  1},
   {0,  0,  9,  9,512,  9,  0},
   {0,  0,  0,  9,  9,  9,  0},
}
EOT

"./$TOOL" "$ACTUAL_TEXT" "$ACTUAL_IMAGE" \
          "$TEST_DIR/input5.png" "$TEST_DIR/metadata5.png"
check_output "$LINENO: obstacles (crowded)"

# Test collectible tiles around breakable tiles.
#
# 1:
# 2:     (#r)(#r)(#r)
# 3:     (#r)(gg)(#r)
# 4:     [##][##][##]
# 5:
convert \
   "(" "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       +append ")" \
   "(" "$TEST_DIR/blank.png" \
       "$TEST_DIR/ul.png" \
       "$TEST_DIR/solid.png" \
       "$TEST_DIR/ur.png" \
       "$TEST_DIR/blank.png" \
       +append ")" \
   "(" "$TEST_DIR/blank.png" \
       "$TEST_DIR/solid.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/solid.png" \
       "$TEST_DIR/blank.png" \
       +append ")" \
   "(" "$TEST_DIR/blank.png" \
       "$TEST_DIR/solid.png" \
       "$TEST_DIR/solid.png" \
       "$TEST_DIR/solid.png" \
       "$TEST_DIR/blank.png" \
       +append ")" \
   "(" "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       +append ")" \
   -append \
   "$TEST_DIR/input.png"
convert "$TEST_DIR/input.png" \
   -fill red -draw "circle 48,48 48,40" \
   -fill red -draw "circle 80,48 80,40" \
   -fill red -draw "circle 112,48 112,40" \
   -fill red -draw "circle 48,80 48,72" \
   -fill green -draw "circle 80,80 80,72" \
   -fill red -draw "circle 112,80 112,72" \
   "$TEST_DIR/metadata.png"

cat <<EOT > "$EXPECTED_TEXT"
world.input =
{
   20,
   -6, 65538, 3, -2, 2, -1, 2, -2, 131074, 2,
   -1,
}
world.metadata =
{
   {0,  0,   0,  0, 0},
   {0, 10,   9, 11, 0},
   {0,  9, 256,  9, 0},
   {0,  1,  17,  1, 0},
   {0,  0,   0,  0, 0},
}
EOT

pgmmake 0 $((1920-32*3)) 32 > "$TEST_DIR/t.pgm"
pnmtopng -alpha="$TEST_DIR/t.pgm" "$TEST_DIR/t.pgm" > "$TEST_DIR/trailer.png"
convert +append \
   "$TEST_DIR/ul.png" \
   "$TEST_DIR/solid.png" \
   "$TEST_DIR/ur.png"  \
   "$TEST_DIR/trailer.png" \
   $EXPECTED_IMAGE

"./$TOOL" "$ACTUAL_TEXT" "$ACTUAL_IMAGE" \
          "$TEST_DIR/input.png" "$TEST_DIR/metadata.png"
check_output "$LINENO: collectible surrounded by breakable"

# Test collectible tile underneath chain reaction foreground.
#
# 1:
# 2:     (#r)(#r)(#r)
# 3:     (#r)[gg](#r)
# 4:     [##][#c][##]
# 5:
convert "$TEST_DIR/input.png" \
   -fill red -draw "circle 48,48 48,40" \
   -fill red -draw "circle 80,48 80,40" \
   -fill red -draw "circle 112,48 112,40" \
   -fill red -draw "circle 48,80 48,72" \
   -fill green -draw "rectangle 72,72 88,88" \
   -fill red -draw "circle 112,80 112,72" \
   -fill cyan -draw "circle 80,112 80,104" \
   "$TEST_DIR/metadata.png"

cat <<EOT > "$EXPECTED_TEXT"
world.input =
{
   20,
   -6, 65538, 3, -2, 2, -1, 2, -2, 131074, 2,
   -1,
}
world.metadata =
{
   {0,  0,    0,  0, 0},
   {0, 10,    9, 11, 0},
   {0,  9, 8448,  9, 0},
   {0,  1, 4113,  1, 0},
   {0,  0,    0,  0, 0},
}
EOT

"./$TOOL" "$ACTUAL_TEXT" "$ACTUAL_IMAGE" \
          "$TEST_DIR/input.png" "$TEST_DIR/metadata.png"
check_output "$LINENO: hidden collectible surrounded by breakable"

# Test collectible tile attached to chain reaction breakable.
#
# 1:
# 2:     [#m][#m][#m]
# 3:         (gg)
# 4:
# 5:
convert \
   "(" "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       +append ")" \
   "(" "$TEST_DIR/blank.png" \
       "$TEST_DIR/solid.png" \
       "$TEST_DIR/solid.png" \
       "$TEST_DIR/solid.png" \
       "$TEST_DIR/blank.png" \
       +append ")" \
   "(" "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       +append ")" \
   "(" "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       +append ")" \
   "(" "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       +append ")" \
   -append \
   "$TEST_DIR/input.png"
convert "$TEST_DIR/input.png" \
   -fill magenta -draw "circle 48,48 48,40" \
   -fill magenta -draw "circle 80,48 80,40" \
   -fill magenta -draw "circle 112,48 112,40" \
   -fill green -draw "circle 80,80 80,72" \
   "$TEST_DIR/metadata.png"

pgmmake 0 $((1920-32)) 32 > "$TEST_DIR/t.pgm"
pnmtopng -alpha="$TEST_DIR/t.pgm" "$TEST_DIR/t.pgm" > "$TEST_DIR/trailer.png"
convert +append "$TEST_DIR/solid.png" "$TEST_DIR/trailer.png" $EXPECTED_IMAGE
cat <<EOT > "$EXPECTED_TEXT"
world.input =
{
   10,
   -6, 65537, 1, -1,
}
world.metadata =
{
   {0,    0,    0,    0, 0},
   {0, 4105, 4105, 4105, 0},
   {0,    0,  512,    0, 0},
   {0,    0,    0,    0, 0},
   {0,    0,    0,    0, 0},
}
EOT

"./$TOOL" "$ACTUAL_TEXT" "$ACTUAL_IMAGE" \
          "$TEST_DIR/input.png" "$TEST_DIR/metadata.png"
check_output "$LINENO: collectible attached to chain reaction breakable"

# ................................................................
# Test bad annotations.

# Collectible near edge of map.
cp "$TEST_DIR/blank.png" "$TEST_DIR/input.png"
convert \
   "$TEST_DIR/input.png" \
   -fill green -draw "circle 16,16 16,8" \
   "$TEST_DIR/metadata.png"
"./$TOOL" "$ACTUAL_TEXT" "$ACTUAL_IMAGE" \
          "$TEST_DIR/input.png" "$TEST_DIR/metadata.png" > /dev/null \
   && die "$LINENO: bad obstacle placement"

# Collectible overlapping with collision.
pgmmake 0 $((32*5)) $((32*5)) | pnmtopng > "$TEST_DIR/input.png"
convert \
   "$TEST_DIR/input.png" \
   -fill green -draw "circle 80,80 80,72" \
   "$TEST_DIR/metadata.png"
"./$TOOL" "$ACTUAL_TEXT" "$ACTUAL_IMAGE" \
          "$TEST_DIR/input.png" "$TEST_DIR/metadata.png" > /dev/null \
   && die "$LINENO: overlapping obstacle placement"

# Insufficient clearance.
convert \
   "(" "$TEST_DIR/blank.png" "$TEST_DIR/blank.png" "$TEST_DIR/blank.png" \
       +append ")" \
   "(" "$TEST_DIR/solid.png" "$TEST_DIR/blank.png" "$TEST_DIR/solid.png" \
       +append ")" \
   "(" "$TEST_DIR/blank.png" "$TEST_DIR/blank.png" "$TEST_DIR/blank.png" \
       +append ")" \
   -append \
   "$TEST_DIR/input.png"
convert \
   "$TEST_DIR/input.png" \
   -fill green -draw "circle 48,48 48,40" \
   "$TEST_DIR/metadata.png"
"./$TOOL" "$ACTUAL_TEXT" "$ACTUAL_IMAGE" \
          "$TEST_DIR/input.png" "$TEST_DIR/metadata.png" > /dev/null \
   && die "$LINENO: insufficient clearance around obstacle (horizontal)"

convert \
   "(" "$TEST_DIR/blank.png" "$TEST_DIR/solid.png" "$TEST_DIR/blank.png" \
       +append ")" \
   "(" "$TEST_DIR/blank.png" "$TEST_DIR/blank.png" "$TEST_DIR/blank.png" \
       +append ")" \
   "(" "$TEST_DIR/blank.png" "$TEST_DIR/solid.png" "$TEST_DIR/blank.png" \
       +append ")" \
   -append \
   "$TEST_DIR/input.png"
convert \
   "$TEST_DIR/input.png" \
   -fill green -draw "circle 48,48 48,40" \
   "$TEST_DIR/metadata.png"
"./$TOOL" "$ACTUAL_TEXT" "$ACTUAL_IMAGE" \
          "$TEST_DIR/input.png" "$TEST_DIR/metadata.png" > /dev/null \
   && die "$LINENO: insufficient clearance around obstacle (vertical)"

convert \
   "(" "$TEST_DIR/blank.png" "$TEST_DIR/solid.png" "$TEST_DIR/blank.png" \
       +append ")" \
   "(" "$TEST_DIR/blank.png" "$TEST_DIR/blank.png" "$TEST_DIR/solid.png" \
       +append ")" \
   "(" "$TEST_DIR/blank.png" "$TEST_DIR/blank.png" "$TEST_DIR/blank.png" \
       +append ")" \
   -append \
   "$TEST_DIR/input.png"
convert \
   "$TEST_DIR/input.png" \
   -fill green -draw "circle 48,48 48,40" \
   "$TEST_DIR/metadata.png"
"./$TOOL" "$ACTUAL_TEXT" "$ACTUAL_IMAGE" \
          "$TEST_DIR/input.png" "$TEST_DIR/metadata.png" > /dev/null \
   && die "$LINENO: insufficient clearance around obstacle (mixed)"

# Missing square collision tile.
convert \
   "(" "$TEST_DIR/blank.png" "$TEST_DIR/blank.png" "$TEST_DIR/blank.png" \
       +append ")" \
   "(" "$TEST_DIR/blank.png" "$TEST_DIR/blank.png" "$TEST_DIR/blank.png" \
       +append ")" \
   "(" "$TEST_DIR/blank.png" "$TEST_DIR/ur.png" "$TEST_DIR/blank.png" \
       +append ")" \
   -append \
   "$TEST_DIR/input.png"
convert \
   "$TEST_DIR/input.png" \
   -fill green -draw "circle 48,48 48,40" \
   "$TEST_DIR/metadata.png"
"./$TOOL" "$ACTUAL_TEXT" "$ACTUAL_IMAGE" \
          "$TEST_DIR/input.png" "$TEST_DIR/metadata.png" > /dev/null \
   && die "$LINENO: not adjacent to square collision tile"

# Too many collectible tiles.
convert "$TEST_DIR/solid.png" "$TEST_DIR/blank.png" "$TEST_DIR/blank.png" \
   -append \
   "$TEST_DIR/column0.png"

convert \
   "$TEST_DIR/column0.png" \
   -fill green -draw "circle 16,48 16,40" \
   "$TEST_DIR/column1.png"

convert \
   "$TEST_DIR/column1.png" \
   "$TEST_DIR/column1.png" \
   "$TEST_DIR/column1.png" \
   "$TEST_DIR/column1.png" \
   "$TEST_DIR/column1.png" \
   +append \
   "$TEST_DIR/column5.png"
convert \
   "$TEST_DIR/column5.png" \
   "$TEST_DIR/column5.png" \
   "$TEST_DIR/column5.png" \
   "$TEST_DIR/column5.png" \
   "$TEST_DIR/column5.png" \
   +append \
   "$TEST_DIR/column25.png"
convert \
   "$TEST_DIR/column0.png" \
   "$TEST_DIR/column25.png" \
   "$TEST_DIR/column25.png" \
   "$TEST_DIR/column25.png" \
   "$TEST_DIR/column25.png" \
   "$TEST_DIR/column0.png" \
   +append \
   "$TEST_DIR/metadata.png"

ppmmake rgb:ff/ff/ff $((32*102)) $((32*3)) | pnmtopng > "$TEST_DIR/input.png"
"./$TOOL" "$ACTUAL_TEXT" "$ACTUAL_IMAGE" \
          "$TEST_DIR/input.png" "$TEST_DIR/metadata.png" > /dev/null \
   && die "$LINENO: too many collectible tiles"

# Breakable tile without collision.
convert \
   "(" "$TEST_DIR/solid.png" "$TEST_DIR/blank.png" "$TEST_DIR/blank.png" \
       +append ")" \
   "(" "$TEST_DIR/blank.png" "$TEST_DIR/blank.png" "$TEST_DIR/blank.png" \
       +append ")" \
   "(" "$TEST_DIR/blank.png" "$TEST_DIR/blank.png" "$TEST_DIR/blank.png" \
       +append ")" \
   "(" "$TEST_DIR/blank.png" "$TEST_DIR/blank.png" "$TEST_DIR/blank.png" \
       +append ")" \
   -append "$TEST_DIR/input.png"
convert \
   "$TEST_DIR/input.png" \
   -fill red -draw "circle 48,48 48,40" \
   "$TEST_DIR/metadata.png"
"./$TOOL" "$ACTUAL_TEXT" "$ACTUAL_IMAGE" \
          "$TEST_DIR/input.png" "$TEST_DIR/metadata.png" > /dev/null \
   && die "$LINENO: breakable tile without collision"

# Chain reaction breakable without collision is fine.
convert \
   "$TEST_DIR/input.png" \
   -fill magenta -draw "circle 48,48 48,40" \
   -fill magenta -draw "rectangle 40,72 56,88" \
   "$TEST_DIR/metadata.png"
"./$TOOL" "$ACTUAL_TEXT" "$ACTUAL_IMAGE" \
          "$TEST_DIR/input.png" "$TEST_DIR/metadata.png" \
   || die "$LINENO: chain reaction breakable tile without collision"

# Terminal reaction not adjacent to chain reaction.
#
#         [cc]
#     [cc][cc][cc]
#         [cc]
#
convert \
   "(" "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       +append ")" \
   "(" "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/solid.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       +append ")" \
   "(" "$TEST_DIR/blank.png" \
       "$TEST_DIR/solid.png" \
       "$TEST_DIR/solid.png" \
       "$TEST_DIR/solid.png" \
       "$TEST_DIR/blank.png" \
       +append ")" \
   "(" "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/solid.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       +append ")" \
   "(" "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       +append ")" \
   -append \
   -fill cyan -draw "rectangle 72,40 88,56" \
   -fill cyan -draw "rectangle 40,72 56,88" \
   -fill cyan -draw "rectangle 72,72 88,88" \
   -fill cyan -draw "rectangle 104,72 120,88" \
   -fill cyan -draw "rectangle 72,104 88,120" \
   "$TEST_DIR/input.png"
cp "$TEST_DIR/input.png" "$TEST_DIR/metadata.png"
"./$TOOL" "$ACTUAL_TEXT" "$ACTUAL_IMAGE" \
          "$TEST_DIR/input.png" "$TEST_DIR/metadata.png" > /dev/null \
   && die "$LINENO: terminal tile needs at least one chain reaction neighbor"

# Breakable terminal reaction not adjacent to chain reaction.
#
#         [mm]
#     [mm][mm][mm]
#         [mm]
#
convert \
   "$TEST_DIR/input.png" \
   -fill magenta -draw "rectangle 72,40 88,56" \
   -fill magenta -draw "rectangle 40,72 56,88" \
   -fill magenta -draw "rectangle 72,72 88,88" \
   -fill magenta -draw "rectangle 104,72 120,88" \
   -fill magenta -draw "rectangle 72,104 88,120" \
   "$TEST_DIR/metadata.png"
"./$TOOL" "$ACTUAL_TEXT" "$ACTUAL_IMAGE" \
          "$TEST_DIR/input.png" "$TEST_DIR/metadata.png" > /dev/null \
   && die "$LINENO: terminal tile needs at least one chain reaction neighbor"

# Hidden collectible items not adjacent to chain reaction.
#
#         [cc]
#     [cc][gg][cc]
#         [#c]
#
convert \
   "(" "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       +append ")" \
   "(" "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       +append ")" \
   "(" "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       +append ")" \
   "(" "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/solid.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       +append ")" \
   "(" "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       +append ")" \
   -append \
   -fill cyan -draw "rectangle 72,40 88,56" \
   -fill cyan -draw "rectangle 40,72 56,88" \
   -fill green -draw "rectangle 72,72 88,88" \
   -fill cyan -draw "rectangle 104,72 120,88" \
   -fill cyan -draw "rectangle 72,104 88,120" \
   "$TEST_DIR/input.png"
cp "$TEST_DIR/input.png" "$TEST_DIR/metadata.png"

"./$TOOL" "$ACTUAL_TEXT" "$ACTUAL_IMAGE" \
          "$TEST_DIR/input.png" "$TEST_DIR/metadata.png" > /dev/null \
   && die "$LINENO: terminal tile needs at least one chain reaction neighbor"

# Try replacing each of the 4 neighbors with a chain reaction.
#
#         (cc)
#         [gg]
#         [##]
#
convert \
   "(" "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       +append ")" \
   "(" "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       +append ")" \
   "(" "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       +append ")" \
   "(" "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/solid.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       +append ")" \
   "(" "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       +append ")" \
   -append \
   -fill cyan -draw "circle 80,48 88,48" \
   -fill green -draw "rectangle 72,72 88,88" \
   "$TEST_DIR/input.png"
cp "$TEST_DIR/input.png" "$TEST_DIR/metadata1.png"
"./$TOOL" "$ACTUAL_TEXT" "$ACTUAL_IMAGE" \
          "$TEST_DIR/input.png" "$TEST_DIR/metadata1.png" \
   || die "$LINENO: terminal tile next to chain reaction (up)"

#
#         [##]
#         [gg]
#         (cc)
#
convert "$TEST_DIR/metadata1.png" -flip "$TEST_DIR/metadata2.png"
"./$TOOL" "$ACTUAL_TEXT" "$ACTUAL_IMAGE" \
          "$TEST_DIR/input.png" "$TEST_DIR/metadata2.png" > /dev/null \
   || die "$LINENO: terminal tile next to chain reaction (down)"

#
#
#     (cc)[gg][##]
#
#
convert "$TEST_DIR/metadata2.png" -rotate 90 "$TEST_DIR/metadata3.png"
"./$TOOL" "$ACTUAL_TEXT" "$ACTUAL_IMAGE" \
          "$TEST_DIR/input.png" "$TEST_DIR/metadata3.png" > /dev/null \
   || die "$LINENO: terminal tile next to chain reaction (left)"

#
#
#     [##][gg](cc)
#
#
convert "$TEST_DIR/metadata3.png" -flop "$TEST_DIR/metadata4.png"
"./$TOOL" "$ACTUAL_TEXT" "$ACTUAL_IMAGE" \
          "$TEST_DIR/input.png" "$TEST_DIR/metadata4.png" > /dev/null \
   || die "$LINENO: terminal tile next to chain reaction (right)"

# ................................................................
# Test other annotations.

# 1:     (yy)
# 2: [##][##]
convert \
   "(" "$TEST_DIR/blank.png" "$TEST_DIR/blank.png" +append ")" \
   "(" "$TEST_DIR/solid.png" "$TEST_DIR/solid.png" +append ")" \
   -append \
   "$TEST_DIR/input.png"

convert "$TEST_DIR/input.png" \
   -fill yellow -draw "circle 48,16 48,8" \
   "$TEST_DIR/metadata.png"

"./$TOOL" "$ACTUAL_TEXT" "$ACTUAL_IMAGE" \
          "$TEST_DIR/input.png" "$TEST_DIR/metadata.png"

grep -qF "world.INIT_BALLS = {{48, 16}}" "$ACTUAL_TEXT" \
   || die "$LINENO: throwable annotation"

# 1:     (cc)
# 2: [##][##]
convert "$TEST_DIR/input.png" \
   -fill cyan -draw "circle 48,16 48,8" \
   "$TEST_DIR/metadata.png"

cat <<EOT > "$EXPECTED_TEXT"
world.input =
{
   4,
   -2, 65537,
}
world.metadata =
{
   {0, 4096},
   {1, 1},
}
EOT

pgmmake 0 $((1920-32)) 32 > "$TEST_DIR/t.pgm"
pnmtopng -alpha="$TEST_DIR/t.pgm" "$TEST_DIR/t.pgm" > "$TEST_DIR/trailer.png"
convert +append "$TEST_DIR/solid.png" "$TEST_DIR/trailer.png" "$EXPECTED_IMAGE"

"./$TOOL" "$ACTUAL_TEXT" "$ACTUAL_IMAGE" \
          "$TEST_DIR/input.png" "$TEST_DIR/metadata.png"
check_output "$LINENO: chain reaction start"

# 1:     [cc]
# 2: [##][#c]
convert "$TEST_DIR/input.png" \
   -fill cyan -draw "rectangle 40,8 56,24" \
   -fill cyan -draw "circle 48,48 48,40" \
   "$TEST_DIR/metadata.png"

cat <<EOT > "$EXPECTED_TEXT"
world.input =
{
   4,
   -2, 65537,
}
world.metadata =
{
   {0, 8192},
   {1, 4097},
}
EOT

"./$TOOL" "$ACTUAL_TEXT" "$ACTUAL_IMAGE" \
          "$TEST_DIR/input.png" "$TEST_DIR/metadata.png"
check_output "$LINENO: terminal reaction"

# 1:     (mm)
# 2: [##][#c]
convert "$TEST_DIR/input.png" \
   -fill black -draw "rectangle 32,0 64,32" \
   -fill magenta -draw "circle 48,16 48,8" \
   "$TEST_DIR/metadata.png"

cat <<EOT > "$EXPECTED_TEXT"
world.input =
{
   4,
   -2, 65537,
}
world.metadata =
{
   {0, 4105},
   {1, 1},
}
EOT

"./$TOOL" "$ACTUAL_TEXT" "$ACTUAL_IMAGE" \
          "$TEST_DIR/input.png" "$TEST_DIR/metadata.png"
check_output "$LINENO: chain reaction effect"

# 1:     [mm]
# 2: [##][#c]
convert "$TEST_DIR/input.png" \
   -fill black -draw "rectangle 32,0 64,32" \
   -fill magenta -draw "rectangle 40,8 56,24" \
   -fill cyan -draw "circle 48,48 48,40" \
   "$TEST_DIR/metadata.png"

cat <<EOT > "$EXPECTED_TEXT"
world.input =
{
   4,
   -2, 65537,
}
world.metadata =
{
   {0, 8201},
   {1, 4097},
}
EOT

"./$TOOL" "$ACTUAL_TEXT" "$ACTUAL_IMAGE" \
          "$TEST_DIR/input.png" "$TEST_DIR/metadata.png"
check_output "$LINENO: terminal reaction effect"

# 1:
# 2:
# 3: [##][##][##][##][##]
# 4:
# 5:
convert \
   "$TEST_DIR/blank.png" \
   "$TEST_DIR/blank.png" \
   "$TEST_DIR/solid.png" \
   "$TEST_DIR/blank.png" \
   "$TEST_DIR/blank.png" \
   -append \
   "$TEST_DIR/column.png"
convert \
   "$TEST_DIR/column.png" \
   "$TEST_DIR/column.png" \
   "$TEST_DIR/column.png" \
   "$TEST_DIR/column.png" \
   "$TEST_DIR/column.png" \
   +append \
   "$TEST_DIR/input.png"
convert \
   "$TEST_DIR/input.png" \
   -fill red -draw "rectangle 8,72 24,88" \
   -fill red -draw "rectangle 40,72 56,88" \
   -fill red -draw "rectangle 72,72 88,88" \
   -fill red -draw "rectangle 104,72 120,88" \
   -fill red -draw "rectangle 136,72 152,88" \
   "$TEST_DIR/metadata.png"

cat <<EOT > "$EXPECTED_TEXT"
world.input =
{
   15,
   -10, 65537, 65537, 1,
}
world.metadata =
{
   {0,  0,  0,  0, 0},
   {0,  0,  0,  0, 0},
   {0, 48, 48, 48, 0},
   {0,  0,  0,  0, 0},
   {0,  0,  0,  0, 0},
}
EOT

"./$TOOL" "$ACTUAL_TEXT" "$ACTUAL_IMAGE" \
          "$TEST_DIR/input.png" "$TEST_DIR/metadata.png"
check_output "$LINENO: ghost collision"

# ................................................................
# Test starting position.

# 1: [##]
# 2: [##]
# 3: [##]
# 4: [##]
# 5: <##>
# 6: [##]
# 7: [##]
convert +append \
   "$TEST_DIR/solid.png" \
   "$TEST_DIR/blank.png" \
   "$TEST_DIR/blank.png" \
   "$TEST_DIR/blank.png" \
   "$TEST_DIR/blank.png" \
   "$TEST_DIR/row.png"
convert -append \
   "$TEST_DIR/row.png" \
   "$TEST_DIR/row.png" \
   "$TEST_DIR/row.png" \
   "$TEST_DIR/row.png" \
   "$TEST_DIR/row.png" \
   "$TEST_DIR/row.png" \
   "$TEST_DIR/row.png" \
   "$TEST_DIR/input.png"
convert "$TEST_DIR/input.png" \
   -fill blue -draw "circle 32,144 40,144" \
   "$TEST_DIR/metadata.png"

"./$TOOL" "$ACTUAL_TEXT" "$ACTUAL_IMAGE" \
          "$TEST_DIR/input.png" "$TEST_DIR/metadata.png"

grep -qF "world.START = {{31, 144}}" "$ACTUAL_TEXT" \
   || die "$LINENO: one-sided starting position"

# Verify that starting position must be marked on a mountable tile.
convert "$TEST_DIR/input.png" \
   -fill blue -draw "circle 96,144 104,144" \
   "$TEST_DIR/metadata.png"

"./$TOOL" "$ACTUAL_TEXT" "$ACTUAL_IMAGE" \
          "$TEST_DIR/input.png" "$TEST_DIR/metadata.png" > /dev/null \
   && die "$LINENO: bad starting position"

# Verify that starting position works on two-sided walls.
# 1:         [##]
# 2:         [##]
# 3:         [##]
# 4:         <##>
# 5:         [##]
# 6:         [##]
# 7:         [##]
convert +append \
   "$TEST_DIR/blank.png" \
   "$TEST_DIR/blank.png" \
   "$TEST_DIR/blank.png" \
   "$TEST_DIR/solid.png" \
   "$TEST_DIR/blank.png" \
   "$TEST_DIR/blank.png" \
   "$TEST_DIR/blank.png" \
   "$TEST_DIR/row.png"
convert -append \
   "$TEST_DIR/row.png" \
   "$TEST_DIR/row.png" \
   "$TEST_DIR/row.png" \
   "$TEST_DIR/row.png" \
   "$TEST_DIR/row.png" \
   "$TEST_DIR/row.png" \
   "$TEST_DIR/row.png" \
   "$TEST_DIR/input.png"
convert "$TEST_DIR/input.png" \
   -fill blue -draw "circle 128,112 136,112" \
   "$TEST_DIR/metadata.png"

"./$TOOL" "$ACTUAL_TEXT" "$ACTUAL_IMAGE" \
          "$TEST_DIR/input.png" "$TEST_DIR/metadata.png"

grep -qF "world.START = {{127, 112}}" "$ACTUAL_TEXT" \
   || die "$LINENO: two-sided starting position"


# ................................................................
# Test teleport station.

# 1:
# 2:
# 3:
# 4:
# 5: [##][##]<##>[##][##]
convert \
   "(" "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       +append ")" \
   "(" "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       +append ")" \
   "(" "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       +append ")" \
   "(" "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       "$TEST_DIR/blank.png" \
       +append ")" \
   "(" "$TEST_DIR/solid.png" \
       "$TEST_DIR/solid.png" \
       "$TEST_DIR/solid.png" \
       "$TEST_DIR/solid.png" \
       "$TEST_DIR/solid.png" \
       +append ")" \
   -append \
   "$TEST_DIR/input.png"
convert \
   "$TEST_DIR/input.png" \
   -fill blue -draw "circle 80,128 88,128" \
   "$TEST_DIR/metadata.png"

"./$TOOL" "$ACTUAL_TEXT" "$ACTUAL_IMAGE" \
          "$TEST_DIR/input.png" "$TEST_DIR/metadata.png"

grep -qF "world.TELEPORT_POSITIONS = {{80, 128}}" "$ACTUAL_TEXT" \
   || die "$LINENO: teleport stations"

# Verify that unmountable teleport stations are flagged.
# 1:
# 2:
# 3:         [##]
# 4:
# 5: [##][##]<##>[##][##]
convert \
   "$TEST_DIR/metadata.png" \
   -fill black -draw "rectangle 64,64 95,95" \
   "$TEST_DIR/metadata2.png"

"./$TOOL" "$ACTUAL_TEXT" "$ACTUAL_IMAGE" \
          "$TEST_DIR/input.png" "$TEST_DIR/metadata2.png" > /dev/null \
   && die "$LINENO: bad teleport station"

# ................................................................
# Cleanup.
rm -rf "$TEST_DIR"
exit 0
