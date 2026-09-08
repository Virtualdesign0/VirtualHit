--!strict

local Workspace = game:GetService("Workspace")

local Types = require(script.Parent.Parent.Types)
local FilterClass = require(script.Parent.Parent.Collision.Filter)
local InternalExclusions = require(script.Parent.Parent.Collision.InternalExclusions)
local Params = require(script.Parent.Parent.Collision.Params)
local Resolver = require(script.Parent.Parent.Collision.Resolver)
local ShapeProbe = require(script.Parent.Parent.Collision.ShapeProbe)
local HitPolicy = require(script.Parent.HitPolicy)
local HitRegistryClass = require(script.Parent.HitRegistry)
local TruncationReason = require(script.Parent.TruncationReason)
local DetailFieldClass = require(script.Parent.Parent.Detail.DetailField)
local Errors = require(script.Parent.Parent.Util.Errors)
local TruncationModule = require(script.Parent.Truncation)
local CandidateModule = require(script.Parent.Candidate)
local CandidateOrdering = require(script.Parent.CandidateOrdering)
local Config = require(script.Parent.Parent.Config)

-- Live config sections. Read through them so VirtualHit.configure()
-- takes effect without reloading the library.
local Tuning = Config.Sweep
local Limits = Config.Limits

local MIN_TRANSLATION = 1e-6
local ANGULAR_SEGMENT_RATIO_TOLERANCE = 1e-6

local Sweep = {}
Sweep.__index = Sweep

export type SweepConfig = {
	MaxLinearStep: number?,
	MaxAngularStep: number?,
	MaxSegments: number?,
	MaxHitsPerSegment: number?,
}

export type HitResponder = (candidate: Types.SweepCandidate) -> Types.HitResponse
export type HitPriority = (candidate: Types.SweepCandidate) -> number
export type HitKey = (candidate: Types.SweepCandidate) -> any
export type HitRegistry = HitRegistryClass.HitRegistry

export type TruncationReason = TruncationReason.Value

export type MaxSegmentsTruncation = {
	Truncated: true,
	Reason: "MaxSegments",
	Certain: true,
	Required: number,
	Allowed: number,
}

export type MaxHitsPerSegmentTruncation = {
	Truncated: true,
	Reason: "MaxHitsPerSegment",
	Certain: true,
	RequiredAtLeast: number,
	Allowed: number,
	Segment: number,
}

export type MaxPartsTruncation = {
	Truncated: true,
	Reason: "MaxParts",
	Certain: false,
	Observed: number,
	Allowed: number,
	Sample: number,
}

export type EngineShapecastLimitTruncation = {
	Truncated: true,
	Reason: "EngineShapecastLimit",
	Certain: true,
	Required: number,
	Allowed: number,
	Limit: number,
}

export type SweepTruncation =
	MaxSegmentsTruncation
	| MaxHitsPerSegmentTruncation
	| MaxPartsTruncation
	| EngineShapecastLimitTruncation

export type SweepStats = {
	Succeeded: boolean,
	Error: string?,
	Segments: number,
	RequiredSegments: number,
	-- What the detail field scaled the step limits by for this Step. One means
	-- full resolution, either because nothing is configured or because somebody
	-- is standing close enough to deserve it.
	DetailScale: number,
	OverlapQueries: number,
	ShapeCasts: number,
	RawCandidates: number,
	UniqueCandidates: number,
	TieBreakCandidates: number,
	Hits: number,
	Ignored: number,
	PolicyRejected: number,
	Blocked: number,
	Occluded: number,
	-- How the query params for this Step were obtained. Reused means the cache
	-- was warm; rebuilt means a Filter mutation or an internal exclusion change
	-- invalidated it, or the filter is tag-driven and never cacheable.
	ParamsRebuilt: number,
	ParamsReused: number,
	Distance: number,
	EstimatedTravel: number,
	AngularTravel: number,
	Truncated: boolean,
	TimeMs: number,
}

export type SweepOptions = {
	Shape: Types.SweepShape,
	Offset: CFrame?,
	Filter: FilterClass.Filter?,
	RaycastParams: RaycastParams?,
	OverlapParams: OverlapParams?,
	WorldRoot: WorldRoot?,
	EntityResolver: Types.EntityResolver?,
	ZoneResolver: Types.ZoneResolver?,
	HitPolicy: HitPolicy.Policy?,
	HitKey: HitKey?,
	-- Sharing one registry makes several sweeps behave as a single hitbox for
	-- policy purposes: the blade, the tip, and the guard of one weapon cannot
	-- each land their own OncePerEntity hit on the same target.
	Registry: HitRegistry?,
	HitResponse: HitResponder?,
	HitPriority: HitPriority?,
	-- Runs the sweep without any query probe: no GetPartsInPart phase and
	-- native Spherecast/Blockcast instead of Shapecast. Nothing is written to
	-- the DataModel, which makes the sweep safe to run under parallel Luau.
	-- The cost is the initial-overlap guarantee: a target already intersecting
	-- the shape at the start of a Step is only found if the cast reaches it.
	ProbeFree: boolean?,
	MaxLinearStep: number?,
	MaxAngularStep: number?,
	MaxSegments: number?,
	MaxHitsPerSegment: number?,
	-- Scales the step limits by how far this sweep is from anyone watching. It
	-- buys back segments, never correctness: see VirtualHit.detail().
	Detail: DetailFieldClass.DetailField?,
}

type ParamsCache = {
	Raycast: RaycastParams,
	Overlap: OverlapParams,
	Predicate: Types.Predicate?,
	BaseExclusions: { Instance },
	-- The array handed back to the engine each Step. Kept and refilled rather
	-- than cloned: assigning to FilterDescendantsInstances copies into the
	-- engine, so the same table can be reused.
	Restore: { Instance },
	FilterVersion: number,
	ExclusionGeneration: number,
	InternalVersion: number,
}

type Member = {
	Index: number,
	Shape: Types.PrimitiveShape,
	IsSphere: boolean,
	RotationRadius: number,
	Offset: CFrame,
	-- True when Offset is the identity, which is the ordinary case: one member
	-- with no offset of its own. Multiplying by it allocates a CFrame per
	-- segment per Step that is equal to the pose it came from.
	OffsetIsIdentity: boolean,
	Probe: BasePart?,
}

export type Sweep = typeof(setmetatable(
	{} :: {
		_members: { Member },
		_probeFree: boolean,
		_partExclusions: { BasePart },
		_filter: FilterClass.Filter?,
		_raycastParams: RaycastParams?,
		_overlapParams: OverlapParams?,
		_worldRoot: WorldRoot,
		_entityResolver: Types.EntityResolver?,
		_zoneResolver: Types.ZoneResolver?,
		_hitResponder: HitResponder?,
		_hitPriority: HitPriority?,
		_registry: HitRegistryClass.HitRegistry,
		_ownsRegistry: boolean,
		_maxLinearStep: number,
		_maxAngularStep: number,
		_detail: DetailFieldClass.DetailField?,
		_detailLinear: number,
		_detailAngular: number,
		_detailAt: Vector3,
		_detailMargin: number,
		_detailGeneration: number,
		_detailAge: number,
		_maxSegments: number,
		_maxHitsPerSegment: number,
		_internalExclusions: { Instance },
		_internalVersion: number,
		_paramsCache: ParamsCache?,
		_scratch: Scratch,
		_lastSampleChains: { { CFrame } },
		_workingStats: MutableSweepStats,
		_lastStats: MutableSweepStats,
		_hasLastStats: boolean,
		_lastStatsSnapshot: SweepStats?,
		_truncation: TruncationModule.Tracker,
		_stepping: boolean,
		_destroyed: boolean,
		_teardownPending: boolean,
	},
	Sweep
))

type TieMetadata = CandidateModule.TieMetadata
type RawCandidate = CandidateModule.RawCandidate
type RankedCandidate = CandidateModule.RankedCandidate
type ExclusionState = CandidateModule.ExclusionState
type Scratch = CandidateModule.Scratch

type MutableSweepStats = SweepStats

local function fail(message: string, code: string?): never
	return Errors.raise("VirtualHit.sweep", code or "InvalidArgument", message, 3)
end

local function createStats(): MutableSweepStats
	return {
		Succeeded = false,
		Error = nil,
		Segments = 0,
		RequiredSegments = 0,
		DetailScale = 1,
		OverlapQueries = 0,
		ShapeCasts = 0,
		RawCandidates = 0,
		UniqueCandidates = 0,
		TieBreakCandidates = 0,
		Hits = 0,
		Ignored = 0,
		PolicyRejected = 0,
		Blocked = 0,
		Occluded = 0,
		ParamsRebuilt = 0,
		ParamsReused = 0,
		Distance = 0,
		EstimatedTravel = 0,
		AngularTravel = 0,
		Truncated = false,
		TimeMs = 0,
	}
end

local function resetStats(stats: MutableSweepStats)
	stats.Succeeded = false
	stats.Error = nil
	stats.Segments = 0
	stats.RequiredSegments = 0
	stats.DetailScale = 1
	stats.OverlapQueries = 0
	stats.ShapeCasts = 0
	stats.RawCandidates = 0
	stats.UniqueCandidates = 0
	stats.TieBreakCandidates = 0
	stats.Hits = 0
	stats.Ignored = 0
	stats.PolicyRejected = 0
	stats.Blocked = 0
	stats.Occluded = 0
	stats.ParamsRebuilt = 0
	stats.ParamsReused = 0
	stats.Distance = 0
	stats.EstimatedTravel = 0
	stats.AngularTravel = 0
	stats.Truncated = false
	stats.TimeMs = 0
end

local function copyStats(target: MutableSweepStats, source: MutableSweepStats)
	target.Succeeded = source.Succeeded
	target.Error = source.Error
	target.Segments = source.Segments
	target.RequiredSegments = source.RequiredSegments
	target.DetailScale = source.DetailScale
	target.OverlapQueries = source.OverlapQueries
	target.ShapeCasts = source.ShapeCasts
	target.RawCandidates = source.RawCandidates
	target.UniqueCandidates = source.UniqueCandidates
	target.TieBreakCandidates = source.TieBreakCandidates
	target.Hits = source.Hits
	target.Ignored = source.Ignored
	target.PolicyRejected = source.PolicyRejected
	target.Blocked = source.Blocked
	target.Occluded = source.Occluded
	target.ParamsRebuilt = source.ParamsRebuilt
	target.ParamsReused = source.ParamsReused
	target.Distance = source.Distance
	target.EstimatedTravel = source.EstimatedTravel
	target.AngularTravel = source.AngularTravel
	target.Truncated = source.Truncated
	target.TimeMs = source.TimeMs
end

local function isFiniteNumber(value: number): boolean
	return value == value and value > -math.huge and value < math.huge
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

local function isFiniteVector3(value: Vector3): boolean
	return isFiniteNumber(value.X) and isFiniteNumber(value.Y) and isFiniteNumber(value.Z)
end

local function positiveNumber(value: number?, defaultValue: number, name: string): number
	if value == nil then
		return defaultValue
	end

	if type(value) ~= "number" or not isFiniteNumber(value) or value <= 0 then
		fail(`options.{name} must be a finite number greater than zero`)
	end

	return value
end

local function positiveInteger(value: number?, defaultValue: number, name: string): number
	local result = positiveNumber(value, defaultValue, name)

	if result % 1 ~= 0 then
		fail(`options.{name} must be an integer`)
	end

	return result
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

local function validatePrimitive(shape: Types.PrimitiveShape, label: string)
	if shape.Type == "Sphere" then
		if
			type(shape.Radius) ~= "number"
			or not isFiniteNumber(shape.Radius)
			or shape.Radius < (Limits.MinPhysicalAxis * 0.5)
			or shape.Radius > Limits.MaxSphereRadius
		then
			fail(
				`options.Shape {label}Sphere radius must be at least {(Limits.MinPhysicalAxis * 0.5)} and at most {Limits.MaxSphereRadius}`
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
				`options.Shape {label}Block axes must be at least {Limits.MinPhysicalAxis} and at most {Limits.MaxBlockAxis}`
			)
		end
	elseif shape.Type == "Part" then
		if
			typeof(shape.Part) ~= "Instance"
			or not shape.Part:IsA("BasePart")
			or shape.Part:IsA("Terrain")
		then
			fail(`options.Shape {label}Part must be a non-Terrain BasePart`)
		end

		if typeof(shape.Offset) ~= "CFrame" or not isFiniteCFrame(shape.Offset) then
			fail(`options.Shape {label}Offset must be a finite CFrame`)
		end
	else
		fail(`options.Shape {label}must be Sphere, Block, or Part; Ray has no sweep volume`)
	end
end

local function validateShape(shape: Types.SweepShape)
	if type(shape) ~= "table" then
		fail("options.Shape must come from VirtualHit.Shapes and have volume")
	end

	if shape.Type == "Compound" then
		local members = shape.Members

		if type(members) ~= "table" or #members == 0 then
			fail("options.Shape Compound must carry at least one member")
		end

		for index, member in members do
			if type(member) ~= "table" or typeof(member.Offset) ~= "CFrame" then
				fail(`options.Shape Compound member {index} needs a Shape and a CFrame Offset`)
			end

			if not isFiniteCFrame(member.Offset) then
				fail(`options.Shape Compound member {index} Offset must be finite`)
			end

			validatePrimitive(member.Shape, `Compound member {index} `)
		end

		return
	end

	validatePrimitive(shape :: Types.PrimitiveShape, "")
end

-- Compared component by component: `cf == CFrame.identity` is a CFrame compare
-- and these are plain Vector3 reads, which cost nothing.
local function isIdentityCFrame(cf: CFrame): boolean
	return cf.Position == Vector3.zero
		and cf.XVector == Vector3.xAxis
		and cf.YVector == Vector3.yAxis
		and cf.ZVector == Vector3.zAxis
end

local function shapeOffset(shape: Types.PrimitiveShape): CFrame
	return if shape.Type == "Part" then shape.Offset else CFrame.identity
end

local function shapeRotationRadius(shape: Types.PrimitiveShape): number
	if shape.Type == "Sphere" then
		return 0
	elseif shape.Type == "Block" then
		return shape.Size.Magnitude * 0.5
	else
		local part = shape.Part
		local physicalCenterOffset = (part.ExtentsCFrame.Position - part.Position).Magnitude
		return physicalCenterOffset + part.ExtentsSize.Magnitude * 0.5
	end
end

-- Sphere and Block probes are leased from the shared pool and returned on
-- Destroy. Part probes are a clone of caller geometry, so they cannot be
-- shared and are created and destroyed outright.
local function createProbe(shape: Types.PrimitiveShape, worldRoot: WorldRoot): BasePart
	if shape.Type == "Sphere" then
		return ShapeProbe.acquireSphere(worldRoot, shape.Radius)
	elseif shape.Type == "Block" then
		return ShapeProbe.acquireBlock(worldRoot, shape.Size)
	else
		return ShapeProbe.create(shape.Part, worldRoot, shape.Part.CFrame)
	end
end

-- Flattens any sweep shape into the ordered primitive list the step loop walks.
-- A non-compound shape produces exactly one member, so the simple case keeps a
-- single probe and a single sample chain.
local function buildMembers(
	shape: Types.SweepShape,
	rootOffset: CFrame,
	worldRoot: WorldRoot,
	probeFree: boolean
): ({ Member }, { BasePart })
	local descriptors: { { Shape: Types.PrimitiveShape, Offset: CFrame } } = {}

	if shape.Type == "Compound" then
		for _, member in shape.Members do
			table.insert(descriptors, { Shape = member.Shape, Offset = member.Offset })
		end
	else
		table.insert(
			descriptors,
			{ Shape = shape :: Types.PrimitiveShape, Offset = CFrame.identity }
		)
	end

	local members: { Member } = {}
	local partExclusions: { BasePart } = {}

	for index, descriptor in descriptors do
		local primitive = descriptor.Shape
		local probe: BasePart? = nil

		if probeFree then
			-- Shapecast is the only cast that needs a probe part. Sphere and
			-- Block have native probe-free casts; Part geometry does not.
			if primitive.Type == "Part" then
				fail("ProbeFree sweeps support Sphere and Block shapes only", "ShapeUnsupported")
			end
		else
			local created, probeOrMessage = pcall(createProbe, primitive, worldRoot)

			if not created then
				-- Probes already parented into the WorldRoot must not outlive a
				-- failed construction, or they would leak queryable internal
				-- geometry for the rest of the session.
				for _, member in members do
					local existing = member.Probe

					if existing ~= nil then
						pcall(function()
							ShapeProbe.release(existing)
						end)
					end
				end

				error(probeOrMessage, 0)
			end

			probe = probeOrMessage :: BasePart

			if primitive.Type == "Part" then
				table.insert(partExclusions, primitive.Part)
			end
		end

		local offset = rootOffset * descriptor.Offset * shapeOffset(primitive)

		table.insert(members, {
			Index = index,
			Shape = primitive,
			IsSphere = primitive.Type == "Sphere",
			RotationRadius = shapeRotationRadius(primitive),
			Offset = offset,
			OffsetIsIdentity = isIdentityCFrame(offset),
			Probe = probe,
		})
	end

	return members, partExclusions
end

local function rotationAxisAngle(from: CFrame, to: CFrame): (Vector3, number)
	-- The ordinary sweep translates without turning, and finding that out the
	-- long way costs three CFrames every Step: one for each `.Rotation` and one
	-- for the object-space product, all to arrive at an angle of zero. The
	-- basis vectors are plain Vector3 reads and cost nothing. The axis is
	-- arbitrary at zero: every use of it downstream is multiplied by the angle.
	if from.XVector == to.XVector and from.YVector == to.YVector and from.ZVector == to.ZVector then
		return Vector3.yAxis, 0
	end

	local relative = from.Rotation:ToObjectSpace(to.Rotation)
	local axis, angle = relative:ToAxisAngle()
	return axis, math.abs(angle)
end

local function angularSegmentCount(angle: number, maxStep: number): number
	local ratio = angle / maxStep
	local nearestInteger = math.round(ratio)

	-- CFrame:ToAxisAngle() can land slightly above exact authored rotations.
	-- Snap only near integral angular ratios; linear and engine-distance caps stay
	-- strictly conservative.
	if
		math.abs(ratio - nearestInteger)
		<= ANGULAR_SEGMENT_RATIO_TOLERANCE * math.max(1, math.abs(ratio))
	then
		return nearestInteger
	end

	return math.ceil(ratio)
end

-- A predicate verdict is remembered so repeated members and repeated segments
-- never ask about the same part twice. Written as a plain function taking the
-- verdict cache rather than a closure over it, because a closure is an
-- allocation and a projectile can run this Step three times a frame.
local function acceptsPart(
	part: BasePart,
	predicate: Types.Predicate?,
	verdicts: { [BasePart]: boolean }
): boolean
	if predicate == nil then
		return true
	end

	local remembered = verdicts[part]

	if remembered ~= nil then
		return remembered
	end

	local accepted = predicate(part)

	if type(accepted) ~= "boolean" then
		fail("Filter predicate must return a boolean", "CallbackContract")
	end

	verdicts[part] = accepted

	return accepted
end

local function copyExclusions(exclusions: { Instance }?): { Instance }
	if exclusions == nil then
		return {}
	end

	if type(exclusions) ~= "table" then
		fail("internal exclusions must be an Instance array")
	end

	for _, instance in exclusions do
		if typeof(instance) ~= "Instance" then
			fail("every internal exclusion must be an Instance")
		end
	end

	return table.clone(exclusions)
end

function Sweep.new(options: SweepOptions, internalExclusions: { Instance }?): Sweep
	if type(options) ~= "table" then
		fail("expected an options table")
	end

	local shape = options.Shape
	validateShape(shape)
	local rootOffset = if options.Offset == nil then CFrame.identity else options.Offset

	if typeof(rootOffset) ~= "CFrame" or not isFiniteCFrame(rootOffset) then
		fail("options.Offset must be a finite CFrame")
	end

	local exclusions = copyExclusions(internalExclusions)

	if options.Filter ~= nil and (options.RaycastParams ~= nil or options.OverlapParams ~= nil) then
		fail("options.Filter cannot be combined with raw query params")
	end

	if options.RaycastParams ~= nil and typeof(options.RaycastParams) ~= "RaycastParams" then
		fail("options.RaycastParams must be a RaycastParams")
	end

	if options.OverlapParams ~= nil and typeof(options.OverlapParams) ~= "OverlapParams" then
		fail("options.OverlapParams must be an OverlapParams")
	end

	if options.EntityResolver ~= nil and type(options.EntityResolver) ~= "function" then
		fail("options.EntityResolver must be a function")
	end

	if options.ZoneResolver ~= nil and type(options.ZoneResolver) ~= "function" then
		fail("options.ZoneResolver must be a function")
	end

	if options.HitKey ~= nil and type(options.HitKey) ~= "function" then
		fail("options.HitKey must be a function")
	end

	if options.HitResponse ~= nil and type(options.HitResponse) ~= "function" then
		fail("options.HitResponse must be a function")
	end

	if options.HitPriority ~= nil and type(options.HitPriority) ~= "function" then
		fail("options.HitPriority must be a function")
	end

	if options.Detail ~= nil and type((options.Detail :: any).LevelAt) ~= "function" then
		fail("options.Detail must be created with VirtualHit.detail()")
	end

	if
		options.Filter ~= nil
		and (
			type((options.Filter :: any)._leaseRaycastParams) ~= "function"
			or type((options.Filter :: any)._leaseOverlapParams) ~= "function"
		)
	then
		fail("options.Filter must be created with VirtualHit.Filter.new()")
	end

	local worldRoot = resolveWorldRoot(options.WorldRoot)
	local sharedRegistry = options.Registry
	local registry: HitRegistryClass.HitRegistry
	local ownsRegistry: boolean

	if sharedRegistry ~= nil then
		if
			type(sharedRegistry) ~= "table"
			or type((sharedRegistry :: any).Accept) ~= "function"
		then
			fail("options.Registry must come from VirtualHit.HitRegistry.new()")
		end

		-- A shared registry already carries its own policy and key function.
		-- Accepting a second definition here would leave two disagreeing
		-- descriptions of the same acceptance rule.
		if options.HitPolicy ~= nil or options.HitKey ~= nil then
			fail(
				"options.Registry cannot be combined with options.HitPolicy or options.HitKey",
				"RegistryConflict"
			)
		end

		registry = sharedRegistry
		ownsRegistry = false
	else
		local policy: HitPolicy.Policy = if options.HitPolicy == nil
			then "OncePerEntity"
			else options.HitPolicy
		registry = HitRegistryClass.new(policy, nil, options.HitKey)
		ownsRegistry = true
	end

	local maxLinearStep =
		positiveNumber(options.MaxLinearStep, Tuning.MaxLinearStep, "MaxLinearStep")
	if maxLinearStep > Limits.MaxShapecastDistance then
		fail(
			string.format(
				"MaxLinearStep cannot exceed Roblox's Shapecast limit of %d studs",
				Limits.MaxShapecastDistance
			)
		)
	end
	local maxAngularStep =
		positiveNumber(options.MaxAngularStep, Tuning.MaxAngularStep, "MaxAngularStep")
	local maxSegments = positiveInteger(options.MaxSegments, Tuning.MaxSegments, "MaxSegments")
	local maxHitsPerSegment =
		positiveInteger(options.MaxHitsPerSegment, Tuning.MaxHitsPerSegment, "MaxHitsPerSegment")
	local probeFree = options.ProbeFree == true

	if options.ProbeFree ~= nil and type(options.ProbeFree) ~= "boolean" then
		fail("options.ProbeFree must be a boolean")
	end

	local members, partExclusions = buildMembers(shape, rootOffset, worldRoot, probeFree)
	local sampleChains: { { CFrame } } = {}

	for _ in members do
		table.insert(sampleChains, {} :: { CFrame })
	end

	local workingStats = createStats()
	local lastStats = createStats()

	return (
		setmetatable({
			_members = members,
			_probeFree = probeFree,
			_partExclusions = partExclusions,
			_filter = options.Filter,
			_raycastParams = options.RaycastParams,
			_overlapParams = options.OverlapParams,
			_worldRoot = worldRoot,
			_entityResolver = options.EntityResolver,
			_zoneResolver = options.ZoneResolver,
			_hitResponder = options.HitResponse,
			_hitPriority = options.HitPriority,
			_registry = registry,
			_ownsRegistry = ownsRegistry,
			_maxLinearStep = maxLinearStep,
			_maxAngularStep = maxAngularStep,
			_detail = options.Detail,
			_detailLinear = 1,
			_detailAngular = 1,
			_detailAt = Vector3.zero,
			_detailMargin = -1,
			_detailGeneration = 0,
			_detailAge = 0,
			_maxSegments = maxSegments,
			_maxHitsPerSegment = maxHitsPerSegment,
			_internalExclusions = exclusions,
			_internalVersion = 0,
			_paramsCache = nil,
			_scratch = CandidateModule.newScratch(),
			_lastSampleChains = sampleChains,
			_workingStats = workingStats,
			_lastStats = lastStats,
			_hasLastStats = false,
			_lastStatsSnapshot = nil,
			_truncation = TruncationModule.newTracker(),
			_stepping = false,
			_destroyed = false,
			_teardownPending = false,
		}, Sweep) :: any
	) :: Sweep
end

function Sweep._setInternalExclusions(self: Sweep, exclusions: { Instance })
	self._internalExclusions = copyExclusions(exclusions)
	self._internalVersion += 1
	self._paramsCache = nil
end

-- Rebuilding query params allocates two engine objects and copies every filter
-- list, once per Step. With hundreds of live projectiles that is the single
-- largest allocation source in the library, and almost all of it is redundant:
-- the inputs only change when the caller mutates the Filter or when the
-- internal exclusion registry gains or loses an artifact. Both are version
-- stamped, so the common case is one integer comparison.

-- A filter carrying CollectionService tags is never cached: its build result
-- can change with no mutation of its own. Neither is a BruteForceAllSlow query,
-- which reads the live tag registry the same way.
function Sweep._paramsForStep(self: Sweep): (RaycastParams, OverlapParams, Types.Predicate?)
	local filter = self._filter
	local filterVersion = if filter == nil then -1 else filter:GetVersion()
	local cacheable = filter == nil or not filter:IsVolatile()
	local exclusionGeneration = InternalExclusions.GetGeneration()
	local cached = self._paramsCache

	if
		cacheable
		and cached ~= nil
		and cached.FilterVersion == filterVersion
		and cached.ExclusionGeneration == exclusionGeneration
		and cached.InternalVersion == self._internalVersion
	then
		-- The previous Step reassigned FilterDescendantsInstances while walking
		-- members, so the base list is restored from the cache, not read back.
		local base = cached.BaseExclusions
		local restore = cached.Restore
		table.clear(restore)
		table.move(base, 1, #base, 1, restore)
		cached.Raycast.FilterDescendantsInstances = restore
		self._workingStats.ParamsReused += 1
		return cached.Raycast, cached.Overlap, cached.Predicate
	end

	local raycastParams: RaycastParams
	local overlapParams: OverlapParams
	local predicate: Types.Predicate? = nil

	if self._filter ~= nil then
		-- Leased: this path always clones before mutating, and the clone is what
		-- gets cached, so the lease is only ever read here.
		raycastParams = self._filter:_leaseRaycastParams()
		overlapParams = self._filter:_leaseOverlapParams()
		predicate = self._filter:GetPredicate()

		if typeof(raycastParams) ~= "RaycastParams" then
			fail("Filter must produce RaycastParams")
		end

		if typeof(overlapParams) ~= "OverlapParams" then
			fail("Filter must produce OverlapParams")
		end
	else
		raycastParams = Params.cloneRaycast(self._raycastParams)
		overlapParams = Params.cloneOverlap(self._overlapParams)
	end

	-- MaxParts only truncates the overlap phase, which a probe-free sweep never
	-- runs, so the guard is unnecessary there.
	if not self._probeFree and self._hitResponder ~= nil and overlapParams.MaxParts > 0 then
		fail("HitResponse requires OverlapParams.MaxParts = 0 so blockers cannot be omitted")
	end

	local exclusions = InternalExclusions.Acquire(
		self._worldRoot,
		raycastParams.BruteForceAllSlow or overlapParams.BruteForceAllSlow
	)

	for _, part in self._partExclusions do
		table.insert(exclusions, part)
	end

	for _, instance in self._internalExclusions do
		table.insert(exclusions, instance)
	end

	local builtRaycast = Params.withRaycastExclusions(raycastParams, exclusions)
	local builtOverlap = Params.withOverlapExclusions(overlapParams, exclusions)
	InternalExclusions.Release(exclusions)

	if cacheable then
		self._paramsCache = {
			Raycast = builtRaycast,
			Overlap = builtOverlap,
			Predicate = predicate,
			BaseExclusions = table.clone(builtRaycast.FilterDescendantsInstances),
			Restore = {},
			FilterVersion = filterVersion,
			ExclusionGeneration = exclusionGeneration,
			InternalVersion = self._internalVersion,
		}
	else
		self._paramsCache = nil
	end

	self._workingStats.ParamsRebuilt += 1
	return builtRaycast, builtOverlap, predicate
end

-- One cast for one member at one pose. With a probe it is a Shapecast; without
-- one it is the native Spherecast/Blockcast, which touch nothing in the
-- DataModel and are therefore usable under parallel Luau.
local function castMember(
	worldRoot: WorldRoot,
	member: Member,
	pose: CFrame,
	vector: Vector3,
	params: RaycastParams
): RaycastResult?
	local probe = member.Probe

	if probe ~= nil then
		probe.CFrame = pose
		return worldRoot:Shapecast(probe, vector, params)
	end

	local shape = member.Shape

	if shape.Type == "Sphere" then
		return worldRoot:Spherecast(pose.Position, shape.Radius, vector, params)
	elseif shape.Type == "Block" then
		return worldRoot:Blockcast(pose, shape.Size, vector, params)
	end

	return fail("a probe-free member must be a Sphere or Block")
end

function Sweep._collectOverlap(
	self: Sweep,
	part: BasePart,
	member: number,
	alpha: number,
	pose: CFrame,
	pathDistance: number,
	candidates: { RawCandidate },
	encountered: { [BasePart]: number }
)
	if CandidateOrdering.cannotImprove(alpha, part, candidates, encountered) then
		return
	end

	local surfaceDistance = 0

	if not part:IsA("Terrain") then
		local closestPoint = part:GetClosestPointOnSurface(pose.Position)
		surfaceDistance = (closestPoint - pose.Position).Magnitude
	end

	CandidateOrdering.keepBest(
		self._workingStats,
		CandidateModule.leaseRaw(
			self._scratch,
			part,
			"Overlap",
			member,
			alpha,
			pose,
			nil,
			pathDistance,
			surfaceDistance
		),
		candidates,
		encountered
	)
end

function Sweep._collectContact(
	self: Sweep,
	result: RaycastResult,
	member: number,
	alpha: number,
	pose: CFrame,
	pathDistance: number,
	candidates: { RawCandidate },
	encountered: { [BasePart]: number }
)
	if CandidateOrdering.cannotImprove(alpha, result.Instance, candidates, encountered) then
		return
	end

	CandidateOrdering.keepBest(
		self._workingStats,
		CandidateModule.leaseRaw(
			self._scratch,
			result.Instance,
			"Sweep",
			member,
			alpha,
			pose,
			result,
			pathDistance,
			(result.Position - pose.Position).Magnitude
		),
		candidates,
		encountered
	)
end

function Sweep._rankCandidates(self: Sweep, rawCandidates: { RawCandidate }): { RankedCandidate }
	CandidateOrdering.prepareRaw(self._workingStats, rawCandidates)
	local scratch = self._scratch
	local ranked = scratch.Ranked

	for _, raw in rawCandidates do
		local candidate: Types.SweepCandidate

		if raw.Kind == "Sweep" then
			local nativeResult = raw.NativeResult
			assert(nativeResult ~= nil, "Sweep candidates must carry a native result")
			local normalized =
				Resolver.normalize(nativeResult, self._entityResolver, self._zoneResolver)
			candidate = {
				Instance = normalized.Instance,
				Entity = normalized.Entity,
				Zone = normalized.Zone,
				Kind = "Sweep" :: "Sweep",
				Member = raw.Member,
				Alpha = raw.Alpha,
				Pose = raw.Pose,
				RootPose = CandidateModule.rootPoseAt(scratch, raw.Alpha),
				Result = normalized,
			}
		else
			candidate = {
				Instance = raw.Instance,
				Entity = Resolver.resolve(raw.Instance, self._entityResolver),
				Zone = Resolver.resolveZone(raw.Instance, self._zoneResolver),
				Kind = "Overlap" :: "Overlap",
				Member = raw.Member,
				Alpha = raw.Alpha,
				Pose = raw.Pose,
				RootPose = CandidateModule.rootPoseAt(scratch, raw.Alpha),
				Result = nil,
			}
		end

		if candidate.Kind == "Sweep" then
			table.freeze(candidate.Result)
		end

		table.freeze(candidate)

		local priority = 0

		if self._hitPriority ~= nil then
			priority = self._hitPriority(candidate)

			if type(priority) ~= "number" or not isFiniteNumber(priority) then
				fail("HitPriority must return a finite number", "CallbackContract")
			end
		end

		local leased = scratch.RankedLeased + 1
		scratch.RankedLeased = leased
		local record = scratch.RankedPool[leased]

		if record == nil then
			record = {
				Candidate = candidate,
				Raw = raw,
				Priority = priority,
				Response = "Hit",
				Key = nil,
			}
			scratch.RankedPool[leased] = record
		else
			record.Candidate = candidate
			record.Raw = raw
			record.Priority = priority
			record.Response = "Hit"
			-- A key left from a previous Step would be committed against this
			-- Step's candidate.
			record.Key = nil
		end

		table.insert(ranked, record)
	end

	table.sort(ranked, CandidateOrdering.rankedOrder)

	return ranked
end

-- Fills in the responses and re-sorts the same array. The responses can only
-- change the order, never the membership, so there is nothing to copy.
function Sweep._evaluateCandidates(self: Sweep, ranked: { RankedCandidate })
	for _, item in ranked do
		local response: Types.HitResponse = "Hit"

		if self._hitResponder ~= nil then
			response = self._hitResponder(item.Candidate)

			if response ~= "Hit" and response ~= "Block" and response ~= "Ignore" then
				fail("HitResponse must return Hit, Block, or Ignore", "CallbackContract")
			end
		end

		if item.Candidate.Instance:IsA("Terrain") then
			if self._hitResponder == nil then
				response = "Block"
			elseif response ~= "Block" then
				fail("HitResponse must return Block for Terrain", "CallbackContract")
			end
		end

		item.Response = response
	end

	table.sort(ranked, CandidateOrdering.evaluatedOrder)
end

local function copyHitResult(result: Types.HitResult): Types.HitResult
	return {
		Instance = result.Instance,
		Position = result.Position,
		Normal = result.Normal,
		Material = result.Material,
		Distance = result.Distance,
		Entity = result.Entity,
		Zone = result.Zone,
	}
end

local function acceptedHit(candidate: Types.SweepCandidate): Types.SweepHit
	if candidate.Kind == "Sweep" then
		return {
			Instance = candidate.Instance,
			Entity = candidate.Entity,
			Zone = candidate.Zone,
			Kind = "Sweep" :: "Sweep",
			Member = candidate.Member,
			Alpha = candidate.Alpha,
			Pose = candidate.Pose,
			RootPose = candidate.RootPose,
			Result = copyHitResult(candidate.Result),
			Response = "Hit",
		}
	else
		return {
			Instance = candidate.Instance,
			Entity = candidate.Entity,
			Zone = candidate.Zone,
			Kind = "Overlap" :: "Overlap",
			Member = candidate.Member,
			Alpha = candidate.Alpha,
			Pose = candidate.Pose,
			RootPose = candidate.RootPose,
			Result = nil,
			Response = "Hit",
		}
	end
end

local function acceptedBlock(candidate: Types.SweepCandidate): Types.SweepBlock
	if candidate.Kind == "Sweep" then
		return {
			Instance = candidate.Instance,
			Entity = candidate.Entity,
			Zone = candidate.Zone,
			Kind = "Sweep" :: "Sweep",
			Member = candidate.Member,
			Alpha = candidate.Alpha,
			Pose = candidate.Pose,
			RootPose = candidate.RootPose,
			Result = copyHitResult(candidate.Result),
			Response = "Block",
		}
	else
		return {
			Instance = candidate.Instance,
			Entity = candidate.Entity,
			Zone = candidate.Zone,
			Kind = "Overlap" :: "Overlap",
			Member = candidate.Member,
			Alpha = candidate.Alpha,
			Pose = candidate.Pose,
			RootPose = candidate.RootPose,
			Result = nil,
			Response = "Block",
		}
	end
end

function Sweep._applyEvaluated(
	self: Sweep,
	evaluated: { RankedCandidate }
): ({ Types.SweepHit }, Types.SweepBlock?)
	local hits: { Types.SweepHit } = {}
	local stats = self._workingStats
	local registry = self._registry

	-- Every key first, and only then the commit.
          
	-- HitKey is caller code and caller code can throw. Computing keys inside
	-- the acceptance walk meant a HitKey that failed on the third candidate
	-- left the first two consumed by a Step that went on to report failure --
	-- the one callback in the pipeline that was not transactional, while
	-- HitPriority and HitResponse both were.

	-- The walk stops at the first blocker exactly as the commit below does, so
	-- HitKey is still called for precisely the candidates it was called for
	-- before: every Hit ahead of the block, and nothing after it.
	for _, item in evaluated do
		if item.Response == "Block" then
			break
		end

		if item.Response == "Hit" then
			local candidate = item.Candidate
			item.Key = registry:KeyFor(candidate.Instance, candidate.Entity, candidate)
		end
	end

	-- Nothing below runs caller code, so nothing below can fail part way.
	for index, item in evaluated do
		local candidate = item.Candidate

		if item.Response == "Block" then
			stats.Blocked = 1
			stats.Occluded = #evaluated - index
			return hits, acceptedBlock(candidate)
		elseif item.Response == "Hit" then
			if registry:AcceptKey(item.Key) then
				table.insert(hits, acceptedHit(candidate))
				stats.Hits += 1
			else
				stats.PolicyRejected += 1
			end
		else
			stats.Ignored += 1
		end
	end

	return hits, nil
end

-- The multipliers this Step runs at, cached against how far the sweep has moved.

-- The field hands back the distance to the nearest ring boundary along with the
-- answer, so a sweep that has not moved that far cannot have changed rings and
-- reuses what it was told. A projectile crossing open ground asks the field
-- once every few hundred studs instead of sixty times a second.

-- Two things the margin cannot see, because the sweep did not move -- the world
-- did. The generation catches an observer being added or removed. The age cap
-- catches observers simply walking around, which no membership change reports.

-- Both are bounded staleness, and bounded staleness is acceptable here in a way
-- it is not for a broadphase: a stale level cannot produce a wrong hit. Every
-- level still runs the query. The only thing it can get wrong is how much that
-- query cost.
local function detailFor(self: Sweep, position: Vector3): (number, number)
	local field = self._detail

	if field == nil then
		return 1, 1
	end

	local generation = field:GetGeneration()
	self._detailAge += 1

	if
		self._detailMargin >= 0
		and self._detailGeneration == generation
		and self._detailAge <= Tuning.MaxDetailAge
		and (position - self._detailAt).Magnitude < self._detailMargin
	then
		return self._detailLinear, self._detailAngular
	end

	local linear, angular, margin = field:LevelAt(position)
	self._detailLinear = linear
	self._detailAngular = angular
	self._detailAt = position
	self._detailMargin = margin
	self._detailGeneration = generation
	self._detailAge = 0

	return linear, angular
end

local function stepInternal(
	self: Sweep,
	previous: CFrame,
	current: CFrame
): ({ Types.SweepHit }, Types.SweepBlock?)
	if self._destroyed then
		fail("cannot Step a destroyed sweep", "Destroyed")
	end

	if
		typeof(previous) ~= "CFrame"
		or typeof(current) ~= "CFrame"
		or not isFiniteCFrame(previous)
		or not isFiniteCFrame(current)
	then
		fail("Step expects two finite CFrames")
	end

	local rotationAxis, angle = rotationAxisAngle(previous, current)
	local rootTravel = (current.Position - previous.Position).Magnitude

	-- Every member shares one segment count so their alphas stay directly
	-- comparable, which is what makes cross-member ordering meaningful. The
	-- count is therefore driven by the member that needs the most resolution.
	local maxCenterRotationRadius = 0
	local maxRotationRadius = 0
	local allCentered = true
	local blindRotatingMember: number? = nil

	for memberIndex, member in self._members do
		local offsetPosition = member.Offset.Position
		local axialOffset = rotationAxis * offsetPosition:Dot(rotationAxis)
		local centerRotationRadius = (offsetPosition - axialOffset).Magnitude
		maxCenterRotationRadius = math.max(maxCenterRotationRadius, centerRotationRadius)
		maxRotationRadius =
			math.max(maxRotationRadius, centerRotationRadius + member.RotationRadius)

		if not (member.IsSphere and centerRotationRadius <= MIN_TRANSLATION) then
			allCentered = false
		end

		-- A member whose own origin does not move produces no cast, because a
		-- cast needs a direction. With a probe the overlap phase still sees the
		-- rotated volume; without one there is nothing left to look with, and a
		-- Block spinning in place would silently report no hits at all. A
		-- Sphere is exempt: its rotation changes nothing it could have hit.
		if
			self._probeFree
			and not member.IsSphere
			and angle > MIN_TRANSLATION
			and rootTravel + centerRotationRadius * angle <= MIN_TRANSLATION
		then
			blindRotatingMember = memberIndex
		end
	end

	if blindRotatingMember ~= nil then
		fail(
			string.format(
				"a ProbeFree sweep cannot observe member %d rotating in place; drop ProbeFree for this shape or use a Sphere member",
				blindRotatingMember
			),
			"ProbeFreeRotation"
		)
	end

	local centerRotationRadius = maxCenterRotationRadius
	local shapeAngle = if allCentered then 0 else angle
	local rotationRadius = maxRotationRadius
	local estimatedTravel = rootTravel + rotationRadius * angle
	local shapeOriginTravel = rootTravel + centerRotationRadius * angle
	-- Detail is read from where the Step starts, so the whole Step runs at one
	-- resolution rather than changing resolution part way along its own path.
	local detailLinear, detailAngular = detailFor(self, previous.Position)
	local linearSegments = math.ceil(estimatedTravel / (self._maxLinearStep * detailLinear))
	local angularSegments = angularSegmentCount(shapeAngle, self._maxAngularStep * detailAngular)
	local engineSegments = math.ceil(shapeOriginTravel / Limits.MaxShapecastDistance)
	local requiredSegments = if estimatedTravel <= MIN_TRANSLATION
			and shapeAngle <= MIN_TRANSLATION
		then 0
		else math.max(1, linearSegments, angularSegments, engineSegments)
	local segmentCount = math.min(requiredSegments, self._maxSegments)
	local stats = self._workingStats
	stats.Distance = rootTravel
	stats.EstimatedTravel = estimatedTravel
	stats.AngularTravel = angle
	stats.RequiredSegments = requiredSegments
	stats.Segments = segmentCount
	stats.DetailScale = detailLinear

	if engineSegments > self._maxSegments then
		TruncationModule.recordEngineLimit(
			self._truncation,
			self._workingStats,
			engineSegments,
			self._maxSegments,
			Limits.MaxShapecastDistance
		)
		fail(
			string.format(
				"Step movement needs at least %d segments to stay within Roblox's %d-stud Shapecast limit; increase MaxSegments or call Step more often",
				engineSegments,
				Limits.MaxShapecastDistance
			),
			"EngineShapecastLimit"
		)
	end

	if requiredSegments > self._maxSegments then
		TruncationModule.recordMaxSegments(
			self._truncation,
			self._workingStats,
			requiredSegments,
			self._maxSegments
		)
	end

	if self._truncation.HasWorking and self._hitResponder ~= nil then
		fail(
			"HitResponse cannot run a truncated Step; increase MaxSegments or call Step more often",
			"TruncatedResponse"
		)
	end

	local scratch = CandidateModule.resetScratch(self._scratch)
	scratch.Previous = previous
	scratch.Current = current
	local rootPoses = scratch.RootPoses

	--[[
		The two ends are the poses that were passed in, not copies of them.

		Lerp allocates, and at alpha zero and one it allocates a CFrame equal to
		one the caller already handed over. On the ordinary two-sample Step that
		is every pose in the chain.
	]]
	for index = 0, segmentCount do
		if index == 0 then
			rootPoses[1] = previous
		elseif index == segmentCount then
			rootPoses[index + 1] = current
		else
			rootPoses[index + 1] = previous:Lerp(current, index / segmentCount)
		end
	end

	-- The chains are the sweep's own pose buffers and are handed to callers only
	-- as clones, so they are refilled in place rather than rebuilt.
	local sampleChains = self._lastSampleChains

	for memberIndex, member in self._members do
		local chain = sampleChains[memberIndex]

		if chain == nil then
			chain = {}
			sampleChains[memberIndex] = chain
		else
			table.clear(chain)
		end

		local offsetIsIdentity = member.OffsetIsIdentity

		for index, rootPose in rootPoses do
			-- A member sitting on the root is at the root. Multiplying anyway
			-- costs a CFrame per segment, and this is the common shape.
			chain[index] = if offsetIsIdentity then rootPose else rootPose * member.Offset
		end
	end

	local raycastParams, overlapParams, predicate = self:_paramsForStep()
	local candidates = scratch.Candidates
	local encountered = scratch.Encountered
	local allowlist = raycastParams.FilterType == Enum.RaycastFilterType.Include
	local baseExclusions = scratch.BaseExclusions

	for index, instance in raycastParams.FilterDescendantsInstances do
		baseExclusions[index] = instance
	end

	-- A predicate verdict is remembered so repeated members and repeated
	-- segments never ask about the same part twice.
	local verdicts = scratch.Verdicts

	for memberIndex, member in self._members do
		local samples = sampleChains[memberIndex]
		local probe = member.Probe
		-- Terrain terminates collection for the member that reached it. Other
		-- members keep collecting, because a nearer contact on a different
		-- member must still be able to outrank that terminal blocker.
		local stopCollection = false
		local cumulativePathDistance = 0
		-- Each member starts from the base exclusions. What one member walked
		-- past must stay visible to the next one.
		local exclusions =
			CandidateModule.prepareExclusionState(scratch, memberIndex, baseExclusions, allowlist)
		raycastParams.FilterDescendantsInstances = exclusions.List

		for index, pose in samples do
			local alpha = if segmentCount == 0 then 0 else (index - 1) / segmentCount

			if probe ~= nil then
				probe.CFrame = pose
				stats.OverlapQueries += 1
				local overlaps = self._worldRoot:GetPartsInPart(probe, overlapParams)
				stats.RawCandidates += #overlaps
				if overlapParams.MaxParts > 0 and #overlaps >= overlapParams.MaxParts then
					-- GetPartsInPart stops at the native part cap before entity/policy
					-- deduplication, so there may be unseen candidates even when every
					-- returned part later collapses to the same entity.
					TruncationModule.recordMaxParts(
						self._truncation,
						self._workingStats,
						#overlaps,
						overlapParams.MaxParts,
						index
					)
				end

				for _, part in overlaps do
					if acceptsPart(part, predicate, verdicts) then
						self:_collectOverlap(
							part,
							memberIndex,
							alpha,
							pose,
							cumulativePathDistance,
							candidates,
							encountered
						)

						if part:IsA("Terrain") then
							stopCollection = true
						end
					end
				end
			end

			if not stopCollection and index < #samples then
				local nextPose = samples[index + 1]
				local vector = nextPose.Position - pose.Position
				local distance = vector.Magnitude

				if distance > MIN_TRANSLATION then
					local reachedHitLimit = true

					for _ = 1, self._maxHitsPerSegment do
						stats.ShapeCasts += 1
						local result =
							castMember(self._worldRoot, member, pose, vector, raycastParams)

						if result == nil then
							reachedHitLimit = false
							break
						end

						stats.RawCandidates += 1

						local localAlpha = math.clamp(result.Distance / distance, 0, 1)
						local globalAlpha = ((index - 1) + localAlpha) / segmentCount
						local contactPose = pose + vector.Unit * result.Distance

						if acceptsPart(result.Instance, predicate, verdicts) then
							self:_collectContact(
								result,
								memberIndex,
								globalAlpha,
								contactPose,
								cumulativePathDistance + result.Distance,
								candidates,
								encountered
							)

							if result.Instance:IsA("Terrain") then
								reachedHitLimit = false
								stopCollection = true
								break
							end
						elseif result.Instance:IsA("Terrain") then
							-- Terrain cannot be excluded per-instance without
							-- removing all of it, so a rejected Terrain contact
							-- ends this member instead of looping forever.
							reachedHitLimit = false
							stopCollection = true
							break
						end

						if
							not CandidateModule.addExclusion(
								raycastParams,
								exclusions,
								result.Instance
							)
						then
							reachedHitLimit = false
							TruncationModule.recordAllowlist(
								self._truncation,
								self._workingStats,
								index
							)
							break
						end
					end

					if reachedHitLimit then
						stats.ShapeCasts += 1
						local remaining =
							castMember(self._worldRoot, member, pose, vector, raycastParams)

						if remaining ~= nil then
							stats.RawCandidates += 1
							TruncationModule.recordMaxHitsPerSegment(
								self._truncation,
								self._workingStats,
								self._maxHitsPerSegment,
								index
							)
							stopCollection = true
						end
					end
				end

				cumulativePathDistance += distance
			end

			if stopCollection then
				break
			end
		end
	end

	if self._truncation.HasWorking and self._hitResponder ~= nil then
		-- Fail closed: a Block decision taken from a candidate set that is known
		-- to be incomplete is worse than no decision. Naming the reason matters
		-- because the remedy differs: a cap can be raised, an allowlist cannot.
		local reason = tostring(self._truncation.Working.Reason)
		fail(`HitResponse cannot run an incomplete Step ({reason})`, "TruncatedResponse")
	end

	local ranked = self:_rankCandidates(candidates)
	self:_evaluateCandidates(ranked)

	return self:_applyEvaluated(ranked)
end

local function commitDiagnostics(self: Sweep)
	copyStats(self._lastStats, self._workingStats)
	self._hasLastStats = true
	self._lastStatsSnapshot = nil
	TruncationModule.commit(self._truncation)
end

local function teardown(self: Sweep)
	for _, member in self._members do
		local probe = member.Probe

		if probe ~= nil then
			ShapeProbe.release(probe)
		end
	end

	for _, chain in self._lastSampleChains do
		table.clear(chain)
	end

	-- The scratch pools outlive a Step by design; they must not outlive the
	-- sweep, or a destroyed hitbox keeps holding whatever it last touched.
	local scratch = self._scratch
	table.clear(scratch.CandidatePool)
	table.clear(scratch.RankedPool)
	table.clear(scratch.ExclusionStates)
	CandidateModule.resetScratch(scratch)
end

function Sweep.Step(
	self: Sweep,
	previous: CFrame,
	current: CFrame
): ({ Types.SweepHit }, Types.SweepBlock?)
	if self._stepping then
		fail("Step cannot be called recursively on the same sweep", "Reentrant")
	end

	local startedAt = os.clock()
	resetStats(self._workingStats)
	TruncationModule.beginStep(self._truncation)

	for _, chain in self._lastSampleChains do
		table.clear(chain)
	end

	self._stepping = true
	-- Passed as arguments rather than captured, so the guarded call costs no
	-- closure and no upvalue cells. A projectile runs this several times a frame.
	local success, first, second = xpcall(stepInternal, Errors.capture, self, previous, current)
	self._stepping = false
	-- On failure xpcall hands back the handler's value where the hits would be.
	local captured: Errors.Captured? = if success then nil else first :: Errors.Captured
	self._workingStats.Succeeded = success
	self._workingStats.Error = if captured == nil then nil else captured.Trace
	self._workingStats.TimeMs = (os.clock() - startedAt) * 1_000
	commitDiagnostics(self)
	CandidateModule.releaseScratch(self._scratch)

	if self._teardownPending then
		-- A callback destroyed this sweep mid-Step. Now that nothing is walking
		-- the arrays any more, the teardown it asked for can actually happen.
		self._teardownPending = false
		teardown(self)
	end

	if captured ~= nil then
		-- The original value, not the trace: a caller that was told to branch on
		-- Errors.is needs the code to survive the guarded call.
		Errors.rethrow(captured)
	end

	return first :: { Types.SweepHit }, second :: Types.SweepBlock?
end

-- The first member's pose chain. For a Sphere, Block, or Part shape that is the
-- whole sweep; for a Compound it is the first member only, and callers that
-- need the rest should use GetLastSampleChains.
function Sweep.GetLastSamples(self: Sweep): { CFrame }
	local first = self._lastSampleChains[1]
	return if first == nil then {} else table.clone(first)
end

function Sweep.GetLastSampleChains(self: Sweep): { { CFrame } }
	local chains: { { CFrame } } = {}

	for index, chain in self._lastSampleChains do
		chains[index] = table.clone(chain)
	end

	return chains
end

function Sweep.GetMemberCount(self: Sweep): number
	return #self._members
end

function Sweep.IsProbeFree(self: Sweep): boolean
	return self._probeFree
end

function Sweep.GetLastStats(self: Sweep): SweepStats?
	if not self._hasLastStats then
		return nil
	end

	local snapshot = self._lastStatsSnapshot

	if snapshot == nil then
		snapshot = table.freeze(table.clone(self._lastStats))
		self._lastStatsSnapshot = snapshot
	end

	return snapshot
end

-- Internal zero-allocation bridge used by the shared melee runtime. Public
-- callers should use GetLastStats(), which returns an immutable snapshot.
function Sweep._getLastQueryCounts(self: Sweep): (number?, number?)
	if not self._hasLastStats then
		return nil, nil
	end

	return self._lastStats.ShapeCasts, self._lastStats.OverlapQueries
end

function Sweep.GetLastTruncation(self: Sweep): SweepTruncation?
	if not self._truncation.HasLast then
		return nil
	end

	local snapshot = self._truncation.Snapshot

	if snapshot == nil then
		snapshot = table.freeze(table.clone(self._truncation.Last) :: any) :: SweepTruncation
		self._truncation.Snapshot = snapshot
	end

	return snapshot
end

function Sweep.WasLastStepTruncated(self: Sweep): boolean
	return self._truncation.HasLast
end

-- A shared registry belongs to whoever created it. Resetting one member of a
-- group would silently re-arm the whole group's policy, so this only resets a
-- registry the sweep owns.
function Sweep.ResetPolicy(self: Sweep)
	if self._ownsRegistry then
		self._registry:Reset()
	end
end

-- Re-arms hit acceptance and drops the diagnostics from the last Step. A caller
-- that only wants to re-arm acceptance mid-flight — a ricocheting projectile
-- that may legitimately hit the same target again — should use ResetPolicy so
-- the last Step's stats stay readable.
function Sweep.Reset(self: Sweep)
	self:ResetPolicy()

	-- A callback running inside Step is iterating these chains right now.
	-- Emptying them under the loop would silently cut the sweep short, and the
	-- Step is about to overwrite them anyway.
	if not self._stepping then
		for _, chain in self._lastSampleChains do
			table.clear(chain)
		end
	end

	self._hasLastStats = false
	self._lastStatsSnapshot = nil
	TruncationModule.clearLast(self._truncation)
end

function Sweep.GetRegistry(self: Sweep): HitRegistryClass.HitRegistry
	return self._registry
end

-- Deferred when a Step is still running.

-- HitPriority, HitResponse, the resolvers and HitKey all run inside Step, and
-- any of them can reach the sweep they were called about. Releasing the probes
-- and emptying the candidate arrays from inside that call would pull the
-- collection out from under the loop still walking it. The sweep is marked
-- destroyed immediately -- so nothing new starts -- and the teardown happens
-- when the Step it interrupted has finished.
function Sweep.Destroy(self: Sweep)
	if self._destroyed then
		return
	end

	self._destroyed = true

	if self._stepping then
		self._teardownPending = true
		return
	end

	teardown(self)
end

return Sweep
