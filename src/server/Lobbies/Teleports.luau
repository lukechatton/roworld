--!strict
-- TeleportService wrapper for public lobbies: reserve a match server, send players to it, send them
-- back to a hub (a public server of the same place). Teleports cannot run in Studio: there `studio`
-- returns stand-ins (a fake reserved server; `send` reports "studio" so the caller can run the match
-- on the same server instead).

local TeleportService = game:GetService("TeleportService")
local RunService = game:GetService("RunService")

local Teleports = {}

Teleports.RETRIES = 3
--- A return teleport already under way for a player is not started again within this long (a
--- LEAVE pressed twice, or the match ending while one is in flight, made TeleportAsync fail with
--- "already in progress" — 600 warnings a day).
Teleports.PENDING_S = 20

function Teleports.live(place_id: number)
	local t = {}
	local pending: { [Player]: number } = {}
	TeleportService.TeleportInitFailed:Connect(function(player: Player)
		pending[player] = nil
	end)
	game:GetService("Players").PlayerRemoving:Connect(function(player: Player)
		pending[player] = nil
	end)

	function t.reserve(): (string, string)
		local code, psid = TeleportService:ReserveServer(place_id)
		return code, psid
	end

	function t.send(players: { Player }, code: string, data: { [string]: any }): (boolean, string?)
		local opts = Instance.new("TeleportOptions")
		opts.ReservedServerAccessCode = code
		opts:SetTeleportData(data)
		local last: any = nil
		for attempt = 1, Teleports.RETRIES do
			local ok, err = pcall(function()
				TeleportService:TeleportAsync(place_id, players, opts)
			end)
			if ok then
				return true, nil
			end
			last = err
			task.wait(attempt)
		end
		warn("[Lobbies] teleport failed: " .. tostring(last))
		return false, "The teleport failed. Try again."
	end

	--- `data` (optional) reaches the hub as the teleport data (who was in which party).
	function t.to_hub(players: { Player }, data: { [string]: any }?): (boolean, string?)
		local now = os.clock()
		local list = {}
		for _, p in players do
			if p.Parent ~= nil and (pending[p] == nil or now - pending[p] > Teleports.PENDING_S) then
				pending[p] = now
				table.insert(list, p)
			end
		end
		if #list == 0 then
			return true, nil -- (all on their way already)
		end
		local ok, err = pcall(function()
			if data ~= nil then
				local opts = Instance.new("TeleportOptions")
				opts:SetTeleportData(data)
				TeleportService:TeleportAsync(place_id, list, opts)
			else
				TeleportService:TeleportAsync(place_id, list)
			end
		end)
		if not ok then
			for _, p in list do
				pending[p] = nil
			end
			local msg = tostring(err)
			if string.find(msg, "already in progress", 1, true) then
				return true, nil
			end
			warn("[Lobbies] return teleport failed: " .. msg)
		end
		return ok, if ok then nil else tostring(err)
	end

	return t
end

--- Studio stand-ins.
function Teleports.studio()
	local n = 0
	local t = {}
	function t.reserve(): (string, string)
		n += 1
		return "studio-code-" .. n, "studio-psid-" .. n
	end
	function t.send(_players: { Player }, _code: string, _data: any): (boolean, string?)
		return false, "studio"
	end
	function t.to_hub(_players: { Player }): (boolean, string?)
		return true, nil
	end
	return t
end

function Teleports.for_place(place_id: number)
	if RunService:IsStudio() then
		return Teleports.studio()
	end
	return Teleports.live(place_id)
end

return Teleports
