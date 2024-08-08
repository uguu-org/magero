#!/usr/bin/perl -w
# Verify that all paths inside layer groups are aligned to tile coordinates.
#
# Outputs errors to stdout and exits with nonzero status on error.

use strict;
use XML::LibXML;

use constant TILE_SIZE => 32;

# Parse a list of comma separated or space separated numbers.
sub parse_list($)
{
   my ($t) = @_;
   my @numbers = split /[, ]+/, $t;
   foreach my $n (@numbers)
   {
      unless( $n =~ /^-?\d+(?:\.\d+)?(e-?\d+)?$/ )
      {
         return ();
      }
   }
   return @numbers;
}

# Apply transformation matrix to another matrix.
sub transform_matrix($$$$$$$)
{
   my ($input, $a, $b, $c, $d, $e, $f) = @_;

   # [[i0, i1, i2],     [[a, b, c],
   #  [i3, i4, i5],  *   [d, e, f],
   #  [ 0,  0,  1]]      [0, 0, 1]]
   return
   (
      $$input[0] * $a + $$input[1] * $d,
      $$input[0] * $b + $$input[1] * $e,
      $$input[0] * $c + $$input[1] * $f + $$input[2],
      $$input[3] * $a + $$input[4] * $d,
      $$input[3] * $b + $$input[4] * $e,
      $$input[3] * $c + $$input[4] * $f + $$input[5],
   );
}

# Apply transformation matrix to a single point.
sub transform_point($$$)
{
   my ($t, $x, $y) = @_;

   # [[t0, t1, t2],     [[x],
   #  [t3, t4, t5],  *   [y],
   #  [ 0,  0,  1]]      [1]]
   return
   (
      $$t[0] * $x + $$t[1] * $y + $$t[2],
      $$t[3] * $x + $$t[4] * $y + $$t[5],
   );
}

# Build transformation matrix.
# Returns empty list if transform is not supported.
sub stack_transform($$)
{
   my ($input, $transform_command) = @_;

   if( $transform_command =~ /^scale\(([^()]+)\)$/ )
   {
      my @t = parse_list($1);
      if( (scalar @t) == 1 )
      {
         return transform_matrix($input, $t[0], 0, 0, 0, $t[0], 0);
      }
      elsif( (scalar @t) == 2 )
      {
         return transform_matrix($input, $t[0], 0, 0, 0, $t[1], 0);
      }
   }
   elsif( $transform_command =~ /^translate\(([^()]+)\)$/ )
   {
      my @t = parse_list($1);
      if( (scalar @t) == 1 )
      {
         return transform_matrix($input, 1, 0, $t[0], 0, 1, 0);
      }
      elsif( (scalar @t) == 2 )
      {
         return transform_matrix($input, 1, 0, $t[0], 0, 1, $t[1]);
      }
   }
   elsif( $transform_command =~ /^matrix\(([^()]+)\)$/ )
   {
      my @t = parse_list($1);
      if( (scalar @t) == 6 )
      {
         return transform_matrix($input,
                                 $t[0], $t[1], $t[2],
                                 $t[3], $t[4], $t[5]);
      }
   }
   return ();
}

# Consume a single number from path.
sub next_number($)
{
   my ($d) = @_;

   if( $$d =~ s/^[, ]*(-?\d+(?:\.\d+)?(?:e-?\d+)?)(.*)$/$2/ )
   {
      return $1;
   }
   return undef;
}

# Check if a single number is aligned, returns nonzero if so.
sub is_aligned($)
{
   my ($n) = @_;
   return $n == int($n) && ($n % TILE_SIZE) == 0;
}

# Output error message regarding a path coordinate to stdout.
sub path_error($$$$$)
{
   my ($id, $transform, $x, $y, $msg) = @_;

   my ($tx, $ty) = transform_point($transform, $x, $y);
   print "<path id=\"$id\">: ($tx,$ty): $msg\n";
}

# Check that path vertices and angles are aligned.
sub check_path($$)
{
   my ($node, $transform) = @_;

   my $id = $node->{"id"} || "";
   my $d = $node->{"d"} || "";

   my $x = 0;
   my $y = 0;
   my $init_x = 0;
   my $init_y = 0;
   my $mode = undef;
   while( $d !~ /^\s*$/ )
   {
      # Parse path command.
      if( $d =~ s/^\s*([[:alpha:]])(.*)$/$2/ )
      {
         my $command = $1;
         if( $command =~ /^([mlhv])$/i )
         {
            $mode = $1;
         }
         elsif( $command =~ /^([zZ])$/ )
         {
            $mode = undef;
            $x = $init_x;
            $y = $init_y;
         }
         else
         {
            path_error($id, $transform, $x, $y, "Unsupported command $command");
            return 1;
         }
         next;
      }

      # Parse path arguments.
      if( defined($mode) )
      {
         if( $mode =~ /[mMlL]/ )
         {
            my $dx = next_number(\$d);
            unless( defined($dx) )
            {
               path_error($id, $transform, $x, $y,
                          "Expected 2 numbers, remainder: $d");
               return 1;
            }
            my $dy = next_number(\$d);
            unless( defined($dy) )
            {
               path_error($id, $transform, $x, $y,
                          "Expected 2 numbers, got $dx, remainder: $d");
               return 1;
            }
            if( $mode =~ /[ML]/ )
            {
               $x = $dx;
               $y = $dy;
            }
            else
            {
               if( $mode eq "l" &&
                   $dx != 0 && $dy != 0 && abs($dx) != abs($dy) )
               {
                  path_error($id, $transform, $x, $y, "Oblique angle");
                  return 1;
               }
               $x += $dx;
               $y += $dy;
            }

            # Special handling for "m" and "M" commands: save the first
            # vertex of the path (needed for "z" and "Z" commands), and
            # interpret subsequent commands as "l" or "L".
            if( $mode eq "M" )
            {
               $init_x = $x;
               $init_y = $y;
               $mode = "L";
            }
            elsif( $mode eq "m" )
            {
               $init_x = $x;
               $init_y = $y;
               $mode = "l";
            }
         }
         else
         {
            my $delta = next_number(\$d);
            unless( defined($delta) )
            {
               path_error($id, $transform, $x, $y,
                          "Expected 1 number, remainder: $d");
               return 1;
            }
            if( $mode eq "h" )
            {
               $x += $delta;
            }
            elsif( $mode eq "H" )
            {
               $x = $delta;
            }
            elsif( $mode eq "v" )
            {
               $y += $delta;
            }
            elsif( $mode eq "V" )
            {
               $y = $delta;
            }
            else
            {
               # Unreachable.
               die "Unexpected mode $mode\n";
            }
         }

         my ($tx, $ty) = transform_point($transform, $x, $y);
         if( !is_aligned($tx) || !is_aligned($ty) )
         {
            path_error($id, $transform, $x, $y, "Unaligned point");
            return 1;
         }
      }
      else
      {
         path_error($id, $transform, $x, $y,
                    "Error parsing path data, missing command");
         return 1;
      }
   }
   return 0;
}

# Check that rectangle vertices are aligned.
sub check_rect($$)
{
   my ($node, $transform) = @_;

   my $id = $node->{"id"} || "";
   my $rx = $node->{"rx"} || 0;
   my $ry = $node->{"ry"} || 0;
   if( $rx != 0 || $ry != 0 )
   {
      print "<rect id=\"$id\">: Rounded corners\n";
      return 1;
   }

   my ($x0, $y0) = transform_point($transform,
                                   $node->{"x"} || 0,
                                   $node->{"y"} || 0);
   if( !is_aligned($x0) || !is_aligned($y0) )
   {
      print "<rect id=\"$id\">: Unaligned position: ($x0, $y0)\n";
      return 1;
   }

   my ($x1, $y1) =
      transform_point($transform,
                      ($node->{"x"} || 0) + ($node->{"width"} || 0),
                      ($node->{"y"} || 0) + ($node->{"height"} || 0));
   if( !is_aligned($x1) || !is_aligned($y1) )
   {
      print "<rect id=\"$id\">: Unaligned size: ($x0, $y0) .. ($x1, $y1)\n";
      return 1;
   }

   return 0;
}

# Check DOM nodes recursively.  Returns 0 if nodes are all good.
sub recursive_check($$$);
sub recursive_check($$$)
{
   my ($node, $inside_layer, $transform) = @_;

   # Stack transformations.
   my @local_transform = ();
   my $id = eval('$node->{"id"}') || "";
   my $name = eval('$node->nodeName') || "?";
   my $t = eval('$node->{"transform"}');
   if( defined($t) && $t ne "" )
   {
      @local_transform = stack_transform($transform, $t);
      if( (scalar @local_transform) != 6 )
      {
         print "<$name id=\"$id\">: Unsupported transform: $t\n";
         return 1;
      }
      $transform = \@local_transform;
   }

   my $errors = 0;
   if( $inside_layer )
   {
      # Currently inside a layer group, apply checks accordingly.
      if( $name eq "path" )
      {
         $errors += check_path($node, $transform);
      }
      elsif( $name eq "rect" )
      {
         $errors += check_rect($node, $transform);
      }
      elsif( $name eq "circle" ||
             $name eq "ellipse" ||
             $name eq "image" ||
             $name eq "text" ||
             $name eq "tspan" )
      {
         print "<$name id=\"$id\">: Unexpected element\n";
         $errors++;
      }

      # All other node types (such as <g>) are not checked, and
      # will fallthrough below where we traverse all child nodes.
   }
   else
   {
      # Currently not not nested inside a layer group, check if we
      # have entered one at current node.
      if( $name eq "g" )
      {
         my $groupmode = $node->{"inkscape:groupmode"};
         if( defined($groupmode) && $groupmode eq "layer" )
         {
            $inside_layer = 1;
         }
      }
   }

   foreach my $child ($node->childNodes())
   {
      $errors += recursive_check($child, $inside_layer, $transform);
   }
   return $errors;
}


if( $#ARGV < 0 && (-t STDIN) )
{
   die "$0 {input.svg}\n";
}

# Load XML from stdin or first argument.
my $dom = XML::LibXML->load_xml(string => join "", <ARGV>);

# Check nodes, returning check status.
my @transform = (1, 0, 0,  0, 1, 0);
my $errors = recursive_check($dom, 0, \@transform);
if( $errors > 0 )
{
   print "$errors errors\n";
   exit 1;
}
exit 0;
