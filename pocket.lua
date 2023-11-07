local function findWirelessModem()
    for _, name in pairs(peripheral.getNames()) do
        if peripheral.getType(name) == "modem" and peripheral.call(name, "isWireless") then
            return name
        end
    end

    return nil
end

local function getPos()
    local x,y,z = gps.locate(5)

    if (x == nil) then print("Could not reach any GPS towers") return end
    return vector.new(x,y - 1.6,z)
end
os.loadAPI("protocol")

local function main()
    local modemSide = findWirelessModem()
    local modem = peripheral.wrap(modemSide)

    if not modem then
        print("Could not find an attached wireless modem. This program requires an attached wireless modem to function.")
        return
    end
    rednet.open(modemSide)
    print("Opening rednet on side "..modemSide)

    local connection = protocol.ServerConnection.begin(false)

    local position = getPos()
    connection:sendPlayerPos(position)
    while true do
        os.sleep(1)
        local newPos = getPos()
        if (newPos - position):length() > 2 then
            position = newPos
            connection:sendPlayerPos(position)
        end
    end
end

main()
