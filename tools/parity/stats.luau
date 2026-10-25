-- sim-parity: AI-only (title-like) match statistics for one seed, with the port's own RNG or the
-- Godot-exact RNG (tools/parity/GodotRng.luau; with it the port reproduces the original exactly).
--   .bin/lune run tools/parity/stats.luau -- --seed=1 --minutes=15 --rng=port|godot [--tribes=80]
-- Prints one JSON line: landgrab % at 15..120 s (every 15 s), nukes / structures / roads / units /
-- attacks / alliances / alive per minute, and step time.
require("../../tests/prelude")
local process = require("@lune/process")
local serde = require("@lune/serde")

local Rng = require("../../src/shared/Core/Rng")
local Defs = require("../../src/shared/Core/Defs")
local WorldMap = require("../../src/shared/Core/WorldMap")
local Sim = require("../../src/shared/Core/Sim")
local GodotRng = require("./GodotRng")

local seed_v, minutes, rng_kind, tribes, diff = 1, 15, "port", 80, 1
for _, arg in process.args do
	local k, v = string.match(arg, "^%-%-([%w_]+)=(.*)$")
	if k == "seed" then
		seed_v = tonumber(v) :: number
	elseif k == "minutes" then
		minutes = tonumber(v) :: number
	elseif k == "rng" then
		rng_kind = v
	elseif k == "tribes" then
		tribes = tonumber(v) :: number
	elseif k == "diff" then
		diff = tonumber(v) :: number
	end
end

local orig_new = Rng.new
if rng_kind == "godot" then
	Rng.new = function(s: number?): any
		return GodotRng.new(s or 0)
	end
end
local sim =
	Sim.new(WorldMap.shared(), { seed = seed_v, difficulty = diff, tribes = tribes, max_humans = 0, time_limit_s = 0 })
Rng.new = orig_new

local out: { [string]: any } = { seed = seed_v, rng = rng_kind, tribes = tribes, landgrab = {}, minute = {} }
local contest = sim.map.contestable_count
local t_step = 0.0
for i = 1, minutes * 600 do
	local c0 = os.clock()
	sim:step()
	t_step += os.clock() - c0
	local since = sim.tick - sim.playing_since
	if since > 0 and since <= 1200 and since % 150 == 0 then
		local claimed = 0
		for id = 1, sim.owner_total do
			if sim.o_alive[id] == 1 then
				claimed += sim.o_tiles[id]
			end
		end
		out.landgrab[tostring(since // 10)] = 100.0 * claimed / contest
	end
	if sim.tick % 600 == 0 then
		local nat, tri = 0, 0
		for id = 1, sim.owner_total do
			if sim.o_alive[id] == 1 then
				if sim.o_kind[id] == Defs.KIND_NATION then
					nat += 1
				elseif sim.o_kind[id] == Defs.KIND_TRIBE then
					tri += 1
				end
			end
		end
		local sk = {}
		for k = 0, 5 do
			sk[k + 1] = 0
		end
		for _, s in sim.struct_list do
			if not s.dead and sim.structs[s.sid] == s then
				sk[s.kind + 1] += 1
			end
		end
		local live = 0
		for _, a in sim.attacks do
			if not a.dead then
				live += 1
			end
		end
		local al = 0
		for _ in sim.alliances do
			al += 1
		end
		out.minute[tostring(sim.tick // 600)] = {
			nukes = sim.nukes_launched,
			structs = sim:struct_total(),
			kinds = sk,
			roads = sim:road_total(),
			units = sim:unit_total(),
			attacks = live,
			alliances = al,
			nations = nat,
			tribes = tri,
		}
	end
end
out.step_ms = t_step * 1000 / (minutes * 600)
print(serde.encode("json", out))
