--!nocheck
-- Map/MapSurface: the tiles a change may have altered are queued and repainted once each
-- (on_tiles_changed, step). Whatever the queue leaves out or the fast path draws, the picture must be
-- the one a full redraw gives.
-- Run: .bin/lune run tests/map_surface_repaint.luau
local roblox = require("./prelude");
(getfenv() :: any).Instance = (roblox :: any).Instance;
(getfenv() :: any).Enum = (roblox :: any).Enum;
(getfenv() :: any).task = require("@lune/task");
(getfenv() :: any).warn = function() end -- (no EditableImage here: the surface says so)
local Defs = require("../src/shared/Core/Defs")
local WorldMap = require("../src/shared/Core/WorldMap")
local Sim = require("../src/shared/Core/Sim")
local GameState = require("../src/shared/Core/GameState")
local MapSurface = require("../src/client/Map/MapSurface")

local fails, total = 0, 0
local function expect(cond: any, what: string)
	total += 1
	if cond then
		print("  ok   " .. what)
	else
		fails += 1
		print("FAIL " .. what)
	end
end

local map = WorldMap.get("world")
local W = map.W

--- A client: a state following `sim`, and a surface painting it. `with_olds`: the surface is told
--- the owners the changed tiles had (as MapView tells it).
local function client(sim: any, with_olds: boolean)
	local state = GameState.new()
	state:load_snapshot(sim:snapshot())
	local surface = MapSurface.new(nil)
	surface:set_map(map)
	surface:bind(state)
	while surface._rebuild_active do
		surface:step()
	end
	state.tiles_changed:Connect(function(ch, olds)
		surface:on_tiles_changed(ch, if with_olds then olds else nil)
	end)
	state.flags_changed:Connect(function(ch)
		surface:on_flags_changed(ch)
	end)
	-- (as MapView wires them: an owner's colours, new or sent again; an alliance's green borders)
	state.owner_added:Connect(function(id)
		surface:refresh_palette()
		surface:repaint_owner(id)
	end)
	state.alliance_changed:Connect(function(a, b)
		surface:refresh_palette()
		surface:repaint_between(a, b)
	end)
	return state, surface
end

local function drain(surface: any)
	local guard = 0
	while surface:repaint_pending() > 0 and guard < 10000 do
		surface:step()
		guard += 1
	end
end

--- The picture now, and the tiles where a full redraw differs from it.
local function differs(surface: any): number
	drain(surface)
	local now = buffer.tostring(surface.comp)
	surface:rebuild_all()
	while surface._rebuild_active do
		surface:step()
	end
	drain(surface)
	local full = surface.comp
	if buffer.tostring(full) == now then
		return 0
	end
	local was = buffer.fromstring(now)
	local n = 0
	for i = 0, surface.N - 1 do
		if buffer.readu32(was, i * 4) ~= buffer.readu32(full, i * 4) then
			n += 1
		end
	end
	return n
end

local function new_sim(seed: number)
	local sim = Sim.new(map, { seed = seed, difficulty = 1, max_humans = 64, time_limit_s = 0, spawn_ticks = 100 })
	sim:add_bot_players(40)
	return sim
end

-- a match's first three minutes, the changes repainted as they come
do
	local sim = new_sim(5)
	local state, surface = client(sim, true)
	local state8, surface8 = client(sim, false)
	local changed, painted, painted8 = 0, 0, 0
	local hovered = 0
	for tick = 1, 1800 do
		local d = sim:step()
		changed += if d.tiles then #d.tiles else 0
		state:apply_delta(d)
		state8:apply_delta(d)
		painted += surface:repaint_pending()
		painted8 += surface8:repaint_pending()
		drain(surface)
		drain(surface8)
		if tick == 600 or tick == 1200 then
			-- the biggest nation is hovered (its border is thickened: diagonals count), then another
			local rank = state:ranking()
			hovered = rank[if tick == 600 then 1 else 2].id
			surface:set_hover(hovered)
			surface8:set_hover(hovered)
		end
		if tick == 900 then
			-- two nations that share a border become allies (their borders turn green there)
			local a, b = 0, 0
			for i = 0, map.N - 2 do
				local o1 = buffer.readi32(state.owner, i * 4)
				local o2 = buffer.readi32(state.owner, (i + 1) * 4)
				if o1 > 0 and o2 > 0 and o1 ~= o2 and (i + 1) % W ~= 0 then
					a, b = o1, o2
					break
				end
			end
			expect(a > 0, "two owners share a border at tick 900")
			for _, st in { state, state8 } do
				st.alliances[math.min(a, b) * 1024 + math.max(a, b)] = true
				st.alliance_changed:Fire(a, b, true, 0)
			end
		end
		if tick == 300 or tick == 899 or tick == 1500 then
			expect(differs(surface) == 0, ("tick %d: the picture is a full redraw's"):format(tick))
		end
	end
	expect(changed > 100000, ("%d tile changes went through"):format(changed))
	expect(hovered > 0 and next(state.alliances) ~= nil, "with a hovered owner and an alliance in the state")
	expect(differs(surface) == 0, "after three minutes: the picture is a full redraw's")
	expect(differs(surface8) == 0, "and so is the one painted without the old owners (the tile and its 8 neighbours)")
	expect(buffer.tostring(surface.comp) == buffer.tostring(surface8.comp), "the two are the same picture")
	expect(
		painted < changed * 3.5 and painted8 > painted * 1.5,
		("%.1f tiles repainted for each one changed (%.1f without the old owners; 9 before the queue)"):format(
			painted / changed,
			painted8 / changed
		)
	)
end

-- changes looked at later (on_tiles_changed records them; step() expands them within its budget,
-- 2026-10-12): many ticks recorded before any is looked at, with hovers and alliances made and broken
-- in between, then drained: still a full redraw's picture
do
	local sim = new_sim(9)
	local state, surface = client(sim, true)
	surface.budget_s = 0 -- (each step looks at its minimum share only)
	local made = {}
	for tick = 1, 1500 do
		local d = sim:step()
		state:apply_delta(d)
		if tick % 7 == 0 then
			surface:step() -- (a slow client: the changes pile up between steps)
		end
		if tick % 250 == 0 then
			local rank = state:ranking()
			surface:set_hover(rank[1 + (tick // 250) % 3].id)
		end
		if tick % 300 == 150 then
			-- two neighbours become allies; an earlier pair breaks theirs
			for i = 0, map.N - 2, 37 do
				local o1 = buffer.readi32(state.owner, i * 4)
				local o2 = buffer.readi32(state.owner, (i + 1) * 4)
				if o1 > 0 and o2 > 0 and o1 ~= o2 and (i + 1) % W ~= 0 then
					local k = math.min(o1, o2) * 1024 + math.max(o1, o2)
					if not state.alliances[k] then
						state.alliances[k] = true
						state.alliance_changed:Fire(o1, o2, true, 0)
						table.insert(made, { o1, o2 })
						break
					end
				end
			end
			if #made > 1 then
				local pair = table.remove(made, 1)
				state.alliances[math.min(pair[1], pair[2]) * 1024 + math.max(pair[1], pair[2])] = nil
				state.alliance_changed:Fire(pair[1], pair[2], false, 0)
			end
		end
	end
	expect(surface._pend_n > 0 or surface._queue_n > 0, "changes were still waiting when the match was stopped")
	expect(
		differs(surface) == 0,
		"changes looked at ticks later, across hovers and alliances: the picture is a full redraw's"
	)
end

-- an alliance ends, and before the frame that repaints its border a neighbour on that border changes hands
-- (2026-10-26: the tile kept the alliance's green border; the sweep looked for tiles next to the old ally,
-- and the neighbour's change was looked at with the alliance already gone; seed 9 above on v108's map)
do
	local sim = new_sim(5)
	for _ = 1, 400 do
		sim:step()
	end
	local state, surface = client(sim, true)
	local own = state.owner
	local function key(x: number, y: number): number
		return math.min(x, y) * 1024 + math.max(x, y)
	end
	-- a tile of `a` whose south neighbour is `b`'s, and a third owner `c`
	local t, a, b = -1, 0, 0
	for i = W, map.N - 2 * W - 1 do
		local o1, o2 = buffer.readi32(own, i * 4), buffer.readi32(own, (i + W) * 4)
		if o1 > 0 and o2 > 0 and o1 ~= o2 and not state.alliances[key(o1, o2)] then
			t, a, b = i, o1, o2
			break
		end
	end
	local c = 0
	for _, o in state:ranking() do
		if o.id ~= a and o.id ~= b then
			c = o.id
			break
		end
	end
	expect(t >= 0 and c > 0, "found a border between two owners, and a third owner")
	state.alliances[key(a, b)] = true
	state.alliance_changed:Fire(a, b, true, 0)
	drain(surface)
	local green = buffer.readu32(surface.comp, t * 4)
	expect(differs(surface) == 0, "allied: the picture is a full redraw's")
	state.alliances[key(a, b)] = nil
	state.alliance_changed:Fire(a, b, false, 0)
	buffer.writei32(own, (t + W) * 4, c)
	state.tiles_changed:Fire({ (t + W) * 1024 + c }, { b })
	drain(surface)
	expect(buffer.readu32(surface.comp, t * 4) ~= green, "the alliance ended: the border is no longer the ally's")
	expect(differs(surface) == 0, "an ended alliance and a neighbour that changed hands first: a full redraw's picture")
end

-- fallout (flags) and a nation falling: a later stretch of a match, with nukes
do
	local sim = new_sim(3)
	for _ = 1, 6000 do
		sim:step()
	end
	local state, surface = client(sim, true)
	local flags, most = 0, 0
	for _ = 1, 4200 do
		local d = sim:step()
		flags += if d.flags then #d.flags else 0
		most = math.max(most, if d.tiles then #d.tiles else 0)
		state:apply_delta(d)
		-- (one step a tick, as a slow client's frame: a big tick's repaint goes over several)
		surface:step()
	end
	expect(flags > 0, ("%d fallout changes went through"):format(flags))
	expect(
		most > MapSurface.REPAINT_TILES_PER_STEP,
		("a tick of %d changed tiles, more than a step repaints"):format(most)
	)
	expect(differs(surface) == 0, "minutes 10 to 17 with fallout and a nation falling: the picture is a full redraw's")

	-- hovering: nothing is repainted in the call, and a frame's share is bounded
	local rank = state:ranking()
	local big, small = rank[1], nil
	for _, o in rank do
		if o.tiles <= MapSurface.HOVER_FILL_MAX // 2 and o.tiles > 2000 then
			small = o
			break
		end
	end
	expect(
		big.tiles > MapSurface.HOVER_FILL_MAX * 3 and small ~= nil,
		("a nation of %d tiles and one of %d"):format(big.tiles, small and small.tiles or -1)
	)
	--- an inner tile of `id` (its 8 neighbours are its own) and one on its border (not at the map's edge)
	local function tiles_of(id: number): (number, number)
		local own = state.owner
		local inner, edge = -1, -1
		for i = W + 1, map.N - W - 2 do
			if
				buffer.readi32(own, i * 4) == id
				and i % W > 0
				and i % W < W - 1
				and buffer.readu8(state.flags, i) == 0
			then
				local all = true
				for _, d in { -1, 1, -W, W, -W - 1, -W + 1, W - 1, W + 1 } do
					all = all and buffer.readi32(own, (i + d) * 4) == id
				end
				if all and inner < 0 then
					inner = i
				elseif
					not all
					and edge < 0
					and (buffer.readi32(own, (i - 1) * 4) ~= id or buffer.readi32(own, (i + 1) * 4) ~= id)
				then
					edge = i
				end
				if inner >= 0 and edge >= 0 then
					break
				end
			end
		end
		return inner, edge
	end
	local function px(i: number): number
		return buffer.readu32(surface.comp, i * 4)
	end
	for _, case in { { big, false, "a big nation" }, { small, true, "a small nation" } } do
		local o, fills, what = case[1], case[2], case[3]
		local inner, edge = tiles_of(o.id)
		local inner0, edge0 = px(inner), px(edge)
		surface:set_hover(o.id)
		expect(
			px(inner) == inner0 and px(edge) == edge0 and surface:repaint_pending() > 0,
			what .. " hovered: nothing is repainted in the call"
		)
		local steps = 0
		while surface:repaint_pending() > 0 and steps < 10000 do
			surface:step()
			steps += 1
		end
		expect(px(edge) ~= edge0, what .. ": its border is brightened")
		expect(
			(px(inner) ~= inner0) == fills,
			what .. (if fills then ": its land too" else ": its land is left as it is (too big to repaint for a hover)")
		)
		expect(differs(surface) == 0, what .. " hovered: the picture is a full redraw's")
		-- (a fill scans the owner's box, SWEEP_SCAN_PER_STEP tiles a frame: a small nation whose box grew
		-- across the map, as boxes do over a match, takes a frame per scan share more than 12)
		local bx = surface._bbox[o.id]
		local area = (bx[3] - bx[1] + 3) * (bx[4] - bx[2] + 3)
		local most = math.max(
			12,
			math.ceil(area / MapSurface.SWEEP_SCAN_PER_STEP)
				+ math.ceil(o.tiles / MapSurface.REPAINT_TILES_PER_STEP)
				+ 1
		)
		expect(
			if fills then steps <= most else steps > 3,
			("%s: over %d frames (at most %d)"):format(what, steps, most)
		)
		surface:set_hover(0)
		drain(surface)
		expect(px(inner) == inner0 and px(edge) == edge0, what .. " left: as it was")
		expect(differs(surface) == 0, what .. " left: the picture is a full redraw's")
	end
	-- the pointer goes from one to the other and back before any frame: still the right picture
	surface:set_hover(big.id)
	surface:set_hover(small.id)
	surface:step()
	surface:set_hover(big.id)
	surface:step()
	surface:set_hover(0)
	surface:set_hover(small.id)
	expect(differs(surface) == 0, "hovers changing faster than they are painted: the picture is a full redraw's")
	surface:set_hover(0)
	expect(differs(surface) == 0, "and with nobody hovered")
end

-- the queue itself
do
	local sim = new_sim(9)
	local state, surface = client(sim, true)
	for _ = 1, 300 do
		state:apply_delta(sim:step())
		drain(surface)
	end
	-- an owned tile inside a nation: changing it twice in one batch queues it once
	local t = -1
	for i = W + 1, map.N - W - 2 do
		local o = buffer.readi32(state.owner, i * 4)
		if
			o > 0
			and buffer.readi32(state.owner, (i - 1) * 4) == o
			and buffer.readi32(state.owner, (i + 1) * 4) == o
			and buffer.readi32(state.owner, (i - W) * 4) == o
			and buffer.readi32(state.owner, (i + W) * 4) == o
		then
			t = i
			break
		end
	end
	local o = buffer.readi32(state.owner, t * 4)
	expect(t > 0 and surface:repaint_pending() == 0, "an inner tile of a nation, and nothing waiting")
	state:apply_delta({ t = state.tick + 1, tiles = { t * 1024 + 0, t * 1024 + 0 }, ev = {} })
	expect(
		surface:repaint_pending() == 5,
		("it goes to nobody: itself and its 4 neighbours wait, once (%d)"):format(surface:repaint_pending())
	)
	surface:step(nil, 2)
	expect(surface:repaint_pending() == 3, "a step paints as many as it is given")
	state:apply_delta({ t = state.tick + 1, tiles = { t * 1024 + o }, ev = {} })
	drain(surface)
	expect(
		surface:repaint_pending() == 0 and differs(surface) == 0,
		"given back: nothing waits, and the picture is a full redraw's"
	)
	-- nobody's land next to it: a tile changing between two strangers repaints only itself
	local lone = -1
	for i = W + 1, map.N - W - 2 do
		if
			buffer.readi32(state.owner, i * 4) == 0
			and buffer.readi32(state.owner, (i - 1) * 4) == 0
			and buffer.readi32(state.owner, (i + 1) * 4) == 0
			and buffer.readi32(state.owner, (i - W) * 4) == 0
			and buffer.readi32(state.owner, (i + W) * 4) == 0
			and map:is_contestable(i)
		then
			lone = i
			break
		end
	end
	state:apply_delta({ t = state.tick + 1, tiles = { lone * 1024 + o }, ev = {} })
	expect(lone > 0 and surface:repaint_pending() == 1, "a tile taken in the middle of nobody's land: only itself")
	expect(differs(surface) == 0, "and the picture is a full redraw's")
end

-- a step's time (budget_s), and an alliance's repaint (repaint_between)
do
	local sim = new_sim(4)
	for _ = 1, 2400 do
		sim:step()
	end
	local state, surface = client(sim, true)
	-- out of time: a step still paints its share of what waits, and a sweep still goes on
	surface.budget_s = 0
	local rank = state:ranking()
	surface:repaint_owner(rank[1].id)
	local guard = 0
	while #surface._sweeps > 0 and guard < 100000 do
		surface:step()
		guard += 1
	end
	expect(
		#surface._sweeps == 0 and guard > 1,
		("with no time a frame, a sweep of %d tiles still ends (%d frames)"):format(rank[1].tiles, guard)
	)
	drain(surface)
	-- a backlog: 4,000 of its tiles changed, each with its 8 neighbours
	local big, list = rank[1].id, {}
	for i = 0, map.N - 1 do
		if buffer.readi32(state.owner, i * 4) == big then
			table.insert(list, i * 1024 + big)
			if #list >= 4000 then
				break
			end
		end
	end
	surface:on_tiles_changed(list, nil)
	local waiting = surface:repaint_pending()
	expect(waiting > MapSurface.REPAINT_MIN_TILES * MapSurface.DRAIN_FRAMES, ("%d tiles waiting"):format(waiting))
	surface:step()
	local share = math.max(math.ceil(waiting / MapSurface.DRAIN_FRAMES), MapSurface.REPAINT_MIN_TILES)
	expect(
		surface:repaint_pending() == waiting - math.min(share, MapSurface.REPAINT_TILES_PER_STEP),
		("with no time, a frame paints its share: %d of %d"):format(waiting - surface:repaint_pending(), waiting)
	)
	surface.budget_s = 1
	surface:step()
	expect(
		surface:repaint_pending() == math.max(waiting - share - MapSurface.REPAINT_TILES_PER_STEP, 0),
		"with time, as many as a step repaints"
	)
	expect(differs(surface) == 0, "and the picture is a full redraw's")
	surface.budget_s = MapSurface.STEP_BUDGET_S

	--- two owners with land, `touch`: whether one has a tile next to the other's
	local function pair(touch: boolean): (number, number)
		local own, W = state.owner, map.W
		local next_to = {}
		for i = 0, map.N - 2 do
			local o1 = buffer.readi32(own, i * 4)
			if o1 > 0 then
				for _, j in { i + 1, i + W } do
					local o2 = if j < map.N then buffer.readi32(own, j * 4) else 0
					if o2 > 0 and o2 ~= o1 then
						next_to[math.min(o1, o2) * 1024 + math.max(o1, o2)] = true
					end
				end
			end
		end
		local ids = {}
		for _, o in state:ranking() do
			if o.tiles > 500 then
				table.insert(ids, o.id)
			end
		end
		for _, a in ids do
			for _, b in ids do
				if a < b and (next_to[a * 1024 + b] == true) == touch then
					local ba, bb = surface._bbox[a], surface._bbox[b]
					local apart = ba[3] + 1 < bb[1] - 1
						or bb[3] + 1 < ba[1] - 1
						or ba[4] + 1 < bb[2] - 1
						or bb[4] + 1 < ba[2] - 1
					if touch or apart then
						return a, b
					end
				end
			end
		end
		return 0, 0
	end
	local function ally(a: number, b: number, on: boolean)
		state.alliances[math.min(a, b) * 1024 + math.max(a, b)] = if on then true else nil
		state.alliance_changed:Fire(a, b, on, 0)
	end
	local fa, fb = pair(false)
	expect(fa > 0, "two owners far apart")
	ally(fa, fb, true)
	surface:step()
	expect(surface:repaint_pending() == 0, "their alliance repaints nothing (no border between them)")
	ally(fa, fb, false)
	local a, b = pair(true)
	expect(a > 0, "two owners next to each other")
	ally(a, b, true)
	local painted = 0
	guard = 0
	while surface:repaint_pending() > 0 and guard < 10000 do
		local before = surface._queue_n - surface._queue_head + 1
		surface:step()
		painted += before
		guard += 1
	end
	local sum = 0
	for _, o in state:ranking() do
		if o.id == a or o.id == b then
			sum += o.tiles
		end
	end
	expect(painted > 0 and painted * 10 < sum, ("their alliance repaints %d tiles of their %d"):format(painted, sum))
	expect(differs(surface) == 0, "allied: the picture is a full redraw's")
	ally(a, b, false)
	drain(surface)
	expect(differs(surface) == 0, "and when it ends")
end

-- a device that never quite catches up (a step every tick, each looking at its minimum share only):
-- the lists of changes and tiles waiting keep only what still waits, not every change of the match
-- (they grew until phones ran out of memory, v84, 2026-10-14), and the picture is still a full redraw's
do
	local sim = new_sim(13)
	local state, surface = client(sim, true)
	surface.budget_s = 0
	local recorded, peak_pend, peak_queue, compacted = 0, 0, 0, false
	for _ = 1, 1600 do
		local d = sim:step()
		recorded += if d.tiles then 2 * #d.tiles else 0
		state:apply_delta(d)
		local before = surface._pend
		surface:step()
		if surface._pend ~= before and surface._pend_n > 0 then
			compacted = true
		end
		peak_pend = math.max(peak_pend, surface._pend_n)
		peak_queue = math.max(peak_queue, surface._queue_n)
	end
	print(("  (recorded %d, longest change list %d, longest repaint queue %d)"):format(recorded, peak_pend, peak_queue))
	expect(recorded > 4 * MapSurface.COMPACT_MIN, "enough changes to need dropping the ones looked at")
	expect(compacted, "the change list was compacted while changes still waited")
	expect(
		peak_pend <= 2 * MapSurface.COMPACT_MIN + 2 * (recorded // 1600) * 40,
		"the change list stays near what waits, not every change of the match"
	)
	expect(surface._pend_n > 0 or surface._queue_n > 0, "changes were still waiting when the match was stopped")
	expect(differs(surface) == 0, "after compacting: the picture is a full redraw's")
end

print(("map_surface_repaint: %d/%d passed"):format(total - fails, total))
if fails > 0 then
	error(("map_surface_repaint: %d failures"):format(fails))
end
