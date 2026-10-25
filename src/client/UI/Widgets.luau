--!nonstrict
-- Port of scripts/ui/widgets.gd (UIWidgets animation helpers) plus the kit's Control engine.
--
-- The original UI is built from Godot Controls and Containers. Roblox auto-layout cannot express
-- them exactly (expand / shrink flags, minimum sizes, fixed-width tabular numbers, letter
-- spacing, synchronous size queries), so this module implements a small Control tree with Godot
-- semantics that renders to Roblox GuiObjects:
--
--   Control   free children placed by anchors / offsets / grow direction (Godot Control)
--   Box       HBoxContainer / VBoxContainer (separation, alignment, size flags, stretch)
--   Panel     PanelContainer with a "panel" style (StyleBoxFlat); Margin = MarginContainer
--   Label     Rubik text (alignment, clip / ellipsis, autowrap, letter spacing, tabular digits)
--   Icon      TextureRect (UiIcons glyph, tint);  ColorRect
--   Button    Button with theme variations (UITheme.theme()), icon + text, toggle mode
--   Root      top-level node bound to a ScreenGui / Frame; owns the UI scale & logical viewport
--
-- Every node has `node.gui` (its Roblox GuiObject). Sizes and positions are logical px (Godot px);
-- the engine renders them at UITheme.scale, pixel-snapped. Layout is recomputed for dirty trees
-- once per frame (Widgets.step) and synchronously whenever a size is queried.
-- Tweens follow Godot's Tween API and easing equations exactly (create_tween, tween_property,
-- set_trans / set_ease, set_parallel, chain, tween_interval, tween_callback, tween_method).

-- (Lune: no services; the driver / tween / timer code still runs headless in tests.)
local RunService = if (game :: any) ~= nil then game:GetService("RunService") else nil :: any
local UserInputService = if (game :: any) ~= nil then game:GetService("UserInputService") else nil :: any
local GuiService = if (game :: any) ~= nil then game:GetService("GuiService") else nil :: any

local UITheme = require("./UITheme")
local Signal = UITheme.core("Signal")

local W = {}

-- =============================================================================================
-- Constants (Godot enums)
-- =============================================================================================

W.SHRINK_BEGIN = 0
W.FILL = 1
W.EXPAND = 2
W.EXPAND_FILL = 3
W.SHRINK_CENTER = 4
W.SHRINK_END = 8

W.GROW_BEGIN = 0
W.GROW_END = 1
W.GROW_BOTH = 2

W.MOUSE_STOP = 0
W.MOUSE_PASS = 1
W.MOUSE_IGNORE = 2

W.ALIGN_BEGIN = 0
W.ALIGN_CENTER = 1
W.ALIGN_END = 2
-- horizontal / vertical text & icon alignment
W.ALIGN_LEFT = 0
W.ALIGN_RIGHT = 2
W.VALIGN_TOP = 0
W.VALIGN_CENTER = 1
W.VALIGN_BOTTOM = 2

W.OVERRUN_NONE = 0
W.OVERRUN_ELLIPSIS = 1

-- Godot Control.LayoutPreset (the ones the UI uses)
W.PRESET_TOP_LEFT = 0
W.PRESET_FULL_RECT = 15
W.PRESET_BOTTOM_WIDE = 12
W.PRESET_TOP_WIDE = 10
W.PRESET_CENTER = 8

-- Tween transitions / eases
W.TRANS_LINEAR = 0
W.TRANS_SINE = 1
W.TRANS_QUINT = 2
W.TRANS_QUART = 3
W.TRANS_QUAD = 4
W.TRANS_EXPO = 5
W.TRANS_ELASTIC = 6
W.TRANS_CUBIC = 7
W.TRANS_CIRC = 8
W.TRANS_BOUNCE = 9
W.TRANS_BACK = 10
W.TRANS_SPRING = 11
W.EASE_IN = 0
W.EASE_OUT = 1
W.EASE_IN_OUT = 2
W.EASE_OUT_IN = 3

local Z_CONTENT = 10 -- children render above a node's own parts (parts use ZIndex 1..9)

-- =============================================================================================
-- Scale & coordinate helpers
-- =============================================================================================

function W.scale(): number
	return UITheme.scale
end

--- Viewport px -> logical px.
function W.to_logical(v: Vector2): Vector2
	return v / UITheme.scale
end

--- Logical px -> viewport px.
function W.to_view(v: Vector2): Vector2
	return v * UITheme.scale
end

function W.rect_to_view(r: Rect): Rect
	local s = UITheme.scale
	return Rect.new(r.Min.X * s, r.Min.Y * s, r.Max.X * s, r.Max.Y * s)
end

function W.rect_to_logical(r: Rect): Rect
	local s = UITheme.scale
	return Rect.new(r.Min.X / s, r.Min.Y / s, r.Max.X / s, r.Max.Y / s)
end

--- Screen position (viewport px, GetMouseLocation space) -> logical px of the node tree that
--- `node` belongs to (relative to its Root's top-left; the Root normally fills the screen).
function W.screen_to_logical(v: Vector2, node: any?): Vector2
	local root = node and node.root
	if root ~= nil and root.gui ~= nil then
		local inset = GuiService:GetGuiInset()
		local o = root.gui.AbsolutePosition + inset
		return (v - o) / UITheme.scale
	end
	return v / UITheme.scale
end

--- Pointer position of an InputObject in viewport px (the space of GetMouseLocation()).
function W.input_pos(input: InputObject): Vector2
	if input.UserInputType == Enum.UserInputType.Touch then
		local inset = GuiService:GetGuiInset()
		return Vector2.new(input.Position.X, input.Position.Y) + inset
	end
	return UserInputService:GetMouseLocation()
end

local function px(v: number): number
	return math.floor(v * UITheme.scale + 0.5)
end
W.px = px

-- =============================================================================================
-- Driver: tweens, per-frame processing, timers, deferred calls, layout flush
-- =============================================================================================

local _roots = {} -- Root nodes
UITheme.fonts_loaded = Signal.new()
local _process = {} -- node -> true
local _tweens = {} -- list of Tween
local _timers = {} -- list of {t, fn, cancelled}
local _deferred = {} -- list of fn (filled while _deferred_run executes)
local _deferred_run = {} -- the list being executed this frame (double-buffered, no per-frame alloc)
local _due = {} -- scratch: timers due this frame
local _proc_list = {} -- scratch: processing nodes this frame
local _driver: RBXScriptConnection? = nil
local _flush_bound = false
W.time = 0.0
--- Default button sounds: UIRoot sets `button_sound(kind: "press" | "tab" | "hover", button)`; a
--- button whose own handlers asked for a sound (UICtx.sfx bumps `sound_serial`) is left alone, and
--- a button with `silent = true` never makes one.
W.sound_serial = 0
W.button_sound = nil :: ((string, any) -> ())?

-- ---------------------------------------------------------------------------------------------
-- Error isolation. Every unit of per-frame work (deferred call, timer, tweener callback, node
-- _process, layout flush, UIRoot component update) runs under xpcall: one broken callback is reported
-- (once per distinct error) and never stops the rest of the frame — otherwise a persistent error
-- would freeze every tween and all layout, i.e. the whole HUD.
-- ---------------------------------------------------------------------------------------------

local _reported: { [string]: boolean } = {}
local _reported_n = 0
W.MAX_REPORTED_ERRORS = 64
--- Error counts (tests / diagnostics): total errors caught, distinct errors reported.
W.errors = { caught = 0, reported = 0 }
--- Where reports go (tests may replace it).
W.report_sink = (warn :: any) or print

--- Report a caught UI error once per distinct (site, message) pair.
function W.report_error(site: string, err: any)
	W.errors.caught += 1
	local text = tostring(err)
	local key = site .. "|" .. (string.match(text, "^[^\n]*") or "")
	if _reported[key] then
		return
	end
	if _reported_n >= W.MAX_REPORTED_ERRORS then
		if _reported_n == W.MAX_REPORTED_ERRORS then
			_reported_n += 1
			W.report_sink("[UI] further UI errors are not reported")
		end
		return
	end
	_reported[key] = true
	_reported_n += 1
	W.errors.reported += 1
	W.report_sink(string.format("[UI] %s failed: %s", site, text))
end

local traceback = debug.traceback

--- Calls fn(...) under xpcall; a failure is reported for `site`. Returns true when fn succeeded.
function W.guard(site: string, fn: (...any) -> ...any, ...: any): boolean
	local ok, err = xpcall(fn, traceback, ...)
	if not ok then
		W.report_error(site, err)
	end
	return ok
end
local guard = W.guard

local function flush_root(r)
	r:_flush()
end

local function flush_all()
	for _, r in ipairs(_roots) do
		guard("layout", flush_root, r)
	end
end
W.flush = flush_all

--- Tests: the live list of Root nodes the driver flushes.
function W._roots_for_tests()
	return _roots
end

--- Run tweens, processing nodes, timers and deferred calls, then lay out dirty trees.
--- Kit CPU cost per frame (ms, exponential average) and the last frame's flush cost.
W.stats = { step_ms = 0.0, max_ms = 0.0, flush_ms = 0.0 }

function W.step(dt: number)
	local t0 = os.clock()
	W._step(dt)
	local ms = (os.clock() - t0) * 1000.0
	local st = W.stats
	st.step_ms = st.step_ms + (ms - st.step_ms) * 0.05
	st.max_ms = math.max(st.max_ms * 0.995, ms)
end

local function step_tween(tw, dt: number)
	tw:_step(dt)
end

local function process_node(n, dt: number)
	n:_process(dt)
end

function W._step(dt: number)
	W.time += dt
	if #_deferred > 0 then
		-- swap the buffers: calls deferred while these run go to the next frame
		local list = _deferred
		_deferred = _deferred_run
		_deferred_run = list
		for i = 1, #list do
			guard("deferred call", list[i])
		end
		table.clear(list)
	end
	if #_timers > 0 then
		local now = W.time
		local due = _due
		for i = #_timers, 1, -1 do
			local t = _timers[i]
			if t.cancelled then
				table.remove(_timers, i)
			elseif now >= t.t then
				table.remove(_timers, i)
				table.insert(due, t)
			end
		end
		-- collected newest-index first: run in creation order
		for i = #due, 1, -1 do
			local t = due[i]
			due[i] = nil
			guard("timer", t.fn)
		end
	end
	local nt = #_tweens
	if nt > 0 then
		-- Tweens created while stepping are appended past `nt` and start next frame (as before);
		-- finished ones are compacted afterwards, so indices are stable during the loop.
		for i = 1, nt do
			local tw = _tweens[i]
			if tw._alive and not guard("tween", step_tween, tw, dt) then
				tw._alive = false -- the tween machinery itself failed (user callbacks are guarded inside)
			end
		end
		local j = 0
		for i = 1, #_tweens do
			local tw = _tweens[i]
			if tw._alive then
				j += 1
				_tweens[j] = tw
			end
		end
		for i = #_tweens, j + 1, -1 do
			_tweens[i] = nil
		end
	end
	if next(_process) ~= nil then
		local list = _proc_list
		for n in pairs(_process) do
			table.insert(list, n)
		end
		for i = 1, #list do
			local n = list[i]
			list[i] = nil
			if _process[n] and not n._freed then
				guard("_process", process_node, n, dt)
			end
		end
	end
	flush_all()
end

--- Start the kit's own frame driver (idempotent). UIRoot may instead call Widgets.step(dt)
--- itself: call Widgets.set_external_driver(true) first.
function W.start_driver()
	if _driver ~= nil or _flush_bound then
		return
	end
	_driver = RunService.RenderStepped:Connect(function(dt)
		W.step(dt)
	end)
end

function W.set_external_driver(on: boolean)
	if on and _driver ~= nil then
		_driver:Disconnect()
		_driver = nil
	elseif not on then
		W.start_driver()
	end
	_flush_bound = on
end

--- get_tree().create_timer(sec).timeout.connect(fn): returns a handle with :cancel().
function W.timer(sec: number, fn: () -> ())
	local h = { t = W.time + sec, fn = fn, cancelled = false }
	function h.cancel()
		h.cancelled = true
	end
	table.insert(_timers, h)
	return h
end

--- call_deferred: run at the start of the next Widgets.step.
function W.defer(fn: () -> ())
	table.insert(_deferred, fn)
end

-- =============================================================================================
-- Class helper (methods + lazily created signals)
-- =============================================================================================

local SIGNALS = {
	resized = true,
	visibility_changed = true,
	item_rect_changed = true,
	mouse_entered = true,
	mouse_exited = true,
	gui_input = true,
	tree_exiting = true,
}

local function class(base)
	local methods = {}
	local mt = {}
	methods.__class = methods
	methods.__base = base
	mt.__index = function(t, k)
		local v = methods[k]
		if v ~= nil then
			return v
		end
		local b = base
		while b ~= nil do
			v = rawget(b, k)
			if v ~= nil then
				return v
			end
			b = rawget(b, "__base")
		end
		if SIGNALS[k] then
			local s = Signal.new()
			rawset(t, k, s)
			local hook = t._on_signal_created
			if hook then
				hook(t, k)
			end
			return s
		end
		return nil
	end
	methods.__mt = mt
	return methods
end
W.class = class

local function new_of(cls)
	return setmetatable({}, cls.__mt)
end

-- =============================================================================================
-- Control
-- =============================================================================================

local Control = class(nil)
W.Control = Control

local function make_gui(class_name: string?): GuiObject
	local g = Instance.new(class_name or "Frame")
	g.BackgroundTransparency = 1
	g.BorderSizePixel = 0
	g.AnchorPoint = Vector2.new(0.5, 0.5)
	g.Size = UDim2.fromOffset(0, 0)
	if g:IsA("GuiButton") then
		g.AutoButtonColor = false
		g.Selectable = false
		if g:IsA("TextButton") then
			g.Text = ""
		end
	end
	if g:IsA("Frame") then
		(g :: Frame).Active = false
	end
	return g
end
W.make_gui = make_gui

function Control._init(self, gui_class: string?, gui: GuiObject?)
	self.gui = gui or make_gui(gui_class)
	self.children = {}
	self._internal = {}
	--- inside a kit button: never sinks input (see _mark_in_button)
	self._in_button = false
	self.parent = nil
	self.root = nil
	self.visible = true
	self.custom_minimum_size = Vector2.zero
	self.size_flags_horizontal = W.FILL
	self.size_flags_vertical = W.FILL
	self.size_flags_stretch_ratio = 1.0
	self.anchor_left = 0.0
	self.anchor_top = 0.0
	self.anchor_right = 0.0
	self.anchor_bottom = 0.0
	self.offset_left = 0.0
	self.offset_top = 0.0
	self.offset_right = 0.0
	self.offset_bottom = 0.0
	self.grow_horizontal = W.GROW_END
	self.grow_vertical = W.GROW_END
	self.position = Vector2.zero
	self.size = Vector2.zero
	self.modulate_a = 1.0
	self._eff_a = 1.0
	self._parts = {}
	self._scale = 1.0
	self.rotation = 0.0
	self.mouse_filter = W.MOUSE_STOP
	self._min_dirty = true
	self._min_cache = Vector2.zero
	self._min_gen = -1
	self._needs_layout = true
	self._geo = nil
	self._freed = false
	self._conns = {}
	self._meta = {}
	self.name = ""
	self:set_mouse_filter(W.MOUSE_STOP)
end

function Control.new(gui_class: string?)
	local self = new_of(Control)
	self:_init(gui_class)
	return self
end

-- --- meta (Godot set_meta / get_meta / has_meta) ----------------------------------------------

function Control.set_meta(self, k: string, v: any)
	self._meta[k] = v
end

function Control.get_meta(self, k: string, default: any?): any
	local v = self._meta[k]
	if v == nil then
		return default
	end
	return v
end

function Control.has_meta(self, k: string): boolean
	return self._meta[k] ~= nil
end

function Control.remove_meta(self, k: string)
	self._meta[k] = nil
end

-- --- tree ---------------------------------------------------------------------------------------

function Control._content_gui(self): GuiObject
	return self.gui
end

function Control._renumber(self)
	for i, c in ipairs(self.children) do
		c.gui.ZIndex = Z_CONTENT + i
	end
end

function Control._set_root(self, r)
	if self.root == r then
		return
	end
	self.root = r
	for _, c in ipairs(self.children) do
		c:_set_root(r)
	end
	for _, c in ipairs(self._internal) do
		c:_set_root(r)
	end
end

function Control.add_child(self, c, _legible: any?)
	if c.parent ~= nil then
		c.parent:remove_child(c)
	end
	table.insert(self.children, c)
	c.parent = self
	c.gui.Parent = self:_content_gui()
	c:_set_root(self.root)
	if self._in_button or self.gui:IsA("GuiButton") then
		c:_mark_in_button()
	end
	self:_renumber()
	c:_propagate_alpha(self._eff_a)
	c._needs_layout = true
	self:_child_changed()
	return c
end

--- Internal child (part of a widget, not in `children`): laid out by its owner.
function Control._add_internal(self, c)
	table.insert(self._internal, c)
	c.parent = self
	c.gui.Parent = self.gui
	c:_set_root(self.root)
	if self._in_button or self.gui:IsA("GuiButton") then
		c:_mark_in_button()
	end
	c:_propagate_alpha(self._eff_a)
	return c
end

function Control.remove_child(self, c)
	local i = table.find(self.children, c)
	if i == nil then
		return
	end
	table.remove(self.children, i)
	c.parent = nil
	c.gui.Parent = nil
	c:_set_root(nil)
	self:_renumber()
	self:_child_changed()
end

--- Godot move_child(child, to_index) (0-based, -1 = last).
function Control.move_child(self, c, to: number)
	local i = table.find(self.children, c)
	if i == nil then
		return
	end
	table.remove(self.children, i)
	local n = #self.children
	local idx = if to < 0 then n + 1 else math.clamp(to + 1, 1, n + 1)
	table.insert(self.children, idx, c)
	self:_renumber()
	self:_child_changed()
end

function Control.get_children(self)
	return table.clone(self.children)
end

function Control.get_child_count(self): number
	return #self.children
end

--- Godot get_child(i) (0-based).
function Control.get_child(self, i: number)
	return self.children[i + 1]
end

function Control.get_index(self): number
	if self.parent == nil then
		return -1
	end
	return (table.find(self.parent.children, self) or 0) - 1
end

function Control.get_parent(self)
	return self.parent
end

function Control.is_inside_tree(self): boolean
	return self.root ~= nil
end

function Control.is_ancestor_of(self, n): boolean
	local p = n.parent
	while p ~= nil do
		if p == self then
			return true
		end
		p = p.parent
	end
	return false
end

function Control.queue_free(self)
	if self._freed then
		return
	end
	if self.parent ~= nil then
		local p = self.parent
		local i = table.find(p.children, self)
		if i then
			p:remove_child(self)
		else
			local j = table.find(p._internal, self)
			if j then
				table.remove(p._internal, j)
			end
			self.parent = nil
		end
	end
	self:_free_rec()
	self.gui:Destroy()
end
Control.free = Control.queue_free

function Control._free_rec(self)
	self._freed = true
	_process[self] = nil
	if rawget(self, "tree_exiting") then
		self.tree_exiting:Fire()
	end
	for _, c in ipairs(self._conns) do
		c:Disconnect()
	end
	table.clear(self._conns)
	for _, c in ipairs(self.children) do
		c:_free_rec()
	end
	for _, c in ipairs(self._internal) do
		c:_free_rec()
	end
	self.root = nil
end

function Control._connect(self, conn)
	table.insert(self._conns, conn)
	return conn
end

-- --- processing -----------------------------------------------------------------------------

--- Godot set_process(on): calls self:_process(dt) every frame (also while hidden, like Godot).
function Control.set_process(self, on: boolean)
	if on and self._process then
		_process[self] = true
	else
		_process[self] = nil
	end
end

function Control.is_processing(self): boolean
	return _process[self] == true
end

-- --- visibility & min size --------------------------------------------------------------------

function Control.set_visible(self, on: boolean)
	on = on and true or false
	if self.visible == on then
		return
	end
	self.visible = on
	self.gui.Visible = on
	self._needs_layout = true
	if self.parent then
		self.parent:_child_changed()
	end
	if rawget(self, "visibility_changed") then
		self.visibility_changed:Fire()
	end
end

function Control.show(self)
	self:set_visible(true)
end

function Control.hide(self)
	self:set_visible(false)
end

function Control.is_visible_in_tree(self): boolean
	local n = self
	while n ~= nil do
		if not n.visible then
			return false
		end
		if n.parent == nil then
			return n._is_root == true
		end
		n = n.parent
	end
	return false
end

function Control.set_min_size(self, v: Vector2)
	if self.custom_minimum_size == v then
		return
	end
	self.custom_minimum_size = v
	self:update_minimum_size()
end

--- Godot `custom_minimum_size.x = v`.
function Control.set_min_width(self, w: number)
	self:set_min_size(Vector2.new(w, self.custom_minimum_size.Y))
end

function Control.set_min_height(self, h: number)
	self:set_min_size(Vector2.new(self.custom_minimum_size.X, h))
end

--- Godot update_minimum_size(): invalidate this node's and its ancestors' minimum size and
--- schedule a layout of the tree.
function Control.update_minimum_size(self)
	local n = self
	while n ~= nil do
		n._min_dirty = true
		n._needs_layout = true
		local p = n.parent
		if p == nil then
			if n._is_root then
				n._dirty = true
			end
			break
		end
		n = p
	end
end

function Control._child_changed(self)
	self:update_minimum_size()
end

--- The node's own minimum size (subclasses override).
function Control._get_minimum_size(_self): Vector2
	return Vector2.zero
end

local _scale_gen = 0

function Control.get_combined_minimum_size(self): Vector2
	if self._min_dirty or self._min_gen ~= _scale_gen then
		local m = self:_get_minimum_size()
		local c = self.custom_minimum_size
		self._min_cache = Vector2.new(math.max(m.X, c.X), math.max(m.Y, c.Y))
		self._min_dirty = false
		self._min_gen = _scale_gen
	end
	return self._min_cache
end
Control.get_minimum_size = Control.get_combined_minimum_size

-- --- anchors / offsets ------------------------------------------------------------------------

local PRESETS = {
	[W.PRESET_TOP_LEFT] = { 0, 0, 0, 0 },
	[W.PRESET_FULL_RECT] = { 0, 0, 1, 1 },
	[W.PRESET_BOTTOM_WIDE] = { 0, 1, 1, 1 },
	[W.PRESET_TOP_WIDE] = { 0, 0, 1, 0 },
	[W.PRESET_CENTER] = { 0.5, 0.5, 0.5, 0.5 },
}

--- Godot set_anchors_and_offsets_preset(preset): anchors and zero offsets (margin 0).
function Control.set_anchors_and_offsets_preset(self, preset: number)
	local a = PRESETS[preset] or PRESETS[W.PRESET_TOP_LEFT]
	self.anchor_left, self.anchor_top, self.anchor_right, self.anchor_bottom = a[1], a[2], a[3], a[4]
	self.offset_left, self.offset_top, self.offset_right, self.offset_bottom = 0, 0, 0, 0
	if preset == W.PRESET_BOTTOM_WIDE then
		self.grow_vertical = W.GROW_BEGIN
	elseif preset == W.PRESET_CENTER then
		self.grow_horizontal = W.GROW_BOTH
		self.grow_vertical = W.GROW_BOTH
	end
	self:queue_layout()
end
Control.set_anchors_preset = Control.set_anchors_and_offsets_preset

--- Set anchors (left, top, right, bottom).
function Control.set_anchors(self, l: number, t: number, r: number, b: number)
	self.anchor_left, self.anchor_top, self.anchor_right, self.anchor_bottom = l, t, r, b
	self:queue_layout()
end

--- Set offsets (left, top, right, bottom).
function Control.set_offsets(self, l: number, t: number, r: number, b: number)
	self.offset_left, self.offset_top, self.offset_right, self.offset_bottom = l, t, r, b
	self:queue_layout()
end

function Control.set_grow(self, h: number, v: number)
	self.grow_horizontal, self.grow_vertical = h, v
	self:queue_layout()
end

--- Schedule a re-layout of this (free) node.
function Control.queue_layout(self)
	self._needs_layout = true
	local n = self
	while n.parent ~= nil do
		n = n.parent
	end
	if n._is_root then
		n._dirty = true
	end
end
Control.queue_sort = Control.queue_layout
Control.queue_redraw = function(self)
	if self._redraw then
		self:_redraw()
	end
end

--- Rect from anchors / offsets inside a parent of size `ps`, grown to the minimum size.
function Control._free_rect(self, ps: Vector2): (Vector2, Vector2)
	local min = self:get_combined_minimum_size()
	local l = self.anchor_left * ps.X + self.offset_left
	local r = self.anchor_right * ps.X + self.offset_right
	local t = self.anchor_top * ps.Y + self.offset_top
	local b = self.anchor_bottom * ps.Y + self.offset_bottom
	local w, h = r - l, b - t
	if w < min.X then
		if self.grow_horizontal == W.GROW_BEGIN then
			l = r - min.X
		elseif self.grow_horizontal == W.GROW_BOTH then
			l -= (min.X - w) * 0.5
		end
		w = min.X
	end
	if h < min.Y then
		if self.grow_vertical == W.GROW_BEGIN then
			t = b - min.Y
		elseif self.grow_vertical == W.GROW_BOTH then
			t -= (min.Y - h) * 0.5
		end
		h = min.Y
	end
	return Vector2.new(l, t), Vector2.new(w, h)
end

function Control._parent_size(self): Vector2
	if self.parent ~= nil then
		return self.parent.size
	end
	return self.size
end

--- Godot reset_size(): shrink to the minimum size. (Kit: the edge implied by the grow direction
--- stays put, so right-anchored / centred panels never drift when they shrink.)
function Control.reset_size(self)
	if self.parent ~= nil and self.parent._is_container then
		self:get_root_flush()
		return
	end
	local ps = self:_parent_size()
	local min = self:get_combined_minimum_size()
	local l = self.anchor_left * ps.X + self.offset_left
	local r = self.anchor_right * ps.X + self.offset_right
	local t = self.anchor_top * ps.Y + self.offset_top
	local b = self.anchor_bottom * ps.Y + self.offset_bottom
	if self.grow_horizontal == W.GROW_BEGIN then
		l = r - min.X
	elseif self.grow_horizontal == W.GROW_BOTH then
		local c = (l + r) * 0.5
		l = c - min.X * 0.5
		r = c + min.X * 0.5
	else
		r = l + min.X
	end
	if self.grow_vertical == W.GROW_BEGIN then
		t = b - min.Y
	elseif self.grow_vertical == W.GROW_BOTH then
		local c = (t + b) * 0.5
		t = c - min.Y * 0.5
		b = c + min.Y * 0.5
	else
		b = t + min.Y
	end
	self.offset_left = l - self.anchor_left * ps.X
	self.offset_right = (if self.grow_horizontal == W.GROW_BEGIN then r else l + min.X) - self.anchor_right * ps.X
	self.offset_top = t - self.anchor_top * ps.Y
	self.offset_bottom = (if self.grow_vertical == W.GROW_BEGIN then b else t + min.Y) - self.anchor_bottom * ps.Y
	self:_layout_free()
end

--- Lay out this free node (and its subtree) now.
function Control._layout_free(self)
	if self.parent == nil then
		return
	end
	local pos, size = self:_free_rect(self.parent.size)
	self:_apply_rect(pos, size)
	self:_sort_tree()
end

function Control.get_root_flush(self)
	local n = self
	while n.parent ~= nil do
		n = n.parent
	end
	if n._is_root then
		n:_flush()
	end
end

-- --- geometry -----------------------------------------------------------------------------------

function Control._apply_rect(self, pos: Vector2, size: Vector2)
	local changed_size = size ~= self.size
	local changed = changed_size or pos ~= self.position
	self.position = pos
	self.size = size
	self:_write_geometry()
	if changed then
		if changed_size then
			if self._on_resized then
				self:_on_resized()
			end
			if rawget(self, "resized") then
				self.resized:Fire()
			end
		end
		if rawget(self, "item_rect_changed") then
			self.item_rect_changed:Fire()
		end
	end
end

function Control._write_geometry(self)
	local s = UITheme.scale
	local x0 = math.floor(self.position.X * s + 0.5)
	local y0 = math.floor(self.position.Y * s + 0.5)
	local x1 = math.floor((self.position.X + self.size.X) * s + 0.5)
	local y1 = math.floor((self.position.Y + self.size.Y) * s + 0.5)
	local w, h = x1 - x0, y1 - y0
	local geo = self._geo
	if geo ~= nil and geo[1] == x0 and geo[2] == y0 and geo[3] == w and geo[4] == h then
		return
	end
	self._geo = { x0, y0, w, h }
	self.gui.Size = UDim2.fromOffset(w, h)
	self.gui.Position = UDim2.fromOffset(x0 + w * 0.5, y0 + h * 0.5)
	if self._on_geometry then
		self:_on_geometry(w, h)
	end
end

--- Render size in px (after scale & snapping).
function Control.px_size(self): (number, number)
	local g = self._geo
	if g == nil then
		return 0, 0
	end
	return g[3], g[4]
end

--- Lay out children (free: anchors; containers override _sort_children).
function Control._sort_children(self)
	for _, c in ipairs(self.children) do
		if c.visible then
			local pos, size = c:_free_rect(self.size)
			c:_apply_rect(pos, size)
		end
	end
end

function Control._sort_tree(self)
	self._needs_layout = false
	self:_sort_children()
	for _, c in ipairs(self.children) do
		if c.visible then
			c:_sort_tree()
		end
	end
	if self._sort_internal then
		self:_sort_internal()
	end
end

--- Godot fit_child_in_rect(child, rect) honouring the child's size flags.
function Control.fit_child_in_rect(_self, c, pos: Vector2, size: Vector2)
	local min = c:get_combined_minimum_size()
	local x, y, w, h = pos.X, pos.Y, size.X, size.Y
	local fh, fv = c.size_flags_horizontal, c.size_flags_vertical
	if bit32.band(fh, W.FILL) == 0 then
		local mw = math.min(min.X, w)
		if bit32.band(fh, W.SHRINK_CENTER) ~= 0 then
			x += math.floor((w - mw) * 0.5)
		elseif bit32.band(fh, W.SHRINK_END) ~= 0 then
			x += w - mw
		end
		w = mw
	end
	if bit32.band(fv, W.FILL) == 0 then
		local mh = math.min(min.Y, h)
		if bit32.band(fv, W.SHRINK_CENTER) ~= 0 then
			y += math.floor((h - mh) * 0.5)
		elseif bit32.band(fv, W.SHRINK_END) ~= 0 then
			y += h - mh
		end
		h = mh
	end
	c:_apply_rect(Vector2.new(x, y), Vector2.new(w, h))
end

--- Position / size relative to the parent node (layout flushed first).
function Control.get_rect(self): Rect
	self:get_root_flush()
	return Rect.new(self.position.X, self.position.Y, self.position.X + self.size.X, self.position.Y + self.size.Y)
end

function Control.get_position(self): Vector2
	self:get_root_flush()
	return self.position
end

function Control.get_size(self): Vector2
	self:get_root_flush()
	return self.size
end

--- Global position in logical px (relative to the Root).
function Control.get_global_position(self): Vector2
	self:get_root_flush()
	local p = Vector2.zero
	local n = self
	while n ~= nil and not n._is_root do
		p += n.position
		n = n.parent
		-- a scrolled container draws its children shifted by the scroll (HelpOverlay.Scroll): without
		-- it a hint anchored inside the help window sat where the content would be unscrolled
		if n ~= nil and n._canvas_offset ~= nil then
			p -= n:_canvas_offset()
		end
	end
	return p
end

--- Godot get_global_rect() as a Roblox Rect in logical px.
function Control.get_global_rect(self): Rect
	local p = self:get_global_position()
	return Rect.new(p.X, p.Y, p.X + self.size.X, p.Y + self.size.Y)
end

--- True when logical point `p` (an event's global_position) is on this control. A window's backdrop
--- uses it: a press on the window's own ground reaches the dim behind it too (Roblox fires InputBegan
--- on every frame under the pointer, Active or not), and only one outside the window should close it.
function Control.has_global_point(self, p: Vector2?): boolean
	if p == nil then
		return false
	end
	local r = self:get_global_rect()
	return p.X >= r.Min.X and p.X <= r.Max.X and p.Y >= r.Min.Y and p.Y <= r.Max.Y
end

--- Rect in viewport px (AbsolutePosition space).
function Control.get_view_rect(self): Rect
	return W.rect_to_view(self:get_global_rect())
end

-- --- mouse -----------------------------------------------------------------------------------------

function Control.set_mouse_filter(self, f: number)
	self.mouse_filter = f
	local g = self.gui
	if g:IsA("GuiButton") then
		g.Active = f ~= W.MOUSE_IGNORE
		g.Interactable = f ~= W.MOUSE_IGNORE
	else
		-- inside a button a stopping frame / image would swallow the button's own clicks and taps
		g.Active = f == W.MOUSE_STOP and not self._in_button
	end
end

--- Decoration inside a button (icons, labels, panels, layout boxes) never sinks input: an Active
--- child made its part of the button dead to clicks and taps (phone players had to hit the edges).
function Control._mark_in_button(self)
	if self._in_button then
		return
	end
	self._in_button = true
	if not self.gui:IsA("GuiButton") then
		self.gui.Active = false
	end
	for _, c in ipairs(self.children) do
		c:_mark_in_button()
	end
	for _, c in ipairs(self._internal) do
		c:_mark_in_button()
	end
end

--- Input signals are wired to the Roblox events only once somebody connects to them.
function Control._on_signal_created(self, k: string)
	local g = self.gui
	if k == "mouse_entered" then
		self:_connect(g.MouseEnter:Connect(function()
			self.mouse_entered:Fire()
		end))
	elseif k == "mouse_exited" then
		self:_connect(g.MouseLeave:Connect(function()
			self.mouse_exited:Fire()
		end))
	elseif k == "gui_input" then
		self:_connect(g.InputBegan:Connect(function(io: InputObject)
			local ev = W.make_event(io, true, self)
			if ev then
				self.gui_input:Fire(ev)
			end
		end))
		self:_connect(g.InputEnded:Connect(function(io: InputObject)
			local ev = W.make_event(io, false, self)
			if ev then
				self.gui_input:Fire(ev)
			end
		end))
	end
end

--- Godot InputEvent stand-in: {kind = "button"|"motion", button = 1 (left) | 2 (right),
--- pressed, touch, position (logical, local to the node), global_position (logical)}.
function W.make_event(io: InputObject, began: boolean, node): any
	local t = io.UserInputType
	local button = nil
	local touch = false
	if t == Enum.UserInputType.MouseButton1 then
		button = 1
	elseif t == Enum.UserInputType.MouseButton2 then
		button = 2
	elseif t == Enum.UserInputType.Touch then
		-- a finger already down that slides onto a control arrives as an InputBegan too (its state is
		-- Change or End, not Begin): that is not a press there (it closed a window when a scrolling
		-- finger drifted onto the dim around it, and the radial menu when the finger that opened it
		-- lifted)
		local state = (io :: any).UserInputState
		if began and state ~= nil and state ~= Enum.UserInputState.Begin then
			return nil
		end
		button = 1
		touch = true
	end
	if button == nil then
		return nil
	end
	local gp = W.screen_to_logical(W.input_pos(io), node)
	local lp = gp
	if node ~= nil then
		lp = gp - node:get_global_position()
	end
	return {
		kind = "button",
		button = button,
		pressed = began,
		touch = touch,
		position = lp,
		global_position = gp,
		input = io,
	}
end

-- --- alpha (Godot modulate.a) & scale ----------------------------------------------------------------

--- Register a visual property whose transparency follows this node's modulate.
--- prop: "BackgroundTransparency" | "TextTransparency" | "ImageTransparency" | "Transparency" (UIStroke)
function Control._part(self, inst: Instance, prop: string, alpha: number)
	local rec = self._parts[inst]
	if rec == nil then
		rec = {}
		self._parts[inst] = rec
	end
	rec[prop] = alpha
	local a = alpha * self._eff_a;
	(inst :: any)[prop] = 1 - a
end

function Control._drop_part(self, inst: Instance)
	self._parts[inst] = nil
end

function Control._propagate_alpha(self, parent_a: number)
	local e = parent_a * self.modulate_a
	if e == self._eff_a and self._alpha_init then
		return
	end
	self._alpha_init = true
	self._eff_a = e
	for inst, rec in pairs(self._parts) do
		for prop, a in pairs(rec) do
			(inst :: any)[prop] = 1 - a * e
		end
	end
	for _, c in ipairs(self.children) do
		c:_propagate_alpha(e)
	end
	for _, c in ipairs(self._internal) do
		c:_propagate_alpha(e)
	end
end

function Control.set_modulate_a(self, a: number)
	if a == self.modulate_a then
		return
	end
	self.modulate_a = a
	self._alpha_init = false
	self:_propagate_alpha(if self.parent then self.parent._eff_a else 1.0)
end

function Control.get_modulate_a(self): number
	return self.modulate_a
end

--- Godot `scale` (uniform; pivot = centre).
function Control.set_scale(self, s: any)
	local v = if typeof(s) == "Vector2" then s.X else s
	if v == self._scale then
		return
	end
	self._scale = v
	local us = self._uiscale
	if math.abs(v - 1) < 1e-4 then
		if us then
			us:Destroy()
			self._uiscale = nil
		end
		return
	end
	if us == nil then
		us = Instance.new("UIScale")
		us.Parent = self.gui
		self._uiscale = us
	end
	us.Scale = math.max(v, 0.001)
end

function Control.get_scale(self): number
	return self._scale
end

function Control.set_rotation(self, rad: number)
	self.rotation = rad
	self.gui.Rotation = math.deg(rad)
end

function Control.set_clip_contents(self, on: boolean)
	self.gui.ClipsDescendants = on
end

--- Tween property access (keys as in GDScript tween_property paths).
function Control.tween_get(self, key: string): any
	if key == "modulate:a" then
		return self.modulate_a
	elseif key == "scale" then
		return self._scale
	elseif key == "position:x" then
		return self.position.X
	elseif key == "position:y" then
		return self.position.Y
	elseif key == "rotation" then
		return self.rotation
	end
	return self[key]
end

function Control.tween_set(self, key: string, v: any)
	if key == "modulate:a" then
		self:set_modulate_a(v)
	elseif key == "scale" then
		self:set_scale(v)
	elseif key == "position:x" then
		self.position = Vector2.new(v, self.position.Y)
		self:_write_geometry()
	elseif key == "position:y" then
		self.position = Vector2.new(self.position.X, v)
		self:_write_geometry()
	elseif key == "rotation" then
		self:set_rotation(v)
	else
		self[key] = v
		if self._redraw then
			self:_redraw()
		end
	end
end

function Control.create_tween(self)
	return W.Tween.new(self)
end

-- --- theme overrides (Panel / Button / Margin use them) -------------------------------------------------

function Control.add_theme_stylebox_override(self, name: string, style)
	self._styles = self._styles or {}
	self._styles[name] = style
	self:_theme_changed()
end

function Control.get_theme_stylebox(self, name: string)
	return self._styles and self._styles[name] or nil
end

function Control.has_theme_stylebox_override(self, name: string): boolean
	return self._styles ~= nil and self._styles[name] ~= nil
end

function Control.add_theme_color_override(self, name: string, col)
	self._colors = self._colors or {}
	self._colors[name] = col
	self:_theme_changed()
end

function Control.get_theme_color(self, name: string)
	return self._colors and self._colors[name] or nil
end

function Control.add_theme_constant_override(self, name: string, v: number)
	self._consts = self._consts or {}
	self._consts[name] = v
	self:_theme_changed()
end

function Control.get_theme_constant(self, name: string, default: number?): number?
	local v = self._consts and self._consts[name]
	if v == nil then
		return default
	end
	return v
end

function Control.add_theme_font_size_override(self, _name: string, size: number)
	if self.set_font_size then
		self:set_font_size(size)
	end
end

function Control._theme_changed(self)
	self:update_minimum_size()
	if self._redraw then
		self:_redraw()
	end
end

-- =============================================================================================
-- Root
-- =============================================================================================

local Root = class(Control)
W.Root = Root

--- Top-level node filling `parent` (a ScreenGui with IgnoreGuiInset or a full-screen Frame).
--- opts.touch_device: phones / tablets (UI scale 1:1 points); opts.scale: fixed scale override.
function Root.new(parent: Instance, opts: any?)
	local self = new_of(Root)
	local g = Instance.new("Frame")
	g.Name = "UIKitRoot"
	g.BackgroundTransparency = 1
	g.BorderSizePixel = 0
	g.Size = UDim2.fromScale(1, 1)
	g.Position = UDim2.fromOffset(0, 0)
	g.Active = false
	Control._init(self, nil, g)
	self:set_mouse_filter(W.MOUSE_IGNORE)
	self._is_root = true
	self._dirty = true
	self.root = self
	self.opts = opts or {}
	self.vp = Vector2.new(1600, 900)
	self.view_size = Vector2.new(1600, 900)
	g.Parent = parent
	table.insert(_roots, self)
	self:_connect(g:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		self:set_viewport(g.AbsoluteSize)
	end))
	self:set_viewport(g.AbsoluteSize)
	W.start_driver()
	if not UITheme.fonts_ready() then
		-- exact metrics arrive in the background (fonts_loaded re-lays everything out)
		task.spawn(UITheme.init)
	end
	return self
end

function Root._write_geometry(_self) end

-- Exact metrics arrived (UITheme.init finished): re-measure and re-render everything.
UITheme.fonts_loaded:Connect(function()
	_scale_gen += 1
	for _, r in ipairs(_roots) do
		r:_invalidate_all()
		r._dirty = true
	end
end)

--- Viewport (render px) changed: recompute the UI scale and the logical viewport.
function Root.set_viewport(self, view: Vector2, force_scale: number?)
	if view.X <= 0 or view.Y <= 0 then
		return
	end
	local s = force_scale or self.opts.scale or UITheme.ui_scale(view, self.opts.touch_device)
	self.view_size = view
	if s ~= UITheme.scale then
		UITheme.set_scale(s)
		_scale_gen += 1
		self:_invalidate_all()
	end
	self.vp = view / s
	self.size = self.vp
	self._dirty = true
	if rawget(self, "resized") then
		self.resized:Fire()
	end
end

function Root.set_scale_override(self, s: number?)
	self.opts.scale = s
	self:set_viewport(self.gui.AbsoluteSize)
end

function Root._invalidate_all(self)
	local function rec(n)
		n._min_dirty = true
		n._needs_layout = true
		n._geo = nil
		if n._restyle then
			n:_restyle()
		end
		for _, c in ipairs(n.children) do
			rec(c)
		end
		for _, c in ipairs(n._internal) do
			rec(c)
		end
	end
	rec(self)
end

function Root._flush(self)
	if not self._dirty then
		return
	end
	self._dirty = false
	self.size = self.vp
	self:_sort_tree()
end

function Root.destroy(self)
	local i = table.find(_roots, self)
	if i then
		table.remove(_roots, i)
	end
	self:queue_free()
end

-- =============================================================================================
-- Style rendering (StyleBoxFlat on a node's gui)
-- =============================================================================================

-- Shadow 9-slice textures: rounded-rect shadows with a linear falloff (Godot StyleBoxFlat
-- shadow), one per corner-radius / feather ratio (tools/uikit/make_shadows.py).
W.SHADOWS = {
	-- [ratio] = {id, feather_px, radius_px, size_px}
}
local _shadow_manifest_loaded = false
local function shadow_for(radius: number, feather: number)
	if not _shadow_manifest_loaded then
		_shadow_manifest_loaded = true
		local ok, m = pcall(function()
			local rs = game:GetService("ReplicatedStorage")
			local assets = (rs:WaitForChild("Airfront") :: any):FindFirstChild("Assets")
			local mod = assets and assets:FindFirstChild("UIKit")
			return if mod then require(mod) :: any else nil
		end)
		if ok and type(m) == "table" and type(m.shadows) == "table" then
			W.SHADOWS = m.shadows
		end
	end
	local q = (radius + 0.5) / math.max(feather, 1)
	local best, bd = nil, math.huge
	for _, e in ipairs(W.SHADOWS) do
		local d = math.abs(math.log((e.radius + 0.5 * e.feather / math.max(feather, 1)) / e.feather) - math.log(q))
		if d < bd then
			best, bd = e, d
		end
	end
	return best
end

local StyleView = {}
StyleView.__index = StyleView
W.StyleView = StyleView

--- Draws a Style (UITheme.flat) into `node.gui` as parts with ZIndex base z (1..9).
function StyleView.new(node, z: number?)
	local self = setmetatable({ node = node, z = z or 1, style = nil, inst = {} }, StyleView)
	return self
end

function StyleView._get(self, key: string, class_name: string)
	local i = self.inst[key]
	if i == nil then
		i = Instance.new(class_name)
		if i:IsA("GuiObject") then
			i.BorderSizePixel = 0
			i.BackgroundTransparency = 1
			i.AnchorPoint = Vector2.zero
			i.Active = false
		end
		self.inst[key] = i
	end
	return i
end

function StyleView._drop(self, key: string)
	local i = self.inst[key]
	if i then
		self.node:_drop_part(i)
		i:Destroy()
		self.inst[key] = nil
	end
end

function StyleView.set(self, style)
	self.style = style
	self:render()
end

function StyleView.clear(self)
	for k in pairs(self.inst) do
		self:_drop(k)
	end
end

--- Re-render for the node's current pixel size.
function StyleView.render(self)
	local st = self.style
	local node = self.node
	local w, h = node:px_size()
	if st == nil or st.kind == "empty" or w <= 0 or h <= 0 then
		self:clear()
		return
	end
	local s = UITheme.scale
	-- optional inset (logical px): draw the style in a sub-rect (Godot draw_style_box(sb, rect))
	local ox, oy = 0, 0
	local ins = self.inset
	if ins then
		ox, oy = math.floor(ins[1] * s + 0.5), math.floor(ins[2] * s + 0.5)
		w = w - ox - math.floor(ins[3] * s + 0.5)
		h = h - oy - math.floor(ins[4] * s + 0.5)
		if w <= 0 or h <= 0 then
			self:clear()
			return
		end
	end
	local rpx = math.min(math.floor(st.radius * s + 0.5), math.floor(math.min(w, h) / 2))
	local z = self.z
	-- shadow
	if st.shadow and st.shadow.size > 0 then
		local f = st.shadow.size
		local e = shadow_for(math.min(st.radius, math.min(w, h) / s / 2), f)
		if e then
			local img = self:_get("shadow", "ImageLabel") :: ImageLabel
			local fpx = f * s
			img.Image = e.id
			img.ScaleType = Enum.ScaleType.Slice
			local c = e.slice or (e.feather + e.radius)
			img.SliceCenter = Rect.new(c, c, e.size - c, e.size - c)
			img.SliceScale = fpx / e.feather
			img.ImageColor3 = Color3.new(0.0, 0.01, 0.04)
			img.Size = UDim2.fromOffset(w + 2 * fpx, h + 2 * fpx)
			img.Position = UDim2.fromOffset(ox - fpx, oy - fpx + st.shadow.offset_y * s)
			img.ZIndex = z
			img.Parent = node.gui
			node:_part(img, "ImageTransparency", st.shadow.alpha)
		end
	else
		self:_drop("shadow")
	end
	local lip = st.bw_bottom or 0
	local has_bg = st.draw_center and st.bg.alpha > 0.001
	local has_border = st.bw > 0 and st.border.alpha > 0.001
	if lip > 0 then
		-- Bottom "lip": the border colour under a shorter fill (PrimaryButton).
		local outer = self:_get("lip", "Frame") :: Frame
		outer.BackgroundColor3 = st.border.color
		outer.Size = UDim2.fromOffset(w, h)
		outer.Position = UDim2.fromOffset(ox, oy)
		outer.ZIndex = z + 1
		outer.Parent = node.gui
		node:_part(outer, "BackgroundTransparency", st.border.alpha)
		local oc = outer:FindFirstChildOfClass("UICorner") or Instance.new("UICorner")
		oc.CornerRadius = UDim.new(0, rpx)
		oc.Parent = outer
	else
		self:_drop("lip")
	end
	if has_bg or has_border then
		local bg = self:_get("bg", "Frame") :: Frame
		local lpx = math.floor(lip * s + 0.5)
		bg.BackgroundColor3 = st.bg.color
		bg.Size = UDim2.fromOffset(w, h - lpx)
		bg.Position = UDim2.fromOffset(ox, oy)
		bg.ZIndex = z + 2
		bg.Parent = node.gui
		node:_part(bg, "BackgroundTransparency", if has_bg then st.bg.alpha else 0)
		local corner = bg:FindFirstChildOfClass("UICorner") or Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, rpx)
		corner.Parent = bg
		local stroke = bg:FindFirstChildOfClass("UIStroke")
		if has_border and lip == 0 then
			if stroke == nil then
				stroke = Instance.new("UIStroke")
				stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
				pcall(function()
					(stroke :: any).BorderStrokePosition = Enum.BorderStrokePosition.Inner
				end)
				stroke.LineJoinMode = Enum.LineJoinMode.Round
				stroke.Parent = bg
			end
			stroke.Color = st.border.color
			stroke.Thickness = math.max(1, math.floor(st.bw * s + 0.5))
			node:_part(stroke, "Transparency", st.border.alpha)
		elseif stroke then
			node:_drop_part(stroke)
			stroke:Destroy()
		end
	else
		self:_drop("bg")
	end
end

W.StyleView = StyleView

-- =============================================================================================
-- Containers
-- =============================================================================================

-- --- Box (HBoxContainer / VBoxContainer) --------------------------------------------------------------

local Box = class(Control)
W.Box = Box

function Box.new(vertical: boolean)
	local self = new_of(Box)
	Control._init(self)
	self._is_container = true
	self.vertical = vertical
	self.separation = if vertical then 4 else 8
	self.alignment = W.ALIGN_BEGIN
	self:set_mouse_filter(W.MOUSE_PASS)
	return self
end

function Box.add_theme_constant_override(self, name: string, v: number)
	if name == "separation" then
		self.separation = v
		self:update_minimum_size()
		return
	end
	Control.add_theme_constant_override(self, name, v)
end

function Box.set_separation(self, v: number)
	self.separation = v
	self:update_minimum_size()
end

function Box.set_alignment(self, a: number)
	self.alignment = a
	self:queue_layout()
end

local function trunc(x: number): number
	return if x >= 0 then math.floor(x) else -math.floor(-x)
end

-- Godot BoxContainer::_get_minimum_size (integer: child minimum sizes are rounded up).
function Box._get_minimum_size(self): Vector2
	local main, cross, n = 0, 0, 0
	local v = self.vertical
	for _, c in ipairs(self.children) do
		if c.visible then
			local m = c:get_combined_minimum_size()
			local mx, my = math.ceil(m.X - 1e-6), math.ceil(m.Y - 1e-6)
			if v then
				main += my
				cross = math.max(cross, mx)
			else
				main += mx
				cross = math.max(cross, my)
			end
			n += 1
		end
	end
	if n > 1 then
		main += self.separation * (n - 1)
	end
	return if v then Vector2.new(cross, main) else Vector2.new(main, cross)
end

-- Godot BoxContainer::_resort (same integer arithmetic, stretch refit and error diffusion).
function Box._sort_children(self)
	local v = self.vertical
	local size = self.size
	local new_main = trunc(if v then size.Y else size.X)
	local cross = trunc(if v then size.X else size.Y)
	local sep = self.separation
	local items = {}
	local stretch_min, stretch_avail, stretch_ratio_total = 0, 0, 0
	local n = 0
	for _, c in ipairs(self.children) do
		if c.visible then
			local m = c:get_combined_minimum_size()
			local ms = math.ceil((if v then m.Y else m.X) - 1e-6)
			local flags = if v then c.size_flags_vertical else c.size_flags_horizontal
			local expand = bit32.band(flags, W.EXPAND) ~= 0
			n += 1
			stretch_min += ms
			local it = { c = c, min = ms, final = ms, will_stretch = expand, ratio = c.size_flags_stretch_ratio }
			if expand then
				stretch_avail += ms
				stretch_ratio_total += it.ratio
			end
			table.insert(items, it)
		end
	end
	if n == 0 then
		return
	end
	local stretch_max = new_main - (n - 1) * sep
	local stretch_diff = math.max(0, stretch_max - stretch_min)
	stretch_avail += stretch_diff
	while stretch_ratio_total > 0 do
		local ok = true
		local err = 0.0
		for _, it in ipairs(items) do
			if it.will_stretch then
				local fps = stretch_avail * it.ratio / stretch_ratio_total
				err += fps - trunc(fps)
				if fps < it.min then
					it.will_stretch = false
					stretch_ratio_total -= it.ratio
					ok = false
					stretch_avail -= it.min
					it.final = it.min
					break
				else
					it.final = trunc(fps)
					if err >= 1 then
						it.final += 1
						err -= 1
					end
				end
			end
		end
		if ok then
			break
		end
	end
	local final_diff = stretch_max - stretch_min
	for _, it in ipairs(items) do
		final_diff -= it.final - it.min
	end
	final_diff = math.max(0, final_diff)
	local ofs = 0
	if self.alignment == W.ALIGN_CENTER then
		ofs = final_diff // 2
	elseif self.alignment == W.ALIGN_END then
		ofs = final_diff
	end
	for i, it in ipairs(items) do
		if i > 1 then
			ofs += sep
		end
		local from = ofs
		local to = ofs + it.final
		if it.will_stretch and i == n then
			to = new_main -- the last stretcher always fits exactly
		end
		local sz = to - from
		if v then
			self:fit_child_in_rect(it.c, Vector2.new(0, from), Vector2.new(cross, sz))
		else
			self:fit_child_in_rect(it.c, Vector2.new(from, 0), Vector2.new(sz, cross))
		end
		ofs = to
	end
end

-- --- Margin (MarginContainer) ---------------------------------------------------------------------------

local Margin = class(Control)
W.Margin = Margin

function Margin.new()
	local self = new_of(Margin)
	Control._init(self)
	self._is_container = true
	self.margins = { 0, 0, 0, 0 }
	self:set_mouse_filter(W.MOUSE_PASS)
	return self
end

local MARGIN_KEYS = { margin_left = 1, margin_top = 2, margin_right = 3, margin_bottom = 4 }

function Margin.add_theme_constant_override(self, name: string, v: number)
	local i = MARGIN_KEYS[name]
	if i then
		self.margins[i] = v
		self:update_minimum_size()
		return
	end
	Control.add_theme_constant_override(self, name, v)
end

function Margin._pad(self): (number, number, number, number)
	local m = self.margins
	return m[1], m[2], m[3], m[4]
end

local function pad_min(self): Vector2
	local l, t, r, b = self:_pad()
	local mw, mh = 0, 0
	for _, c in ipairs(self.children) do
		if c.visible then
			local m = c:get_combined_minimum_size()
			mw = math.max(mw, m.X)
			mh = math.max(mh, m.Y)
		end
	end
	return Vector2.new(mw + l + r, mh + t + b)
end

local function pad_sort(self)
	local l, t, r, b = self:_pad()
	local pos = Vector2.new(l, t)
	local size = Vector2.new(math.max(0, self.size.X - l - r), math.max(0, self.size.Y - t - b))
	for _, c in ipairs(self.children) do
		if c.visible then
			self:fit_child_in_rect(c, pos, size)
		end
	end
end

Margin._get_minimum_size = pad_min
Margin._sort_children = pad_sort

-- --- Panel (PanelContainer with a "panel" StyleBoxFlat) ----------------------------------------------

local Panel = class(Control)
W.Panel = Panel

function Panel.new()
	local self = new_of(Panel)
	Control._init(self)
	Panel._init_panel(self)
	return self
end

function Panel._init_panel(self)
	self._is_container = true
	self._sv = StyleView.new(self, 1)
	self:set_mouse_filter(W.MOUSE_STOP)
end

function Panel._pad(self): (number, number, number, number)
	return UITheme.margins(self:get_theme_stylebox("panel"))
end

Panel._get_minimum_size = pad_min
Panel._sort_children = pad_sort

function Panel._theme_changed(self)
	self:update_minimum_size()
	self._sv:set(self:get_theme_stylebox("panel"))
end

function Panel._on_geometry(self)
	self._sv:render()
end

function Panel._restyle(self)
	self._sv:render()
end

-- =============================================================================================
-- Leaves
-- =============================================================================================

-- --- ColorRect -------------------------------------------------------------------------------------------

local ColorRect = class(Control)
W.ColorRect = ColorRect

function ColorRect.new(col)
	local self = new_of(ColorRect)
	Control._init(self)
	self:set_color(col)
	return self
end

function ColorRect.set_color(self, col)
	self.color = col
	self.gui.BackgroundColor3 = UITheme.color3(col)
	self:_part(self.gui, "BackgroundTransparency", UITheme.alpha(col))
end

-- --- Icon (TextureRect with a UiIcons glyph) ----------------------------------------------------------------

local Icon = class(Control)
W.Icon = Icon

function Icon.new(icon_name: string?)
	local self = new_of(Icon)
	Control._init(self, "ImageLabel")
	local g = self.gui :: ImageLabel
	g.ScaleType = Enum.ScaleType.Fit
	g.ResampleMode = Enum.ResamplerMode.Default
	-- decoration (Godot TextureRect passes input on)
	self:set_mouse_filter(W.MOUSE_IGNORE)
	self.color = UITheme.TEXT
	self:set_icon(icon_name or "")
	self:set_color(UITheme.TEXT)
	return self
end

function Icon.set_icon(self, icon_name: string)
	if self.icon_name == icon_name then
		return
	end
	self.icon_name = icon_name
	local id = if icon_name ~= "" then UITheme.icon(icon_name) else nil
	(self.gui :: ImageLabel).Image = id or ""
end
Icon.set_texture = Icon.set_icon

--- self_modulate (tint + alpha).
function Icon.set_color(self, col)
	self.color = col
	local g = self.gui :: ImageLabel
	g.ImageColor3 = UITheme.color3(col)
	self:_part(g, "ImageTransparency", UITheme.alpha(col))
end
Icon.set_self_modulate = Icon.set_color

-- --- Label -------------------------------------------------------------------------------------------------

local Label = class(Control)
W.Label = Label

function Label.new(text: string?)
	local self = new_of(Label)
	Control._init(self)
	Label._init_label(self, text)
	return self
end

function Label._init_label(self, text: string?)
	self.text = text or ""
	self.font_size = 15
	self.base_fs = 15
	self.weight = 500
	self.spacing = 0
	self.tabular = false
	self.color = UITheme.TEXT
	self.horizontal_alignment = W.ALIGN_LEFT
	self.vertical_alignment = W.VALIGN_TOP
	self.clip_text = false
	self.text_overrun_behavior = W.OVERRUN_NONE
	self.autowrap = false
	self.shadow = nil
	self._glyphs = {}
	self._shadows = {}
	self._tl = nil
	self:set_mouse_filter(W.MOUSE_IGNORE)
	-- Godot's Label constructor: set_v_size_flags(SIZE_SHRINK_CENTER)
	self.size_flags_vertical = W.SHRINK_CENTER
end

--- Godot: label.text = s
function Label.set_text(self, s: string)
	s = s or ""
	if s == self.text then
		return
	end
	self.text = s
	if self:_min_depends_on_text() then
		self:update_minimum_size()
	end
	self:_redraw()
end

function Label.get_text(self): string
	return self.text
end

function Label._min_depends_on_text(self): boolean
	return self.autowrap or not (self.clip_text or self.text_overrun_behavior ~= W.OVERRUN_NONE)
end

function Label.set_font(self, weight: number, spacing: number?)
	self.weight = weight
	self.spacing = spacing or 0
	self:update_minimum_size()
	self:_redraw()
end

function Label.set_font_size(self, size: number)
	if self.font_size == size then
		return
	end
	self.font_size = size
	self:update_minimum_size()
	self:_redraw()
end

function Label.set_color(self, col)
	if UITheme.equal(self.color, col) then
		return
	end
	self.color = col
	self:_recolor()
end

function Label.set_tabular(self, on: boolean)
	self.tabular = on
	self:_redraw()
end

function Label.set_alignment(self, a: number)
	self.horizontal_alignment = a
	self:_redraw()
end

function Label.set_autowrap(self, on: boolean)
	self.autowrap = on
	self:update_minimum_size()
	self:_redraw()
end

--- Godot font_shadow_color + shadow_offset_y + shadow_outline_size.
function Label.set_shadow(self, col, offset_y: number, outline: number)
	self.shadow = { color = col, offset_y = offset_y, outline = outline }
	self:_redraw()
end

function Label._get_minimum_size(self): Vector2
	local lh = UITheme.line_height(self.font_size)
	if self.autowrap then
		local w = if self.size.X > 0 then self.size.X else self.custom_minimum_size.X
		return Vector2.new(0, UITheme.wrapped_height(self.text, self.font_size, self.weight, math.max(w, 1)))
	end
	local lines = string.split(self.text, "\n")
	local h = lh * math.max(1, #lines)
	if self.clip_text or self.text_overrun_behavior ~= W.OVERRUN_NONE then
		return Vector2.new(1, h)
	end
	local w = 0
	local glyphs = self:_use_glyphs()
	for _, line in ipairs(lines) do
		w = math.max(w, UITheme.measure_text(line, self.font_size, self.weight, self.spacing, glyphs and self.tabular))
	end
	return Vector2.new(w, h)
end

function Label._on_resized(self)
	if self.autowrap then
		-- Height follows the width: re-measure and let the container re-sort (Godot does the same).
		local old = self._min_cache
		self._min_dirty = true
		local new = self:get_combined_minimum_size()
		if old ~= new then
			self:update_minimum_size()
			self:queue_layout()
		end
	end
end

function Label._on_geometry(self)
	self:_redraw()
end

function Label._restyle(self)
	self:_redraw()
end

local function make_text(parent: Instance, weight: number, z: number): TextLabel
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency = 1
	t.BorderSizePixel = 0
	t.AnchorPoint = Vector2.zero
	t.TextYAlignment = Enum.TextYAlignment.Top
	t.RichText = false
	t.Active = false
	t.FontFace = UITheme.font(weight)
	t.ZIndex = z
	t.Parent = parent
	return t
end

function Label._use_glyphs(self): boolean
	return (self.spacing ~= 0 or self.tabular) and not self.autowrap and not string.find(self.text, "\n", 1, true)
end

function Label._recolor(self)
	local c3 = UITheme.color3(self.color)
	local a = UITheme.alpha(self.color)
	if self._tl then
		self._tl.TextColor3 = c3
		self:_part(self._tl, "TextTransparency", a)
	end
	for _, g in ipairs(self._glyphs) do
		g.TextColor3 = c3
		self:_part(g, "TextTransparency", a)
	end
end

function Label._redraw(self)
	local w, h = self:px_size()
	if self._geo == nil then
		return
	end
	local ts = UITheme.text_size(self.font_size)
	local s = UITheme.scale
	local lhp = ts
	-- Baseline like Godot: line top + ceil(ascent); Roblox draws it RBX_BASELINE * ts below the
	-- TextLabel's top.
	local lh = UITheme.line_height(self.font_size)
	local line_top = 0
	if self.vertical_alignment == W.VALIGN_CENTER then
		line_top = (self.size.Y - lh) * 0.5
	elseif self.vertical_alignment == W.VALIGN_BOTTOM then
		line_top = self.size.Y - lh
	end
	local y0 = math.floor((line_top + UITheme.ascent(self.font_size)) * s + 0.5)
		- math.floor(ts * UITheme.RBX_BASELINE + 0.5)
	self.gui.ClipsDescendants = self.clip_text
	local font = UITheme.font(self.weight)
	local c3 = UITheme.color3(self.color)
	local a = UITheme.alpha(self.color)
	local sh = self.shadow
	if self:_use_glyphs() then
		if self._tl then
			self:_drop_part(self._tl)
			self._tl:Destroy()
			self._tl = nil
		end
		-- Per-glyph rendering: letter spacing and / or tabular digits.
		local chars = {}
		for _, cp in utf8.codes(self.text) do
			table.insert(chars, utf8.char(cp))
		end
		local sp = self.spacing * s
		local xs = {}
		local ws = {}
		local total
		if self.tabular then
			-- tabular digits: every digit takes the width of "0", centred in its cell
			local x = 0
			for i, ch in ipairs(chars) do
				local adv = UITheme.char_adv_px(ch, ts, self.weight, false)
				local cw = UITheme.char_adv_px(ch, ts, self.weight, true)
				xs[i] = x + (cw - adv) * 0.5
				ws[i] = adv
				x += cw + sp
			end
			total = x
		else
			local pos, adv = UITheme.glyph_positions(self.text, ts, self.weight)
			local prev = 0
			for i = 1, #chars do
				-- monotonic pen positions (kerning never moves a glyph behind its predecessor)
				local p = math.max(pos[i], prev)
				prev = p
				xs[i] = p + sp * (i - 1)
				ws[i] = math.max(0, (if i < #chars then pos[i + 1] else adv) - p)
			end
			total = adv + sp * #chars
		end
		local ox = 0
		if self.horizontal_alignment == W.ALIGN_CENTER then
			ox = math.floor((w - total) * 0.5 + 0.5)
		elseif self.horizontal_alignment == W.ALIGN_RIGHT then
			ox = math.floor(w - total + 0.5)
		end
		for i, ch in ipairs(chars) do
			local g = self._glyphs[i]
			if g == nil then
				g = make_text(self.gui, self.weight, 2)
				self._glyphs[i] = g
			end
			g.FontFace = font
			g.TextSize = ts
			g.Text = ch
			g.TextXAlignment = Enum.TextXAlignment.Left
			g.TextTruncate = Enum.TextTruncate.None
			g.Size = UDim2.fromOffset(math.ceil(ws[i]) + 4, lhp)
			-- Exact (fractional) pen positions: UDim offsets are whole GUI px, which on high-density
			-- screens (phones: 2-3 device px per GUI px) put up to half a GUI px of error on every
			-- glyph -- "Rel axed" (gameplay review). The fraction goes in the Scale part (of this
			-- label's own width); Roblox still snaps glyphs to device pixels, so 1:1 screens stay crisp.
			local px = ox + xs[i]
			local ix = math.floor(px)
			if w > 0 and px - ix > 0.001 then
				g.Position = UDim2.new((px - ix) / w, ix, 0, y0)
			else
				g.Position = UDim2.fromOffset(ix, y0)
			end
			g.TextColor3 = c3
			self:_part(g, "TextTransparency", a)
			g.Visible = true
		end
		for i = #chars + 1, #self._glyphs do
			local g = self._glyphs[i]
			self:_drop_part(g)
			g:Destroy()
			self._glyphs[i] = nil
		end
		self:_render_shadows(sh, ts, font)
		return
	end
	for i = #self._glyphs, 1, -1 do
		self:_drop_part(self._glyphs[i])
		self._glyphs[i]:Destroy()
		self._glyphs[i] = nil
	end
	local tl = self._tl
	if tl == nil then
		tl = make_text(self.gui, self.weight, 2)
		self._tl = tl
	end
	tl.FontFace = font
	tl.TextSize = ts
	tl.Text = self.text
	tl.TextWrapped = self.autowrap
	tl.LineHeight = if self.autowrap then lh * s / ts else 1
	tl.TextXAlignment = if self.horizontal_alignment == W.ALIGN_CENTER
		then Enum.TextXAlignment.Center
		elseif self.horizontal_alignment == W.ALIGN_RIGHT then Enum.TextXAlignment.Right
		else Enum.TextXAlignment.Left
	tl.TextTruncate = if self.text_overrun_behavior == W.OVERRUN_ELLIPSIS
		then Enum.TextTruncate.AtEnd
		else Enum.TextTruncate.None
	-- Wrapped text: Roblox only draws lines whose whole line box fits, and at fractional UI scales
	-- (0.75: 2 lines = 12 * 1.125 * 2 = 27 px in a 25 px box after the baseline offset) the last
	-- line vanished (review_gameplay P1-4). The label's own rect is unchanged; the TextLabel just
	-- gets one line of slack below (top-aligned, so nothing moves).
	tl.Size = UDim2.fromOffset(w, math.max(h - y0, lhp) + (if self.autowrap then ts else 0))
	tl.Position = UDim2.fromOffset(0, y0)
	tl.TextColor3 = c3
	self:_part(tl, "TextTransparency", a)
	self:_render_shadows(sh, ts, font)
end

function Label._render_shadows(self, sh, ts: number, font)
	for _, x in ipairs(self._shadows) do
		self:_drop_part(x)
		x:Destroy()
	end
	table.clear(self._shadows)
	if sh == nil then
		return
	end
	local s = UITheme.scale
	local src = if self._tl then { self._tl } else self._glyphs
	for _, t in ipairs(src) do
		local c = make_text(self.gui, self.weight, 1)
		c.FontFace = font
		c.TextSize = ts
		c.Text = t.Text
		c.TextXAlignment = t.TextXAlignment
		c.TextTruncate = t.TextTruncate
		c.Size = t.Size
		c.Position = t.Position + UDim2.fromOffset(0, math.floor(sh.offset_y * s + 0.5))
		c.TextColor3 = UITheme.color3(sh.color)
		self:_part(c, "TextTransparency", UITheme.alpha(sh.color))
		if sh.outline and sh.outline > 0 then
			local st = Instance.new("UIStroke")
			st.Color = UITheme.color3(sh.color)
			st.Thickness = math.max(1, sh.outline * 0.5 * s)
			st.LineJoinMode = Enum.LineJoinMode.Round
			st.Parent = c
			self:_part(st, "Transparency", UITheme.alpha(sh.color) * 0.6)
		end
		table.insert(self._shadows, c)
	end
end

-- --- Button -------------------------------------------------------------------------------------------------

local Button = class(Control)
W.Button = Button

W.BUTTON_STATES = { "normal", "hover", "pressed", "hover_pressed", "disabled" }

function Button.new(text: string?, variation: string?)
	local self = new_of(Button)
	Control._init(self, "TextButton")
	Button._init_button(self, text, variation)
	return self
end

function Button._init_button(self, text: string?, variation: string?)
	self.theme_type_variation = variation or "Button"
	self.text = text or ""
	self.icon_name = ""
	self.flat = false
	self.disabled = false
	self.toggle_mode = false
	self.button_pressed = false
	self.expand_icon = false
	self.icon_alignment = W.ALIGN_LEFT
	self.vertical_icon_alignment = W.VALIGN_CENTER
	self.alignment = W.ALIGN_CENTER
	self.clip_text = false
	self.focus_mode = 0
	self._hover = false
	self._down = false
	self._font_size = nil
	self.pressed = Signal.new()
	self.toggled = Signal.new()
	self.button_down = Signal.new()
	self.button_up = Signal.new()
	self._sv = StyleView.new(self, 1)
	self._label = Label.new(self.text)
	self:_add_internal(self._label)
	self._label.gui.ZIndex = 5
	self._icon = Icon.new("")
	self:_add_internal(self._icon)
	self._icon.gui.ZIndex = 5
	self._icon:set_visible(false)
	self:set_mouse_filter(W.MOUSE_STOP)
	local g = self.gui :: TextButton
	self:_connect(g.MouseEnter:Connect(function()
		self._hover = true
		self:_refresh_state()
		local serial = W.sound_serial
		if rawget(self, "mouse_entered") then
			self.mouse_entered:Fire()
		end
		-- every button ticks under the pointer, unless its own handler already made a sound
		if W.button_sound ~= nil and W.sound_serial == serial and not self.disabled and not self.silent then
			W.button_sound("hover", self)
		end
	end))
	self:_connect(g.MouseLeave:Connect(function()
		self._hover = false
		self._down = false
		self:_refresh_state()
		if rawget(self, "mouse_exited") then
			self.mouse_exited:Fire()
		end
	end))
	self:_connect(g.InputBegan:Connect(function(io: InputObject)
		local t = io.UserInputType
		if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
			if self.disabled then
				return
			end
			self._down = true
			if t == Enum.UserInputType.Touch then
				self._hover = false
			end
			self:_refresh_state()
			self.button_down:Fire()
		end
		if rawget(self, "gui_input") then
			local ev = W.make_event(io, true, self)
			if ev then
				self.gui_input:Fire(ev)
			end
		end
	end))
	self:_connect(g.InputEnded:Connect(function(io: InputObject)
		local t = io.UserInputType
		if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
			if self._down then
				self._down = false
				self:_refresh_state()
				self.button_up:Fire()
			end
		end
		if rawget(self, "gui_input") then
			local ev = W.make_event(io, false, self)
			if ev then
				self.gui_input:Fire(ev)
			end
		end
	end))
	self:_connect(g.Activated:Connect(function()
		if self.disabled then
			return
		end
		local serial = W.sound_serial
		if self.toggle_mode then
			self.button_pressed = not self.button_pressed
			self:_refresh_state()
			self.toggled:Fire(self.button_pressed)
		end
		self.pressed:Fire()
		-- every press clicks, unless its own handler already made a sound (open, deny, confirm...)
		if W.button_sound ~= nil and W.sound_serial == serial and not self.silent then
			W.button_sound(if self.toggle_mode then "tab" else "press", self)
		end
	end))
	self:_restyle_label()
end

--- The button's style variation (UITheme.theme()[variation]).
function Button._variation(self)
	local t = UITheme.theme()
	return t[self.theme_type_variation] or t.Button
end

function Button.state_name(self): string
	if self.disabled then
		return "disabled"
	end
	local p = self._down or (self.toggle_mode and self.button_pressed)
	if p and self._hover then
		return "hover_pressed"
	elseif p then
		return "pressed"
	elseif self._hover then
		return "hover"
	end
	return "normal"
end

function Button.is_hovered(self): boolean
	return self._hover
end

function Button.is_pressed(self): boolean
	return self.button_pressed or self._down
end

function Button._style_for(self, state: string)
	if self._styles and self._styles[state] then
		return self._styles[state]
	end
	local v = self:_variation()
	return v.styles[state] or v.styles.normal
end

local STATE_FONT = {
	normal = "font_color",
	hover = "font_hover_color",
	pressed = "font_pressed_color",
	hover_pressed = "font_hover_pressed_color",
	disabled = "font_disabled_color",
}
local STATE_ICON = {
	normal = "icon_normal_color",
	hover = "icon_hover_color",
	pressed = "icon_pressed_color",
	hover_pressed = "icon_hover_pressed_color",
	disabled = "icon_disabled_color",
}

function Button._color_for(self, key: string)
	if self._colors and self._colors[key] then
		return self._colors[key]
	end
	return self:_variation().colors[key] or UITheme.TEXT
end

function Button._refresh_state(self)
	if self._draw_state then
		-- custom-drawn buttons (BuildButton, rows) paint their own states
		self:_draw_state()
		return
	end
	local st = self:state_name()
	if not self.flat then
		self._sv:set(self:_style_for(st))
	elseif self._sv.style ~= nil then
		self._sv:set(nil)
	end
	self._label:set_color(self:_color_for(STATE_FONT[st]))
	self._icon:set_color(self:_color_for(STATE_ICON[st]))
end

function Button._restyle_label(self)
	local v = self:_variation()
	self._label:set_font(v.font_weight or 600, v.font_spacing or 0)
	self._label:set_font_size(math.max(self._font_size or v.font_size or 15, UITheme.min_font_size))
	self._label.base_fs = self._font_size or v.font_size or 15
	self._label:set_text(self.text)
	self._label:set_visible(self.text ~= "")
	self._label.clip_text = self.clip_text
	self._label.text_overrun_behavior = if self.clip_text then W.OVERRUN_ELLIPSIS else W.OVERRUN_NONE
	self:_refresh_state()
end

function Button.set_text(self, s: string)
	self.text = s or ""
	self._label:set_text(self.text)
	self._label:set_visible(self.text ~= "")
	self:update_minimum_size()
end

function Button.set_icon(self, icon_name: string?)
	self.icon_name = icon_name or ""
	self._icon:set_icon(self.icon_name)
	self._icon:set_visible(self.icon_name ~= "")
	self:update_minimum_size()
end

function Button.set_font_size(self, size: number)
	self._font_size = size
	self:_restyle_label()
	self:update_minimum_size()
end

function Button.set_disabled(self, on: boolean)
	self.disabled = on
	self._down = false
	self:_refresh_state()
end

function Button.set_flat(self, on: boolean)
	self.flat = on
	self:_refresh_state()
end

function Button.set_toggle_mode(self, on: boolean)
	self.toggle_mode = on
end

function Button.set_pressed_no_signal(self, on: boolean)
	self.button_pressed = on
	self:_refresh_state()
end

function Button.set_pressed(self, on: boolean)
	if self.button_pressed == on then
		return
	end
	self.button_pressed = on
	self:_refresh_state()
	if self.toggle_mode then
		self.toggled:Fire(on)
	end
end

function Button.set_clip_text(self, on: boolean)
	self.clip_text = on
	self:_restyle_label()
	self:update_minimum_size()
end

function Button._theme_changed(self)
	self:update_minimum_size()
	self:_refresh_state()
end

function Button._icon_px(self): number
	local maxw = self:get_theme_constant("icon_max_width", 0) or 0
	local _, t, _, b = UITheme.margins(self:_style_for("normal"))
	local avail = math.max(0, self.size.Y - t - b)
	local px = if maxw > 0 then maxw else 20
	if self.expand_icon and avail > 0 then
		px = math.min(px, avail)
	end
	return px
end

-- Godot Button::get_minimum_size_for_text_and_icon (+ the current style's content margins).
function Button._get_minimum_size(self): Vector2
	local l, t, r, b = UITheme.margins(self:_style_for(self:state_name()))
	local w, h = 0, 0
	local has_text = self.text ~= ""
	local has_icon = self.icon_name ~= ""
	if has_text and not self.clip_text then
		w = self._label:get_combined_minimum_size().X
	end
	if has_icon and not self.expand_icon then
		local maxw = self:get_theme_constant("icon_max_width", 0) or 0
		local ip = if maxw > 0 then maxw else 20
		if self.vertical_icon_alignment == W.VALIGN_CENTER then
			h = math.max(h, ip)
		else
			h += ip
		end
		if self.icon_alignment ~= W.ALIGN_CENTER then
			w += ip
			if has_text then
				w += math.max(0, self:get_theme_constant("h_separation", self:_variation().h_separation or 10) or 10)
			end
		else
			w = math.max(w, ip)
		end
	end
	if has_text then
		local fh = UITheme.line_height(self._label.font_size)
		if self.vertical_icon_alignment == W.VALIGN_CENTER then
			h = math.max(h, fh)
		else
			h += fh
		end
	end
	return Vector2.new(w + l + r, h + t + b)
end

function Button._on_geometry(self)
	self._sv:render()
	if self._draw then
		self:_draw()
	end
end

function Button._restyle(self)
	self._sv:render()
	if self._draw then
		self:_draw()
	end
end

--- Lays out the internal icon + label exactly like Godot's Button::_notification(DRAW): the icon at
--- the left content margin (or centred / right per icon_alignment), the text aligned (centre by
--- default) in the space that remains; icon_max_width caps the icon.
function Button._sort_internal(self)
	local l, t, r, b = UITheme.margins(self:_style_for(self:state_name()))
	local dw, dh = math.max(0, self.size.X - l - r), math.max(0, self.size.Y - t - b)
	local cw, ch = dw, dh -- custom_element_size
	local has_text = self.text ~= ""
	local has_icon = self.icon_name ~= ""
	local sep = self:get_theme_constant("h_separation", self:_variation().h_separation or 10) or 10
	local maxw = self:get_theme_constant("icon_max_width", 0) or 0
	local lab = self._label
	local text_w = if has_text then lab:get_combined_minimum_size().X else 0
	local text_h = if has_text then UITheme.line_height(lab.font_size) else 0
	local ip = 0
	if has_icon then
		if self.expand_icon then
			local w_av, h_av = cw, ch
			if has_text and not self.clip_text and self.icon_alignment ~= W.ALIGN_CENTER then
				w_av -= text_w + sep
			end
			if self.vertical_icon_alignment ~= W.VALIGN_CENTER then
				h_av -= text_h
			end
			ip = math.min(h_av, w_av)
		else
			ip = if maxw > 0 then maxw else 20
		end
		if maxw > 0 then
			ip = math.min(ip, maxw)
		end
		ip = math.max(0, math.floor(ip + 0.5))
		local ix, iy
		if self.icon_alignment == W.ALIGN_CENTER then
			ix = (cw - ip) / 2 + l
		elseif self.icon_alignment == W.ALIGN_RIGHT then
			ix = self.size.X - r - ip
		else
			ix = l
		end
		if self.vertical_icon_alignment == W.VALIGN_TOP then
			iy = t
		elseif self.vertical_icon_alignment == W.VALIGN_BOTTOM then
			iy = self.size.Y - b - ip
		else
			iy = (ch - ip) / 2 + t
		end
		self._icon:_apply_rect(Vector2.new(math.floor(ix), math.floor(iy)), Vector2.new(ip, ip))
		if has_text then
			if self.icon_alignment ~= W.ALIGN_CENTER then
				dw -= ip + sep
			end
			if self.vertical_icon_alignment ~= W.VALIGN_CENTER then
				dh -= ip
			end
		end
	end
	if has_text then
		local tw = math.ceil(math.max(1, dw))
		local tx = l
		if has_icon and self.icon_alignment == W.ALIGN_LEFT then
			tx += cw - dw
		end
		local ty = (dh - text_h) / 2 + t
		if has_icon and self.vertical_icon_alignment == W.VALIGN_TOP then
			ty += ch - dh
		end
		lab.horizontal_alignment = self.alignment
		lab:_apply_rect(Vector2.new(tx, ty), Vector2.new(tw, text_h))
		lab:_redraw()
	end
end

-- =============================================================================================
-- wrap(): a native GuiObject as a node
-- =============================================================================================

--- Wrap a native GuiObject so it can live in the node tree (positioned / sized by layout; its
--- own descendants are untouched). Its AnchorPoint is set to (0.5, 0.5).
function W.wrap(g: GuiObject)
	local self = new_of(Control)
	g.AnchorPoint = Vector2.new(0.5, 0.5)
	Control._init(self, nil, g)
	self:set_mouse_filter(if g.Active then W.MOUSE_STOP else W.MOUSE_IGNORE)
	return self
end

-- =============================================================================================
-- Tween (Godot 4 Tween semantics & easing equations)
-- =============================================================================================

local PI = math.pi

local function ease_in(trans: number, t: number): number
	if trans == W.TRANS_LINEAR then
		return t
	elseif trans == W.TRANS_SINE then
		return 1 - math.cos(t * PI / 2)
	elseif trans == W.TRANS_QUINT then
		return t ^ 5
	elseif trans == W.TRANS_QUART then
		return t ^ 4
	elseif trans == W.TRANS_QUAD then
		return t * t
	elseif trans == W.TRANS_EXPO then
		return if t == 0 then 0 else 2 ^ (10 * (t - 1)) - 0.001
	elseif trans == W.TRANS_ELASTIC then
		if t == 0 or t == 1 then
			return t
		end
		local p = 0.3
		local s = p / 4
		local u = t - 1
		return -(2 ^ (10 * u) * math.sin((u - s) * (2 * PI) / p))
	elseif trans == W.TRANS_CUBIC then
		return t * t * t
	elseif trans == W.TRANS_CIRC then
		return -(math.sqrt(1 - t * t) - 1)
	elseif trans == W.TRANS_BOUNCE then
		local function out(x)
			if x < 1 / 2.75 then
				return 7.5625 * x * x
			elseif x < 2 / 2.75 then
				x -= 1.5 / 2.75
				return 7.5625 * x * x + 0.75
			elseif x < 2.5 / 2.75 then
				x -= 2.25 / 2.75
				return 7.5625 * x * x + 0.9375
			end
			x -= 2.625 / 2.75
			return 7.5625 * x * x + 0.984375
		end
		return 1 - out(1 - t)
	elseif trans == W.TRANS_BACK then
		local s = 1.70158
		return t * t * ((s + 1) * t - s)
	elseif trans == W.TRANS_SPRING then
		-- spring is defined as an "out" curve in Godot; in = 1 - out(1 - t)
		local x = 1 - t
		local o = (math.sin(x * PI * (0.2 + 2.5 * x * x * x)) * ((1 - x) ^ 2.2) + x) * (1 + 1.2 * (1 - x))
		return 1 - o
	end
	return t
end

local function ease_out(trans: number, t: number): number
	if trans == W.TRANS_EXPO then
		return if t == 1 then 1 else 1.001 * (1 - 2 ^ (-10 * t))
	elseif trans == W.TRANS_SPRING then
		return (math.sin(t * PI * (0.2 + 2.5 * t * t * t)) * ((1 - t) ^ 2.2) + t) * (1 + 1.2 * (1 - t))
	end
	return 1 - ease_in(trans, 1 - t)
end

function W.ease(trans: number, ease: number, t: number): number
	t = math.clamp(t, 0, 1)
	if ease == W.EASE_IN then
		return ease_in(trans, t)
	elseif ease == W.EASE_OUT then
		return ease_out(trans, t)
	elseif ease == W.EASE_IN_OUT then
		if t < 0.5 then
			return ease_in(trans, t * 2) * 0.5
		end
		return ease_out(trans, t * 2 - 1) * 0.5 + 0.5
	else
		if t < 0.5 then
			return ease_out(trans, t * 2) * 0.5
		end
		return ease_in(trans, t * 2 - 1) * 0.5 + 0.5
	end
end

local function interp(a: any, b: any, k: number): any
	local ta = typeof(a)
	if ta == "number" then
		return a + (b - a) * k
	elseif ta == "Vector2" then
		return a:Lerp(b, k)
	elseif ta == "Color3" then
		return a:Lerp(b, k)
	elseif UITheme.is_rgba(a) or UITheme.is_rgba(b) then
		return UITheme.lerp(a, b, k)
	end
	return if k >= 1 then b else a
end

local Tweener = {}
Tweener.__index = Tweener

function Tweener.set_trans(self, t: number)
	self.trans = t
	return self
end

function Tweener.set_ease(self, e: number)
	self.ease = e
	return self
end

function Tweener.set_delay(self, d: number)
	self.delay = d
	return self
end

function Tweener.from(self, v: any)
	self.from_v = v
	return self
end

function Tweener.from_current(self)
	self.from_v = nil
	return self
end

local Tween = {}
Tween.__index = Tween
W.Tween = Tween

function Tween.new(owner)
	local self = setmetatable({
		owner = owner,
		steps = {},
		cur = 1,
		t = 0,
		trans = W.TRANS_LINEAR,
		ease = W.EASE_IN_OUT,
		parallel = false,
		_next_parallel = false,
		_chain = false,
		_alive = true,
		_started = false,
		finished = Signal.new(),
	}, Tween)
	table.insert(_tweens, self)
	return self
end

function Tween._add(self, tw)
	tw.trans = tw.trans or self.trans
	tw.ease = tw.ease or self.ease
	local n = #self.steps
	if n == 0 or self._chain or not (self._all_parallel or self._next_parallel) then
		table.insert(self.steps, { tw })
	else
		table.insert(self.steps[n], tw)
	end
	self._chain = false
	self._next_parallel = false
	return tw
end

function Tween.set_parallel(self, on: boolean?)
	-- (`_all_parallel`, not `parallel`: Tween.parallel is the method below)
	self._all_parallel = if on == nil then true else on
	return self
end

function Tween.parallel(self)
	self._next_parallel = true
	return self
end

function Tween.chain(self)
	self._chain = true
	return self
end

function Tween.set_trans(self, t: number)
	self.trans = t
	return self
end

function Tween.set_ease(self, e: number)
	self.ease = e
	return self
end

function Tween.tween_property(self, obj, key: string, to: any, dur: number)
	return self:_add(setmetatable({ kind = "prop", obj = obj, key = key, to = to, dur = dur, delay = 0 }, Tweener))
end

function Tween.tween_method(self, fn, from: any, to: any, dur: number)
	return self:_add(setmetatable({ kind = "method", fn = fn, from_v = from, to = to, dur = dur, delay = 0 }, Tweener))
end

function Tween.tween_interval(self, dur: number)
	return self:_add(setmetatable({ kind = "interval", dur = dur, delay = 0 }, Tweener))
end

function Tween.tween_callback(self, fn)
	return self:_add(setmetatable({ kind = "callback", fn = fn, dur = 0, delay = 0 }, Tweener))
end

function Tween.kill(self)
	self._alive = false
end

function Tween.is_running(self): boolean
	return self._alive
end
Tween.is_valid = Tween.is_running

local function get_prop(obj, key)
	if obj.tween_get then
		return obj:tween_get(key)
	end
	return obj[key]
end

local function set_prop(obj, key, v)
	if obj.tween_set then
		obj:tween_set(key, v)
	else
		obj[key] = v
	end
end

function Tween._step(self, dt: number)
	if self.owner ~= nil and self.owner._freed then
		self._alive = false
		return
	end
	local remaining = dt
	while self._alive do
		local step = self.steps[self.cur]
		if step == nil then
			self._alive = false
			self.finished:Fire()
			return
		end
		if not step._started then
			step._started = true
			step.t = 0
			for _, tw in ipairs(step) do
				tw.done = false
				tw.began = false
			end
		end
		step.t += remaining
		local all_done = true
		local max_over = math.huge
		for _, tw in ipairs(step) do
			if not tw.done then
				local lt = step.t - tw.delay
				if lt >= 0 then
					if not tw.began then
						tw.began = true
						if tw.kind == "prop" then
							tw.start_v = if tw.from_v ~= nil then tw.from_v else get_prop(tw.obj, tw.key)
						end
					end
					if tw.kind == "callback" then
						tw.done = true
						guard("tween_callback", tw.fn)
						if not self._alive then
							return
						end
					else
						local k = if tw.dur <= 0 then 1 else math.min(lt / tw.dur, 1)
						local e = if tw.kind == "interval" then k else W.ease(tw.trans, tw.ease, k)
						local ok = true
						if tw.kind == "prop" then
							if tw.obj._freed then
								self._alive = false
								return
							end
							ok = guard(
								"tween_property " .. tostring(tw.key),
								set_prop,
								tw.obj,
								tw.key,
								if k >= 1 then tw.to else interp(tw.start_v, tw.to, e)
							)
						elseif tw.kind == "method" then
							ok = guard("tween_method", tw.fn, if k >= 1 then tw.to else interp(tw.from_v, tw.to, e))
						end
						-- a failing tweener is finished (the rest of its tween still runs)
						if k >= 1 or not ok then
							tw.done = true
						end
					end
				end
				if not tw.done then
					all_done = false
				else
					max_over = math.min(max_over, lt - tw.dur)
				end
			end
		end
		if not all_done then
			return
		end
		-- carry the overshoot into the next step
		local over = 0
		for _, tw in ipairs(step) do
			over = math.max(over, tw.delay + tw.dur)
		end
		remaining = math.max(0, step.t - over)
		self.cur += 1
		if remaining <= 0 then
			if self.steps[self.cur] == nil then
				self._alive = false
				self.finished:Fire()
			end
			return
		end
	end
end

-- =============================================================================================
-- UIWidgets animation helpers (widgets.gd)
-- =============================================================================================

--- Fade + settle a control in (staggered entrances). Only touches modulate and scale.
function W.pop_in(c, delay: number?, from_scale: number?, dur: number?)
	local d = delay or 0.0
	local fs = from_scale or 0.96
	local du = dur or 0.4
	c:set_modulate_a(0.0)
	local t = c:create_tween()
	if d > 0 then
		t:tween_interval(d)
	end
	t:tween_callback(function()
		c:set_scale(fs)
	end)
	t:set_parallel(true)
	t:tween_property(c, "modulate:a", 1.0, du * 0.8):set_trans(W.TRANS_CUBIC):set_ease(W.EASE_OUT)
	t:tween_property(c, "scale", 1.0, du):set_trans(W.TRANS_BACK):set_ease(W.EASE_OUT)
	return t
end

function W.fade(c, to: number, dur: number?)
	local t = c:create_tween()
	t:tween_property(c, "modulate:a", to, dur or 0.2):set_trans(W.TRANS_CUBIC):set_ease(W.EASE_OUT)
	return t
end

--- Hover grow for buttons (pivot centred).
function W.hover_grow(b, amount: number?)
	local a = amount or 1.04
	b.mouse_entered:Connect(function()
		local t = b:create_tween()
		t:tween_property(b, "scale", a, 0.12):set_trans(W.TRANS_CUBIC):set_ease(W.EASE_OUT)
	end)
	b.mouse_exited:Connect(function()
		local t = b:create_tween()
		t:tween_property(b, "scale", 1.0, 0.16):set_trans(W.TRANS_CUBIC):set_ease(W.EASE_OUT)
	end)
end

--- Slide an anchored control in from an offset (a transient shift on top of its anchor offsets;
--- a re-layout mid-slide takes the new offsets as the base, so layout and animation never fight).
function W.slide_in(c, from_offset: Vector2, delay: number?, dur: number?)
	local d = delay or 0.0
	local du = dur or 0.45
	W._set_shift(c, Vector2.zero)
	c:set_modulate_a(0.0)
	W._set_shift(c, from_offset)
	local t = c:create_tween():set_parallel(true)
	t:tween_method(function(v: Vector2)
		W._set_shift(c, v)
	end, from_offset, Vector2.zero, du)
		:set_delay(d)
		:set_trans(W.TRANS_QUINT)
		:set_ease(W.EASE_OUT)
	t:tween_property(c, "modulate:a", 1.0, du * 0.7):set_delay(d):set_trans(W.TRANS_CUBIC):set_ease(W.EASE_OUT)
	return t
end

function W._set_shift(c, v: Vector2)
	if c._freed then
		return
	end
	local cur = Vector2.new(c.offset_left, c.offset_top)
	local shift: Vector2 = c:get_meta("slide_shift", Vector2.zero)
	local base: Vector2 = c:get_meta("slide_base", cur - shift)
	if (cur - (base + shift)).Magnitude > 1e-3 then
		base = cur -- a layout pass wrote fresh (unshifted) offsets
	end
	local d = base + v - cur
	c.offset_left += d.X
	c.offset_right += d.X
	c.offset_top += d.Y
	c.offset_bottom += d.Y
	c:set_meta("slide_shift", v)
	c:set_meta("slide_base", base)
	c:queue_layout()
end

return W
