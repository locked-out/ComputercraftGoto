local mapFileName = ".gotomapdata"
local configFileName = ".gotoconfig"

local pathFindingTimeout = 5
local GPSLocateTimeout = 5 

------------

os.loadAPI("protocol")

local sensor = peripheral.find("turtlesensorenvironment")
local modem = peripheral.find("modem")

local cardinalDirections = {
    vector.new(1, 0, 0),
    vector.new(-1, 0, 0),
    vector.new(0, 1, 0),
    vector.new(0, -1, 0),
    vector.new(0, 0, 1),
    vector.new(0, 0, -1),
}

local axii = {
    vector.new(1, 0, 0),
    vector.new(0, 1, 0),
    vector.new(0, 0, 1),
}

local indexToFlatDir = {
    vector.new(1,0,0),
    vector.new(-1,0,0),
    vector.new(0,0,1),
    vector.new(0,0,-1)
}

local flatDirToIndex = {}
flatDirToIndex[1] = {}
flatDirToIndex[-1]= {}
flatDirToIndex[0] = {}
flatDirToIndex[1][0]  = 0
flatDirToIndex[-1][0] = 1
flatDirToIndex[0][1]  = 2
flatDirToIndex[0][-1] = 3


Stack = {
    items = {},
    n = 0,
}

function Stack:new()
    local o = {}
    setmetatable(o, self)
    self.__index = self
    self.items = {}
    self.n = 0
    return o
end

function Stack:push(item)
    self.n = self.n + 1
    self.items[self.n] = item
end

function Stack:pop()
    local item = self.items[self.n]
    self.items[self.n] = nil    
    self.n = self.n - 1
    return item
end

function Stack:isEmpty() return self.n == 0 end

function Stack:nItems() return self.n end

PriorityQueue = {
    heap = {},
    n = 0,
    comparisonF = nil, 
}

-- bool comparisonF(a, b) : return true if a should go before b in the queue
function PriorityQueue:new(comparisonF)
    local o = {}
    setmetatable(o, self)
    self.__index = self
    self.heap = {}
    self.n = 0
    self.comparisonF = comparisonF

    return o
end

function PriorityQueue:isEmpty() return self.n == 0 end

function PriorityQueue:dequeue()
    local top = self.heap[1]
   
    -- Move last element to top
    self.heap[1] = self.heap[self.n]
    self.heap[self.n] = nil

    self.n = self.n - 1


    -- Sift new root downards
    local i = 1

    local firstLeaf = bit.brshift(self.n, 1) + 1
    while i < firstLeaf do
        local l = 2 * i
        local r = 2 * i + 1
        local highestPriority = i
        if self.comparisonF(self.heap[l], self.heap[i]) then
            highestPriority = l
        end
        if r <= self.n and self.comparisonF(self.heap[r], self.heap[highestPriority]) then
            highestPriority = r
        end

        if highestPriority == i then
            break
        else
            local temp = self.heap[i]
            self.heap[i] = self.heap[highestPriority]
            self.heap[highestPriority] = temp
            i = highestPriority
        end
    end

    return top
end

function PriorityQueue:enqueue(item)
    self.n = self.n + 1

    local i = self.n

    while i > 1 do
        local parent = bit.brshift(i, 1)
        
        if self.comparisonF(self.heap[parent], item) then
            -- Keep parent here
            break
        end
        -- Move parent down 
        self.heap[i] = self.heap[parent]
        i = parent
    end

    self.heap[i] = item
end


-- TODO: functionality to force hard scan of area

Navigation = {
    isBlocked = {}, -- isBlocked[x][y][z] is true if the block at x,y,z is impassible
    bounds = nil, -- vector3
    origin = nil,  -- vector3
    mov = nil, -- Movement class
}

function Navigation:new(mov, origin, bounds)
   local o = {}
   setmetatable(o, self)
   self.__index = self
   self.mov = mov
   self.bounds = bounds or vector.new(30,30,30)
   self.origin = origin or vector.new(0,0,0)

   return o
end

function Navigation:posToIndex(pos)
    -- local m1 = self.bounds.y * pos.z
    -- local m2 = self.bounds.x * (pos.y + m1)
    -- return pos.x + m2
    return pos.x + self.bounds.x * (pos.y + self.bounds.y * pos.z)
end

function Navigation:indexToPos(index)
    local x = index % self.bounds.x
    index = (index - x) / self.bounds.x
    local y = index % self.bounds.y
    index = (index - y) / self.bounds.y
    local z = index
    return vector.new(x,y,z)
end


-- (-1, 0) (1, 0)  (0, -1) (0, 1)
-- 0         1       2       3
-- 0 + 2 * 
function Navigation:posDirToIndex(pos, dir) 
    local dirIndex = flatDirToIndex[dir.x][dir.z]
    return self:posToIndex(pos) * 4 + dirIndex
end

function Navigation:pdindexToPos(index)
    return self:indexToPos(bit.brshift(index, 2))
end

function Navigation:pdindexToDir(index)
    return indexToFlatDir[index % 4 + 1]
end

function Navigation:isBlockedRelPos(relative) 
    if relative.x < 0 or relative.x >= self.bounds.x then return true end
    if relative.y < 0 or relative.y >= self.bounds.y then return true end
    if relative.z < 0 or relative.z >= self.bounds.z then return true end
    
    return self.isBlocked[self:posToIndex(relative)]
end

function Navigation:isBlockedAbsPos(abs)
    return self:isBlockedRelPos(abs - self.origin)
end

local function queueComparison(a, b)
    return a.fval < b.fval
end

-- returns stack of movements to reach goal, returns nil on pathfind failure
-- also returns the target goal, useful if goodEnoughRadius > 0
-- Only operates with relative positions
-- TODO: Inform user if timeout or unreachable   
function Navigation:aStar(start, startDir, goal, goodEnoughRadius)
    local visited = {}
    local costs = {}
    local prev = {}

    local startIndex = self:posDirToIndex(start, startDir)
    costs[startIndex] = 0
    prev[startIndex] = nil
 
    local sToGoal = goal - start

    local q = PriorityQueue:new(queueComparison)
    q:enqueue({fval=(math.abs(sToGoal.x) + math.abs(sToGoal.y) + math.abs(sToGoal.z)), pos=start, dir=startDir})

    local timeLimit = (os.time() + (pathFindingTimeout/50)) % 24
    local iteration = 0 

    while not q:isEmpty() and (bit.band(iteration, 63) ~= 0 or os.time() < timeLimit) do
        local item = q:dequeue()
        local current = item.pos
        local currentDir = item.dir

        local index = self:posDirToIndex(current, currentDir)

        local hereToGoal = goal - current
        local toGoalDist = math.abs(hereToGoal.x) + math.abs(hereToGoal.y) + math.abs(hereToGoal.z)
        if toGoalDist <= goodEnoughRadius then
            goal = current;
            break
        end

        for i, direction in ipairs(cardinalDirections) do
            local neighbour = current + direction

            if not self:isBlockedRelPos(neighbour) then
                if direction.y == 0 and direction:dot(currentDir) == 0 then
                    -- Need to turn
                    local newIndex = self:posDirToIndex(current, direction)
                    local newCost = costs[index] + 1
                    if costs[newIndex] == nil or newCost < costs[newIndex] then
                        costs[newIndex] = newCost

                    
                        local fval = item.fval + 1
                        q:enqueue({fval=fval, pos=current, dir=direction})
                        prev[newIndex] = index
                    end

                else
                    -- No need to turn
                    local neighbourIndex = self:posDirToIndex(neighbour, currentDir)
                    local newCost = costs[index] + 1
                    if costs[neighbourIndex] == nil or newCost < costs[neighbourIndex] then
                        costs[neighbourIndex] = newCost
        
                        local toGoal = goal - neighbour
                        local fval = newCost + math.abs(toGoal.x) + math.abs(toGoal.y) + math.abs(toGoal.z)
                        q:enqueue({fval=fval, pos=neighbour, dir=currentDir})
                        prev[neighbourIndex] = index
                    end
                end
            end
        end
        iteration = iteration + 1 
    end 

    -- Search for any or best solution
    local goalIndex = self:posToIndex(goal)*4
    local pathIndex = nil
    local bestPath = nil

    for i=1,4 do
        if prev[goalIndex] ~= nil then 
            if pathIndex == nil or costs[goalIndex] < bestPath then
                pathIndex = goalIndex 
                bestPath = costs[goalIndex]
            end
        end
        goalIndex = goalIndex + 1
    end

    if pathIndex == nil then return nil end

    local steps = Stack:new()

    local thisIndex = prev[pathIndex]
    local thisPos
    local nextIndex = pathIndex
    local nextPos = goal

    while thisIndex ~= nil do
        thisPos = self:pdindexToPos(thisIndex)
        local diff = nextPos - thisPos
        if diff.x ~= 0 or diff.y ~= 0 or diff.z ~= 0 then
            steps:push(nextPos - thisPos)
        end

        nextPos = thisPos
        nextIndex = thisIndex
        thisIndex = prev[thisIndex]
    end

    return steps
end

-- Goto an absoulte position, return false if goal is out of bounds or unreachable, else return true on success
-- interuptFunction is called during movement to check if the goal or parameters have changed
-- sendMovingStateFunction is called when commencing movement on a new path, and is passed the following arguments:
--   currentPos: vector
--   dest: vector of target of the turtle
--   travelTime: Estimated time in ticks to reach goal
function Navigation:moveto(goalFunction, interuptFunction, goodEnoughRadius, sendMovingStateFunction)
    while true do
        -- Return here on pathing update
        local goal = goalFunction()
        write("Moving to ")
        print(goal)
        goal = goalFunction() - self.origin
        if goal.x < 0 or goal.x >= self.bounds.x then return false end
        if goal.y < 0 or goal.y >= self.bounds.y then return false end
        if goal.z < 0 or goal.z >= self.bounds.z then return false end

        local relPos = self.mov.currentPos-self.origin
        if goal.x == relPos.x and goal.y == relPos.y and goal.z == relPos.z then
            return true
        end

        local isBlocked = self:isBlockedRelPos(goal)

        if goodEnoughRadius == 0 and isBlocked then return false end

        if not isBlocked then goodEnoughRadius = 0 end

        local nsteps = 0

        while true do
            -- Return here on movement failure (unseen obstacle)
            relPos = self.mov.currentPos-self.origin
            local steps, bestReachable = self:aStar(relPos, self.mov.facing, goal, goodEnoughRadius)

            if steps == nil then
                print("Could not find path")
                return false
            end

            local travelTimeTicks = steps:nItems() * 8 -- 0.4 seconds = 8 ticks 
            
            sendMovingStateFunction(self.mov.currentPos, bestReachable, travelTimeTicks)

            local interupt = false
            local failedStep
            while not steps:isEmpty() do
                local step = steps:pop()

                if not self.mov:move(step) then
                    write("Failed moving ")
                    print(step)
                    failedStep = step
                    break
                else
                    nsteps = nsteps+1
                end

                if nsteps % 5 == 0 then
                    if interuptFunction() then
                        interupt = true
                        break
                    end
                end
            end
            
            if interupt then
                print("Detected changes, recalculating path")
                break
            end

            if steps:isEmpty() then
                return true
            end

            print("Scanning")

            self:scan(failedStep)

            print("Finding new path")
        end
    end
end

function Navigation:scan(blockedDir)
    local scanData = sensor.sonicScan()

    local thisPos = (self.mov.currentPos - self.origin)


    for _, blockData in ipairs(scanData) do
        local offset = vector.new(blockData.x, blockData.y, blockData.z)
        local relPos = thisPos + offset
        if relPos.x >= 0 and relPos.x < self.bounds.x and
           relPos.y >= 0 and relPos.y < self.bounds.y and
           relPos.z >= 0 and relPos.z < self.bounds.z then
            local relIndex = self:posToIndex(relPos)
            local blocked = (blockData.type ~= "AIR")

            -- Leave empty mappings as empty if air
            if self.isBlocked[relIndex] ~= nil or blocked then
                self.isBlocked[relIndex] = blocked
            end
        end
    end


    -- Scan a 3x3 square in the problematic direction
    local normal1 = nil
    local normal2 = nil

    for _, axis in ipairs(axii) do
        if axis:dot(blockedDir) == 0 then
            if normal1 == nil then 
                normal1 = axis
            else
                normal2 = axis
            end
        end
    end

    for m1=-1,1 do
        for m2=-1,1 do
            local dev = normal1 * m1 + normal2 * m2
            local target = blockedDir + dev
            
            local relPos = thisPos + target
            if relPos.x >= 0 and relPos.x < self.bounds.x and
               relPos.y >= 0 and relPos.y < self.bounds.y and
               relPos.z >= 0 and relPos.z < self.bounds.z then
                local res = sensor.sonicScanTarget(target.x, target.y, target.z)
                if res ~= nil then
                    local relIndex = self:posToIndex(relPos)
                    local blocked = (res.type ~= "AIR")

                    -- Leave empty mappings as empty if air
                    if self.isBlocked[relIndex] ~= nil or blocked then
                        self.isBlocked[relIndex] = blocked
                    end
                end
            end
        end
    end

    self.isBlocked[self:posToIndex(thisPos)] = nil
end

function Navigation:saveMap()     
    local mapFile = fs.open(mapFileName, "w")
    for block, state in pairs(self.isBlocked) do
        mapFile.write(string.format("%d", block))
        mapFile.write("\n")
    end
    mapFile.close()
end

function Navigation:loadMap()     
    local mapFile = fs.open(mapFileName, "r")
    
    local line = mapFile.readLine()
    while line ~= nil do
        self.isBlocked[tonumber(line)] = true
        line = mapFile.readLine()
    end
    mapFile.close()
end


Movement = {
    currentPos = nil, -- vector3
    facing = nil, -- cardinal unit vector3 of the forward direction, y is always 0
}

function Movement:new(currentPos, facing)
    local o = {}
    setmetatable(o, self)
    self.__index = self
    self.currentPos = currentPos or vector.new(0, 0, 0)
    self.facing = facing or vector.new(1, 0, 0)
    return o
end

-- return calibration success
function Movement:calibrateDirection()
    for i=1,4 do
        if turtle.forward() then
            local x,y,z = gps.locate(5)
            if x == nil then
                print("Could not reach any GPS towers")
                turtle.back()
                return false
            end

            local newPos = vector.new(x,y,z)
            self.facing = newPos - self.currentPos
            turtle.back()
            return true
        end

        turtle.turnRight()
    end

    return false
end

function Movement:forward()
    if turtle.forward() then
        self.currentPos = self.currentPos + self.facing
        return true
    else
        return false
    end
end

function Movement:back()
    if turtle.back() then
        self.currentPos = self.currentPos - self.facing
        return true
    else
        return false
    end
end

function Movement:up()
    if turtle.up() then
        self.currentPos = self.currentPos + vector.new(0, 1, 0)
        return true
    else
        return false
    end
end

function Movement:down()
    if turtle.down() then
        self.currentPos = self.currentPos + vector.new(0, -1, 0)
        return true
    else
        return false
    end
end

function Movement:right()
    turtle.turnRight()
    self.facing = vector.new(-self.facing.z, 0, self.facing.x)
    return true
end

function Movement:left()
    turtle.turnLeft()
    self.facing = vector.new(self.facing.z, 0, -self.facing.x)
    return true
end

-- Move in the cardinal direction dir, turning if need to
function Movement:move(dir)
    if dir.y > 0 then
        return self:up()
    elseif dir.y < 0 then
        return self:down()
    else
        local dot = self.facing:dot(dir)
        if dot == 0 then
            local cross2d = self.facing.x*dir.z - self.facing.z*dir.x
            if cross2d > 0 then
                self:right()
                return self:forward()
            elseif cross2d < 0 then
                self:left()
                return self:forward()
            else
                print("wtf")
            end
        elseif dot == 1 then
            return self:forward()
        elseif dot == -1 then
            return self:back()
        else
            print("wtf2")
        end
    end
end


DeliveryManager = {
    nav = nil,       -- Nagivation controller
    minCorner = nil, -- vector3 lowest corner of the operating area
    maxCorner = nil, -- vector3 highest corner of the operating area
    homePos = nil,   -- vector3 home location near pickup inventory
    homeDir = "left",-- string of inventory direction
    fuelPos = nil,   -- vector3 fuel locationg near fuel inventory
    fuelDir = "left",-- string of inventory direction
    serverConnection = nil,
    playerPos = nil  -- vector3 of player's position
}

function DeliveryManager:new(nav, serverConnection)
    local o = {}
    setmetatable(o, self)
    self.__index = self
    self.nav = nav
    self.serverConnection = serverConnection
    return o
end

function DeliveryManager:checkForPathingUpdates(getPlayer)
    local changes = false
    
    local function playerPosCallback(pos) 
        print("Player pos was updated!")
        self.playerPos = vector.new(math.floor(pos.x), math.floor(pos.y), math.floor(pos.z))
        changes = true
    end

    self.serverConnection:requestPathingUpdates(playerPosCallback, nil, nil, getPlayer) 
    
    return changes
end

function DeliveryManager:getPlayerUpdates() return self:checkForPathingUpdates(true) end
function DeliveryManager:getPathingOnlyUpdates() return self:checkForPathingUpdates(false) end

function DeliveryManager:getPlayerPos() return self.playerPos end

local function findWirelessModem()
    for _, name in pairs(peripheral.getNames()) do
        if peripheral.getType(name) == "modem" and peripheral.call(name, "isWireless") then
            return name
        end
    end

    return nil
end

local function main()

    if not sensor then
        print("Could not find an attached sensor. This program requires an attached openperipherals sensor. Craft one together with this turtle.")
        return
    end

    if not modem then
        print("Could not find an attached modem. This program requires an attached wirless modem. Craft one together with this turtle.")
        return
    end

    rednet.open(findWirelessModem())    

    local x,y,z = gps.locate(5)

    if (x == nil) then print("Could not reach any GPS towers") return end
    local position = vector.new(x,y,z)

    local mov = Movement:new(position)

    if not mov:calibrateDirection() then print("calibration failed") return end

    local lowerCorner = vector.new(-36, 51, -30)
    local upperCorner = vector.new(38, 70, 22)

    local nav = Navigation:new(mov, lowerCorner, upperCorner-lowerCorner)

    if fs.exists(mapFileName) then
        nav:loadMap()
    end

    local connection = protocol.ServerConnection.begin(true)
    local manager = DeliveryManager:new(nav, connection)

    local playerPos

    local function playerPosCallback(pos) manager.playerPos = vector.new(math.floor(pos.x), math.floor(pos.y), math.floor(pos.z)) end


    while true do
        connection:requestAllUpdates(playerPosCallback, nil, nil, nil, nil)

        if not manager.playerPos or (manager.playerPos-nav.mov.currentPos):length() < 2 then
            connection:sendIdleState(nav.mov.currentPos)
            while not manager.playerPos or (manager.playerPos - nav.mov.currentPos):length() < 2 do
                os.sleep(5)
                connection:requestAllUpdates(playerPosCallback, nil, nil, nil, nil)
            end
        end


        local function sendMovingState(currentPos, dest, travelTime)
            local eta = os.time() + travelTime/1000
            while eta >= 24 do
                eta = eta - 24
            end
            connection:sendMovingState(currentPos, dest, eta, "PLAYER")
        end

        write("Going to ")
        print(manager.playerPos)
        local success = nav:moveto(
            function () return manager:getPlayerPos() end, 
            function () return manager:getPlayerUpdates() end,
            1,
            sendMovingState
        )

        if success then
            nav:saveMap()
        else 
            connection:sendStuckState(nav.mov.currentPos, manager.playerPos, "PLAYER")
            print("Cannot reach")
            os.sleep(5)
        end
    end
end

main()

