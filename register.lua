--[[
FarmPilot, based on AutoDrive 3.0.1.4

LICENSE (MIT)
MIT License

Copyright (c) 2024 Stephan Schlosser

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

CREDITS
FarmPilot:
bibifr - FarmPilot, based on AutoDrive 3.0.1.4

Translations (FarmPilot):
Turkish: huseyinsayar

Original mod: AutoDrive (https://github.com/Stephan-S/FS25_AutoDrive), MIT licence, Copyright (c) 2024 Stephan Schlosser

Main developers:
Stephan-S
Axel32019
TyKonKet

GUI Textures and Design:
OlfDE

Logo Design:
FinalsFarming 

Others:
Anonymous-any
Roby1164
Gonimy-Vetrom
Bandesss
raxtor
raupach
Dzi4d3k
PromGames
jala15
cristiancundari
Iwan1803
rogeriodec
Efratror
pvaiko
Datalund
Bobster82
criss20ster
Gariot
andrefelipeschulle

Tips & Tricks for Lua/FS: 
DeckerMMIV
]]

--
-- Mod: AutoDrive
--
-- Author: Stephan
-- Email: Stephan910@web.de
-- Date: 17.12.2021
-- Version: 2.0.0.2

-- #############################################################################

source(Utils.getFilename("scripts/Utils/FarmPilotLogFilter.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Utils/FarmPilotTraces.lua", g_currentModDirectory)) -- traces privées : fichier à part, interrupteur sur le PC
source(Utils.getFilename("scripts/AutoDrive.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Utils/AutoDriveVehicleData.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Utils/AutoDrivePlaceableData.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Specialization.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Sync.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/XML.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Settings.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Utils/AutoDriveReglages.lua", g_currentModDirectory)) -- réglages généraux : index enregistré hors liste remis au défaut
source(Utils.getFilename("scripts/Gui.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Hud.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/ExternalInterface.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/PathCalculation.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/PathCalculationWidth.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/PathCalculationShift.lua", g_currentModDirectory))

source(Utils.getFilename("scripts/Hud/GenericHudElement.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Hud/Hotspot.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Hud/HudButton.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Hud/HudCounterButton.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Hud/HudSettingsButton.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Hud/HudIcon.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Hud/HudEditorReminder.lua", g_currentModDirectory)) -- fenêtre « Rappel éditeur » (bouton « ? » du HUD)
source(Utils.getFilename("scripts/Hud/DriveGoal.lua", g_currentModDirectory)) -- titre de l'ATH « Conduire - <but> »
source(Utils.getFilename("scripts/Hud/HudSpeedmeter.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Hud/PullDownList.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Hud/HudHarvesterInfo.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Hud/HudTextWrap.lua", g_currentModDirectory)) -- message du HUD trop large : 2 lignes
source(Utils.getFilename("scripts/Hud/HudAnchor.lua", g_currentModDirectory)) -- bas du HUD fixe, grandit vers le haut

source(Utils.getFilename("scripts/Events/GroupsEvent.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Events/UserDataEvent.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Events/UpdateSettingsEvent.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Events/RenameDriverEvent.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Events/UserConnectedEvent.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Events/ExperimentalFeaturesEvent.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Events/MessageEvent.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Events/InputEvent.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Events/HudInputEvent.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Events/AutonomousToolEvent.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Events/TrailerSwapEvent.lua", g_currentModDirectory)) -- dossier des places de l'échange de bennes
source(Utils.getFilename("scripts/Events/HeaderTractorEvent.lua", g_currentModDirectory)) -- véhicule de la remorque porte-barre
source(Utils.getFilename("scripts/Events/SiloCompactEvent.lua", g_currentModDirectory)) -- fenêtre « Tassage du silo » : réglages, Démarrer / Arrêter
source(Utils.getFilename("scripts/Events/LoaderEvent.lua", g_currentModDirectory)) -- (16/11) mode « Chargeur » : réglages du HUD
source(Utils.getFilename("scripts/Events/DebugSettingsEvent.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Events/StartStopEvent.lua", g_currentModDirectory))

source(Utils.getFilename("scripts/Events/Graph/CreateMapMarkerEvent.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Events/Graph/DeleteMapMarkerEvent.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Events/Graph/RenameMapMarkerEvent.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Events/Graph/ChangeMapMarkerGroupEvent.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Events/Graph/ToggleConnectionEvent.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Events/Graph/DeleteWayPointsEvent.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Events/Graph/CreateWayPointEvent.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Events/Graph/RecordWayPointEvent.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Events/Graph/MoveWayPointEvent.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Events/Graph/RoutesUploadEvent.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Events/Graph/SectionEvent.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Events/Graph/SetConnectionEvent.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Events/Graph/CreateSplineConnectionEvent.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Events/Graph/CreatePlaceableEvent.lua", g_currentModDirectory))

source(Utils.getFilename("scripts/Utils/AutoDriveTON.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Utils/TrailerUtil.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Utils/CombineUtil.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Utils/UtilFuncs.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Utils/UtilFuncsSmoothDrive.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Utils/Queue.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Utils/RingQueue.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Utils/Buffer.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Utils/FlaggedTable.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Utils/CollisionDetectionUtils.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Utils/PathFinderUtils.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Utils/Dubins.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Utils/AutoDriveUtilFuncs.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Utils/AutoDriveFoldGuard.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Utils/MotorStartWait.lua", g_currentModDirectory)) -- lancé moteur éteint : 5 s pour démarrer, « Démarre (5 s) » dans la fenêtre
source(Utils.getFilename("scripts/Utils/AutoDriveFoldGround.lua", g_currentModDirectory)) -- repli : points collés au sol (rampe) recalés même quand personne n'est près
source(Utils.getFilename("scripts/Utils/SortedQueue.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Utils/DevFuncs.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Utils/TrafficSplineUtils.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Utils/FieldPointGenerator.lua", g_currentModDirectory))

source(Utils.getFilename("scripts/Manager/RoutesManager.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Manager/DrawingManager.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Manager/ChaseDisplay.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Manager/MessagesManager.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Manager/GraphManager.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Manager/GraphManagerStart.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Manager/DirtRoadManager.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Manager/DirtRoadAccessZone.lua", g_currentModDirectory)) -- tertiaire près de la destination, raccourci une fois par passage, voir DirtRoadAccessZone.lua
source(Utils.getFilename("scripts/Manager/AccessRoadManager.lua", g_currentModDirectory)) -- 4e type « route d'accès », voir AccessRoadManager.lua
source(Utils.getFilename("scripts/Manager/AccessRoadStart.lua", g_currentModDirectory)) -- pas de départ sur une route d'accès, voir AccessRoadStart.lua
source(Utils.getFilename("scripts/Manager/RoadSpeedManager.lua", g_currentModDirectory)) -- vitesse par type de route (calcul et conduite), voir RoadSpeedManager.lua
source(Utils.getFilename("scripts/Manager/GateRegistry.lua", g_currentModDirectory)) -- portails et portes animés de la carte, voir GateRegistry.lua
source(Utils.getFilename("scripts/Manager/GateManager.lua", g_currentModDirectory)) -- portail fermé sur la route : ouvert puis refermé, voir GateManager.lua
source(Utils.getFilename("scripts/Manager/RoadTypesVehicles.lua", g_currentModDirectory)) -- routes secondaires / tertiaires par type de véhicule, voir RoadTypesVehicles.lua
source(Utils.getFilename("scripts/Manager/TriggerManager.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Manager/HarvestManager.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Manager/HarvestManagerChopperJob.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Manager/HarvestManagerCombineJob.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Manager/HarvestManagerQueue.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Manager/InputManager.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Manager/UserDataManager.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Manager/MultipleTargetsManager.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Manager/Scheduler.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Manager/UnloadManager.lua", g_currentModDirectory))

source(Utils.getFilename("scripts/Tasks/AbstractTask.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Tasks/DriveToDestinationTask.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Tasks/DriveToDestinationTaskArrival.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Tasks/DriveToDestinationTaskFieldEntrance.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Tasks/StopAndDisableADTask.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Tasks/DetachToolTask.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Tasks/FetchToolTask.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Tasks/FetchFrontToolTask.lua", g_currentModDirectory)) -- mode Autonome : attelage avant
source(Utils.getFilename("scripts/Tasks/FrontPlaceTask.lua", g_currentModDirectory)) -- mode Autonome : outil avant posé à côté
source(Utils.getFilename("scripts/Tasks/HeaderDropTask.lua", g_currentModDirectory)) -- mode Autonome : barre de coupe reposée sur sa remorque
source(Utils.getFilename("scripts/Tasks/HeaderBackInTask.lua", g_currentModDirectory)) -- mode Autonome : remorque porte-barre reculée dans l'entrée du champ
source(Utils.getFilename("scripts/Tasks/HeaderRoadBackTask.lua", g_currentModDirectory)) -- mode Autonome : remorque porte-barre reculée tout droit jusqu'à la route
source(Utils.getFilename("scripts/Tasks/HeaderGateTask.lua", g_currentModDirectory)) -- mode Autonome : moissonneuse rangée en face de l'entrée du champ, barre arrêtée devant elle
source(Utils.getFilename("scripts/Tasks/HeaderEnterTask.lua", g_currentModDirectory)) -- mode Autonome : barre prise, la moissonneuse avance droit jusqu'au bord du champ
source(Utils.getFilename("scripts/Tasks/BaleCollectTask.lua", g_currentModDirectory)) -- remorque à balles : ramassage des balles du champ
source(Utils.getFilename("scripts/Tasks/UnloadAtDestinationTask.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Tasks/UnloadAtDestinationRetry.lua", g_currentModDirectory)) -- point de livraison : relance quand la benne ne vide pas
source(Utils.getFilename("scripts/Tasks/LoadAtDestinationTask.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Tasks/RestartADTask.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Tasks/UnloadBGATask.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Tasks/DriveToVehicleTask.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Tasks/DriveToVehicleTaskFollow.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Tasks/DriveToVehicleTaskFieldPark.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Tasks/DriveToVehicleTaskTrack.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Tasks/EmptyHarvesterTask.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Tasks/WaitForCallTask.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Tasks/WaitForCallTaskFieldPark.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Tasks/WaitForCallTaskRoadside.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Tasks/ClearCropTask.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Tasks/CatchCombinePipeTask.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Tasks/CatchCombinePipeTaskClear.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Tasks/CatchCombinePipeTaskHandover.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Tasks/CatchCombinePipeTaskChopperRoute.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Tasks/CatchCombinePipeTaskChopperUTurn.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Tasks/FollowCombineTask.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Tasks/FollowCombineTaskChaseLine.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Tasks/FollowCombineTaskTurn.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Tasks/FollowCombineTaskChopperUTurn.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Tasks/FollowCombineTaskChopperDrive.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Tasks/FollowCombineTaskChopperPlace.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Tasks/FollowCombinePipeHold.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Tasks/FollowCombineCropGuard.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Tasks/RefuelTask.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Tasks/ExitFieldTask.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Tasks/ExitFieldTaskExitPoints.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Tasks/ExitFieldTaskStuck.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Tasks/FollowVehicleTask.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Tasks/StepAsideTask.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Tasks/ReverseFromBadLocationTask.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Tasks/CropBackTask.lua", g_currentModDirectory)) -- (16/11) benne de moissonneuse : recul sur son tracé, sortie de la culture debout après le déchargement
source(Utils.getFilename("scripts/Tasks/ParkTask.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Tasks/RepairTask.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Tasks/HandleHarvesterTurnTask.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Tasks/HandleHarvesterTurnTaskTurns.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Tasks/HandleHarvesterTurnTaskEndRow.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Tasks/HandleHarvesterTurnTaskHarvesterWay.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Tasks/HandleHarvesterTurnTaskReverseToPipe.lua", g_currentModDirectory))

source(Utils.getFilename("scripts/Modules/DrivePathModule.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modules/DrivePathModuleCurveSpeed.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modules/DrivePathModuleStuck.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modules/DrivePathModuleObstacles.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modules/CollisionDetectionModule.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modules/TrafficYieldModule.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modules/TrafficYieldModuleTrain.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modules/TrafficYieldModuleRoute.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modules/TrafficYieldModuleAnticipation.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modules/TrafficYieldModuleDeadlock.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modules/TrafficYieldModuleEarlyPlan.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modules/TrafficYieldModuleApproach.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modules/TrafficYieldModuleSingleTrack.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modules/TrafficYieldModuleDetour.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modules/TrafficYieldModuleSpot.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modules/TrafficYieldModuleObstacles.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modules/TrafficYieldModuleReverser.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modules/TrafficYieldModuleParker.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modules/IntersectionHold.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modules/IntersectionModule.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modules/IntersectionModuleZone.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modules/IntersectionModuleTraffic.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modules/ObstacleDetourQueue.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modules/ObstacleDetourEscape.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modules/ObstacleDetourModule.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modules/ApproachModule.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modules/ApproachModuleWidth.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modules/CornerModule.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modules/CornerModuleBends.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modules/CornerModuleEndRoute.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modules/CornerModuleEndManoeuvre.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modules/AvoidModule.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modules/AvoidModuleSensor.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modules/FieldParkModule.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modules/FieldParkModuleHarvester.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modules/FieldParkModuleMemo.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modules/FieldParkModuleSearch.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modules/FieldParkModulePath.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modules/FieldParkModuleEntrance.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modules/BandTurnModule.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modules/BandTurnModuleChopperSearch.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modules/BandTurnModuleDrive.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modules/BandRouteModule.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modules/BandTourModule.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modules/SpecialDrivingModule.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modules/TaskModule.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modules/TrailerModule.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modules/PathFinderModule.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modules/PathFinderModuleField.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modules/PathFinderModuleCropMap.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modules/PathFinderModuleFieldScan.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modules/PathFinderModuleCrop.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modules/PathFinderModuleObstacles.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modules/PathFinderModuleGrid.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modules/PathFinderModuleVerify.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modules/PathFinderModulePartial.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modules/PathFinderModuleGuided.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modules/PathFinderModuleEdge.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modules/PathFinderModulePark.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modules/PathFinderModuleRear.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modules/PathFinderModuleCorners.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modules/PathFinderModuleBand.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modules/PathFinderModuleLog.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modules/PathFinderModuleEntrance.lua", g_currentModDirectory)) -- (15/11) carré de 20 x 20 m à l'entrée du champ des bennes
source(Utils.getFilename("scripts/Modules/StateModule.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modules/StateModuleAutonomous.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modules/StateModuleFront.lua", g_currentModDirectory)) -- mode Autonome : attelage avant
source(Utils.getFilename("scripts/Modules/StateModuleFieldClear.lua", g_currentModDirectory)) -- mode Autonome : « Champ : aucun » une fois garé
source(Utils.getFilename("scripts/Modules/StateModuleTrailer.lua", g_currentModDirectory)) -- remorque des modes avec benne
source(Utils.getFilename("scripts/Modules/StateModuleHeader.lua", g_currentModDirectory)) -- véhicule de la remorque porte-barre (moissonneuse)
source(Utils.getFilename("scripts/Modules/RecordingModule.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modules/TrainModule.lua", g_currentModDirectory))

source(Utils.getFilename("scripts/Modes/AbstractMode.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modes/DriveToMode.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modes/UnloadAtMode.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modes/PickupAndDeliverMode.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Manager/SavegameResume.lua", g_currentModDirectory)) -- chargement de la partie : « Collecter et livrer » reprend, réseau caché
source(Utils.getFilename("scripts/Modes/LoadMode.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modes/BGAMode.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modes/CombineUnloaderMode.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modes/CombineUnloaderModeJobDone.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modes/CombineUnloaderModeBlocked.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modes/CombineUnloaderModeQueue.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modes/CombineUnloaderModeFillNode.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modes/CombineUnloaderModeTracks.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modes/CombineUnloaderModeCourseplay.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modes/CombineUnloaderModeChopperChase.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modes/CombineUnloaderModeCutLine.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modes/AutonomousMode.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modes/AutonomousFront.lua", g_currentModDirectory)) -- mode Autonome : attelage avant (outils frontaux, masses)
source(Utils.getFilename("scripts/Modes/AutonomousNoseIn.lua", g_currentModDirectory)) -- mode Autonome : entrée le nez en avant dans une place prise en marche arrière
source(Utils.getFilename("scripts/Modes/AutonomousParkButton.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Manager/AutonomousManager.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Manager/AutonomousManagerFields.lua", g_currentModDirectory)) -- mode Autonome : champs, ouvrier du jeu
source(Utils.getFilename("scripts/Manager/AutonomousManagerTools.lua", g_currentModDirectory)) -- mode Autonome : outil attelé, outil à atteler
source(Utils.getFilename("scripts/Manager/AutonomousManagerFront.lua", g_currentModDirectory)) -- mode Autonome : attelage avant (outils frontaux, masses)
source(Utils.getFilename("scripts/Manager/AutonomousManagerCourses.lua", g_currentModDirectory)) -- mode Autonome : parcours enregistrés de Courseplay
source(Utils.getFilename("scripts/Manager/SeederManager.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Manager/MassZoneManager.lua", g_currentModDirectory)) -- (17/11) zone des masses : carré au sol après une destination
source(Utils.getFilename("scripts/Manager/BalerManager.lua", g_currentModDirectory)) -- presse : presse attelée, andains, ficelle / filet
source(Utils.getFilename("scripts/Modes/AutonomousRefill.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Modes/AutonomousBalerRefill.lua", g_currentModDirectory)) -- (15/11) presse : recharge de la ficelle / du filet par le plein du semoir
source(Utils.getFilename("scripts/Manager/SprayerManager.lua", g_currentModDirectory)) -- épandeurs et pulvés en Autonome, voir SprayerManager.lua
source(Utils.getFilename("scripts/Modes/AutonomousHeader.lua", g_currentModDirectory)) -- mode Autonome : moissonneuse équipée seule (remorque porte-barre)
source(Utils.getFilename("scripts/Modes/AutonomousHeaderMount.lua", g_currentModDirectory)) -- place de la barre de coupe sur sa remorque porte-barre
source(Utils.getFilename("scripts/Modes/AutonomousHeaderTractor.lua", g_currentModDirectory)) -- tracteur de la remorque porte-barre, roue dentée de la moissonneuse
source(Utils.getFilename("scripts/Modes/AutonomousHeaderSpot.lua", g_currentModDirectory)) -- remorque porte-barre : arrêt au départ, côté de la barre dégagé
source(Utils.getFilename("scripts/Modes/AutonomousHeaderCollect.lua", g_currentModDirectory)) -- fin de champ : la remorque porte-barre vient à la moissonneuse, jamais de route avec la barre
source(Utils.getFilename("scripts/Modes/AutonomousHeaderFollow.lua", g_currentModDirectory)) -- la moissonneuse suit la remorque, s'arrête avant le chemin du champ
source(Utils.getFilename("scripts/Modes/AutonomousHeaderBackIn.lua", g_currentModDirectory)) -- remorque porte-barre reculée en biais dans l'entrée du champ
source(Utils.getFilename("scripts/Modes/AutonomousHeaderCross.lua", g_currentModDirectory)) -- (16/11) champ fermé (muret) : remorque porte-barre reculée en travers du chemin, côté herbe
source(Utils.getFilename("scripts/Modes/AutonomousHeaderClear.lua", g_currentModDirectory)) -- barre prise : le tracteur dégage d'abord, la moissonneuse repart ensuite
source(Utils.getFilename("scripts/Modes/AutonomousHeaderParkButton.lua", g_currentModDirectory)) -- bouton parking, moissonneuse avec sa barre : la barre d'abord sur sa remorque
source(Utils.getFilename("scripts/Modes/AutonomousHeaderChoice.lua", g_currentModDirectory)) -- barre choisie ou selon la culture, changement de barre
source(Utils.getFilename("scripts/Modes/AutonomousMassAuto.lua", g_currentModDirectory)) -- (17/11) « Masse auto » : masse avant selon le poids de l'outil
source(Utils.getFilename("scripts/Modes/AutonomousHeaderGround.lua", g_currentModDirectory)) -- barre sans remorque (coupe à maïs) : posée par la moissonneuse
source(Utils.getFilename("scripts/Modes/AutonomousHeaderEntry.lua", g_currentModDirectory)) -- barre prise : entrée directe dans le champ, jamais de route trop étroite pour la barre
source(Utils.getFilename("scripts/Modes/AutonomousHeaderNextField.lua", g_currentModDirectory)) -- (16/11) champ suivant : la remorque porte-barre change de champ avec la moissonneuse
source(Utils.getFilename("scripts/Modes/AutonomousHeaderLeave.lua", g_currentModDirectory)) -- (17/11) une moissonneuse ne quitte jamais un champ avec la coupe montée
source(Utils.getFilename("scripts/Modes/AutonomousHeaderRoadBack.lua", g_currentModDirectory)) -- remorque porte-barre reculée tout droit jusqu'à la route, barre prise au croisement
source(Utils.getFilename("scripts/Modes/AutonomousHeaderYard.lua", g_currentModDirectory)) -- remorque porte-barre posée hors de la route près du bout quand rien ne va le long de la route
source(Utils.getFilename("scripts/Modes/AutonomousHeaderReturn.lua", g_currentModDirectory)) -- fin de champ : moissonneuse et remorque porte-barre gardent leur écart sur la route du retour
source(Utils.getFilename("scripts/Modes/AutonomousHeaderGate.lua", g_currentModDirectory)) -- la moissonneuse attend en face de l'entrée du champ, la barre est arrêtée devant elle
source(Utils.getFilename("scripts/Modes/AutonomousHeaderStuck.lua", g_currentModDirectory)) -- (16/11) tracteur de la remorque porte-barre bloqué par un objet fixe : endroit suivant, jamais d'attente sans fin
source(Utils.getFilename("scripts/Modes/AutonomousHeaderFieldLead.lua", g_currentModDirectory)) -- (17/11) barre posée dans le champ, amenée au champ suivant : la plus près de la sortie part la première
source(Utils.getFilename("scripts/Modes/AutonomousHeaderHookup.lua", g_currentModDirectory)) -- gestes du chauffeur : brancher la barre, la verrouiller sur sa remorque
source(Utils.getFilename("scripts/Modes/AutonomousHarvesterUnloaders.lua", g_currentModDirectory)) -- bennes qui suivent le champ de la moissonneuse
source(Utils.getFilename("scripts/Modes/AutonomousUnloaderAutoPick.lua", g_currentModDirectory)) -- (16/11) machine au travail sans benne : tracteurs et remorques choisis et envoyés au champ
source(Utils.getFilename("scripts/Hud/HudHarvester.lua", g_currentModDirectory)) -- HUD Autonome moissonneuse / ensileuse : Champ, Barre, Champ suivant, Barre suivante
source(Utils.getFilename("scripts/Hud/HudSilo.lua", g_currentModDirectory)) -- (16/11) HUD du mode « Tassage » : lignes Silo et Attente
source(Utils.getFilename("scripts/Hud/HudLoader.lua", g_currentModDirectory)) -- (16/11) HUD du mode « Chargeur » : Prendre, Vider, Outil, Quantité
source(Utils.getFilename("scripts/Modes/SprayerRestReturn.lua", g_currentModDirectory)) -- épandeurs : reste rendu à la zone de plein ou vendu, jamais en big bags
source(Utils.getFilename("scripts/Modes/AutonomousSprayerDump.lua", g_currentModDirectory)) -- épandeurs : vider le reste (fin de champ, bouton parking)
source(Utils.getFilename("scripts/Manager/RefillSources.lua", g_currentModDirectory)) -- zones de plein filtrées selon le produit
source(Utils.getFilename("scripts/Manager/BaleLoaderManager.lua", g_currentModDirectory)) -- remorque à balles en Autonome : réglages, balles du champ
source(Utils.getFilename("scripts/Manager/BaleWrapperManager.lua", g_currentModDirectory)) -- enrubanneuse en Autonome : bras, film, recharge du film
source(Utils.getFilename("scripts/Modes/AutonomousBales.lua", g_currentModDirectory)) -- remorque à balles : dépôt, retour, fin de champ
source(Utils.getFilename("scripts/Manager/WindrowScan.lua", g_currentModDirectory)) -- (15/11) presse : recherche des andains au sol
source(Utils.getFilename("scripts/Manager/BalerControl.lua", g_currentModDirectory)) -- (15/11) presse : mise au travail, vitesse, arrêts (balle, enrubannage), ficelle
source(Utils.getFilename("scripts/Tasks/WindrowBaleTask.lua", g_currentModDirectory)) -- (15/11) presse : tâche qui presse les andains, sans Courseplay
source(Utils.getFilename("scripts/Modes/AutonomousWindrow.lua", g_currentModDirectory)) -- (15/11) presse en Autonome : arrivée, recherche, pressage, recharge, fin de champ
source(Utils.getFilename("scripts/Modes/AutonomousFuel.lua", g_currentModDirectory)) -- plein de carburant : Courseplay à sec, avant le champ suivant
source(Utils.getFilename("scripts/Modes/TrailerHitch.lua", g_currentModDirectory)) -- modes avec benne : remorque à atteler, reposée à sa place
source(Utils.getFilename("scripts/Hud/HudLoadPoint.lua", g_currentModDirectory)) -- chargement : produits du point de chargement, remorque adaptée
source(Utils.getFilename("scripts/Modes/TrailerSwap.lua", g_currentModDirectory)) -- échange de bennes à la livraison
source(Utils.getFilename("scripts/Modes/AutonomousParkUnload.lua", g_currentModDirectory)) -- bouton parking : benne pas vide, vidée d'abord
source(Utils.getFilename("scripts/Modes/AutonomousFieldExit.lua", g_currentModDirectory)) -- mode Autonome : départ depuis un champ, sortie par l'entrée du champ d'abord (enveloppe les tâches de route)

source(Utils.getFilename("scripts/Sensors/VirtualSensors.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Sensors/CollSensor.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Sensors/CollSensorSplit.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Sensors/FruitSensor.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Sensors/FieldSensor.lua", g_currentModDirectory))

source(Utils.getFilename("scripts/Gui/RoutesManagerGUI.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Gui/NotificationsHistoryGUI.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Gui/ColorSettingsGUI.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Gui/EnterDriverNameGUI.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Gui/EnterGroupNameGUI.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Gui/EnterTargetNameGUI.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Gui/ScanConfirmationGUI.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Gui/AutonomousCoursesGUI.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Gui/SeederSettingsGUI.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Gui/SprayerSettingsGUI.lua", g_currentModDirectory)) -- fenêtre de l'épandeur, voir SprayerSettingsGUI.lua
source(Utils.getFilename("scripts/Gui/BaleLoaderSettingsGUI.lua", g_currentModDirectory)) -- fenêtre de la remorque à balles, voir BaleLoaderSettingsGUI.lua
source(Utils.getFilename("scripts/Gui/BalerSettingsGUI.lua", g_currentModDirectory)) -- (15/11) fenêtre de la presse, voir BalerSettingsGUI.lua
source(Utils.getFilename("scripts/Gui/TrailerSwapGUI.lua", g_currentModDirectory)) -- fenêtre « Échange de bennes », voir TrailerSwapGUI.lua
source(Utils.getFilename("scripts/Gui/HeaderTractorGUI.lua", g_currentModDirectory)) -- fenêtre « Transport de la barre », voir HeaderTractorGUI.lua
source(Utils.getFilename("scripts/Gui/SiloCompactGUI.lua", g_currentModDirectory)) -- (16/11) fenêtre « Tassage du silo », voir SiloCompactGUI.lua

source(Utils.getFilename("scripts/Gui/EnterDestinationFilterGUI.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Gui/SettingsPage.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Manager/TireChangeManager.lua", g_currentModDirectory)) -- pneus changés automatiquement (usure d'AutoSwitch)
source(Utils.getFilename("scripts/Utils/RootHarvester.lua", g_currentModDirectory)) -- bennes des arracheuses : côté de la goulotte, sortie du champ, file du calcul
source(Utils.getFilename("scripts/Utils/TrailerCoverField.lua", g_currentModDirectory)) -- bâche des remorques : ouverte à l'entrée du champ, fermée à la sortie (15/11 : tous les modes)
source(Utils.getFilename("scripts/Modes/AutonomousYardZone.lua", g_currentModDirectory)) -- mode Autonome : un seul tracteur à la fois dans la zone d'une place d'outils
source(Utils.getFilename("scripts/Modes/SiloCompactor.lua", g_currentModDirectory)) -- silo couloir : bennes réparties sur la largeur, tracteur tasseur, silo fermé respecté
source(Utils.getFilename("scripts/Modes/SiloCompactorTask.lua", g_currentModDirectory)) -- (16/11) tasseur : fenêtre « Tassage », lame et rouleau, silo à fond ou traversant
source(Utils.getFilename("scripts/Modes/SiloCompactMode.lua", g_currentModDirectory)) -- (16/11) mode « Tassage » : outils avant/arrière attelés, tassage autonome, retour des outils et garage
source(Utils.getFilename("scripts/Modes/LoaderJob.lua", g_currentModDirectory)) -- (16/11) mode « Chargeur » : sources (silos, tas), points de vidage, réglages
source(Utils.getFilename("scripts/Tasks/LoaderTask.lua", g_currentModDirectory)) -- (16/11) mode « Chargeur » : prendre et vider (fils de UnloadBGATask)
source(Utils.getFilename("scripts/Modes/LoaderMode.lua", g_currentModDirectory)) -- (16/11) mode « Chargeur » : godet à atteler, trajets par la route, fin et garage
source(Utils.getFilename("scripts/Manager/GraphManagerGrid.lua", g_currentModDirectory)) -- points du réseau par cases de 100 m : point le plus proche sans parcourir tout le réseau
source(Utils.getFilename("scripts/Utils/FarmPilotPerf.lua", g_currentModDirectory)) -- commande console fpPerf : temps pris par FarmPilot dans log.txt
source(Utils.getFilename("scripts/Modes/AutonomousResumeReturn.lua", g_currentModDirectory)) -- mode Autonome : le retour au garage reprend après le chargement de la partie et après la relance d'AutoDrive
source(Utils.getFilename("scripts/Modes/AutonomousResumeStage.lua", g_currentModDirectory)) -- mode Autonome : au chargement de la partie, chaque véhicule reprend exactement son étape (balles, plein, reste, changement d'outil)
source(Utils.getFilename("scripts/Modes/AutonomousResumeHeader.lua", g_currentModDirectory)) -- mode Autonome : au chargement de la partie, la moissonneuse équipée seule, le tracteur de sa remorque porte-barre et les bennes de moissonneuse reprennent exactement leur étape
source(Utils.getFilename("scripts/Modes/CombineUnloaderJobDoneGuard.lua", g_currentModDirectory)) -- benne en fin de chantier : la fin de chantier n'est plus oubliée en route (vider puis parking, jamais d'attente d'appel)
source(Utils.getFilename("scripts/Modes/AutonomousResumeButton.lua", g_currentModDirectory)) -- bouton Marche/Arrêt : le départ suivant reprend là où c'était ; clic droit : reprendre au début
source(Utils.getFilename("scripts/Gui/DebugSettingsPage.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Gui/Settings.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Gui/RoadTypesGUI.lua", g_currentModDirectory)) -- fenêtre « types de véhicules » des routes, voir RoadTypesGUI.lua

source(Utils.getFilename("scripts/Tasks/Turns/AbstractTurn.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Tasks/Turns/ReverseOffsetTurn.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Tasks/Turns/OffsetTurn.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Tasks/Turns/ForwardOffsetTurn.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Tasks/Turns/YTurn.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Tasks/Turns/SquareTurn.lua", g_currentModDirectory))

-- fonctions de l'ancien AutoDrive Addon
source(Utils.getFilename("scripts/Addon/AutoDriveAddon.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Addon/LightsOff.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Addon/TurnLights.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Addon/TurnLightsOtherMods.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Addon/TurnLightsBends.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Addon/TurnLightsJunctions.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Addon/EngineStop.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Addon/Weighing.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Addon/SiloEmpty.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Addon/RearTool.lua", g_currentModDirectory))

AutoDriveRegister = {}
AutoDriveRegister.version = g_modManager:getModByName(g_currentModName).version

if AutoDrive.ADSpecName == nil then
    AutoDrive.ADSpecName = g_currentModName .. ".AutoDrive"
end

if g_specializationManager:getSpecializationByName("AutoDrive") == nil then
    g_specializationManager:addSpecialization("AutoDrive", "AutoDrive", Utils.getFilename("scripts/AutoDrive.lua", g_currentModDirectory), nil)
end

function AutoDriveRegister.registerAutoDrive()

    if AutoDrive == nil then
        Logging.error("[AD] Unable to add specialization 'AutoDrive'")
        return
    end

    for vehicleType, typeDef in pairs(g_vehicleTypeManager.types) do
        if typeDef ~= nil and vehicleType ~= "horse" and (not typeDef.hasADSpec == true) then
            if AutoDrive.prerequisitesPresent(typeDef.specializations) then
                --Logging.info('[AD] Attached to vehicleType "%s"', vehicleType)
                if typeDef.specializationsByName[AutoDrive.ADSpecName] == nil then
                    g_vehicleTypeManager:addSpecialization(vehicleType, AutoDrive.ADSpecName)
                    typeDef.hasADSpec = true
                end
            end
        end
    end
end

if AutoDrive.ADVDSpecName == nil then
    AutoDrive.ADVDSpecName = g_currentModName .. ".AutoDriveVehicleData"
end

if g_specializationManager:getSpecializationByName("AutoDriveVehicleData") == nil then
	g_specializationManager:addSpecialization("AutoDriveVehicleData", "AutoDriveVehicleData", Utils.getFilename("scripts/Utils/AutoDriveVehicleData.lua", g_currentModDirectory), nil)
end

function AutoDriveRegister.registerVehicleData()

	if AutoDriveVehicleData == nil then
		Logging.error("[AutoDriveVehicleData] Unable to add specialization 'AutoDriveVehicleData'")
		return
	end

	for vehicleType, typeDef in pairs(g_vehicleTypeManager.types) do
		if typeDef ~= nil and vehicleType ~= "horse" and (not typeDef.hasADVDSpec == true) then
			if AutoDriveVehicleData.prerequisitesPresent(typeDef.specializations) then
				if typeDef.specializationsByName[AutoDrive.ADVDSpecName] == nil then
					g_vehicleTypeManager:addSpecialization(vehicleType, AutoDrive.ADVDSpecName)
					typeDef.hasADVDSpec = true
				end
			end
		end
	end
end

if AutoDrive.ADPDSpecName == nil then
    AutoDrive.ADPDSpecName = g_currentModName .. ".AutoDrivePlaceableData"
end

if g_placeableSpecializationManager:getSpecializationByName("AutoDrivePlaceableData") == nil then
	g_placeableSpecializationManager:addSpecialization("AutoDrivePlaceableData", "AutoDrivePlaceableData", Utils.getFilename("scripts/Utils/AutoDrivePlaceableData.lua", g_currentModDirectory), nil)
end

function AutoDriveRegister.registerPlaceableData()

	if AutoDriveVehicleData == nil then
		Logging.error("[AutoDriveVehicleData] Unable to add specialization 'AutoDriveVehicleData'")
		return
	end

    local validPlaceableTypes =
    {
        "baseHusbandry",
        "beehive",
        "beehivePalletSpawner",
        "bunkerSilo",
        "buyingStation",
        "buyingStationManure",
        "chargingStation",
        "chickenHusbandry",
        "constructible",
        "constructibleFarmhouse",
        "cowHusbandry",
        "cowHusbandryBarn",
        "cowHusbandryBarnMilk",
        "cowHusbandryBarnMilkFeedingRobot",
        "cowHusbandryPasture",
        "cowHusbandryPastureStraw",
        "decoObject",
        "destructible",
        "factory",
        "farmhouse",
        "garageSolarPanels",
        "garageWorkshop",
        "garageWorkshopSolarPanels",
        "greenhouse",
        "heapSpawner",
        "horseHusbandry",
        "horseHusbandryPasture",
        "manureHeap",
        "objectStorage",
        "pigHusbandry",
        "pigHusbandryPasture",
        "productionPoint",
        "sellingStation",
        "sheepHusbandry",
        "silo",
        "siloExtension",
        "simplePlaceable",
        "toolShed",
        "warehouse",
        "weighingStation",
        "workshop"
    }

    local count = 0
	for placeableType, typeDef in pairs(g_placeableTypeManager.types) do
        for _, validPlaceableType in pairs(validPlaceableTypes) do
            if placeableType == validPlaceableType and (not typeDef.hasADPDpec == true) then
                if AutoDrivePlaceableData.prerequisitesPresent(typeDef.specializations) then
                    if typeDef.specializationsByName[AutoDrive.ADPDSpecName] == nil then
                        g_placeableTypeManager:addSpecialization(placeableType, AutoDrive.ADPDSpecName)
                        typeDef.hasADPDpec = true
                        count = count + 1
                        break
                    end
                end
            end
        end
    end
    Logging.info("AutoDrive registered %d placeable Types.", count)
end

-- We need this for network debug functions
EventIds.eventIdToName = {}

for eName, eId in pairs(EventIds) do
	if string.sub(eName, 1, 6) == "EVENT_" then
		EventIds.eventIdToName[eId] = eName
	end
end

function AutoDriveRegister:loadMap(name)
	Logging.info("[AutoDrive] Loaded mod version %s (by Stephan). Full version number: %s", self.version, AutoDrive.version)
end

function AutoDriveRegister:deleteMap()
end

function AutoDriveRegister:keyEvent(unicode, sym, modifier, isDown)
end

function AutoDriveRegister:mouseEvent(posX, posY, isDown, isUp, button)
end

function AutoDriveRegister:update(dt)
    -- FarmPilot : prévient le joueur une fois que la partie tourne
    if AutoDriveRegister.originalDisabled and not AutoDriveRegister.originalDisabledShown and g_currentMission ~= nil and g_currentMission.isRunning then
        AutoDriveRegister.originalDisabledShown = true
        FarmPilotCall(function()
            g_currentMission:showBlinkingWarning("FarmPilot : AutoDrive désactivé, retirez FS25_AutoDrive de vos mods / AutoDrive disabled, remove FS25_AutoDrive from your mods", 10000)
        end)
    end
end

function AutoDriveRegister:draw()
end

--Knowledge to register translations in l10n space and to use the helpLineManager taken from the Seasons mod (Thank you!)
function AutoDriveRegister.onMissionWillLoad(i18n)
	AutoDriveRegister.addModTranslations(i18n)
end

function AutoDriveValidateVehicleTypes(TypeManager)
	AutoDriveRegister.onMissionWillLoad(g_i18n)
end

---Copy our translations to global space.
function AutoDriveRegister.addModTranslations(i18n)
	-- We can copy all our translations to the global table because we prefix everything with ad_ or have unique names with 'AD' in it.
	-- The mod-based l10n lookup only really works for vehicles, not UI and script mods.
	local global = getfenv(0).g_i18n.texts

	for key, text in pairs(i18n.texts) do
		global[key] = text
	end
end

function AutoDriveLoadedMission(mission, superFunc, node)
	superFunc(mission, node)

	if mission.cancelLoading then
		return
	end
end

-- FarmPilot : débranche le mod AutoDrive d'origine (voir check)
local function removeTypeSpec(manager, specName, flagName)
    if manager == nil or manager.types == nil then
        return 0
    end
    local count = 0
    for _, typeDef in pairs(manager.types) do
        if typeDef.specializationsByName ~= nil and typeDef.specializationsByName[specName] ~= nil then
            local spec = typeDef.specializationsByName[specName]
            typeDef.specializationsByName[specName] = nil
            for i = #typeDef.specializationNames, 1, -1 do
                if typeDef.specializationNames[i] == specName then
                    table.remove(typeDef.specializationNames, i)
                end
            end
            for i = #typeDef.specializations, 1, -1 do
                if typeDef.specializations[i] == spec then
                    table.remove(typeDef.specializations, i)
                end
            end
            typeDef[flagName] = nil
            count = count + 1
        end
    end
    return count
end

function AutoDriveRegister.disableOriginalAutoDrive()
    local vehicleTypes = removeTypeSpec(g_vehicleTypeManager, "FS25_AutoDrive.AutoDrive", "hasADSpec")
    removeTypeSpec(g_vehicleTypeManager, "FS25_AutoDrive.AutoDriveVehicleData", "hasADVDSpec")
    removeTypeSpec(g_placeableTypeManager, "FS25_AutoDrive.AutoDrivePlaceableData", "hasADPDpec")

    -- écouteurs AutoDrive et AutoDriveRegister du mod d'origine (reconnus par leur nom de spécialisation)
    local removed = 0
    local listeners = g_modEventListeners
    if type(listeners) == "table" then
        for i = #listeners, 1, -1 do
            local l = listeners[i]
            if type(l) == "table" and l ~= AutoDrive and l ~= AutoDriveRegister
                and (l.ADSpecName == "FS25_AutoDrive.AutoDrive"
                    or (type(l.registerAutoDrive) == "function" and type(l.registerVehicleData) == "function")) then
                table.remove(listeners, i)
                removed = removed + 1
            end
        end
    end

    -- les autres mods qui cherchent FS25_AutoDrive trouvent FarmPilot
    FarmPilotCall(function()
        if _G[g_currentModName] ~= nil then
            _G["FS25_AutoDrive"] = _G[g_currentModName]
        end
    end)

    -- textes : ceux d'AutoDrive sont recopiés après les nôtres, on remet les nôtres en dernier
    TypeManager.validateTypes = Utils.appendedFunction(TypeManager.validateTypes, function()
        AutoDriveRegister.addModTranslations(g_i18n)
    end)

    AutoDriveRegister.originalDisabled = true
end

local function check()
    if AutoDrive == nil then
        Logging.error("[AD] AutoDriveRegister.check Unable to add specialization 'AutoDrive'")
        return
    end

    -- FarmPilot : AutoDrive d'origine aussi activé -> FarmPilot le débranche et marche seul.
    -- Le jeu charge FS25_AutoDrive avant FS25_FarmPilot : on retire ce qu'il a déjà posé
    -- (ses spécialisations sur les types de véhicules et de bâtiments, ses écouteurs du jeu).
    -- Ses crochets du jeu sont posés dans son loadMap, qui ne sera donc jamais appelé.
    if g_modIsLoaded ~= nil and g_modIsLoaded["FS25_AutoDrive"] == true then
        AutoDriveRegister.disableOriginalAutoDrive()
    end

    if g_currentModName then
        if g_currentModName == "FS25_FarmPilot" then
            if AutoDrive.currentModName == nil then
                AutoDrive.currentModName = g_currentModName

                -- Mission00.loadMission00Finished = Utils.overwrittenFunction(Mission00.loadMission00Finished, AutoDriveLoadedMission)
                TypeManager.validateTypes = Utils.prependedFunction(TypeManager.validateTypes, AutoDriveValidateVehicleTypes)
                addModEventListener(AutoDriveRegister)
                addModEventListener(AutoDrive)
                -- FarmPilot : les autres mods (Courseplay, addons...) cherchent AutoDrive sous FS25_AutoDrive
                FarmPilotCall(function()
                    if _G["FS25_AutoDrive"] == nil and _G[g_currentModName] ~= nil then
                        _G["FS25_AutoDrive"] = _G[g_currentModName]
                    end
                end)
                -- first iteration to register AD to vehicle types
                AutoDriveRegister.registerAutoDrive()
                AutoDriveRegister.registerVehicleData()
                AutoDriveRegister.registerPlaceableData()
            end
        else
            Logging.error("[AD] ERROR: AutoDriveRegister.check g_currentModName %s", tostring(g_currentModName))
            local args = {text = "FarmPilot: Wrong mod file name / Mauvais nom de fichier " .. g_currentModName .. " <--> FS25_FarmPilot"}
            local dialog = g_gui:showDialog("InfoDialog")
            if dialog then
                dialog.target:setDialogType(Utils.getNoNil(args.dialogType, DialogElement.TYPE_WARNING))
                dialog.target:setText(args.text)
                dialog.target:setCallback(args.callback, args.target, args.args)
                dialog.target:setButtonTexts(args.okText)
                dialog.target:setButtonAction(args.buttonAction)
            end
            return
        end
    end
end

check()