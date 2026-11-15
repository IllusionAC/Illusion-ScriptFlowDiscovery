--!strict
--[[
	UIComponents.luau
	Reusable, strictly typed Roblox Studio IDE UI primitives and helpers.
]]

local Selection = game:GetService("Selection")
local ScriptEditorService = game:GetService("ScriptEditorService")

local Types = require("./Types")
local Theme = require("./Theme")

type ScriptClassName = Types.ScriptClassName
type ResolutionStatus = Types.ResolutionStatus

export type FilterOption = {
	id: string,
	label: string,
}

local UIComponents = {}

function UIComponents.createCorner(parent: GuiObject, radius: number?): UICorner
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius or Theme.Sizes.CornerRadius)
	corner.Parent = parent
	return corner
end

function UIComponents.createStroke(parent: GuiObject, color: Color3?, thickness: number?): UIStroke
	local stroke = Instance.new("UIStroke")
	stroke.Color = color or Theme.Colors.Border
	stroke.Thickness = thickness or 1
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = parent
	return stroke
end

function UIComponents.createPadding(
	parent: GuiObject,
	top: number,
	bottom: number,
	left: number,
	right: number
): UIPadding
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, top)
	pad.PaddingBottom = UDim.new(0, bottom)
	pad.PaddingLeft = UDim.new(0, left)
	pad.PaddingRight = UDim.new(0, right)
	pad.Parent = parent
	return pad
end

function UIComponents.createListLayout(
	parent: GuiObject,
	direction: Enum.FillDirection,
	paddingPx: number,
	hAlign: Enum.HorizontalAlignment?,
	vAlign: Enum.VerticalAlignment?
): UIListLayout
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = direction
	layout.Padding = UDim.new(0, paddingPx)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.HorizontalAlignment = hAlign or Enum.HorizontalAlignment.Left
	layout.VerticalAlignment = vAlign or Enum.VerticalAlignment.Top
	layout.Parent = parent
	return layout
end

function UIComponents.createScrollFrame(
	parent: Instance,
	name: string,
	size: UDim2,
	layoutOrder: number?
): ScrollingFrame
	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = name
	scroll.Size = size
	scroll.LayoutOrder = layoutOrder or 1
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = Theme.Sizes.ScrollBarThickness
	scroll.ScrollBarImageColor3 = Color3.fromRGB(95, 102, 115)
	scroll.CanvasSize = UDim2.fromScale(0, 0)
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.ScrollingDirection = Enum.ScrollingDirection.Y
	scroll.BottomImage = "rbxasset://textures/ui/Scroll/scroll-middle.png"
	scroll.MidImage = "rbxasset://textures/ui/Scroll/scroll-middle.png"
	scroll.TopImage = "rbxasset://textures/ui/Scroll/scroll-middle.png"
	scroll.Parent = parent
	return scroll
end

function UIComponents.createPanel(
	parent: Instance,
	name: string,
	size: UDim2,
	layoutOrder: number?,
	bgColor: Color3?
): Frame
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.Size = size
	frame.LayoutOrder = layoutOrder or 1
	frame.BackgroundColor3 = bgColor or Theme.Colors.PanelBackground
	frame.BorderSizePixel = 0
	frame.Parent = parent
	UIComponents.createCorner(frame, Theme.Sizes.CornerRadius)
	UIComponents.createStroke(frame, Theme.Colors.Border, 1)
	return frame
end

function UIComponents.createSectionHeader(
	parent: Instance,
	title: string,
	rightText: string?,
	layoutOrder: number?
): (Frame, TextLabel, TextLabel)
	local header = Instance.new("Frame")
	header.Name = "SectionHeader_" .. title
	header.Size = UDim2.new(1, 0, 0, 22)
	header.LayoutOrder = layoutOrder or 1
	header.BackgroundTransparency = 1
	header.Parent = parent

	local titleLabel = Instance.new("TextLabel")
	titleLabel.Name = "Title"
	titleLabel.Size = UDim2.new(0.7, 0, 1, 0)
	titleLabel.BackgroundTransparency = 1
	titleLabel.Font = Theme.Fonts.Bold
	titleLabel.TextSize = 13
	titleLabel.TextColor3 = Theme.Colors.TextSecondary
	titleLabel.TextXAlignment = Enum.TextXAlignment.Left
	titleLabel.Text = string.upper(title)
	titleLabel.Parent = header

	local countLabel = Instance.new("TextLabel")
	countLabel.Name = "RightInfo"
	countLabel.Size = UDim2.new(0.3, 0, 1, 0)
	countLabel.Position = UDim2.fromScale(0.7, 0)
	countLabel.BackgroundTransparency = 1
	countLabel.Font = Theme.Fonts.Regular
	countLabel.TextSize = 12
	countLabel.TextColor3 = Theme.Colors.TextMuted
	countLabel.TextXAlignment = Enum.TextXAlignment.Right
	countLabel.Text = rightText or ""
	countLabel.Parent = header

	return header, titleLabel, countLabel
end

function UIComponents.createBadge(
	parent: Instance,
	text: string,
	textColor: Color3,
	bgColor: Color3,
	layoutOrder: number?
): TextLabel
	local badge = Instance.new("TextLabel")
	badge.Name = "Badge"
	badge.LayoutOrder = layoutOrder or 1
	badge.Size = UDim2.fromOffset(0, 18)
	badge.AutomaticSize = Enum.AutomaticSize.X
	badge.BackgroundColor3 = bgColor
	badge.BorderSizePixel = 0
	badge.Font = Theme.Fonts.Bold
	badge.TextSize = 11
	badge.TextColor3 = textColor
	badge.Text = text
	badge.Parent = parent
	UIComponents.createCorner(badge, 3)
	UIComponents.createPadding(badge, 0, 0, 6, 6)
	return badge
end

function UIComponents.createClassBadge(
	parent: Instance,
	className: ScriptClassName,
	compact: boolean?,
	layoutOrder: number?
): TextLabel
	local shortTag, fullLabel, textColor, bgColor = Theme.getClassVisuals(className)
	local text = if compact then shortTag else string.format("%s %s", shortTag, fullLabel)
	return UIComponents.createBadge(parent, text, textColor, bgColor, layoutOrder)
end

function UIComponents.createEnvironmentBadge(
	parent: Instance,
	env: string,
	layoutOrder: number?
): TextLabel
	local label, textColor, bgColor = Theme.getEnvironmentVisuals(env)
	return UIComponents.createBadge(parent, label, textColor, bgColor, layoutOrder)
end

function UIComponents.createResolutionBadge(
	parent: Instance,
	status: ResolutionStatus,
	layoutOrder: number?
): TextLabel
	local label, textColor, bgColor = Theme.getResolutionVisuals(status)
	return UIComponents.createBadge(parent, label, textColor, bgColor, layoutOrder)
end

function UIComponents.createStatCard(
	parent: Instance,
	title: string,
	valueText: string,
	subtitle: string,
	accentColor: Color3,
	layoutOrder: number
): (Frame, TextLabel, TextLabel)
	local card = Instance.new("Frame")
	card.Name = "StatCard_" .. title
	card.LayoutOrder = layoutOrder
	card.BackgroundColor3 = Theme.Colors.PanelBackground
	card.BorderSizePixel = 0
	card.Parent = parent
	UIComponents.createCorner(card, Theme.Sizes.CornerRadius)
	UIComponents.createStroke(card, Theme.Colors.Border, 1)

	local accentBar = Instance.new("Frame")
	accentBar.Name = "AccentBar"
	accentBar.Size = UDim2.new(0, 3, 1, -8)
	accentBar.Position = UDim2.fromOffset(0, 4)
	accentBar.BackgroundColor3 = accentColor
	accentBar.BorderSizePixel = 0
	accentBar.Parent = card
	UIComponents.createCorner(accentBar, 2)

	local content = Instance.new("Frame")
	content.Name = "Content"
	content.Size = UDim2.new(1, -14, 1, -10)
	content.Position = UDim2.fromOffset(10, 5)
	content.BackgroundTransparency = 1
	content.Parent = card

	local titleLabel = Instance.new("TextLabel")
	titleLabel.Name = "Title"
	titleLabel.Size = UDim2.new(1, 0, 0, 14)
	titleLabel.BackgroundTransparency = 1
	titleLabel.Font = Theme.Fonts.SemiBold
	titleLabel.TextSize = 12
	titleLabel.TextColor3 = Theme.Colors.TextSecondary
	titleLabel.TextXAlignment = Enum.TextXAlignment.Left
	titleLabel.TextTruncate = Enum.TextTruncate.AtEnd
	titleLabel.Text = title
	titleLabel.Parent = content

	local valueLabel = Instance.new("TextLabel")
	valueLabel.Name = "Value"
	valueLabel.Size = UDim2.new(1, 0, 0, 22)
	valueLabel.Position = UDim2.fromOffset(0, 15)
	valueLabel.BackgroundTransparency = 1
	valueLabel.Font = Theme.Fonts.Bold
	valueLabel.TextSize = 20
	valueLabel.TextColor3 = Theme.Colors.TextPrimary
	valueLabel.TextXAlignment = Enum.TextXAlignment.Left
	valueLabel.Text = valueText
	valueLabel.Parent = content

	local subLabel = Instance.new("TextLabel")
	subLabel.Name = "Subtitle"
	subLabel.Size = UDim2.new(1, 0, 0, 13)
	subLabel.Position = UDim2.fromOffset(0, 38)
	subLabel.BackgroundTransparency = 1
	subLabel.Font = Theme.Fonts.Regular
	subLabel.TextSize = 11
	subLabel.TextColor3 = Theme.Colors.TextMuted
	subLabel.TextXAlignment = Enum.TextXAlignment.Left
	subLabel.TextTruncate = Enum.TextTruncate.AtEnd
	subLabel.Text = subtitle
	subLabel.Parent = content

	return card, valueLabel, subLabel
end

function UIComponents.createButton(
	parent: Instance,
	text: string,
	size: UDim2,
	isPrimary: boolean,
	layoutOrder: number?,
	onClick: () -> (),
	connections: { RBXScriptConnection }
): TextButton
	local btn = Instance.new("TextButton")
	btn.Name = "Btn_" .. text
	btn.Size = size
	btn.LayoutOrder = layoutOrder or 1
	btn.BackgroundColor3 = if isPrimary then Theme.Colors.AccentBlue else Theme.Colors.ChipBackground
	btn.BorderSizePixel = 0
	btn.AutoButtonColor = true
	btn.Font = if isPrimary then Theme.Fonts.Bold else Theme.Fonts.SemiBold
	btn.TextSize = 13
	btn.TextColor3 = if isPrimary then Theme.Colors.TextOnAccent else Theme.Colors.TextPrimary
	btn.Text = text
	btn.Parent = parent
	UIComponents.createCorner(btn, Theme.Sizes.CornerRadius)
	if not isPrimary then
		UIComponents.createStroke(btn, Theme.Colors.Border, 1)
	end

	table.insert(
		connections,
		btn.Activated:Connect(function()
			onClick()
		end)
	)
	return btn
end

function UIComponents.createSearchInput(
	parent: Instance,
	placeholder: string,
	size: UDim2,
	layoutOrder: number?,
	onChanged: (string) -> (),
	connections: { RBXScriptConnection }
): (Frame, TextBox, () -> ())
	local container = Instance.new("Frame")
	container.Name = "SearchContainer"
	container.Size = size
	container.LayoutOrder = layoutOrder or 1
	container.BackgroundColor3 = Theme.Colors.InputBackground
	container.BorderSizePixel = 0
	container.Parent = parent
	UIComponents.createCorner(container, Theme.Sizes.CornerRadius)
	local stroke = UIComponents.createStroke(container, Theme.Colors.Border, 1)

	local iconLabel = Instance.new("TextLabel")
	iconLabel.Name = "SearchIcon"
	iconLabel.Size = UDim2.new(0, 28, 1, 0)
	iconLabel.BackgroundTransparency = 1
	iconLabel.Font = Theme.Fonts.Bold
	iconLabel.TextSize = 13
	iconLabel.TextColor3 = Theme.Colors.TextMuted
	iconLabel.Text = "🔎"
	iconLabel.Parent = container

	local box = Instance.new("TextBox")
	box.Name = "SearchBox"
	box.Size = UDim2.new(1, -54, 1, 0)
	box.Position = UDim2.fromOffset(28, 0)
	box.BackgroundTransparency = 1
	box.ClearTextOnFocus = false
	box.Font = Theme.Fonts.Regular
	box.TextSize = 13
	box.TextColor3 = Theme.Colors.TextPrimary
	box.PlaceholderText = placeholder
	box.PlaceholderColor3 = Theme.Colors.TextMuted
	box.TextXAlignment = Enum.TextXAlignment.Left
	box.Text = ""
	box.Parent = container

	local clearBtn = Instance.new("TextButton")
	clearBtn.Name = "ClearButton"
	clearBtn.Size = UDim2.new(0, 22, 0, 22)
	clearBtn.Position = UDim2.new(1, -25, 0.5, -11)
	clearBtn.BackgroundTransparency = 1
	clearBtn.Font = Theme.Fonts.Bold
	clearBtn.TextSize = 12
	clearBtn.TextColor3 = Theme.Colors.TextMuted
	clearBtn.Text = "✕"
	clearBtn.Visible = false
	clearBtn.Parent = container

	table.insert(
		connections,
		box.Focused:Connect(function()
			stroke.Color = Theme.Colors.BorderFocus
		end)
	)
	table.insert(
		connections,
		box.FocusLost:Connect(function()
			stroke.Color = Theme.Colors.Border
		end)
	)
	table.insert(
		connections,
		box:GetPropertyChangedSignal("Text"):Connect(function()
			clearBtn.Visible = (box.Text ~= "")
			onChanged(box.Text)
		end)
	)
	table.insert(
		connections,
		clearBtn.Activated:Connect(function()
			box.Text = ""
		end)
	)

	local function resetSearch()
		box.Text = ""
	end

	return container, box, resetSearch
end

function UIComponents.createFilterBar(
	parent: Instance,
	labelText: string,
	options: { FilterOption },
	initialId: string,
	layoutOrder: number?,
	onSelect: (string) -> (),
	connections: { RBXScriptConnection }
): (Frame, (string) -> ())
	local bar = Instance.new("Frame")
	bar.Name = "FilterBar_" .. labelText
	bar.Size = UDim2.new(1, 0, 0, 26)
	bar.AutomaticSize = Enum.AutomaticSize.Y
	bar.LayoutOrder = layoutOrder or 1
	bar.BackgroundTransparency = 1
	bar.Parent = parent

	local layout = UIComponents.createListLayout(
		bar,
		Enum.FillDirection.Horizontal,
		6,
		Enum.HorizontalAlignment.Left,
		Enum.VerticalAlignment.Center
	)
	layout.Wraps = true

	if labelText ~= "" then
		local lbl = Instance.new("TextLabel")
		lbl.Name = "FilterLabel"
		lbl.LayoutOrder = 0
		lbl.Size = UDim2.fromOffset(0, 24)
		lbl.AutomaticSize = Enum.AutomaticSize.X
		lbl.BackgroundTransparency = 1
		lbl.Font = Theme.Fonts.SemiBold
		lbl.TextSize = 12
		lbl.TextColor3 = Theme.Colors.TextMuted
		lbl.TextXAlignment = Enum.TextXAlignment.Left
		lbl.Text = labelText .. ":"
		lbl.Parent = bar
		UIComponents.createPadding(lbl, 0, 0, 0, 4)
	end

	local chipButtons: { [string]: TextButton } = {}
	local currentSelectedId = initialId

	local function updateActiveStyles(selectedId: string)
		currentSelectedId = selectedId
		for id, btn in chipButtons do
			local isSelected = (id == selectedId)
			btn.BackgroundColor3 = if isSelected
				then Theme.Colors.ChipActiveBackground
				else Theme.Colors.ChipBackground
			btn.TextColor3 = if isSelected then Theme.Colors.TextOnAccent else Theme.Colors.TextSecondary
			btn.Font = if isSelected then Theme.Fonts.Bold else Theme.Fonts.Regular
		end
	end

	for idx, opt in options do
		local chip = Instance.new("TextButton")
		chip.Name = "Chip_" .. opt.id
		chip.LayoutOrder = idx
		chip.Size = UDim2.fromOffset(0, 24)
		chip.AutomaticSize = Enum.AutomaticSize.X
		chip.BorderSizePixel = 0
		chip.AutoButtonColor = true
		chip.TextSize = 12
		chip.Text = opt.label
		chip.Parent = bar
		UIComponents.createCorner(chip, 4)
		UIComponents.createPadding(chip, 2, 2, 9, 9)

		chipButtons[opt.id] = chip
		table.insert(
			connections,
			chip.Activated:Connect(function()
				if currentSelectedId ~= opt.id then
					updateActiveStyles(opt.id)
					onSelect(opt.id)
				end
			end)
		)
	end

	updateActiveStyles(initialId)

	local function setSelectionSilent(newId: string)
		updateActiveStyles(newId)
	end

	return bar, setSelectionSilent
end

function UIComponents.createCopyPathBox(
	parent: Instance,
	initialPath: string,
	layoutOrder: number?,
	connections: { RBXScriptConnection }
): (Frame, (string) -> ())
	local currentPath = initialPath

	local container = Instance.new("Frame")
	container.Name = "CopyPathContainer"
	container.Size = UDim2.new(1, 0, 0, 26)
	container.LayoutOrder = layoutOrder or 1
	container.BackgroundColor3 = Theme.Colors.InputBackground
	container.BorderSizePixel = 0
	container.Parent = parent
	UIComponents.createCorner(container, Theme.Sizes.CornerRadius)
	UIComponents.createStroke(container, Theme.Colors.BorderSubtle, 1)

	local pathBox = Instance.new("TextBox")
	pathBox.Name = "PathBox"
	pathBox.Size = UDim2.new(1, -68, 1, 0)
	pathBox.Position = UDim2.fromOffset(8, 0)
	pathBox.BackgroundTransparency = 1
	pathBox.ClearTextOnFocus = false
	pathBox.TextEditable = false
	pathBox.Font = Theme.Fonts.Mono
	pathBox.TextSize = 12
	pathBox.TextColor3 = Theme.Colors.TextSecondary
	pathBox.TextXAlignment = Enum.TextXAlignment.Left
	pathBox.TextTruncate = Enum.TextTruncate.AtEnd
	pathBox.Text = initialPath
	pathBox.Parent = container

	local copyBtn = Instance.new("TextButton")
	copyBtn.Name = "CopyBtn"
	copyBtn.Size = UDim2.new(0, 56, 1, -4)
	copyBtn.Position = UDim2.new(1, -58, 0, 2)
	copyBtn.BackgroundColor3 = Theme.Colors.ChipBackground
	copyBtn.BorderSizePixel = 0
	copyBtn.Font = Theme.Fonts.SemiBold
	copyBtn.TextSize = 11
	copyBtn.TextColor3 = Theme.Colors.TextPrimary
	copyBtn.Text = "Copy"
	copyBtn.Parent = container
	UIComponents.createCorner(copyBtn, 3)

	table.insert(
		connections,
		copyBtn.Activated:Connect(function()
			pathBox:CaptureFocus()
			pathBox.SelectionStart = 1
			pathBox.CursorPosition = #currentPath + 1

			copyBtn.Text = "Selected"
			copyBtn.BackgroundColor3 = Theme.Colors.SuccessBg
			copyBtn.TextColor3 = Theme.Colors.SuccessText

			task.delay(1.2, function()
				if copyBtn.Parent ~= nil then
					copyBtn.Text = "Copy"
					copyBtn.BackgroundColor3 = Theme.Colors.ChipBackground
					copyBtn.TextColor3 = Theme.Colors.TextPrimary
				end
			end)
		end)
	)

	local function setPath(newPath: string)
		currentPath = newPath
		pathBox.Text = newPath
	end

	return container, setPath
end

function UIComponents.createKeyValueRow(
	parent: Instance,
	keyText: string,
	valueText: string,
	valueColor: Color3?,
	layoutOrder: number?
): (Frame, TextLabel)
	local row = Instance.new("Frame")
	row.Name = "KV_" .. keyText
	row.Size = UDim2.new(1, 0, 0, 18)
	row.AutomaticSize = Enum.AutomaticSize.Y
	row.LayoutOrder = layoutOrder or 1
	row.BackgroundTransparency = 1
	row.Parent = parent

	local keyLabel = Instance.new("TextLabel")
	keyLabel.Name = "Key"
	keyLabel.Size = UDim2.new(0, 118, 0, 18)
	keyLabel.BackgroundTransparency = 1
	keyLabel.Font = Theme.Fonts.SemiBold
	keyLabel.TextSize = 12
	keyLabel.TextColor3 = Theme.Colors.TextMuted
	keyLabel.TextXAlignment = Enum.TextXAlignment.Left
	keyLabel.TextYAlignment = Enum.TextYAlignment.Top
	keyLabel.Text = keyText
	keyLabel.Parent = row

	local valLabel = Instance.new("TextLabel")
	valLabel.Name = "Value"
	valLabel.Size = UDim2.new(1, -122, 0, 18)
	valLabel.Position = UDim2.fromOffset(122, 0)
	valLabel.AutomaticSize = Enum.AutomaticSize.Y
	valLabel.BackgroundTransparency = 1
	valLabel.Font = Theme.Fonts.Regular
	valLabel.TextSize = 13
	valLabel.TextColor3 = valueColor or Theme.Colors.TextPrimary
	valLabel.TextXAlignment = Enum.TextXAlignment.Left
	valLabel.TextYAlignment = Enum.TextYAlignment.Top
	valLabel.TextWrapped = true
	valLabel.Text = valueText
	valLabel.Parent = row

	return row, valLabel
end

function UIComponents.createEmptyState(
	parent: Instance,
	title: string,
	subtitle: string,
	layoutOrder: number?
): Frame
	local box = Instance.new("Frame")
	box.Name = "EmptyState"
	box.Size = UDim2.new(1, 0, 0, 84)
	box.LayoutOrder = layoutOrder or 1
	box.BackgroundColor3 = Theme.Colors.PanelBackground
	box.BorderSizePixel = 0
	box.Parent = parent
	UIComponents.createCorner(box, Theme.Sizes.CornerRadius)
	UIComponents.createStroke(box, Theme.Colors.BorderSubtle, 1)

	local titleLbl = Instance.new("TextLabel")
	titleLbl.Name = "Title"
	titleLbl.Size = UDim2.new(1, -24, 0, 20)
	titleLbl.Position = UDim2.fromOffset(12, 20)
	titleLbl.BackgroundTransparency = 1
	titleLbl.Font = Theme.Fonts.Bold
	titleLbl.TextSize = 14
	titleLbl.TextColor3 = Theme.Colors.TextSecondary
	titleLbl.Text = title
	titleLbl.Parent = box

	local subLbl = Instance.new("TextLabel")
	subLbl.Name = "Subtitle"
	subLbl.Size = UDim2.new(1, -24, 0, 32)
	subLbl.Position = UDim2.fromOffset(12, 42)
	subLbl.BackgroundTransparency = 1
	subLbl.Font = Theme.Fonts.Regular
	subLbl.TextSize = 12
	subLbl.TextColor3 = Theme.Colors.TextMuted
	subLbl.TextWrapped = true
	subLbl.Text = subtitle
	subLbl.Parent = box

	return box
end

function UIComponents.selectInstanceInStudio(target: Instance?): boolean
	if target == nil then
		return false
	end
	local ok = pcall(function()
		Selection:Set({ target })
	end)
	return ok
end

function UIComponents.openScriptInStudio(
	scriptInstance: LuaSourceContainer?,
	lineNumber: number?
)
	if scriptInstance == nil then
		return
	end
	local targetScript = scriptInstance
	local targetLine = lineNumber or 1
	task.spawn(function()
		local ok, opened = pcall(function(): boolean
			local success = ScriptEditorService:OpenScriptDocumentAsync(targetScript)
			return success == true
		end)
		if ok and opened and targetLine > 0 then
			pcall(function()
				local doc = ScriptEditorService:FindScriptDocument(targetScript)
				if doc then
					doc:RequestSetSelectionAsync(targetLine, 1, targetLine, 1)
				end
			end)
		end
	end)
end

return UIComponents
