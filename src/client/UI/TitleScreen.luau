--!nonstrict
-- Port of scripts/ui/title_screen.gd (UITitleScreen)
-- Title screen over the live attract-mode globe: AIRFRONT wordmark, Play Solo with difficulty
-- chips, Multiplayer with live server status, How to Play, credits. Also shows the "joining
-- multiplayer" queue card while a match is being prepared.
--
-- Also defines GradientText (the wordmark / game-over headline): per-glyph Rubik Heavy with letter
-- spacing, the WORD_SHADER vertical gradient, the diagonal shine sweep and the fat drop shadow.
-- Roblox caps TextSize at 100, so glyphs render at a smaller TextSize under a UIScale.

local UITheme = require("./UITheme")
local W = require("./Widgets")
local GlassPanel = require("./GlassPanel")
local UIMaps = require("./UIMaps")
local UICtx = require("./UICtx")
local CrateButton = require("./CrateButton")
local ArsenalButton = require("./ArsenalButton")
local StarterButton = require("./StarterButton")
local ShopButton = require("./ShopButton")
local PartyPanel = require("./PartyPanel")
local Signal = UITheme.core("Signal")

local TitleScreen = W.class(W.Control)

-- =============================================================================================
-- GradientText
-- =============================================================================================

local GradientText = W.class(W.Control)
TitleScreen.GradientText = GradientText
--- The original's desktop top-left reserve for the wordmark (Airship chat panel; ui_layout_probe.gd).
TitleScreen.DESKTOP_WORD_RESERVE = 440.0
--- The wordmark is at most this share of the screen's width: the width the old name had ("ROWORLD",
--- since 2026-10-25, is wider than "ROFRONT" and reached under the Arsenal and crate buttons, top right).
TitleScreen.WORD_MAX_W = 0.35
--- The credits line under the dock (desktop, phones).
TitleScreen.CREDITS = "© OpenFront and Contributors  ·  Maps, flags and unit art from OpenFront (CC BY-SA 4.0)  ·  "
	.. "Music by Rodrigo Flores  ·  GNU AGPL v3, no warranty: see How to play"
TitleScreen.CREDITS_SHORT = "© OpenFront and Contributors  ·  Maps & art: OpenFront (CC BY-SA 4.0)  ·  "
	.. "Music: Rodrigo Flores  ·  GNU AGPL v3"

local SHINE_HALF = 70.0 -- smoothstep(0, 70, |x - sweep - (y - y0) * 0.35|)

function GradientText.new(text: string, px: number, weight: number?)
	local self = setmetatable({}, GradientText.__mt)
	W.Control._init(self)
	self:set_mouse_filter(W.MOUSE_IGNORE)
	self.text = text
	self.px = px
	self.weight = weight or 900
	self.spacing = 0
	self.top_color = Color3.new(1, 1, 1)
	self.bottom_color = Color3.new(1.0, 0.8, 0.52)
	self.y0 = 0.0 -- gradient start (logical px from the top of the line)
	self.span = 100.0
	self.sweep = -10000.0 -- shine centre x (logical px), off by default
	self.shine = 0.4
	self.shadow = { color = Color3.new(0.0, 0.02, 0.08), alpha = 0.55, offset_y = 6, outline = 14 }
	local canvas = UICtx.canvas(self.gui, "Word")
	canvas.ZIndex = 1
	self._canvas = canvas
	local inner = UICtx.frame(canvas)
	inner.Name = "Inner"
	self._inner = inner
	self._inner_scale = UICtx.make("UIScale", { Scale = 1 }, inner)
	self._glyphs = {}
	self._ts = 1
	self:_rebuild()
	return self
end

--- Roblox TextSize used for the glyphs and the extra scale to reach the Godot font size.
function GradientText._sizes(self): (number, number)
	local want = self.px * UITheme.LINE_EM
	local ts = math.clamp(math.floor(want + 0.5), 1, 100)
	return ts, want / ts
end

function GradientText._rebuild(self)
	for _, g in ipairs(self._glyphs) do
		for _, inst in ipairs({ g.shadow, g.text, g.shine, g.shadow_stroke }) do
			self:_drop_part(inst)
		end
		g.shadow:Destroy()
		g.text:Destroy()
		g.shine:Destroy()
	end
	table.clear(self._glyphs)
	local ts = self:_sizes()
	self._ts = ts
	for _, cp in utf8.codes(self.text) do
		local ch = utf8.char(cp)
		local function lab(z: number): TextLabel
			return UICtx.make("TextLabel", {
				BackgroundTransparency = 1,
				Text = ch,
				FontFace = UITheme.font(self.weight),
				TextSize = ts,
				TextColor3 = Color3.new(1, 1, 1),
				TextXAlignment = Enum.TextXAlignment.Left,
				TextYAlignment = Enum.TextYAlignment.Top,
				ZIndex = z,
			}, self._inner)
		end
		local g = { ch = ch, shadow = lab(1), text = lab(2), shine = lab(3) }
		local sst = UICtx.make("UIStroke", { Thickness = 1, LineJoinMode = Enum.LineJoinMode.Round }, g.shadow)
		g.shadow_stroke = sst
		-- Register as parts so the node's modulate (fades) reaches them.
		self:_part(g.text, "TextTransparency", 1.0)
		self:_part(g.shine, "TextTransparency", 1.0)
		self:_part(g.shadow, "TextTransparency", self.shadow.alpha)
		self:_part(sst, "Transparency", self.shadow.alpha)
		g.grad = UICtx.make("UIGradient", { Rotation = 90 }, g.text)
		g.shine_grad = UICtx.make("UIGradient", {}, g.shine)
		table.insert(self._glyphs, g)
	end
	self:update_minimum_size()
	self:_redraw()
end

function GradientText.set_text(self, t: string)
	if t == self.text then
		return
	end
	self.text = t
	self:_rebuild()
end

function GradientText.set_px(self, px: number)
	if px == self.px then
		return
	end
	self.px = px
	local ts = self:_sizes()
	if ts ~= self._ts then
		self:_rebuild()
	else
		self:update_minimum_size()
		self:_redraw()
	end
end

function GradientText.set_colors(self, top: Color3, bottom: Color3)
	self.top_color = top
	self.bottom_color = bottom
	self:_redraw()
end

--- Glyph pen positions in logical px (kerning of the whole string, + spacing after each glyph).
function GradientText._pens(self): ({ number }, number)
	local ts, k = self:_sizes()
	local xs = {}
	local prefix = ""
	local n = 0
	for _, cp in utf8.codes(self.text) do
		n += 1
		table.insert(xs, UITheme.measure_px(prefix, ts, self.weight) * k + (n - 1) * self.spacing)
		prefix ..= utf8.char(cp)
	end
	local total = UITheme.measure_px(self.text, ts, self.weight) * k + n * self.spacing
	return xs, total
end

function GradientText._get_minimum_size(self): Vector2
	local _, total = self:_pens()
	return Vector2.new(math.ceil(total), self.px * UITheme.LINE_EM)
end

function GradientText._on_geometry(self)
	self:_redraw()
end

function GradientText._restyle(self)
	self:_redraw()
end

local function clamp01(x: number): number
	return math.clamp(x, 0, 1)
end

function GradientText._redraw(self)
	local canvas = self._canvas
	canvas.Size = UDim2.fromOffset(self.size.X, self.size.Y);
	(canvas:FindFirstChild("Scale") :: UIScale).Scale = UITheme.scale
	local ts, k = self:_sizes()
	self._inner_scale.Scale = k
	local line_h = self.px * UITheme.LINE_EM
	local xs, total = self:_pens()
	-- Centre the word horizontally in the node (Label HORIZONTAL_ALIGNMENT_CENTER).
	local x0 = math.floor((self.size.X - total) * 0.5 + 0.5)
	-- Vertical gradient from y0 to y0 + span (WORD_SHADER): keypoints in the glyph's own [0, 1].
	local a = clamp01(self.y0 / line_h)
	local b = clamp01((self.y0 + self.span) / line_h)
	if b <= a then
		b = math.min(1, a + 0.001)
	end
	local cseq = ColorSequence.new({
		ColorSequenceKeypoint.new(0, self.top_color),
		ColorSequenceKeypoint.new(a, self.top_color),
		ColorSequenceKeypoint.new(b, self.bottom_color),
		ColorSequenceKeypoint.new(1, self.bottom_color),
	})
	local sh = self.shadow
	for i, g in ipairs(self._glyphs) do
		local gx = x0 + xs[i]
		local next_x = if i < #self._glyphs then x0 + xs[i + 1] - self.spacing else x0 + total - self.spacing
		local gw = math.max(1, next_x - gx)
		-- Inner units: logical / k.
		local ix, iw, ih = gx / k, gw / k + ts * 0.3, ts
		for _, lab in ipairs({ g.text, g.shadow, g.shine }) do
			lab.Position = UDim2.fromOffset(ix, 0)
			lab.Size = UDim2.fromOffset(iw, ih)
		end
		g.grad.Color = cseq
		-- Shadow: offset down, expanded by an outline (Godot shadow_outline_size).
		g.shadow.Position = UDim2.fromOffset(ix, sh.offset_y / k)
		g.shadow.TextColor3 = sh.color
		self:_part(g.shadow, "TextTransparency", sh.alpha)
		g.shadow_stroke.Color = sh.color
		g.shadow_stroke.Thickness = math.max(0, sh.outline * 0.5 / k)
		self:_part(g.shadow_stroke, "Transparency", sh.alpha)
		-- Shine band: + shine * (1 - smoothstep(0, 70, |x - sweep - (y - y0) * 0.35|)), drawn as a
		-- white copy whose transparency gradient is that band in this glyph's box (rotated by the
		-- 0.35 shear converted to the box's aspect).
		local rel = self.sweep - gx -- band centre at the glyph's y0 row, in glyph logical px
		if rel < -SHINE_HALF - gw - line_h or rel > gw + SHINE_HALF + line_h then
			g.shine.Visible = false
		else
			g.shine.Visible = true
			local W_px, H_px = iw * k, ih * k
			-- isolines x - 0.35 y = c  ->  gradient axis along (1, -0.35) in px; in UV space the
			-- direction becomes (1 / W, -0.35 / H) scaled by the box: angle = atan2(-0.35 H, W)...
			local ang = math.deg(math.atan2(-0.35 * H_px, W_px))
			g.shine_grad.Rotation = ang
			-- Distance along the gradient axis per unit t: project the box onto the axis.
			local c, s = math.cos(math.rad(ang)), math.sin(math.rad(ang))
			local L = math.abs(W_px * c) + math.abs(H_px * s) -- px spanned by t = 0..1
			local half_t = SHINE_HALF / math.max(L, 1) * math.sqrt(1 + 0.35 * 0.35)
			-- centre of the band: pixel (rel + y0*0.35 ... ) -> t of the band line through (rel, y0)
			local px_c = rel + 0.35 * self.y0
			local tc = 0.5 + ((px_c - W_px * 0.5) * c + (0 - H_px * 0.5) * s) / L
			local pts = {}
			local function kp(t: number, v: number)
				if t > 0.0005 and t < 0.9995 then
					table.insert(pts, NumberSequenceKeypoint.new(t, v))
				end
			end
			table.insert(pts, NumberSequenceKeypoint.new(0, 1))
			for j = -4, 4 do
				local d = j / 4 -- -1..1 of the half width
				local sm = 1
					- (function(x)
						local u = clamp01(x)
						return u * u * (3 - 2 * u)
					end)(math.abs(d))
				kp(tc + d * half_t, 1 - self.shine * sm)
			end
			table.insert(pts, NumberSequenceKeypoint.new(1, 1))
			table.sort(pts, function(p, q)
				return p.Time < q.Time
			end)
			-- NumberSequence needs strictly increasing times.
			local clean = {}
			local last = -1
			for _, p in ipairs(pts) do
				if p.Time > last + 1e-4 then
					table.insert(clean, p)
					last = p.Time
				end
			end
			if clean[#clean].Time < 1 then
				table.insert(clean, NumberSequenceKeypoint.new(1, 1))
			end
			g.shine_grad.Transparency = NumberSequence.new(clean)
		end
	end
end

-- =============================================================================================
-- Title screen
-- =============================================================================================

--- A lobby card goes when its countdown here reaches this (the server closes joins at
--- LobbyRules.JOIN_CLOSE_S = 6 s; the card's whole seconds round up).
TitleScreen.JOIN_CLOSE_S = 5
TitleScreen.DIFFS = { [0] = "Relaxed", "Standard", "Brutal" }
TitleScreen.DIFF_BLURB = {
	[0] = "Gentle AI: slower growth and a long early peace.",
	"A fair fight: nations respect a short early peace.",
	"Aggressive AI that grows fast and hunts you early.",
}

local INK = Color3.new(0.01, 0.015, 0.05)

--- Full-rect image node (radial gradient textures), alpha follows modulate.
local function image_node(image: string, color: Color3?, alpha: number?)
	local g = Instance.new("ImageLabel")
	g.BackgroundTransparency = 1
	g.BorderSizePixel = 0
	g.ScaleType = Enum.ScaleType.Stretch
	g.Image = image or ""
	g.ImageColor3 = color or Color3.new(1, 1, 1)
	local n = W.wrap(g)
	n:set_mouse_filter(W.MOUSE_IGNORE)
	n:_part(g, "ImageTransparency", alpha or 1.0)
	return n
end

--- Full-rect vertical gradient node: colour c, alpha keypoints {t, a}.
local function vgrad_node(c: Color3, keys: { { number } })
	local g = Instance.new("Frame")
	g.BorderSizePixel = 0
	g.BackgroundColor3 = c
	local seq = {}
	for _, kpt in ipairs(keys) do
		table.insert(seq, NumberSequenceKeypoint.new(kpt[1], 1 - kpt[2]))
	end
	UICtx.make("UIGradient", { Rotation = 90, Transparency = NumberSequence.new(seq) }, g)
	local n = W.wrap(g)
	n:set_mouse_filter(W.MOUSE_IGNORE)
	n:_part(g, "BackgroundTransparency", 1.0)
	return n
end

--- Horizontal amber hairline fading to one side (tag lines).
local function tag_line(flip: boolean)
	local g = Instance.new("Frame")
	g.BorderSizePixel = 0
	g.BackgroundColor3 = UITheme.AMBER
	local seq = if flip
		then NumberSequence.new({ NumberSequenceKeypoint.new(0, 1 - 0.85), NumberSequenceKeypoint.new(1, 1) })
		else NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, 1 - 0.85) })
	UICtx.make("UIGradient", { Transparency = seq }, g)
	local n = W.wrap(g)
	n:set_mouse_filter(W.MOUSE_IGNORE)
	n:_part(g, "BackgroundTransparency", 1.0)
	n:set_min_size(Vector2.new(72, 2))
	n.size_flags_vertical = W.SHRINK_CENTER
	return n
end

function TitleScreen.new(c: any)
	local self = setmetatable({}, TitleScreen.__mt)
	W.Control._init(self)
	self.ctx = c
	self.play_solo = Signal.new()
	--- the map button: UIRoot opens the map picker
	self.pick_map = Signal.new()
	self.play_multi = Signal.new()
	self.show_help = Signal.new()
	self.leave_queue = Signal.new()
	--- the waiting room's vote-to-start toggle
	self.vote_start = Signal.new()
	--- (lobby_id) a public lobby card was clicked
	self.join_lobby = Signal.new()
	--- (mode) Quick Play: a seat in the soonest public match of that kind ("ffa" | "team")
	self.join_public = Signal.new()
	--- Quick Play: leave the line
	self.leave_line = Signal.new()
	--- the crate button (top right): UIRoot opens the Locker
	self.open_locker = Signal.new()
	self.open_arsenal = Signal.new()
	--- the starter pack's button (under the pair, while its offer runs): UIRoot opens the offer
	self.open_starter = Signal.new()
	self.open_shop = Signal.new()
	--- (action, user_id?) the party panel (Session.party_action)
	self.party_action = Signal.new()
	self.difficulty =
		math.clamp(tonumber(c:setting("difficulty", UICtx.DEFAULT_DIFFICULTY)) or UICtx.DEFAULT_DIFFICULTY, 0, 2)
	self._dock_compact = -1
	self._sweep_t = -1.0
	self._lobby = {}
	self._lobby_msec = 0
	self._lobbies = nil :: { any }?
	self._lobbies_msec = 0
	self._joining = nil :: string?
	self._joining_msec = 0
	--- the kinds of public match the hub offers (nil: not said yet)
	self._kinds = nil :: { string }?
	--- Quick Play (Session.public): asking / in line / on the way, and since when (UICtx.msec)
	self._public = { state = "idle" } :: { [string]: any }
	self._public_msec = 0
	self._public_since = 0
	self._accum = 0.0
	self._dot_t = 0.0
	self._tick_sec = -1
	self._hide_tween = nil
	self._chips = {}
	self:set_mouse_filter(W.MOUSE_IGNORE)
	self:set_anchors_and_offsets_preset(W.PRESET_FULL_RECT)
	self:_build_backdrop()
	self:_build_head()
	self:_build_dock()
	self:_build_queue()
	self:_build_solo_menu()
	-- credits: the copyright notice the code's licence asks to keep visible, the CC BY-SA art and
	-- maps, Rodrigo Flores' soundtrack (Orchestral Ambients) and the licence (2026-10-25: the full
	-- notices are in How to play, HelpOverlay.LEGAL); phones get the short line (apply_layout)
	self._credits = UITheme.label(
		TitleScreen.CREDITS,
		11,
		500,
		UITheme.c(UITheme.TEXT_3, 0.85),
		1
	)
	self._credits:set_alignment(W.ALIGN_CENTER)
	self:add_child(self._credits)
	-- cosmetic crates: a big animated chest top right (the top bar's small icon was easy to miss)
	self._crate_btn = CrateButton.new(c)
	self._crate_btn.pressed:Connect(function()
		self.open_locker:Fire()
	end)
	self:add_child(self._crate_btn)
	-- its twin, beside it: the Arsenal (Data/Arsenal) and the player's Stars
	self._arsenal_btn = ArsenalButton.new(c)
	self._arsenal_btn.pressed:Connect(function()
		self.open_arsenal:Fire()
	end)
	self:add_child(self._arsenal_btn)
	-- under them, the flag shop (Data/Shop; shown while it sells something here)
	self._shop_btn = ShopButton.new(c)
	self._shop_btn.pressed:Connect(function()
		self.open_shop:Fire()
	end)
	self:add_child(self._shop_btn)
	-- under those, while the starter pack's offer runs (Data/Starter)
	self._starter_btn = StarterButton.new(c)
	self._starter_btn.pressed:Connect(function()
		self.open_starter:Fire()
	end)
	self:add_child(self._starter_btn)
	-- the party (team games on: staging only for now; hidden until the server sends one)
	self._party = PartyPanel.new(c)
	self._party.on_action = function(action: string, uid: number?)
		self.party_action:Fire(action, uid)
	end
	self:add_child(self._party)
	--- in a party, and whether this player leads it (only the leader picks a public match)
	self._in_party = false
	self._party_leader = true
	self:set_process(true)
	return self
end

--- The player's party (server/Party.state), or nil (parties are off).
function TitleScreen.set_party(self, st: any)
	self._party:set_state(st)
	local n = if type(st) == "table" and type(st.members) == "table" then #st.members else 0
	self._in_party = n >= 2
	self._party_leader = not self._in_party or st.leader == true
	self:_refresh_mp()
end

function TitleScreen._build_backdrop(self)
	local S = UICtx.shapes()
	self._vignette = image_node(S.title_vignette, INK, 1.0)
	self._vignette:set_anchors_and_offsets_preset(W.PRESET_FULL_RECT)
	self:add_child(self._vignette)
	self._bottom_shade = vgrad_node(INK, { { 0, 0.0 }, { 1, 0.8 } })
	self._bottom_shade:set_anchors(0, 0.5, 1, 1)
	self:add_child(self._bottom_shade)
	self._top_shade = vgrad_node(Color3.new(0.005, 0.01, 0.035), { { 0, 0.92 }, { 0.55, 0.6 }, { 1, 0.0 } })
	self._top_shade:set_anchors(0, 0, 1, 0.5)
	self:add_child(self._top_shade)
	self._fade = W.ColorRect.new(UITheme.rgba(0.005, 0.008, 0.03, 0.72))
	self._fade:set_mouse_filter(W.MOUSE_IGNORE)
	self._fade:set_anchors_and_offsets_preset(W.PRESET_FULL_RECT)
	self._fade:set_modulate_a(0.0)
	self:add_child(self._fade)
end

function TitleScreen._build_head(self)
	local S = UICtx.shapes()
	self._head = UITheme.vbox(0)
	self._head:set_alignment(W.ALIGN_CENTER)
	self:add_child(self._head)
	self._emblem = UITheme.icon_rect("app_icon", 64.0, Color3.new(1, 1, 1))
	self._emblem.size_flags_horizontal = W.SHRINK_CENTER
	self._head:add_child(self._emblem)
	-- Warm glow behind the wordmark (placed after the shades, before the fade).
	self._glow = image_node(S.title_glow, Color3.new(1, 1, 1), 1.0)
	self:add_child(self._glow)
	self:move_child(self._glow, 3)

	local word = GradientText.new("ROWORLD", 120, 900)
	word.spacing = 14
	word.shadow = { color = Color3.new(0.0, 0.02, 0.08), alpha = 0.55, offset_y = 6, outline = 14 }
	word:set_colors(Color3.new(1, 1, 1), Color3.new(1.0, 0.8, 0.52))
	word.size_flags_horizontal = W.SHRINK_CENTER
	self._word = word
	self._head:add_child(word)

	self._tag_row = UITheme.hbox(16)
	self._tag_row:set_alignment(W.ALIGN_CENTER)
	self._tag_l = tag_line(false)
	self._tag_r = tag_line(true)
	self._tag = UITheme.label("CONQUER THE REAL WORLD", 15, 600, Color3.new(0.86, 0.89, 0.97), 6)
	self._tag_row:add_child(self._tag_l)
	self._tag_row:add_child(self._tag)
	self._tag_row:add_child(self._tag_r)
	self._head:add_child(self._tag_row)
end

function TitleScreen._build_dock(self)
	local ctx = self.ctx
	self._dock = GlassPanel.new(20.0, 18.0, 18, true, 28)
	self:add_child(self._dock)
	local v = UITheme.vbox(12)
	self._dock_v = v
	self._dock:add_child(v)
	self._greet = UITheme.label("", 13, 500, UITheme.TEXT_2)
	self._greet:set_alignment(W.ALIGN_CENTER)

	self._solo = UITheme.button("PLAY SOLO", "PrimaryButton", "play", 58.0)
	self._solo:add_theme_constant_override("icon_max_width", 18)
	self._solo:set_font_size(19)
	self._solo.pressed:Connect(function()
		self:open_solo_menu()
	end)

	-- the solo map (from the map list; UIRoot.set_map_name keeps the label current)
	local mb = UITheme.button("", "GlassButton", "globe", 42.0)
	mb.alignment = W.ALIGN_LEFT
	mb:set_font_size(14)
	mb.pressed:Connect(function()
		self.pick_map:Fire()
	end)
	self._map_btn = mb
	self:set_map_name("World")

	local dr = UITheme.hbox(8)
	self._diff_row = dr
	self._diff_caption = UITheme.caption("Difficulty")
	self._diff_caption.size_flags_vertical = W.SHRINK_CENTER
	self._diff_caption:set_min_size(Vector2.new(84, 0))
	dr:add_child(self._diff_caption)
	for i = 0, 2 do
		local chip = UITheme.button(TitleScreen.DIFFS[i], "ChipButton", "", 34.0)
		chip.toggle_mode = true
		chip.size_flags_horizontal = W.EXPAND_FILL
		chip:set_pressed_no_signal(i == self.difficulty)
		chip.pressed:Connect(function()
			-- ButtonGroup: exactly one chip stays pressed.
			self.difficulty = i
			for j, ch in ipairs(self._chips) do
				ch:set_pressed_no_signal(j - 1 == i)
			end
			ctx:set_setting("difficulty", i)
			self:_refresh_diff()
		end)
		table.insert(self._chips, chip)
		dr:add_child(chip)
	end
	self._diff_desc = UITheme.label("", 12, 500, UITheme.TEXT_2)
	self._diff_desc:set_alignment(W.ALIGN_CENTER)
	self._diff_desc:set_autowrap(true)
	self._diff_desc:set_min_size(Vector2.new(360, 0))
	self:_refresh_diff()
	-- desktop: "PUBLIC MATCHES" between two rules, above the lobby cards
	local sec = UITheme.hbox(10)
	local l1 = UITheme.hdivider()
	l1.size_flags_horizontal = W.EXPAND_FILL
	l1.size_flags_vertical = W.SHRINK_CENTER
	sec:add_child(l1)
	local cap = UITheme.caption("Public matches", 11, UITheme.CYAN)
	cap.size_flags_vertical = W.SHRINK_CENTER
	sec:add_child(cap)
	local l2 = UITheme.hdivider()
	l2.size_flags_horizontal = W.EXPAND_FILL
	l2.size_flags_vertical = W.SHRINK_CENTER
	sec:add_child(l2)
	self._dock_div = sec

	local row = UITheme.hbox(10)
	self._mp_row = row
	-- public-match cards (Quick Play): one per kind; before the list arrives the first card shows the
	-- server status.
	-- (three cards, one per kind of public match, 2026-10-19: the world map is always open; and the
	-- title screen's spectating was no longer needed, so the live match card, its eye button and
	-- WATCH LIVE went)
	local c1 = self:_lobby_card(1)
	self._cards = { c1, self:_lobby_card(2), self:_lobby_card(3) }
	local mp = c1.btn
	self._mp = mp
	self._mp_title = c1.title
	self._mp_dot = c1.dot
	self._mp_status = c1.status
	self._mp_join = c1.pill
	self._mp_join_l = c1.pill_l
	self._mp_content = c1.content
	self._mp2 = self._cards[2].btn
	--- phones: the two next public matches, one above the other, between PLAY SOLO and the buttons
	self._mp_col = UITheme.vbox(6)
	self._mp3 = self._cards[3].btn
	self._mp3:set_visible(false)
	row:add_child(mp)

	self._help = UITheme.button("HOW TO PLAY", "GlassButton", "help", 62.0)
	self._help:set_font_size(13)
	self._help.pressed:Connect(function()
		self.show_help:Fire()
	end)
	row:add_child(self._help)
	-- The dock children are placed by _reflow_dock.
	self._dock_nodes = {
		self._greet,
		self._solo,
		self._dock_div,
		self._mp_row,
		self._mp,
		self._mp2,
		self._mp3,
		self._help,
		self._mp_col,
	}
end

--- The solo map's name on the map button.
function TitleScreen.set_map_name(self, name: string)
	self._map_btn:set_text("Map:  " .. name)
end

--- One public-match card: map thumbnail, title, status line with a dot, and a JOIN pill.
function TitleScreen._lobby_card(self, index: number): { [string]: any }
	local btn = W.Button.new("", if index == 1 then "PublicButton" else "GlassButton")
	btn:set_min_size(Vector2.new(0, 62))
	btn.size_flags_horizontal = W.EXPAND_FILL
	local card: { [string]: any } = { btn = btn, lobby = nil }
	btn.pressed:Connect(function()
		if card.mode ~= nil then
			-- Quick Play: the kind of match, not a lobby (the hub seats us in the soonest with room)
			local pub = self._public
			if pub.state == "line" and pub.mode == card.mode then
				self.leave_line:Fire()
			elseif pub.state == "idle" and self._joining == nil then
				self:set_public({ state = "joining", mode = card.mode })
				self.join_public:Fire(card.mode)
			end
		elseif index == 1 then
			self.play_multi:Fire()
		end
	end)
	local mm = W.Margin.new()
	mm:set_mouse_filter(W.MOUSE_IGNORE)
	mm:set_anchors_and_offsets_preset(W.PRESET_FULL_RECT)
	mm:add_theme_constant_override("margin_left", 10)
	mm:add_theme_constant_override("margin_right", 12)
	btn:add_child(mm)
	local mh = UITheme.hbox(12)
	mm:add_child(mh)
	-- map thumbnail (a raw ImageLabel in a sized kit node; the users icon until a map is known)
	local th = W.Control.new()
	th:set_min_size(Vector2.new(58, 40))
	th:set_mouse_filter(W.MOUSE_IGNORE)
	th.size_flags_vertical = W.SHRINK_CENTER
	local img = Instance.new("ImageLabel")
	img.Name = "Thumb"
	img.BackgroundTransparency = 1
	img.ScaleType = Enum.ScaleType.Fit
	img.Size = UDim2.fromScale(1, 1)
	img.ZIndex = 20
	img.Parent = th.gui
	-- a registered part follows the title's fades (a raw image showed before its card did)
	th:_part(img, "ImageTransparency", 1.0)
	card.thumb = img
	th:set_visible(false)
	mh:add_child(th)
	local uic = UITheme.icon_rect("users", 22.0, UITheme.CYAN)
	uic.size_flags_vertical = W.SHRINK_CENTER
	card.icon = uic
	card.thumb_node = th
	mh:add_child(uic)
	local mv = UITheme.vbox(1)
	mv.size_flags_vertical = W.SHRINK_CENTER
	mv.size_flags_horizontal = W.EXPAND_FILL
	card.title = UITheme.label("PUBLIC MATCH", 15, 800, UITheme.TEXT, 2)
	card.title.text_overrun_behavior = W.OVERRUN_ELLIPSIS
	card.title.clip_text = true
	mv:add_child(card.title)
	local sr = UITheme.hbox(6)
	card.dot = W.Panel.new()
	card.dot:set_min_size(Vector2.new(7, 7))
	card.dot.size_flags_vertical = W.SHRINK_CENTER
	card.dot:set_mouse_filter(W.MOUSE_IGNORE)
	card.dot:add_theme_stylebox_override("panel", UITheme.flat(UITheme.TEXT_3, 4))
	sr:add_child(card.dot)
	card.status = UITheme.label("Connecting…", 12, 500, UITheme.TEXT_2)
	card.status.text_overrun_behavior = W.OVERRUN_ELLIPSIS
	card.status.clip_text = true
	card.status.size_flags_horizontal = W.EXPAND_FILL
	card.status:set_min_size(Vector2.new(60, 0))
	sr:add_child(card.status)
	mv:add_child(sr)
	mh:add_child(mv)
	card.pill = W.Panel.new()
	card.pill:set_mouse_filter(W.MOUSE_IGNORE)
	card.pill.size_flags_vertical = W.SHRINK_CENTER
	card.pill:add_theme_stylebox_override(
		"panel",
		UITheme.flat(UITheme.c(UITheme.CYAN, 0.16), 999, UITheme.c(UITheme.CYAN, 0.55), 1, 10.0, 3.0)
	)
	card.pill_l = UITheme.label("JOIN", 11, 800, UITheme.CYAN, 1)
	card.pill:add_child(card.pill_l)
	mh:add_child(card.pill)
	card.content = mh
	return card
end

--- The game-wide public lobbies ({id, map, map_name, max, players, starts_in, joinable}, soonest
--- first) from the hub server, and the kinds of public match it offers (Quick Play).
function TitleScreen.set_lobbies(self, list: { any }?, kinds: { string }?)
	self._lobbies = list
	self._lobbies_msec = UICtx.msec()
	if kinds ~= nil then
		self._kinds = kinds
	end
	if self._joining ~= nil and UICtx.msec() - (self._joining_msec or 0) > 20000 then
		self._joining = nil -- the teleport never happened (a notice explains why)
	end
	-- asking, or seated and on the way, with no word for 20 s: the teleport never happened
	local st = self._public.state
	if (st == "joining" or st == "going") and UICtx.msec() - self._public_msec > 20000 then
		self._public = { state = "idle" }
	end
	self:_refresh_mp()
end

--- Quick Play's state from the hub (Session.public): { state = "joining" | "line" | "going" |
--- "idle", mode, info = { map, map_name }? }.
function TitleScreen.set_public(self, st: { [string]: any })
	local prev = self._public.state
	self._public = table.clone(st)
	if st.state ~= prev then
		self._public_msec = UICtx.msec()
		if prev == "idle" then
			self._public_since = UICtx.msec()
		end
	end
	self:_refresh_mp()
end

--- True while asking for, waiting for, or on the way to a public match.
function TitleScreen.public_busy(self): boolean
	return self._public.state ~= "idle"
end

--- A join attempt ended without a teleport (the server said why).
function TitleScreen.join_failed(self)
	self._joining = nil
	if self._public.state == "joining" then
		self._public = { state = "idle" }
	end
	self:_refresh_mp()
end

function TitleScreen._build_queue(self)
	self._queue = GlassPanel.new(26.0, 22.0, 18, true, 28)
	self:add_child(self._queue)
	local v = UITheme.vbox(10)
	self._queue:add_child(v)
	local h = UITheme.hbox(12)
	local uic = UITheme.icon_rect("users", 26.0, UITheme.CYAN)
	uic.size_flags_vertical = W.SHRINK_CENTER
	h:add_child(uic)
	self._q_title = UITheme.label("JOINING MULTIPLAYER", 18, 800, UITheme.TEXT, 2)
	self._q_title.size_flags_vertical = W.SHRINK_CENTER
	h:add_child(self._q_title)
	v:add_child(h)
	self._q_status = UITheme.label("Contacting the server…", 14, 600, UITheme.AMBER)
	v:add_child(self._q_status)
	self._q_players = UITheme.label("", 12, 500, UITheme.TEXT_2)
	self._q_players:set_autowrap(true)
	self._q_players:set_min_size(Vector2.new(340, 0))
	v:add_child(self._q_players)
	local vote = UITheme.button("Vote to start", "PrimaryButton", "play", 44.0)
	self._q_vote = vote
	vote.pressed:Connect(function()
		self.vote_start:Fire()
	end)
	vote:set_visible(false)
	v:add_child(vote)
	local leave = UITheme.button("Leave queue", "GlassButton", "exit", 44.0)
	self._q_leave = leave
	leave.pressed:Connect(function()
		self.leave_queue:Fire()
	end)
	v:add_child(leave)
	self._queue:set_visible(false)
end

-- ---------------------------------------------------------------------------------------------
-- Layout & state
-- ---------------------------------------------------------------------------------------------

function TitleScreen.apply_layout(self)
	local ctx = self.ctx
	local vp = ctx.vp
	local compact = ctx.compact
	local word_px = math.clamp(math.min(vp.X * 0.078, vp.Y * 0.15), 44.0, 132.0)
	self:_size_word(word_px)
	local w_cap = vp.X * TitleScreen.WORD_MAX_W
	local w_now = self._word:get_combined_minimum_size().X
	if w_now > w_cap then
		word_px = math.max(44.0, word_px * w_cap / w_now)
		self:_size_word(word_px)
	end
	-- Keep the wordmark clear of the reserved top-left HUD: shrink it while it can stay centred,
	-- otherwise move the whole composition into the free column on the right.
	local col_x = vp.X * 0.5
	if not compact then
		local min_left = ctx.reserved_top_left.Max.X + 16.0
		-- The original's desktop always reserved Airship's chat panel (airship_reserved: 440 px wide,
		-- the desktop app opens it by default), so its wordmark was fitted to 1600 - 2 x 456 px at
		-- 1600x900. Roblox's collapsed chat reserves only the top-bar row, which left the word 11.7 %
		-- larger (review_visual P1-8). Keep the original's desktop proportions for the word's size;
		-- the real reserve still decides when the composition must move aside.
		local fitted = false
		if not ctx.touch then
			local want_left = math.max(min_left, TitleScreen.DESKTOP_WORD_RESERVE + 16.0)
			local w0 = self._word:get_combined_minimum_size().X
			if col_x - w0 * 0.5 < want_left then
				local fit_px = word_px * (vp.X - 2.0 * want_left) / math.max(w0, 1.0)
				if fit_px >= 88.0 then
					word_px = fit_px
					self:_size_word(word_px)
					fitted = true
				end
			end
		end
		local w = self._word:get_combined_minimum_size().X
		if not fitted and col_x - w * 0.5 < min_left then
			local fit_px = word_px * (vp.X - 2.0 * min_left) / math.max(w, 1.0)
			if fit_px >= 88.0 then
				word_px = fit_px
			else
				col_x = (min_left + vp.X - 24.0) * 0.5
				word_px = math.min(word_px, word_px * (vp.X - 24.0 - min_left) / math.max(w, 1.0))
			end
			self:_size_word(word_px)
		end
	end
	local dx = col_x - vp.X * 0.5
	local emblem_px = if compact then 0.0 else math.clamp(word_px * 0.56, 44.0, 76.0)
	self._emblem:set_visible(emblem_px > 0.0)
	self._emblem:set_min_size(Vector2.new(emblem_px, emblem_px))
	self._tag:set_font_size(if compact then 11 else 15)
	self._tag_l:set_min_size(Vector2.new(if compact then 40 else 72, 2))
	self._tag_r:set_min_size(self._tag_l.custom_minimum_size)
	local head_top = (if compact then 56.0 else math.max(vp.Y * 0.07, 40.0)) + ctx.insets.y
	if compact then
		-- Phones: keep the wordmark centred, below the top bar row when they would touch.
		local ww = self._word:get_combined_minimum_size().X
		if (vp.X - ww) * 0.5 < ctx.reserved_top_left.Max.X + 8.0 then
			head_top = math.max(head_top, ctx.reserved_top_left.Max.Y + 2.0)
		end
	end
	local head = self._head
	head.anchor_left, head.anchor_right, head.anchor_top, head.anchor_bottom = 0.5, 0.5, 0.0, 0.0
	head.grow_horizontal = W.GROW_BOTH
	head.grow_vertical = W.GROW_END
	head.offset_left, head.offset_right = dx, dx
	head.offset_top, head.offset_bottom = head_top, head_top
	head:reset_size()
	local wsize = self._word:get_combined_minimum_size()
	self._word.y0 = wsize.Y * 0.18
	self._word.span = wsize.Y * 0.66
	self._word:_redraw()
	-- Warm glow behind the wordmark.
	local gw = wsize.X * 1.5
	local gh = wsize.Y * 2.4
	local gy = head_top + emblem_px + wsize.Y * 0.5 - gh * 0.5
	self._glow:set_offsets(col_x - gw * 0.5, gy, col_x + gw * 0.5, gy + gh)

	self:_reflow_dock(compact)
	self._diff_caption:set_visible(not compact)
	local dock_w = if not compact then 560.0 else math.min(760.0, vp.X - ctx.insets.x - ctx.insets.z - 16.0)
	self._dock:set_min_size(Vector2.new(dock_w, 0))
	if compact then
		self._dock:set_padding(10.0, 8.0, 10.0, 8.0)
	else
		self._dock:set_padding(20.0, 18.0, 20.0, 18.0)
	end
	local pv = if compact then self:_phone_dock() else ""
	local grid = pv == "grid" or pv == "grid2"
	self._solo:set_min_size(
		Vector2.new(if compact and not grid then 150 else 0, if grid then 44 elseif compact then 52 else 50)
	)
	self._solo:set_font_size(if compact then 15 else 17)
	self._solo_panel:set_min_size(Vector2.new(dock_w, 0))
	if compact then
		self._solo_panel:set_padding(12.0, 10.0, 12.0, 10.0)
		self._solo_v:set_separation(8)
	else
		self._solo_panel:set_padding(20.0, 18.0, 20.0, 18.0)
		self._solo_v:set_separation(12)
	end
	self._start:set_min_size(Vector2.new(0, if compact then 48 else 58))
	self._start:set_font_size(if compact then 16 else 19)
	self._mp:set_min_size(
		Vector2.new(
			if compact and pv ~= "stack"
				then 0
				else math.max(if compact then 250.0 else 0.0, self._mp_content:get_combined_minimum_size().X + 28.0),
			if compact then 52 else 62
		)
	)
	self._mp2:set_min_size(Vector2.new(0, if compact then 52 else 62))
	self._mp3:set_min_size(Vector2.new(0, if compact then 52 else 62))
	-- icon-only everywhere: the lobby card beside it needs the width for its status line
	self._help:set_min_size(Vector2.new(if compact then 56 else 62, if compact then 56 else 62))
	self._help:set_text("")
	self._help.icon_alignment = W.ALIGN_CENTER
	for _, ch in ipairs(self._chips) do
		ch:set_min_size(Vector2.new(if compact then 64 else 0, if ctx.touch then 44 else 34))
		ch:set_font_size(if compact then 12 else 13)
	end
	self._diff_desc:set_font_size(if compact then 11 else 12)
	self._diff_desc:set_min_size(Vector2.new(if compact then 0 else 360, 0))
	self._diff_desc:set_autowrap(not compact)
	self._greet:set_visible(not compact)
	-- (phones: room under the dock for the credits line)
	local bottom = (if not compact then 40.0 else 20.0) + ctx.insets.w
	for _, cn in ipairs({ self._dock, self._queue, self._solo_panel }) do
		cn.anchor_left, cn.anchor_right, cn.anchor_top, cn.anchor_bottom = 0.5, 0.5, 1.0, 1.0
		cn.grow_horizontal = W.GROW_BOTH
		cn.grow_vertical = W.GROW_BEGIN
		cn.offset_left, cn.offset_right = dx, dx
		cn.offset_top, cn.offset_bottom = -bottom, -bottom
		cn:reset_size()
	end
	-- phones too: a line under the dock
	self._credits:set_visible(true)
	self._credits:set_text(if compact then TitleScreen.CREDITS_SHORT else TitleScreen.CREDITS)
	self._credits:set_font_size(if compact then 10 else 11)
	local cb = if compact then 2.0 else 14.0
	self._credits:set_anchors(0, 1, 1, 1)
	self._credits:set_offsets(0, -(cb + ctx.insets.w + 14.0), 0, -(cb + ctx.insets.w))
	self:_place_crate_button(compact, head_top)
	self._party:apply_layout()
end

--- The crate button, top right: level with the wordmark's top on desktop; on phones up in the
--- screen's top right corner (2026-10-04: it and the Arsenal button moved up nearer the top and
--- further right), under Roblox's top bar row only when that row has controls of its own on the
--- right.
function TitleScreen._place_crate_button(self, compact: boolean, head_top: number)
	local ctx = self.ctx
	local vp = ctx.vp
	local ins = ctx.insets
	local b = self._crate_btn
	b:set_scale(if compact then CrateButton.PHONE_K else 1.0)
	local size = b:size_px()
	-- (phones: halfway into the safe-area band beside the notch, which sits at mid height and leaves
	-- the corner free; the rest of the band keeps the pair off the screen's round corner)
	local right = if compact then vp.X - math.max(14.0, ins.z * 0.45) else vp.X - ins.z - 28.0
	local top = if compact then math.max(6.0, ins.y * 0.5) else head_top
	local ok, inset = pcall(function()
		return game:GetService("GuiService").TopbarInset
	end)
	if ok and inset.Height > 0 then
		-- TopbarInset is the row's free part, in px from the safe area's corner. (It was compared
		-- with full-screen logical px before, so on a notched phone the pair always went under the
		-- row, though nothing of Roblox's was on the right.)
		local free = ctx:to_logical(Vector2.new(inset.Max.X, inset.Max.Y))
		if (vp.X - ins.z) - free.X > 24.0 and right > free.X and top < free.Y then
			top = free.Y + 6.0
		end
	end
	b:set_anchors(0, 0, 0, 0)
	b:set_offsets(right - size.X, top, right, top + size.Y)
	-- the Arsenal button sits beside it, to its left (the top left belongs to Roblox's chat window)
	local a = self._arsenal_btn
	a:set_scale(if compact then ArsenalButton.PHONE_K else 1.0)
	local asz = a:size_px()
	local aright = right - size.X - (if compact then 4.0 else 22.0)
	local atop = top + (size.Y - asz.Y)
	a:set_anchors(0, 0, 0, 0)
	a:set_offsets(aright - asz.X, atop, aright, atop + asz.Y)
	-- the flag shop's button under the pair, right-aligned with the crate button (always there while
	-- the shop sells: the starter pack's, which comes and goes, goes under it)
	local gap = if compact then 10.0 else 22.0
	local shb = self._shop_btn
	shb:set_scale(if compact then ShopButton.PHONE_K else 1.0)
	local shsz = shb:size_px()
	local shtop = top + size.Y + gap
	shb:set_anchors(0, 0, 0, 0)
	shb:set_offsets(right - shsz.X, shtop, right, shtop + shsz.Y)
	shb:refresh()
	-- the starter pack's button under it
	local sb = self._starter_btn
	sb:set_scale(if compact then StarterButton.PHONE_K else 1.0)
	local ssz = sb:size_px()
	local stop = if shb.visible then shtop + shsz.Y + (if compact then 8.0 else 14.0) else shtop
	sb:set_anchors(0, 0, 0, 0)
	sb:set_offsets(right - ssz.X, stop, right, stop + ssz.Y)
end

function TitleScreen._refresh_greeting(self)
	local n = self.ctx:username()
	local text = if n ~= "Commander" and n ~= "" then ("Welcome, Commander " .. n) else "Welcome, Commander"
	-- game admins (the server told this client which players are bots): say so, so it's easy to check
	local s = self.ctx.session
	if s ~= nil and s.admin_bots ~= nil then
		text ..= "  ·  Admin"
	end
	self._greet:set_text(text)
end

--- Phones' dock layout: "grid2" (shipped 2026-09-27) the public-match cards side by side over PLAY
--- SOLO; also "grid" (those rows swapped), "row" (one cramped row) and "stack"
--- (v35: the matches stacked between PLAY SOLO and the buttons). Studio: workspace attribute
--- AF_PHONE_DOCK overrides it.
TitleScreen.PHONE_DOCK = "grid2"
--- World's own kind of public match (LobbyRules.MODE_WORLD, on LobbyRules.WORLD_ID): its card always
--- shows it.
TitleScreen.WORLD_MAP = "world"

function TitleScreen._phone_dock(_self): string
	local v = TitleScreen.PHONE_DOCK
	pcall(function()
		if game:GetService("RunService"):IsStudio() then
			local a = workspace:GetAttribute("AF_PHONE_DOCK")
			if type(a) == "string" and a ~= "" then
				v = a
			end
		end
	end)
	return v
end

--- Desktop: a stacked card (PLAY SOLO, then the public matches). Phones: one row
--- [PLAY SOLO | ? | the public matches], so most of the globe stays visible. The solo map and
--- difficulty live in the PLAY SOLO menu (_build_solo_menu).
function TitleScreen._reflow_dock(self, compact: boolean)
	local variant = if compact then self:_phone_dock() else ""
	local want = if compact then "c:" .. variant else "d"
	if want == self._dock_compact then
		return
	end
	self._dock_compact = want
	for _, n in ipairs(self._dock_nodes) do
		if n:get_parent() ~= nil then
			n:get_parent():remove_child(n)
		end
	end
	for _, ch in ipairs(self._dock_v:get_children()) do
		self._dock_v:remove_child(ch)
		ch:queue_free()
	end
	local v = self._dock_v
	self._dock_variant = variant
	if compact and variant ~= "stack" then
		v:set_separation(6)
		self._mp.size_flags_horizontal = W.EXPAND_FILL
		self._mp2.size_flags_horizontal = W.EXPAND_FILL
		self._mp3.size_flags_horizontal = W.EXPAND_FILL
		self._solo.size_flags_vertical = W.FILL
		if variant == "row" then
			-- [PLAY SOLO | match | match | match]
			local line = UITheme.hbox(8)
			self._solo.size_flags_horizontal = W.FILL
			line:add_child(self._solo)
			line:add_child(self._mp)
			line:add_child(self._mp2)
			line:add_child(self._mp3)
			v:add_child(line)
		else
			-- two rows: [PLAY SOLO] and [match | match | match]
			local top = UITheme.hbox(8)
			self._solo.size_flags_horizontal = W.EXPAND_FILL
			top:add_child(self._solo)
			local bottom = UITheme.hbox(8)
			bottom:add_child(self._mp)
			bottom:add_child(self._mp2)
			bottom:add_child(self._mp3)
			if variant == "grid2" then
				v:add_child(bottom)
				v:add_child(top)
			else
				v:add_child(top)
				v:add_child(bottom)
			end
		end
	elseif compact then
		-- [PLAY SOLO | ? | the public matches, stacked (the widest)]
		v:set_separation(6)
		local line = UITheme.hbox(8)
		line:add_child(self._solo)
		line:add_child(self._help)
		self._solo.size_flags_horizontal = W.FILL
		local col = self._mp_col
		col.size_flags_horizontal = W.EXPAND_FILL
		col:add_child(self._mp)
		col:add_child(self._mp2)
		col:add_child(self._mp3)
		self._mp.size_flags_horizontal = W.EXPAND_FILL
		self._mp2.size_flags_horizontal = W.EXPAND_FILL
		self._mp3.size_flags_horizontal = W.EXPAND_FILL
		line:add_child(col)
		for _, b in { self._solo, self._help } do
			b.size_flags_vertical = W.SHRINK_CENTER
		end
		v:add_child(line)
	else
		v:set_separation(12)
		-- [PLAY SOLO | ?], then the public matches (2026-10-19: the "?" button moved from beside the
		-- public match to beside PLAY SOLO)
		self._solo.size_flags_horizontal = W.EXPAND_FILL
		for _, b in { self._solo, self._help } do
			b.size_flags_vertical = W.FILL
		end
		for _, c2 in ipairs({ self._greet, self._mp_row, self._dock_div }) do
			v:add_child(c2)
		end
		self._mp_row:add_child(self._solo)
		self._mp_row:add_child(self._help)
		v:add_child(self._mp)
		v:add_child(self._mp2)
		v:add_child(self._mp3)
	end
end

--- The PLAY SOLO menu: map, difficulty and START (it takes the dock's place while open).
function TitleScreen._build_solo_menu(self)
	local T = UITheme
	local p = GlassPanel.new(20.0, 18.0, 18, true, 28)
	self._solo_panel = p
	self._solo_open = false
	self:add_child(p)
	local v = T.vbox(12)
	self._solo_v = v
	p:add_child(v)
	local head = T.hbox(10)
	local ic = T.icon_rect("play", 18.0, T.AMBER)
	ic.size_flags_vertical = W.SHRINK_CENTER
	head:add_child(ic)
	local title = T.label("PLAY SOLO", 17, 800, T.TEXT, 2)
	title.size_flags_horizontal = W.EXPAND_FILL
	title.size_flags_vertical = W.SHRINK_CENTER
	head:add_child(title)
	local close = T.button("", "GhostButton", "close", 44.0)
	close.expand_icon = true
	close.icon_alignment = W.ALIGN_CENTER
	close:add_theme_constant_override("icon_max_width", 16)
	close:set_min_size(Vector2.new(44, 44))
	close.pressed:Connect(function()
		self:close_solo_menu()
	end)
	head:add_child(close)
	v:add_child(head)
	self._map_btn.size_flags_horizontal = W.FILL
	v:add_child(self._map_btn)
	self._diff_row.size_flags_horizontal = W.FILL
	v:add_child(self._diff_row)
	v:add_child(self._diff_desc)
	local start = T.button("START", "PrimaryButton", "play", 58.0)
	start:add_theme_constant_override("icon_max_width", 18)
	start:set_font_size(19)
	start.pressed:Connect(function()
		self.play_solo:Fire(self.difficulty)
	end)
	self._start = start
	v:add_child(start)
	p:set_visible(false)
end

function TitleScreen.open_solo_menu(self)
	if self._solo_open then
		return
	end
	self._solo_open = true
	self._dock:set_visible(false)
	self._solo_panel:set_visible(true)
	UICtx.pop_in(self._solo_panel, 0.0, 0.96, 0.25)
	self.ctx:sfx("open", -6.0)
end

--- Back to the dock (`quiet`: no sound, e.g. when the title hides).
function TitleScreen.close_solo_menu(self, quiet: boolean?)
	if not self._solo_open then
		return
	end
	self._solo_open = false
	self._solo_panel:set_visible(false)
	self._dock:set_visible(not self.ctx:mp_waiting())
	if not quiet then
		self.ctx:sfx("close", -6.0)
	end
end

function TitleScreen._refresh_diff(self)
	local txt = TitleScreen.DIFF_BLURB[self.difficulty]
	local grace = self.ctx:rules_call("human_grace_ticks", { self.difficulty })
	if type(grace) == "number" then
		local secs = grace / 10.0
		if secs > 0.0 then
			txt ..= "  Nations leave you alone for " .. UITheme.fmt_time(secs) .. "."
		end
	end
	self._diff_desc:set_text(txt)
end

function TitleScreen._size_word(self, px: number)
	self._word:set_px(px)
	self._word.spacing = math.floor(px * 0.12)
	self._word_target_spacing = self._word.spacing
	self._word.shadow.outline = math.floor(px * 0.1)
	self._word:update_minimum_size()
	self._word:_redraw()
end

function TitleScreen.on_show(self)
	self:_refresh_greeting()
	if self._hide_tween ~= nil then
		self._hide_tween:kill()
		self._hide_tween = nil
	end
	self:_refresh_queue_mode()
	self:_refresh_mp()
	self:set_modulate_a(1.0)
	self:_refresh_diff()
	-- Entrance, timed against the attract sim's ~4 s time-lapse bloom: the shades lift as the world
	-- fills in, the wordmark lands mid-bloom, the menu rises, and a shine crosses the logo as the
	-- bloom settles.
	local word = self._word
	local target_sp = self._word_target_spacing or word.spacing
	word.spacing = target_sp + 30
	word:update_minimum_size()
	word:set_modulate_a(0.0)
	word:set_scale(1.18)
	local t = self:create_tween():set_parallel(true)
	self._fade:set_modulate_a(1.0)
	t:tween_property(self._fade, "modulate:a", 0.0, 1.8):set_trans(W.TRANS_SINE):set_ease(W.EASE_OUT)
	self._emblem:set_modulate_a(0.0)
	t:tween_property(self._emblem, "modulate:a", 1.0, 0.7):set_delay(0.5)
	t:tween_property(word, "modulate:a", 1.0, 0.8):set_delay(1.0):set_trans(W.TRANS_CUBIC):set_ease(W.EASE_OUT)
	t:tween_property(word, "scale", 1.0, 1.2):set_delay(1.0):set_trans(W.TRANS_EXPO):set_ease(W.EASE_OUT)
	t:tween_method(function(v: number)
		word.spacing = v
		word:update_minimum_size()
		word:_redraw()
	end, target_sp + 30, target_sp, 1.5)
		:set_delay(1.0)
		:set_trans(W.TRANS_EXPO)
		:set_ease(W.EASE_OUT)
	self._glow:set_modulate_a(0.0)
	t:tween_property(self._glow, "modulate:a", 1.0, 1.6):set_delay(1.4)
	self._tag_row:set_modulate_a(0.0)
	t:tween_property(self._tag_row, "modulate:a", 1.0, 0.7):set_delay(2.1)
	W.slide_in(self._dock, Vector2.new(0, 40), 1.7, 0.7)
	W.slide_in(self._queue, Vector2.new(0, 36), 0.3, 0.5)
	self._credits:set_modulate_a(0.0)
	t:tween_property(self._credits, "modulate:a", 1.0, 0.8):set_delay(2.6)
	self._sweep_t = 0.0
end

--- Play Solo was pressed: the new world is being built in the background.
function TitleScreen.set_building(self, on: boolean)
	self._solo:set_disabled(on)
	self._start:set_disabled(on)
	self._start:set_text(if on then "DEPLOYING…" else "START")
	for _, ch in ipairs(self._chips) do
		ch:set_disabled(on)
	end
end

function TitleScreen.hide_animated(self)
	if not self.visible or (self._hide_tween ~= nil and self._hide_tween:is_running()) then
		return
	end
	self._hide_tween = self:create_tween()
	self._hide_tween:tween_property(self, "modulate:a", 0.0, 0.3):set_trans(W.TRANS_CUBIC):set_ease(W.EASE_IN)
	self._hide_tween:tween_callback(function()
		self:set_visible(false)
		self:set_modulate_a(1.0)
		-- next time the title shows, it opens on the dock again
		self:close_solo_menu(true)
	end)
end

function TitleScreen.set_lobby(self, info: any)
	self._lobby = info or {}
	self._lobby_msec = UICtx.msec()
	self:_refresh_mp()
end

function TitleScreen._refresh_queue_mode(self)
	local waiting = self.ctx:mp_waiting()
	if waiting and not self._was_waiting then
		self.ctx:sfx("queue_start") -- (Airship BedWars' queue sound: the waiting room opens)
	end
	self._was_waiting = waiting
	if waiting then
		self:close_solo_menu(true)
	end
	self._queue:set_visible(waiting)
	self._dock:set_visible(not waiting and not self._solo_open)
end

function TitleScreen._countdown(self): number
	local cd = tonumber(self._lobby.countdown_s) or 0.0
	return math.max(0.0, cd - (UICtx.msec() - self._lobby_msec) / 1000.0)
end

--- Public-match cards from the lobby list (hub servers).
function TitleScreen._refresh_lobby_cards(self)
	local ctx = self.ctx
	local elapsed = (UICtx.msec() - self._lobbies_msec) / 1000.0
	-- the open lobbies with room (running matches aren't shown: the title screen's spectating went,
	-- 2026-10-19)
	local open = {}
	for _, lb in self._lobbies or {} do
		if lb.live then
			continue
		elseif
			((tonumber(lb.max) or 0) <= 0 or (tonumber(lb.players) or 0) < (tonumber(lb.max) or 0))
			and lb.joinable ~= false
			and math.ceil((tonumber(lb.starts_in) or 0) - elapsed) > TitleScreen.JOIN_CLOSE_S
		then
			-- (a lobby that filled up, or whose joins closed while the list counted down here, is
			-- hidden: the next one is the one to join)
			table.insert(open, lb)
		end
	end
	-- Quick Play: a card per kind of public match on offer (the free-for-all, World's,
	-- the team game), showing the soonest of the lobbies its JOIN may seat in; JOIN asks the hub for a
	-- seat in that kind, and with every match of it full the player waits in line (CANCEL).
	local soonest: { [string]: any } = {}
	local has_team = false
	for _, lb in open do
		local k = if lb.mode == "team" or lb.mode == "world" then lb.mode else "ffa"
		soonest[k] = soonest[k] or lb
		has_team = has_team or k == "team"
	end
	-- PUBLIC MATCH takes World's seats too (the server's LobbyRules.takes_from; 2026-10-19: the World
	-- and PUBLIC MATCH buttons can still put players into the same match):
	-- its next match is World's when that starts sooner (a tie: the free-for-all, as the server picks)
	local cards_of: { [string]: any } = table.clone(soonest)
	local w, f = soonest.world, soonest.ffa
	if w ~= nil and (f == nil or (tonumber(w.starts_in) or 0) < (tonumber(f.starts_in) or 0)) then
		cards_of.ffa = w
	end
	local kinds = self._kinds or (if has_team then { "ffa", "team" } else { "ffa" })
	-- phones with three kinds side by side: each card is only its title and status line (the whole
	-- card is the button), or the titles and lines were cut to "GIANT W", "World ·…" (2026-10-19)
	self._tight = ctx.compact and self._dock_variant ~= "stack" and #kinds >= 3
	for i, card in self._cards do
		local kind = kinds[i]
		card.mode = kind
		if i >= 2 then
			card.btn:set_visible(kind ~= nil)
		end
		if kind == nil then
			card.lobby = nil
			continue
		end
		card.lobby = cards_of[kind]
		self:_refresh_kind_card(card, kind, cards_of[kind], elapsed)
	end
end

--- One Quick Play card: the kind's soonest lobby with room (`l`, nil: none listed — JOIN still puts
--- the player in line), or what the player's ask is doing.
function TitleScreen._refresh_kind_card(self, card: { [string]: any }, kind: string, l: any?, elapsed: number)
	local ctx = self.ctx
	local pub = self._public
	local mine = pub.state ~= "idle" and pub.mode == kind
	local busy_other = pub.state ~= "idle" and not mine
	local follower = self._in_party and not self._party_leader
	-- the map: the one we are going to once seated, else the soonest with room (none while in line:
	-- every match of the kind is full)
	local going = mine and pub.state == "going" and type(pub.info) == "table"
	local map = if going
		then pub.info.map
		elseif kind == "world" then TitleScreen.WORLD_MAP
		elseif mine and pub.state == "line" then nil
		else (if l then l.map else nil)
	local map_name = if going
		then pub.info.map_name
		elseif kind == "world" then "World"
		else (if l then (l.map_name or l.map) else nil)
	-- a free-for-all is any map: its card isn't titled with the next one, which a seat may not be in
	-- (a player, 2026-10-19, kept joining maps they didn't want to play); the status line names it
	local next_map = nil
	if kind == "ffa" and not going then
		next_map = map_name
		map, map_name = nil, nil
	end
	local tight = self._tight == true
	if tight then
		card.icon:set_visible(false)
		card.thumb_node:set_visible(false)
		card.title:set_text(
			if going then string.upper(tostring(map_name or map))
				elseif kind == "team" then "TEAM GAME"
				elseif kind == "world" then "WORLD"
				else "PUBLIC MATCH"
		)
	elseif map ~= nil then
		card.icon:set_visible(false)
		card.thumb_node:set_visible(true)
		local e = UIMaps.get(map)
		card.thumb.Image = if e and e.thumb then e.thumb else ""
		card.title:set_text(string.upper(tostring(map_name or map)))
	else
		card.icon:set_visible(true)
		card.thumb_node:set_visible(false)
		card.title:set_text(if kind == "team" then "TEAM GAME" elseif kind == "world" then "WORLD" else "PUBLIC MATCH")
	end
	-- a team game: its teams first ("4 Teams", "Duos", "Humans Vs Nations")
	local teams = if l ~= nil and l.mode == "team" and l.teams ~= nil
		then (
			if type(l.teams) == "number"
				then string.format("%d Teams", l.teams)
				elseif l.teams == "Humans Vs Nations" and ctx.compact then "H vs N"
				else tostring(l.teams)
		)
		else nil
	local text
	if mine and pub.state == "line" then
		local w = UITheme.fmt_time(math.max(0, math.floor((UICtx.msec() - self._public_since) / 1000)))
		text = if ctx.compact then ("In line  ·  " .. w) else ("Waiting for a free seat  ·  " .. w)
	elseif mine then
		text = if pub.state == "going" then "Joining…" else "Finding a seat…"
	elseif l ~= nil then
		local left = math.max(0, math.ceil((tonumber(l.starts_in) or 0) - elapsed))
		local players = string.format("%d / %d players", tonumber(l.players) or 0, tonumber(l.max) or 0)
		if teams ~= nil then
			text = if ctx.compact and self._dock_variant ~= "stack"
				then string.format("%s · %d/%d · %s", teams, tonumber(l.players) or 0, tonumber(l.max) or 0, UITheme.fmt_time(left))
				else string.format("%s  ·  %s  ·  %s", teams, players, UITheme.fmt_time(left))
		else
			text = if ctx.compact and self._dock_variant ~= "stack"
				then string.format("%d/%d  ·  %s", tonumber(l.players) or 0, tonumber(l.max) or 0, UITheme.fmt_time(left))
				else string.format("%s  ·  starts in %s", players, UITheme.fmt_time(left))
			if next_map ~= nil then
				text = (if ctx.compact then "" else "Next: ") .. tostring(next_map) .. "  ·  " .. text
			end
		end
	else
		text = if ctx.compact then "Next match soon" else "Next match opening soon"
	end
	if tight and mine and pub.state == "line" then
		-- (no CANCEL pill here: a press on the card leaves the line, and the line says so)
		text = "In line  ·  " .. UITheme.fmt_time(math.max(0, math.floor((UICtx.msec() - self._public_since) / 1000))) .. "  ·  tap to cancel"
	end
	card.status:set_text(text)
	UITheme.set_swatch_color(card.dot, if l ~= nil or mine then UITheme.GREEN else UITheme.AMBER)
	card.pill:set_visible(not tight)
	card.pill_l:set_text(
		if follower
			then "LEADER"
			elseif mine and pub.state == "line" then "CANCEL"
			elseif mine then "…"
			elseif teams ~= nil and not ctx.compact then "JOIN TEAMS"
			else "JOIN"
	)
	local ready = not follower and not busy_other and (pub.state == "idle" or (mine and pub.state == "line"))
	card.btn:set_disabled(not ready or self._joining ~= nil)
end

function TitleScreen._refresh_mp(self)
	local ctx = self.ctx
	if self._lobbies ~= nil and not ctx:mp_waiting() then
		self:_refresh_lobby_cards()
		return
	end
	-- no lobby list (yet): the first card shows the server status
	self._mp2:set_visible(false)
	self._mp3:set_visible(false)
	self._cards[1].thumb_node:set_visible(false)
	self._cards[1].icon:set_visible(true)
	self._cards[1].lobby = nil
	self._cards[1].mode = nil
	local mpa = ctx:session_call("multiplayer_available")
	local st = ctx:session_call("multiplayer_status")
	local status = if type(st) == "string" then st else (if mpa == true then "connected" else "offline")
	local avail = status == "connected"
	local stage = tostring(self._lobby.stage or "idle")
	local players = self._lobby.players or {}
	local n = #players
	local dot = UITheme.TEXT_3
	local text = ""
	local join = "JOIN"
	local clickable = avail
	if status == "connecting" then
		dot = UITheme.AMBER
		text = if ctx.compact then "Connecting…" else "Connecting to server…"
		join = ""
		clickable = false
	elseif not avail then
		text = if ctx.compact then "Offline" else "Offline  ·  play solo for now"
		join = "RETRY"
		clickable = true
	else
		if stage == "lobby" then
			dot = UITheme.AMBER
			local cd = UITheme.fmt_time(math.ceil(self:_countdown()))
			text = if ctx.compact then ("Next in " .. cd) else string.format("Next match in %s  ·  %d queued", cd, n)
			join = "QUEUE"
		elseif stage == "spawn" or stage == "playing" then
			dot = UITheme.GREEN
			local el = (tonumber(self._lobby.elapsed_s) or 0.0) + (UICtx.msec() - self._lobby_msec) / 1000.0
			text = if ctx.compact
				then string.format("%d online  ·  %s", n, UITheme.fmt_time(el))
				else string.format(
					"%d commander%s  ·  in progress %s",
					n,
					if n == 1 then "" else "s",
					UITheme.fmt_time(el)
				)
		elseif stage == "over" then
			dot = UITheme.AMBER
			text = "Match ending  ·  next one soon"
			join = "QUEUE"
		else
			dot = UITheme.GREEN
			text = "Server online  ·  start a new match"
			join = "START"
		end
	end
	self._mp_join:set_visible(join ~= "")
	self._mp_join_l:set_text(join)
	local jc = if avail then UITheme.CYAN else UITheme.TEXT_2
	self._mp_join_l:set_color(jc)
	if self._mp_join_c ~= jc then
		self._mp_join_c = jc
		self._mp_join:add_theme_stylebox_override(
			"panel",
			UITheme.flat(UITheme.c(jc, 0.14), 999, UITheme.c(jc, 0.5), 1, 10.0, 3.0)
		)
	end
	self._mp_status:set_text(text)
	UITheme.set_swatch_color(self._mp_dot, dot)
	self._mp:set_disabled(not clickable)
	self._mp_title:set_color(if avail then UITheme.TEXT else UITheme.TEXT_2)
	-- Queue card
	if ctx:mp_waiting() and self._lobby.kind == "match" then
		-- a public lobby's own server: the waiting room until the match starts
		local e = UIMaps.get(self._lobby.map_id)
		-- a team game says so: "TEAM GAME · 4 TEAMS · FOUR ISLANDS"
		local tm = self._lobby.teams
		local kind = if tm == nil
			then "PUBLIC MATCH"
			elseif type(tm) == "number" then string.format("TEAM GAME  ·  %d TEAMS", tm)
			else "TEAM GAME  ·  " .. string.upper(tostring(tm))
		self._q_title:set_text(kind .. "  ·  " .. string.upper(if e then e.name else "World"))
		local maxp = tonumber(self._lobby.max) or 0
		local votes = tonumber(self._lobby.votes) or 0
		local need = math.max(tonumber(self._lobby.votes_needed) or 1, 1)
		local started = self._lobby.vote_started == true
		if stage == "lobby" then
			self._q_status:set_text(
				(if started then "Voted to start  ·  starting in " else "Match starts in ")
					.. UITheme.fmt_time(math.ceil(self:_countdown()))
			)
		elseif stage == "spawn" or stage == "playing" then
			self._q_status:set_text("Joining the match…")
		else
			self._q_status:set_text("Getting the match ready…")
		end
		local names = {}
		for _, p in ipairs(players) do
			table.insert(names, tostring(p))
		end
		local head = if maxp > 0 then string.format("%d / %d players", n, maxp) else string.format("%d players", n)
		self._q_players:set_text(if n > 0 then (head .. ":  " .. table.concat(names, ", ")) else head)
		self._q_leave:set_text("Leave match")
		-- vote to start: two thirds of the players here start the match in 10 s (MatchServer.VOTE_SHARE)
		local can_vote = stage == "lobby" and self._lobby.spectating ~= true
		self._q_vote:set_visible(can_vote)
		if can_vote then
			local tally = string.format("%d / %d", math.min(votes, need), need)
			local min_players = tonumber(self._lobby.vote_min_players) or 2
			local lonely = (tonumber(self._lobby.vote_players) or n) < min_players
			-- alone: a lone vote may start the match after a short wait (MatchServer.VOTE_SOLO_AFTER_S)
			local solo_in = tonumber(self._lobby.vote_solo_in)
			if solo_in ~= nil then
				solo_in = math.max(0, math.ceil(solo_in - (UICtx.msec() - self._lobby_msec) / 1000.0))
			end
			self._q_vote:set_text(
				if started
					then "Starting…"
					elseif lonely and solo_in ~= nil then "Vote to start in " .. UITheme.fmt_time(solo_in)
					elseif lonely then string.format("Vote to start needs %d players", min_players)
					elseif self._lobby.voted == true then "Voted  ·  " .. tally .. "  (tap to undo)"
					else "Vote to start  ·  " .. tally
			)
			self._q_vote:set_disabled(started or (lonely and self._lobby.voted ~= true))
		end
	elseif ctx:mp_waiting() then
		self._q_vote:set_visible(false)
		self._q_title:set_text("JOINING MULTIPLAYER")
		self._q_leave:set_text("Leave queue")
		if stage == "lobby" then
			self._q_status:set_text("Match starts in " .. UITheme.fmt_time(math.ceil(self:_countdown())))
		elseif stage == "spawn" or stage == "playing" then
			self._q_status:set_text("Joining the match in progress…")
		elseif stage == "over" then
			self._q_status:set_text("Previous match wrapping up…")
		else
			self._q_status:set_text("Contacting the server…")
		end
		local names = {}
		for _, p in ipairs(players) do
			table.insert(names, tostring(p))
		end
		self._q_players:set_text(
			if n > 0 then ("Commanders: " .. table.concat(names, ", ")) else "You are the first commander here."
		)
	end
end

function TitleScreen._process(self, delta: number)
	if not self.visible then
		return
	end
	if self._sweep_t >= 0.0 then
		self._sweep_t += delta
		local w = self._word.size.X
		local x = -240.0 + (w + 480.0) * math.clamp((self._sweep_t - 3.6) / 1.2, 0.0, 1.0)
		self._word.sweep = x
		self._word:_redraw()
		if self._sweep_t > 4.9 then
			self._sweep_t = -1.0
			self._word.sweep = -10000.0
			self._word:_redraw()
		end
	end
	self._accum += delta
	self._dot_t += delta
	if self._accum >= 0.25 then
		self._accum = 0.0
		self:_refresh_queue_mode()
		self:_refresh_mp()
		self:_refresh_greeting()
		-- the party: on the title itself, not over the waiting room
		local party_on = self._party.state ~= nil and not self.ctx:mp_waiting()
		if self._party.visible ~= party_on then
			self._party:set_visible(party_on)
		end
	end
	self._mp_dot:set_modulate_a(0.55 + 0.45 * (0.5 + 0.5 * math.sin(self._dot_t * 4.0)))
	self:_countdown_ticks()
end

TitleScreen.TICK_FROM_S = 10

--- Public-match waiting room: BedWars' countdown — its tick each second over the last TICK_FROM_S
--- before the match starts, its numbered ticks over the last five, its start sound at zero.
function TitleScreen._countdown_ticks(self)
	local ctx = self.ctx
	if not ctx:mp_waiting() or tostring(self._lobby.stage) ~= "lobby" then
		self._tick_sec = -1
		return
	end
	local sec = math.ceil(self:_countdown())
	local prev = self._tick_sec or -1
	if sec == prev then
		return
	end
	self._tick_sec = sec
	-- (the first reading only arms it; a countdown that jumps back up doesn't tick)
	if prev < 0 or sec >= prev or sec > TitleScreen.TICK_FROM_S then
		return
	end
	if sec <= 0 then
		ctx:sfx("countdown_gamestart", -2.0, 0.0)
	elseif sec <= 5 then
		ctx:sfx("countdown_tick_" .. sec, -2.0, 0.0)
	else
		ctx:sfx("tick", -6.0, 0.0)
	end
end

return TitleScreen
