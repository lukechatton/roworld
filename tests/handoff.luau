--!nocheck
-- Handoff (2026-11-03): a server that teleports a player hands the next one their settings and
-- Purchases record (MemoryStore, under an id the teleport data carries), once its writes have landed;
-- the next server reads the DataStores only when that doesn't come. And a payout lost after every
-- retry is a warning the error report counts.
-- Run: .bin/lune run tests/handoff.luau
require("./prelude")
local Handoff = require("../src/server/Handoff")
local Purchases = require("../src/server/Purchases")
local SettingsStore = require("../src/server/SettingsStore")

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
local function at(when: number, co: thread, args: any)
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
local function now()
	return t
end
local function run(until_t: number)
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

-- a MemoryStore hash map
local mem = {}
local mem_reads, mem_writes = 0, 0
local last_ttl = nil
local map = {
	GetAsync = function(_, k)
		mem_reads += 1
		return mem[k]
	end,
	SetAsync = function(_, k, v, ttl)
		mem_writes += 1
		last_ttl = ttl
		mem[k] = v
	end,
}
local ids = 0
local join = {} -- player -> TeleportData
local function new_handoff(m)
	return Handoff.new({
		map = m,
		guid = function()
			ids += 1
			return "id-" .. ids
		end,
		join_data = function(p)
			return { TeleportData = join[p] }
		end,
		encode = function(v)
			-- (a stand-in for JSON: the size check only needs a length)
			local n = 0
			local function walk(x)
				if type(x) == "table" then
					for k, y in x do
						n += #tostring(k) + 2
						walk(y)
					end
				else
					n += #tostring(x) + 1
				end
			end
			walk(v)
			return string.rep("x", n)
		end,
		spawn = spawn,
		wait = wait,
		now = now,
	})
end

----------------------------------------------------------------------------------------------------
print("the handoff itself")
local A = { UserId = 7, Name = "A" }
local B = { UserId = 8, Name = "B" }
local from = new_handoff(map)
local data = from:stamp({ A, B }, { party = { key = "k" } })
expect(type(data.handoff) == "string" and data.party.key == "k", "a teleport's data gets the id, the rest kept")
expect(from:stamp({}, nil).handoff ~= data.handoff, "every teleport its own id")
from:stamp({ A, B }, nil) -- (a later teleport of the same two: the newest id is theirs)
local id = "id-3"

-- A leaves: the settings part comes first (SettingsStore.release), the record later (Purchases.settle)
from:part(A, "s", { ui = { ratio = 0.4 } })
expect(from:leaving(A), "leaving on a stamped teleport")
expect(mem_writes == 0, "nothing is written while a part is missing")
spawn(function()
	wait(1.5) -- (a payout still landing)
	from:part(A, "p", { stars = 900 })
end)
run(t + 1)
expect(mem_writes == 0, "still waiting for the record")
run(t + 1)
expect(
	mem_writes == 1 and mem.u7.id == id and mem.u7.p.stars == 900 and mem.u7.s.ui.ratio == 0.4,
	"both parts in: one entry, under the teleport's id"
)
expect(last_ttl == Handoff.HOLD_S, "kept HOLD_S")

-- a player who wasn't on our teleport: nothing written
local C = { UserId = 9, Name = "C" }
expect(not from:leaving(C), "a player who just quit is not handed on")
from:part(C, "s", { ui = {} })
run(t + Handoff.PART_WAIT_S + 1)
expect(mem.u9 == nil, "and nothing is written for them")

-- B's parts never all come: after PART_WAIT_S the entry goes with what there is
expect(from:leaving(B), "B leaving")
from:part(B, "p", nil)
run(t + Handoff.PART_WAIT_S + 1)
expect(
	mem.u8 ~= nil and mem.u8.id == id and mem.u8.p == nil and mem.u8.s == nil,
	"after PART_WAIT_S an entry without records (the next server stops waiting)"
)

-- arriving: the ids match
local to = new_handoff(map)
join[A] = { handoff = id }
local got1, got2
spawn(function()
	got1 = to:arrived(A)
end)
spawn(function()
	got2 = to:arrived(A)
end)
mem_reads = 0
run(t + 1)
expect(got1 ~= nil and got1.p.stars == 900 and got1.s.ui.ratio == 0.4, "the records the last server held")
expect(got2 == got1 and mem_reads == 1, "one read for every caller")
expect(to.hits == 1, "counted as a hit")

-- arriving from outside the game: no read at all
local D = { UserId = 10 }
local got = "unset"
mem_reads = 0
spawn(function()
	got = to:arrived(D)
end)
run(t + 1)
expect(got == nil and mem_reads == 0 and to.none == 1, "no id: the stores are read, MemoryStore isn't")

-- a stale id (an older entry under the player's key): read again over POLL_S, then given up
local E = { UserId = 11 }
mem.u11 = { id = "old", p = { stars = 1 } }
join[E] = { handoff = "new" }
mem_reads = 0
got = "unset"
local t0 = t
spawn(function()
	got = to:arrived(E)
end)
run(t + 20)
local total = 0
for _, s in Handoff.POLL_S do
	total += s
end
expect(
	got == nil and mem_reads == #Handoff.POLL_S + 1 and to.misses == 1,
	"a stale entry is never used; tried " .. mem_reads .. " times"
)
expect(t - t0 >= total, "over " .. total .. " s")

-- the entry lands while the next server is reading
local F = { UserId = 12 }
join[F] = { handoff = "late" }
got = nil
spawn(function()
	got = to:arrived(F)
end)
spawn(function()
	wait(1.2)
	mem.u12 = { id = "late", s = { audio = { music = false } } }
end)
run(t + 20)
expect(got ~= nil and got.s.audio.music == false and got.p == nil, "an entry that lands during the reads is used")

-- too big for a hash map item: it goes without the records
local G = { UserId = 13 }
local big = {}
for i = 1, 4000 do
	big["item_" .. i] = true
end
from:stamp({ G }, nil)
from:leaving(G)
from:part(G, "p", { owned = big })
from:part(G, "s", { ui = { ratio = 0.5 } })
run(t + 1)
expect(mem.u13 ~= nil and mem.u13.p == nil and mem.u13.s ~= nil, "a record too big is left out; the settings still go")

-- MemoryStore unavailable: no ids, nothing read
local off = new_handoff(nil)
local d2 = off:stamp({ A }, { x = 1 })
expect(d2.handoff == nil and d2.x == 1 and not off:leaving(A), "no map: teleports carry no id")

----------------------------------------------------------------------------------------------------
print("Purchases")
local rows = {}
local gets = 0
local hold = 0 -- seconds an UpdateAsync takes
local refuse = false
local store = {
	GetAsync = function(_, k)
		gets += 1
		return rows[k]
	end,
	UpdateAsync = function(_, k, fn)
		if hold > 0 then
			wait(hold)
		end
		if refuse then
			error("DataStoreService: TooManyRequests: Too many requests, try again later. API: UpdateAsync", 0)
		end
		local v = fn(rows[k])
		if v ~= nil then
			rows[k] = v
		end
		return v
	end,
}
local warned = {}
local notified = 0
local arrive = {}
Purchases.configure({
	datastore = store,
	wait = wait,
	warn = function(text)
		table.insert(warned, text)
	end,
	notify = function()
		notified += 1
	end,
	arrived = function(p)
		return arrive[p]
	end,
})

local P = { UserId = 42 }
rows.u42 = { stars = 500, unlocks = { stars2x = true }, owned = {}, receipts = { "r1" } }
arrive[P] = { p = table.clone(rows.u42) }
spawn(function()
	Purchases.load(P)
end)
run(t + 1)
expect(gets == 0 and Purchases.stars(P) == 500 and notified == 1, "the handed-on record: no read, the client told")

-- leaving while a match's Stars are still being paid: the record follows once the payout landed
hold = 2
local settled = "unset"
spawn(function()
	Purchases.add_stars(P, 40)
end)
spawn(function()
	settled = Purchases.settle(P, 25)
end)
run(t + 1)
expect(settled == "unset", "settle waits for the write in flight")
run(t + 3)
expect(type(settled) == "table" and settled.stars == 540, "then hands on the record with the payout")
hold = 0

-- a write that failed: what this server holds isn't sure, so nothing is handed on
refuse = true
local ok_pay
spawn(function()
	ok_pay = Purchases.add_stars(P, 60)
end)
run(t + 1)
refuse = false
expect(ok_pay == false and Purchases.lost.payouts == 1 and Purchases.lost.stars == 60, "a lost payout is counted")
expect(
	warned[1] == "[Purchases] match Stars lost after every retry (TooManyRequests)",
	"and warned in the same words each time: " .. tostring(warned[1])
)
settled = "unset"
spawn(function()
	settled = Purchases.settle(P, 25)
end)
run(t + 1)
expect(settled == nil, "after a failed write the next server reads the store")
spawn(function()
	Purchases.add_stars(P, 1)
end)
run(t + 1)
spawn(function()
	settled = Purchases.settle(P, 25)
end)
run(t + 1)
expect(type(settled) == "table" and settled.stars == 541, "a write that landed makes it sure again")

-- no handoff: the store is read as before
local Q = { UserId = 43 }
rows.u43 = { stars = 7 }
spawn(function()
	Purchases.load(Q)
end)
run(t + 1)
expect(gets == 1 and Purchases.stars(Q) == 7, "no handoff: one read")
Purchases.release(Q)
expect(Purchases.settle(Q, 1) == nil, "released: nothing to hand on")

----------------------------------------------------------------------------------------------------
print("SettingsStore")
local srows = {}
local sgets = 0
local sfail = false
local sstore = {
	GetAsync = function(_, k)
		sgets += 1
		return srows[k]
	end,
	UpdateAsync = function(_, k, fn)
		if sfail then
			error(
				"502: API Services rejected request with error. Error code: 0 Reason: Too many requests, try again later.",
				0
			)
		end
		srows[k] = fn(srows[k])
		return srows[k]
	end,
}
local parted = {}
local sarrive = {}
SettingsStore.configure({
	store = sstore,
	spawn = spawn,
	wait = wait,
	now = now,
	warn = function() end,
})
SettingsStore.connect_handoff(function(p)
	return sarrive[p]
end, function(p, s)
	parted[p] = { s = s }
end)

local S1 = { UserId = 51 }
sarrive[S1] = { s = { ui = { ratio = 0.3, tips = "abc" } } }
SettingsStore.load(S1)
run(t + 1)
local d1, loaded1 = SettingsStore.peek(S1)
expect(loaded1 and d1.ui.ratio == 0.3 and sgets == 0, "the handed-on settings: no read")

SettingsStore.release(S1)
expect(parted[S1] ~= nil and parted[S1].s.ui.tips == "abc", "leaving with nothing pending: handed on at once")

-- a change still to write: handed on once the write landed
local S2 = { UserId = 52 }
SettingsStore.load(S2)
run(t + 1)
expect(sgets == 1, "no handoff: one read")
SettingsStore.set(S2, "ui", { ratio = 0.7 })
SettingsStore.release(S2)
expect(parted[S2] == nil, "not before its last write")
run(t + 1)
expect(parted[S2] ~= nil and parted[S2].s.ui.ratio == 0.7 and srows.p_52.ui.ratio == 0.7, "after it, with the change")

-- the write never lands: not known for sure
local S3 = { UserId = 53 }
SettingsStore.load(S3)
run(t + 1)
SettingsStore.set(S3, "ui", { ratio = 0.9 })
sfail = true
SettingsStore.release(S3)
run(t + 10)
sfail = false
expect(parted[S3] ~= nil and parted[S3].s == nil, "a write that failed: the next server reads the store")

-- never loaded (left at once)
local S4 = { UserId = 54 }
SettingsStore.release(S4)
expect(parted[S4] ~= nil and parted[S4].s == nil, "never loaded: nothing handed on, at once")

if fails > 0 then
	error(fails .. " failure(s)")
end
print("handoff: all ok")
