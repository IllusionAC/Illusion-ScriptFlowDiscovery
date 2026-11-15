--!strict
--[[
	Types.luau
	Shared strict type definitions for Illusion's ScriptFlowDiscovery plugin.
]]

export type ScriptClassName = "Script" | "LocalScript" | "ModuleScript"

export type ScriptKind = "Executable" | "Module"

export type ExecutionEnvironment =
	"Server"
	| "Client"
	| "Plugin"
	| "ServerModule"
	| "ClientModule"
	| "SharedModule"
	| "UnreferencedModule"
	| "Inactive"

export type ExecutionPhase =
	"Client_ReplicatedFirst"
	| "Server_Initialization"
	| "Client_PlayerInit"
	| "Server_CharacterOrToolSpawn"
	| "Client_CharacterOrToolSpawn"
	| "Plugin_Studio"
	| "OnDemand_Module"
	| "Dormant_Disabled"
	| "Dormant_Container"
	| "Ineligible_Container"

export type OrderDeterminism = "KnownConstraint" | "PotentialOrder" | "Undetermined"

export type DiscoveredScript = {
	instance: LuaSourceContainer,
	name: string,
	fullPath: string,
	className: ScriptClassName,
	scriptKind: ScriptKind,
	isExecutable: boolean,
	isModule: boolean,
	parent: Instance?,
	parentName: string,
	parentClassName: string,
	parentPath: string,
	serviceName: string,
	runContext: Enum.RunContext?,
	runContextName: string,
	isEnabled: boolean?,
	isActorDescendant: boolean,
	source: string?,
	sourceAccessible: boolean,
	sourceError: string?,
	lineCount: number,
}

export type ResolutionStatus = "Resolved" | "PartiallyResolved" | "Unresolved"

export type DependencyRecord = {
	requiringScriptPath: string,
	requiringScriptName: string,
	requiringScriptClass: ScriptClassName,
	rawExpression: string,
	lineNumber: number,
	isTopLevel: boolean,
	status: ResolutionStatus,
	resolvedModulePath: string?,
	resolvedModuleName: string?,
	resolvedInstance: ModuleScript?,
	partialBasePath: string?,
	failureReason: string?,
	usedAlias: string?,
}

export type ScriptDependencySummary = {
	script: DiscoveredScript,
	dependencies: { DependencyRecord },
	resolvedModules: { string },
	unresolvedRecords: { DependencyRecord },
	requiredByPaths: { string },
}

export type DependencyAnalysisResult = {
	allDependencies: { DependencyRecord },
	resolvedDependencies: { DependencyRecord },
	unresolvedDependencies: { DependencyRecord },
	byScriptPath: { [string]: ScriptDependencySummary },
	unusedModulePaths: { string },
	circularChains: { { string } },
}

export type ExecutionStepDetail = {
	stepIndex: number,
	scriptPath: string,
	scriptName: string,
	scope: string,
	lineNumber: number?,
}

export type ScriptExecutionProfile = {
	script: DiscoveredScript,
	environment: ExecutionEnvironment,
	phase: ExecutionPhase,
	phaseLabel: string,
	willAutoExecute: boolean,
	eligibilityReason: string,
	topLevelModuleOrder: { string },
	orderedSteps: { ExecutionStepDetail },
}

export type ExecutionConstraintItem = {
	category: OrderDeterminism,
	environment: string,
	title: string,
	description: string,
	relatedScripts: { string },
	subjectScriptPath: string?,
	sourceLine: number?,
	conditions: string?,
	steps: { ExecutionStepDetail }?,
}

export type ExecutionAnalysisResult = {
	profilesByPath: { [string]: ScriptExecutionProfile },
	serverExecutableProfiles: { ScriptExecutionProfile },
	clientExecutableProfiles: { ScriptExecutionProfile },
	pluginExecutableProfiles: { ScriptExecutionProfile },
	dormantExecutableProfiles: { ScriptExecutionProfile },
	moduleProfiles: { ScriptExecutionProfile },
	knownConstraints: { ExecutionConstraintItem },
	potentialOrders: { ExecutionConstraintItem },
	undeterminedGroups: { ExecutionConstraintItem },
}

export type ScanOptions = {
	root: Instance,
}

export type ScanCounts = {
	total: number,
	serverScripts: number,
	localScripts: number,
	moduleScripts: number,
	executableActive: number,
	executableDormant: number,
	inaccessibleSources: number,
	instancesAnalyzed: number,
}

export type ScanReport = {
	timestamp: string,
	durationSeconds: number,
	options: ScanOptions,
	scripts: { DiscoveredScript },
	counts: ScanCounts,
	dependencyAnalysis: DependencyAnalysisResult,
	executionAnalysis: ExecutionAnalysisResult,
}

export type NavigationTab = "Overview" | "Scripts" | "Dependencies" | "Execution"

local Types = {}

return Types
