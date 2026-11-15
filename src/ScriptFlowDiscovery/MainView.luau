--!strict
--[[
	MainView.luau
	Constructs the main graphical interface inside the DockWidgetPluginGui (Section 3):
	- 3.1 Compact Header (Plugin name, scan status, last scan timestamp, Rescan button)
	- 3.2 Navigation Bar (Overview, Scripts, Dependencies, Execution Analysis)
	- Dedicated View Container hosting OverviewView, ScriptsView, DependenciesView, and ExecutionView
]]

local Types = require("./Types")
local Theme = require("./Theme")
local UIComponents = require("./UIComponents")
local OverviewView = require("./OverviewView")
local ScriptsView = require("./ScriptsView")
local DependenciesView = require("./DependenciesView")
local ExecutionView = require("./ExecutionView")

type ScanReport = Types.ScanReport
type NavigationTab = Types.NavigationTab

export type MainViewCallbacks = {
	onRequestRescan: () -> (),
	onRequestPrintOutput: () -> (),
}

export type MainViewInstance = {
	setScanningState: (isScanning: boolean) -> (),
	updateReport: (report: ScanReport) -> (),
	switchTab: (tab: NavigationTab) -> (),
	destroy: () -> (),
}

local MainView = {}

function MainView.create(
	dockWidget: DockWidgetPluginGui,
	callbacks: MainViewCallbacks
): MainViewInstance
	local connections: { RBXScriptConnection } = {}
	local activeTab: NavigationTab = "Overview"

	local rootBackground = Instance.new("Frame")
	rootBackground.Name = "MainRoot"
	rootBackground.Size = UDim2.fromScale(1, 1)
	rootBackground.BackgroundColor3 = Theme.Colors.MainBackground
	rootBackground.BorderSizePixel = 0
	rootBackground.Parent = dockWidget

	-- =========================================================================
	-- 3.1 Compact Header (40px height)
	-- =========================================================================
	local headerFrame = Instance.new("Frame")
	headerFrame.Name = "Header"
	headerFrame.Size = UDim2.new(1, 0, 0, Theme.Sizes.HeaderHeight)
	headerFrame.BackgroundColor3 = Theme.Colors.PanelHeader
	headerFrame.BorderSizePixel = 0
	headerFrame.Parent = rootBackground

	local headerBottomBorder = Instance.new("Frame")
	headerBottomBorder.Name = "BottomBorder"
	headerBottomBorder.Size = UDim2.new(1, 0, 0, 1)
	headerBottomBorder.Position = UDim2.new(0, 0, 1, -1)
	headerBottomBorder.BackgroundColor3 = Theme.Colors.Border
	headerBottomBorder.BorderSizePixel = 0
	headerBottomBorder.Parent = headerFrame

	-- Left side of Header: Title + Status Badge + Timestamp
	local headerLeft = Instance.new("Frame")
	headerLeft.Name = "HeaderLeft"
	headerLeft.Size = UDim2.new(1, -175, 1, 0)
	headerLeft.Position = UDim2.fromOffset(12, 0)
	headerLeft.BackgroundTransparency = 1
	headerLeft.Parent = headerFrame
	UIComponents.createListLayout(
		headerLeft,
		Enum.FillDirection.Horizontal,
		8,
		Enum.HorizontalAlignment.Left,
		Enum.VerticalAlignment.Center
	)

	local pluginTitleLabel = Instance.new("TextLabel")
	pluginTitleLabel.Name = "PluginTitle"
	pluginTitleLabel.LayoutOrder = 1
	pluginTitleLabel.Size = UDim2.fromOffset(0, 24)
	pluginTitleLabel.AutomaticSize = Enum.AutomaticSize.X
	pluginTitleLabel.BackgroundTransparency = 1
	pluginTitleLabel.Font = Theme.Fonts.Bold
	pluginTitleLabel.TextSize = 15
	pluginTitleLabel.TextColor3 = Theme.Colors.TextPrimary
	pluginTitleLabel.Text = "Illusion's ScriptFlowDiscovery"
	pluginTitleLabel.Parent = headerLeft

	local statusBadge = UIComponents.createBadge(
		headerLeft,
		"READY",
		Theme.Colors.SuccessText,
		Theme.Colors.SuccessBg,
		2
	)

	local timestampLabel = Instance.new("TextLabel")
	timestampLabel.Name = "TimestampLabel"
	timestampLabel.LayoutOrder = 3
	timestampLabel.Size = UDim2.fromOffset(0, 20)
	timestampLabel.AutomaticSize = Enum.AutomaticSize.X
	timestampLabel.BackgroundTransparency = 1
	timestampLabel.Font = Theme.Fonts.Regular
	timestampLabel.TextSize = 12
	timestampLabel.TextColor3 = Theme.Colors.TextMuted
	timestampLabel.Text = "Not scanned yet"
	timestampLabel.Parent = headerLeft

	-- Right side of Header: Print Log + Rescan Button
	local headerRight = Instance.new("Frame")
	headerRight.Name = "HeaderRight"
	headerRight.Size = UDim2.new(0, 160, 1, 0)
	headerRight.Position = UDim2.new(1, -170, 0, 0)
	headerRight.BackgroundTransparency = 1
	headerRight.Parent = headerFrame
	UIComponents.createListLayout(
		headerRight,
		Enum.FillDirection.Horizontal,
		6,
		Enum.HorizontalAlignment.Right,
		Enum.VerticalAlignment.Center
	)

	UIComponents.createButton(
		headerRight,
		"Print Log",
		UDim2.fromOffset(68, 26),
		false,
		1,
		function()
			callbacks.onRequestPrintOutput()
		end,
		connections
	)

	local rescanBtn = UIComponents.createButton(
		headerRight,
		"Rescan",
		UDim2.fromOffset(78, 26),
		true,
		2,
		function()
			callbacks.onRequestRescan()
		end,
		connections
	)

	-- =========================================================================
	-- 3.2 Navigation Tab Bar (32px height)
	-- =========================================================================
	local navBar = Instance.new("Frame")
	navBar.Name = "NavigationBar"
	navBar.Size = UDim2.new(1, 0, 0, Theme.Sizes.NavBarHeight)
	navBar.Position = UDim2.fromOffset(0, Theme.Sizes.HeaderHeight)
	navBar.BackgroundColor3 = Theme.Colors.PanelBackground
	navBar.BorderSizePixel = 0
	navBar.Parent = rootBackground

	local navBottomBorder = Instance.new("Frame")
	navBottomBorder.Name = "BottomBorder"
	navBottomBorder.Size = UDim2.new(1, 0, 0, 1)
	navBottomBorder.Position = UDim2.new(0, 0, 1, -1)
	navBottomBorder.BackgroundColor3 = Theme.Colors.Border
	navBottomBorder.BorderSizePixel = 0
	navBottomBorder.Parent = navBar

	local navTabsContainer = Instance.new("Frame")
	navTabsContainer.Name = "TabsContainer"
	navTabsContainer.Size = UDim2.new(1, -20, 1, 0)
	navTabsContainer.Position = UDim2.fromOffset(10, 0)
	navTabsContainer.BackgroundTransparency = 1
	navTabsContainer.Parent = navBar
	UIComponents.createListLayout(
		navTabsContainer,
		Enum.FillDirection.Horizontal,
		4,
		Enum.HorizontalAlignment.Left,
		Enum.VerticalAlignment.Bottom
	)

	local tabButtons: { [string]: TextButton } = {}
	local tabIndicators: { [string]: Frame } = {}

	local switchTab: (tab: NavigationTab) -> ()

	local function createNavTab(tabId: NavigationTab, defaultText: string, order: number): TextButton
		local btn = Instance.new("TextButton")
		btn.Name = "Tab_" .. tabId
		btn.LayoutOrder = order
		btn.Size = UDim2.fromOffset(0, Theme.Sizes.NavBarHeight - 2)
		btn.AutomaticSize = Enum.AutomaticSize.X
		btn.BackgroundColor3 = Theme.Colors.PanelBackground
		btn.BackgroundTransparency = 1
		btn.BorderSizePixel = 0
		btn.AutoButtonColor = false
		btn.Font = Theme.Fonts.Bold
		btn.TextSize = 13
		btn.TextColor3 = Theme.Colors.TextSecondary
		btn.Text = defaultText
		btn.Parent = navTabsContainer
		UIComponents.createPadding(btn, 0, 2, 12, 12)

		local underline = Instance.new("Frame")
		underline.Name = "ActiveUnderline"
		underline.Size = UDim2.new(1, 0, 0, 2)
		underline.Position = UDim2.new(0, 0, 1, 0)
		underline.BackgroundColor3 = Theme.Colors.AccentBlue
		underline.BorderSizePixel = 0
		underline.Visible = false
		underline.Parent = btn

		local key: string = tabId
		tabButtons[key] = btn
		tabIndicators[key] = underline

		table.insert(
			connections,
			btn.Activated:Connect(function()
				switchTab(tabId)
			end)
		)
		return btn
	end

	createNavTab("Overview", "Overview", 1)
	local scriptsTabBtn = createNavTab("Scripts", "Scripts", 2)
	local depsTabBtn = createNavTab("Dependencies", "Dependencies", 3)
	local execTabBtn = createNavTab("Execution", "Execution Analysis", 4)

	-- =========================================================================
	-- Content Area (hosts the 4 views)
	-- =========================================================================
	local topOffset = Theme.Sizes.HeaderHeight + Theme.Sizes.NavBarHeight
	local contentArea = Instance.new("Frame")
	contentArea.Name = "ContentArea"
	contentArea.Size = UDim2.new(1, 0, 1, -topOffset)
	contentArea.Position = UDim2.fromOffset(0, topOffset)
	contentArea.BackgroundTransparency = 1
	contentArea.Parent = rootBackground

	-- Loading Overlay while scanning
	local loadingOverlay = Instance.new("Frame")
	loadingOverlay.Name = "LoadingOverlay"
	loadingOverlay.Size = UDim2.fromScale(1, 1)
	loadingOverlay.BackgroundColor3 = Theme.Colors.MainBackground
	loadingOverlay.BackgroundTransparency = 0.25
	loadingOverlay.BorderSizePixel = 0
	loadingOverlay.ZIndex = 20
	loadingOverlay.Visible = false
	loadingOverlay.Parent = contentArea

	local loadingLabel = Instance.new("TextLabel")
	loadingLabel.Size = UDim2.fromOffset(260, 36)
	loadingLabel.Position = UDim2.fromScale(0.5, 0.5)
	loadingLabel.AnchorPoint = Vector2.new(0.5, 0.5)
	loadingLabel.BackgroundColor3 = Theme.Colors.PanelBackground
	loadingLabel.Font = Theme.Fonts.Bold
	loadingLabel.TextSize = 14
	loadingLabel.TextColor3 = Theme.Colors.TextPrimary
	loadingLabel.Text = "Scanning DataModel & Analyzing Flow..."
	loadingLabel.ZIndex = 21
	loadingLabel.Parent = loadingOverlay
	UIComponents.createCorner(loadingLabel, 6)
	UIComponents.createStroke(loadingLabel, Theme.Colors.AccentBlue, 1)

	-- Instantiate the 4 dedicated views
	local scriptsViewInstance = ScriptsView.create(contentArea)

	local dependenciesViewInstance = DependenciesView.create(contentArea, {
		onNavigateToScript = function(scriptPath: string)
			switchTab("Scripts")
			scriptsViewInstance.selectScriptByPath(scriptPath)
		end,
	})

	local executionViewInstance = ExecutionView.create(contentArea, {
		onNavigateToScript = function(scriptPath: string)
			switchTab("Scripts")
			scriptsViewInstance.selectScriptByPath(scriptPath)
		end,
	})

	local overviewViewInstance = OverviewView.create(contentArea, {
		onNavigateToScript = function(scriptPath: string)
			switchTab("Scripts")
			scriptsViewInstance.selectScriptByPath(scriptPath)
		end,
		onNavigateToDependencies = function(filterStatus: string?)
			switchTab("Dependencies")
			if filterStatus ~= nil then
				dependenciesViewInstance.setStatusFilter(filterStatus)
			end
		end,
		onNavigateToExecution = function()
			switchTab("Execution")
		end,
	})

	switchTab = function(tab: NavigationTab)
		activeTab = tab
		overviewViewInstance.frame.Visible = (tab == "Overview")
		scriptsViewInstance.frame.Visible = (tab == "Scripts")
		dependenciesViewInstance.frame.Visible = (tab == "Dependencies")
		executionViewInstance.frame.Visible = (tab == "Execution")

		local activeKey: string = activeTab
		for id, btn in tabButtons do
			local isActive = (id == activeKey)
			btn.TextColor3 = if isActive then Theme.Colors.TextPrimary else Theme.Colors.TextSecondary
			local indicator = tabIndicators[id]
			if indicator then
				indicator.Visible = isActive
			end
		end
	end

	switchTab("Overview")

	local function setScanningState(isScanning: boolean)
		loadingOverlay.Visible = isScanning
		if isScanning then
			statusBadge.Text = "SCANNING..."
			statusBadge.TextColor3 = Theme.Colors.InfoText
			statusBadge.BackgroundColor3 = Theme.Colors.InfoBg
			rescanBtn.Text = "Scanning..."
		else
			statusBadge.Text = "READY"
			statusBadge.TextColor3 = Theme.Colors.SuccessText
			statusBadge.BackgroundColor3 = Theme.Colors.SuccessBg
			rescanBtn.Text = "Rescan"
		end
	end

	local function updateReport(report: ScanReport)
		timestampLabel.Text = string.format(
			"Last scan: %s (%.1f ms)",
			report.timestamp,
			report.durationSeconds * 1000
		)

		local counts = report.counts
		local depAnalysis = report.dependencyAnalysis
		local execAnalysis = report.executionAnalysis
		local totalExecItems = #execAnalysis.knownConstraints
			+ #execAnalysis.potentialOrders
			+ #execAnalysis.undeterminedGroups

		scriptsTabBtn.Text = string.format("Scripts (%d)", counts.total)
		depsTabBtn.Text = string.format("Dependencies (%d)", #depAnalysis.allDependencies)
		execTabBtn.Text = string.format("Execution Analysis (%d)", totalExecItems)

		overviewViewInstance.render(report)
		scriptsViewInstance.render(report)
		dependenciesViewInstance.render(report)
		executionViewInstance.render(report)
	end

	local function destroy()
		for _, conn in connections do
			conn:Disconnect()
		end
		table.clear(connections)
		overviewViewInstance.destroy()
		scriptsViewInstance.destroy()
		dependenciesViewInstance.destroy()
		executionViewInstance.destroy()
		rootBackground:Destroy()
	end

	return {
		setScanningState = setScanningState,
		updateReport = updateReport,
		switchTab = switchTab,
		destroy = destroy,
	}
end

return MainView
