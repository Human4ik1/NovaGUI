--[[
  NovaUI v0.4.0 — single-file UI library for Roblox app interfaces.
  Zero dependencies, loadstring-ready, runs from Studio to live games.

  GitHub usage (pin a version tag, not main):
    local Nova = loadstring(game:HttpGet(
      "https://raw.githubusercontent.com/<USER>/NovaUI/v0.3.0/NovaUI.lua"))()

  Local use (as a ModuleScript, e.g. in Studio):
    local Nova = require(game.ReplicatedStorage.NovaUI)

  Quick start:
    local win = Nova:Window({ Title = "My app", Subtitle = "v1.0" })
    local tab = win:Tab({ Name = "General", Icon = "*" })
    local sec = tab:Section({ Name = "Features" })
    sec:Toggle({ Name = "Enabled", Flag = "feature_on", Callback = print })
    sec:Slider({ Name = "Volume", Min = 0, Max = 100, Default = 80, Flag = "volume" })
    -- read anywhere: Nova.Flags.feature_on, Nova.Flags.volume
    -- persist: Nova:Save("default") / Nova:Load("default")
    -- startup: Nova:LoadAuto() after core controls exist; late controls restore automatically.
    -- nested pages: tab:Navigation():Page({ Name = "Players", Icon = "□" }):Section(...)
    -- Save / Load select the startup profile. Save returns success and "disk" / "memory".

  Controls: Label, Paragraph, Divider, Space, Button, Toggle, Slider, Dropdown
            (single + multi), Segmented, Keybind, Color, TextBox, Progress.
            Sections are collapsible; every control takes an optional Tooltip.

  Windows: win:Tab / win:Notify / win:Dialog / win:SetVisible / win:SetScale /
           win:Unload. Windows are draggable and resizable.

  Theming: Nova:SetTheme("Dark" | "Mono" | "Midnight" | "Light" | customTable).
           Theme changes cross-fade every painted instance.

  Design notes (v0.3.0):
    - flat minimal surfaces, one accent, hairline borders, generous padding
    - Roblox font presets, monospaced numerals for values
    - popups (dropdown/color) live in a window overlay, so they never get
      clipped by a collapsed section or a scrolling page
]]
local Nova = {}
Nova.Version = "0.4.0"
Nova.Flags = {}      -- live values, keyed by Flag (or auto Name)
Nova._setters = {}   -- Flag -> function(value) applied on config load
Nova._paint = {}     -- { o = Instance, k = kind, t = token } repainted by SetTheme
Nova._wins = {}
Nova._aliases = {}
Nova._owners = {}
Nova._pendingSetters = {}
Nova._nilFlags = {}
Nova._refreshers = {}

--// Services ---------------------------------------------------------------
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local LocalPlayer = Players.LocalPlayer

--// Themes -----------------------------------------------------------------
-- Token set (v0.3.0): Bg, Surface, Elevated, Hover, Line, Text, Sub, Mute,
-- Accent, OnAccent, Good, Warn, Danger, Shadow.
Nova.Themes = {
  Dark = {
    Bg      = Color3.fromRGB(13, 13, 16),
    Surface = Color3.fromRGB(19, 19, 23),
    Elevated= Color3.fromRGB(27, 27, 33),
    Hover   = Color3.fromRGB(36, 36, 44),
    Line    = Color3.fromRGB(48, 48, 58),
    Text    = Color3.fromRGB(238, 238, 243),
    Sub     = Color3.fromRGB(154, 154, 166),
    Mute    = Color3.fromRGB(104, 104, 118),
    Accent  = Color3.fromRGB(122, 150, 255),
    OnAccent= Color3.fromRGB(10, 10, 14),
    Good    = Color3.fromRGB(96, 214, 150),
    Warn    = Color3.fromRGB(240, 190, 100),
    Danger  = Color3.fromRGB(246, 114, 128),
    Shadow  = Color3.fromRGB(0, 0, 0),
  },
  Mono = {
    Bg      = Color3.fromRGB(10, 10, 10),
    Surface = Color3.fromRGB(17, 17, 17),
    Elevated= Color3.fromRGB(26, 26, 26),
    Hover   = Color3.fromRGB(38, 38, 38),
    Line    = Color3.fromRGB(52, 52, 52),
    Text    = Color3.fromRGB(245, 245, 245),
    Sub     = Color3.fromRGB(150, 150, 150),
    Mute    = Color3.fromRGB(100, 100, 100),
    Accent  = Color3.fromRGB(240, 240, 240),
    OnAccent= Color3.fromRGB(12, 12, 12),
    Good    = Color3.fromRGB(120, 210, 150),
    Warn    = Color3.fromRGB(230, 190, 120),
    Danger  = Color3.fromRGB(235, 120, 130),
    Shadow  = Color3.fromRGB(0, 0, 0),
  },
  Midnight = {
    Bg      = Color3.fromRGB(8, 11, 20),
    Surface = Color3.fromRGB(13, 17, 29),
    Elevated= Color3.fromRGB(20, 26, 42),
    Hover   = Color3.fromRGB(28, 36, 56),
    Line    = Color3.fromRGB(38, 48, 72),
    Text    = Color3.fromRGB(226, 234, 248),
    Sub     = Color3.fromRGB(140, 154, 182),
    Mute    = Color3.fromRGB(96, 110, 140),
    Accent  = Color3.fromRGB(88, 202, 255),
    OnAccent= Color3.fromRGB(6, 14, 24),
    Good    = Color3.fromRGB(86, 220, 168),
    Warn    = Color3.fromRGB(246, 196, 108),
    Danger  = Color3.fromRGB(255, 118, 138),
    Shadow  = Color3.fromRGB(0, 0, 0),
  },
  Light = {
    Bg      = Color3.fromRGB(247, 247, 249),
    Surface = Color3.fromRGB(255, 255, 255),
    Elevated= Color3.fromRGB(242, 242, 246),
    Hover   = Color3.fromRGB(232, 232, 238),
    Line    = Color3.fromRGB(219, 219, 227),
    Text    = Color3.fromRGB(24, 24, 30),
    Sub     = Color3.fromRGB(104, 104, 118),
    Mute    = Color3.fromRGB(146, 146, 160),
    Accent  = Color3.fromRGB(72, 96, 232),
    OnAccent= Color3.fromRGB(255, 255, 255),
    Good    = Color3.fromRGB(32, 160, 96),
    Warn    = Color3.fromRGB(190, 130, 20),
    Danger  = Color3.fromRGB(216, 64, 88),
    Shadow  = Color3.fromRGB(120, 124, 140),
  },
}
-- v0.2.x token names still work in custom theme tables.
local ALIAS = { Bg2 = "Surface", Row = "Elevated", Dim = "Sub", Accent2 = "Accent" }

Nova.ThemeName = "Dark"
Nova.Theme = {}
for k, v in pairs(Nova.Themes.Dark) do Nova.Theme[k] = v end

--// Type ramp --------------------------------------------------------------
-- Use Roblox font presets instead of assuming a font-family file is installed.
-- FontFace assignment can succeed before an asset fails asynchronously, so
-- pcall around Font.new/FontFace cannot provide the promised fallback.
local Fonts = {
  Regular = Enum.Font.Gotham, Medium = Enum.Font.GothamMedium,
  SemiBold = Enum.Font.GothamBold, Bold = Enum.Font.GothamBold,
  Mono = Enum.Font.Code,
}
local function setFont(o, weight)
  pcall(function() o.Font = Fonts[weight or "Medium"] or Fonts.Medium end)
  return o
end

--// Motion ----------------------------------------------------------------
-- One vocabulary of durations/curves so everything moves like one product.
local M = {
  micro = { 0.11, "Quad", "Out" },   -- hover, press, colour nudges
  base  = { 0.20, "Quint", "Out" },  -- most state changes
  slow  = { 0.34, "Quint", "Out" },  -- panels, theme cross-fade
  pop   = { 0.40, "Back", "Out" },   -- entrances, knobs
  exit  = { 0.15, "Quad", "In" },    -- anything leaving the screen
}
local function Tween(o, props, m)
  m = m or M.base
  local tw = TweenService:Create(o,
    TweenInfo.new(m[1], Enum.EasingStyle[m[2]], Enum.EasingDirection[m[3]]), props)
  tw:Play()
  return tw
end

--// Small helpers ----------------------------------------------------------
local function clamp(v, a, b)
  if v < a then return a elseif v > b then return b end
  return v
end
local function round(v, d)
  local m = 10 ^ (d or 0)
  return math.floor(v * m + 0.5) / m
end
local _flagN = 0
local function autoFlag(name)
  _flagN = _flagN + 1
  return (name or "opt") .. "_" .. _flagN
end
local function New(class, props, parent)
  local o = Instance.new(class)
  if props then
    for k, v in pairs(props) do
      if k ~= "Parent" then
        local ok, err = pcall(function() o[k] = v end)
        if not ok then warn("[NovaUI] bad prop " .. tostring(k) .. ": " .. tostring(err)) end
      end
    end
  end
  if parent ~= nil then o.Parent = parent
  elseif props and props.Parent ~= nil then o.Parent = props.Parent end
  return o
end
local function Corner(p, r) return New("UICorner", { CornerRadius = UDim.new(0, r or 10) }, p) end
local function Pad(p, l, t, r, b)
  t = t or l or 0; r = r or l or 0; b = b or t or 0; l = l or 0
  return New("UIPadding", {
    PaddingLeft = UDim.new(0, l), PaddingTop = UDim.new(0, t),
    PaddingRight = UDim.new(0, r), PaddingBottom = UDim.new(0, b),
  }, p)
end
local function List(p, pad, dir)
  return New("UIListLayout", {
    Padding = UDim.new(0, pad or 8),
    FillDirection = dir or Enum.FillDirection.Vertical,
    SortOrder = Enum.SortOrder.LayoutOrder,
    HorizontalAlignment = Enum.HorizontalAlignment.Left,
    VerticalAlignment = Enum.VerticalAlignment.Top,
  }, p)
end

--// Theme painting ---------------------------------------------------------
-- kind: bg | fg | stroke | img | ph (placeholder) | scroll | grad
local function Paint(o, kind, token, token2)
  table.insert(Nova._paint, { o = o, k = kind, t = token, t2 = token2 })
  return o
end
local PAINT_PROP = {
  bg = "BackgroundColor3", fg = "TextColor3", stroke = "Color",
  img = "ImageColor3", ph = "PlaceholderColor3", scroll = "ScrollBarImageColor3",
}
local function applyPaint(e, anim)
  local T, o = Nova.Theme, e.o
  if not o or not o.Parent then return false end
  if e.k == "grad" then
    pcall(function() o.Color = ColorSequence.new(T[e.t] or T.Accent, T[e.t2] or T[e.t] or T.Accent) end)
    return true
  end
  local prop, c = PAINT_PROP[e.k], T[e.t]
  if not prop or not c then return true end
  pcall(function()
    if anim then Tween(o, { [prop] = c }, M.slow) else o[prop] = c end
  end)
  return true
end
local function Stroke(p, token, t, tr)
  local s = New("UIStroke", {
    Color = Nova.Theme[token or "Line"], Thickness = t or 1,
    Transparency = tr == nil and 0.4 or tr,
    ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
  }, p)
  Paint(s, "stroke", token or "Line")
  return s
end
function Nova:SetTheme(nameOrTable)
  local t = type(nameOrTable) == "string" and Nova.Themes[nameOrTable] or nameOrTable
  if type(t) ~= "table" then return false end
  if type(nameOrTable) == "string" then
    Nova.ThemeName = nameOrTable
    if Nova._loaded and not Nova._applying then Nova._loaded.__theme = nameOrTable end
  end
  for k, v in pairs(t) do
    Nova.Theme[ALIAS[k] or k] = v
  end
  local alive = {}
  for _, e in ipairs(Nova._paint) do
    if applyPaint(e, true) then table.insert(alive, e) end
  end
  Nova._paint = alive   -- drop entries whose instances are gone
  for obj, refresh in pairs(Nova._refreshers) do
    if obj.Parent then refresh() else Nova._refreshers[obj] = nil end
  end
  if Nova._themeControl and type(nameOrTable) == "string" then
    Nova._themeControl.Set(nameOrTable, true)
  end
  return true
end
function Nova:BindTheme(control)
  Nova._themeControl = control
  control.Set(Nova.ThemeName, true)
end
function Nova:NextTheme()
  local order = { "Dark", "Mono", "Midnight", "Light" }
  local i = 1
  for n, name in ipairs(order) do if name == Nova.ThemeName then i = n end end
  Nova:SetTheme(order[(i % #order) + 1])
  return Nova.ThemeName
end

--// Text -------------------------------------------------------------------
-- o.size, o.w (weight), o.token, o.xa, o.sz, o.truncate
local function Txt(parent, text, o)
  o = o or {}
  local l = New("TextLabel", {
    Text = text or "", TextSize = o.size or 13,
    TextColor3 = Nova.Theme[o.token or "Text"],
    TextXAlignment = o.xa or Enum.TextXAlignment.Left,
    TextYAlignment = o.ya or Enum.TextYAlignment.Center,
    TextTruncate = o.truncate and Enum.TextTruncate.AtEnd or Enum.TextTruncate.None,
    BackgroundTransparency = 1, Size = o.sz or UDim2.fromScale(1, 1),
  }, parent)
  setFont(l, o.w or "Medium")
  Paint(l, "fg", o.token or "Text")
  return l
end

--// Interaction sugar ------------------------------------------------------
local function Ripple(btn, token)
  btn.ClipsDescendants = true
  btn.MouseButton1Down:Connect(function(x, y)
    local d = math.max(btn.AbsoluteSize.X, btn.AbsoluteSize.Y) * 2.1
    local c = New("Frame", {
      BackgroundColor3 = Nova.Theme[token or "Text"], BackgroundTransparency = 0.86,
      BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5),
      Size = UDim2.fromOffset(0, 0), ZIndex = btn.ZIndex + 1,
      Position = UDim2.fromOffset(x - btn.AbsolutePosition.X, y - btn.AbsolutePosition.Y),
    }, btn)
    Corner(c, 999)
    Tween(c, { Size = UDim2.fromOffset(d, d), BackgroundTransparency = 1 }, { 0.5, "Quint", "Out" })
    task.delay(0.55, function() c:Destroy() end)
  end)
end
-- Window drag with zero grab-shift by construction. On grab we snapshot the
-- frame's own Position components (scale + offset) and the pointer. While the
-- pointer moves we apply ONLY its delta to that snapshot and write it back
-- with the SAME scale components — at grab instant the delta is 0, so the
-- rewritten Position is bit-identical to the old one: teleport is impossible.
-- We deliberately never read AbsolutePosition here: it disagrees with the
-- Position math by the topbar inset under IgnoreGuiInset, which used to kick
-- the window on the first move. Delta is divided by the window zoom so
-- movement stays 1:1 at any UI scale.
local function Drag(frame, handle, zoom, onStart, onEnd)
  local active, tObj = false, nil
  local sx, sy = 0, 0
  local gsx, gsy, gox, goy, gax, gay = 0.5, 0.5, 0, 0, 0, 0
  local function z()
    if type(zoom) == "function" then
      local v = zoom()
      if type(v) == "number" and v > 0 then return v end
    end
    return 1
  end
  local c1 = handle.InputBegan:Connect(function(inp)
    local t = inp.UserInputType
    if t ~= Enum.UserInputType.MouseButton1 and t ~= Enum.UserInputType.Touch then return end
    if active then return end
    active, tObj = true, (t == Enum.UserInputType.Touch) and inp or nil
    sx, sy = inp.Position.X, inp.Position.Y
    local gp = frame.Position
    gsx, gsy, gox, goy = gp.X.Scale, gp.Y.Scale, gp.X.Offset, gp.Y.Offset
    gax, gay = frame.AnchorPoint.X, frame.AnchorPoint.Y
    if onStart then onStart() end
  end)
  local c2 = UserInputService.InputChanged:Connect(function(inp)
    if not active then return end
    local t = inp.UserInputType
    local isMove = (t == Enum.UserInputType.MouseMovement and tObj == nil)
      or (t == Enum.UserInputType.Touch and inp == tObj)
    if not isMove then return end
    local s = z()
    local vp = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize or Vector2.new(1280, 720)
    local vw, vh = vp.X / s, vp.Y / s
    local w, h = frame.AbsoluteSize.X / s, frame.AbsoluteSize.Y / s
    -- absolute grab corner in layout units, derived from the snapshotted
    -- Position AND AnchorPoint (never from AbsolutePosition, see above)
    local baseX = gsx * vw + gox - gax * w
    local baseY = gsy * vh + goy - gay * h
    -- clamp the corner: window travels anywhere while keeping a 90px
    -- horizontal / 44px top grab strip on screen
    local nx = clamp(baseX + (inp.Position.X - sx) / s, -w + 90, vw - 90)
    local ny = clamp(baseY + (inp.Position.Y - sy) / s, 0, vh - 44)
    frame.Position = UDim2.new(gsx, nx + gax * w - gsx * vw,
      gsy, ny + gay * h - gsy * vh)
  end)
  local c3 = UserInputService.InputEnded:Connect(function(inp)
    if not active then return end
    local t = inp.UserInputType
    if (t == Enum.UserInputType.MouseButton1 and tObj == nil)
      or (t == Enum.UserInputType.Touch and inp == tObj) then
      active, tObj = false, nil
      if onEnd then onEnd() end
    end
  end)
  return { c1, c2, c3 }
end
local function inRect(obj, pos)
  local p, s = obj.AbsolutePosition, obj.AbsoluteSize
  return pos.X >= p.X and pos.X <= p.X + s.X and pos.Y >= p.Y and pos.Y <= p.Y + s.Y
end

local function mountGui(name)
  -- host-provided UI root when available (keeps the UI out of the way),
  -- otherwise the local PlayerGui. Everything is capability-checked.
  local sg = New("ScreenGui", {
    Name = name, ResetOnSpawn = false, IgnoreGuiInset = true,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling, DisplayOrder = 50,
  })
  local done = false
  pcall(function()
    if gethui then
      local h = gethui()
      if h then sg.Parent = h; done = true end
    end
  end)
  pcall(function()
    if syn and syn.protect_gui then syn.protect_gui(sg) end
  end)
  if not done or not sg.Parent then
    local pl = LocalPlayer or Players.PlayerAdded:Wait()
    sg.Parent = pl:WaitForChild("PlayerGui")
  end
  return sg
end

--// Notify -----------------------------------------------------------------
local _notifHolder, _notifN = nil, 0
local function notifHolder(sg)
  if _notifHolder and _notifHolder.Parent then return _notifHolder end
  _notifHolder = New("Frame", {
    Name = "Notifications", BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0),
    Position = UDim2.new(1, -18, 0, 18), Size = UDim2.new(0, 296, 1, -36), ZIndex = 90,
  }, sg)
  return _notifHolder
end
local function restackNotifs(h)
  local rest = {}
  for _, ch in ipairs(h:GetChildren()) do
    if ch:IsA("GuiObject") then table.insert(rest, ch) end
  end
  table.sort(rest, function(a, b) return a.LayoutOrder < b.LayoutOrder end)
  local y = 0
  for _, ch in ipairs(rest) do
    Tween(ch, { Position = UDim2.new(0, ch.Position.X.Offset, 0, y) }, M.base)
    y = y + ch.AbsoluteSize.Y + 8
  end
end
function Nova:Notify(opts)
  opts = opts or {}
  local sg = (Nova._wins[1] and Nova._wins[1]._sg) or mountGui("NovaUI_Notify")
  local h = notifHolder(sg)
  local T = Nova.Theme
  local accentTok = ({ info = "Accent", ok = "Good", warn = "Warn", error = "Danger" })[opts.Type] or "Accent"
  local dur = opts.Duration or 4

  local card = New("CanvasGroup", {
    BackgroundColor3 = T.Surface, BorderSizePixel = 0, GroupTransparency = 1,
    Size = UDim2.new(1, 0, 0, opts.Text and 62 or 44), ZIndex = 90,
  }, h)
  Paint(card, "bg", "Surface"); Corner(card, 12); Stroke(card, "Line", 1, 0.35)
  _notifN = _notifN + 1
  card.LayoutOrder = _notifN

  local stackY = 0
  for _, ch in ipairs(h:GetChildren()) do
    if ch:IsA("GuiObject") and ch ~= card then stackY = stackY + ch.AbsoluteSize.Y + 8 end
  end

  local dot = New("Frame", {
    BackgroundColor3 = T[accentTok], BorderSizePixel = 0,
    Size = UDim2.fromOffset(6, 6), Position = UDim2.new(0, 16, 0, 19),
  }, card)
  Paint(dot, "bg", accentTok); Corner(dot, 3)

  local tt = Txt(card, opts.Title or "Nova", { size = 13, w = "SemiBold", truncate = true,
    sz = UDim2.new(1, -46, 0, 18) })
  tt.Position = UDim2.new(0, 30, 0, opts.Text and 11 or 13)
  if opts.Text then
    local bt = Txt(card, opts.Text, { size = 12, token = "Sub", sz = UDim2.new(1, -46, 0, 30) })
    bt.Position = UDim2.new(0, 30, 0, 28)
    bt.TextWrapped = true
    bt.TextYAlignment = Enum.TextYAlignment.Top
  end

  -- life bar: reads as time left without adding a countdown label
  local bar = New("Frame", {
    BackgroundColor3 = T[accentTok], BorderSizePixel = 0, BackgroundTransparency = 0.35,
    Size = UDim2.new(1, 0, 0, 2), Position = UDim2.new(0, 0, 1, -2), AnchorPoint = Vector2.new(0, 0),
  }, card)
  Paint(bar, "bg", accentTok)
  Tween(bar, { Size = UDim2.new(0, 0, 0, 2) }, { dur, "Linear", "Out" })

  card.Position = UDim2.new(0, 40, 0, stackY)
  Tween(card, { Position = UDim2.new(0, 0, 0, stackY), GroupTransparency = 0 }, M.pop)

  local closed = false
  local function close()
    if closed then return end
    closed = true
    Tween(card, { Position = UDim2.new(0, 60, 0, card.Position.Y.Offset), GroupTransparency = 1 }, M.exit)
    task.delay(0.18, function()
      pcall(function() card:Destroy() end)
      if h.Parent then restackNotifs(h) end
    end)
  end
  card.InputBegan:Connect(function(inp)
    if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
      if opts.Callback then pcall(opts.Callback) end
      close()
    end
  end)
  task.delay(dur, close)
  return { Close = close }
end

--// Control plumbing -------------------------------------------------------
local function fire(flag, cb, v)
  Nova.Flags[flag] = v
  Nova._nilFlags[flag] = v == nil or nil
  if cb then
    local ok, err = pcall(cb, v)
    if not ok then
      warn("[NovaUI] callback: " .. tostring(err))
      if Nova._applying then error(err, 0) end
    end
  end
end
local function regSetter(flag, fn, ctx)
  Nova._setters[flag] = fn
  Nova._owners[flag] = ctx
  Nova._pendingSetters[flag] = fn
  task.defer(function()
    if Nova._pendingSetters[flag] == fn then Nova:ApplyPending() end
  end)
end

-- Shared label/description/right-slot row. Clickable rows get hover + press.
local function Row(parent, opt, clickable, rightPad)
  local T = Nova.Theme
  local hgt = opt.Height or (opt.Desc and 54 or 40)
  local props = { BackgroundColor3 = T.Elevated, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, hgt) }
  if clickable then props.Text = "" ; props.AutoButtonColor = false end
  local row = New(clickable and "TextButton" or "Frame", props, parent)
  Paint(row, "bg", "Elevated"); Corner(row, 10)
  local name = Txt(row, opt.Name or "", { size = 13, truncate = true,
    sz = UDim2.new(1, -(rightPad or 80), 0, 18) })
  name.Position = UDim2.new(0, 14, 0, opt.Desc and 9 or (hgt - 18) / 2)
  if opt.Desc then
    local d = Txt(row, opt.Desc, { size = 11, token = "Sub", truncate = true,
      sz = UDim2.new(1, -(rightPad or 80), 0, 16) })
    d.Position = UDim2.new(0, 14, 0, 29)
  end
  if clickable then
    row.MouseEnter:Connect(function() Tween(row, { BackgroundColor3 = Nova.Theme.Hover }, M.micro) end)
    row.MouseLeave:Connect(function() Tween(row, { BackgroundColor3 = Nova.Theme.Elevated }, M.micro) end)
  end
  return row, name
end

--// Controls ---------------------------------------------------------------
local function addLabel(parent, text, opt)
  opt = opt or {}
  local l = Txt(parent, text, {
    size = opt.size or 13, token = opt.token or "Text", w = opt.w or "Medium",
    sz = UDim2.new(1, 0, 0, 0),
  })
  l.TextWrapped = true
  l.TextYAlignment = Enum.TextYAlignment.Top
  l.AutomaticSize = Enum.AutomaticSize.Y
  local h = {}
  function h.Set(t) l.Text = tostring(t) end
  function h.Get() return l.Text end
  h.Instance = l
  return h
end
local function addDivider(parent)
  local wrap = New("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 9) }, parent)
  local d = New("Frame", {
    BackgroundColor3 = Nova.Theme.Line, BorderSizePixel = 0, BackgroundTransparency = 0.3,
    Size = UDim2.new(1, 0, 0, 1), Position = UDim2.new(0, 0, 0.5, 0),
  }, wrap)
  Paint(d, "bg", "Line")
  return { Instance = wrap }
end
local function addSpace(parent, h)
  return { Instance = New("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, h or 4) }, parent) }
end

local function addButton(parent, opt, ctx)
  local T = Nova.Theme
  local variant = opt.Variant or "primary"   -- primary | ghost | danger
  local fillTok = variant == "ghost" and "Elevated" or (variant == "danger" and "Danger" or "Accent")
  local textTok = variant == "ghost" and "Text" or (variant == "danger" and "Text" or "OnAccent")
  local b = New("TextButton", {
    Text = "", AutoButtonColor = false, BorderSizePixel = 0,
    BackgroundColor3 = T[fillTok], Size = UDim2.new(1, 0, 0, 38),
  }, parent)
  Paint(b, "bg", fillTok); Corner(b, 10)
  if variant == "ghost" then Stroke(b, "Line", 1, 0.4) end
  local sc = New("UIScale", { Scale = 1 }, b)
  local l = Txt(b, opt.Name or "Button", { size = 13, w = "SemiBold", token = textTok,
    xa = Enum.TextXAlignment.Center })
  b.MouseEnter:Connect(function()
    Tween(b, { BackgroundColor3 = variant == "ghost" and Nova.Theme.Hover or Nova.Theme[fillTok] }, M.micro)
    Tween(sc, { Scale = 1.012 }, M.micro)
  end)
  b.MouseLeave:Connect(function()
    Tween(b, { BackgroundColor3 = Nova.Theme[fillTok] }, M.micro)
    Tween(sc, { Scale = 1 }, M.micro)
  end)
  b.MouseButton1Down:Connect(function() Tween(sc, { Scale = 0.975 }, M.micro) end)
  b.MouseButton1Up:Connect(function() Tween(sc, { Scale = 1 }, M.pop) end)
  Ripple(b, variant == "ghost" and "Text" or "OnAccent")
  b.MouseButton1Click:Connect(function()
    if opt.Callback then
      local ok, err = pcall(opt.Callback)
      if not ok then warn("[NovaUI] button: " .. tostring(err)) end
    end
  end)
  if ctx then ctx.tip(b, opt.Tooltip) end
  local h = { Instance = b }
  function h.SetText(t) l.Text = tostring(t) end
  return h
end

local function addToggle(parent, opt, ctx)
  local T = Nova.Theme
  local flag = opt.Flag or autoFlag(opt.Name)
  local val = opt.Default == true
  local row = Row(parent, opt, true, 80)
  local track = New("Frame", {
    BackgroundColor3 = T.Line, BorderSizePixel = 0,
    AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -14, 0.5, 0),
    Size = UDim2.fromOffset(40, 22),
  }, row)
  Corner(track, 11)
  local knob = New("Frame", {
    BackgroundColor3 = T.Text, BorderSizePixel = 0,
    AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 3, 0.5, 0),
    Size = UDim2.fromOffset(16, 16),
  }, track)
  Corner(knob, 8)
  local h = { Instance = row }
  function h.Set(v, silent)
    val = v == true
    local Tn = Nova.Theme
    Tween(track, { BackgroundColor3 = val and Tn.Accent or Tn.Line }, M.base)
    Tween(knob, {
      Position = UDim2.new(0, val and 21 or 3, 0.5, 0),
      BackgroundColor3 = val and Tn.OnAccent or Tn.Sub,
    }, M.pop)
    Nova.Flags[flag] = val
    Nova._nilFlags[flag] = val == nil or nil
    if not silent then fire(flag, opt.Callback, val) end
  end
  function h.Get() return val end
  row.MouseButton1Click:Connect(function() h.Set(not val) end)
  if ctx then ctx.tip(row, opt.Tooltip) end
  regSetter(flag, function(v) h.Set(v == true, false) end, ctx)
  h.Set(val, true); Nova.Flags[flag] = val
  return h
end

local function addSlider(parent, opt, ctx)
  local T = Nova.Theme
  local flag = opt.Flag or autoFlag(opt.Name)
  local min, max = opt.Min or 0, opt.Max or 100
  local dec = opt.Decimals or 0
  local step = opt.Step
  local val = clamp(opt.Default == nil and min or opt.Default, min, max)
  local wrap = New("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 50) }, parent)
  local tt = Txt(wrap, opt.Name or "Slider", { size = 13, sz = UDim2.new(1, -80, 0, 18) })
  tt.Position = UDim2.new(0, 2, 0, 0)
  local vv = Txt(wrap, "", { size = 12, w = "Mono", token = "Sub",
    xa = Enum.TextXAlignment.Right, sz = UDim2.new(0, 78, 0, 18) })
  vv.Position = UDim2.new(1, -78, 0, 0)

  local track = New("TextButton", {
    Text = "", AutoButtonColor = false, BorderSizePixel = 0,
    BackgroundColor3 = T.Line, Size = UDim2.new(1, -4, 0, 4),
    Position = UDim2.new(0, 2, 0, 32),
  }, wrap)
  Paint(track, "bg", "Line"); Corner(track, 2)
  local fill = New("Frame", {
    BackgroundColor3 = T.Accent, BorderSizePixel = 0, Size = UDim2.fromScale(0, 1),
  }, track)
  Paint(fill, "bg", "Accent"); Corner(fill, 2)
  local knob = New("Frame", {
    BackgroundColor3 = T.Accent, BorderSizePixel = 0,
    AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(12, 12),
    Position = UDim2.fromScale(0, 0.5), ZIndex = 2,
  }, track)
  Paint(knob, "bg", "Accent"); Corner(knob, 6)
  -- generous invisible hit area: a 4px track is pretty, not clickable
  local hit = New("TextButton", {
    Text = "", BackgroundTransparency = 1, BorderSizePixel = 0,
    Size = UDim2.new(1, 0, 0, 26), Position = UDim2.new(0, 0, 0, 22),
  }, wrap)

  local h = { Instance = wrap }
  function h.Set(v, silent)
    v = tonumber(v) or min
    if step and step > 0 then v = min + round((v - min) / step, 0) * step end
    val = clamp(round(v, dec), min, max)
    local r = (max == min) and 0 or ((val - min) / (max - min))
    Tween(fill, { Size = UDim2.fromScale(r, 1) }, M.micro)
    Tween(knob, { Position = UDim2.new(r, 0, 0.5, 0) }, M.micro)
    vv.Text = tostring(val) .. (opt.Suffix or "")
    Nova.Flags[flag] = val
    Nova._nilFlags[flag] = val == nil or nil
    if not silent then fire(flag, opt.Callback, val) end
  end
  function h.Get() return val end

  local dragging = false
  local function fromX(x)
    local p, s = track.AbsolutePosition.X, track.AbsoluteSize.X
    if s <= 0 then return end
    h.Set(min + clamp((x - p) / s, 0, 1) * (max - min))
  end
  local function grab(on)
    Tween(knob, { Size = UDim2.fromOffset(on and 18 or 12, on and 18 or 12) }, M.pop)
    Tween(track, { Size = UDim2.new(1, -4, 0, on and 6 or 4) }, M.base)
    Tween(vv, { TextColor3 = Nova.Theme[on and "Text" or "Sub"] }, M.micro)
  end
  hit.InputBegan:Connect(function(inp)
    if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
      dragging = true; grab(true); fromX(inp.Position.X)
    end
  end)
  hit.MouseEnter:Connect(function() if not dragging then Tween(knob, { Size = UDim2.fromOffset(15, 15) }, M.micro) end end)
  hit.MouseLeave:Connect(function() if not dragging then Tween(knob, { Size = UDim2.fromOffset(12, 12) }, M.micro) end end)
  ctx.bind(UserInputService.InputChanged:Connect(function(inp)
    if dragging and (inp.UserInputType == Enum.UserInputType.MouseMovement or inp.UserInputType == Enum.UserInputType.Touch) then
      fromX(inp.Position.X)
    end
  end))
  ctx.bind(UserInputService.InputEnded:Connect(function(inp)
    if dragging and (inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch) then
      dragging = false; grab(false)
    end
  end))
  ctx.tip(wrap, opt.Tooltip)
  regSetter(flag, function(v) h.Set(tonumber(v) or min, false) end, ctx)
  h.Set(val, true); Nova.Flags[flag] = val
  return h
end

local function addProgress(parent, opt)
  local T = Nova.Theme
  local wrap = New("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 42) }, parent)
  local tt = Txt(wrap, opt.Name or "Progress", { size = 13, sz = UDim2.new(1, -60, 0, 18) })
  tt.Position = UDim2.new(0, 2, 0, 0)
  local pc = Txt(wrap, "0%", { size = 12, w = "Mono", token = "Sub",
    xa = Enum.TextXAlignment.Right, sz = UDim2.new(0, 58, 0, 18) })
  pc.Position = UDim2.new(1, -58, 0, 0)
  local track = New("Frame", {
    BackgroundColor3 = T.Line, BorderSizePixel = 0,
    Size = UDim2.new(1, -4, 0, 6), Position = UDim2.new(0, 2, 0, 28),
  }, wrap)
  Paint(track, "bg", "Line"); Corner(track, 3)
  local fill = New("Frame", {
    BackgroundColor3 = T[opt.Token or "Accent"], BorderSizePixel = 0, Size = UDim2.fromScale(0, 1),
  }, track)
  Paint(fill, "bg", opt.Token or "Accent"); Corner(fill, 3)
  local v = 0
  local h = { Instance = wrap }
  function h.Set(x)
    v = clamp(tonumber(x) or 0, 0, 1)
    Tween(fill, { Size = UDim2.fromScale(v, 1) }, M.slow)
    pc.Text = tostring(math.floor(v * 100 + 0.5)) .. "%"
  end
  function h.Get() return v end
  h.Set(opt.Default or 0)
  return h
end

local function addSegmented(parent, opt, ctx)
  local T = Nova.Theme
  local flag = opt.Flag or autoFlag(opt.Name)
  local options = opt.Options or {}
  local n = math.max(#options, 1)
  local val = opt.Default ~= nil and opt.Default or options[1]
  local wrap = New("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, opt.Name and 58 or 34) }, parent)
  local top = 0
  if opt.Name then
    local tt = Txt(wrap, opt.Name, { size = 13, sz = UDim2.new(1, 0, 0, 18) })
    tt.Position = UDim2.new(0, 2, 0, 0)
    top = 24
  end
  local bar = New("Frame", {
    BackgroundColor3 = T.Elevated, BorderSizePixel = 0,
    Size = UDim2.new(1, 0, 0, 34), Position = UDim2.new(0, 0, 0, top),
  }, wrap)
  Paint(bar, "bg", "Elevated"); Corner(bar, 10); Pad(bar, 3, 3, 3, 3)
  local pill = New("Frame", {
    BackgroundColor3 = T.Accent, BorderSizePixel = 0,
    Size = UDim2.fromScale(1 / n, 1), Position = UDim2.fromScale(0, 0),
  }, bar)
  Paint(pill, "bg", "Accent"); Corner(pill, 8)
  local btns = {}
  local h = { Instance = wrap }
  for i, name in ipairs(options) do
    local b = New("TextButton", {
      Text = "", AutoButtonColor = false, BackgroundTransparency = 1, BorderSizePixel = 0,
      Size = UDim2.fromScale(1 / n, 1), Position = UDim2.fromScale((i - 1) / n, 0), ZIndex = 2,
    }, bar)
    local lb = Txt(b, tostring(name), { size = 12, w = "SemiBold", token = "Sub",
      xa = Enum.TextXAlignment.Center })
    btns[i] = { b = b, l = lb, v = name }
    b.MouseButton1Click:Connect(function() h.Set(name) end)
    b.MouseEnter:Connect(function()
      if tostring(val) ~= tostring(name) then Tween(lb, { TextColor3 = Nova.Theme.Text }, M.micro) end
    end)
    b.MouseLeave:Connect(function()
      if tostring(val) ~= tostring(name) then Tween(lb, { TextColor3 = Nova.Theme.Sub }, M.micro) end
    end)
  end
  function h.Set(v, silent)
    val = v
    for i, e in ipairs(btns) do
      local on = tostring(e.v) == tostring(v)
      if on then Tween(pill, { Position = UDim2.fromScale((i - 1) / n, 0) }, M.pop) end
      Tween(e.l, { TextColor3 = Nova.Theme[on and "OnAccent" or "Sub"] }, M.base)
    end
    Nova.Flags[flag] = val
    Nova._nilFlags[flag] = val == nil or nil
    if not silent then fire(flag, opt.Callback, val) end
  end
  function h.Get() return val end
  ctx.tip(bar, opt.Tooltip)
  regSetter(flag, function(v) h.Set(v, false) end, ctx)
  h.Set(val, true); Nova.Flags[flag] = val
  return h
end

-- Popup surface in the window overlay: never clipped by a section or the page.
local function makePopup(ctx, anchor, height, width)
  -- width defaults to the anchor's width; a wider popup right-aligns to it
  local T = Nova.Theme
  local p = New("Frame", {
    BackgroundColor3 = T.Surface, BorderSizePixel = 0, Visible = false,
    Size = UDim2.fromOffset(width or 0, 0), ClipsDescendants = true, ZIndex = 60,
  }, ctx.overlay)
  Paint(p, "bg", "Surface"); Corner(p, 10); Stroke(p, "Line", 1, 0.25)
  local scale = New("UIScale", { Scale = 1 }, p)
  local api, open, track, targetH = {}, false, nil, height
  local function popW()
    local z = ctx.zoom()
    return width or anchor.AbsoluteSize.X / z
  end
  local function place()
    local z = ctx.zoom()
    local ov, a = ctx.overlay.AbsolutePosition, anchor.AbsolutePosition
    local aw, ah = anchor.AbsoluteSize.X / z, anchor.AbsoluteSize.Y / z
    local w = popW()
    local x = (a.X - ov.X) / z
    local y = (a.Y - ov.Y) / z
    if w > aw then x = x + aw - w end
    x = clamp(x, 6, math.max(6, ctx.overlay.AbsoluteSize.X / z - w - 6))
    local room = ctx.overlay.AbsoluteSize.Y / z - (y + ah)
    local up = room < targetH + 10 and y > targetH + 10
    p.Position = UDim2.fromOffset(x, up and (y - targetH - 6) or (y + ah + 6))
  end
  function api.Open(h)
    targetH = h or targetH
    if open then return end
    open = true
    p.Size = UDim2.fromOffset(popW(), 0)
    p.Visible = true
    place()
    scale.Scale = 0.98
    Tween(scale, { Scale = 1 }, M.pop)
    Tween(p, { Size = UDim2.fromOffset(p.Size.X.Offset, targetH) }, M.base)
    track = RunService.RenderStepped:Connect(place)
    ctx.bind(track)
  end
  function api.Close()
    if not open then return end
    open = false
    if track then track:Disconnect(); track = nil end
    Tween(scale, { Scale = 0.98 }, M.exit)
    local tw = Tween(p, { Size = UDim2.fromOffset(p.Size.X.Offset, 0) }, M.exit)
    tw.Completed:Connect(function() if not open then p.Visible = false end end)
  end
  function api.IsOpen() return open end
  api.Frame = p
  api.Anchor = anchor
  api.Owner = ctx.popupOwner
  table.insert(ctx.popups, api)
  return api
end

local function addDropdown(parent, opt, ctx)
  local T = Nova.Theme
  local flag = opt.Flag or autoFlag(opt.Name)
  local options = opt.Options or {}
  local multi = opt.Multi == true
  local val
  if multi then
    val = {}
    if type(opt.Default) == "table" then for _, v in ipairs(opt.Default) do val[tostring(v)] = true end end
  else
    val = opt.Default ~= nil and opt.Default or options[1]
  end
  local wrap = New("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 58) }, parent)
  local tt = Txt(wrap, opt.Name or "Dropdown", { size = 13, sz = UDim2.new(1, 0, 0, 18) })
  tt.Position = UDim2.new(0, 2, 0, 0)
  local btn = New("TextButton", {
    Text = "", AutoButtonColor = false, BorderSizePixel = 0,
    BackgroundColor3 = T.Elevated, Size = UDim2.new(1, 0, 0, 34), Position = UDim2.new(0, 0, 0, 24),
  }, wrap)
  Paint(btn, "bg", "Elevated"); Corner(btn, 10)
  local cur = Txt(btn, "", { size = 12, token = "Sub", truncate = true, sz = UDim2.new(1, -46, 1, 0) })
  cur.Position = UDim2.new(0, 14, 0, 0)
  local chev = Txt(btn, "v", { size = 11, w = "SemiBold", token = "Mute",
    xa = Enum.TextXAlignment.Center, sz = UDim2.fromOffset(16, 16) })
  chev.Position = UDim2.new(1, -28, 0.5, -8)
  btn.MouseEnter:Connect(function() Tween(btn, { BackgroundColor3 = Nova.Theme.Hover }, M.micro) end)
  btn.MouseLeave:Connect(function() Tween(btn, { BackgroundColor3 = Nova.Theme.Elevated }, M.micro) end)

  local rowH = 30
  local listH; listH = clamp(#options * (rowH + 2) + 6, 36, (opt.MaxVisible or 6) * (rowH + 2) + 6)
  local pop = makePopup(ctx, btn, listH)
  local scroll = New("ScrollingFrame", {
    BackgroundTransparency = 1, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1),
    CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y,
    ScrollingDirection = Enum.ScrollingDirection.Y, ScrollBarThickness = 2,
    ScrollBarImageColor3 = T.Mute, ZIndex = 61,
  }, pop.Frame)
  Paint(scroll, "scroll", "Mute"); Pad(scroll, 3, 3, 3, 3)
  List(scroll, 2)

  local h = { Instance = wrap }
  local rows = {}
  local function label()
    if not multi then return tostring(val ~= nil and val or "—") end
    local sel = {}
    for _, n in ipairs(options) do if val[tostring(n)] then table.insert(sel, tostring(n)) end end
    if #sel == 0 then return "None" end
    if #sel <= 2 then return table.concat(sel, ", ") end
    return #sel .. " selected"
  end
  local function paintRows()
    for _, r in ipairs(rows) do
      local on = multi and val[r.key] == true or (not multi and tostring(val) == r.key)
      Tween(r.lbl, { TextColor3 = Nova.Theme[on and "Text" or "Sub"] }, M.micro)
      Tween(r.mark, { BackgroundTransparency = on and 0 or 1 }, M.base)
      Tween(r.btn, { BackgroundTransparency = on and 0.88 or 1 }, M.micro)
    end
    cur.Text = label()
    Tween(cur, { TextColor3 = Nova.Theme[(multi and next(val) or (not multi and val ~= nil)) and "Text" or "Sub"] }, M.micro)
  end
  local function buildRows()
   for _, r in ipairs(rows) do r.btn:Destroy() end
   rows = {}
   for _, name in ipairs(options) do
    local key = tostring(name)
    local ob = New("TextButton", {
      Text = "", AutoButtonColor = false, BorderSizePixel = 0,
      BackgroundColor3 = T.Text, BackgroundTransparency = 1,
      Size = UDim2.new(1, 0, 0, rowH), ZIndex = 62,
    }, scroll)
    Corner(ob, 7); Paint(ob, "bg", "Text")
    local mark = New("Frame", {
      BackgroundColor3 = T.Accent, BorderSizePixel = 0, BackgroundTransparency = 1,
      AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 8, 0.5, 0),
      Size = UDim2.fromOffset(3, 14), ZIndex = 63,
    }, ob)
    Paint(mark, "bg", "Accent"); Corner(mark, 2)
    local lbl = Txt(ob, key, { size = 12, token = "Sub", truncate = true, sz = UDim2.new(1, -22, 1, 0) })
    lbl.Position = UDim2.new(0, 18, 0, 0)
    lbl.ZIndex = 63
    ob.MouseEnter:Connect(function() Tween(ob, { BackgroundTransparency = 0.9 }, M.micro) end)
    ob.MouseLeave:Connect(function() paintRows() end)
    ob.MouseButton1Click:Connect(function()
      if multi then
        val[key] = not val[key] or nil
        paintRows()
        fire(flag, opt.Callback, h.Get())
      else
        h.Set(name)
        pop.Close()
      end
    end)
    table.insert(rows, { btn = ob, lbl = lbl, mark = mark, key = key, raw = name })
   end
   listH = clamp(#options * (rowH + 2) + 6, 36, (opt.MaxVisible or 6) * (rowH + 2) + 6)
  end
  buildRows()

  function h.Set(v, silent)
    if multi then
      val = {}
      if type(v) == "table" then
        if v[1] ~= nil then for _, x in ipairs(v) do val[tostring(x)] = true end
        else for k, on in pairs(v) do if on then val[tostring(k)] = true end end end
      end
    else
      val = v
    end
    paintRows()
    Nova.Flags[flag] = h.Get()
    if not silent then fire(flag, opt.Callback, h.Get()) end
  end
  function h.Get()
    if not multi then return val end
    local out = {}
    local seen, missing = {}, {}
    for _, n in ipairs(options) do
      if val[tostring(n)] then table.insert(out, n); seen[tostring(n)] = true end
    end
    for n, on in pairs(val) do if on and not seen[n] then table.insert(missing, n) end end
    table.sort(missing)
    for _, n in ipairs(missing) do table.insert(out, n) end
    return out
  end
  function h.SetOptions(list, keep)
    options = list or {}
    buildRows()
    if not keep then
      if multi then val = {} else val = options[1] end
    end
    paintRows()
    Nova.Flags[flag] = h.Get()
  end
  function h.Open() pop.Open(listH) ; Tween(chev, { Rotation = 180 }, M.base) end
  function h.Close() pop.Close(); Tween(chev, { Rotation = 0 }, M.base) end
  pop.OnClose = h.Close

  btn.MouseButton1Click:Connect(function()
    if pop.IsOpen() then h.Close() else ctx.closePopups(pop); h.Open() end
  end)
  ctx.tip(btn, opt.Tooltip)
  regSetter(flag, function(v) h.Set(v, false) end, ctx)
  h.Set(multi and h.Get() or val, true)
  Nova.Flags[flag] = h.Get()
  return h
end

local function addKeybind(parent, opt, ctx)
  local T = Nova.Theme
  local flag = opt.Flag or autoFlag(opt.Name)
  local val = opt.Default -- Enum.KeyCode / Enum.UserInputType or nil
  local row = Row(parent, opt, false, 120)
  local box = New("TextButton", {
    Text = "", AutoButtonColor = false, BorderSizePixel = 0,
    BackgroundColor3 = T.Surface, AnchorPoint = Vector2.new(1, 0.5),
    Position = UDim2.new(1, -44, 0.5, 0), Size = UDim2.fromOffset(84, 28),
  }, row)
  Paint(box, "bg", "Surface"); Corner(box, 8); Stroke(box, "Line", 1, 0.35)
  local kt = Txt(box, "NONE", { size = 11, w = "Mono", token = "Sub", xa = Enum.TextXAlignment.Center })
  box.MouseEnter:Connect(function() Tween(box, { BackgroundColor3 = Nova.Theme.Hover }, M.micro) end)
  box.MouseLeave:Connect(function() Tween(box, { BackgroundColor3 = Nova.Theme.Surface }, M.micro) end)

  local h = { Instance = row, _press = nil }
  local function nameOf(v)
    if not v then return "NONE" end
    local ok, n = pcall(function() return v.Name end)
    return ok and n or "NONE"
  end
  function h.Set(v, silent)
    val = v
    kt.Text = nameOf(v)
    Tween(kt, { TextColor3 = Nova.Theme[v and "Text" or "Sub"] }, M.micro)
    Nova.Flags[flag] = val
    Nova._nilFlags[flag] = val == nil or nil
    if not silent then fire(flag, opt.Callback, val) end
  end
  function h.Get() return val end
  function h:OnPress(fn) h._press = fn return h end

  local listening = false
  local clear = New("TextButton", { Name = "ClearBinding", Text = "X", AutoButtonColor = false,
    BackgroundTransparency = 1, BorderSizePixel = 0, TextColor3 = T.Sub,
    AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -12, 0.5, 0),
    Size = UDim2.fromOffset(26, 28), TextSize = 12 }, row)
  setFont(clear, "Medium"); Paint(clear, "fg", "Sub")
  clear.MouseButton1Click:Connect(function() listening = false; h.Set(nil) end)
  ctx.tip(clear, "Clear binding (or press Backspace / Delete while choosing a key)")
  box.MouseButton1Click:Connect(function()
    listening = true
    kt.Text = "PRESS…"
    Tween(kt, { TextColor3 = Nova.Theme.Accent }, M.micro)
  end)
  ctx.bind(UserInputService.InputBegan:Connect(function(inp, gpe)
    if listening then
      if inp.UserInputType == Enum.UserInputType.Keyboard then
        listening = false
        local k = inp.KeyCode
        if k == Enum.KeyCode.Escape then h.Set(val, true)
        elseif k == Enum.KeyCode.Backspace or k == Enum.KeyCode.Delete then h.Set(nil)
        else h.Set(k) end
      elseif inp.UserInputType == Enum.UserInputType.MouseButton2
        or inp.UserInputType == Enum.UserInputType.MouseButton3 then
        listening = false
        h.Set(inp.UserInputType)
      end
      return
    end
    if val and not gpe and UserInputService:GetFocusedTextBox() == nil and h._press then
      local hitKey = (inp.KeyCode == val) or (inp.UserInputType == val)
      if hitKey then
        local ok, err = pcall(h._press)
        if not ok then warn("[NovaUI] keybind: " .. tostring(err)) end
      end
    end
  end))
  ctx.tip(box, opt.Tooltip)
  regSetter(flag, function(v)
    if type(v) == "string" then
      local key
      for _, enum in ipairs({ Enum.KeyCode, Enum.UserInputType }) do
        local ok, found = pcall(function() return enum[v] end)
        if ok and found then key = found; break end
      end
      if not key then error("Unknown key: " .. v) end
      v = key
    end
    if v ~= nil and typeof(v) ~= "EnumItem" then error("Invalid keybind") end
    h.Set(v, false)
  end, ctx)
  h.Set(val, true); Nova.Flags[flag] = val
  return h
end

local function addTextBox(parent, opt, ctx)
  local T = Nova.Theme
  local flag = opt.Flag or autoFlag(opt.Name)
  local wrap = New("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 58) }, parent)
  local tt = Txt(wrap, opt.Name or "Input", { size = 13, sz = UDim2.new(1, 0, 0, 18) })
  tt.Position = UDim2.new(0, 2, 0, 0)
  local tb = New("TextBox", {
    Text = opt.Default or "", PlaceholderText = opt.Placeholder or "Type here…",
    PlaceholderColor3 = T.Mute, TextSize = 13, TextColor3 = T.Text,
    TextXAlignment = Enum.TextXAlignment.Left, ClearTextOnFocus = false,
    BackgroundColor3 = T.Elevated, BorderSizePixel = 0,
    Size = UDim2.new(1, 0, 0, 34), Position = UDim2.new(0, 0, 0, 24),
  }, wrap)
  setFont(tb, opt.Mono and "Mono" or "Medium")
  Paint(tb, "bg", "Elevated"); Paint(tb, "fg", "Text"); Paint(tb, "ph", "Mute")
  Corner(tb, 10); Pad(tb, 14, 0, 14, 0)
  local ring = Stroke(tb, "Accent", 1.4, 1)
  local h = { Instance = wrap }
  local setting = false
  function h.Set(v, silent)
    setting = true
    tb.Text = tostring(v or "")
    setting = false
    Nova.Flags[flag] = tb.Text
    if not silent then fire(flag, opt.Callback, tb.Text) end
  end
  function h.Get() return tb.Text end
  tb.Focused:Connect(function() Tween(ring, { Transparency = 0.1 }, M.base) end)
  tb.FocusLost:Connect(function(enter)
    Tween(ring, { Transparency = 1 }, M.base)
    Nova.Flags[flag] = tb.Text
    if not opt.Live and (enter or opt.FireOnAnyLoss ~= false) then
      fire(flag, opt.Callback, tb.Text)
    end
  end)
  tb:GetPropertyChangedSignal("Text"):Connect(function()
    if setting then return end
    Nova.Flags[flag] = tb.Text
    if opt.Live then fire(flag, opt.Callback, tb.Text) end
  end)
  ctx.tip(tb, opt.Tooltip)
  regSetter(flag, function(v) h.Set(v, false) end, ctx)
  Nova.Flags[flag] = tb.Text
  return h
end

local function addColor(parent, opt, ctx)
  local T = Nova.Theme
  local flag = opt.Flag or autoFlag(opt.Name)
  local val = opt.Default or T.Accent
  local hh, ss, vv = Color3.toHSV(val)

  local row = Row(parent, opt, false, 90)
  local sw = New("TextButton", {
    Text = "", AutoButtonColor = false, BorderSizePixel = 0, BackgroundColor3 = val,
    AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -12, 0.5, 0),
    Size = UDim2.fromOffset(52, 26),
  }, row)
  Corner(sw, 8); Stroke(sw, "Line", 1, 0.25)

  -- picker: SV square + hue rail + hex field, in the overlay so it floats free
  local pop = makePopup(ctx, sw, 186, 214)
  local body = New("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 61 }, pop.Frame)
  Pad(body, 10, 10, 10, 10)

  local sv = New("TextButton", {
    Text = "", AutoButtonColor = false, BorderSizePixel = 0,
    BackgroundColor3 = Color3.fromHSV(hh, 1, 1),
    Size = UDim2.new(1, 0, 0, 110), ZIndex = 62,
  }, body)
  Corner(sv, 8)
  local white = New("Frame", { BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0,
    Size = UDim2.fromScale(1, 1), ZIndex = 62 }, sv)
  Corner(white, 8)
  New("UIGradient", {
    Color = ColorSequence.new(Color3.new(1, 1, 1)),
    Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1) }),
  }, white)
  local black = New("Frame", { BackgroundColor3 = Color3.new(0, 0, 0), BorderSizePixel = 0,
    Size = UDim2.fromScale(1, 1), ZIndex = 63 }, sv)
  Corner(black, 8)
  New("UIGradient", {
    Color = ColorSequence.new(Color3.new(0, 0, 0)), Rotation = 90,
    Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, 0) }),
  }, black)
  local cursor = New("Frame", {
    BackgroundTransparency = 1, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5),
    Size = UDim2.fromOffset(12, 12), ZIndex = 64,
  }, sv)
  Corner(cursor, 6); New("UIStroke", { Color = Color3.new(1, 1, 1), Thickness = 2 }, cursor)

  local hue = New("TextButton", {
    Text = "", AutoButtonColor = false, BorderSizePixel = 0, BackgroundColor3 = Color3.new(1, 1, 1),
    Size = UDim2.new(1, 0, 0, 12), Position = UDim2.new(0, 0, 0, 120), ZIndex = 62,
  }, body)
  Corner(hue, 6)
  New("UIGradient", { Color = ColorSequence.new({
    ColorSequenceKeypoint.new(0.00, Color3.fromRGB(255, 0, 0)),
    ColorSequenceKeypoint.new(0.17, Color3.fromRGB(255, 255, 0)),
    ColorSequenceKeypoint.new(0.33, Color3.fromRGB(0, 255, 0)),
    ColorSequenceKeypoint.new(0.50, Color3.fromRGB(0, 255, 255)),
    ColorSequenceKeypoint.new(0.67, Color3.fromRGB(0, 0, 255)),
    ColorSequenceKeypoint.new(0.83, Color3.fromRGB(255, 0, 255)),
    ColorSequenceKeypoint.new(1.00, Color3.fromRGB(255, 0, 0)),
  }) }, hue)
  local hueKnob = New("Frame", {
    BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0,
    AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0, 0.5),
    Size = UDim2.fromOffset(6, 18), ZIndex = 63,
  }, hue)
  Corner(hueKnob, 3)

  local hex = New("TextBox", {
    Text = "#FFFFFF", TextSize = 12, TextColor3 = T.Sub, ClearTextOnFocus = false,
    TextXAlignment = Enum.TextXAlignment.Center, BackgroundColor3 = T.Elevated,
    BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 26), Position = UDim2.new(0, 0, 0, 140), ZIndex = 62,
  }, body)
  setFont(hex, "Mono")
  Paint(hex, "bg", "Elevated"); Paint(hex, "fg", "Sub"); Corner(hex, 7)

  local h = { Instance = row }
  local function toHex(c)
    return string.format("#%02X%02X%02X",
      math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5))
  end
  function h.Set(v, silent, keepHSV)
    val = v
    sw.BackgroundColor3 = v
    if not keepHSV then hh, ss, vv = Color3.toHSV(v) end
    sv.BackgroundColor3 = Color3.fromHSV(hh, 1, 1)
    cursor.Position = UDim2.fromScale(ss, 1 - vv)
    hueKnob.Position = UDim2.fromScale(hh, 0.5)
    hex.Text = toHex(v)
    Nova.Flags[flag] = val
    Nova._nilFlags[flag] = val == nil or nil
    if not silent then fire(flag, opt.Callback, val) end
  end
  function h.Get() return val end

  local dragSV, dragHue = false, false
  local function pickSV(x, y)
    local p, s = sv.AbsolutePosition, sv.AbsoluteSize
    if s.X <= 0 then return end
    ss = clamp((x - p.X) / s.X, 0, 1)
    vv = 1 - clamp((y - p.Y) / s.Y, 0, 1)
    h.Set(Color3.fromHSV(hh, ss, vv), false, true)
  end
  local function pickHue(x)
    local p, s = hue.AbsolutePosition, hue.AbsoluteSize
    if s.X <= 0 then return end
    hh = clamp((x - p.X) / s.X, 0, 1)
    h.Set(Color3.fromHSV(hh, ss, vv), false, true)
  end
  sv.InputBegan:Connect(function(inp)
    if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
      dragSV = true; pickSV(inp.Position.X, inp.Position.Y)
    end
  end)
  hue.InputBegan:Connect(function(inp)
    if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
      dragHue = true; pickHue(inp.Position.X)
    end
  end)
  ctx.bind(UserInputService.InputChanged:Connect(function(inp)
    if inp.UserInputType ~= Enum.UserInputType.MouseMovement and inp.UserInputType ~= Enum.UserInputType.Touch then return end
    if dragSV then pickSV(inp.Position.X, inp.Position.Y) end
    if dragHue then pickHue(inp.Position.X) end
  end))
  ctx.bind(UserInputService.InputEnded:Connect(function(inp)
    if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
      dragSV, dragHue = false, false
    end
  end))
  hex.FocusLost:Connect(function()
    local s = tostring(hex.Text):gsub("#", "")
    if #s == 6 and tonumber(s, 16) then
      local n = tonumber(s, 16)
      h.Set(Color3.fromRGB(math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256))
    else
      hex.Text = toHex(val)
    end
  end)
  sw.MouseButton1Click:Connect(function()
    if pop.IsOpen() then pop.Close() else ctx.closePopups(pop); pop.Open(186) end
  end)
  ctx.tip(sw, opt.Tooltip)
  regSetter(flag, function(v) if typeof(v) == "Color3" then h.Set(v, false) end end, ctx)
  h.Set(val, true); Nova.Flags[flag] = val
  return h
end

--// Window ---------------------------------------------------------------
function Nova:Window(opts)
  opts = opts or {}
  local T = Nova.Theme
  local sg = mountGui("NovaUI_" .. tostring(opts.Title or "Window"):gsub("%W", ""))
  notifHolder(sg)
  local win = { _sg = sg, _conns = {}, _tabs = {}, Title = opts.Title or "Nova" }

  local minW, minH = 470, 330
  local cont = New("Frame", {
    BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.fromScale(0.5, 0.5), Size = opts.Size or UDim2.fromOffset(680, 470),
  }, sg)
  local scale = New("UIScale", { Scale = 1 }, cont)
  local function zoom() return (scale and scale.Parent) and scale.Scale or 1 end

  -- soft shadow behind the shell keeps the flat surface from floating flatly
  New("ImageLabel", {
    BackgroundTransparency = 1, Image = "rbxassetid://5028857084",
    ScaleType = Enum.ScaleType.Slice, SliceCenter = Rect.new(24, 24, 148, 148),
    ImageColor3 = T.Shadow, ImageTransparency = 0.55,
    AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
    Size = UDim2.new(1, 46, 1, 46), ZIndex = 0,
  }, cont)

  local shell = New("CanvasGroup", {
    BackgroundColor3 = T.Bg, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), GroupTransparency = 0,
  }, cont)
  Paint(shell, "bg", "Bg"); Corner(shell, 14); Stroke(shell, "Line", 1, 0.3)
  local shellPop = New("UIScale", { Scale = 1 }, shell)

  -- context passed to every control: connection tracking, popups, tooltips
  local ctx = { win = win, sg = sg, zoom = zoom, popups = {} }
  function ctx.bind(c) table.insert(win._conns, c) return c end
  function ctx.closePopups(except)
    for _, p in ipairs(ctx.popups) do
      if p ~= except and p.IsOpen() then
        if p.OnClose then p.OnClose() else p.Close() end
      end
    end
  end

  --// header
  local head = New("Frame", {
    BackgroundColor3 = T.Surface, BorderSizePixel = 0, Active = true,
    Size = UDim2.new(1, 0, 0, 52),
  }, shell)
  Paint(head, "bg", "Surface")
  local headLine = New("Frame", {
    BackgroundColor3 = T.Line, BorderSizePixel = 0, BackgroundTransparency = 0.4,
    Size = UDim2.new(1, 0, 0, 1), Position = UDim2.new(0, 0, 1, -1),
  }, head)
  Paint(headLine, "bg", "Line")

  local mark = New("Frame", {
    BackgroundColor3 = T.Accent, BorderSizePixel = 0,
    Size = UDim2.fromOffset(10, 10), Position = UDim2.new(0, 18, 0.5, -5),
  }, head)
  Paint(mark, "bg", "Accent"); Corner(mark, 3)
  local title = Txt(head, opts.Title or "Nova", { size = 14, w = "SemiBold", truncate = true,
    sz = UDim2.new(0, 220, 0, 18) })
  title.Position = UDim2.new(0, 36, 0, opts.Subtitle == false and 17 or 9)
  if opts.Subtitle ~= false then
    local sub = Txt(head, opts.Subtitle or ("NovaUI " .. Nova.Version), { size = 11, token = "Mute",
      truncate = true, sz = UDim2.new(0, 220, 0, 14) })
    sub.Position = UDim2.new(0, 36, 0, 27)
  end

  local function headBtn(glyph, x, danger)
    local b = New("TextButton", {
      Text = "", AutoButtonColor = false, BackgroundColor3 = T.Elevated, BackgroundTransparency = 1,
      BorderSizePixel = 0, AnchorPoint = Vector2.new(1, 0.5),
      Position = UDim2.new(1, x, 0.5, 0), Size = UDim2.fromOffset(28, 28),
    }, head)
    Corner(b, 8)
    local g = Txt(b, glyph, { size = 13, w = "SemiBold", token = "Mute", xa = Enum.TextXAlignment.Center })
    b.MouseEnter:Connect(function()
      Tween(b, { BackgroundTransparency = 0 }, M.micro)
      Tween(g, { TextColor3 = Nova.Theme[danger and "Danger" or "Text"] }, M.micro)
    end)
    b.MouseLeave:Connect(function()
      Tween(b, { BackgroundTransparency = 1 }, M.micro)
      Tween(g, { TextColor3 = Nova.Theme.Mute }, M.micro)
    end)
    return b
  end
  local themeB = headBtn("◐", -84, false)
  local hideB = headBtn("—", -50, false)
  local closeB = headBtn("", -16, true)
  closeB.Name = "CloseWindow"
  for _, angle in ipairs({ 45, -45 }) do
    local line = New("Frame", { Name = "Cross", BorderSizePixel = 0,
      BackgroundColor3 = T.Sub, AnchorPoint = Vector2.new(0.5, 0.5),
      Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(14, 2), Rotation = angle }, closeB)
    Paint(line, "bg", "Sub"); Corner(line, 1)
  end
  ctx.tip = function() end   -- replaced below once the overlay exists

  --// body: sidebar + pages
  local body = New("Frame", {
    BackgroundTransparency = 1, Size = UDim2.new(1, 0, 1, -52), Position = UDim2.new(0, 0, 0, 52),
  }, shell)
  local side = New("Frame", { BackgroundTransparency = 1, Size = UDim2.new(0, 176, 1, 0) }, body)
  Pad(side, 12, 12, 8, 12)
  local sideLine = New("Frame", {
    BackgroundColor3 = T.Line, BorderSizePixel = 0, BackgroundTransparency = 0.5,
    Size = UDim2.new(0, 1, 1, -24), Position = UDim2.new(0, 175, 0, 12),
  }, body)
  Paint(sideLine, "bg", "Line")
  local TAB_H, TAB_GAP = 36, 4
  local tabHolder = New("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 1, -22) }, side)
  List(tabHolder, TAB_GAP)
  -- one indicator that slides between tabs instead of per-button bars
  local ind = New("Frame", {
    BackgroundColor3 = T.Accent, BorderSizePixel = 0, Visible = false,
    Size = UDim2.fromOffset(3, 18), Position = UDim2.fromOffset(-8, 0), ZIndex = 3,
  }, side)
  Paint(ind, "bg", "Accent"); Corner(ind, 2)
  local sideFoot = Txt(side, opts.Footer or ("v" .. Nova.Version), { size = 10, token = "Mute",
    sz = UDim2.new(1, 0, 0, 14) })
  sideFoot.Position = UDim2.new(0, 4, 1, -14)

  local pageWrap = New("Frame", {
    BackgroundTransparency = 1, Size = UDim2.new(1, -176, 1, 0), Position = UDim2.new(0, 176, 0, 0),
    ClipsDescendants = true,
  }, body)

  --// overlay (popups, tooltips, dialogs) sits above everything in the shell
  local overlay = New("Frame", {
    Name = "Overlay", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 50,
  }, shell)
  ctx.overlay = overlay

  --// tooltip
  local tipCard = New("Frame", {
    BackgroundColor3 = T.Elevated, BorderSizePixel = 0, Visible = false,
    Size = UDim2.fromOffset(0, 24), ZIndex = 95, AnchorPoint = Vector2.new(0.5, 1),
  }, overlay)
  Paint(tipCard, "bg", "Elevated"); Corner(tipCard, 7); Stroke(tipCard, "Line", 1, 0.3)
  local tipScale = New("UIScale", { Scale = 1 }, tipCard)
  local tipTxt = Txt(tipCard, "", { size = 11, token = "Text", xa = Enum.TextXAlignment.Center })
  tipTxt.ZIndex = 96
  local tipToken = 0
  function ctx.tip(obj, text)
    if not text or text == "" then return end
    obj.MouseEnter:Connect(function()
      tipToken = tipToken + 1
      local mine = tipToken
      task.delay(0.35, function()
        if mine ~= tipToken or not obj.Parent then return end
        local z = zoom()
        tipTxt.Text = tostring(text)
        tipCard.Size = UDim2.fromOffset(math.min(tipTxt.TextBounds.X + 24, 260), 24)
        local ov, a = overlay.AbsolutePosition, obj.AbsolutePosition
        tipCard.Position = UDim2.fromOffset(
          (a.X - ov.X) / z + (obj.AbsoluteSize.X / z) / 2, (a.Y - ov.Y) / z - 6)
        tipCard.Visible = true
        tipScale.Scale = 0.94
        Tween(tipScale, { Scale = 1 }, M.pop)
      end)
    end)
    obj.MouseLeave:Connect(function()
      tipToken = tipToken + 1
      tipCard.Visible = false
    end)
  end

  --// window chrome behaviour
  for _, c in ipairs(Drag(cont, head, zoom)) do table.insert(win._conns, c) end
  -- resize grip: bottom-right, layout-unit math so it survives SetScale
  local grip = New("TextButton", {
    Text = "", AutoButtonColor = false, BackgroundTransparency = 1, BorderSizePixel = 0,
    AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -2, 1, -2),
    Size = UDim2.fromOffset(16, 16), ZIndex = 40,
  }, shell)
  for i = 1, 2 do
    local d = New("Frame", {
      BackgroundColor3 = T.Mute, BorderSizePixel = 0, BackgroundTransparency = 0.4,
      AnchorPoint = Vector2.new(1, 1), Size = UDim2.fromOffset(2 + (i - 1) * 6, 2),
      Position = UDim2.new(1, -3, 1, -3 - (i - 1) * 4), Rotation = 0,
    }, grip)
    Paint(d, "bg", "Mute"); Corner(d, 1)
  end
  do
    local rs, sx, sy, ox, oy = false, 0, 0, 0, 0
    grip.InputBegan:Connect(function(inp)
      if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
        rs = true
        local z = zoom()
        sx, sy = inp.Position.X / z, inp.Position.Y / z
        ox, oy = cont.AbsoluteSize.X / z, cont.AbsoluteSize.Y / z
      end
    end)
    ctx.bind(UserInputService.InputChanged:Connect(function(inp)
      if rs and (inp.UserInputType == Enum.UserInputType.MouseMovement or inp.UserInputType == Enum.UserInputType.Touch) then
        local z = zoom()
        cont.Size = UDim2.fromOffset(
          math.max(minW, ox + inp.Position.X / z - sx),
          math.max(minH, oy + inp.Position.Y / z - sy))
      end
    end))
    ctx.bind(UserInputService.InputEnded:Connect(function(inp)
      if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then rs = false end
    end))
  end
  -- click-away closes any open popup
  ctx.bind(UserInputService.InputBegan:Connect(function(inp)
    if inp.UserInputType ~= Enum.UserInputType.MouseButton1 and inp.UserInputType ~= Enum.UserInputType.Touch then return end
    for _, p in ipairs(ctx.popups) do
      if p.IsOpen() and not inRect(p.Frame, inp.Position)
        and not (p.Anchor and inRect(p.Anchor, inp.Position)) then
        task.defer(function()
          if p.IsOpen() and not inRect(p.Frame, inp.Position) then
            if p.OnClose then p.OnClose() else p.Close() end
          end
        end)
      end
    end
  end))

  local visible = true
  function win:SetVisible(v)
    v = v == true
    if v == visible then return end
    visible = v
    if v then
      cont.Visible = true
      shellPop.Scale = 0.97
      Tween(shellPop, { Scale = 1 }, M.pop)
      Tween(shell, { GroupTransparency = 0 }, M.base)
    else
      ctx.closePopups(nil)
      Tween(shellPop, { Scale = 0.98 }, M.exit)
      local tw = Tween(shell, { GroupTransparency = 1 }, M.exit)
      tw.Completed:Connect(function() if not visible then cont.Visible = false end end)
    end
  end
  function win:IsVisible() return visible end
  function win:Toggle() win:SetVisible(not visible) end
  function win:SetScale(s) Tween(scale, { Scale = clamp(s or 1, 0.6, 1.6) }, M.base) end
  win.ConfigId = opts.Id or win.Title
  function win:GetLayout()
    local p, s = cont.Position, cont.Size
    return { position = { p.X.Scale, p.X.Offset, p.Y.Scale, p.Y.Offset },
      size = { s.X.Offset, s.Y.Offset } }
  end
  function win:SetLayout(layout)
    if type(layout) ~= "table" then return end
    local function numbers(t, n)
      if type(t) ~= "table" then return false end
      for i = 1, n do
        if type(t[i]) ~= "number" or t[i] ~= t[i] or math.abs(t[i]) > 100000 then return false end
      end
      return true
    end
    local viewport = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize or Vector2.new(1280, 720)
    if numbers(layout.size, 2) then
      cont.Size = UDim2.fromOffset(clamp(layout.size[1], minW, math.max(minW, viewport.X / zoom())),
        clamp(layout.size[2], minH, math.max(minH, viewport.Y / zoom())))
    end
    if numbers(layout.position, 4) then
      local p, sz = layout.position, cont.Size
      local x, y = p[1] * viewport.X + p[2], p[3] * viewport.Y + p[4]
      cont.Position = UDim2.fromOffset(clamp(x, 90, math.max(90, viewport.X - 90)),
        clamp(y, sz.Y.Offset / 2, math.max(sz.Y.Offset / 2, viewport.Y - 44)))
    end
  end
  function win:SetTitle(t) title.Text = tostring(t) end
  function win:Notify(n) return Nova:Notify(n) end

  local tkey = opts.Keybind == nil and Enum.KeyCode.RightShift or opts.Keybind
  -- rebindable at runtime: win:SetToggleKey(Enum.KeyCode.Insert).
  -- Clearing (nil) disables the hotkey; the ▲/— buttons still work.
  function win:SetToggleKey(k)
    if k ~= nil then
      local ok, valid = pcall(function() return k.EnumType == Enum.KeyCode end)
      if not ok or not valid then return false end
    end
    tkey = k
    return true
  end
  function win:GetToggleKey() return tkey end
  ctx.bind(UserInputService.InputBegan:Connect(function(inp, gpe)
      if not gpe and inp.KeyCode == tkey and UserInputService:GetFocusedTextBox() == nil then
        win:Toggle()
      end
  end))
  themeB.MouseButton1Click:Connect(function()
    local name = Nova:NextTheme()
    Nova:Notify({ Title = "Theme", Text = name, Type = "info", Duration = 1.6 })
  end)
  hideB.MouseButton1Click:Connect(function() win:SetVisible(false) end)
  closeB.MouseButton1Click:Connect(function() win:Unload() end)

  function win:Unload()
    if win._dead then return end
    win._dead = true
    ctx.closePopups(nil)
    if Nova._themeControl and Nova._themeControl.Instance:IsDescendantOf(sg) then Nova._themeControl = nil end
    for _, c in ipairs(win._conns) do pcall(function() c:Disconnect() end) end
    for i, w in ipairs(Nova._wins) do if w == win then table.remove(Nova._wins, i) break end end
    Tween(shellPop, { Scale = 0.97 }, M.exit)
    local tw = Tween(shell, { GroupTransparency = 1 }, M.exit)
    tw.Completed:Connect(function() pcall(function() sg:Destroy() end) end)
    if opts.OnUnload then pcall(opts.OnUnload) end
    for flag, owner in pairs(Nova._owners) do
      if owner.win == win then
        Nova._setters[flag], Nova._owners[flag], Nova._pendingSetters[flag] = nil, nil, nil
      end
    end
  end

  --// modal dialog
  function win:Dialog(d)
    d = d or {}
    local Tn = Nova.Theme
    local veil = New("TextButton", {
      Text = "", AutoButtonColor = false, BackgroundColor3 = Color3.new(0, 0, 0),
      BackgroundTransparency = 1, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), ZIndex = 80,
    }, overlay)
    local card = New("Frame", {
      BackgroundColor3 = Tn.Surface, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5),
      Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(320, 0),
      AutomaticSize = Enum.AutomaticSize.Y, ZIndex = 81,
    }, veil)
    Paint(card, "bg", "Surface"); Corner(card, 14); Stroke(card, "Line", 1, 0.25)
    Pad(card, 18, 18, 18, 16); List(card, 10)
    local cs = New("UIScale", { Scale = 0.94 }, card)
    local t = Txt(card, d.Title or "Confirm", { size = 15, w = "SemiBold", sz = UDim2.new(1, 0, 0, 20) })
    t.ZIndex = 82
    if d.Text then
      local b = Txt(card, d.Text, { size = 12, token = "Sub", sz = UDim2.new(1, 0, 0, 0) })
      b.TextWrapped = true; b.AutomaticSize = Enum.AutomaticSize.Y
      b.TextYAlignment = Enum.TextYAlignment.Top; b.ZIndex = 82
    end
    local rowB = New("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 38), ZIndex = 82 }, card)
    local function close()
      Tween(cs, { Scale = 0.96 }, M.exit)
      Tween(veil, { BackgroundTransparency = 1 }, M.exit)
      task.delay(0.18, function() pcall(function() veil:Destroy() end) end)
    end
    local function mkBtn(text, x, w, variant, cb)
      local holder = New("Frame", { BackgroundTransparency = 1,
        Size = UDim2.new(w, -4, 1, 0), Position = UDim2.fromScale(x, 0), ZIndex = 82 }, rowB)
      local bh = addButton(holder, { Name = text, Variant = variant, Callback = function()
        close(); if cb then pcall(cb) end
      end }, nil)
      bh.Instance.ZIndex = 83
      return bh
    end
    if d.Cancel ~= false then
      mkBtn(d.CancelText or "Cancel", 0, 0.5, "ghost", d.OnCancel)
      mkBtn(d.ConfirmText or "Confirm", 0.5, 0.5, d.Danger and "danger" or "primary", d.OnConfirm)
    else
      mkBtn(d.ConfirmText or "OK", 0, 1, "primary", d.OnConfirm)
    end
    veil.MouseButton1Click:Connect(function() if d.DismissOnClickAway ~= false then close() end end)
    Tween(veil, { BackgroundTransparency = 0.45 }, M.base)
    Tween(cs, { Scale = 1 }, M.pop)
    return { Close = close }
  end

  --// tabs -----------------------------------------------------------------
  function win:Tab(topt)
    topt = topt or {}
    -- page lives in a CanvasGroup so tab switches can cross-fade as one layer
    local pageHost = New("CanvasGroup", {
      BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), GroupTransparency = 1, Visible = false,
    }, pageWrap)
    local page = New("ScrollingFrame", {
      BackgroundTransparency = 1, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1),
      CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y,
      ScrollingDirection = Enum.ScrollingDirection.Y, ScrollBarThickness = 2,
      ScrollBarImageColor3 = T.Mute, ScrollBarImageTransparency = 0.4,
    }, pageHost)
    Paint(page, "scroll", "Mute")
    Pad(page, 16, 14, 14, 16)
    List(page, 10)

    local tb = New("TextButton", {
      Text = "", AutoButtonColor = false, BorderSizePixel = 0,
      BackgroundColor3 = T.Elevated, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, TAB_H),
    }, tabHolder)
    Paint(tb, "bg", "Elevated"); Corner(tb, 9)
    local ic = Txt(tb, topt.Icon or "•", { size = 13, w = "SemiBold", token = "Mute",
      xa = Enum.TextXAlignment.Center, sz = UDim2.fromOffset(20, 20) })
    ic.Position = UDim2.new(0, 12, 0.5, -10)
    local nm = Txt(tb, topt.Name or "Tab", { size = 13, token = "Sub", truncate = true,
      sz = UDim2.new(1, -46, 1, 0) })
    nm.Position = UDim2.new(0, 38, 0, 0)

    local tab = { _page = page, _host = pageHost, _btn = tb, _icon = ic, _name = nm,
      _active = false, _defaultSec = nil, Name = topt.Name or "Tab" }

    -- optional inline switch on the tab button: win:Tab({ Toggle = {
    --   Default = true, Tooltip = "...", Callback = fn } }). Clicking the
    -- switch flips it WITHOUT selecting the tab (it sits above the row).
    local togOpt = topt.Toggle
    if type(togOpt) == "table" then
      local tst = togOpt.Default ~= false
      local toggleFlag = togOpt.Flag or (win.ConfigId .. "/" .. tab.Name .. "/enabled")
      nm.Size = UDim2.new(1, -80, 1, 0)
      local sw = New("TextButton", {
        Text = "", AutoButtonColor = false, BorderSizePixel = 0,
        BackgroundColor3 = T[tst and "Accent" or "Line"],
        AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -8, 0.5, 0),
        Size = UDim2.fromOffset(30, 18), ZIndex = 5,
      }, tb)
      Corner(sw, 9)
      local knob = New("Frame", {
        BackgroundColor3 = T[tst and "OnAccent" or "Sub"], BorderSizePixel = 0,
        AnchorPoint = Vector2.new(0, 0.5),
        Position = UDim2.new(0, tst and 13 or 3, 0.5, 0),
        Size = UDim2.fromOffset(12, 12), ZIndex = 6,
      }, sw)
      Corner(knob, 6)
      local function paintSw()
        local Tn = Nova.Theme
        sw.BackgroundColor3 = Tn[tst and "Accent" or "Line"]
        knob.BackgroundColor3 = Tn[tst and "OnAccent" or "Sub"]
        knob.Position = UDim2.new(0, tst and 13 or 3, 0.5, 0)
      end
      function tab:SetToggle(v, silent)
        tst = v == true
        Nova.Flags[toggleFlag] = tst
        paintSw()
        if not silent then fire(toggleFlag, togOpt.Callback, tst) end
      end
      function tab:GetToggle() return tst end
      sw.MouseButton1Click:Connect(function() tab:SetToggle(not tst) end)
      if ctx then ctx.tip(sw, togOpt.Tooltip) end
      tab._toggle = sw
      Nova.Flags[toggleFlag] = tst
      Nova._refreshers[sw] = paintSw
      regSetter(toggleFlag, function(v) tab:SetToggle(v) end, ctx)
    end
    Nova._refreshers[tb] = function()
      ic.TextColor3 = Nova.Theme[tab._active and "Accent" or "Mute"]
      nm.TextColor3 = Nova.Theme[tab._active and "Text" or "Sub"]
    end

    function tab.Select()
      if tab._active then return end
      ctx.closePopups(nil)
      for _, t in ipairs(win._tabs) do
        local on = t == tab
        local was = t._active
        t._active = on
        Tween(t._btn, { BackgroundTransparency = on and 0 or 1 }, M.base)
        Tween(t._icon, { TextColor3 = Nova.Theme[on and "Accent" or "Mute"] }, M.base)
        Tween(t._name, { TextColor3 = Nova.Theme[on and "Text" or "Sub"] }, M.base)
        if on then
          t._host.Visible = true
          t._host.Position = UDim2.fromOffset(0, 10)
          Tween(t._host, { GroupTransparency = 0, Position = UDim2.fromOffset(0, 0) }, M.slow)
          -- slide the indicator to this button; index math, so it is correct
          -- on the very first frame too (AbsolutePosition is not yet laid out)
          local y = (t._index - 1) * (TAB_H + TAB_GAP) + (TAB_H - 18) / 2
          if ind.Visible then
            Tween(ind, { Position = UDim2.fromOffset(-8, y) }, M.pop)
          else
            ind.Position = UDim2.fromOffset(-8, y)
            ind.Visible = true
          end
        elseif was then
          local host = t._host
          Tween(host, { GroupTransparency = 1, Position = UDim2.fromOffset(0, -8) }, M.exit)
          task.delay(0.16, function() if not t._active then host.Visible = false end end)
        else
          t._host.Visible = false
          t._host.GroupTransparency = 1
        end
      end
    end
    tb.MouseEnter:Connect(function()
      if not tab._active then
        Tween(tb, { BackgroundTransparency = 0.5 }, M.micro)
        Tween(nm, { TextColor3 = Nova.Theme.Text }, M.micro)
      end
    end)
    tb.MouseLeave:Connect(function()
      if not tab._active then
        Tween(tb, { BackgroundTransparency = 1 }, M.micro)
        Tween(nm, { TextColor3 = Nova.Theme.Sub }, M.micro)
      end
    end)
    tb.MouseButton1Click:Connect(function() tab.Select() end)
    ctx.tip(tb, topt.Tooltip)
    table.insert(win._tabs, tab)
    tab._index = #win._tabs
    if #win._tabs == 1 then tab.Select() end

    --// sections ------------------------------------------------------------
    local function makeSection(parent, sopt, scope, sectionCtx)
      sopt = sopt or {}
      local ctx = sectionCtx or ctx
      local box = New("Frame", {
        BackgroundColor3 = T.Surface, BorderSizePixel = 0,
        Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
      }, parent)
      Paint(box, "bg", "Surface"); Corner(box, 12); Stroke(box, "Line", 1, 0.45)
      Pad(box, 12, 10, 12, 12); List(box, 8)

      local hb = New("TextButton", {
        Text = "", AutoButtonColor = false, BackgroundTransparency = 1,
        Size = UDim2.new(1, 0, 0, 20),
      }, box)
      local st = Txt(hb, string.upper(sopt.Name or "SECTION"), { size = 11, w = "SemiBold", token = "Mute",
        sz = UDim2.new(1, -24, 1, 0) })
      st.Position = UDim2.new(0, 2, 0, 0)
      local ar = Txt(hb, "v", { size = 10, w = "SemiBold", token = "Mute",
        xa = Enum.TextXAlignment.Center, sz = UDim2.fromOffset(14, 14) })
      ar.Position = UDim2.new(1, -14, 0.5, -7)
      hb.MouseEnter:Connect(function()
        Tween(st, { TextColor3 = Nova.Theme.Sub }, M.micro)
        Tween(ar, { TextColor3 = Nova.Theme.Sub }, M.micro)
      end)
      hb.MouseLeave:Connect(function()
        Tween(st, { TextColor3 = Nova.Theme.Mute }, M.micro)
        Tween(ar, { TextColor3 = Nova.Theme.Mute }, M.micro)
      end)

      -- clip wrapper animates height; inner keeps AutomaticSize so content rules
      local clip = New("Frame", {
        BackgroundTransparency = 1, ClipsDescendants = true,
        Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
      }, box)
      local inner = New("Frame", {
        BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
      }, clip)
      List(inner, 8)

      local collapsed = false
      local function setCollapsed(v)
        ctx.closePopups(nil)
        collapsed = v == true
        local hgt = inner.AbsoluteSize.Y / zoom()
        clip.AutomaticSize = Enum.AutomaticSize.None
        if collapsed then
          clip.Size = UDim2.new(1, 0, 0, hgt)
          Tween(clip, { Size = UDim2.new(1, 0, 0, 0) }, M.base)
        else
          local tw = Tween(clip, { Size = UDim2.new(1, 0, 0, hgt) }, M.base)
          tw.Completed:Connect(function()
            if not collapsed then clip.AutomaticSize = Enum.AutomaticSize.Y end
          end)
        end
        Tween(ar, { Rotation = collapsed and -90 or 0 }, M.base)
      end
      hb.MouseButton1Click:Connect(function() setCollapsed(not collapsed) end)

      local sec = { Instance = box }
      function sec:Label(t, o) return addLabel(inner, t, type(o) == "table" and o or { size = o }) end
      function sec:Paragraph(t) return addLabel(inner, t, { size = 12, token = "Sub" }) end
      function sec:Divider() return addDivider(inner) end
      function sec:Space(h) return addSpace(inner, h) end
      function sec:Button(o) return addButton(inner, o or {}, ctx) end
      local counts = {}
      local function control(factory, options, multi)
        local o = {}
        for k, v in pairs(options or {}) do o[k] = v end
        if multi then o.Multi = true end
        if not o.Flag then
          local name = o.Name or "opt"
          counts[name] = (counts[name] or 0) + 1
          local legacy = autoFlag(name)
          o.Flag = scope .. "/" .. (sopt.Id or sopt.Name or "General") .. "/" .. name
          if counts[name] > 1 then o.Flag = o.Flag .. "/" .. counts[name] end
          Nova._aliases[legacy] = o.Flag
        end
        local handle = factory(inner, o, ctx)
        handle.Flag = o.Flag
        Nova._refreshers[handle.Instance] = function() handle.Set(handle.Get(), true) end
        return handle
      end
      function sec:Toggle(o) return control(addToggle, o) end
      function sec:Slider(o) return control(addSlider, o) end
      function sec:Dropdown(o) return control(addDropdown, o) end
      function sec:MultiDropdown(o) return control(addDropdown, o, true) end
      function sec:Segmented(o) return control(addSegmented, o) end
      function sec:Keybind(o) return control(addKeybind, o) end
      function sec:Color(o) return control(addColor, o) end
      function sec:TextBox(o) return control(addTextBox, o) end
      function sec:Progress(o) return addProgress(inner, o or {}) end
      function sec:SetCollapsed(v) setCollapsed(v == true) end
      function sec:IsCollapsed() return collapsed end
      if sopt.Collapsed then task.defer(function() sec:SetCollapsed(true) end) end
      return sec
    end

    local tabScope = win.ConfigId .. "/" .. (topt.Id or tab.Name)
    function tab:Section(sopt) return makeSection(page, sopt, tabScope) end

    -- A second, persistent sidebar inside the tab. Only the content pages switch.
    function tab:Navigation(nopt)
      if tab._navigation then return tab._navigation end
      nopt = nopt or {}
      page.Visible = false
      local root = New("Frame", { Name = "Navigation", BackgroundTransparency = 1,
        Size = UDim2.fromScale(1, 1) }, pageHost)
      local rail = New("ScrollingFrame", { Name = "Sidebar", BackgroundTransparency = 1,
        BorderSizePixel = 0, Size = UDim2.new(0, 142, 1, 0), CanvasSize = UDim2.new(),
        AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollingDirection = Enum.ScrollingDirection.Y,
        ScrollBarThickness = 2, ScrollBarImageColor3 = T.Mute }, root)
      Paint(rail, "scroll", "Mute"); Pad(rail, 10, 14, 10, 14); List(rail, 6)
      local line = New("Frame", { BackgroundColor3 = T.Line, BorderSizePixel = 0,
        Size = UDim2.new(0, 1, 1, -28), Position = UDim2.fromOffset(142, 14) }, root)
      Paint(line, "bg", "Line")
      local content = New("Frame", { Name = "Content", BackgroundTransparency = 1,
        Position = UDim2.fromOffset(143, 0), Size = UDim2.new(1, -143, 1, 0) }, root)
      local caption = Txt(content, nopt.Name or "Places", { size = 16, w = "SemiBold",
        sz = UDim2.new(1, -32, 0, 24), truncate = true })
      caption.Position = UDim2.fromOffset(16, 14)
      local nav = { Instance = root, Sidebar = rail, Content = content, _pages = {}, _active = nil }
      tab._navigation = nav
      local function layout()
        local compact = root.AbsoluteSize.X / zoom() < 620
        local width = compact and 56 or (nopt.Width or 142)
        rail.Size = UDim2.new(0, width, 1, 0)
        line.Position = UDim2.fromOffset(width, 14)
        content.Position = UDim2.fromOffset(width + 1, 0)
        content.Size = UDim2.new(1, -width - 1, 1, 0)
        for _, item in ipairs(nav._pages) do
          item._label.Visible = not compact
          item._icon.Position = compact and UDim2.new(0.5, -10, 0.5, -10) or UDim2.new(0, 10, 0.5, -10)
        end
      end
      ctx.bind(root:GetPropertyChangedSignal("AbsoluteSize"):Connect(layout))
      function nav:Page(popt)
        popt = popt or {}
        local id = popt.Id or popt.Name or tostring(#nav._pages + 1)
        for _, item in ipairs(nav._pages) do assert(item.Id ~= id, "Duplicate navigation page: " .. id) end
        local button = New("TextButton", { Name = id, Text = "", AutoButtonColor = false,
          BackgroundColor3 = T.Elevated, BackgroundTransparency = 1, BorderSizePixel = 0,
          Size = UDim2.new(1, 0, 0, 38), LayoutOrder = popt.Order or #nav._pages + 1 }, rail)
        Paint(button, "bg", "Elevated"); Corner(button, 9)
        local icon = Txt(button, popt.Icon or "•", { size = 17, token = "Mute",
          xa = Enum.TextXAlignment.Center, sz = UDim2.fromOffset(20, 20) })
        local label = Txt(button, popt.Name or id, { size = 12, token = "Sub", truncate = true,
          sz = UDim2.new(1, -40, 1, 0) })
        label.Position = UDim2.fromOffset(38, 0)
        local bar = New("Frame", { BackgroundColor3 = T.Accent, BorderSizePixel = 0,
          Position = UDim2.new(0, 0, 0.5, -9), Size = UDim2.fromOffset(3, 18), Visible = false }, button)
        Paint(bar, "bg", "Accent"); Corner(bar, 2)
        local scroll = New("ScrollingFrame", { Name = id, BackgroundTransparency = 1,
          BorderSizePixel = 0, Position = UDim2.fromOffset(0, 46), Size = UDim2.new(1, 0, 1, -46),
          CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y,
          ScrollingDirection = Enum.ScrollingDirection.Y, ScrollBarThickness = 2,
          ScrollBarImageColor3 = T.Mute, Visible = false }, content)
        Paint(scroll, "scroll", "Mute"); Pad(scroll, 16, 4, 14, 16); List(scroll, 10)
        local item = { Id = id, Name = popt.Name or id, Instance = scroll, _btn = button,
          _icon = icon, _label = label, _conns = {}, _popups = {} }
        local pageCtx = {}
        for k, v in pairs(ctx) do pageCtx[k] = v end
        function pageCtx.bind(c)
          table.insert(item._conns, c)
          return ctx.bind(c)
        end
        -- Popups live in the overlay, so explicitly own and remove them on reload.
        pageCtx.popupOwner = item
        local function paintItem()
          local on = nav._active == item
          button.BackgroundTransparency = on and 0 or 1
          icon.TextColor3 = Nova.Theme[on and "Accent" or "Mute"]
          label.TextColor3 = Nova.Theme[on and "Text" or "Sub"]
          bar.Visible = on
        end
        item._paint = paintItem
        Nova._refreshers[button] = paintItem
        function item:Select()
          if item._dead or nav._active == item then return end
          ctx.closePopups(nil)
          tipToken = tipToken + 1; tipCard.Visible = false
          nav._active = item
          caption.Text = item.Name
          for _, other in ipairs(nav._pages) do
            other.Instance.Visible = other == item
            other._paint()
          end
        end
        function item:Section(sopt)
          return makeSection(scroll, sopt, tabScope .. "/" .. id, pageCtx)
        end
        function item:SubTabs(definitions)
          assert(not item._subtabs, "Subtabs already exist")
          local tabs = {}
          item._subtabs = tabs
          local host = New("Frame", { Name = "SubTabs", BackgroundTransparency = 1,
            Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y }, scroll)
          List(host, 10)
          local bar = New("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 32) }, host)
          for index, def in ipairs(definitions) do
            local key = def.Id or def.Name
            local button = New("TextButton", { Text = def.Name, AutoButtonColor = false,
              BackgroundColor3 = T.Elevated, TextColor3 = T.Sub, TextSize = 12, BorderSizePixel = 0,
              Position = UDim2.new((index - 1) / #definitions, 0, 0, 0),
              Size = UDim2.new(1 / #definitions, -4, 1, 0) }, bar)
            setFont(button, "Medium"); Corner(button, 8); Paint(button, "bg", "Elevated")
            local body = New("Frame", { Name = key, BackgroundTransparency = 1, Visible = false,
              Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 1 }, host)
            List(body, 10)
            local sub = { Instance = body, Button = button, Name = def.Name }
            tabs[key] = sub
            function sub:Section(options)
              return makeSection(body, options, tabScope .. "/" .. id .. "/" .. key, pageCtx)
            end
            function sub:Select()
              ctx.closePopups(nil)
              for _, other in pairs(tabs) do
                other.Instance.Visible = other == sub
                other.Button.TextColor3 = Nova.Theme[other == sub and "Accent" or "Sub"]
              end
            end
            button.MouseButton1Click:Connect(function() sub:Select() end)
            Nova._refreshers[button] = function()
              button.TextColor3 = Nova.Theme[body.Visible and "Accent" or "Sub"]
            end
            if index == 1 then sub:Select() end
          end
          return tabs
        end
        for _, method in ipairs({ "Label", "Paragraph", "Divider", "Space", "Button", "Toggle", "Slider",
          "Dropdown", "MultiDropdown", "Segmented", "Keybind", "Color", "TextBox", "Progress" }) do
          item[method] = function(_, ...)
            if not item._defaultSec then item._defaultSec = item:Section({ Name = item.Name }) end
            return item._defaultSec[method](item._defaultSec, ...)
          end
        end
        function item:Destroy()
          if item._dead then return end
          item._dead = true
          for _, c in ipairs(item._conns) do
            pcall(function() c:Disconnect() end)
            for i = #win._conns, 1, -1 do if win._conns[i] == c then table.remove(win._conns, i) end end
          end
          for i = #ctx.popups, 1, -1 do
            local popup = ctx.popups[i]
            if popup.Owner == item then popup.Frame:Destroy(); table.remove(ctx.popups, i) end
          end
          for flag, owner in pairs(Nova._owners) do
            if owner == pageCtx then
              Nova._setters[flag], Nova._owners[flag], Nova._pendingSetters[flag] = nil, nil, nil
            end
          end
          for i, other in ipairs(nav._pages) do if other == item then table.remove(nav._pages, i); break end end
          button:Destroy(); scroll:Destroy()
          if nav._active == item then
            nav._active = nil
            if nav._pages[1] then nav._pages[1]:Select() end
          end
        end
        button.MouseButton1Click:Connect(function() item:Select() end)
        button.MouseEnter:Connect(function()
          if nav._active ~= item then button.BackgroundTransparency = 0.5 end
        end)
        button.MouseLeave:Connect(paintItem)
        ctx.tip(button, popt.Tooltip or popt.Name or id)
        table.insert(nav._pages, item)
        layout()
        if not nav._active then item:Select() end
        return item
      end
      function nav:Clear(keepId)
        for i = #nav._pages, 1, -1 do
          if nav._pages[i].Id ~= keepId then nav._pages[i]:Destroy() end
        end
      end
      layout()
      return nav
    end

    function tab:_default()
      if not tab._defaultSec then tab._defaultSec = tab:Section({ Name = topt.Section or "General" }) end
      return tab._defaultSec
    end
    for _, m in ipairs({ "Label", "Paragraph", "Divider", "Space", "Button", "Toggle", "Slider",
      "Dropdown", "MultiDropdown", "Segmented", "Keybind", "Color", "TextBox", "Progress" }) do
      tab[m] = function(_, ...) local s = tab:_default() ; return s[m](s, ...) end
    end
    return tab
  end

  table.insert(Nova._wins, win)
  -- entrance
  shellPop.Scale = 0.96
  shell.GroupTransparency = 1
  Tween(shellPop, { Scale = 1 }, M.pop)
  Tween(shell, { GroupTransparency = 0 }, M.slow)
  return win
end

--// Config persistence ------------------------------------------------------
-- Preserve a session fallback across reinjection, but never report it as disk storage.
local configEnv = (getgenv and getgenv()) or _G
configEnv.__NOVA_CONFIG_MEMORY = configEnv.__NOVA_CONFIG_MEMORY or {}
Nova._memCfg = configEnv.__NOVA_CONFIG_MEMORY
Nova._loaded = {}
Nova.ActiveConfig = "default"

local function configName(name)
  name = tostring(name or "default"):match("^%s*(.-)%s*$")
  if name == "" then name = "default" end
  if #name > 80 or name == "." or name == ".." or name == "__autoload"
    or name:find('[/\\:%*%?"<>|%c]') or name:sub(-1) == "." then
    return nil, "Invalid config name"
  end
  return name
end
local function encVal(v)
  if v == nil then return { t = "nil" } end
  if typeof(v) == "Color3" then
    return { t = "c3", v = { v.R * 255, v.G * 255, v.B * 255 } }
  end
  if typeof(v) == "EnumItem" then
    return { t = "enum", enum = tostring(v.EnumType), v = v.Name }
  end
  if type(v) == "table" then
    local out = {}
    for i, x in ipairs(v) do out[i] = x end
    return { t = "list", v = out }
  end
  if type(v) == "number" or type(v) == "string" or type(v) == "boolean" then return v end
  error("Unsupported config value: " .. typeof(v))
end
local function decVal(v)
  if type(v) ~= "table" then return v end
  if v.t == "nil" then return nil end
  if v.t == "c3" and type(v.v) == "table" then
    for i = 1, 3 do assert(type(v.v[i]) == "number", "Invalid color") end
    return Color3.fromRGB(v.v[1], v.v[2], v.v[3])
  end
  if v.t == "list" and type(v.v) == "table" then return v.v end
  if v.t == "enum" then
    if v.enum then
      -- encVal stores tostring(EnumType): "KeyCode" / "UserInputType" (never
      -- with the "Enum." prefix). Resolve against the right family; an
      -- unknown/stale member falls back to the bare name so the keybind
      -- setter can resolve it across both families instead of throwing.
      local et = tostring(v.enum)
      local enum
      if et == "UserInputType" or et == "Enum.UserInputType" then enum = Enum.UserInputType
      elseif et == "KeyCode" or et == "Enum.KeyCode" then enum = Enum.KeyCode end
      if enum then
        local ok, item = pcall(function() return enum[v.v] end)
        if ok and item ~= nil then return item end
      end
    end
    return v.v -- legacy keybinds stored only the name
  end
  error("Invalid encoded config value")
end
local function readConfigFile(name)
  local json
  if type(readfile) == "function" then
    local ok, value = pcall(readfile, "NovaUI/" .. name .. ".json")
    if ok then json = value end
  end
  json = json or Nova._memCfg[name]
  if not json then return nil, "missing" end
  local ok, data = pcall(HttpService.JSONDecode, HttpService, json)
  if not ok or type(data) ~= "table" then return nil, "Invalid JSON in '" .. name .. "'" end
  return data
end
local function writeConfigFile(name, data)
  local encoded, json = pcall(HttpService.JSONEncode, HttpService, data)
  if not encoded then return false, tostring(json) end
  Nova._memCfg[name] = json
  if type(writefile) ~= "function" or type(readfile) ~= "function" then return true, "memory" end
  local ok, err = pcall(function()
    if type(makefolder) == "function" then
      if type(isfolder) == "function" then
        if not isfolder("NovaUI") then makefolder("NovaUI") end
      else
        pcall(makefolder, "NovaUI")
      end
    end
    local path = "NovaUI/" .. name .. ".json"
    -- Keep the previous valid file recoverable if the host interrupts a write.
    local previousOK, previous = pcall(readfile, path)
    if previousOK and type(previous) == "string" then writefile(path .. ".bak", previous) end
    writefile(path, json)
    assert(readfile(path) == json, "Config verification failed")
  end)
  if not ok then return false, tostring(err) end
  return true, "disk"
end
local function savedValue(flag)
  if Nova._loaded[flag] ~= nil then return Nova._loaded[flag], true end
  for legacy, current in pairs(Nova._aliases) do
    if current == flag and Nova._loaded[legacy] ~= nil then return Nova._loaded[legacy], true end
  end
  return nil, false
end
local function applySetters(setters)
  local order = {}
  for flag in pairs(setters) do table.insert(order, flag) end
  local function priority(flag)
    if flag == "huma_universal_enabled" then return -10 end
    local value = savedValue(flag)
    return type(value) == "boolean" and 10 or 0
  end
  table.sort(order, function(a, b)
    local pa, pb = priority(a), priority(b)
    if pa ~= pb then return pa < pb end
    return a < b
  end)
  local count, errors = 0, {}
  Nova._applying = true
  for _, flag in ipairs(order) do
    local setter = setters[flag]
    if Nova._setters[flag] == setter then
      Nova._pendingSetters[flag] = nil
      local value, exists = savedValue(flag)
      if exists then
        local ok, err = pcall(function() setter(decVal(value)) end)
        if ok then count = count + 1 else table.insert(errors, flag .. ": " .. tostring(err)) end
      end
    end
  end
  Nova._applying = false
  -- __theme is authoritative, including old configs with a stale Theme dropdown.
  if Nova.Themes[Nova._loaded.__theme] then Nova:SetTheme(Nova._loaded.__theme) end
  return count, errors
end
function Nova:ApplyPending()
  local pending = {}
  for flag, fn in pairs(Nova._pendingSetters) do pending[flag] = fn end
  local count, errors = applySetters(pending)
  if #errors > 0 then
    warn("[NovaUI] config: " .. table.concat(errors, "\n"))
    Nova:Notify({ Title = "Config", Text = "Some module settings failed to restore (F9 console)", Type = "error" })
  end
  return #errors == 0, count
end
function Nova:Snapshot()
  local data = {}
  -- Retain settings of modules absent in this place, or still downloading.
  for flag, value in pairs(Nova._loaded) do
    if not Nova._aliases[flag] then data[flag] = value end
  end
  for flag, value in pairs(Nova.Flags) do
    if Nova._setters[flag] or data[flag] == nil then data[flag] = encVal(value) end
  end
  for flag in pairs(Nova._nilFlags) do
    if Nova._setters[flag] or data[flag] == nil then data[flag] = encVal(nil) end
  end
  data.__version, data.__theme = 2, Nova.ThemeName
  data.__windows = {}
  for _, win in ipairs(Nova._wins) do data.__windows[win.ConfigId] = win:GetLayout() end
  return data
end
function Nova:Save(name)
  local valid, err = configName(name)
  if not valid then Nova:Notify({ Title = "Config", Text = err, Type = "error" }); return false end
  local ok, data = pcall(function() return Nova:Snapshot() end)
  if not ok then Nova:Notify({ Title = "Config", Text = tostring(data), Type = "error" }); return false end
  data.huma_cfg = valid
  local saved, storage = writeConfigFile(valid, data)
  if not saved then
    Nova:Notify({ Title = "Config", Text = "Could not save to disk: " .. storage, Type = "error" })
    return false
  end
  local selected, selectionErr = writeConfigFile("__autoload", { name = valid })
  if not selected then
    Nova:Notify({ Title = "Config", Text = "Saved, but could not enable autoload: " .. selectionErr, Type = "error" })
    return false
  end
  Nova.ActiveConfig, Nova._loaded = valid, data
  Nova:SetFlag("huma_cfg", valid)
  Nova:Notify({ Title = "Config", Type = storage == "disk" and "ok" or "warn",
    Text = storage == "disk" and ("Saved '" .. valid .. "' · autoload enabled")
      or "Saved for this session only: executor file access is unavailable" })
  return true, storage
end
function Nova:Load(name, options)
  options = options or {}
  local valid, err = configName(name)
  if not valid then Nova:Notify({ Title = "Config", Text = err, Type = "error" }); return false end
  local data, readErr = readConfigFile(valid)
  if not data then
    if not (options.Optional and readErr == "missing") then
      Nova:Notify({ Title = "Config", Text = readErr == "missing" and ("Not found: " .. valid) or readErr, Type = "error" })
    end
    return false
  end
  if data.__version and data.__version ~= 2 then
    Nova:Notify({ Title = "Config", Text = "Unsupported config version", Type = "error" }); return false
  end
  Nova._loaded = data
  Nova.ActiveConfig = valid
  local count, errors = applySetters(Nova._setters)
  if type(data.__windows) == "table" then
    for _, win in ipairs(Nova._wins) do win:SetLayout(data.__windows[win.ConfigId]) end
  end
  Nova:SetFlag("huma_cfg", valid)
  if #errors > 0 then
    warn("[NovaUI] config: " .. table.concat(errors, "\n"))
    Nova:Notify({ Title = "Config", Text = "Loaded with " .. #errors .. " errors (F9 console)", Type = "error" })
    return false
  end
  if not options.Auto then
    local ok, why = writeConfigFile("__autoload", { name = valid })
    if not ok then
      Nova:Notify({ Title = "Config", Text = "Loaded, but autoload could not be saved: " .. why, Type = "error" })
      return false
    end
  end
  if not options.Quiet then
    Nova:Notify({ Title = "Config", Text = "Loaded '" .. valid .. "' (" .. count .. ")", Type = "ok" })
  end
  return true
end
function Nova:LoadAuto()
  local selected, err = readConfigFile("__autoload")
  if not selected and err ~= "missing" then
    Nova:Notify({ Title = "Config", Text = err, Type = "error" })
  end
  return Nova:Load(selected and selected.name or "default", { Auto = true, Optional = true, Quiet = true })
end
function Nova:GetFlag(flag, fallback)
  local v = Nova.Flags[flag]
  if v == nil then return fallback end
  return v
end
function Nova:SetFlag(flag, v)
  local set = Nova._setters[flag]
  if set then
    local ok, err = pcall(set, v)
    if not ok then warn("[NovaUI] flag " .. flag .. ": " .. tostring(err)) end
    return ok
  end
  Nova.Flags[flag] = v
  Nova._nilFlags[flag] = v == nil or nil
  Nova._loaded[flag] = encVal(v)
  return true
end

function Nova:UnloadAll()
  while #Nova._wins > 0 do Nova._wins[1]:Unload() end
  pcall(function() if _notifHolder then _notifHolder:Destroy() end end)
  _notifHolder = nil
end

print("[NovaUI] v" .. Nova.Version .. " loaded (delta-drag)")
return Nova
