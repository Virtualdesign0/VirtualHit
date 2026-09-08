--!strict

local CollectionService = game:GetService("CollectionService")

local Types = require(script.Parent.Parent.Types)
local Errors = require(script.Parent.Parent.Util.Errors)
local Config = require(script.Parent.Parent.Config)

-- Live config section. Read through it so VirtualHit.configure() takes effect
-- without reloading the library.
local Tuning = Config.Filter

local Filter = {}
Filter.__index = Filter

export type Filter = typeof(setmetatable(
	{} :: {
		_included: { Instance }?,
		_excluded: { Instance },
		_includedSeen: { [Instance]: boolean },
		_excludedSeen: { [Instance]: boolean },
		_includedTags: { string },
		_excludedTags: { string },
		_includedTagsSeen: { [string]: boolean },
		_excludedTagsSeen: { [string]: boolean },
		_collisionGroup: string?,
		_ignoreWater: boolean,
		_respectCanCollide: boolean,
		_maxParts: number,
		_tolerance: number,
		_predicate: Types.Predicate?,
		_maxPredicateRetries: number,
		_version: number,
		_leasedRaycast: RaycastParams?,
		_leasedRaycastVersion: number,
		_leasedOverlap: OverlapParams?,
		_leasedOverlapVersion: number,
	},
	Filter
))

local function fail(message: string, code: string?): never
	return Errors.raise("VirtualHit.Filter", code or "InvalidArgument", message, 3)
end

local function isFiniteNumber(value: number): boolean
	return value == value and value > -math.huge and value < math.huge
end

function Filter.new(): Filter
	return (
		setmetatable({
			_included = nil,
			_excluded = {},
			_includedSeen = {},
			_excludedSeen = {},
			_includedTags = {},
			_excludedTags = {},
			_includedTagsSeen = {},
			_excludedTagsSeen = {},
			_collisionGroup = nil,
			_ignoreWater = false,
			_respectCanCollide = false,
			_maxParts = 0,
			_tolerance = 0,
			_predicate = nil,
			_maxPredicateRetries = Tuning.MaxPredicateRetries,
			_version = 0,
			_leasedRaycast = nil,
			_leasedRaycastVersion = -1,
			_leasedOverlap = nil,
			_leasedOverlapVersion = -1,
		}, Filter) :: any
	) :: Filter
end

-- A filter is a mutable builder, so sharing one between two weapons couples
-- them. Clone gives a variant an independent copy of every list.
function Filter.Clone(self: Filter): Filter
	local copy = Filter.new()

	copy._excluded = table.clone(self._excluded)
	copy._excludedSeen = table.clone(self._excludedSeen)
	local included = self._included

	if included ~= nil then
		copy._included = table.clone(included)
		copy._includedSeen = table.clone(self._includedSeen)
	end

	copy._includedTags = table.clone(self._includedTags)
	copy._excludedTags = table.clone(self._excludedTags)
	copy._includedTagsSeen = table.clone(self._includedTagsSeen)
	copy._excludedTagsSeen = table.clone(self._excludedTagsSeen)
	copy._collisionGroup = self._collisionGroup
	copy._ignoreWater = self._ignoreWater
	copy._respectCanCollide = self._respectCanCollide
	copy._maxParts = self._maxParts
	copy._tolerance = self._tolerance
	copy._predicate = self._predicate
	copy._maxPredicateRetries = self._maxPredicateRetries

	return copy
end

function Filter.Exclude(self: Filter, instance: Instance): Filter
	if typeof(instance) ~= "Instance" then
		fail("Exclude expects an Instance")
	end

	if not self._excludedSeen[instance] then
		self._excludedSeen[instance] = true
		table.insert(self._excluded, instance)
		self._version += 1
	end

	return self
end

function Filter.Include(self: Filter, instance: Instance): Filter
	if typeof(instance) ~= "Instance" then
		fail("Include expects an Instance")
	end

	if not self._includedSeen[instance] then
		self._includedSeen[instance] = true
		local included = self._included

		if included == nil then
			included = {}
			self._included = included
		end

		assert(included ~= nil, "the include list vanished between the check and the insert")
		table.insert(included, instance)
		self._version += 1
	end

	return self
end

local function validateTag(tag: string, method: string)
	if type(tag) ~= "string" or tag == "" then
		error(`VirtualHit.Filter: {method} expects a non-empty tag name`, 4)
	end
end

-- Tag membership is resolved on every Build, not when the tag is registered.
-- A Sweep rebuilds its params each Step, so tagging a part mid-swing takes
-- effect on the next Step. The cost is one CollectionService:GetTagged call
-- per configured tag per build; a filter with no tags pays nothing.
function Filter.IncludeTagged(self: Filter, tag: string): Filter
	validateTag(tag, "IncludeTagged")

	if not self._includedTagsSeen[tag] then
		self._includedTagsSeen[tag] = true
		table.insert(self._includedTags, tag)
		self._version += 1
	end

	return self
end

function Filter.ExcludeTagged(self: Filter, tag: string): Filter
	validateTag(tag, "ExcludeTagged")

	if not self._excludedTagsSeen[tag] then
		self._excludedTagsSeen[tag] = true
		table.insert(self._excludedTags, tag)
		self._version += 1
	end

	return self
end

-- Engine include/exclude lists are instance-based; anything that depends on a
-- part's own properties has to run after the query. A predicate removes a part
-- from consideration exactly as if the engine had never returned it: cast
-- re-queries past it, overlap drops it, sweep does not collect it.
function Filter.Predicate(self: Filter, predicate: Types.Predicate?): Filter
	if predicate ~= nil and type(predicate) ~= "function" then
		fail("Predicate expects a function or nil")
	end

	self._predicate = predicate
	self._version += 1
	return self
end

-- Bounds the re-query loop a rejecting predicate forces on a single cast.
function Filter.MaxPredicateRetries(self: Filter, value: number): Filter
	if type(value) ~= "number" or not isFiniteNumber(value) or value < 0 or value % 1 ~= 0 then
		fail("MaxPredicateRetries expects a non-negative integer")
	end

	self._maxPredicateRetries = value
	self._version += 1
	return self
end

-- Bumped by every mutator. A long-lived query object caches the params it built
-- and only rebuilds when this moves, which turns two engine object allocations
-- per Step into one integer comparison.
function Filter.GetVersion(self: Filter): number
	return self._version
end

-- Tag membership is resolved at build time from CollectionService, so a filter
-- with tags can produce a different result without any mutation of its own.
-- Those filters are never cacheable.
function Filter.IsVolatile(self: Filter): boolean
	return #self._includedTags > 0 or #self._excludedTags > 0
end

function Filter.GetPredicate(self: Filter): Types.Predicate?
	return self._predicate
end

function Filter.GetMaxPredicateRetries(self: Filter): number
	return self._maxPredicateRetries
end

function Filter.CollisionGroup(self: Filter, name: string): Filter
	if type(name) ~= "string" or name == "" then
		fail("CollisionGroup expects a non-empty string")
	end

	self._collisionGroup = name
	self._version += 1
	return self
end

function Filter.IgnoreWater(self: Filter, value: boolean): Filter
	if type(value) ~= "boolean" then
		fail("IgnoreWater expects a boolean")
	end

	self._ignoreWater = value
	self._version += 1
	return self
end

function Filter.RespectCanCollide(self: Filter, value: boolean): Filter
	if type(value) ~= "boolean" then
		fail("RespectCanCollide expects a boolean")
	end

	self._respectCanCollide = value
	self._version += 1
	return self
end

function Filter.MaxParts(self: Filter, value: number): Filter
	if type(value) ~= "number" or not isFiniteNumber(value) or value < 0 or value % 1 ~= 0 then
		fail("MaxParts expects a non-negative integer")
	end

	self._maxParts = value
	self._version += 1
	return self
end

function Filter.Tolerance(self: Filter, value: number): Filter
	if type(value) ~= "number" or not isFiniteNumber(value) or value < 0 or value > 0.05 then
		fail("Tolerance expects a finite number from 0 through 0.05")
	end

	self._tolerance = value
	self._version += 1
	return self
end

local function resolveTagged(
	tags: { string },
	base: { Instance }?,
	seen: { [Instance]: boolean }
): { Instance }?
	if #tags == 0 then
		return if base == nil then nil else table.clone(base)
	end

	local resolved: { Instance } = if base == nil then {} else table.clone(base)
	local resolvedSeen: { [Instance]: boolean } = table.clone(seen)

	for _, tag in tags do
		for _, instance in CollectionService:GetTagged(tag) do
			if not resolvedSeen[instance] then
				resolvedSeen[instance] = true
				table.insert(resolved, instance)
			end
		end
	end

	return resolved
end

-- A query carries one list and one FilterType, never both an allowlist and a
-- blocklist, so an include list replaces the exclude list rather than joining
-- it. Only FilterType and FilterDescendantsInstances are written here: the
-- IncludeInstances and ExcludeInstances aliases assign FilterType as a side
-- effect, which is how an allowlist quietly becomes a blocklist.
local function applyCommon(self: Filter, params: any)
	local included = resolveTagged(self._includedTags, self._included, self._includedSeen)

	if included ~= nil then
		params.FilterType = Enum.RaycastFilterType.Include
		params.FilterDescendantsInstances = included
	else
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = resolveTagged(
			self._excludedTags,
			self._excluded,
			self._excludedSeen
		) or {}
	end

	if self._collisionGroup ~= nil then
		params.CollisionGroup = self._collisionGroup
	end

	params.RespectCanCollide = self._respectCanCollide
end

function Filter.BuildRaycastParams(self: Filter): RaycastParams
	local params = RaycastParams.new()
	applyCommon(self, params)
	params.IgnoreWater = self._ignoreWater

	return params
end

function Filter.BuildOverlapParams(self: Filter): OverlapParams
	local params = OverlapParams.new()
	applyCommon(self, params)
	params.MaxParts = self._maxParts
	params.Tolerance = self._tolerance

	return params
end

-- Tag membership is read from the live registry on every build and nothing
-- bumps the version when somebody tags an instance elsewhere, so a filter that
-- uses tags is rebuilt every time and never reused.
local function reusable(self: Filter): boolean
	return #self._includedTags == 0 and #self._excludedTags == 0
end

-- A library-owned params object for the duration of one query.
--
-- BuildRaycastParams is a snapshot: the caller owns it and may do what it likes
-- with it, which is why it allocates an engine object every call. Two hundred
-- players firing is two hundred of those a frame, for a description that has
-- not changed since the weapon was built. The lease returns the same object
-- until the filter itself changes.
--
-- Nothing inside the library mutates a leased object -- every path that needs
-- to add exclusions clones first -- so two queries holding the same lease at
-- once are both correct. It is internal precisely because that invariant
-- cannot be asked of a caller.
function Filter._leaseRaycastParams(self: Filter): RaycastParams
	if not reusable(self) then
		return self:BuildRaycastParams()
	end

	local leased = self._leasedRaycast

	-- Building returns directly rather than falling through to the shared
	-- return: the cache slot is optional, and returning the value that was just
	-- built says so without the reader having to prove the slot was filled.
	if leased == nil or self._leasedRaycastVersion ~= self._version then
		local built = self:BuildRaycastParams()
		self._leasedRaycast = built
		self._leasedRaycastVersion = self._version

		return built
	end

	return leased
end

function Filter._leaseOverlapParams(self: Filter): OverlapParams
	if not reusable(self) then
		return self:BuildOverlapParams()
	end

	local leased = self._leasedOverlap

	-- Building returns directly rather than falling through to the shared
	-- return: the cache slot is optional, and returning the value that was just
	-- built says so without the reader having to prove the slot was filled.
	if leased == nil or self._leasedOverlapVersion ~= self._version then
		local built = self:BuildOverlapParams()
		self._leasedOverlap = built
		self._leasedOverlapVersion = self._version

		return built
	end

	return leased
end

-- Backwards-compatible v0.1 alias. New code should use the explicit builder.
function Filter.Build(self: Filter): RaycastParams
	return self:BuildRaycastParams()
end

return Filter
