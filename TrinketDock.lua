-- TrinketDock
-- Copyright (c) 2026 Bencepo. All rights reserved.
--
-- Two secure use buttons for the trinket slots (13, 14). Hovering one out of combat opens a flyout
-- with the trinkets in the bags: left click equips to the top slot, right click to the bottom slot.
-- Lightweight on purpose: the bags are read only when the flyout opens, and the only events are
-- trinket equipment changes and item cooldowns. Nothing runs when combat starts or ends.

local ADDON, ns = ...

local VERSION = C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON, "Version") or ""
if VERSION:find("@") then VERSION = "dev" end
local BUG_URL = "https://github.com/Bencepo/TrinketDock/issues/new/choose"
local PREFIX = "|cff4fc3f7TrinketDock:|r "

local SLOTS = { 13, 14 }
local SIZE, GAP = 36, 4
local EMPTY_ICON = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Trinket"

local DEFAULTS = {
	scale = 1,
	locked = false,
	vertical = false,
	direction = "UP",
	tooltips = true,
	hidden = false,
}

local db
local dock, flyout, settingsWin
local buttons, flyButtons = {}, {}
local queue = {}                -- [13|14] = { link, icon }: swap waiting for the end of combat
local pendingLayout = false

BINDING_HEADER_TRINKETDOCK = "TrinketDock"
_G["BINDING_NAME_CLICK TrinketDockButton1:LeftButton"] = "Use top trinket"
_G["BINDING_NAME_CLICK TrinketDockButton2:LeftButton"] = "Use bottom trinket"

---------------------------------------------------------------------------
-- Bags and equipping
---------------------------------------------------------------------------

local function EquipLoc(itemID)
	local f = C_Item and C_Item.GetItemInfoInstant
	if not (f and itemID) then return nil end
	local _, _, _, loc = f(itemID)
	return loc
end

local function BagTrinkets()
	local list = {}
	for bag = 0, 4 do
		for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
			local info = C_Container.GetContainerItemInfo(bag, slot)
			if info and info.itemID and EquipLoc(info.itemID) == "INVTYPE_TRINKET" then
				list[#list + 1] = { bag = bag, slot = slot, icon = info.iconFileID, link = info.hyperlink }
			end
		end
	end
	return list
end

local function FindInBags(link)
	for bag = 0, 4 do
		for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
			local info = C_Container.GetContainerItemInfo(bag, slot)
			if info and info.hyperlink == link then return bag, slot end
		end
	end
end

local function SwapNow(bag, slot, invSlot)
	ClearCursor()
	C_Container.PickupContainerItem(bag, slot)
	PickupInventoryItem(invSlot)
	ClearCursor()
end

local UpdateQueue -- defined with the dock

-- In combat the swap is queued and done as soon as combat ends; the same click again cancels it.
local function Equip(entry, invSlot)
	if InCombatLockdown() then
		local q = queue[invSlot]
		if q and q.link == entry.link then
			queue[invSlot] = nil
		else
			queue[invSlot] = { link = entry.link, icon = entry.icon }
			local other = invSlot == 13 and 14 or 13
			if queue[other] and queue[other].link == entry.link then queue[other] = nil end
		end
		UpdateQueue()
		return
	end
	SwapNow(entry.bag, entry.slot, invSlot)
end

local function RunQueue()
	for _, invSlot in ipairs(SLOTS) do
		local q = queue[invSlot]
		if q then
			queue[invSlot] = nil
			local bag, slot = FindInBags(q.link)
			if bag then SwapNow(bag, slot, invSlot) end
		end
	end
	UpdateQueue()
end

local function SetCooldown(cd, start, duration, enable)
	if start and duration and duration > 1.5 and (enable == 1 or enable == true) then
		cd:SetCooldown(start, duration)
	else
		cd:Clear()
	end
end

---------------------------------------------------------------------------
-- Dock
---------------------------------------------------------------------------

local function UpdateButton(b)
	local tex = GetInventoryItemTexture("player", b.slot)
	b.icon:SetTexture(tex or EMPTY_ICON)
	b.icon:SetDesaturated(not tex)
	SetCooldown(b.cd, GetInventoryItemCooldown("player", b.slot))
end

local function UpdateAll()
	for _, b in ipairs(buttons) do UpdateButton(b) end
end

-- Small icon in the corner of a dock button: the trinket queued for that slot.
function UpdateQueue()
	for _, b in ipairs(buttons) do
		local q = queue[b.slot]
		b.queued:SetShown(q ~= nil)
		b.queuedBorder:SetShown(q ~= nil)
		if q then b.queued:SetTexture(q.icon) end
	end
	for _, fb in ipairs(flyButtons) do
		if fb:IsShown() and fb.entry then
			local mark = (queue[13] and queue[13].link == fb.entry.link) or (queue[14] and queue[14].link == fb.entry.link)
			fb.mark:SetShown(mark and true or false)
		end
	end
end

-- Secure buttons cannot be moved, scaled or hidden in combat: the change waits for combat to end.
local function Layout()
	if not dock then return end
	if InCombatLockdown() then
		pendingLayout = true
		return
	end
	pendingLayout = false
	dock:SetScale(db.scale)
	for i, b in ipairs(buttons) do
		b:ClearAllPoints()
		if i == 1 then
			b:SetPoint("TOPLEFT", dock, "TOPLEFT", 0, 0)
		elseif db.vertical then
			b:SetPoint("TOP", buttons[i - 1], "BOTTOM", 0, -GAP)
		else
			b:SetPoint("LEFT", buttons[i - 1], "RIGHT", GAP, 0)
		end
	end
	if db.vertical then dock:SetSize(SIZE, SIZE * 2 + GAP) else dock:SetSize(SIZE * 2 + GAP, SIZE) end
	dock:ClearAllPoints()
	local p = db.point
	if p then dock:SetPoint(p[1], UIParent, p[2], p[3], p[4]) else dock:SetPoint("CENTER", UIParent, "CENTER", 0, -200) end
	dock:SetShown(not db.hidden)
end

local function SavePosition()
	local p, _, rp, x, y = dock:GetPoint()
	db.point = { p, rp, x, y }
end

---------------------------------------------------------------------------
-- Flyout
---------------------------------------------------------------------------

local function HideFlyout()
	if flyout then flyout:Hide() end
end

local function FlyButton(i)
	local fb = flyButtons[i]
	if fb then return fb end
	fb = CreateFrame("Button", nil, flyout)
	fb:SetSize(SIZE, SIZE)
	fb:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	fb.icon = fb:CreateTexture(nil, "ARTWORK")
	fb.icon:SetAllPoints()
	fb:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
	fb.cd = CreateFrame("Cooldown", nil, fb, "CooldownFrameTemplate")
	fb.cd:SetAllPoints()
	fb.mark = fb:CreateTexture(nil, "OVERLAY")
	fb.mark:SetTexture("Interface\\Buttons\\CheckButtonHilight")
	fb.mark:SetBlendMode("ADD")
	fb.mark:SetAllPoints()
	fb.mark:Hide()
	fb:SetScript("OnClick", function(self, mouse)
		Equip(self.entry, mouse == "RightButton" and 14 or 13)
		HideFlyout()
	end)
	fb:SetScript("OnEnter", function(self)
		if not (db.tooltips and self.entry) then return end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetBagItem(self.entry.bag, self.entry.slot)
		GameTooltip:AddLine("Left-click: top slot   Right-click: bottom slot", 0.31, 0.76, 0.97)
		if InCombatLockdown() then GameTooltip:AddLine("In combat: queued, swapped when combat ends", 1, 0.82, 0) end
		GameTooltip:Show()
	end)
	fb:SetScript("OnLeave", function() GameTooltip:Hide() end)
	flyButtons[i] = fb
	return fb
end

local function ShowFlyout(anchor)
	local list = BagTrinkets()
	for _, fb in ipairs(flyButtons) do fb:Hide() end
	if #list == 0 then
		HideFlyout()
		return
	end
	local up = db.direction == "UP"
	for i, e in ipairs(list) do
		local fb = FlyButton(i)
		fb.entry = e
		fb.icon:SetTexture(e.icon)
		SetCooldown(fb.cd, C_Container.GetContainerItemCooldown(e.bag, e.slot))
		fb:ClearAllPoints()
		local y = (i - 1) * (SIZE + GAP)
		if up then fb:SetPoint("BOTTOMLEFT", flyout, "BOTTOMLEFT", 0, y)
		else fb:SetPoint("TOPLEFT", flyout, "TOPLEFT", 0, -y) end
		fb:Show()
	end
	flyout:SetScale(db.scale)
	flyout:SetSize(SIZE, #list * (SIZE + GAP) - GAP)
	flyout:ClearAllPoints()
	if up then flyout:SetPoint("BOTTOM", anchor, "TOP", 0, GAP)
	else flyout:SetPoint("TOP", anchor, "BOTTOM", 0, -GAP) end
	flyout.anchor = anchor
	flyout:Show()
	UpdateQueue()
end

---------------------------------------------------------------------------
-- Frames
---------------------------------------------------------------------------

local function Create()
	dock = CreateFrame("Frame", "TrinketDockFrame", UIParent)
	dock:SetMovable(true)
	dock:SetClampedToScreen(true)

	flyout = CreateFrame("Frame", nil, UIParent)
	flyout:SetFrameStrata("DIALOG")
	flyout:Hide()
	-- Closes when the mouse leaves both the flyout and its button. It stays usable in combat: clicks queue.
	flyout:SetScript("OnUpdate", function(self)
		if not (self:IsMouseOver(4, -4, -4, 4) or (self.anchor and self.anchor:IsMouseOver())) then self:Hide() end
	end)

	for i, slot in ipairs(SLOTS) do
		local b = CreateFrame("Button", "TrinketDockButton" .. i, dock, "SecureActionButtonTemplate")
		b.slot = slot
		b:SetSize(SIZE, SIZE)
		-- Up and down, like the action bars: the template acts on one of them (ActionButtonUseKeyDown),
		-- and keybindings send the down click.
		b:RegisterForClicks("AnyUp", "AnyDown")
		-- The same as a player macro "/use 13": works in combat exactly like one.
		b:SetAttribute("type", "macro")
		b:SetAttribute("macrotext", "/use " .. slot)
		b.icon = b:CreateTexture(nil, "ARTWORK")
		b.icon:SetAllPoints()
		b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
		b:SetPushedTexture("Interface\\Buttons\\UI-Quickslot-Depress")
		b.cd = CreateFrame("Cooldown", nil, b, "CooldownFrameTemplate")
		b.cd:SetAllPoints()
		local overlay = CreateFrame("Frame", nil, b)
		overlay:SetAllPoints()
		overlay:SetFrameLevel(b.cd:GetFrameLevel() + 2)
		b.queuedBorder = overlay:CreateTexture(nil, "ARTWORK")
		b.queuedBorder:SetColorTexture(1, 0.82, 0, 1)
		b.queuedBorder:SetSize(18, 18)
		b.queuedBorder:SetPoint("BOTTOMRIGHT", 2, -2)
		b.queued = overlay:CreateTexture(nil, "OVERLAY")
		b.queued:SetSize(16, 16)
		b.queued:SetPoint("CENTER", b.queuedBorder, "CENTER")
		b.queued:Hide()
		b.queuedBorder:Hide()
		b:RegisterForDrag("LeftButton")
		b:SetScript("OnDragStart", function()
			if db.locked or not IsShiftKeyDown() or InCombatLockdown() then return end
			HideFlyout()
			dock:StartMoving()
		end)
		b:SetScript("OnDragStop", function()
			dock:StopMovingOrSizing()
			SavePosition()
		end)
		b:SetScript("OnEnter", function(self)
			if db.tooltips then
				GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
				if GetInventoryItemTexture("player", self.slot) then
					GameTooltip:SetInventoryItem("player", self.slot)
				else
					GameTooltip:SetText(self.slot == 13 and "Top trinket slot" or "Bottom trinket slot")
				end
				local q = queue[self.slot]
				if q then GameTooltip:AddLine("Queued after combat: " .. q.link, 1, 0.82, 0) end
				if not db.locked then GameTooltip:AddLine("Shift-drag to move", 0.31, 0.76, 0.97) end
				GameTooltip:Show()
			end
			ShowFlyout(self)
		end)
		b:SetScript("OnLeave", function() GameTooltip:Hide() end)
		b:SetScript("PostClick", function(self, mouse, down)
			if ns.debug then
				print(PREFIX .. ("click %s %s, combat %s, slot %d"):format(tostring(mouse), down and "down" or "up",
					InCombatLockdown() and "yes" or "no", self.slot))
			end
		end)
		buttons[i] = b
	end
	Layout()
	UpdateAll()
end

---------------------------------------------------------------------------
-- Settings: a window of its own, live while you play
---------------------------------------------------------------------------

local function BuildSettings()
	local UI = LibStub("BencepoUI-1.0")
	settingsWin = UI:CreateWindow({
		name = "TrinketDockSettingsFrame", title = "TrinketDock", subtitle = VERSION,
		width = 400, height = 300, accent = { 0.31, 0.76, 0.97, 1 },
		db = db, posKey = "settingsPoint", bugUrl = BUG_URL,
	})
	local w = settingsWin
	local X = 16
	w:Header(X, -48, "Buttons")
	w:Check(X, -72, "Show the buttons", "Hides or shows both trinket buttons.",
		function() return not db.hidden end, function(v) db.hidden = not v Layout() end)
	w:Check(X, -96, "Lock position", "When unlocked, Shift-drag a button to move the dock.",
		function() return db.locked end, function(v) db.locked = v and true or false end)
	w:Check(X, -120, "Vertical", "Stacks the two buttons instead of placing them side by side.",
		function() return db.vertical end, function(v) db.vertical = v and true or false Layout() end)
	w:Check(X, -144, "Tooltips", "Item tooltips on the buttons and in the flyout.",
		function() return db.tooltips end, function(v) db.tooltips = v and true or false end)
	w:Slider(X, -184, "Scale", 0.5, 2, 0.05, function() return db.scale end,
		function(v) db.scale = v Layout() end, "Size of the buttons and the flyout.", 160,
		function(v) return ("%.2f"):format(v) end)

	w:Header(210, -48, "Flyout")
	w:Dropdown(210, -72, "Opens", 170, { { "UP", "Upwards" }, { "DOWN", "Downwards" } },
		function() return db.direction end, function(v) db.direction = v end,
		"Direction of the list of trinkets in your bags.")
	local reset = w:Button("Reset position", 170, function()
		db.point = nil
		Layout()
	end, "Moves the dock back to the middle of the screen.")
	reset:SetPoint("TOPLEFT", 210, -130)

	w:Text(X, -232, "Click a button to use the trinket. Hover it for the flyout: left-click equips to the top slot, right-click to the bottom slot. In combat the swap is queued and done when combat ends. Keybindings: Options > Keybindings > TrinketDock.", 368)
end

local function ToggleSettings()
	if not settingsWin then BuildSettings() end
	settingsWin:Refresh()
	settingsWin:Toggle()
end

function TrinketDock_OnCompartmentClick()
	ToggleSettings()
end

local function RegisterSettings()
	if not (Settings and Settings.RegisterVerticalLayoutCategory and Settings.RegisterAddOnCategory) then return end
	local category, layout = Settings.RegisterVerticalLayoutCategory("TrinketDock")
	if layout and CreateSettingsButtonInitializer then
		layout:AddInitializer(CreateSettingsButtonInitializer("TrinketDock has its own settings window", "Open", function()
			if SettingsPanel and SettingsPanel:IsShown() then HideUIPanel(SettingsPanel) end
			if not settingsWin then BuildSettings() end
			settingsWin:Refresh()
			settingsWin:Show()
		end, "The window can be dragged anywhere and stays open while you play.", true))
	end
	Settings.RegisterAddOnCategory(category)
end

SLASH_TRINKETDOCK1 = "/tdock"
SLASH_TRINKETDOCK2 = "/trinketdock"
SlashCmdList.TRINKETDOCK = function(msg)
	if (msg or ""):lower():match("^%s*debug") then
		ns.debug = not ns.debug
		print(PREFIX .. "click debug " .. (ns.debug and "on" or "off") .. ".")
		return
	end
	ToggleSettings()
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function(_, event, arg1)
	if event == "PLAYER_LOGIN" then
		TrinketDockDB = TrinketDockDB or {}
		db = TrinketDockDB
		for k, v in pairs(DEFAULTS) do
			if db[k] == nil then db[k] = v end
		end
		-- 0.1.0 saved { point, "UIParent", relPoint, x, y }
		if db.point and db.point[2] == "UIParent" then
			db.point = { db.point[1], db.point[3], db.point[4], db.point[5] }
		end
		db.up = nil
		Create()
		pcall(RegisterSettings)
		events:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
		events:RegisterEvent("BAG_UPDATE_COOLDOWN")
		events:RegisterEvent("PLAYER_ENTERING_WORLD")
		events:RegisterEvent("PLAYER_REGEN_ENABLED")
	elseif event == "PLAYER_EQUIPMENT_CHANGED" then
		if arg1 == 13 or arg1 == 14 then UpdateAll() end
	elseif event == "PLAYER_REGEN_ENABLED" then
		if pendingLayout then Layout() end
		if next(queue) then RunQueue() end
	else
		UpdateAll()
	end
end)

ns.ToggleSettings = ToggleSettings
