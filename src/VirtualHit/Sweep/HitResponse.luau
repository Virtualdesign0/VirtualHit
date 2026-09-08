--!strict

local Types = require(script.Parent.Parent.Types)

export type Value = Types.HitResponse

export type HitResponse = {
	Hit: "Hit",
	Block: "Block",
	Ignore: "Ignore",
}

local HitResponse: HitResponse = {
	Hit = "Hit",
	Block = "Block",
	Ignore = "Ignore",
}

table.freeze(HitResponse)

return HitResponse
