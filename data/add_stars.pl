#!/usr/bin/perl -w
# Add star elements to the top part of SVG.
#
# ./add_stars.pl {input.svg} {frame} > {output.svg}

use strict;
use XML::LibXML;

use constant WIDTH => 9600;
use constant HEIGHT => 608;
use constant PALETTE_X => 9280;
use constant PALETTE_Y => 0;
use constant TILE_SIZE => 32;
use constant STAR_VARIATIONS => 4;
use constant FLICKER_VARIATIONS => 2;
use constant EMPTY_TILE_INDEX => STAR_VARIATIONS * FLICKER_VARIATIONS;

# Star variation position offsets.
my @variation_offsets =
(
   [8, 6],
   [26, 8],
   [24, 26],
   [6, 24],
);

# Generate star layer name from specified frame index.
#
# This will be used to match against "inkscape:label".
sub stars_layer_name($)
{
   my ($i) = @_;
   return "IBG frame$i - stars";
}

# Find layer where stars are to be added.
sub find_layer_by_name($$)
{
   my ($dom, $name) = @_;

   foreach my $group ($dom->getElementsByTagName("g"))
   {
      if( defined($group->{"inkscape:label"}) &&
          $group->{"inkscape:label"} eq $name )
      {
         return $group;
      }
   }
   die "Layer not found: $name\n";
}

# Select star variation to be added at a particular spot.
sub get_star_variation($$$)
{
   my ($x, $y, $frame) = @_;

   # Avoid the entrance path from cloud ceiling to upper cloud region, since
   # we don't want the stars to overlap with the moon.
   if( $x > 4704 && $x < 5216 )
   {
      return EMPTY_TILE_INDEX;
   }

   # Special treatment for spaces around Jupiter: reserve some empty spaces,
   # and then add exactly 4 tiles for the Galilean moons.
   if( $x >= 7680 && $x < 7904 && $y >= 96 && $y < 256 )
   {
      if( $y == 160 )
      {
         if( $x == 7712 ) { return 4 + ($frame == 0 ? 1 : 0); }
         if( $x == 7744 ) { return 6 + ($frame == 1 ? 1 : 0); }
         if( $x == 7808 ) { return 2 + ($frame == 2 ? 1 : 0); }
         if( $x == 7840 ) { return 0 + ($frame == 3 ? 1 : 0); }
      }
      return EMPTY_TILE_INDEX;
   }

   # Stash all star variations at a particular region, so that we know
   # where to find the star tiles later.
   if( $y == PALETTE_Y &&
       $x >= PALETTE_X &&
       $x <= PALETTE_X + EMPTY_TILE_INDEX * TILE_SIZE )
   {
      my $tile_index = ($x - PALETTE_X) / TILE_SIZE;
      return $frame == 0 ? $tile_index : ($tile_index & ~1);
   }

   # Generate an arbitrary hash value based on tile position.
   #
   # Magic constants from here: https://thebookofshaders.com/10/
   my $hash = abs(int(sin($x * 12.9898 + $y * 78.233) * 43758.5453123));

   # Use empty spaces for 7/8 of the tiles.
   if( ($hash & 7) != 0 )
   {
      return EMPTY_TILE_INDEX;
   }

   # Use 2 bits to select which star variation to use, and a different 2 bits
   # to set which frame the star should flicker.
   my $variation = ($hash & 0x30) >> 4;
   my $flicker = (($hash & 0x300) >> 8) == $frame ? 1 : 0;
   return $variation * 2 + $flicker;
}

# Add star to a single tile.
sub add_star_tile($$$$)
{
   my ($x, $y, $variation, $dom) = @_;

   return if $variation >= EMPTY_TILE_INDEX;

   my ($cx, $cy) = @{$variation_offsets[$variation >> 1]};
   $cx += $x;
   $cy += $y;

   if( ($variation & 1) == 0 )
   {
      # Non-flickering star, try occupy a single pixel.
      my $element = XML::LibXML::Element->new("rect");
      $element->{"style"} = "fill:#ffffff;stroke:none";
      $element->{"x"} = $cx;
      $element->{"y"} = $cy;
      $element->{"width"} = 1;
      $element->{"height"} = 1;
      $dom->addChild($element);
   }
   else
   {
      # Flickering star, try occupying a cross pattern.
      #
      # A different way of doing this is to draw a circle of radius 1.5 at
      # the center of the pixel.  This would be more efficient since it's
      # just one element instead of two, but there is a fair bit of luck
      # involved due to anti-aliasing and dithering interactions.  The only
      # way to guarantee consistent results is to draw pixels with
      # rectangles, which is what we are doing here.
      my $vertical = XML::LibXML::Element->new("rect");
      $vertical->{"style"} = "fill:#ffffff;stroke:none";
      $vertical->{"x"} = $cx;
      $vertical->{"y"} = $cy - 1;
      $vertical->{"width"} = 1;
      $vertical->{"height"} = 3;
      $dom->addChild($vertical);

      my $horizontal = XML::LibXML::Element->new("rect");
      $horizontal->{"style"} = "fill:#ffffff;stroke:none";
      $horizontal->{"x"} = $cx - 1;
      $horizontal->{"y"} = $cy;
      $horizontal->{"width"} = 3;
      $horizontal->{"height"} = 1;
      $dom->addChild($horizontal);
   }
}

# Add stars to a single layer.
sub add_stars($$)
{
   my ($dom, $frame) = @_;

   # Iterate over each tile position.
   for(my $y = 0; $y < HEIGHT; $y += TILE_SIZE)
   {
      for(my $x = 0; $x < WIDTH; $x += TILE_SIZE)
      {
         add_star_tile($x, $y, get_star_variation($x, $y, $frame), $dom);
      }
   }
}

# Load input.
if( $#ARGV != 1 )
{
   die "$0 {input.svg} {frame} > {output.svg}\n";
}
my $dom = XML::LibXML->load_xml(location => $ARGV[0]);
my $frame = $ARGV[1];
$frame =~ /^[0-3]$/ or die "Unexpected frame, expected 0..3, got $frame\n";

# Add stars.
add_stars(find_layer_by_name($dom, stars_layer_name($frame)), $frame);

# Output updated XML.
print $dom->toString(), "\n";
