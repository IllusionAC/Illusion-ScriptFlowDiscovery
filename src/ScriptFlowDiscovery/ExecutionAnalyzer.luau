--!strict
--[[
	ExecutionAnalyzer.luau
	Analyzes execution contexts, container eligibility, Roblox lifecycle phases,
	known ordering constraints, potential module initialization chains, and
	undetermined peer execution groups across Server, Client, and Plugin environments.
]]

local Types = require("./Types")

type DiscoveredScript = Types.DiscoveredScript
type DependencyAnalysisResult = Types.DependencyAnalysisResult
type ScriptExecutionProfile = Types.ScriptExecutionProfile
type ExecutionEnvironment = Types.ExecutionEnvironment
type ExecutionPhase = Types.ExecutionPhase
type ExecutionConstraintItem = Types.ExecutionConstraintItem
type ExecutionAnalysisResult = Types.ExecutionAnalysisResult
type ExecutionStepDetail = Types.ExecutionStepDetail
type ScanCounts = Types.ScanCounts

local ExecutionAnalyzer = {}

local function isStarterPlayerScriptsPath(fullPath: string): boolean
	return string.find(fullPath, "^StarterPlayer%.StarterPlayerScripts%.") ~= nil
		or fullPath == "StarterPlayer.StarterPlayerScripts"
end

local function isStarterCharacterScriptsPath(fullPath: string): boolean
	return string.find(fullPath, "^StarterPlayer%.StarterCharacterScripts%.") ~= nil
		or fullPath == "StarterPlayer.StarterCharacterScripts"
end

local function computeTopLevelModuleSequence(
	startScriptPath: string,
	dependencyAnalysis: DependencyAnalysisResult
): ({ string }, { ExecutionStepDetail })
	local sequence: { string } = {}
	local steps: { ExecutionStepDetail } = {}
	local visited: { [string]: boolean } = {
		[startScriptPath] = true,
	}

	local function visit(scriptPath: string)
		local summary = dependencyAnalysis.byScriptPath[scriptPath]
		if summary == nil then
			return
		end

		for _, rec in summary.dependencies do
			if rec.status == "Resolved" and rec.resolvedModulePath ~= nil then
				local targetPath = rec.resolvedModulePath
				local targetName = rec.resolvedModuleName or targetPath
				local scopeTag = if rec.isTopLevel
					then "top-level"
					elseif rec.scopeKind == "Loop" then "loop-candidate (" .. rec.classification .. ")"
					elseif rec.scopeKind == "Conditional" then "conditional"
					else "function-scope"
				if not visited[targetPath] then
					visited[targetPath] = true
					if rec.isTopLevel and not rec.isDynamic and not rec.isConditional then
						visit(targetPath)
					end
					table.insert(sequence, string.format("%s (%s, line %d:%d)", targetPath, scopeTag, rec.lineNumber, rec.columnNumber))
					table.insert(steps, {
						stepIndex = #steps + 1,
						scriptPath = targetPath,
						scriptName = targetName,
						scope = scopeTag,
						lineNumber = rec.lineNumber,
					})
				end
			end
		end
	end

	visit(startScriptPath)
	return sequence, steps
end

local function classifyExecutableScript(
	scriptInfo: DiscoveredScript,
	dependencyAnalysis: DependencyAnalysisResult
): ScriptExecutionProfile
	local serviceName = scriptInfo.serviceName
	local fullPath = scriptInfo.fullPath
	local isEnabled = scriptInfo.isEnabled ~= false
	local topLevelModules, orderedSteps = computeTopLevelModuleSequence(fullPath, dependencyAnalysis)

	-- 1. Disabled executable script
	if not isEnabled then
		return {
			script = scriptInfo,
			environment = "Inactive",
			phase = "Dormant_Disabled",
			phaseLabel = "Disabled (Enabled = false)",
			willAutoExecute = false,
			eligibilityReason = "Script has Enabled = false; will not execute automatically unless enabled at runtime.",
			topLevelModuleOrder = topLevelModules,
			orderedSteps = orderedSteps,
		}
	end

	-- 2. Script (Legacy, Server, Client, Plugin)
	if scriptInfo.className == "Script" then
		local rc = scriptInfo.runContext

		if rc == Enum.RunContext.Plugin then
			return {
				script = scriptInfo,
				environment = "Plugin",
				phase = "Plugin_Studio",
				phaseLabel = "Studio Plugin Context (RunContext.Plugin)",
				willAutoExecute = true,
				eligibilityReason = "Script has RunContext = Plugin; executes inside the Roblox Studio Plugin VM.",
				topLevelModuleOrder = topLevelModules,
				orderedSteps = orderedSteps,
			}
		elseif rc == Enum.RunContext.Server then
			if isStarterCharacterScriptsPath(fullPath) or serviceName == "StarterPack" then
				return {
					script = scriptInfo,
					environment = "Server",
					phase = "Server_CharacterOrToolSpawn",
					phaseLabel = "Server (RunContext.Server in Starter Container)",
					willAutoExecute = true,
					eligibilityReason = string.format(
						"RunContext = Server inside '%s'; runs on the Server and cloned copies also execute when Player Character/Backpack spawns.",
						serviceName
					),
					topLevelModuleOrder = topLevelModules,
					orderedSteps = orderedSteps,
				}
			end

			return {
				script = scriptInfo,
				environment = "Server",
				phase = "Server_Initialization",
				phaseLabel = string.format("Server Phase 1: Server Initialization (%s, RunContext.Server)", serviceName),
				willAutoExecute = true,
				eligibilityReason = string.format(
					"Script has RunContext = Server in '%s'; executes on the Server during initialization regardless of ancestor container.",
					serviceName
				),
				topLevelModuleOrder = topLevelModules,
				orderedSteps = orderedSteps,
			}
		elseif rc == Enum.RunContext.Client then
			if serviceName == "ServerStorage" or serviceName == "ServerScriptService" then
				return {
					script = scriptInfo,
					environment = "Inactive",
					phase = "Ineligible_Container",
					phaseLabel = string.format("Ineligible Client Container (%s Not Replicated)", serviceName),
					willAutoExecute = false,
					eligibilityReason = string.format(
						"Script has RunContext = Client, but '%s' is never replicated to clients; will not execute unless reparented to a replicated container.",
						serviceName
					),
					topLevelModuleOrder = topLevelModules,
					orderedSteps = orderedSteps,
				}
			elseif serviceName == "ReplicatedFirst" then
				return {
					script = scriptInfo,
					environment = "Client",
					phase = "Client_ReplicatedFirst",
					phaseLabel = "Client Phase 1: ReplicatedFirst (RunContext.Client)",
					willAutoExecute = true,
					eligibilityReason = "Script has RunContext = Client in ReplicatedFirst; executes on the Client during early replication.",
					topLevelModuleOrder = topLevelModules,
					orderedSteps = orderedSteps,
				}
			elseif isStarterCharacterScriptsPath(fullPath) or serviceName == "StarterPack" then
				return {
					script = scriptInfo,
					environment = "Client",
					phase = "Client_CharacterOrToolSpawn",
					phaseLabel = string.format("Client Phase 3: Character/Tool Spawn (%s, RunContext.Client)", serviceName),
					willAutoExecute = true,
					eligibilityReason = string.format(
						"Script has RunContext = Client in '%s'; executes on the Client when cloned into Character/Backpack.",
						serviceName
					),
					topLevelModuleOrder = topLevelModules,
					orderedSteps = orderedSteps,
				}
			else
				return {
					script = scriptInfo,
					environment = "Client",
					phase = "Client_PlayerInit",
					phaseLabel = string.format("Client Phase 2: Replicated Initialization (%s, RunContext.Client)", serviceName),
					willAutoExecute = true,
					eligibilityReason = string.format(
						"Script has RunContext = Client in replicated service '%s'; executes on the Client once replicated.",
						serviceName
					),
					topLevelModuleOrder = topLevelModules,
					orderedSteps = orderedSteps,
				}
			end
		else
			-- Default: Enum.RunContext.Legacy
			if serviceName == "ServerScriptService" or serviceName == "Workspace" then
				return {
					script = scriptInfo,
					environment = "Server",
					phase = "Server_Initialization",
					phaseLabel = string.format("Server Phase 1: Server Startup (%s)", serviceName),
					willAutoExecute = true,
					eligibilityReason = string.format(
						"Legacy Script in '%s'; executes automatically on the Server during place initialization.",
						serviceName
					),
					topLevelModuleOrder = topLevelModules,
					orderedSteps = orderedSteps,
				}
			elseif isStarterCharacterScriptsPath(fullPath) or serviceName == "StarterPack" then
				local targetContainer = if isStarterCharacterScriptsPath(fullPath)
					then "StarterCharacterScripts (clones to Character)"
					else "StarterPack (clones to Player.Backpack)"
				return {
					script = scriptInfo,
					environment = "Server",
					phase = "Server_CharacterOrToolSpawn",
					phaseLabel = string.format("Server Phase 2: Spawn-Triggered (%s)", targetContainer),
					willAutoExecute = true,
					eligibilityReason = string.format(
						"Legacy Script in %s; dormant in template container, executes on the Server when cloned for a spawning player.",
						targetContainer
					),
					topLevelModuleOrder = topLevelModules,
					orderedSteps = orderedSteps,
				}
			else
				return {
					script = scriptInfo,
					environment = "Inactive",
					phase = "Dormant_Container",
					phaseLabel = string.format("Dormant in Container (%s)", serviceName),
					willAutoExecute = false,
					eligibilityReason = string.format(
						"Legacy Script in '%s' does not auto-execute; only executes if cloned or parented into ServerScriptService or Workspace at runtime.",
						serviceName
					),
					topLevelModuleOrder = topLevelModules,
					orderedSteps = orderedSteps,
				}
			end
		end
	end

	-- 3. LocalScript
	if serviceName == "ReplicatedFirst" then
		return {
			script = scriptInfo,
			environment = "Client",
			phase = "Client_ReplicatedFirst",
			phaseLabel = "Client Phase 1: ReplicatedFirst (Early Client Replication)",
			willAutoExecute = true,
			eligibilityReason = "LocalScript in ReplicatedFirst; guaranteed to execute on the Client before general DataModel replication completes.",
			topLevelModuleOrder = topLevelModules,
			orderedSteps = orderedSteps,
		}
	elseif isStarterPlayerScriptsPath(fullPath) then
		return {
			script = scriptInfo,
			environment = "Client",
			phase = "Client_PlayerInit",
			phaseLabel = "Client Phase 2: PlayerScripts (StarterPlayerScripts)",
			willAutoExecute = true,
			eligibilityReason = "LocalScript in StarterPlayerScripts; cloned to Player.PlayerScripts and executes once on the Client after ReplicatedFirst.",
			topLevelModuleOrder = topLevelModules,
			orderedSteps = orderedSteps,
		}
	elseif serviceName == "StarterGui" then
		return {
			script = scriptInfo,
			environment = "Client",
			phase = "Client_PlayerInit",
			phaseLabel = "Client Phase 2: PlayerGui (StarterGui)",
			willAutoExecute = true,
			eligibilityReason = "LocalScript in StarterGui; cloned to Player.PlayerGui and executes on the Client when GUI initializes.",
			topLevelModuleOrder = topLevelModules,
			orderedSteps = orderedSteps,
		}
	elseif isStarterCharacterScriptsPath(fullPath) then
		return {
			script = scriptInfo,
			environment = "Client",
			phase = "Client_CharacterOrToolSpawn",
			phaseLabel = "Client Phase 3: Character Spawn (StarterCharacterScripts)",
			willAutoExecute = true,
			eligibilityReason = "LocalScript in StarterCharacterScripts; cloned into LocalPlayer.Character and executes on the Client each time the character spawns.",
			topLevelModuleOrder = topLevelModules,
			orderedSteps = orderedSteps,
		}
	elseif serviceName == "StarterPack" then
		return {
			script = scriptInfo,
			environment = "Client",
			phase = "Client_CharacterOrToolSpawn",
			phaseLabel = "Client Phase 3: Backpack Spawn (StarterPack)",
			willAutoExecute = true,
			eligibilityReason = "LocalScript in StarterPack; cloned into LocalPlayer.Backpack and executes on the Client when character spawns.",
			topLevelModuleOrder = topLevelModules,
			orderedSteps = orderedSteps,
		}
	elseif serviceName == "Workspace" then
		return {
			script = scriptInfo,
			environment = "Inactive",
			phase = "Dormant_Container",
			phaseLabel = "Dormant / Character-Bound in Workspace",
			willAutoExecute = false,
			eligibilityReason = "LocalScript directly in Workspace does NOT auto-execute unless parented inside LocalPlayer.Character at runtime.",
			topLevelModuleOrder = topLevelModules,
			orderedSteps = orderedSteps,
		}
	else
		return {
			script = scriptInfo,
			environment = "Inactive",
			phase = "Dormant_Container",
			phaseLabel = string.format("Dormant in Container (%s)", serviceName),
			willAutoExecute = false,
			eligibilityReason = string.format(
				"LocalScript in '%s' does not auto-execute; must be cloned into PlayerScripts, PlayerGui, Backpack, or Character.",
				serviceName
			),
			topLevelModuleOrder = topLevelModules,
			orderedSteps = orderedSteps,
		}
	end
end

function ExecutionAnalyzer.analyzeExecution(
	discoveredScripts: { DiscoveredScript },
	dependencyAnalysis: DependencyAnalysisResult,
	counts: ScanCounts
): ExecutionAnalysisResult
	local profilesByPath: { [string]: ScriptExecutionProfile } = {}
	local serverExecutableProfiles: { ScriptExecutionProfile } = {}
	local clientExecutableProfiles: { ScriptExecutionProfile } = {}
	local pluginExecutableProfiles: { ScriptExecutionProfile } = {}
	local dormantExecutableProfiles: { ScriptExecutionProfile } = {}
	local moduleProfiles: { ScriptExecutionProfile } = {}

	-- First pass: classify all executable scripts
	for _, scriptInfo in discoveredScripts do
		if scriptInfo.isExecutable then
			local profile = classifyExecutableScript(scriptInfo, dependencyAnalysis)
			profilesByPath[scriptInfo.fullPath] = profile

			if profile.willAutoExecute then
				counts.executableActive += 1
				if profile.environment == "Server" then
					table.insert(serverExecutableProfiles, profile)
				elseif profile.environment == "Client" then
					table.insert(clientExecutableProfiles, profile)
				elseif profile.environment == "Plugin" then
					table.insert(pluginExecutableProfiles, profile)
				end
			else
				counts.executableDormant += 1
				table.insert(dormantExecutableProfiles, profile)
			end
		end
	end

	-- Propagate execution environments down the resolved ModuleScript dependency graph
	local moduleEnvs: { [string]: { [string]: boolean } } = {}
	for _, scriptInfo in discoveredScripts do
		if scriptInfo.isModule then
			moduleEnvs[scriptInfo.fullPath] = {}
		end
	end

	local function propagateEnvironment(startPath: string, env: string)
		local visited: { [string]: boolean } = {}
		local function dfs(currPath: string)
			if visited[currPath] then
				return
			end
			visited[currPath] = true
			local summary = dependencyAnalysis.byScriptPath[currPath]
			if summary == nil then
				return
			end
			for _, targetModPath in summary.resolvedModules do
				if moduleEnvs[targetModPath] ~= nil then
					moduleEnvs[targetModPath][env] = true
				end
				dfs(targetModPath)
			end
		end
		dfs(startPath)
	end

	for _, profile in serverExecutableProfiles do
		propagateEnvironment(profile.script.fullPath, "Server")
	end
	for _, profile in clientExecutableProfiles do
		propagateEnvironment(profile.script.fullPath, "Client")
	end
	for _, profile in pluginExecutableProfiles do
		propagateEnvironment(profile.script.fullPath, "Plugin")
	end

	-- Second pass: classify ModuleScripts based on requiring environments
	for _, scriptInfo in discoveredScripts do
		if scriptInfo.isModule then
			local fullPath = scriptInfo.fullPath
			local existingEnvs = moduleEnvs[fullPath]
			local envs: { [string]: boolean } = if existingEnvs ~= nil then existingEnvs else {}
			local isServer = envs["Server"] == true
			local isClient = envs["Client"] == true
			local isPlugin = envs["Plugin"] == true
			local summary = dependencyAnalysis.byScriptPath[fullPath]
			local reqCount = if summary ~= nil then #summary.requiredByPaths else 0

			local envLabel: ExecutionEnvironment = "UnreferencedModule"
			local reason = "No static require() references discovered in the current DataModel; will not execute unless required dynamically."

			if isServer and isClient then
				envLabel = "SharedModule"
				reason = "Required by both Server and Client scripts; executes independently once per VM (Server VM and Client VM) upon first require()."
			elseif isServer then
				envLabel = "ServerModule"
				reason = "Required by Server script(s); executes lazily once in the Server VM on first require()."
			elseif isClient then
				envLabel = "ClientModule"
				if scriptInfo.serviceName == "ServerStorage" or scriptInfo.serviceName == "ServerScriptService" then
					reason = string.format(
						"WARNING: Required by a Client script, but located in '%s' which does NOT replicate to clients (will fail at runtime on Client).",
						scriptInfo.serviceName
					)
				else
					reason = "Required by Client script(s); executes lazily once in the Client VM on first require()."
				end
			elseif isPlugin then
				envLabel = "Plugin"
				reason = "Required by Studio Plugin script(s); executes lazily once in the Plugin VM on first require()."
			elseif reqCount > 0 then
				envLabel = "Inactive"
				reason = string.format(
					"Required by %d script(s), but all requiring root scripts are currently disabled or in dormant containers.",
					reqCount
				)
			end

			local modSeq, modSteps = computeTopLevelModuleSequence(fullPath, dependencyAnalysis)
			local modProfile: ScriptExecutionProfile = {
				script = scriptInfo,
				environment = envLabel,
				phase = "OnDemand_Module",
				phaseLabel = string.format("On-Demand via require() (%s)", envLabel),
				willAutoExecute = false,
				eligibilityReason = reason,
				topLevelModuleOrder = modSeq,
				orderedSteps = modSteps,
			}
			profilesByPath[fullPath] = modProfile
			table.insert(moduleProfiles, modProfile)
		end
	end

	-- Sort Server and Client executable profiles by lifecycle phase then path
	local phasePriority: { [ExecutionPhase]: number } = {
		Client_ReplicatedFirst = 1,
		Server_Initialization = 1,
		Client_PlayerInit = 2,
		Server_CharacterOrToolSpawn = 2,
		Client_CharacterOrToolSpawn = 3,
		Plugin_Studio = 1,
		OnDemand_Module = 4,
		Dormant_Disabled = 5,
		Dormant_Container = 6,
		Ineligible_Container = 7,
	}

	local function sortProfiles(list: { ScriptExecutionProfile })
		table.sort(list, function(a: ScriptExecutionProfile, b: ScriptExecutionProfile): boolean
			local pa = phasePriority[a.phase] or 99
			local pb = phasePriority[b.phase] or 99
			if pa ~= pb then
				return pa < pb
			end
			return a.script.fullPath < b.script.fullPath
		end)
	end

	sortProfiles(serverExecutableProfiles)
	sortProfiles(clientExecutableProfiles)
	sortProfiles(pluginExecutableProfiles)
	sortProfiles(dormantExecutableProfiles)
	sortProfiles(moduleProfiles)

	-- Build Known Constraints, Potential Orders, and Undetermined Groups
	local knownConstraints: { ExecutionConstraintItem } = {}
	local potentialOrders: { ExecutionConstraintItem } = {}
	local undeterminedGroups: { ExecutionConstraintItem } = {}

	local function pushConstraint(list: { ExecutionConstraintItem }, item: ExecutionConstraintItem)
		table.insert(list, item)
	end

	-- Group scripts by phase for lifecycle constraint & undetermined peer analysis
	local serverStartupPaths: { string } = {}
	local serverSpawnPaths: { string } = {}
	local clientRepFirstPaths: { string } = {}
	local clientPlayerInitPaths: { string } = {}
	local clientCharSpawnPaths: { string } = {}
	local pluginPaths: { string } = {}

	for _, prof in serverExecutableProfiles do
		if prof.phase == "Server_Initialization" then
			table.insert(serverStartupPaths, prof.script.fullPath)
		elseif prof.phase == "Server_CharacterOrToolSpawn" then
			table.insert(serverSpawnPaths, prof.script.fullPath)
		end
	end

	for _, prof in clientExecutableProfiles do
		if prof.phase == "Client_ReplicatedFirst" then
			table.insert(clientRepFirstPaths, prof.script.fullPath)
		elseif prof.phase == "Client_PlayerInit" then
			table.insert(clientPlayerInitPaths, prof.script.fullPath)
		elseif prof.phase == "Client_CharacterOrToolSpawn" then
			table.insert(clientCharSpawnPaths, prof.script.fullPath)
		end
	end

	for _, prof in pluginExecutableProfiles do
		table.insert(pluginPaths, prof.script.fullPath)
	end

	-- 1. Known Constraints
	if #clientRepFirstPaths > 0 and (#clientPlayerInitPaths > 0 or #clientCharSpawnPaths > 0) then
		local combined: { string } = {}
		for _, p in clientRepFirstPaths do
			table.insert(combined, p)
		end
		for _, p in clientPlayerInitPaths do
			table.insert(combined, p)
		end
		for _, p in clientCharSpawnPaths do
			table.insert(combined, p)
		end
		pushConstraint(knownConstraints, {
			category = "KnownConstraint",
			environment = "Client",
			title = "ReplicatedFirst Pre-GameLoaded Guarantee",
			description = string.format(
				"Scripts in ReplicatedFirst (%d) are guaranteed by the Roblox engine to begin executing on the Client before StarterPlayerScripts/StarterGui (%d) and Character/Backpack scripts (%d).",
				#clientRepFirstPaths,
				#clientPlayerInitPaths,
				#clientCharSpawnPaths
			),
			relatedScripts = combined,
			subjectScriptPath = clientRepFirstPaths[1],
			sourceLine = nil,
			conditions = "Guaranteed by the Roblox client replication lifecycle whenever ReplicatedFirst scripts are enabled.",
			steps = nil,
		})
	end

	if #clientPlayerInitPaths > 0 and #clientCharSpawnPaths > 0 then
		pushConstraint(knownConstraints, {
			category = "KnownConstraint",
			environment = "Client",
			title = "Client Join vs. Character Spawn Lifecycle",
			description = "StarterPlayerScripts and StarterGui initialize when the LocalPlayer joins, whereas StarterCharacterScripts and StarterPack only execute after the server spawns and replicates the player's Character (and re-run on each respawn).",
			relatedScripts = clientCharSpawnPaths,
			subjectScriptPath = clientPlayerInitPaths[1],
			sourceLine = nil,
			conditions = "Applies when Players.CharacterAutoLoads is active or until Player:LoadCharacter() is invoked.",
			steps = nil,
		})
	end

	if #serverStartupPaths > 0 and #serverSpawnPaths > 0 then
		pushConstraint(knownConstraints, {
			category = "KnownConstraint",
			environment = "Server",
			title = "Server Initialization Precedes Character Spawn Scripts",
			description = string.format(
				"Server startup scripts in ServerScriptService/Workspace (%d) initialize when the server starts, prior to spawn-cloned Server scripts in StarterCharacterScripts/StarterPack (%d).",
				#serverStartupPaths,
				#serverSpawnPaths
			),
			relatedScripts = serverStartupPaths,
			subjectScriptPath = serverStartupPaths[1],
			sourceLine = nil,
			conditions = "Guaranteed by the Roblox server lifecycle prior to player character spawning.",
			steps = nil,
		})
	end

	-- Synchronous top-level require constraints
	for _, prof in discoveredScripts do
		local execProf = profilesByPath[prof.fullPath]
		if execProf ~= nil and (execProf.willAutoExecute or prof.isModule) and #execProf.topLevelModuleOrder > 0 then
			local summary = dependencyAnalysis.byScriptPath[prof.fullPath]
			local hasTopLevel = false
			local firstLine: number? = nil
			if summary ~= nil then
				for _, r in summary.dependencies do
					if r.isTopLevel and r.status == "Resolved" then
						hasTopLevel = true
						if firstLine == nil then
							firstLine = r.lineNumber
						end
					end
				end
			end
			if hasTopLevel and prof.isExecutable then
				pushConstraint(knownConstraints, {
					category = "KnownConstraint",
					environment = tostring(execProf.environment),
					title = string.format("Synchronous Top-Level require() Chain in %s", prof.fullPath),
					description = "Top-level require() calls execute synchronously in source order; each required ModuleScript must complete its top-level chunk before the requiring script continues execution.",
					relatedScripts = execProf.topLevelModuleOrder,
					subjectScriptPath = prof.fullPath,
					sourceLine = firstLine,
					conditions = "Guaranteed during script initialization unless an earlier require() throws an uncaught runtime error or yields indefinitely.",
					steps = execProf.orderedSteps,
				})
			end
		end
	end

	-- Cross-boundary warnings (e.g. Client script requiring ServerStorage/ServerScriptService module)
	for _, rec in dependencyAnalysis.resolvedDependencies do
		local reqProf = profilesByPath[rec.requiringScriptPath]
		local targetPath = rec.resolvedModulePath
		local targetSummary = if targetPath ~= nil then dependencyAnalysis.byScriptPath[targetPath] else nil
		if reqProf ~= nil and targetSummary ~= nil then
			local targetService = targetSummary.script.serviceName
			if
				(reqProf.environment == "Client" or reqProf.environment == "ClientModule")
				and (targetService == "ServerStorage" or targetService == "ServerScriptService")
			then
				pushConstraint(knownConstraints, {
					category = "KnownConstraint",
					environment = "Client -> Server Boundary",
					title = "Replication Boundary Violation",
					description = string.format(
						"Client-context script '%s' (line %d) requires '%s' inside '%s', which is not replicated to clients and will fail to resolve at runtime.",
						rec.requiringScriptPath,
						rec.lineNumber,
						targetSummary.script.fullPath,
						targetService
					),
					relatedScripts = { rec.requiringScriptPath, targetSummary.script.fullPath },
					subjectScriptPath = rec.requiringScriptPath,
					sourceLine = rec.lineNumber,
					conditions = "ServerStorage and ServerScriptService instances are stripped from client replication by the Roblox engine.",
					steps = nil,
				})
			end
		end
	end

	-- 2. Potential Execution Orders (Entry-point module evaluation sequences)
	local activeExecs: { ScriptExecutionProfile } = {}
	for _, p in clientExecutableProfiles do
		table.insert(activeExecs, p)
	end
	for _, p in serverExecutableProfiles do
		table.insert(activeExecs, p)
	end
	for _, p in pluginExecutableProfiles do
		table.insert(activeExecs, p)
	end

	for _, prof in activeExecs do
		if #prof.topLevelModuleOrder > 0 then
			local summary = dependencyAnalysis.byScriptPath[prof.script.fullPath]
			local firstLine: number? = nil
			if summary ~= nil and #summary.dependencies > 0 then
				firstLine = summary.dependencies[1].lineNumber
			end
			pushConstraint(potentialOrders, {
				category = "PotentialOrder",
				environment = tostring(prof.environment),
				title = string.format("%s (%s)", prof.script.fullPath, prof.phaseLabel),
				description = "If this script is the first in its VM to require these modules, they will initialize in the following depth-first sequence:",
				relatedScripts = prof.topLevelModuleOrder,
				subjectScriptPath = prof.script.fullPath,
				sourceLine = firstLine,
				conditions = "Conditional: A ModuleScript's top-level code executes only on its first require() per Luau VM. If another peer script requires a shared module first, that module returns its cached value here without re-running its top-level chunk.",
				steps = prof.orderedSteps,
			})
		end
	end

	-- Cyclic ModuleScript Chains (Beta-Dependent Execution Order)
	for cIdx, chain in dependencyAnalysis.circularChains do
		local firstModulePath = chain[1]
		local firstProf = if firstModulePath ~= nil then profilesByPath[firstModulePath] else nil
		local envLabel = if firstProf ~= nil then tostring(firstProf.environment) else "SharedModule"
		pushConstraint(potentialOrders, {
			category = "PotentialOrder",
			environment = envLabel,
			title = string.format("Cyclic Module Dependency Chain #%d (%s)", cIdx, table.concat(chain, " -> ")),
			description = "Circular ModuleScript require() cycle detected. Top-level cyclic requires work ONLY if the Roblox Studio Beta feature 'Luau Modularity: Export Values and Cyclic Requires' is enabled (or if the mutual require() calls are deferred inside functions).",
			relatedScripts = chain,
			subjectScriptPath = firstModulePath,
			sourceLine = nil,
			conditions = "Conditional on Studio Beta: Works at top level only when 'Luau Modularity: Export Values and Cyclic Requires' beta feature is enabled; otherwise throws a recursive require error / deadlocks at runtime unless deferred inside a function.",
			steps = nil,
		})
	end

	-- 3. Undetermined Execution Order Groups
	if #serverStartupPaths > 1 then
		pushConstraint(undeterminedGroups, {
			category = "Undetermined",
			environment = "Server",
			title = string.format("Server Startup Peer Scripts (%d scripts)", #serverStartupPaths),
			description = "Roblox does not guarantee a deterministic startup order among sibling or cross-service scripts in ServerScriptService and Workspace.",
			relatedScripts = serverStartupPaths,
			subjectScriptPath = serverStartupPaths[1],
			sourceLine = nil,
			conditions = "Limitation: Engine scheduling order between independent server scripts cannot be determined statically.",
			steps = nil,
		})
	end

	if #serverSpawnPaths > 1 then
		pushConstraint(undeterminedGroups, {
			category = "Undetermined",
			environment = "Server",
			title = string.format("Server Character/Backpack Spawn Peer Scripts (%d scripts)", #serverSpawnPaths),
			description = "Relative execution order among Server scripts cloned from StarterCharacterScripts and StarterPack on character spawn is not guaranteed by the engine.",
			relatedScripts = serverSpawnPaths,
			subjectScriptPath = serverSpawnPaths[1],
			sourceLine = nil,
			conditions = "Limitation: Cloned instance initialization order during character spawning is not guaranteed.",
			steps = nil,
		})
	end

	if #clientRepFirstPaths > 1 then
		pushConstraint(undeterminedGroups, {
			category = "Undetermined",
			environment = "Client",
			title = string.format("ReplicatedFirst Peer Scripts (%d scripts)", #clientRepFirstPaths),
			description = "While all ReplicatedFirst scripts run before standard client scripts, the relative execution order among multiple scripts inside ReplicatedFirst is undetermined.",
			relatedScripts = clientRepFirstPaths,
			subjectScriptPath = clientRepFirstPaths[1],
			sourceLine = nil,
			conditions = "Limitation: Use a single entry-point LocalScript in ReplicatedFirst if strict ordering is required.",
			steps = nil,
		})
	end

	if #clientPlayerInitPaths > 1 then
		pushConstraint(undeterminedGroups, {
			category = "Undetermined",
			environment = "Client",
			title = string.format("Client Join / PlayerInit Peer Scripts (%d scripts)", #clientPlayerInitPaths),
			description = "Relative execution order among scripts across StarterPlayerScripts, StarterGui, and replicated RunContext.Client containers is undetermined.",
			relatedScripts = clientPlayerInitPaths,
			subjectScriptPath = clientPlayerInitPaths[1],
			sourceLine = nil,
			conditions = "Limitation: Dependent on network replication arrival order and internal engine container cloning order.",
			steps = nil,
		})
	end

	if #clientCharSpawnPaths > 1 then
		pushConstraint(undeterminedGroups, {
			category = "Undetermined",
			environment = "Client",
			title = string.format("Client Character/Backpack Spawn Peer Scripts (%d scripts)", #clientCharSpawnPaths),
			description = "Relative execution order among LocalScripts in StarterCharacterScripts and StarterPack during character spawn is undetermined.",
			relatedScripts = clientCharSpawnPaths,
			subjectScriptPath = clientCharSpawnPaths[1],
			sourceLine = nil,
			conditions = "Limitation: Character and Backpack replication/cloning order is non-deterministic.",
			steps = nil,
		})
	end

	if #pluginPaths > 1 then
		pushConstraint(undeterminedGroups, {
			category = "Undetermined",
			environment = "Plugin",
			title = string.format("Studio Plugin Peer Scripts (%d scripts)", #pluginPaths),
			description = "Relative initialization order among multiple independent Studio plugin scripts is undetermined.",
			relatedScripts = pluginPaths,
			subjectScriptPath = pluginPaths[1],
			sourceLine = nil,
			conditions = "Limitation: Independent plugin scripts initialize in an unspecified engine order.",
			steps = nil,
		})
	end

	-- Shared Module First-Requirer Ambiguity within the same VM
	for _, modProf in moduleProfiles do
		local modPath = modProf.script.fullPath
		local summary = dependencyAnalysis.byScriptPath[modPath]
		if summary ~= nil and #summary.requiredByPaths > 1 then
			pushConstraint(undeterminedGroups, {
				category = "Undetermined",
				environment = tostring(modProf.environment),
				title = string.format("Module First-Requirer Order: %s", modPath),
				description = string.format(
					"Required by %d scripts/modules. Because a ModuleScript executes its top-level chunk only once per VM on its first require(), which caller triggers initialization depends on runtime caller order.",
					#summary.requiredByPaths
				),
				relatedScripts = summary.requiredByPaths,
				subjectScriptPath = modPath,
				sourceLine = nil,
				conditions = "Limitation: Static analysis identifies all callers, but runtime execution order of the callers determines which require() initializes the module first.",
				steps = nil,
			})
		end
	end

	return {
		profilesByPath = profilesByPath,
		serverExecutableProfiles = serverExecutableProfiles,
		clientExecutableProfiles = clientExecutableProfiles,
		pluginExecutableProfiles = pluginExecutableProfiles,
		dormantExecutableProfiles = dormantExecutableProfiles,
		moduleProfiles = moduleProfiles,
		knownConstraints = knownConstraints,
		potentialOrders = potentialOrders,
		undeterminedGroups = undeterminedGroups,
	}
end

return ExecutionAnalyzer
