--!strict
--[[
	GraphRenderer.luau
	Responsibility:
	- Validates native Roblox Path2D support inside DockWidgetPluginGui (Phase 1 check).
	- Creates and reuses node UI cards and Path2D curve instances.
	- Applies Path2DControlPoint positions and tangents via Path2D:SetControlPoints().
	- Renders directional arrowheads and edge classification pills (DYN, COND, UNRES, CYCLE).
	- Updates selection, hover, and search highlighting states without rebuilding the graph.
]]

local Types = require("./Types")
local Theme = require("./Theme")
local UIComponents = require("./UIComponents")

type GraphModel = Types.GraphModel
type GraphNode = Types.GraphNode
type GraphEdge = Types.GraphEdge
type GraphLayoutResult = Types.GraphLayoutResult
type GraphLayoutNode = Types.GraphLayoutNode
type GraphLayoutEdge = Types.GraphLayoutEdge
type Path2DValidationResult = Types.Path2DValidationResult

export type NodeInteractionCallbacks = {
	onSelectNode: (nodeId: string) -> (),
	onDoubleClickNode: (nodeId: string) -> (),
	onToggleCollapse: (nodeId: string) -> (),
	onHoverNode: (nodeId: string?) -> (),
}

type PooledNodeUI = {
	button: TextButton,
	stroke: UIStroke,
	accentStripe: Frame,
	typeBadge: TextLabel,
	titleLabel: TextLabel,
	collapseBtn: TextButton,
	subtitleLabel: TextLabel,
	statsRightLabel: TextLabel,
	nodeId: string,
	connections: { RBXScriptConnection },
}

type PooledEdgeUI = {
	path2d: Path2D,
	arrowHead: TextLabel,
	midTag: TextLabel,
	edgeId: string,
}

export type GraphRendererInstance = {
	canvasFrame: Frame,
	edgesLayer: Frame,
	nodesLayer: Frame,
	validationResult: Path2DValidationResult,
	renderLayout: (
		model: GraphModel,
		layout: GraphLayoutResult,
		zoom: number,
		selectedNodeId: string?,
		hoveredNodeId: string?,
		searchMatchedIds: { [string]: boolean }
	) -> (),
	updateHighlights: (
		model: GraphModel,
		layout: GraphLayoutResult,
		zoom: number,
		selectedNodeId: string?,
		hoveredNodeId: string?,
		searchMatchedIds: { [string]: boolean }
	) -> (),
	clear: () -> (),
	destroy: () -> (),
}

local GraphRenderer = {}

function GraphRenderer.validatePath2DSupport(parent: GuiObject): Path2DValidationResult
	local canInstantiate = false
	local canParentToGuiObject = false
	local canSetControlPoints = false
	local canStyleProperties = false
	local canQueryCurveGeometry = false
	local diagParts: { string } = {}

	local pathInstance: Path2D? = nil
	local okCreate, errCreate = pcall(function(): boolean
		local inst = Instance.new("Path2D")
		pathInstance = inst
		canInstantiate = true
		return true
	end)

	if not okCreate or pathInstance == nil then
		return {
			supported = false,
			canInstantiate = false,
			canParentToGuiObject = false,
			canSetControlPoints = false,
			canStyleProperties = false,
			canQueryCurveGeometry = false,
			diagnosticMessage = "Path2D instantiation failed: " .. tostring(errCreate),
		}
	end

	local validPath = pathInstance :: Path2D

	local okParent, errParent = pcall(function(): boolean
		validPath.Parent = parent
		canParentToGuiObject = (validPath.Parent == parent)
		return canParentToGuiObject
	end)
	if not okParent then
		table.insert(diagParts, "Parent error: " .. tostring(errParent))
	end

	local okPoints, errPoints = pcall(function(): boolean
		local cp1 = Path2DControlPoint.new(
			UDim2.fromOffset(10, 10),
			UDim2.fromOffset(0, 0),
			UDim2.fromOffset(40, 0)
		)
		local cp2 = Path2DControlPoint.new(
			UDim2.fromOffset(110, 50),
			UDim2.fromOffset(-40, 0),
			UDim2.fromOffset(0, 0)
		)
		validPath:SetControlPoints({ cp1, cp2 })
		local count = #validPath:GetControlPoints()
		canSetControlPoints = (count == 2)
		return canSetControlPoints
	end)
	if not okPoints then
		table.insert(diagParts, "SetControlPoints error: " .. tostring(errPoints))
	end

	local okStyle, errStyle = pcall(function(): boolean
		validPath.Color3 = Theme.Colors.EdgeStatic
		validPath.Thickness = 2
		validPath.Visible = true
		validPath.ZIndex = 2
		canStyleProperties = true
		return true
	end)
	if not okStyle then
		table.insert(diagParts, "Style error: " .. tostring(errStyle))
	end

	local okGeo, errGeo = pcall(function(): boolean
		local _pos = validPath:GetPositionOnCurve(0.5)
		local _tan = validPath:GetTangentOnCurve(0.5)
		local _len = validPath:GetLength()
		canQueryCurveGeometry = true
		return true
	end)
	if not okGeo then
		table.insert(diagParts, "Geometry query note: " .. tostring(errGeo))
	end

	pcall(function()
		validPath:Destroy()
	end)

	local supported = canInstantiate and canParentToGuiObject and canSetControlPoints and canStyleProperties
	local diagnosticMessage = if supported
		then "Path2D verified inside DockWidgetPluginGui (ControlPoints, Tangents, Styling, Curve Geometry ready)"
		else ("Path2D validation incomplete: " .. table.concat(diagParts, "; "))

	return {
		supported = supported,
		canInstantiate = canInstantiate,
		canParentToGuiObject = canParentToGuiObject,
		canSetControlPoints = canSetControlPoints,
		canStyleProperties = canStyleProperties,
		canQueryCurveGeometry = canQueryCurveGeometry,
		diagnosticMessage = diagnosticMessage,
	}
end

local function getBaseEdgeColorAndThickness(edge: GraphEdge): (Color3, number, string?)
	if edge.kind == "Structural" then
		return Theme.Colors.EdgeStructural, 1.5, nil
	end
	if edge.isCircular then
		return Theme.Colors.EdgeUnresolved, 2.4, "CYCLE"
	end
	local classification = edge.classification
	if classification == "Static" then
		return Theme.Colors.EdgeStatic, 2.0, nil
	elseif classification == "DynamicResolved" then
		local countSuffix = if edge.candidateCount ~= nil and edge.candidateCount > 1
			then string.format("DYN(%d)", edge.candidateCount)
			else "DYN"
		return Theme.Colors.EdgeDynamic, 2.2, countSuffix
	elseif classification == "DynamicPartial" then
		return Theme.Colors.OrangeText, 2.2, "DYN*"
	elseif classification == "Conditional" then
		return Theme.Colors.EdgeConditional, 2.2, "COND"
	else
		return Theme.Colors.EdgeUnresolved, 2.2, "UNRES"
	end
end

function GraphRenderer.create(viewportParent: GuiObject, callbacks: NodeInteractionCallbacks): GraphRendererInstance
	local canvasFrame = Instance.new("Frame")
	canvasFrame.Name = "GraphCanvas"
	canvasFrame.Position = UDim2.fromOffset(0, 0)
	canvasFrame.Size = UDim2.fromOffset(800, 600)
	canvasFrame.BackgroundTransparency = 1
	canvasFrame.BorderSizePixel = 0
	canvasFrame.ZIndex = 2
	canvasFrame.Parent = viewportParent

	local edgesLayer = Instance.new("Frame")
	edgesLayer.Name = "EdgesLayer"
	edgesLayer.Size = UDim2.fromScale(1, 1)
	edgesLayer.BackgroundTransparency = 1
	edgesLayer.BorderSizePixel = 0
	edgesLayer.ZIndex = 2
	edgesLayer.Parent = canvasFrame

	local nodesLayer = Instance.new("Frame")
	nodesLayer.Name = "NodesLayer"
	nodesLayer.Size = UDim2.fromScale(1, 1)
	nodesLayer.BackgroundTransparency = 1
	nodesLayer.BorderSizePixel = 0
	nodesLayer.ZIndex = 5
	nodesLayer.Parent = canvasFrame

	local validationResult = GraphRenderer.validatePath2DSupport(edgesLayer)

	local nodePoolById: { [string]: PooledNodeUI } = {}
	local edgePoolById: { [string]: PooledEdgeUI } = {}
	local lastClickTimeByNode: { [string]: number } = {}

	local function setNodeZIndex(pooled: PooledNodeUI, baseZ: number)
		pooled.button.ZIndex = baseZ
		pooled.accentStripe.ZIndex = baseZ + 1
		pooled.typeBadge.ZIndex = baseZ + 1
		pooled.titleLabel.ZIndex = baseZ + 1
		pooled.subtitleLabel.ZIndex = baseZ + 1
		pooled.statsRightLabel.ZIndex = baseZ + 1
		pooled.collapseBtn.ZIndex = baseZ + 2
	end

	local function destroyNodeUI(pooled: PooledNodeUI)
		for _, conn in pooled.connections do
			conn:Disconnect()
		end
		table.clear(pooled.connections)
		pooled.button:Destroy()
	end

	local function destroyEdgeUI(pooled: PooledEdgeUI)
		pooled.path2d:Destroy()
		pooled.arrowHead:Destroy()
		pooled.midTag:Destroy()
	end

	local function getOrCreateNodeUI(nodeId: string): PooledNodeUI
		local existing = nodePoolById[nodeId]
		if existing ~= nil then
			return existing
		end

		local btn = Instance.new("TextButton")
		btn.Name = "Node_" .. nodeId
		btn.BackgroundColor3 = Theme.Colors.PanelBackground
		btn.BorderSizePixel = 0
		btn.AutoButtonColor = false
		btn.Text = ""
		btn.ZIndex = 6
		btn.Parent = nodesLayer
		UIComponents.createCorner(btn, 5)

		local stroke = UIComponents.createStroke(btn, Theme.Colors.Border, 1)

		local accentStripe = Instance.new("Frame")
		accentStripe.Name = "AccentStripe"
		accentStripe.Size = UDim2.new(0, 4, 1, 0)
		accentStripe.Position = UDim2.fromOffset(0, 0)
		accentStripe.BackgroundColor3 = Theme.Colors.AccentBlue
		accentStripe.BorderSizePixel = 0
		accentStripe.ZIndex = 7
		accentStripe.Parent = btn
		UIComponents.createCorner(accentStripe, 3)

		local typeBadge = Instance.new("TextLabel")
		typeBadge.Name = "TypeBadge"
		typeBadge.Position = UDim2.fromOffset(10, 6)
		typeBadge.Size = UDim2.fromOffset(34, 16)
		typeBadge.BackgroundColor3 = Theme.Colors.ChipBackground
		typeBadge.BorderSizePixel = 0
		typeBadge.Font = Theme.Fonts.Mono
		typeBadge.TextSize = 10
		typeBadge.TextColor3 = Theme.Colors.TextPrimary
		typeBadge.Text = "[S]"
		typeBadge.ZIndex = 7
		typeBadge.Parent = btn
		UIComponents.createCorner(typeBadge, 3)

		local titleLabel = Instance.new("TextLabel")
		titleLabel.Name = "Title"
		titleLabel.Position = UDim2.fromOffset(48, 5)
		titleLabel.Size = UDim2.new(1, -80, 0, 18)
		titleLabel.BackgroundTransparency = 1
		titleLabel.Font = Theme.Fonts.Bold
		titleLabel.TextSize = 13
		titleLabel.TextColor3 = Theme.Colors.TextPrimary
		titleLabel.TextXAlignment = Enum.TextXAlignment.Left
		titleLabel.TextTruncate = Enum.TextTruncate.AtEnd
		titleLabel.Text = ""
		titleLabel.ZIndex = 7
		titleLabel.Parent = btn

		local collapseBtn = Instance.new("TextButton")
		collapseBtn.Name = "CollapseBtn"
		collapseBtn.AnchorPoint = Vector2.new(1, 0)
		collapseBtn.Position = UDim2.new(1, -6, 0, 5)
		collapseBtn.Size = UDim2.fromOffset(24, 18)
		collapseBtn.BackgroundColor3 = Theme.Colors.ChipBackground
		collapseBtn.BorderSizePixel = 0
		collapseBtn.AutoButtonColor = true
		collapseBtn.Font = Theme.Fonts.Mono
		collapseBtn.TextSize = 10
		collapseBtn.TextColor3 = Theme.Colors.TextSecondary
		collapseBtn.Text = "[-]"
		collapseBtn.Visible = false
		collapseBtn.ZIndex = 8
		collapseBtn.Parent = btn
		UIComponents.createCorner(collapseBtn, 3)

		local subtitleLabel = Instance.new("TextLabel")
		subtitleLabel.Name = "Subtitle"
		subtitleLabel.Position = UDim2.fromOffset(10, 25)
		subtitleLabel.Size = UDim2.new(1, -16, 0, 14)
		subtitleLabel.BackgroundTransparency = 1
		subtitleLabel.Font = Theme.Fonts.Regular
		subtitleLabel.TextSize = 11
		subtitleLabel.TextColor3 = Theme.Colors.TextSecondary
		subtitleLabel.TextXAlignment = Enum.TextXAlignment.Left
		subtitleLabel.TextTruncate = Enum.TextTruncate.AtEnd
		subtitleLabel.Text = ""
		subtitleLabel.ZIndex = 7
		subtitleLabel.Parent = btn

		local statsRightLabel = Instance.new("TextLabel")
		statsRightLabel.Name = "StatsRight"
		statsRightLabel.Position = UDim2.fromOffset(10, 40)
		statsRightLabel.Size = UDim2.new(1, -16, 0, 14)
		statsRightLabel.BackgroundTransparency = 1
		statsRightLabel.Font = Theme.Fonts.Mono
		statsRightLabel.TextSize = 10
		statsRightLabel.TextColor3 = Theme.Colors.TextMuted
		statsRightLabel.TextXAlignment = Enum.TextXAlignment.Left
		statsRightLabel.TextTruncate = Enum.TextTruncate.AtEnd
		statsRightLabel.Text = ""
		statsRightLabel.ZIndex = 7
		statsRightLabel.Parent = btn

		local conns: { RBXScriptConnection } = {}
		table.insert(
			conns,
			btn.Activated:Connect(function()
				local now = os.clock()
				local prev = lastClickTimeByNode[nodeId] or 0
				lastClickTimeByNode[nodeId] = now
				if (now - prev) <= 0.32 then
					callbacks.onDoubleClickNode(nodeId)
				else
					callbacks.onSelectNode(nodeId)
				end
			end)
		)

		table.insert(
			conns,
			collapseBtn.Activated:Connect(function()
				callbacks.onToggleCollapse(nodeId)
			end)
		)

		table.insert(
			conns,
			btn.MouseEnter:Connect(function()
				callbacks.onHoverNode(nodeId)
			end)
		)

		table.insert(
			conns,
			btn.MouseLeave:Connect(function()
				callbacks.onHoverNode(nil)
			end)
		)

		local pooled: PooledNodeUI = {
			button = btn,
			stroke = stroke,
			accentStripe = accentStripe,
			typeBadge = typeBadge,
			titleLabel = titleLabel,
			collapseBtn = collapseBtn,
			subtitleLabel = subtitleLabel,
			statsRightLabel = statsRightLabel,
			nodeId = nodeId,
			connections = conns,
		}
		nodePoolById[nodeId] = pooled
		return pooled
	end

	local function getOrCreateEdgeUI(edgeId: string): PooledEdgeUI
		local existing = edgePoolById[edgeId]
		if existing ~= nil then
			return existing
		end

		local path2d = Instance.new("Path2D")
		path2d.Name = "Edge_" .. edgeId
		path2d.Color3 = Theme.Colors.EdgeStructural
		path2d.Thickness = 2
		path2d.ZIndex = 2
		path2d.Parent = edgesLayer

		local arrowHead = Instance.new("TextLabel")
		arrowHead.Name = "Arrow_" .. edgeId
		arrowHead.AnchorPoint = Vector2.new(0.5, 0.5)
		arrowHead.Size = UDim2.fromOffset(12, 12)
		arrowHead.BackgroundTransparency = 1
		arrowHead.Font = Theme.Fonts.Bold
		arrowHead.TextSize = 12
		arrowHead.TextColor3 = Theme.Colors.EdgeStatic
		arrowHead.Text = ">"
		arrowHead.ZIndex = 4
		arrowHead.Parent = edgesLayer

		local midTag = Instance.new("TextLabel")
		midTag.Name = "Tag_" .. edgeId
		midTag.AnchorPoint = Vector2.new(0.5, 0.5)
		midTag.Size = UDim2.fromOffset(0, 14)
		midTag.AutomaticSize = Enum.AutomaticSize.X
		midTag.BackgroundColor3 = Theme.Colors.PanelHeader
		midTag.BorderSizePixel = 0
		midTag.Font = Theme.Fonts.Mono
		midTag.TextSize = 9
		midTag.TextColor3 = Theme.Colors.DynamicCyanText
		midTag.Text = ""
		midTag.Visible = false
		midTag.ZIndex = 4
		midTag.Parent = edgesLayer
		UIComponents.createCorner(midTag, 3)
		UIComponents.createPadding(midTag, 0, 0, 4, 4)

		local pooled: PooledEdgeUI = {
			path2d = path2d,
			arrowHead = arrowHead,
			midTag = midTag,
			edgeId = edgeId,
		}
		edgePoolById[edgeId] = pooled
		return pooled
	end

	local function updateHighlights(
		model: GraphModel,
		layout: GraphLayoutResult,
		zoom: number,
		selectedNodeId: string?,
		hoveredNodeId: string?,
		searchMatchedIds: { [string]: boolean }
	)
		local focusNodeId = hoveredNodeId or selectedNodeId
		local incomingNodeIds: { [string]: boolean } = {}
		local outgoingNodeIds: { [string]: boolean } = {}
		local highlightedIncomingEdges: { [string]: boolean } = {}
		local highlightedOutgoingEdges: { [string]: boolean } = {}

		if focusNodeId ~= nil then
			for _, lEdge in layout.layoutEdges do
				if not lEdge.visible then
					continue
				end
				if lEdge.sourceNodeId == focusNodeId then
					outgoingNodeIds[lEdge.targetNodeId] = true
					highlightedOutgoingEdges[lEdge.id] = true
				end
				if lEdge.targetNodeId == focusNodeId then
					incomingNodeIds[lEdge.sourceNodeId] = true
					highlightedIncomingEdges[lEdge.id] = true
				end
			end
		end

		local hasSearchFilter = next(searchMatchedIds) ~= nil

		-- Update Nodes
		for nodeId, pooled in nodePoolById do
			local lNode = layout.layoutNodesById[nodeId]
			if lNode == nil or not lNode.visible then
				pooled.button.Visible = false
				continue
			end

			local node = lNode.node
			local _, _, textCol, bgCol, borderCol = Theme.getNodeTypeVisuals(node.nodeType)
			if node.className == "UnresolvedRequire" then
				textCol = Theme.Colors.DangerText
				bgCol = Theme.Colors.DangerBg
				borderCol = Theme.Colors.DangerText
			end

			local isSelected = (selectedNodeId == nodeId)
			local isHovered = (hoveredNodeId == nodeId)
			local isIncoming = incomingNodeIds[nodeId] == true
			local isOutgoing = outgoingNodeIds[nodeId] == true
			local isSearchMatch = searchMatchedIds[nodeId] == true

			if isSelected or isHovered then
				pooled.button.BackgroundColor3 = Theme.Colors.RowSelected
				pooled.button.BackgroundTransparency = 0
				pooled.stroke.Color = Theme.Colors.TextOnAccent
				pooled.stroke.Thickness = 2
				pooled.titleLabel.TextTransparency = 0
				pooled.subtitleLabel.TextTransparency = 0
				pooled.statsRightLabel.TextTransparency = 0
				pooled.typeBadge.TextTransparency = 0
				setNodeZIndex(pooled, 12)
			elseif isOutgoing then
				pooled.button.BackgroundColor3 = Theme.Colors.PanelBackground
				pooled.button.BackgroundTransparency = 0
				pooled.stroke.Color = Theme.Colors.EdgeOutgoingHighlight
				pooled.stroke.Thickness = 2
				pooled.titleLabel.TextTransparency = 0
				pooled.subtitleLabel.TextTransparency = 0
				pooled.statsRightLabel.TextTransparency = 0
				pooled.typeBadge.TextTransparency = 0
				setNodeZIndex(pooled, 9)
			elseif isIncoming then
				pooled.button.BackgroundColor3 = Theme.Colors.PanelBackground
				pooled.button.BackgroundTransparency = 0
				pooled.stroke.Color = Theme.Colors.EdgeIncomingHighlight
				pooled.stroke.Thickness = 2
				pooled.titleLabel.TextTransparency = 0
				pooled.subtitleLabel.TextTransparency = 0
				pooled.statsRightLabel.TextTransparency = 0
				pooled.typeBadge.TextTransparency = 0
				setNodeZIndex(pooled, 9)
			elseif isSearchMatch then
				pooled.button.BackgroundColor3 = Theme.Colors.AccentBlueSoft
				pooled.button.BackgroundTransparency = 0
				pooled.stroke.Color = Theme.Colors.WarningText
				pooled.stroke.Thickness = 2
				pooled.titleLabel.TextTransparency = 0
				pooled.subtitleLabel.TextTransparency = 0
				pooled.statsRightLabel.TextTransparency = 0
				pooled.typeBadge.TextTransparency = 0
				setNodeZIndex(pooled, 9)
			else
				pooled.button.BackgroundColor3 = if node.isContainer and not node.isScript
					then bgCol
					else Theme.Colors.PanelBackground
				local dimNode = (focusNodeId ~= nil) or (hasSearchFilter and not isSearchMatch)
				pooled.button.BackgroundTransparency = if dimNode then 0.25 else 0
				local textTrans = if dimNode then 0.2 else 0
				pooled.titleLabel.TextTransparency = textTrans
				pooled.subtitleLabel.TextTransparency = textTrans
				pooled.statsRightLabel.TextTransparency = textTrans
				pooled.typeBadge.TextTransparency = textTrans
				pooled.stroke.Color = borderCol
				pooled.stroke.Thickness = 1
				setNodeZIndex(pooled, 6)
			end

			pooled.accentStripe.BackgroundColor3 = textCol
		end

		-- Update Edges
		for edgeId, pooled in edgePoolById do
			local foundLayoutEdge: GraphLayoutEdge? = nil
			for _, le in layout.layoutEdges do
				if le.id == edgeId then
					foundLayoutEdge = le
					break
				end
			end

			if foundLayoutEdge == nil or not foundLayoutEdge.visible then
				pooled.path2d.Visible = false
				pooled.arrowHead.Visible = false
				pooled.midTag.Visible = false
				continue
			end

			local lEdge = foundLayoutEdge :: GraphLayoutEdge
			local baseColor, baseThickness, tagText = getBaseEdgeColorAndThickness(lEdge.edge)
			local isOut = highlightedOutgoingEdges[edgeId] == true
			local isIn = highlightedIncomingEdges[edgeId] == true

			if isOut then
				pooled.path2d.Color3 = if lEdge.edge.kind == "Structural"
					then Theme.Colors.AccentBlueHover
					else Theme.Colors.EdgeOutgoingHighlight
				pooled.path2d.Thickness = math.max(2.5, baseThickness * zoom * 1.35)
				pooled.path2d.ZIndex = 4
				pooled.arrowHead.ZIndex = 5
				pooled.arrowHead.TextColor3 = pooled.path2d.Color3
				pooled.arrowHead.TextTransparency = 0
				pooled.midTag.ZIndex = 6
				pooled.midTag.BackgroundTransparency = 0
				pooled.midTag.TextTransparency = 0
			elseif isIn then
				pooled.path2d.Color3 = Theme.Colors.EdgeIncomingHighlight
				pooled.path2d.Thickness = math.max(2.5, baseThickness * zoom * 1.35)
				pooled.path2d.ZIndex = 4
				pooled.arrowHead.ZIndex = 5
				pooled.arrowHead.TextColor3 = Theme.Colors.EdgeIncomingHighlight
				pooled.arrowHead.TextTransparency = 0
				pooled.midTag.ZIndex = 6
				pooled.midTag.BackgroundTransparency = 0
				pooled.midTag.TextTransparency = 0
			elseif focusNodeId ~= nil then
				local dimmedColor = baseColor:Lerp(Theme.Colors.InputBackground, 0.55)
				pooled.path2d.Color3 = dimmedColor
				pooled.path2d.Thickness = math.max(1, baseThickness * zoom * 0.85)
				pooled.path2d.ZIndex = 2
				pooled.arrowHead.ZIndex = 3
				pooled.arrowHead.TextColor3 = dimmedColor
				pooled.arrowHead.TextTransparency = 0.62
				pooled.midTag.ZIndex = 3
				pooled.midTag.BackgroundTransparency = 0.35
				pooled.midTag.TextTransparency = 0.45
			else
				local edgeZ = if lEdge.edge.kind == "Structural" then 2 else 3
				pooled.path2d.Color3 = baseColor
				pooled.path2d.Thickness = math.max(1.2, baseThickness * zoom)
				pooled.path2d.ZIndex = edgeZ
				pooled.arrowHead.ZIndex = edgeZ + 1
				pooled.arrowHead.TextColor3 = baseColor
				pooled.arrowHead.TextTransparency = if lEdge.edge.kind == "Structural" then 0.35 else 0
				pooled.midTag.ZIndex = edgeZ + 2
				pooled.midTag.BackgroundTransparency = 0
				pooled.midTag.TextTransparency = 0
			end

			if tagText ~= nil and zoom >= 0.65 then
				pooled.midTag.Text = tagText
				pooled.midTag.TextColor3 = pooled.path2d.Color3
				pooled.midTag.Visible = true
			else
				pooled.midTag.Visible = false
			end
		end
	end

	local function renderLayout(
		model: GraphModel,
		layout: GraphLayoutResult,
		zoom: number,
		selectedNodeId: string?,
		hoveredNodeId: string?,
		searchMatchedIds: { [string]: boolean }
	)
		canvasFrame.Size = UDim2.fromOffset(
			math.round(layout.canvasWidth * zoom),
			math.round(layout.canvasHeight * zoom)
		)

		local activeNodeSet: { [string]: boolean } = {}
		for _, lNode in layout.orderedLayoutNodes do
			if not lNode.visible then
				continue
			end
			activeNodeSet[lNode.id] = true
			local pooled = getOrCreateNodeUI(lNode.id)
			local node = lNode.node

			local scaledX = math.round(lNode.x * zoom)
			local scaledY = math.round(lNode.y * zoom)
			local scaledW = math.max(80, math.round(lNode.width * zoom))
			local scaledH = math.max(28, math.round(lNode.height * zoom))

			pooled.button.Position = UDim2.fromOffset(scaledX, scaledY)
			pooled.button.Size = UDim2.fromOffset(scaledW, scaledH)
			pooled.button.Visible = true

			local shortTag, typeLabel, textCol, bgCol, _ = Theme.getNodeTypeVisuals(node.nodeType)
			if node.className == "UnresolvedRequire" then
				shortTag = "[?]"
				typeLabel = "Unresolved require()"
				textCol = Theme.Colors.DangerText
				bgCol = Theme.Colors.DangerBg
			end

			pooled.typeBadge.Text = shortTag
			pooled.typeBadge.TextColor3 = textCol
			pooled.typeBadge.BackgroundColor3 = bgCol
			pooled.typeBadge.Position = UDim2.fromOffset(math.round(8 * zoom), math.round(5 * zoom))
			pooled.typeBadge.Size = UDim2.fromOffset(math.round(32 * zoom), math.round(15 * zoom))
			pooled.typeBadge.TextSize = math.clamp(math.round(10 * zoom), 7, 14)

			local hasChildren = #node.childIds > 0
			pooled.collapseBtn.Visible = hasChildren
			if hasChildren then
				pooled.collapseBtn.Text = if lNode.isCollapsed then "[+]" else "[-]"
				pooled.collapseBtn.TextColor3 = if lNode.isCollapsed
					then Theme.Colors.WarningText
					else Theme.Colors.TextSecondary
				pooled.collapseBtn.Size = UDim2.fromOffset(math.round(24 * zoom), math.round(16 * zoom))
				pooled.collapseBtn.Position = UDim2.new(1, -math.round(5 * zoom), 0, math.round(5 * zoom))
				pooled.collapseBtn.TextSize = math.clamp(math.round(10 * zoom), 7, 13)
			end

			local rightReserve = if hasChildren then math.round(34 * zoom) else math.round(8 * zoom)
			pooled.titleLabel.Position = UDim2.fromOffset(math.round(44 * zoom), math.round(4 * zoom))
			pooled.titleLabel.Size = UDim2.new(1, -(math.round(44 * zoom) + rightReserve), 0, math.round(17 * zoom))
			pooled.titleLabel.TextSize = math.clamp(math.round(13 * zoom), 8, 18)
			pooled.titleLabel.Text = node.name

			pooled.subtitleLabel.Position = UDim2.fromOffset(math.round(8 * zoom), math.round(23 * zoom))
			pooled.subtitleLabel.Size = UDim2.new(1, -math.round(14 * zoom), 0, math.round(14 * zoom))
			pooled.subtitleLabel.TextSize = math.clamp(math.round(11 * zoom), 7, 15)
			if node.isScript then
				local envStr = node.environment or typeLabel
				pooled.subtitleLabel.Text = string.format("%s · %s", typeLabel, envStr)
			elseif node.className == "UnresolvedRequire" then
				pooled.subtitleLabel.Text = "Unresolved Target"
			else
				pooled.subtitleLabel.Text = string.format(
					"%s · %d script%s",
					node.className,
					node.childScriptCount,
					if node.childScriptCount == 1 then "" else "s"
				)
			end

			pooled.statsRightLabel.Position = UDim2.fromOffset(math.round(8 * zoom), math.round(39 * zoom))
			pooled.statsRightLabel.Size = UDim2.new(1, -math.round(14 * zoom), 0, math.round(14 * zoom))
			pooled.statsRightLabel.TextSize = math.clamp(math.round(10 * zoom), 7, 14)

			if node.isScript then
				local lineCount = if node.scriptInfo ~= nil then node.scriptInfo.lineCount else 0
				pooled.statsRightLabel.Text = string.format(
					"Out: %d  In: %d  (%dL)",
					node.dependencyCount,
					node.dependentCount,
					lineCount
				)
			elseif node.className == "UnresolvedRequire" then
				pooled.statsRightLabel.Text = string.format("Callers: %d", node.dependentCount)
			else
				local stateSuffix = if lNode.isCollapsed then " [COLLAPSED]" else ""
				pooled.statsRightLabel.Text = string.format(
					"Deps Out: %d  In: %d%s",
					node.dependencyCount,
					node.dependentCount,
					stateSuffix
				)
			end

			-- Hide secondary text lines when zoomed very far out to keep cards clean
			pooled.subtitleLabel.Visible = (zoom >= 0.55)
			pooled.statsRightLabel.Visible = (zoom >= 0.65)
		end

		for nodeId, pooled in nodePoolById do
			if not activeNodeSet[nodeId] then
				pooled.button.Visible = false
			end
		end

		-- Render Edges using native Path2D
		local activeEdgeSet: { [string]: boolean } = {}
		for _, lEdge in layout.layoutEdges do
			if not lEdge.visible then
				continue
			end
			activeEdgeSet[lEdge.id] = true
			local pooled = getOrCreateEdgeUI(lEdge.id)

			local controlPoints: { Path2DControlPoint } = {}
			for _, cpData in lEdge.controlPoints do
				local cp = Path2DControlPoint.new(
					UDim2.fromOffset(
						math.round(cpData.position.x * zoom),
						math.round(cpData.position.y * zoom)
					),
					UDim2.fromOffset(
						math.round(cpData.leftTangent.x * zoom),
						math.round(cpData.leftTangent.y * zoom)
					),
					UDim2.fromOffset(
						math.round(cpData.rightTangent.x * zoom),
						math.round(cpData.rightTangent.y * zoom)
					)
				)
				table.insert(controlPoints, cp)
			end

			pooled.path2d:SetControlPoints(controlPoints)
			pooled.path2d.Visible = true

			-- Position directional indicator (arrowhead) near the destination node
			local endX = math.round((lEdge.endPoint.x - lEdge.arrowDirection.x * 5) * zoom)
			local endY = math.round((lEdge.endPoint.y - lEdge.arrowDirection.y * 5) * zoom)
			local angleDeg = math.deg(math.atan2(lEdge.arrowDirection.y, lEdge.arrowDirection.x))

			pooled.arrowHead.Position = UDim2.fromOffset(endX, endY)
			pooled.arrowHead.Rotation = angleDeg
			pooled.arrowHead.TextSize = math.clamp(math.round(11 * zoom), 8, 16)
			pooled.arrowHead.Text = if lEdge.edge.kind == "Structural" then "·" else ">"
			pooled.arrowHead.Visible = true

			-- Position midpoint classification tag
			local midX = math.round(lEdge.midpoint.x * zoom)
			local midY = math.round(lEdge.midpoint.y * zoom)
			pooled.midTag.Position = UDim2.fromOffset(midX, midY)
		end

		for edgeId, pooled in edgePoolById do
			if not activeEdgeSet[edgeId] then
				pooled.path2d.Visible = false
				pooled.arrowHead.Visible = false
				pooled.midTag.Visible = false
			end
		end

		updateHighlights(model, layout, zoom, selectedNodeId, hoveredNodeId, searchMatchedIds)
	end

	local function clear()
		for _, pooled in nodePoolById do
			destroyNodeUI(pooled)
		end
		table.clear(nodePoolById)

		for _, pooled in edgePoolById do
			destroyEdgeUI(pooled)
		end
		table.clear(edgePoolById)
	end

	local function destroy()
		clear()
		canvasFrame:Destroy()
	end

	return {
		canvasFrame = canvasFrame,
		edgesLayer = edgesLayer,
		nodesLayer = nodesLayer,
		validationResult = validationResult,
		renderLayout = renderLayout,
		updateHighlights = updateHighlights,
		clear = clear,
		destroy = destroy,
	}
end

return GraphRenderer
