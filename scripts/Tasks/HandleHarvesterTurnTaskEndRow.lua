-- ============================================================================================================
-- FarmPilot : HandleHarvesterTurnTaskEndRow.lua
-- Complément de HandleHarvesterTurnTask : le demi-tour de la benne en bout de rang derrière l'ENSILEUSE conduite
-- par Courseplay (benne qui roule à côté). Ne concerne pas la moissonneuse.
--
-- Historique :
-- - 23/10 : en bout de rang, la tâche de demi-tour d'origine AutoDrive est reprise et adaptée
--   (drapeau endRowUTurn posé par l'attente de fin de rang) ; le cap du nouveau rang et son entrée sont lus sur le
--   parcours Courseplay, pas sur les axes de l'ensileuse ; ordre des essais : demi-tour en avant, recul
--   puis demi-tour, demi-tour décalé en avant ;
-- - 24/10 : 4e solution, rouler jusqu'à l'ensileuse sur sa trace et faire le demi-tour derrière elle ;
-- - 27/10 19:48 : un seul virage à fond, la remorque suit à l'intérieur : rayon propre du tracteur (pas
--   celui qu'AutoDrive gonfle pour la remorque, 9 m et plus, qui sortait du champ à chaque bout de rang) ;
-- - 27/10 19:41 : un 180 au final, ou rien ; plus de manoeuvre en plusieurs temps, la recherche de route prend
--   le relais dès que les demi-tours fixes ne passent pas.
--
-- Suite du demi-tour : HandleHarvesterTurnTaskReverseToPipe.lua (attente de la fin de son virage et recul à côté
-- d'elle) ; croisement et face à face avec elle : HandleHarvesterTurnTaskHarvesterWay.lua.
--
-- Branché par des lignes dans HandleHarvesterTurnTask.lua : new (initEndRow, getCpRowTargetDirs, logEndRowStart),
-- tryNextTurn (prepareEndRowTurn), getHarvesterEndTurnPosition (getCpRowEntryPosition) ; getTurnRadius remplace
-- AutoDrive.getDriverRadius dans new, getUturnOffsetValues et generateUTurn.
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Réglages
-- ------------------------------------------------------------------------------------------------------------
HandleHarvesterTurnTask.OWN_RADIUS_FACTOR = 1.1 -- applied to the tractor's own turning radius at the end of a row
HandleHarvesterTurnTask.OWN_RADIUS_MIN = 5      -- m

HandleHarvesterTurnTask.TRAIL_GROUND_RADIUS = 4    -- m around the harvester's trail counted as drivable ground
HandleHarvesterTurnTask.TRAIL_START_DISTANCE = 6   -- m at most between the tractor and the trail
HandleHarvesterTurnTask.TRAIL_KEEP_BEHIND = 8      -- m kept behind the harvester's rear at the end of the trail
HandleHarvesterTurnTask.TRAIL_KEEP_BEHIND_CLOSE = 2 -- same, when the tractor is already close behind it

-- ------------------------------------------------------------------------------------------------------------
-- Début du demi-tour de bout de rang (accroches dans new)
-- ------------------------------------------------------------------------------------------------------------
function HandleHarvesterTurnTask:initEndRow()
    local vehicle = self.vehicle
    -- Courseplay end of row (23/10, the original task adapted): set when the end-of-row wait hands over
    local flag = vehicle.ad.endRowUTurn
    self.endRow = flag ~= nil and (g_time or 0) - flag < CatchCombinePipeTask.END_ROW_UTURN_AGE
    if self.endRow then
        -- order of the tries: forward U-turn, back then U-turn, forward offset U-turn
        self.nextTurnToTry = -1
        self.endRowTries = 0
    end
end

function HandleHarvesterTurnTask:getCpRowTargetDirs()
    -- Courseplay (23/10): the new row heading read on its course, not the harvester axes
    local targetDirZ = {x = self.cpRow.dx, z = self.cpRow.dz}
    local targetDirX = {x = self.cpRow.dz, z = -self.cpRow.dx}
    return targetDirX, targetDirZ
end

function HandleHarvesterTurnTask:logEndRowStart(turnLeft, targetPosition)
    local vehicle = self.vehicle
    print(string.format("[AD-DemiTour] %s: bout de rang, demi-tour d'origine AutoDrive vers la %s (nouveau rang a %.0f,%.0f, ecart de cap %.0f deg, rayon du tracteur seul %.1f m)",
        tostring(vehicle:getName()), turnLeft and "gauche" or "droite", targetPosition.x, targetPosition.z, self.turnParameters.angle, self.turnParameters.minRadius))
end

-- (accroche dans getHarvesterEndTurnPosition, quand l'ouvrier du jeu ne donne pas la fin de son virage)
function HandleHarvesterTurnTask:getCpRowEntryPosition()
    -- Courseplay harvester (23/10): entry of the new row read on its course (kept at the end-of-row wait)
    if self.cpRow == nil and self.endRow then
        local ant = self.vehicle.ad.anticipatedRear
        if ant ~= nil and (g_time or 0) - ant.t < PathFinderModule.ANTICIPATED_MAX_AGE then
            self.cpRow = {x = ant.ex, z = ant.ez, dx = ant.dx, dz = ant.dz}
        else
            -- its turn is over (or the row was not read): it stands on its new row, its own heading gives it
            local cx, _, cz = getWorldTranslation(self.combine.components[1].node)
            local dx, _, dz = AutoDrive.localDirectionToWorld(self.combine, 0, 0, 1)
            local len = math.sqrt(dx * dx + dz * dz)
            if len > 0.01 then
                self.cpRow = {x = cx, z = cz, dx = dx / len, dz = dz / len}
            end
        end
    end
    if self.cpRow ~= nil then
        return {x = self.cpRow.x, y = AutoDrive:getTerrainHeightAtWorldPos(self.cpRow.x, self.cpRow.z) or 0, z = self.cpRow.z}
    end
    return nil
end

-- ------------------------------------------------------------------------------------------------------------
-- Rayon de braquage des demi-tours fixes
-- ------------------------------------------------------------------------------------------------------------
-- turning radius of the fixed turns. End of row (27/10 19:48: one full-lock turn, the trailer follows
-- inside the tractor's track): the tractor's own radius, not the one AutoDrive inflates for the trailer (9 m and
-- more, which left the field at every row end)
function HandleHarvesterTurnTask:getTurnRadius()
    if self.endRow then
        local ok, own = FarmPilotCall(AutoDrive.getDriverRadius, self.vehicle, true)
        if ok and type(own) == "number" and own > 0 then
            return math.max(HandleHarvesterTurnTask.OWN_RADIUS_MIN, own * HandleHarvesterTurnTask.OWN_RADIUS_FACTOR)
        end
    end
    return AutoDrive.getDriverRadius(self.vehicle)
end

-- ------------------------------------------------------------------------------------------------------------
-- Demi-tours fixes épuisés : trace de l'ensileuse, puis recherche de route (accroche dans tryNextTurn)
-- ------------------------------------------------------------------------------------------------------------
-- true : tryNextTurn s'arrête là
function HandleHarvesterTurnTask:prepareEndRowTurn()
    if self.endRow then
        if self.endRowTries >= 5 and not self.trailTried then
            -- 4th way (24/10: drive up to the harvester, U-turn behind it): drive its own trail
            self.trailTried = true
            if self:tryCombineTrail() then
                return true
            end
        end
        if self.endRowTries >= 5 then
            -- 27/10 19:41 (one 180 in the end, or nothing): the multi-step band manoeuvre is no longer tried at the
            -- end of a row, the route search takes over at once
            print(string.format("[AD-DemiTour] %s: aucun demi-tour fixe ne passe en bout de rang, pas de manoeuvre en plusieurs temps, recherche de route", tostring(self.vehicle:getName())))
            self.vehicle.ad.endRowUTurn = nil
            self:finished(ADTaskModule.DONT_PROPAGATE)
            self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD]:setToWaitForCall(true)
            self.endRowGaveUp = true
            return true
        end
        self.endRowTries = self.endRowTries + 1
    end
    return false
end

function HandleHarvesterTurnTask:tryCombineTrail()
    local mode = self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD]
    if mode == nil or mode.getCombineTrailFrom == nil then
        return false
    end
    local x, _, z = getWorldTranslation(self.vehicle.components[1].node)
    local combine = self.combine
    -- its trail leads to it: only when it is ahead of the tractor (not when the tractor faces away from it)
    local cx, _, cz = getWorldTranslation(combine.components[1].node)
    local fx, _, fz = AutoDrive.localDirectionToWorld(self.vehicle, 0, 0, 1)
    if math.abs(AutoDrive.angleBetween({x = fx, z = fz}, {x = cx - x, z = cz - z})) > 90 then
        print(string.format("[AD-DemiTour] %s: demi-tour sur la trace de l'ensileuse impossible (ensileuse derriere moi)", tostring(self.vehicle:getName())))
        return false
    end
    local combineRear = (combine.size ~= nil and combine.size.length or 10) / 2 - (combine.size ~= nil and combine.size.lengthOffset or 0)
    local points, why = mode:getCombineTrailFrom(x, z, HandleHarvesterTurnTask.TRAIL_START_DISTANCE,
        combineRear + HandleHarvesterTurnTask.TRAIL_KEEP_BEHIND + (self.vehicle.size ~= nil and self.vehicle.size.length / 2 or 3))
    if points == nil and why == "trace trop courte devant moi" then
        -- already close behind it (sim 24/10: 16 m, tractor at 68 deg): drive its trail up to just behind its rear,
        -- the tractor ends aligned with it and the chase takes over
        points, why = mode:getCombineTrailFrom(x, z, HandleHarvesterTurnTask.TRAIL_START_DISTANCE, combineRear + HandleHarvesterTurnTask.TRAIL_KEEP_BEHIND_CLOSE)
        if points ~= nil then
            print(string.format("[AD-DemiTour] %s: deja pres de l'ensileuse, je suis sa trace jusqu'a %.0f m derriere elle pour m'aligner",
                tostring(self.vehicle:getName()), HandleHarvesterTurnTask.TRAIL_KEEP_BEHIND_CLOSE))
        end
    end
    if points == nil then
        print(string.format("[AD-DemiTour] %s: demi-tour sur la trace de l'ensileuse impossible (%s)", tostring(self.vehicle:getName()), tostring(why)))
        return false
    end
    local ok, groundWhy = self:checkGround(points)
    if not ok then
        print(string.format("[AD-DemiTour] %s: demi-tour sur la trace de l'ensileuse refuse : %s", tostring(self.vehicle:getName()), tostring(groundWhy)))
        return false
    end
    print(string.format("[AD-DemiTour] %s: je suis la trace de l'ensileuse pour faire son demi-tour derriere elle (%d points)",
        tostring(self.vehicle:getName()), #points))
    self.vehicle.ad.endRowUTurn = nil
    self:continueWith(points)
    return true
end
