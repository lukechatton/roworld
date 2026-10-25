--!nocheck
-- No client module stores a field under the name of one of its own methods. `self._buy = button` in
-- UI/StarterOffer hid StarterOffer._buy, so BUY NOW called the button and failed on every press: the
-- starter pack sold nothing in production v86 (2026-10-16; 0 "Clicked" of 229,658 "Opened"). This
-- reads every module under src/client and reports `self.<name> = <not a function>` where the same
-- file defines `function <Class>.<name>(` or `function <Class>:<name>(`.
local fs = require("@lune/fs")

local ROOT = "src/client"
local hits = {}
local files = 0

local function scan(dir: string)
	for _, name in fs.readDir(dir) do
		local path = dir .. "/" .. name
		if fs.isDir(path) then
			scan(path)
		elseif string.sub(name, -5) == ".luau" then
			files += 1
			local src = fs.readFile(path)
			-- each class's methods (`function Class.name(` / `function Class:name(`)
			local methods: { [string]: { [string]: boolean } } = {}
			for cls, m in string.gmatch("\n" .. src, "\nfunction ([%w_]+)[%.:]([%w_]+)%(") do
				methods[cls] = methods[cls] or {}
				methods[cls][m] = true
			end
			-- a `self.<field> = ` inside a method of a class, checked against that class's own methods
			local cls: string? = nil
			local line_no = 0
			for line in string.gmatch(src .. "\n", "([^\n]*)\n") do
				line_no += 1
				local c = string.match(line, "^function ([%w_]+)[%.:][%w_]+%(")
				if c ~= nil then
					cls = c
				end
				local field, rest = string.match(line, "self%.([%w_]+)%s*=%s*([^=].*)$")
				local own = if cls ~= nil then methods[cls] else nil
				if field ~= nil and own ~= nil and own[field] and not string.match(rest, "^function") then
					table.insert(hits, string.format("%s:%d self.%s hides %s.%s", path, line_no, field, cls, field))
				end
			end
		end
	end
end

scan(ROOT)
for _, h in hits do
	print("FAIL " .. h)
end
if #hits > 0 then
	error(#hits .. " fields hide methods")
end
print(string.format("ui_method_shadow: %d modules, no field hides a method", files))
