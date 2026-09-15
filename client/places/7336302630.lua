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
  local MODULE_VERSION = "2.6-fix"

  local runService = game:GetService("RunService")
  local players = game:GetService("Players")
  local workspace = game:GetService("Workspace")
  local userInput = game:GetService("UserInputService")
  local lighting = game:GetService("Lighting")
  local camera = workspace.CurrentCamera
  local LP = players.LocalPlayer
  local rayParams = RaycastParams.new()

  -- fullbright originals (captured on first enable, restored on off/unload)
  local brightOrig = nil
  local function brightApply(on)
    if on then
      if not brightOrig then
        brightOrig = {}
        pcall(function()
          brightOrig.ClockTime = lighting.ClockTime
          brightOrig.Brightness = lighting.Brightness
          brightOrig.FogEnd = lighting.FogEnd
          brightOrig.GlobalShadows = lighting.GlobalShadows
          brightOrig.Ambient = lighting.Ambient
          brightOrig.OutdoorAmbient = lighting.OutdoorAmbient
        end)
      end
      pcall(function()
        lighting.ClockTime = 14
        lighting.Brightness = 2
        lighting.FogEnd = 100000
        lighting.GlobalShadows = false
        lighting.Ambient = Color3.fromRGB(170, 170, 170)
        lighting.OutdoorAmbient = Color3.fromRGB(170, 170, 170)
      end)
    elseif brightOrig then
      pcall(function()
        if brightOrig.ClockTime ~= nil then lighting.ClockTime = brightOrig.ClockTime end
        if brightOrig.Brightness ~= nil then lighting.Brightness = brightOrig.Brightness end
        if brightOrig.FogEnd ~= nil then lighting.FogEnd = brightOrig.FogEnd end
        if brightOrig.GlobalShadows ~= nil then lighting.GlobalShadows = brightOrig.GlobalShadows end
        if brightOrig.Ambient ~= nil then lighting.Ambient = brightOrig.Ambient end
        if brightOrig.OutdoorAmbient ~= nil then lighting.OutdoorAmbient = brightOrig.OutdoorAmbient end
      end)
    end
  end

  --// reload safety --------------------------------------------------------
  do
    local g = getgenv and getgenv()
    local prev = g and (g.__HUMA_PLACE or g.__HUMA_DELTA)
    if prev and type(prev.Unload) == "function" then pcall(prev.Unload) end
  end

  local F = {
    esp_on = true, -- master switch for the player ESP drawings
    esp_box = true, esp_health = true, esp_tracer = false,
    esp_name = true, esp_dist = true, esp_weapon = true,
    esp_thick = 2, esp_range = 4000,
    esp_enemy = Color3.fromRGB(255, 90, 90),
    aim_on = false, aim_part = "Head", aim_fov = 15, aim_smooth = 65,
    aim_range = 1200,
    aim_hold = "right", aim_prio = "closest", aim_vis = true,
    aim_circle = true, aim_pause = true, aim_delay = 0.1,
    glow_on = false, glow_npc = false, glow_corpse = false, glow_top = true,
    glow_vis = true, glow_viscol = Color3.fromRGB(255, 255, 255), glow_visthick = 3,
    glow_enemy = Color3.fromRGB(255, 90, 90),
    glow_npc_c = Color3.fromRGB(150, 160, 170),
    glow_corpse_c = Color3.fromRGB(255, 150, 40),
    glow_loot = true,
    glow_cont = Color3.fromRGB(255, 170, 60),
    glow_drop = Color3.fromRGB(120, 220, 255),
    glow_quest = Color3.fromRGB(190, 120, 255),
    glow_star = Color3.fromRGB(255, 210, 90),
    glow_lootcap = 10,
    loot_cont = true, loot_drop = true, loot_quest = true,
    loot_hl = true, loot_keys = "card,key,defib,ledx,bitcoin,gpu,military, thermal, red, violet, gold",
    loot_col = Color3.fromRGB(120, 220, 255),
    loot_hlcol = Color3.fromRGB(255, 210, 90),
    loot_range = 1500,
    loot_contname = true,
    bot_esp = true, bot_col = Color3.fromRGB(255, 140, 50),
    bot_glow = false, bot_range = 2500,
    aim_bots = true,
    fullbright = true,
    corpse_on = true, corpse_ai = true,
    corpse_col = Color3.fromRGB(255, 150, 40),
    corpse_ai_col = Color3.fromRGB(200, 170, 60),
    corpse_range = 2500,
    npc_on = true, npc_col = Color3.fromRGB(150, 160, 170), npc_range = 2500,
    exit_on = true, exit_col = Color3.fromRGB(110, 230, 130), exit_range = 4000,
    radar_on = false, radar_range = 800, radar_size = 170,
  }

  -- Drawing API presence: without it every shape() call throws inside a
  -- pcall and the module looks "loaded but dead". Fail loudly instead.
  local HAS_DRAWING = false
  do
    local ok = pcall(function()
      local probe = Drawing.new("Square")
      probe:Remove()
    end)
    HAS_DRAWING = ok == true
  end

  local moduleDead = false -- set by unloadModule; stops the background scan
  local CONNS = {}
  local function reg(c) table.insert(CONNS, c) return c end
  local unloadModule -- fwd (About button runs at click-time)

  local function clamp(v, a, b)
    if v < a then return a elseif v > b then return b end
    return v
  end

  -- --------------------------------------------------------------------------
  -- Drawing objects: TWO lifecycles, never mixed.
  --   shape()     = persistent (rigs, labels): created once per entity,
  --                 only repositioned per frame. NEVER auto-recycled.
  --   tshape()    = transient (radar blips, fov circle, lock dot): pooled
  --                 per type, hidden at frame start, reused on demand.
  -- Mixing them (auto-recycling persistent rigs) deletes the ESP two
  -- frames after creation.
  --
  -- THE RULE THAT BROKE EVERYTHING BEFORE: in the Drawing API,
  -- `Transparency` is OPACITY. 1 = fully visible, 0 = fully INVISIBLE,
  -- which is the opposite of a Roblox Instance. Objects default to 1.
  -- Setting it to 0 makes an object that is Visible, positioned and
  -- correctly coloured - and draws nothing at all.
  -- --------------------------------------------------------------------------
  local pools = {}
  local function shape(typ)
    local s = Drawing.new(typ)
    -- Drawing API quirk: Transparency is OPACITY. 1 = solid, 0 = INVISIBLE.
    -- Everything starts solid; nothing in this file may set it to 0.
    pcall(function() s.Transparency = 1 end)
    s.Visible = true
    return s
  end
  -- transient objects are POOLED per type: hidden at frame start, reused on
  -- demand. The old code created + :Remove()'d dozens of objects per frame,
  -- which some executors rate-limit (drawings silently stop appearing).
  local function tshape(typ)
    local pool = pools[typ]
    if not pool then pool = { objs = {}, n = 0 }; pools[typ] = pool end
    pool.n = pool.n + 1
    local s = pool.objs[pool.n]
    if not s then
      s = shape(typ)
      pool.objs[pool.n] = s
    end
    pcall(function() s.Visible = true end)
    return s
  end
  local function clearTransient()
    for _, pool in pairs(pools) do
      for i = 1, #pool.objs do
        local o = pool.objs[i]
        pcall(function() o.Visible = false end)
      end
      pool.n = 0
    end
  end
  local function freeTransient()
    for typ, pool in pairs(pools) do
      for _, o in ipairs(pool.objs) do pcall(function() o:Remove() end) end
      pools[typ] = nil
    end
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
  -- cheap viewport cull for single-point labels: drawing text thousands of
  -- pixels off-screen still costs a draw call in most executors
  local function onScreenPt(p, vs, m)
    m = m or 64
    return p.X > -m and p.X < vs.X + m and p.Y > -m and p.Y < vs.Y + m
  end
  local frameMe -- local character, resolved once per frame
  local function isVisible(from, to, ignoreChar, force)
    if not force and not F.aim_vis then return true end
    local ignore = {}
    local me = frameMe or myChar()
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
        -- only *Value objects carry the item name; anything else made the
        -- old code rely on a pcall failing to skip it
        if o:IsA("ValueBase") then
          local ok, v = pcall(function() return o.Value end)
          if ok and v ~= nil then
            local t = tostring(v)
            if t ~= "" and t ~= "nil" and t ~= "false" then return t end
          end
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
  local lootCache, corpseCache, npcCache, exitCache, botCache = {}, {}, {}, {}, {}
  local syncLabelMaps -- fwd: defined below scanWorld, runs on ticks
  local function hlKeys()
    local out = {}
    for k in tostring(F.loot_keys or ""):gmatch("[^,]+") do
      k = k:gsub("^%s+", ""):gsub("%s+$", ""):lower()
      if k ~= "" then table.insert(out, k) end
    end
    return out
  end
  -- Runs on a background task, NOT inside RenderStepped: GetDescendants()
  -- over Containers can be tens of thousands of nodes and used to hitch the
  -- frame every 2s. It also builds into temp tables and swaps them in at the
  -- end, so a yield mid-scan never leaves the render loop with empty caches.
  local SCAN_BUDGET = 1500 -- nodes between yields
  local function scanWorld()
    local budget = SCAN_BUDGET
    local function step()
      budget = budget - 1
      if budget <= 0 then budget = SCAN_BUDGET; task.wait() end
    end
    local loot, corpses, npcs, exits, bots = {}, {}, {}, {}, {}
    local myPos = myHRP() and myHRP().Position or nil
    local keys = hlKeys()
    local function lootKindOf(model, root)
      local p = model
      while p and p ~= workspace do
        local nm = p.Name
        if nm == "DroppedItems" then return "drop" end
        if nm == "Containers" then return "cont" end
        if nm == "QuestItems" then return "quest" end
        if nm == "LootSpawns" then return "spawn" end
        p = p.Parent
      end
      return nil
    end
    local roots = {}
    for _, nm in ipairs({ "Containers", "DroppedItems", "QuestItems" }) do
      local f = workspace:FindFirstChild(nm)
      if f then table.insert(roots, f) end
    end
    local nc = workspace:FindFirstChild("NoCollision")
    local ls = nc and nc:FindFirstChild("LootSpawns")
    if ls then table.insert(roots, ls) end
    for _, root in ipairs(roots) do
      local ok, desc = pcall(function() return root:GetDescendants() end)
      if ok then
        -- Only the OUTERMOST model of each item is labelled. GetDescendants
        -- returns parents before children, so a taken-ancestor test is
        -- enough; without it a crate with sub-models drew 5 stacked labels.
        local taken = {}
        for _, v in ipairs(desc) do
          step()
          if v:IsA("Model") then
            local anc, dup = v.Parent, false
            while anc and anc ~= root do
              if taken[anc] then dup = true break end
              anc = anc.Parent
            end
            if not dup then
              local cf, size = boxOf(v)
              if cf and size and size.Magnitude > 0.5 then
                taken[v] = true
                local nm = v.Name
                local star = false
                if F.loot_hl then
                  local ln = string.lower(nm)
                  for _, k in ipairs(keys) do
                    if string.find(ln, k, 1, true) then star = true break end
                  end
                end
                table.insert(loot, {
                  pos = cf.Position, name = nm,
                  kind = lootKindOf(v, root) or "drop",
                  star = star, m = v,
                })
              end
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
      local alt = workspace:FindFirstChild(pl.Name)
      if alt then liveChars[alt] = true end
    end
    for _, v in ipairs(workspace:GetChildren()) do
      step()
      if v:IsA("Model") then
        local hum = v:FindFirstChildOfClass("Humanoid")
        if hum then
          if hum.Health <= 0 then
            local cf = select(1, boxOf(v))
            -- keep a root part: ragdolls slide after death and a position
            -- snapshot taken at scan time goes stale for up to 2 seconds
            local rootPart = v.PrimaryPart
              or v:FindFirstChild("HumanoidRootPart")
              or v:FindFirstChild("UpperTorso")
              or v:FindFirstChild("Torso")
              or v:FindFirstChild("Head")
            table.insert(corpses, {
              pos = cf and cf.Position or (rootPart and rootPart.Position) or nil,
              root = rootPart,
              name = v.Name, isPlayer = isPlayerModel(v), m = v,
            })
          elseif not liveChars[v] and not isPlayerModel(v) then
            -- NPC trader/boss (has HP, nobody's character)
            local hrp = v:FindFirstChild("HumanoidRootPart") or v.PrimaryPart
            if hrp then
              table.insert(npcs, { model = v, hrp = hrp, hum = hum, name = v.Name })
            end
          end
        end
      end
    end
    local ex = nc and nc:FindFirstChild("ExitLocations")
    if ex then
      -- descendants, not children: exits are sometimes wrapped in a Model
      local ok, desc = pcall(function() return ex:GetDescendants() end)
      for _, v in ipairs(ok and desc or {}) do
        step()
        if v:IsA("BasePart") then
          table.insert(exits, { pos = v.Position, name = v.Name, part = v })
        end
      end
    end
    -- hostile bots live nested under AiZones (traders are top-level NPC).
    -- Faction attribute marks hostiles; dead ones join the corpse list.
    do
      local az = workspace:FindFirstChild("AiZones")
      if az then
        local ok, desc = pcall(function() return az:GetDescendants() end)
        for _, v in ipairs(ok and desc or {}) do
          if v:IsA("Model") then
            step()
            local hum = v:FindFirstChildOfClass("Humanoid")
            if hum then
              local hrp = v:FindFirstChild("HumanoidRootPart") or v.PrimaryPart
              if hum.Health > 0 then
                if hrp then
                  table.insert(bots, {
                    model = v, hrp = hrp, hum = hum, name = v.Name,
                    faction = tostring(v:GetAttribute("Faction") or "?"),
                  })
                end
              else
                local cf = select(1, boxOf(v))
                table.insert(corpses, {
                  pos = cf and cf.Position or (hrp and hrp.Position) or nil,
                  root = hrp,
                  name = v.Name, isPlayer = false, m = v,
                })
              end
            end
          end
        end
      end
    end
    -- nearest-first: the loot glow budget goes to the closest crates
    if myPos then
      table.sort(loot, function(a, b)
        local da = a.pos and (a.pos - myPos).Magnitude or 1e9
        local db = b.pos and (b.pos - myPos).Magnitude or 1e9
        return da < db
      end)
    end
    if moduleDead then return end
    lootCache, corpseCache, npcCache, exitCache, botCache = loot, corpses, npcs, exits, bots
    syncLabelMaps()
  end

  -- persistent label objects (zero per-frame allocation): created on
  -- discovery during scans, updated per frame, destroyed when gone
  local lootMap, corpseMap, npcMap, exitMap, botMap = {}, {}, {}, {}, {}
  local function mkLabel(size)
    local t = shape("Text")
    pcall(function()
      t.Center = true; t.Outline = true
      t.Transparency = 1 -- was 0 = fully invisible
      t.Font = 2; t.ZIndex = 3
      t.Size = size or 12; t.Visible = false
    end)
    return t
  end
  local function killDraw(o) pcall(function() o:Remove() end) end
  function syncLabelMaps()
    local seenL, seenC, seenN, seenE, seenB = {}, {}, {}, {}, {}
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
    for _, b in ipairs(botCache) do
      local m = b.model
      if m and m.Parent then
        seenB[m] = true
        if not botMap[m] then botMap[m] = { lbl = mkLabel(13) } end
        b.lbl = botMap[m].lbl
      else
        b.lbl = nil
      end
    end
    for m, o in pairs(lootMap) do if not seenL[m] then killDraw(o.lbl) lootMap[m] = nil end end
    for m, o in pairs(corpseMap) do if not seenC[m] then killDraw(o.lbl) corpseMap[m] = nil end end
    for m, o in pairs(npcMap) do if not seenN[m] then killDraw(o.lbl) npcMap[m] = nil end end
    for p, o in pairs(exitMap) do if not seenE[p] then killDraw(o.lbl) exitMap[p] = nil end end
    for m, o in pairs(botMap) do if not seenB[m] then killDraw(o.lbl) botMap[m] = nil end end
  end

  -- --------------------------------------------------------------------------
  -- Glow
  -- --------------------------------------------------------------------------
  local glowMap = {}
  -- Roblox stops rendering Highlights past ~31 live instances: past the cap
  -- new ones silently do nothing, which looks exactly like a broken glow.
  -- TWO independent pools, not one shared counter: players/bots/npc/corpses
  -- were processed before loot every frame, so on any populated server they
  -- filled the whole shared cap and loot glow silently got zero, forever,
  -- regardless of F.glow_lootcap. Entities and loot now each guarantee a
  -- minimum; 20 + 10 = 30 stays under the engine's render ceiling.
  local GLOW_ENTITY_CAP = 20
  local GLOW_LOOT_CAP = 10
  local glowUsedEntity, glowUsedLoot = 0, 0
  local function setGlow(model, col, on, tag, pool)
    if not model or not model.Parent then return end
    local key = tostring(tag) .. "_" .. model:GetDebugId()
    local prev = glowMap[key]
    if not on then
      if prev then pcall(function() prev:Destroy() end) end
      glowMap[key] = nil
      return
    end
    local isLoot = pool == "loot"
    if prev and prev.Parent then
      -- refresh live props so the Through-walls / colour toggles apply to
      -- highlights that already exist (they used to be frozen at creation)
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
      t.Transparency = 1 -- was 0: this is why names/dist/weapon never drew
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
      l.Transparency = 1 -- was 0: tracers + corner lines never drew
      l.ZIndex = 2
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
    e.dist = mkTx(12)
    e.weapon = mkTx(12)
    e.trace = mkLn()
    for i = 1, 8 do e.corners[i] = mkLn() end
    pesc[plr] = e
    return e
  end
  local function hideRig(e)
    if not e then return end
    for _, k in ipairs({ "outline", "box", "hback", "hfill", "name", "dist", "weapon", "trace" }) do
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
    for _, k in ipairs({ "outline", "box", "hback", "hfill", "name", "dist", "weapon", "trace" }) do
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
  local aimOn, aimSince, aimTarget = false, 0, nil
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
    if ok and type(vis) == "boolean" then return vis end
    local ok2, vis2 = pcall(function() return api.Win.Visible end)
    if ok2 and type(vis2) == "boolean" then return vis2 end
    return false
  end

  -- --------------------------------------------------------------------------
  -- Status line
  -- --------------------------------------------------------------------------
  local statLbl, dbgLbl
  local statTick, nP, nC, nL, nB = 0, 0, 0, 0, 0

  -- --------------------------------------------------------------------------
  -- Main loop (silent by design: uncaught per-frame errors are observable)
  -- --------------------------------------------------------------------------
  reg(runService.RenderStepped:Connect(function(dt)
    pcall(function()
      camera = workspace.CurrentCamera or camera
      if not camera then return end
      clearTransient()
      local now = os.clock()
      dbg.frames = dbg.frames + 1
      if now - dbg.fpsT >= 1 then
        dbg.fps = math.floor(dbg.frames / math.max(now - dbg.fpsT, 0.01) + 0.5)
        dbg.frames, dbg.fpsT = 0, now
      end
      local me = myChar()
      frameMe = me
      local meHRP = me and me:FindFirstChild("HumanoidRootPart")
      local vs = camera.ViewportSize
      local seenGlow = {}
      glowUsedEntity, glowUsedLoot = 0, 0 -- per-frame budget reset, both pools
      nP, nC, nL, nB = 0, 0, 0, 0

      -- players (persistent rigs: props updated, hidden when invalid)
      if meHRP then
        for _, pl in ipairs(players:GetPlayers()) do
          if pl ~= LP then
            guarded("players", function()
              -- rigs are 14 Drawing objects each: build one only when the
              -- player actually reaches the drawing stage, not for every
              -- name on the player list
              local e = pesc[pl]
              local ch = pl.Character
              if not ch or not ch.Parent then ch = workspace:FindFirstChild(pl.Name) end
              local hum = ch and ch:FindFirstChildOfClass("Humanoid")
              local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
              if not (ch and hum and hum.Health > 0 and hrp) then hideRig(e) return end
              local d = (meHRP.Position - hrp.Position).Magnitude
              if d ~= d or d > F.esp_range then hideRig(e) return end
              nP = nP + 1
              -- glow FIRST (presence beats decoration, and it must keep
              -- working even when the drawing side is switched off)
              if F.glow_on then
                local key = "p_" .. ch:GetDebugId()
                setGlow(ch, F.glow_enemy, true, "p")
                seenGlow[key] = true
              end
              if not F.esp_on then hideRig(e) return end
              e = rigOf(pl)
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
                e.trace.Transparency = 0.7
                e.trace.From = V2(vs.X / 2, vs.Y)
                e.trace.To = V2(cx, y0 + h)
              end
              -- name above the box, distance under it, weapon under that:
              -- one Text object each, so toggling one never blanks another
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
                wy = wy + 14
              end
              local g = F.esp_weapon and gunName(ch) or nil
              e.weapon.Visible = g ~= nil
              if g then
                e.weapon.Text = g
                e.weapon.Color = Color3.fromRGB(235, 235, 245)
                e.weapon.Position = V2(cx, wy)
              end
            end)
          end
        end
      else
        -- no local character (dead / loading): rigs must not freeze on screen
        for _, e in pairs(pesc) do hideRig(e) end
      end

      -- bots (hostile AI from AiZones — NOT the same as trader NPCs)
      if F.bot_esp and meHRP then
        guarded("bots", function()
          for _, b in ipairs(botCache) do
            local m = b.model
            local L = b.lbl
            if L then L.Visible = false end
            if m and m.Parent and b.hum.Health > 0 and L then
              local d = (meHRP.Position - b.hrp.Position).Magnitude
              if d == d and d <= F.bot_range then
                nB = nB + 1
                local cf, size = boxOf(m)
                if cf and size then
                  local t2, tOn = wts(cf.Position + Vector3.new(0, size.Y / 2, 0))
                  if tOn and onScreenPt(t2, vs) then
                    L.Text = b.name .. "  " .. math.floor(d + 0.5) .. "m"
                    L.Color = F.bot_col
                    L.Position = V2(t2.X, t2.Y - 8)
                    L.Visible = true
                  end
                end
                if F.bot_glow then
                  local key = "b_" .. m:GetDebugId()
                  setGlow(m, F.bot_col, true, "b")
                  seenGlow[key] = true
                end
              end
            end
          end
        end)
      else
        for _, b in ipairs(botCache) do
          if b.lbl then b.lbl.Visible = false end
        end
      end

      -- npc (traders/bosses)
      if F.npc_on and meHRP then
        guarded("npc", function()
          for _, npc in ipairs(npcCache) do
            local m = npc.model
            local L = npc.lbl
            if L then L.Visible = false end
            local hum = npc.hum
            if hum and not hum.Parent then hum = m and m:FindFirstChildOfClass("Humanoid") end
            local hrp = npc.hrp
            if hrp and not hrp.Parent then hrp = m and m:FindFirstChild("HumanoidRootPart") end
            -- a destroyed Humanoid used to throw here and kill the whole
            -- NPC pass for that frame
            if m and m.Parent and hum and hrp and hum.Health > 0 then
              local d = (meHRP.Position - hrp.Position).Magnitude
              if d == d and d <= F.npc_range then
                local cf, size = boxOf(m)
                if cf and size then
                  local t2, tOn = wts(cf.Position + Vector3.new(0, size.Y / 2, 0))
                  if tOn and L and onScreenPt(t2, vs) then
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
      else
        for _, o in pairs(npcMap) do
          if o.lbl then pcall(function() o.lbl.Visible = false end) end
        end
      end

      -- corpses
      if F.corpse_on and meHRP then
        guarded("corpse", function()
          for _, c in ipairs(corpseCache) do
            local L = c.lbl
            if L then L.Visible = false end
            -- ragdolls keep sliding after death: follow the root part when
            -- it still exists instead of the scan-time snapshot
            local cpos = c.pos
            if c.root and c.root.Parent then cpos = c.root.Position end
            if cpos and L then
              local showAI = c.isPlayer or F.corpse_ai
              if showAI then
                local d = (meHRP.Position - cpos).Magnitude
                if d == d and d <= F.corpse_range then
                  nC = nC + 1
                  local col = c.isPlayer and F.corpse_col or F.corpse_ai_col
                  local sp, on = wts(cpos + Vector3.new(0, 1, 0))
                  if on and onScreenPt(sp, vs) then
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
        for _, o in pairs(corpseMap) do
          if o.lbl then pcall(function() o.lbl.Visible = false end) end
        end
      end
      if F.glow_corpse and meHRP then
        guarded("corpseGlow", function()
          for _, c in ipairs(corpseCache) do
            local cpos = c.pos
            if c.root and c.root.Parent then cpos = c.root.Position end
            if cpos and (meHRP.Position - cpos).Magnitude <= F.corpse_range then
              -- use the cached instance: FindFirstChild(name) could grab a
              -- respawned LIVE body that reused the same name
              local m = c.m
              local hum = m and m.Parent and m:FindFirstChildOfClass("Humanoid")
              if m and m.Parent and m:IsA("Model") and hum and hum.Health <= 0 then
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
            -- explicit dispatch: the old `or F.loot_cont` fallback meant
            -- unchecking Dropped/Quest did nothing while Containers was on
            local want
            if it.kind == "drop" then want = F.loot_drop == true
            elseif it.kind == "quest" then want = F.loot_quest == true
            else want = F.loot_cont == true end -- cont + spawn
            if want and it.pos and L then
              local d = (meHRP.Position - it.pos).Magnitude
              if d == d and d <= F.loot_range then
                nL = nL + 1
                local sp, on = wts(it.pos)
                -- container crates can hide their name while keeping the glow
                local nameOk = (it.kind ~= "cont" and it.kind ~= "spawn") or F.loot_contname
                if on and nameOk and onScreenPt(sp, vs) then
                  local col = it.star and F.loot_hlcol or F.loot_col
                  local nm = (it.star and "* " or "") .. it.name
                  L.Text = nm .. "  " .. math.floor(d + 0.5) .. "m"
                  L.Color = col
                  L.Size = it.star and 14 or 12
                  L.Position = V2(sp.X, sp.Y)
                  L.Visible = true
                end
                -- lootCache is sorted nearest-first (see scanWorld), so
                -- stopping once the loot pool is full still glows the
                -- closest crates, not an arbitrary subset
                local lootCap = clamp(math.floor(F.glow_lootcap or GLOW_LOOT_CAP), 1, GLOW_LOOT_CAP)
                if F.glow_loot and glowUsedLoot < lootCap
                  and it.m and it.m.Parent then
                  local gc = it.star and F.glow_star
                    or (it.kind == "drop" and F.glow_drop
                      or (it.kind == "quest" and F.glow_quest or F.glow_cont))
                  local key = "l_" .. it.m:GetDebugId()
                  setGlow(it.m, gc, true, "l", "loot")
                  seenGlow[key] = true
                end
              end
            end
          end
        end)
      else
        for _, o in pairs(lootMap) do
          if o.lbl then pcall(function() o.lbl.Visible = false end) end
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
                if on and onScreenPt(sp, vs) then
                  L.Text = "EXIT " .. tostring(e.name) .. "  " .. math.floor(d + 0.5) .. "m"
                  L.Color = F.exit_col
                  L.Position = V2(sp.X, sp.Y)
                  L.Visible = true
                end
              end
            end
          end
        end)
      else
        for _, o in pairs(exitMap) do
          if o.lbl then pcall(function() o.lbl.Visible = false end) end
        end
      end

      -- radar
      if F.radar_on and meHRP then
        guarded("radar", function()
          local size = F.radar_size or 170
          local pos = V2(vs.X - size - 16, vs.Y - size - 16)
          local bg = tshape("Square")
          -- Drawing.Color needs a Color3. The old {R=,G=,B=} tables threw,
          -- and the throw took the rest of the frame with it.
          bg.Color = Color3.fromRGB(15, 15, 26)
          bg.Filled = true; bg.Transparency = 0.55; bg.Thickness = 1
          bg.Size = V2(size, size); bg.Position = V2(pos.X, pos.Y)
          local bd = tshape("Square")
          bd.Color = Color3.fromRGB(64, 140, 179)
          bd.Filled = false; bd.Transparency = 1; bd.Thickness = 1
          bd.Size = V2(size, size); bd.Position = V2(pos.X, pos.Y)
          -- flatten the camera basis onto XZ: with a pitched camera the raw
          -- LookVector squashed the blips toward the centre
          local look = camera.CFrame.LookVector
          local fwd = Vector3.new(look.X, 0, look.Z)
          fwd = (fwd.Magnitude > 1e-4) and fwd.Unit or Vector3.new(0, 0, -1)
          local right = fwd:Cross(Vector3.new(0, 1, 0))
          local range = math.max(F.radar_range or 800, 1)
          local sc = (size / 2 - 4) / range
          local function dot(worldPos, col, s)
            local rel = worldPos - meHRP.Position
            local dx, dz = rel:Dot(right), rel:Dot(fwd)
            if dx ~= dx or dz ~= dz then return end
            if math.sqrt(dx * dx + dz * dz) > range then return end
            local p = tshape("Square")
            p.Color = col; p.Filled = true; p.Transparency = 1; p.Thickness = 1
            p.Size = V2(s, s)
            -- minus dz: what is in FRONT of you belongs at the TOP
            p.Position = V2(pos.X + size / 2 + dx * sc - s / 2,
                            pos.Y + size / 2 - dz * sc - s / 2)
          end
          local self3 = tshape("Square")
          self3.Color = Color3.fromRGB(120, 220, 255)
          self3.Filled = true; self3.Transparency = 1; self3.Thickness = 1
          self3.Size = V2(4, 4)
          self3.Position = V2(pos.X + size / 2 - 2, pos.Y + size / 2 - 2)
          for _, pl in ipairs(players:GetPlayers()) do
            if pl ~= LP then
              local ch = pl.Character
              if not ch or not ch.Parent then ch = workspace:FindFirstChild(pl.Name) end
              local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
              local hum = ch and ch:FindFirstChildOfClass("Humanoid")
              if hrp and hum and hum.Health > 0 then
                dot(hrp.Position, Color3.fromRGB(255, 90, 90), 4)
              end
            end
          end
          for _, c in ipairs(corpseCache) do
            if c.pos then dot(c.pos, Color3.fromRGB(255, 153, 38), 2) end
          end
          for _, e in ipairs(exitCache) do
            if e.pos then dot(e.pos, Color3.fromRGB(102, 230, 128), 3) end
          end
        end)
      end

      -- aim
      aimOn = false
      if F.aim_on and meHRP and not (F.aim_pause and hubOpen()) then
        guarded("aim", function()
          local cap = math.rad(F.aim_fov or 15)
          local maxR = F.aim_range or 1200
          local best, bestPl = nil, nil
          local bestScore = (F.aim_prio == "distance") and math.huge or cap
          local origin = camera.CFrame.Position
          local look = camera.CFrame.LookVector
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
                  -- hard range cap: locking onto someone across the whole
                  -- map is the single most obvious thing on a recording
                  if len == len and len > 1 and len <= maxR then
                    local ang = math.acos(clamp(look:Dot(dir / len), -1, 1))
                    if ang == ang and ang < cap and isVisible(origin, ap, ch) then
                      local score = (F.aim_prio == "distance") and len or ang
                      if score < bestScore then
                        bestScore = score; best = ap; bestPl = pl
                      end
                    end
                  end
                end
              end
            end
          end
          -- hostile bots use the same cone/range/visibility rules as players
          if F.aim_bots then
            for _, b in ipairs(botCache) do
              local m = b.model
              if m and m.Parent and b.hum.Health > 0 then
                local ap = aimPoint(m, F.aim_part)
                if ap then
                  local dir = ap - origin
                  local len = dir.Magnitude
                  if len == len and len > 1 and len <= maxR then
                    local ang = math.acos(clamp(look:Dot(dir / len), -1, 1))
                    if ang == ang and ang < cap and isVisible(origin, ap, m) then
                      local score = (F.aim_prio == "distance") and len or ang
                      if score < bestScore then
                        bestScore = score; best = ap; bestPl = m
                      end
                    end
                  end
                end
              end
            end
          end
          if best then
            -- the delay is per TARGET, not per position. Tracking a position
            -- meant a running target kept re-arming the delay and the lock
            -- stuttered instead of following.
            if bestPl ~= aimTarget then
              aimTarget = bestPl
              aimSince = now
            end
            local hold = F.aim_hold
            if now - aimSince >= (F.aim_delay or 0)
              and (hold == "always"
                or (hold == "right" and userInput:IsMouseButtonPressed(Enum.UserInputType.MouseButton2))
                or (hold == "left" and userInput:IsMouseButtonPressed(Enum.UserInputType.MouseButton1))) then
              -- frame-rate independent: the same Smoothness used to move
              -- twice as fast at 120fps as it did at 60
              local base = clamp(1 - ((F.aim_smooth or 65) / 101), 0.05, 0.99)
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

      -- fov circle + lock dot
      -- NOTE: this block used to be unguarded AND used {R=,G=,B=} tables.
      -- aim_circle defaults to true, so it threw on EVERY frame and aborted
      -- the rest of the handler - gcGlow and the status labels never ran.
      guarded("hud", function()
        if F.aim_circle then
          local c = tshape("Circle")
          c.Color = Color3.fromRGB(51, 204, 255)
          c.Transparency = 0.6
          c.Filled = false
          c.Thickness = 1
          c.NumSides = 64
          -- match the actual cone: screen radius depends on the camera FOV,
          -- not on the aim angle alone
          local camFov = math.rad(clamp(camera.FieldOfView or 70, 1, 120))
          local r = math.tan(math.rad(clamp(F.aim_fov or 15, 1, 89)))
            / math.max(math.tan(camFov / 2), 1e-4) * (vs.Y / 2)
          c.Radius = math.abs(fin(r, 40))
          c.Position = V2(vs.X / 2, vs.Y / 2)
        end
        if aimOn then
          local dotm = tshape("Square")
          dotm.Color = Color3.fromRGB(255, 77, 77)
          dotm.Filled = true
          dotm.Transparency = 1 -- was 0 = invisible
          dotm.Thickness = 2
          dotm.Size = V2(7, 7)
          dotm.Position = V2(vs.X / 2 - 3.5, vs.Y / 2 - 3.5)
        end
      end)

      gcGlow(seenGlow)

      if statLbl and now - statTick > 2 then
        statTick = now
        if F.fullbright then brightApply(true) end -- re-assert daylight
        pcall(function()
          statLbl.Set(("players %d - bots %d - bodies %d - loot %d%s"):format(
            nP, nB, nC, nL, aimOn and " - LOCK" or ""))
          local parts = { ("loop %dfps"):format(dbg.fps) }
          for _, sec in ipairs({ "scan", "players", "npc", "corpse", "corpseGlow", "loot", "exits", "radar", "aim", "hud" }) do
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
  if not HAS_DRAWING then
    pSec:Paragraph("WARNING: this executor has no Drawing API. Boxes, names, distance, tracers and the radar cannot render. Glow (Highlight) still works.")
  end
  flagToggle(pSec, "ESP enabled", "esp_on", "Master switch for every player drawing")
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
  flagSlider(aSec, "Max range", "aim_range", 100, 3000, { suf = "m", tip = "Never lock past this distance" })
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
  flagToggle(gSec, "Loot glow", "glow_loot",
    "Highlight crates, dropped and quest items - nearest first")
  flagSlider(gSec, "Loot glow slots", "glow_lootcap", 1, 10,
    { tip = "Max simultaneous loot highlights (engine caps total highlights ~30)" })
  flagColor(gSec, "Crate glow", "glow_cont")
  flagColor(gSec, "Dropped glow", "glow_drop")
  flagColor(gSec, "Quest glow", "glow_quest")
  flagColor(gSec, "Star glow", "glow_star")

  local lSec = Tab:Section({ Name = "Loot" })
  lSec:Paragraph("Containers, floor drops, quest items. Starred = keyword match.")
  flagToggle(lSec, "Containers", "loot_cont")
  flagToggle(lSec, "Dropped items", "loot_drop")
  flagToggle(lSec, "Quest items", "loot_quest")
  flagToggle(lSec, "Keyword star", "loot_hl")
  flagToggle(lSec, "Container names", "loot_contname",
    "Hide crate names but keep their glow")
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
  wSec:Toggle({ Name = "Fullbright", Desc = "Always daylight, no dark corners",
    Default = F.fullbright == true, Flag = "pd_fullbright",
    Tooltip = "Restores raid lighting on off/unload",
    Callback = function(v)
      F.fullbright = v == true
      brightApply(F.fullbright)
    end })
  wSec:Paragraph("Bots are hostile AI (Faction). Traders are friendly NPC.")
  local botSec = Tab:Section({ Name = "Bots" })
  botSec:Paragraph("Hostile AI from AiZones (Bandits etc.) — separate from trader NPC.")
  flagToggle(botSec, "Bot ESP", "bot_esp")
  flagToggle(botSec, "Bot glow", "bot_glow")
  flagToggle(botSec, "Aim bots", "aim_bots")
  flagSlider(botSec, "Max distance", "bot_range", 200, 4000, { suf = "m" })
  flagColor(botSec, "Bot color", "bot_col")
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
  aboutSec:Label("PROJECT DELTA - hub module v" .. MODULE_VERSION .. " (safe build)")
  aboutSec:Paragraph("ESP + camera aim + glow + loot/corpses/exits/radar. No movement, no packets, no scripts touched — nothing for the server to fingerprint. Still: play sane, reports exist (PlayerReport).")
  statLbl = aboutSec:Label("players 0 - bodies 0 - loot 0")
  dbgLbl = aboutSec:Label("loop - fps")
  aboutSec:Button({ Name = "Text self-test", Variant = "ghost",
    Tooltip = "Draws 6 sample texts center-screen for 6s. Tell which rows you SEE.",
    Callback = function()
      task.spawn(function()
        local vs = camera.ViewportSize
        local cx, cy = vs.X / 2, vs.Y / 2 - 120
        local rows = {
          { "1 font0 outline", 0, true, 14 },
          { "2 font1 outline", 1, true, 14 },
          { "3 font2 plain", 2, false, 14 },
          { "4 font3 plain", 3, false, 14 },
          { "5 no-outline big", 1, false, 20 },
          { "6 font0 big outline", 0, true, 20 },
        }
        local objs = {}
        for i, r in ipairs(rows) do
          local ok, t = pcall(function()
            local x = Drawing.new("Text")
            x.Center = true
            x.Outline = r[3]
            x.Transparency = 1 -- 1 = solid in the Drawing API
            x.Font = r[2]
            x.Size = r[4]
            x.Color = Color3.new(0, 1, 0)
            x.Text = r[1]
            x.Position = Vector2.new(cx, cy + (i - 1) * 30)
            x.Visible = true
            return x
          end)
          if ok and t then table.insert(objs, t) end
        end
        task.wait(6)
        for _, t in ipairs(objs) do pcall(function() t:Remove() end) end
      end)
    end })
  aboutSec:Button({ Name = "Unload module", Variant = "danger", Callback = function()
    unloadModule()
  end })

  -- --------------------------------------------------------------------------
  -- Unload + boot
  -- --------------------------------------------------------------------------
  unloadModule = function()
    if moduleDead then return end -- hub + About button can both call this
    moduleDead = true
    for _, c in ipairs(CONNS) do pcall(function() c:Disconnect() end) end
    brightApply(false) -- restore raid lighting
    freeTransient()
    for _, h in pairs(glowMap) do pcall(function() h:Destroy() end) end
    for k in pairs(glowMap) do glowMap[k] = nil end
    for pl in pairs(pesc) do freeRig(pl) end
    for _, maps in ipairs({ lootMap, corpseMap, npcMap, exitMap, botMap }) do
      for m, o in pairs(maps) do
        if o.lbl then pcall(function() o.lbl:Remove() end) end
        maps[m] = nil
      end
    end
    local g = getgenv and getgenv()
    if g then
      if g.__HUMA_PLACE and g.__HUMA_PLACE.Unload == unloadModule then g.__HUMA_PLACE = nil end
      if g.__HUMA_DELTA and g.__HUMA_DELTA.Unload == unloadModule then g.__HUMA_DELTA = nil end
      g.__HUMA_DELTA_DBG = nil
    end
    Notify("Delta", "Module unloaded", "info")
  end

  -- background scanner: first pass immediately, then every 2s
  task.spawn(function()
    while not moduleDead do
      guarded("scan", scanWorld)
      local t = 0
      while t < 2 and not moduleDead do t = t + task.wait(0.25) end
    end
  end)
  if F.fullbright then brightApply(true) end

  local hub = { Unload = unloadModule }
  if getgenv then pcall(function()
    getgenv().__HUMA_DELTA = hub
    getgenv().__HUMA_PLACE = hub -- generic contract: hub unloads the place module
    -- live debug snapshot (flags, errors, counters) for diagnosis
    getgenv().__HUMA_DELTA_DBG = function()
      local ok, snap = pcall(function()
        local rigs, labels = 0, 0
        local visBox, visName, visDist, visWpn, visTrace = 0, 0, 0, 0, 0
        local sampleName, sampleAlpha
        for _, e in pairs(pesc) do
          rigs = rigs + 1
          pcall(function() if e.box.Visible then visBox = visBox + 1 end end)
          pcall(function() if e.name.Visible then visName = visName + 1 end end)
          pcall(function() if e.dist.Visible then visDist = visDist + 1 end end)
          pcall(function() if e.weapon.Visible then visWpn = visWpn + 1 end end)
          pcall(function() if e.trace.Visible then visTrace = visTrace + 1 end end)
          pcall(function()
            if e.name.Visible and not sampleName then
              sampleName = tostring(e.name.Text)
              sampleAlpha = e.name.Transparency
            end
          end)
        end
        for _, mp in ipairs({ lootMap, corpseMap, npcMap, exitMap }) do
          for _ in pairs(mp) do labels = labels + 1 end
        end
        return {
          ver = MODULE_VERSION,
          fps = dbg.fps, err = dbg.err, last = dbg.last,
          counts = { nP = nP, nC = nC, nL = nL, nB = nB },
          drawing = HAS_DRAWING,
          glow = { entity = glowUsedEntity, entityCap = GLOW_ENTITY_CAP,
                   loot = glowUsedLoot, lootCap = GLOW_LOOT_CAP },
          objs = { rigs = rigs, labels = labels },
          shown = { box = visBox, name = visName, dist = visDist,
                    weapon = visWpn, trace = visTrace },
          -- sampleAlpha must be 1. If it reads 0 the text is transparent.
          sample = { text = sampleName, alpha = sampleAlpha },
          flags = {
            box = F.esp_box, hp = F.esp_health, tracer = F.esp_tracer,
            on = F.esp_on,
            name = F.esp_name, dist = F.esp_dist, weapon = F.esp_weapon,
            glow = F.glow_on, range = F.esp_range, thick = F.esp_thick,
          },
        }
      end)
      if ok then return snap end
      return { error = tostring(snap) }
    end
  end) end

  if not HAS_DRAWING then
    Notify("Delta", "No Drawing API in this executor - only glow will render", "warn")
  end
  Notify("Delta", "Loaded v" .. MODULE_VERSION .. " - eyes only, play sane", "ok")
  print("[huma-delta] place module loaded v" .. MODULE_VERSION)
end
