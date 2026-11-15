--!strict
--[[
	DependencyAnalyzer.luau
	Performs static lexical and syntactic analysis of Luau script sources to discover
	require() calls, resolve static Instance/ModuleScript paths against the DataModel,
	and report unresolved or partially resolved dynamic expressions.
]]

local Types = require("./Types")
local ScriptDiscovery = require("./ScriptDiscovery")

type DiscoveredScript = Types.DiscoveredScript
type DependencyRecord = Types.DependencyRecord
type ResolutionStatus = Types.ResolutionStatus
type ScriptDependencySummary = Types.ScriptDependencySummary
type DependencyAnalysisResult = Types.DependencyAnalysisResult

type TokenKind = "Identifier" | "Keyword" | "String" | "InterpolatedString" | "Number" | "Symbol"

type Token = {
	kind: TokenKind,
	value: string,
	line: number,
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

-- Scans until matching closing long bracket `]==]`, updating line count
local function scanLongBracketClose(source: string, startPos: number, eqCount: number, startLine: number): (number, number, string)
	local len = #source
	local cursor = startPos
	local line = startLine

	while cursor <= len do
		local b = string.byte(source, cursor)
		if b == 10 then -- '\n'
			line += 1
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
				return check + 1, line, content
			end
			cursor += 1
		else
			cursor += 1
		end
	end

	local remaining = string.sub(source, startPos, len)
	return len + 1, line, remaining
end

local function pushToken(list: { Token }, tok: Token)
	table.insert(list, tok)
end

local function pushRecord(list: { DependencyRecord }, rec: DependencyRecord)
	table.insert(list, rec)
end

function DependencyAnalyzer.tokenizeLuau(source: string): { Token }
	local tokens: { Token } = {}
	local len = #source
	local pos = 1
	local line = 1
	local blockDepth = 0
	local pendingLoopHeader = false

	while pos <= len do
		local b = string.byte(source, pos)

		-- Whitespace
		if b == 32 or b == 9 or b == 13 or b == 10 then
			if b == 10 then
				line += 1
			end
			pos += 1

		-- Comment: `--`
		elseif b == 45 and pos + 1 <= len and string.byte(source, pos + 1) == 45 then
			local commentStart = pos + 2
			local longStart, eqCount = matchLongBracketOpen(source, commentStart)
			if longStart ~= nil then
				local nextPos, nextLine, _ = scanLongBracketClose(source, longStart, eqCount, line)
				pos = nextPos
				line = nextLine
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
				local nextPos, nextLine, content = scanLongBracketClose(source, longStart, eqCount, line)
				pushToken(tokens, {
					kind = "String",
					value = content,
					line = tokenLine,
					rawStart = rawStart,
					rawEnd = nextPos - 1,
					blockDepth = blockDepth,
				})
				pos = nextPos
				line = nextLine
			else
				pushToken(tokens, {
					kind = "Symbol",
					value = "[",
					line = line,
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
			pos += 1
			local chars: { string } = {}
			while pos <= len do
				local cb = string.byte(source, pos)
				if cb == 92 then -- '\' escape
					if pos + 1 <= len then
						local nextByte = string.byte(source, pos + 1)
						if nextByte == 10 then
							line += 1
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
				rawStart = rawStart,
				rawEnd = pos - 1,
				blockDepth = blockDepth,
			})

		-- Interpolated string literal `` `...` ``
		elseif b == 96 then
			local rawStart = pos
			local tokenLine = line
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
					pos += 1
				else
					pos += 1
				end
			end
			pushToken(tokens, {
				kind = "InterpolatedString",
				value = string.sub(source, rawStart, pos - 1),
				line = tokenLine,
				rawStart = rawStart,
				rawEnd = pos - 1,
				blockDepth = blockDepth,
			})

		-- Identifier or Keyword
		elseif isAlpha(b) then
			local rawStart = pos
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
				rawStart = rawStart,
				rawEnd = pos - 1,
				blockDepth = tokenBlockDepth,
			})

		-- Number literal
		elseif isDigit(b) then
			local rawStart = pos
			pos += 1
			while pos <= len do
				local nb = string.byte(source, pos)
				if isAlphaNumeric(nb) or nb == 46 then -- allow hex, binary, decimals, underscores
					pos += 1
				else
					break
				end
			end
			pushToken(tokens, {
				kind = "Number",
				value = string.sub(source, rawStart, pos - 1),
				line = line,
				rawStart = rawStart,
				rawEnd = pos - 1,
				blockDepth = blockDepth,
			})

		-- Multi-character or single-character symbols
		else
			local rawStart = pos
			local sym = string.sub(source, pos, pos)
			if pos + 1 <= len then
				local twoChar = string.sub(source, pos, pos + 1)
				if twoChar == "::" or twoChar == ".." or twoChar == "==" or twoChar == "~=" or twoChar == "<=" or twoChar == ">=" or twoChar == "->" then
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
			-- Also check if inner expression has trailing `:: Type`
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

	local cursor = s + 1
	while cursor <= e do
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
			-- Find matching `]`
			local bDepth = 1
			local closeBracketIdx: number? = nil
			local scanIdx = cursor + 1
			while scanIdx <= e do
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

			if methodTok == nil or methodTok.kind ~= "Identifier" or openParenTok == nil or openParenTok.kind ~= "Symbol" or openParenTok.value ~= "(" then
				return {
					status = "PartiallyResolved",
					instance = nil,
					partialBasePath = basePath,
					failureReason = string.format("Malformed method call on '%s'", basePath),
					usedAlias = usedAlias,
				}
			end

			local methodName = methodTok.value
			-- Find matching `)`
			local pDepth = 1
			local closeParenIdx: number? = nil
			local scanIdx = cursor + 3
			while scanIdx <= e do
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
			local remainingRaw = string.sub(rawSource, opTok.rawStart, tokens[e].rawEnd)
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

-- Extracts unambiguous top-level `local <Ident> = <StaticInstancePath>` aliases that are never reassigned
local function extractStaticAliases(
	tokens: { Token },
	rawSource: string,
	currentScript: DiscoveredScript,
	root: Instance
): { [string]: PathEvalResult }
	local aliases: { [string]: PathEvalResult } = {}
	local assignmentCounts: { [string]: number } = {}
	local count = #tokens

	-- First pass: count how many times each identifier is assigned (`local x =` or `x =`)
	for i = 1, count do
		local tok = tokens[i]
		if tok.kind == "Identifier" then
			local prevTok = if i > 1 then tokens[i - 1] else nil
			local nextTok = if i < count then tokens[i + 1] else nil
			if prevTok == nil or (prevTok.value ~= "." and prevTok.value ~= ":") then
				if nextTok ~= nil and nextTok.kind == "Symbol" and nextTok.value == "=" then
					assignmentCounts[tok.value] = (assignmentCounts[tok.value] or 0) + 1
				elseif nextTok ~= nil and nextTok.kind == "Symbol" and nextTok.value == ":" then
					-- Handle `local x: Type = ...`
					if prevTok ~= nil and prevTok.kind == "Keyword" and prevTok.value == "local" then
						local scan = i + 2
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

	-- Second pass: evaluate single-assignment `local <Ident> = <PathExpr>` declarations
	local idx = 1
	while idx <= count - 3 do
		local tok = tokens[idx]
		if tok.kind == "Keyword" and tok.value == "local" and tok.blockDepth == 0 then
			local identTok = tokens[idx + 1]
			if identTok ~= nil and identTok.kind == "Identifier" and (assignmentCounts[identTok.value] or 0) == 1 then
				local eqIdx: number? = nil
				if tokens[idx + 2].kind == "Symbol" and tokens[idx + 2].value == "=" then
					eqIdx = idx + 2
				elseif tokens[idx + 2].kind == "Symbol" and tokens[idx + 2].value == ":" then
					local scan = idx + 3
					while scan <= count and scan <= idx + 12 do
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
					if
						exprStartTok.kind == "Identifier"
						and (
							exprStartTok.value == "game"
							or exprStartTok.value == "script"
							or exprStartTok.value == "workspace"
							or exprStartTok.value == "Workspace"
							or aliases[exprStartTok.value] ~= nil
						)
						and exprStartTok.value ~= "require"
					then
						-- Scan the chained path expression `.Foo`, `:Bar(...)`, `["Baz"]`
						local exprEnd = exprStart
						local scan = exprStart + 1
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

						local evalRes = evaluateInstancePathTokens(
							tokens,
							rawSource,
							exprStart,
							exprEnd,
							currentScript,
							root,
							aliases
						)
						if evalRes.instance ~= nil or evalRes.status == "PartiallyResolved" then
							aliases[identTok.value] = evalRes
						end
						idx = exprEnd + 1
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
								rawSource,
								exprStart,
								exprStart,
								currentScript,
								root,
								aliases
							)
							aliases[identTok.value] = evalRes
							idx = exprStart + 1
							continue
						end
					end
				end
			end
		end
		idx += 1
	end

	return aliases
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
	local aliases = extractStaticAliases(tokens, source, currentScript, root)
	local count = #tokens
	local i = 1

	while i <= count do
		local tok = tokens[i]
		local prevTok = if i > 1 then tokens[i - 1] else nil
		local isFieldOrDeclaration = prevTok ~= nil
			and (
				(prevTok.kind == "Symbol" and (prevTok.value == "." or prevTok.value == ":"))
				or (prevTok.kind == "Keyword" and (prevTok.value == "function" or prevTok.value == "local"))
			)

		-- Match `require( <arg> )`
		if tok.kind == "Identifier" and tok.value == "require" and not isFieldOrDeclaration then
			local nextTok = tokens[i + 1]
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
						local okMod, isMod = pcall(function(): boolean
							return inst:IsA("ModuleScript")
						end)
						if okMod and isMod and inst:IsA("ModuleScript") then
							resolvedInstance = inst
							resolvedModulePath = ScriptDiscovery.getCleanFullPath(inst, root)
							resolvedModuleName = inst.Name
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

					pushRecord(records, {
						requiringScriptPath = currentScript.fullPath,
						requiringScriptName = currentScript.name,
						requiringScriptClass = currentScript.className,
						rawExpression = rawExpr,
						lineNumber = tok.line,
						isTopLevel = (tok.blockDepth == 0),
						status = finalStatus,
						resolvedModulePath = resolvedModulePath,
						resolvedModuleName = resolvedModuleName,
						resolvedInstance = resolvedInstance,
						partialBasePath = partialBasePath,
						failureReason = failureReason,
						usedAlias = evalRes.usedAlias,
					})

					i = closeIdx + 1
					continue
				end
			elseif nextTok ~= nil and nextTok.kind == "String" then
				-- Handle `require "StringPath"` call syntax without parentheses
				local evalRes = evaluateStringRequirePath(nextTok.value, currentScript, root, nil)
				local finalStatus: ResolutionStatus = evalRes.status
				local resolvedModulePath: string? = nil
				local resolvedModuleName: string? = nil
				local resolvedInstance: ModuleScript? = nil
				local partialBasePath: string? = evalRes.partialBasePath
				local failureReason: string? = evalRes.failureReason

				if evalRes.status == "Resolved" and evalRes.instance ~= nil then
					local inst = evalRes.instance
					local okMod, isMod = pcall(function(): boolean
						return inst:IsA("ModuleScript")
					end)
					if okMod and isMod and inst:IsA("ModuleScript") then
						resolvedInstance = inst
						resolvedModulePath = ScriptDiscovery.getCleanFullPath(inst, root)
						resolvedModuleName = inst.Name
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

				pushRecord(records, {
					requiringScriptPath = currentScript.fullPath,
					requiringScriptName = currentScript.name,
					requiringScriptClass = currentScript.className,
					rawExpression = string.format("%q", nextTok.value),
					lineNumber = tok.line,
					isTopLevel = (tok.blockDepth == 0),
					status = finalStatus,
					resolvedModulePath = resolvedModulePath,
					resolvedModuleName = resolvedModuleName,
					resolvedInstance = resolvedInstance,
					partialBasePath = partialBasePath,
					failureReason = failureReason,
					usedAlias = evalRes.usedAlias,
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
