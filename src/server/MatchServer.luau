--!strict
-- Port of the server half of scripts/net/session.gd: the shared multiplayer match.
-- LOBBY (countdown after the first player queues) → SPAWN → PLAYING → OVER (results) → LOBBY/IDLE,
-- one Sim, per-tick deltas to participants only, a cached compressed snapshot for late joiners,
-- intent sanitising + rate limits, idle drop between matches.
--
-- Pure logic with injected dependencies so it runs headless in Lune (tests/net_server.luau) and on a
-- Roblox server (ServerMain.luau wires Players/RemoteEvents/Heartbeat). Peers are opaque keys (Player
-- instances on Roblox, tables in tests).
--
--   deps = {
--     make_sim = function(config) -> Sim,          -- Sim.new(WorldMap.get(config.map_id), config)
--     pick_map = function() -> string?,          -- optional: map id of the next match (default
--                                                -- MatchServer.MP_MAP_ID, else the default map)
--     send = function(peer, op, ...),             -- one ordered reliable message to a peer
--     peers = function() -> { peer },             -- connected peers that are listening (lobby info)
--     now_ms = function() -> number,              -- monotonic milliseconds
--     log = function(text)?,
--     seed = function() -> number?,
--     lobby = {                                   -- optional: a public-lobby match server
--       countdown = function() -> number?,        --   seconds to the lobby's start (nil = unknown yet)
--       info = function() -> {map_id, max}?,      --   the lobby's map and player cap
--       on_start = function(humans, voted) -> number, -- bot players to add (fills the empty slots);
--                                                 --   voted: started by the players' vote
--       bot_names = function(n, taken) -> {string},
--       on_over = function(peers),                --   the match is over: send them back to a hub
--       on_closed = function()?,                  --   everyone left mid-match: it is gone
--       on_vote_start = function(seconds)?,       --   the waiting players voted to start early
--     },
--     bot_faces = {number}?,                      -- Roblox user ids: the head shots bot players wear
--   }

-- Roblox: ReplicatedStorage.Airfront.Net; Lune: the source tree.
local Net: any = if (game :: any) ~= nil then (game :: any):GetService("ReplicatedStorage").Airfront.Net else nil
local Protocol = if Net then require(Net.Protocol) else require("../shared/Net/Protocol")
local Coop = if Net then require(Net.Coop) else require("../shared/Net/Coop")
local Cosmetics: any = if Net then require(Net.Parent.Data.Cosmetics) else require("../shared/Data/Cosmetics")
local Stars: any = if Net then require(Net.Parent.Data.Stars) else require("../shared/Data/Stars")


local MatchServer = {}
MatchServer.__index = MatchServer
--- Bot players dress like players (they must look like people): this share wears a flag, this share a
--- skin (Common / Rare ones), picked at the start of the match. Fairly rare, as with people (toned
--- down 2026-09-29: bots wore too many skins and flags at 40% / 20%): about 2-3 flags
--- and a skin among 30 bots.
MatchServer.BOT_FLAG_SHARE = 0.08
MatchServer.BOT_SKIN_SHARE = 0.04

MatchServer.STAGE_IDLE = "idle"
MatchServer.STAGE_LOBBY = "lobby"
MatchServer.STAGE_SPAWN = "spawn"
MatchServer.STAGE_PLAYING = "playing"
MatchServer.STAGE_OVER = "over"

MatchServer.TICK_SEC = 1.0 / 10
MatchServer.LOBBY_COUNTDOWN_SEC = 15.0
MatchServer.REMATCH_COUNTDOWN_SEC = 12.0
MatchServer.RESULTS_SEC = 18.0
--- Once VOTE_SHARE of the waiting players voted to start, the match starts this soon.
MatchServer.VOTE_SHARE = 2 / 3 -- (2026-09-27; was more than half)
MatchServer.VOTE_START_S = 10.0
--- Vote start needs at least this many players waiting (2026-09-26)...
MatchServer.VOTE_MIN_PLAYERS = 2
--- ...except a player who has waited alone in a public match's waiting room this long (2026-09-27).
MatchServer.VOTE_SOLO_AFTER_S = 30.0
--- The last seconds before a public match starts, the bot players that will fill it show up in the
--- waiting room's player list one by one, like players joining (bots look like players; 2026-09-27).
MatchServer.FILL_REVEAL_S = 10.0
--- How the joins spread over that window (fill_schedule): arrivals thicken toward the start (their
--- times follow window * u^(1 / FILL_RAMP)), and now and then someone follows the previous joiner
--- a moment later (FILL_PARTY_CHANCE, FILL_PARTY_GAP_S), like friends joining together.
MatchServer.FILL_RAMP = 1.8
MatchServer.FILL_PARTY_CHANCE = 0.3
MatchServer.FILL_PARTY_GAP_S = { 0.06, 0.45 }
--- Nation difficulty of multiplayer matches. Public games ran Medium nations, but new
--- players were being overrun (2026-09-27): Easy nations; the Sim.SMART_BOTS smart bot players
--- stay Medium, the other bot players are novices.
MatchServer.MP_DIFFICULTY = 0
--- Core/Teams.HVN (a lobby's `teams` for Humans Vs Nations).
MatchServer.HVN = "Humans Vs Nations"
--- Tribes per match (nil: Sim.default_tribes, 400).
MatchServer.MP_TRIBES = nil :: number?
--- Map of the multiplayer matches when deps.pick_map is not given (nil: MapList.DEFAULT).
MatchServer.MP_MAP_ID = nil :: string?
--- (LobbyRules.MAX_PLAYERS: a public lobby seats up to 50 since 2026-10-19; it was 32 over 30-seat lobbies)
MatchServer.MP_MAX_HUMANS = 50
MatchServer.MP_SPAWN_TICKS = 200
MatchServer.MP_TIME_LIMIT_S = 40 * 60
MatchServer.NOTICE_INFO = 0
MatchServer.NOTICE_WARNING = 1
MatchServer.NOTICE_ERROR = 2
MatchServer.MAX_INTENTS_PER_SEC = 30
MatchServer.JOIN_COOLDOWN_MSEC = 2000
--- A peer may ask for a fresh snapshot (RESYNC, after its mirror failed a delta) this often.
MatchServer.RESYNC_COOLDOWN_MSEC = 10000
--- A failing Sim step / encode ends the match after this many failures in a row, or this many in one
--- match (each failure is followed by a snapshot resync of every participant).
MatchServer.MAX_STEP_FAILURES_IN_ROW = 3
MatchServer.MAX_STEP_FAILURES = 10
MatchServer.STEP_FAILED_NOTICE = "The match ran into a problem. You're back at the title screen."
--- Participants idle this long are not carried into the next match.
MatchServer.IDLE_DROP_MSEC = 5 * 60 * 1000
--- Catch-up cap: at most this many ticks are stepped after a server hitch.
MatchServer.MAX_CATCHUP_TICKS = 6
--- Match construction runs as a Coop job with this budget per server frame (never a long hitch
--- for the players already connected, as long as the Core loops call Coop.check()).
MatchServer.BUILD_BUDGET_S = 0.012

-- Wire constants mirrored from Core (kept local so this module has no Sim dependency).
local EV_MSG = 19
local EV_BONUS = 34
local PHASE_PLAYING = 1
local PHASE_OVER = 2

local OP = Protocol.OP
local STAGE_IDLE, STAGE_LOBBY, STAGE_SPAWN, STAGE_PLAYING, STAGE_OVER = "idle", "lobby", "spawn", "playing", "over"

--- `spectator`: watching only (arrived through a hub's Watch): no nation, never counted as a player,
--- gets the snapshot and the public deltas. `voted`: wants the waiting match to start now.
export type Participant = {
	uid: string,
	key: string,
	name: string,
	owner: number,
	active_msec: number,
	spectator: boolean,
	voted: boolean,
}

local function is_private(e: any): number?
	if e[1] == EV_MSG and e[2] ~= -1 then
		return e[2]
	end
	-- gold a player earned at a tile (a train's stop): their own map shows it, nobody else's
	if e[1] == EV_BONUS then
		return e[2]
	end
	return nil
end

function MatchServer.new(deps: { [string]: any })
	local self = setmetatable({}, MatchServer)
	self.deps = deps
	self.lobby_countdown_sec = MatchServer.LOBBY_COUNTDOWN_SEC
	self._stage = STAGE_IDLE
	self._stage_time = 0.0
	self._mp_sim = nil :: any
	self._mp_acc = 0.0
	self._mp_started_msec = 0
	-- peer -> participant; `_order` keeps insertion order (GDScript Dictionary order)
	self._participants = {} :: { [any]: Participant }
	self._order = {} :: { any }
	self._intent_budget = {} :: { [any]: number }
	--- Troops promised to each donation recipient this Sim tick (cap_donation).
	self._donated = {} :: { [any]: number }
	self._last_join_msec = {} :: { [any]: number }
	--- JOINs that arrived inside the cooldown: admitted when it expires instead of being dropped
	--- (a quick "Leave queue" → "Queue" would otherwise strand the client on its queue card).
	self._pending_join = {} :: { [any]: { uid: string, name: string, key: string? } }
	self._last_resync_msec = {} :: { [any]: number }
	self._step_failures_row = 0
	self._step_failures = 0
	self._step_errors_seen = {} :: { [string]: boolean }
	self._resync_all = false
	self._snap_tick = -1
	self._snap = nil :: buffer?
	self._budget_time = 0.0
	self._lobby_broadcast_time = 0.0
	self._closed = false
	--- a public-lobby match that has been played (lobby mode): later joiners go back to a hub
	self._finished = false
	--- ms (now_ms clock) at which a vote-started lobby begins (nil: no vote passed)
	self._vote_start_at = nil :: number?
	--- public waiting room: since when exactly one player is waiting (VOTE_SOLO_AFTER_S)
	self._alone_since = nil :: number?
	--- public waiting room: the bot players shown joining (FILL_REVEAL_S): names, when each shows up
	--- (server msec, ascending), how many show, and the lobby's size
	self._fill = nil :: { names: { string }, at: { number }, shown: number, max: number }?
	self._start_job = nil :: any
	--- Map id of the running match, or of the next one while no match runs (lobby info carries it
	--- so clients can download the map before the snapshot arrives). nil = the default map.
	self._map_id = self:_pick_map()
	-- instrumentation (read by ServerMain / tests)
	self.stats = {
		steps = 0,
		step_ms_total = 0.0,
		step_ms_max = 0.0,
		step_ms = {} :: { number },
		encode_ms_total = 0.0,
		bytes_sent = 0,
		deltas_sent = 0,
		delta_bytes_max = 0,
		snapshots_sent = 0,
		snapshot_bytes = 0,
		intents_ok = 0,
		intents_dropped = 0,
	}
	return self
end

function MatchServer._pick_map(self: any): string?
	local pick = self.deps.pick_map
	if pick ~= nil then
		local ok, id = pcall(pick)
		if ok and type(id) == "string" then
			return id
		end
	end
	return MatchServer.MP_MAP_ID
end

function MatchServer._log(self: any, text: string)
	local log = self.deps.log
	if log then
		log(text)
	end
end

function MatchServer._now(self: any): number
	return self.deps.now_ms()
end

function MatchServer._send(self: any, peer: any, op: number, ...: any)
	self.deps.send(peer, op, ...)
end

function MatchServer.stage(self: any): string
	return self._stage
end

function MatchServer.participant(self: any, peer: any): Participant?
	return self._participants[peer]
end

function MatchServer.participant_count(self: any): number
	return #self._order
end

function MatchServer.sim(self: any): any
	return self._mp_sim
end

-- =============================================================================================
-- Client requests
-- =============================================================================================

--- A peer asks to queue for / join the match. `info = {uid = account id, name = display name}`.
function MatchServer.join(self: any, peer: any, info: { uid: string, name: string, key: string?, spectate: boolean? })
	if self._closed then
		return
	end
	local now = self:_now()
	local last = self._last_join_msec[peer]
	if last ~= nil and now - last < MatchServer.JOIN_COOLDOWN_MSEC then
		if self._participants[peer] == nil then
			self._pending_join[peer] = info
		end
		return
	end
	self._pending_join[peer] = nil
	self._last_join_msec[peer] = now
	if self._participants[peer] ~= nil then
		-- Double-tapped JOIN: already queued or already playing. Nothing to rebuild.
		self:broadcast_lobby()
		return
	end
	local nice = string.gsub(tostring(info.name or ""), "^%s*(.-)%s*$", "%1")
	-- at most 20 characters (UTF-8 safe; invalid UTF-8 is dropped)
	if utf8.len(nice) == nil then
		nice = ""
	else
		local cut = utf8.offset(nice, 21)
		if cut ~= nil then
			nice = string.sub(nice, 1, cut - 1)
		end
	end
	if nice == "" then
		nice = "Commander"
	end
	-- Keyed by account so a dropped player reconnects to their own nation.
	local key = info.key or info.uid
	local spectator = info.spectate == true
	self._participants[peer] = {
		uid = info.uid,
		key = key,
		name = nice,
		owner = 0,
		active_msec = now,
		spectator = spectator,
		voted = false,
	}
	table.insert(self._order, peer)
	self:_log(string.format("[Session] %s joined multiplayer, stage=%s", nice, self._stage))
	if self._finished then
		-- a public match that already ended: straight back to a hub
		local lobby = self.deps.lobby
		if lobby then
			lobby.on_over({ peer })
		end
		return
	end
	if self._stage == STAGE_IDLE then
		if not spectator then
			self:_set_stage(STAGE_LOBBY, self:_lobby_countdown())
		end
	elseif self._stage == STAGE_SPAWN or self._stage == STAGE_PLAYING or (spectator and self._stage == STAGE_OVER) then
		self:_admit(peer)
	end
	self:broadcast_lobby()
end

--- Seconds until the match starts from the lobby stage: the public lobby's own start time on a
--- match server (a long wait while it is still unknown), else the fixed countdown.
function MatchServer._lobby_countdown(self: any): number
	local lobby = self.deps.lobby
	local cd = self.lobby_countdown_sec
	if lobby ~= nil then
		local ok, v = pcall(lobby.countdown)
		cd = if ok and type(v) == "number" then math.max(v, 0.0) else 3600.0
	end
	if self._vote_start_at ~= nil then
		cd = math.min(cd, math.max(0.0, (self._vote_start_at - self:_now()) / 1000.0))
	end
	return cd
end

--- Players waiting in the lobby who voted to start, and how many votes start the match (two thirds
--- of the players here, rounded up; watchers don't vote).
function MatchServer.vote_counts(self: any): (number, number, number)
	local players, votes = 0, 0
	for _, p in self._order do
		local part = self._participants[p]
		if part ~= nil and not part.spectator then
			players += 1
			if part.voted then
				votes += 1
			end
		end
	end
	return votes, math.max(1, math.ceil(players * MatchServer.VOTE_SHARE - 1e-9)), players
end

--- Players needed before a vote can start the match: VOTE_MIN_PLAYERS, or 1 once a player has waited
--- alone in a public waiting room for VOTE_SOLO_AFTER_S.
function MatchServer.vote_min_players(self: any): number
	if self.deps.lobby ~= nil and self._alone_since ~= nil and self:_now() - self._alone_since >= MatchServer.VOTE_SOLO_AFTER_S * 1000 then
		return 1
	end
	return MatchServer.VOTE_MIN_PLAYERS
end

--- A player toggles their vote to start the waiting match early; once VOTE_SHARE of the players
--- here voted (and at least vote_min_players are here), it starts in VOTE_START_S (locked in: later
--- joiners or unvotes don't cancel it).
function MatchServer.vote_start(self: any, peer: any)
	local part = self._participants[peer]
	if part == nil or part.spectator or self._stage ~= STAGE_LOBBY or self._start_job ~= nil then
		return
	end
	part.voted = not part.voted
	self:_check_votes()
	self:broadcast_lobby()
end

function MatchServer._check_votes(self: any)
	if self._vote_start_at ~= nil or self._stage ~= STAGE_LOBBY then
		return
	end
	local votes, need, players = self:vote_counts()
	if players >= self:vote_min_players() and votes >= need then
		self._vote_start_at = self:_now() + MatchServer.VOTE_START_S * 1000
		if self.deps.lobby == nil then
			self._stage_time = math.min(self._stage_time, MatchServer.VOTE_START_S)
		elseif self.deps.lobby.on_vote_start then
			pcall(self.deps.lobby.on_vote_start, MatchServer.VOTE_START_S)
		end
		self:_log(string.format("[Session] %d of %d players voted to start", votes, players))
	end
end

function MatchServer.leave(self: any, peer: any)
	self._pending_join[peer] = nil
	self:_drop_participant(peer)
	-- fewer players waiting: the others' votes may now be enough
	self:_check_votes()
end

--- The peer's mirror failed a delta: resend the full state (rate-limited per peer).
function MatchServer.resync(self: any, peer: any)
	local part = self._participants[peer]
	if self._mp_sim == nil or part == nil or (part.owner == 0 and not part.spectator) then
		return
	end
	local now = self:_now()
	local last = self._last_resync_msec[peer]
	if last ~= nil and now - last < MatchServer.RESYNC_COOLDOWN_MSEC then
		return
	end
	self._last_resync_msec[peer] = now
	self:_log(string.format("[Session] resync requested by %s", part.name))
	self:_send_snapshot(peer)
end

--- A fallen player may take over the AI nation that eliminated them (a paid takeover, Sim.take_over:
--- nations only, so bot players stay indistinguishable from people).
function MatchServer.can_take_over(self: any, peer: any, target: number): boolean
	local sim = self._mp_sim
	local part = self._participants[peer]
	if sim == nil or part == nil or part.owner == 0 or part.spectator or self._stage ~= STAGE_PLAYING then
		return false
	end
	if type(target) ~= "number" or sim.o_killer[part.owner] ~= target then
		return false
	end
	return sim:can_take_over(part.owner, target)
end

--- The takeover itself (after its credit was spent): the peer commands `target` from now on.
function MatchServer.take_over(self: any, peer: any, target: number): boolean
	if not self:can_take_over(peer, target) then
		return false
	end
	local part = self._participants[peer]
	local old = part.owner
	if not self._mp_sim:take_over(old, target) then
		return false
	end
	part.owner = target
	part.active_msec = self:_now()
	-- a new life: its Stars are counted from here (the first life was paid when it fell)
	if self._tracker ~= nil then
		self._tracker:adopt(old, target)
	end
	part.paid = false
	self:_send(peer, OP.OWNER_CHANGED, target)
	-- the nation wears its new commander's cosmetics
	self:_broadcast_cosmetics()
	self:_log(string.format("[Takeover] %s took over %s", part.name, tostring(self._mp_sim.o_name[target])))
	return true
end

--- An encoded intent from a peer (untrusted). Returns true when it reached the Sim.
function MatchServer.intent(self: any, peer: any, payload: any): boolean
	local sim = self._mp_sim
	if sim == nil then
		return false
	end
	local part = self._participants[peer]
	if part == nil or part.owner == 0 then
		return false
	end
	local used = self._intent_budget[peer] or 0
	if used >= MatchServer.MAX_INTENTS_PER_SEC then
		self.stats.intents_dropped += 1
		return false
	end
	self._intent_budget[peer] = used + 1
	local clean = Protocol.decode_intent(payload)
	if clean == nil then
		self.stats.intents_dropped += 1
		return false
	end
	part.active_msec = self:_now()
	if clean.type == "donate" then
		MatchServer.cap_donation(sim, clean, self._donated)
	end
	sim:submit(part.owner, clean)
	self.stats.intents_ok += 1
	return true
end

--- Server-side twin of the UI's donation cap (UIRules.donate_plan): a donation never exceeds what
--- tick already promised it). The Sim itself accepts any amount (that rule stays as it is on
--- purpose), but troops far above the cap make Rules.troop_growth subtract more than the nation
--- original), but troops far above the cap make Rules.troop_growth subtract more than the nation
--- has (review_gameplay R2-8): a huge gift could push a small ally's troops negative.
--- `pending` = {tick = n, [target] = troops promised this tick} (reset when the Sim tick moves).
function MatchServer.cap_donation(sim: any, it: { [string]: any }, pending: { [any]: number }?)
	local target = tonumber(it.target) or 0
	local caps, troops = sim.o_cap, sim.o_troops
	if target <= 0 or type(caps) ~= "table" or type(troops) ~= "table" then
		return
	end
	local cap = tonumber(caps[target]) or 0
	if cap <= 0 then
		return
	end
	local promised = 0
	if pending ~= nil then
		local tick = tonumber(sim.tick) or 0
		if pending.tick ~= tick then
			table.clear(pending)
			pending.tick = tick
		end
		promised = pending[target] or 0
	end
	local room = math.max(0, math.floor(cap - (tonumber(troops[target]) or 0) - promised))
	local amount = math.clamp(tonumber(it.troops) or 0, 0, room)
	it.troops = amount
	if pending ~= nil and amount > 0 then
		pending[target] = promised + amount
	end
end

--- Dispatches one client → server message (after the transport checked `op` is a number).
--- `who = {uid = account key, name = display name}` comes from the trusted server-side Player.
function MatchServer.on_client(self: any, peer: any, who: { uid: string, name: string }, op: number, ...: any)
	-- Someone is at the controls: intents, a (re)queue, or ACTIVE (the client reports user input at
	-- most every 30 s, so a player watching the end of a match is not idle-dropped at the rematch;
	-- session.gd only counted intents).
	local part = self._participants[peer]
	if part ~= nil and (op == OP.INTENT or op == OP.ACTIVE or op == OP.JOIN) then
		part.active_msec = self:_now()
	end
	if op == OP.INTENT then
		self:intent(peer, (...))
	elseif op == OP.JOIN then
		self:join(peer, who)
	elseif op == OP.LEAVE then
		self:leave(peer)
	elseif op == OP.RESYNC then
		self:resync(peer)
	elseif op == OP.VOTE_START then
		self:vote_start(peer)
	end
end

--- The peer's connection went away (Roblox PlayerRemoving).
function MatchServer.peer_disconnected(self: any, peer: any)
	self._pending_join[peer] = nil
	self:_drop_participant(peer)
	self._last_join_msec[peer] = nil
	self._last_resync_msec[peer] = nil
	self:_check_votes()
end

-- =============================================================================================
-- Frame processing
-- =============================================================================================

function MatchServer.process(self: any, delta: number)
	if self._closed then
		return
	end
	self._budget_time += delta
	if self._budget_time >= 1.0 then
		self._budget_time = 0.0
		table.clear(self._intent_budget)
	end
	self._lobby_broadcast_time += delta
	if self._lobby_broadcast_time >= 1.0 then
		self._lobby_broadcast_time = 0.0
		self:broadcast_lobby()
	end
	if next(self._pending_join) ~= nil then
		self:_admit_pending_joins()
	end

	local stage = self._stage
	if stage == STAGE_LOBBY then
		if self.deps.lobby ~= nil and self._start_job == nil then
			self._stage_time = self:_lobby_countdown()
			self:_public_waiting_room()
		else
			self._stage_time -= delta
		end
		if #self._order == 0 then
			self._start_job = nil
			self:_set_stage(STAGE_IDLE, 0.0)
		elseif self._start_job ~= nil then
			self:_continue_start()
		elseif self._stage_time <= 0.0 then
			self:_start_match()
		end
	elseif stage == STAGE_SPAWN or stage == STAGE_PLAYING then
		local tick_sec = MatchServer.TICK_SEC
		self._mp_acc = math.min(self._mp_acc + delta, tick_sec * MatchServer.MAX_CATCHUP_TICKS)
		while self._mp_acc >= tick_sec and self._mp_sim ~= nil do
			self._mp_acc -= tick_sec
			self:_server_step()
		end
	elseif stage == STAGE_OVER then
		self._stage_time -= delta
		if self._stage_time <= 0.0 and self.deps.lobby ~= nil then
			-- a public match is played once: everyone back to a hub
			self._finished = true
			local peers = table.clone(self._order)
			self:_close_match()
			table.clear(self._participants)
			table.clear(self._order)
			self:_set_stage(STAGE_IDLE, 0.0)
			self.deps.lobby.on_over(peers)
			return
		end
		if self._stage_time <= 0.0 then
			self:_close_match()
			self:_drop_idle_participants()
			if #self._order == 0 then
				self:_set_stage(STAGE_IDLE, 0.0)
			else
				self:_set_stage(STAGE_LOBBY, MatchServer.REMATCH_COUNTDOWN_SEC)
			end
		end
	end
end

--- Per frame in a public match's waiting room: the lone-player clock (a vote may pass once it runs
--- out) and the bot players showing up in the last FILL_REVEAL_S.
function MatchServer._public_waiting_room(self: any)
	local _, _, players = self:vote_counts()
	if players == 1 then
		if self._alone_since == nil then
			self._alone_since = self:_now()
		end
		self:_check_votes()
	else
		self._alone_since = nil
	end
	if self._fill == nil and players > 0 and self._stage_time <= MatchServer.FILL_REVEAL_S then
		self:_prepare_fill(players)
	end
	local fill = self._fill
	if fill ~= nil then
		-- (by the server's msec clock: the lobby countdown moves in whole seconds live, which showed
		-- each second's joiners in one burst)
		local now = self:_now()
		local shown = fill.shown
		while shown < #fill.at and fill.at[shown + 1] <= now do
			shown += 1
		end
		if shown ~= fill.shown then
			fill.shown = shown
			self:broadcast_lobby()
		end
	end
end

--- The bot players that will fill the match (their names are kept for it) and when each shows up.
function MatchServer._prepare_fill(self: any, humans: number)
	local lobby = self.deps.lobby
	local ok, info = pcall(lobby.info)
	local max = if ok and type(info) == "table" then tonumber(info.max) else nil
	local fill = { names = {}, at = {}, shown = 0, max = max or 0 }
	self._fill = fill
	if max == nil or max <= humans then
		return
	end
	local taken = {}
	for _, part in self._participants do
		taken[part.name] = true
	end
	local names_ok, names = pcall(lobby.bot_names, max - humans, taken)
	if not names_ok or type(names) ~= "table" then
		return
	end
	fill.names = names
	-- over what is left of the window, the last one just before the start
	local window = math.max(0.0, math.min(MatchServer.FILL_REVEAL_S, self._stage_time) - 0.6)
	local now = self:_now()
	for i, t in MatchServer.fill_schedule(#names, window) do
		fill.at[i] = now + t * 1000
	end
end

--- When each of `n` bot players shows up: seconds from the start of the reveal, ascending, within
--- `window`. Like players piling into a lobby: more of them the closer the start, some arriving in
--- twos and threes a moment apart, irregular gaps. `rand` (0..1) defaults to math.random.
function MatchServer.fill_schedule(n: number, window: number, rand: (() -> number)?): { number }
	local r = rand or math.random
	local t = table.create(n)
	for i = 1, n do
		t[i] = window * r() ^ (1 / MatchServer.FILL_RAMP)
	end
	table.sort(t)
	local gap = MatchServer.FILL_PARTY_GAP_S
	for i = 2, n do
		if r() < MatchServer.FILL_PARTY_CHANCE then
			t[i] = math.min(window, t[i - 1] + gap[1] + r() * (gap[2] - gap[1]))
		end
	end
	table.sort(t)
	return t
end

--- JOINs held back by the cooldown are admitted once it has passed (in arrival order is not needed:
--- each peer has at most one pending JOIN).
function MatchServer._admit_pending_joins(self: any)
	local now = self:_now()
	for peer, info in table.clone(self._pending_join) do
		local last = self._last_join_msec[peer]
		if last == nil or now - last >= MatchServer.JOIN_COOLDOWN_MSEC then
			self._pending_join[peer] = nil
			self:join(peer, info)
		end
	end
end

function MatchServer._start_match(self: any)
	local seed = if self.deps.seed then self.deps.seed() else math.random(0, 2 ^ 31 - 2)
	local config = {
		seed = seed,
		difficulty = MatchServer.MP_DIFFICULTY,
		tribes = MatchServer.MP_TRIBES,
		max_humans = MatchServer.MP_MAX_HUMANS,
		time_limit_s = MatchServer.MP_TIME_LIMIT_S,
		spawn_ticks = MatchServer.MP_SPAWN_TICKS,
		map_id = self._map_id,
	}
	local lobby = self.deps.lobby
	if lobby ~= nil then
		local ok, info = pcall(lobby.info)
		if ok and type(info) == "table" then
			if type(info.map_id) == "string" then
				config.map_id = info.map_id
				self._map_id = info.map_id
			end
			if type(info.max) == "number" then
				config.max_humans = math.max(config.max_humans, info.max)
			end
			-- a team game (Core/Teams; staging only for now): no nations in public team
			-- games, except Humans Vs Nations, which has as many as the match has player slots
			if info.mode == "team" and info.teams ~= nil then
				config.teams = info.teams
				if info.teams == MatchServer.HVN then
					config.nation_limit = if type(info.max) == "number" then info.max else nil
				else
					config.nations = false
				end
			end
		end
	end
	self._stage_time = 0.0
	self._start_job = Coop.job(self.deps.make_sim, config)
	self:_continue_start()
end

function MatchServer._continue_start(self: any)
	local job = self._start_job
	if not job:step(MatchServer.BUILD_BUDGET_S) then
		return
	end
	self._start_job = nil
	local ok, sim_or_err = job.ok, if job.ok then job.result else job.err
	if not ok or sim_or_err == nil then
		-- The match could not be created (should never happen); send everyone back to the title.
		self:_log("[Session] could not start the match: " .. tostring(sim_or_err))
		for _, peer in table.clone(self._order) do
			self:_send(peer, OP.MATCH_CLOSED, "Multiplayer is unavailable right now. Try again in a moment.")
		end
		table.clear(self._participants)
		table.clear(self._order)
		self:_set_stage(STAGE_IDLE, 0.0)
		return
	end
	self._mp_sim = sim_or_err
	--- the match's results, for Stars (Data/Stars)
	-- (a stand-in Sim in tests has no owner tables to follow)
	self._tracker = if type(sim_or_err.o_tiles) == "table" and type(sim_or_err.o_kind) == "table"
		then Stars.Tracker.new(sim_or_err)
		else nil
	self._mp_acc = 0.0
	self._snap_tick = -1
	self._snap = nil
	self._step_failures_row = 0
	self._step_failures = 0
	self._resync_all = false
	self._mp_started_msec = self:_now()
	-- (the players voted to start it, or its timer ran out: reported with the start)
	local voted = self._vote_start_at ~= nil
	self._vote_start_at = nil
	for _, part in self._participants do
		part.voted = false
	end
	self:_set_stage(STAGE_SPAWN, 0.0)
	local now = self:_now()
	-- Every commander's nation first, then ONE snapshot for all of them: each participant's own nation
	-- is in the state it starts from (admitting one by one gave players 2..N a snapshot without their
	-- own row until the next delta, i.e. state_ready / joined_owner fired with local_info() == nil).
	local order = table.clone(self._order)
	local humans = 0
	for _, peer in order do
		local part = self._participants[peer]
		if part and not part.spectator then
			part.owner = 0
			part.active_msec = now
			self:_ensure_owner(peer)
			humans += 1
		end
	end
	-- public lobby: bot players fill every empty slot (after the humans: they take the first colours)
	local lobby = self.deps.lobby
	if lobby ~= nil then
		local ok, n = pcall(lobby.on_start, humans, voted)
		if ok and type(n) == "number" and n > 0 then
			local taken = {}
			for _, peer in order do
				local part = self._participants[peer]
				if part then
					taken[part.name] = true
				end
			end
			-- the names the waiting room showed joining first (minus any a player took since), then more
			local names = {}
			for _, nm in if self._fill ~= nil then self._fill.names else {} do
				if #names < n and not taken[nm] then
					taken[nm] = true
					table.insert(names, nm)
				end
			end
			if #names < n then
				local more_ok, more = pcall(lobby.bot_names, n - #names, taken)
				if more_ok and type(more) == "table" then
					for _, nm in more do
						table.insert(names, nm)
					end
				end
			end
			local bots = self._mp_sim:add_bot_players(n, if #names > 0 then names else nil)
			self:_dress_bots(bots)
			self._snap = nil
			self._snap_tick = -1
			self:_log(string.format("[Session] %d bot players fill the lobby", n))
		end
	end
	self._fill = nil
	-- a team game: the teams, once everyone (bot players too) is in; a party stays together
	local sim = self._mp_sim
	if sim.team_mode and type(sim.assign_teams) == "function" then
		local groups = {}
		for _, peer in order do
			local part = self._participants[peer]
			if part and part.owner ~= 0 then
				groups[part.owner] = self:_party_of(part)
			end
		end
		sim:assign_teams(groups)
		self._snap = nil
		self._snap_tick = -1
		self:_log(string.format("[Session] %d teams: %s", #sim.team_names, table.concat(sim.team_names, ", ")))
	end
	for _, peer in order do
		local part = self._participants[peer]
		if part and (part.owner ~= 0 or part.spectator) then
			self:_send_snapshot(peer)
		end
	end
	self:_log(string.format("[Session] match started with %d commanders", humans))
end

--- Cosmetics for bot players (they look like players: some wear a flag or a skin, like people do, and
--- each has a head shot beside its name like every person: a different one each of deps.bot_faces,
--- Roblox user ids of accounts picked at random: real avatars, 2026-10-04).
function MatchServer._dress_bots(self: any, ids: any)
	self._bot_cosmetics = {}
	if type(ids) ~= "table" then
		return
	end
	local pool = if type(self.deps.bot_faces) == "table" then table.clone(self.deps.bot_faces) else {}
	local function face(): number?
		if #pool == 0 then
			return nil
		end
		local i = math.random(1, #pool)
		local v = pool[i]
		pool[i] = pool[#pool]
		pool[#pool] = nil
		return if type(v) == "number" and v > 0 then v else nil
	end
	local flags, skins = {}, {}
	for _, it in Cosmetics.all() do
		if it.kind == "flag" then
			table.insert(flags, it.id)
		elseif it.rarity == "common" or it.rarity == "rare" then
			table.insert(skins, it.id)
		end
	end
	for _, id in ids do
		local c = {}
		if #flags > 0 and math.random() < MatchServer.BOT_FLAG_SHARE then
			c.flag = flags[math.random(1, #flags)]
		end
		if #skins > 0 and math.random() < MatchServer.BOT_SKIN_SHARE then
			c.skin = skins[math.random(1, #skins)]
		end
		c.face = face()
		if c.flag or c.skin or c.face then
			self._bot_cosmetics[id] = c
		end
	end
end

--- The match's equipped cosmetics: owner id → { skin?, flag?, face? } (people's from
--- deps.cosmetics_of, bot players' from _dress_bots). `face` is a Roblox user id whose head shot goes
--- beside the name: a person's own, a bot player's dealt from deps.bot_faces.
function MatchServer.cosmetics_map(self: any): { [number]: any }
	local map = table.clone(self._bot_cosmetics or {})
	local of = self.deps.cosmetics_of
	for peer, part in self._participants do
		if part.owner ~= 0 then
			local c: any = nil
			if of ~= nil then
				local ok, v = pcall(of, peer)
				c = if ok and type(v) == "table" then v else nil
			end
			local uid = tonumber(part.uid)
			local face = if uid ~= nil and uid > 0 then uid else nil
			local skin, flag = if c ~= nil then c.skin else nil, if c ~= nil then c.flag else nil
			if skin ~= nil or flag ~= nil or face ~= nil then
				map[part.owner] = { skin = skin, flag = flag, face = face }
			end
		end
	end
	return map
end

--- Everyone (and every watcher) gets the whole map again.
function MatchServer._broadcast_cosmetics(self: any)
	if self._mp_sim == nil then
		return
	end
	local map = self:cosmetics_map()
	for _, peer in self._order do
		self:_send(peer, OP.COSMETICS, map)
	end
end

--- The Arsenal a participant plays with (deps.unlocks_of: a Defs.UNLOCK mask; server/Purchases).
function MatchServer._apply_unlocks(self: any, peer: any)
	local sim = self._mp_sim
	local part = self._participants[peer]
	local of = self.deps.unlocks_of
	if sim == nil or part == nil or part.owner == 0 or of == nil or sim.set_unlocks == nil then
		return
	end
	local ok, mask = pcall(of, peer)
	if ok and type(mask) == "number" then
		sim:set_unlocks(part.owner, mask)
	end
end

--- A player unlocked something mid-match: it works from the next tick.
function MatchServer.unlocks_changed(self: any, peer: any)
	self:_apply_unlocks(peer)
end

--- Pays a participant's Stars for the match once (deps.on_result(peer, result): server/Rewards):
--- when their nation falls, when the match ends, or — `left` — when they walk away from it.
function MatchServer._pay(self: any, peer: any, left: boolean)
	local part = self._participants[peer]
	local tracker = self._tracker
	if part == nil or tracker == nil or part.owner == 0 or part.paid or self.deps.on_result == nil then
		return
	end
	part.paid = true
	pcall(self.deps.on_result, peer, tracker:result(part.owner, left))
end

--- The party a participant came with (the hub's teleport data, via the lobby hooks), or nil.
function MatchServer._party_of(self: any, part: any): string?
	local lobby = self.deps.lobby
	if lobby == nil or type(lobby.party_of) ~= "function" or part.uid == nil then
		return nil
	end
	local ok, key = pcall(lobby.party_of, part.uid)
	return if ok and type(key) == "string" then key else nil
end

--- Gives a participant a nation in the running match (or tells them the match is full). A new
--- nation invalidates the cached snapshot, so every snapshot sent contains its receiver's nation.
function MatchServer._ensure_owner(self: any, peer: any): number
	local sim = self._mp_sim
	local part = self._participants[peer]
	if sim == nil or part == nil or part.spectator then
		return 0
	end
	if part.owner == 0 then
		part.owner = sim:add_human(part.key, part.name) or 0
		if part.owner ~= 0 then
			self._snap = nil
			self._snap_tick = -1
			-- a team game already under way: onto its party's team, else the smallest
			if sim.team_mode and type(sim.join_team) == "function" and #sim.team_names > 0 then
				local key = self:_party_of(part)
				local mates = {}
				if key ~= nil then
					for _, other in self._participants do
						if other ~= part and other.owner ~= 0 and self:_party_of(other) == key then
							table.insert(mates, other.owner)
						end
					end
				end
				sim:join_team(part.owner, mates)
			end
			-- the Arsenal the player has unlocked, and their Stars for this match
			self:_apply_unlocks(peer)
			part.paid = false
			if self._tracker ~= nil then
				self._tracker:watch(part.owner)
			end
		else
			self:_send(
				peer,
				OP.NOTICE,
				"This match is full. You'll be placed in the next one.",
				MatchServer.NOTICE_INFO
			)
		end
	end
	return part.owner
end

--- Sends a participant the full state. Snapshots are built at most once per tick (and state) and
--- shared by every admission / resync in that tick.
function MatchServer._send_snapshot(self: any, peer: any)
	local sim = self._mp_sim
	local part = self._participants[peer]
	if sim == nil or part == nil or (part.owner == 0 and not part.spectator) then
		return
	end
	if self._snap_tick ~= sim.tick or self._snap == nil then
		local t0 = os.clock()
		self._snap = Protocol.compress(Protocol.encode_snapshot(sim:snapshot()))
		self._snap_tick = sim.tick
		self.stats.snapshot_ms = (os.clock() - t0) * 1000
	end
	local snap = self._snap :: buffer
	self.stats.snapshots_sent += 1
	self.stats.snapshot_bytes = buffer.len(snap)
	self.stats.bytes_sent += buffer.len(snap)
	self:_send(peer, OP.SNAPSHOT, part.owner, snap)
	-- (outside the Sim: who wears what, for this mirror)
	self:_send(peer, OP.COSMETICS, self:cosmetics_map())
end

--- Adds a participant to the running match and sends them the full state (late join). Joiners added
--- after another snapshot was sent this tick get their OWNER_ADD in the next delta (GameState handles
--- that idempotently).
function MatchServer._admit(self: any, peer: any)
	local part = self._participants[peer]
	-- a spectator watches without a nation; a player gets one (unless the match is full)
	if (part ~= nil and part.spectator) or self:_ensure_owner(peer) ~= 0 then
		self:_send_snapshot(peer)
		-- the others see the newcomer's flag / skin
		self:_broadcast_cosmetics()
	end
end

--- One server tick, guarded: a Sim or encoder error never escapes into the Heartbeat. After a failure
--- every mirror is resynced with a snapshot (a tick whose delta was not sent, or a half-applied step,
--- leaves the clients behind); repeated failures end the match with a notice instead of freezing it.
function MatchServer._server_step(self: any)
	local ok, err = xpcall(self._step_once, debug.traceback, self)
	if ok and self._resync_all then
		ok, err = xpcall(self._resync_everyone, debug.traceback, self)
	end
	if ok then
		self._step_failures_row = 0
		return
	end
	self._step_failures_row += 1
	self._step_failures += 1
	local key = string.match(tostring(err), "^[^\n]*") or "?"
	if not self._step_errors_seen[key] then
		self._step_errors_seen[key] = true
		self:_log("[Session] match step failed: " .. tostring(err))
	end
	if
		self._step_failures_row >= MatchServer.MAX_STEP_FAILURES_IN_ROW
		or self._step_failures >= MatchServer.MAX_STEP_FAILURES
	then
		self:_abort_match(MatchServer.STEP_FAILED_NOTICE)
	else
		self._resync_all = true
	end
end

function MatchServer._resync_everyone(self: any)
	self._resync_all = false
	self._snap = nil
	self._snap_tick = -1
	for _, peer in self._order do
		self:_send_snapshot(peer)
	end
end

--- Ends the running match for good: everyone goes back to the title with `reason`.
function MatchServer._abort_match(self: any, reason: string)
	self:_log(string.format("[Session] match aborted: %s", reason))
	for _, peer in table.clone(self._order) do
		self:_send(peer, OP.MATCH_CLOSED, reason)
	end
	self:_close_match()
	table.clear(self._participants)
	table.clear(self._order)
	table.clear(self._intent_budget)
	self._resync_all = false
	self:_set_stage(STAGE_IDLE, 0.0)
end

function MatchServer._step_once(self: any)
	local sim = self._mp_sim
	local t0 = os.clock()
	local d = sim:step()
	local t1 = os.clock()
	local tracker = self._tracker
	if tracker ~= nil then
		tracker:step(d.ev)
		for _, peer in self._order do
			local part = self._participants[peer]
			if part.owner ~= 0 and not part.paid and tracker:final(part.owner) then
				self:_pay(peer, false)
			end
		end
	end
	local public, privates = Protocol.split_events(d.ev, is_private)
	local shared = Protocol.compress(Protocol.encode_delta(d, public, sim.W))
	local t2 = os.clock()
	local st = self.stats
	local step_ms = (t1 - t0) * 1000
	st.steps += 1
	st.step_ms_total += step_ms
	st.step_ms_max = math.max(st.step_ms_max, step_ms)
	table.insert(st.step_ms, step_ms)
	st.encode_ms_total += (t2 - t1) * 1000
	local shared_len = buffer.len(shared)
	st.delta_bytes_max = math.max(st.delta_bytes_max, shared_len)
	for _, peer in self._order do
		local part = self._participants[peer]
		local owner = part.owner
		if owner ~= 0 or part.spectator then
			local mine = owner ~= 0 and privates and privates[owner]
			if mine then
				local tail = Protocol.encode_tail(mine, sim.W)
				st.bytes_sent += shared_len + buffer.len(tail)
				self:_send(peer, OP.DELTA, shared, tail)
			else
				st.bytes_sent += shared_len
				self:_send(peer, OP.DELTA, shared)
			end
			st.deltas_sent += 1
		end
	end
	if self._stage == STAGE_SPAWN and sim.phase == PHASE_PLAYING then
		self:_set_stage(STAGE_PLAYING, 0.0)
	end
	if sim.phase == PHASE_OVER and self._stage ~= STAGE_OVER then
		self:_set_stage(STAGE_OVER, MatchServer.RESULTS_SEC)
	end
end

function MatchServer._close_match(self: any)
	self._mp_sim = nil
	self._tracker = nil
	self._bot_cosmetics = {}
	self._snap_tick = -1
	self._snap = nil
	for _, part in self._participants do
		part.owner = 0
	end
	-- the next match's map (announced in the lobby info from now on)
	self._map_id = self:_pick_map()
end

--- Players who walked away are not auto-entered into the next match.
function MatchServer._drop_idle_participants(self: any)
	local now = self:_now()
	for _, peer in table.clone(self._order) do
		local part = self._participants[peer]
		if part and now - part.active_msec > MatchServer.IDLE_DROP_MSEC then
			self:_remove(peer)
			self:_send(peer, OP.MATCH_CLOSED, "You were away, so you weren't entered in the next match.")
		end
	end
end

function MatchServer._remove(self: any, peer: any)
	self._participants[peer] = nil
	local i = table.find(self._order, peer)
	if i then
		table.remove(self._order, i)
	end
	self._intent_budget[peer] = nil
end

function MatchServer._drop_participant(self: any, peer: any)
	local part = self._participants[peer]
	if part == nil then
		return
	end
	local owner = part.owner
	-- walking away from a running match: Stars for what was done so far
	self:_pay(peer, true)
	self:_remove(peer)
	if self._mp_sim ~= nil and owner ~= 0 then
		self._mp_sim:remove_human(owner)
	end
	local st = self._stage
	if #self._order == 0 and (st == STAGE_SPAWN or st == STAGE_PLAYING or st == STAGE_OVER) then
		self:_close_match()
		self:_set_stage(STAGE_IDLE, 0.0)
		local lobby = self.deps.lobby
		if lobby ~= nil then
			-- a public match everyone left is over for good (nothing left to watch either)
			self._finished = true
			if lobby.on_closed then
				pcall(lobby.on_closed)
			end
		end
	end
	self:broadcast_lobby()
end

function MatchServer._set_stage(self: any, stage: string, timer: number)
	if stage == STAGE_IDLE or stage == STAGE_LOBBY then
		self._vote_start_at = nil -- a new wait: nobody has voted yet
	end
	if stage ~= STAGE_LOBBY or self._stage ~= STAGE_LOBBY then
		self._alone_since = nil
		if stage ~= STAGE_SPAWN then
			self._fill = nil
		end
	end
	self._stage = stage
	self._stage_time = timer
	self:_log("[Session] stage -> " .. stage)
	self:broadcast_lobby()
end

local function lobby_solo_wait(self: any, voters: number): boolean
	return self.deps.lobby ~= nil and voters == 1 and self._alone_since ~= nil and self._stage == STAGE_LOBBY
end

--- Lobby info for one peer (session.gd _broadcast_lobby's dictionary).
function MatchServer.lobby_info(self: any, peer: any): { [string]: any }
	local names = table.create(#self._order)
	local watchers = 0
	for _, p in self._order do
		local part = self._participants[p]
		if part.spectator then
			watchers += 1
		else
			table.insert(names, part.name)
		end
	end
	local humans = #names
	-- the last seconds: the bot players that will fill the match, as players joining
	local fill = self._fill
	if fill ~= nil and self._stage == STAGE_LOBBY then
		for i = 1, math.min(fill.shown, fill.max - humans) do
			table.insert(names, fill.names[i])
		end
	end
	local me = self._participants[peer]
	local votes, votes_needed, voters = self:vote_counts()
	local vote_min = self:vote_min_players()
	local solo_in = nil
	if lobby_solo_wait(self, voters) then
		solo_in = math.max(0.0, MatchServer.VOTE_SOLO_AFTER_S - (self:_now() - self._alone_since) / 1000.0)
	end
	local elapsed = 0.0
	if self._mp_sim ~= nil then
		elapsed = (self:_now() - self._mp_started_msec) / 1000.0
	end
	local lobby = self.deps.lobby
	local max = nil
	local lobby_map = nil
	local teams = nil
	if lobby ~= nil then
		local ok, info = pcall(lobby.info)
		if ok and type(info) == "table" then
			max = info.max
			lobby_map = info.map_id
			teams = if info.mode == "team" then info.teams else nil
		end
	end
	return {
		available = true,
		-- a team game's teams (a number of teams, "Duos", ...; nil: free for all)
		teams = teams,
		-- "match": a public lobby's own server (clients join at once); "hub": the shared queue
		kind = if lobby ~= nil then "match" else "hub",
		max = max,
		stage = self._stage,
		countdown_s = math.max(self._stage_time, 0.0),
		elapsed_s = elapsed,
		players = names,
		watchers = watchers,
		votes = votes,
		votes_needed = math.max(votes_needed, vote_min),
		vote_players = humans,
		vote_min_players = vote_min,
		--- alone in a public waiting room: seconds until a lone vote may start the match
		vote_solo_in = solo_in,
		voted = me ~= nil and me.voted,
		vote_started = self._vote_start_at ~= nil,
		in_match = me ~= nil,
		spectating = me ~= nil and me.spectator,
		map_id = if self._mp_sim ~= nil then self._mp_sim.map_id else (lobby_map or self._map_id),
	}
end

function MatchServer.broadcast_lobby(self: any)
	if self._closed then
		return
	end
	for _, peer in self.deps.peers() do
		self:_send(peer, OP.LOBBY, self:lobby_info(peer))
	end
end

--- The server is going away (Roblox BindToClose): tell everyone, stop the match.
function MatchServer.shutdown(self: any, reason: string?)
	if self._closed then
		return
	end
	for _, peer in table.clone(self._order) do
		self:_send(peer, OP.MATCH_CLOSED, reason or "The game server is restarting. You're back at the title screen.")
	end
	self:_close_match()
	table.clear(self._participants)
	table.clear(self._order)
	self._stage = STAGE_IDLE
	self._stage_time = 0.0
	self:broadcast_lobby()
	for _, peer in self.deps.peers() do
		local info = self:lobby_info(peer)
		info.available = false
		self:_send(peer, OP.LOBBY, info)
	end
	self._closed = true
end

--- Instrumentation summary since the last call (and resets the window).
function MatchServer.take_stats(self: any): { [string]: number }
	local st = self.stats
	local list = st.step_ms
	table.sort(list)
	local p50 = list[math.max(1, math.floor(#list * 0.5))] or 0
	local p99 = list[math.max(1, math.floor(#list * 0.99))] or 0
	local out = {
		steps = st.steps,
		step_ms_avg = if st.steps > 0 then st.step_ms_total / st.steps else 0,
		step_ms_p50 = p50,
		step_ms_p99 = p99,
		step_ms_max = st.step_ms_max,
		encode_ms_avg = if st.steps > 0 then st.encode_ms_total / st.steps else 0,
		bytes_sent = st.bytes_sent,
		deltas_sent = st.deltas_sent,
		delta_bytes_max = st.delta_bytes_max,
		snapshots_sent = st.snapshots_sent,
		snapshot_bytes = st.snapshot_bytes,
		snapshot_ms = st.snapshot_ms or 0,
		intents_ok = st.intents_ok,
		intents_dropped = st.intents_dropped,
	}
	st.steps, st.step_ms_total, st.step_ms_max, st.encode_ms_total = 0, 0, 0, 0
	st.bytes_sent, st.deltas_sent, st.delta_bytes_max, st.snapshots_sent = 0, 0, 0, 0
	st.intents_ok, st.intents_dropped = 0, 0
	table.clear(list)
	return out
end

return MatchServer
