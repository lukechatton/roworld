--!nocheck
-- The Arsenal and Stars in a public match (server/MatchServer on a real Sim): a participant plays
-- with the unlocks the server has for them (never the client's word), an unlock bought mid-match works
-- at once, and Stars are paid once per life — when a nation falls, when the match ends, or (partly)
-- when the player walks away. Run: .bin/lune run tests/arsenal_match.luau
require("./prelude")
local U = require("./net_util")
local Protocol = require("../src/shared/Net/Protocol")
local MatchServer = require("../src/server/MatchServer")
local WorldMap = require("../src/shared/Core/WorldMap")
local Sim = require("../src/shared/Core/Sim")
local Defs = require("../src/shared/Core/Defs")
local Stars = require("../src/shared/Data/Stars")
local GameState = require("../src/shared/Core/GameState")
U.use_zstd(Protocol)

local fails = 0
local function expect(c: any, w: string)
	if c then
		print("  ok   " .. w)
	else
		fails += 1
		print("FAIL " .. w)
	end
end

local results = {}
local server = MatchServer.new({
	send = function(peer, op, ...)
		table.insert(peer.inbox, table.pack(op, ...))
	end,
	peers = function()
		return {}
	end,
	now_ms = function()
		return 0
	end,
	make_sim = function()
		return nil
	end,
	unlocks_of = function(peer)
		return peer.mask
	end,
	on_result = function(peer, result)
		table.insert(results, { peer = peer, result = result })
	end,
})

local map = WorldMap.get("pangaea")
local sim =
	Sim.new(map, { seed = 3, difficulty = 0, tribes = 20, max_humans = 8, time_limit_s = 2400, spawn_ticks = 30 })
server._mp_sim = sim
server._tracker = Stars.Tracker.new(sim)
server._stage = "spawn"

local function join(name, mask, uid)
	local peer = { name = name, inbox = {}, mask = mask }
	server._participants[peer] =
		{ uid = uid or name, key = name, name = name, owner = 0, active_msec = 0, spectator = false, voted = false }
	table.insert(server._order, peer)
	server:_ensure_owner(peer)
	return peer, server._participants[peer].owner
end

local alice, a = join("Alice", Defs.UNLOCK.mega, "12345")
local bob, b = join("Bob", 0, "-2")
expect(a > 0 and b > 0 and a ~= b, "both have a nation")
-- a person's Roblox user id travels with the match's cosmetics: their head shot beside their name
local cz = server:cosmetics_map()
expect(cz[a] ~= nil and cz[a].face == 12345, "a player's user id is their face in the cosmetics map")
expect(cz[b] == nil, "a Studio test player (a negative id) has none")
local mirror = GameState.new(map)
mirror:set_cosmetics({ [a] = { face = 12345 }, [b] = { face = -2 }, [9] = { flag = "x", face = "7" } }, true)
expect(mirror.cosmetics[a] ~= nil and mirror.cosmetics[a].face == 12345, "the client keeps a face on its own")
expect(mirror.cosmetics[b] == nil, "and drops one that is no user id")
expect(mirror.cosmetics[9] ~= nil and mirror.cosmetics[9].face == nil, "a bad face leaves the flag")
-- bot players wear a head shot too, each a different one of the server's pool
server.deps.bot_faces = { 101, 102, 103, 104, 105 }
server:_dress_bots({ 40, 41, 42, 43 })
local bz = server:cosmetics_map()
local seen_faces, distinct = {}, 0
for _, id in { 40, 41, 42, 43 } do
	local f = bz[id] and bz[id].face
	if type(f) == "number" and f >= 101 and f <= 105 and not seen_faces[f] then
		seen_faces[f] = true
		distinct += 1
	end
end
expect(distinct == 4, "every bot player has a head shot of its own from the pool")
expect(#server.deps.bot_faces == 5, "the pool itself is left whole")
server:_dress_bots({ 40, 41, 42, 43, 44, 45, 46 })
local short = 0
for _, id in { 40, 41, 42, 43, 44, 45, 46 } do
	short += if server._bot_cosmetics[id] ~= nil and server._bot_cosmetics[id].face ~= nil then 1 else 0
end
expect(short == 5, "a pool smaller than the bots runs out rather than repeating")
server.deps.bot_faces = nil
server:_dress_bots({})
expect(
	sim.o_unlock[a] == Defs.UNLOCK.mega and sim.o_unlock[b] == 0,
	"each plays with the unlocks the server has for them"
)

-- both pick a start, the match begins
local seed = 11
local function rnd(n)
	seed = (seed * 1103515245 + 12345) % 2147483648
	return seed % n
end
for _, id in { a, b } do
	for _ = 1, 400 do
		local t = map:land_tile(rnd(map.land_count))
		if map:is_contestable(t) and buffer.readi32(sim.owner, t * 4) == 0 then
			sim:submit(id, { type = "spawn", tile = t })
			break
		end
	end
end
for _ = 1, 400 do
	server:_step_once()
	if sim.phase == Defs.PHASE_PLAYING and sim.o_spawned[a] == 1 and sim.o_spawned[b] == 1 then
		break
	end
end
expect(sim.phase == Defs.PHASE_PLAYING and sim.o_spawned[a] == 1 and sim.o_spawned[b] == 1, "the match is being played")
for _ = 1, 300 do
	server:_step_once()
end
expect(#results == 0, "nobody is paid while they play")

-- a locked build is refused by the Sim, whatever the client sends
local spawn_a = sim.o_spawn_tile[a]
sim.o_gold[a] = 10000000
server:intent(alice, Protocol.encode_intent({ type = "build", kind = "artillery", tile = spawn_a }))
server:_step_once()
expect(sim:struct_count(a, Defs.S_ARTILLERY) == 0, "a build the player hasn't unlocked is refused")
-- unlocked mid-match (a purchase): it works from the next order
alice.mask = Defs.UNLOCK.mega + Defs.UNLOCK.artillery
server:unlocks_changed(alice)
expect(sim.o_unlock[a] == alice.mask, "an unlock bought mid-match reaches the Sim")
server:intent(alice, Protocol.encode_intent({ type = "build", kind = "artillery", tile = spawn_a }))
server:_step_once()
expect(sim:struct_count(a, Defs.S_ARTILLERY) == 1, "and the build goes through")
server:intent(alice, Protocol.encode_intent({ type = "reinforce" }))
server:_step_once()
expect(sim.o_reinforce_tick[a] < 0, "the reinforce intent arrives, and is refused without its unlock")

-- Bob walks away: paid for what he did, as a leaver
server:_drop_participant(bob)
expect(#results == 1 and results[1].peer == bob, "a player who leaves is paid once")
local rb = results[1].result
expect(
	rb.spawned and rb.left and not rb.won and rb.minutes > 0.4 and rb.field >= 2,
	"as a leaver, for the time he played"
)
expect(Stars.payout(rb, "public").total > 0, "which is worth some Stars")

-- the match ends with Alice the winner
sim.phase = Defs.PHASE_OVER
sim.winner = a
server:_step_once()
expect(#results == 2 and results[2].peer == alice, "the match ends: Alice is paid")
local ra = results[2].result
expect(ra.won and not ra.left and ra.spawned, "as the winner")
local pay = Stars.payout(ra, "public")
local has_victory = false
for _, l in pay.lines do
	if l[1] == "victory" then
		has_victory = true
	end
end
expect(has_victory and pay.total >= 100, "with the victory line")
server:_step_once()
server:_drop_participant(alice)
expect(#results == 2, "never twice")

if fails > 0 then
	error(fails .. " failures")
end
print("arsenal_match: all passed")
