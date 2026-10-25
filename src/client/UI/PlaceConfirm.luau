--!nonstrict
-- Port of scripts/ui/place_confirm.gd (UIPlaceConfirm)
-- Touch placement / launch confirmation: a small caption and two big buttons (✕ cancel, ✓ build
-- or launch) floating next to the ghost on the globe, never over it. The buttons follow the
-- ghost's screen position every frame; UIInteract moves the ghost (tap elsewhere, map drag).

local UITheme = require("./UITheme")
local W = require("./Widgets")
local GlassPanel = require("./GlassPanel")
local UICtx = require("./UICtx")
local Signal = UITheme.core("Signal")

local PlaceConfirm = W.class(W.Control)

PlaceConfirm.BTN = 52.0
--- Keep this far (px) from the ghost's centre so the target stays visible and tappable.
PlaceConfirm.CLEAR = 34.0

local function darkened(c: Color3, amount: number): Color3
	return Color3.new(c.R * (1 - amount), c.G * (1 - amount), c.B * (1 - amount))
end

function PlaceConfirm.new(c: any)
	local self = setmetatable({}, PlaceConfirm.__mt)
	W.Control._init(self)
	self.ctx = c
	self.confirmed = Signal.new()
	self.cancelled = Signal.new()
	self.tile = -1
	self.is_open = false
	--- function() -> {Rect}: HUD panels the buttons must stay clear of.
	self.blockers = nil
	self._side = -1
	self:set_mouse_filter(W.MOUSE_IGNORE)
	self:set_anchors_and_offsets_preset(W.PRESET_FULL_RECT)
	self._panel = GlassPanel.new(8.0, 6.0, UITheme.R_LG, true, 16)
	self:add_child(self._panel)
	local v = UITheme.vbox(6)
	self._panel:add_child(v)
	self._caption = UITheme.label("", 12, 700, UITheme.TEXT)
	self._caption:set_alignment(W.ALIGN_CENTER)
	self._caption.text_overrun_behavior = W.OVERRUN_ELLIPSIS
	self._caption.clip_text = true
	v:add_child(self._caption)
	local h = UITheme.hbox(8)
	h:set_alignment(W.ALIGN_CENTER)
	self._no = self:_round_button("close", false)
	self._no.name = "PlaceCancel"
	self._no.gui.Name = "PlaceCancel"
	self._no.pressed:Connect(function()
		self.cancelled:Fire()
	end)
	h:add_child(self._no)
	self._ok = self:_round_button("check", true)
	self._ok.name = "PlaceConfirm"
	self._ok.gui.Name = "PlaceConfirm"
	self._ok.pressed:Connect(function()
		self.confirmed:Fire()
	end)
	h:add_child(self._ok)
	v:add_child(h)
	self:set_visible(false)
	self:set_process(true)
	return self
end

function PlaceConfirm._round_button(self, icon_name: string, primary: boolean)
	local BTN = PlaceConfirm.BTN
	local b = W.Button.new("", "Button")
	b:set_icon(icon_name)
	b.expand_icon = true
	b.icon_alignment = W.ALIGN_CENTER
	b:add_theme_constant_override("icon_max_width", 22)
	b:set_min_size(Vector2.new(BTN, BTN))
	local r = math.floor(BTN * 0.5)
	local bg = UITheme.flat(
		if primary then UITheme.AMBER else UITheme.rgba(0.08, 0.1, 0.16, 0.92),
		r,
		if primary then UITheme.AMBER_LO else UITheme.LINE_2,
		if not primary then 1 else 0,
		4.0,
		4.0
	)
	if primary then
		bg.bw_bottom = 3
		bg.border = UITheme.to_rgba(UITheme.AMBER_LO)
	end
	local hot = UITheme.dup(bg)
	hot.bg = UITheme.to_rgba(if primary then UITheme.AMBER_HI else UITheme.rgba(0.14, 0.17, 0.25, 0.95))
	for _, st in ipairs({ "normal", "disabled" }) do
		b:add_theme_stylebox_override(st, bg)
	end
	for _, st2 in ipairs({ "hover", "pressed", "hover_pressed" }) do
		b:add_theme_stylebox_override(st2, hot)
	end
	local ic = if primary then UITheme.INK else UITheme.TEXT
	for _, cn in ipairs({
		"icon_normal_color",
		"icon_hover_color",
		"icon_pressed_color",
		"icon_hover_pressed_color",
		"icon_disabled_color",
	}) do
		b:add_theme_color_override(cn, ic)
	end
	return b
end

--- Show the buttons for the ghost at `t`. `danger` paints ✓ red (nuke launch).
function PlaceConfirm.show_for(self, t: number, caption: string, danger: boolean, ok: boolean?)
	local okv = if ok == nil then true else ok
	self.tile = t
	self._caption:set_text(caption)
	self._caption:set_min_size(Vector2.new(math.min(UITheme.text_width(caption, 12, 700) + 4.0, 230.0), 0))
	self._ok:set_disabled(not okv)
	local col = if danger then UITheme.RED else UITheme.AMBER
	local sb = UITheme.dup(self._ok:get_theme_stylebox("normal"))
	sb.bg = if okv then UITheme.to_rgba(col) else UITheme.rgba(1, 1, 1, 0.1)
	sb.border = UITheme.to_rgba(darkened(col, 0.3))
	self._ok:add_theme_stylebox_override("normal", sb)
	self._ok:add_theme_stylebox_override("disabled", sb)
	local was = self.is_open
	self.is_open = true
	self:set_visible(true)
	self._panel:reset_size()
	self._side = -1
	self:_follow(true)
	if not was then
		UICtx.pop_in(self._panel, 0.0, 0.9, 0.2, true)
	end
end

function PlaceConfirm.hide_confirm(self)
	if not self.is_open then
		return
	end
	self.is_open = false
	self.tile = -1
	self:set_visible(false)
end

function PlaceConfirm.panel_rect(self): Rect
	return if self.is_open then self._panel:get_global_rect() else UICtx.EMPTY_RECT
end

function PlaceConfirm.button_rects(self): { Rect }
	return if self.is_open then { self._ok:get_global_rect(), self._no:get_global_rect() } else {}
end

function PlaceConfirm._process(self, _delta: number)
	if self.is_open then
		self:_follow(false)
	end
end

--- Beside the ghost: right, left, above or below — the first spot inside the free screen area
--- that keeps CLEAR px from the ghost and off the HUD; the chosen side sticks while it still fits.
function PlaceConfirm._follow(self, force: boolean)
	local ctx = self.ctx
	local CLEAR = PlaceConfirm.CLEAR
	local p = ctx:tile_screen_pos(self.tile)
	if p.X < 0.0 then
		self._panel:set_visible(false) -- behind the globe: nothing to confirm against right now
		return
	end
	self._panel:set_visible(true)
	local sz = self._panel:get_combined_minimum_size()
	local area = ctx:clear_rect()
	local bar = self:get_meta("bar", nil)
	if bar ~= nil and bar:is_visible_in_tree() then
		area = Rect.new(area.Min.X, area.Min.Y, area.Max.X, math.min(area.Max.Y, bar:top_edge() - 6.0))
	end
	local cands = {
		Vector2.new(p.X + CLEAR, p.Y - sz.Y * 0.5), -- right
		Vector2.new(p.X - CLEAR - sz.X, p.Y - sz.Y * 0.5), -- left
		Vector2.new(p.X - sz.X * 0.5, p.Y - CLEAR - sz.Y), -- above
		Vector2.new(p.X - sz.X * 0.5, p.Y + CLEAR), -- below
	}
	local blocked = if self.blockers then self.blockers() else {}
	local order = { 0, 1, 2, 3 }
	if not force and self._side >= 0 then
		table.remove(order, table.find(order, self._side) :: number)
		table.insert(order, 1, self._side)
	end
	local best = -1
	local best_pos = Vector2.zero
	for _, i in ipairs(order) do
		local q = cands[i + 1]
		local r = UICtx.rect_ps(q, sz)
		if not UICtx.rect_encloses(area, r) then
			continue
		end
		local hit = false
		for _, b in ipairs(blocked) do
			if UICtx.rect_intersects(r, b) then
				hit = true
				break
			end
		end
		if hit then
			continue
		end
		best = i
		best_pos = q
		break
	end
	if best < 0 then
		-- Nothing fits cleanly: clamp the right-hand spot into the area, then push it off the ghost.
		local q2 = cands[1]
		local x = math.clamp(q2.X, area.Min.X, math.max(area.Min.X, area.Max.X - sz.X))
		local y = math.clamp(q2.Y, area.Min.Y, math.max(area.Min.Y, area.Max.Y - sz.Y))
		if UICtx.rect_has_point(UICtx.rect_grow(UICtx.rect_ps(Vector2.new(x, y), sz), CLEAR * 0.5), p) then
			y = if p.Y - CLEAR - sz.Y >= area.Min.Y then p.Y - CLEAR - sz.Y else p.Y + CLEAR
		end
		best_pos = Vector2.new(x, y)
	end
	self._side = best
	UICtx.move_node(self._panel, Vector2.new(math.floor(best_pos.X + 0.5), math.floor(best_pos.Y + 0.5)))
end

return PlaceConfirm
