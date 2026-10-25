--!strict
-- Number display (render_number / render_troops):
-- values are floored, never rounded ("2.45K", "123K", "1.25M"), negatives show as 0, and troops are
-- shown as the internal count / 10 (a 25,000-troop start reads "2.50K").
local NumberFormat = {}

--- `v` with d decimals (already floored to d decimals).
local function fixed(v: number, d: number): string
	return string.format("%." .. d .. "f", v)
end

function NumberFormat.render_number(num: number): string
	if num ~= num then
		num = 0
	end
	num = math.max(num, 0)
	if num >= 10_000_000_000 then
		return fixed(math.floor(num / 100000000) / 10, 1) .. "B"
	elseif num >= 1_000_000_000 then
		return fixed(math.floor(num / 10000000) / 100, 2) .. "B"
	elseif num >= 10_000_000 then
		return fixed(math.floor(num / 100000) / 10, 1) .. "M"
	elseif num >= 1_000_000 then
		return fixed(math.floor(num / 10000) / 100, 2) .. "M"
	elseif num >= 100000 then
		return tostring(math.floor(num / 1000)) .. "K"
	elseif num >= 10000 then
		return fixed(math.floor(num / 100) / 10, 1) .. "K"
	elseif num >= 1000 then
		return fixed(math.floor(num / 10) / 100, 2) .. "K"
	end
	return tostring(math.floor(num))
end

--- render_troops: the internal troop count / 10.
function NumberFormat.render_troops(troops: number): string
	return NumberFormat.render_number(troops / 10)
end

return NumberFormat
