#!/bin/bash

if [[ $# -ne 1 ]]; then
   echo "$0 {check_aligned_paths.pl}"
   exit 1
fi
TOOL=$1

set -euo pipefail
INPUT=$(mktemp)
OUTPUT=$(mktemp)

function die
{
   echo "$1"
   rm -f "$INPUT" "$OUTPUT"
   exit 1
}

# Generate file containing all aligned points.
cat <<EOT > "$INPUT"
<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<svg xmlns:inkscape="http://www.inkscape.org/namespaces/inkscape" xmlns:sodipodi="http://sodipodi.sourceforge.net/DTD/sodipodi-0.dtd" xmlns:xlink="http://www.w3.org/1999/xlink" xmlns="http://www.w3.org/2000/svg" xmlns:svg="http://www.w3.org/2000/svg">
<g id="ignored">
   <path id="not_inside_a_layer" />
</g>
<g id="simple" inkscape:groupmode="layer">
   <path id="ok1" d="m 32,32 h 32 v 32 H 320 V 640 l -32,32 z M 64,128 L 96,96 Z" />
   <rect id="ok2" x="320" y="480" width="64" height="256" />
</g>
<g id="transforms_test" transform="" inkscape:groupmode="layer">
   <g id="t1" transform="translate(-8)">
      <rect id="ok3" x="40" y="32" width="64" height="32" />
   </g>
   <g id="t2" transform="translate(-4,-8)">
      <rect id="ok4" x="36" y="40" width="64" height="32" />
   </g>
   <g id="t3" transform="scale(2)">
      <rect id="ok5" x="16" y="16" width="16" height="16" />
   </g>
   <g id="t4" transform="scale(2,4)">
      <rect id="ok5" x="16" y="8" width="16" height="8" />
   </g>
   <g id="t5" transform="translate(22,12)">
      <g id="t6" transform="scale(2)">
         <rect id="ok6" x="5" y="10" width="16" height="16" />
      </g>
   </g>
   <g id="t7" transform="matrix(1,0,5,0,1,6)">
      <rect id="ok7" x="27" y="26" width="32" height="32" />
   </g>
</g>
</svg>
EOT

# Run tool.  There should be no failure.
"./$TOOL" "$INPUT" || die "$LINENO: Unexpected failure: $?"

# Verify that there is no output on success.
"./$TOOL" "$INPUT" | diff /dev/null - || die "$LINENO: Unexpected output"

# Verify that reading from stdin produced identical result.
cat "$INPUT" | "./$TOOL" | diff /dev/null - \
   || die "$LINENO: Bad handling of stdin"

# Generate bad input.
cat <<EOT > "$INPUT"
<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<svg xmlns:inkscape="http://www.inkscape.org/namespaces/inkscape" xmlns:sodipodi="http://sodipodi.sourceforge.net/DTD/sodipodi-0.dtd" xmlns:xlink="http://www.w3.org/1999/xlink" xmlns="http://www.w3.org/2000/svg" xmlns:svg="http://www.w3.org/2000/svg">
<g inkscape:groupmode="layer">
   <g id="bad_transform1" transform="bad"></g>
   <g id="bad_transform2" transform="matrix(1)"></g>
   <g id="bad_transform3" transform="matrix(1,2,3,4,5,6,7)"></g>
   <g id="bad_transform4" transform="scale(x)"></g>
   <g id="bad_transform5" transform="scale(1,2,3)"></g>
   <g id="bad_transform6" transform="translate(x)"></g>
   <g id="bad_transform7" transform="translate(1,2,3)"></g>
   <circle id="bad_element1" />
   <ellipse id="bad_element2" />
   <image id="bad_element3" />
   <text id="bad_element4">
      <tspan id="bad_element5" />
   </text>
   <rect id="bad_rect1" x="1" y="0" width="31" height="32" />
   <rect id="bad_rect2" x="0" y="2" width="32" height="30" />
   <rect id="bad_rect3" x="32" y="32" width="33" height="32" />
   <rect id="bad_rect4" x="32" y="32" width="32" height="31" />
   <rect id="bad_rect5" x="0" y="0" width="32" height="32" rx="4" />
   <rect id="bad_rect6" x="0" y="0" width="32" height="32" ry="4" />
   <path id="bad_command1" d="m 0,0 c 1,2 3,4 5,6" />
   <path id="bad_command2" d="m 0,0 C 1,2 3,4 5,6" />
   <path id="bad_command3" d="m 0,0 s 1,2 3,4" />
   <path id="bad_command4" d="m 0,0 S 1,2 3,4" />
   <path id="bad_command5" d="m 0,0 q 1,2 3,4" />
   <path id="bad_command6" d="m 0,0 t 1,2" />
   <path id="bad_command7" d="m 0,0 h 32 z 32" />
   <path id="bad_param1" d="m - z" />
   <path id="bad_param2" d="m 0 z" />
   <path id="bad_param3" d="M - z" />
   <path id="bad_param4" d="l - z" />
   <path id="bad_param5" d="L - z" />
   <path id="bad_param6" d="m 0,0 h - z" />
   <path id="bad_point1" d="m 33,32" />
   <path id="bad_point2" d="m 32,31" />
   <path id="bad_point3" d="M 32.5,32" />
   <path id="bad_point4" d="M 32,32.5" />
   <path id="bad_angle1" d="m 0,0 l 32,64" />
   <path id="bad_angle2" d="m 0,32 l -32,-64" />
   <!-- Extra test to verify that z command updates current position -->
   <path id="closepath_test" d="m 32,32 h 32 v -32 z m 63,0 h 32 v -32 z" />
</g>
</svg>
EOT

"./$TOOL" "$INPUT" > "$OUTPUT" && die "$LINENO: Unexpected success: $?"

for i in bad_transform{1,2,3,4,5,6,7} \
         bad_element{1,2,3,4,5} \
         bad_rect{1,2,3,4,5,6} \
         bad_command{1,2,3,4,5,6,7} \
         bad_param{1,2,3,4,5,6} \
         bad_point{1,2,3,4} \
         bad_angle{1,2} \
         "(95,32): Unaligned point"; do
   grep -qF "$i" "$OUTPUT" || die "$LINENO: Missing $i"
done

# Verify that reading from stdin produces identical output.
cat "$INPUT" | ( "./$TOOL" || true ) | diff "$OUTPUT" - \
   || die "$LINENO: Bad handling of stdin"

# Cleanup.
rm -f "$INPUT" "$OUTPUT"
exit 0
