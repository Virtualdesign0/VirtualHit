--!strict

export type Value =
	"MaxSegments"
	| "MaxHitsPerSegment"
	| "MaxParts"
	| "EngineShapecastLimit"
	| "Allowlist"

export type TruncationReason = {
	MaxSegments: "MaxSegments",
	MaxHitsPerSegment: "MaxHitsPerSegment",
	MaxParts: "MaxParts",
	EngineShapecastLimit: "EngineShapecastLimit",
	-- An allowlist query cannot be walked through: see the note on
	-- addExclusion in Sweep. The nearest contact per segment is all it sees.
	Allowlist: "Allowlist",
}

local TruncationReason: TruncationReason = {
	MaxSegments = "MaxSegments",
	MaxHitsPerSegment = "MaxHitsPerSegment",
	MaxParts = "MaxParts",
	EngineShapecastLimit = "EngineShapecastLimit",
	Allowlist = "Allowlist",
}

return table.freeze(TruncationReason)
