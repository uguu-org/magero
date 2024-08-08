// Given a list of input PNG images, output an extra set of PNG images
// that highlights the first occurrence of each new tile.  This is
// meant to debug places where we used up too many tiles.

#include<png.h>
#include<stdio.h>
#include<stdlib.h>
#include<string.h>

#include<array>
#include<atomic>
#include<string>
#include<string_view>
#include<thread>
#include<unordered_map>
#include<vector>

namespace {

// Prefix to prepend to output file names.
static constexpr const char kPrefix[] = "t_tiles_";

// Width and height of world tiles (pixels).
static constexpr int kTileSize = 32;

// Syntactic sugar.
static constexpr int kBytesPerPixel = PNG_IMAGE_SAMPLE_SIZE(PNG_FORMAT_RGBA);
static constexpr int kBlankTile = -1;

// If true, encode output images in multiple threads.  If false, output
// images will be encoded serially in a single thread.
static constexpr bool kMultiThreadedOutputEncode = true;

// Rarity labels.  See AnnotateTile().
enum Rarity
{
   kUnique = 0,
   kRare,
   kSparse,
   kUncommon,
   kCommon,
};
static constexpr const int kRarityCount = 5;
static constexpr std::array<const char*, kRarityCount> kRarityLabel =
{
   "unique", "rare", "sparse", "uncommon", "common"
};

// Rarity use count thresholds.  Tiles with use counts less than or equal
// to the specified threshold will get assigned the corresponding rarity.
//
// Because we have 4 frames for each layer, it's typical for the usage
// counts of a tile to be multiples of 4.  Thus most rarity thresholds
// here are set in multiples of 4 as well.  If a tile is used in only one
// or two locations on the map, it's considered "rare", and we should try
// to find a similar looking tile somewhere to improve tile image sharing.
//
// "Unique" tiles are truly unique, i.e. appearing exactly once across all
// frames.  These are often animation frames for one-off collectible item
// tiles, so there is usually no replacement candidates for these.
static constexpr std::array<int, kRarityCount - 1> kRarityThresholds =
{
   1, 4, 8, 16
};

// Wrapper for a single input image.
struct InputImage
{
   InputImage() = default;
   ~InputImage() { free(pixels); }

   const char *filename = nullptr;
   png_image image;
   png_bytep pixels = nullptr;

   std::vector<std::vector<int>> tiles;
};

// Wrapper around a single image region.
struct TileBlock
{
   using Pixels = std::vector<std::string_view>;

   // Convenience function return the selected pixels.
   Pixels GetPixels() const;

   // Source image.
   const InputImage *source;

   // Tile offset.
   int x, y;
};

// Convenience function to return the selected pixels.
TileBlock::Pixels TileBlock::GetPixels() const
{
   std::vector<std::string_view> pixels;
   pixels.reserve(kTileSize);
   const int row_size = source->image.width * kBytesPerPixel;
   const char *source_pixels = reinterpret_cast<const char*>(
      source->pixels + y * row_size + x * kBytesPerPixel);
   for(int i = 0; i < kTileSize; i++)
   {
      pixels.push_back(std::string_view(source_pixels,
                                        kTileSize * kBytesPerPixel));
      source_pixels += row_size;
   }
   return pixels;
}

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

// Check if all pixels are transparent.
static bool IsBlank(const TileBlock::Pixels &pixels)
{
   for(const std::string_view &row : pixels)
   {
      for(int x = 3; x < static_cast<int>(row.size()); x += kBytesPerPixel)
      {
         if( row[x] != 0 )
            return false;
      }
   }
   return true;
}

// Convert tiles to indices.
static void IndexTiles(InputImage *image, TileBlockSet *unique_tiles)
{
   image->tiles.resize(image->image.height / kTileSize);
   for(int i = 0; i < static_cast<int>(image->image.height) / kTileSize; i++)
      image->tiles[i].resize(image->image.width / kTileSize);

   TileBlock tile;
   tile.source = image;
   for(int y = 0; y < static_cast<int>(image->image.height); y += kTileSize)
   {
      tile.y = y;
      for(int x = 0; x < static_cast<int>(image->image.width); x += kTileSize)
      {
         tile.x = x;
         if( IsBlank(tile.GetPixels()) )
         {
            image->tiles[y / kTileSize][x / kTileSize] = kBlankTile;
         }
         else
         {
            const int tile_count = static_cast<int>(unique_tiles->size());
            auto p = unique_tiles->insert(std::make_pair(tile, tile_count));
            image->tiles[y / kTileSize][x / kTileSize] = p.first->second;
         }
      }
   }
}

// Count number of tiles each tile is used.
static void CountTiles(const InputImage &image, std::vector<int> *tile_count)
{
   for(const std::vector<int> &row : image.tiles)
   {
      for(int cell : row)
      {
         if( cell >= 0 )
            (*tile_count)[cell]++;
      }
   }
}

// Select rarity based on usage count.  See comments near kRarityThresholds.
static Rarity SelectRarity(int use_count)
{
   for(size_t i = 0; i < kRarityThresholds.size(); i++)
   {
      if( use_count <= kRarityThresholds[i] )
         return static_cast<Rarity>(i);
   }
   return kCommon;
}

// Annotate tile based on how often it's used across all files.
// Returns rarity index.
static int AnnotateTile(InputImage *image, int x, int y, int use_count)
{
   const int row_size = static_cast<int>(image->image.width) * kBytesPerPixel;
   const Rarity rarity = SelectRarity(use_count);
   for(int i = 0; i < kTileSize; i++)
   {
      png_bytep p = image->pixels + (y + i) * row_size + x * kBytesPerPixel;
      for(int j = 0; j < kTileSize; j++)
      {
         switch( rarity )
         {
            case kCommon:
               // Green.
               p[0] = 0;
               p[2] = 0;
               break;
            case kUncommon:
               // Yellow.
               p[2] = 0;
               break;
            case kSparse:
               // Faded red.
               p[1] /= 2;
               p[2] /= 2;
               break;
            case kRare:
               // Red.
               p[1] = 0;
               p[2] = 0;
               break;
            case kUnique:
               // Magenta.
               p[1] = 0;
               break;
         }
         p += 4;
      }
   }
   return rarity;
}

// Rewrite tiles.
static void RewriteImage(const std::vector<int> &global_tile_count,
                         InputImage *image,
                         int *highest_tile)
{
   int local_tile_count = 0;
   int local_new_tiles = 0;
   std::array<int, kRarityCount> counts{};

   for(int y = 0; y < static_cast<int>(image->image.height); y += kTileSize)
   {
      const std::vector<int> &row = image->tiles[y / kTileSize];
      for(int x = 0; x < static_cast<int>(image->image.width); x += kTileSize)
      {
         const int cell = row[x / kTileSize];
         if( cell == kBlankTile )
            continue;
         local_tile_count++;

         // Skip this tile if we have seen it before.  We only want to
         // annotate the first occurrence of each tile.
         if( cell <= *highest_tile )
            continue;

         *highest_tile = cell;
         local_new_tiles++;

         // Annotate tiles based on how often it's used.
         const int rarity = AnnotateTile(image, x, y, global_tile_count[cell]);
         counts[rarity]++;
      }
   }
   printf("%s: %d tiles, %d new",
          image->filename, local_tile_count, local_new_tiles);
   for(int i = 0; i < kRarityCount; i++)
      printf(", %d %s", counts[i], kRarityLabel[i]);
   putchar('\n');
}

// Generate output file name based on input name.
static std::string GenerateOutputFilename(std::string filename)
{
   const std::string::size_type s = filename.rfind('/');
   if( s != std::string::npos )
      return filename.substr(0, s + 1) + kPrefix + filename.substr(s + 1);
   return kPrefix + filename;
}

// Write output image.
static void WriteOutput(InputImage *input, std::atomic_int *errors)
{
   const std::string output_name = GenerateOutputFilename(input->filename);

   // Set flag to optimize for encoding speed rather than output size.
   // This is fine since output is only used for debugging.
   input->image.flags |= PNG_IMAGE_FLAG_FAST;
   if( !png_image_write_to_file(
           &(input->image), output_name.c_str(), 0, input->pixels, 0, nullptr) )
   {
      printf("Error writing %s\n", output_name.c_str());
      ++*errors;
   }
}

}  // namespace

int main(int argc, char **argv)
{
   if( argc < 2 )
      return printf("%s {input*.png}\n", *argv);

   // Pre-allocate handles for images.  "input" vector will not resize
   // after this step, so we can have pointers to input elements and know
   // that they will not move.
   std::vector<InputImage> input;
   input.resize(argc - 1);
   TileBlockSet unique_tiles;
   for(int i = 1; i < argc; i++)
   {
      // Load image.
      InputImage &r = input[i - 1];
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

      r.image.format = PNG_FORMAT_RGBA;
      r.pixels = reinterpret_cast<png_bytep>(malloc(PNG_IMAGE_SIZE(r.image)));
      if( r.pixels == nullptr )
      {
         return printf("%s: not enough memory to load %dx%d\n",
                       r.filename, r.image.width, r.image.height);

      }
      if( !png_image_finish_read(&r.image, nullptr, r.pixels, 0, nullptr) )
         return printf("%s: error reading pixels\n", r.filename);

      // Classify tiles in this image.
      IndexTiles(&r, &unique_tiles);
   }

   // Count unique tiles.
   printf("tile table size = %d\n", static_cast<int>(unique_tiles.size()));
   std::vector<int> tile_count(unique_tiles.size(), 0);
   for(const auto &i : input)
      CountTiles(i, &tile_count);

   // Rewrite pixels and write output images.
   int highest_tile = -1;
   std::atomic_int errors{};
   if( kMultiThreadedOutputEncode )
   {
      std::vector<std::thread> encode_threads;
      encode_threads.reserve(input.size());
      for(auto &i : input)
      {
         RewriteImage(tile_count, &i, &highest_tile);
         encode_threads.emplace_back(WriteOutput, &i, &errors);
      }
      for(auto &t : encode_threads)
         t.join();
   }
   else
   {
      for(auto &i : input)
      {
         RewriteImage(tile_count, &i, &highest_tile);
         WriteOutput(&i, &errors);
      }
   }
   return errors.load();
}
