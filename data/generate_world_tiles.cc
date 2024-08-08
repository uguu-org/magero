// Process PNG bitmaps and generate image table with Lua index.
//
// Usage:
//
//   ./generate_world_tiles {output.lua} {output.png} [input.png...]
//
// If input filename contains "metadata" as a substring, it's interpreted as
// an image that specifies metadata (collision and mutability statuses),
// otherwise it's interpreted as strictly image data.

#include<assert.h>
#include<png.h>
#include<stdio.h>
#include<stdlib.h>
#include<string.h>

#include<iostream>
#include<map>
#include<unordered_map>
#include<sstream>
#include<string>
#include<string_view>
#include<vector>

namespace {

// Width and height of world tiles (pixels).
static constexpr int kTileSize = 32;

// Number of tiles per row in output image table.
//
// This mostly doesn't matter since we address the output tiles using the
// 1D index rather than the 2D coordinates, but current setting allows the
// output image table to fit 1920 screen width, which makes debugging easier.
static constexpr int kTilesPerRow = 60;

// Maximum number of collectible tiles in world map.  This limit is set by how
// many items can be displayed at once.
static constexpr int kMaxCollectibleObstacles = 12 * 7;

// Maximum number of tiles.  This limit is enforced by pdc, which will output
// an error message like this if we got too many tiles:
// error: Image table <name>.png is too big, must have fewer than 32,768 images
//
// We won't actually get anywhere near this, because we would run out of
// memory first.  But having this limit does mean that we only need 16 bits
// to store tile indices.
static constexpr int kMaxTileCount = 32767;

// Special index for blank tile.
// https://devforum.play.date/t/using-transparent-images-as-tiles-on-tilemap-lead-to-smearing-effect/9851
static constexpr int kBlankTile = -1;

// Collision bitmasks for metadata tiles.  The names refers to the one
// corner that is not occupied.  Alternatively, think of it as the
// direction of the normal vector on the collision surface.  For
// example, kCollisionUpLeft means the upper left corner of the cell
// is empty, and normal vector points toward upper left.
static constexpr int kCollisionMask = 0x07;
static constexpr int kCollisionNone = 0x00;
static constexpr int kCollisionSquare = 0x01;
static constexpr int kCollisionUpLeft = 0x02;
static constexpr int kCollisionUpRight = 0x03;
static constexpr int kCollisionDownLeft = 0x04;
static constexpr int kCollisionDownRight = 0x05;

// Mountability bitmasks for metadata tiles.  The bits refer to the
// direction of the normal vector.  For example, a kCollisionUpRight tile
// might have a bitmask of "kMountUp|kMountRight", if it were mountable.
// Square collision tiles may be mountable on two sides, while triangular
// collision tiles are only mountable on one side.
//
// Note that we don't get a one-sided mountable horizontal or vertical wall
// with a series of triangle tiles.  If we line up 3 triangle tiles such
// that it's jaggy on one side and flat on the other side, the flat side is
// still not mountable.  This is because the axis-aligned sides of triangle
// tiles interact poorly with ball physics, so we would rather not expose
// those sides.
//
// To make a surface unmountable, the best practice is to add some collision
// tile in front of it, and annotate that tile with kGhostCollisionTile.
// This basically creates a "spike" in the surface that obstructs mounting.
static constexpr int kMountUp = 0x10;
static constexpr int kMountDown = 0x20;
static constexpr int kMountLeft = 0x40;
static constexpr int kMountRight = 0x80;
static constexpr int kMountMask =
   kMountUp | kMountDown | kMountLeft | kMountRight;

// kBreakableTile are mutable collision tiles.  These tiles are
// not mountable.
//
// We don't want these to be mountable since they create potentially
// non-returnable paths -- if there are some locations that are only
// reachable via breakable tiles, but those breakable tiles are later
// removed, player would be stuck.  To avoid that happening, only
// permanent tiles are eligible as mount locations.
static constexpr int kBreakableTile = 0x08;

// kGhostCollisionTile are used only internally within this tool.  During
// loading time, these tiles get the same treatment as regular collision
// tiles in terms of setting mount and collection approach directions, but
// any tile tagged with kGhostCollisionTile will have their collision bits
// zeroed at output time.
//
// This enables tiles that are collision-free that are passable by the robot
// arm, but are nonetheless mountable.  This is useful for certain secret
// passages.
static constexpr int kGhostCollisionTile = 0x4000;

// Bitmasks for mutable tiles.  These are always next a single kCollisionSquare
// tile, which determines the approach direction for removing the obstacle.
// The names refer to the direction of the normal vector.  For example,
// kCollectibleTileRight means there is a kCollisionSquare to the left of the
// obstacle, and player needs to approach from the right side (hand facing
// left) to remove the obstacle.
//
// These are treated like kCollisionNone for collision purposes, and are not
// mountable.
static constexpr int kCollectibleTileUp = 0x100;
static constexpr int kCollectibleTileDown = 0x200;
static constexpr int kCollectibleTileLeft = 0x400;
static constexpr int kCollectibleTileRight = 0x800;

// Bitmasks for chain reaction tiles, to support four types of interactions:
//
//   kChainReaction | (collision bits) =
//
//      Hitting these tiles causes foreground tiles to be removed, and also
//      propagate the change to neighboring kChainReaction tiles.  Underlying
//      collision mask is preserved, so if the tile wasn't passable before,
//      it's still not passable.
//
//      If the tile had zero collision bits, the chain reaction can be
//      triggered by having the hand pass through the tile.
//
//   kChainReaction | kBreakableTile | (collision bits) =
//
//      Hitting these tiles directly have no effect, but if a neighboring
//      kChainReaction is removed, that change will propagate to this tile,
//      such that the foreground tile is removed and all collision bits will
//      be cleared.  The change will propagate to neighboring tiles.
//
//      If collision bits were previously zero, they will remain at zero.
//      This allows kChainReaction|kBreakableTile combination to encode
//      non-triggering chain reaction tiles.
//
//   kTerminalReaction | (collision bits) =
//
//      Hitting these tiles directly have no effect, but if a neighboring
//      kChainReaction is removed, that change will propagate to this tile,
//      such that foreground tile is removed.  Existing collision bits are
//      preserved, and the change does not propagate to neighboring tiles.
//
//      This bit is similar to kChainReaction, except it can't be used to
//      start a reaction, and does not propagate changes to neighboring tiles.
//      The effect is terminal and does not continue a chain, hence the name.
//      The reason why we have this tile is to control the sequence in how the
//      foreground tile are removed.
//
//   kTerminalReaction | kBreakableTile | (nonzero collision bits) =
//
//      Same as kTerminalReaction, but also removes collision bits.
//
// These bits allow us to implement single-use switch that requires player
// to hit or pass through one tile in order to gain access to another tile.
//
// During gameplay, chain reaction tiles will be updated with breadth-first
// expansion, and viewport will be adjusted to try to follow the updated tiles.
// It works best if the tiles form a narrow strip as opposed to a large patch.
// For large patches, kTerminalReaction tiles are used to finetune viewport
// movement by tweaking the tile removal order.
static constexpr int kChainReaction = 0x1000;
static constexpr int kTerminalReaction = 0x2000;
static_assert((kChainReaction & kTerminalReaction) == 0);

// Union of all collectible tile bits.  After all collision tiles have been
// determined, we will do a second pass to select a single approach
// direction for each collectible tile.
static constexpr int kCollectibleTileMask =
   kCollectibleTileUp | kCollectibleTileDown |
   kCollectibleTileLeft | kCollectibleTileRight;

// Check for disjoint bits.
static_assert((kCollisionMask & kMountMask) == 0);
static_assert((kCollisionMask & kCollectibleTileMask) == 0);
static_assert((kCollisionMask & kGhostCollisionTile) == 0);
static_assert((kMountMask & kCollectibleTileMask) == 0);
static_assert((kMountMask & kGhostCollisionTile) == 0);
static_assert(((kChainReaction|kTerminalReaction) & kCollisionMask) == 0);
static_assert(((kChainReaction|kTerminalReaction) & kMountMask) == 0);
static_assert(((kChainReaction|kTerminalReaction) & kCollectibleTileMask) == 0);
static_assert(((kChainReaction|kTerminalReaction) & kGhostCollisionTile) == 0);
static_assert((kBreakableTile & kCollisionMask) == 0);
static_assert((kBreakableTile & kMountMask) == 0);
static_assert((kBreakableTile & kCollectibleTileMask) == 0);
static_assert((kBreakableTile & kGhostCollisionTile) == 0);
static_assert(((kChainReaction|kTerminalReaction) & kBreakableTile) == 0);

// Wrapper for a single input image.
struct InputImage
{
   InputImage() = default;
   ~InputImage() { free(pixels); }

   const char *filename = nullptr;
   png_image image;
   png_bytep pixels = nullptr;
};

// Wrapper around a single image region.
template<int bytes_per_pixel>
struct GenericBlock
{
   using Pixels = std::vector<std::string_view>;

   // Convenience function to return the selected pixels.
   Pixels GetPixels() const;

   // Convenience function to return a single pixel within the block,
   // packed in little-endian order: least significant byte is first
   // component, most significant byte is alpha.
   uint32_t GetPixel(int bx, int by) const;

   // Source image.
   const InputImage *source;

   // Tile offset.
   int x, y;
};

// Convenience function to return the selected pixels.
template<int bpp>
typename GenericBlock<bpp>::Pixels GenericBlock<bpp>::GetPixels() const
{
   std::vector<std::string_view> pixels;
   pixels.reserve(kTileSize);
   const int row_size = source->image.width * bpp;
   const char *source_pixels = reinterpret_cast<const char*>(
      source->pixels + y * row_size + x * bpp);
   for(int i = 0; i < kTileSize; i++)
   {
      pixels.push_back(std::string_view(source_pixels, kTileSize * bpp));
      source_pixels += row_size;
   }
   return pixels;
}

template<int bpp>
uint32_t GenericBlock<bpp>::GetPixel(int bx, int by) const
{
   const int row_size = source->image.width * bpp;
   const uint8_t *source_pixel = reinterpret_cast<const uint8_t*>(
      source->pixels + (y + by) * row_size + (x + bx) * bpp);

   uint32_t p = 0;
   for(int i = 0; i < bpp; i++, source_pixel++)
      p |= *source_pixel << (i * 8);
   return p;
}

using TileBlock = GenericBlock<PNG_IMAGE_SAMPLE_SIZE(PNG_FORMAT_GA)>;
using MetadataBlock = GenericBlock<PNG_IMAGE_SAMPLE_SIZE(PNG_FORMAT_RGBA)>;

// Hash function for tile pixels.
struct HashTileBlock
{
   size_t operator()(const TileBlock &t) const
   {
      const std::vector<std::string_view> pixels = t.GetPixels();
      size_t seed = 0;
      for(const std::string_view &row : pixels)
      {
         // hash_combine from boost 1.55.0
         seed ^= hasher(row) + 0x9e3779b9 + (seed << 6) + (seed >> 2);
      }
      return seed;
   }

   std::hash<std::string_view> hasher;
};

// Equivalence function for tile pixels.
struct EqTileBlock
{
   bool operator()(const TileBlock &a, const TileBlock &b) const
   {
      return a.GetPixels() == b.GetPixels();
   }
};

// Unique tiles to 0-based tile index.
using TileBlockSet =
   std::unordered_map<TileBlock, int, HashTileBlock, EqTileBlock>;

// List of tile indices for a single row.
using TileRow = std::vector<int>;

// Matrix of tile indices.
using TileMap = std::vector<TileRow>;

// Map from layer name to tile data.
//
// For image layer, output contains 1-based tile indices.
// For metadata layer, output contains bitmasks.
using WorldTiles = std::map<std::string, TileMap>;

// List of world coordinates.
using PositionList = std::vector<std::pair<int, int>>;

//////////////////////////////////////////////////////////////////////

// Check if an input PNG specifies tile data or general metadata.
static bool IsMetadataFile(std::string_view filename)
{
   return filename.find("metadata") != std::string_view::npos;
}

// Generate layer name based on input file name.
//
// We assume that getting the base name of the file and stripping the
// extension will make good names, but we don't actually check.
static std::string GenerateLayerName(std::string filename)
{
   const std::string::size_type d = filename.rfind('.');
   if( d != std::string::npos )
      filename.erase(d);

   const std::string::size_type s = filename.rfind('/');
   if( s != std::string::npos )
      filename.erase(0, s + 1);
   return filename;
}

// Allocate output entries based on input image size.
static void ResizeOutput(const InputImage &input, TileMap *output)
{
   const int width = input.image.width / kTileSize;
   const int height = input.image.height / kTileSize;
   output->resize(height);
   for(int y = 0; y < height; y++)
      (*output)[y].resize(width);
}

//////////////////////////////////////////////////////////////////////

// Check if all pixels are transparent.
static bool IsBlank(const TileBlock::Pixels &pixels)
{
   static constexpr int kBytesPerPixel = PNG_IMAGE_SAMPLE_SIZE(PNG_FORMAT_GA);
   static_assert(kBytesPerPixel == 2);
   for(const std::string_view &row : pixels)
   {
      for(int x = 1; x < static_cast<int>(row.size()); x += kBytesPerPixel)
      {
         if( row[x] != 0 )
            return false;
      }
   }
   return true;
}

// Process tile images.  Basically assigns indices to unique tiles and record
// those indices in output.
static void ProcessImage(const InputImage &input,
                         TileBlockSet *unique_tiles,
                         TileMap *output)
{
   assert(input.image.format == PNG_FORMAT_GA);

   ResizeOutput(input, output);
   TileBlock tile;
   tile.source = &input;
   for(int y = 0; y < static_cast<int>(input.image.height); y += kTileSize)
   {
      tile.y = y;
      for(int x = 0; x < static_cast<int>(input.image.width); x += kTileSize)
      {
         tile.x = x;
         const TileBlock::Pixels pixels = tile.GetPixels();
         if( IsBlank(pixels) )
         {
            (*output)[y / kTileSize][x / kTileSize] = kBlankTile;
            continue;
         }

         const int tile_index = unique_tiles->size();
         auto p = unique_tiles->insert(std::make_pair(tile, tile_index));
         (*output)[y / kTileSize][x / kTileSize] = p.first->second + 1;
      }
   }
}

//////////////////////////////////////////////////////////////////////

// Check if a pixel within a block is opaque.
static bool IsOpaque(const MetadataBlock &block, int bx, int by)
{
   return (block.GetPixel(bx, by) & 0xff000000) != 0;
}

// The next few functions check the pixel colors to assign the per-tile
// annotations.  Summary:
//
//   black = no extra annotations.
//   red = IsBreakable
//   green = IsCollectible
//   blue = IsStartingPosition
//   yellow = IsThrowableTile
//   cyan = IsChainReactionTrigger
//   magenta = IsChainReactionEffect
//
// Note that we have used up all high intensity color bits, except white.
// We don't want white annotations because those look identical to
// transparent pixels (since we edit with a white background).

// Check if a pixel marks a breakable obstacle (red).
static bool IsBreakable(const MetadataBlock &block, int bx, int by)
{
   const uint32_t pixel = block.GetPixel(bx, by);

   // As a side note, clang 6.0.0 for x86-64 is able to optimize the following
   // to just 3 instructions (basically "(pixel & 0x808080) == 0x80"), while
   // gcc 13.2 still takes 10 instructions.  This whole tool is not performance
   // critical so it doesn't matter either way, it's just a curiosity of mine
   // to see how compilers fares with bit twiddling expressions.
   return (pixel & 0x0000ff) > 0x00007f &&  // +R
          (pixel & 0x00ff00) < 0x008000 &&
          (pixel & 0xff0000) < 0x800000;
}

// Check if a pixel marks an collectible tile (green).
static bool IsCollectible(const MetadataBlock &block, int bx, int by)
{
   const uint32_t pixel = block.GetPixel(bx, by);
   return (pixel & 0x0000ff) < 0x000080 &&
          (pixel & 0x00ff00) > 0x007f00 &&  // +G
          (pixel & 0xff0000) < 0x800000;
}

// Check if a pixel marks a starting position or teleport station (blue).
static bool IsStartingPosition(const MetadataBlock &block, int bx, int by)
{
   const uint32_t pixel = block.GetPixel(bx, by);
   return (pixel & 0x0000ff) < 0x000080 &&
          (pixel & 0x00ff00) < 0x008000 &&
          (pixel & 0xff0000) > 0x7f0000;    // +B
}

// Check if a pixel marks initial position of a throwable tile (yellow).
static bool IsThrowableTile(const MetadataBlock &block, int bx, int by)
{
   const uint32_t pixel = block.GetPixel(bx, by);
   return (pixel & 0x0000ff) > 0x00007f &&  // +R
          (pixel & 0x00ff00) > 0x007f00 &&  // +G
          (pixel & 0xff0000) < 0x800000;
}

// Check if pixel marks a trigger tile of a chain reaction (cyan).
static bool IsChainReactionTrigger(const MetadataBlock &block, int bx, int by)
{
   const uint32_t pixel = block.GetPixel(bx, by);
   return (pixel & 0x0000ff) < 0x000080 &&
          (pixel & 0x00ff00) > 0x007f00 &&  // +G
          (pixel & 0xff0000) > 0x7f0000;    // +B
}

// Check if pixel marks a reaction tile of a chain reaction (magenta).
static bool IsChainReactionEffect(const MetadataBlock &block, int bx, int by)
{
   const uint32_t pixel = block.GetPixel(bx, by);
   return (pixel & 0x0000ff) > 0x00007f &&  // +R
          (pixel & 0x00ff00) < 0x008000 &&
          (pixel & 0xff0000) > 0x7f0000;    // +B
}

// Process annotation bits for each tile.
//
// "output" will be updated with collision bits and other annotations.
// "start" will be updated with a list of starting positions.
// "teleport" will be updated with a list of teleport stations.
// "throwables" will be updated with list of initial ball positions.
static void ProcessAnnotations(const InputImage &input,
                               TileMap *output,
                               PositionList *start,
                               PositionList *teleport,
                               PositionList *throwables)
{
   // Collision mask is generated by sampling 4 different points within
   // each cell:
   //
   // +-------+
   // |   U   |
   // | L   R |
   // |   D   |
   // +-------+
   //
   // If all 4 points are opaque, we have a square collision tile.  If
   // exactly 2 of the points are opaque, we have either a triangular
   // collision tile or some unsupported combination.  The 45 degree
   // triangles allow a bit more granularity in specifying world
   // boundaries.  Having more bits to support other oblique would be
   // possible, but takes a more code to handle them and more bits to store
   // that metadata, so we will settle for square plus four triangles.
   //
   // Offset for those 4 points are defined here.  In theory, we should be
   // testing the points that are right on the edge of each grid cell (i.e.
   // kMargin should be zero), but here we use a margin of 2 to account for
   // potential grid snapping and antialiasing issues.
   static constexpr int kMargin = 2;
   static constexpr int kLPointX = kMargin;
   static constexpr int kLPointY = kTileSize / 2;
   static constexpr int kRPointX = kTileSize - 1 - kMargin;
   static constexpr int kRPointY = kTileSize / 2;
   static constexpr int kUPointX = kTileSize / 2;
   static constexpr int kUPointY = kMargin;
   static constexpr int kDPointX = kTileSize / 2;
   static constexpr int kDPointY = kTileSize - 1 - kMargin;

   // Offset to tile center, used for checking obstacle annotations.
   static constexpr int kCPointX = kTileSize / 2;
   static constexpr int kCPointY = kTileSize / 2;

   // Offset to off-centered pixel for checking additional annotations.
   static constexpr int kOPointX = kTileSize / 4 + 1;
   static constexpr int kOPointY = kTileSize / 4 + 1;
   static_assert(kOPointX != kMargin);

   MetadataBlock tile;
   tile.source = &input;
   for(int y = 0; y < static_cast<int>(input.image.height); y += kTileSize)
   {
      tile.y = y;
      for(int x = 0; x < static_cast<int>(input.image.width); x += kTileSize)
      {
         tile.x = x;
         const int collision_bits =
            (IsOpaque(tile, kUPointX, kUPointY) ? 1 : 0) |
            (IsOpaque(tile, kDPointX, kDPointY) ? 2 : 0) |
            (IsOpaque(tile, kLPointX, kLPointY) ? 4 : 0) |
            (IsOpaque(tile, kRPointX, kRPointY) ? 8 : 0);
         int tile_bits = 0;
         switch( collision_bits )
         {
            case 0:
               // Fully passable tile.
               tile_bits = kCollisionNone;
               break;
            case 15:
               // UDLR: Square obstacle occupying all four corners.
               tile_bits = kCollisionSquare;
               break;
            case 5:
               // UL: Triangle, lower right corner is passable.
               tile_bits = kCollisionDownRight;
               break;
            case 9:
               // UR: Triangle, lower left corner is passable.
               tile_bits = kCollisionDownLeft;
               break;
            case 6:
               // DL: Triangle, upper right corner is passable.
               tile_bits = kCollisionUpRight;
               break;
            case 10:
               // DR: Triangle, upper left corner is passable.
               tile_bits = kCollisionUpLeft;
               break;
            default:
               // Unexpected combination of bits.  These can happen naturally
               // due to metadata markings, so we silently ignore them.
               break;
         }

         // If the right-facing face contains a blue pixel, the center of
         // that tile face would be added to the starting position list.
         //
         // Only the right-facing face is tested because the arm always
         // starts in the same orientation.
         if( IsStartingPosition(tile, kRPointX, kRPointY) )
         {
            // Note that the starting position is at the rightmost edge of the
            // current tile (that's the -1 bit).  We choose this convention
            // because it looks slightly nicer, with the tips of the robot
            // fingers overlapping the wall by one pixel when mounted.
            //
            // If we don't have the -1, i.e. if we place the mount points at
            // the leftmost edge of the next tile, the fingers will still be
            // touching the wall, but because the fingertips are rounded, it
            // appears to have less contact and doesn't feel as sturdy a grip
            // compared to the -1 placement.
            start->push_back(std::make_pair(x + kTileSize - 1,
                                            y + kTileSize / 2));
         }

         // Teleport stations are similar to starting positions, except the
         // annotation is on the top face instead of the right face.
         if( IsStartingPosition(tile, kUPointX, kUPointY) )
         {
            // Teleport station position is the center of the top edge of
            // the containing tile.  This is the same as the coordinate
            // used for top-facing mounts.
            teleport->push_back(std::make_pair(x + kTileSize / 2, y));
         }

         // Check other annotations.  Annotations are marked either with a
         // circle or a square at the center of the grid cells.  We check
         // the center of the grid cells first to detect the annotation
         // color, and then do a secondary check at an off-center corner to
         // detect the shape.
         //
         // Our annotation system essentially uses a single color plus one
         // optional position bit to encode a few tile types.  We could have
         // used a different system that would allow more tile types to be
         // encoded, such as dividing a cell into quadrants and allow each
         // quadrant to take on a different color.  More tile types would be
         // useful from a level design point of view, but not as ergonomic
         // from a level editing point of view.  We kept the current system
         // for ergonomic reasons, and also because we have gotten fairly
         // good at working around the constraint of limited tile types.
         if( IsBreakable(tile, kCPointX, kCPointY) )
         {
            if( IsBreakable(tile, kOPointX, kOPointY) )
               tile_bits |= kGhostCollisionTile;
            else
               tile_bits |= kBreakableTile;
         }
         else if( IsCollectible(tile, kCPointX, kCPointY) )
         {
            if( IsCollectible(tile, kOPointX, kOPointY) )
               tile_bits |= kCollectibleTileMask | kTerminalReaction;
            else
               tile_bits |= kCollectibleTileMask;
         }
         else if( IsThrowableTile(tile, kCPointX, kCPointY) )
         {
            throwables->push_back(std::make_pair(x + kTileSize / 2,
                                                 y + kTileSize / 2));
         }
         else if( IsChainReactionTrigger(tile, kCPointX, kCPointY) )
         {
            if( IsChainReactionTrigger(tile, kOPointX, kOPointY) )
               tile_bits |= kTerminalReaction;
            else
               tile_bits |= kChainReaction;
         }
         else if( IsChainReactionEffect(tile, kCPointX, kCPointY) )
         {
            if( IsChainReactionEffect(tile, kOPointX, kOPointY) )
               tile_bits |= kTerminalReaction | kBreakableTile;
            else
               tile_bits |= kChainReaction | kBreakableTile;
         }

         (*output)[y / kTileSize][x / kTileSize] = tile_bits;
      }
   }
}

// Check if a particular grid tile is empty or breakable.
static bool IsEmptyOrBreakable(const TileMap &tile_map,
                               int grid_width, int grid_height,
                               int x, int y)
{
   if( x < 0 || x >= grid_width || y < 0 || y >= grid_height )
      return false;

   const int tile_bits = tile_map[y][x];
   return (tile_bits & kCollisionMask) == kCollisionNone ||
          (tile_bits & kBreakableTile) != 0;
}

// Assign mount attributes given neighbor offsets.
//  mount_mask = mask to be added to current cell.
//  normal_dx, normal_dy = direction of normal vector.  Note that Y value for
//                         grid coordinates increases downwards.
//  grid_width, grid_height = grid dimensions.
//  x, y = coordinate of current cell.
//  output = grid to modify.
static void AssignMountAttributes(
   int mount_mask,
   int normal_dx, int normal_dy,
   int grid_width, int grid_height,
   int x, int y,
   TileMap *output)
{
   #define NEIGHBOR_COLLISION(dx, dy) \
      (                                                         \
         x + (dx) >= 0 && x + (dx) < grid_width &&              \
         y + (dy) >= 0 && y + (dy) < grid_height                \
            ? ((*output)[y + (dy)][x + (dx)]) & kCollisionMask  \
            : -1                                                \
      )

   #define IS_EMPTY_OR_BREAKABLE(dx, dy) \
      IsEmptyOrBreakable(*output, grid_width, grid_height, x + (dx), y + (dy))

   #define HAS_ENOUGH_CLEARANCE(base_x, base_y) \
      ( IS_EMPTY_OR_BREAKABLE((base_x) + normal_dx,      \
                              (base_y) + normal_dy) &&   \
        IS_EMPTY_OR_BREAKABLE((base_x) + normal_dx * 2,  \
                              (base_y) + normal_dy * 2) )

   // A tile will need two empty spaces in front to be mountable, due
   // to the size of the hand.
   if( !IS_EMPTY_OR_BREAKABLE(normal_dx, normal_dy) ||
       !IS_EMPTY_OR_BREAKABLE(normal_dx * 2, normal_dy * 2) )
   {
      return;
   }

   // Compute vectors to adjacent neighbors by rotating normal vector.
   const int post_x = normal_dy;
   const int post_y = -normal_dx;
   const int pre_x = -normal_dy;
   const int pre_y = normal_dx;

   // Current tile is mountable if both of the following conditions are true:
   // - Adjacent tiles are of the same type as the current tile.
   // - The tiles in front of those adjacent tiles are empty.
   const int c = (*output)[y][x] & kCollisionMask;
   if( NEIGHBOR_COLLISION(pre_x, pre_y) == c &&
       NEIGHBOR_COLLISION(post_x, post_y) == c &&
       HAS_ENOUGH_CLEARANCE(pre_x, pre_y) &&
       HAS_ENOUGH_CLEARANCE(post_x, post_y) )
   {
      if( normal_dx == 0 || normal_dy == 0 )
      {
         // For horizontal mounts, that's all the checks we need.
         (*output)[y][x] |= mount_mask;
      }
      else
      {
         // For diagonal mounts, we will also need to check the tiles
         // that are not directly on the diagonal lines.  For example:
         //
         //          [0][1]
         //       [0][1][0][1]
         //    [0][1][0][1][#]
         //    [1][0][1][X]
         //       [1][#]
         //
         // If the mount point candidate is at [X], the [0] tiles are
         // already checked by the condition above, but we still need
         // to check the [1] tiles.  This is done by getting the two
         // adjacent tiles behind the pre and post neighbors, then
         // checking the two tiles by stepping forward with normal vector.
         //
         // normal =       (-1, 1)    (1, 1)     (-1, -1)   (1, -1)
         //
         // offset tiles = [##][kx]   [kx][##]   [ky]           [ky]
         //                [ky]           [ky]   [##][kx]   [kx][##]
         const int ky = -normal_dy;
         const int kx = -normal_dx;
         if( HAS_ENOUGH_CLEARANCE(pre_x + kx, pre_y) &&
             HAS_ENOUGH_CLEARANCE(pre_x,      pre_y + ky) &&
             HAS_ENOUGH_CLEARANCE(post_x + kx, post_y) &&
             HAS_ENOUGH_CLEARANCE(post_x,      post_y + ky) )
         {
            (*output)[y][x] |= mount_mask;
         }
      }
   }

   // Note that we can also do an extra check here to detect if the current
   // tile forms the vertex of a convex corner, by checking if either of the
   // pre/post neighbors are empty.  The motivation for detecting convex
   // corners is to limit certain collision checks to only those tiles.
   //
   // This has to do with the shape of the arm, where the joints are larger
   // than the limbs connecting them, such that if the walls are flat or
   // concave, we don't need to check collision with the limbs because the
   // joints are guarantee to collide first.  This is not the case with
   // convex walls where the pointy bit might fall between two joints, so we
   // will need to also check collisions against the limbs for those tiles.
   //
   // However, because the actual collision test for the limbs is relatively
   // cheap, adding an extra bitmask test ends up being just extra work, so
   // we no longer flag any corners as special.

   #undef HAS_ENOUGH_CLEARANCE
   #undef IS_EMPTY_OR_BREAKABLE
   #undef NEIGHBOR_COLLISION
}

// Detect mount points for each tile.
static void DetectMountPoints(int grid_width, int grid_height, TileMap *output)
{
   for(int y = 0; y < grid_height; y++)
   {
      for(int x = 0; x < grid_width; x++)
      {
         // A mountable tile must not also be breakable.
         if( (*output)[y][x] & kBreakableTile )
            continue;

         switch( (*output)[y][x] & kCollisionMask )
         {
            case kCollisionNone:
               // No extra attributes to add for empty tiles.
               break;
            case kCollisionSquare:
               AssignMountAttributes(kMountUp, 0, -1,
                                     grid_width, grid_height, x, y, output);
               AssignMountAttributes(kMountDown, 0, 1,
                                     grid_width, grid_height, x, y, output);
               AssignMountAttributes(kMountLeft, -1, 0,
                                     grid_width, grid_height, x, y, output);
               AssignMountAttributes(kMountRight, 1, 0,
                                     grid_width, grid_height, x, y, output);
               break;
            case kCollisionUpLeft:
               AssignMountAttributes(kMountUp | kMountLeft, -1, -1,
                                     grid_width, grid_height, x, y, output);
               break;
            case kCollisionUpRight:
               AssignMountAttributes(kMountUp | kMountRight, 1, -1,
                                     grid_width, grid_height, x, y, output);
               break;
            case kCollisionDownLeft:
               AssignMountAttributes(kMountDown | kMountLeft, -1, 1,
                                     grid_width, grid_height, x, y, output);
               break;
            case kCollisionDownRight:
               AssignMountAttributes(kMountDown | kMountRight, 1, 1,
                                     grid_width, grid_height, x, y, output);
               break;
            default:
               // Unreachable.
               assert(false);
               break;
         }
      }
   }
}

// Adjust obstacle directionality bits.  Returns true if all obstacles
// are valid.
static bool AdjustObstacles(int grid_width, int grid_height, TileMap *output)
{
   #define METADATA_BITS(dx, dy)  ((*output)[y + (dy)][x + (dx)])
   #define IS_BREAKABLE(dx, dy) \
      ((METADATA_BITS(dx, dy) & kBreakableTile) != 0)
   #define IS_EMPTY_OR_BREAKABLE(dx, dy)  \
      (((METADATA_BITS(dx, dy) & kCollisionMask) == kCollisionNone) ||  \
       IS_BREAKABLE(dx, dy))
   #define IS_UNBREAKABLE_SQUARE(dx, dy)  \
      ((METADATA_BITS(dx, dy) & (kBreakableTile | kCollisionMask)) == \
       kCollisionSquare)

   bool success_status = true;
   int collectible_obstacles = 0;
   for(int y = 0; y < grid_height; y++)
   {
      for(int x = 0; x < grid_width; x++)
      {
         int *tile = &((*output)[y][x]);

         // Check that a breakable tile has some collision bits attached.
         // A breakable tile without collision bits would be indestructible.
         //
         // One exception to this would be breakable tiles that are part of
         // a chain reaction, in which case the breakable tile is actually
         // being used to indicate non-triggerable and non-terminal chain
         // reaction tiles.
         if( (*tile & kBreakableTile) != 0 &&
             (*tile &
              (kCollisionMask | kChainReaction | kTerminalReaction)) == 0 )
         {
            printf("tile[%d][%d] (%d, %d): breakable tile needs collision\n",
                   y,
                   x,
                   x * kTileSize + kTileSize / 2,
                   y * kTileSize + kTileSize / 2);
            success_status = false;
         }

         // Remaining checks and adjustments only applies to collectible tiles.
         if( (*tile & kCollectibleTileMask) == 0 )
            continue;
         if( (*tile & ~(kCollectibleTileMask | kTerminalReaction)) != 0 )
         {
            printf("tile[%d][%d] (%d, %d): collectible tile "
                   "can not overlap other annotations\n",
                   y,
                   x,
                   x * kTileSize + kTileSize / 2,
                   y * kTileSize + kTileSize / 2);
            success_status = false;
            continue;
         }

         if( x == 0 || x == grid_width - 1 || y == 0 || y == grid_height - 1 )
         {
            printf("tile[%d][%d] (%d, %d): collectible tile "
                   "can not be placed near edge of map\n",
                   y,
                   x,
                   x * kTileSize + kTileSize / 2,
                   y * kTileSize + kTileSize / 2);
            success_status = false;
            continue;
         }

         // We require that collectible tiles be adjacent to exactly one wall
         // tile.  This is needed to set approach direction for removing the
         // collectible tile.  There are two ways of satisfying this condition:
         //
         // 1. Have the collectible attached to exactly one permanent wall
         //    tile, with the other 3 tiles being empty or breakable.  This
         //    allows collectibles to be surrounded by obstacles, such that
         //    the player must break them first to reach the collectible.
         //
         // 2. Have the collectible attached to a single breakable wall tile,
         //    with the other 3 tiles being empty.  The motivation here is to
         //    allow collectibles to be attached to any breakable walls at all,
         //    but we need to constrain the neighbor count to one to set
         //    approach direction for the collectible tile.
         const int empty_count = (IS_EMPTY_OR_BREAKABLE(-1, 0) ? 1 : 0) +
                                 (IS_EMPTY_OR_BREAKABLE(+1, 0) ? 1 : 0) +
                                 (IS_EMPTY_OR_BREAKABLE(0, -1) ? 1 : 0) +
                                 (IS_EMPTY_OR_BREAKABLE(0, +1) ? 1 : 0);
         if( empty_count == 3 )
         {
            if( IS_UNBREAKABLE_SQUARE(0, +1) )
            {
               *tile &= ~kCollectibleTileMask;
               *tile |= kCollectibleTileUp;
            }
            else if( IS_UNBREAKABLE_SQUARE(0, -1) )
            {
               *tile &= ~kCollectibleTileMask;
               *tile |= kCollectibleTileDown;
            }
            else if( IS_UNBREAKABLE_SQUARE(+1, 0) )
            {
               *tile &= ~kCollectibleTileMask;
               *tile |= kCollectibleTileLeft;
            }
            else if( IS_UNBREAKABLE_SQUARE(-1, 0) )
            {
               *tile &= ~kCollectibleTileMask;
               *tile |= kCollectibleTileRight;
            }
            else
            {
               printf("tile[%d][%d] (%d, %d): collectible tile "
                      "must be adjacent to 1 square collision tile\n",
                      y,
                      x,
                      x * kTileSize + kTileSize / 2,
                      y * kTileSize + kTileSize / 2);
               success_status = false;
               continue;
            }
         }
         else if( empty_count == 4 )
         {
            if( IS_BREAKABLE(0, +1) &&
                !IS_BREAKABLE(0, -1) &&
                !IS_BREAKABLE(+1, 0) &&
                !IS_BREAKABLE(-1, 0) )
            {
               *tile &= ~kCollectibleTileMask;
               *tile |= kCollectibleTileUp;
            }
            else if( !IS_BREAKABLE(0, +1) &&
                     IS_BREAKABLE(0, -1) &&
                     !IS_BREAKABLE(+1, 0) &&
                     !IS_BREAKABLE(-1, 0) )
            {
               *tile &= ~kCollectibleTileMask;
               *tile |= kCollectibleTileDown;
            }
            else if( !IS_BREAKABLE(0, +1) &&
                     !IS_BREAKABLE(0, -1) &&
                     IS_BREAKABLE(+1, 0) &&
                     !IS_BREAKABLE(-1, 0) )
            {
               *tile &= ~kCollectibleTileMask;
               *tile |= kCollectibleTileLeft;
            }
            else if( !IS_BREAKABLE(0, +1) &&
                     !IS_BREAKABLE(0, -1) &&
                     !IS_BREAKABLE(+1, 0) &&
                     IS_BREAKABLE(-1, 0) )
            {
               *tile &= ~kCollectibleTileMask;
               *tile |= kCollectibleTileRight;
            }
            else
            {
               printf("tile[%d][%d] (%d, %d): collectible tile "
                      "must be adjacent to exactly 1 wall\n",
                      y,
                      x,
                      x * kTileSize + kTileSize / 2,
                      y * kTileSize + kTileSize / 2);
               success_status = false;
               continue;
            }
         }
         else
         {
            printf("tile[%d][%d] (%d, %d): collectible tile "
                   "must be surrounded by 3 empty tiles and 1 wall\n",
                   y,
                   x,
                   x * kTileSize + kTileSize / 2,
                   y * kTileSize + kTileSize / 2);
            success_status = false;
            continue;
         }

         collectible_obstacles++;
         if( collectible_obstacles > kMaxCollectibleObstacles )
         {
            printf("tile[%d][%d] (%d, %d): too many collectible tiles\n",
                   y,
                   x,
                   x * kTileSize + kTileSize / 2,
                   y * kTileSize + kTileSize / 2);
            success_status = false;
         }
      }
   }

   #undef IS_BREAKABLE
   #undef IS_EMPTY_OR_BREAKABLE
   #undef IS_UNBREAKABLE_SQUARE
   #undef METADATA_BITS
   return success_status;
}

// Verify that all starting points are mountable.  Returns true on success.
static bool CheckStartingPoints(const PositionList &start, const TileMap &tiles)
{
   bool success_status = true;
   for(const auto &[x, y] : start)
   {
      assert(x % kTileSize == kTileSize - 1);
      assert(y % kTileSize == kTileSize / 2);
      const int tile_x = x / kTileSize;
      const int tile_y = (y - kTileSize / 2) / kTileSize;
      assert(tile_y >= 0);
      assert(tile_y < static_cast<int>(tiles.size()));
      assert(tile_x >= 0);
      assert(tile_x < static_cast<int>(tiles[tile_y].size()));
      if( (tiles[tile_y][tile_x] & kMountMask) != kMountRight &&
          (tiles[tile_y][tile_x] & kMountMask) != (kMountLeft | kMountRight) )
      {
         printf("tile[%d][%d] does not support mounting at (%d,%d)\n",
                tile_y, tile_x, x, y);
         success_status = false;
      }
   }
   return success_status;
}

// Verify that all teleport stations are mountable.  Returns true on success.
static bool CheckTeleportPoints(const PositionList &start, const TileMap &tiles)
{
   bool success_status = true;
   for(const auto &[x, y] : start)
   {
      assert(x % kTileSize == kTileSize / 2);
      assert(y % kTileSize == 0);
      const int tile_x = (x - kTileSize / 2) / kTileSize;
      const int tile_y = y / kTileSize;
      assert(tile_y >= 0);
      assert(tile_y < static_cast<int>(tiles.size()));
      assert(tile_x >= 0);
      assert(tile_x < static_cast<int>(tiles[tile_y].size()));
      if( (tiles[tile_y][tile_x] & kMountMask) != kMountUp &&
          (tiles[tile_y][tile_x] & kMountMask) != (kMountUp | kMountDown) )
      {
         printf("tile[%d][%d] does not support mounting at (%d,%d)\n",
                tile_y, tile_x, x, y);
         success_status = false;
      }
   }
   return success_status;
}

// Verify that all terminal reaction tiles are adjacent to at least one
// chain reaction tile, returns true on success.
//
// Terminal reaction tiles need chain reaction neighbors, otherwise they will
// not be removed.
static bool CheckTerminalReactions(
   int grid_width, int grid_height, const TileMap &tiles)
{
   bool success_status = true;
   for(int y = 0; y < grid_height; y++)
   {
      for(int x = 0; x < grid_width; x++)
      {
         if( (tiles[y][x] & kTerminalReaction) != 0 )
         {
            const bool adjacent_to_chain_reaction =
               (y > 0 && (tiles[y - 1][x] & kChainReaction) != 0) ||
               (y < grid_height - 1 &&
                (tiles[y + 1][x] & kChainReaction) != 0) ||
               (x > 0 && (tiles[y][x - 1] & kChainReaction) != 0) ||
               (x < grid_width - 1 && (tiles[y][x + 1] & kChainReaction) != 0);
            if( !adjacent_to_chain_reaction )
            {
               printf("tile[%d][%d] (%d, %d): terminal reaction tile must be "
                      "adjacent to at least one chain reaction tile\n",
                      y,
                      x,
                      x * kTileSize + kTileSize / 2,
                      y * kTileSize + kTileSize / 2);
               success_status = false;
            }
         }
      }
   }
   return success_status;
}

// Remove collision bits for all ghost collision tiles.
static bool RemoveGhosts(int grid_width, int grid_height, TileMap *output)
{
   for(int y = 0; y < grid_height; y++)
   {
      for(int x = 0; x < grid_width; x++)
      {
         int *tile = &((*output)[y][x]);
         if( (*tile & kGhostCollisionTile) != 0 )
            *tile &= ~(kGhostCollisionTile | kCollisionMask);
      }
   }
   return true;
}

// Process tile images for metadata layer.  This is similar to ProcessImage
// in that we are converting tiles to indices, but we process the pixels
// heuristically rather than matching against accumulated tiles.
//
// Returns true on success.
static bool ProcessMetadataImage(const InputImage &input,
                                 TileMap *output,
                                 PositionList *start,
                                 PositionList *teleport,
                                 PositionList *throwables)
{
   assert(input.image.format == PNG_FORMAT_RGBA);

   ResizeOutput(input, output);
   ProcessAnnotations(input, output, start, teleport, throwables);
   const int grid_width = static_cast<int>(input.image.width) / kTileSize;
   const int grid_height = static_cast<int>(input.image.height) / kTileSize;
   DetectMountPoints(grid_width, grid_height, output);
   return AdjustObstacles(grid_width, grid_height, output) &&
          CheckStartingPoints(*start, *output) &&
          CheckTeleportPoints(*teleport, *output) &&
          CheckTerminalReactions(grid_width, grid_height, *output) &&
          RemoveGhosts(grid_width, grid_height, output);
}

//////////////////////////////////////////////////////////////////////

// Convert list of coordinates to a string.
static std::string SerializeCoordinates(const PositionList &positions)
{
   std::ostringstream output;
   output << '{';
   bool first = true;
   for(const auto &[x, y] : positions)
   {
      if( first )
      {
         first = false;
      }
      else
      {
         output << ", ";
      }
      output << '{' << x << ", " << y << '}';
   }
   output << '}';
   return output.str();
}

// Get index of the last row containing at least one nonempty tile.
static int IndexOfLastRow(const TileMap &tiles)
{
   for(int row = static_cast<int>(tiles.size()) - 1; row > 0; row--)
   {
      for(int cell : tiles[row])
      {
         if( cell != kBlankTile )
            return row;
      }
   }
   return 0;
}

// Write tile table contents.
static void WriteTileTable(FILE *outfile,
                           const std::string &name,
                           const TileMap &tiles)
{
   // Output array header, and store number of cells in the first entry.
   // Tilemap indices are stored from top to bottom, and for empty
   // trailing rows on the bottom, we just don't store those.  This
   // reduces startup time and saves a bit of memory.
   const int scan_limit = IndexOfLastRow(tiles) + 1;
   fprintf(outfile, "world.%s =\n{\n\t%d,\n",
           name.c_str(), scan_limit * static_cast<int>(tiles.front().size()));

   // Run-length encode tile indices: empty tiles are stored with a negative
   // count indicating number of empty tiles to follow, non-empty tiles are
   // packed two per cell.  This reduces code size since there are many
   // empty regions in our maps.
   //
   // We have to reduce code size since they are much more memory intensive
   // than static data:
   // https://devforum.play.date/t/malloc-pool-failures-with-arrays/15874
   //
   // We could load the tile data from disk, but it's much cleaner if we can
   // package all relevant data inside main.pdz.
   //
   // Up until 2024-02-10, we had only run-length encoding of blank tiles.
   // We considered run-length encoding of non-blank tiles as well, but that
   // was abandoned because it increased startup time by half a second.  A
   // few months after that, we were getting pressured for memory as more
   // map tiles were being drawn, and finally added the two-tile packing
   // scheme on 2024-06-03.  This two-tile packing turned out to be an
   // all-around good deal, reducing memory footprint without negligible
   // impact to startup time.
   class TableWriter
   {
   public:
      explicit TableWriter(FILE *output) : output_(output) {}

      // Output entry for a run of blank tiles.
      void WriteBlankRun(int count)
      {
         FlushBufferedNonblankValue();
         Write(-count);
      }

      // Output or buffer entry for a single non-blank tile.
      void WriteNonblankTile(int tile)
      {
         if( value_pair_buffer_ == 0 )
         {
            value_pair_buffer_ = tile;
         }
         else
         {
            Write((value_pair_buffer_ << 16) | tile);
            value_pair_buffer_ = 0;
         }
      }

      // Finish the table off.
      void Flush()
      {
         FlushBufferedNonblankValue();
         if( text_row_size_ > 0 )
            fputc('\n', output_);
      }

   private:
      // Flush a buffered value that's waiting to form a pair.
      void FlushBufferedNonblankValue()
      {
         if( value_pair_buffer_ != 0 )
         {
            Write(value_pair_buffer_);
            value_pair_buffer_ = 0;
         }
      }

      // Write packed value or run to output.
      void Write(int value)
      {
         fprintf(output_, text_row_size_ == 0 ? "\t%d," : " %d,", value);
         text_row_size_++;
         if( text_row_size_ == 10 )
         {
            fputc('\n', output_);
            text_row_size_ = 0;
         }
      }

      FILE *output_;
      int text_row_size_ = 0;
      int value_pair_buffer_ = 0;
   };

   TableWriter output_table(outfile);
   int blank_count = 0;
   for(int i = 0; i < scan_limit; i++)
   {
      for(int cell : tiles[i])
      {
         if( cell == kBlankTile )
         {
            // Start or continue span of blank cells.
            //
            // Spans are guaranteed to not overflow signed 16bit integers
            // because input maps are only so large, but we add a check here
            // just in case.  Actually we could extend to signed 32bit if
            // needed, since run-length spans always take up the full 32bit
            // entry, but we are keeping the 16bit limit in case if we
            // decide to use a different packing scheme in the future.
            assert(blank_count < 0x7fff);
            blank_count++;
         }
         else
         {
            // Flush current run of blank cells, and output non-blank cell.
            if( blank_count > 0 )
            {
               output_table.WriteBlankRun(blank_count);
               blank_count = 0;
            }
            output_table.WriteNonblankTile(cell);
         }
      }
   }

   // Flush remaining blank cell runs.
   if( blank_count > 0 )
      output_table.WriteBlankRun(blank_count);
   output_table.Flush();
   fputs("}\n", outfile);
}

// Write metadata table contents.
static void WriteMetadataTable(FILE *outfile,
                               const std::string &name,
                               const TileMap &tiles)
{
   fprintf(outfile, "world.%s =\n{\n", name.c_str());
   for(const TileRow &row : tiles)
   {
      bool first_cell = true;
      for(int cell : row)
      {
         if( first_cell )
         {
            fprintf(outfile, "\t{%d", cell);
            first_cell = false;
         }
         else
         {
            fprintf(outfile, ", %d", cell);
         }
      }
      fputs("},\n", outfile);
   }
   fputs("}\n", outfile);
}

// Write indices for all layers.  Returns true on success.
static bool WriteOutputIndices(const char *output_file,
                               const WorldTiles &world,
                               const TileBlockSet &unique_tiles,
                               const PositionList &start,
                               const PositionList &teleport,
                               const PositionList &throwables)
{
   FILE *f = fopen(output_file, "wb+");
   if( f == nullptr )
   {
      printf("Error writing %s\n", output_file);
      return false;
   }

   // Gather some statistics from metadata layer, if available.
   int item_count = 0;
   int removable_tile_count = 0;
   WorldTiles::const_iterator m = world.find("metadata");
   if( m != world.end() )
   {
      const TileMap &metadata = m->second;
      for(int y = 0; y < static_cast<int>(metadata.size()); y++)
      {
         const TileRow &row = metadata[y];
         for(int x = 0; x < static_cast<int>(row.size()); x++)
         {
            if( (row[x] & kCollectibleTileMask) != 0 )
            {
               item_count++;

               // Collectible tiles allow at least one background tile to be
               // removed.  If a collectible tile is hidden behind a chain
               // reaction, we will count the extra foreground tile below.
               removable_tile_count++;
            }

            if( (row[x] & (kChainReaction | kTerminalReaction)) != 0 )
            {
               // Chain reaction and terminal reactions allow exactly one
               // foreground tile to be removed.
               removable_tile_count++;
            }
            else if( (row[x] & kBreakableTile) != 0 )
            {
               // Breakable tiles allow up to two tiles to be removed, one
               // for foreground and one for background.  We always add 2 here
               // even though we might only need 1 depending on tile layout.
               removable_tile_count += 2;
            }
         }
      }
   }

   fputs("world = world or {}\n"
         "-- {{{ Constants\n", f);
   fprintf(f,
           "world.COLLISION_MASK = %d\n"
           "world.COLLISION_NONE = %d\n"
           "world.COLLISION_SQUARE = %d\n"
           "world.COLLISION_UP_LEFT = %d\n"
           "world.COLLISION_UP_RIGHT = %d\n"
           "world.COLLISION_DOWN_LEFT = %d\n"
           "world.COLLISION_DOWN_RIGHT = %d\n",
           kCollisionMask,
           kCollisionNone,
           kCollisionSquare,
           kCollisionUpLeft,
           kCollisionUpRight,
           kCollisionDownLeft,
           kCollisionDownRight);
   fprintf(f,
           "world.MOUNT_MASK = %d\n"
           "world.MOUNT_UP = %d\n"
           "world.MOUNT_DOWN = %d\n"
           "world.MOUNT_LEFT = %d\n"
           "world.MOUNT_RIGHT = %d\n",
           kMountMask,
           kMountUp,
           kMountDown,
           kMountLeft,
           kMountRight);
   fprintf(f,
           "world.BREAKABLE = %d\n"
           "world.COLLECTIBLE_UP = %d\n"
           "world.COLLECTIBLE_DOWN = %d\n"
           "world.COLLECTIBLE_LEFT = %d\n"
           "world.COLLECTIBLE_RIGHT = %d\n"
           "world.COLLECTIBLE_MASK = %d\n"
           "world.CHAIN_REACTION = %d\n"
           "world.TERMINAL_REACTION = %d\n",
           kBreakableTile,
           kCollectibleTileUp,
           kCollectibleTileDown,
           kCollectibleTileLeft,
           kCollectibleTileRight,
           kCollectibleTileMask,
           kChainReaction,
           kTerminalReaction);
   const TileMap &first_map = world.begin()->second;
   fprintf(f,
           "world.START = %s\n"
           "world.TELEPORT_POSITIONS = %s\n"
           "world.INIT_BALLS = %s\n"
           "-- }}} End constants\n"
           "-- {{{ Map info\n"
           "world.ITEM_COUNT = %d\n"
           "world.UNIQUE_TILE_COUNT = %d\n"
           "world.REMOVABLE_TILE_COUNT = %d\n"
           "world.WIDTH = %d\n"
           "world.HEIGHT = %d\n"
           "-- }}} End map info\n",
           SerializeCoordinates(start).c_str(),
           SerializeCoordinates(teleport).c_str(),
           SerializeCoordinates(throwables).c_str(),
           item_count,
           static_cast<int>(unique_tiles.size()),
           removable_tile_count,
           static_cast<int>(first_map.begin()->size() * kTileSize),
           static_cast<int>(first_map.size() * kTileSize));

   for(const auto &[name, tiles] : world)
   {
      if( IsMetadataFile(name) )
      {
         WriteMetadataTable(f, name, tiles);
      }
      else
      {
         WriteTileTable(f, name, tiles);
      }
   }

   fclose(f);
   return true;
}

// Write combined image of all unique tiles.  Returns true on success.
static bool WriteOutputImageTable(const char *output_file,
                                  const TileBlockSet &tiles)
{
   png_image image;
   memset(&image, 0, sizeof(image));
   image.version = PNG_IMAGE_VERSION;
   image.format = PNG_FORMAT_GA;

   image.width = kTileSize * kTilesPerRow;
   image.height = (tiles.size() + kTilesPerRow - 1) / kTilesPerRow * kTileSize;
   assert(image.width * image.height >= tiles.size());

   static constexpr int kBytesPerPixel = PNG_IMAGE_SAMPLE_SIZE(PNG_FORMAT_GA);
   static constexpr int kBytesPerRow =
      kTileSize * kTilesPerRow * kBytesPerPixel;

   // Allocate and zero-initialize output buffer.
   png_bytep pixels =
      reinterpret_cast<png_bytep>(calloc(PNG_IMAGE_SIZE(image), 1));
   if( pixels == nullptr )
   {
      puts("Out of memory");
      return false;
   }

   // Copy tiles to output buffer.
   for(const auto &[tile, index] : tiles)
   {
      // Generate output position from tile index.  Because tile indices
      // are unique, this guarantees that output tiles will not overlap.
      const int x0 = (index % kTilesPerRow) * kTileSize;
      const int y0 = (index / kTilesPerRow) * kTileSize;
      const TileBlock::Pixels tile_rows = tile.GetPixels();
      for(int y = 0; y < static_cast<int>(tile_rows.size()); y++)
      {
         memcpy(pixels + (y0 + y) * kBytesPerRow + x0 * kBytesPerPixel,
                tile_rows[y].data(), tile_rows[y].size());
      }
   }

   // Write output.
   if( !png_image_write_to_file(&image, output_file, 0, pixels, 0, nullptr) )
   {
      printf("Error writing to %s\n", output_file);
      free(pixels);
      return false;
   }
   free(pixels);
   return true;
}

}  // namespace

//////////////////////////////////////////////////////////////////////

int main(int argc, char **argv)
{
   if( argc < 4 )
   {
      return printf("%s {output.lua} {output-table-%d-%d.png} {input*.png}\n",
                    *argv, kTileSize, kTileSize);
   }

   // Pre-allocate handles for images.  "input" vector will not resize
   // after this step, so we can have pointers to input elements and know
   // that they will not move.
   std::vector<InputImage> input;
   input.resize(argc - 3);

   // Load input images and tiles.
   TileBlockSet unique_tiles;
   WorldTiles world_tiles;
   PositionList start, teleport, throwables;
   for(int i = 3; i < argc; i++)
   {
      // Load image.
      InputImage &r = input[i - 3];
      r.filename = argv[i];
      memset(&r.image, 0, sizeof(png_image));
      r.image.version = PNG_IMAGE_VERSION;
      if( !png_image_begin_read_from_file(&r.image, r.filename) )
         return printf("Error reading %s\n", r.filename);

      if( r.image.width % kTileSize != 0 )
      {
         return printf("%s: width (%d) is not a multiple of %d\n",
                       r.filename, r.image.width, kTileSize);
      }
      if( r.image.height % kTileSize != 0 )
      {
         return printf("%s: height (%d) is not a multiple of %d\n",
                       r.filename, r.image.height, kTileSize);
      }
      if( r.image.width != input.front().image.width ||
          r.image.height != input.front().image.height )
      {
         return printf("%s: input image sizes are not uniform: "
                       "(%d,%d) vs (%d,%d)\n",
                       r.filename, r.image.width, r.image.height,
                       input.front().image.width, input.front().image.height);
      }

      r.image.format = IsMetadataFile(r.filename) ? PNG_FORMAT_RGBA
                                                  : PNG_FORMAT_GA;
      r.pixels = reinterpret_cast<png_bytep>(malloc(PNG_IMAGE_SIZE(r.image)));
      if( r.pixels == nullptr )
      {
         return printf("%s: not enough memory to load %dx%d\n",
                       r.filename, r.image.width, r.image.height);
      }
      if( !png_image_finish_read(&r.image, nullptr, r.pixels, 0, nullptr) )
         return printf("%s: error reading pixels\n", r.filename);

      // Add image entry to world.
      auto p =
         world_tiles.insert(std::make_pair(GenerateLayerName(r.filename),
                                           TileMap()));
      if( IsMetadataFile(r.filename) )
      {
         if( !ProcessMetadataImage(
                 r, &(p.first->second), &start, &teleport, &throwables) )
         {
            return 1;
         }
      }
      else
      {
         ProcessImage(r, &unique_tiles, &(p.first->second));
      }
   }
   if( unique_tiles.empty() )
      return printf("No tiles to output\n");
   if( static_cast<int>(unique_tiles.size()) > kMaxTileCount )
   {
      return printf("Too many tiles: limit is %d, got %d\n",
                    kMaxTileCount, static_cast<int>(unique_tiles.size()));
   }


   // Write output and exit with zero status on success.
   return WriteOutputIndices(argv[1],
                             world_tiles, unique_tiles,
                             start, teleport, throwables) &&
          WriteOutputImageTable(argv[2], unique_tiles) ? 0 : 1;
}
