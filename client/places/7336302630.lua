--[[
  HumaHub place module — Project Delta (PlaceId 7336302630).
  Repo path: client/places/7336302630.lua

  Client-side overlays and optional camera assistance.
  Availability depends on streamed objects and executor APIs.
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
  local MODULE_VERSION = "2.8-delta"

  local runService = game:GetService("RunService")
  local players = game:GetService("Players")
  local workspace = game:GetService("Workspace")
  local userInput = game:GetService("UserInputService")
  local lighting = game:GetService("Lighting")
  local camera = workspace.CurrentCamera
  local LP = players.LocalPlayer
  local rayParams = RaycastParams.new()

  -- Keep illumination steady without repeatedly changing the world's clock.
  local brightOrig, brightConns, brightWriting = nil, {}, false
  local brightTargets = { Brightness = 2, FogEnd = 100000, GlobalShadows = false,
    Ambient = Color3.fromRGB(170, 170, 170), OutdoorAmbient = Color3.fromRGB(170, 170, 170) }
  local function brightApply(on)
    if on then
      if brightOrig then return end
      brightOrig = {}
      for property, target in pairs(brightTargets) do
        brightOrig[property] = lighting[property]
        brightConns[#brightConns + 1] = lighting:GetPropertyChangedSignal(property):Connect(function()
          if brightWriting or not brightOrig then return end
          if lighting[property] == target then return end -- deferred notification from our own write
          brightOrig[property] = lighting[property]
          brightWriting = true
          pcall(function() lighting[property] = target end)
          brightWriting = false
        end)
      end
      brightWriting = true
      for property, target in pairs(brightTargets) do pcall(function() lighting[property] = target end) end
      brightWriting = false
    elseif brightOrig then
      for _, c in ipairs(brightConns) do c:Disconnect() end
      brightConns = {}
      local restore = brightOrig; brightOrig = nil
      for property, value in pairs(restore) do pcall(function() lighting[property] = value end) end
    end
  end

  --// reload safety --------------------------------------------------------
  do
    local g = getgenv and getgenv()
    local prev = g and (g.__HUMA_PLACE or g.__HUMA_DELTA)
    if prev and type(prev.Unload) == "function" then pcall(prev.Unload) end
  end

  -- Defaults used until the hub restores the selected profile.
  local F = {
    esp_on = false, -- master switch for the player ESP drawings
    esp_box = false, esp_health = false, esp_tracer = false,
    esp_name = false, esp_dist = false, esp_weapon = false,
    esp_thick = 2, esp_range = 4000,
    esp_enemy = Color3.fromRGB(255, 90, 90),
    aim_on = false, aim_part = "Head", aim_fov = 15, aim_smooth = 65,
    aim_range = 1200,
    aim_hold = "right", aim_prio = "closest", aim_vis = true,
    aim_circle = false, aim_pause = true, aim_delay = 0.1,
    glow_on = false, glow_npc = false, glow_corpse = false, glow_top = true,
    glow_vis = false, glow_viscol = Color3.fromRGB(255, 255, 255), glow_visthick = 3,
    glow_enemy = Color3.fromRGB(255, 90, 90),
    glow_npc_c = Color3.fromRGB(150, 160, 170),
    glow_corpse_c = Color3.fromRGB(255, 150, 40),
    glow_loot = false,
    glow_cont = Color3.fromRGB(255, 170, 60),
    glow_drop = Color3.fromRGB(120, 220, 255),
    glow_quest = Color3.fromRGB(190, 120, 255),
    glow_star = Color3.fromRGB(255, 210, 90),
    glow_lootcap = 10,
    loot_cont = false, loot_drop = false, loot_quest = false,
    loot_hl = false, loot_keys = "card,key,defib,ledx,bitcoin,gpu,military, thermal, red, violet, gold",
    loot_col = Color3.fromRGB(120, 220, 255),
    loot_hlcol = Color3.fromRGB(255, 210, 90),
    loot_range = 1500,
    loot_contname = false,
    bot_esp = false, bot_col = Color3.fromRGB(255, 140, 50),
    bot_glow = false, bot_range = 2500,
    aim_bots = false,
    fullbright = false,
    corpse_on = false, corpse_ai = false,
    corpse_col = Color3.fromRGB(255, 150, 40),
    corpse_ai_col = Color3.fromRGB(200, 170, 60),
    corpse_range = 2500,
    npc_on = false, npc_col = Color3.fromRGB(150, 160, 170), npc_range = 2500,
    exit_on = false, exit_col = Color3.fromRGB(110, 230, 130), exit_range = 4000, exit_near = 80,
    radar_on = false, radar_range = 800, radar_size = 170, radar_corner = "BottomRight",
    loot_dropname = true, loot_questname = true, loot_contdist = false, loot_dropdist = true, loot_questdist = true,
    door_glow = false, door_names = true, door_dist = true, door_range = 200,
    door_color = Color3.fromRGB(255, 195, 70), door_assist = false, door_reach = 8,
    door_key = Enum.KeyCode.H,
    aim_mode = "Assist", aim_strength = 35, aim_deadzone = 2, aim_key = Enum.UserInputType.MouseButton2,
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
  local allocating
  local function shape(typ)
    local s = Drawing.new(typ)
    if allocating then allocating[#allocating + 1] = s end
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
    return ok
  end
  local function boxOf(model)
    local ok, cf, size = pcall(function() return model:GetBoundingBox() end)
    if model:IsA("BasePart") then return model.CFrame, model.Size end
    if ok and cf and size then return cf, size end
    return nil, nil
  end
  local function characterRect(ch, hum, hrp, vs)
    -- Body anchors exclude weapons, backpacks and detached accessories.
    local head = ch:FindFirstChild("Head")
    if head and (head.Position - hrp.Position).Magnitude > 12 then head = nil end
    local top3 = head and (head.Position + Vector3.new(0, head.Size.Y / 2, 0))
      or (hrp.Position + Vector3.new(0, 3, 0))
    local foot = clamp((hum.HipHeight or 2) + hrp.Size.Y / 2, 2.5, 5)
    local bot3 = hrp.Position - Vector3.new(0, foot, 0)
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
  local doorCache, doorTick = {}, -math.huge
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
  local function doorKeyName(object)
    -- Project Delta marks keyed doors with a KeyDoor=<KeyName> attribute
    -- (e.g. CraneKey). Empty/missing = not a keyed door.
    local ok, value = pcall(function() return object:GetAttribute("KeyDoor") end)
    if ok and type(value) == "string" and value ~= "" then return value end
    return nil
  end
  local function doorLocked(object)
    -- Project Delta marks keyed doors with KeyDoor=<KeyName> (self-contained:
    -- engine tests load this chunk standalone, so no helper calls here).
    local okK, keyVal = pcall(function() return object:GetAttribute("KeyDoor") end)
    if okK and type(keyVal) == "string" and keyVal ~= "" then return true end
    for _, key in ipairs({ "Locked", "IsLocked", "DoorLocked" }) do
      local value = object:GetAttribute(key)
      local child = object:FindFirstChild(key)
      if value == nil and child and child:IsA("BoolValue") then value = child.Value end
      if type(value) == "boolean" then return value end
    end
    for _, key in ipairs({ "RequiredKey", "KeyId", "KeyID", "KeyCard", "RequiresKey" }) do
      local value = object:GetAttribute(key)
      local child = object:FindFirstChild(key)
      if value == nil and child and child:IsA("ValueBase") then value = child.Value end
      if value ~= nil and value ~= false and tostring(value) ~= "" and tostring(value) ~= "0" then return true end
    end
    return false
  end
  local function scanDoors()
    local found, seen = {}, {}
    for index, object in ipairs(workspace:GetDescendants()) do
      if moduleDead then return end
      if index % 1500 == 0 then task.wait() end
      local interaction = object:IsA("ProximityPrompt") or object:IsA("ClickDetector")
      if interaction or ((object:IsA("Model") or object:IsA("BasePart")) and object.Name:lower():find("door", 1, true)) then
        local owner = interaction and object.Parent or object
        local match, named
        for _ = 1, 5 do
          if not owner or owner == workspace then break end
          if owner:IsA("Model") or owner:IsA("BasePart") then
            if doorLocked(owner) then match = owner; break end
            if owner.Name:lower():find("door", 1, true) and (not named or owner:IsA("Model")) then named = owner end
          end
          owner = owner.Parent
        end
        match = match or named
        if match then
          local part = match:IsA("BasePart") and match
            or match.PrimaryPart or match:FindFirstChildWhichIsA("BasePart", true)
            if part then
              local entry = seen[match]
              if not entry then
                entry = { m = match, root = part, name = match.Name, pos = part.Position,
                  actions = {}, key = doorKeyName(match) }
                seen[match] = entry; found[#found + 1] = entry
              end
            if interaction then entry.actions[#entry.actions + 1] = object end
          end
        end
      end
    end
    doorCache = found
  end
  local SCAN_BUDGET = 1500 -- nodes between yields
  local function scanWorld()
    if (F.door_glow or F.door_assist) and os.clock() - doorTick > 5 then
      doorTick = os.clock(); scanDoors()
    end
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
          if v:IsA("BasePart") or (v:IsA("Model") and (v.PrimaryPart or v:FindFirstChildOfClass("BasePart"))) then
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
          local owner = v
          while owner.Parent and owner.Parent ~= ex do owner = owner.Parent end
          local duplicate = false
          for _, e in ipairs(exits) do
            if (owner:IsA("Model") and e.owner == owner) or (e.pos - v.Position).Magnitude < 12 then
              duplicate = true
              if v.Name:lower() == "exit" then e.pos, e.part = v.Position, v end
              break
            end
          end
          if not duplicate then table.insert(exits, { pos = v.Position, name = v.Name, part = v, owner = owner }) end
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
  local lootMap, corpseMap, npcMap, exitMap, botMap, doorMap = {}, {}, {}, {}, {}, {}
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
    local root = myHRP()
    local function sync(cache, map, key, enabled, range, size)
      local seen = {}
      for _, entry in ipairs(cache) do
        local object = entry[key]
        local active = type(enabled) == "function" and enabled(entry) or enabled == true
        local position = entry.pos or (entry.hrp and entry.hrp.Position)
        if HAS_DRAWING and root and active and object and object.Parent and position
          and (position - root.Position).Magnitude <= range then
          seen[object] = true
          if not map[object] then map[object] = { lbl = mkLabel(size) } end
          entry.lbl = map[object].lbl
        else entry.lbl = nil end
      end
      for object, record in pairs(map) do
        if not seen[object] then killDraw(record.lbl); map[object] = nil end
      end
    end
    sync(lootCache, lootMap, "m", function(e)
      if e.kind == "drop" then return F.loot_drop and (F.loot_dropname or F.loot_dropdist) end
      if e.kind == "quest" then return F.loot_quest and (F.loot_questname or F.loot_questdist) end
      return F.loot_cont and (F.loot_contname or F.loot_contdist)
    end, F.loot_range, 12)
    sync(corpseCache, corpseMap, "m", F.corpse_on or F.corpse_ai, F.corpse_range, 13)
    sync(npcCache, npcMap, "model", F.npc_on, F.npc_range, 12)
    sync(exitCache, exitMap, "part", F.exit_on, F.exit_range, 14)
    sync(botCache, botMap, "model", F.bot_esp, F.bot_range, 13)
    sync(doorCache, doorMap, "m", F.door_glow and (F.door_names or F.door_dist), F.door_range, 13)
  end

  -- --------------------------------------------------------------------------
  -- Glow
  -- --------------------------------------------------------------------------
  local glowMap = {}
  local objectIds, nextObjectId = setmetatable({}, { __mode = "k" }), 0
  local function glowKey(object, tag)
    if not objectIds[object] then nextObjectId = nextObjectId + 1; objectIds[object] = nextObjectId end
    return tag .. "_" .. objectIds[object]
  end
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
    local key = glowKey(model, tostring(tag))
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
  local rigRetry = {}
  local function rigOf(plr)
    local e = pesc[plr]
    if e then return e end
    if (rigRetry[plr] or 0) > os.clock() then return nil end
    local made = {}; allocating = made
    local ok = pcall(function()
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
    end)
    allocating = nil
    if not ok then
      for _, object in ipairs(made) do killDraw(object) end
      rigRetry[plr] = os.clock() + 2
      return nil
    end
    rigRetry[plr] = nil
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
  reg(players.PlayerRemoving:Connect(function(plr) freeRig(plr); rigRetry[plr] = nil end))

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

  -- Door phase+open: Delta checks key/side on the SERVER, so spamming the
  -- remote from outside a locked door is pointless (the server just says no).
  -- What works — the manual trick, automated: on key PRESS (not hold, no
  -- loops) step once THROUGH the door plane to the far side, face the door
  -- like the F prompt wants, and fire 3 open packets from the inside
  -- position. The server pulls you back a moment later, but the door is
  -- already opening and stays open. No hooks, no key simulation.
  local doorRem
  local function getDoorRem()
    if doorRem and doorRem.Parent then return doorRem end
    local ok, rem = pcall(function()
      return game:GetService("ReplicatedStorage"):WaitForChild("Remotes", 3):WaitForChild("Door", 3)
    end)
    if ok and rem then doorRem = rem; return rem end
    return nil
  end
  local doorPrevHeld, doorCooldown = false, 0
  local function bindingDown(key)
    if not key then return false end
    if key.EnumType == Enum.KeyCode then return userInput:IsKeyDown(key) end
    if key.EnumType == Enum.UserInputType then return userInput:IsMouseButtonPressed(key) end
    return false
  end
  local function interactDoor(root)
    local now = os.clock()
    local held = F.door_assist and bindingDown(F.door_key) and not userInput:GetFocusedTextBox() and not hubOpen()
    local press = held and not doorPrevHeld
    doorPrevHeld = held
    if not press then return end
    if now - doorCooldown < 1 then return end
    doorCooldown = now
    local nearest, best = nil, tonumber(F.door_reach) or 8
    for _, entry in ipairs(doorCache) do
      if entry.m and entry.m.Parent and entry.root and entry.root.Parent then
        local distance = (root.Position - entry.root.Position).Magnitude
        if distance <= best then best, nearest = distance, entry end
      end
    end
    if not nearest then Notify("Doors", "No door close enough — get nearer", "info"); return end
    local rem = getDoorRem()
    if not rem then Notify("Doors", "Door remote not found", "warn"); return end
    task.spawn(function()
      local door = nearest -- loop var 'entry' dies with the loop; capture it
      local ok, err = pcall(function()
        -- aim at the DOOR'S MIDDLE, not entry.root: the scan keeps the
        -- first BasePart it finds, which is often the Hinge at the side
        -- of the doorway — walking at it phases you through the wall
        -- next to the door. Bounding-box center is the true middle.
        local boxCF = select(1, boxOf(door.m))
        local dp = (boxCF and boxCF.Position) or door.root.Position
        local dir0 = Vector3.new(dp.X - root.Position.X, 0, dp.Z - root.Position.Z)
        if dir0.Magnitude < 0.05 then
          local lv = root.CFrame.LookVector
          dir0 = Vector3.new(lv.X, 0, lv.Z)
          if dir0.Magnitude < 0.05 then dir0 = Vector3.new(0, 0, 1) end
        end
        dir0 = dir0.Unit
        -- (walk length is measured live against an exit point 3m past the
        -- middle, so any Reach distance works and yanks just mean walking.)
        local ch = myChar()
        local parts = {}
        if ch then
          for _, p in ipairs(ch:GetDescendants()) do
            if p:IsA("BasePart") then parts[p] = p.CanCollide; p.CanCollide = false end
          end
        end
        local hum = ch and ch:FindFirstChildOfClass("Humanoid")
        local autoWas = (hum and hum.AutoRotate) ~= false
        if hum then pcall(function() hum.AutoRotate = false end) end
        -- exit point: 3m past the middle along the walk line. Measured
        -- from the LIVE position every frame, so a server yank-back just
        -- means more walking instead of an early stop mid-slab.
        local exitPt = Vector3.new(dp.X + dir0.X * 3, root.Position.Y, dp.Z + dir0.Z * 3)
        local t0, lastFire = os.clock(), 0
        while os.clock() - t0 < 4 do
          if not root.Parent then break end
          local rp = root.Position
          local toExit = Vector3.new(exitPt.X - rp.X, 0, exitPt.Z - rp.Z)
          if toExit.Magnitude < 0.7 then break end
          local look = Vector3.new(dp.X, rp.Y, dp.Z)
          local step = 6 / 60
          root.CFrame = CFrame.new(
            Vector3.new(rp.X + dir0.X * step, rp.Y, rp.Z + dir0.Z * step), look)
          pcall(function() root.AssemblyLinearVelocity = Vector3.new(0, 0, 0) end)
          if ch and ch.Parent then
            for p in pairs(parts) do if p.Parent then p.CanCollide = false end end
          end
          pcall(function()
            local cam = workspace.CurrentCamera
            if cam then
              cam.CFrame = CFrame.new(cam.CFrame.Position, Vector3.new(dp.X, cam.CFrame.Position.Y, dp.Z))
            end
          end)
          local now = os.clock()
          if now - lastFire >= 0.06 then
            lastFire = now
            local p = root.Position
            pcall(function() rem:FireServer(nearest.m, 0, p.X, p.Y, p.Z) end)
          end
          task.wait()
        end
        for p, v in pairs(parts) do
          pcall(function() if p.Parent then p.CanCollide = v end end)
        end
        if hum then pcall(function() hum.AutoRotate = autoWas end) end
      end)
      if ok then Notify("Doors", "Phase walk → " .. tostring(nearest.name), "ok")
      else Notify("Doors", tostring(err), "warn") end
    end)
  end

  -- --------------------------------------------------------------------------
  -- Status line
  -- --------------------------------------------------------------------------
  local statLbl, dbgLbl
  local statTick, nP, nC, nL, nB = 0, 0, 0, 0, 0
  local labelTick = 0

  -- --------------------------------------------------------------------------
  -- Main loop (silent by design: uncaught per-frame errors are observable)
  -- --------------------------------------------------------------------------
  reg(runService.RenderStepped:Connect(function(dt)
    clearTransient()
    local renderOk, renderError = pcall(function()
      camera = workspace.CurrentCamera or camera
      if not camera then return end
      local now = os.clock()
      if now - labelTick > 0.25 then labelTick = now; guarded("labels", syncLabelMaps) end
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
            local playerOk = guarded("players", function()
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
                local key = glowKey(ch, "p")
                setGlow(ch, F.glow_enemy, true, "p")
                seenGlow[key] = true
              end
              if not F.esp_on then hideRig(e) return end
              e = rigOf(pl)
              if not e then return end
              local x0, y0, w, h, cx = characterRect(ch, hum, hrp, vs)
              if not x0 then hideRig(e) return end
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
            if not playerOk then freeRig(pl); rigRetry[pl] = os.clock() + 2 end
          end
        end
      else
        -- no local character (dead / loading): rigs must not freeze on screen
        for _, e in pairs(pesc) do hideRig(e) end
      end

      -- bots (hostile AI from AiZones — NOT the same as trader NPCs)
      if (F.bot_esp or F.bot_glow) and meHRP then
        guarded("bots", function()
          for _, b in ipairs(botCache) do
            local m = b.model
            local L = b.lbl
            if L then L.Visible = false end
            if m and m.Parent and b.hum.Health > 0 then
              local d = (meHRP.Position - b.hrp.Position).Magnitude
              if d == d and d <= F.bot_range then
                nB = nB + 1
                local cf, size = boxOf(m)
                if cf and size then
                  local t2, tOn = wts(cf.Position + Vector3.new(0, size.Y / 2, 0))
                  if F.bot_esp and L and tOn and onScreenPt(t2, vs) then
                    L.Text = b.name .. "  " .. math.floor(d + 0.5) .. "m"
                    L.Color = F.bot_col
                    L.Position = V2(t2.X, t2.Y - 8)
                    L.Visible = true
                  end
                end
                if F.bot_glow then
                  local key = glowKey(m, "b")
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
      if (F.npc_on or F.glow_npc) and meHRP then
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
                  if F.npc_on and tOn and L and onScreenPt(t2, vs) then
                    L.Text = npc.name .. "  " .. math.floor(d + 0.5) .. "m"
                    L.Color = F.npc_col
                    L.Position = V2(t2.X, t2.Y - 8)
                    L.Visible = true
                  end
                end
                if F.glow_npc then
                  local key = glowKey(m, "n")
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
      if (F.corpse_on or F.corpse_ai) and meHRP then
        guarded("corpse", function()
          for _, c in ipairs(corpseCache) do
            local L = c.lbl
            if L then L.Visible = false end
            -- ragdolls keep sliding after death: follow the root part when
            -- it still exists instead of the scan-time snapshot
            local cpos = c.pos
            if c.root and c.root.Parent then cpos = c.root.Position end
            if cpos and L then
              local showAI = (c.isPlayer and F.corpse_on) or (not c.isPlayer and F.corpse_ai)
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
                local key = glowKey(m, "c")
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
            if want and it.pos then
              local d = (meHRP.Position - it.pos).Magnitude
              if d == d and d <= F.loot_range then
                nL = nL + 1
                local sp, on = wts(it.pos)
                -- container crates can hide their name while keeping the glow
                local prefix = it.kind == "drop" and "loot_drop" or (it.kind == "quest" and "loot_quest" or "loot_cont")
                local nameOk, distOk = F[prefix .. "name"], F[prefix .. "dist"]
                if L and on and (nameOk or distOk) and onScreenPt(sp, vs) then
                  local col = it.star and F.loot_hlcol or F.loot_col
                  local nm = (it.star and "* " or "") .. it.name
                  L.Text = (nameOk and nm or "") .. (distOk and ((nameOk and "  " or "") .. math.floor(d + 0.5) .. "m") or "")
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
                  -- seen key MUST match setGlow's internal glowKey(model,"l"):
                  -- a GetDebugId-based key never matched, so gcGlow destroyed
                  -- every loot highlight in the same frame it was created and
                  -- crate/item glow never rendered at all.
                  local key = glowKey(it.m, "l")
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

      guarded("doors", function()
        for _, entry in ipairs(doorCache) do
          local label = entry.lbl
          if label then label.Visible = false end
          if F.door_glow and meHRP and entry.m.Parent and entry.root.Parent and doorLocked(entry.m) then
            local pos = entry.root.Position
            local distance = (pos - meHRP.Position).Magnitude
            if distance <= F.door_range then
              setGlow(entry.m, F.door_color, true, "door")
              seenGlow[glowKey(entry.m, "door")] = true
              local point, front = wts(pos)
              if label and front and onScreenPt(point, vs) and (F.door_names or F.door_dist) then
                label.Text = (F.door_names and ((entry.key and ("[KEY " .. entry.key .. "] ") or "[LOCKED] ") .. entry.name) or "")
                  .. (F.door_dist and (" " .. math.floor(distance + 0.5) .. "m") or "")
                label.Color = F.door_color; label.Position = point; label.Visible = true
              end
            end
          end
        end
        if meHRP then interactDoor(meHRP) end
      end)

      -- exits (persistent labels)
      if F.exit_on and meHRP then
        guarded("exits", function()
          for _, e in ipairs(exitCache) do
            local L = e.lbl
            if L then L.Visible = false end
            if e.pos and L then
              local d = (meHRP.Position - e.pos).Magnitude
              -- the game shows its own exit icon up close: hide ours inside
              -- exit_near so there is always exactly ONE exit label.
              if d == d and d <= F.exit_range and d >= (F.exit_near or 0) then
                local sp, on = wts(e.pos)
                if on and onScreenPt(sp, vs) then
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
        for _, o in pairs(exitMap) do
          if o.lbl then pcall(function() o.lbl.Visible = false end) end
        end
      end

      -- radar
      if F.radar_on and meHRP then
        guarded("radar", function()
          local size = F.radar_size or 170
          local corner = F.radar_corner or "BottomRight"
          local pos = V2(corner:find("Left") and 16 or vs.X - size - 16,
            corner:find("Top") and 48 or vs.Y - size - 16)
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
      if F.aim_on and meHRP and not userInput:GetFocusedTextBox() and not (F.aim_pause and hubOpen()) then
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
                or (hold == "left" and userInput:IsMouseButtonPressed(Enum.UserInputType.MouseButton1))
                or (hold == "custom" and F.aim_key and ((F.aim_key.EnumType == Enum.KeyCode and userInput:IsKeyDown(F.aim_key))
                  or (F.aim_key.EnumType == Enum.UserInputType and userInput:IsMouseButtonPressed(F.aim_key))))) then
              -- frame-rate independent: the same Smoothness used to move
              -- twice as fast at 120fps as it did at 60
              local base = clamp(1 - ((F.aim_smooth or 65) / 101), 0.05, 0.99)
              local step = clamp(math.max(dt or (1 / 60), 1 / 480) * 60, 0.05, 4)
              local alpha = clamp(1 - (1 - base) ^ step, 0.01, 1)
              if F.aim_mode == "Assist" then
                local angle = math.acos(clamp(look:Dot((best - origin).Unit), -1, 1))
                local dead = math.rad(F.aim_deadzone or 2)
                if angle <= dead then alpha = 0
                else alpha = math.min(alpha, math.rad(F.aim_strength or 35) * math.max(dt, 0) / angle) end
              end
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
        -- Lighting is maintained by change listeners, not periodic clock resets.
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
    finishTransient()
    if not renderOk then dbg.err.render = (dbg.err.render or 0) + 1; dbg.last = tostring(renderError) end
  end))

  local pages = {}
  unloadModule = function()
    if moduleDead then return end -- hub + About button can both call this
    moduleDead = true
    for _, c in ipairs(CONNS) do pcall(function() c:Disconnect() end) end
    for _, page in pairs(pages) do page:Destroy() end
    brightApply(false) -- restore raid lighting
    freeTransient()
    for _, h in pairs(glowMap) do pcall(function() h:Destroy() end) end
    for k in pairs(glowMap) do glowMap[k] = nil end
    for pl in pairs(pesc) do freeRig(pl) end
    for _, maps in ipairs({ lootMap, corpseMap, npcMap, exitMap, botMap, doorMap }) do
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

  local hub = { Unload = unloadModule }
  if getgenv then getgenv().__HUMA_PLACE = hub end

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

  local nav = api.Navigation or Tab:Navigation({ Name = "Project Delta" })
  local menuDefs = {
    { "ESP", "□", "Players, highlights and AI" },
    { "Aim", "◎", "Aim assistance" },
    { "Loot", "▣", "Containers, items and locked doors" },
    { "World", "◈", "Lighting, exits, radar and interaction" },
    { "About", "i", "Status and recovery" },
  }
  for index, def in ipairs(menuDefs) do
    pages[def[1]] = nav:Page({ Id = "delta_" .. def[1]:lower(), Name = def[1],
      Icon = def[2], Tooltip = def[3], Order = index })
  end
  pages.ESP:Select()
  local espTabs = pages.ESP:SubTabs({ { Name = "Players" }, { Name = "Glow" }, { Name = "Bots" } })
  local aimTabs = pages.Aim:SubTabs({ { Name = "Aim-assist" }, { Name = "Silent Aim" } })
  local lootTabs = pages.Loot:SubTabs({ { Name = "Containers" }, { Name = "Items" }, { Name = "Doors" }, { Name = "Filters" } })

  local pSec = espTabs.Players:Section({ Name = "Players" })
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

  local aSec = aimTabs["Aim-assist"]:Section({ Name = "Aim-assist" })
  aSec:Paragraph("Assist limits camera correction per second and leaves a dead zone around the crosshair.")
  flagDropdown(aSec, "Mode", "aim_mode", { "Assist", "Camera lock" })
  flagSlider(aSec, "Assist turn speed", "aim_strength", 1, 180, { suf = "deg/s" })
  flagSlider(aSec, "Assist dead zone", "aim_deadzone", 0, 10, { dec = 1, suf = "deg" })
  flagToggle(aSec, "Enabled", "aim_on")
  flagDropdown(aSec, "Aim part", "aim_part", { "Head", "UpperTorso", "HumanoidRootPart" })
  flagSlider(aSec, "FOV", "aim_fov", 5, 45)
  flagSlider(aSec, "Max range", "aim_range", 100, 3000, { suf = "m", tip = "Never lock past this distance" })
  flagSlider(aSec, "Smoothness", "aim_smooth", 1, 100, { tip = "Higher = slower, more human" })
  flagSlider(aSec, "Target delay", "aim_delay", 0, 0.5, { dec = 2, suf = "s", tip = "Reaction delay on new targets" })
  flagDropdown(aSec, "Trigger", "aim_hold", { "right", "left", "always", "custom" })
  aSec:Keybind({ Name = "Custom aim key", Default = F.aim_key, Flag = "pd_aim_key",
    Callback = function(v) F.aim_key = v end })
  local silentSec = aimTabs["Silent Aim"]:Section({ Name = "Silent Aim" })
  silentSec:Paragraph("Unavailable in this build: weapon integration has not been verified for the current game version.")
  flagDropdown(aSec, "Priority", "aim_prio", { "closest", "distance" })
  flagToggle(aSec, "Visible check", "aim_vis", "Skip targets behind walls")
  flagToggle(aSec, "FOV circle", "aim_circle")
  flagToggle(aSec, "Pause while hub open", "aim_pause")

  local gSec = espTabs.Glow:Section({ Name = "Glow" })
  gSec:Paragraph("Client-side Highlights (see-through chams).")
  flagToggle(gSec, "Players", "glow_on")
  flagToggle(gSec, "Through walls", "glow_top")
  flagToggle(gSec, "Visible outline", "glow_vis",
    "Fat frame around targets NOT behind a wall (wall-checked)")
  flagSlider(gSec, "Outline thickness", "glow_visthick", 1, 6)
  flagColor(gSec, "Outline color", "glow_viscol")
  flagColor(gSec, "Player glow", "glow_enemy")
  local lSec = lootTabs.Containers:Section({ Name = "Containers" })
  flagToggle(lSec, "Containers", "loot_cont")
  flagToggle(lSec, "Names", "loot_contname")
  flagToggle(lSec, "Distance", "loot_contdist")
  flagColor(lSec, "Glow color", "glow_cont")
  local dropSec = lootTabs.Items:Section({ Name = "Dropped items" })
  flagToggle(dropSec, "Dropped items", "loot_drop")
  flagToggle(dropSec, "Names", "loot_dropname")
  flagToggle(dropSec, "Distance", "loot_dropdist")
  flagColor(dropSec, "Glow color", "glow_drop")
  local questSec = lootTabs.Items:Section({ Name = "Quest items" })
  flagToggle(questSec, "Quest items", "loot_quest")
  flagToggle(questSec, "Names", "loot_questname")
  flagToggle(questSec, "Distance", "loot_questdist")
  flagColor(questSec, "Glow color", "glow_quest")
  local commonLoot = lootTabs.Filters:Section({ Name = "Shared loot settings" })
  flagToggle(commonLoot, "Loot glow", "glow_loot", "Applies to enabled loot categories")
  flagSlider(commonLoot, "Highlight budget", "glow_lootcap", 1, 10)
  flagSlider(commonLoot, "Max distance", "loot_range", 200, 4000, { suf = "m" })
  flagToggle(commonLoot, "Keyword star", "loot_hl")
  commonLoot:TextBox({ Name = "Keywords", Default = F.loot_keys, Flag = "pd_loot_keys",
    Callback = function(v) F.loot_keys = tostring(v or "") end })
  flagColor(commonLoot, "Label color", "loot_col")
  flagColor(commonLoot, "Star label", "loot_hlcol")
  flagColor(commonLoot, "Star glow", "glow_star")

  local bSec = espTabs.Bots:Section({ Name = "Bodies" })
  bSec:Paragraph("Lootable bodies: player corpses + AI corpses, distinct colors.")
  flagToggle(bSec, "Corpses", "corpse_on")
  flagToggle(bSec, "AI bodies", "corpse_ai")
  flagSlider(bSec, "Max distance", "corpse_range", 200, 4000, { suf = "m" })
  flagColor(bSec, "Player body", "corpse_col")
  flagColor(bSec, "AI body", "corpse_ai_col")
  flagToggle(bSec, "Body glow", "glow_corpse")
  flagColor(bSec, "Player body glow", "glow_corpse_c")

  local wSec = pages.World:Section({ Name = "Lighting" })
  wSec:Toggle({ Name = "Fullbright", Desc = "Always daylight, no dark corners",
    Default = F.fullbright == true, Flag = "pd_fullbright",
    Tooltip = "Restores raid lighting on off/unload",
    Callback = function(v)
      F.fullbright = v == true
      brightApply(F.fullbright)
    end })
  local botSec = espTabs.Bots:Section({ Name = "Bots" })
  botSec:Paragraph("Hostile AI from AiZones (Bandits etc.) — separate from trader NPC.")
  flagToggle(botSec, "Bot ESP", "bot_esp")
  flagToggle(botSec, "Bot glow", "bot_glow")
  flagToggle(botSec, "Aim bots", "aim_bots")
  flagSlider(botSec, "Max distance", "bot_range", 200, 4000, { suf = "m" })
  flagColor(botSec, "Bot color", "bot_col")
  local npcSec = espTabs.Bots:Section({ Name = "Traders / NPC" })
  flagToggle(npcSec, "Labels", "npc_on")
  flagToggle(npcSec, "Glow", "glow_npc")
  flagColor(npcSec, "Glow color", "glow_npc_c")
  flagSlider(npcSec, "Max distance", "npc_range", 200, 4000, { suf = "m" })
  flagColor(npcSec, "Label color", "npc_col")
  local exitSec = pages.World:Section({ Name = "Exits" })
  flagToggle(exitSec, "Exits", "exit_on")
  flagSlider(exitSec, "Max distance", "exit_range", 200, 6000, { suf = "m" })
  flagSlider(exitSec, "Hide when closer than", "exit_near", 0, 500,
    { suf = "m", tip = "The game shows its own exit icon up close — hide ours inside this range so only one label is visible" })
  flagColor(exitSec, "Color", "exit_col")
  local radarSec = pages.World:Section({ Name = "Radar" })
  flagToggle(radarSec, "Radar", "radar_on")
  flagDropdown(radarSec, "Position", "radar_corner", { "TopLeft", "TopRight", "BottomLeft", "BottomRight" })
  flagSlider(radarSec, "Range", "radar_range", 100, 2000, { suf = "m" })
  flagSlider(radarSec, "Size", "radar_size", 100, 320, { suf = "px" })

  local doorSec = lootTabs.Doors:Section({ Name = "Locked doors" })
  doorSec:Paragraph("Marks streamed doors that expose lock/key metadata. Unmarked doors may use a custom game controller.")
  flagToggle(doorSec, "Locked-door glow", "door_glow")
  flagToggle(doorSec, "Names", "door_names")
  flagToggle(doorSec, "Distance", "door_dist")
  flagSlider(doorSec, "Max distance", "door_range", 10, 1000, { suf = "m" })
  flagColor(doorSec, "Color", "door_color")
  local doorActionSec = pages.World:Section({ Name = "Door interaction" })
  doorActionSec:Paragraph("PRESS the key once (no holding, no loops): aim-locks the middle of the nearest door, noclips you straight through it and spams the same open packet as F the whole way. Walks until 3m past the door (max ~4s) — server yank-backs just mean more walking.")
  flagToggle(doorActionSec, "Door assist", "door_assist")
  flagSlider(doorActionSec, "Reach", "door_reach", 1, 15, { suf = "m" })
  doorActionSec:Keybind({ Name = "Interact key", Default = F.door_key, Flag = "pd_door_key",
    Callback = function(v) F.door_key = v end })

  local aboutSec = pages.About:Section({ Name = "About" })
  aboutSec:Label("PROJECT DELTA - hub module v" .. MODULE_VERSION .. "")
  aboutSec:Paragraph("ESP + camera aim + glow + loot/corpses/exits/radar. Rendering depends on objects streamed to this client. Live compatibility must be checked on each map.")
  statLbl = aboutSec:Label("players 0 - bodies 0 - loot 0")
  dbgLbl = aboutSec:Label("loop - fps")
  aboutSec:Button({ Name = "Rebuild overlays", Variant = "ghost", Callback = function()
    freeTransient()
    for player in pairs(pesc) do freeRig(player) end
    rigRetry = {}
    for _, map in ipairs({ lootMap, corpseMap, npcMap, exitMap, botMap, doorMap }) do
      for object, record in pairs(map) do killDraw(record.lbl); map[object] = nil end
    end
    for _, cache in ipairs({ lootCache, corpseCache, npcCache, exitCache, botCache, doorCache }) do
      for _, entry in ipairs(cache) do entry.lbl = nil end
    end
    for key, highlight in pairs(glowMap) do pcall(function() highlight:Destroy() end); glowMap[key] = nil end
    HAS_DRAWING = pcall(function() local probe = Drawing.new("Square"); probe:Remove() end)
    guarded("labels", syncLabelMaps)
    Notify("Delta", HAS_DRAWING and "Overlays rebuilt" or "Drawing API unavailable", HAS_DRAWING and "ok" or "warn")
  end })
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

  -- background scanner: first pass immediately, then every 2s
  task.spawn(function()
    while not moduleDead do
      guarded("scan", scanWorld)
      local t = 0
      while t < 2 and not moduleDead do t = t + task.wait(0.25) end
    end
  end)
  if F.fullbright then brightApply(true) end

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
