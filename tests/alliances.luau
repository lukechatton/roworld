--!nocheck
-- Alliances:
--   * a request expires once more than allianceRequestDuration (200 ticks) passed
--     since it was made; a new request to the same player waits
--     allianceRequestCooldown (300 ticks) from when the previous one was made,
--     unless it answers a pending request from that player;
--   * an alliance expires allianceDuration (3000 ticks) after it was formed or renewed
--     (checked on the player's tick): no traitor, both are told;
--   * renewal ("ally_extend") is asked in the last allianceExtensionPromptOffset (300
--     ticks; GameState's can_extend) and happens when both asked
--     (expiresAt = now + allianceDuration); the other side is told once;
--   * AIs never ask; a tribe always agrees (on its attack ticks), a nation
--     agrees as it would to a request and reconsiders every attack tick
--     (its alliance decision, as for a new request);
--   * the wire: "ally_extend" intent, ALLY / ALLY_EXT / ALLY_END events, snapshot rows and
--     GameState.alliance_info on a mirror fed through the Protocol.
-- Run: .bin/lune run tests/alliances.luau
require("./prelude")
local Defs = require("../src/shared/Core/Defs")
local Ev = require("../src/shared/Core/Ev")
local Rules = require("../src/shared/Core/Rules")
local WorldMap = require("../src/shared/Core/WorldMap")
local Sim = require("../src/shared/Core/Sim")
local GameState = require("../src/shared/Core/GameState")
local Protocol = require("../src/shared/Net/Protocol")

local fails = 0
local function expect(cond: any, what: string)
	if cond then
		print("  ok   " .. what)
	else
		fails += 1
		print("FAIL " .. what)
	end
end

expect(
	Rules.ALLY_REQUEST_TICKS == 200
		and Rules.ALLY_REQUEST_COOLDOWN_TICKS == 300
		and Rules.ALLIANCE_TICKS == 3000
		and Rules.ALLIANCE_EXTEND_WINDOW_TICKS == 300,
	"durations: request 20 s, cooldown 30 s, alliance 5 min, renewal window 30 s"
)

local map = WorldMap.get("pangaea")
local W = map.W

--- A match with no nations or tribes; owners are placed by hand far apart; the AI only runs when
--- `ai` is true. Deltas go through the Protocol into a mirror.
local function new_match(seed: number, ai: boolean?): any
	local sim = Sim.new(map, { seed = seed, difficulty = 1, tribes = 0, max_humans = 0, nations = false })
	if not ai then
		sim.ai.tick = function() end
	end
	local m = { sim = sim, ev = {}, gs = GameState.new(map), slot = 0 }
	m.gs:load_snapshot(Protocol.decode_snapshot(Protocol.encode_snapshot(sim:snapshot())))
	return m
end

local function place(m: any, name: string, kind: number): number
	local sim = m.sim
	local id = sim:add_owner(name, 0xffffffff, kind)
	m.slot += 1
	local c = map:land_tile(math.floor(map.land_count * (m.slot - 0.5) / 8))
	for dy = -2, 2 do
		for dx = -2, 2 do
			local t = c + dy * W + dx
			if t >= 0 and t < map.N and buffer.readu8(map.land, t) == 1 and buffer.readi32(sim.owner, t * 4) == 0 then
				sim:set_owner(t, id)
			end
		end
	end
	sim.o_spawned[id] = 1
	sim.o_spawn_tile[id] = c
	sim.o_troops[id] = 50000
	return id
end

--- One tick, mirrored through the wire; returns the tick's events.
local function step(m: any, intents: { { any } }?): { { any } }
	for _, it in intents or {} do
		local wire = Protocol.decode_intent(Protocol.encode_intent(it[2]))
		assert(wire ~= nil, "intent survives the wire")
		m.sim:submit(it[1], wire)
	end
	local d = m.sim:step()
	m.gs:apply_delta(Protocol.decode_delta(Protocol.encode_delta(d, nil, W)))
	m.ev = d.ev
	return d.ev
end

local function find(ev: { { any } }, kind: number, pred: ((any) -> boolean)?): any
	for _, e in ev do
		if e[1] == kind and (pred == nil or pred(e)) then
			return e
		end
	end
	return nil
end

local function msg_to(ev: { { any } }, id: number, text: string): boolean
	return find(ev, Ev.MSG, function(e)
		return e[2] == id and string.find(e[4], text, 1, true) ~= nil
	end) ~= nil
end

-- =============================================================================================
-- Requests: expiry and cooldown
-- =============================================================================================
do
	local m = new_match(1)
	local a = place(m, "Ann", Defs.KIND_HUMAN)
	local b = place(m, "Ben", Defs.KIND_HUMAN)
	step(m)
	local made = m.sim.tick + 1
	step(m, { { a, { type = "ally_request", target = b } } })
	expect(m.sim:has_request(a, b) and m.gs.requests[a * 1024 + b] == made, "request made (tick carried to the mirror)")
	local closed_at = -1
	for _ = 1, 260 do
		local ev = step(m)
		if find(ev, Ev.ALLY_REQ_END) ~= nil and closed_at < 0 then
			closed_at = m.sim.tick
			expect(msg_to(ev, a, "did not answer your alliance request"), "the requester hears it expired")
		end
	end
	expect(
		closed_at == made + Rules.ALLY_REQUEST_TICKS + 1 and not m.gs:has_request(a, b),
		string.format("request expires when more than 200 ticks passed (made %d, closed %d)", made, closed_at)
	)
	-- cooldown: 300 ticks from when the previous request was made
	local wait = m.sim:request_cooldown_left(a, b)
	expect(
		wait == made + Rules.ALLY_REQUEST_COOLDOWN_TICKS - m.sim.tick and m.gs:request_cooldown_left(a, b) == wait,
		"cooldown left counted from when the request was made (Sim and mirror)"
	)
	local ev = step(m, { { a, { type = "ally_request", target = b } } })
	expect(
		not m.sim:has_request(a, b) and msg_to(ev, a, "You can ask Ben again in"),
		"a new request waits for the cooldown"
	)
	-- ...but answering the other side's request is always allowed
	step(m, { { b, { type = "ally_request", target = a } } })
	ev = step(m, { { a, { type = "ally_request", target = b } } })
	expect(m.sim:allied(a, b) and m.gs:are_allies(a, b), "asking back accepts a pending request despite the cooldown")
	-- after the cooldown a new request goes through
	local m2 = new_match(2)
	local c = place(m2, "Cid", Defs.KIND_HUMAN)
	local d = place(m2, "Dan", Defs.KIND_HUMAN)
	step(m2, { { c, { type = "ally_request", target = d } } })
	local t_req = m2.sim.tick
	step(m2, { { d, { type = "ally_reply", target = c, accept = false } } })
	while m2.sim.tick < t_req + Rules.ALLY_REQUEST_COOLDOWN_TICKS - 2 do
		step(m2)
	end
	step(m2, { { c, { type = "ally_request", target = d } } })
	local early = m2.sim:has_request(c, d)
	step(m2, { { c, { type = "ally_request", target = d } } })
	expect(
		not early and m2.sim:has_request(c, d) and m2.sim.tick == t_req + Rules.ALLY_REQUEST_COOLDOWN_TICKS,
		"a rejected request can be re-sent exactly 300 ticks after it was made"
	)
end

-- =============================================================================================
-- Expiry and renewal between humans
-- =============================================================================================
local function allied_pair(seed: number): (any, number, number, number)
	local m = new_match(seed)
	local a = place(m, "Ann", Defs.KIND_HUMAN)
	local b = place(m, "Ben", Defs.KIND_HUMAN)
	step(m, { { a, { type = "ally_request", target = b } } })
	local ev = step(m, { { b, { type = "ally_reply", target = a, accept = true } } })
	local e = find(ev, Ev.ALLY)
	return m, a, b, if e ~= nil then e[4] else -1
end

do
	local m, a, b, expires = allied_pair(3)
	local formed = m.sim.tick
	expect(
		expires == formed + Rules.ALLIANCE_TICKS and m.gs:alliance_info(a, b).expires_at == expires,
		"ALLY carries expiresAt = formed + 3000 (mirror too)"
	)
	-- outside the renewal window asking is refused
	local ev = step(m, { { a, { type = "ally_extend", target = b } } })
	expect(
		find(ev, Ev.ALLY_EXT) == nil and not m.sim:asked_to_extend(a, b) and not m.gs:alliance_info(a, b).can_extend,
		"no renewal before the last 300 ticks"
	)
	while m.sim.tick < expires - Rules.ALLIANCE_EXTEND_WINDOW_TICKS - 1 do
		step(m)
	end
	local info = m.gs:alliance_info(a, b)
	step(m)
	local info2 = m.gs:alliance_info(a, b)
	expect(not info.in_window and info2.in_window and info2.can_extend, "the window opens 300 ticks before expiry")
	-- one side asks: recorded, the other is told once
	ev = step(m, { { a, { type = "ally_extend", target = b } } })
	local e = find(ev, Ev.ALLY_EXT)
	expect(
		e ~= nil
			and e[4] == expires
			and e[5] == (if a < b then 1 else 2)
			and msg_to(ev, b, "Ann wants to renew your alliance"),
		"a renewal request is sent to the ally"
	)
	info = m.gs:alliance_info(b, a)
	local mine = m.gs:alliance_info(a, b)
	expect(
		info.other_asked and not info.me_asked and info.can_extend and mine.me_asked and not mine.can_extend,
		"mirror: who asked"
	)
	ev = step(m, { { a, { type = "ally_extend", target = b } } })
	expect(find(ev, Ev.ALLY_EXT) == nil and find(ev, Ev.MSG) == nil, "asking twice changes nothing")
	-- both asked: renewed from now
	ev = step(m, { { b, { type = "ally_extend", target = a } } })
	e = find(ev, Ev.ALLY_EXT)
	local renewed = m.sim.tick
	expect(
		e ~= nil
			and e[4] == renewed + Rules.ALLIANCE_TICKS
			and e[5] == 0
			and msg_to(ev, a, "was renewed")
			and msg_to(ev, b, "was renewed"),
		"both asked: renewed for another 3000 ticks from now"
	)
	info = m.gs:alliance_info(a, b)
	expect(
		info.expires_at == renewed + Rules.ALLIANCE_TICKS
			and not info.me_asked
			and not info.other_asked
			and not info.in_window,
		"mirror: new expiry, marks cleared"
	)
	-- late joiner: the snapshot carries expiry and marks
	local gs2 = GameState.new(map)
	gs2:load_snapshot(Protocol.decode_snapshot(Protocol.encode_snapshot(m.sim:snapshot())))
	expect(gs2:alliance_info(a, b).expires_at == info.expires_at, "snapshot carries the expiry")
end

do
	local m, a, b, expires = allied_pair(4)
	while m.sim.tick < expires - 100 do
		step(m)
	end
	step(m, { { a, { type = "ally_extend", target = b } } }) -- only one side asks
	local ended_at, ev_end = -1, nil
	while m.sim.tick < expires + 5 do
		local ev = step(m)
		local e = find(ev, Ev.ALLY_END)
		if e ~= nil then
			ended_at = m.sim.tick
			ev_end = ev
			expect(e[4] == 0 and e[5] == true, "ALLY_END: no traitor, expired")
		end
	end
	expect(
		ended_at == expires and not m.sim:allied(a, b) and not m.gs:are_allies(a, b),
		"one-sided renewal: expires on time"
	)
	expect(
		ev_end ~= nil
			and msg_to(ev_end, a, "Your alliance with Ben has expired")
			and msg_to(ev_end, b, "Your alliance with Ann has expired"),
		"both are told it expired"
	)
	expect(
		m.sim.o_traitor_until[a] <= m.sim.tick
			and m.sim.o_traitor_until[b] <= m.sim.tick
			and find(ev_end, Ev.TRAITOR) == nil,
		"expiry marks nobody a traitor"
	)
	local ev = step(m, { { a, { type = "ally_extend", target = b } } })
	expect(find(ev, Ev.ALLY_EXT) == nil, "no renewal once expired")
end

-- =============================================================================================
-- AI answers (never asks)
-- =============================================================================================
local function ai_pair(seed: number, kind: number, grudge: boolean): (any, number, number, number)
	local m = new_match(seed, true)
	local h = place(m, "Hal", Defs.KIND_HUMAN)
	local x = place(m, if kind == Defs.KIND_TRIBE then "Tribe" else "Nation", kind)
	m.sim:form_alliance(h, x)
	local expires = m.sim:alliance_expires(h, x)
	if grudge then
		m.sim:add_grudge(x, h, 100000)
	end
	while m.sim.tick < expires - Rules.ALLIANCE_EXTEND_WINDOW_TICKS do
		step(m)
	end
	return m, h, x, expires
end

for _, case in
	{
		{ Defs.KIND_TRIBE, false, true, "a tribe always renews" },
		{ Defs.KIND_NATION, false, true, "a friendly nation renews (reconsidering until it does)" },
		{ Defs.KIND_NATION, true, false, "a nation holding a grudge lets it expire" },
	}
do
	local m, h, x, expires = ai_pair(5, case[1], case[2])
	local asked_by_ai = false
	for _ = 1, 50 do
		asked_by_ai = asked_by_ai or m.sim:asked_to_extend(x, h)
		step(m)
	end
	expect(not asked_by_ai and not m.sim:asked_to_extend(x, h), "AIs never ask first")
	step(m, { { h, { type = "ally_extend", target = x } } })
	local renewed_at = -1
	while m.sim.tick < expires + 2 and m.sim:allied(h, x) do
		local ev = step(m)
		if find(ev, Ev.ALLY_EXT, function(e)
			return e[5] == 0
		end) ~= nil then
			renewed_at = m.sim.tick
			break
		end
	end
	local renewed = renewed_at > 0
		and m.sim:allied(h, x)
		and m.sim:alliance_expires(h, x) == renewed_at + Rules.ALLIANCE_TICKS
	expect(
		renewed == case[3],
		case[4] .. (if renewed then string.format(" (at %d s)", (renewed_at - expires + 300) // 10) else "")
	)
end

-- Two AIs never renew on their own: their alliance lapses.
do
	local m = new_match(6, true)
	local n1 = place(m, "N1", Defs.KIND_NATION)
	local n2 = place(m, "N2", Defs.KIND_NATION)
	m.sim:form_alliance(n1, n2)
	local expires = m.sim:alliance_expires(n1, n2)
	local ext = false
	while m.sim.tick < expires + 2 do
		local ev = step(m)
		ext = ext or find(ev, Ev.ALLY_EXT) ~= nil
	end
	expect(not ext and not m.sim:allied(n1, n2), "an alliance between two AIs lapses after 3000 ticks")
end

-- Garbage renewal intents are harmless.
do
	local m, a, b = allied_pair(7)
	for _, it in
		{
			{ type = "ally_extend", target = 0 },
			{ type = "ally_extend", target = 999 },
			{ type = "ally_extend", target = a },
			{ type = "ally_extend" },
		}
	do
		m.sim:submit(a, it)
	end
	local ev = step(m)
	expect(find(ev, Ev.ALLY_EXT) == nil and m.sim:allied(a, b), "invalid ally_extend intents are ignored")
	expect(
		Protocol.decode_intent(Protocol.encode_intent({ type = "ally_extend", target = 1024 })) == nil,
		"ally_extend target out of range is rejected on the wire"
	)
end

print(if fails == 0 then "alliances: all passed" else string.format("alliances: %d FAILED", fails))
if fails > 0 then
	error("alliances failed")
end
