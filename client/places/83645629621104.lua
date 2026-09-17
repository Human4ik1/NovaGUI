--[[
  HumaHub place module — Forsaken (PlaceId 83645629621104).
  Repo path: client/places/83645629621104.lua

  Engineered from the open FORSAKICH script + our overlay stack.
  Place facts (verified live):
    - killer = any character with Humanoid MaxHealth > 250 (live: 2750);
    - survivors ~80-110hp, R6, characters under Workspace (pl.Character works);
    - generators: Workspace.Map.Ingame.Map children (Model) with
      Remotes/RF (RemoteFunction) + Remotes/RE (RemoteEvent);
    - items: Medkit / BloxyCola under Map + workspace models with ItemRoot.
  Eyes-only except Fix (which calls the game's own repair remote, same as
  pressing the prompt key — the reference script does the same).
]]

return function(api)
  local Tab, Notify = api.Tab, api.Notify
  local NovaUI = api.Nova
  local MODULE_VERSION = "2.1-fix"

  local runService = game:GetService("RunService")
  local players = game:GetService("Players")
  local workspace = game:GetService("Workspace")
  local userInput = game:GetService("UserInputService")
  local camera = workspace.CurrentCamera
  local LP = players.LocalPlayer
  local rayParams = RaycastParams.new()

  do
    local g = getgenv and getgenv()
    local prev = g and g.__HUMA_PLACE
    if prev and type(prev.Unload) == "function" then pcall(prev.Unload) end
  end

  local F = {
    esp_killer = false, esp_surv = false,
    esp_box = false, esp_health = false, esp_name = false, esp_dist = false,
    esp_thick = 2, esp_range = 4000,
    esp_killercol = Color3.fromRGB(220, 20, 60),
    esp_survcol = Color3.fromRGB(138, 43, 226),
    alert_on = false, alert_range = 200,
    flow_on = false, stam_on = false,
    build_col = Color3.fromRGB(255, 80, 0),
    glow_killer = false, glow_surv = false, glow_top = true,
    glow_killercol = Color3.fromRGB(220, 20, 60),
    glow_survcol = Color3.fromRGB(138, 43, 226),
    item_on = false, item_names = true, item_range = 2500,
    item_col = Color3.fromRGB(0, 255, 0),
    gen_on = false, gen_names = true, gen_range = 4000,
    gen_col = Color3.fromRGB(255, 165, 0),
    fix_key = Enum.KeyCode.B,
    aura_on = false, aura_range = 80, aura_rate = 3,
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
  local allocating
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
  local function charOf(plr)
    local ch = plr.Character
    if ch and ch.Parent then return ch end
    return nil
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
  local function isKiller(plr)
    -- primary: team folders (Workspace.Players.Killers/Survivors), live
    -- per match. Fallback: 250+ HP rule (verified: killer runs 2750).
    local ch = charOf(plr)
    if ch and type(workspace) == "table" and workspace.FindFirstChild then
      local ps = workspace:FindFirstChild("Players")
      if ps then
        local kf = ps:FindFirstChild("Killers")
        if kf and ch:IsDescendantOf(kf) then return true end
        local sf = ps:FindFirstChild("Survivors")
        if sf and ch:IsDescendantOf(sf) then return false end
      end
    end
    local hum = ch and ch:FindFirstChildOfClass("Humanoid")
    return hum and hum.MaxHealth > 250 or false
  end
  local function itemHeld(obj)
    -- carried items (hands/backpack) don't need world ESP
    for _, plr in ipairs(players:GetPlayers()) do
      local ch = plr.Character
      if ch and obj:IsDescendantOf(ch) then return true end
      local bp = plr:FindFirstChildOfClass("Backpack")
      if bp and obj:IsDescendantOf(bp) then return true end
    end
    return false
  end
  local function characterRect(ch, hrp, vs)
    local head = ch:FindFirstChild("Head")
    if head and (head.Position - hrp.Position).Magnitude > 12 then head = nil end
    local top3 = head and (head.Position + Vector3.new(0, head.Size.Y / 2, 0))
      or (hrp.Position + Vector3.new(0, 3, 0))
    local bot3 = hrp.Position - Vector3.new(0, 3.0, 0)
    local t2, tOn, tz = wts(top3)
    local b2, bOn, bz = wts(bot3)
    if not (tOn and bOn) or tz < 0.25 or bz < 0.25 then return nil end
    local h = math.max(math.abs(b2.Y - t2.Y), 8)
    if h ~= h or h > vs.Y * 1.5 then return nil end
    local w = math.max(h * 0.55, 8)
    local cx = (t2.X + b2.X) / 2
    local x0, y0 = cx - w / 2, math.min(t2.Y, b2.Y)
    return x0, y0, w, h, cx
  end
  local function onScreen2(x0, y0, w, h, vs, m)
    m = m or 80
    return x0 + w > -m and x0 < vs.X + m and y0 + h > -m and y0 < vs.Y + m
  end
  local function onScreenPt(p, vs, m)
    m = m or 64
    return p.X > -m and p.X < vs.X + m and p.Y > -m and p.Y < vs.Y + m
  end

  -- --------------------------------------------------------------------------
  -- Persistent player rigs
  -- --------------------------------------------------------------------------
  local pesc = {}
  local function mkSq(fill)
    local s = shape("Square")
    pcall(function()
      s.Filled = fill == true
      s.Transparency = 1
      s.ZIndex = fill and 1 or 2
      s.Visible = false
    end)
    return s
  end
  local function mkTx(size)
    local t = shape("Text")
    pcall(function()
      t.Center = true
      t.Outline = true
      t.Transparency = 1
      t.Font = 2
      t.ZIndex = 4
      t.Size = size or 13
      t.Visible = false
    end)
    return t
  end
  local function mkLn()
    local l = shape("Line")
    pcall(function()
      l.Transparency = 1
      l.ZIndex = 2
      l.Visible = false
    end)
    return l
  end
  local RIG_KEYS = { "outline", "box", "hback", "hfill", "name", "dist" }
  local rigRetry = {}
  local function rigOf(plr)
    local e = pesc[plr]
    if e then return e end
    if (rigRetry[plr] or 0) > os.clock() then return nil end
    local made = {}; allocating = made
    local ok = pcall(function()
      e = {}
      e.outline = mkSq(false)
      e.box = mkSq(false)
      e.hback = mkSq(true)
      e.hfill = mkSq(true)
      e.name = mkTx(13)
      e.dist = mkTx(12)
      e.trace = mkLn()
    end)
    allocating = nil
    if not ok then
      for _, object in ipairs(made) do pcall(function() object:Remove() end) end
      rigRetry[plr] = os.clock() + 2
      return nil
    end
    rigRetry[plr] = nil
    pesc[plr] = e
    return e
  end
  local function hideRig(e)
    if not e then return end
    for _, k in ipairs(RIG_KEYS) do
      local o = e[k]
      if o then pcall(function() o.Visible = false end) end
    end
  end
  local function freeRig(plr)
    local e = pesc[plr]
    if not e then return end
    for _, k in ipairs(RIG_KEYS) do
      local o = e[k]
      if o then pcall(function() o:Remove() end) end
    end
    pesc[plr] = nil
  end
  reg(players.PlayerRemoving:Connect(function(plr) freeRig(plr); rigRetry[plr] = nil end))

  -- --------------------------------------------------------------------------
  -- Glow (nearest-first, engine-capped pools)
  -- --------------------------------------------------------------------------
  local glowMap, glowSeenT = {}, {}
  local glowIds, glowNext = setmetatable({}, { __mode = "k" }), 0
  local function glowKey(o, tag)
    if not glowIds[o] then glowNext = glowNext + 1; glowIds[o] = glowNext end
    return tag .. "_" .. glowIds[o]
  end
  local GLOW_ENTITY_CAP, GLOW_LOOT_CAP = 20, 10
  local glowUsedEntity, glowUsedLoot = 0, 0
  local function setGlow(model, col, on, tag, pool)
    if not model or not model.Parent then return end
    local key = glowKey(model, tostring(tag))
    local prev = glowMap[key]
    if not on then
      if prev then pcall(function() prev:Destroy() end) end
      glowMap[key] = nil
      glowSeenT[key] = nil
      return
    end
    local isLoot = pool == "loot"
    if prev and prev.Parent then
      glowSeenT[key] = os.clock()
      if isLoot then glowUsedLoot = glowUsedLoot + 1
      else glowUsedEntity = glowUsedEntity + 1 end
      pcall(function()
        if prev.FillColor ~= col then prev.FillColor = col end
        prev.DepthMode = F.glow_top and Enum.HighlightDepthMode.AlwaysOnTop
          or Enum.HighlightDepthMode.Occluded
      end)
      return
    end
    if isLoot then
      if glowUsedLoot >= GLOW_LOOT_CAP then return end
      glowUsedLoot = glowUsedLoot + 1
    else
      if glowUsedEntity >= GLOW_ENTITY_CAP then return end
      glowUsedEntity = glowUsedEntity + 1
    end
    local ok, hl = pcall(function()
      local h = Instance.new("Highlight")
      h.Name = "ForsakenFX"
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
    if glowMap[key] then glowSeenT[key] = os.clock() end
  end
  local function gcGlow(seen, stamp)
    local now = stamp or os.clock()
    local live = 0
    for _ in pairs(glowMap) do live = live + 1 end
    local grace = (live < 30) and 2 or 0
    for k, h in pairs(glowMap) do
      if not seen[k] then
        if now - (glowSeenT[k] or 0) > grace then
          pcall(function() h:Destroy() end)
          glowMap[k] = nil
          glowSeenT[k] = nil
        end
      end
    end
  end

  -- --------------------------------------------------------------------------
  -- World scans (generators + items, every 2s)
  -- --------------------------------------------------------------------------
  local genCache, itemCache = {}, {}
  local genMap, itemMap = {}, {}
  local syncLabelMaps -- fwd
  local function mapRoot()
    local mf = workspace:FindFirstChild("Map")
    local ig = mf and mf:FindFirstChild("Ingame")
    return ig and ig:FindFirstChild("Map") or nil
  end
  local function scanWorld()
    local gens, items, seen = {}, {}, {}
    local mp = mapRoot()
    if mp then
      local ok, desc = pcall(function() return mp:GetDescendants() end)
      if ok then
        for _, v in ipairs(desc) do
          if moduleDead then return end
          local rem = v:FindFirstChild("Remotes")
          if rem and rem:FindFirstChild("RF") then
            local owner = v
            while owner.Parent and owner.Parent ~= mp do owner = owner.Parent end
            if not seen[owner] then
              seen[owner] = true
              local okB, cf = pcall(function() return owner:GetBoundingBox() end)
              if okB and cf then
                local prog = owner:FindFirstChild("Progress")
                if not (prog and prog:IsA("NumberValue")) then prog = nil end
                gens[#gens + 1] = { m = owner, pos = cf.Position, name = owner.Name, prog = prog }
              end
            end
          end
        end
        for _, nm in ipairs({ "Medkit", "BloxyCola" }) do
          local it = mp:FindFirstChild(nm)
          if it and not seen[it] then
            seen[it] = true
            local pos = nil
            pcall(function()
              local p = it:IsA("BasePart") and it or it:FindFirstChildWhichIsA("BasePart", true)
              if p then pos = p.Position end
            end)
            if pos then items[#items + 1] = { m = it, pos = pos, name = nm } end
          end
        end
      end
    end
    -- workspace-level dropped items (ItemRoot models), skipping carried ones
    do
      local ok, desc = pcall(function() return workspace:GetChildren() end)
      if ok then
        for _, v in ipairs(desc) do
          if v:FindFirstChild("ItemRoot") and not seen[v] and not itemHeld(v) then
            seen[v] = true
            local pos = nil
            pcall(function()
              local p = v:IsA("BasePart") and v or v:FindFirstChildWhichIsA("BasePart", true)
              if p then pos = p.Position end
            end)
            if pos then items[#items + 1] = { m = v, pos = pos, name = v.Name } end
          end
        end
      end
    end
    -- builderman buildings (sentries/tripmines/dispensers)
    do
      local ig = mp and mp.Parent or nil
      if ig then
        for _, v in ipairs(ig:GetChildren()) do
          if (v.Name == "BuildermanSentry" or v.Name == "SubspaceTripmine" or v.Name == "BuildermanDispenser")
            and not seen[v] then
            seen[v] = true
            local pos = nil
            pcall(function()
              local p = v:IsA("BasePart") and v or v:FindFirstChildWhichIsA("BasePart", true)
              if p then pos = p.Position end
              if not pos then pos = v:GetBoundingBox().Position end
            end)
            if pos then items[#items + 1] = { m = v, pos = pos, name = v.Name, build = true } end
          end
        end
      end
    end
    local myPos = myHRP() and myHRP().Position or nil
    if myPos then
      local function byDist(a, b)
        local da = (a.pos - myPos).Magnitude
        local db = (b.pos - myPos).Magnitude
        return da < db
      end
      table.sort(gens, byDist)
      table.sort(items, byDist)
    end
    if moduleDead then return end
    genCache, itemCache = gens, items
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
        local m = entry.m
        local pos = entry.pos
        if m.Parent and (m:IsA("BasePart") or m:IsA("Model") or m:IsA("Tool")) then
          if m:IsA("Model") then
            local ok, cf = pcall(function() return m:GetBoundingBox() end)
            if ok and cf then pos = cf.Position end
          elseif m:IsA("BasePart") then
            pos = m.Position
          else
            local p = m:FindFirstChildWhichIsA("BasePart", true)
            if p then pos = p.Position end
          end
        end
        entry.pos = pos or entry.pos
        local active = enabled == true
        if HAS_DRAWING and root and active and m.Parent and entry.pos
          and (entry.pos - root.Position).Magnitude <= range then
          seen[m] = true
          if not map[m] then map[m] = { lbl = mkLabel(size) } end
          entry.lbl = map[m].lbl
        else entry.lbl = nil end
      end
      for object, record in pairs(map) do
        if not seen[object] then killDraw(record.lbl); map[object] = nil end
      end
    end
    sync(genCache, genMap, (F.gen_on and F.gen_names) == true, F.gen_range, 13)
    sync(itemCache, itemMap, (F.item_on and F.item_names) == true, F.item_range, 12)
  end

  -- --------------------------------------------------------------------------
  -- FlowGame minigame auto-solve (hooks the game's own solver table in
  -- memory; restored on unload. Solves the generator flow puzzle for you.)
  -- --------------------------------------------------------------------------
  local flowOrigNew, flowFG = nil, nil
  local function flowKey(n) return n.row .. "-" .. n.col end
  local function flowNeighbour(r1, c1, r2, c2)
    if r2 == r1 - 1 and c2 == c1 then return true end
    if r2 == r1 + 1 and c2 == c1 then return true end
    if r2 == r1 and c2 == c1 - 1 then return true end
    if r2 == r1 and c2 == c1 + 1 then return true end
    return false
  end
  local function flowSolve(puzzle)
    if not puzzle or not puzzle.Solution then return end
    for _, ci in ipairs((function()
      local idx = {}
      for i = 1, #puzzle.Solution do idx[i] = i end
      return idx
    end)()) do
      if moduleDead or not F.flow_on then return end
      local solution = puzzle.Solution[ci]
      if solution then
        -- order path from an endpoint inward
        local lookup = {}
        for _, n in ipairs(solution) do lookup[flowKey(n)] = n end
        local start = solution[1]
        for _, n in ipairs(solution) do
          local nb = 0
          for _, d in ipairs({ { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 } }) do
            if lookup[(n.row + d[1]) .. "-" .. (n.col + d[2])] then nb = nb + 1 end
          end
          if nb == 1 then start = n break end
        end
        local pool, ordered = {}, {}
        for _, n in ipairs(solution) do pool[flowKey(n)] = { row = n.row, col = n.col } end
        local cur = { row = start.row, col = start.col }
        table.insert(ordered, cur)
        pool[flowKey(cur)] = nil
        while next(pool) do
          local moved = false
          for k, node in pairs(pool) do
            if flowNeighbour(cur.row, cur.col, node.row, node.col) then
              table.insert(ordered, { row = node.row, col = node.col })
              pool[k] = nil; cur = node; moved = true; break
            end
          end
          if not moved then break end
        end
        puzzle.paths[ci] = {}
        for _, node in ipairs(ordered) do
          if moduleDead or not F.flow_on then return end
          table.insert(puzzle.paths[ci], { row = node.row, col = node.col })
          pcall(function() puzzle:updateGui() end)
          task.wait(0.05)
        end
        task.wait(0.5)
        pcall(function() puzzle:checkForWin() end)
      end
    end
  end
  local function flowHook()
    local ok, FG = pcall(function()
      local mods = game:GetService("ReplicatedStorage"):FindFirstChild("Modules")
      local mini = mods and mods:FindFirstChild("Minigames")
      local fg = mini and mini:FindFirstChild("FlowGameManager")
      local mod = fg and fg:FindFirstChild("FlowGame")
      return mod and require(mod) or nil
    end)
    if ok and FG and FG.new and not flowOrigNew then
      flowOrigNew, flowFG = FG.new, FG
      FG.new = function(...)
        local p = flowOrigNew(...)
        if F.flow_on then
          task.spawn(function()
            task.wait(0.3)
            if F.flow_on and not moduleDead then flowSolve(p) end
          end)
        end
        return p
      end
    end
    return ok and FG ~= nil
  end

  -- --------------------------------------------------------------------------
  -- Infinite stamina (game's own sprint table, refreshed, restored on unload)
  -- --------------------------------------------------------------------------
  local stamMod = nil
  local stamOrig = nil
  local function stamApply()
    if not F.stam_on then return end
    if not stamMod then
      pcall(function()
        stamMod = require(game:GetService("ReplicatedStorage").Systems.Character.Game.Sprinting)
      end)
      if not stamMod then return end
    end
    pcall(function()
      if stamOrig == nil then
        stamOrig = { loss = stamMod.StaminaLoss, dis = stamMod.StaminaLossDisabled }
      end
      stamMod.StaminaLoss = 0
      stamMod.StaminaLossDisabled = true
    end)
  end
  local function stamRestore()
    if stamMod and stamOrig then
      pcall(function()
        stamMod.StaminaLoss = stamOrig.loss
        stamMod.StaminaLossDisabled = stamOrig.dis
      end)
    end
    stamMod, stamOrig = nil, nil
  end
  -- --------------------------------------------------------------------------
  -- Fix (the game's own repair remote, same as the prompt key)
  -- --------------------------------------------------------------------------
  local fixBusy = false
  local function genProgress(e)
    if e.prog and e.prog.Parent then
      local ok, v = pcall(function() return e.prog.Value end)
      if ok and type(v) == "number" then return v end
    end
    return nil
  end
  local function findNearestGen(range, skipDone)
    local root = myHRP()
    if not root then return nil end
    local best, bestD = nil, range or math.huge
    for _, e in ipairs(genCache) do
      if e.m.Parent then
        local d = (e.pos - root.Position).Magnitude
        if d == d and d < bestD then
          if not skipDone then
            best, bestD = e, d
          else
            local p = genProgress(e)
            if p == nil or p < 100 then best, bestD = e, d end
          end
        end
      end
    end
    return best
  end
  local function findPrompt(gen)
    local ok, pr = pcall(function()
      local main = gen:FindFirstChild("Main")
      local p = main and main:FindFirstChild("Prompt")
      if p and p:IsA("ProximityPrompt") then return p end
      return gen:FindFirstChildWhichIsA("ProximityPrompt", true)
    end)
    return ok and pr or nil
  end
  local function fixGenerator(entry)
    if fixBusy then return false end
    local remotes = entry.m:FindFirstChild("Remotes", true)
    if not remotes then return false end
    fixBusy = true
    -- watchdog: a hanging InvokeServer must never wedge the fixer forever
    task.delay(5, function() fixBusy = false end)
    task.spawn(function()
      -- full manual flow, automated: hold the prompt like E, then the
      -- game's own repair remote. Prompt-hold is what a hand repair does;
      -- the remote alone is ignored without it.
      local prompt = findPrompt(entry.m)
      if prompt and type(fireproximityprompt) == "function" then
        pcall(fireproximityprompt, prompt)
      end
      pcall(function()
        local rf = remotes:FindFirstChild("RF")
        if rf then rf:InvokeServer() end
      end)
      for _ = 1, 2 do
        task.wait(0.3)
        pcall(function()
          local re = remotes:FindFirstChild("RE")
          if re then re:FireServer() end
        end)
      end
      fixBusy = false
    end)
    return true
  end

  -- --------------------------------------------------------------------------
  -- Status
  -- --------------------------------------------------------------------------
  local statLbl, dbgLbl
  local statTick, scanTick, labelTick, auraTick, stamTick, nP, nK = 0, 0, 0, 0, 0, 0, 0
  local killerNear, killerDist = false, math.huge

  -- --------------------------------------------------------------------------
  -- Main loop (eyes + camera + own repair remote only)
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
      if now - scanTick > 2 then scanTick = now; guarded("scan", scanWorld) end
      if now - labelTick > 0.5 then labelTick = now; guarded("labels", syncLabelMaps) end
      local me = myChar()
      frameMe = me
      local meHRP = me and me:FindFirstChild("HumanoidRootPart")
      local vs = camera.ViewportSize
      local seenGlow = {}
      glowUsedEntity, glowUsedLoot = 0, 0
      nP, nK = 0, 0
      killerNear, killerDist = false, math.huge

      -- players
      if meHRP then
        local plist = players:GetPlayers()
        for _, pl in ipairs(plist) do
          if pl ~= LP then
            local playerOk = guarded("players", function()
              local e = pesc[pl]
              local ch = charOf(pl)
              local hum = ch and ch:FindFirstChildOfClass("Humanoid")
              local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
              if not (ch and hum and hum.Health > 0 and hrp) then hideRig(e) return end
              local d = (meHRP.Position - hrp.Position).Magnitude
              if d ~= d or d > F.esp_range then hideRig(e) return end
              nP = nP + 1
              local killer = isKiller(pl)
              if killer then
                nK = nK + 1
                if d < killerDist then killerDist = d end
                if d <= (F.alert_range or 200) then killerNear = true end
              end
              local show = (killer and F.esp_killer) or ((not killer) and F.esp_surv)
              local col = killer and F.esp_killercol or F.esp_survcol
              local gcol = killer and F.glow_killercol or F.glow_survcol
              local gon = (killer and F.glow_killer) or ((not killer) and F.glow_surv)
              if gon then
                local key = glowKey(ch, killer and "k" or "s")
                setGlow(ch, gcol, true, killer and "k" or "s")
                seenGlow[key] = true
              end
              if not F.esp_box and not F.esp_health and not F.esp_name and not F.esp_dist then
                hideRig(e) return
              end
              if not show then hideRig(e) return end
              e = rigOf(pl)
              if not e then return end
              local x0, y0, w, h, cx = characterRect(ch, hrp, vs)
              if not x0 then hideRig(e) return end
              if not onScreen2(x0, y0, w, h, vs, 120) then hideRig(e) return end
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
              e.trace.Visible = false
              e.name.Visible = F.esp_name == true
              if e.name.Visible then
                e.name.Text = pl.DisplayName ~= pl.Name
                  and (pl.DisplayName .. " (@" .. pl.Name .. ")") or pl.Name
                e.name.Color = col
                e.name.Position = V2(cx, y0 - 17)
              end
              local wy = y0 + h + 3
              e.dist.Visible = F.esp_dist == true
              if e.dist.Visible then
                e.dist.Text = dm
                e.dist.Color = col
                e.dist.Position = V2(cx, wy)
              end
            end)
            if not playerOk then freeRig(pl); rigRetry[pl] = os.clock() + 2 end
          end
        end
      else
        for _, e in pairs(pesc) do hideRig(e) end
      end

      -- items + generators (labels + loot-pool glow)
      if meHRP then
        guarded("world", function()
          local mp = meHRP.Position
          local function draw(cache, on, names, col, poolTag)
            for _, e in ipairs(cache) do
              local L = e.lbl
              if L then L.Visible = false end
              if on and e.m.Parent and e.pos then
                local d = (mp - e.pos).Magnitude
                local range = (poolTag == "g") and (F.gen_range or 4000) or (F.item_range or 2500)
                if d == d and d <= range then
                  local sp, heard = wts(e.pos)
                  if L and heard and names and onScreenPt(sp, vs) then
                    local tag = e.name
                    if e.prog and e.prog.Parent then
                      local okP, pv = pcall(function() return e.prog.Value end)
                      if okP and type(pv) == "number" then
                        tag = ("Generator %d%%"):format(clamp(math.floor(pv + 0.5), 0, 100))
                      end
                    elseif e.build then
                      tag = e.name
                    end
                    L.Text = tag .. "  " .. math.floor(d + 0.5) .. "m"
                    L.Color = e.build and F.build_col or col
                    L.Position = V2(sp.X, sp.Y)
                    L.Visible = true
                  end
                end
              end
            end
          end
          draw(genCache, F.gen_on == true, F.gen_names == true, F.gen_col, "g")
          draw(itemCache, F.item_on == true, F.item_names == true, F.item_col, "i")
          -- glow pass, nearest-first (caches are sorted)
          local shown = 0
          local cap = GLOW_LOOT_CAP
          local function glow(cache, on, col)
            if not on then return end
            for _, e in ipairs(cache) do
              if shown >= cap then return end
              if e.m.Parent and e.pos and (mp - e.pos).Magnitude <= ((cache == genCache) and (F.gen_range or 4000) or (F.item_range or 2500)) then
                local key = glowKey(e.m, cache == genCache and "g" or "i")
                setGlow(e.m, col, true, cache == genCache and "g" or "i", "loot")
                seenGlow[key] = true
                shown = shown + 1
              end
            end
          end
          glow(genCache, F.gen_on == true, F.gen_col)
          glow(itemCache, F.item_on == true, F.item_col)
        end)
      else
        for _, o in pairs(genMap) do
          if o.lbl then pcall(function() o.lbl.Visible = false end) end
        end
        for _, o in pairs(itemMap) do
          if o.lbl then pcall(function() o.lbl.Visible = false end) end
        end
      end

      -- killer proximity alert: quiet dot under the crosshair
      if F.alert_on and killerNear then
        guarded("hud", function()
          local warn = tshape("Circle")
          warn.Color = Color3.fromRGB(220, 20, 60)
          warn.Transparency = 1
          warn.Filled = false
          warn.Thickness = 2
          warn.NumSides = 24
          warn.Radius = 9
          warn.Position = V2(vs.X / 2, vs.Y / 2 + 30)
        end)
      end

      -- auto-fix aura (same remote as the prompt key, throttled)
      if F.aura_on and meHRP and now - auraTick > (tonumber(F.aura_rate) or 3) then
        auraTick = now
        guarded("aura", function()
          local g = findNearestGen(tonumber(F.aura_range) or 80, true)
          if g then fixGenerator(g) end
        end)
      end
      if F.stam_on and now - stamTick > 0.5 then
        stamTick = now
        guarded("stam", stamApply)
      elseif not F.stam_on and stamMod then
        guarded("stam", stamRestore)
      end

      gcGlow(seenGlow)

      if statLbl and now - statTick > 2 then
        statTick = now
        pcall(function()
          statLbl.Set(("players %d · killers %d%s%s"):format(nP, nK,
            (F.alert_on and killerNear) and (" · KILLER " .. math.floor(killerDist + 0.5) .. "m") or "",
            #genCache > 0 and (" · gens " .. #genCache) or ""))
          local parts = { ("loop %dfps"):format(dbg.fps) }
          table.insert(parts, ("glow E%d/20 L%d/10"):format(
            math.min(glowUsedEntity, 99), math.min(glowUsedLoot, 99)))
          for _, sec in ipairs({ "scan", "labels", "players", "world", "aura", "hud" }) do
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
    pcall(stamRestore)
    if flowFG and flowOrigNew then
      pcall(function() flowFG.new = flowOrigNew end)
      flowFG, flowOrigNew = nil, nil
    end
    for _, h in pairs(glowMap) do pcall(function() h:Destroy() end) end
    for k in pairs(glowMap) do glowMap[k] = nil end
    for k in pairs(glowSeenT) do glowSeenT[k] = nil end
    for pl in pairs(pesc) do freeRig(pl) end
    for _, maps in ipairs({ genMap, itemMap }) do
      for m, o in pairs(maps) do
        if o.lbl then pcall(function() o.lbl:Remove() end) end
        maps[m] = nil
      end
    end
    local g = getgenv and getgenv()
    if g then
      if g.__HUMA_PLACE and g.__HUMA_PLACE.Unload == unloadModule then g.__HUMA_PLACE = nil end
    end
    Notify("Forsaken", "Module unloaded", "info")
  end

  -- --------------------------------------------------------------------------
  -- UI: ESP / Fix / About
  -- --------------------------------------------------------------------------
  local function flagToggle(sec, name, key, desc, tip)
    return sec:Toggle({ Name = name, Desc = desc, Default = F[key] == true,
      Flag = "fs_" .. key, Tooltip = tip,
      Callback = function(v) F[key] = v == true end })
  end
  local function flagSlider(sec, name, key, min, max, extra)
    extra = extra or {}
    return sec:Slider({ Name = name, Min = min, Max = max, Default = F[key],
      Decimals = extra.dec or 0, Suffix = extra.suf or "", Flag = "fs_" .. key,
      Tooltip = extra.tip,
      Callback = function(v) F[key] = tonumber(v) or min end })
  end
  local function flagColor(sec, name, key, tip)
    return sec:Color({ Name = name, Default = F[key], Flag = "fs_" .. key,
      Tooltip = tip, Callback = function(v) F[key] = v end })
  end

  local nav = api.Navigation or Tab:Navigation({ Name = "Forsaken" })
  local menuDefs = {
    { "ESP", "□", "Killers, survivors, items, generators" },
    { "Fix", "⚒", "Generator repair (watched!)" },
    { "About", "i", "Status" },
  }
  for index, def in ipairs(menuDefs) do
    pages[def[1]] = nav:Page({ Id = "fsk_" .. def[1]:lower(), Name = def[1],
      Icon = def[2], Tooltip = def[3], Order = index })
  end
  pages.ESP:Select()
  local espTabs = pages.ESP:SubTabs({ { Name = "Players" }, { Name = "Items" } })

  local pSec = espTabs.Players:Section({ Name = "Players" })
  pSec:Paragraph("Killer = red (250+ HP rule). Everyone else = survivor purple.")
  if not HAS_DRAWING then
    pSec:Paragraph("WARNING: this executor has no Drawing API. Glow (Highlight) still works.")
  end
  flagToggle(pSec, "Killer ESP", "esp_killer")
  flagToggle(pSec, "Survivor ESP", "esp_surv")
  flagToggle(pSec, "Boxes", "esp_box")
  flagToggle(pSec, "Health bar", "esp_health")
  flagToggle(pSec, "Names", "esp_name")
  flagToggle(pSec, "Distance", "esp_dist")
  flagSlider(pSec, "Thickness", "esp_thick", 1, 5)
  flagSlider(pSec, "Range", "esp_range", 200, 6000, { suf = "m" })
  flagColor(pSec, "Killer color", "esp_killercol")
  flagColor(pSec, "Survivor color", "esp_survcol")
  local alSec = espTabs.Players:Section({ Name = "Killer alert" })
  alSec:Paragraph("Quiet dot under the crosshair + distance in About while the killer is close.")
  flagToggle(alSec, "Killer alert", "alert_on")
  flagSlider(alSec, "Alert range", "alert_range", 50, 1000, { suf = "m" })
  local gSec = espTabs.Players:Section({ Name = "Glow" })
  gSec:Paragraph("Client-side Highlights (see-through chams).")
  flagToggle(gSec, "Killer glow", "glow_killer")
  flagToggle(gSec, "Survivor glow", "glow_surv")
  flagToggle(gSec, "Through walls", "glow_top")
  flagColor(gSec, "Killer glow", "glow_killercol")
  flagColor(gSec, "Survivor glow", "glow_survcol")
  local iSec = espTabs.Items:Section({ Name = "Items" })
  iSec:Paragraph("Medkits + Bloxy Cola, on the map and dropped.")
  flagToggle(iSec, "Item ESP", "item_on")
  flagToggle(iSec, "Names", "item_names")
  flagSlider(iSec, "Max distance", "item_range", 200, 6000, { suf = "m" })
  flagColor(iSec, "Color", "item_col")
  local genSec = espTabs.Items:Section({ Name = "Generators" })
  genSec:Paragraph("Generator objectives, nearest-first.")
  flagToggle(genSec, "Generator ESP", "gen_on")
  flagToggle(genSec, "Names", "gen_names")
  flagSlider(genSec, "Max distance", "gen_range", 200, 8000, { suf = "m" })
  flagColor(genSec, "Color", "gen_col")

  local fixSec = pages.Fix:Section({ Name = "Repair" })
  fixSec:Paragraph("Holds the repair prompt like E, then the generator's own remote (RF + RE). Skips finished (100%) generators.")
  fixSec:Button({ Name = "Fix nearest generator", Callback = function()
    local g = findNearestGen(1e9, true)
    if not g then Notify("Fix", "No unfinished generator found", "warn"); return end
    if fixGenerator(g) then Notify("Fix", "Repair sent → " .. g.name, "ok") end
  end })
  fixSec:Keybind({ Name = "Fix key", Default = F.fix_key, Flag = "fs_fix_key",
    Callback = function(v) F.fix_key = v end }):OnPress(function()
    local g = findNearestGen(tonumber(F.aura_range) or 80, true)
    if g then
      if fixGenerator(g) then Notify("Fix", "Repair sent → " .. g.name, "ok") end
    else
      Notify("Fix", "No unfinished generator in range", "info")
    end
  end)
  local auraSec = pages.Fix:Section({ Name = "Auto-fix aura" })
  auraSec:Paragraph("Repairs the nearest generator in radius on a timer. Convenient, noisy — use wisely.")
  flagToggle(auraSec, "Auto-fix aura", "aura_on")
  flagSlider(auraSec, "Radius", "aura_range", 10, 400, { suf = "m" })
  flagSlider(auraSec, "Every", "aura_rate", 1, 15, { dec = 1, suf = "s" })
  local flowSec = pages.Fix:Section({ Name = "Minigame solver" })
  flowSec:Paragraph("Auto-solves the generator flow puzzle when it pops up. Hooks the game's solver table (restored on unload).")
  flowSec:Toggle({ Name = "Auto-solve flow puzzle", Default = F.flow_on == true, Flag = "fs_flow_on",
    Tooltip = "Arms the solver hook on enable",
    Callback = function(v)
      F.flow_on = v == true
      if v then task.spawn(function() guarded("flowhook", flowHook) end) end
    end })
  local stamSec = pages.Fix:Section({ Name = "Stamina" })
  stamSec:Paragraph("Zeroes stamina drain via the game's sprint table. Restored on off/unload.")
  flagToggle(stamSec, "Infinite stamina", "stam_on")

  local aboutSec = pages.About:Section({ Name = "About" })
  aboutSec:Label("FORSAKEN - hub module v" .. MODULE_VERSION)
  aboutSec:Paragraph("Killer/survivor ESP + items + generators + repair. Eyes-only except Fix (own remote).")
  statLbl = aboutSec:Label("players 0 · killers 0")
  dbgLbl = aboutSec:Label("loop - fps")
  aboutSec:Button({ Name = "Rebuild overlays", Variant = "ghost", Callback = function()
    freeTransient()
    for _, maps in ipairs({ genMap, itemMap }) do
      for m, o in pairs(maps) do
        if o.lbl then pcall(function() o.lbl:Remove() end) end
        maps[m] = nil
      end
    end
    for _, cache in ipairs({ genCache, itemCache }) do
      for _, entry in ipairs(cache) do entry.lbl = nil end
    end
    for _, h in pairs(glowMap) do pcall(function() h:Destroy() end) end
    for k in pairs(glowMap) do glowMap[k] = nil end
    for k in pairs(glowSeenT) do glowSeenT[k] = nil end
    HAS_DRAWING = pcall(function() local probe = Drawing.new("Square"); probe:Remove() end)
    guarded("labels", syncLabelMaps)
    Notify("Forsaken", HAS_DRAWING and "Overlays rebuilt" or "Drawing API unavailable", HAS_DRAWING and "ok" or "warn")
  end })
  aboutSec:Button({ Name = "Unload module", Variant = "danger", Callback = function()
    unloadModule()
  end })

  local hub = { Unload = unloadModule }
  if getgenv then getgenv().__HUMA_PLACE = hub end
  return hub
end
