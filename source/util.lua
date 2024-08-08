--[[ Miscellaneous utility functions.

This file contain small functions that are shared by other files, and also
a few workarounds for shortcomings of the SDK.

--]]

local gfx <const> = playdate.graphics
local floor <const> = math.floor
local abs <const> = math.abs

util = {}

-- Distance squared.
function util.distance2(dx, dy)
	return dx * dx + dy * dy
end
assert(util.distance2(0, 0) == 0)
assert(util.distance2(3, 4) == 5 * 5)

-- Round signed number.
function util.round(f)
	if f < 0 then
		return -util.round(-f)
	end
	return floor(f + 0.5)
end
local round <const> = util.round
assert(round(0) == 0)
assert(round(1) == 1)
assert(round(-1) == -1)
assert(round(10.4) == 10)
assert(round(10.5) == 11)
assert(round(10.6) == 11)
assert(round(-10.4) == -10)
assert(round(-10.5) == -11)
assert(round(-10.6) == -11)

-- Normalize an angle to make it fall in [0, 360) range.
function util.normalize_angle(a)
	if a < 0 then
		a += 360 * 4
	end
	return a % 360
end
local normalize_angle <const> = util.normalize_angle
assert(normalize_angle(0) == 0)
assert(normalize_angle(359) == 359)
assert(normalize_angle(360) == 0)
assert(normalize_angle(-1) == 359)

-- Compute the delta from a to b in the range of [-180, 180).
function util.angle_delta(a, b)
	if b < a then
		b += 360
	end

	local d = b - a
	if d < 180 then
		return d
	end
	return d - 360
end
local angle_delta <const> = util.angle_delta
assert(angle_delta(0, 0) == 0)
assert(angle_delta(90, 90) == 0)
assert(angle_delta(359, 359) == 0)
assert(angle_delta(0, 179) == 179)
assert(angle_delta(180, 359) == 179)
assert(angle_delta(181, 0) == 179)
assert(angle_delta(271, 90) == 179)
assert(angle_delta(0, 180) == -180)
assert(angle_delta(0, 359) == -1)
assert(angle_delta(1, 0) == -1)
assert(angle_delta(179, 0) == -179)
assert(angle_delta(269, 90) == -179)
assert(angle_delta(359, 180) == -179)
assert(angle_delta(89, 270) == -179)
assert(angle_delta(180, 0) == -180)
assert(angle_delta(270, 90) == -180)
assert(angle_delta(329, 149) == -180)
assert(angle_delta(90, 270) == -180)
assert(angle_delta(181, 0) == 179)
assert(angle_delta(271, 90) == 179)
assert(angle_delta(359, 178) == 179)
assert(angle_delta(89, 268) == 179)

-- Interpolate and normalize angle.
function util.interpolate_angle(start, delta, index, steps)
	return normalize_angle(start + ((delta * index) // steps))
end
assert(util.interpolate_angle(0, 45, 0, 3) == 0)
assert(util.interpolate_angle(0, 45, 1, 3) == 15)
assert(util.interpolate_angle(0, 45, 2, 3) == 30)
assert(util.interpolate_angle(0, 45, 3, 3) == 45)
assert(util.interpolate_angle(270, 240, 0, 6) == 270)
assert(util.interpolate_angle(270, 240, 1, 6) == 310)
assert(util.interpolate_angle(270, 240, 2, 6) == 350)
assert(util.interpolate_angle(270, 240, 3, 6) == 30)
assert(util.interpolate_angle(270, 240, 4, 6) == 70)
assert(util.interpolate_angle(270, 240, 5, 6) == 110)
assert(util.interpolate_angle(270, 240, 6, 6) == 150)
assert(util.interpolate_angle(45, -90, 0, 6) == 45)
assert(util.interpolate_angle(45, -90, 1, 6) == 30)
assert(util.interpolate_angle(45, -90, 2, 6) == 15)
assert(util.interpolate_angle(45, -90, 3, 6) == 0)
assert(util.interpolate_angle(45, -90, 4, 6) == 345)
assert(util.interpolate_angle(45, -90, 5, 6) == 330)
assert(util.interpolate_angle(45, -90, 6, 6) == 315)

-- Given two rotating joints, return true if their rotation would overlap.
function util.overlapping_rotation(a0, a_delta, b0, b_delta, margin)
	assert(a0 == normalize_angle(a0))
	assert(b0 == normalize_angle(b0))
	assert(abs(a_delta) <= 180)
	assert(abs(b_delta) <= 180)
	assert(margin >= 0)

	-- Zero out one of the initial angle values.  We are still solving the same
	-- problem, just with more convenient frame of reference.
	b0 = normalize_angle(b0 - a0)

	-- Check if the two joints already overlap at the start.
	if abs(angle_delta(0, b0)) <= margin then
		return true
	end

	-- If the two joints rotating at the same speed in the same direction,
	-- they will either overlap at the beginning or never overlap.
	--
	-- We already checked for initial overlap above, so here we can reject
	-- rotations of the same speed and magnitude.
	if a_delta == b_delta then
		return false
	end

	-- Check if the two joints overlap at the end.
	local end_a <const> = normalize_angle(a_delta)
	local end_b <const> = normalize_angle(b0 + b_delta)
	if abs(angle_delta(end_a, end_b)) <= margin then
		return true
	end

	-- Solve for the time for when the two joint angles overlap:
	--
	--  angle = time * a_delta
	--  angle = time * b_delta + b0
	--  time = b0 / (a_delta - b_delta)
	--
	-- To account for 360 wraparound, we will duplicate one of the lines at
	-- +/-360.
	local d <const> = a_delta - b_delta
	for offset = -360, 360, 360 do
		local t <const> = (b0 + offset) / d

		-- t couldn't be at the boundaries, because those would have already
		-- been caught by earlier tests.
		assert(t ~= 0)
		assert(t ~= 1)

		-- If t is within bounds, it means the two joint angles overlap
		-- with zero margin at some point.
		if 0 < t and t < 1 then
			return true
		end

		-- If t is out of bounds, then the closest angular distance happened
		-- at either t=0 or t=1, but we already checked for those earlier,
		-- so we don't need to check them again.
	end
	return false
end

-- Test same rotation speeds.
assert(util.overlapping_rotation(0, 0,    0, 0,    0))
assert(util.overlapping_rotation(0, 1,    0, 1,    0))
assert(util.overlapping_rotation(0, 179,  0, 179,  0))
assert(util.overlapping_rotation(0, -1,   0, -1,   0))
assert(util.overlapping_rotation(0, -179, 0, -179, 0))
assert(not util.overlapping_rotation(0, 0,    1, 0,    0))
assert(not util.overlapping_rotation(0, 1,    1, 1,    0))
assert(not util.overlapping_rotation(0, 179,  1, 179,  0))
assert(not util.overlapping_rotation(0, -1,   1, -1,   0))
assert(not util.overlapping_rotation(0, -179, 1, -179, 0))
assert(util.overlapping_rotation(0, 0,    1, 0,    1))
assert(util.overlapping_rotation(0, 1,    1, 1,    1))
assert(util.overlapping_rotation(0, 179,  1, 179,  1))
assert(util.overlapping_rotation(0, -1,   1, -1,   1))
assert(util.overlapping_rotation(0, -179, 1, -179, 1))
assert(util.overlapping_rotation(0, 0,    355, 0,    5))
assert(util.overlapping_rotation(0, 1,    355, 1,    5))
assert(util.overlapping_rotation(0, 179,  355, 179,  5))
assert(util.overlapping_rotation(0, -1,   355, -1,   5))
assert(util.overlapping_rotation(0, -179, 355, -179, 5))

-- Test same rotation direction.
assert(util.overlapping_rotation(100, 80, 100, 40, 0))
assert(util.overlapping_rotation(100, 80, 140, 40, 0))

assert(not util.overlapping_rotation(100, 80, 180, 40, 0))
assert(    util.overlapping_rotation(100, 80, 180, 40, 40))

assert(    util.overlapping_rotation(80, 80, 100, 40, 0))
assert(    util.overlapping_rotation(60, 80, 100, 40, 0))
assert(not util.overlapping_rotation(59, 80, 140, 40, 0))
assert(    util.overlapping_rotation(59, 80, 140, 40, 42))

assert(util.overlapping_rotation(100, -80, 100, -40, 0))
assert(util.overlapping_rotation(140, -80, 100, -40, 0))

assert(not util.overlapping_rotation(180, -80, 100, -40, 0))
assert(    util.overlapping_rotation(180, -80, 100, -40, 40))

assert(    util.overlapping_rotation(100, -80, 80, -40, 0))
assert(    util.overlapping_rotation(100, -80, 60, -40, 0))
assert(not util.overlapping_rotation(140, -80, 59, -40, 0))
assert(    util.overlapping_rotation(140, -80, 59, -40, 42))

assert(util.overlapping_rotation(32, -140, 0,  -71, 0))
assert(util.overlapping_rotation(0,  140,  32, 71,  0))

-- Test opposite rotation direction.
assert(    util.overlapping_rotation(0, 50, 100, -50, 0))
assert(not util.overlapping_rotation(0, 50, 101, -50, 0))
assert(    util.overlapping_rotation(0, 50, 101, -50, 2))

assert(not util.overlapping_rotation(0, -50, 100, 50, 0))
assert(not util.overlapping_rotation(0, -50, 101, 50, 0))
assert(not util.overlapping_rotation(0, -50, 101, 50, 2))

assert(    util.overlapping_rotation(0,   -50, 260, 50, 0))
assert(    util.overlapping_rotation(359, -50, 260, 50, 0))
assert(not util.overlapping_rotation(1,   -50, 260, 50, 0))
assert(    util.overlapping_rotation(1,   -50, 260, 50, 2))
assert(not util.overlapping_rotation(0,   -50, 259, 50, 0))
assert(    util.overlapping_rotation(0,   -50, 259, 50, 2))

-- Validate an input table against an expected schema, where schema is
-- a table of ["key"]="type" pairs.  Valid types are "table", "int", "uint",
-- or "float".
--
-- Returns true if input passes validation.
function util.validate_state(schema, state)
	if not state then return false end
	if type(state) ~= "table" then return false end

	for k, t in pairs(schema) do
		if not state[k] then
			return false
		end

		if t == "table" then
			if type(state[k]) ~= "table" then
				return false
			end
		else
			assert(t == "int" or t == "uint" or t == "float")
			if type(state[k]) ~= "number" then
				return false
			end
			if t == "int" or t == "uint" then
				local n <const> = state[k]
				if n ~= floor(n) then
					return false
				end
				if t == "uint" and n < 0 then
					return false
				end
			end
		end
	end
	return true
end

assert(util.validate_state({}, {}))
assert(not util.validate_state({}, nil))
assert(not util.validate_state({}, 1))
assert(not util.validate_state({}, "{}"))

assert(util.validate_state({x = "table"}, {x = {}}))
assert(not util.validate_state({x = "table"}, {}))
assert(not util.validate_state({x = "table"}, {x = nil}))
assert(not util.validate_state({x = "table"}, {x = 1}))
assert(not util.validate_state({x = "table"}, {x = "{}"}))

assert(util.validate_state({n = "int"}, {n = 1}))
assert(util.validate_state({n = "int"}, {n = -1}))
assert(not util.validate_state({n = "int"}, {n = 2.5}))
assert(not util.validate_state({n = "int"}, {n = -2.5}))
assert(not util.validate_state({n = "int"}, {n = nil}))
assert(not util.validate_state({n = "int"}, {n = {}}))
assert(not util.validate_state({n = "int"}, {n = "{}"}))

assert(util.validate_state({n = "uint"}, {n = 1}))
assert(not util.validate_state({n = "uint"}, {n = -1}))
assert(not util.validate_state({n = "uint"}, {n = 2.5}))
assert(not util.validate_state({n = "uint"}, {n = -2.5}))
assert(not util.validate_state({n = "uint"}, {n = nil}))
assert(not util.validate_state({n = "uint"}, {n = {}}))
assert(not util.validate_state({n = "uint"}, {n = "{}"}))

assert(util.validate_state({n = "float"}, {n = 1}))
assert(util.validate_state({n = "float"}, {n = -1}))
assert(util.validate_state({n = "float"}, {n = 2.5}))
assert(util.validate_state({n = "float"}, {n = -2.5}))
assert(not util.validate_state({n = "float"}, {n = nil}))
assert(not util.validate_state({n = "float"}, {n = {}}))
assert(not util.validate_state({n = "float"}, {n = "{}"}))

assert(    util.validate_state({x = "int"},            {x = 1}))
assert(not util.validate_state({x = "int"},            {       y = 2}))
assert(    util.validate_state({x = "int", y = "int"}, {x = 1, y = 2}))
assert(not util.validate_state({x = "int", y = "int"}, {x = 1,        z = 3}))
assert(not util.validate_state({x = "int", y = "int"}, {}))

-- Workaround for rotatedImage shifting by (-1,-1).
-- https://devforum.play.date/t/image-rotatedimage-90-offsets-crops-pixels-by-1-1-new-in-sdk-1-12/7051/3
--
-- To check whether we need this workaround: set the constant below to
-- to false, start the game, and wait 10 seconds.  The spinning arrows in
-- help tooltips should be aligned.
--
-- This workaround is still needed as of SDK 2.2.0
local USE_ROTATION_WORKAROUND <const> = true

function util.rotated_image(image, angle)
	if angle == 0 then
		return image
	end

	if USE_ROTATION_WORKAROUND then
		local width <const>, height <const> = image:getSize()
		local transformed_image = gfx.image.new(width, height, gfx.kColorClear)
		gfx.pushContext(transformed_image)
		image:drawRotated(width / 2, height / 2, angle)
		gfx.popContext()
		return transformed_image
	end
	return image:rotatedImage(angle)
end

-- Workaround for transformed image dropping pixels.
--
-- Seems related to this bug:
-- https://devforum.play.date/t/image-edge-clipped-when-using-affine-transforms/3871
--
-- To check whether we need this workaround:
-- 0. Set the constant below to false,
-- 1. Insert "s_top:setVisible(false)" near the end of update_hand_sprites
--    function in arm.lua
-- 2. Start the game and make sure robot arm is attached on top hand.
-- 3. Rotate bottom hand and check the wrist circle.  If it's jumping around
--    every quarter turn (as opposed to remaining aligned for a full turn),
--    we will still need this workaround.
--
-- This workaround is still needed as of SDK 2.2.0
local USE_FLIP_WORKAROUND <const> = true

function util.vertically_flipped_image(image)
	if USE_FLIP_WORKAROUND then
		local width <const>, height <const> = image:getSize()
		local transformed_image = gfx.image.new(width, height, gfx.kColorClear)
		gfx.pushContext(transformed_image)
		image:draw(0, 0, gfx.kImageFlippedY)
		gfx.popContext()
		return transformed_image
	end

	local vertical_flip <const> = playdate.geometry.affineTransform.new(1, 0, 0, -1, 0, 0)
	return image:transformedImage(vertical_flip)
end

-- Extra local variables.  These are intended to use up all remaining
-- available local variable slots, such that any extra variable causes
-- pdc to spit out an error.  In effect, these help us measure how many
-- local variables we are currently using.
--
-- The extra variables will be removed by ../data/strip_lua.pl
local extra_local_variable_1 <const> = 9
local extra_local_variable_2 <const> = 10
local extra_local_variable_3 <const> = 11
local extra_local_variable_4 <const> = 12
local extra_local_variable_5 <const> = 13
local extra_local_variable_6 <const> = 14
local extra_local_variable_7 <const> = 15
local extra_local_variable_8 <const> = 16
local extra_local_variable_9 <const> = 17
local extra_local_variable_10 <const> = 18
local extra_local_variable_11 <const> = 19
local extra_local_variable_12 <const> = 20
local extra_local_variable_13 <const> = 21
local extra_local_variable_14 <const> = 22
local extra_local_variable_15 <const> = 23
local extra_local_variable_16 <const> = 24
local extra_local_variable_17 <const> = 25
local extra_local_variable_18 <const> = 26
local extra_local_variable_19 <const> = 27
local extra_local_variable_20 <const> = 28
local extra_local_variable_21 <const> = 29
local extra_local_variable_22 <const> = 30
local extra_local_variable_23 <const> = 31
local extra_local_variable_24 <const> = 32
local extra_local_variable_25 <const> = 33
local extra_local_variable_26 <const> = 34
local extra_local_variable_27 <const> = 35
local extra_local_variable_28 <const> = 36
local extra_local_variable_29 <const> = 37
local extra_local_variable_30 <const> = 38
local extra_local_variable_31 <const> = 39
local extra_local_variable_32 <const> = 40
local extra_local_variable_33 <const> = 41
local extra_local_variable_34 <const> = 42
local extra_local_variable_35 <const> = 43
local extra_local_variable_36 <const> = 44
local extra_local_variable_37 <const> = 45
local extra_local_variable_38 <const> = 46
local extra_local_variable_39 <const> = 47
local extra_local_variable_40 <const> = 48
local extra_local_variable_41 <const> = 49
local extra_local_variable_42 <const> = 50
local extra_local_variable_43 <const> = 51
local extra_local_variable_44 <const> = 52
local extra_local_variable_45 <const> = 53
local extra_local_variable_46 <const> = 54
local extra_local_variable_47 <const> = 55
local extra_local_variable_48 <const> = 56
local extra_local_variable_49 <const> = 57
local extra_local_variable_50 <const> = 58
local extra_local_variable_51 <const> = 59
local extra_local_variable_52 <const> = 60
local extra_local_variable_53 <const> = 61
local extra_local_variable_54 <const> = 62
local extra_local_variable_55 <const> = 63
local extra_local_variable_56 <const> = 64
local extra_local_variable_57 <const> = 65
local extra_local_variable_58 <const> = 66
local extra_local_variable_59 <const> = 67
local extra_local_variable_60 <const> = 68
local extra_local_variable_61 <const> = 69
local extra_local_variable_62 <const> = 70
local extra_local_variable_63 <const> = 71
local extra_local_variable_64 <const> = 72
local extra_local_variable_65 <const> = 73
local extra_local_variable_66 <const> = 74
local extra_local_variable_67 <const> = 75
local extra_local_variable_68 <const> = 76
local extra_local_variable_69 <const> = 77
local extra_local_variable_70 <const> = 78
local extra_local_variable_71 <const> = 79
local extra_local_variable_72 <const> = 80
local extra_local_variable_73 <const> = 81
local extra_local_variable_74 <const> = 82
local extra_local_variable_75 <const> = 83
local extra_local_variable_76 <const> = 84
local extra_local_variable_77 <const> = 85
local extra_local_variable_78 <const> = 86
local extra_local_variable_79 <const> = 87
local extra_local_variable_80 <const> = 88
local extra_local_variable_81 <const> = 89
local extra_local_variable_82 <const> = 90
local extra_local_variable_83 <const> = 91
local extra_local_variable_84 <const> = 92
local extra_local_variable_85 <const> = 93
local extra_local_variable_86 <const> = 94
local extra_local_variable_87 <const> = 95
local extra_local_variable_88 <const> = 96
local extra_local_variable_89 <const> = 97
local extra_local_variable_90 <const> = 98
local extra_local_variable_91 <const> = 99
local extra_local_variable_92 <const> = 100
local extra_local_variable_93 <const> = 101
local extra_local_variable_94 <const> = 102
local extra_local_variable_95 <const> = 103
local extra_local_variable_96 <const> = 104
local extra_local_variable_97 <const> = 105
local extra_local_variable_98 <const> = 106
local extra_local_variable_99 <const> = 107
local extra_local_variable_100 <const> = 108
local extra_local_variable_101 <const> = 109
local extra_local_variable_102 <const> = 110
local extra_local_variable_103 <const> = 111
local extra_local_variable_104 <const> = 112
local extra_local_variable_105 <const> = 113
local extra_local_variable_106 <const> = 114
local extra_local_variable_107 <const> = 115
local extra_local_variable_108 <const> = 116
local extra_local_variable_109 <const> = 117
local extra_local_variable_110 <const> = 118
local extra_local_variable_111 <const> = 119
local extra_local_variable_112 <const> = 120
local extra_local_variable_113 <const> = 121
local extra_local_variable_114 <const> = 122
local extra_local_variable_115 <const> = 123
local extra_local_variable_116 <const> = 124
local extra_local_variable_117 <const> = 125
local extra_local_variable_118 <const> = 126
local extra_local_variable_119 <const> = 127
local extra_local_variable_120 <const> = 128
local extra_local_variable_121 <const> = 129
local extra_local_variable_122 <const> = 130
local extra_local_variable_123 <const> = 131
local extra_local_variable_124 <const> = 132
local extra_local_variable_125 <const> = 133
local extra_local_variable_126 <const> = 134
local extra_local_variable_127 <const> = 135
local extra_local_variable_128 <const> = 136
local extra_local_variable_129 <const> = 137
local extra_local_variable_130 <const> = 138
local extra_local_variable_131 <const> = 139
local extra_local_variable_132 <const> = 140
local extra_local_variable_133 <const> = 141
local extra_local_variable_134 <const> = 142
local extra_local_variable_135 <const> = 143
local extra_local_variable_136 <const> = 144
local extra_local_variable_137 <const> = 145
local extra_local_variable_138 <const> = 146
local extra_local_variable_139 <const> = 147
local extra_local_variable_140 <const> = 148
local extra_local_variable_141 <const> = 149
local extra_local_variable_142 <const> = 150
local extra_local_variable_143 <const> = 151
local extra_local_variable_144 <const> = 152
local extra_local_variable_145 <const> = 153
local extra_local_variable_146 <const> = 154
local extra_local_variable_147 <const> = 155
local extra_local_variable_148 <const> = 156
local extra_local_variable_149 <const> = 157
local extra_local_variable_150 <const> = 158
local extra_local_variable_151 <const> = 159
local extra_local_variable_152 <const> = 160
local extra_local_variable_153 <const> = 161
local extra_local_variable_154 <const> = 162
local extra_local_variable_155 <const> = 163
local extra_local_variable_156 <const> = 164
local extra_local_variable_157 <const> = 165
local extra_local_variable_158 <const> = 166
local extra_local_variable_159 <const> = 167
local extra_local_variable_160 <const> = 168
local extra_local_variable_161 <const> = 169
local extra_local_variable_162 <const> = 170
local extra_local_variable_163 <const> = 171
local extra_local_variable_164 <const> = 172
local extra_local_variable_165 <const> = 173
local extra_local_variable_166 <const> = 174
local extra_local_variable_167 <const> = 175
local extra_local_variable_168 <const> = 176
local extra_local_variable_169 <const> = 177
local extra_local_variable_170 <const> = 178
local extra_local_variable_171 <const> = 179
local extra_local_variable_172 <const> = 180
local extra_local_variable_173 <const> = 181
local extra_local_variable_174 <const> = 182
local extra_local_variable_175 <const> = 183
local extra_local_variable_176 <const> = 184
local extra_local_variable_177 <const> = 185
local extra_local_variable_178 <const> = 186
local extra_local_variable_179 <const> = 187
local extra_local_variable_180 <const> = 188
local extra_local_variable_181 <const> = 189
local extra_local_variable_182 <const> = 190
local extra_local_variable_183 <const> = 191
local extra_local_variable_184 <const> = 192
local extra_local_variable_185 <const> = 193
local extra_local_variable_186 <const> = 194
local extra_local_variable_187 <const> = 195
local extra_local_variable_188 <const> = 196
local extra_local_variable_189 <const> = 197
local extra_local_variable_190 <const> = 198
local extra_local_variable_191 <const> = 199
local extra_local_variable_192 <const> = 200
local extra_local_variable_193 <const> = 201
local extra_local_variable_194 <const> = 202
local extra_local_variable_195 <const> = 203
local extra_local_variable_196 <const> = 204
local extra_local_variable_197 <const> = 205
local extra_local_variable_198 <const> = 206
local extra_local_variable_199 <const> = 207
local extra_local_variable_200 <const> = 208
local extra_local_variable_201 <const> = 209
local extra_local_variable_202 <const> = 210
local extra_local_variable_203 <const> = 211
local extra_local_variable_204 <const> = 212
local extra_local_variable_205 <const> = 213
local extra_local_variable_206 <const> = 214
local extra_local_variable_207 <const> = 215
local extra_local_variable_208 <const> = 216
local extra_local_variable_209 <const> = 217
local extra_local_variable_210 <const> = 218
local extra_local_variable_211 <const> = 219
local extra_local_variable_212 <const> = 220
