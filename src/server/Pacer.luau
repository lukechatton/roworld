--!strict
-- Runs calls at a steady rate instead of in bursts: a token bucket in front of a queue, with a cap
-- on how many calls one key (a player) may have waiting, so no one crowds out the rest.
-- Analytics uses it for AnalyticsService (2026-11-01: Roblox allows 120 + 20 x players events a
-- minute on a server and drops the rest, "AnalyticsService: You have sent too many events").
--
--   Pacer.new(opts) -> pacer
--     opts = {
--       rate = function() -> number,   -- calls a second now
--       burst_s = number,              -- the bucket holds this many seconds of calls (at least 1 call)
--       max_queued = number,           -- calls waiting at most (past it: dropped)
--       per_key_max = number,          -- calls of one key waiting at most (past it: dropped)
--       now = function() -> number,    -- seconds
--       on_error = function(err)?,
--     }
--   pacer:submit(key, fn, ...) -> boolean   now if the bucket allows and nothing waits, else queued;
--                                           false: dropped
--   pacer:pump()                            runs the waiting calls the bucket allows (call often)
local Pacer = {}
Pacer.__index = Pacer

function Pacer.new(opts: { [string]: any })
	local self = setmetatable({}, Pacer)
	self.opts = opts
	self.tokens = 0.0
	self.at = opts.now()
	self.queue = {} :: { [number]: any }
	self.head = 1
	self.tail = 0
	self.waiting = {} :: { [any]: number }
	self.sent = 0
	self.dropped = 0
	self:_refill()
	self.tokens = self:_cap()
	return self
end

function Pacer._cap(self: any): number
	return math.max(1, self.opts.rate() * self.opts.burst_s)
end

function Pacer._refill(self: any)
	local t = self.opts.now()
	local dt = math.max(0, t - self.at)
	self.at = t
	self.tokens = math.min(self:_cap(), self.tokens + dt * self.opts.rate())
end

function Pacer._run(self: any, call: { any })
	self.tokens -= 1
	self.sent += 1
	local ok, err = pcall(table.unpack(call, 1, call.n))
	if not ok and self.opts.on_error then
		self.opts.on_error(err)
	end
end

function Pacer.queued(self: any): number
	return self.tail - self.head + 1
end

function Pacer.submit(self: any, key: any, fn: (...any) -> ...any, ...: any): boolean
	self:_refill()
	local call = table.pack(fn, ...)
	if self:queued() == 0 and self.tokens >= 1 then
		self:_run(call)
		return true
	end
	local mine = self.waiting[key] or 0
	if self:queued() >= self.opts.max_queued or mine >= self.opts.per_key_max then
		self.dropped += 1
		return false
	end
	self.waiting[key] = mine + 1
	self.tail += 1
	self.queue[self.tail] = { key = key, call = call }
	return true
end

function Pacer.pump(self: any)
	self:_refill()
	while self.tokens >= 1 and self.head <= self.tail do
		local it = self.queue[self.head]
		self.queue[self.head] = nil
		self.head += 1
		local left = (self.waiting[it.key] or 1) - 1
		self.waiting[it.key] = if left > 0 then left else nil
		self:_run(it.call)
	end
	if self.head > self.tail then
		-- (empty: start the array again)
		self.queue = {}
		self.head, self.tail = 1, 0
	end
end

return Pacer
