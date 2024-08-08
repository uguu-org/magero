#!/usr/bin/perl -w
# This script generates a list of tile positions, which is used to
# determine the hint drawing sequence.  We could generate this at run
# time, but generating these statically reduces startup time.

use strict;

use constant TILE_SIZE => 32;
use constant HALF_TILE_SIZE => TILE_SIZE / 2;
use constant SCAN_RADIUS => 13;

# See generate_world_tiles.cc
use constant MOUNT_UP => 0x10;             # kMountUp
use constant MOUNT_DOWN => 0x20;           # kMountDown
use constant MOUNT_LEFT => 0x40;           # kMountLeft
use constant MOUNT_RIGHT => 0x80;          # kMountRight
use constant BREAKABLE => 0x08;            # kBreakable
use constant CHAIN_REACTION => 0x1000;     # kChainReaction
use constant TERMINAL_REACTION => 0x2000;  # kTerminalReaction
use constant COLLECTIBLE => 0xf00;         # kCollectibleTile*

# Cursor types.  These matches the indices to gs_hint_cursors in arm.lua.
use constant CURSOR_H_UP => 1;
use constant CURSOR_H_DOWN => 2;
use constant CURSOR_V_LEFT => 3;
use constant CURSOR_V_RIGHT => 4;
use constant CURSOR_D_SLASH => 5;      # /
use constant CURSOR_D_BACKSLASH => 6;  # \
use constant CURSOR_CIRCLE => 7;
use constant CURSOR_SQUARE => 8;

# Compute distance squared.
sub distance2($$)
{
   my ($dx, $dy) = @_;
   return $dx * $dx + $dy * $dy;
}

# Compute pixel distance squared from center tile to point of interest
# for a single table entry.
sub distance2_to_poi($)
{
   my ($e) = @_;
   my @entry = @$e;
   return distance2(HALF_TILE_SIZE - ($entry[0] * TILE_SIZE + $entry[2]),
                    HALF_TILE_SIZE - ($entry[1] * TILE_SIZE + $entry[3]));
}

# Compare two table entries by distance.
sub cmp_table_entries($$)
{
   my ($a, $b) = @_;
   my @entry_a = @{$a};
   my @entry_b = @{$b};
   return distance2_to_poi($a) <=> distance2_to_poi($b) ||
          # Break ties to make sure that output is deterministic.
          $entry_a[0] <=> $entry_b[0] ||
          $entry_a[1] <=> $entry_b[1] ||
          $entry_a[4] <=> $entry_b[4] ||
          $entry_a[5] <=> $entry_b[5];
}

# Generate list of point-of-interest locations, with each list entry
# containing the following:
# 0. Horizontal tile index delta.
# 1. Vertical tile index delta.
# 2. Horizontal offset of sprite center relative to upper left tile corner.
# 3. Vertical offset of sprite center relative to upper left tile corner.
# 4. Metadata mask.
# 5. Expected metadata bits after applying mask.
# 6. Cursor type.
sub generate_poi_list()
{
   my @table = ();

   # Here we only generate entries positive X or Y values, since we
   # can get the other 3 quadrants via symmetry.  Not including those
   # entries saves ~600K of memory.
   for(my $dx = 0; $dx <= SCAN_RADIUS; $dx++)
   {
      for(my $dy = 0; $dy <= SCAN_RADIUS; $dy++)
      {
         # Ignore tiles that are too far away.
         if( distance2($dx, $dy) > SCAN_RADIUS * SCAN_RADIUS )
         {
            next;
         }

         # Diagonal mounts.
         push @table,
              [
                 $dx, $dy,
                 HALF_TILE_SIZE, HALF_TILE_SIZE,
                 MOUNT_UP | MOUNT_LEFT,
                 MOUNT_UP | MOUNT_LEFT,
                 CURSOR_D_SLASH,
              ];
         push @table,
              [
                 $dx, $dy,
                 HALF_TILE_SIZE, HALF_TILE_SIZE,
                 MOUNT_UP | MOUNT_RIGHT,
                 MOUNT_UP | MOUNT_RIGHT,
                 CURSOR_D_BACKSLASH,
              ];
         push @table,
              [
                 $dx, $dy,
                 HALF_TILE_SIZE, HALF_TILE_SIZE,
                 MOUNT_DOWN | MOUNT_LEFT,
                 MOUNT_DOWN | MOUNT_LEFT,
                 CURSOR_D_BACKSLASH,
              ];
         push @table,
              [
                 $dx, $dy,
                 HALF_TILE_SIZE, HALF_TILE_SIZE,
                 MOUNT_DOWN | MOUNT_RIGHT,
                 MOUNT_DOWN | MOUNT_RIGHT,
                 CURSOR_D_SLASH,
              ];

         # Axis-aligned mounts.
         push @table,
              [
                 $dx, $dy,
                 HALF_TILE_SIZE, 0,
                 MOUNT_LEFT | MOUNT_RIGHT | MOUNT_UP,
                 MOUNT_UP,
                 CURSOR_H_UP,
              ];
         push @table,
              [
                 $dx, $dy,
                 HALF_TILE_SIZE, TILE_SIZE - 1,
                 MOUNT_LEFT | MOUNT_RIGHT | MOUNT_DOWN,
                 MOUNT_DOWN,
                 CURSOR_H_DOWN,
              ];
         push @table,
              [
                 $dx, $dy,
                 0, HALF_TILE_SIZE,
                 MOUNT_UP | MOUNT_DOWN | MOUNT_LEFT,
                 MOUNT_LEFT,
                 CURSOR_V_LEFT,
              ];
         push @table,
              [
                 $dx, $dy,
                 TILE_SIZE - 1, HALF_TILE_SIZE,
                 MOUNT_UP | MOUNT_DOWN | MOUNT_RIGHT,
                 MOUNT_RIGHT,
                 CURSOR_V_RIGHT,
              ];

         # Chain reaction entry points.
         push @table,
              [
                 $dx, $dy,
                 HALF_TILE_SIZE, HALF_TILE_SIZE,
                 BREAKABLE | CHAIN_REACTION | TERMINAL_REACTION,
                 CHAIN_REACTION,
                 CURSOR_SQUARE,
              ];

         # Breakable tiles.
         push @table,
              [
                 $dx, $dy,
                 HALF_TILE_SIZE, HALF_TILE_SIZE,
                 BREAKABLE | CHAIN_REACTION | TERMINAL_REACTION,
                 BREAKABLE,
                 CURSOR_SQUARE,
              ];

         # Collectible tiles.
         push @table,
              [
                 $dx, $dy,
                 HALF_TILE_SIZE, HALF_TILE_SIZE,
                 COLLECTIBLE,
                 0,
                 CURSOR_CIRCLE,
              ];
      }
   }
   return @table;
}


# Generate points of interests sorted by distance.
my @table = sort {cmp_table_entries($a, $b)} generate_poi_list();

# Generate table grouped by frame, where each frame expands the radius
# by half a tile.
print "world.hints =\n{\n";
my $limit = 0;
my $previous_r2 = -1;
for(my $i = 0; $i < scalar @table; $limit += HALF_TILE_SIZE)
{
   print "\t{\n";
   my $max_distance2 = $limit * $limit;

   my $j = $i;
   for(; $j < scalar @table; $j++)
   {
      my $r2 = distance2_to_poi($table[$j]);
      if( $r2 > $max_distance2 )
      {
         last;
      }

      if( $r2 != $previous_r2 )
      {
         printf "\t\t-- Radius = %.2f\n", sqrt($r2);
         $previous_r2 = $r2;
      }
      print "\t\t{",
            $table[$j][0], ", ",  # [1] = Tile index offset X.
            $table[$j][1], ", ",  # [2] = Tile index offset Y.
            $table[$j][4], ", ",  # [3] = Mask.
            $table[$j][5], ", ",  # [4] = Expected bits.
            $table[$j][6],        # [5] = Cursor type.
            "},\n";
   }
   print "\t},\n";
   $i = $j;
}
print "}\n";
