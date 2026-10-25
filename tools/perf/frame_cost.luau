-- What a rendered frame costs on the main thread, from Roblox's MicroProfiler (LibMP). Run it in a
-- Studio playtest's Client:
--   STUDIO_ID=<id> STUDIO_ALLOW_PUBLISHED=1 .venv/bin/python tools/studio.py luau Client tools/perf/frame_cost.luau
-- (or paste it into the Studio MCP's execute_luau). It prints, per rendered frame, the whole of the
-- frame's preparation (PrepareBound) and its parts: our scripts, Roblox's GUI layout, its 2D draw pass
-- and its z-order rebuild; then the same with each of the game's ScreenGuis switched off in turn, which
-- says what each one costs.
--
-- Read docs/performance.md first. Studio renders 15 frames a second while its window is not in front,
-- so "per rendered frame" then holds 67 ms of changes: compare runs, don't read them as frame times.
local Players = game:GetService("Players")
local LibMP = (require :: any)("@rbx/LibMP")
local pg = Players.LocalPlayer:WaitForChild("PlayerGui")

local function measure(label: string): string
	task.wait(1.0)
	LibMP.Control:SetFrameLimit(128)
	LibMP.Control:EnableProfiler(true)
	LibMP.Control:EnableCapture(true)
	task.wait(3.0)
	local session = LibMP.Session.OpenFromBuffer(LibMP.Control:CaptureToBufferSync())
	local t2ms = session:FetchGlobalDesc().TickToMsCpu
	local iter = session:CreateLogIterator()
	iter:Configure({ SkipGpuThreads = true, SkipEvents = true, ThreadIds = { session:FindThreadId("*RBX Main*") } })
	local st = iter:GetState()
	iter:RewindTo(0, 0)
	local ms, count = {}, {}
	while iter:Step() do
		if st:IsExit() and not st:ThreadStackIsUnderflowed() and not st:ThreadStackWasOverflowed() then
			local el = iter:GetCurrentThreadStackElement(st:ThreadStackDepth())
			if el then
				local name = session:FetchTimerDesc(st:TimerId()).TimerName
				ms[name] = (ms[name] or 0) + (st:Timestamp() - el:EnterTimestamp()) * t2ms
				count[name] = (count[name] or 0) + 1
			end
		end
	end
	iter:Dispose()
	session:Dispose()
	local frames = math.max(count["PrepareBound"] or 1, 1)
	local function per_frame(name: string): number
		return (ms[name] or 0) / frames
	end
	return ("%-28s PrepareBound %5.2f | script %5.2f | layouts %5.2f | Pass2d %5.2f | z-order %5.2f | Perform %5.2f  (%d frames)"):format(
		label,
		per_frame("PrepareBound"),
		per_frame("Script_AirfrontClient"),
		per_frame("UpdateUILayouts"),
		per_frame("Pass2d"),
		per_frame("Rebuild Z-order list"),
		per_frame("Perform"),
		frames
	)
end

local function objects(gui: Instance?): number
	local n = 0
	if gui ~= nil then
		for _, d in gui:GetDescendants() do
			if d:IsA("GuiObject") then
				n += 1
			end
		end
	end
	return n
end

local out = { "ms per rendered frame, main thread" }
local guis = { "RofrontMap", "RofrontMapUnits", "RofrontMapLabels", "AirfrontUI" }
local counts = {}
for _, name in guis do
	table.insert(counts, ("%s %d"):format(name, objects(pg:FindFirstChild(name))))
end
table.insert(out, "gui objects: " .. table.concat(counts, ", "))
table.insert(out, measure("everything on"))
for _, name in guis do
	local g = pg:FindFirstChild(name) :: ScreenGui?
	if g ~= nil then
		g.Enabled = false
		table.insert(out, measure(name .. " off"))
		g.Enabled = true
	end
end
return table.concat(out, "\n")
