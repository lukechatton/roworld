--!strict
-- Getting players onto servers that run the newest published version (2026-10-04: a player on an
-- outdated server who starts a solo game is sent to a fresh server, which moves people onto new
-- servers). A server keeps the version it started with: after a publish the old
-- servers stay up until they empty, and Roblox keeps filling them.
--
--   * every hub (a public server) announces its place version when it starts and every ANNOUNCE_S.
--     A hub that hears a higher version than its own is outdated (deps.on_outdated: ServerMain
--     tells its clients);
--   * a hub on the newest version it knows lists itself every LIST_S: its job id, players and room
--     (a shared list whose entries expire after LIST_TTL_S);
--   * an outdated hub, when a player starts a solo match, picks a listed server of the newest
--     version with ROOM seats free, and ServerMain teleports the player there with the solo they
--     asked for (it starts on arrival).
-- No listed server (none fresh yet, a full one, the list unreadable): pick() is nil and the player
-- plays where they are. Nothing here ever restarts or empties a server by itself.
--
--   FreshServers.new(deps) deps = {
--       version: number, job_id: string,
--       now = function() -> seconds,
--       players = function() -> number, max_players: number,
--       publish = function(version: number),            -- announce to every server (may throw)
--       list_put = function(job_id, entry, ttl_s),       -- may throw / yield
--       list_get = function() -> { { key, value } },     -- may throw / yield
--       on_outdated = function(latest: number)?, log = function(text)?,
--   }
--   :heard(version)   another server's announcement
--   :tick()           every few seconds: announce and list when due
--   :is_outdated(), :latest()
--   :pick() -> job_id?   a fresh server with room (yields; the list is read at most every PICK_CACHE_S)

local FreshServers = {}
FreshServers.__index = FreshServers

FreshServers.ANNOUNCE_S = 300
FreshServers.LIST_S = 45
FreshServers.LIST_TTL_S = 110
--- An entry older than this is not trusted (its server may have closed or filled).
FreshServers.STALE_S = 100
--- Seats a listed server must have free to be picked (others are on their way there too).
FreshServers.ROOM = 4
FreshServers.PICK_CACHE_S = 15
--- Among the servers with room, one of the emptiest PICK_AMONG is taken at random.
FreshServers.PICK_AMONG = 4

function FreshServers.new(deps: any)
	local self = setmetatable({}, FreshServers)
	self.deps = deps
	self.version = deps.version
	self._latest = deps.version
	self._next_announce = 0
	self._next_list = 0
	self._list = nil :: any
	self._list_at = -1e9
	return self
end

function FreshServers.latest(self: any): number
	return self._latest
end

function FreshServers.is_outdated(self: any): boolean
	return self._latest > self.version
end

--- Another server announced `version`.
function FreshServers.heard(self: any, version: any)
	if type(version) ~= "number" or version ~= version or version <= self._latest then
		return
	end
	self._latest = math.floor(version)
	if self.deps.log ~= nil then
		self.deps.log(string.format("[Fresh] version %d is out; this server runs %d", self._latest, self.version))
	end
	if self.deps.on_outdated ~= nil then
		pcall(self.deps.on_outdated, self._latest)
	end
end

function FreshServers.tick(self: any)
	local deps = self.deps
	local now = deps.now()
	if now >= self._next_announce then
		self._next_announce = now + FreshServers.ANNOUNCE_S
		pcall(deps.publish, self.version)
	end
	if now >= self._next_list then
		self._next_list = now + FreshServers.LIST_S
		if not self:is_outdated() then
			pcall(
				deps.list_put,
				deps.job_id,
				{ v = self.version, n = deps.players(), cap = deps.max_players, t = now },
				FreshServers.LIST_TTL_S
			)
		end
	end
end

--- A listed server of the newest version with room, or nil. Entries also tell of versions this
--- server has not heard announced.
function FreshServers.pick(self: any): string?
	local deps = self.deps
	local now = deps.now()
	if self._list == nil or now - self._list_at > FreshServers.PICK_CACHE_S then
		local ok, rows = pcall(deps.list_get)
		self._list = if ok and type(rows) == "table" then rows else {}
		self._list_at = now
	end
	local newest = self._latest
	for _, row in self._list do
		local e = if type(row) == "table" then row.value else nil
		if type(e) == "table" and type(e.v) == "number" and e.v > newest then
			newest = e.v
		end
	end
	if newest > self._latest then
		self:heard(newest)
	end
	if newest <= self.version then
		return nil -- (this server is as new as any)
	end
	local fit = {}
	for _, row in self._list do
		local e = if type(row) == "table" then row.value else nil
		if
			type(e) == "table"
			and type(row.key) == "string"
			and row.key ~= deps.job_id
			and e.v == newest
			and type(e.n) == "number"
			and type(e.cap) == "number"
			and type(e.t) == "number"
			and now - e.t <= FreshServers.STALE_S
			and e.cap - e.n >= FreshServers.ROOM
		then
			table.insert(fit, { key = row.key, n = e.n })
		end
	end
	if #fit == 0 then
		return nil
	end
	table.sort(fit, function(a, b)
		if a.n ~= b.n then
			return a.n < b.n
		end
		return a.key < b.key
	end)
	local among = math.min(#fit, FreshServers.PICK_AMONG)
	local chosen = fit[math.random(1, among)]
	-- (one more on its way there: the next pick from this cached list sees it fuller)
	for _, row in self._list do
		if row.key == chosen.key then
			row.value.n += 1
		end
	end
	return chosen.key
end

return FreshServers
