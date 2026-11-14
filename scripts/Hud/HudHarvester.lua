-- ============================================================================================================
-- FarmPilot : HudHarvester.lua
-- HUD du mode Autonome pour une moissonneuse ou une ensileuse (ébauche 11/11) : 4 lignes au lieu des lignes d'outils.
--
-- Règle (11/11) :
-- - De haut en bas : Champ (numéro) / Barre / Champ suivant / Barre suivante.
-- - Champ : le champ de la machine ET celui de ses bennes (mode « Décharger moissonneuse », même 1re destination) ;
--   au champ suivant, ses bennes la suivent (Modes/AutonomousHarvesterUnloaders.lua).
-- - Barre : « Auto (selon la culture) » par défaut, ou une barre de la ferme (coupe, coupe à maïs, bec d'ensileuse),
--   d'après la culture du champ (Modes/AutonomousHeaderChoice.lua). Roue dentée : le tracteur de la remorque
--   porte-barre (Gui/HeaderTractorGUI.lua). Ligne fermée : texte court (« Barre : auto (culture) », « Barre
--   suivante : auto »), la ligne du HUD est étroite.
-- - Barre suivante : « Auto » par défaut, devient « Barre » au champ suivant.
-- - Les lignes « Outil » et « Outil suivant » (arrière) ne sont pas montrées : une moissonneuse n'a pas d'outil arrière.
-- - Les deux lignes « Barre » reprennent les listes « Outil avant » (même choix enregistré, même événement réseau).
--
-- Branché par : Hud.lua (fpRowKind « harvester » : rangées, lignes « Barre » à la place des lignes d'outils),
-- Hud/PullDownList.lua (texte de la ligne fermée, 1re ligne de la liste). Chargé par register.lua après Hud.lua.
-- ============================================================================================================

ADHarvesterHud = {}

-- ------------------------------------------------------------------------------------------------------------
-- Quel HUD
-- ------------------------------------------------------------------------------------------------------------
function ADHarvesterHud.isHarvesterHud(vehicle)
    return vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.stateModule ~= nil
        and vehicle.ad.stateModule:getMode() == AutoDrive.MODE_AUTONOMOUS
        and ADHeaderFlow ~= nil and ADHeaderFlow.isCombine(vehicle)
end

local baseRowKind = AutoDriveHud.fpRowKind
function AutoDriveHud.fpRowKind(vehicle)
    if ADHarvesterHud.isHarvesterHud(vehicle) then
        return "harvester"
    end
    return baseRowKind(vehicle)
end

-- ------------------------------------------------------------------------------------------------------------
-- Lignes « Barre » et « Barre suivante » (Hud.lua : createHud)
-- ------------------------------------------------------------------------------------------------------------
function ADHarvesterHud.addRows(hud, rowHeader, rowNextHeader)
    local x = hud.posX + 2 * hud.gapWidth + hud.buttonWidth
    local w = hud.iconWidth * 6 + hud.gapWidth * 5
    local header = ADPullDownList:new(x, rowHeader, w, hud.listItemHeight, ADPullDownList.TYPE_FILLTYPE, 1)
    header.fpFront = true
    header.fpHeader = true
    header.order = 2
    table.insert(hud.hudElements, header)
    local nextHeader = ADPullDownList:new(x, rowNextHeader, w, hud.listItemHeight, ADPullDownList.TYPE_FILLTYPE, 1)
    nextHeader.fpFront = true
    nextHeader.fpNext = true
    nextHeader.fpHeader = true
    nextHeader.order = 4
    table.insert(hud.hudElements, nextHeader)
end

-- ------------------------------------------------------------------------------------------------------------
-- Textes
-- ------------------------------------------------------------------------------------------------------------
-- ligne fermée : « Barre : Coupe (9 m) », « Barre : auto (culture) »
function ADHarvesterHud.collapsedText(list, vehicle)
    local tool = list:fpGetTool(vehicle)
    if tool ~= nil then
        local okL, label = FarmPilotCall(ADAutonomousManager.frontLabel, tool)
        return string.format(g_i18n:getText(list.fpNext and "AD_header_nextLine" or "AD_header_line"), okL and label or ADAutonomousManager.toolLabel(tool))
    end
    return g_i18n:getText(list.fpNext and "AD_header_nextLineAuto" or "AD_header_lineAuto")
end
