-- ============================================================================================================
-- FarmPilot : TrafficYieldModulePassWatch.lua
-- Celui qui passe dans un croisement et reste arrêté sans raison (17/11, chemin de terre étroit : le MF 7S.210 attendait
-- devant le 7R Gen2 350 garé à moitié sur le chemin, le 7R attendait le MF, 1 min 30 jusqu'à la fin du plan).
--
-- Règle :
-- - En REVERSER_PASS ou PARKER_PASS, arrêté plus de PASSER_STOPPED_MS sans attente expliquée (carrefour, portail
--   qui s'ouvre, file derrière un autre véhicule qui n'est pas le partenaire, écart en cours, 3e véhicule en face,
--   partenaire pas encore garé) : trace de tout ce qui retient le véhicule, puis les rôles sont inversés
--   (restartWithRolesSwapped) : celui qui était garé passe, l'autre se range.
-- - Le cas courant : le partenaire garé reste dans le couloir et l'écart n'a pas trouvé de place à côté
--   (AvoidModule.lua : isParkedPartner).
--
-- Branché par : TrafficYieldModule:handle (watchPasserStopped) ; lit ADApproachModule (getHit), ADAvoidModule
-- (isActive, lastReason), ADIntersectionModule (isWaiting), ADGates (getSpeedLimit).
-- ============================================================================================================

ADTrafficYieldModule.PASSER_STOPPED_MS = 15000 -- ms stopped while passing, with nothing explaining it, before the roles are swapped

-- what holds the passer: returns explained (a normal wait), and a text for the trace
function ADTrafficYieldModule:getPasserStopReason()
    local vehicle = self.vehicle
    local partner = self.partner
    if ADIntersectionModule ~= nil and ADIntersectionModule.isWaiting ~= nil and ADIntersectionModule.isWaiting(vehicle) then
        return true, "attente au carrefour"
    end
    if ADGates ~= nil and ADGates.getSpeedLimit ~= nil and ADGates.getSpeedLimit(vehicle.ad.drivePathModule) <= 0 then
        return true, "portail qui s'ouvre"
    end
    local avoid = vehicle.ad.avoidModule
    if avoid ~= nil and avoid:isActive() then
        return true, "ecart en cours"
    end
    if self.otherConflict ~= nil then
        return true, "3e vehicule en face"
    end
    local partnerModule = partner ~= nil and partner.ad ~= nil and partner.ad.trafficYieldModule or nil
    local partnerState = partnerModule ~= nil and partnerModule.state or nil
    if partnerState == ADTrafficYieldModule.STATE_PARKER_SEARCH or partnerState == ADTrafficYieldModule.STATE_PARKER_MOVE
        or partnerState == ADTrafficYieldModule.STATE_REVERSER_RETREAT then
        return true, string.format("%s se range encore", ADTrafficYieldModule.getName(partner))
    end
    local approach = vehicle.ad.approachModule
    local hit = approach ~= nil and approach.getHit ~= nil and approach:getHit() or nil
    if hit ~= nil then
        local object = hit.object
        local root = object ~= nil and object.getRootVehicle ~= nil and object:getRootVehicle() or object
        local name = tostring(hit.name or "?")
        if root ~= nil and root == partner then
            return false, string.format("capteur avant sur %s (mon partenaire, %s) a %.1f m, ecart impossible (%s)", name,
                ADTrafficYieldModule.STATE_NAMES[partnerState] or tostring(partnerState), hit.distance or -1,
                tostring(avoid ~= nil and avoid.lastReason or "?"))
        end
        if hit.isVehicle or hit.isTraffic then
            local speed = root ~= nil and math.abs(root.lastSpeedReal or 0) * 3600 or 0
            return true, string.format("file derriere '%s' a %.1f m (%.0f km/h)", name, hit.distance or -1, speed)
        end
        return false, string.format("capteur avant sur l'objet '%s' a %.1f m, ecart impossible (%s)", name, hit.distance or -1,
            tostring(avoid ~= nil and avoid.lastReason or "?"))
    end
    local drivePathModule = vehicle.ad.drivePathModule
    return false, string.format("rien vu devant (partenaire %s, sur le reseau %s, limite %s km/h)",
        ADTrafficYieldModule.STATE_NAMES[partnerState] or tostring(partnerState),
        tostring(drivePathModule ~= nil and drivePathModule.isOnRoadNetwork ~= nil and drivePathModule:isOnRoadNetwork()),
        tostring(drivePathModule ~= nil and drivePathModule.speedLimit or "?"))
end

-- called every frame from handle while a plan runs; returns true when the plan was restarted
function ADTrafficYieldModule:watchPasserStopped(dt)
    local passing = self.state == ADTrafficYieldModule.STATE_REVERSER_PASS or self.state == ADTrafficYieldModule.STATE_PARKER_PASS
    if not passing or self.plan == nil or self.partner == nil or ADTrafficYieldModule.getSpeedKmh(self.vehicle) >= 1 then
        self.passerStoppedMs = nil
        return false
    end
    local explained, why = self:getPasserStopReason()
    if explained then
        if self.passerStoppedMs ~= nil and self.passerStoppedMs >= 5000 and why ~= self.passerStoppedWhy then
            self:log("passing, stopped: %s", tostring(why))
        end
        self.passerStoppedWhy = why
        self.passerStoppedMs = nil
        return false
    end
    self.passerStoppedMs = (self.passerStoppedMs or 0) + dt
    if self.passerStoppedWhy ~= why then
        self.passerStoppedWhy = why
        self:log("passing, stopped: %s", tostring(why))
    end
    if self.passerStoppedMs < ADTrafficYieldModule.PASSER_STOPPED_MS then
        return false
    end
    self.passerStoppedMs = nil
    self.passerStoppedWhy = nil
    print(string.format("[AD-Croise] %s: je dois passer mais je suis arrete depuis %d s : %s", ADTrafficYieldModule.getName(self.vehicle),
        ADTrafficYieldModule.PASSER_STOPPED_MS / 1000, tostring(why)))
    self:restartWithRolesSwapped(string.format("passer stopped for %d s (%s)", ADTrafficYieldModule.PASSER_STOPPED_MS / 1000, tostring(why)),
        string.format("je suis bloque depuis %d s alors que je dois passer", ADTrafficYieldModule.PASSER_STOPPED_MS / 1000))
    return true
end
