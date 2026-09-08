--!strict

export type CooldownPolicy = {
	read Type: "Cooldown",
	read Seconds: number,
}

export type Policy = "Once" | "OncePerEntity" | "OncePerPart" | "OncePerKey" | CooldownPolicy

export type HitPolicy = {
	Once: "Once",
	OncePerEntity: "OncePerEntity",
	OncePerPart: "OncePerPart",
	-- Scopes acceptance by the value a caller HitKey returns. Requires a
	-- HitKey; without one there is nothing to scope by.
	OncePerKey: "OncePerKey",
	Cooldown: (seconds: number) -> CooldownPolicy,
}

local function isFiniteNumber(value: number): boolean
	return value == value and value > -math.huge and value < math.huge
end

local function cooldown(seconds: number): CooldownPolicy
	if type(seconds) ~= "number" or not isFiniteNumber(seconds) or seconds <= 0 then
		error("VirtualHit.HitPolicy.Cooldown expects a finite duration greater than zero", 2)
	end

	local policy: CooldownPolicy = {
		Type = "Cooldown",
		Seconds = seconds,
	}
	return table.freeze(policy)
end

local HitPolicy: HitPolicy = {
	Once = "Once",
	OncePerEntity = "OncePerEntity",
	OncePerPart = "OncePerPart",
	OncePerKey = "OncePerKey",
	Cooldown = cooldown,
}

table.freeze(HitPolicy)

return HitPolicy
