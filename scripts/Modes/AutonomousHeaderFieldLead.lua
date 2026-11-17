-- ============================================================================================================
-- FarmPilot : AutonomousHeaderFieldLead.lua
-- Mode Autonome, moissonneuse équipée seule : barre posée sur sa remorque dans le champ, puis amenée au champ
-- suivant. Celle des deux qui est la plus près de la sortie du champ part la première.
--
-- Cas en jeu (17/11, champ 54 -> « Champ 7 », Lexion 6900, MF 7S.210, Lizard Legacy Trailer 35FT) : la barre est
-- posée sur la remorque dans le champ, la Lexion recule de 7 m et reste entre le MF et l'entrée du champ (13 m de
-- lui). Le MF part le premier : le calcul de sortie par l'entrée refuse le passage (« obstacle vers 15,-445 » = la
-- Lexion, puis virages trop serrés pour la remorque en la contournant), « n'a pas pu calculer un chemin ». La
-- Lexion attendait que la remorque passe devant elle : chacun attendait l'autre.
--
-- Règle (comme le retour de fin de champ, AutonomousHeaderReturn.lua, et le 15/11 « si elle bloque le tracteur elle
-- part la première ») :
-- - Amenée (phase « deliver »), le tracteur a la remorque attelée, il est dans le champ et la moissonneuse aussi, à
--   moins de LEAD_RANGE m de lui, et elle est plus près que lui du point de sortie du champ : elle part la première
--   (job.leadFirst : elle va au bout de sa route sans s'arrêter devant la remorque, AutonomousHeaderFollow.lua).
-- - Le tracteur attend sur place qu'elle ait LEAD_GAP m d'écart, ou qu'elle soit sortie du champ, puis part. Il part
--   quand même si elle ne bouge plus depuis LEAD_STUCK ms après avoir bougé, ou au bout de LEAD_MAX ms.
-- - Réglage LEAD = false : comme avant.
--
-- Branché par : enveloppes de ADHeaderFlow.tractorStart et ADHeaderFlow.tractorStage (étape « fieldLead »).
-- Chargé par register.lua après AutonomousHeaderStuck.lua.
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
ADHeaderFlow.LEAD = true
ADHeaderFlow.LEAD_RANGE = 80      -- m au plus entre la moissonneuse et le tracteur
ADHeaderFlow.LEAD_GAP = 40        -- m d'écart avant que le tracteur parte
ADHeaderFlow.LEAD_STUCK = 20000   -- ms : elle ne bouge plus, il part quand même
ADHeaderFlow.LEAD_MAX = 240000    -- ms d'attente au plus

local function nameOf(v)
    return ADHeaderFlow.vehicleName(v)
end

local function log(fmt, ...)
    ADHeaderFlow.log(fmt, ...)
end

local function gone(v)
    return v == nil or v.isDeleted or v.components == nil or v.ad == nil
end

local function pos(v)
    local x, y, z = getWorldTranslation(v.components[1].node)
    return x, y, z
end

local function onField(v)
    local x, y, z = pos(v)
    return AutoDrive ~= nil and AutoDrive.checkIsOnField ~= nil and AutoDrive.checkIsOnField(x, y, z) == true
end

local function attachedTo(trailer, t)
    local attacher = trailer ~= nil and trailer.getAttacherVehicle ~= nil and trailer:getAttacherVehicle() or nil
    if attacher == nil then
        return false
    end
    local root = attacher.getRootVehicle ~= nil and attacher:getRootVehicle() or attacher
    return root == t or attacher == t
end

local function gapOf(a, b)
    local ax, _, az = pos(a)
    local bx, _, bz = pos(b)
    return MathUtil.vector2Length(ax - bx, az - bz)
end

-- point de sortie du champ du tracteur vers le champ suivant (le même que son calcul de route), nil si aucun
local function exitPoint(t, job)
    local pf = t.ad.pathFinderModule
    if pf == nil or pf.getFieldExitWayPoint == nil then
        return nil
    end
    local ok, id = FarmPilotCall(pf.getFieldExitWayPoint, pf, job.fieldId)
    local wp = ok and id ~= nil and ADGraphManager:getWayPointById(id) or nil
    return wp, id
end

-- true = la moissonneuse part la première (elle est entre le tracteur et la sortie du champ)
function ADHeaderFlow.combineLeadsOut(job)
    local t, c = job.tractor, job.combine
    if gone(t) or gone(c) or not onField(t) or not onField(c) then
        return false
    end
    local gap = gapOf(t, c)
    if gap > ADHeaderFlow.LEAD_RANGE then
        return false
    end
    local wp, id = exitPoint(t, job)
    if wp == nil then
        return false
    end
    local tx, _, tz = pos(t)
    local cx, _, cz = pos(c)
    local dt = MathUtil.vector2Length(tx - wp.x, tz - wp.z)
    local dc = MathUtil.vector2Length(cx - wp.x, cz - wp.z)
    log("%s : sortie du champ par le point %s : « %s » à %.0f m, lui à %.0f m (écart %.0f m)", nameOf(t), tostring(id), nameOf(c), dc, dt, gap)
    return dc < dt
end

-- le tracteur attend que la moissonneuse ait pris de l'avance
local function leadDone(job, s)
    local t, c = job.tractor, job.combine
    if job.cancelled or gone(c) or gone(t) then
        return true
    end
    local now = g_time or 0
    s.start = s.start or now
    if now - s.start >= ADHeaderFlow.LEAD_MAX then
        s.why = string.format("attente de %.0f s au plus", ADHeaderFlow.LEAD_MAX / 1000)
        return true
    end
    local gap = gapOf(t, c)
    if gap >= ADHeaderFlow.LEAD_GAP then
        s.why = string.format("elle a %.0f m d'avance", gap)
        return true
    end
    if not onField(c) then
        s.why = "elle est sortie du champ"
        return true
    end
    if math.abs(c.lastSpeedReal or 0) > 0.0005 then
        s.moved = true
        s.still = nil
    elseif s.moved then
        s.still = s.still or now
        if now - s.still >= ADHeaderFlow.LEAD_STUCK then
            s.why = string.format("elle ne bouge plus depuis %.0f s", ADHeaderFlow.LEAD_STUCK / 1000)
            return true
        end
    end
    return false
end

if ADHeaderFlow.tractorStart ~= nil then
    local baseTractorStart = ADHeaderFlow.tractorStart
    function ADHeaderFlow.tractorStart(mode, job)
        local t = mode.vehicle
        if ADHeaderFlow.LEAD and job ~= nil and job.phase == "deliver" and not job.cancelled and not job.fieldLeadGo
            and job.combine ~= nil and attachedTo(job.trailer, t) then
            job.fieldLeadGo = true -- une seule fois par amenée
            if ADHeaderFlow.combineLeadsOut(job) then
                local sm = t.ad.stateModule
                if not sm:isActive() then
                    t:startAutoDrive()
                    if not sm:isActive() then
                        return true
                    end
                end
                mode:reset()
                job.leadFirst = true
                log("%s : « %s » est entre lui et la sortie du champ : elle part la première, il attend qu'elle ait %.0f m d'avance",
                    nameOf(t), nameOf(job.combine), ADHeaderFlow.LEAD_GAP)
                local s = {}
                mode.fieldLeadState = s
                ADHeaderFlow.startWait(mode, "fieldLead", function() return leadDone(job, s) end)
                return true
            end
        end
        return baseTractorStart(mode, job)
    end
end

if ADHeaderFlow.tractorStage ~= nil then
    local baseTractorStage = ADHeaderFlow.tractorStage
    function ADHeaderFlow.tractorStage(mode, job, stage, result)
        if stage == "fieldLead" then
            local t = mode.vehicle
            local s = mode.fieldLeadState or {}
            mode.fieldLeadState = nil
            if job.cancelled then
                ADHeaderFlow.stopHere(mode, nil)
                return
            end
            log("%s : part derrière « %s » (%s)", nameOf(t), nameOf(job.combine), tostring(s.why or result))
            ADHeaderFlow.tractorStart(mode, job)
            return
        end
        return baseTractorStage(mode, job, stage, result)
    end
end
