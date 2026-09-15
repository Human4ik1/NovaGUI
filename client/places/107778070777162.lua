--[[
  HumaHub place module — Steal An Egg (PlaceId 107778070777162).
  Adapted from the supplied VALT :: Pet Spawner script.

  Functions:
    - index the game's ReplicatedStorage.Data.Assets pet catalogue;
    - search and filter pets by rarity;
    - spawn a local pet model in front of you or on your own plot;
    - optionally create a local backpack Tool that places a pet on click;
    - scale, anchor, rotate, float and animate local pet models;
    - local name tags and decorative payout popups;
    - local-only cash counter visual (never sends money to the server);
    - bulk spawn, clear spawns, clear tools and unload cleanup.

  This module does not call game remotes or grant server-side pets/currency.
  All models, tools, labels and payout values are client-side visual objects.
]]
return function(api)
local Nova, Tab, Notify = api.Nova, api.Tab, api.Notify
local Navigation = api.Navigation
if not Navigation and Tab and type(Tab.Navigation) == "function" then
    Navigation = Tab:Navigation()
end
local G = (getgenv and getgenv()) or _G
local pageItems = {}
-- Services
--=====================================================================
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local UserInputService  = game:GetService("UserInputService")
local TweenService      = game:GetService("TweenService")
local Workspace         = game:GetService("Workspace")
local Debris            = game:GetService("Debris")

local LocalPlayer = Players.LocalPlayer
local Camera      = Workspace.CurrentCamera

--=====================================================================
-- Kill previous instance
--=====================================================================
if G.__VALT_SPAWNER then
    pcall(G.__VALT_SPAWNER.unload)
end

--=====================================================================
-- Config
--=====================================================================
local CONFIG = {
    MAX_SPAWNS     = 40,
    SPAWN_DISTANCE = 12,
    SCALE_MULT     = 1,

    SPIN           = true,
    FLOAT          = false,
    OWN_PLOT_ONLY  = true,
    GROUND         = true,
    ANIMATE        = true,
    NAMETAG        = true,
    ANCHORED       = true,

    GRID_COLUMNS   = (UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled) and 2 or 3,

    GIVE_TOOL      = true,
    HAND_MAX_STUDS = 4,

    MONEY_POPUP    = true,
    PAY_INTERVAL   = 1,
    CASH_VISUAL    = true,
}

--=====================================================================
-- State
--=====================================================================
local running      = true
local connections  = {}
local activeSpawns = {}
local activeTools  = {}
local pets         = {}
local rarityList   = { "All" }
local rarityRank   = {}
local selectedPet  = nil
local filter       = { text = "", rarity = "All" }

local UI = {
    window      = nil,
    gridTab     = nil,
    rows        = {},
    viewport    = nil,
    counter     = nil,
    previewInfo = nil,
}

--=====================================================================
-- Utility
--=====================================================================
local function track(conn)
    connections[#connections + 1] = conn
    return conn
end

local function abbreviateNumber(n)
    n = tonumber(n) or 0
    local units = {
        { 1e12, "T" },
        { 1e9,  "B" },
        { 1e6,  "M" },
        { 1e3,  "K" },
    }
    for _, unit in ipairs(units) do
        if n >= unit[1] then
            return string.format("%.2f", n / unit[1]):gsub("%.?0+$", "") .. unit[2]
        end
    end
    return tostring(math.floor(n))
end

local function getCharacterRoot()
    local char = LocalPlayer.Character
    if not char then return nil end
    return char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart
end

--=====================================================================
-- Parse assets
--=====================================================================
local Directory = {}
do
    local ok, data = pcall(function()
        local assets = require(ReplicatedStorage.Data.Assets)
        return assets and assets.Directory
    end)
    if ok and type(data) == "table" then
        Directory = data
    else
        Notify("Steal An Egg", "ReplicatedStorage.Data.Assets is unavailable", "error")
    end
end

for key, entry in pairs(Directory) do
    local rarityInfo  = entry.Rarity or {}
    local rarityName  = tostring(rarityInfo._id or rarityInfo.DisplayName or "Unknown")

    local pet = {
        id       = key,
        name     = tostring(entry.DisplayName or key),
        icon     = tostring(entry.Icon or ""),
        eggIcon  = entry.Egg and tostring(entry.Egg.Icon or "") or "",
        rarity   = rarityName,
        rank     = tonumber(rarityInfo.RarityNumber) or 0,
        color    = typeof(rarityInfo.Color) == "Color3" and rarityInfo.Color or Color3.fromRGB(200, 200, 200),
        rate     = tonumber(entry.EarningRate) or 0,
        scale    = tonumber(entry.BaseModelScale) or 1,
        idle     = entry.Animations and entry.Animations.Idle or nil,
    }

    pets[#pets + 1] = pet

    if rarityRank[rarityName] == nil then
        rarityRank[rarityName] = pet.rank
        rarityList[#rarityList + 1] = rarityName
    end
end

table.sort(pets, function(a, b)
    if a.rank ~= b.rank then return a.rank > b.rank end
    return a.name < b.name
end)

table.sort(rarityList, function(a, b)
    if a == "All" then return true end
    if b == "All" then return false end
    return (rarityRank[a] or 0) > (rarityRank[b] or 0)
end)

--=====================================================================
-- World helpers
--=====================================================================
local function getSpawnFolder()
    local folder = Workspace:FindFirstChild("__ValtSpawns")
    if not folder then
        folder = Instance.new("Folder")
        folder.Name = "__ValtSpawns"
        folder.Parent = Workspace
    end
    return folder
end

local function getOwnPlot()
    local plots = Workspace:FindFirstChild("Plots")
    if not plots then return nil end

    local myName = LocalPlayer.Name
    for _, plot in ipairs(plots:GetChildren()) do
        local sign = plot:FindFirstChild("PlotSign")
        if sign then
            for _, d in ipairs(sign:GetDescendants()) do
                if d:IsA("TextLabel") and d.Text == myName then
                    return plot
                end
            end
        end
    end
    return nil
end

local function getPlotSpawnPosition(index)
    local plot = getOwnPlot()
    if not plot then return nil end

    local center = plot:FindFirstChild("CenterPoint") or plot:FindFirstChild("SpawnPoint")
    if not center then return nil end

    local i      = index or 0
    local angle  = (i % 10) * (math.pi * 0.2)
    local radius = math.floor(i / 10) * 3.5 + 5

    return center.Position + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
end

local function resolveGroundPosition(pos, model)
    if not CONFIG.GROUND then
        return pos + Vector3.new(0, model:GetExtentsSize().Y * 0.5, 0)
    end

    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = { model, LocalPlayer.Character, getSpawnFolder() }
    params.IgnoreWater = true

    local result = Workspace:Raycast(pos + Vector3.new(0, 40, 0), Vector3.new(0, -300, 0), params)
    local y = result and result.Position.Y or pos.Y

    return Vector3.new(pos.X, y + model:GetExtentsSize().Y * 0.5, pos.Z)
end

--=====================================================================
-- Visual setup
--=====================================================================
local function attachNametag(model, pet)
    local primary = model.PrimaryPart
    if not primary then return end

    local billboard = Instance.new("BillboardGui")
    billboard.Name = "ValtTag"
    billboard.Size = UDim2.fromOffset(220, 72)
    billboard.StudsOffsetWorldSpace = Vector3.new(0, model:GetExtentsSize().Y * 0.65 + 2, 0)
    billboard.AlwaysOnTop = true
    billboard.MaxDistance = 400
    billboard.Parent = primary

    if pet.icon ~= "" then
        local img = Instance.new("ImageLabel")
        img.BackgroundTransparency = 1
        img.AnchorPoint = Vector2.new(0.5, 0)
        img.Position = UDim2.new(0.5, 0, 0, 0)
        img.Size = UDim2.fromOffset(34, 34)
        img.Image = pet.icon
        img.ScaleType = Enum.ScaleType.Fit
        img.Parent = billboard
    end

    local title = Instance.new("TextLabel")
    title.BackgroundTransparency = 1
    title.Position = UDim2.new(0, 0, 0, 34)
    title.Size = UDim2.new(1, 0, 0, 22)
    title.Font = Enum.Font.GothamBold
    title.TextScaled = true
    title.TextColor3 = Color3.new(1, 1, 1)
    title.TextStrokeTransparency = 0.4
    title.Text = pet.name
    title.Parent = billboard

    local sub = Instance.new("TextLabel")
    sub.BackgroundTransparency = 1
    sub.Position = UDim2.new(0, 0, 0, 56)
    sub.Size = UDim2.new(1, 0, 0, 16)
    sub.Font = Enum.Font.GothamMedium
    sub.TextScaled = true
    sub.TextColor3 = pet.color
    sub.TextStrokeTransparency = 0.5
    sub.Text = string.format("%s | $%s/s", pet.rarity, abbreviateNumber(pet.rate))
    sub.Parent = billboard
end

local function setupModel(model, pet)
    local scale = CONFIG.SCALE_MULT * (pet.scale or 1)
    if math.abs(scale - 1) > 0.001 then
        pcall(function() model:ScaleTo(scale) end)
    end

    local hasJoints = false
    for _, d in ipairs(model:GetDescendants()) do
        if d:IsA("Motor6D") or d:IsA("Weld") or d:IsA("WeldConstraint") then
            hasJoints = true
            break
        end
    end

    local primary = model.PrimaryPart

    for _, part in ipairs(model:GetDescendants()) do
        if part:IsA("BasePart") then
            part.CanCollide = false
            part.CanQuery  = false
            part.CanTouch  = false
            part.Massless  = true

            local anchored = CONFIG.ANCHORED
            if anchored then
                anchored = (not hasJoints) or part == primary
            end
            part.Anchored = anchored
        end
    end

    if primary then
        primary.Anchored = CONFIG.ANCHORED
    end

    return hasJoints
end

local function playIdle(model, pet)
    if not (CONFIG.ANIMATE and pet.idle) then return end

    local ok, err = pcall(function()
        local host = model:FindFirstChildOfClass("Model") or model
        local controller = host:FindFirstChildOfClass("AnimationController")
            or host:FindFirstChildOfClass("Humanoid")

        if not controller then
            controller = Instance.new("AnimationController")
            controller.Parent = host
        end

        local animator = controller:FindFirstChildOfClass("Animator")
        if not animator then
            animator = Instance.new("Animator")
            animator.Parent = controller
        end

        local anim
        if typeof(pet.idle) == "Instance" and pet.idle:IsA("Animation") then
            anim = pet.idle:Clone()
        else
            anim = Instance.new("Animation")
            anim.AnimationId = tostring(pet.idle)
        end

        local trackAnim = animator:LoadAnimation(anim)
        trackAnim.Looped = true
        trackAnim:Play()
    end)

    if not ok then
        warn("[VALT SPAWNER] idle animation failed for " .. pet.name .. ": " .. tostring(err))
    end
end

--=====================================================================
-- Spawn limit
--=====================================================================
local function enforceSpawnLimit()
    while #activeSpawns > CONFIG.MAX_SPAWNS do
        local record = table.remove(activeSpawns, 1)
        if record and record.model then
            pcall(function() record.model:Destroy() end)
        end
    end
end

--=====================================================================
-- Input tracking for tool placement
--=====================================================================
local lastTouchPos = nil

track(UserInputService.TouchTap:Connect(function(pos)
    if pos and pos[1] then lastTouchPos = pos[1] end
end))

track(UserInputService.TouchEnded:Connect(function(part)
    lastTouchPos = part.Position
end))

local function getSpawnPosition()
    local isMobile = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

    if isMobile and lastTouchPos and Camera then
        local ray = Camera:ViewportPointToRay(lastTouchPos.X, lastTouchPos.Y)
        local params = RaycastParams.new()
        params.FilterType = Enum.RaycastFilterType.Exclude
        params.FilterDescendantsInstances = { LocalPlayer.Character, Workspace:FindFirstChild("__ValtSpawns") }
        local result = Workspace:Raycast(ray.Origin, ray.Direction * 600, params)
        if result then return result.Position end
    end

    local ok, mouse = pcall(function() return LocalPlayer:GetMouse() end)
    if ok and mouse and mouse.Hit and mouse.Target then
        return mouse.Hit.Position
    end

    local root = getCharacterRoot()
    if root then
        return root.Position + root.CFrame.LookVector * CONFIG.SPAWN_DISTANCE
    end

    return nil
end

--=====================================================================
-- Spawn
--=====================================================================
local function spawnPet(pet, positionOverride)
    if not running then return false, "unloaded" end

    local modelsFolder = ReplicatedStorage:FindFirstChild("AssetModels")
    if modelsFolder then
        modelsFolder = modelsFolder:FindFirstChild(pet.id)
    end
    if not modelsFolder then
        return false, "no model for " .. pet.id
    end

    local root = getCharacterRoot()
    if not root then
        return false, "character not loaded"
    end

    local clone = modelsFolder:Clone()
    clone.Name = "VALT_" .. pet.id

    local jointed = setupModel(clone, pet)
    clone.Parent = getSpawnFolder()

    local targetPos
    if CONFIG.OWN_PLOT_ONLY then
        targetPos = getPlotSpawnPosition(#activeSpawns)
    end

    if not targetPos then
        if typeof(positionOverride) == "Vector3" then
            targetPos = positionOverride
        else
            local index = #activeSpawns
            local angle = (index % 12) * (math.pi / 6)
            local dist  = CONFIG.SPAWN_DISTANCE + math.floor(index / 12) * 6
            targetPos = root.Position + Vector3.new(math.cos(angle) * dist, 0, math.sin(angle) * dist)
        end
    end

    local finalPos = resolveGroundPosition(targetPos, clone)
    local look     = root.Position

    pcall(function()
        clone:PivotTo(CFrame.new(finalPos, Vector3.new(look.X, finalPos.Y, look.Z)))
    end)

    if CONFIG.NAMETAG then
        pcall(attachNametag, clone, pet)
    end

    playIdle(clone, pet)

    local now = os.clock()
    activeSpawns[#activeSpawns + 1] = {
        model     = clone,
        root      = clone.PrimaryPart,
        basePos   = finalPos,
        t0        = now,
        lastPay   = now,
        name      = pet.name,
        rate      = pet.rate,
        tagHeight = clone:GetExtentsSize().Y * 0.65 + 4,
        jointed   = jointed,
    }

    enforceSpawnLimit()
    return true
end

--=====================================================================
-- Clear spawns
--=====================================================================
local function clearSpawns()
    for _, record in ipairs(activeSpawns) do
        if record.model then
            pcall(function() record.model:Destroy() end)
        end
    end
    table.clear(activeSpawns)

    local folder = Workspace:FindFirstChild("__ValtSpawns")
    if folder then
        pcall(function() folder:Destroy() end)
    end
end

--=====================================================================
-- Money popup
--=====================================================================
local function moneyPopup(record)
    if not record.root or not record.root.Parent then return end

    local billboard = Instance.new("BillboardGui")
    billboard.Name = "ValtCash"
    billboard.Size = UDim2.fromOffset(150, 40)
    billboard.StudsOffsetWorldSpace = Vector3.new(0, record.tagHeight, 0)
    billboard.AlwaysOnTop = true
    billboard.MaxDistance = 300
    billboard.Adornee = record.root
    billboard.Parent = record.root

    local label = Instance.new("TextLabel")
    label.BackgroundTransparency = 1
    label.Size = UDim2.fromScale(1, 1)
    label.Font = Enum.Font.LuckiestGuy
    label.TextScaled = true
    label.TextColor3 = Color3.fromRGB(80, 235, 105)
    label.TextStrokeColor3 = Color3.fromRGB(10, 45, 15)
    label.TextStrokeTransparency = 0.15
    label.Text = "+$" .. abbreviateNumber(record.rate)
    label.Parent = billboard

    TweenService:Create(billboard,
        TweenInfo.new(1.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
        { StudsOffsetWorldSpace = Vector3.new(0, record.tagHeight + 4.5, 0) }
    ):Play()

    TweenService:Create(label,
        TweenInfo.new(1.1, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
        { TextTransparency = 1, TextStrokeTransparency = 1 }
    ):Play()

    Debris:AddItem(billboard, 1.3)
end

--=====================================================================
-- Tool giving
--=====================================================================
local function giveTool(pet)
    if not running then return false, "unloaded" end

    local modelsFolder = ReplicatedStorage:FindFirstChild("AssetModels")
    if modelsFolder then
        modelsFolder = modelsFolder:FindFirstChild(pet.id)
    end
    if not modelsFolder then
        return false, "no model for " .. pet.id
    end

    local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
    if not backpack then
        return false, "no backpack"
    end

    local tool = Instance.new("Tool")
    tool.Name = pet.name
    tool.ToolTip = string.format("%s | $%s/s - click to place (one use)", pet.rarity, abbreviateNumber(pet.rate))
    tool.CanBeDropped = false
    tool.RequiresHandle = true
    tool.TextureId = pet.icon

    local handle = Instance.new("Part")
    handle.Name = "Handle"
    handle.Size = Vector3.new(1, 1, 1)
    handle.Transparency = 1
    handle.CanCollide = false
    handle.CanQuery = false
    handle.CanTouch = false
    handle.Massless = true
    handle.Parent = tool

    local clone = modelsFolder:Clone()
    clone.Name = "Pet"

    local size   = clone:GetExtentsSize()
    local maxDim = math.max(size.X, size.Y, size.Z)
    if maxDim > CONFIG.HAND_MAX_STUDS then
        local factor = CONFIG.HAND_MAX_STUDS / maxDim
        pcall(function() clone:ScaleTo(factor ^ 0.5) end)
    end

    local primary = clone.PrimaryPart or clone:FindFirstChildWhichIsA("BasePart", true)

    local hasMotor = false
    for _, d in ipairs(clone:GetDescendants()) do
        if d:IsA("Motor6D") then
            hasMotor = true
            break
        end
    end

    for _, part in ipairs(clone:GetDescendants()) do
        if part:IsA("BasePart") then
            part.Anchored = false
            part.CanCollide = false
            part.CanQuery = false
            part.CanTouch = false
            part.Massless = true
        end
    end

    clone.Parent = tool

    if primary then
        local weld = Instance.new("Weld")
        weld.Part0 = handle
        weld.Part1 = primary
        weld.C0 = CFrame.new(0, clone:GetExtentsSize().Y * 0.4, 0)
        weld.Parent = handle
    end

    if not hasMotor then
        for _, d in ipairs(clone:GetDescendants()) do
            if d:IsA("BasePart") and d ~= primary then
                local wc = Instance.new("WeldConstraint")
                wc.Part0 = primary
                wc.Part1 = d
                wc.Parent = primary
            end
        end
    else
        playIdle(clone, pet)
    end

    tool.Parent = backpack
    activeTools[#activeTools + 1] = tool

    track(tool.Activated:Connect(function()
        local pos = getSpawnPosition()
        local ok, err = spawnPet(pet, pos)
        if not ok then
            warn("[VALT SPAWNER] place failed: " .. tostring(err))
            return
        end

        for i = #activeTools, 1, -1 do
            if activeTools[i] == tool then
                table.remove(activeTools, i)
            end
        end
        pcall(function() tool:Destroy() end)
    end))

    return true
end

local function clearTools()
    for _, tool in ipairs(activeTools) do
        pcall(function() tool:Destroy() end)
    end
    table.clear(activeTools)
end

--=====================================================================
-- Cash visual (fake local counter)
--=====================================================================
local cashVisual = {
  label = nil,
  base  = 0,
  bonus = 0,
  shown = 0,
  ours  = nil,
  conn  = nil,
  nextScan = 0,
}

local MULTIPLIERS = { K = 1e3, M = 1e6, B = 1e9, T = 1e12 }

local function parseMoney(text)
    local numStr, suffix = tostring(text):gsub("[%$,%s]", ""):match("^([%d%.]+)(%a*)$")
    if not numStr then return nil end
    local mult = suffix ~= "" and MULTIPLIERS[suffix:upper()] or 1
    if not mult then return nil end
    return (tonumber(numStr) or 0) * mult
end

local function formatMoney(n)
    local units = {
        { 1e12, "T" },
        { 1e9,  "B" },
        { 1e6,  "M" },
        { 1e3,  "K" },
    }
    for _, u in ipairs(units) do
        if n >= u[1] then
            local val = n / u[1]
            local fmt = val >= 100 and "%.0f" or "%.1f"
            return "$" .. string.format(fmt, val):gsub("%.0$", "") .. u[2]
        end
    end
    return "$" .. string.format("%.0f", n)
end

local function findMoneyLabel()
    local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    if not playerGui then return nil end

    local hud = playerGui:FindFirstChild("HUD")
    for _, name in ipairs({ "GameHUD", "BottomLeft", "Money", "Value" }) do
        hud = hud and hud:FindFirstChild(name)
    end

    if hud and hud:IsA("TextLabel") then
        return hud
    end

    for _, obj in ipairs(playerGui:GetDescendants()) do
        if obj:IsA("TextLabel") and obj.Text:match("^%$%d") and obj.AbsoluteSize.X > 40 then
            local parent = obj
            while parent do
                if parent:IsA("ScreenGui") then
                    if parent.Enabled then return obj end
                    break
                end
                parent = parent.Parent
            end
        end
    end

    return nil
end

local function hookCashLabel()
    local label = findMoneyLabel()
    if not label then return false end
    if label == cashVisual.label then return true end

    if cashVisual.conn then
        pcall(function() cashVisual.conn:Disconnect() end)
    end

    cashVisual.label = label
    cashVisual.base  = parseMoney(label.Text) or 0
    cashVisual.shown = cashVisual.base + cashVisual.bonus

    cashVisual.conn = track(label:GetPropertyChangedSignal("Text"):Connect(function()
        if label.Text ~= cashVisual.ours then
            cashVisual.base = parseMoney(label.Text) or cashVisual.base
        end
    end))

    return true
end

local function releaseCashLabel()
    if cashVisual.conn then
        pcall(function() cashVisual.conn:Disconnect() end)
    end

    if cashVisual.label and cashVisual.label.Parent then
        pcall(function()
            cashVisual.label.Text = formatMoney(cashVisual.base)
        end)
    end

    cashVisual.label = nil
    cashVisual.conn  = nil
    cashVisual.nextScan = 0
    cashVisual.bonus = 0
    cashVisual.ours  = nil
end

--=====================================================================
-- Heartbeat loop
--=====================================================================
track(RunService.Heartbeat:Connect(function(dt)
    if not running then return end

    local now = os.clock()

    -- Cash visual
    if CONFIG.CASH_VISUAL then
        if not (cashVisual.label and cashVisual.label.Parent) and now >= (cashVisual.nextScan or 0) then
            cashVisual.nextScan = now + 1
            hookCashLabel()
        end

        if cashVisual.label and cashVisual.bonus > 0 then
            local target = cashVisual.base + cashVisual.bonus
            cashVisual.shown = cashVisual.shown + (target - cashVisual.shown) * math.min(1, (dt or 0.016) * 6)
            if math.abs(target - cashVisual.shown) < 1 then
                cashVisual.shown = target
            end
            cashVisual.ours = formatMoney(cashVisual.shown)
            cashVisual.label.Text = cashVisual.ours
        end
    end

    -- Spin/float + payout
    for i = #activeSpawns, 1, -1 do
        local record = activeSpawns[i]

        if not record.model or not record.model.Parent then
            table.remove(activeSpawns, i)
        else
            local shouldRotate = CONFIG.SPIN or CONFIG.FLOAT
            if shouldRotate and record.root and record.root.Anchored then
                local t     = now - record.t0
                local yOff  = CONFIG.FLOAT and math.sin(t * 1.6) * 0.6 or 0
                local yaw   = CONFIG.SPIN and t * 1.1 or 0
                record.root.CFrame = CFrame.new(record.basePos + Vector3.new(0, yOff, 0)) * CFrame.Angles(0, yaw, 0)
            end

            if now - record.lastPay >= CONFIG.PAY_INTERVAL then
                record.lastPay = now
                if CONFIG.MONEY_POPUP then
                    moneyPopup(record)
                end
                if CONFIG.CASH_VISUAL then
                    cashVisual.bonus = cashVisual.bonus + record.rate * CONFIG.PAY_INTERVAL
                end
            end
        end
    end
end))

--=====================================================================
-- Unload
--=====================================================================
local function unload()
    running = false

    for _, conn in ipairs(connections) do
        pcall(function() conn:Disconnect() end)
    end
    table.clear(connections)

    clearSpawns()
    clearTools()
    releaseCashLabel()

    for _, page in ipairs(pageItems) do
        pcall(function() page:Destroy() end)
    end
    table.clear(pageItems)

    if G.__VALT_SPAWNER and G.__VALT_SPAWNER.unload == unload then
        G.__VALT_SPAWNER = nil
    end
    if G.__HUMA_PLACE and G.__HUMA_PLACE.Unload == unload then
        G.__HUMA_PLACE = nil
    end
    warn("[VALT SPAWNER] unloaded")
end

track(UserInputService.InputBegan:Connect(function(input, processed)
    if processed then return end
    if input.KeyCode == Enum.KeyCode.End then
        unload()
    end
end))

--=====================================================================
--=====================================================================
-- NovaUI integration
--=====================================================================
local function notifyResult(action, pet, ok, err)
    if ok then
        Notify("Steal An Egg", action .. ": " .. pet.name, "ok")
    else
        Notify("Steal An Egg", action .. " failed: " .. tostring(err), "error")
    end
end

local function addPage(id, name, icon, order)
    if not Navigation then return nil end
    local page = Navigation:Page({ Id = "sae_" .. id, Name = name, Icon = icon, Order = order })
    pageItems[#pageItems + 1] = page
    return page
end

local function buildUI()
    if not Navigation then
        Notify("Steal An Egg", "NovaUI navigation is unavailable", "error")
        return
    end

    local petsPage = addPage("pets", "Pets", "🥚", 1)
    local previewPage = addPage("preview", "Preview", "◉", 2)
    local optionsPage = addPage("options", "Options", "⚙", 3)
    local bulkPage = addPage("bulk", "Bulk", "✦", 4)
    local aboutPage = addPage("about", "About", "i", 5)

    local petSec = petsPage:Section({ Name = "Pet catalogue" })
    local catalogInfo = petSec:Label(#pets .. " assets indexed")
    local petSelect
    local raritySelect
    local searchBox
    local previewSelect
    local petInfo
    local previewInfo

    local function allPetNames()
        local result = {}
        for _, pet in ipairs(pets) do result[#result + 1] = pet.name end
        return result
    end

    local function filteredPets()
        local result = {}
        local needle = string.lower(tostring(filter.text or ""))
        for _, pet in ipairs(pets) do
            local nameMatch = needle == "" or string.find(string.lower(pet.name), needle, 1, true) ~= nil
            local rarityMatch = filter.rarity == "All" or pet.rarity == filter.rarity
            if nameMatch and rarityMatch then result[#result + 1] = pet end
        end
        return result
    end

    local function petByName(name)
        for _, pet in ipairs(pets) do
            if pet.name == name then return pet end
        end
        return nil
    end

    local function refreshPetInfo()
        if not selectedPet then
            if petInfo then petInfo.Set("No pet selected") end
            if previewInfo then previewInfo.Set("No pet selected") end
            return
        end
        if petInfo then
            petInfo.Set(("%s · %s · earns $%s/s · base scale %.2f"):format(
                selectedPet.name, selectedPet.rarity, abbreviateNumber(selectedPet.rate), selectedPet.scale))
        end
        if previewInfo then
            previewInfo.Set(("%s · %s · $%s/s · base scale %.2f · model id %s"):format(
                selectedPet.name, selectedPet.rarity, abbreviateNumber(selectedPet.rate),
                selectedPet.scale, tostring(selectedPet.id)))
        end
        if previewSelect then previewSelect.Set(selectedPet.name, true) end
        if petSelect then petSelect.Set(selectedPet.name, true) end
    end

    local function updatePetOptions()
        if not petSelect then return end
        local list, found = {}, false
        for _, pet in ipairs(filteredPets()) do
            list[#list + 1] = pet.name
            if pet == selectedPet then found = true end
        end
        if #list == 0 then list = { "No matching pets" } end
        if not found then
            selectedPet = petByName(list[1])
        end
        petSelect.SetOptions(list, true)
        if selectedPet then petSelect.Set(selectedPet.name, true) end
        catalogInfo.Set(("%d of %d assets shown · %d/%d active spawns"):format(
            #filteredPets(), #pets, #activeSpawns, CONFIG.MAX_SPAWNS))
        refreshPetInfo()
    end

    local function selectPet(name)
        local pet = petByName(tostring(name))
        if pet then
            selectedPet = pet
            refreshPetInfo()
        end
    end

    searchBox = petSec:TextBox({
        Name = "Search",
        Placeholder = "pet name…",
        Default = filter.text,
        Flag = "sae_filter_text",
        Callback = function(value)
            filter.text = tostring(value or "")
            updatePetOptions()
        end,
    })
    raritySelect = petSec:Dropdown({
        Name = "Rarity",
        Options = rarityList,
        Default = filter.rarity,
        Flag = "sae_filter_rarity",
        Callback = function(value)
            filter.rarity = tostring(value or "All")
            updatePetOptions()
        end,
    })
    petSelect = petSec:Dropdown({
        Name = "Pet",
        Options = allPetNames(),
        Default = selectedPet and selectedPet.name or (pets[1] and pets[1].name or "No pets"),
        Flag = "sae_selected_pet",
        Callback = selectPet,
    })
    petSec:Button({
        Name = "Use selected",
        Tooltip = "Follows the Give as backpack tool option",
        Callback = function()
            if not selectedPet then Notify("Steal An Egg", "Select a pet first", "warn"); return end
            if CONFIG.GIVE_TOOL then
                local ok, err = giveTool(selectedPet)
                notifyResult("Tool", selectedPet, ok, err)
            else
                local ok, err = spawnPet(selectedPet)
                notifyResult("Spawn", selectedPet, ok, err)
                updatePetOptions()
            end
        end,
    })
    petSec:Button({
        Name = "Give selected as tool",
        Variant = "ghost",
        Tooltip = "Local Tool: equip it and click the world to place",
        Callback = function()
            if not selectedPet then Notify("Steal An Egg", "Select a pet first", "warn"); return end
            local ok, err = giveTool(selectedPet)
            notifyResult("Tool", selectedPet, ok, err)
        end,
    })

    petInfo = petSec:Label("Select a pet to see its details")

    local previewSec = previewPage:Section({ Name = "Selected pet" })
    previewSelect = previewSec:Dropdown({
        Name = "Pet",
        Options = allPetNames(),
        Default = selectedPet and selectedPet.name or (pets[1] and pets[1].name or "No pets"),
        Flag = "sae_preview_pet",
        Callback = function(value)
            local pet = petByName(value)
            if pet then selectedPet = pet; refreshPetInfo() end
        end,
    })
    previewInfo = previewSec:Label("Select a pet to inspect its rarity, payout and base scale.")
    previewSec:Paragraph("NovaUI has no embedded 3D viewport. Use Spawn selected in front to place the actual local model, or Take selected into backpack to hold it.")
    previewSec:Button({
        Name = "Take selected into backpack",
        Callback = function()
            if not selectedPet then Notify("Steal An Egg", "Select a pet first", "warn"); return end
            local ok, err = giveTool(selectedPet)
            notifyResult("Tool", selectedPet, ok, err)
        end,
    })
    previewSec:Button({
        Name = "Spawn selected in front",
        Variant = "ghost",
        Callback = function()
            if not selectedPet then Notify("Steal An Egg", "Select a pet first", "warn"); return end
            local ok, err = spawnPet(selectedPet)
            notifyResult("Spawn", selectedPet, ok, err)
            updatePetOptions()
        end,
    })
    local optSec = optionsPage:Section({ Name = "Spawn behaviour" })
    local function toggle(name, key, desc)
        return optSec:Toggle({ Name = name, Desc = desc, Default = CONFIG[key], Flag = "sae_" .. string.lower(key),
            Callback = function(v) CONFIG[key] = v == true end })
    end
    local function slider(name, key, min, max, decimals, suffix)
        return optSec:Slider({ Name = name, Min = min, Max = max, Decimals = decimals or 0,
            Suffix = suffix or "", Default = CONFIG[key], Flag = "sae_" .. string.lower(key),
            Callback = function(v) CONFIG[key] = tonumber(v) or CONFIG[key] end })
    end
    toggle("Give as backpack tool", "GIVE_TOOL", "Use selected follows this choice: tool when on, local spawn when off")
    slider("Held pet size", "HAND_MAX_STUDS", 2, 14, 0, " studs")
    slider("Scale multiplier", "SCALE_MULT", 0.2, 8, 1, "x")
    slider("Spawn distance", "SPAWN_DISTANCE", 4, 60, 0, " studs")
    slider("Max active spawns", "MAX_SPAWNS", 1, 120, 0, " pets")
    toggle("Spin", "SPIN")
    toggle("Float", "FLOAT")
    toggle("Place in my plot only", "OWN_PLOT_ONLY")
    toggle("Sit on the ground", "GROUND")
    toggle("Play idle animation", "ANIMATE")
    toggle("Name tags", "NAMETAG")
    toggle("Anchored", "ANCHORED")
    toggle("Money popups", "MONEY_POPUP", "Decorative local +$ popups")
    toggle("Local cash visual", "CASH_VISUAL", "Visual only; restores the game's label on unload")
    slider("Payout interval", "PAY_INTERVAL", 0.5, 10, 1, " s")

    local bulkSec = bulkPage:Section({ Name = "Bulk actions" })
    bulkSec:Paragraph("Bulk actions are local model/tool operations. They do not grant server-side pets or money.")
    bulkSec:Button({
        Name = "Spawn random",
        Callback = function()
            if #pets == 0 then Notify("Steal An Egg", "No assets indexed", "error"); return end
            local pet = pets[math.random(1, #pets)]
            selectedPet = pet
            local ok, err = spawnPet(pet)
            notifyResult("Spawn", pet, ok, err)
            updatePetOptions()
        end,
    })
    bulkSec:Button({
        Name = "Spawn every pet in selected rarity",
        Callback = function()
            task.spawn(function()
                if #pets == 0 then return end
                local count = 0
                for _, pet in ipairs(pets) do
                    if filter.rarity == "All" or pet.rarity == filter.rarity then
                        local ok = spawnPet(pet)
                        if ok then count = count + 1 end
                        task.wait(0.05)
                    end
                end
                Notify("Steal An Egg", tostring(count) .. " pets spawned locally", "ok")
                updatePetOptions()
            end)
        end,
    })
    bulkSec:Button({
        Name = "Clear all spawns",
        Variant = "ghost",
        Callback = function()
            local count = #activeSpawns
            clearSpawns()
            Notify("Steal An Egg", tostring(count) .. " local spawns removed", "info")
            updatePetOptions()
        end,
    })
    bulkSec:Button({
        Name = "Empty pet tools",
        Variant = "ghost",
        Callback = function()
            local count = #activeTools
            clearTools()
            Notify("Steal An Egg", tostring(count) .. " local tools removed", "info")
        end,
    })

    local aboutSec = aboutPage:Section({ Name = "What this module does" })
    aboutSec:Paragraph("Pet catalogue, local model spawning, local backpack tools, model scale/anchor/spin/float, idle animation, name tags and decorative payout visuals. The original script never called a game RemoteEvent or RemoteFunction.")
    aboutSec:Label("This module is for PlaceId 107778070777162. It expects ReplicatedStorage.Data.Assets and AssetModels.")
    aboutSec:Button({
        Name = "Unload module",
        Variant = "danger",
        Callback = unload,
    })

    updatePetOptions()
    if selectedPet then
        refreshPetInfo()
    end
end

buildUI()

G.__VALT_SPAWNER = {
    unload = unload,
    CONFIG = CONFIG,
    PETS = pets,
    spawn = spawnPet,
    give = giveTool,
    tools = activeTools,
    clear = clearSpawns,
}
G.__HUMA_PLACE = { Unload = unload }
warn("[VALT SPAWNER] loaded - " .. #pets .. " assets indexed for PlaceId 107778070777162")
end
