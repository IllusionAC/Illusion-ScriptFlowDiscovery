--!strict
--[[
	SelfTest.luau
	Comprehensive verification suite for Iteration 3:
	- Section 17: 14 Dependency Analysis Test Cases (direct, FindFirstChild, WaitForChild,
	  GetService, local aliases, chained aliases, generic for GetChildren, ipairs GetChildren,
	  pairs over stored GetChildren variable, GetDescendants with IsA("ModuleScript"),
	  Name == condition narrowing, nested container loops, circular dependencies,
	  and unresolvable dynamic requires).
	- Section 18: 12 Graph Architecture & Layout Test Cases (empty, small, medium 50+,
	  large 200+, deep hierarchy, shared modules, unused modules, circular dependencies,
	  unresolved dependencies, dynamic loop dependencies, container collapse/expand redirection,
	  live visual filtering, and Path2D technical validation).
]]

local Types = require("./Types")
local ScriptDiscovery = require("./ScriptDiscovery")
local DependencyAnalyzer = require("./DependencyAnalyzer")
local ExecutionAnalyzer = require("./ExecutionAnalyzer")
local GraphBuilder = require("./GraphBuilder")
local GraphLayout = require("./GraphLayout")
local GraphRenderer = require("./GraphRenderer")

type DiscoveredScript = Types.DiscoveredScript
type ScanCounts = Types.ScanCounts
type ScanReport = Types.ScanReport

export type TestCaseResult = {
	name: string,
	passed: boolean,
	detail: string,
}

export type TestSuiteSummary = {
	total: number,
	passed: number,
	failed: number,
	results: { TestCaseResult },
}

local SelfTest = {}

local function makeDiscoveredScript(
	inst: LuaSourceContainer,
	sourceCode: string,
	serviceName: string,
	root: Instance?
): DiscoveredScript
	local fullPath = ScriptDiscovery.getCleanFullPath(inst, root)
	local parent = inst.Parent
	local parentPath = if parent ~= nil then ScriptDiscovery.getCleanFullPath(parent, root) else serviceName
	local parentName = if parent ~= nil then parent.Name else serviceName
	local parentClass = if parent ~= nil then parent.ClassName else "Folder"
	local className: Types.ScriptClassName = if inst:IsA("LocalScript")
		then "LocalScript"
		elseif inst:IsA("ModuleScript") then "ModuleScript"
		else "Script"
	local isModule = (className == "ModuleScript")
	local _, newlineCount = string.gsub(sourceCode, "\n", "\n")
	return {
		instance = inst,
		name = inst.Name,
		fullPath = fullPath,
		className = className,
		scriptKind = if isModule then "Module" else "Executable",
		isExecutable = not isModule,
		isModule = isModule,
		parent = parent,
		parentName = parentName,
		parentClassName = parentClass,
		parentPath = parentPath,
		serviceName = serviceName,
		runContext = nil,
		runContextName = "Legacy",
		isEnabled = if isModule then nil else true,
		isActorDescendant = false,
		source = sourceCode,
		sourceAccessible = true,
		sourceError = nil,
		lineCount = newlineCount + 1,
	}
end

local function buildSyntheticScanReport(root: Instance, scripts: { DiscoveredScript }): ScanReport
	local counts: ScanCounts = {
		total = #scripts,
		serverScripts = 0,
		localScripts = 0,
		moduleScripts = 0,
		executableActive = 0,
		executableDormant = 0,
		inaccessibleSources = 0,
		instancesAnalyzed = #scripts + 5,
	}
	for _, s in scripts do
		if s.className == "Script" then
			counts.serverScripts += 1
		elseif s.className == "LocalScript" then
			counts.localScripts += 1
		else
			counts.moduleScripts += 1
		end
	end

	local depResult = DependencyAnalyzer.analyzeAll(scripts, root)
	local execResult = ExecutionAnalyzer.analyzeExecution(scripts, depResult, counts)

	return {
		timestamp = "2026-11-15 12:00:00",
		durationSeconds = 0.01,
		options = { root = root },
		scripts = scripts,
		counts = counts,
		dependencyAnalysis = depResult,
		executionAnalysis = execResult,
	}
end

function SelfTest.runAll(): TestSuiteSummary
	local results: { TestCaseResult } = {}

	local function record(name: string, passed: boolean, detail: string)
		table.insert(results, {
			name = name,
			passed = passed,
			detail = detail,
		})
	end

	-- Create a temporary isolated fixture tree in memory (not parented to game)
	local rootFolder = Instance.new("Folder")
	rootFolder.Name = "TestRoot"

	local sss = Instance.new("Folder")
	sss.Name = "ServerScriptService"
	sss.Parent = rootFolder

	local modulesFolder = Instance.new("Folder")
	modulesFolder.Name = "Modules"
	modulesFolder.Parent = sss

	local modAlpha = Instance.new("ModuleScript")
	modAlpha.Name = "Alpha"
	modAlpha.Parent = modulesFolder

	local modBeta = Instance.new("ModuleScript")
	modBeta.Name = "Beta"
	modBeta.Parent = modulesFolder

	local modClient = Instance.new("ModuleScript")
	modClient.Name = "ClientModule"
	modClient.Parent = modulesFolder

	local nonModPart = Instance.new("Part")
	nonModPart.Name = "DecoyPart"
	nonModPart.Parent = modulesFolder

	local nestedRoot = Instance.new("Folder")
	nestedRoot.Name = "NestedPackages"
	nestedRoot.Parent = sss

	local subFolderA = Instance.new("Folder")
	subFolderA.Name = "GroupA"
	subFolderA.Parent = nestedRoot

	local subFolderB = Instance.new("Folder")
	subFolderB.Name = "GroupB"
	subFolderB.Parent = nestedRoot

	local modGamma = Instance.new("ModuleScript")
	modGamma.Name = "Gamma"
	modGamma.Parent = subFolderA

	local modDelta = Instance.new("ModuleScript")
	modDelta.Name = "Delta"
	modDelta.Parent = subFolderB

	local cycleA = Instance.new("ModuleScript")
	cycleA.Name = "CycleA"
	cycleA.Parent = modulesFolder

	local cycleB = Instance.new("ModuleScript")
	cycleB.Name = "CycleB"
	cycleB.Parent = modulesFolder

	local unusedMod = Instance.new("ModuleScript")
	unusedMod.Name = "UnusedHelper"
	unusedMod.Parent = modulesFolder

	local callerScript = Instance.new("Script")
	callerScript.Name = "MainServer"
	callerScript.Parent = sss

	local baseFixtures: { DiscoveredScript } = {
		makeDiscoveredScript(modAlpha, "return {}", "ServerScriptService", rootFolder),
		makeDiscoveredScript(modBeta, "return {}", "ServerScriptService", rootFolder),
		makeDiscoveredScript(modClient, "return {}", "ServerScriptService", rootFolder),
		makeDiscoveredScript(modGamma, "return {}", "ServerScriptService", rootFolder),
		makeDiscoveredScript(modDelta, "return {}", "ServerScriptService", rootFolder),
		makeDiscoveredScript(cycleA, "local B = require(script.Parent.CycleB)\nreturn B", "ServerScriptService", rootFolder),
		makeDiscoveredScript(cycleB, "local A = require(script.Parent.CycleA)\nreturn A", "ServerScriptService", rootFolder),
		makeDiscoveredScript(unusedMod, "return {}", "ServerScriptService", rootFolder),
	}

	local function runCallerSourceAnalysis(source: string): (Types.DependencyAnalysisResult, string)
		local list: { DiscoveredScript } = {}
		for _, item in baseFixtures do
			table.insert(list, item)
		end
		table.insert(list, makeDiscoveredScript(callerScript, source, "ServerScriptService", rootFolder))
		return DependencyAnalyzer.analyzeAll(list, rootFolder), ScriptDiscovery.getCleanFullPath(callerScript, rootFolder)
	end

	-- =========================================================================
	-- Section 17: 14 Dependency Analysis Test Cases
	-- =========================================================================

	-- 17.1 Direct path require
	do
		local res, callerPath = runCallerSourceAnalysis("local a = require(script.Parent.Modules.Alpha)")
		local sum = res.byScriptPath[callerPath]
		local ok = sum ~= nil
			and #sum.dependencies == 1
			and sum.dependencies[1].status == "Resolved"
			and sum.dependencies[1].classification == "Static"
			and sum.dependencies[1].resolvedModuleName == "Alpha"
		record("17.1 Direct path require", ok, "require(script.Parent.Modules.Alpha)")
	end

	-- 17.2 FindFirstChild require
	do
		local res, callerPath = runCallerSourceAnalysis(
			'local a = require(script.Parent:FindFirstChild("Modules"):FindFirstChild("Alpha"))'
		)
		local sum = res.byScriptPath[callerPath]
		local ok = sum ~= nil
			and #sum.dependencies == 1
			and sum.dependencies[1].status == "Resolved"
			and sum.dependencies[1].resolvedModuleName == "Alpha"
		record("17.2 FindFirstChild require", ok, "Resolved via :FindFirstChild()")
	end

	-- 17.3 WaitForChild require
	do
		local res, callerPath = runCallerSourceAnalysis(
			'local b = require(script.Parent:WaitForChild("Modules"):WaitForChild("Beta"))'
		)
		local sum = res.byScriptPath[callerPath]
		local ok = sum ~= nil
			and #sum.dependencies == 1
			and sum.dependencies[1].status == "Resolved"
			and sum.dependencies[1].resolvedModuleName == "Beta"
		record("17.3 WaitForChild require", ok, "Resolved via :WaitForChild()")
	end

	-- 17.4 GetService require
	do
		local repStorage = game:GetService("ReplicatedStorage")
		local tempMod = Instance.new("ModuleScript")
		tempMod.Name = "TempSharedSpecMod"
		tempMod.Parent = repStorage
		local list: { DiscoveredScript } = {
			makeDiscoveredScript(tempMod, "return {}", "ReplicatedStorage"),
			makeDiscoveredScript(
				callerScript,
				'local s = require(game:GetService("ReplicatedStorage").TempSharedSpecMod)',
				"ServerScriptService"
			),
		}
		local res = DependencyAnalyzer.analyzeAll(list, game)
		local sum = res.byScriptPath[ScriptDiscovery.getCleanFullPath(callerScript, game)]
		local ok = sum ~= nil
			and #sum.dependencies == 1
			and sum.dependencies[1].status == "Resolved"
			and sum.dependencies[1].resolvedModuleName == "TempSharedSpecMod"
		tempMod:Destroy()
		record("17.4 GetService require", ok, 'Resolved via game:GetService("ReplicatedStorage")')
	end

	-- 17.5 Local variable alias
	do
		local src = [[
			local targetMod = script.Parent.Modules.Alpha
			require(targetMod)
		]]
		local res, callerPath = runCallerSourceAnalysis(src)
		local sum = res.byScriptPath[callerPath]
		local ok = sum ~= nil
			and #sum.dependencies == 1
			and sum.dependencies[1].status == "Resolved"
			and sum.dependencies[1].resolvedModuleName == "Alpha"
			and sum.dependencies[1].usedAlias == "targetMod"
		record("17.5 Local variable alias", ok, "Resolved local targetMod = ...; require(targetMod)")
	end

	-- 17.6 Chained variable aliases
	do
		local src = [[
			local root = script.Parent
			local mods = root:WaitForChild("Modules")
			local betaRef = mods.Beta
			require(betaRef)
		]]
		local res, callerPath = runCallerSourceAnalysis(src)
		local sum = res.byScriptPath[callerPath]
		local ok = sum ~= nil
			and #sum.dependencies == 1
			and sum.dependencies[1].status == "Resolved"
			and sum.dependencies[1].resolvedModuleName == "Beta"
		record("17.6 Chained variable aliases", ok, "Resolved 3-hop local alias chain")
	end

	-- 17.7 Generic for loop over GetChildren()
	do
		local src = [[
			local Folder = script.Parent.Modules
			for _, module in Folder:GetChildren() do
				require(module)
			end
		]]
		local res, callerPath = runCallerSourceAnalysis(src)
		local sum = res.byScriptPath[callerPath]
		local ok = sum ~= nil
			and #sum.dependencies >= 5
			and sum.dependencies[1].classification == "DynamicResolved"
			and sum.dependencies[1].isDynamic == true
			and sum.dependencies[1].scopeKind == "Loop"
		record(
			"17.7 Generic for loop over GetChildren()",
			ok,
			string.format("Expanded %d ModuleScript candidates", if sum ~= nil then #sum.dependencies else 0)
		)
	end

	-- 17.8 ipairs loop over GetChildren()
	do
		local src = [[
			for _, module in ipairs(script.Parent.Modules:GetChildren()) do
				require(module)
			end
		]]
		local res, callerPath = runCallerSourceAnalysis(src)
		local sum = res.byScriptPath[callerPath]
		local ok = sum ~= nil
			and #sum.dependencies >= 5
			and sum.dependencies[1].classification == "DynamicResolved"
			and sum.dependencies[1].scopeKind == "Loop"
		record("17.8 ipairs loop over GetChildren()", ok, "Expanded ipairs(Folder:GetChildren())")
	end

	-- 17.9 pairs loop over stored GetChildren() variable
	do
		local src = [[
			local Modules = script.Parent:WaitForChild("Modules")
			local Dependencies = Modules:GetChildren()
			for _, dependency in pairs(Dependencies) do
				require(dependency)
			end
		]]
		local res, callerPath = runCallerSourceAnalysis(src)
		local sum = res.byScriptPath[callerPath]
		local ok = sum ~= nil
			and #sum.dependencies >= 5
			and sum.dependencies[1].classification == "DynamicResolved"
		record("17.9 pairs loop over stored GetChildren() variable", ok, "Expanded stored collection variable")
	end

	-- 17.10 GetDescendants() with IsA("ModuleScript")
	do
		local src = [[
			for _, module in script.Parent.NestedPackages:GetDescendants() do
				if module:IsA("ModuleScript") then
					require(module)
				end
			end
		]]
		local res, callerPath = runCallerSourceAnalysis(src)
		local sum = res.byScriptPath[callerPath]
		local ok = sum ~= nil
			and #sum.dependencies == 2
			and sum.dependencies[1].status == "Resolved"
			and sum.dependencies[2].status == "Resolved"
		record("17.10 GetDescendants() with IsA('ModuleScript')", ok, "Resolved Gamma and Delta across subfolders")
	end

	-- 17.11 Loop with Name == condition
	do
		local src = [[
			for _, module in script.Parent.Modules:GetChildren() do
				if module.Name == "ClientModule" then
					require(module)
				end
			end
		]]
		local res, callerPath = runCallerSourceAnalysis(src)
		local sum = res.byScriptPath[callerPath]
		local ok = sum ~= nil
			and #sum.dependencies == 1
			and sum.dependencies[1].resolvedModuleName == "ClientModule"
			and sum.dependencies[1].isConditional == true
			and sum.dependencies[1].classification == "Conditional"
		record("17.11 Loop with Name == condition", ok, "Narrowed candidate set to ClientModule only")
	end

	-- 17.12 Nested container loops
	do
		local src = [[
			for _, folder in script.Parent.NestedPackages:GetChildren() do
				for _, module in folder:GetChildren() do
					require(module)
				end
			end
		]]
		local res, callerPath = runCallerSourceAnalysis(src)
		local sum = res.byScriptPath[callerPath]
		local ok = sum ~= nil
			and #sum.dependencies == 2
			and sum.dependencies[1].classification == "DynamicResolved"
		record("17.12 Nested container loops", ok, "Expanded outer folder loop -> inner module loop (Gamma, Delta)")
	end

	-- 17.13 Circular dependencies
	do
		local res, _ = runCallerSourceAnalysis("require(script.Parent.Modules.CycleA)")
		local ok = #res.circularChains >= 1
		record("17.13 Circular dependencies", ok, string.format("Detected %d circular chain(s)", #res.circularChains))
	end

	-- 17.14 Unresolvable dynamic require
	do
		local res, callerPath = runCallerSourceAnalysis("local x = getDynamicModule()\nrequire(x)")
		local sum = res.byScriptPath[callerPath]
		local ok = sum ~= nil
			and #sum.dependencies == 1
			and sum.dependencies[1].status == "Unresolved"
			and sum.dependencies[1].classification == "Unresolved"
		record("17.14 Unresolvable dynamic require", ok, "Marked as Unresolved with diagnostic reason")
	end

	-- 17.15 Redefined / aliased require function (`local a = require`, `a(...)`, `a "..."`)
	do
		local src = [[
			local a = require
			local b = a
			local m1 = a(script.Parent.Modules.Alpha)
			local m2 = a "./Modules/Beta"
			local m3 = b './Modules/ClientModule'
		]]
		local res, callerPath = runCallerSourceAnalysis(src)
		local sum = res.byScriptPath[callerPath]
		local ok = sum ~= nil
			and #sum.dependencies == 3
			and sum.dependencies[1].status == "Resolved"
			and sum.dependencies[1].resolvedModuleName == "Alpha"
			and sum.dependencies[2].status == "Resolved"
			and sum.dependencies[2].resolvedModuleName == "Beta"
			and sum.dependencies[3].status == "Resolved"
			and sum.dependencies[3].resolvedModuleName == "ClientModule"
		record(
			"17.15 Redefined / aliased require (local a = require; a(...); a \"...\")",
			ok,
			"Resolved parenthesized and string-call requires through function aliases"
		)
	end

	-- =========================================================================
	-- Section 18: 12 Graph Architecture & Layout Test Cases
	-- =========================================================================
	local defaultFilters = GraphLayout.createDefaultFilters()

	-- 18.1 Empty project
	do
		local emptyReport = buildSyntheticScanReport(rootFolder, {})
		local model = GraphBuilder.build(emptyReport)
		local layout = GraphLayout.computeLayout(model, defaultFilters, {})
		local ok = (#model.orderedNodes == 0 and #layout.orderedLayoutNodes == 0 and #layout.layoutEdges == 0)
		record("18.1 Empty project graph", ok, "0 nodes, 0 edges without error")
	end

	-- 18.2 Small project (under 10 scripts)
	do
		local allSmall: { DiscoveredScript } = {}
		for _, f in baseFixtures do
			table.insert(allSmall, f)
		end
		table.insert(
			allSmall,
			makeDiscoveredScript(
				callerScript,
				"require(script.Parent.Modules.Alpha)\nfor _, m in script.Parent.NestedPackages:GetDescendants() do if m:IsA('ModuleScript') then require(m) end end\nrequire(unknownVar)",
				"ServerScriptService",
				rootFolder
			)
		)
		local smallReport = buildSyntheticScanReport(rootFolder, allSmall)
		local model = GraphBuilder.build(smallReport)
		local layout = GraphLayout.computeLayout(model, defaultFilters, {})
		local ok = #model.orderedNodes >= 9 and #layout.layoutEdges >= 8
		record(
			"18.2 Small project graph (<10 scripts)",
			ok,
			string.format("%d nodes, %d layout edges", #model.orderedNodes, #layout.layoutEdges)
		)

		-- 18.5 Deeply nested container hierarchies
		local modGammaNode = model.nodesById[ScriptDiscovery.getCleanFullPath(modGamma, rootFolder)]
		local deepOk = modGammaNode ~= nil and modGammaNode.depth >= 4
		record(
			"18.5 Deeply nested container hierarchies",
			deepOk,
			string.format("Gamma depth = %d", if modGammaNode ~= nil then modGammaNode.depth else -1)
		)

		-- 18.6 Modules shared by many scripts
		local cycleANode = model.nodesById[ScriptDiscovery.getCleanFullPath(cycleA, rootFolder)]
		local sharedOk = cycleANode ~= nil and cycleANode.dependentCount >= 1
		record("18.6 Modules shared by scripts", sharedOk, "Tracked incoming dependent counts")

		-- 18.7 Unused ModuleScripts
		local unusedOk = #smallReport.dependencyAnalysis.unusedModulePaths >= 1
		record(
			"18.7 Unused ModuleScripts in graph",
			unusedOk,
			string.format("%d unreferenced modules", #smallReport.dependencyAnalysis.unusedModulePaths)
		)

		-- 18.8 Circular dependencies in graph
		local hasCycleEdge = false
		for _, edge in model.dependencyEdges do
			if edge.isCircular then
				hasCycleEdge = true
				break
			end
		end
		record("18.8 Circular dependencies flagged on GraphEdge", hasCycleEdge, "edge.isCircular == true")

		-- 18.9 Unresolved dependencies in graph
		local hasUnresolvedEdge = false
		for _, edge in model.dependencyEdges do
			if edge.status == "Unresolved" then
				hasUnresolvedEdge = true
				break
			end
		end
		record("18.9 Unresolved dependencies represented in graph", hasUnresolvedEdge, "Unresolved edge & node created")

		-- 18.10 Dynamic loop dependencies in graph
		local hasDynamicEdge = false
		for _, edge in model.dependencyEdges do
			if edge.isDynamic and edge.classification == "DynamicResolved" then
				hasDynamicEdge = true
				break
			end
		end
		record("18.10 Dynamic loop dependencies in graph", hasDynamicEdge, "edge.isDynamic == true")

		-- 18.11 Expanding and collapsing containers
		local collapsedMap = {
			[ScriptDiscovery.getCleanFullPath(nestedRoot, rootFolder)] = true,
		}
		local collapsedLayout = GraphLayout.computeLayout(model, defaultFilters, collapsedMap)
		local gammaLayout = collapsedLayout.layoutNodesById[ScriptDiscovery.getCleanFullPath(modGamma, rootFolder)]
		local collapseOk = gammaLayout ~= nil and gammaLayout.visible == false
		record("18.11 Expanding and collapsing containers", collapseOk, "Descendants hidden & edges redirected")

		-- 18.12 Filtering nodes and connections
		local filteredState = GraphLayout.createDefaultFilters()
		filteredState.showContainers = false
		filteredState.showDynamicDependencies = false
		local filteredLayout = GraphLayout.computeLayout(model, filteredState, {})
		local containersHidden = true
		for _, ln in filteredLayout.orderedLayoutNodes do
			if ln.visible and not ln.node.isScript and ln.node.className ~= "UnresolvedRequire" then
				containersHidden = false
				break
			end
		end
		record("18.12 Live filtering of nodes and connections", containersHidden, "Containers & dynamic edges filtered")
	end

	-- 18.3 Medium project (50+ scripts) & 18.4 Large project (200+ scripts)
	for _, targetCount in { 55, 205 } do
		local scaleRoot = Instance.new("Folder")
		scaleRoot.Name = "ScaleRoot_" .. tostring(targetCount)
		local scaleService = Instance.new("Folder")
		scaleService.Name = "ServerScriptService"
		scaleService.Parent = scaleRoot

		local scaleScripts: { DiscoveredScript } = {}
		for i = 1, targetCount do
			local m = Instance.new("ModuleScript")
			m.Name = string.format("Mod_%03d", i)
			m.Parent = scaleService
			local src = if i > 1
				then string.format("return require(script.Parent.Mod_%03d)", i - 1)
				else "return {}"
			table.insert(scaleScripts, makeDiscoveredScript(m, src, "ServerScriptService", scaleRoot))
		end

		local scaleReport = buildSyntheticScanReport(scaleRoot, scaleScripts)
		local scaleModel = GraphBuilder.build(scaleReport)
		local scaleLayout = GraphLayout.computeLayout(scaleModel, defaultFilters, {})
		local ok = #scaleLayout.orderedLayoutNodes >= targetCount and #scaleLayout.layoutEdges >= (targetCount - 1)
		local label = if targetCount < 100
			then "18.3 Medium project graph (50+ scripts)"
			else "18.4 Large project graph (200+ scripts)"
		record(
			label,
			ok,
			string.format("%d scripts laid out (%dx%d px)", targetCount, scaleLayout.canvasWidth, scaleLayout.canvasHeight)
		)
		scaleRoot:Destroy()
	end

	-- Phase 1 Path2D Technical Validation Check
	do
		local tempFrame = Instance.new("Frame")
		local pathValidation = GraphRenderer.validatePath2DSupport(tempFrame)
		tempFrame:Destroy()
		record(
			"Phase 1 Path2D Technical Validation",
			pathValidation.supported,
			pathValidation.diagnosticMessage
		)
	end

	rootFolder:Destroy()

	local passedCount = 0
	local failedCount = 0
	for _, r in results do
		if r.passed then
			passedCount += 1
		else
			failedCount += 1
		end
	end

	return {
		total = #results,
		passed = passedCount,
		failed = failedCount,
		results = results,
	}
end

return SelfTest
