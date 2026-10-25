--!native
-- sim-parity: bit-exact emulation of Godot 4's RandomNumberGenerator (RandomPCG = PCG32
-- XSH-RR, default increment, Godot's randf / randi_range / randf_range algorithms) and of
-- GDScript's hash(int). This is the PRODUCTION generator (Rng.new returns it): the port consumes
-- exactly the random numbers the original does for the same seed, so every seed plays out tick for
-- tick like the Godot game (verified by tests/parity_lockstep.luau against recorded traces).
--
-- 64-bit state is kept as two uint32 halves (hi, lo) in doubles.
local GodotRng = {}
GodotRng.__index = GodotRng

local band = bit32.band
local bor = bit32.bor
local bxor = bit32.bxor
local lshift = bit32.lshift
local rshift = bit32.rshift
local rrotate = bit32.rrotate
local countlz = bit32.countlz

local TWO32 = 4294967296
local TWO16 = 65536

-- low 32 bits of a (uint32) * b (uint32)
local function imul(a: number, b: number): number
	local lo = band(b, 0xFFFF)
	local hi = rshift(b, 16)
	return band(a * lo + band(a * hi, 0xFFFF) * 65536, 0xFFFFFFFF)
end

-- full 64-bit product of two uint32 → hi, lo
local function mul32x32(a: number, b: number): (number, number)
	local a0 = band(a, 0xFFFF)
	local a1 = rshift(a, 16)
	local b0 = band(b, 0xFFFF)
	local b1 = rshift(b, 16)
	local p0 = a0 * b0
	local mid = a1 * b0 + a0 * b1
	local p2 = a1 * b1
	local midlo = mid % TWO16
	local midhi = (mid - midlo) / TWO16
	local t = p0 + midlo * TWO16
	local lo = t % TWO32
	local carry = (t - lo) / TWO32
	local hi = (p2 + midhi + carry) % TWO32
	return hi, lo
end

-- (ahi,alo) * (bhi,blo) mod 2^64
local function mul64(ahi: number, alo: number, bhi: number, blo: number): (number, number)
	local hi, lo = mul32x32(alo, blo)
	hi = (hi + imul(ahi, blo) + imul(alo, bhi)) % TWO32
	return hi, lo
end

local function add64(ahi: number, alo: number, bhi: number, blo: number): (number, number)
	local lo = alo + blo
	local carry = 0
	if lo >= TWO32 then
		lo -= TWO32
		carry = 1
	end
	return (ahi + bhi + carry) % TWO32, lo
end

-- PCG32 multiplier 6364136223846793005 = 0x5851F42D_4C957F2D
local MHI, MLO = 0x5851F42D, 0x4C957F2D
-- PCG_DEFAULT_INC_64 = 1442695040888963407 = 0x14057B7E_F767814F
local DINC_HI, DINC_LO = 0x14057B7E, 0xF767814F

--- int64 (as a Luau number, |x| < 2^53) → hi, lo (two's complement)
local function split64(x: number): (number, number)
	if x >= 0 then
		local lo = x % TWO32
		return ((x - lo) / TWO32) % TWO32, lo
	end
	-- two's complement of |x|
	local ax = -x
	local lo = ax % TWO32
	local hi = ((ax - lo) / TWO32) % TWO32
	-- ~(hi,lo) + 1
	hi = TWO32 - 1 - hi
	lo = TWO32 - 1 - lo
	return add64(hi, lo, 0, 1)
end

local function shl64(hi: number, lo: number, n: number): (number, number)
	if n >= 32 then
		return lshift(lo, n - 32), 0
	end
	return bor(lshift(hi, n), rshift(lo, 32 - n)), lshift(lo, n)
end

local function shr64(hi: number, lo: number, n: number): (number, number)
	if n >= 32 then
		return 0, rshift(hi, n - 32)
	end
	return rshift(hi, n), bor(rshift(lo, n), lshift(hi, 32 - n))
end

--- GDScript hash(int): Variant::hash() → hash_one_uint64 (Thomas Wang 64→32).
function GodotRng.hash_int(x: number): number
	local hi, lo = split64(x)
	-- v = (~v) + (v << 18)
	local shi, slo = shl64(hi, lo, 18)
	hi, lo = add64(TWO32 - 1 - hi, TWO32 - 1 - lo, shi, slo)
	-- v = v ^ (v >> 31)
	shi, slo = shr64(hi, lo, 31)
	hi, lo = bxor(hi, shi), bxor(lo, slo)
	-- v = v * 21
	hi, lo = mul64(hi, lo, 0, 21)
	-- v = v ^ (v >> 11)
	shi, slo = shr64(hi, lo, 11)
	hi, lo = bxor(hi, shi), bxor(lo, slo)
	-- v = v + (v << 6)
	shi, slo = shl64(hi, lo, 6)
	hi, lo = add64(hi, lo, shi, slo)
	-- v = v ^ (v >> 22)
	shi, slo = shr64(hi, lo, 22)
	hi, lo = bxor(hi, shi), bxor(lo, slo)
	return lo
end

export type GodotRng = typeof(setmetatable(
	{} :: { seed: number, shi: number, slo: number, ihi: number, ilo: number, calls: number },
	GodotRng
))

--- A generator seeded like `rng.seed = hash(seed)` (pass raw = true to seed with `seed` directly).
function GodotRng.new(seed: number?, raw: boolean?): GodotRng
	local self = setmetatable({ seed = 0, shi = 0, slo = 0, ihi = 0, ilo = 0, calls = 0 }, GodotRng)
	local s = seed or 0
	if not raw then
		s = GodotRng.hash_int(s)
	end
	self:set_seed(s)
	return self
end

-- pcg32_random_r
local function step(self: GodotRng): number
	local ohi, olo = self.shi, self.slo
	local hi, lo = mul64(ohi, olo, MHI, MLO)
	self.shi, self.slo = add64(hi, lo, self.ihi, self.ilo)
	-- xorshifted = ((old >> 18) ^ old) >> 27 ; rot = old >> 59
	local s18hi, s18lo = shr64(ohi, olo, 18)
	local xhi, xlo = bxor(ohi, s18hi), bxor(olo, s18lo)
	local xs = bor(rshift(xlo, 27), lshift(xhi, 5))
	local rot = rshift(ohi, 27)
	return rrotate(xs, rot)
end

--- RandomPCG::seed(p_seed): pcg32_srandom_r(&pcg, p_seed, PCG_DEFAULT_INC_64).
function GodotRng.set_seed(self: GodotRng, seed: number)
	self.seed = seed
	local ihi, ilo = shl64(DINC_HI, DINC_LO, 1)
	self.ihi, self.ilo = ihi, bor(ilo, 1)
	self.shi, self.slo = 0, 0
	step(self)
	local sh, sl = split64(seed)
	self.shi, self.slo = add64(self.shi, self.slo, sh, sl)
	step(self)
end

--- The 64-bit PCG state as a signed int64 decimal string (RandomNumberGenerator.state).
function GodotRng.state_string(self: GodotRng): string
	local hi, lo = self.shi, self.slo
	local neg = hi >= 0x80000000
	if neg then
		hi, lo = add64(TWO32 - 1 - hi, TWO32 - 1 - lo, 0, 1)
	end
	-- decimal of hi*2^32+lo without losing precision: long division by 10^6 in base 2^32
	local digits = {}
	local h, l = hi, lo
	while h > 0 or l > 0 do
		-- (h*2^32 + l) / 1e6
		local qh = h // 1000000
		local rh = h % 1000000
		local cur = rh * TWO32 + l -- < 1e6 * 2^32 < 2^53
		local ql = cur // 1000000
		local r = cur % 1000000
		h, l = qh + ql // TWO32, ql % TWO32
		table.insert(digits, 1, string.format(if h > 0 or l > 0 then "%06d" else "%d", r))
	end
	local s = if #digits == 0 then "0" else table.concat(digits)
	return if neg then "-" .. s else s
end

--- A cheap state fingerprint (low 32 bits of the state).
function GodotRng.state_lo(self: GodotRng): number
	return self.slo
end

--- RandomNumberGenerator.randi(): uint32.
function GodotRng.randi(self: GodotRng): number
	self.calls += 1
	return step(self)
end

-- pcg32_boundedrand_r
local function bounded(self: GodotRng, bound: number): number
	local threshold = (TWO32 - bound) % bound
	while true do
		local r = step(self)
		if r >= threshold then
			return r % bound
		end
	end
end

local f32buf = buffer.create(4)
local function f32(x: number): number
	buffer.writef32(f32buf, 0, x)
	return buffer.readf32(f32buf, 0)
end
GodotRng.f32 = f32

--- RandomPCG::randf() (float): [0, 1] with Godot's exponent trick; a float32 value.
function GodotRng.randf(self: GodotRng): number
	self.calls += 1
	local proto = step(self)
	if proto == 0 then
		return 0.0
	end
	local significand = bor(step(self), 0x80000001)
	-- (float)significand rounds to nearest even; ldexp by a power of two is exact
	return f32(significand) * 2 ^ (-32 - countlz(proto))
end

--- RandomPCG::random(int from, int to): inclusive, unbiased.
function GodotRng.randi_range(self: GodotRng, from: number, to: number): number
	if from == to then
		return from
	end
	self.calls += 1
	local lo = if from < to then from else to
	local bound = math.abs(from - to) + 1
	return bounded(self, bound % TWO32) + lo
end

--- RandomPCG::random(float from, float to) = randf() * (to - from) + from, in float32.
--- FUSED selects fused multiply-add (clang contracts a*b+c on arm64) vs two roundings.
GodotRng.FUSED = false
function GodotRng.randf_range(self: GodotRng, from: number, to: number): number
	local r = self:randf()
	local a = f32(from)
	local b = f32(to)
	local d = f32(b - a)
	if GodotRng.FUSED then
		-- r * d is exact in double (24 x 24-bit mantissas); one rounding of the sum ~ fma
		return f32(r * d + a)
	end
	return f32(f32(r * d) + a)
end

return GodotRng
