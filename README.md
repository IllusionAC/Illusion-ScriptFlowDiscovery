# <div align="center"> Illusion's ScriptFlowDiscovery (ISFD) </div>

<div align="center">

![IIASLogo|256x256, 75%](./ISFDLogo.png)
</div>

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

**Illusion's ScriptFlowDiscovery** is a Roblox Studio plugin that helps developers inspect, navigate, and understand the script architecture, `ModuleScript` dependency graph, and execution lifecycle of their Roblox projects.

It combines a non-intrusive static analysis engine with a dark IDE-style `DockWidgetPluginGui` interface inside Roblox Studio, plus optional structured console reporting for the Output window.

---

## Key Features

### 1. Comprehensive Script Discovery
- Traverses the active `DataModel` across services, nested `Folder`s, `Model`s, `Actor`s, and containers while filtering out internal Roblox Studio/Core services (`CoreGui`, `PluginDebugService`, `PluginGuiService`, etc.).
- Discovers all `Script`, `LocalScript`, and `ModuleScript` instances.
- Collects complete metadata for every script:
  - Instance name, `ClassName`, and clean `DataModel` path.
  - Parent instance name, class, and path, plus top-level service name.
  - `RunContext` (`Legacy`, `Server`, `Client`, `Plugin`) and `Enabled` state.
  - Parallel Luau `Actor` ancestry detection.
  - Live source reading via `ScriptEditorService:GetEditorSource()` (with `.Source` fallback) and line counts.

### 2. Static `require()` Dependency Analysis
- Custom Luau lexical scanner (`tokenizeLuau`) that strips line comments (`--`), multi-line block comments (`--[=[ ... ]=]`), string literals, and interpolated strings so commented-out `require()` calls are never falsely reported.
- Tracks block depth (`function`, `if ... then`, `for ... do`, `while ... do`, `repeat ... until`, `do ... end`) to distinguish **top-level synchronous requires** from **deferred inner-scope requires**.
- Resolves both traditional `Instance` paths and modern Roblox **require-by-string** paths:
  - **Instance Paths**:
    - Relative chains (`script.Parent.Module`, `script.Parent.Parent.Shared.Util`)
    - Service lookups (`game:GetService("ReplicatedStorage").Modules.Net`, `game.ReplicatedStorage.Module`, `workspace.Module`)
    - Child & ancestor methods (`:WaitForChild("...")`, `:FindFirstChild("...")`, `:FindFirstChild("...", true)`, `:FindFirstAncestor("...")`)
    - Bracket indexing (`script.Parent["ModuleName"]`)
  - **String Paths (`require("...")` and `require "..."`)**:
    - `@self/` — resolves starting at the current `script` instance (`require("@self/ChildModule")`)
    - `./` — resolves starting at `script.Parent` (`require("./SiblingModule")`)
    - `../` — resolves starting at `script.Parent.Parent` with support for chained `..` segments (`require("../../Shared/MathUtil")`)
    - `@game/` — resolves starting at the `DataModel` root `game` (`require("@game/ReplicatedStorage/SharedModule")`)
  - **Static Local Aliases**:
    - Tracks single-assignment top-level local variables (`local Modules = ReplicatedStorage:WaitForChild("Modules")` or `local PATH = "./MyModule"`) and resolves `require()` calls that reference them.
  - **Numeric Asset IDs & Dynamic Expressions**:
    - Identifies numeric asset requires (`require(123456789)`) as external cloud `ModuleScript` assets (`rbxassetid://123456789`).
    - Reports dynamic variables, function calls, and missing child segments as **Partially Resolved** (preserving the resolved base path) or **Unresolved** with diagnostic explanations—never fabricating targets.
- Automatically detects **circular `ModuleScript` dependency chains** and **unreferenced `ModuleScript`s**.

### 3. Execution Context & Lifecycle Order Analysis
- Classifies executable scripts (`Script` and `LocalScript`) and `ModuleScript`s across environments (`Server`, `Client`, `Plugin`, `ServerModule`, `ClientModule`, `SharedModule`, `UnreferencedModule`, `Inactive`).
- Evaluates container eligibility (e.g., `ServerScriptService`, `Workspace`, `ReplicatedFirst`, `StarterPlayerScripts`, `StarterCharacterScripts`, `StarterGui`, `StarterPack`) and `RunContext` rules.
- Separates execution ordering into three distinct categories:
  1. **Known Execution Constraints**: Engine-guaranteed lifecycle phase ordering (such as `ReplicatedFirst` before `StarterPlayerScripts`, server initialization before character spawn scripts), synchronous top-level `require()` chains, and client-to-server replication boundary violations.
  2. **Potential Execution Order**: Depth-first `ModuleScript` initialization sequences per entry-point script, documenting first-`require()` VM caching conditions.
  3. **Undetermined Execution Order**: Peer startup script groups and multi-caller shared modules whose exact runtime scheduling order is non-deterministic.

### 4. Interactive Studio Interface (`DockWidgetPluginGui`)
- **Compact Header**: Displays scan status (`READY` / `SCANNING...`), last scan timestamp and duration, a **Print Log** button (for Output window reporting), and a **Rescan** button.
- **Overview Tab**:
  - 9 dynamic statistics cards (Total Scripts, Scripts, LocalScripts, ModuleScripts, Active Executables, Dormant/Disabled, Total `require()` Calls, Resolved Dependencies, Unresolved Dependencies).
  - Dependency Summary highlighting the most frequently required `ModuleScript`s, unreferenced modules, circular dependency counts, and one-click navigation to unresolved calls.
  - Recent Scan Information panel.
- **Scripts Explorer Tab**:
  - Search by script name or full `DataModel` path.
  - Combine filters across **Type** (`All`, `Script`, `LocalScript`, `ModuleScript`), **Context** (`All`, `Server`, `Client`, `Shared`, `Plugin`, `Dormant / Unref`), and **State** (`All`, `Enabled / Active`, `Disabled / Dormant`).
  - Paginated script table paired with a **Script Details Inspector** featuring copyable full paths, **Select in Explorer** (`Selection:Set`), **Open in Editor** (`ScriptEditorService:OpenScriptDocumentAsync`), full metadata, and interactive **Requires Modules** / **Required By** lists.
- **Dependencies Tab**:
  - Expandable/collapsible hierarchical dependency tree with `Expand All` and `Collapse All` controls.
  - Filter by **Resolution** (`All`, `Resolved`, `Unresolved / Partial`), **Origin** (`All Origins`, `From Script`, `From LocalScript`, `From ModuleScript`), and text search.
  - Circular dependency warning banner and inline `CIRCULAR` badges.
  - **Dependency Details Inspector** showing caller, target module, call-site line number, scope (`top-level` vs `fn-scope`), diagnostic reason, and direct jump-to-line in the Studio Script Editor.
- **Execution Analysis Tab**:
  - Expandable sections for **Known Execution Constraints**, **Potential Execution Order**, and **Undetermined Execution Order**, filterable by category, environment, and search query, with clickable step chains that navigate directly to any script.

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
        ├── Types.luau                          # Strict shared Luau type definitions
        ├── ScriptDiscovery.luau                # DataModel traversal, metadata & source reader
        ├── DependencyAnalyzer.luau             # Luau tokenizer & static require() resolver
        ├── ExecutionAnalyzer.luau              # Execution context, phase & ordering analyzer
        ├── OutputFormatter.luau                # Structured text report formatter for Studio Output
        ├── Theme.luau                          # Dark IDE color palette, fonts & badge visuals
        ├── UIComponents.luau                   # Reusable UI primitives, search/filter bars & Studio actions
        ├── OverviewView.luau                   # Overview dashboard view
        ├── ScriptsView.luau                    # Scripts Explorer & Script Details Inspector view
        ├── DependenciesView.luau               # Hierarchical Dependencies Explorer & Edge Inspector view
        ├── ExecutionView.luau                  # Execution Analysis view
        ├── MainView.luau                       # Application header, tab navigation & view container
        └── PluginController.luau               # Toolbar button, DockWidgetPluginGui & scan orchestrator
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

### Using the Interface
1. Click **Rescan** in the top-right corner of the widget at any time to re-analyze the current `DataModel`.
2. Switch between **Overview**, **Scripts**, **Dependencies**, and **Execution Analysis** using the navigation bar.
3. Click any script, module, or dependency relationship across any view to inspect its metadata, select it in the Studio Explorer, or open it at the exact `require()` line in the Script Editor.
4. Click **Print Log** in the header if you also want a formatted plain-text report printed to the Roblox Studio **Output** window.

---

## Technical Standards

- **Language**: Strictly typed Luau (`--!strict`) compatible with both the standard Luau typechecker and the Luau New Type Solver (`LuauSolverV2`).
- **Safety & Read-Only Guarantee**: Never modifies user scripts or `DataModel` instances, and never executes project code during analysis.
- **Zero External Dependencies**: Built entirely with native Roblox Studio APIs and Luau standard libraries.

---

## License

This project is licensed under the **MIT License**. See [LICENCE](LICENCE) for full license text.
