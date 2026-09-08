--!strict

local HitPolicy = require(script.Parent.HitPolicy)
local Errors = require(script.Parent.Parent.Util.Errors)

local HitRegistry = {}
HitRegistry.__index = HitRegistry

-- A Cooldown entry older than the cooldown answers exactly the same as no entry
-- at all, so keeping it costs memory and buys nothing. A per-swing registry
-- never grows far enough to care; a long-lived global Cooldown registry would
-- otherwise hold every key it ever saw, destroyed Instances included.
local PRUNE_FLOOR = 64

-- Once accepts the first candidate and nothing else, so it has no key of its
-- own. This stands in for one, because a caller batching keys ahead of the
-- commit needs a non-nil value per candidate whatever the policy is.
local ONCE_KEY = table.freeze({})

export type Clock = () -> number

-- The candidate a key is derived from. Kept untyped here so the same registry
-- can be shared by Sweep candidates and any other producer that carries an
-- Instance and an optional Entity.
export type HitKey = (candidate: any) -> any

export type HitRegistry = typeof(setmetatable(
	{} :: {
		_policy: HitPolicy.Policy,
		_clock: Clock,
		_hitKey: HitKey?,
		_hasHit: boolean,
		_seen: { [any]: boolean },
		_lastHit: { [any]: number },
		_trackedKeys: number,
		_pruneAt: number,
	},
	HitRegistry
))

local function fail(message: string, code: string?): never
	return Errors.raise("VirtualHit HitRegistry", code or "InvalidArgument", message, 3)
end

local function normalizePolicy(policy: HitPolicy.Policy): HitPolicy.Policy
	if
		policy == "Once"
		or policy == "OncePerEntity"
		or policy == "OncePerPart"
		or policy == "OncePerKey"
	then
		-- Narrowing leaves an intersection of the policy union with the four
		-- string cases, which the solver will not hand back as the union it came
		-- from. The value is unchanged; only its spelling is.
		return policy :: HitPolicy.Policy
	end

	if type(policy) ~= "table" or policy.Type ~= "Cooldown" then
		fail("invalid policy")
	end

	-- Capture caller-owned descriptor fields exactly once. Besides preventing
	-- later mutation from changing registry behavior, this keeps validation and
	-- storage consistent for tables with metatable-backed property access.
	local seconds = policy.Seconds

	if type(seconds) ~= "number" or seconds ~= seconds or seconds <= 0 or seconds == math.huge then
		fail("invalid policy")
	end

	local snapshot: HitPolicy.CooldownPolicy = {
		Type = "Cooldown",
		Seconds = seconds,
	}
	return table.freeze(snapshot)
end

-- A custom key replaces the identity the policy would otherwise use, so it can
-- only be paired with policies whose scope is defined by that identity. Pairing
-- it with OncePerEntity or OncePerPart would make those two names describe the
-- same behavior, which is exactly the ambiguity OncePerKey exists to remove.
local function validatePairing(policy: HitPolicy.Policy, hitKey: HitKey?)
	if hitKey == nil then
		if policy == "OncePerKey" then
			fail("OncePerKey requires a HitKey", "RegistryConflict")
		end

		return
	end

	if type(hitKey) ~= "function" then
		fail("HitKey must be a function")
	end

	if policy == "OncePerKey" then
		return
	end

	if type(policy) == "table" and policy.Type == "Cooldown" then
		return
	end

	fail(
		`HitKey can only be used with OncePerKey or Cooldown, not {tostring(policy)}`,
		"RegistryConflict"
	)
end

function HitRegistry.new(policy: HitPolicy.Policy, clock: Clock?, hitKey: HitKey?): HitRegistry
	local storedPolicy: HitPolicy.Policy = normalizePolicy(policy)

	if clock ~= nil and type(clock) ~= "function" then
		fail("clock must be a function")
	end

	validatePairing(storedPolicy, hitKey)

	return setmetatable({
		_policy = storedPolicy,
		_clock = clock or os.clock,
		_hitKey = hitKey,
		_hasHit = false,
		_seen = {},
		_lastHit = {},
		_trackedKeys = 0,
		_pruneAt = PRUNE_FLOOR,
	}, HitRegistry)
end

function HitRegistry.GetPolicy(self: HitRegistry): HitPolicy.Policy
	return self._policy
end

-- A fresh registry with the same rule and no history. A group that has to
-- decide acceptance in physical order gives each member a clone to dedup
-- within itself, then applies the authoritative registry once the whole frame
-- is sorted.
function HitRegistry.Clone(self: HitRegistry): HitRegistry
	return setmetatable({
		_policy = self._policy,
		_clock = self._clock,
		_hitKey = self._hitKey,
		_hasHit = false,
		_seen = {},
		_lastHit = {},
		_trackedKeys = 0,
		_pruneAt = PRUNE_FLOOR,
	}, HitRegistry)
end

local function pruneExpired(self: HitRegistry, now: number, seconds: number)
	local live = 0

	for key, lastHit in self._lastHit do
		if now - lastHit >= seconds then
			self._lastHit[key] = nil
		else
			live += 1
		end
	end

	self._trackedKeys = live
	-- Waiting for the live set to double keeps this amortised: pruning at a
	-- fixed size would sweep on every insert once the live set stopped
	-- shrinking.
	self._pruneAt = math.max(live * 2, PRUNE_FLOOR)
end

-- The key this candidate would be accepted under, computed without touching
-- anything.

-- Split out of Accept so a caller's HitKey runs ahead of every mutation.
-- HitPriority and HitResponse are already ordered entirely before the registry
-- is written to; a key derived by caller code has to be too. Otherwise a HitKey
-- that throws on the third candidate leaves the first two consumed by a Step
-- that reported failure, and the caller has no way to put them back.
function HitRegistry.KeyFor(
	self: HitRegistry,
	instance: BasePart,
	entity: Instance?,
	candidate: any?
): any
	local policy = self._policy

	if policy == "Once" then
		-- Once does not key on anything, but it still has to hand back
		-- something non-nil so a caller can hold one key per candidate.
		return ONCE_KEY
	end

	local hitKey = self._hitKey

	if hitKey ~= nil then
		local key = hitKey(candidate)

		if key == nil then
			fail("HitKey must return a non-nil value", "CallbackContract")
		end

		return key
	end

	if policy == "OncePerPart" then
		return instance
	end

	return entity or instance
end

-- Commits a key that KeyFor produced. No caller code runs in here, so nothing
-- between the first mutation and the last can fail.
function HitRegistry.AcceptKey(self: HitRegistry, key: any): boolean
	local policy = self._policy

	if policy == "Once" then
		if self._hasHit then
			return false
		end

		self._hasHit = true
		return true
	end

	if policy == "OncePerEntity" or policy == "OncePerPart" or policy == "OncePerKey" then
		if self._seen[key] then
			return false
		end

		self._seen[key] = true
		return true
	end

	local now = self._clock()
	local lastHit = self._lastHit[key]
	local cooldown = policy :: HitPolicy.CooldownPolicy

	if lastHit ~= nil and now - lastHit < cooldown.Seconds then
		return false
	end

	if lastHit == nil then
		if self._trackedKeys >= self._pruneAt then
			pruneExpired(self, now, cooldown.Seconds)
		end

		self._trackedKeys += 1
	end

	self._lastHit[key] = now
	return true
end

-- Both halves in one call, for a caller that is not walking an ordered batch
-- and has nothing to roll back.
function HitRegistry.Accept(
	self: HitRegistry,
	instance: BasePart,
	entity: Instance?,
	candidate: any?
): boolean
	return self:AcceptKey(self:KeyFor(instance, entity, candidate))
end

function HitRegistry.Reset(self: HitRegistry)
	self._hasHit = false
	table.clear(self._seen)
	table.clear(self._lastHit)
	self._trackedKeys = 0
	self._pruneAt = PRUNE_FLOOR
end

return HitRegistry
