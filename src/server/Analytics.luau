--!strict
-- Creator Dashboard analytics (Roblox AnalyticsService): how new players get on. Solo matches run on
-- the client, so the client reports its milestones (OP.ANALYTICS, from client/UI/Telemetry.luau) and
-- this module logs them: known kinds only, each milestone once per match, bounded values. Nothing
-- here affects the game. Events are only recorded in the published game (not in Studio, where they
-- are printed instead) and the dashboard fills in within ~24 h.
--
-- Creator Dashboard → Analytics:
--   Funnels → Onboarding (a player's first session, each step once):
--     1 Joined Game · 2 Title Screen · 3 Match Started · 4 Spawned · 5 First Attack ·
--     6 Survived 3 Min · 7 Survived 10 Min · 8 Second Match
--   Funnels → "Match" (every match played):
--     1 Started · 2 Spawned · 3 First Attack · 4 Survived 3 Min · 5 Survived 10 Min · 6 Reached The End
--   Custom events (CustomField01 = mode, CustomField02 = experience, CustomField03 = detail):
--     Match Start (detail: map) · Match End (value: minutes; detail: result) ·
--     Eliminated (value: minutes alive; detail: who by) · Final Rank (value: rank, alive at the end) ·
--     How To Play (detail: where) · Spectate
--     Crate Shop Opened → Crate Clicked → Crate Bought → Crate Opened (detail: rarity) · Item Equipped
--       (detail: Skin / Flag) (cosmetic crates, Data/Cosmetics)
--     Arsenal Opened (detail: Title / In Match / Locked Unit / Result Screen / Result Offer) → Arsenal Clicked →
--       Arsenal Unlocked (detail: "<Item> for Stars" / "<Item> for Robux") · Stars Earned (value: the
--       Stars a match paid) (the Arsenal, Data/Arsenal; Stars, Data/Stars)
--     Takeover Offered → Takeover Clicked → Takeover Bought → Takeover Used (solo: take over the
--       nation that eliminated you, 25 Robux; each once per match; mode / experience fields)
--     Public Match Humans (one per public match, when it starts; value: humans it started with;
--       CustomField01 = band "1" / "2-4" / "5-9" / "10-19" / "20-29" / "30-39" / "40-49" / "50+",
--       CustomField02 = slots ("30 slots"), CustomField03 = how it started: Vote / Timer). Explore →
--       Custom events → Public Match Humans → Average (daily) is humans per match; the goal is 50.
--     Quit Situation / Left Situation (value: minutes; CustomField02 = what was happening,
--       CustomField03 = land standing) and Quit FPS / Left FPS (value: frame rate; CustomField02 = its
--       band, CustomField03 = experience): the client's last snapshot (Telemetry "state", every 10 s
--       and right before leaving) when a match ends with the player quitting the game / leaving to the
--       title. Situations: Choosing spawn · Not spawned · Under attack · Losing land · Idle · Growing ·
--       Holding · No report (quit before the first snapshot). Standing: Top 3 · Top 10 · Lower · No land.
--     Slow Frames (value: the frame rate; CustomField02 = what the frame was made of, CustomField03 =
--       how far into the match): once a match, the first 10 s a client spends under 12 frames a second
--       with the game's window in front (Telemetry "slow"). Causes: Munitions In Flight (40 or more) ·
--       Script - Units / Labels / Territory / Map Camera / Fallout Glow / Roads / Range Rings /
--       Structures / Map Effects / Fronts / Markers / Map Input / Map Other (the map's layers; until
--       v110 the ones after Territory were all Map Other) / Updates (the server's
--       updates decoded and applied: a public match) / Sim (a solo match's) / Session / HUD / HUD Kit
--       (our own code is half the frame or more; the biggest part) · Engine - GPU / Render CPU (it is
--       not, and the engine's own count of that is a third of the frame or more) · Engine - Other.
--       Break it down by platform in Explore. (Until v73 the updates, the session and the HUD were
--       not counted: an "Engine" of v71 or v72 may be one of them.)
--       (v71 logged the engine's as "Engine, Memory ...": Roblox refuses a field with a comma and
--       kept the event with the field empty. An empty cause on 2026-10-09 is one of those.)
--     Slow Frames Memory (value: the client's memory, MB; CustomField02 = the same cause,
--       CustomField03 = Under 1 GB / 1-2 GB / 2-3 GB / 3-4 GB / 4+ GB): with every Slow Frames.
--   Mode: Solo Easy / Solo Medium / Solo Hard / Public. Experience: the player's matches before this
--   one ("1st match", "2nd-5th match", "6th+ match"; kept in the saved settings' "stats" section).
--   Results: Won · Lost (alive when someone else won) · Eliminated · Left (back to the title) ·
--   Quit Game (left the game mid-match). Killers: Nation · Tribe · Bot Player · Real Player.
--
--   Analytics.configure(deps)   the Roblox services (tests inject fakes)
--   Analytics.joined(player)    PlayerAdded
--   Analytics.report(player, kind, a, b, c)   an OP.ANALYTICS message
--   Analytics.left(player)      PlayerRemoving (an open match ends as "Quit Game")

local Analytics = {}

Analytics.ONBOARDING = {
	"Joined Game",
	"Title Screen",
	"Match Started",
	"Spawned",
	"First Attack",
	"Survived 3 Min",
	"Survived 10 Min",
	"Second Match",
}
Analytics.FUNNEL = "Match"
Analytics.FUNNEL_STEPS = { "Started", "Spawned", "First Attack", "Survived 3 Min", "Survived 10 Min", "Reached The End" }
Analytics.MODES = { solo0 = "Solo Easy", solo1 = "Solo Medium", solo2 = "Solo Hard", public = "Public" }
Analytics.KILLERS = { nation = "Nation", tribe = "Tribe", bot = "Bot Player", human = "Real Player" }
Analytics.WHERE = { title = "Title", match = "In Match" }
Analytics.SITUATIONS = {
	["Choosing spawn"] = true,
	["Not spawned"] = true,
	["Under attack"] = true,
	["Losing land"] = true,
	["Idle"] = true,
	["Growing"] = true,
	["Holding"] = true,
}
Analytics.STANDINGS = { ["Top 3"] = true, ["Top 10"] = true, ["Lower"] = true, ["No land"] = true }
Analytics.MAX_FPS = 240
--- What a slow frame was made of (the client's word, Telemetry.slow_cause).
Analytics.SLOW_CAUSES = {
	nukes = "Munitions In Flight",
	units = "Script - Units",
	labels = "Script - Labels",
	territory = "Script - Territory",
	map = "Script - Map Other",
	-- (2026-10-27: the rest of the map by its parts, Telemetry.MAP_PARTS)
	map_camera = "Script - Map Camera",
	map_glow = "Script - Fallout Glow",
	map_roads = "Script - Roads",
	map_ranges = "Script - Range Rings",
	map_structures = "Script - Structures",
	map_fx = "Script - Map Effects",
	map_fronts = "Script - Fronts",
	map_markers = "Script - Markers",
	map_input = "Script - Map Input",
	hud = "Script - HUD Kit",
	sim = "Script - Sim",
	net = "Script - Updates",
	session = "Script - Session",
	ui = "Script - HUD",
	gpu = "Engine - GPU",
	render = "Engine - Render CPU",
	engine = "Engine - Other",
	-- (v71's clients, until they rejoin, name the engine by the client's memory)
	engine_lo = "Engine - Memory Under 2 GB",
	engine_mid = "Engine - Memory 2-3 GB",
	engine_hi = "Engine - Memory 3+ GB",
}
--- The most memory a client may report (MB).
Analytics.MAX_MEMORY_MB = 65536
--- Where the Arsenal was opened from (the client's word).
Analytics.ARSENAL_FROM = {
	title = "Title",
	match = "In Match",
	locked = "Locked Unit",
	over = "Result Screen",
	--- the result screen's offers (the next unlock, 2x Stars), not its Stars pill
	offer = "Result Offer",
}
Analytics.RARITY_NAMES = { common = "Common", rare = "Rare", epic = "Epic", legendary = "Legendary" }
Analytics.STATS = "stats"
--- Longest match time a report may claim (minutes).
Analytics.MAX_MINUTES = 240
Analytics.MAX_RANK = 1000

type Match = {
	mode: string,
	exp: string,
	map: string,
	key: string,
	steps: { [number]: boolean },
	minutes: number,
	ended: boolean,
	snap: { situation: string, standing: string, fps: number }?,
	slow: boolean?,
	slow_mem: boolean?,
}
type Entry = { onboarding: { [number]: boolean }, match: Match? }
-- (a Match may also carry `tutorial`: the tutorial steps logged for it)

local IS_ROBLOX = typeof(game) == "Instance"
local deps: { [string]: any } = {}
if IS_ROBLOX then
	local AnalyticsService = game:GetService("AnalyticsService")
	local HttpService = game:GetService("HttpService")
	local studio = game:GetService("RunService"):IsStudio()
	local function fields(f: { string }?): any
		if f == nil then
			return nil
		end
		local keys = { Enum.AnalyticsCustomFieldKeys.CustomField01, Enum.AnalyticsCustomFieldKeys.CustomField02, Enum.AnalyticsCustomFieldKeys.CustomField03 }
		local out = {}
		for i, v in f do
			out[keys[i].Name] = Analytics.field(v)
		end
		return out
	end
	deps.onboarding = function(player: Player, step: number, name: string)
		if studio then
			print(string.format("[Analytics] onboarding %d %s (%s)", step, name, player.Name))
			return
		end
		AnalyticsService:LogOnboardingFunnelStepEvent(player, step, name)
	end
	deps.funnel = function(player: Player, funnel: string, session: string, step: number, name: string, f: { string }?)
		if studio then
			print(string.format("[Analytics] funnel %s %d %s [%s]", funnel, step, name, table.concat(f or {}, ", ")))
			return
		end
		AnalyticsService:LogFunnelStepEvent(player, funnel, session, step, name, fields(f))
	end
	deps.custom = function(player: Player, name: string, value: number, f: { string }?)
		if studio then
			print(string.format("[Analytics] event %s = %s [%s]", name, tostring(value), table.concat(f or {}, ", ")))
			return
		end
		AnalyticsService:LogCustomEvent(player, name, value, fields(f))
	end
	deps.guid = function(): string
		return HttpService:GenerateGUID(false)
	end
	deps.warn = warn
end
--- Set by ServerMain: load_stats(player, fn(stats?)), save_stats(player, stats), and on a match server
--- classify(owner_id) -> "bot" | "human" | "nation" | "tribe" | nil (the client can't tell bot players).

local entries: { [any]: Entry } = {}

function Analytics.configure(d: { [string]: any })
	for k, v in d do
		deps[k] = v
	end
end

--- Tests: forget everyone.
function Analytics.reset()
	table.clear(entries)
end

local function entry(player: any): Entry
	local e = entries[player]
	if e == nil then
		e = { onboarding = {}, match = nil }
		entries[player] = e
	end
	return e
end

local function call(fn: any, ...: any)
	if fn == nil then
		return
	end
	local ok, err = pcall(fn, ...)
	if not ok and deps.warn then
		deps.warn("[Analytics] " .. tostring(err))
	end
end

Analytics.HUMAN_BANDS = {
	{ 1, 1, "1" },
	{ 2, 4, "2-4" },
	{ 5, 9, "5-9" },
	{ 10, 19, "10-19" },
	{ 20, 29, "20-29" },
	{ 30, 39, "30-39" },
	{ 40, 49, "40-49" },
}

function Analytics.humans_band(n: number): string
	for _, b in Analytics.HUMAN_BANDS do
		if n >= b[1] and n <= b[2] then
			return b[3]
		end
	end
	return if n >= 50 then "50+" else "0"
end

--- A public match started with `humans` real players in `slots` (bots fill the rest). Logged once per
--- match, attributed to one player on the server (AnalyticsService needs a player).
function Analytics.public_start(player: any, humans: number, slots: number, voted: boolean)
	local n = math.clamp(math.floor(tonumber(humans) or 0), 0, 1000)
	local s = math.clamp(math.floor(tonumber(slots) or 0), 0, 1000)
	call(deps.custom, player, "Public Match Humans", n, {
		Analytics.humans_band(n),
		string.format("%d slots", s),
		if voted then "Vote" else "Timer",
	})
end

--- A Quick Play join's outcome (docs/lobby-service.md "Quick Play"), on the hub: `result` "Seated" |
--- "Left Line" | "Timed Out" | "Teleport Failed" | "Unreachable", the value the seconds from asking
--- to that outcome; fields: the result, the kind, how long it took ("First Try" when the first ask
--- found a seat).
function Analytics.public_join(player: any, result: string, mode: string, wait_s: number, first_try: boolean)
	local w = math.clamp(tonumber(wait_s) or 0, 0, 3600)
	local band = if first_try
		then "First Try"
		elseif w < 10 then "Under 10 s"
		elseif w < 30 then "10-30 s"
		elseif w < 60 then "30-60 s"
		else "Over 60 s"
	call(deps.custom, player, "Public Join", math.floor(w * 10 + 0.5) / 10, {
		result,
		if mode == "team" then "Team" elseif mode == "ffa" then "Free For All" elseif mode == "world" then "World" else "Any",
		band,
	})
end

--- A custom field as AnalyticsService takes it. It refuses a field that holds , " or ' and keeps the
--- event with that field empty: v71's "Engine, Memory Under 2 GB" was refused 461 times in its first
--- hour (2026-10-09), and Studio, where events are only printed, had not shown it.
function Analytics.field(v: any): string
	return (string.gsub(tostring(v), "[,\"']", ""))
end

--- A client's memory (MB) as a band.
function Analytics.memory_band(mb: number): string
	return if mb < 1000
		then "Under 1 GB"
		elseif mb < 2000 then "1-2 GB"
		elseif mb < 3000 then "2-3 GB"
		elseif mb < 4000 then "3-4 GB"
		else "4+ GB"
end

--- How far into a match (minutes) something happened.
function Analytics.minute_band(mins: number): string
	return if mins < 5
		then "0-4 min"
		elseif mins < 10 then "5-9 min"
		elseif mins < 20 then "10-19 min"
		elseif mins < 30 then "20-29 min"
		else "30+ min"
end

--- The frame-rate band of a snapshot.
function Analytics.fps_band(fps: number): string
	if fps <= 0 then
		return "Unknown"
	elseif fps < 20 then
		return "Under 20 fps"
	elseif fps < 40 then
		return "20-39 fps"
	end
	return "40+ fps"
end

function Analytics.experience(matches_before: number): string
	if matches_before <= 0 then
		return "1st match"
	elseif matches_before < 5 then
		return "2nd-5th match"
	end
	return "6th+ match"
end

local function onboard(player: any, e: Entry, step: number)
	if e.onboarding[step] then
		return
	end
	e.onboarding[step] = true
	call(deps.onboarding, player, step, Analytics.ONBOARDING[step])
end

local function funnel(player: any, m: Match, step: number)
	if m.steps[step] then
		return
	end
	m.steps[step] = true
	call(deps.funnel, player, Analytics.FUNNEL, m.key, step, Analytics.FUNNEL_STEPS[step], { m.mode, m.exp })
end

local function custom(player: any, name: string, value: number, m: Match?, detail: string?)
	local f = { if m then m.mode else "None", if m then m.exp else "Unknown" }
	if detail ~= nil then
		table.insert(f, detail)
	end
	call(deps.custom, player, name, value, f)
end

local function minutes(v: any): number?
	local n = tonumber(v)
	if n == nil or n ~= n then
		return nil
	end
	return math.floor(math.clamp(n, 0, Analytics.MAX_MINUTES) * 10 + 0.5) / 10
end

local function end_match(player: any, e: Entry, result: string, mins: number?)
	local m = e.match
	if m == nil or m.ended then
		return
	end
	m.ended = true
	if mins ~= nil and mins > m.minutes then
		m.minutes = mins
	end
	custom(player, "Match End", m.minutes, m, result)
	if result == "Quit Game" or result == "Left" then
		-- what was going on when they gave up (the client's last snapshot)
		local pre = if result == "Quit Game" then "Quit" else "Left"
		local snap = m.snap or { situation = "No report", standing = "No land", fps = 0 }
		call(deps.custom, player, pre .. " Situation", m.minutes, { m.mode, snap.situation, snap.standing })
		call(deps.custom, player, pre .. " FPS", snap.fps, { m.mode, Analytics.fps_band(snap.fps), m.exp })
	end
end

function Analytics.joined(player: any)
	onboard(player, entry(player), 1)
end

--- A client's report. Kinds: "title" · "match_start" (mode, map) · "spawned" · "attack" ·
--- "alive" (minutes) · "eliminated" (minutes, killer kind, killer id) · "over" (won, minutes, rank) ·
--- "state" (situation, standing, fps) · "slow" (cause, minutes, fps) · "slow_mem" (cause, MB) ·
--- "left" (minutes) · "help" (where) · "spectate" ·
--- "takeover_offer" · "takeover_click" (client) · "credit_bought" / "credit_used" (kind; the server) ·
--- "starter" ("shown" / "bought": the server; "opened" / "clicked": the client) ·
--- "general" ("opened" (where) / "clicked" / "prompt_done": the client; "subscribed": the server) ·
--- "flag_shop" ("opened" / "clicked" <key> / "clicked_pack" <set>: the client; "bought" <key> <Robux
--- spent> / "bought_pack" <set> <Robux spent>: the server).
function Analytics.report(player: any, kind: any, a: any, b: any, c: any)
	if type(kind) ~= "string" then
		return
	end
	local e = entry(player)
	local m = e.match
	local open = m ~= nil and not m.ended
	if kind == "title" then
		onboard(player, e, 2)
	elseif kind == "match_start" then
		local mode = if type(a) == "string" then Analytics.MODES[a] else nil
		if mode == nil then
			return
		end
		local map = if type(b) == "string" and #b <= 40 and string.match(b, "^[%w_@%-]+$") then b else "unknown"
		if open then
			end_match(player, e, "Left")
		end
		local nm: Match = {
			mode = mode,
			exp = "Unknown",
			map = map,
			key = if deps.guid then deps.guid() else tostring(os.clock()),
			steps = {},
			minutes = 0,
			ended = false,
		}
		e.match = nm
		onboard(player, e, 3)
		local function with_stats(stats: any)
			local n = if type(stats) == "table" then tonumber(stats.matches) or 0 else 0
			nm.exp = Analytics.experience(n)
			call(deps.save_stats, player, { matches = math.min(n + 1, 1000000) })
			if n >= 1 then
				onboard(player, e, 8)
			end
			funnel(player, nm, 1)
			custom(player, "Match Start", 1, nm, nm.map)
		end
		if deps.load_stats then
			call(deps.load_stats, player, with_stats)
		else
			with_stats(nil)
		end
	elseif kind == "spawned" then
		if open then
			onboard(player, e, 4)
			funnel(player, m :: Match, 2)
		end
	elseif kind == "attack" then
		if open then
			onboard(player, e, 5)
			funnel(player, m :: Match, 3)
		end
	elseif kind == "alive" then
		local mins = minutes(a)
		if not open or mins == nil then
			return
		end
		local mm = m :: Match
		if mins > mm.minutes then
			mm.minutes = mins
		end
		if mm.minutes >= 3 then
			onboard(player, e, 6)
			funnel(player, mm, 4)
		end
		if mm.minutes >= 10 then
			onboard(player, e, 7)
			funnel(player, mm, 5)
		end
	elseif kind == "eliminated" then
		if not open then
			return
		end
		local mins = minutes(a) or (m :: Match).minutes
		local killer = nil
		local id = tonumber(c)
		if id ~= nil and deps.classify then
			local ok, k = pcall(deps.classify, id)
			if ok and type(k) == "string" then
				killer = Analytics.KILLERS[k]
			end
		end
		if killer == nil then
			-- the client only knows nation / tribe / player (bot players look like players)
			killer = if b == "nation" or b == "tribe" then Analytics.KILLERS[b] else "Unknown"
		end
		custom(player, "Eliminated", mins, m, killer)
		end_match(player, e, "Eliminated", mins)
	elseif kind == "over" then
		if not open then
			return
		end
		funnel(player, m :: Match, 6)
		local rank = tonumber(c)
		if rank ~= nil and rank >= 1 and rank <= Analytics.MAX_RANK then
			custom(player, "Final Rank", math.floor(rank), m)
		end
		end_match(player, e, if a == true then "Won" else "Lost", minutes(b))
	elseif kind == "state" then
		if not open or not Analytics.SITUATIONS[a] or not Analytics.STANDINGS[b] then
			return
		end
		local fps = tonumber(c) or 0
		if fps ~= fps then
			fps = 0
		end
		local mm = m :: Match
		mm.snap = {
			situation = a,
			standing = b,
			fps = math.floor(math.clamp(fps, 0, Analytics.MAX_FPS)),
		}
	elseif kind == "slow" then
		-- (once a match, and after its end too: a player who keeps watching is still playing the game)
		local cause = if type(a) == "string" then Analytics.SLOW_CAUSES[a] else nil
		local mins = minutes(b)
		local fps = tonumber(c)
		if m == nil or m.slow or cause == nil or mins == nil or fps == nil or fps ~= fps then
			return
		end
		m.slow = true
		call(deps.custom, player, "Slow Frames", math.floor(math.clamp(fps, 0, Analytics.MAX_FPS)), {
			m.mode,
			cause,
			Analytics.minute_band(mins),
		})
	elseif kind == "slow_mem" then
		-- (with "slow": the client's memory while its frames were slow)
		local cause = if type(a) == "string" then Analytics.SLOW_CAUSES[a] else nil
		local mb = tonumber(b)
		if m == nil or m.slow_mem or cause == nil or mb == nil or mb ~= mb then
			return
		end
		m.slow_mem = true
		local held = math.floor(math.clamp(mb, 0, Analytics.MAX_MEMORY_MB))
		call(deps.custom, player, "Slow Frames Memory", held, { m.mode, cause, Analytics.memory_band(held) })
	elseif kind == "left" then
		if open then
			end_match(player, e, "Left", minutes(a))
		end
	elseif kind == "help" then
		custom(player, "How To Play", 1, if open then m else nil, if type(a) == "string" then Analytics.WHERE[a] else nil)
	elseif kind == "spectate" then
		custom(player, "Spectate", 1, nil)
	elseif kind == "takeover_offer" or kind == "takeover_click" then
		-- the solo takeover offer (client, once per match each): shown, then pressed
		custom(player, if kind == "takeover_offer" then "Takeover Offered" else "Takeover Clicked", 1, m)
	elseif kind == "credit_bought" or kind == "credit_used" then
		-- (the server: a receipt stored / a credit spent; b: how many it stored, the 3-crate pack 3)
		if a == "takeover" then
			custom(player, if kind == "credit_bought" then "Takeover Bought" else "Takeover Used", 1, m)
		elseif a == "crate" and kind == "credit_bought" then
			local n = math.clamp(math.floor(tonumber(b) or 1), 1, 10)
			custom(player, "Crate Bought", n, nil, if n > 1 then "Pack of " .. n else "Single")
		end
	elseif kind == "crate_shop" or kind == "crate_click" then
		-- the crate screen opened / its buy button pressed (client, once per visit each)
		custom(player, if kind == "crate_shop" then "Crate Shop Opened" else "Crate Clicked", 1, nil)
	elseif kind == "crate_opened" then
		-- (the server) detail: the item's rarity
		local it = if type(a) == "string" then deps.cosmetic and deps.cosmetic(a) else nil
		custom(player, "Crate Opened", 1, nil, if it then Analytics.RARITY_NAMES[it.rarity] else nil)
	elseif kind == "equipped" then
		custom(player, "Item Equipped", 1, nil, if a == "skin" then "Skin" elseif a == "flag" then "Flag" else nil)
	elseif kind == "tutorial" then
		-- (client) a tutorial step: the "Tutorial" funnel (Data/Tutorial.FUNNEL), each step once a match
		local step = tonumber(a)
		local names = deps.tutorial_steps or {}
		if m == nil or step == nil or names[step] == nil then
			return
		end
		m.tutorial = m.tutorial or {}
		if m.tutorial[step] then
			return
		end
		m.tutorial[step] = true
		call(deps.funnel, player, "Tutorial", m.key, step, names[step], { m.mode, m.exp })
	elseif kind == "tutorial_skip" then
		-- (client) Skip was pressed; detail: the step it was on
		local names = deps.tutorial_steps or {}
		local step = math.clamp(math.floor(tonumber(a) or 1), 1, math.max(#names - 2, 1))
		custom(player, "Tutorial Skipped", 1, m, names[step + 1] or "Unknown")
	elseif kind == "hop" then
		-- (the server) a solo start on an outdated server: Sent to a fresh one / None listed / Failed
		custom(player, "Fresh Server Hop", 1, nil, if a == "sent" then "Sent" elseif a == "none" then "None" else "Failed")
	elseif kind == "arsenal_shop" then
		-- the Arsenal opened (client, once per visit); detail: from where
		custom(player, "Arsenal Opened", 1, if open then m else nil, Analytics.ARSENAL_FROM[a] or "Title")
	elseif kind == "arsenal_view" then
		-- (client) an item's row pressed in the Arsenal, once per item per visit; detail: the item
		local title = if type(a) == "string" and deps.arsenal_title then deps.arsenal_title(a) else nil
		if title ~= nil then
			custom(player, "Arsenal Viewed", 1, if open then m else nil, title)
		end
	elseif kind == "arsenal_click" or kind == "unlocked" then
		-- a buy button pressed (client) / an item unlocked (the server): detail "<Item> for <Stars|Robux>"
		local title = if type(a) == "string" and deps.arsenal_title then deps.arsenal_title(a) else nil
		if title ~= nil then
			local how = if b == "stars" then "Stars" else "Robux"
			custom(
				player,
				if kind == "unlocked" then "Arsenal Unlocked" else "Arsenal Clicked",
				1,
				if open then m else nil,
				title .. " for " .. how
			)
		end
	elseif kind == "starter" then
		-- the starter pack (Data/Starter): "shown" (the server: its clock started, once per player),
		-- "opened" (client: the offer's window, once per visit; b = "auto" | "button"), "clicked"
		-- (client: BUY pressed), "bought" (the server: the receipt granted)
		local names = { shown = "Shown", opened = "Opened", clicked = "Clicked", bought = "Bought" }
		local action = if type(a) == "string" then names[a] else nil
		if action ~= nil then
			custom(player, "Starter Pack", 1, nil, action)
		end
	elseif kind == "general" then
		-- RoWorld General (Data/Subscription; 2026-10-27): "opened" (client: its window; b = where from),
		-- "clicked" (client: SUBSCRIBE pressed), "prompt_done" (client: Roblox's prompt closed after a
		-- try to buy), "subscribed" (the server: Roblox says so, server/General)
		local names = { opened = "Opened", clicked = "Clicked", prompt_done = "Prompt Done", subscribed = "Subscribed" }
		local action = if type(a) == "string" then names[a] else nil
		if action ~= nil then
			custom(player, "General", 1, nil, action)
		end
	elseif kind == "flag_shop" then
		-- the flag shop (Data/Shop): "Flag Shop" Opened (client, once per visit) / Clicked (client, a
		-- flag's buy button) / Bought (the server, the receipt granted); a purchase also logs "Flag
		-- Bought", worth the Robux paid (the receipt's; its set price without one), the flag's name as the
		-- detail (each flag's takings)
		local names = {
			opened = "Opened",
			clicked = "Clicked",
			bought = "Bought",
			clicked_pack = "Clicked Pack",
			bought_pack = "Bought Pack",
		}
		local action = if type(a) == "string" then names[a] else nil
		if action == nil then
			return
		end
		custom(player, "Flag Shop", 1, nil, action)
		local lookup = if a == "bought" then deps.shop_flag elseif a == "bought_pack" then deps.shop_pack else nil
		if lookup ~= nil and type(b) == "string" then
			local name, robux = lookup(b)
			local paid = if type(c) == "number" and c == c and c >= 0 then c else tonumber(robux) or 0
			if name ~= nil then
				custom(player, "Flag Bought", math.floor(paid), nil, name)
			end
		end
	elseif kind == "stars_paid" then
		-- (the server) value: the Stars a match paid
		local n = tonumber(a)
		if n ~= nil and n == n then
			custom(player, "Stars Earned", math.clamp(math.floor(n), 0, 1000000), if m ~= nil then m else nil)
		end
	end
end

--- Who on this server is doing what now, for the lobby service's live stats page (how many people
--- are playing solos, 2026-09-28): players in an unfinished solo match (by difficulty) and the
--- rest (title screen, spectating, between matches). `players` = everyone on the server.
--- True while `player` plays a solo match (a party leader's match does not take them out of it).
function Analytics.in_solo(player: any): boolean
	local e = entries[player]
	local m = if e then e.match else nil
	return m ~= nil and not m.ended and string.sub(m.mode, 1, 5) == "Solo "
end

function Analytics.presence(players: { any }): { [string]: number }
	local out = { players = #players, solo = 0, solo_easy = 0, solo_medium = 0, solo_hard = 0, title = 0 }
	for _, p in players do
		local e = entries[p]
		local m = if e then e.match else nil
		if m ~= nil and not m.ended and string.sub(m.mode, 1, 5) == "Solo " then
			out.solo += 1
			if m.mode == "Solo Easy" then
				out.solo_easy += 1
			elseif m.mode == "Solo Hard" then
				out.solo_hard += 1
			else
				out.solo_medium += 1
			end
		else
			out.title += 1
		end
	end
	return out
end

function Analytics.left(player: any)
	local e = entries[player]
	if e == nil then
		return
	end
	end_match(player, e, "Quit Game")
	entries[player] = nil
end

return Analytics
