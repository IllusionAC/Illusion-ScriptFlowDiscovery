--!strict
--[[
	ScriptDiscovery.luau
	Discovers all Script, LocalScript, and ModuleScript instances across the DataModel,
	collecting metadata, hierarchy context, and safely reading script source via
	ScriptEditorService with fallback to .Source.
]]

local ScriptEditorService = game:GetService("ScriptEditorService")

local Types = require("./Types")

type DiscoveredScript = Types.DiscoveredScript
type ScriptClassName = Types.ScriptClassName
type ScriptKind = Types.ScriptKind
type ScanOptions = Types.ScanOptions
type ScanCounts = Types.ScanCounts

local ScriptDiscovery = {}

-- Internal Roblox Studio / Core services that are not part of user project code
local IGNORED_TOP_LEVEL_SERVICES: { [string]: boolean } = {
	CoreGui = true,
	CorePackages = true,
	PluginGuiService = true,
	RobloxPluginGuiService = true,
	PluginDebugService = true,
	MemStorageService = true,
	ScriptContext = true,
	StudioService = true,
	ChangeHistoryService = true,
	Selection = true,
	LogService = true,
	Visit = true,
	RobloxReplicatedStorage = true,
	DebuggerManager = true,
	DraftsService = true,
	HSRDataContentProvider = true,
	HttpRbxApiService = true,
	InstanceExtensionsService = true,
	ModerationService = true,
	NonReplicatedCSGDictionaryService = true,
	CSGDictionaryService = true,
	PackageUIService = true,
	PermissionsService = true,
	PlayerEmulatorService = true,
	ProcessInstancePhysicsService = true,
	RobloxServerStorage = true,
	RuntimeScriptService = true,
	SafetyService = true,
	SnippetService = true,
	StopWatchReporter = true,
	StylingService = true,
	TemporaryCageMeshProvider = true,
	ThirdPartyUserService = true,
	TimerService = true,
	TracerService = true,
	UGCAvatarService = true,
	UnvalidatedAssetService = true,
	VersionControlService = true,
	VideoCaptureService = true,
	VoiceChatInternal = true,
	VoiceChatService = true,
}

local function safeGetClassName(instance: Instance): string?
	local ok, className = pcall(function(): string
		return instance.ClassName
	end)
	if ok and type(className) == "string" then
		return className
	end
	return nil
end

local function safeGetName(instance: Instance): string
	local ok, name = pcall(function(): string
		return instance.Name
	end)
	if ok and type(name) == "string" then
		return name
	end
	return "<InaccessibleName>"
end

local function safeGetChildren(instance: Instance): { Instance }
	local ok, children = pcall(function(): { Instance }
		return instance:GetChildren()
	end)
	if ok and type(children) == "table" then
		return children
	end
	return {}
end

function ScriptDiscovery.getCleanFullPath(instance: Instance, root: Instance?): string
	local stopRoot: Instance = root or game
	if instance == stopRoot then
		return safeGetName(instance)
	end

	local segments: { string } = {}
	local current: Instance? = instance
	local guard = 0

	while current ~= nil and current ~= stopRoot and guard < 256 do
		guard += 1
		local currentInst: Instance = current
		table.insert(segments, 1, safeGetName(currentInst))
		local ok, parent = pcall(function(): Instance?
			return currentInst.Parent
		end)
		if not ok then
			break
		end
		current = parent
	end

	if #segments == 0 then
		local okFull, fullName = pcall(function(): string
			return instance:GetFullName()
		end)
		if okFull and type(fullName) == "string" then
			return fullName
		end
		return safeGetName(instance)
	end

	return table.concat(segments, ".")
end

local function getTopLevelServiceName(instance: Instance, root: Instance): string
	local current: Instance? = instance
	local lastBeforeRoot: Instance? = nil
	local guard = 0

	while current ~= nil and current ~= root and guard < 256 do
		guard += 1
		local currentInst: Instance = current
		lastBeforeRoot = currentInst
		local ok, parent = pcall(function(): Instance?
			return currentInst.Parent
		end)
		if not ok then
			break
		end
		current = parent
	end

	if lastBeforeRoot ~= nil then
		return safeGetName(lastBeforeRoot)
	end
	return safeGetName(instance)
end

local function hasActorAncestor(instance: Instance, root: Instance): boolean
	local ok, parent = pcall(function(): Instance?
		return instance.Parent
	end)
	if not ok then
		return false
	end

	local current: Instance? = parent
	local guard = 0
	while current ~= nil and current ~= root and guard < 256 do
		guard += 1
		local currentInst: Instance = current
		local okActor, isActor = pcall(function(): boolean
			return currentInst:IsA("Actor")
		end)
		if okActor and isActor then
			return true
		end
		local okNext, nextParent = pcall(function(): Instance?
			return currentInst.Parent
		end)
		if not okNext then
			break
		end
		current = nextParent
	end

	return false
end

local function countLines(text: string): number
	if text == "" then
		return 0
	end
	local count = 1
	for _ in string.gmatch(text, "\n") do
		count += 1
	end
	return count
end

function ScriptDiscovery.readScriptSource(scriptInstance: LuaSourceContainer): (string?, boolean, string?)
	-- 1. Try ScriptEditorService:GetEditorSource first (reflects open Studio editor buffers)
	local okEditor, editorResult = pcall(function(): string
		return ScriptEditorService:GetEditorSource(scriptInstance)
	end)
	if okEditor and type(editorResult) == "string" then
		return editorResult, true, nil
	end

	-- 2. Fallback to direct .Source property access via narrowed LuaSourceContainer subtypes
	local okSource, sourceResult = pcall(function(): string
		if scriptInstance:IsA("ModuleScript") then
			return scriptInstance.Source
		elseif scriptInstance:IsA("LocalScript") then
			return scriptInstance.Source
		elseif scriptInstance:IsA("Script") then
			return scriptInstance.Source
		end
		error("Unsupported LuaSourceContainer subtype")
	end)

	if okSource and type(sourceResult) == "string" then
		return sourceResult, true, nil
	end

	local errMsg = if not okSource
		then tostring(sourceResult)
		elseif not okEditor then tostring(editorResult)
		else "Source property inaccessible due to Studio security permissions"
	return nil, false, errMsg
end

local function classifyScriptClass(instance: Instance): (ScriptClassName?, LuaSourceContainer?)
	local className = safeGetClassName(instance)
	if className == nil then
		return nil, nil
	end

	if className == "ModuleScript" and instance:IsA("ModuleScript") then
		return "ModuleScript", instance
	elseif className == "LocalScript" and instance:IsA("LocalScript") then
		return "LocalScript", instance
	elseif className == "Script" and instance:IsA("Script") then
		return "Script", instance
	end

	return nil, nil
end

local function inspectScriptInstance(
	scriptInstance: LuaSourceContainer,
	className: ScriptClassName,
	options: ScanOptions
): DiscoveredScript
	local root = options.root
	local name = safeGetName(scriptInstance)
	local fullPath = ScriptDiscovery.getCleanFullPath(scriptInstance, root)

	local okParent, parentInst = pcall(function(): Instance?
		return scriptInstance.Parent
	end)
	local parent: Instance? = if okParent then parentInst else nil
	local parentName = if parent ~= nil then safeGetName(parent) else "None"
	local parentClassName = if parent ~= nil then (safeGetClassName(parent) or "Unknown") else "None"
	local parentPath = if parent ~= nil then ScriptDiscovery.getCleanFullPath(parent, root) else "None"

	local serviceName = getTopLevelServiceName(scriptInstance, root)
	local isModule = (className == "ModuleScript")
	local isExecutable = not isModule
	local scriptKind: ScriptKind = if isModule then "Module" else "Executable"

	local runContext: Enum.RunContext? = nil
	local runContextName = "Module (On-Demand)"
	local isEnabled: boolean? = nil

	if className == "Script" and scriptInstance:IsA("Script") then
		local okRunContext, rc = pcall(function(): Enum.RunContext
			return scriptInstance.RunContext
		end)
		if okRunContext and rc ~= nil then
			runContext = rc
			runContextName = rc.Name
		else
			runContextName = "Legacy"
		end

		local okEnabled, enabledVal = pcall(function(): boolean
			return scriptInstance.Enabled
		end)
		if okEnabled and type(enabledVal) == "boolean" then
			isEnabled = enabledVal
		else
			isEnabled = true
		end
	elseif className == "LocalScript" and scriptInstance:IsA("LocalScript") then
		runContextName = "Client (LocalScript)"
		local okEnabled, enabledVal = pcall(function(): boolean
			return scriptInstance.Enabled
		end)
		if okEnabled and type(enabledVal) == "boolean" then
			isEnabled = enabledVal
		else
			isEnabled = true
		end
	end

	local source, sourceAccessible, sourceError = ScriptDiscovery.readScriptSource(scriptInstance)
	local lineCount = if source ~= nil then countLines(source) else 0

	return {
		instance = scriptInstance,
		name = name,
		fullPath = fullPath,
		className = className,
		scriptKind = scriptKind,
		isExecutable = isExecutable,
		isModule = isModule,
		parent = parent,
		parentName = parentName,
		parentClassName = parentClassName,
		parentPath = parentPath,
		serviceName = serviceName,
		runContext = runContext,
		runContextName = runContextName,
		isEnabled = isEnabled,
		isActorDescendant = hasActorAncestor(scriptInstance, root),
		source = source,
		sourceAccessible = sourceAccessible,
		sourceError = sourceError,
		lineCount = lineCount,
	}
end

function ScriptDiscovery.discoverScripts(options: ScanOptions): ({ DiscoveredScript }, ScanCounts)
	local discovered: { DiscoveredScript } = {}
	local root = options.root
	local instancesAnalyzed = 0

	local function traverse(node: Instance, isTopLevelChild: boolean)
		if isTopLevelChild then
			local nodeName = safeGetName(node)
			local nodeClass = safeGetClassName(node)
			if IGNORED_TOP_LEVEL_SERVICES[nodeName] or (nodeClass ~= nil and IGNORED_TOP_LEVEL_SERVICES[nodeClass]) then
				return
			end
		end

		instancesAnalyzed += 1

		local scriptClass: ScriptClassName?, scriptContainer: LuaSourceContainer? = classifyScriptClass(node)
		if scriptClass ~= nil and scriptContainer ~= nil then
			local info = inspectScriptInstance(scriptContainer, scriptClass, options)
			table.insert(discovered, info)
		end

		local children = safeGetChildren(node)
		for _, child in children do
			traverse(child, false)
		end
	end

	-- Start traversal from root's children
	local topChildren = safeGetChildren(root)
	for _, topChild in topChildren do
		traverse(topChild, root == game)
	end

	-- Sort deterministically by fullPath
	table.sort(discovered, function(a: DiscoveredScript, b: DiscoveredScript): boolean
		return a.fullPath < b.fullPath
	end)

	local counts: ScanCounts = {
		total = #discovered,
		serverScripts = 0,
		localScripts = 0,
		moduleScripts = 0,
		executableActive = 0,
		executableDormant = 0,
		inaccessibleSources = 0,
		instancesAnalyzed = instancesAnalyzed,
	}

	for _, item in discovered do
		if item.className == "Script" then
			counts.serverScripts += 1
		elseif item.className == "LocalScript" then
			counts.localScripts += 1
		elseif item.className == "ModuleScript" then
			counts.moduleScripts += 1
		end

		if not item.sourceAccessible then
			counts.inaccessibleSources += 1
		end
	end

	return discovered, counts
end

return ScriptDiscovery
