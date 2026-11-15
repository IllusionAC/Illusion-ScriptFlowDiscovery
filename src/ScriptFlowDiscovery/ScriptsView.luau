--!strict
--[[
	ScriptsView.luau
	Renders the Scripts Explorer (Section 5):
	- 5.1 Structured Script Table with visual class/context/state indicators
	- 5.2 Combined Search (by name or full path) and Filtering (Type, Context, Enabled state)
	- 5.3 Interactive Script Details Inspector with Studio Selection, Open Script, Copy Path,
	      and clickable Dependency & Requirer navigation
]]

local Types = require("./Types")
local Theme = require("./Theme")
local UIComponents = require("./UIComponents")

type ScanReport = Types.ScanReport
type DiscoveredScript = Types.DiscoveredScript

export type ScriptsViewInstance = {
	frame: Frame,
	render: (report: ScanReport) -> (),
	selectScriptByPath: (scriptPath: string) -> (),
	destroy: () -> (),
}

local ScriptsView = {}

local PAGE_SIZE = 100

function ScriptsView.create(parent: Instance): ScriptsViewInstance
	local viewConnections: { RBXScriptConnection } = {}
	local listConnections: { RBXScriptConnection } = {}
	local detailConnections: { RBXScriptConnection } = {}

	local currentReport: ScanReport? = nil
	local selectedScriptPath: string? = nil
	local searchQuery = ""
	local filterType = "All"
	local filterContext = "All"
	local filterState = "All"
	local currentPage = 1

	local rootFrame = Instance.new("Frame")
	rootFrame.Name = "ScriptsView"
	rootFrame.Size = UDim2.fromScale(1, 1)
	rootFrame.BackgroundTransparency = 1
	rootFrame.Visible = false
	rootFrame.Parent = parent

	UIComponents.createPadding(rootFrame, 8, 8, 10, 10)

	-- =========================================================================
	-- Top Filter & Search Toolbar
	-- =========================================================================
	local filterOuter = UIComponents.createPanel(rootFrame, "FilterToolbar", UDim2.new(1, 0, 0, 148), 1)
	filterOuter.AutomaticSize = Enum.AutomaticSize.Y

	local filterPanel = Instance.new("Frame")
	filterPanel.Name = "FilterToolbarContent"
	filterPanel.Size = UDim2.fromScale(1, 1)
	filterPanel.AutomaticSize = Enum.AutomaticSize.Y
	filterPanel.BackgroundTransparency = 1
	filterPanel.Parent = filterOuter
	UIComponents.createPadding(filterPanel, 10, 12, 12, 14)
	UIComponents.createListLayout(filterPanel, Enum.FillDirection.Vertical, 7)

	UIComponents.attachPanelEdgeResizers(filterOuter, {
		minHeight = 84,
		maxHeight = 320,
		minWidth = 360,
		enableBottom = true,
		enableRight = true,
		enableCorner = true,
	}, viewConnections)

	local topSearchRow = Instance.new("Frame")
	topSearchRow.Name = "TopSearchRow"
	topSearchRow.Size = UDim2.new(1, 0, 0, 28)
	topSearchRow.LayoutOrder = 1
	topSearchRow.BackgroundTransparency = 1
	topSearchRow.Parent = filterPanel

	local applyFiltersAndRenderList: () -> ()

	local searchBoxFrame, _, resetSearchInput = UIComponents.createSearchInput(
		topSearchRow,
		"Search by script name or full DataModel path...",
		UDim2.new(1, -155, 1, 0),
		1,
		function(newText: string)
			searchQuery = string.lower(newText)
			currentPage = 1
			applyFiltersAndRenderList()
		end,
		viewConnections
	)
	searchBoxFrame.Position = UDim2.fromOffset(0, 0)

	local countStatusLabel = Instance.new("TextLabel")
	countStatusLabel.Name = "CountStatus"
	countStatusLabel.Size = UDim2.new(0, 148, 1, 0)
	countStatusLabel.Position = UDim2.new(1, -148, 0, 0)
	countStatusLabel.BackgroundTransparency = 1
	countStatusLabel.Font = Theme.Fonts.SemiBold
	countStatusLabel.TextSize = 12
	countStatusLabel.TextColor3 = Theme.Colors.TextSecondary
	countStatusLabel.TextXAlignment = Enum.TextXAlignment.Right
	countStatusLabel.Text = "0 scripts"
	countStatusLabel.Parent = topSearchRow

	local _, setTypeChip = UIComponents.createFilterBar(
		filterPanel,
		"Type",
		{
			{ id = "All", label = "All" },
			{ id = "Script", label = "[S] Script" },
			{ id = "LocalScript", label = "[L] LocalScript" },
			{ id = "ModuleScript", label = "[M] ModuleScript" },
		},
		"All",
		2,
		function(id: string)
			filterType = id
			currentPage = 1
			applyFiltersAndRenderList()
		end,
		viewConnections
	)

	local _, setContextChip = UIComponents.createFilterBar(
		filterPanel,
		"Context",
		{
			{ id = "All", label = "All" },
			{ id = "Server", label = "Server" },
			{ id = "Client", label = "Client" },
			{ id = "Shared", label = "Shared" },
			{ id = "Plugin", label = "Plugin" },
			{ id = "Dormant", label = "Dormant / Unref" },
		},
		"All",
		3,
		function(id: string)
			filterContext = id
			currentPage = 1
			applyFiltersAndRenderList()
		end,
		viewConnections
	)

	local _, setStateChip = UIComponents.createFilterBar(
		filterPanel,
		"State",
		{
			{ id = "All", label = "All" },
			{ id = "Active", label = "Enabled / Active" },
			{ id = "Inactive", label = "Disabled / Dormant" },
		},
		"All",
		4,
		function(id: string)
			filterState = id
			currentPage = 1
			applyFiltersAndRenderList()
		end,
		viewConnections
	)

	-- =========================================================================
	-- Split Content Area: Left (Script Table) | Right (Script Details Panel)
	-- =========================================================================
	local splitContainer = Instance.new("Frame")
	splitContainer.Name = "SplitContainer"
	splitContainer.Size = UDim2.new(1, 0, 1, -156)
	splitContainer.Position = UDim2.fromOffset(0, 156)
	splitContainer.BackgroundTransparency = 1
	splitContainer.Parent = rootFrame

	local function syncSplitLayout()
		local panelHeight = math.max(84, filterOuter.AbsoluteSize.Y)
		local topOffset = panelHeight + 8
		splitContainer.Position = UDim2.fromOffset(0, topOffset)
		splitContainer.Size = UDim2.new(1, 0, 1, -topOffset)
	end
	table.insert(viewConnections, filterOuter:GetPropertyChangedSignal("AbsoluteSize"):Connect(syncSplitLayout))
	syncSplitLayout()

	-- Left List Panel (55% width)
	local listPanel = UIComponents.createPanel(splitContainer, "ScriptListPanel", UDim2.new(0.55, -5, 1, 0), 1)

	-- Table Column Header
	local tableHeader = Instance.new("Frame")
	tableHeader.Name = "TableHeader"
	tableHeader.Size = UDim2.new(1, 0, 0, 24)
	tableHeader.BackgroundColor3 = Theme.Colors.PanelHeader
	tableHeader.BorderSizePixel = 0
	tableHeader.Parent = listPanel
	UIComponents.createCorner(tableHeader, Theme.Sizes.CornerRadius)

	local function createHeaderCol(text: string, posScale: number, widthScale: number, align: Enum.TextXAlignment)
		local lbl = Instance.new("TextLabel")
		lbl.Size = UDim2.new(widthScale, -8, 1, 0)
		lbl.Position = UDim2.new(posScale, 6, 0, 0)
		lbl.BackgroundTransparency = 1
		lbl.Font = Theme.Fonts.Bold
		lbl.TextSize = 11
		lbl.TextColor3 = Theme.Colors.TextMuted
		lbl.TextXAlignment = align
		lbl.Text = text
		lbl.Parent = tableHeader
	end

	createHeaderCol("SCRIPT NAME & LOCATION", 0, 0.48, Enum.TextXAlignment.Left)
	createHeaderCol("CONTEXT", 0.48, 0.24, Enum.TextXAlignment.Left)
	createHeaderCol("STATE", 0.72, 0.14, Enum.TextXAlignment.Left)
	createHeaderCol("DEPS", 0.86, 0.14, Enum.TextXAlignment.Right)

	local listScroll = UIComponents.createScrollFrame(listPanel, "RowsScroll", UDim2.new(1, 0, 1, -24), 2)
	listScroll.Position = UDim2.fromOffset(0, 24)
	UIComponents.createPadding(listScroll, 4, 6, 4, 4)
	UIComponents.createListLayout(listScroll, Enum.FillDirection.Vertical, 2)

	-- Right Details Panel (45% width)
	local detailPanel = UIComponents.createPanel(splitContainer, "ScriptDetailsPanel", UDim2.new(0.45, -5, 1, 0), 2)
	detailPanel.Position = UDim2.new(0.55, 5, 0, 0)

	local detailScroll = UIComponents.createScrollFrame(detailPanel, "DetailScroll", UDim2.fromScale(1, 1), 1)
	UIComponents.createPadding(detailScroll, 10, 12, 10, 10)
	UIComponents.createListLayout(detailScroll, Enum.FillDirection.Vertical, 8)

	-- Interactive split resizer between Script List (left) and Script Details (right)
	UIComponents.attachHorizontalSplitResizer(
		splitContainer,
		listPanel,
		detailPanel,
		0.55,
		0.25,
		0.78,
		viewConnections
	)

	-- Edge resizers on both panels
	UIComponents.attachPanelEdgeResizers(listPanel, {
		minHeight = 140,
		maxHeight = 1200,
		enableBottom = true,
		enableRight = false,
		enableCorner = false,
	}, viewConnections)

	UIComponents.attachPanelEdgeResizers(detailPanel, {
		minHeight = 140,
		maxHeight = 1200,
		minWidth = 220,
		enableBottom = true,
		enableRight = true,
		enableCorner = true,
	}, viewConnections)

	local rowFramesByPath: { [string]: TextButton } = {}

	local function updateRowSelectionVisuals()
		for path, btn in rowFramesByPath do
			local isSelected = (path == selectedScriptPath)
			btn.BackgroundColor3 = if isSelected then Theme.Colors.RowSelected else Theme.Colors.RowBackground
		end
	end

	local function clearDetailPanel()
		for _, conn in detailConnections do
			conn:Disconnect()
		end
		table.clear(detailConnections)

		for _, child in detailScroll:GetChildren() do
			if not child:IsA("UILayout") and not child:IsA("UIPadding") then
				child:Destroy()
			end
		end
	end

	local renderDetailsForSelected: () -> ()

	local function selectScript(scriptPath: string)
		selectedScriptPath = scriptPath
		updateRowSelectionVisuals()
		renderDetailsForSelected()
	end

	renderDetailsForSelected = function()
		clearDetailPanel()

		local report = currentReport
		local currentPath = selectedScriptPath
		if report == nil or currentPath == nil then
			UIComponents.createEmptyState(
				detailScroll,
				"No Script Selected",
				"Select any Script, LocalScript, or ModuleScript from the list to inspect its metadata, execution eligibility, dependencies, and requirers.",
				1
			)
			return
		end

		local depSummary = report.dependencyAnalysis.byScriptPath[currentPath]
		local execProfile = report.executionAnalysis.profilesByPath[currentPath]
		if depSummary == nil or execProfile == nil then
			UIComponents.createEmptyState(
				detailScroll,
				"Script Not Found",
				"The selected script is not present in the current scan report.",
				1
			)
			return
		end

		local scriptInfo = depSummary.script

		-- 1. Top Title + Class Badge
		local titleRow = Instance.new("Frame")
		titleRow.Name = "TitleRow"
		titleRow.Size = UDim2.new(1, 0, 0, 24)
		titleRow.LayoutOrder = 1
		titleRow.BackgroundTransparency = 1
		titleRow.Parent = detailScroll

		UIComponents.createClassBadge(titleRow, scriptInfo.className, false, 1)

		local titleLabel = Instance.new("TextLabel")
		titleLabel.Name = "ScriptTitle"
		titleLabel.Size = UDim2.new(1, -115, 1, 0)
		titleLabel.Position = UDim2.fromOffset(112, 0)
		titleLabel.BackgroundTransparency = 1
		titleLabel.Font = Theme.Fonts.Bold
		titleLabel.TextSize = 15
		titleLabel.TextColor3 = Theme.Colors.TextPrimary
		titleLabel.TextXAlignment = Enum.TextXAlignment.Left
		titleLabel.TextTruncate = Enum.TextTruncate.AtEnd
		titleLabel.Text = scriptInfo.name
		titleLabel.Parent = titleRow

		-- 2. Copyable Full Instance Path
		UIComponents.createCopyPathBox(detailScroll, scriptInfo.fullPath, 2, detailConnections)

		-- 3. Studio Integration Buttons (Select in Explorer / Open in Script Editor)
		local actionsRow = Instance.new("Frame")
		actionsRow.Name = "StudioActionsRow"
		actionsRow.Size = UDim2.new(1, 0, 0, 26)
		actionsRow.LayoutOrder = 3
		actionsRow.BackgroundTransparency = 1
		actionsRow.Parent = detailScroll
		UIComponents.createListLayout(
			actionsRow,
			Enum.FillDirection.Horizontal,
			6,
			Enum.HorizontalAlignment.Left,
			Enum.VerticalAlignment.Center
		)

		UIComponents.createButton(
			actionsRow,
			"Select in Explorer",
			UDim2.fromOffset(124, 24),
			true,
			1,
			function()
				UIComponents.selectInstanceInStudio(scriptInfo.instance)
			end,
			detailConnections
		)

		UIComponents.createButton(
			actionsRow,
			"Open in Editor",
			UDim2.fromOffset(110, 24),
			false,
			2,
			function()
				UIComponents.openScriptInStudio(scriptInfo.instance, 1)
			end,
			detailConnections
		)

		-- 4. Metadata Card
		local metaCard = UIComponents.createPanel(detailScroll, "MetadataCard", UDim2.new(1, 0, 0, 0), 4, Theme.Colors.RowAlternate)
		metaCard.AutomaticSize = Enum.AutomaticSize.Y
		UIComponents.createPadding(metaCard, 8, 8, 8, 8)
		UIComponents.createListLayout(metaCard, Enum.FillDirection.Vertical, 4)

		local enabledStr = if scriptInfo.isModule
			then "N/A (ModuleScript)"
			elseif scriptInfo.isEnabled == false then "Disabled (false)"
			else "Enabled (true)"

		local enabledColor = if scriptInfo.isModule
			then Theme.Colors.TextSecondary
			elseif scriptInfo.isEnabled == false then Theme.Colors.WarningText
			else Theme.Colors.SuccessText

		UIComponents.createKeyValueRow(metaCard, "Name", scriptInfo.name, nil, 1)
		UIComponents.createKeyValueRow(
			metaCard,
			"ClassName",
			string.format("%s (%s)", scriptInfo.className, scriptInfo.scriptKind),
			nil,
			2
		)
		UIComponents.createKeyValueRow(
			metaCard,
			"Parent",
			string.format("%s (%s)", scriptInfo.parentPath, scriptInfo.parentClassName),
			nil,
			3
		)
		UIComponents.createKeyValueRow(metaCard, "Service", scriptInfo.serviceName, nil, 4)
		UIComponents.createKeyValueRow(metaCard, "Execution Context", tostring(execProfile.environment), nil, 5)
		UIComponents.createKeyValueRow(metaCard, "RunContext", scriptInfo.runContextName, nil, 6)
		UIComponents.createKeyValueRow(metaCard, "Enabled State", enabledStr, enabledColor, 7)
		UIComponents.createKeyValueRow(metaCard, "Lifecycle Phase", execProfile.phaseLabel, nil, 8)
		UIComponents.createKeyValueRow(metaCard, "Eligibility", execProfile.eligibilityReason, Theme.Colors.TextSecondary, 9)
		UIComponents.createKeyValueRow(
			metaCard,
			"Source Lines",
			if scriptInfo.sourceAccessible
				then string.format("%d lines", scriptInfo.lineCount)
				else "Inaccessible (" .. (scriptInfo.sourceError or "Restricted") .. ")",
			nil,
			10
		)
		UIComponents.createKeyValueRow(
			metaCard,
			"Dependencies",
			string.format(
				"%d total (%d resolved, %d unresolved)",
				#depSummary.dependencies,
				#depSummary.resolvedModules,
				#depSummary.unresolvedRecords
			),
			nil,
			11
		)
		UIComponents.createKeyValueRow(
			metaCard,
			"Required By",
			string.format("%d script(s)", #depSummary.requiredByPaths),
			nil,
			12
		)

		-- 5. Outgoing Dependencies Section (Modules required by this script)
		UIComponents.createSectionHeader(
			detailScroll,
			"Requires Modules",
			tostring(#depSummary.dependencies),
			5
		)

		if #depSummary.dependencies == 0 then
			local noDepsLbl = Instance.new("TextLabel")
			noDepsLbl.Size = UDim2.new(1, 0, 0, 20)
			noDepsLbl.LayoutOrder = 6
			noDepsLbl.BackgroundTransparency = 1
			noDepsLbl.Font = Theme.Fonts.Regular
			noDepsLbl.TextSize = 12
			noDepsLbl.TextColor3 = Theme.Colors.TextMuted
			noDepsLbl.TextXAlignment = Enum.TextXAlignment.Left
			noDepsLbl.Text = "This script does not contain any static require() calls."
			noDepsLbl.Parent = detailScroll
		else
			local depsContainer = Instance.new("Frame")
			depsContainer.Name = "DepsContainer"
			depsContainer.Size = UDim2.new(1, 0, 0, 0)
			depsContainer.AutomaticSize = Enum.AutomaticSize.Y
			depsContainer.LayoutOrder = 6
			depsContainer.BackgroundTransparency = 1
			depsContainer.Parent = detailScroll
			UIComponents.createListLayout(depsContainer, Enum.FillDirection.Vertical, 4)

			for idx, rec in depSummary.dependencies do
				local depRow = Instance.new("TextButton")
				depRow.Name = "Dep_" .. tostring(idx)
				depRow.LayoutOrder = idx
				depRow.Size = UDim2.new(1, 0, 0, 26)
				depRow.BackgroundColor3 = Theme.Colors.RowBackground
				depRow.BorderSizePixel = 0
				depRow.AutoButtonColor = true
				depRow.Text = ""
				depRow.Parent = depsContainer
				UIComponents.createCorner(depRow, 3)

				local statusBadge = UIComponents.createClassificationBadge(depRow, rec.classification, 1)
				statusBadge.Position = UDim2.fromOffset(6, 4)

				local labelText = if rec.status == "Resolved" and rec.resolvedModuleName ~= nil
					then rec.resolvedModuleName
					else "require(" .. rec.rawExpression .. ")"

				local targetLabel = Instance.new("TextLabel")
				targetLabel.Size = UDim2.new(1, -182, 1, 0)
				targetLabel.Position = UDim2.fromOffset(88, 0)
				targetLabel.BackgroundTransparency = 1
				targetLabel.Font = Theme.Fonts.SemiBold
				targetLabel.TextSize = 12
				targetLabel.TextColor3 = Theme.Colors.TextPrimary
				targetLabel.TextXAlignment = Enum.TextXAlignment.Left
				targetLabel.TextTruncate = Enum.TextTruncate.AtEnd
				targetLabel.Text = labelText
				targetLabel.Parent = depRow

				local lineScopeLabel = Instance.new("TextLabel")
				lineScopeLabel.Size = UDim2.new(0, 90, 1, 0)
				lineScopeLabel.Position = UDim2.new(1, -94, 0, 0)
				lineScopeLabel.BackgroundTransparency = 1
				lineScopeLabel.Font = Theme.Fonts.Mono
				lineScopeLabel.TextSize = 11
				lineScopeLabel.TextColor3 = Theme.Colors.TextMuted
				lineScopeLabel.TextXAlignment = Enum.TextXAlignment.Right
				lineScopeLabel.Text = string.format("L%d:%d · %s", rec.lineNumber, rec.columnNumber, rec.scopeKind)
				lineScopeLabel.Parent = depRow

				if rec.status == "Resolved" and rec.resolvedModulePath ~= nil then
					local targetModPath = rec.resolvedModulePath
					table.insert(
						detailConnections,
						depRow.Activated:Connect(function()
							selectScript(targetModPath)
						end)
					)
				else
					local lineNum = rec.lineNumber
					table.insert(
						detailConnections,
						depRow.Activated:Connect(function()
							UIComponents.openScriptInStudio(scriptInfo.instance, lineNum)
						end)
					)
				end
			end
		end

		-- 6. Incoming Requirers Section (Scripts/Modules that require this ModuleScript)
		UIComponents.createSectionHeader(
			detailScroll,
			"Required By",
			tostring(#depSummary.requiredByPaths),
			7
		)

		if #depSummary.requiredByPaths == 0 then
			local noReqByLbl = Instance.new("TextLabel")
			noReqByLbl.Size = UDim2.new(1, 0, 0, 20)
			noReqByLbl.LayoutOrder = 8
			noReqByLbl.BackgroundTransparency = 1
			noReqByLbl.Font = Theme.Fonts.Regular
			noReqByLbl.TextSize = 12
			noReqByLbl.TextColor3 = Theme.Colors.TextMuted
			noReqByLbl.TextXAlignment = Enum.TextXAlignment.Left
			noReqByLbl.Text = if scriptInfo.isModule
				then "No static require() callers detected for this ModuleScript."
				else "Executable scripts are not required by other scripts."
			noReqByLbl.Parent = detailScroll
		else
			local reqByContainer = Instance.new("Frame")
			reqByContainer.Name = "ReqByContainer"
			reqByContainer.Size = UDim2.new(1, 0, 0, 0)
			reqByContainer.AutomaticSize = Enum.AutomaticSize.Y
			reqByContainer.LayoutOrder = 8
			reqByContainer.BackgroundTransparency = 1
			reqByContainer.Parent = detailScroll
			UIComponents.createListLayout(reqByContainer, Enum.FillDirection.Vertical, 4)

			for idx, callerPath in depSummary.requiredByPaths do
				local callerSum = report.dependencyAnalysis.byScriptPath[callerPath]
				local callerClass: Types.ScriptClassName = if callerSum ~= nil
					then callerSum.script.className
					else "Script"
				local callerName = if callerSum ~= nil then callerSum.script.name else callerPath

				local callerRow = Instance.new("TextButton")
				callerRow.Name = "Caller_" .. tostring(idx)
				callerRow.LayoutOrder = idx
				callerRow.Size = UDim2.new(1, 0, 0, 26)
				callerRow.BackgroundColor3 = Theme.Colors.RowBackground
				callerRow.BorderSizePixel = 0
				callerRow.AutoButtonColor = true
				callerRow.Text = ""
				callerRow.Parent = reqByContainer
				UIComponents.createCorner(callerRow, 3)

				local cBadge = UIComponents.createClassBadge(callerRow, callerClass, true, 1)
				cBadge.Position = UDim2.fromOffset(6, 4)

				local callerNameLbl = Instance.new("TextLabel")
				callerNameLbl.Size = UDim2.new(1, -44, 1, 0)
				callerNameLbl.Position = UDim2.fromOffset(38, 0)
				callerNameLbl.BackgroundTransparency = 1
				callerNameLbl.Font = Theme.Fonts.SemiBold
				callerNameLbl.TextSize = 12
				callerNameLbl.TextColor3 = Theme.Colors.TextPrimary
				callerNameLbl.TextXAlignment = Enum.TextXAlignment.Left
				callerNameLbl.TextTruncate = Enum.TextTruncate.AtEnd
				callerNameLbl.Text = string.format("%s  (%s)", callerName, callerPath)
				callerNameLbl.Parent = callerRow

				local jumpPath = callerPath
				table.insert(
					detailConnections,
					callerRow.Activated:Connect(function()
						selectScript(jumpPath)
					end)
				)
			end
		end
	end

	local function matchesFilters(scriptInfo: DiscoveredScript, report: ScanReport): boolean
		-- 1. Search filter (name or fullPath)
		if searchQuery ~= "" then
			local lowerName = string.lower(scriptInfo.name)
			local lowerPath = string.lower(scriptInfo.fullPath)
			if string.find(lowerName, searchQuery, 1, true) == nil and string.find(lowerPath, searchQuery, 1, true) == nil then
				return false
			end
		end

		-- 2. ClassName filter
		if filterType ~= "All" and scriptInfo.className ~= filterType then
			return false
		end

		-- 3. Execution Context filter
		local profile = report.executionAnalysis.profilesByPath[scriptInfo.fullPath]
		local env = if profile ~= nil then profile.environment else "Inactive"

		if filterContext ~= "All" then
			if filterContext == "Server" then
				if env ~= "Server" and env ~= "ServerModule" then
					return false
				end
			elseif filterContext == "Client" then
				if env ~= "Client" and env ~= "ClientModule" then
					return false
				end
			elseif filterContext == "Shared" then
				if env ~= "SharedModule" then
					return false
				end
			elseif filterContext == "Plugin" then
				if env ~= "Plugin" then
					return false
				end
			elseif filterContext == "Dormant" then
				if env ~= "Inactive" and env ~= "UnreferencedModule" then
					return false
				end
			end
		end

		-- 4. Enabled / Active State filter
		if filterState ~= "All" then
			local isActive = if scriptInfo.isModule
				then (env ~= "UnreferencedModule" and env ~= "Inactive")
				else (profile ~= nil and profile.willAutoExecute)
			if filterState == "Active" and not isActive then
				return false
			elseif filterState == "Inactive" and isActive then
				return false
			end
		end

		return true
	end

	applyFiltersAndRenderList = function()
		for _, conn in listConnections do
			conn:Disconnect()
		end
		table.clear(listConnections)
		table.clear(rowFramesByPath)

		for _, child in listScroll:GetChildren() do
			if not child:IsA("UILayout") and not child:IsA("UIPadding") then
				child:Destroy()
			end
		end

		if currentReport == nil then
			countStatusLabel.Text = "0 scripts"
			return
		end

		local report = currentReport
		local filtered: { DiscoveredScript } = {}
		for _, scriptInfo in report.scripts do
			if matchesFilters(scriptInfo, report) then
				table.insert(filtered, scriptInfo)
			end
		end

		countStatusLabel.Text = string.format("Showing %d of %d", #filtered, #report.scripts)

		if #filtered == 0 then
			local emptyFrame = UIComponents.createEmptyState(
				listScroll,
				"No Matching Scripts",
				"No scripts matched the active search query and filters.",
				1
			)
			UIComponents.createButton(
				emptyFrame,
				"Reset All Filters",
				UDim2.fromOffset(120, 22),
				false,
				2,
				function()
					filterType = "All"
					filterContext = "All"
					filterState = "All"
					setTypeChip("All")
					setContextChip("All")
					setStateChip("All")
					resetSearchInput()
					applyFiltersAndRenderList()
				end,
				listConnections
			).Position = UDim2.fromOffset(12, 56)
			return
		end

		local totalPages = math.max(1, math.ceil(#filtered / PAGE_SIZE))
		if currentPage > totalPages then
			currentPage = totalPages
		end
		local startIdx = (currentPage - 1) * PAGE_SIZE + 1
		local endIdx = math.min(#filtered, currentPage * PAGE_SIZE)

		for i = startIdx, endIdx do
			local scriptInfo = filtered[i]
			local depSummary = report.dependencyAnalysis.byScriptPath[scriptInfo.fullPath]
			local execProfile = report.executionAnalysis.profilesByPath[scriptInfo.fullPath]
			local envStr = if execProfile ~= nil then tostring(execProfile.environment) else "Inactive"
			local depCount = if depSummary ~= nil then #depSummary.dependencies else 0
			local reqByCount = if depSummary ~= nil then #depSummary.requiredByPaths else 0

			local isSelected = (scriptInfo.fullPath == selectedScriptPath)
			local rowBtn = Instance.new("TextButton")
			rowBtn.Name = "ScriptRow_" .. tostring(i)
			rowBtn.LayoutOrder = i
			rowBtn.Size = UDim2.new(1, 0, 0, 32)
			rowBtn.BackgroundColor3 = if isSelected
				then Theme.Colors.RowSelected
				elseif i % 2 == 0 then Theme.Colors.RowAlternate
				else Theme.Colors.RowBackground
			rowBtn.BorderSizePixel = 0
			rowBtn.AutoButtonColor = true
			rowBtn.Text = ""
			rowBtn.Parent = listScroll
			UIComponents.createCorner(rowBtn, 3)

			-- Col 1: Badge + Name + Parent Path
			local cBadge = UIComponents.createClassBadge(rowBtn, scriptInfo.className, true, 1)
			cBadge.Position = UDim2.fromOffset(6, 7)

			local nameLbl = Instance.new("TextLabel")
			nameLbl.Name = "Name"
			nameLbl.Size = UDim2.new(0.48, -42, 0, 15)
			nameLbl.Position = UDim2.fromOffset(36, 2)
			nameLbl.BackgroundTransparency = 1
			nameLbl.Font = Theme.Fonts.Bold
			nameLbl.TextSize = 13
			nameLbl.TextColor3 = Theme.Colors.TextPrimary
			nameLbl.TextXAlignment = Enum.TextXAlignment.Left
			nameLbl.TextTruncate = Enum.TextTruncate.AtEnd
			nameLbl.Text = scriptInfo.name
			nameLbl.Parent = rowBtn

			local subPathLbl = Instance.new("TextLabel")
			subPathLbl.Name = "SubPath"
			subPathLbl.Size = UDim2.new(0.48, -42, 0, 12)
			subPathLbl.Position = UDim2.fromOffset(36, 17)
			subPathLbl.BackgroundTransparency = 1
			subPathLbl.Font = Theme.Fonts.Mono
			subPathLbl.TextSize = 10
			subPathLbl.TextColor3 = Theme.Colors.TextMuted
			subPathLbl.TextXAlignment = Enum.TextXAlignment.Left
			subPathLbl.TextTruncate = Enum.TextTruncate.AtEnd
			subPathLbl.Text = scriptInfo.parentPath
			subPathLbl.Parent = rowBtn

			-- Col 2: Context Badge
			local ctxHolder = Instance.new("Frame")
			ctxHolder.Size = UDim2.new(0.24, -4, 1, 0)
			ctxHolder.Position = UDim2.fromScale(0.48, 0)
			ctxHolder.BackgroundTransparency = 1
			ctxHolder.Parent = rowBtn
			UIComponents.createListLayout(
				ctxHolder,
				Enum.FillDirection.Horizontal,
				0,
				Enum.HorizontalAlignment.Left,
				Enum.VerticalAlignment.Center
			)
			UIComponents.createEnvironmentBadge(ctxHolder, envStr, 1)

			-- Col 3: Enabled / State
			local stateLbl = Instance.new("TextLabel")
			stateLbl.Size = UDim2.new(0.14, -4, 1, 0)
			stateLbl.Position = UDim2.fromScale(0.72, 0)
			stateLbl.BackgroundTransparency = 1
			stateLbl.Font = Theme.Fonts.SemiBold
			stateLbl.TextSize = 11
			stateLbl.TextXAlignment = Enum.TextXAlignment.Left
			if scriptInfo.isModule then
				stateLbl.Text = "Module"
				stateLbl.TextColor3 = Theme.Colors.TextMuted
			elseif scriptInfo.isEnabled == false then
				stateLbl.Text = "Disabled"
				stateLbl.TextColor3 = Theme.Colors.WarningText
			elseif execProfile ~= nil and execProfile.willAutoExecute then
				stateLbl.Text = "Active"
				stateLbl.TextColor3 = Theme.Colors.SuccessText
			else
				stateLbl.Text = "Dormant"
				stateLbl.TextColor3 = Theme.Colors.WarningText
			end
			stateLbl.Parent = rowBtn

			-- Col 4: Deps / Requirers count
			local depCountLbl = Instance.new("TextLabel")
			depCountLbl.Size = UDim2.new(0.14, -8, 1, 0)
			depCountLbl.Position = UDim2.fromScale(0.86, 0)
			depCountLbl.BackgroundTransparency = 1
			depCountLbl.Font = Theme.Fonts.Mono
			depCountLbl.TextSize = 11
			depCountLbl.TextColor3 = Theme.Colors.TextSecondary
			depCountLbl.TextXAlignment = Enum.TextXAlignment.Right
			depCountLbl.Text = if scriptInfo.isModule
				then string.format("%d→ / ←%d", depCount, reqByCount)
				else string.format("%d req", depCount)
			depCountLbl.Parent = rowBtn

			rowFramesByPath[scriptInfo.fullPath] = rowBtn
			local targetPath = scriptInfo.fullPath
			table.insert(
				listConnections,
				rowBtn.Activated:Connect(function()
					selectScript(targetPath)
				end)
			)
		end

		-- Pagination bar if needed
		if totalPages > 1 then
			local pageBar = Instance.new("Frame")
			pageBar.Name = "PaginationBar"
			pageBar.LayoutOrder = endIdx + 1
			pageBar.Size = UDim2.new(1, 0, 0, 28)
			pageBar.BackgroundTransparency = 1
			pageBar.Parent = listScroll
			UIComponents.createListLayout(
				pageBar,
				Enum.FillDirection.Horizontal,
				8,
				Enum.HorizontalAlignment.Center,
				Enum.VerticalAlignment.Center
			)

			if currentPage > 1 then
				UIComponents.createButton(
					pageBar,
					"← Prev",
					UDim2.fromOffset(64, 22),
					false,
					1,
					function()
						currentPage -= 1
						applyFiltersAndRenderList()
					end,
					listConnections
				)
			end

			local pageInfo = Instance.new("TextLabel")
			pageInfo.LayoutOrder = 2
			pageInfo.Size = UDim2.fromOffset(96, 22)
			pageInfo.BackgroundTransparency = 1
			pageInfo.Font = Theme.Fonts.SemiBold
			pageInfo.TextSize = 12
			pageInfo.TextColor3 = Theme.Colors.TextSecondary
			pageInfo.Text = string.format("Page %d / %d", currentPage, totalPages)
			pageInfo.Parent = pageBar

			if currentPage < totalPages then
				UIComponents.createButton(
					pageBar,
					"Next →",
					UDim2.fromOffset(64, 22),
					false,
					3,
					function()
						currentPage += 1
						applyFiltersAndRenderList()
					end,
					listConnections
				)
			end
		end
	end

	local function render(report: ScanReport)
		currentReport = report
		-- Preserve selection if still valid, otherwise select the first script
		if selectedScriptPath == nil or report.dependencyAnalysis.byScriptPath[selectedScriptPath] == nil then
			selectedScriptPath = if #report.scripts > 0 then report.scripts[1].fullPath else nil
		end
		applyFiltersAndRenderList()
		renderDetailsForSelected()
	end

	local function selectScriptByPath(scriptPath: string)
		if currentReport ~= nil and currentReport.dependencyAnalysis.byScriptPath[scriptPath] ~= nil then
			-- Reset filters if the target script is currently hidden by filters
			local targetScript = currentReport.dependencyAnalysis.byScriptPath[scriptPath].script
			if not matchesFilters(targetScript, currentReport) then
				filterType = "All"
				filterContext = "All"
				filterState = "All"
				setTypeChip("All")
				setContextChip("All")
				setStateChip("All")
				resetSearchInput()
			end
			selectScript(scriptPath)
			applyFiltersAndRenderList()
		end
	end

	local function destroy()
		clearDetailPanel()
		for _, conn in listConnections do
			conn:Disconnect()
		end
		for _, conn in viewConnections do
			conn:Disconnect()
		end
		table.clear(listConnections)
		table.clear(viewConnections)
		rootFrame:Destroy()
	end

	return {
		frame = rootFrame,
		render = render,
		selectScriptByPath = selectScriptByPath,
		destroy = destroy,
	}
end

return ScriptsView
