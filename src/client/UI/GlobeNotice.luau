--!nonstrict
-- Territory-map notice (review_code.md R2-3). The globe draws territory colours with Editable
-- images / meshes; when the device's editable budget is exhausted, or the experience's Mesh / Image
-- APIs permission is off in a published place, it falls back to the static globe (WorldView
-- territory_status().state == "unavailable"). Instead of a silent console warning the player gets
-- this small card: non-blocking (the game keeps running underneath), styled like the Coach tip
-- card, dismissible, hidden again by itself when territories come back. The place owner (Studio, or
-- the account / group that owns the experience) also sees how to enable the APIs.
--
-- API: GlobeNotice.new(ctx), set_status(status), apply_layout(blockers: { Rect }), card (GlassPanel).

local UITheme = require("./UITheme")
local W = require("./Widgets")
local GlassPanel = require("./GlassPanel")
local UICtx = require("./UICtx")

local GlobeNotice = W.class(W.Control)

GlobeNotice.TITLE = "Territory map unavailable"
GlobeNotice.TEXT = {
	memory = "This device is out of graphics memory for territory colours, so nations' land isn't coloured. You can keep playing: the map comes back as soon as memory frees up.",
	disabled = "Territory rendering is unavailable on this server, so nations' land isn't coloured. You can keep playing; everything else works.",
	data = "The globe's map data didn't load, so nations' land isn't coloured. You can keep playing; everything else works.",
}
--- Phones (compact layout): the same, shorter.
GlobeNotice.TEXT_SHORT = {
	memory = "Out of graphics memory for territory colours. Keep playing: the map returns when memory frees up.",
	disabled = "Territory colours can't be drawn on this server. Everything else works.",
	data = "Map data didn't load, so territory colours can't be drawn. Everything else works.",
}
GlobeNotice.OWNER_HINT = {
	disabled = "Owner: enable \u{201C}Mesh / Image APIs\u{201D} for this experience (Game Settings \u{203A} Security).",
	memory = "Owner: other Studio windows share this device's editable memory; close some to test.",
}

local function in_studio(): boolean
	if not UICtx.IS_ROBLOX then
		return false
	end
	local ok, studio = pcall(function()
		return game:GetService("RunService"):IsStudio()
	end)
	return ok and studio == true
end

-- Studio, or the local player owns the experience (user) / holds the owner rank of its group.
local function owner_check(done: (boolean) -> ())
	if not UICtx.IS_ROBLOX then
		done(false)
		return
	end
	if in_studio() then
		done(true)
		return
	end
	task.spawn(function()
		local owner = false
		pcall(function()
			local lp = game:GetService("Players").LocalPlayer
			if game.CreatorType == Enum.CreatorType.User then
				owner = lp ~= nil and lp.UserId == game.CreatorId
			elseif game.CreatorType == Enum.CreatorType.Group then
				owner = lp ~= nil and lp:GetRankInGroup(game.CreatorId) >= 255
			end
		end)
		done(owner)
	end)
end

function GlobeNotice.new(c: any)
	local self = setmetatable({}, GlobeNotice.__mt)
	W.Control._init(self)
	self.ctx = c
	self.status = nil
	self.dismissed_reason = nil
	self.is_owner = false
	self.in_studio = in_studio()
	self:set_mouse_filter(W.MOUSE_IGNORE)
	self:set_anchors_and_offsets_preset(W.PRESET_FULL_RECT)
	local T = UITheme
	local card = GlassPanel.new(14.0, 11.0, T.R_MD, true, 20)
	card:set_accent(T.ORANGE)
	card:set_border(T.c(T.ORANGE, 0.45))
	self.card = card
	local h = T.hbox(12)
	card:add_child(h)
	local disc = W.Panel.new()
	disc:set_mouse_filter(W.MOUSE_IGNORE)
	disc:set_min_size(Vector2.new(34, 34))
	disc.size_flags_vertical = W.SHRINK_BEGIN
	disc:add_theme_stylebox_override("panel", T.flat(T.c(T.ORANGE, 0.16), 17, T.c(T.ORANGE, 0.5), 1))
	local icon = T.icon_rect("globe", 18.0, T.ORANGE)
	icon.size_flags_horizontal = W.SHRINK_CENTER
	icon.size_flags_vertical = W.SHRINK_CENTER
	disc:add_child(icon)
	self._disc = disc
	self._icon = icon
	h:add_child(disc)
	local v = T.vbox(5)
	v.size_flags_horizontal = W.EXPAND_FILL
	self._v = v
	self._cap = T.caption(GlobeNotice.TITLE, 10, T.ORANGE)
	v:add_child(self._cap)
	self._text = T.label("", 13, 500, T.TEXT)
	self._text:set_autowrap(true)
	v:add_child(self._text)
	self._hint = T.label("", 12, 600, T.AMBER_HI)
	self._hint:set_autowrap(true)
	self._hint:set_visible(false)
	v:add_child(self._hint)
	h:add_child(v)
	-- the leaderboard's close button (small margins so the icon fits a compact button)
	local x = W.Button.new("", "GhostButton")
	x:set_icon("close")
	x.expand_icon = true
	x.icon_alignment = W.ALIGN_CENTER
	x:add_theme_constant_override("icon_max_width", 11)
	x:add_theme_stylebox_override("normal", T.empty_box(6, 6))
	x:add_theme_stylebox_override("hover", T.flat(T.FILL, 6, T.CLEAR, 0, 6, 6))
	x:add_theme_stylebox_override("pressed", T.flat(T.FILL, 6, T.CLEAR, 0, 6, 6))
	x:set_min_size(Vector2.new(26, 26))
	x.size_flags_vertical = W.SHRINK_BEGIN
	x.pressed:Connect(function()
		self:dismiss()
	end)
	self._x = x
	h:add_child(x)
	self:add_child(card)
	card:set_visible(false)
	owner_check(function(owner: boolean)
		self.is_owner = owner
		if self.status ~= nil then
			self:_refresh(false)
		end
	end)
	return self
end

--- WorldView.territory_status_changed: show the card while territories can't be drawn.
function GlobeNotice.set_status(self, status: any)
	local was = self.status
	self.status = status
	if status == nil or status.state ~= "unavailable" then
		self.dismissed_reason = nil
		self:_hide()
		return
	end
	-- a different reason after a dismissal is news again
	local fresh = was == nil or was.state ~= "unavailable" or was.reason ~= status.reason
	self:_refresh(fresh)
end

function GlobeNotice.dismiss(self)
	if self.status ~= nil then
		self.dismissed_reason = self.status.reason
	end
	self.ctx:sfx("close", -8.0)
	self:_hide()
end

function GlobeNotice.shown(self): boolean
	return self.card.visible and self.card.modulate_a > 0.01
end

function GlobeNotice._hide(self)
	local card = self.card
	if not card.visible then
		return
	end
	local t = card:create_tween()
	t:tween_property(card, "modulate:a", 0.0, 0.2)
	t:tween_callback(function()
		if self.status == nil or self.status.state ~= "unavailable" or self.dismissed_reason ~= nil then
			card:set_visible(false)
			card:set_modulate_a(1.0)
		end
	end)
end

function GlobeNotice._refresh(self, animate: boolean)
	local st = self.status
	if st == nil or st.state ~= "unavailable" or self.dismissed_reason == st.reason then
		return
	end
	local reason = if GlobeNotice.TEXT[st.reason] then st.reason else "memory"
	local texts = if self.ctx.compact then GlobeNotice.TEXT_SHORT else GlobeNotice.TEXT
	self._text:set_text(texts[reason])
	-- the memory hint is about Studio (windows share the budget); the permission hint is for owners
	local hint = if reason == "memory"
		then (if self.in_studio then GlobeNotice.OWNER_HINT.memory else nil)
		elseif self.is_owner then GlobeNotice.OWNER_HINT[reason]
		else nil
	self._hint:set_text(hint or "")
	self._hint:set_visible(hint ~= nil)
	local was_visible = self.card.visible
	self.card:set_visible(true)
	self.card:set_modulate_a(1.0)
	self:apply_layout(self._blockers)
	if animate or not was_visible then
		UICtx.pop_in(self.card, 0.0, 0.94, 0.35, true)
		self.ctx:sfx("toast", -6.0)
	end
end

--- Top-left, under the top-bar buttons; below any `blockers` (kit nodes that may reach into that
--- corner: the status pill / spawn banner on phones, the title wordmark on the phone title screen).
function GlobeNotice.apply_layout(self, blockers: { any }?)
	self._blockers = blockers
	local ctx = self.ctx
	local c = ctx.compact
	if c ~= self._compact then
		self._compact = c
		if self.card.visible then
			self:_refresh(false)
			return
		end
	end
	local w = if c then 280.0 else 340.0
	local xw = if ctx.touch then 44.0 else 26.0
	local tw = w - 28 - 34 - 12 - 12 - xw
	self._text:set_min_size(Vector2.new(tw, 0))
	self._hint:set_min_size(Vector2.new(tw, 0))
	self._text:set_font_size(if c then 12 else 13)
	self._hint:set_font_size(if c then 11 else 12)
	self._x:set_min_size(Vector2.new(xw, xw))
	local card = self.card
	card:set_min_size(Vector2.new(w, 0))
	card:reset_size()
	local ins = ctx.insets
	local x = 12.0 + ins.x
	local y = math.max(70.0 + ins.y, ctx.reserved_top_left.Max.Y + 10.0)
	local sz = card:get_combined_minimum_size()
	for _, n in ipairs(blockers or {}) do
		if n ~= nil and n:is_visible_in_tree() then
			local b = n:get_global_rect()
			if b.Width > 0 and b.Min.X < x + sz.X and b.Max.X > x and b.Min.Y < y + sz.Y and b.Max.Y > y then
				y = b.Max.Y + 10.0
			end
		end
	end
	card.anchor_left, card.anchor_right, card.anchor_top, card.anchor_bottom = 0, 0, 0, 0
	card.grow_horizontal = W.GROW_END
	card.grow_vertical = W.GROW_END
	card.offset_left = x
	card.offset_right = x
	card.offset_top = y
	card.offset_bottom = y
	card:reset_size()
end

return GlobeNotice
