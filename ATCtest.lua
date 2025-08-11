-- MyBMSATC.lua - BMS-style ATC for DCS Missions written by Spicy
local function onEvent(event)
    if event.id == world.event.S_EVENT_BIRTH and event.initiator == playerUnit then
        -- Add menus, advise freq
        local groupID = playerUnit:getGroup():getID()
        radio.addCommandForGroup(groupID, "Ground: Request Startup", {func = requestStartup})
    elseif event.id == world.event.S_EVENT_RADIO_MESSAGE then
        -- Parse response, add system msg, freq check
        trigger.action.outText("ATC: " .. event.text, 10, false)
    -- Add more events: takeoff, landing
    end
end

local function requestStartup()
    local group = playerUnit:getGroup()
    local msg = #group:getUnits() > 1 and "Flight cleared for startup" or "Cleared for startup"
    trigger.action.outText(msg, 10, false)
    -- Send to DCS ATC if needed
end

-- Similar funcs for taxi, takeoff

world.addEventHandler({onEvent = onEvent})
playerUnit = Unit.getByName('Player')  -- Assume single player; expand for MP