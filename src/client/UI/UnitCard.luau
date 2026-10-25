--!nonstrict
-- Port of scripts/ui/unit_card.gd (UIUnitCard)
-- Selected-warship card (compact on phones): health bar, veterancy chevrons with kills toward the
-- next rank, state (Patrolling / Returning to port for repairs / Repairing) and, for your own
-- ship, the hint "Tap the sea to move". Enemy warships show owner, health and veterancy only.
-- Reads GameState unit fields defensively (hp, max_hp, veterancy, vet_progress, state).

local UITheme = require("./UITheme")
local W = require("./Widgets")
local GlassPanel = require("./GlassPanel")
local UICtx = require("./UICtx")
local Signal = UITheme.core("Signal")

local UIRules = nil
local function Rules()
	if UIRules == nil then
		UIRules = UICtx.mod("UIRules")
	end
	return UIRules
end

local UnitCard = W.class(W.Control)

UnitCard.STATE_TEXT = { [0] = "Patrolling", "Returning to port for repairs", "Repairing" }
UnitCard.DEST_SECONDS = 2.5

--- Reads a unit field that the Sim may not expose yet.
function UnitCard.field(u: any, fname: string, fallback: number): number
	local v = u[fname]
	return if type(v) == "number" then v else fallback
end

function UnitCard.new(c: any)
	local self = setmetatable({}, UnitCard.__mt)
	W.Control._init(self)
	self.ctx = c
	self.closed = Signal.new()
	self.uid = 0
	self.is_open = false
	self.own = false
	self._accum = 0.0
	--- Destination marker after a move order: tile and seconds left.
	self._dest_tile = -1
	self._dest_t = 0.0
	self:set_mouse_filter(W.MOUSE_IGNORE)
	self:set_anchors_and_offsets_preset(W.PRESET_FULL_RECT)
	-- Destination marker (screen space, drawn under the card).
	self._marker = UICtx.canvas(self.gui, "DestMarker")
	self._marker.ZIndex = 1
	self._m_pulse = UICtx.ring(self._marker, Vector2.zero, 6, 2, UITheme.CYAN, 1)
	self._m_ring = UICtx.ring(self._marker, Vector2.zero, 9, 2, UITheme.CYAN, 1)
	self._m_dot = UICtx.circle(self._marker, Vector2.zero, 3, UITheme.CYAN, 1)
	self._marker.Visible = false

	local panel = GlassPanel.new(10.0, 4.0, UITheme.R_LG, true, 18)
	panel:set_accent(UITheme.CYAN)
	self._panel = panel
	self:add_child(panel)
	local v = UITheme.vbox(5)
	panel:add_child(v)
	local head = UITheme.hbox(7)
	self._icon = UITheme.icon_rect("warship", 16.0, UITheme.CYAN)
	self._icon.size_flags_vertical = W.SHRINK_CENTER
	head:add_child(self._icon)
	self._title = UITheme.label("Warship", 14, 700)
	self._title.size_flags_vertical = W.SHRINK_CENTER
	head:add_child(self._title)
	self._sw = UITheme.swatch(UITheme.TEXT, 9.0, 2)
	self._sw.size_flags_vertical = W.SHRINK_CENTER
	head:add_child(self._sw)
	self._owner_l = UITheme.label("", 12, 600, UITheme.TEXT_2)
	self._owner_l.text_overrun_behavior = W.OVERRUN_ELLIPSIS
	self._owner_l.clip_text = true
	self._owner_l:set_min_size(Vector2.new(60, 0))
	self._owner_l.size_flags_horizontal = W.EXPAND_FILL
	self._owner_l.size_flags_vertical = W.SHRINK_CENTER
	head:add_child(self._owner_l)
	local close = UITheme.button("", "GhostButton", "close", 44.0)
	close.name = "UnitClose"
	close.gui.Name = "UnitClose"
	close.expand_icon = true
	close.icon_alignment = W.ALIGN_CENTER
	close:add_theme_constant_override("icon_max_width", 12)
	close:set_min_size(Vector2.new(44, 44))
	close.pressed:Connect(function()
		self:hide_card(true)
	end)
	self._close = close
	head:add_child(close)
	v:add_child(head)
	local hp_row = UITheme.hbox(8)
	local FillBar = UICtx.mod("FillBar")
	self._hp_bar = FillBar.new(5.0, UITheme.GREEN)
	self._hp_bar.glow = false
	self._hp_bar:set_min_size(Vector2.new(120, 8))
	self._hp_bar.size_flags_horizontal = W.EXPAND_FILL
	self._hp_bar.size_flags_vertical = W.SHRINK_CENTER
	hp_row:add_child(self._hp_bar)
	self._hp_l = UITheme.label("", 12, 700, UITheme.TEXT)
	UITheme.fix_width(self._hp_l, UITheme.text_width("8888 / 8888", 12, 700) + 2.0, W.ALIGN_RIGHT)
	hp_row:add_child(self._hp_l)
	v:add_child(hp_row)
	local vet_row = UITheme.hbox(6)
	self._vet = UITheme.hbox(2)
	for _ = 1, 3 do
		local ch = UITheme.icon_rect("chevron", 14.0, UITheme.GOLD)
		ch.gui.Rotation = 180 -- rank chevrons point up (flip_v)
		self._vet:add_child(ch)
	end
	vet_row:add_child(self._vet)
	self._vet_l = UITheme.label("", 12, 600, UITheme.TEXT_2)
	vet_row:add_child(self._vet_l)
	v:add_child(vet_row)
	self._next_l = UITheme.label("", 12, 500, UITheme.TEXT_3)
	v:add_child(self._next_l)
	self._state_l = UITheme.label("", 12, 600, UITheme.TEXT_2)
	v:add_child(self._state_l)
	self._hint = UITheme.label("Tap the sea to move it", 12, 600, UITheme.CYAN)
	v:add_child(self._hint)
	panel:set_min_size(Vector2.new(240, 0))
	panel:set_visible(false)
	self:set_process(true)
	return self
end

function UnitCard.show_unit(self, u: number)
	local ctx = self.ctx
	local s = ctx.state
	local info = if s ~= nil then s.units[u] else nil
	if info == nil then
		return
	end
	self.uid = u
	self.own = info.owner == ctx:me() and ctx:me() ~= 0
	local was = self.is_open
	self.is_open = true
	self._panel:set_visible(true)
	self:refresh()
	self:place()
	if not was then
		UICtx.pop_in(self._panel, 0.0, 0.94, 0.22)
	end
	ctx:sfx("click", -8.0)
end

function UnitCard.hide_card(self, user: boolean?)
	if not self.is_open then
		return
	end
	self.is_open = false
	self.uid = 0
	self._panel:set_visible(false)
	if user then
		self.ctx:sfx("close", -8.0)
	end
	self.closed:Fire()
end

function UnitCard.refresh(self)
	local ctx = self.ctx
	local s = ctx.state
	local u = if s ~= nil then s.units[self.uid] else nil
	if u == nil then
		self:hide_card()
		return
	end
	local R = UICtx.core("Rules")
	local o = s:get_owner(u.owner)
	UITheme.set_swatch_color(self._sw, if o ~= nil then o.color else UITheme.TEXT)
	self._owner_l:set_text(if self.own then "Yours" else s:owner_name(u.owner))
	self._sw:set_visible(not self.own)
	local max_hp = UnitCard.field(u, "max_hp", R.WARSHIP_HP)
	if max_hp <= 0.0 then
		max_hp = R.WARSHIP_HP
	end
	local hp = UnitCard.field(u, "hp", max_hp)
	local frac = math.clamp(hp / math.max(max_hp, 1.0), 0.0, 1.0)
	self._hp_bar.fill_color = if frac > 0.75 then UITheme.GREEN elseif frac > 0.35 then UITheme.GOLD else UITheme.RED
	self._hp_bar:set_target(frac, true)
	self._hp_l:set_text(string.format("%d / %d", math.floor(hp + 0.5), math.floor(max_hp + 0.5)))
	local vet = math.floor(UnitCard.field(u, "veterancy", 0.0))
	for i, ch in ipairs(self._vet:get_children()) do
		ch:set_modulate_a(if i - 1 < vet then 1.0 else 0.22)
	end
	local max_vet = tonumber(Rules().rules_const("WARSHIP_MAX_VET", 3)) or 3
	local prog = UnitCard.field(u, "vet_progress", -1.0)
	self._vet_l:set_text(string.format("Veterancy %d of %d", vet, max_vet))
	-- sinking a warship ranks up at once; or 10 transports / 25 trade ships.
	self._next_l:set_visible(vet < max_vet)
	if prog >= 0.0 then
		self._next_l:set_text(string.format("%d%% to the next rank", math.floor(prog * 100.0 + 0.5)))
	else
		self._next_l:set_text(
			string.format(
				"Next: sink a warship or %d boats",
				tonumber(Rules().rules_const("WARSHIP_VET_TRANSPORTS", 10)) or 10
			)
		)
	end
	local stt = math.floor(UnitCard.field(u, "state", 0.0))
	self._state_l:set_text(UnitCard.STATE_TEXT[math.clamp(stt, 0, 2)])
	UITheme.set_font_color(
		self._state_l,
		if stt == 1 then UITheme.ORANGE elseif stt == 2 then UITheme.GREEN else UITheme.TEXT_2
	)
	self._hint:set_visible(self.own)
	self._hint:set_text(if ctx.touch then "Tap the sea to move it" else "Click the sea to move it")
	self._panel:set_accent(if self.own then UITheme.CYAN else UITheme.ORANGE)
end

--- Bottom-left above the command bar on phones (like the target card), bottom-centre otherwise;
--- never over the ship itself.
function UnitCard.place(self)
	local ctx = self.ctx
	local area = ctx:clear_rect()
	local sz = self._panel:get_combined_minimum_size()
	local bottom = area.Max.Y
	local bar = self:get_meta("bar", nil)
	if bar ~= nil and bar:is_visible_in_tree() then
		bottom = math.min(bottom, bar:top_edge())
	end
	local y = math.max(bottom - sz.Y - 10.0, area.Min.Y + 4.0)
	local cands = {}
	if not ctx.compact then
		table.insert(cands, Vector2.new((ctx.vp.X - sz.X) * 0.5, y))
	end
	table.insert(cands, Vector2.new(area.Min.X + 10.0, y))
	table.insert(cands, Vector2.new(area.Max.X - sz.X - 10.0, y))
	table.insert(cands, Vector2.new(area.Min.X + 10.0, area.Min.Y + 4.0))
	local sp = self:ship_screen_pos()
	local p = cands[1]
	for _, cnd in ipairs(cands) do
		if sp.X < 0.0 or not UICtx.rect_has_point(UICtx.rect_grow(UICtx.rect_ps(cnd, sz), 24.0), sp) then
			p = cnd
			break
		end
	end
	local rp = Vector2.new(math.floor(p.X + 0.5), math.floor(p.Y + 0.5))
	self._panel:set_offsets(rp.X, rp.Y, rp.X, rp.Y)
	self._panel:reset_size()
end

function UnitCard.ship_screen_pos(self): Vector2
	local s = self.ctx.state
	local u = if s ~= nil then s.units[self.uid] else nil
	if u == nil or u.path == nil or #u.path == 0 then
		return Vector2.new(-1, -1)
	end
	return self.ctx:tile_screen_pos(u.path[1])
end

function UnitCard.panel_rect(self): Rect
	return if self.is_open then self._panel:get_global_rect() else UICtx.EMPTY_RECT
end

--- Pulse a destination ring on the sea for a moment after a move order.
function UnitCard.mark_destination(self, tile: number)
	self._dest_tile = tile
	self._dest_t = UnitCard.DEST_SECONDS
	self:_draw_marker()
end

function UnitCard._draw_marker(self)
	local ctx = self.ctx
	if self._dest_tile < 0 or self._dest_t <= 0.0 then
		self._marker.Visible = false
		return
	end
	local p = ctx:tile_screen_pos(self._dest_tile)
	if p.X < 0.0 then
		self._marker.Visible = false
		return
	end
	ctx:fit_canvas(self._marker)
	self._marker.Visible = true
	local D = UnitCard.DEST_SECONDS
	local a = math.clamp(self._dest_t / D, 0.0, 1.0)
	local k = 1.0 - (self._dest_t % 0.8) / 0.8
	UICtx.set_circle(self._m_pulse, p, 6.0 + 16.0 * k);
	(self._m_pulse:FindFirstChild("Stroke") :: UIStroke).Transparency = 1 - a * (1.0 - k)
	UICtx.set_circle(self._m_ring, p, 9.0);
	(self._m_ring:FindFirstChild("Stroke") :: UIStroke).Transparency = 1 - a
	UICtx.set_circle(self._m_dot, p, 3.0)
	self._m_dot.BackgroundTransparency = 1 - a
end

function UnitCard._process(self, delta: number)
	if self._dest_t > 0.0 then
		self._dest_t -= delta
		if self._dest_t <= 0.0 then
			self._dest_tile = -1
		end
		self:_draw_marker()
	end
	if not self.is_open then
		return
	end
	self._accum += delta
	if self._accum >= 0.25 then
		self._accum = 0.0
		self:refresh()
	end
end

return UnitCard
