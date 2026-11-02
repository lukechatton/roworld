--!strict
-- A gate in front of this server's DataStores (2026-11-01). Roblox gives a server 60 + 40 x players
-- reads and as many writes a minute (an UpdateAsync is one of each), queues 30 requests past that and
-- drops the rest: "StandardWriteGameServerThrottled ... the request queue was full. API: UpdateAsync",
-- "TooManyRequests ... API: GetAsync", "DataStore request was added to queue" (~7,500 a day in the
-- error report). They came in bursts: a public match's end pays 50 players' Stars and saves their
-- settings while they all leave (and the budget shrinks with them), a new match server reads 50
-- records at once. A dropped Stars payout was lost ("could not pay ... Stars").
--
-- Through the gate a request waits until the budget has room (at most MAX_WAIT_S, then it goes
-- anyway), no more than MAX_IN_FLIGHT of a kind run at once, and one Roblox dropped for throttling is
-- sent again after RETRY_S (a dropped request did nothing, so this is safe for any request).
--
--   DsGate.wrap(store, deps?) -> store   the same GetAsync / SetAsync / UpdateAsync / RemoveAsync,
--                                         through the gate (every other method as is)
--   DsGate.throttled(err) -> boolean     Roblox refused the request for its limits (it did nothing)
--   deps = { budget = function(kind) -> number?,   -- "read" | "write": this server's budget now
--            wait = function(s), now = function() -> s, log = function(text)? }
local DsGate = {}

DsGate.MAX_WAIT_S = 15
DsGate.MAX_IN_FLIGHT = 8
--- The waits before each new try of a throttled request.
DsGate.RETRY_S = { 2, 5, 10 }
DsGate.POLL_S = 0.25

local IS_ROBLOX = typeof(game) == "Instance"

local function roblox_deps(): { [string]: any }
	local DataStoreService = game:GetService("DataStoreService")
	local types = {
		read = Enum.DataStoreRequestType.StandardRead,
		write = Enum.DataStoreRequestType.StandardWrite,
	}
	return {
		budget = function(kind: string): number?
			local ok, n = pcall(DataStoreService.GetRequestBudgetForRequestType, DataStoreService, types[kind])
			return if ok and type(n) == "number" then n else nil
		end,
		wait = task.wait,
		now = os.clock,
		log = warn,
	}
end

local default_deps: { [string]: any }? = nil

function DsGate.throttled(err: any): boolean
	local s = tostring(err)
	return string.find(s, "Throttled", 1, true) ~= nil
		or string.find(s, "TooManyRequests", 1, true) ~= nil
		or string.find(s, "queue was full", 1, true) ~= nil
		or string.find(s, "request dropped", 1, true) ~= nil
end

local KINDS: { [string]: { string } } = {
	GetAsync = { "read" },
	SetAsync = { "write" },
	UpdateAsync = { "read", "write" },
	RemoveAsync = { "write" },
}

function DsGate.wrap(store: any, deps: { [string]: any }?): any
	local d: { [string]: any } = deps or default_deps or {}
	if deps == nil and default_deps == nil and IS_ROBLOX then
		default_deps = roblox_deps()
		d = default_deps :: { [string]: any }
	end
	local in_flight: { [string]: number } = { read = 0, write = 0 }
	local gate = { waited = 0, retried = 0 }

	local function room(kinds: { string }): boolean
		for _, k in kinds do
			if in_flight[k] >= DsGate.MAX_IN_FLIGHT then
				return false
			end
			local n = if d.budget then d.budget(k) else nil
			if n ~= nil and n < 1 then
				return false
			end
		end
		return true
	end

	local function enter(kinds: { string })
		local t0 = d.now()
		local waited = false
		while not room(kinds) and d.now() - t0 < DsGate.MAX_WAIT_S do
			waited = true
			d.wait(DsGate.POLL_S)
		end
		if waited then
			gate.waited += 1
		end
		for _, k in kinds do
			in_flight[k] += 1
		end
	end

	local function leave(kinds: { string })
		for _, k in kinds do
			in_flight[k] -= 1
		end
	end

	local function through(method: string, ...: any): ...any
		local kinds = KINDS[method]
		local attempt = 1
		while true do
			enter(kinds)
			local res = table.pack(pcall(store[method], store, ...))
			leave(kinds)
			if res[1] then
				return table.unpack(res, 2, res.n)
			end
			local err = res[2]
			local pause = DsGate.RETRY_S[attempt]
			if pause == nil or not DsGate.throttled(err) then
				error(err, 0)
			end
			gate.retried += 1
			attempt += 1
			d.wait(pause)
		end
	end

	return setmetatable(gate, {
		__index = function(_, method: string): any
			if KINDS[method] ~= nil then
				return function(_self: any, ...: any): ...any
					return through(method, ...)
				end
			end
			local v = store[method]
			if type(v) == "function" then
				return function(_self: any, ...: any): ...any
					return v(store, ...)
				end
			end
			return v
		end,
	})
end

return DsGate
