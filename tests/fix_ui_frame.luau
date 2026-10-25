-- code-fixer: the UI kit's frame driver isolates errors (review_code.md #4) and allocates nothing per
-- frame (#14); Core/Signal fires without allocating while keeping snapshot semantics (#14).
-- Widgets' driver (deferred calls, timers, tweens, processing nodes, layout flush) runs headless here.
-- Run: .bin/lune run tests/fix_ui_frame.luau
require("./prelude")
local W = require("../src/client/UI/Widgets")
local Signal = require("../src/shared/Core/Signal")

local fails = 0
local function check(cond: any, what: string)
	if cond then
		print("  ok   " .. what)
	else
		fails += 1
		print("FAIL " .. what)
	end
end

local reports = {}
W.report_sink = function(text)
	table.insert(reports, text)
end

print("Widgets._step: one throwing callback never stops the rest of the frame")
do
	local ran = {}
	-- deferred calls: the second throws, the others still run (in order)
	W.defer(function()
		table.insert(ran, "d1")
	end)
	W.defer(function()
		error("deferred boom")
	end)
	W.defer(function()
		table.insert(ran, "d3")
	end)
	-- timers due the same frame: the first throws, the second still runs
	W.timer(0.0, function()
		error("timer boom")
	end)
	W.timer(0.0, function()
		table.insert(ran, "t2")
	end)
	-- a tween whose callback throws still runs its later steps; a sibling tween keeps animating
	local obj = { v = 0 }
	local tw = W.Tween.new(nil)
	tw:tween_callback(function()
		error("tween callback boom")
	end)
	tw:tween_property(obj, "v", 1, 0.1)
	tw:tween_callback(function()
		table.insert(ran, "after")
	end)
	local obj2 = { v = 0 }
	local tw2 = W.Tween.new(nil)
	tw2:tween_property(obj2, "v", 10, 0.2)
	-- a tween_method that throws every frame is finished, the tween goes on
	local calls = 0
	local tw3 = W.Tween.new(nil)
	tw3:tween_method(function(_v)
		calls += 1
		error("method boom")
	end, 0, 1, 1.0)
	tw3:tween_callback(function()
		table.insert(ran, "m-after")
	end)
	-- processing nodes: one throws every frame, the other keeps running
	local good = { n = 0 }
	function good:_process(_dt)
		self.n += 1
	end
	local bad = {}
	function bad:_process(_dt)
		error("process boom")
	end
	W.Control.set_process(good, true)
	W.Control.set_process(bad, true)
	-- the layout flush still happens: a fake root that records flushes, next to one that throws
	local flushed = 0
	local root_ok = {
		_flush = function()
			flushed += 1
		end,
	}
	local root_bad = {
		_flush = function()
			error("layout boom")
		end,
	}
	local roots = W._roots_for_tests()
	table.insert(roots, root_bad)
	table.insert(roots, root_ok)

	for _ = 1, 30 do
		W.step(1 / 60)
	end
	check(
		table.concat(ran, ",") == "d1,d3,t2,m-after,after",
		"deferred d1,d3 + timer t2 + tween steps ran: " .. table.concat(ran, ",")
	)
	check(obj.v == 1 and obj2.v == 10, "tweens finished (the throwing one and its sibling)")
	check(not tw:is_running() and not tw2:is_running() and not tw3:is_running(), "tweens ended")
	check(calls == 1, ("a throwing tween_method is not retried every frame (%d calls)"):format(calls))
	check(good.n == 30, ("processing node ran every frame (%d)"):format(good.n))
	check(flushed == 30, ("layout flushed every frame despite a failing root (%d)"):format(flushed))
	-- reports: once per distinct error
	local distinct = {}
	for _, r in reports do
		distinct[r:match("^[^\n]*")] = true
	end
	local n = 0
	for _ in distinct do
		n += 1
	end
	check(#reports == 6 and n == 6, ("6 distinct errors reported once each (%d reports)"):format(#reports))
	check(W.errors.caught >= 30 + 30 + 4, ("every occurrence counted (%d)"):format(W.errors.caught))
	W.Control.set_process(bad, false)
	W.Control.set_process(good, false)
	table.clear(roots)
	-- the kit keeps working afterwards
	local later = false
	W.defer(function()
		later = true
	end)
	W.step(1 / 60)
	check(later, "the driver still runs after errors")
	-- W.guard for UIRoot-style call sites
	local function fail()
		error("x")
	end
	local ok = W.guard("site", fail)
	check(ok == false and reports[#reports]:find("site failed", 1, true) ~= nil, "W.guard reports and returns false")
	local before = #reports
	W.guard("site", fail)
	check(#reports == before, "same site + message is not reported twice")
	W.guard("other site", fail)
	check(#reports == before + 1, "the same error at another site is reported")
end

print("Widgets._step: no per-frame allocations")
do
	-- steady state: 20 tweens running, 5 processing nodes, no deferred calls / timers
	local nodes = {}
	for i = 1, 5 do
		local n = { k = 0 }
		function n:_process(_dt)
			self.k += 1
		end
		W.Control.set_process(n, true)
		nodes[i] = n
	end
	local objs = {}
	for i = 1, 20 do
		local o = { v = 0 }
		objs[i] = o
		W.Tween.new(nil):tween_property(o, "v", 1, 100)
	end
	for _ = 1, 10 do
		W.step(1 / 60) -- warm up (tween start values etc.)
	end
	-- Luau has no allocation counter: sum the per-frame growth of the heap (a GC step can only
	-- shrink it, and with no allocation no GC step runs).
	local grown, frames_alloc = 0.0, 0
	for _ = 1, 600 do
		local c0 = collectgarbage("count")
		W._step(1 / 60)
		local d = collectgarbage("count") - c0
		if d > 0 then
			grown += d
			frames_alloc += 1
		end
	end
	check(
		frames_alloc <= 6 and grown < 2,
		("600 frames: %d allocated, %.2f KB (was a tween-list clone + a process list every frame)"):format(
			frames_alloc,
			grown
		)
	)
	for _, n in nodes do
		W.Control.set_process(n, false)
	end
end

print("Signal: snapshot semantics without allocation")
do
	local s = Signal.new()
	local log = {}
	local c2
	local c1 = s:Connect(function(x)
		table.insert(log, "a" .. x)
		-- connecting during a Fire: runs from the next Fire on
		if x == 1 then
			s:Connect(function(y)
				table.insert(log, "late" .. y)
			end)
		end
		-- disconnecting a later handler during a Fire: skipped at once
		if x == 2 then
			c2:Disconnect()
		end
	end)
	c2 = s:Connect(function(x)
		table.insert(log, "b" .. x)
	end)
	s:Fire(1)
	s:Fire(2)
	s:Fire(3)
	check(
		table.concat(log, ",") == "a1,b1,a2,late2,a3,late3",
		"connect/disconnect while firing: " .. table.concat(log, ",")
	)
	check(#s._handlers == 2, "disconnected slots compacted after the Fire")
	-- nested Fire of the same signal
	local depth = 0
	local seen = {}
	local n = Signal.new()
	local h
	h = n:Connect(function(k)
		depth += 1
		table.insert(seen, k)
		if k < 3 then
			n:Fire(k + 1)
		end
		if k == 2 then
			h:Disconnect()
		end
		depth -= 1
	end)
	n:Connect(function(k)
		table.insert(seen, "x" .. k)
	end)
	n:Fire(1)
	check(table.concat(seen, ",") == "1,2,3,x3,x2,x1", "nested Fire: " .. table.concat(seen, ","))
	check(#n._handlers == 1 and n._firing == 0, "nested disconnect compacted when the outer Fire returns")
	-- DisconnectAll while firing
	local d = Signal.new()
	local after = 0
	d:Connect(function()
		d:DisconnectAll()
	end)
	d:Connect(function()
		after += 1
	end)
	d:Fire()
	d:Fire()
	check(after == 0 and #d._handlers == 0, "DisconnectAll while firing stops the rest and clears")
	-- Once
	local o = Signal.new()
	local once = 0
	o:Once(function()
		once += 1
	end)
	o:Fire()
	o:Fire()
	check(once == 1 and #o._handlers == 0, "Once")
	-- errors are isolated and firing depth recovers
	local e = Signal.new()
	local ok_after = 0
	e:Connect(function()
		error("handler boom")
	end)
	e:Connect(function()
		ok_after += 1
	end)
	e:Fire()
	check(ok_after == 1 and e._firing == 0, "a failing handler doesn't stop the next one")
	-- no allocation per Fire with several handlers
	local m = Signal.new()
	local sum = 0
	for _ = 1, 4 do
		m:Connect(function(v)
			sum += v
		end)
	end
	m:Fire(1)
	local grown, fires_alloc = 0.0, 0
	for i = 1, 20000 do
		local c0 = collectgarbage("count")
		m:Fire(i)
		local d = collectgarbage("count") - c0
		if d > 0 then
			grown += d
			fires_alloc += 1
		end
	end
	check(
		fires_alloc <= 10 and grown < 2,
		("20000 Fires with 4 handlers: %d allocated, %.2f KB (was a list clone per Fire)"):format(fires_alloc, grown)
	)
end

if fails > 0 then
	error(fails .. " failures")
end
print("fix_ui_frame ok")
