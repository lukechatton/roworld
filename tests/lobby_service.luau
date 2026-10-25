--!nocheck
-- The lobby service end to end: the game's own lobby code (LobbyDirectory, MatchHost, LobbyStore.http
-- + failover, LobbyHttp, Signing) under Lune, against the real Node service over HTTP.
-- Needs a running service: tools/lobby_service_test.sh starts one on a free port and runs this with
-- RL_TEST_URL / RL_TEST_SECRET; without them the test only checks the signing vectors.
require("./prelude")
local net = require("@lune/net")
local serde = require("@lune/serde")
local process = require("@lune/process")
local task = require("@lune/task")
local LobbyRules = require("../src/server/Lobbies/LobbyRules")
local LobbyStore = require("../src/server/Lobbies/LobbyStore")
local LobbyDirectory = require("../src/server/Lobbies/LobbyDirectory")
local MatchHost = require("../src/server/Lobbies/MatchHost")
local LobbyHttp = require("../src/server/Lobbies/LobbyHttp")
local Signing = require("../src/server/Lobbies/Signing")
local Sha256 = require("../src/server/Lobbies/Sha256")

local fails = 0
local function expect(cond: any, what: string)
	if cond then
		print("  ok   " .. what)
	else
		fails += 1
		print("FAIL " .. what)
	end
end

local okst, bad = Sha256.SelfTest()
expect(okst, "SHA-256 / HMAC vectors " .. table.concat(bad or {}, ", "))
-- the Node service's own vector (auth.ts: hmacHex of the request string)
expect(
	Signing.request("k", 1700000000, "n", "post", "/v1/x", "{}")
		== Sha256.HmacHex("k", "v1\n1700000000\nn\nPOST\n/v1/x\n{}"),
	"request string format"
)

-- the domain and the port (LobbyHttp.BASE_URL / FALLBACK_URL): a Cloudflare block or a dead domain
-- moves a server onto the service's own port, and it tries the domain again after RETRY_PRIMARY_S
do
	local K = "0123456789abcdef0123456789abcdef"
	local t = 1000
	local blocked = true
	local hits = {}
	local function fake(req)
		local base = string.match(req.Url, "^(https?://[^/]+)")
		hits[#hits + 1] = base
		if base == "https://domain.test" and blocked then
			-- a Cloudflare challenge page: unsigned
			return true, { StatusCode = 403, Body = "<html>Just a moment...</html>", Headers = {} }
		end
		local body = '{"ok":true}'
		local nonce = req.Headers["X-TM-Nonce"]
		return true, { StatusCode = 200, Body = body, Headers = { ["x-tm-sig"] = Signing.response(K, nonce, 200, body) } }
	end
	local logs = {}
	local c = LobbyHttp.new({
		base_url = "https://domain.test",
		fallback_url = "http://1.2.3.4:3002",
		secret = K,
		job_id = "j",
		transport = fake,
		encode = function()
			return "{}"
		end,
		decode = function()
			return { ok = true }
		end,
		now = function()
			return t
		end,
		nonce = function()
			return "0123456789abcdef0123456789abcdef"
		end,
		log = function(m)
			table.insert(logs, m)
		end,
	})
	local r1 = c:post("/v1/lobbies/list", {})
	expect(r1 == nil and hits[1] == "https://domain.test", "a blocked domain: that request fails")
	local r2 = c:post("/v1/lobbies/list", {})
	expect(r2 ~= nil and hits[2] == "http://1.2.3.4:3002" and c:healthy(), "the next one goes to the port, and works")
	t += LobbyHttp.RETRY_PRIMARY_S - 1
	c:post("/v1/lobbies/list", {})
	expect(hits[3] == "http://1.2.3.4:3002", "it stays there for RETRY_PRIMARY_S")
	blocked = false
	t += 2
	local r4 = c:post("/v1/lobbies/list", {})
	expect(r4 ~= nil and hits[4] == "https://domain.test" and c.stats.url == "https://domain.test", "then the domain again")
	expect(#logs == 2 and c.stats.switches == 1, "logged once each way")
	-- no fallback (Studio's AF_LOBBY_URL): failures stay on the one URL
	local c2 = LobbyHttp.new({
		base_url = "https://domain.test",
		secret = K,
		job_id = "j",
		transport = fake,
		encode = function()
			return "{}"
		end,
		decode = function()
			return {}
		end,
		now = os.time,
		nonce = function()
			return "0123456789abcdef0123456789abcdef"
		end,
	})
	blocked = true
	c2:post("/v1/x", {})
	c2:post("/v1/x", {})
	expect(hits[#hits] == "https://domain.test", "without a fallback it stays on its URL")
	expect(LobbyHttp.BASE_URL == "https://rofront.snick.co", "the live URL is the domain, over HTTPS")
end

local URL = process.env.RL_TEST_URL
local SECRET = process.env.RL_TEST_SECRET
if URL == nil or SECRET == nil then
	print("lobby_service: RL_TEST_URL not set, service part skipped (tools/lobby_service_test.sh runs it)")
	if fails > 0 then
		error(fails .. " failures")
	end
	print("lobby_service: all passed")
	return
end

local function transport(req)
	local ok, res = pcall(net.request, { url = req.Url, method = req.Method, headers = req.Headers, body = req.Body })
	if not ok then
		return false, tostring(res)
	end
	return true, { StatusCode = res.statusCode, Body = res.body, Headers = res.headers }
end

local function hex32(): string
	local t = {}
	for i = 1, 32 do
		t[i] = string.format("%x", math.random(0, 15))
	end
	return table.concat(t)
end

local function client(job: string, opts: any?)
	local o = opts or {}
	return LobbyHttp.new({
		base_url = o.url or URL,
		secret = o.secret or SECRET,
		job_id = job,
		transport = o.transport or transport,
		encode = function(t)
			return serde.encode("json", t)
		end,
		decode = function(s)
			return serde.decode("json", s)
		end,
		now = o.now or os.time,
		nonce = hex32,
		log = o.log,
	})
end

-- the switch: LOBBIES=0 on the service moves hubs to MemoryStore without errors (the script flips
-- the service's .env and runs this part alone with RL_TEST_OFF=1)
if process.env.RL_TEST_OFF == "1" then
	local c = client("off-" .. hex32():sub(1, 8))
	local fo = LobbyStore.failover(LobbyStore.http(c, "hub"), LobbyStore.localstore(os.time), {
		healthy = function()
			return c:healthy()
		end,
	})
	local okl = pcall(fo.list)
	expect(okl and fo.backend() == "memory", "service switched off: hubs use MemoryStore")
	if fails > 0 then
		error(fails .. " failures")
	end
	print("lobby_service (switch off): all passed")
	return
end

-- ---------------------------------------------------------------------------------------------
-- The store API over HTTP
-- ---------------------------------------------------------------------------------------------
local run = hex32():sub(1, 8) -- ids unique to this run (the service may be shared between runs)
local c1 = client("hub-a-" .. run)
local s1 = LobbyStore.http(c1, "hub")
local id = "T" .. run
s1.put({ id = id, map = "world", starts = os.time() + 60, max = 10, players = 0, status = "open" }, 120)
local got = s1.get(id)
expect(got and got.map == "world", "put / get")
local listed = false
for _, v in s1.list() do
	if v.id == id then
		listed = true
	end
end
expect(listed and s1.enabled == true, "list (service switched on)")
local new = s1.update(id, function(v)
	v.players += 2
	return v
end)
expect(new.players == 2 and s1.get(id).players == 2, "update")
expect(s1.update(id, function()
	return nil
end) == nil and s1.get(id).players == 2, "update returning nil leaves the record")
expect(s1.lock("L" .. run, 10) == true, "lock granted")
local s2 = LobbyStore.http(client("hub-b-" .. run), "hub")
expect(s2.lock("L" .. run, 10) == false, "another server doesn't get it")
s1.bind_psid("P" .. run, id, 120)
local ms = LobbyStore.http(client("match-" .. run), "match")
expect((ms.lobby_for_psid("P" .. run) or {}).id == id, "psid lookup")
expect(ms.lobby_for_psid("nope" .. run) == nil, "unknown psid")
s1.remove(id)
expect(s1.get(id) == nil, "remove")

-- a stale write loses: two servers read, both write
do
	local cid = "C" .. run
	s1.put({ id = cid, map = "m", starts = os.time() + 60, max = 10, players = 0 }, 120)
	local a_calls = 0
	s1.update(cid, function(v)
		a_calls += 1
		if a_calls == 1 then
			-- another server writes between our read and our write
			s2.update(cid, function(w)
				w.players += 10
				return w
			end)
		end
		v.players += 1
		return v
	end)
	expect(a_calls == 2 and s1.get(cid).players == 11, "a conflict re-applies the change on the current row (" .. a_calls .. " calls)")
	s1.remove(cid)
end

-- a server whose clock is 15 minutes behind: corrected on the first request
do
	local logs = {}
	local cs = client("skewed-" .. run, {
		now = function()
			return os.time() - 900
		end,
		log = function(t)
			table.insert(logs, t)
		end,
	})
	local r = cs:post("/v1/lobbies/list", {})
	expect(r ~= nil and r.ok == true and cs:healthy(), "a 15 min slow clock is corrected (" .. tostring(logs[1]) .. ")")
end

-- a wrong secret never gets a trusted reply
do
	local cb = client("bad-" .. run, { secret = string.rep("f", 64) })
	for _ = 1, 3 do
		cb:post("/v1/lobbies/list", {})
	end
	expect(not cb:healthy(), "wrong secret: unhealthy after 3 refusals")
end

-- ---------------------------------------------------------------------------------------------
-- The game's lobby flow on the service: two hubs + a match server
-- ---------------------------------------------------------------------------------------------
local reserved = 0
local sent = {}
local function make_hub(name: string, store: any)
	local n = 0
	return LobbyDirectory.new({
		store = store,
		teleport = {
			reserve = function()
				reserved += 1
				return "code" .. run .. reserved, "psid" .. run .. reserved
			end,
			send = function(players, code, data)
				table.insert(sent, { players = players, code = code, data = data })
				return true
			end,
		},
		maps = function()
			return { { id = "world", name = "World", weight = 1, land = 651569, k_lin = 1 } }
		end,
		now = os.time,
		rand = math.random,
		new_id = function()
			n += 1
			return name .. run .. "x" .. n
		end,
		wait = task.wait,
		log = function(t)
			if process.env.RL_TEST_VERBOSE == "1" then
				print("    log " .. t)
			end
		end,
	})
end
-- a service shared with earlier runs may already hold lobbies: only count this run's
local function mine(list)
	local out = {}
	for _, v in list do
		if string.find(v.id, run, 1, true) then
			table.insert(out, v)
		end
	end
	return out
end
local hs1 = LobbyStore.http(client("hub1-" .. run), "hub")
local hs2 = LobbyStore.http(client("hub2-" .. run), "hub")
local hub1, hub2 = make_hub("h1", hs1), make_hub("h2", hs2)
-- fresh service assumed for the scheduling check (the script starts one per run)
hub1:refresh()
hub2:refresh()
local created = mine(hs1.list())
-- (the free-for-alls and World's own lobby)
local want_open = LobbyRules.TARGET_OPEN + LobbyRules.TARGETS_WITH_TEAMS.world
expect(#created == want_open, "hub 1 schedules " .. #created .. " lobbies, hub 2 (lock held) none")
expect(#mine(hub2:view()) == want_open, "both hubs list them")
local first = mine(hub2:view())[1]
local ok, msg = hub2:join("player1", first.id)
expect(ok and hs1.get(first.id).players == 1, "join reserves a slot on the service: " .. tostring(msg))

-- the match server finds its lobby by PrivateServerId, keeps the count, starts, finishes
local rec = hs1.get(first.id)
local host = MatchHost.new({
	store = LobbyStore.http(client("mh-" .. run), "match"),
	psid = rec.psid,
	now = os.time,
	to_hub = function()
		return true
	end,
})
expect(host:lookup() and host.lobby.id == first.id, "match server found its lobby")
host:set_present(4)
host:_sync()
expect(hs1.get(first.id).players == 4, "match server's presence count reaches the record")
host:start(4)
hub1:refresh()
local live = false
for _, v in hub1:view() do
	if v.id == first.id and v.live then
		live = true
	end
end
expect(live, "a started lobby shows live on the hubs")
host:finish()
expect(hs1.get(first.id) == nil, "finished: the record goes")

-- ---------------------------------------------------------------------------------------------
-- A flood: 60 players on 6 hubs join one 20-player lobby at the same moment
-- ---------------------------------------------------------------------------------------------
do
	local lid = "F" .. run
	hs1.put({ id = lid, map = "world", map_name = "World", starts = os.time() + 80, created = os.time(), max = 20, players = 0, status = "open", code = "fc", psid = "fp" .. run }, 200)
	local hubs = {}
	for i = 1, 6 do
		local h = make_hub("fh" .. i, LobbyStore.http(client("fh" .. i .. "-" .. run), "hub", task.wait))
		h:refresh()
		table.insert(hubs, h)
	end
	local joined, refused, errors, done = 0, 0, 0, 0
	local before = #sent
	for p = 1, 60 do
		task.spawn(function()
			local okj, m = hubs[(p % 6) + 1]:join("flood" .. p, lid)
			if okj then
				joined += 1
			elseif m and string.find(m, "full", 1, true) then
				refused += 1
			else
				errors += 1
			end
			done += 1
		end)
	end
	local t0 = os.clock()
	while done < 60 and os.clock() - t0 < 30 do
		task.wait(0.05)
	end
	local final = hs1.get(lid).players
	expect(done == 60, "all 60 joins answered (" .. string.format("%.2f", os.clock() - t0) .. " s)")
	expect(final == 20 and joined == 20 and #sent - before == 20, string.format("exactly 20 seated, never overbooked (joined %d, refused %d, errors %d, record %d)", joined, refused, errors, final))
end

-- ---------------------------------------------------------------------------------------------
-- Quick Play: 60 players on 6 hubs ask for a team game at the same moment; two 20-slot lobbies
-- ---------------------------------------------------------------------------------------------
do
	local q1, q2 = "Q1" .. run, "Q2" .. run
	local t = os.time()
	hs1.put({ id = q1, map = "luna", map_name = "Luna", starts = t + 70, created = t, max = 20, players = 0, status = "open", code = "q1c", psid = "q1p" .. run, mode = "team", teams = 2 }, 200)
	hs1.put({ id = q2, map = "luna", map_name = "Luna", starts = t + 80, created = t, max = 20, players = 0, status = "open", code = "q2c", psid = "q2p" .. run, mode = "team", teams = 2 }, 200)
	hs1.bind_psid("q1p" .. run, q1, 200)
	expect(hs1.get(q1).slots == 20 and hs1.get(q1).max == nil, "a team game's size is stored as slots")
	local hubs = {}
	for i = 1, 6 do
		local h = make_hub("qh" .. i, LobbyStore.http(client("qh" .. i .. "-" .. run), "hub", task.wait))
		h:refresh()
		table.insert(hubs, h)
	end
	local seated, no_room, errors, done = 0, 0, 0, 0
	local where = {}
	local before = #sent
	for p = 1, 60 do
		task.spawn(function()
			local okj, why, l = hubs[(p % 6) + 1]:join_public({ "qf" .. p }, "team")
			if okj then
				seated += 1
				where[l.id] = (where[l.id] or 0) + 1
			elseif why == LobbyDirectory.NO_ROOM then
				no_room += 1
			else
				errors += 1
				print("    error: " .. tostring(why))
			end
			done += 1
		end)
	end
	local t0 = os.clock()
	while done < 60 and os.clock() - t0 < 30 do
		task.wait(0.05)
	end
	local r1, r2 = hs1.get(q1), hs1.get(q2)
	local ledger = 0
	for _ in r1.seats or {} do
		ledger += 1
	end
	expect(done == 60, "all 60 asks answered (" .. string.format("%.2f", os.clock() - t0) .. " s)")
	expect(
		seated == 40 and no_room == 20 and errors == 0 and r1.players == 20 and r2.players == 20 and #sent - before == 40,
		string.format("the soonest fills first, then the next: exactly 40 seated (seated %d, no room %d, errors %d, records %d + %d)", seated, no_room, errors, r1.players, r2.players)
	)
	expect(where[q1] == 20 and where[q2] == 20 and ledger == 20, "20 in each, every seat in the ledger")
	-- a seat given back over HTTP, once
	local after, n = hs1.release(q1, { "qf1", "qf1", "nobody" })
	expect(n == 1 and after.players == 19 and hs1.get(q1).players == 19, "release over HTTP: one seat back")
	-- the match server gives back seats nobody came for (ARRIVE_S later)
	local mh = MatchHost.new({
		store = LobbyStore.http(client("qmh-" .. run), "match"),
		psid = "q1p" .. run,
		now = function()
			return os.time() + LobbyRules.ARRIVE_S + 1
		end,
		to_hub = function()
			return true
		end,
	})
	expect(mh:lookup(), "the team game's match server finds its lobby")
	local here = {}
	for _, u in { "qf7", "qf13", "qf19" } do
		if r1.seats[u] ~= nil then
			table.insert(here, u)
		end
	end
	mh:set_present(#here)
	mh:set_roster(here)
	mh:_sync()
	expect(hs1.get(q1).players == #here and mh.released == 19 - #here, string.format("seats nobody came for go back: %d present, %d released", #here, mh.released))
	-- the hub's list: every open lobby, running matches capped
	local started = 0
	for _, v in hs1.list() do
		if v.status == "started" then
			started += 1
		end
	end
	expect(started <= LobbyStore.LIST_LIVE, "the list carries LIST_LIVE running matches at most")
	hs1.remove(q1)
	hs1.remove(q2)
end

-- ---------------------------------------------------------------------------------------------
-- Failover: the service goes down -> MemoryStore (a local store here), then comes back
-- ---------------------------------------------------------------------------------------------
do
	local down = true
	local fake_clock = 0
	local c = client("fo-" .. run, {
		transport = function(req)
			if down then
				return false, "connect refused"
			end
			return transport(req)
		end,
	})
	local fallback = LobbyStore.localstore(os.time)
	local logs = {}
	local fo = LobbyStore.failover(LobbyStore.http(c, "hub"), fallback, {
		healthy = function()
			return c:healthy()
		end,
		clock = function()
			return fake_clock
		end,
		log = function(t)
			table.insert(logs, t)
		end,
	})
	local e1 = pcall(fo.list)
	local e2 = pcall(fo.list)
	expect(not e1 and not e2 and fo.backend() == "service", "one or two failed lists: the refresh fails, no switch yet")
	local ok3 = pcall(fo.list)
	expect(ok3 and fo.backend() == "memory", "down (3 failures): MemoryStore, " .. tostring(logs[1]))
	fo.put({ id = "M" .. run, map = "world", starts = os.time() + 60, max = 10, players = 0 }, 60)
	expect(fallback.get("M" .. run) ~= nil, "lobbies made meanwhile go to MemoryStore")
	down = false
	fake_clock += 5
	fo.list()
	expect(fo.backend() == "memory", "no probe before PROBE_S")
	fake_clock += LobbyStore.PROBE_S
	fo.list()
	expect(fo.backend() == "service", "back after the probe: " .. tostring(logs[2]))
	local u = fo.update("M" .. run, function(v)
		v.players = 3
		return v
	end)
	expect(u ~= nil and fallback.get("M" .. run).players == 3, "a MemoryStore lobby keeps updating MemoryStore")
end

if fails > 0 then
	error(fails .. " failures")
end
print("lobby_service: all passed")
