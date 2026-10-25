-- Conquest gold (when a player is conquered): the conqueror takes the victim's gold
-- (half of a human's) exactly once, and Ev.CONQUEST (conqueror, conquered, gold) is emitted once per
-- victim, on every path: elimination, annexation of a small defender, AI capitulation. Tribes use
-- one flat colour (#d1cdc7). The client mirror fires GameState.conquest.
require("./fixtures/fixture_maps") -- the test-only maps (Pangaea, Onion)
local F = require("./simsys_fixture")
local Defs = F.Defs
local Ev = F.Ev
local Sim = require("../src/shared/Core/Sim")
local WorldMap = require("../src/shared/Core/WorldMap")
local GameState = require("../src/shared/Core/GameState")

local fails = 0
local function expect(c: any, w: string)
	if c then
		print("  ok   " .. w)
	else
		fails += 1
		print("FAIL " .. w)
	end
end

local function conquests(sim: any): { { any } }
	return F.events(sim, Ev.CONQUEST)
end

-- elimination: a nation's gold goes to the killer in full
do
	local sim = F.new_sim(1)
	local me = F.owner(sim, "Me", Defs.KIND_HUMAN, 100)
	local nation = F.owner(sim, "Nation", Defs.KIND_NATION, 5000)
	F.claim(sim, nation, 540, 150, 3)
	sim:_eliminate(nation, me)
	local ev = conquests(sim)
	expect(sim.o_gold[me] == 5100 and sim.o_gold[nation] == 0, "killer takes a nation's gold")
	expect(#ev == 1 and ev[1][2] == me and ev[1][3] == nation and ev[1][4] == 5000, "one CONQUEST event with the gold")
end

-- a human victim gives half
do
	local sim = F.new_sim(2)
	local me = F.owner(sim, "Me", Defs.KIND_HUMAN, 0)
	local other = F.owner(sim, "Other", Defs.KIND_HUMAN, 1001)
	sim:_eliminate(other, me)
	local ev = conquests(sim)
	expect(sim.o_gold[me] == 500.5 and #ev == 1 and ev[1][4] == 500, "half of a human's gold (event floors it)")
end

-- no killer, no conquest
do
	local sim = F.new_sim(3)
	local lone = F.owner(sim, "Lone", Defs.KIND_NATION, 700)
	sim:_eliminate(lone, 0)
	expect(#conquests(sim) == 0, "an owner that just runs out of land is no conquest")
end

-- annexation, then the leftover pockets fall later: one event, all the gold
if F.HAS_ATTACKS then
	local sim = F.new_sim(4)
	local me = F.owner(sim, "Me", Defs.KIND_HUMAN, 0)
	local victim = F.owner(sim, "Small", Defs.KIND_NATION, 3000)
	F.claim(sim, me, 540, 150, 4)
	F.claim(sim, victim, 548, 150, 2)
	sim:_annex(victim, me)
	local after_annex = sim.o_gold[me]
	sim.o_gold[victim] = 40 -- income of pockets that survived the annexation
	sim:_eliminate(victim, me)
	local ev = conquests(sim)
	expect(after_annex == 3000, "annexation hands over the gold at once")
	expect(sim.o_gold[me] == 3040 and #ev == 1 and ev[1][4] == 3000, "the final elimination adds pocket gold silently")
end

-- AI capitulation: the winner is paid once (it used to receive the loser's gold twice)
do
	local sim = F.new_sim(5)
	local winner = F.owner(sim, "Winner", Defs.KIND_NATION, 1000)
	local loser = F.owner(sim, "Loser", Defs.KIND_NATION, 2000)
	F.claim(sim, winner, 540, 150, 4)
	F.claim(sim, loser, 548, 150, 3)
	sim:capitulate(loser, winner)
	expect(sim.o_killer[loser] == winner, "capitulation names the conqueror")
	sim:_eliminate(loser, sim.o_killer[loser])
	local ev = conquests(sim)
	expect(sim.o_gold[winner] == 3000, "capitulation pays the loser's gold once: " .. sim.o_gold[winner])
	expect(#ev == 1 and ev[1][2] == winner and ev[1][4] == 2000, "and announces it once")
end

-- the client mirror
do
	local map = WorldMap.get("pangaea")
	local gs = GameState.new(map)
	local got = nil
	gs.conquest:Connect(function(by, victim, gold)
		got = { by, victim, gold }
	end)
	gs:apply_delta({ t = 1, ev = { { Ev.CONQUEST, 3, 7, 1234 } } })
	expect(got ~= nil and got[1] == 3 and got[2] == 7 and got[3] == 1234, "GameState fires conquest(by, victim, gold)")
end

-- tribes: one flat colour
do
	local sim = Sim.new(WorldMap.get("pangaea"), { seed = 3, difficulty = 1, tribes = 12, max_humans = 1 })
	local n, flat = 0, true
	for id = 1, sim.owner_total do
		if sim.o_kind[id] == Defs.KIND_TRIBE then
			n += 1
			if sim.o_color[id] ~= Defs.html_rgba("#d1cdc7") then
				flat = false
			end
		end
	end
	expect(n > 0 and flat, "all " .. n .. " tribes use #d1cdc7")
end

print(if fails == 0 then "sim_conquest: all passed" else string.format("sim_conquest: %d FAILED", fails))
if fails > 0 then
	error("sim_conquest failed")
end
