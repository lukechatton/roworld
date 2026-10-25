--!nonstrict
-- Port of scripts/ui/banner.gd (UIBanner)
-- Centre-screen moment ("THE WAR BEGINS"): a wide letter-spaced title over a soft band that fades
-- in, holds and fades out, then frees itself.

local UITheme = require("./UITheme")
local W = require("./Widgets")

local Banner = W.class(W.Control)

local BAND = Color3.new(0.01, 0.015, 0.05)
-- vertical gradient: alpha 0 -> 0.62 -> 0
local BAND_SEQ = NumberSequence.new({
	NumberSequenceKeypoint.new(0.0, 1.0),
	NumberSequenceKeypoint.new(0.5, 0.0),
	NumberSequenceKeypoint.new(1.0, 1.0),
})

--- UIBanner.make(ctx, title, sub, col, hold = 1.6, top_y = -1, height = 0, small = false)
--- `top_y` / `height`: the band's placement in logical px (height <= 0 = centred default).
--- Add the returned node to a full-rect layer; it animates and frees itself.
function Banner.make(
	ctx: any,
	title: string,
	sub: string,
	col: any,
	hold: number?,
	top_y: number?,
	height: number?,
	small: boolean?
)
	local b = setmetatable({}, Banner.__mt)
	W.Control._init(b)
	b:set_mouse_filter(W.MOUSE_IGNORE)
	b:set_anchors_and_offsets_preset(W.PRESET_FULL_RECT)
	local hold_s = hold or 1.6
	local ty = top_y or -1.0
	local hh = height or 0.0
	local sm = small == true
	local band = W.ColorRect.new(UITheme.c(BAND, 0.62))
	band:set_mouse_filter(W.MOUSE_IGNORE)
	local grad = Instance.new("UIGradient")
	grad.Rotation = 90
	grad.Transparency = BAND_SEQ
	grad.Parent = band.gui
	local v = UITheme.vbox(6)
	v:set_alignment(W.ALIGN_CENTER)
	for _, c in ipairs({ band, v }) do
		c.anchor_left = 0.0
		c.anchor_right = 1.0
		if ty >= 0 and hh > 0 then
			c.anchor_top = 0.0
			c.anchor_bottom = 0.0
			c.offset_top = ty
			c.offset_bottom = ty + hh
		else
			c.anchor_top = 0.36
			c.anchor_bottom = 0.56
		end
	end
	b:add_child(band)
	b:add_child(v)
	local t = UITheme.label(
		title,
		if sm then 22 else (if not ctx.compact then 40 else 26),
		900,
		UITheme.lerp(col, UITheme.WHITE, 0.25),
		if sm then 4 else (if not ctx.compact then 8 else 5)
	)
	t:set_alignment(W.ALIGN_CENTER)
	t:set_shadow(UITheme.rgba(0, 0, 0, 0.5), 3, 6)
	v:add_child(t)
	if sub ~= "" and not sm then
		local s = UITheme.label(sub, if not ctx.compact then 15 else 12, 600, UITheme.TEXT_2, 1)
		s:set_alignment(W.ALIGN_CENTER)
		v:add_child(s)
	end
	b.title_label = t
	-- The text block (title + subtitle) as its own invisible node: UIRoot registers it as a HUD
	-- control so map labels (the player's own included) step aside while the banner is up.
	local area = W.Control.new()
	area:set_mouse_filter(W.MOUSE_IGNORE)
	local tw = t:get_combined_minimum_size().X
	for _, ch in ipairs(v:get_children()) do
		tw = math.max(tw, ch:get_combined_minimum_size().X)
	end
	local th = v:get_combined_minimum_size().Y
	area.anchor_left = 0.5
	area.anchor_right = 0.5
	area.offset_left = -math.ceil(tw * 0.5) - 8
	area.offset_right = math.ceil(tw * 0.5) + 8
	if ty >= 0 and hh > 0 then
		area.anchor_top = 0.0
		area.anchor_bottom = 0.0
		local cy = ty + hh * 0.5
		area.offset_top = math.floor(cy - th * 0.5) - 4
		area.offset_bottom = math.ceil(cy + th * 0.5) + 4
	else
		area.anchor_top = 0.46
		area.anchor_bottom = 0.46
		area.offset_top = -math.ceil(th * 0.5) - 4
		area.offset_bottom = math.ceil(th * 0.5) + 4
	end
	b:add_child(area)
	b.text_area = area
	b._slide_parts = { band, v, area }
	if ty >= 0 and hh > 0 then
		b._base_top = ty
		b._height = hh
		b._shift = 0.0
		b:set_process(true)
	end
	b:set_modulate_a(0.0)
	W.defer(function()
		if b._freed then
			return
		end
		t:set_scale(1.12)
		local tw = b:create_tween():set_parallel(true)
		tw:tween_property(b, "modulate:a", 1.0, 0.35)
		tw:tween_property(t, "scale", 1.0, 0.9):set_trans(W.TRANS_EXPO):set_ease(W.EASE_OUT)
		tw:chain():tween_interval(hold_s)
		tw:chain():tween_property(b, "modulate:a", 0.0, 0.6)
		tw:chain():tween_callback(function()
			b:queue_free()
		end)
	end)
	return b
end

--- Optional: `avoid` = function() -> Rect? (logical px) the banner's text must not cover (the local
--- player's own label while the camera pushes in); `min_top` / `max_bottom` bound where the band
--- may move. Set by the caller after make() (explicitly placed banners only).
Banner.MARGIN = 10.0

--- Keeps the text block clear of the `avoid` rect: slides the band up above it (or below it when
--- there is no room above) within [min_top, max_bottom], eased. Overlap is judged against the
--- band's own placement, so a clear banner never drifts back and forth.
function Banner._process(self, delta: number)
	local avoid = self.avoid
	if avoid == nil or self._base_top == nil or self._freed then
		return
	end
	local ok, r = pcall(avoid)
	local want = 0.0
	local area = self.text_area
	if ok and typeof(r) == "Rect" and area ~= nil then
		local ar = area:get_global_rect()
		local m = Banner.MARGIN
		local a0, a1 = ar.Min.Y - self._shift, ar.Max.Y - self._shift
		if r.Max.X > ar.Min.X and r.Min.X < ar.Max.X and r.Max.Y > a0 - m and r.Min.Y < a1 + m then
			local up = (r.Min.Y - m) - a1
			local down = (r.Max.Y + m) - a0
			local min_top = self.min_top or -math.huge
			local max_bottom = self.max_bottom or math.huge
			local up_ok = self._base_top + up >= min_top
			local down_ok = self._base_top + self._height + down <= max_bottom
			if up_ok and (not down_ok or -up <= down) then
				want = up
			elseif down_ok then
				want = down
			else
				want = math.max(up, min_top - self._base_top)
			end
		end
	end
	local sh = self._shift
	if math.abs(want - sh) < 0.25 then
		sh = want
	else
		sh += (want - sh) * math.min(1.0, delta * 12.0)
	end
	if sh == self._shift then
		return
	end
	self._shift = sh
	local d = math.floor(sh + 0.5)
	for _, c in ipairs(self._slide_parts) do
		if c._base_top == nil then
			c._base_top, c._base_bottom = c.offset_top, c.offset_bottom
		end
		c.offset_top = c._base_top + d
		c.offset_bottom = c._base_bottom + d
		c:queue_layout()
	end
end

return Banner
