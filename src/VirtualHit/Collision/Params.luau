--!strict

local Params = {}

local function appendUnique(target: { Instance }, additions: { Instance })
	local seen: { [Instance]: boolean } = {}

	for _, instance in target do
		seen[instance] = true
	end

	for _, instance in additions do
		if not seen[instance] then
			seen[instance] = true
			table.insert(target, instance)
		end
	end
end

-- FilterType and FilterDescendantsInstances are the whole story. IncludeInstances
-- and ExcludeInstances are aliases for the same pair, and reading either one
-- returns the list whatever the filter type is, so copying "the one that is set"
-- is not a thing that can be done: assigning either alias also rewrites
-- FilterType, which would silently turn an allowlist into a blocklist and let
-- the entire world back into the query.
function Params.cloneRaycast(source: RaycastParams?): RaycastParams
	local target = RaycastParams.new()

	if source == nil then
		return target
	end

	target.BruteForceAllSlow = source.BruteForceAllSlow
	target.CollisionGroup = source.CollisionGroup
	target.IgnoreWater = source.IgnoreWater
	target.RespectCanCollide = source.RespectCanCollide
	target.FilterType = source.FilterType
	target.FilterDescendantsInstances = table.clone(source.FilterDescendantsInstances)

	return target
end

-- Keeps the library's own debug probes out of a caller's query.

-- An allowlist needs no help: it already ignores everything it does not name,
-- and the probes are never named. Adding to it would be the one change that
-- actually breaks it.
function Params.withRaycastExclusions(
	source: RaycastParams?,
	exclusions: { Instance }
): RaycastParams
	local target = Params.cloneRaycast(source)

	if target.FilterType == Enum.RaycastFilterType.Include then
		return target
	end

	local excluded = table.clone(target.FilterDescendantsInstances)
	appendUnique(excluded, exclusions)
	target.FilterType = Enum.RaycastFilterType.Exclude
	target.FilterDescendantsInstances = excluded

	return target
end

function Params.cloneOverlap(source: OverlapParams?): OverlapParams
	local target = OverlapParams.new()

	if source == nil then
		return target
	end

	target.BruteForceAllSlow = source.BruteForceAllSlow
	target.CollisionGroup = source.CollisionGroup
	target.MaxParts = source.MaxParts
	target.RespectCanCollide = source.RespectCanCollide
	target.Tolerance = source.Tolerance
	target.FilterType = source.FilterType
	target.FilterDescendantsInstances = table.clone(source.FilterDescendantsInstances)

	return target
end

function Params.withOverlapExclusions(
	source: OverlapParams?,
	exclusions: { Instance }
): OverlapParams
	local target = Params.cloneOverlap(source)

	if target.FilterType == Enum.RaycastFilterType.Include then
		return target
	end

	local excluded = table.clone(target.FilterDescendantsInstances)
	appendUnique(excluded, exclusions)
	target.FilterType = Enum.RaycastFilterType.Exclude
	target.FilterDescendantsInstances = excluded

	return target
end

return Params
