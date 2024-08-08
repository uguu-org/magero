/* Replace hidden tiles with foreground tiles.

   Usage:

      ./transfer_hidden_tiles {in_a.png} {in_b.png} {out_a.png} {out_b.png}

   For every tile in {in_b.png} that would be completely obscured by a tile
   in {in_a.png} at the same position, move the corresponding tile from
   {in_a.png} to {in_b.png}, leaving behind an empty tile in {in_a.png}.
   After all tiles are processed, outputs are written to {out_a.png} and
   {out_b.png}.  Either {in_a.png} or {in_b.png} can be "-" to read from
   stdin, but output must be written to files.

   This is related to remove_hidden_tiles.c in that it's a memory
   optimization based on tile visibility, but unlike remove_hidden_tiles.c
   which blanks out the bottom layer, this tool blanks out the top layer.
   This is done specifically to optimize for our two background layers, where
   drawing tiles on the IBG layer (bottom) comes out cheaper than drawing
   them on the BG layer (top) because compressed IBG layer data is discarded
   during load while BG layer data are retained.

   Note that we can't simply flatten IBG and BG layers into a single layer.
   It wouldn't visually work because some IBG tiles serves as backgrounds for
   mutable BG tiles (collectibles and throwables).  It also would use more
   memory because some tile variations are avoided by combining two distinct
   tiles, particularly near edges of terrains.

   This tool assumes that {in_a.png} contains tiles that are not mutable, i.e.
   we won't remove any tiles that would be revealed through modifications to
   the top layer.  This assumption holds because the input is preprocessed by
   remove_mutable_bg.c, and would only contain immutable tiles.
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

/* Transfer a single tile. */
static void TransferTile(png_image *image,
                         png_bytep source_pixels,
                         png_bytep target_pixels,
                         int x, int y)
{
   int i, offset = (y * image->width + x) * 2;

   for(i = 0; i < TILE_SIZE; i++)
   {
      memcpy(target_pixels + offset, source_pixels + offset, TILE_SIZE * 2);
      memset(source_pixels + offset, 0, TILE_SIZE * 2);
      offset += image->width * 2;
   }
}

int main(int argc, char **argv)
{
   png_image top_image, bottom_image;
   png_bytep top_pixels = NULL, bottom_pixels = NULL;
   int x, y;

   if( argc != 5 )
   {
      return printf("%s {in_a.png} {in_b.png} {out_a.png} {out_b.png}\n",
                    *argv);
   }

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
             top_image.width, top_image.height,
             bottom_image.width, bottom_image.height);
      goto fail;
   }
   if( (bottom_image.width % TILE_SIZE) != 0 ||
       (bottom_image.height % TILE_SIZE) != 0 )
   {
      printf("Image dimension is not a multiple of tile size (%d): (%d,%d)\n",
             bottom_image.width, bottom_image.height, TILE_SIZE);
      goto fail;
   }

   /* Process image. */
   for(y = 0; y < (int)bottom_image.height; y += TILE_SIZE)
   {
      for(x = 0; x < (int)bottom_image.width; x += TILE_SIZE)
      {
         if( IsInvisible(&bottom_image, bottom_pixels, top_pixels, x, y) )
            TransferTile(&top_image, top_pixels, bottom_pixels, x, y);
      }
   }

   /* Write output.  Here we set the flags to optimize for encoding speed
      rather than output size so that we can iterate faster.  This is fine
      since the output of this tool are intermediate files that are used
      only in the build process, and are not the final PNGs that will be
      committed.                                                           */
   top_image.flags |= PNG_IMAGE_FLAG_FAST;
   bottom_image.flags |= PNG_IMAGE_FLAG_FAST;
   if( !png_image_write_to_file(&top_image, argv[3], 0, top_pixels, 0, NULL) )
   {
      printf("Error writing %s\n", argv[3]);
      goto fail;
   }
   if( !png_image_write_to_file(
          &bottom_image, argv[4], 0, bottom_pixels, 0, NULL) )
   {
      printf("Error writing %s\n", argv[4]);
      goto fail;
   }

   free(top_pixels);
   free(bottom_pixels);
   return 0;

fail:
   free(top_pixels);
   free(bottom_pixels);
   return 1;
}
