-- sim-core: headless Sim benchmark and contract test (port of ~/games/airfront/tests/sim_bench.gd).
--
--   .bin/lune run tests/sim_bench.luau -- --minutes=15 --seed=1 --human=1 --difficulty=1 --tribes=80
--   options: --map=<id> (a map id, default world)  --player=pro|basic  --mode=solo|mp
--            --lat= --lon= (human start, read as an equirectangular position on the map)
--            --png=N (write owner PNGs every N minutes to /private/tmp/rofront-sim via the repo's
--            Python venv)  --quiet=1 (no per-message lines)
--
-- Builds a Sim (the map's nations + N tribes + optionally one scripted human), runs it as fast as possible,
-- feeds every delta into a GameState and checks the mirror against the Sim (grid, flags, owners,
-- counts, structures, placement previews) every minute and a snapshot → fresh GameState every
-- 2 minutes, prints per-minute timing / world statistics in the same format as the original.
local process = require("@lune/process")
local fs = require("@lune/fs")

local Defs = require("../src/shared/Core/Defs")
local Ev = require("../src/shared/Core/Ev")
local Rules = require("../src/shared/Core/Rules")
local Rng = require("../src/shared/Core/Rng")
local WorldMap = require("../src/shared/Core/WorldMap")
local GameState = require("../src/shared/Core/GameState")
local SimState = require("../src/shared/Core/SimState")
local SimColors = require("../src/shared/Core/SimColors")
local Sim = require("../src/shared/Core/Sim")

local OUT_DIR = "/private/tmp/rofront-sim"

local minutes = 15
local seed_value = 1
local with_human = true
local png_every = 0
local difficulty = 1
local tribes = 80
local human_lat = 2.0
local human_lon = 22.0
local mode = "solo"
local player = "pro"
local quiet = false
local trace_human = false
local map_id = "world"

for _, arg in process.args do
	local k, v = string.match(arg, "^%-%-([%w_]+)=(.*)$")
	if k == nil then
		continue
	end
	if k == "minutes" then
		minutes = tonumber(v) or minutes
	elseif k == "seed" then
		seed_value = tonumber(v) or seed_value
	elseif k == "human" then
		with_human = v ~= "0"
	elseif k == "png" then
		png_every = tonumber(v) or 0
	elseif k == "difficulty" then
		difficulty = tonumber(v) or 1
	elseif k == "tribes" then
		tribes = tonumber(v) or tribes
	elseif k == "lat" then
		human_lat = tonumber(v) or human_lat
	elseif k == "lon" then
		human_lon = tonumber(v) or human_lon
	elseif k == "mode" then
		mode = v
	elseif k == "player" then
		player = v
	elseif k == "quiet" then
		quiet = v ~= "0"
	elseif k == "trace" then
		trace_human = v ~= "0"
	elseif k == "map" then
		map_id = v
	end
end

local MAP = WorldMap.get(map_id)
local W, H, N = MAP.W, MAP.H, MAP.N
local LAND: { number } = {}
for k = 0, MAP.land_count - 1 do
	LAND[k + 1] = MAP:land_tile(k)
end
local COAST: { number } = {}
for k = 0, MAP.coast_count - 1 do
	COAST[k + 1] = MAP:coast_tile(k)
end
local function coast_body(t: number): number
	return buffer.readu16(MAP.coast_body, t * 2)
end

local readi32 = buffer.readi32
local readu8 = buffer.readu8
local fmt = string.format
local ft = Defs.format_troops

local sim: any
local gs: any
local hid = 0
local failures = 0
local _next_human_think = 0
local _milestones: { [string]: number } = {}
local _max_wars_on_human = 0
local _human_dead_logged = false
local _sk: { [number]: number } = {}
local _s_built_ai = { [0] = 0, 0, 0, 0, 0, 0 }
local _s_built_h = { [0] = 0, 0, 0, 0, 0, 0 }
local _s_capt = { [0] = 0, 0, 0, 0, 0, 0 }
local _s_del = { [0] = 0, 0, 0, 0, 0, 0 }

local function clock_ms(): number
	return os.clock() * 1000
end

local function arr6(a: { [number]: number }): string
	return fmt("[%d, %d, %d, %d, %d, %d]", a[0], a[1], a[2], a[3], a[4], a[5])
end

local function count_keys(t: { [any]: any }): number
	local n = 0
	for _ in t do
		n += 1
	end
	return n
end

local function sorted_keys(t: { [number]: any }): { number }
	local ks = {}
	for k in t do
		table.insert(ks, k)
	end
	table.sort(ks)
	return ks
end

local function expect(cond: boolean, what: string)
	if cond then
		print("  ok   " .. what)
	else
		failures += 1
		print("FAIL " .. what)
	end
end

-- Approximate Godot var_to_bytes size of a delta (4 bytes per int / header, strings padded).
local function var_size(v: any): number
	local tv = type(v)
	if tv == "number" or tv == "boolean" then
		return if tv == "number" and (v ~= math.floor(v) or math.abs(v) > 2147483647) then 12 else 8
	elseif tv == "string" then
		return 8 + math.ceil(#v / 4) * 4
	elseif tv == "table" then
		local n = 8
		if v[1] ~= nil or next(v) == nil then
			for _, e in v do
				n += var_size(e)
			end
		else
			for k, e in v do
				n += var_size(k) + var_size(e)
			end
		end
		return n
	end
	return 4
end

local function delta_bytes(d: { [string]: any }): number
	local n = 8 + 4 * 16
	n += 8 + 4 * #d.tiles
	n += 8 + 4 * #d.flags
	if d.stats then
		n += 8 + 4 * #d.stats
	end
	n += var_size(d.ev)
	return n
end

local function stats(times: { number }): (number, number, number, number)
	if #times == 0 then
		return 0, 0, 0, 0
	end
	local sorted = table.clone(times)
	table.sort(sorted)
	local s = 0.0
	for _, v in sorted do
		s += v
	end
	local n = #sorted
	return s / n,
		sorted[math.min(n - 1, math.floor(n * 0.95)) + 1],
		sorted[n],
		sorted[math.min(n - 1, math.floor(n * 0.99)) + 1]
end

-- =============================================================================================
-- PNG output (optional, through the repo's Python venv)
-- =============================================================================================

local _terrain_rgb: buffer? = nil

local function _build_terrain_rgb()
	local pal = {
		[0] = { 12, 15, 58 },
		{ 22, 30, 86 },
		{ 74, 92, 58 },
		{ 96, 92, 66 },
		{ 118, 110, 100 },
		{ 150, 152, 146 },
		{ 215, 220, 228 },
	}
	local b = buffer.create(N * 3)
	for i = 0, N - 1 do
		local c = pal[readu8(sim.map.terrain, i)]
		buffer.writeu8(b, i * 3, c[1])
		buffer.writeu8(b, i * 3 + 1, c[2])
		buffer.writeu8(b, i * 3 + 2, c[3])
	end
	_terrain_rgb = b
end

local function _write_png(minute: number)
	if png_every <= 0 then
		return
	end
	if _terrain_rgb == nil then
		_build_terrain_rgb()
	end
	local img = buffer.create(N * 3)
	buffer.copy(img, 0, _terrain_rgb :: buffer, 0)
	local own = gs.owner
	local fl = gs.flags
	local cols = {}
	for id = 1, sim.owner_total do
		local r, g, b = Defs.rgba_bytes(sim.o_color[id])
		cols[id] = { r, g, b }
	end
	for i = 0, N - 1 do
		local o = readi32(own, i * 4)
		if bit32.band(readu8(fl, i), 1) ~= 0 then
			local g = if bit32.bxor(i % 2, (i // W) % 2) == 0 then 120 else 95
			buffer.writeu8(img, i * 3, g)
			buffer.writeu8(img, i * 3 + 1, g)
			buffer.writeu8(img, i * 3 + 2, g)
			continue
		end
		if o == 0 then
			continue
		end
		local x = i % W
		local border = (x < W - 1 and readi32(own, (i + 1) * 4) ~= o)
			or (x > 0 and readi32(own, (i - 1) * 4) ~= o)
			or (i >= W and readi32(own, (i - W) * 4) ~= o)
			or (i < N - W and readi32(own, (i + W) * 4) ~= o)
		local k = if border then 0.55 else 0.88
		local c = cols[o]
		for ch = 0, 2 do
			local v = readu8(img, i * 3 + ch)
			buffer.writeu8(img, i * 3 + ch, math.floor(v * (1.0 - 0.85) + c[ch + 1] * 0.85 * k))
		end
	end
	local function dot(t: number, r: number, g: number, b: number)
		if t < 0 or t >= N then
			return
		end
		buffer.writeu8(img, t * 3, r)
		buffer.writeu8(img, t * 3 + 1, g)
		buffer.writeu8(img, t * 3 + 2, b)
	end
	for _, s in gs.structures do
		if s.kind <= Defs.S_FACTORY then
			dot(s.tile, 255, 255, 255)
		else
			dot(s.tile, 20, 20, 20)
		end
	end
	for _, u in gs.units do
		if u.kind == Defs.U_TRUCK then
			continue
		end
		local px, py = gs:unit_pose_xyz(u, gs.tick)
		local t = MAP:point_tile(px, py)
		if u.kind == Defs.U_TRANSPORT then
			dot(t, 255, 255, 255)
		elseif u.kind == Defs.U_WARSHIP then
			dot(t, 255, 40, 40)
		else
			dot(t, 255, 220, 60)
		end
	end
	fs.writeDir(OUT_DIR)
	local raw = fmt("%s/minute_%02d_s%d_h%d.rgb", OUT_DIR, minute, seed_value, if with_human then 1 else 0)
	fs.writeFile(raw, buffer.tostring(img))
	process.exec(".venv/bin/python", {
		"-c",
		fmt(
			"import sys; from PIL import Image; d=open(sys.argv[1],'rb').read(); Image.frombytes('RGB',(%d,%d),d).save(sys.argv[1][:-4]+'.png')",
			W,
			H
		),
		raw,
	})
	fs.removeFile(raw)
end

-- =============================================================================================
-- Checks
-- =============================================================================================

local function _check_placement(label: string)
	local rng = Rng.new(sim.tick)
	local bad = {}
	local checked = 0
	local tries = 0
	local ids = sorted_keys(sim.structs)
	while checked < 40 and tries < 400 do
		tries += 1
		local t = -1
		if rng:randf() < 0.5 and #ids > 0 then
			local st = sim.structs[ids[rng:randi() % #ids + 1]]
			t = st.tile + rng:randi_range(-3, 3) + rng:randi_range(-3, 3) * W
			t = math.clamp(t, 0, N - 1)
		else
			t = LAND[rng:randi() % #LAND + 1]
		end
		local id = readi32(sim.owner, t * 4)
		if id <= 0 then
			continue
		end
		checked += 1
		local kind = rng:randi_range(0, Defs.STRUCT_KIND_COUNT - 1)
		local name = Defs.STRUCT_NAMES[kind]
		local a = Rules.placement(gs, id, name, t)
		local b = sim:place(id, kind, t)
		local cost = Rules.build_cost_kind(kind, sim:cost_count(id, kind))
		if a.tile ~= b.tile or a.upgrade_sid ~= b.upgrade_sid or a.cost ~= cost then
			table.insert(
				bad,
				fmt(
					"%s@%d owner %d: preview %d/%d/%d sim %d/%d/%d",
					name,
					t,
					id,
					a.tile,
					a.upgrade_sid,
					a.cost,
					b.tile,
					b.upgrade_sid,
					cost
				)
			)
		end
	end
	if #bad > 0 then
		failures += 1
		print(fmt("FAIL %s: Rules.placement differs from the Sim on %d of %d clicks: %s", label, #bad, checked, bad[1]))
	end
end

local function _check_mirror(label: string)
	if buffer.tostring(gs.owner) ~= buffer.tostring(sim.owner) then
		failures += 1
		local diff = 0
		for i = 0, N - 1 do
			if readi32(gs.owner, i * 4) ~= readi32(sim.owner, i * 4) then
				diff += 1
			end
		end
		print(fmt("FAIL %s: GameState.owner differs from Sim grid (%d tiles)", label, diff))
	end
	if buffer.tostring(gs.flags) ~= buffer.tostring(sim.flags) then
		failures += 1
		print(fmt("FAIL %s: GameState.flags differ", label))
	end
	if gs.playing_since ~= sim.playing_since then
		failures += 1
		print(fmt("FAIL %s: playing_since %d/%d", label, gs.playing_since, sim.playing_since))
	end
	if gs.fallout_count ~= sim.fallout_count then
		failures += 1
		print(fmt("FAIL %s: fallout_count %d/%d", label, gs.fallout_count, sim.fallout_count))
	end
	for id = 1, sim.owner_total do
		local o = gs.owners[id]
		if o == nil then
			failures += 1
			print(fmt("FAIL %s: owner %d missing in mirror", label, id))
			continue
		end
		if o.tiles ~= sim.o_tiles[id] or o.alive ~= (sim.o_alive[id] == 1) then
			failures += 1
			print(
				fmt(
					"FAIL %s: owner %d tiles %d/%d alive %s/%d",
					label,
					id,
					o.tiles,
					sim.o_tiles[id],
					tostring(o.alive),
					sim.o_alive[id]
				)
			)
		end
		if o.rgba ~= sim.o_color[id] or o.name ~= sim.o_name[id] then
			failures += 1
			print(fmt("FAIL %s: owner %d colour/name mismatch", label, id))
		end
		if o.alive and (sim.o_spawned[id] == 1 or sim.o_kind[id] == Defs.KIND_HUMAN) and sim.tick % 5 == 0 then
			if
				o.troops ~= Defs.trunc(sim.o_troops[id])
				or o.gold ~= sim:_gold_int(id)
				or o.max_troops ~= Defs.trunc(sim.o_cap[id])
			then
				failures += 1
				print(
					fmt(
						"FAIL %s: owner %d stats troops %d/%d gold %d/%d",
						label,
						id,
						o.troops,
						Defs.trunc(sim.o_troops[id]),
						o.gold,
						sim:_gold_int(id)
					)
				)
			end
		end
	end
	if
		count_keys(gs.structures) ~= sim:struct_total()
		or count_keys(gs.units) ~= sim:unit_total()
		or count_keys(gs.roads) ~= sim:road_total()
	then
		failures += 1
		print(
			fmt(
				"FAIL %s: counts structs %d/%d units %d/%d roads %d/%d",
				label,
				count_keys(gs.structures),
				sim:struct_total(),
				count_keys(gs.units),
				sim:unit_total(),
				count_keys(gs.roads),
				sim:road_total()
			)
		)
	end
	if
		count_keys(gs.attacks) ~= count_keys(sim.attack_by_id)
		or count_keys(gs.alliances) ~= count_keys(sim.alliances)
		or count_keys(gs.nukes) ~= #sim.nukes
	then
		failures += 1
		print(
			fmt(
				"FAIL %s: attacks %d/%d alliances %d/%d nukes %d/%d",
				label,
				count_keys(gs.attacks),
				count_keys(sim.attack_by_id),
				count_keys(gs.alliances),
				count_keys(sim.alliances),
				count_keys(gs.nukes),
				#sim.nukes
			)
		)
	end
	if count_keys(gs.requests) ~= count_keys(sim.requests) then
		failures += 1
		print(fmt("FAIL %s: requests %d/%d", label, count_keys(gs.requests), count_keys(sim.requests)))
	end
	-- attacks: attacker / target / troops (troops as last sent)
	for aid, a in sim.attack_by_id do
		local g = gs.attacks[aid]
		if g == nil or g.attacker ~= a.attacker or g.target ~= a.target or g.troops ~= a.sent_troops then
			failures += 1
			print(fmt("FAIL %s: attack %d mirror mismatch", label, aid))
			break
		end
	end
	local sbad = 0
	for sid, ss in sim.structs do
		local gi = gs.structures[sid]
		if
			gi == nil
			or gi.owner ~= ss.owner
			or gi.level ~= ss.level
			or gi.active_tick ~= ss.active_tick
			or gi.kind ~= ss.kind
			or gi.tile ~= ss.tile
		then
			sbad += 1
		end
	end
	if sbad > 0 then
		failures += 1
		print(fmt("FAIL %s: %d structures differ (owner/level/active_tick)", label, sbad))
	end
	local ubad = 0
	for _, u in sim.unit_list do
		if u.dead then
			continue
		end
		local g = gs.units[u.uid]
		if g == nil or g.owner ~= u.owner or g.kind ~= u.kind then
			ubad += 1
		elseif
			u.kind == Defs.U_WARSHIP
			and (
				g.hp ~= u.hp
				or g.max_hp ~= u.max_hp
				or g.veterancy ~= u.vet
				or g.state ~= u.state
				or g.patrol_tile ~= u.patrol
				or g.start_tick ~= u.start_tick
				or #g.path ~= #u.path
			)
		then
			ubad += 1
		end
	end
	if ubad > 0 then
		failures += 1
		print(fmt("FAIL %s: %d units differ", label, ubad))
	end
	_check_placement(label)
end

local function _check_snapshot(label: string)
	local t0 = clock_ms()
	local snap = sim:snapshot()
	local t1 = clock_ms()
	local g2 = GameState.new(sim.map)
	g2:load_snapshot(snap)
	local t2 = clock_ms()
	print(
		fmt(
			"  snapshot %.1f ms (~%d KB), GameState.load %.1f ms",
			t1 - t0,
			math.floor((var_size(snap) + 2 * N * 4) / 1024),
			t2 - t1
		)
	)
	local bad = {}
	if buffer.tostring(g2.owner) ~= buffer.tostring(gs.owner) then
		table.insert(bad, "owner grid")
	end
	if buffer.tostring(g2.flags) ~= buffer.tostring(gs.flags) then
		table.insert(bad, "flags")
	end
	if
		g2.phase ~= gs.phase
		or g2.tick ~= gs.tick
		or g2.playing_since ~= gs.playing_since
		or g2.mirvs_launched ~= gs.mirvs_launched
	then
		table.insert(bad, "phase/tick/playing_since/mirvs")
	end
	for id, a in gs.owners do
		local b = g2.owners[id]
		if
			b == nil
			or a.tiles ~= b.tiles
			or a.alive ~= b.alive
			or a.name ~= b.name
			or a.kind ~= b.kind
			or a.rgba ~= b.rgba
		then
			table.insert(bad, "owner " .. id)
			continue
		end
		if
			a.alive
			and (
				a.troops ~= b.troops
				or a.gold ~= b.gold
				or a.max_troops ~= b.max_troops
				or a.traitor_until ~= b.traitor_until
			)
		then
			table.insert(
				bad,
				fmt(
					"owner %d stats troops %d/%d gold %d/%d cap %d/%d",
					id,
					a.troops,
					b.troops,
					a.gold,
					b.gold,
					a.max_troops,
					b.max_troops
				)
			)
		end
	end
	for sid, s in gs.structures do
		local s2 = g2.structures[sid]
		if
			s2 == nil
			or s.kind ~= s2.kind
			or s.owner ~= s2.owner
			or s.tile ~= s2.tile
			or s.level ~= s2.level
			or s.active_tick ~= s2.active_tick
		then
			table.insert(bad, "struct " .. sid)
		end
	end
	for id, b in gs.built do
		local b2 = g2.built[id]
		for k = 0, Rules.BUILT_SLOTS - 1 do
			if (b[k] or 0) ~= (if b2 then b2[k] or 0 else 0) then
				table.insert(bad, "built counts " .. id)
				break
			end
		end
	end
	if count_keys(g2.structures) ~= count_keys(gs.structures) then
		table.insert(bad, "struct count")
	end
	if count_keys(g2.roads) ~= count_keys(gs.roads) then
		table.insert(bad, "roads")
	end
	for uid, u in gs.units do
		local u2 = g2.units[uid]
		if u2 == nil or u.kind ~= u2.kind or u.owner ~= u2.owner then
			table.insert(bad, "unit " .. uid)
		elseif #u.path ~= #u2.path or u.start_tick ~= u2.start_tick or u.path[#u.path] ~= u2.path[#u2.path] then
			table.insert(bad, "unit path " .. uid)
		elseif
			u.hp ~= u2.hp
			or u.max_hp ~= u2.max_hp
			or u.veterancy ~= u2.veterancy
			or u.state ~= u2.state
			or u.patrol_tile ~= u2.patrol_tile
		then
			table.insert(bad, "warship state " .. uid)
		end
	end
	if count_keys(g2.units) ~= count_keys(gs.units) then
		table.insert(bad, "unit count")
	end
	if count_keys(g2.shells) ~= count_keys(gs.shells) or count_keys(g2.sam_missiles) ~= count_keys(gs.sam_missiles) then
		table.insert(
			bad,
			fmt(
				"shells %d/%d, SAM missiles %d/%d",
				count_keys(g2.shells),
				count_keys(gs.shells),
				count_keys(g2.sam_missiles),
				count_keys(gs.sam_missiles)
			)
		)
	end
	if count_keys(g2.nukes) ~= count_keys(gs.nukes) or count_keys(g2.attacks) ~= count_keys(gs.attacks) then
		table.insert(bad, "nukes/attacks")
	end
	for k in gs.alliances do
		if not g2.alliances[k] then
			table.insert(bad, "alliance " .. k)
		end
	end
	if count_keys(g2.alliances) ~= count_keys(gs.alliances) or count_keys(g2.requests) ~= count_keys(gs.requests) then
		table.insert(bad, "alliances/requests")
	end
	if #bad > 0 then
		failures += 1
		local shown = {}
		for i = 1, math.min(12, #bad) do
			shown[i] = bad[i]
		end
		print(fmt("FAIL %s snapshot mismatch: %s", label, table.concat(shown, ", ")))
	end
end

--- SimState.disk_tiles() must return exactly the tiles with range_d2(centre, t) <= r².
local function _check_range_metric()
	local rng = Rng.new(99)
	local bad = 0
	for i = 0, 59 do
		local c = rng:randi_range(0, N - 1)
		if i < 6 then
			c = math.min((i * 80 + 2), H - 1) * W + (i * 171) % W
		end
		local r = rng:randf_range(2.0, 52.0)
		local got = {}
		local ng = 0
		for _, t in sim:disk_tiles(c, r, false) do
			if not got[t] then
				ng += 1
			end
			got[t] = true
		end
		local want = 0
		local cy = c // W
		for y = math.max(cy - math.ceil(r), 0), math.min(cy + math.ceil(r), H - 1) do
			for x = 0, W - 1 do
				local t = y * W + x
				if sim.range_d2(c, t) <= r * r then
					want += 1
					if not got[t] then
						bad += 1
					end
				end
			end
		end
		if want ~= ng then
			bad += 1
		end
	end
	expect(bad == 0, "disk_tiles == {t : range_d2(c, t) <= r^2} on 60 random disks (r 2..52)")
end

-- =============================================================================================
-- Reports
-- =============================================================================================

local function _median_nation_tiles(): number
	local v = {}
	for id = 1, sim.owner_total do
		if sim.o_kind[id] == Defs.KIND_NATION and sim.o_alive[id] == 1 then
			table.insert(v, sim.o_tiles[id])
		end
	end
	if #v == 0 then
		return 0
	end
	table.sort(v)
	return v[#v // 2 + 1]
end

local function _report_colour()
	local t = sim.o_spawn_tile[hid]
	local me = SimColors.oklab(sim.o_color[hid])
	local dmin = 10.0
	local who = ""
	for o = 1, sim.owner_total do
		if o == hid or sim.o_alive[o] == 0 or sim.o_spawn_tile[o] < 0 then
			continue
		end
		local near_h = SimColors.NEAR_HUMAN * sim.R.LEGACY_LIN
		if sim.dist2(sim.o_spawn_tile[o], t) > near_h * near_h then
			continue
		end
		local dd = SimColors.dist(me, SimColors.oklab(sim.o_color[o]))
		if dd < dmin then
			dmin = dd
			who = sim.o_name[o]
		end
	end
	print(
		fmt(
			"BENCH human colour %s (OKLab L %.2f C %.3f), nearest-colour owner within 45 tiles: %s at dE %.3f",
			Defs.rgba_html(sim.o_color[hid]),
			me.x,
			math.sqrt(me.y * me.y + me.z * me.z),
			who,
			dmin
		)
	)
end

local function _report_contrast()
	local pairs_: { [number]: boolean } = {}
	local own = sim.owner
	for _, t in LAND do
		local a = readi32(own, t * 4)
		if a == 0 then
			continue
		end
		if t % W < W - 1 then
			local e = t + 1
			local b = readi32(own, e * 4)
			if b ~= 0 and b ~= a and readu8(sim.land, e) == 1 then
				pairs_[math.min(a, b) * 1024 + math.max(a, b)] = true
			end
		end
		if t < N - W then
			local b = readi32(own, (t + W) * 4)
			if b ~= 0 and b ~= a and readu8(sim.land, t + W) == 1 then
				pairs_[math.min(a, b) * 1024 + math.max(a, b)] = true
			end
		end
	end
	-- nations start with their flag country's authored colour (Data/Nations) or a picked one
	local authored = {}
	for k = 1, sim.owner_total do
		authored[k] = sim.o_color[k]
	end
	local low, very_low, n_pairs, n_low, n_low_auth, np = 0, 0, 0, 0, 0, 0
	local min_d = 10.0
	for key in pairs_ do
		np += 1
		local a2 = key // 1024
		local b2 = key % 1024
		local d = SimColors.dist(SimColors.oklab(sim.o_color[a2]), SimColors.oklab(sim.o_color[b2]))
		min_d = math.min(min_d, d)
		if d < SimColors.MIN_DE then
			low += 1
		end
		if d < 0.06 then
			very_low += 1
		end
		if sim.o_kind[a2] == Defs.KIND_NATION and sim.o_kind[b2] == Defs.KIND_NATION then
			n_pairs += 1
			if d < SimColors.MIN_DE then
				n_low += 1
			end
			if SimColors.dist(SimColors.oklab(authored[a2]), SimColors.oklab(authored[b2])) < SimColors.MIN_DE then
				n_low_auth += 1
			end
		end
	end
	print(
		fmt(
			"  CONTRAST %d bordering pairs: %d below dE %.2f, %d below 0.06, min %.3f | nation-nation pairs %d: below %.2f now %d, with authored colours %d",
			np,
			low,
			SimColors.MIN_DE,
			very_low,
			min_d,
			n_pairs,
			SimColors.MIN_DE,
			n_low,
			n_low_auth
		)
	)
end

local function _report_minute(
	minute: number,
	times: { number },
	bytes: number,
	bytes_max: number,
	tiles: number,
	evs: number
)
	local avg, p95, mx, _p99 = stats(times)
	local alive = { [0] = 0, 0, 0 }
	local ids = {}
	for id = 1, sim.owner_total do
		if sim.o_alive[id] == 1 and sim.o_spawned[id] == 1 then
			alive[sim.o_kind[id]] += 1
			table.insert(ids, id)
		end
	end
	table.sort(ids, function(a, b)
		if sim.o_tiles[a] ~= sim.o_tiles[b] then
			return sim.o_tiles[a] > sim.o_tiles[b]
		end
		return a < b
	end)
	local sc = { [0] = 0, 0, 0, 0, 0, 0 }
	local sc_ai = { [0] = 0, 0, 0, 0, 0, 0 }
	local ns = 0
	for _, s in sim.structs do
		if s.dead then
			continue
		end
		ns += 1
		sc[s.kind] += 1
		if s.owner ~= hid then
			sc_ai[s.kind] += 1
		end
	end
	local uc = { [0] = 0, 0, 0, 0 }
	for _, u in sim.unit_list do
		if not u.dead then
			uc[u.kind] += 1
		end
	end
	local claimed = 0
	for _, id in ids do
		claimed += sim.o_tiles[id]
	end
	print(
		fmt(
			"=== minute %d (tick %d) === step avg %.2f ms p95 %.2f max %.2f | delta %.1f KB/s (max tick %.1f KB) tiles/tick %.0f ev/tick %.1f",
			minute,
			sim.tick,
			avg,
			p95,
			mx,
			bytes / 60.0 / 1024.0,
			bytes_max / 1024.0,
			tiles / 600.0,
			evs / 600.0
		)
	)
	print(
		fmt(
			"  alive: nations %d tribes %d humans %d | claimed %.1f%% | attacks %d | alliances %d",
			alive[0],
			alive[1],
			alive[2],
			100.0 * claimed / sim.map.contestable_count,
			#sim.attacks,
			count_keys(sim.alliances)
		)
	)
	local in_flight = 0
	for _, n in sim.nukes do
		if not n.dead then
			in_flight += 1
		end
	end
	print(
		fmt(
			"  structs: city %d port %d factory %d defense %d sam %d silo %d | roads %d | units: transport %d trade %d warship %d truck %d | nukes launched %d (in flight %d)",
			sc[0],
			sc[1],
			sc[2],
			sc[3],
			sc[4],
			sc[5],
			sim:road_total(),
			uc[0],
			uc[1],
			uc[2],
			uc[3],
			sim.nukes_launched,
			in_flight
		)
	)
	local ai_total = 0
	for k = 0, 5 do
		ai_total += sc_ai[k]
	end
	print(fmt("  colour re-tints so far: %d", sim.ai.retints))
	print(
		fmt(
			"  AI structs: city %d port %d factory %d defense %d sam %d silo %d = %d (all owners %d)",
			sc_ai[0],
			sc_ai[1],
			sc_ai[2],
			sc_ai[3],
			sc_ai[4],
			sc_ai[5],
			ai_total,
			ns
		)
	)
	print(
		fmt(
			"  lifecycle (city/port/factory/defense/sam/silo): built AI %s human %s captured %s destroyed %s",
			arr6(_s_built_ai),
			arr6(_s_built_h),
			arr6(_s_capt),
			arr6(_s_del)
		)
	)
	local n_income, n_cap, n_troops, n_gold, nn = 0.0, 0.0, 0.0, 0.0, 0
	for _, id in ids do
		if sim.o_kind[id] == Defs.KIND_NATION then
			nn += 1
			n_income += sim.o_income[id] + sim.o_bonus_rate[id]
			n_cap += sim.o_cap[id]
			n_troops += sim.o_troops[id]
			n_gold += sim.o_gold[id]
		end
	end
	nn = math.max(nn, 1)
	print(
		fmt(
			"  nations avg: income %s/s cap %s troops %s gold %s",
			ft(n_income / nn),
			ft(n_cap / nn),
			ft(n_troops / nn),
			ft(n_gold / nn)
		)
	)
	local pf = "  profile ms/tick:"
	for k, name in Sim.PROF_NAMES do
		pf ..= fmt(" %s %.2f", name, sim.prof[k] / 1000.0 / math.max(#times, 1))
		sim.prof[k] = 0
	end
	print(pf)
	local top = ""
	for k = 1, math.min(10, #ids) do
		local id = ids[k]
		top ..= fmt("%s %.1f%% (%s) ", sim.o_name[id], 100.0 * sim:land_share(id), ft(sim.o_troops[id]))
	end
	print("  top: " .. top)
	local f = sim.dbg_flow
	for k = 1, math.min(3, #ids) do
		local id = ids[k]
		print(
			fmt(
				"    flow %s: sent attacks %s boats %s | lost defending %s nukes %s | refunded %s | cap %s wars %d",
				sim.o_name[id],
				ft(f[id * 5]),
				ft(f[id * 5 + 1]),
				ft(f[id * 5 + 2]),
				ft(f[id * 5 + 3]),
				ft(f[id * 5 + 4]),
				ft(sim.o_cap[id]),
				sim:count_attacks_by(id, true)
			)
		)
	end
	for k in f do
		f[k] = 0.0
	end
	local al = ""
	for k = 1, math.min(5, #ids) do
		for _, q in sim:allies_of(ids[k]) do
			if sim.o_tiles[q] * 50 > sim.map.contestable_count then
				al ..= fmt("%s+%s ", sim.o_name[ids[k]], sim.o_name[q])
			end
		end
	end
	if al ~= "" then
		print("  big alliances: " .. al)
	end
	if hid > 0 then
		print(
			fmt(
				"  human: alive %d tiles %d (%.2f%%) troops %s / %s gold %s income %d/s cities %d ports %d factories %d",
				sim.o_alive[hid],
				sim.o_tiles[hid],
				100.0 * sim:land_share(hid),
				ft(sim.o_troops[hid]),
				ft(sim.o_cap[hid]),
				ft(sim.o_gold[hid]),
				Defs.trunc(sim.o_income[hid] + sim.o_bonus_rate[hid]),
				sim:struct_count(hid, Defs.S_CITY),
				sim:struct_count(hid, Defs.S_PORT),
				sim:struct_count(hid, Defs.S_FACTORY)
			)
		)
	end
end

local function _track_milestones(d: { [string]: any })
	local secs = (sim.tick - sim.playing_since) / 10.0
	for _, e in d.ev do
		local k = e[1]
		local label = ""
		if k == Ev.STRUCT_ADD and e[4] == hid then
			label = "first " .. Defs.STRUCT_NAMES[e[3]]
		elseif k == Ev.ATTACK and e[4] == hid then
			label = "first attacked by a " .. ({ [0] = "nation", "tribe", "human" })[sim.o_kind[e[3]]]
		elseif k == Ev.MSG and e[2] == hid and string.sub(e[4], -#"is attacking you!") == "is attacking you!" then
			label = fmt("first war declared on the human (%s)", string.sub(e[4], 1, #e[4] - #" is attacking you!"))
		elseif k == Ev.NUKE and readi32(sim.owner, e[6] * 4) == hid then
			label = "first nuke at the human"
		elseif k == Ev.ALLY and (e[2] == hid or e[3] == hid) then
			label = "first alliance"
		end
		if label ~= "" and _milestones[label] == nil then
			_milestones[label] = secs
			print(fmt("  MILESTONE %s at %.0f s", label, secs))
		end
	end
end

-- =============================================================================================
-- Scripted humans (only through intents, like the original bench)
-- =============================================================================================

local function _free_around(t: number, r: number): boolean
	local cx = t % W
	local cy = t // W
	for dy = -r, r do
		for dx = -r, r do
			local y = math.clamp(cy + dy, 0, H - 1)
			local x = math.clamp(cx + dx, 0, W - 1)
			if readi32(sim.owner, (y * W + x) * 4) ~= 0 then
				return false
			end
		end
	end
	return true
end

local function _find_human_start(map: any): number
	-- lat / lon read as an equirectangular position on the map
	local cx = math.clamp(math.floor((human_lon + 180.0) / 360.0 * W), 0, W - 1)
	local cy = math.clamp(math.floor((90.0 - human_lat) / 180.0 * H), 0, H - 1)
	local _ = map
	for r = 0, 79 do
		for dy = -r, r do
			for dx = -r, r do
				if math.max(math.abs(dx), math.abs(dy)) ~= r then
					continue
				end
				local y = cy + dy
				local x = cx + dx
				if y < 1 or y >= H - 1 or x < 0 or x >= W then
					continue
				end
				local t = y * W + x
				if readu8(sim.land, t) == 1 and readi32(sim.owner, t * 4) == 0 and _free_around(t, 7) then
					return t
				end
			end
		end
	end
	return LAND[1]
end

local function _human_policy()
	if sim.phase ~= Defs.PHASE_PLAYING or sim.o_alive[hid] == 0 or sim.tick < _next_human_think then
		return
	end
	_next_human_think = sim.tick + 12
	-- Answer alliance requests (accept every other one).
	for _, k in sorted_keys(gs.requests) do
		if k % 1024 == hid then
			sim:submit(hid, { type = "ally_reply", target = k // 1024, accept = (k // 1024) % 2 == 0 })
		end
	end
	sim:scan_border(hid, 600)
	local troops = sim.o_troops[hid]
	local fill = troops / math.max(sim.o_cap[hid], 1.0)
	if sim.sc_neutral > 0 and sim.sc_neutral_tile >= 0 then
		local ex = sim:attack_between(hid, 0)
		if (ex == nil or ex.troops < troops * 0.15) and fill > 0.1 then
			sim:submit(hid, { type = "attack", tile = sim.sc_neutral_tile, ratio = 0.45 })
		end
	elseif fill > 0.45 then
		local best = -1
		local best_s = 0.0
		for _, p in sim.sc_list do
			if gs:are_allies(hid, p) then
				continue
			end
			local s = troops / (sim.o_troops[p] + 1.0)
			if s > best_s then
				best_s = s
				best = p
			end
		end
		if best > 0 and best_s > 1.4 then
			sim:submit(hid, { type = "attack", tile = sim.sc_tile[best], ratio = 0.35 })
		elseif sim.o_boats[hid] == 0 and sim.tick % 300 < 12 then
			local c = sim:own_coast_tile(hid)
			if c >= 0 then
				local ct = COAST
				for _ = 1, 60 do
					local t = ct[sim.rng:randi() % #ct + 1]
					local o = readi32(sim.owner, t * 4)
					if
						coast_body(t) == coast_body(c)
						and o ~= hid
						and not gs:are_allies(hid, o)
						and sim.dist2(t, c) < (150 * sim.R.LEGACY_LIN) ^ 2
						and (o == 0 or sim.o_troops[o] < troops * 0.5)
					then
						sim:submit(hid, { type = "boat", tile = t, ratio = 0.3 })
						break
					end
				end
			end
		end
	end
	-- Economy: the UI shows Rules.build_cost(); build the cheapest useful thing we can afford.
	local gold = sim.o_gold[hid]
	local want = { "city" }
	if sim.o_coast[hid] > 0 and gs:count_structures(hid, Defs.S_PORT) < 1 + sim.o_tiles[hid] // 2500 then
		table.insert(want, "port")
	end
	if gs:count_structures(hid, Defs.S_FACTORY) < gs:count_structures(hid, Defs.S_CITY) // 2 then
		table.insert(want, "factory")
	end
	if sim.tick > 4000 and gs:count_structures(hid, Defs.S_SILO) == 0 and gold > 1500000 then
		want = { "silo" }
	end
	if sim.tick - sim.o_attacked_tick[hid] < 100 and gs:count_structures(hid, Defs.S_DEFENSE) < 3 then
		table.insert(want, 1, "defense")
	end
	for _, k in want do
		local kind = Defs.struct_kind_from_name(k)
		local cost = Rules.build_cost(k, gs:count_structures(hid, kind))
		if gold >= cost then
			local spread = math.clamp(Defs.trunc(math.sqrt(sim.o_tiles[hid]) * 0.6), 8, 60)
			local anchor = sim:centre_tile(hid)
			if k == "port" then
				anchor = sim:own_coast_tile(hid)
			elseif k == "defense" then
				local worst = 0.0
				for _, a in sim.attacks do
					if not a.dead and a.target == hid and a.troops > worst and a.last_tile >= 0 then
						worst = a.troops
						anchor = a.last_tile
					end
				end
				spread = 5
			end
			local site = sim:find_site(hid, kind, anchor, spread, 30)
			if site >= 0 then
				sim:submit(hid, { type = "build", kind = k, tile = site })
				break
			end
		end
	end
	-- Late game: nuke the leader if it is not us.
	local leader = sim.ai.leader
	if
		gs:count_structures(hid, Defs.S_SILO) > 0
		and gold > Rules.nuke_cost("atom") + 200000
		and leader ~= hid
		and leader > 0
	then
		local tgt = sim.o_spawn_tile[leader]
		if tgt >= 0 and readi32(sim.owner, tgt * 4) == leader and not gs:are_allies(hid, leader) then
			sim:submit(hid, { type = "nuke", kind = "atom", tile = tgt })
		end
	end
end

local _pro_next = 0
local _pro_last_boat = -100000
local _pro_last_nuke = -100000
local _pro_rng = Rng.new(0)
local _pro_countered: { [number]: number } = {}

local function _pro_build(age: number)
	local gold = sim.o_gold[hid]
	local tiles = sim.o_tiles[hid]
	local c = gs:struct_level_sum(hid, Defs.S_CITY)
	local f = gs:struct_level_sum(hid, Defs.S_FACTORY)
	local pt = gs:struct_level_sum(hid, Defs.S_PORT)
	local d = gs:count_structures(hid, Defs.S_DEFENSE)
	local want = {}
	if sim.tick - sim.o_attacked_tick[hid] < 100 and d < 1 + tiles // 2500 then
		table.insert(want, "defense")
	end
	if age > 3000 and gs:count_structures(hid, Defs.S_SILO) == 0 and gold > 2000000 then
		table.insert(want, "silo")
	end
	if sim.nukes_launched > 0 and gs:count_structures(hid, Defs.S_SAM) < tiles // 8000 then
		table.insert(want, "sam")
	end
	if c < 1 + tiles // 300 then
		table.insert(want, "city")
	end
	if f < c // 2 then
		table.insert(want, "factory")
	end
	if sim.o_coast[hid] > 0 and pt < 1 + tiles // 1500 then
		table.insert(want, "port")
	end
	for _, k in want do
		local kind = Defs.struct_kind_from_name(k)
		if gold < Rules.cost_of(gs, hid, k) then
			continue
		end
		local anchor = sim:centre_tile(hid)
		local spread = math.clamp(Defs.trunc(math.sqrt(tiles) * 0.6), 8, 60)
		if k == "port" then
			anchor = sim:own_coast_tile(hid)
			spread = 25
		elseif k == "defense" then
			for _, a in sim.attacks do
				if not a.dead and a.target == hid and a.last_tile >= 0 then
					anchor = a.last_tile
					break
				end
			end
			spread = 5
		end
		local site = sim:find_site(hid, kind, anchor, spread, 30)
		if site < 0 and Rules.is_upgradable(kind) then
			-- No room left: click an existing one to upgrade it.
			local mine = gs:structures_of(hid, kind)
			if #mine > 0 then
				site = mine[_pro_rng:randi() % #mine + 1].tile
			end
		end
		if site >= 0 then
			sim:submit(hid, { type = "build", kind = k, tile = site })
			return
		end
	end
end

local function _pro_policy()
	if sim.phase ~= Defs.PHASE_PLAYING or sim.o_alive[hid] == 0 or sim.tick < _pro_next then
		return
	end
	_pro_next = sim.tick + 10
	local age = sim.tick - sim.playing_since
	local mine = sim.o_troops[hid]
	local cap = math.max(sim.o_cap[hid], 1.0)
	local fill = mine / cap
	-- Alliances: make peace with stronger neighbours, keep weaker ones as targets.
	for _, k in sorted_keys(gs.requests) do
		if k % 1024 == hid then
			local from = k // 1024
			sim:submit(hid, { type = "ally_reply", target = from, accept = sim.o_troops[from] > 0.8 * mine })
		end
	end
	sim:scan_border(hid, 800)
	-- 1) Answer the biggest incoming attack with a sized counter-attack.
	local worst = nil
	for _, a in sim.attacks do
		if not a.dead and a.target == hid and (worst == nil or a.troops > worst.troops) then
			worst = a
		end
	end
	if
		worst ~= nil
		and worst.troops > mine * 0.05
		and mine > worst.troops * 1.2
		and sim.tick - (_pro_countered[worst.attacker] or -1000) > 50
	then
		local ours = sim:attack_between(hid, worst.attacker)
		if (ours == nil or ours.troops < worst.troops * 0.8) and sim.sc_count[worst.attacker] > 0 then
			_pro_countered[worst.attacker] = sim.tick
			sim:submit(hid, {
				type = "attack",
				tile = sim.sc_tile[worst.attacker],
				ratio = math.clamp(worst.troops * 1.2 / mine, 0.05, 0.4),
			})
		end
	end
	-- 2) Keep expanding into free land.
	if sim.sc_neutral > 0 and sim.sc_neutral_tile >= 0 then
		local ex = sim:attack_between(hid, 0)
		if ex == nil or ex.troops < mine * 0.05 then
			sim:submit(hid, { type = "attack", tile = sim.sc_neutral_tile, ratio = if age < 1200 then 0.5 else 0.3 })
		end
	end
	-- 3) Wars on weaker neighbours, sized to the job, keeping a reserve.
	local wars = sim:count_attacks_by(hid, true)
	if fill > 0.25 and age > 600 then
		local best = -1
		local best_s = 0.0
		for _, p in sim.sc_list do
			if sim.sc_count[p] < 3 or gs:are_allies(hid, p) then
				continue
			end
			local sc = mine / (sim.o_troops[p] + 1.0)
			if sim.o_kind[p] == Defs.KIND_TRIBE then
				sc *= 1.5
			end
			if sim:attack_between(hid, p) ~= nil then
				sc *= 1.3
			end
			-- Thinly held land is cheap land.
			local dens = sim.o_troops[p] / math.max(sim.o_tiles[p], 1)
			sc *= math.clamp(300.0 / math.max(dens, 1.0), 0.7, 1.5)
			if sc > best_s then
				best_s = sc
				best = p
			end
		end
		-- Idle troops near the cap are wasted: then even an even fight is worth taking.
		local need = if fill > 0.8 then 1.0 else 1.2
		if best > 0 and best_s >= need then
			-- One focused war at a time, with enough force for momentum (≥ 0.7× their army).
			local job = math.max((sim.o_troops[best] + sim.o_tiles[best] * 45.0) * 1.5, sim.o_troops[best] * 0.7)
			local ex2 = sim:attack_between(hid, best)
			if (ex2 == nil and wars < (if fill > 0.6 then 2 else 1)) or (ex2 ~= nil and ex2.troops < job * 0.3) then
				-- Never send so much that home drops under 30 % of the cap (thin land is cheap land).
				local spare = math.clamp((mine - 0.3 * cap) / math.max(mine, 1.0), 0.0, 0.6)
				if spare * mine >= math.min(job, sim.o_troops[best] * 0.7) then
					sim:submit(hid, {
						type = "attack",
						tile = sim.sc_tile[best],
						ratio = math.clamp(job / math.max(mine, 1.0), 0.05, math.max(spare, 0.05)),
					})
				end
			end
		end
	end
	-- 4) Boats: free coasts, islands and weak owners across the water.
	if
		sim.sc_neutral == 0
		and sim.tick - _pro_last_boat > 150
		and sim.o_boats[hid] < Rules.max_boats(sim.o_tiles[hid])
		and fill > 0.35
	then
		local home = sim:own_coast_tile(hid)
		if home >= 0 then
			local ct = COAST
			local body = coast_body(home)
			local pick = -1
			local pick_s = 0.0
			for _ = 1, 80 do
				local c = ct[sim.rng:randi() % #ct + 1]
				if coast_body(c) ~= body or readu8(sim.land, c) == 0 or bit32.band(readu8(sim.flags, c), 1) ~= 0 then
					continue
				end
				local o = readi32(sim.owner, c * 4)
				if o == hid or gs:are_allies(hid, o) then
					continue
				end
				local v = if o == 0 then 3.0 elseif sim.o_troops[o] < mine * 0.3 then 1.5 else 0.0
				v /= 1.0 + math.sqrt(sim.dist2(home, c)) / (150.0 * sim.R.LEGACY_LIN)
				if v > pick_s then
					pick_s = v
					pick = c
				end
			end
			if pick >= 0 then
				_pro_last_boat = sim.tick
				local o2 = readi32(sim.owner, pick * 4)
				local need = if o2 == 0 then 20000.0 else (sim.o_troops[o2] + sim.o_tiles[o2] * 45.0) * 1.5
				sim:submit(
					hid,
					{ type = "boat", tile = pick, ratio = math.clamp(need / math.max(mine, 1.0), 0.05, 0.3) }
				)
			end
		end
	end
	-- 5) Economy: spend gold every think on what the nation needs most.
	_pro_build(age)
	-- 6) Late game: nuke the strongest enemy we share a border with.
	if gs:count_structures(hid, Defs.S_SILO) > 0 and sim.tick - _pro_last_nuke > 400 then
		local foe = -1
		for _, p in sim.sc_list do
			if
				not gs:are_allies(hid, p)
				and sim.o_kind[p] ~= Defs.KIND_TRIBE
				and (foe < 0 or sim.o_troops[p] > sim.o_troops[foe])
			then
				foe = p
			end
		end
		local gold = sim.o_gold[hid]
		if foe > 0 and gold >= Rules.nuke_cost("atom") * 1.5 then
			local kind = if gold >= Rules.nuke_cost("hydrogen") * 1.2 then "hydrogen" else "atom"
			local tgt = sim.sc_tile[foe]
			local cities = gs:structures_of(foe, Defs.S_CITY)
			if #cities > 0 then
				tgt = cities[1].tile
			end
			_pro_last_nuke = sim.tick
			sim:submit(hid, { type = "nuke", kind = kind, tile = tgt })
		end
	end
end

-- =============================================================================================
-- Solo / title run
-- =============================================================================================

local function _run()
	local t0 = clock_ms()
	local map = MAP
	local t1 = clock_ms()
	sim = Sim.new(map, {
		seed = seed_value,
		difficulty = difficulty,
		tribes = tribes,
		max_humans = if with_human then 1 else 0,
		time_limit_s = 0,
	})
	local t2 = clock_ms()
	print(
		fmt(
			"BENCH map load %.0f ms, Sim init %.0f ms (nav regions %d), contestable %d, owners %d",
			t1 - t0,
			t2 - t1,
			sim.nav.reg_count,
			map.contestable_count,
			sim:owner_count()
		)
	)
	sim.profile = true
	_check_range_metric()
	if with_human then
		hid = sim:add_human("bench", "Bench Commander")
	end
	gs = GameState.new(map)
	local ts = clock_ms()
	gs:load_snapshot(sim:snapshot())
	print(fmt("BENCH snapshot+load %.0f ms", clock_ms() - ts))
	gs.local_owner = hid
	if with_human then
		local start = _find_human_start(map)
		local ok = sim:human_start(hid, start)
		print(fmt("BENCH human %d starts at tile %d (x %d, y %d): %s", hid, start, start % W, start // W, tostring(ok)))
		-- Let the 5 s countdown run.
		for _ = 1, Rules.SOLO_COUNTDOWN_TICKS + 1 do
			gs:apply_delta(sim:step())
		end
		print(fmt("BENCH phase after countdown: %d", sim.phase))
		_report_colour()
	end
	_write_png(0)

	local total_ticks = minutes * 600
	local minute_times = {}
	local all_times = table.create(total_ticks)
	local bytes_minute, bytes_max, tiles_minute, ev_minute, msgs_minute = 0, 0, 0, 0, 0
	local max_after_first = 0.0
	local late_times = {}
	for i = 0, total_ticks - 1 do
		if with_human then
			if player == "pro" then
				_pro_policy()
			else
				_human_policy()
			end
		end
		local before = table.clone(sim.prof)
		local nav_before = sim.nav.usec
		local s0 = clock_ms()
		local d = sim:step()
		local ms = clock_ms() - s0
		if ms > 30.0 then
			local parts = ""
			for k, name in Sim.PROF_NAMES do
				parts ..= fmt(" %s %.1f", name, (sim.prof[k] - before[k]) / 1000.0)
			end
			print(
				fmt(
					"  SLOW tick %d: %.1f ms:%s (nav %.1f ms)",
					sim.tick,
					ms,
					parts,
					(sim.nav.usec - nav_before) / 1000.0
				)
			)
		end
		table.insert(minute_times, ms)
		table.insert(all_times, ms)
		if i >= 600 then
			max_after_first = math.max(max_after_first, ms)
		end
		if i >= total_ticks - 3000 then
			table.insert(late_times, ms)
		end
		if trace_human and hid > 0 then
			for _, e in d.ev do
				if
					(e[1] == Ev.STRUCT_ADD and e[4] == hid)
					or (e[1] == Ev.STRUCT_LEVEL and sim.structs[e[2]] and sim.structs[e[2]].owner == hid and e[3] > 1)
				then
					print(
						fmt(
							"  TRACE t=%d human %s kind %s gold now %s",
							sim.tick,
							if e[1] == Ev.STRUCT_ADD then "builds" else "upgrades",
							if e[1] == Ev.STRUCT_ADD
								then Defs.STRUCT_NAMES[e[3]]
								else Defs.STRUCT_NAMES[sim.structs[e[2]].kind],
							ft(sim.o_gold[hid])
						)
					)
				elseif e[1] == Ev.OWNER_OUT and e[3] == hid then
					print(fmt("  TRACE t=%d human eliminated %s", sim.tick, sim.o_name[e[2]]))
				end
			end
		end
		local nb = delta_bytes(d)
		bytes_minute += nb
		bytes_max = math.max(bytes_max, nb)
		tiles_minute += #d.tiles
		ev_minute += #d.ev
		if hid > 0 then
			_track_milestones(d)
			if sim.o_alive[hid] == 1 then
				-- Actual wars: AI nations with a live, non-counter attack on the human.
				local wars_now = 0
				for _, a in sim.attacks do
					if
						not a.dead
						and a.target == hid
						and not a.counter
						and sim.o_kind[a.attacker] == Defs.KIND_NATION
					then
						wars_now += 1
					end
				end
				_max_wars_on_human = math.max(_max_wars_on_human, wars_now)
				if wars_now > Rules.MAX_AI_WARS_ON_HUMAN[difficulty] and sim.tick % 50 == 0 then
					local who = ""
					for _, a in sim.attacks do
						if not a.dead and a.target == hid then
							who ..= fmt(
								"%s(counter=%s age=%ds kind=%d) ",
								sim.o_name[a.attacker],
								tostring(a.counter),
								(sim.tick - a.started_tick) // 10,
								sim.o_kind[a.attacker]
							)
						end
					end
					print(fmt("  OVERCAP t=%d: %s", sim.tick, who))
				end
			elseif not _human_dead_logged then
				_human_dead_logged = true
				print(
					fmt(
						"  MILESTONE human eliminated at %.0f s by %s (tick %d, phase %d — solo keeps running)",
						(sim.tick - sim.playing_since) / 10.0,
						sim:name_of(sim.o_killer[hid]),
						sim.tick,
						sim.phase
					)
				)
			end
		end
		local since = sim.tick - sim.playing_since
		if since > 0 and since <= 1800 and since % 150 == 0 then
			local claimed = 0
			for id = 1, sim.owner_total do
				if sim.o_alive[id] == 1 then
					claimed += sim.o_tiles[id]
				end
			end
			local extra = ""
			if hid > 0 then
				extra = fmt(
					" | human %d tiles (%.2f%%), median nation %d tiles",
					sim.o_tiles[hid],
					100.0 * sim:land_share(hid),
					_median_nation_tiles()
				)
			end
			print(
				fmt(
					"  LANDGRAB t=%3d s claimed %.1f%%%s",
					since // 10,
					100.0 * claimed / sim.map.contestable_count,
					extra
				)
			)
		end
		for _, e in d.ev do
			local k = e[1]
			if k == Ev.STRUCT_ADD then
				_sk[e[2]] = e[3]
				if e[4] == hid then
					_s_built_h[e[3]] += 1
				else
					_s_built_ai[e[3]] += 1
				end
			elseif k == Ev.STRUCT_OWNER then
				local kk = _sk[e[2]] or 0
				_s_capt[kk] += 1
			elseif k == Ev.STRUCT_DEL then
				local kk = _sk[e[2]] or 0
				_s_del[kk] += 1
			end
		end
		for _, e in d.ev do
			if e[1] == Ev.MSG and (e[2] == hid or e[2] == -1) then
				msgs_minute += 1
				if not quiet and (msgs_minute <= 4 or e[3] == Defs.MSG_ALERT and msgs_minute <= 12) then
					print(fmt("   msg[%d] %s", e[3], e[4]))
				end
			end
		end
		gs:apply_delta(d)
		if sim.tick % 600 == 0 then
			local minute = sim.tick // 600
			_report_minute(minute, minute_times, bytes_minute, bytes_max, tiles_minute, ev_minute)
			_check_mirror("minute " .. minute)
			if minute % 2 == 0 or minute == minutes then
				_check_snapshot("minute " .. minute)
			end
			if png_every > 0 and minute % png_every == 0 then
				_write_png(minute)
			end
			if minute == 2 or minute == 10 then
				_report_contrast()
			end
			minute_times = {}
			bytes_minute, bytes_max, tiles_minute, ev_minute, msgs_minute = 0, 0, 0, 0, 0
		end
		if sim.phase == Defs.PHASE_OVER then
			print(
				fmt(
					"BENCH GAME OVER at tick %d: winner %d (%s) reason %d",
					sim.tick,
					sim.winner,
					sim:name_of(sim.winner),
					sim.over_reason
				)
			)
			_check_mirror("game over")
			_write_png(99)
			break
		end
	end
	if hid > 0 then
		print(
			fmt(
				"BENCH max simultaneous AI nation wars on the human: %d (cap %d)",
				_max_wars_on_human,
				Rules.MAX_AI_WARS_ON_HUMAN[difficulty]
			)
		)
	end
	local avg, p95, mx, p99 = stats(all_times)
	print(
		fmt(
			"BENCH TOTAL ticks=%d avg=%.2f ms p95=%.2f ms p99=%.2f max=%.2f ms, max after minute 1=%.2f ms",
			#all_times,
			avg,
			p95,
			p99,
			mx,
			max_after_first
		)
	)
	local lavg, lp95, lmx, lp99 = stats(late_times)
	print(fmt("BENCH LATE (last 5 min) avg=%.2f ms p95=%.2f p99=%.2f max=%.2f ms", lavg, lp95, lp99, lmx))
	local nav = sim.nav
	print(
		fmt(
			"BENCH nav searches=%d expanded=%d total %.0f ms (%.3f ms/search)",
			nav.searches,
			nav.expanded,
			nav.usec / 1000.0,
			nav.usec / 1000.0 / math.max(nav.searches, 1)
		)
	)
	print(
		fmt(
			"BENCH nav split: astar %.0f ms, smooth %.0f ms, worst query %.1f ms, failed %d",
			nav.usec_astar / 1000.0,
			nav.usec_smooth / 1000.0,
			nav.usec_max / 1000.0,
			nav.fails
		)
	)
end

-- =============================================================================================
-- Multiplayer contract test: every intent type, relocation, random spawn, leave, late join,
-- a second mirror built from a mid-game snapshot, time limit.
-- =============================================================================================

local function _run_mp()
	local map = MAP
	sim = Sim.new(
		map,
		{ seed = seed_value, difficulty = 1, tribes = 90, max_humans = 32, time_limit_s = 240, spawn_ticks = 100 }
	)
	local h1 = sim:add_human("alice#1", "Alice")
	local h2 = sim:add_human("bob#2", "Bob")
	local h3 = sim:add_human("carol#3", "Carol")
	hid = h1
	gs = GameState.new(map)
	gs:load_snapshot(sim:snapshot())
	gs.local_owner = h1
	expect(gs.phase == Defs.PHASE_SPAWN and gs.phase_ticks_left == 100, "spawn phase in snapshot")
	expect(gs.time_limit_ticks == 100 + 2400, fmt("time limit in snapshot (%d)", gs.time_limit_ticks))
	local a1 = _find_human_start(map)
	human_lat = 50.0
	human_lon = 90.0
	local a2 = _find_human_start(map)
	local gs2: any = nil
	local h4 = 0
	local late_tile = -1
	local saw: { [any]: any } = {}
	for _ = 1, 3400 do
		local t = sim.tick + 1
		if t == 5 then
			sim:submit(h1, { type = "spawn", tile = a2 })
		elseif t == 15 then
			sim:submit(h1, { type = "spawn", tile = a1 })
		elseif t == 17 then
			expect(
				readi32(sim.owner, a1 * 4) == h1 and readi32(sim.owner, a2 * 4) ~= h1,
				"relocated spawn (claimed the tick after the pick)"
			)
		elseif t == 30 then
			sim:remove_human(h3)
		elseif t == 31 then
			local again = sim:add_human("carol#3", "Carol")
			expect(
				again == h3 and sim.o_alive[h3] == 1,
				fmt("join→leave→join before spawning revives the same id (%d)", again)
			)
			local before_total = sim:owner_count()
			for _ = 1, 20 do
				sim:remove_human(h3)
				sim:add_human("carol#3", "Carol")
			end
			expect(sim:owner_count() == before_total, "20 join/leave cycles allocate no new owners")
			sim:remove_human(h3)
		elseif t == 110 then
			expect(sim.phase == Defs.PHASE_PLAYING and sim.o_spawned[h2] == 1, "random spawn for Bob, playing")
			expect(gs.owners[h3].alive == false, "Carol left before spawning -> out")
		elseif t == 200 then
			sim:submit(h1, { type = "ally_request", target = h2 })
		elseif t == 205 then
			expect(gs:has_request(h1, h2), "alliance request mirrored")
			sim:submit(h2, { type = "ally_reply", target = h1, accept = true })
		elseif t == 150 then
			local tb = sim.o_troops[h1]
			sim:submit(h1, { type = "attack", tile = sim.o_spawn_tile[h2], ratio = 0 / 0 })
			sim:submit(h1, { type = "boat", tile = sim.o_spawn_tile[h2], ratio = math.huge })
			sim:submit(h1, { type = "attack", tile = { 1, 2 } :: any, ratio = { x = 1 } :: any })
			sim:submit(h1, { type = 7 :: any, tile = "x" :: any })
			saw.troops_before_nan = tb
		elseif t == 152 then
			expect(
				Defs.is_finite(sim.o_troops[h1]) and Defs.is_finite(sim.o_troops[h2]),
				"NaN / garbage intents leave troops finite"
			)
		elseif t == 210 then
			expect(gs:are_allies(h1, h2), "alliance formed")
			sim:submit(h1, { type = "donate", target = h2, troops = 1000 })
		elseif t == 260 then
			sim:submit(h1, { type = "ally_break", target = h2 })
		elseif t == 265 then
			expect(not gs:are_allies(h1, h2) and gs:is_traitor(h1), "betrayal -> traitor")
		elseif t == 300 then
			sim.o_gold[h1] += 30000000.0
			local site = sim:find_site(h1, Defs.S_SILO, sim.o_spawn_tile[h1], 10, 40)
			sim:submit(h1, { type = "build", kind = "silo", tile = site })
			local ps = sim:find_site(h1, Defs.S_PORT, sim:own_coast_tile(h1), 12, 40)
			if ps >= 0 then
				sim:submit(h1, { type = "build", kind = "port", tile = ps })
			end
		elseif t == 301 then
			local cs = sim:find_site(h1, Defs.S_CITY, sim.o_spawn_tile[h1], 12, 60)
			saw.city_site = cs
			local pv = Rules.placement(gs, h1, "city", cs)
			expect(pv.ok and pv.tile == cs and pv.upgrade_sid == 0, "placement preview: new city at a free site")
			sim:submit(h1, { type = "build", kind = "city", tile = cs })
		elseif t == 302 then
			local cs2 = saw.city_site
			local cid = readi32(sim.struct_at, cs2 * 4)
			expect(
				cid ~= 0
					and gs.structures[cid] ~= nil
					and gs.structures[cid].active_tick == sim.structs[cid].active_tick
					and gs.structures[cid].active_tick > sim.tick
					and not sim.structs[cid].active,
				"city under construction mirrored (active_tick)"
			)
			local pv2 = Rules.placement(gs, h1, "city", cs2)
			expect(pv2.upgrade_sid == 0, "no upgrade while under construction")
			saw.city_sid = cid
		elseif t == 330 then
			local cid2 = saw.city_sid
			local pv3 = Rules.placement(gs, h1, "city", saw.city_site + 1)
			expect(pv3.upgrade_sid == cid2, "click next to a finished own city previews an upgrade")
			sim:submit(h1, { type = "build", kind = "city", tile = saw.city_site + 1 })
		elseif t == 331 then
			local cid3 = saw.city_sid
			expect(
				gs.structures[cid3] ~= nil and gs.structures[cid3].level == 2 and sim.structs[cid3].level == 2,
				"upgrade: city level 2 (mirrored)"
			)
			expect(gs:struct_level_sum(h1, Defs.S_CITY) == sim:struct_levels(h1, Defs.S_CITY), "level sums mirrored")
			expect(
				Rules.cost_of(gs, h1, "city") == Rules.build_cost_kind(Defs.S_CITY, sim:cost_count(h1, Defs.S_CITY)),
				"cost_of(GameState) == Sim price"
			)
		elseif t == 305 then
			expect(gs:count_structures(h1, Defs.S_SILO) == 1, "silo built (under construction for 10 s)")
		elseif t == 420 then
			sim:submit(h1, { type = "build", kind = "warship", tile = sim:own_coast_tile(h1) })
			local tgt = sim.o_spawn_tile[h2]
			sim:submit(h1, { type = "nuke", kind = "atom", tile = tgt })
			saw.nuke_target = tgt
		elseif t == 520 then
			expect(sim.nukes_launched >= 1 and count_keys(gs.nukes) == #sim.nukes, "atom bomb launched, nukes mirrored")
			local ftile = saw.nuke_target
			local fo = 0
			local _, outer = Rules.nuke_radii(Defs.N_ATOM)
			for _, c in sim:disk_tiles(ftile, outer + 1.0) do
				if gs:has_fallout(c) then
					fo += 1
				end
			end
			expect(
				buffer.tostring(gs.flags) == buffer.tostring(sim.flags) and (fo > 0 or #sim.nukes > 0),
				fmt("fallout mirrored around the target (%d tiles)", fo)
			)
			expect(
				gs:count_units(h1, Defs.U_WARSHIP) <= 1,
				fmt("warship count sane (%d)", gs:count_units(h1, Defs.U_WARSHIP))
			)
			sim:submit(h1, {
				type = "nuke",
				kind = "mirv",
				tile = if sim.o_spawn_tile[h2] >= 0 then sim.o_spawn_tile[h2] else ftile,
			})
		elseif t == 700 then
			if saw.atom_boom ~= nil then
				local bt = saw.atom_boom
				local fo2 = 0
				local _, outer = Rules.nuke_radii(Defs.N_ATOM)
				for _, c in sim:disk_tiles(bt, outer) do
					if gs:has_fallout(c) then
						fo2 += 1
					end
				end
				expect(
					fo2 > 0 and buffer.tostring(gs.flags) == buffer.tostring(sim.flags),
					fmt("atom detonated at tick %d: %d fallout tiles mirrored", saw.atom_boom_tick, fo2)
				)
			else
				print("  (atom bomb was intercepted or is still flying)")
			end
		elseif t == 530 then
			sim:scan_border(h1, 2000)
			if #sim.sc_list > 0 then
				sim:submit(h1, { type = "attack", tile = sim.sc_tile[sim.sc_list[1]], ratio = 0.2 })
			end
		elseif t == 532 then
			local aid = 0
			for _, a in sim.attacks do
				if not a.dead and a.attacker == h1 then
					aid = a.aid
				end
			end
			if aid > 0 then
				sim:submit(h1, { type = "retreat", attack_id = aid })
				saw.retreat = aid
			end
		elseif t == 534 then
			if saw.retreat ~= nil then
				expect(gs.attacks[saw.retreat] == nil, "retreat ended attack")
			end
		elseif t == 1000 then
			h4 = sim:add_human("dave#4", "Dave")
			local lt = LAND
			for k = 0, #lt - 1 do
				local c = lt[(k * 7919) % #lt + 1]
				if readi32(sim.owner, c * 4) == 0 and sim:claimable(c) then
					late_tile = c
					break
				end
			end
			local snap = sim:snapshot()
			gs2 = GameState.new(map)
			gs2:load_snapshot(snap)
			gs2.local_owner = h4
		elseif t == 1001 then
			if late_tile >= 0 then
				sim:submit(h4, { type = "spawn", tile = late_tile })
			end
		elseif t == 1100 then
			-- Alice drops mid-match and reconnects: same nation, passive while away.
			saw.alice_tiles = sim.o_tiles[h1]
			sim:remove_human(h1)
		elseif t == 1150 then
			expect(
				sim.o_alive[h1] == 1 and sim.o_left[h1] == 1 and sim.o_ai[h1] == 0 and sim.o_tiles[h1] > 0,
				"left human's nation stays alive and passive"
			)
			local back = sim:add_human("alice#1", "Alice")
			expect(back == h1 and sim.o_left[h1] == 0, "reconnecting human reclaims the same nation")
			local fresh = sim:add_human("bob#2", "Bob")
			expect(
				sim.o_alive[h2] == 1 and fresh == h2 or sim.o_alive[h2] == 0 and fresh ~= h2,
				fmt("eliminated human rejoining gets a fresh nation (alive=%d)", sim.o_alive[h2])
			)
		elseif t == 1005 then
			if late_tile >= 0 then
				expect(sim.o_spawned[h4] == 1 and gs2.owners[h4].spawned, "late join spawned Dave")
			else
				print("  (no unclaimed land for a late join test)")
			end
		end
		if sim.phase == Defs.PHASE_PLAYING and t > 110 and t % 12 == 0 then
			_human_policy()
		end
		local d = sim:step()
		gs:apply_delta(d)
		if gs2 ~= nil then
			gs2:apply_delta(d)
		end
		for _, e in d.ev do
			saw[e[1]] = true
			if e[1] == Ev.BOOM and e[3] == Defs.N_ATOM and e[5] > 0 and saw.atom_boom == nil then
				saw.atom_boom = e[4]
				saw.atom_boom_tick = sim.tick
			end
		end
		if sim.tick % 600 == 0 then
			_check_mirror("mp tick " .. sim.tick)
			_check_snapshot("mp tick " .. sim.tick)
			if gs2 ~= nil and buffer.tostring(gs2.owner) ~= buffer.tostring(gs.owner) then
				failures += 1
				print(fmt("FAIL late-join mirror diverged at tick %d", sim.tick))
			end
		end
		if sim.phase == Defs.PHASE_OVER then
			break
		end
	end
	expect(
		sim.phase == Defs.PHASE_OVER and sim.over_reason == Defs.OVER_TIME,
		fmt("time limit ended the match (reason %d at tick %d)", sim.over_reason, sim.tick)
	)
	expect(gs.phase == Defs.PHASE_OVER and gs.winner == sim.winner, "game over mirrored")
	for _, k in
		{
			Ev.PHASE,
			Ev.SPAWNED,
			Ev.STRUCT_ADD,
			Ev.ROAD_ADD,
			Ev.UNIT_ADD,
			Ev.UNIT_DEL,
			Ev.NUKE,
			Ev.BOOM,
			Ev.ATTACK,
			Ev.ATTACK_END,
			Ev.ALLY_REQ,
			Ev.ALLY,
			Ev.ALLY_END,
			Ev.TRAITOR,
			Ev.MSG,
			Ev.OWNER_OUT,
			Ev.GAME_OVER,
			Ev.STRUCT_LEVEL,
		}
	do
		expect(saw[k] == true, "saw event " .. k)
	end
	if gs2 ~= nil then
		expect(
			buffer.tostring(gs2.owner) == buffer.tostring(gs.owner)
				and count_keys(gs2.structures) == count_keys(gs.structures),
			"late mirror equals main mirror"
		)
	end
end

if mode == "mp" then
	_run_mp()
else
	_run()
end
print(fmt("BENCH done, failures=%d", failures))
if failures > 0 then
	process.exit(1)
end
