-- spicyATC.lua - BMS-style ATC for DCS Missions written by Spicy
-- Tracks player states per airbase, works in multiplayer, implements detailed states and queues.
-- Players select their home airbase from the menu, then access ATC options per player in group.
-- States: not_started|started|on_taxi|take_off|airborne|in_bound|approach|landed|parked
-- Menus are per group, with submenus per player for multi-player groups.
-- Queues per airbase for takeoff and landing to manage traffic.
-- Auto-sets airbase on player enter if close to one.

-- Global tables
local players = {}      -- unitName -> {coalitionID, groupID, airbaseName, state="not_started"|"started"|...}
local menuPaths = {}    -- groupID -> {spicyATC=menu, changeAirbaseMenu=menu, selectMenus={unitName=menu}, playerMenus={unitName={groundMenu=menu, towerMenu=menu, approachMenu=menu}}}
local takeoffQueues = {}  -- airbaseName -> {unitNames in order waiting for takeoff}
local landingQueues = {}  -- airbaseName -> {unitNames in order waiting for landing}

-- Helper to get airbase object
local function getAirbase(airbaseName)
    return Airbase.getByName(airbaseName)
end

-- Helper to calculate distance in meters (horizontal only)
local function getHorizontalDistance(pos1, pos2)
    if not pos1 or not pos2 then return math.huge end
    return math.sqrt((pos1.x - pos2.x)^2 + (pos1.z - pos2.z)^2)
end

-- Helper to calculate distance in NM
local function getDistanceNM(unit, airbase)
    if not unit or not unit:isExist() or not airbase then return math.huge end
    local unitPos = unit:getPosition().p
    local abPos = airbase:getPosition().p
    local distM = getHorizontalDistance(unitPos, abPos)
    return distM / 1852  -- Meters to NM
end

-- Helper to get closest airbase
local function getClosestAirbase(unit)
    if not unit or not unit:isExist() then return nil, math.huge end
    local coalitionID = unit:getCoalition()
    local airbases = coalition.getAirbases(coalitionID)
    if #airbases == 0 then return nil, math.huge end
    local unitPos = unit:getPosition().p
    local closest = nil
    local minDist = math.huge
    for _, ab in ipairs(airbases) do
        local abPos = ab:getPosition().p
        local dist = getHorizontalDistance(unitPos, abPos)
        if dist < minDist then
            minDist = dist
            closest = ab
        end
    end
    return closest, minDist
end

-- Helper to get placeholder runway (later dynamic)
local function getRunway(airbase)
    -- Placeholder; later use airbase:getRunways() or airbase:getDesc() for active runway
    return "09"
end

-- Function to add or update player-specific menus
local function updatePlayerMenus(groupID, unitName)
    local p = players[unitName]
    if not p or not menuPaths[groupID] then return end

    -- Remove existing player menus if any
    local playerMenuPaths = menuPaths[groupID].playerMenus[unitName] or {}
    if playerMenuPaths.groundMenu then missionCommands.removeItemForGroup(groupID, playerMenuPaths.groundMenu) end
    if playerMenuPaths.towerMenu then missionCommands.removeItemForGroup(groupID, playerMenuPaths.towerMenu) end
    if playerMenuPaths.approachMenu then missionCommands.removeItemForGroup(groupID, playerMenuPaths.approachMenu) end
    menuPaths[groupID].playerMenus[unitName] = nil

    -- Add player submenu
    local spicyATC = menuPaths[groupID].spicyATC
    local playerSubMenu = missionCommands.addSubMenuForGroup(groupID, "For " .. unitName, spicyATC)
    menuPaths[groupID].selectMenus[unitName] = playerSubMenu

    -- Add ATC submenus based on state and airbase selected
    if not p.airbaseName then return end

    local groundMenu = missionCommands.addSubMenuForGroup(groupID, "Ground Control", playerSubMenu)
    menuPaths[groupID].playerMenus[unitName] = {groundMenu = groundMenu}

    if p.state == "not_started" then
        missionCommands.addCommandForGroup(groupID, "Request Startup", groundMenu, requestStartup, {unitName = unitName, groupID = groupID})
    elseif p.state == "started" then
        missionCommands.addCommandForGroup(groupID, "Request Taxi", groundMenu, requestTaxi, {unitName = unitName, groupID = groupID})
    elseif p.state == "landed" then
        missionCommands.addCommandForGroup(groupID, "Request Taxi to Parking", groundMenu, requestTaxiToParking, {unitName = unitName, groupID = groupID})
    elseif p.state == "parked" then
        missionCommands.addCommandForGroup(groupID, "Request Shutdown", groundMenu, requestShutdown, {unitName = unitName, groupID = groupID})
    end

    local towerMenu = missionCommands.addSubMenuForGroup(groupID, "Tower", playerSubMenu)
    menuPaths[groupID].playerMenus[unitName].towerMenu = towerMenu

    if p.state == "on_taxi" then
        missionCommands.addCommandForGroup(groupID, "Request Takeoff", towerMenu, requestTakeoff, {unitName = unitName, groupID = groupID})
    elseif p.state == "take_off" then
        missionCommands.addCommandForGroup(groupID, "Request Handoff", towerMenu, requestHandoff, {unitName = unitName, groupID = groupID})
    end

    local approachMenu = missionCommands.addSubMenuForGroup(groupID, "Approach", playerSubMenu)
    menuPaths[groupID].playerMenus[unitName].approachMenu = approachMenu

    if p.state == "airborne" then
        missionCommands.addCommandForGroup(groupID, "Request Inbound", approachMenu, requestInbound, {unitName = unitName, groupID = groupID})
    elseif p.state == "in_bound" then
        missionCommands.addCommandForGroup(groupID, "Request Approach", approachMenu, requestApproach, {unitName = unitName, groupID = groupID})
    elseif p.state == "approach" then
        missionCommands.addCommandForGroup(groupID, "Request Landing Clearance", approachMenu, requestLanding, {unitName = unitName, groupID = groupID})
    end
end

-- Function to select/change airbase
local function selectAirbase(args)
    env.info("SpicyATC: Player " .. args.unitName .. " selecting airbase " .. args.airbaseName)
    local unit = Unit.getByName(args.unitName)
    if not unit or not unit:isExist() then return end
    local groupID = args.groupID
    local p = players[args.unitName]
    if not p then return end
    p.airbaseName = args.airbaseName
    if not p.state or p.state == "airborne" then p.state = "not_started" end  -- Reset to initial if no state or airborne

    -- Update menus
    updatePlayerMenus(groupID, args.unitName)

    trigger.action.outTextForGroup(groupID, "ATC: Home airbase set to " .. args.airbaseName .. ". Use menus for requests.", 10, false)
end

-- Function to add initial menus when player enters unit
local function addATCMenus(unit)
    if not unit or not unit:isExist() then return end
    local group = unit:getGroup()
    if not group then return end
    local groupID = group:getID()
    local unitName = unit:getName()
    local coalitionID = unit:getCoalition()

    -- Initialize player data
    players[unitName] = {coalitionID = coalitionID, groupID = groupID, airbaseName = nil, state = "not_started"}

    -- If menus not added for group yet
    if not menuPaths[groupID] then
        menuPaths[groupID] = {playerMenus = {}, selectMenus = {}}
        local spicyATC = missionCommands.addSubMenuForGroup(groupID, "SpicyATC")
        menuPaths[groupID].spicyATC = spicyATC
        local changeMenu = missionCommands.addSubMenuForGroup(groupID, "Change Home Airbase", spicyATC)
        menuPaths[groupID].changeAirbaseMenu = changeMenu
        local airbases = coalition.getAirbases(coalitionID)
        for _, ab in ipairs(airbases) do
            local abName = ab:getName()
            missionCommands.addCommandForGroup(groupID, abName, changeMenu, selectAirbase, {unitName = unitName, groupID = groupID, airbaseName = abName})
        end
    end

    -- Auto-set closest airbase if on ground and close enough
    if not unit:inAir() then
        local closest, dist = getClosestAirbase(unit)
        if closest and dist < 5000 then  -- 5km threshold
            players[unitName].airbaseName = closest:getName()
            env.info("SpicyATC: Auto-set airbase for " .. unitName .. " to " .. closest:getName() .. " (dist: " .. dist .. "m)")
            trigger.action.outTextForGroup(groupID, "ATC: Auto-detected home airbase " .. closest:getName() .. ". Change if needed.", 10, false)
        end
    end

    -- Add player-specific submenu and update
    updatePlayerMenus(groupID, unitName)
    env.info("SpicyATC: Menus added/updated for group " .. groupID .. ", player " .. unitName)
end

-- Request Startup: "not_started" -> "started"
local function requestStartup(args)
    env.info("SpicyATC: Request Startup for " .. args.unitName)
    local unit = Unit.getByName(args.unitName)
    if not unit or not unit:isExist() then return end
    local groupID = args.groupID
    local p = players[args.unitName]
    if not p or not p.airbaseName then
        trigger.action.outTextForGroup(groupID, "ATC: Select home airbase first.", 10, false)
        return
    end
    if p.state ~= "not_started" then
        trigger.action.outTextForGroup(groupID, "ATC: Not in correct state for startup.", 10, false)
        return
    end
    p.state = "started"
    local group = unit:getGroup()
    local numUnits = #group:getUnits()
    local msg = numUnits > 1 and "Flight cleared for startup (" .. numUnits .. " aircraft)" or "Cleared for startup"
    trigger.action.outTextForGroup(groupID, "ATC Ground: " .. msg, 10, false)
    updatePlayerMenus(groupID, args.unitName)
end

-- Request Taxi: "started" -> "on_taxi"
local function requestTaxi(args)
    env.info("SpicyATC: Request Taxi for " .. args.unitName)
    local unit = Unit.getByName(args.unitName)
    if not unit or not unit:isExist() then return end
    local groupID = args.groupID
    local p = players[args.unitName]
    if not p or not p.airbaseName then return end
    if p.state ~= "started" then
        trigger.action.outTextForGroup(groupID, "ATC: Not cleared for taxi yet.", 10, false)
        return
    end
    p.state = "on_taxi"
    local airbase = getAirbase(p.airbaseName)
    local runway = getRunway(airbase)
    local msg = "Taxi lane E to F, then hold short runway " .. runway .. ". Switch to tower."
    trigger.action.outTextForGroup(groupID, "ATC Ground: " .. msg, 10, false)
    updatePlayerMenus(groupID, args.unitName)
end

-- Request Takeoff: "on_taxi" -> "take_off" if first in queue
local function requestTakeoff(args)
    env.info("SpicyATC: Request Takeoff for " .. args.unitName)
    local unit = Unit.getByName(args.unitName)
    if not unit or not unit:isExist() then return end
    local groupID = args.groupID
    local p = players[args.unitName]
    if not p or not p.airbaseName then return end
    if p.state ~= "on_taxi" then
        trigger.action.outTextForGroup(groupID, "ATC: Not cleared for takeoff yet.", 10, false)
        return
    end
    local abName = p.airbaseName
    if not takeoffQueues[abName] then takeoffQueues[abName] = {} end
    local queue = takeoffQueues[abName]
    local position = #queue + 1
    table.insert(queue, args.unitName)
    if position == 1 then
        p.state = "take_off"
        local airbase = getAirbase(abName)
        local runway = getRunway(airbase)
        local msg = "Clear to take-off from runway " .. runway .. ", fly outbound heading for 3 miles, then call in for hand-off."
        trigger.action.outTextForGroup(groupID, "ATC Tower: " .. msg, 10, false)
    else
        trigger.action.outTextForGroup(groupID, "ATC Tower: Hold short, you are number " .. position .. " for takeoff.", 10, false)
    end
    updatePlayerMenus(groupID, args.unitName)
end

-- Request Handoff: "take_off" -> "airborne"
local function requestHandoff(args)
    env.info("SpicyATC: Request Handoff for " .. args.unitName)
    local unit = Unit.getByName(args.unitName)
    if not unit or not unit:isExist() then return end
    local groupID = args.groupID
    local p = players[args.unitName]
    if not p or not p.airbaseName then return end
    if p.state ~= "take_off" then
        trigger.action.outTextForGroup(groupID, "ATC: Not in takeoff state.", 10, false)
        return
    end
    setAirborne(args.unitName)
end

-- Function to set airborne and handle queue
local function setAirborne(unitName)
    local p = players[unitName]
    if not p then return end
    local abName = p.airbaseName
    p.state = "airborne"
    p.airbaseName = nil
    local groupID = p.groupID
    trigger.action.outTextForGroup(groupID, "ATC Tower: Handoff acknowledged. Good flight.", 10, false)
    updatePlayerMenus(groupID, unitName)

    -- Remove from takeoff queue
    if takeoffQueues[abName] then
        for i, u in ipairs(takeoffQueues[abName]) do
            if u == unitName then
                table.remove(takeoffQueues[abName], i)
                break
            end
        end
        -- Notify next if any
        if #takeoffQueues[abName] > 0 then
            local nextUnit = takeoffQueues[abName][1]
            local nextP = players[nextUnit]
            if nextP then
                local nextGroupID = nextP.groupID
                local runway = getRunway(getAirbase(abName))
                trigger.action.outTextForGroup(nextGroupID, "ATC Tower: You are now clear to take-off from runway " .. runway .. ".", 10, false)
                nextP.state = "take_off"
                updatePlayerMenus(nextGroupID, nextUnit)
            end
        end
    end
end

-- Request Inbound: "airborne" -> "in_bound"
local function requestInbound(args)
    env.info("SpicyATC: Request Inbound for " .. args.unitName)
    local unit = Unit.getByName(args.unitName)
    if not unit or not unit:isExist() then return end
    local groupID = args.groupID
    local p = players[args.unitName]
    if not p or not p.airbaseName then
        trigger.action.outTextForGroup(groupID, "ATC: Select home airbase first.", 10, false)
        return
    end
    if p.state ~= "airborne" or not unit:inAir() then
        trigger.action.outTextForGroup(groupID, "ATC: Not airborne or incorrect state.", 10, false)
        return
    end
    p.state = "in_bound"
    local msg = "Inbound acknowledged. Proceed for approach."
    trigger.action.outTextForGroup(groupID, "ATC Approach: " .. msg, 10, false)
    -- Add to landing queue
    local abName = p.airbaseName
    if not landingQueues[abName] then landingQueues[abName] = {} end
    table.insert(landingQueues[abName], args.unitName)
    updatePlayerMenus(groupID, args.unitName)
end

-- Request Approach: "in_bound" -> "approach" if within 10NM
local function requestApproach(args)
    env.info("SpicyATC: Request Approach for " .. args.unitName)
    local unit = Unit.getByName(args.unitName)
    if not unit or not unit:isExist() then return end
    local groupID = args.groupID
    local p = players[args.unitName]
    if not p or not p.airbaseName then return end
    if p.state ~= "in_bound" then
        trigger.action.outTextForGroup(groupID, "ATC: Not in inbound state.", 10, false)
        return
    end
    local airbase = getAirbase(p.airbaseName)
    local dist = getDistanceNM(unit, airbase)
    if dist > 10 then
        trigger.action.outTextForGroup(groupID, "ATC: Too far for approach (current " .. math.floor(dist) .. " NM).", 10, false)
        return
    end
    p.state = "approach"
    local msg = "Approach cleared. Expect vectors to runway."
    trigger.action.outTextForGroup(groupID, "ATC Approach: " .. msg, 10, false)
    updatePlayerMenus(groupID, args.unitName)
end

-- Request Landing: "approach" -> grant if first in queue
local function requestLanding(args)
    env.info("SpicyATC: Request Landing for " .. args.unitName)
    local unit = Unit.getByName(args.unitName)
    if not unit or not unit:isExist() then return end
    local groupID = args.groupID
    local p = players[args.unitName]
    if not p or not p.airbaseName then return end
    if p.state ~= "approach" then
        trigger.action.outTextForGroup(groupID, "ATC: Not in approach state.", 10, false)
        return
    end
    local abName = p.airbaseName
    local queue = landingQueues[abName] or {}
    local position = 0
    for i, u in ipairs(queue) do
        if u == args.unitName then position = i; break end
    end
    if position == 1 then
        local runway = getRunway(getAirbase(abName))
        local msg = "Cleared to land runway " .. runway .. "."
        trigger.action.outTextForGroup(groupID, "ATC Tower: " .. msg, 10, false)
    else
        trigger.action.outTextForGroup(groupID, "ATC Tower: Number " .. position .. " for landing. Maintain pattern.", 10, false)
    end
end

-- Request Taxi to Parking: "landed" -> "parked"
local function requestTaxiToParking(args)
    env.info("SpicyATC: Request Taxi to Parking for " .. args.unitName)
    local unit = Unit.getByName(args.unitName)
    if not unit or not unit:isExist() then return end
    local groupID = args.groupID
    local p = players[args.unitName]
    if not p or not p.airbaseName then return end
    if p.state ~= "landed" then
        trigger.action.outTextForGroup(groupID, "ATC: Not landed.", 10, false)
        return
    end
    p.state = "parked"
    local msg = "Taxi in reverse of original path to parking."
    trigger.action.outTextForGroup(groupID, "ATC Ground: " .. msg, 10, false)
    updatePlayerMenus(groupID, args.unitName)
end

-- Request Shutdown: "parked" -> final
local function requestShutdown(args)
    env.info("SpicyATC: Request Shutdown for " .. args.unitName)
    local unit = Unit.getByName(args.unitName)
    if not unit or not unit:isExist() then return end
    local groupID = args.groupID
    local p = players[args.unitName]
    if not p or not p.airbaseName then return end
    if p.state ~= "parked" then
        trigger.action.outTextForGroup(groupID, "ATC: Not parked.", 10, false)
        return
    end
    trigger.action.outTextForGroup(groupID, "ATC Ground: Cleared for shutdown. Good day.", 10, false)
end

-- Event handler
local function onEvent(event)
    if event.id == world.event.S_EVENT_PLAYER_ENTER_UNIT or event.id == world.event.S_EVENT_BIRTH then
        local unit = event.initiator
        if unit and unit:isExist() and unit:getPlayerName() then
            env.info("SpicyATC: Player entered unit " .. unit:getName() .. ", coalition " .. unit:getCoalition())
            addATCMenus(unit)
        end
    elseif event.id == world.event.S_EVENT_TAKEOFF then
        local unit = event.initiator
        if unit and unit:isExist() and players[unit:getName()] then
            local p = players[unit:getName()]
            if p.state == "take_off" and event.place and event.place:getName() == p.airbaseName then
                setAirborne(unit:getName())
            end
        end
    elseif event.id == world.event.S_EVENT_LAND then
        local unit = event.initiator
        if unit and unit:isExist() and players[unit:getName()] then
            local p = players[unit:getName()]
            if p.state == "approach" and event.place and event.place:getName() == p.airbaseName then
                p.state = "landed"
                local groupID = p.groupID
                trigger.action.outTextForGroup(groupID, "ATC Tower: Landing noted. Contact ground for taxi.", 10, false)
                updatePlayerMenus(groupID, unit:getName())
                -- Remove from landing queue
                local abName = p.airbaseName
                if landingQueues[abName] then
                    for i, u in ipairs(landingQueues[abName]) do
                        if u == unit:getName() then
                            table.remove(landingQueues[abName], i)
                            break
                        end
                    end
                    -- Notify next if any
                    if #landingQueues[abName] > 0 then
                        local nextUnit = landingQueues[abName][1]
                        local nextP = players[nextUnit]
                        if nextP then
                            local nextGroupID = nextP.groupID
                            local runway = getRunway(getAirbase(abName))
                            trigger.action.outTextForGroup(nextGroupID, "ATC Tower: You are now cleared to land runway " .. runway .. ".", 10, false)
                        end
                    end
                end
            end
        end
    end
end

-- Periodic check for auto-approach (every 30s)
local function checkApproach()
    for unitName, p in pairs(players) do
        if p.state == "in_bound" and p.airbaseName then
            local unit = Unit.getByName(unitName)
            if unit and unit:isExist() and unit:inAir() then
                local airbase = getAirbase(p.airbaseName)
                local dist = getDistanceNM(unit, airbase)
                if dist <= 10 then
                    p.state = "approach"
                    local groupID = p.groupID
                    trigger.action.outTextForGroup(groupID, "ATC: Entering approach phase.", 10, false)
                    updatePlayerMenus(groupID, unitName)
                end
            end
        end
    end
    return timer.getTime() + 30
end

-- Initialize
env.info("SpicyATC: Script loaded at " .. timer.getTime())
world.addEventHandler({onEvent = onEvent})
timer.scheduleFunction(checkApproach, {}, timer.getTime() + 30)
