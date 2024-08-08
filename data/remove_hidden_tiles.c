/* Replace hidden tiles with transparent tiles.

   Usage:

      ./remove_hidden_tiles {top.png} {bottom.png} {output.png}

   For every tile in {bottom.png} that would be completely obscured by a
   tile in {top.png} at the same position, replace that tile with a
   transparent tile.  One of {top.png} or {bottom.png} can be replaced by "-"
   to read from stdin, and {output.png} can be replaced by "-" to write to
   stdout.

   This is used to remove tiles in the background layers that would be
   completely hidden behind tiles in the foreground layer.  Doing so increases
   the number of empty tiles in background layer and reduces tile variations,
   which in turn saves memory.

   This tool assumes that {top.png} contains tiles that are not mutable, i.e.
   we won't remove any tiles that would be revealed through modifications to
   the top layer.  This assumption holds because the input is preprocessed by
   remove_mutable_fg.c, and would only contain immutable tiles.
*/

#include<png.h>
#include<stdio.h>
#include<stdlib.h>
#include<string.h>

#ifdef _WIN32
   #include<fcntl.h>
   #include<io.h>
#endif

#define TILE_SIZE 32

/* Load a single image, returns 0 on success. */
static int LoadImage(const char *filename, png_image *image, png_bytep *pixels)
{
   memset(image, 0, sizeof(png_image));
   image->version = PNG_IMAGE_VERSION;

   if( strcmp(filename, "-") == 0 )
   {
      if( !png_image_begin_read_from_stdio(image, stdin) )
         return printf("Error reading %s (stdin)\n", filename);
   }
   else
   {
      if( !png_image_begin_read_from_file(image, filename) )
         return printf("Error reading %s\n", filename);
   }

   image->format = PNG_FORMAT_GA;
   *pixels = (png_bytep)malloc(PNG_IMAGE_SIZE(*image));
   if( *pixels == NULL )
      return puts("Out of memory");
   if( !png_image_finish_read(image, NULL, *pixels, 0, NULL) )
   {
      free(*pixels);
      return printf("Error loading %s\n", filename);
   }
   return 0;
}

/* Check tile at a particular offset, and return nonzero if bottom tile
   is completely obscured by the top.                                   */
static int IsInvisible(
   png_image *image, png_bytep bottom, png_bytep top, int x, int y)
{
   int ix, iy, offset;

   for(iy = 0; iy < TILE_SIZE; iy++)
   {
      offset = ((y + iy) * image->width + x) * 2;
      for(ix = 0; ix < TILE_SIZE; ix++)
      {
         /* Bottom pixel is always invisible if it's transparent. */
         if( bottom[offset + ix * 2 + 1] == 0 )
            continue;

         /* Bottom pixel is not transparent.  If top pixel is not opaque,
            bottom pixel would be visible.                                */
         if( top[offset + ix * 2 + 1] != 0xff )
            return 0;
      }
   }

   /* All bottom pixels are hidden. */
   return 1;
}

/* Erase a single tile. */
static void EraseTile(png_image *image, png_bytep pixels, int x, int y)
{
   int i;

   for(i = 0; i < TILE_SIZE; i++)
      memset(pixels + ((y + i) * image->width + x) * 2, 0, TILE_SIZE * 2);
}

int main(int argc, char **argv)
{
   png_image top_image, bottom_image;
   png_bytep top_pixels = NULL, bottom_pixels = NULL;
   int x, y;

   if( argc != 4 )
      return printf("%s {top.png} {bottom.png} {output.png}\n", *argv);

   #ifdef _WIN32
      setmode(STDIN_FILENO, O_BINARY);
      setmode(STDOUT_FILENO, O_BINARY);
   #endif

   /* Load input. */
   if( LoadImage(argv[1], &top_image, &top_pixels) ||
       LoadImage(argv[2], &bottom_image, &bottom_pixels) )
   {
      goto fail;
   }
   if( top_image.width != bottom_image.width ||
       top_image.height != bottom_image.height )
   {
      printf("Image dimensions mismatched: (%d,%d) vs (%d,%d)\n",
             (int)top_image.width, (int)top_image.height,
             (int)bottom_image.width, (int)bottom_image.height);
      goto fail;
   }
   if( (bottom_image.width % TILE_SIZE) != 0 ||
       (bottom_image.height % TILE_SIZE) != 0 )
   {
      printf("Image dimension is not a multiple of tile size (%d): (%d,%d)\n",
             TILE_SIZE, (int)bottom_image.width, (int)bottom_image.height);
      goto fail;
   }

   /* Process image. */
   for(y = 0; y < (int)bottom_image.height; y += TILE_SIZE)
   {
      for(x = 0; x < (int)bottom_image.width; x += TILE_SIZE)
      {
         if( IsInvisible(&bottom_image, bottom_pixels, top_pixels, x, y) )
            EraseTile(&bottom_image, bottom_pixels, x, y);
      }
   }

   /* Write output.  Here we set the flags to optimize for encoding speed
      rather than output size so that we can iterate faster.  This is fine
      since the output of this tool are intermediate files that are used
      only in the build process, and are not the final PNGs that will be
      committed.                                                           */
   bottom_image.flags |= PNG_IMAGE_FLAG_FAST;
   if( strcmp(argv[3], "-") == 0 )
   {
      if( !png_image_write_to_stdio(
             &bottom_image, stdout, 0, bottom_pixels, 0, NULL) )
      {
         printf("Error writing %s (stdout)\n", argv[3]);
         goto fail;
      }
   }
   else
   {
      if( !png_image_write_to_file(
             &bottom_image, argv[3], 0, bottom_pixels, 0, NULL) )
      {
         printf("Error writing %s\n", argv[3]);
         goto fail;
      }
   }

   free(top_pixels);
   free(bottom_pixels);
   return 0;

fail:
   free(top_pixels);
   free(bottom_pixels);
   return 1;
}
