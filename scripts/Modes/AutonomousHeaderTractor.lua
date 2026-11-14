-- ============================================================================================================
-- FarmPilot : AutonomousHeaderTractor.lua
-- Mode Autonome, moissonneuse ou ensileuse équipée seule (12/11) : quel véhicule déplace la remorque porte-barre, et
-- la roue dentée de la ligne « Outil » de la moissonneuse qui permet de le choisir.
--
-- Règle (12/11) :
-- - La remorque est déjà attelée : son tracteur (FarmPilot dessus, sinon « prise »).
-- - Sinon le véhicule choisi à la roue dentée, s'il est à l'arrêt, que rien n'est attelé à son arrière et qu'un de
--   ses attelages arrière libres va à la remorque. Un outil avant ou une masse ne gênent pas.
-- - Sinon le tracteur libre le plus proche de la remorque : un tracteur (catégorie du magasin : pas un automoteur,
--   un camion ni un chargeur, Manager/RoadTypesVehicles.lua), à l'arrêt, rien d'attelé, qui peut atteler la remorque.
-- - Une masse ne compte jamais comme un attelage.
-- - Véhicule choisi refusé : le tracteur libre le plus proche, avec un message (Modes/AutonomousHeader.lua).
-- - Aucun véhicule : le journal dit pourquoi chacun est refusé.
-- - Fenêtre de la roue dentée (Gui/HeaderTractorGUI.lua) : les véhicules FarmPilot de la ferme qui ont un attelage
--   arrière ; pas les moissonneuses ni les autres automoteurs (pulvérisateur automoteur...).
--
-- Branché par : Modes/AutonomousHeader.lua (onStart, startCollect : tractorFor), Modes/AutonomousHeaderChoice.lua
-- (readyToDeliver : tractorFor), Hud/HudButton.lua (hudGear, onGear, une ligne chacune), Gui/HeaderTractorGUI.lua
-- (choosableVehicles). Chargé par register.lua après AutonomousHeaderMount.lua.
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Petits outils
-- ------------------------------------------------------------------------------------------------------------
local function log(fmt, ...)
    ADHeaderFlow.log(fmt, ...)
end

local function label(o)
    return o ~= nil and ADAutonomousManager.toolLabel(o) or "?"
end

local function farmOf(object)
    if object ~= nil and object.getOwnerFarmId ~= nil then
        local ok, id = FarmPilotCall(object.getOwnerFarmId, object)
        if ok then
            return id
        end
    end
    return nil
end

local function vehicles()
    local system = g_currentMission ~= nil and g_currentMission.vehicleSystem or nil
    return system ~= nil and system.vehicles or {}
end

local function isGone(o)
    return o == nil or o.isDeleted or o.isDeleting
end

local function attacherOf(o)
    if o ~= nil and o.getAttacherVehicle ~= nil then
        return o:getAttacherVehicle()
    end
    return nil
end

local function rootOf(o)
    if o ~= nil and o.getRootVehicle ~= nil then
        return o:getRootVehicle() or o
    end
    return o
end

local function distance(a, b)
    local ax, _, az = getWorldTranslation(a.components[1].node)
    local bx, _, bz = getWorldTranslation(b.components[1].node)
    return MathUtil.vector2Length(ax - bx, az - bz)
end

-- ------------------------------------------------------------------------------------------------------------
-- Ce qui est attelé au véhicule, véhicule libre ou non
-- ------------------------------------------------------------------------------------------------------------
-- ce qui est attelé directement au véhicule, masses à part : { { object, rear } }
local function hitched(v)
    local out = {}
    if v.getAttachedImplements == nil then
        return out
    end
    local ok, implements = FarmPilotCall(v.getAttachedImplements, v)
    if not ok or type(implements) ~= "table" then
        return nil
    end
    local rear = {}
    for _, rj in ipairs(ADAutonomousManager.rearJoints(v)) do
        rear[rj.index] = true
    end
    for _, impl in ipairs(implements) do
        if impl.object ~= nil and not ADAutonomousManager.isMass(impl.object) then
            out[#out + 1] = { object = impl.object, rear = rear[impl.jointDescIndex] == true }
        end
    end
    return out
end

-- rien d'attelé (ni outil, ni remorque) ; une masse ne compte pas (12/11)
function ADHeaderFlow.isUnhitched(v)
    local list = hitched(v)
    return list ~= nil and #list == 0
end

-- rien d'attelé à l'arrière (outil avant ou masse gardés)
function ADHeaderFlow.isRearFree(v)
    local list = hitched(v)
    if list == nil then
        return false
    end
    for _, h in ipairs(list) do
        if h.rear then
            return false
        end
    end
    return true
end

-- un tracteur (catégorie du magasin, Manager/RoadTypesVehicles.lua) : pas un automoteur, un camion ni un chargeur
function ADHeaderFlow.isTractor(v)
    if ADRoadTypes == nil or ADRoadTypes.vehicleType == nil then
        return true
    end
    local ok, t = FarmPilotCall(ADRoadTypes.vehicleType, v)
    return not ok or t == nil or t == "tractor"
end

-- véhicule FarmPilot à l'arrêt, sans ouvrier, pas déjà pris par une autre barre
local function isIdle(v, combine)
    local sm = v ~= nil and v.ad ~= nil and v.ad.stateModule or nil
    return sm ~= nil and v ~= combine and v.spec_combine == nil and not isGone(v) and not sm:isActive()
        and not (v.getIsAIActive ~= nil and v:getIsAIActive()) and v.ad.fpHeaderJob == nil
end

-- pourquoi ce véhicule ne déplace pas la remorque (journal), ou nil s'il peut ; chosen : c'est le véhicule choisi
function ADHeaderFlow.tractorRefusal(v, trailer, combine, chosen)
    if not isIdle(v, combine) then
        return "pas à l'arrêt (FarmPilot ou ouvrier en marche, ou déjà pris par une barre)"
    end
    if chosen then
        if not ADHeaderFlow.isRearFree(v) then
            return "arrière pas libre"
        end
    else
        if not ADHeaderFlow.isTractor(v) then
            return "pas un tracteur"
        end
        local list = hitched(v)
        if list == nil or #list > 0 then
            return string.format("attelé à « %s »", list ~= nil and label(list[1].object) or "?")
        end
    end
    if ADAutonomousManager.matchJoints(v, trailer, true) == nil then
        return "pas d'attelage arrière libre du type de la remorque"
    end
    return nil
end

-- ------------------------------------------------------------------------------------------------------------
-- Tracteur de la remorque (fonction principale)
-- ------------------------------------------------------------------------------------------------------------
-- tracteur qui déplace la remorque : celui qui y est attelé, sinon le véhicule choisi (roue dentée) s'il est à
-- l'arrêt et que son arrière est libre, sinon le tracteur libre le plus proche (à l'arrêt, rien d'attelé, masses à
-- part, qui peut atteler la remorque) ;
-- nil, raison (« busy » : attelée à un véhicule sans FarmPilot ou qui roule, « none ») ; 3e valeur : le véhicule
-- choisi n'était pas libre
function ADHeaderFlow.tractorFor(trailer, combine, quiet)
    local attacher = attacherOf(trailer)
    if attacher ~= nil then
        local root = rootOf(attacher)
        if root ~= nil and root.ad ~= nil and root.ad.stateModule ~= nil and root ~= combine then
            return root
        end
        return nil, "busy"
    end
    local farm = farmOf(trailer)
    local sm = combine ~= nil and combine.ad ~= nil and combine.ad.stateModule or nil
    local chosen = sm ~= nil and sm.getFpHeaderTractor ~= nil and sm:getFpHeaderTractor() or nil
    local chosenBusy = nil
    local refused = {}
    if chosen ~= nil then
        local why = ADHeaderFlow.tractorRefusal(chosen, trailer, combine, true)
        if why == nil then
            return chosen
        end
        chosenBusy = chosen
        refused[#refused + 1] = string.format("« %s » (choisi) : %s", ADHeaderFlow.vehicleName(chosen), why)
    end
    local best, bestD = nil, math.huge
    for _, v in pairs(vehicles()) do
        if v ~= chosenBusy and v ~= combine and v.ad ~= nil and v.ad.stateModule ~= nil and v.spec_combine == nil and not isGone(v)
            and (farm == nil or farmOf(v) == farm) then
            local why = ADHeaderFlow.tractorRefusal(v, trailer, combine, false)
            if why == nil then
                local d = distance(v, trailer)
                if d < bestD then
                    best, bestD = v, d
                end
            else
                refused[#refused + 1] = string.format("« %s » : %s", ADHeaderFlow.vehicleName(v), why)
            end
        end
    end
    if best == nil then
        if not quiet then
            log("aucun tracteur pour « %s » : %s", label(trailer), #refused > 0 and table.concat(refused, " ; ") or "aucun véhicule FarmPilot de la ferme")
        end
        return nil, "none", chosenBusy
    end
    return best, nil, chosenBusy
end

-- ------------------------------------------------------------------------------------------------------------
-- Roue dentée de la ligne « Outil » (moissonneuse en Autonome) : véhicule de la remorque porte-barre
-- ------------------------------------------------------------------------------------------------------------
function ADHeaderFlow.gearShown(vehicle)
    return vehicle ~= nil and ADHeaderFlow.isCombine(vehicle) and vehicle.ad.stateModule:getMode() == AutoDrive.MODE_AUTONOMOUS
end

-- état de la roue dentée : « todo » (orange) = tracteur libre le plus proche, « ok » (verte) = véhicule choisi
function ADHeaderFlow.hudGear(vehicle, status, toolTip)
    if status ~= "none" or not ADHeaderFlow.gearShown(vehicle) then
        return status, toolTip
    end
    local chosen = vehicle.ad.stateModule.getFpHeaderTractor ~= nil and vehicle.ad.stateModule:getFpHeaderTractor() or nil
    return chosen ~= nil and "ok" or "todo", "gui_ad_headerTractor_tooltip"
end

function ADHeaderFlow.onGear(vehicle, button, isDown, isUp)
    local chosen = vehicle.ad.stateModule:getFpHeaderTractor()
    vehicle.ad.sToolTipInfo = chosen ~= nil and ADHeaderFlow.vehicleName(chosen) or g_i18n:getText("gui_ad_headerTractor_auto")
    if button == 1 and isUp then
        if ADHeaderTractorGui ~= nil then
            ADHeaderTractorGui.open(vehicle)
        end
        return true
    end
    if button > 0 and button < 4 and isDown then
        return true, true
    end
    return false
end

-- véhicules proposés dans la fenêtre : FarmPilot, de la ferme, avec un attelage arrière ; pas les moissonneuses ni
-- les autres automoteurs (pulvérisateur automoteur...) ; { vehicle, name, info }
function ADHeaderFlow.choosableVehicles(combine)
    local out = {}
    if combine == nil then
        return out
    end
    local farm = farmOf(combine)
    for _, v in pairs(vehicles()) do
        if v ~= combine and v.ad ~= nil and v.ad.stateModule ~= nil and v.spec_combine == nil and not isGone(v)
            and (farm == nil or farmOf(v) == farm) and v.getAttachedImplements ~= nil
            and #ADAutonomousManager.rearJoints(v) > 0
            and not (ADRoadTypes ~= nil and ADRoadTypes.vehicleType ~= nil and ADRoadTypes.vehicleType(v) == "selfPropelled") then
            local names = {}
            local ok, implements = FarmPilotCall(v.getAttachedImplements, v)
            if ok and type(implements) == "table" then
                for _, impl in ipairs(implements) do
                    if not ADAutonomousManager.isMass(impl.object) then -- une masse ne compte pas : « libre »
                        names[#names + 1] = label(impl.object)
                    end
                end
            end
            local d = distance(combine, v)
            local info = #names > 0 and table.concat(names, ", ") or g_i18n:getText("gui_ad_headerTractor_free")
            out[#out + 1] = { vehicle = v, name = ADHeaderFlow.vehicleName(v), info = string.format("%s · %d m", info, math.floor(d + 0.5)), distance = d }
        end
    end
    table.sort(out, function(a, b) return a.distance < b.distance end)
    return out
end
