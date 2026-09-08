--!strict

-- Deterministic ordering primitives shared by Sweep and Overlap.

-- Roblox reports overlap and shapecast results in an unspecified order that can
-- change between frames for physically identical configurations. Every VirtualHit
-- query that promises a stable order resolves ties through these helpers, so a
-- single definition of "same physical position" governs the whole library.

local Ordering = {}

export type TieMetadata = {
	FullName: string,
	ClassName: string,
	Position: Vector3,
	Orientation: Vector3,
	Size: Vector3,
}

function Ordering.number(left: number, right: number): boolean?
	if left < right then
		return true
	elseif left > right then
		return false
	end

	return nil
end

function Ordering.vector(left: Vector3, right: Vector3): boolean?
	local comparison = Ordering.number(left.X, right.X)

	if comparison ~= nil then
		return comparison
	end

	comparison = Ordering.number(left.Y, right.Y)

	if comparison ~= nil then
		return comparison
	end

	return Ordering.number(left.Z, right.Z)
end

-- Snapshots are taken once, before any caller callback runs, so a comparator
-- can never observe geometry a callback moved mid-sort.
function Ordering.snapshot(part: BasePart): TieMetadata
	return {
		FullName = part:GetFullName(),
		ClassName = part.ClassName,
		Position = part.Position,
		Orientation = part.Orientation,
		Size = part.Size,
	}
end

function Ordering.metadata(left: TieMetadata, right: TieMetadata): boolean?
	if left.FullName ~= right.FullName then
		return left.FullName < right.FullName
	end

	if left.ClassName ~= right.ClassName then
		return left.ClassName < right.ClassName
	end

	local comparison = Ordering.vector(left.Position, right.Position)

	if comparison ~= nil then
		return comparison
	end

	comparison = Ordering.vector(left.Orientation, right.Orientation)

	if comparison ~= nil then
		return comparison
	end

	return Ordering.vector(left.Size, right.Size)
end

table.freeze(Ordering)

return Ordering
