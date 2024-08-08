#!/bin/bash
# Build frame 0 image and output a cropped Sixel image to console.
#
# Usage:
#
#    ./preview.sh {x1} {y1} {x2} {y2} [scale]
#
# (x1,y1) is the upper left corner and (x2,y2) is the lower right corner.
#
# If 5th argument is supplied, output will be scaled by that amount,
# otherwise output scaling defaults to 1.
#
# This script is for iterating on edits to small regions of the map.
# It runs much faster than building full resolution images of all map
# layers, and we get the result right in the console.


set -euo pipefail

# Parse preview settings.
if [[ $# -ne 4 && $# -ne 5 ]]; then
   echo "$0 {x1} {y1} {x2} {y2} [scale]"
   exit 1
fi
X1=$1
Y1=$2
X2=$3
Y2=$4
FRAME=0

# Align start coordinate such that it's a multiple of 8.  We need to do this
# to ensure that the dither pattern is consistent.
while [[ $(($X1 % 8)) -gt 0 ]]; do
   X1=$(($X1 - 1))
done
while [[ $(($Y1 % 8)) -gt 0 ]]; do
   Y1=$(($Y1 - 1))
done

# Check dimensions.
WIDTH=$(($X2 - $X1))
HEIGHT=$(($Y2 - $Y1))
if [[ $WIDTH -le 0 ]]; then
   echo "Bad width: $X2 - $X1 = $WIDTH"
   exit 1
fi
if [[ $HEIGHT -le 0 ]]; then
   echo "Bad height: $Y2 - $Y1 = $HEIGHT"
   exit 1
fi

# Set output scale.
SCALE="100%"
if [[ $# -eq 5 ]]; then
   SCALE="$(($5 * 100))%"
fi

# Change to data directory before running make.
cd $(dirname "$0")/

# Check if [a1,a2) intersects [b1,b2), return 0 if so.
function intersect_interval
{
   local a1=$1
   local a2=$2
   local b1=$3
   local b2=$4

   if [[ $a1 -ge $b1 && $a1 -lt $b2 ]]; then
      return 0
   fi
   if [[ $b1 -ge $a1 && $b1 -lt $a2 ]]; then
      return 0
   fi
   return 1
}

# Check if selected region intersects some predefined region.
function intersect
{
   local rx1=$1
   local ry1=$2
   local rx2=$3
   local ry2=$4

   if ( intersect_interval $X1 $X2 $rx1 $rx2 ) &&
      ( intersect_interval $Y1 $Y2 $ry1 $ry2 ); then
      return 0
   fi
   return 1
}

# Select layers based whether decorations are needed.
IBG=t_undecorated_ibg$FRAME
BG=t_undecorated_bg$FRAME
FG=t_undecorated_fg$FRAME

# Stars + dense leaves + sparse leaves + bookshelves.
if ( intersect 0 0 9600 608 ) ||
   ( intersect 660 626 1488 1252 ) ||
   ( intersect 1234 1123 6722 4733 ) ||
   ( intersect 416 1696 1056 2272 ); then
   IBG=t_ibg$FRAME
fi

# Item map.
if ( intersect 7449 2208 7751 2410 ); then
   BG=t_bg$FRAME
fi

# Waterfall + collapsible marble track + door + blackhole debris.
if ( intersect 883 2941 2120 5057 ) ||
   ( intersect 7776 4768 9120 6112 ) ||
   ( intersect 8128 6016 8224 6240 ) ||
   ( intersect 8320 4160 8992 4480 ); then
   FG=t_fg$FRAME
fi

# Generate output makefile.  We generate makefiles to build the preview image,
# using make to parallelize the build steps for faster incremental updates.
#
# All temporary files within the makefile are generated with a deterministic
# prefix based on selected area size.  Note that scaling factor is not part of
# the prefix, since we don't need to rebuild all intermediate images for a
# scaling factor change.  Also note that the makefile itself uses a
# deterministic name regardless of selected area, since generating the
# makefile itself is fairly cheap and we can just repeat that on each run.
PREFIX="t_preview_${X1}_${Y1}_${X2}_${Y2}"
MAKEFILE=$(dirname "$0")/t_preview.makefile
TAB=$(echo -e "\t")

cp Makefile "$MAKEFILE"

# Rasterize a small region and composite those.  This will be less efficient
# from a cache point of view if we generate previews from many different
# areas, but the typical use case is to repeatedly preview a single fixed
# area after each edit, and for that case we would save a few seconds by
# rasterizing small areas.
#
# Note that this skips certain steps that would have been involved rasterizing
# layers for production, such as removal of hidden tiles.  We need those
# optimizations for production, but they cost extra time when we just want to
# preview a region.  Because those steps are skipped, this script always runs
# faster than building debug_frame0.png and cropping from that.
cat <<EOT >> "$MAKEFILE"
preview: $PREFIX.png
${TAB}convert \$< -scale "$SCALE" six:-

$PREFIX.png: ${PREFIX}_${IBG}.png ${PREFIX}_${BG}.png ${PREFIX}_${FG}.png
${TAB}convert -size "${WIDTH}x${HEIGHT}" "xc:#ffffff" -colorspace Gray -depth 8 "${PREFIX}_${IBG}.png" -composite "${PREFIX}_${BG}.png" -composite "${PREFIX}_${FG}.png" -composite \$@

${PREFIX}_${IBG}.png: ${PREFIX}_gray_${IBG}.png dither.exe
${TAB}./dither.exe \$< \$@

${PREFIX}_${BG}.png: ${PREFIX}_gray_${BG}.png dither.exe
${TAB}./dither.exe \$< \$@

${PREFIX}_${FG}.png: ${PREFIX}_gray_${FG}.png dither.exe
${TAB}./dither.exe \$< \$@

${PREFIX}_gray_${IBG}.png: ${IBG}.svg
${TAB}./svg_to_png.sh \$< \$@ "$X1" "$Y1" "$X2" "$Y2"

${PREFIX}_gray_${BG}.png: ${BG}.svg
${TAB}./svg_to_png.sh \$< \$@ "$X1" "$Y1" "$X2" "$Y2"

${PREFIX}_gray_${FG}.png: ${FG}.svg
${TAB}./svg_to_png.sh \$< \$@ "$X1" "$Y1" "$X2" "$Y2"

EOT
exec make -j -f "$MAKEFILE" preview
