--[[
This file is part of Courseplay (https://github.com/Courseplay/courseplay)
Copyright (C) 2019-2021 Peter Vaiko

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.
]]

---@class AIDriveStrategyCombineCourse : AIDriveStrategyFieldWorkCourse
AIDriveStrategyCombineCourse = {}
local AIDriveStrategyCombineCourse_mt = Class(AIDriveStrategyCombineCourse, AIDriveStrategyFieldWorkCourse)

-- fill level when we start making a pocket to unload if we are on the outermost headland
AIDriveStrategyCombineCourse.pocketFillLevelFullPercentage = 95
AIDriveStrategyCombineCourse.safeUnloadDistanceBeforeEndOfRow = 30
-- when fill level is above this threshold, don't start the next row if the pipe would be
-- in the fruit
AIDriveStrategyCombineCourse.waitForUnloadAtEndOfRowFillLevelThreshold = 95

AIDriveStrategyCombineCourse.myStates = {
    -- main states
    UNLOADING_ON_FIELD = {},
    -- unload sub-states
    STOPPING_FOR_UNLOAD = {},
    WAITING_FOR_UNLOAD_ON_FIELD = {},
    PULLING_BACK_FOR_UNLOAD = {},
    WAITING_FOR_UNLOAD_AFTER_PULLED_BACK = {},
    RETURNING_FROM_PULL_BACK = {},
    REVERSING_TO_MAKE_A_POCKET = {},
    MAKING_POCKET = {},
    WAITING_FOR_UNLOAD_IN_POCKET = {},
    WAITING_FOR_UNLOAD_BEFORE_STARTING_NEXT_ROW = {},
    UNLOADING_BEFORE_STARTING_NEXT_ROW = {},
    WAITING_FOR_UNLOAD_AFTER_FIELDWORK_ENDED = {},
    WAITING_FOR_UNLOADER_TO_LEAVE = {},
    RETURNING_FROM_POCKET = {},
    DRIVING_TO_SELF_UNLOAD = {},
    SELF_UNLOADING = {},
    SELF_UNLOADING_WAITING_FOR_DISCHARGE = {},
    DRIVING_TO_SELF_UNLOAD_AFTER_FIELDWORK_ENDED = {},
    SELF_UNLOADING_AFTER_FIELDWORK_ENDED = {},
    SELF_UNLOADING_AFTER_FIELDWORK_ENDED_WAITING_FOR_DISCHARGE = {},
    RETURNING_FROM_SELF_UNLOAD = {}
}

-- stop limit we use for self unload to approach the trailer
AIDriveStrategyCombineCourse.proximityStopThresholdSelfUnload = 0.1

-- Developer hack: to check the class of an object one should use the is_a() defined in CpObject.lua.
-- However, when we reload classes on the fly during the development, the is_a() calls in other modules still
-- have the old class definition (for example CombineUnloadManager.lua) of this class and thus, is_a() fails.
-- Therefore, use this instead, this is safe after a reload.
AIDriveStrategyCombineCourse.isAAIDriveStrategyCombineCourse = true

function AIDriveStrategyCombineCourse.new(customMt)
    if customMt == nil then
        customMt = AIDriveStrategyCombineCourse_mt
    end
    local self = AIDriveStrategyFieldWorkCourse.new(customMt)
    AIDriveStrategyFieldWorkCourse.initStates(self, AIDriveStrategyCombineCourse.myStates)
    self.fruitLeft, self.fruitRight = 0, 0
    self.litersPerMeter = 0
    self.litersPerSecond = 0
    self.fillLevelAtLastWaypoint = 0
    self.beaconLightsActive = false
    self.stopDisabledAfterEmpty = CpTemporaryObject(false)
    self.stopDisabledAfterEmpty:set(false, 1)
    self:initUnloadStates()
    self.chopperCanDischarge = CpTemporaryObject(false)
    -- hold the harvester temporarily
    self.temporaryHold = CpTemporaryObject(false)
    -- periodically check if we need to call an unloader
    self.timeToCallUnloader = CpTemporaryObject(true)

    --- Register info texts
    self:registerInfoTextForStates(self:getFillLevelInfoText(), {
        states = {
            [self.states.UNLOADING_ON_FIELD] = true
        },
        unloadStates = {
            [self.states.WAITING_FOR_UNLOAD_ON_FIELD] = true,
            [self.states.WAITING_FOR_UNLOAD_AFTER_FIELDWORK_ENDED] = true,
            [self.states.WAITING_FOR_UNLOAD_AFTER_PULLED_BACK] = true,
            [self.states.WAITING_FOR_UNLOAD_IN_POCKET] = true
        }
    })

    -- TODO: move this to a setting
    self.callUnloaderAtFillLevelPercentage = 80
    return self
end

function AIDriveStrategyCombineCourse:getStateAsString()
    local s = self.state.name
    if self.state == self.states.UNLOADING_ON_FIELD then
        s = s .. '/' .. self.unloadState.name
    end
    return s
end

-----------------------------------------------------------------------------------------------------------------------
--- Initialization
-----------------------------------------------------------------------------------------------------------------------
function AIDriveStrategyCombineCourse:setAllStaticParameters()
    AIDriveStrategyCombineCourse.superClass().setAllStaticParameters(self)
    self:debug('AIDriveStrategyCombineCourse set')

    if self:isChopper() then
        self:debug('This is a chopper.')
    end

    self:checkMarkers()
    self:measureBackDistance()
    Markers.setMarkerNodes(self.vehicle, self.measuredBackDistance)

    self.proximityController:registerBlockingVehicleListener(self, AIDriveStrategyCombineCourse.onBlockingVehicle)

    -- distance to keep to the right (>0) or left (<0) when pulling back to make room for the tractor
    self.pullBackRightSideOffset = math.abs(self.pipeController:getPipeOffsetX()) - self:getWorkWidth() / 2 + 5
    self.pullBackRightSideOffset = self:isPipeOnLeft() and self.pullBackRightSideOffset or -self.pullBackRightSideOffset
    -- should be at pullBackRightSideOffset to the right or left at pullBackDistanceStart
    self.pullBackDistanceStart = 2 * AIUtil.getTurningRadius(self.vehicle)
    -- and back up another bit
    self.pullBackDistanceEnd = self.pullBackDistanceStart + 5
    -- when making a pocket, how far to back up before changing to forward
    self.pocketReverseDistance = 20
    -- register ourselves at our boss
    -- TODO_22 g_combineUnloadManager:addCombineToList(self.vehicle, self)
    self:measureBackDistance()
    self.waitingForUnloaderAtEndOfRow = CpTemporaryObject()
    --- My unloader. This expires in a few seconds, so unloaders have to renew their registration periodically
    ---@type CpTemporaryObject
    self.unloader = CpTemporaryObject(nil)
    --- if this is not nil, we have a pending rendezvous with our unloader
    ---@type CpTemporaryObject
    self.unloaderToRendezvous = CpTemporaryObject(nil)
    local total, pipeInFruit = self.vehicle:getFieldWorkCourse():setPipeInFruitMap(self.pipeController:getPipeOffsetX(), self:getWorkWidth())
    self:debug('Pipe in fruit map created, there are %d non-headland waypoints, of which at %d the pipe will be in the fruit',
            total, pipeInFruit)
    self.fillLevelFullPercentage = self.normalFillLevelFullPercentage
end

function AIDriveStrategyCombineCourse:initializeImplementControllers(vehicle)
    AIDriveStrategyCombineCourse:superClass().initializeImplementControllers(self, vehicle)
    local _
    _, self.pipeController = self:addImplementController(vehicle, PipeController, Pipe, {}, nil)
    self.combine, self.combineController = self:addImplementController(vehicle, CombineController, Combine, {}, nil)
end

function AIDriveStrategyCombineCourse:getProximitySensorWidth()
    -- proximity sensor width across the entire working width
    return self:getWorkWidth()
end

-- This part of an ugly workaround to make the chopper pickups work
function AIDriveStrategyCombineCourse:checkMarkers()
    for _, implement in pairs(AIUtil.getAllAIImplements(self.vehicle)) do
        local aiLeftMarker, aiRightMarker, aiBackMarker = implement.object:getAIMarkers()
        if not aiLeftMarker or not aiRightMarker or not aiBackMarker then
            self.notAllImplementsHaveAiMarkers = true
            return
        end
    end
end

--- Get the combine object, this can be different from the vehicle in case of tools towed or mounted on a tractor
function AIDriveStrategyCombineCourse:getCombine()
    return self.combine
end

function AIDriveStrategyCombineCourse:update(dt)
    AIDriveStrategyFieldWorkCourse.update(self, dt)
    self:updateChopperFillType()
    self:onDraw()
end

--- Hold the harvester for a period of periodMs milliseconds
function AIDriveStrategyCombineCourse:hold(periodMs)
    if not self.temporaryHold:get() then
        self:debug('Temporary hold request for %d milliseconds', periodMs)
    end
    self.temporaryHold:set(true, math.min(math.max(0, periodMs), 30000))
end

function AIDriveStrategyCombineCourse:getDriveData(dt, vX, vY, vZ)
    self:handlePipe(dt)
    if self.temporaryHold:get() then
        self:setMaxSpeed(0)
    end
    if self.state == self.states.WORKING then
        -- Harvesting
        self:checkRendezvous()
        self:checkBlockingUnloader()

        if self:isFull() then
            self:changeToUnloadOnField()
        elseif self:shouldWaitAtEndOfRow() then
            self:startWaitingForUnloadBeforeNextRow()
        end

        if self:shouldStopForUnloading() then
            -- player does not want us to move while discharging
            self:setMaxSpeed(0)
        end
    elseif self.state == self.states.TURNING then
        self:checkBlockingUnloader()
    elseif self.state == self.states.WAITING_FOR_LOWER then
        if self:isFull() then
            self:debug('Waiting for lower but full...')
            self:changeToUnloadOnField()
        end
    elseif self.state == self.states.UNLOADING_ON_FIELD then
        -- Unloading
        self:driveUnloadOnField()
        self:callUnloaderWhenNeeded()
    end
    if self:isTurning() and not self:isTurningOnHeadland() then
        if self:shouldHoldInTurnManeuver() then
            self:setMaxSpeed(0)
        end
    end
    return AIDriveStrategyCombineCourse.superClass().getDriveData(self, dt, vX, vY, vZ)
end

function AIDriveStrategyCombineCourse:updateFieldworkOffset(course)
    if self.state == self.states.UNLOADING_ON_FIELD and self:isUnloadStateOneOf(self.selfUnloadStates) then
        -- do not apply fieldwork offset when not doing fieldwork
        course:setOffset((self.aiOffsetX or 0) + (self.tightTurnOffset or 0), (self.aiOffsetZ or 0))
    else
        course:setOffset(self.settings.toolOffsetX:getValue() + (self.aiOffsetX or 0) + (self.tightTurnOffset or 0),
                (self.aiOffsetZ or 0))
    end
end

function AIDriveStrategyCombineCourse:checkDistanceToOtherFieldWorkers()
    -- do not slow down/stop for convoy while unloading
    if self.state ~= self.states.UNLOADING_ON_FIELD then
        self:setMaxSpeed(self.fieldWorkerProximityController:getMaxSpeed(self.settings.convoyDistance:getValue(), self.maxSpeed))
    end
end

--- Take care of unloading on the field. This could be stopping and waiting for an unloader or
--- self unloading.
--- The output of this function is:
---  * set self.maxSpeed
---  * change the course to run, for example pulling back/making pocket or self unload
---  * this does not supply drive target point
function AIDriveStrategyCombineCourse:driveUnloadOnField()
    if self.unloadState == self.states.STOPPING_FOR_UNLOAD then
        self:setMaxSpeed(0)
        -- wait until we stopped before raising the implements
        if AIUtil.isStopped(self.vehicle) then
            if self.raiseHeaderAfterStopped then
                self:debug('Stopped, now raise implements and switch to next unload state')
                self:raiseImplements()
            end
            self.unloadState = self.newUnloadStateAfterStopped
        end
    elseif self.unloadState == self.states.PULLING_BACK_FOR_UNLOAD then
        self:setMaxSpeed(self.settings.reverseSpeed:getValue())
    elseif self.unloadState == self.states.REVERSING_TO_MAKE_A_POCKET then
        self:setMaxSpeed(self.settings.reverseSpeed:getValue())
    elseif self.unloadState == self.states.MAKING_POCKET then
        self:setMaxSpeed(self.settings.fieldWorkSpeed:getValue())
    elseif self.unloadState == self.states.RETURNING_FROM_PULL_BACK then
        self:setMaxSpeed(self.settings.turnSpeed:getValue())
    elseif self.unloadState == self.states.WAITING_FOR_UNLOAD_IN_POCKET or
            self.unloadState == self.states.WAITING_FOR_UNLOAD_AFTER_PULLED_BACK or
            self.unloadState == self.states.UNLOADING_BEFORE_STARTING_NEXT_ROW then
        if self:isUnloadFinished() then
            -- reset offset to return to the original up/down row after we unloaded in the pocket
            self.aiOffsetX = 0

            -- wait a bit after the unload finished to give a chance to the unloader to move away
            self.stateBeforeWaitingForUnloaderToLeave = self.unloadState
            self.unloadState = self.states.WAITING_FOR_UNLOADER_TO_LEAVE
            self.waitingForUnloaderSince = g_currentMission.time
            self:debug('Unloading finished, wait for the unloader to leave...')
        else
            self:setMaxSpeed(0)
        end
    elseif self.unloadState == self.states.WAITING_FOR_UNLOAD_ON_FIELD then
        if g_updateLoopIndex % 5 == 0 then
            --small delay, to make sure no more fillLevel change is happening
            if not self:isFull() and not self:shouldStopForUnloading() then
                self:debug('not full anymore, can continue working')
                self:changeToFieldWork()
            end
        end
        self:setMaxSpeed(0)
    elseif self.unloadState == self.states.WAITING_FOR_UNLOAD_BEFORE_STARTING_NEXT_ROW then
        self:setMaxSpeed(0)
        if self:isDischarging() then
            self:cancelRendezvous()
            self.unloadState = self.states.UNLOADING_BEFORE_STARTING_NEXT_ROW
            self:debug('Unloading started at end of row')
        end
        if not self.waitingForUnloaderAtEndOfRow:get() then
            local unloaderWhoDidNotShowUp = self.unloaderToRendezvous:get()
            self:cancelRendezvous()
            if unloaderWhoDidNotShowUp then
                unloaderWhoDidNotShowUp:getCpDriveStrategy():onMissedRendezvous(self)
            end
            self:debug('Waited for unloader at the end of the row but it did not show up, try to continue')
            self:changeToFieldWork()
        end
    elseif self.unloadState == self.states.WAITING_FOR_UNLOAD_AFTER_FIELDWORK_ENDED then
        local fillLevel = self.combineController:getFillLevel()
        if fillLevel < 0.01 then
            self:debug('Unloading finished after fieldwork ended, end course')
            AIDriveStrategyCombineCourse.superClass().finishFieldWork(self)
        else
            self:setMaxSpeed(0)
        end
    elseif self.unloadState == self.states.WAITING_FOR_UNLOADER_TO_LEAVE then
        self:setMaxSpeed(0)
        -- TODO: instead of just wait a few seconds we could check if the unloader has actually left
        if self.waitingForUnloaderSince + 5000 < g_currentMission.time then
            if self.stateBeforeWaitingForUnloaderToLeave == self.states.WAITING_FOR_UNLOAD_AFTER_PULLED_BACK then
                local pullBackReturnCourse = self:createPullBackReturnCourse()
                if pullBackReturnCourse then
                    self.unloadState = self.states.RETURNING_FROM_PULL_BACK
                    self:debug('Unloading finished, returning to fieldwork on return course')
                    self:startCourse(pullBackReturnCourse, 1)
                    self:rememberCourse(self.courseAfterPullBack, self.ixAfterPullBack)
                else
                    self:debug('Unloading finished, returning to fieldwork directly')
                    self:startCourse(self.courseAfterPullBack, self.ixAfterPullBack)
                    self.ppc:setNormalLookaheadDistance()
                    self:changeToFieldWork()
                end
            elseif self.stateBeforeWaitingForUnloaderToLeave == self.states.WAITING_FOR_UNLOAD_IN_POCKET then
                self:debug('Unloading in pocket finished, returning to fieldwork')
                self.fillLevelFullPercentage = self.normalFillLevelFullPercentage
                self:changeToFieldWork()
            elseif self.stateBeforeWaitingForUnloaderToLeave == self.states.UNLOADING_BEFORE_STARTING_NEXT_ROW then
                self:debug('Unloading before next row finished, returning to fieldwork')
                self:changeToFieldWork()
            elseif self.stateBeforeWaitingForUnloaderToLeave == self.states.WAITING_FOR_UNLOAD_ON_FIELD then
                self:debug('Unloading on field finished, returning to fieldwork')
                self:changeToFieldWork()
            else
                self:debug('Unloading finished, previous state not known, returning to fieldwork')
                self:changeToFieldWork()
            end
        end
    elseif self.unloadState == self.states.DRIVING_TO_SELF_UNLOAD_AFTER_FIELDWORK_ENDED or
            self.unloadState == self.states.DRIVING_TO_SELF_UNLOAD then
        if self:isCloseToCourseEnd(25) then
            -- slow down towards the end of the course, near the trailer
            self:setMaxSpeed(0.5 * self.settings.fieldSpeed:getValue())
            -- disable stock collision detection as we have to drive very close to the tractor/trailer
            self:disableCollisionDetection()
            -- we'll be very close to the tractor/trailer, don't stop too soon
            self.proximityController:setTemporaryStopThreshold(self.proximityStopThresholdSelfUnload, 3000)
        else
            self:setMaxSpeed(self.settings.fieldSpeed:getValue())
        end
    elseif self.unloadState == self.states.SELF_UNLOADING_WAITING_FOR_DISCHARGE then
        self:setMaxSpeed(0)
        self:debugSparse('Waiting for the self unloading to start')
        if self:isDischarging() then
            self.unloadState = self.states.SELF_UNLOADING
        end
    elseif self.unloadState == self.states.SELF_UNLOADING then
        self:setMaxSpeed(0)
        if self:isUnloadFinished() then
            if not self:continueSelfUnloadToNextTrailer() then
                self:debug('Self unloading finished, returning to fieldwork')
                self.unloadState = self.states.RETURNING_FROM_SELF_UNLOAD
                self.ppc:setNormalLookaheadDistance()
                self:returnToFieldworkAfterSelfUnload()
            end
        end
    elseif self.unloadState == self.states.SELF_UNLOADING_AFTER_FIELDWORK_ENDED_WAITING_FOR_DISCHARGE then
        self:setMaxSpeed(0)
        self:debugSparse('Fieldwork ended, waiting for the self unloading to start')
        if self:isDischarging() then
            self.unloadState = self.states.SELF_UNLOADING_AFTER_FIELDWORK_ENDED
        end
    elseif self.unloadState == self.states.SELF_UNLOADING_AFTER_FIELDWORK_ENDED then
        self:setMaxSpeed(0)
        if self:isUnloadFinished() then
            if not self:continueSelfUnloadToNextTrailer() then
                self:debug('Self unloading finished after fieldwork ended, finishing fieldwork')
                AIDriveStrategyCombineCourse.superClass().finishFieldWork(self)
            end
        end
    elseif self.unloadState == self.states.RETURNING_FROM_SELF_UNLOAD then
        if self:isCloseToCourseStart(25) then
            self:setMaxSpeed(0.5 * self.settings.fieldSpeed:getValue())
            -- we'll be very close to the tractor/trailer, don't stop too soon
            self.proximityController:setTemporaryStopThreshold(self.proximityStopThresholdSelfUnload, 3000)
        else
            self:setMaxSpeed(self.settings.fieldSpeed:getValue())
            self:enableCollisionDetection()
        end
    end
end

-----------------------------------------------------------------------------------------------------------------------
--- Event listeners
-----------------------------------------------------------------------------------------------------------------------
function AIDriveStrategyCombineCourse:onWaypointPassed(ix, course)
    if self.state == self.states.UNLOADING_ON_FIELD and
            (self.unloadState == self.states.DRIVING_TO_SELF_UNLOAD or
                    self.unloadState == self.states.DRIVING_TO_SELF_UNLOAD_AFTER_FIELDWORK_ENDED or
                    self.unloadState == self.states.RETURNING_FROM_SELF_UNLOAD) then
        -- nothing to do while driving to unload and back
        return AIDriveStrategyFieldWorkCourse.onWaypointPassed(self, ix, course)
    end

    self:checkFruit()

    -- make sure we start making a pocket while we still have some fill capacity left as we'll be
    -- harvesting fruit while making the pocket unless we have self unload turned on
    if self:shouldMakePocket() and not self.settings.selfUnload:getValue() then
        self.fillLevelFullPercentage = self.pocketFillLevelFullPercentage
    end

    local isOnHeadland = self.course:isOnHeadland(ix)
    self.combineController:updateStrawSwath(isOnHeadland)

    if self.state == self.states.WORKING then
        self:estimateDistanceUntilFull(ix)
        self:callUnloaderWhenNeeded()
    end

    if self.state == self.states.UNLOADING_ON_FIELD and
            self.unloadState == self.states.MAKING_POCKET and
            self.unloadInPocketIx and ix == self.unloadInPocketIx then
        -- we are making a pocket and reached the waypoint where we are going to stop and wait for unload
        self:debug('Waiting for unload in the pocket')
        self.unloadState = self.states.WAITING_FOR_UNLOAD_IN_POCKET
    end

    if self.returnedFromPocketIx and self.returnedFromPocketIx == ix then
        -- back to normal look ahead distance for PPC, no tight turns are needed anymore
        self:debug('Reset PPC to normal lookahead distance')
        self.ppc:setNormalLookaheadDistance()
    end
    AIDriveStrategyFieldWorkCourse.onWaypointPassed(self, ix, course)
end

--- Called when the last waypoint of a course is passed
function AIDriveStrategyCombineCourse:onLastWaypointPassed()
    local fillLevel = self.combineController:getFillLevel()
    if self.state == self.states.UNLOADING_ON_FIELD then
        if self.unloadState == self.states.RETURNING_FROM_PULL_BACK then
            self:debug('Pull back finished, returning to fieldwork')
            self:startRememberedCourse()
            self:changeToFieldWork()
        elseif self.unloadState == self.states.RETURNING_FROM_SELF_UNLOAD then
            self:debug('Back from self unload, returning to fieldwork')
            self:startRememberedCourse()
            self:changeToFieldWork()
        elseif self.unloadState == self.states.REVERSING_TO_MAKE_A_POCKET then
            self:debug('Reversed, now start making a pocket to waypoint %d', self.unloadInPocketIx)
            self:lowerImplements()
            -- TODO: maybe lowerImplements should not set the WAITING_FOR_LOWER_DELAYED state...
            self.state = self.states.UNLOADING_ON_FIELD
            self.unloadState = self.states.MAKING_POCKET
            -- offset the main fieldwork course and start on it
            self.aiOffsetX = math.min(self.pullBackRightSideOffset, self:getWorkWidth())
            self:startRememberedCourse()
        elseif self.unloadState == self.states.PULLING_BACK_FOR_UNLOAD then
            -- pulled back, now wait for unload
            self.unloadState = self.states.WAITING_FOR_UNLOAD_AFTER_PULLED_BACK
            self:debug('Pulled back, now wait for unload')
        elseif self.unloadState == self.states.DRIVING_TO_SELF_UNLOAD then
            self:debug('Self unloading point reached, fill level %.1f, waiting for unload to start.', fillLevel)
            self.unloadState = self.states.SELF_UNLOADING_WAITING_FOR_DISCHARGE
        elseif self.unloadState == self.states.DRIVING_TO_SELF_UNLOAD_AFTER_FIELDWORK_ENDED then
            self:debug('Self unloading point reached after fieldwork ended, fill level %.1f, waiting for unload to start.', fillLevel)
            self.unloadState = self.states.SELF_UNLOADING_AFTER_FIELDWORK_ENDED_WAITING_FOR_DISCHARGE
        end
    elseif self.state == self.states.WORKING and fillLevel > 0 then
        -- reset offset we used for the course ending to not miss anything
        self.aiOffsetZ = 0
        if self.settings.selfUnload:getValue() and self:startSelfUnload() then
            self:debug('Start self unload after fieldwork ended')
            self:raiseImplements()
            self.state = self.states.UNLOADING_ON_FIELD
            self.unloadState = self.states.DRIVING_TO_SELF_UNLOAD_AFTER_FIELDWORK_ENDED
            self.ppc:setShortLookaheadDistance()
            self:disableCollisionDetection()
        else
            -- let AutoDrive know we are done and can unload
            self:debug('Fieldwork done, fill level is %.1f, now waiting to be unloaded.', fillLevel)
            self.state = self.states.UNLOADING_ON_FIELD
            self.unloadState = self.states.WAITING_FOR_UNLOAD_AFTER_FIELDWORK_ENDED
        end
    else
        AIDriveStrategyCombineCourse.superClass().onLastWaypointPassed(self)
    end
end

-----------------------------------------------------------------------------------------------------------------------
--- State changes
-----------------------------------------------------------------------------------------------------------------------

--- Some of our turns need a short look ahead distance, make sure we restore the normal after the turn
function AIDriveStrategyCombineCourse:resumeFieldworkAfterTurn(ix)
    self.ppc:setNormalLookaheadDistance()
    AIDriveStrategyCombineCourse.superClass().resumeFieldworkAfterTurn(self, ix)
end

--- Stop, raise the header (if needed) and then, and only then change to the new states. This is to avoid leaving
--- unharvested spots due to the header being lifted while the vehicle is still in motion.
function AIDriveStrategyCombineCourse:stopForUnload(newUnloadStateAfterStopped, raiseHeaderAfterStopped)
    self.state = self.states.UNLOADING_ON_FIELD
    self.unloadState = self.states.STOPPING_FOR_UNLOAD
    self.newUnloadStateAfterStopped = newUnloadStateAfterStopped
    self.raiseHeaderAfterStopped = raiseHeaderAfterStopped
end

function AIDriveStrategyCombineCourse:changeToUnloadOnField()
    self:checkFruit()
    -- TODO: check around turn maneuvers we may not want to pull back before a turn
    if self.settings.selfUnload:getValue() and self:startSelfUnload() then
        self:debug('Start self unload')
        self:raiseImplements()
        self.state = self.states.UNLOADING_ON_FIELD
        self.unloadState = self.states.DRIVING_TO_SELF_UNLOAD
        self.ppc:setShortLookaheadDistance()
    elseif self.settings.avoidFruit:getValue() and self:shouldMakePocket() then
        -- I'm on the edge of the field or fruit is on both sides, make a pocket on the right side and wait there for the unload
        local pocketCourse, nextIx = self:createPocketCourse()
        if pocketCourse then
            self:debug('No room to the left, making a pocket for unload')
            self.state = self.states.UNLOADING_ON_FIELD
            self.unloadState = self.states.REVERSING_TO_MAKE_A_POCKET
            self:rememberCourse(self.course, nextIx)
            -- raise header for reversing
            self:raiseImplements()
            self:startCourse(pocketCourse, 1)
            -- tighter turns
            self.ppc:setShortLookaheadDistance()
        else
            self:startWaitingForUnloadWhenFull()
        end
    elseif self.settings.avoidFruit:getValue() and self:shouldPullBack() then
        -- is our pipe in the fruit? (assuming pipe is on the left side)
        local pullBackCourse = self:createPullBackCourse()
        if pullBackCourse then
            self:debug('Pipe in fruit, pulling back to make room for unloading')
            self:stopForUnload(self.states.PULLING_BACK_FOR_UNLOAD, true)
            self.courseAfterPullBack = self.course
            self.ixAfterPullBack = self.ppc:getLastPassedWaypointIx() or self.ppc:getCurrentWaypointIx()
            -- tighter turns
            self.ppc:setShortLookaheadDistance()
            self:startCourse(pullBackCourse, 1)
        else
            self:startWaitingForUnloadWhenFull()
        end
    else
        self:startWaitingForUnloadWhenFull()
    end
end

function AIDriveStrategyCombineCourse:startWaitingForUnloadWhenFull()
    self:stopForUnload(self.states.WAITING_FOR_UNLOAD_ON_FIELD, true)
    self:debug('Waiting for the unloader on the field')
    g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL,
            string.format(g_i18n:getText("ai_messageErrorGrainTankIsFull"), self.vehicle:getCurrentHelper().name))
end

function AIDriveStrategyCombineCourse:startWaitingForUnloadBeforeNextRow()
    self:debug('Waiting for unload before starting the next row')
    self.waitingForUnloaderAtEndOfRow:set(true, 30000)
    self.state = self.states.UNLOADING_ON_FIELD
    self.unloadState = self.states.WAITING_FOR_UNLOAD_BEFORE_STARTING_NEXT_ROW
end

--- The unloader may call this repeatedly to confirm that the rendezvous still stands, making sure the
--- combine won't give up and keeps waiting
function AIDriveStrategyCombineCourse:reconfirmRendezvous()
    if self.waitingForUnloaderAtEndOfRow:get() then
        -- ok, we'll wait another 30 seconds
        self.waitingForUnloaderAtEndOfRow:set(true, 30000)
    end
end

function AIDriveStrategyCombineCourse:isUnloadFinished()
    local discharging = true
    local dischargingNow = self:isDischarging()
    --wait for 10 frames before taking discharging as false
    if not dischargingNow then
        self.notDischargingSinceLoopIndex = self.notDischargingSinceLoopIndex and self.notDischargingSinceLoopIndex or g_updateLoopIndex
        if g_updateLoopIndex - self.notDischargingSinceLoopIndex > 10 then
            discharging = false
        end
    else
        self.notDischargingSinceLoopIndex = nil
    end
    local fillLevel = self.combineController:getFillLevel()
    -- unload is done when fill levels are ok (not full) and not discharging anymore (either because we
    -- are empty or the trailer is full)
    return (not self:isFull() and not discharging) or fillLevel < 0.1
end

function AIDriveStrategyCombineCourse:isFull(fillLevelFullPercentage)
    local fillLevelPercentage = self.combineController:getFillLevelPercentage()
    if fillLevelPercentage >= 100 or fillLevelPercentage > (fillLevelFullPercentage or self.fillLevelFullPercentage) then
        self:debugSparse('Full or refillUntilPct reached: %.2f', fillLevelPercentage)
        return true
    end
    if fillLevelPercentage < 0.1 then
        self.stopDisabledAfterEmpty:set(true, 2000)
    end
    return false
end

function AIDriveStrategyCombineCourse:shouldMakePocket()
    if self.fruitLeft > 0.75 and self.fruitRight > 0.75 then
        -- fruit both sides
        return true
    elseif self:isPipeOnLeft() then
        -- on the outermost headland clockwise (field edge)
        return not self.fieldOnLeft
    else
        -- on the outermost headland counterclockwise (field edge)
        return not self.fieldOnRight
    end
end

function AIDriveStrategyCombineCourse:shouldPullBack()
    return self:isPipeInFruit()
end

function AIDriveStrategyCombineCourse:isPipeOnLeft()
    return self.pipeController:isPipeOnTheLeftSide()
end

function AIDriveStrategyCombineCourse:isPipeInFruit()
    -- is our pipe in the fruit?
    if self:isPipeOnLeft() then
        return self.fruitLeft > self.fruitRight
    else
        return self.fruitLeft < self.fruitRight
    end
end

function AIDriveStrategyCombineCourse:checkFruit()
    -- getValidityOfTurnDirections() wants to have the vehicle.aiDriveDirection, so get that here.
    local dx, _, dz = localDirectionToWorld(self.vehicle:getAIDirectionNode(), 0, 0, 1)
    local length = MathUtil.vector2Length(dx, dz)
    dx = dx / length
    dz = dz / length
    self.vehicle.aiDriveDirection = { dx, dz }
    -- getValidityOfTurnDirections works only if all AI Implements have aiMarkers. Since
    -- we make all Cutters AI implements, even the ones which do not have AI markers (such as the
    -- chopper pickups which do not work with the Giants helper) we have to make sure we don't call
    -- getValidityOfTurnDirections for those
    if self.notAllImplementsHaveAiMarkers then
        self.fruitLeft, self.fruitRight = 0, 0
    else
        self.fruitLeft, self.fruitRight = AIVehicleUtil.getValidityOfTurnDirections(self.vehicle)
    end
    local workWidth = self:getWorkWidth()
    local x, _, z = localToWorld(self.vehicle:getAIDirectionNode(), workWidth, 0, 0)
    self.fieldOnLeft = CpFieldUtil.isOnField(x, z)
    x, _, z = localToWorld(self.vehicle:getAIDirectionNode(), -workWidth, 0, 0)
    self.fieldOnRight = CpFieldUtil.isOnField(x, z)
    self:debug('Fruit left: %.2f right %.2f, field on left %s, right %s',
            self.fruitLeft, self.fruitRight, tostring(self.fieldOnLeft), tostring(self.fieldOnRight))
end

--- Estimate the waypoint where the combine will be full/reach the fill level where it should start unloading
--- (waypointIxWhenFull/waypointIxWhenCallUnloader), based on the current harvest rate
function AIDriveStrategyCombineCourse:estimateDistanceUntilFull(ix)
    -- calculate fill rate so the combine driver knows if it can make the next row without unloading
    local fillLevel = self.combineController:getFillLevel()
    local capacity = self.combineController:getCapacity()
    if ix > 1 then
        local dToNext = self.course:getDistanceToNextWaypoint(ix - 1)
        if self.fillLevelAtLastWaypoint and self.fillLevelAtLastWaypoint > 0 and self.fillLevelAtLastWaypoint <= fillLevel then
            local litersPerMeter = (fillLevel - self.fillLevelAtLastWaypoint) / dToNext
            -- make sure it won't end up being inf
            local litersPerSecond = math.min(1000, (fillLevel - self.fillLevelAtLastWaypoint) /
                    ((g_currentMission.time - (self.fillLevelLastCheckedTime or g_currentMission.time)) / 1000))
            -- smooth everything a bit, also ignore 0
            self.litersPerMeter = litersPerMeter > 0 and ((self.litersPerMeter + litersPerMeter) / 2) or self.litersPerMeter
            self.litersPerSecond = litersPerSecond > 0 and ((self.litersPerSecond + litersPerSecond) / 2) or self.litersPerSecond
        else
            -- no history yet, so make sure we don't end up with some unrealistic numbers
            self.waypointIxWhenFull = nil
            self.litersPerMeter = 0
            self.litersPerSecond = 0
        end
        self:debug('Fill rate is %.1f l/m, %.1f l/s (fill level %.1f, last %.1f, dToNext = %.1f)',
                self.litersPerMeter, self.litersPerSecond, fillLevel, self.fillLevelAtLastWaypoint, dToNext)
        self.fillLevelLastCheckedTime = g_currentMission.time
        self.fillLevelAtLastWaypoint = fillLevel
    end
    local litersUntilFull = capacity - fillLevel
    local dUntilFull = litersUntilFull / self.litersPerMeter
    local litersUntilCallUnloader = capacity * self.callUnloaderAtFillLevelPercentage / 100 - fillLevel
    local dUntilCallUnloader = litersUntilCallUnloader / self.litersPerMeter
    self.waypointIxWhenFull = self.course:getNextWaypointIxWithinDistance(ix, dUntilFull) or self.course:getNumberOfWaypoints()
    local wpDistance
    self.waypointIxWhenCallUnloader, wpDistance = self.course:getNextWaypointIxWithinDistance(ix, dUntilCallUnloader)
    self:debug('Will be full at waypoint %d, fill level %d at waypoint %d (current waypoint %d), %.1f m and %.1f l until call (currently %.1f l), wp distance %.1f',
            self.waypointIxWhenFull or -1, self.callUnloaderAtFillLevelPercentage, self.waypointIxWhenCallUnloader or -1,
            self.course:getCurrentWaypointIx(), dUntilCallUnloader, litersUntilCallUnloader, fillLevel, wpDistance)
end

function AIDriveStrategyCombineCourse:shouldWaitAtEndOfRow()
    local nextRowStartIx = self.course:getNextRowStartIx(self.ppc:getRelevantWaypointIx())
    local lastPassedWaypointIx = self.ppc:getLastPassedWaypointIx() or self.ppc:getRelevantWaypointIx()
    local distanceToNextTurn = self.course:getDistanceToNextTurn(lastPassedWaypointIx) or math.huge
    local closeToTurn = distanceToNextTurn < AIDriveStrategyCombineCourse.safeUnloadDistanceBeforeEndOfRow
    -- If close to the end of the row and the pipe would be in the fruit after the turn, and our fill level is high,
    -- we always wait here for an unloader, regardless of having a rendezvous or not (unless we have our pipe in fruit here)
    if nextRowStartIx and closeToTurn and
            self:isPipeInFruitAt(nextRowStartIx) and
            self:isFull(AIDriveStrategyCombineCourse.waitForUnloadAtEndOfRowFillLevelThreshold) then
        self:checkFruit()
        if not self:isPipeInFruit() then
            self:debug('shouldWaitAtEndOfRow: Closer than %.1f m to a turn, pipe would be in fruit after turn at %d, fill level over %.1f',
                    AIDriveStrategyCombineCourse.safeUnloadDistanceBeforeEndOfRow, nextRowStartIx,
                    AIDriveStrategyCombineCourse.waitForUnloadAtEndOfRowFillLevelThreshold)
            return true
        end
    end
    -- Or, if we are close to the turn and have a rendezvous waypoint before the turn
    if nextRowStartIx and closeToTurn and
            self.unloaderRendezvousWaypointIx and
            nextRowStartIx > self.unloaderRendezvousWaypointIx then
        self:debug('shouldWaitAtEndOfRow: Closer than %.1f m to a turn and rendezvous waypoint %d is before the turn, waiting for the unloader here',
                AIDriveStrategyCombineCourse.safeUnloadDistanceBeforeEndOfRow, self.unloaderRendezvousWaypointIx)
        return true
    end
end

------------------------------------------------------------------------------------------------------------------------
--- Unloader handling
---
--- We need to answer the following questions:
--- 1. When to call the unloader?
--- 2. Where to meet the unloader?
--- 3. Which unloader to call?
---
--- To question #3, we check the distance between the unloader and the target (combine and a rendezvous point) and based
--- on the unloader's distance to the target and its fill level, we calculate a score and call the unloader with
--- the best score.
---
--- To questions #1 and #2, we have to cases:
---
--- The easy case
---
--- If the combine is stopped for unloading (either 100% full, or made a pocket or finished the course, etc.),
--- the unloader must drive to the combine immediately.
---
--- The difficult case
---
--- The combine is still harvesting, and periodically calculates the waypoint/distance where it will reach the fill
--- level threshold configured. This is the fill level when we want the unload process to start, so the unloader
--- is supposed to meet the combine at that (rendezvous) spot. This answers #2, where to meet the unloader.
--- But when to call the unloader? When it will reach the rendezvous point about the same time (or a little earlier)
--- as the combine reaches it. So we ask around all unloaders to figure out what their estimated time en-route (ETE)
--- to the rendezvous waypoint would be. Then pick the one with the shortest ETE, and if its ETE (plus some reserve)
--- is more than the combine's ETE, call it.
---
------------------------------------------------------------------------------------------------------------------------
function AIDriveStrategyCombineCourse:callUnloaderWhenNeeded()
    if not self.timeToCallUnloader:get() then
        return
    end
    -- check back again in a few seconds
    self.timeToCallUnloader:set(false, 3000)

    if self.unloader:get() then
        self:debug('callUnloaderWhenNeeded: already has an unloader assigned (%s)', CpUtil.getName(self.unloader:get()))
        return
    end

    local bestUnloader, bestEte
    if self:isWaitingForUnload() then
        bestUnloader, _ = self:findUnloader(self.vehicle, nil)
        self:debug('callUnloaderWhenNeeded: stopped, need unloader here')
        if bestUnloader then
            bestUnloader:getCpDriveStrategy():call(self.vehicle, nil)
        end
    else
        if not self.waypointIxWhenCallUnloader then
            self:debug('callUnloaderWhenNeeded: don\'t know yet where to meet the unloader')
            return
        end
        -- Find a good waypoint to unload, as the calculated one may have issues, like pipe would be in the fruit,
        -- or in a turn, etc.
        -- TODO: isPipeInFruitAllowed
        local tentativeRendezvousWaypointIx = self:findBestWaypointToUnload(self.waypointIxWhenCallUnloader, false)
        if not tentativeRendezvousWaypointIx then
            self:debug('callUnloaderWhenNeeded: can\'t find a good waypoint to meet the unloader')
            return
        end
        bestUnloader, bestEte = self:findUnloader(nil, self.course:getWaypoint(tentativeRendezvousWaypointIx))
        -- getSpeedLimit() may return math.huge (inf), when turning for example, not sure why, and that throws off
        -- our ETE calculation
        if bestUnloader and self.vehicle:getSpeedLimit(true) < 100 then
            local dToUnloadWaypoint = self.course:getDistanceBetweenWaypoints(tentativeRendezvousWaypointIx,
                    self.course:getCurrentWaypointIx())
            local myEte = dToUnloadWaypoint / (self.vehicle:getSpeedLimit(true) / 3.6)
            self:debug('callUnloaderWhenNeeded: best unloader ETE at waypoint %d %.1fs, my ETE %.1fs',
                    tentativeRendezvousWaypointIx, bestEte, myEte)
            if bestEte - 5 > myEte then
                -- I'll be at the rendezvous a lot earlier than the unloader which will almost certainly result in the
                -- cancellation of the rendezvous.
                -- So, set something up further away, with better chances,
                -- using the unloader's ETE, knowing that 1) that ETE is for the current rendezvous point, 2) there
                -- may be another unloader selected for that waypoint
                local dToTentativeRendezvousWaypoint = bestEte * (self.vehicle:getSpeedLimit(true) / 3.6)
                self:debug('callUnloaderWhenNeeded: too close to rendezvous waypoint, trying move it %.1fm',
                        dToTentativeRendezvousWaypoint)
                tentativeRendezvousWaypointIx = self.course:getNextWaypointIxWithinDistance(
                        self.course:getCurrentWaypointIx(), dToTentativeRendezvousWaypoint)
                if tentativeRendezvousWaypointIx then
                    bestUnloader, bestEte = self:findUnloader(nil, self.course:getWaypoint(tentativeRendezvousWaypointIx))
                    if bestUnloader then
                        self:callUnloader(bestUnloader, tentativeRendezvousWaypointIx, bestEte)
                    end
                else
                    self:debug('callUnloaderWhenNeeded: still can\'t find a good waypoint to meet the unloader')
                end
            elseif bestEte + 5 > myEte then
                -- do not call too early (like minutes before we get there), only when it needs at least as
                -- much time to get there as the combine (-5 seconds)
                self:callUnloader(bestUnloader, tentativeRendezvousWaypointIx, bestEte)
            end
        end
    end
end

function AIDriveStrategyCombineCourse:callUnloader(bestUnloader, tentativeRendezvousWaypointIx, bestEte)
    if bestUnloader:getCpDriveStrategy():call(self.vehicle,
            self.course:getWaypoint(tentativeRendezvousWaypointIx)) then
        self.unloaderToRendezvous:set(bestUnloader, 1000 * (bestEte + 30))
        self.unloaderRendezvousWaypointIx = tentativeRendezvousWaypointIx
        self:debug('callUnloaderWhenNeeded: harvesting, unloader accepted rendezvous at waypoint %d', self.unloaderRendezvousWaypointIx)
    else
        self:debug('callUnloaderWhenNeeded: harvesting, unloader rejected rendezvous at waypoint %d', tentativeRendezvousWaypointIx)
    end
end

function AIDriveStrategyCombineCourse:isActiveCpUnloader(vehicle)
    if vehicle.getIsCpCombineUnloaderActive and vehicle:getIsCpCombineUnloaderActive() then
        local strategy = vehicle:getCpDriveStrategy()
        if strategy then 
            local unloadTargetType = strategy:getUnloadTargetType()
            if unloadTargetType ~= nil then 
                return unloadTargetType == AIDriveStrategyUnloadCombine.UNLOAD_TYPES.COMBINE
            end
        end
    end
    return false
end

--- Find an unloader to drive to the target, which may either be the combine itself (when stopped and waiting for unload)
--- or a waypoint which the combine will reach in the future. Combine and waypoint parameters are mutually exclusive.
---@param combine table the combine vehicle if we need the unloader come to the combine, otherwise nil
---@param waypoint Waypoint the waypoint where the unloader should meet the combine, otherwise nil.
---@return table, number the best fitting unloader or nil, the estimated time en-route for the unloader to reach the
--- target (combine or waypoint)
function AIDriveStrategyCombineCourse:findUnloader(combine, waypoint)
    local bestScore = -math.huge
    local bestUnloader, bestEte
    for _, vehicle in pairs(g_currentMission.vehicles) do
        if self:isActiveCpUnloader(vehicle) then
            local x, _, z = getWorldTranslation(self.vehicle.rootNode)
            ---@type AIDriveStrategyUnloadCombine
            local driveStrategy = vehicle:getCpDriveStrategy()
            if driveStrategy:isServingPosition(x, z, 0) then
                local unloaderFillLevelPercentage = driveStrategy:getFillLevelPercentage()
                if driveStrategy:isIdle() and unloaderFillLevelPercentage < 99 then
                    local unloaderDistance, unloaderEte
                    if combine then
                        -- if already stopped, we want the unloader to come to us
                        unloaderDistance, unloaderEte = driveStrategy:getDistanceAndEteToVehicle(combine)
                    elseif self.waypointIxWhenCallUnloader then
                        -- if still going, we want the unloader to meet us at the waypoint
                        unloaderDistance, unloaderEte = driveStrategy:getDistanceAndEteToWaypoint(waypoint)
                    end
                    local score = unloaderFillLevelPercentage - 0.1 * unloaderDistance
                    self:debug('findUnloader: %s idle on my field, fill level %.1f, distance %.1f, ETE %.1f, score %.1f)',
                            CpUtil.getName(vehicle), unloaderFillLevelPercentage, unloaderDistance, unloaderEte, score)
                    if score > bestScore then
                        bestUnloader = vehicle
                        bestScore = score
                        bestEte = unloaderEte
                    end
                else
                    self:debug('findUnloader: %s serving my field but already busy', CpUtil.getName(vehicle))
                end
            else
                self:debug('findUnloader: %s is not serving my field', CpUtil.getName(vehicle))
            end
        end
    end
    if bestUnloader then
        self:debug('findUnloader: best unloader is %s (score %.1f, ETE %.1f)',
                CpUtil.getName(bestUnloader), bestScore, bestEte)
        return bestUnloader, bestEte
    else
        self:debug('findUnloader: no idle unloader found')
    end
end

function AIDriveStrategyCombineCourse:checkRendezvous()
    if self.unloaderToRendezvous:get() then
        local lastPassedWaypointIx = self.ppc:getLastPassedWaypointIx() or self.ppc:getRelevantWaypointIx()
        local d = self.course:getDistanceBetweenWaypoints(lastPassedWaypointIx, self.unloaderRendezvousWaypointIx)
        if d < 10 then
            self:debugSparse('Slow down around the unloader rendezvous waypoint %d to let the unloader catch up',
                    self.unloaderRendezvousWaypointIx)
            self:setMaxSpeed(self.settings.fieldWorkSpeed:getValue() / 2)
        elseif lastPassedWaypointIx > self.unloaderRendezvousWaypointIx then
            -- past the rendezvous waypoint
            self:debug('Unloader missed the rendezvous at %d', self.unloaderRendezvousWaypointIx)
            local unloaderWhoDidNotShowUp = self.unloaderToRendezvous:get()
            -- need to call this before onMissedRendezvous as the unloader will call back to set up a new rendezvous
            -- and we don't want to cancel that right away
            self:cancelRendezvous()
            unloaderWhoDidNotShowUp:getCpDriveStrategy():onMissedRendezvous(self.vehicle)
        end
        if self:isDischarging() then
            self:debug('Discharging, cancelling unloader rendezvous')
            self:cancelRendezvous()
        end
    end
end

function AIDriveStrategyCombineCourse:hasRendezvousWith(unloader)
    return self.unloaderToRendezvous:get() == unloader
end

function AIDriveStrategyCombineCourse:cancelRendezvous()
    local unloader = self.unloaderToRendezvous:get()
    self:debug('Rendezvous with %s at waypoint %d cancelled',
            unloader and CpUtil.getName(self.unloaderToRendezvous:get() or 'N/A'),
            self.unloaderRendezvousWaypointIx or -1)
    self.unloaderRendezvousWaypointIx = nil
    self.unloaderToRendezvous:reset()
end

--- Before the unloader asks for a rendezvous (which may result in a lengthy pathfinding to figure out
--- the distance), it should check if the combine is willing to rendezvous.
function AIDriveStrategyCombineCourse:isWillingToRendezvous()
    if self.state ~= self.states.WORKING then
        self:debug('not harvesting, will not rendezvous')
        return nil
    elseif not self.settings.unloadOnFirstHeadland:getValue() and
            self.course:isOnHeadland(self.course:getCurrentWaypointIx(), 1) then
        self:debug('on first headland and unload not allowed on first headland, will not rendezvous')
        return nil
    end
    return true
end

--- An area where the combine is expected to perform a turn between now and the rendezvous waypoint
---@return Waypoint a waypoint, the center of the maneuvering area
---@return number radius around the waypoint, defining a circular area
function AIDriveStrategyCombineCourse:getTurnArea()
    if self.unloaderRendezvousWaypointIx then
        for ix = self.course:getCurrentWaypointIx(), self.unloaderRendezvousWaypointIx do
            if self.course:isTurnEndAtIx(ix) then
                return self.course:getWaypoint(ix), self.turningRadius * 3
            end
        end
    end
end

function AIDriveStrategyCombineCourse:canUnloadWhileMovingAtWaypoint(ix)
    if self:isPipeInFruitAt(ix) then
        self:debug('pipe would be in fruit at the planned rendezvous waypoint %d', ix)
        return false
    end
    if not self.settings.unloadOnFirstHeadland:getValue() and self.course:isOnHeadland(ix, 1) then
        self:debug('planned rendezvous waypoint %d is on first headland, no unloading of moving combine there', ix)
        return false
    end
    return true
end

function AIDriveStrategyCombineCourse:checkFruitAtNode(node, offsetX, offsetZ)
    local x, _, z = localToWorld(node, offsetX, 0, offsetZ or 0)
    local hasFruit, fruitValue = PathfinderUtil.hasFruit(x, z, 5, 3)
    return hasFruit, fruitValue
end

--- Is pipe in fruit according to the current field harvest state at waypoint?
function AIDriveStrategyCombineCourse:isPipeInFruitAtWaypointNow(course, ix)
    if not self.storage.fruitCheckHelperWpNode then
        self.storage.fruitCheckHelperWpNode = WaypointNode(CpUtil.getName(self.vehicle) .. 'fruitCheckHelperWpNode')
    end
    self.storage.fruitCheckHelperWpNode:setToWaypoint(course, ix)
    local hasFruit, fruitValue = self:checkFruitAtNode(self.storage.fruitCheckHelperWpNode.node, self.pipeController:getPipeOffsetX())
    self:debugSparse('at waypoint %d pipe in fruit %s (fruitValue %.1f)', ix, tostring(hasFruit), fruitValue or 0)
    return hasFruit, fruitValue
end

function AIDriveStrategyCombineCourse:isPipeInFruitAt(ix)
    if self.course:getMultiTools() > 1 then
        -- we don't have a reliable pipe in fruit map for multitools, so just check
        -- if there is fruit at the waypoint now, to be on the safe side
        return self:isPipeInFruitAtWaypointNow(self.course, ix)
    else
        return self.course:isPipeInFruitAt(ix)
    end
end

--- Find the best waypoint to unload.
---@param ix number waypoint index we want to start unloading, either because that's about where
--- we'll rendezvous the unloader or we'll be full there.
---@return number best waypoint to unload, ix may be adjusted to make sure it isn't in a turn or
--- the fruit is not in the pipe.
function AIDriveStrategyCombineCourse:findBestWaypointToUnload(ix, isPipeInFruitAllowed)
    if self.course:isOnHeadland(ix) then
        return self:findBestWaypointToUnloadOnHeadland(ix)
    else
        return self:findBestWaypointToUnloadOnUpDownRows(ix, isPipeInFruitAllowed)
    end
end

function AIDriveStrategyCombineCourse:findBestWaypointToUnloadOnHeadland(ix)
    if not self.settings.unloadOnFirstHeadland:getValue() and
            self.course:isOnHeadland(ix, 1) then
        self:debug('planned rendezvous waypoint %d is on first headland, no unloading of moving combine there', ix)
        return nil
    end
    if self.course:isTurnStartAtIx(ix) then
        -- on the headland, use the wp after the turn, the one before may be very far, especially on a
        -- transition from headland to up/down rows.
        return ix + 1
    else
        return ix
    end
end

--- We calculated a waypoint to meet the unloader (either because it asked for it or we think we'll need
--- to unload. Now make sure that this location is not around a turn or the pipe isn't in the fruit by
--- trying to move it up or down a bit. If that's not possible, just leave it and see what happens :)
function AIDriveStrategyCombineCourse:findBestWaypointToUnloadOnUpDownRows(ix, isPipeInFruitAllowed)
    local dToNextTurn = self.course:getDistanceToNextTurn(ix) or math.huge
    local lRow, ixAtRowStart = self.course:getRowLength(ix)
    local pipeInFruit = self:isPipeInFruitAt(ix)
    local currentIx = self.course:getCurrentWaypointIx()
    local newWpIx = ix
    self:debug('Looking for a waypoint to unload around %d on up/down row, pipe in fruit %s, dToNextTurn: %d m, lRow = %d m',
            ix, tostring(pipeInFruit), dToNextTurn, lRow or 0)
    if pipeInFruit and not isPipeInFruitAllowed then
        --if the pipe is in fruit AND the user selects 'avoid fruit'
        if ixAtRowStart then
            if ixAtRowStart > currentIx then
                -- have not started the previous row yet
                self:debug('Pipe would be in fruit at waypoint %d. Check previous row', ix)
                pipeInFruit, _ = self:isPipeInFruitAt(ixAtRowStart - 2) -- wp before the turn start
                if not pipeInFruit then
                    local lPreviousRow, ixAtPreviousRowStart = self.course:getRowLength(ixAtRowStart - 1)
                    self:debug('pipe not in fruit in the previous row (%d m, ending at wp %d), rendezvous at %d',
                            lPreviousRow, ixAtRowStart - 1, newWpIx)
                    newWpIx = math.max(ixAtRowStart - 3, ixAtPreviousRowStart, currentIx)
                else
                    self:debug('Pipe in fruit in previous row too, rejecting rendezvous')
                    newWpIx = nil
                end
            else
                -- previous row already started. Could check next row but that means the rendezvous would be after
                -- the combine turns, and we'd be in the way during the turn, so rather not worry about the next row
                -- until the combine gets there.
                self:debug('Pipe would be in fruit at waypoint %d. Previous row is already started, no rendezvous', ix)
                newWpIx = nil
            end
        else
            self:debug('Could not determine row length, rejecting rendezvous')
            newWpIx = nil
        end
    else
        if (pipeInFruit) then
            self:debug('pipe would be in fruit at waypoint %d, acceptable for user', ix)
        else
            self:debug('pipe is not in fruit at %d. If it is towards the end of the row, bring it up a bit', ix)
        end
        -- so we'll have some distance for unloading
        if ixAtRowStart and dToNextTurn < AIDriveStrategyCombineCourse.safeUnloadDistanceBeforeEndOfRow then
            local safeIx = self.course:getPreviousWaypointIxWithinDistance(ix,
                    AIDriveStrategyCombineCourse.safeUnloadDistanceBeforeEndOfRow)
            newWpIx = math.max(ixAtRowStart + 1, safeIx or -1, ix - 4, currentIx)
        end
    end
    -- no better idea, just use the original estimated, making sure we avoid turn start waypoints
    if newWpIx and self.course:isTurnStartAtIx(newWpIx) then
        self:debug('Calculated rendezvous waypoint is at turn start, moving it up')
        -- make sure it is not on the turn start waypoint
        return math.max(newWpIx - 1, currentIx)
    else
        return newWpIx
    end
end

--- Create a temporary course to pull back to the right when the pipe is in the fruit so the tractor does not have
-- to drive in the fruit to get under the pipe
function AIDriveStrategyCombineCourse:createPullBackCourse()
    -- all we need is a waypoint on our right side towards the back
    self.returnPoint = {}
    self.returnPoint.x, _, self.returnPoint.z = getWorldTranslation(self.vehicle.rootNode)

    local dx, _, dz = localDirectionToWorld(self.vehicle:getAIDirectionNode(), 0, 0, 1)
    self.returnPoint.rotation = MathUtil.getYRotationFromDirection(dx, dz)
    dx, _, dz = localDirectionToWorld(self.vehicle:getAIDirectionNode(), 0, 0, -1)

    local x1, _, z1 = localToWorld(self.vehicle:getAIDirectionNode(), -self.pullBackRightSideOffset, 0, -self.pullBackDistanceStart)
    local x2, _, z2 = localToWorld(self.vehicle:getAIDirectionNode(), -self.pullBackRightSideOffset, 0, -self.pullBackDistanceEnd)
    -- both points must be on the field
    if CpFieldUtil.isOnField(x1, z1) and CpFieldUtil.isOnField(x2, z2) then

        local referenceNode, debugText = AIUtil.getReverserNode(self.vehicle)
        if referenceNode then
            self:debug('Using %s to start pull back course', debugText)
        else
            referenceNode = AIUtil.getDirectionNode(self.vehicle)
            self:debug('Using the direction node to start pull back course')
        end
        -- don't make this too complicated, just create a straight line on the left/right side (depending on
        -- where the pipe is and rely on the PPC, no need for generating fancy curves
        return Course.createFromNode(self.vehicle, referenceNode,
                -self.pullBackRightSideOffset, 0, -self.pullBackDistanceEnd, -2, true)
    else
        self:debug("Pull back course would be outside of the field")
        return nil
    end
end

--- Get the area the unloader should avoid when approaching the combine.
--- Main (and for now, only) use case is to prevent the unloader to cross in front of the combine after the
--- combine pulled back full with pipe in the fruit, making room for the unloader on its left side.
--- @return table, number, number, number, number node, xOffset, zOffset, width, length : the area to avoid is
--- a length x width m rectangle, the rectangle's bottom right corner (when looking from node) is at xOffset/zOffset
--- from node.
function AIDriveStrategyCombineCourse:getAreaToAvoid()
    if self:isWaitingForUnloadAfterPulledBack() then
        local xOffset = self:getWorkWidth() / 2
        local zOffset = 0
        local length = self.pullBackDistanceEnd
        local width = self.pullBackRightSideOffset
        return PathfinderUtil.NodeArea(AIUtil.getDirectionNode(self.vehicle), xOffset, zOffset, width, length)
    end
end

function AIDriveStrategyCombineCourse:createPullBackReturnCourse()
    -- nothing fancy here either, just move forward a few meters before returning to the fieldwork course
    local referenceNode = AIUtil.getDirectionNode(self.vehicle)
    return Course.createFromNode(self.vehicle, referenceNode, 0, 0, 6, 2, false)
end

--- Create a temporary course to make a pocket in the fruit on the right (or left), so we can move into that pocket and
--- wait for the unload there. This way the unload tractor does not have to leave the field.
--- We create a temporary course to reverse back far enough. After that, we return to the main course but
--- set an offset to the right (or left)
function AIDriveStrategyCombineCourse:createPocketCourse()
    local startIx = self.ppc:getLastPassedWaypointIx() or self.ppc:getCurrentWaypointIx()
    -- find the waypoint we want to back up to
    local backIx = self.course:getPreviousWaypointIxWithinDistance(startIx, self.pocketReverseDistance)
    if not backIx then
        return nil
    end
    -- this is where we'll stop in the pocket for unload
    self.unloadInPocketIx = startIx - 2
    -- this where we are back on track after returning from the pocket
    self.returnedFromPocketIx = self.ppc:getCurrentWaypointIx()
    self:debug('Backing up %.1f meters from waypoint %d to %d to make a pocket', self.pocketReverseDistance, startIx, backIx)
    if startIx - backIx > 2 then
        local pocketReverseWaypoints = {}
        for i = startIx, backIx, -1 do
            if self.course:isTurnStartAtIx(i) then
                self:debug('There is a turn behind me at waypoint %d, no pocket', i)
                return nil
            end
            local x, _, z = self.course:getWaypointPosition(i)
            table.insert(pocketReverseWaypoints, { x = x, z = z, rev = true })
        end
        return Course(self.vehicle, pocketReverseWaypoints, true), backIx + 1
    else
        self:debug('Not enough waypoints behind me, no pocket')
        return nil
    end
end

--- Only allow fuel save, if no trailer is under the pipe and we are waiting for unloading.
function AIDriveStrategyCombineCourse:isFuelSaveAllowed()
    --- Enables fuel save, while waiting for the rain to stop.
    if self.combine:getIsThreshingDuringRain() then
        return true
    end
    return not self.pipeController:isFillableTrailerUnderPipe()
            and self:isWaitingForUnload() or self:isChopperWaitingForUnloader()
end

--- Check if the vehicle should stop during a turn (for example while it
--- is held for unloading or waiting for the straw swath to stop
function AIDriveStrategyCombineCourse:shouldHoldInTurnManeuver()
    local discharging = self:isDischarging() and not self:isChopper()
    local isFinishingRow = self.aiTurn and self.aiTurn:isFinishingRow()
    local waitForStraw = self.combine.strawPSenabled and not isFinishingRow
    self:debugSparse('discharging %s, held for unload %s, straw active %s, finishing row = %s',
            tostring(discharging), tostring(self.heldForUnloadRefill), tostring(self.combine.strawPSenabled), tostring(isFinishingRow))
    return discharging or self.heldForUnloadRefill or waitForStraw
end

--- Should we return to the first point of the course after we are done?
function AIDriveStrategyCombineCourse:shouldReturnToFirstPoint()
    -- Combines stay where they are after finishing work
    -- TODO: call unload driver
    return false
end

--- Interface for the unloader and AutoDrive
---@return boolean true when the combine is waiting to be unloaded (and won't move until the unloader gets there)
function AIDriveStrategyCombineCourse:isWaitingForUnload()
    return self.state == self.states.UNLOADING_ON_FIELD and
            (self.unloadState == self.states.WAITING_FOR_UNLOAD_ON_FIELD or
                    self.unloadState == self.states.WAITING_FOR_UNLOAD_IN_POCKET or
                    self.unloadState == self.states.WAITING_FOR_UNLOAD_AFTER_PULLED_BACK or
                    self.unloadState == self.states.WAITING_FOR_UNLOAD_AFTER_FIELDWORK_ENDED or
                    self.unloadState == self.states.WAITING_FOR_UNLOAD_BEFORE_STARTING_NEXT_ROW)
end

--- Interface for AutoDrive
---@return boolean true when the combine is waiting to be unloaded after it ended the course
function AIDriveStrategyCombineCourse:isWaitingForUnloadAfterCourseEnded()
    return self.state == self.states.UNLOADING_ON_FIELD and
            self.unloadState == self.states.WAITING_FOR_UNLOAD_AFTER_FIELDWORK_ENDED
end

function AIDriveStrategyCombineCourse:isWaitingInPocket()
    return self.state == self.states.UNLOADING_ON_FIELD and
            self.unloadState == self.states.WAITING_FOR_UNLOAD_IN_POCKET
end

--- Interface for Mode 2
---@return boolean true when the combine is waiting to after it pulled back.
function AIDriveStrategyCombineCourse:isWaitingForUnloadAfterPulledBack()
    return self.state == self.states.UNLOADING_ON_FIELD and
            self.unloadState == self.states.WAITING_FOR_UNLOAD_AFTER_PULLED_BACK
end

---@return boolean the combine is about to turn
function AIDriveStrategyCombineCourse:isAboutToTurn()
    if self.state == self.states.WORKING and self.course then
        return self.course:isCloseToNextTurn(10)
    else
        return false
    end
end

--- Can the cutter be turned off ?
function AIDriveStrategyCombineCourse:getCanCutterBeTurnedOff()
    return self:isWaitingForUnload() or self.state == self.states.UNLOADING_ON_FIELD and self:isUnloadStateOneOf(self.selfUnloadStates)
end

-----------------------------------------------------------------------------------------------------------------------
--- Turns
-----------------------------------------------------------------------------------------------------------------------

--- Will we be driving forward only (not reversing) during a turn
function AIDriveStrategyCombineCourse:isTurnForwardOnly()
    return self:isTurning() and self.aiTurn and self.aiTurn:isForwardOnly()
end

function AIDriveStrategyCombineCourse:getTurnCourse()
    return self.aiTurn and self.aiTurn:getCourse()
end

function AIDriveStrategyCombineCourse:startTurn(ix)
    self:debug('Starting a combine turn.')

    self.turnContext = TurnContext(self.vehicle, self.course, ix, ix + 1, self.turnNodes, self:getWorkWidth(),
            self.frontMarkerDistance, self.backMarkerDistance,
            self:getTurnEndSideOffset(), self:getTurnEndForwardOffset())

    -- Combines drive special headland corner maneuvers, except potato and sugarbeet harvesters
    if self.turnContext:isHeadlandCorner() then
        if self:isPotatoOrSugarBeetHarvester() then
            self:debug('Headland turn but this harvester uses normal turn maneuvers.')
            AIDriveStrategyCombineCourse.superClass().startTurn(self, ix)
        elseif self.course:isOnConnectingTrack(ix) then
            self:debug('Headland turn but this a connecting track, use normal turn maneuvers.')
            AIDriveStrategyCombineCourse.superClass().startTurn(self, ix)
        elseif self.course:isOnOutermostHeadland(ix) and self:isTurnOnFieldActive() then
            self:debug('Creating a pocket in the corner so the combine stays on the field during the turn')
            self.aiTurn = CombinePocketHeadlandTurn(self.vehicle, self, self.ppc, self.turnContext,
                    self.course, self:getWorkWidth())
            self.state = self.states.TURNING
            self.ppc:setShortLookaheadDistance()
        else
            self:debug('Use combine headland turn.')
            self.aiTurn = CombineHeadlandTurn(self.vehicle, self, self.ppc, self.turnContext)
            self.state = self.states.TURNING
        end
    else
        self:debug('Non headland turn.')
        AIDriveStrategyCombineCourse.superClass().startTurn(self, ix)
    end
end

function AIDriveStrategyCombineCourse:isTurning()
    return self.state == self.states.TURNING
end

-- Turning except in the ending turn phase which isn't really a turn, it is rather 'starting row'
function AIDriveStrategyCombineCourse:isTurningButNotEndingTurn()
    return self:isTurning() and self.aiTurn and not self.aiTurn:isEndingTurn()
end

function AIDriveStrategyCombineCourse:isFinishingRow()
    return self:isTurning() and self.aiTurn and self.aiTurn:isFinishingRow()
end

function AIDriveStrategyCombineCourse:getTurnStartWpIx()
    return self.turnContext and self.turnContext.turnStartWpIx or nil
end

function AIDriveStrategyCombineCourse:isTurningOnHeadland()
    return self.state == self.states.TURNING and self.turnContext and self.turnContext:isHeadlandCorner()
end

function AIDriveStrategyCombineCourse:isTurningLeft()
    return self.state == self.states.TURNING and self.turnContext and self.turnContext:isLeftTurn()
end

function AIDriveStrategyCombineCourse:getFieldworkCourse()
    return self.course
end

function AIDriveStrategyCombineCourse:isChopper()
    return self.combineController:isChopper()
end

-----------------------------------------------------------------------------------------------------------------------
--- Pipe handling
-----------------------------------------------------------------------------------------------------------------------
function AIDriveStrategyCombineCourse:handlePipe(dt)
    if self:isChopper() then
        self:handleChopperPipe()
    else
        self:handleCombinePipe(dt)
    end
end

function AIDriveStrategyCombineCourse:handleCombinePipe(dt)

    if self.pipeController:isFillableTrailerUnderPipe() or self:isAutoDriveWaitingForPipe() then
        self.pipeController:openPipe()
    else
        self.pipeController:closePipe(true)
    end
end

--- Not exactly sure what this does, but without this the chopper just won't move.
--- Copied from AIDriveStrategyCombine:update()
function AIDriveStrategyCombineCourse:updateChopperFillType()
    if self:isChopper() then
        self.combineController:updateChopperFillType()
    end
end

-- TODO: move this to the PipeController?
function AIDriveStrategyCombineCourse:handleChopperPipe()
    self.pipeController:handleChopperPipe()

    local trailer = self.pipeController:getClosestObject()
    local dischargeNode = self.pipeController:getDischargeNode()
    local targetObject = self.pipeController:getDischargeObject()
    self:debugSparse('%s %s', dischargeNode, self:isAnyWorkAreaProcessing())
    if not self.waitingForTrailer and self:isAnyWorkAreaProcessing() and (targetObject == nil or trailer == nil) then
        self:debug('Chopper waiting for trailer, discharge node %s, target object %s, trailer %s',
                tostring(dischargeNode), tostring(targetObject), tostring(trailer))
        self.waitingForTrailer = true
    end
    if self.waitingForTrailer then
        self:setMaxSpeed(0)
        if not (targetObject == nil or trailer == nil) then
            self:debug('Chopper has trailer now, continue')
            self.waitingForTrailer = false
        end
    end
end

function AIDriveStrategyCombineCourse:isChopperWaitingForUnloader()
    return self.waitingForTrailer
end

function AIDriveStrategyCombineCourse:isAnyWorkAreaProcessing()
    for _, implement in pairs(self.vehicle:getChildVehicles()) do
        if implement.spec_workArea ~= nil then
            for i, workArea in pairs(implement.spec_workArea.workAreas) do
                if implement:getIsWorkAreaProcessing(workArea) then
                    return true
                end
            end
        end
    end
    return false
end

function AIDriveStrategyCombineCourse:isPipeMoving()
    return self.pipeController:isPipeMoving()
end

function AIDriveStrategyCombineCourse:canLoadTrailer(trailer)
    local fillType = self:getFillType()
    return FillLevelManager.canLoadTrailer(trailer, fillType)
end

function AIDriveStrategyCombineCourse:getCurrentDischargeNode()
    return self.pipeController:getDischargeNode()
end

function AIDriveStrategyCombineCourse:getFillLevelPercentage()
    return self.combineController:getFillLevelPercentage()
end

--- Support for AutoDrive mod: they'll only find us if we open the pipe
function AIDriveStrategyCombineCourse:isAutoDriveWaitingForPipe()
    return self.vehicle.spec_autodrive and self.vehicle.spec_autodrive.combineIsCallingDriver and
            self.vehicle.spec_autodrive:combineIsCallingDriver(self.vehicle)
end

function AIDriveStrategyCombineCourse:shouldStopForUnloading()
    if self.settings.stopForUnload:getValue() then
        if self:isDischarging() and not self.stopDisabledAfterEmpty:get() then
            -- stop only if the pipe is discharging AND we have been emptied a while ago.
            -- this makes sure the combine will start driving after it is emptied but the trailer
            -- is still under the pipe
            return true
        end
    end
    return false
end

function AIDriveStrategyCombineCourse:getFillType()
    return self.pipeController:getFillType()
end

-- even if there is a trailer in range, we should not start moving until the pipe is turned towards the
-- trailer and can start discharging. This returning true does not mean there's a trailer under the pipe,
-- this seems more like for choppers to check if there's a potential target around
function AIDriveStrategyCombineCourse:canDischarge()
    return self.pipeController:getDischargeObject()
end

function AIDriveStrategyCombineCourse:isDischarging()
    return self.pipeController:isDischarging()
end

function AIDriveStrategyCombineCourse:isPotatoOrSugarBeetHarvester()
    for i, fillUnit in ipairs(self.vehicle:getFillUnits()) do
        if self.vehicle:getFillUnitSupportsFillType(i, FillType.POTATO) or
                self.vehicle:getFillUnitSupportsFillType(i, FillType.SUGARBEET) then
            self:debug('This is a potato or sugar beet harvester.')
            return true
        end
    end
    return false
end

-----------------------------------------------------------------------------------------------------------------------
--- Self unload
-----------------------------------------------------------------------------------------------------------------------
--- Find a path to the best trailer to unload
function AIDriveStrategyCombineCourse:startSelfUnload()

    if not self.pathfinder or not self.pathfinder:isActive() then
        self:rememberCourse(self.fieldWorkCourse, self:getBestWaypointToContinueFieldWork())
        self.pathfindingStartedAt = g_currentMission.time
        self.courseAfterPathfinding = nil
        self.waypointIxAfterPathfinding = nil

        local targetNode, alignLength, offsetX = SelfUnloadHelper:getTargetParameters(self.fieldWorkCourse:getFieldPolygon(),
                self.vehicle,
                self:getFillType(),
                self.pipeController)

        if not targetNode then
            return false
        end

        -- little straight section parallel to the trailer to align better
        self.selfUnloadAlignCourse = Course.createFromNode(self.vehicle, targetNode,
                offsetX, -alignLength + 1, -self.pipeController:getPipeOffsetZ() - 1, 1, false)

        local fieldNum = CpFieldUtil.getFieldNumUnderVehicle(self.vehicle)
        local done, path
        -- require full accuracy from pathfinder as we must exactly line up with the trailer
        self.pathfinder, done, path = PathfinderUtil.startPathfindingFromVehicleToNode(
                self.vehicle, targetNode, offsetX, -alignLength,
                self:getAllowReversePathfinding(),
        -- use a low field penalty to encourage the pathfinder to bridge that gap between the field and the trailer
                fieldNum, {}, nil, 0.1, nil, true)
        if done then
            return self:onPathfindingDoneBeforeSelfUnload(path)
        else
            self:setPathfindingDoneCallback(self, self.onPathfindingDoneBeforeSelfUnload)
        end
    else
        self:debug('Pathfinder already active')
    end
    return true
end

function AIDriveStrategyCombineCourse:onPathfindingDoneBeforeSelfUnload(path)
    if path and #path > 2 then
        self:debug('Pathfinding to self unload finished with %d waypoints (%d ms)',
                #path, g_currentMission.time - (self.pathfindingStartedAt or 0))
        local selfUnloadCourse = Course(self.vehicle, CourseGenerator.pointsToXzInPlace(path), true)
        if self.selfUnloadAlignCourse then
            selfUnloadCourse:append(self.selfUnloadAlignCourse)
            self.selfUnloadAlignCourse = nil
        end
        self:startCourse(selfUnloadCourse, 1)
        return true
    else
        self:debug('No path found to self unload in %d ms',
                g_currentMission.time - (self.pathfindingStartedAt or 0))
        if self.unloadState == self.states.DRIVING_TO_SELF_UNLOAD then
            self.unloadState = self.states.WAITING_FOR_UNLOAD_ON_FIELD
        elseif self.unloadState == self.states.DRIVING_TO_SELF_UNLOAD_AFTER_FIELDWORK_ENDED then
            self.unloadState = self.states.WAITING_FOR_UNLOAD_AFTER_FIELDWORK_ENDED
        end
        return false
    end
end

--- Back to fieldwork after self unloading
function AIDriveStrategyCombineCourse:returnToFieldworkAfterSelfUnload()
    if not self.pathfinder or not self.pathfinder:isActive() then
        self.pathfindingStartedAt = g_currentMission.time
        local fieldWorkCourse, ix = self:getRememberedCourseAndIx()
        self:debug('Return to fieldwork after self unload at waypoint %d', ix)
        local done, path
        self.pathfinder, done, path = PathfinderUtil.startPathfindingFromVehicleToWaypoint(
                self.vehicle, fieldWorkCourse, ix, 0, 0,
                self:getAllowReversePathfinding(), nil)
        if done then
            return self:onPathfindingDoneAfterSelfUnload(path)
        else
            self:setPathfindingDoneCallback(self, self.onPathfindingDoneAfterSelfUnload)
        end
    else
        self:debug('Pathfinder already active')
    end
    return true
end

function AIDriveStrategyCombineCourse:onPathfindingDoneAfterSelfUnload(path)
    -- TODO: for some reason, the combine lowers the header while unloading, that should be fixed, for now, raise it here
    self:raiseImplements()
    if path and #path > 2 then
        self:debug('Pathfinding to return to fieldwork after self unload finished with %d waypoints (%d ms)',
                #path, g_currentMission.time - (self.pathfindingStartedAt or 0))
        local returnCourse = Course(self.vehicle, CourseGenerator.pointsToXzInPlace(path), true)
        self:startCourse(returnCourse, 1)
        return true
    else
        self:debug('No path found to return to fieldwork after self unload (%d ms)',
                g_currentMission.time - (self.pathfindingStartedAt or 0))
        local course, ix = self:getRememberedCourseAndIx()
        local returnCourse = AlignmentCourse(self.vehicle, self.vehicle:getAIDirectionNode(),
                self.turningRadius, course, ix, 0):getCourse()
        if returnCourse then
            self:debug('Start an alignment course to fieldwork waypoint %d', ix)
            self:startCourse(returnCourse, 1)
        else
            self:debug('Could not generate alignment course to fieldwork waypoint %d, starting course directly', ix)
            self:startRememberedCourse()
        end
        return false
    end
end

function AIDriveStrategyCombineCourse:continueSelfUnloadToNextTrailer()
    local fillLevel = self.combineController:getFillLevel()
    if fillLevel > 20 then
        self:debug('Self unloading finished, but fill level is %.1f, is there another trailer around we can unload to?', fillLevel)
        if self:startSelfUnload() then
            self:raiseImplements()
            self.state = self.states.UNLOADING_ON_FIELD
            self.unloadState = self.states.DRIVING_TO_SELF_UNLOAD
            self.ppc:setShortLookaheadDistance()
            return true
        end
    end
    return false
end

--- Let unloaders register for events. This is different from the CombineUnloadManager registration, these
--- events are for the low level coordination between the combine and its unloader(s). CombineUnloadManager
--- takes care about coordinating the work between multiple combines.
function AIDriveStrategyCombineCourse:clearAllUnloaderInformation()
    self:cancelRendezvous()
    self.unloader:reset()
end

--- Register a combine unload AI driver for notification about combine events
--- Unloaders can renew their registration as often as they want to make sure they remain registered.
---@param driver AIDriveStrategyUnloadCombine
function AIDriveStrategyCombineCourse:registerUnloader(driver)
    self.unloader:set(driver, 1000)
end

--- Deregister a combine unload AI driver from notifications
---@param driver CombineUnloadAIDriver
function AIDriveStrategyCombineCourse:deregisterUnloader(driver, noEventSend)
    self:cancelRendezvous()
    self.unloader:reset()
end

--- Make life easier for unloaders, increases reach of the pipe
--- Old code ??
function AIDriveStrategyCombineCourse:fixMaxRotationLimit()
    if self.pipe then
        local lastPipeNode = self.pipe.nodes and self.pipe.nodes[#self.pipe.nodes]
        if self:isChopper() and lastPipeNode and lastPipeNode.maxRotationLimits then
            self.oldLastPipeNodeMaxRotationLimit = lastPipeNode.maxRotationLimits
            self:debug('Chopper fix maxRotationLimits, old Values: x=%s, y= %s, z =%s', tostring(lastPipeNode.maxRotationLimits[1]), tostring(lastPipeNode.maxRotationLimits[2]), tostring(lastPipeNode.maxRotationLimits[3]))
            lastPipeNode.maxRotationLimits = nil
        end
    end
end

--- Old code ??
function AIDriveStrategyCombineCourse:resetFixMaxRotationLimit()
    if self.pipe then
        local lastPipeNode = self.pipe.nodes and self.pipe.nodes[#self.pipe.nodes]
        if lastPipeNode and self.oldLastPipeNodeMaxRotationLimit then
            lastPipeNode.maxRotationLimits = self.oldLastPipeNodeMaxRotationLimit
            self:debug('Chopper: reset maxRotationLimits is x=%s, y= %s, z =%s', tostring(lastPipeNode.maxRotationLimits[1]), tostring(lastPipeNode.maxRotationLimits[3]), tostring(lastPipeNode.maxRotationLimits[3]))
            self.oldLastPipeNodeMaxRotationLimit = nil
        end
    end
end

--- Offset of the pipe from the combine implement's root node
---@param additionalOffsetX number add this to the offsetX if you don't want to be directly under the pipe. If
--- greater than 0 -> to the left, less than zero -> to the right
---@param additionalOffsetZ number forward (>0)/backward (<0) offset from the pipe
function AIDriveStrategyCombineCourse:getPipeOffset(additionalOffsetX, additionalOffsetZ)
    local pipeOffsetX, pipeOffsetZ = self.pipeController:getPipeOffset()
    return pipeOffsetX + (additionalOffsetX or 0), pipeOffsetZ + (additionalOffsetZ or 0)
end

--- Pipe side offset relative to course. This is to help the unloader
--- to find the pipe when we are waiting in a pocket
function AIDriveStrategyCombineCourse:getPipeOffsetFromCourse()
    return self.pipeController:getPipeOffset()
end

function AIDriveStrategyCombineCourse:initUnloadStates()
    self.safeUnloadFieldworkStates = {
        self.states.WORKING,
        self.states.WAITING_FOR_LOWER,
        self.states.WAITING_FOR_LOWER_DELAYED,
        self.states.WAITING_FOR_STOP,
    }

    self.safeFieldworkUnloadOrRefillStates = {
        self.states.WAITING_FOR_UNLOAD_AFTER_FIELDWORK_ENDED,
        self.states.WAITING_FOR_UNLOAD_ON_FIELD,
        self.states.WAITING_FOR_UNLOAD_AFTER_PULLED_BACK,
        self.states.WAITING_FOR_UNLOAD_IN_POCKET,
        self.states.WAITING_FOR_UNLOAD_BEFORE_STARTING_NEXT_ROW
    }

    self.willWaitForUnloadToFinishFieldworkStates = {
        self.states.WAITING_FOR_UNLOAD_AFTER_PULLED_BACK,
        self.states.WAITING_FOR_UNLOAD_IN_POCKET,
        self.states.WAITING_FOR_UNLOAD_AFTER_FIELDWORK_ENDED,
        self.states.WAITING_FOR_UNLOAD_BEFORE_STARTING_NEXT_ROW
    }
    --- All self unload states.
    self.selfUnloadStates = {
        self.states.DRIVING_TO_SELF_UNLOAD,
        self.states.SELF_UNLOADING,
        self.states.SELF_UNLOADING_WAITING_FOR_DISCHARGE,
        self.states.DRIVING_TO_SELF_UNLOAD_AFTER_FIELDWORK_ENDED,
        self.states.SELF_UNLOADING_AFTER_FIELDWORK_ENDED,
        self.states.SELF_UNLOADING_AFTER_FIELDWORK_ENDED_WAITING_FOR_DISCHARGE,
        self.states.RETURNING_FROM_SELF_UNLOAD
    }
end

function AIDriveStrategyCombineCourse:isStateOneOf(myState, states)
    return CpUtil.isStateOneOf(myState, states)
end

function AIDriveStrategyCombineCourse:isUnloadStateOneOf(states)
    return self:isStateOneOf(self.unloadState, states)
end

-- TODO: this whole logic is more relevant to the unloader maybe move it there?
function AIDriveStrategyCombineCourse:getClosestFieldworkWaypointIx()
    if self:isTurning() then
        if self.turnContext then
            -- send turn start wp, unloader will decide if it needs to move it to the turn end or not
            return self.turnContext.turnStartWpIx
        else
            -- if for whatever reason we don't have a turn context, current waypoint is ok
            return self.course:getCurrentWaypointIx()
        end
    elseif self.course:isTemporary() then
        return self.course:getLastPassedWaypointIx()
    else
        -- if currently on the fieldwork course, this is the best estimate
        return self.ppc:getRelevantWaypointIx()
    end
end

--- Maneuvering means turning or working on a pocket or pulling back due to the pipe in fruit
--- We don't want to get too close to a maneuvering combine until it is done
function AIDriveStrategyCombineCourse:isManeuvering()
    return self:isTurning() or
            (
                    self.state == self.states.UNLOADING_ON_FIELD and
                            not self:isUnloadStateOneOf(self.safeFieldworkUnloadOrRefillStates)
            )
end

function AIDriveStrategyCombineCourse:isOnHeadland(n)
    return self.course:isOnHeadland(self.course:getCurrentWaypointIx(), n)
end

--- Are we ready for an unloader?
--- @param noUnloadWithPipeInFruit boolean pipe must not be in fruit for unload
function AIDriveStrategyCombineCourse:isReadyToUnload(noUnloadWithPipeInFruit)
    -- no unloading when not in a safe state (like turning)
    -- in these states we are always ready
    if self:willWaitForUnloadToFinish() then
        return true
    end

    -- but, if we are full and waiting for unload, we have no choice, we must be ready ...
    if self.state == self.states.UNLOADING_ON_FIELD and self.unloadState == self.states.WAITING_FOR_UNLOAD_ON_FIELD then
        return true
    end

    -- pipe is in the fruit.
    if noUnloadWithPipeInFruit and self:isPipeInFruit() then
        self:debugSparse('isReadyToUnload(): pipe in fruit')
        return false
    end

    if not self.course then
        self:debugSparse('isReadyToUnload(): has no fieldwork course')
        return false
    end

    -- around a turn, for example already working on the next row but not done with the turn yet

    if self.course:isCloseToNextTurn(10) then
        self:debugSparse('isReadyToUnload(): too close to turn')
        return false
    end
    -- safe default, better than block unloading
    self:debugSparse('isReadyToUnload(): defaulting to ready to unload')
    return true
end

--- Will not move until unload is done? Unloaders like to know this.
function AIDriveStrategyCombineCourse:willWaitForUnloadToFinish()
    return self.state == self.states.UNLOADING_ON_FIELD and
            ((self.settings.stopForUnload:getValue() and self.unloadState == self.states.WAITING_FOR_UNLOAD_ON_FIELD) or
                    self.unloadState == self.states.WAITING_FOR_UNLOAD_IN_POCKET or
                    self.unloadState == self.states.WAITING_FOR_UNLOAD_AFTER_PULLED_BACK or
                    self.unloadState == self.states.WAITING_FOR_UNLOAD_AFTER_FIELDWORK_ENDED)
end

--- Try to not hit our Unloader after Pocket.
function AIDriveStrategyCombineCourse:isAboutToReturnFromPocket()
    return self.unloadState == self.states.WAITING_FOR_UNLOAD_IN_POCKET or
            (self.unloadState == self.states.WAITING_FOR_UNLOADER_TO_LEAVE and
                    self.stateBeforeWaitingForUnloaderToLeave == self.states.WAITING_FOR_UNLOAD_IN_POCKET)
end

------------------------------------------------------------------------------------------------------------------------
--- Proximity
------------------------------------------------------------------------------------------------------------------------

AIDriveStrategyCombineCourse.maxBackDistance = 10

function AIDriveStrategyCombineCourse:getMeasuredBackDistance()
    return self.measuredBackDistance
end

--- Determine how far the back of the combine is from the direction node
-- TODO: attached/towed harvesters
function AIDriveStrategyCombineCourse:measureBackDistance()
    self.measuredBackDistance = 0
    -- raycast from a point behind the vehicle forward towards the direction node
    local nx, ny, nz = localDirectionToWorld(self.vehicle.rootNode, 0, 0, 1)
    local x, y, z = localToWorld(self.vehicle.rootNode, 0, 1.5, -self.maxBackDistance)
    raycastAll(x, y, z, nx, ny, nz, 'raycastBackCallback', self.maxBackDistance, self)
end

-- I believe this tries to figure out how far the back of a combine is from its direction node.
function AIDriveStrategyCombineCourse:raycastBackCallback(hitObjectId, x, y, z, distance, nx, ny, nz, subShapeIndex)
    if hitObjectId ~= 0 then
        local object = g_currentMission:getNodeObject(hitObjectId)
        if object and object == self.vehicle then
            local d = self.maxBackDistance - distance
            if d > self.measuredBackDistance then
                self.measuredBackDistance = d
                self:debug('Measured back distance is %.1f m', self.measuredBackDistance)
            end
        else
            return true
        end
    end
end

function AIDriveStrategyCombineCourse:onDraw()
    if CpDebug:isChannelActive(CpDebug.DBG_IMPLEMENTS, self.vehicle) then

        local dischargeNode = self:getCurrentDischargeNode()
        if dischargeNode then
            local dx, _, dz = localToLocal(dischargeNode.node, self.vehicle:getAIDirectionNode(), 0, 0, 0)
            DebugUtil.drawDebugNode(dischargeNode.node, string.format('discharge\n%.1f %.1f', dx, dz))
        end
    end

    if CpDebug:isChannelActive(CpDebug.DBG_PATHFINDER, self.vehicle) then
        local areaToAvoid = self:getAreaToAvoid()
        if areaToAvoid then
            local x, y, z = localToWorld(areaToAvoid.node, areaToAvoid.xOffset, 0, areaToAvoid.zOffset)
            DebugUtil.drawDebugLine(x, y + 1.2, z, 10, 10, 10, x, y + 1.2, z + areaToAvoid.length)
            DebugUtil.drawDebugLine(x + areaToAvoid.width, y + 1.2, z, 10, 10, 10, x + areaToAvoid.width, y + 1.2, z + areaToAvoid.length)
        end
    end

end

-- For combines, we use the collision trigger of the header to cover the whole vehicle width
function AIDriveStrategyCombineCourse:createTrafficConflictDetector()
    -- (not everything running as combine has a cutter, for instance the Krone Premos)
    if self.combine.attachedCutters then
        for cutter, _ in pairs(self.combine.attachedCutters) do
            -- attachedCutters is indexed by the cutter, not an integer
            self.trafficConflictDetector = TrafficConflictDetector(self.vehicle, self.course, cutter)
            -- for now, combines ignore traffic conflicts (but still provide the detector boxes for other vehicles)
            self.trafficConflictDetector:disableSpeedControl()
            return
        end
    end
    self.trafficConflictDetector = TrafficConflictDetector(self.vehicle, self.course)
    -- for now, combines ignore traffic conflicts (but still provide the detector boxes for other vehicles)
    self.trafficConflictDetector:disableSpeedControl()
end

--- Don't slow down when discharging. This is a workaround for unloaders getting into the proximity
--- sensor's range.
function AIDriveStrategyCombineCourse:isProximitySlowDownEnabled(vehicle)
    -- if not on fieldwork, always enable slowing down
    if self.state ~= self.states.WORKING then
        return true
    end
    -- TODO: check if vehicle is player or AD driven, or even better, check if this is the vehicle
    -- we are discharging into
    if vehicle and self:isDischarging() then
        self:debugSparse('discharging, not slowing down for nearby %s', CpUtil.getName(vehicle))
        return false
    else
        return true
    end
end

--- This is called by the proximity controller if we have been blocked by another vehicle for a while
function AIDriveStrategyCombineCourse:onBlockingVehicle(vehicle, isBack)
    if isBack then
        self:debug('Proximity sensor: blocking vehicle %s behind us', CpUtil.getName(vehicle))
        self:checkBlockingUnloader()
    else
        self:debug('Proximity sensor: blocking vehicle %s in front of us', CpUtil.getName(vehicle))
        local strategy = vehicle.getCpDriveStrategy and vehicle:getCpDriveStrategy()
        if strategy and strategy.requestToMoveOutOfWay then
            strategy:requestToMoveOutOfWay(self.vehicle, isBack)
        end
    end
end

--- Check if the unloader is blocking us when we are reversing in a turn and immediately notify it
function AIDriveStrategyCombineCourse:checkBlockingUnloader()
    if not self.ppc:isReversing() and not AIUtil.isReversing(self.vehicle) then
        return
    end
    local d, blockingVehicle = self.proximityController:checkBlockingVehicleBack()
    if d < 1000 and blockingVehicle and AIUtil.isStopped(self.vehicle) and
            not self:isWaitingForUnload() and not self:shouldHoldInTurnManeuver() then
        -- try requesting only if the unloader really blocks us, that is we are actually backing up but
        -- can't move because of the unloader, and not when we are stopped for other reasons
        self:debugSparse('Can\'t reverse, %s at %.1f m is blocking', blockingVehicle:getName(), d)
        local strategy = blockingVehicle.getCpDriveStrategy and blockingVehicle:getCpDriveStrategy()
        if strategy and strategy.requestToBackupForReversingCombine then
            strategy:requestToBackupForReversingCombine(self.vehicle)
        end
    end
end

function AIDriveStrategyCombineCourse:getWorkingToolPositionsSetting()
    local setting = self.settings.pipeToolPositions
    return setting:getHasMoveablePipe() and setting:hasValidToolPositions() and setting
end

------------------------------------------------------------------------------------------------------------------------
--- Info texts, makes sure the unloadState also gets checked.
---------------------------------------------------------------------------------------------------------------------------

function AIDriveStrategyCombineCourse:updateInfoTexts()
    for infoText, states in pairs(self.registeredInfoTexts) do
        if states.states[self.state] and states.unloadStates[self.unloadState] then
            self:setInfoText(infoText)
        else
            self:clearInfoText(infoText)
        end
    end
end