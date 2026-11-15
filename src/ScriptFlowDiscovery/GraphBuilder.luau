--!strict
--[[
	GraphBuilder.luau
	Responsibility: Converts discovered scripts, containers, and analyzed dependencies
	from a ScanReport into a pure, UI-independent GraphModel.
	Does NOT inspect script source code and does NOT create UI instances.
]]

local Types = require("./Types")
local ScriptDiscovery = require("./ScriptDiscovery")

type ScanReport = Types.ScanReport
type DiscoveredScript = Types.DiscoveredScript
type DependencyRecord = Types.DependencyRecord
type GraphNodeType = Types.GraphNodeType
type GraphNode = Types.GraphNode
type GraphEdge = Types.GraphEdge
type GraphModel = Types.GraphModel

local GraphBuilder = {}

local function classifyContainerNodeType(className: string, depth: number): GraphNodeType
	if depth <= 1 then
		return "Service"
	elseif className == "Folder" then
		return "Folder"
	elseif className == "Model" then
		return "Model"
	else
		return "Container"
	end
end

local function splitPathSegments(fullPath: string): { string }
	local segments: { string } = {}
	for part in string.gmatch(fullPath, "[^%.]+") do
		table.insert(segments, part)
	end
	return segments
end

function GraphBuilder.build(report: ScanReport): GraphModel
	local nodesById: { [string]: GraphNode } = {}
	local orderedNodes: { GraphNode } = {}
	local rootNodeIds: { string } = {}
	local rootIdSet: { [string]: boolean } = {}
	local structuralEdges: { GraphEdge } = {}
	local dependencyEdges: { GraphEdge } = {}
	local allEdgesById: { [string]: GraphEdge } = {}
	local structuralEdgeSet: { [string]: boolean } = {}

	local rootInstance = report.options.root

	local function registerRootId(nodeId: string)
		if not rootIdSet[nodeId] then
			rootIdSet[nodeId] = true
			table.insert(rootNodeIds, nodeId)
		end
	end

	local function addChildLink(parentId: string, childId: string)
		local parentNode = nodesById[parentId]
		if parentNode == nil then
			return
		end
		for _, existing in parentNode.childIds do
			if existing == childId then
				return
			end
		end
		table.insert(parentNode.childIds, childId)

		local edgeId = "struct:" .. parentId .. "->" .. childId
		if not structuralEdgeSet[edgeId] then
			structuralEdgeSet[edgeId] = true
			local structEdge: GraphEdge = {
				id = edgeId,
				kind = "Structural",
				sourceNodeId = parentId,
				targetNodeId = childId,
				classification = nil,
				status = nil,
				rawExpression = nil,
				lineNumber = nil,
				columnNumber = nil,
				scopeKind = nil,
				conditionExpression = nil,
				isCircular = false,
				isDynamic = false,
				isConditional = false,
				candidateCount = nil,
				dependencyRecord = nil,
			}
			table.insert(structuralEdges, structEdge)
			allEdgesById[edgeId] = structEdge
			table.insert(parentNode.outgoingEdgeIds, edgeId)
			local childNode = nodesById[childId]
			if childNode ~= nil then
				table.insert(childNode.incomingEdgeIds, edgeId)
			end
		end
	end

	local function ensureContainerChainForScript(scriptInfo: DiscoveredScript): string?
		-- Prefer live Instance ancestry when available and parented under rootInstance
		local inst: Instance = scriptInfo.instance
		local ancestors: { Instance } = {}
		local curr: Instance? = inst.Parent
		while curr ~= nil and curr ~= rootInstance and curr ~= game do
			table.insert(ancestors, 1, curr)
			curr = curr.Parent
		end

		if #ancestors > 0 then
			local prevId: string? = nil
			for depthIndex, anc in ancestors do
				local ancPath = ScriptDiscovery.getCleanFullPath(anc, rootInstance)
				local existing = nodesById[ancPath]
				if existing == nil then
					local serviceName = if depthIndex == 1
						then anc.Name
						else (if prevId ~= nil and nodesById[prevId] ~= nil then nodesById[prevId].serviceName else scriptInfo.serviceName)
					local cType: GraphNodeType = classifyContainerNodeType(anc.ClassName, depthIndex)
					local newNode: GraphNode = {
						id = ancPath,
						name = anc.Name,
						fullPath = ancPath,
						nodeType = cType,
						className = anc.ClassName,
						instance = anc,
						parentId = prevId,
						childIds = {},
						serviceName = serviceName,
						depth = depthIndex,
						isContainer = true,
						isScript = false,
						scriptInfo = nil,
						environment = nil,
						dependencyCount = 0,
						dependentCount = 0,
						childScriptCount = 0,
						outgoingEdgeIds = {},
						incomingEdgeIds = {},
					}
					nodesById[ancPath] = newNode
					table.insert(orderedNodes, newNode)
				end

				if prevId == nil then
					registerRootId(ancPath)
				else
					addChildLink(prevId, ancPath)
				end
				prevId = ancPath
			end
			return prevId
		end

		-- Fallback: reconstruct ancestor chain from fullPath segments (e.g. for synthetic test models)
		local segments = splitPathSegments(scriptInfo.fullPath)
		if #segments <= 1 then
			return nil
		end

		local prevId: string? = nil
		local runningPath = ""
		for depthIndex = 1, #segments - 1 do
			local segName = segments[depthIndex]
			runningPath = if runningPath == "" then segName else (runningPath .. "." .. segName)
			local existing = nodesById[runningPath]
			if existing == nil then
				local inferredClass = if depthIndex == 1
					then segName
					elseif depthIndex == #segments - 1 and scriptInfo.parentClassName ~= "" and scriptInfo.parentClassName ~= "DataModel"
					then scriptInfo.parentClassName
					else "Folder"
				local cType: GraphNodeType = classifyContainerNodeType(inferredClass, depthIndex)
				local newNode: GraphNode = {
					id = runningPath,
					name = segName,
					fullPath = runningPath,
					nodeType = cType,
					className = inferredClass,
					instance = if depthIndex == #segments - 1 then scriptInfo.parent else nil,
					parentId = prevId,
					childIds = {},
					serviceName = segments[1],
					depth = depthIndex,
					isContainer = true,
					isScript = false,
					scriptInfo = nil,
					environment = nil,
					dependencyCount = 0,
					dependentCount = 0,
					childScriptCount = 0,
					outgoingEdgeIds = {},
					incomingEdgeIds = {},
				}
				nodesById[runningPath] = newNode
				table.insert(orderedNodes, newNode)
			end

			if prevId == nil then
				registerRootId(runningPath)
			else
				addChildLink(prevId, runningPath)
			end
			prevId = runningPath
		end

		return prevId
	end

	-- 1. Create container & script nodes for all discovered scripts
	for _, scriptInfo in report.scripts do
		local parentId = ensureContainerChainForScript(scriptInfo)
		local parentNode = if parentId ~= nil then nodesById[parentId] else nil
		local depth = if parentNode ~= nil then parentNode.depth + 1 else 1
		local execProfile = report.executionAnalysis.profilesByPath[scriptInfo.fullPath]
		local envStr: string? = if execProfile ~= nil then tostring(execProfile.environment) else nil

		local existing = nodesById[scriptInfo.fullPath]
		if existing ~= nil then
			-- Upgrade placeholder container node to script node if a script has child scripts
			existing.nodeType = scriptInfo.className
			existing.className = scriptInfo.className
			existing.instance = scriptInfo.instance
			existing.isScript = true
			existing.scriptInfo = scriptInfo
			existing.environment = envStr
			if existing.parentId == nil and parentId ~= nil then
				existing.parentId = parentId
				addChildLink(parentId, existing.id)
			end
		else
			local scriptNode: GraphNode = {
				id = scriptInfo.fullPath,
				name = scriptInfo.name,
				fullPath = scriptInfo.fullPath,
				nodeType = scriptInfo.className,
				className = scriptInfo.className,
				instance = scriptInfo.instance,
				parentId = parentId,
				childIds = {},
				serviceName = scriptInfo.serviceName,
				depth = depth,
				isContainer = false,
				isScript = true,
				scriptInfo = scriptInfo,
				environment = envStr,
				dependencyCount = 0,
				dependentCount = 0,
				childScriptCount = 0,
				outgoingEdgeIds = {},
				incomingEdgeIds = {},
			}
			nodesById[scriptInfo.fullPath] = scriptNode
			table.insert(orderedNodes, scriptNode)

			if parentId == nil then
				registerRootId(scriptNode.id)
			else
				addChildLink(parentId, scriptNode.id)
			end
		end

		-- Increment childScriptCount up the ancestor chain
		local ancId = parentId
		while ancId ~= nil do
			local ancNode = nodesById[ancId]
			if ancNode == nil then
				break
			end
			ancNode.childScriptCount += 1
			ancId = ancNode.parentId
		end
	end

	-- If any script has children in the graph, mark it as both a script and expandable container
	for _, node in orderedNodes do
		if node.isScript and #node.childIds > 0 then
			node.isContainer = true
		end
	end

	-- 2. Build circular dependency lookup table
	local circularPairSet: { [string]: boolean } = {}
	for _, chain in report.dependencyAnalysis.circularChains do
		for i = 1, #chain - 1 do
			local fromPath = chain[i]
			local toPath = chain[i + 1]
			circularPairSet[fromPath .. "->" .. toPath] = true
		end
	end

	-- 3. Create dependency edges
	local depEdgeDedup: { [string]: GraphEdge } = {}
	for index, dep in report.dependencyAnalysis.allDependencies do
		local sourceNode = nodesById[dep.requiringScriptPath]
		if sourceNode == nil then
			continue
		end

		local targetNodeId: string
		if dep.status == "Resolved" and dep.resolvedModulePath ~= nil and nodesById[dep.resolvedModulePath] ~= nil then
			targetNodeId = dep.resolvedModulePath
		elseif dep.partialBasePath ~= nil and nodesById[dep.partialBasePath] ~= nil then
			targetNodeId = dep.partialBasePath
		else
			-- Create a synthetic unresolved node under the caller's service so unresolved edges are visible in the graph
			local unresolvedId = string.format(
				"__unresolved__:%s:%d:%d",
				dep.requiringScriptPath,
				dep.lineNumber,
				index
			)
			if nodesById[unresolvedId] == nil then
				local parentId = sourceNode.parentId
				local parentDepth = if parentId ~= nil and nodesById[parentId] ~= nil then nodesById[parentId].depth else 1
				local shortExpr = dep.rawExpression
				if #shortExpr > 28 then
					shortExpr = string.sub(shortExpr, 1, 25) .. "..."
				end
				local unresolvedNode: GraphNode = {
					id = unresolvedId,
					name = shortExpr,
					fullPath = dep.partialBasePath or dep.rawExpression,
					nodeType = "ModuleScript",
					className = "UnresolvedRequire",
					instance = nil,
					parentId = parentId,
					childIds = {},
					serviceName = sourceNode.serviceName,
					depth = parentDepth + 1,
					isContainer = false,
					isScript = false,
					scriptInfo = nil,
					environment = "Unresolved",
					dependencyCount = 0,
					dependentCount = 0,
					childScriptCount = 0,
					outgoingEdgeIds = {},
					incomingEdgeIds = {},
				}
				nodesById[unresolvedId] = unresolvedNode
				table.insert(orderedNodes, unresolvedNode)
			end
			targetNodeId = unresolvedId
		end

		local targetNode = nodesById[targetNodeId]
		if targetNode == nil then
			continue
		end

		-- Deduplicate multiple edges between the same source and target in the visual graph
		-- while preserving the highest-priority classification and metadata
		local pairKey = sourceNode.id .. "=>" .. targetNode.id
		local existingEdge = depEdgeDedup[pairKey]
		local isCircular = circularPairSet[sourceNode.id .. "->" .. targetNode.id] == true
		local candidateCount: number? = if dep.candidateModulePaths ~= nil then #dep.candidateModulePaths else nil

		if existingEdge ~= nil then
			if dep.isDynamic then
				existingEdge.isDynamic = true
			end
			if dep.isConditional then
				existingEdge.isConditional = true
			end
			if isCircular then
				existingEdge.isCircular = true
			end
		else
			local edgeId = string.format("dep:%s->%s#%d", sourceNode.id, targetNode.id, index)
			local depEdge: GraphEdge = {
				id = edgeId,
				kind = "Dependency",
				sourceNodeId = sourceNode.id,
				targetNodeId = targetNode.id,
				classification = dep.classification,
				status = dep.status,
				rawExpression = dep.rawExpression,
				lineNumber = dep.lineNumber,
				columnNumber = dep.columnNumber,
				scopeKind = dep.scopeKind,
				conditionExpression = dep.conditionExpression,
				isCircular = isCircular,
				isDynamic = dep.isDynamic,
				isConditional = dep.isConditional,
				candidateCount = candidateCount,
				dependencyRecord = dep,
			}
			depEdgeDedup[pairKey] = depEdge
			table.insert(dependencyEdges, depEdge)
			allEdgesById[edgeId] = depEdge

			table.insert(sourceNode.outgoingEdgeIds, edgeId)
			table.insert(targetNode.incomingEdgeIds, edgeId)

			sourceNode.dependencyCount += 1
			targetNode.dependentCount += 1
		end
	end

	-- 4. Roll up dependency/dependent counts onto ancestor containers for container summary stats
	for _, edge in dependencyEdges do
		local srcNode = nodesById[edge.sourceNodeId]
		local tgtNode = nodesById[edge.targetNodeId]
		if srcNode ~= nil then
			local ancId = srcNode.parentId
			while ancId ~= nil do
				local anc = nodesById[ancId]
				if anc == nil then
					break
				end
				if not anc.isScript then
					anc.dependencyCount += 1
				end
				ancId = anc.parentId
			end
		end
		if tgtNode ~= nil then
			local ancId = tgtNode.parentId
			while ancId ~= nil do
				local anc = nodesById[ancId]
				if anc == nil then
					break
				end
				if not anc.isScript then
					anc.dependentCount += 1
				end
				ancId = anc.parentId
			end
		end
	end

	-- 5. Deterministic ordering of rootNodeIds and childIds
	table.sort(rootNodeIds)
	for _, node in orderedNodes do
		table.sort(node.childIds, function(aId: string, bId: string): boolean
			local aNode = nodesById[aId]
			local bNode = nodesById[bId]
			if aNode ~= nil and bNode ~= nil then
				if aNode.isContainer ~= bNode.isContainer then
					return aNode.isContainer
				end
				return aNode.name < bNode.name
			end
			return aId < bId
		end)
	end

	table.sort(orderedNodes, function(a: GraphNode, b: GraphNode): boolean
		if a.serviceName ~= b.serviceName then
			return a.serviceName < b.serviceName
		end
		if a.depth ~= b.depth then
			return a.depth < b.depth
		end
		return a.fullPath < b.fullPath
	end)

	return {
		nodesById = nodesById,
		orderedNodes = orderedNodes,
		rootNodeIds = rootNodeIds,
		structuralEdges = structuralEdges,
		dependencyEdges = dependencyEdges,
		allEdgesById = allEdgesById,
	}
end

return GraphBuilder
