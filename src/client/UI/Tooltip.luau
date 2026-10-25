--!nonstrict
-- Port of scripts/ui/tooltip.gd (UITooltip)
-- Small glass info card. Three placements: following the cursor (tile hover), anchored above a
-- control (button hints) or pinned in a corner (tap-to-inspect on touch screens).
--
-- Spec table: {title, title_color, swatch (Color3), badge, badge_color, sub, rows: {{k, v, color}},
-- body, hint, hint_color, hint_icon, footer}

local UITheme = require("./UITheme")
local W = require("./Widgets")
local GlassPanel = require("./GlassPanel")
local UICtx = require("./UICtx")
local Signal = UITheme.core("Signal")

local Tooltip = W.class(W.Control)

Tooltip.Place = { FOLLOW = 0, ANCHOR = 1, PINNED = 2 }
local Place = Tooltip.Place
--- Tap-to-inspect cards close on their own after this many seconds.
Tooltip.PIN_SECONDS = 6.0

--- Stable key of a spec (GDScript var_to_str(spec)).
local function spec_key(spec: any, p: number): string
	local parts = {}
	local keys = {}
	for k in pairs(spec) do
		table.insert(keys, k)
	end
	table.sort(keys)
	for _, k in ipairs(keys) do
		local v = spec[k]
		if k == "rows" then
			for _, r in ipairs(v) do
				table.insert(parts, tostring(r[1]) .. "=" .. tostring(r[2]) .. "/" .. tostring(r[3]))
			end
		else
			table.insert(parts, k .. "=" .. tostring(v))
		end
	end
	return table.concat(parts, "|") .. "#" .. p
end

function Tooltip.new(c: any)
	local self = setmetatable({}, Tooltip.__mt)
	W.Control._init(self)
	self.ctx = c
	self.closed = Signal.new()
	self.place = Place.FOLLOW
	self._anchor = nil
	self._key = ""
	self._shown = false
	self._tween = nil
	self._target = Vector2.zero
	self._close = nil
	self._pin_rect = Rect.new(0, 0, 0, 0)
	self._pin_age = 0.0
	self:set_mouse_filter(W.MOUSE_IGNORE)
	self:set_anchors_and_offsets_preset(W.PRESET_TOP_LEFT)
	self._panel = GlassPanel.new(12.0, 10.0, UITheme.R_MD, true, 14)
	self._panel:set_mouse_filter(W.MOUSE_IGNORE)
	self:add_child(self._panel)
	self._box = UITheme.vbox(6)
	self._panel:add_child(self._box)
	self:set_modulate_a(0.0)
	self:set_visible(false)
	return self
end

function Tooltip.is_shown(self): boolean
	return self._shown
end

function Tooltip.anchor_is(self, c: any): boolean
	return self._anchor == c
end

function Tooltip.show_follow(self, spec: any)
	self:_show(spec, Place.FOLLOW, nil)
end

function Tooltip.show_anchor(self, spec: any, anchor: any)
	self:_show(spec, Place.ANCHOR, anchor)
end

function Tooltip.show_pinned(self, spec: any, rect: Rect)
	self._pin_rect = rect
	self._pin_age = 0.0
	self:_show(spec, Place.PINNED, nil)
end

function Tooltip.hide_tip(self)
	if not self._shown then
		return
	end
	self._shown = false
	self._key = ""
	if self._tween then
		self._tween:kill()
	end
	self._tween = self:create_tween()
	self._tween:tween_property(self, "modulate:a", 0.0, 0.1)
	self._tween:tween_callback(function()
		if not self._shown then
			self:set_visible(false)
			self:set_process(false)
		end
	end)
end

--- The card's current rect (logical px) — UIInteract.show_inspect keeps it off the tapped spot.
function Tooltip.target_rect(self): Rect
	local sz = self._panel:get_combined_minimum_size()
	return UICtx.rect_ps(self._target, sz)
end

function Tooltip._show(self, spec: any, p: number, anchor: any)
	if self:has_meta("stats") then
		self:remove_meta("stats") -- UIRoot tags its strip-details card after showing it
	end
	local key = spec_key(spec, p)
	local was = self._shown
	self.place = p
	self._anchor = anchor
	self._panel:set_mouse_filter(if p == Place.PINNED then W.MOUSE_STOP else W.MOUSE_IGNORE)
	if key ~= self._key then
		self._key = key
		self:_build(spec)
	end
	self._shown = true
	self:set_visible(true)
	self:set_process(true)
	self._panel:reset_size()
	self._target = self:_compute_target()
	if not was then
		self:_set_pos(self._target)
		if self._tween then
			self._tween:kill()
		end
		self._tween = self:create_tween()
		self._tween:tween_property(self, "modulate:a", 1.0, 0.12)
	elseif self.modulate_a < 1.0 and (self._tween == nil or not self._tween:is_running()) then
		self:set_modulate_a(1.0)
	end
end

function Tooltip._set_pos(self, p: Vector2)
	UICtx.move_node(self, p)
end

function Tooltip._build(self, spec: any)
	for _, ch in ipairs(self._box:get_children()) do
		ch:queue_free()
	end
	local ctx = self.ctx
	local compact = ctx.compact
	local head = UITheme.hbox(8)
	if spec.swatch ~= nil then
		head:add_child(UITheme.swatch(spec.swatch, 11.0, 3))
	end
	local tc = spec.title_color or UITheme.TEXT
	local title = UITheme.label(tostring(spec.title or ""), if compact then 14 else 15, 700, tc)
	title.size_flags_horizontal = W.EXPAND_FILL
	head:add_child(title)
	if spec.badge ~= nil and tostring(spec.badge) ~= "" then
		head:add_child(self:_badge(tostring(spec.badge), spec.badge_color or UITheme.TEXT_2))
	end
	self._close = nil
	if self.place == Place.PINNED then
		local b = UITheme.button("", "GhostButton", "close", 44.0)
		b.expand_icon = true
		b:add_theme_constant_override("icon_max_width", 16)
		b:set_min_size(Vector2.new(44, 44))
		b.icon_alignment = W.ALIGN_CENTER
		b:add_theme_color_override("icon_normal_color", UITheme.TEXT)
		b:add_theme_stylebox_override("normal", UITheme.flat(UITheme.FILL, 10, UITheme.LINE, 1, 12.0, 12.0))
		b.pressed:Connect(function()
			self:hide_tip()
			self.closed:Fire()
		end)
		self._close = b
		head:add_child(b)
	end
	self._box:add_child(head)
	if spec.sub ~= nil and tostring(spec.sub) ~= "" then
		self._box:add_child(UITheme.label(tostring(spec.sub), 12, 500, UITheme.TEXT_2))
	end
	local rows = spec.rows or {}
	if #rows > 0 then
		-- GridContainer(2 columns, h_separation 18, v_separation 3): key column shrinks, the value
		-- column expands and right-aligns (tabular digits).
		local grid = UITheme.vbox(3)
		for _, r in ipairs(rows) do
			local line = UITheme.hbox(18)
			line:add_child(UITheme.label(tostring(r[1]), 12, 500, UITheme.TEXT_3))
			local vc = r[3] or UITheme.TEXT
			local v = UITheme.label(tostring(r[2]), 13, 600, vc)
			v:set_tabular(true)
			v:set_alignment(W.ALIGN_RIGHT)
			v.size_flags_horizontal = W.EXPAND_FILL
			line:add_child(v)
			grid:add_child(line)
		end
		self._box:add_child(grid)
	end
	if spec.body ~= nil and tostring(spec.body) ~= "" then
		local body = UITheme.label(tostring(spec.body), 12, 500, UITheme.TEXT_2)
		body:set_autowrap(true)
		body:set_min_size(Vector2.new(220, 0))
		self._box:add_child(body)
	end
	if spec.hint ~= nil and tostring(spec.hint) ~= "" then
		local hc = spec.hint_color or UITheme.AMBER
		local hint = UITheme.hbox(6)
		self._box:add_child(UITheme.hdivider())
		if spec.hint_icon ~= nil then
			local ic = UITheme.icon_rect(tostring(spec.hint_icon), 14.0, hc)
			ic.size_flags_vertical = W.SHRINK_CENTER
			hint:add_child(ic)
		end
		local hl = UITheme.label(tostring(spec.hint), 12, 600, hc)
		hl:set_autowrap(true)
		hl.size_flags_horizontal = W.EXPAND_FILL
		hl:set_min_size(Vector2.new(196, 0))
		hint:add_child(hl)
		self._box:add_child(hint)
	end
	if spec.footer ~= nil and tostring(spec.footer) ~= "" then
		self._box:add_child(UITheme.label(tostring(spec.footer), 11, 500, UITheme.TEXT_3))
	end
	self._panel:set_min_size(Vector2.new(if self.place ~= Place.ANCHOR then 236 else 220, 0))
end

function Tooltip._badge(self, text: string, c: any)
	local p = W.Panel.new()
	p:set_mouse_filter(W.MOUSE_IGNORE)
	p:add_theme_stylebox_override("panel", UITheme.flat(UITheme.c(c, 0.16), 999, UITheme.c(c, 0.5), 1, 7.0, 1.0))
	p:add_child(UITheme.label(string.upper(text), 10, 700, c, 1))
	p.size_flags_vertical = W.SHRINK_CENTER
	return p
end

function Tooltip._compute_target(self): Vector2
	local ctx = self.ctx
	local vp = ctx.vp
	local sz = self._panel:get_combined_minimum_size()
	local ins = ctx.insets
	local margin = 8.0
	local p = Vector2.zero
	if self.place == Place.FOLLOW then
		local m = ctx:mouse_pos()
		p = m + Vector2.new(20, 22)
		local x, y = p.X, p.Y
		if x + sz.X > vp.X - margin - ins.z then
			x = m.X - 16 - sz.X
		end
		if y + sz.Y > vp.Y - margin - ins.w then
			y = m.Y - 14 - sz.Y
		end
		p = Vector2.new(x, y)
	elseif self.place == Place.ANCHOR then
		local a = self._anchor
		if a ~= nil and not a._freed then
			local r = a:get_global_rect()
			local x = r.Min.X + r.Width * 0.5 - sz.X * 0.5
			local y = r.Min.Y - sz.Y - 10.0
			if y < margin then
				y = r.Max.Y + 10.0
			end
			p = Vector2.new(x, y)
		end
	else
		local pr = self._pin_rect
		p = Vector2.new(pr.Min.X + pr.Width - sz.X, pr.Min.Y + pr.Height - sz.Y)
	end
	return Vector2.new(
		math.clamp(p.X, margin + ins.x, math.max(margin, vp.X - sz.X - margin - ins.z)),
		math.clamp(p.Y, margin + ins.y, math.max(margin, vp.Y - sz.Y - margin - ins.w))
	)
end

function Tooltip._process(self, delta: number)
	if not self._shown then
		return
	end
	if self.place == Place.ANCHOR then
		local a = self._anchor
		if a == nil or a._freed or not a:is_visible_in_tree() then
			self:hide_tip()
			return
		end
	end
	if self.place == Place.PINNED then
		self._pin_age += delta
		if self._pin_age > Tooltip.PIN_SECONDS then
			self:hide_tip()
			return
		end
	end
	self._target = self:_compute_target()
	local cur = Vector2.new(self.offset_left, self.offset_top)
	if (cur - self._target).Magnitude < 0.25 then
		if cur ~= self._target then
			self:_set_pos(self._target)
		end
		return
	end
	if self.place == Place.FOLLOW then
		self:_set_pos(cur:Lerp(self._target, 1.0 - math.exp(-delta * 22.0)))
	else
		self:_set_pos(self._target)
	end
end

return Tooltip
