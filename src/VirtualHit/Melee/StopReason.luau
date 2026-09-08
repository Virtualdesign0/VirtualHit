--!strict

export type StopReason =
	"Manual"
	| "Blocked"
	| "SourceRemoved"
	| "CarrierChanged"
	| "RuntimeError"
	| "Destroyed"

export type StopReasonEnum = {
	Manual: "Manual",
	Blocked: "Blocked",
	SourceRemoved: "SourceRemoved",
	CarrierChanged: "CarrierChanged",
	RuntimeError: "RuntimeError",
	Destroyed: "Destroyed",
}

local StopReason: StopReasonEnum = {
	Manual = "Manual",
	Blocked = "Blocked",
	SourceRemoved = "SourceRemoved",
	CarrierChanged = "CarrierChanged",
	RuntimeError = "RuntimeError",
	Destroyed = "Destroyed",
}

return table.freeze(StopReason)
