--- Open/close combine and auger wagon pipes
--- Controls moveable pipes and raises the base pipe rod to the maximum.
---@class PipeController : ImplementController
PipeController = CpObject(ImplementController)
PipeController.MAX_ROT_SPEED = 0.6
PipeController.MIN_ROT_SPEED = 0.1
-- chopper: 0= pipe folded (really? isn't this 1?), 2,= autoaiming;  combine: 1 = closed  2= open
PipeController.PIPE_STATE_MOVING = 0
PipeController.PIPE_STATE_CLOSED = 1
PipeController.PIPE_STATE_OPEN = 2

function PipeController:init(vehicle, implement)
    ImplementController.init(self, vehicle, implement)
    self.pipeSpec = self.implement.spec_pipe
    self.cylinderedSpec = self.implement.spec_cylindered
    self.dischargeSpec = self.implement.spec_dischargeable
    self.foldableSpec = self.implement.spec_foldable

    self:setupMoveablePipe()

    self.pipeOffsetX, self.pipeOffsetZ = 0, 0
    self.pipeOnLeftSide = true
    self:measurePipeProperties()

    self.isDischargingTimer = CpTemporaryObject(false)
    self.isDischargingToGround = false
    self.dischargeData = {}
end

function PipeController:getDriveData()
    local maxSpeed
    if self.isDischargingToGround then
        if self.isDischargingTimer:get() then
            --- Waiting until the discharging stopped or 
            --- the trailer is empty and the folding animation is playing.
            maxSpeed = 0
            self:debugSparse("Waiting for unloading!")
        end
        if self.implement:getIsAIPreparingToDrive() or self:isPipeMoving() then
            --- Pipe is unfolding/moving.
            maxSpeed = 0
            self:debugSparse("Waiting for pipe unfolding!")
        end
    end
    return nil, nil, nil, maxSpeed
end

function PipeController:update(dt)
    if self.isDischargingToGround then
        if self:isEmpty() and self.implement:getAIHasFinishedDischarge(self.dischargeData.dischargeNode) then 
            self:finishedDischarge()
            return
        end
        if self.implement:getCanDischargeToGround(self.dischargeData.dischargeNode) then 
            --- Update discharge timer
            self.isDischargingTimer:set(true, 500)
            if not self:isDischarging() then 
                self.implement:setDischargeState(Dischargeable.DISCHARGE_STATE_GROUND)
            end
        else 
            self.implement:setDischargeState(Dischargeable.DISCHARGE_STATE_OFF)
        end
    end
    self:updateMoveablePipe(dt)
end

function PipeController:needToOpenPipe()
    -- some pipes are not movable (like potato harvesters)
    return self.pipeSpec.numStates > 1
end

function PipeController:openPipe()
    if self:needToOpenPipe() and self.implement:getIsPipeStateChangeAllowed(PipeController.PIPE_STATE_OPEN) and
            self.pipeSpec.currentState ~= PipeController.PIPE_STATE_MOVING and
            self.pipeSpec.currentState ~= PipeController.PIPE_STATE_OPEN then
        self:debug('Opening pipe')
        self.implement:setPipeState(PipeController.PIPE_STATE_OPEN)
    end
end

---@param checkForObjectsUnderPipe boolean check if there is a trigger object (like a trailer) under the pipe and
---                                        only close if there aren't any
function PipeController:closePipe(checkForObjectsUnderPipe)
    local okToClose = self.pipeSpec.numObjectsInTriggers <= 0 or not checkForObjectsUnderPipe
    if self:needToOpenPipe() and okToClose and self.implement:getIsPipeStateChangeAllowed(PipeController.PIPE_STATE_CLOSED) and -- only close when there are nothing under the pipe
            self.pipeSpec.currentState ~= PipeController.PIPE_STATE_MOVING and
            self.pipeSpec.currentState ~= PipeController.PIPE_STATE_CLOSED then
        self:debug('Closing pipe')
        self.implement:setPipeState(PipeController.PIPE_STATE_CLOSED)
    end
end

function PipeController:isPipeMoving()
    if not self:needToOpenPipe() then 
        return false
    end
    return self.pipeSpec.currentState == PipeController.PIPE_STATE_MOVING 
end

function PipeController:isPipeOpen()
    return self:needToOpenPipe() and self.pipeSpec.currentState == PipeController.PIPE_STATE_OPEN
end

function PipeController:getFillType()
    local dischargeNode = self.implement:getDischargeNodeByIndex(self.implement:getPipeDischargeNodeIndex())
    if dischargeNode then
        return self.implement:getFillUnitFillType(dischargeNode.fillUnitIndex)
    end
    return nil
end


function PipeController:isFillableTrailerUnderPipe()
    for trailer, value in pairs(self.pipeSpec.objectsInTriggers) do
        if value > 0 then
            if FillLevelManager.canLoadTrailer(trailer, self:getFillType()) then
                return true
            end
        end
    end
    return false
end

function PipeController:getPipeOffset()
    return self.pipeOffsetX, self.pipeOffsetZ
end

function PipeController:getPipeOffsetX()
    return self.pipeOffsetX
end

function PipeController:getPipeOffsetZ()
    return self.pipeOffsetZ
end

function PipeController:isPipeOnTheLeftSide()
    return self.pipeOnLeftSide
end

function PipeController:isDischarging()
    return self.implement:getDischargeState() ~= Dischargeable.DISCHARGE_STATE_OFF
end

function PipeController:getDischargeNode()
    local ix = self.implement:getPipeDischargeNodeIndex()
	local dischargeNode = self.implement:getDischargeNodeByIndex(ix)
    return dischargeNode
end

function PipeController:getDischargeObject()
    local dischargeNode = self:getDischargeNode()
    if dischargeNode then
        local targetObject, fillUnitIndex = self.implement:getDischargeTargetObject(dischargeNode)
        return targetObject, fillUnitIndex
    end
    return false
end

function PipeController:getClosestExactFillRootNode()
    local objectId = self.pipeSpec.nearestObjectInTriggers.objectId 
	local fillUnitIndex = self.pipeSpec.nearestObjectInTriggers.fillUnitIndex
    if objectId and fillUnitIndex then 
        local object = NetworkUtil.getObject(objectId)
        return object and object:getFillUnitExactFillRootNode(fillUnitIndex)
    end
end

function PipeController:getClosestObject()
    local id = self.pipeSpec.nearestObjectInTriggers.objectId
    return id and NetworkUtil.getObject(id)
end

function PipeController:handleChopperPipe()
    local currentPipeTargetState = self.pipeSpec.targetState
    if currentPipeTargetState ~= 2 then
        self.implement:setPipeState(2)
    end
end

--- Gets the dischargeNode and offset from a selected tip side.
---@param tipSideID number
---@return table dischargeNodeIndex
---@return table dischargeNode
---@return number xOffset 
function PipeController:getDischargeNodeAndOffsetForTipSide(tipSideID)
    local dischargeNode = self:getDischargeNode()
    return self.implement:getPipeDischargeNodeIndex(), dischargeNode, self:getPipeOffsetX()
end

--- Gets the x offset of the discharge node relative to the implement root.
function PipeController:getDischargeXOffset(dischargeNode)
    local node = dischargeNode.node
    local xOffset, _ ,_ = localToLocal(node, self.implement.rootNode, 0, 0, 0)
    return xOffset
end

function PipeController:startDischargeToGround(dischargeNode)
    if not dischargeNode.canDischargeToGround and not dischargeNode.canDischargeToGroundAnywhere then 
        self:debug("Implement doesn't support unload to the ground!")
        return false
    end
    self.isDischargingToGround = true
    self.dischargeData = {
        dischargeNode = dischargeNode,
    }
    return true
end

--- Unfolds the pipe and makes sure that everything is ready for unload.
---@param tipToGround boolean
---@return boolean unfolded pipe
function PipeController:prepareForUnload(tipToGround)
    self:openPipe()  
    if not self:isPipeOpen() then 
        return false
    end
    if self.implement:getIsAIPreparingToDrive() then 
        return false
    end
    return true
end

--- Callback for the drive strategy, when the unloading finished.
function PipeController:setFinishDischargeCallback(finishDischargeCallback)
    self.finishDischargeCallback = finishDischargeCallback
end

--- Callback for ai discharge.
function PipeController:finishedDischarge()
    self:debug("Finished unloading.")
    if self.finishDischargeCallback then 
        self.finishDischargeCallback(self.driveStrategy, self)
    end
    self.isDischargingToGround = false
    self.dischargeData = {}
    self:closePipe(false)
end

function PipeController:isEmpty()
    local dischargeNode = self:getDischargeNode()
    return self.implement:getFillUnitFillLevelPercentage(dischargeNode.fillUnitIndex) <= 0
end

--- Gets the pipe z offset relative to the root vehicles direction node.
function PipeController:getUnloadOffsetZ(dischargeNode)
    return self.pipeOffsetZ
end

--- Measures pipe properties: xOffset, zOffset, pipeOnLeftSide
function PipeController:measurePipeProperties()
    --- Old fold and pipe states.
    local foldAnimTime = self.implement.spec_foldable.foldAnimTime
    local foldState = -self.implement:getToggledFoldDirection()
    local pipeAnimTime = self.implement:getAnimationTime(self.pipeSpec.animation.name)
    local pipeState = self.pipeSpec.targetState
    local pipeAnimCurrentSpeed = pipeState == PipeController.PIPE_STATE_CLOSED and -self.pipeSpec.animation.speedScale 
        or self.pipeSpec.animation.speedScale
    self:debug("Measuring pipe properties return values => pipeState: %s, foldAnimTime: %s, pipeAnimTime: %s, pipeAnimCurrentSpeed: %s",
        tostring(pipeState), tostring(foldAnimTime), tostring(pipeAnimTime), tostring(pipeAnimCurrentSpeed))
    
    self:instantUnfold()

    local _
    local dischargeNode = self:getDischargeNode()
    if self.implement.getAIDirectionNode then 
        self:debug("The pipe is installed at the root vehicle.")
        self.pipeOffsetX, _, self.pipeOffsetZ = localToLocal(dischargeNode.node, 
            self.implement:getAIDirectionNode(), 0, 0, 0)
    else 
        --- Pipe is installed on an implement.
        self:debug("The pipe is installed on an implement.")
        local pipeOffsetZ
        self.pipeOffsetX, _, pipeOffsetZ = localToLocal(dischargeNode.node, 
            self.implement.rootNode, 0, 0, 0)
        local dist = ImplementUtil.getDistanceToImplementNode(self.vehicle:getAIDirectionNode(),
            self.implement, self.implement.rootNode)
        self.pipeOffsetZ = pipeOffsetZ + dist
    end
    self.pipeOnLeftSide = self.pipeOffsetX >= 0
    self:debug("Measuring pipe properties => pipeOffsetX: %.2f, pipeOffsetZ: %.2f, pipeOnLeftSide: %s", 
        self.pipeOffsetX, self.pipeOffsetZ, tostring(self.pipeOnLeftSide))

    --- Restoring old states.
    self:resetFold(foldState, foldAnimTime, 
        pipeState)
end

--- Unfolds the pipe completely to measure the pipe properties.
function PipeController:instantUnfold(ignorePipeState)
    if self.pipeSpec.currentState ~= self.pipeSpec.targetState or 
        self.pipeSpec.currentState ~= PipeController.PIPE_STATE_OPEN or ignorePipeState then
        --- First we need to unfold the implement and then open the pipe
        if self.foldableSpec.turnOnFoldDirection == -1 then
            --- Unfolded direction is -1
            Foldable.setAnimTime(self.implement, 0, true)
        else 
            Foldable.setAnimTime(self.implement, 1, true)
        end
        if self.pipeSpec.hasMovablePipe then
            --- After unfolding the implement, make sure the pipe gets unfolded.
            self.implement:updatePipeNodes(999999, nil)
            self.pipeSpec.targetState = 0
            self.implement:setPipeState(PipeController.PIPE_STATE_OPEN, true)
            self.implement:updatePipeNodes(999999, nil)
            --- Close and open the pipe again, as sometimes this gets stuck...
            self.implement:setPipeState(PipeController.PIPE_STATE_CLOSED, true)
            self.implement:updatePipeNodes(999999, nil)
            self.implement:setPipeState(PipeController.PIPE_STATE_OPEN, true)
            self.implement:updatePipeNodes(999999, nil)
            if self.pipeSpec.animation.name ~= nil then
                self.implement:setAnimationTime(self.pipeSpec.animation.name, 1, true, false)
            end
        end
    end
end

--- Restores the folding and pipe states/positions.
---@param foldState number
---@param foldAnimTime number
---@param pipeState number
function PipeController:resetFold(foldState, foldAnimTime, pipeState)
    if not self.pipeSpec.hasMovablePipe then
        --- Restoring the fold state
        Foldable.setAnimTime(self.implement, foldAnimTime, true)
        --- Makes sure the fold state is correctly set.
        self.implement:setFoldDirection(-foldState, true)
        self.implement:setFoldDirection(foldState, true)
        return
    end
    if pipeState == PipeController.PIPE_STATE_CLOSED then
        --- Restoring the fold state
        Foldable.setAnimTime(self.implement, foldAnimTime, true)
        --- Makes sure the fold state is correctly set.
        self.implement:setFoldDirection(-foldState, true)
        self.implement:setFoldDirection(foldState, true)
        --- Restoring the pipe position
        self.implement:updatePipeNodes(999999, nil)
        self.implement:setPipeState(pipeState, true)
        self.implement:updatePipeNodes(999999, nil)
        if self.pipeSpec.animation.name ~= nil then
            self.implement:setAnimationTime(self.pipeSpec.animation.name, 0, true, false)
        end
    end
end

function PipeController.PipeFoldFix(implement, direction)
    --- Fixes the pipe position,
    --- when the pipe is being folded 
    --- without closing the pipe before that.
    if implement.spec_pipe then 
        if direction == 1 then 
            implement.spec_pipe.targetState = PipeController.PIPE_STATE_CLOSED
		    implement.spec_pipe.currentState = PipeController.PIPE_STATE_CLOSED
        end
    end
end
Foldable.setFoldState = Utils.appendedFunction(Foldable.setFoldState, PipeController.PipeFoldFix)

--------------------------------------------------------------------
--- Moveable pipe
--------------------------------------------------------------------

function PipeController:setupMoveablePipe()
    self.validMovingTools = {}
    if self.cylinderedSpec and self.pipeSpec.numAutoAimingStates <= 0 then
        for i, m in ipairs(self.cylinderedSpec.movingTools) do
            -- Gets only the pipe moving tools.
            if m.freezingPipeStates ~= nil and next(m.freezingPipeStates) ~= nil then
                --- Only control pipe elements, that are controlled with the rot speed for now.
                if m.rotSpeed ~= nil then 
                    table.insert(self.validMovingTools, m)
                end
            end
        end
    end
    self.hasPipeMovingTools = #self.validMovingTools > 0
    if self.dischargeSpec then
        self.dischargeNodeIndex = self.implement:getPipeDischargeNodeIndex()
        self.dischargeNode = self.dischargeSpec.dischargeNodes[self.dischargeNodeIndex]
    end
    for i, m in ipairs(self.validMovingTools) do
        local validBaseTool = true
        for i, mm in ipairs(self.validMovingTools) do
            if m ~= mm and getParent(m.node) == mm.node then 
                validBaseTool = false
            end
        end
        if validBaseTool then 
            self.baseMovingTool = m
            break
        end
    end
    for i, m in ipairs(self.validMovingTools) do 
        if m ~= self.baseMovingTool then 
            self.baseMovingToolChild = m
        end
    end

    self.tempBaseNode = CpUtil.createNode("tempBaseNode", 0, 0, 0)
    self.tempDependedNode = CpUtil.createNode("tempDependedNode", 0, 0, 0)

    self:debug("Number of moveable pipe elements found: %d", #self.validMovingTools)

end

function PipeController:updateMoveablePipe(dt)
    if self.hasPipeMovingTools and not self:isPipeMoving() then
        if self.pipeSpec.unloadingStates[self.pipeSpec.currentState] == true then
            if self.baseMovingTool and self.baseMovingToolChild then 
                self:movePipeUp( self.baseMovingTool, self.baseMovingToolChild.node, dt)
                self:moveDependedPipePart(self.baseMovingToolChild, dt)
            else
                local _, y, _ = localToWorld(self.baseMovingTool.node, 0, 0, 0)
                local _, ny, _ = localToWorld(self.implement.rootNode, 0, 0, 0)
                if math.abs(y-ny) < 2 then 
                    self:movePipeUp( self.baseMovingTool, self.dischargeNode.node, dt)
                else 
               --     DebugUtil.drawDebugNode(self.baseMovingTool.node, "baseMovingTool")
                    self:moveDependedPipePart( self.baseMovingTool, dt)
                end
            end
        end
    end
end



function PipeController:moveDependedPipePart(tool, dt)

    if self.driveStrategy.isMoveablePipeDisabled and self.driveStrategy:isMoveablePipeDisabled() then 
        ImplementUtil.stopMovingTool(self.implement, tool)
        return
    end

    local toolNode = tool.node   
    local dischargeNode = self.dischargeNode.node
    local toolDischargeDist = calcDistanceFrom(toolNode, dischargeNode)
    local exactFillRootNode = self:getClosestExactFillRootNode()

    local tx, ty, tz = localToWorld(dischargeNode, 0, 0, 0)
    local _, gy, _ = localToWorld(toolNode, 0, 0, 0)
   -- DebugUtil.drawDebugNode(dischargeNode, "dischargeNode")
    setTranslation(self.tempDependedNode, tx, gy, tz)
   -- DebugUtil.drawDebugNode(self.tempDependedNode, "tempDependedNode")

    local toolTempDist = calcDistanceFrom(toolNode, self.tempDependedNode)
    --- Absolute angle difference needed to be adjustment.
    local alpha = math.acos(toolTempDist/toolDischargeDist)

    local curRot = {}
    curRot[1], curRot[2], curRot[3] = getRotation(toolNode)
    local oldRot = curRot[tool.rotationAxis]
    local targetRot = 0
    if ty < gy then 
        --- Discharge node is below the tool node
        targetRot = oldRot + alpha
        if not self.pipeOnLeftSide then
            targetRot = oldRot - alpha
        end
    else 
        targetRot = oldRot - alpha
        if not self.pipeOnLeftSide then
            targetRot = oldRot + alpha
        end
    end

    if exactFillRootNode then 
     --   DebugUtil.drawDebugNode(exactFillRootNode, "exactFillRootNode")
        local _, gyT, _ = localToWorld(exactFillRootNode, 0, 0, 0)
        gyT = gyT + 1
        if gyT > gy then
            local d = gyT - gy
            local beta = math.asin(d/toolDischargeDist)
            if self.pipeOnLeftSide then
                targetRot  = targetRot + beta
            else 
                targetRot  = targetRot - beta
            end
        end
    end
  --  if g_currentMission.controlledVehicle and g_currentMission.controlledVehicle == self.vehicle then
  --      self:debug("Move depended: rotTarget: %.2f, oldRot: %.2f, rotMin: %.2f, rotMax: %.2f", targetRot, oldRot, tool.rotMin, tool.rotMax)
  --  end
    ImplementUtil.moveMovingToolToRotation(self.implement, tool, dt, MathUtil.clamp(targetRot, tool.rotMin, tool.rotMax))
end

function PipeController:movePipeUp(tool, childToolNode, dt)

    if self:isDischarging() or self.driveStrategy.isMoveablePipeDisabled and self.driveStrategy:isMoveablePipeDisabled() then 
        --- Stops this moving tool, while discharging.
        ImplementUtil.stopMovingTool(self.implement, tool)
        return
    end

    local toolNode = tool.node   
    local toolChildToolDist = calcDistanceFrom(toolNode, childToolNode)

  --  DebugUtil.drawDebugNode(childToolNode, "childToolNode")
  --  DebugUtil.drawDebugNode(toolNode, "toolNode")

    local exactFillRootNode = self:getClosestExactFillRootNode()
   
    local tx, ty, tz = localToWorld(childToolNode, 0, 0, 0)
    local gx, gy, gz = localToWorld(toolNode, 0, 0, 0)
    setTranslation(self.tempBaseNode, gx, ty, gz)
  --  DebugUtil.drawDebugNode(self.tempBaseNode, "tempNode")

    local toolTempDist = calcDistanceFrom(toolNode, self.tempBaseNode)
    --- Absolute angle difference needed to be adjustment.
    local alpha = math.asin(toolTempDist/toolChildToolDist)
    local curRot = {}
    curRot[1], curRot[2], curRot[3] = getRotation(toolNode)
    local oldRot = curRot[tool.rotationAxis]
    local targetRot = 0
    if ty > gy then 
        --- Discharge node is below the tool node
        targetRot = oldRot + alpha
        if not self.pipeOnLeftSide then
            targetRot = oldRot - alpha
        end
    else 
        targetRot = oldRot - alpha
        if not self.pipeOnLeftSide then
            targetRot = oldRot + alpha
        end
    end

    if exactFillRootNode then 
    --    DebugUtil.drawDebugNode(exactFillRootNode, "exactFillRootNode")
        local gxT, gyT, gzT = localToWorld(exactFillRootNode, 0, 0, 0)
        gyT = gyT + 2
        local terrainHeight = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, gxT, 0, gzT) + 4
        gyT = math.max(gyT, terrainHeight)
        local offset = gyT - gy
        if gyT < ty then
            local d = math.abs(gyT - gy + offset)
            local beta = math.asin(d/toolChildToolDist)
       --     DebugUtil.drawDebugLine(gxT, gyT, gzT, gx, gy, gz, 0, 0, 1)
       --     DebugUtil.drawDebugLine(tx, ty, tz, gxT, gyT, gzT, 0, 0, 1)
            targetRot = oldRot - beta
            if not self.pipeOnLeftSide then
                targetRot = oldRot + beta
            end
        --    if g_currentMission.controlledVehicle and g_currentMission.controlledVehicle == self.vehicle then
        --        self:debug("Move up: rotTarget: %.2f, oldRot: %.2f, rotMin: %.2f, rotMax: %.2f", targetRot, oldRot, tool.rotMin, tool.rotMax)
        --    end
        end
    end
    ImplementUtil.moveMovingToolToRotation(self.implement, tool, dt, MathUtil.clamp(targetRot, tool.rotMin, tool.rotMax))
end

function PipeController:delete()
    CpUtil.destroyNode(self.tempBaseNode)
    CpUtil.destroyNode(self.tempDependedNode)
end

--------------------------------------------------------------------
--- Debug functions
--------------------------------------------------------------------

function PipeController:printPipeDebug()
    self:info("Current pipe state: %s, Target pipe state: %s, numStates: %s", 
        tostring(self.pipeSpec.currentState), tostring(self.pipeSpec.targetState), tostring(self.pipeSpec.numStates))   
    self:info("Is pipe state change allowed: %s", self.implement:getIsPipeStateChangeAllowed())
    self:info("Fold => minTime: %s, maxTime : %s, minState: %s, maxState: %s",
        tostring(self.pipeSpec.foldMinTime), tostring(self.pipeSpec.foldMaxTime), 
        tostring(self.pipeSpec.foldMinState), tostring(self.pipeSpec.foldMaxState))
    self:info("aiFoldedPipeUsesTrailerSpace: %s", tostring(self.pipeSpec.aiFoldedPipeUsesTrailerSpace))
    self:info("Pipe offset x: %.2f, offset z: %.2f", self.pipeOffsetX, self.pipeOffsetZ)

end

function PipeController:printMoveablePipeDebug()
    CpUtil.infoImplement(self.implement, "Num of moveable tools: %d", #self.validMovingTools)
    CpUtil.infoImplement(self.implement, "Base moving tool")
    self:printMovingToolDebug(self.baseMovingTool)
    CpUtil.infoImplement(self.implement, "Base moving tool child")
    self:printMovingToolDebug(self.baseMovingToolChild)
end

function PipeController:printDischargeableDebug()
    local dischargeNode = self:getDischargeNode()
    CpUtil.infoImplement(self.implement, "Discharge node fill unit index: %d, emptySpeed: %s", 
        dischargeNode.fillUnitIndex, self.implement:getDischargeNodeEmptyFactor(dischargeNode))
    CpUtil.infoImplement(self.implement, "canDischargeToGround %s, canDischargeToObject: %s",
        dischargeNode.canDischargeToGround, dischargeNode.canDischargeToObject)
    CpUtil.infoImplement(self.implement, "canStartDischargeAutomatically %s, canStartGroundDischargeAutomatically: %s",
        dischargeNode.canStartDischargeAutomatically, dischargeNode.canStartGroundDischargeAutomatically)
    CpUtil.infoImplement(self.implement, "stopDischargeIfNotPossible %s, canDischargeToGroundAnywhere: %s",
        dischargeNode.stopDischargeIfNotPossible, dischargeNode.canDischargeToGroundAnywhere)
    CpUtil.infoImplement(self.implement, "getCanDischargeToObject() %s, getCanDischargeToGround(): %s",
        self.implement:getCanDischargeToObject(dischargeNode), self.implement:getCanDischargeToGround(dischargeNode))
    CpUtil.infoImplement(self.implement, "Discharge node offset => x: %.2f, z: %.2f", 
        self:getDischargeXOffset(dischargeNode), self:getUnloadOffsetZ(dischargeNode))
end

function PipeController:printMovingToolDebug(tool)
    if tool == nil then 
        CpUtil.infoImplement(self.implement, "Tool not found.")
        return
    end
    CpUtil.infoImplement(self.implement, "RotMin: %s, RotMax: %s, RotSpeed", tostring(tool.rotMin), tostring(tool.rotMax), tostring(tool.rotSpeed))
end