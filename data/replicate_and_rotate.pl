#!/usr/bin/perl -w
# Usage:
#
#  perl replicate_and_rotate.pl sprites_master.svg > sprites_rotated.svg
#
# Read sprites_master.svg from stdin and write sprites_rotated.svg to
# stdout, with all the parts replicated and rotated.  This is so that
# we get one SVG that has shapes for all rotation angles, which can
# then be exported to PNG to produce the final bitmap we want.
#
# This script saves us the trouble of having to apply all the rotation
# transformations manually.  So if there is some graphical change we need to
# make, we will apply the edits to sprites_master.svg and run this script.
#
# Motivation for all this trouble is to have all the sprite rotations done
# by Inkscape using vector data, which would produce higher quality bitmaps
# that better preserves all edges than if we were to do all rotations with
# bitmap data.  Even though we want vector-based rotations, note that we
# only generate rotated shapes in the range of [0,90) degrees, since the
# remaining bitmaps can be obtained using bitmap-based operations on the
# [0,90) bitmaps.

use strict;
use XML::LibXML;
use constant PI => 3.14159265358979323846264338327950288419716939937510;

# List of groups that we want to rotate.
#  (cx, cy) = center of rotation.
#  dx = horizontal offset for duplicated sprites.
my %rotate_groups =
(
   "arm_bottom" => {"cx" => 31.5, "cy" => 32.5,  "dx" => 160},
   "arm_top" =>    {"cx" => 31.5, "cy" => 192.5, "dx" => 160},
   "finger" =>     {"cx" => 31.5, "cy" => 352.5, "dx" => 80},
);


# Check if an XML node is a group that we are interested in replicating.
# Returns nonzero if so.
sub desirable_group($)
{
   my ($node) = @_;

   if( defined($node->{'inkscape:label'}) )
   {
      my $label = $node->{'inkscape:label'};
      return exists $rotate_groups{$label};
   }
   return 0;
}

# Apply rotation to a group and shift it toward the right.
sub rotate_and_shift_group($$$$$$)
{
   my ($group, $angle, $cx, $cy, $dx, $new_label) = @_;

   # SVG rotation angles are in degrees, but we want radians for Perl.
   my $a = $angle * PI / 180.0;

   # Rotation causes coordinate to be transformed as follows:
   #
   #  t(x) = (x - px) * cos(a) - (y - py) * sin(a) + px
   #  t(y) = (x - px) * sin(a) + (y - py) * cos(a) + py
   #
   # Where (px,py) is the center of rotation for SVG.  We want to solve for
   # (px,py) such that:
   #
   #  t(cx) == cx + dx
   #  t(cy) == cy
   #
   #  cx + dx = (cx - px) * cos(a) - (cy - py) * sin(a) + px
   #  cy      = (cx - px) * sin(a) + (cy - py) * cos(a) + py
   #
   #  cx*cos(a) - px*cos(a) - cy*sin(a) + py*sin(a) + px = cx+dx
   #  cx*sin(a) - px*sin(a) + cy*cos(a) - py*cos(a) + py = cy
   #
   #  px*(1 - cos(a)) + py*sin(a) = cx+dx - cx*cos(a) + cy*sin(a)
   #  px*(-sin(a)) + py*(1 - cos(a)) = cy - cx*sin(a) - cy*cos(a)
   #
   # Applying Cramer's rule here.
   my $a1 = 1 - cos($a);
   my $b1 = sin($a);
   my $c1 = $cx + $dx - $cx * cos($a) + $cy * sin($a);
   my $a2 = -sin($a);
   my $b2 = 1 - cos($a);
   my $c2 = $cy - $cx * sin($a) - $cy * cos($a);

   my $d = $a1 * $b2 - $b1 * $a2;
   my $px = ($c1 * $b2 - $b1 * $c2) / $d;
   my $py = ($a1 * $c2 - $c1 * $a2) / $d;

   $group->{'transform'} = "rotate($angle,$px,$py)";
   $group->{'inkscape:label'} = $new_label;
}

# Duplicate a group and apply rotation, then shift the rotated group right.
sub duplicate_and_rotate_group($)
{
   my ($group) = @_;

   my $group_label = $group->{'inkscape:label'};
   my $cx = $rotate_groups{$group_label}{"cx"};
   my $cy = $rotate_groups{$group_label}{"cy"};
   my $dup_offset = $rotate_groups{$group_label}{"dx"};

   # Generate the rotations we want.  Our shapes are all initially pointing
   # downwards, and we want to apply the transformations such that first
   # shape points right and last shape points down.  This is so that the end
   # of arm position can be calculated using the usual transformation:
   #
   #     [x, y] = [length * cos(A), length * sin(A)]
   #
   # Where A is the angle in degrees *and* the index of the rotated shape.
   #
   # The loop below starts at -90 degrees to rotate the initial shape from
   # pointing down to pointing right.  After that, an increasing angle will
   # result in clockwise rotation, because Y grows downward in SVG.
   for(my $angle = -90; $angle < 0; $angle++)
   {
      my $new_label = $group_label . ($angle + 90);
      if( $angle == -90 )
      {
         # For the initial group, transformations are applied to the
         # group directly.
         rotate_and_shift_group($group, $angle, $cx, $cy, 0, $new_label);
      }
      else
      {
         # For all subsequent groups, transformations are applied to a
         # cloned group.  Note that we have already modified the
         # initial group's transformation and label, but that's fine
         # since we will overwrite those.
         my $clone = $group->cloneNode(1);
         my $dx = ($angle + 90) * $dup_offset;
         rotate_and_shift_group($clone, $angle, $cx, $cy, $dx, $new_label);
         $group->addSibling($clone);
      }
   }
}

# Remove redundant xmlns attributes from XML.
#
# This is a string replacement rather than an XML operation.  As far
# as I can tell, LibXML can not do clones without inserting redundant
# namespace attributes, and any attempts to remove those attributes
# are silently ignored.  This is somehow advertised as a feature that
# allows cloned nodes to behave as complete documents.  It's a
# misfeature I do not want, and this function is my response.
sub remove_redunant_namespaces_from_groups($)
{
   my ($text) = @_;

   # Split the text to two parts, since we still want to keep namespaces in
   # the header tag.
   $text =~ m{^(.*<svg[^<>]+>)(.*</svg>\s*)$}s or die;
   my ($header, $body) = ($1, $2);

   # Global replace to wipe out all xmlns attributes in body.
   $body =~ s/ xmlns(?::[^= ]+)?="[^"]*"//gs;
   return $header . $body;
}


# Load XML from stdin or first argument.
my $dom = XML::LibXML->load_xml(string => join "", <ARGV>);

# Iterate through the groups we care about.
foreach my $group ($dom->getElementsByTagName("g"))
{
   if( desirable_group($group) )
   {
      duplicate_and_rotate_group($group);
   }
}

# Output updated XML.
print remove_redunant_namespaces_from_groups($dom->toString()), "\n";
