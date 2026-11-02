--!nocheck
-- Who is a game admin (AdminCheck, 2026-11-01): Roblox's group lookups ran past their limit when
-- every join on every server asked twice. Now the group's owner is looked up once per server and a
-- player's answer is shared by every server (the MemoryStore hash map, here a table).
-- Run: .bin/lune run tests/admin_check.luau
require("./prelude")
local AdminCheck = require("../src/server/AdminCheck")

local fails = 0
local function expect(cond: any, what: string)
	if cond then
		print("  ok   " .. what)
	else
		fails += 1
		print("FAIL " .. what)
	end
end

local OWNER, ADMIN, PLAYER = 1001, 1002, 1003
local ranks = { [OWNER] = 200, [ADMIN] = 254, [PLAYER] = 1 }

-- servers sharing one cache
local shared: { [string]: any } = {}
local ttls: { [string]: number } = {}
local owner_asks = 0
local throttled = false
local function server()
	return AdminCheck.new({
		studio = false,
		group = true,
		creator_id = 77,
		rank = function(p)
			if throttled then
				error("Player:GetRankInGroup failed because number of API requests/minute exceeded limit", 0)
			end
			return ranks[p.UserId] or 0
		end,
		owner = function()
			owner_asks += 1
			return OWNER
		end,
		cache_get = function(k)
			return shared[k]
		end,
		cache_set = function(k, v, ttl)
			shared[k] = v
			ttls[k] = ttl
		end,
	})
end

local a, b = server(), server()
expect(a:is_admin({ UserId = ADMIN }), "rank 254 is an admin")
expect(a:is_admin({ UserId = OWNER }), "the group's owner is, whatever their rank")
expect(not a:is_admin({ UserId = PLAYER }), "a player isn't")
expect(owner_asks == 1, "the owner looked up once on this server")
expect(ttls[tostring(PLAYER)] == AdminCheck.CACHE_S, "answers kept for CACHE_S")
expect(b:is_admin({ UserId = ADMIN }) and not b:is_admin({ UserId = PLAYER }), "another server reads the answers")
expect(b.asked == 0 and owner_asks == 1, "without asking Roblox")

-- a throttled lookup: an error (ServerMain tries again later), never a cached "no"
throttled = true
local c = server()
local ok = pcall(c.is_admin, c, { UserId = 2001 })
expect(not ok and shared["2001"] == nil, "a throttled check errors and caches nothing")
expect(c:is_admin({ UserId = ADMIN }), "cached answers still work while Roblox throttles")
throttled = false

-- the cache down: every check asks Roblox, as before
local d = AdminCheck.new({
	studio = false,
	group = true,
	creator_id = 77,
	rank = function(p)
		return ranks[p.UserId] or 0
	end,
	owner = function()
		return OWNER
	end,
	cache_get = function()
		error("MemoryStore unavailable")
	end,
	cache_set = function()
		error("MemoryStore unavailable")
	end,
})
expect(d:is_admin({ UserId = ADMIN }) and not d:is_admin({ UserId = PLAYER }), "no cache: still right")

-- a game owned by a user; Studio
local u = AdminCheck.new({ studio = false, group = false, creator_id = 55 })
expect(u:is_admin({ UserId = 55 }) and not u:is_admin({ UserId = 56 }), "a user's game: its creator")
local st = AdminCheck.new({ studio = true })
expect(st:is_admin({ UserId = 9 }), "everyone in Studio")

if fails > 0 then
	error(fails .. " failure(s)")
end
print("admin_check: all ok")
