--!strict
-- The match side of a public lobby: runs on the lobby's reserved server. Finds its lobby record
-- (by the server's PrivateServerId), keeps the record's player count current while the lobby is
-- open, says when the match starts (the lobby's start time, pushed back while nobody has arrived
-- yet so an early teleport doesn't start an empty match), marks the lobby started (it leaves the
-- joinable lists and shows as live: a heartbeat keeps it watchable while the match runs), and sends
-- everyone back to a hub server after the match (the record goes away).
--
--   deps = {
--     store = LobbyStore,
--     psid = string,                         -- game.PrivateServerId
--     now = function() -> number,            -- os.time()
--     to_hub = function(players) -> (ok, err?),
--     log = function(text)?,
--   }
local LobbyRules = require("./LobbyRules")

local MatchHost = {}
MatchHost.__index = MatchHost

MatchHost.SYNC_S = 3.0
--- Seconds to wait for the first player when the record is not found yet (store lag).
MatchHost.LOOKUP_RETRY_S = 2.0
--- The match waits at least this long after the first human arrives (their client boots).
MatchHost.MIN_WAIT_AFTER_FIRST_S = 8

function MatchHost.new(deps: { [string]: any })
	local self = setmetatable({}, MatchHost)
	self.deps = deps
	self.lobby = nil :: LobbyRules.Lobby?
	self.started = false
	self.finished = false
	self._beat_in = 0.0
	self._first_arrival = nil :: number?
	--- when this server found its lobby record (starts_in never waits past _found_at + MAX_AHEAD_S)
	self._found_at = nil :: number?
	self._sync_in = 0.0
	self._lookup_in = 0.0
	self._present = 0
	--- user ids of the humans here now, and of everyone who has been here (the seat ledger's checks)
	self._present_uids = {} :: { [string]: boolean }
	self._arrived = {} :: { [string]: boolean }
	--- seats given back while the lobby was open (logs)
	self.released = 0
	self._busy = false
	return self
end

function MatchHost._log(self: any, text: string)
	if self.deps.log then
		self.deps.log("[MatchHost] " .. text)
	end
end

--- Find the lobby record (yields). True once known.
function MatchHost.lookup(self: any): boolean
	if self.lobby ~= nil then
		return true
	end
	local ok, v = pcall(self.deps.store.lobby_for_psid, self.deps.psid)
	if ok then
		self.lobby = LobbyRules.decode(v)
	end
	if self.lobby ~= nil then
		self._found_at = self.deps.now()
		self:_log(
			string.format(
				"lobby %s on %s, %d players, starts in %ds",
				self.lobby.id,
				self.lobby.map,
				self.lobby.max,
				self.lobby.starts - self.deps.now()
			)
		)
	end
	return self.lobby ~= nil
end

--- Humans now on this server (the match server reports it; ServerMain calls on arrivals / leaves).
function MatchHost.set_present(self: any, n: number)
	if n > 0 and self._first_arrival == nil then
		self._first_arrival = self.deps.now()
	end
	self._present = n
end

--- Who is here (user ids of the humans who came to play): a seat whose player arrived and left, or
--- never arrived (LobbyRules.ARRIVE_S), is given back while the lobby is open.
function MatchHost.set_roster(self: any, uids: { string })
	local now: { [string]: boolean } = {}
	for _, u in uids do
		now[u] = true
		self._arrived[u] = true
	end
	self._present_uids = now
end

--- Seconds until the match should start (nil while the lobby is unknown).
function MatchHost.starts_in(self: any): number?
	local l = self.lobby
	if l == nil then
		return nil
	end
	local now = self.deps.now()
	local at = l.starts
	-- never wait past the longest a lobby can be scheduled ahead (from when this server found it)
	if self._found_at ~= nil then
		at = math.min(at, self._found_at + LobbyRules.MAX_AHEAD_S)
	end
	if self._first_arrival ~= nil then
		at = math.max(at, self._first_arrival + MatchHost.MIN_WAIT_AFTER_FIRST_S)
	end
	return math.max(0, at - now)
end

--- Per-frame: lookup / sync the record (in a spawned thread; store calls yield).
function MatchHost.tick(self: any, dt: number, spawn: ((() -> ()) -> ())?)
	if self._busy then
		return
	end
	local run: (() -> ())? = nil
	if self.lobby == nil then
		self._lookup_in -= dt
		if self._lookup_in <= 0 then
			self._lookup_in = MatchHost.LOOKUP_RETRY_S
			run = function()
				self:lookup()
			end
		end
	elseif not self.started then
		self._sync_in -= dt
		if self._sync_in <= 0 then
			self._sync_in = MatchHost.SYNC_S
			run = function()
				self:_sync()
			end
		end
	elseif not self.finished then
		self._beat_in -= dt
		if self._beat_in <= 0 then
			self._beat_in = LobbyRules.LIVE_BEAT_S
			run = function()
				self:_beat()
			end
		end
	end
	if run then
		self._busy = true
		local body = run
		local wrapped = function()
			local ok, err = pcall(body)
			if not ok then
				self:_log("sync failed: " .. tostring(err))
			end
			self._busy = false
		end
		if spawn then
			spawn(wrapped)
		else
			wrapped()
		end
	end
end

--- While open: the record's player count is at least the humans present (hubs add reservations for
--- players still in flight; they arrive and become present), and the seats of players who left the
--- waiting room, or never came (a teleport that failed, a player who quit on the way), go back so
--- the hubs seat others in them. Full 30-seat lobbies started with 25.5 humans on average, and only
--- 1% with all 30 (2026-10-11): a seat was only ever added.
function MatchHost._sync(self: any)
	local l = self.lobby
	if l == nil then
		return
	end
	local present = self._present
	local now = self.deps.now()
	local lapsed: { string } = {}
	local new = self.deps.store.update(l.id, function(v: any): any?
		local cur = LobbyRules.decode(v)
		if cur == nil then
			return nil
		end
		lapsed = LobbyRules.lapsed_seats(cur, self._present_uids, self._arrived, now)
		if cur.players >= present then
			return nil
		end
		cur.players = present
		return cur
	end)
	local d = LobbyRules.decode(new)
	if d then
		self.lobby = d
	end
	if #lapsed > 0 and self.deps.store.release ~= nil then
		local after, n = self.deps.store.release(l.id, lapsed)
		n = tonumber(n) or 0
		if n > 0 then
			self.released += n
			self:_log(string.format("gave back %d seat(s) of players who left or never came", n))
			local da = LobbyRules.decode(after)
			if da then
				self.lobby = da
			end
		end
	end
end

--- While the match runs: the record stays fresh (watchable) and shows the humans still here.
function MatchHost._beat(self: any)
	local l = self.lobby
	if l == nil then
		return
	end
	local now = self.deps.now()
	local present = self._present
	self.deps.store.update(l.id, function(v: any): any?
		local cur = LobbyRules.decode(v)
		if cur == nil then
			return nil
		end
		cur.beat = now
		cur.players = present
		return cur
	end)
end

--- The waiting players voted to start: the lobby now starts within `seconds` (hubs stop offering
--- it once joins close). Yields.
function MatchHost.start_early(self: any, seconds: number)
	local l = self.lobby
	if l == nil then
		return
	end
	local at = self.deps.now() + math.ceil(seconds)
	if at >= l.starts then
		return
	end
	l.starts = at
	pcall(self.deps.store.update, l.id, function(v: any): any?
		local cur = LobbyRules.decode(v)
		if cur == nil or cur.status ~= "open" or cur.starts <= at then
			return nil
		end
		cur.starts = at
		return cur
	end)
end

--- The match is over: its record goes (nothing left to watch). Yields.
function MatchHost.finish(self: any)
	if self.finished then
		return
	end
	self.finished = true
	local l = self.lobby
	if l ~= nil then
		pcall(self.deps.store.remove, l.id)
	end
end

--- The match is starting: the lobby leaves the lists (yields). Returns the bot players to add.
function MatchHost.start(self: any, humans: number): number
	self.started = true
	local l = self.lobby
	if l == nil then
		return 0
	end
	pcall(self.deps.store.update, l.id, function(v: any): any?
		local cur = LobbyRules.decode(v)
		if cur == nil then
			return nil
		end
		cur.status = "started"
		cur.players = humans
		cur.beat = self.deps.now()
		return cur
	end)
	local bots = LobbyRules.bot_fill(l.max, humans)
	self:_log(string.format("starting %s with %d humans + %d bot players", l.id, humans, bots))
	return bots
end

--- After the match: everyone back to a hub server.
function MatchHost.return_to_hub(self: any, players: { any }, data: { [string]: any }?): (boolean, string?)
	if #players == 0 then
		return true, nil
	end
	return self.deps.to_hub(players, data)
end

return MatchHost
