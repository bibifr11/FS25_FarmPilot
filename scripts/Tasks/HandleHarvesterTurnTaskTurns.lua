-- ============================================================================================================
-- FarmPilot : HandleHarvesterTurnTaskTurns.lua
-- Complément de HandleHarvesterTurnTask (tâche AutoDrive d'origine : demi-tour de la benne quand la machine fait
-- demi-tour) : choix et contrôle des demi-tours fixes. Commun ensileuse et moissonneuse ; les parties propres au
-- bout de rang de l'ensileuse (self.endRow) sont marquées et renvoient à HandleHarvesterTurnTaskEndRow.lua et
-- HandleHarvesterTurnTaskHarvesterWay.lua.
--
-- Historique :
-- - 23/10 : le demi-tour respecte les réglages AutoDrive « rester dans le champ » et « éviter la culture » (Strict
--   refuse, sinon autorisé), sur toute la largeur du train ; 24/10 : sur la trace de l'ensileuse, la culture
--   ne compte pas ; 27/10 : dans un arc serré la remorque passe à l'intérieur de la trace du tracteur ;
-- - 24/10 : en bout de rang, écart de cap 150-210 deg accepté (le recul vers la goulotte reprend le reste) ;
--   25/10 19:14 : le Y tourne jusqu'au cap du nouveau rang, 90-270 deg ;
-- - 25/10 (599 erreurs Lua en 19 s) : une erreur Lua dans la génération d'un demi-tour n'arrête plus
--   AutoDrive, ce demi-tour est abandonné et le suivant essayé ; le point de remplissage est lu dès le début ;
-- - 30/10 (A) : un demi-tour qui croise la suite du virage de l'ensileuse attend qu'elle soit passée.
--
-- Les deux demi-tours ajoutés à la liste d'AutoDrive (équerre et Y, 25/10 et 27/10) sont créés dans
-- HandleHarvesterTurnTask:tryNextTurn (scripts/Tasks/Turns/SquareTurn.lua et YTurn.lua).
--
-- Branché par des lignes dans HandleHarvesterTurnTask.lua : new (ensureFillNode), update (updateCurrentTurn,
-- acceptOrDropTurn), tryNextTurn (checkTurnValidity). checkGround est aussi appelé par FollowCombineTask et
-- CatchCombinePipeTask.
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Noms des demi-tours (pour le log)
-- ------------------------------------------------------------------------------------------------------------
HandleHarvesterTurnTask.turnNames = {[0] = "demi-tour en avant", [1] = "recul puis demi-tour", [2] = "demi-tour decale en avant",
    [3] = "demi-tour en equerre (arc avant, recul droit, arc avant ; recul et ecart d'abord si derriere)", [4] = "manoeuvre en Y (avance en biais, long recul droit, demi-tour en avant)"}

-- ------------------------------------------------------------------------------------------------------------
-- Point de remplissage de la remorque lu dès le début (accroche dans new)
-- ------------------------------------------------------------------------------------------------------------
function HandleHarvesterTurnTask:ensureFillNode()
    local vehicle = self.vehicle
    -- 25/10 (Lua error): the mode reads the trailer fill node in the chase only, this task can come first
    local mode = vehicle.ad ~= nil and vehicle.ad.modes ~= nil and vehicle.ad.modes[AutoDrive.MODE_UNLOAD] or nil
    if mode ~= nil and mode.ensureTargetFillNode ~= nil then
        mode:ensureTargetFillNode()
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Génération protégée (accroche dans update) : true quand le demi-tour est prêt
-- ------------------------------------------------------------------------------------------------------------
function HandleHarvesterTurnTask:updateCurrentTurn()
    local turnReady = false
    if self.currentTurn ~= nil then
        -- 25/10 (599 Lua errors in 19 s): a Lua error while generating a turn must not stop
        -- AutoDrive every frame, the turn is dropped and the next one tried
        local ok, result = pcall(self.currentTurn.update, self.currentTurn)
        if ok then
            turnReady = result
            if not result and self.currentTurn.failed then
                print(string.format("[AD-DemiTour] %s: demi-tour d'origine AutoDrive, %s : generation impossible, demi-tour suivant", tostring(self.vehicle:getName()),
                    (self.turnNames ~= nil and self.turnNames[self.nextTurnToTry]) or "?"))
                self.currentTurn = nil
            end
        else
            print(string.format("[AD-DemiTour] %s: erreur Lua dans la generation du demi-tour %s, ce demi-tour est abandonne : %s", tostring(self.vehicle:getName()),
                (self.turnNames ~= nil and self.turnNames[self.nextTurnToTry]) or "?", tostring(result)))
            self.currentTurn = nil
        end
    end
    return turnReady
end

-- ------------------------------------------------------------------------------------------------------------
-- Écart de cap accepté (accroche dans tryNextTurn) : false = ce demi-tour est écarté
-- ------------------------------------------------------------------------------------------------------------
function HandleHarvesterTurnTask:checkTurnValidity()
    -- end of row (24/10): 150-210 deg accepted, the reverse to the pipe takes up the rest (30 deg allowed)
    -- the Y manoeuvre turns until the new row heading: 90-270 deg (25/10 19:14: the 7R was at 103 deg, nothing passed)
    local valid
    local window = "150-210"
    if self.endRow and self.nextTurnToTry >= 3 then
        valid = self.currentTurn.checkValidity(self.turnParameters)
        window = "90-270"
    elseif self.endRow then
        valid = self.turnParameters.angle > 150 and self.turnParameters.angle < 210
    else
        valid = self.currentTurn.checkValidity(self.turnParameters)
    end
    if not valid then
        if self.endRow then
            print(string.format("[AD-DemiTour] %s: demi-tour d'origine AutoDrive, %s : ecart de cap %.0f deg hors %s", tostring(self.vehicle:getName()),
                self.turnNames[self.nextTurnToTry] or "?", self.turnParameters.angle, window))
        end
    end
    return valid
end

-- ------------------------------------------------------------------------------------------------------------
-- Demi-tour retenu ou écarté après le contrôle d'obstacles (accroche dans update)
-- ------------------------------------------------------------------------------------------------------------
function HandleHarvesterTurnTask:acceptOrDropTurn(points, foundCollision)
    local groundOk, groundWhy = true, nil
    if not foundCollision then
        groundOk, groundWhy = self:checkGround(points)
    end
    print(string.format("[AD-DemiTour] %s: demi-tour d'origine AutoDrive, %s vers la %s : %s", tostring(self.vehicle:getName()),
        self.turnNames[self.nextTurnToTry] or "?", self.turnParameters.targetLeft and "gauche" or "droite",
        foundCollision and "obstacle sur le trajet" or (groundOk and "retenu" or tostring(groundWhy))))
    if foundCollision or not groundOk then
        self.currentTurn = nil
    else
        if self.endRow then
            self.vehicle.ad.endRowUTurn = nil
        end
        -- 30/10 (A): the harvester is left out of the obstacle check above; its remaining turn
        -- must not cross the U-turn, else wait until it has entered its row and passed
        local crosses, cx, cz, gap = false, nil, nil, nil
        if self.endRow then
            crosses, cx, cz, gap = self:crossesHarvesterWay(points, 1)
        end
        if crosses then
            print(string.format("[AD-DemiTour] %s: mon demi-tour croise la suite du virage de l'ensileuse (vers %.0f,%.0f, %.1f m), j'attends qu'elle soit entree dans son rang et passee",
                tostring(self.vehicle:getName()), cx, cz, gap))
            self:startWaitHarvesterPass(points, "croisement")
        else
            self:continueWith(points)
        end
    end
end

-- ------------------------------------------------------------------------------------------------------------
-- Sol sous le train : champ et culture
-- ------------------------------------------------------------------------------------------------------------
-- how far inside the tractor's track the trailer axle runs on an arc of radius r (off-tracking)
function HandleHarvesterTurnTask:getTrailerOfftrack(r)
    local ok, len = pcall(AutoDrive.getTractorTrainLength, self.vehicle, false, true)
    local trailer = ok and type(len) == "number" and len or 7
    trailer = math.min(trailer, r * 0.95)
    return r - math.sqrt(math.max(0, r * r - trailer * trailer))
end

-- field and crop under the whole width of the train along the turn, by the AutoDrive settings (23/10):
-- Strict refuses, otherwise allowed. The last reverse points toward the harvester (its own cut track) are kept
function HandleHarvesterTurnTask:checkGround(points, widthFactor, ignoreCrop)
    local strictField = AutoDrive.getSetting("restrictToField", self.vehicle) == "strict"
    local strictCrop = AutoDrive.getSetting("avoidFruit", self.vehicle) == "strict" and not ignoreCrop
    if not strictField and not strictCrop then
        return true
    end
    local half = (self.vehicle.ad.pathFinderModule ~= nil and self.vehicle.ad.pathFinderModule:getTrainWidth() or 3) / 2 * (widthFactor or 1)
    local pf = PathFinderModule
    -- ground the harvester drove on is drivable, even beyond the field border (its CP turn, sim 24/10)
    local mode = self.vehicle.ad.modes ~= nil and self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD] or nil
    local stored = pf.ignoreIsolatedCrop
    pf.ignoreIsolatedCrop = true
    local why = nil
    for i = 2, #points do
        local a, b = points[i - 1], points[i]
        local dx, dz = b.x - a.x, b.z - a.z
        local len = math.sqrt(dx * dx + dz * dz)
        if len > 0.01 then
            dx, dz = dx / len, dz / len
            local widths = {-half, 0, half}
            -- tight arc: the trailer runs inside the tractor's track (27/10), its track is checked too
            local c = points[i + 1]
            if c ~= nil then
                local ex, ez = c.x - b.x, c.z - b.z
                local elen = math.sqrt(ex * ex + ez * ez)
                if elen > 0.01 then
                    ex, ez = ex / elen, ez / elen
                    local turn = math.atan2(dx * ez - dz * ex, dx * ex + dz * ez)
                    local arc = (len + elen) / 2
                    if math.abs(turn) > 1e-3 and arc / math.abs(turn) < 30 then
                        local r = arc / math.abs(turn)
                        local off = self:getTrailerOfftrack(r)
                        -- probe below: (b.x - dz * w, b.z + dx * w), so w > 0 is the RIGHT of heading (dx, dz)
                        local inside = turn > 0 and 1 or -1
                        widths[#widths + 1] = inside * off
                        widths[#widths + 1] = inside * (off + half)
                    end
                end
            end
            for _, w in ipairs(widths) do
                local px, pz = b.x - dz * w, b.z + dx * w
                if strictField and not pf.getMapOnFieldAt(px, pz) and not (mode ~= nil and mode.isOnCombineTrail ~= nil
                    and mode:isOnCombineTrail(px, pz, HandleHarvesterTurnTask.TRAIL_GROUND_RADIUS)) then
                    why = string.format("hors du champ vers %.0f,%.0f", px, pz)
                    break
                end
                local crop = pf.getMapCropAt(px, pz)
                -- 24/10: on the harvester's own trail the crop under it does not count (its U-turn with
                -- the header lifted)
                if strictCrop and crop ~= nil and crop ~= 0 and not (mode ~= nil and mode.isOnCombineTrail ~= nil and mode:isOnCombineTrail(px, pz)) then
                    why = string.format("culture vers %.0f,%.0f", px, pz)
                    break
                end
            end
        end
        if why ~= nil then
            break
        end
    end
    pf.ignoreIsolatedCrop = stored
    return why == nil, why
end
