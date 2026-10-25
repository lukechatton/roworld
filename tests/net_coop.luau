-- Coop time-slicing: jobs yield only when their budget is spent, check() is a no-op outside a job,
-- errors are captured with a traceback, finish() completes synchronously.
-- Run: .bin/lune run tests/net_coop.luau
require("./prelude")
local U = require("./net_util")
local Coop = require("../src/shared/Net/Coop")
local check = U.check

-- no-op outside a job
local t0 = os.clock()
for _ = 1, 100000 do
	Coop.check()
end
check(not Coop.active(), "not active outside a job")
check(os.clock() - t0 < 0.5, ("100k checks outside a job are cheap (%.1f ms)"):format((os.clock() - t0) * 1000))

-- a 60 ms busy job with a 5 ms budget takes several slices, each close to the budget
local function busy(ms)
	local stop = os.clock() + ms / 1000
	local n = 0
	while os.clock() < stop do
		n += 1
		if n % 100 == 0 then
			Coop.check()
		end
	end
	return n
end
local job = Coop.job(busy, 60)
local slices, worst = 0, 0
while true do
	local a = os.clock()
	local done = job:step(0.005)
	worst = math.max(worst, os.clock() - a)
	slices += 1
	if done then
		break
	end
end
check(job.ok and job.result > 0, "job returns its result")
check(slices >= 10, ("60 ms of work spread over %d slices"):format(slices))
check(worst < 0.008, ("no slice much longer than the budget (worst %.1f ms)"):format(worst * 1000))

-- errors are captured
local bad = Coop.job(function()
	Coop.check()
	error("boom")
end)
bad:finish()
check(bad.done and not bad.ok and string.find(bad.err or "", "boom") ~= nil, "errors are captured with the message")

-- nested plain coroutines inside a job don't get yielded by check()
local nested = Coop.job(function()
	local co = coroutine.create(function()
		busy(3)
		return "inner"
	end)
	local ok, r = coroutine.resume(co)
	return ok and r
end)
nested:finish()
check(nested.ok and nested.result == "inner", "check() only yields the job's own coroutine")

-- a job inside a job (Session builds while a snapshot job runs) keeps budgets separate
local outer = Coop.job(function()
	local inner = Coop.job(busy, 10)
	inner:finish()
	Coop.check()
	return inner.ok
end)
outer:finish()
check(outer.ok and outer.result == true, "jobs nest")

if U.failures() > 0 then
	error(U.failures() .. " failures")
end
print("net_coop ok")
