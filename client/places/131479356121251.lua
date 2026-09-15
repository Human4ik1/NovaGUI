--[[
  HumaHub place module — Bloxy Bingo (PlaceId 131479356121251).
  Repo path: client/places/131479356121251.lua

  FORMAT (same for every place module):
    - the file is ONE loadstring-able chunk;
    - it must RETURN a function taking the hub api:
        return function(api) ... end
    - api = {
    -   Nova   = NovaUI library,
    -   Win    = hub window,
    -   Tab    = your own Nova tab inside the hub window (build here!),
    -   Shared = hub helpers (hrpOf, teleportTo, isFriend, notify, ...),
    -   Notify = function(title, text, kind),
    - }
    - DO NOT create your own window / load another UI lib.
      Just do: local sec = api.Tab:Section({ Name = "..." }) and add controls.
    - Keep everything reload-safe via getgenv() (disconnect old conns).

  Logic below is the bingo core: read cards from BingoGui, daub called
  numbers through the game's own cell handlers, claim via ClaimBingo,
  catch-up on enable, anti-AFK.
]]

return function(api)
  local Tab, Notify = api.Tab, api.Notify

  local Players = game:GetService("Players")
  local ReplicatedStorage = game:GetService("ReplicatedStorage")
  local LP = Players.LocalPlayer

  --// reload safety: kill previous copy's connections ---------------------
  local old = getgenv().__HUMA_BINGO
  if old then
    pcall(function() for _, c in ipairs(old.conns or {}) do c:Disconnect() end end)
  end
  local S = {
    marker = false, bingo = false,
    conns = {}, daubs = 0, claims = 0, calls = 0,
    claimTries = {}, claimLast = {}, lastCall = 0, enabledAt = 0,
    patCache = nil, patTick = 0,
  }
  getgenv().__HUMA_BINGO = S

  --// remotes --------------------------------------------------------------
  local Remotes = ReplicatedStorage:WaitForChild("BingoRemotes", 15)
  if not Remotes then
    Notify("Bingo", "BingoRemotes not found — wrong place?", "error")
    return
  end
  local Daub         = Remotes:WaitForChild("Daub", 10)
  local ClaimBingo   = Remotes:WaitForChild("ClaimBingo", 10)
  local NumberCalled = Remotes:WaitForChild("NumberCalled", 10)
  local CardsAssigned = Remotes:WaitForChild("CardsAssigned", 10)
  local NetNotify = Remotes:FindFirstChild("Notify")
  if not (ClaimBingo and NumberCalled and CardsAssigned) then
    Notify("Bingo", "Missing remotes — wrong place?", "error")
    return
  end

  --// status UI (created first so logic can write into it) -----------------
  local autoSec = Tab:Section({ Name = "Auto" })
  local statSec = Tab:Section({ Name = "Status" })
  local statusLbl = statSec:Label("idle")
  local statsLbl = statSec:Label("daubs 0 · claims 0 · calls 0")

  local function refreshStats()
    pcall(function()
      statsLbl.Set(("daubs %d · claims %d · calls %d"):format(S.daubs, S.claims, S.calls))
    end)
  end

  local function setStatus(t)
    print("[huma-bingo] " .. tostring(t))
    pcall(function() statusLbl.Set(tostring(t)) end)
  end

  --// core: cards -----------------------------------------------------------
  -- Scoped STRICTLY to CardArea (RowX/SlotY/CardN): BingoGui holds hundreds
  -- of recycled C-cells outside the live cards — reading them pollutes grids
  -- and fires bogus daubs.
  local function cardArea()
    local pg = LP:FindFirstChild("PlayerGui")
    local bg = pg and pg:FindFirstChild("BingoGui")
    return bg and bg:FindFirstChild("CardArea")
  end

  local function cards()
    local out = {}
    local area = cardArea()
    if not area then return out end
    for _, cell in ipairs(area:GetDescendants()) do
      if cell.ClassName == "ImageButton" and cell.Name:match("^C%d_%d$") then
        local p, idx = cell.Parent, nil
        while p and p ~= area do
          local n = p.Name:match("^Card(%d+)$")
          if n then idx = tonumber(n) break end
          p = p.Parent
        end
        if idx then
          out[idx] = out[idx] or {}
          local c, r = cell.Name:match("^C(%d+)_(%d+)$")
          local num = nil
          local nl = cell:FindFirstChild("Number")
          if nl then num = tonumber(nl.Text) end
          local marked = (c == "3" and r == "3") -- free center
          local st = cell:FindFirstChild("Stamp")
          if st and st.Visible then marked = true end
          out[idx][c .. "_" .. r] = { col = tonumber(c), row = tonumber(r), num = num, marked = marked, ref = cell }
        end
      end
    end
    return out
  end

  local function gridMap(grid)
    local m = {}
    for _, v in pairs(grid) do
      m[v.row] = m[v.row] or {}
      m[v.row][v.col] = v.marked
    end
    return m
  end

  local function readPattern()
    if S.patCache and os.clock() - (S.patTick or 0) < 10 then return S.patCache end
    local pat = nil
    pcall(function()
      local pg = LP:FindFirstChild("PlayerGui")
      local bg = pg and pg:FindFirstChild("BingoGui")
      if bg then
        for _, v in ipairs(bg:GetDescendants()) do
          if v.Name == "PatternPreview" then
            local stroked, plain, total = {}, {}, 0
            for _, c in ipairs(v:GetChildren()) do
              local cc, rr = c.Name:match("^P(%d+)_(%d+)$")
              if cc and rr then
                total = total + 1
                local cell = { col = tonumber(cc), row = tonumber(rr) }
                if c:FindFirstChildOfClass("UIStroke") then stroked[#stroked + 1] = cell
                else plain[#plain + 1] = cell end
              end
            end
            if total > 0 then pat = { stroked = stroked, plain = plain } end
            break
          end
        end
      end
    end)
    S.patCache, S.patTick = pat, os.clock()
    return pat
  end

  local function covers(m, cells)
    if #cells == 0 or #cells > 24 then return false end
    for _, c in ipairs(cells) do
      if not (m[c.row] and m[c.row][c.col]) then return false end
    end
    return true
  end

  local function hasBingo(grid)
    local m = gridMap(grid)
    for i = 1, 5 do
      local row, col = true, true
      for j = 1, 5 do
        if not (m[i] and m[i][j]) then row = false end
        if not (m[j] and m[j][i]) then col = false end
      end
      if row or col then return true end
    end
    local d1, d2 = true, true
    for i = 1, 5 do
      if not (m[i] and m[i][i]) then d1 = false end
      if not (m[i] and m[i][6 - i]) then d2 = false end
    end
    if d1 or d2 then return true end
    if m[1] and m[5] and m[1][1] and m[1][5] and m[5][1] and m[5][5] then return true end
    local pat = readPattern()
    if pat and (covers(m, pat.stroked) or covers(m, pat.plain)) then return true end
    return false
  end

  local function readBalls()
    local out = {}
    local pg = LP:FindFirstChild("PlayerGui")
    local bg = pg and pg:FindFirstChild("BingoGui")
    if not bg then return out end
    for _, v in ipairs(bg:GetDescendants()) do
      if v.Name:match("^Ball_%a") then
        local num = nil
        for _, d in ipairs(v:GetDescendants()) do
          if d.ClassName == "TextLabel" and tonumber(d.Text) then num = tonumber(d.Text) break end
        end
        if not num then
          local digs = v.Name:match("^Ball_%a(%d+)$")
          if digs and #digs % 2 == 0 then num = tonumber(digs:sub(1, #digs / 2)) end
        end
        if num then out[num] = true end
      end
    end
    return out
  end

  local function cellStamp(idx, col, row)
    local okm = false
    pcall(function()
      local g = cards()[idx]
      if g then
        for _, c2 in pairs(g) do
          if c2.col == col and c2.row == row and c2.ref then
            local st = c2.ref:FindFirstChild("Stamp")
            if st and st.Visible then okm = true end
          end
        end
      end
    end)
    return okm
  end

  -- Fire the game's OWN cell handlers (they resolve the server card slot
  -- themselves — verified live: SlotN == visual CardN). Falls back to a
  -- direct Daub:FireServer(slot, col, row, true) with no connections.
  local function fireCellAll(idx, col, row, ref)
    local n = 0
    if ref then
      pcall(function()
        for _, cn in ipairs(getconnections(ref.Activated)) do
          pcall(function() cn:Fire() end)
          n = n + 1
        end
      end)
    end
    if n == 0 and Daub then
      if pcall(function() Daub:FireServer(idx, col, row, true) end) then n = 1 end
    end
    return n
  end

  local function fireCell(idx, col, row)
    local g = cards()[idx]
    if not g then return false end
    for _, c2 in pairs(g) do
      if c2.col == col and c2.row == row and c2.ref then
        return fireCellAll(idx, col, row, c2.ref) > 0
      end
    end
    return false
  end

  -- Claim with a retry budget (max 8 tries, ≥3s apart) instead of a
  -- permanent lock: the reconciler retries while the card is still winning.
  local function tryClaim(idx)
    local now = os.clock()
    local tries = S.claimTries[idx] or 0
    if tries >= 8 then return end
    if now - (S.claimLast[idx] or 0) < 3 then return end
    S.claimTries[idx] = tries + 1
    S.claimLast[idx] = now
    S.claims = S.claims + 1
    -- primary path: the game's own Bingo button (its handler picks the
    -- winning card itself — no arg guessing). Fallback: direct ClaimBingo.
    pcall(function()
      local pg = LP:FindFirstChild("PlayerGui")
      local bg = pg and pg:FindFirstChild("BingoGui")
      local btn = bg and bg:FindFirstChild("BingoButton")
      if btn then
        for _, cn in ipairs(getconnections(btn.Activated)) do
          pcall(function() cn:Fire() end)
        end
      end
    end)
    pcall(function() ClaimBingo:FireServer(idx) end)
    setStatus("claim sent, card " .. idx .. " (try " .. (tries + 1) .. ")")
    refreshStats()
  end

  local function claimPass()
    if not S.bingo then return end
    local fresh = cards()
    for idx, grid in pairs(fresh) do
      if hasBingo(grid) then tryClaim(idx) end
    end
  end

  -- One full pass: daub EVERY unmarked cell holding a called number on
  -- EVERY card (the old code fired a single cell per number — with 6 cards
  -- that silently skipped most of the board), then claims on a fresh read.
  local function sync(src)
    if not (S.marker or S.bingo) then return 0 end
    local balls = readBalls()
    local cs = cards()
    local fired, firedList = 0, {}
    if S.marker then
      for idx, grid in pairs(cs) do
        for _, cell in pairs(grid) do
          if cell.num and balls[cell.num] and not cell.marked and cell.ref then
            if fireCellAll(idx, cell.col, cell.row, cell.ref) > 0 then
              fired = fired + 1
              S.daubs = S.daubs + 1
              table.insert(firedList, { idx = idx, col = cell.col, row = cell.row, n = cell.num })
            end
          end
        end
      end
    end
    if fired > 0 then
      setStatus(src .. ": fired " .. fired .. " (total " .. S.daubs .. ")")
      refreshStats()
      -- async verify (server stamps with a delay): retry what is still blank
      task.spawn(function()
        for a = 1, 4 do
          task.wait(0.8)
          local pending = 0
          for _, f in ipairs(firedList) do
            if not cellStamp(f.idx, f.col, f.row) then
              pending = pending + 1
              local g = cards()[f.idx]
              if g then
                for _, c2 in pairs(g) do
                  if c2.col == f.col and c2.row == f.row and c2.ref then
                    fireCellAll(f.idx, f.col, f.row, c2.ref)
                    break
                  end
                end
              end
            end
          end
          if pending == 0 then
            setStatus(src .. ": all " .. #firedList .. " confirmed")
            break
          end
        end
      end)
    end
    claimPass()
    return fired
  end

  local function parseNumber(data)
    if type(data) == "number" then return data end
    if type(data) == "string" then
      local d = data:match("%d+")
      return d and tonumber(d) or nil
    end
    if type(data) == "table" then
      if tonumber(data.number) then return tonumber(data.number) end
      for _, v in pairs(data) do
        local n = tonumber(v)
        if not n and type(v) == "string" then
          local d = v:match("%d+")
          n = d and tonumber(d) or nil
        end
        if n and n >= 1 and n <= 75 then return n end
      end
    end
    return nil
  end

  local function catchUp()
    task.spawn(function()
      local total = sync("catchup")
      setStatus("catch-up: " .. total .. " marks (total " .. S.daubs .. ")")
      refreshStats()
    end)
  end

  --// events ---------------------------------------------------------------
  table.insert(S.conns, NumberCalled.OnClientEvent:Connect(function(data)
    S.calls = S.calls + 1
    S.lastCall = os.clock()
    local n = parseNumber(data)
    if not n then setStatus("saw malformed call #" .. S.calls) return end
    if not (S.marker or S.bingo) then setStatus("saw " .. n .. " (toggles off)") return end
    local hit = sync("live")
    if hit == 0 then
      setStatus("saw " .. n .. " (nothing new, calls " .. S.calls .. ")")
    end
    refreshStats()
  end))

  table.insert(S.conns, CardsAssigned.OnClientEvent:Connect(function()
    S.claimTries = {}
    S.claimLast = {}
    S.patCache = nil
    setStatus("new round — claims reset")
  end))

  if NetNotify then
    table.insert(S.conns, NetNotify.OnClientEvent:Connect(function(d)
      if type(d) == "table" and d.type then
        local t = tostring(d.type)
        if t:lower():find("claim", 1, true) then
          setStatus("server: " .. t)
          Notify("Bingo", t, "info")
        end
      end
    end))
  end

  --// anti-AFK + self-healing ticker --------------------------------------
  -- ticker: full sync every 2.5s catches anything events missed (late
  -- enable, manual completions, dropped packets, slow stamps). Gated by
  -- recent round activity; claim-only passes still run while quiet.
  task.spawn(function()
    while getgenv().__HUMA_BINGO == S do
      task.wait(2.5)
      if getgenv().__HUMA_BINGO ~= S then break end
      if S.marker or S.bingo then
        local quiet = os.clock() - (S.lastCall or 0) > 90
          and os.clock() - (S.enabledAt or 0) > 30
        pcall(function()
          if quiet then claimPass() else sync("tick") end
        end)
      end
    end
  end)
  task.spawn(function()
    while getgenv().__HUMA_BINGO == S do
      task.wait(60)
      if getgenv().__HUMA_BINGO ~= S then break end
      pcall(function()
        for _, c in ipairs(getconnections(LP.Idled)) do
          pcall(function() c:Disable() end)
        end
      end)
      pcall(function()
        local vim = game:GetService("VirtualInputManager")
        local cam = workspace.CurrentCamera
        local vs = (cam and cam.ViewportSize) or Vector2.new(800, 600)
        local x, y = vs.X / 2, vs.Y / 2
        vim:SendMouseMoveEvent(x + 40, y, game)
        task.wait(0.3)
        vim:SendKeyEvent(true, Enum.KeyCode.LeftShift, false, game)
        task.wait(0.2)
        vim:SendKeyEvent(false, Enum.KeyCode.LeftShift, false, game)
      end)
    end
  end)

  --// hub UI ----------------------------------------------------------------
  autoSec:Toggle({
    Name = "Auto Marker", Desc = "Marks called numbers with zero delay",
    Default = false, Tooltip = "On enable: marks everything already called",
    Callback = function(v)
      S.marker = v == true
      if S.marker then
        S.enabledAt = os.clock()
        Notify("Bingo", "Auto Marker running", "ok")
        catchUp()
      end
    end,
  })
  autoSec:Toggle({
    Name = "Auto Bingo", Desc = "Claims instantly on a winning pattern",
    Default = false, Callback = function(v)
      S.bingo = v == true
      if S.bingo then
        S.enabledAt = os.clock()
        Notify("Bingo", "Auto Bingo armed", "ok")
      end
    end,
  })

  statSec:Button({ Name = "Catch-up now", Variant = "ghost",
    Tooltip = "Mark all already-called numbers",
    Callback = catchUp })
  statSec:Button({ Name = "Rescan pattern", Variant = "ghost",
    Tooltip = "Re-read the PatternPreview (cache is 10s)",
    Callback = function()
      S.patCache = nil
      local pat = readPattern()
      if pat then
        setStatus(("pattern: stroked %d · plain %d"):format(#pat.stroked, #pat.plain))
      else
        setStatus("pattern: not found (open the pattern preview?)")
      end
    end })

  setStatus("module ready — enable Auto Marker / Bingo")
  refreshStats()
  print("[huma-bingo] place module loaded")
end
