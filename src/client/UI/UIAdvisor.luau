-- Port of scripts/ui/ui_advisor.gd
-- Reactions to the match for the HUD: sounds and toasts for game events that involve you, threat
-- warnings (a neighbour massing 5x your army, being attacked), first-match coach-mark triggers and
-- filtering of Sim messages that the UI already presents in a richer form.

local UICtx = require("./UICtx") :: any
local Defs = UICtx.core("Defs")

local _T: any = nil
local function T(): any
	if _T == nil then
		_T = UICtx.mod("UITheme")
	end
	return _T
end
local _Rules: any = nil
local function Rules(): any
	if _Rules == nil then
		_Rules = UICtx.core("Rules")
	end
	return _Rules
end

local UIAdvisor = {}
UIAdvisor.__index = UIAdvisor

function UIAdvisor.new(root: any)
	local self = setmetatable({}, UIAdvisor)
	self.ui = root
	self.ctx = root.ctx
	--- Cool-downs for warnings, keyed "atk:<id>" / "big:<id>" -> msec.
	self._warned = {} :: { [string]: number }
	--- nuke uid -> owner of the SAM that fired at it (from sam_launched).
	self._sam_by_nuke = {} :: { [number]: number }
	--- MIRV volleys: nuke owner -> {total, down_by_me, down_mine, sam, msec}.
	self._volleys = {} :: { [number]: { [string]: number } }
	--- Shells in flight: id -> {target_uid, last known target tile, own involved}.
	self._shells = {} :: { [number]: { any } }
	self._throttle = {} :: { [string]: number }
	--- Own warships: announce a retreat for repairs once per retreat and each veterancy rank gained.
	self._ship_state = {} :: { [number]: number }
	self._ship_vet = {} :: { [number]: number }
	--- ally -> the expires_at whose renewal window we already prompted for.
	self._renew_prompted = {} :: { [number]: number }
	return self
end

function UIAdvisor.reset(self: any)
	table.clear(self._warned)
	table.clear(self._renew_prompted)
end

--- Alliance renewals: when an alliance of ours enters its
--- renewal window (the last ALLIANCE_EXTEND_WINDOW_TICKS), a Renew / Ignore card, once per window.
--- The card closes once we asked, the alliance was renewed or it ended.
function UIAdvisor.check_renewals(self: any)
	local ctx = self.ctx
	local s = ctx.state
	local feed = self.ui.feed
	local me = ctx:me()
	if s == nil or me == 0 or not ctx:in_match() then
		return
	end
	local live = {}
	for _, other in s:allies_of(me) do
		live[other] = true
		local ai = s:alliance_info(me, other)
		if ai ~= nil and ai.can_extend then
			if self._renew_prompted[other] ~= ai.expires_at then
				self._renew_prompted[other] = ai.expires_at
				feed:alliance_renewal(other, ai.expires_at, ai.other_asked)
				ctx:sfx("ally_request")
			end
		elseif feed:has_renewal_card(other) then
			feed:close_renewal(other)
		end
	end
	for other in self._renew_prompted do
		if not live[other] then
			self._renew_prompted[other] = nil
			feed:close_renewal(other)
		end
	end
end

function UIAdvisor.cooldown(self: any, key: string, ms: number): boolean
	local now = UICtx.msec()
	local w = self._warned[key]
	if w ~= nil and now - w < ms then
		return false
	end
	self._warned[key] = now
	return true
end

--- A neighbour massing 5x our army is worth a warning before it strikes.
function UIAdvisor.check_threats(self: any)
	local ctx = self.ctx
	local s = ctx.state
	local o = ctx:my()
	if s == nil or o == nil or not ctx:alive_player() or s.phase ~= Defs.PHASE_PLAYING or o.troops <= 0 then
		return
	end
	local worst = 0
	local worst_troops = 0
	for _, id in ctx.borders:neighbour_ids() do
		local n = s:get_owner(id)
		if n == nil or not n.alive or s:are_allies(o.id, id) then
			continue
		end
		if n.troops >= 5 * o.troops and n.troops > worst_troops then
			worst = id
			worst_troops = n.troops
		end
	end
	if worst ~= 0 and self:cooldown("big:" .. worst, 120000) and self:cooldown("big:any", 25000) then
		local ratio_x = math.floor(worst_troops / math.max(o.troops, 1))
		self.ui.feed:toast(
			Defs.MSG_BAD,
			string.format(
				"%s (%s troops) borders you with %d× your army. Fortify or find allies.",
				s:owner_name(worst),
				T().fmt_troops(worst_troops),
				ratio_x
			),
			"defense"
		)
	end
end

--- First-match coach marks driven by what is happening.
function UIAdvisor.check_tips(self: any)
	local ctx = self.ctx
	local ui = self.ui
	local s = ctx.state
	local o = ctx:my()
	if s == nil or o == nil or not ctx:alive_player() or s.phase ~= Defs.PHASE_PLAYING or ui:screen() ~= "play" then
		return
	end
	local secs = ctx:match_seconds()
	if secs > 3.4 then -- after "THE WAR BEGINS" has faded
		ui.coach:offer("expand", function()
			return self:frontier_point()
		end)
	end
	if secs > 22.0 then
		ui.coach:offer("ratio", function()
			local sl = ui.bar._slider
			if sl ~= nil and sl:is_visible_in_tree() then
				return UICtx.rect_center(sl:get_global_rect())
			end
			return Vector2.new(-1, -1)
		end)
	end
	local city_cost = ctx.rules:cost("city")
	if secs > 25.0 and o.gold >= city_cost and city_cost > 0 then
		ui.coach:offer("city", function()
			local cb = ui.bar:button("city")
			local b = if cb ~= nil and cb:is_visible_in_tree() then cb else ui.bar._tray_btn
			if b ~= nil and b:is_visible_in_tree() then
				return UICtx.rect_center(b:get_global_rect())
			end
			return Vector2.new(-1, -1)
		end)
	end
	local ns = ctx.borders:neighbour_ids()
	if #ns > 0 and secs > 8.0 then
		local first = ns[1]
		ui.coach:offer("contact", function()
			return if s:get_owner(first) ~= nil then ctx:tile_screen_pos(s:label_tile(first)) else Vector2.new(-1, -1)
		end, s:owner_name(first))
	end
	if ctx.borders:has_coast() and secs > 40.0 then
		ui.coach:offer("boat")
	end
end

--- A new player's floor under the army outside the tutorial (which keeps its own while it runs):
--- in the player's first Data/Tutorial.ROOKIE_MATCHES matches an order leaves ROOKIE_FLOOR of the
--- army's cap at home, from the first time the army reaches FLOOR_ARM of it (UICtx.troop_floor;
--- UIRoot clears it for every new match).
function UIAdvisor.check_floor(self: any)
	local ui = self.ui
	local ctx = self.ctx
	if ctx.troop_floor ~= nil or (ui.tutorial ~= nil and ui.tutorial.active) or not ctx:alive_player() then
		return
	end
	local o = ctx:my()
	local Tut = UICtx.data("Tutorial")
	if o == nil or not Tut.rookie(ui.telemetry:matches_before()) then
		return
	end
	if (o.max_troops or 0) > 0 and (o.troops or 0) >= Tut.FLOOR_ARM * o.max_troops then
		ctx.troop_floor = Tut.ROOKIE_FLOOR
	end
end

--- The floor held an order back (UICtx.floor_held): the first time in a match, and then at most
--- once a minute, a tip on the Attack bar says why (the tutorial's card does while it runs).
function UIAdvisor.on_floor_held(self: any)
	local ui = self.ui
	if (ui.tutorial ~= nil and ui.tutorial.active) or not self:cooldown("floor", 60000) then
		return
	end
	ui.coach:offer("floor", function()
		local sl = ui.bar._slider
		if sl ~= nil and sl:is_visible_in_tree() then
			return UICtx.rect_center(sl:get_global_rect())
		end
		return Vector2.new(-1, -1)
	end)
end

--- Screen point of a neutral tile on our frontier (for the "expand" tip), or (-1, -1).
function UIAdvisor.frontier_point(self: any): Vector2
	local ctx = self.ctx
	local s = ctx.state
	if s == nil then
		return Vector2.new(-1, -1)
	end
	local me = ctx:me()
	local n = 0
	local map = s.map
	for t in ctx.borders.border do
		n += 1
		if n > 400 then
			break
		end
		for _, nb in map:neighbors4(t) do
			if s:tile_owner(nb) == 0 and map:is_contestable(nb) and not s:has_fallout(nb) then
				local p = ctx:tile_screen_pos(nb)
				if p.X >= 0.0 then
					return p
				end
			end
		end
	end
	return if me ~= 0 then ctx:tile_screen_pos(s:label_tile(me)) else Vector2.new(-1, -1)
end

--- Sim messages the interface already shows in a richer form (cards, threat toasts, alliance toasts).
function UIAdvisor.duplicate_message(text: string): boolean
	local low = string.lower(text)
	local function has(sub: string): boolean
		return string.find(low, sub, 1, true) ~= nil
	end
	if has("alliance") and (has("request") or has("propos")) and not has("did not answer") and not has("declined") then
		return true
	end
	if string.sub(low, -#"is attacking you!") == "is attacking you!" then
		return true
	end
	if
		string.sub(low, 1, #"you are now allied with") == "you are now allied with"
		or has("betrayed your alliance")
		or string.sub(low, 1, #"you broke your alliance") == "you broke your alliance"
	then
		return true
	end
	return false
end

-- ---------------------------------------------------------------------------------------------
-- GameState events (connected by UIRoot._bind_state)
-- ---------------------------------------------------------------------------------------------

--- The sound of your border growing (2026-10-04):
--- every batch of tile changes, the land the local player just gained goes to AudioDirector.pop,
--- which turns it into a run of pops (their rate follows the speed, see AudioDirector.POP_*).
--- `changed` = GameState.tiles_changed: { tile * 1024 + new owner }.
function UIAdvisor.on_tiles_changed(self: any, changed: { number })
	local ctx = self.ctx
	local a = ctx.audio
	local me = ctx:me()
	local s = ctx.state
	if me == 0 or s == nil or a == nil or type(a.pop) ~= "function" or not ctx:in_match() then
		return
	end
	if s.phase ~= Defs.PHASE_PLAYING then
		return -- (picking a start has its own sound)
	end
	local n = 0
	for _, v in changed do
		if v % 1024 == me then
			n += 1
		end
	end
	if n == 0 then
		return
	end
	local R = s.rules or Rules()
	local progress = 0.0
	local o = ctx:my()
	if o ~= nil and s.map ~= nil then
		local land = math.max((s.map.land_count or 0) - (s.fallout_count or 0), 1)
		progress = (o.tiles or 0) / (land * R.WIN_SHARE)
	end
	a:pop(n * (R.K_AREA or 1), progress)
end

function UIAdvisor.on_structure_added(self: any, sid: number)
	local ctx = self.ctx
	local st = ctx.state.structures[sid]
	if st == nil or not ctx.rules:on_structure(st.kind, 0, st.owner) then
		return
	end
	if ctx:in_match() then
		ctx:sfx("build")
	end
	self.ui.bar:refresh_buttons()
end

function UIAdvisor.on_unit_added(self: any, uid: number)
	local ctx = self.ctx
	local u = ctx.state.units[uid]
	if u == nil or not ctx.rules:on_unit(u.kind, u.owner, 1) then
		return
	end
	if u.kind == Defs.U_TRANSPORT then
		ctx:sfx("boat")
	elseif u.kind == Defs.U_WARSHIP then
		ctx:sfx("warship")
		self.ui.bar:refresh_buttons()
	end
end

function UIAdvisor.on_nuke_launched(self: any, uid: number)
	local ctx = self.ctx
	local n = ctx.state.nukes[uid]
	if n == nil or not ctx:in_match() then
		return
	end
	-- a shell, an air strike, a slug (the Arsenal): a shot, never the nuke alarm
	if Rules().NUKE_FLAT[n.kind] then
		local mine = n.owner == ctx:me() and ctx:me() ~= 0
		if n.kind == Defs.N_SHELL then
			if ctx:tile_screen_pos(n.from_tile).X >= 0.0 then
				ctx:sfx("shell_fire", if mine then -8.0 else -12.0, 0.08)
			end
		elseif mine or ctx:tile_screen_pos(n.from_tile).X >= 0.0 then
			ctx:sfx(if n.kind == Defs.N_SLUG then "shell_fire" else "sam_launch", if mine then -2.0 else -8.0, 0.0, if n.kind == Defs.N_SLUG then 0.6 else 0.85)
		end
		return
	end
	self:on_warhead_launched(n)
	if n.owner == ctx:me() and ctx:me() ~= 0 and n.kind ~= Defs.N_WARHEAD then
		ctx:sfx("nuke_launch")
	end
	local aimed_at_me, banner_came_up = self.ui.alert:track(uid)
	if aimed_at_me then
		ctx:sfx("alarm")
		-- (the banner is placed when it comes up: its width is fixed, so the hundreds of warheads that
		-- follow a MIRV's first don't move it)
		if banner_came_up then
			self.ui:relayout_alert()
		end
	end
end

--- BOOM radius: > 0 blast, 0 = shot down by a SAM, -1 = MIRV split into warheads (no blast).
function UIAdvisor.on_nuke_detonated(
	self: any,
	uid: number,
	kind: number,
	tile: number,
	radius: number,
	owner_id: number
)
	local ctx = self.ctx
	self.ui.alert:resolve(uid, radius == 0)
	if not ctx:in_match() or radius < 0 then
		return
	end
	local near = ctx:tile_screen_pos(tile).X >= 0.0
	local me = ctx:me()
	local mine = me ~= 0 and (owner_id == me or ctx.state:tile_owner(tile) == me)
	-- a strike (the Arsenal): a hit, not a nuclear blast (no ducked music for a shell every few seconds)
	if Rules().NUKE_FLAT[kind] then
		if kind == Defs.N_SHELL then
			if near then
				ctx:sfx("shell_hit", if mine then -6.0 else -11.0, 0.08)
			end
		elseif near or mine then
			ctx:sfx("intercept", if mine then -1.0 else -6.0, 0.0, if kind == Defs.N_SLUG then 1.25 else 0.8)
		end
		return
	end
	if radius == 0 then
		local sam_owner = self._sam_by_nuke[uid] or 0
		self._sam_by_nuke[uid] = nil
		-- (silent: the message says it)
		self:_note_intercept(kind, owner_id, sam_owner)
		return
	end
	if near or mine then
		ctx:sfx("explosion", if mine then 0.0 else -3.0)
	end
end

-- ---------------------------------------------------------------------------------------------
-- SAM interceptions
-- ---------------------------------------------------------------------------------------------

local SAM_FIELDS = { "sam_sid", "nuke_uid", "fire_tick", "intercept_tick", "will_hit" }

local function rec_field(rec: any, fname: string, fallback: any): any
	if type(rec) == "table" then
		local v = rec[fname]
		if v ~= nil then
			return v
		end
		local i = table.find(SAM_FIELDS, fname)
		if i ~= nil and rec[i] ~= nil then
			return rec[i]
		end
	end
	return fallback
end
UIAdvisor._rec_field = rec_field

--- Sim SAM_LAUNCH via GameState.sam_launched(nuke_uid). Reads the launch record defensively.
function UIAdvisor.on_sam_launched(self: any, id: number)
	local ctx = self.ctx
	local s = ctx.state
	if s == nil or not ctx:in_match() then
		return
	end
	local rec = nil
	for _, store in { "sam_missiles", "sam_launches", "sam_shots" } do
		local d = s[store]
		if type(d) == "table" and d[id] ~= nil then
			rec = d[id]
			break
		end
	end
	local sam_sid = tonumber(rec_field(rec, "sam_sid", 0)) or 0
	local nuke_uid = tonumber(rec_field(rec, "nuke_uid", id)) or id
	local st = s.structures[sam_sid]
	local sam_owner = if st ~= nil then st.owner else 0
	if nuke_uid ~= 0 then
		self._sam_by_nuke[nuke_uid] = sam_owner
	end
end

-- ---------------------------------------------------------------------------------------------
-- Naval combat sounds
-- ---------------------------------------------------------------------------------------------

--- Volume (dB) for a combat sound (shells, sinkings, SAM launches): full when the local player is
--- involved, otherwise silent (-100). Other players' fights make no sound: on-screen battles between
--- others made a constant patter of unexplained noises (2026-09-26).
function UIAdvisor.combat_level(_self: any, _tile: number, own: boolean): number
	return if own then 0.0 else -100.0
end

function UIAdvisor._unit_owner(self: any, uid: number): number
	local u = self.ctx.state.units[uid]
	return if u ~= nil then u.owner else 0
end

--- Where a unit is now (warships sit on path[1]; others move along their path).
function UIAdvisor._unit_tile(self: any, uid: number): number
	local ctx = self.ctx
	local u = ctx.state.units[uid]
	if u == nil or u.path == nil or #u.path == 0 then
		return -1
	end
	if u.kind == Defs.U_WARSHIP then
		return u.path[1]
	end
	local px, py, pz = ctx.state:unit_pose_xyz(u, ctx:render_tick())
	return Defs.xyz_tile(px, py, pz)
end

function UIAdvisor.on_shell_fired(self: any, id: number)
	local ctx = self.ctx
	local s = ctx.state
	local sh = if s ~= nil then s.shells[id] else nil
	if sh == nil or not ctx:in_match() then
		return
	end
	local shooter = 0
	if sh.shooter_kind == 0 then
		shooter = self:_unit_owner(sh.shooter_id)
	else
		local st = s.structures[sh.shooter_id]
		shooter = if st ~= nil then st.owner else 0
	end
	local me = ctx:me()
	local own = me ~= 0 and (shooter == me or self:_unit_owner(sh.target_uid) == me)
	self._shells[id] = { sh.target_uid, self:_unit_tile(sh.target_uid), own }
end

--- (warship and defense-post gunfire is silent: every shot, hit and splash made a
--- constant racket once the player had a warship out, 2026-09-27)
function UIAdvisor.on_shell_impact(self: any, id: number, _hit: boolean)
	self._shells[id] = nil
end

--- A unit is gone: forget its warship bookkeeping (sinkings make no sound).
function UIAdvisor.on_unit_removed(self: any, uid: number, _reason: number)
	self._ship_state[uid] = nil
	self._ship_vet[uid] = nil
end

--- An intercept: toast for the local player (one per volley for MIRV warheads).
function UIAdvisor._note_intercept(self: any, kind: number, nuke_owner: number, sam_owner: number)
	local ctx = self.ctx
	local me = ctx:me()
	if me == 0 or (sam_owner ~= me and nuke_owner ~= me) then
		return
	end
	local s = ctx.state
	if kind == Defs.N_WARHEAD then
		local v = self._volleys[nuke_owner] or { total = 0, down_by_me = 0, down_mine = 0, sam = 0, msec = 0 }
		if sam_owner == me then
			v.down_by_me += 1
		end
		if nuke_owner == me then
			v.down_mine += 1
			v.sam = sam_owner
		end
		v.msec = UICtx.msec()
		self._volleys[nuke_owner] = v
		return
	end
	local what = if kind >= 0 and kind < Defs.NUKE_KIND_COUNT then Defs.NUKE_TITLES[kind] else "nuke"
	if not self:cooldown(string.format("icpt:%d:%d", sam_owner, nuke_owner), 2500) then
		return
	end
	if sam_owner == me then
		self.ui.feed:toast(
			Defs.MSG_GOOD,
			string.format("Your SAM shot down %s's %s", s:owner_name(nuke_owner), what),
			"sam"
		)
	else
		self.ui.feed:toast(
			Defs.MSG_BAD,
			string.format("%s's SAM intercepted your %s", if sam_owner ~= 0 then s:owner_name(sam_owner) else "A", what),
			"sam"
		)
	end
end

--- Counts MIRV warheads as they launch (the volley total) and reports each volley once it is over.
function UIAdvisor.on_warhead_launched(self: any, n: any)
	if n.kind ~= Defs.N_WARHEAD then
		return
	end
	local v = self._volleys[n.owner] or { total = 0, down_by_me = 0, down_mine = 0, sam = 0, msec = 0 }
	v.total += 1
	v.msec = UICtx.msec()
	self._volleys[n.owner] = v
end

--- Called about once a second: flush volleys that have been quiet for a while.
function UIAdvisor.flush_volleys(self: any)
	local ctx = self.ctx
	local now = UICtx.msec()
	local s = ctx.state
	local done = {}
	for owner_id, v in self._volleys do
		if now - v.msec >= 3000 then
			table.insert(done, owner_id)
		end
	end
	table.sort(done)
	for _, owner_id in done do
		local v = self._volleys[owner_id]
		self._volleys[owner_id] = nil
		if s == nil or not ctx:in_match() then
			continue
		end
		local total = math.max(v.total, math.max(v.down_by_me, v.down_mine))
		if v.down_by_me > 0 then
			self.ui.feed:toast(
				Defs.MSG_GOOD,
				string.format(
					"Your SAMs shot down %d of %d warheads from %s",
					v.down_by_me,
					total,
					s:owner_name(owner_id)
				),
				"sam"
			)
		elseif v.down_mine > 0 then
			self.ui.feed:toast(
				Defs.MSG_BAD,
				string.format("SAMs shot down %d of your %d warheads", v.down_mine, total),
				"sam"
			)
		end
	end
end

function UIAdvisor.on_attack_started(self: any, aid: number)
	local ctx = self.ctx
	local ui = self.ui
	ui.attacks:mark_dirty()
	local a = ctx.state.attacks[aid]
	local me = ctx:me()
	if a == nil or me == 0 or not ctx:in_match() then
		return
	end
	-- (no sound for launching or receiving attacks: they were more annoying
	-- than useful, 2026-09-27)
	if a.attacker == me then
		return
	end
	if a.target == me and a.attacker ~= 0 and ctx:alive_player() then
		local att = ctx.state:get_owner(a.attacker)
		if att ~= nil and self:cooldown("atk:" .. a.attacker, 20000) then
			ui.feed:toast(
				Defs.MSG_ALERT,
				string.format("%s (%s) is attacking you!", att.name, T().fmt_troops(att.troops)),
				"attack"
			)
		end
		ui.coach:offer("attacked", function()
			local p = ui.attacks.panel
			if p ~= nil and p.visible then
				return UICtx.rect_center(p:get_global_rect())
			end
			return Vector2.new(-1, -1)
		end)
	end
end

function UIAdvisor.on_alliance_requested(self: any, from: number, to: number)
	local ctx = self.ctx
	if to == ctx:me() and to ~= 0 and ctx:in_match() then
		self.ui.feed:alliance_request(from)
		ctx:sfx("ally_request")
	end
end

function UIAdvisor.on_alliance_request_closed(self: any, from: number, to: number)
	if to == self.ctx:me() then
		self.ui.feed:close_request(from)
	end
end

function UIAdvisor.on_alliance_changed(
	self: any,
	a: number,
	b: number,
	formed: boolean,
	traitor: number,
	expired: boolean?
)
	local ctx = self.ctx
	local ui = self.ui
	ui.board:mark_dirty()
	local me = ctx:me()
	if me == 0 or (a ~= me and b ~= me) or not ctx:in_match() then
		return
	end
	local other = if a == me then b else a
	local nm = ctx.state:owner_name(other)
	ui.feed:close_request(other)
	if formed then
		ctx:sfx("alliance")
		ui.feed:toast(Defs.MSG_ALLIANCE, "Alliance formed with " .. nm, "alliance")
	elseif traitor == me then
		ctx:sfx("betrayal")
		ui.feed:toast(
			Defs.MSG_BAD,
			string.format(
				"You broke your alliance with %s. For %d s you are a Traitor: attacks on you cost half the troops.",
				nm,
				Rules().TRAITOR_TICKS // Defs.TICK_RATE
			),
			"betray"
		)
	elseif traitor == other then
		ctx:sfx("betrayal")
		ui.feed:toast(Defs.MSG_ALERT, nm .. " betrayed you!", "betray")
	elseif not expired then
		-- (an expiry is announced by the Sim's own message)
		ui.feed:toast(Defs.MSG_INFO, "Your alliance with " .. nm .. " has ended", "alliance")
	end
	ui.feed:close_renewal(other)
	ui.bar:refresh_buttons()
end

--- Which naval event a Sim message reports ("" = none).
function UIAdvisor._naval_sfx(text: string): string
	local t = string.lower(text)
	local function has(sub: string): boolean
		return string.find(t, sub, 1, true) ~= nil
	end
	if has("sank your") or has("your transport was sunk") or has("your warship was sunk") then
		return "ship_lost"
	end
	if has("you sank") or has("your warship sank") then
		return "ship_kill"
	end
	if has("captured a trade ship") and string.sub(t, 1, 4) == "your" then
		return "trade_captured"
	end
	if has("trade ship") then
		return "trade_lost"
	end
	return ""
end

function UIAdvisor.on_message(self: any, _to: number, category: number, text: string)
	local ctx = self.ctx
	if not ctx:in_match() or UIAdvisor.duplicate_message(text) then
		return
	end
	-- Naval news from the Sim: a sound per kind (throttled), and repeated captures fold together.
	local naval = UIAdvisor._naval_sfx(text)
	if naval == "trade_captured" and self:_throttled("toast_capture", 6000) then
		return
	end
	self.ui.feed:toast(category, text, if naval ~= "" then "warship" else "")
	-- (naval news is silent — sinkings and trade captures played every few seconds
	-- once warships were out and grew annoying, 2026-09-27)
	if naval == "" and category == Defs.MSG_ALERT then
		ctx:sfx("toast", -4.0)
	end
end

function UIAdvisor._throttled(self: any, key: string, ms: number): boolean
	local now = UICtx.msec()
	if now - (self._throttle[key] or -1000000) < ms then
		return true
	end
	self._throttle[key] = now
	return false
end

function UIAdvisor.on_unit_changed(self: any, uid: number)
	local ctx = self.ctx
	local ui = self.ui
	local s = ctx.state
	local u = if s ~= nil then s.units[uid] else nil
	if u == nil or u.kind ~= Defs.U_WARSHIP or u.owner ~= ctx:me() or ctx:me() == 0 or not ctx:in_match() then
		return
	end
	local stt = tonumber(u.state) or 0
	local prev = self._ship_state[uid] or 0
	self._ship_state[uid] = stt
	if stt == 1 and prev ~= 1 and not self:_throttled("retreat", 8000) then
		ui.feed:toast(Defs.MSG_INFO, "Your warship is returning to port for repairs", "warship")
	end
	local vet = tonumber(u.veterancy) or 0
	local pv = self._ship_vet[uid] or 0
	self._ship_vet[uid] = vet
	if vet > pv and not self:_throttled("vet", 3000) then
		ui.feed:toast(Defs.MSG_GOOD, string.format("Your warship reached veterancy %d", vet), "warship")
	end
	if ui.unit_card.is_open and ui.unit_card.uid == uid then
		ui.unit_card:refresh()
	end
end

-- ---------------------------------------------------------------------------------------------
-- Match end: elimination, game over, the war-begins moment
-- ---------------------------------------------------------------------------------------------

function UIAdvisor.track_stats(self: any)
	local ctx = self.ctx
	local ui = self.ui
	local s = ctx.state
	local o = ctx:my()
	if s ~= nil and o ~= nil and ctx:in_match() and o.alive then
		ui._stats.peak_share = math.max(ui._stats.peak_share or 0.0, s:land_share(o.id))
		ui._stats.max_troops = math.max(ui._stats.max_troops or 0, o.troops)
	end
end

function UIAdvisor.on_owner_eliminated(self: any, id: number, killer: number)
	local ctx = self.ctx
	local ui = self.ui
	ui.board:mark_dirty()
	if not ctx:in_match() then
		return
	end
	local me = ctx:me()
	local st = ui._stats
	if killer == me and me ~= 0 and id ~= me then
		st.kills = (st.kills or 0) + 1
		ctx:sfx("eliminate")
	end
	if id == me and me ~= 0 and not st.over and not st.elim then
		self:track_stats()
		st.elim = true
		ui.coach:clear()
		ui.alert:clear()
		ui.feed:close_all_requests()
		st.killer = killer
		st.duration_s = ctx:match_seconds()
		ui.interact:cancel_aim(false)
		ui.radial:close(false)
		-- Let the last tiles fall on screen before the curtain comes down.
		ui:_start_elim_timer(0.8, killer)
		ui:_request_apply()
	end
end

function UIAdvisor.on_elim_timeout(self: any, killer: number)
	local ctx = self.ctx
	local ui = self.ui
	if ui._stats.over or not ctx:in_match() or ui.over.is_open then
		return
	end
	ctx:sfx("defeat")
	ui.over:open("eliminated", 0, killer, ui._stats)
	ui:_update_input_gate()
end

function UIAdvisor.on_game_over(self: any, winner: number, reason: number)
	local ctx = self.ctx
	local ui = self.ui
	local st = ui._stats
	if not ctx:in_match() or st.over then
		return
	end
	self:track_stats()
	ui.coach:clear()
	st.over = true
	-- the whole match's length for the result screen (duration_s stays the moment we fell)
	st.match_s = ctx:match_seconds()
	local me = ctx:me()
	local mine = ctx:my()
	local dead = st.elim or (mine ~= nil and not mine.alive and mine.spawned)
	ui.interact:cancel_aim(false)
	ui.radial:close(false)
	ui.tooltip:hide_tip()
	if dead and reason == Defs.OVER_DEFEATED and ctx:mode() == UICtx.MODE_SOLO then
		-- Solo ended because we fell: that is an elimination, not someone else's "victory".
		local killer = if (st.killer or 0) ~= 0 then st.killer else (if mine ~= nil then (mine.killer or 0) else 0)
		if not st.elim then
			st.duration_s = ctx:match_seconds()
		end
		st.elim = true
		-- (GameOver.open swaps the copy in place when the elimination screen is still up.)
		if not ui:_elim_timer_pending() then
			ctx:sfx("defeat")
		end
		ui.over:open("eliminated", 0, killer, st)
		ui:_request_apply()
		return
	end
	if not dead then
		st.duration_s = ctx:match_seconds()
	end
	local kind = "result"
	if me ~= 0 and not dead then
		kind = if winner == me then "victory" else "defeat"
	end
	-- a team game: the team wins together (a fallen member's team too; every member who spawned is
	-- credited)
	local s = ctx.state
	local wt = if s ~= nil then tonumber(s.winner_team) or 0 else 0
	if wt ~= 0 and me ~= 0 and s:team_of(me) ~= 0 then
		kind = if s:team_of(me) == wt then "victory" else (if dead then "result" else "defeat")
	end
	ctx:sfx(if kind == "victory" then "victory" else "defeat")
	-- An ELIMINATED screen still up turns into the result in place (no close + reopen race).
	ui.over:open(kind, winner, if mine ~= nil then (mine.killer or 0) else 0, st, reason)
	ui:_request_apply()
end

--- Spawn phase camera. The globe turned away from an ocean-only view here; flat maps show the whole
--- map during the spawn phase, so there is nothing to do (UIRoot still calls it).
function UIAdvisor.spawn_view(_self: any) end

--- Spawn -> play: a short "the war begins" moment and a push-in on the capital.
function UIAdvisor.war_begins(self: any)
	local ctx = self.ctx
	local ui = self.ui
	local me = ctx:me()
	if me ~= 0 then
		ctx:world_call("focus_owner", { me })
	end
	-- The camera lands the capital in the middle of the HUD-free band; use the roomier side of it,
	-- and a title-only banner on very short screens.
	local band: Rect = if ui._world_safe.Height > 1.0 then ui._world_safe else ctx:clear_rect()
	local cap_y = UICtx.rect_center(band).Y
	local gap = if ctx.compact then 30.0 else 60.0
	local above = cap_y - gap - band.Min.Y
	local below = band.Max.Y - (cap_y + gap)
	local h = if ctx.compact then 70.0 else 96.0
	local small = math.max(above, below) < h
	if small then
		h = 38.0
	end
	local top_y = if above >= below then cap_y - gap - h else cap_y + gap
	top_y = math.max(top_y, band.Min.Y - 12.0)
	local Banner = UICtx.mod("Banner")
	local banner =
		Banner.make(ctx, "THE WAR BEGINS", "Expand, build and outlast 88 nations", T().AMBER, 1.6, top_y, h, small)
	-- The camera is still pushing in, so where the player's own label ends up is only known as it
	-- goes: the band slides clear of it (up to just under the top panels, or below the capital), and
	-- every other map label steps around its text (review R2-5: on a 361 px phone the subtitle sat
	-- on the YOU pill).
	banner.avoid = function()
		local r = ctx:world_call("local_label_rect", {})
		return if typeof(r) == "Rect" then ctx:rect_to_logical(r) else nil
	end
	banner.min_top = band.Min.Y - 12.0
	banner.max_bottom = band.Max.Y
	ui.float_layer:add_child(banner)
	if banner.text_area ~= nil and ui.add_hud_control ~= nil then
		-- (it moves out of YOU's way itself: the YOU label does not step aside for it)
		banner.text_area.gui:SetAttribute("AF_YIELD_YOU", true)
		ui:add_hud_control(banner.text_area)
	end
end

return UIAdvisor
