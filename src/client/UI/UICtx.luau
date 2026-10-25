-- Port of scripts/ui/ui_ctx.gd
-- Shared context for every UI component: duck-typed handles to Session / WorldView / AudioDirector
-- (so lightweight stand-ins work in tests), the bound GameState, layout metrics, the attack ratio,
-- persisted settings and throttled sound effects. Also a few static helpers the Godot builtins
-- provided (Rect2 maths on Roblox `Rect`, colour conversion, shared-module resolution).
--
-- Coordinates: the UI works in LOGICAL px (Godot px of the 1600x900 design; the kit's Widgets.Root
-- applies one UI scale, see build/notes/ui-kit.md). WorldView / UserInputService use VIEWPORT px.
-- Every conversion happens here: tile_screen_pos / mouse_pos return logical px, tile_at(pos) takes
-- logical px, to_view / to_logical convert explicitly.

local IS_ROBLOX = (game :: any) ~= nil

--- Shared Core module by name (ReplicatedStorage.Airfront.Core in Roblox, src/shared/Core in Lune),
--- required once and kept (see UICtx.prime: a require late in a session can fail).
local _core: { [string]: any } = {}
local function core(name: string): any
	local m = _core[name]
	if m ~= nil then
		return m
	end
	if IS_ROBLOX then
		local rs = game:GetService("ReplicatedStorage")
		m = require((rs:WaitForChild("Airfront") :: any):WaitForChild("Core"):WaitForChild(name))
	else
		m = (require :: any)("../../shared/Core/" .. name)
	end
	_core[name] = m
	return m
end

local Signal = core("Signal")
local Defs = core("Defs")

local UICtx = {}
UICtx.__index = UICtx

UICtx.core = core
UICtx.IS_ROBLOX = IS_ROBLOX

UICtx.MODE_TITLE = 0
UICtx.MODE_SOLO = 1
UICtx.MODE_MULTI = 2
--- Solo difficulty until the player picks one (0 Relaxed · 1 Standard · 2 Brutal): Relaxed, the
--- gentlest. Standard as the default lost most new players in their
--- first minutes (2026-09-28 funnel: 2.6% of Standard matches reached 10 minutes, 16% of Relaxed).
UICtx.DEFAULT_DIFFICULTY = 0
--- The Attack bar's stops: the shares of the army an order can send. Since 2026-10-08 the bar has
--- five set breakpoints, none below 10% or above 75%, which were never needed.
--- Until then the ratio was anything from 1% to 100% (a free slider), set by dragging a
--- knob along 96 px on a phone.
UICtx.RATIO_STOPS = { 0.10, 0.25, 0.35, 0.50, 0.75 }
--- Attack ratio before the player sets one: the stop beside 20 % (it was
--- 20% while the slider had no stops).
UICtx.DEFAULT_RATIO = 0.25

--- Logical SFX ids -> file names in assets/audio/sfx (one place to remap).
UICtx.SFX = {
	hover = "ui_hover",
	click = "ui_click",
	open = "ui_open",
	close = "ui_back",
	deny = "ui_error",
	toast = "ui_tab",
	-- the interface kit (Assets/AudioUI): a press that commits, a tab / toggle, a locked unit,
	-- Stars counting up and landing, paying, an unlock
	confirm = "ui_confirm",
	tab = "ui_tab",
	locked = "ui_locked",
	star_tick = "star_tick",
	star_get = "star_get",
	buy = "buy_spend",
	unlock = "unlock",
	expand = "expand",
	attack = "attack_launch",
	boat = "boat_launch",
	build = "build",
	warship = "warship",
	nuke_launch = "nuke_launch",
	explosion = "nuke_explosion",
	intercept = "sam_intercept",
	alliance = "alliance",
	betrayal = "betrayal",
	alarm = "nuke_alarm",
	-- (BedWars' kill sound, Assets/AudioUI; it was "conquer", the original's 3 s sting, until it was
	-- replaced by a satisfying, unobtrusive elimination sound, 2026-10-04)
	eliminate = "eliminate",
	victory = "victory",
	defeat = "defeat",
	tick = "countdown_tick",
	start = "game_start",
	spawn = "spawn_confirm",
	under_attack = "under_attack",
	ally_request = "ally_request",
	ship_lost = "ship_sunk",
	ship_kill = "ship_kill",
	trade_captured = "trade_capture",
	trade_lost = "trade_lost",
	warship_retreat = "warship_retreat",
	veterancy = "veterancy",
	sam_launch = "sam_launch",
}
--- Used when the AudioDirector does not (yet) ship a sound.
UICtx.SFX_FALLBACK = {
	close = "ui_click",
	toast = "ui_open",
	confirm = "ui_click",
	tab = "ui_click",
	locked = "ui_error",
	star_tick = "ui_hover",
	star_get = "ui_open",
	buy = "ui_click",
	unlock = "alliance",
	under_attack = "ui_error",
	ally_request = "ui_open",
	ship_lost = "sam_intercept",
	ship_kill = "sam_intercept",
	trade_captured = "build",
	trade_lost = "ui_error",
	warship_retreat = "ui_open",
	veterancy = "alliance",
	sam_launch = "attack_launch",
}
--- Minimum milliseconds between two plays of the same SFX id (AudioDirector throttles too).
UICtx.SFX_GAP = {
	hover = 60,
	click = 40,
	tab = 40,
	confirm = 80,
	locked = 200,
	star_tick = 28,
	unlock = 900,
	toast = 400,
	attack = 180,
	expand = 180,
	boat = 200,
	build = 150,
	explosion = 220,
	alarm = 1500,
	tick = 300,
	deny = 200,
	under_attack = 4000,
	ally_request = 1500,
	ship_lost = 1500,
	ship_kill = 1500,
	trade_captured = 2500,
	trade_lost = 3000,
	warship_retreat = 3000,
	veterancy = 2000,
	sam_launch = 100,
	intercept = 120,
	shell_fire = 50,
	shell_hit = 50,
	shell_splash = 50,
	ship_sink = 300,
}

--- A shared Data module (ReplicatedStorage.Airfront.Data: "Arsenal", "Stars", "Products"...),
--- required once and kept.
local _data: { [string]: any } = {}
function UICtx.data(name: string): any
	local m = _data[name]
	if m ~= nil then
		return m
	end
	if typeof(game) == "Instance" then
		local rs = (game :: any):GetService("ReplicatedStorage")
		m = require((rs:WaitForChild("Airfront") :: any).Data[name])
	else
		m = (require :: any)("../../shared/Data/" .. name)
	end
	_data[name] = m
	return m
end

--- A UI module beside this one ("UITheme", "Widgets", "UIRules"...), required once and kept: modules
--- that load one lazily (to keep the rules testable without the interface) ask here.
local _mods: { [string]: any } = {}
function UICtx.mod(name: string): any
	local m = _mods[name]
	if m ~= nil then
		return m
	end
	if typeof(game) == "Instance" then
		m = require((script :: any).Parent:WaitForChild(name))
	else
		m = (require :: any)("./" .. name)
	end
	_mods[name] = m
	return m
end

--- What the interface loads later in a session, loaded at its start. In some live sessions every
--- require after some moment fails ("Cannot require a RobloxScript module from a non RobloxScript
--- context": hover tooltips, sounds, toasts, the troop rate's colour; 2026-10-10 on, 34.6K errors a day
--- by 10-23, its trigger not found): with these kept, nothing on those paths requires any more.
UICtx.PRIME_CORE = { "Signal", "Defs", "Rules", "NumberFormat", "Ev" }
UICtx.PRIME_UI = { "UITheme", "Widgets", "UIRules", "FloatText", "Banner", "FillBar" }
UICtx.PRIME_DATA = { "Arsenal", "Cosmetics", "Staging", "Stars", "Starter", "Tutorial", "Products" }
function UICtx.prime()
	for _, n in UICtx.PRIME_CORE do
		pcall(core, n)
	end
	for _, n in UICtx.PRIME_UI do
		pcall(UICtx.mod, n)
	end
	for _, n in UICtx.PRIME_DATA do
		pcall(UICtx.data, n)
	end
	local T = _mods.UITheme
	if T ~= nil then
		for _, n in UICtx.PRIME_CORE do
			pcall(T.core, n)
		end
		pcall(T.crate_art)
		pcall(T.icon, "close")
	end
	pcall(UICtx.shapes)
end

--- 12345 -> "12,345" (Stars are shown whole, never as 12.3K).
function UICtx.commas(n: number): string
	local s = tostring(math.floor(math.abs(n) + 0.5))
	local out = string.reverse((string.gsub(string.reverse(s), "(%d%d%d)", "%1,")))
	if string.sub(out, 1, 1) == "," then
		out = string.sub(out, 2)
	end
	return if n < 0 then "-" .. out else out
end

--- Milliseconds since an arbitrary start (GDScript Time.get_ticks_msec()).
function UICtx.msec(): number
	return os.clock() * 1000.0
end

-- =============================================================================================
-- Static helpers (Godot builtins)
-- =============================================================================================

--- RGBA8 int (Core colours) / Color3 -> Color3.
function UICtx.color3(c: any): Color3
	if typeof(c) == "Color3" then
		return c
	end
	if type(c) == "number" then
		local r, g, b = Defs.rgba_bytes(c)
		return Color3.fromRGB(r, g, b)
	end
	return Color3.new(0.6, 0.6, 0.6)
end

--- Godot Color.get_luminance() of a Color3.
function UICtx.luminance(c: Color3): number
	return 0.2126 * c.R + 0.7152 * c.G + 0.0722 * c.B
end

--- Rect2(x, y, w, h) as a Roblox Rect.
function UICtx.rect(x: number, y: number, w: number, h: number): Rect
	return Rect.new(x, y, x + w, y + h)
end

--- Rect2(position, size).
function UICtx.rect_ps(pos: Vector2, size: Vector2): Rect
	return Rect.new(pos.X, pos.Y, pos.X + size.X, pos.Y + size.Y)
end

--- Viewport-px rect of a GuiObject. AbsolutePosition is relative to the area below the top bar
--- (even inside IgnoreGuiInset ScreenGuis), so the GUI inset is added back.
function UICtx.rect_of(g: GuiObject): Rect
	local inset = if IS_ROBLOX then game:GetService("GuiService"):GetGuiInset() else Vector2.zero
	local p = g.AbsolutePosition + inset
	local s = g.AbsoluteSize
	return Rect.new(p.X, p.Y, p.X + s.X, p.Y + s.Y)
end

UICtx.EMPTY_RECT = Rect.new(0, 0, 0, 0)

function UICtx.rect_is_empty(r: Rect): boolean
	return r.Width <= 0 or r.Height <= 0
end

function UICtx.rect_has_point(r: Rect, p: Vector2): boolean
	return p.X >= r.Min.X and p.Y >= r.Min.Y and p.X < r.Max.X and p.Y < r.Max.Y
end

function UICtx.rect_grow(r: Rect, by: number): Rect
	return Rect.new(r.Min.X - by, r.Min.Y - by, r.Max.X + by, r.Max.Y + by)
end

--- Rect2.intersects (borders excluded).
function UICtx.rect_intersects(a: Rect, b: Rect): boolean
	return a.Min.X < b.Max.X and a.Max.X > b.Min.X and a.Min.Y < b.Max.Y and a.Max.Y > b.Min.Y
end

--- Rect2.encloses: b lies completely inside a.
function UICtx.rect_encloses(a: Rect, b: Rect): boolean
	return b.Min.X >= a.Min.X and b.Min.Y >= a.Min.Y and b.Max.X <= a.Max.X and b.Max.Y <= a.Max.Y
end

function UICtx.rect_intersection_area(a: Rect, b: Rect): number
	local w = math.min(a.Max.X, b.Max.X) - math.max(a.Min.X, b.Min.X)
	local h = math.min(a.Max.Y, b.Max.Y) - math.max(a.Min.Y, b.Min.Y)
	if w <= 0 or h <= 0 then
		return 0
	end
	return w * h
end

function UICtx.rect_merge(a: Rect, b: Rect): Rect
	return Rect.new(
		math.min(a.Min.X, b.Min.X),
		math.min(a.Min.Y, b.Min.Y),
		math.max(a.Max.X, b.Max.X),
		math.max(a.Max.Y, b.Max.Y)
	)
end

function UICtx.rect_center(r: Rect): Vector2
	return Vector2.new((r.Min.X + r.Max.X) * 0.5, (r.Min.Y + r.Max.Y) * 0.5)
end

function UICtx.rect_equal_approx(a: Rect, b: Rect): boolean
	local e = 0.01
	return math.abs(a.Min.X - b.Min.X) < e
		and math.abs(a.Min.Y - b.Min.Y) < e
		and math.abs(a.Max.X - b.Max.X) < e
		and math.abs(a.Max.Y - b.Max.Y) < e
end

--- Reads a per-tile byte / int grid that may be a buffer (Core convention) or a 0-based table.
function UICtx.u8(grid: any, i: number): number
	if typeof(grid) == "buffer" then
		return buffer.readu8(grid, i)
	end
	return grid[i] or 0
end

function UICtx.i32(grid: any, i: number): number
	if typeof(grid) == "buffer" then
		return buffer.readi32(grid, i * 4)
	end
	return grid[i] or 0
end

-- =============================================================================================
-- Construction
-- =============================================================================================

export type Insets = { x: number, y: number, z: number, w: number }

function UICtx.new()
	local self = setmetatable({}, UICtx)
	self.state_bound = Signal.new()
	self.layout_changed = Signal.new()
	self.ratio_changed = Signal.new()
	self.local_changed = Signal.new()

	self.session = nil :: any
	self.world = nil :: any
	self.audio = nil :: any
	self.state = nil :: any
	--- Mode the bound state belongs to (a queued MP client still shows the title state).
	self.state_mode = UICtx.MODE_TITLE
	--- The UI root Frame (full screen) once UIRoot built it.
	self.root = nil :: any
	self.borders = (require("./BorderTracker") :: any).new()
	self.rules = nil :: any
	--- Persisted settings ([ui] section of the original's user://settings.cfg).
	self.settings = {} :: { [string]: any }

	-- Layout metrics (logical px = Roblox offsets)
	self.vp = Vector2.new(1600, 900)
	--- Safe area: left, top, right, bottom.
	self.insets = { x = 0, y = 0, z = 0, w = 0 } :: Insets
	--- Phone-sized viewport.
	self.compact = false
	--- Last pointer input was touch (or a touch device).
	self.touch = false
	--- Running on a phone / tablet (touch mode never switches off).
	self.touch_device = false
	--- The Rofront Staging experience, or Studio: staging-only tools show (Data/Products).
	self.staging = false
	if IS_ROBLOX then
		pcall(function()
			self.staging = UICtx.data("Staging").here() or game:GetService("RunService"):IsStudio()
		end)
	end
	--- Room for the single-row command bar.
	self.wide = true
	--- Top-left rectangle owned by the Roblox top bar row (+ our top-bar buttons) and the chat window.
	self.reserved_top_left = Rect.new(0, 0, 420, 320)
	--- The Roblox top bar button row (its buttons draw above our layer), padded.
	self.airship_bar = Rect.new(0, 0, 350, 58)

	self.ratio = UICtx.DEFAULT_RATIO
	--- The Attack bar stops here (1 = no cap) and an order leaves this share of the army's cap at home
	--- (nil = no floor): UI/Tutorial sets both while it runs.
	self.ratio_max = 1.0
	self.troop_floor = nil :: number?
	--- Tick at which the PLAYING phase began (match clock and durations come from game ticks).
	self.play_start_tick = -1.0
	--- Test hook: when X >= 0 this replaces the real pointer position.
	self.debug_mouse = Vector2.new(-1, -1)
	--- Viewport px of the UI root's origin (see update_origin).
	self.origin = Vector2.zero
	--- Last pointer position seen (logical px), kept by UIInteract (touches included).
	self.pointer = Vector2.new(-1, -1)
	--- Shared hover card (set by UIRoot).
	self.tooltip = nil :: any
	--- First-match coach marks (set by UIRoot).
	self.coach = nil :: any
	--- Last intents sent (tests use this to prove one tap = one order).
	self.sent_log = {} :: { any }
	self._sfx_last = {} :: { [string]: number }
	self._save_pending = false

	self.rules = (UICtx.mod("UIRules") :: any).new(self)
	self:_load_settings()
	-- (the Attack slider is not a saved setting any more: every match starts at DEFAULT_RATIO)
	self.ratio = UICtx.DEFAULT_RATIO
	UICtx.prime()
	return self
end

-- =============================================================================================
-- Raw drawing helpers (custom-drawn parts: radial ring, countdown arc, coach arrow, markers).
-- They build plain Roblox instances in LOGICAL px inside a "canvas" (a Frame with a UIScale =
-- UITheme.scale), so they line up with the kit's nodes.
-- =============================================================================================

--- Roblox TextSize for a Godot font size inside a logical canvas (the canvas' UIScale applies the
--- UI scale; Rubik line height = 1.185 em).
function UICtx.ts(size: number): number
	return math.max(1, math.floor(size * 1.185 + 0.5))
end

--- Top of a text line whose Godot baseline is at `baseline_y` (Rubik ascent 0.935 em).
function UICtx.top_for_baseline(baseline_y: number, size: number): number
	return baseline_y - 0.935 * size
end

local _shapes: any = nil
--- The static UI shapes manifest (Assets/UiShapes; {} when missing).
function UICtx.shapes(): any
	if _shapes == nil then
		local ok, m = pcall(function()
			if IS_ROBLOX then
				local rs = game:GetService("ReplicatedStorage")
				return require((rs:WaitForChild("Airfront") :: any):WaitForChild("Assets"):WaitForChild("UiShapes"))
			end
			return (require :: any)("../../shared/Assets/UiShapes")
		end)
		_shapes = if ok and type(m) == "table" then m else {}
	end
	return _shapes
end

--- New instance with properties.
function UICtx.make(class: string, props: { [string]: any }?, parent: Instance?): any
	local o = Instance.new(class)
	if props then
		for k, v in props do
			(o :: any)[k] = v
		end
	end
	if parent then
		o.Parent = parent
	end
	return o
end

--- Transparent frame (no border), positioned in offsets.
function UICtx.frame(parent: Instance?, pos: Vector2?, size: Vector2?): Frame
	local f = UICtx.make("Frame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset((pos or Vector2.zero).X, (pos or Vector2.zero).Y),
		Size = UDim2.fromOffset((size or Vector2.zero).X, (size or Vector2.zero).Y),
	}, parent)
	return f
end

--- A full-screen logical canvas: Frame sized to the logical viewport with a UIScale.
function UICtx.canvas(parent: Instance?, name: string?): Frame
	local f = UICtx.frame(parent)
	f.Name = name or "Canvas"
	UICtx.make("UIScale", { Name = "Scale", Scale = 1 }, f)
	return f
end

--- Resize a canvas to the current logical viewport / UI scale.
function UICtx.fit_canvas(self: any, f: Frame)
	f.Size = UDim2.fromOffset(self.vp.X, self.vp.Y)
	local us = f:FindFirstChild("Scale") :: UIScale?
	if us then
		us.Scale = self:ui_scale()
	end
end

--- A kit node (Widgets Control) whose `canvas` Frame is a logical-px drawing surface of the
--- node's size (UIScale = UI scale). `draw(node)` is called whenever the node is resized / the
--- scale changes (Godot _draw on resize). Used for custom-drawn widgets (arcs, arrows).
function UICtx.draw_node(draw: ((any) -> ())?): any
	local W = UICtx.mod("Widgets")
	local node = W.Control.new()
	node:set_mouse_filter(W.MOUSE_IGNORE)
	local canvas = UICtx.canvas(node.gui, "Draw")
	canvas.ZIndex = 1
	node.canvas = canvas
	node._draw_fn = draw
	node._on_geometry = function(self)
		self.canvas.Size = UDim2.fromOffset(self.size.X, self.size.Y)
		local us = self.canvas:FindFirstChild("Scale") :: UIScale
		local T = UICtx.mod("UITheme")
		us.Scale = T.scale
		if self._draw_fn then
			self._draw_fn(self)
		end
	end
	return node
end

--- Panel entrance (the original's UIWidgets.pop_in: fade + settle from 0.94 scale). Roblox re-lays
--- text at every intermediate UIScale (glyph sizes snap to whole px), so panels holding text settle
--- with a short rise instead of a scale: same timing (alpha over 0.8 dur, settle over dur), rise =
--- (1 - from_scale) * 100 px. `fade_only` for panels re-positioned every frame (the shift would be
--- overwritten) — they just fade.
function UICtx.pop_in(node: any, delay: number?, from_scale: number?, dur: number?, fade_only: boolean?)
	local W = UICtx.mod("Widgets")
	local d = delay or 0.0
	local du = dur or 0.4
	local rise = (1.0 - (from_scale or 0.96)) * 100.0
	if fade_only or node.parent == nil or node.parent._is_container then
		node:set_modulate_a(0.0)
		local t = node:create_tween()
		if d > 0 then
			t:tween_interval(d)
		end
		t:tween_property(node, "modulate:a", 1.0, du * 0.8):set_trans(W.TRANS_CUBIC):set_ease(W.EASE_OUT)
		return t
	end
	return W.slide_in(node, Vector2.new(0, rise), d, du)
end

--- Move a free (top-left anchored) kit node to `p` (logical px) without dirtying the whole tree:
--- per-frame followers (tooltip, coach card, placement buttons) only rewrite their own geometry.
--- The node keeps its size; offsets are kept in sync so later layout passes agree.
function UICtx.move_node(n: any, p: Vector2)
	n.offset_left, n.offset_top = p.X, p.Y
	n.offset_right, n.offset_bottom = p.X, p.Y
	if n.parent == nil then
		return
	end
	local min = n:get_combined_minimum_size()
	if n.size ~= min then
		n:reset_size()
		return
	end
	if n.position ~= p then
		n.position = p
		n:_write_geometry()
	end
end

--- Filled circle (Frame + UICorner), centred at `c` with radius `r`.
function UICtx.circle(parent: Instance?, c: Vector2, r: number, color: Color3, transparency: number?): Frame
	local f = UICtx.make("Frame", {
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(c.X, c.Y),
		Size = UDim2.fromOffset(r * 2, r * 2),
		BackgroundColor3 = color,
		BackgroundTransparency = transparency or 0,
	}, parent)
	UICtx.make("UICorner", { CornerRadius = UDim.new(0.5, 0) }, f)
	return f
end

--- Circle outline (UIStroke) of radius `r` (centre of the stroke) and `width`.
function UICtx.ring(
	parent: Instance?,
	c: Vector2,
	r: number,
	width: number,
	color: Color3,
	transparency: number?
): Frame
	local f = UICtx.circle(parent, c, r, color, 1)
	UICtx.make("UIStroke", {
		Name = "Stroke",
		Thickness = width,
		Color = color,
		Transparency = transparency or 0,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		BorderStrokePosition = Enum.BorderStrokePosition.Center,
	}, f)
	return f
end

function UICtx.set_circle(f: Frame, c: Vector2, r: number)
	f.Position = UDim2.fromOffset(c.X, c.Y)
	f.Size = UDim2.fromOffset(r * 2, r * 2)
end

--- Clockwise arc from 12 o'clock over `frac` (0..1) of a circle: two half-width clip frames, each
--- holding a stroked circle whose UIGradient hides everything past the arc end.
--- Returns an object: arc.frame, arc:set(frac, color?, transparency?), arc:place(center, r, width).
function UICtx.arc(parent: Instance?): any
	local holder = UICtx.frame(parent)
	holder.Name = "Arc"
	local halves = {}
	for side = 0, 1 do
		local clip = UICtx.frame(holder)
		clip.ClipsDescendants = true
		local c = UICtx.frame(clip)
		UICtx.make("UICorner", { CornerRadius = UDim.new(0.5, 0) }, c)
		local st = UICtx.make("UIStroke", {
			Thickness = 4,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			BorderStrokePosition = Enum.BorderStrokePosition.Center,
		}, c)
		local g = UICtx.make("UIGradient", {
			Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0),
				NumberSequenceKeypoint.new(0.4999, 0),
				NumberSequenceKeypoint.new(0.5001, 1),
				NumberSequenceKeypoint.new(1, 1),
			}),
		}, st)
		halves[side + 1] = { clip = clip, circle = c, stroke = st, grad = g }
	end
	local arc = { frame = holder, halves = halves, frac = -1 }
	--- Stroke centred on radius `r`, `width` wide.
	function arc.place(self: any, center: Vector2, r: number, width: number)
		local m = width -- margin so the AA edge is never clipped
		local size = (r + m) * 2
		holder.Position = UDim2.fromOffset(center.X - size / 2, center.Y - size / 2)
		holder.Size = UDim2.fromOffset(size, size)
		for i, h in self.halves do
			local right = i == 2
			h.clip.Position = UDim2.fromOffset(if right then size / 2 else 0, 0)
			h.clip.Size = UDim2.fromOffset(size / 2, size)
			h.circle.Position = UDim2.fromOffset(if right then -size / 2 + m else m, m)
			h.circle.Size = UDim2.fromOffset(r * 2, r * 2)
			h.stroke.Thickness = width
		end
	end
	function arc.set(self: any, frac: number, color: Color3?, transparency: number?)
		frac = math.clamp(frac, 0, 1)
		for i, h in self.halves do
			if color then
				h.stroke.Color = color
			end
			if transparency then
				h.stroke.Transparency = transparency
			end
			if frac ~= self.frac then
				if i == 2 then -- right half: 0 .. 0.5 of the circle
					local th = math.clamp(frac / 0.5, 0, 1) * 180
					h.grad.Rotation = th
					h.circle.Visible = th > 0.01
				else -- left half: 0.5 .. 1
					local th = math.clamp((frac - 0.5) / 0.5, 0, 1) * 180
					h.grad.Rotation = 180 + th
					h.circle.Visible = th > 0.01
				end
			end
		end
		self.frac = frac
	end
	return arc
end

-- =============================================================================================
-- Session / state
-- =============================================================================================

function UICtx.mode(self: any): number
	local s = self.session
	if s == nil then
		return UICtx.MODE_TITLE
	end
	return tonumber(s.mode) or UICtx.MODE_TITLE
end

function UICtx.in_match(self: any): boolean
	return self:mode() ~= UICtx.MODE_TITLE and self.state_mode == self:mode()
end

--- Waiting in the multiplayer queue (mode switched, match state not yet received).
function UICtx.mp_waiting(self: any): boolean
	return self:mode() == UICtx.MODE_MULTI and self.state_mode ~= UICtx.MODE_MULTI
end

function UICtx.me(self: any): number
	local s = self.state
	return if s ~= nil then (s.local_owner or 0) else 0
end

function UICtx.my(self: any): any
	local s = self.state
	if s == nil then
		return nil
	end
	return s:get_owner(s.local_owner)
end

--- A commander that still has to place a capital (spawn phase, or dropping into a running match).
function UICtx.needs_spawn(self: any): boolean
	local o = self:my()
	if o == nil or not o.alive or not self:in_match() or self.state == nil then
		return false
	end
	local ph = self.state.phase
	return (not o.spawned) and (ph == Defs.PHASE_SPAWN or ph == Defs.PHASE_PLAYING)
end

function UICtx.alive_player(self: any): boolean
	local o = self:my()
	return o ~= nil and o.alive and self:in_match()
end

function UICtx.lobby(self: any): { [string]: any }
	local s = self.session
	if s == nil then
		return {}
	end
	local l = s.lobby
	return if type(l) == "table" then l else {}
end

function UICtx.send(self: any, intent: { [string]: any })
	-- under a troop floor every attack is held to what may go, whoever built the order; one with
	-- nothing to send is not sent at all
	if self.troop_floor ~= nil and (intent.type == "attack" or intent.type == "boat") then
		local share = math.min(tonumber(intent.ratio) or self.ratio, self:floor_share())
		if share <= 0.001 then
			return
		end
		intent.ratio = share
	end
	table.insert(self.sent_log, { msec = UICtx.msec(), intent = intent })
	if #self.sent_log > 64 then
		table.remove(self.sent_log, 1)
	end
	local s = self.session
	if s ~= nil and type(s.send_intent) == "function" then
		s:send_intent(intent)
	end
	if self.telemetry ~= nil then
		self.telemetry:on_intent(intent)
	end
end

function UICtx.session_call(self: any, method: string, args: { any }?): any
	local s = self.session
	if s == nil then
		return nil
	end
	local f = s[method]
	if type(f) ~= "function" then
		return nil
	end
	if args then
		return f(s, table.unpack(args))
	end
	return f(s)
end

function UICtx.tick_seconds(_self: any, ticks: number): number
	return ticks / Defs.TICK_RATE
end

--- Seconds of play so far (from game ticks, so pausing / time-lapse are exact).
function UICtx.match_seconds(self: any): number
	if self.state == nil or self.play_start_tick < 0.0 then
		return 0.0
	end
	return math.max(0.0, (self:render_tick() - self.play_start_tick) / Defs.TICK_RATE)
end

--- Multiplayer match length in seconds (Session.MP_TIME_LIMIT_S when available).
function UICtx.match_limit_s(self: any): number
	local s = self.session
	if s ~= nil then
		local v = s.MP_TIME_LIMIT_S
		if type(v) == "number" then
			return v
		end
	end
	return 2400.0
end

--- Solo only: freeze the local simulation while a modal (help, game menu) is open.
function UICtx.set_paused(self: any, on: boolean)
	if self:mode() == UICtx.MODE_SOLO then
		self:session_call("set_paused", { on })
	end
end

--- Static helper on Core/Rules when present (feature-detected; returns nil otherwise).
function UICtx.rules_call(_self: any, method: string, args: { any }?): any
	local ok, Rules = pcall(core, "Rules")
	if not ok or type(Rules) ~= "table" then
		return nil
	end
	local f = Rules[method]
	if type(f) ~= "function" then
		return nil
	end
	if args then
		return f(table.unpack(args))
	end
	return f()
end

function UICtx.render_tick(self: any): number
	local s = self.state
	if s == nil then
		return 0.0
	end
	return math.max(s.render_tick or 0, s.tick or 0)
end

-- =============================================================================================
-- World
-- =============================================================================================

function UICtx.world_call(self: any, method: string, args: { any }?): any
	local w = self.world
	if w == nil then
		return nil
	end
	local f = w[method]
	if type(f) ~= "function" then
		return nil
	end
	if args then
		return f(w, table.unpack(args))
	end
	return f(w)
end

function UICtx.set_world_input(self: any, on: boolean)
	local w = self.world
	if w == nil then
		return
	end
	if type(w.set_input_enabled) == "function" then
		w:set_input_enabled(on)
	else
		w.input_enabled = on
	end
end

--- WorldView.set_aim(kind, tile, radius_tiles, valid, detail, level): detail = what is aimed
--- ("sam", "defense", "city", "atom"...), level = the structure's level after this placement
--- (1 new, current + 1 for an upgrade).
function UICtx.set_aim(
	self: any,
	kind: string,
	tile: number,
	radius: number,
	valid: boolean?,
	detail: string?,
	level: number?
)
	self:world_call("set_aim", { kind, tile, radius, if valid == nil then true else valid, detail or "", level or 1 })
end

--- Pointer position in logical px.
function UICtx.mouse_pos(self: any): Vector2
	if self.debug_mouse.X >= 0.0 then
		return self.debug_mouse
	end
	if self.touch and self.pointer.X >= 0.0 then
		return self.pointer
	end
	if IS_ROBLOX then
		return self:to_logical(game:GetService("UserInputService"):GetMouseLocation())
	end
	return if self.pointer.X >= 0 then self.pointer else Vector2.zero
end

local _Widgets: any = nil
local function widgets(): any
	if _Widgets == nil and IS_ROBLOX then
		local ok, w = pcall(require, script.Parent:FindFirstChild("Widgets"))
		_Widgets = if ok then w else false
	end
	return _Widgets
end

--- Where the UI root's (0, 0) lies in viewport px. On notched phones the camera viewport is the
--- device safe area while our full-screen root starts left of it (Studio iPhone 13: root at
--- viewport x = -47), so every conversion goes through this origin. Refreshed by UIRoot._layout.
function UICtx.update_origin(self: any)
	local r = self.root
	if r == nil or not IS_ROBLOX then
		return
	end
	local g = r.gui
	if g ~= nil then
		self.origin = g.AbsolutePosition + game:GetService("GuiService"):GetGuiInset()
	end
end

--- Viewport px -> logical px (identity when no UI scale is active, e.g. in Lune).
function UICtx.to_logical(self: any, v: Vector2): Vector2
	local W = widgets()
	local o = self.origin or Vector2.zero
	if W and W.to_logical then
		return W.to_logical(v - o)
	end
	return v - o
end

--- Logical px -> viewport px.
function UICtx.to_view(self: any, v: Vector2): Vector2
	local W = widgets()
	local o = self.origin or Vector2.zero
	if W and W.to_view then
		return W.to_view(v) + o
	end
	return v + o
end

--- Logical Rect -> viewport Rect.
function UICtx.rect_to_view(self: any, r: Rect): Rect
	local a = self:to_view(r.Min)
	local b = self:to_view(r.Max)
	return Rect.new(a.X, a.Y, b.X, b.Y)
end

--- UI scale (viewport px per logical px).
function UICtx.ui_scale(self: any): number
	local one = self:to_view(Vector2.new(100, 0)) - self:to_view(Vector2.zero)
	return one.X / 100
end

--- A viewport-px rect in logical px.
function UICtx.rect_to_logical(self: any, r: Rect): Rect
	local a = self:to_logical(r.Min)
	local b = self:to_logical(r.Max)
	return Rect.new(a.X, a.Y, b.X, b.Y)
end

--- Tile under a LOGICAL screen point (-1 if none): WorldView.tile_at_screen in viewport px.
function UICtx.tile_at(self: any, pos: Vector2): number
	local v = self:world_call("tile_at_screen", { self:to_view(pos) })
	return if type(v) == "number" then v else -1
end

--- Screen area modals and transient pop-ups may use: inside the safe area and, on phones, below
--- the Roblox top bar row (its buttons draw above our layer).
function UICtx.clear_rect(self: any): Rect
	local ins = self.insets
	local top = math.max(ins.y, self.airship_bar.Max.Y)
	if self.compact then
		top = math.max(top, self.reserved_top_left.Max.Y)
	end
	return UICtx.rect(ins.x, top, self.vp.X - ins.x - ins.z, self.vp.Y - top - ins.w)
end

--- Where a top-centred panel of width `w` can sit at height `y` without touching the top-left
--- reserved HUD: returns dx from centre, top. Shifts right when there is room, otherwise drops the
--- panel below the top bar row.
function UICtx.place_top(self: any, w: number, y: number): (number, number)
	local margin = 8.0
	local left = (self.vp.X - w) * 0.5
	local res = self.reserved_top_left
	if y >= res.Max.Y or left >= res.Max.X + margin then
		return 0.0, y
	end
	local dx = res.Max.X + margin - left
	if left + dx + w <= self.vp.X - self.insets.z - margin then
		return dx, y
	end
	return 0.0, res.Max.Y + 4.0
end

--- Horizontal nudge for a top-centred panel of width `w` so it clears the reserved top-left area.
function UICtx.clear_of_reserved(self: any, w: number): number
	local min_left = self.reserved_top_left.Max.X + 12.0
	local left = (self.vp.X - w) * 0.5
	return math.max(0.0, min_left - left)
end

--- Screen position of a tile in LOGICAL px, (-1, -1) on the far side / without a world.
function UICtx.tile_screen_pos(self: any, tile: number): Vector2
	local v = self:world_call("screen_pos_of_tile", { tile })
	if typeof(v) ~= "Vector2" or v.X < 0 then
		return Vector2.new(-1, -1)
	end
	return self:to_logical(v)
end

-- =============================================================================================
-- Audio
-- =============================================================================================

--- `pitch`: an exact playback speed (instead of the small random jitter).
function UICtx.sfx(self: any, id: string, volume_db: number?, pitch_jitter: number?, pitch: number?)
	local a = self.audio
	if a == nil or type(a.play_sfx) ~= "function" then
		return
	end
	-- (a sound was asked for: Widgets' default button press / hover sounds stay out of its way)
	local Wm = UICtx.mod("Widgets")
	Wm.sound_serial = (Wm.sound_serial or 0) + 1
	local now = UICtx.msec()
	local gap = UICtx.SFX_GAP[id] or 60
	if now - (self._sfx_last[id] or -100000) < gap then
		return
	end
	self._sfx_last[id] = now
	local sfx_name = UICtx.SFX[id] or id
	local fb = UICtx.SFX_FALLBACK[id]
	if fb and type(a.has_sfx) == "function" and not a:has_sfx(sfx_name) then
		sfx_name = fb
	end
	a:play_sfx(sfx_name, volume_db or 0.0, if pitch_jitter == nil then 0.04 else pitch_jitter, pitch)
end

function UICtx.music_enabled(self: any): boolean
	local a = self.audio
	if a ~= nil and type(a.is_music_enabled) == "function" then
		return a:is_music_enabled() and true or false
	end
	return true
end

function UICtx.set_music(self: any, on: boolean)
	local a = self.audio
	if a ~= nil and type(a.set_music_enabled) == "function" then
		a:set_music_enabled(on)
	end
end

--- The player's music level, 0..1 (Settings slider; AudioDirector.set_music_volume).
function UICtx.music_volume(self: any): number
	local a = self.audio
	if a ~= nil and type(a.music_volume) == "function" then
		return a:music_volume()
	end
	return 1.0
end

--- `save`: write it to the saved settings (at the end of a drag).
function UICtx.set_music_volume(self: any, v: number, save: boolean?)
	local a = self.audio
	if a ~= nil and type(a.set_music_volume) == "function" then
		a:set_music_volume(v, save)
	end
end

--- The border pops (AudioDirector.pop) are on (Settings).
function UICtx.pops_enabled(self: any): boolean
	local a = self.audio
	if a ~= nil and type(a.is_pops_enabled) == "function" then
		return a:is_pops_enabled() and true or false
	end
	return true
end

function UICtx.set_pops(self: any, on: boolean)
	local a = self.audio
	if a ~= nil and type(a.set_pops_enabled) == "function" then
		a:set_pops_enabled(on)
	end
end

--- The soundtrack's mood (AudioDirector.set_music_mood).
function UICtx.set_music_mood(self: any, mood: string)
	local a = self.audio
	if a ~= nil and type(a.set_music_mood) == "function" then
		a:set_music_mood(mood)
	elseif a ~= nil and type(a.play_theme) == "function" then
		a:play_theme(if mood == "title" or mood == "wait" then "menu" else "war")
	end
end

function UICtx.play_theme(self: any, theme_name: string)
	local a = self.audio
	if a ~= nil and type(a.play_theme) == "function" then
		a:play_theme(theme_name)
	end
end

-- =============================================================================================
-- Attack ratio & settings
-- =============================================================================================

--- The most of the army any order may send now: what stands above `troop_floor` (a share of the
--- army's cap that stays at home; nil = no floor, 1). Under 2% counts as nothing (0).
function UICtx.floor_share(self: any): number
	local f = self.troop_floor
	local o = self:my()
	if f == nil or o == nil or (o.max_troops or 0) <= 0 or (o.troops or 0) <= 0 then
		return 1.0
	end
	local allowed = (o.troops - f * o.max_troops) / o.troops
	return if allowed < 0.02 then 0.0 else math.min(allowed, 1.0)
end

--- The share of the army an order sends now: the slider's, trimmed to floor_share(). 0: nothing may go.
function UICtx.order_ratio(self: any): number
	return math.min(self.ratio, self:floor_share())
end

--- The stop nearest `r` among those not above `max` (the lowest stop when none is), and its index
--- in RATIO_STOPS. Half way between two stops is the lower one.
function UICtx.ratio_stop(r: number, max: number?): (number, number)
	local stops = UICtx.RATIO_STOPS
	local top = (max or 1.0) + 1e-6
	local best = 1
	for i = 2, #stops do
		if stops[i] <= top and math.abs(stops[i] - r) < math.abs(stops[best] - r) - 1e-9 then
			best = i
		end
	end
	return stops[best], best
end

--- The Attack ratio: the stop nearest `r` that ratio_max allows.
function UICtx.set_ratio(self: any, r: number)
	local v = UICtx.ratio_stop(r, self.ratio_max)
	if math.abs(v - self.ratio) < 1e-5 then
		return
	end
	self.ratio = v
	self.ratio_changed:Fire(v)
end

--- The highest share the Attack bar gives (1: every stop). The tutorial lowers it while it runs: the
--- ratio comes down to it, and the bar is told either way (it draws the stops above the cap faint).
function UICtx.set_ratio_max(self: any, max: number)
	self.ratio_max = max
	self.ratio = UICtx.ratio_stop(self.ratio, max)
	self.ratio_changed:Fire(self.ratio)
end

--- One stop up (`dir` > 0) or down: the Q / E keys and the mouse wheel.
function UICtx.step_ratio(self: any, dir: number)
	local stops = UICtx.RATIO_STOPS
	local _, i = UICtx.ratio_stop(self.ratio, self.ratio_max)
	self:set_ratio(stops[math.clamp(i + (if dir > 0 then 1 else -1), 1, #stops)])
end

--- The Attack bar back at DEFAULT_RATIO: every match starts there (since 2026-10-08, at first at a
--- 20% troop share; the default has since become the 25% stop, see
--- RATIO_STOPS). Until then the slider's last position was saved with the settings and came back in
--- the next match, and the next session.
function UICtx.reset_ratio(self: any)
	self:set_ratio(UICtx.DEFAULT_RATIO)
end

--- Troops sent by an attack at the current ratio.
function UICtx.troops_for_ratio(self: any): number
	local o = self:my()
	return if o ~= nil then (o.troops or 0) * self:order_ratio() else 0.0
end

function UICtx.setting(self: any, key: string, default: any): any
	local v = self.settings[key]
	if v == nil then
		return default
	end
	return v
end

function UICtx.set_setting(self: any, key: string, value: any)
	self.settings[key] = value
	self:_save_later()
end

--- Loads the [ui] section through Session:load_settings("ui") when the session provides one
--- (Roblox has no client-side files: the session persists it, e.g. in a DataStore).
function UICtx._load_settings(self: any)
	local v = self:session_call("load_settings", { "ui" })
	if type(v) == "table" then
		for k, val in v do
			self.settings[k] = val
		end
	end
end

--- Re-read settings once a session is attached (UIRoot.setup).
function UICtx.reload_settings(self: any)
	self:_load_settings()
end

function UICtx._save_later(self: any)
	if self._save_pending then
		return
	end
	self._save_pending = true
	task.delay(0.6, function()
		self._save_pending = false
		self:_save_now()
	end)
end

function UICtx._save_now(self: any)
	self:session_call("save_settings", { "ui", table.clone(self.settings) })
end

-- =============================================================================================
-- Hints (hover cards anchored to controls; suppressed on touch)
-- =============================================================================================

function UICtx.show_hint(self: any, anchor: GuiObject, spec: { [string]: any }, force: boolean?)
	if self.tooltip ~= nil and (force or not self.touch) then
		self.tooltip:show_anchor(spec, anchor)
	end
end

function UICtx.hide_hint(self: any, anchor: GuiObject?)
	local tt = self.tooltip
	if tt == nil or tt.place ~= tt.Place.ANCHOR then
		return
	end
	if anchor == nil or tt:anchor_is(anchor) then
		tt:hide_tip()
	end
end

-- =============================================================================================
-- Platform
-- =============================================================================================

--- The Roblox escape menu is open (hotkeys must not act under it).
function UICtx.pause_menu_open(_self: any): boolean
	if not IS_ROBLOX then
		return false
	end
	return game:GetService("GuiService").MenuIsOpen
end

function UICtx.username(self: any): string
	if IS_ROBLOX then
		local lp = game:GetService("Players").LocalPlayer
		if lp ~= nil and lp.DisplayName ~= "" then
			return lp.DisplayName
		end
	end
	local d = self:session_call("local_display_name")
	return if type(d) == "string" and d ~= "" then d else "Commander"
end

-- =============================================================================================
-- Owners
-- =============================================================================================

--- Progress toward victory: share of the land that is not fallout (the Sim wins at
--- Rules.WIN_SHARE of contestable land minus fallout).
function UICtx.win_share(self: any, id: number): number
	local s = self.state
	if s == nil or s.map == nil then
		return 0.0
	end
	local o = s:get_owner(id)
	if o == nil then
		return 0.0
	end
	local fo = tonumber(s.fallout_count) or 0
	local denom = (s.map.contestable_count or 1) - fo
	return (o.tiles or 0) / math.max(denom, 1)
end

--- A team game: team `t`'s progress toward victory (its members' land together; Sim._check_victory).
function UICtx.team_share(self: any, t: number): number
	local s = self.state
	if s == nil or s.map == nil or t == 0 then
		return 0.0
	end
	local tiles = 0
	for _, o in s.owners do
		if o.team == t and o.alive then
			tiles += o.tiles or 0
		end
	end
	local fo = tonumber(s.fallout_count) or 0
	return tiles / math.max((s.map.contestable_count or 1) - fo, 1)
end

--- A team game: the team's name as players read it ("Red team", "Team 3", "Humans").
function UICtx.team_label(self: any, t: number): string
	local s = self.state
	local n = if s ~= nil and type(s.team_name) == "function" then s:team_name(t) else ""
	if n == "" then
		return ""
	end
	if string.sub(n, 1, 5) == "Team " or n == "Humans" or n == "Nations" then
		return n
	end
	return n .. " team"
end

--- "You", "Teammate", "Ally", "Traitor", "At war", "Neutral".
function UICtx.relation(self: any, id: number): string
	local s = self.state
	if s == nil or id == 0 then
		return ""
	end
	if id == self:me() then
		return "You"
	end
	if type(s.same_team) == "function" and s:same_team(self:me(), id) then
		return "Teammate"
	end
	if s:are_allies(self:me(), id) then
		return "Ally"
	end
	if s:is_traitor(id) then
		return "Traitor"
	end
	if self:at_war(id) then
		return "At war"
	end
	return "Neutral"
end

function UICtx.relation_color(_self: any, rel: string): Color3
	local T = UICtx.mod("UITheme")
	if rel == "You" then
		return T.AMBER
	elseif rel == "Ally" or rel == "Teammate" then
		return T.GREEN
	elseif rel == "Traitor" then
		return T.RED
	elseif rel == "At war" then
		return T.ORANGE
	end
	return T.TEXT_2
end

function UICtx.at_war(self: any, id: number): boolean
	local s = self.state
	local me = self:me()
	if s == nil or me == 0 then
		return false
	end
	for _, a in s.attacks do
		if (a.attacker == me and a.target == id) or (a.attacker == id and a.target == me) then
			return true
		end
	end
	return false
end

function UICtx.kind_title(_self: any, kind: number): string
	if kind == Defs.KIND_TRIBE then
		return "Tribe"
	elseif kind == Defs.KIND_HUMAN then
		return "Commander"
	end
	return "Nation"
end

function UICtx.terrain_at(self: any, tile: number): number
	local map = self.state.map
	if type(map.terrain_at) == "function" then
		return map:terrain_at(tile)
	end
	return UICtx.u8(map.terrain, tile)
end

function UICtx.terrain_title(self: any, tile: number): string
	local s = self.state
	if s == nil or tile < 0 then
		return ""
	end
	if s:has_fallout(tile) then
		return "Fallout"
	end
	local t = self:terrain_at(tile)
	if t == Defs.T_OCEAN then
		return "Ocean"
	elseif t == Defs.T_LAKE then
		return "Lake"
	elseif t == Defs.T_PLAINS then
		return "Plains"
	elseif t == Defs.T_HIGHLAND then
		return "Highland"
	elseif t == Defs.T_MOUNTAIN then
		return "Mountains"
	elseif t == Defs.T_TUNDRA then
		return "Tundra"
	elseif t == Defs.T_ICECAP then
		return "Ice cap"
	end
	return ""
end

--- Structure within `radius` tiles of `tile` (exact tile first), or nil. Ties go to the oldest
--- structure (the GDScript dictionary iterated in insertion order).
function UICtx.structure_at(self: any, tile: number, radius: number?): any
	local s = self.state
	if s == nil or tile < 0 then
		return nil
	end
	local r = radius or 1
	local W = if s.map then s.map.W else Defs.W
	local tx = tile % W
	local ty = tile // W
	local best = nil
	local best_d = 2 ^ 30
	for _, st in s.structures do
		local dx = math.abs(st.tile % W - tx)
		local dy = math.abs(st.tile // W - ty)
		local d = math.max(dx, dy)
		if d <= r and (d < best_d or (d == best_d and best ~= nil and st.sid < best.sid)) then
			best = st
			best_d = d
		end
	end
	return best
end

return UICtx
