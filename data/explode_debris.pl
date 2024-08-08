#!/usr/bin/perl -w
# Usage:
#
#  perl debris_master.svg > debris.svg
#
# Read debris_master.svg and replicate each path, with some transformation
# such that each path shrinks toward zero.  It's possible to do the same
# manual edits in Inkscape, but it's difficult to make the motion of each
# path consistent.
#
# All paths must each define a single closed shape made up of only straight
# lines.

use strict;
use Digest::SHA qw(sha256);
use XML::LibXML;

use constant PI => 3.14159265358979323846264338327950288419716939937510;

# Number of extra frames to generate.
#
# While it's fairly trivial to increase the number of frames, having too
# many animation frames doesn't necessarily make the explosion look any
# nicer.  Current setting at 16 frames appears to have a good balance of
# smooth explosion without feeling too sluggish.
#
# Input page size must match the expected number of frames.  This script
# will check if the size is correct.  Alternatively, we could derive the
# number of frames automatically from the page size, but we would rather
# set that number explicitly here, with this accompanying documentation
# to explain why things are the way they are.
use constant DUP_COUNT => 15;

# Original center of debris.
use constant CENTER_X => 48;
use constant CENTER_Y => 48;

# Horizontal shift offset for each generated path.
use constant SHIFT_OFFSET => 96;


# Multiply two 3x3 matrices.
sub multiply($$)
{
   my ($a, $b) = @_;

   my @result = ();
   for(my $r = 0; $r < 3; $r++)
   {
      for(my $c = 0; $c < 3; $c++)
      {
         my $sum = 0;
         for(my $i = 0; $i < 3; $i++)
         {
            $sum += $$a[$r * 3 + $i] * $$b[$c + $i * 3];
         }
         push @result, $sum;
      }
   }
   return @result;
}

# Apply matrix transformation to a point.
sub apply($$$)
{
   my ($m, $x, $y) = @_;

   my $nx = $$m[0] * $x + $$m[1] * $y + $$m[2];
   my $ny = $$m[3] * $x + $$m[4] * $y + $$m[5];
   return ($nx, $ny);
}

# Generate a rotation matrix.
sub rotate($)
{
   my ($a) = @_;

   return (cos($a), sin($a), 0,  -sin($a), cos($a), 0,  0, 0, 1);
}

# Generate a translation matrix.
sub translate($$)
{
   my ($dx, $dy) = @_;
   return (1, 0, $dx,  0, 1, $dy,  0, 0, 1);
}

# Apply a matrix transformation to all coordinate pairs in path.
sub apply_path($$)
{
   my ($m, $points) = @_;

   for(my $i = 0; $i < scalar @$points; $i++)
   {
      my @r = apply($m, $$points[$i][0], $$points[$i][1]);
      $$points[$i][0] = $r[0];
      $$points[$i][1] = $r[1];
   }
}

# Scale a path string with respect to some center.
sub scale_path($$$$)
{
   my ($points, $scale, $cx, $cy) = @_;

   for(my $i = 0; $i < scalar @$points; $i++)
   {
      my $dx = $$points[$i][0] - $cx;
      my $dy = $$points[$i][1] - $cy;
      $$points[$i][0] = $cx + $scale * $dx;
      $$points[$i][1] = $cy + $scale * $dy;
   }
}

# Translate a path string.
sub translate_path($$$)
{
   my ($points, $dx, $dy) = @_;
   my @m = translate($dx, $dy);
   apply_path(\@m, $points);
}

# Rotate a path string clockwise with respect to some center.
# Rotation amount is in radians.
sub rotate_path($$$$)
{
   my ($points, $angle, $cx, $cy) = @_;

   my @m1 = translate(-$cx, -$cy);
   my @m2 = rotate($angle);
   my @m3 = translate($cx, $cy);

   my @m12 = multiply(\@m2, \@m1);
   my @m123 = multiply(\@m3, \@m12);

   apply_path(\@m123, $points);
}

# Generate updated set of points for a single shape.
sub generate_shape($$$)
{
   my ($input, $params, $index) = @_;

   # Copy points from input.
   my @points = ();
   for(my $i = 0; $i < scalar @$input; $i++)
   {
      push @points, [$$input[$i][0], $$input[$i][1]];
   }

   my $t = $index / DUP_COUNT;

   # Find the center of points for scaling.
   my $min_x = $points[0][0];
   my $min_y = $points[0][1];
   my $max_x = $min_x;
   my $max_y = $max_x;
   for(my $i = 1; $i < scalar @points; $i++)
   {
      my $x = $points[0][0];
      my $y = $points[0][1];
      if( $min_x > $x ) { $min_x = $x; }
      if( $min_y > $y ) { $min_y = $y; }
      if( $max_x < $x ) { $max_x = $x; }
      if( $max_y < $y ) { $max_y = $y; }
   }
   my $cx = ($min_x + $max_x) / 2;
   my $cy = ($min_y + $max_y) / 2;

   # Scale the shape such that we would end up with 10% of the original
   # size in the final frame.
   my $scale = 1 - $t * 0.9;
   scale_path(\@points, $scale, $cx, $cy);

   # Apply random rotation.
   my $angle = PI * (($$params[0] * 2) - 1) * $t;
   rotate_path(\@points, $angle, $cx, $cy);

   # Move points away from sprite center.
   my $dx = $cx - CENTER_X;
   my $dy = $cy - CENTER_Y;
   my $d = sqrt($dx * $dx + $dy * $dy);
   if( $d > 0.001 )
   {
      $dx /= $d;
      $dy /= $d;
   }
   my $move_amount = $t * ($$params[1] * 16 + 4);
   translate_path(\@points, $move_amount * $dx, $move_amount * $dy);

   # Rotate the debris about sprite center.
   $angle = PI * (($$params[0] * 2) - 1) * $t;
   rotate_path(\@points, $angle, CENTER_X, CENTER_Y);

   # Shift the shape right.
   translate_path(\@points, $index * SHIFT_OFFSET, 0);
   return @points;
}

# Extract path data from element as a list of coordinates.
sub parse_path_element($)
{
   my ($element) = @_;

   my $id = $element->{"inkscape:label"};
   if( !defined($id) )
   {
      $id = $element->{"id"};
      if( !defined($id) )
      {
         $id = "unidentified element";
      }
   }
   my $data = $element->{"d"};
   if( !defined($data) )
   {
      die "$id: missing path data\n";
   }

   my @points = ();
   my $command = undef;
   my $x = undef;
   my $y = undef;
   while( $data !~ /^\s*$/ )
   {
      # Extract commands.
      #
      # Only line commands are supported, no curves:
      # https://www.w3.org/TR/SVG2/paths.html#PathData
      if( $data =~ s/^\s*([a-zA-Z])(.*)$/$2/ )
      {
         $command = $1;
         unless( $command =~ /[mMlLhvzZ]/ )
         {
            die "$id: unsupported path command $command\n";
         }
         next;
      }
      unless( defined($command) )
      {
         die "$id: expecting 'm' or 'M'\n";
      }

      # Check for unexpected data.  This should normally be unreachable
      # because after the last "z" or "Z", path data should be empty.
      if( $command =~ /[zZ]/ )
      {
         die "$id: got extra commands after closing path\n";
      }

      # Check that relative commands have previous point defined.
      if( $command =~ /[hvl]/ && !defined($x) )
      {
         die "$id: unexpected relative command $command\n";
      }

      # Check that we have one continuous line.
      if( $command =~ /[mM]/ && defined($x) )
      {
         die "$id: got more than one move command\n";
      }

      if( $command =~ /[hv]/ )
      {
         # Expect a single number.
         if( $data =~ s/^\s*(-?[0-9.]+)(.*)$/$2/ )
         {
            my $n = $1;
            if( $command eq "h" )
            {
               $x += $n;
            }
            else
            {
               $y += $n;
            }
            push @points, [$x, $y];
         }
         else
         {
            die "$id: malformed data for command $command.\n";
         }
      }
      else
      {
         # Expect two numbers.
         if( $data =~ s/^\s*(-?[0-9.]+)[, ]+(-?[0-9.]+)(.*)$/$3/ )
         {
            my ($u, $v) = ($1, $2);

            if( $command =~ /[mML]/ )
            {
               $x = $u;
               $y = $v;
               if( $command eq "m" ) { $command = "l"; }
               if( $command eq "M" ) { $command = "L"; }
            }
            else
            {
               $x += $u;
               $y += $v;
            }
            push @points, [$x, $y];
         }
         else
         {
            die "$id: malformed data for command $command.\n";
         }
      }
   }
   return @points;
}

# Encode a list of points as path data.
sub encode_path_data($)
{
   my ($points) = @_;

   my $d = "m";
   my $x = 0;
   my $y = 0;
   for(my $i = 0; $i < scalar @$points; $i++)
   {
      my $dx = $$points[$i][0] - $x;
      my $dy = $$points[$i][1] - $y;
      $d .= " $dx,$dy";
      $x = $$points[$i][0];
      $y = $$points[$i][1];
   }
   return $d . " z";
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

# Check input dimensions.
my $width = undef;
foreach my $svg ($dom->getElementsByTagName("svg"))
{
   $width = $svg->{"width"};
}
unless( defined($width) )
{
   die "Can not get SVG dimensions\n";
}
if( $width != (DUP_COUNT + 1) * SHIFT_OFFSET )
{
   die "Page size must be exactly " . ((DUP_COUNT + 1) * SHIFT_OFFSET) .
       " pixels wide\n";
}

# Collect all path elements.
my @original_elements = ();
foreach my $element ($dom->getElementsByTagName("path"))
{
   push @original_elements, $element;
}

# Duplicate each path.
foreach my $element (@original_elements)
{
   my @points = parse_path_element($element);

   # Generate a set of random animation parameters.  This works by hashing
   # the path data (via sha256) and then use the resulting bits to generate
   # the parameters.
   #
   # We could have just called rand(), but that makes the output
   # non-deterministic.  So then, we could srand() with a fixed seed, but
   # there is no guarantee that the output would be stable in different
   # environments.  We could also just say "hey this is random debris,
   # who cares", but given I am the kind of person who would write a
   # few hundred lines of code just to align a few pixels, obviously I
   # am also the type to care about this kind of thing.
   my @params = map {$_ / 4294967295.0} unpack "N*", sha256($element->{"d"});

   for(my $i = 1; $i <= DUP_COUNT; $i++)
   {
      # We could assign a new and unique ID to $dup, but since inkscape can
      # deal with it (and automatically generates new IDs), we won't bother.
      my $dup = $element->cloneNode(0);
      my @new_points = generate_shape(\@points, \@params, $i);
      $dup->{"d"} = encode_path_data(\@new_points);
      $element->addSibling($dup);
   }
}

# Output updated XML.
print remove_redunant_namespaces_from_groups($dom->toString()), "\n";
