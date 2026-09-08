--!strict

local Types = require(script.Parent.Parent.Types)
local Errors = require(script.Parent.Parent.Util.Errors)

local Resolver = {}

local defaultResolver: Types.EntityResolver? = nil
local defaultZoneResolver: Types.ZoneResolver? = nil

local function fail(message: string, code: string?): never
	return Errors.raise("VirtualHit entity resolver", code or "InvalidArgument", message, 3)
end

local function failZone(message: string, code: string?): never
	return Errors.raise("VirtualHit zone resolver", code or "InvalidArgument", message, 3)
end

local function validateResolver(resolver: Types.EntityResolver?)
	if resolver ~= nil and type(resolver) ~= "function" then
		fail("expected a function or nil")
	end
end

local function validateZoneResolver(resolver: Types.ZoneResolver?)
	if resolver ~= nil and type(resolver) ~= "function" then
		failZone("expected a function or nil")
	end
end

function Resolver.setDefault(resolver: Types.EntityResolver?)
	validateResolver(resolver)
	defaultResolver = resolver
end

function Resolver.setDefaultZone(resolver: Types.ZoneResolver?)
	validateZoneResolver(resolver)
	defaultZoneResolver = resolver
end

function Resolver.resolve(instance: BasePart, resolverOverride: Types.EntityResolver?): Instance?
	validateResolver(resolverOverride)

	local resolver = resolverOverride or defaultResolver

	if resolver == nil then
		return nil
	end

	local entity = resolver(instance)

	if entity ~= nil and typeof(entity) ~= "Instance" then
		fail("must return an Instance or nil")
	end

	return entity
end

-- Zone classification is deliberately independent of entity resolution: a part
-- can carry a zone with no entity (a destructible prop's weak point) and an
-- entity with no zone (a part the game does not divide into hit regions).
function Resolver.resolveZone(instance: BasePart, resolverOverride: Types.ZoneResolver?): string?
	validateZoneResolver(resolverOverride)

	local resolver = resolverOverride or defaultZoneResolver

	if resolver == nil then
		return nil
	end

	local zone = resolver(instance)

	if zone ~= nil and type(zone) ~= "string" then
		failZone("must return a string or nil")
	end

	return zone
end

-- `distanceOffset` is how far the cast origin had already been advanced when
-- this contact was found. A query that cannot leave a part behind by excluding
-- it resumes from beyond it instead, and the reported distance must still be
-- measured from where the caller aimed.
function Resolver.normalize(
	result: RaycastResult,
	resolverOverride: Types.EntityResolver?,
	zoneResolverOverride: Types.ZoneResolver?,
	distanceOffset: number?
): Types.HitResult
	local entity = Resolver.resolve(result.Instance, resolverOverride)
	local zone = Resolver.resolveZone(result.Instance, zoneResolverOverride)

	-- RaycastResult.Distance is intentionally copied instead of recomputed.
	-- For shape casts, Position is the contact point while Distance is how far
	-- the moving shape travelled before contact.
	return {
		Instance = result.Instance,
		Position = result.Position,
		Normal = result.Normal,
		Material = result.Material,
		Distance = result.Distance + (distanceOffset or 0),
		Entity = entity,
		Zone = zone,
	}
end

return Resolver
