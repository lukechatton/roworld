--!strict
-- Per-player settings sanitizer, shared by the client (Session.save_settings / the copy it keeps) and the
-- server (SettingsStore, which persists them in a DataStore). The original kept these in
-- user://settings.cfg sections ([audio] music_enabled, [ui] ratio, labels, difficulty, tips_seen…).
--
-- A settings blob is { [section] = { [key] = value } } where a value is
--   * a boolean, a finite number (|v| < 1e12) or a string of at most MAX_STRING bytes, or
--   * ONE nested level of such scalars keyed by name (e.g. [ui] tips_seen = { expand = true, … }).
-- Names are 1..MAX_NAME characters of [A-Za-z0-9_]. Everything else is dropped, never an error.
--
-- The input may be an untrusted client table of any size or shape (cycles, metatables, huge tables):
-- every walk stops after a fixed number of EXAMINED entries (valid or not), so the cost per message is
-- bounded, and the output is a fresh plain table (never aliases the input).
--
-- Size caps (review_code.md R2-2): a cleaned section keeps at most MAX_SECTION_BYTES and a whole blob
-- at most MAX_TOTAL_BYTES (Settings.bytes: names + string lengths, 8 per number, 1 per boolean), so
-- what the server stores and echoes per player stays small. Real settings are far below: [ui] with its
-- ~15 keys and tips_seen is ~0.4 KB, [audio] a few bytes.

local Settings = {}

Settings.MAX_SECTIONS = 8
--- Valid top-level keys kept per section.
Settings.MAX_KEYS = 32
--- Valid entries kept per nested table.
Settings.MAX_NESTED_KEYS = 32
--- Entries looked at per section (top level + nested, valid or not) before the walk stops.
Settings.MAX_EXAMINED = 192
--- Sections looked at per blob before the walk stops.
Settings.MAX_SECTIONS_EXAMINED = 16
Settings.MAX_NAME = 32
Settings.MAX_SECTION_NAME = 16
Settings.MAX_STRING = 64
--- Size caps (Settings.bytes) of one cleaned section and of a whole blob.
Settings.MAX_SECTION_BYTES = 4096
Settings.MAX_TOTAL_BYTES = 16384

-- size of one scalar value (Settings.bytes metric)
local function value_bytes(v: any): number
	local t = type(v)
	if t == "string" then
		return #v
	elseif t == "number" then
		return 8
	end
	return 1
end

--- Size of a cleaned value: a section ({key = value | {key = scalar}}) or a whole blob
--- ({section = section}): the length of every name and string, 8 per number, 1 per boolean.
function Settings.bytes(t: any): number
	if type(t) ~= "table" then
		return value_bytes(t)
	end
	local n = 0
	for k, v in t do
		n += #tostring(k) + Settings.bytes(v)
	end
	return n
end

function Settings.valid_name(s: any, max: number?): boolean
	return type(s) == "string" and #s > 0 and #s <= (max or Settings.MAX_NAME) and string.match(s, "^[%w_]+$") ~= nil
end

local valid_name = Settings.valid_name

local function scalar_ok(v: any): boolean
	local t = type(v)
	if t == "boolean" then
		return true
	elseif t == "number" then
		return v == v and math.abs(v) < 1e12
	elseif t == "string" then
		return #v <= Settings.MAX_STRING
	end
	return false
end

-- rawget-style iteration: `next` never calls __index / __pairs metamethods of hostile tables.
local function walk(t: { [any]: any }, budget: { n: number }, fn: (any, any) -> boolean)
	local k, v = next(t)
	while k ~= nil do
		budget.n -= 1
		if budget.n < 0 then
			return
		end
		if fn(k, v) == false then
			return
		end
		k, v = next(t, k)
	end
end

--- A cleaned copy of one settings section, or nil when `values` is not a table. Entries past the
--- MAX_SECTION_BYTES size budget are dropped (trimmed, never an error).
function Settings.clean_section(values: any): { [string]: any }?
	if type(values) ~= "table" then
		return nil
	end
	local out = {}
	local n = 0
	local budget = { n = Settings.MAX_EXAMINED }
	local room = Settings.MAX_SECTION_BYTES
	walk(values, budget, function(k, v)
		if not valid_name(k) then
			return true
		end
		if type(v) == "table" then
			if #k >= room then
				return true
			end
			local sub = {}
			local m = 0
			local used = #k
			walk(v, budget, function(k2, v2)
				if valid_name(k2) and scalar_ok(v2) then
					local b = #k2 + value_bytes(v2)
					if used + b > room then
						return true -- over the size budget: dropped
					end
					used += b
					sub[k2] = v2
					m += 1
					if m >= Settings.MAX_NESTED_KEYS then
						return false
					end
				end
				return true
			end)
			out[k] = sub
			room -= used
		elseif scalar_ok(v) then
			local b = #k + value_bytes(v)
			if b > room then
				return true
			end
			room -= b
			out[k] = v
		else
			return true
		end
		n += 1
		return n < Settings.MAX_KEYS
	end)
	return out
end

--- A cleaned copy of a whole settings blob ({} when unusable). A section that would take the blob
--- past MAX_TOTAL_BYTES is dropped whole.
function Settings.clean_all(data: any): { [string]: { [string]: any } }
	local out = {}
	if type(data) ~= "table" then
		return out
	end
	local n = 0
	local total = 0
	local budget = { n = Settings.MAX_SECTIONS_EXAMINED }
	walk(data, budget, function(section, values)
		if valid_name(section, Settings.MAX_SECTION_NAME) then
			local c = Settings.clean_section(values)
			if c then
				local b = #section + Settings.bytes(c)
				if total + b > Settings.MAX_TOTAL_BYTES then
					return true
				end
				total += b
				out[section] = c
				n += 1
				if n >= Settings.MAX_SECTIONS then
					return false
				end
			end
		end
		return true
	end)
	return out
end

--- Deep copy of a cleaned section (one nested level), so callers can mutate what they get.
function Settings.copy_section(s: { [string]: any }?): { [string]: any }
	local out = {}
	if s == nil then
		return out
	end
	for k, v in s do
		out[k] = if type(v) == "table" then table.clone(v) else v
	end
	return out
end

--- True when two cleaned sections hold the same values.
function Settings.equal(a: { [string]: any }?, b: { [string]: any }?): boolean
	if a == nil or b == nil then
		return a == b
	end
	for k, v in a do
		local w = b[k]
		if type(v) == "table" then
			if type(w) ~= "table" then
				return false
			end
			for k2, v2 in v do
				if w[k2] ~= v2 then
					return false
				end
			end
			for k2 in w do
				if v[k2] == nil then
					return false
				end
			end
		elseif w ~= v then
			return false
		end
	end
	for k in b do
		if a[k] == nil then
			return false
		end
	end
	return true
end

return Settings
