/* Read metadata and background image, and generate a new image highlighting
   tiles that are mountable.

   ./show_mountable_tiles {world_data.lua} {gray_bg0.png} {output.png}

   This tool exists since the mount bits are derived from other metadata
   bits, so they are not visible in world_master.svg.  This tool shows which
   tiles can be mounted, and helps in finding tiles that don't have enough
   contrast for drawing the mount cursor (we want tiles that are mostly
   black or white, since drawing cursor involves inverting some pixels, and
   inverting gray results in gray).

   It's tempting to generalize this to a more advanced tool that also shows
   which tiles are reachable, but that would involve reimplementing
   check_mount_poses() in ../source/arm.lua and all the collision functions
   that go with it.  It might be fun, but also time consuming.  It's far
   easier to test for reachability by running the simulator.
*/

#include<png.h>
#include<stdio.h>
#include<stdlib.h>
#include<string.h>

#define GRID_WIDTH   300
#define GRID_HEIGHT  200
#define TILE_SIZE    32

/* World data. */
static int mount_mask = 0;
static int grid[GRID_HEIGHT][GRID_WIDTH];

/* Read input stream until expected token is found.  Returns 0 on success. */
static int Expect(FILE *infile, const char *token)
{
   int match = 0;
   int c;

   while( (c = fgetc(infile)) != EOF )
   {
      if( c == token[match] )
      {
         match++;
         if( token[match] == '\0' )
            return 0;
      }
      else
      {
         match = 0;
      }
   }
   return 1;
}

/* Load metadata from Lua input and update global `mount_mask` and `grid`
   variables.  Returns 0 on success.                                      */
static int LoadMetadata(char *filename)
{
   static const char *mount_mask_header[2] = {"world.MOUNT_MASK", "="};
   static const char *metadata_header[3] = {"world.metadata", "=", "{"};
   FILE *infile;
   int i, x, y;

   if( (infile = fopen(filename, "rb")) == NULL )
      return printf("%s: read error\n", filename);

   /* Load mount mask. */
   for(i = 0; i < 2; i++)
   {
      if( Expect(infile, mount_mask_header[i]) )
         goto parse_error;
   }
   if( fscanf(infile, "%d", &mount_mask) != 1 )
      goto parse_error;

   /* Load metadata grid. */
   for(i = 0; i < 3; i++)
   {
      if( Expect(infile, metadata_header[i]) )
         goto parse_error;
   }

   /* Load grid cells. */
   for(y = 0; y < GRID_HEIGHT; y++)
   {
      for(x = 0; x < GRID_WIDTH; x++)
      {
         if( Expect(infile, x == 0 ? "{" : ",") )
            goto parse_error;
         if( fscanf(infile, "%d", &i) != 1 )
            goto parse_error;
         grid[y][x] = i;
      }
      if( Expect(infile, "},") )
         goto parse_error;
   }

   fclose(infile);
   return 0;

parse_error:
   /* Close file and return status on parse error.  The error description
      isn't very descriptive, but this isn't meant to be a general tool.
      If we had wanted it to be general, we would have been tracking line
      numbers, at least.                                                  */
   fclose(infile);
   return printf("%s: parse error\n", filename);
}

/* Reduce the opacity of all tiles that are not mountable. */
static void AdjustUnmountableTiles(png_bytep pixels)
{
   int tile_x, tile_y, cell_x, cell_y, x, y, offset;

   for(tile_y = 0; tile_y < GRID_HEIGHT; tile_y++)
   {
      y = tile_y * TILE_SIZE;
      for(tile_x = 0; tile_x < GRID_WIDTH; tile_x++)
      {
         if( (grid[tile_y][tile_x] & mount_mask) != 0 )
            continue;
         x = tile_x * TILE_SIZE;

         for(cell_y = 0; cell_y < TILE_SIZE; cell_y++)
         {
            for(cell_x = 0; cell_x < TILE_SIZE; cell_x++)
            {
               offset = ((y + cell_y) * GRID_WIDTH * TILE_SIZE +
                         x + cell_x) * 2 + 1;
               pixels[offset] = (unsigned char)((pixels[offset] >> 2) & 0xff);
            }
         }
      }
   }
}

int main(int argc, char **argv)
{
   png_image image;
   png_bytep pixels;

   if( argc != 4 )
      return printf("%s {world_data.lua} {gray_bg0.png} {output.png}\n", *argv);

   /* Load input. */
   if( LoadMetadata(argv[1]) )
      return 1;
   memset(&image, 0, sizeof(image));
   image.version = PNG_IMAGE_VERSION;
   if( !png_image_begin_read_from_file(&image, argv[2]) )
      return printf("%s: read error\n", argv[2]);
   if( image.width != GRID_WIDTH * TILE_SIZE ||
       image.height != GRID_HEIGHT * TILE_SIZE )
   {
      return printf("%s: expected size to be (%d,%d), got (%d,%d)\n",
                    argv[2],
                    GRID_WIDTH * TILE_SIZE, GRID_HEIGHT * TILE_SIZE,
                    (int)image.width, (int)image.height);
   }
   image.format = PNG_FORMAT_GA;
   pixels = (png_bytep)malloc(PNG_IMAGE_SIZE(image));
   if( pixels == NULL )
      return puts("Out of memory");
   if( !png_image_finish_read(&image, NULL, pixels, 0, NULL) )
   {
      free(pixels);
      return printf("%s: error loading image\n", argv[2]);
   }

   /* Process image. */
   AdjustUnmountableTiles(pixels);

   /* Write output.  Note that we optimized for encoding speed rather than
      output size.  This is fine since output is only used for debugging.  */
   image.flags |= PNG_IMAGE_FLAG_FAST;
   if( !png_image_write_to_file(&image, argv[3], 0, pixels, 0, NULL) )
   {
      free(pixels);
      return printf("%s: write error\n", argv[3]);
   }

   free(pixels);
   return 0;
}
