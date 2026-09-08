--!strict

local InternalExclusions = require(script.Parent.InternalExclusions)
local Errors = require(script.Parent.Parent.Util.Errors)
local Config = require(script.Parent.Parent.Config)

-- Live config section. Read through it so VirtualHit.configure() takes
-- effect without reloading the library.
local Tuning = Config.Pool

local ShapeProbe = {}

-- Idle probes retained between leases. Long-lived sweeps return their probes
-- here too, so this now absorbs weapon and projectile churn rather than just
-- the scoped overlap helpers. Each retained probe is one anchored, transparent,
-- unqueryable Part.

type PrimitiveKind = "Block" | "Sphere"

local idlePrimitives: { Part } = {}
local leasedRoots: { [Part]: WorldRoot } = setmetatable({}, {
	__mode = "k",
}) :: any
local probeGuards: { [Part]: RBXScriptConnection } = setmetatable({}, {
	__mode = "k",
}) :: any
local discardedProbes: { [Part]: boolean } = setmetatable({}, {
	__mode = "k",
}) :: any
local scheduledDiscards: { [Part]: boolean } = setmetatable({}, {
	__mode = "k",
}) :: any

local function fail(message: string, code: string?): never
	return Errors.raise("VirtualHit shape probe", code or "InvalidArgument", message, 3)
end

local function configure(probe: BasePart): BasePart
	probe.Name = "__VirtualHitShapeProbe"
	probe:SetAttribute("VirtualHitShapeProbe", true)
	probe.Anchored = true
	probe.CanCollide = false
	probe.CanQuery = false
	probe.CanTouch = false
	probe.CastShadow = false
	probe.Transparency = 1

	return probe
end

local function parentProbe(probe: BasePart, worldRoot: WorldRoot): BasePart
	local success, message = pcall(function()
		InternalExclusions.Tag(probe)
		probe.Parent = worldRoot
		InternalExclusions.Register(worldRoot, probe)
	end)

	if not success then
		InternalExclusions.Unregister(worldRoot, probe)
		pcall(function()
			probe:Destroy()
		end)
		error(message, 0)
	end

	return probe
end

local function disconnectProbeGuard(probe: Part)
	local connection: RBXScriptConnection? = probeGuards[probe]

	if connection ~= nil then
		probeGuards[probe] = nil
		connection:Disconnect()
	end
end

local function markPrimitiveDiscarded(probe: Part)
	discardedProbes[probe] = true
	disconnectProbeGuard(probe)
	local index = table.find(idlePrimitives, probe)

	if index ~= nil then
		table.remove(idlePrimitives, index)
	end
end

local function discardIdlePrimitive(probe: Part)
	markPrimitiveDiscarded(probe)

	-- A Parent guard may already have deferred destruction from inside a
	-- property-change callback. Never attempt the same reentrant write again.
	if scheduledDiscards[probe] then
		return
	end

	pcall(function()
		probe:Destroy()
	end)
end

local function deferIdlePrimitiveDiscard(probe: Part)
	markPrimitiveDiscarded(probe)

	if scheduledDiscards[probe] then
		return
	end

	scheduledDiscards[probe] = true
	task.defer(function()
		scheduledDiscards[probe] = nil
		pcall(function()
			probe:Destroy()
		end)
	end)
end

local function activatePrimitive(
	probe: Part,
	kind: PrimitiveKind,
	worldRoot: WorldRoot,
	cframe: CFrame,
	size: Vector3
): (boolean, any)
	leasedRoots[probe] = worldRoot

	local success, message = pcall(function()
		if discardedProbes[probe] then
			error("discarded primitive probe cannot be activated")
		end

		if probe.Parent ~= nil then
			error("idle primitive probe was unexpectedly reparented")
		end

		configure(probe)
		probe.Shape = if kind == "Sphere" then Enum.PartType.Ball else Enum.PartType.Block
		probe.Size = size
		probe.CFrame = cframe

		-- Tag before parenting so another VM, or a reentrant descendant
		-- listener, never observes queryable internal geometry.
		InternalExclusions.Tag(probe)
		probe.Parent = worldRoot
		InternalExclusions.Register(worldRoot, probe)
	end)

	if not success then
		leasedRoots[probe] = nil
		InternalExclusions.Unregister(worldRoot, probe)
		discardIdlePrimitive(probe)
	end

	return success, message
end

local function acquirePrimitive(
	kind: PrimitiveKind,
	worldRoot: WorldRoot,
	cframe: CFrame,
	size: Vector3
): Part
	local pooled = table.remove(idlePrimitives)

	if pooled ~= nil then
		local success = activatePrimitive(pooled, kind, worldRoot, cframe, size)

		if success then
			return pooled
		end
	end

	local probe = Instance.new("Part")
	local success, message = activatePrimitive(probe, kind, worldRoot, cframe, size)

	if not success then
		error(message, 0)
	end

	return probe
end

local function releasePrimitive(probe: Part)
	local worldRoot: WorldRoot? = leasedRoots[probe]

	if worldRoot == nil then
		fail("primitive probe has no active lease")
	end
	local leaseRoot = worldRoot :: WorldRoot

	-- Close ownership before unparenting. Descendant-removal callbacks may
	-- reenter VirtualHit, but cannot obtain or release this probe twice.
	leasedRoots[probe] = nil
	local inspected, parentOrMessage = pcall(function()
		return probe.Parent
	end)

	-- A callback or WorldRoot teardown may already have destroyed/reparented
	-- the probe. It is no longer ours to pool, but this is still a successful
	-- cleanup as long as no leased descendant is left behind.
	if not inspected or parentOrMessage ~= leaseRoot then
		InternalExclusions.Unregister(leaseRoot, probe)
		discardIdlePrimitive(probe)
		return
	end

	local success, message = pcall(function()
		probe.Parent = nil
	end)
	InternalExclusions.Unregister(leaseRoot, probe)

	if not success then
		discardIdlePrimitive(probe)
		error(message, 0)
	end

	local detached, finalParent = pcall(function()
		return probe.Parent
	end)

	if not detached or finalParent ~= nil then
		discardIdlePrimitive(probe)
		return
	end

	if #idlePrimitives >= Tuning.MaxIdlePrimitives then
		discardIdlePrimitive(probe)
		return
	end

	if discardedProbes[probe] then
		discardIdlePrimitive(probe)
		return
	end

	table.insert(idlePrimitives, probe)

	-- Keep one guard for the probe's whole pooled lifetime. Active Parent changes
	-- are ignored through leasedRoots, avoiding connection churn per checkout.
	local guard: RBXScriptConnection? = probeGuards[probe]

	if guard == nil then
		probeGuards[probe] = probe:GetPropertyChangedSignal("Parent"):Connect(function()
			local leasedRoot: WorldRoot? = leasedRoots[probe]

			if leasedRoot == nil and probe.Parent ~= nil then
				-- Destroy() writes Parent = nil. Doing that synchronously from the
				-- Parent signal is rejected by Roblox as a reentrant Parent change.
				-- Remove ownership immediately, then destroy after this signal unwinds.
				deferIdlePrimitiveDiscard(probe)
			end
		end)
	end
end

-- xpcall is typed to return the callee's own results after the boolean, and
-- these callees return nothing; on failure the second value is the handler's
-- capture. Naming the real shape is what lets it be bound and then cast.
local guardedProbe: (() -> (), (any) -> Errors.Captured) -> (boolean, any) = xpcall :: any

local function withPrimitive<T>(
	kind: PrimitiveKind,
	worldRoot: WorldRoot,
	cframe: CFrame,
	size: Vector3,
	callback: (BasePart) -> T
): T
	local probe = acquirePrimitive(kind, worldRoot, cframe, size)
	local callbackResult: T? = nil
	local callbackSuccess, callbackCapture = guardedProbe(function()
		callbackResult = callback(probe)
	end, Errors.capture)
	local cleanupSuccess, cleanupCapture = guardedProbe(function()
		releasePrimitive(probe)
	end, Errors.capture)

	if not callbackSuccess then
		local captured = callbackCapture :: Errors.Captured

		if cleanupSuccess then
			-- Rethrown as it was thrown, so a code raised inside the callback --
			-- a Filter predicate breaking its contract, say -- survives the
			-- probe lease that happened to be wrapped around it.
			Errors.rethrow(captured)
		end

		-- Two failures at once cannot both be rethrown, so this collapses to a
		-- string naming both. Losing the code is the lesser harm when the probe
		-- pool itself is broken.
		local cleanup = cleanupCapture :: Errors.Captured
		error(`{captured.Trace}\nVirtualHit shape probe cleanup failed:\n{cleanup.Trace}`, 0)
	end

	if not cleanupSuccess then
		Errors.rethrow(cleanupCapture :: Errors.Captured)
	end

	return callbackResult :: T
end

function ShapeProbe.cframeForOrigin(
	source: BasePart,
	origin: Vector3 | CFrame,
	offset: CFrame
): CFrame
	if typeof(origin) == "CFrame" then
		return origin * offset
	end

	return CFrame.new(origin) * source.CFrame.Rotation * offset
end

function ShapeProbe.clone(source: BasePart): BasePart
	if source:IsA("Terrain") then
		fail("Terrain cannot be used as a shape")
	end

	local wasArchivable = source.Archivable

	if not wasArchivable then
		source.Archivable = true
	end

	local success, cloned = pcall(function()
		return source:Clone()
	end)

	if not wasArchivable then
		source.Archivable = false
	end

	if not success then
		fail(`could not clone {source:GetFullName()}: {tostring(cloned)}`)
	end

	local probe = cloned :: BasePart

	for _, child in probe:GetChildren() do
		child:Destroy()
	end

	return configure(probe)
end

function ShapeProbe.create(source: BasePart, worldRoot: WorldRoot, cframe: CFrame): BasePart
	local probe = ShapeProbe.clone(source)
	probe.CFrame = cframe
	return parentProbe(probe, worldRoot)
end

-- Long-lived leases on the same idle pool the scoped helpers use. A Sweep holds
-- its probes for its whole lifetime, so without this every projectile spawn
-- created and destroyed one Instance per member: at a few hundred rounds a
-- minute that is pure Instance churn for geometry that is always the same.
function ShapeProbe.acquireSphere(worldRoot: WorldRoot, radius: number): BasePart
	local diameter = radius * 2
	return acquirePrimitive(
		"Sphere",
		worldRoot,
		CFrame.identity,
		Vector3.new(diameter, diameter, diameter)
	)
end

function ShapeProbe.acquireBlock(worldRoot: WorldRoot, size: Vector3): BasePart
	return acquirePrimitive("Block", worldRoot, CFrame.identity, size)
end

-- Returns a leased primitive to the pool, or destroys a cloned Part probe.
-- Callers hold one release per acquire and never need to know which they got.
function ShapeProbe.release(probe: BasePart)
	local pooledRoot: WorldRoot? = leasedRoots[probe :: Part]

	if pooledRoot ~= nil then
		releasePrimitive(probe :: Part)
		return
	end

	probe:Destroy()
end

function ShapeProbe.withBlock<T>(
	worldRoot: WorldRoot,
	cframe: CFrame,
	size: Vector3,
	callback: (BasePart) -> T
): T
	return withPrimitive("Block", worldRoot, cframe, size, callback)
end

function ShapeProbe.withSphere<T>(
	worldRoot: WorldRoot,
	position: Vector3,
	radius: number,
	callback: (BasePart) -> T
): T
	local diameter = radius * 2
	return withPrimitive(
		"Sphere",
		worldRoot,
		CFrame.new(position),
		Vector3.new(diameter, diameter, diameter),
		callback
	)
end

return ShapeProbe
