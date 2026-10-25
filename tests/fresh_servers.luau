--!nocheck
-- server/FreshServers: which server is outdated, who lists itself, and where a solo starter is sent.
-- Run: .bin/lune run tests/fresh_servers.luau
require("./prelude")
local FreshServers = require("../src/server/FreshServers")

local fails = 0
local function expect(c: any, w: string)
	if c then
		print("  ok   " .. w)
	else
		fails += 1
		print("FAIL " .. w)
	end
end

-- a world of servers sharing one announcement topic and one list
local clock = 1000
local list: { [string]: any } = {}
local servers = {}
local function server(job: string, version: number, players: number, cap: number?)
	local s
	local outdated = false
	s = FreshServers.new({
		version = version,
		job_id = job,
		now = function()
			return clock
		end,
		players = function()
			return players
		end,
		max_players = cap or 30,
		publish = function(v)
			for _, o in servers do
				if o ~= s then
					o:heard(v)
				end
			end
		end,
		list_put = function(key, entry, ttl)
			list[key] = { value = entry, expires = clock + ttl }
		end,
		list_get = function()
			local rows = {}
			for k, e in list do
				if e.expires > clock then
					table.insert(rows, { key = k, value = e.value })
				end
			end
			return rows
		end,
		on_outdated = function()
			outdated = true
		end,
	})
	table.insert(servers, s)
	return s, function()
		return outdated
	end
end

local old1, old1_flag = server("old1", 59, 12)
local old2 = server("old2", 59, 3)
old1:tick()
old2:tick()
expect(not old1:is_outdated() and old1:pick() == nil, "with one version live nobody is outdated or sent anywhere")
expect(list.old1 ~= nil and list.old2 ~= nil, "servers on the newest version list themselves")

-- a publish: a new server starts
clock += 60
local new1 = server("new1", 60, 2)
new1:tick()
expect(old1:is_outdated() and old1_flag(), "an old server hears the new version and tells its clients")
expect(not new1:is_outdated(), "the new server is not outdated")
expect(old1:pick() == "new1", "a solo starter on the old server is sent to the new one")
expect(new1:pick() == nil, "the new server sends nobody anywhere")

-- old servers stop listing themselves; their entries run out
clock += 120
old1:tick()
old2:tick()
new1:tick()
local rows = 0
for k, e in list do
	if e.expires > clock then
		rows += 1
	end
end
expect(rows == 1, "only the new server stays listed")

-- a full new server is not picked; a second one with room is
clock += 60
local full = server("full", 60, 28, 30)
full:tick()
list.new1.value.n = 29
list.new1.value.t = clock
old2._list = nil
expect(old2:pick() == nil, "no server with room: the player stays")
local new2 = server("new2", 60, 5, 30)
new2:tick()
old2._list = nil
expect(old2:pick() == "new2", "a new server with room is picked")

-- an entry that went stale is not trusted
clock += FreshServers.STALE_S + 1
old2._list = nil
list.new2.expires = clock + 100
expect(old2:pick() == nil, "a stale entry is not picked")

-- a server that never heard the announcement learns the version from the list
local deaf = server("deaf", 58, 1)
new2:tick()
clock += 50
new2._next_list = 0
new2:tick()
expect(not deaf:is_outdated(), "(it missed the announcement)")
expect(deaf:pick() == "new2" and deaf:is_outdated(), "the list tells it, and it sends the player on")

-- the list failing is not an error
local broken = FreshServers.new({
	version = 1,
	job_id = "b",
	now = function()
		return clock
	end,
	players = function()
		return 0
	end,
	max_players = 30,
	publish = function()
		error("down")
	end,
	list_put = function()
		error("down")
	end,
	list_get = function()
		error("down")
	end,
})
broken:tick()
broken:heard(2)
expect(broken:pick() == nil, "an unreadable list keeps the player here")
broken:heard("x")
broken:heard(0 / 0)
expect(broken:latest() == 2, "junk announcements are ignored")

if fails > 0 then
	error(fails .. " failures")
end
print("fresh_servers: all passed")
