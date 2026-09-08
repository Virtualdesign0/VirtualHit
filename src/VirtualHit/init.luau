--!strict

local Types = require(script.Types)
local Config = require(script.Config)
local Cast = require(script.Cast.Cast)
local Materials = require(script.Cast.Materials)
local ImpactSolver = require(script.Impact.ImpactSolver)
local MaterialProfile = require(script.Impact.MaterialProfile)
local Pierce = require(script.Cast.Pierce)
local Shapes = require(script.Cast.Shapes)
local FilterClass = require(script.Collision.Filter)
local Overlap = require(script.Collision.Overlap)
local Radial = require(script.Collision.Radial)
local Resolver = require(script.Collision.Resolver)
local TerrainProbe = require(script.Collision.TerrainProbe)
local Recorder = require(script.Debug.Recorder)
local Telemetry = require(script.Debug.Telemetry)
local Visualizer = require(script.Debug.Visualizer)
local HitPolicy = require(script.Sweep.HitPolicy)
local HitRegistry = require(script.Sweep.HitRegistry)
local HitResponse = require(script.Sweep.HitResponse)
local Sweep = require(script.Sweep.Sweep)
local TruncationReason = require(script.Sweep.TruncationReason)
local MeleeGroup = require(script.Melee.MeleeGroup)
local MeleeHitbox = require(script.Melee.MeleeHitbox)
local MeleeStopReason = require(script.Melee.StopReason)
local MeleeRuntime = require(script.Melee.Runtime)
local Ballistics = require(script.Projectile.Ballistics)
local ProjectilePool = require(script.Projectile.Pool)
local Projectile = require(script.Projectile.Projectile)
local ProjectileStopReason = require(script.Projectile.StopReason)
local RewindWorld = require(script.Rewind.RewindWorld)
local Validator = require(script.Rewind.Validator)
-- Bound under a distinct name so the exported generic `Signal<T...>` alias
-- below never has to resolve a qualified name that shadows itself.
local ErrorsModule = require(script.Util.Errors)
local SignalModule = require(script.Util.Signal)
local Zone = require(script.Zone.Zone)
local ZoneIndex = require(script.Zone.ZoneIndex)
local DetailField = require(script.Detail.DetailField)

export type HitResult = Types.HitResult
export type CastOptions = Cast.CastOptions
export type CastTruncation = Cast.CastTruncation
export type CastShape = Types.CastShape
export type OverlapShape = Types.OverlapShape
export type SweepShape = Types.SweepShape
export type RayShape = Types.RayShape
export type SphereShape = Types.SphereShape
export type BlockShape = Types.BlockShape
export type PartShape = Types.PartShape
export type PrimitiveShape = Types.PrimitiveShape
export type CompoundShape = Types.CompoundShape
export type CompoundMember = Types.CompoundMember
export type OverlapHit = Types.OverlapHit
export type OverlapOptions = Overlap.OverlapOptions
export type OverlapSort = Overlap.OverlapSort
export type RadialHit = Types.RadialHit
export type RadialOptions = Radial.RadialOptions
export type RadialStats = Radial.RadialStats
export type RadialTruncation = Radial.RadialTruncation
export type SweepOverlapHit = Types.SweepOverlapHit
export type SweepContactHit = Types.SweepContactHit
export type SweepHit = Types.SweepHit
export type SweepOverlapBlock = Types.SweepOverlapBlock
export type SweepContactBlock = Types.SweepContactBlock
export type SweepBlock = Types.SweepBlock
export type SweepCandidate = Types.SweepCandidate
export type HitResponse = Types.HitResponse
export type HitResponder = Sweep.HitResponder
export type HitPriority = Sweep.HitPriority
export type HitKey = Sweep.HitKey
export type HitRegistry = HitRegistry.HitRegistry
export type Sweep = Sweep.Sweep
export type SweepOptions = Sweep.SweepOptions
export type SweepConfig = Sweep.SweepConfig
export type SweepStats = Sweep.SweepStats
export type TruncationReason = Sweep.TruncationReason
export type SweepTruncation = Sweep.SweepTruncation
export type MaxSegmentsTruncation = Sweep.MaxSegmentsTruncation
export type MaxHitsPerSegmentTruncation = Sweep.MaxHitsPerSegmentTruncation
export type MaxPartsTruncation = Sweep.MaxPartsTruncation
export type EngineShapecastLimitTruncation = Sweep.EngineShapecastLimitTruncation
export type HitPolicy = HitPolicy.Policy
export type MeleeSource = MeleeHitbox.MeleeSource
export type MeleeOptions = MeleeHitbox.MeleeOptions
export type MeleeHitbox = MeleeHitbox.MeleeHitbox
export type MeleeStopReason = MeleeStopReason.StopReason
export type MeleeGroup = MeleeGroup.MeleeGroup
export type MeleeGroupOptions = MeleeGroup.MeleeGroupOptions
export type MeleeGroupMember = MeleeGroup.MeleeGroupMember
export type MeleeGroupHit = MeleeGroup.MeleeGroupHit
export type MeleeGroupBlock = MeleeGroup.MeleeGroupBlock
export type MeleeRuntimeOptions = MeleeRuntime.RuntimeOptions
export type MeleeRuntimeConfig = MeleeRuntime.RuntimeConfig
export type MeleeRuntimeStats = MeleeRuntime.RuntimeStats
export type Zone = Zone.Zone
export type ZoneOptions = Zone.ZoneOptions
export type ZoneOccupant = Zone.ZoneOccupant
export type ZoneAnchor = Zone.ZoneAnchor
export type ZoneScope = Zone.ZoneScope
export type Projectile = Projectile.Projectile
export type ProjectileOptions = Projectile.ProjectileOptions
export type ProjectileStats = Projectile.ProjectileStats
export type ProjectileTruncation = Projectile.ProjectileTruncation
export type ProjectileStopReason = ProjectileStopReason.StopReason
export type RicochetOptions = Projectile.RicochetOptions
export type RicochetContext = Projectile.RicochetContext
export type PierceOptions = Pierce.PierceOptions
export type PierceHit = Pierce.PierceHit
export type PierceContact = Pierce.PierceContact
export type PierceStats = Pierce.PierceStats
export type PierceStopReason = Pierce.PierceStopReason
export type RewindWorld = RewindWorld.RewindWorld
export type RewindOptions = RewindWorld.RewindOptions
export type RewindInfo = RewindWorld.RewindInfo
export type RewindStats = RewindWorld.RewindStats
export type Validator = Validator.Validator
export type ValidatorOptions = Validator.ValidatorOptions
export type ValidatorClaim = Validator.Claim
export type ValidatorServerPose = Validator.ServerPose
export type ValidatorVerdict = Validator.Verdict
export type ValidatedShot = Validator.ValidatedShot
export type ValidatorRejection = Validator.Rejection
export type Filter = FilterClass.Filter
export type Predicate = Types.Predicate
export type EntityResolver = Types.EntityResolver
export type ZoneResolver = Types.ZoneResolver
export type Signal<T...> = SignalModule.Signal<T...>
export type Connection = SignalModule.Connection
export type ProjectilePool = ProjectilePool.Pool
export type ProjectilePoolOptions = ProjectilePool.PoolOptions
export type ProjectilePoolStats = ProjectilePool.PoolStats
export type LaunchOptions = Projectile.LaunchOptions
export type BallisticSolution = Ballistics.Solution
export type BallisticLeadOptions = Ballistics.LeadOptions
export type MaterialTable = Materials.MaterialTable
export type MaterialOptions = Materials.MaterialOptions
export type ImpactSolver = ImpactSolver.ImpactSolver
export type ImpactSolverOptions = ImpactSolver.ImpactSolverOptions
export type ImpactResult = ImpactSolver.ImpactResult
export type ImpactRequest = ImpactSolver.ImpactRequest
export type ImpactAction = ImpactSolver.Action
-- What a flight did about an impact, as opposed to what the surface did.
export type ProjectileImpact = Projectile.ProjectileImpact
export type ImpactLimit = Projectile.ImpactLimit
export type MaterialProfileTable = MaterialProfile.MaterialProfileTable
export type MaterialProfileOptions = MaterialProfile.MaterialProfileOptions
export type MaterialProfileEntry = MaterialProfile.Profile
export type ZoneIndex = ZoneIndex.ZoneIndex
export type ZoneIndexOptions = ZoneIndex.ZoneIndexOptions
export type ZoneIndexStats = ZoneIndex.ZoneIndexStats
export type DetailField = DetailField.DetailField
export type DetailFieldOptions = DetailField.DetailFieldOptions
export type DetailLevel = DetailField.DetailLevel
export type DetailFieldStats = DetailField.DetailFieldStats
export type Recorder = Recorder.Recorder
export type RecorderTrace = Recorder.Trace
export type RecorderFrame = Recorder.Frame
export type RecorderHit = Recorder.HitRecord
export type RecorderDivergence = Recorder.Divergence
export type RecorderReport = Recorder.Report
export type RecorderDisagreement = Recorder.Disagreement
export type RecorderDivergenceKind = Recorder.DivergenceKind
export type RecorderReconcileOptions = Recorder.ReconcileOptions
export type TerrainSpan = TerrainProbe.TerrainSpan
export type TerrainSampleOptions = TerrainProbe.SampleOptions
export type VirtualHitError = ErrorsModule.Error
export type CapturedError = ErrorsModule.Captured
export type ErrorCode = ErrorsModule.Code
export type TelemetryOptions = Telemetry.TelemetryOptions
export type DebugDrawOptions = Visualizer.DrawOptions
export type DebugSweepDrawOptions = Visualizer.SweepDrawOptions
export type ConfigFieldInfo = Config.FieldInfo
export type ConfigScope = Config.ConfigScope
export type ConfigAttributeBinding = Config.AttributeBinding

local VirtualHit = {
	Shapes = Shapes,
	Filter = FilterClass,
	Debug = Visualizer,
	HitPolicy = HitPolicy,
	HitResponse = HitResponse,
	HitRegistry = HitRegistry,
	TruncationReason = TruncationReason,
	MeleeStopReason = MeleeStopReason,
	ProjectileStopReason = ProjectileStopReason,
	MeleeRuntime = MeleeRuntime.Public,
	-- The shared query runtime is no longer melee-only: zones ride the same
	-- Heartbeat connection and the same budget. MeleeRuntime stays as the
	-- established name for it.
	Runtime = MeleeRuntime.Public,
	Signal = SignalModule,
	Ballistics = Ballistics,
	Materials = Materials,
	Recorder = Recorder,
	Telemetry = Telemetry,
	Terrain = TerrainProbe,
	Errors = ErrorsModule,
	-- Every default the library ships, in one schema. Read it for the current
	-- values; change it through configure().
	Config = Config,
}

-- Returns the hit and, when a Filter predicate exhausted its retry budget with
-- a rejected part still in front of the cast, an uncertain truncation. A nil
-- hit with a truncation means "could not determine", not "nothing there".
function VirtualHit.cast(options: Cast.CastOptions): (Types.HitResult?, Cast.CastTruncation?)
	local result, rejected, allowed, exhausted, distanceOffset = Cast.perform(options)

	if exhausted then
		-- Annotated on the literal so Truncated stays `true` and Certain stays
		-- `false`; annotating the table.freeze result would widen both to boolean.
		local truncation: Cast.PredicateRetriesTruncation = {
			Truncated = true,
			Reason = "PredicateRetries",
			Certain = false,
			Rejected = rejected,
			Allowed = allowed,
		}

		return nil, table.freeze(truncation)
	end

	if result == nil then
		return nil, nil
	end

	return Resolver.normalize(result, options.EntityResolver, options.ZoneResolver, distanceOffset),
		nil
end

function VirtualHit.overlap(options: Overlap.OverlapOptions): { Types.OverlapHit }
	return Overlap.perform(options)
end

function VirtualHit.radial(
	options: Radial.RadialOptions
): ({ Types.RadialHit }, Radial.RadialStats, Radial.RadialTruncation?)
	return Radial.perform(options)
end

-- Ordered contacts along one line of fire, each charged against a penetration
-- budget. The second return value says why the shot stopped.
function VirtualHit.pierce(
	options: Pierce.PierceOptions
): ({ Pierce.PierceHit }, Pierce.PierceStats)
	return Pierce.perform(options)
end

function VirtualHit.sweep(options: Sweep.SweepOptions): Sweep.Sweep
	return Sweep.new(options)
end

function VirtualHit.projectile(options: Projectile.ProjectileOptions): Projectile.Projectile
	return Projectile.new(options)
end

-- Reuses projectile bodies instead of building one per shot. The expensive part
-- of a projectile is its query geometry, and every shot from one weapon shares
-- it, so a pool is the difference between allocating probes at the fire rate
-- and allocating them once.
function VirtualHit.projectilePool(options: ProjectilePool.PoolOptions): ProjectilePool.Pool
	return ProjectilePool.new(options)
end

function VirtualHit.melee(options: MeleeHitbox.MeleeOptions): MeleeHitbox.MeleeHitbox
	return MeleeHitbox.new(options)
end

function VirtualHit.meleeGroup(options: MeleeGroup.MeleeGroupOptions): MeleeGroup.MeleeGroup
	return MeleeGroup.new(options)
end

function VirtualHit.zone(options: Zone.ZoneOptions): Zone.Zone
	return Zone.new(options)
end

-- A broadphase for zones. Anything a zone using this index must be able to
-- detect has to be tracked here, because the index is what decides whether the
-- real query runs at all.
function VirtualHit.zoneIndex(options: ZoneIndex.ZoneIndexOptions?): ZoneIndex.ZoneIndex
	return ZoneIndex.new(options)
end

-- Scales query resolution by distance to the nearest observer. It buys back
-- segments, never correctness: nothing is ever skipped, and a shot fired where
-- nobody is watching still resolves.
-- What a blocker does to a shot that reaches it: through, off, or stop, decided
-- from energy, angle and material. Give one to a projectile and a single flight
-- can cross glass, lose most of itself in a plank and glance off steel with
-- what is left -- one body, one state, one trajectory.
function VirtualHit.impactSolver(
	options: ImpactSolver.ImpactSolverOptions?
): ImpactSolver.ImpactSolver
	return ImpactSolver.new(options)
end

function VirtualHit.materialProfile(
	options: MaterialProfile.MaterialProfileOptions?
): MaterialProfile.MaterialProfileTable
	return MaterialProfile.new(options)
end

function VirtualHit.detail(options: DetailField.DetailFieldOptions?): DetailField.DetailField
	return DetailField.new(options)
end

function VirtualHit.rewind(options: RewindWorld.RewindOptions?): RewindWorld.RewindWorld
	return RewindWorld.new(options)
end

-- Bounds checking for an untrusted client shot claim. Accepting a claim means
-- it was plausible, never that it hit; the query run against the returned
-- WorldRoot is still what decides.
function VirtualHit.validator(options: Validator.ValidatorOptions): Validator.Validator
	return Validator.new(options)
end

--[[
	Sets library-wide defaults.

	Takes a partial table, a preset name, or a preset name followed by a table
	to adjust from there:

		VirtualHit.configure({ Sweep = { MaxSegments = 128 } })
		VirtualHit.configure("Performance")
		VirtualHit.configure("Fidelity", { Pierce = { MaxHits = 24 } })

	Nothing is written unless the whole patch validates, and every problem is
	reported at once. Per-call options still override these.
]]
function VirtualHit.configure(patch: any, extra: any?)
	Config.configure(patch, extra)
end

--- An immutable copy of every current setting, grouped by section.
function VirtualHit.getConfig(): { [string]: { [string]: any } }
	return Config.snapshot()
end

--- Restores the shipped defaults, for one section or all of them.
function VirtualHit.resetConfig(section: string?)
	Config.reset(section)
end

--- One setting, by `"Section.Field"`. The single-value twin of configure.
function VirtualHit.setConfig(path: string, value: any)
	Config.set(path, value)
end

--[[
	A temporary override that can be handed back.

		local slowMotion = VirtualHit.scopedConfig({
			Sweep = { MaxLinearStep = 0.25 },
		})
		...
		slowMotion:Release()

	Scopes stack and release in any order. `configure` during a scope changes
	the value the setting returns to, not the value in force.
]]
function VirtualHit.scopedConfig(overrides: any): Config.ConfigScope
	return Config.scoped(overrides)
end

--[[
	Drives the configuration from attributes on an Instance, so a designer can
	tune the library from Studio without touching code.

	Attributes are named `Section_Field` - `Sweep_MaxSegments`, `Pierce_MaxHits`
	- because an attribute name cannot contain a dot. Anything the schema does
	not recognise is warned about and skipped rather than failing the whole
	read, since one mistyped attribute should not switch off every other one
	on the same object.
]]
function VirtualHit.bindConfigTo(instance: Instance): Config.AttributeBinding
	return Config.bindToInstance(instance)
end

function VirtualHit.setEntityResolver(resolver: Types.EntityResolver?)
	Resolver.setDefault(resolver)
end

function VirtualHit.setZoneResolver(resolver: Types.ZoneResolver?)
	Resolver.setDefaultZone(resolver)
end

return VirtualHit
