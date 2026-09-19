--[[
  HumaHub place module — Forsaken (PlaceId 83645629621104).
  Repo path: client/places/83645629621104.lua

  Place facts (verified live + wiki):
    - killer = any character with Humanoid MaxHealth > 250 (live: 2750);
      team folders Workspace.Players.Killers/Survivors when present;
    - survivors ~80-110hp, R6, characters under Workspace (pl.Character works);
    - generators: Workspace.Map.Ingame.Map children (Model) with
      Remotes/RF (RemoteFunction) + Remotes/RE (RemoteEvent), NumberValue
      Progress; Noli rounds add 2 FAKE gens (total 7, fakes give
      Hallucination instead of progress);
    - items: Medkit / BloxyCola under Map + workspace models with ItemRoot;
    - Taph: Tripwire + Subspace Tripmine (19m trigger); Azure: Seeker Bulb +
      Stigmatize Vines; Veeronica: wall Graffiti; Two-Time: Ritual point;
      Builderman: BuildermanSentry / BuildermanDispenser / SubspaceTripmine;
    - stamina: ReplicatedStorage.Systems.Character.Game.Sprinting table
      (StaminaLoss / StaminaLossDisabled verified; max/speed/regen applied
      only when those fields exist — names differ per patch).
  Eyes-only except: stamina table edits, client collision/touch flags,
  camera aim, GenFix prompt firing (same as pressing the key yourself).
  GenFix automation can still trip the server (267) — it defaults OFF and
  says so in the UI.
]]

return function(api)
  local Tab, Notify = api.Tab, api.Notify
  local MODULE_VERSION = "3.1-rework"

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
    -- Visual / Players
    esp_killer = false, esp_surv = false,
    esp_box = false, esp_health = false, esp_name = false, esp_dist = false,
    esp_thick = 2, esp_range = 4000,
    esp_killercol = Color3.fromRGB(220, 20, 60),
    esp_survcol = Color3.fromRGB(138, 43, 226),
    alert_on = false, alert_range = 200,
    glow_killer = false, glow_surv = false, glow_top = true,
    glow_killercol = Color3.fromRGB(220, 20, 60),
    glow_survcol = Color3.fromRGB(138, 43, 226),
    -- Visual / Items
    item_on = false, item_names = true, item_range = 2500,
    item_col = Color3.fromRGB(0, 255, 0),
    gen_on = false, gen_names = true, gen_range = 4000,
    gen_col = Color3.fromRGB(255, 165, 0),
    -- Visual / Other (per-kind ESP + colors)
    o_graffiti = false, o_graffiti_col = Color3.fromRGB(255, 0, 255),
    o_taph = false, o_taph_col = Color3.fromRGB(255, 255, 0),
    o_azure = false, o_azure_col = Color3.fromRGB(0, 255, 255),
    azure_radius = 19, azure_radius_on = false,
    o_ritual = false, o_ritual_col = Color3.fromRGB(255, 255, 255),
    o_build = false, o_build_col = Color3.fromRGB(255, 80, 0),
    o_fake = false, o_fake_col = Color3.fromRGB(120, 0, 200),
    fake_realcount = 5, other_range = 2500, other_extra = "",
    -- Stamina (per role; same sprint table underneath)
    stam_surv_on = false, stam_surv_max = 100, stam_surv_speed = 0,
    stam_surv_regen = 0,
    stam_killer_on = false, stam_killer_max = 100, stam_killer_speed = 0,
    stam_killer_regen = 0,
    -- GenFix (flow solver kept from previous version)
    flow_on = false, flow_node = 0.05, flow_line = 0.5,
    genfix_on = false, genfix_key = nil, genfix_mode = "Random",
    genfix_custom = "—", genfix_rate = 1.0, genfix_hideui = false,
    -- Antis / Movement
    anti_slow = false, anti_stun = false, anti_root = false,
    -- Antis / Debuffs
    deb_gui = false, deb_post = false,
    -- Antis / Exploits
    x_doors = false, x_trapimmune = false,
    -- AimBot
    aim_on = false, aim_key = nil, aim_target = "Killer",
    aim_smooth = 8, aim_fov = 300, aim_part = "Head",
    -- AutoCombat (UI only for now)
    ac_surv_mode = "Assist", ac_killer_mode = "Assist",
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
  local function partPos(m)
    local pos = nil
    pcall(function()
      local p = m:IsA("BasePart") and m or m:FindFirstChildWhichIsA("BasePart", true)
      if p then pos = p.Position end
      if not pos then pos = m:GetBoundingBox().Position end
    end)
    return pos
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
  -- highlights go stale (round transitions, streaming races: present and
  -- enabled, but rendering nothing — seen live on Amur). Track birth time
  -- per key and force-recreate anything older than HL_MAXAGE.
  local hlBorn = {}
  local HL_MAXAGE = 25
  local function modelHasParts(model)
    local found = false
    pcall(function()
      for _, d in ipairs(model:GetDescendants()) do
        if d:IsA("BasePart") then found = true break end
      end
    end)
    return found
  end  local function glowKey(o, tag)
    if not glowIds[o] then glowNext = glowNext + 1; glowIds[o] = glowNext end
    return tag .. "_" .. glowIds[o]
  end
  local GLOW_ENTITY_CAP, GLOW_LOOT_CAP = 20, 10
  local glowUsedEntity, glowUsedLoot = 0, 0
  -- Transparent rigs (1x1x1x1, crouched Two-Time, ghostly Noobs): the
  -- Highlight renderer skips fully-transparent parts, so glow looks dead.
  -- While a model is glowed we pin its see-through parts to 0.25 and
  -- restore every saved value on unglow/unload. Client-side only.
  local transSaved, transT = {}, {}
  local TRANS_FIX_T, TRANS_FIX_SET = 0.75, 0.25
  local function transClamp(model, key, now)
    if transSaved[key] and (transT[key] or 0) > now - 0.5 then return end
    transT[key] = now
    local saved = transSaved[key] or {}
    transSaved[key] = saved
    local ok, desc = pcall(function() return model:GetDescendants() end)
    if not ok then return end
    for _, p in ipairs(desc) do
      local okB, isBase = pcall(function() return p:IsA("BasePart") end)
      if okB and isBase then
        pcall(function()
          if p.Transparency > TRANS_FIX_T then
            if saved[p] == nil then saved[p] = p.Transparency end
            p.Transparency = TRANS_FIX_SET
          end
        end)
      end
    end
  end
  local function transRestore(key)
    local saved = transSaved[key]
    transSaved[key] = nil
    transT[key] = nil
    if saved then
      for part, t in pairs(saved) do
        pcall(function() if part.Parent then part.Transparency = t end end)
      end
    end
  end
  local function setGlow(model, col, on, tag, pool)
    if not model or not model.Parent then return end
    local key = glowKey(model, tostring(tag))
    local prev = glowMap[key]
    if not on then
      if prev then pcall(function() prev:Destroy() end) end
      glowMap[key] = nil
      glowSeenT[key] = nil
      hlBorn[key] = nil
      transRestore(key)
      return
    end
    local isLoot = pool == "loot"
    if prev and prev.Parent then
      if os.clock() - (hlBorn[key] or os.clock()) > HL_MAXAGE then
        -- stale: renders nothing (round/streaming race). Drop it; the
        -- creation path below rebuilds it on the next frame.
        pcall(function() prev:Destroy() end)
        glowMap[key] = nil
        glowSeenT[key] = nil
        hlBorn[key] = nil
        transRestore(key)
        prev = nil
      else
        glowSeenT[key] = os.clock()
        if isLoot then glowUsedLoot = glowUsedLoot + 1
        else glowUsedEntity = glowUsedEntity + 1 end
        pcall(function()
          if prev.FillColor ~= col then prev.FillColor = col end
          prev.DepthMode = F.glow_top and Enum.HighlightDepthMode.AlwaysOnTop
            or Enum.HighlightDepthMode.Occluded
        end)
        transClamp(model, key, os.clock())
        return
      end
    end
    if isLoot then
      if glowUsedLoot >= GLOW_LOOT_CAP then return end
      glowUsedLoot = glowUsedLoot + 1
    else
      if glowUsedEntity >= GLOW_ENTITY_CAP then return end
      glowUsedEntity = glowUsedEntity + 1
    end
    local ok, hl = pcall(function()
      -- never plant a highlight on an empty (still streaming) model: it
      -- comes out stillborn and renders nothing until recreated
      if not modelHasParts(model) then return nil end
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
    if glowMap[key] then
      glowSeenT[key] = os.clock()
      hlBorn[key] = os.clock()
    end
    transClamp(model, key, os.clock())
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
          hlBorn[k] = nil
          transRestore(k)
        end
      end
    end
  end

  -- --------------------------------------------------------------------------
  -- World scans (generators + items + Other, every 2s)
  -- --------------------------------------------------------------------------
  local genCache, itemCache, otherCache = {}, {}, {}
  local genMap, itemMap, otherMap = {}, {}, {}
  local syncLabelMaps -- fwd
  local function mapRoot()
    local mf = workspace:FindFirstChild("Map")
    local ig = mf and mf:FindFirstChild("Ingame")
    return ig and ig:FindFirstChild("Map") or nil
  end
  -- name patterns for the Other tab (lowercase substrings).
  -- Deliberately NARROW: bare words like "plant"/"vine"/"bulb" match map
  -- decor (bushes, wall vines) and flood the screen. Extra per-map words
  -- go into F.other_extra (comma-separated TextBox in the UI).
  local OTHER_PATTERNS = {
    graffiti = { "graffiti", "veeronica" },
    taph = { "tripwire", "tripmine", "subspacetripmine", "subspace tripmine" },
    azure = { "seeker", "secretbulb", "seeker bulb", "stigmatize", "azure" },
    ritual = { "ritual", "twotime", "two time", "two-time", "oblation" },
    build = { "buildermansentry", "buildermandispenser" },
  }
  local function otherKind(name, extra)
    local low = string.lower(tostring(name))
    for kind, pats in pairs(OTHER_PATTERNS) do
      for _, p in ipairs(pats) do
        if string.find(low, p, 1, true) then return kind end
      end
    end
    if type(extra) == "table" then
      for kind, words in pairs(extra) do
        for _, w in ipairs(words) do
          if w ~= "" and string.find(low, w, 1, true) then return kind end
        end
      end
    end
    return nil
  end
  local function otherExtra()
    -- { kind = {words} } parsed from the UI textbox ("kind:word, kind:word")
    local out = {}
    pcall(function()
      for chunk in string.gmatch(string.lower(tostring(F.other_extra or "")), "[^,]+") do
        local kind, word = chunk:match("^%s*(%a+)%s*:%s*(.+)%s*$")
        if kind and word then
          word = word:gsub("%s+$", "")
          if OTHER_PATTERNS[kind] and word ~= "" then
            out[kind] = out[kind] or {}
            table.insert(out[kind], word)
          end
        end
      end
    end)
    return out
  end
  local function scanWorld()
    local gens, items, other, seen = {}, {}, {}, {}
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
            local pos = partPos(it)
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
            local pos = partPos(v)
            if pos then items[#items + 1] = { m = v, pos = pos, name = v.Name } end
          end
        end
      end
    end
    -- Other: traps / graffiti / ritual / builds anywhere under Ingame
    do
      local mf = workspace:FindFirstChild("Map")
      local ig = mf and mf:FindFirstChild("Ingame")
      if ig then
        local ok, desc = pcall(function() return ig:GetDescendants() end)
        if ok then
          local extra = otherExtra()
          for _, v in ipairs(desc) do
            if moduleDead then return end
            if not seen[v] and (v:IsA("Model") or v:IsA("BasePart")) then
              local kind = otherKind(v.Name, extra)
              if kind and not itemHeld(v) then
                -- skip parts buried inside already-tracked gens/items
                local pos = partPos(v)
                if pos then
                  seen[v] = true
                  other[#other + 1] = { m = v, pos = pos, name = v.Name, kind = kind }
                end
              end
            end
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
      table.sort(other, byDist)
    end
    if moduleDead then return end
    genCache, itemCache, otherCache = gens, items, other
    syncLabelMaps()
    refreshGenList()
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
    sync(otherCache, otherMap, true, tonumber(F.other_range) or 2500, 12)
  end
  local function genProgress(e)
    if e.prog and e.prog.Parent then
      local ok, v = pcall(function() return e.prog.Value end)
      if ok and type(v) == "number" then return v end
    end
    return nil
  end
  local function otherActive(kind)
    if kind == "graffiti" then return F.o_graffiti end
    if kind == "taph" then return F.o_taph end
    if kind == "azure" then return F.o_azure end
    if kind == "ritual" then return F.o_ritual end
    if kind == "build" then return F.o_build end
    return false
  end
  local function otherColor(kind)
    if kind == "graffiti" then return F.o_graffiti_col end
    if kind == "taph" then return F.o_taph_col end
    if kind == "azure" then return F.o_azure_col end
    if kind == "ritual" then return F.o_ritual_col end
    return F.o_build_col
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
    -- human pacing on purpose: instant solving trips the server's speed
    -- check and kicks. Node/line pauses are configurable, defaults are
    -- the previously-kick-free values.
    local nodeD = tonumber(F.flow_node) or 0.05
    local lineD = tonumber(F.flow_line) or 0.5
    for ci = 1, #puzzle.Solution do
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
          if nodeD > 0 then task.wait(nodeD) end
        end
        if lineD > 0 then task.wait(lineD) end
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
            -- one short yield so Init() finishes; afterwards zero pacing —
            -- lines solve back-to-back at full speed
            task.wait(0.15)
            if F.flow_on and not moduleDead then flowSolve(p) end
          end)
        end
        return p
      end
    end
    return ok and FG ~= nil
  end

  -- --------------------------------------------------------------------------
  -- Stamina (game's own sprint table, snapshotted, restored on off/unload)
  -- --------------------------------------------------------------------------
  local stamMod, stamOrig = nil, nil
  local STAM_MAX_KEYS = { "MaxStamina", "StaminaMax", "Max", "Stamina" }
  local STAM_REGEN_KEYS = { "StaminaRegen", "RegenRate", "Regen", "RecoveryRate", "StaminaRecovery" }
  local STAM_SPEED_KEYS = { "SprintSpeed", "RunSpeed", "Speed", "WalkSpeed", "SprintWalkSpeed" }
  local function stamRequire()
    if stamMod then return true end
    pcall(function()
      stamMod = require(game:GetService("ReplicatedStorage").Systems.Character.Game.Sprinting)
    end)
    return stamMod ~= nil
  end
  local function stamSnapshot()
    if stamOrig or not stamRequire() then return end
    stamOrig = { loss = stamMod.StaminaLoss, dis = stamMod.StaminaLossDisabled, fields = {} }
    for _, group in ipairs({ STAM_MAX_KEYS, STAM_REGEN_KEYS, STAM_SPEED_KEYS }) do
      for _, k in ipairs(group) do
        pcall(function()
          local v = stamMod[k]
          if type(v) == "number" then stamOrig.fields[k] = v end
        end)
      end
    end
  end
  -- role = "surv" | "killer"; pct sliders are 0-200 (% of snapshot, 0 = off)
  local function stamApplyRole(role)
    local onKey, maxKey, spdKey, regKey
    if role == "killer" then
      onKey, maxKey, spdKey, regKey = "stam_killer_on", "stam_killer_max", "stam_killer_speed", "stam_killer_regen"
    else
      onKey, maxKey, spdKey, regKey = "stam_surv_on", "stam_surv_max", "stam_surv_speed", "stam_surv_regen"
    end
    if not F[onKey] then return end
    if not stamRequire() then return end
    stamSnapshot()
    pcall(function()
      stamMod.StaminaLoss = 0
      stamMod.StaminaLossDisabled = true
    end)
    local function scale(keys, pct)
      pct = tonumber(pct) or 0
      if pct <= 0 then return end
      for _, k in ipairs(keys) do
        pcall(function()
          local base = stamOrig.fields[k]
          if type(base) == "number" then stamMod[k] = base * pct / 100 end
        end)
      end
    end
    scale(STAM_MAX_KEYS, F[maxKey])
    scale(STAM_SPEED_KEYS, F[spdKey])
    scale(STAM_REGEN_KEYS, F[regKey])
  end
  local function stamTick()
    if F.stam_surv_on or F.stam_killer_on then
      stamApplyRole("surv")
      stamApplyRole("killer")
    elseif stamMod then
      stamRestore()
    end
  end
  local function stamResetRole(role)
    -- back to snapshot values without disabling the toggle (re-applies clean)
    if stamMod and stamOrig then
      pcall(function()
        stamMod.StaminaLoss = stamOrig.loss
        stamMod.StaminaLossDisabled = stamOrig.dis
        for k, v in pairs(stamOrig.fields) do stamMod[k] = v end
      end)
    end
    Notify("Stamina", (role == "killer" and "Killer" or "Survivor") .. " values reset to game defaults", "ok")
  end
  function stamRestore()
    if stamMod and stamOrig then
      pcall(function()
        stamMod.StaminaLoss = stamOrig.loss
        stamMod.StaminaLossDisabled = stamOrig.dis
        for k, v in pairs(stamOrig.fields) do stamMod[k] = v end
      end)
    end
    stamMod, stamOrig = nil, nil
  end

  -- --------------------------------------------------------------------------
  -- GenFix: auto repair loop (prompt firing = same as pressing the key).
  -- The server has kicked (267) for repair automation before, so this is
  -- OFF by default and the UI says so.
  -- --------------------------------------------------------------------------
  local genfixDD, genfixStatus
  local genfixNames = { "—" }
  local genfixT, genfixTarget = 0, nil
  local function refreshGenList()
    local names = {}
    for _, e in ipairs(genCache) do
      local p = genProgress(e)
      if e.m.Parent and (p == nil or p < 100) then
        table.insert(names, e.name)
      end
    end
    if #names == 0 then names = { "—" } end
    genfixNames = names
    if genfixDD then
      pcall(function() genfixDD.SetOptions(names, true) end)
      if F.genfix_custom == "—" or F.genfix_custom == nil then
        F.genfix_custom = names[1]
        pcall(function() genfixDD.Set(names[1], true) end)
      end
    end
  end
  local function genfixPick()
    local unfinished = {}
    for _, e in ipairs(genCache) do
      local p = genProgress(e)
      if e.m.Parent and e.pos and (p == nil or p < 100) then
        unfinished[#unfinished + 1] = e
      end
    end
    if #unfinished == 0 then return nil end
    if F.genfix_mode == "Custom" and F.genfix_custom ~= "—" then
      for _, e in ipairs(unfinished) do
        if e.name == F.genfix_custom then return e end
      end
    end
    return unfinished[math.random(1, #unfinished)]
  end
  local function genfixSet(on, silent)
    F.genfix_on = on == true
    if on and not silent then
      Notify("GenFix", "Auto-repair ON (" .. tostring(F.genfix_mode) .. ") — kick risk, watch it", "warn")
    elseif silent == false then
      Notify("GenFix", "Auto-repair OFF", "info")
    end
    if genfixStatus then
      pcall(function()
        genfixStatus.Set(on and ("running · " .. tostring(F.genfix_mode)) or "idle")
      end)
    end
  end
  local function genfixTick(now)
    if not F.genfix_on then return end
    local rate = tonumber(F.genfix_rate) or 1
    if now - genfixT < rate then return end
    genfixT = now
    guarded("genfix", function()
      local hrp = myHRP()
      if not hrp then return end
      local target = genfixTarget
      if not (target and target.m.Parent) then
        target = genfixPick()
        genfixTarget = target
      end
      if not target then
        if genfixStatus then pcall(function() genfixStatus.Set("idle · no unfinished gens") end) end
        return
      end
      local p = genProgress(target)
      if p ~= nil and p >= 100 then genfixTarget = nil return end
      if (target.pos - hrp.Position).Magnitude > 12 then
        pcall(function()
          hrp.CFrame = CFrame.new(target.pos + Vector3.new(0, 3, 0))
        end)
        if genfixStatus then
          pcall(function() genfixStatus.Set("→ " .. target.name) end)
        end
        return
      end
      local prompt = target.m:FindFirstChildWhichIsA("ProximityPrompt", true)
      if prompt and type(fireproximityprompt) == "function" then
        pcall(fireproximityprompt, prompt)
      end
      if genfixStatus then pcall(function() genfixStatus.Set("repairing " .. target.name) end) end
    end)
  end
  -- hide the generator minigame UI while GenFix runs (tracked, restored)
  local genfixHidden = {}
  local GENUI_PATTERNS = { "flowgame", "flow", "puzzle", "minigame", "generator" }
  local function genfixHideUI(on)
    if on then
      pcall(function()
        local pg = LP:FindFirstChild("PlayerGui")
        if not pg then return end
        for _, d in ipairs(pg:GetDescendants()) do
          local low = string.lower(tostring(d.Name))
          for _, pat in ipairs(GENUI_PATTERNS) do
            if string.find(low, pat, 1, true)
              and (d:IsA("ScreenGui") or d:IsA("Frame") or d:IsA("BillboardGui")) then
              if d.Enabled ~= false and d.Visible ~= false then
                genfixHidden[#genfixHidden + 1] = d
                pcall(function()
                  if d:IsA("ScreenGui") or d:IsA("BillboardGui") then d.Enabled = false
                  else d.Visible = false end
                end)
              end
              break
            end
          end
        end
      end)
    else
      for _, d in ipairs(genfixHidden) do
        pcall(function()
          if d.Parent then
            if d:IsA("ScreenGui") or d:IsA("BillboardGui") then d.Enabled = true
            else d.Visible = true end
          end
        end)
      end
      genfixHidden = {}
    end
  end

  -- --------------------------------------------------------------------------
  -- Antis
  -- --------------------------------------------------------------------------
  local ANTI_PATTERNS = {
    slow = { "slow", "slowness", "snare", "cripple", "exhaust", "tired" },
    stun = { "stun", "stunned", "helpless", "daze", "stagger" },
    root = { "root", "rooted", "freeze", "frozen", "trap", "trapped", "grab", "grabbed", "held" },
  }
  local function antiStrip(group)
    local ch = myChar()
    if not ch then return end
    for _, pat in ipairs(ANTI_PATTERNS[group]) do
      pcall(function()
        for k, _ in pairs(ch:GetAttributes()) do
          if string.find(string.lower(tostring(k)), pat, 1, true) then
            ch:SetAttribute(k, nil)
          end
        end
      end)
      for _, v in ipairs(ch:GetChildren()) do
        pcall(function()
          if (v:IsA("StringValue") or v:IsA("NumberValue")
            or v:IsA("BoolValue") or v:IsA("IntValue"))
            and string.find(string.lower(v.Name), pat, 1, true) then
            v:Destroy()
          end
        end)
      end
    end
  end
  -- Debuffs: screen-effect GUIs hidden while on (tracked, restored)
  local debHidden = {}
  local DEB_PATTERNS = { "vignette", "lowhealth", "lowhp", "damage", "hurt",
    "glitch", "hallucin", "subspace", "subspaced", "flash", "blind", "overlay",
    "effect", "blood", "injure", "dizzy" }
  local function debApplyGui(on)
    if on then
      pcall(function()
        local pg = LP:FindFirstChild("PlayerGui")
        if not pg then return end
        for _, d in ipairs(pg:GetDescendants()) do
          if d:IsA("ScreenGui") or d:IsA("Frame") or d:IsA("ImageLabel") then
            local low = string.lower(tostring(d.Name))
            for _, pat in ipairs(DEB_PATTERNS) do
              if string.find(low, pat, 1, true) then
                local vis = true
                pcall(function()
                  vis = (d.Enabled ~= false) and (d.Visible ~= false)
                end)
                if vis then
                  debHidden[#debHidden + 1] = d
                  pcall(function()
                    if d:IsA("ScreenGui") then d.Enabled = false
                    else d.Visible = false end
                  end)
                end
                break
              end
            end
          end
        end
      end)
    else
      for _, d in ipairs(debHidden) do
        pcall(function()
          if d.Parent then
            if d:IsA("ScreenGui") then d.Enabled = true else d.Visible = true end
          end
        end)
      end
      debHidden = {}
    end
  end
  -- Debuffs: post-processing in Lighting (tracked, restored)
  local debPostOrig = {}
  local function debApplyPost(on)
    pcall(function()
      local lighting = game:GetService("Lighting")
      if on then
        for _, e in ipairs(lighting:GetChildren()) do
          pcall(function()
            if e:IsA("BlurEffect") or e:IsA("ColorCorrectionEffect")
              or e:IsA("SunRaysEffect") or e:IsA("BloomEffect")
              or e:IsA("DepthOfFieldEffect") then
              if debPostOrig[e] == nil then debPostOrig[e] = e.Enabled end
              e.Enabled = false
            end
          end)
        end
      else
        for e, was in pairs(debPostOrig) do
          pcall(function() if e.Parent then e.Enabled = was end end)
        end
        debPostOrig = {}
      end
    end)
  end
  -- Exploits: killer-only doors phase-through (tracked, restored)
  local DOOR_PATTERNS = { "killerdoor", "killer door", "killeronly", "killer only",
    "killergate", "killergate", "killerpassage", "killer vent", "killerside" }
  local doorTouched = {}
  local function doorsApply(on)
    if on then
      pcall(function()
        local mf = workspace:FindFirstChild("Map")
        local ig = mf and mf:FindFirstChild("Ingame")
        local root = ig or workspace
        for _, d in ipairs(root:GetDescendants()) do
          local okB, isBase = pcall(function() return d:IsA("BasePart") end)
          if okB and isBase then
            local low = string.lower(tostring(d.Name))
            for _, pat in ipairs(DOOR_PATTERNS) do
              if string.find(low, pat, 1, true) then
                if doorTouched[d] == nil then
                  doorTouched[d] = d.CanCollide
                  pcall(function() d.CanCollide = false end)
                end
                break
              end
            end
          end
        end
      end)
    else
      for part, was in pairs(doorTouched) do
        pcall(function() if part.Parent then part.CanCollide = was end end)
      end
      doorTouched = {}
    end
  end
  -- Exploits: Taph trap immunity (local touch suppression; the server may
  -- still register the trigger — the UI says so)
  local trapTouched = {}
  local function trapsApply(on)
    if on then
      pcall(function()
        for _, e in ipairs(otherCache) do
          if e.kind == "taph" and e.m.Parent then
            for _, part in ipairs(e.m:IsA("Model") and e.m:GetDescendants() or { e.m }) do
              pcall(function()
                if part:IsA("BasePart") and trapTouched[part] == nil then
                  trapTouched[part] = part.CanTouch
                  part.CanTouch = false
                end
              end)
            end
          end
        end
      end)
    else
      for part, was in pairs(trapTouched) do
        pcall(function() if part.Parent then part.CanTouch = was end end)
      end
      trapTouched = {}
    end
  end

  -- --------------------------------------------------------------------------
  -- AimBot (camera aim, client-side)
  -- --------------------------------------------------------------------------
  local function aimTargetPart(ch)
    if not ch then return nil end
    local want = F.aim_part or "Head"
    if want == "HRP" then return ch:FindFirstChild("HumanoidRootPart") end
    return ch:FindFirstChild(want == "Torso" and "Torso" or "Head")
      or ch:FindFirstChild("HumanoidRootPart")
  end
  local function aimTick()
    if not F.aim_on then return end
    camera = workspace.CurrentCamera or camera
    if not camera then return end
    guarded("aim", function()
      local meHRP = myHRP()
      if not meHRP then return end
      local vs = camera.ViewportSize
      local cx, cy, best, bestD = vs.X / 2, vs.Y / 2, nil, tonumber(F.aim_fov) or 300
      local wantKiller = (F.aim_target or "Killer") == "Killer"
      for _, pl in ipairs(players:GetPlayers()) do
        if pl ~= LP then
          local ch = charOf(pl)
          local hum = ch and ch:FindFirstChildOfClass("Humanoid")
          if ch and hum and hum.Health > 0 then
            local killer = isKiller(pl)
            if (wantKiller and killer) or ((not wantKiller) and not killer) then
              local part = aimTargetPart(ch)
              if part then
                local sp, heard = wts(part.Position)
                if heard and onScreenPt(sp, vs, 400) then
                  local d = math.sqrt((sp.X - cx) ^ 2 + (sp.Y - cy) ^ 2)
                  if d < bestD then bestD, best = d, part end
                end
              end
            end
          end
        end
      end
      if best then
        local dir = (best.Position - camera.CFrame.Position)
        if dir.Magnitude > 0.5 then
          local want = CFrame.lookAt(camera.CFrame.Position, best.Position)
          local s = clamp(tonumber(F.aim_smooth) or 8, 1, 30)
          camera.CFrame = camera.CFrame:Lerp(want, 1 / s)
        end
      end
    end)
  end
  local function aimSet(on, silent)
    F.aim_on = on == true
    if not silent then
      Notify("AimBot", on and ("ON — " .. tostring(F.aim_target)) or "OFF",
        on and "ok" or "info")
    end
  end

  -- --------------------------------------------------------------------------
  -- Killer alert (popup notification, edge-triggered + cooldown)
  -- --------------------------------------------------------------------------
  local alertFired, alertT = false, 0
  local function alertTick(now)
    if not F.alert_on then alertFired = false return end
    if killerNear and not alertFired and now - alertT > 10 then
      alertFired, alertT = true, now
      Notify("KILLER NEAR", "Killer " .. math.floor(killerDist + 0.5) .. "m away",
        "error")
    elseif not killerNear then
      alertFired = false
    end
  end

  -- --------------------------------------------------------------------------
  -- Status
  -- --------------------------------------------------------------------------
  local statLbl, dbgLbl, antiTick, stamTick2, utilTick = nil, nil, 0, 0, 0
  local statTick, scanTick, labelTick, nP, nK = 0, 0, 0, 0, 0
  local nGlowK, nGlowS = 0, 0
  local killerNear, killerDist = false, math.huge

  -- --------------------------------------------------------------------------
  -- Frame workers (split out of the RenderStepped closure: Lua caps a
  -- single function at 60 upvalues, and the loop body blew past it)
  -- --------------------------------------------------------------------------
  local function framePlayers(meHRP, vs, seenGlow)
    if not meHRP then
      for _, e in pairs(pesc) do hideRig(e) end
      return
    end
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
            if killer then nGlowK = nGlowK + 1 else nGlowS = nGlowS + 1 end
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
  end
  local function frameWorld(meHRP, vs, seenGlow)
    if not meHRP then
      for _, o in pairs(genMap) do
        if o.lbl then pcall(function() o.lbl.Visible = false end) end
      end
      for _, o in pairs(itemMap) do
        if o.lbl then pcall(function() o.lbl.Visible = false end) end
      end
      for _, o in pairs(otherMap) do
        if o.lbl then pcall(function() o.lbl.Visible = false end) end
      end
      return
    end
    guarded("world", function()
      local mp = meHRP.Position
      local function draw(cache, on, names, col, poolTag)
        for _, e in ipairs(cache) do
          local L = e.lbl
          if L then L.Visible = false end
          if on and e.m.Parent and e.pos then
            local d = (mp - e.pos).Magnitude
            local range = (poolTag == "g") and (F.gen_range or 4000)
              or (poolTag == "o") and 6000 or (F.item_range or 2500)
            if d == d and d <= range then
              local sp, heard = wts(e.pos)
              if L and heard and names and onScreenPt(sp, vs) then
                local tag = e.name
                if e.prog and e.prog.Parent then
                  local okP, pv = pcall(function() return e.prog.Value end)
                  if okP and type(pv) == "number" then
                    tag = ("Generator %d%%"):format(clamp(math.floor(pv + 0.5), 0, 100))
                  end
                end
                L.Text = tag .. "  " .. math.floor(d + 0.5) .. "m"
                L.Color = col
                L.Position = V2(sp.X, sp.Y)
                L.Visible = true
              end
            end
          end
        end
      end
      draw(genCache, F.gen_on == true, F.gen_names == true, F.gen_col, "g")
      draw(itemCache, F.item_on == true, F.item_names == true, F.item_col, "i")
      -- Other: per-kind flags + fake-gen suspects (Noli rounds: more
      -- gens than realCount => extras marked "?FAKE")
          local realN = tonumber(F.fake_realcount) or 5
          local oRange = tonumber(F.other_range) or 2500
          for _, e in ipairs(otherCache) do
            local L = e.lbl
            if L then L.Visible = false end
            if e.m.Parent and e.pos and otherActive(e.kind) then
              local d = (mp - e.pos).Magnitude
              if d == d and d <= oRange then
            local sp, heard = wts(e.pos)
            if L and heard and onScreenPt(sp, vs) then
              L.Text = e.name .. "  " .. math.floor(d + 0.5) .. "m"
              L.Color = otherColor(e.kind)
              L.Position = V2(sp.X, sp.Y)
              L.Visible = true
            end
          end
        end
      end
      local gi = 0
      for _, e in ipairs(genCache) do
        gi = gi + 1
        local L = e.lbl
        if F.o_fake and gi > realN and L and e.m.Parent and e.pos then
          local d = (mp - e.pos).Magnitude
          if d == d and d <= (F.gen_range or 4000) then
            local sp, heard = wts(e.pos)
            if heard and onScreenPt(sp, vs) then
              L.Text = "?FAKE " .. e.name .. "  " .. math.floor(d + 0.5) .. "m"
              L.Color = F.o_fake_col
              L.Position = V2(sp.X, sp.Y - 14)
              L.Visible = true
            end
          end
        end
      end
          -- Azure vine attack radius (19m default, adjustable).
          -- Real screen projection: px = R * (H/2) / (D * tan(fov/2)).
          if F.o_azure and F.azure_radius_on then
            local fov = 70
            pcall(function() fov = camera.FieldOfView end)
            local proj = (vs.Y * 0.5) / math.max(math.tan(math.rad(fov) / 2), 0.01)
            for _, e in ipairs(otherCache) do
              if e.kind == "azure" and e.m.Parent and e.pos then
                local d = (mp - e.pos).Magnitude
                if d == d and d <= oRange then
                  guarded("azure", function()
                    local c = tshape("Circle")
                    local sp, heard = wts(e.pos)
                    if heard and onScreenPt(sp, vs, 400) then
                      local dist = math.max((camera.CFrame.Position - e.pos).Magnitude, 1)
                      c.Color = F.o_azure_col
                      c.Transparency = 0.5
                      c.Filled = false
                      c.Thickness = 1
                      c.NumSides = 32
                      c.Radius = clamp((tonumber(F.azure_radius) or 19) * proj / dist, 4, vs.Y)
                      c.Position = V2(sp.X, sp.Y)
                    else
                      c.Visible = false
                    end
                  end)
                end
              end
            end
          end
      -- glow pass, nearest-first (caches are sorted)
      local shown = 0
      local cap = GLOW_LOOT_CAP
      local function glow(cache, on, col)
        if not on then return end
        for _, e in ipairs(cache) do
          if shown >= cap then return end
          if e.m.Parent and e.pos and (mp - e.pos).Magnitude <= ((cache == genCache) and (F.gen_range or 4000) or (F.item_range or 2500)) then
            -- finished (100%) generators glow green, always
            local gc = col
            if cache == genCache then
              local p = genProgress(e)
              if p ~= nil and p >= 100 then gc = Color3.fromRGB(0, 255, 0) end
            end
            local key = glowKey(e.m, cache == genCache and "g" or "i")
            setGlow(e.m, gc, true, cache == genCache and "g" or "i", "loot")
            seenGlow[key] = true
            shown = shown + 1
          end
        end
      end
      glow(genCache, F.gen_on == true, F.gen_col)
      glow(itemCache, F.item_on == true, F.item_col)
    end)
  end
  local function frameUtil(now)
    alertTick(now)
    aimTick()
    genfixTick(now)
    if now - utilTick > 2 then
      utilTick = now
      guarded("anti-util", function()
        -- re-apply flags that new spawns would otherwise dodge
        if F.x_doors then doorsApply(true) end
        if F.x_trapimmune then trapsApply(true) end
        if F.genfix_on and F.genfix_hideui then genfixHideUI(true) end
        if F.deb_gui then debApplyGui(true) end
      end)
    end
    if now - antiTick > 0.25 then
      antiTick = now
      guarded("anti", function()
        if F.anti_slow then antiStrip("slow") end
        if F.anti_stun then antiStrip("stun") end
        if F.anti_root then antiStrip("root") end
      end)
    end
    if now - stamTick2 > 0.5 then
      stamTick2 = now
      guarded("stam", stamTick)
    end
    if statLbl and now - statTick > 2 then
      statTick = now
      pcall(function()
        statLbl.Set(("players %d · killers %d · glow K%d/S%d%s%s%s"):format(nP, nK,
          nGlowK, nGlowS,
          (F.alert_on and killerNear) and (" · KILLER " .. math.floor(killerDist + 0.5) .. "m") or "",
          #genCache > 0 and (" · gens " .. #genCache) or "",
          #otherCache > 0 and (" · other " .. #otherCache) or ""))
        local parts = { ("loop %dfps"):format(dbg.fps) }
        table.insert(parts, ("glow E%d/20 L%d/10"):format(
          math.min(glowUsedEntity, 99), math.min(glowUsedLoot, 99)))
        for _, sec in ipairs({ "scan", "labels", "players", "world", "azure", "genfix", "aim", "anti", "stam" }) do
          if dbg.err[sec] then
            table.insert(parts, sec .. "!" .. dbg.err[sec])
          end
        end
        if dbg.last ~= "" then table.insert(parts, dbg.last) end
        dbgLbl.Set(table.concat(parts, " - "))
      end)
    end
  end

  -- --------------------------------------------------------------------------
  -- Main loop
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
      nGlowK, nGlowS = 0, 0
      killerNear, killerDist = false, math.huge
      framePlayers(meHRP, vs, seenGlow)
      frameWorld(meHRP, vs, seenGlow)
      frameUtil(now)
      gcGlow(seenGlow)
    end)
    finishTransient()
    if not renderOk then dbg.err.render = (dbg.err.render or 0) + 1; dbg.last = tostring(renderError) end
  end))

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
    pcall(function() genfixHideUI(false) end)
    pcall(function() debApplyGui(false) end)
    pcall(function() debApplyPost(false) end)
    pcall(function() doorsApply(false) end)
    pcall(function() trapsApply(false) end)
    for _, h in pairs(glowMap) do pcall(function() h:Destroy() end) end
    for k in pairs(glowMap) do glowMap[k] = nil end
    for k in pairs(glowSeenT) do glowSeenT[k] = nil end
    for k in pairs(transSaved) do transRestore(k) end
    for k in pairs(hlBorn) do hlBorn[k] = nil end
    for pl in pairs(pesc) do freeRig(pl) end
    for _, maps in ipairs({ genMap, itemMap, otherMap }) do
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
  -- UI
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
  local function flagKey(sec, name, key, def, tip)
    return sec:Keybind({ Name = name, Default = def, Flag = "fs_" .. key,
      Tooltip = tip, Callback = function(v) F[key] = v end })
  end

  local pages = {}
  local nav = api.Navigation or Tab:Navigation({ Name = "Forsaken" })
  local menuDefs = {
    { "Visual", "□", "Players, items, traps, builds" },
    { "Stamina", "⚡", "Survivor / killer stamina + speed" },
    { "GenFix", "⚒", "Auto repair, solver, generator UI" },
    { "Antis", "○", "Movement, debuffs, exploits" },
    { "AimBot", "◎", "Camera aim with keybind" },
    { "AutoCombat", "✦", "In development" },
    { "About", "i", "Status" },
  }
  for index, def in ipairs(menuDefs) do
    pages[def[1]] = nav:Page({ Id = "fsk_" .. def[1]:lower(), Name = def[1],
      Icon = def[2], Tooltip = def[3], Order = index })
  end
  pages.Visual:Select()

  -- Visual / Players (+ alert + glow, as before)
  local visTabs = pages.Visual:SubTabs({ { Name = "Players" }, { Name = "Items" }, { Name = "Other" } })
  local pSec = visTabs.Players:Section({ Name = "Players" })
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
  local alSec = visTabs.Players:Section({ Name = "Killer alert" })
  alSec:Paragraph("Popup notification when the killer gets close (10s cooldown).")
  flagToggle(alSec, "Killer alert", "alert_on")
  flagSlider(alSec, "Alert range", "alert_range", 50, 1000, { suf = "m" })
  local gSec = visTabs.Players:Section({ Name = "Glow" })
  gSec:Paragraph("Client-side Highlights (see-through chams).")
  flagToggle(gSec, "Killer glow", "glow_killer")
  flagToggle(gSec, "Survivor glow", "glow_surv")
  flagToggle(gSec, "Through walls", "glow_top")
  flagColor(gSec, "Killer glow", "glow_killercol")
  flagColor(gSec, "Survivor glow", "glow_survcol")

  -- Visual / Items (as before)
  local iSec = visTabs.Items:Section({ Name = "Items" })
  iSec:Paragraph("Medkits + Bloxy Cola, on the map and dropped.")
  flagToggle(iSec, "Item ESP", "item_on")
  flagToggle(iSec, "Names", "item_names")
  flagSlider(iSec, "Max distance", "item_range", 200, 6000, { suf = "m" })
  flagColor(iSec, "Color", "item_col")
  local genSec = visTabs.Items:Section({ Name = "Generators" })
  genSec:Paragraph("Generator objectives, nearest-first. Done ones glow green.")
  flagToggle(genSec, "Generator ESP", "gen_on")
  flagToggle(genSec, "Names", "gen_names")
  flagSlider(genSec, "Max distance", "gen_range", 200, 8000, { suf = "m" })
  flagColor(genSec, "Color", "gen_col")

  -- Visual / Other
  local oSec = visTabs.Other:Section({ Name = "Traps & graffiti" })
  oSec:Paragraph("Taph tripwires/tripmines, Azure bulbs/vines, Veeronica wall graffiti.")
  flagToggle(oSec, "Veeronica graffiti", "o_graffiti")
  flagColor(oSec, "Graffiti color", "o_graffiti_col")
  flagToggle(oSec, "Taph traps", "o_taph")
  flagColor(oSec, "Taph color", "o_taph_col")
  flagToggle(oSec, "Azure plants", "o_azure")
  flagColor(oSec, "Azure color", "o_azure_col")
  flagToggle(oSec, "Show Azure attack radius", "azure_radius_on",
    nil, "Draws the trigger circle around Azure plants")
  flagSlider(oSec, "Azure radius", "azure_radius", 5, 40, { suf = "m",
    tip = "Seeker Bulb triggers at ~19m" })
  local oSec2 = visTabs.Other:Section({ Name = "Ritual, builds, fakes" })
  oSec2:Paragraph("Two-Time ritual point, Builderman sentries/dispensers, Noli fake generators.")
  flagToggle(oSec2, "Two-Time ritual", "o_ritual")
  flagColor(oSec2, "Ritual color", "o_ritual_col")
  flagToggle(oSec2, "Builderman builds", "o_build")
  flagColor(oSec2, "Build color", "o_build_col")
  flagToggle(oSec2, "Mark suspect fake gens", "o_fake", nil,
    "Noli rounds spawn 2 fake gens (7 total). Gens past the count below get ?FAKE tags")
  flagSlider(oSec2, "Real gen count", "fake_realcount", 3, 7, {
    tip = "Normally 5 real gens; Noli adds 2 fakes" })
  flagColor(oSec2, "Fake color", "o_fake_col")
  flagSlider(oSec2, "Other max distance", "other_range", 200, 6000, { suf = "m",
    tip = "Labels + azure circles past this are hidden" })
  oSec2:TextBox({ Name = "Extra filters", Placeholder = "kind:word, e.g. azure:vine",
    Default = F.other_extra, Flag = "fs_other_extra",
    Tooltip = "kind = graffiti/taph/azure/ritual/build. Appended to the built-in name list",
    Callback = function(v) F.other_extra = tostring(v or "") end })

  -- Stamina / Survivor + Killer
  local stamTabs = pages.Stamina:SubTabs({ { Name = "Survivor" }, { Name = "Killer" } })
  local function stamPage(tab, role, title)
    local onKey = role == "killer" and "stam_killer_on" or "stam_surv_on"
    local maxKey = role == "killer" and "stam_killer_max" or "stam_surv_max"
    local spdKey = role == "killer" and "stam_killer_speed" or "stam_surv_speed"
    local regKey = role == "killer" and "stam_killer_regen" or "stam_surv_regen"
    local sec = tab:Section({ Name = title })
    sec:Paragraph("Edits the game's sprint table (snapshotted, restored on off/unload). Sliders are % of the game's own values; 0 = leave that stat alone. Enable the tab matching your current role.")
    sec:Toggle({ Name = "Infinite stamina (no drain)", Default = F[onKey] == true,
      Flag = "fs_" .. onKey, Callback = function(v) F[onKey] = v == true end })
    sec:Slider({ Name = "Max stamina %", Min = 0, Max = 200, Default = F[maxKey],
      Suffix = "%", Flag = "fs_" .. maxKey,
      Callback = function(v) F[maxKey] = tonumber(v) or 0 end })
    sec:Slider({ Name = "Move speed %", Min = 0, Max = 200, Default = F[spdKey],
      Suffix = "%", Flag = "fs_" .. spdKey,
      Callback = function(v) F[spdKey] = tonumber(v) or 0 end })
    sec:Slider({ Name = "Regen rate %", Min = 0, Max = 200, Default = F[regKey],
      Suffix = "%", Flag = "fs_" .. regKey,
      Callback = function(v) F[regKey] = tonumber(v) or 0 end })
    sec:Button({ Name = "Reset stamina", Variant = "ghost",
      Tooltip = "Back to game defaults (keeps the toggle state)",
      Callback = function() stamResetRole(role) end })
  end
  stamPage(stamTabs.Survivor, "surv", "Survivor stamina")
  stamPage(stamTabs.Killer, "killer", "Killer stamina")

  -- GenFix
  local gfSec = pages.GenFix:Section({ Name = "Auto repair" })
  gfSec:Paragraph("WARNING: the server has kicked (267) for repair automation before. This fires the game's own prompt (same as pressing the key), teleports you to the gen and lets the solver play the puzzle. OFF by default — your risk.")
  local gfToggle = gfSec:Toggle({ Name = "Auto repair", Default = false, Flag = "fs_genfix_on",
    Tooltip = "Enable the repair loop",
    Callback = function(v) genfixSet(v == true, true) end })
  flagKey(gfSec, "Auto repair key", "genfix_key", nil,
    "Toggles auto repair with a popup"):OnPress(function()
    genfixSet(not F.genfix_on, false)
    pcall(function() gfToggle.Set(F.genfix_on, true) end)
  end)
  gfSec:Dropdown({ Name = "Target mode", Options = { "Random", "Custom" },
    Default = F.genfix_mode, Flag = "fs_genfix_mode",
    Tooltip = "Random = random unfinished gen; Custom = the one picked below",
    Callback = function(v) F.genfix_mode = tostring(v) end })
  genfixDD = gfSec:Dropdown({ Name = "Custom generator", Options = genfixNames,
    Flag = "fs_genfix_custom",
    Callback = function(v) F.genfix_custom = tostring(v) end })
  gfSec:Button({ Name = "Refresh generator list", Variant = "ghost", Callback = function()
    refreshGenList()
    Notify("GenFix", #genfixNames .. " unfinished gens", "info")
  end })
  flagSlider(gfSec, "Cycle rate", "genfix_rate", 0.25, 5, { dec = 2, suf = "s",
    tip = "Pause between repair attempts" })
  flagToggle(gfSec, "Hide generator UI", "genfix_hideui", nil,
    "Hides the puzzle/minigame frames while repairing (restored after)")
  genfixStatus = gfSec:Label("idle")
  local flowSec = pages.GenFix:Section({ Name = "Minigame solver" })
  flowSec:Paragraph("Auto-solves the generator flow puzzle when it pops up. Hooks the game's solver table (restored on unload).")
  flowSec:Toggle({ Name = "Auto-solve flow puzzle", Default = F.flow_on == true, Flag = "fs_flow_on",
    Tooltip = "Arms the solver hook on enable",
    Callback = function(v)
      F.flow_on = v == true
      if v then task.spawn(function() guarded("flowhook", flowHook) end) end
    end })
  flagSlider(flowSec, "Node pause", "flow_node", 0, 0.5, { dec = 2, suf = "s",
    tip = "Pause between path nodes — 0 = instant (kick risk)" })
  flagSlider(flowSec, "Line pause", "flow_line", 0, 2, { dec = 1, suf = "s",
    tip = "Pause between solved lines — 0 = instant (kick risk)" })

  -- Antis
  local antiTabs = pages.Antis:SubTabs({ { Name = "Movement" }, { Name = "Debuffs" }, { Name = "Exploits" } })
  local amSec = antiTabs.Movement:Section({ Name = "Status cleanse" })
  amSec:Paragraph("Strips slow/stun/root markers off your character 4x/sec. Client-side: the server re-applies them, so this fights what your client enforces.")
  flagToggle(amSec, "Anti slow", "anti_slow")
  flagToggle(amSec, "Anti stun", "anti_stun")
  flagToggle(amSec, "Anti root / grab", "anti_root")
  local adSec = antiTabs.Debuffs:Section({ Name = "Screen effects" })
  adSec:Paragraph("Hides low-HP vignette, glitch/hallucination overlays and similar screen junk + Lighting post-effects. Everything is tracked and restored on off/unload.")
  adSec:Toggle({ Name = "Hide screen-effect GUIs", Default = F.deb_gui == true,
    Flag = "fs_deb_gui", Callback = function(v)
      F.deb_gui = v == true
      guarded("deb", function() debApplyGui(F.deb_gui) end)
    end })
  local adSec2 = antiTabs.Debuffs:Section({ Name = "Post-processing" })
  adSec2:Toggle({ Name = "Disable Lighting effects", Default = F.deb_post == true,
    Desc = "Blur / color correction / sun rays off while on", Flag = "fs_deb_post",
    Callback = function(v)
      F.deb_post = v == true
      guarded("deb", function() debApplyPost(F.deb_post) end)
    end })
  local axSec = antiTabs.Exploits:Section({ Name = "Passages & traps" })
  axSec:Paragraph("Killer-door phase walks you through killer-only barriers (client collision). Taph immunity suppresses local trap touch — the server may still register the trigger.")
  axSec:Toggle({ Name = "Phase killer doors", Default = F.x_doors == true,
    Flag = "fs_x_doors", Callback = function(v)
      F.x_doors = v == true
      guarded("doors", function() doorsApply(F.x_doors) end)
    end })
  axSec:Toggle({ Name = "Taph trap immunity", Default = F.x_trapimmune == true,
    Flag = "fs_x_trapimmune",
    Tooltip = "Local touch suppression only — server may still trigger",
    Callback = function(v)
      F.x_trapimmune = v == true
      guarded("traps", function() trapsApply(F.x_trapimmune) end)
    end })

  -- AimBot
  local abSec = pages.AimBot:Section({ Name = "Aim" })
  abSec:Paragraph("Camera aim at the closest target near your crosshair. Client-side.")
  local abToggle = abSec:Toggle({ Name = "Aimbot", Default = false, Flag = "fs_aim_on",
    Callback = function(v) aimSet(v == true, true) end })
  flagKey(abSec, "Aimbot key", "aim_key", nil, "Toggles aim with a popup"):OnPress(function()
    aimSet(not F.aim_on, false)
    pcall(function() abToggle.Set(F.aim_on, true) end)
  end)
  abSec:Dropdown({ Name = "Target", Options = { "Killer", "Survivors" },
    Default = F.aim_target, Flag = "fs_aim_target",
    Callback = function(v) F.aim_target = tostring(v) end })
  abSec:Dropdown({ Name = "Aim part", Options = { "Head", "Torso", "HRP" },
    Default = F.aim_part, Flag = "fs_aim_part",
    Callback = function(v) F.aim_part = tostring(v) end })
  flagSlider(abSec, "Smoothness", "aim_smooth", 1, 30, { tip = "Higher = slower, more legit" })
  flagSlider(abSec, "FOV", "aim_fov", 50, 1000, { suf = "px" })

  -- AutoCombat (UI only)
  local acTabs = pages.AutoCombat:SubTabs({ { Name = "Survivors" }, { Name = "Killer" } })
  local function acPage(tab, role, modes)
    local sec = tab:Section({ Name = (role == "killer" and "Killer" or "Survivor") .. " combat" })
    sec:Paragraph("Under construction: layout preview only, nothing here acts yet.")
    sec:Dropdown({ Name = "Mode", Options = modes, Default = modes[1],
      Flag = "fs_ac_" .. role .. "_mode",
      Callback = function(v) F["ac_" .. role .. "_mode"] = tostring(v) end })
    sec:Slider({ Name = "React range", Min = 5, Max = 100, Default = 25, Suffix = "m",
      Flag = "fs_ac_" .. role .. "_range", Callback = function() end })
    sec:Slider({ Name = "Cooldown", Min = 0, Max = 5, Default = 1, Decimals = 2, Suffix = "s",
      Flag = "fs_ac_" .. role .. "_cd", Callback = function() end })
    local enT
    enT = sec:Toggle({ Name = "Enable (soon)", Default = false,
      Callback = function(v)
        if v then
          pcall(function() enT.Set(false, true) end)
          Notify("AutoCombat", "Not implemented yet — UI preview only", "warn")
        end
      end })
  end
  acPage(acTabs.Survivors, "surv", { "Assist", "Peel killer", "Bodyguard" })
  acPage(acTabs.Killer, "killer", { "Assist", "Focus weakest", "Zone control" })

  -- About
  local aboutSec = pages.About:Section({ Name = "About" })
  aboutSec:Label("FORSAKEN - hub module v" .. MODULE_VERSION)
  aboutSec:Paragraph("Visual + stamina + GenFix + antis + aimbot. Eyes-only except client stamina/collision/camera and GenFix prompt firing.")
  statLbl = aboutSec:Label("players 0 · killers 0")
  dbgLbl = aboutSec:Label("loop - fps")
  aboutSec:Button({ Name = "Rebuild overlays", Variant = "ghost", Callback = function()
    freeTransient()
    for _, maps in ipairs({ genMap, itemMap, otherMap }) do
      for m, o in pairs(maps) do
        if o.lbl then pcall(function() o.lbl:Remove() end) end
        maps[m] = nil
      end
    end
    for _, cache in ipairs({ genCache, itemCache, otherCache }) do
      for _, entry in ipairs(cache) do entry.lbl = nil end
    end
    for _, h in pairs(glowMap) do pcall(function() h:Destroy() end) end
    for k in pairs(glowMap) do glowMap[k] = nil end
    for k in pairs(glowSeenT) do glowSeenT[k] = nil end
    for k in pairs(transSaved) do transRestore(k) end
    for k in pairs(hlBorn) do hlBorn[k] = nil end
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
