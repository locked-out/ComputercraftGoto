
local function findWirelessModem()
    for _, name in pairs(peripheral.getNames()) do
        if peripheral.getType(name) == "modem" and peripheral.call(name, "isWireless") then
            return name
        end
    end

    return nil
end

os.loadAPI("protocol")

Turtle = protocol.CreateClass()
function Turtle:_init(connection)
    self.connection = connection
    self.state = nil
end

local sentPosUpdate = false

local responseHandler = protocol.ClientResponseHandler()
responseHandler.responseHandlerGreet = function (connection, isTurtle)
   return connection:makeResponseAck()
end

local function incomingMessage(turtles, players, senderID, message, p)
     local newConnection = protocol.ClientConnection.newIncomingConnection(senderID, message, p)
    if newConnection then
        if newConnection:isTurtle() then
            print("Accepted new turtle connection")
            turtles[senderID] = newConnection
        else
            print("Accepted new player connection")
            players[senderID] = newConnection
        end   
    end

    if turtles[senderID] and turtles[senderID]:isSender(senderID, p) then
        turtles[senderID]:handleResponse(responseHandler, message)
        return
    end
    if players[senderID] and players[senderID]:isSender(senderID, p) then
        players[senderID]:handleResponse(responseHandler, message)
        return
    end
end

local function main()
    local modemSide = findWirelessModem()
    local modem = peripheral.wrap(modemSide)

    if not modem then
        print("Could not find an attached wireless modem. This program requires an attached wireless modem to function.")
        return
    end
    rednet.open(modemSide)
    
    protocol.HostServer()

    local turtleConnections = {}
    local playerConnections = {}

    local playerPos = {}

    responseHandler.responseHandlerPlayerPos = function (connection, pos)
        pos = vector.new(pos.x, pos.y, pos.z)
        write("Player at pos ")
        print(pos)
        playerPos[connection:getOtherID()] = pos
        sentPosUpdate = false
        return connection:makeResponseAck()
    end

    responseHandler.responseHandlerGetAllUpdates = function (connection)
        local updates = {}

        for id, pos in pairs(playerPos) do
            if not sentPosUpdate then
                local posUpdate = connection:makeUpdatePlayerPos(pos)
                table.insert(updates, posUpdate)
                sentPosUpdate = true
            end
        end

        return connection:makeResponseUpdateList(updates)
    end

    responseHandler.responseHandlerGetPathingUpdates = responseHandler.responseHandlerGetAllUpdates

    while true do
        local event, r1, r2, r3 = os.pullEvent()
        if event == "rednet_message" then
            write("New "..r3.." message from "..r1..": ")
            print(textutils.serialize(r2))
            incomingMessage(turtleConnections, playerConnections, r1, r2, r3)
        end
    end
end

main()

