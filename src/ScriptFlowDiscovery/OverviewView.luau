--!strict
--[[
	OverviewView.luau
	Renders the Overview dashboard (Section 4):
	- 4.1 Scan Statistics Cards (9 dynamic metrics)
	- 4.2 Dependency Summary (Most Frequently Required ModuleScripts, Unreferenced Modules, Alerts)
	- 4.3 Recent Scan Information (Timestamp, Duration, Plugin Script Inclusion, Total Instances Analyzed)
]]

local Types = require("./Types")
local Theme = require("./Theme")
local UIComponents = require("./UIComponents")

type ScanReport = Types.ScanReport
type ScriptDependencySummary = Types.ScriptDependencySummary

export type OverviewCallbacks = {
	onNavigateToScript: (scriptPath: string) -> (),
	onNavigateToDependencies: (filterStatus: string?) -> (),
	onNavigateToExecution: () -> (),
}

export type OverviewViewInstance = {
	frame: ScrollingFrame,
	render: (report: ScanReport) -> (),
	destroy: () -> (),
}

local OverviewView = {}

function OverviewView.create(parent: Instance, callbacks: OverviewCallbacks): OverviewViewInstance
	local viewConnections: { RBXScriptConnection } = {}
	local dynamicConnections: { RBXScriptConnection } = {}

	local rootScroll = UIComponents.createScrollFrame(parent, "OverviewView", UDim2.fromScale(1, 1), 1)
	UIComponents.createPadding(rootScroll, 10, 14, 12, 12)
	UIComponents.createListLayout(rootScroll, Enum.FillDirection.Vertical, 12)

	-- =========================================================================
	-- 4.1 Statistics Grid
	-- =========================================================================
	local _, _, statsRightLabel = UIComponents.createSectionHeader(rootScroll, "Scan Statistics", "", 1)

	local statsGridContainer = Instance.new("Frame")
	statsGridContainer.Name = "StatsGridContainer"
	statsGridContainer.Size = UDim2.new(1, 0, 0, 0)
	statsGridContainer.AutomaticSize = Enum.AutomaticSize.Y
	statsGridContainer.LayoutOrder = 2
	statsGridContainer.BackgroundTransparency = 1
	statsGridContainer.Parent = rootScroll

	local gridLayout = Instance.new("UIGridLayout")
	gridLayout.CellSize = UDim2.fromOffset(152, 56)
	gridLayout.CellPadding = UDim2.fromOffset(8, 8)
	gridLayout.SortOrder = Enum.SortOrder.LayoutOrder
	gridLayout.FillDirection = Enum.FillDirection.Horizontal
	gridLayout.Parent = statsGridContainer

	local _, valTotalScripts, subTotalScripts = UIComponents.createStatCard(
		statsGridContainer,
		"Total Scripts",
		"0",
		"Discovered in DataModel",
		Theme.Colors.AccentBlue,
		1
	)
	local _, valServerScripts, subServerScripts = UIComponents.createStatCard(
		statsGridContainer,
		"Scripts",
		"0",
		"Server / Legacy / Plugin",
		Theme.Colors.ScriptText,
		2
	)
	local _, valLocalScripts, subLocalScripts = UIComponents.createStatCard(
		statsGridContainer,
		"LocalScripts",
		"0",
		"Client scripts",
		Theme.Colors.LocalScriptText,
		3
	)
	local _, valModuleScripts, subModuleScripts = UIComponents.createStatCard(
		statsGridContainer,
		"ModuleScripts",
		"0",
		"Reusable modules",
		Theme.Colors.ModuleScriptText,
		4
	)
	local _, valActiveExec, subActiveExec = UIComponents.createStatCard(
		statsGridContainer,
		"Active Executables",
		"0",
		"Eligible to auto-run",
		Theme.Colors.SuccessText,
		5
	)
	local _, valDormantExec, subDormantExec = UIComponents.createStatCard(
		statsGridContainer,
		"Dormant / Disabled",
		"0",
		"Inactive container or disabled",
		Theme.Colors.WarningText,
		6
	)
	local _, valTotalRequires, subTotalRequires = UIComponents.createStatCard(
		statsGridContainer,
		"Total require() Calls",
		"0",
		"Static calls analyzed",
		Theme.Colors.InfoText,
		7
	)
	local _, valResolvedDeps, subResolvedDeps = UIComponents.createStatCard(
		statsGridContainer,
		"Resolved Dependencies",
		"0",
		"Target ModuleScript found",
		Theme.Colors.SuccessText,
		8
	)
	local cardUnresolved, valUnresolvedDeps, subUnresolvedDeps = UIComponents.createStatCard(
		statsGridContainer,
		"Unresolved Dependencies",
		"0",
		"Dynamic or missing path",
		Theme.Colors.OrangeText,
		9
	)

	-- =========================================================================
	-- 4.2 Dependency Summary
	-- =========================================================================
	local _, _, depSummaryRight = UIComponents.createSectionHeader(rootScroll, "Dependency Summary", "", 3)

	local depSummaryPanel = UIComponents.createPanel(rootScroll, "DependencySummaryPanel", UDim2.new(1, 0, 0, 0), 4)
	depSummaryPanel.AutomaticSize = Enum.AutomaticSize.Y
	UIComponents.createPadding(depSummaryPanel, 10, 10, 10, 10)
	UIComponents.createListLayout(depSummaryPanel, Enum.FillDirection.Vertical, 8)

	-- =========================================================================
	-- 4.3 Recent Scan Information
	-- =========================================================================
	UIComponents.createSectionHeader(rootScroll, "Recent Scan Information", "", 5)

	local scanInfoPanel = UIComponents.createPanel(rootScroll, "RecentScanInfoPanel", UDim2.new(1, 0, 0, 0), 6)
	scanInfoPanel.AutomaticSize = Enum.AutomaticSize.Y
	UIComponents.createPadding(scanInfoPanel, 10, 10, 10, 10)
	UIComponents.createListLayout(scanInfoPanel, Enum.FillDirection.Vertical, 4)

	local _, valTimestamp = UIComponents.createKeyValueRow(scanInfoPanel, "Scan Timestamp", "-", nil, 1)
	local _, valDuration = UIComponents.createKeyValueRow(scanInfoPanel, "Scan Duration", "-", nil, 2)
	local _, valInstancesAnalyzed = UIComponents.createKeyValueRow(scanInfoPanel, "Instances Analyzed", "-", nil, 3)
	local _, valSourceAccess = UIComponents.createKeyValueRow(scanInfoPanel, "Source Access", "-", nil, 4)

	local function clearDynamicDeps()
		for _, conn in dynamicConnections do
			conn:Disconnect()
		end
		table.clear(dynamicConnections)

		for _, child in depSummaryPanel:GetChildren() do
			if not child:IsA("UILayout") and not child:IsA("UIPadding") and not child:IsA("UICorner") and not child:IsA("UIStroke") then
				child:Destroy()
			end
		end
	end

	local function render(report: ScanReport)
		local counts = report.counts
		local depAnalysis = report.dependencyAnalysis
		local execAnalysis = report.executionAnalysis

		statsRightLabel.Text = string.format("%d instances scanned", counts.instancesAnalyzed)

		valTotalScripts.Text = tostring(counts.total)
		subTotalScripts.Text = string.format("%d executable, %d modules", counts.serverScripts + counts.localScripts, counts.moduleScripts)

		valServerScripts.Text = tostring(counts.serverScripts)
		subServerScripts.Text = "ClassName: Script"

		valLocalScripts.Text = tostring(counts.localScripts)
		subLocalScripts.Text = "ClassName: LocalScript"

		valModuleScripts.Text = tostring(counts.moduleScripts)
		subModuleScripts.Text = string.format("%d unreferenced", #depAnalysis.unusedModulePaths)

		valActiveExec.Text = tostring(counts.executableActive)
		subActiveExec.Text = "Auto-executing scripts"

		valDormantExec.Text = tostring(counts.executableDormant)
		subDormantExec.Text = "Disabled or dormant container"

		valTotalRequires.Text = tostring(#depAnalysis.allDependencies)
		subTotalRequires.Text = "Total require() expressions"

		valResolvedDeps.Text = tostring(#depAnalysis.resolvedDependencies)
		subResolvedDeps.Text = "Statically linked to modules"

		local unresolvedCount = #depAnalysis.unresolvedDependencies
		valUnresolvedDeps.Text = tostring(unresolvedCount)
		subUnresolvedDeps.Text = if unresolvedCount == 0 then "All requires resolved" else "Click to inspect in Dependencies"
		local unresolvedBar = cardUnresolved:FindFirstChild("AccentBar")
		if unresolvedBar ~= nil and unresolvedBar:IsA("Frame") then
			unresolvedBar.BackgroundColor3 = if unresolvedCount == 0
				then Theme.Colors.SuccessText
				else Theme.Colors.DangerText
		end

		-- Update Recent Scan Information (4.3)
		valTimestamp.Text = report.timestamp
		valDuration.Text = string.format("%.2f ms", report.durationSeconds * 1000)
		valInstancesAnalyzed.Text = string.format("%d DataModel instances traversed", counts.instancesAnalyzed)
		valSourceAccess.Text = if counts.inaccessibleSources == 0
			then string.format("100%% accessible (%d / %d scripts)", counts.total, counts.total)
			else string.format(
				"%d accessible, %d restricted by permissions",
				counts.total - counts.inaccessibleSources,
				counts.inaccessibleSources
			)
		valSourceAccess.TextColor3 = if counts.inaccessibleSources == 0
			then Theme.Colors.SuccessText
			else Theme.Colors.WarningText

		-- Rebuild 4.2 Dependency Summary
		clearDynamicDeps()

		depSummaryRight.Text = string.format(
			"%d relationships · %d unresolved",
			#depAnalysis.allDependencies,
			unresolvedCount
		)

		-- Top Quick Summary Row inside Dependency Summary Panel
		local quickBar = Instance.new("Frame")
		quickBar.Name = "QuickMetricsBar"
		quickBar.Size = UDim2.new(1, 0, 0, 26)
		quickBar.AutomaticSize = Enum.AutomaticSize.Y
		quickBar.LayoutOrder = 1
		quickBar.BackgroundTransparency = 1
		quickBar.Parent = depSummaryPanel

		local quickLayout = UIComponents.createListLayout(
			quickBar,
			Enum.FillDirection.Horizontal,
			6,
			Enum.HorizontalAlignment.Left,
			Enum.VerticalAlignment.Center
		)
		quickLayout.Wraps = true

		UIComponents.createBadge(
			quickBar,
			string.format("Relationships: %d", #depAnalysis.allDependencies),
			Theme.Colors.InfoText,
			Theme.Colors.InfoBg,
			1
		)
		UIComponents.createBadge(
			quickBar,
			string.format("Resolved: %d", #depAnalysis.resolvedDependencies),
			Theme.Colors.SuccessText,
			Theme.Colors.SuccessBg,
			2
		)
		UIComponents.createBadge(
			quickBar,
			string.format("Unresolved: %d", unresolvedCount),
			if unresolvedCount > 0 then Theme.Colors.OrangeText else Theme.Colors.SuccessText,
			if unresolvedCount > 0 then Theme.Colors.OrangeBg else Theme.Colors.SuccessBg,
			3
		)
		UIComponents.createBadge(
			quickBar,
			string.format("Circular Chains: %d", #depAnalysis.circularChains),
			if #depAnalysis.circularChains > 0 then Theme.Colors.DangerText else Theme.Colors.NeutralBadgeText,
			if #depAnalysis.circularChains > 0 then Theme.Colors.DangerBg else Theme.Colors.NeutralBadgeBg,
			4
		)

		if unresolvedCount > 0 then
			UIComponents.createButton(
				quickBar,
				"Inspect Unresolved →",
				UDim2.fromOffset(132, 22),
				false,
				5,
				function()
					callbacks.onNavigateToDependencies("Unresolved")
				end,
				dynamicConnections
			)
		end

		-- Collect and sort ModuleScripts by number of requirers
		local moduleSummaries: { ScriptDependencySummary } = {}
		for _, scriptInfo in report.scripts do
			if scriptInfo.isModule then
				local sum = depAnalysis.byScriptPath[scriptInfo.fullPath]
				if sum ~= nil and #sum.requiredByPaths > 0 then
					table.insert(moduleSummaries, sum)
				end
			end
		end

		table.sort(moduleSummaries, function(a: ScriptDependencySummary, b: ScriptDependencySummary): boolean
			if #a.requiredByPaths ~= #b.requiredByPaths then
				return #a.requiredByPaths > #b.requiredByPaths
			end
			return a.script.fullPath < b.script.fullPath
		end)

		-- Sub-header: Most Frequently Required ModuleScripts
		local mostReqHeader = Instance.new("TextLabel")
		mostReqHeader.Name = "MostRequiredHeader"
		mostReqHeader.LayoutOrder = 2
		mostReqHeader.Size = UDim2.new(1, 0, 0, 18)
		mostReqHeader.BackgroundTransparency = 1
		mostReqHeader.Font = Theme.Fonts.Bold
		mostReqHeader.TextSize = 12
		mostReqHeader.TextColor3 = Theme.Colors.TextSecondary
		mostReqHeader.TextXAlignment = Enum.TextXAlignment.Left
		mostReqHeader.Text = string.format("Most Frequently Required ModuleScripts (%d active)", #moduleSummaries)
		mostReqHeader.Parent = depSummaryPanel

		if #moduleSummaries == 0 then
			local noneLbl = Instance.new("TextLabel")
			noneLbl.Name = "NoneRequired"
			noneLbl.LayoutOrder = 3
			noneLbl.Size = UDim2.new(1, 0, 0, 20)
			noneLbl.BackgroundTransparency = 1
			noneLbl.Font = Theme.Fonts.Regular
			noneLbl.TextSize = 12
			noneLbl.TextColor3 = Theme.Colors.TextMuted
			noneLbl.TextXAlignment = Enum.TextXAlignment.Left
			noneLbl.Text = "No ModuleScripts are currently required by any discovered scripts."
			noneLbl.Parent = depSummaryPanel
		else
			local maxToShow = math.min(#moduleSummaries, 8)
			local listFrame = Instance.new("Frame")
			listFrame.Name = "MostRequiredList"
			listFrame.Size = UDim2.new(1, 0, 0, 0)
			listFrame.AutomaticSize = Enum.AutomaticSize.Y
			listFrame.LayoutOrder = 3
			listFrame.BackgroundTransparency = 1
			listFrame.Parent = depSummaryPanel
			UIComponents.createListLayout(listFrame, Enum.FillDirection.Vertical, 4)

			for i = 1, maxToShow do
				local sum = moduleSummaries[i]
				local modScript = sum.script
				local prof = execAnalysis.profilesByPath[modScript.fullPath]
				local envStr = if prof ~= nil then tostring(prof.environment) else "Module"

				local rowBtn = Instance.new("TextButton")
				rowBtn.Name = "ModRow_" .. modScript.name
				rowBtn.LayoutOrder = i
				rowBtn.Size = UDim2.new(1, 0, 0, 26)
				rowBtn.BackgroundColor3 = Theme.Colors.RowBackground
				rowBtn.BorderSizePixel = 0
				rowBtn.AutoButtonColor = true
				rowBtn.Text = ""
				rowBtn.Parent = listFrame
				UIComponents.createCorner(rowBtn, 3)

				local badge = UIComponents.createClassBadge(rowBtn, "ModuleScript", true, 1)
				badge.Position = UDim2.fromOffset(6, 4)

				local nameLbl = Instance.new("TextLabel")
				nameLbl.Name = "Name"
				nameLbl.Size = UDim2.new(0.42, -38, 1, 0)
				nameLbl.Position = UDim2.fromOffset(36, 0)
				nameLbl.BackgroundTransparency = 1
				nameLbl.Font = Theme.Fonts.Bold
				nameLbl.TextSize = 13
				nameLbl.TextColor3 = Theme.Colors.TextPrimary
				nameLbl.TextXAlignment = Enum.TextXAlignment.Left
				nameLbl.TextTruncate = Enum.TextTruncate.AtEnd
				nameLbl.Text = modScript.name
				nameLbl.Parent = rowBtn

				local pathLbl = Instance.new("TextLabel")
				pathLbl.Name = "Path"
				pathLbl.Size = UDim2.new(0.36, 0, 1, 0)
				pathLbl.Position = UDim2.fromScale(0.42, 0)
				pathLbl.BackgroundTransparency = 1
				pathLbl.Font = Theme.Fonts.Mono
				pathLbl.TextSize = 11
				pathLbl.TextColor3 = Theme.Colors.TextMuted
				pathLbl.TextXAlignment = Enum.TextXAlignment.Left
				pathLbl.TextTruncate = Enum.TextTruncate.AtEnd
				pathLbl.Text = modScript.parentPath
				pathLbl.Parent = rowBtn

				local rightHolder = Instance.new("Frame")
				rightHolder.Name = "RightBadges"
				rightHolder.Size = UDim2.new(0.22, -6, 1, 0)
				rightHolder.Position = UDim2.fromScale(0.78, 0)
				rightHolder.BackgroundTransparency = 1
				rightHolder.Parent = rowBtn
				UIComponents.createListLayout(
					rightHolder,
					Enum.FillDirection.Horizontal,
					4,
					Enum.HorizontalAlignment.Right,
					Enum.VerticalAlignment.Center
				)

				UIComponents.createEnvironmentBadge(rightHolder, envStr, 1)
				UIComponents.createBadge(
					rightHolder,
					string.format("%d req", #sum.requiredByPaths),
					Theme.Colors.ModuleScriptText,
					Theme.Colors.ModuleScriptBg,
					2
				)

				local targetPath = modScript.fullPath
				table.insert(
					dynamicConnections,
					rowBtn.Activated:Connect(function()
						callbacks.onNavigateToScript(targetPath)
					end)
				)
			end
		end

		-- Sub-header: Modules With No Detected Requirers
		local unusedHeader = Instance.new("TextLabel")
		unusedHeader.Name = "UnusedModulesHeader"
		unusedHeader.LayoutOrder = 4
		unusedHeader.Size = UDim2.new(1, 0, 0, 18)
		unusedHeader.BackgroundTransparency = 1
		unusedHeader.Font = Theme.Fonts.Bold
		unusedHeader.TextSize = 12
		unusedHeader.TextColor3 = Theme.Colors.TextSecondary
		unusedHeader.TextXAlignment = Enum.TextXAlignment.Left
		unusedHeader.Text = string.format(
			"Modules With No Detected Requirers (%d)",
			#depAnalysis.unusedModulePaths
		)
		unusedHeader.Parent = depSummaryPanel

		if #depAnalysis.unusedModulePaths == 0 then
			local allUsedLbl = Instance.new("TextLabel")
			allUsedLbl.Name = "AllModulesReferenced"
			allUsedLbl.LayoutOrder = 5
			allUsedLbl.Size = UDim2.new(1, 0, 0, 20)
			allUsedLbl.BackgroundTransparency = 1
			allUsedLbl.Font = Theme.Fonts.Regular
			allUsedLbl.TextSize = 12
			allUsedLbl.TextColor3 = Theme.Colors.SuccessText
			allUsedLbl.TextXAlignment = Enum.TextXAlignment.Left
			allUsedLbl.Text = "Every discovered ModuleScript has at least one static require() caller."
			allUsedLbl.Parent = depSummaryPanel
		else
			local unusedFlow = Instance.new("Frame")
			unusedFlow.Name = "UnusedModulesList"
			unusedFlow.Size = UDim2.new(1, 0, 0, 0)
			unusedFlow.AutomaticSize = Enum.AutomaticSize.Y
			unusedFlow.LayoutOrder = 5
			unusedFlow.BackgroundTransparency = 1
			unusedFlow.Parent = depSummaryPanel

			local unusedLayout = UIComponents.createListLayout(
				unusedFlow,
				Enum.FillDirection.Horizontal,
				6,
				Enum.HorizontalAlignment.Left,
				Enum.VerticalAlignment.Center
			)
			unusedLayout.Wraps = true

			for idx, unusedPath in depAnalysis.unusedModulePaths do
				local sum = depAnalysis.byScriptPath[unusedPath]
				local displayName = if sum ~= nil then sum.script.name else unusedPath
				local chipBtn = Instance.new("TextButton")
				chipBtn.Name = "Unused_" .. displayName
				chipBtn.LayoutOrder = idx
				chipBtn.Size = UDim2.fromOffset(0, 22)
				chipBtn.AutomaticSize = Enum.AutomaticSize.X
				chipBtn.BackgroundColor3 = Theme.Colors.WarningBg
				chipBtn.BorderSizePixel = 0
				chipBtn.Font = Theme.Fonts.SemiBold
				chipBtn.TextSize = 12
				chipBtn.TextColor3 = Theme.Colors.WarningText
				chipBtn.Text = "[M] " .. displayName
				chipBtn.Parent = unusedFlow
				UIComponents.createCorner(chipBtn, 3)
				UIComponents.createPadding(chipBtn, 0, 0, 8, 8)

				local targetPath = unusedPath
				table.insert(
					dynamicConnections,
					chipBtn.Activated:Connect(function()
						callbacks.onNavigateToScript(targetPath)
					end)
				)
			end
		end
	end

	local function destroy()
		clearDynamicDeps()
		for _, conn in viewConnections do
			conn:Disconnect()
		end
		table.clear(viewConnections)
		rootScroll:Destroy()
	end

	return {
		frame = rootScroll,
		render = render,
		destroy = destroy,
	}
end

return OverviewView
