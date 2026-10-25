--!strict
-- Map data transfer. Terrain of the non-default maps lives on the server only
-- (ServerScriptService.AirfrontServer.MapData, ~19-54 MB for all of them — too much to replicate),
-- so a client that needs one (solo on another map, a multiplayer match on another map) asks the
-- server for it by id:
--
--   server: MapFetch.serve(net_folder, load_data)   -- RemoteFunction net_folder.GetMap
--   client: local ok, err = MapFetch.fetch(id)      -- yields; then WorldMap.get(id) works
--
-- Wire: InvokeServer(id, chunk) → { id, name, width, height, k_lin, nations, size, chunks, chunk }
-- where `chunk` is a buffer slice (CHUNK_BYTES) of the map's zstd-compressed tile bytes; the client
-- joins the slices and hands WorldMap the data (codec "zstd"). The default map (MapList.DEFAULT) is
-- replicated and never fetched. Maps already available locally return at once.
local MapFetch = {}

MapFetch.CHUNK_BYTES = 192 * 1024
--- Server: GetMap calls per player per 10 s.
MapFetch.MAX_CALLS_PER_10S = 60
MapFetch.REMOTE_NAME = "GetMap"

local function shared_root(): any
	return (game :: any):GetService("ReplicatedStorage"):WaitForChild("Airfront")
end

local function core(name: string): any
	return (require :: any)(shared_root():WaitForChild("Core"):WaitForChild(name))
end

-- =============================================================================================
-- Server
-- =============================================================================================

--- Creates the GetMap RemoteFunction under `folder` and answers it with `load_data(id)` (a map
--- data table as written by tools/maps/import_maps.py).
function MapFetch.serve(folder: Instance, load_data: (string) -> { [string]: any }?)
	local MapCodec = core("MapCodec")
	local MapList = (require :: any)(shared_root():WaitForChild("Data"):WaitForChild("MapList"))
	local rf = Instance.new("RemoteFunction")
	rf.Name = MapFetch.REMOTE_NAME
	rf.Parent = folder
	-- id → { meta = {...}, z = buffer (zstd bytes) }
	local cache: { [string]: any } = {}
	local calls: { [any]: { n: number, t: number } } = {}
	local function entry(id: string): any
		local e = cache[id]
		if e ~= nil then
			return e
		end
		local data = load_data(id)
		if type(data) ~= "table" or type(data.terrain) ~= "string" then
			return nil
		end
		local z = MapCodec.b64decode(data.terrain)
		local nations = {}
		for i, n in data.nations or {} do
			nations[i] = { name = n.name, flag = n.flag, x = n.x, y = n.y }
		end
		e = {
			meta = {
				id = id,
				name = data.name,
				width = data.width,
				height = data.height,
				k_lin = data.k_lin,
				land_tiles = data.land_tiles,
				nations = nations,
				size = data.size or (data.width * data.height),
			},
			z = z,
		}
		cache[id] = e
		return e
	end
	rf.OnServerInvoke = function(player: any, id: any, chunk: any): any
		if type(id) ~= "string" or MapList.get(id) == nil then
			return nil
		end
		local now = os.clock()
		local c = calls[player]
		if c == nil or now - c.t > 10 then
			c = { n = 0, t = now }
			calls[player] = c
		end
		c.n += 1
		if c.n > MapFetch.MAX_CALLS_PER_10S then
			return nil
		end
		local ok, e = pcall(entry, id)
		if not ok or e == nil then
			return nil
		end
		local zlen = buffer.len(e.z)
		local chunks = math.max(1, math.ceil(zlen / MapFetch.CHUNK_BYTES))
		local k = math.floor(tonumber(chunk) or 0)
		if k < 0 or k >= chunks then
			return nil
		end
		local from = k * MapFetch.CHUNK_BYTES
		local len = math.min(MapFetch.CHUNK_BYTES, zlen - from)
		local part = buffer.create(len)
		buffer.copy(part, 0, e.z, from, len)
		local out = table.clone(e.meta)
		out.chunks = chunks
		out.zsize = zlen
		out.chunk = part
		return out
	end
	(game :: any):GetService("Players").PlayerRemoving:Connect(function(p: any)
		calls[p] = nil
	end)
end

-- =============================================================================================
-- Client
-- =============================================================================================

local inflight: { [string]: { any } } = {}

--- Makes map `id` available to WorldMap.get (yields while downloading). Returns true, or false
--- and an error message.
function MapFetch.fetch(id: string): (boolean, string?)
	local WorldMap = core("WorldMap")
	-- a smaller build ("world@80") is made from its map's data
	id = (WorldMap.split_id(id))
	if WorldMap.available(id) then
		return true, nil
	end
	local waiting = inflight[id]
	if waiting ~= nil then
		-- Another caller is downloading it: wait for that one.
		table.insert(waiting, coroutine.running())
		return coroutine.yield()
	end
	inflight[id] = {}
	local ok, err = pcall(function()
		local folder = (game :: any):GetService("ReplicatedStorage"):WaitForChild("AirfrontNet", 30)
		local rf = folder and folder:WaitForChild(MapFetch.REMOTE_NAME, 30)
		if rf == nil then
			error("map service unavailable")
		end
		local first = rf:InvokeServer(id, 0)
		if type(first) ~= "table" or typeof(first.chunk) ~= "buffer" then
			error("server has no map '" .. id .. "'")
		end
		local z = buffer.create(first.zsize)
		buffer.copy(z, 0, first.chunk, 0, buffer.len(first.chunk))
		local at = buffer.len(first.chunk)
		for k = 1, first.chunks - 1 do
			local part = rf:InvokeServer(id, k)
			if type(part) ~= "table" or typeof(part.chunk) ~= "buffer" then
				error("map download interrupted")
			end
			buffer.copy(z, at, part.chunk, 0, buffer.len(part.chunk))
			at += buffer.len(part.chunk)
		end
		if at ~= first.zsize then
			error("map download size mismatch")
		end
		WorldMap.put_data(id, {
			id = id,
			name = first.name,
			width = first.width,
			height = first.height,
			k_lin = first.k_lin,
			land_tiles = first.land_tiles,
			nations = first.nations,
			size = first.size,
			codec = "zstd",
			terrain = z,
		})
	end)
	local waiters = inflight[id] or {}
	inflight[id] = nil
	local msg = if ok then nil else tostring(err)
	for _, co in waiters do
		task.spawn(co, ok, msg)
	end
	return ok, msg
end

--- Starts downloading map `id` in the background (no-op when it is available or in flight).
function MapFetch.prefetch(id: string)
	id = string.match(id, "^(.-)@%d+$") or id
	if inflight[id] ~= nil then
		return
	end
	task.spawn(function()
		MapFetch.fetch(id)
	end)
end

return MapFetch
