#!/usr/bin/perl -w
# Usage:
#
#   perl align_mesh_gradient.pl {input.svg} > {output.svg}
#
# Despite drawing with integer grid alignment, we find that mesh gradient
# control points are often slightly off from the grid-aligned coordinates,
# which causes some tiles that should have been exact duplicates to differ
# by a few pixels.  This script is meant to shift those coordinate values
# so that they are grid aligned.
#
# As a side note, SVG "advanced gradients" was first proposed in 2011, and
# Inkscape has supported mesh gradients since 0.92 (released in 2017-01-01),
# but as of 2024-05-10, mesh gradients still has not yet made it to SVG
# standard.  This script depends on the syntax that's used by Inkscape since
# that's the only SVG interaction that we care about, but there is no
# telling that the syntax is stable.
#
# References:
# https://dev.w3.org/SVG/modules/advancedgradients/SVGAdvancedGradientReqs.html
# https://wiki.inkscape.org/wiki/Mesh_Gradients

use strict;
use XML::LibXML;

use constant ALIGN_THRESHOLD => 0.01;


# Return an integer-aligned value.
sub align_value($)
{
   my ($n) = @_;

   my $a = $n < 0 ? -int(-$n + 0.5) : int($n + 0.5);
   return abs($n - $a) < ALIGN_THRESHOLD ? $a : $n;
}

# Check that current element name matches what we expected.
sub is_element($$)
{
   my ($node, $expected_name) = @_;

   my $name = eval('$node->nodeName');
   return defined $name && $name eq $expected_name;
}

# Process <stop> elements.
sub process_stop($)
{
   my ($node) = @_;

   return unless is_element($node, "stop");

   my $path = eval('$node->{"path"}');
   return unless defined $path;
   return unless $path =~ /^\s*
                            (l\s+)
                            ([-]?\d+(?:\.\d+)?(?:e-\d+)?)
                            (\s*[,]?\s*)
                            ([-]?\d+(?:\.\d+)?(?:e-\d+)?)
                            \s*$/x;
   my ($command, $x, $comma, $y) = ($1, align_value($2), $3, align_value($4));
   $node->{"path"} = $command . $x . $comma . $y;
}

# Process <meshpatch> elements.
sub process_meshpatch($)
{
   my ($node) = @_;

   if( is_element($node, "meshpatch") )
   {
      foreach my $child ($node->childNodes())
      {
         process_stop($child);
      }
   }
}

# Process <meshrow> elements.
sub process_meshrow($)
{
   my ($node) = @_;

   if( is_element($node, "meshrow") )
   {
      foreach my $child ($node->childNodes())
      {
         process_meshpatch($child);
      }
   }
}

# Process <meshgradient> elements.
sub process_meshgradient($)
{
   my ($node) = @_;

   foreach my $attribute ("x", "y")
   {
      my $value = eval("\$node->{'$attribute'}");
      if( defined($value) )
      {
         $node->{$attribute} = align_value($value);
      }
   }

   foreach my $child ($node->childNodes())
   {
      process_meshrow($child);
   }
}

# Process generic elements recursively.
sub process_generic_element($);
sub process_generic_element($)
{
   my ($node) = @_;

   foreach my $child ($node->childNodes())
   {
      if( is_element($child, "meshgradient") )
      {
         process_meshgradient($child);
      }
      else
      {
         process_generic_element($child);
      }
   }
}


# Load XML from stdin or first argument.
my $dom = XML::LibXML->load_xml(string => join "", <ARGV>);

# Process elements and write updated XML to stdout.
process_generic_element($dom);
print $dom->toString(), "\n";
