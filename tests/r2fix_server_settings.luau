-- r2-code-fixer: review_code.md R2-2 — the settings a client can make the server store and echo.
--   * Net/Settings size caps: the worst-case blob (build/critic/settings_size.luau) is trimmed to at most
--     MAX_TOTAL_BYTES; real [ui] / [audio] settings pass through unchanged;
--   * SettingsStore.set refuses sections that would take a player's blob past the cap;
--   * SettingsStore.replay (ServerMain's HELLO answer): one SETTINGS reply per player, a HELLO flood gets
--     no more until REPLAY_MIN_S passed; nothing while a reply is pending.
-- Run: .bin/lune run tests/r2fix_server_settings.luau
require("./prelude")
local Settings = require("../src/shared/Net/Settings")
local SettingsStore = require("../src/server/SettingsStore")

local fails = 0
local function check(cond: any, what: string)
	if cond then
		print("  ok   " .. what)
	else
		fails += 1
		print("FAIL " .. what)
	end
end

local function entries_of(blob: any): number
	local n = 0
	for _, sec in blob do
		for _, v in sec do
			if type(v) == "table" then
				for _ in v do
					n += 1
				end
			else
				n += 1
			end
		end
	end
	return n
end

-- the critic's worst case: 8 sections x 32 keys x 32 nested 30-char keys with 64-byte strings
local function worst_blob()
	local long = string.rep("x", 64)
	local blob = {}
	for s = 1, 8 do
		local sec = {}
		for k = 1, 32 do
			local nested = {}
			for j = 1, 32 do
				nested[string.format("k%030d", j)] = long
			end
			sec[string.format("key%029d", k)] = nested
		end
		blob[string.format("sect%012d", s)] = sec
	end
	return blob
end

-- what the game really stores: UICtx's [ui] table (+ Coach tips_seen) and AudioDirector's [audio]
local function real_ui()
	return {
		ratio = 0.35,
		labels = true,
		difficulty = 1,
		leaderboard_open = false,
		attacks_open = true,
		feed_open = true,
		help_seen = true,
		range_mode = "auto",
		ui_scale = 1.0,
		last_mode = "solo",
		shift_hint = false,
		radial_hint = true,
		build_hotkeys = true,
		camera_speed = 1.0,
		reduce_motion = false,
		tips_seen = {
			expand = true,
			ratio = true,
			build = true,
			attack = true,
			boat = true,
			nuke = true,
			alliance = true,
			contact = true,
		},
	}
end

print("Net/Settings size caps")
do
	local clean = Settings.clean_all(worst_blob())
	local bytes = Settings.bytes(clean)
	local secs = 0
	for _ in clean do
		secs += 1
	end
	print(
		("  worst case kept: %d sections, %d leaf entries, %d bytes (was 1488 entries ~139 KB)"):format(
			secs,
			entries_of(clean),
			bytes
		)
	)
	check(
		bytes <= Settings.MAX_TOTAL_BYTES,
		("worst-case blob <= MAX_TOTAL_BYTES (%d <= %d)"):format(bytes, Settings.MAX_TOTAL_BYTES)
	)
	for name, sec in clean do
		check(Settings.bytes(sec) <= Settings.MAX_SECTION_BYTES, ("section %s <= MAX_SECTION_BYTES"):format(name))
		break
	end
	local one = Settings.clean_section(worst_blob().sect000000000001)
	check(
		Settings.bytes(one) <= Settings.MAX_SECTION_BYTES,
		("one worst section trimmed to %d bytes"):format(Settings.bytes(one))
	)
	-- real settings are untouched
	local ui = real_ui()
	local cu = Settings.clean_section(ui)
	check(Settings.equal(cu, ui), ("real [ui] section kept exactly (%d bytes)"):format(Settings.bytes(cu)))
	local all = Settings.clean_all({ ui = real_ui(), audio = { music_enabled = false } })
	check(
		Settings.equal(all.ui, real_ui()) and all.audio.music_enabled == false,
		"real blob ([ui] + [audio]) kept exactly by clean_all"
	)
	-- a legit-looking blob right under the cap stays, one byte over drops the extra section
	local big = {}
	for i = 1, 30 do
		big[("k%02d"):format(i)] = string.rep("y", 60) -- 3 + 60 bytes each
	end
	local cb = Settings.clean_section(big)
	check(Settings.bytes(cb) == 30 * 63, "sections under the cap are not trimmed")
end

print("SettingsStore.set: per-player total cap")
local clock = 0.0
local store = { data = {} }
function store:GetAsync(key)
	return self.data[key]
end
function store:UpdateAsync(key, fn)
	local v = fn(self.data[key])
	self.data[key] = v
	return v
end
local spawned = {}
SettingsStore.configure({
	store = store,
	spawn = function(fn, ...)
		fn(...)
	end,
	wait = function(sec)
		clock += sec
	end,
	now = function()
		return clock
	end,
	warn = function(_t) end,
})
do
	local p = { UserId = 7 }
	SettingsStore.load(p)
	check(SettingsStore.set(p, "ui", real_ui()) == true, "real [ui] accepted")
	check(SettingsStore.set(p, "audio", { music_enabled = false }) == true, "real [audio] accepted")
	local worst = worst_blob()
	local accepted = 0
	for name, sec in worst do
		if SettingsStore.set(p, string.sub(name, 1, 16), sec) then
			accepted += 1
		end
	end
	local data = SettingsStore.peek(p)
	local bytes = Settings.bytes(data)
	check(
		bytes <= Settings.MAX_TOTAL_BYTES,
		("stored blob stays <= cap (%d bytes, %d hostile sections accepted)"):format(bytes, accepted)
	)
	check(Settings.equal(data.ui, real_ui()) and data.audio.music_enabled == false, "real sections survive the flood")
	clock += 20
	SettingsStore.flush(false)
	local stored = store.data["p_7"]
	check(stored ~= nil and Settings.bytes(stored) <= Settings.MAX_TOTAL_BYTES, "the DataStore copy stays <= cap")
	-- a DataStore value written before the cap (oversized) is capped when it loads
	store.data["p_8"] = worst_blob()
	store.data["p_8"].ui = real_ui()
	local p8 = { UserId = 8 }
	SettingsStore.load(p8)
	local d8 = SettingsStore.peek(p8)
	check(
		Settings.bytes(d8) <= Settings.MAX_TOTAL_BYTES,
		("an oversized stored blob is capped on load (%d bytes)"):format(Settings.bytes(d8))
	)
end

print("SettingsStore.replay: one SETTINGS reply per player (HELLO flood)")
do
	local p = { UserId = 9 }
	SettingsStore.load(p)
	SettingsStore.set(p, "ui", real_ui())
	local replies = 0
	local reply_bytes = 0
	local function send(data)
		replies += 1
		reply_bytes += Settings.bytes(data)
	end
	-- first HELLO
	check(SettingsStore.replay(p, send) == true and replies == 1, "first HELLO: settings sent once")
	-- a flood: 90 HELLOs per second for 10 s
	for _ = 1, 10 do
		for _ = 1, 90 do
			SettingsStore.replay(p, send)
		end
		clock += 1
	end
	check(replies == 1, ("900 more HELLOs in 10 s: no extra SETTINGS (%d total)"):format(replies))
	clock += SettingsStore.REPLAY_MIN_S
	SettingsStore.replay(p, send)
	check(replies == 2, "after REPLAY_MIN_S a restarted client gets its settings again")
	-- worst case bandwidth: one capped blob per REPLAY_MIN_S
	local worst_rate = Settings.MAX_TOTAL_BYTES / SettingsStore.REPLAY_MIN_S
	print(("  worst-case SETTINGS echo: %.2f KB/s per client (was ~12.3 MB/s)"):format(worst_rate / 1024))
	check(worst_rate < 1024, "echo bound < 1 KB/s per client")

	-- a HELLO before the player's settings loaded: one pending reply, repeats dropped
	local waiting: any = nil
	SettingsStore.configure({
		store = {
			GetAsync = function(_self, _key)
				waiting = coroutine.running()
				coroutine.yield()
				return { ui = { ratio = 0.5 } }
			end,
		},
		spawn = function(fn, ...)
			local co = coroutine.create(fn)
			coroutine.resume(co, ...)
		end,
		wait = function(sec)
			clock += sec
		end,
		now = function()
			return clock
		end,
		warn = function(_t) end,
	})
	local q = { UserId = 10 }
	local got = 0
	SettingsStore.load(q)
	check(SettingsStore.replay(q, function()
		got += 1
	end) == true, "HELLO while loading: reply scheduled")
	for _ = 1, 50 do
		SettingsStore.replay(q, function()
			got += 1
		end)
	end
	check(got == 0, "nothing sent before the load finished")
	coroutine.resume(waiting)
	check(got == 1, ("exactly one reply once loaded (%d)"):format(got))
end

if fails > 0 then
	error(("r2fix_server_settings: %d failure(s)"):format(fails))
end
print("r2fix_server_settings ok")
