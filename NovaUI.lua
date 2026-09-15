--[[
  HumaHub — universal script-hub on top of NovaUI.
  One entrypoint: always gives the user the UNIVERSAL cheat,
  plus auto-loads a place-specific module when you publish one.

  Run (pin a commit/tag instead of main when you release):
    loadstring(game:HttpGet(
      "https://raw.githubusercontent.com/Human4ik1/NovaGUI/main/client/HumaHub.lua"))()

  How place modules work:
    1) Exact override:  HumaHub.PlaceMap[PlaceId] = "https://.../myplace.lua"
    2) Convention:      <repo>/client/places/<PlaceId>.lua
    3) By game name:    <repo>/client/games/<sanitized GameName>.lua
  A place module is any loadstring-able chunk. If it returns a function,
  we call it with an api table:  module(api)
    api = { Nova, Win, Tab, Shared, Notify }
  Inside the module just build on api.Tab, e.g:
    local Nova, Tab, Shared = api.Nova, api.Tab, api.Shared
    Tab:Section({ Name = "Farm" }):Toggle({ Name = "Auto farm", ... })
]]

--// Config ---------------------------------------------------------------
local GITHUB_USER = "Human4ik1"
local REPO        = "NovaGUI"
local BRANCH      = "main"

local NOVA_URL   = ("https://raw.githubusercontent.com/%s/%s/%s/NovaUI.lua"):format(GITHUB_USER, REPO, BRANCH)
local PLACE_BASE = ("https://raw.githubusercontent.com/%s/%s/%s/client/places/"):format(GITHUB_USER, REPO, BRANCH)
local GAME_BASE  = ("https://raw.githubusercontent.com/%s/%s/%s/client/games/"):format(GITHUB_USER, REPO, BRANCH)

local HumaHub = {}
-- Fill this when you publish per-place scripts, e.g:
-- HumaHub.PlaceMap = { [131479356121251] = "https://raw.githubusercontent.com/.../bingo.lua" }
HumaHub.PlaceMap = HumaHub.PlaceMap or {}

--// Single instance: re-inject unloads the previous copy first -------------
-- so you never get stacked windows / duplicated ESP loops and drawings.
pcall(function()
  local g = getgenv and getgenv()
  local prev = g and g.__HUMA_HUB
  if prev and type(prev.Unload) == "function" then prev.Unload() end
end)

--// NovaUI ---------------------------------------------------------------
local Nova
do
  local ok, src = pcall(game.HttpGet, game, NOVA_URL)
  if ok and src and #src > 100 then
    Nova = loadstring(src)()
  else
    error("[HumaHub] NovaUI download failed: " .. tostring(src))
  end
end

--// Services -------------------------------------------------------------
local Players   = game:GetService("Players")
local RunSvc    = game:GetService("RunService")
local UIS       = game:GetService("UserInputService")
local Lighting  = game:GetService("Lighting")
local Teleport  = game:GetService("TeleportService")
local Stats     = game:GetService("Stats")
local LP        = Players.LocalPlayer or Players.PlayerAdded:Wait()
local Camera    = workspace.CurrentCamera
local Mouse     = LP:GetMouse()

Camera = Camera or workspace:WaitForChild("Camera")

local function Notify(t, txt, kind)
  pcall(function() Nova:Notify({ Title = t, Text = txt, Type = kind or "info", Duration = 3 }) end)
end

local HAS_DRAWING = false
pcall(function()
  HAS_DRAWING = (typeof(Drawing) == "table" or typeof(Drawing) == "Instance" or Drawing ~= nil)
    and type(Drawing.new) == "function"
end)

local CAN_HIGHLIGHT = false
pcall(function()
  local h = Instance.new("Highlight")
  h:Destroy()
  CAN_HIGHLIGHT = true
end)

--// State ----------------------------------------------------------------
local S = {
  -- esp render
  espOn = false, boxStyle = "Corner", thickness = 2, maxDist = 2500,
  showFriends = true, showEnemies = true, hideWalled = false,
  -- esp info
  names = true, health = true, distance = true, tool = false,
  tracer = false, tracerFrom = "Bottom",
  -- esp colors
  friendCol  = Color3.fromRGB(80, 220, 140),
  enemyCol   = Color3.fromRGB(255, 110, 130),
  friendHid  = Color3.fromRGB(120, 160, 255),
  enemyHid   = Color3.fromRGB(255, 170, 80),
  nearest = false, nearestOnlyEnemies = true,
  nearestCol = Color3.fromRGB(255, 235, 120),
  -- teams
  useTeamColor = false, unknownIsEnemy = true,
  -- glow
  glowOn = false, glowFill = 0.45, glowOutline = 0.15, glowTop = true,
  glowFriends = true, glowEnemies = true,
  -- movement
  fly = false, flySpeed = 80, flyMode = "CFrame", flyNoclip = true,
  noclip = false, ws = 16, lockWS = false, jp = 50, lockJP = false,
  infJump = false, clickTP = false,
  -- world/misc
  fullbright = false, antiAFK = false,
}

local CONNS = {}
local function bind(c) table.insert(CONNS, c) return c end

--// Character helpers ----------------------------------------------------
local function charOf(plr) return plr and plr.Character end
local function hrpOf(plr)
  local ch = charOf(plr)
  return ch and ch:FindFirstChild("HumanoidRootPart")
end
local function headOf(plr)
  local ch = charOf(plr)
  if not ch then return nil end
  return ch:FindFirstChild("Head") or ch:FindFirstChildWhichIsA("BasePart", true)
end
local function humOf(plr)
  local ch = charOf(plr)
  return ch and ch:FindFirstChildOfClass("Humanoid")
end
local function isAlive(plr)
  local hum = humOf(plr)
  return hum ~= nil and hum.Health > 0
end

local function toolName(plr)
  local ch = charOf(plr)
  if ch then
    for _, t in ipairs(ch:GetChildren()) do
      if t:IsA("Tool") then return t.Name end
    end
  end
  local bp = plr:FindFirstChild("Backpack")
  if bp then
    local first = bp:FindFirstChildWhichIsA("Tool")
    if first then return first.Name end
  end
  return "—"
end

local function distanceTo(plr)
  local hrp = hrpOf(plr)
  local my = hrpOf(LP)
  if not hrp or not my then return math.huge end
  return (hrp.Position - my.Position).Magnitude
end

--// Teams: auto-scan ------------------------------------------------------
-- We look in every place where games usually store "who is who":
-- Player.Team, attributes (Team/Group/Role/Faction/...),
-- leaderstats values with team-ish names, character StringValues.
local TEAM_KEYS = { "team", "group", "role", "faction", "side", "squad", "clan", "gang", "nation", "army" }
local function isTeamish(s)
  s = string.lower(tostring(s))
  for _, k in ipairs(TEAM_KEYS) do
    if string.find(s, k, 1, true) then return true end
  end
  return false
end

local function teamKey(plr)
  if plr.Team and plr.Team.Name then
    return "Team:" .. tostring(plr.Team.Name)
  end
  local okA, attrs = pcall(function() return plr:GetAttributes() end)
  if okA and type(attrs) == "table" then
    for k, v in pairs(attrs) do
      if isTeamish(k) then return "Attr:" .. tostring(k) .. "=" .. tostring(v) end
    end
  end
  local ls = plr:FindFirstChild("leaderstats")
  if ls then
    for _, v in ipairs(ls:GetChildren()) do
      if isTeamish(v.Name) then
        local okV, val = pcall(function() return v.Value end)
        if okV then return "Stat:" .. tostring(v.Name) .. "=" .. tostring(val) end
      end
    end
  end
  local ch = charOf(plr)
  if ch then
    for _, v in ipairs(ch:GetChildren()) do
      if (v:IsA("StringValue") or v:IsA("ObjectValue")) and isTeamish(v.Name) then
        local okV, val = pcall(function() return v.Value end)
        if okV then
          local nm = (typeof(val) == "Instance") and val.Name or tostring(val)
          return "Char:" .. tostring(v.Name) .. "=" .. nm
        end
      end
    end
  end
  return "NoTeam"
end

local FriendSet, EnemySet = {}, {}

local function scanTeamKeys()
  local counts, list = {}, {}
  for _, plr in ipairs(Players:GetPlayers()) do
    if plr ~= LP then
      local k = teamKey(plr)
      if not counts[k] then counts[k] = 0; table.insert(list, k) end
      counts[k] = counts[k] + 1
    end
  end
  table.sort(list)
  return list, counts
end

local function isFriend(plr)
  local k = teamKey(plr)
  if FriendSet[k] then return true end
  if EnemySet[k] then return false end
  if S.useTeamColor and LP.Team ~= nil and plr.Team == LP.Team then
    return true
  end
  if S.unknownIsEnemy then return false end
  return true
end

--// Visibility (wall check) ----------------------------------------------
local RayParamsCache = nil
local function rayParams(targetChar)
  local p = RaycastParams.new()
  p.FilterType = Enum.RaycastFilterType.Exclude
  local excl = { Camera }
  if charOf(LP) then table.insert(excl, charOf(LP)) end
  if targetChar then table.insert(excl, targetChar) end
  p.FilterDescendantsInstances = excl
  p.IgnoreWater = true
  return p
end

local function isOccluded(part, targetChar)
  if not part then return true end
  local origin = Camera.CFrame.Position
  local dir = part.Position - origin
  local dist = dir.Magnitude
  if dist < 1 then return false end
  local ok, hit = pcall(function()
    return workspace:Raycast(origin, dir, rayParams(targetChar))
  end)
  if not ok then return false end
  return hit ~= nil
end

--// Window ---------------------------------------------------------------
-- Forward refs: OnUnload (defined here) runs later but must see these locals.
local espCache = {}
HumaHubUnloaded = false
local placeLabel = "PlaceId " .. tostring(game.PlaceId)
local win = Nova:Window({
  Title = "HUMA HUB",
  Subtitle = game.Name .. " · " .. placeLabel,
  Footer = "RightShift — hide  •  NovaUI " .. tostring(Nova.Version),
  Keybind = Enum.KeyCode.RightShift,
  OnUnload = function()
    -- FULL unload: no loops, no drawings, no highlights, no place logic left.
    -- (Minimize "—" only hides the window; RightShift brings it back.)
    HumaHubUnloaded = true
    for _, c in ipairs(CONNS) do pcall(function() c:Disconnect() end) end
    -- restore character physics touched by fly
    pcall(function()
      local hum = humOf(LP)
      if hum then hum.PlatformStand = false end
      local hrp = hrpOf(LP)
      if hrp then
        hrp.AssemblyLinearVelocity = Vector3.zero
        hrp.AssemblyAngularVelocity = Vector3.zero
      end
    end)
    pcall(function()
      for _, e in pairs(espCache) do
        if type(e) == "table" then
          local function del(o)
            if o and typeof(o) ~= "Instance" and type(o.Remove) == "function" then
              pcall(function() o:Remove() end)
            elseif o and typeof(o) == "Instance" then
              pcall(function() o:Destroy() end)
            end
          end
          del(e.outline); del(e.box); del(e.hback); del(e.hfill)
          del(e.name); del(e.dist); del(e.tool); del(e.trace); del(e.dot)
          if type(e.corners) == "table" then
            for _, l in ipairs(e.corners) do del(l) end
          end
        end
      end
    end)
    -- billboards + glow highlights (all players, incl. left ones)
    pcall(function()
      for _, plr in ipairs(Players:GetPlayers()) do
        local ch = plr.Character
        if ch then
          local bb = ch:FindFirstChild("HumaESP_BB")
          if bb then bb:Destroy() end
          local h = ch:FindFirstChild("HumaGlow")
          if h then h:Destroy() end
        end
      end
    end)
    -- mini HUD chip
    pcall(function() if hudGui then hudGui:Destroy() end end)
    hudGui, hudCard, hudBody = nil, nil, nil
    -- place modules (bingo etc.): stop their remote handlers
    pcall(function()
      local g = getgenv and getgenv()
      local b = g and g.__HUMA_BINGO
      if b and type(b.conns) == "table" then
        for _, c in ipairs(b.conns) do pcall(function() c:Disconnect() end) end
      end
      if g then g.__HUMA_BINGO = nil; g.__HUMA_HUB = nil end
    end)
  end,
})

local uniTab   = win:Tab({ Name = "Universal", Icon = "◆" })
local placeTab = win:Tab({ Name = "Place", Icon = "★" })
local setTab   = win:Tab({ Name = "Settings", Icon = "≡" })

--// Mini status HUD ----------------------------------------------------------
-- A tiny corner chip that stays visible while the main window is hidden
-- (RightShift). Hub core + place modules push lines via Shared.SetHud(key).
local hudGui, hudCard, hudBody, hudStroke = nil, nil, nil, nil
local hudLines = {}
local hudVisible, hudCorner = true, "TopLeft"
local hudContent, hudTextSize, hudBgT = { "Ping", "FPS" }, 12, 0.18
local hudRate, hudModules = 0.5, true
local lastFps, lastPing, lastPlayers = 60, "—", 0
local function hudRefresh()
  if not hudBody then return end
  local parts = {}
  local hub = hudLines["hub"]
  if hub and hub ~= "" then table.insert(parts, tostring(hub)) end
  if hudModules then
    for _, k in ipairs({ "bingo", "bingoStats" }) do
      local v = hudLines[k]
      if v and v ~= "" then table.insert(parts, tostring(v)) end
    end
  end
  hudBody.Text = #parts > 0 and table.concat(parts, "\n") or "…"
end
local function hudStatsLine()
  local has = {}
  for _, k in ipairs(hudContent) do has[tostring(k)] = true end
  local parts = {}
  if has.Ping then table.insert(parts, tostring(lastPing)) end
  if has.FPS then table.insert(parts, tostring(lastFps) .. " fps") end
  if has.Players then table.insert(parts, tostring(lastPlayers) .. " pl") end
  if has.Flags then
    if S.fly then table.insert(parts, "FLY") end
    if S.noclip then table.insert(parts, "NC") end
  end
  return table.concat(parts, " · ")
end
local function hudApplyStyle()
  pcall(function()
    if hudBody then hudBody.TextSize = hudTextSize end
    if hudCard then hudCard.BackgroundTransparency = hudBgT end
    if hudStroke then hudStroke.Transparency = math.clamp(hudBgT + 0.15, 0, 1) end
  end)
end
local function hudSet(key, text)
  hudLines[tostring(key)] = text
  pcall(hudRefresh)
end
local function hudApplyVisible()
  pcall(function() if hudGui then hudGui.Enabled = hudVisible == true end end)
end
local function hudPlace()
  if not hudCard then return end
  local c = hudCorner
  if c == "TopRight" then
    hudCard.AnchorPoint = Vector2.new(1, 0)
    hudCard.Position = UDim2.new(1, -12, 0, 70)
  elseif c == "BottomLeft" then
    hudCard.AnchorPoint = Vector2.new(0, 1)
    hudCard.Position = UDim2.new(0, 12, 1, -12)
  elseif c == "BottomRight" then
    hudCard.AnchorPoint = Vector2.new(1, 1)
    hudCard.Position = UDim2.new(1, -12, 1, -12)
  else
    hudCard.AnchorPoint = Vector2.new(0, 0)
    hudCard.Position = UDim2.new(0, 12, 0, 70)
  end
end
do
  local sg = Instance.new("ScreenGui")
  sg.Name = "HumaHUD"
  sg.ResetOnSpawn = false
  sg.IgnoreGuiInset = true
  sg.DisplayOrder = 60
  sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
  pcall(function()
    if gethui then local h = gethui() if h then sg.Parent = h end end
  end)
  if not sg.Parent then
    sg.Parent = LP:WaitForChild("PlayerGui")
  end
  local card = Instance.new("Frame")
  card.Name = "Card"
  card.BackgroundColor3 = Color3.fromRGB(16, 16, 20)
  card.BackgroundTransparency = 0.18
  card.BorderSizePixel = 0
  card.Size = UDim2.fromOffset(248, 0)
  card.AutomaticSize = Enum.AutomaticSize.Y
  card.Active = true
  card.Parent = sg
  local corner = Instance.new("UICorner")
  corner.CornerRadius = UDim.new(0, 9)
  corner.Parent = card
  local stroke = Instance.new("UIStroke")
  stroke.Color = Color3.fromRGB(48, 48, 58)
  stroke.Transparency = 0.35
  stroke.Thickness = 1
  stroke.Parent = card
  hudStroke = stroke
  local pad = Instance.new("UIPadding")
  pad.PaddingLeft = UDim.new(0, 12)
  pad.PaddingRight = UDim.new(0, 12)
  pad.PaddingTop = UDim.new(0, 8)
  pad.PaddingBottom = UDim.new(0, 8)
  pad.Parent = card
  local lay = Instance.new("UIListLayout")
  lay.Padding = UDim.new(0, 2)
  lay.SortOrder = Enum.SortOrder.LayoutOrder
  lay.Parent = card
  local title = Instance.new("TextLabel")
  title.Name = "Title"
  title.BackgroundTransparency = 1
  title.Size = UDim2.new(1, 0, 0, 14)
  title.Font = Enum.Font.GothamBold
  title.TextSize = 11
  title.TextColor3 = Color3.fromRGB(122, 150, 255)
  title.TextXAlignment = Enum.TextXAlignment.Left
  title.Text = "HUMA HUB"
  title.LayoutOrder = 1
  title.Parent = card
  local body = Instance.new("TextLabel")
  body.Name = "Body"
  body.BackgroundTransparency = 1
  body.Size = UDim2.new(1, 0, 0, 14)
  body.AutomaticSize = Enum.AutomaticSize.Y
  body.Font = Enum.Font.GothamMedium
  body.TextSize = 12
  body.TextColor3 = Color3.fromRGB(238, 238, 243)
  body.TextXAlignment = Enum.TextXAlignment.Left
  body.TextYAlignment = Enum.TextYAlignment.Top
  body.TextWrapped = true
  body.Text = "…"
  body.LayoutOrder = 2
  body.Parent = card
  hudGui, hudCard, hudBody = sg, card, body
  hudPlace()
  hudApplyStyle()
  hudApplyVisible()
  hudRefresh()
  -- drag: snapshot Position+AnchorPoint, apply pointer delta only
  -- (same teleport-proof pattern as the main window drag)
  do
    local dragging = false
    local sx, sy, gsx, gsy, gox, goy, gax, gay = 0, 0, 0, 0, 0, 0, 0, 0
    card.InputBegan:Connect(function(inp)
      local t = inp.UserInputType
      if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
        if not card.Parent then return end
        dragging = true
        sx, sy = inp.Position.X, inp.Position.Y
        local gp = card.Position
        gsx, gsy, gox, goy = gp.X.Scale, gp.Y.Scale, gp.X.Offset, gp.Y.Offset
        gax, gay = card.AnchorPoint.X, card.AnchorPoint.Y
      end
    end)
    table.insert(CONNS, UIS.InputChanged:Connect(function(inp)
      if not dragging or not card.Parent then return end
      local t = inp.UserInputType
      if t ~= Enum.UserInputType.MouseMovement and t ~= Enum.UserInputType.Touch then return end
      local vp = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize or Vector2.new(1280, 720)
      local w, h = card.AbsoluteSize.X, card.AbsoluteSize.Y
      local baseX = gsx * vp.X + gox - gax * w
      local baseY = gsy * vp.Y + goy - gay * h
      local nx = math.clamp(baseX + (inp.Position.X - sx), -w + 90, vp.X - 90)
      local ny = math.clamp(baseY + (inp.Position.Y - sy), 0, vp.Y - 44)
      card.Position = UDim2.new(gsx, nx + gax * w - gsx * vp.X,
        gsy, ny + gay * h - gsy * vp.Y)
    end))
    table.insert(CONNS, UIS.InputEnded:Connect(function(inp)
      local t = inp.UserInputType
      if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
        dragging = false
      end
    end))
  end
end

--// ESP engine (Drawing) --------------------------------------------------
_G.__HumaESP = espCache

local function newDraw(class, props)
  local d = Drawing.new(class)
  for k, v in pairs(props) do
    local ok = pcall(function() d[k] = v end)
    if not ok then end
  end
  return d
end

local function makeESP(plr)
  local e = espCache[plr]
  if e then return e end
  e = { player = plr, corners = {} }
  if HAS_DRAWING then
    e.outline = newDraw("Square", { Visible = false, Filled = false, Thickness = 3, Color = Color3.new(0, 0, 0), Transparency = 0.55, ZIndex = 1 })
    e.box     = newDraw("Square", { Visible = false, Filled = false, Thickness = 2, Color = Color3.new(1, 1, 1), ZIndex = 2 })
    for i = 1, 8 do
      e.corners[i] = newDraw("Line", { Visible = false, Thickness = 2, Color = Color3.new(1, 1, 1), ZIndex = 2 })
    end
    e.hback = newDraw("Square", { Visible = false, Filled = true, Color = Color3.new(0, 0, 0), Transparency = 0.5, ZIndex = 1 })
    e.hfill = newDraw("Square", { Visible = false, Filled = true, Color = Color3.new(0, 1, 0), ZIndex = 2 })
    e.name  = newDraw("Text", { Visible = false, Center = true, Outline = true, Size = 13, Color = Color3.new(1, 1, 1), ZIndex = 3 })
    e.dist  = newDraw("Text", { Visible = false, Center = true, Outline = true, Size = 12, Color = Color3.fromRGB(200, 200, 210), ZIndex = 3 })
    e.tool  = newDraw("Text", { Visible = false, Center = true, Outline = true, Size = 12, Color = Color3.fromRGB(200, 200, 210), ZIndex = 3 })
    e.trace = newDraw("Line", { Visible = false, Thickness = 1, Color = Color3.new(1, 1, 1), Transparency = 0.7, ZIndex = 1 })
    e.dot   = newDraw("Circle", { Visible = false, Filled = true, Radius = 4, Color = Color3.new(1, 1, 1), ZIndex = 3 })
  end
  espCache[plr] = e
  return e
end

local function hideESP(e)
  if not e then return end
  local function off(o) if o then pcall(function() o.Visible = false end) end end
  off(e.outline); off(e.box); off(e.hback); off(e.hfill)
  off(e.name); off(e.dist); off(e.tool); off(e.trace); off(e.dot)
  if e.corners then for _, l in ipairs(e.corners) do off(l) end end
end

local function freeESP(plr)
  local e = espCache[plr]
  if not e then return end
  local function del(o) if o then pcall(function() o:Remove() end) end end
  del(e.outline); del(e.box); del(e.hback); del(e.hfill)
  del(e.name); del(e.dist); del(e.tool); del(e.trace); del(e.dot)
  if e.corners then for _, l in ipairs(e.corners) do del(l) end end
  local bb = e.billboard
  if bb then pcall(function() bb:Destroy() end) end
  espCache[plr] = nil
end

-- Billboard fallback when the executor has no Drawing (names/dist/hp only).
local function ensureBillboard(plr, color, text)
  local head = headOf(plr)
  if not head then return nil end
  local ch = charOf(plr)
  local bb = ch and ch:FindFirstChild("HumaESP_BB")
  if not bb then
    bb = Instance.new("BillboardGui")
    bb.Name = "HumaESP_BB"
    bb.Size = UDim2.fromOffset(200, 46)
    bb.StudsOffset = Vector3.new(0, 2.6, 0)
    bb.AlwaysOnTop = true
    local tl = Instance.new("TextLabel")
    tl.Name = "T"
    tl.BackgroundTransparency = 1
    tl.Size = UDim2.fromScale(1, 1)
    tl.Font = Enum.Font.GothamMedium
    tl.TextSize = 12
    tl.TextStrokeTransparency = 0.4
    tl.TextWrapped = true
    tl.Parent = bb
    bb.Parent = ch
  end
  local tl = bb:FindFirstChild("T")
  if tl then
    tl.Text = text
    tl.TextColor3 = color
  end
  return bb
end

local function clearBillboard(plr)
  local ch = charOf(plr)
  local bb = ch and ch:FindFirstChild("HumaESP_BB")
  if bb then pcall(function() bb:Destroy() end) end
end

local nearestPlayer = nil

local function tracerOrigin(vs)
  if S.tracerFrom == "Center" then
    return Vector2.new(vs.X / 2, vs.Y / 2)
  elseif S.tracerFrom == "Mouse" then
    local m = UIS:GetMouseLocation()
    return Vector2.new(m.X, m.Y)
  elseif S.tracerFrom == "Top" then
    return Vector2.new(vs.X / 2, 0)
  else
    return Vector2.new(vs.X / 2, vs.Y - 2) -- Bottom
  end
end

local function updateESP()
  if Camera ~= workspace.CurrentCamera then
    Camera = workspace.CurrentCamera
  end
  local vs = Camera and Camera.ViewportSize or Vector2.new(1280, 720)

  -- nearest (for highlight); computed first, drawn below
  nearestPlayer = nil
  if S.nearest and S.espOn then
    local mpos = UIS:GetMouseLocation()
    local best = 1e9
    for _, plr in ipairs(Players:GetPlayers()) do
      if plr ~= LP and isAlive(plr) then
        local friend = isFriend(plr)
        if (not S.nearestOnlyEnemies) or (not friend) then
          if (friend and S.showFriends) or ((not friend) and S.showEnemies) then
            local d = distanceTo(plr)
            if d <= S.maxDist then
              local hrp = hrpOf(plr)
              if hrp then
                local sp, on = Camera:WorldToViewportPoint(hrp.Position)
                if on then
                  local sd = (Vector2.new(sp.X, sp.Y) - mpos).Magnitude
                  if sd < best then best = sd; nearestPlayer = plr end
                end
              end
            end
          end
        end
      end
    end
  end

  for _, plr in ipairs(Players:GetPlayers()) do
    if plr == LP then
      -- never draw self
    else
      local e = makeESP(plr)
      local show = S.espOn and isAlive(plr)
      local friend = isFriend(plr)
      if show and friend and not S.showFriends then show = false end
      if show and (not friend) and not S.showEnemies then show = false end

      local dist = distanceTo(plr)
      if show and dist > S.maxDist then show = false end

      local hrp, head, hum = hrpOf(plr), headOf(plr), humOf(plr)
      if show and (not hrp or not hum) then show = false end

      if not show then
        hideESP(e)
        if not S.espOn then clearBillboard(plr) end
      else
        -- project box from bounding box
        local ch = charOf(plr)
        local cf, size = nil, nil
        pcall(function() cf, size = ch:GetBoundingBox() end)
        local top3, bot3
        if cf and size then
          top3 = Vector3.new(cf.X, cf.Y + size.Y / 2, cf.Z)
          bot3 = Vector3.new(cf.X, cf.Y - size.Y / 2, cf.Z)
        else
          top3 = (head and head.Position or hrp.Position) + Vector3.new(0, 0.6, 0)
          bot3 = hrp.Position - Vector3.new(0, 3, 0)
        end
        local t2, tOn = Camera:WorldToViewportPoint(top3)
        local b2, bOn = Camera:WorldToViewportPoint(bot3)
        local behind = (t2.Z < 0) or (b2.Z < 0)
        if (not tOn and not bOn) or behind then
          hideESP(e)
        else
          local h = math.max(math.abs(b2.Y - t2.Y), 8)
          local w = math.max(h * 0.62, 10)
          local cx = (t2.X + b2.X) / 2
          local x0, y0 = cx - w / 2, math.min(t2.Y, b2.Y)

          local occluded = false
          if head then occluded = isOccluded(head, ch) end
          if S.hideWalled and occluded then
            hideESP(e)
          else
            local base
            if friend then
              base = occluded and S.friendHid or S.friendCol
            else
              base = occluded and S.enemyHid or S.enemyCol
            end
            if S.useTeamColor and plr.Team and plr.Team.TeamColor then
              base = plr.Team.TeamColor.Color
            end
            local isNear = (plr == nearestPlayer)
            local col = isNear and S.nearestCol or base

            if not HAS_DRAWING then
              -- fallback: billboard text only
              local hpTxt = ""
              if S.health and hum then
                hpTxt = ("  %d/%d"):format(math.floor(hum.Health + 0.5), math.floor(hum.MaxHealth + 0.5))
              end
              local lines = {}
              if S.names then table.insert(lines, plr.DisplayName .. " (@" .. plr.Name .. ")" .. hpTxt) end
              if S.distance then table.insert(lines, ("[%dm]%s"):format(math.floor(dist + 0.5), occluded and " • wall" or "")) end
              if S.tool then table.insert(lines, "▸ " .. toolName(plr)) end
              ensureBillboard(plr, col, table.concat(lines, "\n"))
            else
              clearBillboard(plr)
              -- box
              local th = S.thickness
              if S.boxStyle == "Full" then
                for _, l in ipairs(e.corners) do l.Visible = false end
                e.outline.Visible = true
                e.box.Visible = true
                e.outline.Size = Vector2.new(w + 2, h + 2)
                e.outline.Position = Vector2.new(x0 - 1, y0 - 1)
                e.box.Size = Vector2.new(w, h)
                e.box.Position = Vector2.new(x0, y0)
                e.box.Color = col
                e.box.Thickness = th
              elseif S.boxStyle == "3D" then
                -- cheap 3D: full rect + depth offset rect
                for _, l in ipairs(e.corners) do l.Visible = false end
                e.outline.Visible = true
                e.box.Visible = true
                local dx, dy = math.clamp(w * 0.18, 4, 18), math.clamp(h * 0.06, 3, 12)
                e.box.Size = Vector2.new(w, h)
                e.box.Position = Vector2.new(x0, y0)
                e.box.Color = col
                e.box.Thickness = th
                e.outline.Size = Vector2.new(w, h)
                e.outline.Position = Vector2.new(x0 + dx, y0 - dy)
                e.outline.Color = col
                e.outline.Transparency = 0.75
                e.outline.Thickness = 1
              else -- Corner
                e.outline.Visible = false
                e.box.Visible = false
                local L = math.clamp(math.min(w, h) * 0.28, 5, 26)
                local pts = {
                  { Vector2.new(x0, y0 + L), Vector2.new(x0, y0) },
                  { Vector2.new(x0, y0), Vector2.new(x0 + L, y0) },
                  { Vector2.new(x0 + w - L, y0), Vector2.new(x0 + w, y0) },
                  { Vector2.new(x0 + w, y0), Vector2.new(x0 + w, y0 + L) },
                  { Vector2.new(x0, y0 + h - L), Vector2.new(x0, y0 + h) },
                  { Vector2.new(x0, y0 + h), Vector2.new(x0 + L, y0 + h) },
                  { Vector2.new(x0 + w - L, y0 + h), Vector2.new(x0 + w, y0 + h) },
                  { Vector2.new(x0 + w, y0 + h), Vector2.new(x0 + w, y0 + h - L) },
                }
                for i = 1, 8 do
                  local ln = e.corners[i]
                  ln.Visible = true
                  ln.From = pts[i][1]
                  ln.To = pts[i][2]
                  ln.Color = col
                  ln.Thickness = th
                end
              end

              -- health bar (left)
              if S.health and hum then
                local frac = math.clamp(hum.Health / math.max(hum.MaxHealth, 1), 0, 1)
                local bx = x0 - 7
                e.hback.Visible = true
                e.hback.Size = Vector2.new(3, h)
                e.hback.Position = Vector2.new(bx, y0)
                e.hfill.Visible = true
                e.hfill.Size = Vector2.new(3, h * frac)
                e.hfill.Position = Vector2.new(bx, y0 + h * (1 - frac))
                e.hfill.Color = Color3.fromHSV(frac * 0.33, 0.85, 0.95)
              else
                e.hback.Visible = false
                e.hfill.Visible = false
              end

              -- texts
              if S.names then
                e.name.Visible = true
                local hpS = ""
                if S.health and hum then
                  hpS = ("  %d"):format(math.floor(hum.Health + 0.5))
                end
                e.name.Text = plr.DisplayName .. " (@" .. plr.Name .. ")" .. hpS
                e.name.Color = col
                e.name.Position = Vector2.new(cx, y0 - 15)
              else
                e.name.Visible = false
              end
              local below = y0 + h + 2
              if S.distance then
                e.dist.Visible = true
                e.dist.Text = ("[%dm]%s"):format(math.floor(dist + 0.5), occluded and " wall" or "")
                e.dist.Position = Vector2.new(cx, below)
                below = below + 13
              else
                e.dist.Visible = false
              end
              if S.tool then
                e.tool.Visible = true
                e.tool.Text = toolName(plr)
                e.tool.Position = Vector2.new(cx, below)
              else
                e.tool.Visible = false
              end

              -- tracer
              if S.tracer then
                e.trace.Visible = true
                e.trace.From = tracerOrigin(vs)
                e.trace.To = Vector2.new(cx, y0 + h)
                e.trace.Color = col
                e.trace.Thickness = math.max(1, math.floor(th / 2))
              else
                e.trace.Visible = false
              end

              -- nearest dot on head
              if isNear and head then
                local hp2, on2 = Camera:WorldToViewportPoint(head.Position)
                if on2 and hp2.Z > 0 then
                  e.dot.Visible = true
                  e.dot.Position = Vector2.new(hp2.X, hp2.Y - 22)
                  e.dot.Color = S.nearestCol
                else
                  e.dot.Visible = false
                end
              else
                e.dot.Visible = false
              end
            end
          end
        end
      end
    end
  end
end

--// Glow / chams (Highlight per character) --------------------------------
local function ensureGlow(plr)
  if not CAN_HIGHLIGHT then return nil end
  local ch = charOf(plr)
  if not ch then return nil end
  local h = ch:FindFirstChild("HumaGlow")
  if not h then
    local ok, inst = pcall(function()
      local hl = Instance.new("Highlight")
      hl.Name = "HumaGlow"
      hl.Adornee = ch
      hl.Parent = ch
      return hl
    end)
    if ok then h = inst else return nil end
  end
  return h
end

local function updateGlow()
  if not CAN_HIGHLIGHT then return end
  for _, plr in ipairs(Players:GetPlayers()) do
    if plr == LP then
      -- skip
    else
      local ch = charOf(plr)
      local h = (ch and ch:FindFirstChild("HumaGlow"))
      local want = S.glowOn and (ch ~= nil) and isAlive(plr)
      local friend = isFriend(plr)
      if want and friend and not S.glowFriends then want = false end
      if want and (not friend) and not S.glowEnemies then want = false end
      if not want then
        if h then h.Enabled = false end
      else
        h = ensureGlow(plr)
        if h then
          local col = friend and S.friendCol or S.enemyCol
          h.Enabled = true
          h.FillColor = col
          h.OutlineColor = Color3.new(1, 1, 1)
          h.FillTransparency = math.clamp(S.glowFill, 0, 1)
          h.OutlineTransparency = math.clamp(S.glowOutline, 0, 1)
          h.DepthMode = S.glowTop and Enum.HighlightDepthMode.AlwaysOnTop
            or Enum.HighlightDepthMode.Occluded
        end
      end
    end
  end
end

local glowTick = 0

--// Movement: fly / noclip / speed ----------------------------------------
local flyKeys = { Up = false, Down = false }
bind(UIS.InputBegan:Connect(function(inp, gpe)
  if gpe then return end
  if inp.KeyCode == Enum.KeyCode.Space or inp.KeyCode == Enum.KeyCode.E then flyKeys.Up = true end
  if inp.KeyCode == Enum.KeyCode.LeftShift or inp.KeyCode == Enum.KeyCode.Q or inp.KeyCode == Enum.KeyCode.C then flyKeys.Down = true end
end))
bind(UIS.InputEnded:Connect(function(inp)
  if inp.KeyCode == Enum.KeyCode.Space or inp.KeyCode == Enum.KeyCode.E then flyKeys.Up = false end
  if inp.KeyCode == Enum.KeyCode.LeftShift or inp.KeyCode == Enum.KeyCode.Q or inp.KeyCode == Enum.KeyCode.C then flyKeys.Down = false end
end))

local function setFlying(v)
  S.fly = v == true
  local hum = humOf(LP)
  if hum and S.flyMode == "CFrame" then
    pcall(function() hum.PlatformStand = S.fly end)
  end
  if not S.fly then
    local hrp = hrpOf(LP)
    if hrp then
      pcall(function()
        hrp.AssemblyLinearVelocity = Vector3.zero
        hrp.AssemblyAngularVelocity = Vector3.zero
      end)
    end
    if hum then pcall(function() hum.PlatformStand = false end) end
  end
end

bind(RunSvc.Heartbeat:Connect(function(dt)
  local hrp = hrpOf(LP)
  local hum = humOf(LP)
  if not hrp or not hum then return end
  -- fly
  if S.fly then
    local move = hum.MoveDirection
    local y = 0
    if flyKeys.Up then y = y + 1 end
    if flyKeys.Down then y = y - 1 end
    local dir = (move * Vector3.new(1, 0, 1)) + Vector3.new(0, y, 0)
    if dir.Magnitude > 1 then dir = dir.Unit end
    local step = dir * (S.flySpeed * math.max(dt, 1 / 240))
    if S.flyMode == "Velocity" then
      pcall(function()
        hrp.AssemblyLinearVelocity = dir * S.flySpeed
        hrp.AssemblyAngularVelocity = Vector3.zero
      end)
    else
      pcall(function()
        hrp.CFrame = hrp.CFrame + step
        hrp.AssemblyLinearVelocity = Vector3.zero
        hrp.AssemblyAngularVelocity = Vector3.zero
      end)
    end
    if S.flyNoclip or S.noclip then
      local ch = charOf(LP)
      if ch then
        for _, p in ipairs(ch:GetDescendants()) do
          if p:IsA("BasePart") then p.CanCollide = false end
        end
      end
    end
  elseif S.noclip then
    local ch = charOf(LP)
    if ch then
      for _, p in ipairs(ch:GetDescendants()) do
        if p:IsA("BasePart") then p.CanCollide = false end
      end
    end
  end
  -- speed locks (cheap re-apply, survives most resets)
  if S.lockWS and hum then
    if math.abs(hum.WalkSpeed - S.ws) > 0.5 then
      pcall(function() hum.WalkSpeed = S.ws end)
    end
  end
  if S.lockJP and hum then
    if math.abs(hum.JumpPower - S.jp) > 0.5 then
      pcall(function()
        hum.JumpPower = S.jp
        hum.JumpHeight = S.jp / 7.2
      end)
    end
  end
end))

bind(UIS.JumpRequest:Connect(function()
  if S.infJump then
    local hum = humOf(LP)
    if hum then pcall(function() hum:ChangeState(Enum.HumanoidStateType.Jumping) end) end
  end
end))

-- Ctrl+Click teleport
bind(UIS.InputBegan:Connect(function(inp, gpe)
  if gpe or not S.clickTP then return end
  if inp.UserInputType == Enum.UserInputType.MouseButton1 then
    local ctrl = UIS:IsKeyDown(Enum.KeyCode.LeftControl) or UIS:IsKeyDown(Enum.KeyCode.RightControl)
    if ctrl and Mouse and Mouse.Hit then
      local hrp = hrpOf(LP)
      if hrp then
        hrp.CFrame = Mouse.Hit + Vector3.new(0, 3, 0)
        Notify("Teleport", "Clicked point", "ok")
      end
    end
  end
end))

local savedPos = nil

local function teleportTo(pos, yawKeep)
  local hrp = hrpOf(LP)
  if not hrp then Notify("Teleport", "No character", "error") return end
  local _, oy, _ = hrp.CFrame:ToOrientation()
  local cf = CFrame.new(pos + Vector3.new(0, 3, 0))
  if yawKeep then cf = CFrame.new(pos + Vector3.new(0, 3, 0)) * CFrame.Angles(0, oy, 0) end
  hrp.CFrame = cf
  hrp.AssemblyLinearVelocity = Vector3.zero
end

local function teleportToPlayer(plr)
  if not plr or not plr.Character then Notify("Teleport", "No target", "error") return end
  local t = plr.Character:FindFirstChild("HumanoidRootPart")
  local me = hrpOf(LP)
  if not t or not me then Notify("Teleport", "No HRP", "error") return end
  me.CFrame = t.CFrame + Vector3.new(0, 1, 3)
  me.AssemblyLinearVelocity = Vector3.zero
  Notify("Teleport", "→ " .. plr.DisplayName, "ok")
end

--// World / misc ----------------------------------------------------------
local origLight = {}
do
  pcall(function()
    origLight.Brightness = Lighting.Brightness
    origLight.ClockTime = Lighting.ClockTime
    origLight.FogEnd = Lighting.FogEnd
    origLight.GlobalShadows = Lighting.GlobalShadows
    origLight.Ambient = Lighting.Ambient
  end)
end

local function setFullbright(v)
  S.fullbright = v == true
  if S.fullbright then
    pcall(function()
      Lighting.Brightness = 2
      Lighting.ClockTime = 14
      Lighting.FogEnd = 100000
      Lighting.GlobalShadows = false
      Lighting.Ambient = Color3.fromRGB(160, 160, 160)
    end)
  else
    pcall(function()
      if origLight.Brightness ~= nil then Lighting.Brightness = origLight.Brightness end
      if origLight.ClockTime ~= nil then Lighting.ClockTime = origLight.ClockTime end
      if origLight.FogEnd ~= nil then Lighting.FogEnd = origLight.FogEnd end
      if origLight.GlobalShadows ~= nil then Lighting.GlobalShadows = origLight.GlobalShadows end
      if origLight.Ambient ~= nil then Lighting.Ambient = origLight.Ambient end
    end)
  end
end

bind(Lighting:GetPropertyChangedSignal("ClockTime"):Connect(function()
  if S.fullbright then Lighting.ClockTime = 14 end
end))

if S.antiAFK == nil then S.antiAFK = false end
local antiConn = nil
local function setAntiAFK(v)
  S.antiAFK = v == true
  if antiConn then pcall(function() antiConn:Disconnect() end) antiConn = nil end
  if S.antiAFK then
    antiConn = LP.Idled:Connect(function()
      pcall(function()
        local vu = game:GetService("VirtualUser")
        vu:CaptureController()
        vu:ClickButton2(Vector2.new())
      end)
    end)
    table.insert(CONNS, antiConn)
  end
end

local function fpsBoost()
  pcall(function()
    Lighting.GlobalShadows = false
    Lighting.FogEnd = 100000
    for _, v in ipairs(Lighting:GetChildren()) do
      if v:IsA("PostEffect") or v:IsA("BloomEffect") or v:IsA("BlurEffect")
        or v:IsA("SunRaysEffect") or v:IsA("ColorCorrectionEffect") then
        v.Enabled = false
      end
    end
    for _, d in ipairs(workspace:GetDescendants()) do
      if d:IsA("ParticleEmitter") or d:IsA("Trail") or d:IsA("Smoke") or d:IsA("Fire") then
        d.Enabled = false
      elseif d:IsA("MeshPart") or d:IsA("Part") then
        -- keep collisions, just cheapen visuals
      end
    end
  end)
  Notify("Misc", "GFX lowered (particles/effects off)", "ok")
end

--== UNIVERSAL TAB UI ======================================================
-- NOTE: sections double as "spoilers": collapsed ones hide advanced tuning.

-- Team / target selection (spoiler with auto-scan)
local teamSec = uniTab:Section({ Name = "ESP — Targets" })
teamSec:Paragraph("Auto-scan looks in: Teams, player attributes, leaderstats and character values. Pick who counts as FRIEND — everyone else follows the rule below.")
local friendDD, enemyDD, teamInfo
friendDD = teamSec:MultiDropdown({
  Name = "Friends", Options = { "—" }, Default = {},
  Tooltip = "Keys treated as teammates",
  Callback = function(v)
    table.clear(FriendSet)
    if type(v) == "table" then for _, k in ipairs(v) do FriendSet[tostring(k)] = true end end
  end,
})
enemyDD = teamSec:MultiDropdown({
  Name = "Enemies", Options = { "—" }, Default = {},
  Tooltip = "Keys treated as enemies (priority after Friends)",
  Callback = function(v)
    table.clear(EnemySet)
    if type(v) == "table" then for _, k in ipairs(v) do EnemySet[tostring(k)] = true end end
  end,
})
teamInfo = teamSec:Label("scan…")
teamSec:Toggle({
  Name = "Unknown = enemy", Desc = "Anyone not listed counts as enemy",
  Default = true, Tooltip = "Off = everyone unknown counts as friend",
  Callback = function(v) S.unknownIsEnemy = v == true end,
})
teamSec:Toggle({
  Name = "Respect Roblox teams", Desc = "Same Player.Team = friend",
  Default = false, Tooltip = "Uses the built-in Team property when present",
  Callback = function(v) S.useTeamColor = v == true end,
})
teamSec:Button({ Name = "Rescan teams", Callback = function()
  local list, counts = scanTeamKeys()
  if #list == 0 then list = { "NoTeam" } counts = { NoTeam = 0 } end
  friendDD.SetOptions(list, true)
  enemyDD.SetOptions(list, true)
  local lines = {}
  for _, k in ipairs(list) do
    table.insert(lines, k .. " ×" .. tostring(counts[k] or 0))
  end
  teamInfo.Set("Found: " .. table.concat(lines, "  ·  "))
  Nova.Flags._teams = list
end })

-- ESP render
local rendSec = uniTab:Section({ Name = "ESP — Render" })
rendSec:Toggle({ Name = "ESP enabled", Desc = "Master switch for boxes/text",
  Default = false, Callback = function(v)
    S.espOn = v == true
    if not S.espOn then
      for _, e in pairs(espCache) do hideESP(e) end
      for _, p in ipairs(Players:GetPlayers()) do clearBillboard(p) end
    end
  end })
if not HAS_DRAWING then
  rendSec:Paragraph("⚠ Drawing API not found in this executor — boxes/tracers are off, names work via billboards. Glow still works.")
end
rendSec:Dropdown({ Name = "Box style", Options = { "Corner", "Full", "3D" }, Default = "Corner",
  Tooltip = "Corner = cheater classic, Full = rect, 3D = offset depth",
  Callback = function(v) S.boxStyle = tostring(v) end })
rendSec:Slider({ Name = "Line thickness", Min = 1, Max = 5, Default = 2,
  Tooltip = "Boxes, corners and tracers",
  Callback = function(v) S.thickness = tonumber(v) or 2 end })
rendSec:Slider({ Name = "Max distance", Min = 100, Max = 10000, Default = 2500, Suffix = " st",
  Callback = function(v) S.maxDist = tonumber(v) or 2500 end })
rendSec:Toggle({ Name = "Show friends", Default = true, Callback = function(v) S.showFriends = v == true end })
rendSec:Toggle({ Name = "Show enemies", Default = true, Callback = function(v) S.showEnemies = v == true end })
rendSec:Toggle({ Name = "Hide behind wall", Desc = "Don't draw occluded at all",
  Default = false, Tooltip = "Off = occluded targets use the 'hidden' colors",
  Callback = function(v) S.hideWalled = v == true end })

-- ESP info
local infoSec = uniTab:Section({ Name = "ESP — Info" })
infoSec:Toggle({ Name = "Names", Default = true, Callback = function(v) S.names = v == true end })
infoSec:Toggle({ Name = "Health bar + number", Default = true, Callback = function(v) S.health = v == true end })
infoSec:Toggle({ Name = "Distance", Default = true, Callback = function(v) S.distance = v == true end })
infoSec:Toggle({ Name = "Equipment (tool)", Desc = "Equipped or first backpack tool",
  Default = false, Callback = function(v) S.tool = v == true end })
infoSec:Toggle({ Name = "Tracers (lines to targets)", Default = false,
  Callback = function(v) S.tracer = v == true end })
infoSec:Dropdown({ Name = "Tracer from", Options = { "Bottom", "Center", "Top", "Mouse" }, Default = "Bottom",
  Callback = function(v) S.tracerFrom = tostring(v) end })
infoSec:Toggle({ Name = "Mark nearest", Desc = "Recolors closest target to cursor",
  Default = false, Callback = function(v) S.nearest = v == true end })
infoSec:Toggle({ Name = "Nearest counts only enemies", Default = true,
  Callback = function(v) S.nearestOnlyEnemies = v == true end })

-- ESP colors
local colSec = uniTab:Section({ Name = "ESP — Colors" })
colSec:Color({ Name = "Friend", Default = S.friendCol, Callback = function(v) S.friendCol = v end })
colSec:Color({ Name = "Enemy", Default = S.enemyCol, Callback = function(v) S.enemyCol = v end })
colSec:Color({ Name = "Friend behind wall", Default = S.friendHid,
  Tooltip = "Used when the visibility raycast hits something",
  Callback = function(v) S.friendHid = v end })
colSec:Color({ Name = "Enemy behind wall", Default = S.enemyHid,
  Callback = function(v) S.enemyHid = v end })
colSec:Color({ Name = "Nearest mark", Default = S.nearestCol, Callback = function(v) S.nearestCol = v end })

-- Glow
local glowSec = uniTab:Section({ Name = "Glow / Chams", Collapsed = true })
glowSec:Paragraph("Highlight-based model glow (works without Drawing). Per-player Highlight, colors follow friend/enemy.")
glowSec:Toggle({ Name = "Glow enabled", Default = false,
  Callback = function(v)
    S.glowOn = v == true
    if not CAN_HIGHLIGHT and S.glowOn then
      Notify("Glow", "Highlight not supported here", "warn")
    end
  end })
glowSec:Slider({ Name = "Fill transparency", Min = 0, Max = 1, Default = 0.45, Decimals = 2,
  Callback = function(v) S.glowFill = tonumber(v) or 0.45 end })
glowSec:Slider({ Name = "Outline transparency", Min = 0, Max = 1, Default = 0.15, Decimals = 2,
  Callback = function(v) S.glowOutline = tonumber(v) or 0.15 end })
glowSec:Toggle({ Name = "Visible through walls", Default = true,
  Callback = function(v) S.glowTop = v == true end })
glowSec:Toggle({ Name = "Glow friends", Default = true, Callback = function(v) S.glowFriends = v == true end })
glowSec:Toggle({ Name = "Glow enemies", Default = true, Callback = function(v) S.glowEnemies = v == true end })

-- Movement: fly
local flySec = uniTab:Section({ Name = "Move — Fly" })
local flyToggle
flyToggle = flySec:Toggle({ Name = "Fly", Desc = "WASD + Space up / Shift down",
  Default = false, Callback = function(v) setFlying(v) end })
flySec:Slider({ Name = "Fly speed", Min = 10, Max = 300, Default = 80, Suffix = " st/s",
  Callback = function(v) S.flySpeed = tonumber(v) or 80 end })
flySec:Dropdown({ Name = "Fly mode", Options = { "CFrame", "Velocity" }, Default = "CFrame",
  Tooltip = "CFrame = stable hover, Velocity = physics push",
  Callback = function(v) S.flyMode = tostring(v) end })
flySec:Toggle({ Name = "Noclip while flying", Default = true,
  Callback = function(v) S.flyNoclip = v == true end })
flySec:Keybind({ Name = "Fly key", Default = Enum.KeyCode.F,
  Tooltip = "Toggles fly",
  Callback = function() end }):OnPress(function()
    if flyToggle then flyToggle.Set(not S.fly) end
  end)

-- Movement: physics
local physSec = uniTab:Section({ Name = "Move — Physics" })
local noclipToggle
noclipToggle = physSec:Toggle({ Name = "Noclip", Desc = "Walk through walls",
  Default = false, Callback = function(v) S.noclip = v == true end })
physSec:Keybind({ Name = "Noclip key", Default = Enum.KeyCode.N }):OnPress(function()
  if noclipToggle then noclipToggle.Set(not S.noclip) end
  Notify("Move", "Noclip " .. (S.noclip and "ON" or "OFF"), "info")
end)
local wsSlider = physSec:Slider({ Name = "WalkSpeed", Min = 16, Max = 300, Default = 16,
  Callback = function(v)
    S.ws = tonumber(v) or 16
    if not S.lockWS then
      local hum = humOf(LP)
      if hum then pcall(function() hum.WalkSpeed = S.ws end) end
    end
  end })
physSec:Toggle({ Name = "Lock WalkSpeed", Desc = "Re-apply on resets",
  Default = false, Callback = function(v) S.lockWS = v == true end })
local jpSlider = physSec:Slider({ Name = "JumpPower", Min = 50, Max = 400, Default = 50,
  Callback = function(v)
    S.jp = tonumber(v) or 50
    if not S.lockJP then
      local hum = humOf(LP)
      if hum then pcall(function() hum.JumpPower = S.jp end) end
    end
  end })
physSec:Toggle({ Name = "Lock JumpPower", Default = false, Callback = function(v) S.lockJP = v == true end })
physSec:Toggle({ Name = "Infinite jump", Default = false, Callback = function(v) S.infJump = v == true end })
physSec:Toggle({ Name = "Ctrl+Click teleport", Desc = "Hold Ctrl and click the world",
  Default = false, Callback = function(v) S.clickTP = v == true end })

-- Teleport
local tpSec = uniTab:Section({ Name = "Teleport", Collapsed = true })
local tpList, tpMap = { "—" }, {}
local tpDD
tpDD = tpSec:Dropdown({ Name = "Player", Options = tpList, Default = tpList[1],
  Callback = function() end })
tpSec:Button({ Name = "Refresh players", Variant = "ghost", Callback = function()
  tpList, tpMap = {}, {}
  for _, p in ipairs(Players:GetPlayers()) do
    if p ~= LP then
      table.insert(tpList, p.DisplayName .. " (@" .. p.Name .. ")")
      tpMap[p.DisplayName .. " (@" .. p.Name .. ")"] = p
    end
  end
  if #tpList == 0 then tpList = { "—" } end
  tpDD.SetOptions(tpList, true)
end })
tpSec:Button({ Name = "Teleport to player", Callback = function()
  local sel = tpDD.Get()
  local target = tpMap[tostring(sel)]
  if target then teleportToPlayer(target) else Notify("Teleport", "Pick a player first", "warn") end
end })
tpSec:Divider()
local cxBox = tpSec:TextBox({ Name = "X", Placeholder = "0", Default = "" })
local cyBox = tpSec:TextBox({ Name = "Y", Placeholder = "10", Default = "" })
local czBox = tpSec:TextBox({ Name = "Z", Placeholder = "0", Default = "" })
tpSec:Button({ Name = "Teleport to coords", Callback = function()
  local x, y, z = tonumber(cxBox.Get()), tonumber(cyBox.Get()), tonumber(czBox.Get())
  if x and y and z then teleportTo(Vector3.new(x, y, z), true)
  else Notify("Teleport", "Bad coords", "error") end
end })
tpSec:Button({ Name = "Save position", Variant = "ghost", Callback = function()
  local hrp = hrpOf(LP)
  if hrp then savedPos = hrp.Position; Notify("Teleport", "Saved", "ok") end
end })
tpSec:Button({ Name = "Back to saved", Variant = "ghost", Callback = function()
  if savedPos then teleportTo(savedPos, true) else Notify("Teleport", "Nothing saved", "warn") end
end })

-- World / misc
local miscSec = uniTab:Section({ Name = "World / Misc", Collapsed = true })
miscSec:Toggle({ Name = "Fullbright", Desc = "Day light everywhere",
  Default = false, Callback = function(v) setFullbright(v) end })
miscSec:Toggle({ Name = "Anti-AFK", Default = false, Callback = function(v) setAntiAFK(v) end })
miscSec:Button({ Name = "FPS boost (kill effects)", Variant = "ghost", Callback = fpsBoost })
miscSec:Divider()
local srvInfo = miscSec:Label(placeLabel)
local fpsLabel = miscSec:Label("fps — · ping —")
miscSec:Button({ Name = "Copy PlaceId", Variant = "ghost", Callback = function()
  pcall(function() setclipboard(tostring(game.PlaceId)) end)
  Notify("Misc", "PlaceId: " .. tostring(game.PlaceId), "info")
end })
miscSec:Button({ Name = "Rejoin server", Variant = "ghost", Callback = function()
  pcall(function() Teleport:Teleport(game.PlaceId, LP) end)
end })
miscSec:Button({ Name = "Server hop", Variant = "ghost", Callback = function()
  task.spawn(function()
    local ok, res = pcall(game.HttpGet, game,
      ("https://games.roblox.com/v1/games/%d/servers/Public?limit=100"):format(game.PlaceId))
    if not ok or not res then Notify("Misc", "Hop failed", "error") return end
    local data = nil
    pcall(function() data = game:GetService("HttpService"):JSONDecode(res) end)
    if not (data and data.data) then Notify("Misc", "Hop failed", "error") return end
    for _, s in ipairs(data.data) do
      if s.id ~= game.JobId and (s.playing or 0) < (s.maxPlayers or 10) then
        pcall(function() Teleport:TeleportToPlaceInstance(game.PlaceId, s.id, LP) end)
        return
      end
    end
    Notify("Misc", "No server found", "warn")
  end)
end })

-- Overlay: ping/FPS corner chip (stays while the window is hidden)
local ovSec = uniTab:Section({ Name = "Overlay" })
ovSec:Paragraph("Corner chip with live stats. Stays on screen while the main window is hidden (RightShift). Drag the chip anywhere.")
ovSec:Toggle({ Name = "Stats overlay", Desc = "Show the corner chip",
  Default = true, Callback = function(v) hudVisible = v == true; hudApplyVisible() end })
ovSec:MultiDropdown({ Name = "Content", Options = { "Ping", "FPS", "Players", "Flags" },
  Default = { "Ping", "FPS" }, Tooltip = "Flags = FLY / NC indicators when active",
  Callback = function(v)
    local order, set, out = { "Ping", "FPS", "Players", "Flags" }, {}, {}
    if type(v) == "table" then for _, x in ipairs(v) do set[tostring(x)] = true end end
    for _, k in ipairs(order) do if set[k] then table.insert(out, k) end end
    hudContent = out
    hudSet("hub", hudStatsLine())
  end })
ovSec:Toggle({ Name = "Module lines", Desc = "Bingo status etc. under the stats",
  Default = true, Callback = function(v) hudModules = v == true; hudRefresh() end })
ovSec:Dropdown({ Name = "Corner", Options = { "TopLeft", "TopRight", "BottomLeft", "BottomRight" },
  Default = "TopLeft", Tooltip = "Preset position (dragging overrides it)",
  Callback = function(v) hudCorner = tostring(v); hudPlace() end })
ovSec:Slider({ Name = "Text size", Min = 10, Max = 20, Default = 12,
  Callback = function(v) hudTextSize = tonumber(v) or 12; hudApplyStyle() end })
ovSec:Slider({ Name = "Background", Min = 0, Max = 90, Default = 18, Suffix = "%",
  Tooltip = "Card transparency (90 = almost invisible)",
  Callback = function(v) hudBgT = (tonumber(v) or 18) / 100; hudApplyStyle() end })
ovSec:Slider({ Name = "Update rate", Min = 0.25, Max = 2, Default = 0.5, Decimals = 2, Suffix = "s",
  Callback = function(v) hudRate = tonumber(v) or 0.5 end })

--== PLACE TAB (auto-loader) =================================================
local Shared = {
  Nova = Nova, Win = win, S = S,
  Players = Players, LP = LP,
  teamKey = teamKey, scanTeamKeys = scanTeamKeys, isFriend = isFriend,
  isOccluded = isOccluded, hrpOf = hrpOf, headOf = headOf, humOf = humOf,
  toolName = toolName, distanceTo = distanceTo,
  teleportTo = teleportTo, teleportToPlayer = teleportToPlayer,
  notify = Notify, registerConn = bind,
  SetHud = hudSet, -- Shared.SetHud("bingo", text): line on the mini HUD chip
}
if getgenv then pcall(function() getgenv().HumaAPI = Shared end) end
_G.HumaAPI = Shared

local loadSec = placeTab:Section({ Name = "Place module" })
local placeStatus = loadSec:Label("looking for a module for this place…")
loadSec:Paragraph("Order: exact PlaceMap entry → places/<PlaceId>.lua → games/<GameName>.lua in your NovaGUI repo. Universal tab always works, this one adds place-specific scripts.")
local urlBox = loadSec:TextBox({ Name = "Manual URL", Placeholder = "https://…/myplace.lua", Default = "" })
loadSec:Button({ Name = "Load from URL", Callback = function()
  local u = urlBox.Get()
  if u == nil or u == "" then Notify("Place", "Paste a URL first", "warn") return end
  tryLoadPlaceUrl(tostring(u), placeTab, placeStatus)
end })
loadSec:Button({ Name = "Retry auto-detect", Variant = "ghost", Callback = function()
  autoLoadPlace(placeTab, placeStatus)
end })

function tryLoadPlaceUrl(url, tab, status)
  status.Set("loading: " .. tostring(url))
  task.spawn(function()
    local ok, src = pcall(game.HttpGet, game, url)
    if not ok or type(src) ~= "string" or #src < 50 then
      status.Set("not found: " .. tostring(url))
      return false
    end
    local fn, err = loadstring(src)
    if not fn then
      status.Set("compile error: " .. tostring(err))
      Notify("Place", "Compile error", "error")
      return false
    end
    local api = { Nova = Nova, Win = win, Tab = tab, Shared = Shared, Notify = Notify }
    local okRun, ret = pcall(fn)
    if not okRun then
      status.Set("runtime error: " .. tostring(ret))
      Notify("Place", "Runtime error (F9 console)", "error")
      return false
    end
    if type(ret) == "function" then
      local ok2, err2 = pcall(ret, api)
      if not ok2 then
        status.Set("module error: " .. tostring(err2))
        return false
      end
    end
    status.Set("loaded: " .. tostring(url))
    Notify("Place", "Place module loaded", "ok")
    return true
  end)
end

function autoLoadPlace(tab, status)
  task.spawn(function()
    -- 1) exact map
    local exact = HumaHub.PlaceMap[game.PlaceId]
    if exact and exact ~= "" then
      local ok, src = pcall(game.HttpGet, game, tostring(exact))
      if ok and type(src) == "string" and #src > 50 then
        tryLoadPlaceUrl(tostring(exact), tab, status)
        return
      end
    end
    -- 2) convention by PlaceId
    local byId = PLACE_BASE .. tostring(game.PlaceId) .. ".lua"
    do
      local ok, src = pcall(game.HttpGet, game, byId)
      if ok and type(src) == "string" and #src > 50 then
        tryLoadPlaceUrl(byId, tab, status)
        return
      end
    end
    -- 3) convention by game name
    local clean = tostring(game.Name):gsub("%W", "")
    if clean == "" then clean = "game" end
    local byName = GAME_BASE .. clean .. ".lua"
    do
      local ok, src = pcall(game.HttpGet, game, byName)
      if ok and type(src) == "string" and #src > 50 then
        tryLoadPlaceUrl(byName, tab, status)
        return
      end
    end
    status.Set("no module yet (" .. placeLabel .. ") — universal still works. Publish client/places/"
      .. tostring(game.PlaceId) .. ".lua to enable it.")
  end)
end

--== SETTINGS TAB ============================================================
local uiSec = setTab:Section({ Name = "Interface" })
uiSec:Dropdown({ Name = "Theme", Options = { "Dark", "Midnight", "Mono", "Light" }, Default = "Dark",
  Callback = function(v) Nova:SetTheme(tostring(v)) end })
uiSec:Slider({ Name = "UI scale", Min = 0.7, Max = 1.3, Default = 1, Decimals = 2,
  Callback = function(v) win:SetScale(tonumber(v) or 1) end })
uiSec:Paragraph("RightShift toggles the window. Theme button (top-right) cycles themes.")
local cfgSec = setTab:Section({ Name = "Config" })
cfgSec:TextBox({ Name = "Config name", Placeholder = "default", Default = "default", Flag = "huma_cfg" })
cfgSec:Button({ Name = "Save config", Callback = function()
  Nova:Save(Nova.Flags.huma_cfg ~= "" and Nova.Flags.huma_cfg or "default")
end })
cfgSec:Button({ Name = "Load config", Variant = "ghost", Callback = function()
  Nova:Load(Nova.Flags.huma_cfg ~= "" and Nova.Flags.huma_cfg or "default")
end })
local aboutSec = setTab:Section({ Name = "About" })
aboutSec:Label("HUMA HUB · universal + per-place modules")
aboutSec:Paragraph("Universal works everywhere (ESP, glow, fly, teleport, misc). Place tab pulls a script for the current PlaceId from your NovaGUI repo when it exists.")
aboutSec:Button({ Name = "Unload HUB", Variant = "danger", Callback = function()
  HumaHub.Unload() -- full cleanup lives in OnUnload (loops, ESP, glow, bingo)
end })

--== Loops / events ----------------------------------------------------------
bind(RunSvc.RenderStepped:Connect(function()
  local ok, err = pcall(updateESP)
  if not ok then
    -- never let ESP kill the render loop; throttle errors
  end
  glowTick = glowTick + 1
  if glowTick % 12 == 0 then
    pcall(updateGlow)
  end
end))

bind(Players.PlayerRemoving:Connect(function(plr)
  freeESP(plr)
end))

-- fps/ping readout, HUD chip + misc labels on hudRate
task.spawn(function()
  local ema = 60
  local last = tick()
  local hudAcc = 99 -- first tick updates immediately
  while task.wait(0.25) do
    local now = tick()
    local inst = 1 / math.max(now - last, 1e-4)
    last = now
    ema = ema * 0.9 + inst * 0.1
    hudAcc = hudAcc + 0.25
    if hudAcc >= hudRate then
      hudAcc = 0
      local ping = "—"
      pcall(function()
        local item = Stats.Network.ServerStatsItem["Data Ping"]
        ping = tostring(math.floor(item:GetValue() + 0.5)) .. "ms"
      end)
      lastFps, lastPing, lastPlayers = math.floor(ema + 0.5), ping, #Players:GetPlayers()
      pcall(function()
        fpsLabel.Set(("fps %d · ping %s · %d players"):format(lastFps, lastPing, lastPlayers))
        srvInfo.Set(game.Name .. " · " .. placeLabel .. " · Job " .. tostring(game.JobId):sub(1, 8) .. "…")
        hudSet("hub", hudStatsLine())
      end)
    end
    if not win then break end
    if HumaHubUnloaded then break end
  end
end)

-- initial team scan (fills the spoiler dropdowns)
task.defer(function()
  local list, counts = scanTeamKeys()
  if #list == 0 then list = { "NoTeam" } counts = { NoTeam = 0 } end
  pcall(function()
    friendDD.SetOptions(list, true)
    enemyDD.SetOptions(list, true)
    local lines = {}
    for _, k in ipairs(list) do
      table.insert(lines, k .. " ×" .. tostring(counts[k] or 0))
    end
    teamInfo.Set("Found: " .. table.concat(lines, "  ·  "))
  end)
  autoLoadPlace(placeTab, placeStatus)
end)

Notify("HUMA HUB", "Universal loaded · looking for place module…", "ok")
print("[HumaHub] universal ready @ " .. tostring(game.PlaceId))

HumaHub.Win = win
HumaHub.Nova = Nova
HumaHub.Shared = Shared

-- Full unload entry: X button (win:Unload → OnUnload above) and the next
-- inject (single-instance guard at the top) both end up here.
local hubDead = false
HumaHub.Unload = function()
  if hubDead then return end
  hubDead = true
  pcall(function() win:Unload() end)
end
if getgenv then pcall(function() getgenv().__HUMA_HUB = HumaHub end) end
return HumaHub
