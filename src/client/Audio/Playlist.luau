--!strict
-- The soundtrack's playlists (Assets/Soundtrack.luau): which track plays next in a mood. Pure logic
-- (no Roblox services), used by AudioDirector.
--
--   Playlist.new(manifest, rand?)       manifest = {tracks = {key = {id, length, ...}}, moods = {mood = {keys}}}
--   :pool(mood)                         the mood's playable track keys (FALLBACK moods when empty)
--   :next(mood)                         the next key: the title's opener first, then shuffled — never one
--                                       of the last few played (HISTORY, at most half the pool)
--   :after(mood)                        the mood that follows once a track of `mood` ended (victory and
--                                       defeat play once)

local Playlist = {}
Playlist.__index = Playlist

Playlist.HISTORY = 6
--- A mood without tracks borrows another's.
Playlist.FALLBACK = { wait = "calm", calm = "title", war = "calm", victory = "title", defeat = "calm" }
--- A mood that plays one track, then gives way to another.
Playlist.AFTER = { victory = "title", defeat = "calm" }
--- Plays first, once per session, the first time the mood plays.
Playlist.OPENERS = { title = true }

function Playlist.new(manifest: any, rand: (() -> number)?)
	local self = setmetatable({}, Playlist) :: any
	self.tracks = if type(manifest) == "table" and type(manifest.tracks) == "table" then manifest.tracks else {}
	self.moods = if type(manifest) == "table" and type(manifest.moods) == "table" then manifest.moods else {}
	self._rand = rand or math.random
	self._history = {} :: { string }
	self._opened = {} :: { [string]: boolean }
	return self
end

function Playlist.pool(self: any, mood: string): { string }
	local seen = {}
	local m: string? = mood
	while m ~= nil and not seen[m] do
		seen[m] = true
		local out = {}
		for _, k in self.moods[m] or {} do
			local t = self.tracks[k]
			if type(t) == "table" and type(t.id) == "string" then
				table.insert(out, k)
			end
		end
		if #out > 0 then
			return out
		end
		m = Playlist.FALLBACK[m]
	end
	return {}
end

function Playlist.next(self: any, mood: string): string?
	local pool = self:pool(mood)
	if #pool == 0 then
		return nil
	end
	local pick: string? = nil
	if Playlist.OPENERS[mood] and not self._opened[mood] then
		self._opened[mood] = true
		pick = pool[1]
	else
		local recent = {}
		local keep = math.min(Playlist.HISTORY, #pool // 2)
		for i = #self._history, math.max(1, #self._history - keep + 1), -1 do
			recent[self._history[i]] = true
		end
		local fresh = {}
		for _, k in pool do
			if not recent[k] then
				table.insert(fresh, k)
			end
		end
		if #fresh == 0 then
			fresh = pool
		end
		pick = fresh[math.clamp(math.floor(self._rand() * #fresh) + 1, 1, #fresh)]
	end
	table.insert(self._history, pick :: string)
	if #self._history > 32 then
		table.remove(self._history, 1)
	end
	return pick
end

function Playlist.after(_self: any, mood: string): string
	return Playlist.AFTER[mood] or mood
end

return Playlist
