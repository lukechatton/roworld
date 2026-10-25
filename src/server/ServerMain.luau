--!strict
-- Roblox server entry for the multiplayer match (the server half of scripts/net/session.gd plus the
-- server duties of scripts/main.gd). Every Roblox server hosts one shared match (MatchServer); players
-- pick Solo (runs on their client, never touches the server) or Multiplayer on the title screen.
--
-- Networking: ReplicatedStorage.AirfrontNet.ToServer / ToClient RemoteEvents (one per direction, so
-- everything in a direction is strictly ordered: snapshot before deltas, deltas in tick order). The
-- first argument is an op code (Net/Protocol.OP). Deltas / snapshots / intents are buffers.
--
-- Also: per-player settings (SettingsStore), graceful shutdown (BindToClose), and optional stats
-- logging (workspace attribute AF_NET_STATS = true prints a line every 30 s).
--
-- Maps: the terrain of every map but the default lives in script.Parent.MapData (server only);
-- WorldMap gets a provider for it, and AirfrontNet.GetMap (Net/MapFetch) serves it to clients that
-- need a map for solo play or an upcoming multiplayer match.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")

local Shared = ReplicatedStorage:WaitForChild("Airfront")
local Protocol = require(Shared.Net.Protocol) :: any
local MapFetch = require(Shared.Net.MapFetch) :: any
local LobbyRules = require(script.Parent.Lobbies.LobbyRules) :: any
local LobbyStore = require(script.Parent.Lobbies.LobbyStore) :: any
local LobbyDirectory = require(script.Parent.Lobbies.LobbyDirectory) :: any
local MatchHost = require(script.Parent.Lobbies.MatchHost) :: any
local Teleports = require(script.Parent.Lobbies.Teleports) :: any
local Party = require(script.Parent.Party) :: any
local SharedClock = require(script.Parent.Lobbies.SharedClock) :: any
local LobbyHttp = require(script.Parent.Lobbies.LobbyHttp) :: any
local LobbySecret = require(script.Parent.Lobbies.Secret) :: any
local BotNames = require(Shared.Data.BotNames) :: any
local BotFaces = require(script.Parent.BotFaces) :: any
local FreshServers = require(script.Parent.FreshServers) :: any
local TutorialData = require(Shared.Data.Tutorial) :: any
local Staging = require(Shared.Data.Staging) :: any
local HttpService = game:GetService("HttpService")
local MapList = require(Shared.Data.MapList) :: any
local MatchServer = require(script.Parent.MatchServer) :: any
local SettingsStore = require(script.Parent.SettingsStore) :: any
local Analytics = require(script.Parent.Analytics) :: any
local Purchases = require(script.Parent.Purchases) :: any
local Rewards = require(script.Parent.Rewards) :: any
local MarketplaceService = game:GetService("MarketplaceService")
local PolicyService = game:GetService("PolicyService")
local DataStoreService = game:GetService("DataStoreService")

local OP = Protocol.OP

local ServerMain = {}
ServerMain.server = nil :: any
--- Messages a client may send per second before the rest is ignored (intents have their own 30/s).
ServerMain.MAX_MESSAGES_PER_SEC = 90
--- The production experience (Rofront; build/publish.json). Other experiences running this code
--- (Rofront Staging) stay off the services production shares.
ServerMain.PROD_UNIVERSE = 10768172922
--- Team games and parties in production (docs/teams-and-parties.md; always on in Staging and Studio).
ServerMain.TEAM_GAMES_LIVE = true
--- SETTING messages per second per client (clients throttle each section to 2/s).
ServerMain.MAX_SETTINGS_PER_SEC = 8
--- ANALYTICS messages per second per client (a client sends a handful per match).
ServerMain.MAX_ANALYTICS_PER_SEC = 6
ServerMain.MAX_CREDIT_USES_PER_SEC = 2
--- A player may ask to be sent to a fresh server (OP.SOLO_HOP) this often, seconds.
ServerMain.HOP_GAP_S = 15
--- A client sends HELLO once (its scripts started). Further HELLOs from the same player are answered
--- at most this often (LOBBY); the SETTINGS reply has its own, longer limit (SettingsStore.replay).
--- review_code.md R2-2: every HELLO used to echo the whole stored settings blob.
ServerMain.HELLO_MIN_INTERVAL_S = 2.0
ServerMain.STATS_EVERY_S = 30
--- Hubs push the public-lobby list to their players this often (seconds).
ServerMain.LOBBIES_PUSH_S = 2.0
--- Group rank that counts as a game admin (254 = Admin, 255 = Owner in a default group).
ServerMain.ADMIN_RANK = 254

local started = false

--- Reports an error once per distinct message (first line), so a recurring fault can't flood the log.
local reported: { [string]: boolean } = {}
local reported_n = 0
local function report_once(where: string, err: any)
	local text = tostring(err)
	local key = where .. ":" .. (string.match(text, "^[^\n]*") or "")
	if reported[key] or reported_n >= 64 then
		return
	end
	reported[key] = true
	reported_n += 1
	warn(string.format("[RoWorldServer] %s failed: %s", where, text))
end

local function core(name: string): any
	local m = Shared.Core:FindFirstChild(name)
	if m == nil then
		return nil
	end
	return (require :: any)(m)
end

function ServerMain.start()
	if started then
		return
	end
	started = true
	Players.CharacterAutoLoads = false
	pcall(function()
		StarterGui.ResetPlayerGuiOnSpawn = false
	end)

	-- Server-only map data (src/server/MapData) for WorldMap.get / MapFetch.
	local WorldMapMod = core("WorldMap")
	local map_folder = script.Parent:FindFirstChild("MapData")
	if WorldMapMod ~= nil then
		WorldMapMod.add_provider(function(id: string): any
			local row = MapList.get(id)
			local mod = if row ~= nil and map_folder ~= nil then map_folder:FindFirstChild(row.module) else nil
			return if mod ~= nil then (require :: any)(mod) else nil
		end)
	end

	local folder = Instance.new("Folder")
	folder.Name = "AirfrontNet"
	if WorldMapMod ~= nil then
		MapFetch.serve(folder, function(id: string): any
			return WorldMapMod.load_data(id)
		end)
	end
	local to_server = Instance.new("RemoteEvent")
	to_server.Name = "ToServer"
	to_server.Parent = folder
	local to_client = Instance.new("RemoteEvent")
	to_client.Name = "ToClient"
	to_client.Parent = folder

	local listening: { [Player]: boolean } = {}
	local listening_list: { Player } = {}
	local msg_budget: { [Player]: number } = {}
	local setting_budget: { [Player]: number } = {}
	local analytics_budget: { [Player]: number } = {}
	local credit_budget: { [Player]: number } = {}
	--- server/FreshServers on a live hub (nil elsewhere), and when each player last asked to hop
	local fresh: any = nil
	local hop_at: { [Player]: number } = {}
	--- the INVENTORY payload for a player (set below, with the paid-random-items policy)
	local inventory_of: (any) -> any
	local hello_at: { [Player]: number } = {}
	local joining_lobby: { [Player]: boolean } = {}
	--- Players who came to watch (a hub's Watch teleport, or Studio's local Watch).
	local spectating: { [Player]: boolean } = {}

	-- Dev diagnostics (workspace attribute AF_DIAG; never set in the shipped place) can add fake
	-- participants (tables) next to real Players.
	local diag: any = nil
	if workspace:GetAttribute("AF_DIAG") == true then
		local m = script.Parent:FindFirstChild("Dev") and script.Parent.Dev:FindFirstChild("SessionDiag")
		if m then
			diag = (require :: any)(m)
		end
	end

	local function send(player: any, op: number, ...: any)
		if typeof(player) == "Instance" then
			if player.Parent == Players then
				to_client:FireClient(player, op, ...)
			end
		elseif diag ~= nil and diag.is_fake(player) then
			diag.deliver(player, op, ...)
		end
	end

	-- Public lobbies: a public server is a HUB (title, solo, the
	-- game-wide lobby list; joining a lobby teleports to its reserved server); a reserved server made
	-- for a lobby is that lobby's MATCH server (one match, bot players fill the empty slots, then
	-- everyone goes back to a hub). Studio has no teleports: a joined lobby runs on the same server.
	local is_match_server = game.PrivateServerId ~= "" and game.PrivateServerOwnerId == 0
	ServerMain.kind = if is_match_server then "match" else "hub"
	-- Team games and parties (docs/teams-and-parties.md): on Staging only at first, then
	-- in production too (since 2026-10-10). TEAM_GAMES_LIVE = false puts
	-- production back to two free-for-all lobbies and no parties.
	local TEAM_GAMES = ServerMain.TEAM_GAMES_LIVE or Staging.here() or RunService:IsStudio()
	ServerMain.team_games = TEAM_GAMES
	-- A live public hub takes part in server/FreshServers: it announces its version, lists itself
	-- while it is the newest, and once it is outdated sends the players who start a solo match to a
	-- fresh server (2026-10-04). Clients read workspace attribute RF_Outdated. Private servers,
	-- match servers and Studio stay out of it.
	if game.PrivateServerId == "" and not RunService:IsStudio() then
		local ok_fresh, err_fresh = pcall(function()
			local MSS = game:GetService("MemoryStoreService")
			local Messaging = game:GetService("MessagingService")
			local list = MSS:GetSortedMap("FreshHubs1")
			fresh = FreshServers.new({
				version = game.PlaceVersion,
				job_id = game.JobId,
				now = os.time,
				players = function(): number
					return #Players:GetPlayers()
				end,
				max_players = Players.MaxPlayers,
				publish = function(version: number)
					Messaging:PublishAsync("PlaceVersion", version)
				end,
				list_put = function(job_id: string, entry: any, ttl_s: number)
					list:SetAsync(job_id, entry, ttl_s)
				end,
				list_get = function(): any
					return list:GetRangeAsync(Enum.SortDirection.Ascending, 200)
				end,
				on_outdated = function(latest: number)
					workspace:SetAttribute("RF_Outdated", true)
				end,
				log = print,
			})
			task.spawn(function()
				pcall(function()
					Messaging:SubscribeAsync("PlaceVersion", function(msg: any)
						fresh:heard(if type(msg) == "table" then msg.Data else nil)
					end)
				end)
				while true do
					fresh:tick()
					task.wait(5)
				end
			end)
			-- a hop whose teleport could not start: the player plays here after all
			game:GetService("TeleportService").TeleportInitFailed:Connect(function(player: Player)
				if hop_at[player] ~= nil then
					send(player, OP.HOP_RESULT, false)
				end
			end)
		end)
		if not ok_fresh then
			warn("[Fresh] off: " .. tostring(err_fresh))
			fresh = nil
		end
	end
	-- Lobby times are written by one server and read by others: every server uses the shared clock
	-- (its own clock corrected against Roblox's backend), never its own os.time().
	SharedClock.start({ log = print })
	local now = SharedClock.now
	local store: any = nil
	local ok_store, st = pcall(LobbyStore.memory, game.JobId, now)
	if ok_store then
		store = st
	else
		warn("[Lobbies] MemoryStore unavailable, using a local store: " .. tostring(st))
		store = LobbyStore.localstore(now)
	end
	-- the lobby service on easy-1 (docs/lobby-service.md) in front of MemoryStore: with hundreds of
	-- servers reading the lobby list every few seconds MemoryStore refused most calls (one partition's
	-- limits, 2026-09-27). MemoryStore stays the fallback while the service is down or switched off.
	-- Studio uses it only when AF_LOBBY_URL points at a test service.
	local lobby_url: string? = nil
	if RunService:IsStudio() then
		local u = workspace:GetAttribute("AF_LOBBY_URL")
		lobby_url = if type(u) == "string" and u ~= "" then u else nil
	elseif LobbyHttp.ENABLED and game.GameId == ServerMain.PROD_UNIVERSE then
		-- (only the production experience: the service is one shared lobby list, and another
		-- experience, like Rofront Staging, must not show up in it; MemoryStore is its own per experience)
		lobby_url = LobbyHttp.BASE_URL
	end
	if lobby_url ~= nil then
		local client = LobbyHttp.roblox(LobbySecret, now, lobby_url, print)
		if client ~= nil then
			local fallback = store
			-- hubs tell the service who is playing solo / on the title (its live stats page)
			local presence = if ServerMain.kind == "hub"
				then function(): any
					return Analytics.presence(Players:GetPlayers())
				end
				else nil
			store = LobbyStore.failover(LobbyStore.http(client, ServerMain.kind, nil, presence), fallback, {
				healthy = function(): boolean
					return client:healthy()
				end,
				log = print,
			})
			ServerMain.lobby_client = client
			print("[Lobbies] lobby service " .. lobby_url .. " (MemoryStore as fallback)")
		else
			warn("[Lobbies] HTTP requests are off for this place: lobbies stay on MemoryStore")
		end
	end
	ServerMain.lobby_store = store
	local teleports = Teleports.for_place(game.PlaceId)
	local function lobby_maps(): { any }
		local out = {}
		for _, m in MapList.maps do
			table.insert(out, {
				id = m.id,
				name = m.name,
				weight = m.multiplayer_frequency or 1,
				categories = m.categories,
				land = m.land_tiles,
				k_lin = m.k_lin,
			})
		end
		return out
	end
	local directory: any = nil
	local host: any = nil
	--- Studio stand-in for a lobby's reserved server: the lobby this server plays locally.
	local studio_lobby: any = nil
	if is_match_server then
		host = MatchHost.new({
			store = store,
			psid = game.PrivateServerId,
			now = now,
			to_hub = teleports.to_hub,
			log = print,
		})
		ServerMain.host = host
	else
		directory = LobbyDirectory.new({
			store = store,
			teleport = teleports,
			maps = lobby_maps,
			now = now,
			rand = math.random,
			new_id = function(): string
				return HttpService:GenerateGUID(false)
			end,
			log = print,
			team_games = TEAM_GAMES,
			-- (seats never past what a server holds: a seat past it is a "GameFull" teleport. Studio's
			-- Players.MaxPlayers is not the place's, so no cap there.)
			server_size = function(): number?
				return if RunService:IsStudio() then nil else Players.MaxPlayers
			end,
		})
		ServerMain.directory = directory
	end
	-- Parties (server/Party) on a hub; a match server knows who came in which party from the teleport
	-- data (user id → party key; party key → its leader's user id).
	local party: any = nil
	if TEAM_GAMES and not is_match_server then
		party = Party.new({
			send = function(p: Player, state: any)
				send(p, OP.PARTY_STATE, state)
			end,
			now = os.time,
			log = print,
			prefix = string.sub(game.JobId, 1, 8) .. ":",
		})
		ServerMain.party = party
	end
	local party_by_uid: { [string]: string } = {}
	local party_leader: { [string]: number } = {}
	--- The lobby hooks MatchServer uses on a match server (or for a Studio-local lobby).
	local function lobby_hooks(): any
		local function current(): any
			if host ~= nil then
				return host.lobby
			end
			return studio_lobby
		end
		return {
			countdown = function(): number?
				if host ~= nil then
					return host:starts_in()
				end
				local l = studio_lobby
				return if l then math.max(0, l.starts - now()) else nil
			end,
			info = function(): any
				local l = current()
				-- public matches play their map a bit smaller ("world@80"); a team game's teams
				return if l
					then { map_id = LobbyRules.match_map_id(l.map), max = l.max, mode = l.mode, teams = l.teams }
					else nil
			end,
			party_of = function(uid: string): string?
				return party_by_uid[uid]
			end,
			on_start = function(humans: number, voted: boolean?): number
				-- the humans a public match starts with (the headline number; goal: 50):
				-- one "Public Match Humans" event per match on the Creator Dashboard
				local slots = if host ~= nil and host.lobby
					then host.lobby.max
					elseif studio_lobby ~= nil then studio_lobby.max
					else humans
				local reporter = nil
				for _, p in Players:GetPlayers() do
					reporter = p
					break
				end
				if reporter ~= nil then
					Analytics.public_start(reporter, humans, slots, voted == true)
				end
				if host ~= nil then
					local bots = LobbyRules.bot_fill(if host.lobby then host.lobby.max else humans, humans)
					task.spawn(function()
						host:start(humans)
					end)
					return bots
				end
				local l = studio_lobby
				if l ~= nil then
					-- Studio: the local lobby shows as a live match to watch (the hub's own list)
					task.spawn(function()
						pcall(store.update, l.id, function(v: any): any?
							local cur = LobbyRules.decode(v)
							if cur == nil then
								return nil
							end
							cur.status = "started"
							cur.players = humans
							cur.beat = now()
							return cur
						end)
					end)
				end
				return if l then LobbyRules.bot_fill(l.max, humans) else 0
			end,
			bot_names = function(n: number, taken: { [string]: boolean }): { string }
				local rng = Random.new()
				return BotNames.many(n, function()
					return rng:NextNumber()
				end, taken)
			end,
			on_vote_start = function(seconds: number)
				if host ~= nil then
					task.spawn(function()
						host:start_early(seconds)
					end)
				elseif studio_lobby ~= nil then
					studio_lobby.starts = math.min(studio_lobby.starts, now() + math.ceil(seconds))
				end
			end,
			on_closed = function()
				if host ~= nil then
					task.spawn(function()
						host:finish()
					end)
				elseif studio_lobby ~= nil then
					local id = studio_lobby.id
					task.spawn(function()
						pcall(store.remove, id)
					end)
				end
			end,
			on_over = function(peers: { any })
				local list = {}
				for _, p in peers do
					if typeof(p) == "Instance" and p.Parent == Players then
						table.insert(list, p)
					end
				end
				if host ~= nil then
					-- (who was in which party: the hub makes the parties again)
					local back = nil
					if TEAM_GAMES then
						local parties, leaders = {}, {}
						for _, p in list do
							local key = party_by_uid[tostring(p.UserId)]
							if key ~= nil then
								parties[tostring(p.UserId)] = key
								leaders[key] = party_leader[key]
							end
						end
						if next(parties) ~= nil then
							back = { parties = parties, leaders = leaders }
						end
					end
					task.spawn(function()
						host:finish()
						host:return_to_hub(list, back)
					end)
				elseif studio_lobby ~= nil then
					local id = studio_lobby.id
					task.spawn(function()
						pcall(store.remove, id)
					end)
				end
				studio_lobby = nil
			end,
		}
	end

	local server = MatchServer.new({
		lobby = if is_match_server then lobby_hooks() else nil,
		-- the head shots bot players wear beside their names (Roblox user ids; server only)
		bot_faces = BotFaces,
		-- what a player wears in a match (Data/Cosmetics; the match server sends it to everyone)
		cosmetics_of = function(peer: any): any
			return if typeof(peer) == "Instance" then Purchases.equipped(peer) else nil
		end,
		-- the Arsenal a player has unlocked (Data/Arsenal), and their Stars for a public match
		unlocks_of = function(peer: any): number
			return if typeof(peer) == "Instance" then Purchases.unlock_mask(peer) else 0
		end,
		on_result = function(peer: any, result: any)
			if typeof(peer) == "Instance" then
				task.spawn(Rewards.pay, peer, result, "public")
			end
		end,
		make_sim = function(config: { [string]: any }): any
			local Sim = core("Sim")
			local WorldMap = core("WorldMap")
			if Sim == nil or WorldMap == nil then
				error("Core Sim is not available")
			end
			return Sim.new(WorldMap.get(config.map_id), config)
		end,
		send = send,
		peers = function(): { any }
			return listening_list
		end,
		now_ms = function(): number
			return os.clock() * 1000
		end,
		log = print,
	})
	ServerMain.server = server

	-- Quick Play on a hub (docs/lobby-service.md "Quick Play"): a player (a party leader: their party
	-- with them) asks for a public match of a kind; the store seats them in the soonest lobby of that
	-- kind with room, else they wait in line here until a seat is free. PUBLIC_STATE tells the client
	-- ("joining" | "line" | "going" | "idle").
	--- when each player asked (os.clock), for the wait the Public Join event reports
	local public_since: { [Player]: number } = {}
	--- seated and sent: the lobby, their seat, and whether this was already a retry
	local public_sent: { [Player]: { id: string, uid: string, mode: string, at: number, retried: boolean } } = {}
	--- the kinds of public match a player may ask for here (the title's cards)
	local public_kinds = {}
	for _, k in LobbyRules.kinds(TEAM_GAMES) do
		table.insert(public_kinds, k.mode)
	end
	local function public_state(players: { Player }, state: string, mode: string?, extra: any?)
		for _, m in players do
			send(m, OP.PUBLIC_STATE, state, mode, extra)
		end
	end
	--- The players who go with `player` (a party leader: everyone of the party on the title screen),
	--- and the party data for the match server; nil when `player` can't go now.
	local function public_group(player: Player): ({ Player }?, { [string]: any }?)
		if player.Parent ~= Players or Analytics.in_solo(player) then
			return nil, nil
		end
		if party == nil or party:key_of(player) == nil then
			return { player }, nil
		end
		local list, uids = {}, {}
		for _, m in party:members(player) do
			local free = m == player or (m.Parent == Players and not joining_lobby[m] and not Analytics.in_solo(m))
			if free then
				table.insert(list, m)
				table.insert(uids, tostring(m.UserId))
			end
		end
		if #list <= 1 then
			return { player }, nil
		end
		return list, { players = list, key = party:key_of(player), uids = uids, leader = player.UserId }
	end
	local function public_key(player: Player): string
		local k = if party ~= nil then party:key_of(player) else nil
		return if k ~= nil then "p:" .. k else "u:" .. tostring(player.UserId)
	end
	local function public_wait(m: Player): number
		return os.clock() - (public_since[m] or os.clock())
	end
	local function public_seated(players: { Player }, mode: string, l: any, first_try: boolean, retried: boolean?)
		for _, m in players do
			public_sent[m] =
				{ id = l.id, uid = tostring(m.UserId), mode = mode, at = os.clock(), retried = retried == true }
			pcall(Analytics.public_join, m, "Seated", mode, public_wait(m), first_try)
			public_since[m] = nil
		end
		public_state(players, "going", mode, { map = l.map, map_name = l.map_name })
	end
	local function public_failed(players: { Player }, mode: string, result: string, text: string?)
		for _, m in players do
			pcall(Analytics.public_join, m, result, mode, public_wait(m), false)
			public_since[m] = nil
		end
		public_state(players, "idle", mode)
		if text ~= nil then
			for _, m in players do
				send(m, OP.JOIN_RESULT, false, text)
				send(m, OP.NOTICE, text, 1)
			end
		end
	end
	--- Studio (no teleports): this server plays the lobby itself.
	local function public_studio(players: { Player }, group: { [string]: any }?, l: any)
		studio_lobby = l
		server.deps.lobby = lobby_hooks()
		server._finished = false -- (Studio replays lobbies on this one server)
		public_state(players, "idle", LobbyRules.mode_of(l))
		for _, m in players do
			if group ~= nil then
				party_by_uid[tostring(m.UserId)] = group.key
				party_leader[group.key] = group.leader
			end
			local nm = if m.DisplayName ~= "" then m.DisplayName else m.Name
			server:on_client(m, { uid = tostring(m.UserId), name = nm }, OP.JOIN, nm)
		end
	end
	local function public_join(player: Player, mode: string, retried: boolean?)
		if directory == nil or joining_lobby[player] then
			return
		end
		-- seated and on the way (the teleport has 20 s before the client gives up on it): no second seat
		local going = public_sent[player]
		if going ~= nil and os.clock() - going.at < 20 and not retried then
			return
		end
		if party ~= nil and party:key_of(player) ~= nil and not party:is_leader(player) then
			send(player, OP.JOIN_RESULT, false, "Your party leader picks the match.")
			send(player, OP.NOTICE, "Your party leader picks the match.", 1)
			return
		end
		local key = public_key(player)
		if directory:queued(key) ~= nil then
			return -- (in line already)
		end
		local players, group = public_group(player)
		if players == nil then
			return
		end
		for _, m in players do
			joining_lobby[m] = true
			public_since[m] = public_since[m] or os.clock()
		end
		public_state(players, "joining", mode)
		task.spawn(function()
			local ok, reason, l = directory:join_public(players, mode, { party = group })
			for _, m in players do
				joining_lobby[m] = nil
			end
			if ok then
				public_seated(players, mode, l, true, retried)
			elseif reason == "studio" and l ~= nil then
				public_studio(players, group, l)
			elseif reason == LobbyDirectory.NO_ROOM then
				-- every lobby of the kind is full right now: wait in line for the next free seat
				directory:enqueue({
					key = key,
					mode = mode,
					since = now(),
					members = function(): ({ any }?, { [string]: any }?)
						return public_group(player)
					end,
					done = function(seated: boolean, why: string?, lb: any, sent: { Player }?)
						local who = sent or public_group(player) or { player }
						if seated then
							public_seated(who, mode, lb, false, retried)
						elseif why == "studio" and lb ~= nil then
							public_studio(who, nil, lb)
						elseif why == "gone" then
							public_failed(who, mode, "Left Line", nil)
						elseif why == "timeout" then
							public_failed(
								who,
								mode,
								"Timed Out",
								"Every public match is full right now. Try again in a moment, or play solo."
							)
						else
							public_failed(who, mode, "Teleport Failed", why)
						end
					end,
				})
				public_state(players, "line", mode)
			elseif reason == LobbyDirectory.UNREACHABLE then
				public_failed(players, mode, "Unreachable", reason)
			else
				public_failed(players, mode, "Teleport Failed", reason)
			end
		end)
	end
	--- The player (a party leader: the party) leaves the line.
	local function public_cancel(player: Player)
		if directory == nil or (party ~= nil and party:key_of(player) ~= nil and not party:is_leader(player)) then
			return
		end
		local e = directory:queued(public_key(player))
		if e ~= nil and directory:dequeue(e.key) then
			public_failed(public_group(player) or { player }, e.mode, "Left Line", nil)
		end
	end
	ServerMain.public_join = public_join
	-- a public-match teleport that failed after it began: the seat goes back, and once the player is
	-- put in line again on their own
	if directory ~= nil and not RunService:IsStudio() then
		game:GetService("TeleportService").TeleportInitFailed:Connect(function(player: Player, result: any, msg: any)
			if result == Enum.TeleportResult.IsTeleporting then
				-- A second request refused because one is already under way: the player is still on
				-- their way, so the seat stays and nothing failed (2026-10-15: most of the ~5,200 daily
				-- "Teleport Failed" were this; their seat went back and they read "Couldn't reach that
				-- match" while the first teleport carried them in). If that one fails it fires again,
				-- and a seat nobody takes goes back after LobbyRules.ARRIVE_S anyway.
				return
			end
			local sent = public_sent[player]
			public_sent[player] = nil
			if sent == nil or os.clock() - sent.at > 60 then
				return
			end
			task.spawn(function()
				directory:release(sent.id, { sent.uid })
			end)
			pcall(Analytics.public_join, player, "Teleport Failed", sent.mode, 0, false)
			warn(
				string.format(
					"[Lobbies] teleport to %s failed for %s: %s %s",
					sent.id,
					player.Name,
					tostring(result),
					tostring(msg)
				)
			)
			-- (a party member who doesn't lead is brought along by the leader's retry, if free)
			local follower = party ~= nil and party:key_of(player) ~= nil and not party:is_leader(player)
			local again = not sent.retried and not follower and result ~= Enum.TeleportResult.Unauthorized
			if again and player.Parent == Players then
				send(player, OP.NOTICE, "Couldn't reach that match. Finding you another one…", 0)
				public_join(player, sent.mode, true)
			else
				public_state({ player }, "idle", sent.mode)
				send(player, OP.NOTICE, "Couldn't reach that match. Try again in a moment.", 1)
			end
		end)
	end

	to_server.OnServerEvent:Connect(function(player: Player, op: any, ...: any)
		if type(op) ~= "number" then
			return
		end
		local used = msg_budget[player] or 0
		if used >= ServerMain.MAX_MESSAGES_PER_SEC then
			return
		end
		msg_budget[player] = used + 1
		if op == OP.HELLO then
			local t = os.clock()
			local last = hello_at[player]
			if last ~= nil and t - last < ServerMain.HELLO_MIN_INTERVAL_S then
				return -- a repeated HELLO: already answered
			end
			hello_at[player] = t
			if not listening[player] then
				listening[player] = true
				table.insert(listening_list, player)
			end
			send(player, OP.LOBBY, server:lobby_info(player))
			if directory ~= nil then
				send(player, OP.LOBBIES, directory:view(), public_kinds)
			end
			-- the stored settings (size-capped) go out once, not on every HELLO
			SettingsStore.replay(player, function(data: any)
				send(player, OP.SETTINGS, data)
			end)
			send(player, OP.CREDITS, Purchases.credits(player))
			send(player, OP.INVENTORY, inventory_of(player))
			if party ~= nil then
				send(player, OP.PARTY_STATE, party:state(player))
			end
		elseif op == OP.SETTING then
			local s_used = setting_budget[player] or 0
			if s_used >= ServerMain.MAX_SETTINGS_PER_SEC then
				return
			end
			setting_budget[player] = s_used + 1
			local section, values = ...
			local ok, err = pcall(SettingsStore.set, player, section, values)
			if not ok then
				report_once("SettingsStore.set", err)
			end
		elseif op == OP.JOIN_PUBLIC then
			-- Quick Play: a public match of a kind ("ffa" | "team" | "world"), or false to leave the line
			local mode = ...
			if mode == false then
				public_cancel(player)
			elseif LobbyRules.is_mode(mode) and (mode ~= LobbyRules.MODE_TEAM or TEAM_GAMES) then
				public_join(player, mode)
			end
		elseif op == OP.JOIN_LOBBY then
			-- (a lobby picked by id) Quick Play into that lobby's kind
			local id = ...
			if directory == nil or type(id) ~= "string" or #id > 64 then
				return
			end
			local mode = LobbyRules.MODE_FFA
			for _, l in directory:lobbies() do
				if l.id == id then
					mode = LobbyRules.mode_of(l)
				end
			end
			public_join(player, mode)
		elseif op == OP.PARTY then
			if party == nil then
				return
			end
			local action, target = ...
			local tuid = tonumber(target)
			if action == "invite" and tuid ~= nil then
				local ok, why = party:invite(player, Players:GetPlayerByUserId(tuid))
				if ok then
					send(player, OP.NOTICE, "Invite sent", 0)
				elseif why ~= nil then
					send(player, OP.NOTICE, why, 1)
				end
			elseif action == "accept" and tuid ~= nil then
				local ok, why = party:accept(player, tuid)
				if not ok and why ~= nil then
					send(player, OP.NOTICE, why, 1)
				end
			elseif action == "decline" and tuid ~= nil then
				party:decline(player, tuid)
			elseif action == "leave" then
				party:leave(player)
			elseif action == "kick" and tuid ~= nil then
				party:kick(player, tuid)
			end
		elseif op == OP.SPECTATE_LOBBY then
			local id = ...
			if directory == nil or type(id) ~= "string" or #id > 64 or joining_lobby[player] then
				return
			end
			joining_lobby[player] = true
			task.spawn(function()
				local ok, err = directory:spectate(player, id)
				joining_lobby[player] = nil
				if ok then
					return -- the teleport is under way
				end
				if err == "studio" then
					-- Studio (no teleports): watch the lobby this server plays itself
					if studio_lobby ~= nil and studio_lobby.id == id and server:stage() ~= "idle" then
						spectating[player] = true
						local nm = if player.DisplayName ~= "" then player.DisplayName else player.Name
						server:on_client(
							player,
							{ uid = tostring(player.UserId), name = nm, spectate = true },
							OP.JOIN,
							nm
						)
						return
					end
					err = "That match has ended."
				end
				send(player, OP.JOIN_RESULT, false, err)
				send(player, OP.NOTICE, err or "Couldn't open that match.", 1)
			end)
		elseif op == OP.ANALYTICS then
			local a_used = analytics_budget[player] or 0
			if a_used >= ServerMain.MAX_ANALYTICS_PER_SEC then
				return
			end
			analytics_budget[player] = a_used + 1
			local ok, err = pcall(Analytics.report, player, ...)
			if not ok then
				report_once("Analytics.report", err)
			end
			-- a solo match starts its clock here (its Stars can't outrun it: server/Rewards)
			local kind, mode = ...
			if kind == "match_start" then
				Rewards.solo_started(player, mode)
			elseif kind == "tutorial" and mode == #TutorialData.FUNNEL then
				-- the tutorial's last step: its Stars, once per player
				task.spawn(Purchases.tutorial_bonus, player, TutorialData.STARS)
			end
		elseif op == OP.SOLO_RESULT then
			local c_used = credit_budget[player] or 0
			if c_used >= ServerMain.MAX_CREDIT_USES_PER_SEC then
				return
			end
			credit_budget[player] = c_used + 1
			local report = ...
			task.spawn(function()
				local ok, err = pcall(Rewards.solo_result, player, report)
				if not ok then
					report_once("Rewards.solo_result", err)
				end
			end)
		elseif op == OP.STARTER_SEEN then
			-- the starter pack's offer is on the player's screen: its 48 hours start (once)
			local c_used = credit_budget[player] or 0
			if c_used >= ServerMain.MAX_CREDIT_USES_PER_SEC then
				return
			end
			credit_budget[player] = c_used + 1
			task.spawn(function()
				if Purchases.starter_seen(player) then
					pcall(Analytics.report, player, "starter", "shown")
				end
			end)
		elseif op == OP.NEW_PLAYER then
			-- Rofront Staging / Studio: "Replay as new player" (the game menu)
			if not (Staging.here() or RunService:IsStudio()) then
				return
			end
			local c_used = credit_budget[player] or 0
			if c_used >= ServerMain.MAX_CREDIT_USES_PER_SEC then
				return
			end
			credit_budget[player] = c_used + 1
			print("[Staging] " .. player.Name .. " replays as a new player")
			SettingsStore.set(player, Analytics.STATS, { matches = 0 })
			task.spawn(Purchases.reset_new_player, player)
		elseif op == OP.SOLO_HOP then
			-- the player starts a solo match on an outdated hub: to a fresh server, where it starts
			local difficulty, map_id = ...
			local now_s = os.clock()
			if
				fresh == nil
				or type(difficulty) ~= "number"
				or (map_id ~= nil and (type(map_id) ~= "string" or #map_id > 64))
				or now_s - (hop_at[player] or -1e9) < ServerMain.HOP_GAP_S
			then
				send(player, OP.HOP_RESULT, false)
				return
			end
			hop_at[player] = now_s
			task.spawn(function()
				local target = if fresh:is_outdated() then fresh:pick() else nil
				local going = false
				if target ~= nil and player.Parent ~= nil then
					local ok, err = pcall(function()
						local opts = Instance.new("TeleportOptions")
						opts.ServerInstanceId = target
						opts:SetTeleportData({
							hop = true,
							solo = { d = math.clamp(math.floor(difficulty), 0, 2), m = map_id },
						})
						game:GetService("TeleportService"):TeleportAsync(game.PlaceId, { player }, opts)
					end)
					going = ok
					if not ok then
						warn("[Fresh] hop failed: " .. tostring(err))
					end
				end
				print(
					string.format("[Fresh] %s: %s", player.Name, if going then "to " .. tostring(target) else "stays")
				)
				pcall(
					Analytics.report,
					player,
					"hop",
					if going then "sent" elseif target == nil then "none" else "failed"
				)
				send(player, OP.HOP_RESULT, going)
			end)
		elseif op == OP.BUY_UNLOCK then
			local c_used = credit_budget[player] or 0
			local key = ...
			if c_used >= ServerMain.MAX_CREDIT_USES_PER_SEC or type(key) ~= "string" or #key > 32 then
				return
			end
			credit_budget[player] = c_used + 1
			task.spawn(function()
				local ok, err = Purchases.buy_unlock(player, key)
				send(player, OP.UNLOCK_RESULT, key, ok, err)
				if ok then
					pcall(Analytics.report, player, "unlocked", key, "stars")
				end
			end)
		elseif op == OP.OPEN_CRATE then
			local c_used = credit_budget[player] or 0
			if c_used >= ServerMain.MAX_CREDIT_USES_PER_SEC then
				return
			end
			credit_budget[player] = c_used + 1
			task.spawn(function()
				local ok, res = Purchases.open_crate(player)
				send(player, OP.CRATE_RESULT, ok, res)
				if ok then
					pcall(Analytics.report, player, "crate_opened", res)
				end
			end)
		elseif op == OP.EQUIP then
			local c_used = credit_budget[player] or 0
			local slot, id = ...
			if c_used >= ServerMain.MAX_CREDIT_USES_PER_SEC or type(slot) ~= "string" then
				return
			end
			if id ~= false and (type(id) ~= "string" or #id > 40) then
				return
			end
			credit_budget[player] = c_used + 1
			task.spawn(function()
				local ok = Purchases.equip(player, slot, id)
				if ok and id ~= false then
					pcall(Analytics.report, player, "equipped", slot)
				end
			end)
		elseif op == OP.USE_CREDIT then
			local c_used = credit_budget[player] or 0
			local kind, target = ...
			if c_used >= ServerMain.MAX_CREDIT_USES_PER_SEC or type(kind) ~= "string" or #kind > 48 then
				return
			end
			credit_budget[player] = c_used + 1
			if kind == "studio_grant:starter" then
				-- dev diagnostics (Studio + AF_DIAG only): the starter pack's receipt, through its real
				-- checks (refused unless its offer runs)
				if RunService:IsStudio() and diag ~= nil then
					task.spawn(Purchases.grant, player.UserId, "starter", "studio-" .. HttpService:GenerateGUID(false))
				end
				return
			end
			if kind == "studio_grant:takeover" or kind == "studio_grant:crate" then
				-- dev diagnostics (Studio + AF_DIAG only): a test credit without a real product
				if RunService:IsStudio() and diag ~= nil then
					local k = if kind == "studio_grant:crate" then "crate" else "takeover"
					task.spawn(Purchases.grant, player.UserId, k, "studio-" .. HttpService:GenerateGUID(false))
				end
				return
			end
			if string.sub(kind, 1, 13) == "studio_grant:" then
				-- dev diagnostics (Studio + AF_DIAG only): test Stars ("studio_grant:stars", target =
				-- how many) or a test unlock / shop flag as if bought with Robux
				-- ("studio_grant:unlock:<key>", "studio_grant:shopflag:<key>")
				if RunService:IsStudio() and diag ~= nil then
					local what = string.sub(kind, 14)
					if what == "stars" then
						task.spawn(Purchases.add_stars, player, tonumber(target) or 10000)
					elseif
						string.sub(what, 1, 7) == "unlock:"
						or string.sub(what, 1, 9) == "shopflag:"
						or string.sub(what, 1, 8) == "shopset:"
					then
						task.spawn(Purchases.grant, player.UserId, what, "studio-" .. HttpService:GenerateGUID(false))
					end
				end
				return
			end
			task.spawn(function()
				if kind == "takeover" and type(target) == "number" then
					-- a public match this server runs: the takeover happens here. Checked before the
					-- credit is spent, and again after (the match went on meanwhile): a nation that fell
					-- in between gives the credit back.
					if not server:can_take_over(player, target) then
						send(player, OP.CREDIT_RESULT, kind, false, "gone")
						return
					end
					local ok, err = Purchases.use(player, kind)
					if not ok then
						send(player, OP.CREDIT_RESULT, kind, false, err)
						return
					end
					if not server:take_over(player, target) then
						Purchases.grant(player.UserId, kind, "refund-" .. HttpService:GenerateGUID(false))
						send(player, OP.CREDIT_RESULT, kind, false, "gone")
						return
					end
					send(player, OP.CREDIT_RESULT, kind, true)
					pcall(Analytics.report, player, "credit_used", kind)
					return
				end
				-- solo (the player's own match runs on their device): spend; the client takes over
				local ok, err = Purchases.use(player, kind)
				send(player, OP.CREDIT_RESULT, kind, ok, err)
				if ok then
					pcall(Analytics.report, player, "credit_used", kind)
				end
			end)
		elseif op == OP.LEAVE and is_match_server then
			-- leaving a public match's server = back to a hub
			pcall(Analytics.report, player, "left")
			pcall(server.leave, server, player)
			task.spawn(function()
				teleports.to_hub({ player })
			end)
		else
			local name = player.DisplayName
			if name == "" then
				name = player.Name
			end
			local ok, err = xpcall(
				server.on_client,
				debug.traceback,
				server,
				player,
				{ uid = tostring(player.UserId), name = name, spectate = spectating[player] == true },
				op,
				...
			)
			if not ok then
				report_once("on_client op " .. tostring(op), err)
			end
		end
	end)

	-- Deep-link launch data (roblox://experiences/start?placeId=…&launchData=…) for the client's
	-- owner-only test hooks (Main.launch_hooks). Short strings only; the client decides what to honour.
	local function tag_launch(player: Player)
		local ok, jd = pcall(function()
			return player:GetJoinData()
		end)
		local ld = if ok and type(jd) == "table" then jd.LaunchData else nil
		if type(ld) == "string" and #ld > 0 and #ld <= 64 then
			player:SetAttribute("AF_LaunchData", ld)
		end
	end
	--- Humans on this server who came to play (spectators don't count for the lobby / bot fill).
	local function players_present(leaving: Player?): number
		local n = 0
		for _, p in Players:GetPlayers() do
			if p ~= leaving and not spectating[p] then
				n += 1
			end
		end
		return n
	end
	--- Their user ids (the lobby's seat ledger: MatchHost.set_roster).
	local function present_uids(leaving: Player?): { string }
		local out = {}
		for _, p in Players:GetPlayers() do
			if p ~= leaving and not spectating[p] then
				table.insert(out, tostring(p.UserId))
			end
		end
		return out
	end
	--- A hub's Watch teleport carries { spectate = true }: that player only watches this match.
	local function tag_spectator(player: Player)
		if not is_match_server then
			return
		end
		local ok, jd = pcall(function()
			return player:GetJoinData()
		end)
		local td = if ok and type(jd) == "table" then jd.TeleportData else nil
		if type(td) == "table" and td.spectate == true then
			spectating[player] = true
		end
		-- a party's members (LobbyDirectory.join): one team in a team game, and back to one hub
		local pd = if type(td) == "table" then td.party else nil
		if type(pd) == "table" and type(pd.key) == "string" and #pd.key <= 64 then
			party_by_uid[tostring(player.UserId)] = pd.key
			if tonumber(pd.leader) ~= nil then
				party_leader[pd.key] = tonumber(pd.leader) :: number
			end
		end
	end
	--- A hub: the party `player` came back with from a match, or the Roblox party it came in.
	local function join_party_on_arrival(player: Player)
		if party == nil then
			return
		end
		local ok, jd = pcall(function()
			return player:GetJoinData()
		end)
		local td = if ok and type(jd) == "table" then jd.TeleportData else nil
		local parties = if type(td) == "table" then td.parties else nil
		local key = if type(parties) == "table" then parties[tostring(player.UserId)] else nil
		if type(key) == "string" and #key <= 64 then
			local leaders = if type(td.leaders) == "table" then td.leaders else {}
			party:arrived(player, key, tonumber(leaders[key]))
			return
		end
		local pid_ok, pid = pcall(function()
			return (player :: any).PartyId
		end)
		if pid_ok and type(pid) == "string" and pid ~= "" then
			local o_ok, others = pcall(function()
				return game:GetService("SocialService"):GetPlayersByPartyId(pid)
			end)
			if o_ok and type(others) == "table" then
				party:join_roblox_party(player, others)
			end
		end
	end
	-- Game admins (the game's owner, or rank 254+ in the owning group; everyone in a Studio playtest)
	-- are told which "players" are bot players — nobody else ever receives it (bots look like players).
	local admins: { [Player]: boolean } = {}
	local admin_sent: { [Player]: string } = {}
	local function is_admin(player: Player): boolean
		if RunService:IsStudio() then
			return true
		end
		if game.CreatorType == Enum.CreatorType.Group then
			if player:GetRankInGroup(game.CreatorId) >= ServerMain.ADMIN_RANK then
				return true
			end
			-- the group's owner, whatever their role's rank
			local info = game:GetService("GroupService"):GetGroupInfoAsync(game.CreatorId)
			return type(info) == "table" and type(info.Owner) == "table" and info.Owner.Id == player.UserId
		end
		return player.UserId == game.CreatorId
	end
	--- The group lookups are web calls that can fail now and then: a few tries before giving up.
	local function check_admin(player: Player)
		task.spawn(function()
			for attempt = 1, 4 do
				local ok, yes = pcall(is_admin, player)
				if player.Parent ~= Players then
					return
				end
				if ok then
					if yes then
						admins[player] = true
					end
					print(
						string.format(
							"[Admin] %s (%d): %s",
							player.Name,
							player.UserId,
							if yes then "game admin" else "player"
						)
					)
					return
				end
				warn(string.format("[Admin] check %d for %s failed: %s", attempt, player.Name, tostring(yes)))
				task.wait(2 * attempt)
			end
		end)
	end
	--- Bot players of the running match (owner ids) to each admin, whenever the match changes.
	local function push_admin_bots()
		local sim = server:sim()
		local ids = {}
		if sim ~= nil and sim.o_bot ~= nil then
			for id = 1, sim.owner_total do
				if sim.o_bot[id] == 1 then
					table.insert(ids, id)
				end
			end
		end
		local key = tostring(sim) .. ":" .. #ids
		for p in admins do
			if listening[p] and admin_sent[p] ~= key then
				admin_sent[p] = key
				send(p, OP.ADMIN_BOTS, ids)
			end
		end
	end
	-- Creator Dashboard analytics: match counts live in the saved settings; on a match server the
	-- killer of an eliminated player is classified here (clients can't tell bot players apart)
	Analytics.configure({
		cosmetic = function(id: string): any
			local C = require(Shared.Data.Cosmetics) :: any
			return C.item(id)
		end,
		--- a shop flag's name and price (Robux), for "Flag Bought"
		shop_flag = function(key: string): (string?, number)
			local f = (require(Shared.Data.Shop) :: any).flag(key)
			local p = (require(Shared.Data.Products) :: any)["shop_" .. key]
			return if f ~= nil then f.name else nil, if p ~= nil then p.robux else 0
		end,
		--- a set bundle's name ("Halloween Pack") and price (Robux)
		shop_pack = function(id: string): (string?, number)
			local s = (require(Shared.Data.Shop) :: any).SETS[id]
			local p = (require(Shared.Data.Products) :: any)["shopset_" .. id]
			return if s ~= nil then s.name .. " Pack" else nil, if p ~= nil then p.robux else 0
		end,
		tutorial_steps = TutorialData.FUNNEL,
		arsenal_title = function(key: string): string?
			local it = (require(Shared.Data.Arsenal) :: any).item(key)
			return if it ~= nil then it.title else nil
		end,
		load_stats = function(player: Player, fn: (any) -> ())
			SettingsStore.when_loaded(player, function(data: any)
				fn(if type(data) == "table" then data[Analytics.STATS] else nil)
			end)
		end,
		save_stats = function(player: Player, stats: any)
			-- (Studio playtests write the real DataStore: they must not count as the owner's matches;
			-- and after a failed load the count starts from nothing: saving it would put a veteran's
			-- matches back to 1)
			if not RunService:IsStudio() and not SettingsStore.load_failed(player) then
				SettingsStore.set(player, Analytics.STATS, stats)
			end
		end,
		classify = function(id: number): string?
			local sim = server:sim()
			if sim == nil or id < 1 or id > (sim.owner_total or 0) then
				return nil
			end
			local Defs = core("Defs")
			local k = sim.o_kind[id]
			if k == Defs.KIND_HUMAN then
				return if sim.o_bot ~= nil and sim.o_bot[id] == 1 then "bot" else "human"
			end
			return if k == Defs.KIND_TRIBE then "tribe" else "nation"
		end,
	})
	-- Paid random items (the cosmetic crates) are not offered where Roblox's policy restricts them
	-- (PolicyService.ArePaidRandomItemsRestricted); unknown until checked = restricted.
	local crates_allowed: { [Player]: boolean } = {}
	inventory_of = function(player: Player): any
		local inv = Purchases.inventory(player)
		inv.crates_allowed = crates_allowed[player] == true
		return inv
	end
	local function check_policy(player: Player)
		local ok, info = pcall(function()
			return PolicyService:GetPolicyInfoForPlayerAsync(player)
		end)
		crates_allowed[player] = ok and type(info) == "table" and info.ArePaidRandomItemsRestricted == false
		send(player, OP.INVENTORY, inventory_of(player))
	end
	-- Robux purchases: a receipt is a stored credit before Roblox hears it was granted
	-- (Studio playtests write the real DataStores: their test credits go to a store of their own)
	local store_name = Purchases.STORE .. (if RunService:IsStudio() then "_studio" else "")
	local got_store, purchase_store = pcall(function()
		return DataStoreService:GetDataStore(store_name)
	end)
	if not got_store then
		if not RunService:IsStudio() then
			error(purchase_store)
		end
		-- an unpublished place open in Studio has no DataStores: the records last for this session
		warn("[Purchases] no DataStore here (an unpublished place): purchases are kept for this session only")
		local rows: { [string]: any } = {}
		purchase_store = {
			GetAsync = function(_: any, k: string): any
				return rows[k]
			end,
			UpdateAsync = function(_: any, k: string, fn: (any) -> any): any
				local v = fn(rows[k])
				if v ~= nil then
					rows[k] = v
				end
				return v
			end,
		}
	end
	Purchases.configure({
		datastore = purchase_store,
		players = Players,
		notify = function(player: Player, credits: any)
			send(player, OP.CREDITS, credits)
		end,
		inventory = function(player: Player, _inv: any)
			send(player, OP.INVENTORY, inventory_of(player))
		end,
		bought = function(player: Player, kind: string, count: number?, spent: number?)
			if kind == "starter" then
				pcall(Analytics.report, player, "starter", "bought")
				return
			end
			local shop_key = string.match(kind, "^shopflag:(.+)$")
			if shop_key ~= nil then
				pcall(Analytics.report, player, "flag_shop", "bought", shop_key, spent)
				return
			end
			local set_id = string.match(kind, "^shopset:(.+)$")
			if set_id ~= nil then
				pcall(Analytics.report, player, "flag_shop", "bought_pack", set_id, spent)
				return
			end
			pcall(Analytics.report, player, "credit_bought", kind, count)
			local key = string.match(kind, "^unlock:(.+)$")
			if key ~= nil then
				pcall(Analytics.report, player, "unlocked", key, "robux")
			end
		end,
		-- an Arsenal unlock (Stars or Robux): the match the player is in lets them use it at once
		-- (also a record that could only be read late: Purchases.load)
		unlocked = function(player: Player, _key: string)
			pcall(server.unlocks_changed, server, player)
		end,
		wait = task.wait,
		log = print,
		-- (Studio: the starter pack is offered before its product exists; the prompt is a test)
		studio = RunService:IsStudio(),
	})
	-- Stars for matches (shared/Data/Stars): public matches as this server measured them, solo
	-- matches on the client's report within what the clock allows
	Rewards.configure({
		add_stars = Purchases.add_stars,
		double = function(player: Player): boolean
			return Purchases.has_unlock(player, "stars2x")
		end,
		send = function(player: Player, payload: any)
			send(player, OP.STARS, payload)
			pcall(Analytics.report, player, "stars_paid", payload.total)
		end,
		log = print,
	})
	MarketplaceService.ProcessReceipt = function(info: any): Enum.ProductPurchaseDecision
		local ok, r = pcall(Purchases.process_receipt, info)
		if ok and r == "granted" then
			return Enum.ProductPurchaseDecision.PurchaseGranted
		end
		if not ok then
			report_once("Purchases.process_receipt", r)
		end
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	Players.PlayerAdded:Connect(function(player: Player)
		task.spawn(Purchases.load, player)
		task.spawn(check_policy, player)
		Analytics.joined(player)
		tag_launch(player)
		tag_spectator(player)
		task.spawn(join_party_on_arrival, player)
		check_admin(player)
		SettingsStore.load(player)
		if host ~= nil then
			host:set_present(players_present())
			host:set_roster(present_uids())
		end
	end)
	for _, p in Players:GetPlayers() do
		task.spawn(Purchases.load, p)
		task.spawn(check_policy, p)
		Analytics.joined(p)
		tag_launch(p)
		tag_spectator(p)
		check_admin(p)
		SettingsStore.load(p)
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		server:peer_disconnected(player)
		listening[player] = nil
		hop_at[player] = nil
		local i = table.find(listening_list, player)
		if i then
			table.remove(listening_list, i)
		end
		msg_budget[player] = nil
		setting_budget[player] = nil
		analytics_budget[player] = nil
		credit_budget[player] = nil
		crates_allowed[player] = nil
		Rewards.release(player)
		Purchases.release(player)
		pcall(Analytics.left, player)
		hello_at[player] = nil
		joining_lobby[player] = nil
		public_since[player] = nil
		public_sent[player] = nil
		-- in line alone, or leading a party in line: out of it (the party's others go back to idle)
		if directory ~= nil and (party == nil or party:key_of(player) == nil or party:is_leader(player)) then
			local key = public_key(player)
			local e = directory:queued(key)
			if e ~= nil then
				directory:dequeue(key)
				local others = {}
				if party ~= nil and party:key_of(player) ~= nil then
					for _, m in party:members(player) do
						if m ~= player then
							table.insert(others, m)
						end
					end
				end
				public_state(others, "idle", e.mode)
			end
		end
		if host ~= nil then
			host:set_present(players_present(player))
			host:set_roster(present_uids(player))
		end
		spectating[player] = nil
		admins[player] = nil
		admin_sent[player] = nil
		if party ~= nil then
			party:removed(player)
		end
	end)
	SettingsStore.start()

	local budget_time = 0.0
	local admin_time = 0.0
	local stats_time = 0.0
	local lobby_push = 0.0
	local studio_beat = 0.0
	RunService.Heartbeat:Connect(function(dt: number)
		admin_time += dt
		if admin_time >= 1.0 then
			admin_time = 0.0
			push_admin_bots()
		end
		budget_time += dt
		if budget_time >= 1.0 then
			budget_time = 0.0
			table.clear(msg_budget)
			table.clear(setting_budget)
			table.clear(analytics_budget)
			table.clear(credit_budget)
		end
		-- MatchServer guards its own tick (a failing Sim ends the match with a notice); this catches
		-- anything else so one fault can't throw on every Heartbeat.
		local ok, err = xpcall(server.process, debug.traceback, server, dt)
		if not ok then
			report_once("MatchServer.process", err)
		end
		-- public lobbies: the hub keeps the game-wide list fresh and shows it; the match server keeps
		-- its lobby record current
		-- (lobby scheduling waits for the shared clock's first measurement, a second or so)
		if directory ~= nil and SharedClock.ready() then
			directory:tick(dt, task.spawn)
			directory:tick_queue(dt, task.spawn)
			lobby_push += dt
			if lobby_push >= ServerMain.LOBBIES_PUSH_S then
				lobby_push = 0.0
				local view = directory:view()
				for _, p in listening_list do
					send(p, OP.LOBBIES, view, public_kinds)
				end
			end
			if studio_lobby ~= nil and server:participant_count() == 0 and server:stage() == "idle" then
				studio_lobby = nil
				server.deps.lobby = nil
			end
			-- Studio: the locally played lobby keeps its live record fresh (as MatchHost does live)
			local stg = server:stage()
			if studio_lobby ~= nil and (stg == "spawn" or stg == "playing") then
				studio_beat += dt
				if studio_beat >= LobbyRules.LIVE_BEAT_S then
					studio_beat = 0.0
					local id = studio_lobby.id
					task.spawn(function()
						pcall(store.update, id, function(v: any): any?
							local cur = LobbyRules.decode(v)
							if cur == nil or cur.status ~= "started" then
								return nil
							end
							cur.beat = now()
							return cur
						end)
					end)
				end
			end
		elseif host ~= nil and SharedClock.ready() then
			host:tick(dt, task.spawn)
		end
		stats_time += dt
		if stats_time >= ServerMain.STATS_EVERY_S then
			local elapsed = stats_time
			stats_time = 0.0
			local st = server:take_stats()
			ServerMain.last_stats = st
			ServerMain.last_stats_window = elapsed
			if workspace:GetAttribute("AF_NET_STATS") == true and st.steps > 0 then
				local n = math.max(1, server:participant_count())
				print(
					string.format(
						"[Net] stage=%s players=%d step avg %.2f ms p99 %.2f max %.2f | encode %.2f ms | %.1f KB/s per client (max delta %d B) | snapshots %d (%d B) | intents %d ok %d dropped",
						server:stage(),
						server:participant_count(),
						st.step_ms_avg,
						st.step_ms_p99,
						st.step_ms_max,
						st.encode_ms_avg,
						st.bytes_sent / 1024 / elapsed / n,
						st.delta_bytes_max,
						st.snapshots_sent,
						st.snapshot_bytes,
						st.intents_ok,
						st.intents_dropped
					)
				)
			end
		end
	end)

	game:BindToClose(function()
		server:shutdown("The game server is restarting. You're back at the title screen.")
		if host ~= nil and not RunService:IsStudio() then
			-- a match server closing: everyone to a hub instead of out of the game
			pcall(teleports.to_hub, Players:GetPlayers())
		end
		SettingsStore.flush(true)
	end)

	-- Warm the shared geography before anyone queues, so the first match starts quickly.
	task.defer(function()
		local WorldMap = core("WorldMap")
		if WorldMap then
			pcall(WorldMap.shared)
		end
	end)

	folder.Parent = ReplicatedStorage
	if diag ~= nil then
		diag.start(ServerMain)
	end
end

return ServerMain
