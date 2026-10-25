--!nonstrict
-- Port of scripts/ui/touch_router.gd (UITouchRouter)
-- Multi-touch for the HUD. In Godot only the first finger drove the (mouse-based) ratio slider, so
-- this node routed any other finger that lands on the slider to it. Roblox GUI objects receive
-- every finger's InputBegan / InputChanged, so a slider that handles Touch itself needs no routing:
-- the router then only watches (and never double-drives it). It routes fingers only to a slider
-- that declares `handles_touch = false` and exposes drag_to_global(logical_pos).
--
-- Nothing is consumed here: WorldView tracks every finger too (a HUD finger can still become part
-- of a pinch); a finger WorldView:touch_owned_by_world(index) claims stops driving the slider.

local UICtx = require("./UICtx")

local TouchRouter = {}
TouchRouter.__index = TouchRouter

function TouchRouter.new(root: any)
	local self = setmetatable({}, TouchRouter)
	self.ui = root
	--- Fingers on the slider: InputObject -> slider.
	self._routed = {}
	self._first = nil
	--- Test counter: slider updates driven by a routed finger.
	self.routed_actions = 0
	self._conns = {}
	return self
end

function TouchRouter.connect(self)
	if not UICtx.IS_ROBLOX then
		return
	end
	local UIS = game:GetService("UserInputService")
	table.insert(
		self._conns,
		UIS.InputBegan:Connect(function(io: InputObject)
			if io.UserInputType == Enum.UserInputType.Touch then
				self:_on_touch(io, true)
			end
		end)
	)
	table.insert(
		self._conns,
		UIS.InputEnded:Connect(function(io: InputObject)
			if io.UserInputType == Enum.UserInputType.Touch then
				self:_on_touch(io, false)
			end
		end)
	)
	table.insert(
		self._conns,
		UIS.InputChanged:Connect(function(io: InputObject)
			if io.UserInputType ~= Enum.UserInputType.Touch then
				return
			end
			local c = self._routed[io]
			if c == nil or c._freed or self:_world_owns(io) then
				return -- gone, or the finger turned into a pinch
			end
			c:drag_to_global(self:_pos(io))
			self.routed_actions += 1
		end)
	)
end

function TouchRouter.destroy(self)
	for _, c in ipairs(self._conns) do
		c:Disconnect()
	end
	table.clear(self._conns)
end

function TouchRouter._pos(self, io: InputObject): Vector2
	local inset = game:GetService("GuiService"):GetGuiInset()
	return self.ui.ctx:to_logical(Vector2.new(io.Position.X, io.Position.Y) + inset)
end

function TouchRouter._on_touch(self, io: InputObject, pressed: boolean)
	if pressed then
		if self._first == nil then
			self._first = io -- the GUI drives the HUD from this finger directly
			return
		end
		local target = self:_hit(self:_pos(io))
		if target == nil then
			return
		end
		self._routed[io] = target
		target:drag_to_global(self:_pos(io))
		self.routed_actions += 1
		return
	end
	if io == self._first then
		self._first = nil
	end
	self._routed[io] = nil
end

function TouchRouter._world_owns(self, io: InputObject): boolean
	local w = self.ui.ctx.world
	if w == nil or type(w.touch_owned_by_world) ~= "function" then
		return false
	end
	return w:touch_owned_by_world(io) == true
end

--- The ratio slider under `pos` when it needs routing (handles_touch == false), else nil.
function TouchRouter._hit(self, pos: Vector2): any
	local bar = self.ui.bar
	local sl = bar and bar._slider
	if sl == nil or sl._freed or sl.handles_touch ~= false or not sl:is_visible_in_tree() then
		return nil
	end
	if UICtx.rect_has_point(sl:get_global_rect(), pos) then
		return sl
	end
	return nil
end

return TouchRouter
