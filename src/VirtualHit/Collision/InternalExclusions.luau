--!strict

local CollectionService = game:GetService("CollectionService")

local Errors = require(script.Parent.Parent.Util.Errors)

local InternalExclusions = {}

type ExclusionSet = { [Instance]: boolean }

-- This tag is intentionally stable: server-created artifacts can replicate
-- into a client or another Actor VM whose weak registry has independent state.
local TAG_NAME = "VirtualHitInternalQueryExclusion"

-- Weak WorldRoot and Instance keys let destroyed internal artifacts disappear
-- without a global descendant scan or an explicit unregister lifecycle.
local exclusionsByWorldRoot: { [WorldRoot]: ExclusionSet } = setmetatable({}, {
	__mode = "k",
}) :: any

-- Bumped whenever the registry changes shape. Long-lived callers cache the
-- collected array and the query params built from it, and only rebuild when
-- this number moves. One integer comparison replaces a weak-table walk and two
-- engine object allocations per Step.
local generation = 0

-- Collecting used to allocate an array and a membership set on every query.
-- In production the registry is empty -- probes exist only while the debug
-- visualiser is running -- so that was two tables per cast to describe nothing.
-- The buffer below is reused instead, and a nested call (a predicate that
-- casts again) simply takes a fresh one rather than sharing it.
local sharedBuffer: { Instance } = {}
local sharedBufferBusy = false
local sharedSeen: ExclusionSet = {}

local function fail(message: string, code: string?): never
	return Errors.raise("VirtualHit internal exclusions", code or "InvalidArgument", message, 3)
end

function InternalExclusions.GetGeneration(): number
	return generation
end

function InternalExclusions.Tag(instance: Instance)
	if typeof(instance) ~= "Instance" then
		fail("instance must be an Instance")
	end

	CollectionService:AddTag(instance, TAG_NAME)
end

function InternalExclusions.Register(worldRoot: WorldRoot, instance: Instance)
	if typeof(worldRoot) ~= "Instance" or not worldRoot:IsA("WorldRoot") then
		fail("worldRoot must be a Workspace or WorldModel")
	end

	if typeof(instance) ~= "Instance" or not instance:IsDescendantOf(worldRoot) then
		fail("instance must be a descendant of worldRoot")
	end

	InternalExclusions.Tag(instance)

	local exclusions = exclusionsByWorldRoot[worldRoot]

	if exclusions == nil then
		exclusions = setmetatable({}, {
			__mode = "k",
		}) :: any
		exclusionsByWorldRoot[worldRoot] = exclusions
	end

	if not exclusions[instance] then
		exclusions[instance] = true
		generation += 1
	end
end

function InternalExclusions.Unregister(worldRoot: WorldRoot, instance: Instance)
	local exclusions = exclusionsByWorldRoot[worldRoot]

	if exclusions ~= nil and exclusions[instance] ~= nil then
		exclusions[instance] = nil
		generation += 1
	end
end

-- Appends into a caller-owned array and returns how many were added, so a
-- long-lived caller can keep one buffer instead of allocating per query.
function InternalExclusions.CollectInto(
	worldRoot: WorldRoot,
	includeTagged: boolean?,
	target: { Instance }
): number
	local added = 0
	local exclusions = exclusionsByWorldRoot[worldRoot]
	local scanTags = includeTagged == true

	if scanTags then
		-- Cleared going in as well as coming out, so a collection that died
		-- half way through can never poison the next one.
		table.clear(sharedSeen)
	end

	if exclusions ~= nil then
		for instance in exclusions do
			if instance:IsDescendantOf(worldRoot) then
				added += 1
				table.insert(target, instance)

				if scanTags then
					sharedSeen[instance] = true
				end
			else
				-- A destroyed or reparented artifact is no longer ours to
				-- exclude. Dropping it is a registry change like any other.
				exclusions[instance] = nil
				generation += 1
			end
		end
	end

	if scanTags then
		for _, instance in CollectionService:GetTagged(TAG_NAME) do
			if not sharedSeen[instance] and instance:IsDescendantOf(worldRoot) then
				sharedSeen[instance] = true
				added += 1
				table.insert(target, instance)
			end
		end

		-- The membership set only exists to dedupe the tag scan against the
		-- registry, so it never outlives one collection.
		table.clear(sharedSeen)
	end

	return added
end

-- Borrows the shared buffer, fills it, and reports how many it holds. The
-- caller must Release() once the contents have been copied into query params.
function InternalExclusions.Acquire(
	worldRoot: WorldRoot,
	includeTagged: boolean?
): ({ Instance }, number)
	local target: { Instance }

	if sharedBufferBusy then
		target = {}
	else
		sharedBufferBusy = true
		target = sharedBuffer
		table.clear(target)
	end

	return target, InternalExclusions.CollectInto(worldRoot, includeTagged, target)
end

function InternalExclusions.Release(buffer: { Instance })
	if buffer == sharedBuffer then
		sharedBufferBusy = false
	end
end

return InternalExclusions
