--!strict
-- Stars for a match (shared/Data/Stars; spent in the Arsenal, shared/Data/Arsenal).
--
-- A public match runs on this server: MatchServer follows it (Stars.Tracker) and its results are paid
-- as they are (Rewards.pay). A solo match runs on the player's own device, so its result is the
-- client's word (OP.SOLO_RESULT): it is typed and bounded (Stars.sanitize), can't be longer than the
-- match really lasted on this server's clock (counted from the client's "match_start" report), and
-- never pays more than Stars.solo_cap of that real time. So a made-up report earns no faster than a
-- good player, and nothing at all without the time passing.
--
--   Rewards.configure(deps)          { add_stars = fn(player, n) -> (ok, balance), double = fn(player)
--                                      -> boolean, send = fn(player, payload), now = fn() -> s, log? }
--   Rewards.solo_started(player, mode)   the client's match_start ("solo0" / "solo1" / "solo2")
--   Rewards.solo_result(player, report)  OP.SOLO_RESULT (yields)
--   Rewards.pay(player, result, mode)    a result this server measured itself (yields)
--   Rewards.release(player)              PlayerRemoving
-- The payload sent to the client (OP.STARS): { lines = { { key, amount } }, total, balance, mode }.
local IS_ROBLOX = typeof(game) == "Instance"
local Stars: any = if IS_ROBLOX
	then require((game :: any):GetService("ReplicatedStorage"):WaitForChild("Airfront").Data.Stars)
	else require("../shared/Data/Stars")

local Rewards = {}

--- Results one solo match may be paid for: its end, and one more for each life a takeover gave it.
Rewards.MAX_SOLO_PAYOUTS = 4
--- Slack on the real time a solo result may claim (the report's trip, the clock's grain), minutes.
Rewards.SLACK_MIN = 0.25

type Solo = { mode: string, paid_at: number, payouts: number }

local deps: { [string]: any } = {}
local solo: { [any]: Solo } = {}

function Rewards.configure(d: { [string]: any })
	for k, v in d do
		deps[k] = v
	end
end

--- Tests: forget everyone.
function Rewards.reset()
	table.clear(solo)
end

local function now(): number
	return if deps.now then deps.now() else os.clock()
end

local function deliver(player: any, lines: { { any } }, total: number, mode: string): number
	if total <= 0 then
		return 0
	end
	local ok, balance = deps.add_stars(player, total)
	if not ok then
		return 0
	end
	if deps.send then
		pcall(deps.send, player, { lines = lines, total = total, balance = balance, mode = mode })
	end
	if deps.log then
		deps.log(string.format("[Rewards] %s +%d Stars (%s)", tostring(player.UserId), total, mode))
	end
	return total
end

local function with_double(player: any, lines: { { any } }, total: number): ({ { any } }, number)
	if total > 0 and deps.double and deps.double(player) == true then
		table.insert(lines, { "double", total })
		return lines, total * 2
	end
	return lines, total
end

--- A result this server measured itself (a public match). Returns the Stars paid.
function Rewards.pay(player: any, result: any, mode: string?): number
	local m = mode or "public"
	local p = Stars.payout(result, m, false)
	local lines, total = with_double(player, p.lines, p.total)
	return deliver(player, lines, total, m)
end

function Rewards.solo_started(player: any, mode: any)
	if type(mode) ~= "string" or Stars.MODE_MULT[mode] == nil or mode == "public" then
		solo[player] = nil
		return
	end
	solo[player] = { mode = mode, paid_at = now(), payouts = 0 }
end

--- The client's result of the solo match it reported starting. Returns the Stars paid.
function Rewards.solo_result(player: any, report: any): number
	local m = solo[player]
	if m == nil or m.payouts >= Rewards.MAX_SOLO_PAYOUTS then
		return 0
	end
	local t = now()
	local real = math.max(0, (t - m.paid_at) / 60)
	local r = Stars.sanitize(report, real + Rewards.SLACK_MIN)
	m.payouts += 1
	m.paid_at = t
	if r.left then
		solo[player] = nil -- the match is over for this player
	end
	local p = Stars.payout(r, m.mode, false)
	local lines, total = p.lines, p.total
	local cap = Stars.solo_cap(real)
	if total > cap then
		-- more than that much real time can pay: every line shrinks alike
		local k = cap / total
		total = 0
		for _, line in lines do
			line[2] = math.floor(line[2] * k / Stars.QUANTUM) * Stars.QUANTUM
			total += line[2]
		end
	end
	lines, total = with_double(player, lines, total)
	return deliver(player, lines, total, m.mode)
end

function Rewards.release(player: any)
	solo[player] = nil
end

return Rewards
