--!strict
-- A wall clock every server agrees on, for the public lobbies (start times, heartbeats, locks are
-- written by one server and read by others). Roblox servers' own clocks (os.time) can be minutes
-- apart — a hub whose clock ran ~15 min fast created lobbies that every other server listed as
-- "starts in 17:29" — so each server measures its offset from Roblox's backend clock: a DataStore
-- write's DataStoreKeyInfo.UpdatedTime is stamped by the backend, and the local time halfway through
-- the call is compared with it (error: half the round trip). Re-measured now and then; offset 0 when
-- DataStores are unavailable (Studio without API access), where there is only one server anyway.
--
--   SharedClock.start(deps?)  measure now and every RESYNC_S (deps: datastore, log — injectable)
--   SharedClock.now()         os.time() corrected by the offset (seconds, fractional)
--   SharedClock.ready()       measured once, or gave up (lobby scheduling waits for this)

local SharedClock = {}

SharedClock.STORE = "rofront_clock"
SharedClock.KEY = "probe"
--- Each measurement writes one of this many keys ("probe1" .. "probe256", at random). A DataStore key
--- takes a write every few seconds, and every server wrote "probe": at ~880 servers most of those writes
--- were refused ("TooManyRequests ... API: UpdateAsync", 2026-10-14), and a server that was refused three
--- times ran on its own clock until the next try, 20 minutes on.
SharedClock.KEYS = 256
SharedClock.RESYNC_S = 20 * 60
--- Give up waiting for the first measurement after this long (the lobbies must not stall).
SharedClock.READY_TIMEOUT_S = 15
--- A measurement whose round trip took longer than this is too imprecise to use.
SharedClock.MAX_RTT_S = 4.0

SharedClock.offset = 0.0
SharedClock.synced = false
SharedClock._started_at = os.clock()
SharedClock._given_up = false

local function millis(): number
	return DateTime.now().UnixTimestampMillis
end

function SharedClock.now(): number
	return os.time() + SharedClock.offset
end

function SharedClock.ready(): boolean
	return SharedClock.synced
		or SharedClock._given_up
		or os.clock() - SharedClock._started_at > SharedClock.READY_TIMEOUT_S
end

--- One measurement (yields). True when the offset was updated.
function SharedClock.measure(deps: { [string]: any }?): boolean
	local d = deps or {}
	local store = d.datastore
	if store == nil then
		local ok, ds = pcall(function()
			return game:GetService("DataStoreService"):GetDataStore(SharedClock.STORE)
		end)
		if not ok then
			return false
		end
		store = ds
	end
	local t0 = (d.millis or millis)()
	local ok, info = pcall(function()
		local key = SharedClock.KEY .. tostring(math.random(1, SharedClock.KEYS))
		local _, key_info = store:UpdateAsync(key, function(old: any): any
			return (tonumber(old) or 0) + 1
		end)
		return key_info
	end)
	local t1 = (d.millis or millis)()
	if not ok or info == nil or type(info.UpdatedTime) ~= "number" then
		return false
	end
	local rtt = (t1 - t0) / 1000.0
	if rtt > SharedClock.MAX_RTT_S then
		return false
	end
	-- the backend stamped the write somewhere inside the call: assume the middle
	local backend_s = info.UpdatedTime / 1000.0
	local local_mid_s = (t0 + t1) / 2000.0
	-- os.time() and DateTime share the local clock, so the offset applies to os.time() too
	SharedClock.offset = backend_s - local_mid_s
	SharedClock.synced = true
	if d.log then
		d.log(string.format("[SharedClock] offset %+.1fs (rtt %.0fms)", SharedClock.offset, rtt * 1000))
	end
	return true
end

--- Measure now (in the background) and every RESYNC_S. Gives up waiting after a failed first try.
function SharedClock.start(deps: { [string]: any }?)
	SharedClock._started_at = os.clock()
	task.spawn(function()
		local tries = 0
		while not SharedClock.measure(deps) do
			tries += 1
			if tries >= 3 then
				SharedClock._given_up = true
				break
			end
			task.wait(2)
		end
		while true do
			task.wait(SharedClock.RESYNC_S)
			SharedClock.measure(deps)
		end
	end)
end

return SharedClock
