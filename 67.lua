-- BLXCKGOD HUB (Single Unified UI: Grab Farm + Auto ECU Tune + Settings)
local Enabled = true
local Vehicle = "Current"
local DiscordLink = "https://discord.gg/ThdFxkzFN7"

local env = getgenv()
local prior = env.__MahanakhonGrabStandalone
if prior and prior.Destroy then prior:Destroy() end
local prevTune = env.__MahanakhonTuneSolo
if prevTune and prevTune.Destroy then prevTune:Destroy() end
if not Enabled then return "Disabled" end

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Http = game:GetService("HttpService")
local CoreGui = game:GetService("CoreGui")

local player = Players.LocalPlayer
assert(player, "Join game first")

local GameShared = require(RS:WaitForChild("GameShared"))
local JobShared = require(RS:WaitForChild("JobShared"))
local EcuShared = require(RS:WaitForChild("EcuShared"))
local BikeShared = require(RS:WaitForChild("PCX160Shared"))
local Net = require(RS:WaitForChild("NetSeal"))
local Remotes = RS:WaitForChild("GameRemotes")

local Runtime = {
    Alive = true,
    Farm = { Status = "Ready", Enabled = { Grab = false } },
    ShopVehicleFuel = {},
    Connections = {},
    Tune = {
        Enabled = true,
        Busy = false,
        Tests = 0,
        Cancel = false,
        Status = "Waiting for Tune Bay",
        Cache = {}
    }
}
env.__MahanakhonGrabStandalone = Runtime
env.__MahanakhonTuneSolo = Runtime.Tune

function Runtime:SetFarmStage(_, stage) self.Stage = stage end
function Runtime:UpdateFarmSession() end
function Runtime:SendWorkWebhook() end

function Runtime:HoldPrompt(prompt, keepGoing)
    assert(prompt and prompt.Parent and prompt.Enabled, "No prompt")
    local ok, reason = pcall(function()
        prompt:InputHoldBegin()
        local deadline = os.clock() + math.max(.1, prompt.HoldDuration) + .25
        repeat
            assert(self.Alive and (not keepGoing or keepGoing()), "Stopped")
            task.wait(.05)
        until os.clock() >= deadline
    end)
    pcall(function() prompt:InputHoldEnd() end)
    assert(ok, reason)
end

function Runtime:Destroy()
    self.Alive = false
    self.Farm.Enabled.Grab = false
    self.Tune.Cancel = true
    if self.Grab and self.Grab.Shutdown then pcall(self.Grab.Shutdown) end
    for _, connection in ipairs(self.Connections) do
        pcall(function() connection:Disconnect() end)
    end
    pcall(function()
        local targetGui = (gethui and gethui()) or CoreGui
        local oldUi = targetGui:FindFirstChild("BLXCKGOD_HUB_UI")
        if oldUi then oldUi:Destroy() end
    end)
end

local reloadState = getfenv().STATE
if type(reloadState) == "table" then reloadState.cleanup = function() Runtime:Destroy() end end

function Runtime:IsPassengerLeg(state, encoded)
    if state ~= "ToHome" then return false end
    local ok, data = pcall(Http.JSONDecode, Http, encoded or "")
    if not ok or type(data) ~= "table" then return true end
    return data.kind ~= "food" and data.kind ~= "parcel"
end

function Runtime:CanEmptyVehicleTween(model)
    if self:IsPassengerLeg(player:GetAttribute("DeliveryState"), player:GetAttribute("DeliveryJob")) then return false end
    local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
    if not model then return false end
    if model:GetAttribute("HasPassenger") == true then return false end
    for _, part in ipairs(model:GetDescendants()) do
        if (part:IsA("Seat") or part:IsA("VehicleSeat")) and part.Occupant and part.Occupant ~= humanoid then return false end
    end
    return true
end

function Runtime:CanVehicleTween(model)
    local h = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
    return model ~= nil and model.Parent ~= nil and model:GetAttribute("OwnerUserId") == player.UserId
        and h ~= nil and h.Health > 0 and h.SeatPart ~= nil and h.SeatPart:IsDescendantOf(model)
end

function Runtime:PickShopVehicle(list, bikesOnly)
    local spawned = workspace:FindFirstChild("SpawnedVehicles")
    for _, vehicle in ipairs(spawned and spawned:GetChildren() or {}) do
        if vehicle:GetAttribute("OwnerUserId") == player.UserId then
            local id = vehicle:GetAttribute("VehicleId")
            local fuel = tonumber(vehicle:GetAttribute("Fuel"))
            if id and fuel then self.ShopVehicleFuel[id] = fuel end
        end
    end
    local choices, alternatives = {}, {}
    for _, entry in ipairs(list.vehicles or {}) do
        local definition = GameShared.vehicle(entry.id)
        if definition and not entry.locked and (not bikesOnly or definition.category ~= "Car") and (self.ShopVehicleFuel[entry.id] == nil or self.ShopVehicleFuel[entry.id] > 5) then
            table.insert(choices, entry.id)
            if entry.id ~= self.ShopVehicleLast and entry.id ~= list.active then table.insert(alternatives, entry.id) end
        end
    end
    local pool = #alternatives > 0 and alternatives or choices
    assert(#pool > 0, "No fueled vehicle")
    local id = pool[math.random(1, #pool)]
    self.ShopVehicleLast = id
    return id
end

function Runtime:WorkError(message)
    local text = tostring(message or "Failed")
    self.LastTechnicalError = text
    return text
end

-- ==================== GRAB WORKER ====================
local function newGrab(owner, vehicleId, jobId)
    jobId = jobId or "Grab"
    local mode = jobId == "Courier" and "parcel" or jobId == "Delivery" and "food" or "grab"
    local jobLabel = "Grab"
    local Graph = require(RS.RoadGraph)
    local PistonShared = require(RS.PistonShared)
    local GearShared = require(RS.GearShared)
    local PathfindingService = game:GetService("PathfindingService")
    local CareShared = require(RS.CareShared)
    local ShopShared = require(RS.ShopShared)
    local HttpService = Http
    local Config = {
        JobId = jobId, Mode = mode, VehicleId = vehicleId or "Current",
        ObstacleTween = true, TurnTween = true, KeepShopLane = false, DirectMainRoad = true,
        MaxTrips = 0, ComfortDecel = 38, TurnGain = 1, CurveAccel = 32, BrakeZone = 230,
        StopRadius = 22, LaneOffset = 28, TripTimeout = 600, ApproachSpeed = 12, StallTimeout = 180
    }
    local Worker = {
        JobId = jobId, Config = Config, Running = false, Cancelled = false,
        Status = "Ready", Trips = 0, Earned = 0, PeakSpeed = 0, FuelSpent = 0, Recoveries = 0
    }
    local session, riderHum, sessionKind
    local boosted, constraints, excluded = {}, {}, {}
    local originalFilter, inputPatches, motionPatches = nil, {}, {}
    local castParams = RaycastParams.new()
    castParams.FilterType = Enum.RaycastFilterType.Exclude
    castParams.RespectCanCollide = true
    local oldWheelie

    local function flat(v) return Vector3.new(v.X, 0, v.Z) end
    local function cancelled() return Worker.Cancelled or not owner.Alive or not owner.Farm.Enabled.Grab end
    local function status(message)
        Worker.Status = message
        owner.Farm.Status = message
    end
    local function check()
        assert(not cancelled(), "Stopped")
        assert(player.Parent and player.Character, "Character unavailable")
        local watch = Worker.LegWatch
        if watch then
            local ok, fare = pcall(HttpService.JSONDecode, HttpService, player:GetAttribute("DeliveryJob") or "{}")
            if not ok or tostring(fare.acceptedAt) ~= watch.FareId then
                Worker.LegWatch = nil; watch = nil
            end
        end
        if watch and player:GetAttribute("DeliveryState") == watch.State and player:GetAttribute("DeliveryArrived") ~= true
            and (os.clock() - watch.ProgressAt >= Config.StallTimeout
                or Config.RoadWorkArrival and watch.StartedAt and os.clock() - watch.StartedAt >= 300
                    and (Worker.Recoveries or 0) - (watch.StartRecoveries or 0) >= 3) then
            Worker.NeedsReset = true
            error("Route stalled; recovering", 0)
        end
        if session then
            if session.crashed or not session.model.Parent or session.model:GetAttribute("Crashed") == true then
                Worker.NeedsFreshVehicle = true; Worker.NoWalk = true
                Worker.CommandThrottle, Worker.CommandSteer = 0, 0
                error("Vehicle crashed; recovering", 0)
            end
            if session.seat.Occupant ~= riderHum then
                Worker.NoWalk = true
                error("Seat released; remounting", 0)
            end
        end
        return 0
    end

    local lastDeliveryInvoke = -math.huge
    local function invoke(remote, action, ...)
        check()
        if remote == Remotes.Delivery then
            while os.clock() - lastDeliveryInvoke < .8 do check(); task.wait(.05) end
            lastDeliveryInvoke = os.clock()
        end
        return Net.invoke(remote, action, ...)
    end

    local function stopInputs()
        Worker.CommandThrottle, Worker.CommandSteer = 0, 0
        if session and session.seat.Parent then
            session.seat.ThrottleFloat = 0
            session.seat.SteerFloat = 0
        end
    end

    local function brake()
        if not session or not session.seat.Parent then return end
        local deadline = os.clock() + math.abs(session.speed or 0) / Config.ComfortDecel + 4
        while not Worker.ShuttingDown and session.chassis.Parent and session.seat.Occupant == riderHum
            and math.abs(session.speed or 0) > .35 and os.clock() < deadline do
            session.seat.SteerFloat = 0
            session.seat.ThrottleFloat = (session.speed or 0) > 0 and -1 or 1
            Worker.CommandSteer, Worker.CommandThrottle = 0, session.seat.ThrottleFloat
            RunService.Heartbeat:Wait()
        end
        stopInputs()
    end

    local function restore()
        for _, patch in ipairs(motionPatches) do
            if getupvalue(patch.step, patch.index) == patch.replacement then
                setupvalue(patch.step, patch.index, patch.original)
            end
        end
        table.clear(motionPatches)
        for _, patch in ipairs(inputPatches) do
            if getupvalue(patch.step, patch.index) == patch.replacement then
                setupvalue(patch.step, patch.index, patch.original)
            end
        end
        table.clear(inputPatches)
        for _, constraint in ipairs(constraints) do constraint:Destroy() end
        table.clear(constraints)
        table.clear(excluded)
        if session and originalFilter then
            session.params.FilterDescendantsInstances = originalFilter
        end
        originalFilter = nil
        if session and oldWheelie ~= nil then session.wheelieHeld = oldWheelie end
        for vehicle, old in pairs(boosted) do
            if vehicle.Parent and old.turnAssist then
                vehicle:SetAttribute("MaxSteer", old.steer)
            end
        end
        table.clear(boosted)
    end

    function Worker.Stop()
        Worker.Cancelled = true
        if Worker.RoadExitTween then Worker.RoadExitTween:Cancel(); Worker.RoadExitTween = nil end
        if Worker.Enrollment then Worker.Enrollment.Stop() end
        if Worker.VehicleTweenCleanup then Worker.VehicleTweenCleanup() end
        if Worker.RoadFootCleanup then Worker.RoadFootCleanup() end
        if Worker.VehicleTurnCleanup then Worker.VehicleTurnCleanup() end
        stopInputs()
    end

    function Worker.Shutdown() Worker.ShuttingDown = true; Worker.Stop(); restore() end

    local function walk(goal)
        local character = player.Character
        local humanoid = character:FindFirstChildOfClass("Humanoid")
        local root = character:WaitForChild("HumanoidRootPart")
        local path = PathfindingService:CreatePath({ AgentRadius = 2, AgentHeight = 5, AgentCanJump = true, WaypointSpacing = 12 })
        path:ComputeAsync(root.Position, goal)
        assert(path.Status == Enum.PathStatus.Success, "Cannot walk to the road")
        for _, point in ipairs(path:GetWaypoints()) do
            check()
            if point.Action == Enum.PathWaypointAction.Jump then humanoid.Jump = true end
            humanoid:MoveTo(point.Position)
            local deadline = os.clock() + 9
            while (flat(root.Position) - flat(point.Position)).Magnitude > 3.5 do
                check()
                assert(os.clock() < deadline, "Walking route blocked")
                task.wait(.08)
            end
        end
        humanoid:MoveTo(root.Position)
    end

    local function vehicleModel(seat)
        local model = seat and seat:FindFirstAncestorOfClass("Model")
        while model and model.Parent ~= workspace.SpawnedVehicles do
            model = model.Parent and model.Parent:FindFirstAncestorOfClass("Model")
        end
        return model
    end

    local function isCar(vehicle)
        local definition = GameShared.vehicle(vehicle:GetAttribute("VehicleId") or vehicle.Name)
        return definition and definition.category == "Car"
    end

    local function nativeLimits(vehicle)
        local _, _, multiplier = GameShared.upgradeScales(vehicle)
        local tucked = not isCar(vehicle) and vehicle:GetAttribute("Tuck") == true
        local tuckMultiplier = tucked and BikeShared.TUCK_SPEED_BONUS or 1
        local capKmh = math.min(EcuShared.ABS_KMH,
            tucked and EcuShared.TUCK_TOP_KMH or EcuShared.TOP_KMH,
            PistonShared.capKmh(vehicle, tucked) or math.huge)
        local nativeTop = GameShared.driveTop(vehicle, multiplier, tuckMultiplier)
        return math.min(nativeTop, capKmh / EcuShared.KMH_PER_STUD), capKmh
    end

    local function hookInput(driver)
        check()
        for _, value in ipairs(getupvalues(driver.start)) do
            if type(value) == "function" and debug.info(value, "n") == "step" then
                for index, input in ipairs(getupvalues(value)) do
                    if type(input) == "function" and debug.info(input, "n") == "keysToSeat" then
                        for _, patch in ipairs(inputPatches) do if patch.step == value then return end end
                        local replacement = function(state)
                            if state == session then
                                state.seat.ThrottleFloat = Worker.CommandThrottle or 0
                                state.seat.SteerFloat = Worker.CommandSteer or 0
                                if sessionKind == "Bike" then state.wheelieHeld = false end
                            else
                                return input(state)
                            end
                        end
                        table.insert(inputPatches, { step = value, index = index, original = input, replacement = replacement })
                        setupvalue(value, index, replacement)
                        return
                    end
                end
            end
        end
    end

    local function prepareVehicle()
        local humanoid = player.Character:FindFirstChildOfClass("Humanoid")
        local existing = vehicleModel(humanoid.SeatPart)
        if Config.VehicleId == "Current" then
            Config.VehicleId = existing and existing:GetAttribute("OwnerUserId") == player.UserId
                and existing:GetAttribute("VehicleId") or player:GetAttribute("ActiveVehicle") or "PCX160"
        end
        if existing then
            local client = isCar(existing) and player.PlayerScripts.CarClient or player.PlayerScripts.PCX160Client
            local driver = require(client.Driver)
            for _, value in ipairs(getupvalues(driver.start)) do
                if type(value) == "table" and value.model == existing and value.seat == humanoid.SeatPart then
                    session, riderHum = value, humanoid
                    hookInput(driver)
                    brake()
                    session = nil
                    break
                end
            end
        end
        local list
        for _ = 1, 3 do
            list = invoke(Remotes.Garage, "List")
            if type(list) == "table" then break end
            task.wait(.8)
        end
        assert(type(list) == "table", "Garage list unavailable")
        if Config.RandomVehicle and not Config.RandomChosen then
            local fare = player:GetAttribute("DeliveryState")
            if fare == "ToShop" or fare == "ToHome" then
                Config.VehicleId = existing and existing:GetAttribute("VehicleId") or list.active or player:GetAttribute("ActiveVehicle")
                assert(Config.VehicleId, "No vehicle for fare")
            else
                Config.VehicleId = owner:PickShopVehicle(list, Config.WorkVehicle)
            end
            Config.RandomChosen = true
        end
        task.wait(math.max(.8, tonumber(list.cooldown) or 0))
        local available = {}
        local selectedAllowed = false
        for _, entry in ipairs(list.vehicles or {}) do
            local definition = GameShared.vehicle(entry.id)
            available[entry.id] = definition and definition.th or entry.id
            if entry.id == Config.VehicleId then selectedAllowed = true end
        end
        Worker.Vehicles = available
        assert(selectedAllowed, "This vehicle is not available in your Garage: " .. tostring(Config.VehicleId))
        local seatedVehicle = vehicleModel(humanoid.SeatPart)
        if seatedVehicle and (seatedVehicle:GetAttribute("VehicleId") ~= Config.VehicleId
            or seatedVehicle:GetAttribute("OwnerUserId") ~= player.UserId) then
            local fareState = player:GetAttribute("DeliveryState")
            assert(fareState ~= "ToShop" and fareState ~= "ToHome", "Finish the active fare before switching vehicles")
            session = nil
            if isCar(seatedVehicle) then Net.fire(RS.CarRemote, "Exit", seatedVehicle) else Net.fire(RS.PCX160Remote, "Dismount", "Start") end
            local deadline = os.clock() + 6
            while humanoid.SeatPart and os.clock() < deadline do task.wait(.1) end
            assert(not humanoid.SeatPart, "Could not leave the previous vehicle")
            task.wait(1.2)
        end
        if not humanoid.SeatPart then
            status("Remounting")
            local vehicle
            for _, candidate in ipairs(workspace:WaitForChild("SpawnedVehicles"):GetChildren()) do
                if candidate:GetAttribute("OwnerUserId") == player.UserId and candidate:GetAttribute("VehicleId") == Config.VehicleId then vehicle = candidate; break end
            end
            if not vehicle then
                local ok, message
                for _ = 1, 3 do
                    ok, message = invoke(Remotes.Garage, "Spawn", Config.VehicleId)
                    if ok then break end
                    task.wait(1.2)
                end
                assert(ok, tostring(message)); task.wait(.8)
            end
            for _, candidate in ipairs(workspace:WaitForChild("SpawnedVehicles"):GetChildren()) do
                if candidate:GetAttribute("OwnerUserId") == player.UserId and candidate:GetAttribute("VehicleId") == Config.VehicleId then
                    vehicle = candidate; break
                end
            end
            assert(vehicle, "Your vehicle did not spawn")
            if (player.Character.HumanoidRootPart.Position - vehicle:GetPivot().Position).Magnitude > 14 then
                local approach = vehicle:GetPivot():PointToWorldSpace(Vector3.new(-8, 0, 0))
                walk(approach)
            end
            if isCar(vehicle) then Net.fire(RS.CarRemote, "Enter", vehicle, "Driver") else Net.fire(RS.PCX160Remote, "Mount", vehicle, "Drive") end
            local deadline = os.clock() + 5
            while not humanoid.SeatPart and os.clock() < deadline do check(); task.wait(.1) end
        end
        assert(humanoid.SeatPart, "Could not enter the selected vehicle")
        local vehicle = assert(vehicleModel(humanoid.SeatPart), "Vehicle model unavailable")
        sessionKind = isCar(vehicle) and "Car" or "Bike"
        local client = sessionKind == "Car" and player.PlayerScripts.CarClient or player.PlayerScripts.PCX160Client
        local driver = require(client.Driver)
        session = nil
        for _, value in ipairs(getupvalues(driver.start)) do
            if type(value) == "table" and value.model == vehicle and value.chassis then
                session = value; break
            end
        end
        assert(type(session) == "table" and session.chassis, "Driver state unavailable")
        riderHum = humanoid
        hookInput(driver)
        assert(session.seat == humanoid.SeatPart and humanoid.SeatPart:IsA("VehicleSeat"), "Sit in the driver seat")
        if not vehicle:GetAttribute("EngineOn") then
            if sessionKind == "Car" then Net.fire(RS.CarRemote, "Engine", vehicle, true) else Net.fire(RS.PCX160Remote, "Engine", true) end
            task.wait(2.5)
        end
        if sessionKind == "Bike" and vehicle:GetAttribute("StandDown") then
            Net.fire(RS.PCX160Remote, "Stand", false)
            task.wait(.6)
        end
        assert(isnetworkowner(session.chassis), "The client is not controlling the bike")
        originalFilter = table.clone(session.params.FilterDescendantsInstances)
        castParams.FilterDescendantsInstances = { session.model, player.Character, workspace.CurrentCamera }
        oldWheelie = session.wheelieHeld == true
        Worker.Vehicle = session.model
        Worker.NoWalk = false
        boosted[vehicle] = { steer = vehicle:GetAttribute("MaxSteer"), turnAssist = sessionKind == "Car" }
    end

    local function speedLimit()
        local vehicle = session.model
        local nativeTop = nativeLimits(vehicle)
        return nativeTop * .98
    end

    local function routeModel(points)
        local filtered = {}
        for _, point in ipairs(points) do if #filtered == 0 or (point - filtered[#filtered]).Magnitude > .1 then table.insert(filtered, point) end end
        assert(#filtered >= 2, "Route too short")
        local model = { Points = filtered, Arc = { 0 }, Progress = 0, Cursor = 1, TurnIndex = 1, Turns = {} }
        for i = 2, #filtered do model.Arc[i] = model.Arc[i - 1] + (filtered[i] - filtered[i - 1]).Magnitude end
        model.Length = model.Arc[#filtered]
        return model
    end

    local function routePoint(model, arc)
        arc = math.clamp(arc, 0, model.Length)
        local low, high = 1, #model.Points - 1
        while low < high do
            local middle = math.floor((low + high) / 2)
            if model.Arc[middle + 1] < arc then low = middle + 1 else high = middle end
        end
        local a, b = model.Points[low], model.Points[low + 1]
        local span = model.Arc[low + 1] - model.Arc[low]
        return a + (b - a) * (span > .001 and (arc - model.Arc[low]) / span or 0), low
    end

    local function rideSpeedStep(speed, target, acceleration, dt)
        local desired = math.clamp((target - speed) * 8, -(Config.GrabBrakeAccel or 180), Config.GrabAcceleration or 120)
        local change = (Config.GrabJerk or 1000) * dt
        acceleration += math.clamp(desired - acceleration, -change, change)
        local nextSpeed = speed + acceleration * dt
        if (target - speed) * (target - nextSpeed) <= 0 then return target, 0 end
        return math.max(0, nextSpeed), acceleration
    end

    local function brakeDistance(speed, target)
        local velocity = math.max(0, speed); local distance = 0
        local acceleration = math.max(0, Worker.TweenAcceleration or 0)
        for _ = 1, 1000 do
            if velocity <= target + .05 then break end
            local nextSpeed, nextAccel = rideSpeedStep(velocity, target, acceleration, .02)
            distance += (velocity + nextSpeed) * .01; velocity = nextSpeed; acceleration = nextAccel
        end
        return distance * 1.08 + speed * .45 + 8
    end

    function Worker.GrabRoadKind(a, b)
        if not Worker.GrabLaneEdges then
            local roads = require(RS.MapRoads); local edges = {}
            for i = 1, #roads.EDGES, 3 do
                local first, last, kind = roads.EDGES[i], roads.EDGES[i + 1], roads.KINDS[roads.EDGES[i + 2]]
                if kind.gps then
                    table.insert(edges, { A = Vector2.new(roads.NODES[first * 2 - 1], roads.NODES[first * 2]), B = Vector2.new(roads.NODES[last * 2 - 1], roads.NODES[last * 2]), Kind = kind })
                end
            end
            Worker.GrabLaneEdges = edges
        end
        local delta = b - a; if delta.Magnitude < .1 then return nil end
        local midpoint = (a + b) * .5; local best, bestDistance
        for _, edge in ipairs(Worker.GrabLaneEdges) do
            local direction = edge.B - edge.A
            if direction.Magnitude > .1 and math.abs(direction.Unit:Dot(delta.Unit)) > .97 then
                local t = math.clamp((midpoint - edge.A):Dot(direction) / direction:Dot(direction), 0, 1)
                local distance = (midpoint - (edge.A + direction * t)).Magnitude
                if not bestDistance or distance < bestDistance then best, bestDistance = edge.Kind, distance end
            end
        end
        return bestDistance and bestDistance < (best and best.half or 12) + 3 and best or nil
    end

    function Worker.GrabLaneRoute(raw)
        if #raw < 3 then return raw end
        local clean = { raw[1] }
        for i = 2, #raw - 1 do
            if i == 2 or (raw[i] - clean[#clean]).Magnitude > .5 then table.insert(clean, raw[i]) end
        end
        table.insert(clean, raw[#raw])
        if #clean < 3 then return clean end
        local starts, finishes = {}, {}
        for i = 2, #clean - 2 do
            local a, b = clean[i], clean[i + 1]; local delta = b - a
            if delta.Magnitude > .1 then
                local kind = Worker.GrabRoadKind(a, b)
                local half = kind and kind.half or 12
                local offset = kind and kind.id == "main" and 28 or math.clamp(half * .5, 2, 16)
                local left = Vector2.new(delta.Unit.Y, -delta.Unit.X)
                starts[i] = a + left * offset; finishes[i] = b + left * offset
            end
        end
        local points = { clean[1] }
        local function add(point) if (points[#points] - point).Magnitude > .5 then table.insert(points, point) end end
        for i = 2, #clean - 1 do
            local incoming = finishes[i - 1]; local outgoing = starts[i]
            if incoming and outgoing then
                local before = clean[i] - clean[i - 1]; local after = clean[i + 1] - clean[i]
                local cross = before.X * after.Y - before.Y * after.X
                if math.abs(cross) > .01 and before.Unit:Dot(after.Unit) > -.9 then
                    local diff = outgoing - incoming
                    local t = (diff.X * after.Y - diff.Y * after.X) / cross
                    local intersection = incoming + before * t
                    if (intersection - clean[i]).Magnitude < 45 then add(intersection) else add(incoming); add(outgoing) end
                else add((incoming + outgoing) * .5) end
            else add(incoming or outgoing or clean[i]) end
        end
        add(clean[#clean])
        return points
    end

    function Worker.GrabRoutePoints(target)
        local source = session.chassis.Position
        local raw = assert(Graph.route(source, target), "GPS route unavailable")
        return Worker.GrabLaneRoute(raw)
    end

    function Worker.GrabRideHeight()
        if Worker.TweenRideVehicle == session.model and Worker.TweenRideHeight then return Worker.TweenRideHeight end
        local chassis = session.chassis; local height
        for _, ground in pairs({ session.frontGround, session.rearGround }) do
            if ground and ground.Parent then
                local contact = -chassis.CFrame:PointToObjectSpace(ground.WorldPosition).Y
                height = math.max(height or 0, contact)
            end
        end
        if not height then
            height = math.max(tonumber(session.model:GetAttribute("FrontWheelRadius")) or 0, tonumber(session.model:GetAttribute("RearWheelRadius")) or 0, chassis.Size.Y * .5)
        end
        Worker.TweenRideVehicle = session.model
        Worker.TweenRideHeight = math.clamp(height + .1, .5, 6)
        return Worker.TweenRideHeight
    end

    function Worker.GrabFloor(position, previousY)
        local params = RaycastParams.new(); params.FilterType = Enum.RaycastFilterType.Include
        params.FilterDescendantsInstances = { workspace.Map, workspace.Terrain }; params.RespectCanCollide = true
        local hit = workspace:Raycast(Vector3.new(position.X, previousY + 5, position.Z), Vector3.new(0, -18, 0), params)
        if not hit or hit.Normal.Y < .65 or hit.Material == Enum.Material.Water or math.abs(hit.Position.Y - previousY) > 4 then return nil end
        return hit.Position.Y
    end

    function Worker.GrabSweep(from, to)
        local delta = to - from
        if delta.Magnitude < .05 then return true end
        local ignored = { player.Character, workspace.CurrentCamera, session.model }
        local params = RaycastParams.new(); params.FilterType = Enum.RaycastFilterType.Exclude; params.RespectCanCollide = true
        local width = sessionKind == "Car" and 7 or 3.5
        for _ = 1, 48 do
            params.FilterDescendantsInstances = ignored
            local hit = workspace:Blockcast(CFrame.new(from + Vector3.new(0, 2, 0)), Vector3.new(width, 3.5, 4), delta, params)
            if not hit then return true end
            local part = hit.Instance
            if not part:IsA("BasePart") then return hit.Normal.Y > .65 end
            local cf, size = part.CFrame, part.Size
            local height = math.abs(cf.RightVector.Y) * size.X + math.abs(cf.UpVector.Y) * size.Y + math.abs(cf.LookVector.Y) * size.Z
            local building, roadStructure, parent = false, false, part
            while parent and parent ~= workspace do
                if parent.Parent == workspace.Map and (parent.Name == "Road" or parent.Name == "Network" or parent.Name == "Viaduct" or parent.Name == "Expressway" or parent.Name == "MemorialBridge" or parent.Name == "DriveCrossings" or parent.Name == "Sidewalks" or parent.Name == "SignsStops") then roadStructure = true end
                local name = string.lower(parent.Name)
                if name:find("building") or name:find("house") or name:find("apartment") or name:find("townhome") or name:find("wall") then building = true; break end
                parent = parent.Parent
            end
            if hit.Normal.Y < .65 and (building or height > 8 and not roadStructure) then
                Worker.LastBlockedInstance = part; Worker.LastTweenRejected = "Road blocked"; return false
            end
            table.insert(ignored, part)
        end
        return false
    end

    function Worker.GrabTween(points, speed, final, expected)
        check()
        if not owner:CanVehicleTween(session.model) then return false end
        brake(); check()
        local vehicle, character = session.model, player.Character
        local chassis = session.chassis; local start = chassis.CFrame
        local params = RaycastParams.new(); params.FilterType = Enum.RaycastFilterType.Include
        params.FilterDescendantsInstances = { workspace.Map, workspace.Terrain }; params.RespectCanCollide = true
        local floor = workspace:Raycast(start.Position + Vector3.new(0, 2, 0), Vector3.new(0, -15, 0), params)
        if not floor or floor.Normal.Y < .65 then return false end
        local rideHeight = Worker.GrabRideHeight()
        local sampled = { Vector3.new(start.Position.X, floor.Position.Y + rideHeight, start.Position.Z) }; local floorY = floor.Position.Y
        for _, point in ipairs(points) do
            local begin = sampled[#sampled]; local destination = Vector3.new(point.X, begin.Y, point.Y)
            local steps = math.max(1, math.ceil(flat(destination - begin).Magnitude / 5))
            for step = 1, steps do
                local p = begin:Lerp(destination, step / steps)
                local y = Worker.GrabFloor(p, floorY)
                if not y then return false end
                p = Vector3.new(p.X, y + rideHeight, p.Z)
                if not Worker.GrabSweep(sampled[#sampled], p) then return false end
                table.insert(sampled, p); floorY = y
            end
        end
        local offset = start:ToObjectSpace(vehicle:GetPivot()); local rider = start:ToObjectSpace(character:GetPivot())
        local original = {}; local previousBrake = session.braking; local last = start
        local support = Instance.new("Part"); support.Name = "BLXCKGODGrabSupport"; support.Size = Vector3.new(12, .4, 14)
        support.Anchored = true; support.Transparency = 1; support.CanTouch = false; support.CanQuery = false; support.Parent = workspace
        local bounds, size = vehicle:GetBoundingBox(); local bottom = bounds.Position.Y - size.Y / 2 - start.Position.Y
        local cleaned = false
        local function cleanup()
            if cleaned then return end; cleaned = true
            for part, collide in pairs(original) do if part.Parent then part.CanCollide = collide end end
            if support then support:Destroy() end
            session.braking = previousBrake; session.speed = 0
            if chassis.Parent then chassis.AssemblyLinearVelocity = Vector3.zero end
            Worker.NativeTweenKmh = nil
            if Worker.VehicleTweenCleanup == cleanup then Worker.VehicleTweenCleanup = nil end
        end
        local ok = xpcall(function()
            Worker.VehicleTweenCleanup = cleanup
            brake(); check(); stopInputs(); session.braking = true
            local function apply(cf)
                check(); assert(owner:CanVehicleTween(vehicle), "Tween stopped")
                if expected then assert(player:GetAttribute("DeliveryState") == expected, "Fare state changed") end
                for _, container in ipairs({ vehicle, character }) do for _, part in ipairs(container:GetDescendants()) do
                    if part:IsA("BasePart") then
                        if original[part] == nil then original[part] = part.CanCollide end
                        part.CanCollide = false; part.AssemblyLinearVelocity = Vector3.zero; part.AssemblyAngularVelocity = Vector3.zero
                    end
                end end
                session.speed = final and 0 or speed; session.braking = final; session.heading = math.atan2(-cf.LookVector.X, -cf.LookVector.Z); session.travel = session.heading; session.steerIn = 0
                support.CFrame = CFrame.new(cf.Position + Vector3.new(0, bottom - .25, 0))
                vehicle:PivotTo(cf * offset); character:PivotTo(cf * rider)
                chassis.AssemblyLinearVelocity = cf.LookVector * (final and 0 or speed)
                Worker.NativeTweenKmh = (final and 0 or speed) * EcuShared.KMH_PER_STUD; last = cf
            end
            for index = 2, #sampled do
                local from = last; local position = sampled[index]
                local ahead = sampled[math.min(#sampled, index + 1)] - sampled[index - 1]
                local direction = flat(ahead); if direction.Magnitude < .1 then direction = flat(last.LookVector) end
                local target = CFrame.lookAt(position, position + direction.Unit)
                local duration = math.max(.03, (position - from.Position).Magnitude / speed); local began = os.clock()
                repeat
                    local alpha = math.clamp((os.clock() - began) / duration, 0, 1)
                    apply(from:Lerp(target, alpha)); RunService.Heartbeat:Wait()
                until os.clock() - began >= duration
                apply(target)
            end
        end, tostring)
        cleanup()
        if not ok then assert(not cancelled(), "Stopped"); return false end
        task.wait(.15); check()
        return true
    end

    function Worker.GrabOutsidePlan(model, city)
        local points = {}; local finish = model.Progress
        for arc = model.Progress + 5, math.min(model.Length - 105, model.Progress + 220), 5 do
            local a = routePoint(model, math.max(0, arc - 2)); local b = routePoint(model, math.min(model.Length, arc + 2))
            local kind = Worker.GrabRoadKind(a, b)
            local outside = kind and (kind.id == "ring" or kind.id == "bridge" or kind.id == "hill")
            if city then if outside then break end
            elseif not outside then break end
            table.insert(points, (routePoint(model, arc))); finish = arc
        end
        if finish - model.Progress < 10 then return nil end
        return points, finish
    end

    function Worker.GrabOutsideTween(points, expected, top, model, endArc, city)
        top = math.min(top, speedLimit())
        check(); stopInputs()
        assert(owner:CanVehicleTween(session.model), "Not driving")
        local vehicle, character = session.model, player.Character; local chassis = session.chassis
        local start = chassis.CFrame
        local params = RaycastParams.new(); params.FilterType = Enum.RaycastFilterType.Include
        params.FilterDescendantsInstances = { workspace.Map, workspace.Terrain }; params.RespectCanCollide = true
        local floor = workspace:Raycast(start.Position + Vector3.new(0, 2, 0), Vector3.new(0, -18, 0), params)
        if not floor or floor.Normal.Y < .65 then return false end
        local rideHeight = Worker.GrabRideHeight(); local floorY = floor.Position.Y
        local sampled = { Vector3.new(start.Position.X, floor.Position.Y + rideHeight, start.Position.Z) }; local arcs = { 0 }
        for _, point in ipairs(points) do
            local begin = sampled[#sampled]; local goal = Vector3.new(point.X, begin.Y, point.Y)
            local count = math.max(1, math.ceil(flat(goal - begin).Magnitude / 3))
            for i = 1, count do
                local at = begin:Lerp(goal, i / count); local y = Worker.GrabFloor(at, floorY)
                if not y then return false end
                at = Vector3.new(at.X, y + rideHeight, at.Z)
                if not Worker.GrabSweep(sampled[#sampled], at) then return false end
                table.insert(arcs, arcs[#arcs] + (at - sampled[#sampled]).Magnitude); table.insert(sampled, at); floorY = y
            end
        end
        local length = arcs[#arcs]; if length < 1 then return false end
        local vehicleOffset = start:ToObjectSpace(vehicle:GetPivot()); local riderOffset = start:ToObjectSpace(character:GetPivot())
        local original = {}; local previousBrake = session.braking; local last = start; local cursor = 1
        local driveSpeed = math.min(top, math.max(0, Worker.TweenDriveSpeed or session.speed or 0))
        local bounds, size = vehicle:GetBoundingBox(); local bottom = bounds.Position.Y - size.Y / 2 - start.Position.Y
        local support = Instance.new("Part"); support.Name = "BLXCKGODGrabRoadSupport"; support.Anchored = true
        support.Size = Vector3.new(12, .4, 14); support.Transparency = 1; support.CanTouch = false; support.CanQuery = false; support.Parent = workspace
        local cleaned = false
        local function cleanup()
            if cleaned then return end; cleaned = true
            for part, collide in pairs(original) do if part.Parent then part.CanCollide = collide end end
            support:Destroy(); session.braking = previousBrake; session.speed = 0
            if chassis.Parent then chassis.AssemblyLinearVelocity = Vector3.zero end
            Worker.NativeTweenKmh = nil; stopInputs()
            if Worker.VehicleTweenCleanup == cleanup then Worker.VehicleTweenCleanup = nil end
        end
        local function pointAt(arc)
            local index = cursor
            while index < #sampled - 1 and arcs[index + 1] < arc do index += 1 end
            local alpha = math.clamp((arc - arcs[index]) / math.max(.001, arcs[index + 1] - arcs[index]), 0, 1)
            return sampled[index]:Lerp(sampled[index + 1], alpha), index
        end
        Worker.VehicleTweenCleanup = cleanup; stopInputs(); session.braking = true
        local progress = 0; local startArc = model.Progress; local lastTime = os.clock()
        local ok = xpcall(function()
            while progress < length do
                check(); assert(player:GetAttribute("DeliveryState") == expected, "Fare state changed")
                assert(owner:CanVehicleTween(vehicle), "Not driving")
                local now = os.clock(); local dt = math.min(.05, now - lastTime); lastTime = now
                local wanted = top; local routeArc = startArc + (endArc - startArc) * progress / length
                local approachSpeed = expected == "ToHome" and 34 or 38
                local approachDistance = math.max(flat(last.Position - Worker.LegTarget).Magnitude, model.Length - routeArc) - (Config.GrabArrivalRadius or 100)
                local physicalLead = math.max(0, (brakeDistance(driveSpeed, approachSpeed) - driveSpeed * .45 - 8) / 1.08)
                if approachDistance <= physicalLead + math.max(4, driveSpeed * .16) then wanted = math.min(wanted, approachSpeed) end
                driveSpeed, Worker.TweenAcceleration = rideSpeedStep(driveSpeed, wanted, Worker.TweenAcceleration or 0, dt)
                driveSpeed = math.clamp(driveSpeed, 0, top)
                progress = math.min(length, progress + driveSpeed * dt)
                local at, index = pointAt(progress); cursor = index
                local ahead = pointAt(math.min(length, progress + 5)); local behind = pointAt(math.max(0, progress - 2))
                local direction = ahead - behind; if direction.Magnitude < .1 then direction = last.LookVector end
                local desired = CFrame.lookAt(at, at + direction.Unit)
                local angle = math.acos(math.clamp(last.LookVector:Dot(desired.LookVector), -1, 1))
                local rotation = last.Rotation:Lerp(desired.Rotation, math.min(1, dt * 1.2 / math.max(.001, angle)))
                local cf = CFrame.new(at) * rotation
                for _, container in ipairs({ vehicle, character }) do for _, part in ipairs(container:GetDescendants()) do
                    if part:IsA("BasePart") then
                        if original[part] == nil then original[part] = part.CanCollide end
                        part.CanCollide = false; part.AssemblyLinearVelocity = Vector3.zero; part.AssemblyAngularVelocity = Vector3.zero
                    end
                end end
                session.speed = driveSpeed; session.heading = math.atan2(-cf.LookVector.X, -cf.LookVector.Z); session.travel = session.heading; session.steerIn = 0
                support.CFrame = CFrame.new(at + Vector3.new(0, bottom - .25, 0))
                vehicle:PivotTo(cf * vehicleOffset); character:PivotTo(cf * riderOffset)
                chassis.AssemblyLinearVelocity = cf.LookVector * driveSpeed
                Worker.NativeTweenKmh = driveSpeed * EcuShared.KMH_PER_STUD
                last = cf
                Worker.PeakSpeed = math.max(Worker.PeakSpeed, driveSpeed)
                RunService.Heartbeat:Wait()
            end
        end, tostring)
        cleanup(); Worker.TweenDriveSpeed = driveSpeed
        if not ok then assert(not cancelled(), "Stopped"); return false end
        return true
    end

    function Worker.GrabRouteChunk(model, distance)
        local points = {}; local finish = math.min(model.Length, model.Progress + distance)
        for arc = model.Progress + 5, finish, 5 do table.insert(points, (routePoint(model, arc))) end
        if finish - model.Progress > .1 then table.insert(points, (routePoint(model, finish))) end
        return #points > 0 and points or nil, finish
    end

    function Worker.StopTweenMotion()
        stopInputs()
        if not session then return end
        session.speed = 0; session.braking = true
        if session.chassis and session.chassis.Parent then
            session.chassis.AssemblyLinearVelocity = Vector3.zero; session.chassis.AssemblyAngularVelocity = Vector3.zero
        end
    end

    function Worker.DriveGrabRoute(target, _, expected)
        local chassis = session.chassis
        Worker.LegTarget = target
        local model = routeModel(Worker.GrabRoutePoints(target))
        local began = os.clock(); local arrivalTriedAt = 0
        while true do
            check()
            local state = player:GetAttribute("DeliveryState")
            if expected == "ToShop" and state == "ToHome" then Worker.StopTweenMotion(); return end
            assert(state == expected, "Fare state changed")
            if player:GetAttribute("DeliveryArrived") == true then Worker.StopTweenMotion(); return end
            assert(os.clock() - began < Config.TripTimeout, "Trip timed out")
            local remaining = flat(chassis.Position - target).Magnitude
            if remaining <= (Config.GrabArrivalRadius or 100) and os.clock() - arrivalTriedAt > 1.5 then
                arrivalTriedAt = os.clock(); status("Approaching " .. (expected == "ToShop" and "Pickup" or "Dropoff"))
                if Worker.GrabTween({ Vector2.new(target.X, target.Z) }, Config.GrabArrivalSpeed or 32, true, expected) then
                    Worker.StopTweenMotion()
                    local deadline = os.clock() + 4
                    repeat check(); if player:GetAttribute("DeliveryArrived") == true then return end; task.wait(.1) until os.clock() >= deadline
                end
            end
            local top = speedLimit()
            local points, finish = Worker.GrabOutsidePlan(model)
            local city = false
            if not points then points, finish = Worker.GrabOutsidePlan(model, true); city = true end
            if not points then points, finish = Worker.GrabRouteChunk(model, 30); city = true end
            local moved = false
            if points then
                status(city and "City route" or "Road route")
                moved = Worker.GrabOutsideTween(points, expected, top, model, finish, city)
            end
            if moved then
                model.Progress = finish
                Worker.StopTweenMotion()
            else
                Worker.StopTweenMotion()
                task.wait(.2)
            end
        end
    end

    local function waitFor(predicate, seconds, description)
        local deadline = os.clock() + seconds
        repeat
            deadline += check()
            if predicate() then return end
            task.wait(.15)
        until os.clock() > deadline
        error(description)
    end

    local function serviceFuel(force)
        check()
        if not session or not session.model.Parent then return end
        local vehicle = session.model
        if CareShared.fuel(vehicle) > (force and 99 or Config.RefuelBelow or 30) then return end
        brake(); status("Refueling"); stopInputs()
        local before = player:GetAttribute("Cash") or 0
        if ShopShared.count(player, "FuelCan") < 1 then
            local item = assert(ShopShared.item("FuelCan"))
            assert(before >= item.price, "Not enough cash")
            local bought, message = invoke(Remotes.Shop, "Buy", "FuelCan"); assert(bought, tostring(message))
            Worker.FuelSpent += math.max(0, before - (player:GetAttribute("Cash") or before))
            task.wait(.2)
        end
        local character = player.Character; local humanoid = character:FindFirstChildOfClass("Humanoid")
        restore(); session = nil
        if humanoid.SeatPart then
            if isCar(vehicle) then Net.fire(RS.CarRemote, "Exit", vehicle) else Net.fire(RS.PCX160Remote, "Dismount", "Start") end
            local deadline = os.clock() + 8
            repeat check(); task.wait(.1) until not humanoid.SeatPart or os.clock() > deadline
            task.wait(.4)
        end
        local root = character:FindFirstChild("HumanoidRootPart")
        if root and (root.Position - vehicle:GetPivot().Position).Magnitude > 12 then walk(vehicle:GetPivot():PointToWorldSpace(Vector3.new(-5, 0, 0))) end
        local tool
        for _, container in ipairs({ character, player:FindFirstChildOfClass("Backpack") }) do
            if container then for _, item in ipairs(container:GetChildren()) do
                if item:IsA("Tool") and (item:GetAttribute("FuelCan") or item:GetAttribute("ShopItem") == "FuelCan") then tool = item; break end
            end end
        end
        if tool and tool.Parent ~= character then humanoid:EquipTool(tool); task.wait(.15) end
        local used, message = invoke(Remotes.Shop, "Use", "FuelCan", vehicle); assert(used, tostring(message))
        local deadline = os.clock() + 12
        repeat check(); task.wait(.2) until CareShared.fuel(vehicle) >= 95 or os.clock() > deadline
        humanoid:UnequipTools()
        prepareVehicle()
    end
    function Worker.RefuelNow() return serviceFuel(true) end

    local function oneFare()
        Worker.LegWatch = nil
        owner:SetFarmStage(jobId, "Accepting fare")
        serviceFuel(false)
        local count = player:GetAttribute("DeliveryJobs") or 0
        local nextStart, nextAccept = 0, 0
        while true do
            check()
            local state = player:GetAttribute("DeliveryState") or "Off"
            if state == "ToShop" or state == "ToHome" then break end
            local now = os.clock()
            local cooldown = math.max(0, (tonumber(player:GetAttribute("DeliveryCooldownEnd")) or 0) - workspace:GetServerTimeNow())
            if cooldown > 0 then
                status(("Next fare: %ds"):format(math.ceil(cooldown)))
                task.wait(math.min(.25, cooldown))
                continue
            end
            if state == "Off" and now >= nextStart then
                status("Searching: " .. jobLabel)
                invoke(Remotes.Delivery, "Start", mode)
                nextStart = now + 1
            elseif state == "Offer" and now >= nextAccept then
                status("Accepting: " .. jobLabel)
                pcall(invoke, Remotes.Delivery, "Accept", nil)
                nextAccept = os.clock() + .8
            end
            RunService.Heartbeat:Wait()
        end
        waitFor(function() return player:GetAttribute("DeliveryJob") ~= nil end, 5, "Accepted fare data unavailable")
        local data = HttpService:JSONDecode(assert(player:GetAttribute("DeliveryJob"), "No accepted fare"))
        owner:SetFarmStage(jobId, "Working")
        Worker.Fare = data.fee
        if player:GetAttribute("DeliveryState") == "ToShop" then
            if player:GetAttribute("DeliveryArrived") ~= true then
                Worker.DriveGrabRoute(Vector3.new(data.shop.x, data.shop.y, data.shop.z), "Pickup", "ToShop")
            end
            waitFor(function() return player:GetAttribute("DeliveryArrived") == true end, 12, "Pickup arrival not confirmed")
            local ok, message = invoke(Remotes.Delivery, "Confirm", nil)
            assert(ok, tostring(message))
            waitFor(function() return player:GetAttribute("DeliveryState") == "ToHome" end, 15, "Passenger did not board")
        end
        assert(player:GetAttribute("DeliveryState") == "ToHome", "Passenger is not on board")
        Worker.DriveGrabRoute(Vector3.new(data.home.x, data.home.y, data.home.z), "Dropoff", "ToHome")
        waitFor(function() return player:GetAttribute("DeliveryArrived") == true end, 12, "Dropoff arrival not confirmed")
        local ok, message = invoke(Remotes.Delivery, "Confirm", nil)
        assert(ok, tostring(message))
        waitFor(function() return (player:GetAttribute("DeliveryJobs") or 0) > count end, 15, "Payment not confirmed")
        Worker.Trips += 1
        Worker.Earned = math.max(0, (player:GetAttribute("DeliveryEarned") or 0) - (Worker.StartEarned or 0))
        status(("Completed %d fare(s), earned %d"):format(Worker.Trips, Worker.Earned))
        RunService.Heartbeat:Wait()
    end

    function Worker.Run(maxTrips)
        assert(not Worker.Running, "Already running")
        Worker.Running, Worker.Cancelled = true, false
        Worker.StartedAt = os.clock(); Worker.StartEarned = player:GetAttribute("DeliveryEarned") or 0
        local limit = maxTrips == nil and Config.MaxTrips or maxTrips
        while not cancelled() and (limit == 0 or Worker.Trips < limit) do
            local ok, message = xpcall(function()
                waitFor(function() return player:GetAttribute("ProfileReady") and player.Character and player.Character:FindFirstChildOfClass("Humanoid") and player.Character.Humanoid.Health > 0 end, 30, "Waiting for respawn")
                if player:GetAttribute("Job") ~= jobId then
                    local accepted, reason = invoke(Remotes.Job, "Plan", jobId)
                    assert(accepted, tostring(reason))
                end
                if not session or not session.model.Parent or session.seat.Occupant ~= player.Character.Humanoid then
                    restore(); session = nil; prepareVehicle()
                end
                oneFare()
            end, tostring)
            if not ok and not cancelled() then
                Worker.LastRecoveryRaw = tostring(message)
                status("Remounting")
                stopInputs(); restore(); session = nil
                task.wait(2)
            end
        end
        pcall(brake); restore(); Worker.StoppedAt = os.clock()
        Worker.Running = false; status("Stopped")
        return true
    end

    return Worker
end

local function newDriver()
    local worker = newGrab(Runtime, Vehicle == "Random" and "Current" or Vehicle, "Grab")
    worker.Config.RandomVehicle = Vehicle == "Random"
    worker.Config.WorkVehicle = true
    worker.Config.SpawnOnRoad = true
    worker.Config.RoadWorkArrival = true
    worker.Config.FareAlleyRouting = true
    worker.Config.StallTimeout = 120
    worker.Config.GrabRouteV2 = true
    worker.Config.GrabAcceleration = 120
    worker.Config.GrabBrakeAccel = 180
    worker.Config.GrabJerk = 1000
    worker.Config.GrabArrivalSpeed = 50
    worker.Config.GrabArrivalRadius = 70
    return worker
end

-- ==================== AUTO ECU TUNE ENGINE ====================
local Tune = Runtime.Tune
local cachePath = "BLXCKGOD HUB/MAHANAKHON RACING/TuneSolo_" .. player.UserId .. ".json"
pcall(function()
    if isfile and readfile and isfile(cachePath) then
        Tune.Cache = Http:JSONDecode(readfile(cachePath))
    end
end)

local function copyTune(file)
    local out = {}
    for _, def in ipairs(EcuShared.TABLES) do out[def.key] = table.clone(file[def.key]) end
    return out
end

local function decodeHints(value)
    local ok, result = pcall(function() return EcuShared.decode(value) end)
    return ok and result or nil
end

local function validTuneFile(file)
    if type(file) ~= "table" then return false end
    for _, def in ipairs(EcuShared.TABLES) do
        if type(file[def.key]) ~= "table" or #file[def.key] ~= EcuShared.POINTS then return false end
        for _, value in ipairs(file[def.key]) do
            if type(value) ~= "number" or value ~= value or value < def.min - .0001 or value > def.max + .0001 then return false end
        end
    end
    return true
end

local function tuneVehicleId(v) return v:GetAttribute("VehicleId") or v.Name end

local function tuneSignature(v)
    local fields = { tuneVehicleId(v), tostring(player.UserId), tostring(game.PlaceVersion), tostring(v:GetAttribute("EcuRecipeVer") or "current") }
    local attrs = v:GetAttributes(); local keys = {}
    for key in pairs(attrs) do if key == "EngineLevel" or key:find("Piston") or key:find("Bore") then table.insert(keys, key) end end
    table.sort(keys); for _, key in ipairs(keys) do table.insert(fields, key .. "=" .. tostring(attrs[key])) end
    return table.concat(fields, "|")
end

local function findTuneBayVehicle()
    local spawned = workspace:FindFirstChild("SpawnedVehicles")
    if not spawned then return nil end
    local char = player.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if hum and hum.SeatPart then
        local model = hum.SeatPart:FindFirstAncestorOfClass("Model")
        while model and model.Parent ~= spawned do model = model.Parent and model.Parent:FindFirstAncestorOfClass("Model") end
        if model and model:GetAttribute("OwnerUserId") == player.UserId and GameShared.inTuneBay(model) then return model end
    end
    for _, v in ipairs(spawned:GetChildren()) do
        if v:GetAttribute("OwnerUserId") == player.UserId and GameShared.inTuneBay(v) then return v end
    end
    return nil
end

function Tune:Check()
    assert(Runtime.Alive and self.Enabled and not self.Cancel, "Tune cancelled")
    local v = self.Vehicle
    assert(v and v.Parent and v:GetAttribute("OwnerUserId") == player.UserId, "Vehicle missing")
    assert(GameShared.inTuneBay(v), "Left Tune Bay")
end

function Tune:ReadFile(v)
    local file = Net.invoke(Remotes.Ecu, "Get", v)
    if validTuneFile(file) then return copyTune(file), true end
    assert(not v:GetAttribute("EcuBorrowed"), "ECU borrowed")
    return EcuShared.stockFile(), false
end

function Tune:Save(v, file, gain, feedback)
    self.Saved = copyTune(file)
    self.Cache[tuneVehicleId(v)] = { schema = 3, signature = tuneSignature(v), file = copyTune(file), feedback = feedback, gain = gain }
    if writefile then
        pcall(writefile, cachePath, Http:JSONEncode(self.Cache))
    end
end

function Tune:Flash(vehicle, file, allowStopped)
    if not allowStopped then self:Check() end
    assert(validTuneFile(file), "Invalid ECU file")
    local lastMessage
    for _ = 1, 4 do
        local remaining = (self.LastSend or 0) + (EcuShared.SEND_COOLDOWN or 2) + .15 - os.clock()
        while remaining > 0 do
            if not allowStopped then self:Check() end
            task.wait(math.min(.1, remaining))
            remaining = (self.LastSend or 0) + (EcuShared.SEND_COOLDOWN or 2) + .15 - os.clock()
        end
        if not allowStopped then self:Check() end
        self.LastSend = os.clock()
        local ok, message, gain, feedback, hints = Net.invoke(Remotes.Ecu, "Send", vehicle, file, { k = EcuShared.sum(file) })
        if ok then
            assert(type(gain) == "number" and type(feedback) == "table")
            self.Tests = (self.Tests or 0) + 1
            self.Gain = gain
            self.Feedback = table.clone(feedback)
            self.Hints = type(hints) == "table" and hints or decodeHints(vehicle:GetAttribute("EcuHints")) or {}
            return gain, feedback, self.Hints
        end
        lastMessage = tostring(message)
        local text = lastMessage:lower()
        if not (text:find("still writing", 1, true) or text:find("slow down", 1, true) or text:find("cooldown", 1, true)) then
            error(lastMessage, 0)
        end
    end
    error(lastMessage or "Flash failed", 0)
end

function Tune:MapComplete(key, feedback, hints)
    if (feedback[key] or 0) < 1 then return false end
    for _, hint in ipairs(type(hints) == "table" and hints[key] or {}) do
        local value = type(hint) == "number" and hint or type(hint) == "table" and hint.m
        if type(value) == "number" and value < 1 then return false end
    end
    return true
end

function Tune:CompleteAll(feedback, hints)
    for _, def in ipairs(EcuShared.TABLES) do
        if not self:MapComplete(def.key, feedback, hints) then return false end
    end
    return true
end

function Tune:OptimizeCoded(vehicle, best, gain, feedback, hints)
    best = best and copyTune(best) or self:ReadFile(vehicle)
    if not gain then gain, feedback, hints = self:Flash(vehicle, best) end
    self.Best = copyTune(best); self.CodedCertified = {}; self.CodedBlocks = 0
    if self:CompleteAll(feedback, hints) then return best, gain, feedback, hints end

    local residues = { [1] = true, [3] = true, [4] = true, [5] = true, [9] = true }
    local function h(row, col, size)
        if size == 12 then
            if row == 0 or col == 0 then return 1 end
            local x = (row - col) % 11
            return x ~= 0 and residues[x] and 1 or -1
        end
        local x = bit32.band(row, col); local parity = 0
        while x > 0 do parity = bit32.bxor(parity, bit32.band(x, 1)); x = bit32.rshift(x, 1) end
        return parity == 0 and 1 or -1
    end

    local states = {}; local history = { { file = copyTune(best), f = feedback, h = hints } }; local probeCache = {}
    local initialSignature = tuneSignature(vehicle)
    local function same(a, b)
        for _, d in ipairs(EcuShared.TABLES) do for i = 1, EcuShared.POINTS do if math.abs(a[d.key][i] - b[d.key][i]) > 1e-8 then return false end end end
        return true
    end
    local function probe(file)
        assert(tuneSignature(vehicle) == initialSignature)
        local key = tostring(EcuShared.sum(file)); local bucket = probeCache[key]
        for _, cached in ipairs(bucket or {}) do if same(cached.file, file) then return cached.gain, cached.feedback, cached.hints end end
        local g, f, hs = self:Flash(vehicle, file)
        bucket = bucket or {}; probeCache[key] = bucket
        bucket[#bucket + 1] = { file = copyTune(file), gain = g, feedback = f, hints = hs }
        return g, f, hs
    end
    for _, d in ipairs(EcuShared.TABLES) do
        if not self:MapComplete(d.key, feedback, hints) then
            local st = { d = d, observations = {}, candidates = {} }
            for i = 1, EcuShared.POINTS do
                st.observations[i] = {}; local cs = {}
                for tick = math.ceil(d.min / d.step - 1e-6), math.floor(d.max / d.step + 1e-6) do cs[#cs + 1] = tick * d.step end
                st.candidates[i] = cs
            end
            states[d.key] = st
        end
    end
    local function snap(d, x) return math.clamp(math.round(x / d.step) * d.step, d.min, d.max) end
    local function q(d, x, t) local width = d.key == "Afr" and .95 or d.tol * .75; return math.clamp(math.round((1 - math.abs(x - t) / width) * 100) / 100, 0, 1) end
    local function metric(key, index, f, hs)
        for b, r in ipairs(EcuShared.BANDS) do
            if index >= r[1] and index <= r[2] then
                local z = type(hs[key]) == "table" and hs[key][b]
                local m = type(z) == "number" and z or type(z) == "table" and z.m
                if type(m) == "number" then return m, r[2] - r[1] + 1 end
            end
        end
        return f[key] or 0, EcuShared.POINTS
    end

    for block = 1, 4 do
        self.CodedBlocks = block; self.Status = "Tuning block " .. block .. "/4"
        local probes = {}
        for key, st in pairs(states) do
            local d = st.d; probes[key] = {}
            for i = 1, EcuShared.POINTS do
                local l, r
                if block <= 2 then
                    local low, high = d.recipeMin or d.min, d.recipeMax or d.max
                    l = low + (high - low) * ((block - 1) + .5) / 4; r = low + (high - low) * ((block + 1) + .5) / 4
                else
                    local cs = st.candidates[i]; local choices = {}; local totalWeight = 0
                    local function weight(t) return (not d.recipeMin or t >= d.recipeMin - .15 and t <= d.recipeMax + .15) and 1 or .02 end
                    for _, t in ipairs(cs) do totalWeight += weight(t) end
                    for j = 0, math.min(12, #cs - 1) do
                        local threshold = totalWeight * j / math.max(1, math.min(12, #cs - 1)); local accumulated = 0
                        for _, t in ipairs(cs) do accumulated += weight(t); if accumulated >= threshold then if choices[#choices] ~= t then choices[#choices + 1] = t end; break end end
                    end
                    local info
                    for a = 1, #choices do for b = a + 1, #choices do
                        local repeated = false
                        for _, o in ipairs(st.observations[i]) do if math.abs(o.l - choices[a]) < 1e-6 and math.abs(o.r - choices[b]) < 1e-6 then repeated = true; break end end
                        local bins = {}; local total = 0
                        for _, t in ipairs(cs) do
                            local w = (not d.recipeMin or t >= d.recipeMin - .15 and t <= d.recipeMax + .15) and 1 or .02
                            local bin = math.round((q(d, choices[b], t) - q(d, choices[a], t)) / .015)
                            bins[bin] = (bins[bin] or 0) + w; total += w
                        end
                        local sum = 0; for _, n in pairs(bins) do sum += n * n end
                        local score = total > 0 and total - sum / total or 0
                        if not repeated and (not info or score > info) then info = score; l = choices[a]; r = choices[b] end
                    end end
                    if not l then l = cs[1] or best[key][i]; r = l end
                end
                probes[key][i] = { snap(d, l), snap(d, r) }
            end
        end

        local columns = {}; local maxColumn = 0
        for key in pairs(states) do
            columns[key] = {}; local counts = {}
            for i = 1, EcuShared.POINTS do
                local group = 0
                for b, bounds in ipairs(EcuShared.BANDS) do
                    if i >= bounds[1] and i <= bounds[2] then
                        local hint = type(hints[key]) == "table" and hints[key][b]
                        local m = type(hint) == "number" and hint or type(hint) == "table" and hint.m
                        if type(m) == "number" then group = b end
                        break
                    end
                end
                local p = probes[key][i]
                if math.abs(p[1] - p[2]) < 1e-8 then columns[key][i] = 0
                else counts[group] = (counts[group] or 0) + 1; columns[key][i] = counts[group]; maxColumn = math.max(maxColumn, counts[group]) end
            end
        end
        local rowCount = 2
        if maxColumn >= 8 and maxColumn <= 11 then rowCount = 12 else while rowCount <= maxColumn do rowCount *= 2 end end

        local readings = {}
        for row = 0, rowCount - 1 do
            self:Check(); local file = copyTune(best)
            for key in pairs(states) do for i = 1, EcuShared.POINTS do file[key][i] = probes[key][i][columns[key][i] > 0 and h(row, columns[key][i], rowCount) == 1 and 2 or 1] end end
            local g, f, hs = probe(file); readings[row + 1] = { f = f, h = hs, file = file }; history[#history + 1] = readings[row + 1]
        end
        local candidate = copyTune(best); local mismatch = false
        for key, st in pairs(states) do
            local d = st.d
            for i = 1, EcuShared.POINTS do
                local delta = 0; local count
                for row = 0, rowCount - 1 do local m, n = metric(key, i, readings[row + 1].f, readings[row + 1].h); count = n; if columns[key][i] > 0 then delta += h(row, columns[key][i], rowCount) * m end end
                delta *= 2 * count / rowCount
                local p = probes[key][i]; st.observations[i][#st.observations[i] + 1] = { l = p[1], r = p[2], delta = delta, eps = 2 * count * .00101 }
                local cs = {}
                for tick = math.ceil(d.min / d.step - 1e-6), math.floor(d.max / d.step + 1e-6) do
                    local t = tick * d.step; local valid = true
                    for _, o in ipairs(st.observations[i]) do if math.abs(q(d, o.r, t) - q(d, o.l, t) - o.delta) > o.eps + 1e-6 then valid = false; break end end
                    if valid then cs[#cs + 1] = t end
                end
                if #cs == 0 then mismatch = true; cs = st.candidates[i] end
                st.candidates[i] = cs
                local loss, selected
                for _, t in ipairs(cs) do
                    local e = 0; for _, o in ipairs(st.observations[i]) do e += (q(d, o.r, t) - q(d, o.l, t) - o.delta) ^ 2 end
                    if not loss or e < loss then loss = e; selected = t end
                end
                candidate[key][i] = selected or best[key][i]
            end
        end

        local function rounded(sum, n) return math.floor(sum / n * 500 + 1e-7) / 500 end
        for key, st in pairs(states) do
            local d = st.d; local sums, bands = {}, {}
            for j, read in ipairs(history) do
                sums[j] = 0; bands[j] = { 0, 0, 0 }
                for i = 1, EcuShared.POINTS do
                    local value = q(d, read.file[key][i], candidate[key][i]); sums[j] += value
                    for b, bounds in ipairs(EcuShared.BANDS) do if i >= bounds[1] and i <= bounds[2] then bands[j][b] += value; break end end
                end
            end
            for _ = 1, 4 do
                local changed = false
                for i = 1, EcuShared.POINTS do
                    local bandIndex, bandCount
                    for b, bounds in ipairs(EcuShared.BANDS) do if i >= bounds[1] and i <= bounds[2] then bandIndex = b; bandCount = bounds[2] - bounds[1] + 1; break end end
                    local function loss(t)
                        local total = 0
                        for j, read in ipairs(history) do
                            local delta = q(d, read.file[key][i], t) - q(d, read.file[key][i], candidate[key][i])
                            total += (rounded(sums[j] + delta, EcuShared.POINTS) - read.f[key]) ^ 2
                            local hint = type(read.h[key]) == "table" and read.h[key][bandIndex]
                            local m = type(hint) == "number" and hint or type(hint) == "table" and hint.m
                            if type(m) == "number" then total += (rounded(bands[j][bandIndex] + delta, bandCount) - m) ^ 2 end
                        end
                        return total
                    end
                    local chosen = candidate[key][i]; local lowest = loss(chosen)
                    for _, t in ipairs(st.candidates[i]) do local score = loss(t); if score < lowest - 1e-12 then chosen = t; lowest = score end end
                    if chosen ~= candidate[key][i] then
                        for j, read in ipairs(history) do
                            local delta = q(d, read.file[key][i], chosen) - q(d, read.file[key][i], candidate[key][i])
                            sums[j] += delta; bands[j][bandIndex] += delta
                        end
                        candidate[key][i] = chosen; changed = true
                    end
                end
                if not changed then break end
            end
        end

        if mismatch then self.CodedCertified = {}; break end
        local g, f, hs = self:Flash(vehicle, candidate)
        local same = true
        for key in pairs(states) do
            if (f[key] or 0) >= (feedback[key] or 0) then best[key] = table.clone(candidate[key]) else same = false end
        end
        if same then gain, feedback, hints = g, f, hs else gain, feedback, hints = self:Flash(vehicle, best) end
        for key in pairs(states) do
            self.CodedCertified[key] = {}
            for i = 1, EcuShared.POINTS do self.CodedCertified[key][i] = #st.candidates[i] == 1 end
        end
        self.Feedback = feedback; self.Hints = hints; self.Best = copyTune(best); self:Save(vehicle, best, gain, feedback)
        if self:CompleteAll(feedback, hints) then break end
        for key in pairs(states) do if self:MapComplete(key, feedback, hints) then states[key] = nil end end
    end
    return best, gain, feedback, hints
end

function Tune:Optimize(vehicle, onlyKey, phase)
    local best = self:ReadFile(vehicle)
    local gain, feedback, hints = self:Flash(vehicle, best)
    self.Best = copyTune(best); self.Gain = gain; self.Feedback = feedback; self.Hints = hints

    local function metric(def, index, f, h)
        for band, bounds in ipairs(EcuShared.BANDS or {}) do
            if index >= bounds[1] and index <= bounds[2] then
                local hint = type(h) == "table" and type(h[def.key]) == "table" and h[def.key][band]
                local value = type(hint) == "number" and hint or type(hint) == "table" and hint.m
                if type(value) == "number" then return value, bounds[2] - bounds[1] + 1 end
            end
        end
        return f[def.key] or 0, EcuShared.POINTS
    end

    local pass = 0
    while not self:MapComplete(onlyKey, feedback, hints) and pass < 5 do
        self:Check(); pass += 1
        for _, def in ipairs(EcuShared.TABLES) do
            if def.key ~= onlyKey then continue end
            for index = 1, EcuShared.POINTS do
                self:Check()
                if self.CodedCertified and self.CodedCertified[def.key] and self.CodedCertified[def.key][index] then continue end
                if self:MapComplete(def.key, feedback, hints) then break end
                local initialScore = metric(def, index, feedback, hints)
                if initialScore >= 1 then continue end
                self.Status = ("%s %d/%d (%s)"):format(def.label or def.key, index, EcuShared.POINTS, phase or "fine")
                local initial = best[def.key][index]
                local peak = initialScore
                local function snap(v) return math.clamp(math.round(v / def.step) * def.step, def.min, def.max) end
                for stepOffset = -3, 3 do
                    if stepOffset == 0 then continue end
                    local val = snap(initial + stepOffset * def.step)
                    local file = copyTune(best); file[def.key][index] = val
                    local g, f, h = self:Flash(vehicle, file)
                    local sc = metric(def, index, f, h)
                    if sc > peak + .000001 then
                        peak = sc; best = copyTune(file); gain, feedback, hints = g, f, h
                        self.Best = copyTune(best); self:Save(vehicle, best, gain, feedback)
                    end
                end
            end
        end
    end
end

function Tune:RunOnce(vehicle)
    self.Vehicle = vehicle; self.Busy = true; self.Cancel = false
    self.Status = "Tuning ECU..."
    local read, feedback = pcall(Http.JSONDecode, Http, vehicle:GetAttribute("EcuFeedback") or "{}")
    local hintsOk, hints = pcall(Http.JSONDecode, Http, vehicle:GetAttribute("EcuHints") or "{}")
    if read and type(feedback) == "table" and self:CompleteAll(feedback, hintsOk and hints or {}) then
        self.Feedback = feedback; self.Status = "Already tuned (100%)"; self.Busy = false
        return
    end
    local best = self:ReadFile(vehicle)
    self.Best = copyTune(best)
    local ok, err = xpcall(function()
        local g, f, h = self:Flash(vehicle, best)
        best, g, f, h = self:OptimizeCoded(vehicle, best, g, f, h)
        for _, def in ipairs(EcuShared.TABLES) do
            self:Check()
            if not self:MapComplete(def.key, self.Feedback or f, self.Hints or h) then
                self:Optimize(vehicle, def.key, "fine")
            end
        end
    end, tostring)
    pcall(function()
        local g, f, h = self:Flash(vehicle, self.Best, true)
        self.Feedback = f; self.Hints = h; self:Save(vehicle, self.Best, g, f)
    end)
    self.Busy = false
    self.Status = ok and "Tuned! (100%)" or ("Tune error: " .. tostring(err))
end

-- ==================== BLXCKGOD HUB UI ====================
local targetGui = (gethui and gethui()) or CoreGui
local oldUi = targetGui:FindFirstChild("BLXCKGOD_HUB_UI")
if oldUi then oldUi:Destroy() end

local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "BLXCKGOD_HUB_UI"
ScreenGui.ResetOnSpawn = false
ScreenGui.Parent = targetGui

local Colors = {
    BgDark = Color3.fromRGB(16, 20, 18),
    Sidebar = Color3.fromRGB(19, 24, 21),
    Card = Color3.fromRGB(23, 29, 26),
    CardInner = Color3.fromRGB(29, 36, 32),
    Accent = Color3.fromRGB(38, 194, 129),
    AccentDark = Color3.fromRGB(26, 74, 54),
    TextMain = Color3.fromRGB(240, 244, 242),
    TextMuted = Color3.fromRGB(138, 153, 145),
    Border = Color3.fromRGB(36, 46, 41)
}

local function addCorner(obj, radius)
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, radius or 8)
    c.Parent = obj
    return c
end

local function addStroke(obj, color, thickness)
    local s = Instance.new("UIStroke")
    s.Color = color or Colors.Border
    s.Thickness = thickness or 1
    s.Parent = obj
    return s
end

local MainFrame = Instance.new("Frame")
MainFrame.Name = "MainFrame"
MainFrame.Size = UDim2.new(0, 740, 0, 450)
MainFrame.Position = UDim2.new(0.5, -370, 0.5, -225)
MainFrame.BackgroundColor3 = Colors.BgDark
MainFrame.BorderSizePixel = 0
MainFrame.Parent = ScreenGui
addCorner(MainFrame, 12)
addStroke(MainFrame, Colors.Border, 1.5)

local dragging, dragInput, dragStart, startPos
MainFrame.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        dragging = true; dragStart = input.Position; startPos = MainFrame.Position
    end
end)
MainFrame.InputChanged:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
        dragInput = input
    end
end)
UserInputService.InputChanged:Connect(function(input)
    if input == dragInput and dragging then
        local delta = input.Position - dragStart
        MainFrame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
    end
end)
UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        dragging = false
    end
end)

-- Sidebar
local Sidebar = Instance.new("Frame")
Sidebar.Size = UDim2.new(0, 184, 1, 0)
Sidebar.BackgroundColor3 = Colors.Sidebar
Sidebar.BorderSizePixel = 0
Sidebar.Parent = MainFrame
addCorner(Sidebar, 12)

local LogoBox = Instance.new("Frame")
LogoBox.Size = UDim2.new(0, 36, 0, 36)
LogoBox.Position = UDim2.new(0, 14, 0, 16)
LogoBox.BackgroundColor3 = Colors.Accent
LogoBox.Parent = Sidebar
addCorner(LogoBox, 8)

local LogoTxt = Instance.new("TextLabel")
LogoTxt.Size = UDim2.new(1, 0, 1, 0)
LogoTxt.BackgroundTransparency = 1
LogoTxt.Text = "B"
LogoTxt.Font = Enum.Font.GothamBold
LogoTxt.TextSize = 18
LogoTxt.TextColor3 = Colors.BgDark
LogoTxt.Parent = LogoBox

local TitleLbl = Instance.new("TextLabel")
TitleLbl.Size = UDim2.new(0, 120, 0, 18)
TitleLbl.Position = UDim2.new(0, 58, 0, 16)
TitleLbl.BackgroundTransparency = 1
TitleLbl.Text = "BLXCKGOD HUB"
TitleLbl.Font = Enum.Font.GothamBold
TitleLbl.TextSize = 12.5
TitleLbl.TextColor3 = Colors.TextMain
TitleLbl.TextXAlignment = Enum.TextXAlignment.Left
TitleLbl.TextTruncate = Enum.TextTruncate.AtEnd
TitleLbl.Parent = Sidebar

local SubTitleLbl = Instance.new("TextLabel")
SubTitleLbl.Size = UDim2.new(0, 120, 0, 14)
SubTitleLbl.Position = UDim2.new(0, 58, 0, 34)
SubTitleLbl.BackgroundTransparency = 1
SubTitleLbl.Text = "MAHANAKHON · GRAB"
SubTitleLbl.Font = Enum.Font.Gotham
SubTitleLbl.TextSize = 8.5
SubTitleLbl.TextColor3 = Colors.TextMuted
SubTitleLbl.TextXAlignment = Enum.TextXAlignment.Left
SubTitleLbl.Parent = Sidebar

local pages = {}
local tabButtons = {}

local menuItems = {
    { name = "Main", badge = "Grab" },
    { name = "ECU Tune", badge = "Auto" },
    { name = "Settings", badge = "DC" },
}

for i, item in ipairs(menuItems) do
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(1, -24, 0, 34)
    btn.Position = UDim2.new(0, 12, 0, 72 + (i - 1) * 40)
    btn.BackgroundColor3 = i == 1 and Colors.CardInner or Colors.Sidebar
    btn.BackgroundTransparency = i == 1 and 0 or 1
    btn.Text = ""
    btn.Parent = Sidebar
    addCorner(btn, 6)

    local bar = Instance.new("Frame")
    bar.Name = "Bar"
    bar.Size = UDim2.new(0, 3, 0, 18)
    bar.Position = UDim2.new(0, 0, 0.5, -9)
    bar.BackgroundColor3 = Colors.Accent
    bar.BorderSizePixel = 0
    bar.Visible = (i == 1)
    bar.Parent = btn

    local lbl = Instance.new("TextLabel")
    lbl.Name = "Lbl"
    lbl.Size = UDim2.new(0.68, -12, 1, 0)
    lbl.Position = UDim2.new(0, 12, 0, 0)
    lbl.BackgroundTransparency = 1
    lbl.Text = item.name
    lbl.Font = i == 1 and Enum.Font.GothamBold or Enum.Font.Gotham
    lbl.TextSize = 12
    lbl.TextColor3 = i == 1 and Colors.TextMain or Colors.TextMuted
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Parent = btn

    local bLbl = Instance.new("TextLabel")
    bLbl.Size = UDim2.new(0.32, -8, 1, 0)
    bLbl.Position = UDim2.new(0.68, 0, 0, 0)
    bLbl.BackgroundTransparency = 1
    bLbl.Text = item.badge
    bLbl.Font = Enum.Font.GothamBold
    bLbl.TextSize = 10
    bLbl.TextColor3 = Colors.Accent
    bLbl.TextXAlignment = Enum.TextXAlignment.Right
    bLbl.Parent = btn

    tabButtons[item.name] = btn
end

local ProfileCard = Instance.new("Frame")
ProfileCard.Size = UDim2.new(1, -24, 0, 52)
ProfileCard.Position = UDim2.new(0, 12, 1, -64)
ProfileCard.BackgroundColor3 = Colors.Card
ProfileCard.Parent = Sidebar
addCorner(ProfileCard, 8)
addStroke(ProfileCard, Colors.Border, 1)

local PlayerNameLbl = Instance.new("TextLabel")
PlayerNameLbl.Size = UDim2.new(1, -20, 0, 16)
PlayerNameLbl.Position = UDim2.new(0, 10, 0, 9)
PlayerNameLbl.BackgroundTransparency = 1
PlayerNameLbl.Text = player.Name
PlayerNameLbl.Font = Enum.Font.GothamBold
PlayerNameLbl.TextSize = 11
PlayerNameLbl.TextColor3 = Colors.TextMain
PlayerNameLbl.TextXAlignment = Enum.TextXAlignment.Left
PlayerNameLbl.TextTruncate = Enum.TextTruncate.AtEnd
PlayerNameLbl.Parent = ProfileCard

local SideCashLbl = Instance.new("TextLabel")
SideCashLbl.Size = UDim2.new(1, -20, 0, 16)
SideCashLbl.Position = UDim2.new(0, 10, 0, 26)
SideCashLbl.BackgroundTransparency = 1
SideCashLbl.Text = "฿0"
SideCashLbl.Font = Enum.Font.GothamBold
SideCashLbl.TextSize = 11
SideCashLbl.TextColor3 = Colors.Accent
SideCashLbl.TextXAlignment = Enum.TextXAlignment.Left
SideCashLbl.Parent = ProfileCard

-- TopBar
local TopBar = Instance.new("Frame")
TopBar.Size = UDim2.new(1, -184, 0, 60)
TopBar.Position = UDim2.new(0, 184, 0, 0)
TopBar.BackgroundTransparency = 1
TopBar.Parent = MainFrame

local StatusDot = Instance.new("TextLabel")
StatusDot.Size = UDim2.new(0, 260, 0, 24)
StatusDot.Position = UDim2.new(0, 20, 0.5, -12)
StatusDot.BackgroundTransparency = 1
StatusDot.Text = "⚡  • Ready"
StatusDot.Font = Enum.Font.GothamMedium
StatusDot.TextSize = 12
StatusDot.TextColor3 = Colors.TextMuted
StatusDot.TextXAlignment = Enum.TextXAlignment.Left
StatusDot.Parent = TopBar

local FarmBtn = Instance.new("TextButton")
FarmBtn.Size = UDim2.new(0, 130, 0, 34)
FarmBtn.Position = UDim2.new(1, -210, 0.5, -17)
FarmBtn.BackgroundColor3 = Colors.Accent
FarmBtn.Text = "Start farming"
FarmBtn.Font = Enum.Font.GothamBold
FarmBtn.TextSize = 12
FarmBtn.TextColor3 = Colors.BgDark
FarmBtn.Parent = TopBar
addCorner(FarmBtn, 17)

local MinBtn = Instance.new("TextButton")
MinBtn.Size = UDim2.new(0, 28, 0, 28)
MinBtn.Position = UDim2.new(1, -70, 0.5, -14)
MinBtn.BackgroundColor3 = Colors.Card
MinBtn.Text = "—"
MinBtn.Font = Enum.Font.GothamBold
MinBtn.TextSize = 12
MinBtn.TextColor3 = Colors.TextMuted
MinBtn.Parent = TopBar
addCorner(MinBtn, 14)

local CloseBtn = Instance.new("TextButton")
CloseBtn.Size = UDim2.new(0, 28, 0, 28)
CloseBtn.Position = UDim2.new(1, -36, 0.5, -14)
CloseBtn.BackgroundColor3 = Colors.Card
CloseBtn.Text = "✕"
CloseBtn.Font = Enum.Font.GothamBold
CloseBtn.TextSize = 12
CloseBtn.TextColor3 = Colors.TextMuted
CloseBtn.Parent = TopBar
addCorner(CloseBtn, 14)

CloseBtn.MouseButton1Click:Connect(function()
    Runtime:Destroy()
end)

local ContentContainer = Instance.new("Frame")
ContentContainer.Size = UDim2.new(1, -204, 1, -72)
ContentContainer.Position = UDim2.new(0, 194, 0, 62)
ContentContainer.BackgroundTransparency = 1
ContentContainer.Parent = MainFrame

local minimized = false
MinBtn.MouseButton1Click:Connect(function()
    minimized = not minimized
    MainFrame.Size = minimized and UDim2.new(0, 740, 0, 60) or UDim2.new(0, 740, 0, 450)
    Sidebar.Visible = not minimized
    ContentContainer.Visible = not minimized
end)

-- ==================== PAGE 1: MAIN (GRAB FARM) ====================
local MainPage = Instance.new("Frame")
MainPage.Size = UDim2.new(1, 0, 1, 0)
MainPage.BackgroundTransparency = 1
MainPage.Visible = true
MainPage.Parent = ContentContainer
pages["Main"] = MainPage

local VehicleCard = Instance.new("Frame")
VehicleCard.Size = UDim2.new(0.54, -6, 0, 260)
VehicleCard.Position = UDim2.new(0, 0, 0, 0)
VehicleCard.BackgroundColor3 = Colors.Card
VehicleCard.Parent = MainPage
addCorner(VehicleCard, 10)
addStroke(VehicleCard, Colors.Border, 1)

local VehHeader = Instance.new("TextLabel")
VehHeader.Size = UDim2.new(1, -28, 0, 20)
VehHeader.Position = UDim2.new(0, 14, 0, 12)
VehHeader.BackgroundTransparency = 1
VehHeader.Text = "🏍  VEHICLE · BLXCKGOD HUB"
VehHeader.Font = Enum.Font.GothamBold
VehHeader.TextSize = 10
VehHeader.TextColor3 = Colors.TextMuted
VehHeader.TextXAlignment = Enum.TextXAlignment.Left
VehHeader.Parent = VehicleCard

local VehImgBox = Instance.new("Frame")
VehImgBox.Size = UDim2.new(0, 106, 0, 70)
VehImgBox.Position = UDim2.new(0, 14, 0, 38)
VehImgBox.BackgroundColor3 = Colors.CardInner
VehImgBox.Parent = VehicleCard
addCorner(VehImgBox, 8)

local VehIconTxt = Instance.new("TextLabel")
VehIconTxt.Size = UDim2.new(1, 0, 1, 0)
VehIconTxt.BackgroundTransparency = 1
VehIconTxt.Text = "GRAB\nRIDE"
VehIconTxt.Font = Enum.Font.GothamBold
VehIconTxt.TextSize = 11
VehIconTxt.TextColor3 = Colors.Accent
VehIconTxt.Parent = VehImgBox

local VehNameLbl = Instance.new("TextLabel")
VehNameLbl.Size = UDim2.new(1, -138, 0, 22)
VehNameLbl.Position = UDim2.new(0, 130, 0, 38)
VehNameLbl.BackgroundTransparency = 1
VehNameLbl.Text = Vehicle
VehNameLbl.Font = Enum.Font.GothamBold
VehNameLbl.TextSize = 15
VehNameLbl.TextColor3 = Colors.TextMain
VehNameLbl.TextXAlignment = Enum.TextXAlignment.Left
VehNameLbl.TextTruncate = Enum.TextTruncate.AtEnd
VehNameLbl.Parent = VehicleCard

local VehSubLbl = Instance.new("TextLabel")
VehSubLbl.Size = UDim2.new(1, -138, 0, 16)
VehSubLbl.Position = UDim2.new(0, 130, 0, 62)
VehSubLbl.BackgroundTransparency = 1
VehSubLbl.Text = "Ready for Grab job"
VehSubLbl.Font = Enum.Font.Gotham
VehSubLbl.TextSize = 11
VehSubLbl.TextColor3 = Colors.TextMuted
VehSubLbl.TextXAlignment = Enum.TextXAlignment.Left
VehSubLbl.Parent = VehicleCard

local function createStatBar(parent, yPos, labelText)
    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(0, 60, 0, 16)
    lbl.Position = UDim2.new(0, 14, 0, yPos)
    lbl.BackgroundTransparency = 1
    lbl.Text = labelText
    lbl.Font = Enum.Font.Gotham
    lbl.TextSize = 11
    lbl.TextColor3 = Colors.TextMuted
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Parent = parent

    local bg = Instance.new("Frame")
    bg.Size = UDim2.new(1, -165, 0, 6)
    bg.Position = UDim2.new(0, 76, 0, yPos + 5)
    bg.BackgroundColor3 = Colors.CardInner
    bg.Parent = parent
    addCorner(bg, 3)

    local fill = Instance.new("Frame")
    fill.Size = UDim2.new(1, 0, 1, 0)
    fill.BackgroundColor3 = Colors.Accent
    fill.Parent = bg
    addCorner(fill, 3)

    local val = Instance.new("TextLabel")
    val.Size = UDim2.new(0, 75, 0, 16)
    val.Position = UDim2.new(1, -89, 0, yPos)
    val.BackgroundTransparency = 1
    val.Text = "100% · good"
    val.Font = Enum.Font.GothamBold
    val.TextSize = 10
    val.TextColor3 = Colors.TextMain
    val.TextXAlignment = Enum.TextXAlignment.Right
    val.Parent = parent
    return fill, val
end

local FuelFill, FuelVal = createStatBar(VehicleCard, 122, "Fuel")
local EngineFill, EngineVal = createStatBar(VehicleCard, 148, "Engine")

local SpeedLiveLbl = Instance.new("TextLabel")
SpeedLiveLbl.Size = UDim2.new(0, 220, 0, 18)
SpeedLiveLbl.Position = UDim2.new(0, 14, 0, 182)
SpeedLiveLbl.BackgroundTransparency = 1
SpeedLiveLbl.Text = "SPEED: 0 km/h"
SpeedLiveLbl.Font = Enum.Font.GothamBold
SpeedLiveLbl.TextSize = 11
SpeedLiveLbl.TextColor3 = Colors.Accent
SpeedLiveLbl.TextXAlignment = Enum.TextXAlignment.Left
SpeedLiveLbl.Parent = VehicleCard

local ActionBtn = Instance.new("TextButton")
ActionBtn.Size = UDim2.new(1, -28, 0, 34)
ActionBtn.Position = UDim2.new(0, 14, 1, -46)
ActionBtn.BackgroundColor3 = Colors.AccentDark
ActionBtn.Text = "Refuel Now"
ActionBtn.Font = Enum.Font.GothamBold
ActionBtn.TextSize = 12
ActionBtn.TextColor3 = Colors.Accent
ActionBtn.Parent = VehicleCard
addCorner(ActionBtn, 8)

local QuickCard = Instance.new("Frame")
QuickCard.Size = UDim2.new(0.54, -6, 0, 108)
QuickCard.Position = UDim2.new(0, 0, 0, 270)
QuickCard.BackgroundColor3 = Colors.Card
QuickCard.Parent = MainPage
addCorner(QuickCard, 10)
addStroke(QuickCard, Colors.Border, 1)

local RefuelBtn = Instance.new("TextButton")
RefuelBtn.Size = UDim2.new(1, -28, 0, 34)
RefuelBtn.Position = UDim2.new(0, 14, 0, 16)
RefuelBtn.BackgroundColor3 = Colors.CardInner
RefuelBtn.Text = "  Refuel (Buy & Use FuelCan)   >"
RefuelBtn.Font = Enum.Font.GothamMedium
RefuelBtn.TextSize = 11
RefuelBtn.TextColor3 = Colors.TextMain
RefuelBtn.TextXAlignment = Enum.TextXAlignment.Left
RefuelBtn.Parent = QuickCard
addCorner(RefuelBtn, 6)

local TripsInfoBtn = Instance.new("TextLabel")
TripsInfoBtn.Size = UDim2.new(1, -28, 0, 34)
TripsInfoBtn.Position = UDim2.new(0, 14, 0, 58)
TripsInfoBtn.BackgroundColor3 = Colors.CardInner
TripsInfoBtn.Text = "  Grab Trips: 0 · Earned: ฿0"
TripsInfoBtn.Font = Enum.Font.GothamBold
TripsInfoBtn.TextSize = 11
TripsInfoBtn.TextColor3 = Colors.Accent
TripsInfoBtn.TextXAlignment = Enum.TextXAlignment.Left
TripsInfoBtn.Parent = QuickCard
addCorner(TripsInfoBtn, 6)

local StatusCard = Instance.new("Frame")
StatusCard.Size = UDim2.new(0.46, -6, 0, 212)
StatusCard.Position = UDim2.new(0.54, 6, 0, 0)
StatusCard.BackgroundColor3 = Colors.Card
StatusCard.Parent = MainPage
addCorner(StatusCard, 10)
addStroke(StatusCard, Colors.Border, 1)

local MainCashLbl = Instance.new("TextLabel")
MainCashLbl.Size = UDim2.new(1, -28, 0, 32)
MainCashLbl.Position = UDim2.new(0, 14, 0, 24)
MainCashLbl.BackgroundTransparency = 1
MainCashLbl.Text = "฿0"
MainCashLbl.Font = Enum.Font.GothamBold
MainCashLbl.TextSize = 22
MainCashLbl.TextColor3 = Colors.TextMain
MainCashLbl.TextXAlignment = Enum.TextXAlignment.Left
MainCashLbl.Parent = StatusCard

local function createStatusRow(yPos, name)
    local k = Instance.new("TextLabel")
    k.Size = UDim2.new(0.5, 0, 0, 18)
    k.Position = UDim2.new(0, 14, 0, yPos)
    k.BackgroundTransparency = 1
    k.Text = name
    k.Font = Enum.Font.Gotham
    k.TextSize = 11
    k.TextColor3 = Colors.TextMuted
    k.TextXAlignment = Enum.TextXAlignment.Left
    k.Parent = StatusCard

    local v = Instance.new("TextLabel")
    v.Size = UDim2.new(0.5, -28, 0, 18)
    v.Position = UDim2.new(0.5, 14, 0, yPos)
    v.BackgroundTransparency = 1
    v.Text = "-"
    v.Font = Enum.Font.GothamBold
    v.TextSize = 11
    v.TextColor3 = Colors.TextMain
    v.TextXAlignment = Enum.TextXAlignment.Right
    v.Parent = StatusCard
    return v
end

local QuestValLbl = createStatusRow(86, "Delivery state")
local TuneStateLbl = createStatusRow(114, "Auto ECU Tune")
local TopSpeedValLbl = createStatusRow(142, "Top speed")

local LogCard = Instance.new("Frame")
LogCard.Size = UDim2.new(0.46, -6, 0, 156)
LogCard.Position = UDim2.new(0.54, 6, 0, 222)
LogCard.BackgroundColor3 = Colors.Card
LogCard.Parent = MainPage
addCorner(LogCard, 10)
addStroke(LogCard, Colors.Border, 1)

local LogHeader = Instance.new("TextLabel")
LogHeader.Size = UDim2.new(1, -28, 0, 18)
LogHeader.Position = UDim2.new(0, 14, 0, 12)
LogHeader.BackgroundTransparency = 1
LogHeader.Text = "●  LIVE LOG"
LogHeader.Font = Enum.Font.GothamBold
LogHeader.TextSize = 10
LogHeader.TextColor3 = Colors.Accent
LogHeader.TextXAlignment = Enum.TextXAlignment.Left
LogHeader.Parent = LogCard

local LogTitle = Instance.new("TextLabel")
LogTitle.Size = UDim2.new(1, -28, 0, 22)
LogTitle.Position = UDim2.new(0, 14, 0, 38)
LogTitle.BackgroundTransparency = 1
LogTitle.Text = "Ready"
LogTitle.Font = Enum.Font.GothamBold
LogTitle.TextSize = 12
LogTitle.TextColor3 = Colors.TextMain
LogTitle.TextXAlignment = Enum.TextXAlignment.Left
LogTitle.TextWrapped = true
LogTitle.Parent = LogCard

local LogSub = Instance.new("TextLabel")
LogSub.Size = UDim2.new(1, -28, 0, 40)
LogSub.Position = UDim2.new(0, 14, 0, 66)
LogSub.BackgroundTransparency = 1
LogSub.Text = "Drive into Tune Bay with switch ON to auto-tune, or click Start farming."
LogSub.Font = Enum.Font.Gotham
LogSub.TextSize = 10.5
LogSub.TextColor3 = Colors.TextMuted
LogSub.TextXAlignment = Enum.TextXAlignment.Left
LogSub.TextWrapped = true
LogSub.Parent = LogCard

-- ==================== PAGE 2: ECU TUNE ====================
local TunePage = Instance.new("Frame")
TunePage.Size = UDim2.new(1, 0, 1, 0)
TunePage.BackgroundTransparency = 1
TunePage.Visible = false
TunePage.Parent = ContentContainer
pages["ECU Tune"] = TunePage

local TuneCard = Instance.new("Frame")
TuneCard.Size = UDim2.new(1, 0, 1, 0)
TuneCard.BackgroundColor3 = Colors.Card
TuneCard.Parent = TunePage
addCorner(TuneCard, 10)
addStroke(TuneCard, Colors.Border, 1)

local TuneTitleLbl = Instance.new("TextLabel")
TuneTitleLbl.Size = UDim2.new(1, -28, 0, 24)
TuneTitleLbl.Position = UDim2.new(0, 16, 0, 14)
TuneTitleLbl.BackgroundTransparency = 1
TuneTitleLbl.Text = "⚙  AUTO ECU TUNE (IN TUNE BAY)"
TuneTitleLbl.Font = Enum.Font.GothamBold
TuneTitleLbl.TextSize = 12
TuneTitleLbl.TextColor3 = Colors.Accent
TuneTitleLbl.TextXAlignment = Enum.TextXAlignment.Left
TuneTitleLbl.Parent = TuneCard

local TuneSwitchBtn = Instance.new("TextButton")
TuneSwitchBtn.Size = UDim2.new(0, 180, 0, 36)
TuneSwitchBtn.Position = UDim2.new(0, 16, 0, 48)
TuneSwitchBtn.BackgroundColor3 = Colors.Accent
TuneSwitchBtn.Text = "Switch: ON (Auto)"
TuneSwitchBtn.Font = Enum.Font.GothamBold
TuneSwitchBtn.TextSize = 12
TuneSwitchBtn.TextColor3 = Colors.BgDark
TuneSwitchBtn.Parent = TuneCard
addCorner(TuneSwitchBtn, 8)

local TuneStepBox = Instance.new("Frame")
TuneStepBox.Size = UDim2.new(1, -32, 0, 110)
TuneStepBox.Position = UDim2.new(0, 16, 0, 98)
TuneStepBox.BackgroundColor3 = Colors.CardInner
TuneStepBox.Parent = TuneCard
addCorner(TuneStepBox, 8)

local TuneStepTxt = Instance.new("TextLabel")
TuneStepTxt.Size = UDim2.new(1, -24, 1, -16)
TuneStepTxt.Position = UDim2.new(0, 12, 0, 8)
TuneStepTxt.BackgroundTransparency = 1
TuneStepTxt.Text = "วิธีใช้งาน:\n1. เปิดสวิตช์ Auto Tune ทิ้งไว้ (เปิดอยู่แล้ว)\n2. ขี่รถเข้าไปในจุดจูนรถ (Tune Bay)\n3. ระบบจะตรวจจับรถและจูน ECU ให้เองอัตโนมัติจนครบ 100%"
TuneStepTxt.Font = Enum.Font.Gotham
TuneStepTxt.TextSize = 11.5
TuneStepTxt.TextColor3 = Colors.TextMain
TuneStepTxt.TextXAlignment = Enum.TextXAlignment.Left
TuneStepTxt.TextYAlignment = Enum.TextYAlignment.Top
TuneStepTxt.TextWrapped = true
TuneStepTxt.Parent = TuneStepBox

local TuneLiveStatus = Instance.new("TextLabel")
TuneLiveStatus.Size = UDim2.new(1, -32, 0, 32)
TuneLiveStatus.Position = UDim2.new(0, 16, 0, 222)
TuneLiveStatus.BackgroundTransparency = 1
TuneLiveStatus.Text = "Status: Waiting for Tune Bay"
TuneLiveStatus.Font = Enum.Font.GothamBold
TuneLiveStatus.TextSize = 12
TuneLiveStatus.TextColor3 = Colors.Accent
TuneLiveStatus.TextXAlignment = Enum.TextXAlignment.Left
TuneLiveStatus.Parent = TuneCard

-- ==================== PAGE 3: SETTINGS (DISCORD) ====================
local SettingsPage = Instance.new("Frame")
SettingsPage.Size = UDim2.new(1, 0, 1, 0)
SettingsPage.BackgroundTransparency = 1
SettingsPage.Visible = false
SettingsPage.Parent = ContentContainer
pages["Settings"] = SettingsPage

local SettingsCard = Instance.new("Frame")
SettingsCard.Size = UDim2.new(1, 0, 1, 0)
SettingsCard.BackgroundColor3 = Colors.Card
SettingsCard.Parent = SettingsPage
addCorner(SettingsCard, 10)
addStroke(SettingsCard, Colors.Border, 1)

local SettingsHeader = Instance.new("TextLabel")
SettingsHeader.Size = UDim2.new(1, -32, 0, 24)
SettingsHeader.Position = UDim2.new(0, 16, 0, 16)
SettingsHeader.BackgroundTransparency = 1
SettingsHeader.Text = "⚙  SETTINGS · BLXCKGOD HUB"
SettingsHeader.Font = Enum.Font.GothamBold
SettingsHeader.TextSize = 13
SettingsHeader.TextColor3 = Colors.Accent
SettingsHeader.TextXAlignment = Enum.TextXAlignment.Left
SettingsHeader.Parent = SettingsCard

local DiscordBox = Instance.new("Frame")
DiscordBox.Size = UDim2.new(1, -32, 0, 118)
DiscordBox.Position = UDim2.new(0, 16, 0, 52)
DiscordBox.BackgroundColor3 = Colors.CardInner
DiscordBox.Parent = SettingsCard
addCorner(DiscordBox, 8)
addStroke(DiscordBox, Colors.Border, 1)

local DiscordLabel = Instance.new("TextLabel")
DiscordLabel.Size = UDim2.new(1, -24, 0, 20)
DiscordLabel.Position = UDim2.new(0, 12, 0, 10)
DiscordLabel.BackgroundTransparency = 1
DiscordLabel.Text = "DISCORD COMMUNITY LINK"
DiscordLabel.Font = Enum.Font.GothamBold
DiscordLabel.TextSize = 10
DiscordLabel.TextColor3 = Colors.TextMuted
DiscordLabel.TextXAlignment = Enum.TextXAlignment.Left
DiscordLabel.Parent = DiscordBox

local DiscordInput = Instance.new("TextBox")
DiscordInput.Size = UDim2.new(1, -136, 0, 34)
DiscordInput.Position = UDim2.new(0, 12, 0, 36)
DiscordInput.BackgroundColor3 = Colors.BgDark
DiscordInput.Text = DiscordLink
DiscordInput.TextEditable = false
DiscordInput.ClearTextOnFocus = false
DiscordInput.Font = Enum.Font.GothamMedium
DiscordInput.TextSize = 11.5
DiscordInput.TextColor3 = Colors.TextMain
DiscordInput.TextXAlignment = Enum.TextXAlignment.Left
DiscordInput.Parent = DiscordBox
addCorner(DiscordInput, 6)
addStroke(DiscordInput, Colors.Border, 1)

local CopyDcBtn = Instance.new("TextButton")
CopyDcBtn.Size = UDim2.new(0, 104, 0, 34)
CopyDcBtn.Position = UDim2.new(1, -116, 0, 36)
CopyDcBtn.BackgroundColor3 = Colors.Accent
CopyDcBtn.Text = "Copy Link"
CopyDcBtn.Font = Enum.Font.GothamBold
CopyDcBtn.TextSize = 11.5
CopyDcBtn.TextColor3 = Colors.BgDark
CopyDcBtn.Parent = DiscordBox
addCorner(CopyDcBtn, 6)

local DiscordHint = Instance.new("TextLabel")
DiscordHint.Size = UDim2.new(1, -24, 0, 22)
DiscordHint.Position = UDim2.new(0, 12, 0, 80)
DiscordHint.BackgroundTransparency = 1
DiscordHint.Text = "กด Copy Link เพื่อคัดลอกลิงก์ดิสคอร์ดของ BLXCKGOD HUB"
DiscordHint.Font = Enum.Font.Gotham
DiscordHint.TextSize = 10.5
DiscordHint.TextColor3 = Colors.TextMuted
DiscordHint.TextXAlignment = Enum.TextXAlignment.Left
DiscordHint.Parent = DiscordBox

CopyDcBtn.MouseButton1Click:Connect(function()
    if setclipboard then
        pcall(setclipboard, DiscordLink)
    end
    CopyDcBtn.Text = "Copied!"
    task.wait(1.5)
    CopyDcBtn.Text = "Copy Link"
end)

local function setPage(name)
    for pName, frame in pairs(pages) do
        frame.Visible = (pName == name)
    end
    for tName, btn in pairs(tabButtons) do
        local active = (tName == name)
        btn.BackgroundTransparency = active and 0 or 1
        btn.BackgroundColor3 = active and Colors.CardInner or Colors.Sidebar
        local bar = btn:FindFirstChild("Bar")
        if bar then bar.Visible = active end
        local lbl = btn:FindFirstChild("Lbl")
        if lbl then
            lbl.Font = active and Enum.Font.GothamBold or Enum.Font.Gotham
            lbl.TextColor3 = active and Colors.TextMain or Colors.TextMuted
        end
    end
end

for tName, btn in pairs(tabButtons) do
    btn.MouseButton1Click:Connect(function() setPage(tName) end)
end

TuneSwitchBtn.MouseButton1Click:Connect(function()
    Tune.Enabled = not Tune.Enabled
    Tune.Cancel = not Tune.Enabled
    if Tune.Enabled then
        TuneSwitchBtn.Text = "Switch: ON (Auto)"
        TuneSwitchBtn.BackgroundColor3 = Colors.Accent
        TuneSwitchBtn.TextColor3 = Colors.BgDark
    else
        TuneSwitchBtn.Text = "Switch: OFF"
        TuneSwitchBtn.BackgroundColor3 = Colors.CardInner
        TuneSwitchBtn.TextColor3 = Colors.TextMuted
        Tune.Status = "Switch OFF"
    end
end)

-- ==================== LOGIC & LOOPS ====================
local function formatNumber(n)
    local formatted = tostring(math.floor(tonumber(n) or 0))
    while true do
        local k
        formatted, k = string.gsub(formatted, "^(-?%d+)(%d%d%d)", "%1,%2")
        if k == 0 then break end
    end
    return formatted
end

local function triggerRefuel()
    task.spawn(function()
        if Runtime.Grab and Runtime.Grab.RefuelNow then
            LogTitle.Text = "Refueling vehicle..."
            local ok, err = pcall(Runtime.Grab.RefuelNow)
            LogTitle.Text = ok and "Refuel complete!" or "Refuel failed"
            LogSub.Text = ok and "Fuel restored" or tostring(err)
        else
            LogTitle.Text = "Start farming first"
            LogSub.Text = "Worker not initialized yet"
        end
    end)
end

ActionBtn.MouseButton1Click:Connect(triggerRefuel)
RefuelBtn.MouseButton1Click:Connect(triggerRefuel)

FarmBtn.MouseButton1Click:Connect(function()
    local nextState = not Runtime.Farm.Enabled.Grab
    Runtime.Farm.Enabled.Grab = nextState
    if nextState then
        FarmBtn.Text = "Stop farming"
        FarmBtn.BackgroundColor3 = Color3.fromRGB(220, 75, 75)
        FarmBtn.TextColor3 = Colors.TextMain
    else
        FarmBtn.Text = "Start farming"
        FarmBtn.BackgroundColor3 = Colors.Accent
        FarmBtn.TextColor3 = Colors.BgDark
        if Runtime.Grab and Runtime.Grab.Stop then pcall(Runtime.Grab.Stop) end
    end
end)

-- ลูป Grab Farm
task.spawn(function()
    while Runtime.Alive do
        if Runtime.Farm.Enabled.Grab then
            local worker = newDriver()
            Runtime.Grab = worker
            local ok, reason = pcall(worker.Run)
            if not Runtime.Alive then break end
            if Runtime.Farm.Enabled.Grab then
                LogTitle.Text = "Recovering worker..."
                LogSub.Text = ok and tostring(worker.LastRecoveryRaw or "Restarting") or tostring(reason)
            end
            worker.Shutdown()
            task.wait(2)
        else
            task.wait(.25)
        end
    end
end)

-- ลูป Auto ECU Tune (เมื่อเปิดสวิตช์และอยู่ในจุดจูนรถจะจูนให้เองทันที)
task.spawn(function()
    local lastTunedVehicle
    while Runtime.Alive do
        if Tune.Enabled and not Tune.Busy then
            local v = findTuneBayVehicle()
            if v then
                if v ~= lastTunedVehicle then
                    lastTunedVehicle = v
                    Tune:RunOnce(v)
                else
                    Tune.Status = "Tuned on this vehicle"
                end
            else
                lastTunedVehicle = nil
                Tune.Status = "Waiting for Tune Bay"
            end
        elseif not Tune.Enabled then
            lastTunedVehicle = nil
            Tune.Status = "Switch OFF"
        end
        task.wait(0.5)
    end
end)

RunService.Heartbeat:Connect(function()
    if not Runtime.Alive then return end

    local cash = tonumber(player:GetAttribute("Cash")) or 0
    local formattedCash = "฿" .. formatNumber(cash)
    MainCashLbl.Text = formattedCash
    SideCashLbl.Text = formattedCash

    local delivState = tostring(player:GetAttribute("DeliveryState") or "Off")
    QuestValLbl.Text = delivState
    TuneStateLbl.Text = Tune.Busy and (Tune.Status or "Tuning") or tostring(Tune.Status or "Idle")
    TuneLiveStatus.Text = "Status: " .. tostring(Tune.Status or "Ready")

    if Runtime.Farm.Enabled.Grab then
        StatusDot.Text = "⚡  • Grab Farming"
        StatusDot.TextColor3 = Colors.Accent
    elseif Tune.Busy then
        StatusDot.Text = "⚙  • Auto Tuning"
        StatusDot.TextColor3 = Colors.Accent
    else
        StatusDot.Text = "⚡  • " .. tostring(Tune.Status or "Ready")
        StatusDot.TextColor3 = Colors.TextMuted
    end

    local w = Runtime.Grab
    if w then
        LogTitle.Text = tostring(Runtime.Farm.Status or w.Status or "Ready")
        LogSub.Text = ("Trips: %d · Earned: ฿%s"):format(w.Trips or 0, formatNumber(w.Earned or 0))
        TripsInfoBtn.Text = ("  Grab Trips: %d · Earned: ฿%s"):format(w.Trips or 0, formatNumber(w.Earned or 0))
        if w.PeakSpeed and w.PeakSpeed > 0 then
            TopSpeedValLbl.Text = math.floor(w.PeakSpeed * EcuShared.KMH_PER_STUD) .. " km/h"
        end
        if w.Vehicle and w.Vehicle.Parent then
            local vId = tostring(w.Vehicle:GetAttribute("VehicleId") or w.Vehicle.Name)
            local def = GameShared.vehicle(vId)
            VehNameLbl.Text = (def and def.th) or vId
            VehSubLbl.Text = "Grab · " .. delivState
            local fuel = math.clamp(math.floor(tonumber(w.Vehicle:GetAttribute("Fuel")) or 100), 0, 100)
            FuelFill.Size = UDim2.new(fuel / 100, 0, 1, 0)
            FuelVal.Text = fuel .. "% · " .. (fuel > 30 and "good" or "low")
            local spd = math.floor((w.NativeTweenKmh or (w.Vehicle.PrimaryPart and w.Vehicle.PrimaryPart.AssemblyLinearVelocity.Magnitude * EcuShared.KMH_PER_STUD) or 0))
            SpeedLiveLbl.Text = "SPEED: " .. spd .. " km/h"
        end
    end
end)

return Runtime
