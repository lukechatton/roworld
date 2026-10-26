--!nonstrict
-- The playable maps for the UI: the replicated registry (Data/MapList)
-- joined with the uploaded thumbnails (Assets/MapThumbs, keyed by the source map folder name). Falls
-- back to the one built-in map when the registry is missing.
local RS = game:GetService("ReplicatedStorage")

local UIMaps = {}

UIMaps.DEFAULT_ID = "world"
--- The source manifests' featured_rank (the registry does not carry it).
UIMaps.FEATURED_RANK = { world = 1, europe = 2, northamerica = 3, southamerica = 4, asia = 5, africa = 6 }

local _entries: { any }? = nil
local _by_id: { [string]: any } = {}

--- Registry ids and thumbnail keys compare case- and punctuation-insensitively.
local function norm(id: string): string
	return string.lower((string.gsub(id, "[^%w]", "")))
end
UIMaps.norm = norm

local function find(folder: Instance?, name: string): any
	local m = folder and folder:FindFirstChild(name)
	if m and m:IsA("ModuleScript") then
		local ok, v = pcall(require, m)
		if ok then
			return v
		end
	end
	return nil
end

--- { {id, name, width, height, categories, featured_rank, thumb}, ... }
function UIMaps.entries(): { any }
	if _entries ~= nil then
		return _entries
	end
	local root = RS:FindFirstChild("Airfront")
	local list = find(root and root:FindFirstChild("Data"), "MapList")
	local thumbs = find(root and root:FindFirstChild("Assets"), "MapThumbs") or {}
	local tnorm = {}
	for k, v in thumbs do
		tnorm[norm(k)] = v
	end
	local out = {}
	local rows = if type(list) == "table" then (list.maps or list) else nil
	if type(rows) == "table" then
		for _, m in rows do
			if type(m) == "table" and m.id ~= nil then
				local e = {
					id = m.id,
					name = m.name or m.id,
					width = m.width,
					height = m.height,
					categories = m.categories or {},
					featured_rank = m.featured_rank or UIMaps.FEATURED_RANK[norm(m.id)],
					thumb = tnorm[norm(m.id)] or tnorm[norm(m.name or "")],
				}
				table.insert(out, e)
				_by_id[norm(m.id)] = e
			end
		end
	end
	if #out == 0 then
		local e = {
			id = UIMaps.DEFAULT_ID,
			name = "World",
			categories = { "featured", "world" },
			featured_rank = 1,
			thumb = tnorm.world,
		}
		table.insert(out, e)
		_by_id[norm(e.id)] = e
	end
	_entries = out
	return out
end

function UIMaps.get(id: string?): any
	UIMaps.entries()
	local key = id or UIMaps.DEFAULT_ID
	-- a public match's smaller build ("world@80") shows as its map
	key = string.match(key, "^(.-)@%d+$") or key
	return _by_id[norm(key)]
end

function UIMaps.name_of(id: string?): string
	local e = UIMaps.get(id)
	return if e then e.name else "World"
end

--- A valid map id for `id` (the default when unknown).
function UIMaps.valid(id: string?): string
	local e = UIMaps.get(id)
	if e then
		return e.id
	end
	local first = UIMaps.entries()[1]
	return if first then first.id else UIMaps.DEFAULT_ID
end

return UIMaps
