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
    claimed = {}, claimCd = {},
    conns = {}, daubs = 0, claims = 0, calls = 0,
    patCache = nil, patTick = 0,
  }
  getgenv().__HUMA_BINGO = S

  --// remotes --------------------------------------------------------------
  local Remotes = ReplicatedStorage:WaitForChild("BingoRemotes", 15)
  if not Remotes then
    Notify("Bingo", "BingoRemotes not found — wrong place?", "error")
    return
  end
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
  local function cards()
    local out = {}
    local pg = LP:FindFirstChild("PlayerGui")
    if not pg then return out end
    local bg = pg:FindFirstChild("BingoGui")
    if not bg then return out end
    for _, cell in ipairs(bg:GetDescendants()) do
      if cell.ClassName == "ImageButton" and cell.Name:match("^C%d_%d$") then
        local p, idx = cell.Parent, nil
        while p and p ~= bg do
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

  local function fireCell(idx, col, row)
    local okf = false
    pcall(function()
      local g = cards()[idx]
      if g then
        for _, c2 in pairs(g) do
          if c2.col == col and c2.row == row and c2.ref then
            for _, cn in ipairs(getconnections(c2.ref.Activated)) do
              pcall(function() cn:Fire() end)
            end
            okf = true
          end
        end
      end
    end)
    return okf
  end

  local function tryClaim(idx)
    local now = os.clock()
    if S.claimed[idx] then return end
    if (S.claimCd[idx] or 0) + 5 > now then return end
    S.claimCd[idx] = now
    S.claimed[idx] = true
    S.claims = S.claims + 1
    pcall(function() ClaimBingo:FireServer(idx) end)
    setStatus("claim sent, card " .. idx)
    refreshStats()
  end

  local function daubNumber(n, src)
    local cs = cards()
    local hit = 0
    local firedAt = nil
    for idx, grid in pairs(cs) do
      for _, cell in pairs(grid) do
        if cell.num == n and not cell.marked then
          if S.marker and cell.ref and not firedAt then
            firedAt = { idx = idx, col = cell.col, row = cell.row }
            if fireCell(idx, cell.col, cell.row) then
              S.daubs = S.daubs + 1
              hit = 1
            end
          end
        end
      end
      if S.bingo and not S.claimed[idx] and hasBingo(grid) then
        tryClaim(idx)
      end
    end
    if firedAt then
      task.spawn(function()
        for a = 1, 4 do
          task.wait(0.8)
          if cellStamp(firedAt.idx, firedAt.col, firedAt.row) then
            setStatus("marked " .. n .. " OK (total " .. S.daubs .. ")")
            refreshStats()
            if S.bingo then
              local g = cards()[firedAt.idx]
              if g and hasBingo(g) then tryClaim(firedAt.idx) end
            end
            break
          else
            fireCell(firedAt.idx, firedAt.col, firedAt.row) -- retry
          end
        end
      end)
    end
    return hit
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
      local total = 0
      for n in pairs(readBalls()) do total = total + daubNumber(n, "catchup") end
      setStatus("catch-up: " .. total .. " marks (total " .. S.daubs .. ")")
      refreshStats()
    end)
  end

  --// events ---------------------------------------------------------------
  table.insert(S.conns, NumberCalled.OnClientEvent:Connect(function(data)
    S.calls = S.calls + 1
    local n = parseNumber(data)
    if not n then setStatus("saw malformed call #" .. S.calls) return end
    if not (S.marker or S.bingo) then setStatus("saw " .. n .. " (toggles off)") return end
    local hit = daubNumber(n, "live")
    if hit > 0 then
      setStatus("daubed " .. n .. " (total " .. S.daubs .. ")")
    else
      setStatus("saw " .. n .. " (no match, calls " .. S.calls .. ")")
    end
    refreshStats()
  end))

  table.insert(S.conns, CardsAssigned.OnClientEvent:Connect(function()
    S.claimed = {}
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

  --// anti-AFK (same approach as the standalone: input wiggle each 60s) -----
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
        Notify("Bingo", "Auto Marker running", "ok")
        catchUp()
      end
    end,
  })
  autoSec:Toggle({
    Name = "Auto Bingo", Desc = "Claims instantly on a winning pattern",
    Default = false, Callback = function(v)
      S.bingo = v == true
      if S.bingo then Notify("Bingo", "Auto Bingo armed", "ok") end
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
