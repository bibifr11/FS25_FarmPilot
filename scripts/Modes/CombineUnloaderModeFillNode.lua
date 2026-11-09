-- ============================================================================================================
-- FarmPilot : CombineUnloaderModeFillNode.lua
-- Complément de CombineUnloaderMode : le point de remplissage de la remorque. Commun ensileuse et moissonneuse.
--
-- (25/10) Erreur Lua : le point de remplissage n'était lu que pendant la poursuite
-- (getPipeChasePosition). Le demi-tour d'origine AutoDrive (HandleHarvesterTurnTask) mesure la place à la
-- goulotte et peut maintenant passer avant toute poursuite : point nil, 599 erreurs Lua en 19 s.
--
-- Règle : point lu quand il manque ou n'existe plus ; s'il reste inconnu, une ligne de log, et les distances à la
-- goulotte sont prises sur les longueurs (getDynamicSideChaseOffsetZ et getDynamicSideChaseOffsetZ_fromDischargeNode,
-- restées dans CombineUnloaderMode.lua avec leurs gardes).
--
-- Branché par : CombineUnloaderMode.lua (getDynamicSideChaseOffsetZ, getDynamicSideChaseOffsetZ_fromDischargeNode),
-- HandleHarvesterTurnTaskTurns.lua (ensureFillNode, au début du demi-tour).
-- ============================================================================================================

-- ------------------------------------------------------------------------------------------------------------
-- Point de remplissage de la remorque
-- ------------------------------------------------------------------------------------------------------------
-- 25/10 (Lua error): the trailer fill node was only read in getPipeChasePosition (the chase). The AutoDrive
-- U-turn task measures the place at the pipe (ForwardOffsetTurn) and can now run before any chase, e.g. the 7R called
-- 10 m from the stopped harvester right after a game load: node nil, 599 Lua errors in 19 s. Read it when missing or gone.
function CombineUnloaderMode:ensureTargetFillNode()
    local node = self.targetFillNode
    if node ~= nil and (entityExists == nil or entityExists(node)) then
        return node
    end
    if self.vehicle ~= nil and AutoDrive.getNextFreeDischargeableUnit ~= nil then
        self.targetFillUnit, self.targetFillNode, self.targetAutoAimTargetNode = AutoDrive.getNextFreeDischargeableUnit(self.vehicle)
    end
    node = self.targetFillNode
    if node ~= nil and entityExists ~= nil and not entityExists(node) then
        node = nil
    end
    if node == nil and not self.fillNodeMissingLogged then
        self.fillNodeMissingLogged = true
        local name = self.vehicle ~= nil and self.vehicle.getName ~= nil and self.vehicle:getName() or "?"
        print(string.format("[AD-Poursuite] %s: point de remplissage de la remorque inconnu, distance a la goulotte prise sur les longueurs", tostring(name)))
    end
    return node
end
