--!nocheck
-- Owed Stars (2026-11-13): since Nov 10 Roblox refused so many writes to the Purchases store that
-- 50,000-97,000 match payouts a day failed every retry and were dropped. Now a payout whose write
-- fails is owed: shown, carried by the player's next write, tried again, kept in MemoryStore when
-- they leave and paid by the next server; each payout is stored once (its id). One write at a time
-- goes to a record from a server, and writes that would change nothing are skipped.
-- Run: .bin/lune run tests/owed_stars.luau
require("./prelude")
local Purchases = require("../src/server/Purchases")
local Cosmetics = require("../src/shared/Data/Cosmetics")

local fails = 0
local function expect(cond: any, what: string)
	if cond then
		print("  ok   " .. what)
	else
		fails += 1
		print("FAIL " .. what)
	end
end

-- a scheduler: spawn and wait on a clock that moves only when run() says so
local t = 0.0
local seq = 0
local queue = {}
local function at(when, co, args)
	seq += 1
	table.insert(queue, { at = when, seq = seq, co = co, args = args or table.pack() })
end
local function spawn(fn, ...)
	at(t, coroutine.create(fn), table.pack(...))
end
local function wait(s)
	at(t + s, coroutine.running())
	coroutine.yield()
end
local function run(until_t)
	while true do
		table.sort(queue, function(a, b)
			return a.at < b.at or (a.at == b.at and a.seq < b.seq)
		end)
		local nxt = queue[1]
		if nxt == nil or nxt.at > until_t then
			t = math.max(t, until_t)
			return
		end
		table.remove(queue, 1)
		t = math.max(t, nxt.at)
		local ok, err = coroutine.resume(nxt.co, table.unpack(nxt.args, 1, nxt.args.n))
		if not ok then
			error(err)
		end
	end
end
local function go(fn)
	local out = table.pack()
	spawn(function()
		out = table.pack(fn())
	end)
	run(t + 0.5)
	return table.unpack(out, 1, out.n)
end

-- the Purchases DataStore: refuses `refuse` writes, or stores one and then errors (`ambiguous`)
local rows = {}
local refuse = 0
local ambiguous = 0
local inside, most_inside = {}, 0
local updates = 0
local store = {
	GetAsync = function(_, k)
		return rows[k]
	end,
	UpdateAsync = function(_, k, fn)
		updates += 1
		inside[k] = (inside[k] or 0) + 1
		most_inside = math.max(most_inside, inside[k])
		wait(0.2)
		inside[k] -= 1
		if refuse > 0 then
			refuse -= 1
			error(
				"DataStoreService: StandardWriteGameServerThrottled: StandardWrite request was throttled by game server limits or the request queue was full. API: UpdateAsync",
				0
			)
		end
		local v = fn(rows[k])
		if v ~= nil then
			rows[k] = v
		end
		if ambiguous > 0 then
			ambiguous -= 1
			error("DataStoreService: InternalServerError: An internal server error occurred. API: UpdateAsync", 0)
		end
		return v
	end,
}
-- the MemoryStore hash map of owed Stars
local mem = {}
local mem_down = false
local owed_map = {
	GetAsync = function(_, k)
		return mem[k]
	end,
	UpdateAsync = function(_, k, fn, ttl)
		if mem_down then
			error("MemoryStore unavailable", 0)
		end
		mem[k] = fn(mem[k])
		return mem[k]
	end,
}
local warned = {}
local arrive = {}
Purchases.reset()
Purchases.configure({
	datastore = store,
	owed_map = owed_map,
	spawn = spawn,
	wait = wait,
	warn = function(text)
		table.insert(warned, text)
	end,
	notify = function() end,
	arrived = function(p)
		return arrive[p]
	end,
})

----------------------------------------------------------------------------------------------------
print("a payout stored at once")
local P = { UserId = 101 }
rows.u101 = { stars = 100 }
go(function()
	Purchases.load(P)
end)
local ok, bal = go(function()
	return Purchases.add_stars(P, 40)
end)
expect(ok and bal == 140 and rows.u101.stars == 140 and #rows.u101.payouts == 1, "stored, with its id kept")

print("a payout the store refuses is owed, shown, and stored later once")
Purchases.take_stats()
refuse = 2 -- (the first write and the first retry)
ok, bal = go(function()
	return Purchases.add_stars(P, 60)
end)
expect(ok and bal == 200 and rows.u101.stars == 140, "owed: shown in the balance (200), not stored yet")
local stats = Purchases.take_stats()
expect(stats.payouts == 1 and stats.owed_new == 1 and stats.write_fails == 1, "counted as owed")
run(t + 200)
expect(rows.u101.stars == 200 and #rows.u101.payouts == 2, "stored by the retries, once")
expect(Purchases.stars(P) == 200 and Purchases.take_stats().owed_paid == 1, "and counted as paid late")

print("a write that was stored but answered with an error is not stored twice")
ambiguous = 1
go(function()
	return Purchases.add_stars(P, 25)
end)
expect(rows.u101.stars == 225 and Purchases.stars(P) == 225, "stored once; shown as 200 held + 25 owed")
run(t + 200)
expect(rows.u101.stars == 225 and Purchases.stars(P) == 225, "the retry finds its id stored: no second payout")

print("owed Stars go with the player's next write")
refuse = 1
go(function()
	return Purchases.add_stars(P, 10)
end)
expect(rows.u101.stars == 225, "owed")
local skin
for _, it in Cosmetics.all() do
	if it.kind == "skin" then
		skin = it.id
		break
	end
end
if skin ~= nil then
	rows.u101.owned = { [skin] = true }
	go(function()
		Purchases.load(P)
	end)
	go(function()
		return Purchases.equip(P, "skin", skin)
	end)
	expect(rows.u101.stars == 235 and rows.u101.equipped.skin == skin, "an equip stored the owed 10 Stars with it")
else
	print("  (no skin in Cosmetics.all(): skipped)")
end

print("one write at a time to a record")
most_inside = 0
for _ = 1, 4 do
	spawn(function()
		Purchases.add_stars(P, 1)
	end)
end
run(t + 30)
expect(
	most_inside == 1 and rows.u101.stars >= 239,
	"four payouts at once: never two writes in flight (" .. most_inside .. ")"
)

print("leaving while owed: kept in MemoryStore, paid by the next server")
local Q = { UserId = 202 }
rows.u202 = { stars = 5 }
go(function()
	Purchases.load(Q)
end)
refuse = 100
go(function()
	return Purchases.add_stars(Q, 70)
end)
expect(Purchases.stars(Q) == 75, "owed 70")
Purchases.release(Q)
run(t + 1)
refuse = 0
expect(type(mem.u202) == "table" and #mem.u202 == 1 and mem.u202[1].stars == 70, "kept in MemoryStore")
expect(Purchases.take_stats().owed_kept == 1, "counted as kept")
-- (the retries this server had going stopped when they left)
local before = updates
run(t + 300)
expect(updates == before, "nothing more written for them here")

local Q2 = { UserId = 202 } -- (the same player on the next server)
go(function()
	Purchases.load(Q2)
end)
run(t + 2)
expect(rows.u202.stars == 75 and #mem.u202 == 0, "the next server pays it, and it is gone from MemoryStore")
Purchases.release(Q2)
local Q3 = { UserId = 202 }
go(function()
	Purchases.load(Q3)
end)
run(t + 2)
expect(rows.u202.stars == 75, "and not paid again on the server after")
Purchases.release(Q3)

print("leaving while a payout's write is in flight: stored, not kept for later")
-- (v117's first minutes: 15 of 92 payouts kept in MemoryStore though their write landed)
local V = { UserId = 252 }
rows.u252 = { stars = 10 }
go(function()
	Purchases.load(V)
end)
Purchases.take_stats()
spawn(function()
	Purchases.add_stars(V, 40)
end)
run(t + 0.1) -- (the write is in the store now)
Purchases.release(V)
run(t + 2)
expect(rows.u252.stars == 50, "the write landed")
expect(mem.u252 == nil, "nothing kept in MemoryStore")
local vs = Purchases.take_stats()
expect(vs.owed_kept == 0 and vs.owed_new == 0, "nothing counted as kept or owed")

print("leaving while a payout's write is in flight, and it fails: kept for later")
local V2 = { UserId = 253 }
rows.u253 = { stars = 10 }
go(function()
	Purchases.load(V2)
end)
refuse = 1
spawn(function()
	Purchases.add_stars(V2, 40)
end)
run(t + 0.1)
Purchases.release(V2)
run(t + 2)
refuse = 0
expect(rows.u253.stars == 10, "not stored")
expect(type(mem.u253) == "table" and #mem.u253 == 1 and mem.u253[1].stars == 40, "kept in MemoryStore")
expect(Purchases.take_stats().owed_kept == 1, "counted as kept")

print("a handoff says whether to look")
local R = { UserId = 303 }
rows.u303 = { stars = 0 }
mem.u303 = { { id = "abc123abc123", stars = 30 } }
arrive[R] = { p = { stars = 0 }, o = nil }
go(function()
	Purchases.load(R)
end)
run(t + 2)
expect(rows.u303.stars == 0, "a handoff without o: MemoryStore isn't read")
Purchases.release(R)
local R2 = { UserId = 303 }
arrive[R2] = { p = { stars = 0 }, o = true }
go(function()
	Purchases.load(R2)
end)
run(t + 2)
expect(rows.u303.stars == 30, "with o: the owed Stars are paid")
Purchases.release(R2)

print("MemoryStore down when they leave: lost, and warned")
local S = { UserId = 404 }
rows.u404 = { stars = 0 }
go(function()
	Purchases.load(S)
end)
refuse = 100
go(function()
	return Purchases.add_stars(S, 15)
end)
mem_down = true
Purchases.release(S)
run(t + 1)
mem_down = false
refuse = 0
local st = Purchases.take_stats()
expect(st.lost == 1 and st.lost_stars == 15, "counted as lost")
expect(
	warned[#warned] == "[Purchases] match Stars lost after every retry (other)",
	"warned: " .. tostring(warned[#warned])
)

print("writes that would change nothing are skipped")
local T = { UserId = 505 }
rows.u505 = { stars = 0, tutorial_paid = true, general_day = 20400, starter = { started = 1, ends = 2 } }
go(function()
	Purchases.load(T)
end)
before = updates
local paid = go(function()
	return Purchases.tutorial_bonus(T, 200)
end)
local given = go(function()
	return Purchases.general_perks(T, 20400, nil, true)
end)
local started = go(function()
	return Purchases.starter_seen(T)
end)
expect(
	paid == false and type(given) == "table" and next(given) == nil and started == false,
	"tutorial paid, day given, offer started"
)
expect(updates == before and Purchases.take_stats().skipped >= 2, "no writes for them")

print("the tutorial's Stars, owed, are paid once")
local U = { UserId = 606 }
rows.u606 = { stars = 0 }
go(function()
	Purchases.load(U)
end)
refuse = 1
go(function()
	return Purchases.tutorial_bonus(U, 200)
end)
run(t + 100)
expect(rows.u606.stars == 200 and rows.u606.tutorial_paid == true, "paid once on the retry")
local again = go(function()
	return Purchases.tutorial_bonus(U, 200)
end)
expect(again == false and rows.u606.stars == 200, "not again")

print("the most writes to one record this window")
Purchases.take_stats()
for _ = 1, 3 do
	go(function()
		Purchases.add_stars(U, 1)
	end)
end
run(t + 10)
expect(Purchases.take_stats().max_key == 3, "reported")

if fails > 0 then
	error(fails .. " failure(s)")
end
print("owed_stars: all ok")
