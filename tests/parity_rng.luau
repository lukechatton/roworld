-- sim-parity: tools/parity/GodotRng.luau must reproduce Godot's RandomNumberGenerator bit for bit
-- (expected values tools/parity/rng_ref.txt printed by tools/parity/rng_ref.gd in the Airship Editor).
--   .bin/lune run tests/parity_rng.luau
local fs = require("@lune/fs")
local G = require("../tools/parity/GodotRng")

local lines = string.split(fs.readFile("tools/parity/rng_ref.txt"), "\n")
local failures = 0
local checks = 0
local function expect(cond: boolean, what: string)
	checks += 1
	if not cond then
		failures += 1
		if failures < 20 then
			print("FAIL " .. what)
		end
	end
end

local function hexf(x: number): string
	local b = buffer.create(8)
	buffer.writef64(b, 0, x)
	local out = {}
	for i = 0, 7 do
		out[#out + 1] = string.format("%02x", buffer.readu8(b, i))
	end
	return table.concat(out)
end

local li = 1
local function nextline(): { string }
	local l = lines[li]
	li += 1
	return string.split(l, " ")
end

for _, s in { 1, 2, 3, 12345, 0, -7 } do
	local w = nextline()
	expect(tonumber(w[3]) == G.hash_int(s), string.format("hash(%d) = %s, got %d", s, w[3], G.hash_int(s)))
end
for _, s in { 1, 2, 3, 12345 } do
	local rng = G.new(s)
	local w = nextline()
	expect(w[4] == rng:state_string(), string.format("seed %d state %s got %s", s, w[4], rng:state_string()))
	w = nextline()
	for i = 1, 8 do
		local v = rng:randi()
		expect(tonumber(w[i + 1]) == v, string.format("seed %d randi #%d %s got %d", s, i, w[i + 1], v))
	end
	w = nextline()
	for i = 1, 8 do
		local v = rng:randf()
		expect(w[i + 1] == hexf(v), string.format("seed %d randf #%d %s got %s", s, i, w[i + 1], hexf(v)))
	end
	w = nextline()
	local k = 2
	for _, r in { { -3, 3, 8 }, { 0, 600, 8 }, { 5, 5, 4 }, { 0, 2147483646, 4 } } do
		for _ = 1, r[3] do
			local v = rng:randi_range(r[1], r[2])
			expect(tonumber(w[k]) == v, string.format("seed %d randi_range(%d,%d) %s got %d", s, r[1], r[2], w[k], v))
			k += 1
		end
	end
	w = nextline()
	k = 2
	for _, r in { { 0.8, 1.25 }, { 0.35, 0.65 } } do
		for _ = 1, 8 do
			local v = rng:randf_range(r[1], r[2])
			expect(w[k] == hexf(v), string.format("seed %d randf_range(%g,%g) %s got %s", s, r[1], r[2], w[k], hexf(v)))
			k += 1
		end
	end
	w = nextline()
	expect(w[2] == rng:state_string(), string.format("seed %d state_after %s got %s", s, w[2], rng:state_string()))
end
local rng2 = G.new(99)
for i = 1, 2000 do
	local v = rng2:randf()
	expect(lines[li] == hexf(v), string.format("bulk randf #%d %s got %s", i, lines[li], hexf(v)))
	li += 1
end
for i = 1, 2000 do
	local v = rng2:randf_range(0.5, 1.5)
	expect(lines[li] == hexf(v), string.format("bulk randf_range #%d %s got %s", i, lines[li], hexf(v)))
	li += 1
end
print(string.format("parity_rng: %d checks, %d failures", checks, failures))
if failures > 0 then
	error("parity_rng failed")
end
