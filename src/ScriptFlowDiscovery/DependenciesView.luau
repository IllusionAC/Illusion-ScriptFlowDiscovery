--!strict
--[[
	DependenciesView.luau
	Renders the Dependencies Explorer (Section 6):
	- 6.1 Expandable Hierarchical Dependency Tree using readable script names
	- 6.2 Interactive Dependency Details Inspector (Requiring script, Target ModuleScript,
	      Full paths, Source line, Scope, Resolution status, Studio actions)
	- 6.3 Combined Filtering (Resolved / Unresolved, Origin class: Script / LocalScript / ModuleScript, Search)
	- 6.4 Circular Dependency Identification
]]

local Types = require("./Types")
local Theme = require("./Theme")
local UIComponents = require("./UIComponents")

type ScanReport = Types.ScanReport
type DependencyRecord = Types.DependencyRecord
type ScriptDependencySummary = Types.ScriptDependencySummary

export type DependenciesCallbacks = {
	onNavigateToScript: (scriptPath: string) -> (),
}

export type DependenciesViewInstance = {
	frame: Frame,
	render: (report: ScanReport) -> (),
	setStatusFilter: (statusFilter: string) -> (),
	destroy: () -> (),
}

local DependenciesView = {}

function DependenciesView.create(
	parent: Instance,
	callbacks: DependenciesCallbacks
): DependenciesViewInstance
	local viewConnections: { RBXScriptConnection } = {}
	local treeConnections: { RBXScriptConnection } = {}
	local detailConnections: { RBXScriptConnection } = {}

	local currentReport: ScanReport? = nil
	local searchQuery = ""
	local filterStatus = "All" -- "All" | "Resolved" | "Unresolved"
	local filterOrigin = "All" -- "All" | "Script" | "LocalScript" | "ModuleScript"

	-- Expanded state keyed by tree node key (e.g., "root:ServerStorage.IllusionSFD" or edge path)
	local expandedNodes: { [string]: boolean } = {}
	local defaultExpandedAll = true

	-- Currently selected dependency record or root script
	local selectedRecord: DependencyRecord? = nil
	local selectedRootPath: string? = nil
	local selectedNodeKey: string? = nil

	local rootFrame = Instance.new("Frame")
	rootFrame.Name = "DependenciesView"
	rootFrame.Size = UDim2.fromScale(1, 1)
	rootFrame.BackgroundTransparency = 1
	rootFrame.Visible = false
	rootFrame.Parent = parent

	UIComponents.createPadding(rootFrame, 8, 8, 10, 10)

	-- =========================================================================
	-- Top Filter & Controls Bar
	-- =========================================================================
	local filterOuter = UIComponents.createPanel(rootFrame, "DepFilterToolbar", UDim2.new(1, 0, 0, 114), 1)
	filterOuter.AutomaticSize = Enum.AutomaticSize.Y

	local filterPanel = Instance.new("Frame")
	filterPanel.Name = "DepFilterToolbarContent"
	filterPanel.Size = UDim2.fromScale(1, 1)
	filterPanel.AutomaticSize = Enum.AutomaticSize.Y
	filterPanel.BackgroundTransparency = 1
	filterPanel.Parent = filterOuter
	UIComponents.createPadding(filterPanel, 10, 12, 12, 14)
	UIComponents.createListLayout(filterPanel, Enum.FillDirection.Vertical, 7)

	UIComponents.attachPanelEdgeResizers(filterOuter, {
		minHeight = 76,
		maxHeight = 300,
		minWidth = 360,
		enableBottom = true,
		enableRight = true,
		enableCorner = true,
	}, viewConnections)

	local topRow = Instance.new("Frame")
	topRow.Name = "TopSearchAndTreeControls"
	topRow.Size = UDim2.new(1, 0, 0, 28)
	topRow.LayoutOrder = 1
	topRow.BackgroundTransparency = 1
	topRow.Parent = filterPanel

	local rebuildTree: () -> ()
	local renderDetailPanel: () -> ()

	local searchBoxFrame, _, _ = UIComponents.createSearchInput(
		topRow,
		"Filter dependencies by script name, module name, or expression...",
		UDim2.new(1, -182, 1, 0),
		1,
		function(newText: string)
			searchQuery = string.lower(newText)
			rebuildTree()
		end,
		viewConnections
	)
	searchBoxFrame.Position = UDim2.fromOffset(0, 0)

	local treeButtonsHolder = Instance.new("Frame")
	treeButtonsHolder.Name = "TreeButtons"
	treeButtonsHolder.Size = UDim2.new(0, 174, 1, 0)
	treeButtonsHolder.Position = UDim2.new(1, -174, 0, 0)
	treeButtonsHolder.BackgroundTransparency = 1
	treeButtonsHolder.Parent = topRow
	UIComponents.createListLayout(
		treeButtonsHolder,
		Enum.FillDirection.Horizontal,
		6,
		Enum.HorizontalAlignment.Right,
		Enum.VerticalAlignment.Center
	)

	UIComponents.createButton(
		treeButtonsHolder,
		"Expand All",
		UDim2.fromOffset(82, 26),
		false,
		1,
		function()
			defaultExpandedAll = true
			table.clear(expandedNodes)
			rebuildTree()
		end,
		viewConnections
	)

	UIComponents.createButton(
		treeButtonsHolder,
		"Collapse All",
		UDim2.fromOffset(86, 26),
		false,
		2,
		function()
			defaultExpandedAll = false
			table.clear(expandedNodes)
			rebuildTree()
		end,
		viewConnections
	)

	local _, setStatusChip = UIComponents.createFilterBar(
		filterPanel,
		"Resolution",
		{
			{ id = "All", label = "All" },
			{ id = "Resolved", label = "Resolved" },
			{ id = "Static", label = "Static" },
			{ id = "Dynamic", label = "Dynamic / Loop" },
			{ id = "Conditional", label = "Conditional" },
			{ id = "Unresolved", label = "Unresolved / Partial" },
		},
		"All",
		2,
		function(id: string)
			filterStatus = id
			rebuildTree()
		end,
		viewConnections
	)

	local _, _ = UIComponents.createFilterBar(
		filterPanel,
		"Origin",
		{
			{ id = "All", label = "All Origins" },
			{ id = "Script", label = "[S] From Script" },
			{ id = "LocalScript", label = "[L] From LocalScript" },
			{ id = "ModuleScript", label = "[M] From ModuleScript" },
		},
		"All",
		3,
		function(id: string)
			filterOrigin = id
			rebuildTree()
		end,
		viewConnections
	)

	-- =========================================================================
	-- Split Area: Left (Hierarchical Dependency Tree) | Right (Dependency Details)
	-- =========================================================================
	local splitArea = Instance.new("Frame")
	splitArea.Name = "SplitArea"
	splitArea.Size = UDim2.new(1, 0, 1, -122)
	splitArea.Position = UDim2.fromOffset(0, 122)
	splitArea.BackgroundTransparency = 1
	splitArea.Parent = rootFrame

	local function syncSplitLayout()
		local panelHeight = math.max(76, filterOuter.AbsoluteSize.Y)
		local topOffset = panelHeight + 8
		splitArea.Position = UDim2.fromOffset(0, topOffset)
		splitArea.Size = UDim2.new(1, 0, 1, -topOffset)
	end
	table.insert(viewConnections, filterOuter:GetPropertyChangedSignal("AbsoluteSize"):Connect(syncSplitLayout))
	syncSplitLayout()

	local treePanel = UIComponents.createPanel(splitArea, "TreePanel", UDim2.new(0.56, -5, 1, 0), 1)
	local treeScroll = UIComponents.createScrollFrame(treePanel, "TreeScroll", UDim2.fromScale(1, 1), 1)
	UIComponents.createPadding(treeScroll, 8, 10, 8, 8)
	UIComponents.createListLayout(treeScroll, Enum.FillDirection.Vertical, 2)

	local detailPanel = UIComponents.createPanel(splitArea, "DepDetailsPanel", UDim2.new(0.44, -5, 1, 0), 2)
	detailPanel.Position = UDim2.new(0.56, 5, 0, 0)
	local detailScroll = UIComponents.createScrollFrame(detailPanel, "DepDetailScroll", UDim2.fromScale(1, 1), 1)
	UIComponents.createPadding(detailScroll, 10, 12, 10, 10)
	UIComponents.createListLayout(detailScroll, Enum.FillDirection.Vertical, 8)

	-- Interactive split resizer between Dependency Tree (left) and Dependency Details (right)
	UIComponents.attachHorizontalSplitResizer(
		splitArea,
		treePanel,
		detailPanel,
		0.56,
		0.25,
		0.78,
		viewConnections
	)

	-- Edge resizers on both panels
	UIComponents.attachPanelEdgeResizers(treePanel, {
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

	local nodeRowButtons: { [string]: TextButton } = {}

	local function updateSelectedRowHighlight()
		for key, btn in nodeRowButtons do
			btn.BackgroundColor3 = if key == selectedNodeKey
				then Theme.Colors.RowSelected
				else Theme.Colors.RowBackground
		end
	end

	local function isNodeExpanded(nodeKey: string): boolean
		local explicit = expandedNodes[nodeKey]
		if explicit ~= nil then
			return explicit
		end
		return defaultExpandedAll
	end

	local function recordMatchesFilters(rec: DependencyRecord): boolean
		if filterStatus == "Resolved" and rec.status ~= "Resolved" then
			return false
		elseif filterStatus == "Static" and rec.classification ~= "Static" then
			return false
		elseif filterStatus == "Dynamic" and not rec.isDynamic then
			return false
		elseif filterStatus == "Conditional" and not rec.isConditional then
			return false
		elseif filterStatus == "Unresolved" and rec.status == "Resolved" then
			return false
		end

		if filterOrigin ~= "All" and rec.requiringScriptClass ~= filterOrigin then
			return false
		end

		if searchQuery ~= "" then
			local reqName = string.lower(rec.requiringScriptName)
			local reqPath = string.lower(rec.requiringScriptPath)
			local rawExpr = string.lower(rec.rawExpression)
			local targetName = if rec.resolvedModuleName ~= nil then string.lower(rec.resolvedModuleName) else ""
			local targetPath = if rec.resolvedModulePath ~= nil then string.lower(rec.resolvedModulePath) else ""

			if
				string.find(reqName, searchQuery, 1, true) == nil
				and string.find(reqPath, searchQuery, 1, true) == nil
				and string.find(rawExpr, searchQuery, 1, true) == nil
				and string.find(targetName, searchQuery, 1, true) == nil
				and string.find(targetPath, searchQuery, 1, true) == nil
			then
				return false
			end
		end

		return true
	end

	renderDetailPanel = function()
		for _, conn in detailConnections do
			conn:Disconnect()
		end
		table.clear(detailConnections)

		for _, child in detailScroll:GetChildren() do
			if not child:IsA("UILayout") and not child:IsA("UIPadding") then
				child:Destroy()
			end
		end

		if currentReport == nil then
			UIComponents.createEmptyState(
				detailScroll,
				"No Scan Data",
				"Run a scan to inspect ModuleScript dependency relationships.",
				1
			)
			return
		end

		local report = currentReport

		-- Case A: A specific dependency edge (`DependencyRecord`) is selected
		if selectedRecord ~= nil then
			local rec = selectedRecord
			local reqSummary = report.dependencyAnalysis.byScriptPath[rec.requiringScriptPath]
			local targetSummary = if rec.resolvedModulePath ~= nil
				then report.dependencyAnalysis.byScriptPath[rec.resolvedModulePath]
				else nil

			local headerRow = Instance.new("Frame")
			headerRow.Size = UDim2.new(1, 0, 0, 22)
			headerRow.LayoutOrder = 1
			headerRow.BackgroundTransparency = 1
			headerRow.Parent = detailScroll

			UIComponents.createResolutionBadge(headerRow, rec.status, 1)

			local titleLbl = Instance.new("TextLabel")
			titleLbl.Size = UDim2.new(1, -90, 1, 0)
			titleLbl.Position = UDim2.fromOffset(86, 0)
			titleLbl.BackgroundTransparency = 1
			titleLbl.Font = Theme.Fonts.Bold
			titleLbl.TextSize = 14
			titleLbl.TextColor3 = Theme.Colors.TextPrimary
			titleLbl.TextXAlignment = Enum.TextXAlignment.Left
			titleLbl.TextTruncate = Enum.TextTruncate.AtEnd
			titleLbl.Text = string.format(
				"%s → %s",
				rec.requiringScriptName,
				rec.resolvedModuleName or ("require(" .. rec.rawExpression .. ")")
			)
			titleLbl.Parent = headerRow

			-- 1. Requiring Script Card
			UIComponents.createSectionHeader(detailScroll, "Requiring Script (Caller)", "", 2)

			local reqCard = UIComponents.createPanel(detailScroll, "RequiringCard", UDim2.new(1, 0, 0, 0), 3, Theme.Colors.RowAlternate)
			reqCard.AutomaticSize = Enum.AutomaticSize.Y
			UIComponents.createPadding(reqCard, 8, 8, 8, 8)
			UIComponents.createListLayout(reqCard, Enum.FillDirection.Vertical, 5)

			local reqTop = Instance.new("Frame")
			reqTop.Size = UDim2.new(1, 0, 0, 20)
			reqTop.LayoutOrder = 1
			reqTop.BackgroundTransparency = 1
			reqTop.Parent = reqCard
			UIComponents.createClassBadge(reqTop, rec.requiringScriptClass, false, 1)

			local reqNameLbl = Instance.new("TextLabel")
			reqNameLbl.Size = UDim2.new(1, -115, 1, 0)
			reqNameLbl.Position = UDim2.fromOffset(112, 0)
			reqNameLbl.BackgroundTransparency = 1
			reqNameLbl.Font = Theme.Fonts.Bold
			reqNameLbl.TextSize = 13
			reqNameLbl.TextColor3 = Theme.Colors.TextPrimary
			reqNameLbl.TextXAlignment = Enum.TextXAlignment.Left
			reqNameLbl.TextTruncate = Enum.TextTruncate.AtEnd
			reqNameLbl.Text = rec.requiringScriptName
			reqNameLbl.Parent = reqTop

			UIComponents.createCopyPathBox(reqCard, rec.requiringScriptPath, 2, detailConnections)

			local reqActions = Instance.new("Frame")
			reqActions.Size = UDim2.new(1, 0, 0, 24)
			reqActions.LayoutOrder = 3
			reqActions.BackgroundTransparency = 1
			reqActions.Parent = reqCard
			UIComponents.createListLayout(
				reqActions,
				Enum.FillDirection.Horizontal,
				6,
				Enum.HorizontalAlignment.Left,
				Enum.VerticalAlignment.Center
			)

			UIComponents.createButton(
				reqActions,
				"Inspect in Scripts →",
				UDim2.fromOffset(124, 22),
				false,
				1,
				function()
					callbacks.onNavigateToScript(rec.requiringScriptPath)
				end,
				detailConnections
			)

			if reqSummary ~= nil then
				UIComponents.createButton(
					reqActions,
					string.format("Open Line %d", rec.lineNumber),
					UDim2.fromOffset(96, 22),
					true,
					2,
					function()
						UIComponents.openScriptInStudio(reqSummary.script.instance, rec.lineNumber)
					end,
					detailConnections
				)
			end

			-- 2. Required ModuleScript Card
			UIComponents.createSectionHeader(detailScroll, "Required Target ModuleScript", "", 4)

			local targetCard = UIComponents.createPanel(detailScroll, "TargetCard", UDim2.new(1, 0, 0, 0), 5, Theme.Colors.RowAlternate)
			targetCard.AutomaticSize = Enum.AutomaticSize.Y
			UIComponents.createPadding(targetCard, 8, 8, 8, 8)
			UIComponents.createListLayout(targetCard, Enum.FillDirection.Vertical, 5)

			if rec.status == "Resolved" and rec.resolvedModulePath ~= nil then
				local targetTop = Instance.new("Frame")
				targetTop.Size = UDim2.new(1, 0, 0, 20)
				targetTop.LayoutOrder = 1
				targetTop.BackgroundTransparency = 1
				targetTop.Parent = targetCard
				UIComponents.createClassBadge(targetTop, "ModuleScript", false, 1)

				local targetNameLbl = Instance.new("TextLabel")
				targetNameLbl.Size = UDim2.new(1, -115, 1, 0)
				targetNameLbl.Position = UDim2.fromOffset(112, 0)
				targetNameLbl.BackgroundTransparency = 1
				targetNameLbl.Font = Theme.Fonts.Bold
				targetNameLbl.TextSize = 13
				targetNameLbl.TextColor3 = Theme.Colors.TextPrimary
				targetNameLbl.TextXAlignment = Enum.TextXAlignment.Left
				targetNameLbl.TextTruncate = Enum.TextTruncate.AtEnd
				targetNameLbl.Text = rec.resolvedModuleName or rec.resolvedModulePath
				targetNameLbl.Parent = targetTop

				UIComponents.createCopyPathBox(targetCard, rec.resolvedModulePath, 2, detailConnections)

				local targetActions = Instance.new("Frame")
				targetActions.Size = UDim2.new(1, 0, 0, 24)
				targetActions.LayoutOrder = 3
				targetActions.BackgroundTransparency = 1
				targetActions.Parent = targetCard
				UIComponents.createListLayout(
					targetActions,
					Enum.FillDirection.Horizontal,
					6,
					Enum.HorizontalAlignment.Left,
					Enum.VerticalAlignment.Center
				)

				local resolvedPath = rec.resolvedModulePath
				UIComponents.createButton(
					targetActions,
					"Inspect Target Module →",
					UDim2.fromOffset(146, 22),
					false,
					1,
					function()
						callbacks.onNavigateToScript(resolvedPath)
					end,
					detailConnections
				)

				if targetSummary ~= nil then
					UIComponents.createButton(
						targetActions,
						"Select in Explorer",
						UDim2.fromOffset(116, 22),
						false,
						2,
						function()
							UIComponents.selectInstanceInStudio(targetSummary.script.instance)
						end,
						detailConnections
					)
				end
			else
				UIComponents.createKeyValueRow(
					targetCard,
					"Raw Expression",
					"require(" .. rec.rawExpression .. ")",
					Theme.Colors.OrangeText,
					1
				)
				if rec.partialBasePath ~= nil then
					UIComponents.createKeyValueRow(
						targetCard,
						"Resolved Base",
						rec.partialBasePath,
						Theme.Colors.TextSecondary,
						2
					)
				end
				UIComponents.createKeyValueRow(
					targetCard,
					"Diagnostic Reason",
					rec.failureReason or "Dynamic expression cannot be resolved statically.",
					Theme.Colors.DangerText,
					3
				)
			end

			-- 3. Call Site & Resolution Metadata
			UIComponents.createSectionHeader(detailScroll, "Call Site Metadata", "", 6)

			local callCard = UIComponents.createPanel(detailScroll, "CallSiteCard", UDim2.new(1, 0, 0, 0), 7, Theme.Colors.RowAlternate)
			callCard.AutomaticSize = Enum.AutomaticSize.Y
			UIComponents.createPadding(callCard, 8, 8, 8, 8)
			UIComponents.createListLayout(callCard, Enum.FillDirection.Vertical, 4)

			UIComponents.createKeyValueRow(
				callCard,
				"Source Location",
				string.format("Line %d, Column %d", rec.lineNumber, rec.columnNumber),
				nil,
				1
			)
			UIComponents.createKeyValueRow(
				callCard,
				"Require Scope",
				string.format(
					"%s (%s)",
					rec.scopeKind,
					if rec.isTopLevel
						then "Executes synchronously when caller initializes"
						else "Deferred until enclosing block/loop/function executes"
				),
				if rec.isTopLevel then Theme.Colors.InfoText else Theme.Colors.WarningText,
				2
			)
			UIComponents.createKeyValueRow(
				callCard,
				"Classification",
				rec.classification,
				if rec.classification == "Static"
					then Theme.Colors.SuccessText
					elseif rec.classification == "DynamicResolved" then Theme.Colors.DynamicCyanText
					elseif rec.classification == "Conditional" then Theme.Colors.WarningText
					else Theme.Colors.OrangeText,
				3
			)
			UIComponents.createKeyValueRow(callCard, "Resolution Status", rec.status, nil, 4)
			UIComponents.createKeyValueRow(
				callCard,
				"Raw Expression",
				string.format("require(%s)", rec.rawExpression),
				Theme.Colors.TextSecondary,
				5
			)
			if rec.conditionExpression ~= nil then
				UIComponents.createKeyValueRow(
					callCard,
					"Guard Condition",
					rec.conditionExpression,
					Theme.Colors.WarningText,
					6
				)
			end
			if rec.candidateModulePaths ~= nil and #rec.candidateModulePaths > 0 then
				UIComponents.createKeyValueRow(
					callCard,
					"Candidate Set",
					string.format("%d candidate ModuleScript(s) in loop/collection", #rec.candidateModulePaths),
					Theme.Colors.DynamicCyanText,
					7
				)
			end
			if rec.usedAlias ~= nil then
				UIComponents.createKeyValueRow(
					callCard,
					"Resolved Via Alias",
					string.format("Variable / Iterator '%s'", rec.usedAlias),
					Theme.Colors.InfoText,
					8
				)
			end
			return
		end

		-- Case B: A root script node is selected
		if selectedRootPath ~= nil then
			local sum = report.dependencyAnalysis.byScriptPath[selectedRootPath]
			if sum ~= nil then
				local sInfo = sum.script
				UIComponents.createSectionHeader(detailScroll, "Root Script Summary", "", 1)

				local rootCard = UIComponents.createPanel(detailScroll, "RootCard", UDim2.new(1, 0, 0, 0), 2, Theme.Colors.RowAlternate)
				rootCard.AutomaticSize = Enum.AutomaticSize.Y
				UIComponents.createPadding(rootCard, 8, 8, 8, 8)
				UIComponents.createListLayout(rootCard, Enum.FillDirection.Vertical, 5)

				UIComponents.createKeyValueRow(rootCard, "Name", sInfo.name, nil, 1)
				UIComponents.createKeyValueRow(rootCard, "ClassName", sInfo.className, nil, 2)
				UIComponents.createCopyPathBox(rootCard, sInfo.fullPath, 3, detailConnections)
				UIComponents.createKeyValueRow(
					rootCard,
					"Direct Requires",
					string.format(
						"%d (%d resolved, %d unresolved)",
						#sum.dependencies,
						#sum.resolvedModules,
						#sum.unresolvedRecords
					),
					nil,
					4
				)
				UIComponents.createKeyValueRow(
					rootCard,
					"Required By",
					string.format("%d script(s)", #sum.requiredByPaths),
					nil,
					5
				)

				local targetPath = sInfo.fullPath
				UIComponents.createButton(
					rootCard,
					"Inspect Full Details in Scripts Explorer →",
					UDim2.new(1, 0, 0, 24),
					true,
					6,
					function()
						callbacks.onNavigateToScript(targetPath)
					end,
					detailConnections
				)
				return
			end
		end

		UIComponents.createEmptyState(
			detailScroll,
			"Select a Dependency Relationship",
			"Click any branch or script in the dependency tree on the left to inspect its caller, target ModuleScript, line number, scope, and resolution status.",
			1
		)
	end

	rebuildTree = function()
		for _, conn in treeConnections do
			conn:Disconnect()
		end
		table.clear(treeConnections)
		table.clear(nodeRowButtons)

		for _, child in treeScroll:GetChildren() do
			if not child:IsA("UILayout") and not child:IsA("UIPadding") then
				child:Destroy()
			end
		end

		if currentReport == nil then
			return
		end

		local report = currentReport
		local depAnalysis = report.dependencyAnalysis
		local layoutCounter = 0

		local function nextOrder(): number
			layoutCounter += 1
			return layoutCounter
		end

		-- 6.4 Circular Dependencies Banner (if any cycles exist)
		if #depAnalysis.circularChains > 0 then
			local cycleBanner = UIComponents.createPanel(
				treeScroll,
				"CircularDependenciesBanner",
				UDim2.new(1, 0, 0, 0),
				nextOrder(),
				Theme.Colors.DangerBg
			)
			cycleBanner.AutomaticSize = Enum.AutomaticSize.Y
			UIComponents.createPadding(cycleBanner, 6, 6, 8, 8)
			UIComponents.createListLayout(cycleBanner, Enum.FillDirection.Vertical, 3)

			local cycleTitle = Instance.new("TextLabel")
			cycleTitle.LayoutOrder = 1
			cycleTitle.Size = UDim2.new(1, 0, 0, 16)
			cycleTitle.BackgroundTransparency = 1
			cycleTitle.Font = Theme.Fonts.Bold
			cycleTitle.TextSize = 12
			cycleTitle.TextColor3 = Theme.Colors.DangerText
			cycleTitle.TextXAlignment = Enum.TextXAlignment.Left
			cycleTitle.Text = string.format(
				"[!] %d Circular Dependency Chain(s) Detected",
				#depAnalysis.circularChains
			)
			cycleTitle.Parent = cycleBanner

			local cycleNote = Instance.new("TextLabel")
			cycleNote.LayoutOrder = 2
			cycleNote.Size = UDim2.new(1, 0, 0, 0)
			cycleNote.AutomaticSize = Enum.AutomaticSize.Y
			cycleNote.BackgroundTransparency = 1
			cycleNote.Font = Theme.Fonts.Regular
			cycleNote.TextSize = 11
			cycleNote.TextColor3 = Theme.Colors.TextSecondary
			cycleNote.TextXAlignment = Enum.TextXAlignment.Left
			cycleNote.TextWrapped = true
			cycleNote.Text = "Note: Cyclic ModuleScript requires work at top level ONLY if the Roblox Studio Beta feature 'Luau Modularity: Export Values and Cyclic Requires' is enabled (or if require() calls are deferred inside functions). Without the beta feature enabled, top-level mutual requires will error/deadlock."
			cycleNote.Parent = cycleBanner

			for cIdx, chain in depAnalysis.circularChains do
				local shortNames: { string } = {}
				for _, p in chain do
					local sum = depAnalysis.byScriptPath[p]
					table.insert(shortNames, if sum ~= nil then sum.script.name else p)
				end
				local chainLbl = Instance.new("TextLabel")
				chainLbl.LayoutOrder = 2 + cIdx
				chainLbl.Size = UDim2.new(1, 0, 0, 16)
				chainLbl.BackgroundTransparency = 1
				chainLbl.Font = Theme.Fonts.Mono
				chainLbl.TextSize = 11
				chainLbl.TextColor3 = Theme.Colors.TextPrimary
				chainLbl.TextXAlignment = Enum.TextXAlignment.Left
				chainLbl.TextTruncate = Enum.TextTruncate.AtEnd
				chainLbl.Text = string.format("%d. %s", cIdx, table.concat(shortNames, " → "))
				chainLbl.Parent = cycleBanner
			end
		end

		-- Determine whether filters are active
		local hasActiveFilter = (filterStatus ~= "All") or (filterOrigin ~= "All") or (searchQuery ~= "")

		-- Recursive tree renderer for standard hierarchy mode
		local function renderDependencySubtree(
			parentScriptPath: string,
			nodeKeyPrefix: string,
			visualPrefix: string,
			ancestorSet: { [string]: boolean },
			depth: number
		)
			if depth > 14 then
				return
			end

			local summary = depAnalysis.byScriptPath[parentScriptPath]
			if summary == nil or #summary.dependencies == 0 then
				return
			end

			-- Filter direct dependencies if filters are active
			local depsToShow: { DependencyRecord } = {}
			for _, rec in summary.dependencies do
				if not hasActiveFilter or recordMatchesFilters(rec) then
					table.insert(depsToShow, rec)
				end
			end

			local countDeps = #depsToShow
			for idx, rec in depsToShow do
				local isLast = (idx == countDeps)
				local branchStr = visualPrefix .. (if isLast then "└── " else "├── ")
				local nextVisualPrefix = visualPrefix .. (if isLast then "    " else "│   ")

				local targetPath = rec.resolvedModulePath
				local targetSummary = if targetPath ~= nil then depAnalysis.byScriptPath[targetPath] else nil
				local isCycle = (targetPath ~= nil and ancestorSet[targetPath] == true)
				local hasChildren = (
					not isCycle
					and targetSummary ~= nil
					and #targetSummary.dependencies > 0
					and not hasActiveFilter
				)

				local edgeKey = string.format("%s>%d:%s", nodeKeyPrefix, idx, targetPath or rec.rawExpression)
				local expanded = hasChildren and isNodeExpanded(edgeKey)

				local rowBtn = Instance.new("TextButton")
				rowBtn.Name = "TreeEdge_" .. tostring(layoutCounter)
				rowBtn.LayoutOrder = nextOrder()
				rowBtn.Size = UDim2.new(1, 0, 0, 26)
				rowBtn.BackgroundColor3 = if selectedNodeKey == edgeKey
					then Theme.Colors.RowSelected
					else Theme.Colors.RowBackground
				rowBtn.BorderSizePixel = 0
				rowBtn.AutoButtonColor = true
				rowBtn.Text = ""
				rowBtn.Parent = treeScroll
				UIComponents.createCorner(rowBtn, 3)

				nodeRowButtons[edgeKey] = rowBtn

				local rowContent = Instance.new("Frame")
				rowContent.Size = UDim2.new(1, -8, 1, 0)
				rowContent.Position = UDim2.fromOffset(4, 0)
				rowContent.BackgroundTransparency = 1
				rowContent.Parent = rowBtn
				UIComponents.createListLayout(
					rowContent,
					Enum.FillDirection.Horizontal,
					4,
					Enum.HorizontalAlignment.Left,
					Enum.VerticalAlignment.Center
				)

				-- Tree branch prefix
				local prefixLbl = Instance.new("TextLabel")
				prefixLbl.LayoutOrder = 1
				prefixLbl.Size = UDim2.fromOffset(0, 24)
				prefixLbl.AutomaticSize = Enum.AutomaticSize.X
				prefixLbl.BackgroundTransparency = 1
				prefixLbl.Font = Theme.Fonts.Mono
				prefixLbl.TextSize = 12
				prefixLbl.TextColor3 = Theme.Colors.TextMuted
				prefixLbl.Text = branchStr
				prefixLbl.Parent = rowContent

				-- Expand/collapse toggle button if child has sub-dependencies
				if hasChildren then
					local toggleBtn = Instance.new("TextButton")
					toggleBtn.LayoutOrder = 2
					toggleBtn.Size = UDim2.fromOffset(18, 18)
					toggleBtn.BackgroundColor3 = Theme.Colors.ChipBackground
					toggleBtn.BorderSizePixel = 0
					toggleBtn.Font = Theme.Fonts.Bold
					toggleBtn.TextSize = 11
					toggleBtn.TextColor3 = Theme.Colors.TextSecondary
					toggleBtn.Text = if expanded then "▾" else "▸"
					toggleBtn.Parent = rowContent
					UIComponents.createCorner(toggleBtn, 3)

					table.insert(
						treeConnections,
						toggleBtn.Activated:Connect(function()
							expandedNodes[edgeKey] = not expanded
							rebuildTree()
						end)
					)
				end

				-- Class / Classification Badge
				if rec.status == "Resolved" then
					UIComponents.createClassBadge(rowContent, "ModuleScript", true, 3)
				end
				UIComponents.createClassificationBadge(rowContent, rec.classification, 4)

				-- Readable Target Name (avoid long paths inline!)
				local displayName = if rec.status == "Resolved" and rec.resolvedModuleName ~= nil
					then rec.resolvedModuleName
					else string.format("require(%s)", rec.rawExpression)

				local nameLbl = Instance.new("TextLabel")
				nameLbl.LayoutOrder = 5
				nameLbl.Size = UDim2.fromOffset(0, 24)
				nameLbl.AutomaticSize = Enum.AutomaticSize.X
				nameLbl.BackgroundTransparency = 1
				nameLbl.Font = Theme.Fonts.Bold
				nameLbl.TextSize = 13
				nameLbl.TextColor3 = if rec.status == "Resolved"
					then Theme.Colors.TextPrimary
					else Theme.Colors.OrangeText
				nameLbl.Text = displayName
				nameLbl.Parent = rowContent

				-- Line, Column & Scope tag
				local metaLbl = Instance.new("TextLabel")
				metaLbl.LayoutOrder = 6
				metaLbl.Size = UDim2.fromOffset(0, 24)
				metaLbl.AutomaticSize = Enum.AutomaticSize.X
				metaLbl.BackgroundTransparency = 1
				metaLbl.Font = Theme.Fonts.Mono
				metaLbl.TextSize = 11
				metaLbl.TextColor3 = Theme.Colors.TextMuted
				metaLbl.Text = string.format(
					"(L%d:%d, %s)",
					rec.lineNumber,
					rec.columnNumber,
					rec.scopeKind
				)
				metaLbl.Parent = rowContent

				if isCycle then
					UIComponents.createBadge(
						rowContent,
						"CIRCULAR",
						Theme.Colors.DangerText,
						Theme.Colors.DangerBg,
						7
					)
				end

				local capturedRec = rec
				table.insert(
					treeConnections,
					rowBtn.Activated:Connect(function()
						selectedRecord = capturedRec
						selectedRootPath = nil
						selectedNodeKey = edgeKey
						updateSelectedRowHighlight()
						renderDetailPanel()
					end)
				)

				if expanded and targetPath ~= nil then
					local nextAncestors: { [string]: boolean } = {}
					for k, v in ancestorSet do
						nextAncestors[k] = v
					end
					nextAncestors[targetPath] = true
					renderDependencySubtree(targetPath, edgeKey, nextVisualPrefix, nextAncestors, depth + 1)
				end
			end
		end

		-- Identify root scripts to display in the tree
		local rootSummaries: { ScriptDependencySummary } = {}
		local reachableFromExecutable: { [string]: boolean } = {}

		if not hasActiveFilter then
			-- Mark all modules transitively reachable from executable scripts so the default view is a clean tree
			local function markReachable(startPath: string)
				local sum = depAnalysis.byScriptPath[startPath]
				if sum == nil then
					return
				end
				for _, targetMod in sum.resolvedModules do
					if not reachableFromExecutable[targetMod] then
						reachableFromExecutable[targetMod] = true
						markReachable(targetMod)
					end
				end
			end

			for _, sInfo in report.scripts do
				if sInfo.isExecutable then
					markReachable(sInfo.fullPath)
				end
			end

			for _, sInfo in report.scripts do
				local sum = depAnalysis.byScriptPath[sInfo.fullPath]
				if sum ~= nil and #sum.dependencies > 0 then
					if sInfo.isExecutable or not reachableFromExecutable[sInfo.fullPath] then
						table.insert(rootSummaries, sum)
					end
				end
			end
		else
			-- When filters/search are active, include any script that has at least one matching dependency
			for _, sInfo in report.scripts do
				local sum = depAnalysis.byScriptPath[sInfo.fullPath]
				if sum ~= nil then
					for _, rec in sum.dependencies do
						if recordMatchesFilters(rec) then
							table.insert(rootSummaries, sum)
							break
						end
					end
				end
			end
		end

		if #rootSummaries == 0 then
			UIComponents.createEmptyState(
				treeScroll,
				"No Matching Dependencies",
				if #depAnalysis.allDependencies == 0
					then "No require() calls were discovered in the scanned DataModel."
					else "No dependencies matched the current filter criteria.",
				nextOrder()
			)
			return
		end

		for _, rootSum in rootSummaries do
			local rootScript = rootSum.script
			local rootKey = "root:" .. rootScript.fullPath
			local rootExpanded = isNodeExpanded(rootKey)

			local rootBtn = Instance.new("TextButton")
			rootBtn.Name = "RootNode_" .. rootScript.name
			rootBtn.LayoutOrder = nextOrder()
			rootBtn.Size = UDim2.new(1, 0, 0, 28)
			rootBtn.BackgroundColor3 = if selectedNodeKey == rootKey
				then Theme.Colors.RowSelected
				else Theme.Colors.PanelHeader
			rootBtn.BorderSizePixel = 0
			rootBtn.AutoButtonColor = true
			rootBtn.Text = ""
			rootBtn.Parent = treeScroll
			UIComponents.createCorner(rootBtn, 3)
			UIComponents.createStroke(rootBtn, Theme.Colors.BorderSubtle, 1)

			nodeRowButtons[rootKey] = rootBtn

			local rootContent = Instance.new("Frame")
			rootContent.Size = UDim2.new(1, -12, 1, 0)
			rootContent.Position = UDim2.fromOffset(6, 0)
			rootContent.BackgroundTransparency = 1
			rootContent.Parent = rootBtn
			UIComponents.createListLayout(
				rootContent,
				Enum.FillDirection.Horizontal,
				6,
				Enum.HorizontalAlignment.Left,
				Enum.VerticalAlignment.Center
			)

			local toggleBtn = Instance.new("TextButton")
			toggleBtn.LayoutOrder = 1
			toggleBtn.Size = UDim2.fromOffset(18, 18)
			toggleBtn.BackgroundColor3 = Theme.Colors.ChipBackground
			toggleBtn.BorderSizePixel = 0
			toggleBtn.Font = Theme.Fonts.Bold
			toggleBtn.TextSize = 11
			toggleBtn.TextColor3 = Theme.Colors.TextSecondary
			toggleBtn.Text = if rootExpanded then "▾" else "▸"
			toggleBtn.Parent = rootContent
			UIComponents.createCorner(toggleBtn, 3)

			table.insert(
				treeConnections,
				toggleBtn.Activated:Connect(function()
					expandedNodes[rootKey] = not rootExpanded
					rebuildTree()
				end)
			)

			UIComponents.createClassBadge(rootContent, rootScript.className, true, 2)

			local rootNameLbl = Instance.new("TextLabel")
			rootNameLbl.LayoutOrder = 3
			rootNameLbl.Size = UDim2.fromOffset(0, 24)
			rootNameLbl.AutomaticSize = Enum.AutomaticSize.X
			rootNameLbl.BackgroundTransparency = 1
			rootNameLbl.Font = Theme.Fonts.Bold
			rootNameLbl.TextSize = 13
			rootNameLbl.TextColor3 = Theme.Colors.TextPrimary
			rootNameLbl.Text = string.format("%s (%s)", rootScript.name, rootScript.className)
			rootNameLbl.Parent = rootContent

			UIComponents.createBadge(
				rootContent,
				string.format("%d direct", #rootSum.dependencies),
				Theme.Colors.NeutralBadgeText,
				Theme.Colors.NeutralBadgeBg,
				4
			)

			local capturedRootPath = rootScript.fullPath
			table.insert(
				treeConnections,
				rootBtn.Activated:Connect(function()
					selectedRecord = nil
					selectedRootPath = capturedRootPath
					selectedNodeKey = rootKey
					updateSelectedRowHighlight()
					renderDetailPanel()
				end)
			)

			if rootExpanded then
				local initialAncestors: { [string]: boolean } = {
					[rootScript.fullPath] = true,
				}
				renderDependencySubtree(rootScript.fullPath, rootKey, "", initialAncestors, 1)
			end
		end
	end

	local function render(report: ScanReport)
		currentReport = report
		-- Default selection to first dependency record if none is selected
		if selectedRecord == nil and selectedRootPath == nil then
			if #report.dependencyAnalysis.allDependencies > 0 then
				selectedRecord = report.dependencyAnalysis.allDependencies[1]
			elseif #report.scripts > 0 then
				selectedRootPath = report.scripts[1].fullPath
			end
		end
		rebuildTree()
		renderDetailPanel()
	end

	local function setStatusFilter(newStatus: string)
		filterStatus = newStatus
		setStatusChip(newStatus)
		rebuildTree()
	end

	local function destroy()
		for _, conn in detailConnections do
			conn:Disconnect()
		end
		for _, conn in treeConnections do
			conn:Disconnect()
		end
		for _, conn in viewConnections do
			conn:Disconnect()
		end
		table.clear(detailConnections)
		table.clear(treeConnections)
		table.clear(viewConnections)
		rootFrame:Destroy()
	end

	return {
		frame = rootFrame,
		render = render,
		setStatusFilter = setStatusFilter,
		destroy = destroy,
	}
end

return DependenciesView
