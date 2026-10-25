--!nocheck
-- Creator Dashboard analytics: the server side (src/server/Analytics.luau: validation, once per
-- milestone, experience buckets, results, killer classification, quitting) and the client side
-- (src/client/UI/Telemetry.luau: what a match reports, resyncs, leaving early).
require("./prelude")
local Defs = require("../src/shared/Core/Defs")
local Signal = require("../src/shared/Core/Signal")
local Analytics = require("../src/server/Analytics")
local Telemetry = require("../src/client/UI/Telemetry")

local fails = 0
local function expect(c: any, w: string)
	if c then
		print("  ok   " .. w)
	else
		fails += 1
		print("FAIL " .. w)
	end
end

-- ---------------------------------------------------------------------------------------------
-- server
-- ---------------------------------------------------------------------------------------------

local log = {}
local stats = {}
local guid_n = 0
Analytics.configure({
	onboarding = function(p, step, name)
		table.insert(log, { "onboard", p, step, name })
	end,
	funnel = function(p, funnel, session, step, name, f)
		table.insert(log, { "funnel", p, step, name, session, f[1], f[2] })
	end,
	custom = function(p, name, value, f)
		table.insert(log, { "event", p, name, value, f[1], f[2], f[3] })
	end,
	guid = function()
		guid_n += 1
		return "m" .. guid_n
	end,
	load_stats = function(p, fn)
		fn(stats[p])
	end,
	save_stats = function(p, s)
		stats[p] = s
	end,
	classify = function(id)
		return if id == 7 then "bot" elseif id == 8 then "human" else nil
	end,
	warn = function() end,
})
local function find(kind: string, a: any, b: any?): any
	for _, e in log do
		if e[1] == kind and e[3] == a and (b == nil or e[4] == b) then
			return e
		end
	end
	return nil
end
local function count(kind: string, a: any): number
	local n = 0
	for _, e in log do
		if e[1] == kind and e[3] == a then
			n += 1
		end
	end
	return n
end

do
	local P = "newbie"
	Analytics.joined(P)
	Analytics.report(P, "title")
	Analytics.report(P, "title")
	expect(find("onboard", 1) and find("onboard", 2) and count("onboard", 2) == 1, "joined + title screen, once each")
	Analytics.report(P, "spawned")
	expect(find("onboard", 4) == nil, "no match yet: spawned is ignored")
	Analytics.report(P, "match_start", "hacker", "world")
	expect(find("onboard", 3) == nil, "an unknown mode is ignored")
	Analytics.report(P, "match_start", "solo0", "world@80")
	local ms = find("event", "Match Start")
	expect(find("onboard", 3) and ms and ms[5] == "Solo Easy" and ms[6] == "1st match" and ms[7] == "world@80", "match start: Solo Easy, 1st match, map")
	local f1 = find("funnel", 1)
	expect(f1 and f1[4] == "Started" and f1[5] == "m1" and f1[6] == "Solo Easy", "Match funnel step 1 with its session id")
	expect(stats[P] and stats[P].matches == 1, "the match count is saved")
	Analytics.report(P, "spawned")
	Analytics.report(P, "attack")
	Analytics.report(P, "attack")
	expect(find("onboard", 4) and find("onboard", 5) and count("funnel", 3) == 1, "spawned, first attack (once)")
	Analytics.report(P, "alive", 1.0)
	expect(find("onboard", 6) == nil, "1 min: no milestone yet")
	Analytics.report(P, "alive", 3.04)
	Analytics.report(P, "alive", 2)
	expect(find("onboard", 6) and find("funnel", 4) and find("onboard", 7) == nil, "survived 3 min")
	Analytics.report(P, "eliminated", 4.26, "player", 7)
	local el = find("event", "Eliminated")
	expect(el and el[4] == 4.3 and el[7] == "Bot Player", "eliminated after 4.3 min by a bot player (server classifies)")
	local me = find("event", "Match End")
	expect(me and me[7] == "Eliminated" and me[4] == 4.3, "match end: Eliminated, 4.3 min")
	Analytics.report(P, "over", true, 10, 1)
	expect(count("event", "Match End") == 1 and find("funnel", 6) == nil, "after elimination the end changes nothing")

	Analytics.report(P, "match_start", "public", "europe")
	local ms2 = log[#log]
	expect(find("onboard", 8) and ms2[3] == "Match Start" and ms2[6] == "2nd-5th match" and ms2[5] == "Public", "second match: onboarding step 8, 2nd-5th match")
	Analytics.report(P, "alive", 999)
	Analytics.report(P, "over", false, 11.5, 3)
	local fr = find("event", "Final Rank")
	expect(fr and fr[4] == 3, "final rank 3")
	local me2 = log[#log]
	expect(me2[3] == "Match End" and me2[7] == "Lost" and me2[4] == Analytics.MAX_MINUTES, "lost; minutes clamped")
	expect(find("onboard", 7) ~= nil, "survived 10 min")

	Analytics.report(P, "match_start", "solo2", "../../etc")
	local ms3 = log[#log]
	expect(ms3[7] == "unknown" and ms3[5] == "Solo Hard", "a malformed map id is replaced")
	Analytics.report(P, "match_start", "solo1", "world")
	local left = find("event", "Match End", 0)
	expect(left ~= nil, "a match left unfinished ends when the next one starts")
	Analytics.report(P, "help", "match")
	local h = log[#log]
	expect(h[3] == "How To Play" and h[7] == "In Match" and h[5] == "Solo Medium", "how to play, in a match")
	Analytics.left(P)
	local q = log[#log - 2]
	expect(q[3] == "Match End" and q[7] == "Quit Game", "leaving the game mid-match: Quit Game")
	Analytics.report(P, 42)
	Analytics.report(P, "alive", "nan")
	expect(true, "junk is ignored without errors")
end

do
	local P = "killedbynation"
	Analytics.report(P, "match_start", "solo1", "world")
	Analytics.report(P, "eliminated", 2, "nation", 99)
	local e = log[#log - 1]
	expect(e[3] == "Eliminated" and e[7] == "Nation", "unknown to the server: the client's nation / tribe")
	Analytics.report(P, "match_start", "public", "world")
	Analytics.report(P, "eliminated", 2, "player", 8)
	e = log[#log - 1]
	expect(e[7] == "Real Player", "a real player")
	expect(Analytics.experience(0) == "1st match" and Analytics.experience(4) == "2nd-5th match" and Analytics.experience(5) == "6th+ match", "experience buckets")
end

-- the last snapshot is logged when a player quits or leaves (why do they give up?)
do
	local P = "quitter"
	stats[P] = { matches = 0 }
	Analytics.report(P, "match_start", "solo0", "world")
	Analytics.report(P, "state", "Growing", "Top 10", 58)
	Analytics.report(P, "alive", 1.5)
	Analytics.report(P, "state", "Under attack", "Lower", 17.6)
	Analytics.report(P, "state", "Bored", "Top 3", 60)
	Analytics.report(P, "state", "Idle", "Everywhere", 60)
	Analytics.left(P)
	local sit = log[#log - 1]
	local fps = log[#log]
	expect(
		sit[3] == "Quit Situation" and sit[4] == 1.5 and sit[5] == "Solo Easy" and sit[6] == "Under attack" and sit[7] == "Lower",
		"Quit Situation: the last valid snapshot (unknown values ignored)"
	)
	expect(
		fps[3] == "Quit FPS" and fps[4] == 17 and fps[6] == "Under 20 fps" and fps[7] == "1st match",
		"Quit FPS: frame rate, its band, experience"
	)
	local P2 = "leaver"
	Analytics.report(P2, "match_start", "public", "world")
	Analytics.report(P2, "left", 0.2)
	local s2 = log[#log - 1]
	expect(s2[3] == "Left Situation" and s2[6] == "No report" and log[#log][6] == "Unknown", "left before the first snapshot: No report")
	local P3 = "winner"
	Analytics.report(P3, "match_start", "solo1", "world")
	Analytics.report(P3, "state", "Holding", "Top 3", 60)
	Analytics.report(P3, "over", true, 30, 1)
	expect(log[#log][3] == "Match End" and log[#log][7] == "Won", "a won match logs no quit snapshot")
	Analytics.report(P3, "state", "Idle", "Top 3", 1e9)
	expect(log[#log][3] == "Match End", "a snapshot after the end is ignored")
	expect(
		Analytics.fps_band(0) == "Unknown" and Analytics.fps_band(19) == "Under 20 fps" and Analytics.fps_band(20) == "20-39 fps" and Analytics.fps_band(40) == "40+ fps",
		"fps bands"
	)
end

-- presence: who is playing solo now (the lobby service's live page)
do
	Analytics.report("soloA", "match_start", "solo0", "world")
	Analytics.report("soloB", "match_start", "solo1", "world")
	Analytics.report("soloC", "match_start", "solo2", "world")
	Analytics.report("soloC", "eliminated", 3, "nation", 2)
	Analytics.report("idleD", "title")
	local p = Analytics.presence({ "soloA", "soloB", "soloC", "idleD", "neverReported" })
	expect(
		p.players == 5 and p.solo == 2 and p.solo_easy == 1 and p.solo_medium == 1 and p.solo_hard == 0 and p.title == 3,
		"presence: 2 in solo matches (an eliminated one is not), 3 elsewhere"
	)
end

-- the takeover funnel
do
	local P = "taker"
	Analytics.report(P, "match_start", "solo0", "world")
	Analytics.report(P, "eliminated", 4, "nation", 3)
	Analytics.report(P, "takeover_offer")
	expect(log[#log][3] == "Takeover Offered" and log[#log][5] == "Solo Easy", "takeover offered (mode kept after the elimination)")
	Analytics.report(P, "takeover_click")
	Analytics.report(P, "credit_bought", "takeover")
	Analytics.report(P, "credit_used", "takeover")
	expect(log[#log - 2][3] == "Takeover Clicked" and log[#log - 1][3] == "Takeover Bought" and log[#log][3] == "Takeover Used", "clicked, bought, used")
	local n = #log
	Analytics.report(P, "credit_used", "something_else")
	expect(#log == n, "other kinds log nothing yet")
end

-- humans per public match: one event per match start
do
	Analytics.public_start("host1", 12, 30, false)
	local e = log[#log]
	expect(e[3] == "Public Match Humans" and e[4] == 12 and e[5] == "10-19" and e[6] == "30 slots" and e[7] == "Timer", "public match start: 12 humans of 30, timer")
	Analytics.public_start("host2", 3, 50, true)
	e = log[#log]
	expect(e[4] == 3 and e[5] == "2-4" and e[7] == "Vote", "a vote-started match")
	expect(Analytics.humans_band(1) == "1" and Analytics.humans_band(49) == "40-49" and Analytics.humans_band(50) == "50+" and Analytics.humans_band(0) == "0", "human bands")
end

-- ---------------------------------------------------------------------------------------------
-- client
-- ---------------------------------------------------------------------------------------------

local sent = {}
--- the snapshots ("state" reports) go here, the milestones to `sent`
local states = {}
local function state(me: number, map: string)
	local st = {
		tick = 0,
		playing_since = -1,
		local_owner = me,
		map_id = map,
		owners = {
			[1] = { id = 1, kind = Defs.KIND_HUMAN, alive = true, tiles = 0 },
			[2] = { id = 2, kind = Defs.KIND_NATION, alive = true, tiles = 50 },
		},
		attacks = {},
		owner_eliminated = Signal.new(),
		game_over = Signal.new(),
	}
	function st.ranking(_self)
		return { st.owners[2], st.owners[1] }
	end
	return st
end
local ctx = {
	state = nil,
	state_mode = 1,
	session = {
		difficulty = 2,
		report = function(_s, kind, a, b, c)
			table.insert(if kind == "state" then states else sent, { kind, a, b, c })
			return true
		end,
	},
}
local tel = Telemetry.new(ctx)
local function kinds(): string
	local k = {}
	for _, s in sent do
		table.insert(k, s[1])
	end
	return table.concat(k, ",")
end

do
	tel:title_shown()
	tel:title_shown()
	local st = state(1, "world")
	ctx.state = st
	tel:bind(st)
	tel:tick()
	expect(kinds() == "title,match_start" and sent[2][2] == "solo2" and sent[2][3] == "world", "title once; a Hard solo match on World")
	st.owners[1].tiles = 12
	tel:tick()
	tel:on_intent({ type = "build" })
	tel:on_intent({ type = "attack", tile = 5 })
	tel:on_intent({ type = "attack", tile = 6 })
	expect(kinds() == "title,match_start,spawned,attack", "spawned, then the first attack (once)")
	st.playing_since = 100
	st.tick = 100 + 10 * 61
	tel:tick()
	tel:tick()
	expect(sent[#sent][1] == "alive" and math.abs(sent[#sent][2] - 61 / 60) < 1e-6 and #sent == 5, "one report per whole minute alive")
	st.owners[1].alive = false
	st.owner_eliminated:Fire(1, 2)
	expect(sent[#sent][1] == "eliminated" and sent[#sent][3] == "nation" and sent[#sent][4] == 2, "eliminated by a nation")
	st.game_over:Fire(2, 0)
	expect(sent[#sent][1] == "eliminated", "the end changes nothing after elimination")
	-- back to the title: nothing to close
	local title = state(0, "world")
	ctx.state = title
	ctx.state_mode = 0
	tel:bind(title)
	tel:tick()
	expect(sent[#sent][1] == "eliminated", "back at the title: no report")
end

do
	table.clear(sent)
	local st = state(1, "europe")
	ctx.state = st
	ctx.state_mode = 2
	tel:bind(st)
	tel:tick()
	expect(sent[1][1] == "match_start" and sent[1][2] == "public", "a public match")
	-- a resync: a new state for the same match
	local again = state(1, "europe")
	ctx.state = again
	tel:bind(again)
	tel:tick()
	expect(#sent == 1, "a resync is the same match")
	again.owners[1].tiles = 30
	again.game_over:Fire(1, 0)
	expect(sent[#sent][1] == "over" and sent[#sent][2] == true and sent[#sent][4] == 2, "won (rank 2 by land here)")
end

do
	table.clear(sent)
	local st = state(1, "world")
	ctx.state = st
	ctx.state_mode = 1
	tel:bind(st)
	tel:tick()
	st.playing_since = 0
	st.tick = 10 * 150
	st.owners[1].tiles = 5
	tel:tick()
	local title = state(0, "world")
	ctx.state = title
	ctx.state_mode = 0
	tel:bind(title)
	expect(sent[#sent][1] == "left" and math.abs(sent[#sent][2] - 2.5) < 1e-6, "left after 2.5 min")
end

-- snapshots: what is happening to the player, every STATE_EVERY_S and right before leaving
do
	table.clear(sent)
	table.clear(states)
	local st = state(1, "world")
	ctx.state = st
	ctx.state_mode = 1
	tel:bind(st)
	tel:tick()
	expect(#states == 1 and states[1][2] == "Choosing spawn", "first snapshot at once: choosing a spawn")
	tel:tick()
	expect(#states == 1, "no second snapshot within STATE_EVERY_S")
	st.playing_since = 0
	st.owners[1].tiles = 100
	for _ = 1, 30 do
		tel:frame(1 / 30)
	end
	local m = tel._match
	m.land = { { os.clock(), 100 } }
	m.state_at -= Telemetry.STATE_EVERY_S
	tel:tick()
	local s1 = states[#states]
	expect(s1[2] == "Holding" and s1[3] == "Top 3" and s1[4] == 30, "holding, 2nd of 2 by land (top 3), 30 fps: " .. tostring(s1[2]) .. " " .. tostring(s1[4]))
	st.attacks[5] = { attacker = 2, target = 1, troops = 10, retreating = false }
	m.state_at -= Telemetry.STATE_EVERY_S
	tel:tick()
	expect(states[#states][2] == "Under attack", "an incoming attack: under attack")
	st.attacks[5].retreating = true
	st.owners[1].tiles = 80
	m.land = { { os.clock(), 100 } }
	m.state_at -= Telemetry.STATE_EVERY_S
	tel:tick()
	expect(states[#states][2] == "Losing land", "land down 20 % in the window: losing land")
	st.owners[1].tiles = 80
	m.land = {}
	m.last_intent -= Telemetry.IDLE_S
	m.state_at -= Telemetry.STATE_EVERY_S
	tel:tick()
	expect(states[#states][2] == "Idle", "no intent for a minute: idle")
	tel:on_intent({ type = "attack", tile = 3 })
	st.owners[1].tiles = 200
	st.owners[2].tiles = 10
	m.land = { { os.clock(), 80 } }
	function st.ranking(_self)
		return { st.owners[1], st.owners[2] }
	end
	m.state_at -= Telemetry.STATE_EVERY_S
	tel:tick()
	expect(states[#states][2] == "Growing" and states[#states][3] == "Top 3", "growing, first by land")
	local n = #states
	local title = state(0, "world")
	ctx.state = title
	ctx.state_mode = 0
	tel:bind(title)
	expect(#states == n + 1 and sent[#sent][1] == "left", "leaving to the title: a fresh snapshot, then left")
end

-- ---------------------------------------------------------------------------------------------
-- slow frames: once a match, with what the frame was made of
-- ---------------------------------------------------------------------------------------------
do
	-- the server
	local P = "slowpoke"
	local before = #log
	Analytics.report(P, "slow", "labels", 12, 4)
	expect(#log == before, "slow: nothing without a match")
	Analytics.report(P, "match_start", "solo1", "world")
	before = #log
	Analytics.report(P, "slow", "gremlins", 12, 4)
	Analytics.report(P, "slow", "labels", "soon", 4)
	Analytics.report(P, "slow", "labels", 12, 0 / 0)
	expect(#log == before, "slow: an unknown cause, minutes or frame rate that are no numbers: ignored")
	Analytics.report(P, "slow", "labels", 31.2, 3.4)
	local e = log[#log]
	expect(
		#log == before + 1 and e[3] == "Slow Frames" and e[4] == 3 and e[5] == "Solo Medium" and e[6] == "Script - Labels" and e[7] == "30+ min",
		"Slow Frames: the frame rate, the mode, the cause, how far in"
	)
	Analytics.report(P, "slow", "nukes", 33, 2)
	expect(#log == before + 1, "once a match")
	-- the client's memory, with it
	Analytics.report(P, "slow_mem", "gremlins", 2400)
	Analytics.report(P, "slow_mem", "labels", "lots")
	expect(#log == before + 1, "slow_mem: an unknown cause or no number: ignored")
	Analytics.report(P, "slow_mem", "labels", 2400.4)
	e = log[#log]
	expect(
		#log == before + 2 and e[3] == "Slow Frames Memory" and e[4] == 2400 and e[5] == "Solo Medium" and e[6] == "Script - Labels" and e[7] == "2-3 GB",
		"Slow Frames Memory: the MB, the mode, the cause, the band"
	)
	Analytics.report(P, "slow_mem", "labels", 900)
	expect(#log == before + 2, "once a match too")
	expect(
		Analytics.memory_band(999) == "Under 1 GB" and Analytics.memory_band(1000) == "1-2 GB" and Analytics.memory_band(2999) == "2-3 GB"
			and Analytics.memory_band(3000) == "3-4 GB" and Analytics.memory_band(9000) == "4+ GB",
		"memory bands"
	)
	-- after the player fell (they keep watching), and in the next match
	local P2 = "watcher"
	Analytics.report(P2, "match_start", "public", "world")
	Analytics.report(P2, "eliminated", 6, "nation", 2)
	before = #log
	Analytics.report(P2, "slow", "engine_hi", 22, 5)
	e = log[#log]
	expect(#log == before + 1 and e[5] == "Public" and e[6] == "Engine - Memory 3+ GB" and e[7] == "20-29 min", "a fallen player's slow frames count too (a v71 client's word for the engine)")
	Analytics.report(P2, "match_start", "public", "world")
	before = #log
	Analytics.report(P2, "slow", "nukes", 3, 900)
	e = log[#log]
	expect(#log == before + 1 and e[4] == Analytics.MAX_FPS and e[6] == "Munitions In Flight" and e[7] == "0-4 min", "again in the next match (a frame rate held to MAX_FPS)")
	expect(
		Analytics.minute_band(0) == "0-4 min" and Analytics.minute_band(5) == "5-9 min" and Analytics.minute_band(19.9) == "10-19 min"
			and Analytics.minute_band(20) == "20-29 min" and Analytics.minute_band(30) == "30+ min",
		"minute bands"
	)

	-- the client's word for the cause: every one is a cause the server knows
	local function cause(t)
		local c = Telemetry.slow_cause(t)
		expect(Analytics.SLOW_CAUSES[c] ~= nil, "  (the server knows \"" .. c .. "\")")
		return c
	end
	expect(cause({ frame_ms = 300, nukes = 350, map = { total = 250, units = 240 } }) == "nukes", "a volley in the air is the cause, whatever it costs where")
	expect(cause({ frame_ms = 300, nukes = 3, map = { total = 200, units = 20, labels = 170, territory = 5 } }) == "labels", "our script is most of the frame: its biggest part (labels)")
	expect(cause({ frame_ms = 300, map = { total = 200, units = 160, labels = 20 } }) == "units", "units")
	expect(cause({ frame_ms = 300, map = { total = 200, units = 10, labels = 10, territory = 150 } }) == "territory", "territory")
	expect(cause({ frame_ms = 300, map = { total = 200, units = 10, labels = 10, territory = 10 } }) == "map", "the rest of the map")
	expect(cause({ frame_ms = 300, map = { total = 20 }, hud_ms = 180 }) == "hud", "the HUD")
	expect(cause({ frame_ms = 300, map = { total = 20 }, hud_ms = 5, sim_ms = 190 }) == "sim", "the local Sim")
	expect(cause({ frame_ms = 300, map = { total = 20 }, net_ms = 170, sim_ms = 0 }) == "net", "the server's updates (a public match)")
	expect(cause({ frame_ms = 300, map = { total = 20 }, session_ms = 160 }) == "session", "the rest of the session's step")
	expect(cause({ frame_ms = 300, map = { total = 20 }, ui_ms = 160, hud_ms = 30 }) == "ui", "the HUD's own step")
	expect(cause({ frame_ms = 300, map = { total = 60, units = 50 }, net_ms = 70, ui_ms = 40 }) == "net", "several parts make the half: the biggest is named")
	expect(cause({ frame_ms = 300, map = { total = 20 }, hud_ms = 5, sim_ms = 10, gpu_ms = 240, render_ms = 30 }) == "gpu", "our script is a small part of it and the GPU most: the GPU")
	expect(cause({ frame_ms = 300, map = { total = 20 }, gpu_ms = 20, render_ms = 180 }) == "render", "the engine's render CPU")
	expect(cause({ frame_ms = 300, map = { total = 20 }, gpu_ms = 101, render_ms = 100 }) == "gpu", "a third of the frame is enough, the bigger of the two")
	expect(cause({ frame_ms = 300, map = { total = 20 }, gpu_ms = 60, render_ms = 90 }) == "engine", "neither is a third of the frame: the engine, otherwise")
	expect(cause({ frame_ms = 300, map = { total = 200, labels = 170 }, gpu_ms = 250 }) == "labels", "our script first, whatever the GPU says")
	expect(cause({}) == "engine", "nothing known: the engine")

	-- Roblox refuses a custom field holding , " or ' (and keeps the event with the field empty): no
	-- word this module logs has one, and anything that reaches the service is stripped of them
	local bad = {}
	local function words(t, values_only)
		for k, v in t do
			for _, w in { if values_only then nil else k, v } do
				if type(w) == "string" and string.find(w, "[,\"']") then
					table.insert(bad, w)
				end
			end
		end
	end
	for _, name in { "MODES", "SLOW_CAUSES", "KILLERS", "WHERE", "ARSENAL_FROM", "RARITY_NAMES" } do
		words(Analytics[name], true)
	end
	words(Analytics.SITUATIONS, false)
	words(Analytics.STANDINGS, false)
	words({
		Analytics.fps_band(0), Analytics.fps_band(10), Analytics.fps_band(30), Analytics.fps_band(60),
		Analytics.minute_band(1), Analytics.minute_band(7), Analytics.minute_band(15), Analytics.minute_band(25), Analytics.minute_band(40),
		Analytics.memory_band(500), Analytics.memory_band(1500), Analytics.memory_band(2500), Analytics.memory_band(3500), Analytics.memory_band(5000),
		Analytics.experience(0), Analytics.experience(3), Analytics.experience(9),
		Analytics.humans_band(1), Analytics.humans_band(3), Analytics.humans_band(25), Analytics.humans_band(60),
	}, true)
	expect(#bad == 0, "no custom field's word holds a comma or a quote (" .. table.concat(bad, " / ") .. ")")
	expect(
		Analytics.field("Engine, Memory Under 2 GB") == "Engine Memory Under 2 GB" and Analytics.field([[it's "x"]]) == "its x" and Analytics.field(12) == "12",
		"field(): what reaches the service has none either"
	)

	-- the client: ten slow seconds in a match are reported once
	local st = state(1, "world")
	st.owners[1].tiles = 40
	st.nukes = {}
	local sctx = {
		state = st,
		state_mode = 1,
		world = {
			perf_stats = function(_w)
				return { total = 190, units = 30, labels = 150, territory = 4 }
			end,
		},
		session = { difficulty = 1, perf = { step_s = 0, process_s = 0 }, env = { net = { busy_s = 0 } } },
	}
	local got = {}
	function sctx.session.report(_s, kind, a, b, c)
		table.insert(got, { kind, a, b, c })
		return true
	end
	local function slows()
		local list = {}
		for _, g in got do
			if g[1] == "slow" then
				table.insert(list, g)
			end
		end
		return list
	end
	local t = Telemetry.new(sctx)
	t:bind(st)
	t:tick()
	local function window(frames: number, dt: number)
		for _ = 1, frames do
			t:frame(dt)
		end
		t._slow_at -= Telemetry.SLOW_WINDOW_S
		t:tick()
	end
	-- 3 frames a second, but the match is seconds old
	st.playing_since = 100
	st.tick = 100 + 10 * 5
	window(30, 1 / 3)
	expect(#slows() == 0, "the first seconds of a match are not reported")
	st.tick = 100 + 10 * 60 * 31
	window(600, 1 / 60)
	expect(#slows() == 0, "60 frames a second: nothing")
	t._slow_void = true
	window(30, 1 / 3)
	expect(#slows() == 0, "a window in which the game was not in front does not count")
	t:frame(5.0)
	window(29, 1 / 3)
	expect(#slows() == 0, "nor one with a frame of seconds (the game was set aside)")
	window(30, 1 / 3)
	local sl = slows()
	expect(#sl == 1 and sl[1][2] == "labels" and math.abs(sl[1][3] - 31) < 0.01 and sl[1][4] == 3, "3 frames a second for ten seconds: reported, with the cause, the minute and the rate")
	local mems = 0
	for _, g in got do
		if g[1] == "slow_mem" then
			mems += 1
		end
	end
	expect(mems == 0, "no memory report where the memory can't be read (here)")
	window(30, 1 / 3)
	expect(#slows() == 1, "once a match")
	-- the player falls and keeps watching: a new match would report again, this one does not
	st.owners[1].alive = false
	st.owner_eliminated:Fire(1, 2)
	window(30, 1 / 3)
	expect(#slows() == 1, "still once after falling")

	-- a public match whose updates are the frame: the clocks are read over the window
	local st2 = state(1, "world")
	st2.owners[1].tiles = 40
	st2.nukes = {}
	st2.playing_since = 100
	st2.tick = 100 + 10 * 60 * 3
	sctx.state = st2
	sctx.state_mode = 2
	sctx.world = { perf_stats = function(_w) return { total = 8, units = 3, labels = 3, territory = 1 } end }
	local t2 = Telemetry.new(sctx)
	t2.ui_perf = { process = 0, kit = 0 }
	t2:bind(st2)
	t2:tick()
	got = {}
	-- ten seconds at 5 frames a second (200 ms): 130 ms of each frame in the network handler
	for _ = 1, 50 do
		t2:frame(1 / 5)
	end
	sctx.session.env.net.busy_s += 50 * 0.130
	sctx.session.perf.process_s += 50 * 0.010
	t2.ui_perf.process += 50 * 0.012
	t2._slow_at -= Telemetry.SLOW_WINDOW_S
	t2:tick()
	local s2 = slows()
	expect(#s2 == 1 and s2[1][2] == "net" and s2[1][4] == 5, "a public match at 5 frames a second, most of each in the updates: named so")
end

print(if fails == 0 then "analytics: all passed" else string.format("analytics: %d FAILED", fails))
if fails > 0 then
	error("analytics failed")
end
