#!/usr/bin/perl -w
# Generate grayscale font bitmaps as a C array, for use with
# collect_tile_layers.c

use strict;
use constant TEXT => "0123456789,";
use constant CHAR_COUNT => length(TEXT);
use constant CHAR_WIDTH => 16;
use constant CHAR_HEIGHT => 32;
use constant BASELINE => 27;

# Build command to generate PGM with digits.
#
# We want a font that fills a 16x32 box.  Helvetica at 29 points appears to do
# the trick, and it's available on two different systems I tested.
#
# If the font is not available, magick will output error messages of the form
# "unable to read font" to stderr, but still exit with success status using
# some fallback font.  We could just leave font unspecified here and always
# use the fallback, but that depends on what is configured as the system
# default, so specifying a common font seem to be a more stable choice.
my $cmd =
   "magick" .
   " -depth 8" .
   " -size " . (CHAR_COUNT * CHAR_WIDTH) . "x" . CHAR_HEIGHT .
   ' "xc:rgba(0,0,0,1)"' .
   " -fill white" .
   " -font Helvetica" .
   " -pointsize 29";

for(my $i = 0; $i < CHAR_COUNT; $i++)
{
   $cmd .= ' -annotate "+' . ($i * 16) . '+' . BASELINE .
           '" "' . substr(TEXT, $i, 1) . '"';
}
$cmd .= " pgm:-";

# Read rasterized PGM data.
open my $pipe, "$cmd|" or die $!;
my $pgm = join '', <$pipe>;
close $pipe;

my $header = "P5\n" . (CHAR_COUNT * 16) . " 32\n255\n";
if( substr($pgm, 0, length($header)) ne $header )
{
   die "Header mismatched\n";
}
$pgm = substr($pgm, length($header));

# Convert pixel bytes to C.
my $bytes_per_row = CHAR_COUNT * CHAR_WIDTH;
print "unsigned char font[" . CHAR_COUNT .  "][" .
      CHAR_HEIGHT . "][" . CHAR_WIDTH . "] =\n{\n";
for(my $i = 0; $i < CHAR_COUNT; $i++)
{
   print "\t{\n";
   for(my $y = 0; $y < CHAR_HEIGHT; $y++)
   {
      print "\t\t{",
            (join ",", map {sprintf '0x%02x', $_}
                       unpack 'C*',
                       substr($pgm,
                              $y * CHAR_COUNT * CHAR_WIDTH + $i * CHAR_WIDTH,
                              CHAR_WIDTH)) .
            "}",
            ($y + 1 == CHAR_HEIGHT ? "\n" : ",\n");
   }
   print "\t}", ($i + 1 == CHAR_COUNT ? "\n" : ",\n");
}
print "};\n";
