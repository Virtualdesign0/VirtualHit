--!strict
--[[
	VirtualHit / Config

	One place to change every default in the library.

	The tunables here used to live as `local DEFAULT_MAX_HITS = 8` at the top
	of whichever module happened to need them, which meant tuning a game
	required editing library source and re-doing it on every update. They are
	now declared once, with a type, a range and a sentence explaining what
	moving them costs.

		local VirtualHit = require(ReplicatedStorage.VirtualHit)

		VirtualHit.configure({
			Pierce = { MaxHits = 12 },
			Sweep = { MaxSegments = 128, MaxAngularStep = math.rad(10) },
			Projectile = { MaxLifetime = 20 },
		})

	Or start from a preset and adjust:

		VirtualHit.configure("Performance")
		VirtualHit.configure({ Telemetry = { WarnMs = 1 } })

	Config sets *defaults*. Per-call options still win: a `MaxHits` passed to
	`Pierce.cast` overrides `Config.Pierce.MaxHits` for that call. Config is
	the layer underneath, so a game states its physics once instead of
	repeating it at every call site.

	Reading it from library code:

		local Config = require(script.Parent.Parent.Config)
		local Sweep = Config.Sweep          -- live section, cache as an upvalue

		... Sweep.MaxSegments ...

	Sections are live tables: `configure` writes into them, so a cached
	reference never goes stale. They are internal — callers get an immutable
	copy from `getConfig()` instead.

	Deliberately absent: epsilons and engine limits. `MIN_TRANSLATION`,
	`SURFACE_MARGIN`, Roblox's voxel resolution and the shapecast segment cap
	are not tunables, they are facts about the maths or the engine, and a
	config field would only invite someone to break them.
]]

local Errors = require(script.Parent.Util.Errors)
local Signal = require(script.Parent.Util.Signal)

local SOURCE = "VirtualHit.Config"

-- Schema

export type Kind = "number" | "integer" | "angle" | "unit" | "string" | "boolean" | "Color3"

type Field = {
	Default: any,
	Kind: Kind,
	Min: number?,
	Max: number?,
	Doc: string,
}

type Section = {
	Doc: string,
	Fields: { [string]: Field },
	--- Cross-field rule, run after the individual fields validate.
	Check: ((values: { [string]: any }) -> string?)?,
}

local function number_(default: number, min: number?, max: number?, doc: string): Field
	return { Default = default, Kind = "number", Min = min, Max = max, Doc = doc }
end

local function integer(default: number, min: number?, max: number?, doc: string): Field
	return { Default = default, Kind = "integer", Min = min, Max = max, Doc = doc }
end

--- Radians. Bounded to a half turn: anything beyond is a unit mix-up.
local function angle(default: number, doc: string): Field
	return { Default = default, Kind = "angle", Min = 0, Max = math.pi, Doc = doc }
end

--- A 0..1 proportion.
local function unit(default: number, doc: string): Field
	return { Default = default, Kind = "unit", Min = 0, Max = 1, Doc = doc }
end

local function text(default: string, doc: string): Field
	return { Default = default, Kind = "string", Doc = doc }
end

local function colour(default: Color3, doc: string): Field
	return { Default = default, Kind = "Color3", Doc = doc }
end

--[[
	The schema.

	Every field carries the range that keeps it sane. The ceilings are not
	arbitrary: they are the point past which a setting stops being a tuning
	choice and starts being a way to hang the server.
]]
local SCHEMA: { [string]: Section } = {
	Limits = {
		Doc = "Physical bounds every query shares. Raising them costs engine time per call.",
		Fields = {
			MinPhysicalAxis = number_(
				0.05,
				1e-3,
				1,
				"Smallest side a solid shape may have. Below this the engine stops reporting contacts reliably."
			),
			MaxSphereRadius = number_(256, 1, 2048, "Largest sphere any query may use."),
			MaxBlockAxis = number_(512, 1, 4096, "Largest side a block query may have."),
			MaxCompoundMembers = integer(
				8,
				1,
				64,
				"Parts in one compound shape. Every member costs its own overlap query and its own iterative shapecast chain per segment, so this keeps one sweep's query count predictable instead of letting it scale with an unbounded member list."
			),
			MaxRayDistance = number_(
				15000,
				1,
				100000,
				"Longest raycast. The default is roughly the diagonal of a large map."
			),
			MaxShapecastDistance = number_(
				1024,
				1,
				4096,
				"Longest single shapecast. Roblox itself degrades well before the ceiling here."
			),
		},
	},

	Pierce = {
		Doc = "Penetrating casts: how far a shot keeps going through geometry.",
		Fields = {
			MaxHits = integer(8, 1, 64, "Surfaces one penetrating cast may pass through."),
			MaxThickness = number_(8, 0, 1000, "Total studs of material a shot may cross."),
			TerrainExitMargin = number_(
				2,
				0,
				64,
				"Extra studs probed past a terrain exit, since voxel surfaces are not exact."
			),
		},
	},

	Materials = {
		Doc = "How per-part material resistance is looked up.",
		Fields = {
			PenetrationMultiplier = number_(
				1,
				0,
				100,
				"Multiplier used when a part declares nothing of its own."
			),
			Attribute = text(
				"PenetrationMultiplier",
				"Attribute name read off a part to override its resistance."
			),
		},
	},

	Filter = {
		Doc = "Collision filtering.",
		Fields = {
			MaxPredicateRetries = integer(
				8,
				1,
				64,
				"Times a query re-runs to skip parts a predicate rejected. Each retry is another engine call."
			),
		},
	},

	Terrain = {
		Doc = "Voxel terrain probing.",
		Fields = {
			Threshold = unit(0.5, "Occupancy at which a voxel counts as solid."),
			Step = number_(1, 0.05, 16, "Studs between samples along a terrain probe."),
		},
	},

	Sweep = {
		Doc = "Swept-volume queries. These four decide the cost of every melee swing.",
		Fields = {
			MaxLinearStep = number_(
				1,
				0.05,
				64,
				"Studs of travel per segment. Smaller is more accurate and more expensive."
			),
			MaxAngularStep = angle(
				math.rad(15),
				"Rotation per segment. Smaller catches fast spins that would otherwise tunnel."
			),
			MaxSegments = integer(
				64,
				1,
				512,
				"Segments one sweep may split into before it reports truncation."
			),
			MaxHitsPerSegment = integer(
				32,
				1,
				256,
				"Hits recorded per segment before the rest are dropped."
			),
			MaxDetailAge = number_(
				20,
				0,
				600,
				"Seconds a cached detail field stays valid before it is rebuilt."
			),
		},
		Check = function(values)
			if values.MaxHitsPerSegment > values.MaxSegments * 32 then
				return "MaxHitsPerSegment is far above MaxSegments; one segment would dominate the budget"
			end
			return nil
		end,
	},

	Detail = {
		Doc = "Detail fields, which scale query precision by distance.",
		Fields = {
			Scale = number_(1, 0.01, 64, "Precision multiplier when no field applies."),
			MaxScale = number_(64, 1, 1024, "Ceiling on any field's multiplier."),
		},
		Check = function(values)
			if values.Scale > values.MaxScale then
				return "Scale is above MaxScale"
			end
			return nil
		end,
	},

	Impact = {
		Doc = "Energy model for penetration and damage falloff. The material resistance table itself is calibrated at load and is not a runtime setting; EnergyScale is the knob that moves the whole model.",
		Fields = {
			Mass = number_(0.01, 1e-6, 1000, "Projectile mass in kilograms."),
			Caliber = number_(0.3, 1e-3, 100, "Projectile diameter in studs."),
			EnergyScale = number_(
				260,
				1e-3,
				100000,
				"Converts kinetic energy to the scale the resistance table is written in, which is not joules. Pierce spends an abstract Power budget where a stud of steel costs five; this spends energy, where a ten-gram round at nine hundred studs a second arrives with four thousand. Charging one against the other is a round that crosses eight hundred studs of steel. The default is calibrated against the rest of these defaults: a ten-gram round at typical Roblox speeds crosses about three studs of steel and stops in four. A game whose rounds fly at a different scale sets its own."
			),
			MaxThickness = number_(8, 0, 1000, "Studs of material one impact may solve through."),
			MinSpeed = number_(
				20,
				0,
				10000,
				"Speed below which a projectile stops rather than penetrates."
			),
			ExitMargin = number_(1e-3, 0, 1, "Studs past an exit surface before the shot resumes."),
		},
	},

	Ballistics = {
		Doc = "Firing solutions and target leading.",
		Fields = {
			LeadIterations = integer(
				32,
				4,
				512,
				"Refinement steps when solving for a moving target. More is more exact and slower."
			),
			LeadTolerance = number_(1e-3, 1e-9, 1, "Convergence tolerance for a lead solution."),
			MaxLeadExpansions = integer(
				64,
				4,
				512,
				"Times the search bracket may widen before the solver gives up."
			),
		},
	},

	Projectile = {
		Doc = "Simulated projectiles.",
		Fields = {
			MaxDistance = number_(
				1000,
				1,
				100000,
				"Studs a projectile may travel before it stops."
			),
			MaxLifetime = number_(10, 0.05, 600, "Seconds a projectile may live."),
			MaxSubstepDistance = number_(
				8,
				0.05,
				512,
				"Studs per simulation substep. Smaller resists tunnelling through thin geometry."
			),
			MaxSubsteps = integer(8, 1, 128, "Substeps one frame may run for a single projectile."),
			MaxPenetrations = integer(4, 0, 64, "Surfaces one projectile may punch through."),
			Mass = number_(
				0.01,
				1e-6,
				1000,
				"Default projectile mass in kilograms. A rifle round is a few grams; this is scaled so a default projectile at a few hundred studs a second carries roughly the energy the material table was tuned against."
			),
			Caliber = number_(0.3, 1e-3, 100, "Default projectile diameter in studs."),
		},
	},

	Pool = {
		Doc = "Reuse pools. Both trade memory for fewer Instance allocations under load.",
		Fields = {
			MaxIdle = integer(
				64,
				0,
				4096,
				"Spent projectiles kept for reuse. Higher trades memory for fewer allocations."
			),
			MaxIdlePrimitives = integer(
				64,
				0,
				4096,
				"Query probes kept for reuse across sweeps, weapons and projectiles. Each retained probe is one anchored, transparent, unqueryable Part."
			),
		},
	},

	Ricochet = {
		Doc = "Deflection off surfaces.",
		Fields = {
			MaxIncidence = angle(
				math.rad(35),
				"Steepest angle that still deflects. Past it the shot buries instead."
			),
			SpeedRetained = unit(0.5, "Fraction of speed kept through a deflection."),
			MinSpeed = number_(
				10,
				0,
				10000,
				"Speed below which a shot stops rather than deflects."
			),
			SurfaceOffset = number_(
				0.05,
				0,
				16,
				"Studs the deflected shot starts off the surface, so it does not re-hit it."
			),
		},
	},

	Rewind = {
		Doc = "Server-side lag compensation history.",
		Fields = {
			Duration = number_(1, 1 / 60, 60, "History window a world keeps when none is given."),
			MinDuration = number_(1 / 60, 1 / 240, 10, "Shortest history window a world may keep."),
			MaxDuration = number_(
				10,
				1 / 60,
				60,
				"Longest history window. Memory grows with duration times snapshot rate."
			),
		},
		Check = function(values)
			if values.MinDuration > values.MaxDuration then
				return "MinDuration is above MaxDuration"
			end
			if values.Duration < values.MinDuration or values.Duration > values.MaxDuration then
				return "Duration is outside the MinDuration..MaxDuration range"
			end
			return nil
		end,
	},

	Validator = {
		Doc = "Bounds a server puts on client-reported shots. These are anti-cheat limits.",
		Fields = {
			MinLatency = number_(0, 0, 10, "Lowest claimed latency accepted."),
			MaxLatency = number_(
				0.5,
				0,
				10,
				"Highest claimed latency accepted. Raising it widens the rewind an attacker can ask for."
			),
			MaxRate = number_(20, 0.1, 1000, "Shots per second one player may claim."),
			MaxOriginError = number_(
				5,
				0,
				1000,
				"Studs the claimed origin may differ from the server's own view."
			),
			MaxDirectionError = angle(
				math.rad(25),
				"Angle the claimed direction may differ from the server's own view."
			),
			MaxDistance = number_(1000, 1, 100000, "Longest claimed shot accepted."),
			MaxHistoryAge = number_(
				0.25,
				0,
				10,
				"Oldest snapshot a claim may resolve against. RewindTo clamps a timestamp past the newest snapshot, so without this a recorder that stalled would let every fresh claim validate against however old the last snapshot happens to be."
			),
		},
		Check = function(values)
			if values.MinLatency > values.MaxLatency then
				return "MinLatency is above MaxLatency"
			end
			return nil
		end,
	},

	Zone = {
		Doc = "Spatial index for zone queries.",
		Fields = {
			CellSize = number_(
				32,
				1,
				1024,
				"Grid cell size in studs. Too small wastes memory, too large wastes comparisons."
			),
			MinCellSize = number_(4, 0.5, 1024, "Floor a caller-supplied cell size is clamped to."),
			Padding = number_(
				4,
				0,
				256,
				"Studs of slack around a zone's bounds when it is indexed."
			),
			Lookahead = number_(
				1 / 30,
				0,
				1,
				"Seconds of predicted movement folded into a moving zone's bounds. The default is two frames of headroom at 60 Hz; a subject moving fast enough to matter is covered by its own velocity rather than by a bigger constant padding."
			),
			PruneInterval = number_(
				30,
				1,
				600,
				"Seconds between full ancestry sweeps that drop empty cells. At the default refresh rate the default is about twice a second: soon enough for a detached subject, rare enough that the walk stops being a per-frame cost."
			),
		},
		Check = function(values)
			if values.MinCellSize > values.CellSize then
				return "MinCellSize is above CellSize"
			end
			return nil
		end,
	},

	Telemetry = {
		Doc = "The on-screen performance readout.",
		Fields = {
			History = integer(120, 1, 3600, "Frames of history the graph keeps."),
			WarnMs = number_(2, 0, 1000, "Milliseconds per frame that counts as slow."),
			CriticalMs = number_(4, 0, 1000, "Milliseconds per frame that counts as a problem."),
		},
		Check = function(values)
			if values.WarnMs > values.CriticalMs then
				return "WarnMs is above CriticalMs, so the warning tier would never show"
			end
			return nil
		end,
	},

	Visualizer = {
		Doc = "Debug drawing.",
		Fields = {
			Duration = number_(1.5, 0.05, 300, "Seconds a drawn shape stays on screen."),
			NormalLength = number_(1, 0.05, 64, "Length of a drawn surface normal, in studs."),
			PathThickness = number_(0.05, 0.01, 8, "Thickness of a drawn path, in studs."),
			SampleTransparency = unit(0.75, "Transparency of drawn sample volumes."),
			CastColor = colour(Color3.fromRGB(0, 170, 255), "Colour of a cast path."),
			HitColor = colour(Color3.fromRGB(255, 85, 85), "Colour of a hit marker."),
			BlockColor = colour(Color3.fromRGB(170, 85, 255), "Colour of a blocking hit."),
			OverlapColor = colour(Color3.fromRGB(255, 170, 0), "Colour of an overlap result."),
			NormalColor = colour(Color3.fromRGB(125, 255, 125), "Colour of a surface normal."),
		},
	},

	Recorder = {
		Doc = "Recording queries for replay.",
		Fields = {
			PositionTolerance = number_(
				0.05,
				0,
				64,
				"Studs a replayed position may differ before it is treated as a mismatch."
			),
			AlphaTolerance = number_(
				1e-3,
				0,
				1,
				"Fractional difference tolerated along a segment."
			),
		},
	},
}

-- Presets

--[[
	Starting points, not policies.

	Each one is a partial patch: `configure("Performance")` applies it over the
	defaults, and anything it does not mention keeps its default. Follow a
	preset with your own patch to adjust from there.
]]
local PRESETS: { [string]: { [string]: { [string]: any } } } = {
	--- Everything back to the shipped values.
	Default = {},

	--- Fewer, coarser steps. For servers with many simultaneous attackers.
	Performance = {
		Sweep = {
			MaxLinearStep = 2,
			MaxAngularStep = math.rad(25),
			MaxSegments = 32,
			MaxHitsPerSegment = 16,
		},
		Projectile = { MaxSubstepDistance = 16, MaxSubsteps = 4, MaxPenetrations = 2 },
		Pierce = { MaxHits = 4 },
		Ballistics = { LeadIterations = 16 },
		Filter = { MaxPredicateRetries = 4 },
	},

	--- Finer stepping. For duels, precise hit boxes, or slow-motion sequences.
	Fidelity = {
		Sweep = {
			MaxLinearStep = 0.5,
			MaxAngularStep = math.rad(7.5),
			MaxSegments = 128,
			MaxHitsPerSegment = 64,
		},
		Projectile = { MaxSubstepDistance = 4, MaxSubsteps = 16 },
		Pierce = { MaxHits = 16 },
		Ballistics = { LeadIterations = 64, LeadTolerance = 1e-4 },
	},

	--- Long-lived debug drawing and a readout that reacts early.
	Debug = {
		Telemetry = { WarnMs = 1, CriticalMs = 2, History = 300 },
		Visualizer = { Duration = 8, NormalLength = 2 },
	},
}

-- Validation

local function typeName(value: any): string
	return typeof(value)
end

--- Returns nil when the value fits the field, or a sentence saying why not.
local function checkField(field: Field, value: any): string?
	local kind = field.Kind

	if kind == "string" then
		if type(value) ~= "string" then
			return `expected a string, got {typeName(value)}`
		end
		if #value == 0 then
			return "must not be empty"
		end
		return nil
	end

	if kind == "boolean" then
		if type(value) ~= "boolean" then
			return `expected a boolean, got {typeName(value)}`
		end
		return nil
	end

	if kind == "Color3" then
		if typeof(value) ~= "Color3" then
			return `expected a Color3, got {typeName(value)}`
		end
		return nil
	end

	if type(value) ~= "number" then
		return `expected a number, got {typeName(value)}`
	end
	-- NaN is a number and compares false against every bound, so it would slip
	-- through a plain range check and then poison the arithmetic downstream.
	if value ~= value then
		return "is NaN"
	end
	if value == math.huge or value == -math.huge then
		return "is infinite"
	end
	if kind == "integer" and value % 1 ~= 0 then
		return `expected a whole number, got {value}`
	end
	if field.Min ~= nil and value < field.Min then
		return `must be at least {field.Min}, got {value}`
	end
	if field.Max ~= nil and value > field.Max then
		return `must be at most {field.Max}, got {value}`
	end

	return nil
end

--- Edit distance, capped: past a couple of edits it is a different word, not a typo.
local function editDistance(a: string, b: string, limit: number): number
	local lenA, lenB = #a, #b
	if math.abs(lenA - lenB) > limit then
		return limit + 1
	end

	local previous = table.create(lenB + 1, 0)
	for j = 0, lenB do
		previous[j + 1] = j
	end

	for i = 1, lenA do
		local current = table.create(lenB + 1, 0)
		current[1] = i
		local best = i
		for j = 1, lenB do
			local cost = if string.sub(a, i, i) == string.sub(b, j, j) then 0 else 1
			local value = math.min(current[j] + 1, previous[j + 1] + 1, previous[j] + cost)
			current[j + 1] = value
			if value < best then
				best = value
			end
		end
		-- Every remaining row can only add, so this row already settles it.
		if best > limit then
			return limit + 1
		end
		previous = current
	end

	return previous[lenB + 1]
end

--[[
	The closest real name, or nil when nothing is close.

	Case alone is the common miss, so it wins outright; otherwise a name within
	two edits counts. Suggesting something three edits away is worse than
	suggesting nothing, because it sends the reader after the wrong field.
]]
local function nearestName(candidates: { [string]: any }, wanted: string): string?
	local lowered = string.lower(wanted)
	local best: string? = nil
	local bestDistance = 3

	for name in candidates do
		local loweredName = string.lower(name)
		if loweredName == lowered then
			return name
		end
		local distance = editDistance(loweredName, lowered, 2)
		if distance < bestDistance then
			best = name
			bestDistance = distance
		end
	end

	return best
end

-- Section types

--[[
	One record type per section, so a read is checked rather than guessed.

	The sections are built in a loop from the schema, which Luau cannot infer a
	shape from, so the shapes are declared here by hand. `tools/check-config-types.sh`
	runs in CI and fails if the two ever disagree, because a type is only worth
	having while it still describes the thing it names.
]]
export type LimitsConfig = {
	MinPhysicalAxis: number,
	MaxSphereRadius: number,
	MaxBlockAxis: number,
	MaxCompoundMembers: number,
	MaxRayDistance: number,
	MaxShapecastDistance: number,
}

export type PierceConfig = {
	MaxHits: number,
	MaxThickness: number,
	TerrainExitMargin: number,
}

export type MaterialsConfig = {
	PenetrationMultiplier: number,
	Attribute: string,
}

export type FilterConfig = {
	MaxPredicateRetries: number,
}

export type TerrainConfig = {
	Threshold: number,
	Step: number,
}

export type SweepConfig = {
	MaxLinearStep: number,
	MaxAngularStep: number,
	MaxSegments: number,
	MaxHitsPerSegment: number,
	MaxDetailAge: number,
}

export type DetailConfig = {
	Scale: number,
	MaxScale: number,
}

export type ImpactConfig = {
	Mass: number,
	Caliber: number,
	EnergyScale: number,
	MaxThickness: number,
	MinSpeed: number,
	ExitMargin: number,
}

export type BallisticsConfig = {
	LeadIterations: number,
	LeadTolerance: number,
	MaxLeadExpansions: number,
}

export type ProjectileConfig = {
	MaxDistance: number,
	MaxLifetime: number,
	MaxSubstepDistance: number,
	MaxSubsteps: number,
	MaxPenetrations: number,
	Mass: number,
	Caliber: number,
}

export type PoolConfig = {
	MaxIdle: number,
	MaxIdlePrimitives: number,
}

export type RicochetConfig = {
	MaxIncidence: number,
	SpeedRetained: number,
	MinSpeed: number,
	SurfaceOffset: number,
}

export type RewindConfig = {
	Duration: number,
	MinDuration: number,
	MaxDuration: number,
}

export type ValidatorConfig = {
	MinLatency: number,
	MaxLatency: number,
	MaxRate: number,
	MaxOriginError: number,
	MaxDirectionError: number,
	MaxDistance: number,
	MaxHistoryAge: number,
}

export type ZoneConfig = {
	CellSize: number,
	MinCellSize: number,
	Padding: number,
	Lookahead: number,
	PruneInterval: number,
}

export type TelemetryConfig = {
	History: number,
	WarnMs: number,
	CriticalMs: number,
}

export type VisualizerConfig = {
	Duration: number,
	NormalLength: number,
	PathThickness: number,
	SampleTransparency: number,
	CastColor: Color3,
	HitColor: Color3,
	BlockColor: Color3,
	OverlapColor: Color3,
	NormalColor: Color3,
}

export type RecorderConfig = {
	PositionTolerance: number,
	AlphaTolerance: number,
}

-- Live sections

local Config = {}

--[[
	Sections are ordinary populated tables behind a metatable that only fires
	on a miss.

	A correct read — `Config.Sweep.MaxSegments` — never touches a metamethod,
	which matters because these sit in per-segment loops. A typo does, and
	says so immediately instead of silently reading nil and defaulting to
	something surprising three calls later.
]]
local sections: { [string]: any } = {}
-- Where the values actually live. The section a caller holds is an empty
-- table in front of this one, so that every read and every write goes through
-- a metamethod: a populated section could only refuse writes to keys that were
-- not there, which is the opposite of what needs refusing.
local stores: { [string]: { [string]: any } } = {}

local function makeSection(name: string, fields: { [string]: Field }): any
	local values = {}
	for key, field in fields do
		values[key] = field.Default
	end
	stores[name] = values

	local known = {}
	for key in fields do
		table.insert(known, key)
	end
	table.sort(known)
	local knownText = table.concat(known, ", ")

	return setmetatable({}, {
		__index = function(_, key)
			if fields[key] ~= nil then
				return values[key]
			end

			return Errors.raise(
				SOURCE,
				Errors.Codes.InvalidArgument,
				`{name} has no setting named '{tostring(key)}'. Available: {knownText}`,
				2
			)
		end,
		__iter = function()
			return next, values
		end,
		__newindex = function(_, key)
			Errors.raise(
				SOURCE,
				Errors.Codes.InvalidArgument,
				`{name}.{tostring(key)} is read-only; call VirtualHit.configure() instead`,
				2
			)
		end,
		__metatable = "locked",
	})
end

for name, section in SCHEMA do
	sections[name] = makeSection(name, section.Fields)
end

--[[
	Published one by one rather than in a loop.

	A loop would leave every section typed `any`, which is the whole reason
	`Config.Pierce.MaxHitz` used to be a runtime surprise instead of a red
	squiggle. Naming them here costs eighteen lines and buys completion and
	analysis on every read in the library and in game code.
]]
Config.Limits = (sections.Limits :: any) :: LimitsConfig
Config.Pierce = (sections.Pierce :: any) :: PierceConfig
Config.Materials = (sections.Materials :: any) :: MaterialsConfig
Config.Filter = (sections.Filter :: any) :: FilterConfig
Config.Terrain = (sections.Terrain :: any) :: TerrainConfig
Config.Sweep = (sections.Sweep :: any) :: SweepConfig
Config.Detail = (sections.Detail :: any) :: DetailConfig
Config.Impact = (sections.Impact :: any) :: ImpactConfig
Config.Ballistics = (sections.Ballistics :: any) :: BallisticsConfig
Config.Projectile = (sections.Projectile :: any) :: ProjectileConfig
Config.Pool = (sections.Pool :: any) :: PoolConfig
Config.Ricochet = (sections.Ricochet :: any) :: RicochetConfig
Config.Rewind = (sections.Rewind :: any) :: RewindConfig
Config.Validator = (sections.Validator :: any) :: ValidatorConfig
Config.Zone = (sections.Zone :: any) :: ZoneConfig
Config.Telemetry = (sections.Telemetry :: any) :: TelemetryConfig
Config.Visualizer = (sections.Visualizer :: any) :: VisualizerConfig
Config.Recorder = (sections.Recorder :: any) :: RecorderConfig

--[[
	The effective value of a setting is three layers deep.

		base    what configure() / reset() last set
		scopes  temporary overrides, oldest first
		live    what the library reads, recomputed from the two above

	Keeping base separate is what lets a scope be released out of order. A
	scope that simply restored the value it captured would clobber a newer
	scope that had since set the same field; recomputing from the layers is
	correct whatever order they come and go in.
]]
local baseValues: { [string]: { [string]: any } } = {}
for name, section in SCHEMA do
	local values = {}
	for key, field in section.Fields do
		values[key] = field.Default
	end
	baseValues[name] = values
end

type Scope = {
	Overrides: { [string]: { [string]: any } },
	Released: boolean,
}

local activeScopes: { Scope } = {}

-- Public surface

--[[
	Fires with the sorted list of `"Section.Field"` paths that changed.

	Held internally as an Emitter and published as a plain Signal, so callers
	get Connect/Once/Wait and the library keeps Fire.
]]
local changedEmitter: Signal.Emitter<{ string }> = Signal.new() :: any
Config.Changed = (changedEmitter :: any) :: Signal.Signal<{ string }>

--[[
	Folds the layers into the live tables and reports what moved.

	Every write goes through here, so there is exactly one place that decides
	what the library actually reads, and exactly one place that fires Changed.
]]
--- The value of every setting given a base and a list of scopes on top of it.
local function effectiveState(scopeList: { Scope }): { [string]: { [string]: any } }
	local result: { [string]: { [string]: any } } = {}

	for sectionName, section in SCHEMA do
		local values = {}
		local base = baseValues[sectionName]

		for key in section.Fields do
			local value = base[key]
			-- Later scopes win, so the newest override is the effective one.
			for _, scope in scopeList do
				local override = scope.Overrides[sectionName]
				if override ~= nil and override[key] ~= nil then
					value = override[key]
				end
			end
			values[key] = value
		end

		result[sectionName] = values
	end

	return result
end

local function recompute()
	local target = effectiveState(activeScopes)
	local changed: { string } = {}

	for sectionName, values in target do
		local live = stores[sectionName]
		for key, value in values do
			if live[key] ~= value then
				live[key] = value
				table.insert(changed, `{sectionName}.{key}`)
			end
		end
	end

	if #changed > 0 then
		table.sort(changed)
		changedEmitter:Fire(table.freeze(changed))
	end
end

--- Validates one patch table into `staged`, collecting anything wrong.
local function collectPatch(
	patch: any,
	staged: { [string]: { [string]: any } },
	problems: { string }
)
	if type(patch) ~= "table" then
		table.insert(problems, `expected a table of sections, got {typeName(patch)}`)
		return
	end

	for sectionName, incoming in patch do
		local section = SCHEMA[sectionName]
		if section == nil then
			local suggestion = nearestName(SCHEMA, tostring(sectionName))
			table.insert(
				problems,
				`unknown section '{tostring(sectionName)}'`
					.. (if suggestion then ` (did you mean '{suggestion}'?)` else "")
			)
			continue
		end
		if type(incoming) ~= "table" then
			table.insert(problems, `{sectionName} must be a table, got {typeName(incoming)}`)
			continue
		end

		local sectionStage = staged[sectionName]
		if sectionStage == nil then
			sectionStage = {}
			staged[sectionName] = sectionStage
		end

		for key, value in incoming do
			local field = section.Fields[key]
			if field == nil then
				local suggestion = nearestName(section.Fields, tostring(key))
				table.insert(
					problems,
					`{sectionName} has no setting '{tostring(key)}'`
						.. (if suggestion then ` (did you mean '{suggestion}'?)` else "")
				)
				continue
			end
			local problem = checkField(field, value)
			if problem ~= nil then
				table.insert(problems, `{sectionName}.{key} {problem}`)
				continue
			end
			-- A later patch in the same call wins, which is what makes
			-- configure("Preset", { ... }) read the way it looks.
			sectionStage[key] = value
		end
	end
end

--[[
	Applies a list of patches as ONE transition.

	Everything — reset, preset, the caller's own table — resolves to a single
	target state that is validated whole and then written once. That matters
	twice over. A subscriber to Changed sees one notification and never a
	half-applied world; and an invalid patch cannot leave an earlier part of
	the same call already applied, which a reset-then-preset-then-patch
	sequence of separate calls could.

	`fromDefaults` starts the target from the shipped values rather than from
	whatever is currently set.
]]
local function apply(patches: { any }, fromDefaults: boolean)
	local problems: { string } = {}
	local staged: { [string]: { [string]: any } } = {}

	for _, patch in patches do
		collectPatch(patch, staged, problems)
	end

	--[[
		The base state that would result, section by section.

		Built from `baseValues`, never from the live tables: a scope's override
		sits on top of the base, and reading the live value here would fold a
		temporary override back into the permanent layer the moment anything
		else was configured.
	]]
	local target: { [string]: { [string]: any } } = {}
	for sectionName, section in SCHEMA do
		local values = {}
		local base = baseValues[sectionName]
		for key, field in section.Fields do
			values[key] = if fromDefaults then field.Default else base[key]
		end
		-- Annotated rather than inlined as `staged[sectionName] or {}`: the
		-- empty literal makes that expression a union the analyser will not
		-- iterate over.
		local stagedSection: { [string]: any } = staged[sectionName] or {}
		for key, value in stagedSection do
			values[key] = value
		end
		target[sectionName] = values
	end

	-- Cross-field rules see the whole resulting section, not just the keys the
	-- caller happened to name.
	for sectionName, section in SCHEMA do
		local check = section.Check
		if check ~= nil then
			local problem = check(target[sectionName])
			if problem ~= nil then
				table.insert(problems, `{sectionName}: {problem}`)
			end
		end
	end

	if #problems > 0 then
		table.sort(problems)
		Errors.raise(
			SOURCE,
			Errors.Codes.InvalidArgument,
			`configure was given {#problems} invalid setting(s):\n  `
				.. table.concat(problems, "\n  "),
			3
		)
	end

	baseValues = target
	recompute()
end

--[[
	Applies a patch, a preset name, or a preset name followed by a patch.

	Nothing is written until the whole thing validates, so a typo in the third
	section cannot leave the first two applied. Every problem is reported at
	once rather than one call at a time.
]]
function Config.configure(patch: any, extra: any?)
	if type(patch) == "string" then
		local preset = PRESETS[patch]
		if preset == nil then
			local names = {}
			for name in PRESETS do
				table.insert(names, name)
			end
			table.sort(names)
			Errors.raise(
				SOURCE,
				Errors.Codes.InvalidArgument,
				`'{patch}' is not a preset. Available: {table.concat(names, ", ")}`,
				2
			)
		end
		-- Defaults, then the preset, then the caller's adjustments, in one go.
		apply({ preset, extra }, true)
		return
	end

	if extra ~= nil then
		Errors.raise(
			SOURCE,
			Errors.Codes.InvalidArgument,
			"the second argument is only meaningful after a preset name; merge the two tables instead",
			2
		)
	end
	if type(patch) ~= "table" then
		Errors.raise(
			SOURCE,
			Errors.Codes.InvalidArgument,
			`configure expects a table or a preset name, got {typeName(patch)}`,
			2
		)
	end

	apply({ patch }, false)
end

--- Restores the shipped defaults, for one section or all of them.
function Config.reset(sectionName: string?)
	if sectionName == nil then
		apply({}, true)
		return
	end

	local section = SCHEMA[sectionName]
	if section == nil then
		Errors.raise(SOURCE, Errors.Codes.InvalidArgument, `unknown section '{sectionName}'`, 2)
	end

	local patch = {}
	for key, field in section.Fields do
		patch[key] = field.Default
	end
	apply({ { [sectionName] = patch } }, false)
end

--[[
	An immutable copy of the whole configuration.

	Frozen on purpose: the live sections are the ones the library reads every
	frame, and handing them out would let a caller edit the library's state
	through what reads like a getter.
]]
function Config.snapshot(): { [string]: { [string]: any } }
	local result: { [string]: { [string]: any } } = {}
	for name in SCHEMA do
		-- Copied by hand rather than with table.clone, which would bring the
		-- section's guard metatable along: a snapshot is something a caller
		-- reads and prints, so an unknown key there should come back nil, not
		-- raise the way it does on a live section. The metatable is protected,
		-- so it could not be stripped off a clone afterwards either.
		-- selene: allow(manual_table_clone)
		local copy = {}
		for key, value in sections[name] do
			copy[key] = value
		end
		result[name] = table.freeze(copy)
	end
	return table.freeze(result)
end

--- Splits `"Section.Field"`, raising if it does not name a real setting.
local function splitPath(path: string, level: number): (string, string)
	local sectionName, key = string.match(path, "^([%w_]+)%.([%w_]+)$")
	if sectionName == nil then
		Errors.raise(
			SOURCE,
			Errors.Codes.InvalidArgument,
			`'{path}' is not a Section.Field path`,
			level
		)
	end

	local section = SCHEMA[sectionName :: string]
	if section == nil or section.Fields[key :: string] == nil then
		Errors.raise(SOURCE, Errors.Codes.InvalidArgument, `'{path}' is not a setting`, level)
	end

	return sectionName :: string, key :: string
end

--- One value, by `"Section.Field"`. For scripts and command bars.
function Config.get(path: string): any
	local sectionName, key = splitPath(path, 3)
	return stores[sectionName][key]
end

export type FieldInfo = {
	Section: string,
	Field: string,
	Value: any,
	Default: any,
	Kind: Kind,
	Min: number?,
	Max: number?,
	Doc: string,
}

--[[
	The whole schema as data: current value, default, range and description.

	This is what a settings UI, a documentation generator or a `/config` admin
	command reads. It is also the answer to "what can I even change?" without
	opening the source.
]]
function Config.describe(): { FieldInfo }
	local rows: { FieldInfo } = {}
	for sectionName, section in SCHEMA do
		for key, field in section.Fields do
			table.insert(rows, {
				Section = sectionName,
				Field = key,
				Value = stores[sectionName][key],
				Default = field.Default,
				Kind = field.Kind,
				Min = field.Min,
				Max = field.Max,
				Doc = field.Doc,
			})
		end
	end
	table.sort(rows, function(a: FieldInfo, b: FieldInfo)
		if a.Section ~= b.Section then
			return a.Section < b.Section
		end
		return a.Field < b.Field
	end)
	return rows
end

--- Prints every setting that differs from its shipped default, or says none do.
function Config.printChanges()
	local lines = {}
	for _, row in Config.describe() do
		if row.Value ~= row.Default then
			table.insert(
				lines,
				string.format(
					"  %s.%s = %s   (default %s)",
					row.Section,
					row.Field,
					tostring(row.Value),
					tostring(row.Default)
				)
			)
		end
	end

	if #lines == 0 then
		print("VirtualHit config: all defaults")
		return
	end

	table.insert(lines, 1, `VirtualHit config: {#lines} setting(s) changed`)
	print(table.concat(lines, "\n"))
end

--- One value, by path. The single-setting twin of configure, for command bars.
function Config.set(path: string, value: any)
	local sectionName, key = splitPath(path, 3)
	Config.configure({ [sectionName] = { [key] = value } })
end

-- Scoped overrides

export type ConfigScope = {
	--- Removes this scope. Safe to call twice; the second call does nothing.
	Release: (ConfigScope) -> (),
}

--[[
	A temporary override that can be handed back.

		local slowMotion = VirtualHit.Config.scoped({
			Sweep = { MaxLinearStep = 0.25 },
		})
		...
		slowMotion:Release()

	Scopes stack, and release order does not matter: the effective value is
	recomputed from the base plus whatever scopes are still open, so releasing
	an older scope cannot undo a newer one that touched the same field.

	`configure` during a scope changes the *base*, which is what the setting
	returns to once the scope is released — so a scope never swallows a
	permanent change made while it was open.
]]
function Config.scoped(overrides: any): ConfigScope
	local problems: { string } = {}
	local staged: { [string]: { [string]: any } } = {}
	collectPatch(overrides, staged, problems)

	local scope: Scope = { Overrides = staged, Released = false }

	if #problems == 0 then
		-- Cross-field rules see the state this scope would produce, not the
		-- keys it happens to name.
		local candidate = table.clone(activeScopes)
		table.insert(candidate, scope)
		local preview = effectiveState(candidate)

		for sectionName, section in SCHEMA do
			local check = section.Check
			if check ~= nil then
				local problem = check(preview[sectionName])
				if problem ~= nil then
					table.insert(problems, `{sectionName}: {problem}`)
				end
			end
		end
	end

	if #problems > 0 then
		table.sort(problems)
		Errors.raise(
			SOURCE,
			Errors.Codes.InvalidArgument,
			`scoped was given {#problems} invalid setting(s):\n  ` .. table.concat(problems, "\n  "),
			2
		)
	end

	table.insert(activeScopes, scope)
	recompute()

	local handle = {}
	function handle.Release()
		if scope.Released then
			return
		end
		scope.Released = true
		local index = table.find(activeScopes, scope)
		if index ~= nil then
			table.remove(activeScopes, index)
		end
		recompute()
	end

	return (handle :: any) :: ConfigScope
end

--- How many scopes are currently open. For leak hunting in tests.
function Config.scopeCount(): number
	return #activeScopes
end

-- Export

local function literalOf(value: any): string
	if typeof(value) == "Color3" then
		return string.format(
			"Color3.fromRGB(%d, %d, %d)",
			math.round(value.R * 255),
			math.round(value.G * 255),
			math.round(value.B * 255)
		)
	end
	if type(value) == "string" then
		return string.format("%q", value)
	end
	if type(value) == "number" and value % 1 ~= 0 then
		-- %.17g round-trips a double exactly, which matters for an angle that
		-- came from math.rad and has to come back as the same number.
		return string.format("%.17g", value)
	end
	return tostring(value)
end

--[[
	The current configuration as a `configure` call you can paste.

	Only what differs from the shipped defaults, so the output stays the size
	of the decisions actually made rather than the size of the schema.
]]
function Config.toSource(): string
	local bySection: { [string]: { string } } = {}
	local names: { string } = {}

	for _, row in Config.describe() do
		if row.Value == row.Default then
			continue
		end
		local lines = bySection[row.Section]
		if lines == nil then
			lines = {}
			bySection[row.Section] = lines
			table.insert(names, row.Section)
		end
		table.insert(lines, `\t\t{row.Field} = {literalOf(row.Value)},`)
	end

	if #names == 0 then
		return "VirtualHit.configure({})"
	end

	table.sort(names)
	local out = { "VirtualHit.configure({" }
	for _, sectionName in names do
		table.insert(out, "\t" .. sectionName .. " = {")
		for _, line in bySection[sectionName] do
			table.insert(out, line)
		end
		table.insert(out, "\t},")
	end
	table.insert(out, "})")

	return table.concat(out, "\n")
end

-- Studio attributes

--- Attribute names cannot contain a dot, so the separator is an underscore.
local ATTRIBUTE_PATTERN = "^([%a_][%w_]*)_([%a_][%w_]*)$"

export type AttributeBinding = {
	--- Stops watching. Settings keep whatever the last successful read left.
	Disconnect: (AttributeBinding) -> (),
}

--[[
	Drives the configuration from attributes on an Instance.

	A designer sets `Sweep_MaxSegments` on a Configuration object in Studio and
	the library picks it up, with no code change and no rebuild. Attribute
	names are `Section_Field`, because attribute names cannot contain a dot.

	Unlike `configure`, this applies what it can and warns about the rest. One
	mistyped attribute in Studio should not switch off every other tuning on
	the same object, and the person who made the mistake is looking at the
	output window rather than catching an error.
]]
function Config.bindToInstance(instance: Instance): AttributeBinding
	if typeof(instance) ~= "Instance" then
		Errors.raise(
			SOURCE,
			Errors.Codes.InvalidArgument,
			`bindToInstance expects an Instance, got {typeName(instance)}`,
			2
		)
	end

	local function readAll()
		local patch: { [string]: { [string]: any } } = {}
		local rejected: { string } = {}

		for name, value in instance:GetAttributes() do
			local sectionName, key = string.match(name, ATTRIBUTE_PATTERN)
			if sectionName == nil then
				table.insert(rejected, `{name} is not a Section_Field name`)
				continue
			end

			local section = SCHEMA[sectionName :: string]
			if section == nil then
				table.insert(rejected, `{name}: no section '{sectionName}'`)
				continue
			end
			local field = section.Fields[key :: string]
			if field == nil then
				table.insert(rejected, `{name}: {sectionName} has no '{key}'`)
				continue
			end

			local problem = checkField(field, value)
			if problem ~= nil then
				table.insert(rejected, `{name} {problem}`)
				continue
			end

			local target = patch[sectionName :: string]
			if target == nil then
				target = {}
				patch[sectionName :: string] = target
			end
			target[key :: string] = value
		end

		-- Defaults first, so removing an attribute puts its setting back
		-- rather than leaving the last value it ever had.
		local ok, err = pcall(function()
			apply({ patch }, true)
		end)
		if not ok then
			table.insert(rejected, tostring(err))
		end

		if #rejected > 0 then
			table.sort(rejected)
			warn(
				`[{SOURCE}] {instance:GetFullName()}: {#rejected} attribute(s) ignored:\n  `
					.. table.concat(rejected, "\n  ")
			)
		end
	end

	readAll()
	local connection = instance.AttributeChanged:Connect(readAll)

	local handle = {}
	function handle.Disconnect()
		connection:Disconnect()
	end

	return (handle :: any) :: AttributeBinding
end

--- Names of the available presets, sorted.
function Config.presets(): { string }
	local names = {}
	for name in PRESETS do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

--[[
	Deep, because `table.freeze` is not.

	A shallow freeze on PRESETS leaves `Config.Presets.Performance.Sweep` a
	live table, so one caller could rewrite a preset for everyone who applies
	it afterwards.
]]
local function deepFreeze(value: any): any
	if type(value) ~= "table" or table.isfrozen(value) then
		return value
	end
	for _, nested in value do
		deepFreeze(nested)
	end
	return table.freeze(value)
end

Config.Presets = deepFreeze(PRESETS)

-- Self-check

--[[
	The schema has to satisfy its own rules.

	A default typed outside its own Min/Max, or a set of defaults that fails
	the section's own cross-field rule, would sit there working until the first
	caller touched a neighbouring field and got an error about a value they
	never set. Cheaper to fail here, at require time, with the field named.
]]
do
	local problems: { string } = {}

	for sectionName, section in SCHEMA do
		if #section.Doc == 0 then
			table.insert(problems, `{sectionName} has no Doc`)
		end
		for key, field in section.Fields do
			local problem = checkField(field, field.Default)
			if problem ~= nil then
				table.insert(problems, `{sectionName}.{key} default {problem}`)
			end
			if #field.Doc == 0 then
				table.insert(problems, `{sectionName}.{key} has no Doc`)
			end
			if field.Min ~= nil and field.Max ~= nil and field.Min > field.Max then
				table.insert(problems, `{sectionName}.{key} has Min above Max`)
			end
		end

		local check = section.Check
		if check ~= nil then
			local defaults = {}
			for key, field in section.Fields do
				defaults[key] = field.Default
			end
			local problem = check(defaults)
			if problem ~= nil then
				table.insert(problems, `{sectionName} defaults fail its own rule: {problem}`)
			end
		end
	end

	-- Presets are patches like any other, so they must name real settings.
	for presetName, preset in PRESETS do
		for sectionName, incoming in preset do
			local section = SCHEMA[sectionName]
			if section == nil then
				table.insert(problems, `preset {presetName} names unknown section {sectionName}`)
				continue
			end
			for key, value in incoming do
				local field = section.Fields[key]
				if field == nil then
					table.insert(problems, `preset {presetName} names unknown {sectionName}.{key}`)
					continue
				end
				local problem = checkField(field, value)
				if problem ~= nil then
					table.insert(problems, `preset {presetName}: {sectionName}.{key} {problem}`)
				end
			end
		end
	end

	if #problems > 0 then
		table.sort(problems)
		error(
			`{SOURCE}: the schema is inconsistent with itself:\n  `
				.. table.concat(problems, "\n  "),
			0
		)
	end
end

--[[
	Frozen last.

	The sections defend their own keys, but nothing stopped
	`Config.Pierce = {}` from replacing a guarded section wholesale, or
	`Config.configure = ...` from replacing the validator. Freezing the table
	itself closes both; the sections stay mutable through rawset, which is how
	`apply` writes them.
]]
return table.freeze(Config)
