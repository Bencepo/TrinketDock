-- TrinketDock
-- Copyright (c) 2026 Bencepo. All rights reserved.
--
-- Two secure use buttons for the trinket slots (13, 14). Hovering one out of combat opens a flyout
-- with the trinkets in the bags: left click equips to the top slot, right click to the bottom slot.
-- Lightweight on purpose: the bags are read only when the flyout opens, and the only events are
-- trinket equipment changes and item cooldowns. Nothing runs when combat starts or ends.

local ADDON, ns = ...
local pairs, ipairs, next, type, tonumber, pcall, wipe = pairs, ipairs, next, type, tonumber, pcall, wipe
local abs = math.abs
local format = format

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
	border = false,     -- thin frame around the dock
	background = false, -- dark background behind the dock
	alpha = 100,        -- opacity of the whole dock in percent (0 = invisible, still clickable)
	borderColor = { 0.35, 0.40, 0.47 },    -- r, g, b of the frame
	bgColor = { 0.059, 0.075, 0.094, 0.85 }, -- r, g, b, a of the background
}

local db
local dock, flyout, settingsWin, events
local buttons, flyButtons = {}, {}
local queue = {}                -- [13|14] = { link, icon }: swap waiting for the end of combat
local pendingLayout = false
local editMode = false          -- the game's Edit Mode is open: the dock shows and moves there
local dragging = false
local moverDragging = false
local queueDeferred = false

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

local bagList, bagPool = {}, {}

local function BagTrinkets()
	wipe(bagList)
	local n = 0
	local getID = C_Container.GetContainerItemID
	local getLink = C_Container.GetContainerItemLink
	local getIcon = C_Item and C_Item.GetItemIconByID
	for bag = 0, 4 do
		for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
			local itemID = getID(bag, slot)
			if itemID and EquipLoc(itemID) == "INVTYPE_TRINKET" then
				local link = getLink(bag, slot)
				local icon = getIcon and getIcon(itemID)
				if not icon then
					local info = C_Container.GetContainerItemInfo(bag, slot)
					icon = info and info.iconFileID
				end
				n = n + 1
				local e = bagPool[n]
				if not e then
					e = {}
					bagPool[n] = e
				end
				e.bag, e.slot, e.icon, e.link = bag, slot, icon, link
				bagList[n] = e
			end
		end
	end
	return bagList
end

local function FindInBags(link)
	local getLink = C_Container.GetContainerItemLink
	for bag = 0, 4 do
		for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
			if getLink(bag, slot) == link then return bag, slot end
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
local RunQueue

local function SetQueueDeferEvents(on)
	if queueDeferred == on or not events then return end
	queueDeferred = on
	if on then
		events:RegisterUnitEvent("UNIT_SPELLCAST_STOP", "player")
		events:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_STOP", "player")
		events:RegisterEvent("PLAYER_ALIVE")
		events:RegisterEvent("PLAYER_UNGHOST")
	else
		events:UnregisterEvent("UNIT_SPELLCAST_STOP")
		events:UnregisterEvent("UNIT_SPELLCAST_CHANNEL_STOP")
		events:UnregisterEvent("PLAYER_ALIVE")
		events:UnregisterEvent("PLAYER_UNGHOST")
	end
end

-- Equipping now would cancel a cast in progress (a mount, for example), and in combat it is not
-- allowed at all.
local function MustQueue()
	return InCombatLockdown() or UnitCastingInfo("player") or UnitChannelInfo("player")
end

-- In combat or while casting, the swap is queued and done as soon as combat or the cast ends;
-- the same click again cancels it.
local function Equip(entry, invSlot)
	if MustQueue() then
		local q = queue[invSlot]
		if q and q.link == entry.link then
			queue[invSlot] = nil
		else
			queue[invSlot] = { link = entry.link, icon = entry.icon }
			local other = invSlot == 13 and 14 or 13
			if queue[other] and queue[other].link == entry.link then queue[other] = nil end
		end
		UpdateQueue()
		-- out of combat, RunQueue waits for the cast to end (UNIT_SPELLCAST_STOP) and swaps then
		if not InCombatLockdown() then RunQueue() end
		return
	end
	local bag, slot = entry.bag, entry.slot
	if C_Container.GetContainerItemLink(bag, slot) ~= entry.link then
		bag, slot = FindInBags(entry.link)
	end
	if bag then SwapNow(bag, slot, invSlot) end
end

RunQueue = function()
	if InCombatLockdown() or not next(queue) then return end
	if UnitIsDeadOrGhost("player") or UnitCastingInfo("player") or UnitChannelInfo("player") then
		SetQueueDeferEvents(true)
		return
	end
	SetQueueDeferEvents(false)
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

local Layout, HideFlyout

local function SlotEquipped(slot)
	return GetInventoryItemID("player", slot) ~= nil or GetInventoryItemTexture("player", slot) ~= nil
end

local function UpdateButton(b)
	local id = GetInventoryItemID("player", b.slot)
	local tex = GetInventoryItemTexture("player", b.slot) or (id and C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(id))
	local equipped = id ~= nil or tex ~= nil
	b.icon:SetTexture(tex or EMPTY_ICON)
	b.icon:SetDesaturated(not tex)
	SetCooldown(b.cd, GetInventoryItemCooldown("player", b.slot))
	if b.equipped ~= equipped then
		b.equipped = equipped
		Layout()
	end
end

local function UpdateCooldowns()
	for _, b in ipairs(buttons) do
		SetCooldown(b.cd, GetInventoryItemCooldown("player", b.slot))
	end
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
Layout = function()
	if not dock then return end
	if InCombatLockdown() then
		pendingLayout = true
		return
	end
	pendingLayout = false
	dock:SetScale(db.scale)
	local shown = 0
	local prev
	for _, b in ipairs(buttons) do
		local eq = SlotEquipped(b.slot)
		b.equipped = eq
		local show = editMode or eq
		b:ClearAllPoints()
		if show then
			shown = shown + 1
			if not prev then
				b:SetPoint("TOPLEFT", dock, "TOPLEFT", 0, 0)
			elseif db.vertical then
				b:SetPoint("TOP", prev, "BOTTOM", 0, -GAP)
			else
				b:SetPoint("LEFT", prev, "RIGHT", GAP, 0)
			end
			prev = b
		end
		b:SetShown(show)
	end
	if shown > 1 then
		if db.vertical then dock:SetSize(SIZE, SIZE * shown + GAP * (shown - 1))
		else dock:SetSize(SIZE * shown + GAP * (shown - 1), SIZE) end
	else
		dock:SetSize(SIZE, SIZE)
	end
	dock:ClearAllPoints()
	local p = db.point
	if p then dock:SetPoint(p[1], UIParent, p[2], p[3], p[4]) else dock:SetPoint("CENTER", UIParent, "CENTER", 0, -200) end
	local visible = (not db.hidden and shown > 0) or editMode
	if not visible then HideFlyout() end
	dock:SetShown(visible)
end

-- Frame, background and opacity. None of it is protected, so it also applies in combat.
local WHITE = "Interface\\Buttons\\WHITE8x8"
local BACKDROP = { bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 }
local function ApplyLook()
	if not dock then return end
	local bg, c, f = dock.bg, db.bgColor, db.borderColor
	bg:SetBackdropColor(c[1], c[2], c[3], db.background and (c[4] or 0.85) or 0)
	bg:SetBackdropBorderColor(f[1], f[2], f[3], db.border and 1 or 0)
	dock:SetAlpha((tonumber(db.alpha) or 100) / 100)
end

-- Game colour picker for the frame or the background (the background also gets an opacity).
local function PickColor(key, withAlpha)
	local c = db[key]
	local r, g, b, a = c[1], c[2], c[3], c[4] or 1
	local modern = ColorPickerFrame.SetupColorPickerAndShow ~= nil
	withAlpha = withAlpha and modern and ColorPickerFrame.GetColorAlpha ~= nil
	local function set(nr, ng, nb, na)
		db[key] = withAlpha and { nr, ng, nb, na } or { nr, ng, nb, c[4] }
		ApplyLook()
		if settingsWin then settingsWin:Refresh() end
	end
	local function swatch()
		local nr, ng, nb = ColorPickerFrame:GetColorRGB()
		set(nr, ng, nb, withAlpha and ColorPickerFrame:GetColorAlpha() or a)
	end
	local function cancel() set(r, g, b, a) end
	if modern then
		ColorPickerFrame:SetupColorPickerAndShow({ r = r, g = g, b = b, opacity = a, hasOpacity = withAlpha,
			swatchFunc = swatch, opacityFunc = swatch, cancelFunc = cancel })
	else
		ColorPickerFrame.hasOpacity = false
		ColorPickerFrame.func = swatch
		ColorPickerFrame.cancelFunc = cancel
		ColorPickerFrame:SetColorRGB(r, g, b)
		ColorPickerFrame:Show()
	end
end

local function SavePosition()
	local p, _, rp, x, y = dock:GetPoint()
	db.point = { p, rp, x, y }
end

---------------------------------------------------------------------------
-- Flyout
---------------------------------------------------------------------------

-- Own tooltip without supportsItemComparison, so hovering a trinket never opens the
-- equipped comparison tooltips (ShoppingTooltip1/2), even with Always Compare Items or Shift.
---@type GameTooltip
local dockTip
local function OpenTip(owner)
	if not dockTip then
		dockTip = CreateFrame("GameTooltip", "TrinketDockTooltip", UIParent, "GameTooltipTemplate") --[[@as GameTooltip]]
		dockTip:SetFrameStrata("TOOLTIP")
		dockTip:SetClampedToScreen(true)
	end
	dockTip:SetOwner(owner, "ANCHOR_RIGHT")
	return dockTip
end

local function HideTip()
	if dockTip then dockTip:Hide() end
end

HideFlyout = function()
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
		local t = OpenTip(self)
		t:SetBagItem(self.entry.bag, self.entry.slot)
		t:AddLine("Left-click: top slot   Right-click: bottom slot", 0.31, 0.76, 0.97)
		if InCombatLockdown() then
			t:AddLine("In combat: queued, swapped when combat ends", 1, 0.82, 0)
		elseif MustQueue() then
			t:AddLine("Casting: queued, swapped when the cast ends", 1, 0.82, 0)
		end
		t:Show()
	end)
	fb:SetScript("OnLeave", HideTip)
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
		if fb.up ~= up then
			fb:ClearAllPoints()
			local y = (i - 1) * (SIZE + GAP)
			if up then fb:SetPoint("BOTTOMLEFT", flyout, "BOTTOMLEFT", 0, y)
			else fb:SetPoint("TOPLEFT", flyout, "TOPLEFT", 0, -y) end
			fb.up = up
		end
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
-- Edit Mode: the dock shows there (blue, named, even when hidden) and moves like the game's
-- frames. With Edit Mode's "Snap" on it snaps flush to the other Edit Mode frames, the screen
-- edges and the screen centre lines. Edit Mode is never open in combat.
---------------------------------------------------------------------------

local mover

local function SnapOn()
	local m = EditModeManagerFrame
	if not (m and m.IsSnapEnabled) then return false end
	local ok, on = pcall(m.IsSnapEnabled, m)
	return ok and on and true or false
end

-- Rectangle of a frame in the dock's coordinates: left, right, bottom, top.
local function readRect(frame, dockScale)
	if not (frame and frame:IsVisible()) then return nil end
	local l, r, b, t = frame:GetLeft(), frame:GetRight(), frame:GetBottom(), frame:GetTop()
	if not (l and r and b and t) then return nil end
	local k = frame:GetEffectiveScale() / dockScale
	return l * k, r * k, b * k, t * k
end

local function RectIn(frame, dockScale)
	local ok, l, r, b, t = pcall(readRect, frame, dockScale)
	if ok and l then return l, r, b, t end
	return nil
end

local SNAP_RANGE = 12 -- screen pixels within which an edge snaps
local snapXs, snapYs, snapEdges = {}, {}, {}

local function SnapOffset(e1, e2, e3, targets, range)
	snapEdges[1], snapEdges[2], snapEdges[3] = e1, e2, e3
	local best, bestAbs
	for i = 1, 3 do
		local e = snapEdges[i]
		for _, tv in ipairs(targets) do
			local d = tv - e
			local ad = abs(d)
			if ad <= range and (not bestAbs or ad < bestAbs) then
				best, bestAbs = d, ad
			end
		end
	end
	return best or 0
end

local function SnapToElements(l, r, b, t)
	local dockScale = dock:GetEffectiveScale()
	local k = UIParent:GetEffectiveScale() / dockScale
	local range = SNAP_RANGE * k
	local W, H = UIParent:GetWidth() * k, UIParent:GetHeight() * k
	wipe(snapXs); wipe(snapYs)
	snapXs[1], snapXs[2], snapXs[3] = 0, W / 2, W
	snapYs[1], snapYs[2], snapYs[3] = 0, H / 2, H
	local frames = EditModeManagerFrame and EditModeManagerFrame.registeredSystemFrames
	if type(frames) == "table" then
		for _, other in ipairs(frames) do
			local fl, fr, fb, ft = RectIn(other, dockScale)
			if fl then
				-- a frame counts for one axis only when it is near on the other one
				if fb - range <= t and b <= ft + range then snapXs[#snapXs + 1], snapXs[#snapXs + 2], snapXs[#snapXs + 3] = fl, fr, (fl + fr) / 2 end
				if fl - range <= r and l <= fr + range then snapYs[#snapYs + 1], snapYs[#snapYs + 2], snapYs[#snapYs + 3] = fb, ft, (fb + ft) / 2 end
			end
		end
	end
	return SnapOffset(l, r, (l + r) / 2, snapXs, range), SnapOffset(b, t, (b + t) / 2, snapYs, range)
end

-- After a drag in Edit Mode: snapped (with Snap on), anchored by its top left, saved.
local function PlaceAfterDrag()
	local l, r, b, t = dock:GetLeft(), dock:GetRight(), dock:GetBottom(), dock:GetTop()
	if not (l and r and b and t) then return end
	local dx, dy = 0, 0
	if SnapOn() then
		local ok, x, y = pcall(SnapToElements, l, r, b, t)
		if ok then dx, dy = x, y end
	end
	dock:ClearAllPoints()
	dock:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", l + dx, t + dy)
	SavePosition()
end

local function SetEditMode(on)
	if not dock then return end
	if not on then
		editMode = false
		moverDragging = false
		if mover then mover:Hide() end
		Layout() -- back to shown or hidden as set (defers safely if in combat)
		return
	end
	if InCombatLockdown() then return end
	editMode = true
	if not mover then
		-- above the buttons, so the drag goes to the dock and not to a trinket
		mover = CreateFrame("Frame", nil, dock, "BackdropTemplate")
		mover:SetPoint("TOPLEFT", -4, 4)
		mover:SetPoint("BOTTOMRIGHT", 4, -4)
		mover:SetFrameLevel(dock:GetFrameLevel() + 20)
		mover:SetBackdrop(BACKDROP)
		mover:SetBackdropColor(0.25, 0.55, 1, 0.35)
		mover:SetBackdropBorderColor(0.35, 0.65, 1, 1)
		mover:EnableMouse(true)
		mover:RegisterForDrag("LeftButton")
		mover:SetScript("OnDragStart", function()
			if InCombatLockdown() then return end
			moverDragging = true
			HideFlyout()
			dock:StartMoving()
		end)
		mover:SetScript("OnDragStop", function()
			if not moverDragging then return end
			moverDragging = false
			if not InCombatLockdown() then
				dock:StopMovingOrSizing()
				PlaceAfterDrag()
			end
		end)
		local label = mover:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		label:SetPoint("BOTTOM", mover, "TOP", 0, 4)
		label:SetText("TrinketDock")
	end
	mover:Show()
	HideFlyout()
	Layout() -- also when hidden or unequipped: both slots show so the dock can be placed
end

local function HookEditMode()
	if EventRegistry and EventRegistry.RegisterCallback then
		EventRegistry:RegisterCallback("EditMode.Enter", function() SetEditMode(true) end, dock)
		EventRegistry:RegisterCallback("EditMode.Exit", function() SetEditMode(false) end, dock)
	elseif EditModeManagerFrame and hooksecurefunc then
		hooksecurefunc(EditModeManagerFrame, "EnterEditMode", function() SetEditMode(true) end)
		hooksecurefunc(EditModeManagerFrame, "ExitEditMode", function() SetEditMode(false) end)
	end
end

---------------------------------------------------------------------------
-- Frames
---------------------------------------------------------------------------

local function Create()
	dock = CreateFrame("Frame", "TrinketDockFrame", UIParent)
	dock:SetMovable(true)
	dock:SetClampedToScreen(true)
	-- Frame and background sit behind the buttons, a few pixels around them.
	dock.bg = CreateFrame("Frame", nil, dock, "BackdropTemplate")
	dock.bg:SetPoint("TOPLEFT", -4, 4)
	dock.bg:SetPoint("BOTTOMRIGHT", 4, -4)
	dock.bg:SetFrameLevel(dock:GetFrameLevel())
	dock.bg:SetBackdrop(BACKDROP)

	flyout = CreateFrame("Frame", nil, UIParent)
	flyout:SetFrameStrata("DIALOG")
	flyout:Hide()
	-- Closes when the mouse leaves both the flyout and its button. It stays usable in combat: clicks queue.
	local flyElapsed = 0
	flyout:SetScript("OnShow", function() flyElapsed = 0 end)
	flyout:SetScript("OnHide", function()
		if dockTip and dockTip:GetOwner() and dockTip:GetOwner():GetParent() == flyout then dockTip:Hide() end
	end)
	flyout:SetScript("OnUpdate", function(self, elapsed)
		flyElapsed = flyElapsed + elapsed
		if flyElapsed < 0.05 then return end
		flyElapsed = 0
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
			dragging = true
			HideTip()
			HideFlyout()
			dock:StartMoving()
		end)
		b:SetScript("OnDragStop", function()
			if not dragging then return end
			dragging = false
			if not InCombatLockdown() then
				dock:StopMovingOrSizing()
				SavePosition()
			end
		end)
		b:SetScript("OnEnter", function(self)
			if db.tooltips then
				local t = OpenTip(self)
				if GetInventoryItemTexture("player", self.slot) then
					t:SetInventoryItem("player", self.slot)
				else
					t:SetText(self.slot == 13 and "Top trinket slot" or "Bottom trinket slot")
				end
				local q = queue[self.slot]
				if q then t:AddLine("Queued after combat: " .. q.link, 1, 0.82, 0) end
				if not db.locked then t:AddLine("Shift-drag to move", 0.31, 0.76, 0.97) end
				t:Show()
			end
			if not editMode then ShowFlyout(self) end
		end)
		b:SetScript("OnLeave", HideTip)
		b:SetScript("PostClick", function(self, mouse, down)
			if ns.debug then
				print(PREFIX .. ("click %s %s, combat %s, slot %d"):format(tostring(mouse), down and "down" or "up",
					InCombatLockdown() and "yes" or "no", self.slot))
			end
		end)
		buttons[i] = b
	end
	Layout()
	ApplyLook()
	UpdateAll()
end

---------------------------------------------------------------------------
-- Settings: a window of its own, live while you play
---------------------------------------------------------------------------

local FLYOUT_DIRS = { { "UP", "Upwards" }, { "DOWN", "Downwards" } }

local function BuildSettings()
	local UI = LibStub("BencepoUI-1.0")
	settingsWin = UI:CreateWindow({
		name = "TrinketDockSettingsFrame", title = "TrinketDock", subtitle = VERSION,
		width = 400, height = 410, accent = { 0.31, 0.76, 0.97, 1 },
		db = db, posKey = "settingsPoint", bugUrl = BUG_URL,
	})
	local w = settingsWin
	local X = 16
	w:Header(X, -48, "Buttons")
	w:Check(X, -72, "Show the buttons", "Hides or shows both trinket buttons.",
		function() return not db.hidden end, function(v) db.hidden = not v Layout() end)
	w:Check(X, -96, "Lock position", "When unlocked, Shift-drag a button to move the dock. The game's Edit Mode always moves it.",
		function() return db.locked end, function(v) db.locked = v and true or false end)
	w:Check(X, -120, "Vertical", "Stacks the two buttons instead of placing them side by side.",
		function() return db.vertical end, function(v) db.vertical = v and true or false Layout() end)
	w:Check(X, -144, "Tooltips", "Item tooltips on the buttons and in the flyout.",
		function() return db.tooltips end, function(v) db.tooltips = v and true or false end)
	w:Slider(X, -184, "Scale", 0.5, 2, 0.05, function() return db.scale end,
		function(v) db.scale = v Layout() end, "Size of the buttons and the flyout.", 160,
		function(v) return format("%.2f", v) end)

	w:Header(210, -48, "Flyout")
	w:Dropdown(210, -72, "Opens", 170, FLYOUT_DIRS,
		function() return db.direction end, function(v) db.direction = v end,
		"Direction of the list of trinkets in your bags.")
	local reset = w:Button("Reset position", 170, function()
		db.point = nil
		Layout()
	end, "Moves the dock back to the middle of the screen. The game's Edit Mode moves it too, with snapping.")
	reset:SetPoint("TOPLEFT", 210, -130)

	w:Header(210, -172, "Look")
	w:Check(210, -196, "Frame", "A thin frame around the dock.",
		function() return db.border end, function(v) db.border = v and true or false ApplyLook() end)
	w:Check(210, -220, "Background", "A dark background behind the dock.",
		function() return db.background end, function(v) db.background = v and true or false ApplyLook() end)
	-- Colour swatches next to the switches: click opens the game's colour picker.
	local function Swatch(y, key, label, tip, withAlpha)
		local sw = w:Button(label, 36, function() PickColor(key, withAlpha) end, tip)
		sw:SetText("")
		sw:SetPoint("TOPLEFT", 340, y + 2)
		sw:SetHeight(18)
		local fill = sw:CreateTexture(nil, "ARTWORK")
		fill:SetPoint("TOPLEFT", 3, -3)
		fill:SetPoint("BOTTOMRIGHT", -3, 3)
		w:OnRefresh(function()
			local c = db[key]
			fill:SetColorTexture(c[1], c[2], c[3], 1)
		end)
	end
	Swatch(-196, "borderColor", "Frame colour", "Colour of the frame. Click to pick.", false)
	Swatch(-220, "bgColor", "Background colour", "Colour and opacity of the background. Click to pick.", true)
	local resetLook = w:Button("Reset colours", 120, function()
		db.borderColor = CopyTable(DEFAULTS.borderColor)
		db.bgColor = CopyTable(DEFAULTS.bgColor)
		ApplyLook()
	end, "Back to the default frame and background colours.")
	resetLook:SetPoint("TOPLEFT", 210, -296)
	w:Slider(210, -252, "Opacity", 0, 100, 5, function() return db.alpha end,
		function(v) db.alpha = v ApplyLook() end, "Opacity of the whole dock. At 0% it is invisible but still clickable, and keybindings keep working.", 140,
		function(v) return format("%d%%", v) end)

	w:Text(X, -336, "Click a button to use the trinket. Hover it for the flyout: left-click equips to the top slot, right-click to the bottom slot. In combat or while casting, the swap is queued and done right after. Keybindings: Options > Keybindings > TrinketDock.", 368)
end

local function EnsureSettings()
	if not settingsWin then BuildSettings() end
	return settingsWin
end

local function ToggleSettings()
	if not db then return end
	EnsureSettings():Toggle()
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
			if not db then return end
			EnsureSettings():Show()
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

events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function(self, event, arg1)
	if event == "PLAYER_LOGIN" then
		self:UnregisterEvent("PLAYER_LOGIN")
		TrinketDockDB = TrinketDockDB or {}
		db = TrinketDockDB
		for k, v in pairs(DEFAULTS) do
			if db[k] == nil then db[k] = type(v) == "table" and CopyTable(v) or v end
		end
		-- 0.1.0 saved { point, "UIParent", relPoint, x, y }
		if db.point and db.point[2] == "UIParent" then
			db.point = { db.point[1], db.point[3], db.point[4], db.point[5] }
		end
		db.up = nil
		Create()
		pcall(RegisterSettings)
		pcall(HookEditMode)
		self:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
		self:RegisterEvent("BAG_UPDATE_COOLDOWN")
		self:RegisterEvent("PLAYER_ENTERING_WORLD")
		self:RegisterEvent("PLAYER_REGEN_ENABLED")
	elseif event == "PLAYER_EQUIPMENT_CHANGED" then
		if arg1 == 13 or arg1 == 14 then
			local b = buttons[arg1 == 13 and 1 or 2]
			if b then UpdateButton(b) end
		end
	elseif event == "BAG_UPDATE_COOLDOWN" then
		UpdateCooldowns()
	elseif event == "PLAYER_REGEN_ENABLED" then
		if pendingLayout then Layout() end
		if next(queue) then RunQueue() end
	elseif event == "UNIT_SPELLCAST_STOP" or event == "UNIT_SPELLCAST_CHANNEL_STOP" or event == "PLAYER_ALIVE" or event == "PLAYER_UNGHOST" then
		if next(queue) then RunQueue() else SetQueueDeferEvents(false) end
	else
		UpdateAll()
	end
end)

ns.ToggleSettings = ToggleSettings
