--!strict
--[[
	DependencyAnalyzer.luau
	Performs static lexical, syntactic, and scoped data-flow analysis of Luau script
	sources to discover require() calls, resolve static and dynamic/loop Instance and
	ModuleScript paths against the DataModel, evaluate static conditional guards,
	and classify all dependency relationships.
]]

local Types = require("./Types")
local ScriptDiscovery = require("./ScriptDiscovery")

type DiscoveredScript = Types.DiscoveredScript
type DependencyRecord = Types.DependencyRecord
type ResolutionStatus = Types.ResolutionStatus
type DependencyClassification = Types.DependencyClassification
type RequireScopeKind = Types.RequireScopeKind
type ScriptDependencySummary = Types.ScriptDependencySummary
type DependencyAnalysisResult = Types.DependencyAnalysisResult

type TokenKind = "Identifier" | "Keyword" | "String" | "InterpolatedString" | "Number" | "Symbol"

export type Token = {
	kind: TokenKind,
	value: string,
	line: number,
	column: number,
	rawStart: number,
	rawEnd: number,
	blockDepth: number,
}

type PathEvalResult = {
	status: ResolutionStatus,
	instance: Instance?,
	partialBasePath: string?,
	failureReason: string?,
	usedAlias: string?,
}

type CollectionSourceKind =
	"GetChildren"
	| "GetDescendants"
	| "TableLiteral"
	| "InstanceChildren"
	| "Unknown"

type CollectionEvalResult = {
	status: ResolutionStatus,
	instances: { Instance },
	basePath: string?,
	sourceKind: CollectionSourceKind,
	failureReason: string?,
	usedAlias: string?,
}

type ScopeFrameKind = "Function" | "Loop" | "Conditional" | "DoBlock"

type ScopeFrame = {
	frameKind: ScopeFrameKind,
	loopVarName: string?,
	loopKeyVarName: string?,
	loopEval: CollectionEvalResult?,
	condStartIdx: number?,
	condEndIdx: number?,
	condRawText: string?,
	isElseBranch: boolean?,
}

local DependencyAnalyzer = {}

local KEYWORDS: { [string]: boolean } = {
	["and"] = true,
	["break"] = true,
	["do"] = true,
	["else"] = true,
	["elseif"] = true,
	["end"] = true,
	["false"] = true,
	["for"] = true,
	["function"] = true,
	["if"] = true,
	["in"] = true,
	["local"] = true,
	["nil"] = true,
	["not"] = true,
	["or"] = true,
	["repeat"] = true,
	["return"] = true,
	["then"] = true,
	["true"] = true,
	["until"] = true,
	["while"] = true,
}

local function isAlpha(byte: number): boolean
	return (byte >= 65 and byte <= 90) or (byte >= 97 and byte <= 122) or byte == 95
end

local function isDigit(byte: number): boolean
	return byte >= 48 and byte <= 57
end

local function isAlphaNumeric(byte: number): boolean
	return isAlpha(byte) or isDigit(byte)
end

-- Checks if source at index `pos` starts a Luau long bracket `[==[`; returns content start and equals count
local function matchLongBracketOpen(source: string, pos: number): (number?, number)
	local len = #source
	if pos > len or string.byte(source, pos) ~= 91 then -- '['
		return nil, 0
	end
	local eqCount = 0
	local cursor = pos + 1
	while cursor <= len and string.byte(source, cursor) == 61 do -- '='
		eqCount += 1
		cursor += 1
	end
	if cursor <= len and string.byte(source, cursor) == 91 then -- '['
		return cursor + 1, eqCount
	end
	return nil, 0
end

-- Scans until matching closing long bracket `]==]`, updating line count and lineStartPos
local function scanLongBracketClose(
	source: string,
	startPos: number,
	eqCount: number,
	startLine: number,
	initialLineStartPos: number
): (number, number, number, string)
	local len = #source
	local cursor = startPos
	local line = startLine
	local lineStartPos = initialLineStartPos

	while cursor <= len do
		local b = string.byte(source, cursor)
		if b == 10 then -- '\n'
			line += 1
			lineStartPos = cursor + 1
			cursor += 1
		elseif b == 93 then -- ']'
			local check = cursor + 1
			local matchedEq = 0
			while matchedEq < eqCount and check <= len and string.byte(source, check) == 61 do
				matchedEq += 1
				check += 1
			end
			if matchedEq == eqCount and check <= len and string.byte(source, check) == 93 then
				local content = string.sub(source, startPos, cursor - 1)
				return check + 1, line, lineStartPos, content
			end
			cursor += 1
		else
			cursor += 1
		end
	end

	local remaining = string.sub(source, startPos, len)
	return len + 1, line, lineStartPos, remaining
end

local function pushToken(list: { Token }, tok: Token)
	table.insert(list, tok)
end

local function pushRecord(list: { DependencyRecord }, rec: DependencyRecord)
	table.insert(list, rec)
end

local function pushScopeFrame(stack: { ScopeFrame }, frame: ScopeFrame)
	table.insert(stack, frame)
end

function DependencyAnalyzer.tokenizeLuau(source: string): { Token }
	local tokens: { Token } = {}
	local len = #source
	local pos = 1
	local line = 1
	local lineStartPos = 1
	local blockDepth = 0
	local pendingLoopHeader = false

	while pos <= len do
		local b = string.byte(source, pos)

		-- Whitespace
		if b == 32 or b == 9 or b == 13 or b == 10 then
			if b == 10 then
				line += 1
				lineStartPos = pos + 1
			end
			pos += 1

		-- Comment: `--`
		elseif b == 45 and pos + 1 <= len and string.byte(source, pos + 1) == 45 then
			local commentStart = pos + 2
			local longStart, eqCount = matchLongBracketOpen(source, commentStart)
			if longStart ~= nil then
				local nextPos, nextLine, nextLineStart, _ =
					scanLongBracketClose(source, longStart, eqCount, line, lineStartPos)
				pos = nextPos
				line = nextLine
				lineStartPos = nextLineStart
			else
				pos = commentStart
				while pos <= len and string.byte(source, pos) ~= 10 do
					pos += 1
				end
			end

		-- Long string literal `[=[ ... ]=]`
		elseif b == 91 and (pos + 1 <= len and (string.byte(source, pos + 1) == 91 or string.byte(source, pos + 1) == 61)) then
			local longStart, eqCount = matchLongBracketOpen(source, pos)
			if longStart ~= nil then
				local rawStart = pos
				local tokenLine = line
				local tokenCol = rawStart - lineStartPos + 1
				local nextPos, nextLine, nextLineStart, content =
					scanLongBracketClose(source, longStart, eqCount, line, lineStartPos)
				pushToken(tokens, {
					kind = "String",
					value = content,
					line = tokenLine,
					column = tokenCol,
					rawStart = rawStart,
					rawEnd = nextPos - 1,
					blockDepth = blockDepth,
				})
				pos = nextPos
				line = nextLine
				lineStartPos = nextLineStart
			else
				pushToken(tokens, {
					kind = "Symbol",
					value = "[",
					line = line,
					column = pos - lineStartPos + 1,
					rawStart = pos,
					rawEnd = pos,
					blockDepth = blockDepth,
				})
				pos += 1
			end

		-- Quoted string literal `"..."` or `'...'`
		elseif b == 34 or b == 39 then
			local quoteByte = b
			local rawStart = pos
			local tokenLine = line
			local tokenCol = rawStart - lineStartPos + 1
			pos += 1
			local chars: { string } = {}
			while pos <= len do
				local cb = string.byte(source, pos)
				if cb == 92 then -- '\' escape
					if pos + 1 <= len then
						local nextByte = string.byte(source, pos + 1)
						if nextByte == 10 then
							line += 1
							lineStartPos = pos + 2
						end
						table.insert(chars, string.sub(source, pos + 1, pos + 1))
						pos += 2
					else
						pos += 1
					end
				elseif cb == quoteByte then
					pos += 1
					break
				elseif cb == 10 then
					line += 1
					lineStartPos = pos + 1
					pos += 1
					break
				else
					table.insert(chars, string.sub(source, pos, pos))
					pos += 1
				end
			end
			pushToken(tokens, {
				kind = "String",
				value = table.concat(chars),
				line = tokenLine,
				column = tokenCol,
				rawStart = rawStart,
				rawEnd = pos - 1,
				blockDepth = blockDepth,
			})

		-- Interpolated string literal `` `...` ``
		elseif b == 96 then
			local rawStart = pos
			local tokenLine = line
			local tokenCol = rawStart - lineStartPos + 1
			pos += 1
			while pos <= len do
				local cb = string.byte(source, pos)
				if cb == 92 then
					pos += 2
				elseif cb == 96 then
					pos += 1
					break
				elseif cb == 10 then
					line += 1
					lineStartPos = pos + 1
					pos += 1
				else
					pos += 1
				end
			end
			pushToken(tokens, {
				kind = "InterpolatedString",
				value = string.sub(source, rawStart, pos - 1),
				line = tokenLine,
				column = tokenCol,
				rawStart = rawStart,
				rawEnd = pos - 1,
				blockDepth = blockDepth,
			})

		-- Identifier or Keyword
		elseif isAlpha(b) then
			local rawStart = pos
			local tokenCol = rawStart - lineStartPos + 1
			pos += 1
			while pos <= len and isAlphaNumeric(string.byte(source, pos)) do
				pos += 1
			end
			local word = string.sub(source, rawStart, pos - 1)
			local isKw = KEYWORDS[word] == true
			local tokenBlockDepth = blockDepth

			if isKw then
				if word == "for" or word == "while" then
					pendingLoopHeader = true
					blockDepth += 1
				elseif word == "do" then
					if pendingLoopHeader then
						pendingLoopHeader = false
					else
						blockDepth += 1
					end
				elseif word == "function" or word == "then" or word == "repeat" then
					blockDepth += 1
				elseif word == "end" or word == "until" then
					blockDepth = math.max(0, blockDepth - 1)
					tokenBlockDepth = blockDepth
				end
			end

			pushToken(tokens, {
				kind = if isKw then "Keyword" else "Identifier",
				value = word,
				line = line,
				column = tokenCol,
				rawStart = rawStart,
				rawEnd = pos - 1,
				blockDepth = tokenBlockDepth,
			})

		-- Number literal
		elseif isDigit(b) then
			local rawStart = pos
			local tokenCol = rawStart - lineStartPos + 1
			pos += 1
			while pos <= len do
				local nb = string.byte(source, pos)
				if isAlphaNumeric(nb) or nb == 46 then
					pos += 1
				else
					break
				end
			end
			pushToken(tokens, {
				kind = "Number",
				value = string.sub(source, rawStart, pos - 1),
				line = line,
				column = tokenCol,
				rawStart = rawStart,
				rawEnd = pos - 1,
				blockDepth = blockDepth,
			})

		-- Multi-character or single-character symbols
		else
			local rawStart = pos
			local tokenCol = rawStart - lineStartPos + 1
			local sym = string.sub(source, pos, pos)
			if pos + 1 <= len then
				local twoChar = string.sub(source, pos, pos + 1)
				if
					twoChar == "::"
					or twoChar == ".."
					or twoChar == "=="
					or twoChar == "~="
					or twoChar == "<="
					or twoChar == ">="
					or twoChar == "->"
				then
					sym = twoChar
					pos += 2
				else
					pos += 1
				end
			else
				pos += 1
			end
			pushToken(tokens, {
				kind = "Symbol",
				value = sym,
				line = line,
				column = tokenCol,
				rawStart = rawStart,
				rawEnd = pos - 1,
				blockDepth = blockDepth,
			})
		end
	end

	return tokens
end

local function safeFindDirectChild(parent: Instance, childName: string): Instance?
	local ok, child = pcall(function(): Instance?
		return parent:FindFirstChild(childName)
	end)
	if ok then
		return child
	end
	return nil
end

local function safeFindRecursiveChild(parent: Instance, childName: string): Instance?
	local ok, child = pcall(function(): Instance?
		return parent:FindFirstChild(childName, true)
	end)
	if ok then
		return child
	end
	return nil
end

local function safeFindServiceOrChild(root: Instance, serviceName: string): Instance?
	local direct = safeFindDirectChild(root, serviceName)
	if direct ~= nil then
		return direct
	end
	if root == game then
		local ok, svc = pcall(function(): Instance?
			return game:GetService(serviceName)
		end)
		if ok and svc ~= nil then
			return svc
		end
	end
	return nil
end

local function safeGetParent(instance: Instance): Instance?
	local ok, parent = pcall(function(): Instance?
		return instance.Parent
	end)
	if ok then
		return parent
	end
	return nil
end

local function safeGetChildren(parent: Instance): { Instance }
	local ok, children = pcall(function(): { Instance }
		return parent:GetChildren()
	end)
	if ok and type(children) == "table" then
		return children
	end
	return {}
end

local function safeGetDescendants(parent: Instance): { Instance }
	local ok, descendants = pcall(function(): { Instance }
		return parent:GetDescendants()
	end)
	if ok and type(descendants) == "table" then
		return descendants
	end
	return {}
end

local function safeIsModuleScript(inst: Instance): ModuleScript?
	local ok, isMod = pcall(function(): boolean
		return inst:IsA("ModuleScript")
	end)
	if ok and isMod and inst:IsA("ModuleScript") then
		return inst
	end
	return nil
end

local function safeIsA(inst: Instance, className: string): boolean
	local ok, res = pcall(function(): boolean
		return inst:IsA(className)
	end)
	return ok and res == true
end

local function formatCurrentPath(instance: Instance, root: Instance): string
	if instance == root then
		return "game"
	end
	return ScriptDiscovery.getCleanFullPath(instance, root)
end

-- Strips outer balanced parentheses and trailing `:: Type` annotations from a slice of tokens
local function normalizeExprRange(tokens: { Token }, startIdx: number, endIdx: number): (number, number)
	local s = startIdx
	local e = endIdx

	-- Strip trailing `:: Type` at top paren/bracket level of the slice
	local depth = 0
	local doubleColonPos: number? = nil
	for i = s, e do
		local tok = tokens[i]
		if tok.kind == "Symbol" then
			if tok.value == "(" or tok.value == "[" or tok.value == "{" then
				depth += 1
			elseif tok.value == ")" or tok.value == "]" or tok.value == "}" then
				depth = math.max(0, depth - 1)
			elseif tok.value == "::" and depth == 0 then
				doubleColonPos = i
				break
			end
		end
	end
	if doubleColonPos ~= nil and doubleColonPos > s then
		e = doubleColonPos - 1
	end

	-- Unwrap balanced outer parentheses `( ... )`
	while s < e and tokens[s].kind == "Symbol" and tokens[s].value == "(" and tokens[e].kind == "Symbol" and tokens[e].value == ")" do
		local pDepth = 0
		local balancedUntilEnd = true
		for i = s, e - 1 do
			local v = tokens[i].value
			if tokens[i].kind == "Symbol" then
				if v == "(" then
					pDepth += 1
				elseif v == ")" then
					pDepth -= 1
					if pDepth == 0 then
						balancedUntilEnd = false
						break
					end
				end
			end
		end
		if balancedUntilEnd then
			s += 1
			e -= 1
			local innerDepth = 0
			local innerColon: number? = nil
			for i = s, e do
				local tok = tokens[i]
				if tok.kind == "Symbol" then
					if tok.value == "(" or tok.value == "[" or tok.value == "{" then
						innerDepth += 1
					elseif tok.value == ")" or tok.value == "]" or tok.value == "}" then
						innerDepth = math.max(0, innerDepth - 1)
					elseif tok.value == "::" and innerDepth == 0 then
						innerColon = i
						break
					end
				end
			end
			if innerColon ~= nil and innerColon > s then
				e = innerColon - 1
			end
		else
			break
		end
	end

	return s, e
end

-- Resolves a Roblox require-by-string path ("./...", "../...", "@self/...", "@game/...")
local function evaluateStringRequirePath(
	rawPath: string,
	currentScript: DiscoveredScript,
	root: Instance,
	usedAlias: string?
): PathEvalResult
	if rawPath == "" then
		return {
			status = "Unresolved",
			instance = nil,
			partialBasePath = nil,
			failureReason = "Empty string path in require()",
			usedAlias = usedAlias,
		}
	end

	local currentInstance: Instance
	local remainingPath = ""

	if rawPath == "@self" or string.sub(rawPath, 1, 6) == "@self/" then
		currentInstance = currentScript.instance
		remainingPath = if rawPath == "@self" then "" else string.sub(rawPath, 7)
	elseif rawPath == "@game" or string.sub(rawPath, 1, 6) == "@game/" then
		currentInstance = root
		remainingPath = if rawPath == "@game" then "" else string.sub(rawPath, 7)
	elseif rawPath == "." or string.sub(rawPath, 1, 2) == "./" then
		local parentInst = safeGetParent(currentScript.instance)
		if parentInst == nil then
			return {
				status = "PartiallyResolved",
				instance = nil,
				partialBasePath = currentScript.fullPath,
				failureReason = string.format(
					"Cannot resolve relative string path '%s': script.Parent is nil",
					rawPath
				),
				usedAlias = usedAlias,
			}
		end
		currentInstance = parentInst
		remainingPath = if rawPath == "." then "" else string.sub(rawPath, 3)
	elseif rawPath == ".." or string.sub(rawPath, 1, 3) == "../" then
		local parentInst = safeGetParent(currentScript.instance)
		if parentInst == nil then
			return {
				status = "PartiallyResolved",
				instance = nil,
				partialBasePath = currentScript.fullPath,
				failureReason = string.format(
					"Cannot resolve relative string path '%s': script.Parent is nil",
					rawPath
				),
				usedAlias = usedAlias,
			}
		end
		currentInstance = parentInst
		remainingPath = rawPath
	elseif string.sub(rawPath, 1, 1) == "@" then
		return {
			status = "Unresolved",
			instance = nil,
			partialBasePath = nil,
			failureReason = string.format(
				"Custom string path alias in '%s' cannot be statically resolved (built-in Roblox prefixes are './', '../', '@self/', '@game/')",
				rawPath
			),
			usedAlias = usedAlias,
		}
	else
		return {
			status = "Unresolved",
			instance = nil,
			partialBasePath = nil,
			failureReason = string.format(
				"Invalid require string path '%s': Roblox string paths must start with './', '../', '@self/', or '@game/'",
				rawPath
			),
			usedAlias = usedAlias,
		}
	end

	for component in string.gmatch(remainingPath, "[^/]+") do
		if component == "." or component == "" then
			continue
		elseif component == ".." then
			local basePath = formatCurrentPath(currentInstance, root)
			local parentInst = safeGetParent(currentInstance)
			if parentInst == nil then
				return {
					status = "PartiallyResolved",
					instance = nil,
					partialBasePath = basePath,
					failureReason = string.format(
						"Cannot traverse '..' above '%s' in string path '%s'",
						basePath,
						rawPath
					),
					usedAlias = usedAlias,
				}
			end
			currentInstance = parentInst
		else
			local basePath = formatCurrentPath(currentInstance, root)
			local childInst = if currentInstance == root
				then safeFindServiceOrChild(root, component)
				else safeFindDirectChild(currentInstance, component)
			if childInst == nil then
				return {
					status = "PartiallyResolved",
					instance = nil,
					partialBasePath = basePath,
					failureReason = string.format(
						"Child '%s' not found under '%s' (via string path '%s')",
						component,
						basePath,
						rawPath
					),
					usedAlias = usedAlias,
				}
			end
			currentInstance = childInst
		end
	end

	return {
		status = "Resolved",
		instance = currentInstance,
		partialBasePath = nil,
		failureReason = nil,
		usedAlias = usedAlias,
	}
end

-- Evaluates chained property/bracket/method accesses starting from a known anchor Instance
local function evaluateSuffixFromInstance(
	initialInstance: Instance,
	tokens: { Token },
	rawSource: string,
	cursorStart: number,
	endIdx: number,
	root: Instance,
	usedAlias: string?
): PathEvalResult
	local currentInstance = initialInstance
	local cursor = cursorStart

	while cursor <= endIdx do
		local opTok = tokens[cursor]

		-- Ignore inline `:: Type` assertions if encountered mid-chain
		if opTok.kind == "Symbol" and opTok.value == "::" then
			cursor += 2
			continue
		end

		-- 1. Dot access: `.Parent` or `.ChildName`
		if opTok.kind == "Symbol" and opTok.value == "." then
			local fieldTok = tokens[cursor + 1]
			if fieldTok == nil or (fieldTok.kind ~= "Identifier" and fieldTok.kind ~= "Keyword") then
				local basePath = formatCurrentPath(currentInstance, root)
				return {
					status = "PartiallyResolved",
					instance = nil,
					partialBasePath = basePath,
					failureReason = string.format("Malformed dot property access on '%s'", basePath),
					usedAlias = usedAlias,
				}
			end

			local fieldName = fieldTok.value
			local basePath = formatCurrentPath(currentInstance, root)

			if fieldName == "Parent" then
				local parentInst = safeGetParent(currentInstance)
				if parentInst == nil then
					return {
						status = "PartiallyResolved",
						instance = nil,
						partialBasePath = basePath,
						failureReason = string.format("'.Parent' of '%s' is nil", basePath),
						usedAlias = usedAlias,
					}
				end
				currentInstance = parentInst
			else
				local childInst = if currentInstance == root
					then safeFindServiceOrChild(root, fieldName)
					else safeFindDirectChild(currentInstance, fieldName)
				if childInst == nil then
					return {
						status = "PartiallyResolved",
						instance = nil,
						partialBasePath = basePath,
						failureReason = string.format("Child '%s' not found under '%s'", fieldName, basePath),
						usedAlias = usedAlias,
					}
				end
				currentInstance = childInst
			end
			cursor += 2

		-- 2. Bracket access: `["ChildName"]` or `[dynamicExpr]`
		elseif opTok.kind == "Symbol" and opTok.value == "[" then
			local bDepth = 1
			local closeBracketIdx: number? = nil
			local scanIdx = cursor + 1
			while scanIdx <= endIdx do
				local t = tokens[scanIdx]
				if t.kind == "Symbol" then
					if t.value == "[" then
						bDepth += 1
					elseif t.value == "]" then
						bDepth -= 1
						if bDepth == 0 then
							closeBracketIdx = scanIdx
							break
						end
					end
				end
				scanIdx += 1
			end

			local basePath = formatCurrentPath(currentInstance, root)
			if closeBracketIdx == nil then
				return {
					status = "PartiallyResolved",
					instance = nil,
					partialBasePath = basePath,
					failureReason = string.format("Unclosed bracket index on '%s'", basePath),
					usedAlias = usedAlias,
				}
			end

			local innerStart, innerEnd = normalizeExprRange(tokens, cursor + 1, closeBracketIdx - 1)
			if innerStart == innerEnd and tokens[innerStart].kind == "String" then
				local keyName = tokens[innerStart].value
				if keyName == "Parent" then
					local parentInst = safeGetParent(currentInstance)
					if parentInst == nil then
						return {
							status = "PartiallyResolved",
							instance = nil,
							partialBasePath = basePath,
							failureReason = string.format("['Parent'] of '%s' is nil", basePath),
							usedAlias = usedAlias,
						}
					end
					currentInstance = parentInst
				else
					local childInst = if currentInstance == root
						then safeFindServiceOrChild(root, keyName)
						else safeFindDirectChild(currentInstance, keyName)
					if childInst == nil then
						return {
							status = "PartiallyResolved",
							instance = nil,
							partialBasePath = basePath,
							failureReason = string.format("Child ['%s'] not found under '%s'", keyName, basePath),
							usedAlias = usedAlias,
						}
					end
					currentInstance = childInst
				end
				cursor = closeBracketIdx + 1
			else
				local rawIndex = if innerStart <= innerEnd
					then string.sub(rawSource, tokens[innerStart].rawStart, tokens[innerEnd].rawEnd)
					else ""
				return {
					status = "PartiallyResolved",
					instance = nil,
					partialBasePath = basePath,
					failureReason = string.format(
						"Dynamic bracket index '[%s]' on '%s' cannot be statically resolved",
						rawIndex,
						basePath
					),
					usedAlias = usedAlias,
				}
			end

		-- 3. Method call: `:GetService("...")`, `:WaitForChild("...")`, `:FindFirstChild("...")`
		elseif opTok.kind == "Symbol" and opTok.value == ":" then
			local methodTok = tokens[cursor + 1]
			local openParenTok = tokens[cursor + 2]
			local basePath = formatCurrentPath(currentInstance, root)

			if
				methodTok == nil
				or methodTok.kind ~= "Identifier"
				or openParenTok == nil
				or openParenTok.kind ~= "Symbol"
				or openParenTok.value ~= "("
			then
				return {
					status = "PartiallyResolved",
					instance = nil,
					partialBasePath = basePath,
					failureReason = string.format("Malformed method call on '%s'", basePath),
					usedAlias = usedAlias,
				}
			end

			local methodName = methodTok.value
			local pDepth = 1
			local closeParenIdx: number? = nil
			local scanIdx = cursor + 3
			while scanIdx <= endIdx do
				local t = tokens[scanIdx]
				if t.kind == "Symbol" then
					if t.value == "(" then
						pDepth += 1
					elseif t.value == ")" then
						pDepth -= 1
						if pDepth == 0 then
							closeParenIdx = scanIdx
							break
						end
					end
				end
				scanIdx += 1
			end

			if closeParenIdx == nil then
				return {
					status = "PartiallyResolved",
					instance = nil,
					partialBasePath = basePath,
					failureReason = string.format("Unclosed method call ':%s(' on '%s'", methodName, basePath),
					usedAlias = usedAlias,
				}
			end

			local argStart = cursor + 3
			local argEnd = closeParenIdx - 1
			local firstArgTok = if argStart <= argEnd then tokens[argStart] else nil

			if methodName == "GetService" or methodName == "FindFirstService" then
				if firstArgTok ~= nil and firstArgTok.kind == "String" then
					local serviceName = firstArgTok.value
					local svcInst = safeFindServiceOrChild(currentInstance, serviceName)
					if svcInst == nil then
						return {
							status = "PartiallyResolved",
							instance = nil,
							partialBasePath = basePath,
							failureReason = string.format("Service '%s' not found under '%s'", serviceName, basePath),
							usedAlias = usedAlias,
						}
					end
					currentInstance = svcInst
					cursor = closeParenIdx + 1
				else
					local rawArgs = if argStart <= argEnd
						then string.sub(rawSource, tokens[argStart].rawStart, tokens[argEnd].rawEnd)
						else ""
					return {
						status = "PartiallyResolved",
						instance = nil,
						partialBasePath = basePath,
						failureReason = string.format(
							"Dynamic argument in :%s(%s) on '%s'",
							methodName,
							rawArgs,
							basePath
						),
						usedAlias = usedAlias,
					}
				end
			elseif methodName == "WaitForChild" or methodName == "FindFirstChild" then
				if firstArgTok ~= nil and firstArgTok.kind == "String" then
					local childName = firstArgTok.value
					local isRecursive = false
					if
						methodName == "FindFirstChild"
						and argStart + 2 <= argEnd
						and tokens[argStart + 1].kind == "Symbol"
						and tokens[argStart + 1].value == ","
						and tokens[argStart + 2].kind == "Keyword"
						and tokens[argStart + 2].value == "true"
					then
						isRecursive = true
					end

					local childInst = if isRecursive
						then safeFindRecursiveChild(currentInstance, childName)
						elseif currentInstance == root then safeFindServiceOrChild(root, childName)
						else safeFindDirectChild(currentInstance, childName)

					if childInst == nil then
						return {
							status = "PartiallyResolved",
							instance = nil,
							partialBasePath = basePath,
							failureReason = string.format(
								"Child '%s' (via :%s) not found under '%s'",
								childName,
								methodName,
								basePath
							),
							usedAlias = usedAlias,
						}
					end
					currentInstance = childInst
					cursor = closeParenIdx + 1
				else
					local rawArgs = if argStart <= argEnd
						then string.sub(rawSource, tokens[argStart].rawStart, tokens[argEnd].rawEnd)
						else ""
					return {
						status = "PartiallyResolved",
						instance = nil,
						partialBasePath = basePath,
						failureReason = string.format(
							"Dynamic argument in :%s(%s) on '%s'",
							methodName,
							rawArgs,
							basePath
						),
						usedAlias = usedAlias,
					}
				end
			elseif methodName == "FindFirstAncestor" then
				if firstArgTok ~= nil and firstArgTok.kind == "String" then
					local targetName = firstArgTok.value
					local walker = safeGetParent(currentInstance)
					local matchedAncestor: Instance? = nil
					local guard = 0
					while walker ~= nil and walker ~= root and guard < 256 do
						guard += 1
						if walker.Name == targetName then
							matchedAncestor = walker
							break
						end
						walker = safeGetParent(walker)
					end
					if matchedAncestor == nil then
						return {
							status = "PartiallyResolved",
							instance = nil,
							partialBasePath = basePath,
							failureReason = string.format(
								"Ancestor '%s' (via :FindFirstAncestor) not found above '%s'",
								targetName,
								basePath
							),
							usedAlias = usedAlias,
						}
					end
					currentInstance = matchedAncestor
					cursor = closeParenIdx + 1
				else
					return {
						status = "PartiallyResolved",
						instance = nil,
						partialBasePath = basePath,
						failureReason = string.format("Dynamic argument in :FindFirstAncestor() on '%s'", basePath),
						usedAlias = usedAlias,
					}
				end
			else
				return {
					status = "PartiallyResolved",
					instance = nil,
					partialBasePath = basePath,
					failureReason = string.format(
						"Method call ':%s()' on '%s' cannot be statically evaluated",
						methodName,
						basePath
					),
					usedAlias = usedAlias,
				}
			end

		else
			local basePath = formatCurrentPath(currentInstance, root)
			local remainingRaw = string.sub(rawSource, opTok.rawStart, tokens[endIdx].rawEnd)
			return {
				status = "PartiallyResolved",
				instance = nil,
				partialBasePath = basePath,
				failureReason = string.format(
					"Dynamic or unsupported expression segment '%s' after '%s'",
					remainingRaw,
					basePath
				),
				usedAlias = usedAlias,
			}
		end
	end

	return {
		status = "Resolved",
		instance = currentInstance,
		partialBasePath = nil,
		failureReason = nil,
		usedAlias = usedAlias,
	}
end

-- Evaluates a sequence of tokens representing an Instance path, string path, or numeric asset ID expression
local function evaluateInstancePathTokens(
	tokens: { Token },
	rawSource: string,
	startIdx: number,
	endIdx: number,
	currentScript: DiscoveredScript,
	root: Instance,
	aliases: { [string]: PathEvalResult }
): PathEvalResult
	local s, e = normalizeExprRange(tokens, startIdx, endIdx)
	if s > e then
		return {
			status = "Unresolved",
			instance = nil,
			partialBasePath = nil,
			failureReason = "Empty require() expression",
			usedAlias = nil,
		}
	end

	local firstTok = tokens[s]
	local currentInstance: Instance? = nil
	local usedAlias: string? = nil

	if firstTok.kind == "Number" and s == e then
		return {
			status = "Unresolved",
			instance = nil,
			partialBasePath = "rbxassetid://" .. firstTok.value,
			failureReason = string.format(
				"Asset ID require (%s): external cloud ModuleScript asset cannot be resolved in the local DataModel (closed-source / external asset)",
				firstTok.value
			),
			usedAlias = nil,
		}
	elseif firstTok.kind == "String" then
		if s == e then
			return evaluateStringRequirePath(firstTok.value, currentScript, root, nil)
		end
		local prefixEval = evaluateStringRequirePath(firstTok.value, currentScript, root, nil)
		local basePath = if prefixEval.instance ~= nil
			then formatCurrentPath(prefixEval.instance, root)
			else prefixEval.partialBasePath
		return {
			status = if basePath ~= nil then "PartiallyResolved" else "Unresolved",
			instance = nil,
			partialBasePath = basePath,
			failureReason = string.format(
				"Dynamic string expression '%s' in require() cannot be statically resolved",
				string.sub(rawSource, tokens[s].rawStart, tokens[e].rawEnd)
			),
			usedAlias = nil,
		}
	elseif firstTok.kind == "InterpolatedString" then
		return {
			status = "Unresolved",
			instance = nil,
			partialBasePath = nil,
			failureReason = string.format(
				"Interpolated string %s in require() cannot be statically resolved",
				firstTok.value
			),
			usedAlias = nil,
		}
	elseif firstTok.kind ~= "Identifier" then
		local exprSlice = string.sub(rawSource, tokens[s].rawStart, tokens[e].rawEnd)
		return {
			status = "Unresolved",
			instance = nil,
			partialBasePath = nil,
			failureReason = string.format("Dynamic or non-static expression '%s'", exprSlice),
			usedAlias = nil,
		}
	end

	-- Resolve starting anchor identifier
	local rootIdent = firstTok.value
	if rootIdent == "script" then
		currentInstance = currentScript.instance
	elseif rootIdent == "game" then
		currentInstance = root
	elseif rootIdent == "workspace" or rootIdent == "Workspace" then
		currentInstance = safeFindServiceOrChild(root, "Workspace")
	elseif aliases[rootIdent] ~= nil then
		local aliasResult = aliases[rootIdent]
		usedAlias = rootIdent
		if aliasResult.instance ~= nil then
			currentInstance = aliasResult.instance
		else
			return {
				status = aliasResult.status,
				instance = nil,
				partialBasePath = aliasResult.partialBasePath,
				failureReason = string.format(
					"Local alias '%s' could not be resolved (%s)",
					rootIdent,
					aliasResult.failureReason or "unknown base"
				),
				usedAlias = rootIdent,
			}
		end
	else
		return {
			status = "Unresolved",
			instance = nil,
			partialBasePath = nil,
			failureReason = if s < e and tokens[s + 1].kind == "Symbol" and tokens[s + 1].value == "("
				then string.format("Dynamic function call '%s(...)' cannot be statically resolved", rootIdent)
				else string.format("Unresolved variable or dynamic identifier '%s'", rootIdent),
			usedAlias = nil,
		}
	end

	if currentInstance == nil then
		return {
			status = "Unresolved",
			instance = nil,
			partialBasePath = nil,
			failureReason = string.format("Base root '%s' is not available in the DataModel", rootIdent),
			usedAlias = usedAlias,
		}
	end

	return evaluateSuffixFromInstance(currentInstance, tokens, rawSource, s + 1, e, root, usedAlias)
end

-- Evaluates an iterable/collection expression:
-- Supports:
--   * <Container>:GetChildren()
--   * <Container>:GetDescendants()
--   * ipairs(<CollectionExpr>) / pairs(<CollectionExpr>)
--   * Table literals `{ Mod1, Mod2, key = Mod3 }`
--   * Variable aliases to collections (`local Dependencies = Modules:GetChildren()`)
--   * Nested loop container variables (`for _, folder in Root:GetChildren() do for _, m in folder:GetChildren() do`)
local function evaluateCollectionExpression(
	tokens: { Token },
	rawSource: string,
	startIdx: number,
	endIdx: number,
	currentScript: DiscoveredScript,
	root: Instance,
	aliases: { [string]: PathEvalResult },
	collections: { [string]: CollectionEvalResult },
	activeLoops: { [string]: CollectionEvalResult }
): CollectionEvalResult
	local s, e = normalizeExprRange(tokens, startIdx, endIdx)
	if s > e then
		return {
			status = "Unresolved",
			instances = {},
			basePath = nil,
			sourceKind = "Unknown",
			failureReason = "Empty iterable expression",
			usedAlias = nil,
		}
	end

	-- 1. Unwrap `ipairs(...)` or `pairs(...)`
	if
		tokens[s].kind == "Identifier"
		and (tokens[s].value == "ipairs" or tokens[s].value == "pairs")
		and s + 2 <= e
		and tokens[s + 1].kind == "Symbol"
		and tokens[s + 1].value == "("
		and tokens[e].kind == "Symbol"
		and tokens[e].value == ")"
	then
		s, e = normalizeExprRange(tokens, s + 2, e - 1)
		if s > e then
			return {
				status = "Unresolved",
				instances = {},
				basePath = nil,
				sourceKind = "Unknown",
				failureReason = "Empty argument inside ipairs/pairs()",
				usedAlias = nil,
			}
		end
	end

	-- 2. Table literal `{ expr1, expr2, ... }`
	if
		tokens[s].kind == "Symbol"
		and tokens[s].value == "{"
		and tokens[e].kind == "Symbol"
		and tokens[e].value == "}"
	then
		local instances: { Instance } = {}
		local hasUnresolvedItem = false
		local elemStart = s + 1
		local depth = 0
		local scan = s + 1

		while scan <= e do
			local tok = tokens[scan]
			local isDelimiter = (scan == e)
				or (depth == 0 and tok.kind == "Symbol" and (tok.value == "," or tok.value == ";"))

			if isDelimiter then
				local elemEnd = scan - 1
				if elemStart <= elemEnd then
					-- Check for `key = value` or `[key] = value` inside the table entry
					local valStart = elemStart
					local innerDepth = 0
					for k = elemStart, elemEnd do
						local kt = tokens[k]
						if kt.kind == "Symbol" then
							if kt.value == "(" or kt.value == "[" or kt.value == "{" then
								innerDepth += 1
							elseif kt.value == ")" or kt.value == "]" or kt.value == "}" then
								innerDepth = math.max(0, innerDepth - 1)
							elseif kt.value == "=" and innerDepth == 0 then
								valStart = k + 1
								break
							end
						end
					end

					if valStart <= elemEnd then
						local itemEval = evaluateInstancePathTokens(
							tokens,
							rawSource,
							valStart,
							elemEnd,
							currentScript,
							root,
							aliases
						)
						if itemEval.status == "Resolved" and itemEval.instance ~= nil then
							table.insert(instances, itemEval.instance)
						else
							hasUnresolvedItem = true
						end
					end
				end
				elemStart = scan + 1
			elseif tok.kind == "Symbol" then
				if tok.value == "(" or tok.value == "[" or tok.value == "{" then
					depth += 1
				elseif tok.value == ")" or tok.value == "]" or tok.value == "}" then
					depth = math.max(0, depth - 1)
				end
			end
			scan += 1
		end

		local status: ResolutionStatus = if #instances > 0 and not hasUnresolvedItem
			then "Resolved"
			elseif #instances > 0 and hasUnresolvedItem then "PartiallyResolved"
			else "Unresolved"

		return {
			status = status,
			instances = instances,
			basePath = nil,
			sourceKind = "TableLiteral",
			failureReason = if hasUnresolvedItem
				then "One or more entries in the table literal could not be statically resolved"
				else nil,
			usedAlias = nil,
		}
	end

	-- 3. `<ContainerExpr>:GetChildren()` or `<ContainerExpr>:GetDescendants()`
	if
		e >= s + 4
		and tokens[e].kind == "Symbol"
		and tokens[e].value == ")"
		and tokens[e - 1].kind == "Symbol"
		and tokens[e - 1].value == "("
		and tokens[e - 2].kind == "Identifier"
		and (tokens[e - 2].value == "GetChildren" or tokens[e - 2].value == "GetDescendants")
		and tokens[e - 3].kind == "Symbol"
		and tokens[e - 3].value == ":"
	then
		local methodName = tokens[e - 2].value
		local sourceKind: CollectionSourceKind = if methodName == "GetDescendants"
			then "GetDescendants"
			else "GetChildren"
		local prefixEnd = e - 4
		local firstIdent = tokens[s]

		-- 3a. Prefix starts with an enclosing loop variable (Nested Loops!)
		if firstIdent.kind == "Identifier" and activeLoops[firstIdent.value] ~= nil then
			local outerLoop = activeLoops[firstIdent.value]
			local collected: { Instance } = {}
			local seenInst: { [Instance]: boolean } = {}

			for _, outerInst in outerLoop.instances do
				local targetContainer: Instance? = nil
				if s == prefixEnd then
					targetContainer = outerInst
				else
					local subEval = evaluateSuffixFromInstance(
						outerInst,
						tokens,
						rawSource,
						s + 1,
						prefixEnd,
						root,
						firstIdent.value
					)
					if subEval.status == "Resolved" then
						targetContainer = subEval.instance
					end
				end

				if targetContainer ~= nil then
					local items: { Instance } = if methodName == "GetDescendants"
						then safeGetDescendants(targetContainer)
						else safeGetChildren(targetContainer)
					for _, child in items do
						if not seenInst[child] then
							seenInst[child] = true
							table.insert(collected, child)
						end
					end
				end
			end

			return {
				status = outerLoop.status,
				instances = collected,
				basePath = outerLoop.basePath,
				sourceKind = sourceKind,
				failureReason = outerLoop.failureReason,
				usedAlias = firstIdent.value,
			}
		end

		-- 3b. Standard container expression
		local containerEval = evaluateInstancePathTokens(
			tokens,
			rawSource,
			s,
			prefixEnd,
			currentScript,
			root,
			aliases
		)
		if containerEval.status == "Resolved" and containerEval.instance ~= nil then
			local containerInst = containerEval.instance
			local items = if methodName == "GetDescendants"
				then safeGetDescendants(containerInst)
				else safeGetChildren(containerInst)
			return {
				status = "Resolved",
				instances = items,
				basePath = formatCurrentPath(containerInst, root),
				sourceKind = sourceKind,
				failureReason = nil,
				usedAlias = containerEval.usedAlias,
			}
		else
			return {
				status = containerEval.status,
				instances = {},
				basePath = containerEval.partialBasePath,
				sourceKind = sourceKind,
				failureReason = containerEval.failureReason,
				usedAlias = containerEval.usedAlias,
			}
		end
	end

	-- 4. Single identifier referencing a Collection variable or Container Instance alias
	if s == e and tokens[s].kind == "Identifier" then
		local identName = tokens[s].value
		local existingCol = collections[identName]
		if existingCol ~= nil then
			return {
				status = existingCol.status,
				instances = existingCol.instances,
				basePath = existingCol.basePath,
				sourceKind = existingCol.sourceKind,
				failureReason = existingCol.failureReason,
				usedAlias = identName,
			}
		end

		local existingAlias = aliases[identName]
		if existingAlias ~= nil and existingAlias.instance ~= nil then
			local inst = existingAlias.instance
			return {
				status = "Resolved",
				instances = safeGetChildren(inst),
				basePath = formatCurrentPath(inst, root),
				sourceKind = "InstanceChildren",
				failureReason = nil,
				usedAlias = identName,
			}
		end
	end

	-- 5. Fallback: check if the expression itself resolves to a container Instance
	local fallbackEval = evaluateInstancePathTokens(tokens, rawSource, s, e, currentScript, root, aliases)
	if fallbackEval.status == "Resolved" and fallbackEval.instance ~= nil then
		local inst = fallbackEval.instance
		return {
			status = "Resolved",
			instances = safeGetChildren(inst),
			basePath = formatCurrentPath(inst, root),
			sourceKind = "InstanceChildren",
			failureReason = nil,
			usedAlias = fallbackEval.usedAlias,
		}
	end

	return {
		status = fallbackEval.status,
		instances = {},
		basePath = fallbackEval.partialBasePath,
		sourceKind = "Unknown",
		failureReason = fallbackEval.failureReason
			or string.format(
				"Iterable expression '%s' cannot be statically resolved",
				string.sub(rawSource, tokens[s].rawStart, tokens[e].rawEnd)
			),
		usedAlias = fallbackEval.usedAlias,
	}
end

-- Evaluates an atomic condition clause against a candidate Instance for `loopVarName`
-- Returns: (matches: boolean?, isFullyStatic: boolean, isPureModuleClassCheck: boolean)
local function evaluateAtomicCondition(
	tokens: { Token },
	startIdx: number,
	endIdx: number,
	loopVarName: string,
	candidate: Instance
): (boolean?, boolean, boolean)
	local s, e = normalizeExprRange(tokens, startIdx, endIdx)
	if s > e then
		return nil, false, false
	end

	-- Handle `not <subClause>`
	if tokens[s].kind == "Keyword" and tokens[s].value == "not" and s + 1 <= e then
		local subMatch, subStatic, _ = evaluateAtomicCondition(tokens, s + 1, e, loopVarName, candidate)
		if subMatch ~= nil and subStatic then
			return not subMatch, true, false
		end
		return nil, false, false
	end

	-- Pattern 1: `loopVar:IsA("ClassName")`
	if
		e == s + 5
		and tokens[s].kind == "Identifier"
		and tokens[s].value == loopVarName
		and tokens[s + 1].kind == "Symbol"
		and tokens[s + 1].value == ":"
		and tokens[s + 2].kind == "Identifier"
		and tokens[s + 2].value == "IsA"
		and tokens[s + 3].kind == "Symbol"
		and tokens[s + 3].value == "("
		and tokens[s + 4].kind == "String"
		and tokens[s + 5].kind == "Symbol"
		and tokens[s + 5].value == ")"
	then
		local className = tokens[s + 4].value
		local matches = safeIsA(candidate, className)
		local isPureModCheck = (className == "ModuleScript" or className == "LuaSourceContainer")
		return matches, true, isPureModCheck
	end

	-- Pattern 2: `loopVar.Name == "Str"` or `loopVar.Name ~= "Str"` or `loopVar.ClassName == "Str"`
	if
		e == s + 4
		and tokens[s].kind == "Identifier"
		and tokens[s].value == loopVarName
		and tokens[s + 1].kind == "Symbol"
		and tokens[s + 1].value == "."
		and tokens[s + 2].kind == "Identifier"
		and tokens[s + 3].kind == "Symbol"
		and (tokens[s + 3].value == "==" or tokens[s + 3].value == "~=")
		and tokens[s + 4].kind == "String"
	then
		local propName = tokens[s + 2].value
		local op = tokens[s + 3].value
		local literalVal = tokens[s + 4].value

		if propName == "Name" then
			local eq = (candidate.Name == literalVal)
			return if op == "==" then eq else not eq, true, false
		elseif propName == "ClassName" then
			local eq = (candidate.ClassName == literalVal)
			local isPureModCheck = (op == "==" and literalVal == "ModuleScript")
			return if op == "==" then eq else not eq, true, isPureModCheck
		end
	end

	-- Pattern 3: `"Str" == loopVar.Name` or `"Str" ~= loopVar.Name`
	if
		e == s + 4
		and tokens[s].kind == "String"
		and tokens[s + 1].kind == "Symbol"
		and (tokens[s + 1].value == "==" or tokens[s + 1].value == "~=")
		and tokens[s + 2].kind == "Identifier"
		and tokens[s + 2].value == loopVarName
		and tokens[s + 3].kind == "Symbol"
		and tokens[s + 3].value == "."
		and tokens[s + 4].kind == "Identifier"
	then
		local literalVal = tokens[s].value
		local op = tokens[s + 1].value
		local propName = tokens[s + 4].value

		if propName == "Name" then
			local eq = (candidate.Name == literalVal)
			return if op == "==" then eq else not eq, true, false
		elseif propName == "ClassName" then
			local eq = (candidate.ClassName == literalVal)
			local isPureModCheck = (op == "==" and literalVal == "ModuleScript")
			return if op == "==" then eq else not eq, true, isPureModCheck
		end
	end

	return nil, false, false
end

-- Evaluates a compound condition (`and` / `or`) against a candidate Instance for `loopVarName`
local function evaluateConditionForCandidate(
	tokens: { Token },
	startIdx: number,
	endIdx: number,
	loopVarName: string,
	candidate: Instance
): (boolean?, boolean, boolean)
	local s, e = normalizeExprRange(tokens, startIdx, endIdx)
	if s > e then
		return nil, false, false
	end

	-- Split by top-level `or` first
	local depth = 0
	for i = s, e do
		local tok = tokens[i]
		if tok.kind == "Symbol" then
			if tok.value == "(" or tok.value == "[" or tok.value == "{" then
				depth += 1
			elseif tok.value == ")" or tok.value == "]" or tok.value == "}" then
				depth = math.max(0, depth - 1)
			end
		elseif tok.kind == "Keyword" and tok.value == "or" and depth == 0 then
			local leftMatch, leftStatic, leftModCheck =
				evaluateConditionForCandidate(tokens, s, i - 1, loopVarName, candidate)
			local rightMatch, rightStatic, rightModCheck =
				evaluateConditionForCandidate(tokens, i + 1, e, loopVarName, candidate)
			if leftStatic and rightStatic and leftMatch ~= nil and rightMatch ~= nil then
				return (leftMatch or rightMatch), true, (leftModCheck and rightModCheck)
			end
			return nil, false, false
		end
	end

	-- Split by top-level `and`
	depth = 0
	for i = s, e do
		local tok = tokens[i]
		if tok.kind == "Symbol" then
			if tok.value == "(" or tok.value == "[" or tok.value == "{" then
				depth += 1
			elseif tok.value == ")" or tok.value == "]" or tok.value == "}" then
				depth = math.max(0, depth - 1)
			end
		elseif tok.kind == "Keyword" and tok.value == "and" and depth == 0 then
			local leftMatch, leftStatic, leftModCheck =
				evaluateConditionForCandidate(tokens, s, i - 1, loopVarName, candidate)
			local rightMatch, rightStatic, rightModCheck =
				evaluateConditionForCandidate(tokens, i + 1, e, loopVarName, candidate)
			-- If either side is statically false, the conjunction is definitely false!
			if (leftStatic and leftMatch == false) or (rightStatic and rightMatch == false) then
				return false, (leftStatic and rightStatic), false
			end
			if leftStatic and rightStatic and leftMatch == true and rightMatch == true then
				return true, true, (leftModCheck and rightModCheck)
			end
			return nil, false, false
		end
	end

	return evaluateAtomicCondition(tokens, s, e, loopVarName, candidate)
end

-- Scans the extent of a `local <Ident> = <Expr>` assignment value expression
local function findAssignmentExprEnd(tokens: { Token }, exprStart: number, count: number): number
	local exprEnd = exprStart
	local startTok = tokens[exprStart]

	-- Table literal `{ ... }`
	if startTok.kind == "Symbol" and startTok.value == "{" then
		local bDepth = 1
		local scan = exprStart + 1
		while scan <= count do
			if tokens[scan].kind == "Symbol" then
				if tokens[scan].value == "{" then
					bDepth += 1
				elseif tokens[scan].value == "}" then
					bDepth -= 1
					if bDepth == 0 then
						return scan
					end
				end
			end
			scan += 1
		end
		return exprEnd
	end

	-- Parenthesized expression `( ... )`
	if startTok.kind == "Symbol" and startTok.value == "(" then
		local pDepth = 1
		local scan = exprStart + 1
		while scan <= count do
			if tokens[scan].kind == "Symbol" then
				if tokens[scan].value == "(" then
					pDepth += 1
				elseif tokens[scan].value == ")" then
					pDepth -= 1
					if pDepth == 0 then
						exprEnd = scan
						break
					end
				end
			end
			scan += 1
		end
	end

	-- Standalone String or Number literal
	if startTok.kind == "String" or startTok.kind == "Number" then
		return exprStart
	end

	-- Chained identifier / path / call expression: `a.b:c(...)["d"]`
	local scan = exprEnd + 1
	while scan <= count do
		local st = tokens[scan]
		if st.kind == "Symbol" and st.value == "." then
			if scan + 1 <= count and (tokens[scan + 1].kind == "Identifier" or tokens[scan + 1].kind == "Keyword") then
				exprEnd = scan + 1
				scan += 2
			else
				break
			end
		elseif st.kind == "Symbol" and st.value == ":" then
			if
				scan + 2 <= count
				and tokens[scan + 1].kind == "Identifier"
				and tokens[scan + 2].kind == "Symbol"
				and tokens[scan + 2].value == "("
			then
				local pDepth = 1
				local pScan = scan + 3
				local matchedClose: number? = nil
				while pScan <= count do
					if tokens[pScan].kind == "Symbol" then
						if tokens[pScan].value == "(" then
							pDepth += 1
						elseif tokens[pScan].value == ")" then
							pDepth -= 1
							if pDepth == 0 then
								matchedClose = pScan
								break
							end
						end
					end
					pScan += 1
				end
				if matchedClose ~= nil then
					exprEnd = matchedClose
					scan = matchedClose + 1
				else
					break
				end
			else
				break
			end
		elseif st.kind == "Symbol" and st.value == "(" and scan == exprStart + 1 then
			local pDepth = 1
			local pScan = scan + 1
			local matchedClose: number? = nil
			while pScan <= count do
				if tokens[pScan].kind == "Symbol" then
					if tokens[pScan].value == "(" then
						pDepth += 1
					elseif tokens[pScan].value == ")" then
						pDepth -= 1
						if pDepth == 0 then
							matchedClose = pScan
							break
						end
					end
				end
				pScan += 1
			end
			if matchedClose ~= nil then
				exprEnd = matchedClose
				scan = matchedClose + 1
			else
				break
			end
		elseif st.kind == "Symbol" and st.value == "[" then
			local bDepth = 1
			local bScan = scan + 1
			local matchedClose: number? = nil
			while bScan <= count do
				if tokens[bScan].kind == "Symbol" then
					if tokens[bScan].value == "[" then
						bDepth += 1
					elseif tokens[bScan].value == "]" then
						bDepth -= 1
						if bDepth == 0 then
							matchedClose = bScan
							break
						end
					end
				end
				bScan += 1
			end
			if matchedClose ~= nil then
				exprEnd = matchedClose
				scan = matchedClose + 1
			else
				break
			end
		else
			break
		end
	end

	return exprEnd
end

local function computeCurrentScopeKind(scopeStack: { ScopeFrame }): RequireScopeKind
	if #scopeStack == 0 then
		return "TopLevel"
	end
	for idx = #scopeStack, 1, -1 do
		local kind = scopeStack[idx].frameKind
		if kind == "Conditional" then
			return "Conditional"
		elseif kind == "Loop" then
			return "Loop"
		elseif kind == "Function" then
			return "Function"
		end
	end
	return "TopLevel"
end

local function collectActiveConditions(
	scopeStack: { ScopeFrame }
): (boolean, string?, { ScopeFrame })
	local condFrames: { ScopeFrame } = {}
	local parts: { string } = {}
	for _, frame in scopeStack do
		if frame.frameKind == "Conditional" and frame.condRawText ~= nil then
			table.insert(condFrames, frame)
			table.insert(parts, frame.condRawText)
		end
	end
	if #parts == 0 then
		return false, nil, condFrames
	end
	return true, table.concat(parts, " and "), condFrames
end

function DependencyAnalyzer.analyzeScriptSource(
	currentScript: DiscoveredScript,
	root: Instance
): { DependencyRecord }
	local records: { DependencyRecord } = {}
	local source = currentScript.source
	if not currentScript.sourceAccessible or source == nil or source == "" then
		return records
	end

	local okTok, tokensOrErr = pcall(function(): { Token }
		return DependencyAnalyzer.tokenizeLuau(source)
	end)
	if not okTok or type(tokensOrErr) ~= "table" then
		return records
	end

	local tokens: { Token } = tokensOrErr
	local count = #tokens

	-- First pass: count how many times each identifier is assigned (`local x =` or `x =`)
	local assignmentCounts: { [string]: number } = {}
	for idx = 1, count do
		local tok = tokens[idx]
		if tok.kind == "Identifier" then
			local prevTok = if idx > 1 then tokens[idx - 1] else nil
			local nextTok = if idx < count then tokens[idx + 1] else nil
			if prevTok == nil or (prevTok.value ~= "." and prevTok.value ~= ":") then
				if nextTok ~= nil and nextTok.kind == "Symbol" and nextTok.value == "=" then
					assignmentCounts[tok.value] = (assignmentCounts[tok.value] or 0) + 1
				elseif nextTok ~= nil and nextTok.kind == "Symbol" and nextTok.value == ":" then
					if prevTok ~= nil and prevTok.kind == "Keyword" and prevTok.value == "local" then
						local scan = idx + 2
						while scan <= count and not (tokens[scan].kind == "Symbol" and tokens[scan].value == "=") do
							if tokens[scan].line > tok.line + 1 then
								break
							end
							scan += 1
						end
						if scan <= count and tokens[scan].kind == "Symbol" and tokens[scan].value == "=" then
							assignmentCounts[tok.value] = (assignmentCounts[tok.value] or 0) + 1
						end
					end
				end
			end
		end
	end

	local aliases: { [string]: PathEvalResult } = {}
	local collections: { [string]: CollectionEvalResult } = {}
	local requireAliases: { [string]: string } = {}
	local scopeStack: { ScopeFrame } = {}

	local function isRequireIdentifier(identName: string): boolean
		return identName == "require" or requireAliases[identName] ~= nil
	end

	local function formatRequireUsedAlias(calleeName: string, pathAlias: string?): string?
		if calleeName == "require" then
			return pathAlias
		end
		if pathAlias ~= nil and pathAlias ~= "" then
			return string.format("%s (= require), %s", calleeName, pathAlias)
		end
		return string.format("%s (= require)", calleeName)
	end

	local function getActiveLoopMap(): { [string]: CollectionEvalResult }
		local map: { [string]: CollectionEvalResult } = {}
		for _, frame in scopeStack do
			if frame.frameKind == "Loop" and frame.loopVarName ~= nil and frame.loopEval ~= nil then
				map[frame.loopVarName] = frame.loopEval
			end
		end
		return map
	end

	local i = 1
	while i <= count do
		local tok = tokens[i]
		local prevTok = if i > 1 then tokens[i - 1] else nil
		local isFieldOrProp = prevTok ~= nil
			and prevTok.kind == "Symbol"
			and (prevTok.value == "." or prevTok.value == ":")

		-- 1. Track Scope Frames (`for`, `while`, `repeat`, `function`, `if`, `elseif`, `else`, `do`, `end`, `until`)
		if tok.kind == "Keyword" and not isFieldOrProp then
			local kw = tok.value

			if kw == "for" then
				-- Scan header up to matching `do`
				local doIdx: number? = nil
				local inIdx: number? = nil
				local pDepth = 0
				local scan = i + 1
				while scan <= count do
					local st = tokens[scan]
					if st.kind == "Symbol" then
						if st.value == "(" or st.value == "{" or st.value == "[" then
							pDepth += 1
						elseif st.value == ")" or st.value == "}" or st.value == "]" then
							pDepth = math.max(0, pDepth - 1)
						end
					elseif st.kind == "Keyword" and pDepth == 0 then
						if st.value == "in" and inIdx == nil then
							inIdx = scan
						elseif st.value == "do" then
							doIdx = scan
							break
						end
					end
					scan += 1
				end

				if doIdx ~= nil then
					if inIdx ~= nil and inIdx > i + 1 and inIdx < doIdx then
						-- Extract loop variables before `in`
						local identList: { string } = {}
						for vIdx = i + 1, inIdx - 1 do
							if tokens[vIdx].kind == "Identifier" then
								-- Skip type names after `:` in `for _, m: Instance in ...`
								local prevV = tokens[vIdx - 1]
								if prevV == nil or prevV.value ~= ":" then
									table.insert(identList, tokens[vIdx].value)
								end
							end
						end

						local keyVar: string? = if #identList >= 2 then identList[1] else nil
						local valVar: string? = if #identList >= 2
							then identList[2]
							elseif #identList == 1 then identList[1]
							else nil

						local activeLoops = getActiveLoopMap()
						local loopEval = evaluateCollectionExpression(
							tokens,
							source,
							inIdx + 1,
							doIdx - 1,
							currentScript,
							root,
							aliases,
							collections,
							activeLoops
						)

						pushScopeFrame(scopeStack, {
							frameKind = "Loop",
							loopVarName = valVar,
							loopKeyVarName = keyVar,
							loopEval = loopEval,
							condStartIdx = nil,
							condEndIdx = nil,
							condRawText = nil,
							isElseBranch = nil,
						})
					else
						pushScopeFrame(scopeStack, {
							frameKind = "Loop",
							loopVarName = nil,
							loopKeyVarName = nil,
							loopEval = nil,
							condStartIdx = nil,
							condEndIdx = nil,
							condRawText = nil,
							isElseBranch = nil,
						})
					end
					i = doIdx + 1
					continue
				end

			elseif kw == "while" then
				local doIdx: number? = nil
				local pDepth = 0
				local scan = i + 1
				while scan <= count do
					local st = tokens[scan]
					if st.kind == "Symbol" then
						if st.value == "(" or st.value == "{" or st.value == "[" then
							pDepth += 1
						elseif st.value == ")" or st.value == "}" or st.value == "]" then
							pDepth = math.max(0, pDepth - 1)
						end
					elseif st.kind == "Keyword" and st.value == "do" and pDepth == 0 then
						doIdx = scan
						break
					end
					scan += 1
				end
				pushScopeFrame(scopeStack, {
					frameKind = "Loop",
					loopVarName = nil,
					loopKeyVarName = nil,
					loopEval = nil,
					condStartIdx = nil,
					condEndIdx = nil,
					condRawText = nil,
					isElseBranch = nil,
				})
				if doIdx ~= nil then
					i = doIdx + 1
					continue
				end

			elseif kw == "repeat" then
				pushScopeFrame(scopeStack, {
					frameKind = "Loop",
					loopVarName = nil,
					loopKeyVarName = nil,
					loopEval = nil,
					condStartIdx = nil,
					condEndIdx = nil,
					condRawText = nil,
					isElseBranch = nil,
				})
				i += 1
				continue

			elseif kw == "function" then
				pushScopeFrame(scopeStack, {
					frameKind = "Function",
					loopVarName = nil,
					loopKeyVarName = nil,
					loopEval = nil,
					condStartIdx = nil,
					condEndIdx = nil,
					condRawText = nil,
					isElseBranch = nil,
				})
				i += 1
				continue

			elseif kw == "if" then
				-- Check if this is a Luau inline `if a then b else c` ternary expression vs statement `if a then ... end`
				-- Note: tokenizeLuau increments blockDepth on `then` and decrements on `end`.
				-- Look ahead to matching `then` at paren depth 0:
				local thenIdx: number? = nil
				local pDepth = 0
				local scan = i + 1
				while scan <= count do
					local st = tokens[scan]
					if st.kind == "Symbol" then
						if st.value == "(" or st.value == "{" or st.value == "[" then
							pDepth += 1
						elseif st.value == ")" or st.value == "}" or st.value == "]" then
							pDepth = math.max(0, pDepth - 1)
						end
					elseif st.kind == "Keyword" and st.value == "then" and pDepth == 0 then
						thenIdx = scan
						break
					end
					scan += 1
				end

				if thenIdx ~= nil and thenIdx > i + 1 then
					local cStart = i + 1
					local cEnd = thenIdx - 1
					local condRaw = string.sub(source, tokens[cStart].rawStart, tokens[cEnd].rawEnd)
					pushScopeFrame(scopeStack, {
						frameKind = "Conditional",
						loopVarName = nil,
						loopKeyVarName = nil,
						loopEval = nil,
						condStartIdx = cStart,
						condEndIdx = cEnd,
						condRawText = condRaw,
						isElseBranch = false,
					})
					i = thenIdx + 1
					continue
				end

			elseif kw == "elseif" then
				local thenIdx: number? = nil
				local pDepth = 0
				local scan = i + 1
				while scan <= count do
					local st = tokens[scan]
					if st.kind == "Symbol" then
						if st.value == "(" or st.value == "{" or st.value == "[" then
							pDepth += 1
						elseif st.value == ")" or st.value == "}" or st.value == "]" then
							pDepth = math.max(0, pDepth - 1)
						end
					elseif st.kind == "Keyword" and st.value == "then" and pDepth == 0 then
						thenIdx = scan
						break
					end
					scan += 1
				end

				if thenIdx ~= nil and thenIdx > i + 1 then
					local cStart = i + 1
					local cEnd = thenIdx - 1
					local condRaw = string.sub(source, tokens[cStart].rawStart, tokens[cEnd].rawEnd)
					if #scopeStack > 0 and scopeStack[#scopeStack].frameKind == "Conditional" then
						scopeStack[#scopeStack].condStartIdx = cStart
						scopeStack[#scopeStack].condEndIdx = cEnd
						scopeStack[#scopeStack].condRawText = condRaw
						scopeStack[#scopeStack].isElseBranch = false
					end
					i = thenIdx + 1
					continue
				end

			elseif kw == "else" then
				if #scopeStack > 0 and scopeStack[#scopeStack].frameKind == "Conditional" then
					local topFrame = scopeStack[#scopeStack]
					local prevRaw = topFrame.condRawText or "condition"
					topFrame.condRawText = "not (" .. prevRaw .. ")"
					topFrame.isElseBranch = true
				end
				i += 1
				continue

			elseif kw == "do" then
				pushScopeFrame(scopeStack, {
					frameKind = "DoBlock",
					loopVarName = nil,
					loopKeyVarName = nil,
					loopEval = nil,
					condStartIdx = nil,
					condEndIdx = nil,
					condRawText = nil,
					isElseBranch = nil,
				})
				i += 1
				continue

			elseif kw == "end" or kw == "until" then
				if #scopeStack > 0 then
					table.remove(scopeStack)
				end
				i += 1
				continue

			-- 2. Track `local <Ident> = <Expr>` single-instance, collection, and `require` function aliases
			elseif kw == "local" and i + 3 <= count then
				local identTok = tokens[i + 1]
				if identTok ~= nil and identTok.kind == "Identifier" and (assignmentCounts[identTok.value] or 0) == 1 then
					local eqIdx: number? = nil
					if tokens[i + 2].kind == "Symbol" and tokens[i + 2].value == "=" then
						eqIdx = i + 2
					elseif tokens[i + 2].kind == "Symbol" and tokens[i + 2].value == ":" then
						local scan = i + 3
						while scan <= count and scan <= i + 24 do
							if tokens[scan].kind == "Symbol" and tokens[scan].value == "=" then
								eqIdx = scan
								break
							end
							scan += 1
						end
					end

					if eqIdx ~= nil and eqIdx + 1 <= count then
						local exprStart = eqIdx + 1
						local exprStartTok = tokens[exprStart]
						local exprEnd = findAssignmentExprEnd(tokens, exprStart, count)
						local sNorm, eNorm = normalizeExprRange(tokens, exprStart, exprEnd)
						local afterExprTok = tokens[exprEnd + 1]
						local isFollowedByStringCall = afterExprTok ~= nil
							and (afterExprTok.kind == "String" or afterExprTok.kind == "InterpolatedString")

						-- Check for function alias to `require`: `local a = require` or `local b = a`
						if
							sNorm == eNorm
							and tokens[sNorm].kind == "Identifier"
							and isRequireIdentifier(tokens[sNorm].value)
							and not isFollowedByStringCall
						then
							requireAliases[identTok.value] = tokens[sNorm].value
							i = exprEnd + 1
							continue
						end

						-- Don't treat `local x = require(...)` or `local x = a(...)` or `local x = a "..."` as a path alias;
						-- jump to `exprStart` so step 3 analyzes the require call.
						local isRequireCall = (
							exprStartTok.kind == "Identifier" and isRequireIdentifier(exprStartTok.value)
						)
						if not isRequireCall then
							-- Check if it's a collection expression (`:GetChildren()`, `:GetDescendants()`, `{...}`, `ipairs/pairs`, or collection alias)
							local isCollectionSyntax = false
							if sNorm <= eNorm then
								if tokens[sNorm].kind == "Symbol" and tokens[sNorm].value == "{" then
									isCollectionSyntax = true
								elseif
									tokens[sNorm].kind == "Identifier"
									and (
										tokens[sNorm].value == "ipairs"
										or tokens[sNorm].value == "pairs"
										or collections[tokens[sNorm].value] ~= nil
									)
								then
									isCollectionSyntax = true
								elseif
									eNorm >= sNorm + 4
									and tokens[eNorm].value == ")"
									and tokens[eNorm - 1].value == "("
									and tokens[eNorm - 2].kind == "Identifier"
									and (tokens[eNorm - 2].value == "GetChildren" or tokens[eNorm - 2].value == "GetDescendants")
									and tokens[eNorm - 3].value == ":"
								then
									isCollectionSyntax = true
								end
							end

							if isCollectionSyntax then
								local activeLoops = getActiveLoopMap()
								local colEval = evaluateCollectionExpression(
									tokens,
									source,
									exprStart,
									exprEnd,
									currentScript,
									root,
									aliases,
									collections,
									activeLoops
								)
								if colEval.status ~= "Unresolved" or #colEval.instances > 0 then
									collections[identTok.value] = colEval
								end
								i = exprEnd + 1
								continue
							elseif
								exprStartTok.kind == "Identifier"
								and (
									exprStartTok.value == "game"
									or exprStartTok.value == "script"
									or exprStartTok.value == "workspace"
									or exprStartTok.value == "Workspace"
									or aliases[exprStartTok.value] ~= nil
								)
							then
								local evalRes = evaluateInstancePathTokens(
									tokens,
									source,
									exprStart,
									exprEnd,
									currentScript,
									root,
									aliases
								)
								if evalRes.instance ~= nil or evalRes.status == "PartiallyResolved" then
									aliases[identTok.value] = evalRes
								end
								i = exprEnd + 1
								continue
							elseif exprStartTok.kind == "String" or exprStartTok.kind == "Number" then
								local nextAfterLiteral = tokens[exprStart + 1]
								local isStandaloneLiteral = nextAfterLiteral == nil
									or nextAfterLiteral.line > exprStartTok.line
									or (
										nextAfterLiteral.kind == "Symbol"
										and nextAfterLiteral.value ~= ".."
										and nextAfterLiteral.value ~= "+"
										and nextAfterLiteral.value ~= "-"
										and nextAfterLiteral.value ~= "*"
										and nextAfterLiteral.value ~= "/"
									)
									or nextAfterLiteral.kind == "Keyword"
									or nextAfterLiteral.kind == "Identifier"

								if isStandaloneLiteral then
									local evalRes = evaluateInstancePathTokens(
										tokens,
										source,
										exprStart,
										exprStart,
										currentScript,
										root,
										aliases
									)
									aliases[identTok.value] = evalRes
									i = exprStart + 1
									continue
								end
							end
						end
					end
				end
			end
		end

		-- 2b. Track non-local single-assignment `a = require` (e.g. after `local a`)
		if
			tok.kind == "Identifier"
			and not isFieldOrProp
			and (prevTok == nil or prevTok.kind ~= "Keyword" or prevTok.value ~= "local")
			and (assignmentCounts[tok.value] or 0) == 1
			and i + 2 <= count
			and tokens[i + 1].kind == "Symbol"
			and tokens[i + 1].value == "="
		then
			local exprStart = i + 2
			local exprEnd = findAssignmentExprEnd(tokens, exprStart, count)
			local sNorm, eNorm = normalizeExprRange(tokens, exprStart, exprEnd)
			local afterExprTok = tokens[exprEnd + 1]
			local isFollowedByStringCall = afterExprTok ~= nil
				and (afterExprTok.kind == "String" or afterExprTok.kind == "InterpolatedString")
			if
				sNorm == eNorm
				and tokens[sNorm].kind == "Identifier"
				and isRequireIdentifier(tokens[sNorm].value)
				and not isFollowedByStringCall
			then
				requireAliases[tok.value] = tokens[sNorm].value
				i = exprEnd + 1
				continue
			end
		end

		-- 3. Match `require( <arg> )`, `require "StringPath"`, or aliased `a( <arg> )`, `a "StringPath"`
		local isFieldOrDeclaration = prevTok ~= nil
			and (
				(prevTok.kind == "Symbol" and (prevTok.value == "." or prevTok.value == ":"))
				or (prevTok.kind == "Keyword" and (prevTok.value == "function" or prevTok.value == "local"))
			)

		if tok.kind == "Identifier" and isRequireIdentifier(tok.value) and not isFieldOrDeclaration then
			local calleeName = tok.value
			local nextTok = tokens[i + 1]
			local scopeKind: RequireScopeKind = computeCurrentScopeKind(scopeStack)
			local isTopLevel = (tok.blockDepth == 0)
			local hasCondition, combinedConditionText, activeCondFrames = collectActiveConditions(scopeStack)

			if nextTok ~= nil and nextTok.kind == "Symbol" and nextTok.value == "(" then
				local pDepth = 1
				local closeIdx: number? = nil
				local scan = i + 2
				while scan <= count do
					local st = tokens[scan]
					if st.kind == "Symbol" then
						if st.value == "(" then
							pDepth += 1
						elseif st.value == ")" then
							pDepth -= 1
							if pDepth == 0 then
								closeIdx = scan
								break
							end
						end
					end
					scan += 1
				end

				if closeIdx ~= nil then
					local argStart = i + 2
					local argEnd = closeIdx - 1
					local rawExpr = if argStart <= argEnd
						then string.sub(source, tokens[argStart].rawStart, tokens[argEnd].rawEnd)
						else ""
					local sArg, eArg = normalizeExprRange(tokens, argStart, argEnd)
					local activeLoops = getActiveLoopMap()

					-- Case A: Require argument starts with an active loop variable (`require(module)` or `require(folder.SubModule)`)
					if
						sArg <= eArg
						and tokens[sArg].kind == "Identifier"
						and activeLoops[tokens[sArg].value] ~= nil
					then
						local loopVarName = tokens[sArg].value
						local loopEval = activeLoops[loopVarName]
						local groupId = string.format("%s:L%d:C%d", currentScript.fullPath, tok.line, tok.column)

						-- Filter and resolve candidate ModuleScripts
						local matchedModules: { ModuleScript } = {}
						local matchedPaths: { string } = {}
						local seenPaths: { [string]: boolean } = {}
						local hasNonTrivialCondition = false

						for _, candInst in loopEval.instances do
							-- Check all active enclosing conditions against `candInst`
							local excludedByStaticCond = false
							for _, condFrame in activeCondFrames do
								if condFrame.isElseBranch == true then
									hasNonTrivialCondition = true
								elseif condFrame.condStartIdx ~= nil and condFrame.condEndIdx ~= nil then
									local cMatch, cStatic, isPureModCheck = evaluateConditionForCandidate(
										tokens,
										condFrame.condStartIdx,
										condFrame.condEndIdx,
										loopVarName,
										candInst
									)
									if not isPureModCheck then
										hasNonTrivialCondition = true
									end
									if cStatic and cMatch == false then
										excludedByStaticCond = true
										break
									end
								else
									hasNonTrivialCondition = true
								end
							end

							if not excludedByStaticCond then
								local targetInst: Instance? = nil
								if sArg == eArg then
									targetInst = candInst
								else
									local subEval = evaluateSuffixFromInstance(
										candInst,
										tokens,
										source,
										sArg + 1,
										eArg,
										root,
										loopVarName
									)
									if subEval.status == "Resolved" then
										targetInst = subEval.instance
									end
								end

								if targetInst ~= nil then
									local modInst = safeIsModuleScript(targetInst)
									if modInst ~= nil then
										local modPath = ScriptDiscovery.getCleanFullPath(modInst, root)
										if not seenPaths[modPath] then
											seenPaths[modPath] = true
											table.insert(matchedModules, modInst)
											table.insert(matchedPaths, modPath)
										end
									end
								end
							end
						end

						local dynamicClassification: DependencyClassification = if hasNonTrivialCondition
							then "Conditional"
							elseif loopEval.status == "PartiallyResolved" then "DynamicPartial"
							else "DynamicResolved"

						local loopAliasNote = formatRequireUsedAlias(calleeName, loopEval.usedAlias or loopVarName)

						if #matchedModules > 0 then
							for _, modInst in matchedModules do
								local modPath = ScriptDiscovery.getCleanFullPath(modInst, root)
								pushRecord(records, {
									requiringScriptPath = currentScript.fullPath,
									requiringScriptName = currentScript.name,
									requiringScriptClass = currentScript.className,
									rawExpression = rawExpr,
									lineNumber = tok.line,
									columnNumber = tok.column,
									isTopLevel = isTopLevel,
									scopeKind = scopeKind,
									status = "Resolved",
									classification = dynamicClassification,
									isDynamic = true,
									isConditional = hasCondition,
									conditionExpression = combinedConditionText,
									candidateModulePaths = matchedPaths,
									expansionGroupId = groupId,
									resolvedModulePath = modPath,
									resolvedModuleName = modInst.Name,
									resolvedInstance = modInst,
									partialBasePath = loopEval.basePath,
									failureReason = nil,
									usedAlias = loopAliasNote,
								})
							end
						else
							local emptyStatus: ResolutionStatus = if loopEval.basePath ~= nil or loopEval.status == "Resolved"
								then "PartiallyResolved"
								else "Unresolved"
							local emptyClass: DependencyClassification = if emptyStatus == "PartiallyResolved"
								then (if hasNonTrivialCondition then "Conditional" else "DynamicPartial")
								else "Unresolved"
							local emptyReason = if loopEval.status ~= "Resolved" and loopEval.failureReason ~= nil
								then loopEval.failureReason
								elseif hasNonTrivialCondition and combinedConditionText ~= nil then string.format(
									"Iterable container '%s' resolved, but 0 ModuleScript candidates matched condition (%s)",
									loopEval.basePath or loopVarName,
									combinedConditionText
								)
								else string.format(
									"Iterable container '%s' resolved, but currently contains 0 ModuleScript candidates",
									loopEval.basePath or loopVarName
								)

							pushRecord(records, {
								requiringScriptPath = currentScript.fullPath,
								requiringScriptName = currentScript.name,
								requiringScriptClass = currentScript.className,
								rawExpression = rawExpr,
								lineNumber = tok.line,
								columnNumber = tok.column,
								isTopLevel = isTopLevel,
								scopeKind = scopeKind,
								status = emptyStatus,
								classification = emptyClass,
								isDynamic = true,
								isConditional = hasCondition,
								conditionExpression = combinedConditionText,
								candidateModulePaths = {},
								expansionGroupId = groupId,
								resolvedModulePath = nil,
								resolvedModuleName = nil,
								resolvedInstance = nil,
								partialBasePath = loopEval.basePath,
								failureReason = emptyReason,
								usedAlias = loopAliasNote,
							})
						end

						i = closeIdx + 1
						continue
					end

					-- Case B: Standard static, alias, or non-loop expression
					local evalRes = evaluateInstancePathTokens(
						tokens,
						source,
						argStart,
						argEnd,
						currentScript,
						root,
						aliases
					)

					local finalStatus: ResolutionStatus = evalRes.status
					local resolvedModulePath: string? = nil
					local resolvedModuleName: string? = nil
					local resolvedInstance: ModuleScript? = nil
					local partialBasePath: string? = evalRes.partialBasePath
					local failureReason: string? = evalRes.failureReason

					if evalRes.status == "Resolved" and evalRes.instance ~= nil then
						local inst = evalRes.instance
						local modInst = safeIsModuleScript(inst)
						if modInst ~= nil then
							resolvedInstance = modInst
							resolvedModulePath = ScriptDiscovery.getCleanFullPath(modInst, root)
							resolvedModuleName = modInst.Name
						else
							finalStatus = "Unresolved"
							local nonModPath = ScriptDiscovery.getCleanFullPath(inst, root)
							partialBasePath = nonModPath
							failureReason = string.format(
								"Resolved target '%s' has ClassName '%s', expected 'ModuleScript'",
								nonModPath,
								inst.ClassName
							)
						end
					end

					local classification: DependencyClassification = if finalStatus == "Resolved"
						then (if hasCondition then "Conditional" else "Static")
						elseif finalStatus == "PartiallyResolved" then "DynamicPartial"
						else "Unresolved"
					local isDyn = (finalStatus ~= "Resolved")

					pushRecord(records, {
						requiringScriptPath = currentScript.fullPath,
						requiringScriptName = currentScript.name,
						requiringScriptClass = currentScript.className,
						rawExpression = rawExpr,
						lineNumber = tok.line,
						columnNumber = tok.column,
						isTopLevel = isTopLevel,
						scopeKind = scopeKind,
						status = finalStatus,
						classification = classification,
						isDynamic = isDyn,
						isConditional = hasCondition,
						conditionExpression = combinedConditionText,
						candidateModulePaths = nil,
						expansionGroupId = nil,
						resolvedModulePath = resolvedModulePath,
						resolvedModuleName = resolvedModuleName,
						resolvedInstance = resolvedInstance,
						partialBasePath = partialBasePath,
						failureReason = failureReason,
						usedAlias = formatRequireUsedAlias(calleeName, evalRes.usedAlias),
					})

					i = closeIdx + 1
					continue
				end
			elseif nextTok ~= nil and nextTok.kind == "String" then
				-- Handle `require "StringPath"` or `a "StringPath"` call syntax without parentheses
				local evalRes = evaluateStringRequirePath(nextTok.value, currentScript, root, nil)
				local finalStatus: ResolutionStatus = evalRes.status
				local resolvedModulePath: string? = nil
				local resolvedModuleName: string? = nil
				local resolvedInstance: ModuleScript? = nil
				local partialBasePath: string? = evalRes.partialBasePath
				local failureReason: string? = evalRes.failureReason

				if evalRes.status == "Resolved" and evalRes.instance ~= nil then
					local inst = evalRes.instance
					local modInst = safeIsModuleScript(inst)
					if modInst ~= nil then
						resolvedInstance = modInst
						resolvedModulePath = ScriptDiscovery.getCleanFullPath(modInst, root)
						resolvedModuleName = modInst.Name
					else
						finalStatus = "Unresolved"
						local nonModPath = ScriptDiscovery.getCleanFullPath(inst, root)
						partialBasePath = nonModPath
						failureReason = string.format(
							"Resolved target '%s' has ClassName '%s', expected 'ModuleScript'",
							nonModPath,
							inst.ClassName
						)
					end
				end

				local classification: DependencyClassification = if finalStatus == "Resolved"
					then (if hasCondition then "Conditional" else "Static")
					elseif finalStatus == "PartiallyResolved" then "DynamicPartial"
					else "Unresolved"

				pushRecord(records, {
					requiringScriptPath = currentScript.fullPath,
					requiringScriptName = currentScript.name,
					requiringScriptClass = currentScript.className,
					rawExpression = string.format("%q", nextTok.value),
					lineNumber = tok.line,
					columnNumber = tok.column,
					isTopLevel = isTopLevel,
					scopeKind = scopeKind,
					status = finalStatus,
					classification = classification,
					isDynamic = (finalStatus ~= "Resolved"),
					isConditional = hasCondition,
					conditionExpression = combinedConditionText,
					candidateModulePaths = nil,
					expansionGroupId = nil,
					resolvedModulePath = resolvedModulePath,
					resolvedModuleName = resolvedModuleName,
					resolvedInstance = resolvedInstance,
					partialBasePath = partialBasePath,
					failureReason = failureReason,
					usedAlias = formatRequireUsedAlias(calleeName, evalRes.usedAlias),
				})
				i += 2
				continue
			elseif nextTok ~= nil and nextTok.kind == "InterpolatedString" then
				pushRecord(records, {
					requiringScriptPath = currentScript.fullPath,
					requiringScriptName = currentScript.name,
					requiringScriptClass = currentScript.className,
					rawExpression = nextTok.value,
					lineNumber = tok.line,
					columnNumber = tok.column,
					isTopLevel = isTopLevel,
					scopeKind = scopeKind,
					status = "Unresolved",
					classification = "Unresolved",
					isDynamic = true,
					isConditional = hasCondition,
					conditionExpression = combinedConditionText,
					candidateModulePaths = nil,
					expansionGroupId = nil,
					resolvedModulePath = nil,
					resolvedModuleName = nil,
					resolvedInstance = nil,
					partialBasePath = nil,
					failureReason = string.format(
						"Interpolated string %s in require() cannot be statically resolved",
						nextTok.value
					),
					usedAlias = formatRequireUsedAlias(calleeName, nil),
				})
				i += 2
				continue
			end
		end

		i += 1
	end

	return records
end

-- Detects circular dependency cycles among resolved ModuleScripts
local function detectCircularChains(byScriptPath: { [string]: ScriptDependencySummary }): { { string } }
	local cycles: { { string } } = {}
	local visitedState: { [string]: number } = {} -- 0/nil = unvisited, 1 = visiting, 2 = done
	local stack: { string } = {}
	local stackIndex: { [string]: number } = {}
	local recordedCycleKeys: { [string]: boolean } = {}

	local sortedPaths: { string } = {}
	for path, summary in byScriptPath do
		if summary.script.isModule then
			table.insert(sortedPaths, path)
		end
	end
	table.sort(sortedPaths)

	local function dfs(currentPath: string)
		visitedState[currentPath] = 1
		table.insert(stack, currentPath)
		stackIndex[currentPath] = #stack

		local summary = byScriptPath[currentPath]
		if summary ~= nil then
			for _, depPath in summary.resolvedModules do
				local state = visitedState[depPath] or 0
				if state == 0 then
					dfs(depPath)
				elseif state == 1 then
					local cycleStart = stackIndex[depPath]
					if cycleStart ~= nil then
						local chain: { string } = {}
						for k = cycleStart, #stack do
							table.insert(chain, stack[k])
						end
						table.insert(chain, depPath)
						local key = table.concat(chain, " -> ")
						if not recordedCycleKeys[key] then
							recordedCycleKeys[key] = true
							table.insert(cycles, chain)
						end
					end
				end
			end
		end

		stackIndex[currentPath] = nil
		table.remove(stack)
		visitedState[currentPath] = 2
	end

	for _, path in sortedPaths do
		if (visitedState[path] or 0) == 0 then
			dfs(path)
		end
	end

	return cycles
end

function DependencyAnalyzer.analyzeAll(
	discoveredScripts: { DiscoveredScript },
	root: Instance
): DependencyAnalysisResult
	local allDependencies: { DependencyRecord } = {}
	local resolvedDependencies: { DependencyRecord } = {}
	local unresolvedDependencies: { DependencyRecord } = {}
	local byScriptPath: { [string]: ScriptDependencySummary } = {}
	local incomingMap: { [string]: { [string]: boolean } } = {}

	for _, scriptInfo in discoveredScripts do
		byScriptPath[scriptInfo.fullPath] = {
			script = scriptInfo,
			dependencies = {},
			resolvedModules = {},
			unresolvedRecords = {},
			requiredByPaths = {},
		}
		incomingMap[scriptInfo.fullPath] = {}
	end

	for _, scriptInfo in discoveredScripts do
		local summary = byScriptPath[scriptInfo.fullPath]
		local records = DependencyAnalyzer.analyzeScriptSource(scriptInfo, root)
		local seenResolvedForScript: { [string]: boolean } = {}

		for _, rec in records do
			table.insert(allDependencies, rec)
			table.insert(summary.dependencies, rec)

			if rec.status == "Resolved" and rec.resolvedModulePath ~= nil then
				table.insert(resolvedDependencies, rec)
				local targetPath = rec.resolvedModulePath
				if not seenResolvedForScript[targetPath] then
					seenResolvedForScript[targetPath] = true
					table.insert(summary.resolvedModules, targetPath)
				end

				if incomingMap[targetPath] == nil then
					incomingMap[targetPath] = {}
				end
				incomingMap[targetPath][scriptInfo.fullPath] = true
			else
				table.insert(unresolvedDependencies, rec)
				table.insert(summary.unresolvedRecords, rec)
			end
		end
	end

	-- Populate reverse dependencies (`requiredByPaths`) and unused modules
	local unusedModulePaths: { string } = {}
	for _, scriptInfo in discoveredScripts do
		local path = scriptInfo.fullPath
		local summary = byScriptPath[path]
		local incomingSet = incomingMap[path]
		if incomingSet ~= nil then
			for reqPath, _ in incomingSet do
				table.insert(summary.requiredByPaths, reqPath)
			end
			table.sort(summary.requiredByPaths)
		end

		if scriptInfo.isModule and #summary.requiredByPaths == 0 then
			table.insert(unusedModulePaths, path)
		end
	end
	table.sort(unusedModulePaths)

	local circularChains = detectCircularChains(byScriptPath)

	return {
		allDependencies = allDependencies,
		resolvedDependencies = resolvedDependencies,
		unresolvedDependencies = unresolvedDependencies,
		byScriptPath = byScriptPath,
		unusedModulePaths = unusedModulePaths,
		circularChains = circularChains,
	}
end

return DependencyAnalyzer
