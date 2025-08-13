-- spicyATC.lua - BMS-style ATC for DCS Missions 
-- Author: Spicy
-- Scope: Single-player oriented (world.getPlayer) but coalition-safe. Only uses BLUE/RED/NEUTRAL.
-- Goal: Coalition-scoped airbase menus with nearest recommendation, full state flow, basic telemetry, event-driven updates.

---------------------------
-- State & Structures
---------------------------
local players          = {}   -- unitName -> { coalitionID, unitID, airbaseName, state }
local unitCoalitions   = {}   -- unitName -> coalitionID
local takeoffQueues    = {}   -- airbaseName -> { unitName1, ... }
local landingQueues    = {}   -- airbaseName -> { unitName1, ... }
local menuPaths        = {}   -- coalitionID -> { root, ground, tower, approach, selectAB }
local telemetry        = {}   -- unitName -> { time=number, point=vec3, speed_mps=number, alt_m=number }

---------------------------
-- Utility / Context
---------------------------
local function safeInfo(msg) pcall(env.info, "SpicyATC: " .. tostring(msg)) end

-- Fixed coalition IDs per spec
local function getActiveCoalitionIDs()
    return { coalition.side.BLUE, coalition.side.RED, coalition.side.NEUTRAL }
end

local function getPlayerContext()
    local unit = world.getPlayer()
    if not unit or not unit.isExist or not unit:isExist() then return nil end
    local ctx = {
        unit        = unit,
        unitName    = unit.getName and unit:getName() or nil,
        coalitionID = unit.getCoalition and unit:getCoalition() or nil,
        unitID      = unit.getID and unit:getID() or nil,
        group       = unit.getGroup and unit:getGroup() or nil,
        playerName  = unit.getPlayerName and unit:getPlayerName() or nil,
    }
    ctx.groupID = ctx.group and ctx.group.getID and ctx.group:getID() or nil
    return ctx
end

local function now() return timer.getTime() end
local function metersToNM(m) return m / 1852.0 end
local function planarDistanceMeters(a, b)
    local dx = (a.x or 0) - (b.x or 0)
    local dz = (a.z or 0) - (b.z or 0)
    return math.sqrt(dx * dx + dz * dz)
end

local function getDistanceNM(objA, objB)
    if not objA or not objB then return 1e9 end
    local pa = objA.getPoint and objA:getPoint() or objA
    local pb = objB.getPoint and objB:getPoint() or objB
    if not pa or not pb then return 1e9 end
    return metersToNM(planarDistanceMeters(pa, pb))
end

local function getAirbase(airbaseName)
    if not airbaseName then return nil end
    local ab = Airbase.getByName(airbaseName)
    if not ab then safeInfo("Failed to get airbase " .. tostring(airbaseName)) end
    return ab
end

local function listCoalitionAirbases(coalitionID)
    -- Per spec: do NOT fall back to world.getAirbases(); only show owned.
    local list = coalition.getAirbases(coalitionID) or {}
    return list
end

local function nearestOwnedAirbase(unit, coalitionID)
    local list = listCoalitionAirbases(coalitionID)
    if not unit or not unit.isExist or not unit:isExist() or #list == 0 then return nil end
    local up = unit:getPoint()
    local best, bestD = nil, 1e12
    for _, ab in ipairs(list) do
        local p = ab:getPoint()
        local d = planarDistanceMeters(up, p)
        if d < bestD then best, bestD = ab, d end
    end
    return best
end

-- Telemetry capture helper
local function captureTelemetry(unit)
    if not unit or not unit.isExist or not unit:isExist() then return end
    local name = unit:getName()
    local pt   = unit:getPoint()
    local vel  = unit.getVelocity and unit:getVelocity() or {x=0,y=0,z=0}
    local spd  = math.sqrt((vel.x or 0)^2 + (vel.y or 0)^2 + (vel.z or 0)^2)
    telemetry[name] = { time = now(), point = pt, speed_mps = spd, alt_m = pt.y or 0 }
end

---------------------------
-- Forward Declarations
---------------------------
local ensureMenusForCoalition
local rebuildAirbaseList
local selectAirbase
local requestStartup
local requestTaxi
local requestTakeoff
local requestHandoff
local setAirborne
local requestInbound
local requestApproach
local requestLanding
local requestTaxiToParking
local requestShutdown
local onEvent
local retryAddMenus
local periodicApproachTick

---------------------------
-- Menu Building
---------------------------
ensureMenusForCoalition = function(coalitionID)
    if not coalitionID then return end
    menuPaths[coalitionID] = menuPaths[coalitionID] or {}

    local paths = menuPaths[coalitionID]
    if not paths.root then
        -- Root
        paths.root = missionCommands.addSubMenuForCoalition(coalitionID, "SpicyATC")
        -- Submenus
        paths.ground   = missionCommands.addSubMenuForCoalition(coalitionID, "Ground",   paths.root)
        paths.tower    = missionCommands.addSubMenuForCoalition(coalitionID, "Tower",    paths.root)
        paths.approach = missionCommands.addSubMenuForCoalition(coalitionID, "Approach", paths.root)

        -- Ground commands
        rebuildAirbaseList(coalitionID) -- "Select Home Airbase" under Ground
        missionCommands.addCommandForCoalition(coalitionID, "Request Startup",     paths.ground,   requestStartup)
        missionCommands.addCommandForCoalition(coalitionID, "Request Taxi",        paths.ground,   requestTaxi)
        missionCommands.addCommandForCoalition(coalitionID, "Taxi to Parking",     paths.ground,   requestTaxiToParking)
        missionCommands.addCommandForCoalition(coalitionID, "Shutdown",            paths.ground,   requestShutdown)
        missionCommands.addCommandForCoalition(coalitionID, "Refresh Airbase List",paths.ground,   function() rebuildAirbaseList(coalitionID) end)

        -- Tower commands
        missionCommands.addCommandForCoalition(coalitionID, "Request Takeoff",     paths.tower,    requestTakeoff)
        missionCommands.addCommandForCoalition(coalitionID, "Request Handoff",     paths.tower,    requestHandoff)
        missionCommands.addCommandForCoalition(coalitionID, "Request Landing",     paths.tower,    requestLanding)

        -- Approach commands
        missionCommands.addCommandForCoalition(coalitionID, "Request Inbound",     paths.approach, requestInbound)
        missionCommands.addCommandForCoalition(coalitionID, "Request Approach",    paths.approach, requestApproach)

        safeInfo("Built menus for coalition " .. tostring(coalitionID))
    end
end

rebuildAirbaseList = function(coalitionID)
    if not coalitionID then return end
    local paths = menuPaths[coalitionID]
    if not paths or not paths.ground then return end

    -- Remove old select list
    if paths.selectAB then
        missionCommands.removeItemForCoalition(coalitionID, paths.selectAB)
        paths.selectAB = nil
    end

    paths.selectAB = missionCommands.addSubMenuForCoalition(coalitionID, "Select Home Airbase", paths.ground)

    -- Recommended (nearest owned)
    missionCommands.addCommandForCoalition(coalitionID, "Recommended (Nearest Owned)", paths.selectAB, function()
        local ctx = getPlayerContext(); if not ctx then return end
        local ab = nearestOwnedAirbase(ctx.unit, ctx.coalitionID)
        if ab then
            selectAirbase({ airbaseName = ab:getName() })
        else
            trigger.action.outTextForCoalition(ctx.coalitionID, "ATC: No owned airbases found.", 10, false)
        end
    end)

    -- Owned list only
    local list = listCoalitionAirbases(coalitionID)
    if #list == 0 then
        missionCommands.addCommandForCoalition(coalitionID, "(No owned airbases)", paths.selectAB, function() end)
    else
        table.sort(list, function(a,b) return a:getName() < b:getName() end)
        for _, ab in ipairs(list) do
            local abName = ab:getName()
            missionCommands.addCommandForCoalition(coalitionID, abName, paths.selectAB, selectAirbase, { airbaseName = abName })
        end
    end
end

---------------------------
-- Player Flow / State
---------------------------
selectAirbase = function(args)
    local abName = args and args.airbaseName or nil
    local ctx = getPlayerContext(); if not ctx or not abName then return end

    local p = players[ctx.unitName] or { coalitionID = ctx.coalitionID, unitID = ctx.unitID, airbaseName = nil, state = "not_started" }
    players[ctx.unitName] = p
    p.coalitionID = ctx.coalitionID
    p.unitID      = ctx.unitID
    p.airbaseName = abName
    if not p.state or p.state == "airborne" then p.state = "not_started" end

    trigger.action.outTextForCoalition(ctx.coalitionID, "ATC: Home airbase set to " .. abName .. ".", 10, false)
end

requestStartup = function()
    local ctx = getPlayerContext(); if not ctx then return end
    local p = players[ctx.unitName]
    if not p or not p.airbaseName then
        trigger.action.outTextForCoalition(ctx.coalitionID, "ATC: Select home airbase first.", 10, false); return
    end
    if p.state ~= "not_started" then
        trigger.action.outTextForCoalition(ctx.coalitionID, "ATC: Not in correct state for startup.", 10, false); return
    end
    p.state = "started"
    local group = ctx.group
    local numUnits = group and group.getUnits and #group:getUnits() or 1
    local msg = numUnits > 1 and ("Flight cleared for startup (" .. numUnits .. " aircraft).") or "Cleared for startup."
    trigger.action.outTextForCoalition(ctx.coalitionID, "ATC Ground: " .. msg, 10, false)
end

requestTaxi = function()
    local ctx = getPlayerContext(); if not ctx then return end
    local p = players[ctx.unitName]
    if not p or not p.airbaseName then
        trigger.action.outTextForCoalition(ctx.coalitionID, "ATC: Select home airbase first.", 10, false); return
    end
    if p.state ~= "started" then
        trigger.action.outTextForCoalition(ctx.coalitionID, "ATC: Not cleared for taxi yet.", 10, false); return
    end
    p.state = "on_taxi"
    trigger.action.outTextForCoalition(ctx.coalitionID, "ATC Ground: Taxi via E, right on D. Hold short runway 09.", 10, false)
end

requestTakeoff = function()
    local ctx = getPlayerContext(); if not ctx then return end
    local p = players[ctx.unitName]
    if not p or not p.airbaseName then
        trigger.action.outTextForCoalition(ctx.coalitionID, "ATC: Select home airbase first.", 10, false); return
    end
    if p.state ~= "on_taxi" then
        trigger.action.outTextForCoalition(ctx.coalitionID, "ATC: Not cleared for takeoff yet.", 10, false); return
    end
    local abName = p.airbaseName
    takeoffQueues[abName] = takeoffQueues[abName] or {}
    local q = takeoffQueues[abName]
    table.insert(q, ctx.unitName)
    local pos = #q
    if pos == 1 then
        p.state = "take_off"
        trigger.action.outTextForCoalition(ctx.coalitionID, "ATC Tower: Cleared takeoff runway 09, fly heading 270.", 10, false)
    else
        trigger.action.outTextForCoalition(ctx.coalitionID, "ATC Tower: Hold short, you are number " .. pos .. " for takeoff.", 10, false)
    end
end

requestHandoff = function()
    local ctx = getPlayerContext(); if not ctx then return end
    local p = players[ctx.unitName]; if not p or not p.airbaseName then return end
    if p.state ~= "take_off" then
        trigger.action.outTextForCoalition(ctx.coalitionID, "ATC: Not in takeoff state.", 10, false); return
    end
    setAirborne(ctx.unitName)
end

setAirborne = function(unitName)
    local p = players[unitName]; if not p then return end
    local abName = p.airbaseName
    p.state = "airborne"
    p.airbaseName = nil
    trigger.action.outTextForCoalition(p.coalitionID, "ATC Tower: Handoff acknowledged. Good flight.", 10, false)

    local q = takeoffQueues[abName]
    if q then
        for i, u in ipairs(q) do if u == unitName then table.remove(q, i) break end end
        if #q > 0 then
            local nextUnit = q[1]
            local nextP = players[nextUnit]
            if nextP then
                nextP.state = "take_off"
                trigger.action.outTextForCoalition(nextP.coalitionID, "ATC Tower: You are now cleared for takeoff runway 09.", 10, false)
            end
        end
    end
end

requestInbound = function()
    local ctx = getPlayerContext(); if not ctx then return end
    local p = players[ctx.unitName] or { coalitionID = ctx.coalitionID, unitID = ctx.unitID, state = "airborne" }
    players[ctx.unitName] = p

    -- If player hasn’t set a destination, recommend nearest owned
    if not p.airbaseName then
        local ab = nearestOwnedAirbase(ctx.unit, ctx.coalitionID)
        if ab then
            p.airbaseName = ab:getName()
            trigger.action.outTextForCoalition(ctx.coalitionID, "ATC: Destination set to nearest owned: " .. p.airbaseName .. ".", 10, false)
        else
            trigger.action.outTextForCoalition(ctx.coalitionID, "ATC: No owned airbases to inbound to.", 10, false); return
        end
    end

    if p.state ~= "airborne" or not ctx.unit:inAir() then
        trigger.action.outTextForCoalition(ctx.coalitionID, "ATC: Not airborne or incorrect state.", 10, false); return
    end
    p.state = "in_bound"
    landingQueues[p.airbaseName] = landingQueues[p.airbaseName] or {}
    table.insert(landingQueues[p.airbaseName], ctx.unitName)
    trigger.action.outTextForCoalition(ctx.coalitionID, "ATC Approach: Inbound acknowledged. Fly heading 180 for vectors.", 10, false)
end

requestApproach = function()
    local ctx = getPlayerContext(); if not ctx then return end
    local p = players[ctx.unitName]; if not p or not p.airbaseName then return end
    if p.state ~= "in_bound" then
        trigger.action.outTextForCoalition(ctx.coalitionID, "ATC: Not in inbound state.", 10, false); return
    end
    local ab = getAirbase(p.airbaseName)
    local d  = getDistanceNM(ctx.unit, ab)
    if d > 10 then
        trigger.action.outTextForCoalition(ctx.coalitionID, "ATC: Too far for approach (current " .. math.floor(d) .. " NM).", 10, false); return
    end
    p.state = "approach"
    trigger.action.outTextForCoalition(ctx.coalitionID, "ATC Approach: Approach cleared. Expect vectors to runway.", 10, false)
end

requestLanding = function()
    local ctx = getPlayerContext(); if not ctx then return end
    local p = players[ctx.unitName]; if not p or not p.airbaseName then return end
    if p.state ~= "approach" then
        trigger.action.outTextForCoalition(ctx.coalitionID, "ATC: Not in approach state.", 10, false); return
    end
    local q = landingQueues[p.airbaseName] or {}
    local pos = 0
    for i, u in ipairs(q) do if u == ctx.unitName then pos = i break end end
    if pos == 1 then
        trigger.action.outTextForCoalition(ctx.coalitionID, "ATC Tower: Cleared to land runway 09.", 10, false)
    else
        trigger.action.outTextForCoalition(ctx.coalitionID, "ATC Tower: Number " .. pos .. " for landing. Maintain pattern.", 10, false)
    end
end

requestTaxiToParking = function()
    local ctx = getPlayerContext(); if not ctx then return end
    local p = players[ctx.unitName]; if not p or not p.airbaseName then return end
    if p.state ~= "landed" then
        trigger.action.outTextForCoalition(ctx.coalitionID, "ATC: Not landed.", 10, false); return
    end
    p.state = "parked"
    trigger.action.outTextForCoalition(ctx.coalitionID, "ATC Ground: Taxi in reverse of original path to parking.", 10, false)
end

requestShutdown = function()
    local ctx = getPlayerContext(); if not ctx then return end
    local p = players[ctx.unitName]; if not p or not p.airbaseName then return end
    if p.state ~= "parked" then
        trigger.action.outTextForCoalition(ctx.coalitionID, "ATC: Not parked.", 10, false); return
    end
    trigger.action.outTextForCoalition(ctx.coalitionID, "ATC Ground: Cleared for shutdown. Good day.", 10, false)
end

---------------------------
-- Events & Timers
---------------------------
onEvent = function(event)
    -- Track unit coalition on any relevant birth (player) and update telemetry at key events.
    if event.id == world.event.S_EVENT_BIRTH then
        local unit = event.initiator
        if unit and unit.isExist and unit:isExist() and unit.getPlayerName and unit:getPlayerName() then
            local name = unit:getName()
            local coa  = unit:getCoalition()
            unitCoalitions[name] = coa
            ensureMenusForCoalition(coa)
            captureTelemetry(unit)
            safeInfo("Player " .. unit:getPlayerName() .. " spawned in " .. name .. " (coalition " .. tostring(coa) .. ")")
        end

    -- Prefer the RUNWAY_TAKEOFF event to mark takeoff completion (per Hoggit)
    elseif event.id == world.event.S_EVENT_RUNWAY_TAKEOFF then
        local unit = event.initiator
        if unit and unit.isExist and unit:isExist() and unit.getPlayerName and unit:getPlayerName() then
            local name = unit:getName()
            captureTelemetry(unit)
            local p = players[name]
            if p and (p.state == "take_off" or p.state == "on_taxi") then
                setAirborne(name)
            end
            safeInfo("Runway takeoff: " .. name .. " from " .. (event.place and event.place:getName() or "unknown"))
        end

    elseif event.id == world.event.S_EVENT_TAKEOFF then
        -- Fallback for airstarts/ship/FARP; we still capture telemetry
        local unit = event.initiator
        if unit and unit.isExist and unit:isExist() and unit.getPlayerName and unit:getPlayerName() then
            captureTelemetry(unit)
            safeInfo("Generic takeoff: " .. unit:getName())
        end

    elseif event.id == world.event.S_EVENT_LAND then
        local unit = event.initiator
        if unit and unit.isExist and unit:isExist() and unit.getPlayerName and unit:getPlayerName() then
            local name = unit:getName()
            captureTelemetry(unit)
            local p = players[name]
            if p and p.state == "approach" and event.place and p.airbaseName and event.place:getName() == p.airbaseName then
                p.state = "landed"
                trigger.action.outTextForCoalition(p.coalitionID, "ATC Tower: Landing noted. Contact ground for taxi.", 10, false)
                local q = landingQueues[p.airbaseName]
                if q then
                    for i, u in ipairs(q) do if u == name then table.remove(q, i) break end end
                    if #q > 0 then
                        local nextUnit = q[1]
                        local nextP = players[nextUnit]
                        if nextP then
                            trigger.action.outTextForCoalition(nextP.coalitionID, "ATC Tower: You are now cleared to land runway 09.", 10, false)
                        end
                    end
                end
            end
            safeInfo("Landing: " .. name .. " at " .. (event.place and event.place:getName() or "unknown"))
        end
    end
end

periodicApproachTick = function()
    local ctx = getPlayerContext()
    if ctx then
        captureTelemetry(ctx.unit)
        local p = players[ctx.unitName]
        if p and p.state == "in_bound" and p.airbaseName then
            local d = getDistanceNM(ctx.unit, getAirbase(p.airbaseName))
            if d <= 10 then
                p.state = "approach"
                trigger.action.outTextForCoalition(p.coalitionID, "ATC: Entering approach phase.", 10, false)
            end
        end
    end
    return timer.getTime() + 30
end

retryAddMenus = function()
    -- Ensure all three coalitions have their menus
    for _, coa in ipairs(getActiveCoalitionIDs()) do
        if not (menuPaths[coa] and menuPaths[coa].root) then
            ensureMenusForCoalition(coa)
        end
    end
    return timer.getTime() + 10
end

---------------------------
-- Init
---------------------------
safeInfo("Script loaded at " .. now())

-- Build menus early for all three coalitions (BLUE/RED/NEUTRAL)
for _, coa in ipairs(getActiveCoalitionIDs()) do
    ensureMenusForCoalition(coa)
end

world.addEventHandler({ onEvent = onEvent })
timer.scheduleFunction(periodicApproachTick, {}, timer.getTime() + 30)
timer.scheduleFunction(retryAddMenus,        {}, timer.getTime() + 5)
