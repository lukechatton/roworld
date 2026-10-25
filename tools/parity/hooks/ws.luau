-- warship state trace (matches the WS lines of the instrumented original copy)
return function(ctx)
	local prev = ctx.Sim._warship_tick
	ctx.Sim._warship_tick = function(self, u)
		if ctx.on() then
			ctx.log(
				string.format(
					"WS uid %d own %d pos %d hp %d st %d tu %d tt %d end %d hunt %d pat %d path %d idx %d",
					u.uid,
					u.owner,
					self:unit_tile(u),
					u.hp,
					u.state,
					u.target_uid,
					u.target_tile,
					u.end_tick,
					u.hunt_uid,
					u.patrol,
					#u.path,
					u.start_tick
				)
			)
		end
		return prev(self, u)
	end
end
