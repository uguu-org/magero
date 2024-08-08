--[[ World environment states.

All the world interaction bits go here.  Best way to read this file is to
start at the world exported functions:

- For collision detection, see world.collide().
- For ball physics, see world.throw_ball().
- For tile updates, see world.remove_breakable_tiles().
- For chain reactions, see world.area_trigger().

--]]

import "CoreLibs/graphics"
import "CoreLibs/sprites"

import "util"

-- Cached imported references.
local gfx <const> = playdate.graphics
local abs <const> = math.abs
local max <const> = math.max
local min <const> = math.min
local floor <const> = math.floor
local sqrt <const> = math.sqrt

local distance2 <const> = util.distance2

-- World states.
world =
{
	-- Area of focus.
	focus_min_x = 0,
	focus_min_y = 0,
	focus_max_x = 1,
	focus_max_y = 1,

	-- Global sprite offsets.  This is saved in persistent state.
	sprite_offset_x = 0,
	sprite_offset_y = 0,

	-- List of collectible tiles that were removed from world_grid_bg.  Each
	-- array element contains a tile index.  This is not saved in persistent
	-- state since it will be derived from removed_tiles on load.
	collected_tiles = {},

	-- Number breakable tiles that were removed from world_grid_bg.
	--
	-- If the original tile was animated, it will be counted as "vanquished"
	-- when the tile is removed, otherwise it's counted as "broken".
	--
	-- Half-broken tiles are not counted, i.e. those that are removed from
	-- world_grid_fg but not yet removed from world_grid_bg do not count.
	--
	-- These are not saved in persistent state since they are derived from
	-- removed_tiles on load.
	broken_tiles = 0,
	vanquished_tiles = 0,

	-- Number of times we threw/dropped a ball.  Both are counted by
	-- world.throw_ball(), the difference being that throw_count has nonzero
	-- initial velocity.
	--
	-- These are saved in persistent state.
	throw_count = 0,
	drop_count = 0,

	-- Number of times we summoned an UFO.
	ufo_count = 0,

	-- List of metadata tiles removed from world.metadata.  This is not saved
	-- in persistent state, see serialized_removed_tiles below.
	--
	-- Array contains an even number of elements of {coordinate, tile} pairs.
	-- That is, removed_element[i*2 + 1] contains an encoded coordinate, and
	-- removed_element[i*2 + 2] contains tile data.  This is a flattened array
	-- instead of a 2D array because it's more memory efficient that way.
	--
	-- encoded coordinate =
	--    If foreground tile was removed: (tile_x << 9 | tile_y)
	--    If background tile was removed: -(tile_x << 9 | tile_y)
	--
	--    9 bits is the minimum needed to store tile_y values.  We want the
	--    minimum to keep the magnitude of the encoded values small, since
	--    small numbers take up fewer bytes in the JSON save state file.
	--
	--  tile = metadata tile that was removed.
	--
	-- When resetting state, this list is used to restore the contents of
	-- world.metadata.  We need this to backup the deleted metadata tile
	-- values because world.metadata is modified directly during gameplay,
	-- unlike world.bg and world.fg.
	--
	-- When loading state, this list indicates which tiles to remove, i.e.
	-- it enables removals from previous run to be replayed so that tilemaps
	-- matches previous saved state.
	removed_tiles = {},

	-- Serialized copy of removed_tiles, for save state.  This differs from
	-- removed_tiles in that it's only updated at the beginning of a
	-- playdate.update() cycle, and not continuously updated at each frame.
	-- The intent is that if player tried to save a game in the middle of
	-- a chain reaction sequence, the state that is saved will be the state
	-- before the chain reaction started.
	--
	-- Because removed_tiles can be large, we don't want to make a fresh copy
	-- at each update cycle, so we keep a cached copy here and only refresh
	-- when the cache is out of sync.  We can tell when it's out of sync
	-- because removed_tiles is append-only.
	serialized_removed_tiles = {},

	-- List of teleport stations visited.
	teleport_stations = {},
	serialized_teleport_stations = {},

	-- Tile coordinate of the last collected item.
	last_item_tile_x = nil,
	last_item_tile_y = nil,

	-- List of throwable ball coordinates, each entry contains a {x,y} pair.
	-- Index to this array matches indices to world.INIT_BALLS array.
	--
	-- This is not saved in persistent state, see serialized_balls below.
	balls = {},

	-- Copy of balls, for save state.
	--
	-- Unlike "balls" which is updated continuously when a ball is thrown,
	-- this one is only updated at the beginning of each playdate.update()
	-- cycle, such that if player tries to save state when a ball is in-flight,
	-- the state that is saved is before the ball was thrown.
	serialized_balls = {},

	-- Set to true when serialized_balls needs refreshing.  Note that it starts
	-- out as dirty so that serialized_balls is populated on first update.
	serialized_balls_dirty = true,

	-- Ring buffer of previous positions for the ball that is currently held.
	-- Array of {x,y} tuples, with zero-based index.  This is used to compute
	-- a ball's initial velocity when thrown.
	--
	-- A different way of getting that initial velocity is to track the velocity
	-- of the hand, but it's a bit of a mess to thread that information through.
	-- Conceptually, it seems cleaner to have the ball track its own position,
	-- which is what we are doing here.
	BALL_HISTORY_MASK = 63,
	ball_position_history = {},
	ball_history_index = 0,

	-- If a ball is currently moving, this is the index of that ball.  It's
	-- either the index of the ball that is being held (arm.hold) or a
	-- ball that was recently thrown.
	follow_ball = 0,

	-- True if reset is requested.  This is a world state so that we can
	-- cut animations early upon reset.
	reset_requested = false,

	-- Number of frames rendered since last reset.
	--
	-- This is saved in persistent state.
	frame_count = 0,

	-- Number of frames spent in debug mode.  We track this and show this
	-- in the paused menu, on the off chance that there is some speedrun
	-- that involves debug mode.
	--
	-- This is saved in persistent state.
	debug_frame_count = 0,

	-- Number of frames at the time when the final item was collected.
	-- This is effectively a signal to say that the game has been completed.
	--
	-- This is saved in persistent state.
	completed_frame_count = 0,

	-- Number of tiles painted in endgame.
	--
	-- This is not saved in persistent state, since the painted tiles are
	-- not saved in persistent state either.  The intent is to always give
	-- players a blank world to paint if they have resumed a completed game.
	-- The theory is that painting a blank canvas would be more fun than trying
	-- to obsessively find all unpainted tiles.
	--
	-- It's conceivable that there might be some challenge to get the highest
	-- number of painted tiles under limited time, and not saving painted state
	-- will make that rather inconvenient.  But supporting this case could
	-- greatly enlarge the saved state due to the high number of tiles that
	-- can be painted, so it's not something we want to do.
	paint_count = 0,

	-- Returned kinds for find_points_of_interest().
	MOUNT = 1,
	COLLECT = 2,
	PICK_UP = 3,
	SUMMON = 4,
	TELEPORT = 5,
}

-- World data.
import "data"

-- Cached world references.
local COLLISION_MASK <const> = world.COLLISION_MASK
local COLLISION_SQUARE <const> = world.COLLISION_SQUARE
local COLLISION_UP_LEFT <const> = world.COLLISION_UP_LEFT
local COLLISION_UP_RIGHT <const> = world.COLLISION_UP_RIGHT
local COLLISION_DOWN_LEFT <const> = world.COLLISION_DOWN_LEFT
local COLLISION_DOWN_RIGHT <const> = world.COLLISION_DOWN_RIGHT
local MOUNT_MASK <const> = world.MOUNT_MASK
local MOUNT_UP <const> = world.MOUNT_UP
local MOUNT_DOWN <const> = world.MOUNT_DOWN
local MOUNT_LEFT <const> = world.MOUNT_LEFT
local MOUNT_RIGHT <const> = world.MOUNT_RIGHT
local BREAKABLE <const> = world.BREAKABLE
local COLLECTIBLE_UP <const> = world.COLLECTIBLE_UP
local COLLECTIBLE_DOWN <const> = world.COLLECTIBLE_DOWN
local COLLECTIBLE_LEFT <const> = world.COLLECTIBLE_LEFT
local COLLECTIBLE_RIGHT <const> = world.COLLECTIBLE_RIGHT
local COLLECTIBLE_MASK <const> = world.COLLECTIBLE_MASK
local CHAIN_REACTION <const> = world.CHAIN_REACTION
local TERMINAL_REACTION <const> = world.TERMINAL_REACTION

assert(COLLISION_MASK)
assert(COLLISION_SQUARE)
assert(COLLISION_UP_LEFT)
assert(COLLISION_UP_RIGHT)
assert(COLLISION_DOWN_LEFT)
assert(COLLISION_DOWN_RIGHT)
assert(MOUNT_MASK)
assert(MOUNT_UP)
assert(MOUNT_DOWN)
assert(MOUNT_LEFT)
assert(MOUNT_RIGHT)
assert(BREAKABLE)
assert(COLLECTIBLE_UP)
assert(COLLECTIBLE_DOWN)
assert(COLLECTIBLE_LEFT)
assert(COLLECTIBLE_RIGHT)
assert(COLLECTIBLE_MASK)
assert(CHAIN_REACTION)
assert(TERMINAL_REACTION)
-- No cache for world.COLLISION_NONE, since we only use it inside asserts.

-- Convenient abbreviations.
local MOUNT_UP_LEFT <const> = MOUNT_UP | MOUNT_LEFT
local MOUNT_UP_RIGHT <const> = MOUNT_UP | MOUNT_RIGHT
local MOUNT_DOWN_LEFT <const> = MOUNT_DOWN | MOUNT_LEFT
local MOUNT_DOWN_RIGHT <const> = MOUNT_DOWN | MOUNT_RIGHT
local REACTION_TILE <const> = CHAIN_REACTION | TERMINAL_REACTION
local MUTABLE_TILE <const> = BREAKABLE | REACTION_TILE
local BALL_HISTORY_MASK <const> = world.BALL_HISTORY_MASK

----------------------------------------------------------------------
--{{{ States.

-- Screen dimensions.
local SCREEN_WIDTH <const> = 400
local SCREEN_HEIGHT <const> = 240

-- Screen margin.  We will start scrolling if the focus area falls within
-- this many pixels of screen edge.
--
-- Reducing this margin will reduce the amount of scrolling, but we really
-- don't want to tweak the current setting since it's already ingrained in
-- certain level design elements.  In particular, registration of teleport
-- stations depends on visibility, so adjusting this setting may cause some
-- area to become unreachable.
local SCREEN_MARGIN <const> = 80
local SCREEN_MIN_X <const> = SCREEN_MARGIN
local SCREEN_MAX_X <const> = SCREEN_WIDTH - SCREEN_MARGIN
local SCREEN_MIN_Y <const> = SCREEN_MARGIN
local SCREEN_MAX_Y <const> = SCREEN_HEIGHT - SCREEN_MARGIN

-- World constants.
local TILE_SIZE <const> = 32
local HALF_TILE_SIZE <const> = TILE_SIZE / 2
local EMPTY_TILE <const> = -1
assert(world.WIDTH % TILE_SIZE == 0)
assert(world.HEIGHT % TILE_SIZE == 0)

local GRID_W <const> = world.WIDTH // TILE_SIZE
local GRID_H <const> = world.HEIGHT // TILE_SIZE
assert(world.ibg0[1] % GRID_W == 0)
assert(world.ibg1[1] % GRID_W == 0)
assert(world.ibg2[1] % GRID_W == 0)
assert(world.ibg3[1] % GRID_W == 0)
assert(world.bg0[1] % GRID_W == 0)
assert(world.bg1[1] % GRID_W == 0)
assert(world.bg2[1] % GRID_W == 0)
assert(world.bg3[1] % GRID_W == 0)
assert(world.fg0[1] % GRID_W == 0)
assert(world.fg1[1] % GRID_W == 0)
assert(world.fg2[1] % GRID_W == 0)
assert(world.fg3[1] % GRID_W == 0)
assert(#world.metadata == GRID_H)
assert(#world.metadata[1] == GRID_W)
assert(GRID_H <= 0x1ff)

local ITEM_GRID_W <const> = 12
local ITEM_GRID_H <const> = 7
assert(ITEM_GRID_W * TILE_SIZE <= SCREEN_WIDTH)
assert(ITEM_GRID_H * TILE_SIZE <= SCREEN_HEIGHT)

-- We need at least one item available, otherwise the game can't tell
-- whether player has won or not.  We do this check here rather than in
-- generate_world_tiles.cc, otherwise we would need to update all test
-- data to include at least one collectible item.
assert(world.ITEM_COUNT > 0)

-- Allow a ball to be summoned back to its initial location if it has
-- moved this much distance (squared) from its initial location.
local BALL_SUMMON_DISTANCE2 <const> = 128 * 128

-- Vertical distance from teleport station mount point to where the UFO
-- will be summoned.
world.TELEPORT_STATION_HEIGHT = 128
local TELEPORT_STATION_HEIGHT <const> = world.TELEPORT_STATION_HEIGHT

-- Frame delay for propagating changes from CHAIN_REACTION tiles.
local CHAIN_REACTION_FRAME_DELAY <const> = 4

-- Z indices.  See also arm.lua.
local Z_COMPLETION_MARKER <const> = 9
local Z_GRID_STARS <const> = 7
local Z_GRID_IBG <const> = 8
local Z_GRID_BG <const> = 10
local Z_GRID_FG <const> = 30
local Z_UFO <const> = 32
local Z_PAINT_BG <const> = 11
local Z_BALL <const> = 12
local Z_DEBRIS <const> = Z_GRID_FG + 1

-- Save state dictionary keys.
local SAVE_STATE_REMOVED_TILES <const> = "r"
local SAVE_STATE_FRAME_COUNT <const> = "f"
local SAVE_STATE_DEBUG_FRAME_COUNT <const> = "g"
local SAVE_STATE_COMPLETED_FRAME_COUNT <const> = "e"
local SAVE_STATE_THROW_COUNT <const> = "t"
local SAVE_STATE_DROP_COUNT <const> = "d"
local SAVE_STATE_UFO_COUNT <const> = "u"
local SAVE_STATE_BALLS <const> = "b"
local SAVE_STATE_TELEPORT_STATIONS <const> = "s"
local SAVE_STATE_SPRITE_OFFSET_X <const> = "x"
local SAVE_STATE_SPRITE_OFFSET_Y <const> = "y"

-- Images for loading screen.  0-based index, lazily initialized.
local loading_images = {}

-- Grid images.  Most of the images are part of the grid, including all
-- collectible items and throwable balls.
local world_tiles = nil

-- Debris image table.
local debris_images = nil

-- Exploding debris.  Each entry contains {frame, sprite handle}.
--
-- This table contains debris of different lifetimes in not-quite-sorted
-- order, so it's not like paint_timer where we only need to check the first
-- entry for expiry.  But since there are usually only one item in the table,
-- we will just clear the whole table at once when all timers are done.
local debris_sprites = {}

-- Sprite for animating completion marker flag.
local completion_marker_sprite = nil
local completion_timer = nil

-- List of timers tracking painted completion markers.  Each entry contains a
-- tuple of {frames_remaining, marker_type, tile_x, tile_y, sprite}
--
-- This is a queue with newest timer being appended, and all timers have the
-- same duration, so the oldest timer that is pending expiry will be at the
-- head of the queue.
local paint_timer = {}

-- Array of tilemaps for maintaining grid state.  0-based index.
local world_grid_ibg = {}
local world_grid_bg = {}
local world_grid_fg = {}

-- Array of sprites for displaying tilemaps.  0-based index.
local world_grid_ibg_sprite = {}
local world_grid_bg_sprite = {}
local world_grid_fg_sprite = {}

-- Extra patch of tiles to cover the upper part of the world that is just
-- out of bounds.
local top_of_world_grid = nil
local top_of_world_sprite = nil

-- Number of rows of tiles to generate for top_of_world_grid.
--
-- Setting this to the minimum number of rows needed to cover the height of
-- the screen is definitely sufficient, but actually we can get away with
-- slightly lower than that number because the row of tiles where the arm
-- rests on is always visible, hence the flooring division below.
local TOP_OF_WORLD_HEIGHT <const> = SCREEN_HEIGHT // TILE_SIZE

-- Tile coordinate of first star tile.
--
-- See PALETTE_X and PALETTE_Y in add_stars.pl
local STAR_PALETTE_TILE_X <const> = 9280 // TILE_SIZE + 1
local STAR_PALETTE_TILE_Y <const> = 1

-- UFO.  This will show up if a ball is near the edge of the world, and also
-- if player initiated a teleport.
--
-- As to why we have a UFO at all: we don't want the ball to go out of bounds
-- near top of the world where Y value could become negative, and all tile
-- calculations assume positive Y values so that we can use right shifts as
-- opposed to divides.  We tried adding some edge handling code to move_point
-- and move_ball, but neither were satisfactory.  In the end, the simplest
-- solution was to add an extra collision rectangle near the edges of the world
-- to guarantee that balls will never go out of bounds.
--
-- After adding the collision rectangles, we have to explain why the ball might
-- observe some unnatural bounces near the edges, since the collision
-- rectangles were invisible.  We could draw something there, but then we would
-- have think about what would be a natural object that would be fixed in the
-- sky that balls can bounce off of.  But then I thought an *unnatural* object
-- in the sky would be even better, such as an UFO.  This UFO would show up at
-- just the right moment to block the path of the ball, and disappear soon
-- after that to keep the skies clear.  And in a few hours, I had drawn and
-- coded a UFO.
--
-- Honestly the most natural thing to do would be to leave sufficient margin
-- near top of the world such that the ball can never reach that high, but now
-- that we have a UFO, I intentionally raised the floor in some of the upper
-- areas to make it easier to summon the UFO.
--
-- Now that we have a UFO, it's kind of a waste to only have it bounce balls
-- off the ceiling, so I also implemented a teleport function.  I always meant
-- to do that of course, but now it also summons UFO.
local UFO_FRAMES <const> = 5  -- 1 = fully opaque, 5 = near transparent.
local UFO_WIDTH <const> = 121
local UFO_HEIGHT <const> = 37
local UFO_BOUNCE_FRAMES <const> = 25
local ufo_images = nil
local ufo_sprite = nil
local ufo_frame = UFO_FRAMES + 1
local ufo_frame_delta = 0  -- 1 = fade out, -1 = fade in.

-- Array of ball sprites.  1-based index, matching world.balls and
-- world.INIT_BALLS arrays.
local ball_sprite = {}

-- Tile image for the ball sprites.  1-based index.
local ball_sprite_tile_index = {}

-- List of item locations, initialized on first use.
-- Entries contain {grid_x, grid_y} tuples.
local item_locations = nil

--}}}

----------------------------------------------------------------------
--{{{ Debug logging functions.

-- Print a message, and return true.  The returning true part allows this
-- function to be called inside assert(), which means this function will
-- be stripped in the release build by strip_lua.pl.
local function debug_log(msg)
	print(string.format("[%f]: %s", playdate.getElapsedTime(), msg))
	return true
end

-- Draw frame rate in debug builds.
local function debug_frame_rate()
	playdate.drawFPS(4, 220)
	return true
end

-- Print contents of world.move_point_history to console.
--
-- When a call to test_move_point fails, this function will print a list of
-- move histories to the console, like this:
--
--  [1] #2 (3,4,5,6) -> (7,8,9,10), example_label
--
-- This says the first call ([1]) to move_point was the second call to be
-- completed (#2).  It had an input of (x=3,y=4,vx=5,vy=6) and an output of
-- (x=7,y=8,vx=9,vy=10).  All the movements that can be completed in a single
-- step will have a single entry that say "[1] #1" near the beginning, while
-- movements that required dividing the velocity into smaller steps will have
-- multiple entries of varying order.
--
-- The way debugging works is by going through these move histories and
-- search the code for the corresponding comments ("example_label" above) to
-- see which branch the process went through, and fix any issues nearby.
--
-- With any luck, all these comments above should be moot because move_point()
-- is fully debugged, but I knew as soon as I wrote these comments that I will
-- be debugging that function for weeks to come.
local function debug_trace_move_point_dump()
	if world.move_point_history and #world.move_point_history > 0 then
		print("move_point_history:")
		for i = 1, #world.move_point_history do
			local entry <const> = world.move_point_history[i]
			local text = string.format(
				"[%d] #%s (%g, %g, %g, %g) ->",
				i, entry.steps,
				entry.start[1], entry.start[2], entry.start[3], entry.start[4])
			if entry.stop then
				local d <const> =
					sqrt(distance2(entry.stop[1] - entry.start[1],
					               entry.stop[2] - entry.start[2]))
				text = string.format(
					"%s (%g, %g, %g, %g, %s, %s), d=%g",
					text,
					entry.stop[1], entry.stop[2], entry.stop[3], entry.stop[4],
					entry.stop[5], entry.stop[6],
					d)
			else
				text = text .. " incomplete"
			end
			for j = 1, #entry.comments do
				text = text .. ", " .. entry.comments[j]
			end
			print(text)
		end
	else
		print("move_point_history: empty")
	end
	return true
end

local function debug_trace_move_point_reset()
	world.move_point_history = {}
	return true
end

local function debug_trace_move_point_begin(init_x, init_y, init_vx, init_vy)
	assert(init_x and init_y and init_vx and init_vy)
	table.insert(world.move_point_history,
	             {
	                start = {init_x, init_y, init_vx, init_vy},
	                stop = nil,
	                steps = nil,
	                comments = {},
	             })
	return true
end

local function debug_trace_move_point_get_index(init_x, init_y, init_vx, init_vy)
	-- Linearly search through move_point_history, returning the last entry
	-- that has matching parameters and path has not been completed yet.
	-- We need the completeness check because move_point with the same
	-- arguments may be called multiple times by move_ball.
	local fallback_index = nil
	for i = #world.move_point_history, 1, -1 do
		local entry = world.move_point_history[i]
		if entry.start[1] == init_x and entry.start[2] == init_y and
		   entry.start[3] == init_vx and entry.start[4] == init_vy then
			if not entry.stop then
				return i
			end
			fallback_index = i
		end
	end

	-- Didn't find an incomplete entry, just return the last entry we found
	-- with matching parameters.
	return fallback_index
end

local function debug_trace_move_point_append(init_x, init_y, init_vx, init_vy, comment)
	assert(init_x and init_y and init_vx and init_vy)
	local i <const> = debug_trace_move_point_get_index(init_x, init_y, init_vx, init_vy)
	if i then
		table.insert(world.move_point_history[i].comments, comment)
		return true
	end

	-- Unmatched debug_trace_move_point_append without a corresponding
	-- debug_trace_move_point_begin, return false to make the assertion fail.
	print(string.format("Unmatched debug_trace_move_point_append(%g, %g, %g, %g)", init_x, init_y, init_vx, init_vy))
	return false
end

local function debug_trace_move_point_end(init_x, init_y, init_vx, init_vy, comment, end_x, end_y, end_vx, end_vy, hit_tile_x, hit_tile_y)
	assert(init_x and init_y and init_vx and init_vy)
	assert(comment and end_x and end_y and end_vx and end_vy)

	-- Count number of completed entries in move_point_history.  This for
	-- determining the step count of when the current move completed.  This
	-- helps in following the recursive calls to move_point.
	--
	-- Other things we have tried include sorting move_point_history by
	-- completion order, but in the end it was more informational to just
	-- make both initiation and completion order visible.
	local steps = 1
	for i = 1, #world.move_point_history do
		local entry <const> = world.move_point_history[i]
		if entry.stop then
			steps += 1
		end
	end

	-- Update the corresponding entry that initiated this move.
	local i <const> = debug_trace_move_point_get_index(init_x, init_y, init_vx, init_vy)
	if i then
		local entry = world.move_point_history[i]
		if entry.stop then
			-- Detected redundant calls to debug_trace_move_point_end,
			-- returning false to make the assert fail.
			print(string.format("Redundant debug_trace_move_point_end(%g, %g, %g, %g)", init_x, init_y, init_vx, init_vy))
			debug_trace_move_point_dump()
			return false
		end

		entry.stop = {end_x, end_y, end_vx, end_vy, hit_tile_x, hit_tile_y}
		entry.steps = steps
		table.insert(entry.comments, comment)

		-- Check that the distance moved from initial position to final
		-- position is obtainable given the initial velocity.
		local d_actual <const> = sqrt(distance2(end_x - init_x, end_y - init_y))
		local d_max <const> = sqrt(distance2(init_vx, init_vy))
		if d_actual > d_max + 4 then
			print(string.format("expected max distance = %g, actual distance = %g", d_max, d_actual))
			debug_trace_move_point_dump()
			return false
		end
		return true
	end

	-- Unmatched debug_trace_move_point_end without a corresponding
	-- debug_trace_move_point_begin, returning false to make the assert fail.
	print(string.format("Unmatched debug_trace_move_point_end(%g, %g, %g, %g)", init_x, init_y, init_vx, init_vy))
	debug_trace_move_point_dump()
	return false
end

-- Append extra comments to an existing move log entry with matching comment.
local function debug_trace_move_point_match_and_append(key, comment)
	for i = 1, #world.move_point_history do
		local entry = world.move_point_history[i]
		for j = 1, #entry.comments do
			if string.find(entry.comments[j], key) then
				table.insert(entry.comments, comment)
				return true
			end
		end
	end
	return true
end

-- Output ball history and move history.
local function dump_ball_history()
	local output_header = true
	for i = -5, -1 do
		local j <const> = (world.ball_history_index + i) & BALL_HISTORY_MASK
		local h <const> = world.ball_position_history[j]
		if h then
			local x <const> = h[1]
			local y <const> = h[2]
			if output_header then
				print("ball_position_history:")
				output_header = false
			end
			if x and y then
				print(string.format("[%d] %g, %g", i, x, y))
			elseif x then
				print(string.format("[%d] %g, nil", i, x))
			elseif y then
				print(string.format("[%d] nil, %g", i, y))
			else
				print(string.format("[%d] nil, nil", i))
			end
		end
	end
	debug_trace_move_point_dump()
end

-- Normally we shouldn't have to adjust more than a handful of pixels with
-- try_digging_ball_out_of_walls, but if we have to adjust a lot, something
-- probably went wrong.  Log an extra entry for that case.
local function debug_log_excessive_adjustment(x, y, vx, vy, new_x, new_y, new_vx, new_vy, dx, dy)
	if abs(dx) > 2 or abs(dy) > 2 then
		print(string.format("move_ball(%g,%g,%g,%g) -> (%g,%g,%g,%g): adjustment (%g,%g)", x, y, vx, vy, new_x, new_y, new_vx, new_vy, dx, dy))
		dump_ball_history()
	end
	return true
end

-- Annotate a point of interest entry.  When the debug build of the game is
-- running inside the simulator, we would be able to verify which source is
-- responsible for the currently available action target by running this in
-- the console:
--
--    print(arm.action_target.source)
--
-- This is used to check if insert_extra_mount_point and
-- append_ledge_mount_point are working as expected.
local function debug_trace_poi(poi_list, index, source_annotation)
	poi_list[index].source = source_annotation
	return true
end

-- Return string label corresponding to collision bits.
local function collision_label(bits)
	bits &= COLLISION_MASK
	if bits == COLLISION_SQUARE then
		return "square"
	elseif bits == COLLISION_UP_LEFT then
		return "up_left"
	elseif bits == COLLISION_UP_RIGHT then
		return "up_right"
	elseif bits == COLLISION_DOWN_LEFT then
		return "down_left"
	elseif bits == COLLISION_DOWN_RIGHT then
		return "down_right"
	end
	assert(bits == world.COLLISION_NONE)
	return "none"
end

--}}}

----------------------------------------------------------------------
--{{{ Local functions.

-- Convert world coordinates to tile coordinates.
local function get_tile_position(x, y)
	assert(x >= 0)
	assert(y >= 0)
	local grid_x <const> = (x >> 5) + 1
	local grid_y <const> = (y >> 5) + 1
	return grid_x, grid_y
end

-- Initialize one set of tiles and sprites.
local function init_world_tilemap(tilemap, tilemap_sprite, z_index)
	tilemap:setImageTable(world_tiles)
	tilemap:setSize(GRID_W, GRID_H)

	tilemap_sprite:setTilemap(tilemap)
	tilemap_sprite:setZIndex(z_index)
	tilemap_sprite:add()
	tilemap_sprite:setCenter(0, 0)
	tilemap_sprite:setVisible(false)
end

-- Unpack run-length encoded tiles.
local function unpack_tiles(tiles)
	local unpacked_tiles = table.create(tiles[1], 0)
	local o = 1
	for i = 2, #tiles do
		if tiles[i] < 0 then
			-- A run of blank tiles.
			for j = 1, -tiles[i] do
				unpacked_tiles[o] = -1
				o += 1
			end
		else
			if tiles[i] > 0xffff then
				-- Two non-blank tiles packed in one.
				unpacked_tiles[o] = tiles[i] >> 16
				o += 1
				unpacked_tiles[o] = tiles[i] & 0xffff
				o += 1
			else
				-- A single non-blank tile.
				unpacked_tiles[o] = tiles[i]
				o += 1
			end
		end
	end
	return unpacked_tiles
end

-- Sort points of interest list by distance.
--
-- We could have succinctly implemented this with table.sort(), but because
-- our input size is small (~5 elements on average and 25 elements max), we
-- are able to outperform table.sort() on the average case due to insertion
-- sort being better suited for small inputs, and also because we are able
-- to inline the comparisons.
--
-- On the actual hardware, this function costs ~428ns for the average case,
-- compared to table.sort() at ~520ns.  So this function really is faster,
-- although it's probably not a big deal even if we had gone with table.sort().
local function sort_poi_list(poi_list)
	for i = 2, #poi_list do
		local j = i
		while j > 1 and poi_list[j - 1].d > poi_list[j].d do
			poi_list[j - 1], poi_list[j] = poi_list[j], poi_list[j - 1]
			j -= 1
		end
	end
end

local function test_sort_poi_list()
	local a = {{d = 3}, {d = 1}, {d = 4}}
	sort_poi_list(a)
	assert(a[1].d == 1)
	assert(a[2].d == 3)
	assert(a[3].d == 4)

	for size = 1, 5 do
		a = {}
		for i = 1, size do
			table.insert(a, {d = i})
		end
		sort_poi_list(a)
		for i = 1, size do
			assert(a[i].d == i, string.format("size = %d: a[i].d == i", size))
		end

		a = {}
		for i = size, 1, -1 do
			table.insert(a, {d = i})
		end
		sort_poi_list(a)
		for i = 1, size do
			assert(a[i].d == i, string.format("size = %d: a[i].d == i", size))
		end
	end
	return true
end
assert(test_sort_poi_list())

-- Check if metadata at a particular grid coordinate matches the expected bits,
-- for use with world.add_tile_hints.
local function matched_metadata_bits(grid_x, grid_y, mask, bits)
	if not world.metadata[grid_y] then
		return false
	end
	local cell <const> = world.metadata[grid_y][grid_x]
	return cell and
	       ((bits ~= 0 and (cell & mask) == bits) or
	        (bits == 0 and (cell & mask) ~= 0))
end

-- Syntactic sugar, check if x is between a and b, exclusive.
local function between(a, x, b)
	return (a < x and x < b) or (b < x and x < a)
end

-- Optionally prepend an extra mount point to list of points of interest.
--
-- If the two nearest points of interest are both mount points with the
-- same mount angle, and the two tiles are adjacent, then every point that
-- is on the line segment between the two mount points are also valid
-- mount points.  We could have inserted more mount points in between if
-- world definition wasn't grid-based.  This function fills that gap, by
-- inserting one extra mount point if there exists a point that is closer
-- than the top two mount points.
--
-- The new mount point is still subject to eligibility checks, so we might
-- end up picking one of the grid-based mount points after all.  But for
-- all the places where it does work, it would allow the player to escape
-- the confines of grid granularity.
--
-- See also append_unaligned_mount_points.
local function insert_extra_mount_point(poi_list, hand_x, hand_y)
	assert(#poi_list >= 2)
	assert(hand_x == floor(hand_x))
	assert(hand_y == floor(hand_y))

	if poi_list[1].kind ~= world.MOUNT or
	   poi_list[2].kind ~= world.MOUNT or
	   poi_list[1].a ~= poi_list[2].a then
		return
	end

	if poi_list[1].a == 0 or poi_list[1].a == 180 then
		-- Vertical wall.
		if poi_list[1].x == poi_list[2].x and
		   abs(poi_list[1].y - poi_list[2].y) == TILE_SIZE and
		   between(poi_list[1].y, hand_y, poi_list[2].y) then
			table.insert(poi_list, 1,
			             {
			                kind = world.MOUNT,
			                x = poi_list[1].x,
			                y = hand_y,
			                a = poi_list[1].a,
			             })
			assert(debug_trace_poi(poi_list, 1, "insert_extra_mount_point (vertical)"))
		end

	elseif poi_list[1].a == 90 or poi_list[1].a == 270 then
		-- Horizontal wall.
		if poi_list[1].y == poi_list[2].y and
		   abs(poi_list[1].x - poi_list[2].x) == TILE_SIZE and
		   between(poi_list[1].x, hand_x, poi_list[2].x) then
			table.insert(poi_list, 1,
			             {
			                kind = world.MOUNT,
			                x = hand_x,
			                y = poi_list[1].y,
			                a = poi_list[1].a,
			             })
			assert(debug_trace_poi(poi_list, 1, "insert_extra_mount_point (horizontal)"))
		end

	else
		-- Diagonal wall.  First check that the two tiles are adjacent.
		if abs(poi_list[1].x - poi_list[2].x) ~= TILE_SIZE or
		   abs(poi_list[1].y - poi_list[2].y) ~= TILE_SIZE then
			return
		end
		assert(poi_list[1].x % TILE_SIZE == HALF_TILE_SIZE)
		assert(poi_list[1].y % TILE_SIZE == HALF_TILE_SIZE)
		assert(poi_list[2].x % TILE_SIZE == HALF_TILE_SIZE)
		assert(poi_list[2].y % TILE_SIZE == HALF_TILE_SIZE)

		if poi_list[1].a == 135 or poi_list[1].a == 315 then
			-- Normal vectors for the two tiles are parallel to the line "y=-x+b".
			-- First, find the Y-intercept for the two lines the passes through
			-- the two mount points.
			local b1 <const> = poi_list[1].y + poi_list[1].x
			local b2 <const> = poi_list[2].y + poi_list[2].x

			-- Find the Y-intercept for the line that passes through the hand,
			-- and confirm that it falls between the two normal vectors.
			--
			-- Note how we drop the lowest bit to force the sum to be even.
			-- We do this truncation here before calculating the intersection
			-- to guarantee that intersection coordinates will be integer, and
			-- be on the y=x line.  If we calculate the intersection first and
			-- then round the results, there is no guarantee that this rounded
			-- result will land on the y=x line.
			local bh <const> = (hand_y + hand_x) & ~1
			if not between(b1, bh, b2) then return end

			-- Find the Y-intercept of the line that goes through poi_list[1]
			-- and poi_list[2].  This will be a line of the form "y=x+b".
			--
			-- This Y-intercept is always even, because the original mount
			-- points came from the center of the tiles at (+16,+16).
			local bw <const> = poi_list[1].y - poi_list[1].x
			assert(poi_list[2].y == poi_list[2].x + bw)
			assert(bw == floor(bw))
			assert((bw & 1) == 0)

			-- The intersection between the lines "y=-x+bh" and "y=x+bw" is
			-- where the new mount point will be.
			--
			-- Because we forced "bh" to be even earlier, and "bw" is always
			-- even, the sum here is guaranteed to be divisible by 2.
			local my <const> = (bh + bw) / 2
			assert(my == floor(my))
			local mx <const> = my - bw
			assert(mx % 32 == my % 32)
			table.insert(poi_list, 1,
			             {
			                kind = world.MOUNT,
			                x = mx,
			                y = my,
			                a = poi_list[1].a,
			             })
			assert(debug_trace_poi(poi_list, 1, "insert_extra_mount_point (diagonal 1)"))

		else
			-- The other diagonal wall.  It's similar to the earlier branch
			-- except the normal vectors are parallel to "y=x+b", so we adjust
			-- the equations accordingly.
			assert(poi_list[1].a == 45 or poi_list[1].a == 225)
			local b1 <const> = poi_list[1].y - poi_list[1].x
			local b2 <const> = poi_list[2].y - poi_list[2].x
			local bh <const> = (hand_y - hand_x) & ~1
			if not between(b1, bh, b2) then return end

			local bw <const> = poi_list[1].y + poi_list[1].x
			assert(poi_list[2].y == -poi_list[2].x + bw)

			-- The intersection between the lines "y=x+bh" and "y=-x+bw" is
			-- where the new mount point will be.
			local my <const> = (bh + bw) / 2
			assert(my == floor(my))
			local mx <const> = my - bh
			assert((mx + my) % 32 == 0)
			table.insert(poi_list, 1,
			             {
			                kind = world.MOUNT,
			                x = mx,
			                y = my,
			                a = poi_list[1].a,
			             })
			assert(debug_trace_poi(poi_list, 1, "insert_extra_mount_point (diagonal 2)"))
		end
	end
end

local function test_insert_extra_mount_point()
	local poi_list = {}

	-- Test vertical wall.
	poi_list =
	{
		{kind = world.MOUNT, x = 31, y = 16, a = 180},
		{kind = world.MOUNT, x = 31, y = 48, a = 180},
	}
	insert_extra_mount_point(poi_list, 95, 15)
	assert(#poi_list == 2)
	insert_extra_mount_point(poi_list, 95, 16)
	assert(#poi_list == 2)
	insert_extra_mount_point(poi_list, 95, 49)
	assert(#poi_list == 2)
	insert_extra_mount_point(poi_list, 95, 48)
	assert(#poi_list == 2)
	insert_extra_mount_point(poi_list, 95, 37)
	assert(#poi_list == 3)
	assert(poi_list[1].kind == world.MOUNT)
	assert(poi_list[1].x == 31)
	assert(poi_list[1].y == 37)
	assert(poi_list[1].a == 180)

	poi_list =
	{
		{kind = world.MOUNT, x = 31, y = 16, a = 180},
		{kind = world.MOUNT, x = 31, y = 48, a = 225},  -- Mismatched angle.
	}
	insert_extra_mount_point(poi_list, 95, 37)
	assert(#poi_list == 2)

	poi_list =
	{
		{kind = world.MOUNT, x = 31, y = 16, a = 180},
		{kind = world.MOUNT, x = 31, y = 80, a = 180},  -- Not adjacent.
	}
	insert_extra_mount_point(poi_list, 95, 37)
	assert(#poi_list == 2)

	-- Test horizontal wall.
	poi_list =
	{
		{kind = world.MOUNT, x = 16, y = 63, a = 270},
		{kind = world.MOUNT, x = 48, y = 63, a = 270},
	}
	insert_extra_mount_point(poi_list, 15, 127)
	assert(#poi_list == 2)
	insert_extra_mount_point(poi_list, 16, 127)
	assert(#poi_list == 2)
	insert_extra_mount_point(poi_list, 49, 127)
	assert(#poi_list == 2)
	insert_extra_mount_point(poi_list, 48, 127)
	assert(#poi_list == 2)
	insert_extra_mount_point(poi_list, 37, 127)
	assert(#poi_list == 3)
	assert(poi_list[1].kind == world.MOUNT)
	assert(poi_list[1].x == 37)
	assert(poi_list[1].y == 63)
	assert(poi_list[1].a == 270)

	poi_list =
	{
		{kind = world.MOUNT, x = 16, y = 63, a = 270},
		{kind = world.MOUNT, x = 48, y = 63, a = 315},  -- Mismatched angle.
	}
	insert_extra_mount_point(poi_list, 37, 127)
	assert(#poi_list == 2)

	poi_list =
	{
		{kind = world.MOUNT, x = 16, y = 63, a = 270},
		{kind = world.MOUNT, x = 80, y = 63, a = 270},  -- Not adjacent.
	}
	insert_extra_mount_point(poi_list, 37, 127)
	assert(#poi_list == 2)

	-- Test diagonal wall parallel to y=x.
	poi_list =
	{
		{kind = world.MOUNT, x = 80, y = 48, a = 225},
		{kind = world.MOUNT, x = 112, y = 16, a = 225},
	}
	insert_extra_mount_point(poi_list, 113, 81)
	assert(#poi_list == 2)
	insert_extra_mount_point(poi_list, 112, 80)
	assert(#poi_list == 2)
	insert_extra_mount_point(poi_list, 144, 48)
	assert(#poi_list == 2)
	insert_extra_mount_point(poi_list, 143, 47)
	assert(#poi_list == 2)
	insert_extra_mount_point(poi_list, 144, 80)
	assert(#poi_list == 3)
	assert(poi_list[1].kind == world.MOUNT)
	assert(poi_list[1].x == 96)
	assert(poi_list[1].y == 32)
	assert(poi_list[1].a == 225)

	-- Test diagonal with odd (as opposed to even) input coordinates.
	poi_list =
	{
		{kind = world.MOUNT, x = 80, y = 48, a = 225},
		{kind = world.MOUNT, x = 112, y = 16, a = 225},
	}
	insert_extra_mount_point(poi_list, 143, 80)
	assert(#poi_list == 3)
	assert(poi_list[1].kind == world.MOUNT)
	assert(poi_list[1].x == 96)
	assert(poi_list[1].y == 32)
	assert(poi_list[1].a == 225)

	poi_list =
	{
		{kind = world.MOUNT, x = 80, y = 48, a = 225},
		{kind = world.MOUNT, x = 112, y = 16, a = 225},
	}
	insert_extra_mount_point(poi_list, 142, 81)
	assert(#poi_list == 3)
	assert(poi_list[1].kind == world.MOUNT)
	assert(poi_list[1].x == 95)
	assert(poi_list[1].y == 33)
	assert(poi_list[1].a == 225)

	-- Test error cases.
	poi_list =
	{
		{kind = world.MOUNT, x = 80, y = 48, a = 225},
		{kind = world.MOUNT, x = 112, y = 48, a = 225},  -- Not adjacent.
	}
	insert_extra_mount_point(poi_list, 144, 80)
	assert(#poi_list == 2)

	poi_list =
	{
		{kind = world.MOUNT, x = 80, y = 48, a = 225},
		{kind = world.MOUNT, x = 144, y = 48, a = 225},  -- Not adjacent.
	}
	insert_extra_mount_point(poi_list, 144, 80)
	assert(#poi_list == 2)

	-- Test diagonal wall parallel to y=-x.
	poi_list =
	{
		{kind = world.MOUNT, x = 144, y = 48, a = 315},
		{kind = world.MOUNT, x = 176, y = 80, a = 315},
	}
	insert_extra_mount_point(poi_list, 111, 79)
	assert(#poi_list == 2)
	insert_extra_mount_point(poi_list, 112, 80)
	assert(#poi_list == 2)
	insert_extra_mount_point(poi_list, 144, 112)
	assert(#poi_list == 2)
	insert_extra_mount_point(poi_list, 143, 113)
	assert(#poi_list == 2)
	insert_extra_mount_point(poi_list, 112, 112)
	assert(#poi_list == 3)
	assert(poi_list[1].kind == world.MOUNT)
	assert(poi_list[1].x == 160)
	assert(poi_list[1].y == 64)
	assert(poi_list[1].a == 315)

	-- Test diagonal with odd input coordinates.
	poi_list =
	{
		{kind = world.MOUNT, x = 144, y = 48, a = 315},
		{kind = world.MOUNT, x = 176, y = 80, a = 315},
	}
	insert_extra_mount_point(poi_list, 112, 113)
	assert(#poi_list == 3)
	assert(poi_list[1].kind == world.MOUNT)
	assert(poi_list[1].x == 160)
	assert(poi_list[1].y == 64)
	assert(poi_list[1].a == 315)

	poi_list =
	{
		{kind = world.MOUNT, x = 144, y = 48, a = 315},
		{kind = world.MOUNT, x = 176, y = 80, a = 315},
	}
	insert_extra_mount_point(poi_list, 113, 112)
	assert(#poi_list == 3)
	assert(poi_list[1].kind == world.MOUNT)
	assert(poi_list[1].x == 160)
	assert(poi_list[1].y == 64)
	assert(poi_list[1].a == 315)

	-- Test error cases.
	poi_list =
	{
		{kind = world.MOUNT, x = 144, y = 48, a = 315},
		{kind = world.MOUNT, x = 208, y = 80, a = 315},  -- Not adjacent.
	}
	insert_extra_mount_point(poi_list, 112, 112)
	assert(#poi_list == 2)

	poi_list =
	{
		{kind = world.MOUNT, x = 144, y = 48, a = 315},
		{kind = world.MOUNT, x = 208, y = 112, a = 315},  -- Not adjacent.
	}
	insert_extra_mount_point(poi_list, 112, 112)
	assert(#poi_list == 2)

	return true
end
assert(test_insert_extra_mount_point())

-- For every horizontal and vertical mount point, append extra mount points
-- that are at +/-1 pixel offsets.
--
-- Due to how the joints lined up, there are some steps that require mount
-- a tile at an off-centered position.  A common example is trying to reach
-- the other end of a thin ledge, where both ends of the arm touch the same
-- tile during the move but the mount points are misaligned by one pixel.
--
--                           mounted wrist
--          +-------------+----------------+-----------+----
--          |             |   X = center   |           |
--    empty | unmountable |                | mountable | ...
--          |             | X = center + 1 |           |
--          +-------------+----------------+-----------+----
--                           tip of hand
--
-- Because the mount point needs to be off by one pixel, it's not discovered
-- in the normal search loop.  This means to get across the ledge, the
-- player will need to position the hand at just the right position for
-- insert_extra_mount_point to take effect.  This makes going across ledges
-- more difficult than needed.
--
-- This function expands the points of interest list by appending mount
-- points with +/-1 pixel offset for every mount point, which makes those
-- difficult to reach spots more easily accessible without having to depend
-- on insert_extra_mount_point.  We used to do this for just the ledges, but
-- turns out there are many paths that depend on this 1 pixel offset, so now
-- we do it generically.
--
-- Note that even though this is mainly intended to help with the poses where
-- one of the mount points is aligned to tile center, this function doesn't
-- check for alignment, so a mount point added by insert_extra_mount_point
-- is also eligible for extra mount points being added.
local function append_unaligned_mount_points(poi_list)
	local poi_count <const> = #poi_list
	local w = poi_count
	for r = 1, poi_count do
		local entry <const> = poi_list[r]
		if entry.kind == world.MOUNT then
			local tile_x <const>, tile_y <const> = get_tile_position(entry.x, entry.y)
			if entry.a == 0 then
				-- Add Y-1 mount if neighbor above shares the same mount bit.
				if (world.metadata[tile_y - 1][tile_x] & MOUNT_LEFT) ~= 0 then
					w += 1
					poi_list[w] =
					{
						kind = world.MOUNT,
						x = entry.x,
						y = entry.y - 1,
						a = 0,
					}
					assert(debug_trace_poi(poi_list, w, "append_unaligned_mount_points (MOUNT_LEFT, y-1)"))
				end

				-- Add Y+1 mount if neighbor below shares the same mount bit.
				if (world.metadata[tile_y + 1][tile_x] & MOUNT_LEFT) ~= 0 then
					w += 1
					poi_list[w] =
					{
						kind = world.MOUNT,
						x = entry.x,
						y = entry.y + 1,
						a = 0,
					}
					assert(debug_trace_poi(poi_list, w, "append_unaligned_mount_points (MOUNT_LEFT, y+1)"))
				end

			elseif entry.a == 180 then
				-- Add Y+1 mount if neighbor below shares the same mount bit.
				--
				-- Unlike the branch above, here we check for Y+1 followed by
				-- Y-1.  This is for rotational symmetry, basically we are
				-- appending extra points in clockwise order.
				if (world.metadata[tile_y + 1][tile_x] & MOUNT_RIGHT) ~= 0 then
					w += 1
					poi_list[w] =
					{
						kind = world.MOUNT,
						x = entry.x,
						y = entry.y + 1,
						a = 180,
					}
					assert(debug_trace_poi(poi_list, w, "append_unaligned_mount_points (MOUNT_RIGHT, y+1)"))
				end

				-- Add Y-1 mount if neighbor above shares the same mount bit.
				if (world.metadata[tile_y - 1][tile_x] & MOUNT_RIGHT) ~= 0 then
					w += 1
					poi_list[w] =
					{
						kind = world.MOUNT,
						x = entry.x,
						y = entry.y - 1,
						a = 180,
					}
					assert(debug_trace_poi(poi_list, w, "append_unaligned_mount_points (MOUNT_RIGHT, y-1)"))
				end

			elseif entry.a == 90 then
				-- Add X+1 mount if neighbor to the right shares the same mount bit.
				if (world.metadata[tile_y][tile_x + 1] & MOUNT_UP) ~= 0 then
					w += 1
					poi_list[w] =
					{
						kind = world.MOUNT,
						x = entry.x + 1,
						y = entry.y,
						a = 90,
					}
					assert(debug_trace_poi(poi_list, w, "append_unaligned_mount_points (MOUNT_UP, x+1)"))
				end

				-- Add X-1 mount if neighbor to the left shares the same mount bit.
				if (world.metadata[tile_y][tile_x - 1] & MOUNT_UP) ~= 0 then
					w += 1
					poi_list[w] =
					{
						kind = world.MOUNT,
						x = entry.x - 1,
						y = entry.y,
						a = 90,
					}
					assert(debug_trace_poi(poi_list, w, "append_unaligned_mount_points (MOUNT_UP, x-1)"))
				end

			elseif entry.a == 270 then
				-- Add X-1 mount if neighbor to the left shares the same mount bit.
				--
				-- Similar to the vertical cases, in this branch we are checking
				-- for X-1 followed by X+1, whereas previous branch we check for
				-- X+1 followed by X-1.  This is for rotational symmetry.
				if (world.metadata[tile_y][tile_x - 1] & MOUNT_DOWN) ~= 0 then
					w += 1
					poi_list[w] =
					{
						kind = world.MOUNT,
						x = entry.x - 1,
						y = entry.y,
						a = 270,
					}
					assert(debug_trace_poi(poi_list, w, "append_unaligned_mount_points (MOUNT_DOWN, x-1)"))
				end

				-- Add X+1 mount if neighbor to the right shares the same mount bit.
				if (world.metadata[tile_y][tile_x + 1] & MOUNT_DOWN) ~= 0 then
					w += 1
					poi_list[w] =
					{
						kind = world.MOUNT,
						x = entry.x + 1,
						y = entry.y,
						a = 270,
					}
					assert(debug_trace_poi(poi_list, w, "append_unaligned_mount_points (MOUNT_DOWN, x+1)"))
				end
			end
		end
	end
end

local function test_append_unaligned_mount_points()
	-- Verify the extra mount points added for each existing point.
	--
	-- Input data are invisible collision rectangles at (32,2560)..(256,2592)
	-- and (128,2688)..(160,2912)
	local test_points <const> =
	{
		-- Zero output points.
		{in_x=304, in_y=304, a=225},
		{in_x=272, in_y=304, a=45},
		-- One output point.
		{in_x=80,  in_y=2560, x=81,  y=2560, a=270},
		{in_x=208, in_y=2560, x=207, y=2560, a=270},
		{in_x=80,  in_y=2591, x=81,  y=2591, a=90},
		{in_x=208, in_y=2591, x=207, y=2591, a=90},
		{in_x=128, in_y=2736, x=128, y=2737, a=0},
		{in_x=128, in_y=2864, x=128, y=2863, a=0},
		{in_x=159, in_y=2736, x=159, y=2737, a=180},
		{in_x=159, in_y=2864, x=159, y=2863, a=180},
		-- Two output points.
		{in_x=144, in_y=2560, x=143, y=2560, x2=145, y2=2560, a=270},
		{in_x=144, in_y=2591, x=145, y=2591, x2=143, y2=2591, a=90},
		{in_x=128, in_y=2800, x=128, y=2799, x2=128, y2=2801, a=0},
		{in_x=159, in_y=2800, x=159, y=2801, x2=159, y2=2799, a=180},
	}
	for i = 1, #test_points do
		local t <const> = test_points[i]
		local poi_list =
		{
			{
				kind = world.MOUNT,
				x = t.in_x,
				y = t.in_y,
				a = t.a
			}
		}
		append_unaligned_mount_points(poi_list)
		if t.x then
			-- Expect 1 or 2 added points.
			if t.x2 then
				assert(#poi_list == 3, string.format("test_points[%d]: #poi_list == 3", i))
			else
				assert(#poi_list == 2, string.format("test_points[%d]: #poi_list == 2", i))
			end

			assert(poi_list[2].kind == world.MOUNT, string.format("test_points[%d]: poi_list[2].kind == world.MOUNT", i))
			assert(poi_list[2].x == t.x, string.format("test_points[%d]: poi_list[2].x (%d) == t.x (%d)", i, poi_list[2].x, t.x))
			assert(poi_list[2].y == t.y, string.format("test_points[%d]: poi_list[2].y (%d) == t.y (%d)", i, poi_list[2].y, t.y))
			assert(poi_list[2].a == t.a, string.format("test_points[%d]: poi_list[2].a (%d) == t.a (%d)", i, poi_list[2].a, t.a))
			if t.x2 then
				assert(poi_list[3].kind == world.MOUNT, string.format("test_points[%d]: poi_list[3].kind == world.MOUNT", i))
				assert(poi_list[3].x == t.x2, string.format("test_points[%d]: poi_list[3].x (%d) == t.x2 (%d)", i, poi_list[3].x, t.x2))
				assert(poi_list[3].y == t.y2, string.format("test_points[%d]: poi_list[3].y (%d) == t.y2 (%d)", i, poi_list[3].y, t.y2))
				assert(poi_list[3].a == t.a, string.format("test_points[%d]: poi_list[3].a (%d) == t.a (%d)", i, poi_list[3].a, t.a))
			end

		else
			-- Expect 0 added points.
			assert(#poi_list == 1, string.format("test_points[%d]: #poi_list == 1", i))
		end
	end
	return true
end
assert(test_append_unaligned_mount_points())

-- Check that a diagonal mount surface with negative slope is facing the hand.
--
-- y = -x + b  ->  b = y + x
local function is_up_left_facing_hand(x, y, hand_x, hand_y)
	return y + x >= hand_y + hand_x
end
local function is_down_right_facing_hand(x, y, hand_x, hand_y)
	return y + x <= hand_y + hand_x
end

-- Check that a diagonal mount surface with positive slope is facing the hand.
--
-- y = x + b  ->  b = y - x
local function is_up_right_facing_hand(x, y, hand_x, hand_y)
	return y - x >= hand_y - hand_x
end
local function is_down_left_facing_hand(x, y, hand_x, hand_y)
	return y - x <= hand_y - hand_x
end

-- Syntactic sugar, check a 3x2 grid area and returns true if it's
-- freed of obstacles.
local function has_3x2_clearance(x, y)
	local row0 <const> = world.metadata[y]
	local row1 <const> = world.metadata[y + 1]
	return (row0[x] | row0[x + 1] | row0[x + 2] |
	        row1[x] | row1[x + 1] | row1[x + 2]) &
	       (COLLISION_MASK | COLLECTIBLE_MASK) == 0
end

-- Syntactic sugar, check a 2x3 grid area and returns true if it's
-- freed of obstacles.
local function has_2x3_clearance(x, y)
	local row0 <const> = world.metadata[y]
	local row1 <const> = world.metadata[y + 1]
	local row2 <const> = world.metadata[y + 2]
	return (row0[x] | row0[x + 1] |
	        row1[x] | row1[x + 1] |
	        row2[x] | row2[x + 1]) &
	       (COLLISION_MASK | COLLECTIBLE_MASK) == 0
end

-- Syntactic sugar, check for clearance around collectible tile.
local function is_reachable_from_above(x, y)
	local row0 <const> = world.metadata[y - 1]
	local row1 <const> = world.metadata[y]
	return (row0[x - 1] | row0[x] | row0[x + 1] |
	        row1[x - 1] |           row1[x + 1]) & COLLISION_MASK == 0
end
local function is_reachable_from_below(x, y)
	local row0 <const> = world.metadata[y]
	local row1 <const> = world.metadata[y + 1]
	return (row0[x - 1] |           row0[x + 1] |
	        row1[x - 1] | row1[x] | row1[x + 1]) & COLLISION_MASK == 0
end
local function is_reachable_from_left(x, y)
	local row0 <const> = world.metadata[y - 1]
	local row1 <const> = world.metadata[y]
	local row2 <const> = world.metadata[y + 1]
	return (row0[x - 1] | row0[x] |
	        row1[x - 1] |
	        row2[x - 1] | row2[x]) & COLLISION_MASK == 0
end
local function is_reachable_from_right(x, y)
	local row0 <const> = world.metadata[y - 1]
	local row1 <const> = world.metadata[y]
	local row2 <const> = world.metadata[y + 1]
	return (row0[x] | row0[x + 1] |
	                  row1[x + 1] |
	        row2[x] | row2[x + 1]) & COLLISION_MASK == 0
end

-- Check if tile at a particular position is empty.  We need this because
-- a grid cell does not get a value of -1 even if we call setTileAtPosition
-- with -1.  Instead, we check for the grid cell containing an invalid tile
-- value to determine emptiness.  Empirically, the empty tile value appears
-- to be 0x10000, but the documentation makes no promise of that.
local function is_empty_foreground_tile(tile_x, tile_y)
	local tile <const> = world_grid_fg[0]:getTileAtPosition(tile_x, tile_y)
	return tile > world.UNIQUE_TILE_COUNT or tile < 1
end

-- This function is just like is_empty_foreground_tile above, but here we
-- check all the frames instead of just the first frame.
--
-- This function is used to decide if a cell is paintable, by checking if
-- it's empty at all frames.  Checking just the first frame would have worked
-- in over 99% of the cases, but for the few edge cases where they differ,
-- painting over those tiles would visually corrupt the background tiles.
--
-- There are really only so few tiles where the emptiness status differs
-- between frames, and even fewer when we consider only those tiles that
-- are reachable.  The set of tiles where it matters can be found by
-- building "debug_paintable_tiles.png" in the data directory.  One known
-- reachable spot where it makes a difference is at (9280,6016).
local function is_empty_background_tile(tile_x, tile_y)
	for i = 0, 3 do
		local tile <const> = world_grid_bg[i]:getTileAtPosition(tile_x, tile_y)
		if tile >= 1 and tile <= world.UNIQUE_TILE_COUNT then
			return false
		end
	end
	return true
end

-- Check if a particular background tile is animated.  We use this to determine
-- if a removed tile was some landscape (static) or some foe (animated).
local function is_animated_background_tile(tile_x, tile_y)
	return world_grid_bg[0]:getTileAtPosition(tile_x, tile_y) ~=
	       world_grid_bg[1]:getTileAtPosition(tile_x, tile_y)
end

-- Get index of the teleport station closest to a particular coordinate.
-- Returns -1 if there isn't any that's visible on screen.
--
-- It might seem redundant that we are checking both distance to point and
-- on-screen visibility, but we need both:
--
-- + In theory, we could check just on-screen visibility, and register
--   teleport stations as part of world.update_viewport().  But this may
--   cause us to add teleport station in the middle of a teleport, when the
--   screen rapidly scrolls past some teleport station.
--
--   One possible tweak might be to add teleport stations only when the
--   scroll speed is sufficiently slow, but this seems fragile, since scroll
--   speed is something of a background magic, and we don't necessarily have
--   a good handle on when the scroll speed would reach a desired threshold.
--
-- + We could just check distance to point without checking visibility, but
--   this will lead to a situation where some teleport stations on the
--   opposite of a wall is automatically added.  We exploit this as a puzzle
--   element (i.e. places that are only reachable by teleport, but if you can
--   see the destination teleport station), but in general it's difficult to
--   design levels with only a distance constraint, because either the
--   distance will need to be small or the walls will need to be thick.
local function get_nearest_visible_teleport_station(x, y)
	for i = 1, #world.TELEPORT_POSITIONS do
		-- TELEPORT_POSITIONS contains the base coordinates, at the center
		-- of the top tile edge.  We want the top left corner of the
		-- teleport station sign.
		local sign_x <const> = world.TELEPORT_POSITIONS[i][1] - 16
		local sign_y <const> = world.TELEPORT_POSITIONS[i][2] - 96

		if abs(x - sign_x) < SCREEN_WIDTH and abs(y - sign_y) < SCREEN_HEIGHT then
			-- Found one that's within a screen distance from desired coordinate.
			-- Now we will check if it's actually visible.
			--
			-- The +/-15 offsets here are meant to encode the heuristic of
			-- declaring visibility if majority of the sign is visible, even if
			-- some of the pixels are still out of bounds.
			local screen_x <const> = sign_x + world.sprite_offset_x
			local screen_y <const> = sign_y + world.sprite_offset_y
			if screen_x >= -15 and
			   screen_y >= -15 and
			   screen_x <= SCREEN_WIDTH + 15 - TILE_SIZE and
			   screen_y <= SCREEN_HEIGHT + 15 - TILE_SIZE then
				-- Found a station that is within a screen distance away from
				-- desired coordinate, and is visible.
				return i
			end

			-- This teleport station is not visible, and we are not going to
			-- find another one that's closer because there are never two
			-- teleport stations on the same screen due to how we design the
			-- levels, so we can stop early.
			return -1
		end
	end

	-- Didn't find anything nearby.
	return -1
end

-- Remove tile and update undo list.
local function remove_tile(tile_x, tile_y, grid, true_if_fg)
	assert(tile_x >= 1)
	assert(tile_y >= 1)

	local a = #world.removed_tiles + 1
	if true_if_fg then
		world.removed_tiles[a] = (tile_x << 9) | tile_y
	else
		world.removed_tiles[a] = -((tile_x << 9) | tile_y)
	end
	world.removed_tiles[a + 1] = world.metadata[tile_y][tile_x]
	for i = 0, 3 do
		assert(grid[i])
		assert(tile_x <= ({grid[i]:getSize()})[1])
		assert(tile_y <= ({grid[i]:getSize()})[2])
		grid[i]:setTileAtPosition(tile_x, tile_y, EMPTY_TILE)
	end
end

-- Add exploding debris.
local function add_debris(world_x, world_y, start_frame)
	-- Initialize sprite.
	--
	-- Note that sprite is not centered.  We originally drew the debris in
	-- 96x96 tiles, which were centered at (48,48), but after cropping to
	-- remove excessive space around the margins, the sprites are no longer
	-- centered (because the pieces fly off at different distances).  The
	-- (-19,-11) offsets below account for the difference from upper left
	-- corner of the affected tile to upper left corner of debris tiles.
	local s = gfx.sprite.new()
	s:setImage(debris_images:getImage(start_frame + 1))
	s:add()
	s:setCenter(0, 0)
	s:moveTo(world_x - 19, world_y - 11)
	s:setVisible(true)
	s:setZIndex(Z_DEBRIS)

	-- Append timer and sprite to debris table.
	table.insert(debris_sprites, {start_frame, s})
end

-- Compute completion marker sprite data.  Returns:
-- world_x, world_y, offset_x, offset_y, marker_tile_x
local function get_completion_marker_info()
	-- Compute position.  This is the position of where the marker would end
	-- up after all the animation is done.
	assert(world.last_item_tile_x)
	assert(world.last_item_tile_y)
	local lx <const> = world.last_item_tile_x
	local ly <const> = world.last_item_tile_y
	assert(lx == floor(lx))
	assert(ly == floor(ly))
	local x <const> = (lx - 1) << 5
	local y <const> = (ly - 1) << 5
	assert(x == (lx - 1) * TILE_SIZE)
	assert(y == (ly - 1) * TILE_SIZE)

	-- Compute offset direction.  This is the direction vector to the tile
	-- that the final item was attached.
	--
	-- The direction also decides which sprite we will use.  The indices
	-- are offsets to the last 4 tiles in the immutable background layer.
	--
	-- Note that this direction is computed by checking which wall the item
	-- was adjacent to, as opposed to checking COLLECTIBLE_MASK for the
	-- approach direction to the item.
	local dx, dy, marker_tile_x
	assert((world.metadata[ly][lx] & COLLECTIBLE_MASK) == 0)
	assert((world.metadata[ly][lx] & COLLISION_MASK) == 0)
	if (world.metadata[ly - 1][lx] & COLLISION_MASK) ~= 0 then
		-- Ceiling above.
		marker_tile_x = GRID_W - 2
		dx = 0
		dy = -1
	elseif (world.metadata[ly][lx - 1] & COLLISION_MASK) ~= 0 then
		-- Wall to the left.
		marker_tile_x = GRID_W - 1
		dx = -1
		dy = 0
	elseif (world.metadata[ly][lx + 1] & COLLISION_MASK) ~= 0 then
		-- Wall to the right.
		marker_tile_x = GRID_W
		dx = 1
		dy = 0
	else
		-- Default: assume floor below.
		--
		-- Note that this is also the orientation we will use if the item is not
		-- attached to any walls, e.g. if the item was attached to a breakable
		-- wall that was removed before the item is collected.  Those items
		-- visually appear to be floating in space just before they were
		-- collected, and using the upright orientation for completion flags
		-- look better.
		--
		-- This is also why we check adjacent tiles for flag orientation, as
		-- opposed to checking the approach direction bit on the collectible
		-- tile itself.
		marker_tile_x = GRID_W - 3
		dx = 0
		dy = 1
	end

	return x, y, dx, dy, marker_tile_x
end

-- Initialize completion marker for animation.
local function add_completion_marker()
	local x <const>, y <const>, dx <const>, dy <const>, marker_tile_x <const> =
		get_completion_marker_info()
	local tile_index <const> =
		world_grid_ibg[0]:getTileAtPosition(marker_tile_x, GRID_H)
	assert(tile_index >= 1)
	assert(tile_index <= world.UNIQUE_TILE_COUNT)

	-- Initialize sprite, place it behind a tile adjacent to where the last
	-- item was collected.
	completion_marker_sprite = gfx.sprite.new(world_tiles[tile_index])
	completion_marker_sprite:add()
	completion_marker_sprite:setCenter(0, 0)
	completion_marker_sprite:moveTo(x + dx * TILE_SIZE, y + dy * TILE_SIZE)
	completion_marker_sprite:setVisible(true)
	completion_marker_sprite:setZIndex(Z_COMPLETION_MARKER)

	-- Initialize timer for moving this sprite.
	completion_timer = TILE_SIZE
end

-- Animate completion marker.
local function animate_completion_marker()
	if not completion_timer then
		return
	end

	local x <const>, y <const>, dx <const>, dy <const>, marker_tile_x <const> =
		get_completion_marker_info()

	-- Bake the sprite into the background tilemap grids once it has moved
	-- into place.
	if completion_timer == 0 then
		for i = 0, 3 do
			assert(world_grid_bg[i])
			assert(world.last_item_tile_x >= 1)
			assert(world.last_item_tile_y >= 1)
			assert(world.last_item_tile_x <= ({world_grid_bg[i]:getSize()})[1])
			assert(world.last_item_tile_y <= ({world_grid_bg[i]:getSize()})[2])
			local tile_index <const> =
				world_grid_ibg[i]:getTileAtPosition(marker_tile_x, GRID_H)
			assert(tile_index >= 1)
			assert(tile_index <= world.UNIQUE_TILE_COUNT)
			world_grid_bg[i]:setTileAtPosition(world.last_item_tile_x,
			                                   world.last_item_tile_y,
			                                   tile_index)
		end
		completion_timer = nil
		completion_marker_sprite:remove()
		completion_marker_sprite = nil
		return
	end

	-- Move sprite until it has moved into position.
	completion_marker_sprite:moveTo(x + dx * completion_timer,
	                                y + dy * completion_timer)

	-- If completion marker is vertical, truncate the bottom so that it grows
	-- vertically.  We do this for vertical markers because we can, because
	-- sprite is rendered from top to bottom and setSize causes the bottom
	-- to be truncated.  For other orientations, it's less predictable what
	-- region will be drawn, so we don't truncate.
	--
	-- In most cases, we don't have to truncate the sprite because it would
	-- be drawn behind BG tiles, so part of the sprite will be hidden without
	-- us having to manually hide it.  But there are many parts of the map
	-- where the sprite will be drawn in front of IBG tiles and we can't do
	-- much about those.  We could add BG tiles near those items, if we
	-- remember to do it.
	if dy == 1 then
		assert(completion_timer <= TILE_SIZE)
		completion_marker_sprite:setSize(TILE_SIZE, TILE_SIZE - completion_timer + 1)
	end

	completion_timer -= 1
end

-- Check that all terminal reaction tiles are adjacent to at least one
-- chain reaction tile, returns true if so.
local function all_terminal_reactions_are_reachable()
	local count = 0
	for y = 1, GRID_H do
		for x = 1, GRID_W do
			if (world.metadata[y][x] & TERMINAL_REACTION) ~= 0 then
				count += 1
				local reachable <const> =
					(y > 1 and (world.metadata[y - 1][x] & CHAIN_REACTION) ~= 0) or
					(y < GRID_H and (world.metadata[y + 1][x] & CHAIN_REACTION) ~= 0) or
					(x > 1 and (world.metadata[y][x - 1] & CHAIN_REACTION) ~= 0) or
					(x < GRID_W and (world.metadata[y][x + 1] & CHAIN_REACTION) ~= 0)
				if not reachable then
					debug_log(string.format("terminal tile[%d][%d] (%d,%d) is unreachable", y, x, (x - 1) << 5, (y - 1) << 5))
				end
			end
		end
	end
	debug_log(count .. " terminal reaction tiles remaining")
	return true
end
assert(all_terminal_reactions_are_reachable())

-- Iterate on chain reaction tiles.
local function update_chain_reaction(start_tile_x, start_tile_y)
	assert((world.metadata[start_tile_y][start_tile_x] & BREAKABLE) == 0)
	assert((world.metadata[start_tile_y][start_tile_x] & CHAIN_REACTION) ~= 0)
	assert((world.metadata[start_tile_y][start_tile_x] & TERMINAL_REACTION) == 0)
	local expansion = {{start_tile_x, start_tile_y}}

	while true do
		if world.reset_requested then return end

		local next_expansion = {}

		local min_tile_x = nil
		local max_tile_x = nil
		local min_tile_y = nil
		local max_tile_y = nil
		for i = 1, #expansion do
			local tile_x <const> = expansion[i][1]
			local tile_y <const> = expansion[i][2]
			assert(world.metadata[tile_y][tile_x])

			-- Skip tiles that aren't mutable.  These are duplicate tiles due
			-- to overlapping neighbors from previous expansion.
			local tile_bits <const> = world.metadata[tile_y][tile_x]
			if (tile_bits & MUTABLE_TILE) == 0 then
				goto next_cell
			end

			-- Remove tile from foreground.
			remove_tile(tile_x, tile_y, world_grid_fg, true)

			if (tile_bits & BREAKABLE) ~= 0 then
				-- For breakable tiles, we will remove all collision bits that
				-- were attached to it, essentially resetting to an empty tile.
				-- Note that it's possible for collision bits to already be zero,
				-- which happens when the CHAIN_REACTION|BREAKABLE combination
				-- is used to encode non-triggering chain reactions.
				--
				-- Note: unlike tiles that do not have CHAIN_REACTION or
				-- TERMINAL_REACTION bits set, removing a tile due to chain
				-- reaction does *not* count against broken_tiles.  We could
				-- count them here if we wanted to, but we don't because these
				-- tiles were not broken directly with the robot arm.
				--
				-- See also world.is_valid_save_state().
				world.metadata[tile_y][tile_x] = 0
			else
				-- For unbreakable tiles, we will only clear the chain reaction
				-- or terminal reaction bits, such that each chain reaction can
				-- only trigger once.
				world.metadata[tile_y][tile_x] = tile_bits & ~REACTION_TILE
			end

			-- Keep track of modified tile range.
			if not min_tile_x then
				min_tile_x = tile_x
				min_tile_y = tile_y
				max_tile_x = tile_x
				max_tile_y = tile_y
			else
				min_tile_x = min(min_tile_x, tile_x)
				min_tile_y = min(min_tile_y, tile_y)
				max_tile_x = max(max_tile_x, tile_x)
				max_tile_y = max(max_tile_y, tile_y)
			end

			-- Expand to neighbors.
			if (tile_bits & CHAIN_REACTION) ~= 0 then
				if tile_x < GRID_W and
				   (world.metadata[tile_y][tile_x + 1] & REACTION_TILE) ~= 0 then
					table.insert(next_expansion, {tile_x + 1, tile_y})
				end
				if tile_y < GRID_H and
				   (world.metadata[tile_y + 1][tile_x] & REACTION_TILE) ~= 0 then
					table.insert(next_expansion, {tile_x, tile_y + 1})
				end
				if tile_x > 1 and
				   (world.metadata[tile_y][tile_x - 1] & REACTION_TILE) ~= 0 then
					table.insert(next_expansion, {tile_x - 1, tile_y})
				end
				if tile_y > 1 and
				   (world.metadata[tile_y - 1][tile_x] & REACTION_TILE) ~= 0 then
					table.insert(next_expansion, {tile_x, tile_y - 1})
				end
			end

			::next_cell::
		end

		-- Update viewport to focus on the current round of expanded tiles.
		assert(min_tile_x)
		assert(min_tile_y)
		assert(max_tile_x)
		assert(max_tile_y)
		world.focus_min_x = (min_tile_x - 1) * TILE_SIZE
		world.focus_min_y = (min_tile_y - 1) * TILE_SIZE
		world.focus_max_x = max_tile_x * TILE_SIZE
		world.focus_max_y = max_tile_y * TILE_SIZE

		-- Animate a few frames.
		for i = 1, CHAIN_REACTION_FRAME_DELAY do
			if world.reset_requested then return end

			world.update()
			world.update_viewport()
			gfx.sprite.update()
			assert(debug_frame_rate())
			coroutine.yield()
		end

		if #next_expansion > 0 then
			expansion = next_expansion
		else
			break
		end
	end
	assert(all_terminal_reactions_are_reachable())
end

-- Update tiles with MUTABLE_TILE bits set.
local function update_mutable_tile(tile_x, tile_y)
	assert(world.metadata[tile_y])
	assert(world.metadata[tile_y][tile_x])
	local tile_bits = world.metadata[tile_y][tile_x]

	if (tile_bits & REACTION_TILE) ~= 0 then
		-- Chain reaction tiles are separated into "trigger" and "effect"
		-- tiles, which are encoded with different bits:
		--
		--   trigger tiles = CHAIN_REACTION
		--   effect tiles = CHAIN_REACTION | BREAKABLE
		--                = TERMINAL_REACTION
		--                = TERMINAL_REACTION | BREAKABLE
		--
		-- Chain reaction must start with a collision against the "trigger"
		-- tiles.  Collisions against "effect" tiles are ignored.
		if (tile_bits & MUTABLE_TILE) == CHAIN_REACTION then
			update_chain_reaction(tile_x, tile_y)
		end
		return
	end
	if (tile_bits & BREAKABLE) == 0 then
		return
	end

	-- Breakable tiles takes two hits to clear: first hit removes the
	-- foreground tiles, second hit removes the background tiles and metadata.
	if is_empty_foreground_tile(tile_x, tile_y) then
		-- Second hit.
		if is_animated_background_tile(tile_x, tile_y) then
			world.vanquished_tiles += 1
		else
			world.broken_tiles += 1
		end
		remove_tile(tile_x, tile_y, world_grid_bg, false)
		world.metadata[tile_y][tile_x] = 0
		assert(tile_x == floor(tile_x))
		assert(tile_y == floor(tile_y))
		assert((tile_x - 1) * TILE_SIZE == (tile_x - 1) << 5)
		assert((tile_y - 1) * TILE_SIZE == (tile_y - 1) << 5)
		add_debris((tile_x - 1) << 5, (tile_y - 1) << 5, 0)
	else
		-- First hit.
		remove_tile(tile_x, tile_y, world_grid_fg, true)

		-- Add debris animation with only so few frame remaining.  This is
		-- so that players get a bit of feedback for the first hit.
		assert(debris_images:getLength() > 4)
		add_debris((tile_x - 1) << 5, (tile_y - 1) << 5, debris_images:getLength() - 4)
	end
end

-- Get background tile image index at a particular location (world coordinates).
local function get_bg_tile_image_index(world_x, world_y)
	assert(world_x >= 0)
	assert(world_y >= 0)
	local tile_x <const>, tile_y <const> = get_tile_position(world_x, world_y)
	return world_grid_bg[0]:getTileAtPosition(tile_x, tile_y)
end

-- Refresh world.serialized_removed_tiles or world.serialized_teleport_stations.
local function refresh_serialized_table(table_name)
	local live_table <const> = world[table_name]
	local serialized_table = world["serialized_" .. table_name]
	assert(#serialized_table <= #live_table)
	local i = #serialized_table
	while i < #live_table do
		i += 1
		serialized_table[i] = live_table[i]
	end
end

-- Refresh world.serialized_balls for save state.
--
-- There isn't a function to load serialized balls (unlike loading serialized
-- removed_tiles), since the serialized array is in the same format, so we
-- just need to update world.balls to point at the loaded copy.
local function refresh_serialized_balls()
	if not world.serialized_balls_dirty then return end
	world.serialized_balls_dirty = false

	world.serialized_balls = table.create(#world.INIT_BALLS, 0)
	assert(#world.serialized_balls == 0)
	for i = 1, #world.balls do
		local entry <const> = world.balls[i]
		assert(#entry == 2)
		world.serialized_balls[i] = {entry[1], entry[2]}
	end
end

--}}}

----------------------------------------------------------------------
--{{{ Ball movement constants.

-- Ball dimension.  We have just one single size ball in our world.
local BALL_RADIUS <const> = HALF_TILE_SIZE

-- Offsets for testing ball collisions.  Ball movements are implemented by
-- adding these offsets to the center of the ball to obtain a test point, then
-- applying ball velocities to that test point and see where it ends up.
-- Change in position on that test point is then applied to the ball center.
--
-- This is the first set of test points, for use with single-contact
-- collisions.  That is, if the ball were to collide with the walls at a
-- single point, it will be one of these points.  There are 8 entries here,
-- corresponding to the 8 surface angles in our world.  The offsets correspond
-- the radius rotated to each of the 8 angles.
local BALL_RADIUS_SIN_PI_4 <const> = BALL_RADIUS / sqrt(2)
local BALL_TEST_POINTS <const> =
{
	-- The order of test points is significant: these entries are placed such
	-- that the test points alternate between axis-aligned and diagonal
	-- extents.  See comments for move_ball near first_index and second_index
	-- for more details.
	{                    0,           BALL_RADIUS},
	{-BALL_RADIUS_SIN_PI_4,  BALL_RADIUS_SIN_PI_4},
	{         -BALL_RADIUS,                     0},
	{ BALL_RADIUS_SIN_PI_4,  BALL_RADIUS_SIN_PI_4},
	{          BALL_RADIUS,                     0},
	{-BALL_RADIUS_SIN_PI_4, -BALL_RADIUS_SIN_PI_4},
	{                    0,          -BALL_RADIUS},
	{ BALL_RADIUS_SIN_PI_4, -BALL_RADIUS_SIN_PI_4},
}

-- Indices for the entries above.
local BALL_TEST_INDEX_DOWN <const> = 1
local BALL_TEST_INDEX_DOWN_LEFT <const> = 2
local BALL_TEST_INDEX_LEFT <const> = 3
local BALL_TEST_INDEX_DOWN_RIGHT <const> = 4
local BALL_TEST_INDEX_RIGHT <const> = 5
local BALL_TEST_INDEX_UP_LEFT <const> = 6
local BALL_TEST_INDEX_UP <const> = 7
local BALL_TEST_INDEX_UP_RIGHT <const> = 8

local function test_index_label(index)
	return
	({
		"down",
		"down_left",
		"left",
		"down_right",
		"right",
		"up_left",
		"up",
		"up_right",
	})[index]
end

-- Test order for BALL_TEST_POINTS.  These orders are selected based on
-- direction of ball travel.  Previously we had just one order that was
-- identical to BALL_INDEX_ORDER_DOWN_LEFT, but this leads to a suboptimal
-- bounce for upward moving balls:
--
--      +---------+---------+  Here the ball is travelling in the up right
--      |         |         |  direction near a corner, and would bounce
--      |         |         |  against the tiles above and to the right.  The
--      |         |         |  correct next step would have been to add a test
--      |         |         |  point that models the upper right corner of the
--      |         |         |  square bounding box, but because we were testing
--      +---------+---------+  points from bottom to top, the actual test point
--               /|         |  added models the bottom corner of the right face
--         **** / |         |  of an octagon.  This is not sufficient to
--        *    *  |         |  capture the bounce against the tile above.
--       *      * |         |
--       *      * |         |  The same problem would not have happened if we
--        *    *  +---------+  tested points from top to bottom, which is why
--         ****   |         |  we have these direction-dependent indices for
--                |         |  testing.
--
local BALL_INDEX_ORDER_DOWN_LEFT <const> =
{
	BALL_TEST_INDEX_DOWN,
	BALL_TEST_INDEX_DOWN_LEFT,
	BALL_TEST_INDEX_LEFT,
	BALL_TEST_INDEX_DOWN_RIGHT,
	BALL_TEST_INDEX_RIGHT,
	BALL_TEST_INDEX_UP_LEFT,
	BALL_TEST_INDEX_UP,
	BALL_TEST_INDEX_UP_RIGHT,
}
local BALL_INDEX_ORDER_DOWN_RIGHT <const> =
{
	BALL_TEST_INDEX_DOWN,
	BALL_TEST_INDEX_DOWN_RIGHT,
	BALL_TEST_INDEX_RIGHT,
	BALL_TEST_INDEX_DOWN_LEFT,
	BALL_TEST_INDEX_LEFT,
	BALL_TEST_INDEX_UP_RIGHT,
	BALL_TEST_INDEX_UP,
	BALL_TEST_INDEX_UP_LEFT,
}
local BALL_INDEX_ORDER_UP_LEFT <const> =
{
	BALL_TEST_INDEX_UP,
	BALL_TEST_INDEX_UP_LEFT,
	BALL_TEST_INDEX_LEFT,
	BALL_TEST_INDEX_UP_RIGHT,
	BALL_TEST_INDEX_RIGHT,
	BALL_TEST_INDEX_DOWN_LEFT,
	BALL_TEST_INDEX_DOWN,
	BALL_TEST_INDEX_DOWN_RIGHT,
}
local BALL_INDEX_ORDER_UP_RIGHT <const> =
{
	BALL_TEST_INDEX_UP,
	BALL_TEST_INDEX_UP_RIGHT,
	BALL_TEST_INDEX_RIGHT,
	BALL_TEST_INDEX_UP_LEFT,
	BALL_TEST_INDEX_LEFT,
	BALL_TEST_INDEX_DOWN_RIGHT,
	BALL_TEST_INDEX_DOWN,
	BALL_TEST_INDEX_DOWN_LEFT,
}

-- Second set of test points for the two-contact scenarios.  If a ball were
-- to collide with walls at exactly two points, we will use a test point that
-- is the intersection of two tangents.
--
-- For 90 degree corners, we can imagine the tangents from four sides form a
-- square, and offset to a corner would be at (+BALL_RADIUS, +BALL_RADIUS).
--
-- For 135 degree corners, tangents from 8 points would form an octagon, and
-- X-offset for the bottom corner can be computed by solving for the
-- intersection of "y=R" and "y+x=2*R/sqrt(2)".
--
-- See also ../data/ball_collision_diagram.svg
local BALL_RADIUS_OCT <const> = BALL_RADIUS * (sqrt(2) - 1)
local BALL_ADDITIONAL_TEST_POINTS <const> =
{
	[BALL_TEST_INDEX_UP] =
	{
		-- Square (upper left corner).
		[BALL_TEST_INDEX_LEFT] =       {    -BALL_RADIUS,     -BALL_RADIUS},
		-- Square (upper right corner).
		[BALL_TEST_INDEX_RIGHT] =      {     BALL_RADIUS,     -BALL_RADIUS},
		-- Octagon (top face left corner).
		[BALL_TEST_INDEX_UP_LEFT] =    {-BALL_RADIUS_OCT,     -BALL_RADIUS},
		-- Octagon (top face right corner).
		[BALL_TEST_INDEX_UP_RIGHT] =   { BALL_RADIUS_OCT,     -BALL_RADIUS},
	},
	[BALL_TEST_INDEX_DOWN] =
	{
		-- Square (lower left corner).
		[BALL_TEST_INDEX_LEFT] =       {    -BALL_RADIUS,      BALL_RADIUS},
		-- Square (lower right corner).
		[BALL_TEST_INDEX_RIGHT] =      {     BALL_RADIUS,      BALL_RADIUS},
		-- Octagon (bottom face left corner).
		[BALL_TEST_INDEX_DOWN_LEFT] =  {-BALL_RADIUS_OCT,      BALL_RADIUS},
		-- Octagon (bottom face right corner).
		[BALL_TEST_INDEX_DOWN_RIGHT] = { BALL_RADIUS_OCT,      BALL_RADIUS},
	},
	[BALL_TEST_INDEX_LEFT] =
	{
		-- Square (upper left corner).
		[BALL_TEST_INDEX_UP] =         {    -BALL_RADIUS,     -BALL_RADIUS},
		-- Square (lower left corner).
		[BALL_TEST_INDEX_DOWN] =       {    -BALL_RADIUS,      BALL_RADIUS},
		-- Octagon (left face upper corner).
		[BALL_TEST_INDEX_UP_LEFT] =    {    -BALL_RADIUS, -BALL_RADIUS_OCT},
		-- Octagon (left face lower corner).
		[BALL_TEST_INDEX_DOWN_LEFT] =  {    -BALL_RADIUS,  BALL_RADIUS_OCT},
	},
	[BALL_TEST_INDEX_RIGHT] =
	{
		-- Square (upper right corner).
		[BALL_TEST_INDEX_UP] =         {     BALL_RADIUS,     -BALL_RADIUS},
		-- Square (lower right corner).
		[BALL_TEST_INDEX_DOWN] =       {     BALL_RADIUS,      BALL_RADIUS},
		-- Octagon (right face upper corner).
		[BALL_TEST_INDEX_UP_RIGHT] =   {     BALL_RADIUS, -BALL_RADIUS_OCT},
		-- Octagon (right face lower corner).
		[BALL_TEST_INDEX_DOWN_RIGHT] = {     BALL_RADIUS,  BALL_RADIUS_OCT},
	},
	[BALL_TEST_INDEX_DOWN_LEFT] =
	{
		-- Octagon (bottom face left corner).
		[BALL_TEST_INDEX_DOWN] =       {-BALL_RADIUS_OCT,      BALL_RADIUS},
		[BALL_TEST_INDEX_DOWN_RIGHT] = {-BALL_RADIUS_OCT,      BALL_RADIUS},
		-- Octagon (left face lower corner).
		[BALL_TEST_INDEX_LEFT] =       {    -BALL_RADIUS,  BALL_RADIUS_OCT},
		[BALL_TEST_INDEX_UP_LEFT] =    {    -BALL_RADIUS,  BALL_RADIUS_OCT},
	},
	[BALL_TEST_INDEX_DOWN_RIGHT] =
	{
		-- Octagon (bottom face right corner).
		[BALL_TEST_INDEX_DOWN] =       { BALL_RADIUS_OCT,      BALL_RADIUS},
		-- Octagon (bottom face left corner).
		[BALL_TEST_INDEX_DOWN_LEFT] =  {-BALL_RADIUS_OCT,      BALL_RADIUS},
		-- Octagon (right face lower corner).
		[BALL_TEST_INDEX_RIGHT] =      {     BALL_RADIUS,  BALL_RADIUS_OCT},
		[BALL_TEST_INDEX_UP_RIGHT] =   {     BALL_RADIUS,  BALL_RADIUS_OCT},
	},
	[BALL_TEST_INDEX_UP_LEFT] =
	{
		-- Octagon (top face left corner).
		[BALL_TEST_INDEX_UP] =         {-BALL_RADIUS_OCT,     -BALL_RADIUS},
		[BALL_TEST_INDEX_UP_RIGHT] =   {-BALL_RADIUS_OCT,     -BALL_RADIUS},
		-- Octagon (left face upper corner).
		[BALL_TEST_INDEX_LEFT] =       {    -BALL_RADIUS, -BALL_RADIUS_OCT},
		-- Octagon (left face lower corner).
		[BALL_TEST_INDEX_DOWN_LEFT] =  {    -BALL_RADIUS,  BALL_RADIUS_OCT},
	},
	[BALL_TEST_INDEX_UP_RIGHT] =
	{
		-- Octagon (top face right corner).
		[BALL_TEST_INDEX_UP] =         { BALL_RADIUS_OCT,     -BALL_RADIUS},
		-- Octagon (top face left corner).
		[BALL_TEST_INDEX_UP_LEFT] =    {-BALL_RADIUS_OCT,     -BALL_RADIUS},
		-- Octagon (right face upper corner).
		[BALL_TEST_INDEX_RIGHT] =      {     BALL_RADIUS, -BALL_RADIUS_OCT},
		-- Octagon (right face lower corner).
		[BALL_TEST_INDEX_DOWN_RIGHT] = {     BALL_RADIUS,  BALL_RADIUS_OCT},
	},
}
local function check_test_point_consistency()
	for i = 1, 8 do
		for j = 1, 8 do
			local p <const> = BALL_ADDITIONAL_TEST_POINTS[i][j]
			if p then
				local q <const> = BALL_ADDITIONAL_TEST_POINTS[j][i]
				assert(q)
				assert(p[1] == q[1], string.format("[%d][%d][1]", i, j))
				assert(p[2] == q[2], string.format("[%d][%d][2]", i, j))
			end
		end
	end
	return true
end
assert(check_test_point_consistency())

-- Acceleration due to gravity in number of pixels per frame.
local GRAVITY <const> = 0.75

-- Number of iterations for reducing gravity on unexpected bounce heights.
--
-- Normally a ball would eventually lose most its velocity on bounces, but when
-- it's near the floor, constant gravity may cause it to bounce indefinitely.
-- We detect when this is happening by observing that the ball has gained
-- height while bouncing on the floor, and reduce the effects of gravity until
-- the ball only goes as high as achievable with its original velocity before
-- gravity is applied.
--
-- As a safe guard against infinite loops, this reduction process is limited
-- to the number of iterations defined here.  We have never observed the
-- number of iterations exceed 5.
local MAX_GRAVITY_REDUCTION_ITERATIONS <const> = 8

-- Maximum recursion level for move_point.
--
-- move_point needs to sub-divide a path for some moves:
-- - A three-tile move requires +1, results in two two-tile moves.
-- - Each two-tile move requires another +1.
--
-- Thus in theory, +2 ought to be enough, but because the two-tile cases
-- sometimes require further subdivisions to handle corner cases, it's not
-- guaranteed.  To prevent runaway recursion, we set a hard limit on
-- recursion depth, and stop the ball from moving further when recursion
-- exceeds this depth.
local MAX_MOVE_POINT_DEPTH <const> = 5

-- Maximum velocity in number of pixels per frame.
--
-- This is meant to limit the ball from travelling more than one tile per
-- frame, since our tile-based move_point() routines rest on the assumption
-- that no movement will cross more than 2 tiles (or 3 tiles diagonally).
--
-- In earlier versions, this was also a hack to prevent the ball from going
-- through walls, although it was never very effective at that.  We have
-- pretty much ironed out all such problems such that balls do not go through
-- walls, the worst they can do is getting stuck in those walls.
--
-- If a ball was thrown straight up at maximum velocity, it will reach zero
-- velocity after MAX_VELOCITY/GRAVITY frames (because velocity decreases by
-- GRAVITY at each frame).  Distance travelled is the area under the
-- velocity-time graph, so maximum height that can be gained by a ball is
--
--   MAX_VELOCITY * (MAX_VELOCITY / GRAVITY) / 2 = 96 pixels.
local MAX_VELOCITY <const> = 12
assert(MAX_VELOCITY < HALF_TILE_SIZE)

-- Amount of velocity maintained after each bounce.
local BOUNCE_VELOCITY_RATIO <const> = 0.75
assert(BOUNCE_VELOCITY_RATIO < 1)

-- Unconditionally stop the ball if it has been moving for more than this
-- many frames.  This is the final safety trap to stop balls from bouncing
-- indefinitely.
local MAX_BALL_MOVE_FRAME_COUNT <const> = 60 * 30  -- 1 minute

--}}}

----------------------------------------------------------------------
--{{{ Ball movement functions.

-- Compute starting tile index for a single component.
--
-- This takes care of the edge case when the starting position is aligned
-- to tile boundary, and the velocity is negative.
local function get_start_tile_component(x, vx)
	assert(x >= 0)

	-- Note that the next two lines contain a common pattern for testing whether
	-- a coordinate is aligned to tile boundary:
	--
	--  x == floor(x) and (floor(x) & 31) == 0
	--
	-- Even though it's a common pattern, we don't have a syntactic sugar for
	-- it because in almost all cases, we keep the integer version of the
	-- coordinate around to avoid calling floor() repeatedly.
	local ix <const> = floor(x)
	if x == ix and (ix & 31) == 0 and vx < 0 then
		return ix >> 5
	end
	return (ix >> 5) + 1
end
assert(get_start_tile_component(0, 0) == 1)
assert(get_start_tile_component(31, 0) == 1)
assert(get_start_tile_component(32, 0) == 2)
assert(get_start_tile_component(33, 0) == 2)
assert(get_start_tile_component(63, 0) == 2)
assert(get_start_tile_component(64, 0) == 3)
assert(get_start_tile_component(31.5, 0) == 1)
assert(get_start_tile_component(32.5, 0) == 2)

assert(get_start_tile_component(0, 1) == 1)
assert(get_start_tile_component(31, 1) == 1)
assert(get_start_tile_component(32, 1) == 2)
assert(get_start_tile_component(33, 1) == 2)
assert(get_start_tile_component(63, 1) == 2)
assert(get_start_tile_component(64, 1) == 3)
assert(get_start_tile_component(31.5, 1) == 1)
assert(get_start_tile_component(32.5, 1) == 2)

assert(get_start_tile_component(0, -1) == 0)
assert(get_start_tile_component(31, -1) == 1)
assert(get_start_tile_component(32, -1) == 1)
assert(get_start_tile_component(33, -1) == 2)
assert(get_start_tile_component(63, -1) == 2)
assert(get_start_tile_component(64, -1) == 2)
assert(get_start_tile_component(31.5, -1) == 1)
assert(get_start_tile_component(32.5, -1) == 2)

-- Compute ending tile index for a single component.
--
-- This takes care of the edge case when the end position is aligned at to
-- tile boundary, and we arrived at that position with positive velocity.
local function get_end_tile_component(x, vx)
	assert(x >= 0)
	local ix <const> = floor(x)
	if x == ix and (ix & 31) == 0 and vx > 0 then
		return ix >> 5
	end
	return (ix >> 5) + 1
end
assert(get_end_tile_component(0, 0) == 1)
assert(get_end_tile_component(31, 0) == 1)
assert(get_end_tile_component(32, 0) == 2)
assert(get_end_tile_component(33, 0) == 2)
assert(get_end_tile_component(63, 0) == 2)
assert(get_end_tile_component(64, 0) == 3)
assert(get_end_tile_component(31.5, 0) == 1)
assert(get_end_tile_component(32.5, 0) == 2)

assert(get_end_tile_component(0, 1) == 0)
assert(get_end_tile_component(31, 1) == 1)
assert(get_end_tile_component(32, 1) == 1)
assert(get_end_tile_component(33, 1) == 2)
assert(get_end_tile_component(63, 1) == 2)
assert(get_end_tile_component(64, 1) == 2)
assert(get_end_tile_component(31.5, 1) == 1)
assert(get_end_tile_component(32.5, 1) == 2)

assert(get_end_tile_component(0, -1) == 1)
assert(get_end_tile_component(31, -1) == 1)
assert(get_end_tile_component(32, -1) == 2)
assert(get_end_tile_component(33, -1) == 2)
assert(get_end_tile_component(63, -1) == 2)
assert(get_end_tile_component(64, -1) == 3)
assert(get_end_tile_component(31.5, -1) == 1)
assert(get_end_tile_component(32.5, -1) == 2)

-- Given a diagonal move that crosses three tiles, return scaling vectors for
-- velocities to reach the nearest horizontal and vertical edges of the middle
-- tile.
--
-- In a diagonal move that crosses three tiles, there exists a shared corner
-- between the start and end tiles, located at (cx, cy):
--
--           +------+
--  (x, y) ----> A  |
--           |      |
--           |      |(cx, cy)
--           +------+------+
--                  |      |
--                  | B <------ (x+vx, y+vy)
--                  |      |
--                  +------+
--
-- We want to compute two scaling factors (sx, sy), where:
--
-- (x,y) + sx * (vx,vy) = vertical edge where x=cx
-- (x,y) + sy * (vx,vy) = horizontal edge where y=cy
--
--      +--------+            :   +--------+
--      |    A   |            :   |   A    |
--      |     *  |            :   |    *** | sx
--      |     *  |            :   |       **
--      |      * |(cx, cy)    :   |        |
--      +------*-+--------+   :   +--------+--------+
--           sx *|        |   :    (cx, cy)|        |
--              *|        |   :            |        |
--               *        |   :            |        |
--               lB       |   :            |B       |
--               +--------+   :            +--------+
--                            :
--      +--------+            :   +--------+
--      |    A   |            :   |   A    |
--      |     *  |            :   |    *** | sy
--      |     *  |            :   |       ***
--      |      * |(cx, cy)    :   |        | ***
--      +------*-+--------+   :   +--------+----*---+
--           sy  |        |   :    (cx, cy)|        |
--               |        |   :            |        |
--               |        |   :            |        |
--               lB       |   :            |B       |
--               +--------+   :            +--------+
--                            :
--            sx > sy         :         sx < sy
--
-- Note how comparing sx and sy allows us to classify whether the intermediate
-- tile is horizontally or vertically adjacent.  There are other less intuitive
-- classifications that we can do, see ../data/move_diagram.svg
local function get_path_orientation(x, y, vx, vy)
	assert(vx ~= 0)
	assert(vy ~= 0)
	local cx <const> = floor(vx > 0 and x + vx or x) & ~31
	local cy <const> = floor(vy > 0 and y + vy or y) & ~31
	local sx <const> = (cx - x) / vx
	local sy <const> = (cy - y) / vy
	return sx, sy
end

-- Compute scaling factor such that x+scale*vx lands on a tile boundary.
local function first_boundary_component_collision_time(x, vx)
	assert(abs(vx) < TILE_SIZE)
	if vx == 0 then
		-- Return some number greater than 1 to signal that the boundary
		-- can not be reached with a zero velocity.
		return 2
	end

	local tile_aligned_x <const> = floor(x) & ~31
	if vx > 0 then
		assert(tile_aligned_x + TILE_SIZE > x)
		return (tile_aligned_x + TILE_SIZE - x) / vx
	end
	if x > tile_aligned_x then
		return (tile_aligned_x - x) / vx
	end
	return -TILE_SIZE / vx
end
assert(first_boundary_component_collision_time(0, 0) > 1)
assert(first_boundary_component_collision_time(1, 0) > 1)
assert(first_boundary_component_collision_time(31, 0) > 1)
assert(first_boundary_component_collision_time(32, 0) > 1)

assert(first_boundary_component_collision_time(32, 1) == 32)
assert(first_boundary_component_collision_time(32, -1) == 32)

assert(first_boundary_component_collision_time(34, 1) == 30)
assert(first_boundary_component_collision_time(34, 2) == 15)
assert(first_boundary_component_collision_time(34, -1) == 2)
assert(first_boundary_component_collision_time(34, -2) == 1)
assert(first_boundary_component_collision_time(62, 1) == 2)
assert(first_boundary_component_collision_time(62, 2) == 1)
assert(first_boundary_component_collision_time(62, -1) == 30)
assert(first_boundary_component_collision_time(62, -2) == 15)

assert(first_boundary_component_collision_time(32, 16) == 2)
assert(first_boundary_component_collision_time(48, 16) == 1)
assert(first_boundary_component_collision_time(56, 16) == 0.5)
assert(first_boundary_component_collision_time(32, -16) == 2)
assert(first_boundary_component_collision_time(48, -16) == 1)
assert(first_boundary_component_collision_time(56, -16) == 1.5)

local function first_boundary_collision_time(x, y, vx, vy)
	return min(first_boundary_component_collision_time(x, vx),
	           first_boundary_component_collision_time(y, vy))
end

-- Syntactic sugar to signal there wasn't a valid line intersection within
-- the [0,1] range.  Any number greater than 1 will work.
local NO_INTERSECTION <const> = 2

-- Compute scaling factor such that (start_x,start_y)+scale*(vx,vy) intersects
-- a diagonal line of the form y=b+x, for use with up-right or down-left tiles.
--
-- Returns NO_INTERSECTION if no position solution exists.
local function intersection_to_positive_slope_line(start_x, start_y, vx, vy, b)
	-- x = start_x + t * vx
	-- y = start_y + t * vy
	-- y = b + x
	-- -> t = (start_y - start_x - b) / (vx - vy)
	if vx == vy then
		return NO_INTERSECTION
	end
	return (start_y - start_x - b) / (vx - vy)
end
assert(intersection_to_positive_slope_line(0, 0, 0, 0, 0) == NO_INTERSECTION)
assert(intersection_to_positive_slope_line(9, 8, 1, 1, 0) == NO_INTERSECTION)

assert(intersection_to_positive_slope_line(0, 0, 6, 8, 0) == 0)
assert(intersection_to_positive_slope_line(0, 0, 6, 8, 1) == 0.5)
assert(intersection_to_positive_slope_line(0, 0, 6, 8, 2) == 1)
assert(intersection_to_positive_slope_line(3, 4, 6, 8, 2) == 0.5)
assert(intersection_to_positive_slope_line(3, 4, -6, -8, 2) < 0)

-- Compute scaling factor such that (start_x,start_y)+scale*(vx,vy) intersects
-- a diagonal line of the form y=b-x, for use with up-left or down-right tiles.
--
-- Returns NO_INTERSECTION if no position solution exists.
local function intersection_to_negative_slope_line(start_x, start_y, vx, vy, b)
	-- x = start_x + t * vx
	-- y = start_y + t * vy
	-- y = b - x
	-- -> t = (b - start_x - start_y) / (vx + vy)
	if vx + vy == 0 then
		return NO_INTERSECTION
	end
	return (b - start_x - start_y) / (vx + vy)
end
assert(intersection_to_negative_slope_line(0, 0, 0, 0, 0) == NO_INTERSECTION)
assert(intersection_to_negative_slope_line(9, 8, 1, -1, 0) == NO_INTERSECTION)

assert(intersection_to_negative_slope_line(0, 0, 6, 8, 0) == 0)
assert(intersection_to_negative_slope_line(0, 0, 6, 8, 7) == 0.5)
assert(intersection_to_negative_slope_line(0, 0, 6, 8, 14) == 1)
assert(intersection_to_negative_slope_line(3, 4, 6, 8, 14) == 0.5)
assert(intersection_to_negative_slope_line(3, 4, -6, -8, 14) < 0)

-- Given cell coordinates within a triangular tile, check if the point is
-- inside the collision region, including edges.  Returns true if so.
local function inside_triangular_region(collision_bits, cell_x, cell_y)
	assert((collision_bits & ~COLLISION_MASK) == 0)
	return (collision_bits == COLLISION_UP_LEFT and cell_x + cell_y >= 32) or
	       (collision_bits == COLLISION_DOWN_RIGHT and cell_x + cell_y <= 32) or
	       (collision_bits == COLLISION_UP_RIGHT and cell_x <= cell_y) or
	       (collision_bits == COLLISION_DOWN_LEFT and cell_x >= cell_y)
end

-- Given cell coordinates within a triangular tile, check if the point is
-- inside the collision region, but not on the edges.  Returns true if so.
local function inside_triangular_region_sans_boundary(collision_bits, cell_x, cell_y)
	assert((collision_bits & ~COLLISION_MASK) == 0)
	return (collision_bits == COLLISION_UP_LEFT and cell_x + cell_y > 32) or
	       (collision_bits == COLLISION_DOWN_RIGHT and cell_x + cell_y < 32) or
	       (collision_bits == COLLISION_UP_RIGHT and cell_x < cell_y) or
	       (collision_bits == COLLISION_DOWN_LEFT and cell_x > cell_y)
end

-- Given cell coordinates within a triangular tile, check if the point is
-- on the sloped edge exactly.  Returns true if so.
local function on_triangular_region_edge(collision_bits, cell_x, cell_y)
	if collision_bits == COLLISION_UP_RIGHT or
	   collision_bits == COLLISION_DOWN_LEFT then
		return cell_x == cell_y
	end
	assert(collision_bits == COLLISION_UP_LEFT or collision_bits == COLLISION_DOWN_RIGHT)
	return cell_x + cell_y == 32
end

-- Check if either the tile above or below an edge-aligned point is empty,
-- returns true if so.
local function has_vertical_clearance(x, y)
	assert(y == floor(y) and (y & 31) == 0)

	local tile_x <const> = (floor(x) >> 5) + 1
	local tile_y_above <const> = floor(y) >> 5
	local tile_y_below <const> = tile_y_above + 1
	return (world.metadata[tile_y_above][tile_x] & COLLISION_MASK) == 0 or
	       (world.metadata[tile_y_below][tile_x] & COLLISION_MASK) == 0
end
assert(has_vertical_clearance(112, 864))
assert(has_vertical_clearance(128, 864))
assert(has_vertical_clearance(112, 992))
assert(has_vertical_clearance(128, 992))
assert(not has_vertical_clearance(112, 928))
assert(not has_vertical_clearance(128, 928))

-- Check if either the tile to the left or right of an edge-aligned point is
-- empty, returns true if so.
local function has_horizontal_clearance(x, y)
	assert(x == floor(x) and (x & 31) == 0)

	local tile_y <const> = (floor(y) >> 5) + 1
	local tile_x_left <const> = floor(x) >> 5
	local tile_x_right <const> = tile_x_left + 1
	return (world.metadata[tile_y][tile_x_left] & COLLISION_MASK) == 0 or
	       (world.metadata[tile_y][tile_x_right] & COLLISION_MASK) == 0
end
assert(has_horizontal_clearance(64, 912))
assert(has_horizontal_clearance(64, 928))
assert(has_horizontal_clearance(192, 912))
assert(has_horizontal_clearance(192, 928))
assert(not has_horizontal_clearance(128, 912))
assert(not has_horizontal_clearance(128, 928))

-- Given a move that crosses three tiles, and scaling factors to the edges of
-- the middle tile, return a scaling factor that lands somewhere inside the
-- intermediate tile.
local function second_tile_step_time(x, y, vx, vy, sx, sy)
	assert(sx ~= sy)

	-- We want to compute a scaling factor s1 such that (x+s1*vx, y+s1*vy)
	-- lands inside the adjacent tile, and not on any of the boundaries.
	-- The average of the two scaling factors is guaranteed to land us
	-- inside the tile and not on a tile boundary, but it makes no
	-- guarantees of where we will land inside that tile, could be on the
	-- boundary of a slanted triangle, for example.
	--
	-- In theory, we don't care where this middle point will land since that
	-- a problem to be dealt with by first_tile_collision_time, but if we land
	-- exactly on a triangle edge, we might see some trouble due to floating
	-- point precision issues.  To avoid those issues, we generate multiple
	-- scaling values that fall between the range of sx..sy (exclusive), and
	-- choose one that gets us furtherest away from any diagonals.

	-- Start with the average to land us inside this tile.
	local s1 <const> = (sx + sy) / 2

	-- Check what kind of tile this is.
	local tile_x <const>, tile_y <const> =
		get_tile_position(floor(x + s1 * vx), floor(y + s1 * vy))
	local collision_bits <const> =
		world.metadata[tile_y][tile_x] & COLLISION_MASK
	if collision_bits == COLLISION_UP_RIGHT or
	   collision_bits == COLLISION_DOWN_LEFT then
		local y_intercept <const> = (tile_y - tile_x) << 5
		assert(y_intercept == (tile_y - tile_x) * TILE_SIZE)
		local s2 <const> = intersection_to_positive_slope_line(x, y, vx, vy, y_intercept)
		if between(sx, s2, sy) then
			assert(debug_trace_move_point_append(x, y, vx, vy, "s_positive_triangle"))
			-- Return a scaling factor that is the average of the time to one of
			-- the tiles boundaries (doesn't matter which one) and the time to
			-- the triangle edge.  This will put us either inside or outside of
			-- the triangular collision region, it doesn't matter which side we
			-- are on as long as we are not exactly on the edge.
			return (sx + s2) / 2
		end
		assert(debug_trace_move_point_append(x, y, vx, vy, "s_positive_triangle_fallthrough"))

	elseif collision_bits == COLLISION_UP_LEFT or
	       collision_bits == COLLISION_DOWN_RIGHT then
		local y_intercept <const> = (tile_x + tile_y - 1) << 5
		assert(y_intercept == (tile_x + tile_y - 1) * TILE_SIZE)
		local s2 <const> = intersection_to_negative_slope_line(x, y, vx, vy, y_intercept)
		if between(sx, s2, sy) then
			assert(debug_trace_move_point_append(x, y, vx, vy, "s_negative_triangle"))
			return (sx + s2) / 2
		end
		assert(debug_trace_move_point_append(x, y, vx, vy, "s_negative_triangle_fallthrough"))
	end

	-- Either it's not a triangle, or we haven't found a good alternative
	-- scaling value (i.e. we gone through the triangle_fallthrough paths),
	-- so we will go with the average.
	--
	-- By the way, the reason why we have not find any good alternative values
	-- is always because the incoming vector causes the intersection to happen
	-- outside of the tile, e.g. if the vector is parallel or close to parallel
	-- to the triangle edge, so this is not something to worry about.
	assert(debug_trace_move_point_append(x, y, vx, vy, "s_average"))
	return s1
end

-- Given a move that crosses two tiles, return a scaling factor for the
-- velocity such that (x,y)+scale*(vx,vy) is inside a collision region in
-- the first tile.  If no such scaling factor exists (e.g. if the first tile
-- is empty), return 1.
local function first_tile_collision_time(x, y, vx, vy, start_tile_x, start_tile_y, collision_bits)
	assert((collision_bits & ~COLLISION_MASK) == 0)
	assert(debug_trace_move_point_append(x, y, vx, vy, collision_label(collision_bits)))

	-- Check if there are any obstacles in the first tile.
	if collision_bits == 0 then
		assert(debug_trace_move_point_append(x, y, vx, vy, "first_tile_empty"))
		return 1
	end

	-- Compute time to the next horizontal and vertical boundaries.
	local s_boundary <const> = first_boundary_collision_time(x, y, vx, vy)
	assert(s_boundary > 0, string.format("move_point(%g,%g,%g,%g): s_boundary > 0", x, y, vx, vy))
	assert(s_boundary <= 1, string.format("move_point(%g,%g,%g,%g): s_boundary <= 1", x, y, vx, vy))

	-- Check if we are already inside an obstacle to begin with.
	if collision_bits == COLLISION_SQUARE then
		-- We are at the edge of an tile.  If we are travelling along the edge
		-- and there is clearance on both sides of the edge that we are
		-- travelling on, we will treat it like a no collision case.  We need
		-- to handle this here, because if we push it back to the caller, we
		-- will end up in an infinite recursion loop because the caller has
		-- no way of moving past this first tile.
		--
		-- If we are at the edge
		local at_vertical_edge <const> = x == floor(x) and (x & 31) == 0
		local at_horizontal_edge <const> = y == floor(y) and (y & 31) == 0

		if at_vertical_edge then
			if at_horizontal_edge then
				-- This path should be unreachable because we can't start at a
				-- corner and still manage to cross two tiles, because the
				-- velocity limits us to traveling within at most one tile.
				assert(debug_trace_move_point_append(x, y, vx, vy, "first_tile_square_corner_stuck"))
				return -1
			end

			-- If we are at a vertical edge, we will allow travelling along the
			-- edge if there is clearance on both sides of the edge, i.e. treat
			-- this tile as not having any collisions.  We will return a factor
			-- that is just enough to get past this tile (i.e. land on a corner).
			if vx == 0 then
				if has_horizontal_clearance(x, y) then
					assert(debug_trace_move_point_append(x, y, vx, vy, "first_tile_square_vertical_edge_travel"))
					return s_boundary
				end
				assert(debug_trace_move_point_append(x, y, vx, vy, "first_tile_square_vertical_edge_stuck"))
				return -1
			end

			-- We are not traveling along the edge, return a scaling factor such
			-- that we can bounce away from the edge but not end up in the next
			-- tile.
			assert(debug_trace_move_point_append(x, y, vx, vy, "first_tile_square_vertical_edge_bounce"))
			return s_boundary / 2

		elseif at_horizontal_edge then
			-- If we are at a horizontal edge, we will allow travelling along the
			-- edge if there is clearance on both sides of the edge, just like
			-- how we handled vertical edges.
			if vy == 0 then
				if has_vertical_clearance(x, y) then
					assert(debug_trace_move_point_append(x, y, vx, vy, "first_tile_square_horizontal_edge_travel"))
					return s_boundary
				end
				assert(debug_trace_move_point_append(x, y, vx, vy, "first_tile_square_horizontal_edge_stuck"))
				return -1
			end

			-- We are not traveling along the edge, return a scaling factor such
			-- that we can bounce away from the edge but not end up in the next
			-- tile.
			assert(debug_trace_move_point_append(x, y, vx, vy, "first_tile_square_horizontal_edge_bounce"))
			return s_boundary / 2
		end

		-- We are stuck if we are inside the square tile and away from the edges.
		assert(debug_trace_move_point_append(x, y, vx, vy, "first_tile_square_stuck"))
		return -1
	end

	local tile_corner_x <const> = (start_tile_x - 1) << 5
	local tile_corner_y <const> = (start_tile_y - 1) << 5
	assert(tile_corner_x == (start_tile_x - 1) * TILE_SIZE)
	assert(tile_corner_y == (start_tile_y - 1) * TILE_SIZE)
	local cell_x <const> = x - tile_corner_x
	local cell_y <const> = y - tile_corner_y
	if inside_triangular_region(collision_bits, cell_x, cell_y) then
		-- Similar to square collision tiles, we want to check if we are starting
		-- on the edge, and return a scaling factor to break down the two-tile
		-- problem if so.
		if on_triangular_region_edge(collision_bits, cell_x, cell_y) then
			assert(debug_trace_move_point_append(x, y, vx, vy, "first_tile_triangle_edge"))
			return s_boundary / 2
		end

		-- We are stuck if our starting position is inside a triangle.
		--
		-- Note that we would always get stuck if the ball hits one of
		-- the axis-aligned edges of the triangle.
		--
		--                    +
		--                 ---|
		--    OK -->    ---   |   <--- Not OK
		--           ---      |
		--          +---------+
		--                ^
		--                |
		--              Not OK
		--
		-- A logical thing to do here would be to treat hitting those sides
		-- as if the ball collided with a square, but the risk here is that
		-- if we have two triangles adjacent to each other, we might end up
		-- having the ball bounce between those two tiles indefinitely.  In
		-- that scenario, we would rather have the ball get stuck right away
		-- instead of potentially tripping over a stack overflow.
		--
		-- Since diagonal walls with adjacent triangle tiles are very common
		-- and sharp corners with exposed axis-aligned edges are rare, we just
		-- rework our level design to avoid the latter in places where ball
		-- might be bouncing through.
		--
		-- We could argue that this handling of triangular collision regions
		-- is a feature rather than a bug: if we ever needed a mechanism for
		-- capturing balls without bouncing, these tiles would be great for
		-- that purpose.
		assert(debug_trace_move_point_append(x, y, vx, vy, "first_tile_triangle_stuck"))
		return -1
	end

	-- Solve for a scaling factor such that (x,y)+s_edge*(vx,vy) is at the
	-- edge of the triangular region.
	local s_edge
	if collision_bits == COLLISION_UP_RIGHT then
		s_edge = intersection_to_positive_slope_line(x, y, vx, vy, tile_corner_y - tile_corner_x)
	elseif collision_bits == COLLISION_DOWN_LEFT then
		s_edge = intersection_to_positive_slope_line(x, y, vx, vy, tile_corner_y - tile_corner_x)
	elseif collision_bits == COLLISION_UP_LEFT then
		s_edge = intersection_to_negative_slope_line(x, y, vx, vy, tile_corner_y + tile_corner_x + 32)
	else
		assert(collision_bits == COLLISION_DOWN_RIGHT)
		s_edge = intersection_to_negative_slope_line(x, y, vx, vy, tile_corner_y + tile_corner_x + 32)
	end

	if s_edge > 0 and s_edge < s_boundary then
		-- Point being moved will intersect the collision region before leaving
		-- the tile.  Return the average of the two scaling factors to place the
		-- point inside the collision region.
		return (s_edge + s_boundary) / 2
	end

	-- Point moves through tile without intersection.
	assert(debug_trace_move_point_append(x, y, vx, vy, "first_tile_no_collision"))
	return 1
end

-- Given a collision against a COLLISION_UP_RIGHT or COLLISION_DOWN_LEFT tile,
-- return updated position, velocity, and hit tile coordinates.
--
-- Transformation to rotate incoming vector into bounce vector:
--
--   [ cos(-A)  sin(-A)   *  [-1  0   *  [ cos(A)  sin(A)   *  [vx
--    -sin(-A)  cos(-A)]       0  1]      -sin(A)  cos(A)]      vy]
--
--   A = -pi/4   ->   [new_vx   = [0  1   * [vx
--                     new_vy]     1  0]     vy]
local function positive_slope_tile_collision(collision_bits, x, y, vx, vy, end_tile_x, end_tile_y)
	local ix <const> = (end_tile_x - 1) << 5
	local iy <const> = (end_tile_y - 1) << 5
	assert(ix == (end_tile_x - 1) * TILE_SIZE)
	assert(iy == (end_tile_y - 1) * TILE_SIZE)
	local s_edge <const> = intersection_to_positive_slope_line(x, y, vx, vy, iy - ix)

	-- "s_edge < 0" (as opposed to "s_edge <= 0") means a point that starts off
	-- pushing against an edge will count as a bounce.  If we had used "<=0",
	-- that point will move further into the collision region.
	--
	-- "s_edge >= 1" (as opposed to "s_edge > 1") means a point that landed
	-- exactly on the edge does not count as bounce.
	if s_edge < 0 or s_edge >= 1 then
		assert(debug_trace_move_point_end(x, y, vx, vy, "positive_triangle_no_collision", x + vx, y + vy, vx, vy, nil, nil))
		return x + vx, y + vy, vx, vy, nil, nil
	end

	local new_vx <const> = vy
	local new_vy <const> = vx
	local bounced_x <const> = x + s_edge * vx + (1 - s_edge) * new_vx
	local bounced_y <const> = y + s_edge * vy + (1 - s_edge) * new_vy
	assert(debug_trace_move_point_end(x, y, vx, vy, "positive_triangle", bounced_x, bounced_y, new_vx, new_vy, end_tile_x, end_tile_y))
	return bounced_x, bounced_y, new_vx, new_vy, end_tile_x, end_tile_y
end

-- Given a collision against a COLLISION_UP_LEFT or COLLISION_DOWN_RIGHT tile,
-- return updated position, velocity, and hit tile coordinates.
--
-- Transformation to rotate incoming vector into bounce vector:
--
--   [ cos(-A)  sin(-A)   *  [-1  0   *  [ cos(A)  sin(A)   *  [vx
--    -sin(-A)  cos(-A)]       0  1]      -sin(A)  cos(A)]      vy]
--
--   A = pi/4   ->   [new_vx   = [ 0  -1   * [vx
--                    new_vy]     -1   0]     vy]
local function negative_slope_tile_collision(collision_bits, x, y, vx, vy, end_tile_x, end_tile_y)
	local ix <const> = (end_tile_x - 1) << 5
	local iy <const> = (end_tile_y - 1) << 5
	assert(ix == (end_tile_x - 1) * TILE_SIZE)
	assert(iy == (end_tile_y - 1) * TILE_SIZE)
	local s_edge <const> = intersection_to_negative_slope_line(x, y, vx, vy, ix + iy + 32)

	-- "s_edge < 0" (as opposed to "s_edge <= 0") means a point that starts off
	-- pushing against an edge will count as a bounce.  If we had used "<=0",
	-- that point will move further into the collision region.
	--
	-- "s_edge >= 1" (as opposed to "s_edge > 1") means a point that landed
	-- exactly on the edge does not count as bounce.
	if s_edge < 0 or s_edge >= 1 then
		assert(debug_trace_move_point_end(x, y, vx, vy, "negative_triangle_no_collision", x + vx, y + vy, vx, vy, nil, nil))
		return x + vx, y + vy, vx, vy, nil, nil
	end

	local new_vx <const> = -vy
	local new_vy <const> = -vx
	local bounced_x <const> = x + s_edge * vx + (1 - s_edge) * new_vx
	local bounced_y <const> = y + s_edge * vy + (1 - s_edge) * new_vy
	assert(debug_trace_move_point_end(x, y, vx, vy, "negative_triangle", bounced_x, bounced_y, new_vx, new_vy, end_tile_x, end_tile_y))
	return bounced_x, bounced_y, new_vx, new_vy, end_tile_x, end_tile_y
end

-- Handle cases related to pushing against corner of a square.
local function handle_square_corners(x, y, vx, vy, tile_x, tile_y)
	assert(x == floor(x) and (x & 31) == 0)
	assert(y == floor(y) and (y & 31) == 0)

	-- At least one velocity component must be nonzero.  We would have stopped
	-- earlier in the no_motion branch if they were both zero.
	assert(vx ~= 0 or vy ~= 0)

	if vx ~= 0 and vy ~= 0 then
		-- Attempting a diagonal bounce against a corner.  We need to choose
		-- to bounce either vertically or horizontally, but not both.
		--
		-- This selection is done based on clearance.
		local tx <const> = x >> 5
		local ty <const> = y >> 5
		local up_left_empty <const> = world.metadata[ty][tx] == 0
		local up_right_empty <const> = world.metadata[ty][tx + 1] == 0
		local down_left_empty <const> = world.metadata[ty + 1][tx] == 0
		local down_right_empty <const> = world.metadata[ty + 1][tx + 1] == 0

		-- If we have a pair of horizontally adjacent empty tiles above or
		-- below, we will do a vertical bounce.
		if (up_left_empty and up_right_empty) or
		   (down_left_empty and down_right_empty) then
			assert(debug_trace_move_point_end(x, y, vx, vy, "square_corner_forced_vertical_bounce", x + vx, y - vy, vx, -vy, tile_x, tile_y))
			return x + vx, y - vy, vx, -vy, tile_x, tile_y
		end

		-- If we have a pair of vertically adjacent empty tiles to the left
		-- or right, we will do a horizontal bounce.
		if (up_left_empty and down_left_empty) or
		   (up_right_empty and down_right_empty) then
			assert(debug_trace_move_point_end(x, y, vx, vy, "square_corner_forced_horizontal_bounce", x - vx, y + vy, -vx, vy, tile_x, tile_y))
			return x - vx, y + vy, -vx, vy, tile_x, tile_y
		end

		-- We have no choice remaining but to do a diagonal bounce to get out of
		-- this corner.  Even though we call this a "bounce", we actually set
		-- the direction vector to ensure that we are leaving in the one empty
		-- quadrant, regardless of what direction we came in with.
		--
		-- This is hacky in that in normal circumstances, the bounce direction
		-- should be exactly (-vx, -vy) since there are no other vectors for a
		-- ball to arrive at a corner in the first place.  But in testing, it's
		-- possible for a point to start at a corner with a weird velocity, which
		-- is why we have the forced directions below.
		if up_left_empty then
			local nvx <const> = -abs(vx)
			local nvy <const> = -abs(vy)
			assert(debug_trace_move_point_end(x, y, vx, vy, "square_corner_forced_diagonal_up_left", x + nvx, y + nvy, nvx, nvy, tile_x, tile_y))
			return x + nvx, y + nvy, nvx, nvy, tile_x, tile_y
		elseif up_right_empty then
			local nvx <const> = abs(vx)
			local nvy <const> = -abs(vy)
			assert(debug_trace_move_point_end(x, y, vx, vy, "square_corner_forced_diagonal_up_right", x + nvx, y + nvy, nvx, nvy, tile_x, tile_y))
			return x + nvx, y + nvy, nvx, nvy, tile_x, tile_y
		elseif down_left_empty then
			local nvx <const> = -abs(vx)
			local nvy <const> = abs(vy)
			assert(debug_trace_move_point_end(x, y, vx, vy, "square_corner_forced_diagonal_down_left", x + nvx, y + nvy, nvx, nvy, tile_x, tile_y))
			return x + nvx, y + nvy, nvx, nvy, tile_x, tile_y
		elseif down_right_empty then
			local nvx <const> = abs(vx)
			local nvy <const> = abs(vy)
			assert(debug_trace_move_point_end(x, y, vx, vy, "square_corner_forced_diagonal_down_right", x + nvx, y + nvy, nvx, nvy, tile_x, tile_y))
			return x + nvx, y + nvy, nvx, nvy, tile_x, tile_y
		end
		assert(debug_trace_move_point_end(x, y, vx, vy, "square_corner_stuck", x, y, 0, 0, tile_x, tile_y))
		return x, y, 0, 0, tile_x, tile_y
	end

	if vx == 0 then
		assert(vy ~= 0)

		-- Travelling vertically starting from a corner.  If we have horizontal
		-- clearance in the direction we are traveling, we will treat this as
		-- a no collision travel.
		if has_horizontal_clearance(x, y + vy) then
			assert(debug_trace_move_point_end(x, y, vx, vy, "square_corner_vertical_edge_travel", x, y + vy, 0, vy, nil, nil))
			return x, y + vy, 0, vy, nil, nil
		end

		-- If we have horizontal clearance in the opposite direction of where
		-- we are going, we will treat this as a vertical bounce.
		if has_horizontal_clearance(x, y - vy) then
			assert(debug_trace_move_point_end(x, y, vx, vy, "square_corner_vertical_bounce", x, y - vy, 0, -vy, nil, nil))
			return x, y - vy, 0, -vy, tile_x, tile_y
		end

		-- No clearance, so we are stuck.
		assert(debug_trace_move_point_end(x, y, vx, vy, "square_corner_vertical_stuck", x, y, 0, 0, tile_x, tile_y))
		return x, y, 0, 0, tile_x, tile_y

	else
		assert(vx ~= 0)
		assert(vy == 0)

		-- Travelling horizontally starting from a corner.  If we have vertical
		-- clearance in the direction we are traveling, we will treat this as
		-- a no collision travel.
		if has_vertical_clearance(x + vx, y) then
			assert(debug_trace_move_point_end(x, y, vx, vy, "square_corner_horizontal_edge_travel", x + vx, y, vx, 0, nil, nil))
			return x + vx, y, vx, 0, nil, nil
		end

		-- If we have vertical clearance in the opposite direction of where
		-- we are going, we will treat this as a horizontal bounce.
		if has_vertical_clearance(x - vx, y) then
			assert(debug_trace_move_point_end(x, y, vx, vy, "square_corner_horizontal_bounce", x - vx, y, -vx, 0, nil, nil))
			return x - vx, y, -vx, 0, tile_x, tile_y
		end

		-- No clearance, so we are stuck.
		assert(debug_trace_move_point_end(x, y, vx, vy, "square_corner_horizontal_stuck", x, y, 0, 0, tile_x, tile_y))
		return x, y, 0, 0, tile_x, tile_y
	end
end

-- Handle cases related to pushing against edge of a square.
local function handle_square_edges(x, y, vx, vy, tile_x, tile_y)
	if x == floor(x) and (x & 31) == 0 then
		if y == floor(y) and (y & 31) == 0 then
			return handle_square_corners(x, y, vx, vy, tile_x, tile_y)
		end

		-- We need clearance to the left and right of the vertical edge that
		-- we are on for any movement to be possible.
		if not has_horizontal_clearance(x, y) then
			assert(debug_trace_move_point_end(x, y, vx, vy, "square_vertical_edge_stuck", x, y, 0, 0, tile_x, tile_y))
			return x, y, 0, 0, tile_x, tile_y
		end

		-- If there is no horizontal movement, then we are moving vertically
		-- along this vertical edge, and it does not count as a collision.
		if vx == 0 then
			assert(debug_trace_move_point_end(x, y, vx, vy, "square_vertical_edge_travel", x, y + vy, 0, vy, nil, nil))
			return x, y + vy, 0, vy, nil, nil
		end

		-- Pushing horizontally or diagonally against this vertical edge.
		assert(debug_trace_move_point_end(x, y, vx, vy, "square_vertical_edge_push", x - vx, y + vy, -vx, vy, nil, nil))
		return x - vx, y + vy, -vx, vy, tile_x, tile_y

	elseif y == floor(y) and (y & 31) == 0 then
		-- We need clearance above and below this horizontal edge that we are
		-- on for any movement to be possible.
		if not has_vertical_clearance(x, y) then
			assert(debug_trace_move_point_end(x, y, vx, vy, "square_horizontal_edge_stuck", x, y, 0, 0, tile_x, tile_y))
			return x, y, 0, 0, tile_x, tile_y
		end

		-- If there is no vertically movement, then we are moving horizontally
		-- along this horizontally edge, and it does not count as a collision.
		if vy == 0 then
			assert(debug_trace_move_point_end(x, y, vx, vy, "square_horizontal_edge_travel", x + vx, y, vx, 0, nil, nil))
			return x + vx, y, vx, 0, nil, nil
		end

		-- Pushing vertically or diagonally against this horizontal edge.
		assert(debug_trace_move_point_end(x, y, vx, vy, "square_horizontal_edge_push", x + vx, y - vy, vx, -vy, nil, nil))
		return x + vx, y - vy, vx, -vy, tile_x, tile_y
	end

	-- Stuck because we are in a collision square and not on an edge.
	assert(debug_trace_move_point_end(x, y, vx, vy, "square_stuck", x, y, 0, 0, tile_x, tile_y))
	return x, y, 0, 0, tile_x, tile_y
end

-- Forward declaration.
local move_point

-- Call move_point in two steps, with "s1" amount of velocity for the first
-- step and "1-s1" amount of velocity for the second step.
local function sub_move_point(x, y, vx, vy, s1, depth)
	assert(debug_trace_move_point_append(x, y, vx, vy, string.format("s=%g", s1)))

	-- Step 1, using the caller supplied fraction.
	local step1x <const>, step1y <const>,
	      step1vx <const>, step1vy <const>,
	      step1hx <const>, step1hy <const> =
		move_point(x, y, vx * s1, vy * s1, depth + 1)

	-- Step 2: Complete the movement with the remainder of the velocity.
	-- We reduced the velocity in the previous step to s1, so we need to
	-- scale the resulting velocity by (1-s1)/s1.
	local s2 <const> = (1 - s1) / s1
	assert(s2 ~= 0, string.format("move_point(%g,%g,%g,%g): s2 ~= 0", x, y, vx, vy))
	local step2x <const>, step2y <const>,
	      step2vx <const>, step2vy <const>,
	      step2hx <const>, step2hy <const> =
		move_point(step1x, step1y, step1vx * s2, step1vy * s2, depth + 1)

	-- Scale the result back to the original magnitude.
	local s_original = 1 / (s1 * s2)
	assert(s_original > 1, string.format("move_point(%g,%g,%g,%g): s_original > 1", x, y, vx, vy))
	local rvx <const> = step2vx * s_original
	local rvy <const> = step2vy * s_original

	-- Return the updated position and velocity after step 2, with
	-- the collision tile from either step 1 or step 2.
	if step1hx then
		assert(debug_trace_move_point_end(x, y, vx, vy, "sub_step1", step2x, step2y, rvx, rvy, step1hx, step1hy))
		return step2x, step2y, rvx, rvy, step1hx, step1hy
	end

	-- Return collision result from step 2 if step 1 had no collisions.
	assert(debug_trace_move_point_end(x, y, vx, vy, "sub_step2", step2x, step2y, rvx, rvy, step2hx, step2hy))
	return step2x, step2y, rvx, rvy, step2hx, step2hy
end

-- Call move_point with updated velocities.
--
-- The reason why we have a whole separate function for this is due to debug
-- logging.  We could have tweaked sub_move_point for this purpose, but it's
-- not a good fit due to how velocities are passed in.
local function retry_move_point(x, y, vx, vy, nvx, nvy, depth)
	assert(debug_trace_move_point_append(x, y, vx, vy, string.format("nvx=%g, nvy=%f", nvx, nvy)))

	local rx <const>, ry <const>, rvx <const>, rvy <const>, rhx <const>, rhy <const> = move_point(x, y, nvx, nvy, depth + 1)
	assert(debug_trace_move_point_end(x, y, vx, vy, "retry_step", rx, ry, rvx, rvy, rhx, rhy))
	return rx, ry, rvx, rvy, rhx, rhy
end

-- Given an initial position and a vector, return a tuple of 6 elements:
-- new_x, new_y, new_vx, new_vy, hit_tile_x, hit_tile_y
--
-- Note that (hit_tile_x, hit_tile_y) is the first tile that was hit, even
-- though a point may bounce through two tiles near corners.  That's just one
-- of the known quirks of our bespoke ghetto physics, there are possibly many
-- more unknown quirks waiting to bite us.  For the most part, we can afford
-- such imperfections because MAX_VELOCITY and a world filled with mostly
-- concave walls protects us from these  things.
move_point = function(x, y, vx, vy, depth)
	assert(debug_trace_move_point_begin(x, y, vx, vy))
	assert(abs(vx) < TILE_SIZE)
	assert(abs(vy) < TILE_SIZE)
	assert(depth)

	if depth > MAX_MOVE_POINT_DEPTH then
		assert(debug_trace_move_point_end(x, y, vx, vy, "excessive_recursion", x, y, 0, 0, nil, nil))
		return x, y, 0, 0, nil, nil
	end

	-- Adjust velocity vector based on motion after movement.  That is, if
	-- a position after adding velocity is the same as before, we will force
	-- the velocity to be zero.  This is to account for underflows.
	--
	-- It happens more often than you think, consider this assertion:
	--
	--   assert(5056 - 0.000113726 ~= 5056)
	--
	-- This should have been true since any value minus a nonzero value should
	-- not equal to itself, but IEEE754 doesn't actually have the precision to
	-- store 5055.999886274 in 32bits.  You can verify this with the IEEE754
	-- floating point converter:
	-- https://www.h-schmidt.net/FloatConverter/IEEE754.html
	--
	-- (Note that this link appears more than once in this file, meaning we got
	-- burned by floating point precision more than once.)
	--
	-- Due to this lack of precision, if we have x=5056 and vx=-0.000113726,
	-- we will proceed down an inconsistent path where starting and ending tile
	-- coordinates are different (due to 5056 being on a tile boundary and
	-- get_start_tile_component taking velocity into account), but the starting
	-- and ending world coordinates are same (due to underflow).  The world
	-- versus tile coordinate inconsistency will cause us to trip over an
	-- assertion in first_tile_collision_time.
	--
	-- By forcing velocity that are effectively zeroes to be actually zero,
	-- we shield ourselves from this underflow issue.
	local new_x <const> = x + vx
	local new_y <const> = y + vy
	if (x == new_x and vx ~= 0) or (y == new_y and vy ~= 0) then
		return retry_move_point(x, y, vx, vy, x == new_x and 0 or vx, y == new_y and 0 or vy, depth)
	end

	if vx == 0 and vy == 0 then
		assert(debug_trace_move_point_end(x, y, vx, vy, "no_motion", x, y, vx, vy, nil, nil))
		return x, y, vx, vy, nil, nil
	end

	-- If end tile position will be out of bounds, the behavior is undefined.
	-- There are a few things we can do here to ensure that move_point is
	-- always safe, but those measures do not ensure the safety of move_ball
	-- (which requires additional margins).  Thus we assert here that move_point
	-- will not incur out of bounds access, and deal with it elsewhere.
	--
	-- By "elsewhere", I meant "draw the map so that balls can not be thrown
	-- out of bounds".
	assert(new_x >= 0)
	assert(new_x < world.WIDTH)
	assert(new_y >= 0)
	assert(new_y < world.HEIGHT)

	local start_tile_x <const> = get_start_tile_component(x, vx)
	local start_tile_y <const> = get_start_tile_component(y, vy)
	local end_tile_x <const> = get_end_tile_component(new_x, vx)
	local end_tile_y <const> = get_end_tile_component(new_y, vy)

	-- If we start and end on different rows and columns, we may cross up to
	-- three tiles.  We will need to divide this into two separate two-tile
	-- calls to handle the intermediate bounces properly.
	if start_tile_x ~= end_tile_x and start_tile_y ~= end_tile_y then
		local sx <const>, sy <const> = get_path_orientation(x, y, vx, vy)
		assert(sx > 0, string.format("move_point(%g,%g,%g,%g): sx > 0", x, y, vx, vy))
		assert(sx < 1, string.format("move_point(%g,%g,%g,%g): sx < 1", x, y, vx, vy))
		assert(sy > 0, string.format("move_point(%g,%g,%g,%g): sy > 0", x, y, vx, vy))
		assert(sy < 1, string.format("move_point(%g,%g,%g,%g): sy < 1", x, y, vx, vy))
		if sx ~= sy then
			assert(debug_trace_move_point_append(x, y, vx, vy, sx < sy and "diagonal_horizontal" or "diagonal_vertical"))
			local s <const> = second_tile_step_time(x, y, vx, vy, sx, sy)
			return sub_move_point(x, y, vx, vy, s, depth)
		end
		assert(debug_trace_move_point_append(x, y, vx, vy, "diagonal_corner"))
	end

	-- If we start and end on different tiles, we may need to divide this into
	-- two separate steps to handle two separate collisions in each tile.
	assert(world.metadata[start_tile_y])
	assert(world.metadata[start_tile_y][start_tile_x])
	local start_tile_bits <const> =
		world.metadata[start_tile_y][start_tile_x] & COLLISION_MASK
	if start_tile_x ~= end_tile_x or start_tile_y ~= end_tile_y then
		local s1 <const> = first_tile_collision_time(x, y, vx, vy, start_tile_x, start_tile_y, start_tile_bits)
		if s1 < 1 then
			if s1 <= 0 then
				assert(debug_trace_move_point_end(x, y, vx, vy, "stop", x, y, 0, 0, start_tile_x, start_tile_y))
				return x, y, 0, 0, start_tile_x, start_tile_y
			end

			assert(debug_trace_move_point_append(x, y, vx, vy, "two_steps"))
			return sub_move_point(x, y, vx, vy, s1, depth)
		end

	else
		assert(start_tile_x == end_tile_x)
		assert(start_tile_y == end_tile_y)

		-- We are starting and ending on the same tile.  Verify that we are
		-- not starting inside a collision region.
		assert(debug_trace_move_point_append(x, y, vx, vy, collision_label(start_tile_bits)))
		if start_tile_bits == COLLISION_SQUARE then
			return handle_square_edges(x, y, vx, vy, start_tile_x, start_tile_y)
		else
			local cell_x <const> = x - ((start_tile_x - 1) << 5)
			local cell_y <const> = y - ((start_tile_y - 1) << 5)
			assert(cell_x == x - ((start_tile_x - 1) * TILE_SIZE))
			assert(cell_y == y - ((start_tile_y - 1) * TILE_SIZE))
			if inside_triangular_region_sans_boundary(start_tile_bits, cell_x, cell_y) then
				assert(debug_trace_move_point_end(x, y, vx, vy, "single_tile_stuck_triangle", x, y, 0, 0, start_tile_x, start_tile_y))
				return x, y, 0, 0, start_tile_x, start_tile_y
			end
		end
		assert(debug_trace_move_point_append(x, y, vx, vy, "single_tile"))
	end

	-- If we got this far, it means we can complete the movement in a single
	-- step with at most one collision.
	assert(world.metadata[end_tile_y])
	assert(world.metadata[end_tile_y][end_tile_x])
	local collision_bits <const> =
		world.metadata[end_tile_y][end_tile_x] & COLLISION_MASK
	if collision_bits == 0 then
		-- No collisions because we didn't land in a square with collision bits.
		assert(debug_trace_move_point_end(x, y, vx, vy, "no_collision", new_x, new_y, vx, vy, nil, nil))
		return new_x, new_y, vx, vy, nil, nil
	end

	-- Check for collisions with triangle tiles.
	if collision_bits == COLLISION_UP_LEFT or
	   collision_bits == COLLISION_DOWN_RIGHT then
		return negative_slope_tile_collision(collision_bits, x, y, vx, vy, end_tile_x, end_tile_y)
	elseif collision_bits == COLLISION_UP_RIGHT or
	       collision_bits == COLLISION_DOWN_LEFT then
		return positive_slope_tile_collision(collision_bits, x, y, vx, vy, end_tile_x, end_tile_y)
	end

	-- Only square tiles remain if we got this far.
	assert(collision_bits == COLLISION_SQUARE)
	local adjusted_x = new_x
	local adjusted_y = new_y
	local adjusted_vx = vx
	local adjusted_vy = vy

	-- If the start and end tiles are different, and they are adjacent, we
	-- can choose the bounce direction based on tile coordinates.
	local prefer_horizontal = nil  -- +1 = right, -1 = left
	local prefer_vertical = nil  -- +1 = down, -1 = up
	if start_tile_x == end_tile_x then
		if start_tile_y == end_tile_y then
			-- Start and end in the same tile.  Since this is a collision square,
			-- we were already stuck when we started.
			assert(debug_trace_move_point_end(x, y, vx, vy, "same_tile_stop", x, y, 0, 0, end_tile_x, end_tile_y))
			return x, y, 0, 0, end_tile_x, end_tile_y
		else
			assert(debug_trace_move_point_append(x, y, vx, vy, "adjacent_vertical"))
			prefer_vertical = start_tile_y < end_tile_y and 1 or -1
		end
	elseif start_tile_y == end_tile_y then
		assert(debug_trace_move_point_append(x, y, vx, vy, "adjacent_horizontal"))
		prefer_horizontal = start_tile_x < end_tile_x and 1 or -1
	else
		-- We must have gotten here via diagonal_corner.  We will choose a
		-- horizontal bounce only if the vertical neighbor is empty and the
		-- horizontal neighbor is nonempty.  Vertical bounce is preferred in all
		-- other cases.
		--
		-- Bounce will never be diagonal, even if the ball were to hit the corner
		-- of a tile exactly.  This is because we mostly don't have that kind of
		-- corners in our world, so any corner collision is likely due to the
		-- edge of the ball colliding with corner of a tile that is adjacent to
		-- another tile.  If we allow diagonal bounces, it would appear as if the
		-- ball has some backspin going, which looks weird.
		if (world.metadata[end_tile_y][start_tile_x] & COLLISION_MASK) == 0 and
		   (world.metadata[start_tile_y][end_tile_x] & COLLISION_MASK) ~= 0 then
			assert(debug_trace_move_point_append(x, y, vx, vy, "force_horizontal"))
			prefer_horizontal = vx > 0 and 1 or -1
		else
			assert(debug_trace_move_point_append(x, y, vx, vy, "force_vertical"))
			prefer_vertical = vy > 0 and 1 or -1
		end
	end

	if prefer_vertical then
		local cell_y <const> = new_y - (floor(new_y) & ~31)
		if prefer_vertical > 0 then
			-- Moving down, bouncing up.
			assert(debug_trace_move_point_append(x, y, vx, vy, "down_to_up"))
			adjusted_y -= 2 * cell_y
			adjusted_vy = -adjusted_vy
		else
			-- Moving up, bouncing down.
			assert(debug_trace_move_point_append(x, y, vx, vy, "up_to_down"))
			adjusted_y += 2 * (32 - cell_y)
			adjusted_vy = -adjusted_vy
		end
	elseif prefer_horizontal then
		local cell_x <const> = new_x - (floor(new_x) & ~31)
		if prefer_horizontal > 0 then
			-- Moving right, bouncing left.
			assert(debug_trace_move_point_append(x, y, vx, vy, "right_to_left"))
			adjusted_x -= 2 * cell_x
			adjusted_vx = -adjusted_vx
		else
			-- Moving left, bouncing right.
			assert(debug_trace_move_point_append(x, y, vx, vy, "left_to_right"))
			adjusted_x += 2 * (32 - cell_x)
			adjusted_vx = -adjusted_vx
		end
	end

	-- Exactly one of the vectors should have been inverted due to the
	-- collision.  If not, it might be that we were already inside a
	-- collision square to start with, in which case we want to zero out
	-- all velocities to stop the ball from moving further.
	if vx == adjusted_vx and vy == adjusted_vy then
		assert(debug_trace_move_point_end(x, y, vx, vy, "no_bounce_stop", adjusted_x, adjusted_y, 0, 0, end_tile_x, end_tile_y))
		return adjusted_x, adjusted_y, 0, 0, end_tile_x, end_tile_y
	end

	-- Normal return path for square collisions.
	assert(debug_trace_move_point_end(x, y, vx, vy, "square_success", adjusted_x, adjusted_y, adjusted_vx, adjusted_vy, end_tile_x, end_tile_y))
	return adjusted_x, adjusted_y, adjusted_vx, adjusted_vy, end_tile_x, end_tile_y
end

-- Check for equality with a certain tolerance.
local function roughly_equals(a, b, margin)
	return a == b or (a and b and abs(a - b) <= margin)
end

-- Compare expected and actual results for test_move_point or test_move_ball.
-- Returns true if all values matches what's expected.
local function compare_move_results(ax, ay, avx, avy, ahx, ahy, ex, ey, evx, evy, ehx, ehy, margin)
	local all_equal = true

	-- Compare position and velocity.
	if not roughly_equals(ax, ex, margin) then
		print("expected x", ex, "actual x", ax)
		all_equal = false
	end
	if not roughly_equals(ay, ey, margin) then
		print("expected y", ey, "actual y", ay)
		all_equal = false
	end
	if not roughly_equals(avx, evx, margin) then
		print("expected vx", evx, "actual vx", avx)
		all_equal = false
	end
	if not roughly_equals(avy, evy, margin) then
		print("expected vy", evy, "actual vy", avy)
		all_equal = false
	end

	-- Tile coordinates are always compared without margin.
	if ahx ~= ehx then
		print("expected hit_x", ehx, "actual hit_x", ahx)
		all_equal = false
	end
	if ahy ~= ehy then
		print("expected hit_y", ehy, "actual hit_y", ahy)
		all_equal = false
	end
	return all_equal
end

-- Wrapper for running move_point and compare against expected results.
local function test_move_point(x, y, vx, vy, ex, ey, evx, evy, ehx, ehy)
	debug_trace_move_point_reset()
	local ax <const>, ay <const>, avx <const>, avy <const>,
	      ahx <const>, ahy <const> =
		move_point(x, y, vx, vy, 0)
	local MARGIN <const> = 0.01
	if compare_move_results(ax, ay, avx, avy, ahx, ahy,
	                        ex, ey, evx, evy, ehx, ehy, MARGIN) then
		return true
	end

	debug_trace_move_point_dump()
	return false
end
assert(test_move_point(0, 0, 0, 0,  0, 0, 0, 0, nil, nil))

-- COLLISION_UP_LEFT
assert(test_move_point(40, 40,   0,   0,  40, 40,   0,   0, nil, nil))
assert(test_move_point(40, 40,   5,   0,  45, 40,   5,   0, nil, nil))
assert(test_move_point(40, 40,   0,   5,  40, 45,   0,   5, nil, nil))
assert(test_move_point(40, 40,  -5,   0,  35, 40,  -5,   0, nil, nil))
assert(test_move_point(40, 40,   0,  -5,  40, 35,   0,  -5, nil, nil))
assert(test_move_point(48, 48,  -5,   5,  43, 53,  -5,   5, nil, nil))
assert(test_move_point(48, 48,   5,  -5,  53, 43,   5,  -5, nil, nil))
assert(test_move_point(40, 40,  20,   0,  56, 36,   0, -20, 2, 2))
assert(test_move_point(40, 40,   0,  20,  36, 56, -20,   0, 2, 2))
assert(test_move_point(40, 40,  20,  20,  36, 36, -20, -20, 2, 2))
assert(test_move_point(32, 48,  24,   8,  40, 40,  -8, -24, 2, 2))
assert(test_move_point(48, 32,   8,  24,  40, 40, -24,  -8, 2, 2))
assert(test_move_point(56, 36, -16,  24,  36, 56, -24,  16, 2, 2))
assert(test_move_point(36, 56,  24, -16,  56, 36,  16, -24, 2, 2))
assert(test_move_point(56, 56,  -5,  -5,  56, 56,   0,   0, 2, 2))

-- COLLISION_UP_RIGHT
assert(test_move_point(88, 40,   0,   0,  88, 40,   0,   0, nil, nil))
assert(test_move_point(88, 40,  -5,   0,  83, 40,  -5,   0, nil, nil))
assert(test_move_point(88, 40,   0,   5,  88, 45,   0,   5, nil, nil))
assert(test_move_point(88, 40,   5,   0,  93, 40,   5,   0, nil, nil))
assert(test_move_point(88, 40,   0,  -5,  88, 35,   0,  -5, nil, nil))
assert(test_move_point(80, 48,  -5,  -5,  75, 43,  -5,  -5, nil, nil))
assert(test_move_point(80, 48,   5,   5,  85, 53,   5,   5, nil, nil))
assert(test_move_point(88, 40, -20,   0,  72, 36,   0, -20, 3, 2))
assert(test_move_point(88, 40,   0,  20,  92, 56,  20,   0, 3, 2))
assert(test_move_point(88, 40, -20,  20,  92, 36,  20, -20, 3, 2))
assert(test_move_point(96, 48, -24,   8,  88, 40,   8, -24, 3, 2))
assert(test_move_point(80, 32,  -8,  24,  88, 40,  24,  -8, 3, 2))
assert(test_move_point(72, 36,  16,  24,  92, 56,  24,  16, 3, 2))
assert(test_move_point(92, 56, -24, -16,  72, 36, -16, -24, 3, 2))
assert(test_move_point(72, 56,   5,  -5,  72, 56,   0,   0, 3, 2))

-- COLLISION_DOWN_LEFT
assert(test_move_point(40, 88,   0,   0,  40, 88,   0,   0, nil, nil))
assert(test_move_point(40, 88,   5,   0,  45, 88,   5,   0, nil, nil))
assert(test_move_point(40, 88,   0,  -5,  40, 83,   0,  -5, nil, nil))
assert(test_move_point(40, 88,  -5,   0,  35, 88,  -5,   0, nil, nil))
assert(test_move_point(40, 88,   0,   5,  40, 93,   0,   5, nil, nil))
assert(test_move_point(48, 80,   5,   5,  53, 85,   5,   5, nil, nil))
assert(test_move_point(48, 80,  -5,  -5,  43, 75,  -5,  -5, nil, nil))
assert(test_move_point(40, 88,  20,   0,  56, 92,   0,  20, 2, 3))
assert(test_move_point(40, 88,   0, -20,  36, 72, -20,   0, 2, 3))
assert(test_move_point(40, 88,  20, -20,  36, 92, -20,  20, 2, 3))
assert(test_move_point(32, 80,  24,  -8,  40, 88,  -8,  24, 2, 3))
assert(test_move_point(48, 96,   8, -24,  40, 88, -24,   8, 2, 3))
assert(test_move_point(56, 92, -16, -24,  36, 72, -24, -16, 2, 3))
assert(test_move_point(36, 72,  24,  16,  56, 92,  16,  24, 2, 3))
assert(test_move_point(56, 72,  -5,   5,  56, 72,   0,   0, 2, 3))

-- COLLISION_DOWN_RIGHT
assert(test_move_point(88, 88,   0,   0,  88, 88,   0,   0, nil, nil))
assert(test_move_point(88, 88,  -5,   0,  83, 88,  -5,   0, nil, nil))
assert(test_move_point(88, 88,   0,  -5,  88, 83,   0,  -5, nil, nil))
assert(test_move_point(88, 88,   5,   0,  93, 88,   5,   0, nil, nil))
assert(test_move_point(88, 88,   0,   5,  88, 93,   0,   5, nil, nil))
assert(test_move_point(80, 80,   5,  -5,  85, 75,   5,  -5, nil, nil))
assert(test_move_point(80, 80,  -5,   5,  75, 85,  -5,   5, nil, nil))
assert(test_move_point(88, 88, -20,   0,  72, 92,   0,  20, 3, 3))
assert(test_move_point(88, 88,   0, -20,  92, 72,  20,   0, 3, 3))
assert(test_move_point(88, 88, -20, -20,  92, 92,  20,  20, 3, 3))
assert(test_move_point(96, 80, -24,  -8,  88, 88,   8,  24, 3, 3))
assert(test_move_point(80, 96,  -8, -24,  88, 88,  24,   8, 3, 3))
assert(test_move_point(72, 92,  16, -24,  92, 72,  24, -16, 3, 3))
assert(test_move_point(92, 72, -24,  16,  72, 92, -16,  24, 3, 3))
assert(test_move_point(72, 72,   5,   5,  72, 72,   0,   0, 3, 3))

-- COLLISION_SQUARE
assert(test_move_point(120, 48,   5,   0,  125, 48,   5,   0, nil, nil))
assert(test_move_point(120, 48,   5,   5,  125, 53,   5,   5, nil, nil))
assert(test_move_point(120, 48,   5,  -5,  125, 43,   5,  -5, nil, nil))
assert(test_move_point(144, 24,   0,   5,  144, 29,   0,   5, nil, nil))
assert(test_move_point(144, 24,   5,   5,  149, 29,   5,   5, nil, nil))
assert(test_move_point(144, 24,  -5,   5,  139, 29,  -5,   5, nil, nil))
assert(test_move_point(168, 48,  -5,   0,  163, 48,  -5,   0, nil, nil))
assert(test_move_point(168, 48,  -5,   5,  163, 53,  -5,   5, nil, nil))
assert(test_move_point(168, 48,  -5,  -5,  163, 43,  -5,  -5, nil, nil))
assert(test_move_point(144, 72,   0,  -5,  144, 67,   0,  -5, nil, nil))
assert(test_move_point(144, 72,   5,  -5,  149, 67,   5,  -5, nil, nil))
assert(test_move_point(144, 72,  -5,  -5,  139, 67,  -5,  -5, nil, nil))
assert(test_move_point(120, 48,  12,   0,  124, 48, -12,   0, 5, 2))
assert(test_move_point(120, 48,  12,   8,  124, 56, -12,   8, 5, 2))
assert(test_move_point(120, 48,  12,  -8,  124, 40, -12,  -8, 5, 2))
assert(test_move_point(144, 24,   0,  12,  144, 28,   0, -12, 5, 2))
assert(test_move_point(144, 24,   8,  12,  152, 28,   8, -12, 5, 2))
assert(test_move_point(144, 24,  -8,  12,  136, 28,  -8, -12, 5, 2))
assert(test_move_point(168, 48, -12,   0,  164, 48,  12,   0, 5, 2))
assert(test_move_point(168, 48, -12,   8,  164, 56,  12,   8, 5, 2))
assert(test_move_point(168, 48, -12,  -8,  164, 40,  12,  -8, 5, 2))
assert(test_move_point(144, 72,   0, -12,  144, 68,   0,  12, 5, 2))
assert(test_move_point(144, 72,   8, -12,  152, 68,   8,  12, 5, 2))
assert(test_move_point(144, 72,  -8, -12,  136, 68,  -8,  12, 5, 2))

-- Test for landing exactly on the edge of a tile.
assert(test_move_point(120, 48,  8,  0,  128, 48,  8,  0, nil, nil))
assert(test_move_point(168, 48, -8,  0,  160, 48, -8,  0, nil, nil))
assert(test_move_point(144, 24,  0,  8,  144, 32,  0,  8, nil, nil))
assert(test_move_point(144, 72,  0, -8,  144, 64,  0, -8, nil, nil))

assert(test_move_point(40, 40,  8,  8,  48, 48,  8,  8, nil, nil))
assert(test_move_point(88, 40, -8,  8,  80, 48, -8,  8, nil, nil))
assert(test_move_point(40, 88,  8, -8,  48, 80,  8, -8, nil, nil))
assert(test_move_point(88, 88, -8, -8,  80, 80, -8, -8, nil, nil))

-- Test for pushing against edge of a tile.
assert(test_move_point(128, 48,  8,  0,  120, 48, -8,  0, 5, 2))
assert(test_move_point(160, 48, -8,  0,  168, 48,  8,  0, 5, 2))
assert(test_move_point(144, 32,  0,  8,  144, 24,  0, -8, 5, 2))
assert(test_move_point(144, 64,  0, -8,  144, 72,  0,  8, 5, 2))

assert(test_move_point(48, 48,  8,  8,  40, 40, -8, -8, 2, 2))
assert(test_move_point(80, 48, -8,  8,  88, 40,  8, -8, 3, 2))
assert(test_move_point(48, 80,  8, -8,  40, 88, -8,  8, 2, 3))
assert(test_move_point(80, 80, -8, -8,  88, 88,  8,  8, 3, 3))

-- Test for pushing against the edge of a tile at an oblique angle, such that
-- the start and end tiles are different.
assert(test_move_point(124, 864,  9,  9,  133,  855,  9, -9, 4, 28))
assert(test_move_point(132, 864, -9,  9,  123,  855, -9, -9, 5, 28))
assert(test_move_point(124, 992,  9, -9,  133, 1001,  9,  9, 4, 31))
assert(test_move_point(132, 992, -9, -9,  123, 1001, -9,  9, 5, 31))
assert(test_move_point( 64, 924,  9,  9,   55,  933, -9,  9, 3, 29))
assert(test_move_point( 64, 932,  9, -9,   55,  923, -9, -9, 3, 30))
assert(test_move_point(192, 924, -9,  9,  201,  933,  9,  9, 6, 29))
assert(test_move_point(192, 932, -9, -9,  201,  923,  9, -9, 6, 30))

assert(test_move_point( 92, 868,  9,  0,   92,  859,  0, -9, 3, 28))
assert(test_move_point( 68, 892,  0,  9,   59,  892, -9,  0, 3, 28))
assert(test_move_point(164, 868, -9,  0,  164,  859,  0, -9, 6, 28))
assert(test_move_point(188, 892,  0,  9,  197,  892,  9,  0, 6, 28))
assert(test_move_point( 92, 988,  9,  0,   92,  997,  0,  9, 3, 31))
assert(test_move_point( 68, 964,  0, -9,   59,  964, -9,  0, 3, 31))
assert(test_move_point(164, 988, -9,  0,  164,  997,  0,  9, 6, 31))
assert(test_move_point(188, 964,  0, -9,  197,  964,  9,  0, 6, 31))

-- Test for pushing against corners.
assert(test_move_point(128, 864,  7,  7,  135, 857,  7, -7, 5, 28))
assert(test_move_point(128, 864, -7,  7,  121, 857, -7, -7, 4, 28))
assert(test_move_point(128, 992,  7, -7,  135, 999,  7,  7, 5, 31))
assert(test_move_point(128, 992, -7, -7,  121, 999, -7,  7, 4, 31))
assert(test_move_point( 64, 928,  7,  7,   57, 935, -7,  7, 3, 30))
assert(test_move_point( 64, 928,  7, -7,   57, 921, -7, -7, 3, 29))
assert(test_move_point(192, 928, -7,  7,  199, 935,  7,  7, 6, 30))
assert(test_move_point(192, 928, -7, -7,  199, 921,  7, -7, 6, 29))

-- Test for traversing along edges.
assert(test_move_point(124, 864,  4,  0,  128, 864,  4,  0, nil, nil))
assert(test_move_point(124, 864,  8,  0,  132, 864,  8,  0, nil, nil))
assert(test_move_point(128, 864,  4,  0,  132, 864,  4,  0, nil, nil))
assert(test_move_point(132, 864, -4,  0,  128, 864, -4,  0, nil, nil))
assert(test_move_point(132, 864, -8,  0,  124, 864, -8,  0, nil, nil))
assert(test_move_point(128, 864, -4,  0,  124, 864, -4,  0, nil, nil))

assert(test_move_point(124, 992,  4,  0,  128, 992,  4,  0, nil, nil))
assert(test_move_point(124, 992,  8,  0,  132, 992,  8,  0, nil, nil))
assert(test_move_point(128, 992,  4,  0,  132, 992,  4,  0, nil, nil))
assert(test_move_point(132, 992, -4,  0,  128, 992, -4,  0, nil, nil))
assert(test_move_point(132, 992, -8,  0,  124, 992, -8,  0, nil, nil))
assert(test_move_point(128, 992, -4,  0,  124, 992, -4,  0, nil, nil))

assert(test_move_point( 64, 924,  0,  4,   64, 928,  0,  4, nil, nil))
assert(test_move_point( 64, 924,  0,  8,   64, 932,  0,  8, nil, nil))
assert(test_move_point( 64, 928,  0,  4,   64, 932,  0,  4, nil, nil))
assert(test_move_point( 64, 932,  0, -4,   64, 928,  0, -4, nil, nil))
assert(test_move_point( 64, 932,  0, -8,   64, 924,  0, -8, nil, nil))
assert(test_move_point( 64, 928,  0, -4,   64, 924,  0, -4, nil, nil))

assert(test_move_point(192, 924,  0,  4,  192, 928,  0,  4, nil, nil))
assert(test_move_point(192, 924,  0,  8,  192, 932,  0,  8, nil, nil))
assert(test_move_point(192, 928,  0,  4,  192, 932,  0,  4, nil, nil))
assert(test_move_point(192, 932,  0, -4,  192, 928,  0, -4, nil, nil))
assert(test_move_point(192, 932,  0, -8,  192, 924,  0, -8, nil, nil))
assert(test_move_point(192, 928,  0, -4,  192, 924,  0, -4, nil, nil))

-- Test cases for cutting corners.
--
--    [start] [tile1]
--            [tile2]
--
-- The point is near bottom right corner of [start], with a velocity that
-- will take it to [tile2] in one step.  However, this path will go through
-- [tile1] first, and the resulting velocity should be bouncing toward the
-- left.  If we just add the velocity naively, would end up in [tile2], with
-- the resulting velocity bouncing up, and in the next frame the ball would
-- be stuck because we are inside [tile1].
--
-- The test cases here checks for this diagonal two-tile intersection case,
-- plus rotations and reflections.
assert((world.metadata[5][12] & COLLISION_MASK) == COLLISION_SQUARE)
assert((world.metadata[6][12] & COLLISION_MASK) == COLLISION_SQUARE)
assert(test_move_point(347, 153,  8,  8,  349, 161, -8,  8, 12, 5))
assert(test_move_point(389, 153, -8,  8,  387, 161,  8,  8, 12, 5))
assert(test_move_point(349, 161,  8, -8,  347, 153, -8, -8, 12, 5))
assert(test_move_point(387, 161, -8, -8,  389, 153,  8, -8, 12, 5))

assert((world.metadata[11][5] & COLLISION_MASK) == COLLISION_SQUARE)
assert((world.metadata[11][6] & COLLISION_MASK) == COLLISION_SQUARE)
assert(test_move_point(156, 316,  6,  8,  162, 316,  6, -8, 5, 11))
assert(test_move_point(162, 316, -6,  8,  156, 316, -6, -8, 5, 11))
assert(test_move_point(156, 356,  6, -8,  162, 356,  6,  8, 5, 11))
assert(test_move_point(162, 356, -6, -8,  156, 356, -6,  8, 5, 11))

-- Test for cutting corners where trivial average of scaling factors will
-- not cause the point to collide with the first tile.
assert(test_move_point( 85, 863,   12,  2.4,   94.6,   863, -2.4,  -12, 3, 28))
assert(test_move_point(171, 863,  -12,  2.4,  161.4,   863,  2.4,  -12, 6, 28))
assert(test_move_point( 85, 993,   12, -2.4,   94.6,   993, -2.4,   12, 3, 31))
assert(test_move_point(171, 993,  -12, -2.4,  161.4,   993,  2.4,   12, 6, 31))
assert(test_move_point( 63, 885,  2.4,   12,     63, 894.6,  -12, -2.4, 3, 28))
assert(test_move_point( 63, 971,  2.4,  -12,     63, 961.4,  -12,  2.4, 3, 31))
assert(test_move_point(193, 885, -2.4,   12,    193, 894.6,   12, -2.4, 6, 28))
assert(test_move_point(193, 971, -2.4,  -12,    193, 961.4,   12,  2.4, 6, 31))

assert(test_move_point( 94.6,   863,  2.4,   12,  85, 863,  -12, -2.4,  3, 28))
assert(test_move_point(161.4,   863, -2.4,   12, 171, 863,   12, -2.4,  6, 28))
assert(test_move_point( 94.6,   993,  2.4,  -12,  85, 993,  -12,  2.4,  3, 31))
assert(test_move_point(161.4,   993, -2.4,  -12, 171, 993,   12,  2.4,  6, 31))
assert(test_move_point(   63, 894.6,   12,  2.4,  63, 885, -2.4,  -12,  3, 28))
assert(test_move_point(   63, 961.4,   12, -2.4,  63, 971, -2.4,   12,  3, 31))
assert(test_move_point(  193, 894.6,  -12,  2.4, 193, 885,  2.4,  -12,  6, 28))
assert(test_move_point(  193, 961.4,  -12, -2.4, 193, 971,  2.4,   12,  6, 31))

-- Test for cutting corners where trivial average of scaling factors will
-- cause the point to land on the triangle edge exactly.
assert(test_move_point( 98, 658, -20, -20,  98, 658,  20,  20, 3, 21))
assert(test_move_point( 82, 674, -20, -20,  82, 674,  20,  20, 3, 21))
assert(test_move_point(158, 658,  20, -20, 158, 658, -20,  20, 6, 21))
assert(test_move_point(174, 674,  20, -20, 174, 674, -20,  20, 6, 21))
assert(test_move_point( 98, 750, -20,  20,  98, 750,  20, -20, 3, 24))
assert(test_move_point( 82, 734, -20,  20,  82, 734,  20, -20, 3, 24))
assert(test_move_point(158, 750,  20,  20, 158, 750, -20, -20, 6, 24))
assert(test_move_point(174, 734,  20,  20, 174, 734, -20, -20, 6, 24))

-- Actually the above doesn't exercise the issue where trivial average of
-- scaling factors doesn't due to numeric precision loss.  The one test
-- case known to capture that is below (found by fuzz_test_move_ball).
assert(test_move_point(100.973, 649.5, -12, -12,  98.509, 647.036, 12, 12, 3, 21))

-- Test cases for hitting the corner exactly.
assert(test_move_point(348, 156,  9,  9,  347, 165, -9,  9, 12, 6))
assert(test_move_point(347, 165,  9, -9,  348, 156, -9, -9, 12, 5))
assert(test_move_point(388, 156, -9,  9,  389, 165,  9,  9, 12, 6))
assert(test_move_point(389, 165, -9, -9,  388, 156,  9, -9, 12, 5))

assert(test_move_point(156, 316,  9,  9,  165, 315,  9, -9, 6, 11))
assert(test_move_point(165, 315, -9,  9,  156, 316, -9, -9, 5, 11))
assert(test_move_point(156, 356,  9, -9,  165, 357,  9,  9, 6, 11))
assert(test_move_point(165, 357, -9, -9,  156, 356, -9,  9, 5, 11))

-- Test cases for double bounces.
assert(test_move_point( 92, 762,   6,  12,  102, 766,  12,  -6, 3, 24))
assert(test_move_point(164, 762,  -6,  12,  154, 766, -12,  -6, 6, 24))
assert(test_move_point( 92, 646,   6, -12,  102, 642,  12,   6, 3, 21))
assert(test_move_point(164, 646,  -6, -12,  154, 642, -12,   6, 6, 21))
assert(test_move_point( 70, 740, -12,  -6,   66, 730,   6, -12, 3, 24))
assert(test_move_point( 70, 668, -12,   6,   66, 678,   6,  12, 3, 21))
assert(test_move_point(186, 740,  12,  -6,  190, 730,  -6, -12, 6, 24))
assert(test_move_point(186, 668,  12,   6,  190, 678,  -6,  12, 6, 21))

assert(test_move_point(102, 766, -12,   6,  92, 762,  -6, -12,  4, 25))
assert(test_move_point(154, 766,  12,   6, 164, 762,   6, -12,  5, 25))
assert(test_move_point(102, 642, -12,  -6,  92, 646,  -6,  12,  4, 20))
assert(test_move_point(154, 642,  12,  -6, 164, 646,   6,  12,  5, 20))
assert(test_move_point( 66, 730,  -6,  12,  70, 740,  12,   6,  2, 23))
assert(test_move_point( 66, 678,  -6, -12,  70, 668,  12,  -6,  2, 22))
assert(test_move_point(190, 730,   6,  12, 186, 740, -12,   6,  7, 23))
assert(test_move_point(190, 678,   6, -12, 186, 668, -12,  -6,  7, 22))

-- Start and end with no collision.
assert(test_move_point(176, 144,  18, -18,  194, 126,  18, -18, nil, nil))
assert(test_move_point(176, 144,  18,  -9,  194, 135,  18,  -9, nil, nil))
assert(test_move_point(176, 144,  18,   0,  194, 144,  18,   0, nil, nil))
assert(test_move_point(176, 144,  18,   9,  194, 153,  18,   9, nil, nil))
assert(test_move_point(176, 144,  18,  18,  194, 162,  18,  18, nil, nil))
assert(test_move_point(176, 144,   9,  18,  185, 162,   9,  18, nil, nil))
assert(test_move_point(176, 144,   0,  18,  176, 162,   0,  18, nil, nil))
assert(test_move_point(176, 144,  -9,  18,  167, 162,  -9,  18, nil, nil))
assert(test_move_point(176, 144, -18,  18,  158, 162, -18,  18, nil, nil))
assert(test_move_point(176, 144, -18,   9,  158, 153, -18,   9, nil, nil))
assert(test_move_point(176, 144, -18,   0,  158, 144, -18,   0, nil, nil))
assert(test_move_point(176, 144, -18,  -9,  158, 135, -18,  -9, nil, nil))
assert(test_move_point(176, 144, -18, -18,  158, 126, -18, -18, nil, nil))
assert(test_move_point(176, 144,  -9, -18,  167, 126,  -9, -18, nil, nil))
assert(test_move_point(176, 144,   0, -18,  176, 126,   0, -18, nil, nil))
assert(test_move_point(176, 144,   9, -18,  185, 126,   9, -18, nil, nil))

-- Start and end with no collision (edge and corner cases).
assert(test_move_point(176, 144,  16, -16,  192, 128,  16, -16, nil, nil))
assert(test_move_point(176, 144,  16,  -9,  192, 135,  16,  -9, nil, nil))
assert(test_move_point(176, 144,  16,   0,  192, 144,  16,   0, nil, nil))
assert(test_move_point(176, 144,  16,   9,  192, 153,  16,   9, nil, nil))
assert(test_move_point(176, 144,  16,  16,  192, 160,  16,  16, nil, nil))
assert(test_move_point(176, 144,   9,  16,  185, 160,   9,  16, nil, nil))
assert(test_move_point(176, 144,   0,  16,  176, 160,   0,  16, nil, nil))
assert(test_move_point(176, 144,  -9,  16,  167, 160,  -9,  16, nil, nil))
assert(test_move_point(176, 144, -16,  16,  160, 160, -16,  16, nil, nil))
assert(test_move_point(176, 144, -16,   9,  160, 153, -16,   9, nil, nil))
assert(test_move_point(176, 144, -16,   0,  160, 144, -16,   0, nil, nil))
assert(test_move_point(176, 144, -16,  -9,  160, 135, -16,  -9, nil, nil))
assert(test_move_point(176, 144, -16, -16,  160, 128, -16, -16, nil, nil))
assert(test_move_point(176, 144,  -9, -16,  167, 128,  -9, -16, nil, nil))
assert(test_move_point(176, 144,   0, -16,  176, 128,   0, -16, nil, nil))
assert(test_move_point(176, 144,   9, -16,  185, 128,   9, -16, nil, nil))

assert(test_move_point(176, 144,  20,  24,  196, 168,  20,  24, nil, nil))
assert(test_move_point(176, 144,  24,  20,  200, 164,  24,  20, nil, nil))
assert(test_move_point(176, 144, -20,  24,  156, 168, -20,  24, nil, nil))
assert(test_move_point(176, 144, -24,  20,  152, 164, -24,  20, nil, nil))
assert(test_move_point(176, 144,  20, -24,  196, 120,  20, -24, nil, nil))
assert(test_move_point(176, 144,  24, -20,  200, 124,  24, -20, nil, nil))
assert(test_move_point(176, 144, -20, -24,  156, 120, -20, -24, nil, nil))
assert(test_move_point(176, 144, -24, -20,  152, 124, -24, -20, nil, nil))

assert(test_move_point(180, 185,  12,  12,  192, 197,  12,  12, nil, nil))
assert(test_move_point(185, 180,  12,  12,  197, 192,  12,  12, nil, nil))
assert(test_move_point(172, 185, -12,  12,  160, 197, -12,  12, nil, nil))
assert(test_move_point(167, 180, -12,  12,  155, 192, -12,  12, nil, nil))
assert(test_move_point(180, 167,  12, -12,  192, 155,  12, -12, nil, nil))
assert(test_move_point(185, 172,  12, -12,  197, 160,  12, -12, nil, nil))
assert(test_move_point(172, 167, -12, -12,  160, 155, -12, -12, nil, nil))
assert(test_move_point(167, 172, -12, -12,  155, 160, -12, -12, nil, nil))

local function test_triangle_corner_no_collision(x, y)
	for dx = -4, 4, 2 do
		for dy = -4, 4, 2 do
			for vx = -4, 4, 2 do
				for vy = -4, 4, 2 do
					if not test_move_point(x + dx, y + dy, vx, vy,
					                       x + dx + vx, y + dy + vy, vx, vy,
					                       nil, nil) then
						return false
					end
				end
			end
		end
	end
	return true
end
assert(test_triangle_corner_no_collision(96, 672))
assert(test_triangle_corner_no_collision(96, 736))
assert(test_triangle_corner_no_collision(160, 672))
assert(test_triangle_corner_no_collision(160, 736))

-- Start and end inside the same empty square.
assert(test_move_point(112, 80,  4, -4,  116, 76,  4, -4, nil, nil))
assert(test_move_point(112, 80,  4, -3,  116, 77,  4, -3, nil, nil))
assert(test_move_point(112, 80,  4,  0,  116, 80,  4,  0, nil, nil))
assert(test_move_point(112, 80,  4,  3,  116, 83,  4,  3, nil, nil))
assert(test_move_point(112, 80,  4,  4,  116, 84,  4,  4, nil, nil))
assert(test_move_point(112, 80,  3,  4,  115, 84,  3,  4, nil, nil))
assert(test_move_point(112, 80,  0,  4,  112, 84,  0,  4, nil, nil))
assert(test_move_point(112, 80, -3,  4,  109, 84, -3,  4, nil, nil))
assert(test_move_point(112, 80, -4,  4,  108, 84, -4,  4, nil, nil))
assert(test_move_point(112, 80, -4,  3,  108, 83, -4,  3, nil, nil))
assert(test_move_point(112, 80, -4,  0,  108, 80, -4,  0, nil, nil))
assert(test_move_point(112, 80, -4, -3,  108, 77, -4, -3, nil, nil))
assert(test_move_point(112, 80, -4, -4,  108, 76, -4, -4, nil, nil))
assert(test_move_point(112, 80, -3, -4,  109, 76, -3, -4, nil, nil))
assert(test_move_point(112, 80,  0, -4,  112, 76,  0, -4, nil, nil))
assert(test_move_point(112, 80,  3, -4,  115, 76,  3, -4, nil, nil))

-- Start and end inside the same collision square.
assert(test_move_point(144, 48,  4, -4,  144, 48, 0, 0, 5, 2))
assert(test_move_point(144, 48,  4, -3,  144, 48, 0, 0, 5, 2))
assert(test_move_point(144, 48,  4,  0,  144, 48, 0, 0, 5, 2))
assert(test_move_point(144, 48,  4,  3,  144, 48, 0, 0, 5, 2))
assert(test_move_point(144, 48,  4,  4,  144, 48, 0, 0, 5, 2))
assert(test_move_point(144, 48,  3,  4,  144, 48, 0, 0, 5, 2))
assert(test_move_point(144, 48,  0,  4,  144, 48, 0, 0, 5, 2))
assert(test_move_point(144, 48, -3,  4,  144, 48, 0, 0, 5, 2))
assert(test_move_point(144, 48, -4,  4,  144, 48, 0, 0, 5, 2))
assert(test_move_point(144, 48, -4,  3,  144, 48, 0, 0, 5, 2))
assert(test_move_point(144, 48, -4,  0,  144, 48, 0, 0, 5, 2))
assert(test_move_point(144, 48, -4, -3,  144, 48, 0, 0, 5, 2))
assert(test_move_point(144, 48, -4, -4,  144, 48, 0, 0, 5, 2))
assert(test_move_point(144, 48, -3, -4,  144, 48, 0, 0, 5, 2))
assert(test_move_point(144, 48,  0, -4,  144, 48, 0, 0, 5, 2))
assert(test_move_point(144, 48,  3, -4,  144, 48, 0, 0, 5, 2))

-- Start along the edge of collision square, surrounded by collision squares.
assert(test_move_point(124, 928,  3,  0,  124, 928, 0, 0, 4, 30))
assert(test_move_point(124, 928,  4,  0,  124, 928, 0, 0, 4, 30))
assert(test_move_point(124, 928,  5,  0,  124, 928, 0, 0, 4, 30))
assert(test_move_point(132, 928, -3,  0,  132, 928, 0, 0, 5, 30))
assert(test_move_point(132, 928, -4,  0,  132, 928, 0, 0, 5, 30))
assert(test_move_point(132, 928, -5,  0,  132, 928, 0, 0, 5, 30))
assert(test_move_point(128, 924,  0,  3,  128, 924, 0, 0, 5, 29))
assert(test_move_point(128, 924,  0,  4,  128, 924, 0, 0, 5, 29))
assert(test_move_point(128, 924,  0,  5,  128, 924, 0, 0, 5, 29))
assert(test_move_point(128, 936,  0, -3,  128, 936, 0, 0, 5, 30))
assert(test_move_point(128, 936,  0, -4,  128, 936, 0, 0, 5, 30))
assert(test_move_point(128, 936,  0, -5,  128, 936, 0, 0, 5, 30))

-- Underflow.
assert(1e-6 ~= 0)
assert(test_move_point( 96, 656, -1e-6,    -1,   96, 655,  0, -1, nil, nil))
assert(test_move_point( 96, 656,    -1, -1e-6,   95, 656, -1,  0, nil, nil))
assert(test_move_point( 88, 672, -1e-6,    -1,   88, 671,  0, -1, nil, nil))
assert(test_move_point( 88, 672,    -1, -1e-6,   87, 672, -1,  0, nil, nil))
assert(test_move_point(160, 656,  1e-6,    -1,  160, 655,  0, -1, nil, nil))
assert(test_move_point(160, 656,     1, -1e-6,  161, 656,  1,  0, nil, nil))
assert(test_move_point(168, 672,  1e-6,    -1,  168, 671,  0, -1, nil, nil))
assert(test_move_point(168, 672,     1, -1e-6,  169, 672,  1,  0, nil, nil))
assert(test_move_point( 96, 752, -1e-6,     1,   96, 753,  0,  1, nil, nil))
assert(test_move_point( 96, 752,    -1,  1e-6,   95, 752, -1,  0, nil, nil))
assert(test_move_point( 88, 736, -1e-6,     1,   88, 737,  0,  1, nil, nil))
assert(test_move_point( 88, 736,    -1,  1e-6,   87, 736, -1,  0, nil, nil))
assert(test_move_point(160, 752,  1e-6,     1,  160, 753,  0,  1, nil, nil))
assert(test_move_point(160, 752,     1,  1e-6,  161, 752,  1,  0, nil, nil))
assert(test_move_point(168, 736,  1e-6,     1,  168, 737,  0,  1, nil, nil))
assert(test_move_point(168, 736,     1,  1e-6,  169, 736,  1,  0, nil, nil))
assert(test_move_point( 96, 672, -1e-6, -1e-6,   96, 672,  0,  0, nil, nil))
assert(test_move_point(160, 672,  1e-6, -1e-6,  160, 672,  0,  0, nil, nil))
assert(test_move_point( 96, 736, -1e-6,  1e-6,   96, 736,  0,  0, nil, nil))
assert(test_move_point(160, 736,  1e-6,  1e-6,  160, 736,  0,  0, nil, nil))

-- Miscellaneous test cases.
assert(test_move_point( 69, 596, -9, 6,   68, 602,  9, 6, 2, 19))
assert(test_move_point(187, 586,  9, 6,  188, 592, -9, 6, 7, 19))
assert(test_move_point(90, 860.75, 6, 5.5,  93.75, 864, -5.5, -6, 3, 28))
assert(test_move_point(148.69, 859.31, 6, 4,  154.69, 863.31, 6, 4, nil, nil))
assert(test_move_point(64, 925.38, 4.5, 12,  59.5, 937.38, -4.5, 12, 3, 29))
assert(test_move_point(95, 672, 9, -0.75,  104, 671.25, 9, -0.75, nil, nil))
assert(test_move_point(64, 480, 2, -2,  66, 482, 2, 2, 3, 15))
assert(test_move_point(5056, 4009.37, -0.000113726, -0.718713,  5056, 4008.651287, 0, -0.718713, nil, nil))

-- Return a floating point random number between two ranges, for use with
-- fuzz_test_move_point and fuzz_test_move_ball.
--
-- This differs from "math.random(a,b)" in that it generates floating point
-- numbers instead of integers.
local function random_float_range(a, b)
	return math.random() * (b - a) + a
end

-- Try various random vectors to make sure that move_point doesn't trip over
-- any assertions.
local function fuzz_test_move_point(iterations)
	local start <const> = playdate.getElapsedTime()
	local hits = 0
	for i = 1, iterations do
		-- Select a random goal that is near one of the 5 collision squares,
		-- then pick a random starting position that is less than one tile away
		-- from goal.
		local goal_x <const> = random_float_range(32, 128)
		local goal_y <const> = random_float_range(32, 96)
		local vx <const> = random_float_range(-31, 31)
		local vy <const> = random_float_range(-31, 31)
		local x <const> = goal_x - vx
		local y <const> = goal_y - vy

		local rx <const>, ry <const>, rvx <const>, rvy <const>,
		      hit_x <const>, hit_y <const> =
			move_point(x, y, vx, vy, 0)
		assert(rx, string.format("move_point(%g,%g,%g,%g): rx", x, y, vx, vy))
		assert(ry, string.format("move_point(%g,%g,%g,%g): ry", x, y, vx, vy))
		assert(rvx, string.format("move_point(%g,%g,%g,%g): rvx", x, y, vx, vy))
		assert(rvy, string.format("move_point(%g,%g,%g,%g): rvy", x, y, vx, vy))
		if hit_x then
			assert(hit_y, string.format("move_point(%g,%g,%g,%g): hit_y", x, y, vx, vy))
			hits += 1
		else
			assert(not hit_y, string.format("move_point(%g,%g,%g,%g): not hit_y", x, y, vx, vy))
		end
	end

	-- Output some timing info at the end, and also the fraction of bounces.
	-- The bounce rate is meant to verify whether move_point exercised any
	-- bouncing routines.
	--
	-- On my machine, I get about 0.00048s per move for debug builds, and
	-- 2e-05s per move for release builds, so move_point runs 24x faster
	-- without all the debug logging bits.
	local done <const> = playdate.getElapsedTime()
	if iterations > 0 then
		print(string.format("move_point: %gs per move, bounce rate = %g", (done - start) / iterations, hits / iterations))
	end
	return true
end

-- Only run the fuzz test inside the simulator, since it has enough speed
-- for that purpose.  But we only have to do a few iterations here, since
-- we get more coverage through fuzz_test_move_ball.
assert(fuzz_test_move_point(playdate.isSimulator and 50 or 0))

-- Clamp a velocity value between -MAX_VELOCITY and MAX_VELOCITY.
local function apply_speed_limit(v)
	return min(max(v, -MAX_VELOCITY), MAX_VELOCITY)
end

-- Move ball with some set of velocities.  Returns:
-- new_x, new_y, new_vx, new_vy, hit_x, hit_y
local function sub_move_ball(init_x, init_y, vx, vy)
	-- Save the original vertical velocity.  We will need this for adjustments
	-- later when ball is near the floor.
	local init_vy <const> = vy

	-- Apply gravity.
	vy += GRAVITY

	-- Apply speed limit in all directions.
	--
	-- In theory, we only need to apply speed limit in the downward direction,
	-- since that's the only direction that is getting acceleration.  But due
	-- to change in velocity directions from all the sloped surfaces, there
	-- is no telling that one of the other 3 directions can't temporarily
	-- exceed the terminal velocity, hence the uniform speed limit.
	vx = apply_speed_limit(vx)
	vy = apply_speed_limit(vy)

	-- Set ceiling of how high the ball can go before applying gravity.
	-- See comments below near adjusted_gravity.
	local ball_ceiling <const> =
		init_y - sqrt(vx * vx + init_vy * init_vy) * BOUNCE_VELOCITY_RATIO

	-- Collect results from 8 test points.  We may not do all 8 tests, instead
	-- we will stop early if we saw two collisions.
	--
	-- first_index and second_index is used to model the extent of the ball by
	-- adding a test point that is at the intersection of the ball tangents
	-- (see comments near BALL_ADDITIONAL_TEST_POINTS earlier).  If both
	-- first_index and second_index have the same parity, it means we might
	-- have skipped a point in the middle.  To illustrate, these are the
	-- three test points in the upper right quadrant of the ball:
	--
	--               second_index
	--                 ++++X++++
	--             ++++     .   ++++
	--                        .     ++
	--                         .      X  skipped point
	--                           .     +
	--                            .     +
	--                              .   +
	--                               .   +
	--                                 . +
	--                                   X first_index
	--                                   +
	--
	-- Note that if we draw a chord connecting first_index and second_index,
	-- we will find that the "skipped point" is placed beyond that chord and
	-- further away from the center of the ball.  This is problematic because
	-- if the ball were to go toward a sloped surface that is facing down and
	-- left, because the two test points at first_index and second_index are
	-- closer to the center, we might see a bounce that is shallower than what
	-- we would have seen if "skipped point" were to come in contact with the
	-- wall.  Due to the shallower bounce, "skipped point" may be embedded in
	-- the wall in the next frame, and the ball would be stuck.
	--
	-- To avoid this problem, we want first_index and second_index to have
	-- different parities such that they are likely adjacent points on the
	-- ball.  The entries in BALL_TEST_POINTS were sorted for this purpose,
	-- but it's impossible to guarantee that the last point (upper right)
	-- would be observed before its two adjacent points purely by sorting the
	-- entries.  Instead, we will run extra tests until we got two indices of
	-- different parity, or until we run out of test points.
	local index_order <const> =
		vy < 0 and (vx < 0 and BALL_INDEX_ORDER_UP_LEFT or
		                       BALL_INDEX_ORDER_UP_RIGHT) or
		           (vx < 0 and BALL_INDEX_ORDER_DOWN_LEFT or
		                       BALL_INDEX_ORDER_DOWN_RIGHT)
	assert(#index_order == #BALL_TEST_POINTS)
	local first_index = 0
	local second_index = 0
	local results = {nil, nil, nil, nil, nil, nil, nil, nil}
	local hit_index = {}
	assert(debug_trace_move_point_reset())
	for o = 1, #BALL_TEST_POINTS do
		local i <const> = index_order[o]
		local edge_x <const> = init_x + BALL_TEST_POINTS[i][1]
		local edge_y <const> = init_y + BALL_TEST_POINTS[i][2]
		local nx, ny, nvx, nvy, hit_tile_x, hit_tile_y

		local adjusted_gravity = GRAVITY
		for j = 1, MAX_GRAVITY_REDUCTION_ITERATIONS do
			nx, ny, nvx, nvy, hit_tile_x, hit_tile_y = move_point(edge_x, edge_y, vx, vy, 0)
			assert(debug_trace_move_point_append(edge_x, edge_y, vx, vy, string.format("probe_%d_%s", i, test_index_label(i))))
			if hit_tile_y and vy > 0 and nvy < 0 and
			   init_y + (ny - edge_y) < ball_ceiling then
				-- If a collision would cause us to bounce higher than we should
				-- go, it means the ball is rising from what should have been a
				-- standstill due to excessive gravity pushing against the floor.
				-- We will reduce the effects of gravity and try again.
				--
				-- Note that this only affects bounces against the floor, which is
				-- what "vy > 0" and "nvy < 0" is meant to capture (i.e. old
				-- velocity was downward and new velocity is upward).  This means
				-- upward bounces have no ceiling, and is only limited by velocity.
				--
				-- We can avoid this if we set GRAVITY to be less than 0.5, but
				-- the ball would fall too slowly in that world.
				--
				-- We can also avoid this if we do physics properly.  The reason
				-- why balls don't bounce higher than their original dropped height
				-- is because gravity is an acceleration, and balls dropped from
				-- closer to the floor will experience less acceleration than balls
				-- dropped from greater heights.  This is unlike how we implemented
				-- it here where gravity is applied as an instantaneous impulse
				-- independent of height.  It might make sense if we were to apply
				-- different gravitational impulse depending on height, but that
				-- requires knowing the distance to the floor ahead of time.  Here
				-- we emulate the adjusted impulse by doing adjustment after the
				-- fact and retry the drop.  It looks and feels roughly correct
				-- during gameplay, so there.
				adjusted_gravity /= 2
				vy = apply_speed_limit(init_vy + adjusted_gravity)
			else
				break
			end
		end

		-- Record this result.
		results[i] = {nx - edge_x, ny - edge_y, nvx, nvy, hit_tile_x, hit_tile_y}
		if hit_tile_x then
			table.insert(hit_index, i)

			-- Once we have four contacts, we have a pretty good idea of what
			-- the terrain is shaped like, and don't need to look further.
			if #hit_index >= 4 then
				break
			end
		end
	end

	-- If there were no collisions, we should be able to apply any one to
	-- the center of the ball to get the new position.  Note that despite
	-- the lack of collisions, the deltas are not guaranteed to be equal,
	-- since they might have been reduced to compensate for excessive gravity
	-- (that is, there might have been collisions for a point previously,
	-- but after reducing gravity the ball no longer collides).
	if #hit_index == 0 then
		assert(results[1])
		local entry <const> = results[1]
		assert(debug_trace_move_point_match_and_append("probe_1_", "zero_contact_move"))

		-- Update ball position.
		--
		-- Note that we are using update_ball_position for this instead of just
		-- assigning the updated position to world.balls[].  This is so that the
		-- historical position of the ball is stored in the ring buffer.
		local new_x <const> = init_x + entry[1]
		local new_y <const> = init_y + entry[2]

		-- No hits.
		assert(not entry[5])
		assert(not entry[6])

		-- Return the velocities from move_ball.
		--
		-- Despite the lack of collisions, the resulting velocities are not
		-- guaranteed to be the same as before, because the velocity might have
		-- gone through some precision loss due to recursive move_ball() calls.
		-- Also, vertical velocity might have gone through some compensation due
		-- to excessive gravity.  This is why we return the velocities that were
		-- returned by move_ball, as opposed to the original velocities.
		return new_x, new_y, entry[3], entry[4], nil, nil
	end

	-- Select up to two collisions that are representative of the shape of the
	-- terrain, from which we will add a new test point to better model the
	-- bounces against that terrain.  The idea is that if the ball were a zero
	-- radius point, we could just trace the bounces for that one point and be
	-- done.  Since ball actually have nonzero radius, we add a new test point
	-- that models the ball as if the center were up against the wall.
	--
	-- Where we place that test point depends on which corner we are up against,
	-- it's basically one of these:
	--
	--            ******           #         +++******+++        #
	--           *      *          #         + *      * +        #
	--          *        *         #         +*        *+        #
	--         *          *        #         *          *        #
	--         *   ball   *        #         *  square  *        #
	--         *          *        #         *          *        #
	--          *        *         #         +*        *+        #
	--           *      *          #         + *      * +        #
	--            ******   --__    #         +++******++X--__    #
	--                         --> #                         --> #
	--                             #                             #
	--      ########################      ########################
	--
	--            ******                        ++++++
	--           *      *                      +      +
	--          *        *            #       +        +            #
	--         *          *          #       +          +          #
	--         *   ball   *         #        + octagon  +         #
	--         *          *        #         +          +        #
	--          *        *        #           +        +        #
	--           *      *        #             +      +        #
	--            ******   -->  #               +++++X   -->  #
	--                         #                             #
	--                        #                             #
	--      ##################            ##################
	--
	local first_index = nil
	local second_index = nil
	if #hit_index >= 2 then
		-- First we need to know whether we are up against a square corner or
		-- a slanted corner.  If we collided with any triangles at all, we will
		-- assume slanted, otherwise we will assume square.
		local slanted = false
		for i = 1, #hit_index do
			local entry <const> = results[hit_index[i]]
			assert(entry[5])
			assert(entry[6])
			local collision_bits <const> =
				world.metadata[entry[6]][entry[5]] & COLLISION_MASK
			assert(collision_bits ~= 0)
			if collision_bits ~= COLLISION_SQUARE then
				slanted = true
				break
			end
		end

		-- Now we need to select two indices for BALL_ADDITIONAL_TEST_POINTS.
		if slanted then
			-- For slanted corners, we prefer two indices that are of different
			-- parities, e.g. RIGHT_DOWN=4 and RIGHT=5.
			first_index = hit_index[1]
			for i = 2, #hit_index do
				if ((hit_index[i] ~ first_index) & 1) == 1 then
					second_index = hit_index[i]
					break
				end
			end
		else
			-- For square corners, we prefer two indices that are axis-aligned,
			-- e.g. RIGHT and DOWN.
			for i = 1, #hit_index do
				if (hit_index[i] & 1) == 1 then
					assert(hit_index[i] == BALL_TEST_INDEX_UP or hit_index[i] == BALL_TEST_INDEX_DOWN or hit_index[i] == BALL_TEST_INDEX_LEFT or hit_index[i] == BALL_TEST_INDEX_RIGHT)
					if not first_index then
						first_index = hit_index[i]
					elseif not second_index then
						second_index = hit_index[i]
						break
					end
				end
			end
		end

		-- If we didn't get our two indices, we will just take whatever we got.
		if not second_index then
			for i = 1, #hit_index do
				if not first_index then
					first_index = hit_index[i]
				elseif not second_index then
					if first_index ~= hit_index[i] then
						second_index = hit_index[i]
						break
					end
				end
			end
		end
		assert(first_index)
		assert(second_index)
		assert(first_index ~= second_index)
	else
		first_index = hit_index[1]
	end
	assert(first_index)

	-- If we got indices from two collisions, we can use that to select one
	-- additional test point from BALL_ADDITIONAL_TEST_POINTS.
	if second_index and
	   BALL_ADDITIONAL_TEST_POINTS[first_index] and
	   BALL_ADDITIONAL_TEST_POINTS[first_index][second_index] then
		assert(debug_trace_move_point_match_and_append("probe_" .. first_index .. "_", "double_contact_move"))
		assert(debug_trace_move_point_match_and_append("probe_" .. second_index .. "_", "double_contact_move"))
		local offset <const> = BALL_ADDITIONAL_TEST_POINTS[first_index][second_index]
		local corner_x <const> = init_x + offset[1]
		local corner_y <const> = init_y + offset[2]
		local nx, ny, nvx, nvy, hit_tile_x, hit_tile_y

		local adjusted_gravity = GRAVITY
		for j = 1, MAX_GRAVITY_REDUCTION_ITERATIONS do
			nx, ny, nvx, nvy, hit_tile_x, hit_tile_y =
				move_point(corner_x, corner_y, vx, vy, 0)
			if hit_tile_y and vy > 0 and nvy < 0 and
			   init_y + (ny - corner_y) < ball_ceiling then
				adjusted_gravity /= 2
				vy = apply_speed_limit(init_vy + adjusted_gravity)
			else
				break
			end
		end
		local dx = nx - corner_x
		local dy = ny - corner_y

		-- Check if the result from the additional test point would cause us
		-- to get stuck.  If so, we would rather stick with the results from
		-- one of the earlier bounces.
		--
		-- This tend to happen near convex corners, where the enclosing octagon
		-- that approximates our circle could extend just enough inside the
		-- collision region.
		--
		-- A different policy would have been to let movements that start inside
		-- collision regions to just go through, but that tend to lead to less
		-- predictable bugs.
		if nvx == 0 and nvy == 0 then
			local fallback_index = nil
			if results[first_index][3] ~= 0 and results[first_index][4] ~= 0 then
				if results[second_index][3] ~= 0 or results[second_index][4] ~= 0 then
					-- Two results to choose from, prefer second one if the second
					-- result has a vertical bounce but the first result didn't.
					if results[second_index][4] * vy < 0 and
					   results[first_index][4] * vy > 0 then
						fallback_index = second_index
					else
						fallback_index = first_index
					end
				else
					fallback_index = first_index
				end
			else
				if results[second_index][3] ~= 0 or results[second_index][4] ~= 0 then
					fallback_index = second_index
				end
			end
			if fallback_index then
				assert(debug_trace_move_point_match_and_append("probe_" .. fallback_index .. "_", "fallback"))
				dx, dy, nvx, nvy, hit_tile_x, hit_tile_y = table.unpack(results[fallback_index])
			end
		end

		-- Apply delta to ball position.
		local new_x <const> = init_x + dx
		local new_y <const> = init_y + dy

		-- Return updated velocities, with magnitude reduced a bit to account
		-- for energy lost due to collision.
		--
		-- By losing some velocity on each bounce, the ball will eventually
		-- come to a halt if there are enough walls around.  If there are no
		-- walls, gravity will cause constant collisions against the ground
		-- and we will lose velocity that way, so the ball will eventually
		-- come to a halt on flat surfaces as well.  So we get the effects of
		-- friction for free just by adding gravity.
		return new_x, new_y, nvx * BOUNCE_VELOCITY_RATIO, nvy * BOUNCE_VELOCITY_RATIO, hit_tile_x, hit_tile_y
	end
	assert(debug_trace_move_point_match_and_append("probe_" .. first_index .. "_", "single_contact_move"))

	-- Either there was exactly one collision, or it was a two collision
	-- combination that we don't know how to handle.  Either way, we will apply
	-- deltas from the first collision we found to the center of the ball.
	local entry <const> = results[first_index]
	assert(entry[5])
	assert(entry[6])
	local new_x <const> = init_x + entry[1]
	local new_y <const> = init_y + entry[2]

	return new_x, new_y, entry[3] * BOUNCE_VELOCITY_RATIO, entry[4] * BOUNCE_VELOCITY_RATIO, entry[5], entry[6]
end

-- Given cell coordinates inside a collision square, return the smallest offset
-- needed to escape this tile.
local function get_square_escape_offset(cell_x, cell_y)
	local dx <const> = cell_x < HALF_TILE_SIZE and -cell_x or TILE_SIZE - cell_x
	local dy <const> = cell_y < HALF_TILE_SIZE and -cell_y or TILE_SIZE - cell_y
	return dx, dy
end
assert(({get_square_escape_offset(0, 0)})[1] == 0)
assert(({get_square_escape_offset(1, 0)})[1] == -1)
assert(({get_square_escape_offset(15, 0)})[1] == -15)
assert(({get_square_escape_offset(16, 0)})[1] == 16)
assert(({get_square_escape_offset(31, 0)})[1] == 1)
assert(({get_square_escape_offset(32, 0)})[1] == 0)
assert(({get_square_escape_offset(0.5, 0)})[1] == -0.5)
assert(({get_square_escape_offset(31.5, 0)})[1] == 0.5)
assert(({get_square_escape_offset(0, 0)})[2] == 0)
assert(({get_square_escape_offset(0, 1)})[2] == -1)
assert(({get_square_escape_offset(0, 15)})[2] == -15)
assert(({get_square_escape_offset(0, 16)})[2] == 16)
assert(({get_square_escape_offset(0, 31)})[2] == 1)
assert(({get_square_escape_offset(0, 32)})[2] == 0)
assert(({get_square_escape_offset(0, 0.5)})[2] == -0.5)
assert(({get_square_escape_offset(0, 31.5)})[2] == 0.5)

-- Given cell coordinates inside a collision triangle, return the smallest
-- offset needed to escape this tile.
local function get_triangle_escape_offset(collision_bits, cell_x, cell_y)
	assert((collision_bits & ~COLLISION_MASK) == 0)
	if collision_bits == COLLISION_UP_LEFT or
	   collision_bits == COLLISION_DOWN_RIGHT then
		local d <const> = (TILE_SIZE - cell_x - cell_y) / 2
		return d, d
	else
		assert(collision_bits == COLLISION_UP_RIGHT or collision_bits == COLLISION_DOWN_LEFT)
		local d <const> = (cell_y - cell_x) / 2
		return d, -d
	end
end

local function test_get_triangle_escape_offset(collision_bits, cell_x, cell_y, edx, edy)
	local adx <const>, ady <const> =
		get_triangle_escape_offset(collision_bits, cell_x, cell_y)
	if edx ~= adx then print("expected dx", edx, "actual dx", adx) end
	if edy ~= ady then print("expected dy", edy, "actual dy", ady) end
	return edx == adx and edy == ady
end
assert(test_get_triangle_escape_offset(COLLISION_UP_LEFT, 17, 17, -1, -1))
assert(test_get_triangle_escape_offset(COLLISION_UP_LEFT, 18, 17, -1.5, -1.5))
assert(test_get_triangle_escape_offset(COLLISION_UP_LEFT, 17, 18, -1.5, -1.5))
assert(test_get_triangle_escape_offset(COLLISION_UP_LEFT, 17, 19, -2, -2))
assert(test_get_triangle_escape_offset(COLLISION_DOWN_RIGHT, 15, 15, 1, 1))
assert(test_get_triangle_escape_offset(COLLISION_DOWN_RIGHT, 14, 15, 1.5, 1.5))
assert(test_get_triangle_escape_offset(COLLISION_DOWN_RIGHT, 15, 14, 1.5, 1.5))
assert(test_get_triangle_escape_offset(COLLISION_DOWN_RIGHT, 15, 13, 2, 2))
assert(test_get_triangle_escape_offset(COLLISION_UP_RIGHT, 15, 17, 1, -1))
assert(test_get_triangle_escape_offset(COLLISION_UP_RIGHT, 14, 17, 1.5, -1.5))
assert(test_get_triangle_escape_offset(COLLISION_UP_RIGHT, 15, 18, 1.5, -1.5))
assert(test_get_triangle_escape_offset(COLLISION_UP_RIGHT, 15, 19, 2, -2))
assert(test_get_triangle_escape_offset(COLLISION_DOWN_LEFT, 17, 15, -1, 1))
assert(test_get_triangle_escape_offset(COLLISION_DOWN_LEFT, 18, 15, -1.5, 1.5))
assert(test_get_triangle_escape_offset(COLLISION_DOWN_LEFT, 17, 14, -1.5, 1.5))
assert(test_get_triangle_escape_offset(COLLISION_DOWN_LEFT, 17, 13, -2, 2))

-- Update escape vector from input.
local function update_escape_vector(escape, new_dx, new_dy)
	if not escape.d2 then
		escape.d2 = distance2(new_dx, new_dy)
		escape.dx = new_dx
		escape.dy = new_dy
		return
	end

	-- If multiple escape vectors are available, we choose the one that results
	-- in the smallest delta.  It's not the case that we need the largest delta
	-- so that we can move all points away, since the escape directions might
	-- actually be different for each point.  Instead, we choose the smallest
	-- delta so that at least one test point is unstuck for the next frame, and
	-- we would be able to move the ball if we have that one test point.
	--
	-- Usually it doesn't matter since in the common case, if we were to get
	-- stuck at all, it would be just a single point that gets stuck.
	local new_d2 <const> = distance2(new_dx, new_dy)
	if escape.d2 > new_d2 then
		escape.d2 = new_d2
		escape.dx = new_dx
		escape.dy = new_dy
	end
end

-- Check for stuck test points after ball has moved.  If the ball is stuck,
-- return the minimum offset to get it unstuck, otherwise return pair of nils.
local function try_digging_ball_out_of_walls(x, y)
	local escape = {d2 = nil, dx = nil, dy = nil}

	for i = 1, #BALL_TEST_POINTS do
		local edge_x <const> = x + BALL_TEST_POINTS[i][1]
		local edge_y <const> = y + BALL_TEST_POINTS[i][2]
		local tile_x <const>, tile_y <const> =
			get_tile_position(floor(edge_x), floor(edge_y))
		local collision_bits <const> =
			world.metadata[tile_y][tile_x] & COLLISION_MASK
		if collision_bits == COLLISION_SQUARE then
			if not ((edge_x == floor(edge_x) and (edge_x & 31) == 0) or
			        (edge_y == floor(edge_y) and (edge_y & 31) == 0)) then
				local cell_x <const> = edge_x - (floor(edge_x) & ~31)
				local cell_y <const> = edge_y - (floor(edge_y) & ~31)

				local s_dx <const>, s_dy <const> =
					get_square_escape_offset(cell_x, cell_y)
				update_escape_vector(escape, s_dx, s_dy)
			end
		else
			local cell_x <const> = edge_x - (floor(edge_x) & ~31)
			local cell_y <const> = edge_y - (floor(edge_y) & ~31)
			if inside_triangular_region_sans_boundary(collision_bits, cell_x, cell_y) then
				local t_dx <const>, t_dy <const> =
					get_triangle_escape_offset(collision_bits, cell_x, cell_y)
				update_escape_vector(escape, t_dx, t_dy)
			end
		end
	end
	return escape.dx, escape.dy
end

-- Check for unexpected deceleration to zero after a bounce.
--
-- The normal way for a ball to stop is to have lost enough velocity through
-- bounces, but because each bounce only reduce the velocity proportionally,
-- the velocity is never zero.  The only time we see velocities being exactly
-- zero is when move_point has detected the started position being inside some
-- collision region, and that's usually* a bug.
--
-- This check only happens in debug builds since it's wrapped in assert().
-- In release builds, the ball may still stop unexpectedly and it will look
-- weird, but player can still continue playing normally -- either the ball
-- can be picked up from the stuck position, or player can summon the ball
-- so that the ball is movable again.
--
-- * Note: it's *usually* a bug, but we know of at least one case where the
-- sudden deceleration is due to floating point precision issues.  Consider
-- these two movements:
--
--   x =  178.64, y =  658.64, vx = -3.25, vy = -4.42
--   x = 4978.64, y = 2482.64, vx = -3.25, vy = -4.42
--
-- The tile at both of these starting positions are COLLISION_DOWN_LEFT, and
-- both of the sub-cell coordinates are (18.64, 18.64), so we should expect the
-- same edge bounce behavior from both, but this is not the case, and it has
-- to do with floating point precision:
--
--   178.64 = 178.6399993896484375
--   658.64 = 658.6400146484375
--
--   4978.64 = 4978.64013671875
--   2482.64 = 2482.639892578125
--
-- These are the values that actually got stored according to
-- https://www.h-schmidt.net/FloatConverter/IEEE754.html
--
-- I also tried just evaluating these expressions in irb (interactive Ruby):
--
--   178.64 - 160 = 18.639999999999986
--   658.64 - 640 = 18.639999999999986
--
--   4978.64 - 4960 = 18.640000000000327
--   2482.64 - 2464 = 18.639999999999873
--
-- In both IEEE754's single-precision representation or Ruby's double-precision
-- representation, (4978.64, 2482.64) is inside the collision region to start
-- with (because cell_x > cell_y), and thus move_point would fail because
-- it was stuck from the very start.
local function check_for_unexpected_stop(x, y, vx, vy, new_vx, new_vy, bounced)
	-- Don't apply checks if there were no collisions, since it's normal for a
	-- ball to reach zero velocity at the apex of a parabolic path, due to
	-- gravity decelerating its vertical velocity to zero.
	if not bounced then
		return true
	end

	-- Nothing to fix if we weren't stuck.
	if new_vx ~= 0 or new_vy ~= 0 then
		return true
	end

	-- We log the error here, and just leave the ball as stuck.  We could
	-- try to fix it, but most fixes are expensive, and these cases are
	-- relatively rare.
	print(string.format("move_ball(%g,%g,%g,%g): unexpected stop", x, y, vx, vy))
	dump_ball_history()
	return true
end

-- Given ball index and velocity, update ball position, returns a tuple of
-- 4 elements:
-- new_vx, new_vy, hit_tile_x, hit_tile_y
local function move_ball(ball_index, vx, vy)
	local b <const> = world.balls[ball_index]
	local init_x <const> = b[1]
	local init_y <const> = b[2]

	-- Do the movement.
	--
	-- This is a separate function mostly so that it looks cleaner.  Previously,
	-- there were some thought that we can call sub_move_ball repeatedly with
	-- different parameters, such as dividing a single step into two separate
	-- steps with half the velocities at each step (assuming that we also take
	-- gravity as a parameter).  We did not end up doing that because such
	-- subdivisions never helped.
	--
	-- The one trick we found that fixed practically all stoppages is
	-- try_digging_ball_out_of_walls().
	local new_x, new_y, new_vx, new_vy, hit_tile_x, hit_tile_y =
		sub_move_ball(init_x, init_y, vx, vy)
	assert(new_x, string.format("move_ball(%g,%g,%g,%g): new_x", init_x, init_y, vx, vy))
	assert(new_y, string.format("move_ball(%g,%g,%g,%g): new_y", init_x, init_y, vx, vy))
	assert(distance2(new_x - init_x, new_y - init_y) <= distance2(vx, abs(vy) + GRAVITY) + 4)

	-- Check for sudden deceleration.  This is usually a bug.
	assert(check_for_unexpected_stop(init_x, init_y, vx, vy, new_vx, new_vy, hit_tile_x or hit_tile_y))

	-- Check for ball becoming stuck after the current move, and adjust ball
	-- position accordingly.  This is also a bug, but it's something very
	-- difficult to fix with how we model the ball.  Instead of taking all
	-- corner cases into account, we just shift the ball away from the wall
	-- such that it's no longer stuck.
	--
	-- There is at least one known case where we need this feature:
	--
	--             ****
	--            *    *
	--           *      *  Ball is moving at (+6, +3.25)
	--           *      *
	--            *    *
	--             ****
	--    +---------+_   <-- Lowest point of the ball touches corner
	--    |         | -_
	--    |         |   -_
	--    |         |     -_
	--    |         |       -_
	--    |         |         -
	--    +---------+---------+
	--
	-- Because the corner is on the left edge of the triangle tile, ball will
	-- have a bounce vector of (+3.25, +6+gravity) after the move.  In the next
	-- frame, ball will be stuck because (+3.25, +6+g) puts the lower left test
	-- point inside the collision region.
	--
	-- One thought is if we had picked the square tile to the left, the bounce
	-- vector would be up at (+3.25, -6+g), and we wouldn't be stuck in the next
	-- frame.  This is arguably more natural, but requires more heuristics to
	-- select which tiles to test.  Also, even though it would have worked in
	-- this specific case, there are scenarios where simply don't have another
	-- tile to bounce off of.
	--
	-- Rather building more heuristics to select where to bounce, we implemented
	-- the one guarantee fix-all, which is to just shift the ball away when it
	-- is embedded in the wall.  Typical shifts will be just one pixel
	-- diagonally, so it should not be visually jarring.
	--
	-- Note that try_digging_ball_out_of_walls fixed "practically all"
	-- stoppages, but even this is not 100%.  One way to get stuck is to ram the
	-- ball at full speed into the wall with an arm motion (as opposed to a
	-- wrist motion), and release the ball just as the ball touches the wall.
	-- In debug builds, we will trip over check_for_unexpected_stop() above, and
	-- occasionally the ball may fall inside diagonal walls.  At this point it
	-- should probably be considered a feature, like, sometimes things do stick
	-- in real life if I throw them at a wall hard enough.
	local dx <const>, dy <const> = try_digging_ball_out_of_walls(new_x, new_y)
	if dx then
		assert(debug_log_excessive_adjustment(init_x, init_y, vx, vy, new_x, new_y, new_vx, new_vy, dx, dy))
		new_x += dx
		new_y += dy
	end

	-- Update ball position.
	world.update_ball_position(ball_index, new_x, new_y)

	return new_vx, new_vy, hit_tile_x, hit_tile_y
end

-- Wrapper for running move_ball and compare against expected results.
local function test_move_ball(x, y, vx, vy, ex, ey, evx, evy, ehx, ehy)
	-- Temporarily populate ball list with our test ball.  It was previously
	-- an empty list because world.init has not been called yet.  We will
	-- restore it back to empty list before this function returns, so that
	-- other tests that were expecting empty lists will not be affected.
	assert(#world.balls == 0)
	local TEST_BALL <const> = 1
	world.balls = {{x, y}}

	-- Set update_ball_position to overwrite ball position, without recording
	-- history.  This function will be replaced later.
	world.update_ball_position = function(index, x, y)
		world.balls[index][1] = x
		world.balls[index][2] = y
	end

	-- Use a more generous margin here (unlike test_move_point), since
	-- the floating point gravity determining the exact outcomes difficult.
	local MARGIN <const> = 1

	debug_trace_move_point_reset()
	local avx <const>, avy <const>, ahx <const>, ahy <const> =
		move_ball(TEST_BALL, vx, vy)
	local ax <const> = world.balls[TEST_BALL][1]
	local ay <const> = world.balls[TEST_BALL][2]

	-- Compare expected versus actual results.
	if compare_move_results(ax, ay, avx, avy, ahx, ahy,
	                        ex, ey, evx, evy, ehx, ehy, MARGIN) then
		world.balls = {}
		return true
	end

	-- Note that one test we have explicitly avoided is to check whether the
	-- distance travelled by the ball is less than input velocity plus gravity.
	-- This check is not sound because the actual distance travelled by the ball
	-- may be greater due to adjustments from try_digging_ball_out_of_walls.

	debug_trace_move_point_dump()
	world.balls = {}
	return false
end

assert(test_move_ball(128, 544, 0, 0,  128, 544+GRAVITY, 0, GRAVITY, nil, nil))

-- Test two-contact bounces that require adjacent test points.
assert(test_move_ball(120, 864-17, 0,  6-GRAVITY,  120, 864-21, 0, -4.5, 4, 28))
assert(test_move_ball(120, 992+17, 0, -6-GRAVITY,  120, 992+21, 0,  4.5, 4, 31))

assert(test_move_ball( 64-17, 920,  6, -GRAVITY,   64-21, 920, -4.5, 0, 3, 29))
assert(test_move_ball(192+17, 920, -6, -GRAVITY,  192+21, 920,  4.5, 0, 6, 29))

assert(test_move_ball(176+12, 880-12, -6,  6-GRAVITY,  176+16.6, 880-16.6,  4.5, -4.5, 6, 28))
assert(test_move_ball( 80-12, 880-12,  6,  6-GRAVITY,   80-16.6, 880-16.6, -4.5, -4.5, 3, 28))
assert(test_move_ball(176+12, 976+12, -6, -6-GRAVITY,  176+16.6, 976+16.6,  4.5,  4.5, 6, 31))
assert(test_move_ball( 80-12, 976+12,  6, -6-GRAVITY,   80-16.6, 976+16.6, -4.5,  4.5, 3, 31))

-- Test corner bounces.
assert(test_move_ball(127, 582, -10, 10,  117, 591.25, -7.5, -8.1, 4, 20))
assert(test_move_ball(128, 582, -10, 10,  118, 591.25, -7.5, -8.1, 4, 20))
assert(test_move_ball(129, 582, -10, 10,  119, 591.25, -7.5, -8.1, 4, 20))

assert(test_move_ball(159, 864-16,  6,  4-GRAVITY, 165,  844,  4.5,   -4,   5,  28))
assert(test_move_ball(160, 864-16,  6,  4-GRAVITY, 165,  853,    3,  4.5,   6,  28))
assert(test_move_ball(161, 864-16,  6,  4-GRAVITY, 167,  852,    6,    4, nil, nil))
assert(test_move_ball( 97, 864-16, -6,  4-GRAVITY,  91,  844, -4.5,   -4,   4,  28))
assert(test_move_ball( 96, 864-16, -6,  4-GRAVITY,  91,  853,   -3,  4.5,   3,  28))
assert(test_move_ball( 95, 864-16, -6,  4-GRAVITY,  89,  852,   -6,    4, nil, nil))
assert(test_move_ball(159, 992+16,  6, -4-GRAVITY, 165, 1012,  4.5,    4,   5,  31))
assert(test_move_ball(160, 992+16,  6, -4-GRAVITY, 165, 1003,    3, -4.5,   6,  31))
assert(test_move_ball(161, 992+16,  6, -4-GRAVITY, 167, 1004,    6,   -4, nil, nil))
assert(test_move_ball( 97, 992+16, -6, -4-GRAVITY,  91, 1012, -4.5,    4,   4,  31))
assert(test_move_ball( 96, 992+16, -6, -4-GRAVITY,  91, 1003,   -3, -4.5,   3,  31))
assert(test_move_ball( 95, 992+16, -6, -4-GRAVITY,  89, 1004,   -6,   -4, nil, nil))
assert(test_move_ball( 64-16, 897,  4, -6-GRAVITY,  44,  891,   -3, -4.5,   3,  29))
assert(test_move_ball( 64-16, 896,  4, -6-GRAVITY,  53,  891,  4.5,   -3,   3,  28))
assert(test_move_ball( 64-16, 895,  4, -6-GRAVITY,  52,  889,    4,   -6, nil, nil))
assert(test_move_ball( 64-16, 959,  4,  6-GRAVITY,  44,  965,   -3,  4.5,   3,  30))
assert(test_move_ball( 64-16, 960,  4,  6-GRAVITY,  53,  965,  4.5,    3,   3,  31))
assert(test_move_ball( 64-16, 961,  4,  6-GRAVITY,  52,  967,    4,    6, nil, nil))
assert(test_move_ball(192+16, 897, -4, -6-GRAVITY, 212,  891,    3, -4.5,   6,  29))
assert(test_move_ball(192+16, 896, -4, -6-GRAVITY, 203,  891, -4.5,   -3,   6,  28))
assert(test_move_ball(192+16, 895, -4, -6-GRAVITY, 204,  889,   -4,   -6, nil, nil))
assert(test_move_ball(192+16, 959, -4,  6-GRAVITY, 212,  965,    3,  4.5,   6,  30))
assert(test_move_ball(192+16, 960, -4,  6-GRAVITY, 203,  965, -4.5,    3,   6,  31))
assert(test_move_ball(192+16, 961, -4,  6-GRAVITY, 204,  967,   -4,    6, nil, nil))

-- Miscellaneous tests.
assert(test_move_ball(171, 586, 9, 6,  172, 592, -6.75, -5.06, 7, 19))
assert(test_move_ball(88, 852, 6, 6.25,  85, 850, -5.25, -4.5, 3, 28))
assert(test_move_ball(104, 1009, 12, -10,  116, 1016.25, 9, 6.9, 4, 31))
assert(test_move_ball(160, 848, 6, 3.25,  165, 853, 3, 4.5, 6, 28))
assert(test_move_ball(173, 500.8, 10.3, -6.6,  168, 497, -7.73, 4.39, 7, 16))
assert(test_move_ball(107.6, 665.5, -12.6, -13.7,  105, 663, 9, 9, 3, 21))
assert(test_move_ball(9425.43, 5841.43, -14.2108, -14.1649, 9434.57, 5850.57, 9, 9, 294, 182))

-- Call move_ball with some parameters and verify that it doesn't trip over any
-- assertions.  Returns true when there was a hit.
--
-- For use with fuzz_test_move_ball and sweep_test_move_ball.
local function verify_move_ball(x, y, vx, vy)
	world.balls = {{x, y}}

	world.update_ball_position = function(index, x, y)
		world.balls[index][1] = x
		world.balls[index][2] = y
	end

	local rvx <const>, rvy <const>, hit_x <const>, hit_y <const> =
		move_ball(1, vx, vy)
	assert(rvx, string.format("move_ball(%g,%g,%g,%g): rvx", x, y, vx, vy))
	assert(rvy, string.format("move_ball(%g,%g,%g,%g): rvy", x, y, vx, vy))
	if hit_x then
		assert(hit_y, string.format("move_ball(%g,%g,%g,%g): hit_y", x, y, vx, vy))
	else
		assert(not hit_y, string.format("move_ball(%g,%g,%g,%g): not hit_y", x, y, vx, vy))
	end
	return hit_x
end

-- Try various random vectors to make sure that move_ball doesn't trip over
-- any assertions.
local function fuzz_test_move_ball(iterations)
	-- Offset from the "near" collision shapes to the "far" collision shapes.
	-- Set USE_FAR_SHAPES to false to test against the "near" shapes.
	--
	-- We have two copies of the same collision shapes for testing, the
	-- "near" ones are located at (32,448) and the "far" ones are located
	-- at (9376,5792).  In theory we should only need one copy since all
	-- movements happen within 3 tiles at most, and coordinates within the
	-- tiles should be the same after modulus.  In practice, we have ran
	-- into floating point precision issues multiple times with coordinate
	-- values that are larger than what's represented in the "near" shapes.
	--
	-- Since we have ran enough fuzz tests against the "near" shapes, the
	-- default below selects the "far" shapes.
	local USE_FAR_SHAPES <const> = true
	local OFFSET_X <const> = USE_FAR_SHAPES and 9376 -  32 or 0
	local OFFSET_Y <const> = USE_FAR_SHAPES and 5792 - 448 or 0

	-- Test parameters for move_ball.  We will choose a starting position that
	-- is at +/-8 from (x,y), and call move_ball with a random velocity biased
	-- toward (dx,dy).
	local MOVE_BALL_PARAMS <const> =
	{
		-- Square enclosure.
		{x =  88 + OFFSET_X, y =  504 + OFFSET_Y, dx = -5, dy = -5},
		{x = 168 + OFFSET_X, y =  504 + OFFSET_Y, dx =  5, dy = -5},
		{x =  88 + OFFSET_X, y =  584 + OFFSET_Y, dx = -5, dy =  5},
		{x = 168 + OFFSET_X, y =  584 + OFFSET_Y, dx =  5, dy =  5},
		-- Octagon enclosure.
		{x = 104 + OFFSET_X, y =  672 + OFFSET_Y, dx = -5, dy = -5},
		{x =  96 + OFFSET_X, y =  680 + OFFSET_Y, dx = -5, dy = -5},
		{x = 152 + OFFSET_X, y =  672 + OFFSET_Y, dx =  5, dy = -5},
		{x = 160 + OFFSET_X, y =  680 + OFFSET_Y, dx =  5, dy = -5},
		{x = 104 + OFFSET_X, y =  736 + OFFSET_Y, dx = -5, dy =  5},
		{x =  96 + OFFSET_X, y =  728 + OFFSET_Y, dx = -5, dy =  5},
		{x = 152 + OFFSET_X, y =  736 + OFFSET_Y, dx =  5, dy =  5},
		{x = 160 + OFFSET_X, y =  728 + OFFSET_Y, dx =  5, dy =  5},
		-- Outside octagon.
		{x =  96 + OFFSET_X, y =  840 + OFFSET_Y, dx = -1, dy =  5},
		{x =  40 + OFFSET_X, y =  896 + OFFSET_Y, dx =  5, dy = -1},
		{x = 160 + OFFSET_X, y =  840 + OFFSET_Y, dx =  1, dy =  5},
		{x = 216 + OFFSET_X, y =  896 + OFFSET_Y, dx = -5, dy = -1},
		{x =  96 + OFFSET_X, y = 1016 + OFFSET_Y, dx = -1, dy = -5},
		{x =  40 + OFFSET_X, y =  960 + OFFSET_Y, dx =  5, dy =  1},
		{x = 160 + OFFSET_X, y = 1016 + OFFSET_Y, dx =  1, dy = -5},
		{x = 216 + OFFSET_X, y =  960 + OFFSET_Y, dx = -5, dy =  1},
		-- Outside octagon bounding square corners.
		{x =  56 + OFFSET_X, y =  856 + OFFSET_Y, dx =  5, dy =  5},
		{x = 200 + OFFSET_X, y =  856 + OFFSET_Y, dx = -5, dy =  5},
		{x =  56 + OFFSET_X, y = 1000 + OFFSET_Y, dx =  5, dy = -5},
		{x = 200 + OFFSET_X, y = 1000 + OFFSET_Y, dx = -5, dy = -5},
	}

	world.balls = {{nil, nil}}

	-- Set update_ball_position to overwrite ball position, without recording
	-- history.  This function will be replaced later.
	world.update_ball_position = function(index, x, y)
		world.balls[index][1] = x
		world.balls[index][2] = y
	end

	local start <const> = playdate.getElapsedTime()
	local hits = 0
	for i = 1, iterations do
		local t <const> = MOVE_BALL_PARAMS[math.random(1, #MOVE_BALL_PARAMS)]
		local x <const> = random_float_range(t.x - 7, t.x + 7)
		local y <const> = random_float_range(t.y - 7, t.y + 7)
		local vx <const> = random_float_range(t.dx - 10, t.dx + 10)
		local vy <const> = random_float_range(t.dy - 10, t.dy + 10)
		if verify_move_ball(x, y, vx, vy) then
			hits += 1
		end
	end

	-- Output some timing information at the end, same as fuzz_test_move_point.
	--
	-- On my machine, I get anywhere between 0.005s to 0.011s per move
	-- depending on bounce rate for debug builds, and about 0.0002s per move
	-- for release builds (independent of bounce rate), so about the same order
	-- of magnitude in speedups as move_point for release builds, as expected.
	--
	-- The timing information also says each move_ball costs about 10x
	-- move_point calls, which sounds about right.
	local done <const> = playdate.getElapsedTime()
	if iterations > 0 then
		print(string.format("move_ball: %gs per move, bounce rate = %g", (done - start) / iterations, hits / iterations))
	end

	world.balls = {}
	return true
end

-- Only run the fuzz test inside the simulator, since it has enough speed
-- for that purpose.
assert(fuzz_test_move_ball(playdate.isSimulator and 500 or 0))

-- Test by doing a parameter sweep of some region.
local function sweep_test_move_ball(x, y, min_vx, max_vx, min_vy, max_vy, step)
	-- Only run this test on the simulator.
	if not playdate.isSimulator then
		return true
	end

	assert(min_vx and max_vx and min_vy and max_vy and step)
	assert(step > 0)
	assert(min_vx <= max_vx)
	assert(min_vy <= max_vy)
	local start <const> = playdate.getElapsedTime()
	local runs = 0
	local hits = 0
	for vx = min_vx, max_vx, step do
		for vy = min_vy, max_vy, step do
			runs += 1
			if verify_move_ball(x, y, vx, vy) then
				hits += 1
			end
		end
	end
	local done <const> = playdate.getElapsedTime()
	if runs > 0 then
		print(string.format("move_ball: %gs per move, bounce rate = %g", (done - start) / runs, hits / runs))
	end

	world.balls = {}
	return true
end
assert(sweep_test_move_ball(176, 848, -10, 0, 0, 10, 1))

-- Given a history of move movements, check if we are in an infinite bounce
-- loop.  Returns true if a loop has been detected, which is a signal to
-- world.throw_ball() to break out of the ball movement loop.
--
-- These can happen if the ball is at just the right height, with gravity
-- pushing down on it to replenish the lost velocity.  These happen despite
-- all the heuristics around MAX_GRAVITY_REDUCTION_ITERATIONS.  One such loop
-- has this series of Y values:
--
--   y=1327.42, vy=2.57143 -> bounce
--   y=1326.01, vy=-1.17857
--   y=1324.83, vy=-0.428571
--   y=1324.4,  vy=0.321429
--   y=1324.72, vy=1.07143
--   y=1325.79, vy=1.82143
--   y=1327.62, vy=2.57143 -> bounce
--   y=1325.81, vy=-1.17857
--   y=1324.63, vy=-0.428572
--   y=1324.21, vy=0.321428
--   y=1324.53, vy=1.07143
--   y=1325.6,  vy=1.82143
--   y=1327.42, vy=2.57143 -> bounce
--
-- Note that the X values are always roughly constant in these infinite
-- bounces, because there is nothing to add to the horizontal velocity
-- except on a sloped surface.
--
-- We will detect infinite bounces by three means: checking for deviance
-- around mean position, direct check for loop around some point, and basic
-- time bound.
local function stop_infinite_bounce(ball_index, move_frame_count, vx, vy)
	-- Keep track of the lowest position for which the ball is oscillating
	-- around.  If we do detect a loop, we will use this position to drop the
	-- ball to the floor.
	local index = world.ball_history_index
	local lowest_point_x = world.ball_position_history[index][1]
	local lowest_point_y = world.ball_position_history[index][2]

	-- Iterate through history and find the average position, and also the
	-- lowest point.
	local mean_x = lowest_point_x
	local mean_y = lowest_point_y
	for i = 1, BALL_HISTORY_MASK do
		index += 1
		local p <const> = world.ball_position_history[index & BALL_HISTORY_MASK]
		mean_x += p[1]
		mean_y += p[2]
		if lowest_point_y < p[2] then
			lowest_point_x = p[1]
			lowest_point_y = p[2]
		end
	end
	mean_x /= (BALL_HISTORY_MASK + 1)
	mean_y /= (BALL_HISTORY_MASK + 1)

	-- Add up all deltas from mean position, and also count the number of
	-- times the lowest point was visited.
	--
	-- Comparison with the lowest point is done with reduced precision by
	-- multiplying by 10 and truncating away the decimal parts (i.e. be accurate
	-- within 0.1 pixel).  10 appears to be a good multiplier.  We also tried
	-- higher values such as 16, and in those cases the lowest_point_visits
	-- detector tend to not converge as fast as the delta sum threshold
	-- detector, causing players to wait one extra cycle (~2 seconds) for the
	-- ball to stop bouncing.
	local delta_x = 0
	local delta_y = 0
	local lowest_point_visits = 0
	local scaled_lowest_x <const> = floor(lowest_point_x * 10)
	local scaled_lowest_y <const> = floor(lowest_point_y * 10)
	for i = 0, BALL_HISTORY_MASK do
		local p <const> = world.ball_position_history[i]
		delta_x += abs(p[1] - mean_x)
		delta_y += abs(p[2] - mean_y)

		if floor(p[1] * 10) == scaled_lowest_x and floor(p[2] * 10) == scaled_lowest_y then
			lowest_point_visits += 1
		end
	end

	if move_frame_count > MAX_BALL_MOVE_FRAME_COUNT or
		lowest_point_visits > 3 or
		(delta_x < BALL_HISTORY_MASK * 0.5 and
		 delta_y < BALL_HISTORY_MASK * 0.5) then
		assert(debug_log(string.format("force stopped ball %d after %d frames, velocity=(%g,%g), mean position=(%g,%g), average delta=(%g,%g), lowest position=(%g, %g) * %d", ball_index, move_frame_count, vx, vy, mean_x, mean_y, delta_x / BALL_HISTORY_MASK, delta_y / BALL_HISTORY_MASK, lowest_point_x, lowest_point_y, lowest_point_visits)))

		-- Update ball position to the lowest point.  This is so that if the
		-- ball was oscillating above the floor slightly, we will drop it to
		-- the floor.
		world.update_ball_position(ball_index, lowest_point_x, lowest_point_y)
		return true
	end
	return false
end

--}}}

----------------------------------------------------------------------
--{{{ Global functions.

-- Do partial initialization of world layers.
--
-- Call this function with step values 0..14 to get all initialization done.
function world.init(step)
	assert(debug_log(string.format("world.init(%d)", step)))

	-- Step 13 populates the star patch and UFO above the world.
	-- This needs to happen after all the background tiles are loaded.
	if step == 13 then
		-- Star patch.
		top_of_world_grid = gfx.tilemap.new()
		top_of_world_grid:setImageTable(world_tiles)
		top_of_world_grid:setSize(GRID_W, TOP_OF_WORLD_HEIGHT)
		local t = {}
		for i = 1, 5 do
			-- Get indices of the non-flickering star tiles.  We want the
			-- non-flickering ones because there is only one set of non-animating
			-- tiles for the top of the world.
			t[i] = world_grid_ibg[0]:getTileAtPosition(
				STAR_PALETTE_TILE_X + (i - 1) * 2, STAR_PALETTE_TILE_Y)
			assert(t[i] and t[i] >= 1 and t[i] <= world.UNIQUE_TILE_COUNT)
		end
		for y = 1, TOP_OF_WORLD_HEIGHT do
			for x = 1, GRID_W do
				if math.random(8) == 1 then
					top_of_world_grid:setTileAtPosition(x, y, t[math.random(4)])
				else
					top_of_world_grid:setTileAtPosition(x, y, t[5])
				end
			end
		end

		top_of_world_sprite = gfx.sprite.new()
		top_of_world_sprite:setTilemap(top_of_world_grid)
		top_of_world_sprite:setZIndex(Z_GRID_STARS)
		top_of_world_sprite:add()
		top_of_world_sprite:setCenter(0, 0)
		top_of_world_sprite:setVisible(true)
		top_of_world_sprite:moveTo(0, -TOP_OF_WORLD_HEIGHT * TILE_SIZE)

		-- UFO.
		ufo_images = gfx.imagetable.new("images/ufo")
		assert(ufo_images:getLength() == UFO_FRAMES)
		assert(({ufo_images:getImage(1):getSize()})[1] == UFO_WIDTH)
		assert(({ufo_images:getImage(1):getSize()})[2] == UFO_HEIGHT)

		ufo_sprite = gfx.sprite.new()
		ufo_sprite:setZIndex(Z_UFO)
		ufo_sprite:setCenter(0, 0)
		ufo_sprite:add()
		ufo_sprite:setVisible(false)
		return
	end

	-- Last step of the initialization process is to initialize balls.
	-- This needs to happen after all the background tiles are loaded.
	if step == 14 then
		world.balls = {}
		ball_sprite = {}
		for i = 1, #world.INIT_BALLS do
			-- Initialize logical state of each ball.
			local x <const> = world.INIT_BALLS[i][1]
			local y <const> = world.INIT_BALLS[i][2]
			world.balls[i] = {x, y}

			-- Initialize ball sprite.
			ball_sprite[i] = gfx.sprite.new()
			ball_sprite[i]:add()
			ball_sprite[i]:setCenter(0.5, 0.5)
			ball_sprite[i]:moveTo(x, y)
			ball_sprite[i]:setVisible(true)
			ball_sprite[i]:setZIndex(Z_BALL)
			local tile_index <const> = get_bg_tile_image_index(x, y)
			ball_sprite_tile_index[i] = tile_index
			ball_sprite[i]:setImage(world_tiles:getImage(tile_index))

			-- Remove ball tiles from background image.
			local tile_x <const>, tile_y <const> = get_tile_position(x, y)
			assert(tile_x >= 1)
			assert(tile_y >= 1)
			for j = 0, 3 do
				assert(tile_x <= ({world_grid_bg[j]:getSize()})[1])
				assert(tile_y <= ({world_grid_bg[j]:getSize()})[2])
				world_grid_bg[j]:setTileAtPosition(tile_x, tile_y, EMPTY_TILE)
			end
		end
		return
	end

	-- Step 0 loads the bitmaps.
	if step == 0 then
		world_tiles = gfx.imagetable.new("images/world")
		assert(world_tiles)
		assert(world_tiles:getLength() >= world.UNIQUE_TILE_COUNT)
		debris_images = gfx.imagetable.new("images/debris")
		assert(debris_images)
		return
	end

	-- Steps 1..12 populates the tile maps.
	step -= 1
	local index <const> = step // 3
	if step % 3 == 0 then
		-- Immutable background tiles.
		world_grid_ibg[index] = gfx.tilemap.new()
		world_grid_ibg_sprite[index] = gfx.sprite.new()
		init_world_tilemap(world_grid_ibg[index], world_grid_ibg_sprite[index], Z_GRID_IBG)
	elseif step % 3 == 1 then
		-- Mutable background tiles.
		world_grid_bg[index] = gfx.tilemap.new()
		world_grid_bg_sprite[index] = gfx.sprite.new()
		init_world_tilemap(world_grid_bg[index], world_grid_bg_sprite[index], Z_GRID_BG)
	else
		-- Foreground tiles.
		world_grid_fg[index] = gfx.tilemap.new()
		world_grid_fg_sprite[index] = gfx.sprite.new()
		init_world_tilemap(world_grid_fg[index], world_grid_fg_sprite[index], Z_GRID_FG)
	end

	if step % 3 == 0 then
		world_grid_ibg[index]:setTiles(unpack_tiles(world["ibg" .. index]), GRID_W)
		-- Don't need the immutable tiles after initialization is done.
		world["ibg" .. index] = nil
	elseif step % 3 == 1 then
		world_grid_bg[index]:setTiles(unpack_tiles(world["bg" .. index]), GRID_W)
	else
		world_grid_fg[index]:setTiles(unpack_tiles(world["fg" .. index]), GRID_W)
	end
end

-- Draw loading progress.
function world.show_loading_progress(progress, denominator)
	-- Show loading screens.
	local frame <const> = progress % 4
	if not loading_images[frame] then
		loading_images[frame] = gfx.image.new("images/loading" .. frame)
		assert(loading_images[frame])
	end
	loading_images[frame]:drawIgnoringOffset(0, 0)

	-- Draw progress bar.
	gfx.setColor(gfx.kColorBlack)
	gfx.fillRect(63, 158, progress * 274 / denominator, 2)

	-- Unload loading screens if we are almost done.
	if progress + 4 > denominator then
		loading_images[frame] = nil
	end
end

-- Reset world tiles.
function world.reset()
	-- Load background and foreground tiles.
	for i = 0, 3 do
		world_grid_bg[i]:setTiles(unpack_tiles(world["bg" .. i]), GRID_W)
		world.show_loading_progress(i, 8)
		coroutine.yield()
	end
	for i = 0, 3 do
		world_grid_fg[i]:setTiles(unpack_tiles(world["fg" .. i]), GRID_W)
		world.show_loading_progress(i + 4, 8)
		coroutine.yield()
	end

	-- Restore metadata tiles that were removed by undoing all of removed_tiles.
	assert(#world.removed_tiles % 2 == 0)
	for i = #world.removed_tiles - 1, 1, -2 do
		local packed_xy <const> = abs(world.removed_tiles[i])
		local tile_x <const> = packed_xy >> 9
		local tile_y <const> = packed_xy & 0x1ff
		assert(tile_x >= 1)
		assert(tile_x <= GRID_W)
		assert(tile_y >= 1)
		assert(tile_y <= GRID_H)
		world.metadata[tile_y][tile_x] = world.removed_tiles[i + 1]
	end

	-- Initialize world states.
	world.collected_tiles = {}
	world.removed_tiles = table.create(world.REMOVABLE_TILE_COUNT * 2, 0)
	world.teleport_stations = {}
	world.broken_tiles = 0
	world.vanquished_tiles = 0
	world.frame_count = 0
	world.debug_frame_count = 0
	world.completed_frame_count = 0
	world.throw_count = 0
	world.drop_count = 0
	world.ufo_count = 0
	world.last_item_tile_x = nil
	world.last_item_tile_y = nil
	world.paint_count = 0

	world.serialized_balls_dirty = true
	world.serialized_removed_tiles = table.create(world.REMOVABLE_TILE_COUNT * 2, 0)
	world.serialized_teleport_stations = {}

	world.balls = {}
	for i = 1, #world.INIT_BALLS do
		local entry <const> = world.INIT_BALLS[i]
		local x <const> = entry[1]
		local y <const> = entry[2]
		world.balls[i] = {x, y}

		local tile_x <const>, tile_y <const> = get_tile_position(x, y)
		assert(tile_x >= 1)
		assert(tile_y >= 1)
		for j = 0, 3 do
			assert(tile_x <= ({world_grid_bg[j]:getSize()})[1])
			assert(tile_y <= ({world_grid_bg[j]:getSize()})[2])
			world_grid_bg[j]:setTileAtPosition(tile_x, tile_y, EMPTY_TILE)
		end
	end
	world.serialized_balls_dirty = true

	-- Reset cached item locations.
	item_locations = nil

	-- Delete any in-progress animation sprites.
	for i = 1, #debris_sprites do
		if debris_sprites[i][2] then
			debris_sprites[i][2]:remove()
		end
	end
	debris_sprites = {}

	if completion_marker_sprite then
		completion_marker_sprite:remove()
		completion_marker_sprite = nil
	end
	completion_timer = nil

	for i = 1, #paint_timer do
		paint_timer[i][5]:remove()
	end
	paint_timer = {}
end

-- Update sprites.
function world.update()
	-- Cycle through foreground and background tiles.
	--
	-- A complete cycle is 60 frames or 2 seconds.  If we had gone with a
	-- 64 frame cycle, we would be able to use just bit masks and shifts
	-- instead of divides, but a 2-second cycle felt more pleasant, especially
	-- since our cursor blinks at 1-second intervals.
	--
	-- 2 seconds is also roughly the time it takes to play one measure of
	-- "The Mysterious Barricades" here: https://youtu.be/xp6J6MKkMYk
	world.frame_count += 1
	local selected_layer <const> = ((world.frame_count) % 60) // 15
	for i = 0, 3 do
		if i == selected_layer then
			world_grid_ibg_sprite[i]:setVisible(true)
			world_grid_bg_sprite[i]:setVisible(true)
			world_grid_fg_sprite[i]:setVisible(true)
		else
			world_grid_ibg_sprite[i]:setVisible(false)
			world_grid_bg_sprite[i]:setVisible(false)
			world_grid_fg_sprite[i]:setVisible(false)
		end
	end

	-- Update ball sprite positions.
	assert(#world.balls == #world.INIT_BALLS)
	assert(#ball_sprite == #world.INIT_BALLS)
	for i = 1, #world.INIT_BALLS do
		assert(ball_sprite[i])
		ball_sprite[i]:moveTo(world.balls[i][1], world.balls[i][2])
	end

	-- Animate debris, and also check if any debris are still visible.
	if #debris_sprites > 0 then
		local all_debris_expired = true
		local debris_frame_count <const> = debris_images:getLength()
		for i = 1, #debris_sprites do
			local entry <const> = debris_sprites[i]
			entry[1] += 1
			if debris_sprites[i][1] < debris_frame_count then
				entry[2]:setImage(debris_images:getImage(entry[1]))
				all_debris_expired = false
			elseif debris_sprites[i][1] == debris_frame_count then
				entry[2]:remove()
				entry[2] = nil
			end
		end
		if all_debris_expired then
			debris_sprites = {}
		end
	end

	-- Update UFO image.
	if ufo_frame_delta ~= 0 then
		-- Update UFO image frame with setImage.
		--
		-- Previously we would do this by defining ufo_sprite as a tilemap with
		-- a single cell, the theory being that we only need to set a single
		-- tile index, and we know it won't incur any extra copies.  That did
		-- not work out because Playdate's runtime seemed unpredictable in
		-- deciding when the tilemap is considered dirty, and we would often
		-- see no updates despite calls to setTileAtPosition.  setImage() appears
		-- to be more consistent, so that's what we are using here.
		if ufo_frame <= UFO_FRAMES then
			ufo_sprite:setVisible(true)
			ufo_sprite:setImage(ufo_images:getImage(ufo_frame))
		end

		ufo_frame += ufo_frame_delta
		if ufo_frame <= 0 then
			ufo_frame = 1
			ufo_frame_delta = 0
		elseif ufo_frame > UFO_FRAMES then
			ufo_frame = UFO_FRAMES + 1
			ufo_frame_delta = 0
			ufo_sprite:setVisible(false)
		end
	end

	-- Animate completion marker flag.
	animate_completion_marker()

	-- Bake the painted completion markers into background layers once their
	-- timers have expired.
	while #paint_timer > 0 and paint_timer[1][1] <= 0 do
		local entry <const> = paint_timer[1]
		local o <const> = math.random(0, 3)
		for i = 0, 3 do
			local tile <const> = world_grid_ibg[(i + o) % 4]:getTileAtPosition(
				1, GRID_H - 4 + entry[2])
			world_grid_bg[i]:setTileAtPosition(entry[3], entry[4], tile)
		end
		entry[5]:remove()
		table.remove(paint_timer, 1)
	end

	-- Animate painted completion markers.
	for i = 1, #paint_timer do
		local entry = paint_timer[i]
		entry[1] -= 1

		-- Fetch tile from immutable background layer at (0,6240)..(512,6400).
		local frame <const> = entry[1] // 2
		assert(frame >= 0)
		assert(frame <= 15)
		local tile <const> = world_grid_ibg[0]:getTileAtPosition(
			1 + frame, GRID_H - 4 + entry[2])
		entry[5]:setImage(world_tiles:getImage(tile))
	end
end

-- Set drawing offset in response to viewport updates.
function world.set_draw_offset()
	-- Round to the nearest even pixel.
	-- https://help.play.date/developer/designing-for-playdate/#dither-flashing
	gfx.setDrawOffset(floor(world.sprite_offset_x + 1) & ~1,
	                  floor(world.sprite_offset_y + 1) & ~1)
end

-- Try to expand focus area to bring collectible item into view.
function world.expand_focus()
	-- Compute window of what would be visible on screen if viewport were
	-- centered.
	--
	-- Note that we constrain the window to be within world coordinate bounds.
	-- This is needed to accommodate debug mode movements, where player may
	-- intentionally place the arm near the edge of the map.  There is no good
	-- reason to do that because there is nothing out there, but we want the
	-- game to not crash if that's what the player really wanted to do.
	local cx <const> = floor((world.focus_min_x + world.focus_max_x) / 2)
	local cy <const> = floor((world.focus_min_y + world.focus_max_y) / 2)
	local s0x <const> = max(cx - SCREEN_WIDTH // 2, 0)
	local s1x <const> = min(cx + SCREEN_WIDTH // 2, world.WIDTH - 1)
	local s0y <const> = max(cy - SCREEN_HEIGHT // 2, 0)
	local s1y <const> = min(cy + SCREEN_HEIGHT // 2, world.HEIGHT - 1)

	-- Convert to tile coordinates.
	local t0x <const>, t0y <const> = get_tile_position(s0x, s0y)
	local t1x <const>, t1y <const> = get_tile_position(s1x, s1y)
	assert(t0x >= 1)
	assert(t1x <= GRID_W)
	assert(t0y >= 1)
	assert(t1y <= GRID_H)

	-- No need to adjust focus if current area already contains a collectible.
	for y = t0y, t1y do
		for x = t0x, t1x do
			assert(world.metadata[y][x])
			if (world.metadata[y][x] & COLLECTIBLE_MASK) ~= 0 then
				return
			end
		end
	end

	-- Try expanding right or left.
	local start_x <const> = {t1x + 1, t0x - 1}
	local end_x <const> = {t1x + 4, t0x - 4}
	local dx <const> = {1, -1}
	for i = 1, 2 do
		for x = start_x[i], end_x[i], dx[i] do
			if x > GRID_W or x <= 0 then break end
			for y = t0y, t1y do
				assert(y >= 1)
				assert(y <= GRID_H)
				-- Check for collectible tile within the expanded column, then
				-- check that the tile is not hidden behind a foreground tile.
				if (world.metadata[y][x] & COLLECTIBLE_MASK) ~= 0 and
				   (world.metadata[y][x] & REACTION_TILE) == 0 then
					-- Update horizontal focus area.
					if x > t1x then
						local delta_x <const> = (x - t1x) * TILE_SIZE
						assert(delta_x >= TILE_SIZE)
						world.focus_max_x = s1x + delta_x
					else
						local delta_x <const> = (x - t0x) * TILE_SIZE
						assert(delta_x <= -TILE_SIZE)
						world.focus_min_x = s0x + delta_x
					end

					-- world.update_viewport will make use of the new focus area.
					return
				end
			end
		end
	end
end

-- Update all sprite offsets according to world.focus_{min,max}_{x,y}.
function world.update_viewport()
	local min_x <const> = world.focus_min_x + world.sprite_offset_x
	local min_y <const> = world.focus_min_y + world.sprite_offset_y
	local max_x <const> = world.focus_max_x + world.sprite_offset_x
	local max_y <const> = world.focus_max_y + world.sprite_offset_y

	-- Compute amount of displacement needed to move the current viewport
	-- such that the entire focus area is visible.  No update is needed
	-- if the displacement vector is zero.
	--
	-- A simpler computation would be to compare the center of the focus
	-- area with the center of the screen and try to keep the two points
	-- aligned, but that would result in more scrolling than needed.
	local dx <const> = max(SCREEN_MIN_X - min_x, 0) + min(SCREEN_MAX_X - max_x, 0)
	local dy <const> = max(SCREEN_MIN_Y - min_y, 0) + min(SCREEN_MAX_Y - max_y, 0)
	if dx == 0 and dy == 0 then
		return
	end

	-- Apply the displacement vector to sprite offsets, with some scaling
	-- factor.  A scaling factor of 1 would result in instantaneous scrolling,
	-- some value between 0.3 and 1 would result in fast and unpleasant jerky
	-- motion.  Current settings seem to produce the most pleasant result.
	--
	-- Note that we have a slightly higher multiplier for vertical movement.
	-- This is because we have less room on the screen vertically, so we would
	-- like the vertical movements to catch up faster.
	world.sprite_offset_x += dx * 0.14
	world.sprite_offset_y += dy * 0.15
	world.set_draw_offset()
end

-- Test collision for a coordinate against a single tile, returns true if
-- point collides with tile.
--
-- Note that this function takes just a single coordinate, as opposed to
-- something that specifies a line segment.  Collision test is basically
-- checking whether a point falls inside a tile, plus a bit of code to
-- account for various tile shapes.  This is cheaper than doing line
-- intersections, and it works because the walls are reasonably thick
-- relative to the things that collide with it.
function world.collide(x, y)
	if x < 0 or x >= GRID_W * TILE_SIZE or y < 0 or y >= GRID_H * TILE_SIZE then
		return true
	end

	local grid_x <const>, grid_y <const> = get_tile_position(x, y)
	assert(world.metadata[grid_y])
	assert(world.metadata[grid_y][grid_x])
	local collision_bits <const> = world.metadata[grid_y][grid_x] & COLLISION_MASK
	return collision_bits == COLLISION_SQUARE or
	       inside_triangular_region(collision_bits, x & 31, y & 31)
end

-- Test world.collide against the invisible collision cells at upper
-- left corner of the map.

-- COLLISION_UP_LEFT
assert(not world.collide(32, 32))
assert(not world.collide(37, 37))
assert(not world.collide(61, 32))
assert(not world.collide(32, 61))
assert(world.collide(63, 63))
assert(world.collide(58, 58))
assert(world.collide(61, 63))
assert(world.collide(63, 61))

-- COLLISION_UP_RIGHT
assert(not world.collide(95, 32))
assert(not world.collide(90, 37))
assert(not world.collide(66, 32))
assert(not world.collide(95, 61))
assert(world.collide(64, 63))
assert(world.collide(69, 58))
assert(world.collide(66, 63))
assert(world.collide(64, 61))

-- COLLISION_DOWN_LEFT
assert(not world.collide(32, 95))
assert(not world.collide(37, 90))
assert(not world.collide(61, 95))
assert(not world.collide(32, 66))
assert(world.collide(63, 64))
assert(world.collide(58, 69))
assert(world.collide(61, 64))
assert(world.collide(63, 66))

-- COLLISION_DOWN_RIGHT
assert(not world.collide(95, 95))
assert(not world.collide(90, 90))
assert(not world.collide(66, 95))
assert(not world.collide(95, 66))
assert(world.collide(64, 64))
assert(world.collide(69, 69))
assert(world.collide(66, 64))
assert(world.collide(64, 66))

-- COLLISION_SQUARE
assert(world.collide(128, 32))
assert(world.collide(128, 63))
assert(world.collide(159, 32))
assert(world.collide(159, 63))
assert(world.collide(144, 48))

-- COLLISION_NONE
assert(not world.collide(128, 64))
assert(not world.collide(128, 95))
assert(not world.collide(159, 64))
assert(not world.collide(159, 95))
assert(not world.collide(144, 80))

-- Out of bounds.
assert(world.collide(-1, -1))
assert(world.collide(-1, 0))
assert(world.collide(0, -1))
assert(world.collide(GRID_W * TILE_SIZE, GRID_H * TILE_SIZE))
assert(world.collide(GRID_W * TILE_SIZE, 0))
assert(world.collide(0, GRID_H * TILE_SIZE))

-- Test for a point passing through a non-colliding CHAIN_REACTION tile,
-- and trigger chain reaction accordingly.
--
-- This is separate from world.collide in that these tiles do not contribute
-- to collision (because they have no collision bits), but we still want the
-- chain reaction to trigger if the arm passed through them.
function world.area_trigger(x, y, update_sprites)
	local tile_x <const>, tile_y <const> = get_tile_position(x, y)
	if world.metadata[tile_y][tile_x] == CHAIN_REACTION then
		-- Update sprites before applying chain reaction, so that player can
		-- see the arm pose that triggered the chain reaction.
		update_sprites()
		update_chain_reaction(tile_x, tile_y)
	end

	-- If we are in endgame mode and the completion flag has stopped animating,
	-- we will paint all unpainted background tiles here.
	if (not completion_timer) and
	   #world.collected_tiles == world.ITEM_COUNT and
	   is_empty_background_tile(tile_x, tile_y) then
		-- Avoid painting over an in-progress end marker.
		--
		-- This might seem like a very inefficient thing to do, why not just
		-- mark the background layer with some nonempty tile so that
		-- is_empty_background_tile will return false?  Turns out, when we
		-- update the tilemap like that, it messes up playdate's sense of
		-- which areas are dirty, and as a result we will see some frames
		-- get skipped.  This is the same reason why we are creating sprites
		-- a few lines below as opposed to just baking the in-progress frames
		-- into the tilemap.
		for i = 1, #paint_timer do
			if paint_timer[i][3] == tile_x and paint_timer[i][4] == tile_y then
				return
			end
		end

		-- Initialize timer and select from one of 5 marker variations.
		-- See world.update() for how the tiles are selected.
		--
		-- Each marker has 16 progressive image, and each image appears for
		-- 2 frames before being replaced by the next image, so the timer here
		-- is set to 16*2.
		local s = gfx.sprite.new()
		local entry <const> = {32, math.random(0, 4), tile_x, tile_y, s}
		table.insert(paint_timer, entry)

		-- Create sprite to display the progressive images.
		--
		-- You would think that we can just modify the underlying tilemap
		-- for each frame, but the redraw checks for that turns out to be
		-- very unreliable, and has a tendency to skip frames.  It's much
		-- more reliable to do this kind of animation with sprites.
		local tile <const> = world_grid_ibg[0]:getTileAtPosition(
			1, GRID_H - 4 + entry[2])
		s:setImage(world_tiles:getImage(tile))
		s:add()
		s:setCenter(0, 0)
		s:moveTo((tile_x - 1) << 5, (tile_y - 1) << 5)
		s:setVisible(true)
		s:setZIndex(Z_PAINT_BG)

		world.paint_count += 1
	end
end

-- Given world coordinate for tip of hand, return a sorted list of tuples
-- containing points of interest.
--
-- Returned tuple type:
--   kind = kind of interaction possible at this location.
--   x, y = world coordinates.
--   a = hand angle needed to interact with item (degrees).
--       For mount points, this is 180 degrees from the normal angle.
--   ball = if kind is PICK_UP, this is the index of the ball being picked up.
--   next_x, next_y = if kind is TELEPORT, these are the coordinates of the
--                    mount point for the destination station.
--
-- This returned list is meant to be where action happens when player presses
-- down on D-pad.  There should be at most one item returned, but this
-- function returns a list so that parent function can select which item
-- to use based on whether there exists arm poses that can reach the
-- location of interest.
--
-- Input is tip of the hand, as opposed to something more complex such as
-- center of hand plus hand angle.  Turns out, sorting by distance to tip
-- of the hand would also cause tiles that are just in front of the hand
-- to be preferred, and we don't need more complex heuristics to select
-- tiles that best fits current hand's orientation.
function world.find_points_of_interest(hand_x, hand_y)
	assert(hand_x >= 0)
	assert(hand_y >= 0)
	local grid_center_x <const>, grid_center_y <const> =
		get_tile_position(hand_x, hand_y)

	-- Search area is a 5x5 square (+/-2) surrounding the hand position.
	-- This is as about generous as we can make it -- given that the screen
	-- height is just over 7 tiles tall, scanning at +/-3 would cause many
	-- points of interest that are outside of the visible area to be matched.
	--
	-- Also, we will lose a bit of frame rate if we go above 5x5.
	local poi_list = {}
	local poi_count = 0
	for dy = -2, 2 do
		local grid_y <const> = grid_center_y + dy
		if grid_y < 1 or grid_y > GRID_H then goto next_y end

		for dx = -2, 2 do
			local grid_x <const> = grid_center_x + dx
			if grid_x < 1 or grid_x > GRID_W then goto next_x end
			assert(world.metadata[grid_y])
			assert(world.metadata[grid_y][grid_x])

			-- Compute upper left corner and center of grid cell in world
			-- coordinates.  These will be used to compute point-of-interest
			-- locations in the returned value.
			local px <const> = (grid_x - 1) * TILE_SIZE
			local py <const> = (grid_y - 1) * TILE_SIZE
			local cx <const> = px + HALF_TILE_SIZE
			local cy <const> = py + HALF_TILE_SIZE

			-- Check collectible tiles.
			--
			-- Each of these come with two checks:
			-- 1. Check that the surface that the collectible is resting on is
			--    facing the hand, to avoid grabbing items on the other side of
			--    a double-sided wall.
			-- 2. Check that there is enough clearance around the item to grab it.
			--    So if an item is surrounded by obstacles, those obstacles need
			--    to be removed first.
			local tile <const> = world.metadata[grid_y][grid_x]
			local collectible_tile <const> = tile & COLLECTIBLE_MASK
			if collectible_tile ~= 0 then
				if collectible_tile == COLLECTIBLE_UP and
				   py + TILE_SIZE >= hand_y and
				   is_reachable_from_above(grid_x, grid_y) then
					poi_count += 1
					poi_list[poi_count] =
					{
						kind = world.COLLECT,
						x = cx,
						y = cy,
						a = 90
					}
					assert(debug_trace_poi(poi_list, poi_count, "find_points_of_interest (COLLECTIBLE_UP)"))
				elseif collectible_tile == COLLECTIBLE_DOWN and
				       py <= hand_y and
				       is_reachable_from_below(grid_x, grid_y) then
					poi_count += 1
					poi_list[poi_count] =
					{
						kind = world.COLLECT,
						x = cx,
						y = cy,
						a = 270
					}
					assert(debug_trace_poi(poi_list, poi_count, "find_points_of_interest (COLLECTIBLE_DOWN)"))
				elseif collectible_tile == COLLECTIBLE_LEFT and
				       px + TILE_SIZE >= hand_x and
				       is_reachable_from_left(grid_x, grid_y) then
					poi_count += 1
					poi_list[poi_count] =
					{
						kind = world.COLLECT,
						x = cx,
						y = cy,
						a = 0
					}
					assert(debug_trace_poi(poi_list, poi_count, "find_points_of_interest (COLLECTIBLE_LEFT)"))
				elseif collectible_tile == COLLECTIBLE_RIGHT and
				       px <= hand_x and
				       is_reachable_from_right(grid_x, grid_y) then
					poi_count += 1
					poi_list[poi_count] =
					{
						kind = world.COLLECT,
						x = cx,
						y = cy,
						a = 180
					}
					assert(debug_trace_poi(poi_list, poi_count, "find_points_of_interest (COLLECTIBLE_RIGHT)"))
				end
			end

			-- Check mount point.
			--
			-- Similar to collectible items, each of these come with an extra
			-- check to verify that the mount surface is facing the hand, to
			-- avoid mounting on surfaces that are on the other side of a
			-- double sided wall.
			local mount_mask = tile & MOUNT_MASK
			if mount_mask ~= 0 then
				-- Add mount point to list.  First check the diagonals,
				-- since these are always exact matches that don't need
				-- extra masking to check for double-sided walls.
				--
				-- Note the structure of these diagonal tests:
				--   if mount_mask == bits then
				--      if hand direction is correct then
				--         ...
				--      end
				--   elseif ...
				--
				-- The intent is that if mount_mask matches a diagonal surface,
				-- we don't want the test to fall through to match the horizontal
				-- and vertical surface bits.
				if mount_mask == MOUNT_UP_LEFT then
					if is_up_left_facing_hand(cx, cy, hand_x, hand_y) then
						poi_count += 1
						poi_list[poi_count] =
						{
							kind = world.MOUNT,
							x = cx,
							y = cy,
							a = 45
						}
						assert(debug_trace_poi(poi_list, poi_count, "find_points_of_interest (MOUNT_UP_LEFT)"))
					end
				elseif mount_mask == MOUNT_UP_RIGHT then
					if is_up_right_facing_hand(cx, cy, hand_x, hand_y) then
						poi_count += 1
						poi_list[poi_count] =
						{
							kind = world.MOUNT,
							x = cx,
							y = cy,
							a = 135
						}
						assert(debug_trace_poi(poi_list, poi_count, "find_points_of_interest (MOUNT_UP_RIGHT)"))
					end
				elseif mount_mask == MOUNT_DOWN_LEFT then
					if is_down_left_facing_hand(cx, cy, hand_x, hand_y) then
						poi_count += 1
						poi_list[poi_count] =
						{
							kind = world.MOUNT,
							x = cx,
							y = cy,
							a = 315
						}
						assert(debug_trace_poi(poi_list, poi_count, "find_points_of_interest (MOUNT_DOWN_LEFT)"))
					end
				elseif mount_mask == MOUNT_DOWN_RIGHT then
					if is_down_right_facing_hand(cx, cy, hand_x, hand_y) then
						poi_count += 1
						poi_list[poi_count] =
						{
							kind = world.MOUNT,
							x = cx,
							y = cy,
							a = 225
						}
						assert(debug_trace_poi(poi_list, poi_count, "find_points_of_interest (MOUNT_DOWN_RIGHT)"))
					end
				else
					-- Check horizontal and vertical mounts.
					--
					-- These come with extra clearance checks to confirm that any
					-- mutable obstacles blocking the tiles have been removed before
					-- allowing the mount to be accepted.
					--
					-- We don't do this for diagonal tiles because by convention,
					-- we don't put obstacles near diagonal tiles.  Also,
					-- generate_world_tiles.cc will flag some of those if we try.
					if (mount_mask & MOUNT_UP) ~= 0 and
					   py >= hand_y and
					   has_3x2_clearance(grid_x - 1, grid_y - 2) then
						poi_count += 1
						poi_list[poi_count] =
						{
							kind = world.MOUNT,
							x = px + HALF_TILE_SIZE,
							y = py,
							a = 90
						}
						assert(debug_trace_poi(poi_list, poi_count, "find_points_of_interest (MOUNT_UP)"))
					elseif (mount_mask & MOUNT_DOWN) ~= 0 and
					       py + TILE_SIZE - 1 <= hand_y and
					       has_3x2_clearance(grid_x - 1, grid_y + 1) then
						poi_count += 1
						poi_list[poi_count] =
						{
							kind = world.MOUNT,
							x = px + HALF_TILE_SIZE,
							y = py + TILE_SIZE - 1,
							a = 270
						}
						assert(debug_trace_poi(poi_list, poi_count, "find_points_of_interest (MOUNT_DOWN)"))
					elseif (mount_mask & MOUNT_LEFT) ~= 0 and
					       px >= hand_x and
					       has_2x3_clearance(grid_x - 2, grid_y - 1) then
						poi_count += 1
						poi_list[poi_count] =
						{
							kind = world.MOUNT,
							x = px,
							y = py + HALF_TILE_SIZE,
							a = 0
						}
						assert(debug_trace_poi(poi_list, poi_count, "find_points_of_interest (MOUNT_LEFT)"))
					elseif (mount_mask & MOUNT_RIGHT) ~= 0 and
					       px + TILE_SIZE - 1 <= hand_x and
					       has_2x3_clearance(grid_x + 1, grid_y - 1) then
						poi_count += 1
						poi_list[poi_count] =
						{
							kind = world.MOUNT,
							x = px + TILE_SIZE - 1,
							y = py + HALF_TILE_SIZE,
							a = 180
						}
						assert(debug_trace_poi(poi_list, poi_count, "find_points_of_interest (MOUNT_RIGHT)"))
					end
				end
			end

			::next_x::
		end
		::next_y::
	end

	-- Insert balls to points of interest list if they are nearby.
	for i = 1, #world.balls do
		local ball_x <const> = world.balls[i][1]
		local ball_y <const> = world.balls[i][2]
		assert(ball_x == floor(ball_x))
		assert(ball_y == floor(ball_y))
		local d2 = distance2(hand_x - ball_x, hand_y - ball_y)
		if d2 < TILE_SIZE * TILE_SIZE * 9 then
			-- Balls are always picked up from above, since they should always
			-- be resting on an upward facing surface.
			poi_count += 1
			poi_list[poi_count] =
			{
				kind = world.PICK_UP,
				x = ball_x,
				y = ball_y,
				a = 90,
				d = d2,
				ball = i,
			}
			assert(debug_trace_poi(poi_list, poi_count, "find_points_of_interest (pickup ball)"))
		end

		-- If a ball has moved sufficiently far from its initial location, and
		-- the initial location is hear the hand, add target to summon the ball.
		local ball_init_x <const> = world.INIT_BALLS[i][1]
		local ball_init_y <const> = world.INIT_BALLS[i][2]
		local id2 <const> = distance2(ball_init_x - ball_x, ball_init_y - ball_y)
		if id2 > BALL_SUMMON_DISTANCE2 then
			d2 = distance2(hand_x - ball_init_x, hand_y - ball_init_y)
			if d2 < TILE_SIZE * TILE_SIZE * 9 then
				poi_count += 1
				poi_list[poi_count] =
				{
					kind = world.SUMMON,
					x = ball_init_x,
					y = ball_init_y,
					a = 90,
					d = d2,
					ball = i,
				}
				assert(debug_trace_poi(poi_list, poi_count, "find_points_of_interest (summon ball)"))
			end
		end
	end

	-- Check for nearby teleport stations.
	local t_index <const> = get_nearest_visible_teleport_station(hand_x, hand_y)
	if t_index > 0 then
		-- Get distance to action target.
		local station_x <const> = world.TELEPORT_POSITIONS[t_index][1]
		local station_y <const> = world.TELEPORT_POSITIONS[t_index][2] - TELEPORT_STATION_HEIGHT
		local dx <const> = station_x - hand_x
		local dy <const> = station_y - hand_y
		local d2 <const> = distance2(dx, dy)

		-- Get index of this teleport station within world.teleport_stations.
		local w_index = 0
		for i = 1, #world.teleport_stations do
			if world.teleport_stations[i] == t_index then
				w_index = i
				break
			end
		end
		if w_index > 0 then
			-- Hand is near a teleport station that the arm has visited before,
			-- and w_index is the position within world.teleport_stations for
			-- that station number.  We will decrement w_index here to point the
			-- previously visited teleport station before the current one.
			--
			-- If we were incrementing w_index instead, the initial teleport
			-- destination for every newly visited teleport station will always
			-- be the first teleport station that the player has visited, which
			-- seems less useful than getting player back to where they were
			-- just before the current station.
			--
			-- Another alternative is to always visit the teleport stations
			-- in predefined fixed order, similar to how warp rooms work in
			-- Symphony of the Night.  The issue with that is having to define
			-- an order that makes sense, and also being able to encode that
			-- order in our build process.  Current system of having the player
			-- implicitly define the visit order seem more intuitive.
			w_index -= 1
		else
			-- Hand is near a teleport station that player has never visited
			-- before.  Append it to list of teleport stations.
			w_index = #world.teleport_stations
			world.teleport_stations[w_index + 1] = t_index
			assert(debug_log(string.format("registered teleport station %d @ (%d,%d), hand=(%d,%d), distance to activation point=%.0f", t_index, world.TELEPORT_POSITIONS[t_index][1], world.TELEPORT_POSITIONS[t_index][2], hand_x, hand_y, sqrt(d2))))
		end

		-- If teleport station is sufficiently close, add it to the points
		-- of interest list.
		if d2 < TILE_SIZE * TILE_SIZE * 9 then
			if w_index == 0 then
				w_index = #world.teleport_stations
			end
			local selected_index <const> = world.teleport_stations[w_index]

			poi_count += 1
			poi_list[poi_count] =
			{
				kind = world.TELEPORT,
				x = station_x,
				y = station_y,
				a = 90,
				d = d2,
				next_x = world.TELEPORT_POSITIONS[selected_index][1],
				next_y = world.TELEPORT_POSITIONS[selected_index][2],
			}
			assert(debug_trace_poi(poi_list, poi_count, "find_points_of_interest (teleport)"))
		end
	end

	-- Sort points of interest by distance.
	if #poi_list > 1 then
		for i = 1, #poi_list do
			if not poi_list[i].d then
				poi_list[i].d = distance2(hand_x - poi_list[i].x, hand_y - poi_list[i].y)
			end
		end
		sort_poi_list(poi_list)
		insert_extra_mount_point(poi_list, hand_x, hand_y)
	end

	-- Add extra mount points near existing sorted mount points.  These are
	-- meant to be fallback positions for when the tile-aligned mount points
	-- will not work.
	--
	-- Note that we don't do another round of sort after the extra points are
	-- appended, so that we give priority to the tile-aligned mount points.
	append_unaligned_mount_points(poi_list)
	return poi_list
end

local function test_find_points_of_interest()
	-- Verify the first returned mount points for each hand position.
	-- Input data is an invisible collision shape at (128,128)..(384,352)
	-- of the world map.
	local test_points <const> =
	{
		-- Points aligned to center of cells.
		{hand_x=176, hand_y=258, x=176, y=320, a=90},
		{hand_x=176, hand_y=295, x=176, y=320, a=90},
		{hand_x=176, hand_y=357, x=176, y=351, a=270},
		{hand_x=208, hand_y=258, x=208, y=320, a=90},
		{hand_x=256, hand_y=224, x=304, y=272, a=45},
		{hand_x=384, hand_y=320, x=336, y=272, a=225},
		{hand_x=291, hand_y=176, x=352, y=176, a=0},
		{hand_x=435, hand_y=176, x=383, y=176, a=180},
		-- Points offset from cell centers.
		{hand_x=180, hand_y=258, x=180, y=320, a=90},
		{hand_x=260, hand_y=220, x=304, y=272, a=45},
		{hand_x=252, hand_y=228, x=304, y=272, a=45},
		{hand_x=380, hand_y=324, x=332, y=276, a=225},
		{hand_x=435, hand_y=169, x=383, y=176, a=180},
		{hand_x=435, hand_y=183, x=383, y=176, a=180},
	}
	for i = 1, #test_points do
		local t <const> = test_points[i]
		local poi_list <const> = world.find_points_of_interest(t.hand_x, t.hand_y)
		assert(#poi_list >= 1, string.format("test_points[%d]: #poi_list >= 1", i))
		assert(poi_list[1].x == t.x, string.format("test_points[%d]: poi_list[1].x (%d) == t.x (%d)", i, poi_list[1].x, t.x))
		assert(poi_list[1].y == t.y, string.format("test_points[%d]: poi_list[1].y (%d) == t.y (%d)", i, poi_list[1].y, t.y))
		assert(poi_list[1].a == t.a, string.format("test_points[%d]: poi_list[1].a (%d) == t.a (%d)", i, poi_list[1].a, t.a))
	end
	return true
end
assert(test_find_points_of_interest())

-- List all actionable positions matching the entries in world.hints[frame],
-- and append {0, world_x, world_y, cursor_type} entries to hint_table.
--
-- This is similar in world.find_points_of_interest in the sense that it
-- finds actionable spots, but it never matches balls nor teleport stations,
-- and it never checks reachability or orientation.  The motivation for this
-- function is to provide hints to player as to what spots could be actionable
-- if they were to move closer, particularly those spots that aren't visually
-- obvious as such (e.g. hidden chain reaction tiles).
function world.add_tile_hints(x, y, frame, hint_table)
	local hint_scan_group <const> = world.hints[frame]
	if not hint_scan_group then return end

	-- Compute grid coordinates for the current tile, and also world
	-- coordinates for the upper left corner of current tile.
	local grid_x <const>, grid_y <const> = get_tile_position(x, y)
	local cx <const> = (grid_x - 1) << 5
	local cy <const> = (grid_y - 1) << 5
	assert(cx == (grid_x - 1) * TILE_SIZE)
	assert(cy == (grid_y - 1) * TILE_SIZE)

	-- Build table to convert cursor types back to world coordinates.
	local offsets <const> =
	{
		-- Up.
		{cx + HALF_TILE_SIZE, cy},
		-- Down.
		{cx + HALF_TILE_SIZE, cy + TILE_SIZE - 1},
		-- Left.
		{cx, cy + HALF_TILE_SIZE},
		-- Right.
		{cx + TILE_SIZE - 1, cy + HALF_TILE_SIZE},
		-- Up right + down left.
		{cx + HALF_TILE_SIZE, cy + HALF_TILE_SIZE},
		-- Up left + down right.
		{cx + HALF_TILE_SIZE, cy + HALF_TILE_SIZE},
		-- Circle.
		{cx + HALF_TILE_SIZE, cy + HALF_TILE_SIZE},
		-- Square.
		{cx + HALF_TILE_SIZE, cy + HALF_TILE_SIZE},
	}

	local o = #hint_table
	for i = 1, #hint_scan_group do
		local entry <const> = hint_scan_group[i]
		local dx <const> = entry[1]
		local dy <const> = entry[2]
		assert(dx == floor(dx))
		assert(dy == floor(dy))
		assert(dx << 5 == dx * TILE_SIZE)
		assert(dy << 5 == dy * TILE_SIZE)
		local mask <const> = entry[3]
		local bits <const> = entry[4]
		local t <const> = entry[5]

		-- Add entries for lower right quadrant.
		if matched_metadata_bits(grid_x + dx, grid_y + dy, mask, bits) then
			o += 1
			hint_table[o] =
			{
				0,
				offsets[t][1] + (dx << 5),
				offsets[t][2] + (dy << 5),
				t,
			}
		end

		-- Add entries for lower left quadrant.
		if dx ~= 0 and
		   matched_metadata_bits(grid_x - dx, grid_y + dy, mask, bits) then
			o += 1
			hint_table[o] =
			{
				0,
				offsets[t][1] - (dx << 5),
				offsets[t][2] + (dy << 5),
				t,
			}
		end

		-- Add entries for upper right quadrant.
		if dy ~= 0 and
		   matched_metadata_bits(grid_x + dx, grid_y - dy, mask, bits) then
			o += 1
			hint_table[o] =
			{
				0,
				offsets[t][1] + (dx << 5),
				offsets[t][2] - (dy << 5),
				t,
			}
		end

		-- Add entries for upper left quadrant.
		if dx ~= 0 and dy ~= 0 and
		   matched_metadata_bits(grid_x - dx, grid_y - dy, mask, bits) then
			o += 1
			hint_table[o] =
			{
				0,
				offsets[t][1] - (dx << 5),
				offsets[t][2] - (dy << 5),
				t,
			}
		end
	end
end

-- Draw direction to nearest item.
function world.draw_item_hint(include_visible_items)
	-- Stop if there are no items remaining.
	if #world.collected_tiles >= world.ITEM_COUNT then
		return
	end

	-- Build index of all items on first call.
	if not item_locations then
		item_locations = {}
		local i = 0
		for y = 1, GRID_H do
			for x = 1, GRID_W do
				if (world.metadata[y][x] & COLLECTIBLE_MASK) ~= 0 then
					i += 1
					item_locations[i] = {x, y}
				end
			end
		end
	end

	-- Find item that is closest to screen center.
	local cx <const> = SCREEN_WIDTH / 2 - world.sprite_offset_x
	local cy <const> = SCREEN_HEIGHT / 2 - world.sprite_offset_y
	local dx = nil
	local dy = nil
	local nearest_d2 = 0x7fffffff
	for i = #item_locations, 1, -1 do
		local x <const> = item_locations[i][1]
		local y <const> = item_locations[i][2]
		if (world.metadata[y][x] & COLLECTIBLE_MASK) ~= 0 then
			local t_dx <const> = (x << 5) - HALF_TILE_SIZE - cx
			local t_dy <const> = (y << 5) - HALF_TILE_SIZE - cy
			assert(t_dx == (x - 1) * TILE_SIZE + HALF_TILE_SIZE - cx)
			assert(t_dy == (y - 1) * TILE_SIZE + HALF_TILE_SIZE - cy)

			local d2 <const> = t_dx * t_dx + t_dy * t_dy
			if (not nearest_d2) or nearest_d2 > d2 then
				nearest_d2 = d2
				dx = t_dx
				dy = t_dy
			end
		else
			-- Item is no longer available, remove it from index.
			table.remove(item_locations, i)
		end
	end
	assert(dx)
	assert(dy)

	-- Check if item is visible on screen.  Because the deltas are adjusted by
	-- HALF_TILE_SIZE above, an item would be considered visible if it's less
	-- than half a tile outside of the screen region.  The margin usually
	-- doesn't that much of a difference because for most items (ones that
	-- are not hidden behind foreground tiles), world.expand_focus() will
	-- bring the item into view when the player gets close.
	if abs(dx) <= SCREEN_WIDTH / 2 + TILE_SIZE and
	   abs(dy) <= SCREEN_HEIGHT / 2 + TILE_SIZE then
		if not include_visible_items then
			return
		end

		-- Compute tip of triangle.
		if dy > SCREEN_HEIGHT / 2 - TILE_SIZE then
			-- Drawing triangle above the item, pointing down.
			x0 = cx + dx
			y0 = min(cy + dy - TILE_SIZE, cy + SCREEN_HEIGHT / 2 - 4)
			dx = 0
			dy = 1
		elseif dy < -SCREEN_HEIGHT / 2 + TILE_SIZE then
			-- Drawing triangle below the item, pointing up.
			x0 = cx + dx
			y0 = max(cy + dy + TILE_SIZE, cy - SCREEN_HEIGHT / 2 + 4)
			dx = 0
			dy = -1
		else
			y0 = cy + dy
			dy = 0
			assert(cy - SCREEN_HEIGHT / 2 < y0 and y0 < cy + SCREEN_HEIGHT / 2)
			if dx < 0 then
				-- Drawing triangle to the right of the item, pointing left.
				x0 = max(cx + dx + TILE_SIZE, cx - SCREEN_WIDTH / 2 + 4)
				dx = -1
			else
				-- Drawing triangle to the left of the item, pointing right.
				x0 = min(cx + dx - TILE_SIZE, cx + SCREEN_WIDTH / 2 - 4)
				dx = 1
			end
		end
		assert(dx ~= 0 or dy ~= 0)
		assert(dx == 0 or dx == -1 or dx == 1)
		assert(dy == 0 or dy == -1 or dy == 1)

		-- If tip of triangle is sufficiently close to the center of the screen,
		-- invert the triangle so that it's drawn closer to the edge of the
		-- screen and have it point inward.  This is to avoid the triangle
		-- getting in the way between the arm and the item.
		if abs(x0 - cx) < SCREEN_WIDTH / 2 - 80 then
			x0 += dx * 64
			dx = -dx
		end
		if abs(y0 - cy) < SCREEN_HEIGHT / 2 - 80 then
			y0 += dy * 64
			dy = -dy
		end

		-- Compute base of triangle.
		local base_x <const> = x0 - 16 * dx
		local base_y <const> = y0 - 16 * dy

		-- Compute the triangle sides by rotating (dx,dy) and applying the
		-- rotated vector away from the base.
		local x1 <const> = base_x + 9 * dy
		local y1 <const> = base_y - 9 * dx
		local x2 <const> = base_x - 9 * dy
		local y2 <const> = base_y + 9 * dx

		-- Draw filled black triangle with white outlines.
		gfx.setColor(gfx.kColorBlack)
		gfx.fillTriangle(x0, y0, x1, y1, x2, y2)
		gfx.setColor(gfx.kColorWhite)
		gfx.setLineWidth(2)
		gfx.drawTriangle(x0, y0, x1, y1, x2, y2)
		return
	end

	-- We want to draw a triangle that points at the item, with the tip
	-- near the edge of the screen.  We will start with the coordinate
	-- of the tip first:
	--
	--  (x0,y0) = (cx,cy) + t * (dx,dy)
	local tx = 0x7fffffff
	local ty = 0x7fffffff
	if dx ~= 0 then
		tx = abs((SCREEN_WIDTH / 2 - 4) / dx)
	end
	if dy ~= 0 then
		ty = abs((SCREEN_HEIGHT / 2 - 4) / dy)
	end
	local t <const> = tx < ty and tx or ty
	local x0 <const> = cx + t * dx
	local y0 <const> = cy + t * dy

	-- Compute the base of the triangle by normalizing (dx,dy) scaling it
	-- to the desired height that we want, and move backwards from the
	-- tip using that vector.
	local s <const> = sqrt(nearest_d2)
	assert(s > 0)
	dx /= s
	dy /= s
	local base_x <const> = x0 - 16.0 * dx
	local base_y <const> = y0 - 16.0 * dy

	-- Compute the triangle sides by rotating (dx,dy) and applying the
	-- rotated vector away from the base.
	local x1 <const> = base_x + 9.0 * dy
	local y1 <const> = base_y - 9.0 * dx
	local x2 <const> = base_x - 9.0 * dy
	local y2 <const> = base_y + 9.0 * dx

	-- Draw filled black triangle with white outlines.
	gfx.setColor(gfx.kColorBlack)
	gfx.fillTriangle(x0, y0, x1, y1, x2, y2)
	gfx.setColor(gfx.kColorWhite)
	gfx.setLineWidth(2)
	gfx.drawTriangle(x0, y0, x1, y1, x2, y2)
end

-- Summon or move UFO to a particular location.
function world.move_ufo(x, y)
	ufo_frame_delta = -1
	ufo_sprite:moveTo(x - UFO_WIDTH // 2, y - UFO_HEIGHT // 2)
end

-- Move UFO and simultaneously decrease its opacity.
function world.dismiss_ufo(x, y)
	ufo_frame_delta = 1
	ufo_sprite:moveTo(x - UFO_WIDTH // 2, y - UFO_HEIGHT // 2)
end

-- Reset historical ball positions for recently captured ball.
function world.reset_ball_history(ball_index)
	for i = 0, BALL_HISTORY_MASK do
		world.ball_position_history[i] =
		{
			world.balls[ball_index][1],
			world.balls[ball_index][2],
		}
	end
end

-- Set ball's Z-order to mark it as been held by the arm.
function world.update_ball_for_hold(ball_index, z)
	ball_sprite[ball_index]:setZIndex(z)
end

-- Update ball position.
function world.update_ball_position(ball_index, x, y)
	world.follow_ball = ball_index

	world.ball_position_history[world.ball_history_index][1] = world.balls[ball_index][1]
	world.ball_position_history[world.ball_history_index][2] = world.balls[ball_index][2]
	world.ball_history_index = (world.ball_history_index + 1) & BALL_HISTORY_MASK

	world.balls[ball_index][1] = x
	world.balls[ball_index][2] = y
end

-- Throw a ball with the given velocity.
function world.throw_ball(ball_index)
	assert(ball_index > 0)
	assert(ball_index <= #world.INIT_BALLS)

	-- Restore original Z-index for balls such that they are drawn just above
	-- the background layer, and below all arm sprites.  This is so that we
	-- don't see the weird artifact of the ball rolling through the elbow hole.
	--
	-- Players could arrange a pose such that this change in Z-index is
	-- observable upon release, which will look weird, but less weird than
	-- the ball rolling through the elbow hole.
	ball_sprite[ball_index]:setZIndex(Z_BALL)

	-- Initial velocity is the different in ball position from now and
	-- a few frames back.
	--
	-- Other things we tried include adding up all position deltas from
	-- the past few frames, which doesn't work because they tend to add
	-- up to zero (probably has a lot to do with how the hand jerks back
	-- a bit just before release).  We also tried reading from a different
	-- frame offset, but current offset appears to work best.
	--
	-- Initial velocities can be pretty wild, but the first thing that
	-- move_ball() does is to clamp the velocities to a reasonable range,
	-- so we don't need to do any range check here.
	local previous <const> = (world.ball_history_index - 5) & BALL_HISTORY_MASK
	local b <const> = world.balls[ball_index]
	local vx = b[1] - world.ball_position_history[previous][1]
	local vy = b[2] - world.ball_position_history[previous][2]
	local move_frame_count = 0
	local hit_tile_x, hit_tile_y
	local ufo_bounce_timer = 0

	-- Count the number of throws.
	if vx ~= 0 or vy ~= 0 then
		world.throw_count += 1
	else
		world.drop_count += 1
	end

	-- Animate ball until it comes to a standstill.
	while true do
		if world.reset_requested then
			break
		end

		-- Update ball position.
		vx, vy, hit_tile_x, hit_tile_y = move_ball(ball_index, vx, vy)
		world.update()

		-- (hit_tile_x, hit_tile_y) would be defined if some special handling
		-- of the ball is needed, and would be within grid range if that was
		-- a collision.  In the latter case, we will apply the collision action
		-- to the world.
		if hit_tile_x and hit_tile_x > 0 then
			assert(hit_tile_x <= GRID_W)
			assert(hit_tile_y)
			assert(hit_tile_y > 0)
			assert(hit_tile_y <= GRID_H)
			update_mutable_tile(hit_tile_x, hit_tile_y)
		end

		-- Check if the center of the ball passed through a CHAIN_REACTION tile.
		-- If so, go ahead and trigger the chain reactions.  This is used to
		-- handle traps where the ball would roll through without collisions.
		--
		-- Even though this branch is placed after the collision handling bits
		-- above, in practice it shouldn't matter whether we place it before
		-- or after.  If there is a CHAIN_REACTION tile without collision bits
		-- in front of some wall, the ball will trigger the CHAIN_REACTION code
		-- here before it is able to travel past the tile, due to speed limit.
		local tile_x <const>, tile_y <const> =
			get_tile_position(floor(b[1]), floor(b[2]))
		if (world.metadata[tile_y][tile_x] & CHAIN_REACTION) ~= 0 then
			update_mutable_tile(tile_x, tile_y)
		end

		-- Update camera to follow the ball.
		--
		-- After this function returns, we will be back to having camera
		-- follow the arm.
		world.focus_min_x = b[1] - BALL_RADIUS
		world.focus_max_x = b[1] + BALL_RADIUS
		world.focus_min_y = b[2] - BALL_RADIUS
		world.focus_max_y = b[2] + BALL_RADIUS

		-- Show UFO if ball is near the top edge of the world.
		if ufo_bounce_timer == 0 and b[2] < 96 then
			ufo_bounce_timer = UFO_BOUNCE_FRAMES
			world.ufo_count += 1
		end
		if ufo_bounce_timer > 0 then
			-- Set UFO position.
			if ufo_bounce_timer > UFO_FRAMES then
				world.move_ufo(b[1], TILE_SIZE)
			else
				world.dismiss_ufo(b[1], TILE_SIZE)
			end

			-- Try to include UFO in the view.
			local ufo_x <const>, ufo_y <const> = ufo_sprite:getPosition()
			world.focus_min_x = min(world.focus_min_x, ufo_x)
			world.focus_max_x = max(world.focus_max_x, ufo_x + UFO_WIDTH)
			world.focus_min_y = min(world.focus_min_y, ufo_y)
			world.focus_max_y = max(world.focus_max_y, ufo_y + UFO_HEIGHT)
			ufo_bounce_timer -= 1
		end
		world.update_viewport()

		-- If we want to register teleport stations seen by the ball while
		-- it's bouncing, this would be the place to do it.  But we are not
		-- doing that, and we are also not registering any teleport stations
		-- that might be observed in a chain reaction.  You had to be there.

		gfx.sprite.update()
		assert(debug_frame_rate())
		coroutine.yield()

		-- If there was a collision, exit this loop when the velocity is
		-- sufficiently small.  In other words, stop when we have lost enough
		-- energy due to bounces and friction.
		--
		-- We don't want to stop simply based on low velocity alone, because
		-- that will cause us to stop when an upward flying ball reached zero
		-- velocity at the apex of its parabolic flight path.
		if hit_tile_x and abs(vx) < 0.9 and abs(vy) < 0.9 then
			assert(debug_log(string.format("ball %d stopped after %d frames, velocity=(%g,%g)", ball_index, move_frame_count, vx, vy)))
			break
		end

		-- Check if ball is oscillating in a very small area, and force stop
		-- the ball if so.
		--
		-- This is a safety hack: despite all the checks we put into move_ball
		-- to make sure that the ball will eventually halt, there is some chance
		-- that some numerical peculiarity could cause things to fail.  This
		-- hack here ensures that the ball is not bouncing indefinitely.
		move_frame_count += 1
		if (move_frame_count & BALL_HISTORY_MASK) == 0 and
		   stop_infinite_bounce(ball_index, move_frame_count, vx, vy) then
			break
		end
	end

	-- Dismiss UFO if it showed up.  It's extremely unlikely that the UFO is
	-- still visible since it would require the ball coming to a stop within
	-- 25 frames after it reached the world's ceiling, but just in case if
	-- the ball unexpectedly got stuck, we don't want the UFO to get stuck
	-- along with it.
	if ufo_bounce_timer > 0 then
		world.dismiss_ufo(b[1], TILE_SIZE)
	end

	-- Make sure ball's at-rest position is integer.
	b[1] = util.round(b[1])
	b[2] = util.round(b[2])

	-- Stop following this ball.
	world.follow_ball = 0

	-- Refresh serialized_balls on next update.
	world.serialized_balls_dirty = true
end

-- Summon ball to its initial location.
--
-- This is our solution to all the balls that got stuck in weird places.
-- If player remember where they originally found those balls, they can
-- go there and recall the ball back.
function world.summon_ball(ball_index)
	assert(ball_index > 0)
	assert(ball_index <= #world.INIT_BALLS)
	local b = world.balls[ball_index]
	local ball_image = world_tiles:getImage(ball_sprite_tile_index[ball_index])
	assert(ball_image)

	-- If ball is currently visible on screen, make it disappear from its
	-- current location first.  This is to make the teleport less abrupt if
	-- the ball's previous and current locations are both visible.
	--
	-- If it's not visible on screen then we don't bother, since we don't want
	-- player to sit through the few frames for the invisible ball to shrink.
	local bx <const> = b[1] + world.sprite_offset_x
	local by <const> = b[2] + world.sprite_offset_y
	if bx > -BALL_RADIUS and bx < SCREEN_WIDTH + BALL_RADIUS and
	   by > -BALL_RADIUS and by < SCREEN_HEIGHT + BALL_RADIUS then
		for i = 6, 1, -1 do
			if world.reset_requested then return end

			ball_sprite[ball_index]:setImage(ball_image, gfx.kImageUnflipped, i / 6)
			world.update()
			world.update_viewport()
			gfx.sprite.update()
			coroutine.yield()
		end
	end

	-- Move the ball to a spawn location.  If the ball's initial location
	-- is above a square collision tile, we will spawn the ball at a few
	-- tiles above its initial location, and let it drop into place.  In
	-- most cases, this means the ball can be summoned and picked up without
	-- having to move the robot arm.
	--
	-- If the ball's initial location is not above a square collision tile,
	-- we will throw the ball at an angle instead.  This is essentially a
	-- special case for the comet at (3664,336), where dropping the ball
	-- straight down would look weird.
	local tile_x <const>, tile_y <const> = get_tile_position(
		world.INIT_BALLS[ball_index][1], world.INIT_BALLS[ball_index][2])
	assert(world.metadata[tile_y + 1])
	if (world.metadata[tile_y + 1][tile_x] & COLLISION_MASK) == COLLISION_SQUARE then
		-- Spawn at a few tiles above the initial location.
		b[1] = world.INIT_BALLS[ball_index][1]
		b[2] = world.INIT_BALLS[ball_index][2] - TILE_SIZE * 3

		-- Grow the ball back to original size.
		for i = 1, 6 do
			if world.reset_requested then return end

			ball_sprite[ball_index]:setImage(ball_image, gfx.kImageUnflipped, i / 6)
			world.update()
			world.update_viewport()
			gfx.sprite.update()
			coroutine.yield()
		end

		-- Drop the ball to current location.  Because this is not dropped
		-- from the end of arm, we decrement drop_count here to balance out
		-- the extra drop_count that would be added by world.throw_ball().
		world.drop_count -= 1
		world.reset_ball_history(ball_index)
	else
		-- Make sure ball_position_history is not empty.
		world.reset_ball_history(ball_index)

		-- Grow the ball back to original size, while also moving the ball
		-- toward its initial location.  The path here will be written to
		-- world.ball_position_history, and world.throw_ball() will use that
		-- to set the initial velocity.
		--
		-- Because the ball is thrown instead of dropped, it will fly off to
		-- the left after being summoned, and player will need to move a bit
		-- to pick it up.  This is slightly inconvenient, but on the plus side,
		-- player can now generate shooting stars repeatedly at the same place
		-- without having to pick a ball.
		for i = 1, 16 do
			if world.reset_requested then return end

			local bx <const> = world.INIT_BALLS[ball_index][1] + (16 - i) * (128 / 16)
			local by <const> = world.INIT_BALLS[ball_index][2] - (16 - i) * (84 / 16)
			world.update_ball_position(ball_index, bx, by)
			ball_sprite[ball_index]:setImage(ball_image, gfx.kImageUnflipped, i / 16)

			world.focus_min_x = bx - HALF_TILE_SIZE
			world.focus_min_y = by - HALF_TILE_SIZE
			world.focus_max_x = bx + HALF_TILE_SIZE
			world.focus_max_y = by + HALF_TILE_SIZE

			world.update()
			world.update_viewport()
			gfx.sprite.update()
			coroutine.yield()
		end

		-- Since the ball is thrown instead of dropped, we will decrement
		-- throw_count here to balance out the extra throw_count that would
		-- be added by world.throw_ball().
		world.throw_count -= 1
	end
	world.throw_ball(ball_index)
end

-- Given world coordinates of a mount point and the hand angle to mount
-- at that coordinate, check if the mount pose is valid.  Returns true if s.
-- to mount at that coordinate.  Returns nil if mount point is not valid.
function world.check_mount_angle(world_x, world_y, hand_angle)
	-- Reject negative world coordinates before calling get_tile_position.
	-- This is needed because the input coordinates came from saved state,
	-- and this function is called at load time, so we haven't validated
	-- all coordinates yet.
	if world_x < 0 or world_y < 0 then
		return false
	end

	local grid_x <const>, grid_y <const> = get_tile_position(world_x, world_y)
	if not world.metadata[grid_y] then return false end
	if not world.metadata[grid_y][grid_x] then return false end
	local mount <const> = world.metadata[grid_y][grid_x] & MOUNT_MASK

	-- Check mount bits for horizontal and vertical mounts.
	--
	-- We first check that the coordinates are of the right alignment for the
	-- particular mount direction, then confirm that the tile is one of the
	-- two bit patterns that would satisfy the hand direction.
	if hand_angle == 0 then
		return world_x % TILE_SIZE == 0 and
		       (mount == MOUNT_LEFT or mount == (MOUNT_LEFT | MOUNT_RIGHT))
	elseif hand_angle == 90 then
		return world_y % TILE_SIZE == 0 and
		       (mount == MOUNT_UP or mount == (MOUNT_UP | MOUNT_DOWN))
	elseif hand_angle == 180 then
		return world_x % TILE_SIZE == TILE_SIZE - 1 and
		       (mount == MOUNT_RIGHT or mount == (MOUNT_LEFT | MOUNT_RIGHT))
	elseif hand_angle == 270 then
		return world_y % TILE_SIZE == TILE_SIZE - 1 and
		       (mount == MOUNT_DOWN or mount == (MOUNT_UP | MOUNT_DOWN))
	end

	-- Check mount bits for diagonal mounts.  For these we only check that
	-- the tile has the right mask bits, since there is at most one mount
	-- direction per tile.
	if hand_angle == 45 then
		return mount == (MOUNT_UP | MOUNT_LEFT)
	elseif hand_angle == 135 then
		return mount == (MOUNT_UP | MOUNT_RIGHT)
	elseif hand_angle == 225 then
		return mount == (MOUNT_DOWN | MOUNT_RIGHT)
	elseif hand_angle == 315 then
		return mount == (MOUNT_DOWN | MOUNT_LEFT)
	end
	return false
end

-- Test get_mount_angle using the invisible collision shape at
-- (128,128)..(384,352) of the world map.
assert(world.check_mount_angle(352, 176, 0))
assert(world.check_mount_angle(383, 176, 180))
assert(world.check_mount_angle(176, 320, 90))
assert(world.check_mount_angle(208, 320, 90))
assert(world.check_mount_angle(207, 320, 90))
assert(world.check_mount_angle(176, 351, 270))
assert(world.check_mount_angle(208, 351, 270))
assert(world.check_mount_angle(180, 351, 270))
assert(world.check_mount_angle(304, 272, 45))
assert(world.check_mount_angle(319, 288, 225))
assert(not world.check_mount_angle(0, 0, 0))
assert(not world.check_mount_angle(144, 320, 90))
assert(not world.check_mount_angle(144, 351, 270))
assert(not world.check_mount_angle(352, 144, 0))
assert(not world.check_mount_angle(383, 144, 180))

assert(not world.check_mount_angle(176, 320, 0))
assert(not world.check_mount_angle(176, 320, 45))
assert(not world.check_mount_angle(176, 320, 135))
assert(not world.check_mount_angle(176, 320, 180))
assert(not world.check_mount_angle(176, 320, 225))
assert(not world.check_mount_angle(176, 320, 270))
assert(not world.check_mount_angle(176, 320, 315))

-- Return image at a particular tile location.
--
-- This is used to convert a particular tile into a movable/scalable image.
-- We only need this for background tiles because we don't ever move
-- foreground tiles that way.
function world.get_bg_tile_image(world_x, world_y)
	return world_tiles:getImage(get_bg_tile_image_index(world_x, world_y))
end

-- Remove collectible tile and add to item collection.
-- Input is world coordinates (as opposed to tile coordinates).
function world.remove_collectible_tile(world_x, world_y)
	assert(world_x >= 0)
	assert(world_y >= 0)

	-- Check that the tile we want to remove is still collectible.  This is
	-- normally always true because find_points_of_interest wouldn't return
	-- coordinates to a collectible tile if it wasn't there, but it's possible
	-- for world tiles to be out of sync via world.test_endgame()
	local tile_x <const>, tile_y <const> = get_tile_position(world_x, world_y)
	if (world.metadata[tile_y][tile_x] & COLLECTIBLE_MASK) == 0 then
		return
	end

	table.insert(world.collected_tiles, world_grid_bg[0]:getTileAtPosition(tile_x, tile_y))

	remove_tile(tile_x, tile_y, world_grid_bg, false)
	world.metadata[tile_y][tile_x] &= ~COLLECTIBLE_MASK
	world.last_item_tile_x = tile_x
	world.last_item_tile_y = tile_y
end

-- Remove breakable obstacles.  Input is a list of world coordinates.
function world.remove_breakable_tiles(points)
	-- Convert world coordinates to tile coordinates, keeping only the
	-- unique breakable tiles.
	local unique_tiles = {}
	local unique_tile_count = 0
	for i = 1, #points do
		-- Make sure point is within world boundaries before converting to tile
		-- coordinates.  This is needed to accommodate debug mode where player
		-- may move the arm near the edges of the map.  In normal gameplay,
		-- the arm will never get that close to the edges.
		if points[i][1] > 0 and points[i][1] < world.WIDTH and
		   points[i][2] > 0 and points[i][2] < world.HEIGHT then
			local tile_x <const>, tile_y <const> = get_tile_position(points[i][1], points[i][2])
			if (world.metadata[tile_y][tile_x] & MUTABLE_TILE) ~= 0 then
				local unique = true
				for j = 1, #unique_tiles do
					if tile_x == unique_tiles[j][1] and
					   tile_y == unique_tiles[j][2] then
						unique = false
						break
					end
				end
				if unique then
					unique_tile_count += 1
					unique_tiles[unique_tile_count] = {tile_x, tile_y}
				end
			end
		end
	end

	for i = 1, unique_tile_count do
		local t <const> = unique_tiles[i]
		update_mutable_tile(t[1], t[2])
	end
end

-- Draw collected item list.
function world.show_item_list()
	-- Use blurred screenshot as background.
	local item_list = gfx.getDisplayImage():blurredImage(2, 2, gfx.image.kDitherTypeFloydSteinberg)

	gfx.pushContext(item_list)

	-- Draw some white diagonal lines to lighten the background.  This is to
	-- make the items stand out more, if the screenshot happens the be dark.
	-- Ideally we should be able to insert a fadedImage() call before the
	-- blurredImage() call above to achieve the same effect, but it's not as
	-- consistent as if we were to just draw the pattern ourselves on top
	-- of the blurred background.
	gfx.setColor(gfx.kColorWhite)
	gfx.setLineWidth(1)
	for x = 0, 640, 4 do
		gfx.drawLine(x, 0, x - 240, 240)
	end

	-- Draw list of items with a tilemap.
	local item_tiles = gfx.tilemap.new()
	item_tiles:setImageTable(world_tiles)
	item_tiles:setSize(ITEM_GRID_W, ITEM_GRID_H)
	for i = 1, #world.collected_tiles do
		local x <const> = (i - 1) % ITEM_GRID_W + 1
		local y <const> = (i - 1) // ITEM_GRID_W + 1
		item_tiles:setTileAtPosition(x, y, world.collected_tiles[i])
	end
	item_tiles:drawIgnoringOffset(8, 8)
	gfx.popContext(item_list)

	item_list:drawIgnoringOffset(0, 0)
end

-- Conditionally initialize endgame.  There are exactly two places that
-- call this function:
-- + world.load_saved_state(), to check if we are resuming from winning state.
-- + arm.execute_action(), to check if we are entering winning state right
--   after collecting an item.
function world.check_victory_state()
	assert(world.ITEM_COUNT > 0)
	if #world.collected_tiles < world.ITEM_COUNT then
		return
	end

	-- Update timestamp if it's not updated yet.  It might have been updated
	-- already if we got here from world.load_saved_state().
	if world.completed_frame_count <= 0 then
		world.completed_frame_count = world.frame_count
	end

	-- Mark where we collected the last item.
	assert(not completion_timer)
	add_completion_marker()
end

-- Validate a partial save state, returns true if state is valid.
function world.is_valid_save_state(state)
	-- General schema check.
	local SCHEMA <const> =
	{
		[SAVE_STATE_REMOVED_TILES] = "table",
		[SAVE_STATE_FRAME_COUNT] = "uint",
		[SAVE_STATE_DEBUG_FRAME_COUNT] = "uint",
		[SAVE_STATE_COMPLETED_FRAME_COUNT] = "uint",
		[SAVE_STATE_THROW_COUNT] = "uint",
		[SAVE_STATE_DROP_COUNT] = "uint",
		[SAVE_STATE_UFO_COUNT] = "uint",
		[SAVE_STATE_BALLS] = "table",
		[SAVE_STATE_TELEPORT_STATIONS] = "table",
		[SAVE_STATE_SPRITE_OFFSET_X] = "float",
		[SAVE_STATE_SPRITE_OFFSET_Y] = "float",
	}
	if not util.validate_state(SCHEMA, state) then
		assert(debug_log("invalid world state: mismatched schema"))
		return false
	end

	-- Check if all removed tiles matches metadata content.
	if #state[SAVE_STATE_REMOVED_TILES] % 2 ~= 0 or
	   #state[SAVE_STATE_REMOVED_TILES] > world.REMOVABLE_TILE_COUNT * 2 then
		assert(debug_log("invalid world state: bad removed_tiles (" .. SAVE_STATE_REMOVED_TILES .. ") size: " .. #state[SAVE_STATE_REMOVED_TILES]))
		return false
	end
	local item_count = 0
	for i = 1, #state[SAVE_STATE_REMOVED_TILES], 2 do
		local s <const> = state[SAVE_STATE_REMOVED_TILES][i]
		if (not s) or type(s) ~= "number" or s == 0 then
			assert(debug_log("invalid world state: bad removed_tiles (" .. SAVE_STATE_REMOVED_TILES .. "): invalid packed coordinate"))
			return false
		end
		local packed_xy <const> = abs(s)
		local x <const> = packed_xy >> 9
		local y <const> = packed_xy & 0x1ff
		local m <const> = state[SAVE_STATE_REMOVED_TILES][i + 1]
		if type(m) ~= "number" then
			assert(debug_log("invalid world state: bad removed_tiles (" .. SAVE_STATE_REMOVED_TILES .. "): invalid tile"))
			return false
		end
		if not (world.metadata[y] and world.metadata[y][x]) then
			assert(debug_log("invalid world state: bad removed_tiles (" .. SAVE_STATE_REMOVED_TILES .. "): bad packed coordinate " .. s))
			return false
		end

		if (world.metadata[y][x] & COLLECTIBLE_MASK) ~= 0 and
		   (world.metadata[y][x] & REACTION_TILE) ~= 0 then
			-- For collectible tiles with reaction bits, the bits that are stored
			-- will depend on whether player removed the foreground or background
			-- tile first, so we skip checks for those bits.
			if s > 0 then
				if (world.metadata[y][x] & ~COLLECTIBLE_MASK) ~= (m & ~COLLECTIBLE_MASK) then
					assert(debug_log("invalid world state: bad removed_tiles (" .. SAVE_STATE_REMOVED_TILES .. "): bad removed foreground"))
					return false
				end
			else
				if (world.metadata[y][x] & ~REACTION_TILE) ~= (m & ~REACTION_TILE) then
					assert(debug_log("invalid world state: bad removed_tiles (" .. SAVE_STATE_REMOVED_TILES .. "): bad removed background"))
					return false
				end
			end
		else
			-- For all other tiles, the removed bits must match the original bits
			-- exactly.
			if world.metadata[y][x] ~= m then
				assert(debug_log("invalid world state: bad removed_tiles (" .. SAVE_STATE_REMOVED_TILES .. "): mismatched bits"))
				return false
			end
		end

		-- Check item count for removed background tiles with collectible
		-- bit set.
		if s < 0 and (world.metadata[y][x] & COLLECTIBLE_MASK) ~= 0 then
			item_count += 1
			if item_count > world.ITEM_COUNT then
				assert(debug_log("invalid world state: too many items collected"))
				return false
			end
		end
	end

	-- Check ball positions.
	if #state[SAVE_STATE_BALLS] ~= #world.INIT_BALLS then
		assert(debug_log("invalid world state: bad balls (" .. SAVE_STATE_BALLS .. ")"))
		return false
	end
	for i = 1, #state[SAVE_STATE_BALLS] do
		local entry <const> = state[SAVE_STATE_BALLS][i]
		if #entry ~= 2 then
			assert(debug_log("invalid world state: malformed balls (" .. SAVE_STATE_BALLS .. ")"))
			return false
		end
		local x <const> = entry[1]
		local y <const> = entry[2]
		if x < HALF_TILE_SIZE or x > world.WIDTH - HALF_TILE_SIZE or
		   y < HALF_TILE_SIZE or y > world.HEIGHT - HALF_TILE_SIZE then
			assert(debug_log("invalid world state: ball out of range"))
			return false
		end

		-- Here we could check that the ball is at a good place.  For example,
		-- the ball should not be intersecting some wall.
		--
		-- This is a bit messy to do, and it also depends on whether the ball
		-- is currently being held or not, so we just don't bother checking.
	end

	-- Check teleport station indices.
	for i = 1, #state[SAVE_STATE_TELEPORT_STATIONS] do
		local entry <const> = state[SAVE_STATE_TELEPORT_STATIONS][i]
		if entry < 1 or entry > #world.TELEPORT_POSITIONS then
			assert(debug_log("invalid world state: bad teleport_stations (" .. SAVE_STATE_TELEPORT_STATIONS .. ")"))
			return false
		end
	end

	-- Check completion time.
	if state[SAVE_STATE_COMPLETED_FRAME_COUNT] > 0 then
		if state[SAVE_STATE_COMPLETED_FRAME_COUNT] > state[SAVE_STATE_FRAME_COUNT] then
			assert(debug_log("invalid world state: completed_frame_count out of range (" .. SAVE_STATE_COMPLETED_FRAME_COUNT .. ")"))
			return false
		end
		if item_count < world.ITEM_COUNT then
			assert(debug_log("invalid world state: completed without collecting all items"))
			return false
		end
	end

	-- Check debug time.
	if state[SAVE_STATE_DEBUG_FRAME_COUNT] > state[SAVE_STATE_FRAME_COUNT] then
		assert(debug_log("invalid world state: debug_frame_count out of range (" .. SAVE_STATE_DEBUG_FRAME_COUNT .. ")"))
		return false
	end

	-- All good.
	return true
end

-- Serialize a subset of the world state into a table.
function world.encode_save_state()
	refresh_serialized_table("removed_tiles")
	refresh_serialized_table("teleport_stations")
	refresh_serialized_balls()
	assert(#world.serialized_removed_tiles == #world.removed_tiles)
	assert(#world.serialized_balls == #world.balls)
	assert(#world.serialized_teleport_stations == #world.teleport_stations)
	return
	{
		-- Mutable world data.  Note that these entries are deliberately not
		-- stored in persistent state, since we will re-derive them from
		-- world.removed_tiles:
		--
		-- - world.collected_tiles
		-- - world.broken_tiles
		-- - world.vanquished_tiles
		--
		-- Also note that we have to do this for collected_tiles for future
		-- compatibility, since the tile indices may change.
		[SAVE_STATE_REMOVED_TILES] = world.serialized_removed_tiles,
		[SAVE_STATE_FRAME_COUNT] = world.frame_count,
		[SAVE_STATE_THROW_COUNT] = world.throw_count,
		[SAVE_STATE_DROP_COUNT] = world.drop_count,
		[SAVE_STATE_UFO_COUNT] = world.ufo_count,
		[SAVE_STATE_DEBUG_FRAME_COUNT] = world.debug_frame_count,
		[SAVE_STATE_COMPLETED_FRAME_COUNT] = world.completed_frame_count,
		[SAVE_STATE_BALLS] = world.serialized_balls,
		[SAVE_STATE_TELEPORT_STATIONS] = world.serialized_teleport_stations,
		-- Viewport data.  Technically we don't need to save this since we
		-- can re-derive this from the arm positions, but the derived positions
		-- might not be exactly the same as what the player saw when the state
		-- was saved, and we will get a bit of scrolling when the game resumes.
		-- Saving and restoring viewport position helps us avoid that scrolling.
		[SAVE_STATE_SPRITE_OFFSET_X] = world.sprite_offset_x,
		[SAVE_STATE_SPRITE_OFFSET_Y] = world.sprite_offset_y,
	}
end

-- Load saved state.
--
-- Input state must not be modified after this function returns.
function world.load_saved_state(state)
	-- Load mutable states.
	world.frame_count = state[SAVE_STATE_FRAME_COUNT]
	world.debug_frame_count = state[SAVE_STATE_DEBUG_FRAME_COUNT]
	world.completed_frame_count = state[SAVE_STATE_COMPLETED_FRAME_COUNT]
	world.throw_count = state[SAVE_STATE_THROW_COUNT]
	world.drop_count = state[SAVE_STATE_DROP_COUNT]
	world.ufo_count = state[SAVE_STATE_UFO_COUNT]
	world.balls = state[SAVE_STATE_BALLS]
	world.teleport_stations = state[SAVE_STATE_TELEPORT_STATIONS]

	world.removed_tiles = state[SAVE_STATE_REMOVED_TILES]
	world.serialized_removed_tiles = table.create(world.REMOVABLE_TILE_COUNT * 2, 0)

	-- Apply patches to world tiles.
	world.collected_tiles = {}
	world.broken_tiles = 0
	world.vanquished_tiles = 0
	for i = 1, #world.removed_tiles, 2 do
		local s <const> = world.removed_tiles[i]
		local packed_xy <const> = abs(s)
		local tile_x <const> = packed_xy >> 9
		local tile_y <const> = packed_xy & 0x1ff
		-- world.removed_tiles[i + 1] would contain the metadata that was set
		-- to zero, but we don't do anything with it here, since we only need
		-- the coordinates for the tile that is being removed.

		if s > 0 then
			-- Remove foreground tiles.
			assert(tile_x >= 1)
			assert(tile_y >= 1)
			for j = 0, 3 do
				assert(tile_x <= ({world_grid_fg[j]:getSize()})[1])
				assert(tile_y <= ({world_grid_fg[j]:getSize()})[2])
				world_grid_fg[j]:setTileAtPosition(tile_x, tile_y, EMPTY_TILE)
			end

			-- If the foreground tile was removed due to chain reaction effect
			-- or terminal reaction effect, we will need to at least clear the
			-- corresponding reaction bits, and maybe also clear all collision
			-- bits if it was a breakable tile.
			if (world.metadata[tile_y][tile_x] & REACTION_TILE) ~= 0 then
				if (world.metadata[tile_y][tile_x] & BREAKABLE) ~= 0 then
					-- A breakable chain reaction foreground tile can not occlude
					-- any other tile, so we can clear all metadata bits here.
					world.metadata[tile_y][tile_x] = 0
				else
					-- A non-breakable chain reaction foreground tile may be in
					-- front of a collectible tile, so we only want to clear the
					-- chain reaction bits.
					world.metadata[tile_y][tile_x] &= ~REACTION_TILE
				end
			end

		else
			-- Removed background tile.
			if (world.metadata[tile_y][tile_x] & BREAKABLE) ~= 0 then
				-- Removed a breakable tile.
				if is_animated_background_tile(tile_x, tile_y) then
					world.vanquished_tiles += 1
				else
					world.broken_tiles += 1
				end

				-- A breakable background tile is only removed if there is no
				-- foreground tile, so we can clear all metadata bits here.
				world.metadata[tile_y][tile_x] = 0

			else
				-- Removed an collectible tile.
				assert((world.metadata[tile_y][tile_x] & COLLECTIBLE_MASK) ~= 0)
				table.insert(world.collected_tiles, world_grid_bg[0]:getTileAtPosition(tile_x, tile_y))
				world.last_item_tile_x = tile_x
				world.last_item_tile_y = tile_y

				-- It's conceivable that the player removed a collectible tile
				-- without perturbing any chain reaction tiles in the foreground,
				-- so we only want to clear the collectible bits here.
				world.metadata[tile_y][tile_x] &= ~COLLECTIBLE_MASK
			end

			-- Remove background tiles.
			assert(tile_x >= 1)
			assert(tile_y >= 1)
			for j = 0, 3 do
				assert(tile_x <= ({world_grid_bg[j]:getSize()})[1])
				assert(tile_y <= ({world_grid_bg[j]:getSize()})[2])
				world_grid_bg[j]:setTileAtPosition(tile_x, tile_y, EMPTY_TILE)
			end
		end
	end

	-- Enter endgame if we are resuming a completed game.
	world.check_victory_state()

	-- Restore viewport.
	world.sprite_offset_x = state[SAVE_STATE_SPRITE_OFFSET_X]
	world.sprite_offset_y = state[SAVE_STATE_SPRITE_OFFSET_Y]
	world.set_draw_offset()
end

-- Add functions to test endgame states.  These are only accessible in debug
-- builds.  See comments near check_endgame_backdoor() in main.lua
local function debug_enable_endgame_backdoor()
	-- Function for removing all collectible items except one.  This is used
	-- to get to near endgame state, so that player only needs to grab one
	-- more item to complete the game.
	world.test_endgame = function()
		-- No need to enable backdoor if we are already near the end.
		if #world.collected_tiles + 1 >= world.ITEM_COUNT then
			return
		end

		local cx <const> = (world.focus_max_x + world.focus_min_x) / 2
		local cy <const> = (world.focus_max_y + world.focus_min_y) / 2

		-- Get coordinates of all remaining collectible items, keeping track
		-- of the one that is nearest to current viewport center.
		local nearest_index = nil
		local nearest_distance = nil
		local points = {}
		local point_count = 0
		for y = 1, GRID_H do
			for x = 1, GRID_W do
				if (world.metadata[y][x] & COLLECTIBLE_MASK) ~= 0 then
					local world_x <const> = ((x - 1) << 5) + HALF_TILE_SIZE
					local world_y <const> = ((y - 1) << 5) + HALF_TILE_SIZE
					assert(world_x == ((x - 1) * TILE_SIZE) + HALF_TILE_SIZE)
					assert(world_y == ((y - 1) * TILE_SIZE) + HALF_TILE_SIZE)

					point_count += 1
					points[point_count] = {world_x, world_y}
					local d <const> = abs(world_x - cx) + abs(world_y - cy)
					if (not nearest_distance) or nearest_distance > d then
						nearest_distance = d
						nearest_index = point_count
					end
				end
			end
		end
		if point_count == 0 then return end

		-- Remove all items except the closest one.  We will leave the last one
		-- for the player to take.
		for i = 1, point_count do
			if i ~= nearest_index then
				world.remove_collectible_tile(points[i][1], points[i][2])
			end
		end
		debug_log("Removed " .. (point_count - 1) .. " items")
	end

	-- Function to poke all mutable tiles, activating any chain reactions
	-- associated with them and applying hits to breakable tiles.  This
	-- function is used to test memory usage needed to maintain mutable tiles.
	--
	-- Currently we need ~1MB of memory free to account for all tiles that
	-- would be removed.
	--
	-- Note that poking tiles causes chain reactions to trigger, which can
	-- take a few minutes, long enough for Playdate's auto lock feature to
	-- kick in.  Hold "down" to stop poking additional tiles after current
	-- chain reaction has completed.
	world.test_probe_all_tiles = function()
		debug_log("Poking tiles, hold \"down\" on D-pad to cancel")
		local visit_count = 0
		local poke_count = 0

		-- Poke tiles nearest to center of screen first.  This gives us a bit
		-- of control as to order of chain reactions>
		local cx <const> = (world.focus_max_x + world.focus_min_x) / 2
		local cy <const> = (world.focus_max_y + world.focus_min_y) / 2
		local tx <const>, ty <const> = get_tile_position(floor(cx), floor(cy))
		assert(tx >= 1)
		assert(tx <= GRID_W)
		assert(ty >= 1)
		assert(ty <= GRID_H)
		for d = 0, max(GRID_W, GRID_H) do
			local top_y <const> = ty - d
			if top_y >= 1 then
				for dx = -d, d do
					if playdate.buttonIsPressed(playdate.kButtonDown) then
						goto cancel_poke
					end
					local top_x <const> = tx + dx
					if top_x >= 1 and top_x <= GRID_W then
						visit_count += 1
						if (world.metadata[top_y][top_x] & MUTABLE_TILE) ~= 0 then
							update_mutable_tile(top_x, top_y)
							poke_count += 1
						end
					end
				end
			end

			local bottom_y <const> = ty + d
			if d ~= 0 and bottom_y <= GRID_H then
				for dx = -d, d do
					if playdate.buttonIsPressed(playdate.kButtonDown) then
						goto cancel_poke
					end
					local bottom_x <const> = tx + dx
					if bottom_x >= 1 and bottom_x <= GRID_W then
						visit_count += 1
						if (world.metadata[bottom_y][bottom_x] & MUTABLE_TILE) ~= 0 then
							update_mutable_tile(bottom_x, bottom_y)
							poke_count += 1
						end
					end
				end
			end

			local left_x <const> = tx - d
			if left_x >= 1 then
				for dy = -d + 1, d - 1 do
					if playdate.buttonIsPressed(playdate.kButtonDown) then
						goto cancel_poke
					end
					local left_y <const> = ty + dy
					if left_y >= 1 and left_y <= GRID_H then
						visit_count += 1
						if (world.metadata[left_y][left_x] & MUTABLE_TILE) ~= 0 then
							update_mutable_tile(left_x, left_y)
							poke_count += 1
						end
					end
				end
			end

			local right_x <const> = tx + d
			if d ~= 0 and right_x <= GRID_W then
				for dy = -d + 1, d - 1 do
					if playdate.buttonIsPressed(playdate.kButtonDown) then
						goto cancel_poke
					end
					local right_y <const> = ty + dy
					if right_y >= 1 and right_y <= GRID_H then
						visit_count += 1
						if (world.metadata[right_y][right_x] & MUTABLE_TILE) ~= 0 then
							update_mutable_tile(right_x, right_y)
							poke_count += 1
						end
					end
				end
			end
		end

		::cancel_poke::
		debug_log("Visited " .. visit_count .. " tiles, poked " .. poke_count)
	end

	return true
end
assert(debug_enable_endgame_backdoor())

-- Extra local variables.  These are intended to use up all remaining
-- available local variable slots, such that any extra variable causes
-- pdc to spit out an error.  In effect, these help us measure how many
-- local variables we are currently using.
--
-- The extra variables will be removed by ../data/strip_lua.pl
local extra_local_variable_1 <const> = 218
local extra_local_variable_2 <const> = 219
local extra_local_variable_3 <const> = 220

--}}}
