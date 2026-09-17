--[[
  HumaHub place module — hunting game (PlaceId 120073741652089).
  Repo path: client/places/120073741652089.lua

  Place facts (verified live):
    - Workspace.Animals / Workspace.DeadAnimals hold animal Models;
    - models have NO Humanoid; PrimaryPart = "RootPart";
    - attributes: DisplayName, Sex, Weight, ClientSide, Id (no Health);
    - harvest prompt via ObjectValue ProximityPromptParent;
    - player character is standard (Humanoid + HRP in Workspace).
  Risky bits (teleport) carry the same honest warnings as the reference
  script — the game watches position. ESP/aim/glow-equivalents are eyes
  and camera only.
]]

return function(api)
  local Tab, Notify = api.Tab, api.Notify
  local NovaUI = api.Nova
  local MODULE_VERSION = "1.0-hunt"

  local runService = game:GetService("RunService")
  local players = game:GetService("Players")
  local workspace = game:GetService("Workspace")
  local userInput = game:GetService("UserInputService")
  local LP = players.LocalPlayer
  local camera = workspace.CurrentCamera
  local rayParams = RaycastParams.new()

  do
    local g = getgenv and getgenv()
    local prev = g and g.__HUMA_PLACE
    if prev and type(prev.Unload) == "function" then pcall(prev.Unload) end
  end

  local F = {
    esp_live = false, esp_dead = false,
    esp_filter = "",
    esp_col = Color3.fromRGB(255, 200, 80),
    esp_deadcol = Color3.fromRGB(255, 100, 100),
    esp_range = 2500,
    esp_names = true, esp_dist = true,
    aim_on = false, aim_part = "Heart", aim_fov = 12, aim_smooth = 60,
    aim_range = 1500, aim_hold = "always", aim_vis = true, aim_delay = 0.1,
    aim_circle = true, aim_pause = true, aim_predict = true,
    autofire = false,
    magic_on = false, magic_size = 10, magic_trans = 70,
    magic_col = Color3.fromRGB(255, 40, 40),
    speed = 16,
    harvest_on = false, harvest_range = 30,
  }

  local HAS_DRAWING = false
  do
    local ok = pcall(function()
      local probe = Drawing.new("Square")
      probe:Remove()
    end)
    HAS_DRAWING = ok == true
  end

  local moduleDead = false
  local CONNS = {}
  local function reg(c) table.insert(CONNS, c) return c end
  local unloadModule

  local function clamp(v, a, b)
    if v < a then return a elseif v > b then return b end
    return v
  end

  -- Drawing (Transparency is OPACITY: 1 = solid, 0 = invisible)
  local pools = {}
  local function shape(typ)
    local s = Drawing.new(typ)
    pcall(function() s.Transparency = 1 end)
    s.Visible = true
    return s
  end
  local function tshape(typ)
    local pool = pools[typ]
    if not pool then pool = { objs = {}, n = 0 }; pools[typ] = pool end
    pool.n = pool.n + 1
    local s = pool.objs[pool.n]
    if not s then s = shape(typ); pool.objs[pool.n] = s end
    pcall(function() if not s.Visible then s.Visible = true end end)
    return s
  end
  local function clearTransient()
    for _, pool in pairs(pools) do pool.n = 0 end
  end
  local function finishTransient()
    for _, pool in pairs(pools) do
      for i = pool.n + 1, #pool.objs do
        local o = pool.objs[i]
        pcall(function() if o.Visible then o.Visible = false end end)
      end
    end
  end
  local function freeTransient()
    for typ, pool in pairs(pools) do
      for _, o in ipairs(pool.objs) do pcall(function() o:Remove() end) end
      pools[typ] = nil
    end
  end

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
  local function fin(x, fb)
    if type(x) ~= "number" or x ~= x then return fb or 0 end
    if x == math.huge then return 1e6 end
    if x == -math.huge then return -1e6 end
    return x
  end
  local function V2(x, y) return Vector2.new(fin(x), fin(y)) end
  local dbg = { fps = 0, frames = 0, fpsT = 0, err = {}, last = "" }
  local function guarded(sec, fn)
    local ok, e = pcall(fn)
    if not ok then
      dbg.err[sec] = (dbg.err[sec] or 0) + 1
      dbg.last = sec .. ": " .. tostring(e):sub(1, 90)
    end
    return ok
  end
  local function onScreenPt(p, vs, m)
    m = m or 64
    return p.X > -m and p.X < vs.X + m and p.Y > -m and p.Y < vs.Y + m
  end
  local frameMe
  local function isVisible(from, to, ignore)
    if not F.aim_vis then return true end
    local ig = {}
    local me = frameMe or myChar()
    if me then ig[#ig + 1] = me end
    if ignore then ig[#ig + 1] = ignore end
    ig[#ig + 1] = camera
    local ok, hit = pcall(function()
      rayParams.FilterDescendantsInstances = ig
      rayParams.FilterType = Enum.RaycastFilterType.Exclude
      rayParams.IgnoreWater = true
      return workspace:Raycast(from, to - from, rayParams)
    end)
    if not ok then return true end
    return hit == nil
  end

  -- --------------------------------------------------------------------------
  -- Animal lists (rebuilt every 2s) + persistent labels
  -- --------------------------------------------------------------------------
  local liveCache, deadCache = {}, {}
  local liveMap, deadMap = {}, {}
  local function rootOf(m)
    if not m or not m.Parent then return nil end
    return m.PrimaryPart or m:FindFirstChildWhichIsA("BasePart", true)
  end
  local function filterKeys()
    local out = {}
    for k in tostring(F.esp_filter or ""):gmatch("[^,]+") do
      k = k:gsub("^%s+", ""):gsub("%s+$", ""):lower()
      if k ~= "" then table.insert(out, k) end
    end
    return out
  end
  local function scanAnimals()
    local live, dead = {}, {}
    local keys = filterKeys()
    local function want(name)
      if #keys == 0 then return true end
      local ln = name:lower()
      for _, k in ipairs(keys) do
        if ln:find(k, 1, true) then return true end
      end
      return false
    end
    local function collect(folder, out)
      if not folder then return end
      local ok, desc = pcall(function() return folder:GetDescendants() end)
      if not ok then return end
      local seen = {}
      for _, v in ipairs(desc) do
        if moduleDead then return end
        if v:IsA("Model") and not seen[v] and want(v.Name) then
          seen[v] = true
          local r = rootOf(v)
          if r then
            local dn = v.Name
            local okA, disp = pcall(function() return v:GetAttribute("DisplayName") end)
            out[#out + 1] = { m = v, root = r, name = dn,
              disp = (okA and type(disp) == "string" and disp ~= "") and disp or dn }
          end
        end
      end
    end
    collect(workspace:FindFirstChild("Animals"), live)
    collect(workspace:FindFirstChild("DeadAnimals"), dead)
    local myPos = myHRP() and myHRP().Position or nil
    if myPos then
      local function byDist(a, b)
        local pa = a.root.Parent and a.root.Position or nil
        local pb = b.root.Parent and b.root.Position or nil
        local da = pa and (pa - myPos).Magnitude or 1e9
        local db = pb and (pb - myPos).Magnitude or 1e9
        return da < db
      end
      table.sort(live, byDist)
      table.sort(dead, byDist)
    end
    if moduleDead then return end
    liveCache, deadCache = live, dead
    syncLabelMaps()
  end
  local function mkLabel(size)
    local t = shape("Text")
    pcall(function()
      t.Center = true; t.Outline = true
      t.Transparency = 1
      t.Font = 2; t.ZIndex = 3
      t.Size = size or 12; t.Visible = false
    end)
    return t
  end
  local function killDraw(o) pcall(function() o:Remove() end) end
  syncLabelMaps = function()
    local root = myHRP()
    local function sync(cache, map, enabled, range, size)
      local seen = {}
      for _, entry in ipairs(cache) do
        local active = enabled == true
        local position = entry.root.Parent and entry.root.Position or nil
        if HAS_DRAWING and root and active and entry.m.Parent and position
          and (position - root.Position).Magnitude <= range then
          seen[entry.m] = true
          if not map[entry.m] then map[entry.m] = { lbl = mkLabel(size) } end
          entry.lbl = map[entry.m].lbl
        else entry.lbl = nil end
      end
      for object, record in pairs(map) do
        if not seen[object] then killDraw(record.lbl); map[object] = nil end
      end
    end
    sync(liveCache, liveMap, (F.esp_live and (F.esp_names or F.esp_dist)) == true, F.esp_range, 12)
    sync(deadCache, deadMap, (F.esp_dead and (F.esp_names or F.esp_dist)) == true, F.esp_range, 12)
  end

  -- --------------------------------------------------------------------------
  -- Aim state (camera only) + autofire (input layer)
  -- --------------------------------------------------------------------------
  local aimOn, aimSince, aimTarget, fireTick = false, 0, nil, 0
  local function aimSpot(m)
    -- Heart first: an Attachment deep in the spine chain (verified live on
    -- deer). Falls back to bbox top, then bbox center, then root part.
    if F.aim_part == "Heart" then
      local ok, heart = pcall(function()
        for _, d in ipairs(m:GetDescendants()) do
          if d:IsA("Attachment") and d.Name:lower() == "heart" then return d end
        end
        return nil
      end)
      if ok and heart and heart.Parent then
        local ok2, wp = pcall(function() return heart.WorldPosition end)
        if ok2 and wp then return wp end
      end
    end
    local cf, size = nil, nil
    pcall(function() cf, size = m:GetBoundingBox() end)
    if cf then
      if F.aim_part == "Top" then return cf.Position + Vector3.new(0, (size and size.Y or 2) / 2, 0) end
      return cf.Position
    end
    local r = rootOf(m)
    return r and r.Position or nil
  end
  local fireClick = nil
  do
    if type(mouse1click) == "function" then
      fireClick = function() pcall(mouse1click) end
    elseif type(mouse1press) == "function" then
      fireClick = function()
        pcall(mouse1press)
        task.delay(0.03, function()
          pcall(function()
            if type(mouse1release) == "function" then mouse1release() end
          end)
        end)
      end
    else
      local okV, vim = pcall(function() return game:GetService("VirtualInputManager") end)
      if okV and vim then
        fireClick = function()
          pcall(function() vim:SendMouseButtonEvent(0, 0, 0, true, game, 0) end)
          task.delay(0.03, function()
            pcall(function() vim:SendMouseButtonEvent(0, 0, 0, false, game, 0) end)
          end)
        end
      end
    end
  end

  -- --------------------------------------------------------------------------
  -- Magic bullet (hitbox expand, local parts) + auto-harvest + speed
  -- --------------------------------------------------------------------------
  local hbOrig = {}
  local function applyMagic()
    if not F.magic_on then
      for part, o in pairs(hbOrig) do
        pcall(function()
          if part.Parent then
            part.Size = o.s; part.Transparency = o.t
            if o.m then part.Material = o.m end
          end
        end)
      end
      for k in pairs(hbOrig) do hbOrig[k] = nil end
      return
    end
    local seen = {}
    local s = clamp(tonumber(F.magic_size) or 10, 1, 50)
    local tr = clamp((tonumber(F.magic_trans) or 70) / 100, 0, 1)
    for _, e in ipairs(liveCache) do
      local m = e.m
      if m and m.Parent then
        local part = m.PrimaryPart or m:FindFirstChildWhichIsA("BasePart", true)
        if part then
          seen[part] = true
          if not hbOrig[part] then
            hbOrig[part] = { s = part.Size, t = part.Transparency, m = part.Material }
          end
          pcall(function()
            part.Size = Vector3.new(s, s, s)
            part.Transparency = tr
            part.Material = Enum.Material.ForceField
            part.CanCollide = false
          end)
        end
      end
    end
    for part, o in pairs(hbOrig) do
      if not seen[part] then
        pcall(function()
          if part.Parent then part.Size = o.s; part.Transparency = o.t; part.Material = o.m end
        end)
        hbOrig[part] = nil
      end
    end
  end
  local function autoHarvest()
    if not F.harvest_on then return end
    if type(fireproximityprompt) ~= "function" then return end
    local root = myHRP()
    if not root then return end
    local range = tonumber(F.harvest_range) or 30
    for _, e in ipairs(deadCache) do
      if e.m and e.m.Parent and e.root.Parent then
        if (e.root.Position - root.Position).Magnitude <= range then
          local ok, holder = pcall(function() return e.m:FindFirstChild("ProximityPromptParent", true) end)
          local prompt = nil
          if ok and holder then
            pcall(function() prompt = holder.Value end)
          end
          if not prompt then
            local ok2, pr = pcall(function()
              return e.m:FindFirstChildWhichIsA("ProximityPrompt", true)
            end)
            if ok2 then prompt = pr end
          end
          if prompt then pcall(fireproximityprompt, prompt) end
        end
      end
    end
  end
  local function applySpeed()
    local ch = myChar()
    local hum = ch and ch:FindFirstChildOfClass("Humanoid")
    if hum then pcall(function() hum.WalkSpeed = tonumber(F.speed) or 16 end) end
  end
  reg(players.PlayerRemoving:Connect(function()
    -- labels/dropdowns refresh on next scan tick; nothing cached per player
  end))

  -- --------------------------------------------------------------------------
  -- Status + teleport state
  -- --------------------------------------------------------------------------
  local statLbl, dbgLbl
  local statTick, scanTick, labelTick2, magicTick, harvTick, nL, nD = 0, 0, 0, 0, 0, 0, 0
  local tpBack = nil
  local tpList, tpPick = {}, nil
  local tpDrop = nil

  -- --------------------------------------------------------------------------
  -- Main loop (eyes + camera + local parts only)
  -- --------------------------------------------------------------------------
  reg(runService.RenderStepped:Connect(function(dt)
    clearTransient()
    local renderOk, renderError = pcall(function()
      camera = workspace.CurrentCamera or camera
      if not camera then return end
      local now = os.clock()
      dbg.frames = dbg.frames + 1
      if now - dbg.fpsT >= 1 then
        dbg.fps = math.floor(dbg.frames / math.max(now - dbg.fpsT, 0.01) + 0.5)
        dbg.frames, dbg.fpsT = 0, now
      end
      if now - scanTick > 2 then scanTick = now; guarded("scan", scanAnimals) end
      if now - labelTick2 > 0.5 then labelTick2 = now; guarded("labels", syncLabelMaps) end
      if now - magicTick > 0.5 then magicTick = now; guarded("magic", applyMagic) end
      if now - harvTick > 0.7 then harvTick = now; guarded("harvest", autoHarvest) end
      local me = myChar()
      frameMe = me
      local meHRP = me and me:FindFirstChild("HumanoidRootPart")
      local vs = camera.ViewportSize
      nL, nD = 0, 0

      -- ESP labels (root position read live — animals walk)
      if meHRP then
        guarded("esp", function()
          local mp = meHRP.Position
          local function draw(cache, map, on, col, dead)
            for _, e in ipairs(cache) do
              local L = e.lbl
              if L then L.Visible = false end
              if on and e.m.Parent and e.root.Parent then
                local p = e.root.Position
                local d = (mp - p).Magnitude
                if d == d and d <= (F.esp_range or 2500) then
                  if dead then nD = nD + 1 else nL = nL + 1 end
                  local sp, ok = wts(p + Vector3.new(0, 2, 0))
                  if L and ok and (F.esp_names or F.esp_dist) and onScreenPt(sp, vs) then
                    L.Text = (F.esp_names and e.disp or "")
                      .. (F.esp_dist and ((F.esp_names and "  " or "") .. math.floor(d + 0.5) .. "m") or "")
                    L.Color = col
                    L.Position = V2(sp.X, sp.Y)
                    L.Visible = true
                  end
                end
              end
            end
          end
          draw(liveCache, liveMap, F.esp_live == true, F.esp_col, false)
          draw(deadCache, deadMap, F.esp_dead == true, F.esp_deadcol, true)
        end)
      else
        for _, maps in ipairs({ liveMap, deadMap }) do
          for _, o in pairs(maps) do
            if o.lbl then pcall(function() o.lbl.Visible = false end) end
          end
        end
      end

      -- aim (camera only)
      aimOn = false
      if F.aim_on and meHRP and not userInput:GetFocusedTextBox() and not (F.aim_pause and hubOpen()) then
        guarded("aim", function()
          local cap = math.rad(F.aim_fov or 12)
          local maxR = F.aim_range or 1500
          local best, bestM = nil, nil
          local bestScore = cap
          local origin = camera.CFrame.Position
          local look = camera.CFrame.LookVector
          for _, e in ipairs(liveCache) do
            local m = e.m
            if m and m.Parent and e.root.Parent then
              local ap = aimSpot(m)
              if ap then
                local dir = ap - origin
                local len = dir.Magnitude
                if len == len and len > 1 and len <= maxR then
                  local ang = math.acos(clamp(look:Dot(dir / len), -1, 1))
                  if ang == ang and ang < cap and isVisible(origin, ap, m) then
                    if ang < bestScore then
                      bestScore = ang; best = ap; bestM = m
                    end
                  end
                end
              end
            end
          end
          if best then
            -- velocity lead (scene formula)
            if F.aim_predict ~= false and bestM then
              local hrp = bestM.PrimaryPart or bestM:FindFirstChildWhichIsA("BasePart", true)
              local vel = hrp and hrp.AssemblyLinearVelocity or nil
              if vel and vel.Magnitude == vel.Magnitude and vel.Magnitude < 200 then
                local dist = (best - origin).Magnitude
                best = best + vel * clamp(0.05 + dist / 2000, 0.02, 0.12)
              end
            end
            if bestM ~= aimTarget then
              aimTarget = bestM
              aimSince = now
            end
            local hold = F.aim_hold
            if now - aimSince >= (F.aim_delay or 0)
              and (hold == "always"
                or (hold == "right" and userInput:IsMouseButtonPressed(Enum.UserInputType.MouseButton2))
                or (hold == "left" and userInput:IsMouseButtonPressed(Enum.UserInputType.MouseButton1))) then
              local base = clamp(1 - ((F.aim_smooth or 60) / 101), 0.05, 0.99)
              local step = clamp(math.max(dt or (1 / 60), 1 / 480) * 60, 0.05, 4)
              local alpha = clamp(1 - (1 - base) ^ step, 0.01, 1)
              camera.CFrame = camera.CFrame:Lerp(CFrame.lookAt(origin, best), alpha)
              aimOn = true
            end
          else
            aimTarget = nil
          end
        end)
      end

      -- autofire while locked (never with the menu open, never dead)
      if F.autofire and aimOn and fireClick and not hubOpen() then
        local mc = myChar()
        local hum = mc and mc:FindFirstChildOfClass("Humanoid")
        if mc and hum and hum.Health > 0 and meHRP and now - fireTick > 0.13 then
          fireTick = now
          fireClick()
        end
      end

      -- fov circle + lock dot
      guarded("hud", function()
        if F.aim_circle then
          local c = tshape("Circle")
          c.Color = Color3.fromRGB(51, 204, 255)
          c.Transparency = 0.6
          c.Filled = false
          c.Thickness = 1
          c.NumSides = 64
          local camFov = math.rad(clamp(camera.FieldOfView or 70, 1, 120))
          local r = math.tan(math.rad(clamp(F.aim_fov or 12, 1, 89)))
            / math.max(math.tan(camFov / 2), 1e-4) * (vs.Y / 2)
          c.Radius = math.abs(fin(r, 40))
          c.Position = V2(vs.X / 2, vs.Y / 2)
        end
        if aimOn then
          local dotm = tshape("Square")
          dotm.Color = Color3.fromRGB(255, 77, 77)
          dotm.Filled = true
          dotm.Transparency = 1
          dotm.Thickness = 2
          dotm.Size = V2(7, 7)
          dotm.Position = V2(vs.X / 2 - 3.5, vs.Y / 2 - 3.5)
        end
      end)

      if statLbl and now - statTick > 2 then
        statTick = now
        pcall(function()
          statLbl.Set(("live %d - dead %d%s"):format(nL, nD, aimOn and " - LOCK" or ""))
          local parts = { ("loop %dfps"):format(dbg.fps) }
          for _, sec in ipairs({ "scan", "labels", "esp", "magic", "harvest", "aim", "hud" }) do
            if dbg.err[sec] then
              table.insert(parts, sec .. "!" .. dbg.err[sec])
            end
          end
          if dbg.last ~= "" then table.insert(parts, dbg.last) end
          dbgLbl.Set(table.concat(parts, " - "))
        end)
      end
    end)
    finishTransient()
    if not renderOk then dbg.err.render = (dbg.err.render or 0) + 1; dbg.last = tostring(renderError) end
  end))

  local function hubOpen()
    local ok, vis = pcall(function() return api.Win:IsVisible() end)
    if ok and type(vis) == "boolean" then return vis end
    local ok2, vis2 = pcall(function() return api.Win.Visible end)
    if ok2 and type(vis2) == "boolean" then return vis2 end
    return false
  end

  local pages = {}
  unloadModule = function()
    if moduleDead then return end
    moduleDead = true
    for _, c in ipairs(CONNS) do pcall(function() c:Disconnect() end) end
    for _, page in pairs(pages) do page:Destroy() end
    freeTransient()
    for part, o in pairs(hbOrig) do
      pcall(function()
        if part.Parent then part.Size = o.s; part.Transparency = o.t; part.Material = o.m end
      end)
    end
    for k in pairs(hbOrig) do hbOrig[k] = nil end
    for _, maps in ipairs({ liveMap, deadMap }) do
      for m, o in pairs(maps) do
        if o.lbl then pcall(function() o.lbl:Remove() end) end
        maps[m] = nil
      end
    end
    local g = getgenv and getgenv()
    if g then
      if g.__HUMA_PLACE and g.__HUMA_PLACE.Unload == unloadModule then g.__HUMA_PLACE = nil end
    end
    Notify("Hunt", "Module unloaded, hitboxes restored", "info")
  end

  local hub = { Unload = unloadModule }
  if getgenv then getgenv().__HUMA_PLACE = hub end

  -- --------------------------------------------------------------------------
  -- UI: ESP / Combat / Teleport / About
  -- --------------------------------------------------------------------------
  -- separate flag namespace (hu_) on purpose: pd_ is shared with the
  -- Delta/shooter modules and their saved values (Head part, RMB trigger,
  -- names off) were leaking into this module and silently breaking it.
  local function flagToggle(sec, name, key, desc, tip)
    return sec:Toggle({ Name = name, Desc = desc, Default = F[key] == true,
      Flag = "hu_" .. key, Tooltip = tip,
      Callback = function(v) F[key] = v == true end })
  end
  local function flagSlider(sec, name, key, min, max, extra)
    extra = extra or {}
    return sec:Slider({ Name = name, Min = min, Max = max, Default = F[key],
      Decimals = extra.dec or 0, Suffix = extra.suf or "", Flag = "hu_" .. key,
      Tooltip = extra.tip,
      Callback = function(v) F[key] = tonumber(v) or min end })
  end
  local function flagDropdown(sec, name, key, options, tip)
    return sec:Dropdown({ Name = name, Options = options, Default = F[key],
      Flag = "hu_" .. key, Tooltip = tip,
      Callback = function(v) F[key] = tostring(v) end })
  end
  local function flagColor(sec, name, key, tip)
    return sec:Color({ Name = name, Default = F[key], Flag = "hu_" .. key,
      Tooltip = tip, Callback = function(v) F[key] = v end })
  end

  local nav = api.Navigation or Tab:Navigation({ Name = "Hunt" })
  local menuDefs = {
    { "ESP", "□", "Live and dead animals" },
    { "Combat", "◎", "Aim, trigger, magic bullet" },
    { "Teleport", "➤", "Travel (watched by the game!)" },
    { "About", "i", "Status" },
  }
  for index, def in ipairs(menuDefs) do
    pages[def[1]] = nav:Page({ Id = "hunt_" .. def[1]:lower(), Name = def[1],
      Icon = def[2], Tooltip = def[3], Order = index })
  end
  pages.ESP:Select()
  local espTabs = pages.ESP:SubTabs({ { Name = "Live" }, { Name = "Dead" } })

  local liveSec = espTabs.Live:Section({ Name = "Live animals" })
  liveSec:Paragraph("Name + distance labels that follow walking animals.")
  flagToggle(liveSec, "Live ESP", "esp_live")
  flagToggle(liveSec, "Names", "esp_names")
  flagToggle(liveSec, "Distance", "esp_dist")
  flagSlider(liveSec, "Max distance", "esp_range", 200, 6000, { suf = "m" })
  flagColor(liveSec, "Color", "esp_col")
  liveSec:TextBox({ Name = "Filter (comma list)", Placeholder = "Deer,Bear — empty = all",
    Default = F.esp_filter, Flag = "hu_esp_filter",
    Callback = function(v) F.esp_filter = tostring(v or "") end })
  local deadSec = espTabs.Dead:Section({ Name = "Dead animals" })
  deadSec:Paragraph("Carcasses ready to harvest.")
  flagToggle(deadSec, "Dead ESP", "esp_dead")
  flagToggle(deadSec, "Names", "esp_names")
  flagToggle(deadSec, "Distance", "esp_dist")
  flagColor(deadSec, "Color", "esp_deadcol")

  local aimSec = pages.Combat:Section({ Name = "Aimbot" })
  aimSec:Paragraph("3 steps: 1) Aimbot ON 2) Autofire ON 3) close the menu and hunt. LOCK in About means tracking.")
  flagToggle(aimSec, "Aimbot", "aim_on")
  flagToggle(aimSec, "Autofire", "autofire",
    "Clicks for you while locked on. Off while the menu is open.")
  if not fireClick then
    aimSec:Paragraph("WARNING: this executor exposes no input simulation — autofire cannot work here.")
  end
  flagDropdown(aimSec, "Aim at", "aim_part", { "Heart", "Body", "Top" })
  flagSlider(aimSec, "FOV", "aim_fov", 3, 45)
  flagSlider(aimSec, "Max range", "aim_range", 100, 4000, { suf = "m" })
  flagSlider(aimSec, "Smoothness", "aim_smooth", 1, 100, { tip = "Higher = slower, more human" })
  flagSlider(aimSec, "Target delay", "aim_delay", 0, 0.5, { dec = 2, suf = "s" })
  flagDropdown(aimSec, "Trigger", "aim_hold", { "always", "right", "left" })
  flagToggle(aimSec, "Visible check", "aim_vis", "Skip targets behind walls")
  flagToggle(aimSec, "Prediction", "aim_predict", "Lead moving animals by velocity")
  flagToggle(aimSec, "FOV circle", "aim_circle")
  flagToggle(aimSec, "Pause while hub open", "aim_pause")
  local magicSec = pages.Combat:Section({ Name = "Magic bullet" })
  magicSec:Paragraph("Enlarges live-animal hitboxes so near-misses connect. Restores on off/unload.")
  flagToggle(magicSec, "Magic bullet", "magic_on")
  flagSlider(magicSec, "Hitbox size", "magic_size", 1, 50, { suf = "st" })
  flagSlider(magicSec, "Transparency", "magic_trans", 0, 100, { suf = "%" })
  flagColor(magicSec, "Color", "magic_col")

  local tpSec = pages.Teleport:Section({ Name = "Travel" })
  tpSec:Paragraph("WARNING: this game watches position — teleports are the fastest way to get banned here. Your call.")
  local tpLbl = tpSec:Label("scan for nearby animals first")
  tpDrop = tpSec:Dropdown({ Name = "Animal", Options = { "—" }, Default = "—",
    Tooltip = "Nearest animals with distances",
    Callback = function(v) tpPick = tostring(v) end })
  tpSec:Button({ Name = "Scan nearby animals", Variant = "ghost", Callback = function()
    task.spawn(function()
      guarded("scan", scanAnimals)
      local me = myHRP()
      local mp = me and me.Position or nil
      tpList = {}
      if mp then
        for _, e in ipairs(liveCache) do
          if e.root.Parent then
            tpList[#tpList + 1] = { e = e,
              disp = e.disp .. " · " .. math.floor(((e.root.Position - mp).Magnitude) + 0.5) .. "m" }
            if #tpList >= 24 then break end
          end
        end
        for _, e in ipairs(deadCache) do
          if e.root.Parent then
            tpList[#tpList + 1] = { e = e,
              disp = "[DEAD] " .. e.disp .. " · " .. math.floor(((e.root.Position - mp).Magnitude) + 0.5) .. "m" }
            if #tpList >= 30 then break end
          end
        end
      end
      local opts = {}
      for _, t in ipairs(tpList) do opts[#opts + 1] = t.disp end
      if #opts == 0 then opts = { "—" } end
      tpDrop.SetOptions(opts)
      tpPick = opts[1]
      if #tpList > 0 then tpDrop.Set(opts[1], true) end
      tpLbl.Set(("found %d (live %d + dead %d)"):format(#tpList, #liveCache, #deadCache))
    end)
  end })
  tpSec:Button({ Name = "Teleport to animal", Callback = function()
    local me = myHRP()
    if not me then Notify("Travel", "No character", "warn"); return end
    local target
    for _, t in ipairs(tpList) do if t.disp == tpPick then target = t.e break end end
    if not target or not target.m.Parent or not target.root.Parent then
      Notify("Travel", "Animal gone — scan again", "warn"); return end
    tpBack = me.CFrame
    local ok = pcall(function()
      me.CFrame = target.root.CFrame + Vector3.new(0, 4, 0)
    end)
    Notify("Travel", ok and ("At " .. target.disp) or "Teleport failed", ok and "ok" or "error")
  end })
  tpSec:Button({ Name = "Teleport back", Variant = "ghost", Callback = function()
    local me = myHRP()
    if not me then Notify("Travel", "No character", "warn"); return end
    if not tpBack then Notify("Travel", "Nowhere to return to", "warn"); return end
    local ok = pcall(function() me.CFrame = tpBack end)
    Notify("Travel", ok and "Back" or "Failed", ok and "ok" or "error")
  end })
  local harvSec = pages.Teleport:Section({ Name = "Auto-harvest" })
  harvSec:Paragraph("Presses E on every carcass around you by itself. Same as you mashing E — stand near bodies.")
  flagToggle(harvSec, "Auto-harvest", "harvest_on")
  flagSlider(harvSec, "Radius", "harvest_range", 5, 100, { suf = "m" })
  if type(fireproximityprompt) ~= "function" then
    harvSec:Paragraph("WARNING: this executor has no fireproximityprompt — auto-harvest cannot work here.")
  end
  local moveSec = pages.Teleport:Section({ Name = "Movement" })
  moveSec:Paragraph("Plain WalkSpeed. Resets to 16 on unload.")
  local speedBox = moveSec:Slider({ Name = "Walk speed", Min = 16, Max = 120, Default = F.speed,
    Flag = "hu_speed",
    Callback = function(v) F.speed = tonumber(v) or 16; applySpeed() end })
  if task ~= nil then
    task.defer(function()
      pcall(applySpeed)
      reg(LP.CharacterAdded:Connect(function()
        task.wait(1)
        if not moduleDead then applySpeed() end
      end))
    end)
  end

  local aboutSec = pages.About:Section({ Name = "About" })
  aboutSec:Label("HUNT - hub module v" .. MODULE_VERSION)
  aboutSec:Paragraph("Animal ESP + camera aim + trigger + magic bullet + travel. Eyes and camera are safe; travel is watched.")
  statLbl = aboutSec:Label("live 0 - dead 0")
  dbgLbl = aboutSec:Label("loop - fps")
  aboutSec:Button({ Name = "Rebuild overlays", Variant = "ghost", Callback = function()
    freeTransient()
    for _, maps in ipairs({ liveMap, deadMap }) do
      for m, o in pairs(maps) do
        if o.lbl then pcall(function() o.lbl:Remove() end) end
        maps[m] = nil
      end
    end
    for _, cache in ipairs({ liveCache, deadCache }) do
      for _, entry in ipairs(cache) do entry.lbl = nil end
    end
    HAS_DRAWING = pcall(function() local probe = Drawing.new("Square"); probe:Remove() end)
    guarded("labels", syncLabelMaps)
    Notify("Hunt", HAS_DRAWING and "Overlays rebuilt" or "Drawing API unavailable", HAS_DRAWING and "ok" or "warn")
  end })
  aboutSec:Button({ Name = "Unload module", Variant = "danger", Callback = function()
    unloadModule()
  end })

  local hub = { Unload = unloadModule }
  if getgenv then getgenv().__HUMA_PLACE = hub end
  return hub
end
