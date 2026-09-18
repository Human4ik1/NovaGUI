--[[
  HumaHub place module — Destroy the Cube (PlaceId 124745235987813).
  Repo path: client/places/124745235987813.lua

  Engineered from the open AutoDestroy script (nearest part + Hit remote).
  Place facts (verified live):
    - Workspace.Cube holds ~2894 MeshParts, each with HP/MaxHP/Tier attrs;
    - hit = ReplicatedStorage.CubeRemotes.Hit:FireServer(part, pos, normal);
    - Broke/Dmg remotes exist (break + damage counters).
  Only the game's own Hit remote is ever sent, paced (default 15/s, not
  60/s like the reference) — no teleports, no hooks, no game edits.
]]

return function(api)
  local Tab, Notify = api.Tab, api.Notify
  local Hud = api.Shared and api.Shared.SetHud -- mini corner chip (may be nil on old hubs)
  local MODULE_VERSION = "1.11-podprompt"

  local runService = game:GetService("RunService")
  local players = game:GetService("Players")
  local workspace = game:GetService("Workspace")
  local userInput = game:GetService("UserInputService")
  local camera = workspace.CurrentCamera
  local LP = players.LocalPlayer

  do
    local g = getgenv and getgenv()
    local prev = g and g.__HUMA_PLACE
    if prev and type(prev.Unload) == "function" then pcall(prev.Unload) end
  end

  local F = {
    farm_on = false, farm_rate = 15, farm_mode = "Weakest", farm_range = 80,
    sell_on = false, sell_at = 100, sell_cd = 0,
    gel_on = false, gel_cd = 0, gel_every = 120,
    tour_on = false, tour_range = 150, tour_mode = "Walk",
    tour_speed = 16, tour_pause = 0.5,
    esp_on = false, esp_names = true, esp_range = 400, esp_count = 30,
    esp_col = Color3.fromRGB(120, 220, 255),
  }
  -- proven hit normal from the reference script (kept byte-identical)
  local HIT_NORMAL = Vector3.new(0.014110449701548, 0.16652980446815, 0.98593550920486)

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

  local function shape(typ)
    local s = Drawing.new(typ)
    pcall(function() s.Transparency = 1 end)
    s.Visible = true
    return s
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
  local function hud(key, text)
    if Hud then pcall(function() Hud(key, text) end) end
  end
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

  local function cubeFolder()
    return workspace:FindFirstChild("Cube")
  end
  local function hitRemote()
    local rs = game:GetService("ReplicatedStorage")
    local cr = rs and rs:FindFirstChild("CubeRemotes")
    return cr and cr:FindFirstChild("Hit") or nil
  end
  local function partHP(part)
    local ok, hp = pcall(function() return part:GetAttribute("HP") end)
    local ok2, mh = pcall(function() return part:GetAttribute("MaxHP") end)
    if ok and type(hp) == "number" then
      return hp, (ok2 and type(mh) == "number" and mh > 0) and mh or hp
    end
    return nil, nil
  end

  -- --------------------------------------------------------------------------
  -- Target scan (every 0.5s): nearest + weakest parts in range
  -- --------------------------------------------------------------------------
  local tgtCache, espCache = {}, {}
  local espMap = {}
  local syncEsp
  syncEsp = function()
    local root = myHRP()
    local want = F.esp_on == true and HAS_DRAWING and root ~= nil
    local seen = {}
    if want then
      local n = clamp(math.floor(tonumber(F.esp_count) or 30), 1, 60)
      for i = 1, math.min(n, #espCache) do
        local e = espCache[i]
        if e.m.Parent then
          seen[e.m] = true
          if not espMap[e.m] then espMap[e.m] = { lbl = mkLabel(12), box = nil } end
          e.lbl = espMap[e.m].lbl
        else e.lbl = nil end
      end
    end
    for object, record in pairs(espMap) do
      if not seen[object] then
        killDraw(record.lbl)
        if record.box then pcall(function() record.box:Destroy() end) end
        espMap[object] = nil
      end
    end
  end
  local function scanTargets()
    local cf = cubeFolder()
    local root = myHRP()
    if not cf or not root then tgtCache, espCache = {}, {}; return end
    local mp = root.Position
    local range = tonumber(F.farm_range) or 80
    local espRange = tonumber(F.esp_range) or 400
    local best, bestD, bestWeak, bestWeakFrac = nil, math.huge, nil, math.huge
    local esp = {}
    -- main cube + rubble chunks (broken-off parts live in CubeRubble with
    -- their own HP — the same Hit remote works on them)
    local function consider(part)
      if not (part:IsA("BasePart") and part.Parent) then return end
      local d = (part.Position - mp).Magnitude
      if d ~= d then return end
      if d <= range then
        if d < bestD then best, bestD = part, d end
        local hp, mh = partHP(part)
        if hp and mh then
          local frac = hp / mh
          if frac < bestWeakFrac then bestWeak, bestWeakFrac = part, frac end
        end
      end
      if d <= espRange and #esp < 200 then
        local hp2, mh2 = partHP(part)
        esp[#esp + 1] = { m = part, pos = part.Position, d = d,
          hp = hp2, mh = mh2 }
      end
    end
    local sources = { cf, workspace:FindFirstChild("CubeRubble") }
    for _, folder in ipairs(sources) do
      if folder then
        local kids = folder:GetChildren()
        for i, part in ipairs(kids) do
          if moduleDead then return end
          if i % 800 == 0 then task.wait() end
          consider(part)
        end
      end
    end
    -- weakest-first for ESP so low bars surface; farm picks by mode below
    table.sort(esp, function(a, b)
      local fa = (a.hp and a.mh) and (a.hp / a.mh) or 1
      local fb = (b.hp and b.mh) and (b.hp / b.mh) or 1
      if fa ~= fb then return fa < fb end
      return a.d < b.d
    end)
    if moduleDead then return end
    tgtCache = { near = best, nearD = bestD, weak = bestWeak }
    espCache = esp
    syncEsp()
  end
  local syncEsp
  syncEsp = function()
    local root = myHRP()
    local want = F.esp_on == true and HAS_DRAWING and root ~= nil
    local seen = {}
    if want then
      local n = clamp(math.floor(tonumber(F.esp_count) or 30), 1, 60)
      for i = 1, math.min(n, #espCache) do
        local e = espCache[i]
        if e.m.Parent then
          seen[e.m] = true
          if not espMap[e.m] then espMap[e.m] = { lbl = mkLabel(12), box = nil } end
          e.lbl = espMap[e.m].lbl
        else e.lbl = nil end
      end
    end
    for object, record in pairs(espMap) do
      if not seen[object] then
        killDraw(record.lbl)
        if record.box then pcall(function() record.box:Destroy() end) end
        espMap[object] = nil
      end
    end
    -- unlimited wireframe boxes (no Highlight cap pressure on 3k parts)
    if want then
      for object in pairs(seen) do
        local rec = espMap[object]
        if rec and (not rec.box or not rec.box.Parent) then
          local ok, ad = pcall(function()
            local a = Instance.new("BoxHandleAdornment")
            a.Name = "CubeFX"
            a.Adornee = object
            a.Size = object.Size
            a.Color3 = F.esp_col
            a.Transparency = 0.35
            a.AlwaysOnTop = true
            a.ZIndex = 1
            a.Parent = object
            return a
          end)
          if ok and ad then rec.box = ad end
        end
      end
    else
      for _, rec in pairs(espMap) do
        if rec.box then pcall(function() rec.box:Destroy() end); rec.box = nil end
      end
    end
  end

  -- --------------------------------------------------------------------------
  -- Auto-sell (podium prompt, in-range only) + auto aqua (UseGel)
  -- --------------------------------------------------------------------------
  local sellLbl = nil
  local function sellPrompt()
    local ok, pod = pcall(function()
      local pav = workspace:FindFirstChild("Pavilion")
      return pav and pav:FindFirstChild("SellPodium") or nil
    end)
    if not ok or not pod then return nil end
    local ok2, pr = pcall(function()
      return pod:FindFirstChildWhichIsA("ProximityPrompt", true)
    end)
    return (ok2 and pr or nil), pod
  end
  local function playerStat(name)
    local ok, v = pcall(function() return LP:GetAttribute(name) end)
    if ok and type(v) == "number" then return v end
    return nil
  end
  local function autoTick()
    local now = os.clock()
    -- sell: shards full (or past threshold) + standing by the podium
    if F.sell_on then
      local shards, max = playerStat("Shards"), playerStat("MaxShards")
      if shards and max and max > 0 and shards >= max * (tonumber(F.sell_at) or 100) / 100 then
        if now - (F.sell_cd or 0) > 5 then
          local me = myHRP()
          local prompt, pod = sellPrompt()
          if prompt and me then
            local maxD = 12
            pcall(function()
              local md = prompt.MaxActivationDistance
              if type(md) == "number" and md > 0 then maxD = md end
            end)
            local pp = pod:IsA("BasePart") and pod.Position or prompt.Parent.Position
            if (pp - me.Position).Magnitude <= maxD then
              if type(fireproximityprompt) == "function" then
                F.sell_cd = now
                sellHold, sellHoldT = true, now
                sellMoney = playerStat("Money") or 0
                sellMoneyT = now
                pcall(fireproximityprompt, prompt)
                Notify("Sell", ("Auto-sold %d shards"):format(math.floor(shards)), "ok")
              end
            end
          end
        end
      end
      if sellLbl then
        pcall(function()
          local s, m = playerStat("Shards"), playerStat("MaxShards")
          if s and m then sellLbl.Set(("shards %d/%d"):format(math.floor(s), math.floor(m))) end
        end)
      end
    end
    -- aqua: the counter only grows (223 seen), so "below 80" never
    -- triggers. Mirror the water button periodically instead.
    if F.gel_on then
      local every = tonumber(F.gel_every) or 120
      if now - (F.gel_cd or 0) > every then
        local rs = game:GetService("ReplicatedStorage")
        local cr = rs and rs:FindFirstChild("CubeRemotes")
        local ug = cr and cr:FindFirstChild("UseGel")
        if ug then
          F.gel_cd = now
          pcall(function() ug:FireServer("Aqua") end)
        end
      end
    end
  end
  -- --------------------------------------------------------------------------
  -- Loot tour: Walk (legit steps) / Noclip (through walls) / Teleport
  -- (hops). Bag-full walks home to the podium (auto-sell fires there).
  -- Your WASD always wins. Risk grows left to right — pick wisely.
  -- --------------------------------------------------------------------------
  local tourStuckT, tourLastPos, tourTarget, tourWaitUntil = 0, nil, nil, 0
  local tourNc, tourOrigSpeed, tourSpeedSet = {}, nil, false
  local tourStatus = "off"
  -- sale completion is tracked by MONEY movement, not the shard counter:
  -- the server deducts Shards the instant the sale is accepted while the
  -- visuals (and the money ticks) still fly for many seconds. Holding on
  -- shards==0 releases immediately and the tour walks off mid-sale.
  local sellHold, sellHoldT, sellMoney, sellMoneyT = false, 0, 0, 0
  local function tourNoclip(on, ch)
    if on then
      if ch then
        for _, p in ipairs(ch:GetDescendants()) do
          if p:IsA("BasePart") then
            if tourNc[p] == nil then tourNc[p] = p.CanCollide end
            p.CanCollide = false
          end
        end
      end
    else
      for p, v in pairs(tourNc) do
        pcall(function() if p.Parent then p.CanCollide = v end end)
        tourNc[p] = nil
      end
    end
  end
  local function tourSpeed(hum, want)
    if want then
      if not tourSpeedSet then
        tourOrigSpeed = hum.WalkSpeed
        tourSpeedSet = true
      end
      local s = clamp(tonumber(F.tour_speed) or 16, 16, 100)
      if hum.WalkSpeed ~= s then pcall(function() hum.WalkSpeed = s end) end
    elseif tourSpeedSet then
      tourSpeedSet = false
      pcall(function() hum.WalkSpeed = tourOrigSpeed or 16 end)
      tourOrigSpeed = nil
    end
  end
  local function podiumPos()
    -- aim at the PROMPT, not the podium middle: the model bbox center can
    -- sit a dozen meters from the sell prompt, and then the tour hops
    -- around a spot the sale can never trigger from. Prompt parent first.
    local ok, pod = pcall(function()
      local pav = workspace:FindFirstChild("Pavilion")
      return pav and pav:FindFirstChild("SellPodium") or nil
    end)
    if not ok or not pod then return nil end
    local okP, pr = pcall(function()
      return pod:FindFirstChildWhichIsA("ProximityPrompt", true)
    end)
    if okP and pr and pr.Parent then
      local okQ, pp = pcall(function() return pr.Parent.Position end)
      if okQ and pp then return pp end
    end
    local ok2, cf = pcall(function() return pod:GetBoundingBox() end)
    if ok2 and cf then return cf.Position end
    return nil
  end
  local function tourTick()
    local ch = myChar()
    local hum = ch and ch:FindFirstChildOfClass("Humanoid")
    local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
    if not F.tour_on then
      if hum then tourSpeed(hum, false) end
      tourNoclip(false)
      tourStatus = "off"
      return
    end
    if not hum or not hrp then tourStatus = "no char"; return end
    local mode = F.tour_mode or "Walk"
    -- your hands on WASD override the tour for this tick
    local manual = false
    pcall(function()
      manual = hum.MoveDirection.Magnitude > 0.1
    end)
    if manual then tourTarget = nil; tourStatus = "manual"; return end
    local now = os.clock()
    -- sale in flight: stand by until the money STOPS moving (min 5s,
    -- max 60s), then go for new ones
    if sellHold then
      local m = playerStat("Money")
      if m and m ~= sellMoney then sellMoney, sellMoneyT = m, now end
      if m == nil or (now - sellMoneyT > 4 and now - sellHoldT > 5) or now - sellHoldT > 60 then
        sellHold = false
      else
        tourStatus = "selling…"
        pcall(function() hum:MoveTo(hrp.Position) end)
        return
      end
    end
    tourSpeed(hum, true)
    tourNoclip(mode == "Noclip", ch)
    local now = os.clock()
    if now < tourWaitUntil then tourStatus = "pause"; return end -- pickup pause
    local shards, max = playerStat("Shards"), playerStat("MaxShards")
    local dest, isPodium = nil, false
    if shards and max and max > 0 and shards >= max then
      dest, isPodium = podiumPos(), true -- bag full: walk home
      if dest then tourStatus = "→ podium (full)" end
    else
      local ws = workspace:FindFirstChild("CubeDrops")
      local bestD = tonumber(F.tour_range) or 150
      if ws then
        local mp, best = hrp.Position, nil
        for _, d in ipairs(ws:GetChildren()) do
          if d:IsA("BasePart") and d.Parent then
            local dd = (d.Position - mp).Magnitude
            if dd < bestD then best, bestD = d.Position, dd end
          end
        end
        dest = best
      end
      if dest then tourStatus = ("→ drop %dm"):format(math.floor(bestD))
      else tourStatus = ("idle: nothing ≤%dm"):format(math.floor(tonumber(F.tour_range) or 150)) end
    end
    if dest == nil then
      tourTarget = nil
      -- nothing to collect: dump whatever is in the bag, then idle here
      -- (auto-sell fires on arrival at the podium)
      local sh = playerStat("Shards")
      if sh and sh > 0 then
        dest = podiumPos()
        if dest then tourStatus = "→ podium (nothing left)" end
      end
      if dest == nil then
        if not isPodium then tourStatus = ("idle: nothing ≤%dm"):format(math.floor(tonumber(F.tour_range) or 150)) end
        pcall(function() hum:MoveTo(hrp.Position) end)
        return
      end
    end
    tourTarget = dest
    local dist = (dest - hrp.Position).Magnitude
    local pause = tonumber(F.tour_pause) or 0.5
    -- arrived (any mode): hold, let server register, no more hops
    if dist < 5 then
      pcall(function() hum:MoveTo(hrp.Position) end)
      tourWaitUntil = now + pause
      return
    end
    if mode == "Teleport" then
      -- hop in (only when not arrived — see above), pause, next
      pcall(function()
        hrp.CFrame = CFrame.new(dest + Vector3.new(0, 3, 0))
      end)
      tourWaitUntil = now + math.max(pause, 0.3)
      return
    end
    -- Walk / Noclip: MoveTo ONLY — never touch HRP CFrame while walking.
    -- Rewriting CFrame every tick (even rotation-only) cancels the active
    -- MoveTo, so the character twitches in place forever. Facing is the
    -- humanoid's own job (AutoRotate follows MoveTo).
    -- stuck? (3s without progress) hop once and keep going
    if tourLastPos and (hrp.Position - tourLastPos).Magnitude < 1 then
      if now - tourStuckT > 3 then
        tourStuckT = now
        pcall(function() hum.Jump = true end)
      end
    else
      tourLastPos = hrp.Position
      tourStuckT = now
    end
    if (dest - hrp.Position).Magnitude > 0.5 then
      pcall(function() hum:MoveTo(dest) end)
    end
  end
  local statHits, statBroke = 0, 0
  do
    pcall(function()
      local rs = game:GetService("ReplicatedStorage")
      local cr = rs and rs:FindFirstChild("CubeRemotes")
      local broke = cr and cr:FindFirstChild("Broke")
      if broke and broke:IsA("RemoteEvent") then
        reg(broke.OnClientEvent:Connect(function()
          statBroke = statBroke + 1
        end))
      end
    end)
  end

  -- --------------------------------------------------------------------------
  -- Status
  -- --------------------------------------------------------------------------
  local statLbl, dbgLbl
  local statTick, scanTick, fireTick, autoT, tourT, nParts = 0, 0, 0, 0, 0, 0

  -- --------------------------------------------------------------------------
  -- Main loop (own Hit remote only, paced)
  -- --------------------------------------------------------------------------
  reg(runService.RenderStepped:Connect(function(dt)
    local renderOk, renderError = pcall(function()
      camera = workspace.CurrentCamera or camera
      if not camera then return end
      local now = os.clock()
      dbg.frames = dbg.frames + 1
      if now - dbg.fpsT >= 1 then
        dbg.fps = math.floor(dbg.frames / math.max(now - dbg.fpsT, 0.01) + 0.5)
        dbg.frames, dbg.fpsT = 0, now
      end
      if now - scanTick > 0.5 then scanTick = now; guarded("scan", scanTargets) end
      if now - autoT > 1 then autoT = now; guarded("auto", autoTick) end
      if now - tourT > 0.5 then tourT = now; guarded("tour", tourTick) end
      local me = myChar()
      local meHRP = me and me:FindFirstChild("HumanoidRootPart")
      local vs = camera.ViewportSize

      -- auto-hit, paced
      if F.farm_on and meHRP then
        guarded("farm", function()
          local rate = clamp(tonumber(F.farm_rate) or 15, 1, 60)
          if now - fireTick >= 1 / rate then
            fireTick = now
            local t = (F.farm_mode == "Weakest" and tgtCache.weak) or tgtCache.near
            if t == nil then t = tgtCache.near end
            if t and t.Parent then
              local rem = hitRemote()
              if rem then
                local ok = pcall(function()
                  rem:FireServer(t, t.Position, HIT_NORMAL)
                end)
                if ok then statHits = statHits + 1 end
              end
            end
          end
        end)
      end

      -- ESP labels (top-N weakest in range)
      if meHRP then
        guarded("esp", function()
          for _, e in ipairs(espCache) do
            local L = e.lbl
            if L then L.Visible = false end
          end
          if F.esp_on then
            for _, e in ipairs(espCache) do
              local L = e.lbl
              if L and e.m.Parent then
                local sp, heard = wts(e.pos)
                if heard and F.esp_names and onScreenPt(sp, vs) then
                  local txt = e.m.Name
                  if e.hp and e.mh then
                    txt = txt .. " " .. math.floor(e.hp + 0.5) .. "/" .. math.floor(e.mh + 0.5)
                  end
                  L.Text = txt .. "  " .. math.floor(e.d + 0.5) .. "m"
                  if e.hp and e.mh and e.mh > 0 then
                    local f = clamp(e.hp / e.mh, 0, 1)
                    L.Color = Color3.new(1 - f * 0.7, 0.4 + f * 0.6, 1)
                  else
                    L.Color = F.esp_col
                  end
                  L.Position = V2(sp.X, sp.Y)
                  L.Visible = true
                end
              end
            end
          end
        end)
      else
        for _, rec in pairs(espMap) do
          if rec.lbl then pcall(function() rec.lbl.Visible = false end) end
        end
      end

      if statLbl and now - statTick > 2 then
        statTick = now
        pcall(function()
          statLbl.Set(("hits %d · broke %d · parts %d · %s"):format(statHits, statBroke, nParts, tourStatus))
          local s, m, money = playerStat("Shards"), playerStat("MaxShards"), playerStat("Money")
          if s and m then
            hud("cube", ("◆ shards %d/%d%s · %s"):format(math.floor(s), math.floor(m),
              money and (" · $%d"):format(math.floor(money)) or "", tourStatus))
          end
          local parts = { ("loop %dfps"):format(dbg.fps) }
          for _, sec in ipairs({ "scan", "farm", "esp" }) do
            if dbg.err[sec] then
              table.insert(parts, sec .. "!" .. dbg.err[sec])
            end
          end
          if dbg.last ~= "" then table.insert(parts, dbg.last) end
          dbgLbl.Set(table.concat(parts, " - "))
        end)
      end
      local cf = cubeFolder()
      if cf then
        local n = #cf:GetChildren()
        if n ~= nParts then nParts = n end
      end
    end)
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
    hud("cube", nil) -- drop the overlay line
    pcall(function()
      local ch = myChar()
      local hum = ch and ch:FindFirstChildOfClass("Humanoid")
      local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
      if hum and hrp then hum:Move(hrp.Position) end
    end)
    tourNoclip(false)
    if tourSpeedSet then
      tourSpeedSet = false
      pcall(function()
        local ch = myChar()
        local hum = ch and ch:FindFirstChildOfClass("Humanoid")
        if hum then hum.WalkSpeed = tourOrigSpeed or 16 end
      end)
      tourOrigSpeed = nil
    end
    for _, c in ipairs(CONNS) do pcall(function() c:Disconnect() end) end
    for _, page in pairs(pages) do page:Destroy() end
    for _, rec in pairs(espMap) do
      if rec.lbl then pcall(function() rec.lbl:Remove() end) end
      if rec.box then pcall(function() rec.box:Destroy() end) end
    end
    for k in pairs(espMap) do espMap[k] = nil end
    local g = getgenv and getgenv()
    if g then
      if g.__HUMA_PLACE and g.__HUMA_PLACE.Unload == unloadModule then g.__HUMA_PLACE = nil end
    end
    Notify("Cube", "Module unloaded", "info")
  end
  local function flagToggle(sec, name, key, desc, tip)
    return sec:Toggle({ Name = name, Desc = desc, Default = F[key] == true,
      Flag = "cb_" .. key, Tooltip = tip,
      Callback = function(v) F[key] = v == true end })
  end
  local function flagSlider(sec, name, key, min, max, extra)
    extra = extra or {}
    return sec:Slider({ Name = name, Min = min, Max = max, Default = F[key],
      Decimals = extra.dec or 0, Suffix = extra.suf or "", Flag = "cb_" .. key,
      Tooltip = extra.tip,
      Callback = function(v) F[key] = tonumber(v) or min end })
  end
  local function flagDropdown(sec, name, key, options, tip)
    return sec:Dropdown({ Name = name, Options = options, Default = F[key],
      Flag = "cb_" .. key, Tooltip = tip,
      Callback = function(v) F[key] = tostring(v) end })
  end
  local function flagColor(sec, name, key, tip)
    return sec:Color({ Name = name, Default = F[key], Flag = "cb_" .. key,
      Tooltip = tip, Callback = function(v) F[key] = v end })
  end

  local nav = api.Navigation or Tab:Navigation({ Name = "Cube" })
  local menuDefs = {
    { "Farm", "⛏", "Auto-hit" },
    { "ESP", "□", "Parts" },
    { "About", "i", "Status" },
  }
  for index, def in ipairs(menuDefs) do
    pages[def[1]] = nav:Page({ Id = "cb_" .. def[1]:lower(), Name = def[1],
      Icon = def[2], Tooltip = def[3], Order = index })
  end
  pages.Farm:Select()

  local farmSec = pages.Farm:Section({ Name = "Auto-hit" })
  farmSec:Paragraph("Hits the target part with the game's own Hit remote, paced. Weakest = lowest HP fraction.")
  flagToggle(farmSec, "Auto-hit", "farm_on")
  flagDropdown(farmSec, "Target", "farm_mode", { "Weakest", "Nearest" })
  flagSlider(farmSec, "Hits per second", "farm_rate", 1, 60,
    { tip = "The reference spams ~60/s. Lower is quieter." })
  flagSlider(farmSec, "Target range", "farm_range", 10, 1000, { suf = "m" })
  local sellSec = pages.Farm:Section({ Name = "Auto-sell" })
  sellSec:Paragraph("Sells by itself when the bag fills — but only standing by the podium (its 12m reach). No teleports.")
  flagToggle(sellSec, "Auto-sell", "sell_on")
  flagSlider(sellSec, "Sell when full at", "sell_at", 1, 100, { suf = "%" })
  sellLbl = sellSec:Label("shards ?/?")
  if type(fireproximityprompt) ~= "function" then
    sellSec:Paragraph("WARNING: this executor has no fireproximityprompt — auto-sell cannot work here.")
  end
  local gelSec = pages.Farm:Section({ Name = "Auto aqua" })
  gelSec:Paragraph("Presses the free water button for you, periodically.")
  flagToggle(gelSec, "Auto aqua", "gel_on")
  flagSlider(gelSec, "Every", "gel_every", 30, 600, { suf = "s" })
  local tourSec = pages.Farm:Section({ Name = "Loot tour" })
  tourSec:Paragraph("Walks the drops like a player (no teleports), bag-full walks home to the podium where auto-sell fires. Your WASD always wins.")
  flagToggle(tourSec, "Loot tour", "tour_on")
  flagDropdown(tourSec, "Move mode", "tour_mode", { "Walk", "Noclip", "Teleport" })
  tourSec:Paragraph("Walk = legit steps, slowest, safest. Noclip = through walls (server may yank). Teleport = hops, fastest, riskiest.")
  flagSlider(tourSec, "Tour radius", "tour_range", 50, 500, { suf = "m" })
  flagSlider(tourSec, "Walk speed", "tour_speed", 16, 100,
    { tip = "Applies during the tour, restores after" })
  flagSlider(tourSec, "Pause per pickup", "tour_pause", 0, 3,
    { dec = 1, suf = "s", tip = "Linger on each drop so the server registers it" })
  local espSec = pages.ESP:Section({ Name = "Parts" })
  espSec:Paragraph("Weakest parts first: labels with HP + unlimited wireframe boxes.")
  flagToggle(espSec, "Part ESP", "esp_on")
  flagToggle(espSec, "Names + HP", "esp_names")
  flagSlider(espSec, "Max distance", "esp_range", 50, 2000, { suf = "m" })
  flagSlider(espSec, "Shown count", "esp_count", 5, 60, { tip = "How many weakest parts get visuals" })
  flagColor(espSec, "Box color", "esp_col")

  local aboutSec = pages.About:Section({ Name = "About" })
  aboutSec:Label("DESTROY THE CUBE - hub module v" .. MODULE_VERSION)
  aboutSec:Paragraph("Auto-hit + part ESP. Own Hit remote only, paced — no teleports, no hooks.")
  statLbl = aboutSec:Label("hits 0 · broke 0 · parts 0")
  dbgLbl = aboutSec:Label("loop - fps")
  aboutSec:Button({ Name = "Unload module", Variant = "danger", Callback = function()
    unloadModule()
  end })

  local hub = { Unload = unloadModule }
  if getgenv then getgenv().__HUMA_PLACE = hub end
  return hub
end
