-- spicyATC.lua - BMS-style ATC for DCS Missions written by Spicy
-- Single-player focus with world.getPlayer(), enhanced states and queues, coalition F10 menus
local players = {}      -- unitName -> {coalitionID, airbaseName, state="not_started"|"started"|...}
local menuPaths = {}    -- coalitionID -> {spicyATC=menu}
local takeoffQueues = {}  -- airbaseName -> {unitNames in order waiting for takeoff}
local landingQueues = {}  -- airbaseName -> {unitNames in order waiting for landing}

-- Helper to get airbase object
local function getAirbase(airbaseName)
    local airbase = Airbase.getByName(airbaseName)
    if not airbase then env.info("SpicyATC: Failed to get airbase " .. tostring(airbaseName)) end
    return airbase
end

-- Helper to get placeholder runway
local function getRunway(airbase)
    if not airbase then return "09" end
    return "09" -- Placeholder
end

-- Function to select airbase and update player data
local function selectAirbase(args)
    env.info("SpicyATC: Player selecting airbase " .. args.airbaseName)
    local unit = world.getPlayer()
    if not unit or not unit:isExist() then return end
    local coalitionID = unit:getCoalition()
    local unitName = unit:getName()
    local p = players[unitName] or {coalitionID = coalitionID, airbaseName = nil, state = "not_started"}
    players[unitName] = p
    p.airbaseName = args.airbaseName
    if not p.state or p.state == "airborne" then p.state = "not_started" end
    trigger.action.outTextForCoalition(coalitionID, "ATC: Home airbase set to " .. args.airbaseName .. ".", 10, false)
end

-- Function to add initial menus when player enters unit
local function addATCMenus(unit)
    if not unit or not unit:isExist() then
        env.info("SpicyATC: Invalid unit for menu addition: " .. tostring(unit))
        return
    end
    local unitName = unit:getName()
    local coalitionID = unit:getCoalition()
    env.info("SpicyATC: Adding menus for " .. unitName .. ", coalition " .. coalitionID)

    players[unitName] = {coalitionID = coalitionID, airbaseName = nil, state = "not_started"}

    if not menuPaths[coalitionID] then
        menuPaths[coalitionID] = {}
        local spicyATCMenu = missionCommands.addSubMenuForCoalition(coalitionID, "SpicyATC")
        menuPaths[coalitionID].spicyATC = spicyATCMenu

        missionCommands.addCommandForCoalition(coalitionID, "Change Home Airbase", spicyATCMenu, function()
            local unit = world.getPlayer()
            if not unit or not unit:isExist() then return end
            local coalitionID = unit:getCoalition()
            local airbases = coalition.getAirbases(coalitionID)
            if airbases and #airbases > 0 then
                for _, ab in ipairs(airbases) do
                    local abName = ab:getName()
                    missionCommands.addCommandForCoalition(coalitionID, abName, spicyATCMenu, selectAirbase, {airbaseName = abName})
                end
            else
                env.info("SpicyATC: No airbases found for coalition " .. coalitionID)
            end
        end)

        missionCommands.addCommandForCoalition(coalitionID, "Request Startup", spicyATCMenu, requestStartup)
        missionCommands.addCommandForCoalition(coalitionID, "Request Taxi", spicyATCMenu, requestTaxi)
        missionCommands.addCommandForCoalition(coalitionID, "Request Takeoff", spicyATCMenu, requestTakeoff)
        missionCommands.addCommandForCoalition(coalitionID, "Inbound VFR/IFR", spicyATCMenu, requestInbound)
    end
end

-- Retry menu addition for players
local function retryAddMenus()
    local unit = world.getPlayer()
    if unit and unit:isExist() then
        local unitName = unit:getName()
        local coalitionID = unit:getCoalition()
        if not menuPaths[coalitionID] then
            env.info("SpicyATC: Retrying menu addition for " .. unitName)
            addATCMenus(unit)
        end
    end
    return timer.getTime() + 10
end

-- Request Startup: "not_started" -> "started"
local function requestStartup()
    env.info("SpicyATC: Request Startup")
    local unit = world.getPlayer()
    if not unit or not unit:isExist() then
        env.info("SpicyATC: No player unit found, aborting startup")
        return
    end
    local coalitionID = unit:getCoalition()
    local unitName = unit:getName()
    local p = players[unitName]
    if not p or not p.airbaseName then
        trigger.action.outTextForCoalition(coalitionID, "ATC: Select home airbase first.", 10, false)
        return
    end
    if p.state ~= "not_started" then
        trigger.action.outTextForCoalition(coalitionID, "ATC: Not in correct state for startup.", 10, false)
        return
    end
    p.state = "started"
    local group = unit:getGroup()
    local numUnits = group and #group:getUnits() or 1
    local msg = numUnits > 1 and "Flight cleared for startup (" .. numUnits .. " aircraft)" or "Cleared for startup"
    trigger.action.outTextForCoalition(coalitionID, "ATC Ground: " .. msg, 10, false)
end

-- Request Taxi: "started" -> "on_taxi"
local function requestTaxi()
    env.info("SpicyATC: Request Taxi")
    local unit = world.getPlayer()
    if not unit or not unit:isExist() then
        env.info("SpicyATC: No player unit found, aborting taxi")
        return
    end
    local coalitionID = unit:getCoalition()
    local unitName = unit:getName()
    local p = players[unitName]
    if not p or not p.airbaseName then
        trigger.action.outTextForCoalition(coalitionID, "ATC: Select home airbase first.", 10, false)
        return
    end
    if p.state ~= "started" then
        trigger.action.outTextForCoalition(coalitionID, "ATC: Not cleared for taxi yet.", 10, false)
        return
    end
    p.state = "on_taxi"
    local msg = "Taxi via E, right on D. Hold short runway 09."
    trigger.action.outTextForCoalition(coalitionID, "ATC Ground: " .. msg, 10, false)
end

-- Request Takeoff: "on_taxi" -> "take_off" if first in queue
local function requestTakeoff()
    env.info("SpicyATC: Request Takeoff")
    local unit = world.getPlayer()
    if not unit or not unit:isExist() then
        env.info("SpicyATC: No player unit found, aborting takeoff")
        return
    end
    local coalitionID = unit:getCoalition()
    local unitName = unit:getName()
    local p = players[unitName]
    if not p or not p.airbaseName then
        trigger.action.outTextForCoalition(coalitionID, "ATC: Select home airbase first.", 10, false)
        return
    end
    if p.state ~= "on_taxi" then
        trigger.action.outTextForCoalition(coalitionID, "ATC: Not cleared for takeoff yet.", 10, false)
        return
    end
    local abName = p.airbaseName
    if not takeoffQueues[abName] then takeoffQueues[abName] = {} end
    local queue = takeoffQueues[abName]
    local position = #queue + 1
    table.insert(queue, unitName)
    if position == 1 then
        p.state = "take_off"
        local msg = "Cleared takeoff runway 09, fly heading 270."
        trigger.action.outTextForCoalition(coalitionID, "ATC Tower: " .. msg, 10, false)
    else
        trigger.action.outTextForCoalition(coalitionID, "ATC Tower: Hold short, you are number " .. position .. " for takeoff.", 10, false)
    end
end

-- Request Handoff: "take_off" -> "airborne"
local function requestHandoff()
    env.info("SpicyATC: Request Handoff")
    local unit = world.getPlayer()
    if not unit or not unit:isExist() then return end
    local coalitionID = unit:getCoalition()
    local unitName = unit:getName()
    local p = players[unitName]
    if not p or not p.airbaseName then return end
    if p.state ~= "take_off" then
        trigger.action.outTextForCoalition(coalitionID, "ATC: Not in takeoff state.", 10, false)
        return
    end
    setAirborne(unitName)
end

-- Function to set airborne and handle queue
local function setAirborne(unitName)
    local p = players[unitName]
    if not p then return end
    local abName = p.airbaseName
    p.state = "airborne"
    p.airbaseName = nil
    local coalitionID = p.coalitionID
    trigger.action.outTextForCoalition(coalitionID, "ATC Tower: Handoff acknowledged. Good flight.", 10, false)

    if takeoffQueues[abName] then
        for i, u in ipairs(takeoffQueues[abName]) do
            if u == unitName then
                table.remove(takeoffQueues[abName], i)
                break
            end
        end
        if #takeoffQueues[abName] > 0 then
            local nextUnit = takeoffQueues[abName][1]
            local nextP = players[nextUnit]
            if nextP then
                local nextCoalitionID = nextP.coalitionID
                local runway = getRunway(getAirbase(abName))
                trigger.action.outTextForCoalition(nextCoalitionID, "ATC Tower: You are now clear to take-off from runway " .. runway .. ".", 10, false)
                nextP.state = "take_off"
            end
        end
    end
end

-- Request Inbound: "airborne" -> "in_bound"
local function requestInbound()
    env.info("SpicyATC: Request Inbound")
    local unit = world.getPlayer()
    if not unit or not unit:isExist() then return end
    local coalitionID = unit:getCoalition()
    local unitName = unit:getName()
    local p = players[unitName]
    if not p or not p.airbaseName then
        trigger.action.outTextForCoalition(coalitionID, "ATC: Select home airbase first.", 10, false)
        return
    end
    if p.state ~= "airborne" or not unit:inAir() then
        trigger.action.outTextForCoalition(coalitionID, "ATC: Not airborne or incorrect state.", 10, false)
        return
    end
    p.state = "in_bound"
    local msg = "Inbound acknowledged. Fly heading 180 for vectors."
    trigger.action.outTextForCoalition(coalitionID, "ATC Approach: " .. msg, 10, false)
    local abName = p.airbaseName
    if not landingQueues[abName] then landingQueues[abName] = {} end
    table.insert(landingQueues[abName], unitName)
end

-- Request Approach: "in_bound" -> "approach" if within 10NM
local function requestApproach()
    env.info("SpicyATC: Request Approach")
    local unit = world.getPlayer()
    if not unit or not unit:isExist() then return end
    local coalitionID = unit:getCoalition()
    local unitName = unit:getName()
    local p = players[unitName]
    if not p or not p.airbaseName then return end
    if p.state ~= "in_bound" then
        trigger.action.outTextForCoalition(coalitionID, "ATC: Not in inbound state.", 10, false)
        return
    end
    local airbase = getAirbase(p.airbaseName)
    local dist = getDistanceNM(unit, airbase)
    if dist > 10 then
        trigger.action.outTextForCoalition(coalitionID, "ATC: Too far for approach (current " .. math.floor(dist) .. " NM).", 10, false)
        return
    end
    p.state = "approach"
    local msg = "Approach cleared. Expect vectors to runway."
    trigger.action.outTextForCoalition(coalitionID, "ATC Approach: " .. msg, 10, false)
end

-- Request Landing: "approach" -> grant if first in queue
local function requestLanding()
    env.info("SpicyATC: Request Landing")
    local unit = world.getPlayer()
    if not unit or not unit:isExist() then return end
    local coalitionID = unit:getCoalition()
    local unitName = unit:getName()
    local p = players[unitName]
    if not p or not p.airbaseName then return end
    if p.state ~= "approach" then
        trigger.action.outTextForCoalition(coalitionID, "ATC: Not in approach state.", 10, false)
        return
    end
    local abName = p.airbaseName
    local queue = landingQueues[abName] or {}
    local position = 0
    for i, u in ipairs(queue) do
        if u == unitName then position = i; break end
    end
    if position == 1 then
        local runway = getRunway(getAirbase(abName))
        local msg = "Cleared to land runway " .. runway .. "."
        trigger.action.outTextForCoalition(coalitionID, "ATC Tower: " .. msg, 10, false)
    else
        trigger.action.outTextForCoalition(coalitionID, "ATC Tower: Number " .. position .. " for landing. Maintain pattern.", 10, false)
    end
end

-- Request Taxi to Parking: "landed" -> "parked"
local function requestTaxiToParking()
    env.info("SpicyATC: Request Taxi to Parking")
    local unit = world.getPlayer()
    if not unit or not unit:isExist() then return end
    local coalitionID = unit:getCoalition()
    local unitName = unit:getName()
    local p = players[unitName]
    if not p or not p.airbaseName then return end
    if p.state ~= "landed" then
        trigger.action.outTextForCoalition(coalitionID, "ATC: Not landed.", 10, false)
        return
    end
    p.state = "parked"
    local msg = "Taxi in reverse of original path to parking."
    trigger.action.outTextForCoalition(coalitionID, "ATC Ground: " .. msg, 10, false)
end

-- Request Shutdown: "parked" -> final
local function requestShutdown()
    env.info("SpicyATC: Request Shutdown")
    local unit = world.getPlayer()
    if not unit or not unit:isExist() then return end
    local coalitionID = unit:getCoalition()
    local unitName = unit:getName()
    local p = players[unitName]
    if not p or not p.airbaseName then return end
    if p.state ~= "parked" then
        trigger.action.outTextForCoalition(coalitionID, "ATC: Not parked.", 10, false)
        return
    end
    trigger.action.outTextForCoalition(coalitionID, "ATC Ground: Cleared for shutdown. Good day.", 10, false)
end

-- Event handler
local function onEvent(event)
    if event.id == world.event.S_EVENT_BIRTH then
        local unit = event.initiator
        if unit and unit:isExist() and unit:getPlayerName() then
            local unitName = unit:getName()
            env.info("SpicyATC: Player " .. unit:getPlayerName() .. " born in unit " .. unitName .. ", coalition " .. unit:getCoalition())
            addATCMenus(unit)
        end
    elseif event.id == world.event.S_EVENT_TAKEOFF then
        local unit = world.getPlayer()
        if unit and unit:isExist() then
            local unitName = unit:getName()
            local p = players[unitName]
            if p and p.state == "take_off" and event.place and event.place:getName() == p.airbaseName then
                env.info("SpicyATC: Takeoff event for " .. unitName)
                setAirborne(unitName)
            end
        end
    elseif event.id == world.event.S_EVENT_LAND then
        local unit = world.getPlayer()
        if unit and unit:isExist() then
            local unitName = unit:getName()
            local p = players[unitName]
            if p and p.state == "approach" and event.place and event.place:getName() == p.airbaseName then
                env.info("SpicyATC: Landing event for " .. unitName)
                p.state = "landed"
                local coalitionID = p.coalitionID
                trigger.action.outTextForCoalition(coalitionID, "ATC Tower: Landing noted. Contact ground for taxi.", 10, false)
                local abName = p.airbaseName
                if landingQueues[abName] then
                    for i, u in ipairs(landingQueues[abName]) do
                        if u == unitName then
                            table.remove(landingQueues[abName], i)
                            break
                        end
                    end
                    if #landingQueues[abName] > 0 then
                        local nextUnit = landingQueues[abName][1]
                        local nextP = players[nextUnit]
                        if nextP then
                            local nextCoalitionID = nextP.coalitionID
                            local runway = getRunway(getAirbase(abName))
                            trigger.action.outTextForCoalition(nextCoalitionID, "ATC Tower: You are now cleared to land runway " .. runway .. ".", 10, false)
                        end
                    end
                end
            end
        end
    end
end

-- Periodic check for auto-approach (every 30s)
local function checkApproach()
    local unit = world.getPlayer()
    if unit and unit:isExist() then
        local unitName = unit:getName()
        local p = players[unitName]
        if p and p.state == "in_bound" and p.airbaseName then
            local airbase = getAirbase(p.airbaseName)
            local dist = getDistanceNM(unit, airbase)
            if dist <= 10 then
                p.state = "approach"
                local coalitionID = p.coalitionID
                trigger.action.outTextForCoalition(coalitionID, "ATC: Entering approach phase.", 10, false)
            end
        end
    end
    return timer.getTime() + 30
end

-- Retry menu addition for players
local function retryAddMenus()
    local unit = world.getPlayer()
    if unit and unit:isExist() then
        local unitName = unit:getName()
        local coalitionID = unit:getCoalition()
        if not menuPaths[coalitionID] then
            env.info("SpicyATC: Retrying menu addition for " .. unitName)
            addATCMenus(unit)
        end
    end
    return timer.getTime() + 10
end

-- Initialize
env.info("SpicyATC: Script loaded at " .. timer.getTime())
for _, coalitionID in pairs({coalition.side.BLUE, coalition.side.RED, coalition.side.NEUTRAL}) do
    missionCommands.addSubMenuForCoalition(coalitionID, "SpicyATC")
end
world.addEventHandler({onEvent = onEvent})
timer.scheduleFunction(checkApproach, {}, timer.getTime() + 30)
timer.scheduleFunction(retryAddMenus, {}, timer.getTime() + 5)
