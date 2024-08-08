/* Remove breakable + collectible + chain reaction tiles from foreground image.

   ./remove_mutable_fg {metadata.png} {gray_bg.png} {output.png}

   This is meant to preprocess input images for use with remove_hidden_tiles.c,
   so that we preserve tiles that are behind mutable tiles.  This tool removes
   a superset of the tiles removed by remove_mutable_bg.c.
*/

#include<png.h>
#include<stdio.h>
#include<stdlib.h>
#include<string.h>

#define TILE_SIZE 32

/* Read a single pixel that's packed with RGBA bytes.  If we want to build
   this tool on a big-endian machine, we will need to reverse the byte order
   here, or replace PNG_FORMAT_RGBA with PNG_FORMAT_ABGR.                    */
#define READ_RGBA(p, offset) (*(unsigned int*)((p) + (offset)))

/* Load a single image, returns 0 on success. */
static int LoadImage(const char *filename,
                     int format,
                     png_image *image,
                     png_bytep *pixels)
{
   memset(image, 0, sizeof(png_image));
   image->version = PNG_IMAGE_VERSION;
   if( !png_image_begin_read_from_file(image, filename) )
      return printf("Error reading %s\n", filename);

   image->format = format;
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

/* Compute byte offset to center of a RGBA tile. */
static int RGBATileCenter(int width, int x, int y)
{
   return ((y + TILE_SIZE / 2) * width + (x + TILE_SIZE / 2)) * 4;
}

/* Compute byte offset to auxiliary center of a RGBA tile. */
static int RGBATileOffCenter(int width, int x, int y)
{
   return ((y + TILE_SIZE / 4 + 1) * width + (x + TILE_SIZE / 4 + 1)) * 4;
}

/* Compute byte offset to upper left corner of a GA tile. */
static int GATileOffset(int width, int x, int y)
{
   return (y * width + x) * 2;
}

/* Check annotation based on center and auxiliary center pixel colors.
   Returns nonzero if tile is mutable.                                 */
static int IsMutable(unsigned int pixel, unsigned int auxiliary_pixel)
{
   /* Ignore all transparent pixels. */
   if( (pixel & 0xff000000) == 0 )
      return 0;

   /* Ignore empty annotations. */
   if( (pixel & 0xffffff) == 0 )
      return 0;

   /* Check for breakable tiles (red). */
   if( ((pixel & 0x0000ff) > 0x00007f) &&
       ((pixel & 0x00ff00) < 0x008000) &&
       ((pixel & 0xff0000) < 0x800000) )
   {
      /* Ignore ghost collision tiles.  Ghost collision tiles would have
         a red auxiliary_pixel, regular breakable tiles would have a black
         auxiliary_pixel.  Checking the latter here.                       */
      return (auxiliary_pixel & 0xffffff) == 0;
   }

   /* Remaining annotations are all related to removable foreground tiles:
      - chain reaction (cyan)
      - breakable chain reaction (magenta)
      - collectible (green)
      - throwable (yellow)                                                 */
   return 1;
}

/* Remove tiles that are breakable/collectible/chain reaction tiles. */
static void RemoveMatchingTiles(int width,
                                int height,
                                png_bytep metadata_pixels,
                                png_bytep pixels)
{
   int x, y, cell_y;

   for(y = 0; y < height; y += TILE_SIZE)
   {
      for(x = 0; x < width; x += TILE_SIZE)
      {
         if( IsMutable(READ_RGBA(metadata_pixels,
                                 RGBATileCenter(width, x, y)),
                       READ_RGBA(metadata_pixels,
                                 RGBATileOffCenter(width, x, y))) )
         {
            for(cell_y = 0; cell_y < TILE_SIZE; cell_y++)
            {
               memset(pixels + GATileOffset(width, x, y + cell_y),
                      0,
                      TILE_SIZE * 2);
            }
         }
      }
   }
}

int main(int argc, char **argv)
{
   png_image metadata, image;
   png_bytep metadata_pixels = NULL, pixels = NULL;

   if( argc != 4 )
      return printf("%s {metadata.png} {input.png} {output.png}\n", *argv);

   /* Load input. */
   if( LoadImage(argv[1], PNG_FORMAT_RGBA, &metadata, &metadata_pixels) ||
       LoadImage(argv[2], PNG_FORMAT_GA, &image, &pixels) )
   {
      goto fail;
   }

   /* Process image. */
   if( metadata.width != image.width || metadata.height != image.height )
   {
      printf("Size mismatched: (%d,%d) vs (%d,%d)\n",
             (int)metadata.width, (int)metadata.height,
             (int)image.width, (int)image.height);
      goto fail;
   }
   if( (image.width % TILE_SIZE) != 0 || (image.height % TILE_SIZE) != 0 )
   {
      printf("Image dimension is not a multiple of tile size (%d): (%d,%d)\n",
             TILE_SIZE, (int)image.width, (int)image.height);
      goto fail;
   }
   RemoveMatchingTiles(image.width, image.height, metadata_pixels, pixels);

   /* Write output.  Here we set the flags to optimize for encoding speed
      rather than output size so that we can iterate faster.  This is fine
      since the output of this tool are intermediate files that are used
      only in the build process, and are not the final PNGs that will be
      committed.                                                           */
   image.flags |= PNG_IMAGE_FLAG_FAST;
   if( !png_image_write_to_file(&image, argv[3], 0, pixels, 0, NULL) )
   {
      printf("Error writing %s\n", argv[3]);
      goto fail;
   }

   free(metadata_pixels);
   free(pixels);
   return 0;

fail:
   free(metadata_pixels);
   free(pixels);
   return 1;
}
