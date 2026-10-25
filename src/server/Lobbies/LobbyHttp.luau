--!strict
-- Client of the lobby service on easy-1 (services/lobbies, docs/lobby-service.md): signed JSON POSTs
-- with our own deadline, every reply's signature checked, a health state, and a clock correction for
-- signing (a server's clock can be minutes out; the service tells a correctly signed request with a
-- stale timestamp its time, and the request is sent once more).
--
-- It is reached at https://rofront.snick.co (Cloudflare, then easy-1's Caddy; 2026-10-12: the
-- studio's services live under the snick.co domain). While the domain fails (no answer, or an answer
-- that isn't the service's: a Cloudflare block or error page) a server uses the service's own port
-- instead, and tries the domain again after RETRY_PRIMARY_S.
--
--   LobbyHttp.new(deps) -> client
--     deps = {
--       base_url = string, fallback_url = string?, secret = string, job_id = string,
--       transport = function(req) -> (ok, res | err),  -- req {Url, Method, Headers, Body};
--                                                       -- res {StatusCode, Body, Headers}
--       encode = function(t) -> string, decode = function(s) -> any,
--       now = function() -> number,                     -- unix seconds (SharedClock.now live)
--       nonce = function() -> string,                   -- 32 hex
--       log = function(text)?,
--     }
--   client:post(path, body) -> (reply?, err?)   reply = the decoded, verified reply (check .ok)
--   client:healthy() -> boolean                 false after FAIL_THRESHOLD failures in a row
--   LobbyHttp.roblox(deps?) -> client | nil     the live client (nil: HTTP off / not configured)
local Signing = require("./Signing")

local LobbyHttp = {}
LobbyHttp.__index = LobbyHttp

--- The service (easy-1, behind Cloudflare: HTTPS; http:// is redirected).
LobbyHttp.BASE_URL = "https://rofront.snick.co"
--- Its own port, straight (until it closes, docs/lobby-service.md "Ops"): used while the domain fails.
--- "" = none.
LobbyHttp.FALLBACK_URL = "http://54.39.159.132:3002"
--- How long a server stays on the fallback before it tries the domain again.
LobbyHttp.RETRY_PRIMARY_S = 300
--- Live servers use the service (MemoryStore stays the fallback). false = MemoryStore only.
--- (On since 2026-09-28, once easy-1's firewall let port 3002 in; the service's LOBBIES switch turns it
--- off without a publish.)
LobbyHttp.ENABLED = true
LobbyHttp.TIMEOUT_S = 5
--- Transport failures in a row before the service counts as down.
LobbyHttp.FAIL_THRESHOLD = 3

function LobbyHttp.new(deps: { [string]: any })
	local self = setmetatable({}, LobbyHttp)
	self.deps = deps
	self._failures = 0
	--- seconds added to deps.now() for request timestamps (learned from the service)
	self._skew = 0.0
	--- on the fallback until this time (deps.now()), else on base_url
	self._fallback_until = nil :: number?
	self.stats = { requests = 0, failures = 0, ms = 0, last_error = "", url = deps.base_url, switches = 0 }
	return self
end

--- The URL requests go to now.
function LobbyHttp._url(self: any): string
	local d = self.deps
	local untl = self._fallback_until
	if untl ~= nil then
		if d.now() < untl then
			return d.fallback_url
		end
		self._fallback_until = nil
		self.stats.url = d.base_url
		if d.log then
			d.log("[LobbyService] trying " .. d.base_url .. " again")
		end
	end
	return d.base_url
end

--- The domain failed this way (no answer / not the service's answer): the fallback for a while.
function LobbyHttp._route_failed(self: any, url: string, err: string)
	local d = self.deps
	if d.fallback_url == nil or d.fallback_url == "" or url ~= d.base_url then
		return
	end
	self._fallback_until = d.now() + LobbyHttp.RETRY_PRIMARY_S
	self.stats.url = d.fallback_url
	self.stats.switches += 1
	if d.log then
		d.log(string.format("[LobbyService] %s failed (%s): using %s", d.base_url, err, d.fallback_url))
	end
end

function LobbyHttp.healthy(self: any): boolean
	return self._failures < LobbyHttp.FAIL_THRESHOLD
end

function LobbyHttp._fail(self: any, err: string): (nil, string)
	self._failures += 1
	self.stats.failures += 1
	self.stats.last_error = err
	if self._failures == LobbyHttp.FAIL_THRESHOLD and self.deps.log then
		self.deps.log("[LobbyService] unreachable (" .. err .. ")")
	end
	return nil, err
end

function LobbyHttp._ok(self: any)
	if self._failures >= LobbyHttp.FAIL_THRESHOLD and self.deps.log then
		self.deps.log("[LobbyService] reachable again")
	end
	self._failures = 0
end

function LobbyHttp.post(self: any, path: string, body: { [string]: any }): (any?, string?)
	local d = self.deps
	body.protocol = 1
	body.jobId = d.job_id
	local ok_enc, raw = pcall(d.encode, body)
	if not ok_enc then
		return nil, "encode: " .. tostring(raw)
	end
	for attempt = 1, 2 do
		local ts = math.floor(d.now() + self._skew)
		local nonce = d.nonce()
		self.stats.requests += 1
		local t0 = os.clock()
		local base = self:_url()
		local ok, res = d.transport({
			Url = base .. path,
			Method = "POST",
			Headers = {
				["Content-Type"] = "application/json",
				["X-TM-Ts"] = tostring(ts),
				["X-TM-Nonce"] = nonce,
				["X-TM-Sig"] = Signing.request(d.secret, ts, nonce, "POST", path, raw),
			},
			Body = raw,
		})
		self.stats.ms = math.floor((os.clock() - t0) * 1000)
		if not ok then
			self:_route_failed(base, tostring(res))
			return self:_fail(tostring(res))
		end
		local status = tonumber(res.StatusCode) or 0
		local text = res.Body or ""
		if status == 401 then
			-- a stale timestamp: the (unsigned) reply carries the service's time; correct and resend once
			local okd, j = pcall(d.decode, text)
			local st = if okd and type(j) == "table" then tonumber(j.serverTime) else nil
			if attempt == 1 and st ~= nil and math.abs(st - (d.now() + self._skew)) < 24 * 3600 then
				self._skew = st - d.now()
				if d.log then
					d.log(string.format("[LobbyService] clock corrected by %+.0fs for signing", self._skew))
				end
				continue
			end
			return self:_fail("http 401 (signature or clock)")
		end
		if not Signing.verify_response(d.secret, nonce, status, text, Signing.header(res.Headers, "X-TM-Sig")) then
			-- a reply we can't trust (a proxy's error page, tampering): unreachable
			local err = string.format("unsigned reply (http %d)", status)
			self:_route_failed(base, err)
			return self:_fail(err)
		end
		self:_ok()
		local okd, decoded = pcall(d.decode, text)
		if not okd or type(decoded) ~= "table" then
			return nil, "bad json"
		end
		return decoded, nil
	end
	return self:_fail("http 401")
end

--- RequestAsync with our own deadline (the call itself can hang ~30 s).
local function roblox_transport(HttpService: any, timeout: number): (any) -> (boolean, any)
	return function(req: any): (boolean, any)
		local thread = coroutine.running()
		local done = false
		task.spawn(function()
			local ok, res = pcall(function()
				return HttpService:RequestAsync(req)
			end)
			if done then
				return
			end
			done = true
			task.spawn(thread, ok, res)
		end)
		task.delay(timeout, function()
			if done then
				return
			end
			done = true
			task.spawn(thread, false, "timeout")
		end)
		return coroutine.yield()
	end
end

--- The live client, or nil when HTTP requests are off for the place / the service is not in use.
--- `url` overrides BASE_URL (Studio: the AF_LOBBY_URL attribute points at a test service); the
--- fallback is FALLBACK_URL for BASE_URL only.
function LobbyHttp.roblox(secret: string, now: () -> number, url: string?, log: ((string) -> ())?): any
	local HttpService = game:GetService("HttpService")
	local ok, enabled = pcall(function()
		return HttpService.HttpEnabled
	end)
	if not ok or enabled ~= true then
		return nil
	end
	local job = game.JobId
	if job == "" then
		job = "studio-" .. string.gsub(HttpService:GenerateGUID(false), "-", "")
	end
	local base = url or LobbyHttp.BASE_URL
	return LobbyHttp.new({
		base_url = base,
		fallback_url = if base == LobbyHttp.BASE_URL and LobbyHttp.FALLBACK_URL ~= ""
			then LobbyHttp.FALLBACK_URL
			else nil,
		secret = secret,
		job_id = job,
		transport = roblox_transport(HttpService, LobbyHttp.TIMEOUT_S),
		encode = function(t: any): string
			return HttpService:JSONEncode(t)
		end,
		decode = function(s: string): any
			return HttpService:JSONDecode(s)
		end,
		now = now,
		nonce = function(): string
			return string.lower((string.gsub(HttpService:GenerateGUID(false), "-", "")))
		end,
		log = log,
	})
end

return LobbyHttp
