#!/bin/bash
# Cleanup redundant style attributes in world_master.svg
#
# Takes ~10 minutes to run since it may involve rebuilding everything twice.

if [[ $# -ne 0 ]]; then
   echo "This script wasn't expecting any arguments"
   exit 1
fi

INPUT=world_master.svg
OUTPUT=t_clean_world_master.svg
SELECTED_LAYERS=$(echo metadata.png t_gray_{ibg,bg,fg}{0,1,2,3}.png)
DIGEST=t_images_digest.txt

set -euo pipefail
cd $(dirname "$0")/

# Don't need to do any extra tests if input is already clean.
perl cleanup_styles.pl "$INPUT" > "$OUTPUT"
if ( diff -q "$INPUT" "$OUTPUT" ); then
   echo "$INPUT is already clean"
   exit 0
fi

# Update timestamp of the input image to force a rebuild.
#
# If we don't do this, running this script twice in a row will always succeed,
# because the intermediate files leftover from the previous run will be newer
# than the input file.
touch "$INPUT"

# Rasterize layers with the original input, and generate a digest of the
# rasterized images.
make -j $SELECTED_LAYERS
md5sum $SELECTED_LAYERS > "$DIGEST"

# Update output timestamp to make sure it's newer than all intermediates.
# This is needed to force rebuilds.
touch "$OUTPUT"

# Rasterize layers with the updated output, and compare these against the
# digests generated earlier.
#
# Note that this only includes the layers that will end up in the final
# game.  It's conceivable to have a bug in cleanup_styles.pl that caused a
# perceptible difference, but that difference is not captured by the layers
# we have selected here.  We don't really care about those.
make -j world_master="$OUTPUT" $SELECTED_LAYERS
md5sum -c "$DIGEST"

# If we didn't bail out due to "set -e", it means all the images before and
# after the change were identical, so we can replace the input.
ls -l "$INPUT"
ls -l "$OUTPUT"
mv -f "$OUTPUT" "$INPUT"
echo "Updated $INPUT"
exit 0
