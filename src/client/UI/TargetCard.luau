--!nonstrict
-- Port of scripts/ui/target_card.gd (UITargetCard)
-- Touch "look before you act" card: the first tap on a foreign nation (or a coast reached by boat)
-- selects it and shows who it is, with a big primary order button ("Attack · 12.3K"). A second
-- tap on the same target, or the button, fires; Ally proposes an alliance; ✕ or a tap elsewhere
-- closes it. For an ally (kind "ally") it offers Donate and Break alliance, which first asks for
-- confirmation and spells out the Traitor penalty.

local UITheme = require("./UITheme")
local W = require("./Widgets")
local GlassPanel = require("./GlassPanel")
local UICtx = require("./UICtx")
local Signal = UITheme.core("Signal")
local Defs = UICtx.core("Defs")

local _Rules = nil
local function Rules()
	if _Rules == nil then
		_Rules = UICtx.core("Rules")
	end
	return _Rules
end

local TargetCard = W.class(W.Control)

TargetCard.LIFETIME = 12.0

local function close_button(icon_px: number)
	local b = UITheme.button("", "GhostButton", "close", 44.0)
	b.expand_icon = true
	b.icon_alignment = W.ALIGN_CENTER
	b:add_theme_constant_override("icon_max_width", icon_px)
	b:set_min_size(Vector2.new(44, 44))
	return b
end
TargetCard.close_button = close_button

function TargetCard.new(c: any)
	local self = setmetatable({}, TargetCard.__mt)
	W.Control._init(self)
	self.ctx = c
	self.fire = Signal.new()
	self.ally = Signal.new()
	self.closed = Signal.new()
	--- Break the alliance; `attack` = also attack them right away (a betrayal).
	self.betray = Signal.new()
	self.donate = Signal.new()
	self.tile = -1
	self.owner_id = 0
	self.kind = "" -- "attack", "boat" or "ally"
	self.confirming = false
	self.shown_msec = 0
	self.is_open = false
	self._age = 0.0
	self:set_mouse_filter(W.MOUSE_IGNORE)
	self:set_anchors_and_offsets_preset(W.PRESET_FULL_RECT)
	local panel = GlassPanel.new(12.0, 10.0, UITheme.R_LG, true, 20)
	panel:set_accent(UITheme.AMBER)
	self._panel = panel
	self:add_child(panel)
	local v = UITheme.vbox(8)
	panel:add_child(v)
	local head = UITheme.hbox(8)
	self._sw = UITheme.swatch(UITheme.TEXT, 12.0, 3)
	head:add_child(self._sw)
	self._name = UITheme.label("", 15, 700)
	UITheme.fix_width(self._name, 150.0, W.ALIGN_LEFT, false)
	self._name.size_flags_vertical = W.SHRINK_CENTER
	head:add_child(self._name)
	self._badge = W.Panel.new()
	self._badge:set_mouse_filter(W.MOUSE_IGNORE)
	self._badge.size_flags_vertical = W.SHRINK_CENTER
	self._badge_l = UITheme.label("", 12, 700, UITheme.TEXT_2, 1)
	self._badge:add_child(self._badge_l)
	head:add_child(self._badge)
	local sp = W.Control.new()
	sp.size_flags_horizontal = W.EXPAND_FILL
	sp:set_mouse_filter(W.MOUSE_IGNORE)
	head:add_child(sp)
	self._close = close_button(14)
	self._close.pressed:Connect(function()
		self:hide_card(true)
	end)
	head:add_child(self._close)
	v:add_child(head)
	self._sub = UITheme.label("", 12, 500, UITheme.TEXT_2)
	v:add_child(self._sub)
	local stats = UITheme.hbox(14)
	self._stats = stats
	self._troops = UITheme.label("", 13, 600)
	UITheme.fix_width(self._troops, 110.0, W.ALIGN_LEFT, false)
	stats:add_child(self._troops)
	self._land = UITheme.label("", 13, 600, UITheme.TEXT_2)
	UITheme.fix_width(self._land, 96.0, W.ALIGN_LEFT, false)
	stats:add_child(self._land)
	v:add_child(stats)
	self._odds = UITheme.label("", 12, 600, UITheme.TEXT_3)
	self._odds_warn = false
	v:add_child(self._odds)
	self._warn = UITheme.label("", 13, 600, Color3.new(1.0, 0.82, 0.8))
	self._warn:set_autowrap(true)
	self._warn:set_min_size(Vector2.new(240, 0))
	self._warn:set_visible(false)
	v:add_child(self._warn)
	local btns = UITheme.hbox(8)
	self._go = UITheme.button("Attack", "PrimaryButton", "attack", 48.0)
	self._go:set_font_size(15)
	self._go.size_flags_horizontal = W.EXPAND_FILL
	self._go.pressed:Connect(function()
		self:_on_go()
	end)
	btns:add_child(self._go)
	self._donate = UITheme.button("Donate", "GlassButton", "donate", 48.0)
	self._donate:set_font_size(13)
	self._donate.pressed:Connect(function()
		self.donate:Fire()
	end)
	self._donate:set_visible(false)
	btns:add_child(self._donate)
	self._ally = UITheme.button("Ally", "GlassButton", "alliance", 48.0)
	self._ally:set_font_size(13)
	self._ally.pressed:Connect(function()
		self.ally:Fire()
	end)
	btns:add_child(self._ally)
	v:add_child(btns)
	-- Confirmation row: break without attacking, or keep the alliance.
	self._btns2 = UITheme.hbox(8)
	self._break_only = UITheme.button("Break only", "GlassButton", "betray", 44.0)
	self._break_only:set_font_size(13)
	self._break_only.size_flags_horizontal = W.EXPAND_FILL
	self._break_only.pressed:Connect(function()
		self.betray:Fire(false)
	end)
	self._btns2:add_child(self._break_only)
	self._keep = UITheme.button("Keep ally", "GlassButton", "alliance", 44.0)
	self._keep:set_font_size(13)
	self._keep.size_flags_horizontal = W.EXPAND_FILL
	self._keep.pressed:Connect(function()
		self:hide_card(true)
	end)
	self._btns2:add_child(self._keep)
	self._btns2:set_visible(false)
	v:add_child(self._btns2)
	panel:set_min_size(Vector2.new(300, 0))
	self:set_visible(false)
	self:set_process(true)
	return self
end

--- Select `t` for order `k` ("attack" / "boat" / "ally"); `act` is UIRules.primary() for that tile.
function TargetCard.show_target(self, t: number, k: string, act: any)
	local ctx = self.ctx
	local s = ctx.state
	if s == nil then
		return
	end
	self.tile = t
	self.kind = k
	self.confirming = false
	self.owner_id = s:tile_owner(t)
	self.shown_msec = UICtx.msec()
	self._age = 0.0
	local troops = UITheme.fmt_troops(tonumber(act.troops) or 0.0)
	local c = ctx.compact
	if self.owner_id ~= 0 then
		local o = s:get_owner(self.owner_id)
		UITheme.set_swatch_color(self._sw, if o ~= nil then o.color else UITheme.TEXT)
		self._sw:set_visible(true)
		self._name:set_text(s:owner_name(self.owner_id))
		local rel = ctx:relation(self.owner_id)
		self._badge:set_visible(rel ~= "")
		local rc = ctx:relation_color(rel)
		self._badge_l:set_text(string.upper(rel))
		self._badge_l:set_color(rc)
		self._badge:add_theme_stylebox_override(
			"panel",
			UITheme.flat(UITheme.c(rc, 0.14), 999, UITheme.c(rc, 0.5), 1, 8.0, 1.0)
		)
		self._sub:set_text(
			string.format("%s  ·  %s", ctx:kind_title(if o ~= nil then o.kind else 0), ctx:terrain_title(t))
		)
		self._troops:set_text("Troops " .. UITheme.fmt_troops(if o ~= nil then o.troops else 0))
		self._land:set_text("Land " .. UITheme.fmt_pct(s:land_share(self.owner_id)))
		local mine = tonumber(act.troops) or 0.0
		local theirs = if o ~= nil then o.troops else 0
		self._odds:set_visible(true)
		if theirs > mine * 1.5 then
			self._odds:set_text(string.format("They outnumber the %s troops you would send", troops))
			self._odds:set_color(UITheme.ORANGE)
			self._odds_warn = true
		else
			self._odds:set_text(string.format("You would send %s troops", troops))
			self._odds:set_color(UITheme.TEXT_3)
			self._odds_warn = false
		end
		self._ally:set_visible(self.kind == "attack" or self.kind == "boat")
		self._ally:set_disabled(s:has_request(ctx:me(), self.owner_id))
	else
		self._sw:set_visible(false)
		self._name:set_text("Unclaimed land")
		self._badge:set_visible(false)
		self._sub:set_text(ctx:terrain_title(t) .. "  ·  across the sea")
		self._troops:set_text("")
		self._land:set_text("")
		self._odds:set_visible(true)
		self._odds:set_text(string.format("A transport lands %s troops here", troops))
		self._odds:set_color(UITheme.TEXT_3)
		self._odds_warn = false
		self._ally:set_visible(false)
	end
	self._sub:set_visible(true)
	local plan = nil
	if self.kind == "ally" and self.owner_id ~= 0 then
		local oa = s:get_owner(self.owner_id)
		plan = if ctx.rules ~= nil then ctx.rules:donate_plan(self.owner_id) else nil
		-- Near their troop cap: say how much still fits (a gift above the cap evaporates).
		local who = if s:same_team(ctx:me(), self.owner_id) then "Your teammate" else "Your ally"
		self._sub:set_text(
			if plan ~= nil and plan.capped
				then string.format(
					"%s · %s troops · room for %s",
					who,
					UITheme.fmt_troops(if oa ~= nil then oa.troops else 0),
					UITheme.fmt_troops(plan.room)
				)
				else string.format(
					"%s · %s troops · %s land",
					who,
					UITheme.fmt_troops(if oa ~= nil then oa.troops else 0),
					UITheme.fmt_pct(s:land_share(self.owner_id))
				)
		)
	end
	-- Phones: one info line (who · troops · land); the odds line only when it is a warning.
	self._stats:set_visible(not c)
	if c and self.owner_id ~= 0 and self.kind ~= "ally" then
		local o2 = s:get_owner(self.owner_id)
		self._sub:set_text(
			string.format(
				"%s · %s troops · %s land",
				ctx:kind_title(if o2 ~= nil then o2.kind else 0),
				UITheme.fmt_troops(if o2 ~= nil then o2.troops else 0),
				UITheme.fmt_pct(s:land_share(self.owner_id))
			)
		)
		self._odds:set_visible(self._odds_warn)
	elseif c and self.owner_id == 0 then
		self._odds:set_visible(false)
		self._sub:set_text(string.format("%s · across the sea · lands %s troops", ctx:terrain_title(t), troops))
	end
	for _, b in ipairs({ self._go, self._ally }) do
		b:set_min_height(if c then 44.0 else 48.0)
	end
	self._panel:set_min_size(Vector2.new(if c then 250 else 300, 0))
	UITheme.fix_width(self._name, if c then 110.0 else 150.0, W.ALIGN_LEFT, false)
	self._panel:set_padding(
		if c then 10.0 else 12.0,
		if c then 2.0 else 10.0,
		if c then 4.0 else 12.0,
		if c then 8.0 else 10.0
	)
	local verb = if self.kind == "attack" then "Attack" else "Invade"
	self._go:set_text(string.format("%s · %s", verb, troops))
	self._go:set_icon(if self.kind == "attack" then "attack" else "boat")
	self:_set_variation(self._go, "PrimaryButton")
	self._panel:set_accent(if self.kind == "attack" then UITheme.AMBER else UITheme.CYAN)
	self._warn:set_visible(false)
	self._btns2:set_visible(false)
	self._donate:set_visible(false)
	self._go:set_visible(true)
	if self.kind == "ally" then
		self._odds:set_visible(false)
		-- (a teammate: no alliance to break)
		self._go:set_visible(not s:same_team(ctx:me(), self.owner_id))
		self._ally:set_visible(false)
		self._donate:set_visible(true)
		local amt = if plan ~= nil then plan.amount else ctx:troops_for_ratio()
		local full = plan ~= nil and plan.full
		self._donate:set_text(if full then "At troop cap" else "Donate " .. UITheme.fmt_troops(amt))
		self._donate:set_disabled(amt < 1.0 or full)
		self._go:set_text("Break alliance")
		self._go:set_icon("betray")
		self:_set_variation(self._go, "DangerButton")
		self._panel:set_accent(UITheme.VIOLET)
	end
	local was = self.is_open
	self.is_open = true
	self:set_visible(true)
	self:place()
	if not was then
		UICtx.pop_in(self._panel, 0.0, 0.94, 0.25)
	end
	ctx:sfx("click", -8.0)
end

function TargetCard._set_variation(_self, b, variation: string)
	if b.theme_type_variation ~= variation then
		b.theme_type_variation = variation
		b:_theme_changed()
		b:_restyle_label()
	end
end

--- Same target as the current selection (owner for attacks; nearby coast for boats), still fresh.
function TargetCard.matches(self, t: number, k: string): boolean
	if not self.is_open or k ~= self.kind or UICtx.msec() - self.shown_msec > TargetCard.LIFETIME * 1000.0 then
		return false
	end
	local s = self.ctx.state
	if s == nil then
		return false
	end
	if k == "attack" then
		return s:tile_owner(t) == self.owner_id and self.owner_id ~= 0
	end
	return Defs.tile_distance(t, self.tile) <= 4.0 or (self.owner_id ~= 0 and s:tile_owner(t) == self.owner_id)
end

--- Ally card: ask before breaking the alliance (the Traitor penalty is spelled out).
function TargetCard.confirm_betray(self)
	if not self.is_open or self.kind ~= "ally" then
		return
	end
	local ctx = self.ctx
	local R = Rules()
	self.confirming = true
	self._age = 0.0
	local secs = Defs.round(R.TRAITOR_TICKS / R.TICK_RATE)
	self._warn:set_text(
		string.format(
			"Break the alliance with %s? For %d s you are a TRAITOR: every nation sees it and attacks on you cost only %d%% of the troops.",
			if ctx.state ~= nil then ctx.state:owner_name(self.owner_id) else "them",
			secs,
			Defs.round(R.TRAITOR_DEFENSE_DEBUFF * 100.0)
		)
	)
	self._warn:set_visible(true)
	self._sub:set_visible(false)
	self._donate:set_visible(false)
	self._btns2:set_visible(true)
	self._go:set_text("Betray & attack · " .. UITheme.fmt_troops(ctx:troops_for_ratio()))
	self._go:set_icon("attack")
	self._panel:set_accent(UITheme.RED)
	self:place()
	ctx:sfx("open", -8.0)
end

function TargetCard._on_go(self)
	if self.kind ~= "ally" then
		self.fire:Fire()
	elseif not self.confirming then
		self:confirm_betray()
	else
		self.betray:Fire(true)
	end
end

function TargetCard.hide_card(self, user: boolean?)
	if not self.is_open then
		return
	end
	self.is_open = false
	local t = self:create_tween()
	t:tween_property(self, "modulate:a", 0.0, 0.12)
	t:tween_callback(function()
		if not self.is_open then
			self:set_visible(false)
		end
		self:set_modulate_a(1.0)
	end)
	if user then
		self.ctx:sfx("close", -8.0)
	end
	self.closed:Fire()
end

--- Bottom-left above the command bar on phones (the thumb side, clear of the Attacks column);
--- centred above the bar on larger screens.
function TargetCard.place(self)
	local ctx = self.ctx
	local area = ctx:clear_rect()
	local sz = self._panel:get_combined_minimum_size()
	local bottom = area.Max.Y
	local ui_bar = self:get_meta("bar", nil)
	if ui_bar ~= nil and ui_bar:is_visible_in_tree() then
		bottom = math.min(bottom, ui_bar:top_edge())
	end
	local y = math.max(bottom - sz.Y - 10.0, area.Min.Y + 4.0)
	local left = Vector2.new(area.Min.X + 10.0, y)
	local right = Vector2.new(area.Max.X - sz.X - 10.0, y)
	local top_y = area.Min.Y + 4.0
	local cands = {}
	if not ctx.compact then
		table.insert(cands, Vector2.new((ctx.vp.X - sz.X) * 0.5, y))
	end
	table.insert(cands, left)
	table.insert(cands, right)
	-- Narrow screens: a mid-screen target can sit under both bottom corners; try the top ones.
	table.insert(cands, Vector2.new(left.X, top_y))
	table.insert(cands, Vector2.new(right.X, top_y))
	-- Never cover the target itself (the second tap must reach it).
	local tp = if self.tile >= 0 then ctx:tile_screen_pos(self.tile) else Vector2.new(-1, -1)
	local p = cands[1]
	for _, cnd in ipairs(cands) do
		if not (tp.X >= 0 and UICtx.rect_has_point(UICtx.rect_grow(UICtx.rect_ps(cnd, sz), 24.0), tp)) then
			p = cnd
			break
		end
	end
	local rp = Vector2.new(math.floor(p.X + 0.5), math.floor(p.Y + 0.5))
	self._panel:set_offsets(rp.X, rp.Y, rp.X, rp.Y)
	self._panel:reset_size()
end

function TargetCard.panel_rect(self): Rect
	return if self.is_open then self._panel:get_global_rect() else UICtx.EMPTY_RECT
end

function TargetCard._process(self, delta: number)
	if not self.is_open then
		return
	end
	-- The betray confirm is a destructive choice: it waits for an answer (Break only / Keep ally /
	-- ✕) instead of closing under the pointer. Any card also holds while the mouse rests on it.
	-- (review P2-3; the original expires every variant after LIFETIME.)
	local ctx = self.ctx
	if self.confirming then
		-- ...unless the question is moot (the alliance already ended some other way).
		local s = ctx.state
		if s == nil or not s:are_allies(ctx:me(), self.owner_id) then
			self:hide_card()
		end
		return
	end
	if not ctx.touch and UICtx.rect_has_point(self._panel:get_global_rect(), ctx:mouse_pos()) then
		return
	end
	self._age += delta
	if self._age > TargetCard.LIFETIME then
		self:hide_card()
	end
end

return TargetCard
