--!strict
-- Parties on a hub server (experimental, staging only; 2026-10-10: for joining a match with
-- a friend): players who play public matches together. The leader picks the match; everyone in
-- the party who is on the title screen goes with them, in one teleport, and a team game puts the
-- party on one team (Core/Teams).
-- (Parties are what keep friends together in team games.)
--
-- A party lives on one server, so its members are on the same hub:
--   * an invite goes to anyone on this server (friends first in the list); a friend elsewhere gets a
--     Roblox game invite (SocialService:PromptGameInvite, client side) and lands here;
--   * players in one Roblox party (Player.PartyId) arrive together and are put in one party here;
--   * after a match, the match server sends everyone back to a hub in one teleport with who was in
--     which party (`arrived`), and the party is made again there.
--
--   Party.new(deps)   deps = { send(player, state), now() -> seconds, log(text)?, prefix: string? (this
--                     server's: party keys travel between servers) }
--   party:invite(from, target) / accept(target, from_uid) / decline(target, from_uid) / leave(p)
--   party:kick(leader, uid) / removed(p) / members(p) / is_leader(p) / key_of(p)
--   party:join_roblox_party(p, others_in_it) / arrived(p, key, leader_uid)
--   party:state(p) -> what the client shows (OP.PARTY_STATE)

local Party = {}
Party.__index = Party

Party.MAX_SIZE = 4
--- An invite waits this long for an answer.
Party.INVITE_TTL_S = 60
--- A player invites the same player again only this long after.
Party.INVITE_GAP_S = 3

type Group = { key: string, leader: any, members: { any } }

function Party.new(deps: { [string]: any })
	local self = setmetatable({}, Party)
	self.deps = deps
	self.groups = {} :: { [string]: Group }
	self.of = {} :: { [any]: string }
	--- target → { [from] = sent at }
	self.invites = {} :: { [any]: { [any]: number } }
	self._seq = 0
	return self
end

local function uid(p: any): number
	return tonumber(p.UserId) or 0
end

local function name_of(p: any): string
	local d = p.DisplayName
	return if type(d) == "string" and d ~= "" then d else tostring(p.Name)
end

function Party._log(self: any, text: string)
	if self.deps.log then
		self.deps.log("[Party] " .. text)
	end
end

function Party._new_key(self: any, leader: any): string
	self._seq += 1
	return ("%s%d:%d"):format(self.deps.prefix or "", uid(leader), self._seq)
end

--- `p`'s party key, or nil.
function Party.key_of(self: any, p: any): string?
	return self.of[p]
end

--- Everyone in `p`'s party (leader first), or { p } alone.
function Party.members(self: any, p: any): { any }
	local g = self.groups[self.of[p] or ""]
	if g == nil then
		return { p }
	end
	return table.clone(g.members)
end

function Party.is_leader(self: any, p: any): boolean
	local g = self.groups[self.of[p] or ""]
	return g == nil or g.leader == p
end

--- Tells every member (and anyone with an invite from them) what the party looks like now.
function Party._push(self: any, players: { any })
	local seen = {}
	for _, p in players do
		if not seen[p] then
			seen[p] = true
			self.deps.send(p, self:state(p))
		end
	end
end

function Party._push_group(self: any, key: string?)
	local g = self.groups[key or ""]
	if g ~= nil then
		self:_push(g.members)
	end
end

--- What `p` sees: { members = { {uid, name, leader} }, leader (am I), invites = { {uid, name} } }.
function Party.state(self: any, p: any): { [string]: any }
	local members = {}
	local g = self.groups[self.of[p] or ""]
	if g ~= nil and #g.members > 1 then
		for _, m in g.members do
			table.insert(members, { uid = uid(m), name = name_of(m), leader = m == g.leader })
		end
	end
	local invites = {}
	local now = self.deps.now()
	for from, at in self.invites[p] or {} do
		if now - at <= Party.INVITE_TTL_S and from.Parent ~= nil then
			table.insert(invites, { uid = uid(from), name = name_of(from) })
		end
	end
	table.sort(invites, function(a, b)
		return a.uid < b.uid
	end)
	return {
		members = members,
		leader = g == nil or g.leader == p,
		invites = invites,
		max = Party.MAX_SIZE,
	}
end

--- `from` invites `target` (on this server). Returns ok, reason.
function Party.invite(self: any, from: any, target: any): (boolean, string?)
	if target == nil or target == from then
		return false, "Pick someone to invite."
	end
	local key = self.of[from]
	if key ~= nil and self.of[target] == key then
		return false, name_of(target) .. " is already in your party."
	end
	local g = self.groups[key or ""]
	if g ~= nil and #g.members >= Party.MAX_SIZE then
		return false, ("A party holds %d players."):format(Party.MAX_SIZE)
	end
	local now = self.deps.now()
	local box = self.invites[target]
	if box == nil then
		box = {}
		self.invites[target] = box
	end
	if box[from] ~= nil and now - box[from] < Party.INVITE_GAP_S then
		return false, nil
	end
	box[from] = now
	self:_push({ target })
	self:_log(("%s invited %s"):format(name_of(from), name_of(target)))
	return true, nil
end

--- `target` accepts `from_uid`'s invite: they are now in `from`'s party (made if `from` had none);
--- `target` leaves the party it was in.
function Party.accept(self: any, target: any, from_uid: number): (boolean, string?)
	local box = self.invites[target]
	local from = nil
	for p, at in box or {} do
		if uid(p) == from_uid and self.deps.now() - at <= Party.INVITE_TTL_S then
			from = p
		end
	end
	if from == nil or from.Parent == nil then
		return false, "That invite has expired."
	end
	box[from] = nil
	local key = self.of[from]
	local g = self.groups[key or ""]
	if g ~= nil and #g.members >= Party.MAX_SIZE then
		self:_push({ target })
		return false, "That party is full."
	end
	if self.of[target] ~= nil then
		self:leave(target)
	end
	if g == nil then
		key = self:_new_key(from)
		g = { key = key :: string, leader = from, members = { from } }
		self.groups[key :: string] = g
		self.of[from] = key
	end
	table.insert(g.members, target)
	self.of[target] = key
	self:_push_group(key)
	self:_log(("%s joined %s's party (%d)"):format(name_of(target), name_of(g.leader), #g.members))
	return true, nil
end

function Party.decline(self: any, target: any, from_uid: number)
	local box = self.invites[target]
	for p in box or {} do
		if uid(p) == from_uid then
			box[p] = nil
		end
	end
	self:_push({ target })
end

--- `p` leaves its party (the next member leads when the leader leaves; one left alone is no party).
function Party.leave(self: any, p: any)
	local key = self.of[p]
	local g = self.groups[key or ""]
	self.of[p] = nil
	if g == nil then
		self:_push({ p })
		return
	end
	local i = table.find(g.members, p)
	if i ~= nil then
		table.remove(g.members, i)
	end
	if g.leader == p then
		g.leader = g.members[1]
	end
	if #g.members <= 1 then
		for _, m in g.members do
			self.of[m] = nil
		end
		self.groups[g.key] = nil
		self:_push(g.members)
	else
		self:_push_group(key)
	end
	if p.Parent ~= nil then
		self:_push({ p })
	end
end

--- The leader removes a member.
function Party.kick(self: any, leader: any, member_uid: number)
	local g = self.groups[self.of[leader] or ""]
	if g == nil or g.leader ~= leader then
		return
	end
	for _, m in g.members do
		if m ~= leader and uid(m) == member_uid then
			self:leave(m)
			return
		end
	end
end

--- `p` left the server.
function Party.removed(self: any, p: any)
	self:leave(p)
	self.invites[p] = nil
	for target, box in self.invites do
		if box[p] ~= nil then
			box[p] = nil
			if target.Parent ~= nil then
				self:_push({ target })
			end
		end
	end
end

--- Players of one Roblox party (Player.PartyId) on this server: one party, the first of them leading.
function Party.join_roblox_party(self: any, p: any, others: { any })
	if self.of[p] ~= nil then
		return
	end
	for _, o in others do
		if o ~= p and self.of[o] ~= nil then
			local g = self.groups[self.of[o]]
			if g ~= nil and #g.members < Party.MAX_SIZE then
				table.insert(g.members, p)
				self.of[p] = g.key
				self:_push_group(g.key)
			end
			return
		end
	end
	for _, o in others do
		if o ~= p and o.Parent ~= nil and self.of[o] == nil then
			local key = self:_new_key(o)
			self.groups[key] = { key = key, leader = o, members = { o, p } }
			self.of[o] = key
			self.of[p] = key
			self:_push_group(key)
			return
		end
	end
end

--- `p` came back from a match in party `key` (the match server's return teleport): the party is made
--- again with whoever of it is here; `leader_uid` leads when present.
function Party.arrived(self: any, p: any, key: string, leader_uid: number?)
	if self.of[p] ~= nil or type(key) ~= "string" or key == "" then
		return
	end
	local g = self.groups[key]
	if g == nil then
		g = { key = key, leader = p, members = {} }
		self.groups[key] = g
	end
	if #g.members >= Party.MAX_SIZE then
		return
	end
	table.insert(g.members, p)
	self.of[p] = key
	if leader_uid ~= nil and uid(p) == leader_uid then
		g.leader = p
	end
	self:_push_group(key)
end

return Party
