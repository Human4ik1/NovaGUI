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
  local Hud = api.Shared and api.Shared.SetHud -- mini corner chip (may be nil on old hub)

  local function hud(key, text)
    if Hud then pcall(function() Hud(key, text) end) end
  end

  local Players = game:GetService("Players")
  local ReplicatedStorage = game:GetService("ReplicatedStorage")
  local LP = Players.LocalPlayer

  --// reload safety: kill previous copy's connections ---------------------
  local old = getgenv().__HUMA_BINGO
  if old then
    pcall(function() for _, c in ipairs(old.conns or {}) do c:Disconnect() end end)
  end
  local S = {
    marker = false, bingo = false, maxProfit = false, skipBox = true,
    conns = {}, daubs = 0, claims = 0, calls = 0,
    claimTries = {}, claimLast = {}, lastCall = 0, enabledAt = 0,
    seen = {}, -- union of every number observed since enable (event+panel)
    sentSig = {}, -- board signature at last claim attempt per card
    lastNumForced = false, -- last-number failsafe fires once per round
    rivalClaimed = false, stagePattern = nil, holdMsg = "",
    figCache = nil, figTick = 0,
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
  local OpenBoxEv = Remotes:FindFirstChild("OpenBox")
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
    -- window label only; the HUD chip keeps the static FIG line
    pcall(function()
      statsLbl.Set(("daubs %d · claims %d · calls %d"):format(S.daubs, S.claims, S.calls))
    end)
  end

  local function setStatus(t)
    -- window label only (noisy by design); HUD chip keeps FIG x/6
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

  -- FIGURE (the reliable method): the game draws the required shape in
  -- StatusPanel: GameTitle.Text is the figure NAME, and PatternPreview cells
  -- whose Ink child is Visible are the required CELLS (verified live with
  -- "Letter T": ink on row 1 + column 3, exactly the T). A win = our marks
  -- cover every ink cell. Works for any figure with zero hardcoded shapes.
  -- (UIStrokes on the preview are NOT the figure — they mark called numbers.)
  local function readFigure()
    if S.figCache and os.clock() - (S.figTick or 0) < 3 then return S.figCache end
    local fig = { name = "", cells = {} }
    pcall(function()
      local pg = LP:FindFirstChild("PlayerGui")
      local bg = pg and pg:FindFirstChild("BingoGui")
      if not bg then return end
      local sp = bg:FindFirstChild("StatusPanel")
      local gt = sp and sp:FindFirstChild("GameTitle")
      if gt then fig.name = tostring(gt.Text) end
      local prev = bg:FindFirstChild("PatternPreview", true)
      if prev then
        for _, c in ipairs(prev:GetChildren()) do
          local cc, rr = c.Name:match("^P(%d+)_(%d+)$")
          if cc and rr then
            for _, ch in ipairs(c:GetChildren()) do
              if ch.Name == "Ink" then
                local ok, vis = pcall(function() return ch.Visible end)
                if ok and vis then
                  table.insert(fig.cells, { col = tonumber(cc), row = tonumber(rr) })
                end
                break
              end
            end
          end
        end
      end
    end)
    S.figCache, S.figTick = fig, os.clock()
    return fig
  end

  local function hasBingo(grid, fig)
    local m = gridMap(grid)
    if fig and #fig.cells > 0 then
      -- figure mode: every required cell must be marked
      if #fig.cells > 25 then return false end
      for _, c in ipairs(fig.cells) do
        if not (m[c.row] and m[c.row][c.col]) then return false end
      end
      return true
    end
    -- fallback (figure unreadable): legacy lines
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

  -- Claim with a retry budget (max 8 tries, ≥3s apart). Budget resets every
  -- round AND every stage (new figure). `force` bypasses the caps — used for
  -- rival-claim and last-number failsafes (better something than nothing).
  -- `sig` records the exact board claimed, so the same stale board is never
  -- re-claimed (new stages keep old stamps — without this the bot spams
  -- claims for shapes that already lost/won).
  local function tryClaim(idx, force, sig)
    local now = os.clock()
    local tryNo
    if not force then
      local tries = S.claimTries[idx] or 0
      if tries >= 8 then return end
      if now - (S.claimLast[idx] or 0) < 3 then return end
      S.claimTries[idx] = tries + 1
      S.claimLast[idx] = now
      tryNo = tries + 1
    else
      S.claimLast[idx] = now
      tryNo = "FORCE"
    end
    if sig then S.sentSig[idx] = sig end
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
    setStatus("claim sent, card " .. idx .. " (try " .. tostring(tryNo) .. ")")
    refreshStats()
  end

  -- MAX PROFIT gate. OFF = claim every winning card ASAP (old behavior).
  -- ON = hold until EVERY owned card completes the figure, then claim all —
  -- except two failsafes that force an instant claim of whatever wins:
  --   1) rivalClaimed — someone else just claimed (RoundState ClaimWindow);
  --   2) lastNumber  — 74+ of 75 numbers are out, the game is about to end.
  local function gridSig(grid)
    local ks = {}
    for k, v in pairs(grid) do
      if v.marked then table.insert(ks, k) end
    end
    table.sort(ks)
    return table.concat(ks, ",")
  end

  -- Static HUD line: figure + figure-ready count. This is the important
  -- state — it never scrolls away, unlike the noisy window status.
  local function pushFigHud(fig, doneN, total)
    local name = (fig and fig.name ~= "") and fig.name or "?"
    hud("bingo", ("FIG %s · %d/%d"):format(name, doneN or 0, total or 0))
  end

  local function claimPass(force)
    local fig = readFigure()
    local fresh = cards()
    local winners, total = {}, 0
    for idx, grid in pairs(fresh) do
      total = total + 1
      if hasBingo(grid, fig) then table.insert(winners, { idx = idx, sig = gridSig(grid) }) end
    end
    pushFigHud(fig, #winners, total)
    if not S.bingo then return end
    if #winners == 0 then
      S.holdMsg = ""
      return
    end
    local calledN = 0
    for _ in pairs(S.seen) do calledN = calledN + 1 end
    local lastNumber = calledN >= 74
    local allWin = total > 0 and #winners >= total
    local go = (not S.maxProfit) or force or allWin or S.rivalClaimed or lastNumber
    if not go then
      local msg = ("holding %d/%d for max profit"):format(#winners, total)
      if S.holdMsg ~= msg then
        S.holdMsg = msg
        setStatus(msg)
      end
      return
    end
    local why = "single"
    local forceClaim = force == true
    -- last-number failsafe fires once (edge); afterwards normal sig-gating
    if lastNumber and not S.lastNumForced then
      S.lastNumForced = true
      forceClaim = true
    end
    if lastNumber then why = "LAST-NUMBER" end
    if S.rivalClaimed then why = "RIVAL" end
    if allWin then why = "ALL-WIN" end
    for _, w in ipairs(winners) do
      -- only fresh boards: skip what this exact board already claimed
      if forceClaim or S.sentSig[w.idx] ~= w.sig then
        tryClaim(w.idx, forceClaim or nil, w.sig)
      end
    end
    setStatus(("claiming %d/%d (%s)"):format(#winners, total, why))
  end

  -- FULL SWEEP: press EVERY unmarked cell on every card. Proven live that
  -- the game's own click handler silently ignores uncalled numbers WITHOUT
  -- sending any remote — so blanket-pressing costs traffic only for numbers
  -- that were really called, and needs no call history at all. Join mid-game
  -- with half the board unknown: one sweep still marks everything callable.
  -- Cells with known-called numbers are tracked for verify+retry.
  local function sync(src)
    if not (S.marker or S.bingo) then return 0 end
    local balls = readBalls()
    for n in pairs(balls) do S.seen[n] = true end
    local cs = cards()
    local pressed, known, firedList = 0, 0, {}
    if S.marker then
      for idx, grid in pairs(cs) do
        for _, cell in pairs(grid) do
          if cell.ref and not cell.marked then
            if fireCellAll(idx, cell.col, cell.row, cell.ref) > 0 then
              pressed = pressed + 1
              if cell.num and (balls[cell.num] or S.seen[cell.num]) then
                known = known + 1
                S.daubs = S.daubs + 1
                table.insert(firedList, { idx = idx, col = cell.col, row = cell.row, n = cell.num })
              end
            end
          end
        end
        task.wait(0.03) -- gentle pacing per card
      end
    end
    if pressed > 0 then
      setStatus(src .. ": swept " .. pressed .. " cells (" .. known .. " called, total " .. S.daubs .. ")")
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
    return pressed
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
      local total = sync("catchup") or 0
      setStatus("catch-up: swept " .. total .. " cells (total " .. S.daubs .. ")")
      refreshStats()
    end)
  end

  --// events ---------------------------------------------------------------
  table.insert(S.conns, NumberCalled.OnClientEvent:Connect(function(data)
    S.calls = S.calls + 1
    S.lastCall = os.clock()
    local n = parseNumber(data)
    if n then S.seen[n] = true end
    if not n then setStatus("saw malformed call #" .. S.calls) return end
    if not (S.marker or S.bingo) then setStatus("saw " .. n .. " (toggles off)") return end
    local hit = sync("live")
    if hit == 0 then
      setStatus("saw " .. n .. " (board clean, calls " .. S.calls .. ")")
    end
    refreshStats()
  end))

  table.insert(S.conns, CardsAssigned.OnClientEvent:Connect(function()
    S.claimTries = {}
    S.claimLast = {}
    S.seen = {}
    S.sentSig = {}
    S.lastNumForced = false
    S.rivalClaimed = false
    S.holdMsg = ""
    S.figCache = nil
    setStatus("new round — claims reset")
    task.spawn(function() pcall(function() sync("round") end) end)
  end))

  -- RoundState: rival-claim radar + per-stage budget reset.
  -- Seen live: Playing{pattern}, ClaimWindow{claimantName}, Claim{claimants},
  -- StageWinner{payouts,winnerNames}, Dance{...}. A round has 3 stages; each
  -- new figure gets a fresh claim budget.
  local RS = Remotes:FindFirstChild("RoundState")
  if RS then
    table.insert(S.conns, RS.OnClientEvent:Connect(function(d)
      if type(d) ~= "table" then return end
      local phase = d.phase
      if phase == "Playing" then
        local pat = d.pattern or d.patternLabel
        if pat and pat ~= S.stagePattern then
          S.stagePattern = tostring(pat)
          S.claimTries = {}
          S.claimLast = {}
          S.rivalClaimed = false
          S.holdMsg = ""
          -- NOTE: sentSig is NOT reset here on purpose: stamps persist
          -- across stages, and re-claiming the same stale board is exactly
          -- the stage-2 spam we killed. Only genuinely new marks re-arm.
          setStatus("stage figure: " .. S.stagePattern)
        end
      elseif phase == "ClaimWindow" then
        local cn = d.claimantName
        if cn and cn ~= "" and cn ~= LP.Name and S.bingo then
          S.rivalClaimed = true
          setStatus("rival claimed (" .. tostring(cn) .. ") — counter-claiming!")
          Notify("Bingo", "Rival claim by " .. tostring(cn) .. " — claiming now", "warn")
          claimPass(true)
        end
      elseif phase == "Claim" then
        local cls = d.claimants
        if type(cls) == "table" and S.bingo and not S.rivalClaimed then
          for _, c in pairs(cls) do
            local nm = (type(c) == "table") and (c.name or c[1]) or c
            nm = nm ~= nil and tostring(nm) or ""
            if nm ~= "" and nm ~= LP.Name and not nm:find("%.%.") then
              S.rivalClaimed = true
              setStatus("rival claim — counter-claiming!")
              Notify("Bingo", "Rival claim — claiming now", "warn")
              claimPass(true)
              break
            end
          end
        end
      end
    end))
  end

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

  -- CASE SKIP: the server sends the full item the instant a box is opened
  -- (name/rarity/isNew/seed) and the reel is pure cosmetics. Proven live that
  -- hiding BoxOpening changes nothing: opens and rewards flow 1:1 while the
  -- gui is off. So: hide the reel, surface the result instantly.
  -- NOTE: hiding once is not enough — the game re-shows the reel on every
  -- open *after* our event-hide runs. The heartbeat pin below re-hides it
  -- every frame while skip is on, so the animation can never be seen.
  local function applyBoxSkip()
    pcall(function()
      local pg = LP:FindFirstChild("PlayerGui")
      local bo = pg and pg:FindFirstChild("BoxOpening")
      if bo then bo.Enabled = not S.skipBox end
    end)
  end
  table.insert(S.conns, game:GetService("RunService").Heartbeat:Connect(function()
    if S.skipBox then applyBoxSkip() end
  end))
  if OpenBoxEv then
    table.insert(S.conns, OpenBoxEv.OnClientEvent:Connect(function(d)
      if type(d) ~= "table" or not S.skipBox then return end
      applyBoxSkip()
      local nm = tostring(d.name or "?")
      local rar = tostring(d.rarity or "?")
      local kind = tostring(d.kind or d.box or "item")
      kind = kind:sub(1, 1):upper() .. kind:sub(2)
      local isNew = d.isNew == true
      local rl = string.lower(rar)
      local sev = (rl == "legendary" or rl == "mythic" or rl == "epic") and "warn"
        or (rl == "rare" or rl == "uncommon") and "ok" or "info"
      Notify("Unboxed " .. kind, nm .. " · " .. rar .. (isNew and " · NEW!" or ""), sev)
      setStatus(("unboxed: %s · %s%s"):format(nm, rar, isNew and " · NEW!" or ""))
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
  autoSec:Toggle({
    Name = "Skip case animation", Desc = "Instant result, no unbox scroll",
    Default = true,
    Tooltip = "Hides the reel and shows the item immediately. Rewards unaffected (proven live: opens flow 1:1 while hidden).",
    Callback = function(v)
      S.skipBox = v == true
      applyBoxSkip()
      if S.skipBox then Notify("Bingo", "Case skip ON", "ok") end
    end,
  })
  autoSec:Toggle({
    Name = "Max Profit", Desc = "Hold the claim until ALL cards complete the figure",
    Default = false,
    Tooltip = "Waits for every owned card to win, then claims all at once (bigger payout). Two failsafes still claim early: a rival's claim, or 74+ of 75 numbers out.",
    Callback = function(v)
      S.maxProfit = v == true
      S.holdMsg = ""
      if S.maxProfit then
        Notify("Bingo", "Max Profit ON — holding for all cards", "ok")
      end
    end,
  })

  statSec:Button({ Name = "Catch-up now", Variant = "ghost",
    Tooltip = "Mark all already-called numbers",
    Callback = catchUp })
  statSec:Button({ Name = "Rescan figure", Variant = "ghost",
    Tooltip = "Re-read the required figure from StatusPanel (cache is 3s)",
    Callback = function()
      S.figCache = nil
      local fig = readFigure()
      if fig and #fig.cells > 0 then
        setStatus(("figure: %s · %d cells"):format(
          fig.name ~= "" and fig.name or "?", #fig.cells))
      else
        setStatus("figure: not found")
      end
    end })
  statSec:Button({ Name = "Hide / show cards", Variant = "ghost",
    Tooltip = "The game keeps running while cards are hidden — farm in your pocket",
    Callback = function()
      pcall(function()
        local pg = LP:FindFirstChild("PlayerGui")
        local bg = pg and pg:FindFirstChild("BingoGui")
        local btn = bg and bg:FindFirstChild("HideCardsButton")
        if btn then
          for _, cn in ipairs(getconnections(btn.Activated)) do
            pcall(function() cn:Fire() end)
          end
        end
      end)
    end })

  setStatus("module ready — enable Auto Marker / Bingo")
  refreshStats()
  applyBoxSkip()
  print("[huma-bingo] place module loaded")
end
