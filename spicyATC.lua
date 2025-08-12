-- spicyATC.lua - BMS-style ATC for DCS Missions written by Spicy
-- Uses missionCommands for '/' comms menu integration

local function getClosestAirbases(unit, num)
    env.info("SpicyATC: Getting closest airbases for unit " .. (unit and unit:getName() or "nil"))
    if not unit or not unit:isExist() then return {} end
    local airbases = coalition.getAirbases(unit:getCoalition())
    if not airbases or #airbases == 0 then env.info("SpicyATC: No airbases found"); return {} end
    local playerPos = unit:getPosition().p
    if not playerPos then env.info("SpicyATC: No player position"); return {} end
    local distances = {}
    for i, airbase in pairs(airbases) do
        local abPos = airbase:getPosition().p
        if abPos then
            local dist = math.sqrt((abPos.x - playerPos.x)^2 + (abPos.z - playerPos.z)^2)
            table.insert(distances, {airbase = airbase, dist = dist})
        end
    end
    table.sort(distances, function(a, b) return a.dist < b.dist end)
    local closest = {}
    for i = 1, math.min(num or 3, #distances) do
        table.insert(closest, distances[i].airbase)
    end
    return closest
end

local function adviseFreq(unit, closestAirbases)
    env.info("SpicyATC: Advising freq for unit " .. (unit and unit:getName() or "nil"))
    if not unit or not unit:isExist() then return false end
    local comm = unit:getCommunicator()
    if not comm then 
        env.info("SpicyATC: No communicator, assuming wrong freq")
        return false  -- Force freq check failure if no communicator
    end
    local playerFreq = comm:getFrequency() / 1000000
    local msg = "ATC: Wrong freq. Closest airfields: "
    local onRightFreq = false
    for i, airbase in ipairs(closestAirbases) do
        local abFreq = airbase:getFrequency() / 1000000
        msg = msg .. airbase:getName() .. " " .. abFreq .. " MHz, "
        if playerFreq == abFreq then onRightFreq = true end
    end
    if not onRightFreq and #closestAirbases > 0 then
        trigger.action.outTextForUnit(unit:getID(), msg:sub(1, -3), 10, false)
    end
    return onRightFreq
end

local function requestStartup()
    env.info("SpicyATC: Request Startup called")
    local unit = world.getPlayer()
    if not unit or not unit:isExist() then
        env.info("SpicyATC: No player unit found, aborting startup");
        return
    end
    local closestAirbases = getClosestAirbases(unit, 3)
    if #closestAirbases == 0 then env.info("SpicyATC: No airbases to check freq"); return end
    -- Skip freq check for startup (BMS ground crew behavior)
    local group = unit:getGroup()
    local numUnits = #group:getUnits()
    local msg = numUnits > 1 and "Flight cleared for startup (" .. numUnits .. " aircraft)" or "Cleared for startup"
    trigger.action.outTextForUnit(unit:getID(), "ATC Ground: " .. msg, 10, false)
end

local function requestTaxi()
    env.info("SpicyATC: Request Taxi called")
    local unit = world.getPlayer()
    if not unit or not unit:isExist() then
        env.info("SpicyATC: No player unit found, aborting taxi");
        return
    end
    local closestAirbases = getClosestAirbases(unit, 3)
    if #closestAirbases == 0 then env.info("SpicyATC: No airbases to check freq"); return end
    local onRightFreq = adviseFreq(unit, closestAirbases)
    if onRightFreq then
        local msg = "Taxi via E, right on D. Hold short runway 09." -- Placeholder
        trigger.action.outTextForUnit(unit:getID(), "ATC Ground: " .. msg, 10, false)
    end
end

local function requestTakeoff()
    env.info("SpicyATC: Request Takeoff called")
    local unit = world.getPlayer()
    if not unit or not unit:isExist() then
        env.info("SpicyATC: No player unit found, aborting takeoff");
        return
    end
    local closestAirbases = getClosestAirbases(unit, 3)
    if #closestAirbases == 0 then env.info("SpicyATC: No airbases to check freq"); return end
    local onRightFreq = adviseFreq(unit, closestAirbases)
    if onRightFreq then
        local msg = "Cleared takeoff runway 09, fly heading 270, contact Tower on [freq]." -- Placeholder
        trigger.action.outTextForUnit(unit:getID(), "ATC Tower: " .. msg, 10, false)
    end
end

local function requestInbound()
    env.info("SpicyATC: Request Inbound called")
    local unit = world.getPlayer()
    if not unit or not unit:isExist() then
        env.info("SpicyATC: No player unit found, aborting inbound");
        return
    end
    local closestAirbases = getClosestAirbases(unit, 3)
    if #closestAirbases == 0 then env.info("SpicyATC: No airbases to check freq"); return end
    local onRightFreq = adviseFreq(unit, closestAirbases)
    if onRightFreq then
        local msg = "Inbound acknowledged. Fly heading 180 for vectors." -- Placeholder
        trigger.action.outTextForUnit(unit:getID(), "ATC Approach: " .. msg, 10, false)
    end
end

local function addATCMenus(coalitionID)
    env.info("SpicyATC: Adding menus for coalition " .. coalitionID)
    local spicyATCMenu = missionCommands.addSubMenuForCoalition(coalitionID, "SpicyATC") -- Direct under F10 Other
    local groundMenu = missionCommands.addSubMenuForCoalition(coalitionID, "Ground Control", spicyATCMenu)
    local towerMenu = missionCommands.addSubMenuForCoalition(coalitionID, "Tower", spicyATCMenu)
    local approachMenu = missionCommands.addSubMenuForCoalition(coalitionID, "Approach", spicyATCMenu)
    missionCommands.addCommandForCoalition(coalitionID, "Request Startup", groundMenu, requestStartup)
    missionCommands.addCommandForCoalition(coalitionID, "Request Taxi", groundMenu, requestTaxi)
    missionCommands.addCommandForCoalition(coalitionID, "Request Takeoff", towerMenu, requestTakeoff)
    missionCommands.addCommandForCoalition(coalitionID, "Inbound VFR/IFR", approachMenu, requestInbound)
end

local function onEvent(event)
    if event.id == world.event.S_EVENT_PLAYER_ENTER_UNIT then
        local unit = event.initiator
        if unit and unit:isExist() then
            env.info("SpicyATC: Player entered unit " .. unit:getName() .. ", coalition " .. unit:getCoalition())
            addATCMenus(unit:getCoalition()) -- Add on enter to ensure timing
        end
    elseif event.id == world.event.S_EVENT_TAKEOFF then
        local unit = world.getPlayer()
        if unit then
            trigger.action.outTextForUnit(unit:getID(), "ATC Tower: Takeoff noted. Good flight.", 10, false)
        end
    end
end

-- Initialize event handler
env.info("SpicyATC: Script loaded at " .. timer.getTime())
for _, coalitionID in pairs({coalition.side.BLUE, coalition.side.RED, coalition.side.NEUTRAL}) do
    addATCMenus(coalitionID)
end
world.addEventHandler({onEvent = onEvent})
