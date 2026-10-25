--!nocheck
-- Team games (Core/Teams, Sim.assign_teams):
--   * the team list (a number of teams, Duos / Trios / Quads, Humans Vs Nations; "Team N" past 7);
--   * assignment: a party whole on one team while it has room, everyone else evenly (Duos / Trios /
--     Quads: teams filled one by one), bot players filling; nobody left out;
--   * teammates are friendly (no attacks, no nukes, donations allowed), can't ally or betray each
--     other, and a teammate who left may be attacked;
--   * a team wins on its land together; tribes never win;
--   * the wire: the team in OWNER_ADD and in the snapshot, the winning team in GAME_OVER;
--   * a match without teams is unchanged (every owner on team 0).
-- Run: .bin/lune run tests/teams.luau
require("./prelude")
local Defs = require("../src/shared/Core/Defs")
local Rules = require("../src/shared/Core/Rules")
local WorldMap = require("../src/shared/Core/WorldMap")
local Sim = require("../src/shared/Core/Sim")
local Teams = require("../src/shared/Core/Teams")
local GameState = require("../src/shared/Core/GameState")
local Protocol = require("../src/shared/Net/Protocol")

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

-- the team list
do
	local two = Teams.resolve(2, 30)
	expect(#two == 2 and two[1] == "Red" and two[2] == "Blue", "2 teams: Red, Blue")
	expect(#Teams.resolve(Teams.DUOS, 10) == 5, "Duos of 10 players: 5 teams")
	expect(#Teams.resolve(Teams.TRIOS, 10) == 4, "Trios of 10: 4 teams (ceil)")
	expect(#Teams.resolve(Teams.QUADS, 3) == 2, "Quads of 3: at least 2 teams")
	local many = Teams.resolve(Teams.DUOS, 30)
	expect(#many == 15 and many[1] == "Team 1" and many[15] == "Team 15", "15 teams are numbered")
	local hvn = Teams.resolve(Teams.HVN, 12)
	expect(hvn[1] == Teams.HUMANS and hvn[2] == Teams.NATIONS, "Humans Vs Nations")
	expect(Teams.label(3) == "3 Teams" and Teams.label(Teams.DUOS) == "Duos", "labels")
end

-- assignment
do
	local function players(n: number, groups: { [number]: string }?, fillers_from: number?)
		local out = {}
		for i = 1, n do
			table.insert(out, { id = i, group = groups and groups[i], filler = fillers_from ~= nil and i >= fillers_from })
		end
		return out
	end
	local function count(a, n_teams)
		local c = table.create(n_teams, 0)
		for _, t in a do
			c[t] += 1
		end
		return c
	end
	-- 2 teams of 10: a party of 3 together, everyone placed, 5 / 5
	local p = players(10, { [4] = "p", [7] = "p", [9] = "p" }, 6)
	local a = Teams.assign(p, 2, false)
	local c = count(a, 2)
	expect(a[4] == a[7] and a[7] == a[9], "a party of 3 on one team")
	expect(c[1] == 5 and c[2] == 5, ("2 teams of 10: %d / %d"):format(c[1], c[2]))
	local placed = 0
	for _ in a do
		placed += 1
	end
	expect(placed == 10, "everyone has a team")
	-- Duos: teams fill one by one, a party of 2 is one team
	p = players(8, { [2] = "x", [5] = "x" }, 7)
	a = Teams.assign(p, 4, true)
	c = count(a, 4)
	expect(a[2] == a[5], "Duos: the party of 2 is a team")
	expect(c[1] == 2 and c[2] == 2 and c[3] == 2 and c[4] == 2, "Duos: 4 teams of 2")
	-- a party larger than a team spills over, but nobody is left out
	p = players(6, { [1] = "big", [2] = "big", [3] = "big" })
	a = Teams.assign(p, 3, true)
	c = count(a, 3)
	expect(c[1] == 2 and c[2] == 2 and c[3] == 2 and (a[1] == a[2] or a[2] == a[3] or a[1] == a[3]), "a party of 3 in Duos: two together, one spills over")
	-- fillers come last, in the shuffle's order
	p = players(4, nil, 3)
	local seen = {}
	Teams.assign(p, 2, false, function(list)
		for _, q in list do
			table.insert(seen, q.id)
		end
	end)
	expect(#seen == 2 and seen[1] == 3 and seen[2] == 4, "the fillers go through the shuffle")
	-- colours: the shades of one team differ, two teams differ
	local r0, r1, b0 = Teams.color("Red", 1, 0), Teams.color("Red", 1, 1), Teams.color("Blue", 2, 0)
	expect(r0 == Defs.html_rgba("#eb3333") and r1 ~= r0 and b0 ~= r0, "team colours: base, shade, other team")
	expect(Teams.color("Team 3", 3, 0) == Teams.color("Team 3", 3, 5), "a numbered team shares one colour")
end

local map = WorldMap.get("pangaea")

--- A public team match: `humans` humans (with `groups`: index → party) and bot players to `slots`.
local function team_match(config, humans: number, slots: number, groups: { [number]: string }?, seed: number?)
	local sim = Sim.new(map, {
		seed = seed or 7,
		difficulty = 0,
		max_humans = slots,
		time_limit_s = 0,
		spawn_ticks = 100,
		nations = if config == Teams.HVN then nil else false,
		nation_limit = if config == Teams.HVN then slots else nil,
		teams = config,
	})
	local ids, by_id = {}, {}
	for i = 1, humans do
		local id = sim:add_human("u" .. i, "Human" .. i)
		ids[i] = id
		if groups and groups[i] then
			by_id[id] = groups[i]
		end
	end
	if slots > humans then
		sim:add_bot_players(slots - humans)
	end
	sim:assign_teams(by_id)
	return sim, ids
end

-- a 2-team match
do
	local sim, h = team_match(2, 4, 12, { [1] = "party", [3] = "party" })
	expect(#sim.team_names == 2, "the match has 2 teams")
	local per = { 0, 0 }
	local untouched = 0
	for _, id in sim.humans do
		local t = sim.o_team[id]
		if t == 0 then
			untouched += 1
		else
			per[t] += 1
		end
	end
	expect(untouched == 0 and per[1] == 6 and per[2] == 6, ("12 players, 6 / 6 (%d / %d)"):format(per[1], per[2]))
	expect(sim.o_team[h[1]] == sim.o_team[h[3]], "the party is on one team")
	local tribe = 0
	for id = 1, sim.owner_total do
		if sim.o_kind[id] == Defs.KIND_TRIBE then
			tribe = id
			break
		end
	end
	expect(tribe > 0 and sim.o_team[tribe] == 0, "tribes are on no team")
	-- friendliness
	local mate, foe = 0, 0
	for _, id in sim.humans do
		if id ~= h[1] then
			if sim.o_team[id] == sim.o_team[h[1]] and mate == 0 then
				mate = id
			elseif sim.o_team[id] ~= sim.o_team[h[1]] and foe == 0 then
				foe = id
			end
		end
	end
	expect(sim:allied(h[1], mate) and not sim:has_alliance(h[1], mate), "teammates are friendly, without an alliance")
	expect(not sim:allied(h[1], foe), "the other team is not")
	expect(not sim:allied(h[1], tribe), "nor are tribes")
	expect(not sim:ally_request(h[1], mate), "no alliance request to a teammate")
	expect(not sim:ally_break(h[1], mate), "no betraying a teammate")
	expect(sim:ally_request(h[1], foe) == true, "an alliance with the other team may be asked")
	-- play into the match: spawn everyone, then a teammate's land can't be attacked
	while sim.phase ~= Defs.PHASE_PLAYING do
		sim:step()
	end
	for _ = 1, 300 do
		sim:step()
	end
	local mt = -1
	for t = 0, sim.N - 1 do
		if buffer.readi32(sim.owner, t * 4) == mate then
			mt = t
			break
		end
	end
	local before = sim.o_tiles[mate]
	sim:submit(h[1], { type = "attack", tile = mt, ratio = 0.5 })
	for _ = 1, 30 do
		sim:step()
	end
	expect(mt >= 0 and sim:attack_between(h[1], mate) == nil, "no attack on a teammate")
	expect(sim.o_tiles[mate] >= before - 50 or sim.o_alive[mate] == 1, "the teammate keeps its land")
	-- donations to a teammate
	sim.o_troops[h[1]] = 50000
	local mt0 = sim.o_troops[mate]
	expect(sim:donate(h[1], mate, 10000) and sim.o_troops[mate] > mt0, "troops can be sent to a teammate")
	-- a teammate who left may be attacked (like a disconnected teammate)
	sim:remove_human(h[3])
	expect(not sim:allied(h[1], h[3]), "a teammate who left is not friendly")
	-- the team wins on its land together
	local team = sim.o_team[h[1]]
	local need = Rules.WIN_SHARE * (sim.map.contestable_count - sim.fallout_count)
	local each = math.ceil(need / 6) + 1
	for _, id in sim.humans do
		if sim.o_team[id] == team then
			sim.o_tiles[id] = each
		end
	end
	sim:_check_victory()
	expect(sim.phase == Defs.PHASE_OVER and sim.winner_team == team and sim.o_team[sim.winner] == team, "the team wins with its land together")
	-- the wire: snapshot and events
	local gs = GameState.new()
	gs:load_snapshot(Protocol.decode_snapshot(Protocol.encode_snapshot(sim:snapshot())))
	expect(gs:is_team_game() and gs.team_names[1] == "Red" and gs.winner_team == team, "the snapshot carries the teams and the winning team")
	expect(gs:team_of(h[1]) == team and gs:same_team(h[1], mate) and gs:are_allies(h[1], mate), "the mirror knows teammates")
	expect(not gs:has_alliance(h[1], mate) and gs:alliance_info(h[1], mate) == nil, "and that they are not allied")
	local rank = gs:team_ranking()
	expect(#rank == 2 and rank[1].tiles >= rank[2].tiles and rank[1].members > 0, "team ranking: by land, with members")
end

-- events: the team reaches a mirror that joined before the teams were made
do
	local sim = Sim.new(map, { seed = 3, difficulty = 0, max_humans = 6, time_limit_s = 0, spawn_ticks = 100, nations = false, teams = 3 })
	local gs = GameState.new()
	gs:load_snapshot(sim:snapshot())
	local a = sim:add_human("a", "A")
	sim:add_bot_players(5)
	sim:assign_teams(nil)
	local d = sim:step()
	gs:apply_delta(Protocol.decode_delta(Protocol.encode_delta(d, d.ev, sim.W)))
	expect(gs:team_of(a) == sim.o_team[a] and gs:team_of(a) ~= 0, "OWNER_ADD carries the team")
	expect(#sim.team_names == 3, "3 teams")
	-- a late joiner with a party member goes onto its team; one alone onto the smallest
	local late = sim:add_human("late", "Late")
	sim:join_team(late, { a })
	expect(sim.o_team[late] == sim.o_team[a], "a late joiner joins its party's team")
	local alone = sim:add_human("alone", "Alone")
	sim:join_team(alone, nil)
	local count = { 0, 0, 0 }
	for _, id in sim.humans do
		if id ~= alone and sim.o_team[id] ~= 0 then
			count[sim.o_team[id]] += 1
		end
	end
	local smallest = math.min(count[1], count[2], count[3])
	expect(count[sim.o_team[alone]] == smallest, "one alone joins the smallest team")
end

-- Humans Vs Nations
do
	local sim = team_match(Teams.HVN, 2, 6)
	local humans_ok, nations, nations_ok = true, 0, true
	for id = 1, sim.owner_total do
		if sim.o_kind[id] == Defs.KIND_HUMAN then
			humans_ok = humans_ok and sim.o_team[id] == 1
		elseif sim.o_kind[id] == Defs.KIND_NATION then
			nations += 1
			nations_ok = nations_ok and sim.o_team[id] == 2
		end
	end
	expect(humans_ok and nations_ok, "humans and bot players vs the nations")
	expect(nations == 6, ("as many nations as players (%d)"):format(nations))
end

-- a match without teams is unchanged
do
	local sim = Sim.new(map, { seed = 5, difficulty = 1, max_humans = 4, time_limit_s = 0, spawn_ticks = 100 })
	sim:add_human("a", "A")
	sim:add_bot_players(3)
	sim:assign_teams(nil)
	local any = false
	for id = 1, sim.owner_total do
		any = any or sim.o_team[id] ~= 0
	end
	expect(not sim.team_mode and not any and #sim.team_names == 0, "free for all: nobody on a team")
end

print(("teams: %d/%d passed"):format(total - fails, total))
if fails > 0 then
	error(("teams: %d failures"):format(fails))
end
