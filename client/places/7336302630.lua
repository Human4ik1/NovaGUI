--[[
  HumaHub place module — Project Delta (PlaceId 7336302630).
  Repo path: client/places/7336302630.lua

  SAFE BY DESIGN (this place bans for behavior):
    - eyes only: Drawing ESP, Highlight chams, camera aimbot. Nothing here
      touches movement, humanoid props, remotes, packets, metatables or
      game scripts/UIs — there is nothing server-side to fingerprint.
    - NO fly / noclip / teleport / speed / autofire / rage on purpose.
    - aim defaults are legit-ish (smooth, small FOV, hold-to-aim, visible
      check, pause while the hub is open). Snapping 180 deg across the map is
      still YOUR choice — and still detectable. Play sane.
  Place facts (verified live):
    - no teams (everyone else is hostile), R15, 100hp;
    - characters live as Workspace.<PlayerName> (pl.Character works too);
    - NPC traders/bosses are Workspace models with a Humanoid;
    - corpses = models with a dead Humanoid (stay lootable);
    - loot: Workspace.Containers / DroppedItems / QuestItems /
      NoCollision.LootSpawns (dynamic — scanned on a timer);
    - exits: Workspace.NoCollision.ExitLocations.Exit parts;
    - equipped gun: Holstered.Item* values or Render.Holding.
]]

return function(api)
  local Tab, Notify = api.Tab, api.Notify

  local runService = game:GetService("RunService")
  local players = game:GetService("Players")
  local workspace = game:GetService("Workspace")
  local userInput = game:GetService("UserInputService")
  local camera = workspace.CurrentCamera
  local LP = players.LocalPlayer
  local rayParams = RaycastParams.new()

  --// reload safety --------------------------------------------------------
  do
    local g = getgenv and getgenv()
    local prev = g and (g.__HUMA_PLACE or g.__HUMA_DELTA)
    if prev and type(prev.Unload) == "function" then pcall(prev.Unload) end
  end

  local F = {
    esp_box = false, esp_health = false, esp_tracer = false,
    esp_name = true, esp_dist = true, esp_weapon = true,
    esp_thick = 2, esp_range = 4000,
    esp_enemy = Color3.fromRGB(255, 90, 90),
    aim_on = false, aim_part = "Head", aim_fov = 15, aim_smooth = 65,
    aim_hold = "right", aim_prio = "closest", aim_vis = true,
    aim_circle = true, aim_pause = true, aim_delay = 0.1,
    glow_on = false, glow_npc = false, glow_corpse = false, glow_top = true,
    glow_vis = true, glow_viscol = Color3.fromRGB(255, 255, 255), glow_visthick = 3,
    glow_enemy = Color3.fromRGB(255, 90, 90),
    glow_npc_c = Color3.fromRGB(150, 160, 170),
    glow_corpse_c = Color3.fromRGB(255, 150, 40),
    loot_cont = true, loot_drop = true, loot_quest = true,
    loot_hl = true, loot_keys = "card,key,defib,ledx,bitcoin,gpu,military, thermal, red, violet, gold",
    loot_col = Color3.fromRGB(120, 220, 255),
    loot_hlcol = Color3.fromRGB(255, 210, 90),
    loot_range = 1500,
    corpse_on = true, corpse_ai = true,
    corpse_col = Color3.fromRGB(255, 150, 40),
    corpse_ai_col = Color3.fromRGB(200, 170, 60),
    corpse_range = 2500,
    npc_on = true, npc_col = Color3.fromRGB(150, 160, 170), npc_range = 2500,
    exit_on = true, exit_col = Color3.fromRGB(110, 230, 130), exit_range = 4000,
    radar_on = false, radar_range = 800, radar_size = 170,
  }

  local CONNS = {}
  local function reg(c) table.insert(CONNS, c) return c end
  local unloadModule -- fwd (About button runs at click-time)

  local function clamp(v, a, b)
    if v < a then return a elseif v > b then return b end
    return v
  end

  -- --------------------------------------------------------------------------
  -- Drawing recycle (per-frame)
  -- --------------------------------------------------------------------------
  local shapes, prevShapes = {}, {}
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
    shapes[#shapes + 1] = s
    s.Visible = true
    return s
  end
  local function frameBegin()
    for _, s in ipairs(prevShapes) do pcall(function() s:Remove() end) end
    prevShapes = shapes
    shapes = {}
  end

  -- --------------------------------------------------------------------------
  -- World helpers
  -- --------------------------------------------------------------------------
  local function myChar()
    local ch = LP.Character
    if ch and ch.Parent then return ch end
    return workspace:FindFirstChild(LP.Name)
  end
  local function myHRP()
    local ch = myChar()
    return ch and ch:FindFirstChild("HumanoidRootPart")
  end
  local function wts(pos)
    local v = camera:WorldToViewportPoint(pos)
    return Vector2.new(v.X, v.Y), v.Z > 0, v.Z
  end
  -- NaN/inf sanitizer: ragdolls, vehicles and camera-plane projections can
  -- produce non-finite coords; a single bad Vector2 aborts the whole frame
  -- (silently, inside pcall) and kills ESP/glow for everyone after it.
  local function fin(x, fb)
    if type(x) ~= "number" or x ~= x then return fb or 0 end
    if x == math.huge then return 1e6 end
    if x == -math.huge then return -1e6 end
    return x
  end
  local function V2(x, y) return Vector2.new(fin(x), fin(y)) end
  -- per-section error counters (see About debug line): silence with telemetry
  local dbg = { fps = 0, frames = 0, fpsT = 0, err = {}, last = "" }
  local function guarded(sec, fn)
    local ok, e = pcall(fn)
    if not ok then
      dbg.err[sec] = (dbg.err[sec] or 0) + 1
      dbg.last = sec .. ": " .. tostring(e):sub(1, 90)
    end
  end
  local function boxOf(model)
    local ok, cf, size = pcall(function() return model:GetBoundingBox() end)
    if ok and cf and size then return cf, size end
    return nil, nil
  end
  -- true when a rect is at least partly on screen (with margin)
  local function onScreen2(x0, y0, w, h, vs, m)
    m = m or 80
    return x0 + w > -m and x0 < vs.X + m and y0 + h > -m and y0 < vs.Y + m
  end
  local function isVisible(from, to, ignoreChar, force)
    if not force and not F.aim_vis then return true end
    local ignore = {}
    local me = myChar()
    if me then ignore[#ignore + 1] = me end
    if ignoreChar then ignore[#ignore + 1] = ignoreChar end
    ignore[#ignore + 1] = camera
    local ok, hit = pcall(function()
      rayParams.FilterDescendantsInstances = ignore
      rayParams.FilterType = Enum.RaycastFilterType.Exclude
      rayParams.IgnoreWater = true
      return workspace:Raycast(from, to - from, rayParams)
    end)
    if not ok then return true end
    return hit == nil
  end
  local function gunName(model)
    local hol = model:FindFirstChild("Holstered")
    if hol then
      for _, o in ipairs(hol:GetChildren()) do
        local ok, v = pcall(function() return o.Value end)
        if ok and v ~= nil and tostring(v) ~= "" and tostring(v) ~= "nil" then
          return tostring(v)
        end
      end
    end
    local rend = model:FindFirstChild("Render")
    local holding = rend and rend:FindFirstChild("Holding")
    if holding then
      local ok, v = pcall(function() return holding.Value end)
      if ok and v ~= nil and tostring(v) ~= "" then return tostring(v) end
    end
    return nil
  end
  local function isPlayerModel(model)
    return players:FindFirstChild(model.Name) ~= nil
  end

  -- --------------------------------------------------------------------------
  -- Cached slow scans (loot / corpses / npc / exits) — 2s timer
  -- --------------------------------------------------------------------------
  local lootCache, corpseCache, npcCache, exitCache = {}, {}, {}, {}
  local scanTick = 0
  local syncLabelMaps -- fwd: defined below scanWorld, runs on ticks
  local function hlKeys()
    local out = {}
    for k in tostring(F.loot_keys or ""):gmatch("[^,]+") do
      k = k:gsub("^%s+", ""):gsub("%s+$", ""):lower()
      if k ~= "" then table.insert(out, k) end
    end
    return out
  end
  local function scanWorld()
    lootCache, corpseCache, npcCache, exitCache = {}, {}, {}, {}
    local keys = hlKeys()
    local function lootKindOf(model)
      local p = model
      while p and p ~= workspace do
        local n = p.Name
        if n == "DroppedItems" then return "drop" end
        if n == "Containers" then return "cont" end
        if n == "QuestItems" then return "quest" end
        if n == "LootSpawns" then return "spawn" end
        p = p.Parent
      end
      return nil
    end
    local roots = {}
    for _, n in ipairs({ "Containers", "DroppedItems", "QuestItems" }) do
      local f = workspace:FindFirstChild(n)
      if f then table.insert(roots, f) end
    end
    local nc = workspace:FindFirstChild("NoCollision")
    local ls = nc and nc:FindFirstChild("LootSpawns")
    if ls then table.insert(roots, ls) end
    for _, root in ipairs(roots) do
      local ok, desc = pcall(function() return root:GetDescendants() end)
      if ok then
        for _, v in ipairs(desc) do
          if v:IsA("Model") then
            local cf, size = boxOf(v)
            if cf and size and size.Magnitude > 0.5 then
              local kind = lootKindOf(v) or "drop"
              local nm = v.Name
              local star = false
              if F.loot_hl then
                local ln = string.lower(nm)
                for _, k in ipairs(keys) do
                  if string.find(ln, k, 1, true) then star = true break end
                end
              end
              table.insert(lootCache, { pos = cf.Position, name = nm, kind = kind, star = star, m = v })
            end
          end
        end
      end
    end
    -- corpses + npc: workspace models with a Humanoid that are not live chars
    local liveChars = {}
    for _, pl in ipairs(players:GetPlayers()) do
      local ch = pl.Character
      if ch then liveChars[ch] = true end
    end
    for _, v in ipairs(workspace:GetChildren()) do
      if v:IsA("Model") then
        local hum = v:FindFirstChildOfClass("Humanoid")
        if hum then
          if hum.Health <= 0 then
            local cf = select(1, boxOf(v))
            table.insert(corpseCache, {
              pos = cf and cf.Position or nil,
              name = v.Name, isPlayer = isPlayerModel(v), m = v,
            })
          elseif not liveChars[v] and not isPlayerModel(v) then
            -- NPC trader/boss (has HP, nobody's character)
            local hrp = v:FindFirstChild("HumanoidRootPart")
            if hrp then
              table.insert(npcCache, { model = v, hrp = hrp, hum = hum, name = v.Name })
            end
          end
        end
      end
    end
    local ex = nc and nc:FindFirstChild("ExitLocations")
    if ex then
      for _, v in ipairs(ex:GetChildren()) do
        if v:IsA("BasePart") then
          table.insert(exitCache, { pos = v.Position, name = v.Name, part = v })
        end
      end
    end
    syncLabelMaps()
  end

  -- persistent label objects (zero per-frame allocation): created on
  -- discovery during scans, updated per frame, destroyed when gone
  local lootMap, corpseMap, npcMap, exitMap = {}, {}, {}, {}
  local function mkLabel(size)
    local t = shape("Text")
    t.Center = true; t.Outline = true; t.Transparency = 0
    t.Size = size or 12; t.Visible = false
    return t
  end
  local function killDraw(o) pcall(function() o:Remove() end) end
  function syncLabelMaps()
    local seenL, seenC, seenN, seenE = {}, {}, {}, {}
    for _, it in ipairs(lootCache) do
      local m = it.m
      if m and m.Parent then
        seenL[m] = true
        if not lootMap[m] then lootMap[m] = { lbl = mkLabel(12) } end
        it.lbl = lootMap[m].lbl
      else
        it.lbl = nil
      end
    end
    for _, c in ipairs(corpseCache) do
      local m = c.m
      if m and m.Parent then
        seenC[m] = true
        if not corpseMap[m] then corpseMap[m] = { lbl = mkLabel(13) } end
        c.lbl = corpseMap[m].lbl
      else
        c.lbl = nil
      end
    end
    for _, npc in ipairs(npcCache) do
      local m = npc.model
      if m and m.Parent then
        seenN[m] = true
        if not npcMap[m] then npcMap[m] = { lbl = mkLabel(12) } end
        npc.lbl = npcMap[m].lbl
      else
        npc.lbl = nil
      end
    end
    for _, e in ipairs(exitCache) do
      local p = e.part
      if p and p.Parent then
        seenE[p] = true
        if not exitMap[p] then exitMap[p] = { lbl = mkLabel(14) } end
        e.lbl = exitMap[p].lbl
      else
        e.lbl = nil
      end
    end
    for m, o in pairs(lootMap) do if not seenL[m] then killDraw(o.lbl) lootMap[m] = nil end end
    for m, o in pairs(corpseMap) do if not seenC[m] then killDraw(o.lbl) corpseMap[m] = nil end end
    for m, o in pairs(npcMap) do if not seenN[m] then killDraw(o.lbl) npcMap[m] = nil end end
    for p, o in pairs(exitMap) do if not seenE[p] then killDraw(o.lbl) exitMap[p] = nil end end
  end

  -- --------------------------------------------------------------------------
  -- Glow
  -- --------------------------------------------------------------------------
  local glowMap = {}
  local function setGlow(model, col, on, tag)
    if not model or not model.Parent then return end
    local key = tostring(tag) .. "_" .. model:GetDebugId()
    local prev = glowMap[key]
    if not on then
      if prev then pcall(function() prev:Destroy() end) end
      glowMap[key] = nil
      return
    end
    if prev and prev.Parent then
      if prev.FillColor ~= col then prev.FillColor = col end
      return
    end
    local ok, hl = pcall(function()
      local h = Instance.new("Highlight")
      h.Name = "BodyFX"
      h.Adornee = model
      h.FillColor = col
      h.FillTransparency = 0.35
      h.OutlineColor = Color3.new(1, 1, 1)
      h.OutlineTransparency = 0.4
      h.DepthMode = F.glow_top and Enum.HighlightDepthMode.AlwaysOnTop
        or Enum.HighlightDepthMode.Occluded
      h.Parent = model
      return h
    end)
    glowMap[key] = (ok and hl) or nil
  end
  local function gcGlow(seen)
    for k, h in pairs(glowMap) do
      if not seen[k] then
        pcall(function() h:Destroy() end)
        glowMap[k] = nil
      end
    end
  end

  -- --------------------------------------------------------------------------
  -- Persistent player rigs (universal-style): objects are created ONCE per
  -- player and only repositioned per frame — zero per-frame allocation, so
  -- executor Drawing throttles/rate quirks cannot blank the ESP.
  -- --------------------------------------------------------------------------
  local pesc = {}
  local function mkSq(fill)
    local s = shape("Square")
    pcall(function()
      s.Filled = fill == true
      s.Visible = false
    end)
    return s
  end
  local function mkTx(size)
    local t = shape("Text")
    pcall(function()
      t.Center = true
      t.Outline = true
      t.Transparency = 0
      t.Size = size or 13
      t.Visible = false
    end)
    return t
  end
  local function mkLn()
    local l = shape("Line")
    pcall(function()
      l.Transparency = 0
      l.Visible = false
    end)
    return l
  end
  local function rigOf(plr)
    local e = pesc[plr]
    if e then return e end
    e = { corners = {} }
    e.outline = mkSq(false)
    e.box = mkSq(false)
    e.hback = mkSq(true)
    e.hfill = mkSq(true)
    e.name = mkTx(13)
    e.weapon = mkTx(12)
    e.trace = mkLn()
    for i = 1, 8 do e.corners[i] = mkLn() end
    pesc[plr] = e
    return e
  end
  local function hideRig(e)
    if not e then return end
    for _, k in ipairs({ "outline", "box", "hback", "hfill", "name", "weapon", "trace" }) do
      local o = e[k]
      if o then pcall(function() o.Visible = false end) end
    end
    if e.corners then
      for _, l in ipairs(e.corners) do pcall(function() l.Visible = false end) end
    end
  end
  local function freeRig(plr)
    local e = pesc[plr]
    if not e then return end
    for _, k in ipairs({ "outline", "box", "hback", "hfill", "name", "weapon", "trace" }) do
      local o = e[k]
      if o then pcall(function() o:Remove() end) end
    end
    if e.corners then
      for _, l in ipairs(e.corners) do pcall(function() l:Remove() end) end
    end
    pesc[plr] = nil
  end
  reg(players.PlayerRemoving:Connect(function(plr) freeRig(plr) end))

  -- --------------------------------------------------------------------------
  -- Aim state
  -- --------------------------------------------------------------------------
  local aimCur, aimOn, aimSince, aimLastPos = nil, false, 0, nil
  local function aimPoint(model, part)
    local inst = (part == "Head" and model:FindFirstChild("Head"))
      or (part == "UpperTorso" and model:FindFirstChild("UpperTorso"))
      or model:FindFirstChild("HumanoidRootPart")
    if inst and inst:IsA("BasePart") then return inst.Position end
    local hrp = model:FindFirstChild("HumanoidRootPart")
    return hrp and hrp.Position or nil
  end
  local function hubOpen()
    local ok, vis = pcall(function() return api.Win:IsVisible() end)
    return ok and vis or false
  end

  -- --------------------------------------------------------------------------
  -- Status line
  -- --------------------------------------------------------------------------
  local statLbl, dbgLbl
  local statTick, nP, nC, nL = 0, 0, 0, 0

  -- --------------------------------------------------------------------------
  -- Main loop (silent by design: uncaught per-frame errors are observable)
  -- --------------------------------------------------------------------------
  reg(runService.RenderStepped:Connect(function(dt)
    pcall(function()
      camera = workspace.CurrentCamera or camera
      if not camera then return end
      frameBegin()
      local now = os.clock()
      dbg.frames = dbg.frames + 1
      if now - dbg.fpsT >= 1 then
        dbg.fps = math.floor(dbg.frames / math.max(now - dbg.fpsT, 0.01) + 0.5)
        dbg.frames, dbg.fpsT = 0, now
      end
      if now - scanTick > 2 then
        scanTick = now
        pcall(scanWorld)
      end

      local me = myChar()
      local meHRP = me and me:FindFirstChild("HumanoidRootPart")
      local vs = camera.ViewportSize
      local seenGlow = {}
      nP, nC, nL = 0, 0, 0

      -- players (persistent rigs: props updated, hidden when invalid)
      if meHRP then
        for _, pl in ipairs(players:GetPlayers()) do
          if pl ~= LP then
            guarded("players", function()
              local e = rigOf(pl)
              local ch = pl.Character
              if not ch or not ch.Parent then ch = workspace:FindFirstChild(pl.Name) end
              local hum = ch and ch:FindFirstChildOfClass("Humanoid")
              local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
              if not (ch and hum and hum.Health > 0 and hrp) then hideRig(e) return end
              local d = (meHRP.Position - hrp.Position).Magnitude
              if d ~= d or d > F.esp_range then hideRig(e) return end
              nP = nP + 1
              -- glow FIRST (presence beats decoration)
              if F.glow_on then
                local key = "p_" .. ch:GetDebugId()
                setGlow(ch, F.glow_enemy, true, "p")
                seenGlow[key] = true
              end
              local cf, size = boxOf(ch)
              if not (cf and size) then hideRig(e) return end
              local top3 = cf.Position + Vector3.new(0, size.Y / 2, 0)
              local bot3 = cf.Position - Vector3.new(0, size.Y / 2, 0)
              local t2, tOn = wts(top3)
              local b2, bOn = wts(bot3)
              if not (tOn or bOn) then hideRig(e) return end
              local h = math.max(math.abs(b2.Y - t2.Y), 8)
              local w = math.max(h * 0.55, 8)
              local cx = (t2.X + b2.X) / 2
              local x0, y0 = cx - w / 2, math.min(t2.Y, b2.Y)
              if not onScreen2(x0, y0, w, h, vs, 120) then hideRig(e) return end
              local col = F.esp_enemy
              local th = F.esp_thick or 2
              local dm = math.floor(d + 0.5) .. "m"
              e.outline.Visible = F.esp_box == true
              if e.outline.Visible then
                e.outline.Color = Color3.new(0, 0, 0)
                e.outline.Thickness = th + 2
                e.outline.Position = V2(x0 - 1, y0 - 1)
                e.outline.Size = V2(w + 2, h + 2)
              end
              e.box.Visible = F.esp_box == true
              if e.box.Visible then
                e.box.Color = col
                e.box.Thickness = th
                e.box.Position = V2(x0, y0)
                e.box.Size = V2(w, h)
              end
              -- visible outline: fat corners ONLY when not behind a wall
              local showVis = F.glow_vis
                and isVisible(camera.CFrame.Position, hrp.Position, ch, true)
              if showVis then
                local L = clamp(math.min(w, h) * 0.28, 5, 26)
                local vt = F.glow_visthick or 3
                local pts = {
                  { V2(x0, y0 + L), V2(x0, y0) },
                  { V2(x0, y0), V2(x0 + L, y0) },
                  { V2(x0 + w - L, y0), V2(x0 + w, y0) },
                  { V2(x0 + w, y0), V2(x0 + w, y0 + L) },
                  { V2(x0, y0 + h - L), V2(x0, y0 + h) },
                  { V2(x0, y0 + h), V2(x0 + L, y0 + h) },
                  { V2(x0 + w - L, y0 + h), V2(x0 + w, y0 + h) },
                  { V2(x0 + w, y0 + h), V2(x0 + w, y0 + h - L) },
                }
                for i = 1, 8 do
                  local ln = e.corners[i]
                  ln.Visible = true
                  ln.From = pts[i][1]
                  ln.To = pts[i][2]
                  ln.Color = F.glow_viscol
                  ln.Thickness = vt
                end
              else
                for i = 1, 8 do e.corners[i].Visible = false end
              end
              local showHp = F.esp_health and hum.MaxHealth > 0
              e.hback.Visible = showHp
              e.hfill.Visible = showHp
              if showHp then
                local frac = clamp(hum.Health / hum.MaxHealth, 0, 1)
                e.hback.Color = Color3.new(0, 0, 0)
                e.hback.Thickness = th
                e.hback.Position = V2(x0 - 7, y0)
                e.hback.Size = V2(3, h)
                e.hfill.Color = Color3.new(1 - frac, frac * 0.9, 0.15)
                e.hfill.Thickness = th
                e.hfill.Position = V2(x0 - 7, y0 + h * (1 - frac))
                e.hfill.Size = V2(3, math.max(h * frac, 1))
              end
              e.trace.Visible = F.esp_tracer == true
              if e.trace.Visible then
                e.trace.Color = col
                e.trace.Thickness = 1
                e.trace.Transparency = 0.6
                e.trace.From = V2(vs.X / 2, vs.Y)
                e.trace.To = V2(cx, y0 + h)
              end
              local showNm = F.esp_name or F.esp_dist
              e.name.Visible = showNm
              if showNm then
                local parts = {}
                if F.esp_name then table.insert(parts, pl.Name) end
                if F.esp_dist then table.insert(parts, dm) end
                e.name.Text = table.concat(parts, "  ")
                e.name.Color = col
                e.name.Position = V2(cx, y0 - 16)
              end
              local g = F.esp_weapon and gunName(ch) or nil
              e.weapon.Visible = g ~= nil
              if g then
                e.weapon.Text = g
                e.weapon.Color = Color3.new(1, 1, 1)
                e.weapon.Position = V2(cx, y0 + h + 3)
              end
            end)
          end
        end
      end

      -- npc (traders/bosses)
      if F.npc_on and meHRP then
        guarded("npc", function()
          for _, npc in ipairs(npcCache) do
            local m = npc.model
            local L = npc.lbl
            if L then L.Visible = false end
            if m and m.Parent and npc.hum.Health > 0 then
              local d = (meHRP.Position - npc.hrp.Position).Magnitude
              if d == d and d <= F.npc_range then
                local cf, size = boxOf(m)
                if cf and size then
                  local t2, tOn = wts(cf.Position + Vector3.new(0, size.Y / 2, 0))
                  if tOn and L then
                    L.Text = npc.name .. "  " .. math.floor(d + 0.5) .. "m"
                    L.Color = F.npc_col
                    L.Position = V2(t2.X, t2.Y - 8)
                    L.Visible = true
                  end
                end
                if F.glow_npc then
                  local key = "n_" .. m:GetDebugId()
                  setGlow(m, F.npc_col, true, "n")
                  seenGlow[key] = true
                end
              end
            end
          end
        end)
      end

      -- corpses
      if F.corpse_on and meHRP then
        guarded("corpse", function()
          for _, c in ipairs(corpseCache) do
            local L = c.lbl
            if L then L.Visible = false end
            if c.pos and L then
              local showAI = c.isPlayer or F.corpse_ai
              if showAI then
                local d = (meHRP.Position - c.pos).Magnitude
                if d == d and d <= F.corpse_range then
                  nC = nC + 1
                  local col = c.isPlayer and F.corpse_col or F.corpse_ai_col
                  local sp, on = wts(c.pos + Vector3.new(0, 1, 0))
                  if on then
                    local tag = (c.isPlayer and "[BODY] " or "[AI] ") .. c.name
                    L.Text = tag .. "  " .. math.floor(d + 0.5) .. "m"
                    L.Color = col
                    L.Position = V2(sp.X, sp.Y)
                    L.Visible = true
                  end
                end
              end
            end
          end
        end)
      else
        for _, c in ipairs(corpseCache) do
          if c.lbl then c.lbl.Visible = false end
        end
      end
      if F.glow_corpse and meHRP then
        guarded("corpseGlow", function()
          for _, c in ipairs(corpseCache) do
            if c.pos and (meHRP.Position - c.pos).Magnitude <= F.corpse_range then
              local m = workspace:FindFirstChild(c.name)
              local hum = m and m:FindFirstChildOfClass("Humanoid")
              -- re-validate: the name may be reused by a respawned live body
              if m and m:IsA("Model") and hum and hum.Health <= 0 then
                local key = "c_" .. m:GetDebugId()
                setGlow(m, c.isPlayer and F.glow_corpse_c or F.corpse_ai_col, true, "c")
                seenGlow[key] = true
              end
            end
          end
        end)
      end

      -- loot (persistent labels)
      if meHRP and (F.loot_cont or F.loot_drop or F.loot_quest) then
        guarded("loot", function()
          for _, it in ipairs(lootCache) do
            local L = it.lbl
            if L then L.Visible = false end
            local want = (it.kind == "drop" and F.loot_drop)
              or (it.kind == "quest" and F.loot_quest)
              or (F.loot_cont) -- cont + spawn
            if want and it.pos and L then
              local d = (meHRP.Position - it.pos).Magnitude
              if d == d and d <= F.loot_range then
                nL = nL + 1
                local sp, on = wts(it.pos)
                if on then
                  local col = it.star and F.loot_hlcol or F.loot_col
                  local nm = (it.star and "* " or "") .. it.name
                  L.Text = nm .. "  " .. math.floor(d + 0.5) .. "m"
                  L.Color = col
                  L.Size = it.star and 14 or 12
                  L.Position = V2(sp.X, sp.Y)
                  L.Visible = true
                end
              end
            end
          end
        end)
      else
        for _, it in ipairs(lootCache) do
          if it.lbl then it.lbl.Visible = false end
        end
      end

      -- exits (persistent labels)
      if F.exit_on and meHRP then
        guarded("exits", function()
          for _, e in ipairs(exitCache) do
            local L = e.lbl
            if L then L.Visible = false end
            if e.pos and L then
              local d = (meHRP.Position - e.pos).Magnitude
              if d == d and d <= F.exit_range then
                local sp, on = wts(e.pos)
                if on then
                  L.Text = "EXIT  " .. math.floor(d + 0.5) .. "m"
                  L.Color = F.exit_col
                  L.Position = V2(sp.X, sp.Y)
                  L.Visible = true
                end
              end
            end
          end
        end)
      else
        for _, e in ipairs(exitCache) do
          if e.lbl then e.lbl.Visible = false end
        end
      end

      -- radar
      if F.radar_on and meHRP then
        guarded("radar", function()
          local size = F.radar_size or 170
          local pos = V2(vs.X - size - 16, vs.Y - size - 16)
          local bg = shape("Square")
          bg.Color = { R = 0.06, G = 0.06, B = 0.1 }; bg.Thickness = 1
          bg.Size = V2(size, size); bg.Position = V2(pos.X, pos.Y)
          local bd = shape("Square")
          bd.Color = { R = 0.25, G = 0.55, B = 0.7 }; bd.Thickness = 1; bd.Filled = false
          bd.Size = V2(size, size); bd.Position = V2(pos.X, pos.Y)
          local fwd, right = camera.CFrame.LookVector, camera.CFrame.RightVector
          local function dot(worldPos, col, s)
            local rel = worldPos - meHRP.Position
            local dx, dz = rel:Dot(right), rel:Dot(fwd)
            if dx ~= dx or dz ~= dz then return end
            if math.sqrt(dx * dx + dz * dz) > F.radar_range then return end
            local sc = (size / 2 - 4) / F.radar_range
            local p = shape("Square")
            p.Color = col; p.Thickness = 1
            p.Size = V2(s, s)
            p.Position = V2(pos.X + size / 2 + dx * sc - s / 2, pos.Y + size / 2 + dz * sc - s / 2)
          end
          for _, pl in ipairs(players:GetPlayers()) do
            if pl ~= LP then
              local ch = pl.Character
              local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
              local hum = ch and ch:FindFirstChildOfClass("Humanoid")
              if hrp and hum and hum.Health > 0 then
                dot(hrp.Position, { R = 1, G = 0.35, B = 0.35 }, 3)
              end
            end
          end
          for _, c in ipairs(corpseCache) do
            if c.pos then dot(c.pos, { R = 1, G = 0.6, B = 0.15 }, 2) end
          end
          for _, e in ipairs(exitCache) do
            if e.pos then dot(e.pos, { R = 0.4, G = 0.9, B = 0.5 }, 3) end
          end
        end)
      end

      -- aim
      aimOn = false
      if F.aim_on and meHRP and not (F.aim_pause and hubOpen()) then
        guarded("aim", function()
          local cap = math.rad(F.aim_fov or 15)
          local best, bestScore = nil, F.aim_prio == "distance" and math.huge or cap
          local origin = camera.CFrame.Position
          for _, pl in ipairs(players:GetPlayers()) do
            if pl ~= LP then
              local ch = pl.Character
              if not ch or not ch.Parent then ch = workspace:FindFirstChild(pl.Name) end
              local hum = ch and ch:FindFirstChildOfClass("Humanoid")
              if ch and hum and hum.Health > 0 then
                local ap = aimPoint(ch, F.aim_part)
                if ap then
                  local dir = ap - origin
                  local len = dir.Magnitude
                  if len == len and len > 1 then
                    local ang = math.acos(clamp(camera.CFrame.LookVector:Dot(dir / len), -1, 1))
                    if ang == ang and ang < cap and isVisible(origin, ap, ch) then
                      local score = (F.aim_prio == "distance") and len or ang
                      if score < bestScore then bestScore = score best = ap end
                    end
                  end
                end
              end
            end
          end
          if best then
            if not aimLastPos or (best - aimLastPos).Magnitude > 5 then
              aimSince = now -- fresh target: human reaction delay starts
            end
            aimLastPos = best
            local hold = F.aim_hold
            if now - aimSince >= (F.aim_delay or 0)
              and (hold == "always"
                or (hold == "right" and userInput:IsMouseButtonPressed(Enum.UserInputType.MouseButton2))
                or (hold == "left" and userInput:IsMouseButtonPressed(Enum.UserInputType.MouseButton1))) then
              local alpha = clamp(1 - ((F.aim_smooth or 65) / 101), 0.05, 0.99)
              camera.CFrame = camera.CFrame:Lerp(CFrame.lookAt(origin, best), alpha, true)
              aimOn = true
            end
          else
            aimLastPos = nil
          end
        end)
      end

      -- fov circle
      if F.aim_circle then
        local c = shape("Circle")
        c.Color = { R = 0.2, G = 0.8, B = 1 }; c.Transparency = 0.5
        c.Thickness = 1; c.NumSides = 48
        c.Radius = math.abs(fin(math.tan(math.rad(clamp(F.aim_fov or 15, 5, 90))) * vs.Y * 0.5, 10))
        c.Position = V2(vs.X / 2, vs.Y / 2)
      end
      if aimOn then
        local dotm = shape("Square")
        dotm.Color = { R = 1, G = 0.3, B = 0.3 }; dotm.Thickness = 2
        dotm.Size = V2(7, 7)
        dotm.Position = V2(vs.X / 2 - 3.5, vs.Y / 2 - 3.5)
        dotm.Transparency = 0
      end

      gcGlow(seenGlow)

      if statLbl and now - statTick > 2 then
        statTick = now
        pcall(function()
          statLbl.Set(("players %d - bodies %d - loot %d%s"):format(
            nP, nC, nL, aimOn and " - LOCK" or ""))
          local parts = { ("loop %dfps"):format(dbg.fps) }
          for _, sec in ipairs({ "players", "npc", "corpse", "corpseGlow", "loot", "exits", "radar", "aim" }) do
            if dbg.err[sec] then
              table.insert(parts, sec .. "!" .. dbg.err[sec])
            end
          end
          if dbg.last ~= "" then table.insert(parts, dbg.last) end
          dbgLbl.Set(table.concat(parts, " - "))
        end)
      end
    end)
  end))

  -- --------------------------------------------------------------------------
  -- Nova UI
  -- --------------------------------------------------------------------------
  local function flagToggle(sec, name, key, desc, tip)
    return sec:Toggle({ Name = name, Desc = desc, Default = F[key] == true,
      Flag = "pd_" .. key, Tooltip = tip,
      Callback = function(v) F[key] = v == true end })
  end
  local function flagSlider(sec, name, key, min, max, extra)
    extra = extra or {}
    return sec:Slider({ Name = name, Min = min, Max = max, Default = F[key],
      Decimals = extra.dec or 0, Suffix = extra.suf or "", Flag = "pd_" .. key,
      Tooltip = extra.tip,
      Callback = function(v) F[key] = tonumber(v) or min end })
  end
  local function flagDropdown(sec, name, key, options, tip)
    return sec:Dropdown({ Name = name, Options = options, Default = F[key],
      Flag = "pd_" .. key, Tooltip = tip,
      Callback = function(v) F[key] = tostring(v) end })
  end
  local function flagColor(sec, name, key, tip)
    return sec:Color({ Name = name, Default = F[key], Flag = "pd_" .. key,
      Tooltip = tip, Callback = function(v) F[key] = v end })
  end

  local pSec = Tab:Section({ Name = "Players" })
  pSec:Paragraph("No teams here — everyone else is hostile. Eyes only, nothing replicated.")
  flagToggle(pSec, "Boxes", "esp_box")
  flagToggle(pSec, "Health bar", "esp_health")
  flagToggle(pSec, "Tracers", "esp_tracer")
  flagToggle(pSec, "Names", "esp_name")
  flagToggle(pSec, "Distance", "esp_dist")
  flagToggle(pSec, "Weapon", "esp_weapon", "Holstered gun name")
  flagSlider(pSec, "Thickness", "esp_thick", 1, 5)
  flagSlider(pSec, "Range", "esp_range", 200, 6000, { suf = "m" })
  flagColor(pSec, "Enemy color", "esp_enemy")

  local aSec = Tab:Section({ Name = "Aim" })
  aSec:Paragraph("Camera lock only — no packets, no autofire. Smooth + small FOV keeps it human.")
  flagToggle(aSec, "Aim lock", "aim_on")
  flagDropdown(aSec, "Aim part", "aim_part", { "Head", "UpperTorso", "HumanoidRootPart" })
  flagSlider(aSec, "FOV", "aim_fov", 5, 45)
  flagSlider(aSec, "Smoothness", "aim_smooth", 1, 100, { tip = "Higher = slower, more human" })
  flagSlider(aSec, "Target delay", "aim_delay", 0, 0.5, { dec = 2, suf = "s", tip = "Reaction delay on new targets" })
  flagDropdown(aSec, "Trigger", "aim_hold", { "right", "left", "always" })
  flagDropdown(aSec, "Priority", "aim_prio", { "closest", "distance" })
  flagToggle(aSec, "Visible check", "aim_vis", "Skip targets behind walls")
  flagToggle(aSec, "FOV circle", "aim_circle")
  flagToggle(aSec, "Pause while hub open", "aim_pause")

  local gSec = Tab:Section({ Name = "Glow" })
  gSec:Paragraph("Client-side Highlights (see-through chams).")
  flagToggle(gSec, "Players", "glow_on")
  flagToggle(gSec, "NPC", "glow_npc")
  flagToggle(gSec, "Corpses", "glow_corpse")
  flagToggle(gSec, "Through walls", "glow_top")
  flagToggle(gSec, "Visible outline", "glow_vis",
    "Fat frame around targets NOT behind a wall (wall-checked)")
  flagSlider(gSec, "Outline thickness", "glow_visthick", 1, 6)
  flagColor(gSec, "Outline color", "glow_viscol")
  flagColor(gSec, "Player glow", "glow_enemy")
  flagColor(gSec, "NPC glow", "glow_npc_c")
  flagColor(gSec, "Corpse glow", "glow_corpse_c")

  local lSec = Tab:Section({ Name = "Loot" })
  lSec:Paragraph("Containers, floor drops, quest items. Starred = keyword match.")
  flagToggle(lSec, "Containers", "loot_cont")
  flagToggle(lSec, "Dropped items", "loot_drop")
  flagToggle(lSec, "Quest items", "loot_quest")
  flagToggle(lSec, "Keyword star", "loot_hl")
  lSec:TextBox({ Name = "Keywords", Placeholder = "card,key,defib,…", Default = F.loot_keys,
    Tooltip = "Comma-separated, case-insensitive", Flag = "pd_loot_keys",
    Callback = function(v) F.loot_keys = tostring(v or "") end })
  flagSlider(lSec, "Max distance", "loot_range", 200, 4000, { suf = "m" })
  flagColor(lSec, "Loot color", "loot_col")
  flagColor(lSec, "Star color", "loot_hlcol")

  local bSec = Tab:Section({ Name = "Bodies" })
  bSec:Paragraph("Lootable bodies: player corpses + AI corpses, distinct colors.")
  flagToggle(bSec, "Corpses", "corpse_on")
  flagToggle(bSec, "AI bodies", "corpse_ai")
  flagSlider(bSec, "Max distance", "corpse_range", 200, 4000, { suf = "m" })
  flagColor(bSec, "Player body", "corpse_col")
  flagColor(bSec, "AI body", "corpse_ai_col")

  local wSec = Tab:Section({ Name = "World" })
  flagToggle(wSec, "NPC (traders/bosses)", "npc_on")
  flagSlider(wSec, "NPC distance", "npc_range", 200, 4000, { suf = "m" })
  flagColor(wSec, "NPC color", "npc_col")
  flagToggle(wSec, "Exits", "exit_on")
  flagSlider(wSec, "Exit distance", "exit_range", 200, 6000, { suf = "m" })
  flagColor(wSec, "Exit color", "exit_col")
  flagToggle(wSec, "Radar", "radar_on")
  flagSlider(wSec, "Radar range", "radar_range", 100, 2000, { suf = "m" })
  flagSlider(wSec, "Radar size", "radar_size", 100, 320, { suf = "px" })

  local aboutSec = Tab:Section({ Name = "About" })
  aboutSec:Label("PROJECT DELTA - hub module (safe build)")
  aboutSec:Paragraph("ESP + camera aim + glow + loot/corpses/exits/radar. No movement, no packets, no scripts touched — nothing for the server to fingerprint. Still: play sane, reports exist (PlayerReport).")
  statLbl = aboutSec:Label("players 0 - bodies 0 - loot 0")
  dbgLbl = aboutSec:Label("loop - fps")
  aboutSec:Button({ Name = "Unload module", Variant = "danger", Callback = function()
    unloadModule()
  end })

  -- --------------------------------------------------------------------------
  -- Unload + boot
  -- --------------------------------------------------------------------------
  unloadModule = function()
    for _, c in ipairs(CONNS) do pcall(function() c:Disconnect() end) end
    for _, s in ipairs(shapes) do pcall(function() s:Remove() end) end
    for _, s in ipairs(prevShapes) do pcall(function() s:Remove() end) end
    shapes, prevShapes = {}, {}
    for _, h in pairs(glowMap) do pcall(function() h:Destroy() end) end
    for k in pairs(glowMap) do glowMap[k] = nil end
    for pl in pairs(pesc) do freeRig(pl) end
    for _, maps in ipairs({ lootMap, corpseMap, npcMap, exitMap }) do
      for m, o in pairs(maps) do
        if o.lbl then pcall(function() o.lbl:Remove() end) end
        maps[m] = nil
      end
    end
    local g = getgenv and getgenv()
    if g then
      if g.__HUMA_PLACE and g.__HUMA_PLACE.Unload == unloadModule then g.__HUMA_PLACE = nil end
      if g.__HUMA_DELTA and g.__HUMA_DELTA.Unload == unloadModule then g.__HUMA_DELTA = nil end
    end
    Notify("Delta", "Module unloaded", "info")
  end

  scanWorld()
  local hub = { Unload = unloadModule }
  if getgenv then pcall(function()
    getgenv().__HUMA_DELTA = hub
    getgenv().__HUMA_PLACE = hub -- generic contract: hub unloads the place module
    -- live debug snapshot (flags, errors, counters) for diagnosis
    getgenv().__HUMA_DELTA_DBG = function()
      local ok, snap = pcall(function()
        local rigs, labels = 0, 0
        local visBox, visName, visTrace = 0, 0, 0
        for _, e in pairs(pesc) do
          rigs = rigs + 1
          pcall(function() if e.box.Visible then visBox = visBox + 1 end end)
          pcall(function() if e.name.Visible then visName = visName + 1 end end)
          pcall(function() if e.trace.Visible then visTrace = visTrace + 1 end end)
        end
        for _, mp in ipairs({ lootMap, corpseMap, npcMap, exitMap }) do
          for _ in pairs(mp) do labels = labels + 1 end
        end
        return {
          fps = dbg.fps, err = dbg.err, last = dbg.last,
          counts = { nP = nP, nC = nC, nL = nL },
          objs = { rigs = rigs, labels = labels },
          shown = { box = visBox, name = visName, trace = visTrace },
          flags = {
            box = F.esp_box, hp = F.esp_health, tracer = F.esp_tracer,
            name = F.esp_name, dist = F.esp_dist, weapon = F.esp_weapon,
            glow = F.glow_on, range = F.esp_range, thick = F.esp_thick,
          },
        }
      end)
      if ok then return snap end
      return { error = tostring(snap) }
    end
  end) end

  Notify("Delta", "Loaded - eyes only, play sane", "ok")
  print("[huma-delta] place module loaded")
end
