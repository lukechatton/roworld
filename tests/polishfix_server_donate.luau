-- polish-fixer: the server caps a donation to the recipient's troop headroom (review_gameplay R2-8).
-- The Sim's donate rule is untouched (bit-exact with the original); MatchServer sanitises the intent.
-- Run: .bin/lune run tests/polishfix_server_donate.luau
require("./prelude")
local Protocol = require("../src/shared/Net/Protocol")
local MatchServer = require("../src/server/MatchServer")
local Rules = require("../src/shared/Core/Rules")

local failures = 0
local function check(cond: boolean, what: string)
	if cond then
		print("  ok   " .. what)
	else
		failures += 1
		print("FAIL " .. what)
	end
end

-- 1. the pure cap
do
	local sim = { tick = 10, o_cap = { [1] = 1e6, [2] = 165000 }, o_troops = { [1] = 5e8, [2] = 100000 } }
	local pending = {}
	local it = { type = "donate", target = 2, troops = 5e8 }
	MatchServer.cap_donation(sim, it, pending)
	check(
		it.troops == 65000,
		"a 500M gift to an ally at 100K / 165K is capped to 65K (got " .. tostring(it.troops) .. ")"
	)
	local it2 = { type = "donate", target = 2, troops = 50000 }
	MatchServer.cap_donation(sim, it2, pending)
	check(
		it2.troops == 0,
		"a second gift in the same tick gets only what is left (0, got " .. tostring(it2.troops) .. ")"
	)
	sim.tick = 11
	sim.o_troops[2] = 160000
	local it3 = { type = "donate", target = 2, troops = 50000 }
	MatchServer.cap_donation(sim, it3, pending)
	check(it3.troops == 5000, "next tick: room from the Sim again (5K, got " .. tostring(it3.troops) .. ")")
	sim.tick = 12
	sim.o_troops[2] = 100000
	local it4 = { type = "donate", target = 2, troops = 1000 }
	MatchServer.cap_donation(sim, it4, pending)
	check(it4.troops == 1000, "a gift that fits is unchanged")
	sim.tick = 13
	sim.o_troops[2] = 200000
	local it5 = { type = "donate", target = 2, troops = 1000 }
	MatchServer.cap_donation(sim, it5, pending)
	check(it5.troops == 0, "an ally already above its cap gets nothing")
	local it6 = { type = "donate", target = 7, troops = 1000 }
	MatchServer.cap_donation(sim, it6, pending)
	check(it6.troops == 1000, "unknown cap (not spawned / no data): left to the Sim's own checks")
	local it7 = { type = "donate", target = 2, troops = 1000 }
	MatchServer.cap_donation({ tick = 1 }, it7, nil)
	check(it7.troops == 1000, "a sim without troop arrays (test fakes) is left alone")
end

-- 2. through MatchServer.intent: the decoded intent reaches the Sim capped
do
	local submitted = {}
	local server = MatchServer.new({
		make_sim = function()
			return nil
		end,
		send = function() end,
		peers = function()
			return {}
		end,
		now_ms = function()
			return 0
		end,
	})
	local sim = {
		tick = 50,
		o_cap = { [3] = 1e6, [4] = 50000 },
		o_troops = { [3] = 9e8, [4] = 49000 },
		submit = function(_self, owner, it)
			table.insert(submitted, { owner, it })
		end,
	}
	server._mp_sim = sim
	local peer = { name = "p" }
	server._participants[peer] = { uid = "1", key = "1", name = "p", owner = 3, active_msec = 0 }
	local payload = Protocol.encode_intent({ type = "donate", target = 4, troops = 800000000 })
	check(server:intent(peer, payload) == true, "the donate intent is accepted")
	local got = submitted[1]
	check(
		got ~= nil and got[2].type == "donate" and got[2].troops == 1000,
		"and reaches the Sim capped to 1K (got " .. tostring(got and got[2].troops) .. ")"
	)
	local other = Protocol.encode_intent({ type = "attack", target = 4, ratio = 0.5 })
	server:intent(peer, other)
	check(submitted[2] ~= nil and submitted[2][2].type == "attack", "other intents pass untouched")
end

-- 3. why: troop growth far above the cap subtracts more than the nation has (the formula is the
-- original's; this is what the cap keeps out of reach)
do
	local cap = 165000
	local g = Rules.troop_growth(0, 5e8, cap, 1)
	check(5e8 + g < 0, string.format("uncapped: 500M troops at a 165K cap -> %.3g after one tick (negative)", 5e8 + g))
	local g2 = Rules.troop_growth(0, cap, cap, 1)
	check(cap + g2 >= 0, "capped: at the cap growth is harmless")
end

if failures > 0 then
	error(string.format("%d check(s) failed", failures))
end
print("polishfix_server_donate: all checks passed")
