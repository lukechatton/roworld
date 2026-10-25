--!nocheck
-- A public match's takeover on its server (MatchServer.take_over): only the nation that eliminated the
-- player, only while playing, never for a watcher; the player's owner switches, the client hears
-- OWNER_CHANGED, and the player's orders go to the new nation.
require("./prelude")
local U = require("./net_util")
local Protocol = require("../src/shared/Net/Protocol")
local MatchServer = require("../src/server/MatchServer")
U.use_zstd(Protocol)
local OP = Protocol.OP

local fails = 0
local function expect(c: any, w: string)
	if c then
		print("  ok   " .. w)
	else
		fails += 1
		print("FAIL " .. w)
	end
end

local server = MatchServer.new({
	send = function(peer, op, ...)
		table.insert(peer.inbox, table.pack(op, ...))
	end,
	peers = function()
		return {}
	end,
	now_ms = function()
		return 0
	end,
	make_sim = function()
		return nil
	end,
})
-- a match in play (the sim's takeover rules are tested in tests/takeover.luau)
local submitted = {}
local sim = {
	o_killer = { [5] = 9, [6] = 3 },
	o_name = { [9] = "Canada" },
	allowed = { [9] = true },
	can_take_over = function(s, old, target)
		return s.allowed[target] == true
	end,
	take_over = function(s, old, target)
		return s.allowed[target] == true
	end,
	submit = function(_s, owner, intent)
		table.insert(submitted, { owner, intent })
	end,
}
server._mp_sim = sim
server._stage = "playing"
local alice = { name = "alice", inbox = {} }
local watcher = { name = "watcher", inbox = {} }
server._participants[alice] =
	{ uid = "1", key = "1", name = "Alice", owner = 5, active_msec = 0, spectator = false, voted = false }
server._participants[watcher] =
	{ uid = "2", key = "2", name = "W", owner = 0, active_msec = 0, spectator = true, voted = false }
table.insert(server._order, alice)
table.insert(server._order, watcher)

expect(not server:can_take_over(alice, 3), "not a nation that didn't eliminate her")
expect(not server:can_take_over(watcher, 9), "never a watcher")
expect(server:can_take_over(alice, 9), "the nation that eliminated her")
server._stage = "over"
expect(not server:can_take_over(alice, 9), "not once the match is over")
server._stage = "playing"
sim.allowed[9] = false
expect(not server:take_over(alice, 9), "the sim refuses (it fell meanwhile): no takeover")
sim.allowed[9] = true
expect(server:take_over(alice, 9), "taken over")
expect(server._participants[alice].owner == 9, "Alice commands owner 9")
local heard, dressed = false, false
for _, m in alice.inbox do
	if m[1] == OP.OWNER_CHANGED and m[2] == 9 then
		heard = true
	elseif heard and m[1] == OP.COSMETICS then
		dressed = true
	end
end
expect(heard, "her client hears OWNER_CHANGED 9")
expect(dressed, "then everyone gets the cosmetics map again (the nation wears hers)")
local payload = Protocol.encode_intent({ type = "retreat", aid = 1 })
server:intent(alice, payload)
expect(#submitted == 1 and submitted[1][1] == 9, "her orders go to the nation")

if fails > 0 then
	error(fails .. " failures")
end
print("takeover_match: all passed")
