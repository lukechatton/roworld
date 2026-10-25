-- valid_site trace (matches the VS lines of the instrumented original copy)
local Defs = require("../../../src/shared/Core/Defs")
local Rules = require("../../../src/shared/Core/Rules")
return function(ctx)
	local prev = ctx.Sim.valid_site
	ctx.Sim.valid_site = function(self, id, kind, t)
		if ctx.on() and t >= 0 and t < Defs.TILE_COUNT then
			local info = string.format(
				"VS id %d kind %d t %d owner %d land %d:",
				id,
				kind,
				t,
				buffer.readi32(self.owner, t * 4),
				buffer.readu8(self.land, t)
			)
			local md = Rules.STRUCT_MIN_DIST
			for _, s in self:structs_in_box(t, Defs.geo_span(t, md), math.ceil(md)) do
				info ..= string.format(
					" [sid %d k %d o %d tile %d d2 %.3f]",
					s.sid,
					s.kind,
					s.owner,
					s.tile,
					Defs.range_d2(s.tile, t)
				)
			end
			ctx.log(info)
		end
		return prev(self, id, kind, t)
	end
end
