-- code-fixer: settings persistence end to end (review_code.md #2, #7, #12).
--   Net/Settings sanitizer (nested tables, limits, hostile input), Session.save_settings / load_settings
--   (tables survive, throttled sends, deep copies), SettingsStore against a fake DataStore (load retries,
--   failed load never overwrites stored sections, merge-on-write, failed writes stay dirty, serialized
--   writes, no-op writes skipped).
-- Run: .bin/lune run tests/fix_settings.luau
require("./prelude")
local Settings = require("../src/shared/Net/Settings")
local Session = require("../src/client/Session")
local SettingsStore = require("../src/server/SettingsStore")
local Protocol = require("../src/shared/Net/Protocol")

local fails = 0
local function check(cond: any, what: string)
	if cond then
		print("  ok   " .. what)
	else
		fails += 1
		print("FAIL " .. what)
	end
end

print("Net/Settings sanitizer")
do
	local c = Settings.clean_section({
		ratio = 0.4,
		labels = true,
		difficulty = 2,
		name = "hello",
		tips_seen = { expand = true, ratio = true, bad_value = { deeper = true }, ["bad key"] = true },
		long = string.rep("x", 65),
		nan = 0 / 0,
		huge = 1e13,
		["bad-key"] = true,
		[5] = true,
		fn = print,
	}) :: any
	check(c.ratio == 0.4 and c.labels == true and c.difficulty == 2 and c.name == "hello", "scalars kept")
	check(
		type(c.tips_seen) == "table" and c.tips_seen.expand == true and c.tips_seen.ratio == true,
		"one nested level of scalars kept (tips_seen)"
	)
	check(c.tips_seen.bad_value == nil and c.tips_seen["bad key"] == nil, "nested tables / bad names inside dropped")
	check(
		c.long == nil and c.nan == nil and c.huge == nil and c["bad-key"] == nil and c[5] == nil and c.fn == nil,
		"invalid entries dropped"
	)
	-- limits
	local big = {}
	for i = 1, 100 do
		big["k" .. i] = i
	end
	local cb = Settings.clean_section(big) :: any
	local n = 0
	for _ in cb do
		n += 1
	end
	check(n == Settings.MAX_KEYS, ("at most MAX_KEYS valid keys (%d)"):format(n))
	local nested = {}
	for i = 1, 100 do
		nested["t" .. i] = true
	end
	local cn = Settings.clean_section({ tips_seen = nested }) :: any
	n = 0
	for _ in cn.tips_seen do
		n += 1
	end
	check(n == Settings.MAX_NESTED_KEYS, ("nested tables capped at MAX_NESTED_KEYS (%d)"):format(n))
	-- hostile: a huge table of invalid keys is not walked in full, and valid keys behind it are not reached
	local hostile = {}
	for i = 1, 200000 do
		hostile[i] = true
	end
	local t0 = os.clock()
	local ch = Settings.clean_section(hostile) :: any
	local ms = (os.clock() - t0) * 1000
	check(next(ch) == nil and ms < 5, ("200k invalid keys: bounded walk (%.3f ms)"):format(ms))
	-- nested tables share the examined budget
	local many = {}
	for i = 1, 50 do
		local sub = {}
		for j = 1, 50 do
			sub["x" .. j] = true
		end
		many["s" .. i] = sub
	end
	local cm = Settings.clean_section(many) :: any
	local leaves = 0
	for _, sub in cm do
		for _ in sub do
			leaves += 1
		end
	end
	check(leaves <= Settings.MAX_EXAMINED, ("nested walk shares the budget (%d leaves kept)"):format(leaves))
	-- cycles / self references can't recurse (one nested level only)
	local cyc: any = { a = true }
	cyc.self = cyc
	local cc = Settings.clean_section(cyc) :: any
	check(cc.a == true and type(cc.self) == "table" and cc.self.self == nil, "cyclic table cleaned without recursion")
	-- output never aliases input
	local src = { tips_seen = { expand = true } }
	local out = Settings.clean_section(src) :: any
	check(out.tips_seen ~= src.tips_seen, "cleaned copy does not alias the input")
	-- whole blobs
	local all = Settings.clean_all({
		ui = { ratio = 0.5 },
		audio = { music_enabled = false },
		["bad section"] = { x = 1 },
		waytoolongsectionname = { x = 1 },
		junk = 5,
	})
	check(
		all.ui ~= nil
			and all.audio ~= nil
			and all["bad section"] == nil
			and all.waytoolongsectionname == nil
			and all.junk == nil,
		"clean_all"
	)
	check(Settings.clean_section("nope") == nil and next(Settings.clean_all(nil)) == nil, "non-tables")
	check(Settings.equal({ a = 1, t = { x = true } }, { a = 1, t = { x = true } }), "equal: same")
	check(
		not Settings.equal({ a = 1, t = { x = true } }, { a = 1, t = { x = true, y = true } }),
		"equal: nested differs"
	)
end

print("Session.save_settings / load_settings")
do
	local clock = 0
	local sent = {}
	local s = Session.new({
		now = function()
			return clock
		end,
		net = {
			connected = true,
			send = function(op, ...)
				table.insert(sent, table.pack(op, ...))
			end,
			listen = function() end,
		},
	})
	s.threaded = false
	s:save_settings("ui", { ratio = 0.4, tips_seen = { expand = true } })
	check(#sent == 1 and sent[1][1] == Protocol.OP.SETTING and sent[1][2] == "ui", "first save is sent at once")
	check(
		type(sent[1][3].tips_seen) == "table" and sent[1][3].tips_seen.expand == true,
		"tips_seen travels to the server"
	)
	local l = s:load_settings("ui")
	check(type(l.tips_seen) == "table" and l.tips_seen.expand == true, "load_settings returns tips_seen")
	l.tips_seen.ratio = true
	check(s:load_settings("ui").tips_seen.ratio == nil, "load_settings returns a deep copy")
	-- throttle: rapid saves → one leading send, the latest value trails
	for i = 1, 5 do
		clock += 0.05
		s:save_settings("ui", { ratio = 0.4, tips_seen = { expand = true, n = i } })
	end
	check(#sent == 1, ("rapid saves inside the gap are held (%d sent)"):format(#sent))
	clock += 0.5
	s:process(0.016)
	check(#sent == 2 and sent[2][3].tips_seen.n == 5, "the latest value is sent after the gap")
	s:process(0.016)
	check(#sent == 2, "nothing more to send")
	-- another section is independent
	s:save_settings("audio", { music_enabled = false })
	check(#sent == 3 and sent[3][2] == "audio", "other sections are not held by the ui throttle")
	-- server copy arriving later never overwrites what was saved this session; bad data is cleaned
	s:_on_settings({ ui = { ratio = 0.9 }, extra = { a = 1, bad = { x = { y = 1 } } }, ["bad name"] = {} })
	check(s:load_settings("ui").ratio == 0.4, "local (newer) sections win over the server's copy")
	check(s:load_settings("extra").a == 1 and s:load_settings("extra").bad.x == nil, "server sections cleaned")
	check(s.settings_ready == true, "settings_ready")
	-- invalid section names are refused
	s:save_settings("bad name", { a = 1 })
	check(next(s:load_settings("bad name")) == nil, "invalid section name refused")
end

print("Session: saves made before the server's copy arrives are merged, never replace it")
do
	local clock = 0
	local sent = {}
	local s = Session.new({
		now = function()
			return clock
		end,
		net = {
			connected = true,
			sends_settings = true, -- the Roblox transport: SETTINGS follow HELLO
			send = function(op, ...)
				table.insert(sent, table.pack(op, ...))
			end,
			listen = function() end,
		},
	})
	-- a difficulty chip clicked in the first second: UICtx saves its (defaults-only) [ui] table
	s:save_settings("ui", { difficulty = 2 })
	s:save_settings("audio", { music_enabled = false })
	clock += 1
	s:process(0.016)
	check(#sent == 0, "nothing is sent before the saved settings arrived")
	s:_on_settings({
		ui = { difficulty = 0, ratio = 0.3, tips_seen = { expand = true, city = true } },
		audio = { music_enabled = true },
		other = { x = 1 },
	})
	local ui = s:load_settings("ui")
	check(
		ui.difficulty == 2 and ui.ratio == 0.3 and ui.tips_seen.city == true,
		"early [ui] change merged over the stored section"
	)
	check(
		s:load_settings("audio").music_enabled == false and s:load_settings("other").x == 1,
		"other sections: newer local value / stored value"
	)
	local by = {}
	for _, m in sent do
		by[m[2]] = m[3]
	end
	check(
		#sent == 2 and by.ui ~= nil and by.ui.tips_seen.expand == true and by.ui.difficulty == 2,
		"the merged sections are sent once the copy is in"
	)
	check(by.other == nil, "untouched sections are not re-sent")
end

print("SettingsStore: fake DataStore")
local clock = 0.0
local warnings = {}
local function fake_store()
	local ds = { data = {}, get_fail = 0, update_fail = 0, gets = 0, updates = 0, in_update = 0, max_in_update = 0 }
	function ds:GetAsync(key)
		self.gets += 1
		if self.get_fail > 0 then
			self.get_fail -= 1
			error("502: DataStore request failed")
		end
		return self.data[key]
	end
	function ds:UpdateAsync(key, fn)
		self.updates += 1
		self.in_update += 1
		self.max_in_update = math.max(self.max_in_update, self.in_update)
		if self.yield_update then
			coroutine.yield()
		end
		self.in_update -= 1
		if self.update_fail > 0 then
			self.update_fail -= 1
			error("503: throttled")
		end
		local v, ids = fn(self.data[key])
		self.data[key] = v
		self.last_ids = ids
		return v
	end
	return ds
end
local waits = 0
local store = fake_store()
SettingsStore.configure({
	store = store,
	spawn = function(fn, ...)
		fn(...)
	end,
	wait = function(sec)
		waits += 1
		clock += sec
	end,
	now = function()
		return clock
	end,
	warn = function(t)
		table.insert(warnings, t)
	end,
})
do
	-- 1) normal load + merge write of the touched section only
	store.data["p_1"] = { audio = { music_enabled = false }, ui = { ratio = 0.3, tips_seen = { expand = true } } }
	local p1 = { UserId = 1 }
	SettingsStore.load(p1)
	local data, loaded = SettingsStore.peek(p1)
	check(
		loaded and data.audio.music_enabled == false and data.ui.tips_seen.expand == true,
		"stored settings load (incl. tips_seen)"
	)
	local got
	SettingsStore.when_loaded(p1, function(d)
		got = d
	end)
	check(got ~= nil and got.ui.ratio == 0.3, "when_loaded fires with the data")
	SettingsStore.set(p1, "ui", { ratio = 0.3, tips_seen = { expand = true } })
	check(SettingsStore._entry(p1).dirty == false, "saving identical values does not mark dirty")
	SettingsStore.set(p1, "ui", { ratio = 0.6, tips_seen = { expand = true, city = true } })
	clock += 20
	SettingsStore.flush(false)
	check(
		store.data["p_1"].ui.ratio == 0.6 and store.data["p_1"].ui.tips_seen.city == true,
		"write stores the ui section (with tips_seen)"
	)
	check(store.data["p_1"].audio.music_enabled == false, "untouched sections are kept")
	check(store.last_ids ~= nil and store.last_ids[1] == 1, "UpdateAsync tags the user id")
	check(SettingsStore._entry(p1).dirty == false, "dirty cleared after a successful write")

	-- 2) load fails every attempt → defaults this session, stored value never overwritten
	store.data["p_2"] =
		{ audio = { music_enabled = false }, ui = { ratio = 0.25, tutorial = "done", tips_seen = { expand = true } } }
	store.get_fail = 99
	local p2 = { UserId = 2 }
	waits = 0
	SettingsStore.load(p2)
	local d2, l2 = SettingsStore.peek(p2)
	check(l2 and next(d2) == nil, "failed load releases waiters with defaults")
	check(
		store.gets >= 1 + SettingsStore.LOAD_ATTEMPTS and waits == SettingsStore.LOAD_ATTEMPTS - 1,
		("GetAsync retried %d times with backoff"):format(SettingsStore.LOAD_ATTEMPTS)
	)
	check(SettingsStore._entry(p2).load_failed == true, "load_failed flagged")
	store.get_fail = 0
	SettingsStore.set(p2, "ui", { ratio = 0.9 }) -- the player moves the attack slider
	clock += 20
	SettingsStore.flush(false)
	check(store.data["p_2"].ui.ratio == 0.9, "the changed section is saved")
	check(
		store.data["p_2"].ui.tutorial == "done" and store.data["p_2"].ui.tips_seen.expand == true,
		"and the keys of it this session never saw are kept (a returning player's tutorial state, their tips)"
	)
	check(SettingsStore.load_failed(p2) and not SettingsStore.load_failed(p1), "load_failed(player)")
	check(
		store.data["p_2"].audio ~= nil and store.data["p_2"].audio.music_enabled == false,
		"music_enabled=false survives a failed load (was wiped before)"
	)

	-- 2b) a "no access" answer (Studio without API access) is not retried
	local real_get = store.GetAsync
	store.GetAsync = function(self, key)
		self.gets += 1
		error("502: API Services rejected request with error. HTTP 403 (Forbidden)")
	end
	local gets0 = store.gets
	local p2b = { UserId = 22 }
	SettingsStore.load(p2b)
	check(
		store.gets == gets0 + 1 and SettingsStore._entry(p2b).load_failed,
		"403 / no API access: one attempt, defaults"
	)
	store.GetAsync = real_get

	-- 3) a failed write keeps the entry dirty and is retried later
	store.update_fail = 1
	SettingsStore.set(p2, "audio", { music_enabled = true })
	clock += 20
	SettingsStore.flush(false)
	check(
		SettingsStore._entry(p2).dirty == true and store.data["p_2"].audio.music_enabled == false,
		"failed write stays dirty"
	)
	SettingsStore.flush(false)
	check(store.updates > 0 and SettingsStore._entry(p2).dirty == true, "no retry before FLUSH_SEC")
	clock += 20
	SettingsStore.flush(false)
	check(
		SettingsStore._entry(p2).dirty == false and store.data["p_2"].audio.music_enabled == true,
		"retried write succeeds"
	)

	-- 4) writes are serialized per player: a flush while one is in flight doesn't start another
	store.yield_update = true
	local p3 = { UserId = 3 }
	SettingsStore.load(p3)
	SettingsStore.set(p3, "ui", { ratio = 0.1 })
	local e3 = SettingsStore._entry(p3)
	local co = coroutine.create(SettingsStore._write)
	coroutine.resume(co, p3, e3) -- first write, suspended inside UpdateAsync
	check(e3.writing == true, "write in flight")
	SettingsStore.set(p3, "ui", { ratio = 0.2 }) -- changes meanwhile
	clock += 20
	local before = store.updates
	SettingsStore.flush(false)
	check(store.updates == before and store.max_in_update == 1, "no second write while one is in flight")
	store.yield_update = false
	coroutine.resume(co)
	check(e3.writing == false and e3.dirty == true, "data changed during the write → still dirty")
	clock += 20
	SettingsStore.flush(false)
	check(e3.dirty == false and store.data["p_3"].ui.ratio == 0.2, "the newer value is written next")

	-- 5) leave writes what is pending; guests / Studio players stay in memory
	SettingsStore.set(p3, "ui", { ratio = 0.33 })
	SettingsStore.release(p3)
	check(store.data["p_3"].ui.ratio == 0.33 and SettingsStore.peek(p3) == nil, "release flushes the pending section")
	local guest = { UserId = -1 }
	SettingsStore.load(guest)
	SettingsStore.set(guest, "ui", { ratio = 0.5 })
	local u = store.updates
	SettingsStore.flush(true)
	check(store.updates == u and SettingsStore._entry(guest).dirty == false, "guests: memory only")

	-- 6) SETTING payloads: section count cap, hostile sizes are cheap
	local p4 = { UserId = 4 }
	SettingsStore.load(p4)
	for i = 1, 20 do
		SettingsStore.set(p4, "s" .. i, { a = i })
	end
	local secs = 0
	for _ in (SettingsStore.peek(p4)) do
		secs += 1
	end
	check(secs == Settings.MAX_SECTIONS, ("at most MAX_SECTIONS sections per player (%d)"):format(secs))
	local hostile = {}
	for i = 1, 100000 do
		hostile["bad key " .. i] = i
	end
	local t0 = os.clock()
	for _ = 1, 90 do
		SettingsStore.set(p4, "s1", hostile)
	end
	local ms = (os.clock() - t0) * 1000
	check(ms < 20, ("90 hostile 100k-key SETTINGs cost %.2f ms (bounded walk)"):format(ms))
end

if fails > 0 then
	error(fails .. " failures")
end
print("fix_settings ok")
