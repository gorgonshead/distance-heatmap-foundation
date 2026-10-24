local mod = ...

-- Every tunable in one place. Scripts copy these into locals when they load,
-- so a change needs a mod reload (Ctrl+Shift+R) or a save reload.
--
-- Per-frame budgets are counted in units of work.
PathHeatmap.cfg = {
	-- Per-selection, per-job and slow-frame log lines.
	DEBUG = false,
	-- false: watch selections (and time them, with DEBUG) without drawing an
	-- overlay, to measure what selecting a building costs the game itself.
	OVERLAY = true,

	-- Sampling --------------------------------------------------------------
	-- Component types that represent walking people.
	AGENT_TYPES = { "COMP_VILLAGER", "COMP_VISITOR" },
	-- Game seconds between position samples. Each sample adds the elapsed time
	-- as weight, so the total does not depend on this. At walking pace an agent
	-- moves well under one cell between samples, so trails stay unbroken.
	SAMPLE_INTERVAL = 0.3,
	-- Largest weight one sample may add, so a long hitch does not paint a cell.
	MAX_SAMPLE_WEIGHT = 1.0,

	-- Grid and decay ---------------------------------------------------------
	CELL = 2.0, -- metres per grid cell
	-- A villager crossing a cell adds about 1.3 s of presence. With these values
	-- one crossing keeps a cell walkable for about 7 game days, and a cell
	-- pinned at MAX_WEIGHT by someone standing in it fades after about 14. A
	-- game day is 60 s, so those are 7 and 14 minutes at normal speed. Raise
	-- HALF_LIFE_DAYS if trails fragment, lower it if abandoned routes linger.
	HALF_LIFE_DAYS = 3,
	MAX_WEIGHT = 6,
	ACTIVE_WEIGHT = 0.25, -- decayed weight a cell needs to count as walkable
	PRUNE_EVERY = 60, -- game seconds between removals of faded cells

	-- Distance search --------------------------------------------------------
	BANDS = { 50, 100, 150 }, -- band limits in metres; the last is the search limit
	BAND_COLORS = { -- one per band, red/green/blue from 0 to 1
		{ 0.2, 0.9, 0.3 }, -- green
		{ 1.0, 0.8, 0.1 }, -- amber
		{ 0.95, 0.25, 0.2 }, -- red
	},
	SEED_RADIUS = 12, -- reach from the building origin when it has no entrances
	ENTRANCE_RADIUS = 6, -- reach from an entrance to the first walked cell
	RECOMPUTE_EVERY = 20, -- game seconds between refreshes while selected
	SEARCH_POPS_PER_FRAME = 500, -- heap entries processed per frame

	-- Shape planning ---------------------------------------------------------
	RADII = { 3, 5, 8 }, -- semi-minor radii of the shapes, metres
	ASPECTS = { 1, 2.2, 3.5 }, -- stretch classes: semi-major = radius x aspect
	MAX_MAJOR = 16, -- longest semi-major axis, metres
	FILL = 0.6, -- share of a shape that must be walked cells of its band
	PLAN_WORK_PER_FRAME = 10000, -- cell lookups per frame

	-- Markers and particles --------------------------------------------------
	SIZE_PER_RADIUS = 2.4, -- quad size per metre of radius; the dot fades at its edge
	OVERLAY_ALPHA = 0.55, -- opacity of one marker
	PARTICLE_LOOP = 60, -- seconds a particle lives before its replacement fades in
	GROUND_LIFT = 0.6, -- metres above the ground, along the slope
	MAX_GROUND_MISMATCH = 1.5, -- metres the terrain ray may differ from the walked height
	CREATE_PER_FRAME = 24,
	DESTROY_PER_FRAME = 64,

	-- Persistence ------------------------------------------------------------
	-- Game seconds between refreshes of the saved history. A save holds the
	-- history as of the last refresh. Writing the string into the save property
	-- costs a noticeable frame in a large village, so not too often.
	SAVE_EVERY = 150,
	EXPORT_CELLS_PER_FRAME = 2000, -- the grid walk before it does 4x this
}
