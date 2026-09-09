--[[
  NovaUI v0.3.0 — single-file UI library for Roblox app interfaces.
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

  Controls: Label, Paragraph, Divider, Space, Button, Toggle, Slider, Dropdown
            (single + multi), Segmented, Keybind, Color, TextBox, Progress.
            Sections are collapsible; every control takes an optional Tooltip.

  Windows: win:Tab / win:Notify / win:Dialog / win:SetVisible / win:SetScale /
           win:Unload. Windows are draggable and resizable.

  Theming: Nova:SetTheme("Dark" | "Mono" | "Midnight" | "Light" | customTable).
           Theme changes cross-fade every painted instance.

  Design notes (v0.3.0):
    - flat minimal surfaces, one accent, hairline borders, generous padding
    - Inter type ramp (with Gotham fallback), monospaced numerals for values
    - popups (dropdown/color) live in a window overlay, so they never get
      clipped by a collapsed section or a scrolling page
]]
local Nova = {}
Nova.Version = "0.3.0"
Nova.Flags = {}      -- live values, keyed by Flag (or auto Name)
Nova._setters = {}   -- Flag -> function(value) applied on config load
Nova._paint = {}     -- { o = Instance, k = kind, t = token } repainted by SetTheme
Nova._wins = {}

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
-- Inter where the client ships it, Gotham otherwise; numerals are monospaced
-- so sliders and counters do not twitch as digits change width.
local Fonts, FontFallback = {}, {
  Regular = Enum.Font.Gotham, Medium = Enum.Font.GothamMedium,
  SemiBold = Enum.Font.GothamBold, Bold = Enum.Font.GothamBold,
  Mono = Enum.Font.Code,
}
do
  local families = {
    Regular = { "Inter", "Regular" }, Medium = { "Inter", "Medium" },
    SemiBold = { "Inter", "SemiBold" }, Bold = { "Inter", "Bold" },
    Mono = { "RobotoMono", "Medium" },
  }
  for name, def in pairs(families) do
    local ok, f = pcall(function()
      return Font.new("rbxasset://fonts/families/" .. def[1] .. ".json", Enum.FontWeight[def[2]])
    end)
    if ok then Fonts[name] = f end
  end
end
local function setFont(o, weight)
  weight = weight or "Medium"
  local f = Fonts[weight]
  if f and pcall(function() o.FontFace = f end) then return o end
  pcall(function() o.Font = FontFallback[weight] or Enum.Font.GothamMedium end)
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
  if type(nameOrTable) == "string" then Nova.ThemeName = nameOrTable end
  for k, v in pairs(t) do
    Nova.Theme[ALIAS[k] or k] = v
  end
  local alive = {}
  for _, e in ipairs(Nova._paint) do
    if applyPaint(e, true) then table.insert(alive, e) end
  end
  Nova._paint = alive   -- drop entries whose instances are gone
  return true
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
-- Frame drag without the classic "jump": on grab we freeze the window's current
-- screen rect (anchor -> 0,0) and measure the grab delta with inp.Position,
-- which lives in the same space as AbsolutePosition (GetMouseLocation does
-- not — it carries the topbar inset, hence the Y teleport). All math is in
-- layout units (divided by UIScale) so win:SetScale never breaks dragging.
local function Drag(frame, handle, zoom, onStart, onEnd)
  local dragging, dx, dy = false, 0, 0
  local c1 = handle.InputBegan:Connect(function(inp)
    if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
      dragging = true
      local z = zoom()
      frame.AnchorPoint = Vector2.new(0, 0)
      frame.Position = UDim2.fromOffset(frame.AbsolutePosition.X / z, frame.AbsolutePosition.Y / z)
      dx = (inp.Position.X - frame.AbsolutePosition.X) / z
      dy = (inp.Position.Y - frame.AbsolutePosition.Y) / z
      if onStart then onStart() end
    end
  end)
  local c2 = UserInputService.InputChanged:Connect(function(inp)
    if dragging and (inp.UserInputType == Enum.UserInputType.MouseMovement or inp.UserInputType == Enum.UserInputType.Touch) then
      local z = zoom()
      local vp = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize or Vector2.new(1280, 720)
      local w, h = frame.AbsoluteSize.X / z, frame.AbsoluteSize.Y / z
      frame.Position = UDim2.fromOffset(
        clamp(inp.Position.X / z - dx, -w + 90, vp.X / z - 90),
        clamp(inp.Position.Y / z - dy, 0, vp.Y / z - 44))
    end
  end)
  local c3 = UserInputService.InputEnded:Connect(function(inp)
    if dragging and (inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch) then
      dragging = false
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
  if cb then
    local ok, err = pcall(cb, v)
    if not ok then warn("[NovaUI] callback: " .. tostring(err)) end
  end
end
local function regSetter(flag, fn) Nova._setters[flag] = fn end

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
    if not silent then fire(flag, opt.Callback, val) end
  end
  function h.Get() return val end
  row.MouseButton1Click:Connect(function() h.Set(not val) end)
  if ctx then ctx.tip(row, opt.Tooltip) end
  regSetter(flag, function(v) h.Set(v == true, false) end)
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
  regSetter(flag, function(v) h.Set(tonumber(v) or min, false) end)
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
    if not silent then fire(flag, opt.Callback, val) end
  end
  function h.Get() return val end
  ctx.tip(bar, opt.Tooltip)
  regSetter(flag, function(v) h.Set(v, false) end)
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
    if not silent then fire(flag, opt.Callback, h.Get()) end
  end
  function h.Get()
    if not multi then return val end
    local out = {}
    for _, n in ipairs(options) do if val[tostring(n)] then table.insert(out, n) end end
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
  regSetter(flag, function(v) h.Set(v, false) end)
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
    Position = UDim2.new(1, -12, 0.5, 0), Size = UDim2.fromOffset(96, 28),
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
    if not silent then fire(flag, opt.Callback, val) end
  end
  function h.Get() return val end
  function h.OnPress(fn) h._press = fn return h end

  local listening = false
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
        elseif k == Enum.KeyCode.Backspace then h.Set(nil)
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
    if type(v) == "string" and Enum.KeyCode[v] then h.Set(Enum.KeyCode[v], false)
    else h.Set(nil, true); Nova.Flags[flag] = nil end
  end)
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
  tb.Focused:Connect(function() Tween(ring, { Transparency = 0.1 }, M.base) end)
  tb.FocusLost:Connect(function(enter)
    Tween(ring, { Transparency = 1 }, M.base)
    Nova.Flags[flag] = tb.Text
    if (enter or opt.FireOnAnyLoss) and opt.Callback then
      local ok, err = pcall(opt.Callback, tb.Text)
      if not ok then warn("[NovaUI] textbox: " .. tostring(err)) end
    end
  end)
  if opt.Live then
    tb:GetPropertyChangedSignal("Text"):Connect(function()
      Nova.Flags[flag] = tb.Text
      if opt.Callback then pcall(opt.Callback, tb.Text) end
    end)
  end
  ctx.tip(tb, opt.Tooltip)
  local h = { Instance = wrap }
  function h.Set(v) tb.Text = tostring(v or ""); Nova.Flags[flag] = tb.Text end
  function h.Get() return tb.Text end
  regSetter(flag, function(v) tb.Text = tostring(v or "") end)
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
  regSetter(flag, function(v) if typeof(v) == "Color3" then h.Set(v, false) end end)
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
  local closeB = headBtn("✕", -16, true)
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
  function win:SetTitle(t) title.Text = tostring(t) end
  function win:Notify(n) return Nova:Notify(n) end

  local tkey = opts.Keybind == nil and Enum.KeyCode.RightShift or opts.Keybind
  if tkey then
    ctx.bind(UserInputService.InputBegan:Connect(function(inp, gpe)
      if not gpe and inp.KeyCode == tkey and UserInputService:GetFocusedTextBox() == nil then
        win:Toggle()
      end
    end))
  end
  themeB.MouseButton1Click:Connect(function()
    local name = Nova:NextTheme()
    Nova:Notify({ Title = "Theme", Text = name, Type = "info", Duration = 1.6 })
  end)
  hideB.MouseButton1Click:Connect(function() win:SetVisible(false) end)
  closeB.MouseButton1Click:Connect(function() win:Unload() end)

  function win:Unload()
    for _, c in ipairs(win._conns) do pcall(function() c:Disconnect() end) end
    for i, w in ipairs(Nova._wins) do if w == win then table.remove(Nova._wins, i) break end end
    Tween(shellPop, { Scale = 0.97 }, M.exit)
    local tw = Tween(shell, { GroupTransparency = 1 }, M.exit)
    tw.Completed:Connect(function() pcall(function() sg:Destroy() end) end)
    if opts.OnUnload then pcall(opts.OnUnload) end
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
    if #win._tabs == 1 then task.defer(tab.Select) end

    --// sections ------------------------------------------------------------
    function tab:Section(sopt)
      sopt = sopt or {}
      local box = New("Frame", {
        BackgroundColor3 = T.Surface, BorderSizePixel = 0,
        Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
      }, page)
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
      function sec:Toggle(o) return addToggle(inner, o or {}, ctx) end
      function sec:Slider(o) return addSlider(inner, o or {}, ctx) end
      function sec:Dropdown(o) return addDropdown(inner, o or {}, ctx) end
      function sec:MultiDropdown(o) o = o or {}; o.Multi = true; return addDropdown(inner, o, ctx) end
      function sec:Segmented(o) return addSegmented(inner, o or {}, ctx) end
      function sec:Keybind(o) return addKeybind(inner, o or {}, ctx) end
      function sec:Color(o) return addColor(inner, o or {}, ctx) end
      function sec:TextBox(o) return addTextBox(inner, o or {}, ctx) end
      function sec:Progress(o) return addProgress(inner, o or {}) end
      function sec:SetCollapsed(v) setCollapsed(v == true) end
      function sec:IsCollapsed() return collapsed end
      if sopt.Collapsed then task.defer(function() sec:SetCollapsed(true) end) end
      return sec
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

--// Config save/load (disk persistence when the host allows it, memory fallback) -
Nova._memCfg = {}
local function canFile()
  return type(writefile) == "function" and type(readfile) == "function" and type(isfile) == "function"
end
local function encVal(v)
  if typeof and typeof(v) == "Color3" then
    return { t = "c3", v = { math.floor(v.R * 255 + 0.5), math.floor(v.G * 255 + 0.5), math.floor(v.B * 255 + 0.5) } }
  end
  if type(v) == "table" then
    local out = {}
    for i, x in ipairs(v) do out[i] = tostring(x) end
    return { t = "list", v = out }
  end
  if type(v) == "userdata" and tostring(v):find("Enum") then
    local ok, name = pcall(function() return v.Name end)
    if ok then return { t = "enum", v = name } end
  end
  if type(v) == "number" or type(v) == "string" or type(v) == "boolean" then return v end
  return nil
end
local function decVal(v)
  if type(v) == "table" and v.t == "c3" and type(v.v) == "table" then
    return Color3.fromRGB(v.v[1] or 0, v.v[2] or 0, v.v[3] or 0)
  end
  if type(v) == "table" and v.t == "list" then return v.v end
  if type(v) == "table" and v.t == "enum" then return v.v end -- setter resolves KeyCode
  return v
end
function Nova:Save(name)
  name = name or "default"
  local data = {}
  for flag, v in pairs(Nova.Flags) do data[flag] = encVal(v) end
  data.__theme = Nova.ThemeName
  local json = HttpService:JSONEncode(data)
  if canFile() then
    pcall(function()
      if makefolder and isfolder and not isfolder("NovaUI") then makefolder("NovaUI") end
      writefile("NovaUI/" .. tostring(name) .. ".json", json)
    end)
  else
    Nova._memCfg[name] = json
  end
  Nova:Notify({ Title = "Config", Text = "Saved '" .. tostring(name) .. "'", Type = "ok" })
end
function Nova:Load(name)
  name = name or "default"
  local json
  if canFile() then
    local ok, c = pcall(readfile, "NovaUI/" .. tostring(name) .. ".json")
    if ok then json = c end
  else
    json = Nova._memCfg[name]
  end
  if not json then
    Nova:Notify({ Title = "Config", Text = "Not found: " .. tostring(name), Type = "error" })
    return false
  end
  local ok, data = pcall(HttpService.JSONDecode, HttpService, json)
  if not ok or type(data) ~= "table" then return false end
  if data.__theme and Nova.Themes[data.__theme] then Nova:SetTheme(data.__theme) end
  local n = 0
  for flag, v in pairs(data) do
    local set = Nova._setters[flag]
    if set then local s = pcall(set, decVal(v)); if s then n = n + 1 end end
  end
  Nova:Notify({ Title = "Config", Text = "Loaded '" .. tostring(name) .. "' (" .. n .. ")", Type = "ok" })
  return true
end
function Nova:GetFlag(flag, fallback)
  local v = Nova.Flags[flag]
  if v == nil then return fallback end
  return v
end
function Nova:SetFlag(flag, v)
  local set = Nova._setters[flag]
  if set then pcall(set, v) else Nova.Flags[flag] = v end
end
function Nova:UnloadAll()
  while #Nova._wins > 0 do Nova._wins[1]:Unload() end
  pcall(function() if _notifHolder then _notifHolder:Destroy() end end)
  _notifHolder = nil
end

return Nova
