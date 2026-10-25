-- sim-systems: SimNaval tests (transports: launch validation, budgets, pathing, landing; trade
-- ships: partners, launch, income). Run: .bin/lune run tests/simsys_naval.luau
local F = require("./simsys_fixture")
local Defs, Ev, Rules = F.Defs, F.Ev, F.Rules
local expect, near = F.expect, F.near

local COAST = F.coast_tiles()
local function coast_of(sim, id: number): { number }
	local out = {}
	for _, t in COAST do
		if buffer.readi32(sim.owner, t * 4) == id and sim.map:coast_body_of(t) == 1 then
			table.insert(out, t)
		end
	end
	return out
end

--- B's ocean coast tiles farther than `d` tiles from every coast tile of A (so a transport
--- between them has a real sea route; on World the Alboran Sea is narrow).
local function far_coast_of(sim, id: number, other: number, d: number): { number }
	local mine = coast_of(sim, other)
	local out = {}
	for _, t in coast_of(sim, id) do
		local near_one = false
		for _, o in mine do
			if sim.dist2(t, o) <= d * d then
				near_one = true
				break
			end
		end
		if not near_one then
			table.insert(out, t)
		end
	end
	return out
end

local function dense(path: { number }): boolean
	for i = 2, #path do
		if F.step(path[i - 1], path[i]) ~= 1 then
			return false
		end
	end
	return true
end

local function all_water(sim, path: { number }): boolean
	for _, t in path do
		if buffer.readu8(sim.map.terrain, t) > Defs.T_LAKE then
			return false
		end
	end
	return true
end

-- Spain (A, human) and Algeria (B, human) across the western Mediterranean.
local function setup(seed)
	local sim = F.new_sim(seed)
	local A = F.owner(sim, "Alpha", Defs.KIND_HUMAN, 0, 20000)
	local B = F.owner(sim, "Bravo", Defs.KIND_HUMAN, 0, 20000)
	F.claim(sim, A, 497, 146, 7)
	F.claim(sim, B, 500, 159, 7)
	return sim, A, B
end

-- =============================================================================================
print("transports")
do
	local sim, A, B = setup(1)
	local bc = far_coast_of(sim, B, A, 8)
	expect(#bc > 0 and #coast_of(sim, A) > 0, "both have Mediterranean coast")
	local target = bc[1]
	F.clear(sim)
	expect(sim:launch_boat(A, target, 0.5), "launch_boat")
	local u = sim.unit_list[1]
	expect(u ~= nil and u.kind == Defs.U_TRANSPORT and u.owner == A and u.target_tile == target, "transport unit")
	expect(near(u.troops, 10000) and near(sim.o_troops[A], 10000), "carries ratio x home troops")
	expect(near(sim.dbg_flow[A * 5 + 1], 10000), "dbg_flow boats launched")
	expect(#u.path >= 2 and dense(u.path) and all_water(sim, u.path), "dense water path")
	local src = sim:nearest_own_coast(A, 1, target)
	expect(
		u.path[1] == sim.nav:water_next_to(src, 1) and u.path[#u.path] == sim.nav:water_next_to(target, 1),
		"path from water next to A's nearest coast to water next to the target"
	)
	expect(
		u.tpt == Rules.TRANSPORT_TPT_X100
			and u.tpt == 100
			and u.end_tick == sim.tick + ((#u.path - 1) * 100 + 99) // 100,
		"1 full-size tile per tick (tpt 100), end_tick"
	)
	expect(
		sim.o_boats[A] == 1 and sim.boat_tokens[A] == Rules.BOAT_SEARCHES_PER_S - 1,
		"boat slot and search token used"
	)
	expect(F.has_msg(sim, "Alpha sent a transport toward your coast", B), "alert to the target")
	expect(#sim.hooks == 1 and sim.hooks[1][1] == "launched" and sim.hooks[1][3] == B, "_on_transport_launched hook")
	local ua = F.events(sim, Ev.UNIT_ADD)
	expect(#ua == 1 and ua[1][3] == Defs.U_TRANSPORT and ua[1][8] == 10000, "UNIT_ADD with troops")

	-- validation order and messages
	F.clear(sim)
	expect(
		not sim:launch_boat(A, F.tile(497, 140), 0.3) and F.has_msg(sim, "Boats can only land on a coast", A),
		"inland target rejected"
	)
	expect(not sim:launch_boat(A, coast_of(sim, A)[1], 0.3), "own coast rejected silently")
	expect(not sim:launch_boat(A, target, 0 / 0), "NaN ratio rejected")
	expect(sim:launch_boat(A, bc[2], 0.1), "second boat (last token)")
	F.clear(sim)
	expect(
		not sim:launch_boat(A, bc[3], 0.1) and F.has_msg(sim, "Too many boat orders at once — wait a moment", A),
		"2 path searches per second"
	)
	sim:refill_boat_tokens()
	expect(sim:launch_boat(A, bc[3], 0.1), "third boat after refill")
	F.clear(sim)
	sim:refill_boat_tokens()
	-- a person: MAX_BOATS_PLAYER at sea (any coast of theirs; the same one again is fine)
	local launched = 3
	for k = 4, Rules.MAX_BOATS_PLAYER do
		sim:refill_boat_tokens()
		if sim:launch_boat(A, bc[(k - 1) % #bc + 1], 0.01) then
			launched += 1
		end
	end
	expect(launched == Rules.MAX_BOATS_PLAYER and sim.o_boats[A] == Rules.MAX_BOATS_PLAYER, ("a person: %d transports at sea"):format(sim.o_boats[A]))
	F.clear(sim)
	sim:refill_boat_tokens()
	expect(not sim:launch_boat(A, bc[4], 0.01) and F.has_msg(sim, "Too many transports at sea", A), ("and not %d"):format(Rules.MAX_BOATS_PLAYER + 1))
	expect(Rules.max_boats(20000) == 3 and Rules.max_boats(20000, true) == Rules.MAX_BOATS_PLAYER, "the AI keeps boatMaxNumber 3")
	sim:form_alliance(A, B)
	F.clear(sim)
	expect(not sim:launch_boat(A, bc[4], 0.1) and F.has_msg(sim, "Bravo is your ally", A), "ally coast rejected")
	sim:end_alliance(A, B, 0)

	-- arrival: landing tile taken for free, attack started with every soldier
	F.clear(sim)
	local troops = u.troops
	while not u.dead do
		F.advance(sim, 1)
		sim:units_tick()
	end
	expect(sim.tick == u.end_tick, "arrives at end_tick")
	expect(buffer.readi32(sim.owner, target * 4) == A, "landing tile conquered")
	expect(
		F.has_msg(sim, "Your transport landed in Bravo", A) and F.has_msg(sim, "Alpha landed troops on your coast!", B),
		"landing messages"
	)
	if F.HAS_ATTACKS then
		local a = sim:attack_between(A, B)
		expect(a ~= nil and a.troops > 0, "attack started from the beachhead")
	else
		local st = sim.started[#sim.started]
		expect(
			st ~= nil and st[1] == A and st[2] == B and near(st[3], troops) and st[4] == target,
			"start_attack(A, B, troops, landing tile)"
		)
	end
	local at_sea = 0
	for _, o in sim.unit_list do
		if not o.dead and o.kind == Defs.U_TRANSPORT and o.owner == A then
			at_sea += 1
		end
	end
	expect(u.dead and sim.o_boats[A] == at_sea and at_sea < 3, "boat slot released on arrival")
end

-- =============================================================================================
print("transport returns / alt landing / blocked landing")
do
	local sim, A, B = setup(2)
	local bc = far_coast_of(sim, B, A, 8)
	local target = bc[1]
	expect(sim:launch_boat(A, target, 0.5), "launch")
	local u = sim.unit_list[1]
	-- the target coast becomes A's while at sea → troops come home minus 25 %
	sim:set_owner(target, A)
	local home = sim.o_troops[A]
	F.clear(sim)
	sim.tick = u.end_tick
	sim:units_tick()
	expect(
		u.dead
			and near(sim.o_troops[A] - home, u.troops * 0.75)
			and F.has_msg(sim, "Your transport returned its troops home", A),
		"own coast: 75 % return"
	)
	-- target no longer landable (ally) → nearby alternative landing tile
	sim:set_owner(target, B)
	expect(sim:launch_boat(A, target, 0.2), "launch 2")
	local u2 = sim.unit_list[#sim.unit_list]
	sim:form_alliance(A, B)
	local C2 = F.owner(sim, "Charlie", Defs.KIND_NATION, 0, 20000)
	-- give a neighbouring coastal tile to a third owner so the alternative exists
	local alt = nil
	for _, t in bc do
		if t ~= target and sim.dist2(t, target) <= 4 then
			alt = t
			break
		end
	end
	if alt then
		sim:set_owner(alt, C2)
	end
	sim.tick = u2.end_tick
	F.clear(sim)
	sim:units_tick()
	expect(
		alt ~= nil and buffer.readi32(sim.owner, alt * 4) == A,
		"landed on the nearest landable coast (_alt_landing)"
	)
	expect(sim:_alt_landing(A, F.tile(497, 140), 1) == -1, "no alternative inland")
end

-- =============================================================================================
print("trade ships")
do
	local sim, A, B = setup(3)
	local pa = sim:add_struct(Defs.S_PORT, A, coast_of(sim, A)[1])
	local pb = sim:add_struct(Defs.S_PORT, B, coast_of(sim, B)[1])
	expect(pa.water >= 0 and pa.body == 1 and pb.water >= 0, "ports get a water tile and body")
	expect(pa.next_tick == sim.tick % 10, "trade roll slot = build tick % 10")
	F.advance(sim, 50)
	sim:construction_tick()
	expect(pa.active and #sim.port_list == 2, "ports active after 5 s")
	local cands, weights = {}, {}
	sim:_trade_candidates(pa, cands, weights)
	expect(#cands == 1 and cands[1] == pb and weights[1] == 1, "candidate: B's port, weight 1 (short range: no bonus)")
	-- run port rolls until A's port launches a ship
	local ship = nil
	for _ = 1, 20000 do
		F.advance(sim, 1)
		sim.path_budget = 2
		sim:ports_tick()
		for _, u in sim.unit_list do
			if not u.dead and u.kind == Defs.U_TRADE and u.owner == A then
				ship = u
			end
		end
		if ship then
			break
		end
	end
	expect(ship ~= nil, "A's port launches a trade ship")
	if ship then
		expect(ship.src_sid == pa.sid and ship.dst_sid == pb.sid and ship.tpt == 100, "trade ship route A→B at 100")
		expect(
			ship.path[1] == pa.water and ship.path[#ship.path] == pb.water and dense(ship.path),
			"path water tile to water tile"
		)
		expect(sim.trade_cache[pa.sid * 1048576 + pb.sid] == ship.path, "route cached")
		expect(#pa.partners == 1 and pa.partners[1] == pb.sid, "partner list")
		expect(sim.n_trade >= 1, "n_trade")
		for _, o in sim.unit_list do
			if o ~= ship then
				sim:remove_unit(o, Defs.DEL_DESTROYED)
			end
		end
		local ga, gb = sim.o_gold[A], sim.o_gold[B]
		local g = Rules.trade_gold(#ship.path)
		sim.tick = ship.end_tick
		F.clear(sim)
		sim:units_tick()
		expect(
			ship.dead and near(sim.o_gold[A] - ga, g) and near(sim.o_gold[B] - gb, g),
			"arrival pays tradeShipGold(tiles) to both owners"
		)
		-- each of them (people here) sees it over their own port (the gold shown at the port tile)
		local bonus = F.events(sim, Ev.BONUS)
		local whole = math.floor(g + 0.5)
		expect(
			#bonus == 2
				and bonus[1][2] == A
				and bonus[1][3] == pa.tile
				and bonus[1][4] == whole
				and bonus[2][2] == B
				and bonus[2][3] == pb.tile
				and bonus[2][4] == whole,
			"a BONUS event each: the sender's at the port it left, the receiver's at the port it reached"
		)
		expect(
			near(Rules.trade_gold(0), 75000 / (1 + math.exp(9)))
				and near(
					Rules.trade_gold(154),
					75000 / (1 + math.exp(-0.03 * (154 * Rules.K_LIN - 300))) + 50 * 154 * Rules.K_LIN
				),
			"trade_gold formula"
		)
	end
	-- reverse route reuses the cached path reversed
	local rp = sim:_trade_path(pb, pa)
	local fp = sim.trade_cache[pa.sid * 1048576 + pb.sid]
	local rev_ok = #rp == #fp
	for i = 1, #rp do
		if rp[i] ~= fp[#fp + 1 - i] then
			rev_ok = false
		end
	end
	expect(rev_ok and rp ~= fp, "reverse route = reversed copy")
	-- hostility blocks trade partners
	sim:add_grudge(B, A, 600)
	local c2, w2 = {}, {}
	sim:_trade_candidates(pa, c2, w2)
	expect(#c2 == 0, "hostile owners don't trade")
	-- destroying a port drops its cached routes
	sim:destroy_struct(pb)
	local left = 0
	for _ in sim.trade_cache do
		left += 1
	end
	expect(left == 0 and #sim.port_list == 1, "port destruction drops cached routes")
	expect(
		Rules.trade_spawn_rate(0, 0) == math.floor(100 / Rules.trade_saturation(0))
			and Rules.trade_spawn_rate(9, 0) < Rules.trade_spawn_rate(0, 0),
		"pity timer raises odds"
	)
	-- captured ship arriving: gold to the captor only when bound for its own port
	local SimStructures = require("../src/shared/Core/SimStructures")
	local w = SimStructures.Unit.new()
	w.kind = Defs.U_TRADE
	w.owner = B
	w.orig_owner = A
	w.dst_sid = pa.sid
	w.path = { pa.water, pa.water }
	w.traveled = 30
	w.end_tick = sim.tick
	sim:add_unit(w)
	local gb2 = sim.o_gold[B]
	F.clear(sim)
	sim:_trade_arrive(w)
	expect(
		near(sim.o_gold[B], gb2) and #F.events(sim, Ev.BONUS) == 0,
		"captured ship bound for someone else's port pays nothing (and shows nothing)"
	)
	-- a captured ship reaching its captor's own port: the gold, over that port
	local w3 = SimStructures.Unit.new()
	w3.kind = Defs.U_TRADE
	w3.owner = A
	w3.orig_owner = B
	w3.dst_sid = pa.sid
	w3.path = { pa.water, pa.water }
	w3.traveled = 30
	w3.end_tick = sim.tick
	sim:add_unit(w3)
	local ga3 = sim.o_gold[A]
	F.clear(sim)
	sim:_trade_arrive(w3)
	local b3 = F.events(sim, Ev.BONUS)
	expect(
		near(sim.o_gold[A] - ga3, Rules.trade_gold(32)) and #b3 == 1 and b3[1][2] == A and b3[1][3] == pa.tile,
		"a captured ship reaching its captor's port pays the captor, shown over that port"
	)
	-- the port it left is gone: the sender's gold shows over the port it reached
	local w4 = SimStructures.Unit.new()
	w4.kind = Defs.U_TRADE
	w4.owner = B
	w4.src_sid = pb.sid -- (destroyed above)
	w4.dst_sid = pa.sid
	w4.path = { pa.water, pa.water }
	w4.end_tick = sim.tick
	sim:add_unit(w4)
	F.clear(sim)
	sim:_trade_arrive(w4)
	local b4 = F.events(sim, Ev.BONUS)
	expect(#b4 >= 1 and b4[1][2] == B and b4[1][3] == pa.tile, "the sender's port is gone: shown over the port reached")
end

F.finish("simsys_naval")
