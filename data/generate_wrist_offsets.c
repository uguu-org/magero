/* Read in arm sprite images (t_arm_table_160_160.png) and output offsets
   for where the wrist holes are located relative to the elbow centers.

   In theory, we wouldn't need to do this and the center of the wrist holes
   can be obtained by just cos+sin, but those tend to be off by a few
   pixels.  This tool allows us to apply some heuristics to place the
   center that may be better aligned with the visual center of those holes.

   Current heuristic affects 67 out of the 90 rotation angles.  Of those,
   63 of the angles could have been taken care of by better rounding
   (instead of truncating ARM_LENGTH*sin and ARM_LENGTH*cos).  The
   remaining 4 are where this tool chose a wrist center that is diagonally
   1 pixel away from the rounded placements.  So it's really a lot of work
   for very little gain.  I could have just placed the centers for all 90
   angles manually, but I found that for some even-sized holes where one of
   two locations both seem reasonable, it's hard to make the placement
   consistent when the hole positions are rotated for the remaining 3
   quadrants.  In contrast to manual placements, heuristic placements are
   always consistent.
*/

#include<assert.h>
#include<math.h>
#include<stdio.h>
#include<stdlib.h>
#include<string.h>
#include<png.h>

#define PI  3.14159265358979323846264338327950288419716939937510

/* Width and height of each arm sprite in pixels. */
#define SPRITE_SIZE  160

/* Length of arm from base hole to wrist hole in pixels. */
#define ARM_LENGTH  100

/* X and Y offset of center of base hole within each arm sprite, in pixels.

   We assume that all sprites are aligned such that the centers of their
   base holes are all at the same offset.                                   */
#define BASE_HOLE_OFFSET_X  31
#define BASE_HOLE_OFFSET_Y  192

/* Maximum number of pixels along the edge of hole.

   Our hole diameter is 12 in the SVG, so 4x that should be more than
   enough.  In practice, all hole perimeter sizes are less than 30
   because the inner hole is smaller than the diameter due to the
   thickness of the outline pixels.                                   */
#define MAX_HOLE_PERIMETER   48


typedef struct { int x, y; } XY;

/* Check if a particular pixel is opaque, return 1 if so.

   Since we are working with black and white images, anything that is not
   transparent is opaque,  We name this function "IsOpaque" as opposed to
   "IsNotTransparent" and test for alpha greater than zero instead of equal
   to 0xff because it reads better that way.                                */
static int IsOpaque(const png_image *image,
                    const png_bytep pixels,
                    int x, int y)
{
   assert(x >= 0);
   assert(x < (int)(image->width));
   assert(y >= 0);
   assert(y < (int)(image->height));
   return pixels[(y * image->width + x) * 2 + 1] > 0 ? 1 : 0;
}

/* Check if a particular opaque pixel contains both opaque and
   transparent neighbors in 4 directions.  Return nonzero if so. */
static int IsEdge(const png_image *image, const png_bytep pixels, int x, int y)
{
   int opaque_count;

   if( !IsOpaque(image, pixels, x, y) )
      return 0;

   opaque_count = IsOpaque(image, pixels, x - 1, y) +
                  IsOpaque(image, pixels, x + 1, y) +
                  IsOpaque(image, pixels, x, y - 1) +
                  IsOpaque(image, pixels, x, y + 1);
   return opaque_count > 0 && opaque_count < 4;
}

/* Check if a point been recorded recently, returns nonzero if so.  This is
   used to check if we are backtracking on an edge we have already traced.  */
static int IsRecent(const XY *perimeter, int perimeter_size, int x, int y)
{
   int i;

   for(i = 1; i < 3; i++)
   {
      if( perimeter_size - i <= 0 )
         return 0;
      if( perimeter[perimeter_size - i].x == x &&
          perimeter[perimeter_size - i].y == y )
      {
         return 1;
      }
   }
   return 0;
}

/* Collect coordinates of all edge pixels. */
static void GetEdgePixelList(const png_image *image,
                             const png_bytep pixels,
                             int sx, int sy,
                             XY *output,
                             int *count)
{
   int dx, dy, tx, ty, found;

   /* Find top edge of hole. */
   while( !IsOpaque(image, pixels, sx, sy) )
      sy--;
   output[0].x = sx;
   output[0].y = sy;
   *count = 1;

   /* Trace the edge pixels until we have completed a circle around the hole. */
   for(;;)
   {
      /* Find a neighbor of the current pixel that is an edge pixel. */
      found = 0;
      for(dx = -1; found == 0 && dx <= 1; dx++)
      {
         tx = sx + dx;
         for(dy = -1; dy <= 1; dy++)
         {
            if( dx == 0 && dy == 0 )
               continue;
            ty = sy + dy;
            if( !IsEdge(image, pixels, tx, ty) )
               continue;

            /* Avoid tracing back to pixels we have already added. */
            if( IsRecent(output, *count, tx, ty) )
               continue;

            /* (tx, ty) is a new edge point. */
            found = 1;
            break;
         }
      }
      assert(found);

      /* Stop when we have completed a full circle. */
      if( tx == output[0].x && ty == output[0].y )
         break;

      /* Add point to list. */
      output[*count].x = tx;
      output[*count].y = ty;
      ++*count;
      assert(*count < MAX_HOLE_PERIMETER);

      /* Move on to next pixel. */
      sx = tx;
      sy = ty;
   }
}

/* Find offsets for a single hole. */
static XY FindHoleOffset(const png_image *image, const png_bytep pixels, int a)
{
   XY perimeter[MAX_HOLE_PERIMETER], r;
   int perimeter_size, min_x, min_y, max_x, max_y, i;

   /* Start with the estimated center location. */
   int cx = (int)(ARM_LENGTH * cos(a * PI / 180.0)) + BASE_HOLE_OFFSET_X
          + a * SPRITE_SIZE;
   int cy = (int)(ARM_LENGTH * sin(a * PI / 180.0)) + BASE_HOLE_OFFSET_Y;

   /* Gather perimeter points. */
   GetEdgePixelList(image, pixels, cx, cy, perimeter, &perimeter_size);

   /* Find the extent of the perimeter. */
   min_x = max_x = cx;
   min_y = max_y = cy;
   for(i = 0; i < perimeter_size; i++)
   {
      if( min_x > perimeter[i].x ) min_x = perimeter[i].x;
      if( max_x < perimeter[i].x ) max_x = perimeter[i].x;
      if( min_y > perimeter[i].y ) min_y = perimeter[i].y;
      if( max_y < perimeter[i].y ) max_y = perimeter[i].y;
   }

   /* Make wrist center the center of the extents.

      This turns out to be the most reasonable placement heuristic.
      Other things we have tried include:

      - Flood fill the hole and get an average of all pixels in that hole.
        This is intended to find the centroid of the hole, but the end
        result appears to weigh more heavily toward narrow ends of holes,
        as opposed to the visual center.

      - Take the average of all pixels that are within one pixel of
        extent.  This is meant to smooth out edges that stick out with
        a single pixel notch, but has a tendency to bias pixels toward
        one end of the hole that looks more flat than the other.
   */
   r.x = (max_x + min_x) / 2;
   r.y = (max_y + min_y) / 2;

   /* Convert from screen coordinates to relative offset. */
   r.x -= BASE_HOLE_OFFSET_X + a * SPRITE_SIZE;
   r.y -= BASE_HOLE_OFFSET_Y;
   return r;
}

int main(int argc, char **argv)
{
   png_image image;
   png_bytep pixels;
   XY offsets[360];
   int a;

   if( argc != 2 )
      return printf("%s {input.png} > {output.lua}\n", *argv);

   /* Load input image as grayscale plus alpha. */
   memset(&image, 0, sizeof(image));
   image.version = PNG_IMAGE_VERSION;
   if( !png_image_begin_read_from_file(&image, argv[1]) )
      return printf("Error reading %s\n", argv[1]);
   image.format = PNG_FORMAT_GA;
   assert(image.width >= SPRITE_SIZE * 90);
   assert(image.height >= SPRITE_SIZE);
   pixels = (png_bytep)malloc(PNG_IMAGE_SIZE(image));
   if( pixels == NULL )
      return puts("Out of memory");
   if( !png_image_finish_read(&image, NULL, pixels, 0, NULL) )
      return printf("Error loading %s\n", argv[1]);

   /* Find hole offsets for the first 90 degrees. */
   for(a = 0; a < 90; a++)
      offsets[a] = FindHoleOffset(&image, pixels, a);
   free(pixels);

   /* Complete the table for all remaining 270 degrees. */
   for(a = 90; a < 180; a++)
   {
      offsets[a].x = -offsets[a - 90].y;
      offsets[a].y = offsets[a - 90].x;
   }
   for(a = 180; a < 360; a++)
   {
      offsets[a].x = -offsets[a - 180].x;
      offsets[a].y = -offsets[a - 180].y;
   }

   /* Output table to stdout. */
   puts("arm = arm or {}\n"
        "arm.wrist_offsets =\n{");
   for(a = 0; a < 360; a++)
      printf("\t[%d] = {%d, %d},\n", a, offsets[a].x, offsets[a].y);
   puts("}");
   return 0;
}
