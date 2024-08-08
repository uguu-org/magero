#!/usr/bin/perl -w
# Add random books to tower area.
#
# ./add_books.pl {input.svg} > {output.svg}

use strict;
use Digest::SHA qw(sha256);
use XML::LibXML;

use constant OUTPUT_LAYER => "IBG common - tower";
use constant BOOK_VARIATIONS => 10;

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

# Generate a list of (book width, book height, book color) values based on
# block coordinate.
sub generate_book_list($)
{
   my ($variation) = @_;

   my @rand = unpack "C*", sha256("$variation block");

   # Generate books until they fill up a block.
   my @books = ();
   my $width = 0;
   my $r = 0;
   my $previous_color = -1;
   while( $width < 64 )
   {
      my $book_width = 4 + ($rand[$r++ % 32] % 8);
      my $book_height = 26 + ($rand[$r++ % 32] % 32);

      # Avoid having two books of the same color be adjacent to each other.
      my $book_color;
      for(my $i = 0; $i < 32; $i++)
      {
         $book_color = 188 + ($rand[$r++ % 32] % 16) * 4;
         last if( $book_color != $previous_color );
      }

      push @books, [$book_width, $book_height, $book_color];
      $width += $book_width;
      $previous_color = $book_color;
   }

   # Chop the last book to make sure it fits within the block.
   $books[$#books][0] -= $width - 64;

   return @books;
}

# Syntactic sugar.
sub copy_book_list($$$$)
{
   my ($block, $book_list, $x, $y) = @_;

   my @books = ();
   foreach my $i (@{$$book_list{$$block{$y}{$x}}})
   {
      my @d = @$i;
      push @books, [$d[0], $d[1], $d[2]];
   }
   return @books;
}

# Add a single 64x64 block.
sub add_block($$$$$)
{
   my ($dom, $block, $book_list, $x, $y) = @_;

   # Get block definition for current and adjacent blocks.
   my @books = copy_book_list($block, $book_list, $x, $y);
   my @adjacent_books = copy_book_list($block, $book_list, $x + 64, $y);

   # Update the last book in current block such that it matches the height
   # and color of the first book in the adjacent block.  This makes the
   # block boundary seamless.
   #
   # Note that these adjustment at the boundaries are going to increase
   # tile variations, but this is a price we are willing to pay.
   $books[$#books][1] = $adjacent_books[0][1];
   $books[$#books][2] = $adjacent_books[0][2];

   # Add books as rectangles.
   my $book_x = $x;
   for(my $i = 0; $i < scalar @books; $i++)
   {
      my $rect = XML::LibXML::Element->new("rect");
      $rect->{"x"} = $book_x;
      $book_x += $books[$i][0];
      $rect->{"y"} = $y - $books[$i][1];
      $rect->{"width"} = $books[$i][0];
      $rect->{"height"} = $books[$i][1];
      my $fill = (sprintf '%02x', $books[$i][2]) x 3;
      $rect->{"style"} = "fill:#$fill;stroke:none";
      $dom->addChild($rect);
   }
}

# Add books to output layer.
sub add_books($)
{
   my ($dom) = @_;

   # There are two floors of books with 4 shelves each:
   #
   # Floor 5:
   # - top shelf = (416, 1760)
   # - bottom shelf = (416, 1952)
   # - right edge = 992
   #
   # Floor 4:
   # - top shelf = (416, 2080),
   # - bottom shelf = (416, 2272)
   # - right edge = 1056
   #
   # We will generate 64x64 blocks to populate those shelves.  The first
   # step is to generate those random blocks, and do so in a way to avoid
   # having a block appear beneath another block of the same type.
   my @random_variations = unpack "C*", sha256("block variations");
   my $r = 0;
   my %block = ();
   for(my $y = 1760; $y <= 2272; $y += 64)
   {
      for(my $x = 416; $x <= 1056; $x += 64)
      {
         for(my $i = 0; $i < 32; $i++)
         {
            $block{$y}{$x} = $random_variations[$r++ % 32] % BOOK_VARIATIONS;
            my $above1 = $block{$y - 64}{$x} || -1;
            my $above2 = $block{$y - 128}{$x} || -1;
            my $above3 = $block{$y - 192}{$x} || -1;
            if( $block{$y}{$x} != $above1 &&
                $block{$y}{$x} != $above2 &&
                $block{$y}{$x} != $above3 )
            {
               last;
            }
         }
      }
   }

   # Generate list of books for each block type.
   my %book_list = ();
   for(my $i = 0; $i < BOOK_VARIATIONS; $i++)
   {
      @{$book_list{$i}} = generate_book_list($i);
   }

   # Add blocks using generated book lists.
   for(my $y = 1760; $y <= 1952; $y += 64)
   {
      for(my $x = 416; $x < 992; $x += 64)
      {
         add_block($dom, \%block, \%book_list, $x, $y);
      }
   }
   for(my $y = 2080; $y <= 2272; $y += 64)
   {
      for(my $x = 416; $x < 1056; $x += 64)
      {
         add_block($dom, \%block, \%book_list, $x, $y);
      }
   }
}


# Load input.
if( $#ARGV != 0 )
{
   die "$0 {input.svg} > {output.svg}\n";
}
my $dom = XML::LibXML->load_xml(location => $ARGV[0]);

# Add books.
add_books(find_layer_by_name($dom, OUTPUT_LAYER));

# Output updated XML.
print $dom->toString(), "\n";
