/* List annotated tiles from metadata image.

   Usage:
      ./list_annotated_tiles {metadata.png} > {output.txt}

   One use case for this is to count various things we have placed on
   the map.  We can get this from data.lua as well, but it's more
   efficient to use this tool since it has fewer build dependencies.

      make -j debug_annotated_tiles
      grep -F collectible t_annotated_tiles.txt | wc -l
      grep -F throwable t_annotated_tiles.txt | wc -l
      grep -F teleport t_annotated_tiles.txt | wc -l
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

/* Compute byte offset to right side of a RGBA tile. */
static int RGBATileRight(int width, int x, int y)
{
   return ((y + TILE_SIZE / 2) * width + x + TILE_SIZE - 1) * 4;
}

/* Compute byte offset at the top side of a RGBA tile. */
static int RGBATileTop(int width, int x, int y)
{
   return (y * width + x + TILE_SIZE / 2) * 4;
}

/* Output annotation for single tile. */
static void AnnotateTile(
   int x, int y, unsigned int primary, unsigned int secondary)
{
   int primary_bits =
      (((primary & 0x0000ff) > 0x00007f) ? 1 : 0) |
      (((primary & 0x00ff00) > 0x007f00) ? 2 : 0) |
      (((primary & 0xff0000) > 0x7f0000) ? 4 : 0);
   int secondary_bits =
      (((secondary & 0x0000ff) > 0x00007f) ? 1 : 0) |
      (((secondary & 0x00ff00) > 0x007f00) ? 2 : 0) |
      (((secondary & 0xff0000) > 0x7f0000) ? 4 : 0);
   switch( primary_bits )
   {
      case 0:
         break;
      case 1:  /* R */
         printf("%d,%d: %s\n", x, y,
                secondary_bits == 1 ? "ghost collision" : "breakable");
         break;
      case 2:  /* G */
         printf("%d,%d: %s\n", x, y,
                secondary_bits == 2 ? "hidden collectible" : "collectible");
         break;
      case 3:  /* RG */
         printf("%d,%d: throwable\n", x, y);
         break;
      case 5:  /* RB */
         printf("%d,%d: %s\n", x, y,
                secondary_bits == 5 ? "terminal breakable chain reaction"
                                    : "breakable chain reaction");
         break;
      case 6:  /* RG */
         printf("%d,%d: %s\n", x, y,
                secondary_bits == 6 ? "terminal reaction" : "chain reaction");
         break;
      default:
         break;
   }
}

/* Output positional annotations. */
static void CheckBlueDots(int x, int y, unsigned int right, unsigned int top)
{
   if( (right & 0x0000ff) < 0x000080 &&
       (right & 0x00ff00) < 0x008000 &&
       (right & 0xff0000) > 0x7f0000 )
   {
      printf("%d,%d: starting position\n",
             x + TILE_SIZE - 1, y + TILE_SIZE / 2);
   }
   if( (top & 0x0000ff) < 0x000080 &&
       (top & 0x00ff00) < 0x008000 &&
       (top & 0xff0000) > 0x7f0000 )
   {
      printf("%d,%d: teleport station\n", x + TILE_SIZE / 2, y);
   }
}

int main(int argc, char **argv)
{
   png_image image;
   png_bytep pixels;
   int x, y;

   if( argc != 2 )
      return printf("%s {metadata.png}\n", *argv);

   /* Load input. */
   memset(&image, 0, sizeof(image));
   image.version = PNG_IMAGE_VERSION;
   if( !png_image_begin_read_from_file(&image, argv[1]) )
      return printf("Error reading %s\n", argv[1]);
   if( (image.width % TILE_SIZE) != 0 || (image.height % TILE_SIZE) != 0 )
   {
      return printf(
         "Image dimension is not a multiple of tile size (%d): (%d,%d)\n",
         TILE_SIZE, (int)image.width, (int)image.height);
   }

   image.format = PNG_FORMAT_RGBA;
   pixels = (png_bytep)malloc(PNG_IMAGE_SIZE(image));
   if( pixels == NULL )
      return puts("Out of memory");
   if( !png_image_finish_read(&image, NULL, pixels, 0, NULL) )
   {
      free(pixels);
      return printf("Error loading %s\n", argv[1]);
   }

   /* Check each tile. */
   for(y = 0; y < (int)image.height; y += TILE_SIZE)
   {
      for(x = 0; x < (int)image.width; x += TILE_SIZE)
      {
         AnnotateTile(x, y,
                      READ_RGBA(pixels, RGBATileCenter(image.width, x, y)),
                      READ_RGBA(pixels, RGBATileOffCenter(image.width, x, y)));
         CheckBlueDots(x, y,
                       READ_RGBA(pixels, RGBATileRight(image.width, x, y)),
                       READ_RGBA(pixels, RGBATileTop(image.width, x, y)));
      }
   }

   /* Cleanup. */
   free(pixels);
   return 0;
}
