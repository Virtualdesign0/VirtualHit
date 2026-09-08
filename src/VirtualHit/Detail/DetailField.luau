--!strict

local Errors = require(script.Parent.Parent.Util.Errors)
local Config = require(script.Parent.Parent.Config)

-- Live config section. Read through it so VirtualHit.configure() takes
-- effect without reloading the library.
local Tuning = Config.Detail

-- How much fidelity a query at a given place has earned.

-- The load a server carries is not spread evenly. A hundred projectiles in
-- flight are mostly nowhere near anybody: they are crossing empty ground, and
-- resolving their flight to the same resolution as a shot happening in front of
-- a player's face is work whose result nobody can perceive.

-- What can safely be coarsened is narrower than it first looks, and the whole
-- design turns on it. A shapecast is continuous: it sweeps the shape along the
-- entire segment and cannot tunnel through anything, however long the segment
-- is. Segments exist for other reasons, and only some of them can be traded:

--   * Rotation genuinely needs segments. A swinging blade sampled coarsely
--     misses contacts along its arc, so the angular budget is left alone by
--     default and relaxing it is opt-in per level.
--   * The overlap phase reports what a shape is already inside, which a
--     shapecast never reports. That matters at the first sample. At the
--     intermediate ones it is close to redundant: anything the shape is inside
--     at sample 3 it entered between samples 2 and 3, and the cast from 2
--     reported it then.
--   * Contact alpha is measured from the real cast distance within its segment,
--     so it stays exact however few segments there are. Ordering does not
--     degrade, and neither does determinism.

-- So a level scales the linear step and, if asked, the angular one. It never
-- skips a query, and there is no level at which a sweep stops running: a shot
-- fired where no player is standing still has to resolve, because something is
-- standing there being shot at. Distance to an observer is a budget hint, never
-- permission to guess.

local DetailField = {}
DetailField.__index = DetailField

export type DetailLevel = {
	-- Applies beyond this distance from every observer. The furthest ring whose
	-- Distance the query is beyond wins, so these read as widening rings drawn
	-- around the players.
	Distance: number,
	-- Multiplies the sweep's own MaxLinearStep. Two means half the segments.
	LinearStep: number?,
	-- Multiplies MaxAngularStep. Left at one unless the caller says otherwise,
	-- because rotation is the one thing segments are genuinely required for.
	AngularStep: number?,
}

export type DetailFieldOptions = {
	Levels: { DetailLevel }?,
}

export type DetailFieldStats = {
	read Observers: number,
	read Queries: number,
	read Levels: number,
}

type Resolved = {
	Distance: number,
	LinearStep: number,
	AngularStep: number,
}

export type DetailField = typeof(setmetatable(
	{} :: {
		_levels: { Resolved },
		_observers: { [Instance]: boolean },
		_positions: { Vector3 },
		_positionCount: number,
		_dirty: boolean,
		_generation: number,
		_queries: number,
		_destroyed: boolean,
	},
	DetailField
))

local function fail(message: string, code: string?): never
	return Errors.raise("VirtualHit.detail", code or "InvalidArgument", message, 3)
end

local function isFiniteNumber(value: number): boolean
	return value == value and value > -math.huge and value < math.huge
end

local function scaleValue(value: any, name: string): number
	if value == nil then
		return Tuning.Scale
	end

	-- Below one would mean a level that asks for more work the further away it
	-- is, which is not a level, it is a mistake.
	if type(value) ~= "number" or not isFiniteNumber(value) or value < 1 then
		fail(name .. " must be a number of at least 1")
	end

	if value > Tuning.MaxScale then
		fail(name .. " cannot exceed " .. tostring(Tuning.MaxScale))
	end

	return value
end

-- Sorted nearest first so the walk in LevelAt can stop at the first ring the
-- query has not reached, rather than comparing against every one of them.
local function resolveLevels(levels: { DetailLevel }?): { Resolved }
	if levels == nil then
		return {}
	end

	if type(levels) ~= "table" then
		fail("options.Levels must be an array of levels")
	end

	local resolved: { Resolved } = {}

	for index, level in levels do
		if type(level) ~= "table" then
			fail("level " .. tostring(index) .. " must be a table")
		end

		local distance = level.Distance

		if type(distance) ~= "number" or not isFiniteNumber(distance) or distance <= 0 then
			fail("level " .. tostring(index) .. " needs a Distance greater than zero")
		end

		table.insert(resolved, {
			Distance = distance,
			LinearStep = scaleValue(level.LinearStep, "level " .. tostring(index) .. " LinearStep"),
			AngularStep = scaleValue(
				level.AngularStep,
				"level " .. tostring(index) .. " AngularStep"
			),
		})
	end

	table.sort(resolved, function(left: Resolved, right: Resolved): boolean
		return left.Distance < right.Distance
	end)

	return resolved
end

function DetailField.new(options: DetailFieldOptions?): DetailField
	local resolved: DetailFieldOptions = if options == nil then {} else options

	if type(resolved) ~= "table" then
		fail("expected an options table")
	end

	return (
		setmetatable({
			_levels = resolveLevels(resolved.Levels),
			_observers = {},
			_positions = {},
			_positionCount = 0,
			_dirty = true,
			_generation = 1,
			_queries = 0,
			_destroyed = false,
		}, DetailField) :: any
	) :: DetailField
end

-- The things whose proximity buys fidelity. Usually player characters; a
-- spectator camera or a recording rig works the same way.
function DetailField.Track(self: DetailField, observer: Instance)
	if self._destroyed then
		fail("cannot Track on a destroyed detail field", "Destroyed")
	end

	if typeof(observer) ~= "Instance" then
		fail("Track expects an Instance")
	end

	self._observers[observer] = true
	self._dirty = true
	self._generation += 1
end

function DetailField.Untrack(self: DetailField, observer: Instance)
	if self._observers[observer] == nil then
		return
	end

	self._observers[observer] = nil
	self._dirty = true
	self._generation += 1
end

function DetailField.IsTracking(self: DetailField, observer: Instance): boolean
	return self._observers[observer] ~= nil
end

-- Positions are read once per frame, not once per query. A hundred projectiles
-- asking about the same hundred players would otherwise be ten thousand
-- property reads for an answer that is identical every time.
function DetailField.Refresh(self: DetailField)
	local positions = self._positions
	local count = 0

	for observer in self._observers do
		local position: Vector3? = nil

		if observer:IsA("BasePart") then
			position = observer.Position
		elseif observer:IsA("Model") then
			local primary = observer.PrimaryPart

			if primary ~= nil then
				position = primary.Position
			end
		elseif observer:IsA("Camera") then
			position = observer.CFrame.Position
		end

		if position ~= nil then
			count += 1
			positions[count] = position
		end
	end

	-- The tail is nilled rather than the array cleared, so its capacity survives
	-- and a stable observer set stops allocating after the first refresh.
	for index = count + 1, self._positionCount do
		positions[index] = nil
	end

	self._positionCount = count
	self._dirty = false
end

function DetailField.Invalidate(self: DetailField)
	self._dirty = true
end

-- The multipliers a query at this position has earned, and how far it may move
-- before they could change.

-- That third return is what makes this affordable to ask every frame. It is the
-- distance to the nearest ring boundary in either direction, so a caller that
-- has not moved that far can reuse its previous answer. The answer is exact
-- either way: this is a cache, not an approximation.
function DetailField.LevelAt(self: DetailField, position: Vector3): (number, number, number)
	if self._dirty then
		self:Refresh()
	end

	self._queries += 1
	local levels = self._levels
	local count = #levels

	if count == 0 then
		return Tuning.Scale, Tuning.Scale, math.huge
	end

	local positions = self._positions
	local nearestSquared = math.huge

	for index = 1, self._positionCount do
		local offset = positions[index] - position
		local squared = offset:Dot(offset)

		if squared < nearestSquared then
			nearestSquared = squared
		end
	end

	if nearestSquared == math.huge then
		-- Nothing is observing anything. The coarsest level is the honest answer
		-- rather than the finest: there is nobody to notice either way, and a
		-- server with no players still has to run its own simulation cheaply.
		local coarsest = levels[count]
		return coarsest.LinearStep, coarsest.AngularStep, math.huge
	end

	local nearest = math.sqrt(nearestSquared)
	local linear = Tuning.Scale
	local angular = Tuning.Scale
	local inner = 0
	local outer = math.huge

	for index = 1, count do
		local level = levels[index]

		if nearest >= level.Distance then
			linear = level.LinearStep
			angular = level.AngularStep
			inner = level.Distance
		else
			outer = level.Distance
			break
		end
	end

	-- How far this position may move in any direction and stay in the same ring.
	-- Both boundaries count: moving closer promotes it, moving away demotes it.
	local margin = math.min(nearest - inner, outer - nearest)

	return linear, angular, margin
end

-- Bumped whenever the observer set changes. A caller holding a cached level
-- compares this to know its answer was computed against a different set of
-- observers entirely -- the case a distance margin cannot see, because the
-- caller did not move, the world did.
function DetailField.GetGeneration(self: DetailField): number
	return self._generation
end

function DetailField.GetStats(self: DetailField): DetailFieldStats
	if self._dirty then
		self:Refresh()
	end

	return table.freeze({
		Observers = self._positionCount,
		Queries = self._queries,
		Levels = #self._levels,
	})
end

function DetailField.Clear(self: DetailField)
	table.clear(self._observers)
	table.clear(self._positions)
	self._positionCount = 0
	self._dirty = true
	self._generation += 1
end

function DetailField.IsDestroyed(self: DetailField): boolean
	return self._destroyed
end

function DetailField.Destroy(self: DetailField)
	if self._destroyed then
		return
	end

	self._destroyed = true
	self:Clear()
end

return DetailField
