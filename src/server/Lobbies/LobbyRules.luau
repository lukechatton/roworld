--!strict
-- Public-lobby rules: pure logic,
-- no services, so it runs in Lune tests and on the server.
--
-- A lobby is one upcoming public match: a map, a player cap, a start time (wall clock, os.time()
-- seconds — every server shares it), and the reserved server that will run it. Hub servers (public
-- servers) list the open lobbies to their players and teleport joiners into the lobby's reserved
-- server; the match server runs a countdown to the start, then fills every empty player slot with a
-- bot player and plays the match.
--   * TARGET_OPEN lobbies are kept open, starting LOBBY_INTERVAL_S apart; each is open for
--     LOBBY_OPEN_S (90 s).
--   * Joining closes JOIN_CLOSE_S before the start (a teleport takes a few seconds).
--   * Maps rotate by the registry's multiplayer_frequency (the playlist weights), never
--     repeating the last RECENT_MAPS maps.
--   * Player cap: 50 per million full-size land tiles x 1.5 (round to 5), clamped to [MIN_PLAYERS,
--     MAX_PLAYERS]: World and larger maps host 50 (and never more than a server holds: max_players).
--   * Kinds: a free-for-all, a team game, and World's own free-for-all (MODE_WORLD, always open).

local LobbyRules = {}

LobbyRules.TARGET_OPEN = 2
--- Public match kinds: every player for itself (a record without `mode`), a team game (Core/Teams), or
--- World's own free-for-all (MODE_WORLD, 2026-10-19: a simple way to queue for a World PvP match, rather
--- than hunting for one among the others and joining matches on maps a player doesn't want; the
--- one map this mode plays is World, always open; it was the Giant World Map's for a day).
--- Its lobbies are always on World (WORLD_ID). The free-for-all rotation no longer plays World: a
--- free-for-all join takes World's seats too (takes_from), so PUBLIC MATCH and WORLD fill the same game
--- when World is the soonest.
LobbyRules.MODE_FFA = "ffa"
LobbyRules.MODE_TEAM = "team"
LobbyRules.MODE_WORLD = "world"
--- Joinable lobbies kept open per kind where team games are on (2026-10-10: one solo public match and
--- one team public match are joinable at all times). Elsewhere: TARGET_OPEN
--- free-for-all lobbies. World's: one, either way.
LobbyRules.TARGETS_WITH_TEAMS = { ffa = 1, team = 1, world = 1 }

--- The kinds of lobby a join of `mode` may seat in, in no order (the soonest that fits wins): a
--- free-for-all join (PUBLIC MATCH, any map) takes World's lobbies too (2026-10-19: the
--- WORLD and PUBLIC MATCH buttons match into the same game when World is the
--- active map); World's join and a team game's take only their own.
function LobbyRules.takes_from(mode: string): { string }
	if mode == LobbyRules.MODE_FFA then
		return { LobbyRules.MODE_FFA, LobbyRules.MODE_WORLD }
	end
	return { mode }
end

--- The kinds of public match offered, in the title's order, and how many joinable lobbies each keeps
--- open at least (more when the demand calls for them: missing_starts).
function LobbyRules.kinds(team_games: boolean?): { { mode: string, target: number } }
	if team_games then
		return {
			{ mode = LobbyRules.MODE_FFA, target = LobbyRules.TARGETS_WITH_TEAMS.ffa },
			{ mode = LobbyRules.MODE_WORLD, target = LobbyRules.TARGETS_WITH_TEAMS.world },
			{ mode = LobbyRules.MODE_TEAM, target = LobbyRules.TARGETS_WITH_TEAMS.team },
		}
	end
	return {
		{ mode = LobbyRules.MODE_FFA, target = LobbyRules.TARGET_OPEN },
		{ mode = LobbyRules.MODE_WORLD, target = LobbyRules.TARGETS_WITH_TEAMS.world },
	}
end
--- Public matches play their map at this % of its width and height (the full-size maps felt huge,
--- 2026-09-27); tribes scale with the area (Sim.default_tribes).
LobbyRules.MAP_SCALE_PCT = 80
--- (it was 2 minutes: players left long waits, so on 2026-09-27 the start
--- timers were lowered to 90 seconds. A new lobby starts at least MIN_LEAD_S out, one every
--- LOBBY_INTERVAL_S: every listed match starts within LOBBY_OPEN_S.)
LobbyRules.LOBBY_OPEN_S = 90
LobbyRules.LOBBY_INTERVAL_S = 45
LobbyRules.MIN_LEAD_S = 45
--- World's lobbies keep this far from the free-for-alls' starts (missing_starts `avoid`): the two kinds
--- kept the same schedule (each LOBBY_INTERVAL_S after its last), so their lobbies started on the same
--- second and PUBLIC MATCH, which takes World's seats when World's lobby is the sooner (takes_from),
--- never was. Half an interval apart, the soonest alternates.
LobbyRules.WORLD_STAGGER_S = 22
LobbyRules.JOIN_CLOSE_S = 6
LobbyRules.RECENT_MAPS = 3
LobbyRules.MIN_PLAYERS = 10
LobbyRules.MAX_PLAYERS = 50
LobbyRules.PLAYERS_PER_MILLION_LAND = 50 * 1.5
--- A lobby record lives this long past its start (the match server reads it on boot).
LobbyRules.RECORD_TTL_AFTER_START_S = 15 * 60
--- A running match's server refreshes its record (`beat`) this often; hubs list it as live (to watch)
--- only while the last beat is recent, so a crashed match server drops off the lists.
LobbyRules.LIVE_BEAT_S = 30
LobbyRules.LIVE_STALE_S = 100
--- Running matches listed to watch at most (most players first; the phone list shows them all).
LobbyRules.MAX_LIVE_LISTED = 8

export type Lobby = {
	id: string,
	map: string,
	map_name: string,
	max: number,
	starts: number, -- os.time() seconds
	created: number,
	players: number, -- humans in (or on their way to) the match server
	status: string, -- "open" | "started" | "closed"
	beat: number?, -- os.time() of the running match's last heartbeat
	code: string?, -- reserved-server access code (server-only; never sent to clients)
	psid: string?, -- reserved server's PrivateServerId
	mode: string?, -- MODE_TEAM for a team game, MODE_WORLD for World's own; nil: free for all
	teams: any?, -- a team game's teams: a number of teams, or Teams.DUOS / TRIOS / QUADS / HVN
	seats: { [string]: number }?, -- the seat ledger: user id -> when its seat was taken (take)
}

-- ---------------------------------------------------------------------------------------------
-- Seats (Quick Play, 2026-10-11)
-- ---------------------------------------------------------------------------------------------
-- 2026-10-11 (10k players): public matches had become too hard to get into, as they filled so
-- fast. One joinable lobby per kind filled in ~8 s, and a player clicked a card
-- the hub had listed up to ~5 s before. Now a player asks for a public match of a kind and the store
-- seats them in the soonest lobby of that kind with room, in one step (`take`); with no room
-- anywhere they wait in line on their hub until a seat is free. A lobby record keeps who holds its
-- seats (`seats`), so a seat whose player never arrives, or leaves the waiting room, is given back.

--- Seat-ledger entries a record keeps at most (the lobby service's MAX_SEATS).
LobbyRules.MAX_SEATS = 60
--- A seat whose player has not reached the match server this long after taking it is given back
--- (a teleport that failed after it began, a player who quit on the way).
LobbyRules.ARRIVE_S = 30

--- What `take` asks for: `n` seats for `uids` in the soonest open lobby of one of `modes` (takes_from
--- `mode`) with room that still takes joins (`close_before`) and was not written with a wrong clock
--- (`start_before`); `id`: only that lobby; `candidates`: lobby ids to try in order, for stores that
--- can't search (MemoryStore, the local store).
export type TakeSpec = {
	mode: string,
	modes: { string },
	n: number,
	uids: { string },
	at: number,
	close_before: number,
	start_before: number,
	id: string?,
	candidates: { string }?,
}

function LobbyRules.take_spec(mode: string, n: number, uids: { string }, now: number, id: string?): TakeSpec
	return {
		mode = mode,
		modes = LobbyRules.takes_from(mode),
		n = n,
		uids = uids,
		at = now,
		close_before = now + LobbyRules.JOIN_CLOSE_S,
		start_before = now + LobbyRules.MAX_AHEAD_S,
		id = id,
	}
end

--- True when `l` can seat what `spec` asks for (the service's take compares the same).
function LobbyRules.fits(l: Lobby, spec: TakeSpec): boolean
	return l.status == "open"
		and table.find(spec.modes or { spec.mode }, LobbyRules.mode_of(l)) ~= nil
		and l.starts > spec.close_before
		and l.starts <= spec.start_before
		and l.players + spec.n <= l.max
		and (spec.id == nil or spec.id == l.id)
end

--- `l` with `spec`'s seats taken (a new table; `l` is left as it was).
function LobbyRules.seated(l: Lobby, spec: TakeSpec): Lobby
	local c = table.clone(l)
	local seats = if l.seats ~= nil then table.clone(l.seats) else {}
	local count = 0
	for _ in seats do
		count += 1
	end
	for _, u in spec.uids do
		if seats[u] == nil and count < LobbyRules.MAX_SEATS then
			seats[u] = spec.at
			count += 1
		end
	end
	c.players += spec.n
	c.seats = seats
	return c
end

--- `l` with the seats of `uids` given back (only seats in its ledger, and only while open): the new
--- record and how many went back (0: unchanged).
function LobbyRules.released(l: Lobby, uids: { string }): (Lobby, number)
	if l.status ~= "open" or l.seats == nil then
		return l, 0
	end
	local seats = table.clone(l.seats)
	local n = 0
	for _, u in uids do
		if seats[u] ~= nil then
			seats[u] = nil
			n += 1
		end
	end
	if n == 0 then
		return l, 0
	end
	local c = table.clone(l)
	c.seats = seats
	c.players = math.max(0, l.players - n)
	return c, n
end

--- Seats of a waiting lobby to give back (MatchHost, before the start): of `l`'s ledger, those whose
--- player arrived and has left (`arrived` but not `present`), and those whose player has not arrived
--- ARRIVE_S after taking the seat.
function LobbyRules.lapsed_seats(l: Lobby, present: { [string]: boolean }, arrived: { [string]: boolean }, now: number): { string }
	local out = {}
	for u, at in l.seats or {} do
		if present[u] then
			continue
		end
		if arrived[u] or now - at >= LobbyRules.ARRIVE_S then
			table.insert(out, u)
		end
	end
	table.sort(out)
	return out
end

-- Demand: with more players joining than one lobby holds for long, more lobbies of a kind are kept
-- open, starting one after another, so a free seat is always there to take.

--- Seats taken lately over this many seconds measure the demand for a kind of lobby.
LobbyRules.DEMAND_WINDOW_S = 120
--- Free seats kept open per kind: this many seconds of joins at the measured demand.
LobbyRules.FILL_AHEAD_S = 20
--- Joinable lobbies of one kind at most.
LobbyRules.MAX_OPEN_PER_KIND = 4
--- Lobbies of one kind start at least this far apart (and at most LOBBY_INTERVAL_S).
LobbyRules.MIN_INTERVAL_S = 8

export type Demand = { rate: number, size: number }

--- The demand for `mode` lobbies: `rate` = seats taken a second (the players of the lobbies of that
--- kind made in the last DEMAND_WINDOW_S: seats taken so far while open, the humans who started a
--- started one), `size` = their average size. `window`: seconds the list covers (less when it holds
--- only the latest running matches).
function LobbyRules.demand(list: { Lobby }, now: number, mode: string, window: number?): Demand
	local w = math.clamp(window or LobbyRules.DEMAND_WINDOW_S, 30, LobbyRules.DEMAND_WINDOW_S)
	local seats, sizes, n = 0, 0, 0
	for _, l in list do
		if LobbyRules.mode_of(l) == mode and l.created > now - w and l.created <= now then
			seats += math.min(l.players, l.max)
			sizes += l.max
			n += 1
		end
	end
	return { rate = seats / w, size = if n > 0 then sizes / n else LobbyRules.max_players(nil) }
end

local function round5(n: number): number
	return math.floor(n / 5 + 0.5) * 5
end

--- Player cap for a map with `land_tiles` land tiles at full resolution (`k_lin` = full-size tiles
--- per our tile: our land count * k_lin^2 = the full-size map's) x PLAYERS_PER_MILLION_LAND / 1e6, rounded
--- to 5, 10..50, and at most `server` (the most players a Roblox server of the place holds,
--- Players.MaxPlayers: a seat past it is a "GameFull" teleport).
--- (2026-10-19: up to 50 players a lobby, where the map supports it. It was that
--- count times MAP_SCALE_PCT's area, so 50-player maps hosted 30 (2026-09-27: smaller maps, fewer
--- players). The map is still played at MAP_SCALE_PCT.)
function LobbyRules.max_players(land_tiles: number?, k_lin: number?, server: number?): number
	local full = LobbyRules.MAX_PLAYERS
	if land_tiles ~= nil and land_tiles > 0 then
		local k = k_lin or 1.0
		local src_land = land_tiles * k * k
		full = math.clamp(round5(src_land / 1e6 * LobbyRules.PLAYERS_PER_MILLION_LAND), LobbyRules.MIN_PLAYERS, LobbyRules.MAX_PLAYERS)
	end
	if type(server) == "number" and server >= LobbyRules.MIN_PLAYERS then
		full = math.min(full, math.floor(server))
	end
	return full
end

--- Weighted map pick: entries { id, weight } (weight <= 0 never picked), skipping `recent` ids;
--- `r` in [0, 1). Falls back to any map when every candidate is recent.
function LobbyRules.pick_map(entries: { { id: string, weight: number } }, recent: { string }, r: number): string?
	-- World only waits for one other map (a rotation that has it: the team playlist); every other map
	-- waits out RECENT_MAPS
	local function held(skip_recent: boolean, id: string): boolean
		if not skip_recent then
			return false
		end
		if id == LobbyRules.WORLD_ID then
			return recent[1] == id
		end
		return table.find(recent, id) ~= nil
	end
	local function pick(skip_recent: boolean): string?
		local total = 0.0
		for _, e in entries do
			if e.weight > 0 and not held(skip_recent, e.id) then
				total += e.weight
			end
		end
		if total <= 0 then
			return nil
		end
		local x = r * total
		for _, e in entries do
			if e.weight > 0 and not held(skip_recent, e.id) then
				x -= e.weight
				if x < 0 then
					return e.id
				end
			end
		end
		-- rounding: the last eligible entry
		for i = #entries, 1, -1 do
			local e = entries[i]
			if e.weight > 0 and not held(skip_recent, e.id) then
				return e.id
			end
		end
		return nil
	end
	return pick(true) or pick(false)
end

--- The free-for-all playlist (2026-09-29: fewer odd maps in public matches, and regular World much
--- more common): the playlist weights
--- (multiplayer_frequency), the odd maps (WEIRD_CATEGORIES: fictional, cosmic, arcade) at WEIRD_FACTOR
--- of their weight, and no World: World's own lobby (MODE_WORLD, always open) takes PUBLIC MATCH's seats
--- whenever it is the soonest (takes_from), which is how World stays common (it was weighted to
--- WORLD_SHARE, 40% of this rotation, until 2026-10-19).
LobbyRules.WORLD_ID = "world"
LobbyRules.WEIRD_FACTOR = 0.15
LobbyRules.WEIRD_CATEGORIES = { fictional = true, cosmic = true, arcade = true }

function LobbyRules.public_weights(maps: { any }): { { id: string, weight: number } }
	local out = {}
	for _, m in maps do
		local w = math.max(0, tonumber(m.weight) or 0)
		if m.id ~= LobbyRules.WORLD_ID then
			for _, c in (if type(m.categories) == "table" then m.categories else {}) do
				if LobbyRules.WEIRD_CATEGORIES[c] then
					w *= LobbyRules.WEIRD_FACTOR
					break
				end
			end
			table.insert(out, { id = m.id, weight = w })
		end
	end
	return out
end

--- True while players may still join (open, not full, far enough from the start).
function LobbyRules.joinable(l: Lobby, now: number): boolean
	return l.status == "open" and l.players < l.max and now < l.starts - LobbyRules.JOIN_CLOSE_S
end

--- Start times of the lobbies to create now so that TARGET_OPEN joinable lobbies exist: after the
--- latest joinable start (or now + MIN_LEAD_S), LOBBY_INTERVAL_S apart. Full lobbies don't push the
--- next ones back: when players pour in (1.1k at once, 2026-09-27) a full lobby is replaced at once,
--- so the matches on offer keep up with the players.
--- Never more than LOBBY_OPEN_S out: a start that would land later waits until it fits (a later
--- refresh makes it). Each vote-started or filled lobby used to put its replacement LOBBY_INTERVAL_S
--- after the latest one, and a few in a row marched the schedule out to 4+ minutes (2026-09-28: it
--- should be about 90 seconds at most). The soonest lobby stays joinable meanwhile, and the next one is
--- made by the time it is LOBBY_INTERVAL_S from its start.
--- `mode`, `target`: per kind (team games on). Then a lobby within half LOBBY_INTERVAL_S of its start
--- no longer counts, so the next one is made before it closes (JOIN_CLOSE_S): with one lobby of each
--- kind wanted, there is always one to join (the soonest is listed; the next waits behind it).
--- `demand` (LobbyRules.demand): more lobbies while the free seats of the joinable ones would last
--- less than FILL_AHEAD_S at that rate (MAX_OPEN_PER_KIND at most), each starting about as long after
--- the one before as it takes to fill (MIN_INTERVAL_S..LOBBY_INTERVAL_S). At 10k players a lobby
--- filled in ~8 s and 27% of the time no lobby of a kind had a free seat (2026-10-11).
--- `avoid` (World's: the free-for-alls' starts, made and about to be): on the quiet schedule the first
--- new start that would fall within WORLD_STAGGER_S of one moves to WORLD_STAGGER_S after it (once, and
--- not past LOBBY_OPEN_S), so a schedule that started level (every lobby until 2026-10-19) comes apart.
function LobbyRules.missing_starts(
	open: { Lobby },
	now: number,
	mode: string?,
	target: number?,
	demand: Demand?,
	avoid: { number }?
): { number }
	local joinable = 0
	local free = 0
	local latest = 0
	local want = mode or LobbyRules.MODE_FFA
	local cover = if mode ~= nil then LobbyRules.LOBBY_INTERVAL_S / 2 else 0
	for _, l in open do
		if LobbyRules.mode_of(l) == want and LobbyRules.joinable(l, now) then
			if l.starts - now > cover then
				joinable += 1
				free += l.max - l.players
			end
			if l.starts > latest then
				latest = l.starts
			end
		end
	end
	local base = target or LobbyRules.TARGET_OPEN
	local want_free = 0
	local interval = LobbyRules.LOBBY_INTERVAL_S
	local size = LobbyRules.max_players(nil)
	if demand ~= nil and demand.rate > 0 then
		want_free = demand.rate * LobbyRules.FILL_AHEAD_S
		size = math.max(1, demand.size)
		interval = math.clamp(size / demand.rate, LobbyRules.MIN_INTERVAL_S, LobbyRules.LOBBY_INTERVAL_S)
	end
	local out = {}
	local next_start = math.max(now + LobbyRules.MIN_LEAD_S, latest + interval)
	if avoid ~= nil and interval >= LobbyRules.LOBBY_INTERVAL_S then
		for _, a in avoid do
			if math.abs(next_start - a) < LobbyRules.WORLD_STAGGER_S then
				local moved = a + LobbyRules.WORLD_STAGGER_S
				if moved <= now + LobbyRules.LOBBY_OPEN_S then
					next_start = moved
				end
				break
			end
		end
	end
	while joinable < base or (free < want_free and joinable < math.max(base, LobbyRules.MAX_OPEN_PER_KIND)) do
		if next_start > now + LobbyRules.LOBBY_OPEN_S then
			break
		end
		table.insert(out, next_start)
		joinable += 1
		free += size
		next_start += interval
	end
	return out
end

--- The map id a public match on `map` plays ("world@80").
function LobbyRules.match_map_id(map: string): string
	return if LobbyRules.MAP_SCALE_PCT < 100 then map .. "@" .. LobbyRules.MAP_SCALE_PCT else map
end

--- No lobby is ever scheduled further ahead than this (the open window plus the queue behind it,
--- with slack). A record beyond it was written with a wrong clock: ignored by the hubs, and its match
--- server does not wait past it.
LobbyRules.MAX_AHEAD_S = LobbyRules.LOBBY_OPEN_S + LobbyRules.TARGET_OPEN * LobbyRules.LOBBY_INTERVAL_S + 120

function LobbyRules.plausible(l: Lobby, now: number): boolean
	return l.starts <= now + LobbyRules.MAX_AHEAD_S
end

--- A running match anyone may watch (its server is alive and reachable).
function LobbyRules.watchable(l: Lobby, now: number): boolean
	return l.status == "started" and l.code ~= nil and (l.beat or l.starts) > now - LobbyRules.LIVE_STALE_S
end

--- A lobby's kind (MODE_FFA / MODE_TEAM / MODE_WORLD).
function LobbyRules.mode_of(l: Lobby): string
	return if l.mode == LobbyRules.MODE_TEAM or l.mode == LobbyRules.MODE_WORLD then l.mode else LobbyRules.MODE_FFA
end

--- Is `mode` a kind of public match ("ffa" | "team" | "world")?
function LobbyRules.is_mode(mode: any): boolean
	return mode == LobbyRules.MODE_FFA or mode == LobbyRules.MODE_TEAM or mode == LobbyRules.MODE_WORLD
end

--- What a client sees of a lobby (no access code / server id). Live matches: `live`, `elapsed`.
function LobbyRules.public_view(l: Lobby, now: number): { [string]: any }
	local live = l.status == "started"
	return {
		mode = if l.mode == LobbyRules.MODE_TEAM or l.mode == LobbyRules.MODE_WORLD then l.mode else nil,
		teams = if l.mode == LobbyRules.MODE_TEAM then l.teams else nil,
		id = l.id,
		map = l.map,
		map_name = l.map_name,
		max = l.max,
		players = math.min(l.players, l.max),
		starts_in = math.max(0, l.starts - now),
		joinable = LobbyRules.joinable(l, now),
		live = live,
		elapsed = if live then math.max(0, now - l.starts) else 0,
		watchable = LobbyRules.watchable(l, now),
	}
end

--- Bot players to add at the start so the match has `max` players.
function LobbyRules.bot_fill(max: number, humans: number): number
	return math.max(0, max - humans)
end

--- Sanitises a lobby record read back from a store (anything a client or a stale version could have
--- left malformed); nil when unusable.
function LobbyRules.decode(v: any): Lobby?
	if type(v) ~= "table" then
		return nil
	end
	-- (a team game's size is `slots` in the store: LobbyStore.encode)
	local size = if type(v.max) == "number" then v.max elseif type(v.slots) == "number" then v.slots else nil
	if type(v.id) ~= "string" or type(v.map) ~= "string" or type(v.starts) ~= "number" or size == nil then
		return nil
	end
	-- the seat ledger (an empty one may come back as an array: Roblox writes {} as [])
	local seats = nil
	if type(v.seats) == "table" then
		seats = {}
		local n = 0
		for u, at in v.seats do
			if type(u) == "string" and #u <= 24 and type(at) == "number" and n < LobbyRules.MAX_SEATS then
				seats[u] = at
				n += 1
			end
		end
	end
	return {
		id = v.id,
		map = v.map,
		map_name = if type(v.map_name) == "string" then v.map_name else v.map,
		max = math.clamp(math.floor(size), 1, 200),
		starts = v.starts,
		created = if type(v.created) == "number" then v.created else v.starts,
		players = if type(v.players) == "number" then math.max(0, math.floor(v.players)) else 0,
		status = if v.status == "started" or v.status == "closed" then v.status else "open",
		beat = if type(v.beat) == "number" then v.beat else nil,
		code = if type(v.code) == "string" then v.code else nil,
		psid = if type(v.psid) == "string" then v.psid else nil,
		mode = if v.mode == LobbyRules.MODE_TEAM or v.mode == LobbyRules.MODE_WORLD then v.mode else nil,
		teams = if v.mode == LobbyRules.MODE_TEAM and (type(v.teams) == "number" or type(v.teams) == "string")
			then v.teams
			else nil,
		seats = seats,
	}
end

-- ---------------------------------------------------------------------------------------------
-- Team games (staging only for now)
-- ---------------------------------------------------------------------------------------------

LobbyRules.DUOS = "Duos"
LobbyRules.TRIOS = "Trios"
LobbyRules.QUADS = "Quads"
LobbyRules.HVN = "Humans Vs Nations"
--- Team-count weights (total 100).
LobbyRules.TEAM_COUNT_WEIGHTS = ({
	{ 2, 10 },
	{ 3, 10 },
	{ 4, 10 },
	{ 5, 10 },
	{ 6, 10 },
	{ 7, 10 },
	{ LobbyRules.DUOS, 5 },
	{ LobbyRules.TRIOS, 7.5 },
	{ LobbyRules.QUADS, 7.5 },
	{ LobbyRules.HVN, 20 },
} :: { { any } })
--- Maps made for a number of teams, played with it 3 times in 4.
LobbyRules.SPECIAL_TEAM_COUNT = {
	aegean = 2,
	babelmandebstrait = 2,
	baikal = 2,
	beringsea = 2,
	beringstrait = 2,
	bosphorusstraits = 2,
	caspiansea = 2,
	conakry = 2,
	falklandislands = 2,
	korea = 2,
	madagascar = 2,
	pulicatlake = 2,
	straitofgibraltar = 2,
	straitofhormuz = 2,
	taiwanstrait = 2,
	vietnam = 2,
	gulfofstlawrence = 3,
	irishsea = 3,
	juandefucastrait = 3,
}
LobbyRules.SPECIAL_TEAM_CHANCE = 0.75
--- A map's weight in team games; a map not listed weighs its multiplayer_frequency.
LobbyRules.TEAM_FREQUENCY = {
	babelmandebstrait = 10,
	beringsea = 10,
	beringstrait = 5,
	bosphorusstraits = 10,
	canaryislands = 10,
	caspiansea = 10,
	channelislands = 7,
	conakry = 6,
	falklandislands = 8,
	gulfofstlawrence = 8,
	juandefucastrait = 8,
	korea = 10,
	madagascar = 10,
	straitofgibraltar = 10,
	straitofhormuz = 8,
	taiwanstrait = 10,
	vietnam = 8,
	archipelagosea = 0,
}
--- A team game holds 1.5 times the free-for-all count, up to this many.
LobbyRules.TEAM_PLAYERS_FACTOR = 1.5
LobbyRules.MAX_TEAM_PLAYERS = 30

--- The team playlist's weights: { id, weight } (TEAM_FREQUENCY, else the map's weight).
function LobbyRules.team_weights(maps: { any }): { { id: string, weight: number } }
	local out = {}
	for _, m in maps do
		local f: number? = (LobbyRules.TEAM_FREQUENCY :: { [string]: number })[m.id]
		local w = if f ~= nil then f else math.max(0, tonumber(m.weight) or 0)
		table.insert(out, { id = m.id, weight = w })
	end
	return out
end

--- A team game's teams on `map` (`r1`, `r2` in [0, 1)): the map's own count 3 times in 4, else
--- TEAM_COUNT_WEIGHTS.
function LobbyRules.team_config(map: string, r1: number, r2: number): any
	local special = LobbyRules.SPECIAL_TEAM_COUNT[map]
	if special ~= nil and r1 < LobbyRules.SPECIAL_TEAM_CHANCE then
		return special
	end
	local total = 0
	for _, e in LobbyRules.TEAM_COUNT_WEIGHTS do
		total += e[2] :: number
	end
	local x = r2 * total
	for _, e in LobbyRules.TEAM_COUNT_WEIGHTS do
		x -= e[2] :: number
		if x < 0 then
			return e[1]
		end
	end
	return 2
end

--- A team game's player slots and teams for a map whose free-for-all count is `ffa_slots`:
--- 1.5 times as many (MAX_TEAM_PLAYERS at most), then a multiple
--- of the team size; a number of teams too large for 2 players each becomes as many as fit. Humans
--- Vs Nations: the slots are the humans' half (as many nations join them).
function LobbyRules.team_slots(ffa_slots: number, teams: any): (number, any)
	local p = math.min(LobbyRules.MAX_TEAM_PLAYERS, math.ceil(ffa_slots * LobbyRules.TEAM_PLAYERS_FACTOR))
	if teams == LobbyRules.HVN then
		return math.max(2, p // 2), teams
	end
	local size = if teams == LobbyRules.DUOS then 2 elseif teams == LobbyRules.TRIOS then 3 elseif teams == LobbyRules.QUADS then 4 else nil
	if size ~= nil then
		return math.max(size * 2, p - p % size), teams
	end
	local n = math.max(2, math.floor(tonumber(teams) or 2))
	if p // n < 2 then
		n = math.max(2, p // 2)
	end
	return p - p % n, n
end

return LobbyRules
