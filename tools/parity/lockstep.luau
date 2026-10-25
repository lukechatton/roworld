-- sim-parity: lockstep trace of the PORT with Godot's RNG (tools/parity/GodotRng.luau) injected, in
-- the same format as tools/parity/lockstep.gd prints for the original:
--   .bin/lune run tools/parity/lockstep.luau -- --seed=1 --ticks=600 --out=/path/port.txt
--   options: --tribes=80 --diff=1 --human=0|1|2 (none / passive / scripted human, same policy as
--   lockstep.gd) --log_from= --log_to= --rnglog=<file> (RNG call sites in that tick window)
--   --hooks=a,b (tools/parity/hooks/<name>.luau diagnostics)
-- One line per tick: tick, RNG state, claimed tiles, live attacks, owner-tile checksum, troops sum,
-- nukes, structures, roads, units, delta hash. Diff against the original's trace
-- (tools/parity/diff.py) to find the first tick where the two simulations part ways.
require("../../tests/prelude")
local process = require("@lune/process")
local fs = require("@lune/fs")

local Rng = require("../../src/shared/Core/Rng")
local Defs = require("../../src/shared/Core/Defs")
local WorldMap = require("../../src/shared/Core/WorldMap")
local Sim = require("../../src/shared/Core/Sim")
local GodotRng = require("./GodotRng")

local readi32 = buffer.readi32
local readu8 = buffer.readu8
local sim: any

local seed_v, ticks, tribes, diff, out = 1, 600, 80, 1, "/dev/stdout"
local human = 0
local log_from, log_to, rnglog = -1, -1, ""
local dump_from, dump_to = -1, -1
local hooks = ""
for _, arg in process.args do
	local k, v = string.match(arg, "^%-%-([%w_]+)=(.*)$")
	if k == "seed" then
		seed_v = tonumber(v) :: number
	elseif k == "ticks" then
		ticks = tonumber(v) :: number
	elseif k == "tribes" then
		tribes = tonumber(v) :: number
	elseif k == "diff" then
		diff = tonumber(v) :: number
	elseif k == "human" then
		human = tonumber(v) :: number
	elseif k == "out" then
		out = v
	elseif k == "log_from" then
		log_from = tonumber(v) :: number
	elseif k == "log_to" then
		log_to = tonumber(v) :: number
	elseif k == "rnglog" then
		rnglog = v
	elseif k == "hooks" then
		hooks = v
	elseif k == "dump_from" then
		dump_from = tonumber(v) :: number
	elseif k == "dump_to" then
		dump_to = tonumber(v) :: number
	end
end

--- Builds a port Sim that draws from Godot's RNG exactly like sim.gd (rng.seed = hash(seed)).
local function new_sim(seed: number, cfg: { [string]: any }): any
	local orig_new = Rng.new
	Rng.new = function(s: number?): any
		return GodotRng.new(s or 0)
	end
	cfg.seed = seed
	local ok, s = pcall(Sim.new, WorldMap.shared(), cfg)
	Rng.new = orig_new
	if not ok then
		error(s)
	end
	return s
end

-- RNG call-site log (ticks log_from..log_to), same format as the traced original.
local cur_tick = 0
local rlines = {}
local function site(): string
	local function one(level: number): string
		local src, line, name = debug.info(level, "sln")
		if src == nil then
			return "?"
		end
		return string.format("%s:%d %s", string.match(src, "[^/]+$") or src, line, name or "?")
	end
	return one(4) .. " < " .. one(5)
end
local function on(): boolean
	return cur_tick >= log_from and cur_tick <= log_to
end
if log_from >= 0 then
	local r_randi, r_randf, r_randi_range, r_randf_range =
		GodotRng.randi, GodotRng.randf, GodotRng.randi_range, GodotRng.randf_range
	local depth = 0
	GodotRng.randi = function(self)
		local v = r_randi(self)
		if on() and depth == 0 then
			table.insert(rlines, string.format("%d randi %d @ %s", cur_tick, v, site()))
		end
		return v
	end
	GodotRng.randf = function(self)
		local v = r_randf(self)
		if on() and depth == 0 then
			table.insert(rlines, string.format("%d randf %.9f @ %s", cur_tick, v, site()))
		end
		return v
	end
	GodotRng.randi_range = function(self, a, b)
		local v = r_randi_range(self, a, b)
		if on() and a ~= b then
			table.insert(rlines, string.format("%d randi_range(%d,%d) %d @ %s", cur_tick, a, b, v, site()))
		end
		return v
	end
	GodotRng.randf_range = function(self, a, b)
		depth += 1
		local v = r_randf_range(self, a, b)
		depth -= 1
		if on() then
			table.insert(rlines, string.format("%d randf_range %.9f @ %s", cur_tick, v, site()))
		end
		return v
	end
end

-- Optional diagnostic hooks: tools/parity/hooks/<name>.luau returns function(ctx) that may wrap
-- Sim / SimAI methods and append lines to the RNG log with ctx.log(text) while ctx.on().
if hooks ~= "" then
	for _, name in string.split(hooks, ",") do
		local h = (require :: any)("./hooks/" .. name)
		h({
			Sim = Sim,
			SimAI = require("../../src/shared/Core/SimAI"),
			on = on,
			tick = function(): number
				return cur_tick
			end,
			log = function(text: string)
				table.insert(rlines, string.format("%d %s", cur_tick, text))
			end,
		})
	end
end

-- ---------------------------------------------------------------------------------------------
-- Delta hash (same rules as lockstep.gd): numbers as floor(x * 1000), strings as UTF-8 bytes,
-- arrays recursively; events, tiles, flags and the stats row.
-- ---------------------------------------------------------------------------------------------
local HM = 1000000007
local function hv(h: number, v: any): number
	local tv = type(v)
	if tv == "boolean" then
		return (h * 31 + (if v then 1 else 0) + 7) % HM
	elseif tv == "number" then
		local x = math.floor(v * 1000.0)
		-- h * 1000003 < 2^50: exact in doubles
		return (h * 1000003 + x % HM + 11) % HM
	elseif tv == "string" then
		local hh = (h * 17 + 3) % HM
		for i = 1, #v do
			hh = (hh * 257 + string.byte(v, i) + 1) % HM
		end
		return hh
	elseif tv == "table" then
		local hh = (h * 13 + 5) % HM
		for i = 1, #v do
			hh = hv(hh, v[i])
		end
		return (hh * 7 + 9) % HM
	end
	return (h * 3 + 1) % HM
end

local function fmtv(v: any): string
	local tv = type(v)
	if tv == "boolean" then
		return if v then "true" else "false"
	elseif tv == "number" then
		return string.format("%d", math.floor(v * 1000.0))
	elseif tv == "string" then
		return "'" .. v .. "'"
	elseif tv == "table" then
		local parts = {}
		for i = 1, #v do
			parts[i] = fmtv(v[i])
		end
		return "[" .. table.concat(parts, " ") .. "]"
	end
	return "?"
end

local dumps = {}
local function dump(d: any)
	for _, e in d.ev do
		table.insert(dumps, string.format("%d EV %s", sim.tick, fmtv(e)))
	end
	table.insert(dumps, string.format("%d TILES %s", sim.tick, fmtv(d.tiles)))
	table.insert(dumps, string.format("%d FLAGS %s", sim.tick, fmtv(d.flags)))
	if d.stats ~= nil then
		table.insert(dumps, string.format("%d STATS %s", sim.tick, fmtv(d.stats)))
	end
end

local function dhash(d: any): number
	local h = 1
	for _, e in d.ev do
		h = hv(h, e)
	end
	h = hv(h, d.tiles)
	h = hv(h, d.flags)
	if d.stats ~= nil then
		h = hv(h, d.stats)
	end
	return h
end

-- ---------------------------------------------------------------------------------------------
-- Deterministic scripted human (no Sim RNG) — the same policy as lockstep.gd.
-- ---------------------------------------------------------------------------------------------
local hid = 0
local hid_b = 0
local hid_c = 0
local lcg = 12345
local W = Defs.W
local N = Defs.TILE_COUNT

local function rand(): number
	lcg = (lcg * 16807) % 2147483647
	return lcg
end

local function free_around(t: number, r: number): boolean
	local cx = t % 1024
	local cy = t // 1024
	for dy = -r, r do
		for dx = -r, r do
			local y = math.clamp(cy + dy, 0, Defs.H - 1)
			if readi32(sim.owner, (y * W + (cx + dx) % 1024) * 4) ~= 0 then
				return false
			end
		end
	end
	return true
end

local function find_start(map: any): number
	local c = map:latlon_to_tile(2.0, 22.0)
	local cx = c % 1024
	local cy = c // 1024
	for r = 0, 79 do
		for dy = -r, r do
			for dx = -r, r do
				if math.max(math.abs(dx), math.abs(dy)) ~= r then
					continue
				end
				local y = cy + dy
				if y < 1 or y >= Defs.H - 1 then
					continue
				end
				local t = y * W + (cx + dx) % 1024
				if readu8(sim.land, t) == 1 and readi32(sim.owner, t * 4) == 0 and free_around(t, 7) then
					return t
				end
			end
		end
	end
	return map.land_tiles[1]
end

local function contacts(): { number }
	local out_ = {}
	local seen = {}
	local b = sim.bhead[hid]
	local steps = 0
	while b ~= -1 and steps < 400 and #out_ < 64 do
		local x = b % 1024
		local row = b - x
		for _, n in
			{
				row + (x + 1023) % 1024,
				row + (x + 1) % 1024,
				if b >= W then b - W else -1,
				if b < N - W then b + W else -1,
			}
		do
			if n >= 0 and readu8(sim.land, n) == 1 and readi32(sim.owner, n * 4) ~= hid and not seen[n] then
				seen[n] = true
				table.insert(out_, n)
			end
		end
		b = readi32(sim.bnext, b * 4)
		steps += 1
	end
	return out_
end

local function own_tile(): number
	local n = math.min(sim.bcount[hid], 300)
	if n <= 0 then
		return -1
	end
	local k = rand() % n
	local b = sim.bhead[hid]
	for _ = 1, k do
		b = readi32(sim.bnext, b * 4)
	end
	local x = b % 1024
	local row = b - x
	for _, c in { row + (x + 1023) % 1024, row + (x + 1) % 1024, b - W, b + W } do
		if c >= 0 and c < N and readi32(sim.owner, c * 4) == hid and readu8(sim.in_border, c) == 0 then
			return c
		end
	end
	return b
end

local lines = {}

-- Multiplayer script: Bravo never picks (random start at spawn end) and leaves 5 min in;
-- Charlie joins 2 min in on the first unowned claimable tile found from (-20, 130).
local function mp_script()
	if sim.phase ~= Defs.PHASE_PLAYING then
		return
	end
	local age = sim.tick + 1 - sim.playing_since
	if age == 1200 and hid_c == 0 then
		hid_c = sim:add_human("charlie", "Charlie")
		local c = sim.map:latlon_to_tile(-20.0, 130.0)
		local found = -1
		for k = 0, 199999 do
			local t = (c + k * 7) % N
			if
				readu8(sim.land, t) == 1
				and readi32(sim.owner, t * 4) == 0
				and bit32.band(readu8(sim.flags, t), 1) == 0
			then
				found = t
				break
			end
		end
		if found >= 0 then
			sim:submit(hid_c, { type = "spawn", tile = found })
		end
		table.insert(lines, string.format("mp charlie %d tile %d", hid_c, found))
	end
	if age == 3000 and hid_b > 0 then
		sim:remove_human(hid_b)
	end
end

local KINDS = { "city", "port", "factory", "defense", "sam", "silo" }
local NUKES = { "atom", "hydrogen", "mirv" }
local function policy()
	if sim.phase ~= Defs.PHASE_PLAYING or hid <= 0 or sim.o_alive[hid] == 0 or sim.o_spawned[hid] == 0 then
		return
	end
	if (sim.tick + 1) % 7 ~= 0 then
		return
	end
	local r = rand() % 20
	if r < 7 then
		local cs = contacts()
		if #cs > 0 and sim.o_troops[hid] >= 0.6 * sim.o_cap[hid] then
			local t = -1
			for _, c in cs do
				if readi32(sim.owner, c * 4) == 0 then
					t = c
					break
				end
			end
			if t < 0 then
				local c2 = cs[rand() % #cs + 1]
				if sim.o_troops[readi32(sim.owner, c2 * 4)] < sim.o_troops[hid] * 0.8 then
					t = c2
				end
			end
			if t >= 0 then
				sim:submit(hid, { type = "attack", tile = t, ratio = 0.2 + (rand() % 4) * 0.1 })
			end
		end
	elseif r < 11 then
		local t2 = own_tile()
		if t2 >= 0 and sim.o_gold[hid] >= 150000.0 then
			sim:submit(hid, { type = "build", kind = KINDS[rand() % #KINDS + 1], tile = t2 })
		end
	elseif r == 11 then
		local ct = sim.map.coast_tiles
		for _ = 1, 30 do
			local c = ct[rand() % #ct + 1]
			if readi32(sim.owner, c * 4) ~= hid and readu8(sim.land, c) == 1 then
				sim:submit(hid, { type = "boat", tile = c, ratio = 0.2 })
				break
			end
		end
	elseif r == 12 and sim.o_gold[hid] >= 1000000.0 then
		local lt = sim.map.land_tiles
		for _ = 1, 30 do
			local c2 = lt[rand() % #lt + 1]
			local o = readi32(sim.owner, c2 * 4)
			if o > 0 and o ~= hid and not sim:allied(hid, o) then
				sim:submit(hid, { type = "nuke", kind = NUKES[rand() % 3 + 1], tile = c2 })
				break
			end
		end
	elseif r == 13 then
		sim:submit(hid, { type = "ally_request", target = 1 + rand() % sim.owner_total })
	elseif r == 14 then
		for id = 1, sim.owner_total do
			if sim:has_request(id, hid) then
				sim:submit(hid, { type = "ally_reply", target = id, accept = rand() % 2 == 0 })
			end
		end
	elseif r == 15 then
		for id = 1, sim.owner_total do
			if sim:allied(hid, id) then
				if rand() % 3 == 0 then
					sim:submit(hid, { type = "ally_break", target = id })
				else
					sim:submit(hid, { type = "donate", target = id, troops = Defs.trunc(sim.o_troops[hid] * 0.05) })
				end
				break
			end
		end
	elseif r == 16 then
		for _, a in sim.attacks do
			if not a.dead and a.attacker == hid then
				sim:submit(hid, { type = "retreat", attack_id = a.aid })
				break
			end
		end
	elseif r == 17 then
		for _, u in sim.unit_list do
			if not u.dead and u.owner == hid and u.kind == Defs.U_WARSHIP then
				local p = sim:unit_tile(u)
				local dst = (p // 1024 + (rand() % 21) - 10) * W + ((p % 1024) + (rand() % 41) - 20) % 1024
				sim:submit(hid, { type = "move_warship", uid = u.uid, tile = math.clamp(dst, 0, N - 1) })
				break
			end
		end
	else
		local cs2 = contacts()
		if #cs2 > 0 then
			sim:submit(hid, { type = "attack", tile = cs2[1], ratio = 0.5 })
		end
	end
end

if human == 3 then
	-- Multiplayer: 4 slots, spawn phase, 15 min limit (see mp_script).
	sim = new_sim(seed_v, { difficulty = diff, tribes = tribes, max_humans = 4, time_limit_s = 900 })
else
	sim = new_sim(seed_v, {
		difficulty = diff,
		tribes = tribes,
		max_humans = if human > 0 then 1 else 0,
		time_limit_s = 0,
	})
end
local ck = 0
for id = 1, sim.owner_total do
	ck += sim.o_tiles[id] * id
end
table.insert(lines, string.format("init %s owners %d ck %d", sim.rng:state_string(), sim.owner_total, ck))
if human == 3 then
	hid = sim:add_human("alpha", "Alpha")
	hid_b = sim:add_human("bravo", "Bravo")
	local st0 = find_start(sim.map)
	sim:submit(hid, { type = "spawn", tile = st0 })
	table.insert(lines, string.format("mp humans %d %d start %d", hid, hid_b, st0))
elseif human > 0 then
	hid = sim:add_human("bench", "Bench Commander")
	local st = find_start(sim.map)
	local ok = sim:human_start(hid, st)
	table.insert(lines, string.format("human %d start %d ok %s", hid, st, tostring(ok)))
end
for _ = 1, ticks do
	cur_tick = sim.tick + 1
	if human == 2 or human == 3 then
		policy()
	end
	if human == 3 then
		mp_script()
	end
	local d = sim:step()
	if human > 0 and sim.tick % 600 == 0 and process.env.LS_VERBOSE then
		print(
			string.format(
				"minute %d human alive %d tiles %d troops %.0f gold %.0f structs %d",
				sim.tick // 600,
				sim.o_alive[hid],
				sim.o_tiles[hid],
				sim.o_troops[hid],
				sim.o_gold[hid],
				(function()
					local n = 0
					for _, st in sim.struct_list do
						if not st.dead and st.owner == hid then
							n += 1
						end
					end
					return n
				end)()
			)
		)
	end
	if sim.tick >= dump_from and sim.tick <= dump_to then
		dump(d)
	end
	local claimed, cks, tr = 0, 0, 0.0
	for id = 1, sim.owner_total do
		if sim.o_alive[id] == 1 then
			claimed += sim.o_tiles[id]
		end
		cks += sim.o_tiles[id] * id
		tr += sim.o_troops[id]
	end
	local live = 0
	for _, a in sim.attacks do
		if not a.dead then
			live += 1
		end
	end
	table.insert(
		lines,
		string.format(
			"%d %s %d %d %d %d %d %d %d %d %d",
			sim.tick,
			sim.rng:state_string(),
			claimed,
			live,
			cks,
			math.floor(tr),
			sim.nukes_launched,
			sim:struct_total(),
			sim:road_total(),
			sim:unit_total(),
			dhash(d)
		)
	)
end
fs.writeFile(out, table.concat(lines, "\n") .. "\n")
if rnglog ~= "" then
	for _, l in dumps do
		table.insert(rlines, l)
	end
	fs.writeFile(rnglog, table.concat(rlines, "\n") .. "\n")
end
