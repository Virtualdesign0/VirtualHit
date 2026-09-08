--!strict

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local RuntimeClass = require(script.Parent.Parent.Melee.Runtime)
local Errors = require(script.Parent.Parent.Util.Errors)
local Config = require(script.Parent.Parent.Config)

-- Live config section. Read through it so VirtualHit.configure() takes
-- effect without reloading the library.
local Tuning = Config.Telemetry

-- A live view of what the shared query runtime is doing. Calibrating budgets
-- from a CSV means running, exporting, reading, changing one number and running
-- again; this shows the same numbers while the load is happening, which is the
-- difference between tuning in minutes and tuning in an afternoon.

-- Client-only, opt-in, and never created unless something calls show().

local Telemetry = {}

local GUI_NAME = "VirtualHitTelemetry"

export type TelemetryOptions = {
	-- Which runtime to watch. Defaults to the shared one every hitbox, zone and
	-- projectile uses.
	Runtime: RuntimeClass.Runtime?,
	Position: UDim2?,
	WarnTimeMs: number?,
	CriticalTimeMs: number?,
	-- Frames of history in the sparkline.
	History: number?,
}

type State = {
	Gui: ScreenGui,
	Body: TextLabel,
	Bars: { Frame },
	Samples: { number },
	Cursor: number,
	Connection: RBXScriptConnection?,
	Runtime: RuntimeClass.Runtime,
	WarnMs: number,
	CriticalMs: number,
	History: number,
}

local active: State? = nil

local function fail(message: string, code: string?): never
	return Errors.raise("VirtualHit.Debug.Telemetry", code or "InvalidArgument", message, 3)
end

local function isFiniteNumber(value: number): boolean
	return value == value and value > -math.huge and value < math.huge
end

local function positiveNumber(value: any, name: string, defaultValue: number): number
	if value == nil then
		return defaultValue
	end

	if type(value) ~= "number" or not isFiniteNumber(value) or value <= 0 then
		fail(`options.{name} must be a finite number greater than zero`)
	end

	return value
end

local function colorFor(timeMs: number, warnMs: number, criticalMs: number): Color3
	if timeMs >= criticalMs then
		return Color3.fromRGB(255, 92, 92)
	elseif timeMs >= warnMs then
		return Color3.fromRGB(255, 190, 92)
	end

	return Color3.fromRGB(120, 230, 150)
end

local function build(options: TelemetryOptions, player: Player): State
	local history = math.floor(positiveNumber(options.History, "History", Tuning.History))
	local gui = Instance.new("ScreenGui")
	gui.Name = GUI_NAME
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 1_000

	local frame = Instance.new("Frame")
	frame.Name = "Panel"
	frame.Size = UDim2.fromOffset(300, 168)
	frame.Position = options.Position or UDim2.new(1, -312, 0, 12)
	frame.BackgroundColor3 = Color3.fromRGB(16, 16, 20)
	frame.BackgroundTransparency = 0.15
	frame.BorderSizePixel = 0
	frame.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = frame

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.new(1, -16, 0, 18)
	title.Position = UDim2.fromOffset(8, 6)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.TextSize = 13
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextColor3 = Color3.fromRGB(235, 235, 240)
	title.Text = "VirtualHit runtime"
	title.Parent = frame

	local body = Instance.new("TextLabel")
	body.Name = "Body"
	body.Size = UDim2.new(1, -16, 0, 96)
	body.Position = UDim2.fromOffset(8, 26)
	body.BackgroundTransparency = 1
	body.Font = Enum.Font.Code
	body.TextSize = 12
	body.TextXAlignment = Enum.TextXAlignment.Left
	body.TextYAlignment = Enum.TextYAlignment.Top
	body.TextColor3 = Color3.fromRGB(200, 205, 215)
	body.Text = "waiting for a heartbeat"
	body.Parent = frame

	local chart = Instance.new("Frame")
	chart.Name = "Chart"
	chart.Size = UDim2.new(1, -16, 0, 34)
	chart.Position = UDim2.new(0, 8, 1, -42)
	chart.BackgroundColor3 = Color3.fromRGB(28, 28, 34)
	chart.BorderSizePixel = 0
	chart.Parent = frame

	local bars: { Frame } = {}
	local width = 1 / history

	for index = 1, history do
		local bar = Instance.new("Frame")
		bar.Name = `Bar{index}`
		bar.AnchorPoint = Vector2.new(0, 1)
		bar.Position = UDim2.fromScale((index - 1) * width, 1)
		bar.Size = UDim2.new(width, -1, 0, 0)
		bar.BackgroundColor3 = Color3.fromRGB(120, 230, 150)
		bar.BorderSizePixel = 0
		bar.Parent = chart
		bars[index] = bar
	end

	gui.Parent = player:WaitForChild("PlayerGui")

	return {
		Gui = gui,
		Body = body,
		Bars = bars,
		Samples = {},
		Cursor = 0,
		Connection = nil,
		Runtime = options.Runtime or RuntimeClass.Default,
		WarnMs = positiveNumber(options.WarnTimeMs, "WarnTimeMs", Tuning.WarnMs),
		CriticalMs = positiveNumber(options.CriticalTimeMs, "CriticalTimeMs", Tuning.CriticalMs),
		History = history,
	}
end

local function render(state: State)
	local stats = state.Runtime:GetLastStats()

	if stats == nil then
		return
	end

	state.Cursor += 1
	local slot = (state.Cursor - 1) % state.History + 1
	state.Samples[slot] = stats.TimeMs

	local peak = 0

	for _, sample in state.Samples do
		peak = math.max(peak, sample)
	end

	local scale = math.max(peak, state.CriticalMs)

	for index, bar in state.Bars do
		local sample = state.Samples[index] or 0
		bar.Size = UDim2.new(1 / state.History, -1, math.clamp(sample / scale, 0, 1), 0)
		bar.BackgroundColor3 = colorFor(sample, state.WarnMs, state.CriticalMs)
	end

	local config = state.Runtime:GetConfig()
	local shapeLimit = if config.MaxShapeCastsPerHeartbeat == nil
		then "-"
		else tostring(config.MaxShapeCastsPerHeartbeat)
	local overlapLimit = if config.MaxOverlapQueriesPerHeartbeat == nil
		then "-"
		else tostring(config.MaxOverlapQueriesPerHeartbeat)

	state.Body.Text = string.format(
		"time     %6.3f ms   peak %6.3f ms\nmember   %6.3f ms\nactive   %4d  exec %4d  defer %4d\nfailed   %4d  maxdefer %3d\nshapecast %5d / %s%s\noverlap   %5d / %s%s",
		stats.TimeMs,
		peak,
		stats.PeakHitboxTimeMs,
		stats.Active,
		stats.Executed,
		stats.Deferred,
		stats.Failed,
		stats.MaxDeferredHeartbeats,
		stats.ShapeCasts,
		shapeLimit,
		if stats.ShapeCastBudgetReached then "  CAP" else "",
		stats.OverlapQueries,
		overlapLimit,
		if stats.OverlapQueryBudgetReached then "  CAP" else ""
	)
end

-- Shows the overlay, replacing any panel a previous call left behind.
function Telemetry.show(options: TelemetryOptions?)
	local resolved: TelemetryOptions = if options == nil then {} else options

	if type(resolved) ~= "table" then
		fail("expected an options table")
	end

	if not RunService:IsClient() then
		fail("the telemetry overlay needs a PlayerGui and can only run on a client")
	end

	local player = Players.LocalPlayer

	if player == nil then
		fail("no LocalPlayer to parent the overlay to")
	end

	Telemetry.hide()

	local state = build(resolved, player)
	state.Connection = RunService.RenderStepped:Connect(function()
		render(state)
	end)
	active = state
end

function Telemetry.hide()
	local state = active

	if state == nil then
		return
	end

	active = nil

	if state.Connection ~= nil then
		state.Connection:Disconnect()
	end

	state.Gui:Destroy()
end

function Telemetry.isVisible(): boolean
	return active ~= nil
end

return Telemetry
