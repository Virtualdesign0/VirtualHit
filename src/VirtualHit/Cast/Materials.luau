--!strict

local Pierce = require(script.Parent.Pierce)
local Errors = require(script.Parent.Parent.Util.Errors)
local Config = require(script.Parent.Parent.Config)

-- Live config section. Read through it so VirtualHit.configure() takes
-- effect without reloading the library.
local Tuning = Config.Materials

-- pierce() charges a budget per contact, and the interesting part of that
-- charge is what the material is made of. Every project ends up writing the
-- same Enum.Material lookup, so it lives here instead.

-- The numbers are multipliers on measured thickness, not physics. Glass costs
-- a fraction of its thickness, steel costs several times it. They are a
-- starting point to tune against, not a claim about the real world.

local Materials = {}
Materials.__index = Materials

export type MaterialTable = typeof(setmetatable(
	{} :: {
		_multipliers: { [Enum.Material]: number },
		_default: number,
		_attribute: string?,
		_unmeasured: number?,
	},
	Materials
))

export type MaterialOptions = {
	-- Charge for a contact whose thickness could not be measured. Defaults to
	-- the same "impassable" rule pierce() uses on its own: the whole remaining
	-- budget. A finite number here lets deep geometry be crossed at a cost.
	Unmeasured: number?,
	Default: number?,
	-- Per-part override read from an attribute, which beats the table. Set to
	-- false to skip the attribute lookup entirely.
	Attribute: (string | boolean)?,
}

local function fail(message: string, code: string?): never
	return Errors.raise("VirtualHit.Materials", code or "InvalidArgument", message, 3)
end

local function isFiniteNumber(value: number): boolean
	return value == value and value > -math.huge and value < math.huge
end

local function validateMultiplier(value: any, label: string): number
	if type(value) ~= "number" or not isFiniteNumber(value) or value < 0 then
		fail(`{label} must be a non-negative finite number`)
	end

	return value
end

-- Soft things cost less than their thickness, dense things cost more.
local DEFAULTS: { [Enum.Material]: number } = {
	[Enum.Material.Air] = 0,
	[Enum.Material.Water] = 0.1,
	[Enum.Material.Snow] = 0.3,
	[Enum.Material.Sand] = 0.6,
	[Enum.Material.Fabric] = 0.2,
	[Enum.Material.Foil] = 0.3,
	[Enum.Material.Glass] = 0.35,
	[Enum.Material.Ice] = 0.5,
	[Enum.Material.Plastic] = 0.8,
	[Enum.Material.SmoothPlastic] = 0.8,
	[Enum.Material.Neon] = 0.8,
	[Enum.Material.Wood] = 0.9,
	[Enum.Material.WoodPlanks] = 0.9,
	[Enum.Material.Cardboard] = 0.25,
	[Enum.Material.Carpet] = 0.3,
	[Enum.Material.LeafyGrass] = 0.2,
	[Enum.Material.Grass] = 0.4,
	[Enum.Material.Ground] = 1.2,
	[Enum.Material.Mud] = 1,
	[Enum.Material.Asphalt] = 2,
	[Enum.Material.Brick] = 2.5,
	[Enum.Material.Concrete] = 3,
	[Enum.Material.CrackedLava] = 2,
	[Enum.Material.Basalt] = 3,
	[Enum.Material.Rock] = 3,
	[Enum.Material.Slate] = 2.5,
	[Enum.Material.Limestone] = 2.5,
	[Enum.Material.Sandstone] = 2,
	[Enum.Material.Marble] = 3.5,
	[Enum.Material.Granite] = 4,
	[Enum.Material.Cobblestone] = 2.5,
	[Enum.Material.Pebble] = 1.5,
	[Enum.Material.Metal] = 5,
	[Enum.Material.CorrodedMetal] = 3.5,
	[Enum.Material.DiamondPlate] = 6,
	[Enum.Material.Salt] = 1,
	[Enum.Material.Glacier] = 1.5,
}

function Materials.new(options: MaterialOptions?): MaterialTable
	local resolved: MaterialOptions = if options == nil then {} else options

	if type(resolved) ~= "table" then
		fail("expected an options table")
	end

	local attribute: string? = Tuning.Attribute
	local supplied = resolved.Attribute

	if supplied == false then
		attribute = nil
	elseif type(supplied) == "string" then
		if supplied == "" then
			fail("options.Attribute must be a non-empty string or false")
		end

		attribute = supplied
	elseif supplied ~= nil and supplied ~= true then
		fail("options.Attribute must be a string or false")
	end

	local unmeasured: number? = nil

	if resolved.Unmeasured ~= nil then
		unmeasured = validateMultiplier(resolved.Unmeasured, "options.Unmeasured")
	end

	return (
		setmetatable({
			_multipliers = table.clone(DEFAULTS),
			_default = if resolved.Default == nil
				then Tuning.PenetrationMultiplier
				else validateMultiplier(resolved.Default, "options.Default"),
			_attribute = attribute,
			_unmeasured = unmeasured,
		}, Materials) :: any
	) :: MaterialTable
end

function Materials.Set(
	self: MaterialTable,
	material: Enum.Material,
	multiplier: number
): MaterialTable
	if typeof(material) ~= "EnumItem" then
		fail("Set expects an Enum.Material")
	end

	self._multipliers[material] = validateMultiplier(multiplier, "multiplier")
	return self
end

function Materials.SetMany(
	self: MaterialTable,
	multipliers: { [Enum.Material]: number }
): MaterialTable
	if type(multipliers) ~= "table" then
		fail("SetMany expects a table")
	end

	for material, multiplier in multipliers do
		self:Set(material, multiplier)
	end

	return self
end

function Materials.Get(self: MaterialTable, material: Enum.Material): number
	local multiplier = self._multipliers[material]
	return if multiplier == nil then self._default else multiplier
end

-- The per-part attribute wins over the table, so one reinforced door can differ
-- from every other door made of the same material without a new table.
function Materials.MultiplierFor(
	self: MaterialTable,
	part: BasePart,
	material: Enum.Material
): number
	local attribute = self._attribute

	if attribute ~= nil then
		local override = part:GetAttribute(attribute)

		if type(override) == "number" and isFiniteNumber(override) and override >= 0 then
			return override
		end
	end

	return self:Get(material)
end

-- Ready to hand to PierceOptions.Cost.
function Materials.CostFunction(self: MaterialTable): (contact: Pierce.PierceContact) -> number
	return function(contact: Pierce.PierceContact): number
		local thickness = contact.Thickness

		if thickness == nil then
			local unmeasured = self._unmeasured

			-- Matching pierce()'s own default: material too deep to measure is
			-- treated as impassable unless the caller priced it.
			if unmeasured == nil then
				return contact.PowerBefore
			end

			return unmeasured
		end

		return thickness * self:MultiplierFor(contact.Instance, contact.Material)
	end
end

function Materials.Clone(self: MaterialTable): MaterialTable
	local copy = Materials.new()
	copy._multipliers = table.clone(self._multipliers)
	copy._default = self._default
	copy._attribute = self._attribute
	copy._unmeasured = self._unmeasured

	return copy
end

Materials.Defaults = table.freeze(table.clone(DEFAULTS))

return Materials
