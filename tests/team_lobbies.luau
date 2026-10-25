--!nocheck
-- Team games in the public lobbies (staging only): LobbyRules' team playlist (picking
-- a map's own team count 3 times in 4, else the weighted roll; 1.5 times the players, a multiple of the
-- team size), one free-for-all and one team lobby kept open, the mode surviving the store, and a
-- party taking its seats together in one teleport.
-- Run: .bin/lune run tests/team_lobbies.luau
require("./prelude")
local LobbyRules = require("../src/server/Lobbies/LobbyRules")
local LobbyStore = require("../src/server/Lobbies/LobbyStore")
local LobbyDirectory = require("../src/server/Lobbies/LobbyDirectory")
local Teams = require("../src/shared/Core/Teams")

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

-- the names agree with Core/Teams
expect(
	LobbyRules.DUOS == Teams.DUOS and LobbyRules.TRIOS == Teams.TRIOS and LobbyRules.QUADS == Teams.QUADS and LobbyRules.HVN == Teams.HVN,
	"LobbyRules and Teams name the formats alike"
)

-- team counts
expect(LobbyRules.team_config("irishsea", 0.5, 0.99) == 3, "Irish Sea: its own 3 teams 3 times in 4")
expect(LobbyRules.team_config("irishsea", 0.8, 0.0) == 2, "else the roll (2 teams first)")
expect(LobbyRules.team_config("world", 0.1, 0.99) == LobbyRules.HVN, "the roll's end: Humans Vs Nations")
expect(LobbyRules.team_config("world", 0.1, 0.62) == LobbyRules.DUOS, "Duos after the 60 points of 2..7 teams")
do
	local counts = {}
	for i = 0, 999 do
		local c = LobbyRules.team_config("world", 0.9, i / 1000)
		counts[c] = (counts[c] or 0) + 1
	end
	expect(counts[2] == 100 and counts[LobbyRules.HVN] == 200 and counts[LobbyRules.TRIOS] == 75, "the weights: 10 / 20 / 7.5 of 100")
end

-- team slots
local s, t = LobbyRules.team_slots(20, 7)
expect(s == 28 and t == 7, ("30 places, 7 teams: 28 (%d)"):format(s))
s, t = LobbyRules.team_slots(10, 7)
expect(s == 14 and t == 7, ("15 places, 7 teams of 2: 14 (%d)"):format(s))
s, t = LobbyRules.team_slots(10, LobbyRules.TRIOS)
expect(s == 15 and t == LobbyRules.TRIOS, "15 places in Trios")
s, t = LobbyRules.team_slots(10, LobbyRules.QUADS)
expect(s == 12, "15 places in Quads: 12")
s, t = LobbyRules.team_slots(30, LobbyRules.HVN)
expect(s == 15 and t == LobbyRules.HVN, "Humans Vs Nations: the humans' half")
s, t = LobbyRules.team_slots(10, 7)
s, t = LobbyRules.team_slots(4, 7)
expect(s == 6 and t == 3, ("too many teams for 2 each: as many as fit (%d places, %s teams)"):format(s, tostring(t)))

-- weights: listed team frequencies, others their map weight, none for a map listed at 0
do
	local w = LobbyRules.team_weights({ { id = "babelmandebstrait", weight = 1 }, { id = "world", weight = 30 }, { id = "archipelagosea", weight = 5 } })
	expect(w[1].weight == 10 and w[2].weight == 30 and w[3].weight == 0, "team weights")
end

-- scheduling per kind
local clock = 1000
local function tnow()
	return clock
end
do
	local open = {
		{ id = "f", map = "world", max = 30, starts = clock + 60, created = clock, players = 0, status = "open" },
	}
	expect(#LobbyRules.missing_starts(open, clock, "ffa", 1) == 0, "one free-for-all open: none missing")
	expect(#LobbyRules.missing_starts(open, clock, "team", 1) == 1, "no team game open: one missing")
	-- one about to close: the next is made now, LOBBY_INTERVAL_S after it (no gap between them)
	open[1].starts = clock + 20
	local nxt = LobbyRules.missing_starts(open, clock, "ffa", 1)
	expect(#nxt == 1 and nxt[1] == clock + 20 + LobbyRules.LOBBY_INTERVAL_S, "the next one before this one closes")
	-- production: 2 free-for-all, the next only once it fits in the open window
	open[1].starts = clock + 40
	expect(#LobbyRules.missing_starts(open, clock) == 1, "production (2 free-for-all): one more")
end

-- the directory: one of each, the team record keeps its kind
local store = LobbyStore.localstore(tnow)
local sent = {}
local reserved = 0
local hub = LobbyDirectory.new({
	store = store,
	teleport = {
		reserve = function()
			reserved += 1
			return "code" .. reserved, "psid" .. reserved
		end,
		send = function(players, code, data)
			table.insert(sent, { players = players, code = code, data = data })
			return true
		end,
	},
	maps = function()
		return {
			{ id = "world", name = "World", weight = 30, land = 651569, k_lin = 1 },
			{ id = "capecod", name = "Cape Cod", weight = 4, land = 400000, k_lin = 1 },
		}
	end,
	now = tnow,
	rand = function()
		return 0.1
	end,
	new_id = (function()
		local n = 0
		return function()
			n += 1
			return "L" .. n
		end
	end)(),
	team_games = true,
})
hub:refresh()
local ffa, team, world = nil, nil, nil
for _, l in hub:lobbies() do
	if LobbyRules.mode_of(l) == "team" then
		team = l
	elseif LobbyRules.mode_of(l) == "world" then
		world = l
	else
		ffa = l
	end
end
expect(ffa ~= nil and team ~= nil and world ~= nil and #hub:lobbies() == 3, "one free-for-all, one World and one team game open")
-- World's own record keeps its size as `slots` too (older servers skip it)
local wraw = store.get(world.id)
expect(wraw.max == nil and wraw.slots == world.max and wraw.mode == "world" and wraw.map == "world", "a World-kind record keeps its size as slots")
expect(team ~= nil and team.teams ~= nil and team.max % 2 == 0, ("the team game: %s teams, %d places"):format(tostring(team and team.teams), team and team.max or -1))
-- the store: a team game's size as `slots`, so servers from before team games skip the record
local raw = store.get(team.id)
expect(raw.max == nil and raw.slots == team.max, "a team game's record keeps its size as slots")
local function old_decode(v)
	-- (LobbyRules.decode before 2026-10-10: a record without a numeric `max` is unusable)
	return type(v) == "table" and type(v.id) == "string" and type(v.map) == "string" and type(v.starts) == "number" and type(v.max) == "number"
end
expect(not old_decode(raw) and old_decode(store.get(ffa.id)), "older servers skip it, and still read the free-for-all")
local back = LobbyRules.decode(store.get(team.id))
expect(back ~= nil and back.mode == "team" and back.teams == team.teams, "the store keeps the kind and the teams")
local view = LobbyRules.public_view(back, clock)
expect(view.mode == "team" and view.teams == team.teams, "clients see the kind and the teams")
expect(LobbyRules.public_view(ffa, clock).mode == nil, "a free-for-all shows no kind")
hub:refresh()
expect(#hub:lobbies() == 3, "nothing more while all three are open")

-- a party's seats in one go, one teleport
local p1, p2, p3 = { UserId = 1 }, { UserId = 2 }, { UserId = 3 }
local ok = hub:join(p1, team.id, { players = { p1, p2, p3 }, key = "K", uids = { "1", "2", "3" }, leader = 1 })
local last = sent[#sent]
expect(ok and #last.players == 3 and last.data.party.key == "K" and last.data.party.leader == 1, "a party of 3 goes in one teleport")
expect(LobbyRules.decode(store.get(team.id)).players == 3, "and takes 3 places")
-- no room for the whole party: refused
store.update(team.id, function(v)
	local l = LobbyRules.decode(v)
	l.players = l.max - 1
	return l
end)
local ok2, why = hub:join(p1, team.id, { players = { p1, p2 }, key = "K2", uids = { "1", "2" }, leader = 1 })
expect(not ok2 and why ~= nil and string.find(why, "party") ~= nil, "no room for the whole party: refused")

print(("team_lobbies: %d/%d passed"):format(total - fails, total))
if fails > 0 then
	error(("team_lobbies: %d failures"):format(fails))
end
