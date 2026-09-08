--!strict

local Debris = game:GetService("Debris")
local Workspace = game:GetService("Workspace")

local Types = require(script.Parent.Parent.Types)
local Cast = require(script.Parent.Parent.Cast.Cast)
local InternalExclusions = require(script.Parent.Parent.Collision.InternalExclusions)
local ShapeProbe = require(script.Parent.Parent.Collision.ShapeProbe)
local Errors = require(script.Parent.Parent.Util.Errors)
local Config = require(script.Parent.Parent.Config)

-- Live config section. Read through it so VirtualHit.configure() takes
-- effect without reloading the library.
local Tuning = Config.Visualizer

export type DrawOptions = {
	Duration: number?,
	CastColor: Color3?,
	HitColor: Color3?,
	DrawNormal: boolean?,
	NormalLength: number?,
	NormalColor: Color3?,
}

export type SweepDrawOptions = {
	Duration: number?,
	SampleColor: Color3?,
	HitColor: Color3?,
	BlockColor: Color3?,
	OverlapColor: Color3?,
	BlockedBy: Types.SweepBlock?,
	SampleTransparency: number?,
	DrawNormal: boolean?,
	NormalLength: number?,
	NormalColor: Color3?,
}

local FOLDER_NAME = "__VirtualHitDebug"

local Visualizer = {}
local debugFolder: Folder? = nil

local function fail(message: string, code: string?): never
	return Errors.raise("VirtualHit.Debug.draw", code or "InvalidArgument", message, 3)
end

local function isFiniteNumber(value: number): boolean
	return value == value and value > -math.huge and value < math.huge
end

local function getFolder(): Folder
	if debugFolder and debugFolder.Parent then
		InternalExclusions.Register(Workspace, debugFolder)
		return debugFolder
	end

	for _, child in Workspace:GetChildren() do
		if
			child:IsA("Folder")
			and child.Name == FOLDER_NAME
			and child:GetAttribute("VirtualHitDebug") == true
		then
			debugFolder = child
			InternalExclusions.Register(Workspace, child)
			return child
		end
	end

	local folder = Instance.new("Folder")
	folder.Name = FOLDER_NAME
	folder:SetAttribute("VirtualHitDebug", true)
	InternalExclusions.Tag(folder)
	folder.Parent = Workspace
	InternalExclusions.Register(Workspace, folder)
	debugFolder = folder

	return folder
end

local function createPart(
	name: string,
	size: Vector3,
	cframe: CFrame,
	color: Color3,
	transparency: number,
	duration: number,
	shape: Enum.PartType?
): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Color = color
	part.Transparency = transparency
	part.Size = size
	part.CFrame = cframe

	if shape then
		part.Shape = shape
	end

	part.Parent = getFolder()
	Debris:AddItem(part, duration)

	return part
end

local function drawPath(
	name: string,
	origin: Vector3,
	direction: Vector3,
	distance: number,
	color: Color3,
	duration: number,
	transparency: number
)
	if distance <= 1e-6 then
		return
	end

	local center = origin + direction * (distance * 0.5)
	local cframe = Cast.alignedCFrame(center, direction)

	createPart(
		name,
		Vector3.new(Tuning.PathThickness, Tuning.PathThickness, distance),
		cframe,
		color,
		transparency,
		duration,
		nil
	)
end

local function drawNormal(
	position: Vector3,
	normal: Vector3,
	length: number,
	color: Color3,
	duration: number
)
	local magnitude = normal.Magnitude

	if magnitude <= 1e-6 then
		return
	end

	drawPath("Normal", position, normal / magnitude, length, color, duration, 0)
end

local function createShapeSample(
	source: BasePart,
	cframe: CFrame,
	color: Color3,
	transparency: number,
	duration: number,
	name: string
): BasePart
	local sample = ShapeProbe.clone(source)
	sample.Name = name
	sample.CFrame = cframe
	sample.Color = color
	sample.Material = Enum.Material.Neon
	sample.Transparency = transparency
	sample.Parent = getFolder()
	Debris:AddItem(sample, duration)

	return sample
end

local function createSweepSample(
	shape: Types.PrimitiveShape,
	cframe: CFrame,
	color: Color3,
	transparency: number,
	duration: number,
	name: string
)
	if shape.Type == "Sphere" then
		local diameter = shape.Radius * 2
		createPart(
			name,
			Vector3.new(diameter, diameter, diameter),
			cframe,
			color,
			transparency,
			duration,
			Enum.PartType.Ball
		)
	elseif shape.Type == "Block" then
		createPart(name, shape.Size, cframe, color, transparency, duration, nil)
	elseif shape.Type == "Part" then
		createShapeSample(shape.Part, cframe, color, transparency, duration, name)
	else
		fail(`unsupported sweep sample shape {tostring((shape :: any).Type)}`)
	end
end

function Visualizer.draw(
	options: Cast.CastOptions,
	result: Types.HitResult?,
	drawOptions: DrawOptions?
)
	local prepared = Cast.prepare(options)
	local config = (drawOptions or {}) :: DrawOptions
	local duration = config.Duration or Tuning.Duration
	local castColor = config.CastColor or Tuning.CastColor
	local hitColor = config.HitColor or Tuning.HitColor
	local drawNormalEnabled = config.DrawNormal == true
	local normalLength = config.NormalLength or Tuning.NormalLength
	local normalColor = config.NormalColor or Tuning.NormalColor

	if type(duration) ~= "number" or not isFiniteNumber(duration) or duration <= 0 then
		fail("Duration must be a finite number greater than zero")
	end

	if typeof(castColor) ~= "Color3" or typeof(hitColor) ~= "Color3" then
		fail("CastColor and HitColor must be Color3 values")
	end

	if config.DrawNormal ~= nil and type(config.DrawNormal) ~= "boolean" then
		fail("DrawNormal must be a boolean")
	end

	if type(normalLength) ~= "number" or not isFiniteNumber(normalLength) or normalLength <= 0 then
		fail("NormalLength must be a finite number greater than zero")
	end

	if typeof(normalColor) ~= "Color3" then
		fail("NormalColor must be a Color3")
	end

	local travelled = if result then result.Distance else prepared.Distance
	travelled = math.clamp(travelled, 0, prepared.Distance)

	drawPath("Path", prepared.Origin, prepared.Direction, travelled, castColor, duration, 0.15)

	local shape = prepared.Shape
	local endPosition = prepared.Origin + prepared.Direction * travelled

	if shape.Type == "Sphere" then
		local diameter = shape.Radius * 2
		local size = Vector3.new(diameter, diameter, diameter)

		createPart(
			"SphereStart",
			size,
			CFrame.new(prepared.Origin),
			castColor,
			0.8,
			duration,
			Enum.PartType.Ball
		)
		createPart(
			"SphereEnd",
			size,
			CFrame.new(endPosition),
			castColor,
			0.65,
			duration,
			Enum.PartType.Ball
		)
	elseif shape.Type == "Block" then
		local startCFrame = prepared.OriginCFrame
		assert(startCFrame ~= nil, "Block casts must have an origin CFrame")

		createPart("BlockStart", shape.Size, startCFrame, castColor, 0.8, duration, nil)
		createPart(
			"BlockEnd",
			shape.Size,
			startCFrame + prepared.Direction * travelled,
			castColor,
			0.65,
			duration,
			nil
		)
	elseif shape.Type == "Part" then
		local startCFrame = prepared.OriginCFrame
		assert(startCFrame ~= nil, "Part casts must have an origin CFrame")
		createShapeSample(shape.Part, startCFrame, castColor, 0.8, duration, "PartStart")
		createShapeSample(
			shape.Part,
			startCFrame + prepared.Direction * travelled,
			castColor,
			0.65,
			duration,
			"PartEnd"
		)
	end

	if result then
		createPart(
			"Hit",
			Vector3.new(0.18, 0.18, 0.18),
			CFrame.new(result.Position),
			hitColor,
			0,
			duration,
			Enum.PartType.Ball
		)

		if drawNormalEnabled then
			drawNormal(result.Position, result.Normal, normalLength, normalColor, duration)
		end
	end
end

-- Accepts either the flat CFrame array a primitive sweep produces or the array
-- of per-member chains a compound sweep produces, so callers can pass
-- GetLastSamples() or GetLastSampleChains() without branching.
local function normalizeSampleInput(
	shape: Types.SweepShape,
	samples: { CFrame } | { { CFrame } }
): ({ Types.PrimitiveShape }, { { CFrame } })
	if shape.Type == "Compound" then
		local shapes: { Types.PrimitiveShape } = {}

		for _, member in shape.Members do
			table.insert(shapes, member.Shape)
		end

		local first = (samples :: any)[1]

		if first ~= nil and typeof(first) == "CFrame" then
			fail(
				"a Compound shape needs the chains from GetLastSampleChains(), not GetLastSamples()"
			)
		end

		local chains = samples :: { { CFrame } }

		if #chains > #shapes then
			fail("drawSweep received more sample chains than the Compound shape has members")
		end

		return shapes, chains
	end

	local first = (samples :: any)[1]
	local chains: { { CFrame } }

	if first ~= nil and type(first) == "table" then
		chains = samples :: { { CFrame } }

		if #chains > 1 then
			fail("a non-Compound shape has exactly one sample chain")
		end
	else
		chains = { samples :: { CFrame } }
	end

	return { shape :: Types.PrimitiveShape }, chains
end

function Visualizer.drawSweep(
	shape: Types.SweepShape,
	samples: { CFrame } | { { CFrame } },
	hits: { Types.SweepHit },
	drawOptions: SweepDrawOptions?
)
	if
		type(shape) ~= "table"
		or (
			shape.Type ~= "Sphere"
			and shape.Type ~= "Block"
			and shape.Type ~= "Part"
			and shape.Type ~= "Compound"
		)
	then
		fail("drawSweep shape must be a Sphere, Block, Part, or Compound")
	end

	if type(samples) ~= "table" or type(hits) ~= "table" then
		fail("drawSweep expects sample and hit arrays")
	end

	local config = (drawOptions or {}) :: SweepDrawOptions
	local duration = config.Duration or Tuning.Duration
	local sampleColor = config.SampleColor or Tuning.CastColor
	local hitColor = config.HitColor or Tuning.HitColor
	local blockColor = config.BlockColor or Tuning.BlockColor
	local overlapColor = config.OverlapColor or Tuning.OverlapColor
	local transparency = if config.SampleTransparency == nil
		then Tuning.SampleTransparency
		else config.SampleTransparency
	local drawNormalEnabled = config.DrawNormal == true
	local normalLength = config.NormalLength or Tuning.NormalLength
	local normalColor = config.NormalColor or Tuning.NormalColor

	if type(duration) ~= "number" or not isFiniteNumber(duration) or duration <= 0 then
		fail("Duration must be a finite number greater than zero")
	end

	if
		type(transparency) ~= "number"
		or not isFiniteNumber(transparency)
		or transparency < 0
		or transparency > 1
	then
		fail("SampleTransparency must be from zero through one")
	end

	if
		typeof(sampleColor) ~= "Color3"
		or typeof(hitColor) ~= "Color3"
		or typeof(blockColor) ~= "Color3"
		or typeof(overlapColor) ~= "Color3"
		or typeof(normalColor) ~= "Color3"
	then
		fail("drawSweep colors must be Color3 values")
	end

	if config.DrawNormal ~= nil and type(config.DrawNormal) ~= "boolean" then
		fail("DrawNormal must be a boolean")
	end

	if type(normalLength) ~= "number" or not isFiniteNumber(normalLength) or normalLength <= 0 then
		fail("NormalLength must be a finite number greater than zero")
	end

	local memberShapes, chains = normalizeSampleInput(shape, samples)

	for chainIndex, chain in chains do
		local memberShape = memberShapes[chainIndex]

		if type(chain) ~= "table" then
			fail("every sweep sample chain must be an array of CFrames")
		end

		for index, cframe in chain do
			if typeof(cframe) ~= "CFrame" then
				fail("every sweep sample must be a CFrame")
			end

			createSweepSample(
				memberShape,
				cframe,
				sampleColor,
				transparency,
				duration,
				`SweepSample{chainIndex}_{index}`
			)
		end
	end

	for _, hit in hits do
		local result = hit.Result

		if hit.Kind == "Sweep" and result ~= nil then
			createPart(
				"SweepHit",
				Vector3.new(0.18, 0.18, 0.18),
				CFrame.new(result.Position),
				hitColor,
				0,
				duration,
				Enum.PartType.Ball
			)

			if drawNormalEnabled then
				drawNormal(result.Position, result.Normal, normalLength, normalColor, duration)
			end
		elseif hit.Kind == "Overlap" then
			createPart(
				"OverlapPose",
				Vector3.new(0.12, 0.12, 0.12),
				hit.Pose,
				overlapColor,
				0.25,
				duration,
				Enum.PartType.Ball
			)
		end
	end

	local blockedBy = config.BlockedBy

	if blockedBy ~= nil then
		local result = blockedBy.Result

		if blockedBy.Kind == "Sweep" and result ~= nil then
			createPart(
				"SweepBlock",
				Vector3.new(0.18, 0.18, 0.18),
				CFrame.new(result.Position),
				blockColor,
				0,
				duration,
				Enum.PartType.Ball
			)

			if drawNormalEnabled then
				drawNormal(result.Position, result.Normal, normalLength, normalColor, duration)
			end
		elseif blockedBy.Kind == "Overlap" then
			createPart(
				"BlockPose",
				Vector3.new(0.12, 0.12, 0.12),
				blockedBy.Pose,
				blockColor,
				0.25,
				duration,
				Enum.PartType.Ball
			)
		end
	end
end

function Visualizer.clear()
	for _, child in Workspace:GetChildren() do
		if
			child:IsA("Folder")
			and child.Name == FOLDER_NAME
			and child:GetAttribute("VirtualHitDebug") == true
		then
			child:Destroy()
		end
	end

	debugFolder = nil
end

return Visualizer
