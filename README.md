# <div align="center"> Illusion's ScriptFlowDiscovery (ISFD) </div>

<div align="center">

![IIASLogo|256x256, 75%](./ISFDLogo.png)
</div>

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

**Illusion's ScriptFlowDiscovery** is a Roblox Studio plugin that helps developers inspect, navigate, and understand the script architecture, `ModuleScript` dependency graph, and execution lifecycle of their Roblox projects.

It combines a non-intrusive static analysis engine with an interactive `Path2D` node-based **Game Architecture Diagram** and a dark IDE-style `DockWidgetPluginGui` interface inside Roblox Studio, plus optional structured console reporting for the Output window.

---

## Key Features

### 1. Interactive Game Architecture Diagram (`Path2D`)
- Accessible directly at the top of the **Overview** page as a GitDiagram-inspired node-based architecture graph.
- Combines two relationship layers in one interactive canvas:
  1. **DataModel Hierarchy**: Services (`[SRV]`), Folders (`[FLD]`), Models (`[MDL]`), Containers (`[CNT]`), `Script` (`[S]`), `LocalScript` (`[L]`), and `ModuleScript` (`[M]`).
  2. **Script Dependencies**: Static, dynamic/loop-expanded, conditional, circular, and unresolved `require()` relationships.
- **Native Roblox `Path2D` Connections**:
  - Uses `Instance.new("Path2D")` and `Path2DControlPoint.new(position, leftTangent, rightTangent)` with `Path2D:SetControlPoints()` to draw smooth cubic Bezier curves with distributed attachment ports, directional arrowheads, and midpoint classification tags (`DYN`, `COND`, `UNRES`, `CYCLE`).
  - Includes a built-in `Path2D` technical validation check (`GraphRenderer.validatePath2DSupport`) inside `DockWidgetPluginGui`.
- **Interactive Navigation & Live Filtering**:
  - **Zoom**: Zoom in/out (`+`/`-`), reset (`100%`), or scroll the mouse wheel to zoom smoothly around the cursor position.
  - **Pan**: Click and drag anywhere on the canvas to pan across large architectures.
  - **Focus & View History**: `Fit Graph`, `Focus Node`, and `Prev View` camera controls.
  - **Expand / Collapse Containers**: Collapse or expand Service/Folder/Model containers (`[-]` / `[+]`) or double-click a container node; edges of collapsed descendants automatically redirect to their visible collapsed ancestor container.
  - **Diagram Search**: Search by instance name, script name, module name, or full path with automatic node highlighting and `Next` match cycling.
  - **Live Visual Filter Toggles**: Toggle `Containers`, `Scripts`, `LocalScripts`, `ModuleScripts`, `Hierarchy`, `Dependencies`, and `Dynamic` edges in real time without rescanning.
  - **Integrated Node Inspector Panel**: Clicking any node highlights its incoming (`REQUIRED BY`) and outgoing (`OUTGOING DEPENDENCIES`) curves and displays its metadata, full copyable path, Studio shortcuts (`Select in Explorer`, `Open Script`, `Inspect in Scripts ->`), and clickable dependency cards.

### 2. Comprehensive Script Discovery
- Traverses the active `DataModel` across services, nested `Folder`s, `Model`s, `Actor`s, and containers while filtering out internal Roblox Studio/Core services (`CoreGui`, `PluginDebugService`, `PluginGuiService`, etc.).
- Discovers all `Script`, `LocalScript`, and `ModuleScript` instances.
- Collects complete metadata for every script:
  - Instance name, `ClassName`, and clean `DataModel` path.
  - Parent instance name, class, and path, plus top-level service name.
  - `RunContext` (`Legacy`, `Server`, `Client`, `Plugin`) and `Enabled` state.
  - Parallel Luau `Actor` ancestry detection.
  - Live source reading via `ScriptEditorService:GetEditorSource()` (with `.Source` fallback) and line counts.

### 3. Advanced Static & Dynamic `require()` Dependency Analysis
- Custom Luau lexical and scoped data-flow analyzer (`tokenizeLuau` + `ScopeFrame` stack) that strips line comments (`--`), multi-line block comments (`--[=[ ... ]=]`), string literals, and interpolated strings while tracking 1-based line and column numbers (`line:col`) and scope kinds (`TopLevel`, `Function`, `Loop`, `Conditional`).
- Resolves static `Instance` paths, modern Roblox **require-by-string** paths, chained local aliases, and **dynamic loop / conditional `require()` patterns**:
  - **Static Instance Paths**:
    - Relative chains (`script.Parent.Module`, `script.Parent.Parent.Shared.Util`)
    - Service lookups (`game:GetService("ReplicatedStorage").Modules.Net`, `game.ReplicatedStorage.Module`, `workspace.Module`)
    - Child & ancestor methods (`:WaitForChild("...")`, `:FindFirstChild("...")`, `:FindFirstChild("...", true)`, `:FindFirstAncestor("...")`)
    - Bracket indexing (`script.Parent["ModuleName"]`)
  - **String Paths (`require("...")` and `require "..."`)**:
    - `@self/`, `./`, `../`, and `@game/` prefixes.
  - **Variables, Chained Aliases & Redefined `require` Functions**:
    - Tracks local variable assignments and collection aliases (`local Modules = ReplicatedStorage:WaitForChild("Modules")`, `local Dependencies = Modules:GetChildren()`) across scopes.
    - Tracks `require` function aliases (`local a = require`, `local b = a`) and resolves both parenthesized calls (`a(script.Module)`) and string-literal calls (`a "./Module"`, `b './Module'`).
  - **Dynamic Loop & Collection `require()` Resolution**:
    - **Generic For Loops**: `for _, module in Folder:GetChildren() do require(module) end`
    - **`ipairs` / `pairs` Loops**: `for _, module in ipairs(Folder:GetChildren()) do require(module) end` and `for _, module in pairs(Modules) do require(module) end`
    - **`GetDescendants()` Loops**: `for _, module in Folder:GetDescendants() do if module:IsA("ModuleScript") then require(module) end end`
    - **Conditional Candidate Narrowing**: Evaluates static guards on loop variables (`module:IsA("ModuleScript")`, `module.ClassName == "ModuleScript"`, `module.Name == "ClientModule"`, `module.Name ~= "..."`, `and`, `or`, `not`) to narrow candidate `ModuleScript` sets accurately.
    - **Nested Container Loops**: `for _, folder in Root:GetChildren() do for _, module in folder:GetChildren() do require(module) end end`
  - **Dependency Classifications**:
    - `Static` — Direct, deterministic single-target `require()`.
    - `DynamicResolved` — Expanded from a statically resolved loop/collection to concrete `ModuleScript` candidates.
    - `DynamicPartial` — Iterable base or prefix resolved, but dynamic child key or empty candidate set prevents full resolution.
    - `Conditional` — Guarded by an `if` / `elseif` / `else` branch or conditional filter.
    - `Unresolved` — Runtime-only expression, external asset ID (`require(123456789)`), or missing instance.
- Automatically detects **circular `ModuleScript` dependency chains** (noting that top-level cyclic `require()` calls work only when the Roblox Studio Beta feature **Luau Modularity: Export Values and Cyclic Requires** is enabled, or when deferred inside functions) and **unreferenced `ModuleScript`s**.

### 4. Execution Context & Lifecycle Order Analysis
- Classifies executable scripts (`Script` and `LocalScript`) and `ModuleScript`s across environments (`Server`, `Client`, `Plugin`, `ServerModule`, `ClientModule`, `SharedModule`, `UnreferencedModule`, `Inactive`).
- Evaluates container eligibility and `RunContext` rules.
- Separates execution ordering into three distinct categories:
  1. **Known Execution Constraints**: Engine-guaranteed lifecycle phase ordering, synchronous top-level `require()` chains, and client-to-server replication boundary violations.
  2. **Potential Execution Order**: Depth-first `ModuleScript` initialization sequences per entry-point script, documenting first-`require()` VM caching and loop/conditional candidate notes.
  3. **Undetermined Execution Order**: Peer startup script groups and multi-caller shared modules whose exact runtime scheduling order is non-deterministic.

---

## Project Structure

```text
.
├── .gitignore
├── LICENCE
├── README.md
└── src/
    ├── IllusionSFD.plugin.luau                 # Studio Plugin entry point
    └── ScriptFlowDiscovery/
        ├── Types.luau                          # Strict shared Luau type definitions (Scan, Dependencies, Graph)
        ├── ScriptDiscovery.luau                # DataModel traversal, metadata & source reader
        ├── DependencyAnalyzer.luau             # Luau tokenizer, scoped data-flow & static/loop require() resolver
        ├── ExecutionAnalyzer.luau              # Execution context, phase & ordering analyzer
        ├── OutputFormatter.luau                # Structured text report formatter for Studio Output
        ├── GraphBuilder.luau                   # Converts ScanReport into a UI-independent GraphModel
        ├── GraphLayout.luau                    # Deterministic layered layout & Path2D Bezier tangent calculator
        ├── GraphRenderer.luau                  # Path2D validation, curve & arrowhead rendering, node pooling
        ├── GraphInteractions.luau              # Zoom, pan, focus, search, live filters & Node Inspector panel
        ├── Theme.luau                          # Dark IDE color palette, fonts & badge visuals
        ├── UIComponents.luau                   # Reusable UI primitives, search/filter bars & Studio actions
        ├── OverviewView.luau                   # Overview dashboard & Game Architecture Diagram host
        ├── ScriptsView.luau                    # Scripts Explorer & Script Details Inspector view
        ├── DependenciesView.luau               # Hierarchical Dependencies Explorer & Call-Site Inspector view
        ├── ExecutionView.luau                  # Execution Analysis view
        ├── MainView.luau                       # Application header, tab navigation & view container
        ├── PluginController.luau               # Toolbar button, DockWidgetPluginGui & scan orchestrator
        └── SelfTest.luau                       # Automated verification suite (14 dependency + 12 graph tests)
```

---

## Installation & Usage

### Installing in Roblox Studio...

#### ...from Creator Store (toolbox)
- click the [following link](https://create.roblox.com/store/asset/86843299608271) to download the plugin directly to Roblox Studio.

#### ...from repo releases
- obtain the .rbxm file from latest releases, and place it in your plugin folder.

#### ...by building the plugin yourself
1. Sync or import the `src` directory into Roblox Studio (for example via [Rojo](https://rojo.space/) or by placing `IllusionSFD.plugin.luau` with the child `ScriptFlowDiscovery` folder inside Studio).
2. In Roblox Studio, right-click `IllusionSFD.plugin` and select **Save as Local Plugin...** (or load it from your Roblox Studio `Plugins` directory).
3. Open the **Plugins** tab in the Studio ribbon and click **Script Flow** under the **Illusion's Script Flow** toolbar section to open the dockable window.

### Running the Built-In Self-Test Suite
To run all 14 dependency resolution tests, 12 graph architecture/layout tests, and the `Path2D` technical validation check inside Roblox Studio's Command Bar:
```luau
local SelfTest = require(game.ServerStorage["Illusion-ScriptFlowDiscovery"].src.ScriptFlowDiscovery.SelfTest)
local summary = SelfTest.runAll()
print(string.format("SelfTest: %d/%d passed (%d failed)", summary.passed, summary.total, summary.failed))
for _, r in summary.results do
	print(if r.passed then "[PASS]" else "[FAIL]", r.name, "-", r.detail)
end
```

---

## Technical Standards

- **Language**: Strictly typed Luau (`--!strict`) compatible with both the standard Luau typechecker and the Luau New Type Solver (`LuauSolverV2`).
- **Safety & Read-Only Guarantee**: Never modifies user scripts or `DataModel` instances, and never executes project code during analysis.
- **Zero External Dependencies**: Built entirely with native Roblox Studio APIs (`Path2D`, `Path2DControlPoint`, `ScriptEditorService`, `DockWidgetPluginGui`) and Luau standard libraries.

---

## License

This project is licensed under the **MIT License**. See [LICENCE](LICENCE) for full license text.
