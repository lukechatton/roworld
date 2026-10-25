--!native
-- Port of scripts/core/sim_ai.gd (SimAI extends SimAIEconomy).
-- Nation and tribe AI. Each AI nation "thinks" every ~1.5 s; thinking is staggered by owner id so
-- no tick carries more than a handful of thinkers. Nation attack sizing runs on a per-nation
-- cadence: every attackRate ticks a nation sends everything above
-- expandRatio x max troops into free land, and wars only once troops reach reserveRatio (usually
-- triggerRatio) of max, sending everything above the reserve; its target choice, human protection
-- and dogpile caps sit on top of that. Tribes (the simple bots) run a plainer loop (see
-- the Tribes section): they act only on their attackRate ticks. The AI perceives the world through
-- Sim.scan_border() (a walk over its border list) and acts only through the same entry points
-- humans use (intent_attack, launch_boat, try_build, launch_nuke, ally_request / ally_reply /
-- ally_break), so every rule and cost applies to it too.
--
-- Luau: SimAIEconomy's methods are mixed into this class (SimAIEconomy.install); the Sim is passed
-- in as `sim` on every call (no stored back-reference), as in GDScript.
--
-- Map scale: the heuristics were tuned on the original 1024-wide Earth grid; tile distances in
-- those units are multiplied by sim.R.LEGACY_LIN (our tiles per original tile), border-tile counts
-- likewise and tile counts by sim.R.LEGACY_AREA, so every map plays alike.

local Defs = require("./Defs")
local Rules = require("./Rules")
local SimAIEconomy = require("./SimAIEconomy")
local Coop = require("../Net/Coop")

local readu8 = buffer.readu8
local readu16 = buffer.readu16
local readi32 = buffer.readi32

local f32 = Defs.f32

local filled = SimAIEconomy.filled
local zt = SimAIEconomy.zt
local NUKE_AGE = SimAIEconomy.NUKE_AGE

local KIND_NATION = Defs.KIND_NATION
local KIND_TRIBE = Defs.KIND_TRIBE
local KIND_HUMAN = Defs.KIND_HUMAN
local U_TRANSPORT = Defs.U_TRANSPORT

local SimAI = {}
SimAI.__index = SimAI
SimAIEconomy.install(SimAI)

-- Re-export the base constants (GDScript subclasses see their parent's consts).
for k, v in SimAIEconomy do
	if type(v) ~= "function" and SimAI[k] == nil then
		SimAI[k] = v
	end
end

SimAI.NATION_THINK = 15
--- Novice bot players (Sim.is_novice_bot) wait this many times longer before attacking a real player.
SimAI.NOVICE_GRACE_MULT = 2
-- A nation's attackRate range (ticks between attack decisions) per difficulty.
SimAI.NATION_ATTACK_RATE = zt({ { 65, 100 }, { 55, 70 }, { 45, 60 } })
-- Tribe cadence: attackRate is drawn from 40-79 ticks (80 excluded), attackTick from
-- 0 .. attackRate - 1; a tribe acts when tick % attackRate == attackTick.
SimAI.TRIBE_ATTACK_RATE = { 40, 79 }
-- A tribe's random attack: 1 in 3 chance to go for a
-- traitor; a nation or human neighbour is skipped 1 time in 2 (tribes never are).
SimAI.TRIBE_TRAITOR_ODDS = 3
SimAI.TRIBE_SKIP_PLAYER_ODDS = 2
-- Delete cooldown (deleteUnitCooldown 30 s) and deletionMarkDuration (30 s): a tribe marks
-- one captured structure for deletion per attack tick at most every 300 ticks; it goes 300 ticks later.
SimAI.TRIBE_DELETE_COOLDOWN = 300
SimAI.TRIBE_DELETE_DELAY = 300
-- Score (own / target troops x preferences) a war target needs. The "weakest" strategy
-- attacks a bordering enemy with fewer troops than ours.
SimAI.WAR_RATIO = zt({ 1.0, 1.0, 1.0 }) -- PackedFloat32Array
-- Easy nations skip a human target 3 times in 4, Medium 1 in 4, Hard never.
SimAI.HUMAN_SKIP = zt({ 0.75, 0.25, 0.0 }) -- PackedFloat32Array
-- Alliance acceptance bias per difficulty.
SimAI.ACCEPT_BIAS = zt({ f32(0.1), 0.0, f32(-0.15) }) -- PackedFloat32Array
SimAI.NUKE_GAP = 1800
-- After an AI nukes someone, other AIs leave that target alone for this long (Brutal: half).
SimAI.NUKE_TARGET_COOL = 600
-- Nuke-age extra delay before AIs may nuke a human (on top of that AI's own grace).
SimAI.HUMAN_NUKE_EXTRA = 1200
-- Late-game remnant mop-up (boat invasions of small, weak owners).
SimAI.MOPUP_AGE = 6000
SimAI.MOPUP_GAP = 200
-- Endgame naval offensives by big nations against major rivals across the sea.
SimAI.INVASION_AGE = 12000
SimAI.INVASION_GAP = 150
SimAI.LATE_WAR_FROM = 12000
SimAI.LATE_WAR_SPAN = 9000

local NATION_THINK = SimAI.NATION_THINK
local NATION_ATTACK_RATE = SimAI.NATION_ATTACK_RATE
local TRIBE_ATTACK_RATE = SimAI.TRIBE_ATTACK_RATE
local WAR_RATIO = SimAI.WAR_RATIO
local HUMAN_SKIP = SimAI.HUMAN_SKIP
local ACCEPT_BIAS = SimAI.ACCEPT_BIAS
--- Team games: the share of alliance requests refused outright, by difficulty (0..2).
local TEAM_REFUSE = { [0] = 0.25, [1] = 0.5, [2] = 0.75 }
local HUMAN_NUKE_EXTRA = SimAI.HUMAN_NUKE_EXTRA

function SimAI.new()
	local self = setmetatable({}, SimAI)
	self:_init_economy()
	self.next_think = {} :: { [number]: number }
	-- Per-AI ratios of max troops: triggerRatio 0.50-0.59, reserveRatio 0.30-0.39,
	-- expandRatio 0.10-0.19; attack cadence (attackRate) and the tick of the next attack decision
	-- (nations) or the attack tick modulo attackRate (tribes).
	self.trigger_r = {} :: { [number]: number }
	self.reserve_r = {} :: { [number]: number }
	self.expand_r = {} :: { [number]: number }
	self.attack_rate = {} :: { [number]: number }
	self.next_attack = {} :: { [number]: number }
	self.attack_tick = {} :: { [number]: number }
	-- 0 until the AI's first (forced) expansion after the land grab begins.
	self.started = {} :: { [number]: number }
	-- Per tribe: 1 until the tribe first finds no free land nearby.
	self.tribe_tn = {} :: { [number]: number }
	-- Tick of each tribe's last structure deletion, and the structures tribes marked for deletion.
	self.last_delete = {} :: { [number]: number }
	self.doomed = {} :: { any }
	-- Scratch lists of the tribe decision (nearby players, traitors), reused.
	self._near = {} :: { number }
	self._near_seen = {} :: { [number]: boolean }
	self._pick = {} :: { number }
	self.aggression = {} :: { [number]: number }
	self.naval = {} :: { [number]: number }
	self.last_boat = {} :: { [number]: number }
	self.last_nuke = {} :: { [number]: number }
	self.last_ally_ask = {} :: { [number]: number }
	-- Tick until which AIs will not pick this owner as a nuke target.
	self.nuke_cool = {} :: { [number]: number }
	-- Per-AI extra grace (ticks) before it may attack humans; see _may_attack_human().
	self.grace_jitter = {} :: { [number]: number }
	-- AI nations currently at war with each owner (rebuilt every tick; tribes don't count).
	self.attackers_on = {} :: { [number]: number }
	self.last_mopup = {} :: { [number]: number }
	self.last_invasion = {} :: { [number]: number }
	-- { due_tick, from, to } alliance requests an AI must answer.
	self.replies = {} :: { { number } }
	-- { due_tick, from, to } renewal requests of `from` that AI ally `to` must answer.
	self.extensions = {} :: { { number } }
	self.leader = 0
	self.leader_share = 0.0
	self.runaway_human = 0
	return self
end

function SimAI:setup(sim)
	local m = Defs.MAX_OWNERS
	self:_setup_economy(m)
	-- Coop.check(): Session builds local matches time-sliced over frames (no-op outside a Coop job).
	Coop.check()
	self.next_think = filled(m, 0)
	self.trigger_r = filled(m, 0.0)
	self.reserve_r = filled(m, 0.0)
	self.expand_r = filled(m, 0.0)
	self.attack_rate = filled(m, 0)
	self.next_attack = filled(m, 0)
	self.attack_tick = filled(m, 0)
	self.started = filled(m, 0)
	self.tribe_tn = filled(m, 1)
	self.last_delete = filled(m, -1)
	self.aggression = filled(m, 0.0)
	self.naval = filled(m, 0.0)
	self.last_boat = filled(m, 0)
	self.last_nuke = filled(m, -100000)
	self.last_ally_ask = filled(m, 0)
	self.nuke_cool = filled(m, 0)
	self.grace_jitter = filled(m, 0)
	self.attackers_on = filled(m, 0)
	self.last_mopup = filled(m, 0)
	self.last_invasion = filled(m, 0)
	local rng = sim.rng
	for id = 1, m - 1 do
		self.aggression[id] = f32(rng:randf_range(0.8, 1.25))
		self.naval[id] = f32(rng:randf_range(0.5, 1.5))
		self.next_think[id] = id % NATION_THINK
		self.grace_jitter[id] = rng:randi_range(0, Rules.HUMAN_GRACE_JITTER)
		self.last_ally_ask[id] = rng:randi_range(0, 600)
		-- 0.50-0.59 etc., drawn once per AI (nations and tribes alike).
		self.trigger_r[id] = rng:randi_range(50, 59) / 100
		self.reserve_r[id] = rng:randi_range(30, 39) / 100
		self.expand_r[id] = rng:randi_range(10, 19) / 100
		if id % 256 == 0 then
			Coop.check()
		end
	end
	-- A tribe's setup: attackRate and attackTick.
	for id = 1, sim.owner_total do
		if sim.o_kind[id] == KIND_TRIBE then
			self:_tribe_cadence(sim, id)
		end
	end
end

function SimAI:_tribe_cadence(sim, id: number)
	local rate = sim.rng:randi_range(TRIBE_ATTACK_RATE[1], TRIBE_ATTACK_RATE[2])
	self.attack_rate[id] = rate
	self.attack_tick[id] = sim.rng:randi_range(0, rate - 1)
end

function SimAI:tick(sim)
	local t = sim.tick
	if #self.replies > 0 then
		self:_process_replies(sim)
	end
	if #self.extensions > 0 then
		self:_process_extensions(sim)
	end
	if t % 50 == 0 then
		self:_update_leader(sim)
	end
	-- AI nations at war with each owner: live non-counter attacks plus transports under way to it
	-- (a boat launched under the cap must not push a human over it when it lands).
	local attackers_on = self.attackers_on
	for i = 0, Defs.MAX_OWNERS - 1 do
		attackers_on[i] = 0
	end
	local o_kind = sim.o_kind
	local pairs_ = {}
	for _, a in sim.attacks do
		if
			not a.dead
			and not a.counter
			and a.target > 0
			and (o_kind[a.attacker] == KIND_NATION or sim.o_bot[a.attacker] == 1)
		then
			pairs_[a.attacker * 1024 + a.target] = true
		end
	end
	local owner = sim.owner
	for _, u in sim.unit_list do
		if not u.dead and u.kind == U_TRANSPORT and (o_kind[u.owner] == KIND_NATION or sim.o_bot[u.owner] == 1) then
			local tg = readi32(owner, u.target_tile * 4)
			if tg > 0 and o_kind[tg] == KIND_HUMAN then
				pairs_[u.owner * 1024 + tg] = true
			end
		end
	end
	for k in pairs_ do
		attackers_on[k % 1024] += 1
	end
	if #self.doomed > 0 then
		self:_delete_doomed(sim)
	end
	local next_think = self.next_think
	local attack_rate = self.attack_rate
	local attack_tick = self.attack_tick
	local o_ai = sim.o_ai
	local o_alive = sim.o_alive
	local o_spawned = sim.o_spawned
	local rng = sim.rng
	for id = 1, sim.owner_total do
		if o_ai[id] == 0 or o_alive[id] == 0 or o_spawned[id] == 0 then
			continue
		end
		if o_kind[id] == KIND_TRIBE then
			if attack_rate[id] == 0 then
				-- (a tribe added after setup: tests place owners by hand)
				self:_tribe_cadence(sim, id)
			end
			-- Nothing happens off the tribe's attack ticks.
			if t % attack_rate[id] == attack_tick[id] then
				if self.started[id] == 0 then
					self:_tribe_first(sim, id)
				else
					self:_think_tribe(sim, id)
				end
				Coop.check()
			end
			continue
		end
		if next_think[id] > t then
			continue
		end
		if self.started[id] == 0 then
			self:_first_attack(sim, id)
			continue
		end
		next_think[id] = t + NATION_THINK + rng:randi_range(-3, 3)
		self:_think_nation(sim, id)
		-- (a local match's step runs as a Coop job spread over frames: Session._local_process)
		Coop.check()
	end
end

function SimAI:_update_leader(sim)
	local best = 0
	local bt = 0
	local second = 0
	local o_alive = sim.o_alive
	local o_tiles = sim.o_tiles
	for id = 1, sim.owner_total do
		if o_alive[id] == 0 then
			continue
		end
		local n = o_tiles[id]
		if n > bt then
			second = bt
			bt = n
			best = id
		elseif n > second then
			second = n
		end
	end
	self.leader = best
	self.leader_share = if best > 0 then sim:land_share(best) else 0.0
	local rank = self.rank
	local ids = {}
	for id = 1, sim.owner_total do
		rank[id] = 999
		if o_alive[id] == 1 and o_tiles[id] > 0 then
			table.insert(ids, id)
		end
	end
	-- Godot's sort_custom (unstable): owners with equal land get the Godot version's ranks.
	Defs.godot_sort(ids, function(p, q)
		return o_tiles[p] > o_tiles[q]
	end)
	for k = 1, #ids do
		rank[ids[k]] = k
	end
	self.runaway_human = 0
	-- (the runaway leader is a free-for-all rule: FFA only)
	if not sim.team_mode and best > 0 and sim:is_human(best) and self.leader_share >= 0.15 and bt >= 1.3 * second then
		self.runaway_human = best
	end
	self.nukes_in_play = self.nukes_in_play or sim.nukes_launched > 0
end

-- A nation's first act is an expansion with half its troops and its attack decisions
-- then come every attackRate ticks. (Tribes: _tribe_first.)
function SimAI:_first_attack(sim, id: number)
	self.started[id] = 1
	local r = NATION_ATTACK_RATE[sim:ai_difficulty(id)]
	self.attack_rate[id] = sim.rng:randi_range(r[1], r[2])
	self.next_attack[id] = sim.tick + sim.rng:randi_range(0, self.attack_rate[id])
	sim:scan_border(id, math.ceil(400 * sim.R.LEGACY_LIN))
	if sim.sc_neutral > 0 and sim.sc_neutral_tile >= 0 then
		sim:intent_attack(id, sim.sc_neutral_tile, 0.5)
	end
end

-- True (and schedules the next one) when this AI's attackRate cycle comes round.
function SimAI:_attack_due(sim, id: number): boolean
	if sim.tick < self.next_attack[id] then
		return false
	end
	self.next_attack[id] = sim.tick + self.attack_rate[id]
	return true
end

-- Attack size: the share of home troops above `keep` x max troops.
function SimAI._above(sim, id: number, keep: number): number
	local troops = sim.o_troops[id]
	return (troops - keep * math.max(sim.o_cap[id], 1.0)) / math.max(troops, 1.0)
end
local _above = SimAI._above

-- Two owners big enough to be rivals for the win never stay allied.
function SimAI._great_powers(a_share: number, b_share: number): boolean
	return (a_share >= 0.12 and b_share >= 0.08) or (b_share >= 0.12 and a_share >= 0.08)
end
local _great_powers = SimAI._great_powers

-- =============================================================================================
-- Nations
-- =============================================================================================

function SimAI:_think_nation(sim, id: number)
	local age = sim.tick - sim.playing_since
	local troops = sim.o_troops[id]
	local fill = troops / math.max(sim.o_cap[id], 1.0)
	sim:scan_border(id, math.ceil(400 * sim.R.LEGACY_LIN))
	self:_consider_retint(sim, id, age)
	if self:_consider_capitulation(sim, id, age) then
		return
	end
	local defended = self:_defend(sim, id)
	local due = self:_attack_due(sim, id)
	-- Expansion into unclaimed land: everything above expandRatio of max troops.
	local expanded = false
	if due and sim.sc_neutral > 0 and sim.sc_neutral_tile >= 0 then
		local send = _above(sim, id, self.expand_r[id])
		if send * troops >= 1.0 then
			expanded = sim:intent_attack(id, sim.sc_neutral_tile, send)
		end
	end
	local warred = false
	-- While there is clean free land to take, the attack cycle goes to expansion.
	if due and not defended and not expanded then
		warred = self:_consider_war(sim, id, fill, age)
	end
	-- Nuked land: with no clean land to take and no war
	-- started, a nation at its trigger ratio slowly re-settles bordering fallout.
	if
		due
		and not warred
		and not defended
		and sim.sc_neutral == 0
		and sim.sc_fallout_tile >= 0
		and fill >= self.trigger_r[id]
	then
		local send2 = _above(sim, id, self.reserve_r[id]) * 0.5
		if send2 * troops >= 1.0 then
			sim:intent_attack(id, sim.sc_fallout_tile, send2)
		end
	end
	self:_consider_build(sim, id, age)
	if due then
		self:_maybe_spawn_warship(sim, id)
		self:_counter_infestation(sim, id)
	end
	if not warred and sim.sc_neutral == 0 then
		self:_consider_boat(sim, id, age)
	end
	self:_consider_mopup(sim, id, age)
	self:_consider_invasion(sim, id, age)
	self:_consider_nuke(sim, id, age)
	self:_consider_diplomacy(sim, id, age)
end

-- Endgame: a small nation overrun by a far stronger attacker surrenders (see Rules.CAPITULATE_*).
function SimAI:_consider_capitulation(sim, id: number, age: number): boolean
	if age < Rules.CAPITULATE_AGE or sim:land_share(id) >= Rules.CAPITULATE_SHARE then
		return false
	end
	if sim.tick - sim.last_capitulation < Rules.CAPITULATE_GAP then
		return false
	end
	if sim.tick - sim.o_attacked_tick[id] > 40 then
		return false
	end
	local mine = sim.o_troops[id] + 1.0
	for _, a in sim.attacks do
		if a.dead or a.target ~= id or sim.o_kind[a.attacker] == KIND_TRIBE then
			continue
		end
		if sim.o_troops[a.attacker] + a.troops >= Rules.CAPITULATE_RATIO * mine then
			sim:capitulate(id, a.attacker)
			return true
		end
	end
	return false
end

-- Counter-attacks the largest incoming attack when we can afford it. True if we acted.
function SimAI:_defend(sim, id: number): boolean
	if sim.tick - sim.o_attacked_tick[id] > 40 then
		return false
	end
	local worst = nil
	for _, a in sim.attacks do
		if not a.dead and a.target == id and (worst == nil or a.troops > worst.troops) then
			worst = a
		end
	end
	if worst == nil then
		return false
	end
	local x = worst.attacker
	local tile = -1
	if sim.sc_count[x] > 0 then
		tile = sim.sc_tile[x]
	elseif
		worst.last_tile >= 0
		and readi32(sim.owner, worst.last_tile * 4) == x
		and sim:touches(worst.last_tile, id)
	then
		tile = worst.last_tile
	end
	if tile < 0 then
		return false
	end
	local mine = sim.o_troops[id]
	if mine < worst.troops * 1.1 or worst.troops < mine * 0.02 then
		return false
	end
	-- Already answering this attacker with enough troops: don't feed a ping-pong grind.
	local ours = sim:attack_between(id, x)
	if ours ~= nil and ours.troops >= worst.troops * 0.8 then
		return false
	end
	local ratio = math.clamp(worst.troops * 1.25 / math.max(mine, 1.0), 0.05, 0.4)
	return sim:intent_attack(id, tile, ratio)
end

function SimAI:_consider_war(sim, id: number, fill: number, age: number): boolean
	local my_share = sim:land_share(id)
	-- Before a war: save up to reserveRatio, usually to triggerRatio.
	if fill < self.reserve_r[id] then
		return false
	end
	if fill < self.trigger_r[id] and sim.rng:randf() >= 0.1 then
		return false
	end
	local d = sim:ai_difficulty(id)
	-- (towards players a smart bot player is as patient as Easy: Rules.SMART_VS_PLAYERS)
	local hd = sim:human_difficulty(id)
	local mine = sim.o_troops[id]
	local best = -1
	local best_s = 0.0
	local sc_count = sim.sc_count
	local attackers_on = self.attackers_on
	local L = sim.R.LEGACY_LIN
	for _, p in sim.sc_list do
		if sc_count[p] < 2 * L or sim:allied(id, p) then
			continue
		end
		local pk = sim.o_kind[p]
		local at_war = sim:attack_between(id, p) ~= nil
		if
			pk == KIND_HUMAN
			and not at_war
			and (not self:_may_attack_human(sim, id, p, age) or sim.rng:randf() < HUMAN_SKIP[hd])
		then
			continue
		end
		local s = mine / (sim.o_troops[p] + 1.0)
		-- Prefer targets that are not already being dogpiled.
		s *= 0.6 ^ (attackers_on[p] - (if at_war then 1 else 0))
		if pk == KIND_TRIBE then
			s *= 1.5
		end
		if sim:is_traitor(p) then
			s *= 1.3
		end
		if sim:grudge_of(id, p) then
			s *= 1.35
		end
		if at_war then
			s *= 1.2
		end
		if p == self.runaway_human then
			s *= 1.4
		end
		if _great_powers(my_share, sim:land_share(p)) then
			s *= 1.5
		end
		s *= self.aggression[id] * (0.8 + 0.2 * math.min(sc_count[p] / (20.0 * L), 1.0))
		if s > best_s then
			best_s = s
			best = p
		end
	end
	-- Endgame showdown: from minute 20 wars need a smaller edge (x0.5 by minute 35), so the
	-- larger empire's faster regrowth decides the attrition instead of a frozen stalemate.
	local w = math.clamp((age - SimAI.LATE_WAR_FROM) / SimAI.LATE_WAR_SPAN, 0.0, 1.0)
	local need = WAR_RATIO[d] * (1.0 + (0.5 - 1.0) * w)
	if best < 0 or best_s < need then
		return false
	end
	local new_war = sim:attack_between(id, best) == nil
	if new_war and sim:count_attacks_by(id, true) >= (if my_share >= 0.12 then 3 else 2) then
		return false
	end
	-- Send everything above the reserve; only reinforce a front that is running short.
	local ratio = _above(sim, id, self.reserve_r[id])
	if ratio * mine < 1.0 then
		return false
	end
	if not new_war then
		local ex = sim:attack_between(id, best)
		if ex ~= nil and ex.troops > sim.o_troops[best] * 0.8 then
			return false
		end
	end
	local ok = sim:intent_attack(id, sim.sc_tile[best], ratio)
	if ok and new_war then
		attackers_on[best] += 1
	end
	return ok
end

-- Launches a transport; a boat aimed at a human takes a war slot at once (so two AIs deciding
-- in the same tick can't both slip under MAX_AI_WARS_ON_HUMAN).
function SimAI:_boat_at(sim, id: number, tile: number, ratio: number): boolean
	local tg = readi32(sim.owner, tile * 4)
	local ok = sim:launch_boat(id, tile, ratio)
	if ok and tg > 0 and sim:is_human(tg) and sim:attack_between(id, tg) == nil then
		self.attackers_on[tg] += 1
	end
	return ok
end

-- Public check used by the Sim when an AI transport lands on a human's coast.
function SimAI:may_attack_human(sim, id: number, h: number): boolean
	-- Tribes have no human protection: a tribe never skips a human target, and
	-- only human attackers respect spawn immunity.
	if sim.o_kind[id] == KIND_TRIBE then
		return true
	end
	return self:_may_attack_human(sim, id, h, sim.tick - sim.playing_since)
end

-- Human protection: this AI's own grace (global minimum + its random delay + more for distant
-- nations) has passed, and fewer than MAX_AI_WARS_ON_HUMAN nations already fight that human.
function SimAI:_may_attack_human(sim, id: number, h: number, age: number): boolean
	local d = sim:human_difficulty(id)
	local grace = Rules.human_grace_ticks(d) + self.grace_jitter[id]
	if sim:is_novice_bot(id) then
		-- novice bot players leave real players alone for twice as long (~10 min)
		grace *= SimAI.NOVICE_GRACE_MULT
	end
	local a = if sim.o_spawn_tile[id] >= 0 then sim.o_spawn_tile[id] else sim:centre_tile(id)
	local b = sim.o_spawn_tile[h]
	if a >= 0 and b >= 0 then
		-- in tiles of the original grid
		local dist = Defs.trunc(math.sqrt(sim.range_d2(a, b)) / sim.R.LEGACY_LIN)
		grace += math.clamp(
			(dist - Rules.HUMAN_GRACE_NEAR) * Rules.HUMAN_GRACE_PER_TILE,
			0,
			Rules.HUMAN_GRACE_MAX_EXTRA
		)
	end
	if age < grace then
		return false
	end
	if
		(sim.o_kind[id] == KIND_NATION or sim.o_bot[id] == 1)
		and self.attackers_on[h] >= Rules.MAX_AI_WARS_ON_HUMAN[d]
	then
		return false
	end
	return true
end

function SimAI:_consider_boat(sim, id: number, age: number)
	if age < 600 or sim.o_boats[id] >= (if sim:ai_difficulty(id) == 2 then 2 else 1) then
		return
	end
	if sim.tick - self.last_boat[id] < Defs.trunc(300.0 / self.naval[id]) then
		return
	end
	local home_coast = sim:own_coast_tile(id)
	if home_coast < 0 then
		return
	end
	self.last_boat[id] = sim.tick
	local map = sim.map
	local cb = map.coast_body
	local water_body = readu16(cb, home_coast * 2)
	local ct = map.coast_list
	local nct = map.coast_count
	local owner = sim.owner
	local land = sim.land
	local flags = sim.flags
	local mine = sim.o_troops[id]
	local dist2 = sim.dist2
	local L = sim.R.LEGACY_LIN
	local tile_troops = 60.0 * sim.R.LEGACY_AREA
	local best = -1
	local best_s = 0.0
	for _ = 1, 48 do
		local c = readi32(ct, (sim.rng:randi() % nct) * 4)
		if readu16(cb, c * 2) ~= water_body or readu8(land, c) == 0 or bit32.band(readu8(flags, c), 1) ~= 0 then
			continue
		end
		local o = readi32(owner, c * 4)
		if o == id or sim:allied(id, o) then
			continue
		end
		local s = 0.0
		if o == 0 then
			s = 3.0
		else
			local ratio = mine * 0.3 / (sim.o_troops[o] / math.max(sim.o_tiles[o], 1) * tile_troops + 1.0)
			if ratio < 1.0 then
				continue
			end
			if
				sim.o_kind[o] == KIND_HUMAN
				and sim:attack_between(id, o) == nil
				and not self:_may_attack_human(sim, id, o, age)
			then
				continue
			end
			s = 1.0 + math.min(ratio, 3.0) * 0.3
			if sim.o_kind[o] == KIND_TRIBE then
				s *= 1.4
			end
		end
		local dist = math.sqrt(dist2(home_coast, c))
		s /= 1.0 + dist / (110.0 * L)
		if s > best_s then
			best_s = s
			best = c
		end
	end
	if best >= 0 and best_s > 0.35 then
		self:_boat_at(sim, id, best, Rules.BOAT_ATTACK_FRACTION)
	end
end

-- Endgame: a big nation (>= 12 % land) that is not badly outmatched keeps landing 20 % waves on a
-- major rival it can't reach by land, so continents separated by oceans still get decided.
function SimAI:_consider_invasion(sim, id: number, age: number)
	if age < SimAI.INVASION_AGE or sim.tick - self.last_invasion[id] < SimAI.INVASION_GAP then
		return
	end
	self.last_invasion[id] = sim.tick + sim.rng:randi_range(0, 80)
	local share = sim:land_share(id)
	if share < 0.12 or sim.o_boats[id] >= Rules.max_boats(sim.o_tiles[id]) then
		return
	end
	local mine = sim.o_troops[id]
	if mine < math.max(sim.o_cap[id], 1.0) * 0.3 then
		return
	end
	local best = 0
	local best_s = 0.0
	local rank = self.rank
	for p = 1, sim.owner_total do
		if p == id or sim.o_alive[p] == 0 or rank[p] > 8 or sim:allied(id, p) or sim:land_share(p) < 0.04 then
			continue
		end
		if sim.sc_count[p] > 0 or sim.o_coast[p] <= 0 then
			continue
		end
		local theirs = sim.o_troops[p] + 1.0
		if mine < 0.7 * theirs then
			continue
		end
		if sim:is_human(p) and sim:attack_between(id, p) == nil and not self:_may_attack_human(sim, id, p, age) then
			continue
		end
		local s = (mine / theirs) * sim:land_share(p) * (if sim:grudge_of(id, p) then 1.5 else 1.0)
		if s > best_s then
			best_s = s
			best = p
		end
	end
	if best <= 0 then
		return
	end
	local ct = sim.map.coast_list
	local nct = sim.map.coast_count
	local owner = sim.owner
	local flags = sim.flags
	for _ = 1, 300 do
		local c = readi32(ct, (sim.rng:randi() % nct) * 4)
		if readi32(owner, c * 4) == best and bit32.band(readu8(flags, c), 1) == 0 then
			self:_boat_at(sim, id, c, Rules.BOAT_ATTACK_FRACTION)
			return
		end
	end
end

-- Late game: big nations invade small, weak remnants (usually islands they can't reach by land)
-- by sea, so the match can actually end.
function SimAI:_consider_mopup(sim, id: number, age: number)
	if age < SimAI.MOPUP_AGE or sim.tick - self.last_mopup[id] < SimAI.MOPUP_GAP then
		return
	end
	self.last_mopup[id] = sim.tick + sim.rng:randi_range(0, 100)
	local tiles = sim.o_tiles[id]
	if sim:land_share(id) < 0.03 or sim.o_boats[id] >= Rules.max_boats(tiles) then
		return
	end
	local mine = sim.o_troops[id]
	local LA = sim.R.LEGACY_AREA
	local L = sim.R.LEGACY_LIN
	local dist2 = sim.dist2
	local small = math.max(600 * LA, Defs.trunc(0.006 * sim.map.contestable_count))
	local home = sim:own_coast_tile(id)
	if home < 0 then
		return
	end
	local best = 0
	local best_s = 0.0
	for p = 1, sim.owner_total do
		if p == id or sim.o_alive[p] == 0 or sim.o_tiles[p] <= 0 or sim.o_tiles[p] > small or sim:allied(id, p) then
			continue
		end
		if sim.o_troops[p] > 0.2 * mine or sim.o_coast[p] <= 0 then
			continue
		end
		if sim:is_human(p) and sim:attack_between(id, p) == nil and not self:_may_attack_human(sim, id, p, age) then
			continue
		end
		local anchor = if sim.o_spawn_tile[p] >= 0 then sim.o_spawn_tile[p] else home
		local s = 1.0 / (1.0 + math.sqrt(dist2(home, anchor)) / (200.0 * L))
		if sim.sc_count[p] > 0 then
			s *= 0.3
		end
		if s > best_s then
			best_s = s
			best = p
		end
	end
	if best <= 0 then
		return
	end
	local target = sim:own_coast_tile(best)
	if target < 0 then
		return
	end
	local need = (sim.o_troops[best] + sim.o_tiles[best] * 60.0 * LA) * 1.6
	self:_boat_at(sim, id, target, math.clamp(need / math.max(mine, 1.0), 0.05, Rules.BOAT_ATTACK_FRACTION))
end

function SimAI:_consider_nuke(sim, id: number, age: number)
	local d = sim:ai_difficulty(id)
	if age < NUKE_AGE[d] or sim:struct_count(id, Defs.S_SILO) == 0 then
		return
	end
	if sim.tick - self.last_nuke[id] < SimAI.NUKE_GAP then
		return
	end
	local gold = sim.o_gold[id]
	if gold < Rules.NUKE_COST[Defs.N_ATOM] then
		return
	end
	local mine = sim.o_troops[id]
	local best = 0
	local best_s = 0.0
	local nuke_cool = self.nuke_cool
	local LA = sim.R.LEGACY_AREA
	for _, p in sim.sc_list do
		if sim:allied(id, p) or sim.o_kind[p] == KIND_TRIBE or sim.o_tiles[p] < 400 * LA or nuke_cool[p] > sim.tick then
			continue
		end
		if
			sim.o_kind[p] == KIND_HUMAN
			and (age < HUMAN_NUKE_EXTRA or not self:_may_attack_human(sim, id, p, age - HUMAN_NUKE_EXTRA))
		then
			continue
		end
		local s = sim.o_tiles[p] + 0.0
		if sim:grudge_of(id, p) then
			s *= 1.6
		end
		local at_war = sim:grudge_of(id, p) or sim:attack_between(id, p) ~= nil
		if not at_war then
			continue
		end
		if sim.o_troops[p] > mine then
			s *= 1.3
		end
		if s > best_s then
			best_s = s
			best = p
		end
	end
	-- The leader / a runaway human is only a nuke target for rivals that border it or hold a
	-- grudge, and never more than one AI nuke per target per minute (no dogpile collapse).
	for _, p2 in { self.leader, self.runaway_human } do
		if p2 <= 0 or p2 == id or sim:allied(id, p2) or nuke_cool[p2] > sim.tick or sim:land_share(p2) < 0.25 then
			continue
		end
		if sim.sc_count[p2] == 0 and not sim:grudge_of(id, p2) then
			continue
		end
		if sim:is_human(p2) and not self:_may_attack_human(sim, id, p2, age - HUMAN_NUKE_EXTRA) then
			continue
		end
		local s2 = sim.o_tiles[p2] * (if p2 == self.runaway_human then 2.0 else 1.2)
		if s2 > best_s then
			best_s = s2
			best = p2
		end
	end
	if best <= 0 then
		return
	end
	local kind = Defs.N_ATOM
	if
		gold >= Rules.nuke_cost("mirv", sim.mirvs_launched)
		and (best == self.leader or best == self.runaway_human)
		and sim:land_share(best) >= 0.35
	then
		kind = Defs.N_MIRV
	elseif gold >= Rules.NUKE_COST[Defs.N_HYDROGEN] and sim.o_tiles[best] > 2500 * LA then
		kind = Defs.N_HYDROGEN
	end
	local target = self:_nuke_target(sim, id, best, kind)
	if target < 0 then
		return
	end
	self.last_nuke[id] = sim.tick
	if sim:launch_nuke(id, Defs.NUKE_NAMES[kind], target) then
		nuke_cool[best] = sim.tick + SimAI.NUKE_TARGET_COOL
		-- Follow up on the ground while the defender reels.
		if sim.sc_count[best] > 0 and sim.o_troops[id] > sim.o_troops[best] * 0.6 then
			sim:intent_attack(id, sim.sc_tile[best], 0.3)
		end
	end
end

function SimAI:_nuke_target(sim, id: number, p: number, kind: number): number
	local cands = {}
	for _, k in { Defs.S_CITY, Defs.S_SILO, Defs.S_FACTORY, Defs.S_PORT } do
		if sim:struct_count(p, k) > 0 then
			for _, s in sim:structs_of(p, k) do
				table.insert(cands, s.tile)
			end
			if #cands >= 6 then
				break
			end
		end
	end
	if sim.sc_count[p] > 0 then
		table.insert(cands, sim.sc_tile[p])
	end
	local st = sim.o_spawn_tile[p]
	if st >= 0 and readi32(sim.owner, st * 4) == p then
		table.insert(cands, st)
	end
	-- MIRV warheads only ever land on the target's own land.
	local radius = sim.R.NUKE_RADIUS[kind]
	for _ = 1, math.min(#cands, 6) do
		local c = cands[sim.rng:randi() % #cands + 1]
		if kind == Defs.N_MIRV or self:_blast_safe(sim, id, c, radius + 2.0 * sim.R.LEGACY_LIN) then
			return c
		end
	end
	return -1
end

-- True when a blast of `radius` at `c` would not touch allies and would spare most own land.
function SimAI:_blast_safe(sim, id: number, c: number, radius: number): boolean
	local own = 0
	local total = 0
	local W = sim.W
	local cx = c % W
	local cy = c // W
	local r = Defs.trunc(radius)
	local owner = sim.owner
	local rng = sim.rng
	for _ = 1, 40 do
		local x = math.clamp(cx + rng:randi_range(-r, r), 0, W - 1)
		local y = math.clamp(cy + rng:randi_range(-r, r), 0, sim.H - 1)
		local t = y * W + x
		local o = readi32(owner, t * 4)
		if o == 0 then
			continue
		end
		total += 1
		if o == id then
			own += 1
		elseif sim:allied(id, o) then
			return false
		end
	end
	return own * 4 <= total
end

function SimAI:_consider_diplomacy(sim, id: number, age: number)
	if age < 300 or sim.tick - self.last_ally_ask[id] < 600 then
		return
	end
	self.last_ally_ask[id] = sim.tick + sim.rng:randi_range(0, 600)
	local mine = sim.o_troops[id]
	local my_share = sim:land_share(id)
	-- Betrayal: great powers do not tolerate each other for long, dominant nations shed weak
	-- allies that stand in their way, and aggressive nations occasionally stab a weak neighbour.
	if sim.o_ally_count[id] > 0 then
		for _, p in sim:allies_of(id) do
			local ps = sim:land_share(p)
			local chance = 0.0
			if _great_powers(my_share, ps) then
				chance = 0.35
			elseif my_share >= 0.25 and mine > 2.0 * sim.o_troops[p] then
				chance = 0.15
			elseif mine > 3.0 * sim.o_troops[p] and sim.sc_count[p] > 0 then
				chance = 0.04 * self.aggression[id] * (0.5 + 0.5 * sim:ai_difficulty(id))
			end
			if sim:is_human(p) and age < Rules.human_grace_ticks(sim:human_difficulty(id)) * 2 then
				chance *= 0.25
			end
			if chance > 0.0 and sim.rng:randf() < chance then
				sim:ally_break(id, p)
				return
			end
		end
	end
	if sim.o_ally_count[id] >= Rules.AI_MAX_ALLIES or sim.rng:randf() > 0.4 then
		return
	end
	local best = 0
	local best_s = 0.0
	for _, p in sim.sc_list do
		if sim.o_kind[p] == KIND_TRIBE or sim:allied(id, p) or sim:hostile(id, p) or sim:has_request(id, p) then
			continue
		end
		if sim:is_traitor(p) or sim.o_ally_count[p] >= Rules.AI_MAX_ALLIES + (if sim:is_human(p) then 2 else 0) then
			continue
		end
		if _great_powers(my_share, sim:land_share(p)) then
			continue
		end
		local s = sim.o_troops[p] / math.max(mine, 1.0) + sim.rng:randf() * 0.5
		if sim:is_human(p) then
			s += 0.4
		end
		if s > best_s then
			best_s = s
			best = p
		end
	end
	if best > 0 and best_s > 0.6 then
		sim:ally_request(id, best)
	end
end

-- =============================================================================================
-- Alliance replies
-- =============================================================================================

function SimAI:queue_reply(sim, from: number, to: number)
	-- A tribe answers on its next attack tick (see _tribe_answers); the request made this tick is
	-- initialised after this tick's tribe update ran.
	local due = if sim.o_kind[to] == KIND_TRIBE then sim.tick + 1 else sim.tick + sim.rng:randi_range(20, 45)
	table.insert(self.replies, { due, from, to })
end

--- A tribe accepts alliance requests on its attack ticks after its first.
function SimAI:_tribe_answers(sim, id: number): boolean
	return self.started[id] == 1 and sim.tick % self.attack_rate[id] == self.attack_tick[id]
end

function SimAI:_process_replies(sim)
	local keep = {}
	for _, r in self.replies do
		if r[1] > sim.tick then
			table.insert(keep, r)
			continue
		end
		local from = r[2]
		local to = r[3]
		if not sim:has_request(from, to) or sim.o_alive[to] == 0 or sim.o_ai[to] == 0 then
			continue
		end
		if sim.o_kind[to] == KIND_TRIBE then
			-- A tribe accepts every request.
			if self:_tribe_answers(sim, to) then
				sim:ally_reply(to, from, true)
			else
				table.insert(keep, r)
			end
			continue
		end
		sim:ally_reply(to, from, self:_accept(sim, to, from))
	end
	self.replies = keep
end

function SimAI:_accept(sim, me: number, other: number): boolean
	if sim.o_ally_count[me] >= Rules.AI_MAX_ALLIES or sim:grudge_of(me, other) then
		return false
	end
	if _great_powers(sim:land_share(me), sim:land_share(other)) then
		return false
	end
	if sim:attack_between(me, other) ~= nil then
		return false
	end
	local p = 0.3
	local ratio = (sim.o_tiles[other] + 1) / (sim.o_tiles[me] + 1)
	if ratio > 1.5 then
		p += 0.35
	elseif ratio > 0.7 then
		p += 0.2
	end
	if sim:is_human(other) then
		p += 0.15
	end
	if self:_shared_enemy(sim, me, other) then
		p += 0.2
	end
	if sim:is_traitor(other) then
		p = 0.08
	end
	p += ACCEPT_BIAS[sim:ai_difficulty(me)]
	-- Team games: a nation refuses a request outright 25% / 50% / 75% of
	-- the time on Easy / Medium / Hard
	if sim.team_mode and sim.rng:randf() < TEAM_REFUSE[sim:ai_difficulty(me)] then
		return false
	end
	return sim.rng:randf() < p
end

-- =============================================================================================
-- Alliance renewals
-- =============================================================================================
-- AIs never ask to renew (only a human can click "renew"); they answer when only the other
-- side has asked: a tribe always agrees, on its next attack
-- tick (as it accepts every alliance request), a nation agrees when it would accept that player's
-- alliance request (the same decision as for a new request)
-- and, while it declines, reconsiders every attack tick (attackRate: Easy 65-100, Medium 55-70,
-- Hard 45-60 ticks) until the alliance expires. So alliances between two AIs lapse after
-- Rules.ALLIANCE_TICKS.
SimAI.EXTEND_RETRY = zt({ { 65, 100 }, { 55, 70 }, { 45, 60 } })

function SimAI:queue_extension(sim, from: number, to: number)
	local due = if sim.o_kind[to] == KIND_TRIBE then sim.tick + 1 else sim.tick + sim.rng:randi_range(20, 45)
	table.insert(self.extensions, { due, from, to })
end

function SimAI:_process_extensions(sim)
	local keep = {}
	for _, r in self.extensions do
		if r[1] > sim.tick then
			table.insert(keep, r)
			continue
		end
		local from = r[2]
		local to = r[3]
		if
			sim.o_alive[to] == 0
			or sim.o_ai[to] == 0
			or not sim:has_alliance(from, to)
			or not sim:asked_to_extend(from, to)
			or sim:asked_to_extend(to, from)
		then
			continue
		end
		if sim.o_kind[to] == KIND_TRIBE and not self:_tribe_answers(sim, to) then
			-- A tribe renews on its next attack tick.
			table.insert(keep, r)
			continue
		end
		if self:_accept_extension(sim, to, from) then
			sim:ally_extend(to, from)
		else
			local span = SimAI.EXTEND_RETRY[math.clamp(sim:ai_difficulty(to), 0, 2)]
			r[1] = sim.tick + sim.rng:randi_range(span[1], span[2])
			table.insert(keep, r)
		end
	end
	self.extensions = keep
end

--- Would AI `me` renew its alliance with `other`? Tribes always; others decide as for a new
--- request from `other` (_accept), except that the alliance itself does not count against
--- AI_MAX_ALLIES.
function SimAI:_accept_extension(sim, me: number, other: number): boolean
	if sim.o_kind[me] == KIND_TRIBE then
		return true
	end
	if sim:grudge_of(me, other) or _great_powers(sim:land_share(me), sim:land_share(other)) then
		return false
	end
	local p = 0.3
	local ratio = (sim.o_tiles[other] + 1) / (sim.o_tiles[me] + 1)
	if ratio > 1.5 then
		p += 0.35
	elseif ratio > 0.7 then
		p += 0.2
	end
	if sim:is_human(other) then
		p += 0.15
	end
	if self:_shared_enemy(sim, me, other) then
		p += 0.2
	end
	if sim:is_traitor(other) then
		p = 0.08
	end
	p += ACCEPT_BIAS[sim:ai_difficulty(me)]
	return sim.rng:randf() < p
end

-- True when both owners currently hold a grudge against the same third party.
function SimAI:_shared_enemy(sim, a: number, b: number): boolean
	local foes = {}
	local any = false
	local tick = sim.tick
	for k, expiry in sim.grudge do
		if expiry > tick and k // 1024 == a then
			foes[k % 1024] = true
			any = true
		end
	end
	if not any then
		return false
	end
	for k, expiry in sim.grudge do
		if expiry > tick and k // 1024 == b and foes[k % 1024] and k % 1024 ~= a then
			return true
		end
	end
	return false
end

-- =============================================================================================
-- Tribes: the tribe update and the attack choices it makes
-- =============================================================================================
-- A tribe acts only on its attack ticks (tick % attackRate == attackTick; never in the spawn
-- phase). On the first it sends everything above expandRatio x max troops into free land and
-- nothing else (_tribe_send_tn). On every later one it accepts all alliance requests and
-- renewals (_process_replies / _process_extensions), marks one captured structure for deletion
-- (_tribe_delete_next) and then picks an attack:
--   1. a random nearby traitor, 1 time in 3 (no troop threshold);
--   2. while it has only ever seen free land nearby: free land again — the latch goes off for good
--      the first time there is none;
--   3. a random target, only at triggerRatio of max troops or more: the biggest incoming
--      attacker, a traitor (1 in 3), then its nearby players in random order — a nation or human
--      skipped 1 time in 2 — the first it can attack.
-- Troops: a land attack on a player sends everything above reserveRatio x max (expandRatio against
-- a tribe holding structures), free land everything above expandRatio x max; a target only
-- reachable across water gets a transport with troops / 5. No strength check, no human grace.
-- "Nearby" (_tribe_nearby): owners of land next to the border (free land unless fallout),
-- plus what every 10th shore tile sees 5 full-size tiles across a river.

local TRIBE_TRAITOR_ODDS = SimAI.TRIBE_TRAITOR_ODDS
local TRIBE_SKIP_PLAYER_ODDS = SimAI.TRIBE_SKIP_PLAYER_ODDS
local TRIBE_DELETE_COOLDOWN = SimAI.TRIBE_DELETE_COOLDOWN
local TRIBE_DELETE_DELAY = SimAI.TRIBE_DELETE_DELAY
local T_LAKE = Defs.T_LAKE
local F_FALLOUT = Defs.F_FALLOUT
local STRUCTURE_KINDS = { Defs.S_CITY, Defs.S_PORT, Defs.S_FACTORY, Defs.S_DEFENSE, Defs.S_SAM, Defs.S_SILO }
-- Cardinal steps (x, y) of the shore probes.
local PROBE_DX = { 0, 0, -1, 1 }
local PROBE_DY = { -1, 1, 0, 0 }

--- A tribe's first attack tick: it sends an attack
--- into terra nullius; nothing else happens that tick.
function SimAI:_tribe_first(sim, id: number)
	self.started[id] = 1
	sim:scan_border(id, sim.bcount[id])
	self:_tribe_send_tn(sim, id)
end

--- Every later attack tick of a tribe (alliances are answered by _process_replies /
--- _process_extensions at the start of the tick).
function SimAI:_think_tribe(sim, id: number)
	local tn_near = self:_tribe_nearby(sim, id)
	self:_consider_retint(sim, id, sim.tick - sim.playing_since)
	self:_tribe_delete_next(sim, id)
	-- the attack choice
	local rng = sim.rng
	local traitor = self:_tribe_traitor(sim, id)
	-- (the traitor is never an ally, so there is no alliance to break first)
	if traitor > 0 and rng:randi_range(1, TRIBE_TRAITOR_ODDS) == 1 and self:_tribe_send(sim, id, traitor) then
		return
	end
	if self.tribe_tn[id] == 1 then
		if tn_near then
			if self:_tribe_send_tn(sim, id) then
				return
			end
		else
			self.tribe_tn[id] = 0
		end
	end
	self:_tribe_attack_random(sim, id)
end

--- Step 3: a random target, at triggerRatio of max troops or more.
function SimAI:_tribe_attack_random(sim, id: number)
	if sim.o_troops[id] / math.max(sim.o_cap[id], 1.0) < self.trigger_r[id] then
		return
	end
	local rng = sim.rng
	local attacker = self:_tribe_incoming(sim, id)
	if attacker > 0 and self:_tribe_send(sim, id, attacker) then
		return
	end
	local traitor = self:_tribe_traitor(sim, id)
	if traitor > 0 and rng:randi_range(1, TRIBE_TRAITOR_ODDS) == 1 and self:_tribe_send(sim, id, traitor) then
		return
	end
	-- Fisher-Yates shuffle of the nearby list, terra nullius included
	local near = self._near
	for i = #near, 2, -1 do
		local j = rng:randi_range(1, i)
		near[i], near[j] = near[j], near[i]
	end
	local o_kind = sim.o_kind
	for _, p in near do
		if p == 0 or sim:allied(id, p) then
			continue
		end
		if o_kind[p] ~= KIND_TRIBE and rng:randi_range(1, TRIBE_SKIP_PLAYER_ODDS) == 1 then
			continue
		end
		if self:_tribe_send(sim, id, p) then
			return
		end
	end
end

--- Scans the whole border (sc_list / sc_count / sc_tile for the owners of the
--- land next to it, sc_neutral / sc_fallout_tile for unowned land) and fills self._near with what
--- is nearby — the owners next to the border in border order, then the shore probes: every
--- SHORE_PROBE_EVERY-th coastal tile looks SHORE_PROBE_DIST tiles away in each direction whose
--- first step is water. Free land (not fallout) is in the list as 0 (terra nullius, after the land
--- neighbours when it touches the border). True when free land is nearby.
function SimAI:_tribe_nearby(sim, id: number): boolean
	sim:scan_border(id, sim.bcount[id])
	local near = self._near
	local seen = self._near_seen
	table.clear(near)
	table.clear(seen)
	for _, p in sim.sc_list do
		near[#near + 1] = p
		seen[p] = true
	end
	local tn = sim.sc_neutral > 0
	if tn then
		near[#near + 1] = 0
		seen[0] = true
	end
	if sim.o_coast[id] <= 0 then
		return tn
	end
	local R = sim.R
	local every = R.SHORE_PROBE_EVERY
	local dist = R.SHORE_PROBE_DIST
	local W, H = sim.W, sim.H
	local terr = sim.terr
	local land = sim.land
	local owner = sim.owner
	local flags = sim.flags
	local cnext = sim.cnext
	local k = 0
	local c = sim.chead[id]
	while c ~= -1 do
		if k % every == 0 then
			local x = c % W
			local y = c // W
			for d = 1, 4 do
				local dx, dy = PROBE_DX[d], PROBE_DY[d]
				local x1, y1 = x + dx, y + dy
				if x1 < 0 or x1 >= W or y1 < 0 or y1 >= H or readu8(terr, y1 * W + x1) > T_LAKE then
					continue
				end
				local nx, ny = x + dx * dist, y + dy * dist
				if nx < 0 or nx >= W or ny < 0 or ny >= H then
					continue
				end
				local n = ny * W + nx
				if readu8(land, n) ~= 1 then
					continue
				end
				local o = readi32(owner, n * 4)
				if o == id or seen[o] or (o == 0 and bit32.band(readu8(flags, n), F_FALLOUT) ~= 0) then
					continue
				end
				seen[o] = true
				near[#near + 1] = o
				tn = tn or o == 0
			end
		end
		k += 1
		c = cnext[c]
	end
	return tn
end

--- A random nearby traitor that is not an ally (0: none).
function SimAI:_tribe_traitor(sim, id: number): number
	local pick = self._pick
	table.clear(pick)
	for _, p in self._near do
		if p > 0 and sim:is_traitor(p) and not sim:allied(id, p) then
			pick[#pick + 1] = p
		end
	end
	if #pick == 0 then
		return 0
	end
	return pick[sim.rng:randi_range(1, #pick)]
end

--- The incoming attacker (tribe attackers count too): the attacker of the
--- biggest attack on `id` that is not an ally (0: none).
function SimAI:_tribe_incoming(sim, id: number): number
	local best = 0
	local most = 0
	local o_alive = sim.o_alive
	for _, a in sim.attacks do
		if a.dead or a.target ~= id or a.troops <= most or o_alive[a.attacker] == 0 or sim:allied(id, a.attacker) then
			continue
		end
		most = a.troops
		best = a.attacker
	end
	return best
end

--- True when owner `p` holds any structure.
function SimAI._holds_structures(sim, p: number): boolean
	for _, k in STRUCTURE_KINDS do
		if sim:struct_count(p, k) > 0 then
			return true
		end
	end
	return false
end
local _holds_structures = SimAI._holds_structures

--- A tribe's attack on a player: a land attack when it shares a land border with
--- `p` (everything above reserveRatio x max troops, or above expandRatio x max
--- against a tribe that holds structures), else a transport (_tribe_boat).
function SimAI:_tribe_send(sim, id: number, p: number): boolean
	if sim.sc_count[p] > 0 then
		local keep = if sim.o_kind[p] == KIND_TRIBE and _holds_structures(sim, p)
			then self.expand_r[id]
			else self.reserve_r[id]
		local troops = sim.o_troops[id] - sim.o_cap[id] * keep
		if troops < 1.0 then
			return false
		end
		return sim:intent_attack_troops(id, sim.sc_tile[p], troops)
	end
	return self:_tribe_boat(sim, id, p)
end

--- A tribe's attack on free land: a land attack with everything above expandRatio x max
--- troops when unowned land (fallout too) touches the border, else a
--- transport to free land across the water (_tribe_boat_tn). Needs a fresh
--- scan_border of `id`.
function SimAI:_tribe_send_tn(sim, id: number): boolean
	local tile = if sim.sc_neutral_tile >= 0 then sim.sc_neutral_tile else sim.sc_fallout_tile
	if tile >= 0 then
		local troops = sim.o_troops[id] - sim.o_cap[id] * self.expand_r[id]
		if troops < 1.0 then
			return false
		end
		return sim:intent_attack_troops(id, tile, troops)
	end
	return self:_tribe_boat_tn(sim, id)
end

--- A boat to free land: every SHORE_PROBE_EVERY-th coastal tile,
--- each direction whose first step is water: when the tile SHORE_PROBE_DIST away is free land (not
--- fallout), a transport with troops / 5 lands on that shore (the first land along the probe:
--- the closest reachable shore).
function SimAI:_tribe_boat_tn(sim, id: number): boolean
	if sim.o_coast[id] <= 0 or sim.o_boats[id] >= Rules.max_boats() then
		return false
	end
	local R = sim.R
	local every = R.SHORE_PROBE_EVERY
	local dist = R.SHORE_PROBE_DIST
	local W, H = sim.W, sim.H
	local terr = sim.terr
	local land = sim.land
	local owner = sim.owner
	local flags = sim.flags
	local k = 0
	-- (a copy: a launch changes no coast, but keep the walk independent of the list)
	for _, c in sim:coast_tiles(id) do
		k += 1
		if (k - 1) % every ~= 0 then
			continue
		end
		local x = c % W
		local y = c // W
		for d = 1, 4 do
			local dx, dy = PROBE_DX[d], PROBE_DY[d]
			local x1, y1 = x + dx, y + dy
			if x1 < 0 or x1 >= W or y1 < 0 or y1 >= H or readu8(terr, y1 * W + x1) > T_LAKE then
				continue
			end
			local nx, ny = x + dx * dist, y + dy * dist
			if nx < 0 or nx >= W or ny < 0 or ny >= H then
				continue
			end
			local n = ny * W + nx
			if
				readu8(land, n) ~= 1
				or readi32(owner, n * 4) ~= 0
				or bit32.band(readu8(flags, n), F_FALLOUT) ~= 0
			then
				continue
			end
			local shore = -1
			for s = 2, dist do
				local t = (y + dy * s) * W + x + dx * s
				if readu8(terr, t) > T_LAKE then
					shore = t
					break
				end
			end
			if
				shore < 0
				or readu8(land, shore) ~= 1
				or readi32(owner, shore * 4) ~= 0
				or bit32.band(readu8(flags, shore), F_FALLOUT) ~= 0
			then
				continue
			end
			if sim.o_troops[id] / 5 < 1.0 then
				return false
			end
			if sim:launch_boat(id, shore, Rules.BOAT_ATTACK_FRACTION) then
				return true
			end
		end
	end
	return false
end

--- Closest pair of tiles: both lists sorted by x, then a sweep keeping the closest (manhattan) pair
--- it passes. Returns the tile of `ys` of that pair (-1 when a list is empty).
function SimAI._closest_two(W: number, xs: { number }, ys: { number }): number
	if #xs == 0 or #ys == 0 then
		return -1
	end
	local function by_x(a: number, b: number): boolean
		local ax, bx = a % W, b % W
		if ax ~= bx then
			return ax < bx
		end
		return a < b
	end
	table.sort(xs, by_x)
	table.sort(ys, by_x)
	local i, j = 1, 1
	local nx, ny = #xs, #ys
	local best = math.huge
	local result = ys[1]
	while i <= nx and j <= ny do
		local a, b = xs[i], ys[j]
		local ax, bx = a % W, b % W
		local d = math.abs(ax - bx) + math.abs(a // W - b // W)
		if d < best then
			best = d
			result = b
		end
		-- At the end of xs move along ys, at the end of ys along xs, else the one with smaller x.
		if i ~= nx and (j == ny or ax < bx) then
			i += 1
		else
			j += 1
		end
	end
	return result
end
local _closest_two = SimAI._closest_two

--- A tribe's boat attack: a transport with troops / 5 to the shore tile of `p` closest to
--- ours (_closest_two).
function SimAI:_tribe_boat(sim, id: number, p: number): boolean
	if sim.o_coast[id] <= 0 or sim.o_coast[p] <= 0 or sim.o_boats[id] >= Rules.max_boats() then
		return false
	end
	local dst = _closest_two(sim.W, sim:coast_tiles(id), sim:coast_tiles(p))
	if dst < 0 then
		return false
	end
	return sim:launch_boat(id, dst, Rules.BOAT_ATTACK_FRACTION)
end

--- Tribe structure deletion: once the delete cooldown (TRIBE_DELETE_COOLDOWN) is over,
--- the tribe's first structure (in the order it got them) not yet marked is marked for deletion
--- and goes TRIBE_DELETE_DELAY ticks later unless captured first.
function SimAI:_tribe_delete_next(sim, id: number)
	if sim.tick - self.last_delete[id] < TRIBE_DELETE_COOLDOWN or not _holds_structures(sim, id) then
		return
	end
	local first = nil
	for _, s in sim.struct_list do
		if not s.dead and s.owner == id and s.delete_at == 0 and (first == nil or s.owned_seq < first.owned_seq) then
			first = s
		end
	end
	if first == nil then
		return
	end
	self.last_delete[id] = sim.tick
	first.delete_at = sim.tick + TRIBE_DELETE_DELAY
	table.insert(self.doomed, first)
end

--- Marked structures go once overdue; a capture in
--- the meantime cleared the mark (a change of owner clears it).
function SimAI:_delete_doomed(sim)
	local keep = {}
	for _, s in self.doomed do
		if s.dead or s.delete_at == 0 then
			continue
		end
		if sim.tick > s.delete_at then
			sim:destroy_struct(s)
		else
			keep[#keep + 1] = s
		end
	end
	self.doomed = keep
end

return SimAI
