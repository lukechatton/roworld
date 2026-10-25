--!nonstrict
-- ui-kit dev: believable GameState for HUD screenshots (port of tests/ui_mock_state.gd's
-- play_snapshot for the "hud" scene): 88 nations + 36 tribes grown around their capitals on the
-- real map, a human commander "Luke" (id 239) in Poland with structures, an ally (Germany), a
-- traitor (Belarus), an alliance request (Italy), fronts with Ukraine / Russia / Belarus and an
-- incoming hydrogen bomb. Tile counts reproduce the original's hud_desktop leaderboard.
-- Also: minimal Session / WorldView stand-ins (tests/ui_mock_session.gd).

local RS = game:GetService("ReplicatedStorage")
local Core = RS:WaitForChild("Airfront"):WaitForChild("Core")
local Defs = require(Core:WaitForChild("Defs"))
local GameState = require(Core:WaitForChild("GameState"))
local WorldMap = require(Core:WaitForChild("WorldMap"))

local M = {}
M.ME = 239
M.TICK = 4220

local LEADERS = {
	-- name, share, troops (the hud_desktop capture)
	{ "Russia", 0.099, 451000 },
	{ "China", 0.088, 405000 },
	{ "Canada", 0.058, 268000 },
	{ "Brazil", 0.044, 208000 },
	{ "United States", 0.031, 150000 },
	{ "Australia", 0.0302, 138000 },
	{ "Kazakhstan", 0.0298, 143000 },
	{ "India", 0.028, 140000 },
	{ "DR Congo", 0.021, 98400 },
	{ "Sudan", 0.018, 90700 },
}

local function rgba(r: number, g: number, b: number): number
	return math.floor(r * 255 + 0.5) * 16777216
		+ math.floor(g * 255 + 0.5) * 65536
		+ math.floor(b * 255 + 0.5) * 256
		+ 255
end

--- Grow `quota` tiles for `id` from `seed` over free contestable land (4-neighbour BFS).
local function grow(map, grid: buffer, id: number, seed: number, quota: number, rng: Random): number
	local got = 0
	local queue = { seed }
	local head = 1
	local seen = {}
	seen[seed] = true
	local tries = 0
	while got < quota do
		if head > #queue then
			-- enclosed: restart from a random free land tile
			tries += 1
			if tries > 40 then
				break
			end
			local t = map.land_tiles[rng:NextInteger(1, #map.land_tiles)]
			if buffer.readi32(grid, t * 4) == 0 and map:is_contestable(t) then
				table.insert(queue, t)
				seen[t] = true
			end
			continue
		end
		local t = queue[head]
		head += 1
		if buffer.readi32(grid, t * 4) == 0 and map:is_contestable(t) then
			buffer.writei32(grid, t * 4, id)
			got += 1
			for _, n in ipairs(map:neighbors4(t)) do
				if not seen[n] and map:is_contestable(n) and buffer.readi32(grid, n * 4) == 0 then
					seen[n] = true
					table.insert(queue, n)
				end
			end
		end
	end
	return got
end

function M.play_snapshot()
	local map = WorldMap.shared()
	local nations = WorldMap.load_nations()
	local tribe_names = WorldMap.load_tribe_names()
	local N = Defs.W * Defs.H
	local grid = buffer.create(N * 4)
	local cc = map.contestable_count
	local rng = Random.new(7)
	local by_name = {}
	for i, n in ipairs(nations) do
		by_name[n.name] = i
	end
	-- quotas: leaders, then everyone else by a smooth curve with Luke at rank 44 (0.28 %)
	local quota = {}
	local troops = {}
	for _, l in ipairs(LEADERS) do
		local id = by_name[l[1]]
		quota[id] = math.floor(l[2] * cc + 0.5)
		troops[id] = l[3]
	end
	local others = {}
	for i, n in ipairs(nations) do
		if quota[i] == nil and n.name ~= "Poland" then
			table.insert(others, i)
		end
	end
	for k = 1, 36 do
		table.insert(others, 88 + k)
	end
	-- deterministic shuffle
	for i = #others, 2, -1 do
		local j = rng:NextInteger(1, i)
		others[i], others[j] = others[j], others[i]
	end
	local me_tiles = math.floor(0.0028 * cc + 0.5)
	for rank, id in ipairs(others) do
		-- ranks 11..43 above Luke, the rest below
		local r = rank + 10
		local share
		if r <= 43 then
			share = 0.0175 * (0.0034 / 0.0175) ^ ((r - 11) / 32)
		else
			share = 0.0026 * (0.0002 / 0.0026) ^ ((r - 44) / (#others + 10 - 44))
		end
		quota[id] = math.max(4, math.floor(share * cc + 0.5))
	end
	-- Luke first (Poland, reaches the Baltic coast), then the rest by size.
	local pl = nations[by_name["Poland"]]
	local me_seed = map:latlon_to_tile(pl.lat, pl.lon)
	grow(map, grid, M.ME, me_seed, me_tiles, rng)
	local order = {}
	for id in pairs(quota) do
		table.insert(order, id)
	end
	table.sort(order, function(a, b)
		return quota[a] > quota[b]
	end)
	for _, id in ipairs(order) do
		local seed
		if id <= 88 then
			local n = nations[id]
			seed = map:latlon_to_tile(n.lat, n.lon)
		else
			seed = map.land_tiles[rng:NextInteger(1, #map.land_tiles)]
		end
		grow(map, grid, id, seed, quota[id], rng)
	end
	local rows = {}
	for i, n in ipairs(nations) do
		local alive = n.name ~= "Poland"
		local q = quota[i] or 0
		table.insert(rows, {
			i,
			n.name,
			Defs.html_rgba(n.color),
			Defs.KIND_NATION,
			0,
			alive,
			q,
			troops[i] or (q * 36 + rng:NextInteger(4000, 18000)),
			rng:NextInteger(40000, 2600000),
			q * 55 + 30000,
			900 + q // 2,
			0,
			if alive then map:latlon_to_tile(n.lat, n.lon) else -1,
		})
	end
	for k = 1, 36 do
		local tid = 88 + k
		local q = quota[tid] or 0
		table.insert(rows, {
			tid,
			tribe_names[k] or ("Tribe " .. k),
			Defs.hsv_rgba(rng:NextNumber(), 0.45, 0.8),
			Defs.KIND_TRIBE,
			0,
			true,
			q,
			q * 20 + 2000,
			rng:NextInteger(5000, 90000),
			q * 30 + 8000,
			300,
			0,
			0,
		})
	end
	table.insert(rows, {
		M.ME,
		"Luke",
		rgba(0.36, 0.62, 1.0),
		Defs.KIND_HUMAN,
		0,
		true,
		me_tiles,
		186900,
		1431000,
		310000,
		3400,
		0,
		me_seed,
	})
	-- my structures
	local mine = {}
	local coast = -1
	for t = 0, N - 1 do
		if buffer.readi32(grid, t * 4) == M.ME then
			table.insert(mine, t)
			if coast < 0 and map:is_coastal(t) then
				coast = t
			end
		end
	end
	local structs = {}
	local sid = 1
	local kinds = { Defs.S_CITY, Defs.S_CITY, Defs.S_CITY, Defs.S_FACTORY, Defs.S_SILO, Defs.S_DEFENSE }
	local step = math.max(1, #mine // 8)
	for k, kind in ipairs(kinds) do
		table.insert(structs, { sid, kind, M.ME, mine[math.min(#mine, k * step)], 1, 0 })
		sid += 1
	end
	if coast >= 0 then
		table.insert(structs, { sid, Defs.S_PORT, M.ME, coast, 1, 0 })
		sid += 1
	end
	local function id_of(name)
		return by_name[name]
	end
	local ukr_tile, rus_tile = -1, -1
	for t = 0, N - 1, 7 do
		local o = buffer.readi32(grid, t * 4)
		if o == id_of("Ukraine") and ukr_tile < 0 then
			ukr_tile = t
		elseif o == id_of("Russia") and rus_tile < 0 then
			rus_tile = t
		end
	end
	for _, r in ipairs(rows) do
		if r[1] == id_of("Belarus") then
			r[12] = M.TICK + 420 -- traitor
		end
	end
	local snap = {
		t = M.TICK,
		phase = Defs.PHASE_PLAYING,
		phase_left = 0,
		time_limit_ticks = 0,
		playing_since = 0,
		winner = 0,
		over_reason = -1,
		owner = grid,
		owners = rows,
		structs = structs,
		roads = {},
		units = if coast >= 0 then { { 1, Defs.U_WARSHIP, M.ME, { coast }, M.TICK - 100, 100, 0 } } else {},
		nukes = { { 900, Defs.N_HYDROGEN, id_of("Russia"), rus_tile, mine[1] or me_seed, M.TICK - 5, 45 } },
		attacks = {
			{ 1, M.ME, id_of("Ukraine"), 24500, ukr_tile },
			{ 2, id_of("Russia"), M.ME, 41000, mine[2] or -1 },
			{ 7, id_of("Belarus"), M.ME, 30400, mine[3] or -1 },
		},
		allies = { { M.ME, id_of("Germany") } },
		requests = { { id_of("Italy"), M.ME } },
	}
	return snap, by_name
end

function M.make_state()
	local snap, by_name = M.play_snapshot()
	local st = GameState.new(WorldMap.shared())
	st.local_owner = M.ME
	st:load_snapshot(snap)
	st.local_owner = M.ME
	return st, by_name
end

--- Session stand-in (tests/ui_mock_session.gd).
function M.session(st)
	local s = {
		mode = 1,
		state = st,
		difficulty = 1,
		intents = {},
		paused = false,
		lobby = {
			available = true,
			stage = "playing",
			countdown_s = 0.0,
			elapsed_s = 762.0,
			players = {},
			in_match = true,
		},
	}
	function s.send_intent(self, intent)
		table.insert(self.intents, intent)
		print("[MockSession] intent", intent.type, intent.target, intent.accept)
	end
	function s.local_display_name(_self)
		return "Luke"
	end
	function s.set_paused(self, on)
		self.paused = on
	end
	function s.multiplayer_available(_self)
		return true
	end
	return s
end

--- WorldView stand-in: logs the calls the HUD makes.
function M.world()
	local w = { calls = {} }
	for _, m in ipairs({
		"set_hover_owner",
		"focus_owner",
		"focus_tile",
		"set_selected_owner",
		"set_range_mode",
		"set_range_owner",
	}) do
		w[m] = function(self, ...)
			table.insert(self.calls, { m, ... })
		end
	end
	function w.screen_pos_of_tile(_self, _t)
		return Vector2.new(-1, -1)
	end
	return w
end

return M
