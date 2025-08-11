-- spicyATC.lua - BMS-style ATC for DCS Missions written by Spicy
-- Expanded for F10 radio menu with three categories (Ground, Tower, Approach)

local playerUnits = {}  -- Table to track players for MP

local function adviseFreq(unit)
    local airbases = coalition.getAirbases(unit:getCoalition())
    if #airbases > 0 then
        local nearestAirbase = airbases[1]  -- Simple nearest; expand with distance calc later
        local atcFreq = nearestAirbase:getFrequency() / 1000000  -- In MHz
        local playerFreq = unit:getCommunicator():getFrequency() / 1000000
        if playerFreq ~= atcFreq then
            trigger.action.outTextForUnit(unit:getID(), "ATC: Switch to " .. atcFreq .. " MHz", 10, false)
        end
        return atcFreq
    end
end

local function requestStartup(unit)
    adviseFreq(unit)  -- Check/advise freq
    local group = unit:getGroup()
    local numUnits = #group:getUnits()
    local msg = numUnits > 1 and "Flight cleared for startup (" .. numUnits .. " aircraft)" or "Cleared for startup"
    trigger.action.outTextForUnit(unit:getID(), "ATC Ground: " .. msg, 10, false)
    -- Needs more work 
end

local function requestTaxi(unit)
    adviseFreq(unit)
    -- Taxi path logic
    local msg = "Taxi via E, right on D. Hold short runway 09."
    trigger.action.outTextForUnit(unit:getID(), "ATC Ground: " .. msg, 10, false)
end

local function requestTakeoff(unit)
    adviseFreq(unit)
    -- Placeholder: Clearance with plan
    local msg = "Cleared takeoff runway 09, fly heading 270, contact Tower on [freq]."
    trigger.action.outTextForUnit(unit:getID(), "ATC Tower: " .. msg, 10, false)
end

local function requestInbound(unit)
    adviseFreq(unit)
    -- Placeholder for Approach
    local msg = "Inbound acknowledged. Fly heading 180 for vectors."
    trigger.action.outTextForUnit(unit:getID(), "ATC Approach: " .. msg, 10, false)
end

local function addATCMenusForPlayer(unit)
    local groupID = unit:getGroup():getID()
    
    -- Top-level ATC menu under F10
    local atcMenu = radio.addSubMenuForGroup(groupID, "Spicy ATC")
    
    -- Submenus for categories
    local groundMenu = radio.addSubMenuForGroup(groupID, "Ground Control", atcMenu)
    local towerMenu = radio.addSubMenuForGroup(groupID, "Tower", atcMenu)
    local approachMenu = radio.addSubMenuForGroup(groupID, "Approach", atcMenu)
    
    -- Add commands to Ground
    radio.addCommandForGroup(groupID, "Request Startup", groundMenu, requestStartup, unit)
    radio.addCommandForGroup(groupID, "Request Taxi", groundMenu, requestTaxi, unit)
    
    -- Add commands to Tower
    radio.addCommandForGroup(groupID, "Request Takeoff", towerMenu, requestTakeoff, unit)
    
    -- Add commands to Approach
    radio.addCommandForGroup(groupID, "Inbound VFR/IFR", approachMenu, requestInbound, unit)
end

local function onEvent(event)
    if event.id == world.event.S_EVENT_PLAYER_ENTER_UNIT then
        local unit = event.initiator
        if unit and unit:isExist() then
            playerUnits[unit:getID()] = unit
            addATCMenusForPlayer(unit)  -- Add menus when player enters unit
        end
    elseif event.id == world.event.S_EVENT_RADIO_MESSAGE then
        -- Parse default ATC responses, enhance with system msg (placeholder)
        if event.initiator and playerUnits[event.initiator:getID()] then
            trigger.action.outTextForUnit(event.initiator:getID(), "ATC: " .. (event.text or "Response received"), 10, false)
        end
    -- Add more events: e.g., S_EVENT_TAKEOFF, S_EVENT_LAND
    elseif event.id == world.event.S_EVENT_TAKEOFF then
        if event.initiator and playerUnits[event.initiator:getID()] then
            trigger.action.outTextForUnit(event.initiator:getID(), "ATC Tower: Takeoff noted. Good flight.", 10, false)
        end
    end
end

world.addEventHandler({onEvent = onEvent})

