--!strict
--[[
	Theme.luau
	Centralized dark IDE color palette, typography, and visual indicator helpers
	for Illusion's ScriptFlowDiscovery.
]]

local Types = require("./Types")

type ScriptClassName = Types.ScriptClassName
type ExecutionEnvironment = Types.ExecutionEnvironment
type ResolutionStatus = Types.ResolutionStatus
type DependencyClassification = Types.DependencyClassification
type OrderDeterminism = Types.OrderDeterminism
type GraphNodeType = Types.GraphNodeType

local Theme = {}

Theme.Colors = {
	-- Surfaces
	MainBackground = Color3.fromRGB(22, 23, 26),
	PanelBackground = Color3.fromRGB(30, 32, 36),
	PanelHeader = Color3.fromRGB(26, 28, 32),
	RowBackground = Color3.fromRGB(33, 35, 40),
	RowAlternate = Color3.fromRGB(29, 31, 35),
	RowHover = Color3.fromRGB(42, 46, 54),
	RowSelected = Color3.fromRGB(36, 58, 94),
	InputBackground = Color3.fromRGB(20, 21, 24),
	ChipBackground = Color3.fromRGB(38, 41, 47),
	ChipActiveBackground = Color3.fromRGB(37, 99, 235),

	-- Borders
	Border = Color3.fromRGB(48, 52, 60),
	BorderSubtle = Color3.fromRGB(39, 42, 49),
	BorderFocus = Color3.fromRGB(59, 130, 246),

	-- Text
	TextPrimary = Color3.fromRGB(236, 239, 244),
	TextSecondary = Color3.fromRGB(166, 173, 186),
	TextMuted = Color3.fromRGB(115, 122, 135),
	TextOnAccent = Color3.fromRGB(255, 255, 255),

	-- Primary Accent
	AccentBlue = Color3.fromRGB(59, 130, 246),
	AccentBlueHover = Color3.fromRGB(78, 145, 252),
	AccentBlueSoft = Color3.fromRGB(26, 48, 82),

	-- Script Class Indicators
	ScriptText = Color3.fromRGB(96, 165, 250), -- Neutral Blue
	ScriptBg = Color3.fromRGB(24, 46, 78),
	LocalScriptText = Color3.fromRGB(52, 211, 153), -- Green
	LocalScriptBg = Color3.fromRGB(18, 58, 45),
	ModuleScriptText = Color3.fromRGB(192, 132, 252), -- Purple
	ModuleScriptBg = Color3.fromRGB(54, 32, 82),

	-- Dependency & Execution Status Indicators
	SuccessText = Color3.fromRGB(52, 211, 153), -- Green (Resolved / Known constraint)
	SuccessBg = Color3.fromRGB(18, 58, 45),
	InfoText = Color3.fromRGB(96, 165, 250), -- Blue (Potential order)
	InfoBg = Color3.fromRGB(24, 46, 78),
	WarningText = Color3.fromRGB(251, 191, 36), -- Amber (Undetermined order / Dormant)
	WarningBg = Color3.fromRGB(68, 48, 14),
	OrangeText = Color3.fromRGB(251, 146, 60), -- Orange (Partially resolved)
	OrangeBg = Color3.fromRGB(70, 36, 14),
	DangerText = Color3.fromRGB(248, 113, 113), -- Red (Unresolved / Cycle)
	DangerBg = Color3.fromRGB(72, 26, 28),
	NeutralBadgeText = Color3.fromRGB(175, 182, 195),
	NeutralBadgeBg = Color3.fromRGB(44, 47, 54),

	-- Graph & Container Visuals
	ServiceText = Color3.fromRGB(147, 197, 253),
	ServiceBg = Color3.fromRGB(28, 38, 62),
	ServiceBorder = Color3.fromRGB(68, 96, 152),
	ContainerText = Color3.fromRGB(190, 197, 210),
	ContainerBg = Color3.fromRGB(36, 39, 46),
	ContainerBorder = Color3.fromRGB(64, 70, 82),
	DynamicCyanText = Color3.fromRGB(56, 189, 248),
	DynamicCyanBg = Color3.fromRGB(16, 52, 74),
	EdgeStructural = Color3.fromRGB(82, 92, 110),
	EdgeStatic = Color3.fromRGB(52, 211, 153),
	EdgeDynamic = Color3.fromRGB(56, 189, 248),
	EdgeConditional = Color3.fromRGB(251, 191, 36),
	EdgeUnresolved = Color3.fromRGB(248, 113, 113),
	EdgeIncomingHighlight = Color3.fromRGB(52, 211, 153),
	EdgeOutgoingHighlight = Color3.fromRGB(168, 85, 247),
}

Theme.Fonts = {
	Regular = Enum.Font.SourceSans,
	SemiBold = Enum.Font.SourceSansSemibold,
	Bold = Enum.Font.SourceSansBold,
	Mono = Enum.Font.Code,
}

Theme.Sizes = {
	HeaderHeight = 40,
	NavBarHeight = 32,
	RowHeight = 28,
	CornerRadius = 4,
	ScrollBarThickness = 6,
}

function Theme.getClassVisuals(className: ScriptClassName): (string, string, Color3, Color3)
	if className == "Script" then
		return "[S]", "Script", Theme.Colors.ScriptText, Theme.Colors.ScriptBg
	elseif className == "LocalScript" then
		return "[L]", "LocalScript", Theme.Colors.LocalScriptText, Theme.Colors.LocalScriptBg
	else
		return "[M]", "ModuleScript", Theme.Colors.ModuleScriptText, Theme.Colors.ModuleScriptBg
	end
end

function Theme.getEnvironmentVisuals(env: ExecutionEnvironment | string): (string, Color3, Color3)
	if env == "Server" or env == "ServerModule" then
		return tostring(env), Theme.Colors.ScriptText, Theme.Colors.ScriptBg
	elseif env == "Client" or env == "ClientModule" then
		return tostring(env), Theme.Colors.LocalScriptText, Theme.Colors.LocalScriptBg
	elseif env == "SharedModule" then
		return "SharedModule", Theme.Colors.ModuleScriptText, Theme.Colors.ModuleScriptBg
	elseif env == "Plugin" then
		return "Plugin", Theme.Colors.InfoText, Theme.Colors.InfoBg
	elseif env == "UnreferencedModule" then
		return "Unreferenced", Theme.Colors.WarningText, Theme.Colors.WarningBg
	elseif env == "Inactive" then
		return "Dormant", Theme.Colors.NeutralBadgeText, Theme.Colors.NeutralBadgeBg
	else
		return tostring(env), Theme.Colors.InfoText, Theme.Colors.InfoBg
	end
end

function Theme.getResolutionVisuals(status: ResolutionStatus): (string, Color3, Color3)
	if status == "Resolved" then
		return "RESOLVED", Theme.Colors.SuccessText, Theme.Colors.SuccessBg
	elseif status == "PartiallyResolved" then
		return "PARTIAL", Theme.Colors.OrangeText, Theme.Colors.OrangeBg
	else
		return "UNRESOLVED", Theme.Colors.DangerText, Theme.Colors.DangerBg
	end
end

function Theme.getOrderCategoryVisuals(category: OrderDeterminism): (string, Color3, Color3)
	if category == "KnownConstraint" then
		return "KNOWN CONSTRAINT", Theme.Colors.SuccessText, Theme.Colors.SuccessBg
	elseif category == "PotentialOrder" then
		return "POTENTIAL ORDER", Theme.Colors.InfoText, Theme.Colors.InfoBg
	else
		return "UNDETERMINED", Theme.Colors.WarningText, Theme.Colors.WarningBg
	end
end

function Theme.getClassificationVisuals(classification: DependencyClassification): (string, Color3, Color3)
	if classification == "Static" then
		return "STATIC", Theme.Colors.SuccessText, Theme.Colors.SuccessBg
	elseif classification == "DynamicResolved" then
		return "DYNAMIC", Theme.Colors.DynamicCyanText, Theme.Colors.DynamicCyanBg
	elseif classification == "DynamicPartial" then
		return "DYN PARTIAL", Theme.Colors.OrangeText, Theme.Colors.OrangeBg
	elseif classification == "Conditional" then
		return "CONDITIONAL", Theme.Colors.WarningText, Theme.Colors.WarningBg
	else
		return "UNRESOLVED", Theme.Colors.DangerText, Theme.Colors.DangerBg
	end
end

function Theme.getNodeTypeVisuals(nodeType: GraphNodeType): (string, string, Color3, Color3, Color3)
	if nodeType == "Service" then
		return "[SRV]", "Service", Theme.Colors.ServiceText, Theme.Colors.ServiceBg, Theme.Colors.ServiceBorder
	elseif nodeType == "Folder" then
		return "[FLD]", "Folder", Theme.Colors.ContainerText, Theme.Colors.ContainerBg, Theme.Colors.ContainerBorder
	elseif nodeType == "Model" then
		return "[MDL]", "Model", Theme.Colors.ContainerText, Theme.Colors.ContainerBg, Theme.Colors.ContainerBorder
	elseif nodeType == "Container" then
		return "[CNT]", "Container", Theme.Colors.ContainerText, Theme.Colors.ContainerBg, Theme.Colors.ContainerBorder
	elseif nodeType == "Script" then
		return "[S]", "Script", Theme.Colors.ScriptText, Theme.Colors.ScriptBg, Theme.Colors.ScriptText
	elseif nodeType == "LocalScript" then
		return "[L]", "LocalScript", Theme.Colors.LocalScriptText, Theme.Colors.LocalScriptBg, Theme.Colors.LocalScriptText
	else
		return "[M]", "ModuleScript", Theme.Colors.ModuleScriptText, Theme.Colors.ModuleScriptBg, Theme.Colors.ModuleScriptText
	end
end

return Theme
