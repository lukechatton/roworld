--!nonstrict
-- Studio only (Dev: not published). Films the game a frame at a time for the trailer (2026-10-12: the
-- trailer for the experience's details page): while it runs,
-- time stands still (Map/FrameClock: dt 0) until the capture script asks for the next frame, which
-- moves time on by exactly 1/FPS s. The session, the map, its animations and the HUD's own tweens all
-- run on that time, so frames captured one by one (Studio MCP screen_capture, slow) play back smooth
-- at FPS. Roblox's TweenService still runs on real time.
--
-- The capture script sets workspace attribute af_film_req = n (n counting up) and waits for
-- af_film_done = n: that frame has been drawn (signalled a frame later), and stays on screen.
--
--   Film.start(Main, fps?)   Film.stop()
-- The camera is moved with `film cam` / `film look` (Dev/SessionDiag): its glides run on its own dt,
-- so on film time.
local RunService = game:GetService("RunService")
local FrameClock = require(script.Parent.Parent:WaitForChild("Map"):WaitForChild("FrameClock")) :: any

local Film = {}
Film.FPS = 30

local state = nil :: any

function Film.active(): boolean
	return state ~= nil
end

function Film.start(Main: any, fps: number?)
	if state ~= nil then
		Film.stop()
	end
	local f = { t = os.clock(), dt = 0.0 }
	local session = Main.session
	state = {
		main = Main,
		fps = fps or Film.FPS,
		done = workspace:GetAttribute("af_film_req") or 0,
		signal = nil :: number?,
		old_now = session and session.env and session.env.now,
		frames = 0,
	}
	-- (the session's clock too: its render tick follows it between ticks)
	if session and session.env then
		session.env.now = FrameClock.now
	end
	FrameClock.film = f
	-- (the HUD's "INCOMING NUKE" banner is kept down while filming: a bot's nuke at the player flashed
	-- it over the trailer's last shot, 2026-10-12; a UI choice, like the event feed's toasts)
	-- (every way it shows itself goes through set_visible: red, the green "INTERCEPTED", the pop-in)
	local alert = Main.ui and Main.ui.alert
	if alert ~= nil and alert.set_visible ~= nil then
		local set_visible = alert.set_visible
		alert.set_visible = function(a: any, _v: boolean)
			set_visible(a, false)
		end
		alert:set_visible(false)
		state.alert = alert
	end
	workspace:SetAttribute("af_film_done", state.done)
	RunService:BindToRenderStep("AirfrontFilm", Enum.RenderPriority.First.Value - 1, function()
		local s = state
		if s == nil then
			return
		end
		-- the frame stepped last time has been drawn: say so
		if s.signal ~= nil then
			workspace:SetAttribute("af_film_done", s.signal)
			s.signal = nil
		end
		local req = tonumber(workspace:GetAttribute("af_film_req")) or 0
		if req > s.done then
			s.done = req
			f.dt = 1 / s.fps
			f.t += f.dt
			s.frames += 1
			s.signal = req
		else
			f.dt = 0.0
		end
	end)
end

function Film.stop()
	if state == nil then
		return
	end
	pcall(function()
		RunService:UnbindFromRenderStep("AirfrontFilm")
	end)
	local session = state.main.session
	if session and session.env and state.old_now then
		session.env.now = state.old_now
	end
	FrameClock.film = nil
	if state.alert ~= nil then
		state.alert.set_visible = nil
	end
	state = nil
end

function Film.frames(): number
	return if state then state.frames else 0
end

return Film
