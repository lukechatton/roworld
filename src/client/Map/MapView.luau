--!strict
-- The 2D world view (a flat tile map), replacing the 3D globe WorldView with the same
-- public API (DESIGN.md §10), so UIRoot / Main / Session drive it unchanged:
--   signals tile_hovered(tile), tile_clicked(tile), tile_context(tile, screen_pos),
--   territory_status_changed(status); bind_state, set_attract_mode, focus_tile, focus_owner,
--   set_hover_owner, set_selected_owner, set_selected_unit, unit_at_screen, set_aim,
--   aim_sams, set_range_*, set_safe_area, set_hud_rects / controls, local_label_rect,
--   set_labels_visible, tile_at_screen, screen_pos_of_tile, camera_distance, project, update.
--
-- Rendering: three ScreenGuis under the HUD (DisplayOrder MAP_DISPLAY_ORDER and the two above it):
--   RofrontMap        Surface (MapSurface: terrain + territory images, pixel-crisp, wrapped
--                     east-west) and the Overlay with what seldom changes: spawn / aim markers,
--                     rails, ranges, structure plates;
--   RofrontMapUnits   what moves every frame: ships, trains, wakes, munitions, effects, and the
--                     structures' progress bars;
--   RofrontMapLabels  names and front numbers (they change with the troop counts).
-- Why three (2026-10-08; players on Windows had stutter bad enough to quit, ten minutes into a
-- match): Roblox lays out and draws a ScreenGui again as a whole
-- when anything in it changed, and nothing at all when nothing did. As one ScreenGui the map was
-- about 13,000 objects twenty minutes into a World match, all of them gone over every frame
-- because some ship had moved a pixel: 9 ms a frame on the Mac that measured it (with the match
-- paused: 0.2 ms). The moving layers are a small tree of their own now (docs/performance.md).
-- Input: MapInput (mouse / touch / keys) driving the MapCamera through the camera-rig API.
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RS = game:GetService("ReplicatedStorage")
local Core = RS:WaitForChild("Airfront"):WaitForChild("Core")
local Defs = require(Core:WaitForChild("Defs")) :: any
local Signal = require(Core:WaitForChild("Signal")) :: any
local Rules = require(Core:WaitForChild("Rules")) :: any

local MapCamera = require(script.Parent:WaitForChild("MapCamera"))
local MapSurface = require(script.Parent:WaitForChild("MapSurface"))

local N: number = Defs.TILE_COUNT

local MapView = {}
MapView.__index = MapView

MapView.RENDER_PRIORITY = Enum.RenderPriority.Camera.Value + 1
--- Seconds the pointer rests on a nation before the surface highlights it (its name and its range
--- rings follow at once). A highlight repaints the nation's border, and its land when it is small:
--- a pointer on its way across the map should start none (Map/MapSurface.HOVER_FILL_MAX).
MapView.HOVER_DELAY_S = 0.08
MapView.MAP_DISPLAY_ORDER = -10
--- focus_owner zooms in at most this far along the zoom range (0 = farthest, 1 = closest).
MapView.FOCUS_MAX_ZOOM = 0.3
--- Spawn-phase ring around the local player's placed spawn (breathing between SPAWN_MIN_RAD and
--- SPAWN_MAX_RAD full-size tiles). Nothing follows the cursor before the player picks a spot.
MapView.SPAWN_MIN_RAD = 10
MapView.SPAWN_MAX_RAD = 30

local function report(site: string, err: any)
	warn(string.format("[RoWorld] map view %s: %s", site, tostring(err)))
end

local _reported: { [string]: boolean } = {}
local function guard(site: string, fn: (...any) -> any, ...: any): (boolean, any)
	local ok, res = pcall(fn, ...)
	if not ok and not _reported[site] then
		_reported[site] = true
		report(site, res)
	end
	return ok, res
end

local function call(layer: any, method: string, ...: any): any
	if layer == nil then
		return nil
	end
	local f = layer[method]
	if type(f) ~= "function" then
		return nil
	end
	local ok, res = guard(method, f, layer, ...)
	return if ok then res else nil
end

local function optional(folder: Instance, name: string): any
	local m = folder:FindFirstChild(name)
	if m == nil or not m:IsA("ModuleScript") then
		return nil
	end
	local ok, mod = pcall(require, m)
	if not ok then
		report("require " .. name, mod)
		return nil
	end
	return mod
end

-- ---------------------------------------------------------------------------------------------
-- Map-space markers: spawn preview disk, aim disk / reticle
-- ---------------------------------------------------------------------------------------------

local function ring(parent: Instance, name: string, z: number): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.BackgroundColor3 = Color3.new(1, 1, 1)
	f.BackgroundTransparency = 0.75
	f.BorderSizePixel = 0
	f.ZIndex = z
	f.Visible = false
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0.5, 0)
	c.Parent = f
	local s = Instance.new("UIStroke")
	s.Color = Color3.new(1, 1, 1)
	s.Thickness = 2
	s.Transparency = 0.1
	s.Parent = f
	f.Parent = parent
	return f
end

export type MapView = typeof(setmetatable({} :: { [string]: any }, MapView))

function MapView.new(): MapView
	local self = setmetatable({}, MapView) :: any
	self.tile_hovered = Signal.new()
	self.tile_clicked = Signal.new()
	self.tile_context = Signal.new()
	self.territory_status_changed = Signal.new()
	self.input_enabled = true

	local gui = Instance.new("ScreenGui")
	gui.Name = "RofrontMap"
	gui.IgnoreGuiInset = true
	-- the whole screen, notch / home-bar areas included: the camera and input work in full-viewport
	-- px (Camera.ViewportSize), and the map is the backdrop (the default CoreUISafeInsets left dark
	-- bands on phones and shifted the map by the safe-area inset)
	gui.ScreenInsets = Enum.ScreenInsets.None
	gui.ResetOnSpawn = false
	gui.DisplayOrder = MapView.MAP_DISPLAY_ORDER
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	self.gui = gui
	-- the backdrop covers the whole screen (notch / home-bar areas too); the map draws in `canvas`,
	-- a frame whose origin is the camera viewport's (Camera.ViewportSize, the viewport px input
	-- and the UI use). On a notched phone the full screen starts ~47 px left of the viewport:
	-- drawing from the backdrop's origin put every tap ~47 px off (2026-09-28).
	local backdrop = Instance.new("Frame")
	backdrop.Name = "Backdrop"
	backdrop.Size = UDim2.fromScale(1, 1)
	backdrop.BackgroundColor3 = Color3.fromRGB(0x3c, 0x3c, 0x3c)
	backdrop.BorderSizePixel = 0
	backdrop.ClipsDescendants = true
	backdrop.Parent = gui
	self.backdrop = backdrop
	local canvas = Instance.new("Frame")
	canvas.Name = "Canvas"
	canvas.BackgroundTransparency = 1
	canvas.Size = UDim2.fromScale(1, 1)
	canvas.Parent = backdrop
	self.canvas = canvas
	backdrop:GetPropertyChangedSignal("AbsolutePosition"):Connect(function()
		self:_place_canvas()
	end)
	backdrop:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		self:_place_canvas()
	end)

	self.rig = MapCamera.new(workspace.CurrentCamera)
	self.camera = self.rig
	self.surface = MapSurface.new(canvas)
	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		-- (a phone or tablet: the same as Session's test for one)
		self.surface.budget_s = MapSurface.STEP_BUDGET_MOBILE_S
	end
	local overlay = Instance.new("Frame")
	overlay.Name = "Overlay"
	overlay.Size = UDim2.fromScale(1, 1)
	overlay.BackgroundTransparency = 1
	overlay.ZIndex = 5
	overlay.Parent = canvas
	self.overlay = overlay
	-- the moving layers and the labels, each a ScreenGui of its own above the map's (see the header)
	self._canvases = { canvas }
	self._guis = { gui }
	local function layer_gui(name: string, order: number): Frame
		local g = Instance.new("ScreenGui")
		g.Name = name
		g.IgnoreGuiInset = true
		g.ScreenInsets = Enum.ScreenInsets.None
		g.ResetOnSpawn = false
		g.DisplayOrder = order
		g.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		local hold = Instance.new("Frame")
		hold.Name = "Backdrop"
		hold.Size = UDim2.fromScale(1, 1)
		hold.BackgroundTransparency = 1
		hold.BorderSizePixel = 0
		hold.ClipsDescendants = true
		hold.Parent = g
		local c = Instance.new("Frame")
		c.Name = "Canvas"
		c.BackgroundTransparency = 1
		c.Size = UDim2.fromScale(1, 1)
		c.Parent = hold
		table.insert(self._canvases, c)
		table.insert(self._guis, g)
		return c
	end
	local moving = layer_gui("RofrontMapUnits", MapView.MAP_DISPLAY_ORDER + 1)
	local labels = layer_gui("RofrontMapLabels", MapView.MAP_DISPLAY_ORDER + 2)
	--- where a layer of the seldom-changing ScreenGui puts what it animates (StructureLayer's bars)
	self.moving_overlay = moving
	self._spawn_ring = ring(overlay, "SpawnPreview", 6)
	self._aim_ring = ring(overlay, "AimOuter", 7)
	self._aim_inner = ring(overlay, "AimInner", 8)

	local MapInput = optional(script.Parent, "MapInput")
	self.input = if MapInput then MapInput.new(self, self.rig) else nil

	-- overlay layers drawn on the map (Map/<Name>Layer), each optional, in draw / update order
	self.layers = {} :: { [string]: any }
	self._layer_order = {} :: { string }
	self.view_rules = optional(script.Parent, "ViewRules")
	for _, spec in
		{
			{ "glow", "FalloutGlow", overlay },
			{ "roads", "RoadLayer", overlay },
			{ "ranges", "RangeLayer", overlay },
			{ "structures", "StructureLayer", overlay },
			{ "units", "UnitLayer", moving },
			{ "fx", "FxLayer", moving },
			{ "labels", "NameLayer", labels },
			{ "fronts", "FrontLayer", labels },
		}
	do
		local mod = optional(script.Parent, spec[2] :: string)
		if mod then
			local ok, layer = pcall(mod.new, spec[3], self)
			if ok then
				self:add_layer(spec[1] :: string, layer)
			else
				report((spec[2] :: string) .. ".new", layer)
			end
		end
	end

	self._state = nil :: any
	self._conns = {} :: { any }
	self._attract = false
	self._last_local = -1
	self._aim = nil :: any
	self._selected_unit = -1
	self._selected_owner = 0
	self._hover_owner = 0
	self._safe_area = Rect.new(0, 0, 0, 0)
	self._hud_rects = {} :: { Rect }
	self._hud_controls = {} :: { GuiObject }
	self._labels_visible = true
	self._perf = {} :: { [string]: number }
	self._status = { state = "loading", tier = "map", reason = "" }

	-- the 3D camera only has to show nothing behind the GUI
	local cam = workspace.CurrentCamera
	if cam then
		cam.CameraType = Enum.CameraType.Scriptable
		cam.CFrame = CFrame.new(0, 10000, 0) * CFrame.Angles(-math.pi / 2, 0, 0)
	end

	local pg = Players.LocalPlayer:WaitForChild("PlayerGui")
	for _, g in self._guis do
		g.Parent = pg
	end
	self:_place_canvas()

	self.tile_hovered:Connect(function(t: number)
		self:_on_tile_hovered(t)
	end)
	self._render_name = "RofrontMapView"
	local FrameClock = require(script.Parent:WaitForChild("FrameClock")) :: any
	RunService:BindToRenderStep(self._render_name, MapView.RENDER_PRIORITY, function(dt: number)
		guard("update", self.update, self, FrameClock.dt(dt))
	end)
	-- the map: terrain composited off the boot path (the default map until a state names another)
	self._map = nil :: any
	task.spawn(function()
		self:_show_map(require(Core:WaitForChild("WorldMap")).shared())
	end)
	return self
end

--- Show `map` (a WorldMap): camera bounds + surface terrain (slow: yields while it builds).
function MapView._show_map(self: any, map: any)
	if map == nil or map == self._map then
		return
	end
	self._map = map
	self.rig:set_map(map)
	local ok, err = pcall(function()
		self.surface:set_map(map)
	end)
	if not ok then
		report("map", err)
	end
	self:_set_status(if self.surface.ok then "ok" else "unavailable", if self.surface.ok then "" else "memory")
	if self._attract then
		self.rig:set_scale_immediate(self.rig:min_scale() * 2.2)
	end
end

function MapView._set_status(self: any, state: string, reason: string)
	if self._status.state == state and self._status.reason == reason then
		return
	end
	self._status = { state = state, tier = "map", reason = reason }
	self.territory_status_changed:Fire(self._status)
end

--- Add an overlay layer (module with new(parent, view)); kept in update / bind order.
function MapView.add_layer(self: any, name: string, layer: any)
	if layer == nil then
		return
	end
	self.layers[name] = layer
	self[name] = layer
	table.insert(self._layer_order, name)
end

-- ---------------------------------------------------------------------------------------------
-- State binding
-- ---------------------------------------------------------------------------------------------

function MapView._connect(self: any, sig: any, fn: (...any) -> ())
	if sig ~= nil and sig.Connect then
		table.insert(self._conns, sig:Connect(fn))
	end
end

function MapView.bind_state(self: any, state: any)
	self:unbind(state ~= nil)
	if state == nil then
		return
	end
	self._state = state
	if self.view_rules then
		self.view_rules.use(state.rules)
	end
	local surface = self.surface
	self:_connect(state.snapshot_loaded, function()
		surface:bind(state)
		call(self.layers.glow, "on_snapshot")
		if self.view_rules then
			self.view_rules.use(state.rules)
		end
	end)
	self:_connect(state.tiles_changed, function(ch, olds)
		surface:on_tiles_changed(ch, olds)
	end)
	self:_connect(state.flags_changed, function(ch)
		surface:on_flags_changed(ch)
		call(self.layers.glow, "on_flags_changed", ch)
	end)
	self:_connect(state.owner_added, function(id)
		surface:refresh_palette()
		-- (an owner that is sent again with land already on the map, in another colour: a slot that
		-- changed hands. Its tiles kept the old colour until each was next repainted. A new owner
		-- has no land yet and this does nothing.)
		surface:repaint_owner(id)
	end)
	self:_connect(state.cosmetics_changed, function(ids)
		surface:on_cosmetics_changed(ids)
		call(self.layers.names, "on_cosmetics_changed", ids)
	end)
	self:_connect(state.alliance_changed, function(a, b, _formed, _traitor)
		surface:refresh_palette()
		surface:repaint_between(a, b)
	end)
	for _, pair in
		{
			{ "structure_added", "on_structure_added" },
			{ "structure_changed", "on_structure_changed" },
			{ "structure_removed", "on_structure_removed" },
			{ "structure_leveled", "on_structure_leveled" },
		}
	do
		self:_connect(state[pair[1]], function(...)
			for _, name in self._layer_order do
				call(self.layers[name], pair[2], ...)
			end
		end)
	end
	self:_connect(state.alliance_changed, function()
		call(self.layers.ranges, "mark_dirty")
	end)
	self:_connect(state.road_added, function(rid)
		call(self.layers.roads, "mark_road_dirty", rid)
	end)
	self:_connect(state.road_removed, function(rid)
		call(self.layers.roads, "mark_road_dirty", rid)
	end)
	self:_connect(state.nuke_detonated, function(uid, kind, tile, radius, _owner)
		self:_on_nuke_detonated(uid, kind, tile, radius)
	end)
	self:_connect(state.unit_removed, function(uid, reason)
		self:_on_unit_removed(uid, reason)
	end)
	self:_connect(state.conquest, function(by, victim, gold)
		self:_on_conquest(by, victim, gold)
	end)
	-- only the local player's income shows
	self:_connect(state.bonus, function(owner, tile, gold)
		if owner ~= 0 and owner == state.local_owner then
			call(self.layers.fx, "bonus", tile, gold)
		end
	end)
	surface:bind(state)
	if state.map ~= nil and state.map ~= self._map then
		task.spawn(function()
			self:_show_map(state.map)
		end)
	end
	for _, name in self._layer_order do
		call(self.layers[name], "bind", state)
	end
	self._last_local = state.local_owner or 0
end

function MapView.unbind(self: any, _rebinding: boolean?)
	for _, c in self._conns do
		c:Disconnect()
	end
	table.clear(self._conns)
	if self._state == nil then
		return
	end
	self._state = nil
	self.surface:unbind()
	for _, name in self._layer_order do
		call(self.layers[name], "unbind")
	end
	self:set_aim("", -1, 0)
	call(self.input, "set_hover_tile", -1)
end

function MapView.set_attract_mode(self: any, on: boolean)
	self._attract = on
	self.rig.attract = on
	if on then
		call(self.input, "reset")
		self.rig:halt()
		self.rig:set_scale_immediate(self.rig:min_scale() * 2.2)
	end
end

function MapView.is_attract(self: any): boolean
	return self._attract
end

function MapView.territory_status(self: any): { [string]: any }
	return self._status
end

function MapView.set_input_enabled(self: any, on: boolean)
	if self.input_enabled == on then
		return
	end
	self.input_enabled = on
	call(self.input, if on then "enable" else "disable")
end

function MapView.touch_owned_by_world(self: any, io: any): boolean
	if self.input == nil then
		return false
	end
	return self.input:touch_owned_by_world(io)
end

-- ---------------------------------------------------------------------------------------------
-- Camera
-- ---------------------------------------------------------------------------------------------

--- Fly to `tile`; `distance` is the globe camera's (1 + altitude, < 0 keeps the zoom).
function MapView.focus_tile(self: any, tile: number, distance: number?, duration: number?)
	if tile < 0 or tile >= N then
		return
	end
	local d = distance or -1.0
	local s = if d > 0 then self.rig:distance_to_scale(d) else -1.0
	self.rig:focus_tile(tile, s, duration or 1.0)
end

function MapView.focus_owner(self: any, owner_id: number)
	local st = self._state
	if st == nil then
		return
	end
	local tile = st:label_tile(owner_id)
	if tile < 0 then
		return
	end
	local o = st:get_owner(owner_id)
	local tiles = if o ~= nil then o.tiles else 50.0
	-- frame the nation: its rough diameter takes about a sixth of the view height, never closer
	-- than FOCUS_MAX_ZOOM of the zoom range (a new nation is only a few tiles across)
	local diam = 2.0 * math.sqrt(math.max(tiles, 1.0) / math.pi)
	local rig = self.rig
	local s = rig:viewport_height() / math.max(diam * 6.0, 8.0)
	local lo, hi = rig:min_scale(), rig:max_scale()
	s = math.min(s, lo + (hi - lo) * MapView.FOCUS_MAX_ZOOM)
	rig:focus_tile(tile, rig:clamp_scale(s), 1.0)
end

--- Globe camera distance equivalent of the current zoom (1 + altitude).
function MapView.camera_distance(self: any): number
	return self.rig:scale_to_distance(self.rig.scale)
end

function MapView.tile_at_screen(self: any, pos: Vector2): number
	return self.rig:tile_at_screen(pos)
end

function MapView.screen_pos_of_tile(self: any, tile: number): Vector2
	if tile < 0 or tile >= N then
		return Vector2.new(-1, -1)
	end
	local x, y = self.rig:tile_to_screen(tile)
	return Vector2.new(x, y)
end

--- Legacy world position (unit direction, or studs on the R = 100 globe) -> viewport px, and
--- whether it is on screen.
function MapView.project(self: any, p: Vector3): (Vector2, boolean)
	local x, y = self.rig:xyz_to_screen(p.X, p.Y, p.Z)
	return Vector2.new(x, y), self.rig:on_screen(x, y, 0)
end

--- The part of the viewport (px) not covered by HUD panels: the view anchor sits in its middle.
function MapView.set_safe_area(self: any, rect: Rect)
	self._safe_area = rect
	local labels = self.layers.labels
	if labels then
		labels.safe_rect = rect
		labels.layout_dirty = true
	end
	self:_update_screen_offset()
end

--- Lines the drawing frame up with the camera viewport inside the full-screen backdrop.
function MapView._place_canvas(self: any)
	local GuiService = game:GetService("GuiService")
	local origin = self.backdrop.AbsolutePosition + GuiService:GetGuiInset() -- viewport px
	local vp = self.rig:viewport_size()
	-- (every ScreenGui of the map is the same full screen: one origin serves them all)
	for _, c in self._canvases do
		c.Position = UDim2.fromOffset(-origin.X, -origin.Y)
		c.Size = UDim2.fromOffset(vp.X, vp.Y)
	end
end

function MapView._update_screen_offset(self: any)
	local sa = self._safe_area
	local sz = self.rig:viewport_size()
	if sa == nil or sa.Width <= 1.0 or sa.Height <= 1.0 then
		self.rig.screen_offset = Vector2.zero
		return
	end
	local c = (sa.Min + sa.Max) * 0.5
	self.rig.screen_offset = c - sz * 0.5
end

function MapView.set_hud_rects(self: any, rects: { Rect })
	self._hud_rects = table.clone(rects or {})
	self:_update_obstacles()
end

function MapView.set_hud_controls(self: any, controls: { any })
	local list = {}
	for _, c in controls or {} do
		if typeof(c) == "Instance" and c:IsA("GuiObject") then
			table.insert(list, c)
		elseif type(c) == "table" and typeof(c.gui) == "Instance" then
			table.insert(list, c.gui)
		end
	end
	self._hud_controls = list
	self:_update_obstacles()
end

function MapView._update_obstacles(self: any)
	local labels = self.layers.labels
	if labels == nil then
		return
	end
	labels.obstacles = table.clone(self._hud_rects)
	labels.obstacle_controls = self._hud_controls
	labels.layout_dirty = true
end

function MapView.local_label_rect(self: any): Rect?
	return call(self.layers.labels, "local_label_rect")
end

function MapView.set_labels_visible(self: any, on: boolean)
	self._labels_visible = on
	call(self.layers.labels, "set_visible", on)
end

-- ---------------------------------------------------------------------------------------------
-- Highlights, selection, previews
-- ---------------------------------------------------------------------------------------------

function MapView.set_hover_owner(self: any, id: number)
	self._hover_owner = id
	-- (the surface's highlight waits HOVER_DELAY_S for the pointer to rest: update())
	self:_want_surface_hover(if id > 0 then id else self._selected_owner, MapView.HOVER_DELAY_S)
	local labels = self.layers.labels
	if labels then
		labels.hover_owner = id
	end
	call(self.layers.ranges, "set_hover_owner", id)
end

function MapView.set_selected_owner(self: any, id: number)
	self._selected_owner = id
	if self._hover_owner <= 0 then
		self:_want_surface_hover(id, 0)
	end
end

--- The owner the surface is to highlight, once `delay_s` have passed without another being asked
--- for: a pointer crossing nations on its way somewhere highlights none of them.
function MapView._want_surface_hover(self: any, id: number, delay_s: number)
	if self._surface_hover_want == id then
		return
	end
	self._surface_hover_want = id
	self._surface_hover_at = os.clock() + delay_s
end

function MapView.set_selected_unit(self: any, uid: number)
	if uid <= 0 then
		uid = -1
	end
	self._selected_unit = uid
	call(self.layers.units, "set_selected", uid)
	if uid < 0 then
		call(self.layers.ranges, "clear_unit_rings")
	end
end

function MapView.unit_at_screen(self: any, screen_pos: Vector2, radius_px: number?): number
	local r = radius_px or -1.0
	if r < 0.0 then
		r = if UserInputService.TouchEnabled then 28.0 else 16.0
	end
	local v = call(self.layers.units, "unit_at_screen", screen_pos, r)
	return if type(v) == "number" then v else -1
end

--- Aim preview: kind "nuke" / "boat" / "build" / "" (clear); see WorldView.set_aim.
function MapView.set_aim(
	self: any,
	kind: string,
	tile: number,
	radius_tiles: number,
	valid: boolean?,
	detail: string?,
	level: number?
)
	if kind == "" or tile < 0 or tile >= N then
		self._aim = nil
		call(self.layers.ranges, "set_aim", "", -1, "")
		call(self.layers.icons, "set_aim", "", -1)
		return
	end
	local inner = -1.0
	local outer = radius_tiles
	local d = detail or ""
	local ViewRules = optional(script.Parent, "ViewRules")
	if kind == "nuke" and ViewRules then
		local nk = Defs.nuke_kind_from_name(d)
		if nk < 0 then
			nk = ViewRules.nuke_kind_for_radius(radius_tiles)
		end
		if nk >= 0 then
			local ri, ro = ViewRules.nuke_radii(nk)
			if ro > 0 then
				inner, outer = ri, ro
			end
			d = Defs.NUKE_NAMES[nk] or d
		end
	end
	self._aim = { kind = kind, tile = tile, inner = inner, outer = math.max(outer, 0.5), valid = valid ~= false }
	call(self.layers.ranges, "set_aim", kind, tile, d, level or 1)
	call(self.layers.icons, "set_aim", kind, tile, Color3.new(1, 1, 1))
end

function MapView.aim_sams(self: any): number
	local v = call(self.layers.ranges, "aim_sams")
	return if type(v) == "number" then v else 0
end

function MapView.set_range_mode(self: any, mode: string)
	call(self.layers.ranges, "set_mode", mode)
end

function MapView.set_range_owner(self: any, owner_id: number)
	call(self.layers.ranges, "set_range_owner", owner_id)
end

function MapView.set_range_focus(self: any, tile: number)
	call(self.layers.ranges, "set_focus_tile", tile, 14.0 * 1.4 / self.rig.scale)
end

function MapView._on_tile_hovered(self: any, tile: number)
	call(self.layers.ranges, "set_hover_tile", tile, 14.0 / self.rig.scale)
end

function MapView._on_nuke_detonated(self: any, uid: number, kind: number, tile: number, radius: number)
	local fx = self.layers.fx
	if fx == nil then
		return
	end
	if radius == 0 then
		-- intercepted: an airburst where the nuke was
		local st = self._state
		local n = st and st.nukes[uid]
		local units = self.layers.units
		if n and units then
			local t = math.clamp(((st.render_tick or st.tick) - n.launch_tick) / math.max(n.flight_ticks, 1), 0, 1)
			local u, v = units.nuke_uv(st, n, t)
			local W = st.map.W or Defs.W
			call(fx, "pop", math.floor(v) * W + math.floor(u), Color3.new(1, 0.85, 0.5))
			call(fx, "burst", "sam", u, v)
			return
		end
		call(fx, "pop", tile)
		local W = if st ~= nil then st.map.W or Defs.W else Defs.W
		call(fx, "burst", "sam", tile % W + 0.5, tile // W + 0.5)
		return
	end
	call(fx, "nuke", kind, tile, radius)
end

--- Game admins: which "players" are bot players (owner id → true); nil hides the HUMAN badges.
function MapView.set_admin_bots(self: any, bots: { [number]: boolean }?)
	local labels = self.layers.labels
	if labels ~= nil then
		labels.admin_bots = bots
	end
end

--- The UI's BorderTracker (the local player's border tiles) for the front troop labels.
function MapView.set_borders(self: any, tracker: any)
	call(self.layers.fronts, "set_borders", tracker)
end

--- Only the local player's conquests show, at the conquered name's location.
function MapView._on_conquest(self: any, by: number, victim: number, gold: number)
	local st = self._state
	if st == nil or by ~= st.local_owner or by == 0 then
		return
	end
	local loc = call(self.layers.labels, "name_location", victim)
	if loc == nil then
		local o = st:get_owner(victim)
		local t = if o ~= nil then o.spawn_tile else -1
		if t < 0 then
			return
		end
		local W = st.map.W or Defs.W
		loc = { t % W + 0.5, t // W + 0.5 }
	end
	call(self.layers.fx, "conquest", loc[1], loc[2], gold)
end

function MapView._on_unit_removed(self: any, uid: number, reason: number)
	local st = self._state
	if reason == Defs.DEL_DESTROYED and st ~= nil then
		local u = st.units[uid]
		local units = self.layers.units
		if u ~= nil and units ~= nil and u.path and #u.path > 0 then
			local x, y = units.unit_uv(st, u, st.render_tick or st.tick)
			local W = st.map.W or Defs.W
			call(self.layers.fx, "pop", math.floor(y) * W + math.floor(x))
		end
	end
	if uid == self._selected_unit then
		self:set_selected_unit(-1)
	end
end

--- The selected warship's patrol / targeting rings follow it.
function MapView._update_selected_rings(self: any)
	local st = self._state
	local VR = self.view_rules
	local units = self.layers.units
	if self._selected_unit < 0 or st == nil or VR == nil or units == nil then
		return
	end
	local u = st.units[self._selected_unit]
	if u == nil then
		self:set_selected_unit(-1)
		return
	end
	local W = st.map.W or Defs.W
	local patrol = if u.patrol_tile ~= nil and u.patrol_tile >= 0
		then u.patrol_tile
		elseif u.path and #u.path > 0 then u.path[1]
		else -1
	local pc = if patrol >= 0 then Vector2.new(patrol % W + 0.5, patrol // W + 0.5) else Vector2.zero
	local x, y = units.unit_uv(st, u, st.render_tick or st.tick)
	call(
		self.layers.ranges,
		"set_unit_rings",
		pc,
		if patrol >= 0 then VR.warship_patrol_range() else 0.0,
		Vector2.new(x, y),
		VR.warship_target_range(),
		st:owner_color(u.owner)
	)
end

-- ---------------------------------------------------------------------------------------------
-- Frame
-- ---------------------------------------------------------------------------------------------

local function place_disk(self: any, f: Frame, tile: number, radius_tiles: number, col: Color3, fill_t: number)
	local x, y = self.rig:tile_to_screen(tile)
	local d = math.max(radius_tiles * 2.0 * self.rig.scale, 6.0)
	f.Position = UDim2.fromOffset(x, y)
	f.Size = UDim2.fromOffset(d, d)
	f.BackgroundColor3 = col
	f.BackgroundTransparency = fill_t
	local s = f:FindFirstChildOfClass("UIStroke")
	if s then
		s.Color = col
	end
	f.Visible = true
end

local function markers_step(self: any, now: number)
	local st = self._state
	local spawn = -1
	if st ~= nil and st.phase == Defs.PHASE_SPAWN and st.local_owner ~= 0 then
		local me = st:get_owner(st.local_owner)
		spawn = if me ~= nil then me.spawn_tile else -1
	end
	if spawn >= 0 then
		-- a ring breathing between SPAWN_MIN_RAD and SPAWN_MAX_RAD
		-- (full-size tiles) around the local spawn, at a phase speed of 0.008 per ms
		local col = Color3.new(1, 1, 1)
		if st.local_owner ~= 0 then
			col = st:owner_color(st.local_owner):Lerp(Color3.new(1, 1, 1), 0.35)
		end
		local k = tonumber(st.map and st.map.k_lin) or Rules.K_LIN
		local b = 0.5 + 0.5 * math.sin(now * 8.0)
		local r = (MapView.SPAWN_MIN_RAD + (MapView.SPAWN_MAX_RAD - MapView.SPAWN_MIN_RAD) * b) / k
		place_disk(self, self._spawn_ring, spawn, r, col, 0.9)
	else
		self._spawn_ring.Visible = false
	end
	local aim = self._aim
	if aim ~= nil then
		local col = Color3.new(1, 1, 1)
		if aim.kind == "nuke" then
			col = if self:aim_sams() > 0 then Color3.new(1.0, 0.16, 0.12) else Color3.new(1.0, 0.84, 0.46)
		elseif aim.kind == "boat" then
			col = Color3.new(0.55, 0.85, 1.0)
		end
		if not aim.valid then
			col = Color3.new(0.6, 0.6, 0.6)
		end
		place_disk(self, self._aim_ring, aim.tile, aim.outer, col, 0.8)
		if aim.inner > 0 then
			place_disk(self, self._aim_inner, aim.tile, aim.inner, col, 0.7)
		else
			self._aim_inner.Visible = false
		end
	else
		self._aim_ring.Visible = false
		self._aim_inner.Visible = false
	end
end

local function local_owner_step(self: any, st: any)
	if st.local_owner ~= self._last_local then
		self._last_local = st.local_owner
		self.surface:refresh_palette()
		call(self.layers.icons, "mark_markers_dirty")
	end
end

local clock = os.clock

function MapView.update(self: any, dt: number)
	local t0 = clock()
	local vp0 = self.rig:viewport_size()
	self.rig:tick(dt)
	if self.rig:viewport_size() ~= vp0 then
		self:_update_screen_offset()
		self:_place_canvas()
	end
	local st = self._state
	if st ~= nil then
		guard("local_owner", local_owner_step, self, st)
	end
	local t1 = clock()
	local want = self._surface_hover_want
	if want ~= nil and t1 >= (self._surface_hover_at or 0) then
		self._surface_hover_want = nil
		guard("surface.set_hover", self.surface.set_hover, self.surface, want)
	end
	guard("surface.step", self.surface.step, self.surface)
	guard("surface.layout", self.surface.layout, self.surface, self.rig)
	local t2 = clock()
	guard("markers", markers_step, self, t0)
	guard("selected_rings", self._update_selected_rings, self)
	for _, name in self._layer_order do
		local lt = clock()
		call(self.layers[name], "tick", dt)
		self:_perf_add(name, clock() - lt)
	end
	call(self.input, "tick", dt)
	local t3 = clock()
	self:_perf_add("camera", t1 - t0)
	self:_perf_add("territory", t2 - t1)
	self:_perf_add("total", t3 - t0)
end

function MapView._perf_add(self: any, key: string, sec: number)
	local prev = self._perf[key]
	self._perf[key] = if prev == nil then sec else prev + (sec - prev) * 0.05
end

function MapView.perf_stats(self: any): { [string]: any }
	local out = {}
	for k, v in self._perf do
		out[k] = v * 1000.0
	end
	return out
end

function MapView.request_trim(_self: any, _hard: boolean, _delay_s: number?) end

function MapView.pool_stats(_self: any): { [string]: any }
	return {}
end

function MapView.destroy(self: any)
	self:unbind()
	RunService:UnbindFromRenderStep(self._render_name)
	for _, name in self._layer_order do
		call(self.layers[name], "destroy")
	end
	call(self.input, "destroy")
	self.surface:destroy()
	for _, g in self._guis do
		g:Destroy()
	end
end

return MapView
