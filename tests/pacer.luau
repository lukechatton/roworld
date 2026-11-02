--!nocheck
-- Pacer (2026-11-01): calls at a steady rate instead of in bursts, as Analytics sends AnalyticsService
-- events (Roblox drops a server's events past 120 + 20 x players a minute).
-- Run: .bin/lune run tests/pacer.luau
require("./prelude")
local Pacer = require("../src/server/Pacer")

local fails = 0
local function expect(cond: any, what: string)
	if cond then
		print("  ok   " .. what)
	else
		fails += 1
		print("FAIL " .. what)
	end
end

local t = 0.0
local got = {}
local function log(who, n)
	table.insert(got, who .. n)
end
local errors = {}
local p = Pacer.new({
	rate = function()
		return 10
	end,
	burst_s = 2,
	max_queued = 50,
	per_key_max = 30,
	now = function()
		return t
	end,
	on_error = function(e)
		table.insert(errors, e)
	end,
})

-- a burst: the bucket's 20 at once, the rest queued in order
for i = 1, 60 do
	p:submit("spam", log, "s", i)
end
p:submit("fair", log, "f", 1)
expect(#got == 20, "a burst: the bucket's 20 at once")
expect(p:queued() == 31, "30 of the flooding player's wait, the rest dropped; another player still gets in")
expect(p.dropped == 10, "10 dropped")
t += 1.0
p:pump()
expect(#got == 30 and got[21] == "s21", "a second later: 10 more, in order")
for _ = 1, 3 do
	t += 1.0
	p:pump()
end
expect(#got == 51 and got[51] == "f1", "the queue drains at the rate, the other player's call too")
expect(p:queued() == 0, "empty")

-- nothing waits: straight through while the bucket has room; a failing call is reported, not thrown
local before = #got
p:submit("x", log, "x", 1)
p:submit("x", function()
	error("boom")
end)
expect(#got == before + 1 and #errors == 1, "a failing call goes to on_error")

-- the rate follows the players (Analytics: 120 + 20 x players a minute)
local rate = 1
local q = Pacer.new({
	rate = function()
		return rate
	end,
	burst_s = 1,
	max_queued = 100,
	per_key_max = 100,
	now = function()
		return t
	end,
})
local n = 0
for _ = 1, 10 do
	q:submit("k", function()
		n += 1
	end)
end
expect(n == 1, "a slow bucket: one at once")
rate = 5
t += 1.0
q:pump()
expect(n == 6, "a faster rate: 5 more after a second")

if fails > 0 then
	error(fails .. " failure(s)")
end
print("pacer: all ok")
