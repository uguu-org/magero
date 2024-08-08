#!/usr/bin/perl -w
# Add water flow triangles to SVG according to bounding edges.
#
# ./add_water.pl {world_master.svg} {frame} > {output.svg}
#
# Requires two control paths in "FG common - waterfall" layer labelled
# "lower bound" and "upper bound", and those control paths must be
# made out of entirely straight line segments.
#
# The straight line requirement simplifies this script so that we
# don't have to implement something like De Casteljau's algorithm, but
# it places more burden on world_master.svg to define the control
# paths properly.  Since we only have to do it once, we just document
# the procedure inside world_master.svg as opposed to implementing the
# generalized curve handling code here.

use strict;
use Digest::SHA qw(sha256);
use XML::LibXML;

use constant PI => 3.14159265358979323846264338327950288419716939937510;

# Tile size settings.
use constant TILE_BITS => 5;
use constant TILE_SIZE => 1 << TILE_BITS;

# Which layer to modify.
use constant WATER_LAYER => "FG common - waterfall";

# Angle variation settings.  Lower magnitude means fewer tile variations.
# The water flows mostly in the same direction near the bottom of the
# waterfall, so we could go down to ~1 degree and still not have too many
# tiles, but the grouping from quantizing at 2 degrees seem to look best.
use constant QUANTIZED_ANGLE => PI / 90;
use constant VARIATION_ANGLE => QUANTIZED_ANGLE;

# Number of line segments in each generated tile.
use constant SHAPE_COUNT => 64;

# Find layer to be modified.
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

# Load list of vertices from path.
sub load_vertices($)
{
   my ($path) = @_;

   unless( defined $path->{"d"} )
   {
      die "Path is missing data.\n";
   }
   my $d = $path->{"d"};
   unless( $d =~ s/^\s*m\s+(.*)$/$1/ )
   {
      die "Only relative straight line segments are supported.\n";
   }

   my @points = ();
   my $x = undef;
   my $y = undef;
   my $mode = "l";
   for(;;)
   {
      # Set path mode.  Only limited commands are supported.
      if( $d =~ /^\s*([hvlL])(.*)$/ )
      {
         $mode = $1;
         $d = $2;
      }

      # Add node.
      my ($dx, $dy, $tail);
      if( $mode eq "l" || $mode eq "L" )
      {
         if( $d =~ /^\s*
                     (-?\d+(?:\.\d+)?(?:e-?\d+)?)
                     (?:[, ]+)
                     (-?\d+(?:\.\d+)?(?:e-?\d+)?)
                     (.*)$/x )
         {
            if( $mode eq "L" )
            {
               $x = $y = undef;
            }
            $dx = $1;
            $dy = $2;
            $tail = $3;
         }
         else
         {
            last;
         }
      }
      else
      {
         if( $d =~ /^\s*
                     (-?\d+(?:\.\d+)?(?:e-?\d+)?)
                     (.*)$/x )
         {
            if( $mode eq "h" )
            {
               $dx = $1;
               $dy = 0;
            }
            else
            {
               $dx = 0;
               $dy = $1;
            }
            $tail = $2;
         }
         else
         {
            last;
         }
      }

      if( defined($x) )
      {
         $x += $dx;
         $y += $dy;
      }
      else
      {
         $x = $dx;
         $y = $dy;
      }
      push @points, [$x, $y];
      $d = $tail;
   }
   return @points;
}

# Compute distance between two points.
sub distance($$$$)
{
   my ($ax, $ay, $bx, $by) = @_;

   my $dx = $ax - $bx;
   my $dy = $ay - $by;
   return sqrt($dx * $dx + $dy * $dy);
}

# Interpolate between two values.
sub interpolate_value($$$)
{
   my ($t, $a, $b) = @_;
   return $a + ($b - $a) * $t;
}

# Interpolate between two points.
sub interpolate_point($$$$$)
{
   my ($t, $ax, $ay, $bx, $by) = @_;
   return interpolate_value($t, $ax, $bx), interpolate_value($t, $ay, $by);
}

# Generate a new vector that is an interpolation of two vectors.
sub interpolate_vector($$$$$$$$$)
{
   my ($t, $ax0, $ay0, $ax1, $ay1, $bx0, $by0, $bx1, $by1) = @_;

   my ($ix0, $iy0) = interpolate_point($t, $ax0, $ay0, $bx0, $by0);
   my ($ix1, $iy1) = interpolate_point($t, $ax1, $ay1, $bx1, $by1);
   return $ix0, $iy0, $ix1, $iy1;
}

# Collect angles for tiles that are touched by a quadrilateral defined by
# two edge vectors.
#
# Also collect all pixels that are enclosed by the two edge vectors.
sub count_angles($$$$$$$$$$$)
{
   my ($angles, $counts, $pixels,
       $ax0, $ay0, $ax1, $ay1, $bx0, $by0, $bx1, $by1) = @_;

   my $i_steps = int(distance($ax0, $ay0, $bx0, $by0));
   return if $i_steps <= 0;
   for(my $i = 0; $i <= $i_steps; $i++)
   {
      my ($ix0, $iy0, $ix1, $iy1) = interpolate_vector(
         $i / $i_steps,
         $ax0, $ay0, $ax1, $ay1,
         $bx0, $by0, $bx1, $by1);

      # Note the order of the arguments is (x,y) instead of (y,x).
      # We want $a=0 for (0,+1) and $a=PI for(0,-1), so that it's easier
      # to average the angles later.
      my $a = atan2($ix1 - $ix0, $iy1 - $iy0);

      my $j_steps = int(distance($ix0, $iy0, $ix1, $iy1));
      next if $j_steps <= 0;
      for(my $j = 0; $j <= $j_steps; $j++)
      {
         # Record angles for this interpolated point, quantized to tile
         # coordinates.
         my ($x, $y) = interpolate_point($j / $j_steps, $ix0, $iy0, $ix1, $iy1);
         my $key = pack "ii", int($x / TILE_SIZE), int($y / TILE_SIZE);
         $$angles{$key} += $a;
         $$counts{$key}++;

         # Record pixels touched by this interpolated point, quantized to
         # 2x2 squares.
         $$pixels{pack "ii", int($x / 2), int($y / 2)} = 1;
      }
   }
}

# Reduce angle variations.
sub quantize_angle($)
{
   my ($a) = @_;
   return int(($a + QUANTIZED_ANGLE / 2) / QUANTIZED_ANGLE) * QUANTIZED_ANGLE;
}

# Sort angle keys by Y,X pairs.
sub cmp_packed_coordinate($$)
{
   my ($a, $b) = @_;

   my ($ax, $ay) = unpack "ii", $a;
   my ($bx, $by) = unpack "ii", $b;
   return $ay <=> $by || $ax <=> $bx;
}

# Add a single tile.
sub add_tile($$$$$$)
{
   my ($pixels, $dom, $frame, $x, $y, $a) = @_;

   # Generate list of random numbers by hashing the flow angle.  We want
   # all tiles with the same angle to use the same sequence of random
   # numbers, independent of tile position, such that we would generate
   # the same tiles for same flow angles.
   my @rand = ();
   for(my $i = 0; (scalar @rand) < SHAPE_COUNT * 6; $i++)
   {
      push @rand,
           (map {$_ / 65535.0}
            (unpack "n*", sha256(pack 'NN', $i, int($a * 180 / PI))));
   }

   # Adjust frame index based on tile position.
   $frame = ($frame + ($y >> TILE_BITS)) & 3;

   # Generate lines in the general direction of the water flow.
   my $r = 0;
   for(my $i = 0; $i < SHAPE_COUNT; $i++)
   {
      # Compute starting position of line, and skip this line if starting
      # point is not within the region defined by the two control lines.
      my $ax = $x + $rand[$r++] * TILE_SIZE;
      my $ay = $y + $rand[$r++] * TILE_SIZE;
      my $p = pack "ii", int($ax / 2), int($ay / 2);
      next unless exists $$pixels{$p};

      # Compute end position of line, and skip if end position is not
      # within region.
      my $da = $a + ($rand[$r++] - 0.5) * VARIATION_ANGLE;
      my $dx = sin($da) * TILE_SIZE / 2;
      my $dy = cos($da) * TILE_SIZE / 2;
      $p = pack "ii", int(($ax + $dx * 4) / 2), int(($ay + $dy * 4) / 2);
      next unless exists $$pixels{$p};

      # Shift starting position according to frame counter plus some random
      # random offset.
      my $f = ($frame + int($rand[$r++] * 4)) & 3;
      $ax += $f * $dx;
      $ay += $f * $dy;

      # Set opacity for a layered effect.
      my $opacity = $rand[$r++] * 0.4 + 0.25;

      # Use mostly white lines, and occasionally some black lines.  We need
      # a bit of black, otherwise the white waterfall won't be visible
      # against the black background.
      my $color = ($rand[$r++] > 0.4) ? "#ffffff" : "#000000";

      # Add line segment as a path element.
      my $path = XML::LibXML::Element->new("path");
      $path->{"style"} = "stroke:$color;stroke-opacity:$opacity;stroke-width:3;stroke-linecap:round;fill:none";
      $path->{"d"} = "m $ax,$ay $dx,$dy";
      $dom->addChild($path);
   }
}

# Reduce the number of pixels that can be painted near the bottom.  This is
# to thin out the tiles so that it blends better with the water surface.
sub reduce_waterfall_splash($)
{
   my ($pixels) = @_;

   for(my $y = 4896; $y < 4992; $y += 4)
   {
      for(my $x = 1696; $x < 2080; $x += 4)
      {
         delete $$pixels{pack "ii", int($x / 2), int($y / 2)};
         delete $$pixels{pack "ii", int($x / 2), int($y / 2) + 1};
      }
   }
}

# Update water layer.
sub add_water($$)
{
   my ($dom, $frame) = @_;

   # Load control path vertices, and also remove control paths from SVG.
   my @lower_bound = ();
   my @upper_bound = ();
   foreach my $path ($dom->getElementsByTagName("path"))
   {
      if( defined($path->{"inkscape:label"}) )
      {
         if( $path->{"inkscape:label"} eq "lower bound" )
         {
            @lower_bound = load_vertices($path);
            $path->parentNode->removeChild($path);
         }
         elsif( $path->{"inkscape:label"} eq "upper bound" )
         {
            @upper_bound = load_vertices($path);
            $path->parentNode->removeChild($path);
         }
      }
   }

   unless( (scalar @lower_bound) && (scalar @upper_bound) )
   {
      die "Failed to load control paths from \"" . WATER_LAYER . "\"\n";
   }
   if( $#lower_bound != $#upper_bound )
   {
      die "Control path vertex counts do not match: " .
          (scalar @lower_bound) . " vs " . (scalar @upper_bound) . "\n";
   }

   # Walk control path vertices in lockstep and find the average angle of
   # flow on all tiles covered by the control paths.
   my %angles = ();
   my %counts = ();
   my %pixels = ();
   for(my $i = 0; $i < $#lower_bound; $i++)
   {
      count_angles(\%angles, \%counts, \%pixels,
                   $lower_bound[$i][0], $lower_bound[$i][1],
                   $lower_bound[$i + 1][0], $lower_bound[$i + 1][1],
                   $upper_bound[$i][0], $upper_bound[$i][1],
                   $upper_bound[$i + 1][0], $upper_bound[$i + 1][1]);
   }
   foreach my $key (keys %angles)
   {
      # Compute quantized average angle.
      $angles{$key} = quantize_angle($angles{$key} / $counts{$key});
   }
   reduce_waterfall_splash(\%pixels);

   # Add tiles.
   foreach my $key (sort {cmp_packed_coordinate($a, $b)} keys %angles)
   {
      my ($x, $y) = unpack "ii", $key;
      add_tile(\%pixels, $dom, $frame,
               $x * TILE_SIZE, $y * TILE_SIZE, $angles{$key});
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

# Update water.
add_water(find_layer_by_name($dom, WATER_LAYER), $frame);

# Output updated XML.
print $dom->toString(), "\n";
