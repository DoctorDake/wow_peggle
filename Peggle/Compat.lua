-- Compatibility layer for the modern (Midnight-based) client used by WoW Forever.
-- Everything lives in the addon's private table; nothing is added to _G.
-- Each shim prefers the current API and falls back to the legacy one, so the
-- addon keeps loading on older clients too.

local _, ns = ...
local compat = {}
ns.compat = compat

local _G = _G
local pcall, type, select = pcall, type, select

-------------------------------------------------------------------------------
-- Secret values (12.0+): chat payloads can be opaque while restrictions are
-- active. Any string operation on them errors, so callers bail out early.
-------------------------------------------------------------------------------
local issecretvalue = _G.issecretvalue

function compat.IsSecret(...)
	if not issecretvalue then
		return false
	end
	for i = 1, select("#", ...) do
		if issecretvalue((select(i, ...))) then
			return true
		end
	end
	return false
end

-------------------------------------------------------------------------------
-- Globals / named children
-------------------------------------------------------------------------------
function compat.getglobal(name)
	return _G[name]
end

local function LowerFirst(key)
	return key:sub(1, 1):lower()..key:sub(2)
end

-- Resolves a template child that used to be reachable as _G[frameName..key].
-- Modern templates expose most of these as parentKeys instead.
function compat.Child(frame, key)
	local name = frame:GetName()
	local obj = name and name ~= "" and _G[name..key]
	if obj then
		return obj
	end
	obj = frame[key]
	if type(obj) ~= "table" then
		obj = frame[LowerFirst(key)]
	end
	if type(obj) == "table" then
		return obj
	end
	if key == "Thumb" and frame.GetThumbTexture then
		obj = frame:GetThumbTexture()
		if obj then
			return obj
		end
	end
	if key == "Text" or key == "Low" or key == "High" then
		obj = frame:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
		if key == "Text" then
			obj:SetPoint("BOTTOM", frame, "TOP")
		elseif key == "Low" then
			obj:SetPoint("TOPLEFT", frame, "BOTTOMLEFT")
		else
			obj:SetPoint("TOPRIGHT", frame, "BOTTOMRIGHT")
		end
		frame[key] = obj
		return obj
	end
	error("Peggle: missing child '"..key.."' on "..(name or "unnamed frame"), 2)
end

-------------------------------------------------------------------------------
-- Frame creation: backdrops and renamed/removed templates
-------------------------------------------------------------------------------
local hasBackdropTemplate = _G.BackdropTemplateMixin ~= nil

local templateFallbacks = {
	OptionsCheckButtonTemplate = {"InterfaceOptionsCheckButtonTemplate", "UICheckButtonTemplate"},
	OptionsSliderTemplate = {"UISliderTemplateWithLabels", "UISliderTemplate"},
	OptionsButtonTemplate = {"UIPanelButtonTemplate"},
}

local function NoOp()
end

local function CopyBackdrop(info)
	if type(info) ~= "table" then
		return info
	end
	local copy = {}
	for k, v in pairs(info) do
		if type(v) == "table" then
			local sub = {}
			for k2, v2 in pairs(v) do
				sub[k2] = v2
			end
			v = sub
		end
		copy[k] = v
	end
	-- The old API accepted any truthy value here (the addon passes tile = 1);
	-- the mixin hands it straight to Texture:SetTexture as a wrap mode, which
	-- only accepts a boolean or a wrap-mode string.
	if copy.tile ~= nil then
		copy.tile = copy.tile and true or false
	end
	if copy.tileEdge ~= nil then
		copy.tileEdge = copy.tileEdge and true or false
	end
	return copy
end

local function TryCreate(frameType, name, parent, template)
	if hasBackdropTemplate then
		local ok, frame = pcall(CreateFrame, frameType, name, parent, template and (template..", BackdropTemplate") or "BackdropTemplate")
		if ok and frame then
			return frame
		end
	end
	local ok, frame = pcall(CreateFrame, frameType, name, parent, template)
	if ok and frame then
		return frame
	end
end

local function SetupBackdrop(frame)
	if frame.SetBackdrop then
		if hasBackdropTemplate then
			-- The mixin keeps a reference to the table it is given; the addon
			-- reuses and mutates one table across frames, so hand it a copy.
			local setBackdrop = frame.SetBackdrop
			frame.SetBackdrop = function(self, info)
				return setBackdrop(self, CopyBackdrop(info))
			end
		end
	else
		frame.SetBackdrop = NoOp
		frame.SetBackdropColor = NoOp
		frame.SetBackdropBorderColor = NoOp
	end
end

local function BuildScrollBarFallback(slider)
	slider:SetOrientation("VERTICAL")
	slider:SetWidth(16)
	local thumb = slider:CreateTexture(nil, "ARTWORK")
	thumb:SetTexture("Interface\\Buttons\\UI-ScrollBar-Knob")
	thumb:SetWidth(18)
	thumb:SetHeight(24)
	thumb:SetTexCoord(0.20, 0.80, 0.125, 0.875)
	slider:SetThumbTexture(thumb)
	local function MakeButton(key, direction, point, relPoint)
		local button = CreateFrame("Button", nil, slider)
		button:SetWidth(18)
		button:SetHeight(16)
		button:SetPoint(point, slider, relPoint)
		local prefix = "Interface\\Buttons\\UI-ScrollBar-Scroll"..direction.."Button-"
		button:SetNormalTexture(prefix.."Up")
		button:SetPushedTexture(prefix.."Down")
		button:SetDisabledTexture(prefix.."Disabled")
		button:SetHighlightTexture(prefix.."Highlight", "ADD")
		slider[key] = button
	end
	MakeButton("ScrollUpButton", "Up", "BOTTOM", "TOP")
	MakeButton("ScrollDownButton", "Down", "TOP", "BOTTOM")
end

function compat.CreateFrame(frameType, name, parent, template)
	if name == "" then
		name = nil
	end
	local frame = TryCreate(frameType, name, parent, template)
	local usedTemplate = frame and template
	if not frame and template then
		local fallbacks = templateFallbacks[template]
		if fallbacks then
			for i = 1, #fallbacks do
				frame = TryCreate(frameType, name, parent, fallbacks[i])
				if frame then
					usedTemplate = fallbacks[i]
					break
				end
			end
		end
		if not frame then
			frame = TryCreate(frameType, name, parent, nil)
		end
	end
	if not frame then
		-- Let the real error surface.
		frame = CreateFrame(frameType, name, parent, template)
	end
	SetupBackdrop(frame)
	if template and not usedTemplate then
		if template == "UIPanelScrollBarTemplate" then
			BuildScrollBarFallback(frame)
		elseif template == "InputBoxTemplate" then
			frame:SetFontObject(_G.ChatFontNormal or _G.GameFontHighlight)
			frame:SetAutoFocus(false)
		end
	end
	return frame
end

-- Replacement for AutoCastShineTemplate (removed in 11.0): a frame with 16
-- additive sparkle textures, exposed as frame.sparkles[1..16].
function compat.CreateSparkFrame(name, parent)
	local frame = CreateFrame("Frame", name, parent)
	frame.sparkles = {}
	for i = 1, 16 do
		local size = 13 - 3 * math.floor((i - 1) / 4)
		local tex = frame:CreateTexture(nil, "OVERLAY")
		tex:SetTexture("Interface\\ItemSocketingFrame\\UI-ItemSockets")
		tex:SetTexCoord(0.3984375, 0.4453125, 0.40234375, 0.44921875)
		tex:SetBlendMode("ADD")
		tex:SetWidth(size)
		tex:SetHeight(size)
		tex:SetPoint("CENTER")
		frame.sparkles[i] = tex
	end
	return frame
end

-- Replacement for ActionButtonTemplate, whose layout and behaviour changed
-- completely in 10.0. Only the pieces the talent screen uses are built.
function compat.CreateTalentButton(name, parent)
	local button = CreateFrame("Button", name, parent)
	button:SetWidth(36)
	button:SetHeight(36)

	local icon = button:CreateTexture(nil, "BACKGROUND")
	icon:SetAllPoints(button)
	button.icon = icon

	local border = button:CreateTexture(nil, "OVERLAY")
	border:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
	border:SetBlendMode("ADD")
	border:SetWidth(62)
	border:SetHeight(62)
	border:SetPoint("CENTER")
	border:Hide()
	button.border = border

	local rank = button:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
	rank:SetJustifyH("RIGHT")
	rank:SetPoint("BOTTOMRIGHT", -2, 2)
	button.rank = rank

	button:SetPushedTexture("Interface\\Buttons\\UI-Quickslot-Depress")
	button:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
	return button
end

-- TalentBranchTemplate / TalentArrowTemplate went away with the old talent UI.
function compat.CreateTalentTexture(parent, layer, kind)
	local tex = parent:CreateTexture(nil, layer)
	tex:SetWidth(32)
	tex:SetHeight(32)
	if kind == "arrow" then
		tex:SetTexture("Interface\\TalentFrame\\UI-TalentArrows")
	else
		tex:SetTexture("Interface\\TalentFrame\\UI-TalentBranches")
	end
	return tex
end

-- Achievement style toast. The Blizzard template is used for its artwork when
-- it can be instantiated, but the animation is driven by compat.ToastOnUpdate
-- because AchievementAlertFrame_OnUpdate has not existed since 7.0.
function compat.CreateToast(name, parent)
	if not _G.AchievementFrame and _G.AchievementFrame_LoadUI then
		pcall(_G.AchievementFrame_LoadUI)
	end
	local ok, frame = pcall(CreateFrame, "Button", name, parent, "AchievementAlertFrameTemplate")
	if ok and frame then
		-- Detach from the alert system's own scripts and animations.
		frame:SetScript("OnShow", nil)
		frame:SetScript("OnHide", nil)
		frame:SetScript("OnClick", nil)
		frame:SetScript("OnEnter", nil)
		frame:SetScript("OnLeave", nil)
	else
		frame = compat.CreateFrame("Button", name, parent)
		frame:SetBackdrop({
			bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
			edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Gold-Border",
			tile = true, tileSize = 32, edgeSize = 32,
			insets = {left = 11, right = 12, top = 12, bottom = 11},
		})
	end
	if not frame.glow then
		frame.glow = frame.Glow or frame:CreateTexture(nil, "OVERLAY")
	end
	if not frame.shine then
		frame.shine = frame.Shine or frame:CreateTexture(nil, "OVERLAY")
	end
	frame.glow:Hide()
	frame.shine:Hide()
	return frame
end

function compat.ToastOnUpdate(self, elapsed)
	local t = (self.elapsed or 0) + elapsed
	self.elapsed = t
	local hold = self.holdDuration or 5
	if t < 0.3 then
		self:SetAlpha(t / 0.3)
	elseif t < 0.3 + hold then
		self:SetAlpha(1)
	elseif t < 1.8 + hold then
		self:SetAlpha(1 - (t - 0.3 - hold) / 1.5)
	else
		self:SetAlpha(0)
		self:SetScript("OnUpdate", nil)
		self:Hide()
	end
end

-------------------------------------------------------------------------------
-- Widget methods
-------------------------------------------------------------------------------
function compat.SetResizeBounds(frame, minWidth, minHeight, maxWidth, maxHeight)
	if frame.SetResizeBounds then
		frame:SetResizeBounds(minWidth, minHeight, maxWidth, maxHeight)
	else
		frame:SetMaxResize(maxWidth, maxHeight)
		frame:SetMinResize(minWidth, minHeight)
	end
end

function compat.MouseIsOver(frame)
	return frame:IsMouseOver()
end

function compat.SetDesaturation(texture, desaturated)
	texture:SetDesaturated(desaturated and true or false)
end

-- hooksecurefunc errors when the target global does not exist.
function compat.hooksecurefunc(name, hook)
	if type(_G[name]) == "function" then
		hooksecurefunc(name, hook)
	end
end

function compat.message(text)
	if _G.message then
		_G.message(text)
	else
		print(text)
	end
end

-------------------------------------------------------------------------------
-- Chat
-------------------------------------------------------------------------------
function compat.SendChatMessage(...)
	if C_ChatInfo and C_ChatInfo.SendChatMessage then
		return C_ChatInfo.SendChatMessage(...)
	end
	return _G.SendChatMessage(...)
end

function compat.AddMessageEventFilter(event, filter)
	if _G.ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter then
		ChatFrameUtil.AddMessageEventFilter(event, filter)
	elseif _G.ChatFrame_AddMessageEventFilter then
		ChatFrame_AddMessageEventFilter(event, filter)
	end
end

function compat.RemoveMessageEventFilter(event, filter)
	if _G.ChatFrameUtil and ChatFrameUtil.RemoveMessageEventFilter then
		ChatFrameUtil.RemoveMessageEventFilter(event, filter)
	elseif _G.ChatFrame_RemoveMessageEventFilter then
		ChatFrame_RemoveMessageEventFilter(event, filter)
	end
end

-------------------------------------------------------------------------------
-- Friends / guild
-------------------------------------------------------------------------------
function compat.GetNumFriends()
	if C_FriendList and C_FriendList.GetNumFriends then
		return C_FriendList.GetNumFriends() or 0
	elseif _G.GetNumFriends then
		return _G.GetNumFriends() or 0
	end
	return 0
end

-- Legacy return order: name, level, class, area, connected.
function compat.GetFriendInfo(index)
	if C_FriendList and C_FriendList.GetFriendInfoByIndex then
		local info = C_FriendList.GetFriendInfoByIndex(index)
		if info then
			return info.name, info.level, info.className, info.area, info.connected
		end
		return nil
	elseif _G.GetFriendInfo then
		return _G.GetFriendInfo(index)
	end
end

function compat.GetNumGuildMembers()
	if _G.GetNumGuildMembers then
		return _G.GetNumGuildMembers() or 0
	end
	return 0
end

function compat.GetGuildRosterInfo(index)
	if _G.GetGuildRosterInfo then
		return _G.GetGuildRosterInfo(index)
	end
end

function compat.SortGuildRoster(sort)
	if _G.SortGuildRoster then
		_G.SortGuildRoster(sort)
	end
end

function compat.SetGuildRosterShowOffline(show)
	if _G.SetGuildRosterShowOffline then
		_G.SetGuildRosterShowOffline(show)
	end
end

-------------------------------------------------------------------------------
-- Date / time
-------------------------------------------------------------------------------
local function CalendarTime()
	if C_DateAndTime and C_DateAndTime.GetCurrentCalendarTime then
		return C_DateAndTime.GetCurrentCalendarTime()
	elseif C_Calendar and C_Calendar.GetDate then
		return C_Calendar.GetDate()
	end
end

-- Returns a table with weekday, month, monthDay and year.
function compat.GetDate()
	local info = CalendarTime()
	if info then
		return info
	end
	local now = date("*t")
	return {weekday = now.wday, month = now.month, monthDay = now.day, year = now.year}
end

function compat.GetGameTime()
	if _G.GetGameTime then
		return _G.GetGameTime()
	end
	local info = CalendarTime()
	if info and info.hour then
		return info.hour, info.minute
	end
	local now = date("*t")
	return now.hour, now.min
end

-------------------------------------------------------------------------------
-- Dropdown menus
-- UIDropDownMenu has been deprecated since 11.0 and cannot be relied on, so the
-- small subset the addon uses is implemented here on plain frames.
-------------------------------------------------------------------------------
compat.UIDROPDOWNMENU_MENU_LEVEL = 1
compat.dropDownMaxWidth = nil

local ROW_PADDING = 12
local LIST_PADDING = 12
local ICON_SIZE = 16
local currentDropDown
local collecting
local list

local function FontObject(name, fallback)
	return _G[name] or _G[fallback] or _G.GameFontNormalSmall
end

local function ListButton_OnClick(self)
	if self.func then
		self.func(self, self.arg1, self.arg2, self.checked)
	end
	list:Hide()
end

local function GetList()
	if list then
		return list
	end
	list = compat.CreateFrame("Frame", "PeggleDropDownList", UIParent)
	list:SetFrameStrata("FULLSCREEN_DIALOG")
	list:SetClampedToScreen(true)
	list:EnableMouse(true)
	list:Hide()
	list:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true, tileSize = 16, edgeSize = 16,
		insets = {left = 5, right = 5, top = 5, bottom = 5},
	})
	list:SetBackdropColor(0.09, 0.09, 0.19, 1)
	list:SetBackdropBorderColor(1, 1, 1, 1)
	list.buttons = {}
	list.numButtons = 0
	list.idle = 0
	list:SetScript("OnUpdate", function(self, elapsed)
		local owner = self.owner
		if owner and not owner:IsVisible() then
			self:Hide()
		elseif self:IsMouseOver() or (owner and owner:IsMouseOver()) then
			self.idle = 0
		else
			self.idle = self.idle + elapsed
			if self.idle > 2 then
				self:Hide()
			end
		end
	end)
	return list
end

local function AcquireButton(index)
	local button = list.buttons[index]
	if button then
		return button
	end
	button = CreateFrame("Button", nil, list)
	button:SetHeight(16)
	local text = button:CreateFontString(nil, "ARTWORK")
	text:SetFontObject(FontObject("GameFontHighlightSmallLeft", "GameFontHighlightSmall"))
	text:SetJustifyH("LEFT")
	text:SetWordWrap(false)
	text:SetPoint("LEFT", ROW_PADDING / 2, 0)
	button:SetFontString(text)
	button.label = text
	local icon = button:CreateTexture(nil, "ARTWORK")
	icon:SetWidth(ICON_SIZE)
	icon:SetHeight(ICON_SIZE)
	icon:SetPoint("RIGHT", -ROW_PADDING / 2, 0)
	icon:Hide()
	button.iconTexture = icon
	local highlight = button:CreateTexture(nil, "HIGHLIGHT")
	highlight:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
	highlight:SetBlendMode("ADD")
	highlight:SetAllPoints(button)
	button:SetScript("OnClick", ListButton_OnClick)
	list.buttons[index] = button
	return button
end

function compat.UIDropDownMenu_AddButton(info)
	if collecting then
		collecting[#collecting + 1] = {text = info.text, value = info.value}
		return
	end
	if not list then
		return
	end
	local index = list.numButtons + 1
	list.numButtons = index
	local button = AcquireButton(index)
	button.func = info.func
	button.arg1 = info.arg1
	button.arg2 = info.arg2
	button.value = info.value
	button.checked = info.checked

	local label = button.label
	if info.fontObject then
		label:SetFontObject(info.fontObject)
	elseif info.isTitle then
		label:SetFontObject(FontObject("GameFontNormalSmallLeft", "GameFontNormalSmall"))
	elseif info.notClickable then
		label:SetFontObject(FontObject("GameFontDisableSmallLeft", "GameFontDisableSmall"))
	else
		label:SetFontObject(FontObject("GameFontHighlightSmallLeft", "GameFontHighlightSmall"))
	end
	label:SetWidth(0)
	button:SetText(info.text or "")

	local icon = button.iconTexture
	if info.icon then
		icon:SetTexture(info.icon)
		icon:SetTexCoord(info.tCoordLeft or 0, info.tCoordRight or 1, info.tCoordTop or 0, info.tCoordBottom or 1)
		icon:Show()
	else
		icon:Hide()
	end

	if info.isTitle or info.notClickable then
		button:EnableMouse(false)
	else
		button:EnableMouse(true)
	end
	button:Show()
end

local function LayoutList(maxWidth)
	local width, y = 0, -LIST_PADDING
	for i = 1, list.numButtons do
		local button = list.buttons[i]
		local rowWidth = (button.label:GetStringWidth() or 0) + ROW_PADDING
		if button.iconTexture:IsShown() then
			rowWidth = rowWidth + ICON_SIZE + 4
		end
		if rowWidth > width then
			width = rowWidth
		end
	end
	if maxWidth and width > maxWidth then
		width = maxWidth
	end
	if width < 60 then
		width = 60
	end
	for i = 1, list.numButtons do
		local button = list.buttons[i]
		local height = math.max(16, math.ceil((button.label:GetStringHeight() or 0) + 2))
		local labelWidth = width - ROW_PADDING
		if button.iconTexture:IsShown() then
			labelWidth = labelWidth - ICON_SIZE - 4
		end
		button.label:SetWidth(labelWidth)
		button:SetWidth(width)
		button:SetHeight(height)
		button:ClearAllPoints()
		button:SetPoint("TOPLEFT", list, "TOPLEFT", LIST_PADDING, y)
		y = y - height
	end
	list:SetWidth(width + LIST_PADDING * 2)
	list:SetHeight(-y + LIST_PADDING)
end

function compat.ToggleDropDown(dropDown)
	GetList()
	if list:IsShown() and list.owner == dropDown then
		list:Hide()
		return
	end
	list:Hide()
	for i = 1, #list.buttons do
		list.buttons[i]:Hide()
	end
	list.numButtons = 0
	list.owner = dropDown
	currentDropDown = dropDown
	compat.dropDownMaxWidth = nil
	if dropDown.initialize then
		dropDown.initialize(dropDown, 1)
	end
	if list.numButtons == 0 then
		return
	end
	LayoutList(compat.dropDownMaxWidth)
	local anchor = dropDown.dropAnchor
	list:ClearAllPoints()
	list:SetScale(dropDown:GetEffectiveScale() / UIParent:GetEffectiveScale())
	if anchor then
		list:SetPoint(anchor.point, anchor.relativeTo, anchor.relativePoint, anchor.x, anchor.y)
	else
		list:SetPoint("TOPLEFT", dropDown, "BOTTOMLEFT", 16, 8)
	end
	list.idle = 0
	list:Show()
	list:Raise()
end

function compat.CloseDropDowns()
	if list then
		list:Hide()
	end
end

function compat.UIDropDownMenu_GetCurrentDropDown()
	return currentDropDown
end

function compat.UIDropDownMenu_SetText(dropDown, text)
	dropDown.Text:SetText(text)
end

local function FindEntry(dropDown, field, wanted)
	local entries = dropDown.entries
	if entries then
		for i = 1, #entries do
			if entries[i][field] == wanted then
				return entries[i]
			end
		end
	end
end

function compat.UIDropDownMenu_SetSelectedValue(dropDown, value)
	dropDown.selectedValue = value
	dropDown.selectedName = nil
	local entry = FindEntry(dropDown, "value", value)
	if entry then
		dropDown.Text:SetText(entry.text)
	end
end

function compat.UIDropDownMenu_SetSelectedName(dropDown, name)
	dropDown.selectedName = name
	dropDown.selectedValue = nil
	if FindEntry(dropDown, "text", name) then
		dropDown.Text:SetText(name)
	end
end

function compat.UIDropDownMenu_SetAnchor(dropDown, x, y, point, relativeTo, relativePoint)
	dropDown.dropAnchor = {x = x, y = y, point = point, relativeTo = relativeTo, relativePoint = relativePoint}
end

-- Like the original, initialising runs the init function once so its side
-- effects happen and the entries are known for SetSelectedValue/Name.
function compat.UIDropDownMenu_Initialize(dropDown, initFunction)
	dropDown.initialize = initFunction
	currentDropDown = dropDown
	collecting = {}
	local ok, err = pcall(initFunction, dropDown, 1)
	dropDown.entries = collecting
	collecting = nil
	if not ok then
		error(err, 0)
	end
end

function compat.UIDropDownMenu_SetWidth(dropDown, width)
	dropDown.Middle:SetWidth(width)
	dropDown:SetWidth(width + 50)
	dropDown.Text:SetWidth(width - 25)
end

function compat.CreateDropDown(name, parent)
	local dropDown = CreateFrame("Frame", name, parent)
	dropDown:SetWidth(40)
	dropDown:SetHeight(32)

	local art = "Interface\\Glues\\CharacterCreate\\CharacterCreate-LabelFrame"
	local left = dropDown:CreateTexture(nil, "ARTWORK")
	left:SetTexture(art)
	left:SetWidth(25)
	left:SetHeight(64)
	left:SetTexCoord(0, 0.1953125, 0, 1)
	left:SetPoint("TOPLEFT", 0, 17)
	dropDown.Left = left

	local middle = dropDown:CreateTexture(nil, "ARTWORK")
	middle:SetTexture(art)
	middle:SetWidth(115)
	middle:SetHeight(64)
	middle:SetTexCoord(0.1953125, 0.8046875, 0, 1)
	middle:SetPoint("LEFT", left, "RIGHT")
	dropDown.Middle = middle

	local right = dropDown:CreateTexture(nil, "ARTWORK")
	right:SetTexture(art)
	right:SetWidth(25)
	right:SetHeight(64)
	right:SetTexCoord(0.8046875, 1, 0, 1)
	right:SetPoint("LEFT", middle, "RIGHT")
	dropDown.Right = right

	local text = dropDown:CreateFontString(name and (name.."Text") or nil, "ARTWORK", "GameFontHighlightSmall")
	text:SetWordWrap(false)
	text:SetJustifyH("RIGHT")
	text:SetHeight(18)
	text:SetPoint("RIGHT", right, "RIGHT", -43, 2)
	dropDown.Text = text

	local button = CreateFrame("Button", nil, dropDown)
	button:SetWidth(24)
	button:SetHeight(24)
	button:SetPoint("TOPRIGHT", right, "TOPRIGHT", -16, -18)
	button:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Up")
	button:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Down")
	button:SetDisabledTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Disabled")
	button:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
	button:SetScript("OnClick", function(self)
		compat.ToggleDropDown(self:GetParent())
	end)
	dropDown.Button = button

	dropDown:EnableMouse(true)
	dropDown:SetScript("OnMouseDown", function(self)
		compat.ToggleDropDown(self)
	end)
	dropDown:SetScript("OnHide", function(self)
		if list and list.owner == self then
			list:Hide()
		end
	end)
	return dropDown
end

-------------------------------------------------------------------------------
-- Minimap
-------------------------------------------------------------------------------
-- Distance from the minimap centre to the icon. The addon hard-coded 76, which
-- is the classic 140px minimap's radius plus 6; the modern minimap is larger.
function compat.MinimapRadius()
	local width = Minimap and Minimap:GetWidth()
	if not width or width <= 0 then
		return 76
	end
	return width / 2 + 6
end
