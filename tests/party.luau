--!nocheck
-- server/Party: parties on a hub server (staging only): invites, accept / decline, leaving (the next
-- member leads), the size limit, a Roblox party arriving together, and a party made again after a
-- match (the match server's return teleport).
-- Run: .bin/lune run tests/party.luau
local Party = require("../src/server/Party")

local fails, total = 0, 0
local function expect(cond: any, what: string)
	total += 1
	if cond then
		print("  ok   " .. what)
	else
		fails += 1
		print("FAIL " .. what)
	end
end

local clock = 0
local sent = {}
local function player(id: number, name: string)
	return { UserId = id, DisplayName = name, Name = name, Parent = true }
end
local party = Party.new({
	send = function(p, state)
		sent[p] = state
	end,
	now = function()
		return clock
	end,
	prefix = "S1:",
})

local a, b, c, d, e = player(1, "Ann"), player(2, "Bob"), player(3, "Cat"), player(4, "Dan"), player(5, "Eve")

-- invite and accept
expect(party:invite(a, b), "Ann invites Bob")
expect(#sent[b].invites == 1 and sent[b].invites[1].uid == 1, "Bob sees the invite")
expect(not party:invite(a, b), "the same invite again at once is ignored")
expect(party:accept(b, 1), "Bob accepts")
expect(party:key_of(a) ~= nil and party:key_of(a) == party:key_of(b), "Ann and Bob share a party")
expect(party:is_leader(a) and not party:is_leader(b), "Ann leads")
expect(#sent[a].members == 2 and #sent[b].members == 2 and sent[b].invites[1] == nil, "both see the party; the invite is gone")
expect(string.sub(party:key_of(a), 1, 3) == "S1:", "the key carries the server's prefix")
-- a decline
party:invite(a, c)
party:decline(c, 1)
expect(#sent[c].invites == 0 and party:key_of(c) == nil, "Cat declines")
-- the size limit
clock += 10
party:invite(a, c)
party:accept(c, 1)
party:invite(a, d)
party:accept(d, 1)
expect(#party:members(a) == 4, "a party of 4")
local ok, why = party:invite(a, e)
expect(not ok and why ~= nil, "a fifth can't be invited")
-- an expired invite
local f = player(6, "Fay")
party:invite(e, f)
clock += Party.INVITE_TTL_S + 1
expect(not party:accept(f, 5), "an invite expires")
-- leaving: the next member leads; one left alone is no party
party:leave(a)
expect(party:key_of(a) == nil and party:is_leader(b) and #party:members(b) == 3, "the leader leaves: Bob leads the 3")
party:kick(b, 3)
expect(party:key_of(c) == nil and #party:members(b) == 2, "Bob removes Cat")
party:removed(d)
expect(party:key_of(b) == nil and #sent[b].members == 0, "Dan leaves the server: Bob alone, no party")
-- accepting another invite leaves the old party
party:invite(a, b)
party:accept(b, 1)
party:invite(c, b)
party:accept(b, 3)
expect(party:key_of(b) == party:key_of(c) and party:key_of(a) == nil, "Bob moves from Ann's party to Cat's")
-- a Roblox party arriving together
local g, h = player(7, "Gus"), player(8, "Hal")
party:join_roblox_party(h, { g, h })
expect(party:key_of(g) ~= nil and party:key_of(g) == party:key_of(h) and party:is_leader(g), "a Roblox party: one party, the first leads")
-- back from a match: the party is made again, its leader leading
local i, j = player(9, "Ivy"), player(10, "Jon")
party:arrived(i, "S0:10:1", 10)
party:arrived(j, "S0:10:1", 10)
expect(party:key_of(i) == "S0:10:1" and party:key_of(j) == "S0:10:1" and party:is_leader(j), "back from a match: the same party, Jon leads")

print(("party: %d/%d passed"):format(total - fails, total))
if fails > 0 then
	error(("party: %d failures"):format(fails))
end
