#!/usr/bin/perl -w
# Add animated debris near the blackhole.
#
# ./add_orbiting_debris.pl {input.svg} {frame} > {output.svg}

use strict;
use Digest::SHA qw(sha256);
use XML::LibXML;

use constant PI => 3.14159265358979323846264338327950288419716939937510;

# Output region settings.
use constant OUTPUT_LAYER => "FG common - caves";
use constant CENTER_X => 8656;
use constant CENTER_Y => 4336;
use constant MIN_X => 8384;
use constant MIN_Y => 4160;
use constant MAX_X => 8960;
use constant MAX_Y => 4480;

# Debris shape settings.
use constant ASPECT_RATIO => 2.2;
use constant TILT_ANGLE => atan2(4298 - CENTER_Y, 8822 - CENTER_X);
use constant ROTATE1 => cos(TILT_ANGLE);
use constant ROTATE2 => sin(TILT_ANGLE);
use constant DEBRIS_COUNT => 1000;
use constant STEP_COUNT => 53;

# Debris movement settings.
use constant INITIAL_VELOCITY => 1.4;
use constant GRAVITY => 2;
use constant ACCELERATION => 1.01;

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

# Add trace for a single particle.
sub add_trace($$@)
{
   my ($dom, $frame, @seed) = @_;

   # Generate an initial location near the center tile.  The final animation
   # we want is to have dots falling in, but rather than starting at a
   # random place going towards the center, it's easier to start at the
   # center and go outwards, and then rewind time.
   my $r = $seed[0] * 10 + 16;
   my $a = $seed[1] * PI * 2;
   my $x = $r * cos($a);
   my $y = $r * sin($a);

   # Set initial velocity such that point leaves center more or less in
   # counter-clockwise direction.
   my $va = $a - PI / 2 + $seed[2] * 0.6 - 0.3;
   my $vx = INITIAL_VELOCITY * cos($va);
   my $vy = INITIAL_VELOCITY * sin($va);

   # Run simulation steps.
   #
   # The outer for($i) loop traces a coarse path with some number of steps,
   # while the inner for($j) loop subdivides those steps into finer curves.
   my $frame_offset = int($seed[3] * 4);
   for(my $i = 0; $i < STEP_COUNT; $i++)
   {
      my $path_data;
      for(my $j = 0; $j < 5; $j++)
      {
         # Stop as soon as any point goes out of bounds.
         my $ry = $y / ASPECT_RATIO;
         my $sx = CENTER_X + $x * ROTATE1 - $ry * ROTATE2;
         my $sy = CENTER_Y + $x * ROTATE2 + $ry * ROTATE1;
         if( $sx < MIN_X || $sy < MIN_Y || $sx >= MAX_X || $sy >= MAX_Y )
         {
            return;
         }

         if( $j == 0 )
         {
            # Start new path.
            $path_data = "M $sx,$sy L";
         }
         else
         {
            # Append point to path.
            $path_data .= " $sx,$sy";
         }

         # Accelerate toward center.
         my $d2 = $x * $x + $y * $y;
         if( $d2 < 1e-3 )
         {
            $d2 = 1;
         }
         my $ax = -GRAVITY * $x / $d2;
         my $ay = -GRAVITY * $y / $d2;

         # Update position.
         $x += $vx;
         $y += $vy;

         # Update velocity.
         $vx *= ACCELERATION;
         $vy *= ACCELERATION;
         $vx += $ax;
         $vy += $ay;
      }

      # Add segment to output if it's the right frame.
      #
      # The "%4" part of the expression means to take the long path that
      # would be traced by the particle, divide them into quarters, and
      # assign each quarter to a different frame.  The "3-" part of the
      # expression causes time to flow in reverse, so that the particles
      # would appear to be going toward the center of the blackhole.
      if( 3 - (($i + $frame_offset) % 4) == $frame )
      {
         my $path = XML::LibXML::Element->new("path");
         my $opacity = 0.6;
         if( $i > STEP_COUNT * 0.6 )
         {
            $opacity *= 1.0 - ($i - STEP_COUNT * 0.6) / (STEP_COUNT * 0.4);
         }
         $path->{"style"} = "stroke:#ffffff;stroke-opacity:$opacity;stroke-width:2;stroke-linejoin:round;fill:none";
         $path->{"d"} = $path_data;
         $dom->addChild($path);
      }
   }
}


if( $#ARGV != 1 )
{
   die "$0 {input.svg} {frame} > {output.svg}\n";
}
my $dom = XML::LibXML->load_xml(location => $ARGV[0]);
my $frame = $ARGV[1];
$frame =~ /^[0-3]$/ or die "Unexpected frame, expected 0..3, got $frame\n";

# Generate a list of random numbers in the range of [0,1].  Using SHA256 here
# because we want it to be constant independent of Perl version and environment.
my @rand = ();
for(my $i = 0; scalar(@rand) < DEBRIS_COUNT * 4; $i++)
{
   push @rand, (map {$_ / 65535.0} (unpack "n*", sha256(pack 'N', $i)));
}

# Add traces.
my $output = find_layer_by_name($dom, OUTPUT_LAYER);
for(my $i = 0; $i < DEBRIS_COUNT; $i++)
{
   add_trace($output,
             $frame,
             $rand[$i * 3],
             $rand[$i * 3 + 1],
             $rand[$i * 3 + 2],
             $rand[$i * 3 + 3]);
}
print $dom->toString(), "\n";
