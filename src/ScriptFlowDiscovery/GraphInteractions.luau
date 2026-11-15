--!strict
--[[
	GraphInteractions.luau
	Responsibility:
	- Handles zoom (in, out, reset, cursor-centered wheel zoom), pan (click-and-drag),
	  node selection, double-click focus/collapse, search with auto-focus, view history
	  (Fit Graph, Focus Selected, Previous View), and live visual filtering without rescanning.
	- Renders the Game Architecture Diagram panel, toolbar, filter bar, legend,
	  and dedicated Node Details inspector panel.
]]

local Selection = game:GetService("Selection")
local UserInputService = game:GetService("UserInputService")

local Types = require("./Types")
local Theme = require("./Theme")
local UIComponents = require("./UIComponents")
local GraphBuilder = require("./GraphBuilder")
local GraphLayout = require("./GraphLayout")
local GraphRenderer = require("./GraphRenderer")

type ScanReport = Types.ScanReport
type GraphModel = Types.GraphModel
type GraphNode = Types.GraphNode
type GraphEdge = Types.GraphEdge
type GraphLayoutResult = Types.GraphLayoutResult
type GraphFilterState = Types.GraphFilterState

export type DiagramCallbacks = {
	onNavigateToScript: (scriptPath: string) -> (),
}

export type DiagramWidgetInstance = {
	container: Frame,
	setReport: (report: ScanReport) -> (),
	focusNodeById: (nodeId: string) -> (),
	getModel: () -> GraphModel?,
	getLayout: () -> GraphLayoutResult?,
	destroy: () -> (),
}

type ViewCameraState = {
	panX: number,
	panY: number,
	zoom: number,
}

local MIN_ZOOM = 0.35
local MAX_ZOOM = 1.85
local ZOOM_STEP = 0.15
local DIAGRAM_HEIGHT = 580
local INSPECTOR_WIDTH = 268

local GraphInteractions = {}

function GraphInteractions.createDiagramWidget(
	parent: Instance,
	layoutOrder: number,
	callbacks: DiagramCallbacks
): DiagramWidgetInstance
	local widgetConnections: { RBXScriptConnection } = {}
	local inspectorConnections: { RBXScriptConnection } = {}

	local currentModel: GraphModel? = nil
	local currentLayout: GraphLayoutResult? = nil
	local filters: GraphFilterState = GraphLayout.createDefaultFilters()
	local collapsedContainers: { [string]: boolean } = {}

	local zoom = 0.90
	local panX = 16
	local panY = 16
	local previousCamera: ViewCameraState? = nil

	local selectedNodeId: string? = nil
	local hoveredNodeId: string? = nil
	local searchMatchedIds: { [string]: boolean } = {}
	local searchMatchList: { string } = {}
	local searchMatchIndex = 0

	local isDraggingCanvas = false
	local activeDragInput: InputObject? = nil
	local activeDragStateConn: RBXScriptConnection? = nil
	local dragStartMouse = Vector2.new(0, 0)
	local dragStartPanX = 0
	local dragStartPanY = 0

	-- Outer Panel
	local outerPanel = UIComponents.createPanel(
		parent,
		"GameArchitectureDiagramPanel",
		UDim2.new(1, 0, 0, DIAGRAM_HEIGHT),
		layoutOrder
	)

	-- 1. Top Toolbar Row (Search + Zoom + Viewport Focus Controls)
	local topToolbar = Instance.new("Frame")
	topToolbar.Name = "DiagramTopToolbar"
	topToolbar.Size = UDim2.new(1, 0, 0, 34)
	topToolbar.Position = UDim2.fromOffset(0, 0)
	topToolbar.BackgroundColor3 = Theme.Colors.PanelHeader
	topToolbar.BorderSizePixel = 0
	topToolbar.Parent = outerPanel
	UIComponents.createPadding(topToolbar, 4, 4, 8, 8)

	local topDivider = Instance.new("Frame")
	topDivider.Name = "Divider"
	topDivider.Size = UDim2.new(1, 0, 0, 1)
	topDivider.Position = UDim2.new(0, 0, 1, -1)
	topDivider.BackgroundColor3 = Theme.Colors.BorderSubtle
	topDivider.BorderSizePixel = 0
	topDivider.Parent = topToolbar

	-- Left side of Top Toolbar: Search Box + Match Counter
	local leftToolbar = Instance.new("Frame")
	leftToolbar.Name = "LeftSearchControls"
	leftToolbar.Size = UDim2.new(0.42, 0, 1, 0)
	leftToolbar.BackgroundTransparency = 1
	leftToolbar.Parent = topToolbar
	UIComponents.createListLayout(
		leftToolbar,
		Enum.FillDirection.Horizontal,
		6,
		Enum.HorizontalAlignment.Left,
		Enum.VerticalAlignment.Center
	)

	-- Right side of Top Toolbar: Zoom + Focus + Collapse Controls
	local rightToolbar = Instance.new("Frame")
	rightToolbar.Name = "RightViewControls"
	rightToolbar.AnchorPoint = Vector2.new(1, 0)
	rightToolbar.Position = UDim2.fromScale(1, 0)
	rightToolbar.Size = UDim2.new(0.58, 0, 1, 0)
	rightToolbar.BackgroundTransparency = 1
	rightToolbar.Parent = topToolbar
	UIComponents.createListLayout(
		rightToolbar,
		Enum.FillDirection.Horizontal,
		4,
		Enum.HorizontalAlignment.Right,
		Enum.VerticalAlignment.Center
	)

	-- 2. Filter Bar Row (Live Node & Relationship Toggles)
	local filterBar = Instance.new("Frame")
	filterBar.Name = "DiagramFilterBar"
	filterBar.Size = UDim2.new(1, 0, 0, 30)
	filterBar.AutomaticSize = Enum.AutomaticSize.Y
	filterBar.Position = UDim2.fromOffset(0, 34)
	filterBar.BackgroundColor3 = Theme.Colors.MainBackground
	filterBar.BorderSizePixel = 0
	filterBar.Parent = outerPanel
	UIComponents.createPadding(filterBar, 4, 4, 8, 8)
	local filterBarLayout = UIComponents.createListLayout(
		filterBar,
		Enum.FillDirection.Horizontal,
		5,
		Enum.HorizontalAlignment.Left,
		Enum.VerticalAlignment.Center
	)
	filterBarLayout.Wraps = true

	-- 3. Main Body Area (Interactive Viewport on Left + Node Details Inspector on Right)
	local bodyFrame = Instance.new("Frame")
	bodyFrame.Name = "DiagramBody"
	bodyFrame.Size = UDim2.new(1, 0, 1, -90)
	bodyFrame.Position = UDim2.fromOffset(0, 64)
	bodyFrame.BackgroundColor3 = Theme.Colors.InputBackground
	bodyFrame.BorderSizePixel = 0
	bodyFrame.ClipsDescendants = true
	bodyFrame.Parent = outerPanel

	local function syncDiagramBodyBounds()
		local filterH = math.max(30, filterBar.AbsoluteSize.Y)
		local topTotal = 34 + filterH
		bodyFrame.Position = UDim2.fromOffset(0, topTotal)
		bodyFrame.Size = UDim2.new(1, 0, 1, -(topTotal + 26))
	end
	table.insert(widgetConnections, filterBar:GetPropertyChangedSignal("AbsoluteSize"):Connect(syncDiagramBodyBounds))
	syncDiagramBodyBounds()

	-- Interactive Graph Viewport
	local viewportFrame = Instance.new("Frame")
	viewportFrame.Name = "GraphViewport"
	viewportFrame.Size = UDim2.new(1, -INSPECTOR_WIDTH, 1, 0)
	viewportFrame.Position = UDim2.fromOffset(0, 0)
	viewportFrame.BackgroundColor3 = Theme.Colors.InputBackground
	viewportFrame.BorderSizePixel = 0
	viewportFrame.ClipsDescendants = true
	viewportFrame.Active = true
	viewportFrame.Parent = bodyFrame

	-- Background Drag Surface inside Viewport
	local dragSurface = Instance.new("TextButton")
	dragSurface.Name = "PanDragSurface"
	dragSurface.Size = UDim2.fromScale(1, 1)
	dragSurface.BackgroundTransparency = 1
	dragSurface.BorderSizePixel = 0
	dragSurface.AutoButtonColor = false
	dragSurface.Text = ""
	dragSurface.ZIndex = 1
	dragSurface.Parent = viewportFrame

	-- Node Details Inspector Panel (Right Side)
	local inspectorPanel = Instance.new("Frame")
	inspectorPanel.Name = "NodeInspectorPanel"
	inspectorPanel.AnchorPoint = Vector2.new(1, 0)
	inspectorPanel.Position = UDim2.fromScale(1, 0)
	inspectorPanel.Size = UDim2.new(0, INSPECTOR_WIDTH, 1, 0)
	inspectorPanel.BackgroundColor3 = Theme.Colors.PanelBackground
	inspectorPanel.BorderSizePixel = 0
	inspectorPanel.Parent = bodyFrame

	local inspectorLeftBorder = Instance.new("Frame")
	inspectorLeftBorder.Name = "LeftBorder"
	inspectorLeftBorder.Size = UDim2.new(0, 1, 1, 0)
	inspectorLeftBorder.Position = UDim2.fromOffset(0, 0)
	inspectorLeftBorder.BackgroundColor3 = Theme.Colors.Border
	inspectorLeftBorder.BorderSizePixel = 0
	inspectorLeftBorder.Parent = inspectorPanel

	local inspectorHeader = Instance.new("Frame")
	inspectorHeader.Name = "InspectorHeader"
	inspectorHeader.Size = UDim2.new(1, 0, 0, 26)
	inspectorHeader.BackgroundColor3 = Theme.Colors.PanelHeader
	inspectorHeader.BorderSizePixel = 0
	inspectorHeader.Parent = inspectorPanel
	UIComponents.createPadding(inspectorHeader, 0, 0, 8, 8)

	local inspectorTitle = Instance.new("TextLabel")
	inspectorTitle.Name = "Title"
	inspectorTitle.Size = UDim2.fromScale(1, 1)
	inspectorTitle.BackgroundTransparency = 1
	inspectorTitle.Font = Theme.Fonts.Bold
	inspectorTitle.TextSize = 11
	inspectorTitle.TextColor3 = Theme.Colors.TextSecondary
	inspectorTitle.TextXAlignment = Enum.TextXAlignment.Left
	inspectorTitle.Text = "NODE INSPECTOR"
	inspectorTitle.Parent = inspectorHeader

	local inspectorScroll = UIComponents.createScrollFrame(
		inspectorPanel,
		"InspectorScroll",
		UDim2.new(1, 0, 1, -26),
		1
	)
	inspectorScroll.Position = UDim2.fromOffset(0, 26)
	UIComponents.createPadding(inspectorScroll, 8, 10, 8, 8)
	UIComponents.createListLayout(inspectorScroll, Enum.FillDirection.Vertical, 6)

	-- Draggable splitter on the left border of the Node Inspector Panel
	UIComponents.attachLeftEdgePixelResizer(
		bodyFrame,
		viewportFrame,
		inspectorPanel,
		INSPECTOR_WIDTH,
		185,
		520,
		widgetConnections
	)

	-- Draggable bottom, right, and corner resize handles on the outer Diagram Window
	UIComponents.attachPanelEdgeResizers(outerPanel, {
		minHeight = 320,
		maxHeight = 1400,
		minWidth = 420,
		enableBottom = true,
		enableRight = true,
		enableCorner = true,
	}, widgetConnections)

	-- 4. Bottom Status & Visual Legend Bar
	local legendBar = Instance.new("Frame")
	legendBar.Name = "DiagramLegendBar"
	legendBar.AnchorPoint = Vector2.new(0, 1)
	legendBar.Position = UDim2.fromScale(0, 1)
	legendBar.Size = UDim2.new(1, 0, 0, 26)
	legendBar.BackgroundColor3 = Theme.Colors.PanelHeader
	legendBar.BorderSizePixel = 0
	legendBar.Parent = outerPanel
	UIComponents.createPadding(legendBar, 2, 2, 8, 8)

	local legendTopBorder = Instance.new("Frame")
	legendTopBorder.Name = "TopBorder"
	legendTopBorder.Size = UDim2.new(1, 0, 0, 1)
	legendTopBorder.Position = UDim2.fromOffset(0, 0)
	legendTopBorder.BackgroundColor3 = Theme.Colors.BorderSubtle
	legendTopBorder.BorderSizePixel = 0
	legendTopBorder.Parent = legendBar

	local legendLeft = Instance.new("Frame")
	legendLeft.Name = "LegendItems"
	legendLeft.Size = UDim2.new(0.68, 0, 1, 0)
	legendLeft.BackgroundTransparency = 1
	legendLeft.Parent = legendBar
	UIComponents.createListLayout(
		legendLeft,
		Enum.FillDirection.Horizontal,
		10,
		Enum.HorizontalAlignment.Left,
		Enum.VerticalAlignment.Center
	)

	local function createLegendItem(label: string, color: Color3, order: number)
		local item = Instance.new("Frame")
		item.Name = "Legend_" .. label
		item.LayoutOrder = order
		item.Size = UDim2.fromOffset(0, 18)
		item.AutomaticSize = Enum.AutomaticSize.X
		item.BackgroundTransparency = 1
		item.Parent = legendLeft
		UIComponents.createListLayout(
			item,
			Enum.FillDirection.Horizontal,
			4,
			Enum.HorizontalAlignment.Left,
			Enum.VerticalAlignment.Center
		)

		local swatch = Instance.new("Frame")
		swatch.Name = "Swatch"
		swatch.LayoutOrder = 1
		swatch.Size = UDim2.fromOffset(12, 3)
		swatch.BackgroundColor3 = color
		swatch.BorderSizePixel = 0
		swatch.Parent = item
		UIComponents.createCorner(swatch, 2)

		local lbl = Instance.new("TextLabel")
		lbl.Name = "Label"
		lbl.LayoutOrder = 2
		lbl.Size = UDim2.fromOffset(0, 16)
		lbl.AutomaticSize = Enum.AutomaticSize.X
		lbl.BackgroundTransparency = 1
		lbl.Font = Theme.Fonts.Regular
		lbl.TextSize = 11
		lbl.TextColor3 = Theme.Colors.TextSecondary
		lbl.Text = label
		lbl.Parent = item
	end

	createLegendItem("Hierarchy", Theme.Colors.EdgeStructural, 1)
	createLegendItem("Static req", Theme.Colors.EdgeStatic, 2)
	createLegendItem("Dynamic req", Theme.Colors.EdgeDynamic, 3)
	createLegendItem("Conditional", Theme.Colors.EdgeConditional, 4)
	createLegendItem("Unresolved / Cycle", Theme.Colors.EdgeUnresolved, 5)

	local statusLabel = Instance.new("TextLabel")
	statusLabel.Name = "GraphStatusLabel"
	statusLabel.AnchorPoint = Vector2.new(1, 0)
	statusLabel.Position = UDim2.fromScale(1, 0)
	statusLabel.Size = UDim2.new(0.32, 0, 1, 0)
	statusLabel.BackgroundTransparency = 1
	statusLabel.Font = Theme.Fonts.Mono
	statusLabel.TextSize = 11
	statusLabel.TextColor3 = Theme.Colors.TextMuted
	statusLabel.TextXAlignment = Enum.TextXAlignment.Right
	statusLabel.Text = "0 nodes · 0 edges"
	statusLabel.Parent = legendBar

	-- Forward declarations
	local refreshGraphRender: (recomputeLayout: boolean) -> ()
	local renderInspector: () -> ()
	local focusNodeById: (nodeId: string) -> ()

	local renderer: GraphRenderer.GraphRendererInstance
	renderer = GraphRenderer.create(viewportFrame, {
		onSelectNode = function(nodeId: string)
			selectedNodeId = nodeId
			if currentModel ~= nil and currentLayout ~= nil then
				renderer.updateHighlights(
					currentModel,
					currentLayout,
					zoom,
					selectedNodeId,
					hoveredNodeId,
					searchMatchedIds
				)
			end
			renderInspector()
		end,
		onDoubleClickNode = function(nodeId: string)
			selectedNodeId = nodeId
			if currentModel ~= nil then
				local node = currentModel.nodesById[nodeId]
				if node ~= nil then
					if node.isContainer and not node.isScript and #node.childIds > 0 then
						if collapsedContainers[nodeId] then
							collapsedContainers[nodeId] = nil
						else
							collapsedContainers[nodeId] = true
						end
						refreshGraphRender(true)
						renderInspector()
						return
					end
				end
			end
			focusNodeById(nodeId)
			renderInspector()
		end,
		onToggleCollapse = function(nodeId: string)
			if collapsedContainers[nodeId] then
				collapsedContainers[nodeId] = nil
			else
				collapsedContainers[nodeId] = true
			end
			refreshGraphRender(true)
			renderInspector()
		end,
		onHoverNode = function(nodeId: string?)
			hoveredNodeId = nodeId
			if currentModel ~= nil and currentLayout ~= nil then
				renderer.updateHighlights(
					currentModel,
					currentLayout,
					zoom,
					selectedNodeId,
					hoveredNodeId,
					searchMatchedIds
				)
			end
		end,
	})

	local function savePreviousCamera()
		previousCamera = {
			panX = panX,
			panY = panY,
			zoom = zoom,
		}
	end

	local function applyCanvasTransform()
		renderer.canvasFrame.Position = UDim2.fromOffset(math.round(panX), math.round(panY))
	end

	local zoomReadoutBtn: TextButton? = nil

	local function setZoomAroundPoint(newZoom: number, focalViewportX: number, focalViewportY: number)
		local clamped = math.clamp(newZoom, MIN_ZOOM, MAX_ZOOM)
		if math.abs(clamped - zoom) < 0.001 then
			return
		end

		local graphX = (focalViewportX - panX) / zoom
		local graphY = (focalViewportY - panY) / zoom

		zoom = clamped
		panX = focalViewportX - graphX * zoom
		panY = focalViewportY - graphY * zoom

		if zoomReadoutBtn ~= nil then
			zoomReadoutBtn.Text = string.format("%d%%", math.round(zoom * 100))
		end

		refreshGraphRender(false)
		applyCanvasTransform()
	end

	focusNodeById = function(nodeId: string)
		if currentLayout == nil then
			return
		end
		local lNode = currentLayout.layoutNodesById[nodeId]
		if lNode == nil or not lNode.visible then
			return
		end
		savePreviousCamera()
		local vpSize = viewportFrame.AbsoluteSize
		local vpW = if vpSize.X > 20 then vpSize.X else 520
		local vpH = if vpSize.Y > 20 then vpSize.Y else 380

		local nodeCenterX = (lNode.x + lNode.width * 0.5) * zoom
		local nodeCenterY = (lNode.y + lNode.height * 0.5) * zoom

		panX = (vpW * 0.5) - nodeCenterX
		panY = (vpH * 0.5) - nodeCenterY
		applyCanvasTransform()
	end

	local function fitGraphInView()
		if currentLayout == nil then
			return
		end
		savePreviousCamera()
		local vpSize = viewportFrame.AbsoluteSize
		local vpW = if vpSize.X > 40 then vpSize.X else 540
		local vpH = if vpSize.Y > 40 then vpSize.Y else 380

		local cW = math.max(100, currentLayout.canvasWidth)
		local cH = math.max(100, currentLayout.canvasHeight)

		local scaleX = (vpW - 24) / cW
		local scaleY = (vpH - 24) / cH
		zoom = math.clamp(math.min(scaleX, scaleY, 1.05), MIN_ZOOM, MAX_ZOOM)

		panX = math.max(12, math.round((vpW - cW * zoom) * 0.5))
		panY = math.max(12, math.round((vpH - cH * zoom) * 0.5))

		if zoomReadoutBtn ~= nil then
			zoomReadoutBtn.Text = string.format("%d%%", math.round(zoom * 100))
		end

		refreshGraphRender(false)
		applyCanvasTransform()
	end

	-- Top Toolbar Controls
	local searchMatchLabel = Instance.new("TextLabel")

	local function recomputeSearchMatches(autoFocusFirst: boolean)
		table.clear(searchMatchedIds)
		table.clear(searchMatchList)
		searchMatchIndex = 0

		local trimmedQuery = string.gsub(filters.searchQuery, "^%s*(.-)%s*$", "%1")
		local query = string.lower(trimmedQuery)
		if query ~= "" and currentLayout ~= nil then
			for _, lNode in currentLayout.orderedLayoutNodes do
				if not lNode.visible then
					continue
				end
				local node = lNode.node
				local nameLower = string.lower(node.name)
				local pathLower = string.lower(node.fullPath)
				local classLower = string.lower(node.className)
				if
					string.find(nameLower, query, 1, true) ~= nil
					or string.find(pathLower, query, 1, true) ~= nil
					or string.find(classLower, query, 1, true) ~= nil
				then
					searchMatchedIds[node.id] = true
					table.insert(searchMatchList, node.id)
				end
			end
		end

		if #searchMatchList > 0 then
			searchMatchIndex = 1
			searchMatchLabel.Text = string.format("%d/%d", searchMatchIndex, #searchMatchList)
			searchMatchLabel.TextColor3 = Theme.Colors.WarningText
			if autoFocusFirst then
				local firstId = searchMatchList[1]
				selectedNodeId = firstId
				focusNodeById(firstId)
				renderInspector()
			end
		elseif query ~= "" then
			searchMatchLabel.Text = "0 hits"
			searchMatchLabel.TextColor3 = Theme.Colors.DangerText
		else
			searchMatchLabel.Text = ""
		end

		if currentModel ~= nil and currentLayout ~= nil then
			renderer.updateHighlights(
				currentModel,
				currentLayout,
				zoom,
				selectedNodeId,
				hoveredNodeId,
				searchMatchedIds
			)
		end
	end

	UIComponents.createSearchInput(
		leftToolbar,
		"Search nodes, scripts, modules, paths...",
		UDim2.fromOffset(210, 24),
		1,
		function(newText: string)
			filters.searchQuery = newText
			recomputeSearchMatches(true)
		end,
		widgetConnections
	)

	searchMatchLabel.Name = "SearchMatchCount"
	searchMatchLabel.LayoutOrder = 2
	searchMatchLabel.Size = UDim2.fromOffset(42, 20)
	searchMatchLabel.BackgroundTransparency = 1
	searchMatchLabel.Font = Theme.Fonts.Mono
	searchMatchLabel.TextSize = 11
	searchMatchLabel.TextColor3 = Theme.Colors.TextMuted
	searchMatchLabel.TextXAlignment = Enum.TextXAlignment.Left
	searchMatchLabel.Text = ""
	searchMatchLabel.Parent = leftToolbar

	UIComponents.createButton(
		leftToolbar,
		"Next",
		UDim2.fromOffset(42, 22),
		false,
		3,
		function()
			if #searchMatchList == 0 then
				return
			end
			searchMatchIndex = (searchMatchIndex % #searchMatchList) + 1
			searchMatchLabel.Text = string.format("%d/%d", searchMatchIndex, #searchMatchList)
			local targetId = searchMatchList[searchMatchIndex]
			selectedNodeId = targetId
			focusNodeById(targetId)
			if currentModel ~= nil and currentLayout ~= nil then
				renderer.updateHighlights(
					currentModel,
					currentLayout,
					zoom,
					selectedNodeId,
					hoveredNodeId,
					searchMatchedIds
				)
			end
			renderInspector()
		end,
		widgetConnections
	)

	-- Zoom & Focus Buttons on Right Toolbar
	UIComponents.createButton(
		rightToolbar,
		"-",
		UDim2.fromOffset(24, 22),
		false,
		1,
		function()
			local vp = viewportFrame.AbsoluteSize
			setZoomAroundPoint(zoom - ZOOM_STEP, vp.X * 0.5, vp.Y * 0.5)
		end,
		widgetConnections
	)

	zoomReadoutBtn = UIComponents.createButton(
		rightToolbar,
		"90%",
		UDim2.fromOffset(46, 22),
		false,
		2,
		function()
			local vp = viewportFrame.AbsoluteSize
			setZoomAroundPoint(1.0, vp.X * 0.5, vp.Y * 0.5)
		end,
		widgetConnections
	)

	UIComponents.createButton(
		rightToolbar,
		"+",
		UDim2.fromOffset(24, 22),
		false,
		3,
		function()
			local vp = viewportFrame.AbsoluteSize
			setZoomAroundPoint(zoom + ZOOM_STEP, vp.X * 0.5, vp.Y * 0.5)
		end,
		widgetConnections
	)

	UIComponents.createButton(
		rightToolbar,
		"Fit Graph",
		UDim2.fromOffset(64, 22),
		false,
		4,
		function()
			fitGraphInView()
		end,
		widgetConnections
	)

	UIComponents.createButton(
		rightToolbar,
		"Focus Node",
		UDim2.fromOffset(72, 22),
		false,
		5,
		function()
			if selectedNodeId ~= nil then
				focusNodeById(selectedNodeId)
			end
		end,
		widgetConnections
	)

	UIComponents.createButton(
		rightToolbar,
		"Prev View",
		UDim2.fromOffset(64, 22),
		false,
		6,
		function()
			if previousCamera ~= nil then
				local restore = previousCamera
				previousCamera = {
					panX = panX,
					panY = panY,
					zoom = zoom,
				}
				panX = restore.panX
				panY = restore.panY
				zoom = restore.zoom
				if zoomReadoutBtn ~= nil then
					zoomReadoutBtn.Text = string.format("%d%%", math.round(zoom * 100))
				end
				refreshGraphRender(false)
				applyCanvasTransform()
			else
				fitGraphInView()
			end
		end,
		widgetConnections
	)

	-- 2. Filter Bar Toggle Buttons
	local filterHeading = Instance.new("TextLabel")
	filterHeading.Name = "FilterHeading"
	filterHeading.LayoutOrder = 1
	filterHeading.Size = UDim2.fromOffset(42, 20)
	filterHeading.BackgroundTransparency = 1
	filterHeading.Font = Theme.Fonts.Bold
	filterHeading.TextSize = 11
	filterHeading.TextColor3 = Theme.Colors.TextMuted
	filterHeading.TextXAlignment = Enum.TextXAlignment.Left
	filterHeading.Text = "FILTERS:"
	filterHeading.Parent = filterBar

	local function createFilterToggle(
		label: string,
		initialState: boolean,
		activeColor: Color3,
		order: number,
		onToggle: (enabled: boolean) -> ()
	)
		local state = initialState
		local btn = Instance.new("TextButton")
		btn.Name = "Toggle_" .. label
		btn.LayoutOrder = order
		btn.Size = UDim2.fromOffset(0, 20)
		btn.AutomaticSize = Enum.AutomaticSize.X
		btn.BorderSizePixel = 0
		btn.AutoButtonColor = true
		btn.Font = Theme.Fonts.SemiBold
		btn.TextSize = 11
		btn.Parent = filterBar
		UIComponents.createCorner(btn, 3)
		UIComponents.createPadding(btn, 0, 0, 7, 7)

		local stroke = UIComponents.createStroke(btn, activeColor, 1)

		local function syncVisual()
			if state then
				btn.BackgroundColor3 = Theme.Colors.ChipBackground
				btn.TextColor3 = activeColor
				stroke.Color = activeColor
				stroke.Transparency = 0.2
				btn.Text = "[x] " .. label
			else
				btn.BackgroundColor3 = Theme.Colors.InputBackground
				btn.TextColor3 = Theme.Colors.TextMuted
				stroke.Color = Theme.Colors.BorderSubtle
				stroke.Transparency = 0.5
				btn.Text = "[ ] " .. label
			end
		end

		syncVisual()

		table.insert(
			widgetConnections,
			btn.Activated:Connect(function()
				state = not state
				syncVisual()
				onToggle(state)
			end)
		)
	end

	createFilterToggle("Containers", filters.showContainers, Theme.Colors.ServiceText, 2, function(on)
		filters.showContainers = on
		refreshGraphRender(true)
	end)
	createFilterToggle("Scripts", filters.showScripts, Theme.Colors.ScriptText, 3, function(on)
		filters.showScripts = on
		refreshGraphRender(true)
	end)
	createFilterToggle("LocalScripts", filters.showLocalScripts, Theme.Colors.LocalScriptText, 4, function(on)
		filters.showLocalScripts = on
		refreshGraphRender(true)
	end)
	createFilterToggle("ModuleScripts", filters.showModuleScripts, Theme.Colors.ModuleScriptText, 5, function(on)
		filters.showModuleScripts = on
		refreshGraphRender(true)
	end)
	createFilterToggle("Hierarchy", filters.showStructuralEdges, Theme.Colors.EdgeStructural, 6, function(on)
		filters.showStructuralEdges = on
		refreshGraphRender(true)
	end)
	createFilterToggle("Dependencies", filters.showDependencyEdges, Theme.Colors.EdgeStatic, 7, function(on)
		filters.showDependencyEdges = on
		refreshGraphRender(true)
	end)
	createFilterToggle("Dynamic", filters.showDynamicDependencies, Theme.Colors.EdgeDynamic, 8, function(on)
		filters.showDynamicDependencies = on
		refreshGraphRender(true)
	end)

	-- Canvas Panning & Wheel Zoom Input Handling
	local parentScrollingFrame: ScrollingFrame? = if parent:IsA("ScrollingFrame") then parent else nil

	local function stopCanvasDrag()
		isDraggingCanvas = false
		activeDragInput = nil
		dragSurface.ZIndex = 1
		if activeDragStateConn ~= nil then
			activeDragStateConn:Disconnect()
			activeDragStateConn = nil
		end
	end

	local function isDragInputStillHeld(): boolean
		if not isDraggingCanvas then
			return false
		end
		if activeDragInput ~= nil then
			local st = activeDragInput.UserInputState
			if st == Enum.UserInputState.End or st == Enum.UserInputState.Cancel then
				stopCanvasDrag()
				return false
			end
		end
		return true
	end

	local function beginCanvasDrag(input: InputObject)
		if
			input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.MouseButton2
			or input.UserInputType == Enum.UserInputType.MouseButton3
		then
			stopCanvasDrag()
			isDraggingCanvas = true
			activeDragInput = input
			dragStartMouse = Vector2.new(input.Position.X, input.Position.Y)
			dragStartPanX = panX
			dragStartPanY = panY

			activeDragStateConn = input:GetPropertyChangedSignal("UserInputState"):Connect(function()
				local st = input.UserInputState
				if st == Enum.UserInputState.End or st == Enum.UserInputState.Cancel then
					stopCanvasDrag()
				end
			end)
		end
	end

	local function isMouseEndInput(input: InputObject): boolean
		return input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.MouseButton2
			or input.UserInputType == Enum.UserInputType.MouseButton3
	end

	table.insert(
		widgetConnections,
		dragSurface.InputBegan:Connect(function(input: InputObject)
			beginCanvasDrag(input)
		end)
	)

	table.insert(
		widgetConnections,
		dragSurface.InputEnded:Connect(function(input: InputObject)
			if isMouseEndInput(input) then
				stopCanvasDrag()
			end
		end)
	)

	table.insert(
		widgetConnections,
		dragSurface.MouseButton1Up:Connect(function()
			stopCanvasDrag()
		end)
	)

	table.insert(
		widgetConnections,
		dragSurface.MouseButton2Up:Connect(function()
			stopCanvasDrag()
		end)
	)

	table.insert(
		widgetConnections,
		viewportFrame.MouseEnter:Connect(function()
			if parentScrollingFrame ~= nil then
				parentScrollingFrame.ScrollingEnabled = false
			end
		end)
	)

	table.insert(
		widgetConnections,
		viewportFrame.MouseLeave:Connect(function()
			stopCanvasDrag()
			if parentScrollingFrame ~= nil then
				parentScrollingFrame.ScrollingEnabled = true
			end
		end)
	)

	local function handlePointerMoveOrWheel(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseMovement then
			if isDragInputStillHeld() then
				local deltaX = input.Position.X - dragStartMouse.X
				local deltaY = input.Position.Y - dragStartMouse.Y
				if math.abs(deltaX) + math.abs(deltaY) >= 2 then
					-- Keep dragSurface above node buttons while actively panning so nodes passing
					-- underneath the cursor never steal focus or swallow the MouseButtonUp/InputEnded event.
					dragSurface.ZIndex = 50
				end
				panX = dragStartPanX + deltaX
				panY = dragStartPanY + deltaY
				applyCanvasTransform()
			end
		elseif input.UserInputType == Enum.UserInputType.MouseWheel then
			local vpPos = viewportFrame.AbsolutePosition
			local localX = input.Position.X - vpPos.X
			local localY = input.Position.Y - vpPos.Y
			local wheelDelta = if input.Position.Z > 0 then ZOOM_STEP else -ZOOM_STEP
			setZoomAroundPoint(zoom + wheelDelta, localX, localY)
		end
	end

	table.insert(
		widgetConnections,
		viewportFrame.InputChanged:Connect(handlePointerMoveOrWheel)
	)

	table.insert(
		widgetConnections,
		dragSurface.InputChanged:Connect(handlePointerMoveOrWheel)
	)

	table.insert(
		widgetConnections,
		renderer.nodesLayer.InputEnded:Connect(function(input: InputObject)
			if isMouseEndInput(input) then
				stopCanvasDrag()
			end
		end)
	)

	table.insert(
		widgetConnections,
		renderer.canvasFrame.InputEnded:Connect(function(input: InputObject)
			if isMouseEndInput(input) then
				stopCanvasDrag()
			end
		end)
	)

	table.insert(
		widgetConnections,
		viewportFrame.InputEnded:Connect(function(input: InputObject)
			if isMouseEndInput(input) then
				stopCanvasDrag()
			end
		end)
	)

	table.insert(
		widgetConnections,
		outerPanel.InputEnded:Connect(function(input: InputObject)
			if isMouseEndInput(input) then
				stopCanvasDrag()
			end
		end)
	)

	table.insert(
		widgetConnections,
		UserInputService.InputEnded:Connect(function(input: InputObject)
			if isMouseEndInput(input) then
				stopCanvasDrag()
			end
		end)
	)

	-- Clicking background deselects active node
	table.insert(
		widgetConnections,
		dragSurface.Activated:Connect(function()
			stopCanvasDrag()
			local movedDist = math.abs(panX - dragStartPanX) + math.abs(panY - dragStartPanY)
			if movedDist < 4 then
				selectedNodeId = nil
				if currentModel ~= nil and currentLayout ~= nil then
					renderer.updateHighlights(
						currentModel,
						currentLayout,
						zoom,
						selectedNodeId,
						hoveredNodeId,
						searchMatchedIds
					)
				end
				renderInspector()
			end
		end)
	)

	local function clearInspector()
		for _, conn in inspectorConnections do
			conn:Disconnect()
		end
		table.clear(inspectorConnections)

		for _, child in inspectorScroll:GetChildren() do
			if not child:IsA("UILayout") and not child:IsA("UIPadding") then
				child:Destroy()
			end
		end
	end

	renderInspector = function()
		clearInspector()

		local selId = selectedNodeId
		if currentModel == nil or selId == nil then
			local hint = Instance.new("TextLabel")
			hint.Name = "EmptyInspectorHint"
			hint.LayoutOrder = 1
			hint.Size = UDim2.new(1, 0, 0, 0)
			hint.AutomaticSize = Enum.AutomaticSize.Y
			hint.BackgroundTransparency = 1
			hint.Font = Theme.Fonts.Regular
			hint.TextSize = 12
			hint.TextColor3 = Theme.Colors.TextMuted
			hint.TextWrapped = true
			hint.TextXAlignment = Enum.TextXAlignment.Left
			hint.Text = "Select any node in the diagram to inspect its hierarchy, incoming requirers, outgoing require() calls, and Studio shortcuts.\n\nTips:\n- Drag canvas to pan\n- Scroll wheel to zoom around cursor\n- Double-click a container to collapse/expand\n- Double-click a node to center it"
			hint.Parent = inspectorScroll
			return
		end

		local model = currentModel :: GraphModel
		local node = model.nodesById[selId]
		if node == nil then
			return
		end

		local shortTag, typeLabel, textCol, bgCol, _ = Theme.getNodeTypeVisuals(node.nodeType)
		if node.className == "UnresolvedRequire" then
			shortTag = "[?]"
			typeLabel = "Unresolved require()"
			textCol = Theme.Colors.DangerText
			bgCol = Theme.Colors.DangerBg
		end

		-- Header Badge + Node Name
		local titleRow = Instance.new("Frame")
		titleRow.Name = "TitleRow"
		titleRow.LayoutOrder = 1
		titleRow.Size = UDim2.new(1, 0, 0, 0)
		titleRow.AutomaticSize = Enum.AutomaticSize.Y
		titleRow.BackgroundTransparency = 1
		titleRow.Parent = inspectorScroll
		UIComponents.createListLayout(
			titleRow,
			Enum.FillDirection.Horizontal,
			6,
			Enum.HorizontalAlignment.Left,
			Enum.VerticalAlignment.Center
		)

		UIComponents.createBadge(titleRow, shortTag .. " " .. typeLabel, textCol, bgCol, 1)
		if node.environment ~= nil then
			UIComponents.createEnvironmentBadge(titleRow, node.environment, 2)
		end

		local nameHeading = Instance.new("TextLabel")
		nameHeading.Name = "NodeNameHeading"
		nameHeading.LayoutOrder = 2
		nameHeading.Size = UDim2.new(1, 0, 0, 20)
		nameHeading.BackgroundTransparency = 1
		nameHeading.Font = Theme.Fonts.Bold
		nameHeading.TextSize = 15
		nameHeading.TextColor3 = Theme.Colors.TextPrimary
		nameHeading.TextXAlignment = Enum.TextXAlignment.Left
		nameHeading.TextTruncate = Enum.TextTruncate.AtEnd
		nameHeading.Text = node.name
		nameHeading.Parent = inspectorScroll

		-- Full Copyable Path Box
		local pathBox = Instance.new("TextBox")
		pathBox.Name = "CopyablePathBox"
		pathBox.LayoutOrder = 3
		pathBox.Size = UDim2.new(1, 0, 0, 0)
		pathBox.AutomaticSize = Enum.AutomaticSize.Y
		pathBox.BackgroundColor3 = Theme.Colors.InputBackground
		pathBox.BorderSizePixel = 0
		pathBox.ClearTextOnFocus = false
		pathBox.TextEditable = false
		pathBox.Font = Theme.Fonts.Mono
		pathBox.TextSize = 11
		pathBox.TextColor3 = Theme.Colors.TextSecondary
		pathBox.TextXAlignment = Enum.TextXAlignment.Left
		pathBox.TextWrapped = true
		pathBox.Text = node.fullPath
		pathBox.Parent = inspectorScroll
		UIComponents.createCorner(pathBox, 3)
		UIComponents.createPadding(pathBox, 4, 4, 6, 6)

		-- Studio Action Buttons
		local actionsFlow = Instance.new("Frame")
		actionsFlow.Name = "StudioActions"
		actionsFlow.LayoutOrder = 4
		actionsFlow.Size = UDim2.new(1, 0, 0, 0)
		actionsFlow.AutomaticSize = Enum.AutomaticSize.Y
		actionsFlow.BackgroundTransparency = 1
		actionsFlow.Parent = inspectorScroll
		local actionsLayout = UIComponents.createListLayout(
			actionsFlow,
			Enum.FillDirection.Horizontal,
			4,
			Enum.HorizontalAlignment.Left,
			Enum.VerticalAlignment.Center
		)
		actionsLayout.Wraps = true

		if node.instance ~= nil then
			local targetInst = node.instance
			UIComponents.createButton(
				actionsFlow,
				"Select in Explorer",
				UDim2.fromOffset(112, 22),
				false,
				1,
				function()
					pcall(function()
						Selection:Set({ targetInst })
					end)
				end,
				inspectorConnections
			)
		end

		if node.isScript and node.scriptInfo ~= nil then
			local scriptInst = node.scriptInfo.instance
			local scriptFullPath = node.fullPath
			UIComponents.createButton(
				actionsFlow,
				"Open Script",
				UDim2.fromOffset(82, 22),
				true,
				2,
				function()
					UIComponents.openScriptInStudio(scriptInst, 1)
				end,
				inspectorConnections
			)

			UIComponents.createButton(
				actionsFlow,
				"Inspect in Scripts ->",
				UDim2.fromOffset(122, 22),
				false,
				3,
				function()
					callbacks.onNavigateToScript(scriptFullPath)
				end,
				inspectorConnections
			)
		end

		if #node.childIds > 0 then
			local isCollapsed = collapsedContainers[node.id] == true
			UIComponents.createButton(
				actionsFlow,
				if isCollapsed then "Expand Container" else "Collapse Container",
				UDim2.fromOffset(118, 22),
				false,
				4,
				function()
					if collapsedContainers[node.id] then
						collapsedContainers[node.id] = nil
					else
						collapsedContainers[node.id] = true
					end
					refreshGraphRender(true)
					renderInspector()
				end,
				inspectorConnections
			)
		end

		-- Key-Value Metadata
		UIComponents.createKeyValueRow(inspectorScroll, "Class", node.className, nil, 5)
		UIComponents.createKeyValueRow(inspectorScroll, "Service", node.serviceName, nil, 6)
		if node.isScript and node.scriptInfo ~= nil then
			UIComponents.createKeyValueRow(
				inspectorScroll,
				"Lines",
				tostring(node.scriptInfo.lineCount),
				nil,
				7
			)
		else
			UIComponents.createKeyValueRow(
				inspectorScroll,
				"Child Scripts",
				tostring(node.childScriptCount),
				nil,
				7
			)
		end

		-- Collect Outgoing & Incoming Dependency Edges for this Node
		local outgoingDeps: { GraphEdge } = {}
		local incomingDeps: { GraphEdge } = {}
		for _, edge in model.dependencyEdges do
			if edge.sourceNodeId == node.id then
				table.insert(outgoingDeps, edge)
			end
			if edge.targetNodeId == node.id then
				table.insert(incomingDeps, edge)
			end
		end

		-- Outgoing Dependencies Section
		local outHeader = Instance.new("TextLabel")
		outHeader.Name = "OutgoingHeader"
		outHeader.LayoutOrder = 10
		outHeader.Size = UDim2.new(1, 0, 0, 18)
		outHeader.BackgroundTransparency = 1
		outHeader.Font = Theme.Fonts.Bold
		outHeader.TextSize = 11
		outHeader.TextColor3 = Theme.Colors.EdgeOutgoingHighlight
		outHeader.TextXAlignment = Enum.TextXAlignment.Left
		outHeader.Text = string.format("OUTGOING DEPENDENCIES (%d)", #outgoingDeps)
		outHeader.Parent = inspectorScroll

		if #outgoingDeps == 0 then
			local noneOut = Instance.new("TextLabel")
			noneOut.LayoutOrder = 11
			noneOut.Size = UDim2.new(1, 0, 0, 16)
			noneOut.BackgroundTransparency = 1
			noneOut.Font = Theme.Fonts.Regular
			noneOut.TextSize = 11
			noneOut.TextColor3 = Theme.Colors.TextMuted
			noneOut.TextXAlignment = Enum.TextXAlignment.Left
			noneOut.Text = "None"
			noneOut.Parent = inspectorScroll
		else
			local outList = Instance.new("Frame")
			outList.Name = "OutgoingList"
			outList.LayoutOrder = 11
			outList.Size = UDim2.new(1, 0, 0, 0)
			outList.AutomaticSize = Enum.AutomaticSize.Y
			outList.BackgroundTransparency = 1
			outList.Parent = inspectorScroll
			UIComponents.createListLayout(outList, Enum.FillDirection.Vertical, 4)

			for idx, depEdge in outgoingDeps do
				local tgtNode = model.nodesById[depEdge.targetNodeId]
				local tgtName = if tgtNode ~= nil then tgtNode.name else depEdge.targetNodeId
				local card = Instance.new("TextButton")
				card.Name = "OutDep_" .. tostring(idx)
				card.LayoutOrder = idx
				card.Size = UDim2.new(1, 0, 0, 0)
				card.AutomaticSize = Enum.AutomaticSize.Y
				card.BackgroundColor3 = Theme.Colors.RowBackground
				card.BorderSizePixel = 0
				card.AutoButtonColor = true
				card.Text = ""
				card.Parent = outList
				UIComponents.createCorner(card, 3)
				UIComponents.createPadding(card, 4, 4, 6, 6)
				UIComponents.createListLayout(card, Enum.FillDirection.Vertical, 2)

				local topLine = Instance.new("Frame")
				topLine.LayoutOrder = 1
				topLine.Size = UDim2.new(1, 0, 0, 18)
				topLine.BackgroundTransparency = 1
				topLine.Parent = card
				UIComponents.createListLayout(
					topLine,
					Enum.FillDirection.Horizontal,
					4,
					Enum.HorizontalAlignment.Left,
					Enum.VerticalAlignment.Center
				)

				if depEdge.classification ~= nil then
					UIComponents.createClassificationBadge(topLine, depEdge.classification, 1)
				end

				local tLbl = Instance.new("TextLabel")
				tLbl.LayoutOrder = 2
				tLbl.Size = UDim2.new(1, -78, 1, 0)
				tLbl.BackgroundTransparency = 1
				tLbl.Font = Theme.Fonts.Bold
				tLbl.TextSize = 12
				tLbl.TextColor3 = Theme.Colors.TextPrimary
				tLbl.TextXAlignment = Enum.TextXAlignment.Left
				tLbl.TextTruncate = Enum.TextTruncate.AtEnd
				tLbl.Text = "-> " .. tgtName
				tLbl.Parent = topLine

				local metaParts: { string } = {}
				if depEdge.lineNumber ~= nil then
					table.insert(
						metaParts,
						string.format("L%d:%d", depEdge.lineNumber, depEdge.columnNumber or 1)
					)
				end
				if depEdge.scopeKind ~= nil then
					table.insert(metaParts, "Scope: " .. depEdge.scopeKind)
				end
				if depEdge.conditionExpression ~= nil then
					table.insert(metaParts, "if " .. depEdge.conditionExpression)
				end
				if depEdge.isCircular then
					table.insert(
						metaParts,
						"Cyclic (works only if 'Luau Modularity: Export Values and Cyclic Requires' Beta is ON)"
					)
				end

				if #metaParts > 0 then
					local metaLbl = Instance.new("TextLabel")
					metaLbl.LayoutOrder = 2
					metaLbl.Size = UDim2.new(1, 0, 0, 0)
					metaLbl.AutomaticSize = Enum.AutomaticSize.Y
					metaLbl.BackgroundTransparency = 1
					metaLbl.Font = Theme.Fonts.Mono
					metaLbl.TextSize = 10
					metaLbl.TextColor3 = Theme.Colors.TextMuted
					metaLbl.TextXAlignment = Enum.TextXAlignment.Left
					metaLbl.TextWrapped = true
					metaLbl.Text = table.concat(metaParts, " · ")
					metaLbl.Parent = card
				end

				local targetNodeId = depEdge.targetNodeId
				table.insert(
					inspectorConnections,
					card.Activated:Connect(function()
						selectedNodeId = targetNodeId
						focusNodeById(targetNodeId)
						if currentModel ~= nil and currentLayout ~= nil then
							renderer.updateHighlights(
								currentModel,
								currentLayout,
								zoom,
								selectedNodeId,
								hoveredNodeId,
								searchMatchedIds
							)
						end
						renderInspector()
					end)
				)
			end
		end

		-- Incoming Dependents Section
		local inHeader = Instance.new("TextLabel")
		inHeader.Name = "IncomingHeader"
		inHeader.LayoutOrder = 20
		inHeader.Size = UDim2.new(1, 0, 0, 18)
		inHeader.BackgroundTransparency = 1
		inHeader.Font = Theme.Fonts.Bold
		inHeader.TextSize = 11
		inHeader.TextColor3 = Theme.Colors.EdgeIncomingHighlight
		inHeader.TextXAlignment = Enum.TextXAlignment.Left
		inHeader.Text = string.format("REQUIRED BY (%d)", #incomingDeps)
		inHeader.Parent = inspectorScroll

		if #incomingDeps == 0 then
			local noneIn = Instance.new("TextLabel")
			noneIn.LayoutOrder = 21
			noneIn.Size = UDim2.new(1, 0, 0, 16)
			noneIn.BackgroundTransparency = 1
			noneIn.Font = Theme.Fonts.Regular
			noneIn.TextSize = 11
			noneIn.TextColor3 = Theme.Colors.TextMuted
			noneIn.TextXAlignment = Enum.TextXAlignment.Left
			noneIn.Text = "None"
			noneIn.Parent = inspectorScroll
		else
			local inList = Instance.new("Frame")
			inList.Name = "IncomingList"
			inList.LayoutOrder = 21
			inList.Size = UDim2.new(1, 0, 0, 0)
			inList.AutomaticSize = Enum.AutomaticSize.Y
			inList.BackgroundTransparency = 1
			inList.Parent = inspectorScroll
			UIComponents.createListLayout(inList, Enum.FillDirection.Vertical, 4)

			for idx, depEdge in incomingDeps do
				local srcNode = model.nodesById[depEdge.sourceNodeId]
				local srcName = if srcNode ~= nil then srcNode.name else depEdge.sourceNodeId
				local card = Instance.new("TextButton")
				card.Name = "InDep_" .. tostring(idx)
				card.LayoutOrder = idx
				card.Size = UDim2.new(1, 0, 0, 24)
				card.BackgroundColor3 = Theme.Colors.RowBackground
				card.BorderSizePixel = 0
				card.AutoButtonColor = true
				card.Text = ""
				card.Parent = inList
				UIComponents.createCorner(card, 3)
				UIComponents.createPadding(card, 0, 0, 6, 6)
				UIComponents.createListLayout(
					card,
					Enum.FillDirection.Horizontal,
					4,
					Enum.HorizontalAlignment.Left,
					Enum.VerticalAlignment.Center
				)

				if depEdge.classification ~= nil then
					UIComponents.createClassificationBadge(card, depEdge.classification, 1)
				end

				local sLbl = Instance.new("TextLabel")
				sLbl.LayoutOrder = 2
				sLbl.Size = UDim2.new(1, -80, 1, 0)
				sLbl.BackgroundTransparency = 1
				sLbl.Font = Theme.Fonts.SemiBold
				sLbl.TextSize = 12
				sLbl.TextColor3 = Theme.Colors.TextPrimary
				sLbl.TextXAlignment = Enum.TextXAlignment.Left
				sLbl.TextTruncate = Enum.TextTruncate.AtEnd
				sLbl.Text = string.format("<- %s (L%d)", srcName, depEdge.lineNumber or 1)
				sLbl.Parent = card

				local callerId = depEdge.sourceNodeId
				table.insert(
					inspectorConnections,
					card.Activated:Connect(function()
						selectedNodeId = callerId
						focusNodeById(callerId)
						if currentModel ~= nil and currentLayout ~= nil then
							renderer.updateHighlights(
								currentModel,
								currentLayout,
								zoom,
								selectedNodeId,
								hoveredNodeId,
								searchMatchedIds
							)
						end
						renderInspector()
					end)
				)
			end
		end
	end

	refreshGraphRender = function(recomputeLayout: boolean)
		if currentModel == nil then
			return
		end
		local model = currentModel :: GraphModel
		if recomputeLayout or currentLayout == nil then
			currentLayout = GraphLayout.computeLayout(model, filters, collapsedContainers)
		end
		local layout = currentLayout :: GraphLayoutResult

		renderer.renderLayout(
			model,
			layout,
			zoom,
			selectedNodeId,
			hoveredNodeId,
			searchMatchedIds
		)

		local visibleNodeCount = 0
		for _, ln in layout.orderedLayoutNodes do
			if ln.visible then
				visibleNodeCount += 1
			end
		end

		local path2dTag = if renderer.validationResult.supported then "Path2D: OK" else "Path2D: ERR"
		statusLabel.Text = string.format(
			"%d nodes · %d curves · %s",
			visibleNodeCount,
			#layout.layoutEdges,
			path2dTag
		)
	end

	local function setReport(report: ScanReport)
		local builtModel = GraphBuilder.build(report)
		currentModel = builtModel
		if selectedNodeId ~= nil and builtModel.nodesById[selectedNodeId] == nil then
			selectedNodeId = nil
		end
		refreshGraphRender(true)
		recomputeSearchMatches(false)
		applyCanvasTransform()
		renderInspector()
	end

	local function getModel(): GraphModel?
		return currentModel
	end

	local function getLayout(): GraphLayoutResult?
		return currentLayout
	end

	local function destroy()
		stopCanvasDrag()
		if parentScrollingFrame ~= nil then
			parentScrollingFrame.ScrollingEnabled = true
		end
		clearInspector()
		for _, conn in widgetConnections do
			conn:Disconnect()
		end
		table.clear(widgetConnections)
		renderer.destroy()
		outerPanel:Destroy()
	end

	renderInspector()

	return {
		container = outerPanel,
		setReport = setReport,
		focusNodeById = focusNodeById,
		getModel = getModel,
		getLayout = getLayout,
		destroy = destroy,
	}
end

return GraphInteractions
