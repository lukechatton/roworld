--!native
--!strict
-- Deterministic pseudo-random generator with the subset of Godot's RandomNumberGenerator API the
-- port uses: Rng.new(seed), rng.seed, rng:set_seed(s), rng:randi() (uint32 0..2^32-1),
-- rng:randf() ([0, 1)), rng:randi_range(a, b) (inclusive), rng:randf_range(a, b).
-- Pure Luau (bit32); xoshiro128** seeded through splitmix32. Bit-exact parity with Godot's PCG32 is
-- not a goal (behavioural parity is): same seed → same sequence on every Luau VM.
local Rng = {}
Rng.__index = Rng

export type Rng = typeof(setmetatable({} :: { seed: number, s0: number, s1: number, s2: number, s3: number }, Rng))

local band = bit32.band
local bxor = bit32.bxor
local lshift = bit32.lshift
local rshift = bit32.rshift
local lrotate = bit32.lrotate

local TWO32 = 4294967296

-- 32 x 32 → low 32 bits multiply (exact in doubles by splitting b into 16-bit halves).
local function imul(a: number, b: number): number
	local lo = band(b, 0xFFFF)
	local hi = rshift(b, 16)
	return band(a * lo + band(a * hi, 0xFFFF) * 65536, 0xFFFFFFFF)
end

local function splitmix32(x: number): (number, number)
	x = band(x + 0x9E3779B9, 0xFFFFFFFF)
	local z = x
	z = imul(bxor(z, rshift(z, 16)), 0x85EBCA6B)
	z = imul(bxor(z, rshift(z, 13)), 0xC2B2AE35)
	z = bxor(z, rshift(z, 16))
	return x, z
end

function Rng.new(seed: number?): Rng
	local self = setmetatable({ seed = 0, s0 = 0, s1 = 0, s2 = 0, s3 = 0 }, Rng)
	self:set_seed(seed or 0)
	return self
end

--- Resets the state from an integer seed (any sign / magnitude up to 2^53).
function Rng.set_seed(self: Rng, seed: number)
	self.seed = seed
	local lo = seed % TWO32
	local hi = ((seed - lo) / TWO32) % TWO32
	local x = band(bxor(lo, imul(hi, 0x27D4EB2F)), 0xFFFFFFFF)
	local z
	x, z = splitmix32(x)
	self.s0 = z
	x, z = splitmix32(x)
	self.s1 = z
	x, z = splitmix32(x)
	self.s2 = z
	x, z = splitmix32(x)
	self.s3 = z
	if self.s0 == 0 and self.s1 == 0 and self.s2 == 0 and self.s3 == 0 then
		self.s0 = 1
	end
end

--- Uniform uint32 (0 .. 4294967295), like RandomNumberGenerator.randi().
function Rng.randi(self: Rng): number
	local s0, s1, s2, s3 = self.s0, self.s1, self.s2, self.s3
	local result = band(lrotate(band(s1 * 5, 0xFFFFFFFF), 7) * 9, 0xFFFFFFFF)
	local t = lshift(s1, 9)
	s2 = bxor(s2, s0)
	s3 = bxor(s3, s1)
	s1 = bxor(s1, s2)
	s0 = bxor(s0, s3)
	s2 = bxor(s2, t)
	s3 = lrotate(s3, 11)
	self.s0, self.s1, self.s2, self.s3 = s0, s1, s2, s3
	return result
end

--- Uniform float in [0, 1).
function Rng.randf(self: Rng): number
	return self:randi() / TWO32
end

--- Uniform integer in [from, to] (either order), like randi_range.
function Rng.randi_range(self: Rng, from: number, to: number): number
	if from == to then
		return from
	end
	local lo = if from < to then from else to
	local hi = if from < to then to else from
	return lo + self:randi() % (hi - lo + 1)
end

--- Uniform float in [from, to), like randf_range.
function Rng.randf_range(self: Rng, from: number, to: number): number
	return self:randf() * (to - from) + from
end

-- Production: Godot's exact RandomNumberGenerator (PCG32), seeded like sim.gd's
-- `rng.seed = hash(int(seed))`, so a seed plays out exactly as in the original. The xoshiro
-- implementation above stays available as Rng.xoshiro(seed) for tools that want it.
local GodotRng = require("./GodotRng")
Rng.xoshiro = Rng.new
Rng.new = function(seed: number?): any
	return GodotRng.new(seed or 0)
end

return Rng
