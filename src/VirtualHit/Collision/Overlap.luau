--!strict

local Workspace = game:GetService("Workspace")

local Types = require(script.Parent.Parent.Types)
local FilterClass = require(script.Parent.Filter)
local InternalExclusions = require(script.Parent.InternalExclusions)
local Ordering = require(script.Parent.Ordering)
local Params = require(script.Parent.Params)
local Resolver = require(script.Parent.Resolver)
local ShapeProbe = require(script.Parent.ShapeProbe)
local Errors = require(script.Parent.Parent.Util.Errors)
local Config = require(script.Parent.Parent.Config)

-- Live config sections. Read through them so VirtualHit.configure()
-- takes effect without reloading the library.
local Limits = Config.Limits

local Overlap = {}

-- The description a query with no Filter and no Params carries. Read-only by
-- construction: every path that needs to add exclusions clones first.
local DEFAULT_OVERLAP_PARAMS = OverlapParams.new()

export type OverlapSort = "None" | "Distance"

export type OverlapOptions = {
	Origin: Types.CastOrigin,
	Shape: Types.OverlapShape,
	Filter: FilterClass.Filter?,
	Params: OverlapParams?,
	WorldRoot: WorldRoot?,
	EntityResolver: Types.EntityResolver?,
	ZoneResolver: Types.ZoneResolver?,
	Sort: OverlapSort?,
}

type Candidate = {
	Instance: BasePart,
	SurfaceDistance: number,
	TieMetadata: Ordering.TieMetadata?,
}

local function fail(message: string, code: string?): never
	return Errors.raise("VirtualHit.overlap", code or "InvalidArgument", message, 4)
end

local function isFiniteNumber(value: number): boolean
	return value == value and value > -math.huge and value < math.huge
end

local function isFiniteVector3(value: Vector3): boolean
	return isFiniteNumber(value.X) and isFiniteNumber(value.Y) and isFiniteNumber(value.Z)
end

-- Reads the twelve components into locals rather than packing them into a
-- table. The table was the only allocation on Step's validation path, and Step
-- is the hot one: two per call, per sweep, per frame.
local function isFiniteCFrame(value: CFrame): boolean
	local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = value:GetComponents()

	return isFiniteNumber(x)
		and isFiniteNumber(y)
		and isFiniteNumber(z)
		and isFiniteNumber(r00)
		and isFiniteNumber(r01)
		and isFiniteNumber(r02)
		and isFiniteNumber(r10)
		and isFiniteNumber(r11)
		and isFiniteNumber(r12)
		and isFiniteNumber(r20)
		and isFiniteNumber(r21)
		and isFiniteNumber(r22)
end

local function validateOrigin(origin: Types.CastOrigin): (Vector3, CFrame?)
	if typeof(origin) == "Vector3" then
		if not isFiniteVector3(origin) then
			fail("options.Origin must contain only finite values")
		end

		return origin, nil
	elseif typeof(origin) == "CFrame" then
		if not isFiniteCFrame(origin) then
			fail("options.Origin must contain only finite values")
		end

		return origin.Position, origin
	end

	error("VirtualHit.overlap: options.Origin must be a Vector3 or CFrame", 4)
end

local function validatePrimitive(shape: Types.PrimitiveShape, label: string)
	if shape.Type == "Sphere" then
		if
			type(shape.Radius) ~= "number"
			or not isFiniteNumber(shape.Radius)
			or shape.Radius < (Limits.MinPhysicalAxis * 0.5)
			or shape.Radius > Limits.MaxSphereRadius
		then
			fail(
				`{label}Sphere Radius must be at least {(Limits.MinPhysicalAxis * 0.5)} and at most {Limits.MaxSphereRadius}`
			)
		end
	elseif shape.Type == "Block" then
		local size = shape.Size

		if
			typeof(size) ~= "Vector3"
			or not isFiniteVector3(size)
			or size.X < Limits.MinPhysicalAxis
			or size.Y < Limits.MinPhysicalAxis
			or size.Z < Limits.MinPhysicalAxis
			or size.X > Limits.MaxBlockAxis
			or size.Y > Limits.MaxBlockAxis
			or size.Z > Limits.MaxBlockAxis
		then
			fail(
				`{label}Block axes must be at least {Limits.MinPhysicalAxis} and at most {Limits.MaxBlockAxis}`
			)
		end
	elseif shape.Type == "Part" then
		local part = shape.Part

		if typeof(part) ~= "Instance" or not part:IsA("BasePart") or part:IsA("Terrain") then
			fail(`{label}Part shape must contain a non-Terrain BasePart`)
		end

		if typeof(shape.Offset) ~= "CFrame" or not isFiniteCFrame(shape.Offset) then
			fail(`{label}Part shape Offset must be a finite CFrame`)
		end
	else
		fail(`unsupported overlap Shape type {tostring((shape :: any).Type)}`)
	end
end

local function validateShape(shape: Types.OverlapShape)
	if type(shape) ~= "table" then
		fail("options.Shape must come from VirtualHit.Shapes")
	end

	if shape.Type == "Compound" then
		local members = shape.Members

		if type(members) ~= "table" or #members == 0 then
			fail("Compound Shape must carry at least one member")
		end

		for index, member in members do
			if type(member) ~= "table" or typeof(member.Offset) ~= "CFrame" then
				fail(`Compound member {index} must carry a Shape and a CFrame Offset`)
			end

			validatePrimitive(member.Shape, `Compound member {index} `)
		end

		return
	end

	validatePrimitive(shape :: Types.PrimitiveShape, "")
end

-- Exposed so callers that build a long-lived query object (a Zone) can reject a
-- bad shape at construction instead of on the first poll, where the traceback
-- would point at the heartbeat rather than at the caller.
function Overlap.validateShape(shape: Types.OverlapShape)
	validateShape(shape)
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

local function resolveSort(sort: OverlapSort?): OverlapSort
	if sort == nil then
		return "None"
	end

	if sort ~= "None" and sort ~= "Distance" then
		fail("options.Sort must be None or Distance")
	end

	return sort
end

local function resolveParams(options: OverlapOptions): OverlapParams
	if options.Filter ~= nil and options.Params ~= nil then
		fail("options.Filter and options.Params are mutually exclusive")
	end

	if options.Params ~= nil then
		if typeof(options.Params) ~= "OverlapParams" then
			fail("options.Params must be an OverlapParams")
		end

		return options.Params
	end

	if options.Filter ~= nil then
		if type((options.Filter :: any)._leaseOverlapParams) ~= "function" then
			fail("options.Filter must be created with VirtualHit.Filter.new()")
		end

		local params = options.Filter:_leaseOverlapParams()

		if typeof(params) ~= "OverlapParams" then
			fail("options.Filter must produce an OverlapParams")
		end

		return params
	end

	-- Nothing here is ever mutated -- every path that adds exclusions clones
	-- first -- so a caller that asked for no filtering at all gets the same
	-- empty description back instead of a fresh engine object per query.
	return DEFAULT_OVERLAP_PARAMS
end

local function queryParts(
	worldRoot: WorldRoot,
	params: OverlapParams,
	probe: BasePart,
	sourcePart: BasePart?
): { BasePart }
	local exclusions, count = InternalExclusions.Acquire(worldRoot, params.BruteForceAllSlow)

	if sourcePart ~= nil then
		count += 1
		table.insert(exclusions, sourcePart)
	end

	-- Nothing to keep out means the caller's params go straight to the engine:
	-- no clone, no engine object, nothing for the collector to sweep up later.
	local queryParams = if count == 0
		then params
		else Params.withOverlapExclusions(params, exclusions)
	InternalExclusions.Release(exclusions)

	return worldRoot:GetPartsInPart(probe, queryParams)
end

local function queryPrimitive(
	shape: Types.PrimitiveShape,
	worldRoot: WorldRoot,
	params: OverlapParams,
	origin: Vector3,
	originCFrame: CFrame?,
	rawOrigin: Types.CastOrigin
): { BasePart }
	if shape.Type == "Sphere" then
		return ShapeProbe.withSphere(worldRoot, origin, shape.Radius, function(probe)
			return queryParts(worldRoot, params, probe, nil)
		end)
	elseif shape.Type == "Block" then
		local cframe = originCFrame or CFrame.new(origin)
		return ShapeProbe.withBlock(worldRoot, cframe, shape.Size, function(probe)
			return queryParts(worldRoot, params, probe, nil)
		end)
	end

	local cframe = ShapeProbe.cframeForOrigin(shape.Part, rawOrigin, shape.Offset)
	local probe = ShapeProbe.create(shape.Part, worldRoot, cframe)
	local success, result = pcall(function()
		return queryParts(worldRoot, params, probe, shape.Part)
	end)
	probe:Destroy()

	if not success then
		error(result, 0)
	end

	return result :: { BasePart }
end

local function candidateOrder(left: Candidate, right: Candidate): boolean
	local comparison = Ordering.number(left.SurfaceDistance, right.SurfaceDistance)

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
	return Ordering.number(left.SurfaceDistance, right.SurfaceDistance) == true
end

-- Ties are resolved on a metadata snapshot taken before any sort runs, so the
-- comparator can never read geometry that moved between comparisons. Snapshots
-- are only taken for candidates that actually tie.
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
			and candidates[runStart].SurfaceDistance == candidates[runEnd].SurfaceDistance
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

function Overlap.perform(options: OverlapOptions): { Types.OverlapHit }
	if type(options) ~= "table" then
		fail("expected an options table")
	end

	local origin, originCFrame = validateOrigin(options.Origin)
	local shape = options.Shape
	validateShape(shape)

	if options.EntityResolver ~= nil and type(options.EntityResolver) ~= "function" then
		fail("options.EntityResolver must be a function")
	end

	if options.ZoneResolver ~= nil and type(options.ZoneResolver) ~= "function" then
		fail("options.ZoneResolver must be a function")
	end

	local sort = resolveSort(options.Sort)
	local worldRoot = resolveWorldRoot(options.WorldRoot)
	local params = resolveParams(options)
	local filter = options.Filter
	local predicate: Types.Predicate? = nil

	if filter ~= nil then
		predicate = filter:GetPredicate()
	end

	local candidates: { Candidate } = {}
	local seen: { [BasePart]: boolean } = {}

	local function collect(parts: { BasePart })
		-- Copied into a local so the nil check refines it. Luau does not carry
		-- a refinement across an upvalue read inside a closure.
		local check = predicate

		for _, part in parts do
			if not seen[part] then
				seen[part] = true

				if check ~= nil then
					local accepted = check(part)

					if type(accepted) ~= "boolean" then
						fail("Filter predicate must return a boolean", "CallbackContract")
					end

					if not accepted then
						continue
					end
				end

				local surfaceDistance = 0

				if sort == "Distance" and not part:IsA("Terrain") then
					surfaceDistance = (part:GetClosestPointOnSurface(origin) - origin).Magnitude
				end

				table.insert(candidates, {
					Instance = part,
					SurfaceDistance = surfaceDistance,
					TieMetadata = nil,
				})
			end
		end
	end

	if shape.Type == "Compound" then
		-- Members share one dedup set, so a part straddling two members is
		-- reported once. The compound is a union, not a list of queries.
		local rootCFrame = originCFrame or CFrame.new(origin)

		for _, member in shape.Members do
			local memberCFrame = rootCFrame * member.Offset
			collect(
				queryPrimitive(
					member.Shape,
					worldRoot,
					params,
					memberCFrame.Position,
					memberCFrame,
					memberCFrame
				)
			)
		end
	else
		collect(
			queryPrimitive(
				shape :: Types.PrimitiveShape,
				worldRoot,
				params,
				origin,
				originCFrame,
				options.Origin
			)
		)
	end

	if sort == "Distance" then
		sortCandidates(candidates)
	end

	local hits: { Types.OverlapHit } = {}

	for _, candidate in candidates do
		table.insert(hits, {
			Instance = candidate.Instance,
			Entity = Resolver.resolve(candidate.Instance, options.EntityResolver),
			Zone = Resolver.resolveZone(candidate.Instance, options.ZoneResolver),
		})
	end

	return hits
end

return Overlap
