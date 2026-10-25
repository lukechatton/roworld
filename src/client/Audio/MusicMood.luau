--!strict
-- Which soundtrack mood fits the moment (AudioDirector.set_music_mood). Pure logic, polled by UIRoot:
--   title    the title screen                     wait     a public match's waiting room
--   calm     a match, no fighting                 war      fighting a nation or a player
--   victory  the match is over and we won          defeat   the match is over for us (lost, or out)
-- War: an attack between us and a nation or a player (tribes don't count — early expansion isn't a
-- war) or a nuke of ours or at our land; it lasts WAR_HOLD_S after the last sign of fighting, so the
-- music doesn't flip back and forth.

local MusicMood = {}
MusicMood.__index = MusicMood

MusicMood.WAR_HOLD_S = 40.0
local KIND_TRIBE = 1 -- Defs.KIND_TRIBE

export type Input = {
	screen: string, -- UIRoot screen: "title", "spawn", "play", "over"
	waiting: boolean, -- queued for / in a public match's waiting room
	me: number, -- our nation (0: spectating)
	alive: boolean,
	winner: number,
	fighting: boolean, -- MusicMood.fighting(state, me) this poll
}

function MusicMood.new()
	local self = setmetatable({}, MusicMood) :: any
	self._war_until = -math.huge
	return self
end

--- Any sign of war for `me` in `st` (GameState): attacks with a nation / player, nukes.
function MusicMood.fighting(st: any, me: number): boolean
	if st == nil or me == 0 then
		return false
	end
	local owners = st.owners or {}
	local function rival(id: number): boolean
		local o = owners[id]
		return id ~= 0 and id ~= me and o ~= nil and o.kind ~= KIND_TRIBE
	end
	for _, a in st.attacks or {} do
		if (a.attacker == me and rival(a.target)) or (a.target == me and rival(a.attacker)) then
			return true
		end
	end
	local tile_owner = st.tile_owner
	for _, n in st.nukes or {} do
		if n.owner == me then
			return true
		end
		if tile_owner ~= nil and tile_owner(st, n.to_tile) == me then
			return true
		end
	end
	return false
end

function MusicMood.mood(self: any, input: Input, now_s: number): string
	if input.screen == "title" then
		self._war_until = -math.huge
		return if input.waiting then "wait" else "title"
	end
	if input.me == 0 then
		return "calm" -- watching a match
	end
	if input.screen == "over" or not input.alive then
		return if input.winner ~= 0 and input.winner == input.me then "victory" else "defeat"
	end
	if input.fighting then
		self._war_until = now_s + MusicMood.WAR_HOLD_S
	end
	return if now_s < self._war_until then "war" else "calm"
end

return MusicMood
