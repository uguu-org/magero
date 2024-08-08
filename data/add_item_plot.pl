#!/usr/bin/perl -w
# Plot item locations for the map room.
#
# ./add_item_plot.pl {input.svg} {t_annotated_tiles.txt} {frame} > {output.svg}

use strict;
use XML::LibXML;

use constant MAP_X => 7450;
use constant MAP_Y => 2209;
use constant OUTPUT_LAYER => "BG common - castle";


# Parse annotated tile list, returning 0-based tile coordinates for each item.
sub parse_annotated_tiles($)
{
   my ($filename) = @_;

   my @items = ();
   open my $infile, "<$filename" or die $!;
   while( my $line = <$infile> )
   {
      # There are two types of lines we are interested in, and they look
      # like these:
      # 8608,96: hidden collectible
      # 1408,128: collectible
      if( $line =~ /^(\d+),(\d+): (?:hidden )?collectible/ )
      {
         my $tile_x = $1 / 32;
         my $tile_y = $2 / 32;
         push @items, [$tile_x, $tile_y];
      }
   }
   close $infile;
   return @items;
}

# Find layer where items are to be plotted.
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

# Add 1x1 rectangles for each item.
sub plot_items($$$)
{
   my ($dom, $frame, $items) = @_;

   foreach my $p (@$items)
   {
      my ($x, $y) = @$p;

      # Generate a hash of the item location.
      #
      # Magic constants from here: https://thebookofshaders.com/10/
      my $hash = abs(int(sin($x * 12.9898 + $y * 78.233) * 43758.5453123));

      # Set color based on hash of item location.  The color is set based
      # on the second lowest bit of the hash plus frame number, which
      # means each spot will have two consecutive white frames followed by
      # two consecutive black frames, but the start of the 4-frame cycles
      # will be somewhat random depending on item location.
      #
      # Other things we have tried include having 3 black frames followed
      # by 1 white frame, but that only works if the pixels near all items
      # are mostly white.
      #
      # We have also tried not doing the hashing bit and just have all
      # points blink simultaneously.  This reduces the tile count
      # slightly, at the cost of looking much worse than the random
      # blinking we have now.
      my $color = (($hash + $frame) & 2) == 0 ? "#ffffff" : "#000000";

      # Set shape based on lowest bit of hash plus frame number.  We draw
      # single pixels on odd frames and crosses on even frames.  Initially
      # we have just the single pixels, but had to expand them to crosses
      # since single pixels are barely visible.
      if( (($hash + $frame) & 1) == 0 )
      {
         my $element = XML::LibXML::Element->new("rect");
         $element->{"style"} = "fill:$color";
         $element->{"x"} = MAP_X + $x - 1;
         $element->{"y"} = MAP_Y + $y;
         $element->{"width"} = 3;
         $element->{"height"} = 1;
         $dom->addChild($element);

         $element = XML::LibXML::Element->new("rect");
         $element->{"style"} = "fill:$color";
         $element->{"x"} = MAP_X + $x;
         $element->{"y"} = MAP_Y + $y - 1;
         $element->{"width"} = 1;
         $element->{"height"} = 3;
         $dom->addChild($element);
      }
      else
      {
         my $element = XML::LibXML::Element->new("rect");
         $element->{"style"} = "fill:$color";
         $element->{"x"} = MAP_X + $x;
         $element->{"y"} = MAP_Y + $y;
         $element->{"width"} = 1;
         $element->{"height"} = 1;
         $dom->addChild($element);
      }
   }
}


# Load input.
if( $#ARGV != 2 )
{
   die "$0 {input.svg} {t_annotated_tiles.txt} {frame} > {output.svg}\n";
}
my $dom = XML::LibXML->load_xml(location => $ARGV[0]);
my @items = parse_annotated_tiles($ARGV[1]);

# Plot points.
plot_items(find_layer_by_name($dom, OUTPUT_LAYER), $ARGV[2], \@items);

# Output updated XML.
print $dom->toString(), "\n";
