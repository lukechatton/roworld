--!nonstrict
-- Port of scripts/ui/float_text.gd (UIFloatText)
-- Brief confirmation pill that pops near the cursor, drifts up and fades
-- ("Attacking Brazil with 24.5K", "Not enough gold"...).
--
-- FloatText.spawn(parent_node, pos_logical, text, icon_name, col, bounds_rect?)
-- FloatText.bounds_provider: () -> Rect (logical px) -- live area floats must stay inside, re-read
-- every frame (a tray opening later pushes floats above it).

local UITheme = require("./UITheme")
local W = require("./Widgets")

local FloatText = W.class(W.Control)

FloatText.bounds_provider = nil :: (() -> Rect)?

function FloatText.spawn(parent: any, pos: Vector2, text: string, icon_name: string?, col: any, bounds: Rect?)
	if parent == nil or text == nil or text == "" then
		return nil
	end
	local ft = setmetatable({}, FloatText.__mt)
	W.Control._init(ft)
	ft:set_mouse_filter(W.MOUSE_IGNORE)
	ft._rise = 0.0
	ft._fixed_bounds = bounds
	parent:add_child(ft)
	local pill = W.Panel.new()
	pill:set_mouse_filter(W.MOUSE_IGNORE)
	pill:add_theme_stylebox_override(
		"panel",
		UITheme.flat(UITheme.rgba(0.03, 0.045, 0.1, 0.92), 999, UITheme.c(col, 0.55), 1, 12.0, 5.0)
	)
	local row = UITheme.hbox(7)
	if icon_name ~= nil and icon_name ~= "" then
		local ic = UITheme.icon_rect(icon_name, 14.0, col)
		ic.size_flags_vertical = W.SHRINK_CENTER
		row:add_child(ic)
	end
	row:add_child(UITheme.label(text, 13, 700, UITheme.lerp(UITheme.color3(col), UITheme.WHITE, 0.35)))
	pill:add_child(row)
	pill:set_anchors_and_offsets_preset(W.PRESET_FULL_RECT)
	ft:add_child(pill)
	ft._sz = pill:get_combined_minimum_size()
	local p = pos + Vector2.new(-ft._sz.X * 0.5, -ft._sz.Y - 22.0)
	ft._base_y = p.Y
	ft._x = p.X
	ft:_clamp()
	ft:set_scale(0.85)
	ft:set_modulate_a(0.0)
	ft:set_process(true)
	local t = ft:create_tween():set_parallel(true)
	t:tween_property(ft, "modulate:a", 1.0, 0.12)
	t:tween_property(ft, "scale", 1.0, 0.25):set_trans(W.TRANS_BACK):set_ease(W.EASE_OUT)
	t:tween_property(ft, "_rise", 26.0, 1.5):set_trans(W.TRANS_CUBIC):set_ease(W.EASE_OUT)
	t:tween_property(ft, "modulate:a", 0.0, 0.45):set_delay(1.05)
	t:chain():tween_callback(function()
		ft:queue_free()
	end)
	return ft
end

function FloatText._clamp(self)
	local b = self._fixed_bounds
	local prov = FloatText.bounds_provider
	if prov ~= nil then
		local ok, v = pcall(prov)
		if ok and typeof(v) == "Rect" and v.Width > 0 then
			b = v
		end
	end
	if b == nil or b.Width <= 0 then
		local vp = if self.root then self.root.vp else Vector2.new(1600, 900)
		b = Rect.new(0, 0, vp.X, vp.Y)
	end
	local sz = self._sz
	local x = math.clamp(self._x, b.Min.X + 8.0, math.max(b.Min.X + 8.0, b.Max.X - sz.X - 8.0))
	local y = self._base_y - self._rise
	y = math.clamp(y, b.Min.Y + 8.0, math.max(b.Min.Y + 8.0, b.Max.Y - sz.Y - 8.0))
	self.offset_left = x
	self.offset_top = y
	self.offset_right = x + sz.X
	self.offset_bottom = y + sz.Y
	self:_layout_free()
end

function FloatText._process(self, _delta: number)
	self:_clamp()
end

return FloatText
