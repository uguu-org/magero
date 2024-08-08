#!/bin/bash
# Verify that the build process is deterministic.
#
# Note that this only verifies that the intermediate helper scripts are
# deterministic.  We assume that Inkscape itself is deterministic in its
# rasterization process, and have never observed any behavior to the
# contrary.  But if we want to be really paranoid, we can replace the
# body of "clean_preserving_cache" to be just "make clean".

set -euo pipefail

# Do a "make clean" without deleting t_svg_cache_* files.
#
# This is to avoid invoking Inkscape repeatedly, which accounts for most of
# the build time.
function clean_preserving_cache
{
   if ( ls t_svg_cache_* > /dev/null 2>&1 ); then
      # Cache available, move them to a temporary directory first before
      # running "make clean", then move them back.
      TEMP_CACHE_DIR=$(mktemp -d)
      mv t_svg_cache_* "$TEMP_CACHE_DIR/"
      make clean
      mv $TEMP_CACHE_DIR/t_svg_cache_* .
      rmdir "$TEMP_CACHE_DIR"
   else
      # No cache available, so we can just do "make clean".
      make clean
   fi
}


# Build a subset of the targets related to world map tiles.  These are
# the ones that will go through various add_* scripts.  If there are any
# non-determinism in our build process, it will probably come from one
# of these scripts.
ARTIFACTS=$(echo t_{ibg,bg,fg}{0,1,2,3}.svg t_gray_{ibg,bg,fg}{0,1,2,3}.png t_metadata.svg metadata.png)
DIGEST=artifacts_digest.txt

# Run two clean builds, collecting digest in the first run and checking
# digest in the second run.
clean_preserving_cache
make -j $ARTIFACTS
md5sum $ARTIFACTS > "$DIGEST"

clean_preserving_cache
make -j $ARTIFACTS
if ( md5sum -c "$DIGEST" ); then
   rm "$DIGEST"
   echo "All good."
   exit 0
fi

rm "$DIGEST"
echo "Build is not deterministic"
exit 1
