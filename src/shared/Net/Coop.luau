--!strict
-- Cooperative time-slicing for long synchronous work (match construction, snapshot decoding).
--
-- session.gd built local matches on a WorkerThreadPool task so the UI never froze. Roblox gives game
-- scripts no worker threads for this, so the Session runs such work inside a Coop job: a coroutine that
-- is resumed once per frame with a time budget. Long loops call `Coop.check()` every few thousand
-- iterations; it yields back to the frame only when the job's budget is spent, and is a cheap no-op
-- outside a job (plain calls, Lune tests, the server).
--
--   local job = Coop.job(function() return build_match() end)
--   RunService.Heartbeat:Connect(function() if not job.done then job:step(0.004) end end)
--   -- job.done / job.ok / job.result (first return value) / job.err (message with traceback)

local Coop = {}

local clock = os.clock
local current: thread? = nil
local deadline = 0.0

--- Yields the running Coop job if its frame budget is spent. Safe to call from anywhere.
function Coop.check()
	if current ~= nil and clock() >= deadline and coroutine.running() == current then
		coroutine.yield()
	end
end

--- True when called from inside a Coop job (callers may pick a chunkier loop).
function Coop.active(): boolean
	return current ~= nil and coroutine.running() == current
end

export type Job = {
	done: boolean,
	ok: boolean,
	result: any,
	err: string?,
	slices: number,
	step: (self: Job, budget_s: number) -> boolean,
	finish: (self: Job) -> (),
}

local Job = {}
Job.__index = Job

function Coop.job(fn: (...any) -> any, ...: any): Job
	local args = table.pack(...)
	local self: any = setmetatable({ done = false, ok = false, result = nil, err = nil, slices = 0 }, Job)
	self._co = coroutine.create(function()
		local ok, res = xpcall(function()
			return fn(table.unpack(args, 1, args.n))
		end, function(e)
			return debug.traceback(tostring(e), 2)
		end)
		return ok, res
	end)
	return self
end

--- Runs the job for at most ~budget_s seconds (the current slice always finishes the check it is in).
--- Returns true once the job has finished (successfully or not).
function Job.step(self: any, budget_s: number): boolean
	if self.done then
		return true
	end
	local prev, prev_deadline = current, deadline
	current = self._co
	deadline = clock() + budget_s
	self.slices += 1
	local resumed, ok, res = coroutine.resume(self._co)
	current, deadline = prev, prev_deadline
	if coroutine.status(self._co) == "dead" then
		self.done = true
		if not resumed then
			self.ok = false
			self.err = tostring(ok)
		elseif ok then
			self.ok = true
			self.result = res
		else
			self.ok = false
			self.err = tostring(res)
		end
	end
	return self.done
end

--- Runs the job to completion synchronously (tests, or when the caller must block).
function Job.finish(self: any)
	while not self.done do
		self:step(math.huge)
	end
end

return Coop
