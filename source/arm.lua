--[[ Joint arm states.

All the arm movement and posing functions go here.

Best place to start reading is arm.reset() for the data model, followed by
arm.update_joints() for how movements are handled.

The arm is graphically a set 6 sprites: one for each arm, and two fingers
for each hand.  All 6 sprites can rotate 360 degrees at 1-degree increments,
but for control purposes, we abstract them to 3 rotating joints: lower wrist
(shoulder), elbow, upper wrist.  arm.reset() has more comments on how the
arm is modelled.

A key complication of this library is in translating crank *position*
directly to joint angles, as opposed to applying crank *change* to the joint
angles.  This is implemented by balancing three variables:

   joint = delta + crank (for clockwise joints)
   joint = delta - crank (for counterclockwise joints)

On each update, we do one of three things:
- Hold "delta" fixed and update "joint" proportional to "crank".  This
  happens in response to user input, where no collision is observed.

- Hold "joint" fixed and update "delta" proportional to "crank".  This
  happens while a particular joint is idle, and we need to synchronize with
  crank position.

- Update "joint" with partial amount from "crank", with the remainder amount
  going to "delta" updates.  This happens when a full joint rotation would
  have resulted in a collision, so we adjusted "delta" to prevent joint from
  rotating further.

Because the direction of joint rotation can change rapidly, actual
implementation actually splits the "delta" in two, and balances four
variables to balance the two equations simultaneously:

   joint = positive_delta + crank
   joint = negative_delta - crank

For example, if a joint is in clockwise mode (i.e. if its direction is meant
to match the direction of crank rotation), we hold "positive_delta" as fixed
while updating "joint" and "negative_delta" in response to changes in "crank".

See arm.update_joints() for additional details.

--]]

import "CoreLibs/graphics"
import "CoreLibs/sprites"

import "util"
import "world"

-- Cached imported references and constants.
local gfx <const> = playdate.graphics
local abs <const> = math.abs
local atan2 <const> = math.atan2
local cos <const> = math.cos
local floor <const> = math.floor
local max <const> = math.max
local min <const> = math.min
local sin <const> = math.sin
local sqrt <const> = math.sqrt
local PI <const> = math.pi
local deg2rad <const> = PI / 180
local rad2deg <const> = 180 / PI

local wrist_offsets <const> = arm.wrist_offsets
local angle_delta <const> = util.angle_delta
local distance2 <const> = util.distance2
local interpolate_angle <const> = util.interpolate_angle
local normalize_angle <const> = util.normalize_angle
local overlapping_rotation <const> = util.overlapping_rotation
local round <const> = util.round
assert(angle_delta)
assert(interpolate_angle)
assert(normalize_angle)
assert(overlapping_rotation)
assert(round)

local collide_with_world <const> = world.collide
assert(collide_with_world)

-- Arm states.
arm = arm or {}

-- Arm operation modes.  P/+ means the joint rotation direction matches
-- crank rotation, N/- means joint rotation is opposite of crank rotation.
--
-- On playdate simulator, positive crank rotation translates to clockwise
-- rotation of the crank the display, and with P/+ modes, they will also
-- translate to clockwise rotation of the joint.
--
-- Initially we have just the PNP mode, which kind of makes sense mechanically
-- in that because the elbow moves opposite of how the wrist moves, a
-- diagonal direction on D-Pad behaves exactly like how the orthogonal
-- directions would behave when operated in sequence:
--
--   (left + crank) + (up - crank) == (up+left +/- crank)
--
-- The unfortunate thing about this mode is that player has to constantly
-- mentally switch between crank directions when they are switching joints.
-- Since it's far more common for players to operate one joint at a time,
-- we made the default such that clockwise crank rotation always results
-- in clockwise joint movement.  For the diagonal case where both wrist
-- and elbow need to rotate in opposite directions, we make the wrist
-- rotation match the crank rotation.
--
-- "W_P" is like "PPP" except the interpretation of Up on D-Pad is inverted,
-- such that holding left or right moves two joints instead of just one, while
-- holding both left+up or right+up moves one joint instead of two.  This is
-- best summarized in a table (first column are the button that are held, next
-- two columns show the joints that would be moved):
--
--   D-Pad    | PPP / NNN / PNP / NPN | W_P / W_N
--   ---------+-----------------------+-------------
--   left     | lower                 | lower+middle
--   left+up  | lower+middle          | lower
--   right    | upper                 | upper+middle
--   right+up | upper+middle          | upper
--   up       | middle                | middle
--
-- Think of "W" as "double".  It's useful for people who find themselves
-- holding the diagonal direction on D-Pad more often than the orthogonal
-- directions.  But honestly what really happened is that we named the menu
-- item "flex", and then it seemed like not having a "weird flex" mode would
-- be a real shame.  Most players will probably stick to the default PPP mode
-- and never change it to anything else.
--
-- Note that JOINT_W_P is always interpreted the same as JOINT_PPP throughout
-- this file, and similarly for JOINT_W_N/JOINT_NNN.  The mode differences
-- are handled as different interpretations of input buttons, which are all
-- implemented in main.lua.  This file is mainly concerned with operating on
-- joints, which happens after all buttons are interpreted.
arm.JOINT_PPP = 1
arm.JOINT_PNP = 2
arm.JOINT_NNN = 3
arm.JOINT_NPN = 4
arm.JOINT_W_P = 5
arm.JOINT_W_N = 6
local JOINT_PPP <const> = arm.JOINT_PPP
local JOINT_PNP <const> = arm.JOINT_PNP
local JOINT_NNN <const> = arm.JOINT_NNN
local JOINT_NPN <const> = arm.JOINT_NPN
local JOINT_W_P <const> = arm.JOINT_W_P
local JOINT_W_N <const> = arm.JOINT_W_N
arm.JOINT_MODES = {"+ + +", "+ - +", "- - -", "- + -", "weird +", "weird -"}

-- Hint modes.
-- + none = Don't show any hints at all, regardless of idle time.
-- + basic = Show controls after a few seconds.  This is the default, as it
--           helps new players to learn the controls.
-- + more = Show direction to nearest item, if it's not visible on screen.
--          This is something of a spoiler, so it's not enabled by default.
-- + even more = Show direction to nearest item, even if it's visible on screen.
-- + extra = Show actionable tiles after a few seconds.  This makes certain
--           secrets more visible, so it's an even greater spoiler.
arm.HINT_NONE = 1
arm.HINT_BASIC = 2
arm.HINT_MORE = 3
arm.HINT_EVEN_MORE = 4
arm.HINT_EXTRA = 5
arm.HINT_MODES = {"none", "basic", "more", "even more", "extra"}

----------------------------------------------------------------------
--{{{ Graphical states.

-- Z indices.  See also world.lua.
local Z_BOTTOM_ARM <const> = 21
local Z_BOTTOM_CAPTURED_OBJECT <const> = 22
local Z_BOTTOM_FINGER_BOTTOM <const> = 23
local Z_BOTTOM_FINGER_TOP <const> = 24
local Z_WRIST <const> = 25
local Z_TOP_CAPTURED_OBJECT <const> = 26
local Z_TOP_FINGER_BOTTOM <const> = 27
local Z_TOP_FINGER_TOP <const> = 28
local Z_TOP_ARM <const> = 29

-- Table of images for each rotation angle.
local g_arm_top = nil
local g_arm_bottom = nil
local g_finger_top = nil
local g_finger_bottom = nil

-- Pixel offsets to rotation center, one entry for each 90 degree range.
-- After calling setCenter(0,0) on each sprite, the offsets here are added
-- to the desired target position to keep the center of rotation at the
-- same pixel location for all rotation angles.
--
-- These values are determined empirically, to correct for one-pixel shifts
-- when the sprites are rotated.  To repeat the calibration process:
--
-- - For G_ARM_OFFSET:
--
--   0. Make sure the arm is mounted on the bottom.  This is so that the
--      top of arm can rotate freely while keeping elbow stationary in
--      world space.
--
--   1. In simulator console, output the current arm angle using
--
--      print(arm.top.arm)
--
--   2. Rotate the top arm such that the arm angle goes through the four
--      quadrants, taking a screenshot at each quadrant.
--
--   3. Count the number pixels where the circular elbow hole is off-centered
--      from the elbow joint position (indicated by a red cross in debug
--      builds).  Apply that count to G_ARM_OFFSET.
--
--   4. To confirm that calibration is done correctly, rotate the top arm
--      around and confirm that the elbow hole doesn't move.
--
-- - For G_TOP_FINGER_OFFSET and G_BOTTOM_FINGER_OFFSET:
--
--   0. Make sure the arm is mounted on the top.  This is so that the
--      top of arm doesn't cover up the finger sprites.
--
--      If we are calibrating G_BOTTOM_FINGER_OFFSET, we should also add
--      "s_top:setVisible(false)" to update_hand_sprites function so that
--      the top finger sprite doesn't obstruct the bottom finger sprite.
--
--   1. In simulator console, output the current hand angle using
--
--      print(arm.bottom.hand)
--
--   2. Rotate the hand such that the hand angle goes through the four
--      quadrants, taking a screenshot at each quadrant.
--
--   3. Count the number pixels where the circular finger hole is off-centered
--      from the wrist joint position (indicated by a red cross in debug
--      builds).  Apply that count to offset tables.
--
--   4. To confirm that calibration is done correctly, rotate the hand around
--      a full circle and observe that the wrist hole doesn't move.
--
-- My hope is that we never need to repeat this process, but see comments
-- near util.rotated_image and util.vertically_flipped_image in util.lua
-- for why we needed it in the first place.  If the behavior of drawRotated()
-- and draw() with kImageFlippedY changed in a future SDK version, we will
-- need to do it again, unless we want to make the sprite positions
-- self-calibrating.
--
-- Note that these are fixes related to elbow and finger positions.  The
-- wrist hole is a different problem altogether because the hole wasn't
-- pixel-aligned to begin with.  See generate_wrist_offsets.c for how we
-- dealt with that problem.
local G_ARM_OFFSET <const> =
{
	{ -24,  -24},
	{-113,  -24},
	{-113, -113},
	{ -24, -113},
}
local G_TOP_FINGER_OFFSET <const> =
{
	{-24, -22},
	{-47, -24},
	{-45, -47},
	{-22, -45},
}
local G_BOTTOM_FINGER_OFFSET <const> =
{
	{-22, -24},
	{-45, -22},
	{-47, -45},
	{-24, -47},
}

-- Joint sizes and offsets.
--
-- By the way, accessing hand_offsets as a table is about twice as fast as
-- using cos/sin on the actual device.
local ELBOW_RADIUS <const> = 24
local WRIST_RADIUS <const> = 13.5
local HAND_RADIUS <const> = 25
local HAND_OFFSET <const> = 17.5
local ARM_LENGTH <const> = 100

-- Size of the ball that is being held, see BALL_RADIUS in world.lua.
local BALL_RADIUS <const> = 16

-- Scaling factor from arm length (elbow to wrist) to half-width of arm
local ARM_LENGTH_TO_HALF_WIDTH_MULTIPLIER <const> = 13.5 / ARM_LENGTH

-- Minimum angle between two arms to avoid collision between two wrists.
local MINIMUM_ELBOW_ANGLE <const> = 16

-- Hand opening angle for grabbing an object.
local GRAB_OPENING_ANGLE <const> = 20

-- Lower arm angle when arm is folded in a compact pose (upper arm is 0).
-- Most compact angle would be 20, but by setting this angle to be a bit
-- higher, the unmounted hand is raised slightly away from the floor, such
-- that the top action right after a teleport will be another teleport.
-- This allows the player go through the chain of teleport stations by
-- pressing down repeatedly.
--
-- If we set the angle to 20, the unmounted hand will be too close to the
-- floor, such that the top action right after a teleport will be shifting
-- the mount position to the other hand.
local COMPACT_FOLD_ANGLE <const> = 30

-- Vertical distance from teleport station mount point to UFO summon location.
local TELEPORT_STATION_HEIGHT <const> = world.TELEPORT_STATION_HEIGHT

-- Number of frames for arm assembly sequence.
local ARM_ASSEMBLY_PART_STAGGER <const> = 3
local ARM_ASSEMBLY_PART_FLIGHT <const> = 6
local ARM_ASSEMBLY_FRAMES <const> = ARM_ASSEMBLY_PART_STAGGER * 7 + ARM_ASSEMBLY_PART_FLIGHT

-- Remove breakable tiles if the crank was rotating at this many degrees
-- per frame up collision.  This threshold was set more or less empirically.
--
-- Note that the threshold is particularly low when running inside the
-- simulator, meaning pretty much any collision counts as a breaking
-- collision.  This is because it's already hard enough to control the crank
-- with the simulator, even more difficult to have varying speeds.  Having
-- everything easily breakable is not necessarily a disadvantage, so we just
-- do that for the simulator.  But note that using only the keyboard to deliver
-- two hits would still be difficult, because the joint angles would be aligned
-- after the first hit, so the second hit tend to stop exactly at the object
-- surface, instead of getting the few few degrees overflow needed for the
-- breakage.
--
-- We still use the higher threshold for real device, because the feeling
-- that varying crank speed contributes to varying outcome is much more
-- satisfying than just have everything uniformly fragile.
local BREAK_THRESHOLD_DEGREES <const> = playdate.isSimulator and 1 or 3

-- Number of entries to keep in action_plan_cache.
--
-- Most of the points of interests are going to come from mount points,
-- and typically those are found on the same surface that the arm is currently
-- mounted on.  The arm reaches 200 pixels in two directions, so a cache size
-- of 512 should almost never have any evictions.  Max observed size is 119.
local MAX_ACTION_PLAN_CACHE_SIZE <const> = 512

-- Animation variations for use with interpolate_toward_pose.
local INTERPOLATE_SLOWLY <const> = 1
local INTERPOLATE_MEDIUM_PACE <const> = 2
local INTERPOLATE_WITH_CAPTURED_OBJECT <const> = 3
local INTERPOLATE_WITH_SHRINKING_OBJECT <const> = 4
local INTERPOLATE_WITH_HOLD <const> = 5
local INTERPOLATE_TELEPORT_DEPARTURE <const> = 6
local INTERPOLATE_TELEPORT_ARRIVAL <const> = 7

-- Save state dictionary keys.
local SAVE_STATE_JOINT_MODE <const> = "j"
local SAVE_STATE_HINT_MODE <const> = "t"
local SAVE_STATE_ATTACHMENT <const> = "a"
local SAVE_STATE_ELBOW_X <const> = "x"
local SAVE_STATE_ELBOW_Y <const> = "y"
local SAVE_STATE_BOTTOM_ARM <const> = "d"
local SAVE_STATE_BOTTOM_HAND <const> = "b"
local SAVE_STATE_TOP_ARM <const> = "q"
local SAVE_STATE_TOP_HAND <const> = "p"
local SAVE_STATE_HOLD <const> = "h"
local SAVE_STATE_START <const> = "i"
local SAVE_STATE_STEP_COUNT <const> = "s"

-- Offsets from wrist to center of hand for each rotation angle.  Index is
-- integer degrees (zero based).
--
-- This is used for collision tests, in conjunction with hand_test_points.
local hand_offsets = nil

-- Offset from wrist to wall for mounting purposes.  Index is integer degrees
-- that are multiples of 45.
--
-- This is the approach position for where wrists will be moved to before
-- opening hand and attaching to wall.  It's not simply double of hand_offsets
-- because offset to center of hand is smaller than the hand radius (because
-- the portion of the hand near the wrist is more elliptical than circular).
local approach_offsets = nil

-- Offset from wrist for grabbing objects.  Index is integer degrees
-- that are multiples of 45.
local grab_offsets = nil

-- Coordinates for collision test locations around each joint.
local hand_test_points = nil
local wrist_test_points = nil
local elbow_test_points = nil
local ball_test_points = nil

-- Arm sprites.
local gs_bottom_arm = nil
local gs_bottom_finger_bottom = nil
local gs_bottom_finger_top = nil
local gs_wrist = nil
local gs_top_finger_bottom = nil
local gs_top_finger_top = nil
local gs_top_arm = nil

-- Cursor images.
local gs_mount_h = nil
local gs_mount_v = nil
local gs_mount_d_slash = nil
local gs_mount_d_backslash = nil
local gs_summon_ball = nil
local gs_summon_ufo = nil
local gs_circle_target = nil
local gs_hint_cursors = nil

-- Sprite for object that is currently being held by the hand.
local gs_captured_object = nil

-- Cursor blink timer.  This is increment on every frame, and reset when
-- arm.action_target changes.
local cursor_timer = 0

-- Number of frames without any actions available.  This is incremented
-- while idling and reset when arm.action_target changes.  See comments
-- near HINT_DELAY_FRAMES below.
local idle_timer = 0

-- Hint image queue.  Each entry contains:
-- {frame index, world x, world y, gs_hint_cursors index}
local hint_table = {}

-- Add hints relative to this position.
local hint_origin_x = 0
local hint_origin_y = 0

-- Show hints after player has been idling for this many frames, where idle
-- means not holding a ball and not having an executable action.  Basically,
-- the arm is in a state where pressing "down" is no-op.  The arm could be
-- moving and idle_timer would still increase if player did not come across
-- an actionable tile during the move.
--
-- The hints consist of flashing cursor images radially outward from current
-- hand location, showing the spots that could be actioned upon if the arm
-- were closer.  The intent is to show mountable walls and breakable tiles
-- in places where they might not be visually obvious.
--
-- The delay here is relatively short, but since the extra hints are disabled
-- by default, we assume that players who enabled them really wanted to see
-- them, so they are shown with a short delay.  That said, my average time
-- between steps is about 3 seconds, so the hints should never trigger for
-- players who know where they are going.
local HINT_DELAY_FRAMES <const> = 6 * 30

-- Reset idle_timer to HINT_DELAY_FRAMES after this many frames.  This causes
-- the hints to be displayed repeatedly if the player kept on idling, at an
-- interval that is shorter than the initial HINT_DELAY_FRAMES.
local HINT_RESET_FRAMES <const> = HINT_DELAY_FRAMES + 5 * 30
assert(HINT_RESET_FRAMES > HINT_DELAY_FRAMES + #world.hints * 3)

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

-- Dump cache stats to console.
local function debug_cache_stats()
	assert(action_plan_cache_stats)
	local average_seek = "n/a"
	if action_plan_cache_stats.hit > 0 then
		average_seek = action_plan_cache_stats.seek / action_plan_cache_stats.hit
	end
	debug_log(string.format(
		"action_plan_cache: hit=%d, miss=%d, avg_seek=%s, max_size=%d",
		action_plan_cache_stats.hit,
		action_plan_cache_stats.miss,
		average_seek,
		action_plan_cache_stats.max_size))
	return true
end

-- Keep track of stats for check_and_cache_action.
local function debug_cache_event(event, arg)
	if not action_plan_cache_stats then
		action_plan_cache_stats =
		{
			hit = 0, miss = 0, seek = 0, max_size = 0
		}
	end
	if event == "hit" then
		action_plan_cache_stats.hit += 1
		action_plan_cache_stats.seek += arg
	elseif event == "miss" then
		action_plan_cache_stats.miss += 1
	elseif event == "reset" then
		local max_size_increased = false
		if action_plan_cache_stats.max_size < arg then
			action_plan_cache_stats.max_size = arg
			max_size_increased = true
		end

		if max_size_increased then
			-- Maximum action plan cache size increased.  Log current stats,
			-- and also log the location where this happened.
			--
			-- We are interested in places where the max size increased
			-- because it could indicate locations that are more complex than
			-- average, and complex locations tend to cause lags because
			-- set_action_from_poi_list will need to process more entries.
			--
			-- Complexity is dominated by number of mountable tiles nearby,
			-- so if we log a message about a cache size increase at a
			-- particular location, the usual response would be to see if there
			-- are any nearby mountable surfaces that can be removed.  For
			-- example, by filling unreachable areas with solid collisions.
			debug_cache_stats()

			-- Location of where cache size increased is near one of the hands.
			-- Since most common entry to debug_cache_stats is right after
			-- performing a mount operation, the hand that saw the extra points
			-- is usually the hand that is currently mounted to the wall, so we
			-- will log the coordinate of just that hand.  The actual trouble
			-- spots won't be at that coordinate specifically, but they will be
			-- nearby, so we don't need to log more coordinates.
			if arm.bottom_attached then
				debug_log(string.format("action_plan_cache: cache size increased near (%g,%g)", arm.bottom.hand_x, arm.bottom.hand_y))
			else
				debug_log(string.format("action_plan_cache: cache size increased near (%g,%g)", arm.top.hand_x, arm.top.hand_y))
			end

		elseif arm.step_count % 8 == 0 then
			-- Even without max cache size increases, we will still log cache
			-- stats every so often.
			debug_cache_stats()
		end
	end
	return true
end

-- Load images from a table, duplicating 90 entries starting at the
-- specified offset to generate sprites for all 360 degrees of rotation.
--
-- Note that we keep image tables of the same size within the same file,
-- and use start_offset to index inside those tables.  This is because
-- fewer output files look cleaner.
--
-- Because this function may read from the same image table multiple times,
-- loading is done by the calling function.  Doing it this way also appears
-- to reduce heap usage by ~400K.  You would think that the loaded and
-- copied images would be garbage collected after this function returns, but
-- that doesn't seem to happen in practice.
local function load_and_rotate(image_table, start_offset, output_table)
	for i = 1, 90 do
		output_table:setImage(i, image_table[start_offset + i])
	end
	for a = 1, 3 do
		for i = 1, 90 do
			output_table:setImage(a * 90 + i, util.rotated_image(image_table[start_offset + i], a * 90))
		end
	end
end

-- Generate mirror images of finger sprites.
local function initialize_bottom_finger()
	for i = 1, 90 do
		g_finger_bottom:setImage(360 - i + 1, util.vertically_flipped_image(g_finger_top[i]))
	end
	for a = 1, 3 do
		for i = 1, 90 do
			g_finger_bottom:setImage((a - 1) * 90 + i, util.rotated_image(g_finger_bottom[270 + i], a * 90))
		end
	end
end

-- Apply common sprite settings.
local function init_sprite(s, z)
	s:addSprite()
	s:setCenter(0, 0)
	s:setZIndex(z)
end

-- Initialize rotation offset tables.
local function init_offset_tables()
	-- Hand offsets.
	hand_offsets = table.create(360, 0)
	for i = 0, 359 do
		hand_offsets[i] = {}
		hand_offsets[i][1] = round(HAND_OFFSET * cos(i * deg2rad))
		hand_offsets[i][2] = round(HAND_OFFSET * sin(i * deg2rad))
	end

	-- Test points and mount offsets.
	hand_test_points = table.create(8, 0)
	wrist_test_points = table.create(8, 0)
	elbow_test_points = table.create(8, 0)
	ball_test_points = table.create(8, 0)
	approach_offsets = {}
	grab_offsets = {}
	for i = 1, 8 do
		local d <const> = (i - 1) * 45
		local a <const> = d * deg2rad
		local c <const> = cos(a)
		local s <const> = sin(a)
		hand_test_points[i] = {round(HAND_RADIUS * c), round(HAND_RADIUS * s)}
		wrist_test_points[i] = {round(WRIST_RADIUS * c), round(WRIST_RADIUS * s)}
		elbow_test_points[i] = {round(ELBOW_RADIUS * c), round(ELBOW_RADIUS * s)}
		ball_test_points[i] = {round(BALL_RADIUS * c), round(BALL_RADIUS * s)}

		-- We want an offset such that the hand does not collide with walls
		-- on unmount.  HAND_OFFSET + HAND_RADIUS should have been sufficient,
		-- but we add an extra margin +2 to account for rounding.
		--
		-- Note that approach offset is negative.  This is because the indices
		-- are hand angles, which are opposite of the normal angles.  We use
		-- a negative offset here to back away from the mount surface.
		local ra <const> = -(HAND_OFFSET + HAND_RADIUS + 2)
		approach_offsets[d] = {round(ra * c), round(ra * s)}

		-- Grab offset was determined empirically, via simulator console:
		-- 1. Set arm.top.opening=20 and arm.top.hand=90.
		-- 2. Confirm that arm.top.hand_x==arm.top.wrist_x.
		-- 3. Move hand such that arm.top.hand_x==arm.action_target.x and the
		--    vertical position of hand appears to grab the mushroom just right.
		-- 4. print(arm.action_target.y - arm.top.wrist_y).
		local rg <const> = -39
		grab_offsets[d] = {round(rg * c), round(rg * s)}
	end
end

--}}}

----------------------------------------------------------------------
--{{{ Graphic functions.

-- Adjust coordinate with G_ARM_OFFSET.
local function arm_offset(a, x, y)
	return x + G_ARM_OFFSET[(a // 90) + 1][1], y + G_ARM_OFFSET[(a // 90) + 1][2]
end

-- Adjust coordinate with G_TOP_FINGER_OFFSET.
local function top_finger_offset(a, x, y)
	return x + G_TOP_FINGER_OFFSET[(a // 90) + 1][1], y + G_TOP_FINGER_OFFSET[(a // 90) + 1][2]
end

-- Adjust coordinate with G_BOTTOM_FINGER_OFFSET.
local function bottom_finger_offset(a, x, y)
	return x + G_BOTTOM_FINGER_OFFSET[(a // 90) + 1][1], y + G_BOTTOM_FINGER_OFFSET[(a // 90) + 1][2]
end

-- Update sprites for a single hand.
local function update_hand_sprites(a, s_top, s_bottom)
	-- Compute and cache wrist position.
	a.wrist_x = arm.elbow_x + wrist_offsets[a.arm][1]
	a.wrist_y = arm.elbow_y + wrist_offsets[a.arm][2]
	a.hand_x = a.wrist_x + hand_offsets[a.hand][1]
	a.hand_y = a.wrist_y + hand_offsets[a.hand][2]

	local finger_top_x <const> = a.wrist_x
	local finger_top_y <const> = a.wrist_y
	local finger_bottom_x <const> = a.wrist_x
	local finger_bottom_y <const> = a.wrist_y

	local top_angle <const> = (a.hand + a.opening) % 360
	s_top:setImage(g_finger_top[top_angle + 1])
	s_top:moveTo(top_finger_offset(top_angle, finger_top_x, finger_top_y))

	local bottom_angle <const> = (a.hand - a.opening + 360) % 360
	s_bottom:setImage(g_finger_bottom[bottom_angle + 1])
	s_bottom:moveTo(bottom_finger_offset(bottom_angle, finger_bottom_x, finger_bottom_y))

	-- Confirm that wrist and hand coordinates are non-negative.  This matters
	-- because there are a few places where we use bitwise shift instead of
	-- division, and ">>" operator does unsigned shifts (i.e. they don't extend
	-- sign bit, so shifting negative numbers result in large positive numbers).
	--
	-- We are able to enforce coordinates being non-negative because all world
	-- locations are non-negative, and attempting to move to any negative
	-- coordinate will trip over collision check.
	assert(a.wrist_x >= 0)
	assert(a.wrist_y >= 0)
	assert(a.hand_x >= 0)
	assert(a.hand_y >= 0)
end

-- Linear interpolation.
local function lerp(a, b, t)
	return a + (b - a) * t
end

-- Arm assembly animation.
-- (sx, sy) = where arm parts are coming from.
-- direction = animation direction: +1 = disassemble, -1 = assemble.
local function animate_arm_assembly(sx, sy, direction)
	-- Sort sprites depending on which side we are mounted.
	local sprites
	if arm.bottom_attached then
		sprites =
		{
			gs_top_finger_top,
			gs_top_finger_bottom,
			gs_wrist,
			gs_top_arm,
			gs_bottom_arm,
			gs_bottom_finger_top,
			gs_bottom_finger_bottom,
		}
	else
		sprites =
		{
			gs_bottom_finger_top,
			gs_bottom_finger_bottom,
			gs_bottom_arm,
			gs_top_arm,
			gs_wrist,
			gs_top_finger_top,
			gs_top_finger_bottom,
		}
	end
	local initial_position = table.create(7, 0)
	for i = 1, 7 do
		local x <const>, y <const> = sprites[i]:getPosition()
		initial_position[i] = {x, y}

		-- Unhide arm sprites at the start of assembly.
		if direction == -1 then
			sprites[i]:setVisible(true)
		end
	end

	local f0 <const> = (direction == 1) and 0 or ARM_ASSEMBLY_FRAMES
	local f1 <const> = (direction == 1) and ARM_ASSEMBLY_FRAMES or 0
	for f = f0, f1, direction do
		if world.reset_requested then return end

		-- Move the arm parts one by one, staggering the flight of each part.
		for i = 1, 7 do
			local part_f0 <const> = (i - 1) * ARM_ASSEMBLY_PART_STAGGER
			local part_f1 <const> = part_f0 + ARM_ASSEMBLY_PART_FLIGHT
			if f >= part_f0 and f <= part_f1 then
				local t <const> = (f - part_f0) / ARM_ASSEMBLY_PART_FLIGHT
				sprites[i]:moveTo(lerp(initial_position[i][1], sx, t),
				                  lerp(initial_position[i][2], sy, t))
				sprites[i]:setScale(1 - t)
			end
		end
		world.update()
		world.update_viewport()
		assert(debug_frame_rate())
		gfx.sprite.update()
		coroutine.yield()
	end

	if direction == 1 then
		-- Hide arm sprites at the end of disassembly.
		for i = 1, 7 do
			sprites[i]:setVisible(false)
		end
	else
		-- Ensure arm sprites are unscaled at the end of assembly.
		for i = 1, 7 do
			sprites[i]:setScale(1)
			sprites[i]:setVisible(true)
		end
	end
end

-- Extra animation steps in preparation to teleport away from current location,
-- for use with INTERPOLATE_TELEPORT_DEPARTURE.
local function animate_teleport_departure()
	-- Disassemble arm.
	animate_arm_assembly(arm.action_target.x, arm.action_target.y, 1)

	-- Move UFO away from departure location.
	local dx <const> = arm.action_target.next_x > arm.action_target.x and 25 or -25
	for i = 1, 15 do
		if world.reset_requested then return end

		world.move_ufo(arm.action_target.x + i * dx, arm.action_target.y)
		world.update()
		world.update_viewport()
		assert(debug_frame_rate())
		gfx.sprite.update()
		coroutine.yield()
	end
end

-- Extra animation steps after teleporting to current location, for use with
-- INTERPOLATE_TELEPORT_DEPARTURE.
local function animate_teleport_arrival()
	-- Move UFO to arrival location.  This takes more frames than the departure
	-- sequence because also want to wait for the viewport movement to catch up.
	local dx <const> = arm.action_target.next_x > arm.action_target.x and 25 or -25
	local ufo_x0 <const> = arm.action_target.x + 15 * dx
	local ufo_x1 <const> = arm.action_target.next_x
	for i = 1, 32 do
		if world.reset_requested then return end

		world.move_ufo(lerp(ufo_x0, ufo_x1, i / 32), arm.action_target.next_y - TELEPORT_STATION_HEIGHT)
		world.update()
		world.update_viewport()
		assert(debug_frame_rate())
		gfx.sprite.update()
		coroutine.yield()
	end

	-- Assemble arm.
	animate_arm_assembly(arm.action_target.next_x, arm.action_target.next_y - TELEPORT_STATION_HEIGHT, -1)

	-- Dismiss UFO.
	for i = 1, 5 do
		if world.reset_requested then return end

		world.dismiss_ufo(arm.action_target.next_x, arm.action_target.next_y - TELEPORT_STATION_HEIGHT)
		world.update()
		world.update_viewport()
		assert(debug_frame_rate())
		gfx.sprite.update()
		coroutine.yield()
	end
end

-- Return maximum rotation angle steps based on interpolation variation.
local function max_angular_speed(pose)
	assert(pose.variation)
	if pose.variation == 0 then
		return 5, 15, 15
	end
	if pose.variation == INTERPOLATE_WITH_SHRINKING_OBJECT then
		return 1, 3, 5
	end
	if pose.variation == INTERPOLATE_MEDIUM_PACE then
		return 2, 6, 5
	end
	if pose.variation == INTERPOLATE_TELEPORT_DEPARTURE then
		return 2, 6, 5
	end
	if pose.variation == INTERPOLATE_TELEPORT_ARRIVAL then
		return 360, 360, 360
	end
	return 1, 3, 1
end

-- Return complement angle that would make an otherwise short rotation
-- take the long way around to reach the same angle.
local function complement_angle(a)
	return (a > 0) and (a - 360) or (a + 360)
end

-- Interpolate current joint positions toward a particular pose in the
-- arm.action_plan list, used by arm.execute_action().
local function interpolate_toward_pose(pose)
	-- Save the initial positions.
	local bottom_arm_start <const> = arm.bottom.arm
	local bottom_hand_start <const> = arm.bottom.hand
	local bottom_opening_start <const> = arm.bottom.opening
	local top_arm_start <const> = arm.top.arm
	local top_hand_start <const> = arm.top.hand
	local top_opening_start <const> = arm.top.opening

	-- Set attachment status.  This parameter is not interpolated.
	arm.bottom_attached = pose.bottom_attached

	-- Compute the amount of rotation needed for each joint.
	local bottom_arm_delta = angle_delta(arm.bottom.arm, pose.bottom.arm)
	local bottom_hand_delta <const> = angle_delta(arm.bottom.hand, pose.bottom.hand)
	local bottom_opening_delta <const> = angle_delta(arm.bottom.opening, pose.bottom.opening)
	local top_arm_delta = angle_delta(arm.top.arm, pose.top.arm)
	local top_hand_delta <const> = angle_delta(arm.top.hand, pose.top.hand)
	local top_opening_delta <const> = angle_delta(arm.top.opening, pose.top.opening)

	-- If the bottom and top arms will incur a collision between the two wrists,
	-- have the top arm take the long way around.
	--
	-- We could get into this situation where the arm is folded like a pretzel
	-- with the action target across the other side of the limb:
	--
	--    #T        T = action target
	--    #
	--    #S----E   S = shoulder
	--    #    /    E = elbow
	--    #  H/     H = hand
	--
	-- Assuming that the lower limb (ES) need to rotate counter-clockwise,
	-- while the smaller angle delta for the upper limb (EH) is rotating
	-- clockwise, the upper wrist will collide with the lower wrist along
	-- this path.  Instead of letting that happen, we will have the upper
	-- limb rotate counter-clockwise along the longer arc.
	--
	-- In theory, MINIMUM_ELBOW_ANGLE should be sufficient margin for flagging
	-- overlaps, but in practice we need the -2 due to boundary conditions
	-- around when arms are tightly folded.  Without this -2, we will observe
	-- some unnecessary long rotations that would have been best avoided.
	if overlapping_rotation(bottom_arm_start, bottom_arm_delta, top_arm_start, top_arm_delta, MINIMUM_ELBOW_ANGLE - 2) then
		if arm.bottom_attached then
			top_arm_delta = complement_angle(top_arm_delta)
		else
			bottom_arm_delta = complement_angle(bottom_arm_delta)
		end
	end

	-- Determine anchor position for animations.
	--
	-- For animation that takes more than one step, we interpolate the joint
	-- angles while holding one of the wrists fixed, such that the elbow
	-- moves radially instead of linearly.
	local anchor_wrist_x, anchor_wrist_y, anchor_key, action_key
	if pose.bottom_attached then
		anchor_wrist_x = pose.elbow_x + wrist_offsets[pose.bottom.arm][1]
		anchor_wrist_y = pose.elbow_y + wrist_offsets[pose.bottom.arm][2]
		anchor_key = "bottom"
		action_key = "top"
	else
		anchor_wrist_x = pose.elbow_x + wrist_offsets[pose.top.arm][1]
		anchor_wrist_y = pose.elbow_y + wrist_offsets[pose.top.arm][2]
		anchor_key = "top"
		action_key = "bottom"
	end

	-- Save initial hand positions, in case if we need to move a captured
	-- object along with it.
	local init_hand_x <const> = arm[action_key].hand_x
	local init_hand_y <const> = arm[action_key].hand_y
	local init_hand_opening <const> = arm[action_key].opening

	-- Optionally capture object with hand.
	if pose.variation == INTERPOLATE_WITH_CAPTURED_OBJECT then
		-- Save image of the captured object.
		arm.action_target.image = world.get_bg_tile_image(arm.action_target.x, arm.action_target.y)
		assert(arm.action_target.image)

		-- Assign captured object to sprite.  Note that we need to fully specify
		-- the orientation and scale here to avoid inheriting the previously
		-- set scale from when gs_captured_object was last used.
		gs_captured_object:setImage(arm.action_target.image, gfx.kImageUnflipped, 1)
		gs_captured_object:setVisible(true)
		gs_captured_object:moveTo(arm.action_target.x, arm.action_target.y)
		if pose.bottom_attached then
			gs_captured_object:setZIndex(Z_TOP_CAPTURED_OBJECT)
		else
			gs_captured_object:setZIndex(Z_BOTTOM_CAPTURED_OBJECT)
		end

		-- Remove captured object from background.
		--
		-- This also updates world.collected_tiles for status display.
		world.remove_collectible_tile(arm.action_target.x, arm.action_target.y)
	elseif pose.variation == INTERPOLATE_WITH_HOLD then
		assert(arm.action_target.ball)
		assert(arm.action_target.ball >= 1)
		assert(arm.action_target.ball <= #world.INIT_BALLS)
		arm.hold = arm.action_target.ball
		if pose.bottom_attached then
			world.update_ball_for_hold(arm.hold, Z_TOP_CAPTURED_OBJECT)
		else
			world.update_ball_for_hold(arm.hold, Z_BOTTOM_CAPTURED_OBJECT)
		end
		world.reset_ball_history(arm.hold)
	end

	-- Optionally summon UFO.
	if pose.variation == INTERPOLATE_TELEPORT_DEPARTURE then
		world.move_ufo(arm.action_target.x, arm.action_target.y)
		world.ufo_count += 1
	end

	-- Compute number of interpolation steps, such that none of the joints
	-- rotate more than a few degrees at each step.
	local max_a1 <const>, max_a2 <const>, max_a3 <const> = max_angular_speed(pose)
	local arm_steps <const> = max(abs(bottom_arm_delta), abs(top_arm_delta)) // max_a1
	local hand_steps <const> = max(abs(bottom_hand_delta), abs(top_hand_delta)) // max_a2
	local finger_steps <const> = max(abs(bottom_opening_delta), abs(top_opening_delta)) // max_a3
	local steps <const> = max(arm_steps, hand_steps, finger_steps)
	if steps > 1 then
		-- Need interpolation since movement takes more than one step.
		for i = 1, (steps - 1) do
			-- Abort animation on reset.
			if world.reset_requested then return end

			-- Update joint angles.
			--
			-- Note that this just interpolates all joint angles simultaneously,
			-- without taking into account of any collisions that might happen
			-- in doing so.  We can be more careful about those by interpolating
			-- the joints serially if we detect that collisions would happen,
			-- but that requires extra collision checks, and isn't always
			-- guaranteed to work anyways.
			--
			-- Rather than worrying about the visual artifacts of collision
			-- during an interpolated motion, we just document that as a feature
			-- and move on.
			arm.bottom.arm = interpolate_angle(bottom_arm_start, bottom_arm_delta, i, steps)
			arm.bottom.hand = interpolate_angle(bottom_hand_start, bottom_hand_delta, i, steps)
			arm.bottom.opening = interpolate_angle(bottom_opening_start, bottom_opening_delta, i, steps)
			arm.top.arm = interpolate_angle(top_arm_start, top_arm_delta, i, steps)
			arm.top.hand = interpolate_angle(top_hand_start, top_hand_delta, i, steps)
			arm.top.opening = interpolate_angle(top_opening_start, top_opening_delta, i, steps)

			-- Update elbow position.
			local a <const> = arm[anchor_key].arm
			arm.elbow_x = anchor_wrist_x - wrist_offsets[a][1]
			arm.elbow_y = anchor_wrist_y - wrist_offsets[a][2]

			-- Draw intermediate step.
			arm.update()
			arm.update_focus()
			world.update()
			world.update_viewport()

			if pose.variation == INTERPOLATE_WITH_CAPTURED_OBJECT then
				local hand_dx <const> = arm[action_key].hand_x - init_hand_x
				local hand_dy <const> = arm[action_key].hand_y - init_hand_y
				gs_captured_object:moveTo(arm.action_target.x + hand_dx, arm.action_target.y + hand_dy)
			elseif pose.variation == INTERPOLATE_WITH_SHRINKING_OBJECT then
				local scale <const> = arm[action_key].opening / init_hand_opening
				gs_captured_object:setImage(arm.action_target.image, gfx.kImageUnflipped, scale)
			end

			gfx.sprite.update()
			assert(debug_frame_rate())
			coroutine.yield()
		end
	end

	-- Apply the target pose values to the arm.
	arm.bottom.arm = pose.bottom.arm
	arm.bottom.hand = pose.bottom.hand
	arm.bottom.opening = pose.bottom.opening
	arm.top.arm = pose.top.arm
	arm.top.hand = pose.top.hand
	arm.top.opening = pose.top.opening
	arm.elbow_x = pose.elbow_x
	arm.elbow_y = pose.elbow_y

	-- Update the final frame.
	arm.update()
	arm.update_focus()
	world.update()
	world.update_viewport()

	if pose.variation == INTERPOLATE_WITH_CAPTURED_OBJECT then
		local hand_dx <const> = arm[action_key].hand_x - init_hand_x
		local hand_dy <const> = arm[action_key].hand_y - init_hand_y
		gs_captured_object:moveTo(arm.action_target.x + hand_dx, arm.action_target.y + hand_dy)
	elseif pose.variation == INTERPOLATE_WITH_SHRINKING_OBJECT then
		gs_captured_object:setVisible(false)
	elseif pose.variation == INTERPOLATE_TELEPORT_DEPARTURE then
		animate_teleport_departure()
	elseif pose.variation == INTERPOLATE_TELEPORT_ARRIVAL then
		animate_teleport_arrival()
	end

	-- If the hand is entering some chain reaction area, trigger the chain
	-- reaction after all other animation are done.
	--
	-- We apply the trigger after all other animation, as opposed to before,
	-- because chain reactions may cause the viewport to scroll quite a bit of
	-- distance away from the hand's final coordinate.  Where this makes a
	-- difference is in the first arrival to Dead End Cave near (7568,4320):
	-- If we trigger chain reaction first, the viewport scroll sequence will
	-- look like this:
	--
	-- 1. Scroll to the right to track the chain reaction.  Initial viewport
	--    position would be the departure teleport station, so it doesn't
	--    quite track the chain reaction well.
	--
	-- 2. Scroll to the left to track arrival of the UFO.  Because most other
	--    teleport stations are to the left of Dead End Cave, the UFO will
	--    arrive from the left and moving right, while the viewport is scrolling
	--    to the left.  This differs from all other teleport station arrivals,
	--    where the viewport scrolls in the same direction as UFO movement.
	--
	-- Basically, both scroll sequences felt inconsistent.
	--
	-- With the current order, first arrival to Dead End Cave looks like this:
	--
	-- 1. Scroll to teleport station (usually from left to right).
	-- 2. Show only UFO (arm is hidden behind foreground layer).
	-- 3. Scroll to the right to track the chain reaction.  Initial viewport
	--    position is the arrival teleport station, so this tracks the chain
	--    reaction more consistently.
	local end_wrist <const> = wrist_offsets[pose[action_key].arm]
	local end_hand <const> = hand_offsets[pose[action_key].hand]
	world.area_trigger(
		pose.elbow_x + end_wrist[1] + end_hand[1],
		pose.elbow_y + end_wrist[2] + end_hand[2],
		arm.update)

	gfx.sprite.update()
end

-- Reset hint images.
local function reset_tile_hints()
	idle_timer = 0
	hint_table = {}
end

-- Animate hint images.
local function animate_tile_hints()
	-- Expire old hints after 4 frames.
	while #hint_table > 0 and hint_table[1][1] > 5 do
		table.remove(hint_table, 1)
	end

	-- Draw cursors that blink white and black.
	for i = 1, #hint_table do
		local entry <const> = hint_table[i]
		if (entry[1] & 1) == 0 then
			gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
		else
			gfx.setImageDrawMode(gfx.kDrawModeFillBlack)
		end
		gs_hint_cursors[entry[4]]:drawCentered(entry[2], entry[3])
		entry[1] += 1
	end

	-- Always return draw mode to "copy" when we are done.
	--
	-- This is the convention we have adopted: in all functions that calls
	-- setImageDrawMode, we will always exit the function with draw mode set
	-- to copy, since that's the mode expected in most other places.
	-- In particular, if we didn't restore "copy" mode here, the help popups
	-- in main.lua will appear broken.
	gfx.setImageDrawMode(gfx.kDrawModeCopy)
end

--}}}

----------------------------------------------------------------------
--{{{ Pose and collision functions.

-- Check if a coordinate value is within world range.
local function within_world_x_range(x)
	return HAND_RADIUS < x and x < world.WIDTH - HAND_RADIUS
end
local function within_world_y_range(y)
	return HAND_RADIUS < y and y < world.HEIGHT - HAND_RADIUS
end

-- Test for collision along a straight line.  Returns true if some sampled
-- point along the line would collide with the world.
local function line_collision(x0, y0, dx, dy)
	-- Step along the major axis of the line in 16 pixel increments.  Because
	-- tile sizes are 32, the expectation is that a step size of 16 will allow
	-- us to hit all tiles along the way.
	--
	-- It's possible to create a scenario where a line grazes a tile without
	-- colliding with it, especially if the tile is triangular, but generally
	-- we expect those scenarios to be rare because the walls are mostly thick
	-- and concave.
	local steps <const> = floor(max(abs(dx), abs(dy)) / 16) + 1
	assert(steps > 0)
	for i = 0, steps do
		-- Convert coordinates to integer before doing collision test.  Here
		-- we would gain a bit more accuracy if we were calling round() instead
		-- of floor(), but we are trading that ~1 pixel of accuracy for a few
		-- nanoseconds of speedup.
		local x <const> = floor(x0 + dx * i / steps)
		local y <const> = floor(y0 + dy * i / steps)
		if collide_with_world(x, y) then
			return true
		end
	end
	return false
end

-- Same as line_collision, but also collect all colliding points.
local function line_collision_with_collection(points, x0, y0, dx, dy)
	local steps <const> = floor(max(abs(dx), abs(dy)) / 16) + 1
	assert(steps > 0)
	for i = 0, steps do
		local x <const> = floor(x0 + dx * i / steps)
		local y <const> = floor(y0 + dy * i / steps)
		if collide_with_world(x, y) then
			table.insert(points, {x, y})
		end
	end
end

-- Test for collision along a single limb.  Returns true if some sampled
-- point along the limb would collide with the world.
local function limb_collision(elbow_x, elbow_y, wrist_x, wrist_y)
	-- The line segment that runs from elbow to wrist is the center of the
	-- limb.  Rotating that 90 degrees would give us a vector that is
	-- perpendicular to the center.
	local dx <const> = wrist_x - elbow_x
	local dy <const> = wrist_y - elbow_y
	local offset_x <const> = -dy * ARM_LENGTH_TO_HALF_WIDTH_MULTIPLIER
	local offset_y <const> = dx * ARM_LENGTH_TO_HALF_WIDTH_MULTIPLIER

	-- Compute the starting coordinates of two segments that are parallel
	-- along the limb.
	local sx0 <const> = elbow_x + offset_x
	local sy0 <const> = elbow_y + offset_y
	local sx1 <const> = elbow_x - offset_x
	local sy1 <const> = elbow_y - offset_y

	-- Step along the two segments and check if any point resulted in collision
	-- with the world.
	--
	-- In theory, we only have to test one of these two line segments for
	-- collision, since only one side of the arm is moving toward a wall.
	-- But deciding on which side to test is slightly complicated, so we test
	-- both sides.
	return line_collision(sx0, sy0, dx, dy) or line_collision(sx1, sy1, dx, dy)
end

-- Same as limb_collision, but also collect all colliding points.
local function limb_collision_with_collection(points, elbow_x, elbow_y, wrist_x, wrist_y)
	local dx <const> = wrist_x - elbow_x
	local dy <const> = wrist_y - elbow_y
	local offset_x <const> = -dy * ARM_LENGTH_TO_HALF_WIDTH_MULTIPLIER
	local offset_y <const> = dx * ARM_LENGTH_TO_HALF_WIDTH_MULTIPLIER

	local sx0 <const> = elbow_x + offset_x
	local sy0 <const> = elbow_y + offset_y
	local sx1 <const> = elbow_x - offset_x
	local sy1 <const> = elbow_y - offset_y

	line_collision_with_collection(points, sx0, sy0, dx, dy)
	line_collision_with_collection(points, sx1, sy1, dx, dy)
end


-- Test for joint collisions for elbow, wrist, and hand.  Returns true if
-- there is a collision.
local function joint_collision(elbow_x, elbow_y, upper_wrist_x, upper_wrist_y, upper_hand_x, upper_hand_y)
	assert(elbow_x == floor(elbow_x))
	assert(elbow_y == floor(elbow_y))
	assert(upper_wrist_x == floor(upper_wrist_x))
	assert(upper_wrist_y == floor(upper_wrist_y))
	assert(upper_hand_x == floor(upper_hand_x))
	assert(upper_hand_y == floor(upper_hand_y))

	-- Check if any of the joints collide with the world by testing 8 points
	-- around each joint.  This is a good enough approximation since all the
	-- world surfaces angled in one of 8 directions, so this approximation
	-- is optimal against all concave walls.
	--
	-- Convex walls is a bit of problem if the corners land right between
	-- two test points.  Expected maximum error is about ~7 pixels worth,
	-- which doesn't seem like a lot, but where it shows up is that there
	-- are some corner tiles where the hand would collide if it were moving
	-- slowly, but would pass right through when moving at faster speed.
	-- Some ways to deal with those corners:
	--
	--  + Increase the number of approximation points to make them less likely.
	--  + Do proper circle-polygon intersection tests near those corners.
	--  + Just ignore those and design the levels to make sharp corners rare.
	--
	-- We are going with the last option here because it seems most practical.
	--
	-- An earlier implementation had extra code to detect where all the
	-- convex corners are, and mark those in the map so that we might be
	-- extra careful in detecting those.  The problem is that in order to
	-- know which tiles needs extra care, we would have already done collision
	-- checks against those tiles -- because we are iterating over 3 joints to
	-- to find which of the 60000 tiles to test, as opposed to iterating over
	-- 60000 tiles to test against 3 joints.  Anyways, we haven't found a
	-- good reason to add special handing for corners.
	for i = 1, 8 do
		if collide_with_world(upper_hand_x + hand_test_points[i][1],
		                      upper_hand_y + hand_test_points[i][2]) or
		   collide_with_world(upper_wrist_x + wrist_test_points[i][1],
		                      upper_wrist_y + wrist_test_points[i][2]) or
		   collide_with_world(elbow_x + elbow_test_points[i][1],
		                      elbow_y + elbow_test_points[i][2]) then
			return true
		end
	end
	return false
end

-- Same as joint_collision, but also collect all colliding points.
local function joint_collision_with_collection(points, elbow_x, elbow_y, upper_wrist_x, upper_wrist_y, upper_hand_x, upper_hand_y)
	for i = 1, 8 do
		local x = upper_hand_x + hand_test_points[i][1]
		local y = upper_hand_y + hand_test_points[i][2]
		if collide_with_world(x, y) then
			table.insert(points, {x, y})
		end
		x = upper_wrist_x + wrist_test_points[i][1]
		y = upper_wrist_y + wrist_test_points[i][2]
		if collide_with_world(x, y) then
			table.insert(points, {x, y})
		end
		x = elbow_x + elbow_test_points[i][1]
		y = elbow_y + elbow_test_points[i][2]
		if collide_with_world(x, y) then
			table.insert(points, {x, y})
		end
	end
end

-- Similar to joint_collision, but only check the elbow.  Returns true if
-- there is a collision.
--
-- There isn't a elbow_collision_with_collection, because this function is
-- only used for testing intermediate poses.  During normal operations,
-- elbow collision points are covered by joint_collision_with_collection.
local function elbow_collision(elbow_x, elbow_y)
	for i = 1, 8 do
		if collide_with_world(elbow_x + elbow_test_points[i][1],
		                      elbow_y + elbow_test_points[i][2]) then
			return true
		end
	end
	return false
end

-- Test for collision of the ball that is currently held by the hand.
local function ball_collision(ball_x, ball_y)
	for i = 1, 8 do
		if collide_with_world(ball_x + ball_test_points[i][1],
		                      ball_y + ball_test_points[i][2]) then
			return true
		end
	end
	return false
end

-- Same as ball_collision, but also collect all colliding points.
local function ball_collision_with_collection(points, ball_x, ball_y)
	for i = 1, 8 do
		local x <const> = ball_x + ball_test_points[i][1]
		local y <const> = ball_y + ball_test_points[i][2]
		if collide_with_world(x, y) then
			table.insert(points, {x, y})
		end
	end
end

-- Get relationship of crank to {shoulder,elbow,wrist} rotations based on
-- joint mode and active joint selection.
local function get_joint_direction(elbow, lower_wrist, upper_wrist)
	if arm.joint_mode == JOINT_PPP or arm.joint_mode == JOINT_W_P then
		if lower_wrist and elbow then
			return 1, -1, 1
		elseif elbow and upper_wrist then
			return 1, 1, -1
		else
			return 1, 1, 1
		end
	elseif arm.joint_mode == JOINT_NNN or arm.joint_mode == JOINT_W_N then
		if lower_wrist and elbow then
			return -1, 1, -1
		elseif elbow and upper_wrist then
			return -1, -1, 1
		else
			return -1, -1, -1
		end
	elseif arm.joint_mode == JOINT_PNP then
		return 1, -1, 1
	else
		assert(arm.joint_mode == JOINT_NPN)
		return -1, 1, -1
	end
end

-- Compute all joint angles for an attempted update.
local function compute_joint_angles(lower, upper, delta_crank, elbow, lower_wrist, upper_wrist)
	local d1 <const>, d2 <const>, d3 <const> =
		get_joint_direction(elbow, lower_wrist, upper_wrist)

	local cumulative_angle = lower_wrist and d1 * delta_crank or 0
	local shoulder_angle <const> = normalize_angle(lower.arm + cumulative_angle)

	cumulative_angle += elbow and d2 * delta_crank or 0
	local elbow_angle <const> = normalize_angle(upper.arm + cumulative_angle)

	cumulative_angle += upper_wrist and d3 * delta_crank or 0
	local hand_angle <const> = normalize_angle(upper.hand + cumulative_angle)

	return shoulder_angle, elbow_angle, hand_angle
end

-- Compute all joint positions for an attempted update.
local function compute_joint_positions(lower_wrist_x, lower_wrist_y, shoulder_angle, elbow_angle, hand_angle)
	assert(lower_wrist_x == floor(lower_wrist_x))
	assert(lower_wrist_y == floor(lower_wrist_y))

	local elbow_x <const> = lower_wrist_x - wrist_offsets[shoulder_angle][1]
	local elbow_y <const> = lower_wrist_y - wrist_offsets[shoulder_angle][2]
	assert(elbow_x == floor(elbow_x))
	assert(elbow_y == floor(elbow_y))

	local upper_wrist_x <const> = elbow_x + wrist_offsets[elbow_angle][1]
	local upper_wrist_y <const> = elbow_y + wrist_offsets[elbow_angle][2]
	assert(upper_wrist_x == floor(upper_wrist_x))
	assert(upper_wrist_y == floor(upper_wrist_y))

	local upper_hand_x <const> = upper_wrist_x + hand_offsets[hand_angle][1]
	local upper_hand_y <const> = upper_wrist_y + hand_offsets[hand_angle][2]
	assert(upper_hand_x == floor(upper_hand_x))
	assert(upper_hand_y == floor(upper_hand_y))

	return elbow_x, elbow_y, upper_wrist_x, upper_wrist_y, upper_hand_x, upper_hand_y
end

-- Test crank rotation configuration.  Returns true if configuration is valid.
local function try_joint_update(lower, upper, delta_crank, elbow, lower_wrist, upper_wrist)
	-- Compute joint angles.
	local shoulder_angle <const>, elbow_angle <const>, hand_angle <const> =
		compute_joint_angles(lower, upper, delta_crank, elbow, lower_wrist, upper_wrist)

	-- Verify that the upper wrist does not collide with the lower wrist.
	-- We only need the elbow angle to do this, since the shape of the arm
	-- parts are constant.  We do this first since it's cheap to do, but
	-- this particular collision probably doesn't happen often since players
	-- usually don't need the wrist to be near the shoulder.
	--
	-- Another alternative is to don't do this check at all.  If we remove
	-- this check and also the hand-wrist collision check, the elbow would
	-- be able to rotate a full circle.  We don't want that because that
	-- would allow both hands to potentially mount at the exact same tile,
	-- which will cause trouble when the user is trying to do perform an
	-- attach-detach command.
	if abs(angle_delta(shoulder_angle, elbow_angle)) < MINIMUM_ELBOW_ANGLE then
		return false
	end

	-- Compute all the joint positions.
	local lower_wrist_x <const> = lower.wrist_x
	local lower_wrist_y <const> = lower.wrist_y

	local elbow_x <const>, elbow_y <const>,
	      upper_wrist_x <const>, upper_wrist_y <const>,
	      upper_hand_x <const>, upper_hand_y <const> =
		compute_joint_positions(lower_wrist_x, lower_wrist_y,
		                        shoulder_angle, elbow_angle, hand_angle)

	if joint_collision(elbow_x, elbow_y, upper_wrist_x, upper_wrist_y, upper_hand_x, upper_hand_y) then
		return false
	end

	-- Test for limb collisions.
	--
	-- Only the upper limb is checked.  The lower lib is ignored because
	-- the shoulder is embedded in the wall when mounted, so the limb will
	-- have a high likelihood of colliding with the wall.
	if limb_collision(elbow_x, elbow_y, upper_wrist_x, upper_wrist_y) then
		return false
	end

	-- If we are currently holding a ball, we need to check that the ball
	-- does not collide with the world, otherwise we can end up in a
	-- situation where the ball is embedded in a wall and there is no way
	-- to get it back out.
	if arm.hold > 0 then
		local ball_x <const> = 2 * upper_hand_x - upper_wrist_x
		local ball_y <const> = 2 * upper_hand_y - upper_wrist_y
		if ball_collision(ball_x, ball_y) then
			return false
		end
	end

	-- One thing we explicitly allow is hand-wrist collision, i.e. the free
	-- moving hand is allowed to touch the mounted wrist.  We need to allow
	-- these because the poses required to get the robot arm across a single
	-- tile ledge will trip over these collisions.
	return true
end

-- Wrapper to try_joint_update to select test angles.
local function try_joint_update_based_on_attachment(delta_crank, elbow, bottom_wrist, top_wrist)
	if arm.bottom_attached then
		-- bottom->elbow->top chain.
		return try_joint_update(arm.bottom, arm.top, delta_crank, elbow, bottom_wrist, top_wrist)
	else
		-- top->elbow->bottom chain.
		return try_joint_update(arm.top, arm.bottom, delta_crank, elbow, top_wrist, bottom_wrist)
	end
end

-- Table to reduce step size for find_closest_valid_crank_position.
-- Integer division by 2 would almost work, but Lua truncates toward
-- negative infinity instead of rounding toward zero.
local REDUCE_STEP <const> =
{
	[12] = 6, [-12] = -6,
	[11] = 5, [-11] = -5,
	[10] = 5, [-10] = -5,
	[9] = 4,  [-9] = -4,
	[8] = 4,  [-8] = -4,
	[7] = 3,  [-7] = -3,
	[6] = 3,  [-6] = -3,
	[5] = 2,  [-5] = -2,
	[4] = 2,  [-4] = -2,
	[3] = 1,  [-3] = -1,
	[2] = 1,  [-2] = -1,
	[1] = 0,  [-1] = 0,
}

-- Find a crank angle that is closest to actual crank position, but does
-- not collide with anything along the rotational path.
local function find_closest_valid_crank_position(crank, elbow, bottom_wrist, top_wrist)
	-- In theory, we should be able to analytically compute the intersection
	-- of the arc formed by the joints with whatever obstacle is there, but
	-- that's a bit complicated to do.  Instead of that, we incrementally
	-- rotate toward the desired angle, and stop when we find an angle that
	-- doesn't work.
	--
	-- We could naively do this in 1-degree increments, but since the end
	-- of arm does not overlap when we rotate the fully extended arm by
	-- up to 12-degree increments, we will try to take larger steps starting
	-- at 12 degrees, then fall back to smaller degrees when we find a
	-- collision.
	local delta_crank <const> = angle_delta(arm.previous_crank_position, crank)
	assert(normalize_angle(crank) == normalize_angle(arm.previous_crank_position + delta_crank))
	local abs_delta_crank <const> = abs(delta_crank)
	local d = 0
	local step = delta_crank > 0 and 12 or -12
	while true do
		if abs(d + step) > abs_delta_crank then
			-- If we would overshoot the desired delta in the next step, make
			-- sure the next step lands on that delta.
			step = delta_crank - d
		else
			if try_joint_update_based_on_attachment(d + step, elbow, bottom_wrist, top_wrist) then
				-- Next step is valid.
				d += step
				if d == delta_crank then
					-- All steps are valid.
					break
				end
			else
				-- Next step is not valid, reduce step size.
				step = REDUCE_STEP[step]
				if step == 0 then
					-- No smaller step available, 'd' holds the largest valid delta.
					break
				end
			end
		end
	end
	return normalize_angle(arm.previous_crank_position + d)
end

-- Synchronize deltas to current joint positions.
local function synchronize_deltas(crank)
	assert(crank == normalize_angle(floor(crank)))
	assert(arm.bottom.arm == normalize_angle(arm.bottom.arm))
	assert(arm.bottom.hand == normalize_angle(arm.bottom.hand))
	assert(arm.top.arm == normalize_angle(arm.top.arm))
	assert(arm.top.hand == normalize_angle(arm.top.hand))

	arm.bottom.arm_crank_positive_delta = normalize_angle(arm.bottom.arm - crank)
	arm.bottom.arm_crank_negative_delta = normalize_angle(arm.bottom.arm + crank)
	arm.bottom.hand_crank_positive_delta = normalize_angle(arm.bottom.hand - crank)
	arm.bottom.hand_crank_negative_delta = normalize_angle(arm.bottom.hand + crank)
	arm.top.arm_crank_positive_delta = normalize_angle(arm.top.arm - crank)
	arm.top.arm_crank_negative_delta = normalize_angle(arm.top.arm + crank)
	arm.top.hand_crank_positive_delta = normalize_angle(arm.top.hand - crank)
	arm.top.hand_crank_negative_delta = normalize_angle(arm.top.hand + crank)

	arm.previous_crank_position = normalize_angle(crank)
end

--}}}

----------------------------------------------------------------------
--{{{ Joint actions.

-- Check for equality with a certain tolerance.
local function roughly_equals(a, b, margin)
	return abs(a - b) <= margin
end

-- Check if distance between two points is roughly arm length.
-- This is for testing solve_pose().
local function test_expected_arm_length(ax, ay, bx, by)
	return roughly_equals(
		distance2(ax - bx, ay - by), ARM_LENGTH * ARM_LENGTH, 2)
end

-- Given an elbow position and target wrist positions, return a tuple
-- of {elbow_x,elbow_y,lower_arm,upper_arm} that covers the wrist positions.
local function solve_arm_angles(ex, ey, lower_wrist_x, lower_wrist_y, upper_wrist_x, upper_wrist_y)
	assert(ex == floor(ex))
	assert(ey == floor(ey))
	assert(lower_wrist_x == floor(lower_wrist_x))
	assert(lower_wrist_y == floor(lower_wrist_y))
	assert(upper_wrist_x == floor(upper_wrist_x))
	assert(upper_wrist_y == floor(upper_wrist_y))

	-- Solve for arm angles, and also check resulting elbow angle range to avoid
	-- collision between the two wrists.
	--
	-- The simulator sampler says "atan2" is a bottleneck in our arm movements.
	-- We could try to optimize atan2 by caching the results (since we have
	-- limited offsets that we feed to atan2), but rather than optimizing atan2,
	-- a better optimization is done at a higher level in caching the action
	-- plans.  See check_and_cache_action.
	local lower_arm = atan2(lower_wrist_y - ey, lower_wrist_x - ex)
	local upper_arm = atan2(upper_wrist_y - ey, upper_wrist_x - ex)
	assert(roughly_equals(ex + ARM_LENGTH * cos(lower_arm), lower_wrist_x, 2))
	assert(roughly_equals(ey + ARM_LENGTH * sin(lower_arm), lower_wrist_y, 2))
	assert(roughly_equals(ex + ARM_LENGTH * cos(upper_arm), upper_wrist_x, 2))
	assert(roughly_equals(ey + ARM_LENGTH * sin(upper_arm), upper_wrist_y, 2))
	lower_arm = normalize_angle(round(lower_arm * rad2deg))
	upper_arm = normalize_angle(round(upper_arm * rad2deg))
	if abs(angle_delta(lower_arm, upper_arm)) < MINIMUM_ELBOW_ANGLE then
		return nil, nil, nil, nil
	end

	-- In theory, the input elbow position should be fixed, and we are only
	-- solving for the angle of that to the lower and upper wrists.  But due
	-- to numerical imprecision, the angle we found could end up leaving the
	-- lower wrist floating.  It looks annoying visually to have that one
	-- pixel gap at the mount point, but the really annoying part is going to
	-- be not being able to restore saved state because the state loader
	-- couldn't confirm that the wrist was mounted properly.
	--
	-- To compensate for a potential floating wrist, we recompute the new
	-- position of the lower wrist using the computed lower_arm angle.  If
	-- we detected a shift there, we will apply the shift to the elbow, such
	-- that the lower wrist remains mounted on the wall at where it should be.
	local test_lower_wrist_x <const> = ex + wrist_offsets[lower_arm][1]
	local test_lower_wrist_y <const> = ey + wrist_offsets[lower_arm][2]
	ex -= test_lower_wrist_x - lower_wrist_x
	ey -= test_lower_wrist_y - lower_wrist_y

	return ex, ey, lower_arm, upper_arm
end

-- Empty solution for solve_pose.
local NO_SOLUTION <const> = {nil, nil, nil, nil}

-- Given current elbow position and two target wrist positions, return
-- new elbow position and two arm angles need to cover those positions.
-- Return all nil if pose is not possible.  Collision is not checked.
--
-- Input:
--   elbow_{x,y} = current elbow position, used as a hint.
--   {lower,upper}_wrist_{x,y} = target wrist positions.
--
-- Returns two tuples, each containing 4 elements:
--   elbow_{x,y} = elbow position needed to cover both targets.
--   {lower,upper}_arm = arm angle from elbow to wrist in degrees.
--
-- If no suitable pose is found, NO_SOLUTION is returned.
local function solve_pose(elbow_x, elbow_y, lower_wrist_x, lower_wrist_y, upper_wrist_x, upper_wrist_y)
	-- We don't need a fully featured inverse kinematics solver since our
	-- joint setup is very simple, and we can get by with a bespoke solver
	-- with only 2 sqrt and 2 atan2 calls.
	--
	-- Let E be the elbow joint we want to solve, and B+T are the target
	-- wrist positions, the three points form an isosceles triangle:
	--
	--              E
	--           ---|---
	--        ---   |   ---
	--     ---      |      ---
	--    B---------M---------T
	--
	-- It's isosceles because the two arms are of equal length.  Thus E lies
	-- on the perpendicular bisector of BT.  EB and ET are our arm lengths,
	-- and EM can be solved using Pythagoras theorem.
	local mx <const> = (lower_wrist_x + upper_wrist_x) / 2
	local my <const> = (lower_wrist_y + upper_wrist_y) / 2
	local dx <const> = mx - lower_wrist_x
	local dy <const> = my - lower_wrist_y
	local bm2 <const> = distance2(dx, dy)
	if bm2 < WRIST_RADIUS * WRIST_RADIUS or bm2 > ARM_LENGTH * ARM_LENGTH then
		-- Target positions are not reachable, either because the two points
		-- overlap, or because the two points are more than two arms length away.
		return NO_SOLUTION, NO_SOLUTION
	end
	local em <const> = sqrt(ARM_LENGTH * ARM_LENGTH - bm2)

	-- Compute direction of perpendicular bisector.
	local bm <const> = sqrt(bm2)
	local nx <const> = -dy / bm
	local ny <const> = dx / bm

	-- Compute the two candidates for elbow position.
	local ex1 <const> = mx + nx * em
	local ey1 <const> = my + ny * em
	local ex2 <const> = mx - nx * em
	local ey2 <const> = my - ny * em
	assert(test_expected_arm_length(ex1, ey1, lower_wrist_x, lower_wrist_y))
	assert(test_expected_arm_length(ex2, ey2, lower_wrist_x, lower_wrist_y))
	assert(test_expected_arm_length(ex1, ey1, upper_wrist_x, upper_wrist_y))
	assert(test_expected_arm_length(ex2, ey2, upper_wrist_x, upper_wrist_y))

	-- Sort two elbow candidates based on distance to current elbow.
	local near_ex, near_ey, far_ex, far_ey
	if distance2(elbow_x - ex1, elbow_y - ey1) < distance2(elbow_x - ex2, elbow_y - ey2) then
		near_ex = round(ex1)
		near_ey = round(ey1)
		far_ex = round(ex2)
		far_ey = round(ey2)
	else
		near_ex = round(ex2)
		near_ey = round(ey2)
		far_ex = round(ex1)
		far_ey = round(ey1)
	end

	-- Compute the arm angles and return both solutions.
	--
	-- We could have returned just the one solution with (near_ex,near_ey).
	-- The effect of that would be that some poses that are feasible aren't
	-- accepted, because user did not have the arm bent the right way.
	-- Even if the user is familiar with how the joint solver works, this is
	-- a constant source of annoyance to have to prepare the arm with the
	-- right direction of joints.  Rather than forcing users to develop that
	-- habit, we just return both solutions here and have
	-- solve_pose_and_check_collisions pick the right one.
	return {solve_arm_angles(near_ex, near_ey,
	                         lower_wrist_x, lower_wrist_y,
	                         upper_wrist_x, upper_wrist_y)},
	       {solve_arm_angles(far_ex, far_ey,
	                         lower_wrist_x, lower_wrist_y,
	                         upper_wrist_x, upper_wrist_y)}
end

-- Check configuration for elbow collisions, returns true on success.
local function check_elbow_collision(solution)
	local ex <const> = solution[1]
	if not ex then
		return false
	end
	assert(solution[2])
	assert(solution[3])
	assert(solution[4])
	local ey <const> = solution[2]
	return not elbow_collision(ex, ey)
end

-- Check configuration for joint and limb collisions, returns true on success.
local function check_joint_and_limb_collision(solution, hand_angle)
	local ex <const> = solution[1]
	if not ex then
		return false
	end
	assert(solution[2])
	assert(solution[3])
	assert(solution[4])
	local ey <const> = solution[2]
	local upper_arm <const> = solution[4]
	local upper_wrist_x <const> = ex + wrist_offsets[upper_arm][1]
	local upper_wrist_y <const> = ey + wrist_offsets[upper_arm][2]
	local upper_hand_x <const> = upper_wrist_x + hand_offsets[hand_angle][1]
	local upper_hand_y <const> = upper_wrist_y + hand_offsets[hand_angle][2]
	return not (joint_collision(ex, ey,
	                            upper_wrist_x, upper_wrist_y,
	                            upper_hand_x, upper_hand_y) or
	            limb_collision(ex, ey, upper_wrist_x, upper_wrist_y))
end

-- Check for path between old and new elbow positions, and make sure it's
-- not going through a wall.  This is to avoid a situation like this:
--
--       #############
--         S       H             E--         S = shoulder
--          --    /     ->      /   --H      E = elbow
--            -- /          ###/#########    H = hand
--              E             S              # = wall
--
-- None of the arm elements are in collision except the lower limb, but
-- lower limb is not eligible for collision checks (otherwise the lower
-- limb would be in constant collision near the mount point).  Despite
-- the lack of collisions, this is a pose we want to avoid because the
-- arm is stuck, being locked by two joints that are on opposite sides
-- of a wall.  We don't want to get into a pose that we can't get out of,
-- hence this extra collision check for elbow path.
--
-- This problem generally happens when attempting to reach a target pose
-- with the "far" solution returned by solve_pose().  See comments in
-- solve_pose() on why we attempt both near and far solutions.
local function check_elbow_path(ex0, ey0, ex1, ey1)
	-- Here we are checking the linear path moved by the elbow, which is
	-- good enough despite the actual path being radial.  There are no
	-- false positives because the triangular area formed by the linear
	-- path is smaller than the pie-shaped area swept by lower arm, and
	-- there should be few false negatives because the extended path should
	-- be covered by the area swept by the upper arm.
	return not line_collision(ex0, ey0, ex1 - ex0, ey1 - ey0)
end

-- Wrapper around solve_pose to pick the set of arm configuration that is
-- free of collisions.
local function solve_pose_and_check_collisions(elbow_x, elbow_y, bottom_wrist_x, bottom_wrist_y, top_wrist_x, top_wrist_y, hand_angle, check_elbow_only)
	local s_near <const>, s_far <const> = solve_pose(elbow_x, elbow_y, bottom_wrist_x, bottom_wrist_y, top_wrist_x, top_wrist_y)
	assert((not s_near[1]) or #s_near == 4)
	assert((not s_far[1]) or #s_far == 4)
	if check_elbow_only then
		if check_elbow_collision(s_near) and
		   check_elbow_path(elbow_x, elbow_y, s_near[1], s_near[2]) then
			return s_near[1], s_near[2], s_near[3], s_near[4]
		end
		if check_elbow_collision(s_far) and
		   check_elbow_path(elbow_x, elbow_y, s_far[1], s_far[2]) then
			return s_far[1], s_far[2], s_far[3], s_far[4]
		end
	else
		if check_joint_and_limb_collision(s_near, hand_angle) and
		   check_elbow_path(elbow_x, elbow_y, s_near[1], s_near[2]) then
			return s_near[1], s_near[2], s_near[3], s_near[4]
		end
		if check_joint_and_limb_collision(s_far, hand_angle) and
		   check_elbow_path(elbow_x, elbow_y, s_far[1], s_far[2]) then
			return s_far[1], s_far[2], s_far[3], s_far[4]
		end
	end
	return nil, nil, nil, nil
end

-- Return keys to arm{} structure based on attachment status.
local function get_arm_parts()
	if arm.bottom_attached then
		return "bottom", "top"
	else
		return "top", "bottom"
	end
end

-- Check a mount position for feasibility based on arm.action_target.
-- Returns true if all intermediate poses are valid.
-- arm.action_plan is populated on success.
--
-- Note that while all poses along the steps of action_plan are valid, some
-- of the interpolated steps will incur visible collisions.  This is working
-- as intended: what we want with these checks is to avoid non-reversible
-- poses that player can get into but can't get out of, and not so much the
-- fact that some collisions might happen while getting in and out of these
-- poses.
--
-- We don't want to reject a pose because trivial interpolation of joint
-- angles would result in collisions.  Of course it would be nice if we have
-- a more clever interpolation scheme that avoids those collisions, but this
-- is something that we just accept as a feature and move on.
local function check_mount_poses()
	local a <const>, b <const> = get_arm_parts()
	local lower <const> = arm[a]
	local upper <const> = arm[b]

	-- Compute key wrist positions.
	assert(arm.action_target)
	local t <const> = arm.action_target
	local mount_x <const> = t.x
	local mount_y <const> = t.y
	assert(approach_offsets[t.a])
	local mount_approach_x <const> = mount_x + approach_offsets[t.a][1]
	local mount_approach_y <const> = mount_y + approach_offsets[t.a][2]
	local unmount_x <const> = lower.wrist_x
	local unmount_y <const> = lower.wrist_y
	assert(approach_offsets[lower.hand])
	local unmount_retreat_x <const> = unmount_x + approach_offsets[lower.hand][1]
	local unmount_retreat_y <const> = unmount_y + approach_offsets[lower.hand][2]

	-- Here we can do an early check to see if the upper wrist would collide
	-- with the world when travelling from its current location to mount
	-- approach direction.  We can call line_collision() for this purpose,
	-- but it's not useful:
	--
	-- - The wrist usually travels a short distance (+/-2 tiles), so in general
	--   we don't expect any collision along the way.
	--
	-- - Around certain corners, we might see a false positive with the wrist
	--   colliding along the linear path between source and destination, but
	--   the wrist actually travels along a epicycloid that might very well
	--   have avoided the corner.  Having these false positives will make
	--   maneuvering around corners difficult.
	--
	-- Instead of checking the upper wrist for such collisions, we will check
	-- the elbow later.

	-- Step 1: Move hand to approach position.
	local ex1 <const>, ey1 <const>, la1 <const>, ua1 <const> =
		solve_pose_and_check_collisions(arm.elbow_x, arm.elbow_y,
		                                unmount_x, unmount_y,
		                                mount_approach_x, mount_approach_y,
		                                t.a,
		                                false)
	if not ex1 then
		return false
	end
	local step1 <const> =
	{
		elbow_x = ex1,
		elbow_y = ey1,
		bottom_attached = arm.bottom_attached,
		[a] =
		{
			arm = la1,
			hand = lower.hand,
			opening = 90,
		},
		[b] =
		{
			arm = ua1,
			hand = t.a,
			opening = 0,
		},
		variation = 0,
	}

	-- Step 2: Open hand.
	local step2 <const> =
	{
		elbow_x = ex1,
		elbow_y = ey1,
		bottom_attached = arm.bottom_attached,
		[a] = step1[a],
		[b] =
		{
			arm = ua1,
			hand = t.a,
			opening = 90,
		},
		variation = 0,
	}

	-- Step 3: Attach upper hand to wall.
	local ex3 <const>, ey3 <const>, la3 <const>, ua3 <const> =
		solve_pose_and_check_collisions(ex1, ey1,
		                                unmount_x, unmount_y,
		                                mount_x, mount_y,
		                                t.a,
		                                true)
	if not ex3 then
		return false
	end
	local step3 <const> =
	{
		elbow_x = ex3,
		elbow_y = ey3,
		bottom_attached = arm.bottom_attached,
		[a] =
		{
			arm = la3,
			hand = lower.hand,
			opening = 90,
		},
		[b] =
		{
			arm = ua3,
			hand = t.a,
			opening = 90,
		},
		variation = 0,
	}

	-- Step 4: Detach lower hand from wall, invert attachment flag.
	-- Note how the order of the arguments and the returned values are
	-- swapped from earlier calls due to inverted attachment.
	--
	-- We check for lower wrist retreat position for collision, which is
	-- symmetric to how we check upper wrist approach position.  In theory,
	-- we shouldn't need to do this because the lower wrist must have passed
	-- through its retreat position when it was previously mounted, so this
	-- test should always succeed.  But we do it anyways because in practice,
	-- the mount-unmount cycle isn't always repeatable, and sometimes the wrist
	-- will end up a few pixels off from where it originally was when mounted.
	local ex4 <const>, ey4 <const>, ua4 <const>, la4 <const> =
		solve_pose_and_check_collisions(ex3, ey3,
		                                mount_x, mount_y,
		                                unmount_retreat_x, unmount_retreat_y,
		                                lower.hand,
		                                false)
	if not ex4 then
		return false
	end
	local step4 <const> =
	{
		elbow_x = ex4,
		elbow_y = ey4,
		bottom_attached = (not arm.bottom_attached),
		[a] =
		{
			arm = la4,
			hand = lower.hand,
			opening = 90,
		},
		[b] =
		{
			arm = ua4,
			hand = t.a,
			opening = 90,
		},
		variation = 0,
	}

	-- Step 5: Close lower hand.
	local step5 <const> =
	{
		elbow_x = ex4,
		elbow_y = ey4,
		bottom_attached = (not arm.bottom_attached),
		[a] =
		{
			arm = la4,
			hand = lower.hand,
			opening = 0,
		},
		[b] = step4[b],
		variation = 0,
	}

	arm.action_plan = {step1, step2, step3, step4, step5}
	return true
end

-- Check an collect position for feasibility based on arm.action_target.
-- Returns true if all intermediate poses are valid.
-- arm.action_plan is populated on success.
local function check_collect_pose()
	local a, b = get_arm_parts()
	local lower = arm[a]
	local upper = arm[b]

	-- Compute key wrist positions.
	local shoulder_x = lower.wrist_x
	local shoulder_y = lower.wrist_y
	assert(arm.action_target)
	local t = arm.action_target
	local collect_x = t.x
	local collect_y = t.y
	assert(grab_offsets[t.a])
	local collect_grab_x = collect_x + grab_offsets[t.a][1]
	local collect_grab_y = collect_y + grab_offsets[t.a][2]
	assert(approach_offsets[t.a])
	local collect_approach_x = collect_grab_x + approach_offsets[t.a][1]
	local collect_approach_y = collect_grab_y + approach_offsets[t.a][2]

	-- Step 1: Move hand to approach position.
	local ex1 <const>, ey1 <const>, la1 <const>, ua1 <const> =
		solve_pose_and_check_collisions(arm.elbow_x, arm.elbow_y,
		                                shoulder_x, shoulder_y,
		                                collect_approach_x, collect_approach_y,
		                                t.a,
		                                false)
	if not ex1 then
		return false
	end
	local step1 <const> =
	{
		elbow_x = ex1,
		elbow_y = ey1,
		bottom_attached = arm.bottom_attached,
		[a] =
		{
			arm = la1,
			hand = lower.hand,
			opening = 90,
		},
		[b] =
		{
			arm = ua1,
			hand = t.a,
			opening = 0,
		},
		variation = 0,
	}

	-- Step 2: Open fingers.
	local step2 <const> =
	{
		elbow_x = ex1,
		elbow_y = ey1,
		bottom_attached = arm.bottom_attached,
		[a] = step1[a],
		[b] =
		{
			arm = ua1,
			hand = t.a,
			opening = 45,
		},
		variation = 0,
	}

	-- Step 3: Move forward and grab.
	local ex3 <const>, ey3 <const>, la3 <const>, ua3 <const> =
		solve_pose_and_check_collisions(arm.elbow_x, arm.elbow_y,
		                                shoulder_x, shoulder_y,
		                                collect_grab_x, collect_grab_y,
		                                t.a,
		                                false)
	if not ex3 then
		return false
	end
	local step3 <const> =
	{
		elbow_x = ex3,
		elbow_y = ey3,
		bottom_attached = arm.bottom_attached,
		[a] =
		{
			arm = la3,
			hand = lower.hand,
			opening = 90,
		},
		[b] =
		{
			arm = ua3,
			hand = t.a,
			opening = GRAB_OPENING_ANGLE,
		},
		variation = INTERPOLATE_SLOWLY,
	}

	-- Step 4: Shake hand counter-clockwise.
	local step4 <const> =
	{
		elbow_x = ex3,
		elbow_y = ey3,
		bottom_attached = arm.bottom_attached,
		[a] = step3[a],
		[b] =
		{
			arm = ua3,
			hand = normalize_angle(t.a - 5),
			opening = GRAB_OPENING_ANGLE,
		},
		variation = INTERPOLATE_SLOWLY,
	}

	-- Step 5: Shake hand clockwise.
	local step5 <const> =
	{
		elbow_x = ex3,
		elbow_y = ey3,
		bottom_attached = arm.bottom_attached,
		[a] = step3[a],
		[b] =
		{
			arm = ua3,
			hand = normalize_angle(t.a + 5),
			opening = GRAB_OPENING_ANGLE,
		},
		variation = INTERPOLATE_SLOWLY,
	}

	-- Step 6: Move back to approach position with captured object.
	local step6 <const> =
	{
		elbow_x = ex1,
		elbow_y = ey1,
		bottom_attached = arm.bottom_attached,
		[a] = step1[a],
		[b] =
		{
			arm = ua1,
			hand = t.a,
			opening = GRAB_OPENING_ANGLE,
		},
		variation = INTERPOLATE_WITH_CAPTURED_OBJECT,
	}

	-- Step 7: Close fingers.
	--
	-- Same as step 1, but with an extra flag to close fingers slowly.
	local step7 <const> =
	{
		elbow_x = ex1,
		elbow_y = ey1,
		bottom_attached = arm.bottom_attached,
		[a] = step1[a],
		[b] = step1[b],
		variation = INTERPOLATE_WITH_SHRINKING_OBJECT,
	}

	arm.action_plan =
	{
		-- Move hand forward and grab.
		step1,
		step2,
		step3,
		-- Shake 3 times.
		step4, step5, step4, step5, step4, step5,
		-- Re-center hand.
		step3,
		-- Move hand back.
		step6, step7
	}
	return true
end

-- Check a pickup position for feasibility based on arm.action_target.
-- Returns true if all intermediate poses are valid.  This is a subset
-- of check_collect_pose.
local function check_pickup_poses()
	local a, b = get_arm_parts()
	local lower = arm[a]
	local upper = arm[b]

	-- Compute key wrist positions.
	local shoulder_x = lower.wrist_x
	local shoulder_y = lower.wrist_y
	assert(arm.action_target)
	local t = arm.action_target
	assert(grab_offsets[t.a])
	local pickup_grab_x = t.x - 2 * hand_offsets[t.a][1]
	local pickup_grab_y = t.y - 2 * hand_offsets[t.a][2]
	assert(approach_offsets[t.a])
	local pickup_approach_x = pickup_grab_x + approach_offsets[t.a][1]
	local pickup_approach_y = pickup_grab_y + approach_offsets[t.a][2]

	-- Step 1: Move hand to approach position.
	local ex1 <const>, ey1 <const>, la1 <const>, ua1 <const> =
		solve_pose_and_check_collisions(arm.elbow_x, arm.elbow_y,
		                                shoulder_x, shoulder_y,
		                                pickup_approach_x, pickup_approach_y,
		                                t.a,
		                                false)
	if not ex1 then
		return false
	end
	local step1 <const> =
	{
		elbow_x = ex1,
		elbow_y = ey1,
		bottom_attached = arm.bottom_attached,
		[a] =
		{
			arm = la1,
			hand = lower.hand,
			opening = 90,
		},
		[b] =
		{
			arm = ua1,
			hand = t.a,
			opening = 0,
		},
		variation = 0,
	}

	-- Step 2: Open fingers.
	local step2 <const> =
	{
		elbow_x = ex1,
		elbow_y = ey1,
		bottom_attached = arm.bottom_attached,
		[a] = step1[a],
		[b] =
		{
			arm = ua1,
			hand = t.a,
			opening = 45,
		},
		variation = 0,
	}

	-- Step 3: Move forward and grab.
	--
	-- Note that we only check for elbow collision here, which allows the
	-- hand to collide with surrounding tiles during the pickup step (but
	-- during the approach step in step 1).  This makes it possible to
	-- pick up the ball in various places.  For example, if the ball were
	-- stuck on a corner of the wall due to our ghetto physics (see move_point
	-- function in world.lua), we could still pick up that ball because
	-- collision is not checked.  Whereas if we were to enable collision checks
	-- for the hand, that pick up is not possible because the hand would
	-- collide with the wall.
	--
	-- The general goal with these checks is to avoid getting into situations
	-- we can't get out of, and in the case of picking up a ball from a bad
	-- place, that goal is mostly served by checking for collisions in the
	-- approach step.
	local ex3 <const>, ey3 <const>, la3 <const>, ua3 <const> =
		solve_pose_and_check_collisions(arm.elbow_x, arm.elbow_y,
		                                shoulder_x, shoulder_y,
		                                pickup_grab_x, pickup_grab_y,
		                                t.a,
		                                true)
	if not ex3 then
		return false
	end
	local step3 <const> =
	{
		elbow_x = ex3,
		elbow_y = ey3,
		bottom_attached = arm.bottom_attached,
		[a] =
		{
			arm = la3,
			hand = lower.hand,
			opening = 90,
		},
		[b] =
		{
			arm = ua3,
			hand = t.a,
			opening = GRAB_OPENING_ANGLE,
		},
		variation = INTERPOLATE_SLOWLY,
	}

	-- Step 4: Move back to approach position with captured object.
	local step4 <const> =
	{
		elbow_x = ex1,
		elbow_y = ey1,
		bottom_attached = arm.bottom_attached,
		[a] = step1[a],
		[b] =
		{
			arm = ua1,
			hand = t.a,
			opening = GRAB_OPENING_ANGLE,
		},
		variation = INTERPOLATE_WITH_HOLD,
	}

	arm.action_plan = {step1, step2, step3, step4}
	return true
end

-- Generate arm teleport sequence.
local function generate_teleport_action_plan()
	local a, b = get_arm_parts()
	local lower = arm[a]
	local upper = arm[b]

	-- Fold the arm up.  There is no check on whether the pose will collide
	-- with anything, we will just fold the arm up wherever it is.
	local initial_fold_angle <const> = (lower.hand + 270 + COMPACT_FOLD_ANGLE) % 360
	local step1 <const> =
	{
		bottom_attached = arm.bottom_attached,
		elbow_x = lower.wrist_x - wrist_offsets[initial_fold_angle][1],
		elbow_y = lower.wrist_y - wrist_offsets[initial_fold_angle][2],
		[a] =
		{
			arm = initial_fold_angle,
			hand = lower.hand,
			opening = 90,
		},
		[b] =
		{
			arm = (lower.hand + 270) % 360,
			hand = (lower.hand + 170) % 360,
			opening = 0,
		},
		variation = INTERPOLATE_TELEPORT_DEPARTURE,
	}

	-- Move arm to destination location, and set arm angles to match the
	-- new mounting angle.
	local step2 <const> =
	{
		bottom_attached = arm.bottom_attached,
		elbow_x = arm.action_target.next_x - wrist_offsets[COMPACT_FOLD_ANGLE][1],
		elbow_y = arm.action_target.next_y - wrist_offsets[COMPACT_FOLD_ANGLE][2],
		[a] =
		{
			arm = COMPACT_FOLD_ANGLE,
			hand = 90,
			opening = 90,
		},
		[b] =
		{
			arm = 0,
			hand = 260,  -- Hand points at teleport action cursor.
			opening = 0,
		},
		variation = INTERPOLATE_TELEPORT_ARRIVAL,
	}
	arm.action_plan = {step1, step2}
end

-- Cache of action plans for use with check_and_cache_action.
-- Each entry contains one of the following:
-- {x, y, a, kind, positive_elbow, action_plan}
-- {x, y, a, kind, positive_elbow, nil}
--
-- If positive_elbow is true, it means angle_delta(arm.bottom.arm, arm.top.arm)
-- was positive at the time the cache entry was made.  We need this because
-- there are up to two poses that can reach the same coordinate, and action
-- plans were generated based on which of the two poses had an elbow that is
-- closer to the elbow at the time.  This can lead to some suboptimal movements
-- if the user approached a mount point from one angle without mounting, and
-- later attempted to mount the same mount point from a different angle.
--
-- To allow for both solutions to be cached, we include the elbow orientation
-- as part of the cache lookup key.
local action_plan_cache = {}

-- Check arm.action_target for feasibility, caching any generated action plans
-- it found.
--
-- On the actual hardware, we can generate action plans for about 6 points
-- of interest per frame before we start seeing frame rates drop, and 6 is
-- not a very high number.  Since the reachability of each coordinate remains
-- constant as long as the mount point remain constant, we will cache the
-- generated action plans for each location until the mount point changes,
-- or until we have removed some tiles.
--
-- Prior to having this cache, we used to see some slowdowns near certain
-- ledges with a high number of points of interests to evaluate.  We no longer
-- see such slowdowns after implementing this cache.
local function check_and_cache_action()
	local target <const> = arm.action_target
	local positive_elbow <const> = angle_delta(arm.bottom.arm, arm.top.arm) >= 0

	-- Lookup existing cache entries first.
	local action_plan_cache_size <const> = #action_plan_cache
	for i = 1, action_plan_cache_size do
		local entry <const> = action_plan_cache[i]
		if entry[1] == target.x and
		   entry[2] == target.y and
		   entry[3] == target.a and
		   entry[4] == target.kind and
		   entry[5] == positive_elbow then
			-- Got a cache hit.
			assert(debug_cache_event("hit", i - 1))

			-- Apply move-to-front optimization to reduce seeks for next lookup.
			if i > 1 then
				action_plan_cache[1], action_plan_cache[i] = action_plan_cache[i], action_plan_cache[1]
			end

			if entry[6] then
				-- Action is feasible.
				arm.action_plan = entry[6]
				return true
			end
			-- Action is not feasible.
			return false
		end
	end

	-- Don't have a cached result, try adding a new result.
	assert(debug_cache_event("miss", nil))
	local result = nil
	if target.kind == world.MOUNT then
		if check_mount_poses() then
			assert(arm.action_target)
			assert(arm.action_plan)
			result = arm.action_plan
		end
	elseif target.kind == world.COLLECT then
		if check_collect_pose() then
			assert(arm.action_target)
			assert(arm.action_plan)
			result = arm.action_plan
		end
	elseif target.kind == world.PICK_UP then
		assert(arm.action_target.ball)
		assert(arm.action_target.ball >= 1)
		assert(arm.action_target.ball <= #world.INIT_BALLS)
		if check_pickup_poses() then
			assert(arm.action_target)
			assert(arm.action_plan)
			result = arm.action_plan
		end
	else
		assert(target.kind == world.TELEPORT)
		generate_teleport_action_plan()
		assert(arm.action_target)
		assert(arm.action_plan)
		result = arm.action_plan
	end

	-- Insert new result at front of cache.
	table.insert(
		action_plan_cache, 1,
		{target.x, target.y, target.a, target.kind, positive_elbow, result})

	-- Optionally expire the oldest entry.
	if action_plan_cache_size >= MAX_ACTION_PLAN_CACHE_SIZE then
		table.remove(action_plan_cache)
	end

	return result
end

-- Update arm.action_target and arm.action_plan from points of interest.
--
-- This function assumes that all joint positions are up to date.
--
-- Note: this function keeps the first viable action from poi_list, but
-- theoretically we could keep all viable actions and have some way to choose
-- among those.  This would almost allow the game to be played without using
-- the crank, but it's not sufficient because this scheme would only cover
-- movements that involve mount points, and further design is needed to cover
-- movements that require triggering chain reaction tiles (which are not
-- returned by find_points_of_interest).
--
-- Even if we did come up with an input system that did not require crank
-- input, we probably wouldn't implement it since driving a robot with a
-- crank is kind of the whole point of this game.  That said, driving the
-- arm through generated action plans might be useful for some demo or
-- autopilot modes, if we ever come to implement those.
local function set_action_from_poi_list(poi_list)
	local poi_list_size <const> = #poi_list
	if poi_list_size == 0 then
		arm.action_target = nil
		arm.action_plan = nil
		return
	end

	-- Return the first valid entry.
	for i = 1, poi_list_size do
		assert(poi_list[i].kind)

		arm.action_target = poi_list[i]
		assert(arm.action_target.x == floor(arm.action_target.x))
		assert(arm.action_target.y == floor(arm.action_target.y))
		assert(arm.action_target.a == floor(arm.action_target.a))
		if arm.action_target.kind == world.SUMMON then
			assert(arm.action_target.ball)
			assert(arm.action_target.ball >= 1)
			assert(arm.action_target.ball <= #world.INIT_BALLS)
			-- Summon action requires no checks since it does not involve
			-- any arm movement.
			return
		else
			if check_and_cache_action() then
				return
			end
		end
	end

	-- Did not find anything suitable.
	arm.action_target = nil
	arm.action_plan = nil
end

-- Release currently held ball.
local function release_ball()
	-- Release hold.
	local ball_index <const> = arm.hold
	arm.hold = 0

	-- Widen fingers a bit.
	if arm.bottom_attached then
		assert(arm.top.opening <= 80)
		arm.top.opening += 10
	else
		assert(arm.bottom.opening <= 80)
		arm.bottom.opening += 10
	end
	arm.update()

	-- Throw ball.
	world.throw_ball(ball_index)
	if world.reset_requested then return end

	-- Close fingers.
	local pose <const> =
	{
		elbow_x = arm.elbow_x,
		elbow_y = arm.elbow_y,
		bottom_attached = arm.bottom_attached,
		bottom =
		{
			arm = arm.bottom.arm,
			hand = arm.bottom.hand,
			opening = arm.bottom_attached and 90 or 0,
		},
		top =
		{
			arm = arm.top.arm,
			hand = arm.top.hand,
			opening = arm.bottom_attached and 0 or 90,
		},
		variation = INTERPOLATE_MEDIUM_PACE,
	}
	interpolate_toward_pose(pose)
end

--}}}

----------------------------------------------------------------------
--{{{ Joint movement functions.

-- Compare integer keys in a table.
local function compare_table_int_values(a, b, prefix, keys)
	for i = 1, #keys do
		local change <const> = a[keys[i]] == b[keys[i]] and " " or "*"
		print(string.format("%s %s.%s: %d -> %d", change, prefix, keys[i], a[keys[i]], b[keys[i]]))
	end
end

-- Check that current arm position is freed of collisions.  Returns true
-- on success.  This is a debug-only sanity check to make sure we flag
-- bad arm joints early.
local function post_joint_update_sanity_check()
	if try_joint_update_based_on_attachment(0, false, false, false) then
		-- Current state is good, save a snapshot for future reference.
		arm.last_good =
		{
			elbow_x = arm.elbow_x,
			elbow_y = arm.elbow_y,
			bottom =
			{
				arm = arm.bottom.arm,
				arm_crank_negative_delta = arm.bottom.arm_crank_negative_delta,
				arm_crank_positive_delta = arm.bottom.arm_crank_positive_delta,
				hand = arm.bottom.hand,
				hand_crank_negative_delta = arm.bottom.hand_crank_negative_delta,
				hand_crank_positive_delta = arm.bottom.hand_crank_positive_delta,
			},
			top =
			{
				arm = arm.top.arm,
				arm_crank_negative_delta = arm.top.arm_crank_negative_delta,
				arm_crank_positive_delta = arm.top.arm_crank_positive_delta,
				hand = arm.top.hand,
				hand_crank_negative_delta = arm.top.hand_crank_negative_delta,
				hand_crank_positive_delta = arm.top.hand_crank_positive_delta,
			},
		}
		return true
	end

	-- Sanity check failed.  If we never had a good previous state to compare
	-- with, it's likely that we were loading from a bad saved state.  We will
	-- just return false for the assertion to fail.
	if not arm.last_good then
		return false
	end

	-- Log changes from previous good state to current bad state to the console.
	compare_table_int_values(arm.last_good, arm, "arm", {"elbow_x", "elbow_y"})
	local keys <const> =
	{
		"arm",
		"arm_crank_negative_delta",
		"arm_crank_positive_delta",
		"hand",
		"hand_crank_negative_delta",
		"hand_crank_positive_delta",
	}
	compare_table_int_values(arm.last_good.bottom, arm.bottom, "arm.bottom", keys)
	compare_table_int_values(arm.last_good.top, arm.top, "arm.top", keys)
	return false
end

-- Apply crank rotation for a particular arm configuration.
local function apply_joint_update(lower, upper, crank, elbow, lower_wrist, upper_wrist, preview_only)
	-- Lower hand is stationary.
	if not preview_only then
		lower.hand_crank_positive_delta = normalize_angle(lower.hand - crank)
		lower.hand_crank_negative_delta = normalize_angle(lower.hand + crank)
	end

	local positive_wrist <const> = arm.joint_mode == JOINT_PPP or arm.joint_mode == JOINT_W_P or arm.joint_mode == JOINT_PNP
	local positive_elbow <const> = arm.joint_mode == JOINT_PPP or arm.joint_mode == JOINT_W_P or arm.joint_mode == JOINT_NPN

	-- Lower wrist (shoulder) is not dependent on any other joints.
	local cumulative_delta = 0
	if lower_wrist then
		local target
		if positive_wrist then
			target = normalize_angle(lower.arm_crank_positive_delta + crank)
			if not preview_only then
				lower.arm_crank_negative_delta = normalize_angle(target + crank)
			end
		else
			target = normalize_angle(lower.arm_crank_negative_delta - crank)
			if not preview_only then
				lower.arm_crank_positive_delta = normalize_angle(target - crank)
			end
		end
		cumulative_delta = target - lower.arm
		lower.arm = target

		arm.elbow_x = lower.wrist_x - wrist_offsets[lower.arm][1]
		arm.elbow_y = lower.wrist_y - wrist_offsets[lower.arm][2]
	else
		if not preview_only then
			lower.arm_crank_positive_delta = normalize_angle(lower.arm - crank)
			lower.arm_crank_negative_delta = normalize_angle(lower.arm + crank)
		end
	end

	if elbow then
		if lower_wrist then
			-- If both lower wrist and elbow are moving, their motions cancel
			-- out each other, so upper arm angle does not change.
			if not preview_only then
				upper.arm_crank_positive_delta = normalize_angle(upper.arm - crank)
				upper.arm_crank_negative_delta = normalize_angle(upper.arm + crank)
			end
			cumulative_delta = 0
		else
			-- Elbow movement without lower wrist movement.
			local target
			if positive_elbow then
				target = normalize_angle(upper.arm_crank_positive_delta + crank)
				if not preview_only then
					upper.arm_crank_negative_delta = normalize_angle(target + crank)
				end
			else
				target = normalize_angle(upper.arm_crank_negative_delta - crank)
				if not preview_only then
					upper.arm_crank_positive_delta = normalize_angle(target - crank)
				end
			end
			cumulative_delta = target - upper.arm
			upper.arm = target
		end
	else
		-- No elbow movement.  Add lower wrist movement, if any.
		local target <const> = normalize_angle(upper.arm + cumulative_delta)
		if not preview_only then
			upper.arm_crank_positive_delta = normalize_angle(target - crank)
			upper.arm_crank_negative_delta = normalize_angle(target + crank)
		end
		upper.arm = target
	end

	if upper_wrist then
		assert(not lower_wrist)
		if elbow then
			-- If both upper wrist and elbow are moving, their motions cancel
			-- out each other, so hand angle does not change.
			if not preview_only then
				upper.hand_crank_positive_delta = normalize_angle(upper.hand - crank)
				upper.hand_crank_negative_delta = normalize_angle(upper.hand + crank)
			end
		else
			-- Upper wrist movement without elbow movement.  Since we can't
			-- move both wrists at the same time, this means upper wrist is
			-- the only joint that's moving.
			assert(cumulative_delta == 0)
			local target
			if positive_wrist then
				target = normalize_angle(upper.hand_crank_positive_delta + crank)
				if not preview_only then
					upper.hand_crank_negative_delta = normalize_angle(target + crank)
				end
			else
				target = normalize_angle(upper.hand_crank_negative_delta - crank)
				if not preview_only then
					upper.hand_crank_positive_delta = normalize_angle(target - crank)
				end
			end
			upper.hand = target
		end
	else
		-- No upper wrist movement.  Add lower wrist or elbow movement, if any.
		local target <const> = normalize_angle(upper.hand + cumulative_delta)
		if not preview_only then
			upper.hand_crank_positive_delta = normalize_angle(target - crank)
			upper.hand_crank_negative_delta = normalize_angle(target + crank)
		end
		upper.hand = target
	end

	if preview_only then
		return
	end
	assert(post_joint_update_sanity_check())

	-- If we are currently holding a ball, we won't be looking for any
	-- points of interest until that ball is released.
	if arm.hold > 0 then
		arm.action_target = nil
		arm.action_plan = nil
		return
	end

	-- Compute wrist position.  This seems redundant here since arm.update()
	-- will do it again, but we need it to compute the hand position.
	--
	-- Since arm.update() will update the wrist positions, we store the
	-- results here to local variables as opposed to updating arm.wrist_{x,y},
	-- since local variables are slightly cheaper to access.
	local upper_wrist_x <const> = arm.elbow_x + wrist_offsets[upper.arm][1]
	local upper_wrist_y <const> = arm.elbow_y + wrist_offsets[upper.arm][2]
	assert(upper_wrist_x == floor(upper_wrist_x))
	assert(upper_wrist_y == floor(upper_wrist_y))

	-- Compute world coordinates near tip of hand.
	--
	-- For finding mount points, the ideal location to test is actually the
	-- wrist, since that's where the arm will be mounted.  But by extending
	-- toward the tip of the hand, it allows the wrist rotation to be
	-- incorporated into deciding where to mount: if we only look for mount
	-- near the wrist, only the shoulder and elbow angles are taken into
	-- account.  By looking for mount points near the tip of the hand, the
	-- wrist angle would also contribute, and players can roughly point at
	-- where they want to mount with the tip of the hand.
	--
	-- Note that 2*hand_offsets is actually slightly shorter than tip of
	-- hand (because hand radius is longer than offset to hand center),
	-- but it's close enough for our purpose.
	local hand_x <const> = upper_wrist_x + 2 * hand_offsets[upper.hand][1]
	local hand_y <const> = upper_wrist_y + 2 * hand_offsets[upper.hand][2]
	assert(hand_x == floor(hand_x))
	assert(hand_y == floor(hand_y))

	-- Find points of interest near center of hand (e.g. mount points),
	-- and update arm.action_target and arm.action_plan accordingly.
	local old_target <const> = arm.action_target
	set_action_from_poi_list(world.find_points_of_interest(hand_x, hand_y))

	-- Reset cursor_timer if the action target has changed.
	if (not old_target) or
	   (arm.action_target and
	    (arm.action_target.x ~= old_target.x or
	     arm.action_target.y ~= old_target.y or
	     arm.action_target.a ~= old_target.a or
	     arm.action_target.kind ~= old_target.kind)) then
		cursor_timer = 0
	end
end

-- Wrapper to apply_joint_update to select the right arm components.
local function apply_update(crank, elbow, bottom_wrist, top_wrist)
	if arm.bottom_attached then
		-- Apply crank rotation for bottom->elbow->top chain.
		apply_joint_update(arm.bottom, arm.top, crank, elbow, bottom_wrist, top_wrist, false)
	else
		-- Apply crank rotation for top->elbow->bottom chain.
		apply_joint_update(arm.top, arm.bottom, crank, elbow, top_wrist, bottom_wrist, false)
	end
end

-- Collect set of breakable tiles that collided with the arm.
local function collect_breakable_tiles(lower, upper, crank, elbow, lower_wrist, upper_wrist)
	-- Compute joint positions.
	local delta_crank <const> = angle_delta(arm.previous_crank_position, crank)
	local shoulder_angle <const>, elbow_angle <const>, hand_angle <const> =
		compute_joint_angles(lower, upper, delta_crank, elbow, lower_wrist, upper_wrist)

	local lower_wrist_x <const> = lower.wrist_x
	local lower_wrist_y <const> = lower.wrist_y

	local elbow_x <const>, elbow_y <const>,
	      upper_wrist_x <const>, upper_wrist_y <const>,
	      upper_hand_x <const>, upper_hand_y <const> =
		compute_joint_positions(lower_wrist_x, lower_wrist_y,
		                        shoulder_angle, elbow_angle, hand_angle)

	-- Collect collision points.
	local points = {}
	joint_collision_with_collection(points, elbow_x, elbow_y, upper_wrist_x, upper_wrist_y, upper_hand_x, upper_hand_y)
	limb_collision_with_collection(points, elbow_x, elbow_y, upper_wrist_x, upper_wrist_y)

	-- Also collect collision points with the ball if we are currently holding
	-- one.  Honestly this is kind of a silly thing to do, since it would have
	-- been easier for the player to just go ahead and bash those tiles without
	-- holding any ball at all, but we are not to judge.
	if arm.hold > 0 then
		local ball_x <const> = 2 * upper_hand_x - upper_wrist_x
		local ball_y <const> = 2 * upper_hand_y - upper_wrist_y
		ball_collision_with_collection(points, ball_x, ball_y)
	end

	return points
end

-- Find where arm collided with the world, and remove tiles accordingly.
local function apply_breaking_update(crank, elbow, bottom_wrist, top_wrist)
	local points
	if arm.bottom_attached then
		points = collect_breakable_tiles(arm.bottom, arm.top, crank, elbow, bottom_wrist, top_wrist)
	else
		points = collect_breakable_tiles(arm.top, arm.bottom, crank, elbow, top_wrist, bottom_wrist)
	end

	-- Render one frame of the arm with the breaking crank angle.  This is a
	-- "preview" image for the temporary arm pose during the breakage.
	--
	-- If we are just breaking one tile then it doesn't really matter, and the
	-- joint angles will be overwritten by the non-breaking crank angle later
	-- in the same frame.  But if we have set off a chain reaction, the joint
	-- angles would have been left at the previous arm pose, which might be
	-- far off from the breaking arm pose if the user was making large
	-- movements with the crank, and we would see the arm sort of hanging in
	-- mid air without coming into contact with whatever it was breaking.  The
	-- preview here is meant to avoid that hanging arm effect.
	if arm.bottom_attached then
		-- Apply crank rotation for bottom->elbow->top chain.
		apply_joint_update(arm.bottom, arm.top, crank, elbow, bottom_wrist, top_wrist, true)
	else
		-- Apply crank rotation for top->elbow->bottom chain.
		apply_joint_update(arm.top, arm.bottom, crank, elbow, top_wrist, bottom_wrist, true)
	end

	-- Update arm sprites, but don't call arm.update_focus().  If we did not
	-- set off a chain reaction, viewport will be updated later in main.lua.
	-- If we did set off a chain reaction, world.remove_breakable_tiles()
	-- take care off updating viewports.
	arm.update()

	world.remove_breakable_tiles(points)
end

--}}}

----------------------------------------------------------------------
--{{{ Global functions.

-- Do partial initialization of arm sprites.
--
-- Call this function with step values 0..3 to get all initialization done.
function arm.init(step)
	if gs_top_arm ~= nil then
		return
	end

	assert(debug_log(string.format("arm.init(%d)", step)))
	if step == 0 then
		init_offset_tables()
		assert(wrist_offsets[0])
		assert(wrist_offsets[359])
		assert(hand_offsets[0])
		assert(hand_offsets[359])

		local arm_image_table = gfx.imagetable.new("images/arm")
		assert(arm_image_table)
		g_arm_top = gfx.imagetable.new(360)
		g_arm_bottom = gfx.imagetable.new(360)
		load_and_rotate(arm_image_table, 90, g_arm_top)
		load_and_rotate(arm_image_table, 0, g_arm_bottom)

	elseif step == 1 then
		local finger_image_table = gfx.imagetable.new("images/finger")
		assert(finger_image_table)
		g_finger_top = gfx.imagetable.new(360)
		load_and_rotate(finger_image_table, 0, g_finger_top)

	elseif step == 2 then
		g_finger_bottom = gfx.imagetable.new(360)
		initialize_bottom_finger()

	else
		gs_bottom_arm = gfx.sprite.new()
		gs_bottom_finger_bottom = gfx.sprite.new()
		gs_bottom_finger_top = gfx.sprite.new()
		gs_wrist = gfx.sprite.new(gfx.image.new("images/wrist"))
		gs_top_finger_bottom = gfx.sprite.new()
		gs_top_finger_top = gfx.sprite.new()
		gs_top_arm = gfx.sprite.new()
		gs_captured_object = gfx.sprite.new()

		init_sprite(gs_bottom_arm, Z_BOTTOM_ARM)
		init_sprite(gs_bottom_finger_bottom, Z_BOTTOM_FINGER_BOTTOM)
		init_sprite(gs_bottom_finger_top, Z_BOTTOM_FINGER_TOP)
		init_sprite(gs_wrist, Z_WRIST)
		init_sprite(gs_top_finger_bottom, Z_TOP_FINGER_BOTTOM)
		init_sprite(gs_top_finger_top, Z_TOP_FINGER_TOP)
		init_sprite(gs_top_arm, Z_TOP_ARM)
		init_sprite(gs_captured_object, Z_TOP_CAPTURED_OBJECT)

		gs_wrist:setCenter(0.5, 0.5)
		gs_captured_object:setCenter(0.5, 0.5)
		gs_captured_object:setVisible(false)

		gs_mount_h = gfx.image.new("images/cursor1")
		gs_mount_v = gfx.image.new("images/cursor2")
		gs_mount_d_backslash = gfx.image.new("images/cursor3")
		gs_mount_d_slash = gfx.image.new("images/cursor4")
		gs_circle_target = gfx.image.new("images/cursor5")
		gs_summon_ball = gfx.image.new("images/cursor6")
		gs_summon_ufo = gfx.image.new("images/cursor7")
		assert(gs_mount_h)
		assert(gs_mount_v)
		assert(gs_mount_d_backslash)
		assert(gs_mount_d_slash)
		assert(gs_circle_target)
		assert(gs_summon_ball)
		assert(gs_summon_ufo)
		gs_hint_cursors =
		{
			gs_mount_h,  -- Up.
			gs_mount_h,  -- Down.
			gs_mount_v,  -- Left.
			gs_mount_v,  -- Right.
			gs_mount_d_slash,
			gs_mount_d_backslash,
			gs_circle_target,
			gfx.image.new("images/help_bg1"),
		}
		assert(gs_hint_cursors[1])
		assert(gs_hint_cursors[2])
		assert(gs_hint_cursors[3])
		assert(gs_hint_cursors[4])
		assert(gs_hint_cursors[5])
		assert(gs_hint_cursors[6])
		assert(gs_hint_cursors[7])
		assert(gs_hint_cursors[8])
	end
end

-- Reset arm states.
function arm.reset()
	-- Fetch starting position from data.lua.
	assert(world.START)
	assert(#world.START >= 1)
	local start_select = math.random(1, #world.START)

	-- If this is not the user's first run, we will make some effort to pick
	-- a different starting position from last time.
	if arm.start then
		for retry = 1, 5 do
			if start_select == arm.start then
				start_select = math.random(1, #world.START)
			end
		end
	end
	local start_x <const> = world.START[start_select][1]
	local start_y <const> = world.START[start_select][2]

	-- Save the starting position.
	arm.start = start_select

	-- Joint operation mode.
	arm.joint_mode = JOINT_PPP

	-- Hint mode.
	arm.hint_mode = arm.HINT_BASIC

	-- arm, hand = rotation angles for each sprite.
	-- opening = rotation angles for finger sprites.
	-- wrist_x, wrist_y = cached wrist position in world coordinates.
	-- {arm,hand}_crank_{positive,negative}_delta = crank control state.
	--
	-- All angles are stored as integer degrees (as opposed to floating point).
	-- We enforce this by truncating crank input to integer, so that only
	-- integers propagate around the functions.  We do this because some
	-- floating point precision issues will cause us to have spurious
	-- 1-degree movements when a joint transitions between controlled and
	-- uncontrolled states.
	--
	-- An increase in any rotation angle corresponds to a clockwise rotation
	-- on screen.
	--
	-- Arm joint movements are controlled by crank motion.  A straightforward
	-- way to implement this would be to just apply getCrankChange() values
	-- to the joints, but that loses accuracy for small crank movements.
	-- Since Playdate has a way of getting absolute crank position, mapping
	-- that to the arm joints would be more accurate.
	--
	-- Since we only have one crank but we want to move multiple joints
	-- independently, the way the arm joints are controlled is that the D-Pad
	-- selects which joints to move, and joints move in response to a D-Pad
	-- plus crank combination.  To keep the joints and crank in sync, we
	-- keep track of three angles: one for the joint, two for the positive
	-- and negative crank deltas, and balance these two equations for each
	-- joint:
	--
	--   joint = positive_delta + crank
	--   joint = negative_delta - crank
	--
	-- Depending on joint mode, one of the deltas are held fixed when D-Pad
	-- is pressed while joint value and the other delta are updated.  When
	-- D-Pad is released, both deltas are updated to keep the deltas in sync
	-- with crank position.
	arm.bottom =
	{
		arm = 180,
		hand = 180,
		opening = 90,
		wrist_x = start_x,
		wrist_y = start_y,
		hand_x = start_x - floor(HAND_OFFSET),
		hand_y = start_y,
		arm_crank_positive_delta = 0,
		arm_crank_negative_delta = 0,
		hand_crank_negative_delta = 0,
		hand_crank_positive_delta = 0,
	}
	arm.top =
	{
		arm = 0,
		hand = 0,
		opening = 0,
		wrist_x = start_x + ARM_LENGTH * 2,
		wrist_y = start_y,
		hand_x = start_x + ARM_LENGTH * 2 + floor(HAND_OFFSET),
		hand_y = start_y,
		arm_crank_positive_delta = 0,
		arm_crank_negative_delta = 0,
		hand_crank_positive_delta = 0,
		hand_crank_negative_delta = 0,
	}

	-- Bottom hand attachment state.  If true, arm is attached at bottom.
	-- If false, arm is attached at top.
	--
	-- While we logically operate the arm as a set of 3 joints, we actually
	-- have 4 sprites to rotate.  The states above represent rotation of the
	-- sprites, and this flag controls their interpretation.
	--
	--  arm.bottom_attached   true         false
	--  arm.bottom.hand       stationary   wrist
	--  arm.bottom.arm        shoulder     elbow
	--  arm.top.arm           elbow        shoulder
	--  arm.top.hand          wrist        stationary
	arm.bottom_attached = true

	-- Previous crank position (integer degrees).  This is used to detect
	-- which direction the crank was rotating.
	arm.previous_crank_position = normalize_angle(floor(playdate.getCrankPosition()))

	-- Coordinate of elbow joint.  All arm/finger sprites are positioned
	-- relative to the elbow as opposed to shoulder or wrist, because the
	-- role of shoulder or wrist will change depending on which end is
	-- attached.  Also, the sprites were draw with the rotation center set
	-- to the elbow, so picking any other center will a bit more work.
	arm.elbow_x = start_x + ARM_LENGTH
	arm.elbow_y = start_y

	-- Point of interest to be actioned on when player operates the hand, either
	-- a nil or a tuple returned from world.find_points_of_interest().
	--
	-- The tuple contains these elements:
	--   kind = action kind (MOUNT, COLLECT, PICK_UP, or SUMMON).
	--   x, y = action target coordinates.
	--   a = angle for interacting with the target.
	--   ball = if kind is PICK_UP or SUMMON, this is the ball index.
	arm.action_target = nil

	-- List of poses for the arm to go through when player operates the hand,
	-- either a nil or a list of tuples of this type:
	--
	--   {
	--      elbow_x,
	--      elbow_y,
	--      bottom_attached,
	--      [bottom] = {arm, hand, opening},
	--      [top] = {arm, hand, opening}
	--      variation,
	--   }
	--
	-- These are basically intermediate values to be applied to global arm
	-- state upon activating an action.  This is populated at the same time
	-- as action_target because action_target selection requires validating
	-- all poses associated with that action.  Since we already computed
	-- those poses at that time, we will just cache the list of poses here.
	arm.action_plan = nil

	-- Invalidate cached action plans.
	action_plan_cache = {}

	-- If we are currently holding a ball, this is the index of the ball
	-- that is being held (1-based), otherwise it's zero.
	arm.hold = 0

	-- Number of times a mount/unmount action was executed.
	arm.step_count = 0

	-- Reset sprite scales.
	gs_bottom_arm:setScale(1)
	gs_bottom_finger_bottom:setScale(1)
	gs_bottom_finger_top:setScale(1)
	gs_wrist:setScale(1)
	gs_top_finger_bottom:setScale(1)
	gs_top_finger_top:setScale(1)
	gs_top_arm:setScale(1)

	-- Hide captured images.
	gs_captured_object:setVisible(false)

	-- Derive initial viewport position from initial arm position.
	arm.update_focus()
	local SCREEN_WIDTH <const> = 400
	local SCREEN_HEIGHT <const> = 240
	world.sprite_offset_x = SCREEN_WIDTH / 2 - (arm.elbow_x + arm.top.wrist_x) / 2
	world.sprite_offset_y = SCREEN_HEIGHT / 2 - arm.elbow_y

	-- Remove extra hints.
	reset_tile_hints()
end

-- Update arm sprites.
function arm.update()
	-- Update arm sprites.
	local bottom_arm <const> = arm.bottom.arm
	gs_bottom_arm:setImage(g_arm_bottom[bottom_arm + 1])
	gs_bottom_arm:moveTo(arm_offset(bottom_arm, arm.elbow_x, arm.elbow_y))
	local top_arm <const> = arm.top.arm
	gs_top_arm:setImage(g_arm_top[top_arm + 1])
	gs_top_arm:moveTo(arm_offset(top_arm, arm.elbow_x, arm.elbow_y))

	update_hand_sprites(arm.bottom, gs_bottom_finger_top, gs_bottom_finger_bottom)
	update_hand_sprites(arm.top, gs_top_finger_top, gs_top_finger_bottom)
	gs_wrist:moveTo(arm.top.wrist_x, arm.top.wrist_y)

	-- If we are currently holding a ball, update its position to match
	-- tip of hand.
	if arm.hold > 0 then
		if arm.bottom_attached then
			world.update_ball_position(
				arm.hold,
				arm.top.wrist_x + 2 * hand_offsets[arm.top.hand][1],
				arm.top.wrist_y + 2 * hand_offsets[arm.top.hand][2])
		else
			world.update_ball_position(
				arm.hold,
				arm.bottom.wrist_x + 2 * hand_offsets[arm.bottom.hand][1],
				arm.bottom.wrist_y + 2 * hand_offsets[arm.bottom.hand][2])
		end
	end
end

-- Update area of focus.
--
-- Because the arm is longer than number of vertical pixels we got, we
-- only try to keep the non-anchored part of the arm within view.
-- Actually, we made our arm so big that we are not guaranteed to fit
-- the elbow within range either depending on how large we set the
-- screen margins, so we try to keep the part of the arm that is just a
-- bit ahead of the elbow within view.
--
-- We could have just made the arm smaller, but it doesn't look as nice.
function arm.update_focus()
	if arm.bottom_attached then
		local forearm_x <const> = arm.elbow_x + 0.2 * (arm.top.wrist_x - arm.elbow_x)
		local forearm_y <const> = arm.elbow_y + 0.2 * (arm.top.wrist_y - arm.elbow_y)
		world.focus_min_x = min(forearm_x, arm.top.wrist_x, arm.top.hand_x)
		world.focus_max_x = max(forearm_x, arm.top.wrist_x, arm.top.hand_x)
		world.focus_min_y = min(forearm_y, arm.top.wrist_y, arm.top.hand_y)
		world.focus_max_y = max(forearm_y, arm.top.wrist_y, arm.top.hand_y)
	else
		local forearm_x <const> = arm.elbow_x + 0.2 * (arm.bottom.wrist_x - arm.elbow_x)
		local forearm_y <const> = arm.elbow_y + 0.2 * (arm.bottom.wrist_y - arm.elbow_y)
		world.focus_min_x = min(forearm_x, arm.bottom.wrist_x, arm.bottom.hand_x)
		world.focus_max_x = max(forearm_x, arm.bottom.wrist_x, arm.bottom.hand_x)
		world.focus_min_y = min(forearm_y, arm.bottom.wrist_y, arm.bottom.hand_y)
		world.focus_max_y = max(forearm_y, arm.bottom.wrist_y, arm.bottom.hand_y)
	end
end

-- Draw action target and hints.
function arm.draw_cursor()
	if arm.hint_mode >= arm.HINT_MORE then
		-- Show direction to nearest item.
		world.draw_item_hint(arm.hint_mode >= arm.HINT_EVEN_MORE)

		if arm.hold ~= 0 then
			-- Remove any extra hints if we are holding a ball.
			reset_tile_hints()
		elseif arm.hint_mode >= arm.HINT_EXTRA then
			-- We are not holding anything and hint is in "extra" mode, increase
			-- idle_timer and show tile hints after some amount of time.
			--
			-- Note that we do this even if arm.action_target is set, which means
			-- the tile hints could appear even though an action cursor is
			-- visible on screen.  This is fine since the tile hints flashes by
			-- quickly.  The alternative of hiding tile hints to the presence
			-- of action cursors is a less useful behavior, since there are many
			-- tight places where player might want to see tile hints but can't
			-- move the hand away.
			--
			-- Alternatively, we could bind the tile hints to one of the A/B
			-- buttons such that they are generated on demand, but we don't want
			-- that since the spirit of the hints is that they only show up
			-- through inaction, and we don't want the hint system to interfere
			-- with the game controls in any way.
			idle_timer += 1
			if idle_timer >= HINT_DELAY_FRAMES then
				-- Set hint origin on the first frame, so that subsequent tile
				-- hints radiate from the same spot.
				if idle_timer == HINT_DELAY_FRAMES then
					if arm.bottom_attached then
						hint_origin_x = arm.top.hand_x
						hint_origin_y = arm.top.hand_y
					else
						hint_origin_x = arm.bottom.hand_x
						hint_origin_y = arm.bottom.hand_y
					end
				end

				local hint_frame = idle_timer - HINT_DELAY_FRAMES
				if hint_frame % 3 == 0 then
					world.add_tile_hints(hint_origin_x, hint_origin_y, hint_frame // 3, hint_table)
				end
			end

			-- Animate hint cursors.
			animate_tile_hints()
			if idle_timer > HINT_RESET_FRAMES then
				idle_timer = HINT_DELAY_FRAMES - 1
			end
		end
	else
		reset_tile_hints()
	end

	-- No additional cursors to draw if there is no pending action available.
	if not arm.action_target then
		return
	end

	-- Make the cursor blink once per second.
	cursor_timer += 1
	if cursor_timer > 20 then
		if cursor_timer > 30 then
			cursor_timer = 0
		end
		return
	end

	-- Draw the one cursor that is relevant to arm.action_target.
	--
	-- Note: we are drawing one image with NXOR mode at each frame, as opposed
	-- to creating sprites for each cursor image and call setImageDrawMode on
	-- on them.  This is slightly more convenient for us than managing sprite
	-- visibilities for each cursor shape.
	--
	-- The use of NXOR mode appears to cause some sort of Z-fighting issue with
	-- the immutable background layer, but drawing on top of background layer
	-- seems just fine.  In other words, NXOR seem to interact poorly with
	-- sprites that are two layers below, but works fine with sprite that is
	-- immediately below.  This feels like a bug with Playdate runtime.
	--
	-- One thought is to draw all the cursors as sprites so that we can manage
	-- the Z-orders explicitly.  We have tried that, but it didn't fix
	-- Z-fighting.  What seem to be actually happening is some trouble with
	-- managing dirty bit across 3 layers.  We have also tried to workaround
	-- this with setOpaque, which also didn't help.  On the other hand, this
	-- Z-fighting issue appears to happening on against some specific tiles.
	-- Maybe it depends on dither pattern?  Anyways, we have decided to just
	-- live with the occasionally flashing cursor.
	--
	-- In places that are close to 50% gray, NXOR doesn't show up so well,
	-- which is why we flash solid black followed by solid white as part of
	-- the cursor's blink sequence.  This flashing happens near the end of
	-- a cycle just before the cursor is about to disappear, because newly
	-- placed cursors have cursor_timer set to zero, and we don't want the
	-- flashing to start right away.
	if cursor_timer == 17 or cursor_timer == 18 then
		gfx.setImageDrawMode(gfx.kDrawModeFillBlack)
	elseif cursor_timer == 19 or cursor_timer == 20 then
		gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
	else
		gfx.setImageDrawMode(gfx.kDrawModeNXOR)
	end
	local x <const> = arm.action_target.x
	local y <const> = arm.action_target.y
	if arm.action_target.kind == world.MOUNT then
		local a <const> = arm.action_target.a
		if a == 0 or a == 180 then
			gs_mount_v:drawCentered(x, y)
		elseif a == 90 or a == 270 then
			gs_mount_h:drawCentered(x, y)
		elseif a == 45 or a == 225 then
			gs_mount_d_slash:drawCentered(x, y)
		else
			assert(a == 135 or a == 315)
			gs_mount_d_backslash:drawCentered(x, y)
		end
	elseif arm.action_target.kind == world.SUMMON then
		gs_summon_ball:drawCentered(x, y)
	elseif arm.action_target.kind == world.TELEPORT then
		gs_summon_ufo:drawCentered(x, y)
	else
		assert(arm.action_target.kind == world.COLLECT or arm.action_target.kind == world.PICK_UP)
		gs_circle_target:drawCentered(x, y)
	end

	-- Always return draw mode to "copy" when we are done.
	gfx.setImageDrawMode(gfx.kDrawModeCopy)
end

-- Update joint positions.  Arguments are booleans indicating which joints
-- to rotate.
--
-- Returns collision velocity in terms of degrees, which indicates how much
-- further the arm would have rotated if there was no obstacle in the way.
-- Returns zero if there were no collisions.
function arm.update_joints(elbow, bottom_wrist, top_wrist)
	-- Read absolute crank position and convert it to integer.
	--
	-- Here it might seem inconsistent that we are reading the crank position
	-- directly, as opposed to having the parent read it and pass it in as an
	-- argument.  We are trading purity for convenience since this function
	-- and arm.reset() are the only places that deals with crank position,
	-- so it doesn't need to be read elsewhere.
	local crank <const> = normalize_angle(floor(playdate.getCrankPosition()))

	-- If no movement is requested, refresh deltas to maintain current arm
	-- position.
	if arm.previous_crank_position == crank or
	   not (elbow or bottom_wrist or top_wrist) then
		synchronize_deltas(crank)
		-- arm.action_target and arm.action_plan are left untouched.  If they
		-- were populated before, they should still be valid, since arm pose
		-- has not changed.
		return 0
	end

	local adjusted_crank <const> = find_closest_valid_crank_position(crank, elbow, bottom_wrist, top_wrist)
	if adjusted_crank ~= crank then
		-- Adjust crank position differs from intended crank position.  If
		-- the adjusted crank position is different from the previous crank
		-- position, then we are pushing against a wall, and there is no
		-- collision, because crank didn't move.
		--
		-- If the adjusted crank position is different from previous position,
		-- it's considered a collision.  If the adjusted crank position is
		-- sufficiently different from the intended crank position, we will
		-- treat this as a breaking collision (as opposed to just a soft tap),
		-- and remove breakable tiles accordingly.
		if adjusted_crank ~= arm.previous_crank_position then
			local velocity <const> = angle_delta(adjusted_crank, crank)
			local magnitude <const> = abs(velocity)
			if magnitude > BREAK_THRESHOLD_DEGREES then
				-- Compute a new crank position that is just a bit greater
				-- than the closest valid crank position.  We use this crank
				-- position to find the nearest object that collided with the arm.
				--
				-- We don't want to just use original crank value because that
				-- might position the arm much deeper than the collision surface,
				-- if the user was moving the crank really fast.
				local collision_crank <const> = adjusted_crank + velocity / magnitude
				assert(collision_crank == floor(collision_crank))
				assert(abs(angle_delta(adjusted_crank, collision_crank)) == 1)
				local old_removed_tile_count <const> = #world.removed_tiles
				apply_breaking_update(collision_crank, elbow, bottom_wrist, top_wrist)

				-- Invalidate cached action plans due to terrain change.
				--
				-- We can detect the terrain has changed (as opposed to the arm
				-- knocking hard on an unbreakable wall) due to some number of
				-- tiles being removed.
				if old_removed_tile_count ~= #world.removed_tiles then
					assert(debug_cache_event("reset", #action_plan_cache))
					action_plan_cache = {}
					reset_tile_hints()
				end
			end
		end

		-- The next step would have been to compute joint positions from the
		-- crank values (via apply_update), but simply assigning "delta+crank"
		-- and "delta-crank" to various joints would result in the arm being
		-- embedded in whatever obstacle it collided with.  An obvious fix
		-- would be to change the value of "crank" to "adjusted_crank" such
		-- that the collision didn't happen, but because "crank" reflects actual
		-- crank position, we will go through the same adjustments again in the
		-- next frame.
		--
		-- Thus, in order to make "delta+crank" and "delta-crank" valid while
		-- holding value of "crank" fixed, we adjust the delta values.
		local d <const> = adjusted_crank - crank
		arm.bottom.arm_crank_positive_delta = normalize_angle(arm.bottom.arm_crank_positive_delta + d)
		arm.bottom.arm_crank_negative_delta = normalize_angle(arm.bottom.arm_crank_negative_delta - d)
		arm.bottom.hand_crank_positive_delta = normalize_angle(arm.bottom.hand_crank_positive_delta + d)
		arm.bottom.hand_crank_negative_delta = normalize_angle(arm.bottom.hand_crank_negative_delta - d)
		arm.top.arm_crank_positive_delta = normalize_angle(arm.top.arm_crank_positive_delta + d)
		arm.top.arm_crank_negative_delta = normalize_angle(arm.top.arm_crank_negative_delta - d)
		arm.top.hand_crank_positive_delta = normalize_angle(arm.top.hand_crank_positive_delta + d)
		arm.top.hand_crank_negative_delta = normalize_angle(arm.top.hand_crank_negative_delta - d)
	end

	apply_update(crank, elbow, bottom_wrist, top_wrist)
	arm.previous_crank_position = crank

	-- Check if the tip of the unattached hand tripped over any chain reaction
	-- tiles.  This is not as precise as the arm collisions since we don't want
	-- to repeat all that work.  So, if a chain reaction tile was meant to be
	-- triggered by the hand or ball passing through, it will need to cover
	-- many tiles to ensure that it would be tripped.
	--
	-- We can do even less work if we only check the elbow position, since
	-- that's guaranteed to be computed and we don't need to repeat the wrist
	-- computations here.  We used to do that, but it didn't feel natural since
	-- the arm will need to "elbow" its way into an area to reveal what's
	-- behind the foreground, as opposed to "reach" into an area with the hand.
	--
	-- During endgame, this same logic is used to paint endgame markers onto
	-- blank background tiles.
	local old_removed_tile_count <const> = #world.removed_tiles
	if arm.bottom_attached then
		local wrist_x <const> = arm.elbow_x + wrist_offsets[arm.top.arm][1]
		local wrist_y <const> = arm.elbow_y + wrist_offsets[arm.top.arm][2]
		local hand_x <const> = wrist_x + hand_offsets[arm.top.hand][1] * 2
		local hand_y <const> = wrist_y + hand_offsets[arm.top.hand][2] * 2
		world.area_trigger(hand_x, hand_y, arm.update)
	else
		local wrist_x <const> = arm.elbow_x + wrist_offsets[arm.bottom.arm][1]
		local wrist_y <const> = arm.elbow_y + wrist_offsets[arm.bottom.arm][2]
		local hand_x <const> = wrist_x + hand_offsets[arm.bottom.hand][1] * 2
		local hand_y <const> = wrist_y + hand_offsets[arm.bottom.hand][2] * 2
		world.area_trigger(hand_x, hand_y, arm.update)
	end

	-- Invalidate cached action plans due to terrain change.
	if old_removed_tile_count ~= #world.removed_tiles then
		assert(debug_cache_event("reset", #action_plan_cache))
		action_plan_cache = {}
		reset_tile_hints()
	end
end

-- Execute action_plan.
function arm.execute_action()
	if arm.hold > 0 then
		-- Throw ball.
		release_ball()
		if world.reset_requested then return end

		-- Invalidate cached action plans.
		assert(debug_cache_event("reset", #action_plan_cache))
		action_plan_cache = {}

	else
		if not arm.action_target then return end

		if arm.action_target.kind == world.SUMMON then
			-- Summon ball.
			assert(arm.action_target.ball)
			world.summon_ball(arm.action_target.ball)

		else
			-- Grab/mount/pickup/teleport.
			assert(arm.action_plan)
			assert(arm.action_target.kind == world.MOUNT or arm.action_target.kind == world.COLLECT or arm.action_target.kind == world.PICK_UP or arm.action_target.kind == world.TELEPORT)

			-- Execute action plan steps.
			for i = 1, #arm.action_plan do
				if world.reset_requested then return end
				interpolate_toward_pose(arm.action_plan[i])
			end

			-- Invalidate cached action plans.
			assert(debug_cache_event("reset", #action_plan_cache))
			action_plan_cache = {}

			if arm.action_target.kind == world.MOUNT then
				-- Update step counter.
				arm.step_count += 1
			elseif arm.action_target.kind == world.COLLECT then
				-- Check if we have collected all items.
				world.check_victory_state()
			end
		end
	end

	-- Synchronize deltas and apply a no-op update to refresh action_target.
	local crank = normalize_angle(floor(playdate.getCrankPosition()))
	synchronize_deltas(crank)
	apply_update(crank, false, false, false)
	reset_tile_hints()
end

-- Move elbow to a specified world coordinate and clear action plan cache.
--
-- This is meant to be used for debugging only.  After the move, the arm will
-- be floating in space not and not attached to any wall.  User should find a
-- wall for attaching the arm before attempting to save state, otherwise the
-- saved state will be rejected on next load.
function arm.debug_move(dx, dy)
	-- Do not allow any part of the arm to go out of bounds.
	if not (within_world_x_range(arm.elbow_x + dx) and
	        within_world_y_range(arm.elbow_y + dy) and
	        within_world_x_range(arm.bottom.wrist_x + dx) and
	        within_world_y_range(arm.bottom.wrist_y + dy) and
	        within_world_x_range(arm.bottom.hand_x + dx) and
	        within_world_y_range(arm.bottom.hand_y + dy) and
	        within_world_x_range(arm.top.wrist_x + dx) and
	        within_world_y_range(arm.top.wrist_y + dy) and
	        within_world_x_range(arm.top.hand_x + dx) and
	        within_world_y_range(arm.top.hand_y + dy)) then
		return
	end

	arm.elbow_x += dx
	arm.elbow_y += dy
	action_plan_cache = {}
end

-- Check if arm is idle by comparing joint positions against serialized state.
-- Returns true if so.
function arm.is_idle(state)
	return state[SAVE_STATE_ELBOW_X] == arm.elbow_x and
	       state[SAVE_STATE_ELBOW_Y] == arm.elbow_y and
	       state[SAVE_STATE_BOTTOM_ARM] == arm.bottom.arm and
	       state[SAVE_STATE_BOTTOM_HAND] == arm.bottom.hand and
	       state[SAVE_STATE_TOP_ARM] == arm.top.arm and
	       state[SAVE_STATE_TOP_HAND] == arm.top.hand
end

-- Validate a partial save state, returns true if state is valid.
function arm.is_valid_save_state(state)
	-- General schema check.
	local SCHEMA <const> =
	{
		[SAVE_STATE_JOINT_MODE] = "uint",
		[SAVE_STATE_HINT_MODE] = "uint",
		[SAVE_STATE_ELBOW_X] = "uint",
		[SAVE_STATE_ELBOW_Y] = "uint",
		[SAVE_STATE_ATTACHMENT] = "uint",
		[SAVE_STATE_BOTTOM_ARM] = "uint",
		[SAVE_STATE_BOTTOM_HAND] = "uint",
		[SAVE_STATE_TOP_ARM] = "uint",
		[SAVE_STATE_TOP_HAND] = "uint",
		[SAVE_STATE_START] = "uint",
		[SAVE_STATE_HOLD] = "uint",
		[SAVE_STATE_STEP_COUNT] = "uint",
	}
	if not util.validate_state(SCHEMA, state) then
		assert(debug_log("invalid arm state: mismatched schema"))
		return false
	end

	-- Check joint mode.
	if state[SAVE_STATE_JOINT_MODE] < 1 or state[SAVE_STATE_JOINT_MODE] > #arm.JOINT_MODES then
		assert(debug_log("invalid arm state: bad joint_mode (" .. SAVE_STATE_JOINT_MODE .. ")"))
		return false
	end

	-- Check hint mode.
	if state[SAVE_STATE_HINT_MODE] < 1 or state[SAVE_STATE_HINT_MODE] > #arm.HINT_MODES then
		assert(debug_log("invalid arm state: bad hint_mode (" .. SAVE_STATE_HINT_MODE .. ")"))
		return false
	end

	-- Check angle ranges.
	if state[SAVE_STATE_BOTTOM_ARM] ~= normalize_angle(state[SAVE_STATE_BOTTOM_ARM]) or
	   state[SAVE_STATE_BOTTOM_HAND] ~= normalize_angle(state[SAVE_STATE_BOTTOM_HAND]) or
	   state[SAVE_STATE_TOP_ARM] ~= normalize_angle(state[SAVE_STATE_TOP_ARM]) or
	   state[SAVE_STATE_TOP_HAND] ~= normalize_angle(state[SAVE_STATE_TOP_HAND]) then
		assert(debug_log("invalid arm state: bad joint angles"))
		return false
	end

	-- Check that one end of the arm is attached to a mount point.
	if state[SAVE_STATE_ATTACHMENT] == 1 then
		-- Bottom attached.
		local bottom_wrist_x <const> = state[SAVE_STATE_ELBOW_X] + wrist_offsets[state[SAVE_STATE_BOTTOM_ARM]][1]
		local bottom_wrist_y <const> = state[SAVE_STATE_ELBOW_Y] + wrist_offsets[state[SAVE_STATE_BOTTOM_ARM]][2]
		if not world.check_mount_angle(bottom_wrist_x, bottom_wrist_y, state[SAVE_STATE_BOTTOM_HAND]) then
			assert(debug_log("invalid arm state: bad mount (bottom)"))
			return false
		end
	elseif state[SAVE_STATE_ATTACHMENT] == 2 then
		-- Top attached.
		local top_wrist_x <const> = state[SAVE_STATE_ELBOW_X] + wrist_offsets[state[SAVE_STATE_TOP_ARM]][1]
		local top_wrist_y <const> = state[SAVE_STATE_ELBOW_Y] + wrist_offsets[state[SAVE_STATE_TOP_ARM]][2]
		if not world.check_mount_angle(top_wrist_x, top_wrist_y, state[SAVE_STATE_TOP_HAND]) then
			assert(debug_log("invalid arm state: bad mount (top)"))
			return false
		end
	else
		-- Bad attachment bit.
		assert(debug_log("invalid arm state: bad attachment (" .. SAVE_STATE_ATTACHMENT .. ")"))
		return false
	end

	-- Check holding index.
	if state[SAVE_STATE_HOLD] < 0 or state[SAVE_STATE_HOLD] > #world.INIT_BALLS then
		assert(debug_log("invalid arm state: bad hold (" .. SAVE_STATE_HOLD .. ")"))
		return false
	end

	-- Check start position.
	if state[SAVE_STATE_START] < 1 or state[SAVE_STATE_START] > #world.START then
		assert(debug_log("invalid arm state: bad start (" .. SAVE_STATE_START .. ")"))
		return false
	end

	-- All good.
	return true
end

-- Serialize a subset of the world state into a table.
function arm.encode_save_state()
	return
	{
		[SAVE_STATE_JOINT_MODE] = arm.joint_mode,
		[SAVE_STATE_HINT_MODE] = arm.hint_mode,
		[SAVE_STATE_ELBOW_X] = arm.elbow_x,
		[SAVE_STATE_ELBOW_Y] = arm.elbow_y,
		[SAVE_STATE_ATTACHMENT] = arm.bottom_attached and 1 or 2,
		[SAVE_STATE_BOTTOM_ARM] = arm.bottom.arm,
		[SAVE_STATE_BOTTOM_HAND] = arm.bottom.hand,
		[SAVE_STATE_TOP_ARM] = arm.top.arm,
		[SAVE_STATE_TOP_HAND] = arm.top.hand,
		[SAVE_STATE_START] = arm.start,
		[SAVE_STATE_HOLD] = arm.hold,
		[SAVE_STATE_STEP_COUNT] = arm.step_count,
		-- arm.bottom.opening and arm.top.opening are not saved, since we
		-- will derive that from attachment state.
		--
		-- All the joint positions and action plans are not saved either,
		-- we will re-derive those after load.
	}
end

-- Load saved state.  Returns false on error.
function arm.load_saved_state(state)
	arm.joint_mode = state[SAVE_STATE_JOINT_MODE]
	arm.hint_mode = state[SAVE_STATE_HINT_MODE]
	arm.elbow_x = state[SAVE_STATE_ELBOW_X]
	arm.elbow_y = state[SAVE_STATE_ELBOW_Y]
	arm.hold = state[SAVE_STATE_HOLD]
	local hand_opening = 0
	if arm.hold > 0 then
		hand_opening = GRAB_OPENING_ANGLE
		world.reset_ball_history(arm.hold)
	end
	if state[SAVE_STATE_ATTACHMENT] == 1 then
		arm.bottom_attached = true
		arm.bottom.opening = 90
		arm.top.opening = hand_opening
		if arm.hold > 0 then
			world.update_ball_for_hold(arm.hold, Z_TOP_CAPTURED_OBJECT)
		end
	else
		arm.bottom_attached = false
		arm.bottom.opening = hand_opening
		arm.top.opening = 90
		if arm.hold > 0 then
			world.update_ball_for_hold(arm.hold, Z_BOTTOM_CAPTURED_OBJECT)
		end
	end
	arm.bottom.arm = state[SAVE_STATE_BOTTOM_ARM]
	arm.bottom.hand = state[SAVE_STATE_BOTTOM_HAND]
	arm.top.arm = state[SAVE_STATE_TOP_ARM]
	arm.top.hand = state[SAVE_STATE_TOP_HAND]
	arm.start = state[SAVE_STATE_START]
	arm.step_count = state[SAVE_STATE_STEP_COUNT]

	-- Refresh joint positions.
	arm.update()

	-- Do one last sanity check, basically checking for unexpected joint
	-- collisions with the world.  This couldn't be folded into
	-- arm.is_valid_save_state() because it requires world state to
	-- be loaded first.
	if not try_joint_update_based_on_attachment(0, false, false, false) then
		return false
	end

	-- Update focus area, but don't update sprite offsets.  Sprite offsets
	-- are already updated by world.load_saved_state().
	arm.update_focus()

	-- Synchronize deltas and apply a no-op update to refresh action_target.
	local crank = normalize_angle(floor(playdate.getCrankPosition()))
	synchronize_deltas(crank)
	apply_update(crank, false, false, false)
	return true
end

-- Extra local variables.  These are intended to use up all remaining
-- available local variable slots, such that any extra variable causes
-- pdc to spit out an error.  In effect, these help us measure how many
-- local variables we are currently using.
--
-- The extra variables will be removed by ../data/strip_lua.pl
local extra_local_variable_1 <const> = 172
local extra_local_variable_2 <const> = 173
local extra_local_variable_3 <const> = 174
local extra_local_variable_4 <const> = 175
local extra_local_variable_5 <const> = 176
local extra_local_variable_6 <const> = 177
local extra_local_variable_7 <const> = 178
local extra_local_variable_8 <const> = 179
local extra_local_variable_9 <const> = 180
local extra_local_variable_10 <const> = 181
local extra_local_variable_11 <const> = 182
local extra_local_variable_12 <const> = 183
local extra_local_variable_13 <const> = 184
local extra_local_variable_14 <const> = 185
local extra_local_variable_15 <const> = 186
local extra_local_variable_16 <const> = 187
local extra_local_variable_17 <const> = 188
local extra_local_variable_18 <const> = 189
local extra_local_variable_19 <const> = 190
local extra_local_variable_20 <const> = 191
local extra_local_variable_21 <const> = 192
local extra_local_variable_22 <const> = 193
local extra_local_variable_23 <const> = 194
local extra_local_variable_24 <const> = 195
local extra_local_variable_25 <const> = 196
local extra_local_variable_26 <const> = 197
local extra_local_variable_27 <const> = 198
local extra_local_variable_28 <const> = 199
local extra_local_variable_29 <const> = 200
local extra_local_variable_30 <const> = 201
local extra_local_variable_31 <const> = 202
local extra_local_variable_32 <const> = 203
local extra_local_variable_33 <const> = 204
local extra_local_variable_34 <const> = 205
local extra_local_variable_35 <const> = 206
local extra_local_variable_36 <const> = 207
local extra_local_variable_37 <const> = 208
local extra_local_variable_38 <const> = 209
local extra_local_variable_39 <const> = 210
local extra_local_variable_40 <const> = 211
local extra_local_variable_41 <const> = 212
local extra_local_variable_42 <const> = 213
local extra_local_variable_43 <const> = 214
local extra_local_variable_44 <const> = 215
local extra_local_variable_45 <const> = 216
local extra_local_variable_46 <const> = 217
local extra_local_variable_47 <const> = 218
local extra_local_variable_48 <const> = 219
local extra_local_variable_49 <const> = 220

--}}}
