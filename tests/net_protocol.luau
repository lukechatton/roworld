-- Protocol round trips on synthetic data shaped like the Sim's (tests/net_sim.luau uses real Sim data),
-- on a non-1024-wide map of ~2.3M tiles (the biggest maps the importer's budget allows).
-- Run: .bin/lune run tests/net_protocol.luau
require("./prelude")
local U = require("./net_util")
local Protocol = require("../src/shared/Net/Protocol")
local Coop = require("../src/shared/Net/Coop")

local W, H = 2111, 1090
local TILE_COUNT = W * H
local MSG = 19

local function rt_value(v, what, gw: number?, cells: number?)
	local b = Protocol._write_value(v, gw or W, cells or TILE_COUNT)
	local back = Protocol._read_value(b)
	U.assert_eq(v, back, what)
	return buffer.len(b)
end

print("values")
rt_value(0, "zero")
rt_value(239, "small max")
rt_value(240, "240")
rt_value(-1, "-1")
rt_value(2 ^ 40 + 3, "big")
rt_value(-(2 ^ 40) - 7, "big neg")
rt_value(0xd9574bff, "rgba colour")
rt_value(0.35, "float")
rt_value(0 / 0, "nan")
rt_value(math.huge, "inf")
rt_value(-math.huge, "-inf")
rt_value("", "empty string")
rt_value("Côte d'Ivoire — ✈", "utf8")
rt_value(true, "true")
rt_value(false, "false")
rt_value({}, "empty table")
rt_value({ 1, "a", true, 2.5, { 3, 4 } }, "mixed array")
rt_value({ a = 1, b = { c = "x" }, d = {} }, "map")
rt_value({ 5, 6 }, "int pair")
rt_value({ 1, -5, 100000, 3 }, "int array")
rt_value(buffer.fromstring("raw\0bytes"), "buffer")
-- dense path: an east-west water path with diagonal moves and a few jumps, near the map's far end
do
	local path = {}
	local t = (H - 200) * W + 1500
	for i = 1, 400 do
		table.insert(path, t)
		local x, y = t % W, t // W
		if i % 3 == 0 then
			y += 1
		end
		if i % 50 == 0 then
			x += 5 -- escape
		end
		x += 1
		t = y * W + x
	end
	local n = rt_value(path, "dense path")
	U.check(n < 400 * 0.7, ("dense 400-tile path encodes in %d bytes"):format(n))
	U.check(path[400] > 2000000, "path tiles beyond 2M")
	rt_value(path, "dense path without a grid width (int array)", 0, 0)
	rt_value({ 7, 7, 7, 7, 7 }, "path standing still")
	rt_value({ TILE_COUNT - 1, 0, 1, 2 }, "path-ish with escapes at the grid ends")
	-- the edge columns are not neighbours (no wrap): W - 1 -> W is an escape, not a step
	rt_value({ W - 2, W - 1, W, W + 1 }, "path across the right edge")
end
-- big grids
do
	local grid = buffer.create(TILE_COUNT * 4)
	for y = 100, 200 do
		for x = 300, 500 do
			buffer.writei32(grid, (y * W + x) * 4, 1 + (x // 40) + (y // 30) * 7)
		end
	end
	local n = rt_value(grid, "i32 owner grid buffer")
	U.check(n < 20000, ("owner grid RLE %d bytes"):format(n))
	local fl = buffer.create(TILE_COUNT)
	buffer.fill(fl, 5000, 1, 300)
	rt_value(fl, "u8 flag grid buffer")
	local tgrid = table.create(TILE_COUNT, 0)
	for i = 1000, 2000 do
		tgrid[i] = 7
	end
	rt_value(tgrid, "table grid")
end

print("deltas")
local function sample_events()
	return {
		{ 0, 90, "Brave Lynx Clan", 0x44aa88ff, 1, 0 },
		{ 2, 1, 0 },
		{ 3, 90, 123456 },
		{ 4, 17, 0, 12, 123000 },
		{ 23, 17, 1, 350 },
		{ 9, 55, 1, 3, { 250000, 250001, 250002, 251026, 252050 }, 300, 195, 1200 },
		{ MSG, -1, 3, "France has conquered the world" },
		{ MSG, 12, 3, "Germany is attacking you!" },
		{ 14, 88, 12, 40, 5321, 230011 },
		{ MSG, 40, 1, "You eliminated Spain" },
		{ MSG, 12, 0, "Not enough gold for a City" },
		{ 29, 17, 55, 300, 330, true },
		{ 13, 55, 0, 123000, 12, 3 },
		{ 18, 3, 4, 0 },
	}
end

local function sample_delta(buffers: boolean)
	local tiles = {}
	for k = 0, 999 do
		local owner = 1 + (k // 100)
		-- tiles up to ~2.29M: packed tile * 1024 + owner reaches 2.3e9 (above 2^31)
		local tile = 200000 + k * 2000 + (k // 100) * W
		table.insert(tiles, tile * 1024 + owner)
	end
	local flags = { 12345 * 256 + 1, 2290000 * 256 + 1, 99 * 256 + 0 }
	local stats = {}
	for id = 1, 170 do
		for _, v in { id, 1000 + id, 50000 + id * 13, 120000 + id, 400000, 91 } do
			table.insert(stats, v)
		end
	end
	local function pack(list)
		if not buffers then
			return list
		end
		local b = buffer.create(#list * 4)
		for i, v in list do
			buffer.writei32(b, (i - 1) * 4, v)
		end
		return b
	end
	return { t = 1234, tiles = pack(tiles), flags = pack(flags), stats = pack(stats), ev = sample_events() }
end

for _, buffers in { false, true } do
	local d = sample_delta(buffers)
	local enc = Protocol.encode_delta(d, nil, W)
	U.assert_eq(d, Protocol.decode_delta(enc), "delta round trip")
	U.check(true, ("delta round trip (%s): %d bytes raw"):format(buffers and "buffers" or "tables", buffer.len(enc)))
end
do -- minimal deltas
	U.assert_eq({ t = 5 }, Protocol.decode_delta(Protocol.encode_delta({ t = 5 })), "t only")
	local d = { t = 6, tiles = {}, flags = {}, ev = {} }
	U.assert_eq(d, Protocol.decode_delta(Protocol.encode_delta(d)), "empty lists")
	local d2 = { t = 7, tiles = {}, ev = {}, future = { 1, 2 } }
	U.assert_eq(d2, Protocol.decode_delta(Protocol.encode_delta(d2)), "extra field")
end

-- Private MSG routing: shared body once + per-recipient tails == session.gd's _delta_for filter.
do
	local d = sample_delta(false)
	local function is_private(e)
		if e[1] == MSG and e[2] ~= -1 then
			return e[2]
		end
		return nil
	end
	local public, privates = Protocol.split_events(d.ev, is_private)
	local shared = Protocol.encode_delta(d, public, W)
	for _, owner in { 12, 40, 99 } do
		local expect = table.clone(d)
		local evs = {}
		for _, e in d.ev do
			if not (e[1] == MSG and e[2] ~= -1 and e[2] ~= owner) then
				table.insert(evs, e)
			end
		end
		expect.ev = evs
		local tail = if privates and privates[owner] then Protocol.encode_tail(privates[owner], W) else nil
		U.assert_eq(expect, Protocol.decode_delta(shared, tail), "private routing for owner " .. owner)
	end
	U.check(true, "private MSG events reach only their recipient, in original order")
end

print("snapshot")
local function sample_snapshot()
	local owner = buffer.create(TILE_COUNT * 4)
	for i = 0, TILE_COUNT - 1, 7 do
		if (i // W) % 3 == 0 then
			buffer.writei32(owner, i * 4, 1 + (i // 5000) % 200)
		end
	end
	local flags = buffer.create(TILE_COUNT)
	buffer.fill(flags, 10000, 1, 64)
	local owners = {}
	for id = 1, 200 do
		table.insert(owners, {
			id,
			"Nation " .. id,
			0x10203040 + id,
			id > 88 and 1 or 0,
			0,
			true,
			100 + id,
			5000,
			1000,
			90000,
			40,
			0,
			id * 1000,
		})
	end
	return {
		map_id = "test",
		map_w = W,
		map_h = H,
		t = 4321,
		phase = 1,
		phase_left = 0,
		time_limit_ticks = 24200,
		playing_since = 200,
		mirvs_launched = 0,
		winner = 0,
		over_reason = -1,
		owner = owner,
		flags = flags,
		owners = owners,
		structs = { { 1, 0, 12, 123000, 2, 400 }, { 2, 5, 13, 124000, 1, 450 } },
		built = { { 12, 2, 0, 0, 0, 0, 0, 1, 0 } },
		roads = { { 1, 1, 2 } },
		units = { { 55, 1, 3, { 250000, 250001, 250002, 251026 }, 300, 195, 1200, 0, 0, 0, 0, -1 } },
		shells = {},
		sam_missiles = { { 17, 60, 4300, 4330, true } },
		nukes = { { 60, 0, 13, 100, 200000, 4290, 80 } },
		attacks = { { 88, 12, 40, 5321, 230011 } },
		allies = { { 3, 4 } },
		requests = {},
	}
end
do
	local snap = sample_snapshot()
	local enc = Protocol.encode_snapshot(snap)
	U.assert_eq(snap, Protocol.decode_snapshot(enc), "snapshot round trip")
	U.check(true, ("snapshot round trip: %d bytes raw"):format(buffer.len(enc)))
	U.check(buffer.len(enc) < TILE_COUNT, "snapshot grids are run-length encoded (map_w x map_h)")
	-- decoding inside a Coop job yields between grid runs and still produces the same snapshot
	local job = Coop.job(function()
		return Protocol.decode_snapshot(enc)
	end)
	while not job:step(0.0005) do
	end
	U.check(job.ok, "snapshot decodes inside a Coop job")
	U.assert_eq(snap, job.result, "coop snapshot decode")
	print(("    (%d slices)"):format(job.slices))
end

print("compression")
U.use_zstd(Protocol)
do
	local d = sample_delta(true)
	local raw = Protocol.encode_delta(d, nil, W)
	local z = Protocol.compress(raw)
	U.check(buffer.len(z) < buffer.len(raw), ("zstd delta %d → %d bytes"):format(buffer.len(raw), buffer.len(z)))
	U.assert_eq(d, Protocol.decode_delta(z), "compressed delta round trip")
	local small = Protocol.encode_delta({ t = 1, ev = {} })
	U.check(Protocol.compress(small) == small, "small messages stay raw")
	local snap = sample_snapshot()
	local zs = Protocol.compress(Protocol.encode_snapshot(snap))
	U.assert_eq(snap, Protocol.decode_snapshot(zs), "compressed snapshot round trip")
	U.check(true, ("zstd snapshot %d bytes"):format(buffer.len(zs)))
end

print("intents")
do
	local cases = {
		{ type = "spawn", tile = 123456 },
		{ type = "attack", tile = 5, ratio = 0.35 },
		{ type = "boat", tile = 99, ratio = 1.0 },
		{ type = "build", kind = "city", tile = 1000 },
		{ type = "nuke", kind = "hydrogen", tile = 4000 },
		{ type = "retreat", attack_id = 77 },
		{ type = "move_warship", uid = 1234, tile = 777 },
		{ type = "ally_request", target = 88 },
		{ type = "ally_reply", target = 3, accept = true },
		{ type = "ally_reply", target = 3, accept = false },
		{ type = "ally_break", target = 4 },
		{ type = "donate", target = 4, troops = 50000 },
	}
	for _, it in cases do
		local b = Protocol.encode_intent(it)
		assert(b, "encodes " .. it.type)
		U.assert_eq(it, Protocol.decode_intent(b), "intent " .. it.type)
	end
	U.check(true, "all 11 intent types round-trip")
	U.assert_eq(
		{ type = "attack", tile = 5, ratio = 0.01 },
		Protocol.decode_intent(Protocol.encode_intent({ type = "attack", tile = 5, ratio = -3 })),
		"ratio clamped"
	)
	U.assert_eq(
		{ type = "donate", target = 4, troops = 0 },
		Protocol.decode_intent(Protocol.encode_intent({ type = "donate", target = 4, troops = -9 })),
		"troops floored at 0"
	)
	-- bulk builds / stacked bombs: an optional trailing amount byte (1..MAX_INTENT_AMOUNT)
	U.assert_eq(
		{ type = "build", kind = "city", tile = 77, amount = 10 },
		Protocol.decode_intent(Protocol.encode_intent({ type = "build", kind = "city", tile = 77, amount = 10 })),
		"build amount round-trips"
	)
	U.assert_eq(
		{ type = "nuke", kind = "atom", tile = 9, amount = 2 },
		Protocol.decode_intent(Protocol.encode_intent({ type = "nuke", kind = "atom", tile = 9, amount = 2 })),
		"nuke amount round-trips"
	)
	U.check(Protocol.encode_intent({ type = "build", kind = "city", tile = 1, amount = 0 }) == nil, "amount 0 never encoded")
	U.check(
		Protocol.encode_intent({ type = "build", kind = "city", tile = 1, amount = Protocol.MAX_INTENT_AMOUNT + 1 }) == nil,
		"amount above the cap never encoded"
	)
	do
		local b = Protocol.encode_intent({ type = "build", kind = "city", tile = 1, amount = 5 }) :: buffer
		local bad = buffer.create(buffer.len(b))
		buffer.copy(bad, 0, b)
		buffer.writeu8(bad, buffer.len(b) - 1, 200)
		U.check(Protocol.decode_intent(bad) == nil, "a forged amount above the cap is rejected")
		local long = buffer.create(buffer.len(b) + 1)
		buffer.copy(long, 0, b)
		U.check(Protocol.decode_intent(long) == nil, "trailing bytes past the amount are rejected")
	end
	U.check(Protocol.encode_intent({ type = "hack" }) == nil, "unknown type is never encoded")
	U.check(Protocol.encode_intent({ type = "attack", tile = 0 / 0 }) == nil, "NaN tile is never encoded")
	U.check(
		Protocol.decode_intent(Protocol.encode_intent({ type = "spawn", tile = Protocol.MAX_CELLS })) == nil,
		"tile beyond any map rejected (the Sim checks its own map size)"
	)
	U.assert_eq(
		{ type = "spawn", tile = 2300000 },
		Protocol.decode_intent(Protocol.encode_intent({ type = "spawn", tile = 2300000 })),
		"tile index above 2M accepted"
	)
	U.check(
		Protocol.decode_intent(Protocol.encode_intent({ type = "spawn", tile = -1 })) == nil,
		"negative tile rejected"
	)
	U.check(
		Protocol.decode_intent(Protocol.encode_intent({ type = "ally_request", target = 1024 })) == nil,
		"target out of range rejected"
	)
	U.check(
		Protocol.decode_intent("spawn") == nil and Protocol.decode_intent({ type = "spawn" }) == nil,
		"non-buffer payloads rejected"
	)
	U.check(Protocol.decode_intent(buffer.create(4000)) == nil, "oversized payload rejected")
	-- fuzz: random bytes never error and never produce an intent outside the whitelist
	local seed = 12345
	local function rnd(n)
		seed = (seed * 1103515245 + 12345) % 2147483648
		return seed % n
	end
	local produced = 0
	for _ = 1, 20000 do
		local len = 3 + rnd(30)
		local b = buffer.create(len)
		for i = 0, len - 1 do
			buffer.writeu8(b, i, rnd(256))
		end
		if rnd(2) == 0 then
			-- mutate a valid encoding
			local src = Protocol.encode_intent(cases[1 + rnd(#cases)]) :: buffer
			b = buffer.create(buffer.len(src))
			buffer.copy(b, 0, src)
			for _ = 1, 1 + rnd(2) do
				buffer.writeu8(b, rnd(buffer.len(b) - 2) + 2, rnd(256))
			end
		end
		local it = Protocol.decode_intent(b)
		if it then
			produced += 1
			assert(table.find(Protocol.INTENT_TYPES, it.type), "whitelisted type")
			for k, v in it do
				assert(
					({
						type = 1,
						tile = 1,
						target = 1,
						attack_id = 1,
						troops = 1,
						uid = 1,
						ratio = 1,
						kind = 1,
						accept = 1,
						amount = 1,
					})[k],
					"known key " .. k
				)
				if k == "tile" then
					assert(v >= 0 and v < Protocol.MAX_CELLS)
				end
				if k == "amount" then
					assert(v >= 1 and v <= Protocol.MAX_INTENT_AMOUNT)
				end
			end
		end
	end
	U.check(true, ("20000 random payloads decoded safely (%d accepted as valid intents)"):format(produced))
end

if U.failures() > 0 then
	error(U.failures() .. " failures")
end
print("net_protocol ok")
