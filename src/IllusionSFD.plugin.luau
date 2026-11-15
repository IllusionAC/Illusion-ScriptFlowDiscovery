---!strict
--[[
	Illusion's ScriptFlowDiscovery (IllusionSFD.plugin.luau)
	Entry point for the Roblox Studio plugin.

	Collects, analyzes, and prints structured information about the current DataModel:
	- Discovers Script, LocalScript, and ModuleScript instances across all services and nested containers.
	- Analyzes static require() dependencies and resolves target ModuleScripts.
	- Evaluates execution contexts, container eligibility, and known vs. undetermined execution ordering.
	- Provides a Studio toolbar and lightweight DockWidgetPluginGui to scan and rescan the DataModel.
]]

if not plugin then
	warn("[Illusion's ScriptFlowDiscovery] This script must run in the Roblox Studio Plugin context.")
	return
end

local PluginController = require("./ScriptFlowDiscovery/PluginController")

PluginController.initialize(plugin)
