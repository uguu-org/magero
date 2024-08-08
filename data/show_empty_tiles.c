/* Find tiles that are completely transparent.

   Usage:

      ./show_empty_tiles {input.png} {output.png}

   Use "-" for input or output to read/write from stdin/stdout.

   Tiles that are completely transparent will be replaced with all white
   pixels.  Any tile that contains at least one visible pixel will be
   replaced with all black pixels.

   To check if a particular location is paintable in endgame, we check BG
   layer for frame 0 to see if it's empty.  In practice, this is not
   sufficient because frames 1..3 could have a different emptiness state,
   usually due to transfer_hidden_tiles.c reacting to the underlying IBG
   layers being different at each frame.  This tool is used to canonicalize
   BG layer tiles as empty/not empty, so that we can easily find where those
   tile discrepancies are.

   We could also avoiding writing this tool and just use "magick compare",
   but that runs very slow for some reason.
*/

#include<png.h>
#include<stdio.h>
#include<stdlib.h>
#include<string.h>
#include<unistd.h>

#ifdef _WIN32
   #include<fcntl.h>
   #include<io.h>
#endif

#define TILE_SIZE 32

/* Check if a particular tile is completely invisible, returns 1 if so. */
static int IsEmpty(png_image *image, png_bytep pixels, int x, int y)
{
   int ix, iy, offset;

   for(iy = 0; iy < TILE_SIZE; iy++)
   {
      /* Set offset to point at first alpha byte. */
      offset = ((y + iy) * image->width + x) * 2 + 1;
      for(ix = 0; ix < TILE_SIZE; ix++, offset += 2)
      {
         if( pixels[offset] != 0 )
            return 0;
      }
   }
   return 1;
}

/* Fill a tile with a solid color. */
static void Fill(png_image *image, png_bytep pixels,
                 int x, int y, unsigned char color)
{
   int ix, iy, offset;

   for(iy = 0; iy < TILE_SIZE; iy++)
   {
      /* Set offset to point at first color byte. */
      offset = ((y + iy) * image->width + x) * 2;
      for(ix = 0; ix < TILE_SIZE; ix++)
      {
         pixels[offset++] = color;
         pixels[offset++] = 0xff;
      }
   }
}

int main(int argc, char **argv)
{
   png_image image;
   png_bytep pixels;
   int x, y;

   if( argc != 3 )
      return printf("%s {input.png} {output.png}\n", *argv);
   if( strcmp(argv[2], "-") == 0 && isatty(STDOUT_FILENO) )
   {
      fputs("Not writing output to stdout because it's a tty\n", stderr);
      return 1;
   }
   #ifdef _WIN32
      setmode(STDIN_FILENO, O_BINARY);
      setmode(STDOUT_FILENO, O_BINARY);
   #endif

   /* Load input. */
   memset(&image, 0, sizeof(image));
   image.version = PNG_IMAGE_VERSION;
   if( strcmp(argv[1], "-") == 0 )
   {
      if( !png_image_begin_read_from_stdio(&image, stdin) )
         return puts("Error reading from stdin");
   }
   else
   {
      if( !png_image_begin_read_from_file(&image, argv[1]) )
         return printf("Error reading %s\n", argv[1]);
   }
   if( (image.width % TILE_SIZE) != 0 || (image.height % TILE_SIZE) != 0 )
   {
      return printf(
         "Image dimension is not a multiple of tile size (%d): (%d,%d)\n",
         TILE_SIZE, (int)image.width, (int)image.height);
   }

   image.format = PNG_FORMAT_GA;
   pixels = (png_bytep)malloc(PNG_IMAGE_SIZE(image));
   if( pixels == NULL )
      return puts("Out of memory");
   if( !png_image_finish_read(&image, NULL, pixels, 0, NULL) )
   {
      free(pixels);
      return printf("Error loading %s\n", argv[1]);
   }

   /* Check and update tiles. */
   for(y = 0; y < (int)image.height; y += TILE_SIZE)
   {
      for(x = 0; x < (int)image.width; x += TILE_SIZE)
      {
         if( IsEmpty(&image, pixels, x, y) )
            Fill(&image, pixels, x, y, 0xff);
         else
            Fill(&image, pixels, x, y, 0);
      }
   }

   /* Write output.  Here we set the flags to optimize for encoding speed
      rather than output size so that we can iterate faster.  This is fine
      since the output of this tool are intermediate files that are used
      only in the build process, and are not the final PNGs that will be
      committed.                                                           */
   image.flags |= PNG_IMAGE_FLAG_FAST;
   x = 0;
   if( strcmp(argv[2], "-") == 0 )
   {
      if( !png_image_write_to_stdio(&image, stdout, 0, pixels, 0, NULL) )
      {
         fputs("Error writing to stdout\n", stderr);
         x = 1;
      }
   }
   else
   {
      if( !png_image_write_to_file(&image, argv[2], 0, pixels, 0, NULL) )
      {
         printf("Error writing %s\n", argv[2]);
         x = 1;
      }
   }
   free(pixels);
   return x;
}
