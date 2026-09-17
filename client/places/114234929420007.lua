--[[
  HumaHub place module — tactical shooter (PlaceId 114234929420007).
  Repo path: client/places/114234929420007.lua

  SAFE BUILD: client-side overlays + camera assistance ONLY. No teleports,
  no noclip, no fly, no fling, no remotes, no hooks — the game runs BAC,
  anything replicated gets you banned.
  Place facts (verified live):
    - teams as player attribute Team ("Counter-Terrorists", ...), no Teams;
    - characters are Workspace.Characters.<PlayerName> models (R15, NO
      Humanoid — Health/MaxHealth/Dead live in model attributes);
    - gun name from player attribute CurrentEquipped (JSON, .Name);
    - mouse locked (LockCenter) while playing.
]]

return function(api)
  local Tab, Notify = api.Tab, api.Notify
  local NovaUI = api.Nova
  local MODULE_VERSION = "1.5-aim"

  local runService = game:GetService("RunService")
  local players = game:GetService("Players")
  local workspace = game:GetService("Workspace")
  local userInput = game:GetService("UserInputService")
  local lighting = game:GetService("Lighting")
  local http = game:GetService("HttpService")
  local camera = workspace.CurrentCamera
  local LP = players.LocalPlayer
  local rayParams = RaycastParams.new()

  -- Fullbright is local lighting only (nothing replicates): safe.
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
          if lighting[property] == target then return end
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
    local prev = g and g.__HUMA_PLACE
    if prev and type(prev.Unload) == "function" then pcall(prev.Unload) end
  end

  local F = {
    esp_on = false,
    esp_box = false, esp_health = false, esp_tracer = false,
    esp_name = false, esp_dist = false, esp_weapon = false,
    esp_thick = 2, esp_range = 4000,
    esp_enemy = Color3.fromRGB(255, 90, 90),
    esp_friend = Color3.fromRGB(110, 230, 130),
    look_on = false, look_range = 300, look_col = Color3.fromRGB(255, 200, 80),
    aimed_on = false, aimed_range = 500,
    aim_on = false, aim_part = "Head", aim_fov = 15, aim_smooth = 65,
    aim_range = 1200,
    aim_hold = "custom", aim_prio = "closest", aim_vis = true,
    aim_circle = false, aim_pause = true, aim_delay = 0.1,
    aim_toggle_key = Enum.UserInputType.MouseButton3, autofire = false,
    skip_friends = true, skip_wl = true, skip_mates = true, bl_only = false,
    glow_on = false, glow_top = true,
    glow_vis = false, glow_viscol = Color3.fromRGB(255, 255, 255), glow_visthick = 3,
    glow_enemy = Color3.fromRGB(255, 90, 90),
    glow_friend = Color3.fromRGB(110, 230, 130),
    fullbright = false,
    radar_on = false, radar_range = 800, radar_size = 170, radar_corner = "BottomRight",
    cs_mouse = true,
    aim_mode = "Assist", aim_strength = 35, aim_deadzone = 2, aim_key = Enum.KeyCode.LeftAlt,
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

  -- --------------------------------------------------------------------------
  -- Drawing objects. Transparency is OPACITY here: 1 = solid, 0 = INVISIBLE.
  -- --------------------------------------------------------------------------
  local pools = {}
  local allocating
  local function shape(typ)
    local s = Drawing.new(typ)
    if allocating then allocating[#allocating + 1] = s end
    pcall(function() s.Transparency = 1 end)
    s.Visible = true
    return s
  end
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
  -- Helpers (attribute-driven: this game has no Humanoids, no Teams)
  -- --------------------------------------------------------------------------
  local function myChar()
    local ch = LP.Character
    if ch and ch.Parent then return ch end
    local cf = workspace:FindFirstChild("Characters")
    if cf then
      ch = cf:FindFirstChild(LP.Name)
      if ch then return ch end
    end
    return workspace:FindFirstChild(LP.Name)
  end
  local function charOf(plr)
    local ch = plr.Character
    if ch and ch.Parent then return ch end
    local cf = workspace:FindFirstChild("Characters")
    if cf then
      ch = cf:FindFirstChild(plr.Name)
      if ch then return ch end
    end
    return nil
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
  local function attrHP(model)
    if not model then return nil, nil end
    local ok, h = pcall(function() return model:GetAttribute("Health") end)
    local ok2, mh = pcall(function() return model:GetAttribute("MaxHealth") end)
    if ok and type(h) == "number" then
      return h, (ok2 and type(mh) == "number" and mh > 0) and mh or 100
    end
    return nil, nil
  end
  local function attrDead(model)
    if not model then return true end
    local ok, d = pcall(function() return model:GetAttribute("Dead") end)
    return ok and d == true
  end
  local function teamOf(plr)
    local ok, t = pcall(function() return plr:GetAttribute("Team") end)
    if ok and type(t) == "string" and t ~= "" then return t end
    return nil
  end
  local function isMate(plr)
    local mine, theirs = teamOf(LP), teamOf(plr)
    return mine ~= nil and mine == theirs
  end
  local function gunName(plr)
    local ok, js = pcall(function() return plr:GetAttribute("CurrentEquipped") end)
    if ok and type(js) == "string" and js ~= "" then
      local ok2, t = pcall(function() return http:JSONDecode(js) end)
      if ok2 and type(t) == "table" and t.Name then return tostring(t.Name) end
    end
    return nil
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
  local frameMe
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

  -- --------------------------------------------------------------------------
  -- Persistent player rigs (created once, repositioned per frame)
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
  local RIG_KEYS = { "outline", "box", "hback", "hfill", "name", "dist", "weapon", "trace", "sight" }
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
      e.sight = mkLn()
      for i = 1, 8 do e.corners[i] = mkLn() end
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
    if e.corners then
      for _, l in ipairs(e.corners) do pcall(function() l.Visible = false end) end
    end
  end
  local function freeRig(plr)
    local e = pesc[plr]
    if not e then return end
    for _, k in ipairs(RIG_KEYS) do
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
  -- Aim state + white/black/friend lists (persisted via profile flags)
  -- --------------------------------------------------------------------------
  local aimOn, aimSince, aimTarget, aimToggle, fireTick = false, 0, nil, false, 0
  -- autofire = pulsed left-clicks through the input layer (same as you
  -- clicking). Capability-detected: VirtualInputManager, else mouse1press.
  local fireClick = nil
  do
    local okV, vim = pcall(function() return game:GetService("VirtualInputManager") end)
    if okV and vim then
      fireClick = function()
        pcall(function() vim:SendMouseButtonEvent(0, 0, 0, true, game, 0) end)
        task.delay(0.03, function()
          pcall(function() vim:SendMouseButtonEvent(0, 0, 0, false, game, 0) end)
        end)
      end
    elseif type(mouse1press) == "function" then
      fireClick = function()
        pcall(mouse1press)
        task.delay(0.03, function()
          pcall(function()
            if type(mouse1release) == "function" then mouse1release() end
          end)
        end)
      end
    elseif type(mouse1click) == "function" then
      fireClick = function() pcall(mouse1click) end
    end
  end
  local wlSet, blSet, friendSet, frSet = {}, {}, {}, {}
  local function aimAllowed(pl)
    local id = tostring(pl.UserId)
    if blSet[id] then return true end
    if F.bl_only then return false end
    if F.skip_mates ~= false and isMate(pl) then return false end
    if F.skip_friends ~= false and (friendSet[id] or frSet[id]) then return false end
    if F.skip_wl ~= false and wlSet[id] then return false end
    return true
  end
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
  local function bindingDown(key)
    if not key then return false end
    if key.EnumType == Enum.KeyCode then return userInput:IsKeyDown(key) end
    if key.EnumType == Enum.UserInputType then return userInput:IsMouseButtonPressed(key) end
    return false
  end

  -- --------------------------------------------------------------------------
  -- Glow (Highlights, engine-capped ~31: 20-slot entity pool + 2s grace that
  -- yields under pressure so the engine never overfills and flickers)
  -- --------------------------------------------------------------------------
  local glowMap = {}
  local glowSeenT = {}
  local objectIds, nextObjectId = setmetatable({}, { __mode = "k" }), 0
  local function glowKey(object, tag)
    if not objectIds[object] then nextObjectId = nextObjectId + 1; objectIds[object] = nextObjectId end
    return tag .. "_" .. objectIds[object]
  end
  local GLOW_ENTITY_CAP = 20
  local glowUsedEntity = 0
  local function setGlow(model, col, on, tag)
    if not model or not model.Parent then return end
    local key = glowKey(model, tostring(tag))
    local prev = glowMap[key]
    if not on then
      if prev then pcall(function() prev:Destroy() end) end
      glowMap[key] = nil
      glowSeenT[key] = nil
      return
    end
    if prev and prev.Parent then
      glowSeenT[key] = os.clock()
      glowUsedEntity = glowUsedEntity + 1
      pcall(function()
        if prev.FillColor ~= col then prev.FillColor = col end
        prev.DepthMode = F.glow_top and Enum.HighlightDepthMode.AlwaysOnTop
          or Enum.HighlightDepthMode.Occluded
      end)
      return
    end
    if glowUsedEntity >= GLOW_ENTITY_CAP then return end
    glowUsedEntity = glowUsedEntity + 1
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
  -- Status line
  -- --------------------------------------------------------------------------
  local statLbl, dbgLbl
  local statTick, nP = 0, 0
  local lastMenu, savedMouse = nil, nil
  -- click veil: fullscreen invisible button UNDER our window (DisplayOrder
  -- 40 < Nova's 50). Free cursor alone is not enough: clicks landing on
  -- bare game view are NOT consumed, so the game fires its gun under the
  -- menu. The veil eats every click outside the menu (menu itself is on
  -- top and keeps working). Keyboard is untouched — RightShift closes fine.
  local veilBtn = nil
  pcall(function()
    local sg = Instance.new("ScreenGui")
    sg.Name = "HumaVeil"
    sg.ResetOnSpawn = false
    sg.IgnoreGuiInset = true
    sg.DisplayOrder = 40
    sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    local vb = Instance.new("TextButton")
    vb.Name = "Veil"
    vb.Text = ""
    vb.BackgroundTransparency = 1
    vb.BorderSizePixel = 0
    vb.AutoButtonColor = false
    vb.Active = true
    vb.Size = UDim2.fromScale(1, 1)
    vb.Visible = false
    vb.Parent = sg
    local par = nil
    pcall(function() if gethui then par = gethui() end end)
    if par == nil then par = LP:WaitForChild("PlayerGui") end
    sg.Parent = par
    veilBtn = vb
    reg({ Disconnect = function()
      pcall(function() sg:Destroy() end)
    end })
  end)
  -- late-step mouse pin (see loop): re-bind cleanly on re-inject, unbind on unload.
  -- Verified live: the game re-locks the pointer ~every frame from several
  -- pipelines at once, so one RenderStep is not enough — RenderStep(100000)
  -- + Heartbeat + Stepped together hold Default 29/30 frames (one of them
  -- alone: 1/30). All three are cheap no-op checks while the menu is shut.
  local function mouseForce()
    if moduleDead then return end
    if lastMenu == true and F.cs_mouse ~= false then
      pcall(function()
        if userInput.MouseBehavior ~= Enum.MouseBehavior.Default then
          savedMouse = userInput.MouseBehavior
          userInput.MouseBehavior = Enum.MouseBehavior.Default
        end
        userInput.MouseIconEnabled = true
      end)
    end
  end
  pcall(function() runService:UnbindFromRenderStep("HumaMouseUnlock") end)
  do
    local ok, err = pcall(function()
      runService:BindToRenderStep("HumaMouseUnlock", 100000, mouseForce)
    end)
    if not ok then
      dbg.last = "mousebind: " .. tostring(err):sub(1, 60)
    end
  end
  reg(runService.Heartbeat:Connect(mouseForce))
  reg(runService.Stepped:Connect(mouseForce))
  -- the lock is re-applied on INPUT events (mouse move re-locks between
  -- frames — that's why it holds while dead and dies while playing), so
  -- counter-force on every input event too, not just every frame.
  reg(userInput.InputBegan:Connect(function() mouseForce() end))
  reg(userInput.InputChanged:Connect(function() mouseForce() end))
  reg(userInput.InputEnded:Connect(function() mouseForce() end))
  reg({ Disconnect = function()
    pcall(function() runService:UnbindFromRenderStep("HumaMouseUnlock") end)
  end })

  -- --------------------------------------------------------------------------
  -- Main loop (eyes + camera only — nothing here replicates)
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
      -- mouse unlock: the game re-locks the pointer (LockCenter) EVERY
      -- frame, so a one-time set melts instantly. While our window is open
      -- we pin Default late in the render step (after the camera), and give
      -- the game its lock back the moment the window closes.
      local menuOpen = hubOpen()
      if menuOpen ~= lastMenu then
        lastMenu = menuOpen
        if veilBtn then pcall(function() veilBtn.Visible = menuOpen end) end
        if not menuOpen then
          pcall(function()
            if savedMouse then userInput.MouseBehavior = savedMouse; savedMouse = nil end
          end)
        end
      end
      local me = myChar()
      frameMe = me
      local meHRP = me and me:FindFirstChild("HumanoidRootPart")
      local vs = camera.ViewportSize
      local seenGlow = {}
      glowUsedEntity = 0
      nP = 0
      local aimerCount = 0
      local myHead = me and me:FindFirstChild("Head")

      -- players (persistent rigs: props updated, hidden when invalid)
      if meHRP then
        local plist = players:GetPlayers()
        if F.glow_on and #plist > 1 then
          local mp = meHRP.Position
          local dist = {}
          for _, pl in ipairs(plist) do
            local ch = charOf(pl)
            local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
            dist[pl] = (hrp and (hrp.Position - mp).Magnitude) or 1e9
          end
          table.sort(plist, function(a, b) return dist[a] < dist[b] end)
        end
        for _, pl in ipairs(plist) do
          if pl ~= LP then
            local playerOk = guarded("players", function()
              local e = pesc[pl]
              local ch = charOf(pl)
              local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
              local hp, maxHp = attrHP(ch)
              if not (ch and hrp and hp and hp > 0 and not attrDead(ch)) then hideRig(e) return end
              local d = (meHRP.Position - hrp.Position).Magnitude
              if d ~= d or d > F.esp_range then hideRig(e) return end
              nP = nP + 1
              local mate = isMate(pl)
              local col = mate and F.esp_friend or F.esp_enemy
              local gcol = mate and F.glow_friend or F.glow_enemy
              if F.glow_on then
                local key = glowKey(ch, "p")
                setGlow(ch, gcol, true, "p")
                seenGlow[key] = true
              end
              if not F.esp_on then hideRig(e) return end
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
              local showHp = F.esp_health and (maxHp or 0) > 0
              e.hback.Visible = showHp
              e.hfill.Visible = showHp
              if showHp then
                local frac = clamp(hp / maxHp, 0, 1)
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
              local g = F.esp_weapon and gunName(pl) or nil
              e.weapon.Visible = g ~= nil
              if g then
                e.weapon.Text = g
                e.weapon.Color = Color3.fromRGB(235, 235, 245)
                e.weapon.Position = V2(cx, wy)
              end
              -- look ray + aimed-at-me check (own toggles, ESP pass)
              e.sight.Visible = false
              local hd = ch:FindFirstChild("Head")
              if hd and hd:IsA("BasePart") and (F.look_on or F.aimed_on) then
                local o = hd.Position
                local lv = hd.CFrame.LookVector
                if lv.Magnitude > 0.01 then
                  lv = lv.Unit
                  local maxL = math.max(F.look_range or 300, F.aimed_range or 0)
                  local okH, hit = pcall(function()
                    rayParams.FilterDescendantsInstances = { frameMe or me, ch }
                    rayParams.FilterType = Enum.RaycastFilterType.Exclude
                    rayParams.IgnoreWater = true
                    return workspace:Raycast(o, lv * maxL, rayParams)
                  end)
                  local wall = (okH and hit) and (hit.Position - o).Magnitude or maxL
                  if F.look_on and wall > 1 then
                    local drawL = math.min(wall, F.look_range or 300)
                    local h2, hOn = wts(o)
                    local e2, eOn = wts(o + lv * drawL)
                    if hOn and eOn and onScreenPt(h2, vs, 160) and onScreenPt(e2, vs, 160) then
                      e.sight.Color = mate and F.esp_friend or F.look_col
                      e.sight.Thickness = 1
                      e.sight.From = h2
                      e.sight.To = e2
                      e.sight.Visible = true
                    end
                  end
                  if F.aimed_on and myHead and myHead.Parent then
                    local mp2 = myHead.Position
                    local toMe = mp2 - o
                    local md = toMe.Magnitude
                    if md > 1 and md <= (F.aimed_range or 500) then
                      if lv:Dot(toMe / md) > 0.997 and wall + 1 >= md then
                        aimerCount = aimerCount + 1
                      end
                    end
                  end
                end
              end
            end)
            if not playerOk then freeRig(pl); rigRetry[pl] = os.clock() + 2 end
          end
        end
      else
        for _, e in pairs(pesc) do hideRig(e) end
      end

      -- radar (players only: red enemy, green mate)
      if F.radar_on and meHRP then
        guarded("radar", function()
          local size = F.radar_size or 170
          local corner = F.radar_corner or "BottomRight"
          local pos = V2(corner:find("Left") and 16 or vs.X - size - 16,
            corner:find("Top") and 48 or vs.Y - size - 16)
          local bg = tshape("Square")
          bg.Color = Color3.fromRGB(15, 15, 26)
          bg.Filled = true; bg.Transparency = 0.55; bg.Thickness = 1
          bg.Size = V2(size, size); bg.Position = V2(pos.X, pos.Y)
          local bd = tshape("Square")
          bd.Color = Color3.fromRGB(64, 140, 179)
          bd.Filled = false; bd.Transparency = 1; bd.Thickness = 1
          bd.Size = V2(size, size); bd.Position = V2(pos.X, pos.Y)
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
              local ch = charOf(pl)
              local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
              if hrp and not attrDead(ch) then
                dot(hrp.Position, isMate(pl) and Color3.fromRGB(110, 230, 130) or Color3.fromRGB(255, 90, 90), 4)
              end
            end
          end
        end)
      end

      -- aim (camera only — the only BAC-safe kind)
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
            if pl ~= LP and not isMate(pl) and aimAllowed(pl) then
              local ch = charOf(pl)
              if ch and not attrDead(ch) then
                local ap = aimPoint(ch, F.aim_part)
                if ap then
                  local dir = ap - origin
                  local len = dir.Magnitude
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
          if best then
            if bestPl ~= aimTarget then
              aimTarget = bestPl
              aimSince = now
            end
            local hold = F.aim_hold
            local holdActive = aimToggle
              or (hold == "always"
                or (hold == "right" and userInput:IsMouseButtonPressed(Enum.UserInputType.MouseButton2))
                or (hold == "left" and userInput:IsMouseButtonPressed(Enum.UserInputType.MouseButton1))
                or (hold == "custom" and F.aim_key and ((F.aim_key.EnumType == Enum.KeyCode and userInput:IsKeyDown(F.aim_key))
                  or (F.aim_key.EnumType == Enum.UserInputType and userInput:IsMouseButtonPressed(F.aim_key)))))
            if now - aimSince >= (F.aim_delay or 0) and holdActive then
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

      -- autofire: pulsed clicks while locked on. Never with the menu open
      -- (those clicks belong to the menu), never while dead.
      if F.autofire and aimOn and fireClick and not hubOpen() then
        local mc = myChar()
        if mc and not attrDead(mc) and meHRP and now - fireTick > 0.13 then
          fireTick = now
          fireClick()
        end
      end

      -- fov circle + lock dot + aimed-at dot
      guarded("hud", function()
        if F.aim_circle then
          local c = tshape("Circle")
          c.Color = Color3.fromRGB(51, 204, 255)
          c.Transparency = 0.6
          c.Filled = false
          c.Thickness = 1
          c.NumSides = 64
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
          dotm.Transparency = 1
          dotm.Thickness = 2
          dotm.Size = V2(7, 7)
          dotm.Position = V2(vs.X / 2 - 3.5, vs.Y / 2 - 3.5)
        end
        if F.aimed_on and aimerCount > 0 then
          local warn = tshape("Circle")
          warn.Color = Color3.fromRGB(255, 150, 60)
          warn.Transparency = 1
          warn.Filled = false
          warn.Thickness = 2
          warn.NumSides = 24
          warn.Radius = 7 + math.min(aimerCount, 5) * 2
          warn.Position = V2(vs.X / 2, vs.Y / 2 + 30)
        end
      end)

      gcGlow(seenGlow)

      if statLbl and now - statTick > 2 then
        statTick = now
        pcall(function()
          statLbl.Set(("players %d%s"):format(nP, aimOn and " - LOCK" or ""))
          local parts = { ("loop %dfps"):format(dbg.fps) }
          table.insert(parts, ("glow E%d/20"):format(math.min(glowUsedEntity, 99)))
          for _, sec in ipairs({ "players", "radar", "aim", "hud" }) do
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
    if moduleDead then return end
    moduleDead = true
    for _, c in ipairs(CONNS) do pcall(function() c:Disconnect() end) end
    for _, page in pairs(pages) do page:Destroy() end
    brightApply(false)
    freeTransient()
    for _, h in pairs(glowMap) do pcall(function() h:Destroy() end) end
    for k in pairs(glowMap) do glowMap[k] = nil end
    for k in pairs(glowSeenT) do glowSeenT[k] = nil end
    for pl in pairs(pesc) do freeRig(pl) end
    pcall(function()
      if savedMouse then userInput.MouseBehavior = savedMouse; savedMouse = nil end
    end)
    local g = getgenv and getgenv()
    if g then
      if g.__HUMA_PLACE and g.__HUMA_PLACE.Unload == unloadModule then g.__HUMA_PLACE = nil end
    end
    Notify("Shooter", "Module unloaded", "info")
  end

  local hub = { Unload = unloadModule }
  if getgenv then getgenv().__HUMA_PLACE = hub end

  -- --------------------------------------------------------------------------
  -- UI (ESP / Aim / World / About — nothing else, keep it clean)
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

  local nav = api.Navigation or Tab:Navigation({ Name = "Shooter" })
  local menuDefs = {
    { "ESP", "□", "Players and highlights" },
    { "Aim", "◎", "Camera assistance" },
    { "World", "◈", "Lighting, radar, mouse" },
    { "About", "i", "Status" },
  }
  for index, def in ipairs(menuDefs) do
    pages[def[1]] = nav:Page({ Id = "sh_" .. def[1]:lower(), Name = def[1],
      Icon = def[2], Tooltip = def[3], Order = index })
  end
  pages.ESP:Select()
  local espTabs = pages.ESP:SubTabs({ { Name = "Players" }, { Name = "Glow" } })

  local pSec = espTabs.Players:Section({ Name = "Players" })
  pSec:Paragraph("Red = enemy, green = teammate (by Team attribute). Eyes only.")
  if not HAS_DRAWING then
    pSec:Paragraph("WARNING: this executor has no Drawing API. Glow (Highlight) still works.")
  end
  flagToggle(pSec, "ESP enabled", "esp_on", "Master switch for every player drawing")
  flagToggle(pSec, "Boxes", "esp_box")
  flagToggle(pSec, "Health bar", "esp_health")
  flagToggle(pSec, "Tracers", "esp_tracer")
  flagToggle(pSec, "Names", "esp_name")
  flagToggle(pSec, "Distance", "esp_dist")
  flagToggle(pSec, "Weapon", "esp_weapon", "From the player's loadout data")
  flagSlider(pSec, "Thickness", "esp_thick", 1, 5)
  flagSlider(pSec, "Range", "esp_range", 200, 6000, { suf = "m" })
  flagColor(pSec, "Enemy color", "esp_enemy")
  flagColor(pSec, "Teammate color", "esp_friend")
  local lookSec = espTabs.Players:Section({ Name = "Look rays" })
  lookSec:Paragraph("A ray from every player's eyes, clipped by the first wall. Runs inside the player pass (needs ESP enabled).")
  flagToggle(lookSec, "Look rays", "look_on")
  flagSlider(lookSec, "Max length", "look_range", 50, 1500, { suf = "m" })
  flagColor(lookSec, "Ray color", "look_col")
  flagToggle(lookSec, "Aimed-at alert", "aimed_on",
    "Quiet dot under the crosshair while someone is looking at you (cone + wall checked, no text)")
  flagSlider(lookSec, "Alert range", "aimed_range", 100, 2000, { suf = "m" })

  -- Player lists: All / Whitelist / Blacklist. — → WL → BL → FR → —.
  -- Persisted in the profile as pd_wl_list / pd_bl_list / pd_fr_list.
  local plistSec = espTabs.Players:Section({ Name = "All players" })
  plistSec:Paragraph("Button on each row cycles: — → WL → BL → FR → —")
  flagToggle(plistSec, "Skip friends", "skip_friends", "Never aim at friends")
  flagToggle(plistSec, "Skip whitelist", "skip_wl", "Never aim at whitelisted players")
  flagToggle(plistSec, "Skip teammates", "skip_mates", "Never aim at your team")
  flagToggle(plistSec, "Blacklist only", "bl_only", "Aim ONLY at blacklisted players")
  local ALL_ROWS, SUB_ROWS = 14, 10
  local allRows, wlRows, blRows, listSearch = {}, {}, {}, ""
  local COL_BL = Color3.fromRGB(246, 114, 128)
  local COL_WL = Color3.fromRGB(122, 150, 255)
  local COL_FR = Color3.fromRGB(96, 214, 150)
  local function loadSets()
    wlSet, blSet, frSet = {}, {}, {}
    local function read(name)
      local N = NovaUI
      local v = N and N.Flags and N.Flags[name]
      if type(v) == "table" then return v end
      local L = N and N._loaded
      if type(L) == "table" and type(L[name]) == "table" then return L[name] end
      return {}
    end
    for _, id in ipairs(read("pd_wl_list")) do wlSet[tostring(id)] = true end
    for _, id in ipairs(read("pd_bl_list")) do blSet[tostring(id)] = true end
    for _, id in ipairs(read("pd_fr_list")) do frSet[tostring(id)] = true end
  end
  local function saveSets()
    local function arr(s)
      local o = {}
      for id in pairs(s) do o[#o + 1] = id end
      table.sort(o)
      return o
    end
    if NovaUI and NovaUI.Flags then
      NovaUI.Flags["pd_wl_list"] = arr(wlSet)
      NovaUI.Flags["pd_bl_list"] = arr(blSet)
      NovaUI.Flags["pd_fr_list"] = arr(frSet)
    end
  end
  local function isFriend(id) return friendSet[id] or frSet[id] end
  local function dispName(pl)
    return pl.DisplayName ~= pl.Name
      and (pl.DisplayName .. " (@" .. pl.Name .. ")") or pl.Name
  end
  local allHead, wlHead, blHead
  local function paintAll(i)
    local row = allRows[i]
    if not row or not row.plr then return end
    local id = tostring(row.plr.UserId)
    local tag, col, btn
    if blSet[id] then tag, col, btn = "BL", COL_BL, "BL"
    elseif wlSet[id] then tag, col, btn = "WL", COL_WL, "WL"
    elseif isFriend(id) then tag, col, btn = "FR", COL_FR, "FR"
    else tag, col, btn = "", nil, "—" end
    local nm = dispName(row.plr)
    row.lbl.Set(tag ~= "" and (nm .. "  [" .. tag .. "]") or nm)
    if col then pcall(function() row.lbl.Instance.TextColor3 = col end) end
    row.btn.SetText(btn)
    pcall(function() row.lbl.Instance.Visible = true end)
    pcall(function() row.btn.Instance.Visible = true end)
  end
  local function paintSub(rows, i, tag, col)
    local row = rows[i]
    if not row or not row.info then return end
    row.lbl.Set(row.info.name .. "  [" .. tag .. "]")
    pcall(function() row.lbl.Instance.TextColor3 = col end)
    row.btn.SetText("×")
    pcall(function() row.lbl.Instance.Visible = true end)
    pcall(function() row.btn.Instance.Visible = true end)
  end
  local function hideRow(row)
    pcall(function() row.lbl.Instance.Visible = false end)
    pcall(function() row.btn.Instance.Visible = false end)
  end
  local function refreshList()
    if players == nil or LP == nil then return end
    loadSets()
    local present = {}
    for _, pl in ipairs(players:GetPlayers()) do
      if pl ~= LP then present[#present + 1] = pl end
    end
    table.sort(present, function(a, b) return a.Name:lower() < b.Name:lower() end)
    local all = {}
    for _, pl in ipairs(present) do
      if listSearch == "" or (pl.Name:lower() .. " " .. pl.DisplayName:lower()):find(listSearch, 1, true) then
        all[#all + 1] = pl
      end
    end
    for i, row in ipairs(allRows) do
      row.plr = all[i]
      if row.plr then paintAll(i) else hideRow(row) end
    end
    local wl, bl = {}, {}
    for _, pl in ipairs(present) do
      local id = tostring(pl.UserId)
      if wlSet[id] then wl[#wl + 1] = { id = id, name = dispName(pl) } end
      if blSet[id] then bl[#bl + 1] = { id = id, name = dispName(pl) } end
    end
    for i, row in ipairs(wlRows) do
      row.info = wl[i]
      if row.info then paintSub(wlRows, i, "WL", COL_WL) else hideRow(row) end
    end
    for i, row in ipairs(blRows) do
      row.info = bl[i]
      if row.info then paintSub(blRows, i, "BL", COL_BL) else hideRow(row) end
    end
    local nWL, nBL, nFR = 0, 0, 0
    for _ in pairs(wlSet) do nWL = nWL + 1 end
    for _ in pairs(blSet) do nBL = nBL + 1 end
    for _ in pairs(frSet) do nFR = nFR + 1 end
    local extra = #all - ALL_ROWS
    if allHead then allHead.Set(("players %d%s"):format(
      #all, extra > 0 and (" · +" .. extra .. " hidden") or "")) end
    if wlHead then wlHead.Set(("whitelist %d"):format(nWL)) end
    if blHead then blHead.Set(("blacklist %d · manual friends %d"):format(nBL, nFR)) end
  end
  local function cycleAll(i)
    local row = allRows[i]
    if not row or not row.plr then return end
    local id = tostring(row.plr.UserId)
    if frSet[id] then frSet[id] = nil
    elseif blSet[id] then blSet[id] = nil; frSet[id] = true
    elseif wlSet[id] then wlSet[id] = nil; blSet[id] = true
    else wlSet[id] = true end
    saveSets()
    refreshList()
  end
  local function unlist(rows, i)
    local row = rows[i]
    if not row or not row.info then return end
    local id = row.info.id
    wlSet[id] = nil; blSet[id] = nil
    saveSets()
    refreshList()
  end
  local friendBusy = false
  local function scanFriends()
    if friendBusy then return end
    if players == nil or LP == nil then return end
    friendBusy = true
    task.spawn(function()
      local ok, pages = pcall(function() return players:GetFriendsAsync(LP.UserId) end)
      if ok and pages then
        local n = 0
        while true do
          local okP, items = pcall(function() return pages:GetCurrentPage() end)
          if not okP or type(items) ~= "table" then break end
          for _, it in ipairs(items) do
            local fid = it and (it.Id or it.UserId)
            if fid then friendSet[tostring(fid)] = true end
            n = n + 1
            if n > 1000 then break end
          end
          if n > 1000 then break end
          local okA, fin = pcall(function() return pages.IsFinished end)
          if not okA or fin then break end
          local okN = pcall(function() pages:AdvanceToNextPageAsync() end)
          if not okN then break end
        end
      end
      friendBusy = false
      pcall(refreshList)
    end)
  end
  plistSec:TextBox({ Name = "Search", Placeholder = "type a name…", Live = true, Flag = "pd_plist_search",
    Callback = function(v) listSearch = tostring(v or ""):lower(); refreshList() end })
  allHead = plistSec:Label("…")
  for i = 1, ALL_ROWS do
    local lbl = plistSec:Label("")
    local btn = plistSec:Button({ Name = "—", Callback = function() cycleAll(i) end })
    allRows[i] = { lbl = lbl, btn = btn, plr = nil }
    pcall(function() lbl.Instance.Visible = false end)
    pcall(function() btn.Instance.Visible = false end)
  end
  plistSec:Button({ Name = "Refresh lists", Variant = "ghost", Callback = function()
    refreshList(); scanFriends()
  end })
  local wlSec = espTabs.Players:Section({ Name = "Whitelist" })
  wlSec:Paragraph("Aim never touches these. × removes the mark.")
  wlHead = wlSec:Label("…")
  for i = 1, SUB_ROWS do
    local lbl = wlSec:Label("")
    local btn = wlSec:Button({ Name = "×", Callback = function() unlist(wlRows, i) end })
    wlRows[i] = { lbl = lbl, btn = btn, info = nil }
    pcall(function() lbl.Instance.Visible = false end)
    pcall(function() btn.Instance.Visible = false end)
  end
  local blSec = espTabs.Players:Section({ Name = "Blacklist" })
  blSec:Paragraph("Aim is forced on these. × removes the mark.")
  blHead = blSec:Label("…")
  for i = 1, SUB_ROWS do
    local lbl = blSec:Label("")
    local btn = blSec:Button({ Name = "×", Callback = function() unlist(blRows, i) end })
    blRows[i] = { lbl = lbl, btn = btn, info = nil }
    pcall(function() lbl.Instance.Visible = false end)
    pcall(function() btn.Instance.Visible = false end)
  end
  if players ~= nil then
    reg(players.PlayerAdded:Connect(function() refreshList() end))
    reg(players.PlayerRemoving:Connect(function() refreshList() end))
    if task ~= nil then
      task.defer(function()
        pcall(refreshList)
        pcall(scanFriends)
      end)
    end
  end

  local gSec = espTabs.Glow:Section({ Name = "Glow" })
  gSec:Paragraph("Client-side Highlights (see-through chams). Teammates green.")
  flagToggle(gSec, "Players", "glow_on")
  flagToggle(gSec, "Through walls", "glow_top")
  flagToggle(gSec, "Visible outline", "glow_vis",
    "Fat frame around targets NOT behind a wall (wall-checked)")
  flagSlider(gSec, "Outline thickness", "glow_visthick", 1, 6)
  flagColor(gSec, "Outline color", "glow_viscol")
  flagColor(gSec, "Enemy glow", "glow_enemy")
  flagColor(gSec, "Teammate glow", "glow_friend")

  local aSec = pages.Aim:Section({ Name = "Aim-assist" })
  aSec:Paragraph("Camera only — no packets. Toggle mode: tap the key once and the crosshair sticks to heads by itself (walls still skip). MMB by default, rebind below.")
  aSec:Keybind({ Name = "Aim toggle key", Default = F.aim_toggle_key, Flag = "pd_aim_toggle",
    Tooltip = "Tap to lock/unlock persistent aim",
    Callback = function(v) F.aim_toggle_key = v end }):OnPress(function()
    aimToggle = not aimToggle
    Notify("Aim", aimToggle and "Aim magnet ON" or "Aim magnet OFF", aimToggle and "ok" or "info")
  end)
  flagToggle(aSec, "Autofire", "autofire",
    "Clicks for you while locked on (input layer, like a real click). Off while the menu is open or you're dead.")
  if not fireClick then
    aSec:Paragraph("WARNING: this executor exposes no input simulation (no VirtualInputManager / mouse1press) — autofire cannot work here.")
  end
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
  flagDropdown(aSec, "Priority", "aim_prio", { "closest", "distance" })
  flagToggle(aSec, "Visible check", "aim_vis", "Skip targets behind walls")
  flagToggle(aSec, "FOV circle", "aim_circle")
  flagToggle(aSec, "Pause while hub open", "aim_pause")

  local wSec = pages.World:Section({ Name = "Lighting" })
  wSec:Toggle({ Name = "Fullbright", Desc = "Always daylight, no dark corners",
    Default = F.fullbright == true, Flag = "pd_fullbright",
    Tooltip = "Local lighting only — restores on off/unload",
    Callback = function(v)
      F.fullbright = v == true
      brightApply(F.fullbright)
    end })
  local radarSec = pages.World:Section({ Name = "Radar" })
  flagToggle(radarSec, "Radar", "radar_on")
  flagDropdown(radarSec, "Position", "radar_corner", { "TopLeft", "TopRight", "BottomLeft", "BottomRight" })
  flagSlider(radarSec, "Range", "radar_range", 100, 2000, { suf = "m" })
  flagSlider(radarSec, "Size", "radar_size", 100, 320, { suf = "px" })
  local mouseSec = pages.World:Section({ Name = "Mouse" })
  mouseSec:Paragraph("The game locks the pointer (LockCenter). While the hub window is open the pointer is yours; it returns to the game when you close the window.")
  flagToggle(mouseSec, "Unlock mouse in menu", "cs_mouse", "Free the pointer while the window is open")

  local aboutSec = pages.About:Section({ Name = "About" })
  aboutSec:Label("TACTICAL SHOOTER - hub module v" .. MODULE_VERSION .. " (safe build)")
  aboutSec:Paragraph("ESP + camera aim + glow + radar. Eyes and camera only: no movement, no packets, no scripts touched.")
  statLbl = aboutSec:Label("players 0")
  dbgLbl = aboutSec:Label("loop - fps")
  aboutSec:Button({ Name = "Rebuild overlays", Variant = "ghost", Callback = function()
    freeTransient()
    for player in pairs(pesc) do freeRig(player) end
    rigRetry = {}
    for key, highlight in pairs(glowMap) do pcall(function() highlight:Destroy() end); glowMap[key] = nil end
    for key in pairs(glowSeenT) do glowSeenT[key] = nil end
    HAS_DRAWING = pcall(function() local probe = Drawing.new("Square"); probe:Remove() end)
    Notify("Shooter", HAS_DRAWING and "Overlays rebuilt" or "Drawing API unavailable", HAS_DRAWING and "ok" or "warn")
  end })
  aboutSec:Button({ Name = "Unload module", Variant = "danger", Callback = function()
    unloadModule()
  end })

  if F.fullbright then brightApply(true) end

  local hub = { Unload = unloadModule }
  if getgenv then getgenv().__HUMA_PLACE = hub end
  return hub
end
