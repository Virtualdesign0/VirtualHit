--!strict

local Types = require(script.Parent.Parent.Types)
local Errors = require(script.Parent.Parent.Util.Errors)
local Config = require(script.Parent.Parent.Config)

-- Live config sections. Read through them so VirtualHit.configure()
-- takes effect without reloading the library.
local Limits = Config.Limits

local Shapes = {}

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

local function fail(message: string, code: string?): never
	return Errors.raise("VirtualHit.Shapes", code or "InvalidArgument", message, 3)
end

function Shapes.Ray(): Types.RayShape
	local shape: Types.RayShape = {
		Type = "Ray",
	}
	return table.freeze(shape)
end

function Shapes.Sphere(radius: number): Types.SphereShape
	if type(radius) ~= "number" or not isFiniteNumber(radius) then
		fail("Sphere radius must be a finite number")
	end

	if radius < (Limits.MinPhysicalAxis * 0.5) then
		fail(`Sphere radius must be at least {(Limits.MinPhysicalAxis * 0.5)} studs`)
	end

	if radius > Limits.MaxSphereRadius then
		fail(`Sphere radius cannot exceed {Limits.MaxSphereRadius} studs`)
	end

	local shape: Types.SphereShape = {
		Type = "Sphere",
		Radius = radius,
	}
	return table.freeze(shape)
end

function Shapes.Block(size: Vector3): Types.BlockShape
	if typeof(size) ~= "Vector3" then
		fail("Block size must be a Vector3")
	end

	if not isFiniteNumber(size.X) or not isFiniteNumber(size.Y) or not isFiniteNumber(size.Z) then
		fail("Block size must contain only finite values")
	end

	if
		size.X < Limits.MinPhysicalAxis
		or size.Y < Limits.MinPhysicalAxis
		or size.Z < Limits.MinPhysicalAxis
	then
		fail(`Every Block size axis must be at least {Limits.MinPhysicalAxis} studs`)
	end

	if
		size.X > Limits.MaxBlockAxis
		or size.Y > Limits.MaxBlockAxis
		or size.Z > Limits.MaxBlockAxis
	then
		fail(`No Block size axis can exceed {Limits.MaxBlockAxis} studs`)
	end

	local shape: Types.BlockShape = {
		Type = "Block",
		Size = size,
	}
	return table.freeze(shape)
end

function Shapes.Part(part: BasePart, offset: CFrame?): Types.PartShape
	if typeof(part) ~= "Instance" or not part:IsA("BasePart") or part:IsA("Terrain") then
		fail("Part expects a non-Terrain BasePart")
	end

	if offset ~= nil and (typeof(offset) ~= "CFrame" or not isFiniteCFrame(offset)) then
		fail("Part offset must be a finite CFrame")
	end

	local shape: Types.PartShape = {
		Type = "Part",
		Part = part,
		Offset = offset or CFrame.identity,
	}
	return table.freeze(shape)
end

local function isPrimitive(shape: any): boolean
	return type(shape) == "table"
		and (shape.Type == "Sphere" or shape.Type == "Block" or shape.Type == "Part")
end

-- Members are frozen copies. A caller that mutates the descriptor table it
-- passed in cannot change how an already-constructed shape is queried.
function Shapes.Compound(
	members: { { Shape: Types.PrimitiveShape, Offset: CFrame? } }
): Types.CompoundShape
	if type(members) ~= "table" then
		fail("Compound expects an array of members")
	end

	if #members == 0 then
		fail("Compound needs at least one member")
	end

	if #members > Limits.MaxCompoundMembers then
		fail(`Compound cannot exceed {Limits.MaxCompoundMembers} members`)
	end

	local stored: { Types.CompoundMember } = {}

	for index, member in members do
		if type(member) ~= "table" then
			fail(`Compound member {index} must be a table with a Shape field`)
		end

		local shape = member.Shape

		if not isPrimitive(shape) then
			fail(
				`Compound member {index} Shape must be a Sphere, Block, or Part shape; compounds cannot nest`
			)
		end

		local offset = member.Offset

		if offset ~= nil and (typeof(offset) ~= "CFrame" or not isFiniteCFrame(offset)) then
			fail(`Compound member {index} Offset must be a finite CFrame`)
		end

		table.insert(
			stored,
			table.freeze({
				Shape = table.freeze(table.clone(shape :: any)) :: Types.PrimitiveShape,
				Offset = offset or CFrame.identity,
			})
		)
	end

	local shape: Types.CompoundShape = {
		Type = "Compound",
		Members = table.freeze(stored),
	}
	return table.freeze(shape)
end

local AXIS_DIRECTION: { [string]: Vector3? } = {
	X = Vector3.xAxis,
	Y = Vector3.yAxis,
	Z = Vector3.zAxis,
}

-- Roblox has no capsule primitive and no capsule shapecast. A capsule is
-- therefore a convenience constructor over Compound: two end spheres plus the
-- cylindrical section approximated by a block. The block's corners extend past
-- the true capsule surface, so a Capsule is slightly more generous than the
-- ideal solid along the diagonals of its cross-section.
function Shapes.Capsule(radius: number, height: number, axis: Enum.Axis?): Types.CompoundShape
	if type(radius) ~= "number" or not isFiniteNumber(radius) then
		fail("Capsule radius must be a finite number")
	end

	if type(height) ~= "number" or not isFiniteNumber(height) then
		fail("Capsule height must be a finite number")
	end

	if axis ~= nil and typeof(axis) ~= "EnumItem" then
		fail("Capsule axis must be an Enum.Axis")
	end

	local axisName = if axis == nil then "Y" else axis.Name
	local lookup = AXIS_DIRECTION[axisName]

	if lookup == nil then
		fail("Capsule axis must be an Enum.Axis")
	end

	local direction = lookup :: Vector3
	local section = height - radius * 2

	if section < Limits.MinPhysicalAxis then
		fail(
			`Capsule height must exceed twice its radius by at least {Limits.MinPhysicalAxis} studs; use Shapes.Sphere for a capsule with no cylindrical section`
		)
	end

	local diameter = radius * 2
	local sectionSize = direction * section + (Vector3.one - direction) * diameter
	local capOffset = direction * (section * 0.5)

	-- Every member spells out its Offset so the array literal has one uniform
	-- element type instead of a mixed optional-field union.
	local members: { { Shape: Types.PrimitiveShape, Offset: CFrame? } } = {
		{ Shape = Shapes.Block(sectionSize), Offset = CFrame.identity },
		{ Shape = Shapes.Sphere(radius), Offset = CFrame.new(capOffset) },
		{ Shape = Shapes.Sphere(radius), Offset = CFrame.new(-capOffset) },
	}

	return Shapes.Compound(members)
end

table.freeze(Shapes)

return Shapes
