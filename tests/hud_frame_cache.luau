--!nocheck
-- The HUD's per-frame shortcuts give the answers the full scans gave (2026-10-27, phones' slow
-- frames): UICtx.leader / rank_of (one pass) against GameState.ranking() (a sort), and UIRules'
-- one pass over the player's structures (costs through Rules.cost_of, silos, launchers) against the
-- per-call scans it replaced.
-- Run: .bin/lune run tests/hud_frame_cache.luau
require("./prelude")
local Defs = require("../src/shared/Core/Defs")
local Rules = require("../src/shared/Core/Rules")
local GameState = require("../src/shared/Core/GameState")
local UICtx = require("../src/client/UI/UICtx")
local UIRules = require("../src/client/UI/UIRules")

local fails, total = 0, 0
local function expect(cond: any, what: string)
	total += 1
	if not cond then
		fails += 1
		print("FAIL " .. what)
	end
end

local seed = 5
local function rnd(a: number, b: number): number
	seed = (seed * 1103515245 + 12345) % 2147483648
	return a + seed % (b - a + 1)
end

--- A match's state as these read it: owners (ties in land, the dead, the landless), structures with
--- levels, builds still going and shots fired, units.
local function make_state(round: number): any
	local st = setmetatable({
		owners = {},
		structures = {},
		units = {},
		built = {},
		tick = 1000 + round * 7,
		render_tick = 1000.3 + round * 7,
		mirvs_launched = round % 3,
	}, { __index = GameState })
	for id = 1, rnd(1, 40) do
		st.owners[id] = { id = id, alive = rnd(0, 5) > 0, tiles = rnd(0, 6) * 50 }
		st.built[id] = {}
		for k = 0, Defs.STRUCT_KIND_COUNT - 1 do
			st.built[id][k] = rnd(0, 6)
		end
	end
	for sid = 1, rnd(20, 300) do
		local shots = {}
		for _ = 1, rnd(0, 3) do
			table.insert(shots, st.tick - rnd(0, 300))
		end
		st.structures[sid] = {
			sid = sid,
			owner = rnd(1, 4),
			kind = rnd(0, Defs.STRUCT_KIND_COUNT - 1),
			level = rnd(1, 3),
			active_tick = st.tick + rnd(-200, 60),
			shots = shots,
		}
	end
	for uid = 1, 40 do
		st.units[uid] = { owner = rnd(1, 4), kind = rnd(0, 3) }
	end
	return st
end

-- the scans UIRules made before (one per call)
local function scan_active(st: any, me: number, kind: number): (number, number, number)
	local act, building, soonest = 0, 0, math.huge
	for _, x in st.structures do
		if x.owner == me and x.kind == kind then
			if x.active_tick > st.tick then
				building += 1
				soonest = math.min(soonest, (x.active_tick - st.tick) / Defs.TICK_RATE)
			else
				act += 1
			end
		end
	end
	return act, building, if building > 0 then soonest else 0.0
end
local function scan_ready(st: any, me: number, kind: number): (number, number)
	local cd = Rules.RELOAD_TICKS[kind] or 0
	local n, soonest = 0, math.huge
	for _, x in st.structures do
		if x.owner == me and x.kind == kind and x.active_tick <= st.tick then
			local busy, first = 0, math.huge
			for _, t in x.shots do
				if t + cd > st.tick then
					busy += 1
					first = math.min(first, t + cd - st.tick)
				end
			end
			local free = math.max(0, x.level - busy)
			n += free
			if free == 0 then
				soonest = math.min(soonest, first)
			end
		end
	end
	return n, if n == 0 and soonest < math.huge then soonest / Defs.TICK_RATE else 0.0
end

local rank_bad, cost_bad, built_bad = 0, 0, 0
for round = 1, 40 do
	local st = make_state(round)
	local me = rnd(1, 4)
	local ctx = { state = st, session = {
		has_unlock = function()
			return true
		end,
	} }
	setmetatable(ctx, { __index = UICtx })
	ctx.me = function()
		return me
	end
	-- the leader and every owner's place, as the sorted ranking has them
	local ranking = st:ranking()
	if ctx:leader() ~= ranking[1] then
		rank_bad += 1
	end
	local place = {}
	for i, o in ranking do
		place[o.id] = i
	end
	for id in st.owners do
		if ctx:rank_of(id) ~= (place[id] or 0) then
			rank_bad += 1
		end
	end
	-- the build slots' numbers
	local ur = UIRules.new(ctx)
	for _, kind in UIRules.ACTIONS do
		if ur:cost(kind) ~= Rules.cost_of(st, me, kind) then
			cost_bad += 1
		end
	end
	for _, kind in UIRules.ARSENAL do
		if kind ~= "reinforce" and ur:cost(kind) ~= Rules.cost_of(st, me, kind) then
			cost_bad += 1
		end
	end
	for k = 0, Defs.STRUCT_KIND_COUNT - 1 do
		local a1, b1, c1 = ur:active_structs(k)
		local a2, b2, c2 = scan_active(st, me, k)
		local n1, w1 = ur:ready_launchers(k)
		local n2, w2 = scan_ready(st, me, k)
		if a1 ~= a2 or b1 ~= b2 or c1 ~= c2 or n1 ~= n2 or w1 ~= w2 then
			built_bad += 1
		end
	end
	-- a build a tick later: the numbers follow
	st.structures[9999] = { sid = 9999, owner = me, kind = Defs.S_CITY, level = 2, active_tick = st.tick + 5, shots = {} }
	st.tick += 1
	local a1, b1 = ur:active_structs(Defs.S_CITY)
	local a2, b2 = scan_active(st, me, Defs.S_CITY)
	if ur:cost("city") ~= Rules.cost_of(st, me, "city") or a1 ~= a2 or b1 ~= b2 then
		built_bad += 1
	end
end
expect(rank_bad == 0, "leader and ranks match the sorted ranking (" .. rank_bad .. " off)")
expect(cost_bad == 0, "build costs match Rules.cost_of (" .. cost_bad .. " off)")
expect(built_bad == 0, "silos / launchers / builds match the full scans (" .. built_bad .. " off)")

print(string.format("%d / %d passed", total - fails, total))
if fails > 0 then
	error(fails .. " failed")
end
