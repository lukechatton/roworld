-- Protocol on REAL Sim data: every delta of a multiplayer-config match (the map's nations + 90 tribes +
-- AF humans that expand like players) is encoded, compressed, decoded and compared with the original
-- (decode(encode(x)) == x), and a client GameState fed only from decoded wire deltas must match the Sim's
-- grid exactly. Snapshots are round-tripped at several minutes. Reports per-client bandwidth.
-- Run: .bin/lune run tests/net_sim.luau [minutes=15] [humans=4] [map=pangaea]
require("./fixtures/fixture_maps") -- the test-only maps (Pangaea, Onion)
local process = require("@lune/process")
local U = require("./net_util")
local Protocol = require("../src/shared/Net/Protocol")
local WorldMap = require("../src/shared/Core/WorldMap")
local GameState = require("../src/shared/Core/GameState")
local Sim = require("../src/shared/Core/Sim")
U.use_zstd(Protocol)

local minutes = tonumber(process.args[1]) or 15
local nhumans = tonumber(process.args[2]) or 4
local map_id = process.args[3] or "pangaea"
local TICKS = minutes * 600
local EV_MSG = 19

local map = WorldMap.get(map_id)
local W = map.W
print(("map %s %dx%d"):format(map_id, W, map.H))
local t0 = os.clock()
local sim =
	Sim.new(map, { seed = 7, difficulty = 1, tribes = 90, max_humans = 32, time_limit_s = 2400, spawn_ticks = 200 })
print(("Sim.new %.0f ms"):format((os.clock() - t0) * 1000))

-- humans: join, pick a spawn on free inland land, then keep expanding / attacking like players
local humans = {}
for k = 1, nhumans do
	local id = sim:add_human("h" .. k, "Player " .. k)
	table.insert(humans, id)
end

local function snapshot_rt(label)
	local s0 = os.clock()
	local snap = sim:snapshot()
	local s1 = os.clock()
	local raw = Protocol.encode_snapshot(snap)
	local s2 = os.clock()
	local z = Protocol.compress(raw)
	local s3 = os.clock()
	local back = Protocol.decode_snapshot(z)
	local s4 = os.clock()
	U.assert_eq(snap, back, "snapshot " .. label)
	print(
		("  snapshot %s: raw %.1f KB, zstd %.1f KB | snapshot() %.1f ms, encode %.1f ms, zstd %.1f ms, decode %.1f ms"):format(
			label,
			buffer.len(raw) / 1024,
			buffer.len(z) / 1024,
			(s1 - s0) * 1000,
			(s2 - s1) * 1000,
			(s3 - s2) * 1000,
			(s4 - s3) * 1000
		)
	)
	return back
end

-- client mirror fed only from the wire (one human's view: its private MSGs included)
local viewer = humans[1] or 0
local mirror = GameState.new(map)
mirror:load_snapshot(snapshot_rt("t=0"))
mirror.local_owner = viewer

local EV_BONUS = 34
local function is_private(e)
	if e[1] == EV_MSG and e[2] ~= -1 then
		return e[2]
	end
	-- (MatchServer.is_private: a player's income popups are theirs alone)
	if e[1] == EV_BONUS then
		return e[2]
	end
	return nil
end

local sec_bytes, sec_ticks = 0, 0
local per_sec = {}
local minute_bytes = {}
local max_delta, max_raw = 0, 0
local total_raw, total_z = 0, 0
local step_ms, enc_ms, dec_ms = 0, 0, 0
local step_max = 0
local events, paths = 0, 0
local rng_state = 99
local function rnd(n)
	rng_state = (rng_state * 1103515245 + 12345) % 2147483648
	return rng_state % n
end

local function human_play()
	for _, id in humans do
		if sim.o_alive[id] == 1 then
			if sim.o_spawned[id] == 0 then
				for _ = 1, 50 do
					local t = map:land_tile(rnd(map.land_count))
					if map:is_contestable(t) and buffer.readi32(sim.owner, t * 4) == 0 then
						sim:submit(id, { type = "spawn", tile = t })
						break
					end
				end
			elseif sim.tick % 30 == 0 then
				-- expand into a neighbour's / free land at the border
				local t = sim.o_spawn_tile and sim.o_spawn_tile[id] or -1
				if t and t >= 0 then
					local tt = t + W * (rnd(21) - 10) + rnd(21) - 10
					if tt >= 0 and tt < map.N then
						sim:submit(id, { type = "attack", tile = tt, ratio = 0.3 })
					end
				end
				if sim.tick % 300 == 0 then
					sim:submit(id, { type = "build", kind = "city", tile = t })
				end
			end
		end
	end
end

local t_start = os.clock()
for i = 1, TICKS do
	human_play()
	local a = os.clock()
	local d = sim:step()
	local b = os.clock()
	local public, privates = Protocol.split_events(d.ev, is_private)
	local shared = Protocol.compress(Protocol.encode_delta(d, public, W))
	local tail = if privates and privates[viewer] then Protocol.encode_tail(privates[viewer], W) else nil
	local c = os.clock()
	-- full round trip against the original delta (public + the viewer's private events)
	local back = Protocol.decode_delta(shared, tail)
	local e = os.clock()
	local expect = table.clone(d)
	local evs = {}
	for _, ev in d.ev or {} do
		if not ((ev[1] == EV_MSG and ev[2] ~= -1 and ev[2] ~= viewer) or (ev[1] == EV_BONUS and ev[2] ~= viewer)) then
			table.insert(evs, ev)
		end
		events += 1
		if ev[1] == 9 or ev[1] == 28 then
			paths += 1
		end
	end
	expect.ev = evs
	U.assert_eq(expect, back, "delta t=" .. d.t)
	mirror:apply_delta(back)
	step_ms += (b - a) * 1000
	step_max = math.max(step_max, (b - a) * 1000)
	enc_ms += (c - b) * 1000
	dec_ms += (e - c) * 1000
	local bytes = buffer.len(shared) + (if tail then buffer.len(tail) else 0)
	total_raw += buffer.len(Protocol.encode_delta(d, public, W))
	total_z += bytes
	max_delta = math.max(max_delta, bytes)
	sec_bytes += bytes
	sec_ticks += 1
	if sec_ticks == 10 then
		table.insert(per_sec, sec_bytes)
		sec_bytes, sec_ticks = 0, 0
	end
	if i % 600 == 0 then
		local m = i // 600
		local from = #per_sec - 59
		local sum, peak = 0, 0
		for k = math.max(1, from), #per_sec do
			sum += per_sec[k]
			peak = math.max(peak, per_sec[k])
		end
		minute_bytes[m] = sum
		local grid_ok = buffer.tostring(mirror.owner) == buffer.tostring(sim.owner)
		local units = 0
		for _ in sim.unit_list or {} do
			units += 1
		end
		print(
			("minute %2d: %.2f KB/s avg, %.2f KB/s peak second | step %.2f ms avg | ev/tick %.1f | units %d | mirror grid %s"):format(
				m,
				sum / 60 / 1024,
				peak / 1024,
				step_ms / i,
				events / i,
				units,
				grid_ok and "== sim" or "DIFFERS"
			)
		)
		assert(grid_ok, "mirror grid diverged")
		if m == 1 or m == 5 or m == 10 or m == minutes then
			snapshot_rt(("minute %d"):format(m))
		end
	end
	if sim.phase == 2 then
		print("match over at tick " .. sim.tick)
		break
	end
end
local secs = #per_sec
table.sort(per_sec)
print(
	("\n%d ticks in %.1f s | step avg %.2f ms, max %.1f ms | encode+zstd avg %.3f ms/tick | decode avg %.3f ms/tick"):format(
		sim.tick,
		os.clock() - t_start,
		step_ms / sim.tick,
		step_max,
		enc_ms / sim.tick,
		dec_ms / sim.tick
	)
)
print(
	("bandwidth per client: avg %.2f KB/s, p50 %.2f, p95 %.2f, max %.2f KB/s | largest delta %d B | raw→wire %.1f%%"):format(
		total_z / math.max(1, secs) / 1024,
		(per_sec[math.max(1, secs // 2)] or 0) / 1024,
		(per_sec[math.max(1, math.floor(secs * 0.95))] or 0) / 1024,
		(per_sec[secs] or 0) / 1024,
		max_delta,
		100 * total_z / math.max(1, total_raw)
	)
)
print(("events %d (%d unit paths) — all deltas round-tripped exactly"):format(events, paths))
print("net_sim ok")
