--!strict
--[[
	ExecutionView.luau
	Renders the Execution Analysis view (Section 7):
	- A. Known Execution Constraints (Confirmed engine & synchronous top-level require guarantees)
	- B. Potential Execution Order (Conditional depth-first ModuleScript evaluation sequences)
	- C. Undetermined Execution Order (Peer startup groups & multi-caller shared module ambiguities)
]]

local Types = require("./Types")
local Theme = require("./Theme")
local UIComponents = require("./UIComponents")

type ScanReport = Types.ScanReport
type ExecutionConstraintItem = Types.ExecutionConstraintItem
type OrderDeterminism = Types.OrderDeterminism

export type ExecutionCallbacks = {
	onNavigateToScript: (scriptPath: string) -> (),
}

export type ExecutionViewInstance = {
	frame: Frame,
	render: (report: ScanReport) -> (),
	destroy: () -> (),
}

local ExecutionView = {}

function ExecutionView.create(parent: Instance, callbacks: ExecutionCallbacks): ExecutionViewInstance
	local viewConnections: { RBXScriptConnection } = {}
	local contentConnections: { RBXScriptConnection } = {}

	local currentReport: ScanReport? = nil
	local searchQuery = ""
	local filterCategory = "All" -- "All" | "KnownConstraint" | "PotentialOrder" | "Undetermined"
	local filterEnv = "All" -- "All" | "Server" | "Client" | "Plugin" | "Shared"

	local sectionCollapsed: { [string]: boolean } = {
		KnownConstraint = false,
		PotentialOrder = false,
		Undetermined = false,
	}

	local rootFrame = Instance.new("Frame")
	rootFrame.Name = "ExecutionView"
	rootFrame.Size = UDim2.fromScale(1, 1)
	rootFrame.BackgroundTransparency = 1
	rootFrame.Visible = false
	rootFrame.Parent = parent

	UIComponents.createPadding(rootFrame, 8, 8, 10, 10)

	-- =========================================================================
	-- Top Filter & Search Bar
	-- =========================================================================
	local filterOuter = UIComponents.createPanel(rootFrame, "ExecFilterToolbar", UDim2.new(1, 0, 0, 114), 1)
	filterOuter.AutomaticSize = Enum.AutomaticSize.Y

	local filterPanel = Instance.new("Frame")
	filterPanel.Name = "ExecFilterToolbarContent"
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

	local rebuildContent: () -> ()

	UIComponents.createSearchInput(
		filterPanel,
		"Search execution constraints, scripts, or module initialization sequences...",
		UDim2.new(1, 0, 0, 28),
		1,
		function(newText: string)
			searchQuery = string.lower(newText)
			rebuildContent()
		end,
		viewConnections
	)

	UIComponents.createFilterBar(
		filterPanel,
		"Category",
		{
			{ id = "All", label = "All Categories" },
			{ id = "KnownConstraint", label = "A. Known Constraints" },
			{ id = "PotentialOrder", label = "B. Potential Order" },
			{ id = "Undetermined", label = "C. Undetermined Order" },
		},
		"All",
		2,
		function(id: string)
			filterCategory = id
			rebuildContent()
		end,
		viewConnections
	)

	UIComponents.createFilterBar(
		filterPanel,
		"Environment",
		{
			{ id = "All", label = "All Environments" },
			{ id = "Server", label = "Server" },
			{ id = "Client", label = "Client" },
			{ id = "Plugin", label = "Plugin" },
			{ id = "Shared", label = "Shared / Module" },
		},
		"All",
		3,
		function(id: string)
			filterEnv = id
			rebuildContent()
		end,
		viewConnections
	)

	-- =========================================================================
	-- Main Scrolling Area for the 3 Expandable Sections
	-- =========================================================================
	local mainScroll = UIComponents.createScrollFrame(
		rootFrame,
		"ExecutionScroll",
		UDim2.new(1, 0, 1, -122),
		2
	)
	mainScroll.Position = UDim2.fromOffset(0, 122)
	UIComponents.createPadding(mainScroll, 4, 12, 2, 4)
	UIComponents.createListLayout(mainScroll, Enum.FillDirection.Vertical, 10)

	local function syncScrollLayout()
		local panelHeight = math.max(76, filterOuter.AbsoluteSize.Y)
		local topOffset = panelHeight + 8
		mainScroll.Position = UDim2.fromOffset(0, topOffset)
		mainScroll.Size = UDim2.new(1, 0, 1, -topOffset)
	end
	table.insert(viewConnections, filterOuter:GetPropertyChangedSignal("AbsoluteSize"):Connect(syncScrollLayout))
	syncScrollLayout()

	local function itemMatchesFilters(item: ExecutionConstraintItem): boolean
		if filterCategory ~= "All" and item.category ~= filterCategory then
			return false
		end

		if filterEnv ~= "All" then
			local env = item.environment
			if filterEnv == "Server" then
				if env ~= "Server" and env ~= "ServerModule" then
					return false
				end
			elseif filterEnv == "Client" then
				if env ~= "Client" and env ~= "ClientModule" then
					return false
				end
			elseif filterEnv == "Plugin" then
				if env ~= "Plugin" then
					return false
				end
			elseif filterEnv == "Shared" then
				if env ~= "SharedModule" then
					return false
				end
			end
		end

		if searchQuery ~= "" then
			local matchTitle = string.find(string.lower(item.title), searchQuery, 1, true) ~= nil
			local matchDesc = string.find(string.lower(item.description), searchQuery, 1, true) ~= nil
			local matchSubj = item.subjectScriptPath ~= nil
				and string.find(string.lower(item.subjectScriptPath), searchQuery, 1, true) ~= nil
			local matchRelated = false
			for _, rel in item.relatedScripts do
				if string.find(string.lower(rel), searchQuery, 1, true) ~= nil then
					matchRelated = true
					break
				end
			end
			if not matchTitle and not matchDesc and not matchSubj and not matchRelated then
				return false
			end
		end

		return true
	end

	local function renderCategorySection(
		categoryKey: OrderDeterminism,
		sectionTitle: string,
		sectionSubtitle: string,
		items: { ExecutionConstraintItem },
		layoutOrder: number
	)
		local filteredItems: { ExecutionConstraintItem } = {}
		for _, item in items do
			if itemMatchesFilters(item) then
				table.insert(filteredItems, item)
			end
		end

		local badgeLabel, accentText, accentBg = Theme.getOrderCategoryVisuals(categoryKey)
		local isCollapsed = sectionCollapsed[categoryKey] == true

		local sectionOuter = UIComponents.createPanel(
			mainScroll,
			"Section_" .. categoryKey,
			UDim2.new(1, 0, 0, 0),
			layoutOrder
		)
		sectionOuter.AutomaticSize = Enum.AutomaticSize.Y

		local sectionContainer = Instance.new("Frame")
		sectionContainer.Name = "SectionContent"
		sectionContainer.Size = UDim2.fromScale(1, 1)
		sectionContainer.AutomaticSize = Enum.AutomaticSize.Y
		sectionContainer.BackgroundTransparency = 1
		sectionContainer.Parent = sectionOuter
		UIComponents.createPadding(sectionContainer, 8, 12, 10, 14)
		UIComponents.createListLayout(sectionContainer, Enum.FillDirection.Vertical, 8)

		UIComponents.attachPanelEdgeResizers(sectionOuter, {
			minHeight = 54,
			maxHeight = 1200,
			minWidth = 340,
			enableBottom = true,
			enableRight = true,
			enableCorner = true,
		}, contentConnections)

		-- Clickable Expand/Collapse Section Header
		local headerBtn = Instance.new("TextButton")
		headerBtn.Name = "SectionHeaderBtn"
		headerBtn.LayoutOrder = 1
		headerBtn.Size = UDim2.new(1, 0, 0, 38)
		headerBtn.BackgroundColor3 = Theme.Colors.PanelHeader
		headerBtn.BorderSizePixel = 0
		headerBtn.AutoButtonColor = true
		headerBtn.Text = ""
		headerBtn.Parent = sectionContainer
		UIComponents.createCorner(headerBtn, 4)

		local leftBar = Instance.new("Frame")
		leftBar.Size = UDim2.new(0, 4, 1, -8)
		leftBar.Position = UDim2.fromOffset(0, 4)
		leftBar.BackgroundColor3 = accentText
		leftBar.BorderSizePixel = 0
		leftBar.Parent = headerBtn
		UIComponents.createCorner(leftBar, 2)

		local arrowLbl = Instance.new("TextLabel")
		arrowLbl.Size = UDim2.fromOffset(20, 20)
		arrowLbl.Position = UDim2.fromOffset(10, 9)
		arrowLbl.BackgroundTransparency = 1
		arrowLbl.Font = Theme.Fonts.Bold
		arrowLbl.TextSize = 13
		arrowLbl.TextColor3 = Theme.Colors.TextSecondary
		arrowLbl.Text = if isCollapsed then "▸" else "▾"
		arrowLbl.Parent = headerBtn

		local titleLbl = Instance.new("TextLabel")
		titleLbl.Size = UDim2.new(1, -180, 0, 18)
		titleLbl.Position = UDim2.fromOffset(30, 3)
		titleLbl.BackgroundTransparency = 1
		titleLbl.Font = Theme.Fonts.Bold
		titleLbl.TextSize = 14
		titleLbl.TextColor3 = Theme.Colors.TextPrimary
		titleLbl.TextXAlignment = Enum.TextXAlignment.Left
		titleLbl.TextTruncate = Enum.TextTruncate.AtEnd
		titleLbl.Text = sectionTitle
		titleLbl.Parent = headerBtn

		local subLbl = Instance.new("TextLabel")
		subLbl.Size = UDim2.new(1, -180, 0, 14)
		subLbl.Position = UDim2.fromOffset(30, 20)
		subLbl.BackgroundTransparency = 1
		subLbl.Font = Theme.Fonts.Regular
		subLbl.TextSize = 11
		subLbl.TextColor3 = Theme.Colors.TextMuted
		subLbl.TextXAlignment = Enum.TextXAlignment.Left
		subLbl.TextTruncate = Enum.TextTruncate.AtEnd
		subLbl.Text = sectionSubtitle
		subLbl.Parent = headerBtn

		local countBadge = UIComponents.createBadge(
			headerBtn,
			string.format("%s (%d)", badgeLabel, #filteredItems),
			accentText,
			accentBg,
			1
		)
		countBadge.Position = UDim2.new(1, -8, 0.5, 0)
		countBadge.AnchorPoint = Vector2.new(1, 0.5)

		table.insert(
			contentConnections,
			headerBtn.Activated:Connect(function()
				sectionCollapsed[categoryKey] = not isCollapsed
				rebuildContent()
			end)
		)

		if isCollapsed then
			return
		end

		if #filteredItems == 0 then
			local emptyLbl = Instance.new("TextLabel")
			emptyLbl.LayoutOrder = 2
			emptyLbl.Size = UDim2.new(1, 0, 0, 22)
			emptyLbl.BackgroundTransparency = 1
			emptyLbl.Font = Theme.Fonts.Regular
			emptyLbl.TextSize = 12
			emptyLbl.TextColor3 = Theme.Colors.TextMuted
			emptyLbl.TextXAlignment = Enum.TextXAlignment.Left
			emptyLbl.Text = "No items in this category for the current scan and filter criteria."
			emptyLbl.Parent = sectionContainer
			return
		end

		for idx, item in filteredItems do
			local card = UIComponents.createPanel(
				sectionContainer,
				"ConstraintCard_" .. tostring(idx),
				UDim2.new(1, 0, 0, 0),
				idx + 1,
				Theme.Colors.RowAlternate
			)
			card.AutomaticSize = Enum.AutomaticSize.Y
			UIComponents.createPadding(card, 8, 8, 10, 10)
			UIComponents.createListLayout(card, Enum.FillDirection.Vertical, 5)

			-- Top metadata bar: Environment badge + Line badge + Subject Script button
			local topMeta = Instance.new("Frame")
			topMeta.Name = "TopMeta"
			topMeta.LayoutOrder = 1
			topMeta.Size = UDim2.new(1, 0, 0, 22)
			topMeta.AutomaticSize = Enum.AutomaticSize.Y
			topMeta.BackgroundTransparency = 1
			topMeta.Parent = card
			local topMetaLayout = UIComponents.createListLayout(
				topMeta,
				Enum.FillDirection.Horizontal,
				6,
				Enum.HorizontalAlignment.Left,
				Enum.VerticalAlignment.Center
			)
			topMetaLayout.Wraps = true

			UIComponents.createEnvironmentBadge(topMeta, item.environment, 1)

			if item.sourceLine ~= nil then
				UIComponents.createBadge(
					topMeta,
					string.format("Line %d", item.sourceLine),
					Theme.Colors.TextSecondary,
					Theme.Colors.NeutralBadgeBg,
					2
				)
			end

			local cardTitle = Instance.new("TextLabel")
			cardTitle.LayoutOrder = 3
			cardTitle.Size = UDim2.fromOffset(0, 20)
			cardTitle.AutomaticSize = Enum.AutomaticSize.X
			cardTitle.BackgroundTransparency = 1
			cardTitle.Font = Theme.Fonts.Bold
			cardTitle.TextSize = 13
			cardTitle.TextColor3 = Theme.Colors.TextPrimary
			cardTitle.TextXAlignment = Enum.TextXAlignment.Left
			cardTitle.Text = item.title
			cardTitle.Parent = topMeta

			if item.subjectScriptPath ~= nil then
				local subjPath = item.subjectScriptPath
				UIComponents.createButton(
					topMeta,
					"Inspect Script →",
					UDim2.fromOffset(102, 20),
					false,
					4,
					function()
						callbacks.onNavigateToScript(subjPath)
					end,
					contentConnections
				)
			end

			-- Description
			local descLbl = Instance.new("TextLabel")
			descLbl.LayoutOrder = 2
			descLbl.Size = UDim2.new(1, 0, 0, 0)
			descLbl.AutomaticSize = Enum.AutomaticSize.Y
			descLbl.BackgroundTransparency = 1
			descLbl.Font = Theme.Fonts.Regular
			descLbl.TextSize = 12
			descLbl.TextColor3 = Theme.Colors.TextSecondary
			descLbl.TextXAlignment = Enum.TextXAlignment.Left
			descLbl.TextWrapped = true
			descLbl.Text = item.description
			descLbl.Parent = card

			-- Conditions / Limitations Box
			if item.conditions ~= nil and item.conditions ~= "" then
				local condBox = Instance.new("Frame")
				condBox.Name = "ConditionsBox"
				condBox.LayoutOrder = 3
				condBox.Size = UDim2.new(1, 0, 0, 0)
				condBox.AutomaticSize = Enum.AutomaticSize.Y
				condBox.BackgroundColor3 = Theme.Colors.InputBackground
				condBox.BorderSizePixel = 0
				condBox.Parent = card
				UIComponents.createCorner(condBox, 3)
				UIComponents.createPadding(condBox, 5, 5, 8, 8)

				local condLbl = Instance.new("TextLabel")
				condLbl.Size = UDim2.new(1, 0, 0, 0)
				condLbl.AutomaticSize = Enum.AutomaticSize.Y
				condLbl.BackgroundTransparency = 1
				condLbl.Font = Theme.Fonts.SemiBold
				condLbl.TextSize = 11
				condLbl.TextColor3 = accentText
				condLbl.TextXAlignment = Enum.TextXAlignment.Left
				condLbl.TextWrapped = true
				condLbl.Text = item.conditions
				condLbl.Parent = condBox
			end

			-- Structured Steps or Related Scripts List
			if item.steps ~= nil and #item.steps > 0 then
				local stepsFrame = Instance.new("Frame")
				stepsFrame.Name = "StepsList"
				stepsFrame.LayoutOrder = 4
				stepsFrame.Size = UDim2.new(1, 0, 0, 0)
				stepsFrame.AutomaticSize = Enum.AutomaticSize.Y
				stepsFrame.BackgroundTransparency = 1
				stepsFrame.Parent = card
				UIComponents.createListLayout(stepsFrame, Enum.FillDirection.Vertical, 3)

				for _, step in item.steps do
					local stepBtn = Instance.new("TextButton")
					stepBtn.Name = "Step_" .. tostring(step.stepIndex)
					stepBtn.LayoutOrder = step.stepIndex
					stepBtn.Size = UDim2.new(1, 0, 0, 22)
					stepBtn.BackgroundColor3 = Theme.Colors.RowBackground
					stepBtn.BorderSizePixel = 0
					stepBtn.AutoButtonColor = true
					stepBtn.Text = ""
					stepBtn.Parent = stepsFrame
					UIComponents.createCorner(stepBtn, 3)

					local stepRow = Instance.new("Frame")
					stepRow.Size = UDim2.new(1, -12, 1, 0)
					stepRow.Position = UDim2.fromOffset(6, 0)
					stepRow.BackgroundTransparency = 1
					stepRow.Parent = stepBtn
					UIComponents.createListLayout(
						stepRow,
						Enum.FillDirection.Horizontal,
						6,
						Enum.HorizontalAlignment.Left,
						Enum.VerticalAlignment.Center
					)

					UIComponents.createBadge(
						stepRow,
						string.format("Step %d", step.stepIndex),
						accentText,
						accentBg,
						1
					)

					local sNameLbl = Instance.new("TextLabel")
					sNameLbl.LayoutOrder = 2
					sNameLbl.Size = UDim2.fromOffset(0, 20)
					sNameLbl.AutomaticSize = Enum.AutomaticSize.X
					sNameLbl.BackgroundTransparency = 1
					sNameLbl.Font = Theme.Fonts.Bold
					sNameLbl.TextSize = 12
					sNameLbl.TextColor3 = Theme.Colors.TextPrimary
					sNameLbl.Text = step.scriptName
					sNameLbl.Parent = stepRow

					local sPathLbl = Instance.new("TextLabel")
					sPathLbl.LayoutOrder = 3
					sPathLbl.Size = UDim2.fromOffset(0, 20)
					sPathLbl.AutomaticSize = Enum.AutomaticSize.X
					sPathLbl.BackgroundTransparency = 1
					sPathLbl.Font = Theme.Fonts.Mono
					sPathLbl.TextSize = 11
					sPathLbl.TextColor3 = Theme.Colors.TextMuted
					sPathLbl.Text = string.format(
						"(%s, line %s) — %s",
						step.scope,
						tostring(step.lineNumber or "?"),
						step.scriptPath
					)
					sPathLbl.Parent = stepRow

					local targetStepPath = step.scriptPath
					table.insert(
						contentConnections,
						stepBtn.Activated:Connect(function()
							callbacks.onNavigateToScript(targetStepPath)
						end)
					)
				end
			elseif #item.relatedScripts > 0 then
				local chipsFrame = Instance.new("Frame")
				chipsFrame.Name = "RelatedScriptsFlow"
				chipsFrame.LayoutOrder = 4
				chipsFrame.Size = UDim2.new(1, 0, 0, 0)
				chipsFrame.AutomaticSize = Enum.AutomaticSize.Y
				chipsFrame.BackgroundTransparency = 1
				chipsFrame.Parent = card
				local chipsLayout = UIComponents.createListLayout(
					chipsFrame,
					Enum.FillDirection.Horizontal,
					5,
					Enum.HorizontalAlignment.Left,
					Enum.VerticalAlignment.Center
				)
				chipsLayout.Wraps = true

				for rIdx, relPath in item.relatedScripts do
					local relChip = Instance.new("TextButton")
					relChip.Name = "Rel_" .. tostring(rIdx)
					relChip.LayoutOrder = rIdx
					relChip.Size = UDim2.fromOffset(0, 20)
					relChip.AutomaticSize = Enum.AutomaticSize.X
					relChip.BackgroundColor3 = Theme.Colors.ChipBackground
					relChip.BorderSizePixel = 0
					relChip.AutoButtonColor = true
					relChip.Font = Theme.Fonts.Mono
					relChip.TextSize = 11
					relChip.TextColor3 = Theme.Colors.TextPrimary
					relChip.Text = relPath
					relChip.Parent = chipsFrame
					UIComponents.createCorner(relChip, 3)
					UIComponents.createPadding(relChip, 0, 0, 6, 6)

					local capturedPath = relPath
					table.insert(
						contentConnections,
						relChip.Activated:Connect(function()
							if
								currentReport ~= nil
								and currentReport.dependencyAnalysis.byScriptPath[capturedPath] ~= nil
							then
								callbacks.onNavigateToScript(capturedPath)
							end
						end)
					)
				end
			end
		end
	end

	rebuildContent = function()
		for _, conn in contentConnections do
			conn:Disconnect()
		end
		table.clear(contentConnections)

		for _, child in mainScroll:GetChildren() do
			if not child:IsA("UILayout") and not child:IsA("UIPadding") then
				child:Destroy()
			end
		end

		if currentReport == nil then
			UIComponents.createEmptyState(
				mainScroll,
				"No Execution Analysis Available",
				"Run a scan to inspect known execution constraints, potential module sequences, and undetermined peer groups.",
				1
			)
			return
		end

		local execAnalysis = currentReport.executionAnalysis

		if filterCategory == "All" or filterCategory == "KnownConstraint" then
			renderCategorySection(
				"KnownConstraint",
				"A. Known Execution Constraints",
				"Confirmed engine lifecycle rules, synchronous top-level require() chains, and boundary constraints.",
				execAnalysis.knownConstraints,
				1
			)
		end

		if filterCategory == "All" or filterCategory == "PotentialOrder" then
			renderCategorySection(
				"PotentialOrder",
				"B. Potential Execution Order",
				"Conditional depth-first ModuleScript evaluation sequences (applies on first require() within a Luau VM).",
				execAnalysis.potentialOrders,
				2
			)
		end

		if filterCategory == "All" or filterCategory == "Undetermined" then
			renderCategorySection(
				"Undetermined",
				"C. Undetermined Execution Order",
				"Peer script startup groups and multi-caller shared modules whose exact order cannot be determined statically.",
				execAnalysis.undeterminedGroups,
				3
			)
		end
	end

	local function render(report: ScanReport)
		currentReport = report
		rebuildContent()
	end

	local function destroy()
		for _, conn in contentConnections do
			conn:Disconnect()
		end
		for _, conn in viewConnections do
			conn:Disconnect()
		end
		table.clear(contentConnections)
		table.clear(viewConnections)
		rootFrame:Destroy()
	end

	return {
		frame = rootFrame,
		render = render,
		destroy = destroy,
	}
end

return ExecutionView
