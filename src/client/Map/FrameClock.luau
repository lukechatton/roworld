--!strict
-- The client's frame time: the real one (os.clock, RenderStepped's dt), except while a Studio film
-- (Dev/Film: the trailer, 2026-10-12) steps time itself,
-- a frame at a time, so a capture of each frame plays back smoothly. The session, the map and the HUD
-- take their dt from here and the map's animations their clock.
local FrameClock = {}

--- Dev/Film while filming: { t = seconds, dt = this frame's seconds }.
FrameClock.film = nil :: { t: number, dt: number }?

function FrameClock.now(): number
	local f = FrameClock.film
	return if f ~= nil then f.t else os.clock()
end

function FrameClock.dt(real: number): number
	local f = FrameClock.film
	return if f ~= nil then f.dt else real
end

return FrameClock
