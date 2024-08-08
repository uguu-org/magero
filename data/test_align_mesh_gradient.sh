#!/bin/bash

if [[ $# -ne 1 ]]; then
   echo "$0 {align_mesh_gradient.pl}"
   exit 1
fi
TOOL=$1

set -euo pipefail
INPUT=$(mktemp)
EXPECTED_OUTPUT=$(mktemp)
ACTUAL_OUTPUT=$(mktemp)

function die
{
   echo "$1"
   rm -f "$INPUT" "$EXPECTED_OUTPUT" "$ACTUAL_OUTPUT"
   exit 1
}

# Generate test data.
cat <<EOT > "$INPUT"
<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<svg xmlns:inkscape="http://www.inkscape.org/namespaces/inkscape" xmlns:sodipodi="http://sodipodi.sourceforge.net/DTD/sodipodi-0.dtd" xmlns:xlink="http://www.w3.org/1999/xlink" xmlns="http://www.w3.org/2000/svg" xmlns:svg="http://www.w3.org/2000/svg">
   <defs>
      <meshgradient id="m1" x="1280.0001" y="2559.9999">
         <meshrow>
            <meshpatch>
               <stop path="l 32,0" />
               <stop path="l 0.0005,31.9995" />
               <stop path="l -32.0005,1e-9" />
               <stop path="l -1.5e-13,-32" />
            </meshpatch>
         </meshrow>
      </meshgradient>
   </defs>
</svg>
EOT
cat <<EOT > "$EXPECTED_OUTPUT"
<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<svg xmlns:inkscape="http://www.inkscape.org/namespaces/inkscape" xmlns:sodipodi="http://sodipodi.sourceforge.net/DTD/sodipodi-0.dtd" xmlns:xlink="http://www.w3.org/1999/xlink" xmlns="http://www.w3.org/2000/svg" xmlns:svg="http://www.w3.org/2000/svg">
   <defs>
      <meshgradient id="m1" x="1280" y="2560">
         <meshrow>
            <meshpatch>
               <stop path="l 32,0" />
               <stop path="l 0,32" />
               <stop path="l -32,0" />
               <stop path="l 0,-32" />
            </meshpatch>
         </meshrow>
      </meshgradient>
   </defs>
</svg>
EOT

# Run tool.
"./$TOOL" "$INPUT" > "$ACTUAL_OUTPUT"

if ! ( diff -w -B "$EXPECTED_OUTPUT" "$ACTUAL_OUTPUT" ); then
   die "Output mismatched"
fi

# Try again to confirm that output is idempotent.
mv -f "$ACTUAL_OUTPUT" "$EXPECTED_OUTPUT"
"./$TOOL" "$INPUT" | "./$TOOL" > "$ACTUAL_OUTPUT"
if ! ( diff -w -B "$EXPECTED_OUTPUT" "$ACTUAL_OUTPUT" ); then
   die "Output is not idempotent"
fi

# Cleanup.
rm -f "$INPUT" "$EXPECTED_OUTPUT" "$ACTUAL_OUTPUT"
exit 0
