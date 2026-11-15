--!strict
--[[
	GraphLayout.luau
	Responsibility: Deterministic hierarchical + dependency-aware layout engine.
	Calculates node positions, layers, spacing, and Path2D cubic Bezier control
	points and tangent vectors completely independently of UI instances.
]]

local Types = require("./Types")

type GraphModel = Types.GraphModel
type GraphNode = Types.GraphNode
type GraphEdge = Types.GraphEdge
type GraphPoint2D = Types.GraphPoint2D
type GraphControlPointData = Types.GraphControlPointData
type GraphLayoutNode = Types.GraphLayoutNode
type GraphLayoutEdge = Types.GraphLayoutEdge
type GraphLayoutResult = Types.GraphLayoutResult
type GraphFilterState = Types.GraphFilterState

local GraphLayout = {}

GraphLayout.Config = {
	NodeWidth = 216,
	NodeHeight = 58,
	LayerGapX = 116,
	NodeGapY = 18,
	ServiceClusterGapY = 30,
	CanvasPaddingX = 48,
	CanvasPaddingY = 48,
	MaxPortSpread = 34,
}

local SERVICE_PRIORITY: { [string]: number } = {
	ReplicatedFirst = 1,
	ServerScriptService = 2,
	ServerStorage = 3,
	ReplicatedStorage = 4,
	StarterPlayer = 5,
	StarterGui = 6,
	StarterPack = 7,
	Workspace = 8,
	Lighting = 9,
	SoundService = 10,
	Chat = 11,
	TextChatService = 12,
	TestService = 13,
}

local function getServicePriority(serviceName: string): number
	return SERVICE_PRIORITY[serviceName] or 50
end

local function isNodeTypeEnabled(node: GraphNode, filters: GraphFilterState): boolean
	if node.className == "UnresolvedRequire" then
		return filters.showDependencyEdges and filters.showModuleScripts
	end
	if not node.isScript then
		return filters.showContainers
	end
	if node.nodeType == "Script" then
		return filters.showScripts
	elseif node.nodeType == "LocalScript" then
		return filters.showLocalScripts
	elseif node.nodeType == "ModuleScript" then
		return filters.showModuleScripts
	else
		return filters.showContainers
	end
end

-- Returns the nearest collapsed ancestor ID if the node is hidden inside a collapsed container
local function findCollapsedAncestorId(
	node: GraphNode,
	nodesById: { [string]: GraphNode },
	collapsedContainers: { [string]: boolean }
): string?
	local highestCollapsed: string? = nil
	local currId = node.parentId
	while currId ~= nil do
		local anc = nodesById[currId]
		if anc == nil then
			break
		end
		if collapsedContainers[currId] == true then
			highestCollapsed = currId
		end
		currId = anc.parentId
	end
	return highestCollapsed
end

local function evaluateCubicBezier(
	p0: GraphPoint2D,
	p1: GraphPoint2D,
	p2: GraphPoint2D,
	p3: GraphPoint2D,
	t: number
): GraphPoint2D
	local u = 1 - t
	local tt = t * t
	local uu = u * u
	local uuu = uu * u
	local ttt = tt * t
	return {
		x = uuu * p0.x + 3 * uu * t * p1.x + 3 * u * tt * p2.x + ttt * p3.x,
		y = uuu * p0.y + 3 * uu * t * p1.y + 3 * u * tt * p2.y + ttt * p3.y,
	}
end

local function normalizeVector(dx: number, dy: number): GraphPoint2D
	local len = math.sqrt(dx * dx + dy * dy)
	if len < 0.0001 then
		return { x = 1, y = 0 }
	end
	return { x = dx / len, y = dy / len }
end

function GraphLayout.createDefaultFilters(): GraphFilterState
	return {
		showContainers = true,
		showScripts = true,
		showLocalScripts = true,
		showModuleScripts = true,
		showStructuralEdges = true,
		showDependencyEdges = true,
		showDynamicDependencies = true,
		searchQuery = "",
	}
end

function GraphLayout.computeLayout(
	model: GraphModel,
	filters: GraphFilterState,
	collapsedContainers: { [string]: boolean }
): GraphLayoutResult
	local cfg = GraphLayout.Config
	local layoutNodesById: { [string]: GraphLayoutNode } = {}
	local orderedLayoutNodes: { GraphLayoutNode } = {}
	local visibleNodes: { GraphNode } = {}
	local visibleSet: { [string]: boolean } = {}
	local effectiveTargetMap: { [string]: string } = {}

	-- 1. Determine node visibility and collapsed container redirection
	for _, node in model.orderedNodes do
		local collapsedAncId = findCollapsedAncestorId(node, model.nodesById, collapsedContainers)
		if collapsedAncId ~= nil then
			effectiveTargetMap[node.id] = collapsedAncId
			local hiddenLayout: GraphLayoutNode = {
				id = node.id,
				node = node,
				x = 0,
				y = 0,
				width = cfg.NodeWidth,
				height = cfg.NodeHeight,
				layer = node.depth,
				orderInLayer = 1,
				isCollapsed = collapsedContainers[node.id] == true,
				visible = false,
			}
			layoutNodesById[node.id] = hiddenLayout
		elseif isNodeTypeEnabled(node, filters) then
			effectiveTargetMap[node.id] = node.id
			visibleSet[node.id] = true
			table.insert(visibleNodes, node)
		else
			local hiddenLayout: GraphLayoutNode = {
				id = node.id,
				node = node,
				x = 0,
				y = 0,
				width = cfg.NodeWidth,
				height = cfg.NodeHeight,
				layer = node.depth,
				orderInLayer = 1,
				isCollapsed = collapsedContainers[node.id] == true,
				visible = false,
			}
			layoutNodesById[node.id] = hiddenLayout
		end
	end

	-- 2. Assign horizontal layer index for each visible node
	local nodeLayer: { [string]: number } = {}
	if filters.showContainers then
		-- Base layer is structural depth
		for _, node in visibleNodes do
			nodeLayer[node.id] = math.max(1, node.depth)
		end
		-- Nudge dependent modules one layer to the right when required by a script in the same or deeper layer
		if filters.showDependencyEdges then
			for _ = 1, 2 do
				for _, edge in model.dependencyEdges do
					if edge.isDynamic and not filters.showDynamicDependencies then
						continue
					end
					local srcId = effectiveTargetMap[edge.sourceNodeId]
					local tgtId = effectiveTargetMap[edge.targetNodeId]
					if srcId ~= nil and tgtId ~= nil and srcId ~= tgtId and visibleSet[srcId] and visibleSet[tgtId] then
						local srcNode = model.nodesById[srcId]
						local tgtNode = model.nodesById[tgtId]
						if srcNode ~= nil and tgtNode ~= nil and not tgtNode.isContainer then
							local sLayer = nodeLayer[srcId] or srcNode.depth
							local tLayer = nodeLayer[tgtId] or tgtNode.depth
							local maxAllowedLayer = tgtNode.depth + 2
							if tLayer <= sLayer and sLayer + 1 <= maxAllowedLayer then
								nodeLayer[tgtId] = sLayer + 1
							end
						end
					end
				end
			end
		end
	else
		-- Pure Dependency Graph Mode (Containers hidden): layer by dependency topological depth
		for _, node in visibleNodes do
			nodeLayer[node.id] = 1
		end
		for _ = 1, 5 do
			for _, edge in model.dependencyEdges do
				if edge.isDynamic and not filters.showDynamicDependencies then
					continue
				end
				local srcId = effectiveTargetMap[edge.sourceNodeId]
				local tgtId = effectiveTargetMap[edge.targetNodeId]
				if srcId ~= nil and tgtId ~= nil and srcId ~= tgtId and visibleSet[srcId] and visibleSet[tgtId] then
					local sLayer = nodeLayer[srcId] or 1
					local tLayer = nodeLayer[tgtId] or 1
					if tLayer <= sLayer and sLayer < 8 then
						nodeLayer[tgtId] = sLayer + 1
					end
				end
			end
		end
	end

	-- Normalize layers so they are contiguous 1..maxLayer
	local usedLayerNumbers: { number } = {}
	local usedLayerSet: { [number]: boolean } = {}
	for _, node in visibleNodes do
		local l = nodeLayer[node.id] or 1
		if not usedLayerSet[l] then
			usedLayerSet[l] = true
			table.insert(usedLayerNumbers, l)
		end
	end
	table.sort(usedLayerNumbers)
	local layerRemap: { [number]: number } = {}
	for idx, rawLayer in usedLayerNumbers do
		layerRemap[rawLayer] = idx
	end

	local layers: { [number]: { GraphNode } } = {}
	local maxLayer = #usedLayerNumbers
	for i = 1, maxLayer do
		layers[i] = {}
	end
	for _, node in visibleNodes do
		local mapped = layerRemap[nodeLayer[node.id] or 1] or 1
		nodeLayer[node.id] = mapped
		table.insert(layers[mapped], node)
	end

	-- 3. Order nodes vertically within each layer using Service priority + parent order + fullPath
	local assignedOrder: { [string]: number } = {}
	for layerIdx = 1, maxLayer do
		local bucket = layers[layerIdx]
		table.sort(bucket, function(a: GraphNode, b: GraphNode): boolean
			local prioA = getServicePriority(a.serviceName)
			local prioB = getServicePriority(b.serviceName)
			if prioA ~= prioB then
				return prioA < prioB
			end
			if a.serviceName ~= b.serviceName then
				return a.serviceName < b.serviceName
			end
			local pOrderA = if a.parentId ~= nil and assignedOrder[a.parentId] ~= nil then assignedOrder[a.parentId] else 9999
			local pOrderB = if b.parentId ~= nil and assignedOrder[b.parentId] ~= nil then assignedOrder[b.parentId] else 9999
			if pOrderA ~= pOrderB then
				return pOrderA < pOrderB
			end
			if a.isContainer ~= b.isContainer then
				return a.isContainer
			end
			return a.fullPath < b.fullPath
		end)

		for orderIdx, node in bucket do
			assignedOrder[node.id] = orderIdx
		end
	end

	-- 4. Compute exact (x, y) coordinates per layer
	local maxCanvasX = cfg.CanvasPaddingX * 2 + cfg.NodeWidth
	local maxCanvasY = cfg.CanvasPaddingY * 2 + cfg.NodeHeight

	for layerIdx = 1, maxLayer do
		local bucket = layers[layerIdx]
		local colX = cfg.CanvasPaddingX + (layerIdx - 1) * (cfg.NodeWidth + cfg.LayerGapX)
		local cursorY = cfg.CanvasPaddingY
		local prevService: string? = nil

		for orderIdx, node in bucket do
			if prevService ~= nil and prevService ~= node.serviceName then
				cursorY += cfg.ServiceClusterGapY
			end
			prevService = node.serviceName

			local layoutNode: GraphLayoutNode = {
				id = node.id,
				node = node,
				x = colX,
				y = cursorY,
				width = cfg.NodeWidth,
				height = cfg.NodeHeight,
				layer = layerIdx,
				orderInLayer = orderIdx,
				isCollapsed = collapsedContainers[node.id] == true,
				visible = true,
			}
			layoutNodesById[node.id] = layoutNode
			table.insert(orderedLayoutNodes, layoutNode)

			local rightEdge = colX + cfg.NodeWidth + cfg.CanvasPaddingX
			local bottomEdge = cursorY + cfg.NodeHeight + cfg.CanvasPaddingY
			if rightEdge > maxCanvasX then
				maxCanvasX = rightEdge
			end
			if bottomEdge > maxCanvasY then
				maxCanvasY = bottomEdge
			end

			cursorY += cfg.NodeHeight + cfg.NodeGapY
		end
	end

	-- 5. Collect visible edges and compute distributed port offsets
	local candidateEdges: { { edge: GraphEdge, srcId: string, tgtId: string } } = {}
	local renderedEdgeDedup: { [string]: boolean } = {}

	local function considerEdge(edge: GraphEdge)
		local srcId: string? = effectiveTargetMap[edge.sourceNodeId]
		local tgtId: string? = effectiveTargetMap[edge.targetNodeId]
		if srcId == nil or tgtId == nil or srcId == tgtId then
			return
		end
		if not visibleSet[srcId] or not visibleSet[tgtId] then
			return
		end
		local dedupKey = edge.kind .. ":" .. srcId .. "->" .. tgtId
		if renderedEdgeDedup[dedupKey] then
			return
		end
		renderedEdgeDedup[dedupKey] = true
		table.insert(candidateEdges, {
			edge = edge,
			srcId = srcId,
			tgtId = tgtId,
		})
	end

	if filters.showStructuralEdges and filters.showContainers then
		for _, edge in model.structuralEdges do
			considerEdge(edge)
		end
	end

	if filters.showDependencyEdges then
		for _, edge in model.dependencyEdges do
			if edge.isDynamic and not filters.showDynamicDependencies then
				continue
			end
			considerEdge(edge)
		end
	end

	-- Group outgoing and incoming ports per node to distribute attachment Y coordinates cleanly
	local outgoingByNode: { [string]: { number } } = {}
	local incomingByNode: { [string]: { number } } = {}
	for idx, item in candidateEdges do
		if outgoingByNode[item.srcId] == nil then
			outgoingByNode[item.srcId] = {}
		end
		table.insert(outgoingByNode[item.srcId], idx)

		if incomingByNode[item.tgtId] == nil then
			incomingByNode[item.tgtId] = {}
		end
		table.insert(incomingByNode[item.tgtId], idx)
	end

	for _, list in outgoingByNode do
		table.sort(list, function(aIdx: number, bIdx: number): boolean
			local tgtA = layoutNodesById[candidateEdges[aIdx].tgtId]
			local tgtB = layoutNodesById[candidateEdges[bIdx].tgtId]
			local yA = if tgtA ~= nil then tgtA.y else 0
			local yB = if tgtB ~= nil then tgtB.y else 0
			if yA ~= yB then
				return yA < yB
			end
			return aIdx < bIdx
		end)
	end

	for _, list in incomingByNode do
		table.sort(list, function(aIdx: number, bIdx: number): boolean
			local srcA = layoutNodesById[candidateEdges[aIdx].srcId]
			local srcB = layoutNodesById[candidateEdges[bIdx].srcId]
			local yA = if srcA ~= nil then srcA.y else 0
			local yB = if srcB ~= nil then srcB.y else 0
			if yA ~= yB then
				return yA < yB
			end
			return aIdx < bIdx
		end)
	end

	local outOffsetByEdgeIdx: { [number]: number } = {}
	for _, list in outgoingByNode do
		local count = #list
		for rank, edgeIdx in list do
			if count <= 1 then
				outOffsetByEdgeIdx[edgeIdx] = 0
			else
				local normalized = ((rank - 1) / (count - 1)) - 0.5
				outOffsetByEdgeIdx[edgeIdx] = math.round(normalized * cfg.MaxPortSpread)
			end
		end
	end

	local inOffsetByEdgeIdx: { [number]: number } = {}
	for _, list in incomingByNode do
		local count = #list
		for rank, edgeIdx in list do
			if count <= 1 then
				inOffsetByEdgeIdx[edgeIdx] = 0
			else
				local normalized = ((rank - 1) / (count - 1)) - 0.5
				inOffsetByEdgeIdx[edgeIdx] = math.round(normalized * cfg.MaxPortSpread)
			end
		end
	end

	-- 6. Build GraphLayoutEdge records with Path2D cubic Bezier control points & tangents
	local layoutEdges: { GraphLayoutEdge } = {}
	for edgeIdx, item in candidateEdges do
		local srcLayout = layoutNodesById[item.srcId]
		local tgtLayout = layoutNodesById[item.tgtId]
		if srcLayout == nil or tgtLayout == nil then
			continue
		end

		local srcPortOffset = outOffsetByEdgeIdx[edgeIdx] or 0
		local tgtPortOffset = inOffsetByEdgeIdx[edgeIdx] or 0

		local startPoint: GraphPoint2D
		local endPoint: GraphPoint2D
		local controlPoints: { GraphControlPointData }
		local midpoint: GraphPoint2D
		local arrowDirection: GraphPoint2D

		if tgtLayout.x > srcLayout.x then
			-- Standard forward left-to-right connection
			startPoint = {
				x = srcLayout.x + srcLayout.width,
				y = srcLayout.y + math.round(srcLayout.height * 0.5) + srcPortOffset,
			}
			endPoint = {
				x = tgtLayout.x,
				y = tgtLayout.y + math.round(tgtLayout.height * 0.5) + tgtPortOffset,
			}

			local dx = math.max(math.round((endPoint.x - startPoint.x) * 0.46), 44)
			controlPoints = {
				{
					position = startPoint,
					leftTangent = { x = 0, y = 0 },
					rightTangent = { x = dx, y = 0 },
				},
				{
					position = endPoint,
					leftTangent = { x = -dx, y = 0 },
					rightTangent = { x = 0, y = 0 },
				},
			}

			local handle1 = { x = startPoint.x + dx, y = startPoint.y }
			local handle2 = { x = endPoint.x - dx, y = endPoint.y }
			midpoint = evaluateCubicBezier(startPoint, handle1, handle2, endPoint, 0.5)
			local nearEnd = evaluateCubicBezier(startPoint, handle1, handle2, endPoint, 0.92)
			arrowDirection = normalizeVector(endPoint.x - nearEnd.x, endPoint.y - nearEnd.y)
		elseif tgtLayout.x == srcLayout.x then
			-- Same-column vertical arch on the right side
			startPoint = {
				x = srcLayout.x + srcLayout.width,
				y = srcLayout.y + math.round(srcLayout.height * 0.5) + srcPortOffset,
			}
			endPoint = {
				x = tgtLayout.x + tgtLayout.width,
				y = tgtLayout.y + math.round(tgtLayout.height * 0.5) + tgtPortOffset,
			}
			local archDist = math.clamp(math.abs(endPoint.y - startPoint.y) * 0.42, 42, 96)
			controlPoints = {
				{
					position = startPoint,
					leftTangent = { x = 0, y = 0 },
					rightTangent = { x = archDist, y = 0 },
				},
				{
					position = endPoint,
					leftTangent = { x = archDist, y = 0 },
					rightTangent = { x = 0, y = 0 },
				},
			}
			local handle1 = { x = startPoint.x + archDist, y = startPoint.y }
			local handle2 = { x = endPoint.x + archDist, y = endPoint.y }
			midpoint = evaluateCubicBezier(startPoint, handle1, handle2, endPoint, 0.5)
			arrowDirection = { x = -1, y = 0 }
		else
			-- Backward dependency connection (curves smoothly via an intermediate arch point)
			startPoint = {
				x = srcLayout.x + srcLayout.width,
				y = srcLayout.y + math.round(srcLayout.height * 0.5) + srcPortOffset,
			}
			endPoint = {
				x = tgtLayout.x,
				y = tgtLayout.y + math.round(tgtLayout.height * 0.5) + tgtPortOffset,
			}
			local verticalOffset = if endPoint.y >= startPoint.y then 52 else -52
			local midX = math.round((startPoint.x + endPoint.x) * 0.5)
			local midY = math.round((startPoint.y + endPoint.y) * 0.5) + verticalOffset
			local midPos: GraphPoint2D = { x = midX, y = midY }
			local spanX = math.max(math.round(math.abs(startPoint.x - endPoint.x) * 0.28), 48)

			controlPoints = {
				{
					position = startPoint,
					leftTangent = { x = 0, y = 0 },
					rightTangent = { x = 48, y = verticalOffset * 0.6 },
				},
				{
					position = midPos,
					leftTangent = { x = spanX, y = 0 },
					rightTangent = { x = -spanX, y = 0 },
				},
				{
					position = endPoint,
					leftTangent = { x = -48, y = verticalOffset * 0.6 },
					rightTangent = { x = 0, y = 0 },
				},
			}
			midpoint = midPos
			arrowDirection = { x = 1, y = 0 }
		end

		local layoutEdge: GraphLayoutEdge = {
			id = item.edge.id,
			edge = item.edge,
			sourceNodeId = item.srcId,
			targetNodeId = item.tgtId,
			startPoint = startPoint,
			endPoint = endPoint,
			midpoint = midpoint,
			arrowDirection = arrowDirection,
			controlPoints = controlPoints,
			visible = true,
		}
		table.insert(layoutEdges, layoutEdge)
	end

	return {
		layoutNodesById = layoutNodesById,
		orderedLayoutNodes = orderedLayoutNodes,
		layoutEdges = layoutEdges,
		canvasWidth = maxCanvasX,
		canvasHeight = maxCanvasY,
	}
end

return GraphLayout
