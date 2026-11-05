--!strict
-- What a server knew about a player, handed to the server it teleports them to (2026-11-03).
--
-- Every join read the player's settings and Purchases record from their DataStores, and a public match
-- is two joins (its match server, then a hub): four reads a match for every player. At busy times
-- Roblox's backend refused a share of them ("DataStoreService: TooManyRequests: Too many requests, try
-- again later. API: GetAsync" on both stores, ~9,000 a day; a refused settings read meant defaults for
-- the session). Now a server that teleports a player sends a fresh id in the teleport data and, once the
-- player has left and their last writes have landed, puts what it knew of them (both records) in a
-- MemoryStore hash map under their user id, with that id, for HOLD_S. The server they arrive on uses it
-- when the ids match, and reads the DataStores only when they don't (a join from outside the game, a
-- server of an older version, a record that wasn't known for sure). Teleport data passes through the
-- player's client, so it carries only the id: the records come from MemoryStore under the player's own
-- user id, and a stale or made-up id finds nothing.
--
--   Handoff.new(deps) -> h
--     deps = {
--       map = MemoryStoreHashMap?,          -- GetAsync / SetAsync (nil: off, every join reads the stores)
--       guid = function() -> string,
--       join_data = function(player) -> any, -- player:GetJoinData()
--       encode = function(v) -> string,      -- JSON, for the size check
--       spawn, wait, now,
--       log = function(text)?,
--     }
--   h:stamp(players, data?) -> data      a teleport is about to start: a copy of `data` with the id
--   h:leaving(player) -> boolean         PlayerRemoving: true when the player is on a stamped teleport
--   h:part(player, name, value?)         a leaving player's "p" (Purchases record) or "s" (settings);
--                                        nil: not known for sure. The entry goes when both are in.
--   h:arrived(player) -> { p?, s? }?     what the last server knew (yields; one read for all callers)
local Handoff = {}
Handoff.__index = Handoff

Handoff.MAP = "handoff_v1"
--- How long an entry is kept: a teleport, and a reserved match server starting up.
Handoff.HOLD_S = 300
--- A leaving player's entry goes when both parts are in, or after this long with what is there.
Handoff.PART_WAIT_S = 30
Handoff.PARTS = { "p", "s" }
--- Arriving: the waits between reads while the entry isn't there yet (its last writes still landing).
Handoff.POLL_S = { 0.5, 1, 1.5, 2 }
--- A hash map item holds at most 32 KB: a bigger entry goes without its records.
Handoff.MAX_BYTES = 30000

local function key(uid: number): string
	return "u" .. tostring(uid)
end

function Handoff.new(deps: { [string]: any })
	local self = setmetatable({}, Handoff)
	self.deps = deps
	--- user id -> the id of the teleport they are on
	self._ids = {} :: { [number]: string }
	--- user id -> a leaving player's entry, while its parts come in
	self._out = {} :: { [number]: any }
	--- player -> the arrival read ({ done, entry })
	self._got = {} :: { [any]: any }
	-- counts (tests, diagnostics)
	self.sent = 0
	self.hits = 0
	self.misses = 0
	--- joins that weren't one of our teleports (from outside the game, an older server)
	self.none = 0
	return self
end

function Handoff.stamp(self: any, players: { any }, data: { [string]: any }?): { [string]: any }
	local out = if data ~= nil then table.clone(data) else {}
	if self.deps.map == nil then
		return out
	end
	local id = self.deps.guid()
	out.handoff = id
	for _, p in players do
		self._ids[p.UserId] = id
	end
	return out
end

--- The entry of a player leaving on a stamped teleport (made on the first call; nil when there's none).
function Handoff._start(self: any, uid: number): any
	local out = self._out[uid]
	if out ~= nil then
		return out
	end
	local id = self._ids[uid]
	if id == nil then
		return nil
	end
	self._ids[uid] = nil
	out = { id = id, parts = {}, have = {}, n = 0 }
	self._out[uid] = out
	local d = self.deps
	d.spawn(function()
		local t0 = d.now()
		while out.n < #Handoff.PARTS and d.now() - t0 < Handoff.PART_WAIT_S do
			d.wait(0.1)
		end
		if self._out[uid] == out then
			self._out[uid] = nil
		end
		self:_put(uid, out)
	end)
	return out
end

function Handoff.leaving(self: any, player: any): boolean
	self._got[player] = nil
	return self:_start(player.UserId) ~= nil
end

function Handoff.part(self: any, player: any, name: string, value: any)
	local out = self:_start(player.UserId)
	if out == nil or out.have[name] then
		return
	end
	out.have[name] = true
	out.parts[name] = value
	out.n += 1
end

function Handoff._put(self: any, uid: number, out: any)
	local d = self.deps
	local entry = { id = out.id, p = out.parts.p, s = out.parts.s }
	if d.encode ~= nil then
		-- (the entry still goes without them: the next server stops waiting and reads the stores)
		for _, name in { "p", "s" } do
			local ok, json = pcall(d.encode, entry)
			if ok and type(json) == "string" and #json <= Handoff.MAX_BYTES then
				break
			end
			entry[name] = nil
		end
	end
	local ok, err = pcall(function()
		d.map:SetAsync(key(uid), entry, Handoff.HOLD_S)
	end)
	local log = d.log
	if ok then
		self.sent += 1
	elseif log ~= nil then
		log("[Handoff] could not hand " .. tostring(uid) .. " on: " .. tostring(err))
	end
end

--- The entry the last server put for this teleport: read again over POLL_S while it isn't there.
function Handoff._fetch(self: any, player: any): any
	local d = self.deps
	if d.map == nil then
		return nil
	end
	local ok, jd = pcall(d.join_data, player)
	local td = if ok and type(jd) == "table" then jd.TeleportData else nil
	local id = if type(td) == "table" then td.handoff else nil
	if type(id) ~= "string" or #id == 0 or #id > 64 then
		self.none += 1 -- (not from one of our teleports)
		return nil
	end
	local k = key(player.UserId)
	for i = 1, #Handoff.POLL_S + 1 do
		if i > 1 then
			d.wait(Handoff.POLL_S[i - 1])
		end
		local got, v = pcall(function()
			return d.map:GetAsync(k)
		end)
		if got and type(v) == "table" and v.id == id then
			self.hits += 1
			return {
				p = if type(v.p) == "table" then v.p else nil,
				s = if type(v.s) == "table" then v.s else nil,
			}
		end
	end
	self.misses += 1
	return nil
end

function Handoff.arrived(self: any, player: any): any
	local got = self._got[player]
	if got == nil then
		got = { done = false, entry = nil }
		self._got[player] = got
		got.entry = self:_fetch(player)
		got.done = true
		return got.entry
	end
	local d = self.deps
	local t0 = d.now()
	while not got.done and d.now() - t0 < 30 do
		d.wait(0.1)
	end
	return got.entry
end

return Handoff
