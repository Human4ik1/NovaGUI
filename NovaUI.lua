--[[
  NovaUI v0.1.0 — single-file UI framework for Roblox cheat scripts.
  Zero dependencies, executor-friendly, loadstring-ready.

  GitHub usage (pin a version tag, not main):
    local Nova = loadstring(game:HttpGet(
      "https://raw.githubusercontent.com/<USER>/NovaUI/v0.1.0/NovaUI.lua"))()

  Local dev fallback:
    local Nova = loadstring(readfile("NovaUI.lua"))()

  Quick start:
    local win = Nova:Window({ Title = "My cheat", Subtitle = "v1.0" })
    local tab = win:Tab({ Name = "Combat", Icon = "+" })
    local sec = tab:Section({ Name = "Aimbot" })
    sec:Toggle({ Name = "Enabled", Flag = "aim_on", Callback = print })
    sec:Slider({ Name = "FOV", Min = 0, Max = 500, Default = 120, Flag = "aim_fov" })
    -- read anywhere: Nova.Flags.aim_on, Nova.Flags.aim_fov
    -- persist: Nova:Save("default") / Nova:Load("default")

  Controls: Label, Paragraph, Divider, Button, Toggle, Slider, Dropdown,
            Keybind, Color, TextBox. Sections are collapsible.
  Theming: Nova:SetTheme("Dark" | "Midnight" | "Light" | customTable).
]]
local Nova = {}
Nova.Version = "0.1.0"
Nova.Flags = {}      -- live values, keyed by Flag (or auto Name)
Nova._setters = {}   -- Flag -> function(value) applied on config load
Nova._paint = {}     -- { o = Instance, role = string } repainted by SetTheme
Nova._wins = {}

--// Services ---------------------------------------------------------------
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local LocalPlayer = Players.LocalPlayer

--// Themes -----------------------------------------------------------------
Nova.Themes = {
  Dark = {
    Bg = Color3.fromRGB(15, 16, 22), Bg2 = Color3.fromRGB(21, 23, 32),
    Row = Color3.fromRGB(30, 33, 46), Hover = Color3.fromRGB(38, 41, 56),
    Accent = Color3.fromRGB(124, 92, 255), Accent2 = Color3.fromRGB(56, 208, 255),
    Text = Color3.fromRGB(228, 233, 246), Dim = Color3.fromRGB(126, 133, 155),
    Good = Color3.fromRGB(80, 220, 140), Warn = Color3.fromRGB(255, 190, 90),
    Danger = Color3.fromRGB(255, 110, 130),
  },
  Midnight = {
    Bg = Color3.fromRGB(8, 10, 18), Bg2 = Color3.fromRGB(13, 16, 26),
    Row = Color3.fromRGB(20, 24, 38), Hover = Color3.fromRGB(28, 33, 50),
    Accent = Color3.fromRGB(56, 208, 255), Accent2 = Color3.fromRGB(124, 92, 255),
    Text = Color3.fromRGB(220, 232, 245), Dim = Color3.fromRGB(110, 120, 145),
    Good = Color3.fromRGB(80, 220, 140), Warn = Color3.fromRGB(255, 190, 90),
    Danger = Color3.fromRGB(255, 110, 130),
  },
  Light = {
    Bg = Color3.fromRGB(238, 240, 245), Bg2 = Color3.fromRGB(255, 255, 255),
    Row = Color3.fromRGB(228, 231, 238), Hover = Color3.fromRGB(214, 218, 228),
    Accent = Color3.fromRGB(108, 80, 230), Accent2 = Color3.fromRGB(20, 160, 220),
    Text = Color3.fromRGB(28, 30, 40), Dim = Color3.fromRGB(120, 126, 142),
    Good = Color3.fromRGB(30, 170, 90), Warn = Color3.fromRGB(200, 130, 20),
    Danger = Color3.fromRGB(220, 70, 95),
  },
}
Nova.ThemeName = "Dark"
Nova.Theme = {}
for k, v in pairs(Nova.Themes.Dark) do Nova.Theme[k] = v end

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
local function Stroke(p, color, t, tr)
  return New("UIStroke", { Color = color, Thickness = t or 1, Transparency = tr == nil and 0.75 or tr, BorderSizePixel = 0 }, p)
end
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
    HorizontalAlignment = Enum.HorizontalAlignment.Center,
    VerticalAlignment = Enum.VerticalAlignment.Top,
  }, p)
end
local function Tween(obj, props, t, style, dir)
  local tw = TweenService:Create(obj,
    TweenInfo.new(t or 0.18, Enum.EasingStyle[style or "Quad"], Enum.EasingDirection[dir or "Out"]), props)
  tw:Play()
  return tw
end
local function Ripple(btn)
  btn.ClipsDescendants = true
  btn.MouseButton1Down:Connect(function(x, y)
    local d = math.max(btn.AbsoluteSize.X, btn.AbsoluteSize.Y) * 2.2
    local c = New("Frame", {
      BackgroundColor3 = Color3.fromRGB(255, 255, 255), BackgroundTransparency = 0.75,
      BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5),
      Size = UDim2.fromOffset(0, 0), Position = UDim2.fromOffset(x - btn.AbsolutePosition.X, y - btn.AbsolutePosition.Y),
      ZIndex = btn.ZIndex + 1,
    }, btn)
    Corner(c, 999)
    Tween(c, { Size = UDim2.fromOffset(d, d), BackgroundTransparency = 1 }, 0.45, "Quad", "Out")
    task.delay(0.5, function() c:Destroy() end)
  end)
end
local function Drag(frame, handle)
  local dragging, dx, dy = false, 0, 0
  handle.InputBegan:Connect(function(inp)
    if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
      dragging = true
      local mp = UserInputService:GetMouseLocation()
      dx, dy = mp.X - frame.AbsolutePosition.X, mp.Y - frame.AbsolutePosition.Y
    end
  end)
  UserInputService.InputChanged:Connect(function(inp)
    if dragging and (inp.UserInputType == Enum.UserInputType.MouseMovement or inp.UserInputType == Enum.UserInputType.Touch) then
      local mp = UserInputService:GetMouseLocation()
      local vp = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize or Vector2.new(1280, 720)
      local w, h = frame.AbsoluteSize.X, frame.AbsoluteSize.Y
      frame.Position = UDim2.fromOffset(clamp(mp.X - dx, -w + 80, vp.X - 80), clamp(mp.Y - dy, 0, vp.Y - 40))
    end
  end)
  UserInputService.InputEnded:Connect(function(inp)
    if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
      dragging = false
    end
  end)
end
-- role -> property repaint on theme change. roles: bg,bg2,row,hover,accent,
-- accent2,text,dim,good,warn,danger,grad(grad=ColorSequence accent->accent2)
local function Paint(obj, role)
  table.insert(Nova._paint, { o = obj, r = role })
  return obj
end
local function applyPaint(e)
  local T, o = Nova.Theme, e.o
  if not o then return end
  local ok = pcall(function()
    local r = e.r
    if r == "grad" then o.Color = ColorSequence.new(T.Accent, T.Accent2)
    elseif r == "text" or r == "dim" or r == "accent" or r == "accent2"
      or r == "good" or r == "warn" or r == "danger" then
      local map = { text = T.Text, dim = T.Dim, accent = T.Accent, accent2 = T.Accent2,
        good = T.Good, warn = T.Warn, danger = T.Danger }
      if o:IsA("TextLabel") or o:IsA("TextButton") or o:IsA("TextBox") then o.TextColor3 = map[r]
      elseif o:IsA("UIStroke") then o.Color = map[r]
      elseif o:IsA("ImageLabel") or o:IsA("ImageButton") then o.ImageColor3 = map[r] end
    else
      local map = { bg = T.Bg, bg2 = T.Bg2, row = T.Row, hover = T.Hover,
        accentbg = T.Accent }
      if r == "accentbg" then o.BackgroundColor3 = T.Accent
      elseif map[r] then o.BackgroundColor3 = map[r] end
    end
  end)
end
function Nova:SetTheme(nameOrTable)
  local t = type(nameOrTable) == "string" and Nova.Themes[nameOrTable] or nameOrTable
  if type(t) ~= "table" then return false end
  if type(nameOrTable) == "string" then Nova.ThemeName = nameOrTable end
  for k, v in pairs(t) do Nova.Theme[k] = v end
  for _, e in ipairs(Nova._paint) do applyPaint(e) end
  return true
end
local function Txt(parent, text, size, role, font, xalign)
  return New("TextLabel", {
    Text = text, TextSize = size or 13, Font = font or Enum.Font.GothamMedium,
    TextColor3 = Nova.Theme[role == "dim" and "Dim" or "Text"],
    TextXAlignment = xalign or Enum.TextXAlignment.Left,
    BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, size and (size + 6) or 20),
  }, parent)
end
local function mountGui(name)
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
local _notifHolder = nil
local function notifHolder(sg)
  if _notifHolder and _notifHolder.Parent then return _notifHolder end
  local h = New("Frame", {
    BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0),
    Position = UDim2.new(1, -16, 0, 16), Size = UDim2.new(0, 270, 1, -32),
  }, sg)
  _notifHolder = h
  return h
end
function Nova:Notify(opts)
  opts = opts or {}
  local sg = (Nova._wins[1] and Nova._wins[1]._sg) or mountGui("NovaUI_Notify")
  local h = notifHolder(sg)
  local T = Nova.Theme
  local bar = { info = T.Accent, ok = T.Good, warn = T.Warn, error = T.Danger }
  local card = New("Frame", {
    BackgroundColor3 = T.Bg2, BorderSizePixel = 0,
    Size = UDim2.new(0, 270, 0, 58),
  }, h)
  Paint(card, "bg2"); Corner(card, 10); Stroke(card, T.Accent, 1, 0.8)
  _notifN = (_notifN or 0) + 1
  card.LayoutOrder = _notifN
  local stackY = 0
  for _, ch in ipairs(h:GetChildren()) do
    if ch:IsA("Frame") and ch ~= card then
      stackY = stackY + ch.Size.Y.Offset + 8
    end
  end
  local strip = New("Frame", {
    BackgroundColor3 = bar[opts.Type] or T.Accent, BorderSizePixel = 0,
    Size = UDim2.new(0, 4, 1, -16), Position = UDim2.new(0, 8, 0, 8),
  }, card)
  Corner(strip, 4)
  local tt = Txt(card, opts.Title or "Nova", 13, "text", Enum.Font.GothamBold)
  tt.Position, tt.Size = UDim2.new(0, 20, 0, 6), UDim2.new(1, -30, 0, 18)
  local bt = Txt(card, opts.Text or "", 11, "dim")
  bt.Position, bt.Size = UDim2.new(0, 20, 0, 24), UDim2.new(1, -30, 0, 26)
  bt.TextWrapped = true
  card.Position = UDim2.new(0, 300, 0, stackY)
  Tween(card, { Position = UDim2.new(0, 0, 0, stackY) }, 0.3, "Back")
  task.delay(opts.Duration or 4, function()
    Tween(card, { Position = UDim2.new(0, 300, 0, card.Position.Y.Offset) }, 0.25, "Quad", "In")
    task.wait(0.26)
    pcall(function() card:Destroy() end)
    local rest = {}
    for _, ch in ipairs(h:GetChildren()) do
      if ch:IsA("Frame") then table.insert(rest, ch) end
    end
    table.sort(rest, function(a, b) return a.LayoutOrder < b.LayoutOrder end)
    local y = 0
    for _, ch in ipairs(rest) do
      Tween(ch, { Position = UDim2.new(0, ch.Position.X.Offset, 0, y) }, 0.2)
      y = y + ch.Size.Y.Offset + 8
    end
  end)
end

--// Control builders (parent = section body frame) -------------------------
local function fire(opt, v)
  Nova.Flags[opt.Flag] = v
  if opt.Callback then
    local ok, err = pcall(opt.Callback, v)
    if not ok then warn("[NovaUI] callback: " .. tostring(err)) end
  end
end
local function regSetter(flag, fn) Nova._setters[flag] = fn end

local function addLabel(parent, text, size, dim)
  local l = Txt(parent, text, size or 12, dim and "dim" or "text")
  l.TextWrapped = true; l.Size = UDim2.new(1, 0, 0, 0); l.AutomaticSize = Enum.AutomaticSize.Y
  return l
end
local function addDivider(parent)
  local d = New("Frame", {
    BackgroundColor3 = Nova.Theme.Dim, BackgroundTransparency = 0.75,
    BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 1),
  }, parent)
  return d
end
local function addButton(parent, opt)
  local T = Nova.Theme
  local b = New("TextButton", {
    Text = "", AutoButtonColor = false, BorderSizePixel = 0,
    BackgroundColor3 = opt.Variant == "ghost" and T.Row or (opt.Variant == "danger" and T.Danger or T.Accent),
    Size = UDim2.new(1, 0, 0, 36),
  }, parent)
  Paint(b, opt.Variant == "ghost" and "row" or (opt.Variant == "danger" and "danger" or "accentbg"))
  Corner(b, 10)
  local l = New("TextLabel", {
    Text = opt.Name or "Button", Font = Enum.Font.GothamBold, TextSize = 13,
    TextColor3 = opt.Variant == "ghost" and T.Text or Color3.fromRGB(255, 255, 255),
    BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1),
  }, b)
  if opt.Variant == "ghost" then Paint(l, "text") end
  b.MouseEnter:Connect(function() Tween(b, { BackgroundTransparency = 0.12 }, 0.12) end)
  b.MouseLeave:Connect(function() Tween(b, { BackgroundTransparency = 0 }, 0.12) end)
  b.MouseButton1Down:Connect(function() Tween(b, { Size = UDim2.new(1, -4, 0, 34) }, 0.08) end)
  b.MouseButton1Up:Connect(function() Tween(b, { Size = UDim2.new(1, 0, 0, 36) }, 0.1) end)
  Ripple(b)
  b.MouseButton1Click:Connect(function()
    if opt.Callback then local ok, err = pcall(opt.Callback)
      if not ok then warn("[NovaUI] button: " .. tostring(err)) end end
  end)
  return b
end
local function addToggle(parent, opt)
  local T = Nova.Theme
  local flag = opt.Flag or autoFlag(opt.Name)
  local val = opt.Default == true
  local row = New("TextButton", {
    Text = "", AutoButtonColor = false, BorderSizePixel = 0,
    BackgroundColor3 = T.Row, Size = UDim2.new(1, 0, 0, opt.Desc and 50 or 38),
  }, parent)
  Paint(row, "row"); Corner(row, 10); Pad(row, 12, 0, 12, 0)
  local tt = Txt(row, opt.Name or "Toggle", 13, "text", Enum.Font.GothamMedium)
  tt.Size = UDim2.new(1, -70, 0, 20); tt.Position = UDim2.new(0, 12, 0, opt.Desc and 4 or 9)
  if opt.Desc then
    local dd = Txt(row, opt.Desc, 11, "dim")
    dd.Size = UDim2.new(1, -70, 0, 16); dd.Position = UDim2.new(0, 12, 0, 26)
  end
  local sw = New("Frame", {
    BackgroundColor3 = T.Bg, BorderSizePixel = 0, ClipsDescendants = false,
    AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -12, 0.5, 0),
    Size = UDim2.fromOffset(44, 24),
  }, row)
  Corner(sw, 12); Stroke(sw, T.Dim, 1, 0.6)
  local knob = New("Frame", {
    BackgroundColor3 = T.Dim, BorderSizePixel = 0,
    Size = UDim2.fromOffset(18, 18), Position = UDim2.fromOffset(3, 3),
  }, sw)
  Corner(knob, 9)
  local h = {}
  function h.Set(v, silent)
    val = v == true
    Tween(sw, { BackgroundColor3 = val and T.Accent or T.Bg }, 0.18)
    Tween(knob, {
      Position = val and UDim2.fromOffset(23, 3) or UDim2.fromOffset(3, 3),
      BackgroundColor3 = val and Color3.fromRGB(255, 255, 255) or T.Dim,
    }, 0.18, "Back")
    if not silent then fire({ Flag = flag, Callback = opt.Callback }, val) end
  end
  function h.Get() return val end
  row.MouseButton1Click:Connect(function() h.Set(not val) end)
  regSetter(flag, function(v) h.Set(v == true, false) end)
  h.Set(val, true); Nova.Flags[flag] = val
  return h
end
local function addSlider(parent, opt)
  local T = Nova.Theme
  local flag = opt.Flag or autoFlag(opt.Name)
  local min, max = opt.Min or 0, opt.Max or 100
  local dec = opt.Decimals or 0
  local val = clamp(opt.Default == nil and min or opt.Default, min, max)
  local wrap = New("Frame", {
    BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 52),
  }, parent)
  local tt = Txt(wrap, opt.Name or "Slider", 13, "text", Enum.Font.GothamMedium)
  tt.Size = UDim2.new(1, -80, 0, 18)
  local vv = Txt(wrap, "", 13, "dim", Enum.Font.GothamBold, Enum.TextXAlignment.Right)
  vv.Size = UDim2.new(1, 0, 0, 18)
  local track = New("TextButton", {
    Text = "", AutoButtonColor = false, BorderSizePixel = 0,
    BackgroundColor3 = T.Bg, Size = UDim2.new(1, -4, 0, 8),
    Position = UDim2.new(0, 2, 0, 32),
  }, wrap)
  Corner(track, 4)
  local fill = New("Frame", {
    BackgroundColor3 = T.Accent, BorderSizePixel = 0,
    Size = UDim2.fromScale(0, 1),
  }, track)
  Paint(fill, "accentbg"); Corner(fill, 4)
  New("UIGradient", { Color = ColorSequence.new(T.Accent, T.Accent2), Rotation = 0 }, fill)
  local knob = New("Frame", {
    BackgroundColor3 = Color3.fromRGB(255, 255, 255), BorderSizePixel = 0,
    AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(14, 14),
    Position = UDim2.fromScale(0, 0.5),
  }, track)
  Corner(knob, 7)
  Stroke(knob, T.Accent, 2, 0)
  local hit = New("TextButton", {
    Text = "", BackgroundTransparency = 1, BorderSizePixel = 0,
    Size = UDim2.new(1, 0, 0, 24), Position = UDim2.new(0, 0, 0, 24),
  }, wrap)
  local h = {}
  function h.Set(v, silent)
    val = clamp(round(v, dec), min, max)
    local r = (max == min) and 0 or ((val - min) / (max - min))
    fill.Size = UDim2.fromScale(r, 1)
    knob.Position = UDim2.new(r, 0, 0.5, 0)
    vv.Text = tostring(val) .. (opt.Suffix or "")
    if not silent then fire({ Flag = flag, Callback = opt.Callback }, val) end
  end
  function h.Get() return val end
  local dragging = false
  local function fromX(x)
    local p, s = track.AbsolutePosition.X, track.AbsoluteSize.X
    if s <= 0 then return end
    h.Set(min + clamp((x - p) / s, 0, 1) * (max - min))
  end
  hit.InputBegan:Connect(function(inp)
    if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
      dragging = true; fromX(inp.Position.X)
    end
  end)
  UserInputService.InputChanged:Connect(function(inp)
    if dragging and (inp.UserInputType == Enum.UserInputType.MouseMovement or inp.UserInputType == Enum.UserInputType.Touch) then
      fromX(inp.Position.X)
    end
  end)
  UserInputService.InputEnded:Connect(function(inp)
    if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
      dragging = false
    end
  end)
  regSetter(flag, function(v) h.Set(tonumber(v) or min, false) end)
  h.Set(val, true); Nova.Flags[flag] = val
  return h
end
local function addDropdown(parent, opt, win)
  local T = Nova.Theme
  local flag = opt.Flag or autoFlag(opt.Name)
  local options = opt.Options or {}
  local val = opt.Default ~= nil and opt.Default or options[1]
  local wrap = New("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 62) }, parent)
  Txt(wrap, opt.Name or "Dropdown", 13, "text", Enum.Font.GothamMedium).Size = UDim2.new(1, 0, 0, 18)
  local btn = New("TextButton", {
    Text = "", AutoButtonColor = false, BorderSizePixel = 0,
    BackgroundColor3 = T.Row, Size = UDim2.new(1, 0, 0, 34), Position = UDim2.new(0, 0, 0, 22),
  }, wrap)
  Paint(btn, "row"); Corner(btn, 10); Pad(btn, 12, 0, 12, 0)
  local cur = Txt(btn, tostring(val), 13, "text")
  cur.Size = UDim2.new(1, -30, 1, 0); cur.Position = UDim2.new(0, 12, 0, 0)
  local chev = Txt(btn, "▾", 16, "dim", Enum.Font.GothamBold, Enum.TextXAlignment.Right)
  chev.Size = UDim2.new(1, -12, 1, 0)
  local h = {}
  local rowH, maxH = 30, (opt.MaxVisible or 5) * 30 + 8
  local listH = clamp(#options * rowH + 8, 8, maxH)
  local list = New("Frame", {
    BackgroundColor3 = T.Bg, BorderSizePixel = 0, ClipsDescendants = true,
    Size = UDim2.new(1, 0, 0, 0), Position = UDim2.new(0, 0, 0, 60), Visible = false, ZIndex = 5,
  }, wrap)
  Corner(list, 10); Stroke(list, T.Accent, 1, 0.7); Pad(list, 4, 4, 4, 4)
  local ll = List(list, 2); ll.HorizontalAlignment = Enum.HorizontalAlignment.Left
  for _, name in ipairs(options) do
    local ob = New("TextButton", {
      Text = "  " .. tostring(name), Font = Enum.Font.GothamMedium, TextSize = 12,
      TextColor3 = T.Text, TextXAlignment = Enum.TextXAlignment.Left,
      BackgroundColor3 = T.Bg, BorderSizePixel = 0, AutoButtonColor = false,
      Size = UDim2.new(1, 0, 0, rowH),
    }, list)
    Corner(ob, 6)
    ob.MouseEnter:Connect(function() ob.BackgroundColor3 = T.Hover end)
    ob.MouseLeave:Connect(function() ob.BackgroundColor3 = T.Bg end)
    ob.MouseButton1Click:Connect(function() h.Set(name) ; h.Close() end)
  end
  local open = false
  function h.Set(v, silent)
    val = v; cur.Text = tostring(v)
    if not silent then fire({ Flag = flag, Callback = opt.Callback }, val) end
  end
  function h.Get() return val end
  function h.Close()
    if not open then return end
    open = false
    Tween(chev, { Rotation = 0 }, 0.15)
    local tw = Tween(list, { Size = UDim2.new(1, 0, 0, 0) }, 0.15)
    tw.Completed:Connect(function() if not open then list.Visible = false end end)
  end
  function h.Open()
    for _, dd in ipairs(win._dropdowns) do if dd ~= h then dd.Close() end end
    open = true; list.Visible = true
    Tween(chev, { Rotation = 180 }, 0.15)
    Tween(list, { Size = UDim2.new(1, 0, 0, listH) }, 0.2, "Back")
  end
  btn.MouseButton1Click:Connect(function() if open then h.Close() else h.Open() end end)
  table.insert(win._dropdowns, h)
  regSetter(flag, function(v) h.Set(v, false) end)
  h.Set(val, true); Nova.Flags[flag] = val
  return h
end
local function addKeybind(parent, opt)
  local T = Nova.Theme
  local flag = opt.Flag or autoFlag(opt.Name)
  local val = opt.Default -- Enum.KeyCode or nil
  local wrap = New("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 38) }, parent)
  local tt = Txt(wrap, opt.Name or "Keybind", 13, "text", Enum.Font.GothamMedium)
  tt.Size = UDim2.new(1, -110, 1, 0)
  local box = New("TextButton", {
    Text = val and val.Name or "NONE", Font = Enum.Font.GothamBold, TextSize = 12,
    TextColor3 = T.Text, AutoButtonColor = false, BorderSizePixel = 0,
    BackgroundColor3 = T.Row, AnchorPoint = Vector2.new(1, 0.5),
    Position = UDim2.new(1, 0, 0.5, 0), Size = UDim2.fromOffset(100, 30),
  }, wrap)
  Paint(box, "row"); Corner(box, 8)
  local h = { _press = nil }
  function h.Set(v, silent)
    val = v
    box.Text = (v and v.Name) or "NONE"
    if not silent then fire({ Flag = flag, Callback = opt.Callback }, val) end
  end
  function h.Get() return val end
  function h.OnPress(fn) h._press = fn return h end
  local listening = false
  box.MouseButton1Click:Connect(function()
    listening = true; box.Text = "..."
  end)
  UserInputService.InputBegan:Connect(function(inp, gpe)
    if listening and inp.UserInputType == Enum.UserInputType.Keyboard then
      listening = false
      local k = inp.KeyCode
      if k == Enum.KeyCode.Escape then box.Text = (val and val.Name) or "NONE"
      elseif k == Enum.KeyCode.Backspace then h.Set(nil)
      else h.Set(k) end
      return
    end
    if not listening and val and inp.KeyCode == val and not gpe
      and UserInputService:GetFocusedTextBox() == nil and h._press then
      local ok, err = pcall(h._press)
      if not ok then warn("[NovaUI] keybind: " .. tostring(err)) end
    end
  end)
  regSetter(flag, function(v)
    if type(v) == "string" and Enum.KeyCode[v] then h.Set(Enum.KeyCode[v], false)
    else h.Set(nil, true); Nova.Flags[flag] = nil end
  end)
  h.Set(val, true); Nova.Flags[flag] = val
  return h
end
local function addColor(parent, opt)
  local T = Nova.Theme
  local flag = opt.Flag or autoFlag(opt.Name)
  local val = opt.Default or T.Accent
  local wrap = New("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 38) }, parent)
  local tt = Txt(wrap, opt.Name or "Color", 13, "text", Enum.Font.GothamMedium)
  tt.Size = UDim2.new(1, -60, 1, 0)
  local sw = New("TextButton", {
    Text = "", AutoButtonColor = false, BorderSizePixel = 0,
    BackgroundColor3 = val, AnchorPoint = Vector2.new(1, 0.5),
    Position = UDim2.new(1, 0, 0.5, 0), Size = UDim2.fromOffset(48, 26),
  }, wrap)
  Corner(sw, 8); Stroke(sw, T.Dim, 1, 0.4)
  local pop = New("Frame", {
    BackgroundColor3 = T.Bg, BorderSizePixel = 0, Visible = false,
    Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
  }, parent)
  Corner(pop, 10); Stroke(pop, T.Accent, 1, 0.7); Pad(pop, 10, 10, 10, 10)
  List(pop, 6)
  local h = {}
  local sr, sg2, sb, lock = nil, nil, nil, false
  function h.Set(v, silent)
    val = v; sw.BackgroundColor3 = v
    if not lock and sr then
      lock = true
      sr.Set(math.floor(v.R * 255 + 0.5), true)
      sg2.Set(math.floor(v.G * 255 + 0.5), true)
      sb.Set(math.floor(v.B * 255 + 0.5), true)
      lock = false
    end
    if not silent then fire({ Flag = flag, Callback = opt.Callback }, val) end
  end
  function h.Get() return val end
  local function pull()
    if lock then return end
    h.Set(Color3.fromRGB(sr.Get(), sg2.Get(), sb.Get()))
  end
  sr = addSlider(pop, { Name = "R", Min = 0, Max = 255, Default = math.floor(val.R * 255 + 0.5), Callback = pull })
  sg2 = addSlider(pop, { Name = "G", Min = 0, Max = 255, Default = math.floor(val.G * 255 + 0.5), Callback = pull })
  sb = addSlider(pop, { Name = "B", Min = 0, Max = 255, Default = math.floor(val.B * 255 + 0.5), Callback = pull })
  sw.MouseButton1Click:Connect(function() pop.Visible = not pop.Visible end)
  regSetter(flag, function(v)
    if type(v) == "userdata" then h.Set(v, false) end
  end)
  h.Set(val, true); Nova.Flags[flag] = val
  return h
end
local function addTextBox(parent, opt)
  local T = Nova.Theme
  local flag = opt.Flag or autoFlag(opt.Name)
  local wrap = New("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 62) }, parent)
  Txt(wrap, opt.Name or "Input", 13, "text", Enum.Font.GothamMedium).Size = UDim2.new(1, 0, 0, 18)
  local tb = New("TextBox", {
    Text = opt.Default or "", PlaceholderText = opt.Placeholder or "Type here...",
    PlaceholderColor3 = T.Dim, Font = Enum.Font.GothamMedium, TextSize = 13,
    TextColor3 = T.Text, TextXAlignment = Enum.TextXAlignment.Left,
    BackgroundColor3 = T.Row, BorderSizePixel = 0, ClearTextOnFocus = false,
    Size = UDim2.new(1, 0, 0, 34), Position = UDim2.new(0, 0, 0, 22),
  }, wrap)
  Paint(tb, "row"); Corner(tb, 10); Pad(tb, 12, 0, 12, 0)
  tb.Focused:Connect(function() Stroke(tb, T.Accent, 1, 0.3).Name = "FocusStroke" end)
  tb.FocusLost:Connect(function(enter)
    local f = tb:FindFirstChild("FocusStroke"); if f then f:Destroy() end
    Nova.Flags[flag] = tb.Text
    if (enter or opt.FireOnAnyLoss) and opt.Callback then
      local ok, err = pcall(opt.Callback, tb.Text)
      if not ok then warn("[NovaUI] textbox: " .. tostring(err)) end
    end
  end)
  local h = {}
  function h.Set(v) tb.Text = tostring(v or ""); Nova.Flags[flag] = tb.Text end
  function h.Get() return tb.Text end
  regSetter(flag, function(v) tb.Text = tostring(v or "") end)
  Nova.Flags[flag] = tb.Text
  return h
end

--// Window ---------------------------------------------------------------
function Nova:Window(opts)
  opts = opts or {}
  local T = Nova.Theme
  local sg = mountGui("NovaUI_" .. tostring(opts.Title or "Window"):gsub("%W", ""))
  notifHolder(sg)
  local win = {
    _sg = sg, _conns = {}, _dropdowns = {}, _tabs = {},
    Title = opts.Title or "Nova",
  }
  local cont = New("Frame", {
    BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.fromScale(0.5, 0.5), Size = opts.Size or UDim2.fromOffset(620, 440),
  }, sg)
  local scale = New("UIScale", { Scale = 1 }, cont)
  local shell = New("CanvasGroup", {
    BackgroundColor3 = T.Bg, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1),
    GroupTransparency = 0,
  }, cont)
  Paint(shell, "bg"); Corner(shell, 14); Stroke(shell, T.Accent, 1.4, 0.35)
  -- shadow
  local sh = New("ImageLabel", {
    BackgroundTransparency = 1, Image = "rbxassetid://5028857084",
    ScaleType = Enum.ScaleType.Slice, SliceCenter = Rect.new(24, 24, 148, 148),
    ImageColor3 = Color3.fromRGB(0, 0, 0), ImageTransparency = 0.6,
    AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
    Size = UDim2.new(1, 30, 1, 30), ZIndex = 0,
  }, cont)
  sh.LayoutOrder = -1
  -- header
  local head = New("Frame", {
    BackgroundColor3 = T.Bg2, BorderSizePixel = 0,
    Size = UDim2.new(1, 0, 0, 56), Active = true,
  }, shell)
  Paint(head, "bg2"); Corner(head, 14)
  local headFix = New("Frame", {
    BackgroundColor3 = T.Bg2, BorderSizePixel = 0,
    Size = UDim2.new(1, 0, 0, 14), Position = UDim2.new(0, 0, 1, -14),
  }, head)
  Paint(headFix, "bg2"); headFix.ZIndex = 0
  local title = New("TextLabel", {
    Text = opts.Title or "NOVA", Font = Enum.Font.GothamBold, TextSize = 18,
    TextColor3 = T.Text, TextXAlignment = Enum.TextXAlignment.Left,
    BackgroundTransparency = 1, Position = UDim2.fromOffset(18, 8),
    Size = UDim2.new(1, -140, 0, 24),
  }, head)
  New("UIGradient", { Color = ColorSequence.new(T.Accent, T.Accent2), Rotation = 15 }, title)
  local sub = Txt(head, opts.Subtitle or ("NovaUI " .. Nova.Version), 11, "dim")
  sub.Position, sub.Size = UDim2.fromOffset(18, 32), UDim2.new(1, -140, 0, 14)
  local function headBtn(txt, x, danger)
    local b = New("TextButton", {
      Text = txt, Font = Enum.Font.GothamBold, TextSize = 16,
      TextColor3 = T.Dim, BackgroundTransparency = 1, AutoButtonColor = false,
      AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, x, 0, 10),
      Size = UDim2.fromOffset(30, 30),
    }, head)
    b.MouseEnter:Connect(function()
      Tween(b, { TextColor3 = danger and T.Danger or T.Text }, 0.12) end)
    b.MouseLeave:Connect(function() Tween(b, { TextColor3 = T.Dim }, 0.12) end)
    return b
  end
  local hideB = headBtn("—", -48, false)
  local xB = headBtn("×", -12, true)
  local uline = New("Frame", {
    BackgroundColor3 = T.Accent, BorderSizePixel = 0,
    Size = UDim2.new(1, 0, 0, 2), Position = UDim2.new(0, 0, 1, -2),
  }, head)
  New("UIGradient", { Color = ColorSequence.new(T.Accent, T.Accent2) }, uline)
  -- body: sidebar + pages
  local body = New("Frame", {
    BackgroundTransparency = 1, Size = UDim2.new(1, 0, 1, -88),
    Position = UDim2.new(0, 0, 0, 58),
  }, shell)
  local side = New("Frame", {
    BackgroundTransparency = 1, Size = UDim2.new(0, 150, 1, 0),
  }, body)
  Pad(side, 12, 6, 4, 0)
  local sideList = List(side, 4); sideList.HorizontalAlignment = Enum.HorizontalAlignment.Left
  local pageWrap = New("Frame", {
    BackgroundTransparency = 1, Size = UDim2.new(1, -162, 1, 0),
    Position = UDim2.new(0, 158, 0, 0),
  }, body)
  -- footer
  local foot = Txt(shell, (opts.Footer or "RightShift — hide  •  NovaUI ") .. Nova.Version,
    10, "dim", Enum.Font.Gotham, Enum.TextXAlignment.Center)
  foot.AnchorPoint = Vector2.new(0, 1); foot.Position = UDim2.new(0, 0, 1, -6)
  foot.Size = UDim2.new(1, 0, 0, 16)
  Drag(cont, head)
  -- visibility -----------------------------------------------------------
  local visible = true
  function win:SetVisible(v)
    v = v == true
    if v == visible then return end
    visible = v
    if v then
      cont.Visible = true
      Tween(shell, { GroupTransparency = 0 }, 0.18)
    else
      local tw = Tween(shell, { GroupTransparency = 1 }, 0.15)
      tw.Completed:Connect(function() if not visible then cont.Visible = false end end)
    end
  end
  function win:IsVisible() return visible end
  function win:SetScale(s)
    s = clamp(s or 1, 0.6, 1.5)
    Tween(scale, { Scale = s }, 0.15)
  end
  local tkey = opts.Keybind == nil and Enum.KeyCode.RightShift or opts.Keybind
  if tkey then
    table.insert(win._conns, UserInputService.InputBegan:Connect(function(inp, gpe)
      if not gpe and inp.KeyCode == tkey and UserInputService:GetFocusedTextBox() == nil then
        win:SetVisible(not visible)
      end
    end))
  end
  hideB.MouseButton1Click:Connect(function() win:SetVisible(false) end)
  xB.MouseButton1Click:Connect(function() win:Unload() end)
  function win:Unload()
    for _, c in ipairs(win._conns) do pcall(function() c:Disconnect() end) end
    for i, w in ipairs(Nova._wins) do if w == win then table.remove(Nova._wins, i) break end end
    pcall(function() sg:Destroy() end)
    if opts.OnUnload then pcall(opts.OnUnload) end
  end
  function win:Notify(n) Nova:Notify(n) end
  -- tabs -----------------------------------------------------------------
  function win:Tab(topt)
    topt = topt or {}
    local page = New("ScrollingFrame", {
      BackgroundTransparency = 1, BorderSizePixel = 0, Visible = false,
      Size = UDim2.fromScale(1, 1), CanvasSize = UDim2.new(),
      AutomaticCanvasSize = Enum.AutomaticSize.Y,
      ScrollingDirection = Enum.ScrollingDirection.Y,
      ScrollBarThickness = 3, ScrollBarImageColor3 = T.Dim,
    }, pageWrap)
    Pad(page, 4, 6, 10, 12)
    List(page, 10)
    local tb = New("TextButton", {
      Text = "", AutoButtonColor = false, BorderSizePixel = 0,
      BackgroundColor3 = T.Bg2, Size = UDim2.new(1, 0, 0, 36),
    }, side)
    Paint(tb, "bg2"); Corner(tb, 10); Pad(tb, 10, 0, 6, 0)
    local ind = New("Frame", {
      BackgroundColor3 = T.Accent, BorderSizePixel = 0,
      Size = UDim2.new(0, 3, 0, 20), Position = UDim2.new(0, 6, 0.5, 0),
      AnchorPoint = Vector2.new(0, 0.5), Visible = false,
    }, tb)
    Corner(ind, 2)
    local ic = Txt(tb, topt.Icon or "•", 14, "dim", Enum.Font.GothamBold)
    ic.Size, ic.Position = UDim2.new(0, 24, 1, 0), UDim2.new(0, 10, 0, 0)
    ic.TextXAlignment = Enum.TextXAlignment.Center
    local nm = Txt(tb, topt.Name or "Tab", 13, "text", Enum.Font.GothamMedium)
    nm.Size, nm.Position = UDim2.new(1, -40, 1, 0), UDim2.new(0, 36, 0, 0)
    local tab = { _page = page, _btn = tb, _ind = ind, _defaultSec = nil }
    function tab.Select()
      for _, t in ipairs(win._tabs) do
        local on = t == tab
        t._page.Visible = on
        t._ind.Visible = on
        Tween(t._btn, { BackgroundColor3 = on and T.Row or T.Bg2 }, 0.15)
      end
    end
    tb.MouseButton1Click:Connect(function() tab.Select() end)
    table.insert(win._tabs, tab)
    if #win._tabs == 1 then tab.Select() end
    -- sections -------------------------------------------------------------
    function tab:Section(sopt)
      sopt = sopt or {}
      local box = New("Frame", {
        BackgroundColor3 = T.Bg2, BorderSizePixel = 0,
        Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
      }, page)
      Paint(box, "bg2"); Corner(box, 12); Stroke(box, T.Dim, 1, 0.85); Pad(box, 12, 8, 12, 10)
      List(box, 4)
      local hb = New("TextButton", {
        Text = "", AutoButtonColor = false, BackgroundTransparency = 1,
        Size = UDim2.new(1, 0, 0, 26),
      }, box)
      local st = Txt(hb, string.upper(sopt.Name or "SECTION"), 12, "dim", Enum.Font.GothamBold)
      st.Size = UDim2.new(1, -30, 1, 0)
      local ar = Txt(hb, "▾", 14, "dim", Enum.Font.GothamBold, Enum.TextXAlignment.Right)
      ar.Size = UDim2.new(1, 0, 1, 0)
      local inner = New("Frame", { BackgroundTransparency = 1,
        Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y }, box)
      List(inner, 8)
      local collapsed = false
      hb.MouseButton1Click:Connect(function()
        collapsed = not collapsed
        inner.Visible = not collapsed
        Tween(ar, { Rotation = collapsed and -90 or 0 }, 0.15)
      end)
      local sec = {}
      function sec:Label(t, s) return addLabel(inner, t, s or 12, false) end
      function sec:Paragraph(t) return addLabel(inner, t, 12, true) end
      function sec:Divider() return addDivider(inner) end
      function sec:Button(o) return addButton(inner, o or {}) end
      function sec:Toggle(o) return addToggle(inner, o or {}) end
      function sec:Slider(o) return addSlider(inner, o or {}) end
      function sec:Dropdown(o) return addDropdown(inner, o or {}, win) end
      function sec:Keybind(o) return addKeybind(inner, o or {}) end
      function sec:Color(o) return addColor(inner, o or {}) end
      function sec:TextBox(o) return addTextBox(inner, o or {}) end
      return sec
    end
    function tab:_default()
      if not tab._defaultSec then tab._defaultSec = tab:Section({ Name = "General" }) end
      return tab._defaultSec
    end
    function tab:Label(t, s) return tab:_default():Label(t, s) end
    function tab:Paragraph(t) return tab:_default():Paragraph(t) end
    function tab:Divider() return tab:_default():Divider() end
    function tab:Button(o) return tab:_default():Button(o) end
    function tab:Toggle(o) return tab:_default():Toggle(o) end
    function tab:Slider(o) return tab:_default():Slider(o) end
    function tab:Dropdown(o) return tab:_default():Dropdown(o) end
    function tab:Keybind(o) return tab:_default():Keybind(o) end
    function tab:Color(o) return tab:_default():Color(o) end
    function tab:TextBox(o) return tab:_default():TextBox(o) end
    return tab
  end
  table.insert(Nova._wins, win)
  return win
end

--// Config save/load (executor file APIs, memory fallback) -----------------
Nova._memCfg = {}
local function canFile()
  return type(writefile) == "function" and type(readfile) == "function" and type(isfile) == "function"
end
local function encVal(v)
  if typeof and typeof(v) == "Color3" then
    return { t = "c3", v = { math.floor(v.R * 255 + 0.5), math.floor(v.G * 255 + 0.5), math.floor(v.B * 255 + 0.5) } }
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
  if type(v) == "table" and v.t == "enum" then return v.v end -- setter resolves KeyCode
  return v
end
function Nova:Save(name)
  name = name or "default"
  local data = {}
  for flag, v in pairs(Nova.Flags) do data[flag] = encVal(v) end
  local json = HttpService:JSONEncode(data)
  if canFile() then
    pcall(function()
      if makefolder and not isfolder("NovaUI") then makefolder("NovaUI") end
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
  if not json then Nova:Notify({ Title = "Config", Text = "Not found: " .. tostring(name), Type = "error" }) return false end
  local ok, data = pcall(HttpService.JSONDecode, HttpService, json)
  if not ok or type(data) ~= "table" then return false end
  local n = 0
  for flag, v in pairs(data) do
    local set = Nova._setters[flag]
    if set then local s = pcall(set, decVal(v)); if s then n = n + 1 end end
  end
  Nova:Notify({ Title = "Config", Text = "Loaded '" .. tostring(name) .. "' (" .. n .. ")", Type = "ok" })
  return true
end
function Nova:UnloadAll()
  while #Nova._wins > 0 do Nova._wins[1]:Unload() end
  pcall(function() if _notifHolder then _notifHolder.Parent:Destroy() end end)
  _notifHolder = nil
end

return Nova
