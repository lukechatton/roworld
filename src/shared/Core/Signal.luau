--!strict
-- Minimal synchronous signal (GDScript `signal` equivalent). Handlers run in connection order.
-- Usage: local s = Signal.new(); local c = s:Connect(fn); s:Fire(a, b); c:Disconnect()
-- Fire allocates nothing: handlers connected during a Fire first run on the next Fire, and handlers
-- disconnected during a Fire are skipped at once (their slots are compacted when the outermost Fire
-- returns), exactly the semantics of iterating a snapshot of the list.
local Signal = {}
Signal.__index = Signal

export type Connection = { Connected: boolean, Disconnect: (self: Connection) -> () }

local Connection = {}
Connection.__index = Connection

function Connection.Disconnect(self: any)
	if not self.Connected then
		return
	end
	self.Connected = false
	local sig = self._signal
	if sig._firing > 0 then
		sig._dirty = true -- removed when the outermost Fire returns
		return
	end
	local list = sig._handlers
	local i = table.find(list, self)
	if i then
		table.remove(list, i)
	end
end

function Signal.new()
	return setmetatable({ _handlers = {}, _firing = 0, _dirty = false }, Signal)
end

function Signal.Connect(self: any, fn: (...any) -> ())
	local c = setmetatable({ Connected = true, _fn = fn, _signal = self }, Connection)
	table.insert(self._handlers, c)
	return c
end

function Signal.Once(self: any, fn: (...any) -> ())
	local c
	c = self:Connect(function(...)
		c:Disconnect()
		fn(...)
	end)
	return c
end

-- A handler error is reported and the remaining handlers still run (Godot semantics: one broken
-- listener must not starve its siblings). The report keeps the handler's traceback.
local report: (string) -> () = (warn :: any) or print
local spawn = if type(task) == "table" then (task :: any).spawn else nil

local function on_handler_error(err: string)
	if spawn then
		-- Roblox: surface it as a real error in the output (red, clickable) without unwinding Fire.
		spawn(error, err, 0)
	else
		report(err)
	end
end

local function compact(self: any)
	self._dirty = false
	local list = self._handlers
	local j = 0
	for i = 1, #list do
		local c = list[i]
		if c.Connected then
			j += 1
			list[j] = c
		end
	end
	for i = #list, j + 1, -1 do
		list[i] = nil
	end
end

function Signal.Fire(self: any, ...)
	local list = self._handlers
	local n = #list
	if n == 0 then
		return
	end
	-- Only the first n handlers run (later connections wait for the next Fire); slots are never
	-- removed while firing (Disconnect only marks them), so indices stay valid.
	self._firing += 1
	for i = 1, n do
		local c = list[i]
		if c.Connected then
			local ok, err = xpcall(c._fn, debug.traceback, ...)
			if not ok then
				on_handler_error(err)
			end
		end
	end
	self._firing -= 1
	if self._firing == 0 and self._dirty then
		compact(self)
	end
end

function Signal.DisconnectAll(self: any)
	for _, c in ipairs(self._handlers) do
		c.Connected = false
	end
	if self._firing > 0 then
		self._dirty = true
	else
		table.clear(self._handlers)
	end
end

return Signal
