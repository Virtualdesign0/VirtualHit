--!strict

local Errors = require(script.Parent.Parent.Util.Errors)

-- What a material does to a shot that reaches it.

-- The penetration cost table already in the library answers one question --
-- how much budget a stud of this material spends -- and that is enough for a
-- single hitscan line. A projectile that has to keep flying afterwards needs
-- three more answers: whether a failed penetration deflects instead of
-- stopping, how much energy a deflection keeps, and how far a shot that got
-- through is knocked off course.

-- The numbers are game-tuned, not physical. Resistance is energy absorbed per
-- stud actually crossed, on the same relative scale the cost table already
-- uses, so glass stays cheap and granite stays expensive. What matters is that
-- the same shot meeting the same wall twice answers the same way, and that the
-- ordering between materials is the one a player would expect.

local MaterialProfile = {}
MaterialProfile.__index = MaterialProfile

-- A shot needs this much energy per stud of steel. Everything else is scaled
-- against it, so tuning one weapon's mass and speed tunes the whole table.
local BASE_RESISTANCE = 60

export type Profile = {
	-- Energy absorbed per stud of material actually crossed.
	read Resistance: number,
	-- Below this angle from the surface, a shot that could not get through
	-- glances off instead of stopping. Zero means this material never
	-- ricochets: a shot either goes through or stops dead.
	read RicochetBelow: number,
	-- Fraction of the incoming energy a glance keeps.
	read Retention: number,
	-- How far a shot that got through may be knocked off course, in radians.
	-- Zero -- the default for most materials -- keeps a flight deterministic
	-- without needing a seeded Random.
	read Deflection: number,
}

export type ProfileOverride = {
	Resistance: number?,
	RicochetBelow: number?,
	Retention: number?,
	Deflection: number?,
}

export type MaterialProfileOptions = {
	Profiles: { [Enum.Material]: ProfileOverride }?,
	-- Read from a part when present, the way the cost table reads its own
	-- attribute: a specific pane of armoured glass can be harder than glass.
	Attribute: string?,
}

export type MaterialProfileTable = typeof(setmetatable(
	{} :: {
		_profiles: { [Enum.Material]: Profile },
		_attribute: string,
	},
	MaterialProfile
))

local function fail(message: string, code: string?): never
	return Errors.raise("VirtualHit.materialProfile", code or "InvalidArgument", message, 3)
end

local function isFiniteNumber(value: number): boolean
	return value == value and value > -math.huge and value < math.huge
end

local function profile(
	resistance: number,
	ricochetBelow: number,
	retention: number,
	deflection: number
): Profile
	return table.freeze({
		Resistance = resistance * BASE_RESISTANCE,
		RicochetBelow = ricochetBelow,
		Retention = retention,
		Deflection = deflection,
	})
end

local SHALLOW = math.rad(20)
local FAIRLY_SHALLOW = math.rad(30)
local STEEP = math.rad(45)

-- Resistance multipliers track the penetration cost table so the two describe
-- the same world. Ricochet behaviour does not: what decides whether a shot
-- glances is hardness and surface, not how much of the shot a stud eats.
-- Water is cheap to cross and still skips a bullet at a shallow enough angle;
-- fabric is cheap and never does.
local DEFAULTS: { [Enum.Material]: Profile } = {
	[Enum.Material.Air] = profile(0, 0, 0, 0),
	[Enum.Material.Water] = profile(0.1, FAIRLY_SHALLOW, 0.35, 0),
	[Enum.Material.Snow] = profile(0.3, 0, 0, 0),
	[Enum.Material.Sand] = profile(0.6, 0, 0, 0),
	[Enum.Material.Fabric] = profile(0.2, 0, 0, 0),
	[Enum.Material.Foil] = profile(0.3, SHALLOW, 0.4, 0),
	[Enum.Material.Glass] = profile(0.35, math.rad(12), 0.3, 0),
	[Enum.Material.Ice] = profile(0.5, FAIRLY_SHALLOW, 0.45, 0),
	[Enum.Material.Plastic] = profile(0.8, SHALLOW, 0.4, 0),
	[Enum.Material.SmoothPlastic] = profile(0.8, FAIRLY_SHALLOW, 0.45, 0),
	[Enum.Material.Neon] = profile(0.8, SHALLOW, 0.4, 0),
	[Enum.Material.Wood] = profile(0.9, math.rad(12), 0.3, 0),
	[Enum.Material.WoodPlanks] = profile(0.9, math.rad(12), 0.3, 0),
	[Enum.Material.Cardboard] = profile(0.25, 0, 0, 0),
	[Enum.Material.Carpet] = profile(0.3, 0, 0, 0),
	[Enum.Material.LeafyGrass] = profile(0.2, 0, 0, 0),
	[Enum.Material.Grass] = profile(0.4, 0, 0, 0),
	[Enum.Material.Ground] = profile(1.2, math.rad(10), 0.25, 0),
	[Enum.Material.Mud] = profile(1, 0, 0, 0),
	[Enum.Material.Asphalt] = profile(2, FAIRLY_SHALLOW, 0.45, 0),
	[Enum.Material.Brick] = profile(2.5, FAIRLY_SHALLOW, 0.4, 0),
	[Enum.Material.Concrete] = profile(3, FAIRLY_SHALLOW, 0.45, 0),
	[Enum.Material.CrackedLava] = profile(2, SHALLOW, 0.35, 0),
	[Enum.Material.Basalt] = profile(3, FAIRLY_SHALLOW, 0.45, 0),
	[Enum.Material.Rock] = profile(3, FAIRLY_SHALLOW, 0.45, 0),
	[Enum.Material.Slate] = profile(2.5, STEEP, 0.5, 0),
	[Enum.Material.Limestone] = profile(2.5, FAIRLY_SHALLOW, 0.45, 0),
	[Enum.Material.Sandstone] = profile(2, FAIRLY_SHALLOW, 0.4, 0),
	[Enum.Material.Marble] = profile(3.5, STEEP, 0.55, 0),
	[Enum.Material.Granite] = profile(4, STEEP, 0.55, 0),
	[Enum.Material.Cobblestone] = profile(2.5, SHALLOW, 0.35, 0),
	[Enum.Material.Pebble] = profile(1.5, SHALLOW, 0.3, 0),
	[Enum.Material.Metal] = profile(5, STEEP, 0.6, 0),
	[Enum.Material.CorrodedMetal] = profile(3.5, FAIRLY_SHALLOW, 0.5, 0),
	[Enum.Material.DiamondPlate] = profile(6, STEEP, 0.6, 0),
	[Enum.Material.Salt] = profile(1, 0, 0, 0),
	[Enum.Material.Glacier] = profile(1.5, FAIRLY_SHALLOW, 0.45, 0),
}

-- Anything the table does not name. Deliberately mid-range and never
-- ricocheting: an unknown surface should behave plainly rather than surprise
-- the player with a glance nobody designed.
local FALLBACK = profile(1, 0, 0, 0)

local function validateOverride(material: Enum.Material, override: ProfileOverride): Profile
	if type(override) ~= "table" then
		fail(`profile for {material.Name} must be a table`)
	end

	local base = DEFAULTS[material] or FALLBACK

	local function number(value: any, name: string, defaultValue: number, maximum: number?): number
		if value == nil then
			return defaultValue
		end

		if type(value) ~= "number" or not isFiniteNumber(value) or value < 0 then
			fail(`{material.Name} {name} must be a non-negative finite number`)
		end

		if maximum ~= nil and value > maximum then
			fail(`{material.Name} {name} cannot exceed {maximum}`)
		end

		return value
	end

	return table.freeze({
		Resistance = number(override.Resistance, "Resistance", base.Resistance),
		RicochetBelow = number(
			override.RicochetBelow,
			"RicochetBelow",
			base.RicochetBelow,
			math.pi * 0.5
		),
		Retention = number(override.Retention, "Retention", base.Retention, 1),
		Deflection = number(override.Deflection, "Deflection", base.Deflection, math.pi * 0.5),
	})
end

function MaterialProfile.new(options: MaterialProfileOptions?): MaterialProfileTable
	local resolved: MaterialProfileOptions = if options == nil then {} else options

	if type(resolved) ~= "table" then
		fail("expected an options table")
	end

	local profiles: { [Enum.Material]: Profile } = table.clone(DEFAULTS)
	local overrides = resolved.Profiles

	if overrides ~= nil then
		if type(overrides) ~= "table" then
			fail("options.Profiles must be a table keyed by Enum.Material")
		end

		for material, override in overrides do
			if typeof(material) ~= "EnumItem" or material.EnumType ~= Enum.Material then
				fail("options.Profiles must be keyed by Enum.Material")
			end

			profiles[material] = validateOverride(material, override)
		end
	end

	local attribute = resolved.Attribute

	if attribute ~= nil and (type(attribute) ~= "string" or attribute == "") then
		fail("options.Attribute must be a non-empty string")
	end

	return (
		setmetatable({
			_profiles = profiles,
			_attribute = attribute or "PenetrationMultiplier",
		}, MaterialProfile) :: any
	) :: MaterialProfileTable
end

function MaterialProfile.Get(self: MaterialProfileTable, material: Enum.Material): Profile
	if typeof(material) ~= "EnumItem" or material.EnumType ~= Enum.Material then
		fail("Get expects an Enum.Material")
	end

	return self._profiles[material] or FALLBACK
end

function MaterialProfile.Set(
	self: MaterialProfileTable,
	material: Enum.Material,
	override: ProfileOverride
): MaterialProfileTable
	if typeof(material) ~= "EnumItem" or material.EnumType ~= Enum.Material then
		fail("Set expects an Enum.Material")
	end

	self._profiles[material] = validateOverride(material, override)

	return self
end

-- The profile for a specific part, which is the material profile with the
-- part's own attribute folded into its resistance. A single reinforced pane in
-- an otherwise ordinary glass wall belongs to the part, not to glass.
function MaterialProfile.For(
	self: MaterialProfileTable,
	part: BasePart,
	material: Enum.Material
): Profile
	local base = self:Get(material)
	local attribute = part:GetAttribute(self._attribute)

	if type(attribute) ~= "number" or not isFiniteNumber(attribute) or attribute < 0 then
		return base
	end

	return table.freeze({
		Resistance = base.Resistance * attribute,
		RicochetBelow = base.RicochetBelow,
		Retention = base.Retention,
		Deflection = base.Deflection,
	})
end

function MaterialProfile.Clone(self: MaterialProfileTable): MaterialProfileTable
	return (
		setmetatable({
			_profiles = table.clone(self._profiles),
			_attribute = self._attribute,
		}, MaterialProfile) :: any
	) :: MaterialProfileTable
end

MaterialProfile.BaseResistance = BASE_RESISTANCE

return MaterialProfile
