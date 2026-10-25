--!nonstrict
-- Port of scripts/ui/command_bar.gd (UICommandBar)
-- Bottom command bar: nation chip, troops (with cap, growth and fill), the attack-ratio slider, gold
-- (with income, next to the slots it buys) and the ten build / nuke slots. Re-flows between a single
-- row (wide desktop), two rows (laptop / tablet) and a slim phone strip (icons + numbers, a short
-- slider and a Build toggle; the slots live in a tray and the details in a tap-for-info card).
--
-- The Arsenal (Data/Arsenal; 2026-10-04): one gold SHOP slot closes the row and opens the
-- Arsenal; a kind the player has unlocked gets a slot of its own before it, a locked one has none
-- (2026-10-04: the build menu was too big, so only the SHOP button shows and it all stays on one
-- row; the first version had a second row of eight locked slots). The SHOP slot is one gold button
-- that shows, in turn, what the player has yet to get (ShopSlot; 2026-10-12: one button instead of
-- six sub-buttons, the locked units' cards it held from 2026-10-05). On phones the slots
-- narrow a little, then the SHOP button, before the tray takes a second row (TrayFit).
--
-- Signals: build_chosen(kind), cancel_placement(), footprint_changed(), stats_tapped(),
-- arsenal_wanted(key?, from?) (the SHOP button; key: the item it showed).
-- Members read by UIRoot / UIInteract: panel, tray, buttons, _place_chip, _slider, _tray_btn, _flow.
-- Per frame: update(dt) (GDScript _process).

local UICtx = require("./UICtx") :: any
local UITheme = require("./UITheme")
local W = require("./Widgets")
local GlassPanel = require("./GlassPanel")
local FillBar = require("./FillBar")
local CountLabel = require("./CountLabel")
local RatioSlider = require("./RatioSlider")
local BuildButton = require("./BuildButton")
local ShopSlot = require("./ShopSlot")
local TrayFit = require("./TrayFit")
local Signal = UITheme.core("Signal")

local _UIRules: any = nil
local function UIRules(): any
	if _UIRules == nil then
		_UIRules = UICtx.mod("UIRules")
	end
	return _UIRules
end

local CommandBar = W.class(W.Control)

CommandBar.Flow = { WIDE = 0, STACKED = 1, COMPACT = 2 }
--- Phone tray: a slot is never narrower than this (then the tray takes a second row).
CommandBar.TRAY_SLOT_MIN = TrayFit.SLOT_MIN
--- The SHOP slot outside the phone tray, with nothing locked to show.
CommandBar.SHOP_W = 58.0
--- Phones: the width of one stop of the Attack bar (a finger's target; the strip is 44 tall).
CommandBar.STOP_TOUCH_W = 38.0
local WIDE, STACKED, COMPACT = 0, 1, 2

local function spacer()
	local sp = W.Control.new()
	sp.size_flags_horizontal = W.EXPAND_FILL
	sp:set_mouse_filter(W.MOUSE_IGNORE)
	return sp
end

function CommandBar.new(c: any)
	local self = setmetatable({}, CommandBar.__mt)
	W.Control._init(self)
	self.ctx = c
	self.build_chosen = Signal.new()
	self.cancel_placement = Signal.new()
	--- The bar's footprint changed (tray opened/closed, placement chip shown/hidden).
	self.footprint_changed = Signal.new()
	--- Phone strip: the troops / gold numbers were tapped (show the details card).
	self.stats_tapped = Signal.new()
	--- The SHOP slot was pressed (key: the locked item whose card was, nil for the slot itself).
	self.arsenal_wanted = Signal.new()
	--- The row gained or lost a slot (an Arsenal kind was unlocked).
	self.slots_changed = Signal.new()
	--- the Arsenal kinds with a slot (the unlocked ones), as last arranged: "artillery,mega"
	self._arsenal_sig = ""
	self.buttons = {} -- kind -> BuildButton
	self._flow = -1
	self._root_box = nil
	self._tray_open = false
	self._placing = ""
	self._rate = 0.0
	--- Whether the troop rate is rising, and the last rate seen (see sample_growth).
	self._rate_up = true
	self._last_growth = nil :: number?
	self._poll = 0.0
	self._buttons_dirty = true
	self:set_mouse_filter(W.MOUSE_IGNORE)
	self:set_anchors_and_offsets_preset(W.PRESET_FULL_RECT)
	self.panel = GlassPanel.new(18.0, 12.0, UITheme.R_LG, true, 22)
	self:add_child(self.panel)
	self:_build_sections()
	self:_connect(c.ratio_changed:Connect(function(_r)
		self:_refresh_ratio()
	end))
	return self
end

function CommandBar._build_sections(self)
	local T = UITheme
	local ctx = self.ctx
	-- Nation chip
	self._nation = T.hbox(10)
	self._swatch = T.swatch(T.AMBER, 14.0, 4)
	self._nation:add_child(self._swatch)
	local nv = T.vbox(0)
	nv.size_flags_vertical = W.SHRINK_CENTER
	local name_row = T.hbox(6)
	self._name = T.label("Commander", 15, 700)
	self._name.text_overrun_behavior = W.OVERRUN_ELLIPSIS
	self._name:set_min_size(Vector2.new(96, 0))
	self._name.size_flags_horizontal = W.EXPAND_FILL
	name_row:add_child(self._name)
	self._crown = T.icon_rect("crown", 14.0, T.GOLD)
	self._crown:set_modulate_a(0.0)
	name_row:add_child(self._crown)
	nv:add_child(name_row)
	self._land = T.label("0.0% of the world", 12, 500, T.TEXT_2)
	nv:add_child(self._land)
	self._nation:add_child(nv)
	self._nation:set_min_size(Vector2.new(150, 0))

	-- Troops
	self._troops_box = T.vbox(3)
	local tr = T.hbox(6)
	tr:add_child(T.icon_rect("troops", 12.0, T.TEXT_3))
	tr:add_child(T.caption("Troops"))
	tr:add_child(spacer())
	self._growth = T.label("+0/s", 11, 700, T.GREEN)
	tr:add_child(self._growth)
	self._troops_box:add_child(tr)
	local tv = T.hbox(5)
	self._troops = CountLabel.new(20, 700, T.TEXT, T.fmt_troops)
	tv:add_child(self._troops)
	self._troops_cap = T.label("/ 0", 13, 500, T.TEXT_3)
	self._troops_cap.size_flags_vertical = W.SHRINK_END
	tv:add_child(self._troops_cap)
	self._troops_box:add_child(tv)
	local brow = T.hbox(6)
	self._troops_bar = FillBar.new(4.0, T.CYAN)
	self._troops_bar:set_min_size(Vector2.new(40, 8))
	self._troops_bar.size_flags_horizontal = W.EXPAND_FILL
	self._troops_bar.size_flags_vertical = W.SHRINK_CENTER
	brow:add_child(self._troops_bar)
	-- Troops committed to attacks: space is always reserved, so showing it never moves anything.
	self._committed = T.label("", 11, 700, T.ORANGE)
	self._committed:set_modulate_a(0.0)
	brow:add_child(self._committed)
	self._troops_box:add_child(brow)
	self._troops_box:set_min_size(Vector2.new(158, 0))

	-- Gold (same shape as troops: caption row carries the rate, the value sits below)
	self._gold_box = T.vbox(3)
	local gr = T.hbox(6)
	gr:add_child(T.icon_rect("gold", 12.0, T.TEXT_3))
	gr:add_child(T.caption("Gold"))
	gr:add_child(spacer())
	self._income = T.label("+0/s", 11, 700, T.GREEN)
	gr:add_child(self._income)
	self._gold_box:add_child(gr)
	local gv = T.hbox(6)
	self._gold = CountLabel.new(20, 700, T.GOLD, T.fmt_num)
	gv:add_child(self._gold)
	self._gold_box:add_child(gv)
	self._gold_box:set_min_size(Vector2.new(118, 0))

	-- Attack ratio
	self._ratio_box = T.vbox(2)
	local rr = T.hbox(6)
	rr:add_child(T.icon_rect("attack", 12.0, T.TEXT_3))
	rr:add_child(T.caption("Attack"))
	rr:add_child(spacer())
	self._ratio_pct = T.label("35%", 13, 800, T.AMBER)
	rr:add_child(self._ratio_pct)
	self._ratio_head = rr
	self._ratio_box:add_child(rr)
	local line = T.hbox(8)
	self._slider = RatioSlider.new(ctx)
	self._slider.size_flags_horizontal = W.EXPAND_FILL
	line:add_child(self._slider)
	-- (the phone strip's readout: "Sends" over the troops an order sends now. The share itself is
	-- the stop lit on the bar; until the bar had stops this line read "35%".)
	self._ratio_inline = T.label("Sends", 12, 600, T.TEXT_3)
	self._ratio_inline.size_flags_vertical = W.SHRINK_CENTER
	self._ratio_inline:set_min_size(Vector2.new(40, 0))
	self._ratio_inline.horizontal_alignment = W.ALIGN_RIGHT
	self._ratio_inline:set_visible(false)
	self._ratio_inline_box = T.vbox(0)
	self._ratio_inline_box.size_flags_vertical = W.SHRINK_CENTER
	self._ratio_inline_box:add_child(self._ratio_inline)
	self._ratio_sends = T.label("", 13, 700, T.TEXT)
	self._ratio_sends.horizontal_alignment = W.ALIGN_RIGHT
	self._ratio_inline_box:add_child(self._ratio_sends)
	line:add_child(self._ratio_inline_box)
	self._ratio_line = line
	self._ratio_box:add_child(line)
	self._ratio_sub = T.label("Sends 0 troops", 11, 500, T.TEXT_3)
	self._ratio_box:add_child(self._ratio_sub)
	self._ratio_box:set_min_size(Vector2.new(176, 0))
	self._ratio_box:set_mouse_filter(W.MOUSE_PASS)

	-- Phone strip: troops and gold as icon + number inside one flat button (tap = details card).
	self._m_stats = W.Button.new("", "GhostButton")
	self._m_stats:set_flat(true)
	for _, st in ipairs(W.BUTTON_STATES) do
		self._m_stats:add_theme_stylebox_override(st, T.empty_box())
	end
	self._m_stats.pressed:Connect(function()
		self.stats_tapped:Fire()
	end)
	self._m_stats.button_down:Connect(function()
		self._m_stats:set_modulate_a(0.7)
	end)
	self._m_stats.button_up:Connect(function()
		self._m_stats:set_modulate_a(1.0)
	end)
	self._m_stats_box = T.hbox(10)
	self._m_stats_box:set_anchors_and_offsets_preset(W.PRESET_FULL_RECT)
	self._m_stats_box:set_alignment(W.ALIGN_CENTER)
	local mt = T.vbox(1)
	mt.size_flags_vertical = W.SHRINK_CENTER
	local mth = T.hbox(5)
	local ti = T.icon_rect("troops", 14.0, T.TEXT_2)
	ti.size_flags_vertical = W.SHRINK_CENTER
	mth:add_child(ti)
	self._m_troops = CountLabel.new(15, 700, T.TEXT, T.fmt_troops)
	mth:add_child(self._m_troops)
	-- the troop rate, coloured like the desktop label (green while it isn't falling,
	-- orange once it is) — players time their attacks by it
	self._m_growth = T.label("+0/s", 12, 700, T.GREEN)
	self._m_growth.size_flags_vertical = W.SHRINK_CENTER
	mth:add_child(self._m_growth)
	mt:add_child(mth)
	self._m_troops_bar = FillBar.new(3.0, T.CYAN)
	self._m_troops_bar.glow = false
	self._m_troops_bar:set_min_size(Vector2.new(40, 3))
	mt:add_child(self._m_troops_bar)
	self._m_stats_box:add_child(mt)
	local mgh = T.hbox(5)
	mgh.size_flags_vertical = W.SHRINK_CENTER
	local gi = T.icon_rect("gold", 14.0, T.GOLD)
	gi.size_flags_vertical = W.SHRINK_CENTER
	mgh:add_child(gi)
	self._m_gold = CountLabel.new(15, 700, T.GOLD, T.fmt_num)
	mgh:add_child(self._m_gold)
	self._m_stats_box:add_child(mgh)
	self._m_stats:add_child(self._m_stats_box)
	self._m_ratio = T.hbox(6)
	self._m_ratio.size_flags_vertical = W.SHRINK_CENTER

	-- Build slots
	self._builds = T.hbox(4)
	self._builds2 = T.hbox(8)
	self._builds2:set_alignment(W.ALIGN_CENTER)
	self._tray_v = T.vbox(8)
	local R = UIRules()
	for i, k in ipairs(R.ACTIONS) do
		if k == "atom" then
			self._nuke_div = T.vdivider(40.0)
			local wrap = W.Margin.new()
			wrap:set_mouse_filter(W.MOUSE_IGNORE)
			wrap:add_theme_constant_override("margin_left", 6)
			wrap:add_theme_constant_override("margin_right", 6)
			wrap:add_child(self._nuke_div)
			self._nuke_wrap = wrap
			self._builds:add_child(wrap)
		end
		local b = BuildButton.new(ctx, k, R.HOTKEYS[i])
		b.chosen:Connect(function(kind: string)
			self.build_chosen:Fire(kind)
		end)
		self.buttons[k] = b
		self._builds:add_child(b)
	end

	-- The Arsenal: a slot for each of its kinds (in the row only once unlocked, see _arrange_slots)
	-- and the gold SHOP slot that closes the row
	for _, k in ipairs(R.ARSENAL) do
		local b = BuildButton.new(ctx, k, "")
		b.chosen:Connect(function(kind: string)
			self.build_chosen:Fire(kind)
		end)
		self.buttons[k] = b
	end
	local shop = ShopSlot.new(ctx)
	shop.wanted:Connect(function(key: string?, from: string?)
		self.arsenal_wanted:Fire(key, from)
	end)
	self._shop = shop
	self._arsenal_wrap = W.Margin.new()
	self._arsenal_wrap:set_mouse_filter(W.MOUSE_IGNORE)
	self._arsenal_wrap:add_theme_constant_override("margin_left", 6)
	self._arsenal_wrap:add_child(shop)
	self._builds:add_child(self._arsenal_wrap)

	-- Phone tray + toggle, and the touch placement chip.
	self.tray = GlassPanel.new(10.0, 8.0, T.R_LG, true, 18)
	self.tray:set_visible(false)
	self:add_child(self.tray)
	local tb = W.Button.new("BUILD", "GlassButton")
	tb.toggle_mode = true
	tb:set_icon("city")
	tb:add_theme_constant_override("icon_max_width", 18)
	tb:set_font_size(13)
	tb:set_min_size(Vector2.new(88, 44))
	tb:add_theme_stylebox_override("pressed", T.flat(T.c(T.AMBER, 0.22), T.R_MD, T.AMBER, 1, 12.0, 8.0))
	tb:add_theme_stylebox_override("hover_pressed", T.flat(T.c(T.AMBER, 0.28), T.R_MD, T.AMBER, 1, 12.0, 8.0))
	tb:add_theme_color_override("font_pressed_color", T.AMBER_HI)
	tb:add_theme_color_override("icon_pressed_color", T.AMBER_HI)
	tb.toggled:Connect(function(on: boolean)
		self:set_tray(on)
	end)
	self._tray_btn = tb
	self._place_chip = GlassPanel.new(14.0, 6.0, 999, true, 16)
	self._place_chip:set_visible(false)
	local pc = T.hbox(10)
	local pic = T.icon_rect("target", 16.0, T.AMBER)
	pic.size_flags_vertical = W.SHRINK_CENTER
	pc:add_child(pic)
	self._place_text = T.label("", 13, 600)
	self._place_text.size_flags_vertical = W.SHRINK_CENTER
	pc:add_child(self._place_text)
	local cancel = T.button("Cancel", "GlassButton", "close", 44.0)
	cancel:set_font_size(13)
	cancel:add_theme_constant_override("icon_max_width", 12)
	cancel.pressed:Connect(function()
		self.cancel_placement:Fire()
	end)
	pc:add_child(cancel)
	self._place_chip:add_child(pc)
	self:add_child(self._place_chip)
end

-- ---------------------------------------------------------------------------------------------
-- Layout
-- ---------------------------------------------------------------------------------------------

function CommandBar.apply_layout(self)
	local ctx = self.ctx
	local flow = WIDE
	if ctx.compact then
		flow = COMPACT
	elseif not ctx.wide then
		flow = STACKED
	end
	if flow ~= self._flow then
		self._flow = flow
		self:_reflow()
	end
	local bottom = if not ctx.compact then 12.0 + ctx.insets.w else math.max(6.0, ctx.insets.w)
	self:_anchor_bottom_center(self.panel, bottom)
	-- Tray and placement chip sit just above the bar.
	local above = bottom + self.panel:get_combined_minimum_size().Y + 8.0
	self:_anchor_bottom_center(self.tray, above)
	local chip = self._place_chip
	if ctx.compact then
		-- Phones: the placement hint sits top-left under the top bar, clear of the globe's centre.
		chip.anchor_left, chip.anchor_right, chip.anchor_top, chip.anchor_bottom = 0, 0, 0, 0
		chip.grow_horizontal = W.GROW_END
		chip.grow_vertical = W.GROW_END
		chip.offset_left = ctx.insets.x + 12.0
		chip.offset_right = chip.offset_left
		chip.offset_top = ctx.reserved_top_left.Max.Y + 6.0
		chip.offset_bottom = chip.offset_top
		chip:set_padding(12.0, 0.0, 0.0, 0.0)
		chip:reset_size()
	else
		chip:set_padding(14.0, 6.0, 14.0, 6.0)
		self:_anchor_bottom_center(chip, above)
	end
end

function CommandBar._anchor_bottom_center(_self, c, bottom: number)
	c.anchor_left, c.anchor_right, c.anchor_top, c.anchor_bottom = 0.5, 0.5, 1.0, 1.0
	c.grow_horizontal = W.GROW_BOTH
	c.grow_vertical = W.GROW_BEGIN
	c.offset_left = 0.0
	c.offset_right = 0.0
	c.offset_top = -bottom
	c.offset_bottom = -bottom
	c:reset_size()
end

--- Every value in the bar sits in a box sized for its widest possible text (tabular digits), and
--- labels clip rather than grow, so the bar never changes size or shifts as numbers change.
function CommandBar._apply_fixed_widths(self, compact: boolean)
	local T = UITheme
	local small = math.max(11, T.min_font_size)
	local vf = if compact then 17 else 20
	local cf = math.max(if compact then 12 else 13, T.min_font_size)
	for _, l in ipairs({ self._growth, self._income, self._committed, self._ratio_sub }) do
		l:set_font_size(small)
	end
	self._troops_cap:set_font_size(cf)
	local w_val = T.text_width("888.8M", vf, 700) + 2.0
	local w_gold = T.text_width("8888.8M", vf, 700) + 2.0
	local w_cap = T.text_width("/ 888.8M", cf, 500) + 2.0
	local w_rate = T.text_width("+888.8K/s", small, 700) + 2.0
	local w_war = T.text_width("888.8M at war", small, 700) + 2.0
	T.fix_width(self._troops, w_val, W.ALIGN_RIGHT)
	T.fix_width(self._troops_cap, w_cap)
	T.fix_width(self._growth, w_rate, W.ALIGN_RIGHT)
	T.fix_width(self._committed, w_war, W.ALIGN_RIGHT)
	T.fix_width(self._gold, w_gold)
	T.fix_width(self._income, w_rate, W.ALIGN_RIGHT)
	local cap_troops = T.text_width("TROOPS", small, 700) + 6.0
	local cap_gold = T.text_width("GOLD", small, 700) + 4.0
	local troops_w = math.max(w_val + 5.0 + w_cap, 12.0 + 6.0 + cap_troops + 8.0 + w_rate)
	troops_w = math.max(troops_w, 40.0 + 6.0 + w_war)
	self._troops_box:set_min_size(Vector2.new(troops_w, 0))
	self._gold_box:set_min_size(Vector2.new(math.max(w_gold, 12.0 + 6.0 + cap_gold + 8.0 + w_rate), 0))
	local pct_w = T.text_width("100%", 13, 800) + 2.0
	T.fix_width(self._ratio_pct, pct_w, W.ALIGN_RIGHT)
	local inline_w = math.max(T.text_width("Sends", 12, 600), T.text_width("888.8K", 13, 700)) + 2.0
	T.fix_width(self._ratio_inline, inline_w, W.ALIGN_RIGHT)
	T.fix_width(self._ratio_sends, inline_w, W.ALIGN_RIGHT)
	local ratio_w = if compact then 188.0 else 180.0
	self._ratio_box:set_min_size(Vector2.new(ratio_w, 0))
	T.fix_width(self._ratio_sub, ratio_w, W.ALIGN_LEFT, false)
	-- Phone strip numbers: fixed boxes too.
	T.fix_width(self._m_troops, T.text_width("888.8M", 15, 700) + 2.0, W.ALIGN_LEFT)
	T.fix_width(self._m_growth, T.text_width("+888.8K/s", 12, 700) + 2.0, W.ALIGN_LEFT)
	T.fix_width(self._m_gold, T.text_width("888.8M", 15, 700) + 2.0, W.ALIGN_LEFT)
	local name_w = if compact then 84.0 else 118.0
	T.fix_width(self._name, name_w, W.ALIGN_LEFT, false)
	T.fix_width(self._land, name_w + 20.0, W.ALIGN_LEFT, false)
	self._nation:set_min_size(Vector2.new(name_w + 20.0 + 24.0, 0))
end

--- Screen y of the bar's top edge (for stacking the event feed above it).
function CommandBar.top_edge(self): number
	local ctx = self.ctx
	if not (self.panel.visible and self.visible) then
		return ctx.vp.Y - ctx.insets.w
	end
	local y = self.panel:get_position().Y
	if self.tray.visible then
		y = math.min(y, self.tray:get_position().Y)
	end
	if self._place_chip.visible and not ctx.compact then
		y = math.min(y, self._place_chip:get_position().Y)
	end
	return y
end

--- The bar's own top edge, without the build tray or the placement chip: the map's HUD-free band
--- (UILayoutProbe.update_world_safe_area) uses it, so opening the tray never moves the camera
--- (2026-09-29: before, the band shrank and the view slid up).
function CommandBar.base_edge(self): number
	local ctx = self.ctx
	if not (self.panel.visible and self.visible) then
		return ctx.vp.Y - ctx.insets.w
	end
	return self.panel:get_position().Y
end

--- Phone: show / hide the build tray.
function CommandBar.set_tray(self, on: boolean)
	local ctx = self.ctx
	if self._flow ~= COMPACT then
		on = false
	end
	self._tray_open = on
	self._tray_btn:set_pressed_no_signal(on)
	if self._tray_caption ~= nil then
		UITheme.set_font_color(self._tray_caption, if on then UITheme.AMBER_HI else UITheme.TEXT)
	end
	if on == self.tray.visible then
		return
	end
	if on then
		self.tray:set_visible(true)
		self:refresh_buttons()
		W.pop_in(self.tray, 0.0, 0.94, 0.25)
		ctx:sfx("open", -8.0)
		if ctx.coach ~= nil and ctx.touch then
			ctx.coach:offer("tray", function(): Vector2
				local b = self.buttons["city"]
				if b:is_visible_in_tree() then
					local r = b:get_global_rect()
					return Vector2.new((r.Min.X + r.Max.X) * 0.5, (r.Min.Y + r.Max.Y) * 0.5)
				end
				return Vector2.new(-1, -1)
			end)
		end
	else
		self.tray:set_visible(false)
	end
	self.footprint_changed:Fire()
end

--- The Arsenal kinds the player has unlocked, in slot order.
function CommandBar._unlocked_arsenal(self): { string }
	local out = {}
	local rules = self.ctx.rules
	for _, k in ipairs(UIRules().ARSENAL) do
		if rules ~= nil and not rules:arsenal_locked(k) then
			table.insert(out, k)
		end
	end
	return out
end

--- What the single-row bar holds beyond its ten slots, in px: SHOP (wider while there is anything to get)
--- and a slot per unlocked Arsenal kind. UIRoot: how wide the screen must be for the wide flow.
function CommandBar.extra_width(self): number
	local shop = math.max(CommandBar.SHOP_W, TrayFit.shop_width(#self._shop:locked()))
	return 62.0 * #self:_unlocked_arsenal() + shop + 4.0
end

--- Placement feedback: highlights the slot and, on touch, shows "Tap your land… · Cancel".
function CommandBar.set_placing(self, kind: string)
	local ctx = self.ctx
	local R = UIRules()
	self._placing = kind
	self:set_active(kind)
	if kind ~= "" then
		self:set_tray(false)
	end
	local show = kind ~= "" and ctx.touch
	if show then
		local t = R.SHORT[kind] or kind
		local txt = if R.is_nuke(kind)
			then "Tap a target, then ✓ to launch"
			else string.format("Tap your land, then ✓ to build the %s", t)
		if kind == "warship" then
			txt = "Tap water near your port, then ✓"
		end
		self._place_text:set_text(txt)
	end
	local was = self._place_chip.visible
	self._place_chip:set_visible(show)
	if show and not was then
		self._place_chip:reset_size()
		W.pop_in(self._place_chip, 0.0, 0.94, 0.25)
	end
end

--- Nuke slots live either at the end of the build row or on their own second row. The unlocked
--- Arsenal kinds follow them, and the SHOP slot closes whichever row they are in.
function CommandBar._arrange_slots(self, two_rows: boolean)
	local nukes = { self.buttons["atom"], self.buttons["hydrogen"], self.buttons["mirv"] }
	for _, n in ipairs(nukes) do
		self:_detach(n)
	end
	self:_detach(self._nuke_wrap)
	self:_detach(self._arsenal_wrap)
	for _, k in ipairs(UIRules().ARSENAL) do
		self:_detach(self.buttons[k])
	end
	local unlocked = self:_unlocked_arsenal()
	self._arsenal_sig = table.concat(unlocked, ",")
	local row = self._builds
	if two_rows then
		row = self._builds2
	else
		self._builds:add_child(self._nuke_wrap)
	end
	for _, n in ipairs(nukes) do
		row:add_child(n)
	end
	for _, k in ipairs(unlocked) do
		row:add_child(self.buttons[k])
	end
	row:add_child(self._arsenal_wrap)
end

function CommandBar._detach(_self, c)
	if c ~= nil and c.parent ~= nil then
		c.parent:remove_child(c)
	end
end

function CommandBar._reflow(self)
	local T = UITheme
	local ctx = self.ctx
	for _, c in ipairs({
		self._nation,
		self._troops_box,
		self._gold_box,
		self._ratio_box,
		self._builds,
		self._builds2,
		self._tray_btn,
		self._tray_v,
		self._m_stats,
		self._m_ratio,
	}) do
		self:_detach(c)
	end
	-- The slider and its % / sends readout live in the ratio box, or in the phone strip.
	self:_detach(self._slider)
	self:_detach(self._ratio_inline_box)
	local strip_host = if self._flow == COMPACT then self._m_ratio else self._ratio_line
	strip_host:add_child(self._slider)
	strip_host:add_child(self._ratio_inline_box)
	self:_arrange_slots(false)
	self._shop:refresh()
	local shop_want = TrayFit.shop_width(#self._shop:locked())
	if self._root_box ~= nil then
		self.panel:remove_child(self._root_box)
		self._root_box:queue_free()
		self._root_box = nil
	end
	local compact = self._flow == COMPACT
	for _, b in pairs(self.buttons) do
		b:set_compact(compact, ctx.touch)
	end
	self._builds:set_separation(if ctx.touch then 8 else 4)
	self._troops:set_font_size(if compact then 17 else 20)
	self._gold:set_font_size(if compact then 17 else 20)
	self._name:set_font_size(if compact then 13 else 15)
	self:_apply_fixed_widths(compact)
	local ratio_w = self._ratio_box.custom_minimum_size.X
	-- The Attack bar: five stops. Under a finger each is a target STOP_TOUCH_W wide and the strip's
	-- height tall (the slider it replaced was 96 px for the whole range, 1% to 100%).
	local stop_fs = math.max(12, T.min_font_size)
	local stop_w = math.max(CommandBar.STOP_TOUCH_W, T.text_width("75%", stop_fs, 800) + 10.0)
	self._slider:set_min_size(
		Vector2.new(if compact then stop_w * #UICtx.RATIO_STOPS else ratio_w, if ctx.touch then 44 else 26)
	)
	self._slider.track_height = if ctx.touch then 36.0 else 26.0
	self._slider.font_size = stop_fs
	self._slider:queue_redraw()
	self._ratio_sub:set_visible(not compact)
	self._ratio_head:set_visible(not compact)
	self._ratio_inline:set_visible(compact)
	self._ratio_inline_box:set_visible(compact)
	self._ratio_sends:set_visible(compact)
	self._nation:set_visible(not compact)

	self._nuke_div:set_min_size(Vector2.new(1, if compact then 32 else 40))
	-- Phones: a slim strip exactly one touch target tall.
	self.panel:set_padding(
		if compact then 8.0 else 18.0,
		if compact then 0.0 else 12.0,
		if compact then 4.0 else 18.0,
		if compact then 0.0 else 12.0
	)
	-- Icon on top, "Build" underneath, exactly one touch target tall (the caption is a child label
	-- so it does not add to the button's minimum height).
	local tb = self._tray_btn
	tb:set_text("")
	tb.icon_alignment = W.ALIGN_CENTER
	tb.vertical_icon_alignment = W.VALIGN_TOP
	tb.expand_icon = false
	tb:add_theme_constant_override("icon_max_width", 16)
	tb:set_min_size(Vector2.new(52, 44))
	for _, st in ipairs({ "normal", "hover", "disabled" }) do
		tb:add_theme_stylebox_override(st, T.flat(T.rgba(1, 1, 1, 0.05), T.R_MD, T.rgba(1, 1, 1, 0.08), 1, 0.0, 5.0))
	end
	tb:add_theme_stylebox_override("pressed", T.flat(T.c(T.AMBER, 0.22), T.R_MD, T.AMBER, 1, 0.0, 5.0))
	tb:add_theme_stylebox_override("hover_pressed", T.flat(T.c(T.AMBER, 0.28), T.R_MD, T.AMBER, 1, 0.0, 5.0))
	if self._tray_caption == nil then
		local cap = T.label("Build", 12, 700, T.TEXT)
		cap.horizontal_alignment = W.ALIGN_CENTER
		cap:set_anchors_and_offsets_preset(W.PRESET_BOTTOM_WIDE)
		cap.offset_top = -19.0
		cap.offset_bottom = -3.0
		tb:add_child(cap)
		self._tray_caption = cap
	end

	-- (gold last, next to the slots it buys; 2026-10-13: gold and the attack panel swapped places in
	-- the bottom bar, so gold sits next to what it buys, which is more intuitive)
	local stats_order = { self._nation, self._troops_box, self._ratio_box, self._gold_box }
	if self._flow == WIDE then
		local row = T.hbox(16)
		row:set_alignment(W.ALIGN_CENTER)
		self._root_box = row
		for _, c in ipairs(stats_order) do
			row:add_child(c)
			c.size_flags_vertical = W.SHRINK_CENTER
			row:add_child(T.vdivider(44.0))
		end
		row:add_child(self._builds)
		self._builds.size_flags_vertical = W.SHRINK_CENTER
	elseif compact then
		-- Phone: one slim strip (numbers, short slider, Build); the slots live in a tray.
		local one = T.hbox(8)
		one:set_alignment(W.ALIGN_CENTER)
		self._root_box = one
		-- Width from the fixed number boxes (icon + gap + number + gap + rate, then gold, plus the gap
		-- between).
		local w_stats = 14.0
			+ 5.0
			+ self._m_troops.custom_minimum_size.X
			+ 5.0
			+ self._m_growth.custom_minimum_size.X
			+ 10.0
			+ 14.0
			+ 5.0
			+ self._m_gold.custom_minimum_size.X
		self._m_stats:set_min_size(Vector2.new(w_stats + 4.0, 44.0))
		one:add_child(self._m_stats)
		one:add_child(self._m_ratio)
		one:add_child(tb)
		tb.size_flags_vertical = W.SHRINK_CENTER
		self._builds:set_alignment(W.ALIGN_CENTER)
		-- One row when it fits between the safe edges (the ten slots, the unlocked Arsenal kinds and
		-- the SHOP button: the slots narrow a little first, then SHOP), else builds over nukes.
		local avail = ctx.vp.X - ctx.insets.x - ctx.insets.z - 16.0
		local fit = TrayFit.fit(avail, 10 + #self:_unlocked_arsenal(), #self._shop:locked())
		for _, b in pairs(self.buttons) do
			b:set_slot_width(fit.slot_w)
		end
		self._shop:set_block(fit.shop_w, 64.0)
		self._builds:set_separation(fit.sep)
		self._builds2:set_separation(fit.sep)
		self:_arrange_slots(fit.two_rows)
		self._tray_v:add_child(self._builds)
		if fit.two_rows then
			self._tray_v:add_child(self._builds2)
		end
		self.tray:add_child(self._tray_v)
	else
		local col = T.vbox(10)
		self._root_box = col
		local stats = T.hbox(16)
		stats:set_alignment(W.ALIGN_CENTER)
		for _, c in ipairs(stats_order) do
			stats:add_child(c)
			c.size_flags_vertical = W.SHRINK_CENTER
			if c ~= self._gold_box then
				stats:add_child(T.vdivider(40.0))
			end
		end
		col:add_child(stats)
		self._builds:set_alignment(W.ALIGN_CENTER)
		self._builds.size_flags_horizontal = W.SHRINK_CENTER
		col:add_child(self._builds)
	end
	if not compact then
		self:set_tray(false)
		for _, b in pairs(self.buttons) do
			b:set_slot_width(nil)
		end
		self._shop:set_block(math.max(CommandBar.SHOP_W, shop_want), if ctx.touch then 62.0 else 60.0)
	end
	self._root_box:set_mouse_filter(W.MOUSE_IGNORE)
	self.panel:add_child(self._root_box)
end

-- ---------------------------------------------------------------------------------------------
-- Data
-- ---------------------------------------------------------------------------------------------

function CommandBar.refresh(self, animate: boolean?)
	local ctx = self.ctx
	local T = UITheme
	local anim = animate ~= false
	local s = ctx.state
	local o = ctx:my()
	if s == nil or o == nil then
		return
	end
	local Rules = T.core("Rules")
	local Defs = T.core("Defs")
	local col = T.owner_ui_color(o.color)
	T.set_swatch_color(self._swatch, o.color)
	self._name:set_text(o.name)
	local share = s:land_share(o.id)
	self._land:set_text(string.format("%s of the world", T.fmt_pct(share)))
	local ranking = s:ranking()
	self._crown:set_modulate_a(if #ranking > 0 and ranking[1].id == o.id then 1.0 else 0.0)
	self._troops:set_value(o.troops, anim)
	self._troops_cap:set_text("/ " .. T.fmt_troops(o.max_troops))
	local bar_col = T.lerp(col, T.CYAN, 0.35)
	self._troops_bar.fill_color = bar_col
	self._troops_bar:set_target(o.troops / math.max(o.max_troops, 1.0), not anim)
	self._gold:set_value(o.gold, anim)
	self._m_troops:set_value(o.troops, anim)
	self._m_gold:set_value(o.gold, anim)
	self._m_troops_bar.fill_color = bar_col
	self._m_troops_bar:set_target(o.troops / math.max(o.max_troops, 1.0), not anim)
	self._income:set_text(T.fmt_rate(o.income))
	T.set_font_color(self._income, if o.income > 0 then T.GREEN else T.TEXT_3)
	-- Growth: the troop-rate label — "+{troops gained per second}/s" (NumberFormat clamps
	-- at 0, so a nation above its cap after losing land reads +0/s), green while the rate is not
	-- falling and orange once it is (sample_growth). Attacks spend troops but do not slow it.
	local per_tick = Rules.troop_growth(o.kind, o.troops, math.max(o.max_troops, 1), self:_difficulty())
	self._rate = per_tick * Defs.TICK_RATE
	self._growth:set_text(UIRules().troop_rate_text(self._rate))
	T.set_font_color(self._growth, if self._rate_up then T.GREEN else T.ORANGE)
	self._m_growth:set_text(self._growth.text)
	T.set_font_color(self._m_growth, if self._rate_up then T.GREEN else T.ORANGE)
	local at_war = self:_committed_troops()
	self._committed:set_modulate_a(if at_war > 0 then 1.0 else 0.0)
	self._committed:set_text(if at_war > 0 then string.format("%s at war", T.fmt_troops(at_war)) else "")
	self:_refresh_ratio()
	self:refresh_buttons()
end

--- Coalesced: the slots refresh at most once per frame, however many events ask for it.
function CommandBar.refresh_buttons(self)
	self._buttons_dirty = true
end

function CommandBar._refresh_buttons_now(self)
	self._buttons_dirty = false
	-- an Arsenal kind was unlocked (or the inventory arrived): its slot joins the row, SHOP stops
	-- showing it
	local cards_changed = self._shop:refresh()
	if table.concat(self:_unlocked_arsenal(), ",") ~= self._arsenal_sig or cards_changed then
		self._arsenal_sig = table.concat(self:_unlocked_arsenal(), ",")
		self.slots_changed:Fire() -- (UIRoot lays the HUD out again: the row may need another flow)
		self:_reflow()
		self.footprint_changed:Fire()
	end
	for _, b in pairs(self.buttons) do
		b:refresh()
	end
end

--- Phone details card (the strip shows only numbers): troops, cap, growth, at war, gold, income.
function CommandBar.stats_spec(self): { [string]: any }
	local ctx = self.ctx
	local T = UITheme
	local s = ctx.state
	local o = ctx:my()
	if s == nil or o == nil then
		return {}
	end
	local rows: { any } = {
		{ "Troops", string.format("%s / %s", T.fmt_troops(o.troops), T.fmt_troops(o.max_troops)) },
		{ "Growth", self._growth.text, if self._rate_up then T.GREEN else T.ORANGE },
	}
	local at_war = self:_committed_troops()
	if at_war > 0 then
		table.insert(rows, { "At war", T.fmt_troops(at_war), T.ORANGE })
	end
	table.insert(rows, { "Gold", T.fmt_num(o.gold), T.GOLD })
	table.insert(rows, { "Income", T.fmt_rate(o.income), if o.income > 0 then T.GREEN else T.TEXT_3 })
	table.insert(rows, { "Land", T.fmt_pct(s:land_share(o.id)) })
	local pct = ctx.ratio * 100
	table.insert(rows, {
		"Each order sends",
		string.format(
			"%d%% · %s",
			if pct >= 0 then math.floor(pct + 0.5) else 0,
			T.fmt_troops(ctx:troops_for_ratio())
		),
		T.AMBER,
	})
	return {
		title = o.name,
		swatch = o.color,
		rows = rows,
		footer = "Cities raise your troop cap. More land, more gold.",
	}
end

--- Rect (logical px) of the phone strip's numbers (anchor for the details card).
function CommandBar.stats_rect(self): Rect
	if self._m_stats:is_visible_in_tree() then
		return self._m_stats:get_global_rect()
	end
	return self.panel:get_global_rect()
end

function CommandBar.reset_rate(self)
	self._rate = 0.0
	self._rate_up = true
	self._last_growth = nil
end

function CommandBar._difficulty(self): number
	local session = self.ctx.session
	return if session ~= nil then (tonumber(session.difficulty) or 1) else 1
end

--- Whether the troops/s label shows a rising rate (UIRules.troop_rate_rising), run once per stats
--- update (the server sends stats every 5 ticks). Only new stats count:
--- re-rendering the same numbers must not turn an orange label green.
function CommandBar.sample_growth(self)
	local ctx = self.ctx
	local o = ctx:my()
	if ctx.state == nil or o == nil then
		return
	end
	local Rules = UITheme.core("Rules")
	local rate = Rules.troop_growth(o.kind, o.troops, math.max(o.max_troops, 1), self:_difficulty())
	self._rate_up = UIRules().troop_rate_rising(rate, self._last_growth)
	self._last_growth = rate
end

function CommandBar._committed_troops(self): number
	local ctx = self.ctx
	local s = ctx.state
	local n = 0
	if s == nil then
		return 0
	end
	local me = ctx:me()
	if me == 0 then
		return 0
	end
	for _, a in pairs(s.attacks) do
		if a.attacker == me then
			n += a.troops
		end
	end
	return n
end

function CommandBar.set_active(self, kind: string)
	for k, b in pairs(self.buttons) do
		b:set_active(k == kind)
	end
end

function CommandBar.button(self, kind: string)
	return self.buttons[kind]
end

function CommandBar._refresh_ratio(self)
	local ctx = self.ctx
	local T = UITheme
	local pct = math.floor(ctx.ratio * 100 + 0.5)
	self._ratio_pct:set_text(string.format("%d%%", pct))
	self._ratio_sends:set_text(T.fmt_troops(ctx:troops_for_ratio()))
	self._ratio_sub:set_text(string.format("Sends %s troops", T.fmt_troops(ctx:troops_for_ratio())))
end

--- Per frame (GDScript _process).
function CommandBar.update(self, delta: number)
	self._poll += delta
	if self._poll >= 0.5 then
		self._poll = 0.0
		self._buttons_dirty = true
	end
	if self._buttons_dirty and self:is_visible_in_tree() then
		self:_refresh_buttons_now()
	end
end

--- Sections the current flow does not use are detached (not in the tree): free them with the bar.
function CommandBar.destroy(self)
	local parts = {
		self._nation,
		self._troops_box,
		self._gold_box,
		self._ratio_box,
		self._builds,
		self._builds2,
		self._tray_btn,
		self._tray_v,
		self._m_stats,
		self._m_ratio,
		self._nuke_wrap,
		self._arsenal_wrap,
		self._slider,
		self._ratio_inline_box,
	}
	for _, b in pairs(self.buttons) do
		table.insert(parts, b)
	end
	self:queue_free()
	for _, n in ipairs(parts) do
		if not n._freed and n.parent == nil then
			n:queue_free()
		end
	end
end

return CommandBar
