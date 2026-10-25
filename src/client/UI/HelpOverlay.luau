--!nonstrict
-- Port of scripts/ui/help_overlay.gd (UIHelpOverlay)
-- "How to play" overlay: illustrated sections (spawn, expand & attack, boats, economy, nukes,
-- alliances, victory) and the mouse/keyboard and touch controls. Scrolls on small screens.
--
-- Also defines two small containers the kit does not ship: Scroll (ScrollContainer, vertical)
-- and Grid (GridContainer), both with Godot layout semantics.

local UITheme = require("./UITheme")
local W = require("./Widgets")
local GlassPanel = require("./GlassPanel")
local UICtx = require("./UICtx")
local UIRules = require("./UIRules")
local Signal = UITheme.core("Signal")
local Defs = UICtx.core("Defs")

local HelpOverlay = W.class(W.Control)

-- =============================================================================================
-- Grid (GridContainer: columns, h_separation, v_separation)
-- =============================================================================================

local Grid = W.class(W.Control)
HelpOverlay.Grid = Grid

function Grid.new(columns: number, hsep: number?, vsep: number?)
	local self = setmetatable({}, Grid.__mt)
	W.Control._init(self)
	self._is_container = true
	self.columns = columns
	self.hsep = hsep or 4
	self.vsep = vsep or 4
	self:set_mouse_filter(W.MOUSE_IGNORE)
	return self
end

function Grid._cells(self): { any }
	local out = {}
	for _, c in ipairs(self.children) do
		if c.visible then
			table.insert(out, c)
		end
	end
	return out
end

function Grid._metrics(self): ({ number }, { number }, { boolean })
	local cells = self:_cells()
	local cols = math.max(1, self.columns)
	local cw, rh, cexp = {}, {}, {}
	for i, c in ipairs(cells) do
		local col = (i - 1) % cols + 1
		local row = (i - 1) // cols + 1
		local m = c:get_combined_minimum_size()
		cw[col] = math.max(cw[col] or 0, m.X)
		rh[row] = math.max(rh[row] or 0, m.Y)
		if bit32.band(c.size_flags_horizontal, W.EXPAND) ~= 0 then
			cexp[col] = true
		end
	end
	for col = 1, cols do
		cw[col] = cw[col] or 0
	end
	return cw, rh, cexp
end

function Grid._get_minimum_size(self): Vector2
	local cw, rh = self:_metrics()
	local w, h = 0, 0
	local nc, nr = 0, 0
	for _, v in ipairs(cw) do
		w += v
		nc += 1
	end
	for _, v in ipairs(rh) do
		h += v
		nr += 1
	end
	return Vector2.new(w + math.max(0, nc - 1) * self.hsep, h + math.max(0, nr - 1) * self.vsep)
end

function Grid._sort_children(self)
	local cells = self:_cells()
	local cols = math.max(1, self.columns)
	local cw, rh, cexp = self:_metrics()
	-- Expanding columns share the spare width (Godot: remaining space split between them).
	local total = 0
	local nexp = 0
	for col = 1, cols do
		total += cw[col]
		if cexp[col] then
			nexp += 1
		end
	end
	local spare = self.size.X - total - (cols - 1) * self.hsep
	if nexp > 0 and spare > 0 then
		for col = 1, cols do
			if cexp[col] then
				cw[col] += spare / nexp
			end
		end
	end
	local y = 0
	for row = 1, #rh do
		local x = 0
		for col = 1, cols do
			local c = cells[(row - 1) * cols + col]
			if c then
				self:fit_child_in_rect(c, Vector2.new(x, y), Vector2.new(cw[col], rh[row]))
			end
			x += cw[col] + self.hsep
		end
		y += rh[row] + self.vsep
	end
end

-- =============================================================================================
-- Scroll (ScrollContainer, vertical only)
-- =============================================================================================

local Scroll = W.class(W.Control)
HelpOverlay.Scroll = Scroll

function Scroll.new()
	local self = setmetatable({}, Scroll.__mt)
	W.Control._init(self, "ScrollingFrame")
	self._is_container = true
	local g = self.gui :: ScrollingFrame
	g.ScrollingDirection = Enum.ScrollingDirection.Y
	g.ScrollBarThickness = 6
	g.ScrollBarImageColor3 = Color3.new(1, 1, 1)
	g.ScrollBarImageTransparency = 0.82
	g.TopImage = "rbxasset://textures/ui/Scroll/scroll-middle.png"
	g.BottomImage = "rbxasset://textures/ui/Scroll/scroll-middle.png"
	g.VerticalScrollBarInset = Enum.ScrollBarInset.None
	g.ElasticBehavior = Enum.ElasticBehavior.WhenScrollable
	g.CanvasSize = UDim2.fromOffset(0, 0)
	g.ScrollingEnabled = true
	g.Active = true
	self:set_mouse_filter(W.MOUSE_PASS)
	return self
end

function Scroll._get_minimum_size(self): Vector2
	local w = 0
	for _, c in ipairs(self.children) do
		if c.visible then
			w = math.max(w, c:get_combined_minimum_size().X)
		end
	end
	return Vector2.new(w, 0)
end

function Scroll._sort_children(self)
	local h = 0
	for _, c in ipairs(self.children) do
		if c.visible then
			-- Width first (autowrapped labels compute their height from it), then the height.
			c:_apply_rect(Vector2.zero, Vector2.new(self.size.X, c:get_combined_minimum_size().Y))
			local m = c:get_combined_minimum_size()
			c:_apply_rect(Vector2.zero, Vector2.new(self.size.X, math.max(m.Y, 0)))
			h = math.max(h, m.Y)
		end
	end
	self._content_h = h;
	(self.gui :: ScrollingFrame).CanvasSize = UDim2.fromOffset(0, math.floor(h * UITheme.scale + 0.5))
end

--- How far the content is scrolled, in logical px (Control.get_global_position subtracts it).
function Scroll._canvas_offset(self): Vector2
	return (self.gui :: ScrollingFrame).CanvasPosition / UITheme.scale
end

function Scroll.scroll_by(self, px: number)
	local g = self.gui :: ScrollingFrame
	local s = UITheme.scale
	local max_y = math.max(0, (self._content_h or 0) * s - g.AbsoluteWindowSize.Y)
	g.CanvasPosition = Vector2.new(0, math.clamp(g.CanvasPosition.Y + px * s, 0, max_y))
end

-- =============================================================================================
-- Help content
-- =============================================================================================

local function Rules()
	return UICtx.core("Rules")
end

--- Numbers in the help text come from Rules, so the text follows balance changes.
function HelpOverlay._fill_rules(text: string): string
	local R = Rules()
	return UIRules.format(text, {
		traitor_s = tostring(Defs.round(R.TRAITOR_TICKS / R.TICK_RATE)),
		traitor_def = tostring(Defs.round(R.TRAITOR_DEFENSE_DEBUFF * 100.0)),
		spacing = tostring(Defs.round(R.STRUCT_MIN_DIST)),
		def_mag = tostring(Defs.round(R.DEFENSE_POST_MAG)),
		def_cost = tostring(Defs.round(R.DEFENSE_POST_COST)),
		sam_r = tostring(Defs.round(R.sam_range(1))),
		ws_retreat = tostring(
			Defs.round((tonumber(UIRules.rules_const("WARSHIP_RETREAT_FRAC", 0.75)) or 0.75) * 100.0)
		),
		post_shoot = if UIRules.rules_const("DEFENSE_POST_SHOOTS", false) == true
			then " Defense Posts also fire on enemy boats in range."
			else "",
		win = tostring(Defs.round(R.WIN_SHARE * 100.0)),
	})
end

HelpOverlay.SECTIONS = {
	{
		icon = "target",
		color = "amber",
		title = "Pick your start",
		text = "Click any unclaimed land to place your capital. Solo games deploy 5 seconds after you choose; until then you can move it.",
	},
	{
		icon = "attack",
		color = "orange",
		title = "Expand & attack",
		text = "Click neutral land beside you to expand, or a nation you border to attack it. The Attack bar sets the share of troops you send (Q / E, or Shift + wheel). Troops regrow on their own, fastest well below your cap.",
	},
	{
		icon = "boat",
		color = "cyan",
		title = "Boats",
		text = "Click a coast you can't reach by land and a transport sails from your nearest shore, landing troops for a beachhead. Warships (built from a Port) patrol where you send them: they hit transports first, then warships, then trade ships, which they capture for gold. Below {ws_retreat}% health a warship returns to port and heals near your ports; kills earn it veterancy. Click one of yours, then the sea, to move it.{post_shoot}",
	},
	{
		icon = "alliance",
		color = "violet",
		title = "Alliances & betrayal",
		text = "Right-click a nation to propose an alliance. Allies can't attack each other and can donate troops. Breaking an alliance brands you a Traitor for {traitor_s} s: everyone knows, and attacks against you cost only {traitor_def}% of the troops and land faster.",
	},
	{
		icon = "city",
		color = "gold",
		title = "Build your economy",
		builds = true,
		wide = true,
		text = "Gold flows from your land, factories and trade. Structures get pricier the more you own and need room ({spacing} tiles apart); place them on your own land with the command bar (1 – 7) or the action menu. Land near a Defense Post costs attackers {def_mag}× the troops and {def_cost}× the time.",
	},
	{
		icon = "atom",
		color = "red",
		title = "Nukes & SAMs",
		text = "A Missile Silo lets you launch Atom bombs, Hydrogen bombs and MIRVs. Blasts erase troops and structures and leave fallout: land that stays poisoned until someone re-conquers it, slowly and at a high cost. SAM Launchers shoot down bombs aimed inside their range ({sam_r} tiles); MIRV warheads can't be stopped.",
	},
	{
		icon = "crown",
		color = "gold",
		title = "Win at 80%",
		text = "Hold {win}% of the world's land to win (fallout doesn't count). Multiplayer matches end after 40 minutes and the largest nation wins. Lose all your land and you're out.",
	},
}
--- The "Credits & licence" card, last: the AGPL's Appropriate Legal Notices (a copyright notice, no
--- warranty, that the game may be shared under the licence, where the licence is) and the CC BY-SA credits
--- (2026-10-25: the AGPL licence and its notices, the copyright notice and the credit for the sprites).
--- NOTICE.md and LICENSE in the source have the full text.
HelpOverlay.LEGAL = {
	"RoWorld is a modified version of OpenFront. © OpenFront and Contributors. Changes © 2026 Snick Co.",
	"RoWorld is free software: you can redistribute it and/or modify it under the terms of the GNU Affero General Public License, version 3, with the additional terms in its LICENSE file. It comes with ABSOLUTELY NO WARRANTY. The licence comes with RoWorld's source code.",
	"Maps, country flags and unit art from OpenFront, licensed CC BY-SA 4.0; the versions converted or adapted for RoWorld are shared under the same licence. Music by Rodrigo Flores.",
	"RoWorld is not affiliated with or endorsed by OpenFront.",
}
--- Where the source lives, under the credits: plain text with the GitHub mark, since Roblox games
--- can't link off-platform (2026-10-25: "Source <github logo> <repo>" at the bottom; the public repo is
--- lukechatton/roworld, lukechatton/rofront is private).
HelpOverlay.SOURCE_REPO = "lukechatton/roworld"
--- The card that pops up over the repo name when it's pressed (2026-10-25), and how long it stays.
HelpOverlay.SOURCE_TIP = {
	title = "Source code",
	body = "Source available on the github website under " .. HelpOverlay.SOURCE_REPO,
}
HelpOverlay.SOURCE_TIP_S = 4.0

-- Roblox: Esc opens Roblox's own menu (games never receive it), so cancel is X or right-click;
-- Backspace (retreat) and WASD / +- are Roblox-port keys the original's list didn't show (review P2-4).
HelpOverlay.KEYS_DESKTOP = {
	{ "Click", "Expand, attack or send a boat" },
	{ "Right-click", "Action menu" },
	{ "Drag", "Rotate the globe" },
	{ "WASD / Arrows", "Pan the globe" },
	{ "Wheel / + −", "Zoom" },
	{ "1 – 0", "Build & nukes" },
	{ "Q / E", "Attack share −/+" },
	{ "Space", "Attack at cursor" },
	{ "Backspace", "Retreat your latest attack" },
	{ "X / Right-click", "Cancel" },
	{ "H", "This help" },
	{ "Tab", "Leaderboard" },
	{ "M", "Music" },
	{ "Home", "Center on your nation" },
	{ "Click a warship", "Then click the sea to move it" },
}
HelpOverlay.KEYS_TOUCH = {
	{ "Tap", "Expand, attack or send a boat" },
	{ "Long-press", "Action menu" },
	{ "Drag", "Rotate the globe" },
	{ "Pinch", "Zoom" },
	{ "Tap a slot", "Tap the globe, then ✓" },
	{ "Tap your land", "Inspect" },
	{ "Tap a warship", "Then tap the sea to move it" },
	{ "Tap an ally", "Donate or break the alliance" },
}

local COLORS = {
	amber = "AMBER",
	orange = "ORANGE",
	cyan = "CYAN",
	gold = "GOLD",
	red = "RED",
	violet = "VIOLET",
}

local function col(name: string): Color3
	local k = COLORS[name]
	return if k then UITheme[k] else UITheme.TEXT
end

function HelpOverlay.new(c: any)
	local self = setmetatable({}, HelpOverlay.__mt)
	W.Control._init(self)
	self.ctx = c
	self.closed = Signal.new()
	self.is_open = false
	self._built_compact = -1
	self._scroll = nil
	self:set_anchors_and_offsets_preset(W.PRESET_FULL_RECT)
	self:set_mouse_filter(W.MOUSE_STOP)
	self:set_visible(false)
	-- Input sink (Godot mouse_filter STOP while open; RadialMenu's Blocker): Active frames don't stop a
	-- click reaching a button behind them, only a button on top does (2026-10-25: a click on the window
	-- pressed the title's Play Solo / JOIN underneath). Under the dim and the window (kit children are
	-- ZIndex 11+), so the dim still sees presses outside the window.
	UICtx.make("TextButton", {
		Name = "Blocker",
		BackgroundTransparency = 1,
		Text = "",
		AutoButtonColor = false,
		Size = UDim2.fromScale(1, 1),
		Active = true,
		Selectable = false,
		ZIndex = 1,
	}, self.gui)
	self._dim = W.ColorRect.new(UITheme.rgba(0.01, 0.015, 0.05, 0.72))
	self._dim:set_anchors_and_offsets_preset(W.PRESET_FULL_RECT)
	self._dim:set_mouse_filter(W.MOUSE_STOP)
	self._dim.gui_input:Connect(function(e)
		-- (a press on the window's own ground reaches the dim too: only one outside it closes)
		if e.pressed and not self._panel:has_global_point(e.global_position) then
			self:close()
		end
	end)
	self:add_child(self._dim)
	self._panel = GlassPanel.new(0.0, 0.0, 18, true, 34)
	self._panel:set_tint(UITheme.rgba(0.045, 0.065, 0.13, 0.94))
	self:add_child(self._panel)
	return self
end

function HelpOverlay._build(self)
	for _, ch in ipairs(self._panel:get_children()) do
		ch:queue_free()
	end
	local ctx = self.ctx
	local compact = ctx.compact
	self._built_compact = if compact then 1 else 0
	local v = UITheme.vbox(0)
	self._panel:add_child(v)
	-- Header
	local hm = W.Margin.new()
	hm:set_mouse_filter(W.MOUSE_IGNORE)
	for _, side in ipairs({ "left", "right" }) do
		hm:add_theme_constant_override("margin_" .. side, if not compact then 28 else 16)
	end
	hm:add_theme_constant_override("margin_top", if not compact then 22 else 12)
	hm:add_theme_constant_override("margin_bottom", if not compact then 14 else 8)
	local head = UITheme.hbox(14)
	hm:add_child(head)
	local hic = UITheme.icon_rect("help", if not compact then 28.0 else 22.0, UITheme.AMBER)
	hic.size_flags_vertical = W.SHRINK_CENTER
	head:add_child(hic)
	local tv = UITheme.vbox(2)
	tv.size_flags_horizontal = W.EXPAND_FILL
	tv.size_flags_vertical = W.SHRINK_CENTER
	tv:add_child(UITheme.label("HOW TO PLAY", if not compact then 24 else 18, 800, UITheme.TEXT, 3))
	local paused = ctx:mode() == UICtx.MODE_SOLO and ctx:in_match()
	tv:add_child(
		UITheme.label(
			"Conquer the real world in seven ideas." .. (if paused then "  ·  Game paused" else ""),
			13,
			500,
			UITheme.TEXT_2
		)
	)
	head:add_child(tv)
	local close_b = UITheme.button("", "GlassButton", "close", 44.0)
	close_b.expand_icon = true
	close_b.icon_alignment = W.ALIGN_CENTER
	close_b:add_theme_constant_override("icon_max_width", 14)
	close_b:set_min_size(Vector2.new(44, 44))
	close_b.size_flags_vertical = W.SHRINK_CENTER
	close_b.pressed:Connect(function()
		self:close()
	end)
	head:add_child(close_b)
	v:add_child(hm)
	v:add_child(UITheme.hdivider())

	local scroll = Scroll.new()
	scroll.size_flags_vertical = W.EXPAND_FILL
	self._scroll = scroll
	v:add_child(scroll)
	local body_m = W.Margin.new()
	body_m:set_mouse_filter(W.MOUSE_IGNORE)
	body_m.size_flags_horizontal = W.EXPAND_FILL
	for _, side2 in ipairs({ "left", "right" }) do
		body_m:add_theme_constant_override("margin_" .. side2, if not compact then 24 else 12)
	end
	body_m:add_theme_constant_override("margin_top", if not compact then 18 else 10)
	body_m:add_theme_constant_override("margin_bottom", if not compact then 22 else 12)
	scroll:add_child(body_m)
	local body = UITheme.vbox(18)
	body.size_flags_horizontal = W.EXPAND_FILL
	body_m:add_child(body)
	-- Two cards per row on wide screens; "wide" sections span the full row.
	local row = nil
	for i, d in ipairs(HelpOverlay.SECTIONS) do
		local card = self:_section(i, d)
		if compact or d.wide then
			body:add_child(card)
			row = nil
			continue
		end
		if row == nil then
			row = UITheme.hbox(14)
			row.size_flags_horizontal = W.EXPAND_FILL
			body:add_child(row)
		end
		row:add_child(card)
		if row:get_child_count() >= 2 then
			row = nil
		end
	end
	body:add_child(self:_controls())
	body:add_child(self:_legal())
	body:add_child(self:_source())
end

local function card_panel(mh: number, mv: number)
	local card = W.Panel.new()
	card:set_mouse_filter(W.MOUSE_IGNORE)
	card:add_theme_stylebox_override(
		"panel",
		UITheme.flat(UITheme.rgba(1, 1, 1, 0.035), 12, UITheme.rgba(1, 1, 1, 0.07), 1, mh, mv)
	)
	return card
end

function HelpOverlay._section(self, n: number, d: any)
	local ctx = self.ctx
	local c = col(d.color)
	local card = card_panel(16.0, 14.0)
	card.size_flags_horizontal = W.EXPAND_FILL
	local h = UITheme.hbox(14)
	card:add_child(h)
	h:add_child(self:_medallion(d.icon, c))
	local v = UITheme.vbox(5)
	v.size_flags_horizontal = W.EXPAND_FILL
	local tr = UITheme.hbox(8)
	local num = UITheme.label(string.format("%02d", n), 12, 800, c, 1)
	num.size_flags_vertical = W.SHRINK_CENTER
	tr:add_child(num)
	tr:add_child(UITheme.label(d.title, 16, 700))
	v:add_child(tr)
	local body = HelpOverlay._fill_rules(d.text)
	if ctx.touch then
		body = body:gsub("Right%-click", "Long-press"):gsub("Click", "Tap"):gsub("click", "tap")
		body = body:gsub(" %(Q / E, or Shift %+ wheel%)", ""):gsub(" with the command bar %(1 – 7%)", " with BUILD")
	end
	local t = UITheme.label(body, 13, 500, UITheme.TEXT_2)
	t:set_autowrap(true)
	t:set_min_size(Vector2.new(220, 0))
	v:add_child(t)
	if d.builds then
		local g = Grid.new(if ctx.compact then 1 else 2, 18, 8)
		g.size_flags_horizontal = W.EXPAND_FILL
		for _, k in ipairs(UIRules.BUILD_KINDS) do
			local item = UITheme.hbox(10)
			item.size_flags_horizontal = W.EXPAND_FILL
			local chip = W.Panel.new()
			chip:set_mouse_filter(W.MOUSE_IGNORE)
			chip:set_min_size(Vector2.new(30, 30))
			chip.size_flags_vertical = W.SHRINK_BEGIN
			chip:add_theme_stylebox_override(
				"panel",
				UITheme.flat(UITheme.c(UITheme.GOLD, 0.1), 8, UITheme.c(UITheme.GOLD, 0.3), 1)
			)
			local ic = UITheme.icon_rect(k, 16.0, UITheme.GOLD)
			ic.size_flags_horizontal = W.SHRINK_CENTER
			ic.size_flags_vertical = W.SHRINK_CENTER
			chip:add_child(ic)
			item:add_child(chip)
			local tv = UITheme.vbox(0)
			tv.size_flags_horizontal = W.EXPAND_FILL
			tv:add_child(UITheme.label(UIRules.TITLES[k], 13, 700))
			local bl = UITheme.label(UIRules.blurb(k), 12, 500, UITheme.TEXT_3)
			bl:set_autowrap(true)
			bl:set_min_size(Vector2.new(180, 0))
			tv:add_child(bl)
			item:add_child(tv)
			g:add_child(item)
		end
		v:add_child(g)
	end
	h:add_child(v)
	return card
end

--- Round icon medallion with a coloured glow (StyleBoxFlat shadow in the section colour).
function HelpOverlay._medallion(self, icon_name: string, c: Color3)
	local wrap = W.Control.new()
	wrap:set_mouse_filter(W.MOUSE_IGNORE)
	wrap.size_flags_vertical = W.SHRINK_BEGIN
	wrap:set_min_size(Vector2.new(52, 52))
	local glow = UICtx.make("ImageLabel", {
		Name = "Glow",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(72 / 52, 72 / 52),
		Image = UICtx.shapes().disc_glow or "",
		ImageColor3 = c,
		ZIndex = 1,
	}, wrap.gui)
	wrap:_part(glow, "ImageTransparency", 0.18)
	local p = W.Panel.new()
	p:set_mouse_filter(W.MOUSE_IGNORE)
	p:set_anchors_and_offsets_preset(W.PRESET_FULL_RECT)
	p:add_theme_stylebox_override("panel", UITheme.flat(UITheme.c(c, 0.14), 26, UITheme.c(c, 0.55), 1))
	local ic = UITheme.icon_rect(icon_name, 26.0, c)
	ic.size_flags_horizontal = W.SHRINK_CENTER
	ic.size_flags_vertical = W.SHRINK_CENTER
	p:add_child(ic)
	wrap:add_child(p)
	return wrap
end

function HelpOverlay._controls(self)
	local ctx = self.ctx
	local card = card_panel(18.0, 16.0)
	local v = UITheme.vbox(12)
	card:add_child(v)
	local hr = UITheme.hbox(10)
	local lic = UITheme.icon_rect("layers", 18.0, UITheme.CYAN)
	lic.size_flags_vertical = W.SHRINK_CENTER
	hr:add_child(lic)
	hr:add_child(UITheme.label("CONTROLS", 14, 800, UITheme.TEXT, 2))
	v:add_child(hr)
	local cols = if ctx.compact then UITheme.vbox(16) else UITheme.hbox(32)
	v:add_child(cols)
	cols:add_child(self:_key_list("Mouse & keyboard", HelpOverlay.KEYS_DESKTOP))
	cols:add_child(self:_key_list("Touch", HelpOverlay.KEYS_TOUCH))
	return card
end

function HelpOverlay._legal(self)
	local card = card_panel(18.0, 16.0)
	local v = UITheme.vbox(8)
	card:add_child(v)
	v:add_child(UITheme.label("CREDITS & LICENCE", 14, 800, UITheme.TEXT, 2))
	for _, para in ipairs(HelpOverlay.LEGAL) do
		local t = UITheme.label(para, 12, 500, UITheme.TEXT_3)
		t:set_autowrap(true)
		t:set_min_size(Vector2.new(220, 0))
		t.size_flags_horizontal = W.EXPAND_FILL
		v:add_child(t)
	end
	return card
end

--- "Source  [<GitHub mark> lukechatton/roworld]", centred below the credits card. Games can't open web
--- links, so pressing the repo name pops up where to find it instead (SOURCE_TIP).
function HelpOverlay._source(self)
	local row = UITheme.hbox(4)
	row.size_flags_horizontal = W.SHRINK_CENTER
	local cap = UITheme.label("Source", 13, 500, UITheme.TEXT_3)
	cap.size_flags_vertical = W.SHRINK_CENTER
	row:add_child(cap)
	local b = UITheme.button(HelpOverlay.SOURCE_REPO, "GhostButton", "github", 40.0)
	b:set_font_size(13)
	b:add_theme_constant_override("icon_max_width", 18)
	b.size_flags_vertical = W.SHRINK_CENTER
	b.pressed:Connect(function()
		self:_show_source_tip(b)
	end)
	row:add_child(b)
	return row
end

--- The tooltip card above the repo name (forced, so taps show it too); it hides after SOURCE_TIP_S,
--- or with the window (the card drops an anchor that is no longer visible).
function HelpOverlay._show_source_tip(self, b: any)
	self.ctx:show_hint(b, HelpOverlay.SOURCE_TIP, true)
	self._tip_serial = (self._tip_serial or 0) + 1
	local serial = self._tip_serial
	task.delay(HelpOverlay.SOURCE_TIP_S, function()
		if self._tip_serial == serial then
			self.ctx:hide_hint(b)
		end
	end)
end

--- Key cap: StyleBoxFlat(white 0.09, r 6, border white 0.2, 1 px, 2 px bottom border).
local function keycap(text: string)
	local cap = W.Panel.new()
	cap:set_mouse_filter(W.MOUSE_IGNORE)
	local sb = UITheme.flat(UITheme.rgba(1, 1, 1, 0.09), 6, UITheme.rgba(1, 1, 1, 0.2), 1, 8.0, 2.0)
	sb.margin = { 8.0, 2.0, 8.0, 3.0 }
	cap:add_theme_stylebox_override("panel", sb)
	cap.size_flags_horizontal = W.SHRINK_BEGIN
	local lip = UICtx.make("Frame", {
		Name = "Lip",
		BorderSizePixel = 0,
		BackgroundColor3 = Color3.new(1, 1, 1),
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -1),
		Size = UDim2.new(1, -8, 0, 1),
		ZIndex = 5,
	}, cap.gui)
	cap:_part(lip, "BackgroundTransparency", 0.2)
	cap:add_child(UITheme.label(text, 11, 700, UITheme.TEXT))
	return cap
end

function HelpOverlay._key_list(self, title: string, keys: any)
	local v = UITheme.vbox(7)
	v.size_flags_horizontal = W.EXPAND_FILL
	v:add_child(UITheme.caption(title, 11, UITheme.TEXT_3))
	local g = Grid.new(2, 12, 6)
	for _, k in ipairs(keys) do
		g:add_child(keycap(k[1]))
		local d = UITheme.label(k[2], 13, 500, UITheme.TEXT_2)
		d.size_flags_vertical = W.SHRINK_CENTER
		g:add_child(d)
	end
	v:add_child(g)
	return v
end

function HelpOverlay.apply_layout(self)
	if self.is_open and self._built_compact ~= (if self.ctx.compact then 1 else 0) then
		self:_build()
	end
	self:_place()
end

function HelpOverlay._place(self)
	local ctx = self.ctx
	local area = ctx:clear_rect()
	local margin_x = if not ctx.compact then 24.0 else 8.0
	local margin_y = if not ctx.compact then 28.0 else 6.0
	local w = math.min(1080.0, area.Width - margin_x * 2.0)
	local h = math.min(820.0, area.Height - margin_y * 2.0)
	local p = area.Min + (Vector2.new(area.Width, area.Height) - Vector2.new(w, h)) * 0.5
	p = Vector2.new(math.floor(p.X + 0.5), math.floor(p.Y + 0.5))
	self._panel:set_min_size(Vector2.new(w, h))
	self._panel:set_offsets(p.X, p.Y, p.X + w, p.Y + h)
	self._panel:reset_size()
end

function HelpOverlay.open(self)
	if self.is_open then
		return
	end
	self.is_open = true
	self:_build()
	self:_place()
	self:set_visible(true)
	self:set_modulate_a(1.0)
	self._panel:set_modulate_a(1.0)
	self._dim:set_modulate_a(0.0)
	W.fade(self._dim, 1.0, 0.25)
	UICtx.pop_in(self._panel, 0.0, 0.95, 0.35)
	self.ctx:sfx("open")
end

function HelpOverlay.close(self)
	if not self.is_open then
		return
	end
	self.is_open = false
	self.ctx:sfx("close")
	local t = self:create_tween():set_parallel(true)
	t:tween_property(self._dim, "modulate:a", 0.0, 0.2)
	t:tween_property(self._panel, "modulate:a", 0.0, 0.18)
	t:chain():tween_callback(function()
		if not self.is_open then
			self:set_visible(false)
		end
	end)
	self.closed:Fire()
end

function HelpOverlay.scroll_by(self, px: number)
	if self._scroll ~= nil then
		self._scroll:scroll_by(px)
	end
end

return HelpOverlay
