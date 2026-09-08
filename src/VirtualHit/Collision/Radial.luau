--!strict

local Workspace = game:GetService("Workspace")

local Types = require(script.Parent.Parent.Types)
local FilterClass = require(script.Parent.Filter)
local InternalExclusions = require(script.Parent.InternalExclusions)
local Ordering = require(script.Parent.Ordering)
local Overlap = require(script.Parent.Overlap)
local Params = require(script.Parent.Params)
local Resolver = require(script.Parent.Resolver)
local Errors = require(script.Parent.Parent.Util.Errors)
local Config = require(script.Parent.Parent.Config)

-- Live config sections. Read through them so VirtualHit.configure()
-- takes effect without reloading the library.
local Limits = Config.Limits

local Radial = {}

-- The occlusion description a radial with no Occlusion filter carries. Never
-- mutated: the exclusion path clones before touching anything.
local DEFAULT_OCCLUSION_PARAMS = RaycastParams.new()

export type RadialOptions = {
	Origin: Types.CastOrigin,
	Radius: number,
	-- Selects which parts are candidates. Typically an include list of damageable
	-- characters, which is exactly why it must not also decide occlusion.
	Filter: FilterClass.Filter?,
	Params: OverlapParams?,
	-- Selects what can block sight. Left unset, everything blocks, which is the
	-- right default for an explosion: a wall the candidate filter ignores still
	-- has to stop the blast.
	Occlusion: FilterClass.Filter?,
	OcclusionParams: RaycastParams?,
	WorldRoot: WorldRoot?,
	EntityResolver: Types.EntityResolver?,
	ZoneResolver: Types.ZoneResolver?,
	LineOfSight: boolean?,
	IncludeOccluded: boolean?,
	Sort: boolean?,
	-- Bounds the line-of-sight phase. Candidates are checked nearest first, so
	-- reaching the bound drops the farthest ones and reports a truncation.
	MaxLineOfSightChecks: number?,
}

export type RadialStats = {
	OverlapQueries: number,
	Raycasts: number,
	Candidates: number,
	Visible: number,
	Occluded: number,
	Dropped: number,
	Truncated: boolean,
	TimeMs: number,
}

export type RadialTruncation = {
	Truncated: true,
	Reason: "MaxLineOfSightChecks",
	Certain: true,
	Required: number,
	Allowed: number,
}

type Candidate = {
	Instance: BasePart,
	Entity: Instance?,
	Zone: string?,
	Distance: number,
	Point: Vector3,
	TieMetadata: Ordering.TieMetadata?,
}

local function fail(message: string, code: string?): never
	return Errors.raise("VirtualHit.radial", code or "InvalidArgument", message, 3)
end

-- `table.freeze` returns a read-only view of its argument. That is the truth
-- about the value the caller gets, but not about the record the query filled in
-- field by field on the way here, whose type has to stay writable. This freezes
-- at runtime and hands the declared type back: the same table either way, with
-- one cast in one place instead of one at every return.
local function frozen<T>(value: T): T
	return (table.freeze(value :: any) :: any) :: T
end

local function isFiniteNumber(value: number): boolean
	return value == value and value > -math.huge and value < math.huge
end

local function isFiniteVector3(value: Vector3): boolean
	return isFiniteNumber(value.X) and isFiniteNumber(value.Y) and isFiniteNumber(value.Z)
end

local function resolveWorldRoot(worldRoot: WorldRoot?): WorldRoot
	if worldRoot == nil then
		return Workspace
	end

	if typeof(worldRoot) ~= "Instance" or not worldRoot:IsA("WorldRoot") then
		fail("options.WorldRoot must be a Workspace or WorldModel")
	end

	return worldRoot :: WorldRoot
end

local function originPosition(origin: Types.CastOrigin): Vector3
	if typeof(origin) == "Vector3" then
		if not isFiniteVector3(origin) then
			fail("options.Origin must contain only finite values")
		end

		return origin
	elseif typeof(origin) == "CFrame" then
		local position = (origin :: CFrame).Position

		if not isFiniteVector3(position) then
			fail("options.Origin must contain only finite values")
		end

		return position
	end

	return fail("options.Origin must be a Vector3 or CFrame")
end

local function resolveOcclusionParams(options: RadialOptions): RaycastParams
	if options.Occlusion ~= nil and options.OcclusionParams ~= nil then
		fail("options.Occlusion and options.OcclusionParams are mutually exclusive")
	end

	if options.OcclusionParams ~= nil then
		if typeof(options.OcclusionParams) ~= "RaycastParams" then
			fail("options.OcclusionParams must be a RaycastParams")
		end

		return Params.cloneRaycast(options.OcclusionParams)
	end

	if options.Occlusion ~= nil then
		if type((options.Occlusion :: any)._leaseRaycastParams) ~= "function" then
			fail("options.Occlusion must be created with VirtualHit.Filter.new()")
		end

		local params = options.Occlusion:_leaseRaycastParams()

		if typeof(params) ~= "RaycastParams" then
			fail("options.Occlusion must produce a RaycastParams")
		end

		return params
	end

	return DEFAULT_OCCLUSION_PARAMS
end

local function candidateOrder(left: Candidate, right: Candidate): boolean
	local comparison = Ordering.number(left.Distance, right.Distance)

	if comparison ~= nil then
		return comparison
	end

	if left == right then
		return false
	end

	local leftMetadata = left.TieMetadata
	local rightMetadata = right.TieMetadata
	assert(leftMetadata ~= nil, "left tied candidate is missing tie metadata")
	assert(rightMetadata ~= nil, "right tied candidate is missing tie metadata")

	return Ordering.metadata(leftMetadata, rightMetadata) == true
end

local function distanceOrder(left: Candidate, right: Candidate): boolean
	return Ordering.number(left.Distance, right.Distance) == true
end

local function sortCandidates(candidates: { Candidate })
	if #candidates < 2 then
		return
	end

	table.sort(candidates, distanceOrder)
	local runStart = 1
	local hasTie = false

	while runStart <= #candidates do
		local runEnd = runStart + 1

		while
			runEnd <= #candidates
			and candidates[runStart].Distance == candidates[runEnd].Distance
		do
			runEnd += 1
		end

		if runEnd - runStart > 1 then
			hasTie = true

			for index = runStart, runEnd - 1 do
				local candidate = candidates[index]

				if candidate.TieMetadata == nil then
					candidate.TieMetadata = Ordering.snapshot(candidate.Instance)
				end
			end
		end

		runStart = runEnd
	end

	if hasTie then
		table.sort(candidates, candidateOrder)
	end
end

function Radial.perform(
	options: RadialOptions
): ({ Types.RadialHit }, RadialStats, RadialTruncation?)
	if type(options) ~= "table" then
		fail("expected an options table")
	end

	local startedAt = os.clock()
	local origin = originPosition(options.Origin)
	local radius = options.Radius

	if type(radius) ~= "number" or not isFiniteNumber(radius) then
		fail("options.Radius must be a finite number")
	end

	if radius < (Limits.MinPhysicalAxis * 0.5) or radius > Limits.MaxSphereRadius then
		fail(
			`options.Radius must be at least {(Limits.MinPhysicalAxis * 0.5)} and at most {Limits.MaxSphereRadius}`
		)
	end

	local lineOfSight = options.LineOfSight ~= false
	local includeOccluded = options.IncludeOccluded ~= false
	local sort = options.Sort ~= false
	local maxChecks = options.MaxLineOfSightChecks

	if maxChecks ~= nil then
		if
			type(maxChecks) ~= "number"
			or not isFiniteNumber(maxChecks)
			or maxChecks < 0
			or maxChecks % 1 ~= 0
		then
			fail("options.MaxLineOfSightChecks must be a non-negative integer")
		end
	end

	local worldRoot = resolveWorldRoot(options.WorldRoot)
	local stats: RadialStats = {
		OverlapQueries = 0,
		Raycasts = 0,
		Candidates = 0,
		Visible = 0,
		Occluded = 0,
		Dropped = 0,
		Truncated = false,
		TimeMs = 0,
	}

	stats.OverlapQueries = 1
	local sphere: Types.SphereShape = {
		Type = "Sphere",
		Radius = radius,
	}
	local overlapHits = Overlap.perform({
		Origin = origin,
		Shape = sphere,
		Filter = options.Filter,
		Params = options.Params,
		WorldRoot = worldRoot,
		EntityResolver = options.EntityResolver,
		ZoneResolver = options.ZoneResolver,
	})

	local candidates: { Candidate } = {}

	for _, hit in overlapHits do
		local part = hit.Instance
		-- Distance is measured to the nearest surface point, not to the part
		-- origin, so a long wall segment is not judged by where its centre sits.
		local point = if part:IsA("Terrain") then origin else part:GetClosestPointOnSurface(origin)

		table.insert(candidates, {
			Instance = part,
			Entity = hit.Entity,
			Zone = hit.Zone,
			Distance = (point - origin).Magnitude,
			Point = point,
			TieMetadata = nil,
		})
	end

	stats.Candidates = #candidates

	-- Sorting before the sight phase is what lets a bounded check budget drop
	-- the farthest candidates instead of an arbitrary subset.
	if sort or (lineOfSight and maxChecks ~= nil) then
		sortCandidates(candidates)
	end

	local hits: { Types.RadialHit } = {}
	local truncation: RadialTruncation? = nil

	if not lineOfSight then
		for _, candidate in candidates do
			stats.Visible += 1
			table.insert(hits, {
				Instance = candidate.Instance,
				Entity = candidate.Entity,
				Zone = candidate.Zone,
				Distance = candidate.Distance,
				Point = candidate.Point,
				Occluded = false,
				Blocker = nil,
			})
		end

		stats.TimeMs = (os.clock() - startedAt) * 1_000
		return hits, frozen(stats), nil
	end

	local occlusionParams = resolveOcclusionParams(options)
	local exclusions, exclusionCount =
		InternalExclusions.Acquire(worldRoot, occlusionParams.BruteForceAllSlow)
	-- One params object for every line-of-sight ray in this call, and no rebuild
	-- at all when there are no probes to keep out.
	local sightParams = if exclusionCount == 0
		then occlusionParams
		else Params.withRaycastExclusions(occlusionParams, exclusions)
	InternalExclusions.Release(exclusions)
	local checks = 0

	for index, candidate in candidates do
		if maxChecks ~= nil and checks >= maxChecks then
			stats.Dropped = #candidates - index + 1
			stats.Truncated = true
			-- Annotated on the literal so the singleton fields keep their exact
			-- types; a cast after table.freeze would widen them to boolean.
			local record: RadialTruncation = {
				Truncated = true,
				Reason = "MaxLineOfSightChecks",
				Certain = true,
				Required = #candidates,
				Allowed = maxChecks,
			}
			truncation = frozen(record)
			break
		end

		checks += 1
		stats.Raycasts += 1
		local vector = candidate.Point - origin
		local result: RaycastResult? = nil

		-- A candidate whose surface point is the origin itself has nothing to
		-- occlude: the query started inside it.
		if vector.Magnitude > 1e-4 then
			result = worldRoot:Raycast(origin, vector, sightParams)
		end

		local occluded = false
		local blocker: BasePart? = nil

		if result ~= nil and result.Instance ~= candidate.Instance then
			-- Another part of the same entity is not an occluder. A character
			-- must not shadow itself out of its own explosion.
			local blockerEntity = Resolver.resolve(result.Instance, options.EntityResolver)

			if candidate.Entity == nil or blockerEntity ~= candidate.Entity then
				occluded = true
				blocker = result.Instance
			end
		end

		if occluded then
			stats.Occluded += 1
		else
			stats.Visible += 1
		end

		if includeOccluded or not occluded then
			table.insert(hits, {
				Instance = candidate.Instance,
				Entity = candidate.Entity,
				Zone = candidate.Zone,
				Distance = candidate.Distance,
				Point = candidate.Point,
				Occluded = occluded,
				Blocker = blocker,
			})
		end
	end

	stats.TimeMs = (os.clock() - startedAt) * 1_000
	return hits, frozen(stats), truncation
end

return Radial
