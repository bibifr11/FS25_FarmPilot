-- ============================================================================================================
-- FarmPilot : HudSilo.lua
-- HUD du mode « Tassage » (16/11) : 2 lignes, même cadre que « Conduire vers ».
--
-- - Bouton de mode : « Tassage » juste après « Autonome » (icône tracteur à lame, jaune quand il roule).
-- - 1re ligne « Silo » : liste de TOUS les silos couloirs de la carte, « Silo N (P %) - distance ». Le tracteur
--   peut être lancé de n'importe où : il va seul au silo choisi par le réseau, puis tasse (CompactMode,
--   Modes/SiloCompactorTask.lua).
-- - 2e ligne « Attente » : « Sur le côté » de l'entrée, ou un marqueur proche du silo (place quand une benne vide).
-- - Roue dentée de la 2e ligne : fenêtre « Tassage du silo » (réglages : sens, largeur, lame, arrêt à 100 %).
-- - On/Off : démarre / arrête le tassage.
-- Le choix des deux lignes est un réglage du tracteur (#fpSiloCfg), envoyé au serveur (ADSiloCompactEvent SAVE).
--
-- Branché par : Hud.lua (fpRowKind « silo » : 2 lignes, ADSiloHud.addRows), register.lua (après HudHarvester.lua).
-- La liste des destinations (même rangée que « Silo ») est cachée dans ce HUD (fpHidden).
-- ============================================================================================================

ADSiloHud = {}

local function text(key)
    return g_i18n:getText(key)
end

function ADSiloHud.isSiloHud(vehicle)
    return vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.stateModule ~= nil and AutoDrive.MODE_COMPACT ~= nil
        and vehicle.ad.stateModule:getMode() == AutoDrive.MODE_COMPACT
end

local baseRowKind = AutoDriveHud.fpRowKind
function AutoDriveHud.fpRowKind(vehicle)
    if ADSiloHud.isSiloHud(vehicle) then
        return "silo"
    end
    return baseRowKind(vehicle)
end

-- ------------------------------------------------------------------------------------------------------------
-- Lignes (Hud.lua : createHud)
-- ------------------------------------------------------------------------------------------------------------
function ADSiloHud.addRows(hud)
    local x = hud.posX + 2 * hud.gapWidth + hud.buttonWidth
    local w = hud.iconWidth * 6 + hud.gapWidth * 5
    local siloList = ADPullDownList:new(x, hud.row4, w, hud.listItemHeight, ADPullDownList.TYPE_FILLTYPE, 1)
    siloList.fpSilo = "silo"
    siloList.order = 1
    table.insert(hud.hudElements, siloList)
    local waitList = ADPullDownList:new(x, hud.row3, w, hud.listItemHeight, ADPullDownList.TYPE_FILLTYPE, 1)
    waitList.fpSilo = "wait"
    waitList.order = 2
    table.insert(hud.hudElements, waitList)
    if hud.targetPullDownList ~= nil then
        hud.targetPullDownList.fpHidden = true -- même rangée que « Silo »
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Textes
-- ------------------------------------------------------------------------------------------------------------
local function distanceText(d)
    if d >= 1000 then
        return string.format("%.1f km", d / 1000)
    end
    return string.format("%d m", math.floor(d + 0.5))
end

function ADSiloHud.siloLabel(silo, dist)
    local label = string.format(text("gui_ad_silo_hudSilo"), ADSiloJob.siloNumber(silo), ADSiloCompactor.getCompactedPercent(silo))
    if dist ~= nil then
        label = label .. " - " .. distanceText(dist)
    end
    return label
end

function ADSiloHud.collapsedText(list, vehicle)
    local cfg = ADSiloJob.getCfg(vehicle)
    if list.fpSilo == "silo" then
        local silo = ADSiloJob.selectedSilo(vehicle)
        if silo == nil then
            return text("gui_ad_silo_hudSiloNone")
        end
        local g = ADSiloCompactor.getGeometry(silo)
        local x, _, z = getWorldTranslation(vehicle.components[1].node)
        return ADSiloHud.siloLabel(silo, g ~= nil and ADSiloCompactor.distanceTo(g, x, z) or nil)
    end
    if cfg.wait == ADSiloJob.WAIT_MARKER and cfg.marker ~= nil then
        return string.format(text("gui_ad_silo_hudWait"), cfg.marker)
    end
    return string.format(text("gui_ad_silo_hudWait"), text("gui_ad_silo_waitSide"))
end

-- marqueurs proches du silo choisi (place d'attente), par distance
function ADSiloHud.waitMarkers(vehicle)
    local list = {}
    local silo = ADSiloJob.selectedSilo(vehicle)
    local g = silo ~= nil and ADSiloCompactor.getGeometry(silo) or nil
    if g == nil then
        return list
    end
    for _, m in pairs(ADGraphManager:getMapMarkers()) do
        local wp = m ~= nil and ADGraphManager:getWayPointById(m.id) or nil
        if wp ~= nil then
            local d = ADSiloCompactor.distanceTo(g, wp.x, wp.z)
            if d <= ADSiloJob.WAIT_MARKER_RANGE then
                table.insert(list, { name = m.name, dist = d })
            end
        end
    end
    table.sort(list, function(a, b) return a.dist < b.dist end)
    return list
end

-- ------------------------------------------------------------------------------------------------------------
-- Listes ouvertes
-- ------------------------------------------------------------------------------------------------------------
function ADSiloHud.fillOptions(list, vehicle)
    list.fpSiloEntries = {}
    list.options = { {} }
    if list.fpSilo == "silo" then
        local all = ADSiloJob.silosNear(vehicle, nil)
        table.sort(all, function(a, b) return ADSiloJob.siloNumber(a.silo) < ADSiloJob.siloNumber(b.silo) end)
        for i, e in ipairs(all) do
            list.fpSiloEntries[i] = { silo = e.silo }
            list.options[1][i] = { displayName = ADSiloHud.siloLabel(e.silo, e.dist), returnValue = i }
        end
        if #all == 0 then
            list.options[1][1] = { displayName = text("gui_ad_silo_hudSiloNone"), returnValue = 0 }
        end
    else
        list.fpSiloEntries[1] = { side = true }
        list.options[1][1] = { displayName = text("gui_ad_silo_waitSide"), returnValue = 1 }
        for i, m in ipairs(ADSiloHud.waitMarkers(vehicle)) do
            list.fpSiloEntries[i + 1] = { marker = m.name }
            list.options[1][i + 1] = { displayName = m.name, returnValue = i + 1 }
        end
    end
    list.fpToolOptions = true -- retour aux types de produit en quittant le mode (restoreFillTypeOptions)
    list.fpToolList = nil
end

-- choix dans la liste : réglage du tracteur, envoyé au serveur
function ADSiloHud.apply(list, vehicle, value)
    local e = list.fpSiloEntries ~= nil and list.fpSiloEntries[value] or nil
    if e == nil then
        return
    end
    local cfg = ADSiloJob.getCfg(vehicle)
    if e.silo ~= nil then
        ADSiloJob.selectSilo(vehicle, e.silo)
        -- autre silo : la place d'attente choisie près de l'ancien n'a plus de sens
        if cfg.wait == ADSiloJob.WAIT_MARKER then
            cfg.wait, cfg.marker = ADSiloJob.WAIT_SIDE, nil
        end
    elseif e.side then
        cfg.wait, cfg.marker = ADSiloJob.WAIT_SIDE, nil
    elseif e.marker ~= nil then
        cfg.wait, cfg.marker = ADSiloJob.WAIT_MARKER, e.marker
    end
    local x, z = 0, 0
    local silo = ADSiloJob.selectedSilo(vehicle)
    if silo ~= nil then
        x, z = ADSiloJob.center(silo)
    end
    ADSiloCompactEvent.send(vehicle, ADSiloCompactEvent.SAVE, ADSiloJob.cfgToText(cfg), x, z)
end

-- ------------------------------------------------------------------------------------------------------------
-- Enveloppes de ADPullDownList (listes fpSilo ; liste des destinations cachée : fpHidden)
-- ------------------------------------------------------------------------------------------------------------
local baseIsFpTool = ADPullDownList.isFpTool
function ADPullDownList:isFpTool(vehicle)
    if self.fpSilo ~= nil then
        return ADSiloHud.isSiloHud(vehicle)
    end
    return baseIsFpTool(self, vehicle)
end

local baseCreateFpTool = ADPullDownList.createSelection_FpTool
function ADPullDownList:createSelection_FpTool(vehicle)
    if self.fpSilo ~= nil then
        local ok = FarmPilotCall(ADSiloHud.fillOptions, self, vehicle)
        if not ok then
            self.options = { { { displayName = "", returnValue = 0 } } }
        end
        return
    end
    return baseCreateFpTool(self, vehicle)
end

local baseNewStateFill = ADPullDownList.getNewState_FillType
function ADPullDownList:getNewState_FillType(vehicle)
    if self.fpSilo ~= nil and self:isFpTool(vehicle) then
        if self.state == ADPullDownList.STATE_COLLAPSED then
            local ok, t = FarmPilotCall(ADSiloHud.collapsedText, self, vehicle)
            self.text = ok and t or ""
        end
        return self.state, self.selected
    end
    return baseNewStateFill(self, vehicle)
end

local baseCollapse = ADPullDownList.collapse
function ADPullDownList:collapse(vehicle, setItem)
    if self.fpSilo ~= nil and vehicle ~= nil and self:isFpTool(vehicle) then
        local value = nil
        if setItem == true and self.hovered ~= nil then
            local entry = self:getListElementByIndex(vehicle, self.hovered)
            value = entry ~= nil and entry.returnValue or nil
        end
        if self.state == ADPullDownList.STATE_EXPANDED then
            self.layer = self.layer - 1
        end
        self.state = ADPullDownList.STATE_COLLAPSED
        AutoDrive.pullDownListExpanded = 0
        if value ~= nil and value > 0 then
            FarmPilotCall(ADSiloHud.apply, self, vehicle, value)
        end
        AutoDrive.Hud.lastUIScale = 0
        return
    end
    return baseCollapse(self, vehicle, setItem)
end

local baseAct = ADPullDownList.act
function ADPullDownList:act(vehicle, posX, posY, isDown, isUp, button)
    if self.fpHidden then
        return false
    end
    if self.fpSilo ~= nil and button == 3 and self.state == ADPullDownList.STATE_COLLAPSED then
        return isUp == true -- clic droit : rien à vider sur ces lignes
    end
    return baseAct(self, vehicle, posX, posY, isDown, isUp, button)
end

local baseHit = ADPullDownList.hit
function ADPullDownList:hit(posX, posY, layer)
    if self.fpHidden then
        return false
    end
    return baseHit(self, posX, posY, layer)
end

local baseDraw = ADPullDownList.onDraw
function ADPullDownList:onDraw(vehicle, uiScale)
    if self.fpHidden then
        return
    end
    return baseDraw(self, vehicle, uiScale)
end

local baseGetTool = ADPullDownList.fpGetTool
function ADPullDownList:fpGetTool(vehicle)
    if self.fpSilo ~= nil then
        return nil
    end
    return baseGetTool(self, vehicle)
end
