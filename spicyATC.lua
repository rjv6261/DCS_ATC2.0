-- spicyATC.lua - BMS-style ATC for DCS Missions written by Spicy
-- Uses missionCommands for '/' comms menu integration

local playerUnits = {}  -- Track player units

local function adviseFreq(unit)
    local airbases = coalition.getAirbases(unit:getCoalition())
    if #airbases > 0 then
        local nearestAirbase = airbases[1]  -- Simple nearest;
        local atcFreq = nearestAirbase:getFrequency() / 1000000  -- In MHz
        local playerFreq = unit:getCommunicator():getFrequency() / 1000000
        if playerFreq ~= atcFreq then
            trigger.action.outTextForUnit(unit:getID(), "ATC: Switch to " .. atcFreq .. " MHz", 10, false)
        end
        return atcFreq
    end
end

local function requestStartup(unit)
    adviseFreq(unit)
    local group = unit:getGroup()
    local numUnits = #group:getUnits()
    local msg = numUnits > 1 and "Flight cleared for startup (" .. numUnits .. " aircraft)" or "Cleared for startup"
    trigger.action.outTextForUnit(unit:getID(), "ATC Ground: " .. msg, 10, false)
end

local function requestTaxi(unit)
    adviseFreq(unit)
    local msg = "Taxi via E, right on D. Hold short runway 09."  -- Placeholder
    trigger.action.outTextForUnit(unit:getID(), "ATC Ground: " .. msg, 10, false)
end

local function requestTakeoff(unit)
    adviseFreq(unit)
    local msg = "Cleared takeoff runway 09, fly heading 270, contact Tower on [freq]."  -- Placeholder
    trigger.action.outTextForUnit(unit:getID(), "ATC Tower: " .. msg, 10, false)
end

local function requestInbound(unit)
    adviseFreq(unit)
    local msg = "Inbound acknowledged. Fly heading 180 for vectors."  -- Placeholder
    trigger.action.outTextForUnit(unit:getID(), "ATC Approach: " .. msg, 10, false)
end

local function addATCMenusForPlayer(unit)
    local groupID = unit:getGroup():getID()
    local coalitionID = unit:getCoalition()

    -- Add top-level "F10-Other" 
    local otherMenu = missionCommands.addSubMenuForCoalition(coalitionID, "F10-Other")
    
    -- Add "SpicyATC" submenu under F10-Other
    local spicyATCMenu = missionCommands.addSubMenuForCoalition(coalitionID, "SpicyATC", otherMenu)

    -- Add category submenus under SpicyATC
    local groundMenu = missionCommands.addSubMenuForCoalition(coalitionID, "Ground Control", spicyATCMenu)
    local towerMenu = missionCommands.addSubMenuForCoalition(coalitionID, "Tower", spicyATCMenu)
    local approachMenu = missionCommands.addSubMenuForCoalition(coalitionID, "Approach", spicyATCMenu)

    -- Add commands
    missionCommands.addCommandForCoalition(coalitionID, "Request Startup", groundMenu, requestStartup, unit)
    missionCommands.addCommandForCoalition(coalitionID, "Request Taxi", groundMenu, requestTaxi, unit)
    missionCommands.addCommandForCoalition(coalitionID, "Request Takeoff", towerMenu, requestTakeoff, unit)
    missionCommands.addCommandForCoalition(coalitionID, "Inbound VFR/IFR", approachMenu, requestInbound, unit)
end

local function onEvent(event)
    if event.id == world.event.S_EVENT_PLAYER_ENTER_UNIT then
        local unit = event.initiator
        if unit and unit:isExist() then
            playerUnits[unit:getID()] = unit
            addATCMenusForPlayer(unit)  -- Add menus when player enters unit
            env.info("SpicyATC: Menus added for unit " .. unit:getName())  -- Debug log
        end
    elseif event.id == world.event.S_EVENT_TAKEOFF then
        if event.initiator and playerUnits[event.initiator:getID()] then
            trigger.action.outTextForUnit(event.initiator:getID(), "ATC Tower: Takeoff noted. Good flight.", 10, false)
        end
    end
end

-- Initialize event handler
env.info("SpicyATC: Script loaded at " .. timer.getTime())  -- Debug log
world.addEventHandler({onEvent = onEvent})
