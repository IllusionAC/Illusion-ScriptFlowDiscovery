--!strict
--[[
	PluginController.luau
	Manages the Roblox Studio plugin lifecycle, toolbar buttons, DockWidgetPluginGui,
	MainView interactive UI, and orchestrates DataModel scans.
]]

local Types = require("./Types")
local ScriptDiscovery = require("./ScriptDiscovery")
local DependencyAnalyzer = require("./DependencyAnalyzer")
local ExecutionAnalyzer = require("./ExecutionAnalyzer")
local OutputFormatter = require("./OutputFormatter")
local MainView = require("./MainView")

type ScanOptions = Types.ScanOptions
type ScanReport = Types.ScanReport

export type ControllerInstance = {
	runScan: () -> ScanReport,
	destroy: () -> (),
}

local PluginController = {}

local WIDGET_ID = "IllusionScriptFlowDiscovery_DockWidget_v2"
local TOOLBAR_NAME = "Illusion's Script Flow"

function PluginController.executeScan(options: ScanOptions): ScanReport
	local startClock = os.clock()
	local timestamp = os.date("%Y-%m-%d %H:%M:%S")

	local discoveredScripts, counts = ScriptDiscovery.discoverScripts(options)
	local dependencyAnalysis = DependencyAnalyzer.analyzeAll(discoveredScripts, options.root)
	local executionAnalysis = ExecutionAnalyzer.analyzeExecution(discoveredScripts, dependencyAnalysis, counts)

	local durationSeconds = math.max(0, os.clock() - startClock)

	local report: ScanReport = {
		timestamp = timestamp,
		durationSeconds = durationSeconds,
		options = options,
		scripts = discoveredScripts,
		counts = counts,
		dependencyAnalysis = dependencyAnalysis,
		executionAnalysis = executionAnalysis,
	}

	return report
end

function PluginController.initialize(pluginInstance: Plugin): ControllerInstance
	local connections: { RBXScriptConnection } = {}
	local isScanning = false
	local lastReport: ScanReport? = nil

	local toolbar = pluginInstance:CreateToolbar(TOOLBAR_NAME)

	local toggleWidgetButton = toolbar:CreateButton(
		"ScriptFlowPanel",
		"Open or close Illusion's ScriptFlowDiscovery interface",
		"rbxassetid://124401899497822",
		"Script Flow"
	)
	toggleWidgetButton.ClickableWhenViewportHidden = true
	
	local widgetInfo = DockWidgetPluginGuiInfo.new(
		Enum.InitialDockState.Float,
		false,
		false,
		920,
		640,
		520,
		360
	)

	local dockWidget = pluginInstance:CreateDockWidgetPluginGuiAsync(WIDGET_ID, widgetInfo)
	dockWidget.Title = "Illusion's ScriptFlowDiscovery"
	dockWidget.Name = "IllusionScriptFlowDiscovery"
	dockWidget.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	local triggerScan: () -> ScanReport

	local mainView = MainView.create(dockWidget, {
		onRequestRescan = function()
			triggerScan()
		end,
		onRequestPrintOutput = function()
			if lastReport ~= nil then
				OutputFormatter.printReport(lastReport)
			else
				local rep = triggerScan()
				OutputFormatter.printReport(rep)
			end
		end,
	})

	local function syncToolbarSelection()
		toggleWidgetButton:SetActive(dockWidget.Enabled)
	end
	syncToolbarSelection()

	triggerScan = function(): ScanReport
		if isScanning and lastReport ~= nil then
			return lastReport
		end

		isScanning = true
		mainView.setScanningState(true)

		local options: ScanOptions = {
			root = game,
		}

		local report = PluginController.executeScan(options)
		lastReport = report

		mainView.updateReport(report)
		mainView.setScanningState(false)
		isScanning = false

		return report
	end

	-- Perform initial scan so the UI is populated immediately when opened
	triggerScan()

	table.insert(
		connections,
		toggleWidgetButton.Click:Connect(function()
			dockWidget.Enabled = not dockWidget.Enabled
			syncToolbarSelection()
			if dockWidget.Enabled and lastReport == nil then
				triggerScan()
			end
		end)
	)

	table.insert(
		connections,
		dockWidget:GetPropertyChangedSignal("Enabled"):Connect(function()
			syncToolbarSelection()
		end)
	)

	local function destroy()
		for _, conn in connections do
			conn:Disconnect()
		end
		table.clear(connections)
		mainView.destroy()
		dockWidget:Destroy()
	end

	table.insert(
		connections,
		pluginInstance.Unloading:Connect(function()
			destroy()
		end)
	)

	return {
		runScan = triggerScan,
		destroy = destroy,
	}
end

return PluginController
