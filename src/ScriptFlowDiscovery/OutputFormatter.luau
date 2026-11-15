--!strict
--[[
	OutputFormatter.luau
	Formats the ScanReport into a clean, structured, human-readable report for the
	Roblox Studio Output window and plugin status display.
]]

local Types = require("./Types")

type ScanReport = Types.ScanReport
type DiscoveredScript = Types.DiscoveredScript
type DependencyRecord = Types.DependencyRecord
type ScriptDependencySummary = Types.ScriptDependencySummary
type ScriptExecutionProfile = Types.ScriptExecutionProfile
type ExecutionConstraintItem = Types.ExecutionConstraintItem

local OutputFormatter = {}

local DIVIDER = string.rep("=", 62)
local SUB_DIVIDER = string.rep("-", 62)

local function appendDependencySubtree(
	lines: { string },
	modulePath: string,
	prefix: string,
	byScriptPath: { [string]: ScriptDependencySummary },
	ancestorSet: { [string]: boolean },
	depth: number
)
	if depth > 12 then
		table.insert(lines, prefix .. "└── ... (max display depth reached)")
		return
	end

	local summary = byScriptPath[modulePath]
	if summary == nil or #summary.dependencies == 0 then
		return
	end

	local totalDeps = #summary.dependencies
	for idx, rec in summary.dependencies do
		local isLast = (idx == totalDeps)
		local branch = if isLast then "└── " else "├── "
		local childPrefix = prefix .. (if isLast then "    " else "│   ")
		local scopeNote = string.format("%s, %s", rec.scopeKind, rec.classification)

		if rec.status == "Resolved" and rec.resolvedModulePath ~= nil then
			local targetPath = rec.resolvedModulePath
			if ancestorSet[targetPath] then
				table.insert(
					lines,
					string.format(
						"%s%s%s [line %d:%d, %s] (CIRCULAR REFERENCE)",
						prefix,
						branch,
						targetPath,
						rec.lineNumber,
						rec.columnNumber,
						scopeNote
					)
				)
			else
				table.insert(
					lines,
					string.format(
						"%s%s%s [line %d:%d, %s]",
						prefix,
						branch,
						targetPath,
						rec.lineNumber,
						rec.columnNumber,
						scopeNote
					)
				)
				local nextAncestors: { [string]: boolean } = {}
				for k, v in ancestorSet do
					nextAncestors[k] = v
				end
				nextAncestors[targetPath] = true
				appendDependencySubtree(lines, targetPath, childPrefix, byScriptPath, nextAncestors, depth + 1)
			end
		else
			table.insert(
				lines,
				string.format(
					"%s%s[UNRESOLVED: %s / %s] require(%s) [line %d:%d]",
					prefix,
					branch,
					rec.status,
					rec.classification,
					rec.rawExpression,
					rec.lineNumber,
					rec.columnNumber
				)
			)
		end
	end
end

function OutputFormatter.formatReport(report: ScanReport): string
	local lines: { string } = {}
	local counts = report.counts
	local depAnalysis = report.dependencyAnalysis
	local execAnalysis = report.executionAnalysis

	table.insert(lines, "")
	table.insert(lines, DIVIDER)
	table.insert(lines, "ILLUSION'S SCRIPTFLOWDISCOVERY")
	table.insert(lines, DIVIDER)
	table.insert(
		lines,
		string.format(
			"Scan Time: %s | Duration: %.2f ms",
			report.timestamp,
			report.durationSeconds * 1000
		)
	)
	table.insert(lines, "")

	-- 1. [SCAN SUMMARY]
	table.insert(lines, "[SCAN SUMMARY]")
	table.insert(lines, string.format("Total Scripts: %d", counts.total))
	table.insert(lines, string.format("  - Script: %d", counts.serverScripts))
	table.insert(lines, string.format("  - LocalScript: %d", counts.localScripts))
	table.insert(lines, string.format("  - ModuleScript: %d", counts.moduleScripts))
	table.insert(
		lines,
		string.format(
			"Executable Status: %d Active (Eligible) | %d Dormant / Disabled",
			counts.executableActive,
			counts.executableDormant
		)
	)
	table.insert(
		lines,
		string.format(
			"Require Calls Found: %d Total (%d Resolved, %d Unresolved/Partial)",
			#depAnalysis.allDependencies,
			#depAnalysis.resolvedDependencies,
			#depAnalysis.unresolvedDependencies
		)
	)
	if counts.inaccessibleSources > 0 then
		table.insert(
			lines,
			string.format("Inaccessible Script Sources: %d (restricted by permissions)", counts.inaccessibleSources)
		)
	end
	table.insert(lines, "")

	-- 2. [EXECUTABLE SCRIPTS]
	table.insert(lines, "[EXECUTABLE SCRIPTS]")
	local execIndex = 0
	for _, scriptInfo in report.scripts do
		if scriptInfo.isExecutable then
			execIndex += 1
			local profile = execAnalysis.profilesByPath[scriptInfo.fullPath]
			local envText = if profile ~= nil then profile.environment else "Unknown"
			local phaseText = if profile ~= nil then profile.phaseLabel else "Unknown"
			local enabledText = if scriptInfo.isEnabled == false then "false (Disabled)" else "true"
			local typeDetail = if scriptInfo.className == "Script"
				then string.format("Script (RunContext: %s)", scriptInfo.runContextName)
				else "LocalScript"
			local actorSuffix = if scriptInfo.isActorDescendant then " | Inside Actor (Parallel Eligible)" else ""

			table.insert(lines, string.format("%d. %s", execIndex, scriptInfo.fullPath))
			table.insert(
				lines,
				string.format("   Name: %s | Type: %s | Kind: %s", scriptInfo.name, typeDetail, scriptInfo.scriptKind)
			)
			table.insert(
				lines,
				string.format("   Parent: %s (%s)", scriptInfo.parentPath, scriptInfo.parentClassName)
			)
			table.insert(
				lines,
				string.format("   Context: %s | Phase: %s", envText, phaseText)
			)
			table.insert(lines, string.format("   Enabled: %s%s", enabledText, actorSuffix))
			if profile ~= nil then
				table.insert(lines, string.format("   Eligibility: %s", profile.eligibilityReason))
			end
			if not scriptInfo.sourceAccessible then
				table.insert(
					lines,
					string.format("   Source Warning: Inaccessible (%s)", scriptInfo.sourceError or "Restricted")
				)
			end
			table.insert(lines, "")
		end
	end
	if execIndex == 0 then
		table.insert(lines, "  (No executable Script or LocalScript instances discovered)")
		table.insert(lines, "")
	end

	-- 3. [MODULE SCRIPTS]
	table.insert(lines, "[MODULE SCRIPTS]")
	local modIndex = 0
	for _, scriptInfo in report.scripts do
		if scriptInfo.isModule then
			modIndex += 1
			local profile = execAnalysis.profilesByPath[scriptInfo.fullPath]
			local summary = depAnalysis.byScriptPath[scriptInfo.fullPath]
			local reqByCount = if summary ~= nil then #summary.requiredByPaths else 0
			local envText = if profile ~= nil then profile.environment else "UnreferencedModule"

			table.insert(lines, string.format("%d. %s", modIndex, scriptInfo.fullPath))
			table.insert(
				lines,
				string.format(
					"   Name: %s | Type: ModuleScript | Kind: %s",
					scriptInfo.name,
					scriptInfo.scriptKind
				)
			)
			table.insert(
				lines,
				string.format("   Parent: %s (%s)", scriptInfo.parentPath, scriptInfo.parentClassName)
			)
			table.insert(
				lines,
				string.format("   Context: %s | Required By: %d script(s)", envText, reqByCount)
			)
			if summary ~= nil and reqByCount > 0 then
				table.insert(
					lines,
					string.format("   Requirers: %s", table.concat(summary.requiredByPaths, ", "))
				)
			end
			if not scriptInfo.sourceAccessible then
				table.insert(
					lines,
					string.format("   Source Warning: Inaccessible (%s)", scriptInfo.sourceError or "Restricted")
				)
			end
			table.insert(lines, "")
		end
	end
	if modIndex == 0 then
		table.insert(lines, "  (No ModuleScript instances discovered)")
		table.insert(lines, "")
	end

	-- 4. [MODULE DEPENDENCIES]
	table.insert(lines, "[MODULE DEPENDENCIES]")
	local hasAnyDependencyTree = false
	for _, scriptInfo in report.scripts do
		local summary = depAnalysis.byScriptPath[scriptInfo.fullPath]
		if summary ~= nil and #summary.dependencies > 0 then
			hasAnyDependencyTree = true
			table.insert(lines, "")
			table.insert(lines, string.format("%s (%s)", scriptInfo.fullPath, scriptInfo.className))
			local ancestorSet: { [string]: boolean } = {
				[scriptInfo.fullPath] = true,
			}
			appendDependencySubtree(lines, scriptInfo.fullPath, "  ", depAnalysis.byScriptPath, ancestorSet, 1)
		end
	end
	if not hasAnyDependencyTree then
		table.insert(lines, "  (No static require() dependencies found)")
	end
	table.insert(lines, "")

	if #depAnalysis.circularChains > 0 then
		table.insert(lines, "[CIRCULAR MODULE DEPENDENCIES DETECTED]")
		table.insert(
			lines,
			"  Note: Cyclic ModuleScript requires work at top level ONLY if the Studio Beta feature 'Luau Modularity: Export Values and Cyclic Requires' is enabled (or if deferred inside functions)."
		)
		for idx, chain in depAnalysis.circularChains do
			table.insert(lines, string.format("  %d. %s", idx, table.concat(chain, " -> ")))
		end
		table.insert(lines, "")
	end

	-- 5. [UNRESOLVED DEPENDENCIES]
	table.insert(lines, "[UNRESOLVED DEPENDENCIES]")
	if #depAnalysis.unresolvedDependencies == 0 then
		table.insert(lines, "  - None (All discovered require() calls resolved statically)")
	else
		for _, rec in depAnalysis.unresolvedDependencies do
			local baseNote = if rec.partialBasePath ~= nil
				then string.format(" [Resolved Base: %s]", rec.partialBasePath)
				else ""
			table.insert(
				lines,
				string.format(
					"  - %s (line %d) [%s]: require(%s)%s -> %s",
					rec.requiringScriptPath,
					rec.lineNumber,
					rec.status,
					rec.rawExpression,
					baseNote,
					rec.failureReason or "Unable to resolve statically"
				)
			)
		end
	end
	table.insert(lines, "")

	-- 6. [EXECUTION ANALYSIS]
	table.insert(lines, "[EXECUTION ANALYSIS]")
	table.insert(lines, SUB_DIVIDER)
	table.insert(lines, "A. KNOWN EXECUTION CONSTRAINTS (Engine Guarantees)")
	if #execAnalysis.knownConstraints == 0 then
		table.insert(lines, "  - No multi-phase or synchronous require constraints detected in current scripts.")
	else
		for _, item in execAnalysis.knownConstraints do
			table.insert(lines, string.format("  * [%s] %s", item.environment, item.title))
			table.insert(lines, string.format("    %s", item.description))
			if #item.relatedScripts > 0 then
				for sIdx, sPath in item.relatedScripts do
					table.insert(lines, string.format("      %d) %s", sIdx, sPath))
				end
			end
		end
	end
	table.insert(lines, "")

	table.insert(lines, "B. POTENTIAL EXECUTION ORDER (Conditional / First-Require Chains)")
	if #execAnalysis.potentialOrders == 0 then
		table.insert(lines, "  - No active executable scripts with resolved ModuleScript initialization chains.")
	else
		for _, item in execAnalysis.potentialOrders do
			table.insert(lines, string.format("  * [%s] %s", item.environment, item.title))
			table.insert(lines, string.format("    %s", item.description))
			for sIdx, sPath in item.relatedScripts do
				table.insert(lines, string.format("      %d -> %s", sIdx, sPath))
			end
		end
	end
	table.insert(lines, "")

	table.insert(lines, "C. UNDETERMINED EXECUTION ORDER (Non-Deterministic Peer Groups)")
	if #execAnalysis.undeterminedGroups == 0 then
		table.insert(
			lines,
			"  - No competing peer executable scripts or multi-caller shared modules in the same phase."
		)
	else
		for _, item in execAnalysis.undeterminedGroups do
			table.insert(lines, string.format("  * [%s] %s", item.environment, item.title))
			table.insert(lines, string.format("    %s", item.description))
			table.insert(lines, string.format("    Peers: %s", table.concat(item.relatedScripts, ", ")))
		end
	end
	table.insert(lines, "")

	table.insert(lines, DIVIDER)
	table.insert(lines, "SCAN COMPLETED")
	table.insert(lines, DIVIDER)

	return table.concat(lines, "\n")
end

function OutputFormatter.printReport(report: ScanReport): string
	local formatted = OutputFormatter.formatReport(report)
	print(formatted)
	return formatted
end

return OutputFormatter
