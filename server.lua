
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
    self.updates = {} 
end

Player = protocol.CreateClass()
function Player:_init(connection)
    self.connection = connection
    self.pos = nil
    self.posSentTo = {} -- A set of IDs of turtles that are aware of the players latest position
end

local responseHandler = protocol.ClientResponseHandler()
responseHandler.responseHandlerGreet = function (connection, isTurtle)
   return connection:makeResponseAck()
end

local function incomingMessage(turtles, players, senderID, message, p)
    local newConnection = protocol.ClientConnection.newIncomingConnection(senderID, message, p)
    if newConnection then
        if newConnection:isTurtle() then
            print("Accepted new turtle connection")
            turtles[senderID] = Turtle(newConnection)
            for id, player in pairs(players) do
                player.posSentTo[senderID] = false
            end
        else
            print("Accepted new player connection")
            players[senderID] = Player(newConnection)
        end   
    end

    if turtles[senderID] and turtles[senderID].connection:isSender(senderID, p) then
        turtles[senderID].connection:handleResponse(responseHandler, message)
        return
    end
    if players[senderID] and players[senderID].connection:isSender(senderID, p) then
        players[senderID].connection:handleResponse(responseHandler, message)
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

    local turtles = {}
    local players = {}

    responseHandler.responseHandlerPlayerPos = function (connection, pos)
        pos = vector.new(pos.x, pos.y, pos.z)
        write("Player at pos ")
        print(pos)
        players[connection:getOtherID()].pos = pos
        players[connection:getOtherID()].posSentTo = {}
        return connection:makeResponseAck()
    end

    responseHandler.responseHandlerGetAllUpdates = function (connection)
        local updates = {}

        for id, player in pairs(players) do
            if not player.posSentTo[connection:getOtherID()] then
                player.posSentTo[connection:getOtherID()] = true
                local posUpdate = connection:makeUpdatePlayerPos(player.pos)
                table.insert(updates, posUpdate)
            end
        end

        return connection:makeResponseUpdateList(updates)
    end

    responseHandler.responseHandlerGetPathingUpdates = responseHandler.responseHandlerGetAllUpdates

    responseHandler.responseHandlerTurtleState = function (connection, state)
        turtles[connection:getOtherID()].state = state
        return connection:makeResponseAck()
    end


    while true do
        local event, r1, r2, r3 = os.pullEvent()
        if event == "rednet_message" then
            write("New "..r3.." message from "..r1..": ")
            print(textutils.serialize(r2))
            incomingMessage(turtles, players, r1, r2, r3)
        end
    end
end

main()

