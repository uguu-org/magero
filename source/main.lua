--[[ Magero

This is a robot arm simulation game, because I just felt like cranking
Playdate's crank and thought it would be a great idea if those rotations
translated to robot arm joint movements.

--]]

import "CoreLibs/graphics"
import "CoreLibs/sprites"
import "CoreLibs/ui"

-- Print a message, and return true.  The returning true part allows this
-- function to be called inside assert(), which means this function will
-- be stripped in the release build by strip_lua.pl.
local function debug_log(msg)
	print(string.format("[%f]: %s", playdate.getElapsedTime(), msg))
	return true
end

-- Seed random number generator here before importing any of our own libraries
-- so that the libraries don't need to do their own seeding.
local random_seed = playdate.getSecondsSinceEpoch()
local title_version <const> = playdate.metadata.name .. " v" .. playdate.metadata.version
assert(debug_log(title_version .. " (debug build), random seed = " .. random_seed))
math.randomseed(random_seed)

import "arm"
import "world"
import "util"

-- Cached imported references.
local gfx <const> = playdate.graphics
local abs <const> = math.abs
local floor <const> = math.floor
local sqrt <const> = math.sqrt
local arm_encode_save_state <const> = arm.encode_save_state
local world_encode_save_state <const> = world.encode_save_state
local distance2 <const> = util.distance2
assert(arm_encode_save_state)
assert(world_encode_save_state)
assert(distance2)

----------------------------------------------------------------------
--{{{ Local functions.

-- Initialization status.
local game_initialized = false

-- If true, show list of collected items instead of the usual gameplay screen.
local item_display_mode = false

-- If true, update joint mode and crank position.  This is used to synchronize
-- game state with configuration state on menu exit.
local resync_game_state_requested = false

-- Menu image, shown when paused.
local menu_image = gfx.image.new(400, 240, gfx.kColorWhite)

-- State to be saved on next menu press.
local global_save_state = nil

-- Idle frame counter.  This starts off with a nonzero value so that
-- the help popups show up faster for first time users.
local idle_frames = 120

-- Show help popups after this many idle frames.
--
-- This is currently set at 5 seconds.  It used to be 10 seconds with a
-- fade-in effect, but I found that people don't really have the patience
-- to idle for 10 seconds, and the fade-in effect appears to flicker due
-- to poor interaction between rotated image and drawFaded.  So now the
-- help popups just appear instantly after 5 seconds of idleness.
local IDLE_HELP <const> = 150

-- Save state dictionary keys.
local SAVE_STATE_VERSION <const> = "_"
local SAVE_STATE_ARM <const> = "a"
local SAVE_STATE_WORLD <const> = "w"

-- Minimum supported build number.  This is incremented if the map is changed
-- in a backward-incompatible way.  Actual build number in the save state came
-- from buildNumber in pdxinfo, which may be greater or equal to this number.
--
-- Compatibility comes in multiple levels, and we only increment
-- MIN_SUPPORTED_BUILD if we feel there is a great risk that existing saved
-- states would be bad.
--
-- 1. Graphical changes are always compatible.
--
--    Assuming that all tiles remained in the same place, we don't increment
--    MIN_SUPPORTED_BUILD for graphical changes.
--
-- 2. Movements of items and teleport stations may be compatible.
--
--    Collectible item movements are fine if player hasn't collected the
--    affected items yet.  If they did, the inconsistent state would be
--    flagged by world.is_valid_save_state().  We don't increment
--    MIN_SUPPORTED_BUILD since there is a chance that existing state is
--    still usable, and we can detect unusable states.
--
--    Teleport station movements are fine if the order of the teleport
--    stations are preserved.  This means horizontal movements are generally
--    fine, but vertical movements require a bit of care.  We don't increment
--    MIN_SUPPORTED_BUILD if we can preserve teleport station order.
--
-- 3. All remaining changes are incompatible.
--
--    These include ball movements and metadata changes, due to potential
--    conflicts with existing saved positions.  We always increment
--    MIN_SUPPORTED_BUILD for these changes.
--
--    Note that we always check for incompatible collision layer changes at
--    startup, but that's more for our development use.  We can't rely on
--    this for production because there is a chance that player becomes
--    stranded in a place that became unreachable (e.g. a place that has
--    gained new access requirements).
--
-- The plan is to have a completed and stable map in the very first release,
-- so we never have to increment MIN_SUPPORTED_BUILD except for minor bug
-- fixes.  But we never know if we have to make a breaking change or not.
-- MIN_SUPPORTED_BUILD is meant to defend against player being left in an
-- undefined state.
local MIN_SUPPORTED_BUILD <const> = 1

-- Images for show_help.
local help_bg1_image = nil
local help_bg2_image = nil
local help_dpad_image = nil
local help_crank_tiles = nil

-- Popup world coordinates.
local help_bottom_x = nil
local help_bottom_y = nil
local help_elbow_x = nil
local help_elbow_y = nil
local help_top_x = nil
local help_top_y = nil
local help_action_x = nil
local help_action_y = nil

-- Slide offset for menu animation, for use with setMenuImage.  Setting this
-- to a positive value causes the menu to slide in, which is kind of neat,
-- but because the background image appears to be sliding as well, it's
-- somewhat disorientating, so we have it disabled.
local MENU_SLIDE_OFFSET <const> = 50

-- Horizontal offset of menu texts.
local MENU_TEXT_X <const> = MENU_SLIDE_OFFSET + 4

-- Forward declaration, needed by hint_mode.
local hide_help

-- System menu control.  Menu items are added from top to bottom, but they
-- are accessed from bottom to top, because initial cursor position is just
-- below the custom menu options (with "volume" selected), so we want to
-- add the "reset" command first and "flex" option last to make the
-- "flex" option more accessible.
playdate.getSystemMenu():addMenuItem("reset", function()
	world.reset_requested = true
end)

local hint_mode = playdate.getSystemMenu():addOptionsMenuItem(
	"hints", arm.HINT_MODES, arm.HINT_MODES[arm.HINT_BASIC], function(new_mode)
	for i = 1, #arm.HINT_MODES do
		if new_mode == arm.HINT_MODES[i] then
			arm.hint_mode = i
		end
	end

	hide_help()
end)

local joint_mode = playdate.getSystemMenu():addOptionsMenuItem(
	"flex", arm.JOINT_MODES, arm.JOINT_MODES[arm.JOINT_PPP], function()
	resync_game_state_requested = true
end)

-- Update joint mode based on menu option, and resynchronize joint deltas.
local function resync_game_state()
	assert(resync_game_state_requested)
	resync_game_state_requested = false

	local new_joint_mode <const> = joint_mode:getValue()
	for i = 1, #arm.JOINT_MODES do
		if new_joint_mode == arm.JOINT_MODES[i] then
			if arm.joint_mode ~= i then
				-- If joint mode changed, show help pop immediately to let player
				-- know what the new rotation directions are.
				idle_frames += IDLE_HELP
				arm.joint_mode = i
			end
			break
		end
	end
	arm.update_joints(false, false, false)
end

-- Encode current game state to "global_save_state" global variable.
--
-- Note that this just save a copy of the game state to memory, but doesn't
-- write it to disk.  The writing happens only when game is paused, so that
-- we are not writing to disk continuously.
local function prepare_save_state()
	global_save_state =
	{
		[SAVE_STATE_VERSION] =
		{
			version = title_version,
			build = tonumber(playdate.metadata.buildNumber),
		},
		[SAVE_STATE_ARM] = arm_encode_save_state(),
		[SAVE_STATE_WORLD] = world_encode_save_state(),
	}
end

-- Quick compatibility check.
local function is_compatible_state(version_state)
	local SCHEMA <const> =
	{
		build = "uint",
	}
	if not util.validate_state(SCHEMA, version_state) then
		assert(debug_log("invalid version state: mismatched schema"))
		return false
	end
	if version_state.build < MIN_SUPPORTED_BUILD then
		assert(debug_log("invalid version state: incompatible build"))
		return false
	end
	return true
end

-- Load previously saved state from disk.
local function load_state()
	assert(debug_log("Checking saved state"))
	local old_state <const> = playdate.datastore.read()
	if old_state and
	   is_compatible_state(old_state[SAVE_STATE_VERSION]) and
	   arm.is_valid_save_state(old_state[SAVE_STATE_ARM]) and
	   world.is_valid_save_state(old_state[SAVE_STATE_WORLD]) then
		assert(debug_log("Loading saved state"))
		-- Load world state before loading arm state, so that arm state loader
		-- can recompute the points of interests properly with the updated world.
		world.load_saved_state(old_state[SAVE_STATE_WORLD])
		if arm.load_saved_state(old_state[SAVE_STATE_ARM]) then
			assert(debug_log("Loaded saved state"))
		else
			assert(debug_log("Ignored unusable save state"))

			-- Force a reset to discard the partially loaded state.
			-- Not the smoothest experience here, but better than leaving
			-- the user stuck in a broken state.
			world.reset_requested = true
		end

		-- Update mode options from loaded state.
		hint_mode:setValue(arm.HINT_MODES[arm.hint_mode])
		joint_mode:setValue(arm.JOINT_MODES[arm.joint_mode])
	end
end

-- Called by gameWillPause and deviceWillSleep hooks to save state on exit.
local function save_state_on_exit()
	if global_save_state then
		playdate.datastore.write(global_save_state)
		assert(debug_log("Saved state"))
	end
end

-- If we are in debug build and we are running on the simulator, override
-- save_state_on_exit to be no-op.
--
-- We do this because we want to make state saving explicit instead of
-- automatic when debugging, since it makes it easier to re-run a scenario
-- just by reloading.
local function disable_automatic_saves_for_debug()
	if playdate.isSimulator then
		save_state_on_exit = function() end
	end
	return true
end
assert(disable_automatic_saves_for_debug())

-- Check placement of a single point.
local function test_placement(x, y, candidate, target_points, target_index, placements)
	x -= world.sprite_offset_x
	y -= world.sprite_offset_y

	-- Reject point if it's too close to any of the targets, including the
	-- one we are attaching the help popup to.
	local target_d2
	for i = 1, #target_points do
		local d2 <const> = distance2(target_points[i][1] - x, target_points[i][2] - y)
		if d2 < 80 * 80 then
			return
		end
		if i == target_index then
			target_d2 = d2
		end
	end

	-- Reject point if it's too close to other popups.
	for i = 1, #target_points do
		if placements[i] and
		   abs(placements[i][1] - x) < 72 and abs(placements[i][2] - y) < 40 then
			return
		end
	end

	-- Accept point if we don't have a placement yet, or if current distance
	-- is smaller than candidate distance.
	if (not candidate.d2) or target_d2 < candidate.d2 then
		candidate.x = x
		candidate.y = y
		candidate.d2 = target_d2
	end
end

-- Assign placements to a group of points.
local function assign_placement_with_permutation(target_points, permutation)
	local MIN_X <const> = 40
	local MIN_Y <const> = 24
	local MAX_X <const> = 400 - MIN_X
	local MAX_Y <const> = 240 - MIN_Y
	local STEP <const> = 8
	assert((MAX_X - MIN_X) % STEP == 0)
	assert((MAX_Y - MIN_Y) % STEP == 0)

	-- Pre-allocate placement table.
	local placements = {}
	for i = 1, #target_points do
		table.insert(placements, nil)
	end

	local total_d2 = 0
	for i = 1, #target_points do
		local index <const> = permutation[i]
		local candidate = {}

		-- Look for candidate points around the edge of screen.
		for x = MIN_X, MAX_X, STEP do
			test_placement(x, MIN_Y, candidate, target_points, index, placements)
		end
		for y = MIN_Y + STEP, MAX_Y - STEP, STEP do
			test_placement(MAX_X, y, candidate, target_points, index, placements)
		end
		for x = MAX_X, MIN_X, -STEP do
			test_placement(x, MAX_Y, candidate, target_points, index, placements)
		end
		for y = MAX_Y - STEP, MIN_Y + STEP, -STEP do
			test_placement(MIN_X, y, candidate, target_points, index, placements)
		end
		assert(candidate.x)
		assert(candidate.y)
		placements[index] = {candidate.x, candidate.y}
		total_d2 += candidate.d2
	end
	return total_d2, placements
end

-- Assign placements, trying different order to see if we can minimize distance.
local function assign_placements(target_points)
	local permutation
	if #target_points == 3 then
		permutation =
		{
			{1, 2, 3}, {1, 3, 2},
			{2, 1, 3}, {2, 3, 1},
			{3, 1, 2}, {3, 2, 1},
		}
	else
		assert(#target_points == 4)
		permutation =
		{
			-- These permutations are intentionally omitted:
			-- {1, 2, 3, 4}, {1, 2, 4, 3},
			-- {1, 3, 2, 4}, {1, 3, 4, 2},
			-- {1, 4, 2, 3}, {1, 4, 3, 2},
			-- {2, 1, 3, 4}, {2, 1, 4, 3},
			-- {2, 3, 1, 4}, {2, 3, 4, 1},
			-- {2, 4, 1, 3}, {2, 4, 3, 1},
			-- {3, 1, 2, 4}, {3, 1, 4, 2},
			-- {3, 2, 1, 4}, {3, 2, 4, 1},
			-- {3, 4, 1, 2}, {3, 4, 2, 1},

			-- This is the only subset of permutations we test, which gives
			-- priority placement to action target first.  This also reduces
			-- time needed to place help popups.
			{4, 1, 2, 3}, {4, 1, 3, 2},
			{4, 2, 1, 3}, {4, 2, 3, 1},
			{4, 3, 1, 2}, {4, 3, 2, 1},
		}
	end

	local best_d2 = nil
	local best_placement = nil
	for i = 1, #permutation do
		local d2 <const>, placements <const> = assign_placement_with_permutation(target_points, permutation[i])
		if (not best_d2) or d2 < best_d2 then
			best_d2 = d2
			best_placement = placements
		end
	end
	assert(best_placement)
	return best_placement
end

-- Draw arrow from (ax, ay) to (bx, by).
local function draw_arrow(ax, ay, bx, by)
	-- Here we can achieve a funky effect by adding some random jitter to
	-- target coordinates:
	--
	--   bx += math.random(-1, 1)
	--   by += math.random(-1, 1)
	--
	-- It's kind of neat for the first few seconds, but gets annoying after
	-- a while, so we are not doing that anymore.
	local dx <const> = bx - ax
	local dy <const> = by - ay
	local d = sqrt(dx * dx + dy * dy)
	if d <= 1 then return end

	-- Compute arrow vertices.
	local s <const> = 4 / d
	local mx <const> = dx * s
	local my <const> = dy * s
	local sx <const> = -dy * s
	local sy <const> = dx * s

	-- Draw thick white outline.
	gfx.setLineWidth(6)
	gfx.setColor(gfx.kColorWhite)
	gfx.drawLine(ax, ay, bx, by)
	gfx.drawLine(bx, by, bx - mx + sx, by - my + sy)
	gfx.drawLine(bx, by, bx - mx - sx, by - my - sy)
	gfx.drawCircleAtPoint(bx, by, 0)
	gfx.drawCircleAtPoint(bx - mx + sx, by - my + sy, 0)
	gfx.drawCircleAtPoint(bx - mx - sx, by - my - sy, 0)

	-- Draw thin black center line.
	gfx.setLineWidth(2)
	gfx.setColor(gfx.kColorBlack)
	gfx.drawLine(ax, ay, bx, by)
	gfx.drawLine(bx, by, bx - mx + sx, by - my + sy)
	gfx.drawLine(bx, by, bx - mx - sx, by - my - sy)
	gfx.drawCircleAtPoint(bx, by, 0)
end

-- Draw spinning crank image at a particular world coordinate.
local function draw_crank(x, y, crank_flip)
	local crank_frame <const> = idle_frames % 32

	-- We have 8 frames that accounts for a quarter of the rotations.  For
	-- the remaining frames, we rotate the whole sprite.
	--
	-- Note that this part calls util.rotated_image on each frame, which would
	-- cause lots of allocations to happen.  When simulator is running with
	-- memory pool enabled, these allocations will eventually fill up the
	-- memory log, causing the simulator to slow down.  We can reduce the
	-- number of allocations here by caching, but we are not doing that because
	-- the expectation is that most users aren't going to idly watch the help
	-- popups spin.
	--
	-- Also, this slowdown appears to be a simulator-only problem, there is no
	-- leak in this code as far as I can tell.  By the way, this also means
	-- that for regular non-debugging use of the simulator, you will probably
	-- want to have malloc pool disabled to avoid memory leaks there.
	if crank_frame < 8 then
		util.rotated_image(help_crank_tiles:getImage(crank_frame + 1), 0):draw(x - 16, y - 16, crank_flip)
	elseif crank_frame < 16 then
		util.rotated_image(help_crank_tiles:getImage(crank_frame - 7), 90):draw(x - 16, y - 16, crank_flip)
	elseif crank_frame < 24 then
		util.rotated_image(help_crank_tiles:getImage(crank_frame - 15), 180):draw(x - 16, y - 16, crank_flip)
	else
		util.rotated_image(help_crank_tiles:getImage(crank_frame - 23), -90):draw(x - 16, y - 16, crank_flip)
	end
end

-- Draw 1x1 help popup background centered at a particular world coordinate.
local function draw_help_bg1(x, y)
	help_bg1_image:drawCentered(x, y, gfx.kImageUnflipped)
end

-- Draw 2x1 help popup background centered at a particular world coordinate.
local function draw_help_bg2(x, y)
	help_bg2_image:draw(x - 32, y - 16, gfx.kImageUnflipped)
end

-- Draw crank help image at a particular world coordinate.
local function draw_crank_help_with_dpad(help_x, help_y, target_x, target_y, dpad_rotate, crank_flip)
	draw_arrow(help_x, help_y, target_x, target_y)
	draw_help_bg2(help_x, help_y)
	util.rotated_image(help_dpad_image, dpad_rotate):draw(help_x - 32, help_y - 16)
	draw_crank(help_x + 16, help_y, crank_flip)
end

-- Draw crank help image at a particular world coordinate, without D-Pad
-- illustration.  This is used when a ball is held.
local function draw_crank_help_without_dpad(help_x, help_y, target_x, target_y, crank_flip)
	draw_arrow(help_x, help_y, target_x, target_y)
	draw_help_bg1(help_x, help_y)
	draw_crank(help_x, help_y, crank_flip)
end

-- Wrapper to select which crank help popup to show.
local function draw_crank_help(bottom, help_x, help_y, target_x, target_y, dpad_rotate, crank_flip)
	if arm.hold > 0 then
		if arm.bottom_attached == bottom then
			draw_crank_help_with_dpad(help_x, help_y, target_x, target_y, dpad_rotate, crank_flip)
		else
			draw_crank_help_without_dpad(help_x, help_y, target_x, target_y, crank_flip)
		end
	else
		draw_crank_help_with_dpad(help_x, help_y, target_x, target_y, dpad_rotate, crank_flip)
	end
end

-- Draw action help image at a particular world coordinate.
local function draw_action_help(help_x, help_y, target_x, target_y)
	draw_arrow(help_x, help_y, target_x, target_y)
	draw_help_bg1(help_x, help_y)
	help_dpad_image:drawCentered(help_x, help_y, gfx.kImageFlippedY)
end

-- Draw help popups.
local function show_help()
	-- Assign coordinates to popups if they had not been assigned yet.
	if not help_bottom_x then
		local target_points =
		{
			{arm.bottom.wrist_x, arm.bottom.wrist_y},
			{arm.elbow_x, arm.elbow_y},
			{arm.top.wrist_x, arm.top.wrist_y},
		}
		if arm.action_target then
			table.insert(target_points, {arm.action_target.x, arm.action_target.y})
		elseif arm.hold > 0 then
			local ball <const> = world.balls[arm.hold]
			table.insert(target_points, {ball[1], ball[2]})
		end
		local placements <const> = assign_placements(target_points)

		help_bottom_x = placements[1][1]
		help_bottom_y = placements[1][2]
		help_elbow_x = placements[2][1]
		help_elbow_y = placements[2][2]
		help_top_x = placements[3][1]
		help_top_y = placements[3][2]
		if #placements == 4 then
			help_action_x = placements[4][1]
			help_action_y = placements[4][2]
		else
			help_action_x = nil
			help_action_y = nil
		end
	end

	-- Draw extra arrows for weird flex modes.
	assert(help_elbow_x)
	assert(help_elbow_y)
	if arm.joint_mode == arm.JOINT_W_P or arm.joint_mode == arm.JOINT_W_N then
		if arm.hold > 0 then
			if arm.bottom_attached then
				draw_arrow(help_bottom_x, help_bottom_y, arm.elbow_x, arm.elbow_y)
			else
				draw_arrow(help_top_x, help_top_y, arm.elbow_x, arm.elbow_y)
			end
		else
			draw_arrow(help_bottom_x, help_bottom_y, arm.elbow_x, arm.elbow_y)
			draw_arrow(help_top_x, help_top_y, arm.elbow_x, arm.elbow_y)
		end
	end

	-- Draw arrows and popups for wrist joints.
	assert(help_bottom_x)
	assert(help_bottom_y)
	assert(help_top_x)
	assert(help_top_y)
	if arm.joint_mode == arm.JOINT_PPP or
	   arm.joint_mode == arm.JOINT_PNP or
	   arm.joint_mode == arm.JOINT_W_P then
		draw_crank_help(true, help_bottom_x, help_bottom_y,
		                arm.bottom.wrist_x, arm.bottom.wrist_y,
		                -90, gfx.kImageUnflipped)
		draw_crank_help(false, help_top_x, help_top_y,
		                arm.top.wrist_x, arm.top.wrist_y,
		                90, gfx.kImageUnflipped)
	else
		draw_crank_help(true, help_bottom_x, help_bottom_y,
		                arm.bottom.wrist_x, arm.bottom.wrist_y,
		                -90, gfx.kImageFlippedX)
		draw_crank_help(false, help_top_x, help_top_y,
		                arm.top.wrist_x, arm.top.wrist_y,
		                90, gfx.kImageFlippedX)
	end

	-- Draw arrow and popup for elbow joint.
	assert(help_elbow_x)
	assert(help_elbow_y)
	if arm.joint_mode == arm.JOINT_PPP or
	   arm.joint_mode == arm.JOINT_NPN or  -- NPN here, opposite of PNP above.
	   arm.joint_mode == arm.JOINT_W_P then
		draw_crank_help_with_dpad(help_elbow_x, help_elbow_y,
		                          arm.elbow_x, arm.elbow_y,
		                          0, gfx.kImageUnflipped)
	else
		draw_crank_help_with_dpad(help_elbow_x, help_elbow_y,
		                          arm.elbow_x, arm.elbow_y,
		                          0, gfx.kImageFlippedX)
	end

	if arm.action_target then
		-- Extra arrow and popup for actionable target location.
		assert(help_action_x)
		assert(help_action_y)
		local target_x <const> = arm.action_target.x
		local target_y <const> = arm.action_target.y
		draw_action_help(help_action_x, help_action_y, target_x, target_y)
	elseif arm.hold > 0 then
		-- Extra arrow and popup for releasing ball.
		assert(help_action_x)
		assert(help_action_y)
		local target_x <const> = world.balls[arm.hold][1]
		local target_y <const> = world.balls[arm.hold][2]
		draw_action_help(help_action_x, help_action_y, target_x, target_y)
	end
end

-- Reset help display.
hide_help = function()
	idle_frames = 0
	help_bottom_x = nil
	help_bottom_y = nil
	help_elbow_x = nil
	help_elbow_y = nil
	help_top_x = nil
	help_top_y = nil
	help_action_x = nil
	help_action_y = nil
end

-- Key sequence to match for enabling debug mode.
--
-- To enable debug mode, enter the sequence below within 2 seconds.
--
-- Debug mode can not be activated while game is paused (while menu is
-- visible), or when item list is visible.  We are not checking for button
-- presses during those times.
--
-- Debug mode can not be activated while holding a ball.  We don't do anything
-- extra to prevent it, but because "down" is part of the key sequence, the
-- ball will naturally be dropped when attempting to enter the sequence, and
-- the sequence will be broken due to arm.execute_action.  This is working as
-- intended since it avoids throwing balls in places where they are not meant
-- to be thrown.
local BACKDOOR_KEYS <const> =
{
	playdate.kButtonUp,
	playdate.kButtonUp,
	playdate.kButtonDown,
	playdate.kButtonDown,
	playdate.kButtonLeft,
	playdate.kButtonRight,
	playdate.kButtonLeft,
	playdate.kButtonRight,
}

-- Debug mode matching state.
local backdoor_cursor = 1

-- Timestamp for first button press in key sequence.  If user can not complete
-- the key sequence in limited time, we will reset matching state so that they
-- will need to re-enter the sequence from the beginning.
local backdoor_sequence_start = nil

-- True if debug mode is enabled.
--
-- Debug mode operations:
-- + Use D-Pad to position arm.
-- + Use crank to adjust movement speed.
-- + Press "A" to commit to new position and exit debug mode.
-- + Press "B" to exit debug mode without committing to new position.
local debug_mode = false

-- Arm elbow coordinates at the start of debug mode.  This is for rolling back
-- the debug arm position if user exited debug mode with "B" button.
local debug_rollback_x = nil
local debug_rollback_y = nil

-- Check for backdoor access.  These are only available in debug builds.
--
-- To enter endgame mode (without playing the game normally, that is):
-- 1. Enable debug backdoor at least once.  It would be best to place the
--    arm at some place where you can see two items on the screen, such as
--    the area near (6032,4784).
-- 2. Press and hold A.  This causes item list to show up.
-- 3. Still holding A, press and hold B.  This dismisses the item list,
--    and now both A+B are held.
-- 4. Wait ~10 seconds.  If the arm is placed at an area with two items
--    visible, one of those items will disappear.  If console is connected,
--    a message will be logged to say the number of items removed.
-- 5. Manually take the last item to enter endgame.
--
-- Since most of this game is about exploring the map to collect everything
-- up to and including the final item, this backdoor greatly spoils the game,
-- so we only enable it for debug builds.
--
-- Backdoor to probe all tiles is similar, except Up+A+B need to be held for
-- ~10 seconds, instead of just A+B.
local function check_endgame_backdoor()
	-- Player must have enabled regular backdoor at least once during the
	-- current session for the endgame backdoor to be enabled.
	if not world.endgame_backdoor_watermark then
		world.endgame_backdoor_watermark = world.debug_frame_count
	end
	if world.debug_frame_count <= world.endgame_backdoor_watermark then
		return true
	end

	-- Time how long both A and B buttons were held.
	if playdate.buttonIsPressed(playdate.kButtonA) and
	   playdate.buttonIsPressed(playdate.kButtonB) then
		if not world.endgame_backdoor_timer then
			world.endgame_backdoor_timer = 1
		else
			-- Trigger backdoor after both A+B have been held for 9 seconds.
			-- 10 seconds would have been a nice round number, but because
			-- we are often just below 30fps in debug mode, it's hard to tell
			-- whether we have successfully triggered backdoor or not, and we
			-- end up needing to hold the buttons for longer.  By setting the
			-- threshold to 9 seconds here, holding A+B buttons for 10 seconds
			-- will usually be good enough.
			world.endgame_backdoor_timer += 1
			if world.endgame_backdoor_timer % 30 == 0 then
				debug_log((270 - world.endgame_backdoor_timer) // 30 .. "...")
			end
			if world.endgame_backdoor_timer > 270 then
				if playdate.buttonIsPressed(playdate.kButtonUp) then
					world.test_probe_all_tiles()
				else
					world.test_endgame()
				end

				-- Reset timer to avoid it from being triggered repeatedly.
				world.endgame_backdoor_timer = 0
			end
		end
	else
		world.endgame_backdoor_timer = 0
	end
	return true
end

-- Reset backdoor timer upon reset request.
--
-- This is needed, otherwise endgame_backdoor_timer will preserve the value
-- from previous run, and player will need to reload the game to be able
-- to use the backdoor again.
--
-- This also means that after a reset, player must enter debug mode at least
-- once to activate endgame backdoor.
local function reset_backdoor_timer()
	world.endgame_backdoor_watermark = nil
	return true
end

-- Check for backdoor access.
local function check_debug_sequence()
	-- Backdoor key sequence is matched on button release rather than button
	-- press.
	--
	-- If we were matching the key sequence on button presses instead of
	-- releases, we would see a minor jolt right after entering debug mode
	-- because the last key in the sequence is still considered pressed
	-- (because button press and release don't happen in the same frame),
	-- and thus arm will experience a movement immediately upon entering
	-- debug mode.  By matching the key sequence on button releases, we would
	-- enter debug mode with all buttons released, and won't see that jolt.
	if playdate.buttonJustReleased(BACKDOOR_KEYS[backdoor_cursor]) then
		-- Matched a key in expected key sequence.
		if backdoor_cursor == 1 then
			-- Started new key sequence.
			backdoor_sequence_start = playdate.getElapsedTime()
			backdoor_cursor += 1
			return
		end

		-- Continuing key sequence.  Stop matching if player took too long.
		assert(backdoor_sequence_start)
		if playdate.getElapsedTime() - backdoor_sequence_start <= 2 then
			backdoor_cursor += 1
			if backdoor_cursor <= #BACKDOOR_KEYS then
				return
			end

			-- Matched all keys, enable debug mode.
			assert(debug_log("Enter debug mode"))
			debug_mode = true

			-- Save current elbow position for rollback.
			debug_rollback_x = arm.elbow_x
			debug_rollback_y = arm.elbow_y

			-- Fallthrough to reset matcher.
		end

		backdoor_cursor = 1
		backdoor_sequence_start = nil

	else
		-- Did not match a key in expected sequence.  If there were any other
		-- button release, it was an incorrect key, and we will reset the
		-- matcher to match start of sequence.
		--
		-- If there were no other button releases then we do nothing.
		if playdate.buttonJustReleased(playdate.kButtonUp) or
		   playdate.buttonJustReleased(playdate.kButtonDown) or
		   playdate.buttonJustReleased(playdate.kButtonLeft) or
		   playdate.buttonJustReleased(playdate.kButtonRight) or
		   playdate.buttonJustReleased(playdate.kButtonA) or
		   playdate.buttonJustReleased(playdate.kButtonB) then
			backdoor_cursor = 1
			backdoor_sequence_start = nil
		end
	end

	-- Check for endgame backdoor.  This is wrapped inside an assert()
	-- so that it's stripped in release builds.
	assert(check_endgame_backdoor())
end

-- Draw elbow coordinate in bottom left corner of the screen.
local function draw_arm_coordinate()
	local width <const>, height <const> = gfx.getTextSize("8888,")

	gfx.pushContext()
	gfx.setDrawOffset(0, 0)
	gfx.setColor(gfx.kColorWhite)
	gfx.fillRect(0, 238 - height, width * 2 + 2, 240)
	gfx.drawTextAligned(string.format("%d,", arm.elbow_x), width, 240 - height, kTextAlignment.right)
	gfx.drawTextAligned(string.format("%d", arm.elbow_y), width * 2, 240 - height, kTextAlignment.right)
	gfx.popContext()
end

-- Format frame counts as a duration string.
local function format_duration(frame_count)
	-- Cap the time duration at 100 hours minus one second.
	local total_seconds <const> = floor(frame_count / 30)
	if total_seconds >= 100 * 60 * 60 - 1 then
		return "99:59:59"
	end

	local seconds <const> = total_seconds % 60
	local minutes <const> = (total_seconds // 60) % 60
	local hours <const> = total_seconds // (60 * 60)

	-- Format time as HH:MM:SS if duration is one hour or more.
	if hours > 0 then
		return string.format("%d:%02d:%02d", hours, minutes, seconds)
	end
	return string.format("%d:%02d", minutes, seconds)
end
assert(format_duration(0) == "0:00")
assert(format_duration(30) == "0:01")
assert(format_duration(15) == "0:00")
assert(format_duration(59 * 30) == "0:59")
assert(format_duration(59 * 30 + 15) == "0:59")
assert(format_duration(60 * 30) == "1:00")
assert(format_duration(60 * 30 + 15) == "1:00")
assert(format_duration(61 * 30 + 15) == "1:01")
assert(format_duration(119 * 30 + 15) == "1:59")
assert(format_duration(120 * 30 + 15) == "2:00")
assert(format_duration(1200 * 30) == "20:00")
assert(format_duration(3599 * 30) == "59:59")
assert(format_duration(3600 * 30) == "1:00:00")
assert(format_duration(99 * 3600 * 30) == "99:00:00")
assert(format_duration(100 * 3600 * 30) == "99:59:59")

-- Draw a pair of text items for paused menu.
local function draw_menu_stat(key, value, y)
	gfx.drawText("*" .. key .. "*", MENU_TEXT_X, y)
	gfx.drawTextAligned(value, MENU_TEXT_X + 186, y, kTextAlignment.right)
end

-- Draw in-game stats for pause screen, returning Y coordinate of last
-- drawn bit of text.
local function draw_game_stats()
	-- We have up to 11 items to display, in this order:
	-- 1. Completion time
	-- 2. Elapsed time
	-- 3. Debug time
	-- (optional spacer)
	-- 4. Painted
	-- 5. Collected
	-- 6. Vanquished
	-- 7. Broken
	-- 8. Thrown
	-- 9. Dropped
	-- 10. Encountered
	-- 11. Steps
	--
	-- "Debug time" would be hidden in normal game play, so usually 10 items.
	-- A vertical spacing of 22 pixels plus 10 pixel spacer will work.
	local dy = 22
	local spacer = 10
	if world.completed_frame_count > 0 and
	   world.debug_frame_count > 0 and
	   world.paint_count > 0 and
	   #world.collected_tiles > 0 and
	   world.vanquished_tiles > 0 and
	   world.broken_tiles > 0 and
	   world.throw_count > 0 and
	   world.drop_count > 0 and
	   world.ufo_count > 0 then
		assert(world.frame_count > 0)
		assert(arm.step_count > 0)
		-- We need to display all 11 items.  Adjust spacing accordingly.
		dy = 21
		spacer = 3
	end

	local y = 4
	if world.completed_frame_count > 0 then
		draw_menu_stat("Completion time", format_duration(world.completed_frame_count), y)
		y += dy
	end
	draw_menu_stat("Elapsed time", format_duration(world.frame_count), y)
	y += dy
	if world.debug_frame_count > 0 then
		draw_menu_stat("Debug time", format_duration(world.debug_frame_count), y)
		y += dy
	end

	-- Add a bit of vertical space, then show count stats.
	y += spacer
	if world.paint_count > 0 then
		draw_menu_stat("Painted", world.paint_count, y)
		y += dy
	end
	if #world.collected_tiles > 0 then
		draw_menu_stat("Collected", #world.collected_tiles, y)
		y += dy
	end
	if world.vanquished_tiles > 0 then
		draw_menu_stat("Vanquished", world.vanquished_tiles, y)
		y += dy
	end
	if world.broken_tiles > 0 then
		draw_menu_stat("Broken", world.broken_tiles, y)
		y += dy
	end
	if world.throw_count > 0 then
		draw_menu_stat("Thrown", world.throw_count, y)
		y += dy
	end
	if world.drop_count > 0 then
		draw_menu_stat("Dropped", world.drop_count, y)
		y += dy
	end
	if world.ufo_count > 0 then
		draw_menu_stat("Encountered", world.ufo_count, y)
		y += dy
	end
	if arm.step_count > 0 then
		draw_menu_stat("Steps", arm.step_count, y)
		y += dy
	end

	return y
end

-- Draw version string and contact information, but only if we have room to
-- show both.
local function draw_game_info(y)
	if y <= 190 then
		gfx.drawText(playdate.metadata.name .. " v" .. playdate.metadata.version, MENU_TEXT_X, 198)
		gfx.drawText("omoikane@uguu.org", MENU_TEXT_X, 220)
	end
end

-- Helper for drawing joint position as a cross.
local function draw_cross(x, y)
	if x and y then
		gfx.setLineWidth(1)
		gfx.drawLine(x - 3, y, x + 3, y)
		gfx.drawLine(x, y - 3, x, y + 3)
	end
end

-- Draw frame rate in debug builds.
local function debug_frame_rate()
	playdate.drawFPS(4, 220)
	return true
end

-- Draw various positions in debug builds.  Stripped in release builds.
--
-- Note that we are more careful about checking everything being not nil
-- before using them, since debugDraw may be called at a time when some of
-- the values had not been initialized yet.
local function draw_debug_positions()
	if arm and arm.elbow_x and arm.elbow_y and arm.bottom then
		draw_cross(arm.elbow_x, arm.elbow_y)
		draw_cross(arm.bottom.wrist_x, arm.bottom.wrist_y)
		draw_cross(arm.bottom.hand_x, arm.bottom.hand_y)
		draw_cross(arm.top.wrist_x, arm.top.wrist_y)
		draw_cross(arm.top.hand_x, arm.top.hand_y)
	end
	if world and world.balls then
		for i = 1, #world.balls do
			if world.balls[i] then
				draw_cross(world.balls[i][1], world.balls[i][2])
			end
		end

		if world.follow_ball and world.follow_ball > 0 and
		   world.ball_position_history and world.ball_history_index then
			gfx.setLineWidth(1)
			local x0 = nil
			local y0 = nil
			for i = -31, -1 do
				local h <const> = (world.ball_history_index + i) & world.BALL_HISTORY_MASK
				if world.ball_position_history[h] then
					local x1 <const> = world.ball_position_history[h][1]
					local y1 <const> = world.ball_position_history[h][2]
					if x0 and y0 and x1 and y1 then
						gfx.drawLine(x0, y0, x1, y1)
					end
					x0 = x1
					y0 = y1
				end
			end
		end
	end
	return true
end

-- Override the debugDraw function for debug builds.  Stripped in release
-- builds.  This is done as an assignment rather than a function (unlike
-- what we did with playdate.update), so that we don't leave behind an
-- empty playdate.debugDraw function in release builds.
--
-- If we don't override debugDraw, button presses for buttonJustPressed
-- will be buffered, which is kind of handy if we want to summon a ball
-- and pick it up right away.  That buffering doesn't work when debugDraw
-- is overridden, which makes certain testing less convenient.  But honestly
-- that's not the worst part -- the worst thing about overriding debugDraw is
-- that instead of a stacktrace and a pause on assertion failures, we tend to
-- see a runtime failure in the simulator itself that looks like this:
--
--    Assertion failed!
--
--    Program: ...ne\Documents\PlaydateSDK\bin\PlaydateSimulator.exe
--    File: C:\GitLab-Runner\ci-builds\HeHsk-Bm\0\playda...\ldebug.c
--    Line: 782
--
--    Expression: (((((((&(errfunc)->val))->tt_)) & 0x0F)) == (6))
--
-- This is why we commented out the "assert(override_debug_draw())" below.
-- It's a real shame, the effect is rather neat.
--
-- To reproduce the simulator crash:
-- 0. Enable debug drawing in simulator: View -> Enable Debug Drawing
-- 1. Uncomment the assert below to override debugDraw.
-- 2. Edit world.lua and make check_for_unexpected_stop return false right
--    after dump_ball_history.
-- 3. Throw the ball that's located at (5328,1168) left.
--
-- The ball at (5328,1168) has a high probably of getting in the valley at
-- (4960,2520), and step #2 will cause move_ball to trip over an assertion
-- failure.  The simulator crash was still reproducible as of SDK 2.2.0
local function override_debug_draw()
	playdate.debugDraw = draw_debug_positions
	return true
end
-- assert(override_debug_draw())

--}}}

----------------------------------------------------------------------
--{{{ Playdate callbacks.

function playdate.update()
	-- Initialize all sprites in steps in the first few calls to update(),
	-- showing progress status between each step.
	--
	-- We can't initialize all the sprites at once before the first update
	-- because it takes too long, and playdate will declare that the game
	-- have crashed.  This thread says the watchdog limit is 10 seconds:
	-- https://devforum.play.date/t/is-there-a-limit-on-how-long-the-update-callback-can-run-for-edit-yes-10-seconds/9021
	if not game_initialized then
		gfx.clear()
		world.show_loading_progress(0, 19)
		coroutine.yield()

		-- Initialize UI sprites.
		help_bg1_image = gfx.image.new("images/help_bg1")
		help_bg2_image = gfx.image.new("images/help_bg2")
		help_dpad_image = gfx.image.new("images/help_dpad")
		help_crank_tiles = gfx.imagetable.new("images/help_crank")
		assert(help_bg1_image)
		assert(help_bg2_image)
		assert(help_dpad_image)
		assert(help_crank_tiles)

		-- Initialize world layers.  Do this first before initializing arm
		-- sprites since some memory is released in this step, which makes
		-- room for the rotated arm sprites later.
		for step = 0, 14 do
			world.init(step)
			world.show_loading_progress(step + 1, 19)
			coroutine.yield()
		end

		-- Initialize arm sprites.
		for step = 0, 3 do
			arm.init(step)
			world.show_loading_progress(step + 16, 19)
			coroutine.yield()
		end

		-- Initialize arm state.
		arm.reset()

		-- Load previous saved state, if any.  This is done after initializing
		-- arm state since we want to get various table keys populated first.
		load_state()
		world.set_draw_offset()

		gfx.clear()
		game_initialized = true
		assert(debug_log("Game started"))

	elseif world.reset_requested then
		assert(debug_log("Reset"))

		-- Reset requested.  We will start by showing the loading screen,
		-- since reloading the tiles takes a few seconds.
		gfx.setDrawOffset(0, 0)
		gfx.clear()
		world.show_loading_progress(0, 8)
		coroutine.yield()

		-- Always exit debug mode on reset.
		debug_mode = false
		assert(reset_backdoor_timer())

		-- If we need to synchronize game state, handle that before processing
		-- the reset.  This is so that if the player requested reset immediately
		-- after updating joint mode, their new joint mode selection will be
		-- reflected in the new game session.
		if resync_game_state_requested then
			resync_game_state()
		end

		-- Reset arm and world states, but preserve hint and joint modes
		-- across reset.
		local old_hint_mode <const> = arm.hint_mode
		local old_joint_mode <const> = arm.joint_mode
		arm.reset()
		arm.hint_mode = old_hint_mode
		arm.joint_mode = old_joint_mode
		world.reset()
		world.set_draw_offset()
		gfx.clear()
		world.reset_requested = false
		item_display_mode = false
		assert(debug_log("Game resumed"))

		-- Reset is triggered via pause menu, so we would have saved a state
		-- to reach this point, but we have not yet written the fresh reset
		-- state to disk.  This means if the game crashed here, player would
		-- resume from their previous state just before attempting the reset.
		--
		-- This feels slightly unclean since the on-disk state is a different
		-- game from what the player is current playing.  We could write the
		-- new state to disk here, but since we have already done one
		-- unnecessary write when we entered the menu to trigger the reset,
		-- we don't feel like writing again.
		--
		-- On the actual device, it doesn't make much difference if we never
		-- crash.  On the simulator, player has to be mindful of accessing
		-- the menu after a reset if they want to save a fresh state.
	end

	if debug_mode then
		-- Debug mode.
		world.debug_frame_count += 1
		if playdate.buttonJustPressed(playdate.kButtonA) then
			-- A button: Exit debug mode, committing new arm position.
			assert(debug_log(string.format("Exit debug mode, setting new position to (%d,%d)", arm.elbow_x, arm.elbow_y)))
			debug_mode = false
			resync_game_state_requested = true

			-- Fall through to draw one more frame before exiting.
			-- This is so that we consume the A button press.

		elseif playdate.buttonJustPressed(playdate.kButtonB) then
			-- B button: Abort debug mode, restoring old arm position.
			assert(debug_log(string.format("Abort debug mode, restoring old position at (%d,%d)", debug_rollback_x, debug_rollback_y)))
			arm.debug_move(debug_rollback_x - arm.elbow_x, debug_rollback_y - arm.elbow_y)
			debug_mode = false
			resync_game_state_requested = true

			-- Fall through to draw one more frame before exiting.
			-- This is so that we consume the B button press.

		else
			-- D-Pad buttons: move arm.

			-- Get movement amount from crank position.
			--
			-- Speed is proportional to how far the crank is away from bottom, so
			-- 0 results in fastest movement and 180 results in slowest movement.
			-- It's adjusted this way because simulator starts with the crank
			-- position at zero degrees, so we would get the maximum movement
			-- speed by default right after starting the simulator, which saves a
			-- few seconds when iterating on map updates.
			--
			-- Movement amount is adjusted to be a multiple of 2 except for the
			-- slowest mode.  This is because the camera scrolls at multiples
			-- of 2, so if if movement amount were odd, we will get an shaking
			-- effect in the arm.
			local angle <const> = abs(util.angle_delta(180, util.normalize_angle(floor(playdate.getCrankPosition()))))
			local amount = ((angle // 15) + 1) & ~1
			if angle < 15 then
				-- We could support finer grain positioning here, such as moving
				-- one pixel every few frames.  We haven't found a need for it.
				amount = 1
			end

			local dx = 0
			local dy = 0
			if playdate.buttonIsPressed(playdate.kButtonUp) then
				dy = -amount
			elseif playdate.buttonIsPressed(playdate.kButtonDown) then
				dy = amount
			end
			if playdate.buttonIsPressed(playdate.kButtonLeft) then
				dx = -amount
			elseif playdate.buttonIsPressed(playdate.kButtonRight) then
				dx = amount
			end

			if dx ~= 0 or dy ~= 0 then
				-- Apply movement to arm.
				arm.debug_move(dx, dy)

				-- Also move viewport in tandem, so the position of arm will
				-- remain more or less fixed on scree.  We do this instead of
				-- letting world.update_viewport() do automatic centering, because
				-- the latter tend to be jerky because the viewport adjustment
				-- rate is not in sync with the debug movement rate here.
				--
				-- Note that if we try to move the arm out of bounds,
				-- arm.debug_move will ignore that request, but that delta will
				-- still be applied to the sprite offsets here.  The bad sprite
				-- offsets will be fixed by world.update_viewport below.
				world.sprite_offset_x -= dx
				world.sprite_offset_y -= dy
				world.set_draw_offset()
			end
		end

		arm.update()
		arm.update_focus()
		world.update()
		world.update_viewport()
		gfx.sprite.update()
		draw_arm_coordinate()

		playdate.timer.updateTimers()
		return
	end

	-- Toggle collected items display on A/B press.
	if playdate.buttonJustPressed(playdate.kButtonA) or
	   playdate.buttonJustPressed(playdate.kButtonB) then
		if item_display_mode then
			-- Exit item display mode.
			item_display_mode = false
			gfx.clear()
		else
			-- Enter item display mode.
			item_display_mode = true
			world.show_item_list()
			playdate.timer.updateTimers()
			return
		end
	else
		if item_display_mode then
			-- Continue showing items.
			playdate.timer.updateTimers()
			return
		end
	end

	-- Update sprites and viewport.
	--
	-- Note that update_viewport() happens after arm.update(), because it
	-- needs the updated joint positions to set the viewport properly.
	-- Calling update_viewport() first would look suspiciously correct most
	-- of the time because it's only behind by one frame, but it will look
	-- wrong when we update joint positions after gfx.sprite.update().
	arm.update()
	arm.update_focus()
	world.expand_focus()
	world.update()
	world.update_viewport()
	gfx.sprite.update()
	arm.draw_cursor()
	if idle_frames > IDLE_HELP and arm.hint_mode > arm.HINT_NONE then
		show_help()
	end
	assert(debug_frame_rate())

	-- Resynchronize joint mode and cranks state after returning from menu.
	--
	-- Similar caveats with reset: joint mode setting is not saved here
	-- because we want to avoid saving state twice.  Simulator users
	-- will need to remember to access the menu again if they want to
	-- save joint mode settings after making a change.
	if resync_game_state_requested then
		resync_game_state()
	end

	-- Encode save state before handling input.  This will be used to
	-- compare game state after input is processed to see if player is idle.
	--
	-- Note that transitional states that are generated during
	-- arm.execute_action() are not saved, so we never save state during
	-- the middle of an action sequence.  This is to avoid resuming the
	-- game from the middle of those generated action sequences, especially
	-- since those may involve temporarily going through walls.
	prepare_save_state()
	assert(global_save_state)

	if playdate.buttonJustPressed(playdate.kButtonDown) then
		-- Handle actions.
		arm.execute_action()
		hide_help()

		-- Note that action sequences may take several seconds, and if player
		-- eagerly pressed "down" again before the end of the sequence, that
		-- "down" press will be buffered, next call to buttonJustPressed will
		-- return true, and the end result is another action sequence being
		-- executed immediately.  This seems undesirable if it happened by
		-- accident, and we can filter those by tracking an extra boolean state
		-- to ignore the button press.
		--
		-- The reason why we don't do it is because these consecutive presses
		-- tend to not happen by accident -- usually what the player will do is
		-- press "down" to execute an action, and then adjust the joint positions
		-- before pressing "down" again.  Because player will need the visual
		-- confirmation that joints have reached the target positions first, we
		-- tend to not run into the problem accidental "down" presses due to
		-- buffering.
		--
		-- In fact, we have one use case where buffered "down" presses are
		-- useful -- if the arm is at a position to summon a ball, it will also
		-- be at the correct position to grab it later.  Thus player can
		-- double-tap "down" to summon ball and immediately pick it up.

	else
		-- Handle arm joint updates.  This only happens if we are not executing
		-- an action, since we don't want both to happen at the same time.
		local up = playdate.buttonIsPressed(playdate.kButtonUp)
		local left = playdate.buttonIsPressed(playdate.kButtonLeft)
		local right = playdate.buttonIsPressed(playdate.kButtonRight)

		-- Invert the interpretation of "up" for weird flex modes.
		--
		-- We have to do this reinterpretation here and not inside
		-- arm.update_joints, since it needs to happen before the special
		-- handling for when ball is held.
		if (left or right) and (arm.joint_mode == arm.JOINT_W_P or arm.joint_mode == arm.JOINT_W_N) then
			up = not up
		end

		if arm.hold > 0 and not (up or left or right) then
			-- If we are currently holding a ball, and none of the D-Pad buttons
			-- are pressed, interpret this configuration as having either the
			-- left or right button pressed.  This makes it possible to operate
			-- the wrist joint using only the crank while holding a ball.
			--
			-- In normal operations, the timing of when D-pad buttons are
			-- released is not so critical, so requiring both D-Pad and crank
			-- for normal operations is fine.  But while a ball is held, the
			-- timing of when to press down on D-Pad determines the initial
			-- velocity of the ball, and there it's awkward to transition the
			-- D-Pad from whatever direction was held to "down", especially in
			-- the simulator.
			--
			-- Interpreting crank motion without D-Pad press as wrist movement
			-- makes it easier to gain a bit more control over how the ball is
			-- thrown.  Note that moving the wrist (as opposed to the elbow)
			-- is intentional -- the wrist usually always have a full motion
			-- range, unlike the elbow which tend to be limited because the
			-- larger swing makes it more prone to collisions.  In theory, the
			-- range of wrist motion would also mean that player can throw the
			-- ball in any direction using only wrist motion alone.
			if arm.bottom_attached then
				right = true
			else
				left = true
			end
		end
		arm.update_joints(up, left, right)

		if arm.is_idle(global_save_state[SAVE_STATE_ARM]) then
			idle_frames += 1
		else
			hide_help()
		end
	end
	check_debug_sequence()

	playdate.timer.updateTimers()
end

-- Update menu image to show statistics on pause.
function playdate.gameWillPause()
	gfx.pushContext(menu_image)
	gfx.clear()

	-- If game is not initialized yet (i.e. user pressed "menu" while we are
	-- still loading), only show version and contact info, and don't try to
	-- save state.
	if not game_initialized then
		draw_game_info(0)
		gfx.popContext()
		playdate.setMenuImage(menu_image, MENU_SLIDE_OFFSET)
		return
	end

	-- Draw in-game stats followed by version and contact info.
	draw_game_info(draw_game_stats())
	gfx.popContext()
	playdate.setMenuImage(menu_image, MENU_SLIDE_OFFSET)

	-- Hide help popups and synchronize game state when unpaused.
	hide_help()
	resync_game_state_requested = true

	-- If we are running inside simulator, also save state when user paused
	-- the game.  We do it here because usually we don't terminate the game
	-- in simulator (because if we do that, we will need to open the game
	-- again the next time instead of just reload).
	if playdate.isSimulator and global_save_state then
		playdate.datastore.write(global_save_state)
		assert(debug_log("Saved state"))
	end
end

-- Save state on exit.
function playdate.gameWillTerminate()
	save_state_on_exit()
end

-- Save state on sleep.
function playdate.deviceWillSleep()
	save_state_on_exit()
end

-- Extra local variables.  These are intended to use up all remaining
-- available local variable slots, such that any extra variable causes
-- pdc to spit out an error.  In effect, these help us measure how many
-- local variables we are currently using.
--
-- The extra variables will be removed by ../data/strip_lua.pl
local extra_local_variable_1 <const> = 75
local extra_local_variable_2 <const> = 76
local extra_local_variable_3 <const> = 77
local extra_local_variable_4 <const> = 78
local extra_local_variable_5 <const> = 79
local extra_local_variable_6 <const> = 80
local extra_local_variable_7 <const> = 81
local extra_local_variable_8 <const> = 82
local extra_local_variable_9 <const> = 83
local extra_local_variable_10 <const> = 84
local extra_local_variable_11 <const> = 85
local extra_local_variable_12 <const> = 86
local extra_local_variable_13 <const> = 87
local extra_local_variable_14 <const> = 88
local extra_local_variable_15 <const> = 89
local extra_local_variable_16 <const> = 90
local extra_local_variable_17 <const> = 91
local extra_local_variable_18 <const> = 92
local extra_local_variable_19 <const> = 93
local extra_local_variable_20 <const> = 94
local extra_local_variable_21 <const> = 95
local extra_local_variable_22 <const> = 96
local extra_local_variable_23 <const> = 97
local extra_local_variable_24 <const> = 98
local extra_local_variable_25 <const> = 99
local extra_local_variable_26 <const> = 100
local extra_local_variable_27 <const> = 101
local extra_local_variable_28 <const> = 102
local extra_local_variable_29 <const> = 103
local extra_local_variable_30 <const> = 104
local extra_local_variable_31 <const> = 105
local extra_local_variable_32 <const> = 106
local extra_local_variable_33 <const> = 107
local extra_local_variable_34 <const> = 108
local extra_local_variable_35 <const> = 109
local extra_local_variable_36 <const> = 110
local extra_local_variable_37 <const> = 111
local extra_local_variable_38 <const> = 112
local extra_local_variable_39 <const> = 113
local extra_local_variable_40 <const> = 114
local extra_local_variable_41 <const> = 115
local extra_local_variable_42 <const> = 116
local extra_local_variable_43 <const> = 117
local extra_local_variable_44 <const> = 118
local extra_local_variable_45 <const> = 119
local extra_local_variable_46 <const> = 120
local extra_local_variable_47 <const> = 121
local extra_local_variable_48 <const> = 122
local extra_local_variable_49 <const> = 123
local extra_local_variable_50 <const> = 124
local extra_local_variable_51 <const> = 125
local extra_local_variable_52 <const> = 126
local extra_local_variable_53 <const> = 127
local extra_local_variable_54 <const> = 128
local extra_local_variable_55 <const> = 129
local extra_local_variable_56 <const> = 130
local extra_local_variable_57 <const> = 131
local extra_local_variable_58 <const> = 132
local extra_local_variable_59 <const> = 133
local extra_local_variable_60 <const> = 134
local extra_local_variable_61 <const> = 135
local extra_local_variable_62 <const> = 136
local extra_local_variable_63 <const> = 137
local extra_local_variable_64 <const> = 138
local extra_local_variable_65 <const> = 139
local extra_local_variable_66 <const> = 140
local extra_local_variable_67 <const> = 141
local extra_local_variable_68 <const> = 142
local extra_local_variable_69 <const> = 143
local extra_local_variable_70 <const> = 144
local extra_local_variable_71 <const> = 145
local extra_local_variable_72 <const> = 146
local extra_local_variable_73 <const> = 147
local extra_local_variable_74 <const> = 148
local extra_local_variable_75 <const> = 149
local extra_local_variable_76 <const> = 150
local extra_local_variable_77 <const> = 151
local extra_local_variable_78 <const> = 152
local extra_local_variable_79 <const> = 153
local extra_local_variable_80 <const> = 154
local extra_local_variable_81 <const> = 155
local extra_local_variable_82 <const> = 156
local extra_local_variable_83 <const> = 157
local extra_local_variable_84 <const> = 158
local extra_local_variable_85 <const> = 159
local extra_local_variable_86 <const> = 160
local extra_local_variable_87 <const> = 161
local extra_local_variable_88 <const> = 162
local extra_local_variable_89 <const> = 163
local extra_local_variable_90 <const> = 164
local extra_local_variable_91 <const> = 165
local extra_local_variable_92 <const> = 166
local extra_local_variable_93 <const> = 167
local extra_local_variable_94 <const> = 168
local extra_local_variable_95 <const> = 169
local extra_local_variable_96 <const> = 170
local extra_local_variable_97 <const> = 171
local extra_local_variable_98 <const> = 172
local extra_local_variable_99 <const> = 173
local extra_local_variable_100 <const> = 174
local extra_local_variable_101 <const> = 175
local extra_local_variable_102 <const> = 176
local extra_local_variable_103 <const> = 177
local extra_local_variable_104 <const> = 178
local extra_local_variable_105 <const> = 179
local extra_local_variable_106 <const> = 180
local extra_local_variable_107 <const> = 181
local extra_local_variable_108 <const> = 182
local extra_local_variable_109 <const> = 183
local extra_local_variable_110 <const> = 184
local extra_local_variable_111 <const> = 185
local extra_local_variable_112 <const> = 186
local extra_local_variable_113 <const> = 187
local extra_local_variable_114 <const> = 188
local extra_local_variable_115 <const> = 189
local extra_local_variable_116 <const> = 190
local extra_local_variable_117 <const> = 191
local extra_local_variable_118 <const> = 192
local extra_local_variable_119 <const> = 193
local extra_local_variable_120 <const> = 194
local extra_local_variable_121 <const> = 195
local extra_local_variable_122 <const> = 196
local extra_local_variable_123 <const> = 197
local extra_local_variable_124 <const> = 198
local extra_local_variable_125 <const> = 199
local extra_local_variable_126 <const> = 200
local extra_local_variable_127 <const> = 201
local extra_local_variable_128 <const> = 202
local extra_local_variable_129 <const> = 203
local extra_local_variable_130 <const> = 204
local extra_local_variable_131 <const> = 205
local extra_local_variable_132 <const> = 206
local extra_local_variable_133 <const> = 207
local extra_local_variable_134 <const> = 208
local extra_local_variable_135 <const> = 209
local extra_local_variable_136 <const> = 210
local extra_local_variable_137 <const> = 211
local extra_local_variable_138 <const> = 212
local extra_local_variable_139 <const> = 213
local extra_local_variable_140 <const> = 214
local extra_local_variable_141 <const> = 215
local extra_local_variable_142 <const> = 216
local extra_local_variable_143 <const> = 217
local extra_local_variable_144 <const> = 218
local extra_local_variable_145 <const> = 219
local extra_local_variable_146 <const> = 220

--}}}
