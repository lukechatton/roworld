-- The MicroProfiler's biggest timers over a few seconds, in ms per rendered frame, every thread (the
-- main thread's and the render threads' alike). Run it in a Studio playtest's Client:
--   STUDIO_ID=<id> STUDIO_ALLOW_PUBLISHED=1 .venv/bin/python tools/studio.py luau Client tools/perf/top_timers.luau
-- It answers "what is the engine doing for us": tools/perf/frame_cost.luau follows five known timers
-- on the main thread, this one lists whatever is big. Inclusive times: a parent holds its children.
-- Set the LocalPlayer attribute "af_top_secs" (seconds, default 3) and "af_top_n" (rows, default 45)
-- before running to change the window; the result is also left in the attribute "af_top_result" so a
-- capture can be started with task.spawn and read after driving the game.
local Players = game:GetService("Players")
local LibMP = (require :: any)("@rbx/LibMP")
local lp = Players.LocalPlayer
local secs = tonumber(lp:GetAttribute("af_top_secs")) or 3
local rows_n = tonumber(lp:GetAttribute("af_top_n")) or 45

LibMP.Control:SetFrameLimit(256)
LibMP.Control:EnableProfiler(true)
LibMP.Control:EnableCapture(true)
task.wait(secs)
local session = LibMP.Session.OpenFromBuffer(LibMP.Control:CaptureToBufferSync())
local t2ms = session:FetchGlobalDesc().TickToMsCpu
local iter = session:CreateLogIterator()
iter:Configure({ SkipGpuThreads = true, SkipEvents = true })
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
local frames = math.max(count["Present"] or count["PrepareBound"] or 1, 1)
local rows = {}
for name, v in ms do
	if name ~= "Sleep" and name ~= "$Event" then
		table.insert(rows, { name, v })
	end
end
table.sort(rows, function(a, b)
	return a[2] > b[2]
end)
local out = { ("%d rendered frames in %.1f s; ms per frame (calls per frame)"):format(frames, secs) }
for i = 1, math.min(rows_n, #rows) do
	local name, v = rows[i][1], rows[i][2]
	table.insert(out, ("%7.2f  %-44s (%.1f)"):format(v / frames, name, (count[name] or 0) / frames))
end
local text = table.concat(out, "\n")
lp:SetAttribute("af_top_result", text)
return text
