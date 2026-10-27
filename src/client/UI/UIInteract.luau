-- Port of scripts/ui/ui_interact.gd
-- Globe interaction for the HUD: hover tooltips and previews, primary clicks (spawn / expand /
-- attack / boat / inspect), build & nuke placement mode, the radial context menu and its actions,
-- and the keyboard / wheel / touch detection (hotkeys: H, L, Esc, Space, Backspace, Q/E, 1-0;
-- M / Home live in Main).
--
-- Input: UserInputService events, respecting gameProcessedEvent (chat typing never triggers a
-- hotkey). Positions are viewport coordinates (see UICtx).

local UICtx = require("./UICtx") :: any
local UIRules = require("./UIRules") :: any
local Defs = UICtx.core("Defs")

local _T: any = nil
local function T(): any
	if _T == nil then
		_T = UICtx.mod("UITheme")
	end
	return _T
end
local _FT: any = nil
local function FloatText(): any
	if _FT == nil then
		_FT = UICtx.mod("FloatText")
	end
	return _FT
end

local UIInteract = {}
UIInteract.__index = UIInteract

-- One physical tap can reach us twice (a platform that reports both mouse and touch); identical
-- globe clicks inside this window are ignored.
UIInteract.DUP_MS = 180
--- Touch taps sample a ring this wide (logical px) around the finger; the mouse a small one.
UIInteract.PICK_TOUCH_PX = 22.0
UIInteract.PICK_MOUSE_PX = 6.0
--- Touch / mouse radius (px) for picking a warship.
UIInteract.UNIT_PICK_TOUCH = 26.0
UIInteract.UNIT_PICK_MOUSE = 12.0
--- Q / E held: key repeat like the OS (initial delay, then a steady rate).
UIInteract.REPEAT_DELAY = 0.45
UIInteract.REPEAT_RATE = 1.0 / 25.0

local TAU = 2 * math.pi

function UIInteract.new(c: any)
	local self = setmetatable({}, UIInteract)
	self.ctx = c
	self.bar = nil :: any
	self.tooltip = nil :: any
	self.radial = nil :: any
	self.float_layer = nil :: any
	self.ui = nil :: any
	self.target_card = nil :: any
	self.place_confirm = nil :: any
	self.unit_card = nil :: any
	--- Current placement kind ("" = none): a structure, "warship" or a nuke.
	self.aim_kind = ""
	self.hover_tile = -1
	self.enabled = false

	self._confirm_tile = -1
	--- The tile the last globe tap resolved to (tests / diagnostics).
	self.last_pick = -1
	-- Touch placement ghost: the resolved tile, the screen point it was picked at (a map drag
	-- under it moves the ghost) and the raw tile last seen there.
	self._ghost_tile = -1
	self._ghost_anchor = Vector2.new(-1, -1)
	self._ghost_raw = -1
	self._ghost_hit = -1
	self._ghost_res = {}
	--- Tile whose SAM / post rings the inspect card is showing (-1 = none).
	self._range_focus = -1
	self._last_click_msec = -100000
	self._last_click_tile = -2
	self._last_ctx_msec = -100000
	self._confirm_msec = 0
	self._tip_accum = 0.0
	self._tip_dirty = false
	self._tip_wait = 0.0
	self._conns = {} :: { any }
	-- Held Q / E: keycode -> {t = seconds held, next = next repeat time}
	self._held = {} :: { [any]: { t: number, next: number } }
	return self
end

-- ---------------------------------------------------------------------------------------------
-- Placement mode
-- ---------------------------------------------------------------------------------------------

function UIInteract.select_action(self: any, kind: string)
	local ctx = self.ctx
	if not self.enabled or not ctx:alive_player() then
		return
	end
	local b = self.bar:button(kind)
	local av = ctx.rules:availability(kind)
	if av.arsenal ~= nil then
		-- an Arsenal unit the player hasn't unlocked: the Arsenal opens on it
		ctx:sfx("locked")
		if self.ui ~= nil and type(self.ui.open_arsenal) == "function" then
			self.ui:open_arsenal(av.arsenal, "locked")
		end
		return
	end
	if not av.ok then
		if b ~= nil then
			b:deny()
		end
		ctx:sfx("deny")
		self:_float(tostring(av.reason), "info", T().RED, self:_anchor_pos(b))
		return
	end
	if kind == "reinforce" then
		-- the Arsenal's Reinforcements: an order, not a placement
		self:cancel_aim(false)
		ctx:send({ type = "reinforce" })
		ctx:sfx("confirm")
		return
	end
	if self.aim_kind == kind then
		self:cancel_aim()
		return
	end
	self.aim_kind = kind
	self._confirm_tile = -1
	self:_clear_ghost()
	if self.target_card ~= nil then
		self.target_card:hide_card()
	end
	-- Aiming a nuke shows every hostile SAM's coverage.
	ctx:world_call("set_range_mode", { if UIRules.is_nuke(kind) then "nuke_aim" else "auto" })
	self.bar:set_placing(kind)
	ctx:hide_hint()
	ctx:sfx("click")
	self:on_hover(self.hover_tile)
end

function UIInteract.cancel_aim(self: any, play_sound: boolean?)
	if self.aim_kind == "" then
		return
	end
	local ctx = self.ctx
	local was_mirv = self.aim_kind == "mirv"
	self.aim_kind = ""
	self._confirm_tile = -1
	self:_clear_ghost()
	self.bar:set_placing("")
	ctx:set_aim("", -1, 0)
	ctx:world_call("set_range_mode", { "auto" })
	if was_mirv then
		ctx:world_call("set_selected_owner", { 0 })
	end
	if play_sound ~= false then
		ctx:sfx("close", -6.0)
	end
	self:on_hover(self.hover_tile)
end

function UIInteract._anchor_pos(self: any, c: any): Vector2
	if c ~= nil and type(c) == "table" and c.get_global_rect ~= nil and not c._freed and c:is_visible_in_tree() then
		local r = c:get_global_rect()
		return Vector2.new(UICtx.rect_center(r).X, r.Min.Y)
	end
	return self.ctx:mouse_pos()
end

-- ---------------------------------------------------------------------------------------------
-- World signals
-- ---------------------------------------------------------------------------------------------

function UIInteract.on_hover(self: any, tile: number)
	local ctx = self.ctx
	local tooltip = self.tooltip
	self.hover_tile = tile
	if not self.enabled or ctx.state == nil then
		ctx:world_call("set_hover_owner", { 0 })
		if tooltip.place == tooltip.Place.FOLLOW then
			tooltip:hide_tip()
		end
		return
	end
	local s = ctx.state
	local own = if tile >= 0 then s:tile_owner(tile) else 0
	ctx:world_call("set_hover_owner", { own })
	-- Placement preview (the view draws blast radii, hostile SAM cover and SAM / post range rings
	-- from the detail; an invalid spot shows the preview greyed).
	if self.aim_kind ~= "" then
		if ctx.touch then
			if self._ghost_tile < 0 then
				ctx:set_aim("", -1, 0, false) -- touch: nothing to preview until the first tap
			end
			-- else the ghost only moves on a tap or a map drag (process_frame)
		else
			local locked = self._confirm_tile >= 0 and self:_locks_target(self.aim_kind)
			local t = if locked then self._confirm_tile else tile
			if t >= 0 then
				self:_show_aim(t, ctx.rules:placement(self.aim_kind, t), locked)
			else
				ctx:set_aim("", -1, 0, false)
			end
		end
	end
	-- The hover card is rebuilt at most ~16x per second (its hint may flood-fill the map).
	self._tip_dirty = true
	if self._tip_wait <= 0.0 then
		self._tip_wait = 0.06
		self._tip_dirty = false
		self:_update_tooltip()
	end
end

function UIInteract._update_tooltip(self: any)
	local tooltip = self.tooltip
	local P = tooltip.Place
	if tooltip.place == P.PINNED and tooltip:is_shown() then
		return
	end
	if tooltip.place == P.ANCHOR and tooltip:is_shown() then
		return
	end
	if self.ctx.touch or self.radial.is_open or not self.enabled then
		if tooltip.place == P.FOLLOW then
			tooltip:hide_tip()
		end
		return
	end
	local spec = self:hover_spec(self.hover_tile)
	if next(spec) == nil then
		tooltip:hide_tip()
	else
		tooltip:show_follow(spec)
	end
end

function UIInteract.on_click(self: any, tile: number)
	local ctx = self.ctx
	if not self.enabled or ctx.state == nil then
		return
	end
	local now = UICtx.msec()
	if tile == self._last_click_tile and now - self._last_click_msec < UIInteract.DUP_MS then
		return
	end
	self._last_click_tile = tile
	self._last_click_msec = now
	if self.radial.is_open then
		self.radial:close()
		return
	end
	local pos = self:tap_pos(tile)
	local unit_card = self.unit_card
	-- Warships: a tap on one selects it; with your own selected, a tap on the sea moves it there and
	-- any other tap just deselects (never also an order).
	if self.aim_kind == "" then
		-- On land a ship must be right under the finger (land taps near a coast stay land orders);
		-- with your own ship selected, sea taps are move orders unless another ship is right there.
		local on_land = tile >= 0 and ctx.state.map:is_land(tile)
		local steering = unit_card ~= nil and unit_card.is_open and unit_card.own and not on_land
		local uid = self:unit_at(pos, if on_land or steering then 12.0 else -1.0)
		if uid ~= 0 and not (steering and uid == unit_card.uid) then
			self:select_unit(uid)
			return
		end
		if unit_card ~= nil and unit_card.is_open then
			if unit_card.own and tile >= 0 and ctx.state.map:is_water(tile) then
				self:_move_selected(tile, pos)
			else
				self:deselect_unit(true)
			end
			return
		end
	end
	tile = self:pick(tile, pos)
	self.last_pick = tile
	if self.aim_kind ~= "" then
		self:_place(tile, pos)
		return
	end
	local act = ctx.rules:primary(tile)
	local kind = tostring(act.type)
	local selectable = (kind == "attack" or kind == "boat") and act.ok
	-- Touch: an ally's land opens their card (Donate / Break alliance) instead of a bare info card.
	local ally_own = if ctx.touch then self:_ally_at(tile) else 0
	local target_card = self.target_card
	local tooltip = self.tooltip
	-- A target card is up: tapping the same target again fires; anything else just changes or
	-- closes the selection (a "tap elsewhere to close" must never also give an order).
	if target_card ~= nil and target_card.is_open then
		if selectable and target_card:matches(tile, kind) then
			self:_fire_selected(pos)
			return
		end
		local same_ally = ally_own ~= 0 and target_card.kind == "ally" and target_card.owner_id == ally_own
		target_card:hide_card()
		if ally_own ~= 0 and not same_ally then
			self:_select(tile, "ally", act)
		elseif selectable and self:confirm_orders() then
			self:_select(tile, kind, act)
		end
		return
	end
	if ally_own ~= 0 then
		tooltip:hide_tip()
		self:_select(tile, "ally", act)
		return
	end
	if tooltip.place == tooltip.Place.PINNED and tooltip:is_shown() then
		tooltip:hide_tip()
		if ctx.touch then
			return
		end
	end
	if selectable and self:confirm_orders() then
		self:_select(tile, kind, act)
		return
	end
	if kind == "inspect" then
		local own = ctx.state:tile_owner(tile)
		ctx:world_call("set_selected_owner", { own })
		if ctx.touch and own ~= 0 then
			self:show_inspect(tile)
		end
		return
	end
	if kind == "none" or not act.ok then
		local reason = tostring(act.reason)
		if reason ~= "" then
			ctx:sfx("deny", -4.0)
			self:_float(reason, "info", T().TEXT_2, pos)
		end
		if act.floor == true then
			ctx.floor_held:Fire()
		end
		return
	end
	local intent = ctx.rules:primary_intent(tile, act)
	if next(intent) == nil then
		return
	end
	ctx:send(intent)
	local coach = ctx.coach
	if coach ~= nil then
		if kind == "expand" then
			coach:complete("expand")
		elseif kind == "attack" then
			coach:complete("expand")
			coach:complete("contact")
		elseif kind == "boat" then
			coach:complete("boat")
		end
	end
	if kind == "spawn" then
		ctx:sfx("spawn")
	elseif kind == "expand" then
		self:_float(ctx.rules:confirm_text(act), "attack", T().GREEN, pos)
	elseif kind == "attack" then
		self:_float(ctx.rules:confirm_text(act), "attack", T().AMBER, pos)
	elseif kind == "boat" then
		self:_float(ctx.rules:confirm_text(act), "boat", T().CYAN, pos)
	end
end

--- Touch plays "look before you act": attacks and boat invasions need a selection first.
--- Desktop keeps one-click orders unless the player turns "Confirm attacks" on.
function UIInteract.confirm_orders(self: any): boolean
	local ctx = self.ctx
	if ctx.touch then
		return ctx:setting("confirm_orders", ctx.touch_device or ctx.touch) and true or false
	end
	return ctx:setting("confirm_orders_desktop", false) and true or false
end

function UIInteract._select(self: any, tile: number, kind: string, act: { [string]: any })
	local ctx = self.ctx
	if self.target_card == nil then
		return
	end
	self.target_card:show_target(tile, kind, act)
	local own = ctx.state:tile_owner(tile)
	ctx:world_call("set_selected_owner", { own })
	-- Show the target's defense posts (their protection radius) while sizing them up.
	if own ~= 0 and kind ~= "ally" then
		ctx:world_call("set_range_owner", { own })
		ctx:world_call("set_range_mode", { "attack_aim" })
	end
	-- A tapped SAM / post shows its own ring (the view ignores tiles without one).
	self._range_focus = tile
	ctx:world_call("set_range_focus", { tile })
	if ctx.coach ~= nil then
		ctx.coach:offer("select")
	end
end

function UIInteract._fire_selected(self: any, pos: Vector2)
	local ctx = self.ctx
	local tc = self.target_card
	local t = tc.tile
	local k = tc.kind
	tc:hide_card()
	ctx:world_call("set_selected_owner", { 0 })
	local act = ctx.rules:primary(t)
	if tostring(act.type) == "none" or not act.ok then
		ctx:sfx("deny", -4.0)
		local r = tostring(act.reason)
		self:_float(if r ~= "" then r else "Target out of reach", "info", T().TEXT_2, pos)
		if act.floor == true then
			ctx.floor_held:Fire()
		end
		return
	end
	if tostring(act.type) ~= k and not (k == "attack" and tostring(act.type) == "expand") then
		act.type = k
	end
	local intent = ctx.rules:primary_intent(t, act)
	if next(intent) == nil then
		return
	end
	ctx:send(intent)
	if ctx.coach ~= nil then
		ctx.coach:complete("select")
		ctx.coach:complete("contact")
		if k == "boat" then
			ctx.coach:complete("boat")
		end
	end
	self:_float(
		ctx.rules:confirm_text(act),
		if k == "attack" then "attack" else "boat",
		if k == "attack" then T().AMBER else T().CYAN,
		pos
	)
end

function UIInteract.fire_from_card(self: any)
	local tc = self.target_card
	if tc == nil or not tc.is_open then
		return
	end
	local p = self.ctx:tile_screen_pos(tc.tile)
	self:_fire_selected(if p.X >= 0.0 then p else UICtx.rect_center(tc:panel_rect()))
end

--- The alliance partner owning `tile` while playing (0 = none).
function UIInteract._ally_at(self: any, tile: number): number
	local ctx = self.ctx
	local s = ctx.state
	if s == nil or tile < 0 or s.phase ~= Defs.PHASE_PLAYING or not ctx:alive_player() then
		return 0
	end
	local own = s:tile_owner(tile)
	return if own ~= 0 and own ~= ctx:me() and s:are_allies(ctx:me(), own) then own else 0
end

--- Break alliance from the ally card's confirmation; `attack` also sends an attack on them (the
--- Sim handles intents in order, so the attack lands on a former ally).
function UIInteract.betray_from_card(self: any, attack: boolean)
	local ctx = self.ctx
	local tc = self.target_card
	if tc == nil or not tc.is_open or tc.owner_id == 0 then
		return
	end
	local own = tc.owner_id
	local t = tc.tile
	local p = ctx:tile_screen_pos(t)
	tc:hide_card()
	ctx:world_call("set_selected_owner", { 0 })
	ctx:send({ type = "ally_break", target = own })
	ctx:sfx("deny", -2.0)
	local at = if p.X >= 0.0 then p else ctx:mouse_pos()
	if attack and ctx:troops_for_ratio() >= 1.0 then
		local land = ctx.borders:borders_owner(own)
		local landing = if land then -1 else ctx.rules:boat_landing(t)
		ctx:send({
			type = if land then "attack" else "boat",
			tile = if landing >= 0 then landing else t,
			ratio = ctx:order_ratio(),
		})
		self:_float(
			string.format(
				"You betrayed %s · attacking with %s",
				ctx.state:owner_name(own),
				T().fmt_troops(ctx:troops_for_ratio())
			),
			"betray",
			T().RED,
			at
		)
	else
		self:_float("You broke your alliance with " .. ctx.state:owner_name(own), "betray", T().RED, at)
	end
end

function UIInteract.donate_from_card(self: any)
	local ctx = self.ctx
	local tc = self.target_card
	if tc == nil or not tc.is_open or tc.owner_id == 0 then
		return
	end
	local own = tc.owner_id
	local p = ctx:tile_screen_pos(tc.tile)
	if self:donate_to(own, if p.X >= 0.0 then p else ctx:mouse_pos()) then
		tc:hide_card()
		ctx:world_call("set_selected_owner", { 0 })
	end
end

--- Send troops to ally `own` (ratio share, capped at their troop headroom; see UIRules.donate_plan)
--- with a float at `pos`. False (and a deny float) when nothing useful can be sent.
function UIInteract.donate_to(self: any, own: number, pos: Vector2): boolean
	local ctx = self.ctx
	local plan = ctx.rules:donate_plan(own)
	local name = ctx.state:owner_name(own)
	if plan.want < 1 or plan.full or plan.amount < 1 then
		ctx:sfx("deny", -4.0)
		self:_float(
			if plan.want < 1 then "No troops to spare" else name .. " is at its troop cap",
			"info",
			T().RED,
			pos
		)
		return false
	end
	ctx:send({ type = "donate", target = own, troops = plan.amount })
	self:_float(
		if plan.capped
			then string.format("Sent %s troops  ·  %s is now at its troop cap", T().fmt_troops(plan.amount), name)
			else string.format("Sent %s troops to %s", T().fmt_troops(plan.amount), name),
		"donate",
		T().GREEN,
		pos
	)
	return true
end

function UIInteract.ally_from_card(self: any)
	local ctx = self.ctx
	local tc = self.target_card
	if tc == nil or not tc.is_open or tc.owner_id == 0 then
		return
	end
	local own = tc.owner_id
	tc:hide_card()
	ctx:world_call("set_selected_owner", { 0 })
	ctx:send({ type = "ally_request", target = own })
	self:_float("Alliance proposed to " .. ctx.state:owner_name(own), "alliance", T().VIOLET, ctx:mouse_pos())
end

function UIInteract.on_context(self: any, tile: number, screen_pos: Vector2)
	local ctx = self.ctx
	if not self.enabled or ctx.state == nil then
		return
	end
	local now = UICtx.msec()
	if now - self._last_ctx_msec < 350 then
		return
	end
	self._last_ctx_msec = now
	if self.aim_kind ~= "" then
		self:cancel_aim()
		return
	end
	tile = self:pick(tile, screen_pos)
	if tile < 0 then
		return
	end
	if self.target_card ~= nil and self.target_card.is_open then
		self.target_card:hide_card()
	end
	local s = ctx.state
	if s.phase == Defs.PHASE_SPAWN then
		return
	end
	self.tooltip:hide_tip()
	local own = s:tile_owner(tile)
	local title = ctx:terrain_title(tile)
	local col = T().TEXT_2
	if own ~= 0 then
		title = s:owner_name(own)
		col = T().owner_ui_color(UICtx.color3(s:owner_color(own)))
	elseif s.map:is_contestable(tile) then
		title = "Unclaimed " .. string.lower(ctx:terrain_title(tile))
	end
	self.radial:open_at(tile, screen_pos, ctx.rules:radial_items(tile), title, col)
end

--- Space bar: primary action at the hovered tile.
function UIInteract.primary_at_hover(self: any)
	if self.hover_tile >= 0 then
		self:on_click(self.hover_tile)
	end
end

-- ---------------------------------------------------------------------------------------------
-- Actions
-- ---------------------------------------------------------------------------------------------

local function shift_down(): boolean
	if not UICtx.IS_ROBLOX then
		return false
	end
	local UIS = game:GetService("UserInputService")
	return UIS:IsKeyDown(Enum.KeyCode.LeftShift) or UIS:IsKeyDown(Enum.KeyCode.RightShift)
end

function UIInteract._place(self: any, tile: number, pos: Vector2)
	local ctx = self.ctx
	local kind = self.aim_kind
	local av = ctx.rules:availability(kind)
	if not av.ok then
		ctx:sfx("deny")
		self:_float(tostring(av.reason), "info", T().RED, pos)
		self:cancel_aim(false)
		return
	end
	if ctx.touch and self.place_confirm ~= nil then
		-- Touch: a tap only moves the ghost; the floating ✓ builds / launches.
		self:_move_ghost(tile, pos)
		return
	end
	local pl = ctx.rules:placement(kind, tile)
	if not pl.ok then
		ctx:sfx("deny", -4.0)
		self:_float(tostring(pl.reason), "info", T().RED, pos)
		return
	end
	if pl.tile ~= nil then
		tile = pl.tile -- the snapped site / the structure an upgrade applies to
	end
	if UIRules.is_nuke(kind) then
		local now = UICtx.msec()
		local confirmed = self._confirm_tile >= 0
			and now - self._confirm_msec < 6000
			and Defs.tile_distance(self._confirm_tile, tile) <= 6.0
		-- a strike (an Air Strike, a Railgun shot) is free and reloads: one click fires it
		if UIRules.is_strike(kind) then
			confirmed = true
			self._confirm_tile = tile
		end
		if not confirmed then
			self._confirm_tile = tile
			self._confirm_msec = now
			ctx:sfx("click")
			local what = UIRules.TITLES[kind]
			self:on_hover(tile)
			local n_sam = tonumber(ctx:world_call("aim_sams")) or 0
			local verb = if ctx.touch then "Tap" else "Click"
			if n_sam > 0 and kind ~= "mirv" then
				self:_float(
					string.format(
						"Target inside %d enemy SAM%s: the %s may be shot down. %s again to launch",
						n_sam,
						if n_sam == 1 then "" else "s",
						what,
						verb
					),
					"sam",
					T().RED,
					pos
				)
			else
				self:_float(
					string.format("Target locked. %s again to launch the %s", verb, what),
					"target",
					T().RED,
					pos
				)
			end
			return
		end
		ctx:send({ type = "nuke", kind = kind, tile = self._confirm_tile })
		self:_float(UIRules.TITLES[kind] .. " launched", kind, T().RED, pos)
		self:cancel_aim(false)
		return
	end
	self:_send_build(kind, tile, pl, pos)
	if not shift_down() then
		self:cancel_aim(false)
	end
end

function UIInteract._send_build(self: any, kind: string, tile: number, pl: { [string]: any }, pos: Vector2)
	local ctx = self.ctx
	local av = ctx.rules:availability(kind)
	ctx:send({ type = "build", kind = kind, tile = tile })
	if kind == "city" and ctx.coach ~= nil then
		ctx.coach:complete("city")
	end
	local title = UIRules.TITLES[kind]
	if pl.upgrade then
		self:_float(
			string.format("%s upgraded to Lv %d  ·  %s gold", title, tonumber(pl.level) or 2, T().fmt_cost(av.cost)),
			kind,
			T().GOLD,
			pos
		)
	else
		self:_float(string.format("%s  ·  %s gold", title, T().fmt_cost(av.cost)), kind, T().GOLD, pos)
	end
end

--- Preview on the globe for `kind` at `t` given its placement result (snapped site, upgrade level).
function UIInteract._show_aim(self: any, t: number, pl: { [string]: any }, locked: boolean?)
	local ctx = self.ctx
	local nuke = UIRules.is_nuke(self.aim_kind)
	local ok = locked or (pl.ok == true)
	local at = if ok then (tonumber(pl.tile) or t) else t
	local radius = if nuke then UIRules.nuke_radius(self.aim_kind) else 0
	if self.aim_kind == "mirv" then
		-- The MIRV rains over the whole target nation: highlight it instead of a huge circle.
		radius = 0
		ctx:world_call("set_selected_owner", { if ok then ctx.state:tile_owner(at) else 0 })
	end
	ctx:set_aim(if nuke then "nuke" else "build", at, radius, ok, self.aim_kind, tonumber(pl.level) or 1)
end

--- Touch: put the ghost where a tap at `tile` really builds / aims, with ✓ / ✕ beside it.
function UIInteract._move_ghost(self: any, tile: number, pos: Vector2, quiet: boolean?)
	local ctx = self.ctx
	local kind = self.aim_kind
	local pl = ctx.rules:placement(kind, tile)
	self._ghost_anchor = pos
	self._ghost_raw = tile
	self._ghost_hit = ctx:tile_at(pos)
	self._ghost_res = pl
	local ok = pl.ok == true
	local moved_to = if ok then (tonumber(pl.tile) or tile) else tile
	local changed = moved_to ~= self._ghost_tile
	self._ghost_tile = moved_to
	self:_show_aim(self._ghost_tile, pl)
	self.place_confirm:show_for(self._ghost_tile, self:_ghost_caption(kind, pl), UIRules.is_nuke(kind), ok)
	if not quiet or changed then
		ctx:sfx(if ok then "click" else "deny", -8.0)
	end
end

function UIInteract._ghost_caption(self: any, kind: string, pl: { [string]: any }): string
	local ctx = self.ctx
	local title = UIRules.TITLES[kind]
	if not pl.ok then
		local r = pl.reason
		return if r ~= nil and r ~= "" then tostring(r) else "Can't place here"
	end
	local cost = T().fmt_cost(ctx.rules:availability(kind).cost)
	if pl.upgrade then
		return string.format("Upgrade %s → Lv %d · %s", UIRules.SHORT[kind], tonumber(pl.level) or 2, cost)
	end
	if kind == "warship" then
		return "Warship patrols here · " .. cost
	end
	if UIRules.is_nuke(kind) then
		local n_sam = tonumber(ctx:world_call("aim_sams")) or 0
		if n_sam > 0 and kind ~= "mirv" then
			return string.format("%d SAM%s cover this target", n_sam, if n_sam == 1 then "" else "s")
		end
		return string.format("Launch %s · %s", UIRules.SHORT[kind], cost)
	end
	return string.format("%s · %s", title, cost)
end

--- ✓ on the touch confirm: build / launch at the ghost.
function UIInteract.confirm_ghost(self: any)
	local ctx = self.ctx
	if self.aim_kind == "" or self._ghost_tile < 0 then
		return
	end
	local kind = self.aim_kind
	local pos = ctx:tile_screen_pos(self._ghost_tile)
	local at = if pos.X >= 0.0 then pos else ctx:mouse_pos()
	local av = ctx.rules:availability(kind)
	if not av.ok then
		ctx:sfx("deny")
		self:_float(tostring(av.reason), "info", T().RED, at)
		return
	end
	-- Re-check at the moment of the tap (the world moved on since the ghost was placed).
	local pl = ctx.rules:placement(kind, if not UIRules.is_nuke(kind) then self._ghost_raw else self._ghost_tile)
	if not pl.ok then
		ctx:sfx("deny", -4.0)
		self:_float(tostring(pl.reason), "info", T().RED, at)
		self:_move_ghost(self._ghost_raw, self._ghost_anchor)
		return
	end
	if UIRules.is_nuke(kind) then
		ctx:send({ type = "nuke", kind = kind, tile = self._ghost_tile })
		self:_float(UIRules.TITLES[kind] .. " launched", kind, T().RED, at)
	else
		self:_send_build(kind, tonumber(pl.tile) or self._ghost_tile, pl, at)
	end
	self:cancel_aim(false)
end

function UIInteract._clear_ghost(self: any)
	self._ghost_tile = -1
	self._ghost_raw = -1
	self._ghost_anchor = Vector2.new(-1, -1)
	self._ghost_res = {}
	if self.place_confirm ~= nil then
		self.place_confirm:hide_confirm()
	end
end

--- A map drag under the ghost's screen point moves the ghost with it (fine positioning).
function UIInteract._follow_ghost(self: any)
	if self._ghost_tile < 0 or self.aim_kind == "" or self._ghost_anchor.X < 0.0 then
		return
	end
	local t = self.ctx:tile_at(self._ghost_anchor)
	if t < 0 or t == self._ghost_hit then
		return
	end
	self:_move_ghost(self:pick(t, self._ghost_anchor), self._ghost_anchor, true)
end

-- ---------------------------------------------------------------------------------------------
-- Warships
-- ---------------------------------------------------------------------------------------------

--- Warship under screen `pos` (0 = none): WorldView.unit_at_screen when the view has it, else the
--- nearest warship whose tile projects within the pick radius.
function UIInteract.unit_at(self: any, pos: Vector2, radius: number?): number
	local ctx = self.ctx
	local s = ctx.state
	if s == nil then
		return 0
	end
	local rad = radius or -1.0
	local w = ctx.world
	if w ~= nil and type(w.unit_at_screen) == "function" then
		local v = ctx:world_call("unit_at_screen", { ctx:to_view(pos), if rad > 0 then rad * ctx:ui_scale() else rad })
		local u0 = if type(v) == "number" then s.units[v] else nil
		if u0 ~= nil and u0.kind == Defs.U_WARSHIP then
			return u0.uid
		end
		-- The view only knows ships it has drawn: fall through to the mirror (e.g. just launched).
	end
	local r = if rad > 0.0 then rad else (if ctx.touch then UIInteract.UNIT_PICK_TOUCH else UIInteract.UNIT_PICK_MOUSE)
	local best = 0
	local bd = r * r
	for _, u in s.units do
		if u.kind ~= Defs.U_WARSHIP or u.path == nil or #u.path == 0 then
			continue
		end
		local p = ctx:tile_screen_pos(u.path[1])
		if p.X < 0.0 then
			continue
		end
		local d = (p - pos).Magnitude
		d *= d
		if d <= bd and (d < bd or best == 0 or u.uid < best) then
			bd = d
			best = u.uid
		end
	end
	return best
end

function UIInteract.select_unit(self: any, uid: number)
	if self.target_card ~= nil then
		self.target_card:hide_card()
	end
	self.tooltip:hide_tip()
	self.unit_card:show_unit(uid)
	self.ctx:world_call("set_selected_unit", { uid })
end

function UIInteract.deselect_unit(self: any, user: boolean?)
	if self.unit_card ~= nil and self.unit_card.is_open then
		self.unit_card:hide_card(user)
	end
	self.ctx:world_call("set_selected_unit", { -1 })
end

function UIInteract._move_selected(self: any, tile: number, pos: Vector2)
	local ctx = self.ctx
	local uid = self.unit_card.uid
	ctx:send({ type = "move_warship", uid = uid, tile = tile })
	self.unit_card:mark_destination(tile)
	ctx:sfx("click", -4.0)
	self:_float("Warship moving", "warship", T().CYAN, pos)
end

-- ---------------------------------------------------------------------------------------------
-- Forgiving picking
-- ---------------------------------------------------------------------------------------------

--- Screen point of the tap that hit `tile`: the pointer when it agrees with the hit, else the
--- tile's centre.
function UIInteract.tap_pos(self: any, tile: number): Vector2
	local ctx = self.ctx
	local pos = ctx:mouse_pos()
	if ctx:tile_at(pos) == tile then
		return pos
	end
	local c = ctx:tile_screen_pos(tile)
	return if c.X >= 0.0 then c else pos
end

--- The tile a tap at screen `pos` (which hit `tile`) means in the current context:
---   * placing a structure -> the nearest of the player's own land tiles;
---   * nukes / warships -> exactly what was hit;
---   * everything else (spawn, expand, attack, boat, inspect) -> the tile under the finger when it
---     is contestable land, else the nearest contestable land (small islands, crisp coastlines that
---     are water on the tile grid), preferring the owner of the land under the finger.
function UIInteract.pick(self: any, tile: number, pos: Vector2): number
	local ctx = self.ctx
	local s = ctx.state
	if s == nil or ctx.world == nil then
		return tile
	end
	local map = s.map
	if self.aim_kind ~= "" and (UIRules.is_nuke(self.aim_kind) or self.aim_kind == "warship") then
		return tile
	end
	-- The pointer position must belong to this tap (else fall back to the tile's centre).
	if ctx:tile_at(pos) ~= tile then
		local c = ctx:tile_screen_pos(tile)
		if c.X >= 0.0 then
			pos = c
		end
	end
	local own_build = self.aim_kind ~= ""
	local me = ctx:me()
	local function good(t: number): boolean
		if t < 0 then
			return false
		end
		if own_build then
			return s:tile_owner(t) == me and map:is_land(t)
		end
		return map:is_contestable(t)
	end
	if good(tile) then
		return tile
	end
	local r_max = if ctx.touch then UIInteract.PICK_TOUCH_PX else UIInteract.PICK_MOUSE_PX
	local prefer_owner = if tile >= 0 and map:is_land(tile) then s:tile_owner(tile) else -1
	local best = -1
	local best_score = math.huge
	local rings = { r_max }
	if ctx.touch then
		rings = { r_max * 0.35, r_max * 0.7, r_max }
	end
	for _, r in rings do
		local n = if r < 10.0 then 8 elseif r < 18.0 then 12 else 16
		for i = 0, n - 1 do
			local a = TAU * i / n
			local q = pos + Vector2.new(math.cos(a), math.sin(a)) * r
			local t = ctx:tile_at(q)
			if not good(t) then
				continue
			end
			local score = r
			if prefer_owner >= 0 and s:tile_owner(t) ~= prefer_owner then
				score += r_max * 0.5
			end
			if score < best_score then
				best_score = score
				best = t
			end
		end
	end
	if best >= 0 then
		return best
	end
	-- Sub-pixel islands: search the tile grid around the hit tile (≈ the ring's size in tiles).
	local span = self:_px_to_tiles(r_max, pos)
	if tile >= 0 and span > 0 then
		local map = ctx.state and ctx.state.map
		local W = if map then map.W else Defs.W
		local H = if map then map.H else Defs.H
		local cx = tile % W
		local cy = tile // W
		local bd = math.huge
		for dy = -span, span do
			local y = cy + dy
			if y < 0 or y >= H then
				continue
			end
			for dx = -span, span do
				local x = cx + dx
				if x < 0 or x >= W then
					continue
				end
				local t2 = y * W + x
				if good(t2) then
					local d = dx * dx + dy * dy
					if d < bd then
						bd = d
						best = t2
					end
				end
			end
		end
	end
	return if best >= 0 then best else tile
end

--- How many grid tiles `px` screen pixels span around `pos` (at least 1).
function UIInteract._px_to_tiles(self: any, px: number, pos: Vector2): number
	local ctx = self.ctx
	local a = ctx:tile_at(pos)
	local b = ctx:tile_at(pos + Vector2.new(px, 0))
	if a < 0 or b < 0 then
		return 1
	end
	local map = ctx.state and ctx.state.map
	local W = if map then map.W else Defs.W
	local dx = math.abs(a % W - b % W)
	local dy = math.abs(a // W - b // W)
	return math.clamp(math.max(dx, dy), 1, 6)
end

--- Aims that take two taps: nukes on desktop (touch confirms with the floating ✓ instead).
function UIInteract._locks_target(self: any, kind: string): boolean
	return UIRules.is_nuke(kind) and not self.ctx.touch
end

function UIInteract.on_radial(self: any, id: string, tile: number)
	local ctx = self.ctx
	local s = ctx.state
	if s == nil then
		return
	end
	local own = s:tile_owner(tile)
	local pos = self.radial.center
	-- "build:<kind>" or "build:<kind>:<amount>" (the bulk ring: several levels at once), likewise nukes
	if string.sub(id, 1, 6) == "build:" then
		local k, amt = string.match(id, "^build:([%w_]+):?(%d*)$")
		k = k or string.sub(id, 7)
		local n = math.max(1, tonumber(amt) or 1)
		local cost = if n > 1 then ctx.rules:bulk_cost(k, n) else ctx.rules:cost(k)
		ctx:send({ type = "build", kind = k, tile = tile, amount = if n > 1 then n else nil })
		self:_float(
			string.format(
				"%s%s  ·  %s gold",
				UIRules.TITLES[k],
				if n > 1 then string.format(" ×%d", n) else "",
				T().fmt_cost(cost)
			),
			k,
			T().GOLD,
			pos
		)
		return
	end
	if string.sub(id, 1, 5) == "nuke:" then
		local nk, amt = string.match(id, "^nuke:([%w_]+):?(%d*)$")
		nk = nk or string.sub(id, 6)
		local n = math.max(1, tonumber(amt) or 1)
		ctx:send({ type = "nuke", kind = nk, tile = tile, amount = if n > 1 then n else nil })
		self:_float(
			string.format(
				"%s%s launched at %s",
				UIRules.TITLES[nk],
				if n > 1 then string.format(" ×%d", n) else "",
				s:owner_name(own)
			),
			nk,
			T().RED,
			pos
		)
		return
	end
	if id == "attack" then
		local act = ctx.rules:primary(tile)
		ctx:send({ type = "attack", tile = tile, ratio = ctx:order_ratio() })
		self:_float(ctx.rules:confirm_text(act), "attack", if own ~= 0 then T().AMBER else T().GREEN, pos)
	elseif id == "boat" then
		local landing = ctx.rules:boat_landing(tile)
		ctx:send({ type = "boat", tile = if landing >= 0 then landing else tile, ratio = ctx:order_ratio() })
		local act2 = ctx.rules:primary(tile)
		act2.type = "boat"
		self:_float(ctx.rules:confirm_text(act2), "boat", T().CYAN, pos)
	elseif id == "ally_request" then
		ctx:send({ type = "ally_request", target = own })
		ctx:sfx("click")
		self:_float("Alliance proposed to " .. s:owner_name(own), "alliance", T().VIOLET, pos)
	elseif id == "ally_accept" then
		ctx:send({ type = "ally_reply", target = own, accept = true })
		self:_float("Alliance accepted", "alliance", T().VIOLET, pos)
	elseif id == "ally_extend" then
		ctx:send({ type = "ally_extend", target = own })
	elseif id == "ally_break" then
		-- Never in one tap: the ally card asks first and spells out the Traitor penalty.
		self:_select(tile, "ally", ctx.rules:primary(tile))
		self.target_card:confirm_betray()
	elseif id == "donate" then
		self:donate_to(own, pos)
	elseif id == "retreat" then
		local aid = self:my_attack_on(own)
		if aid >= 0 then
			self:retreat(aid)
		end
	elseif id == "focus" then
		ctx:world_call("focus_tile", { tile })
	elseif id == "info" then
		self:show_inspect(tile)
	end
end

--- Nations / tribes / commanders whose capital lies within ~88 full-size tiles of `tile` (spawn advice).
UIInteract.CROWD_FULL_TILES = 88.0
function UIInteract._crowding(self: any, tile: number): number
	local ctx = self.ctx
	local s = ctx.state
	if s == nil or tile < 0 then
		return 0
	end
	-- flat maps: within CROWD_FULL_TILES full-size tiles (the old Earth's 45 tiles), in this map's tiles
	local W = s.map.W
	local k = tonumber(s.map.k_lin) or 1.0
	local r = UIInteract.CROWD_FULL_TILES / k
	local r2 = r * r
	local hx, hy = tile % W, tile // W
	local n = 0
	local me = ctx:me()
	for _, o in s.owners do
		if not o.alive or o.id == me then
			continue
		end
		local t = if (o.spawn_tile or -1) >= 0 then o.spawn_tile else (o.label_tile or -1)
		if t >= 0 then
			local dx, dy = t % W - hx, t // W - hy
			if dx * dx + dy * dy <= r2 then
				n += 1
			end
		end
	end
	return n
end

--- Our newest outgoing attack against `target` (0 = expansion), or -1.
function UIInteract.my_attack_on(self: any, target: number): number
	local best = -1
	local ctx = self.ctx
	if ctx.state == nil then
		return best
	end
	local me = ctx:me()
	for _, a in ctx.state.attacks do
		if a.attacker == me and a.target == target and a.aid > best then
			best = a.aid
		end
	end
	return best
end

function UIInteract.retreat(self: any, aid: number)
	local ctx = self.ctx
	local s = ctx.state
	if s == nil or s.attacks[aid] == nil then
		return
	end
	local a = s.attacks[aid]
	ctx:send({ type = "retreat", attack_id = aid })
	ctx:sfx("click")
	local who = if a.target ~= 0 then s:owner_name(a.target) else "neutral land"
	self:_float("Retreating from " .. who, "retreat", T().CYAN, ctx:mouse_pos())
end

--- Backspace: pull back the most recent outgoing attack.
function UIInteract.retreat_latest(self: any): boolean
	local ctx = self.ctx
	local s = ctx.state
	if s == nil then
		return false
	end
	local best = -1
	local me = ctx:me()
	for _, a in s.attacks do
		if a.attacker == me and a.aid > best then
			best = a.aid
		end
	end
	if best < 0 then
		return false
	end
	self:retreat(best)
	return true
end

function UIInteract._float(self: any, text: string, icon_name: string, col: Color3, pos: Vector2)
	local FT = FloatText()
	if FT.bounds_provider == nil then
		FT.bounds_provider = function()
			return self:float_bounds()
		end
	end
	FT.spawn(self.float_layer, pos, text, icon_name, col, self:float_bounds())
end

--- Where floating confirmations may appear: below the top bar row, above the command bar / tray.
function UIInteract.float_bounds(self: any): Rect
	local area = self.ctx:clear_rect()
	local bottom = if self.bar ~= nil and self.bar:is_visible_in_tree() then self.bar:top_edge() else area.Max.Y
	return Rect.new(area.Min.X, area.Min.Y, area.Max.X, math.min(area.Max.Y, bottom))
end

-- ---------------------------------------------------------------------------------------------
-- Tooltip / inspect content
-- ---------------------------------------------------------------------------------------------

function UIInteract.show_inspect(self: any, tile: number)
	local ctx = self.ctx
	local tooltip = self.tooltip
	local spec = self:hover_spec(tile, true)
	if next(spec) == nil then
		return
	end
	-- Bottom-left above the command bar: the right column holds the Attacks panel on phones.
	local area = ctx:clear_rect()
	local bottom = if self.bar:is_visible_in_tree() then self.bar:top_edge() - 8.0 else area.Max.Y
	tooltip:show_pinned(spec, UICtx.rect(area.Min.X, area.Min.Y, 0.0, bottom - area.Min.Y))
	-- Never cover the tapped spot: move to the right when it lies under the card.
	local tp = ctx:tile_screen_pos(tile)
	if tp.X >= 0 and UICtx.rect_has_point(UICtx.rect_grow(tooltip:target_rect(), 24.0), tp) then
		tooltip:show_pinned(spec, UICtx.rect(area.Max.X, area.Min.Y, 0.0, bottom - area.Min.Y))
	end
	-- A tapped SAM / defense post shows its range ring while the card is open.
	self._range_focus = tile
	ctx:world_call("set_range_focus", { tile })
end

function UIInteract.hover_spec(self: any, tile: number, pinned: boolean?): { [string]: any }
	local ctx = self.ctx
	local Th = T()
	local s = ctx.state
	if s == nil or tile < 0 then
		return {}
	end
	local map = s.map
	local own = s:tile_owner(tile)
	local terrain = ctx:terrain_title(tile)
	local spec = {} :: { [string]: any }
	if self.aim_kind ~= "" and not pinned then
		return self:_aim_spec(tile)
	end
	if own ~= 0 then
		local o = s:get_owner(own)
		if o == nil then
			return {}
		end
		local rel = ctx:relation(own)
		spec.title = o.name
		spec.swatch = UICtx.color3(o.color)
		spec.badge = rel
		spec.badge_color = ctx:relation_color(rel)
		spec.sub = string.format("%s  ·  %s", ctx:kind_title(o.kind), terrain)
		local rows = {
			{ "Troops", Th.fmt_troops(o.troops), Th.TEXT },
			{ "Land", Th.fmt_pct(s:land_share(own)), Th.TEXT },
		}
		if own == ctx:me() or pinned then
			table.insert(rows, { "Gold", Th.fmt_num(o.gold), Th.GOLD })
		end
		local st = ctx:structure_at(tile, 1)
		if st ~= nil and st.owner == own then
			local lv = if st.level > 1 then string.format(" · Lv %d", st.level) else ""
			table.insert(rows, { "Structure", Defs.STRUCT_TITLES[st.kind] .. lv, Th.TEXT })
			if st.active_tick > s.tick then
				-- Under construction: it does nothing yet (no cap, trade, defense, interception, launch).
				table.insert(
					rows,
					{ "Building…", Th.fmt_time(math.ceil((st.active_tick - s.tick) / Defs.TICK_RATE)), Th.ORANGE }
				)
			end
		end
		if s:is_traitor(own) then
			table.insert(
				rows,
				{ "Traitor", string.format("%ds left", math.ceil((o.traitor_until - s.tick) / Defs.TICK_RATE)), Th.RED }
			)
		end
		-- game admins only: whether this "player" is a real person
		local bots = if ctx.session ~= nil then ctx.session.admin_bots else nil
		if bots ~= nil and o.kind == Defs.KIND_HUMAN and own ~= ctx:me() then
			table.insert(rows, if bots[own] then { "Player", "Bot", Th.TEXT_3 } else { "Player", "Human", Th.CYAN })
		end
		-- the player panel's "Alliance Expires In": red in the last 30 s, yellow in the last 60 s
		local ai = if own ~= ctx:me() then s:alliance_info(ctx:me(), own) else nil
		if ai ~= nil and ai.expires_at >= 0 then
			local secs = math.ceil(ai.ticks_left / Defs.TICK_RATE)
			local col = if secs <= 30 then Th.RED elseif secs <= 60 then Th.AMBER else Th.GREEN
			table.insert(rows, { "Alliance ends", Th.fmt_time(secs), col })
			if ai.me_asked or ai.other_asked then
				table.insert(
					rows,
					{ "Renewal", if ai.me_asked then "asked, waiting for them" else "they asked", Th.VIOLET }
				)
			end
		end
		spec.rows = rows
	elseif map:is_land(tile) then
		local fallout = s:has_fallout(tile)
		spec.title = if not fallout then ("Unclaimed  ·  " .. terrain) else "Fallout zone"
		spec.title_color = if not fallout then Th.TEXT_2 else Th.ORANGE
		local st2 = ctx:structure_at(tile, 0)
		if st2 ~= nil then
			spec.sub = Defs.STRUCT_TITLES[st2.kind]
		end
	else
		if not pinned then
			return {}
		end
		spec.title = terrain
		spec.title_color = Th.TEXT_2
	end
	if pinned then
		return spec
	end
	local act = ctx.rules:primary(tile)
	local verb = if ctx.touch then "Tap" else "Click"
	local ty = tostring(act.type)
	if ty == "spawn" then
		spec.hint = verb .. " to place your capital here"
		spec.hint_color = Th.AMBER
		spec.hint_icon = "target"
		local crowd = self:_crowding(tile)
		local rows2 = spec.rows or {}
		if crowd >= 6 then
			table.insert(rows2, { "Neighbours", string.format("%d nearby · crowded, tough start", crowd), Th.ORANGE })
		elseif crowd >= 3 then
			table.insert(rows2, { "Neighbours", string.format("%d nearby · contested", crowd), Th.AMBER })
		else
			table.insert(
				rows2,
				{ "Neighbours", string.format("%d nearby · ", crowd) .. "open land, safer start", Th.GREEN }
			)
		end
		spec.rows = rows2
	elseif ty == "expand" or ty == "attack" then
		if act.ok then
			spec.hint = string.format(
				"%s: %s with %s",
				verb,
				if ty == "expand" then "expand" else "attack",
				Th.fmt_troops(act.troops)
			)
			spec.hint_color = if ty == "expand" then Th.GREEN else Th.AMBER
			spec.hint_icon = "attack"
		end
	elseif ty == "boat" then
		if act.ok then
			spec.hint = string.format("%s: boat invasion with %s", verb, Th.fmt_troops(act.troops))
			spec.hint_color = Th.CYAN
			spec.hint_icon = "boat"
		else
			spec.hint = tostring(act.reason)
			spec.hint_color = Th.TEXT_3
			spec.hint_icon = "boat"
		end
	elseif ty == "none" then
		if tostring(act.reason) ~= "" then
			spec.hint = tostring(act.reason)
			spec.hint_color = Th.TEXT_3
			spec.hint_icon = "info"
		end
	end
	if s.phase == Defs.PHASE_PLAYING and ctx:alive_player() then
		spec.footer = "Right-click for more actions"
	end
	return spec
end

function UIInteract._aim_spec(self: any, tile: number): { [string]: any }
	local ctx = self.ctx
	local Th = T()
	local k = self.aim_kind
	local nuke = UIRules.is_nuke(k)
	local title = UIRules.TITLES[k]
	local spec = {
		title = (if nuke then "Launch " else "Build ") .. title,
		title_color = if nuke then Th.RED else Th.TEXT,
	} :: { [string]: any }
	local av = ctx.rules:availability(k)
	local pl = ctx.rules:placement(k, tile)
	-- Your own structure under the cursor: the click upgrades it (same wording as the touch caption).
	local upgrade = pl.ok and pl.upgrade == true and not nuke
	if upgrade then
		spec.title = string.format("Upgrade %s → Lv %d", title, tonumber(pl.level) or 2)
	end
	local rows = { { "Cost", Th.fmt_cost(av.cost) .. " gold", Th.GOLD } }
	if nuke then
		table.insert(rows, { "Blast radius", UIRules.blast_text(k), Th.TEXT })
		if tile >= 0 and ctx.state:tile_owner(tile) ~= 0 then
			table.insert(rows, { "Target", ctx.state:owner_name(ctx.state:tile_owner(tile)), Th.TEXT })
		end
		-- Hostile SAM cover of the aimed tile (the view counts it for the current aim).
		local n_sam = tonumber(ctx:world_call("aim_sams")) or 0
		if n_sam > 0 and k ~= "mirv" then
			table.insert(rows, {
				"SAM cover",
				string.format("%d SAM%s cover this target", n_sam, if n_sam == 1 then "" else "s"),
				Th.RED,
			})
		end
	end
	spec.rows = rows
	local verb = if ctx.touch then "Tap" else "Click"
	if not pl.ok then
		spec.hint = tostring(pl.reason)
		spec.hint_color = Th.RED
		spec.hint_icon = "info"
	elseif self._confirm_tile >= 0 and self:_locks_target(k) and not nuke then
		spec.hint = if upgrade then "Tap again to upgrade" else "Tap again to build here"
		spec.hint_color = Th.GREEN
		spec.hint_icon = "target"
	elseif nuke and self._confirm_tile >= 0 then
		spec.hint = verb .. " again to confirm the launch"
		spec.hint_color = Th.RED
		spec.hint_icon = "target"
	else
		spec.hint = if nuke
			then (verb .. " to target")
			elseif upgrade then (verb .. " to upgrade")
			else (verb .. " to build here")
		spec.hint_color = Th.GREEN
		spec.hint_icon = "target"
		if tostring(pl.warn or "") ~= "" then
			spec.body = tostring(pl.warn)
		end
	end
	-- (Esc belongs to Roblox's menu; X is the cancel key here.)
	spec.footer = if not ctx.touch then "Right-click or X to cancel" else "Long-press to cancel"
	return spec
end

function UIInteract.process_frame(self: any, delta: number)
	local ctx = self.ctx
	local tooltip = self.tooltip
	self:_follow_ghost()
	if
		self._range_focus >= 0
		and not (tooltip:is_shown() and tooltip.place == tooltip.Place.PINNED)
		and not (self.target_card ~= nil and self.target_card.is_open)
	then
		self._range_focus = -1
		ctx:world_call("set_range_focus", { -1 })
	end
	if self._tip_wait > 0.0 then
		self._tip_wait -= delta
		if self._tip_wait <= 0.0 and self._tip_dirty then
			self._tip_dirty = false
			self._tip_wait = 0.06
			self:_update_tooltip()
		end
	end
	-- Keep the hover card's numbers fresh while the pointer rests.
	self._tip_accum += delta
	if self._tip_accum >= 0.5 then
		self._tip_accum = 0.0
		if self.enabled and tooltip.place == tooltip.Place.FOLLOW and tooltip:is_shown() then
			self:_update_tooltip()
		end
	end
	self:_key_repeat(delta)
end

-- ---------------------------------------------------------------------------------------------
-- Keyboard, wheel and touch detection
-- ---------------------------------------------------------------------------------------------

--- Touch InputObject positions exclude the top GUI inset: viewport px = Position + inset.
local function io_view_pos(io: InputObject): Vector2
	local p = Vector2.new(io.Position.X, io.Position.Y)
	local inset = game:GetService("GuiService"):GetGuiInset()
	return p + inset
end
UIInteract.io_view_pos = io_view_pos

--- Hooks UserInputService (Godot _input + _unhandled_key_input).
function UIInteract.connect_input(self: any)
	if not UICtx.IS_ROBLOX then
		return
	end
	local UIS = game:GetService("UserInputService")
	table.insert(
		self._conns,
		UIS.InputBegan:Connect(function(io: InputObject, gp: boolean)
			self:_on_input_began(io, gp)
		end)
	)
	table.insert(
		self._conns,
		UIS.InputChanged:Connect(function(io: InputObject, gp: boolean)
			self:_on_input_changed(io, gp)
		end)
	)
	table.insert(
		self._conns,
		UIS.InputEnded:Connect(function(io: InputObject, _gp: boolean)
			if io.UserInputType == Enum.UserInputType.Keyboard then
				self._held[io.KeyCode] = nil
			elseif io.UserInputType == Enum.UserInputType.Touch then
				self.ctx.pointer = self.ctx:to_logical(io_view_pos(io))
			end
		end)
	)
	table.insert(
		self._conns,
		UIS.TextBoxFocused:Connect(function()
			table.clear(self._held)
		end)
	)
	-- Esc opens Roblox's own menu (games never receive it): the transient things Esc cancelled in
	-- the original (radial menu, placement, selection cards) are cancelled when that menu opens.
	table.insert(
		self._conns,
		game:GetService("GuiService").MenuOpened:Connect(function()
			table.clear(self._held)
			if self.radial.is_open then
				self.radial:close()
			end
			if self.unit_card ~= nil and self.unit_card.is_open then
				self:deselect_unit(false)
			end
			if self.target_card ~= nil and self.target_card.is_open then
				self.target_card:hide_card(false)
			end
			if self.aim_kind ~= "" then
				self:cancel_aim(false)
			end
		end)
	)
end

function UIInteract.destroy(self: any)
	for _, c in self._conns do
		c:Disconnect()
	end
	table.clear(self._conns)
end

function UIInteract._on_input_began(self: any, io: InputObject, gp: boolean)
	local ty = io.UserInputType
	if ty == Enum.UserInputType.Touch then
		self.ctx.pointer = self.ctx:to_logical(io_view_pos(io))
		self:_set_touch(true)
		-- A slot's long-press card stays up until the next tap anywhere.
		local tt = self.tooltip
		if tt.place == tt.Place.ANCHOR and tt:is_shown() then
			tt:hide_tip()
		end
		return
	end
	if ty == Enum.UserInputType.Keyboard then
		-- Esc belongs to Roblox's system menu: when it still reaches us, it cancels like the original
		-- (a bonus); X is the always-available cancel key.
		if io.KeyCode == Enum.KeyCode.Escape then
			if not game:GetService("GuiService").MenuIsOpen then
				self:escape()
			end
			return
		end
		if not gp then
			self:_on_key(io.KeyCode, false)
		end
	end
end

function UIInteract._on_input_changed(self: any, io: InputObject, gp: boolean)
	local ty = io.UserInputType
	if ty == Enum.UserInputType.MouseMovement then
		if not self.ctx.touch_device and io.Delta.Magnitude > 0.5 then
			self:_set_touch(false)
		end
		return
	end
	if ty == Enum.UserInputType.Touch then
		self.ctx.pointer = self.ctx:to_logical(io_view_pos(io))
		return
	end
	if ty == Enum.UserInputType.MouseWheel and shift_down() and self.ui:screen() == "play" and self.enabled then
		-- Shift + wheel: attack ratio (the globe ignores the wheel while Shift is held).
		local z = io.Position.Z
		if z ~= 0 then
			self.ctx:step_ratio(z)
		end
	end
	local _ = gp
end

function UIInteract._set_touch(self: any, on: boolean)
	local ctx = self.ctx
	-- Phones and tablets stay in touch mode.
	if self.ui.debug_touch >= 0 or on == ctx.touch or (not on and ctx.touch_device) then
		return
	end
	ctx.touch = on
	if on then
		self.tooltip:hide_tip()
	end
	if self.bar ~= nil then
		self.bar._flow = -1
	end
	self.ui:relayout()
end

local HOTKEY_INDEX: { [any]: number } = {}
if UICtx.IS_ROBLOX then
	local K = Enum.KeyCode
	HOTKEY_INDEX = {
		[K.One] = 1,
		[K.KeypadOne] = 1,
		[K.Two] = 2,
		[K.KeypadTwo] = 2,
		[K.Three] = 3,
		[K.KeypadThree] = 3,
		[K.Four] = 4,
		[K.KeypadFour] = 4,
		[K.Five] = 5,
		[K.KeypadFive] = 5,
		[K.Six] = 6,
		[K.KeypadSix] = 6,
		[K.Seven] = 7,
		[K.KeypadSeven] = 7,
		[K.Eight] = 8,
		[K.KeypadEight] = 8,
		[K.Nine] = 9,
		[K.KeypadNine] = 9,
		[K.Zero] = 10,
		[K.KeypadZero] = 10,
	}
end

--- Hotkeys. `echo` = a key-repeat (only Q / E repeat). Returns true when handled.
function UIInteract._on_key(self: any, key: Enum.KeyCode, echo: boolean): boolean
	local ctx = self.ctx
	local ui = self.ui
	local UIS = game:GetService("UserInputService")
	local K = Enum.KeyCode
	if
		UIS:IsKeyDown(K.LeftControl)
		or UIS:IsKeyDown(K.RightControl)
		or UIS:IsKeyDown(K.LeftMeta)
		or UIS:IsKeyDown(K.RightMeta)
		or UIS:IsKeyDown(K.LeftAlt)
		or UIS:IsKeyDown(K.RightAlt)
		or UIS:IsKeyDown(K.LeftSuper)
		or UIS:IsKeyDown(K.RightSuper)
		or ctx:pause_menu_open()
	then
		return false
	end
	if echo and key ~= K.Q and key ~= K.E then
		return false
	end
	local handled = true
	if key == K.Escape or key == K.X then
		handled = self:escape()
	elseif key == K.H then
		ui:toggle_help()
	elseif key == K.Tab then
		-- the leaderboard (Tab, as in most games; Roblox's own player list is off)
		if ui:screen() == "title" then
			handled = false
		else
			ui:toggle_leaderboard()
		end
	elseif key == K.Space then
		if ui:screen() == "play" or ui:screen() == "spawn" then
			self:primary_at_hover()
		else
			handled = false
		end
	elseif key == K.Backspace then
		handled = ui:screen() == "play" and self.enabled and self:retreat_latest()
	elseif key == K.Q or key == K.E then
		if ui:screen() == "play" and self.enabled then
			ctx:step_ratio(if key == K.E then 1 else -1)
			if not echo then
				self._held[key] = { t = 0.0, next = UIInteract.REPEAT_DELAY }
			end
		else
			handled = false
		end
	else
		local idx = HOTKEY_INDEX[key]
		if idx ~= nil and ui:screen() == "play" and self.enabled then
			self:select_action(UIRules.ACTIONS[idx])
		else
			handled = false
		end
	end
	return handled
end

--- Q / E held down repeat like an OS key repeat (Roblox sends no echo events).
function UIInteract._key_repeat(self: any, delta: number)
	if next(self._held) == nil or not UICtx.IS_ROBLOX then
		return
	end
	local UIS = game:GetService("UserInputService")
	for key, h in self._held do
		if not UIS:IsKeyDown(key) or UIS:GetFocusedTextBox() ~= nil then
			self._held[key] = nil
			continue
		end
		h.t += delta
		while h.t >= h.next do
			h.next += UIInteract.REPEAT_RATE
			self:_on_key(key, true)
		end
	end
end

--- Esc: close the top-most transient thing. Returns false when there was nothing to close.
function UIInteract.escape(self: any): boolean
	local ui = self.ui
	local radial = self.radial
	if radial.is_open then
		radial:close()
		return true
	end
	if self.unit_card ~= nil and self.unit_card.is_open then
		self:deselect_unit(true)
		return true
	end
	if self.target_card ~= nil and self.target_card.is_open then
		self.target_card:hide_card(true)
		return true
	end
	if self.aim_kind ~= "" then
		self:cancel_aim()
		return true
	end
	if ui.help.is_open then
		ui.help:close()
		return true
	end
	if ui.pause.is_open then
		ui.pause:close()
		return true
	end
	local tt = self.tooltip
	if tt:is_shown() and tt.place == tt.Place.PINNED then
		tt:hide_tip()
		return true
	end
	return false
end

return UIInteract
