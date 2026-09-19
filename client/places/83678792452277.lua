--[[
  HumaHub place module — Death Ball (PlaceId 83678792452277, UniverseId 5166944221).
  Repo path: client/places/83678792452277.lua
  Universe redirect: client/universes/5166944221.lua (every map funnels here).

  Verified live against the game client:
    - parry swing = ReplicatedStorage._SwordVFXAcquire:InvokeServer({sword, finisher})
      + _SwordVFXRelease:FireServer on swing end (only traffic a swing makes;
      server judges the deflect itself, ParrySuccess* are server->client);
    - ball mesh is NEVER exposed client-side: tracked via workspace.FX
      BallShadow (only moving anchored part, ~94st/s in flight). Timing uses
      shadow XZ distance + closing trend + manual velocity; ball height unknown;
    - game state = require(ReplicatedStorage.Values): GAME_STATE (Started?),
      CURRENT_BALL_ID, PLAYER_ACTIVE_STATE, IS_READY;
    - live parry state = LocalPlayer attribute isDeflecting (bool);
    - HUD: HUD.HolderBottom.ToolbarButtons.{DeflectButton(F), DashButton(Q),
      AbilityButton1..4(keys 1-4)}, each with a Cooldown frame;
    - ReadyZone = Workspace.New Lobby.ReadyArea.ReadyZone (part position);
    - ball spawns = Workspace.ActiveMap.<Map>.BallSpawns.
  Design rules: no CFrame teleports anywhere (walk via Humanoid:MoveTo,
  dash via velocity). All Movement/Parry toggles carry an inline key box
  + T/H mode button on the same line (bindCombo). MODULE_VERSION in About.
]]

return function(api)
  local Tab, Notify = api.Tab, api.Notify
  local MODULE_VERSION = "1.0-deathball"

  local runService = game:GetService("RunService")
  local players = game:GetService("Players")
  local workspace = game:GetService("Workspace")
  local userInput = game:GetService("UserInputService")
  local camera = workspace.CurrentCamera

  --// reload safety: unload a previous copy of this module ----------------
  do
    local g = getgenv and getgenv()
    local prev = g and (g.__HUMA_PLACE or g.__HUMA_DEATHBALL)
    if prev and type(prev.Unload) == "function" then pcall(prev.Unload) end
  end

  local M = {}
  M.version = MODULE_VERSION
  M.flags = {}
  M.errors = {}
  M.binds = { prev = {}, last = {}, tog = {}, hold = {} }
  M.uiState = { mouseFree = false }

  local CONNS = {}
  local function regConn(c) table.insert(CONNS, c) return c end

  local function clamp(v, mn, mx) return math.max(mn, math.min(mx, v)) end
  local function getLocal() return players.LocalPlayer end
  local function getChar() local p = getLocal() return p and p.Character end
  local function getHRP() local c = getChar() return c and c:FindFirstChild("HumanoidRootPart") end
  local function recordError(tag, err)
    M.errors[#M.errors + 1] = tag .. ": " .. tostring(err)
    if #M.errors > 40 then table.remove(M.errors, 1) end
  end
  local function notify(msg)
    pcall(function() Notify("Death Ball", tostring(msg), "info") end)
  end

  local keyCache = {}
  local function keyOf(name)
    if not name or name == "" or name == "none" then return nil end
    local k = keyCache[name]
    if k == nil then
      local ok, kc = pcall(function() return Enum.KeyCode[name] end)
      if (not ok) or kc == nil then -- mouse buttons live on UserInputType
        local ok2, ut = pcall(function() return Enum.UserInputType[name] end)
        kc = (ok2 and ut) or false
      end
      k = kc
      keyCache[name] = k
    end
    if k == false then return nil end
    return k
  end
  local function bindDown(kc) -- pressed state for KeyCode + mouse buttons
    if not kc then return false end
    local okT, et = pcall(function() return kc.EnumType end)
    if okT and et == Enum.UserInputType then
      if kc == Enum.UserInputType.MouseButton1 then
        return userInput:IsMouseButtonPressed(Enum.UserInputType.MouseButton1)
      end
      if kc == Enum.UserInputType.MouseButton2 then
        return userInput:IsMouseButtonPressed(Enum.UserInputType.MouseButton2)
      end
      if kc == Enum.UserInputType.MouseButton3 then
        return userInput:IsMouseButtonPressed(Enum.UserInputType.MouseButton3)
      end
      return false
    end
    return userInput:IsKeyDown(kc)
  end

  local vim = nil
  pcall(function() vim = game:GetService("VirtualInputManager") end)
  local function pressKey(kc)
    if not vim or not kc then return end
    pcall(function() vim:SendKeyEvent(true, kc, false, game) end)
    pcall(function() vim:SendKeyEvent(false, kc, false, game) end)
  end
  local slotKeys = { Enum.KeyCode.One, Enum.KeyCode.Two, Enum.KeyCode.Three, Enum.KeyCode.Four }
  local function pressMouse()
    if not vim then return end
    local vs = camera.ViewportSize
    pcall(function() vim:SendMouseButtonEvent(vs.X / 2, vs.Y / 2, 0, true, game, 1) end)
    pcall(function() vim:SendMouseButtonEvent(vs.X / 2, vs.Y / 2, 0, false, game, 1) end)
  end

  -- --------------------------------------------------------------------------
  -- Live game refs (cached, respawn-safe)
  -- --------------------------------------------------------------------------
  local btnCache, btnCacheT = {}, 0
  local function toolbarBtn(name)
    local now = os.clock()
    if now - btnCacheT > 3 then btnCache, btnCacheT = {}, now end
    if btnCache[name] == nil then
      local b = nil
      pcall(function()
        local lp = getLocal()
        local hud = lp and lp:FindFirstChildOfClass("PlayerGui"):FindFirstChild("HUD")
        local bar = hud and hud:FindFirstChild("ToolbarButtons", true)
        b = bar and bar:FindFirstChild(name) or false
      end)
      btnCache[name] = b
    end
    return btnCache[name] or nil
  end
  local function btnOnCooldown(name)
    local b = toolbarBtn(name)
    if not b then return false end
    local cd = b:FindFirstChild("Cooldown")
    if not cd then return false end
    local ok, vis = pcall(function() return cd.Visible end)
    if ok and vis then return true end
    local ok2, sz = pcall(function() return cd.Size end)
    if ok2 and sz and sz.Y and sz.Y.Scale < 0.99 then return true end
    return false
  end
  local function isDeflecting()
    local lp = getLocal()
    if not lp then return false end
    local ok, v = pcall(function() return lp:GetAttribute("isDeflecting") end)
    return ok and v == true
  end

  -- Ball tracking: the real ball mesh is never exposed client-side (server
  -- only). The game replicates its ground projection as workspace.FX
  -- BallShadow — the only anchored part that moves (verified: 94st in 1s
  -- during flight). All parry timing runs off the shadow: XZ distance,
  -- closing trend, manual velocity.
  local ballCache, ballCacheT = nil, 0
  local function findBall()
    local now = os.clock()
    if ballCache and (now - ballCacheT) < 1.5 then
      if ballCache.Parent then return ballCache end
      ballCache = nil
    end
    ballCacheT = now
    local best, bestSpd = nil, 3
    pcall(function()
      local fx = workspace:FindFirstChild("FX")
      local sh = fx and fx:FindFirstChild("BallShadow")
      if sh and sh:IsA("BasePart") then best = sh end
      if not best then
        for _, d in ipairs(workspace:GetDescendants()) do
          if d:IsA("BasePart") then
            local n = tostring(d.Name):lower()
            if n == "ball" or n:find("death ball", 1, true) then
              local ok, v = pcall(function() return d.AssemblyLinearVelocity end)
              local spd = (ok and v) and v.Magnitude or 0
              if spd >= bestSpd then best, bestSpd = d, spd end
            end
          end
        end
      end
    end)
    ballCache = best
    return best
  end
  local lastBallDist, lastBallPos, lastBallT, smoothSpd = nil, nil, 0, 0
  local function ballThreat(maxDist)
    local ball = findBall()
    local hrp = getHRP()
    if not ball or not hrp then
      lastBallDist, lastBallPos, smoothSpd = nil, nil, 0
      return nil
    end
    local now = os.clock()
    local bp = ball.Position
    local dx, dz = bp.X - hrp.Position.X, bp.Z - hrp.Position.Z
    local d = math.sqrt(dx * dx + dz * dz) -- horizontal: height unknown via shadow
    local closing = lastBallDist ~= nil and d < lastBallDist - 0.05
    lastBallDist = d
    if lastBallPos and now - lastBallT > 0.001 then
      local inst = (bp - lastBallPos).Magnitude / (now - lastBallT)
      smoothSpd = smoothSpd * 0.7 + math.min(inst, 400) * 0.3
    end
    lastBallPos, lastBallT = bp, now
    if d > maxDist then return nil end
    return { ball = ball, dist = d, speed = smoothSpd, closing = closing, hrp = hrp }
  end
  -- Game state via the replicated Values module (round/alive/ready)
  local valuesApi, valuesApiT = nil, 0
  local function gameValues()
    if valuesApi and os.clock() - valuesApiT < 5 then return valuesApi end
    valuesApiT = os.clock()
    pcall(function()
      local v = game:GetService("ReplicatedStorage"):FindFirstChild("Values")
      if v and v:IsA("ModuleScript") then
        local ok, api = pcall(require, v)
        if ok and type(api) == "table" then valuesApi = api end
      end
    end)
    return valuesApi
  end
  local function gameLive()
    local api = gameValues()
    if not api then return findBall() ~= nil end -- fallback: ball presence
    local gs = api.GAME_STATE
    if not gs then return findBall() ~= nil end
    local ok, v = pcall(function()
      if type(gs.Get) == "function" then return gs:Get() end
      return gs.value
    end)
    if not ok then return findBall() ~= nil end
    return tostring(v) == "Started"
  end

  local swingLock = 0
  local function parrySwing()
    if os.clock() - swingLock < 0.22 then return false end
    swingLock = os.clock()
    return pcall(function()
      local rs = game:GetService("ReplicatedStorage")
      local acq = rs:FindFirstChild("_SwordVFXAcquire")
      local rel = rs:FindFirstChild("_SwordVFXRelease")
      if not acq then return false end
      local payload = { tostring(M.flags.db_sword or "Default Katana"), tostring(M.flags.db_finisher or "Go-Fish") }
      acq:InvokeServer(payload)
      task.delay(0.3, function()
        pcall(function() rel:FireServer(payload) end)
      end)
      return true
    end)
  end
  local function faceBall(ballPos)
    local hrp = getHRP()
    if not hrp then return end
    pcall(function()
      hrp.CFrame = CFrame.lookAt(hrp.Position, Vector3.new(ballPos.X, hrp.Position.Y, ballPos.Z))
    end)
  end

  -- --------------------------------------------------------------------------
  -- Anchors (arena / ready zone)
  -- --------------------------------------------------------------------------
  local arenaAnchor, readyAnchor = nil, nil
  local function refreshAnchors()
    pcall(function()
      local am = workspace:FindFirstChild("ActiveMap")
      local sp = am and am:FindFirstChild("BallSpawns", true)
      local p0 = sp and sp:FindFirstChildWhichIsA("BasePart")
      if p0 then arenaAnchor = p0.Position end
    end)
    pcall(function()
      local lob = workspace:FindFirstChild("New Lobby")
      local ra = lob and lob:FindFirstChild("ReadyZone", true)
      local pz = ra and ((ra:IsA("BasePart") and ra) or ra:FindFirstChildWhichIsA("BasePart", true))
      if pz then readyAnchor = pz.Position end
    end)
    if not arenaAnchor then
      local hrp = getHRP()
      if hrp then arenaAnchor = hrp.Position end
    end
  end

  -- --------------------------------------------------------------------------
  -- Movement: noclip / fly (gradual, no teleports)
  -- --------------------------------------------------------------------------
  local noclipApplied = false
  local function setPartsCollide(on)
    local ch = getChar()
    if not ch then return end
    for _, part in ipairs(ch:GetDescendants()) do
      if part:IsA("BasePart") then pcall(function() part.CanCollide = on end) end
    end
  end
  local function updateMovement(dt)
    local cfg = M.flags
    local me = getChar()
    if not me then return end
    local hrp = me:FindFirstChild("HumanoidRootPart")
    if not hrp then return end
    local hum = me:FindFirstChildOfClass("Humanoid")
    local want = cfg.db_noclip or cfg.db_fly
    if want and not noclipApplied then setPartsCollide(false) end
    if not want and noclipApplied then setPartsCollide(true) end
    noclipApplied = want and true or false
    if not want then return end
    if hum then pcall(function() hum:ChangeState(Enum.HumanoidStateType.Flying) end) end
    if cfg.db_fly then
      local speed = cfg.db_fly_speed or 45
      local cf = camera.CFrame
      local fwd = Vector3.new(cf.LookVector.X, 0, cf.LookVector.Z)
      local right = Vector3.new(cf.RightVector.X, 0, cf.RightVector.Z)
      if fwd.Magnitude < 0.01 then fwd = Vector3.new(0, 0, -1) end
      if right.Magnitude < 0.01 then right = Vector3.new(1, 0, 0) end
      fwd, right = fwd.Unit, right.Unit
      local move = Vector3.new()
      if userInput:IsKeyDown(Enum.KeyCode.W) then move = move + fwd end
      if userInput:IsKeyDown(Enum.KeyCode.S) then move = move - fwd end
      if userInput:IsKeyDown(Enum.KeyCode.A) then move = move - right end
      if userInput:IsKeyDown(Enum.KeyCode.D) then move = move + right end
      if userInput:IsKeyDown(Enum.KeyCode.Space) then move = move + Vector3.new(0, 1, 0) end
      if userInput:IsKeyDown(Enum.KeyCode.LeftShift) then move = move + Vector3.new(0, -1, 0) end
      if move.Magnitude > 0.001 then hrp.CFrame = hrp.CFrame + move.Unit * speed * dt end
      pcall(function() hrp.AssemblyLinearVelocity = Vector3.new(0, 0, 0) end)
    else
      pcall(function()
        local v = hrp.AssemblyLinearVelocity
        if v.Y < -1 then hrp.AssemblyLinearVelocity = Vector3.new(v.X, 0, v.Z) end
      end)
    end
  end

  -- --------------------------------------------------------------------------
  -- InfDash (own velocity burst, no game dash remote needed) / AI walk / ready
  -- --------------------------------------------------------------------------
  local dashT = 0
  local function stepDash(dt)
    if not M.flags.db_infdash then return end
    local kc = keyOf(M.flags.db_infdash_key)
    local held = kc and bindDown(kc) or false
    if kc and not held then return end -- key bound: burst only while held
    dashT = dashT + dt
    if dashT < (M.flags.db_dash_cd or 0.8) then return end
    dashT = 0
    local hrp = getHRP()
    local hum = getChar() and getChar():FindFirstChildOfClass("Humanoid")
    if not hrp then return end
    local dir = hum and hum.MoveDirection or Vector3.new()
    if dir.Magnitude < 0.1 then
      dir = Vector3.new(camera.CFrame.LookVector.X, 0, camera.CFrame.LookVector.Z)
    end
    if dir.Magnitude < 0.01 then return end
    local power = M.flags.db_dash_power or 80
    pcall(function()
      hrp.AssemblyLinearVelocity = dir.Unit * power + Vector3.new(0, 5, 0)
    end)
  end

  local aiTarget, aiStuckT, aiLastPos = nil, 0, nil
  local function stepAI(dt)
    if not M.flags.db_aiwalk then aiTarget = nil return end
    if not arenaAnchor then refreshAnchors() end
    if not arenaAnchor then return end
    local hrp = getHRP()
    local hum = getChar() and getChar():FindFirstChildOfClass("Humanoid")
    if not hrp or not hum then return end
    local r = M.flags.db_ai_radius or 40
    if not aiTarget or (hrp.Position - aiTarget).Magnitude < 4 then
      local a = math.random() * math.pi * 2
      local rr = math.random() * r
      aiTarget = arenaAnchor + Vector3.new(math.cos(a) * rr, 0, math.sin(a) * rr)
      aiStuckT, aiLastPos = 0, hrp.Position
    end
    aiStuckT = aiStuckT + dt
    if aiStuckT > 3 then
      if aiLastPos and (hrp.Position - aiLastPos).Magnitude < 2 then
        aiTarget = nil -- stuck: repick next tick
      end
      aiStuckT, aiLastPos = 0, hrp.Position
    end
    pcall(function() hum:MoveTo(aiTarget) end)
  end

  local readyT = 0
  local function stepReady(dt)
    if not M.flags.db_alwaysready then return end
    readyT = readyT + dt
    if readyT < 1 then return end
    readyT = 0
    if gameLive() then return end -- round live: stay and play
    if not readyAnchor then refreshAnchors() end
    if not readyAnchor then return end
    local hrp = getHRP()
    local hum = getChar() and getChar():FindFirstChildOfClass("Humanoid")
    if not hrp or not hum then return end
    if (hrp.Position - readyAnchor).Magnitude > 8 then
      pcall(function() hum:MoveTo(readyAnchor) end)
    end
  end

  -- --------------------------------------------------------------------------
  -- Parry engine
  -- --------------------------------------------------------------------------
  local spamT, infT = 0, 0
  local function stepParry(dt)
    local cfg = M.flags
    -- smart AutoParry: ball close + closing + parry ready
    if cfg.db_autoparry then
      local th = ballThreat(cfg.db_parry_dist or 25)
      if th and (not cfg.db_parry_closing or th.closing) and th.speed >= (cfg.db_min_speed or 0) then
        if not btnOnCooldown("DeflectButton") and not isDeflecting() then
          if cfg.db_face_ball ~= false then faceBall(th.ball.Position) end
          parrySwing()
        end
      end
    end
    -- InfParry: force swings ignoring the client cooldown UI
    if cfg.db_infparry then
      infT = infT + dt
      if infT >= 1 / math.max(cfg.db_inf_rate or 6, 1) then
        infT = 0
        if not isDeflecting() then parrySwing() end
      end
    end
    -- AutoSpam: LMB and/or F through real input
    if cfg.db_autospam then
      spamT = spamT + dt
      if spamT >= 1 / math.max(cfg.db_spam_rate or 8, 1) then
        spamT = 0
        local mode = cfg.db_spam_mode or "Both"
        if mode == "LMB" or mode == "Both" then pressMouse() end
        if mode == "F" or mode == "Both" then pressKey(Enum.KeyCode.F) end
      end
    end
    -- SaveAbility: parry on cooldown + ball incoming -> fire chosen ability slot
    if cfg.db_saveability then
      local slot = clamp(math.floor(cfg.db_save_slot or 1), 1, 4)
      local th = ballThreat(cfg.db_save_dist or 30)
      if th and th.closing and btnOnCooldown("DeflectButton")
        and not btnOnCooldown("AbilityButton" .. slot) then
        pressKey(slotKeys[slot])
      end
    end
  end

  -- --------------------------------------------------------------------------
  -- Camera
  -- --------------------------------------------------------------------------
  local camHome = { fov = 70, maxzoom = 128 }
  pcall(function()
    camHome.fov = camera.FieldOfView or 70
    local pl = getLocal()
    if pl then camHome.maxzoom = pl.CameraMaxZoomDistance or 128 end
  end)
  local function applyCamera()
    pcall(function()
      local fov = clamp((M.flags.db_fov or 70) * (M.flags.db_stretch or 1), 20, 130)
      camera.FieldOfView = fov
      local pl = getLocal()
      if pl then pl.CameraMaxZoomDistance = M.flags.db_maxzoom or 128 end
    end)
  end
  local function restoreCamera()
    pcall(function() camera.FieldOfView = camHome.fov end)
    pcall(function()
      local pl = getLocal()
      if pl then pl.CameraMaxZoomDistance = camHome.maxzoom end
    end)
  end

  -- --------------------------------------------------------------------------
  -- Flags + keybind defs
  -- --------------------------------------------------------------------------
  local defaultFor = {
    db_autoparry = false, db_parry_dist = 25, db_parry_closing = true,
    db_min_speed = 0, db_face_ball = true,
    db_infparry = false, db_inf_rate = 6,
    db_autospam = false, db_spam_rate = 8, db_spam_mode = "Both",
    db_saveability = false, db_save_slot = 1, db_save_dist = 30,
    db_sword = "Default Katana", db_finisher = "Go-Fish",
    db_infdash = false, db_dash_power = 80, db_dash_cd = 0.8,
    db_noclip = false, db_fly = false, db_fly_speed = 45,
    db_aiwalk = false, db_ai_radius = 40,
    db_alwaysready = false,
    db_fov = 70, db_stretch = 1, db_maxzoom = 128,
    bind_autoparry_key = "none", bind_autoparry_mode = "toggle",
    bind_infparry_key = "none", bind_infparry_mode = "toggle",
    bind_autospam_key = "none", bind_autospam_mode = "toggle",
    bind_saveability_key = "none", bind_saveability_mode = "toggle",
    bind_infdash_key = "none", bind_infdash_mode = "toggle",
    bind_noclip_key = "none", bind_noclip_mode = "toggle",
    bind_fly_key = "none", bind_fly_mode = "toggle",
    bind_aiwalk_key = "none", bind_aiwalk_mode = "toggle",
    bind_alwaysready_key = "none", bind_alwaysready_mode = "toggle",
  }
  for k, v in pairs(defaultFor) do
    if M.flags[k] == nil then M.flags[k] = v end
  end

  -- Nova control handles (forward: bind sides sync them)
  local tAP, tIP, tAS, tSA, tDash, tNoclip, tFly, tAI, tReady
  local unloadModule
  local function sideFor(flagKey, getH, label)
    return function(on)
      M.flags[flagKey] = on
      local h = getH()
      if h then h.Set(on) end
      notify(label .. (on and " ON" or " OFF"))
    end
  end
  M.bindDefs = {
    autoparry = { label = "AutoParry", keyflag = "bind_autoparry_key", modflag = "bind_autoparry_mode",
      side = function(on) sideFor("db_autoparry", function() return tAP end, "AutoParry")(on) end },
    infparry = { label = "InfParry", keyflag = "bind_infparry_key", modflag = "bind_infparry_mode",
      side = function(on) sideFor("db_infparry", function() return tIP end, "InfParry")(on) end },
    autospam = { label = "AutoSpam", keyflag = "bind_autospam_key", modflag = "bind_autospam_mode",
      side = function(on) sideFor("db_autospam", function() return tAS end, "AutoSpam")(on) end },
    saveability = { label = "SaveAbility", keyflag = "bind_saveability_key", modflag = "bind_saveability_mode",
      side = function(on) sideFor("db_saveability", function() return tSA end, "SaveAbility")(on) end },
    infdash = { label = "InfDash", keyflag = "bind_infdash_key", modflag = "bind_infdash_mode",
      side = function(on) sideFor("db_infdash", function() return tDash end, "InfDash")(on) end },
    noclip = { label = "Noclip", keyflag = "bind_noclip_key", modflag = "bind_noclip_mode",
      side = function(on) sideFor("db_noclip", function() return tNoclip end, "Noclip")(on) end },
    fly = { label = "Fly", keyflag = "bind_fly_key", modflag = "bind_fly_mode",
      side = function(on) sideFor("db_fly", function() return tFly end, "Fly")(on) end },
    aiwalk = { label = "AI walk", keyflag = "bind_aiwalk_key", modflag = "bind_aiwalk_mode",
      side = function(on) sideFor("db_aiwalk", function() return tAI end, "AI walk")(on) end },
    alwaysready = { label = "Always Ready", keyflag = "bind_alwaysready_key", modflag = "bind_alwaysready_mode",
      side = function(on) sideFor("db_alwaysready", function() return tReady end, "Always Ready")(on) end },
  }

  -- --------------------------------------------------------------------------
  -- Nova UI helpers (flag controls + inline bind combo, Delta/ColdWar style)
  -- --------------------------------------------------------------------------
  local NovaUI = api.Nova
  local function themeColor(key, fb)
    local ok, v = pcall(function() return NovaUI.Theme[key] end)
    if ok and typeof(v) == "Color3" then return v end
    return fb
  end
  local function seedBindFlags()
    local live = (NovaUI and NovaUI.Flags) or {}
    local saved = (NovaUI and NovaUI._loaded) or {}
    for action, def in pairs(M.bindDefs) do
      local v = live["db_" .. def.keyflag]
      if type(v) ~= "string" then v = saved["db_" .. def.keyflag] end
      if type(v) == "string" and v ~= "" then M.flags[def.keyflag] = v end
      local m = live["db_" .. def.modflag]
      if m ~= "toggle" and m ~= "hold" then m = saved["db_" .. def.modflag] end
      if m == "toggle" or m == "hold" then M.flags[def.modflag] = m end
    end
  end
  seedBindFlags()
  local function flagToggle(sec, name, key, desc, tip)
    return sec:Toggle({ Name = name, Desc = desc, Default = M.flags[key] == true,
      Flag = "db_" .. key, Tooltip = tip,
      Callback = function(v) M.flags[key] = v == true end })
  end
  local function flagSlider(sec, name, key, min, max, extra)
    extra = extra or {}
    return sec:Slider({ Name = name, Min = min, Max = max, Default = M.flags[key],
      Decimals = extra.dec or 0, Suffix = extra.suf or "", Flag = "db_" .. key,
      Tooltip = extra.tip,
      Callback = function(v)
        M.flags[key] = tonumber(v) or min
        if extra.camera then applyCamera() end
      end })
  end
  local function flagDropdown(sec, name, key, options, tip)
    return sec:Dropdown({ Name = name, Options = options, Default = M.flags[key],
      Flag = "db_" .. key, Tooltip = tip,
      Callback = function(v) M.flags[key] = tostring(v) end })
  end
  local function bindCombo(toggleHandle, action, keep)
    local def = M.bindDefs[action]
    local row = toggleHandle and toggleHandle.Instance
    if not def or not row then return end
    local keyflag, modflag = def.keyflag, def.modflag
    keep = keep or {}
    local function persistKey(name)
      M.flags[keyflag] = name
      pcall(function() NovaUI.Flags["db_" .. keyflag] = name end)
    end
    local function persistMode(mode)
      M.flags[modflag] = mode
      pcall(function() NovaUI.Flags["db_" .. modflag] = mode end)
    end
    local function keyName()
      local k = keyOf(M.flags[keyflag])
      if not k then return "—" end
      local ok, n = pcall(function() return k.Name end)
      if not ok then return "?" end
      if n == "MouseButton2" then return "RMB" end
      if n == "MouseButton3" then return "MMB" end
      return tostring(n):sub(1, 9)
    end
    local box = Instance.new("TextButton")
    box.Name = "BindBox"
    box.Text = ""
    box.AutoButtonColor = false
    box.BorderSizePixel = 0
    box.BackgroundColor3 = themeColor("Surface", Color3.fromRGB(30, 32, 42))
    box.AnchorPoint = Vector2.new(1, 0.5)
    box.Position = UDim2.new(1, -84, 0.5, 0)
    box.Size = UDim2.fromOffset(58, 24)
    box.Font = Enum.Font.GothamMedium
    box.TextSize = 11
    box.TextColor3 = themeColor("Sub", Color3.fromRGB(150, 160, 180))
    box.ZIndex = 2
    box.Parent = row
    local bc = Instance.new("UICorner")
    bc.CornerRadius = UDim.new(0, 6)
    bc.Parent = box
    local modeBtn = Instance.new("TextButton")
    modeBtn.Name = "BindMode"
    modeBtn.Text = "T"
    modeBtn.AutoButtonColor = false
    modeBtn.BorderSizePixel = 0
    modeBtn.BackgroundColor3 = themeColor("Surface", Color3.fromRGB(30, 32, 42))
    modeBtn.AnchorPoint = Vector2.new(1, 0.5)
    modeBtn.Position = UDim2.new(1, -58, 0.5, 0)
    modeBtn.Size = UDim2.fromOffset(22, 24)
    modeBtn.Font = Enum.Font.GothamMedium
    modeBtn.TextSize = 11
    modeBtn.TextColor3 = themeColor("Sub", Color3.fromRGB(150, 160, 180))
    modeBtn.ZIndex = 2
    modeBtn.Parent = row
    local mc = Instance.new("UICorner")
    mc.CornerRadius = UDim.new(0, 6)
    mc.Parent = modeBtn
    local snap = nil
    local function snapshot()
      snap = {}
      for _, e in ipairs(keep) do snap[e.key] = M.flags[e.key] end
    end
    local function restoreRow()
      if not snap then return end
      for _, e in ipairs(keep) do
        e.h.Set(snap[e.key] == true, true)
        M.flags[e.key] = snap[e.key]
      end
      snap = nil
    end
    local listening = false
    local function refresh()
      box.Text = listening and "…" or keyName()
      modeBtn.Text = (M.flags[modflag] == "hold") and "H" or "T"
    end
    box.InputBegan:Connect(function(inp)
      if inp.UserInputType == Enum.UserInputType.MouseButton1
        or inp.UserInputType == Enum.UserInputType.Touch then
        snapshot()
      end
    end)
    box.MouseButton1Click:Connect(function()
      restoreRow()
      listening = true
      refresh()
    end)
    modeBtn.InputBegan:Connect(function(inp)
      if inp.UserInputType == Enum.UserInputType.MouseButton1
        or inp.UserInputType == Enum.UserInputType.Touch then
        snapshot()
      end
    end)
    modeBtn.MouseButton1Click:Connect(function()
      restoreRow()
      persistMode((M.flags[modflag] == "hold") and "toggle" or "hold")
      refresh()
    end)
    regConn(userInput.InputBegan:Connect(function(inp)
      if not listening then return end
      if inp.UserInputType == Enum.UserInputType.Keyboard then
        local k = inp.KeyCode
        if k == Enum.KeyCode.Escape then
          listening = false
        elseif k == Enum.KeyCode.Backspace or k == Enum.KeyCode.Delete then
          listening = false
          persistKey("none")
        else
          listening = false
          persistKey(k.Name)
        end
        refresh()
      elseif inp.UserInputType == Enum.UserInputType.MouseButton2
        or inp.UserInputType == Enum.UserInputType.MouseButton3 then
        listening = false
        persistKey(inp.UserInputType.Name)
        refresh()
      end
    end))
    refresh()
  end

  -- --------------------------------------------------------------------------
  -- Nova UI: Pages + SubTabs
  -- --------------------------------------------------------------------------
  local pages = {}
  local nav = api.Navigation or Tab:Navigation({ Name = "Death Ball" })
  local menuDefs = {
    { "Parry", "◎", "AutoParry, spam and save ability" },
    { "Movement", "➤", "Dash, noclip, fly, AI walk, auto-ready" },
    { "Visual", "◈", "Camera and bound-keys list" },
    { "About", "i", "Status and unload" },
  }
  for index, def in ipairs(menuDefs) do
    pages[def[1]] = nav:Page({ Id = "db_" .. def[1]:lower(), Name = def[1],
      Icon = def[2], Tooltip = def[3], Order = index })
  end
  pages.Parry:Select()
  local parryTabs = pages.Parry:SubTabs({ { Name = "Auto" }, { Name = "Spam" } })
  local moveTabs = pages.Movement:SubTabs({ { Name = "Move" }, { Name = "Auto" } })
  local visTabs = pages.Visual:SubTabs({ { Name = "Camera" }, { Name = "Binds" } })

  -- PARRY / Auto --
  local apSec = parryTabs.Auto:Section({ Name = "AutoParry" })
  apSec:Paragraph("Swings the moment the ball reaches you (server judges the deflect). Key box on the line.")
  tAP = apSec:Toggle({ Name = "AutoParry", Default = M.flags.db_autoparry == true, Flag = "db_autoparry",
    Callback = function(v) M.flags.db_autoparry = v == true end })
  bindCombo(tAP, "autoparry", { { key = "db_autoparry", h = tAP } })
  flagSlider(apSec, "Parry distance", "db_parry_dist", 8, 60, { suf = " st",
    tip = "Swing when the incoming ball is within this range" })
  flagToggle(apSec, "Only if closing", "db_parry_closing", "Skip balls flying away from you")
  flagSlider(apSec, "Min ball speed", "db_min_speed", 0, 120, { suf = " st/s",
    tip = "Ignore slow balls below this speed" })
  flagToggle(apSec, "Face the ball", "db_face_ball", "Rotate towards the ball before swinging (rotation only)")
  local advSec = parryTabs.Auto:Section({ Name = "Swing payload" })
  advSec:Paragraph("The swing remote carries your sword + finisher names. Captured live values are prefilled — change only if swings stop registering.")
  advSec:TextBox({ Name = "Sword", Default = M.flags.db_sword, Flag = "db_sword",
    Callback = function(v) M.flags.db_sword = tostring(v or "") end })
  advSec:TextBox({ Name = "Finisher", Default = M.flags.db_finisher, Flag = "db_finisher",
    Callback = function(v) M.flags.db_finisher = tostring(v or "") end })
  tIP = advSec:Toggle({ Name = "InfParry", Desc = "Force swings ignoring the client cooldown",
    Default = M.flags.db_infparry == true, Flag = "db_infparry",
    Callback = function(v) M.flags.db_infparry = v == true end })
  bindCombo(tIP, "infparry", { { key = "db_infparry", h = tIP } })
  flagSlider(advSec, "Force rate", "db_inf_rate", 1, 20, { suf = "/s" })

  -- PARRY / Spam --
  local spSec = parryTabs.Spam:Section({ Name = "AutoSpam" })
  spSec:Paragraph("Spams real input (mouse + F). Key box on the line.")
  tAS = spSec:Toggle({ Name = "AutoSpam", Default = M.flags.db_autospam == true, Flag = "db_autospam",
    Callback = function(v) M.flags.db_autospam = v == true end })
  bindCombo(tAS, "autospam", { { key = "db_autospam", h = tAS } })
  flagDropdown(spSec, "Spam what", "db_spam_mode", { "Both", "LMB", "F" })
  flagSlider(spSec, "Rate", "db_spam_rate", 1, 20, { suf = "/s" })
  local svSec = parryTabs.Spam:Section({ Name = "SaveAbility" })
  svSec:Paragraph("Parry on cooldown + ball incoming → fires your chosen ability slot (1-4) once per approach.")
  tSA = svSec:Toggle({ Name = "SaveAbility", Default = M.flags.db_saveability == true, Flag = "db_saveability",
    Callback = function(v) M.flags.db_saveability = v == true end })
  bindCombo(tSA, "saveability", { { key = "db_saveability", h = tSA } })
  svSec:Slider({ Name = "Slot", Min = 1, Max = 4, Default = M.flags.db_save_slot or 1,
    Decimals = 0, Suffix = "", Flag = "db_save_slot",
    Tooltip = "Which ability button (1-4) is the saver",
    Callback = function(v) M.flags.db_save_slot = clamp(math.floor(tonumber(v) or 1), 1, 4) end })
  flagSlider(svSec, "Trigger distance", "db_save_dist", 10, 60, { suf = " st" })

  -- MOVEMENT / Move --
  local mvSec = moveTabs.Move:Section({ Name = "Move" })
  tDash = mvSec:Toggle({ Name = "InfDash", Desc = "Velocity burst, key held = repeat",
    Default = M.flags.db_infdash == true, Flag = "db_infdash",
    Callback = function(v) M.flags.db_infdash = v == true end })
  bindCombo(tDash, "infdash", { { key = "db_infdash", h = tDash } })
  flagSlider(mvSec, "Dash power", "db_dash_power", 30, 160, { suf = " st/s" })
  flagSlider(mvSec, "Burst delay", "db_dash_cd", 0.2, 2, { dec = 1, suf = "s" })
  tNoclip = mvSec:Toggle({ Name = "Noclip", Desc = "Walls, no fall",
    Default = M.flags.db_noclip == true, Flag = "db_noclip",
    Callback = function(v) M.flags.db_noclip = v == true end })
  bindCombo(tNoclip, "noclip", { { key = "db_noclip", h = tNoclip } })
  tFly = mvSec:Toggle({ Name = "Fly", Desc = "WASD + Space up / Shift down",
    Default = M.flags.db_fly == true, Flag = "db_fly",
    Callback = function(v) M.flags.db_fly = v == true end })
  bindCombo(tFly, "fly", { { key = "db_fly", h = tFly } })
  flagSlider(mvSec, "Fly speed", "db_fly_speed", 10, 200, { suf = " st/s" })

  -- MOVEMENT / Auto --
  local aiSec = moveTabs.Auto:Section({ Name = "AI walk" })
  aiSec:Paragraph("Wanders around the arena anchor (BallSpawns). Pure MoveTo, no teleports.")
  tAI = aiSec:Toggle({ Name = "AI walk", Default = M.flags.db_aiwalk == true, Flag = "db_aiwalk",
    Callback = function(v) M.flags.db_aiwalk = v == true end })
  bindCombo(tAI, "aiwalk", { { key = "db_aiwalk", h = tAI } })
  flagSlider(aiSec, "Wander radius", "db_ai_radius", 10, 120, { suf = " st" })
  local rdSec = moveTabs.Auto:Section({ Name = "Auto-ready" })
  rdSec:Paragraph("No ball in play → walks to the lobby ReadyZone for the next match.")
  tReady = rdSec:Toggle({ Name = "Always Ready", Default = M.flags.db_alwaysready == true, Flag = "db_alwaysready",
    Callback = function(v) M.flags.db_alwaysready = v == true end })
  bindCombo(tReady, "alwaysready", { { key = "db_alwaysready", h = tReady } })

  -- VISUAL / Camera --
  local camSec = visTabs.Camera:Section({ Name = "Camera" })
  flagSlider(camSec, "FOV", "db_fov", 40, 120, { camera = true })
  flagSlider(camSec, "Stretch", "db_stretch", 1, 1.6,
    { dec = 2, tip = "Wide-screen stretch feel: multiplies the FOV", camera = true })
  flagSlider(camSec, "Max zoom", "db_maxzoom", 20, 400, { suf = " st", camera = true })

  -- VISUAL / Binds: live list of bound keys + states --
  local blSec = visTabs.Binds:Section({ Name = "Bound keys" })
  blSec:Paragraph("Every Movement/Parry key in one place. Click a toggle line to rebind.")
  local bindsLbl = blSec:Label("…")
  local function keyText(action)
    local def = M.bindDefs[action]
    if not def then return "—" end
    local k = keyOf(M.flags[def.keyflag])
    if not k then return "—" end
    local ok, n = pcall(function() return k.Name end)
    if not ok then return "?" end
    if n == "MouseButton2" then return "RMB" end
    if n == "MouseButton3" then return "MMB" end
    return tostring(n)
  end
  local bindsRows = {
    { "autoparry", "AutoParry", "db_autoparry" },
    { "infparry", "InfParry", "db_infparry" },
    { "autospam", "AutoSpam", "db_autospam" },
    { "saveability", "SaveAbility", "db_saveability" },
    { "infdash", "InfDash", "db_infdash" },
    { "noclip", "Noclip", "db_noclip" },
    { "fly", "Fly", "db_fly" },
    { "aiwalk", "AI walk", "db_aiwalk" },
    { "alwaysready", "Always Ready", "db_alwaysready" },
  }
  local function refreshBinds()
    local lines = {}
    for _, r in ipairs(bindsRows) do
      lines[#lines + 1] = r[2] .. " [" .. keyText(r[1]) .. "]: "
        .. (M.flags[r[3]] and "ON" or "off")
    end
    pcall(function() bindsLbl.Set(table.concat(lines, "\n")) end)
  end

  -- ABOUT --
  local aboutSec = pages.About:Section({ Name = "About" })
  aboutSec:Label("DEATH BALL - hub module v" .. MODULE_VERSION)
  aboutSec:Paragraph("Parry swings via the real swing remote · no teleports · camera + binds. Persistence via hub Settings → Config.")
  aboutSec:Button({ Name = "Unload module", Variant = "danger", Callback = function()
    unloadModule()
  end })

  -- --------------------------------------------------------------------------
  -- Hotkeys dispatcher + render loop
  -- --------------------------------------------------------------------------
  local function initKeys()
    local lastAlt, lastCtrl = 0, 0
    regConn(runService.Heartbeat:Connect(function()
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
      end
      for action, def in pairs(M.bindDefs) do
        local kc = keyOf(M.flags[def.keyflag])
        if kc then
          local down = bindDown(kc)
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

  local bindsT = 0
  local function beginRender()
    regConn(runService.RenderStepped:Connect(function(dt)
      camera = workspace.CurrentCamera or camera
      do local ok, e = pcall(stepParry, dt) if not ok then recordError("parry", e) end end
      do local ok, e = pcall(stepDash, dt) if not ok then recordError("dash", e) end end
      do local ok, e = pcall(updateMovement, dt) if not ok then recordError("move", e) end end
      do local ok, e = pcall(stepAI, dt) if not ok then recordError("ai", e) end end
      do local ok, e = pcall(stepReady, dt) if not ok then recordError("ready", e) end end
      bindsT = bindsT + dt
      if bindsT > 0.5 then bindsT = 0 do local ok, e = pcall(refreshBinds) if not ok then recordError("binds", e) end end end
      if M.uiState.mouseFree then
        do local ok, e = pcall(function()
          userInput.MouseBehavior = Enum.MouseBehavior.Default
        end) if not ok then recordError("mouse", e) end end
      end
    end))
  end

  -- --------------------------------------------------------------------------
  -- Unload + boot
  -- --------------------------------------------------------------------------
  unloadModule = function()
    for _, c in ipairs(CONNS) do pcall(function() c:Disconnect() end) end
    for _, page in pairs(pages) do pcall(function() page:Destroy() end) end
    pcall(function() setPartsCollide(true) end)
    pcall(restoreCamera)
    local g = getgenv and getgenv()
    if g then
      if g.__HUMA_PLACE and g.__HUMA_PLACE.Unload == unloadModule then g.__HUMA_PLACE = nil end
      if g.__HUMA_DEATHBALL and g.__HUMA_DEATHBALL.Unload == unloadModule then g.__HUMA_DEATHBALL = nil end
    end
    notify("Death Ball module unloaded")
  end

  refreshAnchors()
  applyCamera()
  beginRender()
  initKeys()
  refreshBinds()

  local hub = { Unload = unloadModule }
  if getgenv then pcall(function()
    getgenv().__HUMA_DEATHBALL = hub
    getgenv().__HUMA_PLACE = hub -- generic contract: hub unloads the place module
  end) end

  notify("Death Ball loaded v" .. MODULE_VERSION .. " — Alt frees the mouse")
  print("[huma-deathball] place module loaded v" .. MODULE_VERSION)
end
