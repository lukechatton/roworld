--!strict
-- Port of scripts/audio/audio_director.gd: music + sound-effect director (client only).
--
-- - The soundtrack (Assets/Soundtrack.luau: Rodrigo Flores' Orchestral Ambients, 2026-09-27) plays by
--   mood (set_music_mood: title, wait, calm, war, victory, defeat — UIRoot picks it with MusicMood):
--   whole tracks, intro to ending, the next one (Playlist: shuffled, no recent repeats) fading in over
--   the last TRACK_OVERLAP_S; a new mood crossfades at once, except war -> calm, which lets the battle
--   track play out. Only the next track is preloaded (phones). Two music Sounds crossfade
--   (equal-power). Without the soundtrack the old looping "menu" / "war" themes play (play_theme).
-- - Music on/off is persisted per account through the Session's settings ([audio] music_enabled, as
--   the original's user://settings.cfg) and fades smoothly (0.6 s); switched-off music is paused so it
--   resumes where it was.
-- - play_sfx() plays from per-effect voice pools (MAX_SAME Sounds per effect, created once with their
--   SoundId so every play is already loaded — swapping SoundId per play made Sound.Played fire with
--   IsLoaded = false, review P2-7), at most VOICE_COUNT ringing at once, with per-sound throttling,
--   a cap on simultaneous copies and voice-steal priorities; long stings honour cooldowns (a repeat
--   plays a short accent instead).
-- - duck_music() dips the music under big moments (nuke explosions etc. duck automatically).
-- - "Music" and "SFX" SoundGroups under SoundService. Levels are the original's dB values converted
--   with Sound.Volume = 10^(dB/20) (Volume is linear gain, 1 = unity; the assets keep the WAVs' levels).
-- - Sound ids come from Assets/Audio.luau (assets agent); missing entries are skipped silently.
--   Assets/AudioExtra (the studio's other games) and then Assets/AudioUI (the interface kit, from
--   the same packs: tools/assets/upload_sfx_ui.py) replace same-named entries; a replaced sound stays as that
--   name's stand-in, played while the new one has not loaded (still in moderation, or refused).
-- - pop() is the sound of your border growing (added 2026-10-04, so taking land is heard as well as
--   seen): a run of one bubble pop whose rate follows how fast land is being taken, a little
--   higher the longer the run lasts.

local ContentProvider = game:GetService("ContentProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")

local Shared = ReplicatedStorage:WaitForChild("Airfront")
local Signal = require(Shared.Core.Signal) :: any
local Playlist = require(script.Parent:WaitForChild("Playlist")) :: any

local AudioDirector = {}
AudioDirector.__index = AudioDirector

AudioDirector.SFX_NAMES = {
	"ui_click",
	"ui_hover",
	"ui_open",
	"ui_error",
	"countdown_tick",
	-- BedWars' countdown (Assets/AudioExtra): the last five seconds and the start
	"countdown_tick_5",
	"countdown_tick_4",
	"countdown_tick_3",
	"countdown_tick_2",
	"countdown_tick_1",
	"countdown_gamestart",
	-- Airship BedWars' (AudioExtra): the waiting room opens; a spectator switches player
	"queue_start",
	"spectate_switch",
	"order_ack",
	-- the cosmetic crate opening (UI/CrateOpening; AudioExtra: BedWars / Airship BedWars). They were
	-- missing here, so the show played silent live (until 2026-09-29)
	"crate_drop",
	"crate_land",
	"crate_rattle",
	"crate_preview_common",
	"crate_preview_rare",
	"crate_preview_epic",
	"crate_preview_legendary",
	"crate_open",
	"crate_shimmer",
	"card_whoosh",
	"card_flip",
	"reveal_common",
	"reveal_rare",
	"reveal_epic",
	"reveal_legendary",
	"expand",
	"spawn_confirm",
	"attack_launch",
	"boat_launch",
	"build",
	"warship",
	"nuke_launch",
	"nuke_alarm",
	"nuke_explosion",
	"sam_launch",
	"sam_intercept",
	"shell_fire",
	"shell_hit",
	"shell_splash",
	"ship_sink",
	"under_attack",
	"ally_request",
	"alliance",
	"betrayal",
	"conquer",
	"victory",
	"defeat",
	"game_start",
	-- the interface kit (Assets/AudioUI, 2026-10-04: the interface sounds come from the studio's
	-- own packs rather than being made from scratch): ui_click / ui_hover / ui_open / ui_error are
	-- replaced there too.
	"ui_confirm",
	"ui_back",
	"ui_tab",
	"ui_locked",
	"expand_pop",
	"eliminate",
	"star_tick",
	"star_get",
	"buy_spend",
	"unlock",
}
--- Long stings: a full play at most once per cooldown (ms). A repeat inside the cooldown plays the
--- fallback accent instead ("" = stay silent), so rapid clicks never restart or stack a 2-3 s sting.
AudioDirector.COOLDOWNS = {
	attack_launch = { 1200, "order_ack" },
	boat_launch = { 1500, "order_ack" },
	warship = { 2000, "order_ack" },
	spawn_confirm = { 700, "ui_click" },
	conquer = { 2500, "" },
	betrayal = { 3000, "" },
	alliance = { 2500, "" },
	ally_request = { 1500, "" },
	under_attack = { 4000, "" },
	nuke_alarm = { 2500, "" },
	game_start = { 3000, "" },
	victory = { 10000, "" },
	defeat = { 10000, "" },
}
--- Minimum time between two starts of the same sound (ms) for short / cooldown-free sounds.
AudioDirector.THROTTLE_MS = {
	expand = 150,
	ui_hover = 45,
	ui_click = 30,
	ui_open = 60,
	ui_error = 120,
	countdown_tick = 250,
	order_ack = 80,
	build = 90,
	sam_intercept = 90,
	nuke_launch = 150,
	nuke_explosion = 180,
	sam_launch = 100,
	shell_fire = 120,
	shell_hit = 90,
	shell_splash = 90,
	ship_sink = 400,
	spectate_switch = 150,
	crate_rattle = 90,
	ui_confirm = 60,
	ui_back = 60,
	ui_tab = 40,
	ui_locked = 150,
	expand_pop = 38,
	eliminate = 250,
	star_tick = 28,
	star_get = 120,
	buy_spend = 150,
	unlock = 800,
}
AudioDirector.DEFAULT_THROTTLE_MS = 50
--- At most this many copies of one sound may ring at once (the oldest copy is restarted beyond it).
AudioDirector.MAX_SAME = {
	expand = 2,
	ui_hover = 1,
	ui_click = 2,
	order_ack = 2,
	nuke_alarm = 1,
	attack_launch = 2,
	boat_launch = 2,
	warship = 2,
	sam_launch = 3,
	shell_fire = 3,
	shell_hit = 3,
	shell_splash = 2,
	ship_sink = 2,
	under_attack = 1,
	ally_request = 1,
	victory = 1,
	defeat = 1,
	game_start = 1,
	countdown_tick = 1,
	countdown_gamestart = 1,
	queue_start = 1,
	spectate_switch = 1,
	crate_drop = 1,
	crate_land = 1,
	crate_rattle = 2,
	crate_preview_common = 1,
	crate_preview_rare = 1,
	crate_preview_epic = 1,
	crate_preview_legendary = 1,
	crate_open = 1,
	crate_shimmer = 1,
	card_whoosh = 1,
	card_flip = 1,
	reveal_common = 1,
	reveal_rare = 1,
	reveal_epic = 1,
	reveal_legendary = 1,
	ui_confirm = 2,
	ui_back = 2,
	ui_tab = 2,
	ui_locked = 1,
	-- (a pop rings 0.05 s and up to 20 start a second: a few overlap)
	expand_pop = 6,
	eliminate = 2,
	star_tick = 4,
	star_get = 2,
	buy_spend = 1,
	unlock = 1,
}
AudioDirector.DEFAULT_MAX_SAME = 3
--- Voice-steal priority when every voice is busy (default 1).
AudioDirector.PRIORITY = {
	ui_hover = 0,
	ui_click = 0,
	order_ack = 0,
	expand = 0,
	expand_pop = 0,
	eliminate = 2,
	ui_tab = 0,
	star_tick = 0,
	unlock = 2,
	shell_fire = 0,
	shell_hit = 0,
	shell_splash = 0,
	victory = 2,
	defeat = 2,
	game_start = 2,
	nuke_alarm = 2,
	nuke_explosion = 2,
	under_attack = 2,
	betrayal = 2,
	conquer = 2,
	alliance = 2,
	crate_open = 2,
	reveal_common = 2,
	reveal_rare = 2,
	reveal_epic = 2,
	reveal_legendary = 2,
}
--- Sounds that automatically duck the music: name -> {amount_db, hold_seconds}.
AudioDirector.AUTO_DUCK = {
	nuke_explosion = { 8.0, 2.5 },
	nuke_alarm = { 4.0, 1.8 },
	game_start = { 5.0, 4.0 }, -- (Airship BedWars' 6.7 s start)
	countdown_gamestart = { 5.0, 2.5 },
	under_attack = { 3.0, 1.0 },
	victory = { 14.0, 9.0 },
	defeat = { 14.0, 6.0 },
	betrayal = { 3.0, 1.5 },
	conquer = { 3.0, 1.2 },
	crate_preview_epic = { 3.0, 1.8 },
	crate_preview_legendary = { 4.0, 2.0 },
	crate_open = { 4.0, 1.5 },
	reveal_epic = { 4.0, 2.5 },
	reveal_legendary = { 6.0, 4.0 },
	unlock = { 5.0, 3.0 },
}

--- The border pops (pop()). Speeds are full-size tiles of land gained per second: at POP_SLOW and
--- below a pop every POP_SLOW / POP_RATE_MIN tiles (so slow growth thins out), rising to POP_RATE_MAX
--- pops a second at POP_FAST (measured over ten minutes of a 71-nation match: the median gain is ~60
--- tiles a second, the 95th percentile ~590).
--- The rise is slow at first (POP_CURVE): the rate went up with the log of the speed, which is
--- steepest just above POP_SLOW, so an ordinary creeping border (60 to 100 tiles a second) already
--- popped 5 to 9 times a second, too fast for slow growth (changed 2026-10-07). Now 2 a second at
--- 40, 2.4 at 60, 4 at 100, 8 at 200, 20 at 600.
AudioDirector.POP_SLOW = 40.0
AudioDirector.POP_FAST = 600.0
AudioDirector.POP_RATE_MIN = 2.0
AudioDirector.POP_RATE_MAX = 20.0
AudioDirector.POP_CURVE = 2.0
--- How quickly the speed estimate follows the gains (seconds).
AudioDirector.POP_SMOOTH_S = 0.45
--- At most this many pops for one batch of gains (10 batches a second), the second a moment later.
AudioDirector.POP_PER_BATCH = 2
AudioDirector.POP_SECOND_S = 0.05
--- The pop is one sound (expand_pop). For a day it was one of six bubble pops picked at random, each a
--- different note, which sounded random and chaotic (2026-10-04).
--- Pitch (playback speed). A run of pops warms up slowly: POP_PITCH_MIN from cold, POP_PITCH_MAX after
--- POP_WARM_S of unbroken growth; pops closer together than POP_RUN_GAP_S are one run, and a longer
--- quiet cools it again over POP_COOL_S (it never jumps back). The first version climbed an octave in
--- a second (a pentatonic ladder, a step every 0.2 s) and sat up to 25% higher towards a win: far
--- too high, and it reached its top pitch far too fast (2026-10-04).
AudioDirector.POP_PITCH_MIN = 0.8
AudioDirector.POP_PITCH_MAX = 1.1
AudioDirector.POP_WARM_S = 15.0
AudioDirector.POP_COOL_S = 6.0
AudioDirector.POP_RUN_GAP_S = 0.7
--- Each pop is this much off the run's pitch, either way (just enough not to sound stamped out).
AudioDirector.POP_JITTER = 0.012
--- The whole run sits a touch higher the closer the player is to winning (x1 to x1.05).
AudioDirector.POP_PROGRESS_LIFT = 0.05
--- Level: a small bite POP_DB_MIN, a big one (POP_BIG tiles banked) POP_DB_MAX.
AudioDirector.POP_DB_MIN = -9.0
AudioDirector.POP_DB_MAX = -3.0
AudioDirector.POP_BIG = 60.0

AudioDirector.VOICE_COUNT = 18

--- While one of these rings, the border pops hold off (seconds). 2026-10-17: a first elimination
--- seemed to play no kill sound, because you usually eliminate someone by taking their
--- last land, a big bite that sets off the loudest pops (two at a time, -3 dB, the file levelled 2 dB
--- above the kill sound's) right as the kill sound plays, and the run carries on over it.
AudioDirector.HUSH_POPS = { eliminate = 0.65 }

--- Fetched first, before every other sound and the title's 4 MB music track (the sounds a match needs
--- the moment it happens; the kill sound sat near the end of ~120 fetches, behind the crate show's).
AudioDirector.PRELOAD_FIRST = {
	"eliminate",
	"expand_pop",
	"attack_launch",
	"under_attack",
	"nuke_alarm",
	"nuke_launch",
	"nuke_explosion",
	"conquer",
	"spawn_confirm",
	"order_ack",
	"game_start",
	"countdown_gamestart",
}
AudioDirector.CROSSFADE_S = 2.0
--- Soundtrack: the next track fades in over the last seconds of the one playing.
AudioDirector.TRACK_OVERLAP_S = 2.0
--- Soundtrack: crossfade into a new mood (into war a little faster).
AudioDirector.MOOD_FADE_S = 3.0
AudioDirector.WAR_FADE_S = 2.0
--- Soundtrack: a track that hasn't loaded after this long (an asset still in moderation, a network
--- failure) is skipped and not picked again this session.
AudioDirector.TRACK_LOAD_TIMEOUT_S = 12.0
AudioDirector.TOGGLE_FADE_S = 0.6
AudioDirector.DUCK_ATTACK_DB_PER_S = 60.0
AudioDirector.DUCK_RELEASE_DB_PER_S = 6.0
AudioDirector.SILENT_DB = -80.0
AudioDirector.SETTINGS_SECTION = "audio"
AudioDirector.SETTINGS_KEY = "music_enabled"
--- [audio] pops_enabled: the border pops can be switched off on their own (a Settings toggle, added
--- 2026-10-07). Missing = on.
AudioDirector.SETTINGS_POPS_KEY = "pops_enabled"
--- [audio] music_volume: the music volume slider in Settings (added 2026-10-21), 0..1, missing = 1
--- (the level it always had). The music's gain is its square, so the
--- slider's middle sounds about half as loud rather than barely quieter.
AudioDirector.SETTINGS_VOLUME_KEY = "music_volume"
--- bind_settings holds the music silent until the saved [audio] section arrives (so a player who
--- switched music off never hears the menu theme start), at most this long.
AudioDirector.SETTINGS_WAIT_S = 2.5

local function db_to_volume(db: number): number
	if db <= AudioDirector.SILENT_DB then
		return 0
	end
	return 10 ^ (db / 20)
end

local function move_toward(from: number, to: number, delta: number): number
	if math.abs(to - from) <= delta then
		return to
	end
	return from + math.sign(to - from) * delta
end

local function now_ms(): number
	return os.clock() * 1000
end

--- Once per asset: a sound that did not load is named in the output (the Creator Dashboard's error
--- report only says "Failed to load sound: <reason>", without the asset).
local _reported_fail: { [string]: boolean } = {}
local function report_fetch(content: string, status: Enum.AssetFetchStatus)
	if status ~= Enum.AssetFetchStatus.Success and not _reported_fail[content] then
		_reported_fail[content] = true
		warn(string.format("[Audio] could not load %s (%s)", content, status.Name))
	end
end

type Voice = { sound: Sound, name: string, started: number }

function AudioDirector.new(autoplay_theme: string?)
	local self: any = setmetatable({}, AudioDirector)
	self.music_enabled_changed = Signal.new() -- (on: boolean)
	--- Base level of the music relative to its group (the themes are mastered at -16/-18 LUFS).
	self.music_volume_db = -6.0
	--- The player's music level (Settings slider, 0..1; MUSIC_LEVEL_GAIN of it scales the music).
	self._music_level = 1.0
	self._volume_user_set = false
	--- Base level of all sound effects relative to their group.
	self.sfx_volume_db = 0.0
	self.pops_enabled_changed = Signal.new() -- (on: boolean)
	self._music_on = true
	self._user_set = false
	--- The border pops (pop / pop_once) are on, and whether the player chose that this session.
	self._pops_on = true
	self._pops_user_set = false
	--- Seconds left to wait for the saved music setting (0 = not waiting); see bind_settings.
	self._settings_hold_s = 0.0
	self._session = nil :: any
	self._music_streams = {} :: { [string]: { [string]: any } }
	self._sfx_streams = {} :: { [string]: { [string]: any } }
	self._current = nil :: Sound?
	self._outgoing = nil :: Sound?
	self._current_theme = ""
	self._fade_t = 1.0
	self._fade_len = AudioDirector.CROSSFADE_S
	self._master_gain = 1.0
	self._duck_db = 0.0
	self._duck_target_db = 0.0
	self._duck_hold_s = 0.0
	self._voices = {} :: { Voice }
	--- Music sounds paused because music was switched off (Sound.IsPaused is just "not playing").
	self._toggle_paused = {} :: { [Sound]: boolean }
	self._last_start_ms = {} :: { [string]: number }
	self._last_full_ms = {} :: { [string]: number }
	--- pop(): land banked for pops, the smoothed speed (tiles / s), the last batch's time, when the
	--- run began and when it last popped
	self._pop_debt = 0.0
	self._pop_speed = 0.0
	self._pop_last = -1e9
	self._pop_run_last = -1e9
	--- os.clock() until which the border pops hold off (HUSH_POPS)
	self._pop_hush_until = -1e9
	self._pop_heat = 0.0
	--- Soundtrack (nil when Assets/Soundtrack is missing): the mood asked for, the mood the next
	--- track comes from (victory / defeat give way after one track), the track playing, the next one.
	self._playlist = nil :: any
	self._requested = ""
	self._pool_mood = ""
	self._track = nil :: string?
	self._track_len = 0.0
	self._track_started = 0.0
	self._next = nil :: { mood: string, key: string }?

	local root = Instance.new("Folder")
	root.Name = "AirfrontAudio"
	self._root = root
	self._music_group = self:_group("Music")
	self._sfx_group = self:_group("SFX")
	self._player_a = self:_make_sound("MusicA", self._music_group)
	self._player_b = self:_make_sound("MusicB", self._music_group)
	self._player_a.Looped = true
	self._player_b.Looped = true
	for _, p in { self._player_a, self._player_b } do
		p.Ended:Connect(function()
			-- (a soundtrack track that ended before the overlap started it: the next one now)
			if p == self._current and self._track ~= nil then
				self:_advance()
			end
		end)
	end
	--- effect name -> its own voices (Sounds pre-bound to the effect's asset)
	self._pool = {} :: { [string]: { Voice } }
	root.Parent = SoundService
	self:_load_streams()
	self:_make_voices()
	self._conn = RunService.Heartbeat:Connect(function(dt: number)
		self:_process(dt)
	end)
	-- which sound: Roblox's "Failed to load sound: <reason>" names no asset (370K a day of "User is not
	-- authorized to access Asset" from 2026-10-22 while every id is the group's and our preload reports
	-- none failing): after one, name ours that are still not loaded (_name_failed)
	local okl, LogService = pcall(function()
		return game:GetService("LogService")
	end)
	if okl and LogService ~= nil then
		self._log_conn = LogService.MessageOut:Connect(function(msg: string, kind: Enum.MessageType)
			if kind == Enum.MessageType.MessageError and string.find(msg, "Failed to load sound", 1, true) then
				self:_on_load_failure(msg)
			end
		end)
	end
	local theme = if autoplay_theme == nil then "menu" else autoplay_theme
	if theme ~= "" then
		if self._playlist ~= nil and #self._playlist:pool("title") > 0 then
			self:set_music_mood("title")
		else
			self:play_theme(theme)
		end
	end
	return self
end

--- Persist music on/off through the Session's settings (the section arrives from the server shortly
--- after boot; an explicit toggle before that wins).
function AudioDirector.bind_settings(self: any, session: any)
	self._session = session
	local function apply()
		if not self._user_set then
			local ok, section = pcall(function()
				return session:load_settings(AudioDirector.SETTINGS_SECTION)
			end)
			if ok and type(section) == "table" and type(section[AudioDirector.SETTINGS_KEY]) == "boolean" then
				self:_set_music(section[AudioDirector.SETTINGS_KEY], false)
			end
		end
		if not self._pops_user_set then
			local ok, section = pcall(function()
				return session:load_settings(AudioDirector.SETTINGS_SECTION)
			end)
			if ok and type(section) == "table" and type(section[AudioDirector.SETTINGS_POPS_KEY]) == "boolean" then
				self:_set_pops(section[AudioDirector.SETTINGS_POPS_KEY], false)
			end
		end
		if not self._volume_user_set then
			local ok, section = pcall(function()
				return session:load_settings(AudioDirector.SETTINGS_SECTION)
			end)
			local v = if ok and type(section) == "table" then section[AudioDirector.SETTINGS_VOLUME_KEY] else nil
			if type(v) == "number" and v == v then
				self:_set_music_volume(v, false)
			end
		end
		-- the saved setting is known: the music starts now (or stays off)
		self:_release_hold()
	end
	if session.settings_ready == true then
		apply()
	else
		-- Saved settings arrive from the server a moment after boot. Hold the music silent until then
		-- (bounded): the theme then fades in, or stays off for a player who switched it off.
		self._settings_hold_s = AudioDirector.SETTINGS_WAIT_S
		self._master_gain = 0.0
		self:_apply_music_volume()
	end
	if session.settings_loaded then
		session.settings_loaded:Connect(apply)
	end
end

-- ---------------------------------------------------------------------------------------------
-- Music
-- ---------------------------------------------------------------------------------------------

--- The soundtrack's mood (see the header). Asking for the mood already asked for does nothing.
function AudioDirector.set_music_mood(self: any, mood: string)
	if mood == self._requested then
		return
	end
	local old = self._requested
	self._requested = mood
	local pl = self._playlist
	if pl == nil or #pl:pool(mood) == 0 then
		self:play_theme(if mood == "title" or mood == "wait" then "menu" else "war")
		return
	end
	self._pool_mood = mood
	self._next = nil
	if old == "war" and mood == "calm" and self._track ~= nil then
		return -- the battle track plays out; the next one is calm
	end
	local key = pl:next(mood)
	if key ~= nil then
		self:_start_track(key, if mood == "war" then AudioDirector.WAR_FADE_S else AudioDirector.MOOD_FADE_S)
	end
end

function AudioDirector.music_mood(self: any): string
	return self._requested
end

--- The soundtrack track playing (its key in Assets/Soundtrack), or nil.
function AudioDirector.current_track(self: any): string?
	return self._track
end

function AudioDirector._start_track(self: any, key: string, fade_s: number)
	local t = self._playlist.tracks[key]
	if t == nil then
		return
	end
	self._track = key
	self._track_len = tonumber(t.length) or 0.0
	self._track_started = os.clock()
	self._current_theme = "track:" .. key
	self:_crossfade_to(t.id, fade_s, false)
	-- the one after it, fetched in the background while this one plays
	local m = self._playlist:after(self._pool_mood)
	local nk = self._playlist:next(m)
	self._next = if nk ~= nil then { mood = m, key = nk } else nil
	if nk ~= nil then
		local id = self._playlist.tracks[nk].id
		task.spawn(function()
			local s = Instance.new("Sound")
			s.SoundId = id
			pcall(function()
				ContentProvider:PreloadAsync({ s }, report_fetch)
			end)
			s:Destroy()
		end)
	end
end

--- The track playing is ending: the next one (victory / defeat give way to their AFTER mood).
function AudioDirector._advance(self: any)
	local pl = self._playlist
	if pl == nil then
		return
	end
	self._pool_mood = pl:after(self._pool_mood)
	local nx = self._next
	local key = if nx ~= nil and nx.mood == self._pool_mood then nx.key else pl:next(self._pool_mood)
	self._next = nil
	if key ~= nil then
		self:_start_track(key, AudioDirector.TRACK_OVERLAP_S)
	else
		self._track = nil -- nothing left to play
	end
end

--- Crossfade the music players to asset `id` from its start.
function AudioDirector._crossfade_to(self: any, id: string, fade_s: number, looped: boolean)
	local current: Sound? = self._current
	self._fade_len = math.max(0.01, fade_s)
	local incoming: Sound = if current == self._player_a then self._player_b else self._player_a
	incoming:Stop()
	self._toggle_paused[incoming] = nil
	self._outgoing = if current ~= nil and self:_active(current) then current else nil
	self._current = incoming
	incoming.SoundId = id
	incoming.Looped = looped
	incoming.Volume = 0
	incoming.TimePosition = 0
	incoming:Play()
	if self._master_gain <= 0.0 and not self._music_on then
		incoming:Pause()
		self._toggle_paused[incoming] = true
	end
	self._fade_t = 0.0
	self:_apply_music_volume()
end

--- Crossfade to a looping theme ("menu" or "war"). Calling it with the playing theme does nothing.
function AudioDirector.play_theme(self: any, theme_name: string, crossfade_s: number?)
	local stream = self._music_streams[theme_name]
	if stream == nil then
		return
	end
	self._track = nil
	local current: Sound? = self._current
	if theme_name == self._current_theme and current ~= nil and self:_active(current) then
		return
	end
	self._current_theme = theme_name
	self._fade_len = math.max(0.01, crossfade_s or AudioDirector.CROSSFADE_S)
	local incoming: Sound = if current == self._player_a then self._player_b else self._player_a
	if incoming == self._outgoing and self:_active(incoming) and incoming.SoundId == stream.id then
		-- switching back to the theme that is still fading out: reverse the fade, no restart
		self._outgoing = current
		self._current = incoming
		self._fade_t = 1.0 - self._fade_t
		return
	end
	self:_crossfade_to(stream.id, self._fade_len, true)
end

--- Fade the music out completely (the theme is forgotten; play_theme starts it again).
function AudioDirector.stop_music(self: any, fade_s: number?)
	if self._current == nil then
		return
	end
	if self._outgoing ~= nil then
		self._outgoing:Stop()
		self._toggle_paused[self._outgoing] = nil
	end
	self._outgoing = self._current
	self._current = nil
	self._current_theme = ""
	self._track = nil
	self._requested = ""
	self._fade_len = math.max(0.01, fade_s or 1.0)
	self._fade_t = 0.0
end

function AudioDirector.current_theme(self: any): string
	return self._current_theme
end

function AudioDirector.set_music_enabled(self: any, on: boolean)
	self._user_set = true
	self:_set_music(on, true)
	self:_release_hold()
end

--- End the boot hold (see bind_settings). With music on, the current theme starts as it would have
--- without the hold: from the top, with the usual fade-in.
function AudioDirector._release_hold(self: any)
	if self._settings_hold_s <= 0.0 then
		return
	end
	self._settings_hold_s = 0.0
	local cur: Sound? = self._current
	if self._music_on and cur ~= nil and self._outgoing == nil and cur.IsPlaying then
		cur.TimePosition = 0
		self._fade_t = 0.0
		self._master_gain = 1.0
		self:_apply_music_volume()
	end
end

--- True while the music waits for the saved setting (tests / diagnostics).
function AudioDirector.is_holding(self: any): boolean
	return self._settings_hold_s > 0.0
end

function AudioDirector._set_music(self: any, on: boolean, save: boolean)
	if on == self._music_on then
		return
	end
	self._music_on = on
	if on then
		for p in self._toggle_paused do
			p:Resume()
		end
		table.clear(self._toggle_paused)
	end
	if save and self._session ~= nil then
		local session = self._session
		pcall(function()
			local section = session:load_settings(AudioDirector.SETTINGS_SECTION)
			section[AudioDirector.SETTINGS_KEY] = on
			session:save_settings(AudioDirector.SETTINGS_SECTION, section)
		end)
	end
	self.music_enabled_changed:Fire(on)
end

function AudioDirector.is_music_enabled(self: any): boolean
	return self._music_on
end

--- The gain of slider position `v` (0..1): its square (0.5 -> 0.25, about -12 dB).
function AudioDirector.level_gain(v: number): number
	local c = math.clamp(tonumber(v) or 1.0, 0.0, 1.0)
	return c * c
end

--- The player's music level (0..1). `save`: write it to the saved [audio] section (the slider does
--- when the finger lifts, not at every step of a drag).
function AudioDirector.set_music_volume(self: any, v: number, save: boolean?)
	self._volume_user_set = true
	self:_set_music_volume(v, save == true)
end

function AudioDirector._set_music_volume(self: any, v: number, save: boolean)
	local c = math.clamp(tonumber(v) or 1.0, 0.0, 1.0)
	self._music_level = c
	self:_apply_music_volume()
	if save and self._session ~= nil then
		local session = self._session
		pcall(function()
			local section = session:load_settings(AudioDirector.SETTINGS_SECTION)
			section[AudioDirector.SETTINGS_VOLUME_KEY] = math.floor(c * 100 + 0.5) / 100
			session:save_settings(AudioDirector.SETTINGS_SECTION, section)
		end)
	end
end

function AudioDirector.music_volume(self: any): number
	return self._music_level
end

--- The border pops on or off (saved like the music setting).
function AudioDirector.set_pops_enabled(self: any, on: boolean)
	self._pops_user_set = true
	self:_set_pops(on, true)
end

function AudioDirector._set_pops(self: any, on: boolean, save: boolean)
	if on == self._pops_on then
		return
	end
	self._pops_on = on
	if not on then
		-- nothing banked plays when they come back on
		self._pop_debt = 0.0
		self._pop_speed = 0.0
		self._pop_heat = 0.0
	end
	if save and self._session ~= nil then
		local session = self._session
		pcall(function()
			local section = session:load_settings(AudioDirector.SETTINGS_SECTION)
			section[AudioDirector.SETTINGS_POPS_KEY] = on
			session:save_settings(AudioDirector.SETTINGS_SECTION, section)
		end)
	end
	self.pops_enabled_changed:Fire(on)
end

function AudioDirector.is_pops_enabled(self: any): boolean
	return self._pops_on
end

--- Convenience for a music hotkey / HUD toggle. Returns the new state.
function AudioDirector.toggle_music(self: any): boolean
	self:set_music_enabled(not self._music_on)
	return self._music_on
end

--- Temporarily lower the music by amount_db for `seconds`, then let it recover smoothly.
--- Overlapping calls keep the deepest amount and the longest hold.
function AudioDirector.duck_music(self: any, amount_db: number, seconds: number)
	local target = -math.abs(amount_db)
	if self._duck_hold_s > 0.0 then
		self._duck_target_db = math.min(self._duck_target_db, target)
		self._duck_hold_s = math.max(self._duck_hold_s, seconds)
	else
		self._duck_target_db = target
		self._duck_hold_s = seconds
	end
end

-- ---------------------------------------------------------------------------------------------
-- Sound effects
-- ---------------------------------------------------------------------------------------------

--- Play a one-shot effect by name (see SFX_NAMES). pitch_jitter is a fraction (0.05 = +/-5 %).
--- Cues replaced by another sound. attack_launch (the original's taiko + brass sting) → the short
--- order tap: launching an attack gets a quiet acknowledgement instead of the sting
--- (2026-09-26).
AudioDirector.REPLACE = { attack_launch = "order_ack" }
--- Per-sound level trims in dB (the conquest sting was a little loud, 2026-09-26).
AudioDirector.TRIM_DB = { conquer = -6.0 }

function AudioDirector.play_sfx(
	self: any,
	sfx_name: string,
	volume_db: number?,
	pitch_jitter: number?,
	pitch: number?
)
	sfx_name = AudioDirector.REPLACE[sfx_name] or sfx_name
	local stream = self._sfx_streams[sfx_name]
	if stream == nil then
		return
	end
	local vol_db = volume_db or 0.0
	local jitter = pitch_jitter or 0.0
	local now = now_ms()
	local cd = AudioDirector.COOLDOWNS[sfx_name]
	if cd ~= nil then
		local last = self._last_full_ms[sfx_name]
		if last ~= nil and now - last < cd[1] then
			local fallback = cd[2]
			if fallback ~= "" and fallback ~= sfx_name then
				self:play_sfx(fallback, vol_db, jitter)
			end
			return
		end
		self._last_full_ms[sfx_name] = now
	else
		local gap = AudioDirector.THROTTLE_MS[sfx_name] or AudioDirector.DEFAULT_THROTTLE_MS
		local last = self._last_start_ms[sfx_name]
		if last ~= nil and now - last < gap then
			return
		end
	end
	self._last_start_ms[sfx_name] = now
	local v: Voice? = self:_pick_voice(sfx_name)
	if v == nil then
		return
	end
	if not v.sound.IsLoaded then
		-- not here yet (or it never will be: refused by moderation): the sound it replaced
		local stand_in = sfx_name .. "~"
		if self._pool[stand_in] ~= nil then
			local sv: Voice? = self:_pick_voice(stand_in)
			if sv ~= nil and sv.sound.IsLoaded then
				v = sv
				stream = self._sfx_streams[stand_in]
			end
		end
	end
	local s = (v :: Voice).sound
	s:Stop()
	s.Volume = db_to_volume(self.sfx_volume_db + vol_db + (AudioDirector.TRIM_DB[sfx_name] or 0.0))
	local j = math.abs(jitter)
	s.PlaybackSpeed = if pitch ~= nil
		then math.clamp(pitch, 0.25, 4.0)
		elseif j > 0.0 then math.clamp(1.0 + (math.random() * 2 - 1) * j, 0.25, 4.0)
		else 1.0
	s.TimePosition = if stream.region ~= nil then stream.region.Min else 0
	s:Play()
	local hush = AudioDirector.HUSH_POPS[sfx_name]
	if hush ~= nil then
		self._pop_hush_until = math.max(self._pop_hush_until, os.clock() + hush)
	end
	local played: Voice = v :: Voice
	played.started = now
	local d = AudioDirector.AUTO_DUCK[sfx_name]
	if d ~= nil then
		self:duck_music(d[1], d[2])
	end
end

function AudioDirector.has_sfx(self: any, sfx_name: string): boolean
	return self._sfx_streams[sfx_name] ~= nil
end

--- Pops a second at a land-gain speed of `speed` full-size tiles a second (see POP_*).
function AudioDirector.pop_rate(speed: number): number
	local A = AudioDirector
	if speed <= A.POP_SLOW then
		return A.POP_RATE_MIN * math.max(speed, 0) / A.POP_SLOW
	end
	local k = math.min(math.log(speed / A.POP_SLOW) / math.log(A.POP_FAST / A.POP_SLOW), 1)
	return A.POP_RATE_MIN + (A.POP_RATE_MAX - A.POP_RATE_MIN) * k ^ A.POP_CURVE
end

--- The local player's border grew by `tiles` (full-size tiles) in this batch of changes; `progress`
--- (0..1) is how close they are to winning. Banks the land and plays the pops it has earned.
function AudioDirector.pop(self: any, tiles: number, progress: number?)
	if tiles <= 0 or not self._pops_on or self._sfx_streams["expand_pop"] == nil then
		return
	end
	local A = AudioDirector
	local now = os.clock()
	local dt = math.clamp(now - self._pop_last, 0.1, 3.0)
	self._pop_last = now
	self._pop_speed += (tiles / dt - self._pop_speed) * (1 - math.exp(-dt / A.POP_SMOOTH_S))
	local speed = self._pop_speed
	-- land per pop: fixed at slow speeds, speed / rate above
	local per = if speed <= A.POP_SLOW then A.POP_SLOW / A.POP_RATE_MIN else speed / A.pop_rate(speed)
	self._pop_debt = math.min(self._pop_debt + tiles, math.max(A.POP_BIG, per * 2))
	if self._pop_debt < per then
		return
	end
	local n = math.min(math.floor(self._pop_debt / per), A.POP_PER_BATCH)
	local bite = self._pop_debt
	self._pop_debt = math.min(self._pop_debt - n * per, per)
	-- the run warms up while the pops keep coming, and cools in the quiet between runs
	local quiet = now - self._pop_run_last
	self._pop_run_last = now
	if quiet <= A.POP_RUN_GAP_S then
		self._pop_heat = math.min(1, self._pop_heat + quiet / A.POP_WARM_S)
	else
		self._pop_heat = math.max(0, self._pop_heat - (quiet - A.POP_RUN_GAP_S) / A.POP_COOL_S)
	end
	local lift = 1 + A.POP_PROGRESS_LIFT * math.clamp(progress or 0, 0, 1)
	local pitch = A.pop_pitch(self._pop_heat) * lift
	local db = A.POP_DB_MIN + (A.POP_DB_MAX - A.POP_DB_MIN) * math.sqrt(math.clamp(bite / A.POP_BIG, 0, 1))
	local function strike()
		if os.clock() < self._pop_hush_until then
			return -- (the kill sound rings: HUSH_POPS)
		end
		self:play_sfx("expand_pop", db, 0, pitch * (1 + (math.random() * 2 - 1) * A.POP_JITTER))
	end
	strike()
	if n >= 2 then
		task.delay(A.POP_SECOND_S, strike)
	end
end

--- One pop, outside any run (picking a start).
function AudioDirector.pop_once(self: any)
	if not self._pops_on then
		return
	end
	self:play_sfx("expand_pop", AudioDirector.POP_DB_MAX, 0, 1.0)
end

--- The playback speed of a pop in a run that is `heat` (0 cold .. 1 warm) along.
function AudioDirector.pop_pitch(heat: number): number
	local A = AudioDirector
	return A.POP_PITCH_MIN + (A.POP_PITCH_MAX - A.POP_PITCH_MIN) * math.clamp(heat, 0, 1)
end


--- A voice of `sfx_name`'s own pool: restart its oldest copy beyond MAX_SAME, else an idle one. When
--- VOICE_COUNT effects already ring, the least important, oldest other voice is stopped — never a
--- more important one (then nil: the new sound is dropped).
function AudioDirector._pick_voice(self: any, sfx_name: string): Voice?
	local pool = self._pool[sfx_name]
	if pool == nil then
		return nil
	end
	local limit = AudioDirector.MAX_SAME[sfx_name] or AudioDirector.DEFAULT_MAX_SAME
	local same = 0
	local oldest_same: Voice? = nil
	local idle: Voice? = nil
	for _, v in pool do
		if v.sound.IsPlaying then
			same += 1
			if oldest_same == nil or v.started < oldest_same.started then
				oldest_same = v
			end
		elseif idle == nil then
			idle = v
		end
	end
	if (same >= limit or idle == nil) and oldest_same ~= nil then
		return oldest_same
	end
	local total = 0
	local victim: Voice? = nil
	local victim_prio = 99
	for _, v in self._voices do
		if v.sound.IsPlaying then
			total += 1
			local prio = AudioDirector.PRIORITY[v.name] or 1
			if prio < victim_prio or (prio == victim_prio and victim ~= nil and v.started < victim.started) then
				victim = v
				victim_prio = prio
			end
		end
	end
	if total >= AudioDirector.VOICE_COUNT and victim ~= nil then
		if victim_prio > (AudioDirector.PRIORITY[sfx_name] or 1) then
			return nil
		end
		victim.sound:Stop()
	end
	return idle
end

--- One pool per effect, each Sound bound to its asset (and sprite region) once, up front.
function AudioDirector._make_voices(self: any)
	local names = table.clone(AudioDirector.SFX_NAMES)
	for _, name in AudioDirector.SFX_NAMES do
		-- (the sound a newer one replaced: its stand-in while that one isn't loaded)
		if self._sfx_streams[name .. "~"] ~= nil then
			table.insert(names, name .. "~")
		end
	end
	for _, name in names do
		local stream = self._sfx_streams[name]
		if stream == nil then
			continue
		end
		local pool = {}
		local copies = if string.sub(name, -1) == "~"
			then 1
			else AudioDirector.MAX_SAME[name] or AudioDirector.DEFAULT_MAX_SAME
		for i = 1, copies do
			local s = self:_make_sound(string.format("Sfx_%s_%d", name, i), self._sfx_group)
			s.SoundId = stream.id
			if stream.region ~= nil then
				s.PlaybackRegionsEnabled = true
				s.PlaybackRegion = stream.region
			end
			local v: Voice = { sound = s, name = name, started = 0 }
			table.insert(pool, v)
			table.insert(self._voices, v)
		end
		self._pool[name] = pool
	end
end

-- ---------------------------------------------------------------------------------------------
-- Internals
-- ---------------------------------------------------------------------------------------------

function AudioDirector._process(self: any, dt: number)
	-- soundtrack: the next track fades in over the end of this one
	local cur: Sound? = self._current
	if
		self._track ~= nil
		and cur ~= nil
		and self._music_on
		and not cur.IsLoaded
		and os.clock() - self._track_started > AudioDirector.TRACK_LOAD_TIMEOUT_S
	then
		-- never loaded: drop it from the playlist and go on
		self._playlist.tracks[self._track :: string] = nil
		self:_advance()
		cur = self._current
	end
	if self._track ~= nil and cur ~= nil and cur.IsPlaying then
		local len = if cur.TimeLength > 0 then cur.TimeLength else self._track_len
		if len > AudioDirector.TRACK_OVERLAP_S and cur.TimePosition >= len - AudioDirector.TRACK_OVERLAP_S then
			self:_advance()
		end
	end
	if self._fade_t < 1.0 then
		self._fade_t = math.min(1.0, self._fade_t + dt / self._fade_len)
		if self._fade_t >= 1.0 and self._outgoing ~= nil then
			self._outgoing:Stop()
			self._toggle_paused[self._outgoing] = nil
			self._outgoing = nil
		end
	end
	if self._duck_hold_s > 0.0 then
		self._duck_hold_s -= dt
		self._duck_db = move_toward(self._duck_db, self._duck_target_db, AudioDirector.DUCK_ATTACK_DB_PER_S * dt)
	else
		self._duck_target_db = 0.0
		self._duck_db = move_toward(self._duck_db, 0.0, AudioDirector.DUCK_RELEASE_DB_PER_S * dt)
	end
	local target = if self._music_on then 1.0 else 0.0
	if self._settings_hold_s > 0.0 then
		if self._settings_hold_s > dt then
			self._settings_hold_s -= dt
			target = 0.0
		else
			self:_release_hold() -- no settings in time (offline / slow server): start anyway
		end
	end
	self._master_gain = move_toward(self._master_gain, target, dt / AudioDirector.TOGGLE_FADE_S)
	self:_apply_music_volume()
end

function AudioDirector._apply_music_volume(self: any)
	local g_in = math.sin(self._fade_t * math.pi * 0.5) * self._master_gain
	local g_out = math.cos(self._fade_t * math.pi * 0.5) * self._master_gain
	if self._current ~= nil then
		self._current.Volume = self:_gain_volume(g_in)
	end
	if self._outgoing ~= nil then
		self._outgoing.Volume = self:_gain_volume(g_out)
	end
	-- pause silent music while it is switched off (keeps its position for when it comes back)
	if not self._music_on and self._master_gain <= 0.0 then
		self:_pause_silent(self._player_a)
		self:_pause_silent(self._player_b)
	end
end

function AudioDirector._pause_silent(self: any, p: Sound)
	if p.IsPlaying then
		p:Pause()
		self._toggle_paused[p] = true
	end
end

--- Playing, or paused only because music is switched off.
function AudioDirector._active(self: any, s: Sound): boolean
	return s.IsPlaying or self._toggle_paused[s] == true
end

function AudioDirector._gain_volume(self: any, g: number): number
	if g <= 0.0005 then
		return 0
	end
	-- linear_to_db(g) + music_volume_db + duck_db, as a linear Sound.Volume, times the player's level
	return g * db_to_volume(self.music_volume_db + self._duck_db) * AudioDirector.level_gain(self._music_level)
end

function AudioDirector._group(self: any, name: string): SoundGroup
	local g = Instance.new("SoundGroup")
	g.Name = name
	g.Volume = 1
	g.Parent = self._root
	return g
end

function AudioDirector._make_sound(self: any, name: string, group: SoundGroup): Sound
	local s = Instance.new("Sound")
	s.Name = name
	s.SoundGroup = group
	s.Volume = 0
	s.Parent = self._root
	return s
end

function AudioDirector._load_streams(self: any)
	local ok, manifest = pcall(function()
		local m = Shared:FindFirstChild("Assets") and Shared.Assets:FindFirstChild("Audio")
		return if m then (require :: any)(m) else nil
	end)
	if not ok or type(manifest) ~= "table" then
		return
	end
	local preload = {}
	-- the soundtrack: only the title's opener up front (each track is ~4 MB; the next one is fetched
	-- while one plays)
	local ok_st, st = pcall(function()
		local m = Shared:FindFirstChild("Assets") and Shared.Assets:FindFirstChild("Soundtrack")
		return if m then (require :: any)(m) else nil
	end)
	if ok_st and type(st) == "table" and type(st.tracks) == "table" and next(st.tracks) ~= nil then
		self._playlist = Playlist.new(st)
		local opener = (st.moods and st.moods.title or {})[1]
		local t = opener and st.tracks[opener]
		if t ~= nil then
			table.insert(preload, t.id)
		end
	end
	for theme_name, e in manifest.music or {} do
		if type(e) == "table" and type(e.id) == "string" then
			self._music_streams[theme_name] = { id = e.id, length = e.length }
			if self._playlist == nil then
				table.insert(preload, e.id)
			end
		end
	end
	-- Assets/AudioExtra (sounds from the studio's other games) replaces same-named entries
	local ok_x, extra = pcall(function()
		local m = Shared:FindFirstChild("Assets") and Shared.Assets:FindFirstChild("AudioExtra")
		return if m then (require :: any)(m) else nil
	end)
	local extra_sfx = if ok_x and type(extra) == "table" and type(extra.sfx) == "table" then extra.sfx else {}
	-- Assets/AudioUI (the interface kit) replaces both
	local ok_u, ui = pcall(function()
		local m = Shared:FindFirstChild("Assets") and Shared.Assets:FindFirstChild("AudioUI")
		return if m then (require :: any)(m) else nil
	end)
	local ui_sfx = if ok_u and type(ui) == "table" and type(ui.sfx) == "table" then ui.sfx else {}
	local function stream_of(e: any): any
		if type(e) ~= "table" then
			return nil
		end
		if type(e.id) == "string" then
			return { id = e.id, length = e.length }
		elseif type(e.sprite) == "string" and type(e.start) == "number" and type(e.stop) == "number" then
			return { id = e.sprite, region = NumberRange.new(e.start, e.stop), length = e.length }
		end
		return nil
	end
	for _, name in AudioDirector.SFX_NAMES do
		local older = stream_of(extra_sfx[name] or (manifest.sfx and manifest.sfx[name]))
		local newer = stream_of(ui_sfx[name])
		local chosen = newer or older
		if chosen ~= nil then
			self._sfx_streams[name] = chosen
			table.insert(preload, chosen.id)
		end
		if newer ~= nil and older ~= nil then
			self._sfx_streams[name .. "~"] = older
			table.insert(preload, older.id)
		end
	end
	-- Fetch every sound in the background so the first play of each is instant: the ones a match needs
	-- the moment they happen first (PRELOAD_FIRST), then the rest (each id once). Always through
	-- throwaway copies: v89 (2026-10-17) preloaded the first ones' own voices instead, and in some
	-- sessions that preload failed ("Failed to load sound: User is not authorized to access Asset",
	-- from a few hundred a day to ~48,000; our "[Audio] could not load" named exactly those 12 sounds,
	-- ~53,000 a day), so the kill sound it meant to make sure of was among the ones failing.
	local first, seen = {}, {}
	for _, name in AudioDirector.PRELOAD_FIRST do
		local st = self._sfx_streams[name]
		if st ~= nil and not seen[st.id] then
			seen[st.id] = true
			table.insert(first, st.id)
		end
	end
	local rest = {}
	for _, id in preload do
		if not seen[id] then
			seen[id] = true
			table.insert(rest, id)
		end
	end
	task.spawn(function()
		for _, batch in { first, rest } do
			local list = {}
			for _, id in batch do
				local s = Instance.new("Sound")
				s.SoundId = id
				table.insert(list, s)
			end
			pcall(function()
				ContentProvider:PreloadAsync(list, report_fetch)
			end)
			for _, s in list do
				s:Destroy()
			end
		end
	end)
end

--- Seconds after a "Failed to load sound" before looking at which of ours never loaded (one that is
--- merely slow has loaded by then).
AudioDirector.FAILURE_CHECK_S = 4.0
local _named_fail: { [string]: boolean } = {}
local _foreign_reported = false

--- The engine said a sound failed to load: once the moment has passed, warn the asset of each of ours
--- that still isn't loaded (once per asset a session), or, when all of ours are loaded, that the
--- failing one isn't the game's (once a session). Several failures in a moment make one check.
function AudioDirector._on_load_failure(self: any, msg: string)
	-- ("Failed to load sound rbxassetid://123: User is not authorized to access Asset.": the dashboard
	-- shows it without the id)
	self._fail_reason = string.sub(string.match(msg, "Failed to load sound.-: (.*)$") or msg, 1, 80)
	self._fail_ids = self._fail_ids or {}
	local id = string.match(msg, "rbxassetid://%d+")
	if id ~= nil then
		self._fail_ids[id] = true
	end
	if self._fail_check then
		return
	end
	self._fail_check = true
	task.delay(AudioDirector.FAILURE_CHECK_S, function()
		self._fail_check = false
		local root = self._root
		if root == nil or root.Parent == nil then
			return
		end
		local ours = 0
		for _, s in root:GetDescendants() do
			if s:IsA("Sound") and s.SoundId ~= "" and not s.IsLoaded then
				ours += 1
				local id = s.SoundId
				if not _named_fail[id] then
					_named_fail[id] = true
					-- (no quote or comma in the text: the error report keeps it whole)
					warn(string.format("[Audio] did not load %s %s after %s", id, s.Name, tostring(self._fail_reason)))
				end
			end
		end
		if ours == 0 and not _foreign_reported then
			_foreign_reported = true
			local ids = {}
			for id in self._fail_ids or {} do
				table.insert(ids, id)
			end
			table.sort(ids)
			warn(
				"[Audio] a sound outside the game's failed to load: "
					.. table.concat(ids, " ", 1, math.min(#ids, 3))
					.. " "
					.. tostring(self._fail_reason)
			)
		end
		self._fail_ids = {}
	end)
end

function AudioDirector.destroy(self: any)
	if self._conn then
		self._conn:Disconnect()
	end
	if self._log_conn then
		self._log_conn:Disconnect()
		self._log_conn = nil
	end
	self._root:Destroy()
end

return AudioDirector
