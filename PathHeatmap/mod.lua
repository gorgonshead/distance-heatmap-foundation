local mod = foundation.createMod()

mod:log("PathHeatmap: loading")

-- Shared state. Globals survive Ctrl+Shift+R, so start fresh on every load.
PathHeatmap = {}

mod:dofile("scripts/config.lua", mod)

function PathHeatmap.debug(message)
	if PathHeatmap.cfg.DEBUG then mod:log(message) end
end

mod:dofile("scripts/particles.lua", mod)
mod:dofile("scripts/grid.lua", mod)
mod:dofile("scripts/distance.lua", mod)
mod:dofile("scripts/plan.lua", mod)
mod:dofile("scripts/overlay.lua", mod)
mod:dofile("scripts/COMP_PATH_SAMPLER.lua", mod)
