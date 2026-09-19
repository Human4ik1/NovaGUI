--[[
  HumaHub place module — Cold War (PlaceId 13687899540, UniverseId 4750561026).
  Repo path: client/places/13687899540.lua
  Universe redirect: client/universes/4750561026.lua (every map funnels here).

  Converted from ColdWar.lua (standalone, own menu) to hub format:
    - the full engine is kept 1:1 (teams, ESP, glow, aimbot, fire packets,
      kill-all, radar, crosshair, movement, teleports, vehicles, binds);
    - the custom menu is replaced by Nova controls in Delta layout:
      Navigation → Pages (ESP/Aim/Teleport/World/Safety/About) → SubTabs;
    - keybind bars live inside their feature sections (Aim/Fire/Move/Kill);
    - persistence now rides Nova:Save/Load (Flag = engine key), the JSON
      file is gone; kill-list/markers stay session-only.

  Notes for this place:
    - Teams: Neutral / NATO / PACT (Player.Team + attributes).
    - R6 rig, 1hp gameplay. Aim parts: head / neck(Torso) / body(HRP).
    - Capture points: Workspace.Match.Objectives (Trigger 1..3).
    - Fire packets go to ReplicatedStorage.BallisticsNet.Fire (autofire/rage).
    - The game locks the mouse (LockCenter): press ALT to free it for the
      hub window, RightShift toggles the hub.
]]

return function(api)
  local Tab, Notify = api.Tab, api.Notify

  local runService = game:GetService("RunService")
  local players = game:GetService("Players")
  local workspace = game:GetService("Workspace")
  local lighting = game:GetService("Lighting")
  local userInput = game:GetService("UserInputService")
  local camera = workspace.CurrentCamera
  local raycastParams = RaycastParams.new()

  --// reload safety: unload a previous copy of this module ----------------
  do
    local g = getgenv and getgenv()
    local prev = g and (g.__HUMA_PLACE or g.__HUMA_COLDWAR)
    if prev and type(prev.Unload) == "function" then pcall(prev.Unload) end
  end

  local M = {}
  M.version = "hub-2"
  M.flags = {}
  M.errors = {}
  M.markers = {}
  M.killAllChecked = M.killAllChecked or {}
  M.uiState = { open = false, mouseFree = false }
  M.binds = { prev = {}, last = {}, tog = {}, hold = {} }

  local CONNS = {}
  local function regConn(c) table.insert(CONNS, c) return c end

  -- --------------------------------------------------------------------------
  -- Utilities
  -- --------------------------------------------------------------------------
  local function clamp(v, mn, mx) return math.max(mn, math.min(mx, v)) end
  local function round(v, d) d = 10 ^ (d or 0) return math.floor(v * d + 0.5) / d end
  local function getLocal() return players.LocalPlayer end
  local function getChar() local p = getLocal() return p and p.Character end
  local function recordError(tag, err)
    M.errors[#M.errors + 1] = tag .. ": " .. tostring(err)
    if #M.errors > 40 then table.remove(M.errors, 1) end
  end

  local keyCache = {}
  local function keyOf(name)
    if not name or name == "" or name == "none" then return nil end
    local k = keyCache[name]
    if k == nil then
      local ok, kc = pcall(function() return Enum.KeyCode[name] end)
      k = ok and kc or false
      keyCache[name] = k
    end
    if k == false then return nil end
    return k
  end
  local function notify(msg)
    pcall(function() Notify("Cold War", tostring(msg), "info") end)
  end

  -- --------------------------------------------------------------------------
  -- Drawing shapes with per-frame recycle
  -- --------------------------------------------------------------------------
  local frameShapes, prevShapes = {}, {}
  local function shape(typ)
    local ok, s = pcall(Drawing.new, typ)
    if not ok then
      local stub = setmetatable({}, {
        __index = function() return stub end,
        __newindex = function() end,
        __call = function() return stub end,
      })
      return stub
    end
    frameShapes[#frameShapes + 1] = s
    s.Visible = true
    return s
  end

  local function frameBegin()
    for _, s in ipairs(prevShapes) do pcall(function() s:Remove() end) end
    prevShapes = frameShapes
    frameShapes = {}
  end

  -- --------------------------------------------------------------------------
  -- World -> screen
  -- --------------------------------------------------------------------------
  local function wts(pos)
    local v = camera:WorldToViewportPoint(pos)
    return Vector2.new(v.X, v.Y), v.Z > 0, v.Z
  end

  -- --------------------------------------------------------------------------
  -- Classification
  -- --------------------------------------------------------------------------
  local function isValidTarget(instance)
    return instance ~= nil and instance.Parent ~= nil
      and instance:FindFirstChildOfClass("Humanoid") ~= nil
      and instance:FindFirstChild("HumanoidRootPart") ~= nil
      and instance.Humanoid.Health > 0
  end

  local function nx(val)
    if val == nil then return nil end
    if type(val) == "table" or type(val) == "userdata" then
      return tostring(val.Value ~= nil and val.Value or val.Name or val)
    end
    return tostring(val)
  end

  local function readAttr(inst, names)
    if not inst then return nil end
    for _, name in ipairs(names) do
      local ok, v = pcall(function() return inst:GetAttribute(name) end)
      if ok and v ~= nil and v ~= "" then return nx(v) end
    end
    return nil
  end

  local function primaryTeam(pl)
    if not pl then return "Neutral" end
    local t = readAttr(pl, { "Team", "team", "Takim", "TeamName" })
    if not t and pl.Character then
      t = readAttr(pl.Character, { "Team", "team" })
    end
    if not t then
      local ok, tm = pcall(function() return pl.Team and pl.Team.Name end)
      if ok and tm then t = nx(tm) end
    end
    if not t then
      local ok, f = pcall(function() return pl:FindFirstChild("Team") end)
      if ok and f then
        local okV, v = pcall(function() return f.Value end)
        t = okV and tostring(v) or tostring(f.Name)
      end
    end
    return t or "Neutral"
  end

  local function hasFriendlyMarker(ch)
    if not ch then return false end
    local okA, isF = pcall(function()
      return (ch:GetAttribute("Friendly") == true or ch:GetAttribute("Ally") == true)
    end)
    if okA and isF then return true end
    local okD, desc = pcall(function() return ch:GetDescendants() end)
    if not okD then return false end
    for _, obj in ipairs(desc) do
      if obj:IsA("BasePart") and obj.Color then
        local c = obj.Color
        if c.B > 0.55 and c.R < 0.35 then
          local nm = string.lower(tostring(obj.Name or ""))
          if string.find(nm, "marker") or string.find(nm, "ally") or string.find(nm, "friendly")
            or string.find(nm, "indicator") or string.find(nm, "dot") or string.find(nm, "tag") then
            return true
          end
        end
      end
    end
    return false
  end

  local function teamOf(pl) return primaryTeam(pl) end

  local function hostility(pl)
    local me = getLocal()
    if not pl then return "neutral" end
    if pl == me then return "self" end
    local mt, tt = primaryTeam(me), primaryTeam(pl)
    if tt == "Neutral" then return "neutral" end
    if tt == mt then return "friendly" end
    if hasFriendlyMarker(pl.Character) then return "friendly" end
    return "enemy"
  end

  local function weaponName(ch)
    if not ch then return nil end
    local best
    for _, child in ipairs(ch:GetChildren()) do
      if child:IsA("Model") and child:FindFirstChild("Handle") then
        local name = child.Name:match("^(.*)Model$") or child.Name
        if not best or #name < #best then best = name end
      end
    end
    return best
  end

  local teamColors = {
    friendly = { R = 0, G = 0.59, B = 1 },
    enemy    = { R = 1, G = 0, B = 0 },
    neutral  = { R = 0.9, G = 0.85, B = 0.5 },
    self     = { R = 0.3, G = 0.7, B = 1 },
  }

  -- --------------------------------------------------------------------------
  -- Collection
  -- --------------------------------------------------------------------------
  local collected = {}

  local function collectTargets(maxDist)
    local me = getChar()
    collected = {}
    local meHrp = me and me:FindFirstChild("HumanoidRootPart")
    for _, pl in ipairs(players:GetPlayers()) do
      local ch = pl.Character
      if ch and ch ~= me and isValidTarget(ch) then
        local hrp = ch:FindFirstChild("HumanoidRootPart")
        local d = meHrp and hrp and (meHrp.Position - hrp.Position).Magnitude or 0
        if d <= maxDist then
          collected[#collected + 1] = {
            player = pl, character = ch, hrp = hrp,
            head = ch:FindFirstChild("Head") or hrp,
            humanoid = ch:FindFirstChildOfClass("Humanoid"),
            team = teamOf(pl), hos = hostility(pl), distance = d,
          }
        end
      end
    end
  end

  -- --------------------------------------------------------------------------
  -- ESP
  -- --------------------------------------------------------------------------
  local function renderESP(t)
    local cfg = M.flags
    local hrp, head = t.hrp, (t.head or t.hrp)
    local top2d, topOn = wts(head.Position + Vector3.new(0, 0.5, 0))
    local bot2d, botOn = wts(hrp.Position - Vector3.new(0, 2.2, 0))
    if not topOn and not botOn then return end

    local height = math.abs(bot2d.Y - top2d.Y)
    local width = height * 0.55
    local centerX = (top2d.X + bot2d.X) / 2
    local boxTop = math.min(top2d.Y, bot2d.Y)
    local boxLeft = centerX - width / 2
    local col = teamColors[t.hos] or teamColors.neutral
    local hp = t.humanoid.Health / t.humanoid.MaxHealth
    local hpCol = hp > 0.55 and teamColors.friendly or (hp > 0.25 and teamColors.neutral or teamColors.enemy)
    local thick = cfg.esp_thickness or 1

    if cfg.esp_box then
      local tl = shape("Line"); tl.Color = col; tl.Thickness = thick; tl.Transparency = 1
      local tr = shape("Line"); tr.Color = col; tr.Thickness = thick; tr.Transparency = 1
      local bl = shape("Line"); bl.Color = col; bl.Thickness = thick; bl.Transparency = 1
      local br = shape("Line"); br.Color = col; br.Thickness = thick; br.Transparency = 1
      tl.From = Vector2.new(boxLeft, boxTop); tl.To = Vector2.new(boxLeft + width, boxTop)
      tr.From = Vector2.new(boxLeft, boxTop); tr.To = Vector2.new(boxLeft, boxTop + height)
      bl.From = Vector2.new(boxLeft + width, boxTop); bl.To = Vector2.new(boxLeft + width, boxTop + height)
      br.From = Vector2.new(boxLeft, boxTop + height); br.To = Vector2.new(boxLeft + width, boxTop + height)
    end

    if cfg.esp_health and height > 20 then
      local bg = shape("Line")
      bg.Color = { R = 0, G = 0, B = 0 }; bg.Thickness = thick; bg.Transparency = 1
      bg.From = Vector2.new(boxLeft - 5, boxTop); bg.To = Vector2.new(boxLeft - 5, boxTop + height)
      local fg = shape("Line")
      fg.Color = hpCol; fg.Thickness = thick; fg.Transparency = 1
      fg.From = Vector2.new(boxLeft - 5, boxTop + height)
      fg.To = Vector2.new(boxLeft - 5, boxTop + height - math.max(width * hp, 0))
    end

    if cfg.esp_tracer then
      local tl = shape("Line")
      tl.Color = col; tl.Thickness = 1; tl.Transparency = 0.4
      local vs = camera.ViewportSize
      tl.From = Vector2.new(vs.X / 2, vs.Y); tl.To = Vector2.new(centerX, boxTop)
    end

    if cfg.esp_name or cfg.esp_distance then
      local txt = shape("Text")
      txt.Color = col; txt.Size = 13; txt.Center = true; txt.Outline = true; txt.Transparency = 1
      local parts = {}
      if cfg.esp_name then parts[#parts + 1] = t.player.Name end
      if cfg.esp_distance then parts[#parts + 1] = string.format("%.0fm", t.distance) end
      txt.Text = table.concat(parts, "  ")
      txt.Position = Vector2.new(centerX, boxTop - 16)
    end

    if cfg.esp_weapon then
      local w = weaponName(t.character)
      if w then
        local wtxt = shape("Text")
        wtxt.Color = { R = 1, G = 1, B = 1 }; wtxt.Size = 12; wtxt.Center = true; wtxt.Transparency = 1
        wtxt.Text = w
        wtxt.Position = Vector2.new(centerX, boxTop + height + 4)
      end
    end

    if cfg.esp_team and t.hos ~= "self" then
      local tt = shape("Text")
      tt.Color = col; tt.Size = 11; tt.Center = true; tt.Outline = true; tt.Transparency = 1
      tt.Text = t.team
      tt.Position = Vector2.new(centerX, boxTop - 30)
    end
  end

  -- --------------------------------------------------------------------------
  -- Glow (Highlight, client-only)
  -- --------------------------------------------------------------------------
  local glowTable = {}

  local function applyGlow(character, col, on)
    if not on then
      local prev = glowTable[character]
      if prev then
        pcall(function() prev:Destroy() end)
      end
      glowTable[character] = nil
      return
    end
    if glowTable[character] then
      local fill = Color3.new(col.R, col.G, col.B)
      if glowTable[character].FillColor ~= fill then
        glowTable[character].FillColor = fill
      end
      return
    end
    local ok, hl = pcall(function()
      local h = Instance.new("Highlight")
      h.Name = "EdgeFX"
      h.Adornee = character
      h.FillColor = Color3.new(col.R, col.G, col.B)
      h.FillTransparency = 0.1
      h.OutlineColor = Color3.fromRGB(255, 255, 255)
      h.OutlineTransparency = 0
      h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
      h.Parent = character
      return h
    end)
    glowTable[character] = ok and hl or nil
  end

  local function updateGlow()
    local cfg = M.flags
    if cfg.glow_on then
      local seen = {}
      for _, t in ipairs(collected) do
        if t.hos ~= "neutral" and (t.hos == "enemy" or (t.hos == "friendly" and cfg.glow_friends)) then
          applyGlow(t.character, teamColors[t.hos] or teamColors.enemy, true)
          seen[t.character] = true
        end
      end
      for ch in pairs(glowTable) do
        if not seen[ch] then applyGlow(ch, { R = 1, G = 1, B = 1 }, false) end
      end
    else
      for ch in pairs(glowTable) do applyGlow(ch, { R = 1, G = 1, B = 1 }, false) end
      for k in pairs(glowTable) do glowTable[k] = nil end
    end
  end

  -- --------------------------------------------------------------------------
  -- Aimbot (camera only)
  -- --------------------------------------------------------------------------
  local aimState = { active = false, current = nil }

  -- --------------------------------------------------------------------------
  -- Kill All
  -- --------------------------------------------------------------------------
  local killAll = { active = false, origin = nil, targets = {}, index = 1, timer = 0 }

  local function getAimPoint(t, part)
    local char = t.character
    local inst = (part == "head" and char:FindFirstChild("Head"))
      or (part == "neck" and (char:FindFirstChild("UpperTorso") or char:FindFirstChild("Torso")))
      or char:FindFirstChild("HumanoidRootPart")
    if inst and inst:IsA("BasePart") then
      local p = inst.Position
      if part == "head" then p = p + Vector3.new(0, -(M.flags.aim_head_off or 0.3), 0) end
      return p
    end
    return t.hrp.Position
  end

  local function isVisible(from, to, ignoreChar)
    if not M.flags.aim_visible_check and not M.flags.legit then return true end
    local ignore = {}
    local me = getChar()
    if me then ignore[#ignore + 1] = me end
    if ignoreChar then ignore[#ignore + 1] = ignoreChar end
    ignore[#ignore + 1] = camera
    local ok, ray = pcall(function()
      raycastParams.FilterDescendantsInstances = ignore
      raycastParams.FilterType = Enum.RaycastFilterType.Exclude
      return workspace:Raycast(from, (to - from).Unit * (to - from).Magnitude, raycastParams)
    end)
    if not ok then return true end
    return not ray
  end

  local function angleTo(pos)
    local f = camera.CFrame
    local dir = pos - f.Position
    local len = dir.Magnitude
    if len < 0.01 then return 0 end
    return math.acos(math.clamp(f.LookVector:Dot(dir / len), -1, 1))
  end

  local function pickTarget(cap)
    local cfg = M.flags
    local byDist = cfg.aim_priority == "distance"
    local best, bestScore = nil, byDist and math.huge or cap
    for _, t in ipairs(collected) do
      local allowed = t.hos == "enemy"
        or (not M.flags.legit and ((t.hos == "friendly" and cfg.aim_friends)
          or (t.hos == "neutral" and cfg.aim_all)))
      if allowed then
        local ap = getAimPoint(t, cfg.aim_part)
        if isVisible(camera.CFrame.Position, ap, t.character) then
          local ang = angleTo(ap)
          if ang < cap then
            local score = byDist and t.distance or ang
            if score < bestScore then bestScore = score best = t end
          end
        end
      end
    end
    return best
  end

  local function hubOpen()
    local ok, vis = pcall(function() return api.Win:IsVisible() end)
    return ok and vis or false
  end

  local function updateAim()
    local cfg = M.flags
    local me = getChar()
    if killAll.active then aimState.active = false return end
    if not cfg.aim_enabled or not me then aimState.active = false return end
    if hubOpen() and cfg.aim_pause_menu and not cfg.aim_rage then aimState.active = false return end
    local hrp = me:FindFirstChild("HumanoidRootPart")
    if not hrp then aimState.active = false return end
    local isRage = cfg.aim_rage
    local fovDeg = clamp(cfg.aim_fov or 20, 5, 90)
    local cap = isRage and math.pi or math.rad(cfg.aim_fov_circle and fovDeg or 60)

    local cur = aimState.current
    if cur then
      local ap = getAimPoint(cur, cfg.aim_part)
      local alive = cur.hrp and cur.hrp.Parent and cur.humanoid and cur.humanoid.Health > 0
      if not alive or not isVisible(camera.CFrame.Position, ap, cur.character) or angleTo(ap) >= cap then
        aimState.current = nil
      end
    end
    if not aimState.current then
      aimState.current = pickTarget(cap)
      aimState.since = os.clock()
    end

    if aimState.current then
      if (os.clock() - (aimState.since or 0)) < (cfg.aim_delay or 0) then
        aimState.active = false -- human reaction delay on new targets
      elseif isRage then
        aimState.active = true
      else
        local hold = cfg.aim_hold
        aimState.active = hold == "always"
          or (hold == "right" and userInput:IsMouseButtonPressed(Enum.UserInputType.MouseButton2))
          or (hold == "left" and userInput:IsMouseButtonPressed(Enum.UserInputType.MouseButton1))
      end
      if cfg.bind_aim_key and cfg.bind_aim_key ~= "none" and keyOf(cfg.bind_aim_key) then
        local gate = M.flags.bind_aim_mode == "hold" and M.binds.hold.aim or M.binds.tog.aim
        aimState.active = aimState.active and (gate or false)
      end
    else
      aimState.active = false
    end
  end

  -- --------------------------------------------------------------------------
  -- Weapon fire: genuine 30-byte BallisticsNet Fire packets
  -- --------------------------------------------------------------------------
  local lastFireTime = 0
  local warnedNoTool = false
  local fireRemote

  local function getFireRemote()
    if not fireRemote or not fireRemote.Parent then
      fireRemote = nil
      pcall(function()
        local bn = game:GetService("ReplicatedStorage"):FindFirstChild("BallisticsNet")
        if bn then fireRemote = bn:FindFirstChild("Fire") end
      end)
    end
    return fireRemote
  end

  local function encodeShot(origin, direction, seed)
    if type(buffer) ~= "table" or type(buffer.create) ~= "function" then return nil end
    local dir = direction.Unit
  local b = buffer.create(30)
  buffer.writeu8(b, 0, 17)
  buffer.writef32(b, 1, origin.X)
  buffer.writef32(b, 5, origin.Y)
  buffer.writef32(b, 9, origin.Z)
  -- fractional monotonic clock: integer-second os.time() stamps quantize
  -- sub-second bursts to dt=0 (inhuman) and fingerprint forged packets
  buffer.writef64(b, 13, tick())
    buffer.writeu8(b, 21, 1)
    buffer.writei16(b, 22, clamp(math.floor(dir.X * 32767 + 0.5), -32767, 32767))
    buffer.writei16(b, 24, clamp(math.floor(dir.Y * 32767 + 0.5), -32767, 32767))
    buffer.writeu32(b, 26, seed)
    return b
  end

  local function fireWeapon()
    local t = os.clock()
    local base = M.flags.aim_fire_rate or 15
    if M.flags.legit then base = math.min(base, 12) end
    local cd = 1 / math.max(base, 1)
    if (t - lastFireTime) < cd then return false end
    local ch = getChar()
    local tool = ch and ch:FindFirstChildWhichIsA("Tool")
    if not tool or tool.Name == "Ammo Crate" then
      if not warnedNoTool then
        warnedNoTool = true
        notify("Equip a firearm to auto-fire")
      end
      return false
    end
    local remote = getFireRemote()
    if not remote then return false end
    lastFireTime = t
    return pcall(function()
      remote:FireServer(encodeShot(camera.CFrame.Position, camera.CFrame.LookVector, math.random(0, 2147483647)))
    end)
  end

  local function applyAim()
    local cfg = M.flags
    if not aimState.active or not aimState.current then return end
    local ap = getAimPoint(aimState.current, cfg.aim_part)
    local desired = CFrame.lookAt(camera.CFrame.Position, ap)
    local alpha = clamp(1 - (cfg.aim_smooth / 101), 0.05, 0.99)
    camera.CFrame = camera.CFrame:Lerp(desired, alpha, true)
    if cfg.aim_rage or (cfg.aim_autofire and aimState.active) then
      fireWeapon()
    end
  end

  -- --------------------------------------------------------------------------
  -- Fast zoom (instant Camera.FieldOfView)
  -- --------------------------------------------------------------------------
  local defaultFOV
  local fovOverride = false

  local function aimFOV(active)
    local cfg = M.flags
    if active and cfg.aim_fastzoom then
      if not defaultFOV then defaultFOV = camera.FieldOfView or 70 end
      camera.FieldOfView = math.max(cfg.aim_zoom_fov or 25, 5)
      fovOverride = true
    elseif fovOverride then
      if defaultFOV then pcall(function() camera.FieldOfView = defaultFOV end) end
      fovOverride = false
    end
  end

  -- --------------------------------------------------------------------------
  -- Kill All
  -- --------------------------------------------------------------------------
  local function startKillAll()
    if M.flags.legit then notify("Blocked by Legit Mode") return end
    if killAll.active then return end
    local me = getChar()
    if not me then return end
    local hrp = me:FindFirstChild("HumanoidRootPart")
    if not hrp then return end
    killAll.origin = hrp.CFrame
    killAll.index = 1
    killAll.timer = 0
    killAll.active = true
  end

  local function stopKillAll()
    killAll.active = false
    if killAll.origin then
      local ch = getChar()
      if ch then
        local hrp = ch:FindFirstChild("HumanoidRootPart")
        if hrp then
          pcall(function()
            hrp.CFrame = killAll.origin
            pcall(function() hrp.Velocity = Vector3.new(0, 0, 0) end)
            pcall(function() hrp.AssemblyLinearVelocity = Vector3.new(0, 0, 0) end)
          end)
        end
      end
    end
    killAll.origin = nil
    killAll.targets = {}
    killAll.index = 1
  end

  local function stepKillAll(dt)
    if not killAll.active then return end
    killAll.timer = killAll.timer + dt
    local cfg = M.flags
    local delay = cfg.killall_delay or 0.08

    if #killAll.targets == 0 then
      local checked = M.killAllChecked or {}
      local list = {}
      for plName, v in pairs(checked) do
        if v then
          local pl = players:FindFirstChild(plName)
          if pl then
            local ch = pl.Character
            local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
            local hum = ch and ch:FindFirstChildOfClass("Humanoid")
            if hrp and hum and hum.Health > 0 then
              list[#list + 1] = { player = pl, character = ch, hrp = hrp, humanoid = hum }
            end
          end
        end
      end
      killAll.targets = list
      killAll.index = 1
      if #list == 0 then
        stopKillAll()
        return
      end
    end

    local t = killAll.targets[killAll.index]
    if not t then
      stopKillAll()
      return
    end

    local ch = getChar()
    if not ch then return end
    local hrp = ch:FindFirstChild("HumanoidRootPart")
    if not hrp then return end

    local hum = t.character and t.character:FindFirstChildOfClass("Humanoid")
    local tHrp = t.character and t.character:FindFirstChild("HumanoidRootPart")
    if not hum or not tHrp or hum.Health <= 0 then
      killAll.index = killAll.index + 1
      killAll.timer = 0
      return
    end

    local behindPos = tHrp.Position - tHrp.CFrame.LookVector * 3
    behindPos = Vector3.new(behindPos.X, tHrp.Position.Y + 1, behindPos.Z)
    local headPos = (t.character:FindFirstChild("Head") or tHrp).Position
    pcall(function()
      hrp.CFrame = CFrame.lookAt(behindPos, headPos)
    end)

    if killAll.timer > (cfg.killall_delay or 0.15) then
      fireWeapon()
    end
  end

  -- --------------------------------------------------------------------------
  -- Radar
  -- --------------------------------------------------------------------------
  local function drawRadar()
    local cfg = M.flags
    if not cfg.radar_on then return end
    local me = getChar()
    me = me and me:FindFirstChild("HumanoidRootPart")
    if not me then return end
    local hrp = me

    local vs = camera.ViewportSize
    local size = cfg.radar_size
    local pos = Vector2.new(vs.X - size - 16, vs.Y - size - 16)

    local bg = shape("Square")
    bg.Visible = true; bg.Color = { R = 0.06, G = 0.06, B = 0.1 }; bg.Thickness = 1
    bg.Size = Vector2.new(size, size); bg.Position = pos

    local border = shape("Square")
    border.Visible = true; border.Color = { R = 0.25, G = 0.55, B = 0.7 }; border.Thickness = 1
    border.Filled = false
    border.Size = Vector2.new(size, size); border.Position = pos

    local fwd, right = camera.CFrame.LookVector, camera.CFrame.RightVector
    for _, t in ipairs(collected) do
      if t.hos ~= "neutral" or cfg.radar_neutral then
        local rel = t.hrp.Position - hrp.Position
        local dx, dz = rel:Dot(right), rel:Dot(fwd)
        local horiz = math.sqrt(dx * dx + dz * dz)
        if horiz <= cfg.radar_range then
          local scale = (size / 2 - 4) / cfg.radar_range
          local sx, sy = pos.X + size / 2 + dx * scale, pos.Y + size / 2 + dz * scale
          local p = shape("Square")
          p.Visible = true
          p.Color = teamColors[t.hos] or teamColors.neutral
          p.Thickness = 1
          local s = t.hos == "enemy" and 3 or 2
          p.Size = Vector2.new(s, s)
          p.Position = Vector2.new(sx - s / 2, sy - s / 2)
        end
      end
    end
  end

  -- --------------------------------------------------------------------------
  -- Crosshair (Drawing primitives, crisp + configurable)
  -- --------------------------------------------------------------------------
  local crossColors = {
    white   = { R = 1, G = 1, B = 1 },
    green   = { R = 0.25, G = 1, B = 0.35 },
    red     = { R = 1, G = 0.2, B = 0.2 },
    cyan    = { R = 0.3, G = 0.9, B = 1 },
    yellow  = { R = 1, G = 0.85, B = 0.2 },
    orange  = { R = 1, G = 0.55, B = 0.1 },
    magenta = { R = 1, G = 0.3, B = 0.85 },
    lime    = { R = 0.6, G = 1, B = 0.15 },
  }

  local function syncCrosshair()
    local cfg = M.flags
    if not cfg.misc_crosshair then return end
    local vs = camera.ViewportSize
    local c = Vector2.new(vs.X / 2, vs.Y / 2)
    local style = cfg.cross_style or "cross"
    local t = clamp(cfg.cross_thickness or 1, 1, 8)
    local gap = clamp(cfg.cross_gap or 4, 0, 40)
    local len = clamp(cfg.cross_length or 7, 2, 60)
    local col = crossColors[cfg.cross_color or "white"] or crossColors.white
    local outline = cfg.cross_outline ~= false
    local outlineCol = { R = 0, G = 0, B = 0 }

    local function arms(cc, tt, dl)
      if style == "dot" or style == "ring" then
      else
        local l = shape("Line");  l.Color = cc; l.Thickness = tt
        l.From = c - Vector2.new(gap + len + dl, 0); l.To = c - Vector2.new(gap - dl, 0)
        l = shape("Line");  l.Color = cc; l.Thickness = tt
        l.From = c + Vector2.new(gap - dl, 0); l.To = c + Vector2.new(gap + len + dl, 0)
        l = shape("Line");  l.Color = cc; l.Thickness = tt
        l.From = c - Vector2.new(0, gap + len + dl); l.To = c - Vector2.new(0, gap - dl)
        l = shape("Line");  l.Color = cc; l.Thickness = tt
        l.From = c + Vector2.new(0, gap - dl); l.To = c + Vector2.new(0, gap + len + dl)
      end
      if style == "circle" or style == "ring" then
        local ring = shape("Circle")
        ring.Color = cc; ring.Thickness = tt; ring.Radius = gap + len
        ring.Position = c; ring.Filled = false
      end
    end
    local function centerDot(cc, rr, filled)
      local d = shape("Circle")
      d.Color = cc; d.Radius = rr; d.Position = c; d.Filled = filled
    end

    if outline then
      arms(outlineCol, t + 2, 1)
      if style ~= "cross" and style ~= "circle" then centerDot(outlineCol, t * 2 + 1, true) end
    end
    arms(col, t, 0)
    if style == "dot" or style == "crossdot" then centerDot(col, math.max(2, t), true) end
    if style == "ring" then centerDot(outline and outlineCol or col, math.max(2, t), true) end
  end

  -- --------------------------------------------------------------------------
  -- Overlay (Drawing) — FOV circle, lock marker, watermark
  -- --------------------------------------------------------------------------
  local function drawOverlay()
    local cfg = M.flags
    local vs = camera.ViewportSize
    local c = Vector2.new(vs.X / 2, vs.Y / 2)

    if cfg.aim_fov_circle then
      local circle = shape("Circle")
      circle.Color = { R = 0.2, G = 0.8, B = 1 }; circle.Transparency = 0.5
      circle.Thickness = 1; circle.NumSides = 60
      circle.Radius = math.tan(math.rad(clamp(cfg.aim_fov or 20, 5, 90))) * vs.Y * 0.5
      circle.Position = c; circle.Visible = true
    end

    if aimState.active and aimState.current then
      local sp, onScreen = wts(getAimPoint(aimState.current, cfg.aim_part))
      if onScreen then
        local dot = shape("Square")
        dot.Color = teamColors.enemy; dot.Thickness = 2
        dot.Size = Vector2.new(7, 7)
        dot.Position = sp - Vector2.new(3.5, 3.5)
        dot.Transparency = 1
      end
    end

    if cfg.misc_watermark then
      local wm = shape("Text")
      wm.Visible = true
      wm.Text = "ColdWar · " .. (getLocal() and getLocal().Name or "executor")
      wm.Size = 13
      wm.Color = { R = 0.5, G = 0.8, B = 1 }
      wm.Outline = true
      wm.Position = Vector2.new(6, 4)
    end
  end

  -- --------------------------------------------------------------------------
  -- Visuals
  -- --------------------------------------------------------------------------
  local function suppressWeather()
    for _, child in ipairs(workspace:GetChildren()) do
      local n = string.lower(child.Name)
      if child:IsA("Model") and (n:find("rain") or n:find("snow")) then
        local ok, desc = pcall(function() return child:GetDescendants() end)
        if ok then
          for _, d in ipairs(desc) do
            if d:IsA("ParticleEmitter") then
              pcall(function() d.Enabled = false end)
            elseif d:IsA("Sound") then
              pcall(function() d.Playing = false end)
            end
          end
        end
      end
    end
  end

  local cce
  local function updateVisuals()
    local cfg = M.flags
    if cfg.misc_noweather then suppressWeather() end
    if cfg.visual_fullbright then
      if not cce or not cce.Parent then
        cce = Instance.new("ColorCorrectionEffect")
        cce.Name = "CW_Fullbright"
        cce.Parent = lighting
      end
      cce.Brightness = clamp(cfg.visual_brightness, 0, 2)
      cce.Contrast = 0.15
      cce.Saturation = 0.1
    elseif cce and cce.Parent then
      pcall(function() cce:Destroy() end)
      cce = nil
    end
  end

  local function flushVisuals()
    updateGlow()
    updateVisuals()
    syncCrosshair()
  end

  -- --------------------------------------------------------------------------
  -- Movement: noclip / fly
  -- --------------------------------------------------------------------------
  local noclipApplied = false
  local flyActive = false

  local function setPartsCollide(on)
    local ch = getChar()
    if not ch then return end
    for _, part in ipairs(ch:GetDescendants()) do
      if part:IsA("BasePart") then
        pcall(function() part.CanCollide = on end)
      end
    end
  end

  local function zeroRootVel(hrp, freezeY)
    pcall(function() hrp.AssemblyAngularVelocity = Vector3.new(0, 0, 0) end)
    if freezeY then
      pcall(function()
        local v = hrp.AssemblyLinearVelocity
        if v.Y < -1 then hrp.AssemblyLinearVelocity = Vector3.new(v.X, 0, v.Z) end
      end)
    else
      pcall(function() hrp.AssemblyLinearVelocity = Vector3.new(0, 0, 0) end)
    end
  end

  local function updateMovement(dt)
    local cfg = M.flags
    local me = getChar()
    if not me then return end
    local hrp = me:FindFirstChild("HumanoidRootPart")
    if not hrp then return end
    local hum = me:FindFirstChildOfClass("Humanoid")
    local want = cfg.misc_noclip or cfg.misc_fly

    if want and not noclipApplied then setPartsCollide(false) end
    if not want and noclipApplied then setPartsCollide(true) end
    noclipApplied = want

    if not want then
      flyActive = false
      return
    end

    if hum and not flyActive then
      pcall(function() hum:ChangeState(Enum.HumanoidStateType.Flying) end)
    end
    flyActive = true

    if cfg.misc_fly then
      local speed = cfg.fly_speed
      local cf = camera.CFrame
      local fwd = Vector3.new(cf.LookVector.X, 0, cf.LookVector.Z)
      local right = Vector3.new(cf.RightVector.X, 0, cf.RightVector.Z)
      if fwd.Magnitude < 0.01 then fwd = Vector3.new(0, 0, -1) end
      if right.Magnitude < 0.01 then right = Vector3.new(1, 0, 0) end
      fwd = fwd.Unit
      right = right.Unit
      local move = Vector3.new()
      if userInput:IsKeyDown(Enum.KeyCode.W) then move = move + fwd end
      if userInput:IsKeyDown(Enum.KeyCode.S) then move = move - fwd end
      if userInput:IsKeyDown(Enum.KeyCode.A) then move = move - right end
      if userInput:IsKeyDown(Enum.KeyCode.D) then move = move + right end
      if userInput:IsKeyDown(Enum.KeyCode.Space) then move = move + Vector3.new(0, 1, 0) end
      if userInput:IsKeyDown(Enum.KeyCode.LeftShift) then move = move + Vector3.new(0, -1, 0) end
      if move.Magnitude > 0.001 then
        hrp.CFrame = hrp.CFrame + move.Unit * speed * dt
      end
      zeroRootVel(hrp, false)
    else
      pcall(function() hum:ChangeState(Enum.HumanoidStateType.Flying) end)
      zeroRootVel(hrp, true)
    end
  end

  -- --------------------------------------------------------------------------
  -- Teleport / markers
  -- --------------------------------------------------------------------------
  local function objectives()
    local out = {}
    local m = workspace:FindFirstChild("Match")
    local obs = m and m:FindFirstChild("Objectives")
    if obs then
      for _, ov in ipairs(obs:GetChildren()) do
        local v = ov.Value
        if v then
          local pos
          if v:IsA("BasePart") then
            pos = v.Position
          else
            local part = v:FindFirstChildWhichIsA("BasePart")
            pos = part and part.Position
          end
          if not pos and v:IsA("Model") then
            local ok, p = pcall(function() return v:GetPivot().Position end)
            if ok then pos = p end
          end
          if pos then out[#out + 1] = { name = ov.Name, label = tostring(v.Name), pos = pos } end
        end
      end
    end
    return out
  end

  local tpParams
  local function groundY(pos)
    if not tpParams then
      local ok, P = pcall(function() return RaycastParams.new() end)
      if ok and P then tpParams = P end
    end
    if tpParams then
      tpParams.FilterType = Enum.RaycastFilterType.Exclude
      tpParams.FilterDescendantsInstances = { getChar() or workspace.CurrentCamera }
      local ok, hit = pcall(function()
        return workspace:Raycast(pos + Vector3.new(0, 30, 0), Vector3.new(0, -600, 0), tpParams)
      end)
      if ok and hit then return hit.Position end
    end
    return nil
  end

  local function teleport(pos)
    local ch = getChar()
    if not ch then return "no char" end
    local hrp = ch:FindFirstChild("HumanoidRootPart")
    if not hrp then return "no hrp" end
    if M.flags.legit and (hrp.Position - pos).Magnitude > 300 then
      notify("Legit: teleport too far (>300st)")
      return "blocked"
    end
    local target = pos
    local gy = groundY(pos)
    if gy then
      target = Vector3.new(pos.X, gy.Y + 3, pos.Z)
    end
    pcall(function()
      hrp.CFrame = CFrame.new(target)
      pcall(function() hrp.Velocity = Vector3.new(0, 0, 0) end)
      pcall(function() hrp.AssemblyLinearVelocity = Vector3.new(0, 0, 0) end)
    end)
    return "tp ok"
  end

  -- --------------------------------------------------------------------------
  -- Render loop
  -- --------------------------------------------------------------------------
  local function beginRender()
    regConn(runService.RenderStepped:Connect(function(dt)
      camera = workspace.CurrentCamera or camera
      frameBegin()
      do local ok, e = pcall(collectTargets, M.flags.esp_range) if not ok then recordError("collect", e) end end
      do local ok, e = pcall(updateGlow) if not ok then recordError("glow", e) end end
      for _, t in ipairs(collected) do
        do local ok, e = pcall(renderESP, t) if not ok then recordError("esp", e) end end
      end
      do local ok, e = pcall(updateAim) if not ok then recordError("aim", e) end end
      do local ok, e = pcall(function()
        aimFOV(aimState.active or killAll.active
          or (M.flags.aim_fastzoom and M.flags.aim_enabled
            and userInput:IsMouseButtonPressed(Enum.UserInputType.MouseButton2)))
      end) if not ok then recordError("fov", e) end end
      do local ok, e = pcall(applyAim) if not ok then recordError("aimapply", e) end end
      do local ok, e = pcall(drawOverlay) if not ok then recordError("overlay", e) end end
      do local ok, e = pcall(drawRadar) if not ok then recordError("radar", e) end end
      do local ok, e = pcall(updateVisuals) if not ok then recordError("visuals", e) end end
      do local ok, e = pcall(updateMovement, dt) if not ok then recordError("move", e) end end
      do local ok, e = pcall(stepKillAll, dt) if not ok then recordError("killall", e) end end
      do local ok, e = pcall(syncCrosshair) if not ok then recordError("cross", e) end end
      if M.uiState.mouseFree then
        do local ok, e = pcall(function()
          userInput.MouseBehavior = Enum.MouseBehavior.Default
        end) if not ok then recordError("mouse", e) end end
      end
    end))
  end

  -- --------------------------------------------------------------------------
  -- Flags + keybind defs
  -- --------------------------------------------------------------------------
  local defaultFor = {
    legit = false,
    aim_enabled = false, aim_part = "head", aim_fov = 20, aim_smooth = 45,
    aim_hold = "right", aim_priority = "closest", aim_visible_check = true,
    aim_friends = false, aim_all = false, aim_fov_circle = false, aim_pause_menu = false,
    aim_autofire = false, aim_rage = false, aim_fastzoom = false, aim_zoom_fov = 25,
    aim_fire_rate = 15, aim_head_off = 0.3, aim_delay = 0.08,
    killall_delay = 0.15,
    esp_box = false, esp_health = false, esp_tracer = false, esp_name = false,
    esp_distance = false, esp_weapon = false, esp_team = false, esp_thickness = 1,
    esp_range = 4000,
    glow_on = false, glow_friends = false,
    radar_on = false, radar_neutral = false, radar_range = 1000, radar_size = 190,
    visual_fullbright = false, visual_brightness = 0.8,
    misc_crosshair = false, misc_watermark = false, misc_noweather = false,
    misc_noclip = false, misc_fly = false, fly_speed = 45,
    cross_style = "cross", cross_thickness = 1, cross_gap = 4, cross_length = 7,
    cross_color = "white", cross_outline = true,
    bind_aim_key = "CapsLock", bind_aim_mode = "toggle",
    bind_killall_key = "none", bind_killall_mode = "toggle",
    bind_noclip_key = "none", bind_noclip_mode = "toggle",
    bind_fly_key = "none", bind_fly_mode = "toggle",
    bind_zoom_key = "none", bind_zoom_mode = "toggle",
  }

  for k, v in pairs(defaultFor) do
    if M.flags[k] == nil then M.flags[k] = v end
  end

  -- Nova control handles + unload fn (forward: bind sides/hotkeys sync them)
  local killToggle, noclipToggle, flyToggle, zoomToggle
  local rageToggle, autoToggle
  local unloadModule
  local legitGuard -- fwd: returns true (and notifies) when Legit blocks

  M.bindDefs = {
    aim = { label = "Aim lock", keyflag = "bind_aim_key", modflag = "bind_aim_mode" },
    killall = {
      label = "Kill all", keyflag = "bind_killall_key", modflag = "bind_killall_mode",
      side = function(on)
        if killAll.active == on then return end
        if on then startKillAll() else stopKillAll() end
        notify("Kill All " .. (on and "STARTED" or "STOPPED"))
        if killToggle then killToggle.Set(killAll.active) end
      end,
    },
    noclip = {
      label = "Noclip", keyflag = "bind_noclip_key", modflag = "bind_noclip_mode",
      side = function(on)
        if on and legitGuard() then
          M.flags.misc_noclip = false
          if noclipToggle then noclipToggle.Set(false) end
          return
        end
        M.flags.misc_noclip = on
        if on and M.flags.misc_fly then M.flags.misc_fly = false end
        notify(on and "Noclip ON" or "Noclip OFF")
        if noclipToggle then noclipToggle.Set(on) end
        if flyToggle and M.flags.misc_fly == false then flyToggle.Set(false) end
      end,
    },
    fly = {
      label = "Fly", keyflag = "bind_fly_key", modflag = "bind_fly_mode",
      side = function(on)
        if on and legitGuard() then
          M.flags.misc_fly = false
          if flyToggle then flyToggle.Set(false) end
          return
        end
        M.flags.misc_fly = on
        if on and M.flags.misc_noclip then M.flags.misc_noclip = false end
        notify(on and "Fly ON (WASD + space)" or "Fly OFF")
        if flyToggle then flyToggle.Set(on) end
        if noclipToggle and M.flags.misc_noclip == false then noclipToggle.Set(false) end
      end,
    },
    zoom = {
      label = "Fast zoom", keyflag = "bind_zoom_key", modflag = "bind_zoom_mode",
      side = function(on)
        M.flags.aim_fastzoom = on
        if zoomToggle then zoomToggle.Set(on) end
      end,
    },
  }

  -- --------------------------------------------------------------------------
  -- Nova UI (replaces the standalone menu)
  -- --------------------------------------------------------------------------
  legitGuard = function()
    if M.flags.legit then notify("Blocked by Legit Mode") return true end
    return false
  end
  local function flagToggle(sec, name, key, desc, tip)
    return sec:Toggle({ Name = name, Desc = desc, Default = M.flags[key] == true,
      Flag = "cw_" .. key, Tooltip = tip,
      Callback = function(v) M.flags[key] = v == true end })
  end
  local function flagSlider(sec, name, key, min, max, extra)
    extra = extra or {}
    return sec:Slider({ Name = name, Min = min, Max = max, Default = M.flags[key],
      Decimals = extra.dec or 0, Suffix = extra.suf or "", Flag = "cw_" .. key,
      Tooltip = extra.tip,
      Callback = function(v) M.flags[key] = tonumber(v) or min end })
  end
  local function flagDropdown(sec, name, key, options, tip)
    return sec:Dropdown({ Name = name, Options = options, Default = M.flags[key],
      Flag = "cw_" .. key, Tooltip = tip,
      Callback = function(v) M.flags[key] = tostring(v) end })
  end
  local function bindRow(sec, action)
    -- key capture (Nova control) + toggle/hold mode (engine dispatcher stays)
    local def = M.bindDefs[action]
    sec:Keybind({ Name = def.label .. " key", Default = keyOf(M.flags[def.keyflag]),
      Tooltip = "Click, then press a key (Esc cancels, Backspace clears)",
      Callback = function(v)
        M.flags[def.keyflag] = (v and v.Name) or "none"
      end })
    sec:Segmented({ Name = def.label .. " mode", Options = { "toggle", "hold" },
      Default = M.flags[def.modflag] or "toggle",
      Callback = function(v) M.flags[def.modflag] = tostring(v) end })
  end

  -- --------------------------------------------------------------------------
  -- Nova UI — Delta-style navigation (Pages + SubTabs, engine untouched)
  -- --------------------------------------------------------------------------
  local pages = {}
  local nav = api.Navigation or Tab:Navigation({ Name = "Cold War" })
  local menuDefs = {
    { "ESP", "□", "Players, teams and highlights" },
    { "Aim", "◎", "Aimbot, fire and Kill All" },
    { "Teleport", "▷", "Markers, capture points, players, vehicles" },
    { "World", "◈", "Visuals, movement and radar" },
    { "Safety", "⚑", "Legit Mode, session stats and mouse" },
    { "About", "i", "Status and unload" },
  }
  for index, def in ipairs(menuDefs) do
    pages[def[1]] = nav:Page({ Id = "cw_" .. def[1]:lower(), Name = def[1],
      Icon = def[2], Tooltip = def[3], Order = index })
  end
  pages.ESP:Select()
  local espTabs = pages.ESP:SubTabs({ { Name = "Players" }, { Name = "Glow" } })
  local aimTabs = pages.Aim:SubTabs({ { Name = "Aim" }, { Name = "Fire" }, { Name = "Kill All" } })
  local tpTabs = pages.Teleport:SubTabs({ { Name = "Points" }, { Name = "Players" }, { Name = "Vehicles" } })
  local worldTabs = pages.World:SubTabs({ { Name = "Visuals" }, { Name = "Move" }, { Name = "Radar" } })

  -- AIM --
  local aimSec = aimTabs.Aim:Section({ Name = "Aim" })
  aimSec:Paragraph("Camera aimbot. The Aim lock key bar is right below in this section.")
  aimSec:Toggle({ Name = "Aimbot", Default = M.flags.aim_enabled == true, Flag = "cw_aim_enabled",
    Callback = function(v) M.flags.aim_enabled = v == true end })
  flagDropdown(aimSec, "Aim part", "aim_part", { "head", "neck", "body" })
  flagSlider(aimSec, "FOV deg", "aim_fov", 5, 60)
  flagSlider(aimSec, "Smoothness", "aim_smooth", 1, 100)
  aimSec:Slider({ Name = "Target delay", Min = 0, Max = 0.5, Default = M.flags.aim_delay or 0.08,
    Decimals = 2, Suffix = "s", Flag = "cw_aim_delay",
    Tooltip = "Human reaction delay before engaging a new target",
    Callback = function(v) M.flags.aim_delay = tonumber(v) or 0 end })
  flagDropdown(aimSec, "Trigger", "aim_hold", { "right", "left", "always" },
    "Mouse button that engages the lock (plus the Aim lock key gate)")
  flagDropdown(aimSec, "Priority", "aim_priority", { "closest", "distance" })
  flagToggle(aimSec, "Visible check", "aim_visible_check", "Skip targets behind walls")
  flagToggle(aimSec, "Aim at friends", "aim_friends")
  flagToggle(aimSec, "Aim neutrals", "aim_all")
  flagToggle(aimSec, "FOV circle", "aim_fov_circle")
  flagToggle(aimSec, "Pause while hub open", "aim_pause_menu")
  bindRow(aimSec, "aim")

  -- FIRE --
  local fireSec = aimTabs.Fire:Section({ Name = "Fire" })
  fireSec:Paragraph("Rage (X) locks everything on screen and fires. Needs an equipped firearm.")
  rageToggle = fireSec:Toggle({ Name = "Rage aim (X)", Default = M.flags.aim_rage == true, Flag = "cw_aim_rage",
    Callback = function(v)
      if v and legitGuard() then if rageToggle then rageToggle.Set(false) end return end
      M.flags.aim_rage = v == true
    end })
  autoToggle = fireSec:Toggle({ Name = "Auto fire (B)", Default = M.flags.aim_autofire == true, Flag = "cw_aim_autofire",
    Callback = function(v)
      if v and legitGuard() then if autoToggle then autoToggle.Set(false) end return end
      M.flags.aim_autofire = v == true
    end })
  zoomToggle = fireSec:Toggle({ Name = "Fast zoom (RMB)", Default = M.flags.aim_fastzoom == true, Flag = "cw_aim_fastzoom",
    Callback = function(v) M.flags.aim_fastzoom = v == true end })
  flagSlider(fireSec, "Fire rate", "aim_fire_rate", 5, 30, { suf = "/s" })
  flagSlider(fireSec, "Zoom FOV", "aim_zoom_fov", 5, 50)
  bindRow(fireSec, "zoom")

  -- ESP --
  local espSec = espTabs.Players:Section({ Name = "ESP" })
  espSec:Paragraph("NATO/PACT teams auto-detected (blue = friendly, red = enemy).")
  flagToggle(espSec, "Box", "esp_box")
  flagToggle(espSec, "Health bar", "esp_health")
  flagToggle(espSec, "Tracers", "esp_tracer")
  flagToggle(espSec, "Name", "esp_name")
  flagToggle(espSec, "Distance", "esp_distance")
  flagToggle(espSec, "Weapon", "esp_weapon")
  flagToggle(espSec, "Team tag", "esp_team")
  flagSlider(espSec, "Thickness", "esp_thickness", 1, 5)
  flagSlider(espSec, "Range", "esp_range", 200, 6000, { suf = " st" })

  -- GLOW --
  local glowSec = espTabs.Glow:Section({ Name = "Glow" })
  glowSec:Paragraph("See-through chams (Highlight).")
  flagToggle(glowSec, "ESP chams (glow)", "glow_on")
  flagToggle(glowSec, "Highlight allies", "glow_friends")

  -- RADAR --
  local radarSec = worldTabs.Radar:Section({ Name = "Radar" })
  flagToggle(radarSec, "Radar", "radar_on")
  flagToggle(radarSec, "Show neutral", "radar_neutral")
  flagSlider(radarSec, "Range", "radar_range", 50, 2500, { suf = " st" })
  flagSlider(radarSec, "Size", "radar_size", 100, 420, { suf = "px" })

  -- MOVE --
  local moveSec = worldTabs.Move:Section({ Name = "Move" })
  noclipToggle = moveSec:Toggle({ Name = "Noclip (N)", Desc = "Walls, no fall",
    Default = M.flags.misc_noclip == true, Flag = "cw_misc_noclip",
    Callback = function(v)
      if v and legitGuard() then if noclipToggle then noclipToggle.Set(false) end return end
      M.flags.misc_noclip = v == true
      if v and M.flags.misc_fly then M.flags.misc_fly = false; if flyToggle then flyToggle.Set(false) end end
    end })
  flyToggle = moveSec:Toggle({ Name = "Fly (M)", Desc = "WASD + Space up / Shift down",
    Default = M.flags.misc_fly == true, Flag = "cw_misc_fly",
    Callback = function(v)
      if v and legitGuard() then if flyToggle then flyToggle.Set(false) end return end
      M.flags.misc_fly = v == true
      if v and M.flags.misc_noclip then M.flags.misc_noclip = false; if noclipToggle then noclipToggle.Set(false) end end
    end })
  flagSlider(moveSec, "Fly speed", "fly_speed", 10, 200, { suf = " st/s" })
  bindRow(moveSec, "noclip")
  bindRow(moveSec, "fly")

  -- WORLD --
  local worldSec = worldTabs.Visuals:Section({ Name = "World" })
  flagToggle(worldSec, "Fullbright", "visual_fullbright")
  flagSlider(worldSec, "Brightness", "visual_brightness", 0, 2, { dec = 1 })
  flagToggle(worldSec, "Disable weather (rain/snow)", "misc_noweather")
  flagToggle(worldSec, "Crosshair", "misc_crosshair")
  flagDropdown(worldSec, "Crosshair style", "cross_style", { "cross", "dot", "ring", "circle", "crossdot" })
  flagSlider(worldSec, "Crosshair thickness", "cross_thickness", 1, 8)
  flagSlider(worldSec, "Crosshair gap", "cross_gap", 0, 40, { suf = "px" })
  flagSlider(worldSec, "Crosshair length", "cross_length", 2, 60, { suf = "px" })
  flagDropdown(worldSec, "Crosshair color", "cross_color",
    { "white", "green", "red", "cyan", "yellow", "orange", "magenta", "lime" })
  flagToggle(worldSec, "Crosshair outline", "cross_outline")
  flagToggle(worldSec, "Watermark", "misc_watermark")

  -- TELEPORT: Points --
  local tpPoints = tpTabs.Points:Section({ Name = "Markers & points" })
  tpPoints:Paragraph("P = save position · O = go back · F2/F3 = capture points 1/2.")
  local markerDD, objDD, allyDD, enemyDD
  local refreshTpPlayers -- fwd: defined after enemyDD, used by Refresh button
  local function markerNames()
    local out = {}
    for _, mk in ipairs(M.markers) do table.insert(out, mk.name) end
    if #out == 0 then out = { "—" } end
    return out
  end
  local function findMarker(name)
    for _, mk in ipairs(M.markers) do if mk.name == name then return mk end end
  end
  tpPoints:Button({ Name = "Save current position (P)", Callback = function()
    local me = getChar()
    local hrp = me and me:FindFirstChild("HumanoidRootPart")
    if hrp then
      table.insert(M.markers, { name = "Marked " .. (#M.markers + 1), pos = hrp.Position })
      markerDD.SetOptions(markerNames(), true)
      notify("Position saved")
    end
  end })
  markerDD = tpPoints:Dropdown({ Name = "Marker", Options = markerNames(), Default = "—",
    Callback = function() end })
  tpPoints:Button({ Name = "Teleport to marker (O)", Variant = "ghost", Callback = function()
    local mk = findMarker(tostring(markerDD.Get()))
    if mk then teleport(mk.pos) else notify("No marker") end
  end })
  local function objNames()
    local out = {}
    for _, o in ipairs(objectives()) do table.insert(out, o.label) end
    if #out == 0 then out = { "—" } end
    return out
  end
  local function findObj(label)
    for _, o in ipairs(objectives()) do if o.label == label then return o end end
  end
  tpPoints:Button({ Name = "Refresh lists", Variant = "ghost", Callback = function()
    markerDD.SetOptions(markerNames(), true)
    objDD.SetOptions(objNames(), true)
    refreshTpPlayers()
  end })
  objDD = tpPoints:Dropdown({ Name = "Capture point", Options = objNames(), Default = "—",
    Callback = function() end })
  tpPoints:Button({ Name = "Teleport to point", Variant = "ghost", Callback = function()
    local o = findObj(tostring(objDD.Get()))
    if o then teleport(o.pos) else notify("No point") end
  end })
  local function alivePl(p)
    local ch = p.Character
    local h = ch and ch:FindFirstChildOfClass("Humanoid")
    return h and h.Health > 0 and ch:FindFirstChild("HumanoidRootPart") ~= nil
  end
  local function playerLists()
    local me = getLocal()
    local allies, enemies = {}, {}
    for _, p in ipairs(players:GetPlayers()) do
      if p ~= me and alivePl(p) then
        local h = hostility(p)
        if h == "friendly" then allies[#allies + 1] = p
        elseif h == "enemy" then enemies[#enemies + 1] = p end
      end
    end
    return allies, enemies
  end
  local function tpToPlayer(p)
    if not p then notify("No target") return end
    local hrp = p.Character and p.Character:FindFirstChild("HumanoidRootPart")
    if hrp then teleport(hrp.Position + Vector3.new(0, 0.5, 0)) end
  end
  local function nameList(list)
    local out = {}
    for _, p in ipairs(list) do table.insert(out, p.Name) end
    if #out == 0 then out = { "—" } end
    return out
  end
  local function findPlayer(list, name)
    for _, p in ipairs(list) do if p.Name == name then return p end end
  end
  -- TELEPORT: Players --
  local tpPlayers = tpTabs.Players:Section({ Name = "Players" })
  allyDD = tpPlayers:Dropdown({ Name = "Ally", Options = { "—" }, Default = "—", Callback = function() end })
  tpPlayers:Button({ Name = "TP to ally", Variant = "ghost", Callback = function()
    local a = playerLists()
    tpToPlayer(findPlayer(a, tostring(allyDD.Get())))
  end })
  enemyDD = tpPlayers:Dropdown({ Name = "Enemy", Options = { "—" }, Default = "—", Callback = function() end })
  tpPlayers:Button({ Name = "TP to enemy", Variant = "ghost", Callback = function()
    local _, e = playerLists()
    tpToPlayer(findPlayer(e, tostring(enemyDD.Get())))
  end })
  refreshTpPlayers = function()
    local a, e = playerLists()
    allyDD.SetOptions(nameList(a), true)
    enemyDD.SetOptions(nameList(e), true)
  end
  tpPlayers:Button({ Name = "Random ally → tp", Variant = "ghost", Callback = function()
    local a = playerLists()
    if #a > 0 then tpToPlayer(a[math.random(1, #a)]) end
  end })
  tpPlayers:Button({ Name = "Random enemy → tp", Variant = "ghost", Callback = function()
    local _, e = playerLists()
    if #e > 0 then tpToPlayer(e[math.random(1, #e)]) end
  end })
  -- TELEPORT: Vehicles --
  local tpVehicles = tpTabs.Vehicles:Section({ Name = "Vehicles" })
  local function sitOn(seat)
    local ch = getChar()
    local hum = ch and ch:FindFirstChildOfClass("Humanoid")
    local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
    if not (hum and hrp and seat) then return end
    pcall(function() hrp.CFrame = seat.CFrame * CFrame.new(0, 3, 0) end)
    task.wait(0.05)
    pcall(function() hrp.CFrame = seat.CFrame * CFrame.new(0, 1.6, 0) end)
    pcall(function() hum.Sit = true end)
  end
  local function scanVehicles(wantDriver)
    local out = {}
    local seen = {}
    pcall(function()
      for _, s in ipairs(workspace:GetDescendants()) do
        if s:IsA("VehicleSeat") then
          local m = s:FindFirstAncestorOfClass("Model")
          if m and not seen[m] then
            seen[m] = true
            local free = {}
            for _, ss in ipairs(m:GetDescendants()) do
              if ss:IsA("VehicleSeat") then
                local okO, ov = pcall(function() return ss.Occupant end)
                if okO and not ov then free[#free + 1] = ss end
              end
            end
            if #free > 0 then
              if wantDriver then
                local d2 = nil
                for _, f in ipairs(free) do
                  if tostring(f.Name):lower():find("driver") then d2 = f break end
                end
                out[#out + 1] = d2 or free[1]
              else
                out[#out + 1] = free[1]
              end
            end
          end
        end
      end
    end)
    return out
  end
  tpVehicles:Button({ Name = "Free car (sit)", Variant = "ghost", Callback = function()
    local v = scanVehicles(false)
    if #v > 0 then sitOn(v[math.random(1, #v)]) else notify("No free vehicle") end
  end })
  tpVehicles:Button({ Name = "Driver seat", Variant = "ghost", Callback = function()
    local v = scanVehicles(true)
    if #v > 0 then sitOn(v[math.random(1, #v)]) else notify("No free vehicle") end
  end })

  -- KILL ALL --
  local killSec = aimTabs["Kill All"]:Section({ Name = "Kill All" })
  killSec:Paragraph("Teleports behind checked targets and fires. G = start/stop.")
  local killStatus = killSec:Label("idle")
  killToggle = killSec:Toggle({ Name = "Kill All (G)", Default = false,
    Callback = function(v)
      if v then startKillAll() else stopKillAll() end
      if killToggle then killToggle.Set(killAll.active, true) end -- silent: no loop
      killStatus.Set(killAll.active and "RUNNING" or "idle")
    end })
  killSec:Slider({ Name = "Step delay", Min = 0.01, Max = 0.5, Default = M.flags.killall_delay or 0.15,
    Decimals = 2, Suffix = "s", Flag = "cw_killall_delay",
    Callback = function(v) M.flags.killall_delay = tonumber(v) or 0.15 end })
  local killDD
  local function enemyNames()
    local _, e = playerLists()
    return nameList(e)
  end
  killDD = killSec:MultiDropdown({ Name = "Targets (enemies)", Options = enemyNames(), Default = {},
    Tooltip = "Checked players are visited by Kill All",
    Callback = function(v)
      M.killAllChecked = {}
      if type(v) == "table" then
        for _, n in ipairs(v) do M.killAllChecked[tostring(n)] = true end
      end
      local n = 0
      for _ in pairs(M.killAllChecked) do n = n + 1 end
      killStatus.Set((killAll.active and "RUNNING · " or "") .. n .. " targets")
    end })
  killSec:Button({ Name = "Check all enemies", Variant = "ghost", Callback = function()
    for _, pl in ipairs(players:GetPlayers()) do
      if pl ~= getLocal() then
        local ch = pl.Character
        local hum = ch and ch:FindFirstChildOfClass("Humanoid")
        if hum and hum.Health > 0 and hostility(pl) == "enemy" then
          M.killAllChecked[pl.Name] = true
        end
      end
    end
    killDD.SetOptions(enemyNames(), true)
    killStatus.Set("targets checked")
  end })
  killSec:Button({ Name = "Clear + refresh", Variant = "ghost", Callback = function()
    M.killAllChecked = {}
    killDD.SetOptions(enemyNames(), true)
    killStatus.Set("idle")
  end })
  bindRow(killSec, "killall")

  -- SAFETY (anti-ban) --
  local safeSec = pages.Safety:Section({ Name = "Safety" })
  safeSec:Paragraph("No script is undetectable here: the server sees positions, shots and stats, players report (ReportGui), mods watch live. Biggest risks: mass kills, rage snaps, teleports, impossible fire packets. Legit Mode kills all blatant vectors in one tap — it is safer, not immortal.")
  safeSec:Toggle({ Name = "Legit Mode", Desc = "One tap clean",
    Default = false, Flag = "cw_legit",
    Tooltip = "Forces off rage/autofire/fly/noclip/kill-all, forces visible-check + enemies-only + fire-rate cap + 300st teleport cap. Blocks re-enabling while on.",
    Callback = function(v)
      M.flags.legit = v == true
      if v then
        M.flags.aim_rage = false
        M.flags.aim_autofire = false
        M.flags.misc_fly = false
        M.flags.misc_noclip = false
        if killAll.active then stopKillAll() end
        if rageToggle then rageToggle.Set(false) end
        if autoToggle then autoToggle.Set(false) end
        if flyToggle then flyToggle.Set(false) end
        if noclipToggle then noclipToggle.Set(false) end
        if killToggle then killToggle.Set(false, true) end
        killStatus.Set("idle")
        notify("Legit Mode ON — blatant features off")
      else
        notify("Legit Mode OFF")
      end
    end })
  local kdLabel = safeSec:Label("Session K/D: —")
  local kdBase, kdTick, kdW15, kdW30 = nil, 0, false, false
  local function numAttr(n)
    local ok, v = pcall(function()
      local p = getLocal()
      return p and p:GetAttribute(n) or nil
    end)
    if not ok then return 0 end
    return tonumber(v) or 0
  end
  regConn(runService.Heartbeat:Connect(function()
    local now = os.clock()
    if now - kdTick < 2 then return end
    kdTick = now
    local k, d = numAttr("Kills"), numAttr("Deaths")
    if not kdBase then kdBase = { k = k, d = d } end
    local sk, sd = k - kdBase.k, d - kdBase.d
    pcall(function()
      kdLabel.Set(("Session K/D: %d/%d  (total %d/%d)"):format(sk, sd, k, d))
    end)
    if sk >= 15 and not kdW15 then
      kdW15 = true
      notify("15 session kills — consider Legit Mode")
    end
    if sk >= 30 and not kdW30 then
      kdW30 = true
      notify("30 session kills — high report risk, Legit advised")
    end
  end))

  -- MOUSE (keybinds live next to their features now) --
  local mouseSec = pages.Safety:Section({ Name = "Mouse" })
  mouseSec:Paragraph("Key bars sit inside their feature sections (Aim · Fire · Move · Kill All). Fixed: Alt/Ctrl mouse · P/O/F2/F3 tp · X rage · G kill · B autofire · N/M noclip/fly.")
  mouseSec:Toggle({ Name = "Free mouse (Alt)", Desc = "Release cursor for the hub window",
    Default = false, Callback = function(v)
      M.uiState.mouseFree = v == true
      pcall(function()
        userInput.MouseBehavior = v and Enum.MouseBehavior.Default or Enum.MouseBehavior.LockCenter
      end)
    end })

  -- ABOUT --
  local aboutSec = pages.About:Section({ Name = "About" })
  aboutSec:Label("COLD WAR · hub module (engine v3)")
  aboutSec:Paragraph("NATO/PACT auto-teams · R6 · BallisticsNet fire · conquest teleports. Persistence via hub Settings → Config.")
  aboutSec:Button({ Name = "Unload module", Variant = "danger", Callback = function()
    unloadModule()
  end })

  -- --------------------------------------------------------------------------
  -- Hotkeys (no menu toggle / drag / picking — hub owns the window)
  -- --------------------------------------------------------------------------
  local function initKeys()
    local lastAlt, lastCtrl, lastP, lastO, lastF2, lastF3 = 0, 0, 0, 0, 0, 0
    local lastG, lastX, lastB = 0, 0, 0
    local lastN, lastM = 0, 0

    regConn(runService.Heartbeat:Connect(function()
      -- whole-body guard: uncaught per-frame errors are observable noise
      pcall(function()
      local t = os.clock()
      local typing = userInput:GetFocusedTextBox() ~= nil

      if not typing then
        if (userInput:IsKeyDown(Enum.KeyCode.RightAlt) or userInput:IsKeyDown(Enum.KeyCode.LeftAlt)) and (t - lastAlt) > 0.3 then
          lastAlt = t
          M.uiState.mouseFree = not M.uiState.mouseFree
          pcall(function()
            userInput.MouseBehavior = M.uiState.mouseFree and Enum.MouseBehavior.Default or Enum.MouseBehavior.LockCenter
          end)
          notify(M.uiState.mouseFree and "mouse released" or "mouse locked")
        end
        if (userInput:IsKeyDown(Enum.KeyCode.LeftControl) or userInput:IsKeyDown(Enum.KeyCode.RightControl)) and (t - lastCtrl) > 0.35 then
          lastCtrl = t
          M.uiState.mouseFree = not M.uiState.mouseFree
          pcall(function()
            userInput.MouseBehavior = M.uiState.mouseFree and Enum.MouseBehavior.Default or Enum.MouseBehavior.LockCenter
          end)
          notify(M.uiState.mouseFree and "mouse released (Ctrl)" or "mouse locked (Ctrl)")
        end
        if userInput:IsKeyDown(Enum.KeyCode.P) and (t - lastP) > 0.4 then
          lastP = t
          local me, hrp = getChar(), nil
          if me then hrp = me:FindFirstChild("HumanoidRootPart") end
          if hrp then
            table.insert(M.markers, { name = "Marked " .. (#M.markers + 1), pos = hrp.Position })
            markerDD.SetOptions(markerNames(), true)
            notify("Position saved")
          end
        end
        if userInput:IsKeyDown(Enum.KeyCode.O) and (t - lastO) > 0.4 then
          lastO = t
          local last = M.markers[#M.markers]
          if last then teleport(last.pos) end
        end
        local obs = objectives()
        if userInput:IsKeyDown(Enum.KeyCode.F2) and (t - lastF2) > 0.4 and obs[1] then
          lastF2 = t
          teleport(obs[1].pos)
        end
        if userInput:IsKeyDown(Enum.KeyCode.F3) and (t - lastF3) > 0.4 and obs[2] then
          lastF3 = t
          teleport(obs[2].pos)
        end
        if userInput:IsKeyDown(Enum.KeyCode.G) and (t - lastG) > 0.5 then
          lastG = t
          if killAll.active then stopKillAll() else startKillAll() end
          if killToggle then killToggle.Set(killAll.active) end
          killStatus.Set(killAll.active and "RUNNING" or "idle")
          notify(killAll.active and "Kill All STARTED" or "Kill All STOPPED")
        end
        if userInput:IsKeyDown(Enum.KeyCode.X) and (t - lastX) > 0.3 then
          lastX = t
          if not M.flags.aim_rage and legitGuard() then
            if rageToggle then rageToggle.Set(false) end
          else
            M.flags.aim_rage = not M.flags.aim_rage
            if rageToggle then rageToggle.Set(M.flags.aim_rage) end
            notify(M.flags.aim_rage and "Rage ON" or "Rage OFF")
          end
        end
        if userInput:IsKeyDown(Enum.KeyCode.B) and (t - lastB) > 0.3 then
          lastB = t
          if not M.flags.aim_autofire and legitGuard() then
            if autoToggle then autoToggle.Set(false) end
          else
            M.flags.aim_autofire = not M.flags.aim_autofire
            if autoToggle then autoToggle.Set(M.flags.aim_autofire) end
            notify(M.flags.aim_autofire and "AutoFire ON" or "AutoFire OFF")
          end
        end
        if userInput:IsKeyDown(Enum.KeyCode.N) and (t - lastN) > 0.3 then
          lastN = t
          if not M.flags.misc_noclip and legitGuard() then
            if noclipToggle then noclipToggle.Set(false) end
          else
            M.flags.misc_noclip = not M.flags.misc_noclip
            if M.flags.misc_fly and M.flags.misc_noclip then M.flags.misc_fly = false end
            if noclipToggle then noclipToggle.Set(M.flags.misc_noclip) end
            if flyToggle then flyToggle.Set(M.flags.misc_fly) end
            notify(M.flags.misc_noclip and "Noclip ON" or "Noclip OFF")
          end
        end
        if userInput:IsKeyDown(Enum.KeyCode.M) and (t - lastM) > 0.3 then
          lastM = t
          if not M.flags.misc_fly and legitGuard() then
            if flyToggle then flyToggle.Set(false) end
          else
            M.flags.misc_fly = not M.flags.misc_fly
            if M.flags.misc_fly and M.flags.misc_noclip then M.flags.misc_noclip = false end
            if flyToggle then flyToggle.Set(M.flags.misc_fly) end
            if noclipToggle then noclipToggle.Set(M.flags.misc_noclip) end
            notify(M.flags.misc_fly and "Fly ON (WASD + space)" or "Fly OFF")
          end
        end
      end

      -- keybind dispatcher: hold = live key state, toggle = edge flip
      for action, def in pairs(M.bindDefs) do
        local kc = keyOf(M.flags[def.keyflag])
        if kc then
          local down = userInput:IsKeyDown(kc)
          local prevDown = M.binds.prev[action]
          M.binds.prev[action] = down
          local mode = M.flags[def.modflag] or "toggle"
          if mode == "toggle" and down and not prevDown then
            M.binds.tog[action] = not M.binds.tog[action]
          end
          local eff = (mode == "hold" and down) or M.binds.tog[action]
          if eff ~= M.binds.last[action] then
            M.binds.last[action] = eff
            if def.side then xpcall(function() def.side(eff or false) end,
              function(err) recordError("bind:" .. action, err) end) end
          end
        end
      end

      if M.uiState.mouseFree then
        pcall(function()
          userInput.MouseBehavior = Enum.MouseBehavior.Default
        end)
      end
      end)
    end))
  end

  -- --------------------------------------------------------------------------
  -- Unload + boot
  -- --------------------------------------------------------------------------
  unloadModule = function()
    if killAll.active then pcall(stopKillAll) end
    for _, c in ipairs(CONNS) do pcall(function() c:Disconnect() end) end
    for _, page in pairs(pages) do pcall(function() page:Destroy() end) end
    for _, s in ipairs(frameShapes) do pcall(function() s:Remove() end) end
    for _, s in ipairs(prevShapes) do pcall(function() s:Remove() end) end
    frameShapes, prevShapes = {}, {}
    for ch in pairs(glowTable) do applyGlow(ch, { R = 1, G = 1, B = 1 }, false) end
    for k in pairs(glowTable) do glowTable[k] = nil end
    pcall(function() aimFOV(false) end)
    pcall(function() setPartsCollide(true) end)
    if cce then pcall(function() cce:Destroy() end) cce = nil end
    local g = getgenv and getgenv()
    if g then
      if g.__HUMA_PLACE and g.__HUMA_PLACE.Unload == unloadModule then g.__HUMA_PLACE = nil end
      if g.__HUMA_COLDWAR and g.__HUMA_COLDWAR.Unload == unloadModule then g.__HUMA_COLDWAR = nil end
    end
    notify("Cold War module unloaded")
  end

  beginRender()
  initKeys()
  flushVisuals()
  refreshTpPlayers()
  killDD.SetOptions(enemyNames(), true)

  local hub = { Unload = unloadModule }
  if getgenv then pcall(function()
    getgenv().__HUMA_COLDWAR = hub
    getgenv().__HUMA_PLACE = hub -- generic contract: hub unloads the place module
  end) end

  notify("Cold War loaded — Alt frees the mouse, RightShift toggles the hub")
  print("[huma-coldwar] place module loaded")
end
