--!nocheck
-- DsGate (2026-11-01): this server's DataStore requests wait for budget, at most MAX_IN_FLIGHT of a
-- kind at once, and one Roblox dropped for throttling is sent again (a match's end paid 50 players'
-- Stars at once, and a dropped payout was lost).
-- Run: .bin/lune run tests/ds_gate.luau
require("./prelude")
local DsGate = require("../src/server/DsGate")

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
local budget = { read = 100, write = 100 }
local deps = {
	budget = function(kind)
		return budget[kind]
	end,
	wait = function(s)
		t += s
		-- the budget refills as time passes
		budget.read += s * 10
		budget.write += s * 10
	end,
	now = function()
		return t
	end,
}

-- a store that refuses the first `refuse` requests as Roblox does when its queue is full
local rows = {}
local refuse = 0
local calls = 0
local raw = {
	GetAsync = function(_, k)
		calls += 1
		budget.read -= 1
		return rows[k], { UpdatedTime = 1 }
	end,
	UpdateAsync = function(_, k, fn)
		calls += 1
		budget.read -= 1
		budget.write -= 1
		if refuse > 0 then
			refuse -= 1
			error(
				"StandardWriteGameServerThrottled: StandardWrite request was throttled by game server limits or the request queue was full. API: UpdateAsync",
				0
			)
		end
		rows[k] = fn(rows[k])
		return rows[k], { UpdatedTime = 2 }
	end,
	ListKeysAsync = function(_, prefix)
		return "pages:" .. prefix
	end,
	Name = "Stars",
}
local store = DsGate.wrap(raw, deps)

-- straight through with budget: both return values kept
rows.a = 5
local v, info = store:GetAsync("a")
expect(v == 5 and info.UpdatedTime == 1, "a read with budget: value and key info")
local nv = store:UpdateAsync("a", function(old)
	return old + 1
end)
expect(nv == 6, "an update")
expect(store:ListKeysAsync("p") == "pages:p" and store.Name == "Stars", "other methods and fields as they are")

-- a throttled update is sent again (it did nothing) and lands once
refuse = 2
calls = 0
local paid = store:UpdateAsync("stars", function(old)
	return (old or 0) + 40
end)
expect(paid == 40 and rows.stars == 40, "a payout dropped twice by Roblox lands once")
expect(calls == 3 and store.retried == 2, "three tries")

-- other errors are not retried
local ok, err = pcall(store.UpdateAsync, store, "x", function()
	error("bad data")
end)
expect(
	not ok and string.find(tostring(err), "bad data", 1, true) and store.retried == 2,
	"a real error comes back at once"
)

-- no write budget: the request waits until there is some
budget.write = -5
local t0 = t
store:UpdateAsync("w", function()
	return 1
end)
expect(t > t0 and store.waited >= 1, ("it waited for budget (%.2f s)"):format(t - t0))
expect(t - t0 < DsGate.MAX_WAIT_S, "and not longer than needed")

-- a budget that never comes: it goes anyway after MAX_WAIT_S
local stuck = DsGate.wrap(raw, {
	budget = function()
		return 0
	end,
	wait = function(s)
		t += s
	end,
	now = function()
		return t
	end,
})
t0 = t
expect(stuck:GetAsync("a") == rows.a, "no budget at all: goes after MAX_WAIT_S")
expect(math.abs(t - t0 - DsGate.MAX_WAIT_S) <= DsGate.POLL_S + 1e-9, "after waiting MAX_WAIT_S")

-- the in-flight cap: requests that yield count until they return
local inside, most = 0, 0
local slow_raw = {
	GetAsync = function()
		inside += 1
		most = math.max(most, inside)
		coroutine.yield()
		inside -= 1
		return 1
	end,
}
local waits = {}
local gate = DsGate.wrap(slow_raw, {
	wait = function(s)
		t += s
		table.insert(waits, coroutine.running())
		coroutine.yield()
	end,
	now = function()
		return t
	end,
})
local threads = {}
for i = 1, DsGate.MAX_IN_FLIGHT + 3 do
	threads[i] = coroutine.create(function()
		return gate:GetAsync("k")
	end)
	coroutine.resume(threads[i])
end
expect(most == DsGate.MAX_IN_FLIGHT, ("at most %d reads at once"):format(DsGate.MAX_IN_FLIGHT))
expect(#waits == 3, "the other 3 wait their turn")

if fails > 0 then
	error(fails .. " failure(s)")
end
print("ds_gate: all ok")
