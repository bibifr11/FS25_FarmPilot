ADHudIcon = ADInheritsFrom(ADGenericHudElement)

function ADHudIcon:new(posX, posY, width, height, image, layer, name)
    local o = ADHudIcon:create()
    o:init(posX, posY, width, height)
    o.layer = layer
    o.name = name
    o.image = image
    o.isVisible = true
    o.lastLineCount = 1
    o.ov = Overlay.new(g_baseUIFilename, o.position.x, o.position.y, width, height)
    o.ov:setUVs(g_colorBgUVs)
    return o
end

function ADHudIcon:onDraw(vehicle, uiScale)
    self:updateVisibility(vehicle)

    self:updateIcon(vehicle)

    if self.name == "header" then
        self:onDrawHeader(vehicle, uiScale)
    end

    if self.isVisible and self.ov ~= nil then
        if self.name == "header" then
            self.ov:setColor(unpack(AutoDrive.currentColors.ad_color_header))
            if not ADHudIcon.drawRounded(self.ov, uiScale, true, false, AutoDrive.currentColors.ad_color_header) then
                self.ov:render()
            end
        elseif self.name == "background" then
            self.ov:setColor(unpack(AutoDrive.currentColors.ad_color_background))
            -- le fond s'arrête sous le bandeau : sinon les deux couleurs se superposent et font un trait
            local headerY = AutoDrive.Hud ~= nil and AutoDrive.Hud.rowHeader or nil
            if not ADHudIcon.drawRounded(self.ov, uiScale, headerY == nil, true, AutoDrive.currentColors.ad_color_background, headerY) then
                self.ov:render()
            end
        else
            self.ov:render()
        end
    end
end

-- FarmPilot : fond et bandeau du HUD aux coins arrondis, comme les fenêtres d'AutoSwitch
-- (quart de cercle hud/corner_*.dds teinté + rectangles pleins calés sur les pixels de l'écran)
ADHudIcon.CORNER_PX = 10
function ADHudIcon.getCorners()
    if ADHudIcon.corners == nil then
        ADHudIcon.corners = {}
        for _, k in ipairs({ "tl", "tr", "bl", "br" }) do
            local ok, o = FarmPilotCall(createImageOverlay, Utils.getFilename(({ tl = "hud/corner_tl.dds", tr = "hud/corner_tr.dds", bl = "hud/corner_bl.dds", br = "hud/corner_br.dds" })[k], AutoDrive.directory or g_currentModDirectory))
            if ok and o ~= nil and o ~= 0 then
                ADHudIcon.corners[k] = o
            else
                ADHudIcon.corners = false
                break
            end
        end
    end
    return ADHudIcon.corners or nil
end

-- (07/11) images des coins prêtes à être dessinées (sinon « renderOverlay called too soon » dans le log) ;
-- en attendant, le cadre est dessiné sans coins arrondis
function ADHudIcon.cornersReady(cs)
    if cs.ready then
        return true
    end
    if getIsOverlayReady ~= nil then
        for _, k in ipairs({ "tl", "tr", "bl", "br" }) do
            local ok, r = FarmPilotCall(getIsOverlayReady, cs[k])
            if ok and not r then
                return false
            end
        end
    end
    cs.ready = true
    return true
end

function ADHudIcon.drawRounded(ov, uiScale, roundTop, roundBottom, color, topLimit)
    local cs = ADHudIcon.getCorners()
    if cs == nil or ov.x == nil or ov.width == nil or not ADHudIcon.cornersReady(cs) then
        return false
    end
    local r, g, b, a = unpack(color)
    local sw, sh = math.max(1, g_screenWidth or 1920), math.max(1, g_screenHeight or 1080)
    local function sx(v) return math.floor(v * sw + 0.5) / sw end
    local function sy(v) return math.floor(v * sh + 0.5) / sh end
    local left, right = sx(ov.x), sx(ov.x + ov.width)
    local bottom, top = sy(ov.y), sy(ov.y + ov.height)
    if topLimit ~= nil then
        top = math.min(top, sy(topLimit))
    end
    local cw, ch = getNormalizedScreenValues(ADHudIcon.CORNER_PX * (uiScale or 1), ADHudIcon.CORNER_PX * (uiScale or 1))
    cw, ch = math.min(sx(cw), (right - left) / 2), math.min(sy(ch), (top - bottom) / 2)
    local b2, t2 = bottom, top
    if roundBottom then
        drawFilledRect(left + cw, bottom, right - left - 2 * cw, ch, r, g, b, a)
        setOverlayColor(cs.bl, r, g, b, a); renderOverlay(cs.bl, left, bottom, cw, ch)
        setOverlayColor(cs.br, r, g, b, a); renderOverlay(cs.br, right - cw, bottom, cw, ch)
        b2 = bottom + ch
    end
    if roundTop then
        drawFilledRect(left + cw, top - ch, right - left - 2 * cw, ch, r, g, b, a)
        setOverlayColor(cs.tl, r, g, b, a); renderOverlay(cs.tl, left, top - ch, cw, ch)
        setOverlayColor(cs.tr, r, g, b, a); renderOverlay(cs.tr, right - cw, top - ch, cw, ch)
        t2 = top - ch
    end
    if t2 > b2 then
        drawFilledRect(left, b2, right - left, t2 - b2, r, g, b, a)
    end
    return true
end

function ADHudIcon:onDrawHeader(vehicle, uiScale)
    local adFontSize = 0.011 * uiScale
    local textHeight = getTextHeight(adFontSize, "text")
    local adPosX = self.position.x + AutoDrive.Hud.gapWidth
    local adPosY = self.position.y + (self.size.height - textHeight) / 2

    if AutoDrive.Hud.isShowingTips then
        adPosY = self.position.y + (AutoDrive.Hud.gapHeight)
    end

    setTextBold(true)
    setTextColor(unpack(AutoDrive.currentColors.ad_color_hudTextDefault))
    setTextAlignment(RenderText.ALIGN_LEFT)
    self:renderDefaultText(vehicle, adFontSize, adPosX, adPosY)
    if AutoDrive.Hud.isShowingTips then
        adPosY = adPosY + textHeight + AutoDrive.Hud.gapHeight
        adPosY = adPosY + (textHeight + AutoDrive.Hud.gapHeight) * (self.lastLineCount - 1)
        self:renderEditorTips(textHeight, adFontSize, adPosX, adPosY)
    end
end

function ADHudIcon:renderDefaultText(vehicle, fontSize, posX, posY)
    local textHeight = getTextHeight(fontSize, "text")
    local textToShow = "FarmPilot"
    textToShow = textToShow .. " - " .. tostring(AutoDriveRegister.version)
    textToShow = textToShow .. " - " .. AutoDriveHud:getModeName(vehicle)
    textToShow = self:addVehicleDriveTimeString(vehicle, textToShow)
    textToShow = self:addTooltipString(vehicle, textToShow)    

    local taskInfo = vehicle.ad.stateModule:getCurrentLocalizedTaskInfo()
    if taskInfo ~= "" then
        textToShow = textToShow .. " - " .. taskInfo
    end

    if AutoDrive.isEditorModeEnabled() and AutoDrive.getDebugChannelIsSet(AutoDrive.DC_PATHINFO) then
        if vehicle.ad.pathFinderModule.steps > 0 then
            textToShow = textToShow .. " - " .. "Fallback: " .. tostring(vehicle.ad.pathFinderModule.fallBackMode)
        end
    end

    local lines = self:splitTextByLength(textToShow, fontSize, self.size.width - 4 * AutoDrive.Hud.gapWidth - 3 * AutoDrive.Hud.headerIconWidth)

    if #lines ~= self.lastLineCount and self.ov ~= nil then
        self.ov:setDimension(nil, self.size.height + (textHeight + AutoDrive.Hud.gapHeight) * (#lines - 1))        
    end

    for lineNumber, lineText in pairs(lines) do
        if AutoDrive.pullDownListExpanded == 0 then
            -- FarmPilot : nom en or (titre des fenêtres d'AutoSwitch), le reste en gris clair
            if lineNumber == 1 and string.sub(lineText, 1, 9) == "FarmPilot" then
                setTextColor(1, 0.8, 0.3, 1)
                renderText(posX, posY, fontSize, "FarmPilot")
                local titleWidth = getTextWidth(fontSize, "FarmPilot")
                setTextBold(false)
                setTextColor(0.70, 0.73, 0.78, 1)
                renderText(posX + titleWidth, posY, fontSize, string.sub(lineText, 10))
                setTextBold(true)
                setTextColor(unpack(AutoDrive.currentColors.ad_color_hudTextDefault))
            else
                renderText(posX, posY, fontSize, lineText)
            end
            posY = posY + textHeight + AutoDrive.Hud.gapHeight
        end
    end
    self.lastLineCount = #lines
end

function ADHudIcon:renderEditorTips(textHeight, fontSize, posX, posY)
    local editorTips = {}
    table.insert(editorTips, g_i18n:getText("gui_ad_editorTip_11"))
    table.insert(editorTips, g_i18n:getText("gui_ad_editorTip_10"))
    table.insert(editorTips, g_i18n:getText("gui_ad_editorTip_9"))
    table.insert(editorTips, g_i18n:getText("gui_ad_editorTip_8"))
    table.insert(editorTips, g_i18n:getText("gui_ad_editorTip_7"))
    table.insert(editorTips, g_i18n:getText("gui_ad_editorTip_6"))
    table.insert(editorTips, g_i18n:getText("gui_ad_editorTip_5"))
    table.insert(editorTips, g_i18n:getText("gui_ad_editorTip_4"))
    table.insert(editorTips, g_i18n:getText("gui_ad_editorTip_3"))
    table.insert(editorTips, g_i18n:getText("gui_ad_editorTip_2"))
    table.insert(editorTips, g_i18n:getText("gui_ad_editorTip_1"))

    for tipId, tip in pairs(editorTips) do
        if AutoDrive.pullDownListExpanded == 0 then
            renderText(posX, posY, fontSize, tip)
            posY = posY + textHeight + AutoDrive.Hud.gapHeight
            if tipId == 3 or tipId == 6 then
                posY = posY + textHeight + AutoDrive.Hud.gapHeight
            end
        end
    end
end

function ADHudIcon:addVehicleDriveTimeString(vehicle, currentText)
    local remainingTime = vehicle.ad.stateModule:getRemainingDriveTime()
    if remainingTime ~= 0 then
        local remainingMinutes = math.floor(remainingTime / 60)
        local remainingSeconds = remainingTime % 60
        if remainingMinutes > 0 then
            currentText = currentText .. " - " .. string.format("%.0f", remainingMinutes) .. ":" .. string.format("%02d", math.floor(remainingSeconds))
        elseif remainingSeconds ~= 0 then
            currentText = currentText .. " - " .. string.format("%2.0f", remainingSeconds) .. "s"
        end
    end
    return currentText
end

function ADHudIcon:addTooltipString(vehicle, currentText)
    if vehicle.ad.sToolTip ~= "" and AutoDrive.getSetting("showTooltips") then
        if vehicle.ad.toolTipIsSetting then
            currentText = currentText .. " - " .. g_i18n:getText(vehicle.ad.sToolTip)
        else
            -- préfixe des touches (« FP - », avant « AD: ») retiré
            local tip = g_i18n:getText(vehicle.ad.sToolTip)
            if string.sub(tip, 1, 5) == "FP - " then
                tip = string.sub(tip, 6)
            elseif string.sub(tip, 1, 4) == "AD: " then
                tip = string.sub(tip, 5)
            end
            currentText = currentText .. " - " .. tip
        end

        if vehicle.ad.sToolTipInfo ~= nil then
            currentText = currentText .. " - " .. vehicle.ad.sToolTipInfo
        end
    end
    return currentText
end

function ADHudIcon:splitTextByLength(text, fontSize, maxLength)
    -- parts are separated by " - " only: a hyphen inside a word ("Demi-tour") must not cut the text
    local textParts = {}
    local start = 1
    while true do
        local i = text:find(" - ", start, true)
        if i == nil then
            table.insert(textParts, text:sub(start))
            break
        end
        table.insert(textParts, text:sub(start, i - 1))
        start = i + 3
    end
    local lines = {}
    local line = textParts[1]
    local index = 2
    while index <= #textParts do
        if getTextWidth(fontSize, line .. " - " .. textParts[index]) > maxLength then
            table.insert(lines, line)
            line = textParts[index]
        else
            line = line .. " - " .. textParts[index]
        end
        index = index + 1
    end
    table.insert(lines, line)
    return lines
end

function ADHudIcon:updateVisibility(vehicle)
    local newVisibility = self.isVisible
    if self.name == "unloadOverlay" then
        if (vehicle.ad.stateModule:getMode() == AutoDrive.MODE_PICKUPANDDELIVER or vehicle.ad.stateModule:getMode() == AutoDrive.MODE_UNLOAD or vehicle.ad.stateModule:getMode() == AutoDrive.MODE_LOAD) then
            newVisibility = true
        else
            newVisibility = false
        end
    end

    if self.name == "fruitOverlay" then
        if (vehicle.ad.stateModule:getMode() == AutoDrive.MODE_PICKUPANDDELIVER or vehicle.ad.stateModule:getMode() == AutoDrive.MODE_LOAD) then
            newVisibility = true
        else
            newVisibility = false
        end
    end

    self.isVisible = newVisibility
end

function ADHudIcon:act(vehicle, posX, posY, isDown, isUp, button)
    if self.name == "header" then
        if button == 1 and isDown and AutoDrive.pullDownListExpanded == 0 then
            if (not g_inGameMenu.isOpen or AutoDrive.aiFrameOpen) then
                AutoDrive.Hud:startMovingHud(posX, posY)
                return true
            end
        end
    end
    return false
end

function ADHudIcon:updateIcon(vehicle)
    local newIcon = self.image
    if self.name == "unloadOverlay" then
        if vehicle.ad.stateModule:getMode() == AutoDrive.MODE_LOAD then
            newIcon = "ad_gui.tipper_load"
        elseif vehicle.ad.stateModule:getMode() == AutoDrive.MODE_PICKUPANDDELIVER then
            newIcon = "ad_gui.tipper_overlay"
        elseif vehicle.ad.stateModule:getMode() == AutoDrive.MODE_UNLOAD then
            newIcon = "ad_gui.tipper_overlay"
        end
    elseif self.name == "destinationOverlay" then
        if vehicle.ad.stateModule:getMode() == AutoDrive.MODE_PICKUPANDDELIVER then
            newIcon = "ad_gui.tipper_load"
        elseif vehicle.ad.stateModule:getMode() == AutoDrive.MODE_DELIVERTO then
            newIcon = "ad_gui.tipper_overlay"
        elseif vehicle.ad.stateModule:getMode() ~= AutoDrive.MODE_BGA then
            newIcon = "ad_gui.destination"
        end
    end

    self.image = newIcon
    if self.ov ~= nil then
        -- self.ov:setSliceId(self.image)
    end
end
