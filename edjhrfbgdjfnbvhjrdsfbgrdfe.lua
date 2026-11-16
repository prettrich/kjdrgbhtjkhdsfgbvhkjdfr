-- ShadowChat v3.8.8 - reliable online directory (presence-only changes)
-- Replace only these two values before running.
local SUPABASE_URL = "https://jwyubmjadrqpfronkekt.supabase.co"
local SUPABASE_KEY = "sb_publishable_LVzVuQMyG0-3hDKJlaZ2ag_wquBImsI"

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local TextService = game:GetService("TextService")
local player = Players.LocalPlayer
local env = (type(getgenv) == "function" and getgenv()) or _G
local requestFn = request or http_request or (syn and syn.request)
assert(requestFn, "[ShadowChat] Executor HTTP request support required")
assert(not SUPABASE_URL:find("YOUR_PROJECT_ID", 1, true), "[ShadowChat] Set SUPABASE_URL")
assert(not SUPABASE_KEY:find("YOUR_PUBLISHABLE_KEY", 1, true), "[ShadowChat] Set SUPABASE_KEY")
SUPABASE_URL = SUPABASE_URL:gsub("/+$", "")
assert(not SUPABASE_URL:find("/rest/v1", 1, true), "[ShadowChat] URL must not include /rest/v1")

if type(env.ShadowChatStop) == "function" then pcall(env.ShadowChatStop) end
local alive = true
local gui, accessToken, refreshToken, expiresAt, supabaseUserId, roomId
local seen = {}
local tabButtons
local messageCount = 0
-- Session-local Global unread count (the first history fetch is not a notification).
local globalUnread = 0
local globalHistoryLoaded = false
local function updateGlobalBadge()
    if tabButtons and tabButtons[1] then
        tabButtons[1].Text = globalUnread > 0 and ("Global (" .. tostring(math.min(globalUnread, 99)) .. ")") or "Global"
    end
end
local busy = false
local POLL_SECONDS = 2
local MAX_MESSAGE_CHARS = 500
local MAX_DISPLAY_MESSAGES = 500
local function trimMessageFrames(pane)
    local frames = {}
    for _, child in ipairs(pane:GetChildren()) do
        if child:IsA("Frame") then table.insert(frames, child) end
    end
    if #frames <= MAX_DISPLAY_MESSAGES then return end
    table.sort(frames, function(a,b) return a.LayoutOrder < b.LayoutOrder end)
    for i = 1, #frames - MAX_DISPLAY_MESSAGES do frames[i]:Destroy() end
end
local function messageLength(text)
    local length = utf8.len(text)
    return length or math.huge
end
local SESSION_FILE = "ShadowChat_session_" .. tostring(player.UserId) .. ".json"
local connections = {}
local messageEntries = {}
local customSize = nil
local isMobileLayout = false
local activeTab = "Global"
local presenceReady = false
local presenceBusy = false
local presenceRows = {}
local presenceFetchSerial = 0
local presenceLastApplied = 0
local selectedProfile = nil
local PRESENCE_INTERVAL = 20
local DIRECTORY_INTERVAL = 8
local PRESENCE_TIMEOUT = 70
local escapeRich
local dmConversations = {}
local dmCurrent = nil
local dmSeen = {}
local dmLoading = false
local dmSending = false
local dmLastUnread = 0
local typography = {message = 14, name = 14, title = 17, tabs = 13, input = 14, status = 11}
local function connect(signal, callback)
    local c = signal:Connect(callback)
    table.insert(connections, c)
    return c
end
local api
local function cleanup()
    alive = false
    -- Best-effort offline signal. Timeout expiry also handles crashes/disconnects.
    if accessToken and supabaseUserId then
        task.spawn(function()
            pcall(function()
                api("DELETE", "/rest/v1/shadowchat_presence?user_id=eq." .. supabaseUserId, nil, accessToken)
            end)
        end)
    end
    env.ShadowChatSend = nil
    if gui then gui:Destroy() end
    for _, c in ipairs(connections) do pcall(function() c:Disconnect() end) end
end
env.ShadowChatStop = cleanup

api = function(method, path, body, token)
    local headers = { ["apikey"] = SUPABASE_KEY, ["Content-Type"] = "application/json" }
    if token then headers["Authorization"] = "Bearer " .. token end
    local opts = { Url = SUPABASE_URL .. path, Method = method, Headers = headers }
    if body ~= nil then opts.Body = type(body) == "string" and body or HttpService:JSONEncode(body) end
    local ok, response = pcall(requestFn, opts)
    if not ok or type(response) ~= "table" then return 0, nil, tostring(response) end
    local status = tonumber(response.StatusCode or response.Status) or 0
    local raw = response.Body or ""
    local parsed
    if raw ~= "" then pcall(function() parsed = HttpService:JSONDecode(raw) end) end
    return status, parsed, raw
end
local function readSession()
    if type(isfile) ~= "function" or type(readfile) ~= "function" then return nil end
    local ok, result = pcall(function()
        if not isfile(SESSION_FILE) then return nil end
        return HttpService:JSONDecode(readfile(SESSION_FILE))
    end)
    return ok and result or nil
end
local function storeSession()
    if type(writefile) ~= "function" or not refreshToken then return end
    pcall(function()
        writefile(SESSION_FILE, HttpService:JSONEncode({refresh_token = refreshToken, user_id = supabaseUserId}))
    end)
end
local function acceptAuth(data)
    if type(data) ~= "table" or not data.access_token or not data.refresh_token or not data.user or not data.user.id then
        return false
    end
    accessToken = data.access_token
    refreshToken = data.refresh_token
    supabaseUserId = data.user.id
    expiresAt = os.time() + (tonumber(data.expires_in) or 3600)
    storeSession()
    return true
end
local function refreshAuth()
    if not refreshToken then return false end
    local code, data, raw = api("POST", "/auth/v1/token?grant_type=refresh_token", {refresh_token = refreshToken})
    if code == 200 and acceptAuth(data) then return true end
    warn("[ShadowChat] Session refresh failed:", code, raw)
    return false
end
local function authorized(method, path, body)
    if not alive then return 0, nil, "Stopped" end
    if os.time() >= (expiresAt or 0) - 120 then
        if not refreshAuth() then return 401, nil, "Could not refresh session" end
    end
    local code, data, raw = api(method, path, body, accessToken)
    if code == 401 and refreshAuth() then
        return api(method, path, body, accessToken)
    end
    return code, data, raw
end

-- UI helpers. All positioning/sizing is scale-based.
local function make(class, parent, properties)
    local obj = Instance.new(class)
    for k, v in pairs(properties or {}) do obj[k] = v end
    obj.Parent = parent
    return obj
end
local C = {
    bg = Color3.fromRGB(12, 13, 17), panel = Color3.fromRGB(20, 21, 26),
    raised = Color3.fromRGB(35, 38, 45), accent = Color3.fromRGB(78, 153, 255),
    text = Color3.fromRGB(244, 247, 253), muted = Color3.fromRGB(166, 176, 192),
    green = Color3.fromRGB(92, 214, 148), red = Color3.fromRGB(245, 113, 113)
}
local function corner(parent, radius)
    make("UICorner", parent, {CornerRadius = UDim.new(radius or 0.12, 0)})
end
local function label(parent, value, pos, size, font, align)
    local l = make("TextLabel", parent, {
        BackgroundTransparency = 1, Position = pos, Size = size,
        Text = value, TextColor3 = C.text, Font = font or Enum.Font.Gotham,
        TextScaled = true, TextWrapped = true, TextXAlignment = align or Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Center
    })
    make("UITextSizeConstraint", l, {MinTextSize = 10, MaxTextSize = 21})
    return l
end
local function button(parent, value, pos, size, color)
    local b = make("TextButton", parent, {
        BackgroundColor3 = color or C.raised, BorderSizePixel = 0,
        Position = pos, Size = size, Text = value, TextColor3 = C.text,
        Font = Enum.Font.GothamBold, TextScaled = true, AutoButtonColor = true
    })
    corner(b, 0.16)
    make("UITextSizeConstraint", b, {MinTextSize = 10, MaxTextSize = 18})
    return b
end

gui = make("ScreenGui", player:WaitForChild("PlayerGui"), {
    Name = "ShadowChat", ResetOnSpawn = false, IgnoreGuiInset = false,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling, DisplayOrder = 50
})
local frame = make("Frame", gui, {
    Name = "ChatWindow", AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.30, 0.55),
    BackgroundColor3 = C.bg, BackgroundTransparency = 0.20, BorderSizePixel = 0, Active = true
})
corner(frame, 0.035)
make("UIStroke", frame, {Color = C.raised, Thickness = 1.5})
-- A fixed UIAspectRatioConstraint would fight freeform resizing.
-- The initial proportions are set by fitViewport; after that the user controls them.
local top = make("Frame", frame, {
    Size = UDim2.fromScale(1, 0.105), BackgroundColor3 = C.panel, BackgroundTransparency = 0.15,
    BorderSizePixel = 0, Active = true
})
corner(top, 0.16)
local titleLabel = label(top, "ShadowChat", UDim2.fromScale(0.045, 0.15), UDim2.fromScale(0.55, 0.7), Enum.Font.GothamBold)
local minimize = button(top, "−", UDim2.fromScale(0.67, 0.16), UDim2.fromScale(0.09, 0.68))
local maximize = button(top, "□", UDim2.fromScale(0.78, 0.16), UDim2.fromScale(0.09, 0.68))
local close = button(top, "×", UDim2.fromScale(0.89, 0.16), UDim2.fromScale(0.09, 0.68), Color3.fromRGB(111, 48, 59))
local tabs = make("Frame", frame, {
    BackgroundTransparency = 1, Position = UDim2.fromScale(0.035, 0.125),
    Size = UDim2.fromScale(0.93, 0.085)
})
local tabNames = {"Global", "Rooms", "DMs", "Players"}
tabButtons = {}
for i, name in ipairs(tabNames) do
    local b = button(tabs, name, UDim2.fromScale((i-1)*0.255, 0), UDim2.fromScale(0.235, 1),
        i == 1 and C.accent or C.raised)
    table.insert(tabButtons, b)
end
local scroll = make("ScrollingFrame", frame, {
    Name = "Messages", Position = UDim2.fromScale(0.035, 0.225),
    Size = UDim2.fromScale(0.93, 0.625), BackgroundColor3 = C.panel, BackgroundTransparency = 0.64,
    BorderSizePixel = 0, ScrollBarThickness = 4, ScrollBarImageColor3 = C.muted,
    CanvasSize = UDim2.fromScale(0, 0), AutomaticCanvasSize = Enum.AutomaticSize.None,
    ScrollingDirection = Enum.ScrollingDirection.Y
})
corner(scroll, 0.025)
local padding = make("UIPadding", scroll, {
    PaddingTop = UDim.new(0, 4), PaddingBottom = UDim.new(0, 4),
    PaddingLeft = UDim.new(0, 7), PaddingRight = UDim.new(0, 10)
})
local layout = make("UIListLayout", scroll, {
    Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder
})
-- Clip the actual TextBox inside a rounded input container. A TextBox alone can
-- render its single-line text beyond its visual bounds after focus is lost.
local inputHolder = make("Frame", frame, {
    Name = "InputHolder", Position = UDim2.fromScale(0.035, 0.867),
    Size = UDim2.fromScale(0.73, 0.075), BackgroundColor3 = C.raised,
    BackgroundTransparency = 0.18, BorderSizePixel = 0, ClipsDescendants = true
})
corner(inputHolder, 0.14)
local input = make("TextBox", inputHolder, {
    Name = "MessageInput", Position = UDim2.new(0, 8, 0, 0),
    Size = UDim2.new(1, -16, 1, 0), BackgroundTransparency = 1,
    BorderSizePixel = 0, ClearTextOnFocus = false, MultiLine = false,
    TextWrapped = false, TextTruncate = Enum.TextTruncate.None,
    PlaceholderText = "Type a message...", PlaceholderColor3 = C.muted,
    Text = "", TextColor3 = C.text, Font = Enum.Font.Gotham,
    TextScaled = false, TextXAlignment = Enum.TextXAlignment.Left,
    TextYAlignment = Enum.TextYAlignment.Center
})
connect(input:GetPropertyChangedSignal("Text"), function()
    local value = input.Text
    if messageLength(value) > MAX_MESSAGE_CHARS then
        local cut = utf8.offset(value, MAX_MESSAGE_CHARS + 1)
        if cut then input.Text = value:sub(1, cut - 1) end
    end
end)
make("UITextSizeConstraint", input, {MinTextSize = 10, MaxTextSize = 20})
-- The text field grows horizontally inside the clipped holder. Its position is
-- adjusted to keep the caret in view, without ellipses or text leaking outside.
local function followInputCaret()
    if not alive or not input.Parent then return end
    if isMobileLayout then
        -- Roblox manages its own caret while the software keyboard is active.
        -- Do not reposition/expand the TextBox on touch devices: that caused
        -- the mobile caret and text to escape the clipped input field.
        input.Position = UDim2.new(0, 8, 0, 0)
        input.Size = UDim2.new(1, -16, 1, 0)
        return
    end
    local visible = math.max(40, inputHolder.AbsoluteSize.X - 16)
    local fontSize = input.TextSize
    local fullWidth = TextService:GetTextSize(input.Text, fontSize, input.Font, Vector2.new(100000, 100)).X
    local totalWidth = math.max(visible, fullWidth + 24)
    local cursor = input.CursorPosition
    local prefix = input.Text
    if cursor and cursor > 0 then
        prefix = input.Text:sub(1, cursor - 1)
    end
    local cursorX = TextService:GetTextSize(prefix, fontSize, input.Font, Vector2.new(100000, 100)).X
    local oldOffset = math.max(0, 8 - input.Position.X.Offset)
    local offset = math.clamp(oldOffset, 0, math.max(0, totalWidth - visible))
    if cursor and cursor > 0 then
        if cursorX - offset > visible - 14 then
            offset = cursorX - visible + 14
        elseif cursorX - offset < 5 then
            offset = cursorX - 5
        end
    elseif not input:IsFocused() then
        offset = math.max(0, fullWidth - visible + 12)
    end
    offset = math.clamp(offset, 0, math.max(0, totalWidth - visible))
    input.Position = UDim2.new(0, 8 - offset, 0, 0)
    input.Size = UDim2.new(0, totalWidth, 1, 0)
end
connect(input:GetPropertyChangedSignal("Text"), function() task.defer(followInputCaret) end)
connect(input:GetPropertyChangedSignal("CursorPosition"), function() task.defer(followInputCaret) end)
connect(inputHolder:GetPropertyChangedSignal("AbsoluteSize"), function() task.defer(followInputCaret) end)
connect(input.Focused, function() task.defer(followInputCaret) end)
connect(input.FocusLost, function() task.defer(followInputCaret) end)
local send = button(frame, "Send", UDim2.fromScale(0.785, 0.867), UDim2.fromScale(0.18, 0.075), C.accent)
local statusLabel = label(frame, "● Connecting...", UDim2.fromScale(0.045, 0.947), UDim2.fromScale(0.88, 0.045))
statusLabel.TextColor3 = C.muted
local function status(text, color)
    if alive and statusLabel then statusLabel.Text = "● " .. text; statusLabel.TextColor3 = color or C.muted end
end
-- Players directory occupies the same content region as Global messages.
local playersPanel = make("Frame", frame, {
    Name = "PlayersPanel", BackgroundColor3 = C.panel,
    BackgroundTransparency = 0.64, BorderSizePixel = 0,
    Position = UDim2.fromScale(0.035, 0.225),
    Size = UDim2.fromScale(0.93, 0.715), Visible = false
})
corner(playersPanel, 0.025)
local playerSearch = make("TextBox", playersPanel, {
    Name = "SearchPlayers", Position = UDim2.fromScale(0.025, 0.018),
    Size = UDim2.fromScale(0.95, 0.105),
    BackgroundColor3 = C.raised, BackgroundTransparency = 0.2,
    BorderSizePixel = 0, Text = "", PlaceholderText = "Search players...",
    PlaceholderColor3 = C.muted, TextColor3 = C.text,
    Font = Enum.Font.Gotham, TextSize = 14, TextScaled = false,
    TextXAlignment = Enum.TextXAlignment.Left, ClearTextOnFocus = false
})
corner(playerSearch, 0.1)
local playerSummary = label(playersPanel, "Loading online players...",
    UDim2.fromScale(0.035, 0.14), UDim2.fromScale(0.93, 0.07),
    Enum.Font.Gotham, Enum.TextXAlignment.Left)
playerSummary.TextScaled = false
playerSummary.TextSize = 12
playerSummary.TextColor3 = C.muted
local playersScroll = make("ScrollingFrame", playersPanel, {
    Name = "OnlinePlayers", Position = UDim2.fromScale(0.025, 0.225),
    Size = UDim2.fromScale(0.95, 0.75), BackgroundTransparency = 1,
    BorderSizePixel = 0, ScrollBarThickness = 3,
    CanvasSize = UDim2.new(0,0,0,0), AutomaticCanvasSize = Enum.AutomaticSize.Y,
    ScrollingDirection = Enum.ScrollingDirection.Y
})
local playersLayout = make("UIListLayout", playersScroll, {
    Padding = UDim.new(0, 5), SortOrder = Enum.SortOrder.LayoutOrder
})
local playerProfile = make("Frame", playersPanel, {
    Name = "SelectedPlayer", Position = UDim2.fromScale(0.025, 0.225),
    Size = UDim2.fromScale(0.95, 0.75), BackgroundColor3 = C.panel,
    BackgroundTransparency = 0.05, BorderSizePixel = 0, Visible = false
})
corner(playerProfile, 0.05)
local profileBack = button(playerProfile, "‹ Back",
    UDim2.fromScale(0.04, 0.04), UDim2.fromScale(0.34, 0.13), C.raised)
local profileName = label(playerProfile, "", UDim2.fromScale(0.05, 0.24),
    UDim2.fromScale(0.9, 0.15), Enum.Font.GothamBold)
profileName.TextScaled = false; profileName.TextSize = 17
local profileHandle = label(playerProfile, "", UDim2.fromScale(0.05, 0.40),
    UDim2.fromScale(0.9, 0.12))
profileHandle.TextScaled = false; profileHandle.TextSize = 13
profileHandle.TextColor3 = Color3.fromRGB(145,190,255)
local profileOnline = label(playerProfile, "", UDim2.fromScale(0.05, 0.55),
    UDim2.fromScale(0.9, 0.1))
profileOnline.TextScaled = false; profileOnline.TextSize = 12
local profileDM = button(playerProfile, "Message",
    UDim2.fromScale(0.05, 0.73), UDim2.fromScale(0.9, 0.16), C.raised)

connect(profileBack.Activated, function()
    playerProfile.Visible = false
    playersScroll.Visible = true
    selectedProfile = nil
end)
local function openProfile(entry)
    selectedProfile = entry
    profileName.Text = tostring(entry.roblox_display_name or entry.roblox_username or "Unknown")
    profileHandle.Text = "@" .. tostring(entry.roblox_username or "Unknown")
    profileOnline.Text = entry.user_id == supabaseUserId and "● Online (you)" or "● Online"
    profileOnline.TextColor3 = C.green
    playersScroll.Visible = false
    playerProfile.Visible = true
end
local dmPanel
local roomsPanel
local refreshPublicRooms
local updateDMStatus
local function showTab(tab)
    if not alive then return end
    activeTab = tab
    if tab == "Global" then
        globalUnread = 0
        updateGlobalBadge()
    end
    for i, b in ipairs(tabButtons) do
        b.BackgroundColor3 = tabNames[i] == tab and C.accent or C.raised
    end
    local global = tab == "Global"
    scroll.Visible = global
    inputHolder.Visible = global
    send.Visible = global
    playersPanel.Visible = tab == "Players"
    if dmPanel then dmPanel.Visible = tab == "DMs" end
    if roomsPanel then roomsPanel.Visible = tab == "Rooms" end
    if tab == "Rooms" and refreshPublicRooms then
        task.spawn(refreshPublicRooms)
    end
    if updateDMStatus then updateDMStatus() end
    if tab == "Players" then
        playerProfile.Visible = false
        playersScroll.Visible = true
        selectedProfile = nil
    end
end
-- Direct message interface: conversation list and a separate thread composer.
dmPanel = make("Frame", frame, {
    Name = "DMPanel", BackgroundColor3 = C.panel, BackgroundTransparency = 0.64,
    BorderSizePixel = 0, Position = UDim2.fromScale(0.035, 0.225),
    Size = UDim2.fromScale(0.93, 0.715), Visible = false
})
corner(dmPanel, 0.025)
local dmTitle = label(dmPanel, "Direct Messages",
    UDim2.fromScale(0.035, 0.015), UDim2.fromScale(0.78, 0.085), Enum.Font.GothamBold)
dmTitle.TextScaled = false; dmTitle.TextSize = 15
local dmPresence = label(dmPanel, "", UDim2.fromScale(0.035, 0.083),
    UDim2.fromScale(0.65, 0.065))
dmPresence.TextScaled = false; dmPresence.TextSize = 11
dmPresence.Visible = false
local dmBack = button(dmPanel, "‹ Back", UDim2.fromScale(0.73, 0.015),
    UDim2.fromScale(0.245, 0.09), C.raised)
dmBack.Visible = false
local dmList = make("ScrollingFrame", dmPanel, {
    Name = "Conversations", Position = UDim2.fromScale(0.025, 0.12),
    Size = UDim2.fromScale(0.95, 0.85), BackgroundTransparency = 1,
    BorderSizePixel = 0, ScrollBarThickness = 3, CanvasSize = UDim2.new(),
    AutomaticCanvasSize = Enum.AutomaticSize.Y
})
make("UIListLayout", dmList, {Padding = UDim.new(0, 5), SortOrder = Enum.SortOrder.LayoutOrder})
local dmThread = make("ScrollingFrame", dmPanel, {
    Name = "Thread", Position = UDim2.fromScale(0.025, 0.12),
    Size = UDim2.fromScale(0.95, 0.685), BackgroundTransparency = 1,
    BorderSizePixel = 0, ScrollBarThickness = 3, CanvasSize = UDim2.new(),
    AutomaticCanvasSize = Enum.AutomaticSize.Y, Visible = false
})
local dmThreadLayout = make("UIListLayout", dmThread, {
    Padding = UDim.new(0, 5), SortOrder = Enum.SortOrder.LayoutOrder
})
local dmInputHolder = make("Frame", dmPanel, {
    Position = UDim2.fromScale(0.025, 0.82), Size = UDim2.fromScale(0.72, 0.145),
    BackgroundColor3 = C.raised, BackgroundTransparency = 0.18,
    BorderSizePixel = 0, ClipsDescendants = true, Visible = false
})
corner(dmInputHolder, 0.12)
local dmInput = make("TextBox", dmInputHolder, {
    Position = UDim2.new(0, 8, 0, 0), Size = UDim2.new(1, -16, 1, 0),
    BackgroundTransparency = 1, Text = "", PlaceholderText = "Private message...",
    PlaceholderColor3 = C.muted, TextColor3 = C.text,
    Font = Enum.Font.Gotham, TextSize = 13, TextScaled = false,
    ClearTextOnFocus = false, MultiLine = false, TextWrapped = false,
    TextTruncate = Enum.TextTruncate.None,
    TextXAlignment = Enum.TextXAlignment.Left
})
connect(dmInput:GetPropertyChangedSignal("Text"), function()
    local value = dmInput.Text
    if messageLength(value) > MAX_MESSAGE_CHARS then
        local cut = utf8.offset(value, MAX_MESSAGE_CHARS + 1)
        if cut then dmInput.Text = value:sub(1, cut - 1) end
    end
end)
local dmSend = button(dmPanel, "Send", UDim2.fromScale(0.765, 0.82),
    UDim2.fromScale(0.21, 0.145), C.accent)
dmSend.Visible = false
local dmEmpty = label(dmPanel, "No conversations yet. Select a player and tap Message.",
    UDim2.fromScale(0.06, 0.30), UDim2.fromScale(0.88, 0.3))
dmEmpty.TextScaled = false; dmEmpty.TextSize = 13
dmEmpty.TextColor3 = C.muted
local function dmThreadBottom()
    task.defer(function()
        if alive and dmThread.Parent then
            RunService.Heartbeat:Wait()
            dmThread.CanvasPosition = Vector2.new(0,
                math.max(0, dmThread.AbsoluteCanvasSize.Y - dmThread.AbsoluteWindowSize.Y))
        end
    end)
end
local function clearGuiRows(parent)
    for _, child in ipairs(parent:GetChildren()) do
        if child:IsA("GuiObject") then child:Destroy() end
    end
end
local function showDMList()
    dmCurrent = nil
    dmTitle.Text = "Direct Messages"
    dmPresence.Visible = false
    dmBack.Visible = false
    dmList.Visible = true
    dmThread.Visible = false
    dmInputHolder.Visible = false
    dmSend.Visible = false
    dmEmpty.Visible = #dmConversations == 0
end
connect(dmBack.Activated, showDMList)
local function displayPeer(row)
    local display = tostring(row.peer_display_name or row.peer_username or "Unknown")
    local username = tostring(row.peer_username or "Unknown")
    return display == username and ("@" .. username) or (display .. " (@" .. username .. ")")
end
local function refreshDMPresence()
    if not dmCurrent then dmPresence.Visible = false; return end
    local online = false
    for _, entry in ipairs(presenceRows) do
        if entry.user_id == dmCurrent.peer_user_id then online = true; break end
    end
    dmPresence.Visible = true
    dmPresence.Text = online and "● Online" or "● Offline"
    dmPresence.TextColor3 = online and C.green or C.muted
end
local function showDMThread(row)
    dmCurrent = row
    dmTitle.Text = displayPeer(row)
    refreshDMPresence()
    dmBack.Visible = true
    dmList.Visible = false
    dmThread.Visible = true
    dmInputHolder.Visible = true
    dmSend.Visible = true
    dmEmpty.Visible = false
    dmSeen = {}
    clearGuiRows(dmThread)
end
local fetchDMThread
local function drawDMList()
    if not alive then return end
    clearGuiRows(dmList)
    dmEmpty.Visible = #dmConversations == 0 and not dmCurrent
    for i, row in ipairs(dmConversations) do
        local item = button(dmList, "", UDim2.new(), UDim2.new(1, -5, 0, 58), C.raised)
        item.LayoutOrder = i
        item.Text = ""
        local name = label(item, displayPeer(row), UDim2.fromScale(0.03, 0.05),
            UDim2.fromScale(0.81, 0.48), Enum.Font.GothamBold)
        name.TextScaled = false; name.TextSize = 13
        local preview = label(item, tostring(row.last_body or "Start a conversation"),
            UDim2.fromScale(0.03, 0.53), UDim2.fromScale(0.84, 0.37))
        preview.TextScaled = false; preview.TextSize = 11
        preview.TextColor3 = C.muted
        local unread = tonumber(row.unread_count) or 0
        if unread > 0 then
            local badge = label(item, tostring(unread), UDim2.fromScale(0.86, 0.16),
                UDim2.fromScale(0.11, 0.55), Enum.Font.GothamBold)
            badge.TextColor3 = C.accent
            badge.TextScaled = false; badge.TextSize = 14
        end
        connect(item.Activated, function()
            showDMThread(row)
            task.spawn(function() if fetchDMThread then fetchDMThread() end end)
        end)
    end
end
local function fetchDMList()
    if not alive or not supabaseUserId then return end
    local code, data, raw = authorized("POST", "/rest/v1/rpc/shadowchat_list_dms", {})
    if not alive then return end
    if code ~= 200 or type(data) ~= "table" then
        warn("[ShadowChat] DM list failed:", code, raw)
        return
    end
    dmConversations = data
    local total = 0
    for _, row in ipairs(data) do total += tonumber(row.unread_count) or 0 end
    dmLastUnread = total
    tabButtons[3].Text = total > 0 and ("DMs (" .. math.min(total,99) .. ")") or "DMs"
    if not dmCurrent then drawDMList() end
end
fetchDMThread = function()
    if not alive or not dmCurrent or dmLoading then return end
    dmLoading = true
    local id = dmCurrent.conversation_id
    local path = "/rest/v1/shadowchat_dm_messages?conversation_id=eq." .. id
        .. "&select=id,sender_id,body,created_at&order=created_at.asc&limit=100"
    local code, data, raw = authorized("GET", path)
    dmLoading = false
    if not alive or not dmCurrent or dmCurrent.conversation_id ~= id then return end
    if code ~= 200 or type(data) ~= "table" then
        warn("[ShadowChat] DM messages failed:", code, raw)
        return
    end
    local added = false
    for idx = 1, #data do
        local msg = data[idx]
        if msg.id and not dmSeen[msg.id] then
            dmSeen[msg.id] = true
            added = true
            local mine = msg.sender_id == supabaseUserId
            local item = make("Frame", dmThread, {
                BackgroundTransparency = 1, BorderSizePixel = 0,
                Size = UDim2.new(1, -5, 0, 32), LayoutOrder = #dmThread:GetChildren()
            })
            local prefix = mine and "You" or displayPeer(dmCurrent)
            local text = prefix .. ": " .. tostring(msg.body or "")
            local mobile = isMobileLayout
            local font = mobile and Enum.Font.Gotham or Enum.Font.SourceSans
            local fontSize = mobile and typography.message or 18
            local rich = '<font color="' .. (mine and "#4E99FF" or "#91BEFF")
                .. '"><b>' .. escapeRich(prefix) .. ':</b></font> '
                .. escapeRich(tostring(msg.body or ""))
            local content = make("TextLabel", item, {
                BackgroundTransparency = 1, Text = mobile and rich or text,
                RichText = mobile, Font = font,
                TextSize = fontSize, TextColor3 = C.text,
                TextWrapped = true, TextScaled = false,
                TextXAlignment = Enum.TextXAlignment.Left,
                TextYAlignment = Enum.TextYAlignment.Top,
                Position = UDim2.new(0, 5, 0, 0), Size = UDim2.new(1, -10, 0, 1000)
            })
            -- Desktop keeps its existing plain-text layout with a colored name overlay.
            local width = math.max(80, dmThread.AbsoluteSize.X - 22)
            local height = TextService:GetTextSize(text, fontSize, font,
                Vector2.new(width, 10000)).Y + 5
            item.Size = UDim2.new(1, -5, 0, height)
            content.Size = UDim2.new(1, -10, 0, height)
            if not mobile then
                local prefixWidth = TextService:GetTextSize(prefix .. ":", fontSize,
                    font, Vector2.new(100000, 100)).X
                if prefixWidth < width then
                    make("TextLabel", item, {
                        BackgroundTransparency = 1, Text = prefix .. ":", RichText = false,
                        Font = font, TextSize = fontSize, TextColor3 = mine and C.accent
                            or Color3.fromRGB(145, 190, 255), TextScaled = false,
                        TextWrapped = false, TextXAlignment = Enum.TextXAlignment.Left,
                        TextYAlignment = Enum.TextYAlignment.Top,
                        Position = UDim2.new(0, 5, 0, 0),
                        Size = UDim2.new(0, prefixWidth + 1, 0, height), ZIndex = 2
                    })
                end
            end
        end
    end
    trimMessageFrames(dmThread)
    if added then dmThreadBottom() end
    -- Read receipts are updated only while the thread is visible.
    if activeTab == "DMs" and dmThread.Visible then
        authorized("POST", "/rest/v1/rpc/shadowchat_mark_dm_read", {p_conversation_id = id})
    end
end
local function sendDM()
    if not alive or not dmCurrent or dmSending then return end
    local body = dmInput.Text:match("^%s*(.-)%s*$")
    if body == "" or messageLength(body) > MAX_MESSAGE_CHARS then return end
    dmSending = true
    dmInput.Text = ""
    local id = dmCurrent.conversation_id
    task.spawn(function()
        local code, _, raw = authorized("POST", "/rest/v1/shadowchat_dm_messages", {
            conversation_id = id, sender_id = supabaseUserId, body = body
        })
        dmSending = false
        if not alive then return end
        if code == 201 then
            fetchDMThread()
            fetchDMList()
        else
            if dmInput.Text == "" then dmInput.Text = body end
            warn("[ShadowChat] DM send failed:", code, raw)
        end
    end)
end
connect(dmSend.Activated, sendDM)
connect(dmInput.FocusLost, function(enter) if enter then sendDM() end end)
local function startDM(entry)
    if not entry or not entry.user_id then return end
    if entry.user_id == supabaseUserId then return end
    profileDM.Text = "Opening..."
    task.spawn(function()
        local code, id, raw = authorized("POST", "/rest/v1/rpc/shadowchat_start_dm",
            {p_other_user = entry.user_id})
        if not alive then return end
        profileDM.Text = "Message"
        if code ~= 200 or type(id) ~= "string" then
            warn("[ShadowChat] Open DM failed:", code, raw)
            return
        end
        fetchDMList()
        showTab("DMs")
        local row = nil
        for _, conversation in ipairs(dmConversations) do
            if conversation.conversation_id == id then row = conversation; break end
        end
        row = row or {conversation_id = id,
            peer_username = entry.roblox_username,
            peer_display_name = entry.roblox_display_name}
        showDMThread(row)
        fetchDMThread()
    end)
end
connect(profileDM.Activated, function() startDM(selectedProfile) end)
updateDMStatus = function()
    if not alive then return end
    if activeTab == "Players" then
        status("Connected · Players", C.green)
    elseif activeTab == "DMs" then
        status("Connected · DMs", C.green)
    elseif activeTab == "Rooms" then
        status("Connected · Rooms", C.green)
    else
        status("Connected · Global", C.green)
    end
end

-- Public Rooms. All room writes and membership checks are enforced in Supabase.
roomsPanel = make("Frame", frame, {
    Name = "PublicRoomsPanel", BackgroundColor3 = C.panel,
    BackgroundTransparency = 0.64, BorderSizePixel = 0,
    Position = UDim2.fromScale(0.035, 0.225),
    Size = UDim2.fromScale(0.93, 0.715), Visible = false
})
corner(roomsPanel, 0.025)
local roomListPane = make("Frame", roomsPanel, {
    BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1)
})
local roomUI = {}
roomUI.roomsHeading = label(roomListPane, "Chat Rooms", UDim2.fromScale(0.03,0.015),
    UDim2.fromScale(0.55,0.095), Enum.Font.GothamBold)
roomUI.roomsHeading.TextScaled = false; roomUI.roomsHeading.TextSize = 15
roomUI.createRoomBtn = button(roomListPane, "+ Create", UDim2.fromScale(0.7,0.015),
    UDim2.fromScale(0.275,0.105), C.accent)
roomUI.roomSearch = make("TextBox", roomListPane, {
    Position = UDim2.fromScale(0.025,0.14), Size = UDim2.fromScale(0.95,0.105),
    BackgroundColor3 = C.raised, BorderSizePixel = 0,
    PlaceholderText = "Search rooms...", Text = "",
    PlaceholderColor3 = C.muted, TextColor3 = C.text,
    Font = Enum.Font.Gotham, TextSize = 13, ClearTextOnFocus = false,
    TextXAlignment = Enum.TextXAlignment.Left
})
corner(roomUI.roomSearch, 0.12)
roomUI.roomsInfo = label(roomListPane, "Loading rooms...", UDim2.fromScale(0.035,0.255),
    UDim2.fromScale(0.92,0.07))
roomUI.roomsInfo.TextScaled = false; roomUI.roomsInfo.TextSize = 11; roomUI.roomsInfo.TextColor3 = C.muted
roomUI.roomsList = make("ScrollingFrame", roomListPane, {
    Position = UDim2.fromScale(0.025,0.34), Size = UDim2.fromScale(0.95,0.635),
    BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 3,
    AutomaticCanvasSize = Enum.AutomaticSize.Y, CanvasSize = UDim2.new()
})
make("UIListLayout", roomUI.roomsList, {Padding = UDim.new(0,5), SortOrder = Enum.SortOrder.LayoutOrder})
roomUI.roomCreatePane = make("Frame", roomsPanel, {
    BackgroundTransparency = 1, Size = UDim2.fromScale(1,1), Visible = false
})
roomUI.createHeading = label(roomUI.roomCreatePane, "Create Room",
    UDim2.fromScale(0.04,0.03), UDim2.fromScale(0.67,0.1), Enum.Font.GothamBold)
roomUI.createHeading.TextScaled = false; roomUI.createHeading.TextSize = 15
roomUI.createBack = button(roomUI.roomCreatePane, "‹ Back", UDim2.fromScale(0.72,0.03),
    UDim2.fromScale(0.25,0.12), C.raised)
roomUI.roomNameInput = make("TextBox", roomUI.roomCreatePane, {
    Position = UDim2.fromScale(0.04,0.23), Size = UDim2.fromScale(0.92,0.15),
    BackgroundColor3 = C.raised, BorderSizePixel = 0,
    PlaceholderText = "Room name (3–40 characters)", Text = "",
    PlaceholderColor3 = C.muted, TextColor3 = C.text,
    Font = Enum.Font.Gotham, TextSize = 14, ClearTextOnFocus = false,
    TextXAlignment = Enum.TextXAlignment.Left
})
corner(roomUI.roomNameInput, 0.08)
roomUI.roomDescInput = make("TextBox", roomUI.roomCreatePane, {
    Position = UDim2.fromScale(0.04,0.42), Size = UDim2.fromScale(0.92,0.15),
    BackgroundColor3 = C.raised, BorderSizePixel = 0,
    PlaceholderText = "Description (optional)", Text = "",
    PlaceholderColor3 = C.muted, TextColor3 = C.text,
    Font = Enum.Font.Gotham, TextSize = 13, ClearTextOnFocus = false,
    TextXAlignment = Enum.TextXAlignment.Left
})
corner(roomUI.roomDescInput, 0.08)
local privateCreateMode = false
local privacyToggle = button(roomUI.roomCreatePane, "Room Type: Public",
    UDim2.fromScale(0.04,0.565), UDim2.fromScale(0.92,0.12), C.raised)
local roomPasswordInput = make("TextBox", roomUI.roomCreatePane, {
    Position = UDim2.fromScale(0.04,0.695), Size = UDim2.fromScale(0.92,0.115),
    BackgroundColor3 = C.raised, BorderSizePixel = 0,
    PlaceholderText = "Private room password (8+ characters)", Text = "",
    PlaceholderColor3 = C.muted, TextColor3 = C.text,
    Font = Enum.Font.Gotham, TextSize = 13, ClearTextOnFocus = false,
    TextXAlignment = Enum.TextXAlignment.Left, Visible = false
})
corner(roomPasswordInput, 0.08)
connect(privacyToggle.Activated, function()
    privateCreateMode = not privateCreateMode
    privacyToggle.Text = privateCreateMode and "Room Type: Private (Invite Only)" or "Room Type: Public"
    roomPasswordInput.Visible = false
end)
roomUI.roomCreateStatus = label(roomUI.roomCreatePane, "",
    UDim2.fromScale(0.05,0.815), UDim2.fromScale(0.9,0.05))
roomUI.roomCreateStatus.TextScaled = false; roomUI.roomCreateStatus.TextSize = 12
roomUI.createSubmit = button(roomUI.roomCreatePane, "Create Room",
    UDim2.fromScale(0.04,0.87), UDim2.fromScale(0.92,0.12), C.accent)
local roomJoinPane = make("Frame", roomsPanel, {
    BackgroundTransparency = 1, Size = UDim2.fromScale(1,1), Visible = false
})
local joinHeading = label(roomJoinPane, "Join Private Room",
    UDim2.fromScale(0.04,0.03), UDim2.fromScale(0.66,0.1), Enum.Font.GothamBold)
joinHeading.TextScaled = false; joinHeading.TextSize = 15
local joinBack = button(roomJoinPane, "‹ Back", UDim2.fromScale(0.72,0.03),
    UDim2.fromScale(0.25,0.13), C.raised)
local joinRoomName = label(roomJoinPane, "",
    UDim2.fromScale(0.04,0.21), UDim2.fromScale(0.92,0.12), Enum.Font.GothamBold)
joinRoomName.TextScaled = false; joinRoomName.TextSize = 14
local joinPassword = make("TextBox", roomJoinPane, {
    Position = UDim2.fromScale(0.04,0.4), Size = UDim2.fromScale(0.92,0.16),
    BackgroundColor3 = C.raised, BorderSizePixel = 0,
    PlaceholderText = "Enter room password", Text = "",
    PlaceholderColor3 = C.muted, TextColor3 = C.text,
    Font = Enum.Font.Gotham, TextSize = 14, ClearTextOnFocus = false,
    TextXAlignment = Enum.TextXAlignment.Left
})
corner(joinPassword, 0.08)
local joinStatus = label(roomJoinPane, "",
    UDim2.fromScale(0.04,0.61), UDim2.fromScale(0.92,0.1))
joinStatus.TextScaled = false; joinStatus.TextSize = 12
local joinSubmit = button(roomJoinPane, "Join Private Room",
    UDim2.fromScale(0.04,0.77), UDim2.fromScale(0.92,0.15), C.accent)
local selectedPrivateRoom = nil
roomUI.roomThreadPane = make("Frame", roomsPanel, {
    BackgroundTransparency = 1, Size = UDim2.fromScale(1,1), Visible = false
})
roomUI.roomTitle = label(roomUI.roomThreadPane, "", UDim2.fromScale(0.035,0.015),
    UDim2.fromScale(0.67,0.1), Enum.Font.GothamBold)
roomUI.roomTitle.TextScaled = false; roomUI.roomTitle.TextSize = 14
roomUI.roomBack = button(roomUI.roomThreadPane, "‹ Back", UDim2.fromScale(0.72,0.015),
    UDim2.fromScale(0.255,0.125), C.raised)
roomUI.roomThread = make("ScrollingFrame", roomUI.roomThreadPane, {
    Position = UDim2.fromScale(0.025,0.15), Size = UDim2.fromScale(0.95,0.66),
    BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 3,
    AutomaticCanvasSize = Enum.AutomaticSize.Y, CanvasSize = UDim2.new()
})
make("UIListLayout", roomUI.roomThread, {Padding = UDim.new(0,4), SortOrder = Enum.SortOrder.LayoutOrder})
roomUI.roomInputHolder = make("Frame", roomUI.roomThreadPane, {
    Position = UDim2.fromScale(0.025,0.835), Size = UDim2.fromScale(0.73,0.14),
    BackgroundColor3 = C.raised, BorderSizePixel = 0,
    ClipsDescendants = true
})
corner(roomUI.roomInputHolder, 0.12)
roomUI.roomInput = make("TextBox", roomUI.roomInputHolder, {
    Position = UDim2.new(0,8,0,0), Size = UDim2.new(1,-16,1,0),
    BackgroundTransparency = 1, Text = "", PlaceholderText = "Message room...",
    PlaceholderColor3 = C.muted, TextColor3 = C.text,
    Font = Enum.Font.Gotham, TextSize = 13, ClearTextOnFocus = false,
    MultiLine = false, TextWrapped = false, TextTruncate = Enum.TextTruncate.None,
    TextXAlignment = Enum.TextXAlignment.Left
})
connect(roomUI.roomInput:GetPropertyChangedSignal("Text"), function()
    local value = roomUI.roomInput.Text
    if messageLength(value) > MAX_MESSAGE_CHARS then
        local cut = utf8.offset(value, MAX_MESSAGE_CHARS + 1)
        if cut then roomUI.roomInput.Text = value:sub(1, cut - 1) end
    end
end)
roomUI.roomSend = button(roomUI.roomThreadPane, "Send", UDim2.fromScale(0.775,0.835),
    UDim2.fromScale(0.2,0.14), C.accent)
-- Room invitations and member management (v3.7).
roomUI.roomMembersButton = button(roomUI.roomThreadPane, "Members", UDim2.fromScale(0.025,0.135),
    UDim2.fromScale(0.24,0.09), C.raised)
local roomManagementPane = make("Frame", roomsPanel, {
    BackgroundTransparency = 1, Size = UDim2.fromScale(1,1), Visible = false
})
local manageHeading = label(roomManagementPane, "Room Members", UDim2.fromScale(0.04,0.02),
    UDim2.fromScale(0.62,0.1), Enum.Font.GothamBold)
manageHeading.TextScaled = false; manageHeading.TextSize = 15
local manageBack = button(roomManagementPane, "‹ Back", UDim2.fromScale(0.72,0.02),
    UDim2.fromScale(0.25,0.12), C.raised)
local manageList = make("ScrollingFrame", roomManagementPane, {
    Position=UDim2.fromScale(0.035,0.17), Size=UDim2.fromScale(0.93,0.46),
    BackgroundTransparency=1, BorderSizePixel=0, ScrollBarThickness=3,
    AutomaticCanvasSize=Enum.AutomaticSize.Y, CanvasSize=UDim2.new()
})
make("UIListLayout",manageList,{Padding=UDim.new(0,5),SortOrder=Enum.SortOrder.LayoutOrder})
local inviteUsername = make("TextBox",roomManagementPane,{
    Position=UDim2.fromScale(0.035,0.66), Size=UDim2.fromScale(0.61,0.13),
    BackgroundColor3=C.raised, BorderSizePixel=0, Text="",
    PlaceholderText="Invite @username (private owner)",
    PlaceholderColor3=C.muted,TextColor3=C.text,Font=Enum.Font.Gotham,
    TextSize=13,ClearTextOnFocus=false,TextXAlignment=Enum.TextXAlignment.Left
})
corner(inviteUsername,0.1)
local inviteSend = button(roomManagementPane,"Invite",UDim2.fromScale(0.67,0.66),
    UDim2.fromScale(0.3,0.13),C.accent)
local leaveRoomButton = button(roomManagementPane,"Leave Room",UDim2.fromScale(0.035,0.83),
    UDim2.fromScale(0.4,0.12),C.raised)
local manageStatus = label(roomManagementPane,"",UDim2.fromScale(0.46,0.82),
    UDim2.fromScale(0.5,0.15))
manageStatus.TextScaled=false;manageStatus.TextSize=11
-- Owner-only room deletion. Confirmation prevents accidental permanent deletion.
local deleteUI = {}
deleteUI.button = button(roomManagementPane, "Delete Room", UDim2.fromScale(0.035,0.83),
    UDim2.fromScale(0.4,0.12), Color3.fromRGB(124,47,62))
deleteUI.overlay = make("Frame", roomsPanel, {
    Size=UDim2.fromScale(1,1), BackgroundColor3=Color3.fromRGB(0,0,0),
    BackgroundTransparency=0.24, BorderSizePixel=0, Visible=false, ZIndex=40
})
deleteUI.dialog = make("Frame", deleteUI.overlay, {
    AnchorPoint=Vector2.new(0.5,0.5), Position=UDim2.fromScale(0.5,0.5),
    Size=UDim2.fromScale(0.9,0.46), BackgroundColor3=C.raised,
    BorderSizePixel=0, ZIndex=41
})
corner(deleteUI.dialog,0.07)
deleteUI.title = label(deleteUI.dialog,"Delete this room permanently?",
    UDim2.fromScale(0.04,0.06),UDim2.fromScale(0.92,0.19),Enum.Font.GothamBold)
deleteUI.title.ZIndex=42; deleteUI.title.TextScaled=false; deleteUI.title.TextSize=14
deleteUI.detail = label(deleteUI.dialog,"All room messages and memberships will be deleted. This cannot be undone.",
    UDim2.fromScale(0.04,0.28),UDim2.fromScale(0.92,0.27))
deleteUI.detail.ZIndex=42; deleteUI.detail.TextWrapped=true
deleteUI.detail.TextScaled=false; deleteUI.detail.TextSize=12
deleteUI.cancel = button(deleteUI.dialog,"Cancel",UDim2.fromScale(0.04,0.68),
    UDim2.fromScale(0.43,0.23),C.bg)
deleteUI.confirm = button(deleteUI.dialog,"Delete",UDim2.fromScale(0.53,0.68),
    UDim2.fromScale(0.43,0.23),Color3.fromRGB(124,47,62))
deleteUI.cancel.ZIndex=42; deleteUI.confirm.ZIndex=42

-- Private-room owner moderation. Public rooms never expose this control.
local kickUI = {}
kickUI.overlay = make("Frame", roomsPanel, {
    Size=UDim2.fromScale(1,1), BackgroundColor3=Color3.fromRGB(0,0,0),
    BackgroundTransparency=0.24, BorderSizePixel=0, Visible=false, ZIndex=45
})
kickUI.dialog = make("Frame",kickUI.overlay,{
    AnchorPoint=Vector2.new(0.5,0.5), Position=UDim2.fromScale(0.5,0.5),
    Size=UDim2.fromScale(0.9,0.43), BackgroundColor3=C.raised,
    BorderSizePixel=0,ZIndex=46
})
corner(kickUI.dialog,0.07)
kickUI.title=label(kickUI.dialog,"Remove member?",UDim2.fromScale(0.04,0.08),
    UDim2.fromScale(0.92,0.19),Enum.Font.GothamBold)
kickUI.title.ZIndex=47;kickUI.title.TextScaled=false;kickUI.title.TextSize=14
kickUI.detail=label(kickUI.dialog,"They will lose access to this private room and its messages.",
    UDim2.fromScale(0.04,0.3),UDim2.fromScale(0.92,0.26))
kickUI.detail.ZIndex=47;kickUI.detail.TextWrapped=true
kickUI.detail.TextScaled=false;kickUI.detail.TextSize=12
kickUI.cancel=button(kickUI.dialog,"Cancel",UDim2.fromScale(0.04,0.68),
    UDim2.fromScale(0.43,0.23),C.bg)
kickUI.confirm=button(kickUI.dialog,"Kick",UDim2.fromScale(0.53,0.68),
    UDim2.fromScale(0.43,0.23),Color3.fromRGB(124,47,62))
kickUI.cancel.ZIndex=47;kickUI.confirm.ZIndex=47
kickUI.target=nil;kickUI.busy=false
local inviteInboxButton = button(roomListPane,"Invites",UDim2.fromScale(0.45,0.015),
    UDim2.fromScale(0.235,0.105),C.raised)
local inboxPane = make("Frame",roomsPanel,{
    BackgroundTransparency=1,Size=UDim2.fromScale(1,1),Visible=false
})
local inboxTitle=label(inboxPane,"Room Invitations",UDim2.fromScale(0.04,0.02),
    UDim2.fromScale(0.62,0.1),Enum.Font.GothamBold)
inboxTitle.TextScaled=false;inboxTitle.TextSize=15
local inboxBack=button(inboxPane,"‹ Back",UDim2.fromScale(0.72,0.02),
    UDim2.fromScale(0.25,0.12),C.raised)
local inboxList=make("ScrollingFrame",inboxPane,{
    Position=UDim2.fromScale(0.035,0.17),Size=UDim2.fromScale(0.93,0.8),
    BackgroundTransparency=1,BorderSizePixel=0,ScrollBarThickness=3,
    AutomaticCanvasSize=Enum.AutomaticSize.Y,CanvasSize=UDim2.new()
})
make("UIListLayout",inboxList,{Padding=UDim.new(0,6),SortOrder=Enum.SortOrder.LayoutOrder})
local roomUnreadCounts={}
local roomInvites={}
local roomInviteCount=0
local function updateRoomBadge()
    local total=roomInviteCount
    for _,n in pairs(roomUnreadCounts) do total += tonumber(n) or 0 end
    tabButtons[2].Text=total>0 and ("Rooms ("..math.min(total,99)..")") or "Rooms"
    inviteInboxButton.Text=roomInviteCount>0 and ("Invites ("..roomInviteCount..")") or "Invites"
end
local function fetchRoomNotifications()
    if not alive or not supabaseUserId then return end
    local code,counts=authorized("POST","/rest/v1/rpc/shadowchat_room_unread",{})
    if code==200 and type(counts)=="table" then
        roomUnreadCounts={}
        for _,r in ipairs(counts) do
            roomUnreadCounts[(r.is_private and "private:" or "public:")..tostring(r.room_id)] = tonumber(r.unread_count) or 0
        end
    end
    local inviteCode,invites=authorized("POST","/rest/v1/rpc/shadowchat_list_room_invites",{})
    if inviteCode==200 and type(invites)=="table" then
        roomInvites=invites
        roomInviteCount=#invites
    end
    if alive then updateRoomBadge() end
end
local roomRows = {}
local currentPublicRoom = nil
local publicRooms = {}
local privateRooms = {}
local roomSeen = {}
local roomBusy = false
local roomPollBusy = false
local function clearRoomItems(container)
    for _, child in ipairs(container:GetChildren()) do
        if child:IsA("GuiObject") then child:Destroy() end
    end
end
local function roomView(which)
    if deleteUI then deleteUI.overlay.Visible=false end
    if kickUI then kickUI.overlay.Visible=false; kickUI.target=nil end
    roomListPane.Visible = which == "list"
    roomUI.roomCreatePane.Visible = which == "create"
    roomJoinPane.Visible = false
    roomUI.roomThreadPane.Visible = which == "thread"
    roomManagementPane.Visible = which == "members"
    inboxPane.Visible = which == "inbox"
    if which ~= "thread" and which ~= "members" then currentPublicRoom = nil end
end
local function refreshMembers()
    if not currentPublicRoom then return end
    local r=currentPublicRoom
    manageHeading.Text="Members · "..tostring(r.name)
    local code,members,raw=authorized("POST","/rest/v1/rpc/shadowchat_room_members",
        {p_room_id=r.id,p_private=r.private==true})
    clearRoomItems(manageList)
    if code~=200 or type(members)~="table" then
        manageStatus.Text="Unable to load members ("..tostring(code)..")"
        warn("[ShadowChat] Room members:",raw)
        return
    end
    local owner=false
    for _,m in ipairs(members) do
        if m.user_id==supabaseUserId then owner=m.is_owner==true end
    end
    for i,m in ipairs(members) do
        local canKick=r.private==true and owner and not m.is_owner and m.user_id~=supabaseUserId
        local row=make("Frame",manageList,{
            Size=UDim2.new(1,-8,0,isMobileLayout and 43 or 34),
            BackgroundTransparency=1,BorderSizePixel=0,LayoutOrder=i
        })
        local line=label(row,(m.is_owner and "★ " or "@")..tostring(m.username or "Member"),
            UDim2.new(),UDim2.new(canKick and 0.69 or 1,-4,1,0))
        line.TextScaled=false;line.TextSize=isMobileLayout and 14 or 15
        if canKick then
            local kick=button(row,"Kick",UDim2.fromScale(0.72,0.08),
                UDim2.fromScale(0.26,0.84),Color3.fromRGB(124,47,62))
            kick.TextScaled=false;kick.TextSize=isMobileLayout and 13 or 12
            connect(kick.Activated,function()
                if kickUI.busy or not currentPublicRoom or currentPublicRoom.id~=r.id then return end
                kickUI.target={room_id=r.id,user_id=m.user_id,username=tostring(m.username or "Member")}
                kickUI.title.Text="Kick @"..kickUI.target.username.."?"
                kickUI.overlay.Visible=true
            end)
        end
    end
    inviteUsername.Visible=r.private and owner
    inviteSend.Visible=r.private and owner
    leaveRoomButton.Visible=not owner
    deleteUI.button.Visible=owner
    manageStatus.Text=owner and "Owner" or (tostring(#members).." members")
end
connect(kickUI.cancel.Activated,function()
    if not kickUI.busy then kickUI.overlay.Visible=false;kickUI.target=nil end
end)
connect(kickUI.confirm.Activated,function()
    local target=kickUI.target
    if kickUI.busy or not target or not currentPublicRoom or not currentPublicRoom.private
        or currentPublicRoom.id~=target.room_id then return end
    kickUI.busy=true;kickUI.confirm.Text="Kicking..."
    task.spawn(function()
        local code,_,raw=authorized("POST","/rest/v1/rpc/shadowchat_kick_private_member",
            {p_room_id=target.room_id,p_user_id=target.user_id})
        kickUI.busy=false;kickUI.confirm.Text="Kick"
        if not alive then return end
        kickUI.overlay.Visible=false;kickUI.target=nil
        if code==200 or code==204 then
            if currentPublicRoom and currentPublicRoom.id==target.room_id then
                refreshMembers()
            end
        else
            manageStatus.Text="Kick failed ("..tostring(code)..")"
            warn("[ShadowChat] Kick member:",raw)
        end
    end)
end)
connect(deleteUI.button.Activated,function()
    if not currentPublicRoom then return end
    deleteUI.title.Text="Delete #"..tostring(currentPublicRoom.name).."?"
    deleteUI.overlay.Visible=true
end)
connect(deleteUI.cancel.Activated,function() deleteUI.overlay.Visible=false end)
connect(deleteUI.confirm.Activated,function()
    if not currentPublicRoom or deleteUI.confirm.Text=="Deleting..." then return end
    local target=currentPublicRoom
    deleteUI.confirm.Text="Deleting..."
    task.spawn(function()
        local code,_,raw=authorized("POST","/rest/v1/rpc/shadowchat_delete_room",
            {p_room_id=target.id,p_private=target.private==true})
        deleteUI.confirm.Text="Delete"
        if not alive then return end
        if code==200 or code==204 then
            deleteUI.overlay.Visible=false
            roomView("list")
            fetchRoomNotifications()
            if refreshPublicRooms then refreshPublicRooms() end
        else
            deleteUI.overlay.Visible=false
            manageStatus.Text="Delete failed ("..tostring(code)..")"
            warn("[ShadowChat] Delete room:",raw)
        end
    end)
end)
local function drawInviteInbox()
    clearRoomItems(inboxList)
    if #roomInvites==0 then
        local empty=label(inboxList,"No pending invitations",UDim2.new(),UDim2.new(1,-5,0,45))
        empty.TextScaled=false;empty.TextSize=14
    end
    for i,invite in ipairs(roomInvites) do
        local item=make("Frame",inboxList,{
            BackgroundColor3=C.raised,BorderSizePixel=0,
            Size=UDim2.new(1,-5,0,isMobileLayout and 88 or 77),LayoutOrder=i
        })
        corner(item,0.08)
        local name=label(item,"# "..tostring(invite.room_name).." · from @"..tostring(invite.inviter_name),
            UDim2.fromScale(0.03,0.04),UDim2.fromScale(0.94,0.36))
        name.TextScaled=false;name.TextSize=12
        local accept=button(item,"Accept",UDim2.fromScale(0.03,0.49),UDim2.fromScale(0.44,0.43),C.accent)
        local decline=button(item,"Decline",UDim2.fromScale(0.53,0.49),UDim2.fromScale(0.44,0.43),C.raised)
        local function respond(yes)
            accept.Active=false;decline.Active=false
            task.spawn(function()
                local code,_,raw=authorized("POST","/rest/v1/rpc/shadowchat_respond_room_invite",
                    {p_invite_id=invite.id,p_accept=yes})
                if code~=200 and code~=204 then
                    warn("[ShadowChat] Invitation response:",code,raw)
                end
                fetchRoomNotifications()
                drawInviteInbox()
                if refreshPublicRooms then refreshPublicRooms() end
            end)
        end
        connect(accept.Activated,function() respond(true) end)
        connect(decline.Activated,function() respond(false) end)
    end
end
connect(inviteInboxButton.Activated,function()
    task.spawn(function() fetchRoomNotifications();drawInviteInbox();roomView("inbox") end)
end)
connect(inboxBack.Activated,function() roomView("list") end)
connect(roomUI.roomMembersButton.Activated,function()
    if not currentPublicRoom then return end
    roomView("members")
    task.spawn(refreshMembers)
end)
connect(manageBack.Activated,function() roomView("thread") end)
connect(inviteSend.Activated,function()
    if not currentPublicRoom or not currentPublicRoom.private then return end
    local name=inviteUsername.Text:gsub("^@",""):match("^%s*(.-)%s*$")
    if name=="" then return end
    local room=currentPublicRoom
    manageStatus.Text="Inviting..."
    task.spawn(function()
        local code,result,raw=authorized("POST","/rest/v1/rpc/shadowchat_invite_to_room",
            {p_room_id=room.id,p_username=name})
        if not alive then return end
        manageStatus.Text=code==200 and tostring(result or "Invitation sent") or ("Invite failed ("..tostring(code)..")")
        if code==200 then
            if inviteUsername.Text:gsub("^@",""):match("^%s*(.-)%s*$")==name then
                inviteUsername.Text=""
            end
        else
            warn("[ShadowChat] Invite failed:",raw)
        end
    end)
end)
connect(leaveRoomButton.Activated,function()
    if not currentPublicRoom then return end
    local room=currentPublicRoom
    manageStatus.Text="Leaving..."
    task.spawn(function()
        local code,_,raw=authorized("POST","/rest/v1/rpc/shadowchat_leave_room",
            {p_room_id=room.id,p_private=room.private==true})
        if not alive then return end
        if code==200 or code==204 then
            roomView("list")
            fetchRoomNotifications()
            if refreshPublicRooms then refreshPublicRooms() end
        else
            manageStatus.Text="Leave failed ("..tostring(code)..")"
            warn("[ShadowChat] Leave room:",raw)
        end
    end)
end)
local function drawPublicRooms()
    clearRoomItems(roomUI.roomsList)
    local query = roomUI.roomSearch.Text:lower()
    local count = 0
    local combinedRooms = {}
    for _, r in ipairs(publicRooms) do
        r.private = false
        table.insert(combinedRooms, r)
    end
    for _, r in ipairs(privateRooms) do
        r.private = true
        table.insert(combinedRooms, r)
    end
    for _, r in ipairs(combinedRooms) do
        local name = tostring(r.name or "Unnamed")
        local desc = tostring(r.description or "")
        if query == "" or name:lower():find(query,1,true)
            or desc:lower():find(query,1,true) then
            count += 1
            local item = button(roomUI.roomsList, "", UDim2.new(), UDim2.new(1,-5,0,isMobileLayout and 54 or 57), C.raised)
            item.Text = ""; item.LayoutOrder = count
            local title = label(item, (r.private and "[Private] " or "# ") .. name, UDim2.fromScale(0.03,0.07),
                UDim2.fromScale(0.94,0.43), Enum.Font.GothamBold)
            title.TextScaled = false; title.TextSize = isMobileLayout and 13 or 13
            local subtitle = label(item, desc ~= "" and desc or (r.private and "Private room" or "Public room"),
                UDim2.fromScale(0.03,0.53), UDim2.fromScale(0.94,0.37))
            subtitle.TextScaled = false; subtitle.TextSize = isMobileLayout and 11 or 11
            subtitle.TextColor3 = C.muted
            local unread=roomUnreadCounts[(r.private and "private:" or "public:")..tostring(r.id)] or 0
            if unread>0 then
                local unreadLabel=label(item,tostring(math.min(unread,99)).." new",
                    UDim2.fromScale(0.78,0.05),UDim2.fromScale(0.2,0.4),Enum.Font.GothamBold)
                unreadLabel.TextScaled=false;unreadLabel.TextSize=11
                unreadLabel.TextColor3=C.accent
            end
            connect(item.Activated, function()
                if roomBusy then return end
                if r.private then
                    -- The database only returns private rooms for existing members.
                    currentPublicRoom = r
                    roomSeen = {}
                    roomUI.roomTitle.Text = "# " .. name
                    clearRoomItems(roomUI.roomThread)
                    roomView("thread")
                    return
                end
                roomBusy = true
                task.spawn(function()
                    local code, _, raw = authorized("POST",
                        "/rest/v1/rpc/shadowchat_join_public_room", {p_room_id = r.id})
                    roomBusy = false
                    if not alive then return end
                    if code ~= 200 and code ~= 204 then
                        roomUI.roomsInfo.Text = "Join failed (" .. tostring(code) .. ")"
                        warn("[ShadowChat] Public room join:", raw)
                        return
                    end
                    currentPublicRoom = r
                    roomSeen = {}
                    roomUI.roomTitle.Text = "# " .. name
                    clearRoomItems(roomUI.roomThread)
                    roomView("thread")
                    currentPublicRoom = r
                end)
            end)
        end
    end
    roomUI.roomsInfo.Text = tostring(count) .. " rooms shown (public + joined private)"
end
connect(roomUI.roomSearch:GetPropertyChangedSignal("Text"), drawPublicRooms)
refreshPublicRooms = function()
    if not alive or not supabaseUserId then return end
    local code, data, raw = authorized("GET",
        "/rest/v1/shadowchat_public_rooms?select=id,name,description,created_at&order=created_at.desc&limit=100")
    if not alive then return end
    if code == 200 and type(data) == "table" then
        publicRooms = data
        local privateCode, privateData, privateRaw = authorized("GET",
            "/rest/v1/shadowchat_private_rooms?select=id,name,description,created_at&order=created_at.desc&limit=100")
        if privateCode == 200 and type(privateData) == "table" then
            privateRooms = privateData
        else
            privateRooms = {}
            warn("[ShadowChat] Private rooms fetch:", privateCode, privateRaw)
        end
        drawPublicRooms()
    else
        roomUI.roomsInfo.Text = "Rooms unavailable (" .. tostring(code) .. ")"
        warn("[ShadowChat] Public rooms fetch:", raw)
    end
end
connect(roomUI.createRoomBtn.Activated, function() roomView("create") end)
connect(roomUI.createBack.Activated, function() roomView("list") end)
connect(roomUI.roomBack.Activated, function()
    roomView("list")
    task.spawn(refreshPublicRooms)
end)
connect(roomUI.createSubmit.Activated, function()
    if roomBusy then return end
    local name = roomUI.roomNameInput.Text:match("^%s*(.-)%s*$")
    local desc = roomUI.roomDescInput.Text:match("^%s*(.-)%s*$")
    if #name < 3 or #name > 40 or #desc > 200 then
        roomUI.roomCreateStatus.Text = "Name: 3–40 chars; description: max 200."
        return
    end
    local private = privateCreateMode
    roomBusy = true
    roomUI.roomCreateStatus.Text = "Creating..."
    task.spawn(function()
        local code, id, raw
        if private then
            code, id, raw = authorized("POST",
                "/rest/v1/rpc/shadowchat_create_invite_room",
                {p_name = name, p_description = desc})
        else
            code, id, raw = authorized("POST",
                "/rest/v1/rpc/shadowchat_create_public_room",
                {p_name = name, p_description = desc})
        end
        roomBusy = false
        if not alive then return end
        if code == 200 and type(id) == "string" then
            roomUI.roomNameInput.Text = ""; roomUI.roomDescInput.Text = ""
            roomPasswordInput.Text = ""
            roomUI.roomCreateStatus.Text = ""
            roomView("list")
            refreshPublicRooms()
        else
            roomUI.roomCreateStatus.Text = "Create failed (" .. tostring(code) .. ")"
            warn("[ShadowChat] Create public room:", raw)
        end
    end)
end)
local function verifyCurrentPrivateMembership(room)
    if not room or not room.private then return true end
    local code, rows = authorized("POST", "/rest/v1/rpc/shadowchat_room_members",
        {p_room_id=room.id, p_private=true})
    if code==200 and type(rows)=="table" then
        for _, member in ipairs(rows) do
            if member.user_id==supabaseUserId then return true end
        end
    end
    -- Only a definite authorization failure proves removal; don't eject on outages.
    if code==200 or code==400 or code==401 or code==403 or code==404 then
        if currentPublicRoom and currentPublicRoom.id==room.id then
            roomUI.roomInput.Text=""
            roomView("list")
            task.spawn(function() if alive then refreshPublicRooms() end end)
            warn("[ShadowChat] Private room membership ended; returned to Rooms.")
        end
        return false
    end
    return nil
end
local function pollPublicRoom()
    if not alive or not currentPublicRoom or roomPollBusy or activeTab ~= "Rooms" then return end
    roomPollBusy = true
    local membership=verifyCurrentPrivateMembership(currentPublicRoom)
    if membership~=true then
        roomPollBusy=false
        return
    end
    local id = currentPublicRoom.id
    local tableName = currentPublicRoom.private and "shadowchat_private_messages" or "shadowchat_public_messages"
    local path = "/rest/v1/" .. tableName .. "?room_id=eq." .. id
        .. "&select=id,sender_id,body,created_at&order=id.desc&limit=500"
    local code, data, raw = authorized("GET", path)
    roomPollBusy = false
    if not alive or not currentPublicRoom or currentPublicRoom.id ~= id then return end
    if code ~= 200 or type(data) ~= "table" then
        warn("[ShadowChat] Public room messages:", code, raw)
        return
    end
    local added = false
    for idx = #data, 1, -1 do
        local msg = data[idx]
        if msg.id and not roomSeen[msg.id] then
            roomSeen[msg.id] = true
            added = true
            local mine = msg.sender_id == supabaseUserId
            local name = mine and "You" or "Member"
            local username = nil
            for _, p in ipairs(presenceRows) do
                if p.user_id == msg.sender_id then
                    username = p.roblox_username
                    break
                end
            end
            if not mine and username then name = "@" .. username end
            local body = tostring(msg.body or "")
            local contentText = name .. ": " .. body
            local mobileRoomText = isMobileLayout
            local fontSize = mobileRoomText and 13 or 18
            local roomFont = mobileRoomText and Enum.Font.Gotham or Enum.Font.SourceSans
            local width = math.max(80, roomUI.roomThread.AbsoluteSize.X - 24)
            local height = math.max(fontSize + 5,
                TextService:GetTextSize(contentText, fontSize, roomFont,
                    Vector2.new(width,10000)).Y + 5)
            local item = make("Frame", roomUI.roomThread, {
                BackgroundTransparency = 1, Size = UDim2.new(1,-5,0,height),
                LayoutOrder = tonumber(msg.id) or 0
            })
            local lbl = make("TextLabel", item, {
                BackgroundTransparency = 1, Size = UDim2.new(1,-10,1,0),
                Position = UDim2.new(0,5,0,0),
                Text = '<font color="' .. (mine and "#4E99FF" or "#91BEFF") .. '"><b>'
                    .. escapeRich(name .. ":") .. '</b></font> ' .. escapeRich(body),
                RichText = true,
                Font = roomFont, TextSize = fontSize, TextScaled = false,
                TextColor3 = C.text, TextWrapped = true,
                TextXAlignment = Enum.TextXAlignment.Left,
                TextYAlignment = Enum.TextYAlignment.Top
            })
            local prefixWidth = TextService:GetTextSize(name .. ":", fontSize,
                Enum.Font.SourceSans, Vector2.new(10000,100)).X
            local overlay = make("TextLabel", item, {
                BackgroundTransparency = 1, Position = UDim2.new(0,5,0,0),
                Size = UDim2.new(0,prefixWidth+1,0,fontSize+6),
                Text = name .. ":", Font = Enum.Font.SourceSans,
                TextSize = fontSize, TextScaled = false,
                TextColor3 = mine and C.accent or Color3.fromRGB(145,190,255),
                TextXAlignment = Enum.TextXAlignment.Left,
                Visible = false
            })
        end
    end
    if activeTab=="Rooms" and roomUI.roomThreadPane.Visible then
        local wasPrivate=currentPublicRoom.private==true
        task.spawn(function()
            local readCode=authorized("POST","/rest/v1/rpc/shadowchat_mark_room_read",
                {p_room_id=id,p_private=wasPrivate})
            if (readCode==200 or readCode==204) and alive then
                roomUnreadCounts[(wasPrivate and "private:" or "public:")..tostring(id)]=0
                updateRoomBadge()
            end
        end)
    end
    trimMessageFrames(roomUI.roomThread)
    if added then
        task.defer(function()
            if alive and roomUI.roomThread.Parent then
                RunService.Heartbeat:Wait()
                roomUI.roomThread.CanvasPosition = Vector2.new(0,
                    math.max(0, roomUI.roomThread.AbsoluteCanvasSize.Y - roomUI.roomThread.AbsoluteWindowSize.Y))
            end
        end)
    end
end
local function sendPublicRoom()
    if not currentPublicRoom or roomBusy then return end
    local body = roomUI.roomInput.Text:match("^%s*(.-)%s*$")
    if #body < 1 or messageLength(body) > MAX_MESSAGE_CHARS then return end
    roomBusy = true
    local room=currentPublicRoom
    local id=room.id
    task.spawn(function()
        local membership=verifyCurrentPrivateMembership(room)
        if membership~=true then
            roomBusy=false
            return
        end
        if not currentPublicRoom or currentPublicRoom.id~=id then
            roomBusy=false
            return
        end
        roomUI.roomInput.Text=""
        local tableName = room.private
            and "shadowchat_private_messages" or "shadowchat_public_messages"
        local code, _, raw = authorized("POST", "/rest/v1/" .. tableName,
            {room_id = id, sender_id = supabaseUserId, body = body})
        roomBusy = false
        if not alive then return end
        if code == 201 then
            pollPublicRoom()
        else
            if currentPublicRoom and currentPublicRoom.id==id and roomUI.roomInput.Text == "" then
                roomUI.roomInput.Text = body
            end
            if room.private and (code==401 or code==403 or code==404) then
                verifyCurrentPrivateMembership(room)
            end
            warn("[ShadowChat] Public room send:", code, raw)
        end
    end)
end
connect(roomUI.roomSend.Activated, sendPublicRoom)
connect(roomUI.roomInput.FocusLost, function(enter) if enter then sendPublicRoom() end end)
for i, b in ipairs(tabButtons) do
    local tab = tabNames[i]
    connect(b.Activated, function() showTab(tab) end)
end
local function drawPlayers()
    if not alive then return end
    for _, child in ipairs(playersScroll:GetChildren()) do
        if child:IsA("GuiObject") then child:Destroy() end
    end
    local query = playerSearch.Text:lower()
    local shown = 0
    for _, entry in ipairs(presenceRows) do
        local username = tostring(entry.roblox_username or "Unknown")
        local display = tostring(entry.roblox_display_name or username)
        if query == "" or username:lower():find(query, 1, true)
            or display:lower():find(query, 1, true) then
            shown += 1
            local row = button(playersScroll, "", UDim2.new(), UDim2.new(1, -5, 0, 52), C.raised)
            row.Name = "Player_" .. tostring(shown)
            row.LayoutOrder = shown
            row.Text = ""
            local displayLabel = label(row, display,
                UDim2.fromScale(0.035, 0.06), UDim2.fromScale(0.78, 0.45),
                Enum.Font.GothamBold)
            displayLabel.TextScaled = false; displayLabel.TextSize = 14
            local handleLabel = label(row, "@" .. username,
                UDim2.fromScale(0.035, 0.50), UDim2.fromScale(0.83, 0.38))
            handleLabel.TextScaled = false; handleLabel.TextSize = 12
            handleLabel.TextColor3 = Color3.fromRGB(145,190,255)
            local dot = label(row, "●", UDim2.fromScale(0.89, 0.22),
                UDim2.fromScale(0.08, 0.5))
            dot.TextColor3 = C.green
            connect(row.Activated, function() openProfile(entry) end)
        end
    end
    playerSummary.Text = tostring(#presenceRows) .. " online · " .. tostring(shown) .. " shown"
end
connect(playerSearch:GetPropertyChangedSignal("Text"), drawPlayers)
local function heartbeatPresence()
    if not alive or not supabaseUserId then return end
    local payload = {
        user_id = supabaseUserId, roblox_username = player.Name,
        roblox_display_name = player.DisplayName,
        last_seen = os.date("!%Y-%m-%dT%H:%M:%SZ")
    }
    -- Supabase PostgREST upsert requires a unique user_id and RLS insert/update.
    local headers = {["Prefer"] = "resolution=merge-duplicates,return=minimal"}
    local function sendUpsert()
        local token = accessToken
        local opts = {
            Url = SUPABASE_URL .. "/rest/v1/shadowchat_presence?on_conflict=user_id",
            Method = "POST",
            Headers = {["apikey"] = SUPABASE_KEY,
                ["Authorization"] = "Bearer " .. token,
                ["Content-Type"] = "application/json",
                ["Prefer"] = headers.Prefer},
            Body = HttpService:JSONEncode(payload)
        }
        return pcall(requestFn, opts)
    end
    if os.time() >= (expiresAt or 0) - 120 and not refreshAuth() then return end
    local ok, res = sendUpsert()
    if not ok or type(res) ~= "table" or
        (tonumber(res.StatusCode or res.Status) or 0) >= 300 then
        if alive then warn("[ShadowChat] Presence heartbeat failed. Check setup SQL/RLS.") end
    else
        presenceReady = true
    end
end
-- Parse a Supabase UTC timestamp using Roblox's ISO-8601 parser.
-- Invalid/missing timestamps must never count as online.
local function presenceTimestamp(value)
    if type(value) ~= "string" then return nil end
    local ok, result = pcall(function() return DateTime.fromIsoDate(value) end)
    return ok and result and result.UnixTimestamp or nil
end

local function normalizePresence(rows)
    local now = os.time()
    local byAccount = {}
    for _, entry in ipairs(rows) do
        local last = presenceTimestamp(entry.last_seen)
        -- Allow a small clock discrepancy, but never show expired entries.
        if last and last >= now - PRESENCE_TIMEOUT and last <= now + 15 then
            -- Username is a temporary identity fallback: the presence table
            -- currently does not include a verified Roblox numeric UserId.
            local username = tostring(entry.roblox_username or ""):lower()
            local key = username ~= "" and username or tostring(entry.user_id or "")
            if key ~= "" then
                local previous = byAccount[key]
                if not previous or last > previous._presenceUnix then
                    local copy = {}
                    for k, v in pairs(entry) do copy[k] = v end
                    copy._presenceUnix = last
                    byAccount[key] = copy
                end
            end
        end
    end
    local unique = {}
    for _, entry in pairs(byAccount) do table.insert(unique, entry) end
    table.sort(unique, function(a, b)
        return tostring(a.roblox_username or ""):lower() < tostring(b.roblox_username or ""):lower()
    end)
    return unique
end

local function refreshPresenceDisplay()
    if not alive then return end
    local fresh = normalizePresence(presenceRows)
    if #fresh ~= #presenceRows then
        presenceRows = fresh
        drawPlayers()
        refreshDMPresence()
    end
end

local function fetchPlayers()
    if not alive or presenceBusy or not supabaseUserId then return end
    presenceBusy = true
    presenceFetchSerial += 1
    local serial = presenceFetchSerial
    local cutoff = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() - PRESENCE_TIMEOUT)
    local path = "/rest/v1/shadowchat_presence?select=user_id,roblox_username,roblox_display_name,last_seen"
        .. "&last_seen=gte." .. HttpService:UrlEncode(cutoff)
        .. "&order=last_seen.desc&limit=200"
    local code, data, raw = authorized("GET", path)
    presenceBusy = false
    if not alive or serial < presenceLastApplied then return end
    if code == 200 and type(data) == "table" then
        presenceLastApplied = serial
        presenceRows = normalizePresence(data)
        drawPlayers()
        refreshDMPresence()
    else
        -- Don't continue showing a stale directory after a failed request.
        refreshPresenceDisplay()
        playerSummary.Text = "Players unavailable (" .. tostring(code) .. ")"
        warn("[ShadowChat] Players lookup failed:", raw)
    end
end
-- Message rows use measured pixel heights. The window uses responsive Scale sizes,
-- but text is never allowed to stretch to fill a tiny row.
local function maxScroll()
    return math.max(0, scroll.AbsoluteCanvasSize.Y - scroll.AbsoluteWindowSize.Y)
end
local function nearBottom()
    return scroll.CanvasPosition.Y >= maxScroll() - 38
end
local function scrollToBottom()
    task.defer(function()
        if not alive or not scroll.Parent then return end
        RunService.Heartbeat:Wait()
        if alive and scroll.Parent then
            scroll.CanvasPosition = Vector2.new(0, maxScroll())
        end
    end)
end
local function recalcCanvas(follow)
    if not alive or not scroll.Parent then return end
    local content = layout.AbsoluteContentSize.Y + padding.PaddingTop.Offset + padding.PaddingBottom.Offset
    scroll.CanvasSize = UDim2.new(0, 0, 0, math.ceil(content))
    if follow then scrollToBottom() end
end
-- Inline username and body, matching the compact Roblox chat format.
-- Escape user-provided text before inserting it into RichText markup.
escapeRich = function(s)
    return tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
        :gsub('"', "&quot;"):gsub("'", "&apos;")
end
-- Infinite Yield uses plain TextLabels, TextWrapped, and TextBounds.Y.
-- Follow that approach on desktop. RichText font runs can alter glyph
 -- spacing; keep mobile's existing RichText path untouched.
local function measureRow(entry)
    if not alive or not entry.item.Parent then return end
    local size = typography.message
    local textLabel = entry.text
    local nameLabel = entry.nameOverlay
    local mobile = isMobileLayout
    local width = math.max(80, scroll.AbsoluteSize.X - 7 - 10 - 18 - 16)

    textLabel.TextSize = size
    textLabel.Font = mobile and Enum.Font.Gotham or Enum.Font.SourceSans
    textLabel.FontFace = Font.fromEnum(textLabel.Font)
    textLabel.LineHeight = mobile and 1 or 1
    textLabel.RichText = mobile
    textLabel.Text = mobile and entry.rich or (entry.name .. ": " .. entry.body)
    textLabel.Position = UDim2.new(0, 8, 0, mobile and 2 or 0)
    textLabel.Size = UDim2.new(1, -16, 0, 100000)

    if mobile then
        nameLabel.Visible = false
        local bounds = TextService:GetTextSize(entry.name .. ": " .. entry.body,
            size, Enum.Font.Gotham, Vector2.new(width, 100000))
        local height = math.max(math.ceil(size * 1.3), bounds.Y + 3)
        entry.item.Size = UDim2.new(1, 0, 0, height + 5)
        textLabel.Size = UDim2.new(1, -16, 0, height)
    else
        -- Use the label's actual rendered bounds instead of estimating
        -- wrapped text with a different font or extra multipliers.
        local bounds = TextService:GetTextSize(textLabel.Text, size,
            Enum.Font.SourceSans, Vector2.new(width, 100000))
        local height = math.max(math.ceil(size * 1.2), bounds.Y, textLabel.TextBounds.Y)
        entry.item.Size = UDim2.new(1, 0, 0, height + 1)
        textLabel.Size = UDim2.new(1, -16, 0, height + 1)

        -- Draw the colored username over the same plain-text glyphs.
        -- Both labels use identical font, size and origin, so the body
        -- remains a single uninterrupted plain-text layout.
        local prefix = entry.name .. ":"
        local prefixWidth = TextService:GetTextSize(prefix, size,
            Enum.Font.SourceSans, Vector2.new(100000, 100)).X
        nameLabel.Visible = prefixWidth < width
        nameLabel.Font = Enum.Font.SourceSans
        nameLabel.FontFace = Font.fromEnum(Enum.Font.SourceSans)
        nameLabel.TextSize = size
        nameLabel.Text = prefix
        nameLabel.Position = UDim2.new(0, 8, 0, 0)
        nameLabel.Size = UDim2.new(0, prefixWidth + 1, 0, height + 1)
    end
end

local function addMessage(name, body, mine)
    if not alive then return end
    local follow = messageCount == 0 or nearBottom()
    messageCount += 1
    local item = make("Frame", scroll, {
        BackgroundColor3 = mine and Color3.fromRGB(31, 40, 54) or C.raised,
        BackgroundTransparency = 1, BorderSizePixel = 0,
        Size = UDim2.new(1, 0, 0, 36), LayoutOrder = messageCount
    })
    corner(item, 0.10)
    local usernameColor = mine and "#4E99FF" or "#91BEFF"
    local rich = '<font color="' .. usernameColor .. '"><b>' .. escapeRich(name) ..
        ':</b></font> ' .. escapeRich(body)
    local content = make("TextLabel", item, {
        BackgroundTransparency = 1, Text = rich, RichText = true,
        Font = Enum.Font.Gotham, TextColor3 = C.text, TextScaled = false,
        TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Top
    })
    local nameOverlay = make("TextLabel", item, {
        BackgroundTransparency = 1, Text = "", RichText = false,
        Font = Enum.Font.SourceSans, TextColor3 = mine and C.accent or Color3.fromRGB(145,190,255),
        TextScaled = false, TextWrapped = false, TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Top, ZIndex = 2, Visible = false
    })
    local entry = {item = item, text = content, nameOverlay = nameOverlay,
        name = name, body = body, rich = rich}
    table.insert(messageEntries, entry)
    measureRow(entry)
    if #messageEntries > MAX_DISPLAY_MESSAGES then
        local old = table.remove(messageEntries, 1)
        old.item:Destroy()
    end
    recalcCanvas(follow)
end

-- Scale-based layout, with separate dimensions and typography for mobile.
-- Uses the actual viewport to avoid huge windows on ultrawide monitors.
local maximized = false
local beforeMaxSize = nil
local beforeMaxPosition = nil
local beforeMaxCustomSize = nil
local function fitViewport()
    if not alive then return end
    local camera = workspace.CurrentCamera
    if not camera then return end
    local v = camera.ViewportSize
    if v.X <= 0 or v.Y <= 0 then return end
    local touch = UserInputService.TouchEnabled
    local portrait = v.Y > v.X
    local mobile = touch or v.Y < 650
    isMobileLayout = mobile
    local width, height
    if portrait then
        width = math.min(v.X * 0.80, 430)
        height = math.min(v.Y * 0.53, 540)
    elseif mobile then
        width = math.min(v.X * 0.47, 475)
        height = math.min(v.Y * 0.55, 350)
    else
        width = math.min(v.X * 0.30, 405)
        height = math.min(v.Y * 0.56, 485)
    end
    if maximized then
        width, height = v.X * 0.94, v.Y * 0.84
    elseif customSize then
        width = customSize.X * v.X
        height = customSize.Y * v.Y
    end
    width = math.clamp(width, math.min(220, v.X * 0.5), v.X * 0.94)
    height = math.clamp(height, math.min(180, v.Y * 0.4), v.Y * 0.84)
    frame.Size = UDim2.fromScale(width / v.X, height / v.Y)
    typography.message = mobile and 13 or 18
    typography.name = typography.message
    typography.title = mobile and 16 or 17
    typography.tabs = mobile and 12 or 13
    typography.input = mobile and 13 or 14
    typography.status = mobile and 10 or 11
    titleLabel.TextScaled = false; titleLabel.TextSize = typography.title
    for _, b in ipairs(tabButtons) do b.TextScaled = false; b.TextSize = typography.tabs end
    minimize.TextScaled = false; minimize.TextSize = typography.title
    maximize.TextScaled = false; maximize.TextSize = typography.title
    close.TextScaled = false; close.TextSize = typography.title
    send.TextScaled = false; send.TextSize = typography.tabs
    input.TextScaled = false; input.TextSize = typography.input
    -- Taller input on mobile, with the Send button aligned to it.
    local inputY = mobile and 0.84 or 0.867
    local inputH = mobile and 0.11 or 0.075
    inputHolder.Position = UDim2.fromScale(0.035, inputY)
    inputHolder.Size = UDim2.fromScale(0.73, inputH)
    send.Position = UDim2.fromScale(0.785, inputY)
    send.Size = UDim2.fromScale(0.18, inputH)
    -- Keep message history clear of the larger mobile input.
    scroll.Size = UDim2.fromScale(0.93, mobile and 0.608 or 0.625)
    task.defer(followInputCaret)
    statusLabel.TextScaled = false; statusLabel.TextSize = typography.status
    playerSearch.TextSize = mobile and 13 or 14
    profileName.TextSize = mobile and 15 or 17
    -- Increase touch targets slightly on mobile without changing desktop sizing.
    -- Taller mobile touch targets, with content moved below the tab bar.
    top.Size = UDim2.fromScale(1, mobile and 0.12 or 0.105)
    tabs.Position = UDim2.fromScale(0.035, mobile and 0.135 or 0.125)
    tabs.Size = UDim2.fromScale(0.93, mobile and 0.135 or 0.085)
    scroll.Position = UDim2.fromScale(0.035, mobile and 0.285 or 0.225)
    scroll.Size = UDim2.fromScale(0.93, mobile and 0.56 or 0.625)
    playersPanel.Position = UDim2.fromScale(0.035, mobile and 0.285 or 0.225)
    playersPanel.Size = UDim2.fromScale(0.93, mobile and 0.66 or 0.715)
    dmPanel.Position = UDim2.fromScale(0.035, mobile and 0.285 or 0.225)
    dmPanel.Size = UDim2.fromScale(0.93, mobile and 0.66 or 0.715)
    if roomsPanel then
        roomsPanel.Position = UDim2.fromScale(0.035, mobile and 0.285 or 0.225)
        roomsPanel.Size = UDim2.fromScale(0.93, mobile and 0.66 or 0.715)
    end
    -- Larger, taller minimize/exit touch targets on mobile only.
    local controlWidth = mobile and 0.135 or 0.09
    local controlHeight = mobile and 0.84 or 0.68
    local controlY = mobile and 0.08 or 0.16
    minimize.Size = UDim2.fromScale(controlWidth, controlHeight)
    minimize.Position = UDim2.fromScale(mobile and 0.54 or 0.67, controlY)
    maximize.Size = UDim2.fromScale(controlWidth, controlHeight)
    maximize.Position = UDim2.fromScale(mobile and 0.695 or 0.78, controlY)
    close.Size = UDim2.fromScale(controlWidth, controlHeight)
    close.Position = UDim2.fromScale(mobile and 0.85 or 0.89, controlY)
    dmBack.TextSize = mobile and 14 or 13
    dmBack.Size = UDim2.fromScale(mobile and 0.265 or 0.245, mobile and 0.145 or 0.09)
    dmBack.Position = UDim2.fromScale(mobile and 0.71 or 0.73, 0.015)
    profileBack.Size = UDim2.fromScale(mobile and 0.38 or 0.34, mobile and 0.15 or 0.13)
    profileDM.Size = UDim2.fromScale(0.9, mobile and 0.18 or 0.16)
    dmInput.TextSize = typography.input
    dmSend.TextScaled = false
    dmSend.TextSize = typography.tabs
    -- Match the Global composer exactly in screen-space, on PC and mobile.
    -- DM controls are children of dmPanel, so convert Global frame coordinates.
    local panelY = mobile and 0.285 or 0.225
    local panelH = mobile and 0.66 or 0.715
    local dmComposerY = (inputY - panelY) / panelH
    local dmComposerH = inputH / panelH
    dmInputHolder.Position = UDim2.fromScale(0, dmComposerY)
    dmInputHolder.Size = UDim2.fromScale(0.73 / 0.93, dmComposerH)
    dmSend.Position = UDim2.fromScale((0.785 - 0.035) / 0.93, dmComposerY)
    dmSend.Size = UDim2.fromScale(0.18 / 0.93, dmComposerH)
    -- Reserve extra breathing room below the online indicator on desktop.
    dmThread.Position = UDim2.fromScale(0.025, mobile and 0.205 or 0.19)
    dmThread.Size = UDim2.fromScale(0.95, mobile and 0.59 or 0.68)
    dmTitle.Position = UDim2.fromScale(0.035, mobile and 0.018 or 0.015)
    dmTitle.Size = UDim2.fromScale(mobile and 0.68 or 0.78, mobile and 0.085 or 0.085)
    dmPresence.Position = UDim2.fromScale(0.035, mobile and 0.118 or 0.083)
    dmPresence.Size = UDim2.fromScale(0.65, mobile and 0.065 or 0.065)
    dmList.Position = UDim2.fromScale(0.025, mobile and 0.205 or 0.12)
    dmList.Size = UDim2.fromScale(0.95, mobile and 0.77 or 0.85)
    dmBack.Position = UDim2.fromScale(mobile and 0.71 or 0.73, mobile and 0.02 or 0.015)
    dmPresence.TextSize = mobile and 11 or 11
    -- Public room header matches the DM title and Back button exactly.
    roomUI.roomTitle.Position = dmTitle.Position
    roomUI.roomTitle.Size = dmTitle.Size
    roomUI.roomTitle.TextSize = dmTitle.TextSize
    roomUI.roomBack.Position = dmBack.Position
    roomUI.roomBack.Size = dmBack.Size
    -- DM Back uses TextScaled, so use the same setting rather than a fixed font size.
    roomUI.roomBack.TextScaled = dmBack.TextScaled
    roomUI.roomBack.TextSize = dmBack.TextSize
    inboxBack.Position=dmBack.Position
    inboxBack.Size=dmBack.Size
    inboxBack.TextScaled=dmBack.TextScaled
    inboxBack.TextSize=dmBack.TextSize
    manageBack.Position=dmBack.Position
    manageBack.Size=dmBack.Size
    manageBack.TextScaled=dmBack.TextScaled
    manageBack.TextSize=dmBack.TextSize
    -- Public room composer matches Global/DM frame-space dimensions.
    roomUI.roomInputHolder.Position = dmInputHolder.Position
    roomUI.roomInputHolder.Size = dmInputHolder.Size
    roomUI.roomSend.Position = dmSend.Position
    roomUI.roomSend.Size = dmSend.Size
    roomUI.roomInput.TextSize = typography.input
    roomUI.roomSend.TextScaled = false
    roomUI.roomSend.TextSize = typography.tabs
    roomUI.roomInputHolder.BackgroundTransparency = dmInputHolder.BackgroundTransparency
    -- Keep the room messages above the composer.
    -- Match Members to Back exactly on PC and mobile, in the same header row.
    roomUI.roomTitle.Size=UDim2.fromScale(0.39,0.085)
    roomUI.roomMembersButton.Position=UDim2.fromScale(mobile and 0.435 or 0.455, mobile and 0.02 or 0.015)
    roomUI.roomMembersButton.Size=dmBack.Size
    roomUI.roomMembersButton.TextScaled=dmBack.TextScaled
    roomUI.roomMembersButton.TextSize=dmBack.TextSize
    roomUI.roomThread.Position=UDim2.fromScale(0.025,mobile and 0.18 or 0.17)
    roomUI.roomThread.Size=UDim2.fromScale(0.95,mobile and 0.65 or 0.69)
    -- Increase mobile room browser controls and their vertical spacing.
    roomUI.roomsHeading.Position = UDim2.fromScale(0.03, mobile and 0.015 or 0.015)
    roomUI.roomsHeading.Size = UDim2.fromScale(0.39, mobile and 0.12 or 0.095)
    roomUI.roomsHeading.TextSize = mobile and 15 or 15
    inviteInboxButton.Position=UDim2.fromScale(0.41,0.015)
    inviteInboxButton.Size=UDim2.fromScale(0.275,mobile and 0.14 or 0.105)
    inviteInboxButton.TextScaled=false
    inviteInboxButton.TextSize=mobile and 12 or 13
    roomUI.createRoomBtn.Position = UDim2.fromScale(0.7, mobile and 0.015 or 0.015)
    roomUI.createRoomBtn.Size = UDim2.fromScale(0.275, mobile and 0.14 or 0.105)
    roomUI.createRoomBtn.TextScaled = false
    roomUI.createRoomBtn.TextSize = mobile and 13 or 13
    roomUI.roomSearch.Position = UDim2.fromScale(0.025, mobile and 0.195 or 0.14)
    roomUI.roomSearch.Size = UDim2.fromScale(0.95, mobile and 0.14 or 0.105)
    roomUI.roomSearch.TextSize = mobile and 14 or 13
    roomUI.roomsInfo.Position = UDim2.fromScale(0.035, mobile and 0.355 or 0.255)
    roomUI.roomsInfo.Size = UDim2.fromScale(0.92, mobile and 0.075 or 0.07)
    roomUI.roomsInfo.TextSize = mobile and 12 or 11
    roomUI.roomsList.Position = UDim2.fromScale(0.025, mobile and 0.445 or 0.34)
    roomUI.roomsList.Size = UDim2.fromScale(0.95, mobile and 0.53 or 0.635)
    layout.Padding = UDim.new(0, mobile and 2 or 4)
    for _, entry in ipairs(messageEntries) do measureRow(entry) end
    recalcCanvas(true)
    -- Center initially; clamp when resizing an already dragged window.
    local halfX = frame.AbsoluteSize.X / math.max(v.X, 1) / 2
    local halfY = frame.AbsoluteSize.Y / math.max(v.Y, 1) / 2
    local p = frame.Position
    frame.Position = maximized and UDim2.fromScale(0.5, 0.5) or
        UDim2.fromScale(math.clamp(p.X.Scale, halfX, 1-halfX), math.clamp(p.Y.Scale, halfY, 1-halfY))
end
fitViewport()
local lastViewport = Vector2.zero
connect(RunService.RenderStepped, function()
    local cam = workspace.CurrentCamera
    if cam and cam.ViewportSize ~= lastViewport then
        lastViewport = cam.ViewportSize
        fitViewport()
    end
end)
connect(layout:GetPropertyChangedSignal("AbsoluteContentSize"), function()
    recalcCanvas(false)
end)

-- Drag with mouse or touch, staying inside the viewport.
local dragging, dragStart, startPosition, dragInput
connect(top.InputBegan, function(inp)
    if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
        dragging = true; dragStart = inp.Position; startPosition = frame.Position
        connect(inp.Changed, function()
            if inp.UserInputState == Enum.UserInputState.End then dragging = false end
        end)
    end
end)
connect(top.InputChanged, function(inp)
    if inp.UserInputType == Enum.UserInputType.MouseMovement or inp.UserInputType == Enum.UserInputType.Touch then dragInput = inp end
end)
connect(UserInputService.InputChanged, function(inp)
    if dragging and not maximized and inp == dragInput and dragStart then
        local v = workspace.CurrentCamera.ViewportSize
        local delta = inp.Position - dragStart
        local sx = startPosition.X.Scale + delta.X / math.max(v.X, 1)
        local sy = startPosition.Y.Scale + delta.Y / math.max(v.Y, 1)
        local hx = frame.AbsoluteSize.X / math.max(v.X, 1) / 2
        local hy = frame.AbsoluteSize.Y / math.max(v.Y, 1) / 2
        frame.Position = UDim2.fromScale(math.clamp(sx, hx, 1-hx), math.clamp(sy, hy, 1-hy))
    end
end)

-- Freeform resize handle: mouse and touch. Drag the lower-right corner.
-- Store the chosen dimensions as viewport fractions so they survive a
-- resolution/orientation change. No aspect ratio lock is imposed.
local resizeGrip = make("TextButton", frame, {
    Name = "ResizeHandle", AnchorPoint = Vector2.new(1, 1),
    Position = UDim2.fromScale(0.998, 0.998),
    Size = UDim2.fromScale(0.075, 0.065),
    BackgroundTransparency = 1, BorderSizePixel = 0,
    Text = "◢", Font = Enum.Font.GothamBold,
    TextColor3 = C.muted, TextTransparency = 0.08,
    TextScaled = true, ZIndex = 20, Active = true
})
make("UITextSizeConstraint", resizeGrip, {MinTextSize = 11, MaxTextSize = 20})
local resizing = false
local resizeStart, resizeSize, resizeInput
connect(resizeGrip.InputBegan, function(inp)
    if not maximized and (inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch) then
        resizing = true
        dragging = false
        resizeStart = inp.Position
        resizeSize = frame.AbsoluteSize
        resizeInput = inp.UserInputType == Enum.UserInputType.Touch and inp or nil
        connect(inp.Changed, function()
            if inp.UserInputState == Enum.UserInputState.End then resizing = false end
        end)
    end
end)
connect(UserInputService.InputChanged, function(inp)
    if maximized or not resizing or not resizeStart then return end
    if resizeInput then
        if inp ~= resizeInput then return end
    elseif inp.UserInputType ~= Enum.UserInputType.MouseMovement then
        return
    end
    local cam = workspace.CurrentCamera
    if not cam then return end
    local v = cam.ViewportSize
    local delta = inp.Position - resizeStart
    local minW = math.min(220, v.X * 0.5)
    local minH = math.min(180, v.Y * 0.4)
    local w = math.clamp(resizeSize.X + delta.X, minW, v.X * 0.94)
    local h = math.clamp(resizeSize.Y + delta.Y, minH, v.Y * 0.84)
    customSize = Vector2.new(w / v.X, h / v.Y)
    frame.Size = UDim2.fromScale(customSize.X, customSize.Y)
    -- Keep the entire resized window visible.
    local hx, hy = w / v.X / 2, h / v.Y / 2
    frame.Position = UDim2.fromScale(
        math.clamp(frame.Position.X.Scale, hx, 1 - hx),
        math.clamp(frame.Position.Y.Scale, hy, 1 - hy))
    for _, entry in ipairs(messageEntries) do measureRow(entry) end
    recalcCanvas(false)
    task.defer(followInputCaret)
end)

-- Toggle between the largest safe viewport size and the exact prior window state.
connect(maximize.Activated, function()
    if maximized then
        maximized = false
        customSize = beforeMaxCustomSize
        frame.Size = beforeMaxSize or frame.Size
        frame.Position = beforeMaxPosition or frame.Position
        maximize.Text = "□"
        resizeGrip.Visible = true
        fitViewport()
    else
        beforeMaxSize = frame.Size
        beforeMaxPosition = frame.Position
        beforeMaxCustomSize = customSize
        maximized = true
        resizing = false
        dragging = false
        maximize.Text = "❐"
        resizeGrip.Visible = false
        fitViewport()
    end
end)
local minimized = false
local restore = button(gui, "Chat", UDim2.fromScale(0.84, 0.76), UDim2.fromScale(0.13, 0.07), C.accent)
restore.Visible = false
local function positionRestore()
    -- Mobile: upper-right, clear of the lower-right jump button.
    if isMobileLayout then
        restore.AnchorPoint = Vector2.new(1, 0)
        restore.Position = UDim2.fromScale(0.96, 0.19)
        restore.Size = UDim2.fromScale(0.12, 0.065)
    else
        restore.AnchorPoint = Vector2.new(1, 0)
        -- Mid-right, below the player list, and smaller than the mobile button.
        restore.Position = UDim2.fromScale(0.975, 0.49)
        restore.Size = UDim2.fromScale(0.085, 0.043)
    end
end
positionRestore()
connect(RunService.RenderStepped, function()
    if restore.Visible then positionRestore() end
end)
connect(restore:GetPropertyChangedSignal("Visible"), function()
    if restore.Visible then positionRestore() end
end)
connect(minimize.Activated, function() minimized = true; frame.Visible = false; restore.Visible = true end)
connect(restore.Activated, function() minimized = false; frame.Visible = true; restore.Visible = false; fitViewport() end)
-- Exit confirmation is contained inside ShadowChat and works with touch/mouse.
-- Dismissing the prompt does not interrupt polling or close the window.
local exitOverlay = make("Frame", frame, {
    Name = "ExitConfirmation", Size = UDim2.fromScale(1, 1),
    BackgroundColor3 = Color3.fromRGB(0, 0, 0), BackgroundTransparency = 0.36,
    BorderSizePixel = 0, Visible = false, Active = true, ZIndex = 80
})
corner(exitOverlay, 0.035)
local exitDialog = make("Frame", exitOverlay, {
    Name = "Dialog", AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.86, 0.42),
    BackgroundColor3 = C.panel, BorderSizePixel = 0, ZIndex = 81
})
corner(exitDialog, 0.07)
make("UIStroke", exitDialog, {Color = C.raised, Thickness = 1.5})
local exitHeading = label(exitDialog, "Exit ShadowChat?",
    UDim2.fromScale(0.07, 0.10), UDim2.fromScale(0.86, 0.25), Enum.Font.GothamBold,
    Enum.TextXAlignment.Center)
exitHeading.ZIndex = 82
local exitDescription = label(exitDialog, "Are you sure you want to exit?",
    UDim2.fromScale(0.06, 0.38), UDim2.fromScale(0.88, 0.17), Enum.Font.Gotham,
    Enum.TextXAlignment.Center)
exitDescription.ZIndex = 82
exitDescription.TextColor3 = C.muted
local exitCancel = button(exitDialog, "Cancel", UDim2.fromScale(0.07, 0.68),
    UDim2.fromScale(0.41, 0.23), C.raised)
exitCancel.ZIndex = 82
local exitConfirm = button(exitDialog, "Exit", UDim2.fromScale(0.52, 0.68),
    UDim2.fromScale(0.41, 0.23), Color3.fromRGB(111, 48, 59))
exitConfirm.ZIndex = 82
connect(close.Activated, function()
    if alive then exitOverlay.Visible = true end
end)
connect(exitCancel.Activated, function() exitOverlay.Visible = false end)
connect(exitConfirm.Activated, cleanup)

local function getMessages()
    if not roomId then return end
    local path = "/rest/v1/messages?room_id=eq." .. roomId
        .. "&select=id,body,sender_id,profile:profiles!messages_sender_id_fkey(roblox_username,roblox_display_name)"
        .. "&order=id.desc&limit=500"
    local code, messages, raw = authorized("GET", path)
    if code ~= 200 or type(messages) ~= "table" then
        status("Connection error (" .. tostring(code) .. ")", C.red)
        warn("[ShadowChat] Read failed:", raw)
        return
    end
    task.spawn(function()
        while alive do
            refreshPresenceDisplay()
            task.wait(5)
        end
    end)
    if updateDMStatus then updateDMStatus() else status("Connected · Global", C.green) end
    for i = #messages, 1, -1 do
        local m = messages[i]
        if m.id and not seen[m.id] then
            seen[m.id] = true
            if globalHistoryLoaded and activeTab ~= "Global" and m.sender_id ~= supabaseUserId then
                globalUnread += 1
                updateGlobalBadge()
            end
            local p = m.profile or {}
            local name = p.roblox_display_name or p.roblox_username or "Unknown"
            if p.roblox_display_name and p.roblox_username and p.roblox_display_name ~= p.roblox_username then
                name = p.roblox_display_name .. " (@" .. p.roblox_username .. ")"
            end
            addMessage(name, tostring(m.body or ""), m.sender_id == supabaseUserId)
        end
    end
    globalHistoryLoaded = true
end
local function sendMessage(text)
    if busy or not roomId or not alive then return end
    if type(text) ~= "string" then return end
    text = text:match("^%s*(.-)%s*$")
    if text == "" or messageLength(text) > MAX_MESSAGE_CHARS then
        status("Message must be 1–500 characters", C.red)
        return
    end
    busy = true
    -- Clear before the asynchronous request, not after it. This also prevents
    -- focus/Enter events from leaving the old message in the input field.
    local draft = text
    input.Text = ""
    status("Sending...", C.muted)
    task.spawn(function()
        local code, _, raw = authorized("POST", "/rest/v1/messages", {
            room_id = roomId, sender_id = supabaseUserId, body = draft
        })
        if not alive then return end
        busy = false
        if code == 201 then
            getMessages()
        else
            -- Preserve any new text typed while the request was in flight.
            if input.Text == "" then input.Text = draft end
            status("Send failed (" .. tostring(code) .. ")", C.red)
            warn("[ShadowChat] Send failed:", raw)
        end
    end)
end
connect(send.Activated, function() sendMessage(input.Text) end)
connect(input.FocusLost, function(enterPressed)
    if enterPressed then sendMessage(input.Text) end
end)
env.ShadowChatSend = sendMessage

-- Connect asynchronously so the UI appears immediately.
task.spawn(function()
    local saved = readSession()
    if saved and saved.refresh_token then
        refreshToken = saved.refresh_token
        status("Restoring session...")
        refreshAuth()
    end
    if not accessToken then
        status("Signing in...")
        local code, data, raw = api("POST", "/auth/v1/signup", "{}")
        if (code ~= 200 and code ~= 201) or not acceptAuth(data) then
            status("Sign-in failed (" .. tostring(code) .. ")", C.red)
            warn("[ShadowChat] Anonymous signup failed:", raw)
            return
        end
    end
    if not alive then return end
    local code, _, raw = authorized("PATCH", "/rest/v1/profiles?id=eq." .. supabaseUserId, {
        roblox_user_id = player.UserId,
        roblox_username = player.Name,
        roblox_display_name = player.DisplayName
    })
    if code ~= 204 and code ~= 200 then
        warn("[ShadowChat] Profile update failed:", code, raw)
    end
    local roomCode, rooms, roomRaw = authorized("GET", "/rest/v1/chat_rooms?kind=eq.global&select=id,name&limit=1")
    if roomCode ~= 200 or type(rooms) ~= "table" or not rooms[1] then
        status("Global room unavailable", C.red)
        warn("[ShadowChat] Room lookup failed:", roomRaw)
        return
    end
    roomId = rooms[1].id
    task.spawn(function()
        while alive do
            heartbeatPresence()
            task.wait(PRESENCE_INTERVAL)
        end
    end)
    task.spawn(function()
        while alive do
            fetchDMList()
            if dmCurrent and activeTab == "DMs" then fetchDMThread() end
            task.wait(3)
        end
    end)
    task.spawn(function()
        while alive do
            fetchRoomNotifications()
            task.wait(5)
        end
    end)
    task.spawn(function()
        while alive do
            if activeTab == "Rooms" and currentPublicRoom then pollPublicRoom() end
            task.wait(2)
        end
    end)
    task.spawn(function()
        while alive do
            fetchPlayers()
            task.wait(DIRECTORY_INTERVAL)
        end
    end)
    if updateDMStatus then updateDMStatus() else status("Connected · Global", C.green) end
    getMessages()
    while alive do
        task.wait(POLL_SECONDS)
        if alive then getMessages() end
    end
end)
print("[ShadowChat] v3.8.8 started. Use getgenv().ShadowChatStop() to close it.")
