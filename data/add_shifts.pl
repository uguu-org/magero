#!/usr/bin/perl -w
# Apply random shifts to paths in the "collapsible marble track" group.

use strict;
use Digest::SHA qw(sha256);
use XML::LibXML;

# Group containing the groups of paths to be shifted.
use constant PARENT_GROUP => "collapsible marble track";

# Sub-groups that are subject to shifting.
my %shift_groups =
(
   "shift up" => "translate(0,-1)",
   "shift up right" => "translate(1,-1)",
   "shift right" => "translate(1,0)",
   "shift down" => "translate(0,1)",
   "shift down left" => "translate(-1,1)",
   "shift left" => "translate(-1,0)",
);

# Check that an element is of the expected type, returns true if so.
sub check_element_type($$)
{
   my ($element, $expected_type) = @_;

   my $type = eval('$element->nodeName');
   return defined($type) && $type eq $expected_type;
}

# Generate key based on path data.  The intent is to find the center of
# each path so that we can assign consecutive indices to adjacent shapes.
sub get_path_key($)
{
   my ($path_data) = @_;

   # All paths consists of an outer triangle followed by an inner triangle,
   # for example:
   #
   # d="m 7842,4869 v 25 h 25 z ..."
   # d="M 7870,4891.5 V 4866 h -25.5 z ..."
   #
   # We will collect vertices up to the end of the first path.
   my $cmd = "m";
   my $x = undef;
   my $y = undef;
   my @p = ();
   while( $path_data !~ /^\s*[Zz]/ )
   {
      if( $path_data =~ s/^\s*[Mm]\s+([^, ]+)[, ]([^, ]+)\s+(.*)$/$3/ )
      {
         $x = $1;
         $y = $2;
         push @p, [$x, $y];
      }
      elsif( $path_data =~ s/^\s*([vVhH])\s+(\S+)\s+(.*)$/$3/ )
      {
         $cmd = $1;
         unless( defined($x) && defined($y) )
         {
            die "Bad path data: $path_data\n";
         }
         if( $cmd eq "v" )
         {
            $y += $2;
         }
         elsif( $cmd eq "V" )
         {
            $y = $2;
         }
         elsif( $cmd eq "h" )
         {
            $x += $2;
         }
         elsif( $cmd eq "H" )
         {
            $x = $2;
         }
         push @p, [$x, $y];
      }
      else
      {
         die "Unsupported path command: $path_data\n";
      }
   }
   unless( scalar @p > 0 )
   {
      die "Empty path data\n";
   }

   # Average all vertices.
   $x = $p[0][0];
   $y = $p[0][1];
   for(my $i = 1; $i < scalar @p; $i++)
   {
      $x += $p[$i][0];
      $y += $p[$i][1];
   }
   $x /= scalar @p;
   $y /= scalar @p;

   # Return (Y,X) tuple packed in big-endian format.
   return pack "NN", int($y), int($x);
}

# Collect paths within a group that's nested under the parent group.
sub collect_paths_within_group($$)
{
   my ($group, $shift_paths) = @_;

   unless( check_element_type($group, "g") &&
           defined($group->{"inkscape:label"}) )
   {
      return;
   }
   return unless exists $shift_groups{$group->{"inkscape:label"}};
   my $transform = $shift_groups{$group->{"inkscape:label"}};
   foreach my $path ($group->childNodes())
   {
      next unless check_element_type($path, "path");

      if( defined $path->{"transform"} )
      {
         die "Path contains transform: " . $path->{"id"} . "\n";
      }

      # Add path to collection.
      my $key = get_path_key($path->{"d"});
      if( exists $$shift_paths{$key} )
      {
         die "Duplicate path: " . $path->{"id"} . "\n";
      }

      $$shift_paths{$key}{"node"} = $path;
      $$shift_paths{$key}{"transform"} = $transform;
   }
}

# Collect all paths to be shifted.
sub collect_paths($$)
{
   my ($dom, $shift_paths) = @_;

   foreach my $group ($dom->getElementsByTagName("g"))
   {
      if( defined($group->{"inkscape:label"}) &&
          $group->{"inkscape:label"} eq PARENT_GROUP )
      {
         foreach my $sub_group ($group->childNodes())
         {
            collect_paths_within_group($sub_group, $shift_paths);
         }
      }
   }
}

# Assign an unique index to each path.
sub assign_indices($)
{
   my ($shift_paths) = @_;

   my $index = 0;
   foreach my $k (sort keys %$shift_paths)
   {
      $$shift_paths{$k}{"index"} = $index++;
   }
}

# Assign frame number to each path.
#
# Each path has a 4 frame animation starting at this frame.  We assign
# frames based on path index to avoid adjacent paths from starting their
# animation cycles on the same frame.
sub assign_frames($)
{
   my ($shift_paths) = @_;

   my @frames = ();
   my $seed = 0;
   my $previous = -1;
   while( scalar @frames < scalar keys %$shift_paths )
   {
      # Generate random bits deterministically with a hash.
      my @rand = unpack "C*", sha256(++$seed);
      for(my $i = 0; $i < scalar @rand; $i++)
      {
         # Generate frame number with a modulus.  We have only 4 frames but
         # here we are taking a modulus of a higher number, so that some
         # tiles will not move at all.
         my $f = $rand[$i] % 6;

         # Avoid assigning same frame number to adjacent paths.
         if( $f != $previous )
         {
            push @frames, $f;
            $previous = $f;
         }
      }
   }

   # Assign frame indices.
   foreach my $k (keys %$shift_paths)
   {
      $$shift_paths{$k}{"frame"} = $frames[$$shift_paths{$k}{"index"}];
   }
}

# Apply transforms to each path based on selected frame index.
sub apply_transforms($$)
{
   my ($shift_paths, $frame) = @_;

   foreach my $k (keys %$shift_paths)
   {
      my $path = $$shift_paths{$k}{"node"};
      my $path_frame = $$shift_paths{$k}{"frame"};
      if( $path_frame < 4 )
      {
         if( $path_frame == $frame )
         {
            $path->{"transform"} = $$shift_paths{$k}{"transform"};
         }
         elsif( $path_frame == (($frame + 3) & 3) )
         {
            $path->{"style"} =~ s/stroke:#000000/stroke:#2f2f2f/;
         }
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

# Collect path data.  The goal is to build a dictionary with this structure:
# {
#    "lowercase path data" =>
#    {
#       "node" => dom_node,
#       "transform" => "translate(...)",
#       "index" => path_index,
#       "frame" => frame_index,
#    },
#    ...
# }
my %shift_paths = ();
collect_paths($dom, \%shift_paths);
assign_indices(\%shift_paths);
assign_frames(\%shift_paths);

# Update paths.
apply_transforms(\%shift_paths, $frame);

# Output updated XML.
print $dom->toString(), "\n";
