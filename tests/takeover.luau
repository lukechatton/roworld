--!nocheck
-- Solo "take over the nation that eliminated you" (Sim.take_over): only in solo, only a fallen
-- human, only a living AI nation; the nation keeps its land, troops, gold and structures, its AI
-- stops, and the player's orders move it.
require("./prelude")
local Defs = require("../src/shared/Core/Defs")
local Ev = require("../src/shared/Core/Ev")
local WorldMap = require("../src/shared/Core/WorldMap")
local Sim = require("../src/shared/Core/Sim")

local fails = 0
local function expect(c: any, w: string)
	if c then
		print("  ok   " .. w)
	else
		fails += 1
		print("FAIL " .. w)
	end
end

local map = WorldMap.get("pangaea")
local sim = Sim.new(map, { seed = 21, difficulty = 1, tribes = 12, max_humans = 1 })
local function owner_of(t: number): number
	return buffer.readi32(sim.owner, t * 4)
end
expect(sim.solo, "a solo sim")
local me = sim:add_human("local", "Me")
-- place the human, then run into the war
local pick = -1
for k = 0, map.land_count - 1, 61 do
	local t = map:land_tile(k)
	if map:is_contestable(t) and owner_of(t) == 0 then
		pick = t
		break
	end
end
sim:human_start(me, pick)
local guard = 0
while sim.phase ~= Defs.PHASE_PLAYING and guard < 2000 do
	sim:step()
	guard += 1
end
for _ = 1, 50 do
	sim:step()
end
expect(sim.phase == Defs.PHASE_PLAYING and sim.o_alive[me] == 1, "playing, the human alive")

-- the strongest nation "conquers" the human
-- (a nation with a neighbour, so the player's attack order below has a target)
local function neighbour_of(n: number): number
	for id = 1, sim.owner_total do
		if id ~= n and id ~= me and sim.o_alive[id] == 1 and sim.o_tiles[id] > 0 and sim:borders(n, id) then
			return id
		end
	end
	return 0
end
local nation = 0
for id = 1, sim.owner_total do
	if
		sim.o_kind[id] == Defs.KIND_NATION
		and sim.o_alive[id] == 1
		and neighbour_of(id) > 0
		and (nation == 0 or sim.o_tiles[id] > sim.o_tiles[nation])
	then
		nation = id
	end
end
local tribe = 0
for id = 1, sim.owner_total do
	if sim.o_kind[id] == Defs.KIND_TRIBE and sim.o_alive[id] == 1 then
		tribe = id
		break
	end
end
expect(nation > 0 and tribe > 0, "a nation and a tribe to test with")
expect(not sim:can_take_over(me, nation), "no takeover while the human is alive")
sim:_eliminate(me, nation)
expect(sim.o_alive[me] == 0, "the human fell")
expect(not sim:can_take_over(me, tribe), "a tribe can't be taken over")
local tiles, troops, gold = sim.o_tiles[nation], sim.o_troops[nation], sim.o_gold[nation]
local name = sim.o_name[nation]
expect(sim:take_over(me, nation), "take over " .. name)
expect(sim.o_kind[nation] == Defs.KIND_HUMAN and sim.o_ai[nation] == 0, "now human-controlled, AI off")
expect(
	sim.o_tiles[nation] == tiles and sim.o_troops[nation] == troops and sim.o_gold[nation] == gold,
	"land, troops and gold kept"
)
expect(sim.human_keys["local"] == nation, "the player's key points at the nation")
expect(not sim:take_over(me, nation), "a second takeover is refused")

-- the mirror hears about it (OWNER_ADD with the human kind), and a message says so
local d = sim:step()
local added, said = false, false
for _, e in d.ev or {} do
	if e[1] == Ev.OWNER_ADD and e[2] == nation and e[5] == Defs.KIND_HUMAN and e[3] == "Me" then
		added = true
	end
	if e[1] == Ev.MSG and e[2] == nation and string.find(tostring(e[4]), "took over", 1, true) then
		said = true
	end
end
expect(added and said, 'OWNER_ADD (human, "Me") and "You took over ' .. name .. '"')
expect(sim.o_name[nation] == "Me", "the nation goes by the player's name now (" .. sim.o_name[nation] .. ")")

-- the AI no longer moves it: with no orders, it starts no attacks of its own for a while
-- (attacks already running at the takeover keep going and re-send updates: not new ones)
local known = {}
for _, a in sim.attacks do
	known[a.aid] = true
end
local started = 0
local others = 0
for _ = 1, 300 do
	local dd = sim:step()
	for _, e in dd.ev or {} do
		if e[1] == Ev.ATTACK and not known[e[2]] then
			known[e[2]] = true
			if e[3] == nation then
				started += 1
			else
				others += 1
			end
		end
	end
end
expect(others > 0, "(the AI nations kept attacking meanwhile: " .. others .. " new attacks)")
expect(started == 0, "300 ticks without orders: the nation starts no attacks (" .. started .. ")")

-- the player's orders move it
local target = neighbour_of(nation)
if target > 0 then
	local t = -1
	for tt = 0, sim.N - 1 do
		if owner_of(tt) == target then
			t = tt
			break
		end
	end
	local troops_now = sim.o_troops[nation]
	sim:submit(nation, { type = "attack", tile = t, ratio = 0.3 })
	sim:step()
	expect(sim.o_troops[nation] < troops_now, "an attack order from the player is carried out")
else
	print("  (no bordering owner to attack: order check skipped)")
end

-- a public match: a nation yes; a bot player never (it would give the bot away), a tribe never
do
	local mp = Sim.new(map, { seed = 3, difficulty = 0, tribes = 10, max_humans = 4, spawn_ticks = 30 })
	local a = mp:add_human("a", "Alice")
	local b = mp:add_human("b", "Bob")
	local bot = mp:add_bot_player("Carl", false)
	local function owner(t: number): number
		return buffer.readi32(mp.owner, t * 4)
	end
	local picks = {}
	for k = 0, map.land_count - 1, 211 do
		local t = map:land_tile(k)
		if map:is_contestable(t) and owner(t) == 0 then
			table.insert(picks, t)
		end
		if #picks >= 2 then
			break
		end
	end
	mp:submit(a, { type = "spawn", tile = picks[1] })
	mp:submit(b, { type = "spawn", tile = picks[2] })
	local g = 0
	while mp.phase ~= Defs.PHASE_PLAYING and g < 500 do
		mp:step()
		g += 1
	end
	for _ = 1, 20 do
		mp:step()
	end
	local nat = 0
	local trb = 0
	for id = 1, mp.owner_total do
		if mp.o_alive[id] == 1 and mp.o_tiles[id] > 0 then
			if mp.o_kind[id] == Defs.KIND_NATION and nat == 0 then
				nat = id
			elseif mp.o_kind[id] == Defs.KIND_TRIBE and trb == 0 then
				trb = id
			end
		end
	end
	expect(
		mp.phase == Defs.PHASE_PLAYING and nat > 0 and trb > 0 and mp.o_alive[bot] == 1,
		"a public match is on (a nation, a tribe, a bot player)"
	)
	mp:_eliminate(a, nat)
	expect(not mp:can_take_over(a, bot), "public: a bot player can't be taken over")
	expect(not mp:can_take_over(a, trb), "public: nor a tribe")
	expect(not mp:can_take_over(a, b), "public: nor a real player")
	expect(
		mp:take_over(a, nat) and mp.o_kind[nat] == Defs.KIND_HUMAN and mp.o_ai[nat] == 0,
		"public: the nation that eliminated Alice is hers"
	)
	expect(mp.o_name[nat] == "Alice", "and is called Alice")
	expect(mp.human_keys["a"] == nat, "her reconnect key points at it")
end

if fails > 0 then
	error(fails .. " failures")
end
print("takeover: all passed")
