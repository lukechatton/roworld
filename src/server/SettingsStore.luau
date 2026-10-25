--!strict
-- Per-player settings persistence. The original kept music / UI settings in user://settings.cfg
-- ([audio] music_enabled, [ui] ratio, labels, difficulty, tips_seen…). Roblox clients have no files, so
-- the server keeps one small table per account in a DataStore: { [section] = { [key] = value } }
-- (validated by Net/Settings: scalars and one nested level, bounded size).
--
-- Robustness:
--   * the load retries GetAsync with backoff; if it still fails, the player's stored value is never
--     overwritten with the partial session copy — every write is an UpdateAsync that merges only the
--     sections this session changed into whatever is stored (so a failed load, or the same account in
--     two servers, can never wipe untouched sections). After a failed load a changed section is
--     merged key by key: the session only knows the keys it set, and writing the section whole put a
--     returning player's `ui` back to those few keys (their tips and tutorial state gone; the error
--     report of 2026-10-05 had 8 such loads in a day);
--   * writes are coalesced (at most one per player per FLUSH_SEC), serialized per player (never two in
--     flight, so they can't land out of order), and `dirty` is cleared only when a write succeeded;
--   * leave and shutdown flush what is pending (shutdown waits for every write, bounded).
-- Without DataStore access (Studio without API access, guests) it works in memory for the session.
--
-- The Roblox services are injectable (SettingsStore.configure) so tests drive it headless.

local IS_ROBLOX = typeof(game) == "Instance"
local SettingsMod: any = if IS_ROBLOX
	then require((game :: any):GetService("ReplicatedStorage"):WaitForChild("Airfront").Net.Settings)
	else require("../shared/Net/Settings")

local SettingsStore = {}

SettingsStore.STORE_NAME = "AirfrontSettings_v1"
SettingsStore.FLUSH_SEC = 12
SettingsStore.MAX_SECTIONS = SettingsMod.MAX_SECTIONS
SettingsStore.MAX_KEYS = SettingsMod.MAX_KEYS
--- GetAsync attempts on load and the waits before each retry (20 s in all: Roblox's throttling
--- "Too many requests, try again later" clears within seconds; it was 3 attempts over 4 s).
SettingsStore.LOAD_ATTEMPTS = 5
SettingsStore.LOAD_BACKOFF = { 1.0, 3.0, 6.0, 10.0 }
--- BindToClose waits at most this long for the final writes.
SettingsStore.SHUTDOWN_WAIT_SEC = 20

type Entry = {
	data: { [string]: { [string]: any } },
	loaded: boolean,
	--- GetAsync failed every attempt: the stored value is unknown (writes still merge safely).
	load_failed: boolean,
	dirty: boolean,
	--- Sections changed this session (the only ones a write touches).
	touched: { [string]: boolean },
	--- Bumped by every change; a write clears `dirty` only if nothing changed while it ran.
	gen: number,
	writing: boolean,
	last_write: number,
	waiters: { (any) -> () },
	--- SETTINGS replies (replay): when the last one was scheduled, and whether it is still pending.
	replayed_at: number?,
	replay_pending: boolean,
}

-- Services (Roblox by default; tests inject fakes with configure()).
local deps: { [string]: any } = {}
if IS_ROBLOX then
	deps.players = game:GetService("Players")
	deps.datastores = game:GetService("DataStoreService")
	deps.spawn = task.spawn
	deps.wait = task.wait
	deps.now = os.clock
	deps.warn = warn
end

local entries: { [any]: Entry } = {}
local store: any = nil
local store_checked = false
--- Writes in flight (any player), for the shutdown flush.
local inflight = 0

--- Tests: replace the Roblox services. `store` = an object with GetAsync / UpdateAsync (the DataStore),
--- `spawn(fn, ...)`, `wait(sec)`, `now()`, `warn(text)`.
function SettingsStore.configure(d: { [string]: any })
	for k, v in d do
		deps[k] = v
	end
	if d.store ~= nil then
		store = d.store
		store_checked = true
	end
	table.clear(entries)
	inflight = 0
end

local function get_store(): any
	if store_checked then
		return store
	end
	store_checked = true
	local ds = deps.datastores
	if ds ~= nil then
		local ok, s = pcall(function()
			return ds:GetDataStore(SettingsStore.STORE_NAME)
		end)
		if ok then
			store = s
		end
	end
	return store
end

local function key_for(player: any): string?
	local uid = tonumber(player.UserId) or 0
	if uid <= 0 then
		return nil -- Studio test players / guests: memory only
	end
	return "p_" .. tostring(uid)
end

--- Returns a cleaned copy of a settings section, or nil when unusable.
function SettingsStore.clean_section(values: any): { [string]: any }?
	return SettingsMod.clean_section(values)
end

--- Outages / throttling are worth a retry; "no access" answers (Studio without API access, an
--- unpublished place) are not.
local function retryable(err: any): boolean
	local text = string.lower(tostring(err))
	return not (
		string.find(text, "403", 1, true)
		or string.find(text, "forbidden", 1, true)
		or string.find(text, "studio", 1, true)
		or string.find(text, "publish", 1, true)
	)
end

local function release_waiters(e: Entry)
	e.loaded = true
	local waiters = e.waiters
	e.waiters = {}
	for _, fn in waiters do
		deps.spawn(fn, e.data)
	end
end

--- Starts loading a player's settings (call on PlayerAdded).
function SettingsStore.load(player: any)
	if entries[player] then
		return
	end
	local e: Entry = {
		data = {},
		loaded = false,
		load_failed = false,
		dirty = false,
		touched = {},
		gen = 0,
		writing = false,
		last_write = 0,
		waiters = {},
		replayed_at = nil,
		replay_pending = false,
	}
	entries[player] = e
	deps.spawn(function()
		local key = key_for(player)
		local ds = if key then get_store() else nil
		if ds and key then
			local ok, data = false, nil
			for attempt = 1, SettingsStore.LOAD_ATTEMPTS do
				ok, data = pcall(function()
					return ds:GetAsync(key)
				end)
				if ok or entries[player] ~= e or not retryable(data) then
					break
				end
				if attempt < SettingsStore.LOAD_ATTEMPTS then
					deps.wait(SettingsStore.LOAD_BACKOFF[attempt] or 3.0)
				end
			end
			if ok then
				-- merge under anything the player changed while loading
				local loaded = SettingsMod.clean_all(data)
				for section, values in e.data do
					loaded[section] = values
				end
				e.data = loaded
			else
				e.load_failed = true
				if deps.warn then
					deps.warn(
						"[SettingsStore] could not load settings ("
							.. tostring(data)
							.. "); using defaults this session"
					)
				end
			end
		end
		release_waiters(e)
	end)
end

--- Calls fn(settings) once the player's settings are loaded (or failed to load).
function SettingsStore.when_loaded(player: any, fn: (any) -> ())
	local e = entries[player]
	if e == nil then
		SettingsStore.load(player)
		e = entries[player]
	end
	if e.loaded then
		deps.spawn(fn, e.data)
	else
		table.insert(e.waiters, fn)
	end
end

--- Store a section (cleaned; see Net/Settings). Returns false when it was refused: invalid, too many
--- sections, or the player's whole blob would exceed Settings.MAX_TOTAL_BYTES (review_code.md R2-2:
--- the stored blob is what every SETTINGS reply carries, so it stays small).
function SettingsStore.set(player: any, section: any, values: any): boolean
	local e = entries[player]
	if e == nil or not SettingsMod.valid_name(section, SettingsMod.MAX_SECTION_NAME) then
		return false
	end
	local c = SettingsMod.clean_section(values)
	if c == nil then
		return false
	end
	if e.data[section] == nil then
		local n = 0
		for _ in e.data do
			n += 1
		end
		if n >= SettingsMod.MAX_SECTIONS then
			return false
		end
	elseif SettingsMod.equal(e.data[section], c) then
		return true -- nothing changed (no write needed)
	end
	local total = #section + SettingsMod.bytes(c)
	for s, v in e.data do
		if s ~= section then
			total += #s + SettingsMod.bytes(v)
		end
	end
	if total > SettingsMod.MAX_TOTAL_BYTES then
		return false
	end
	e.data[section] = c
	e.touched[section] = true
	e.gen += 1
	e.dirty = true
	return true
end

--- A SETTINGS reply (the player's whole stored blob) goes out at most once per this many seconds per
--- player after the first one (review_code.md R2-2: HELLO used to echo it on every message).
SettingsStore.REPLAY_MIN_S = 30

--- Answer a HELLO: fn(settings) once the player's settings are loaded — the first time, and again
--- only if REPLAY_MIN_S passed since the last reply (a client script restart). Extra HELLOs while a
--- reply is pending or within the interval are dropped. Returns true when a reply was scheduled.
function SettingsStore.replay(player: any, fn: (any) -> ()): boolean
	local e = entries[player]
	if e == nil then
		SettingsStore.load(player)
		e = entries[player]
	end
	local ex = e :: Entry
	if ex.replay_pending then
		return false
	end
	local now = deps.now()
	if ex.replayed_at ~= nil and now - ex.replayed_at < SettingsStore.REPLAY_MIN_S then
		return false
	end
	ex.replayed_at = now
	ex.replay_pending = true
	SettingsStore.when_loaded(player, function(data: any)
		ex.replay_pending = false
		fn(data)
	end)
	return true
end

--- One write of the sections this session changed, merged into the stored value. Serialized per
--- player; `dirty` stays set when the write fails or the data changed meanwhile.
local function write(player: any, e: Entry)
	if e.writing or not e.dirty then
		return
	end
	local key = key_for(player)
	local ds = if key then get_store() else nil
	if ds == nil or key == nil then
		e.dirty = false
		e.last_write = deps.now()
		return
	end
	e.writing = true
	inflight += 1
	local gen = e.gen
	local sections = {}
	for section in e.touched do
		sections[section] = SettingsMod.copy_section(e.data[section])
	end
	-- (the stored sections were never seen: this session's copies hold only the keys it set)
	local blind = e.load_failed
	local uid = tonumber(player.UserId) or 0
	local ok, err = pcall(function()
		ds:UpdateAsync(key, function(old: any)
			local merged = SettingsMod.clean_all(old)
			for section, values in sections do
				local stored = merged[section]
				if blind and type(stored) == "table" then
					local both = SettingsMod.copy_section(stored)
					for k, v in values do
						both[k] = v
					end
					-- (a section too big merged is written as this session has it, as before)
					merged[section] = SettingsMod.clean_section(both) or values
				else
					merged[section] = values
				end
			end
			return SettingsMod.clean_all(merged), { uid }
		end)
	end)
	inflight -= 1
	e.writing = false
	e.last_write = deps.now()
	if ok then
		if e.gen == gen then
			e.dirty = false
		end
	elseif deps.warn then
		deps.warn("[SettingsStore] saving settings failed (will retry): " .. tostring(err))
	end
end
SettingsStore._write = write

--- Periodic flush of dirty entries (at most one write per player per FLUSH_SEC). `force` (shutdown)
--- writes everything pending now and waits for all writes, bounded by SHUTDOWN_WAIT_SEC.
function SettingsStore.flush(force: boolean?)
	local t0 = deps.now()
	for _ = 1, if force then 2 else 1 do
		local now = deps.now()
		for player, e in entries do
			if
				e.dirty
				and not e.writing
				and (force or (e.loaded and now - e.last_write >= SettingsStore.FLUSH_SEC))
			then
				deps.spawn(write, player, e)
			end
		end
		if not force then
			return
		end
		-- a second pass picks up entries whose earlier write was still in flight or failed
		while inflight > 0 and deps.now() - t0 < SettingsStore.SHUTDOWN_WAIT_SEC do
			deps.wait(0.1)
		end
	end
end

--- The player left: forget the entry and write what is pending (after a write already in flight).
function SettingsStore.release(player: any)
	local e = entries[player]
	if e == nil then
		return
	end
	entries[player] = nil
	if not e.dirty then
		return
	end
	deps.spawn(function()
		inflight += 1 -- keep a shutdown flush waiting while this one queues behind a write in flight
		local t0 = deps.now()
		while e.writing and deps.now() - t0 < 30 do
			deps.wait(0.1)
		end
		inflight -= 1
		for _ = 1, 2 do
			write(player, e)
			if not e.dirty then
				break
			end
			deps.wait(2.0)
		end
	end)
end

--- True when the player's stored settings could not be read: what this session holds is not what
--- they have saved.
function SettingsStore.load_failed(player: any): boolean
	local e = entries[player]
	return e ~= nil and e.load_failed
end

--- Debug view of a player's stored settings (dev diagnostics / tests).
function SettingsStore.peek(player: any): ({ [string]: any }?, boolean)
	local e = entries[player]
	if e == nil then
		return nil, false
	end
	return e.data, e.loaded
end

--- Tests: the raw entry.
function SettingsStore._entry(player: any): any
	return entries[player]
end

function SettingsStore.start()
	deps.spawn(function()
		while true do
			deps.wait(SettingsStore.FLUSH_SEC / 2)
			SettingsStore.flush(false)
		end
	end)
	deps.players.PlayerRemoving:Connect(SettingsStore.release)
end

return SettingsStore
