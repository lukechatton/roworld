-- The soundtrack's logic: Playlist (the title opener first, shuffled without recent repeats,
-- fallbacks, victory / defeat playing once) and MusicMood (which mood fits: title, waiting room,
-- calm, war with a hold, victory, defeat; tribes don't make a war). The generated manifest has every
-- mood filled.
require("./prelude")
local Playlist = require("../src/client/Audio/Playlist")
local MusicMood = require("../src/client/Audio/MusicMood")

local fails = 0
local function expect(c: any, w: string)
	if c then
		print("  ok   " .. w)
	else
		fails += 1
		print("FAIL " .. w)
	end
end

local function manifest()
	local tracks = {}
	local function t(k)
		tracks[k] = { id = "rbxassetid://" .. #k, length = 120 }
		return k
	end
	return {
		tracks = tracks,
		moods = {
			title = { t("opener"), t("t2"), t("t3") },
			calm = { t("c1"), t("c2"), t("c3"), t("c4"), t("c5"), t("c6") },
			war = { t("w1"), t("w2"), t("w3"), t("w4") },
			victory = { t("v") },
			defeat = { t("d") },
			wait = {},
		},
	}
end

do
	local seed = 1
	local pl = Playlist.new(manifest(), function()
		seed = (seed * 1103515245 + 12345) % 2147483648
		return seed / 2147483648
	end)
	expect(pl:next("title") == "opener", "the title opens with its first track")
	local repeats = 0
	local last3 = {}
	for _ = 1, 200 do
		local k = pl:next("calm")
		if table.find(last3, k) then
			repeats += 1
		end
		table.insert(last3, k)
		if #last3 > 3 then
			table.remove(last3, 1)
		end
	end
	expect(repeats == 0, "calm (6 tracks) never repeats one of the last 3")
	local titles = {}
	for _ = 1, 50 do
		titles[pl:next("title")] = true
	end
	expect(titles.opener and titles.t2 and titles.t3, "then the title tracks are shuffled")
	expect(pl:next("victory") == "v" and pl:after("victory") == "title" and pl:after("defeat") == "calm", "victory / defeat play once, then title / calm")
	local w = pl:next("wait")
	expect(w ~= nil and string.sub(w, 1, 1) == "c", "an empty mood borrows its fallback (wait -> calm)")
	local empty = Playlist.new(nil)
	expect(empty:next("title") == nil and #empty:pool("war") == 0, "no manifest: nothing to play")
end

do
	local mm = MusicMood.new()
	local base = { screen = "title", waiting = false, me = 0, alive = true, winner = 0, fighting = false }
	local function with(t)
		local o = table.clone(base)
		for k, v in t do
			o[k] = v
		end
		return o
	end
	expect(mm:mood(base, 0) == "title", "title screen")
	expect(mm:mood(with({ waiting = true }), 0) == "wait", "waiting room")
	expect(mm:mood(with({ screen = "play" }), 0) == "calm", "watching a match: calm")
	expect(mm:mood(with({ screen = "play", me = 3 }), 0) == "calm", "playing, no fighting: calm")
	expect(mm:mood(with({ screen = "play", me = 3, fighting = true }), 10) == "war", "fighting: war")
	expect(mm:mood(with({ screen = "play", me = 3 }), 10 + MusicMood.WAR_HOLD_S - 1) == "war", "war holds a while")
	expect(mm:mood(with({ screen = "play", me = 3 }), 10 + MusicMood.WAR_HOLD_S + 1) == "calm", "then calm again")
	expect(mm:mood(with({ screen = "play", me = 3, alive = false }), 100) == "defeat", "eliminated: defeat")
	expect(mm:mood(with({ screen = "over", me = 3, winner = 3 }), 100) == "victory", "won: victory")
	expect(mm:mood(with({ screen = "over", me = 3, winner = 5 }), 100) == "defeat", "someone else won: defeat")

	local st = {
		owners = { [1] = { kind = 2 }, [2] = { kind = 1 }, [3] = { kind = 0 } },
		attacks = { { attacker = 1, target = 2 }, { attacker = 2, target = 1 }, { attacker = 1, target = 0 } },
		nukes = {},
		tile_owner = function(_s, t)
			return if t == 99 then 1 else 0
		end,
	}
	expect(not MusicMood.fighting(st, 1), "fighting tribes or taking empty land isn't a war")
	st.attacks[4] = { attacker = 3, target = 1 }
	expect(MusicMood.fighting(st, 1), "a nation attacking us is")
	st.attacks[4] = nil
	st.nukes[1] = { owner = 3, to_tile = 99 }
	expect(MusicMood.fighting(st, 1), "a nuke at our land is")
	expect(not MusicMood.fighting(st, 0), "spectators never fight")
end

do
	local ok, st = pcall(require, "../src/shared/Assets/Soundtrack")
	if ok and type(st) == "table" then
		local good = true
		for _, m in { "title", "wait", "calm", "war", "victory", "defeat" } do
			local list = st.moods[m]
			if list == nil or #list == 0 then
				good = false
				print("  (empty mood " .. m .. ")")
			end
			for _, k in list or {} do
				local t = st.tracks[k]
				if t == nil or type(t.id) ~= "string" or not string.match(t.id, "^rbxassetid://%d+$") or not (t.length > 30) then
					good = false
				end
			end
		end
		expect(good, "the soundtrack manifest fills every mood with uploaded tracks")
		expect(st.credit == "Music by Rodrigo Flores", "and carries the credit")
	else
		print("  skip the soundtrack manifest (not generated yet)")
	end
end

print(if fails == 0 then "soundtrack: all passed" else string.format("soundtrack: %d FAILED", fails))
if fails > 0 then
	error("soundtrack failed")
end
