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

export type DependencyClassification =
	"Static"
	| "DynamicResolved"
	| "DynamicPartial"
	| "Conditional"
	| "Unresolved"

export type RequireScopeKind = "TopLevel" | "Function" | "Loop" | "Conditional"

export type DependencyRecord = {
	requiringScriptPath: string,
	requiringScriptName: string,
	requiringScriptClass: ScriptClassName,
	rawExpression: string,
	lineNumber: number,
	columnNumber: number,
	isTopLevel: boolean,
	scopeKind: RequireScopeKind,
	status: ResolutionStatus,
	classification: DependencyClassification,
	isDynamic: boolean,
	isConditional: boolean,
	conditionExpression: string?,
	candidateModulePaths: { string }?,
	expansionGroupId: string?,
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

-- =============================================================================
-- Iteration 3: Game Architecture Graph Model & Layout Types
-- =============================================================================

export type GraphNodeType =
	"Service"
	| "Folder"
	| "Model"
	| "Container"
	| "Script"
	| "LocalScript"
	| "ModuleScript"

export type GraphEdgeKind = "Structural" | "Dependency"

export type GraphNode = {
	id: string,
	name: string,
	fullPath: string,
	nodeType: GraphNodeType,
	className: string,
	instance: Instance?,
	parentId: string?,
	childIds: { string },
	serviceName: string,
	depth: number,
	isContainer: boolean,
	isScript: boolean,
	scriptInfo: DiscoveredScript?,
	environment: string?,
	dependencyCount: number,
	dependentCount: number,
	childScriptCount: number,
	outgoingEdgeIds: { string },
	incomingEdgeIds: { string },
}

export type GraphEdge = {
	id: string,
	kind: GraphEdgeKind,
	sourceNodeId: string,
	targetNodeId: string,
	classification: DependencyClassification?,
	status: ResolutionStatus?,
	rawExpression: string?,
	lineNumber: number?,
	columnNumber: number?,
	scopeKind: RequireScopeKind?,
	conditionExpression: string?,
	isCircular: boolean,
	isDynamic: boolean,
	isConditional: boolean,
	candidateCount: number?,
	dependencyRecord: DependencyRecord?,
}

export type GraphModel = {
	nodesById: { [string]: GraphNode },
	orderedNodes: { GraphNode },
	rootNodeIds: { string },
	structuralEdges: { GraphEdge },
	dependencyEdges: { GraphEdge },
	allEdgesById: { [string]: GraphEdge },
}

export type GraphPoint2D = {
	x: number,
	y: number,
}

export type GraphControlPointData = {
	position: GraphPoint2D,
	leftTangent: GraphPoint2D,
	rightTangent: GraphPoint2D,
}

export type GraphLayoutNode = {
	id: string,
	node: GraphNode,
	x: number,
	y: number,
	width: number,
	height: number,
	layer: number,
	orderInLayer: number,
	isCollapsed: boolean,
	visible: boolean,
}

export type GraphLayoutEdge = {
	id: string,
	edge: GraphEdge,
	sourceNodeId: string,
	targetNodeId: string,
	startPoint: GraphPoint2D,
	endPoint: GraphPoint2D,
	midpoint: GraphPoint2D,
	arrowDirection: GraphPoint2D,
	controlPoints: { GraphControlPointData },
	visible: boolean,
}

export type GraphLayoutResult = {
	layoutNodesById: { [string]: GraphLayoutNode },
	orderedLayoutNodes: { GraphLayoutNode },
	layoutEdges: { GraphLayoutEdge },
	canvasWidth: number,
	canvasHeight: number,
}

export type GraphFilterState = {
	showContainers: boolean,
	showScripts: boolean,
	showLocalScripts: boolean,
	showModuleScripts: boolean,
	showStructuralEdges: boolean,
	showDependencyEdges: boolean,
	showDynamicDependencies: boolean,
	searchQuery: string,
}

export type Path2DValidationResult = {
	supported: boolean,
	canInstantiate: boolean,
	canParentToGuiObject: boolean,
	canSetControlPoints: boolean,
	canStyleProperties: boolean,
	canQueryCurveGeometry: boolean,
	diagnosticMessage: string,
}

local Types = {}

return Types
