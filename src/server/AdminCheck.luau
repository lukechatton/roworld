--!strict
-- Who is a game admin: the game's owner, or rank ADMIN_RANK+ in the owning group (everyone in a Studio
-- playtest). ServerMain gives admins the AF_Admin attribute and tells them which players are bots.
--
-- 2026-11-01: every join on every server asked Roblox twice (GetRankInGroup, then GetGroupInfoAsync for
-- the group's owner), and a failed check was tried 4 times in 12 s. At ~3,000 joins a minute at peak
-- that ran past Roblox's limit for these calls ("number of API requests/minute exceeded limit for
-- HTTP API throttle. Please don't issue more than 4400 API requests/minute with server scripts": at
-- least 70,000 failed checks a day in the error report). Now the group's owner is looked up once per
-- server, and a player's answer is shared by every server for CACHE_S (a MemoryStore hash map): a
-- player is asked about about once per CACHE_S, however many servers they pass through. A failed check
-- waits RETRY_S before the next try.
--
--   AdminCheck.new(deps) -> check
--     deps = {
--       studio = boolean,                          -- RunService:IsStudio(): everyone is an admin
--       group = boolean,                           -- the game belongs to a group (CreatorType)
--       creator_id = number,                       -- game.CreatorId
--       rank = function(player) -> number,         -- GetRankInGroup(creator_id); may error
--       owner = function() -> number?,             -- the group owner's user id; may error
--       cache_get = function(key) -> any,          -- the shared answers (nil: none); may error
--       cache_set = function(key, value, ttl_s),   -- may error
--     }
--   check:is_admin(player) -> boolean   yields; errors while the answer can't be known
local AdminCheck = {}
AdminCheck.__index = AdminCheck

--- Group rank that counts as a game admin (254 = Admin, 255 = Owner in a default group).
AdminCheck.ADMIN_RANK = 254
--- How long every server trusts a player's answer (a promotion or demotion shows within this).
AdminCheck.CACHE_S = 6 * 3600
--- The waits before the second and third tries of a failed check (then it gives up: not an admin).
AdminCheck.RETRY_S = { 15, 60 }

function AdminCheck.new(deps: { [string]: any })
	local self = setmetatable({}, AdminCheck)
	self.deps = deps
	self._owner = nil :: number?
	self._owner_known = false
	self.asked = 0 -- rank lookups made (tests)
	return self
end

--- The group owner's user id (looked up once per server; nil: the group has none).
function AdminCheck._group_owner(self: any): number?
	if not self._owner_known then
		local id = self.deps.owner()
		self._owner = if type(id) == "number" then id else nil
		self._owner_known = true
	end
	return self._owner
end

function AdminCheck.is_admin(self: any, player: any): boolean
	local d = self.deps
	if d.studio then
		return true
	end
	local uid = tonumber(player.UserId) or 0
	if not d.group then
		return uid == d.creator_id
	end
	local key = tostring(uid)
	if d.cache_get ~= nil then
		local ok, v = pcall(d.cache_get, key)
		if ok and (v == 1 or v == 0) then
			return v == 1
		end
	end
	self.asked += 1
	local yes = d.rank(player) >= AdminCheck.ADMIN_RANK
	if not yes then
		-- the group's owner, whatever their role's rank
		yes = self:_group_owner() == uid
	end
	if d.cache_set ~= nil then
		pcall(d.cache_set, key, if yes then 1 else 0, AdminCheck.CACHE_S)
	end
	return yes
end

return AdminCheck
