--[=[
    monpaff MODULAR QA DEBUGGING SUITE v9.0
    Project: Rivals Internal Validation (Elite Build)
    
    [NEW IN v9.0]:
    - TP Behind: Permanent CFrame offset behind the primary target.
    - Device Spoofer: Remote-based emulation (Keyboard/Gamepad/Touch/VR).
    - Logic Patch: Optimized RenderPriority for TP-stability.
--]=]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local CoreGui = game:GetService("CoreGui")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer
local Camera = workspace.CurrentCamera

--------------------------------------------------------------------------------
-- // MEMORY MANAGEMENT //
--------------------------------------------------------------------------------
local Maid = {}
Maid.__index = Maid
function Maid.new() return setmetatable({_tasks = {}}, Maid) end
function Maid:GiveTask(task) table.insert(self._tasks, task) return task end
function Maid:DoCleaning()
    for _, task in ipairs(self._tasks) do
        if typeof(task) == "Instance" then task:Destroy()
        elseif typeof(task) == "function" then task()
        elseif task.Disconnect then task:Disconnect()
        elseif task.Destroy then task:Destroy() end
    end
    table.clear(self._tasks)
end

if _G.monpaffRunning then _G.monpaffMaid:DoCleaning() end
_G.monpaffMaid = Maid.new()
local GlobalMaid = _G.monpaffMaid
_G.monpaffRunning = true

--------------------------------------------------------------------------------
-- // SETTINGS & STATE //
--------------------------------------------------------------------------------
local Settings = {
    UI_Visible = true,
    CurrentTab = "Combat",
    
    -- Combat & TP
    Aimbot = false,
    AimbotKey = Enum.KeyCode.E,
    Triggerbot = false,
    TPBehind = false,
    WallCheck = true,
    DeathCheck = true,
    TeamCheck = true,
    AutoFire = false,
    AutoFireCooldown = 0.11, -- [IMPROVED] Slightly longer for more legit feel
    AutoFireReaction = 50, -- [NEW] Reaction time in MS (50-200 for human-like, lower = faster)
    TargetFOV = 150,
    Smoothness = 0.21, -- [IMPROVED] Higher smoothness = slower, more human-like tracking
    TargetPart = "UpperTorso",
    AimPriority = "FOV", -- [NEW] "FOV" or "Distance" - FOV is more legit
    
    -- Visuals
    ESP = true,
    Vitals = true,
    ShowFOV = true,
    DiscreetMode = false,
    CameraFOV = 70,
    ToggleMenuKey = Enum.KeyCode.V,
    
    -- Movement
    SpeedBoost = false,
    Fly = false,
    Noclip = false,
    FlySpeed = 50,
    
    -- Aesthetic
    Accent = Color3.fromRGB(138, 43, 226),
    BG = Color3.fromRGB(15, 15, 20),
    SidebarBG = Color3.fromRGB(25, 25, 35),
    
    -- Ally Capture
    CaptureRadius = 50
}

local Allies = {}
local lastShotTime = 0
local currentAimOffset = Vector3.new(0, 0, 0)
local offsetChangeTimer = 0
local OFFSET_CHANGE_INTERVAL = 0.35 -- [IMPROVED] Longer interval = smoother, less jittery
local lastTargetPart = nil -- [NEW] Track target changes for smooth transitions
local autoFireReactionTime = 0 -- [NEW] Track reaction delay for human-like shooting
local autoFireReadyTime = 0 -- [NEW] When the script "decided" to shoot

-- [NEW] Configuration Save/Load System
local CONFIG_FILE = "monpaff_config.json"
local function SaveConfig()
    local config = {Allies = Allies}
    local json = game:GetService("HttpService"):JSONEncode(config)
    if pcall(writefile, CONFIG_FILE, json) then
        warn("[monpaff] Config saved!")
    end
end
local function LoadConfig()
    if pcall(readfile, CONFIG_FILE) then
        local json = readfile(CONFIG_FILE)
        local config = game:GetService("HttpService"):JSONDecode(json)
        if config.Allies then
            for player, isAlly in pairs(config.Allies) do
                Allies[player] = isAlly
            end
        end
        warn("[monpaff] Config loaded!")
    end
end

-- Remote References
local SetControlsRemote = ReplicatedStorage:FindFirstChild("Remotes") 
    and ReplicatedStorage.Remotes:FindFirstChild("Replication")
    and ReplicatedStorage.Remotes.Replication:FindFirstChild("Fighter") 
    and ReplicatedStorage.Remotes.Replication.Fighter:FindFirstChild("SetControls")

--------------------------------------------------------------------------------
-- // UTILITIES //
--------------------------------------------------------------------------------
local Utils = {}
function Utils:Create(class, props)
    local inst = Instance.new(class)
    for k, v in pairs(props) do inst[k] = v end
    return inst
end

function Utils:IsVisible(targetPart)
    if not Settings.WallCheck then return true end
    local rayParams = RaycastParams.new()
    rayParams.FilterType = Enum.RaycastFilterType.Exclude
    rayParams.FilterDescendantsInstances = {LocalPlayer.Character, targetPart.Parent, Camera}
    local result = workspace:Raycast(Camera.CFrame.Position, (targetPart.Position - Camera.CFrame.Position), rayParams)
    return result == nil
end

function Utils:GetTarget()
    local target, dist = nil, Settings.TargetFOV
    local mouse = UserInputService:GetMouseLocation()
    local targetParts = {"UpperTorso", "LowerTorso", "UpperTorso"} -- Biased towards torso

    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer and p.Character and (not Settings.TeamCheck or not Allies[p.Name]) then
            local hum = p.Character:FindFirstChildOfClass("Humanoid")
            
            local randomPartName = targetParts[math.random(1, #targetParts)]
            local part = p.Character:FindFirstChild(randomPartName)

            if part and hum and (not Settings.DeathCheck or hum.Health > 0) then
                local pos, onScreen = Camera:WorldToViewportPoint(part.Position)
                if onScreen then
                    local mag = (Vector2.new(pos.X, pos.Y) - mouse).Magnitude
                    
                    -- [IMPROVED] FOV-based priority is more legit than pure distance
                    if Settings.AimPriority == "FOV" then
                        if mag < dist then
                            target = part
                            dist = mag
                        end
                    elseif Settings.AimPriority == "Distance" then
                        -- Distance from world position
                        local worldDist = (part.Position - Camera.CFrame.Position).Magnitude
                        if worldDist < dist then
                            target = part
                            dist = worldDist
                        end
                    end
                    
                    -- Always check line of sight
                    if target == part and not self:IsVisible(part) then
                        target = nil
                    end
                end
            end
        end
    end
    return target
end

function Utils:Spoof(wantedDevice)
    if SetControlsRemote then
        SetControlsRemote:FireServer("MouseKeyboard")
        task.wait(0.2)
        SetControlsRemote:FireServer(wantedDevice)
        warn("[monpaff] Device Spoofed to: " .. wantedDevice)
    else
        warn("[monpaff] SetControls Remote Not Found!")
    end
end

--------------------------------------------------------------------------------
-- // monpaff UI ENGINE //
--------------------------------------------------------------------------------
local UI = {}
function UI:Init()
    self.Gui = Utils:Create("ScreenGui", {Name = "monpaff_Elite", Parent = CoreGui})
    GlobalMaid:GiveTask(self.Gui)

    self.Main = Utils:Create("Frame", {
        Size = UDim2.new(0, 580, 0, 420), Position = UDim2.new(0.5, -290, 0.5, -210),
        BackgroundColor3 = Settings.BG, Parent = self.Gui, Visible = Settings.UI_Visible
    })
    Utils:Create("UICorner", {CornerRadius = UDim.new(0, 8), Parent = self.Main})
    Utils:Create("UIStroke", {Color = Settings.Accent, Thickness = 2, Parent = self.Main})

    -- Sidebar
    self.Sidebar = Utils:Create("Frame", {
        Size = UDim2.new(0, 150, 1, 0), BackgroundColor3 = Settings.SidebarBG, Parent = self.Main
    })
    Utils:Create("UICorner", {CornerRadius = UDim.new(0, 8), Parent = self.Sidebar})
    
    Utils:Create("TextLabel", {
        Text = "monpaff v9.0", Size = UDim2.new(1, 0, 0, 50),
        Font = Enum.Font.GothamBold, TextColor3 = Settings.Accent,
        TextSize = 20, BackgroundTransparency = 1, Parent = self.Sidebar
    })

    self.TabHolder = Utils:Create("Frame", {
        Size = UDim2.new(1, 0, 1, -60), Position = UDim2.new(0, 0, 0, 60),
        BackgroundTransparency = 1, Parent = self.Sidebar
    })
    Utils:Create("UIListLayout", {Parent = self.TabHolder, Padding = UDim.new(0, 4), HorizontalAlignment = "Center"})

    self.Content = Utils:Create("ScrollingFrame", {
        Size = UDim2.new(1, -170, 1, -20), Position = UDim2.new(0, 160, 0, 10),
        BackgroundTransparency = 1, Parent = self.Main, CanvasSize = UDim2.new(0,0,2.2,0),
        ScrollBarThickness = 2
    })
    Utils:Create("UIListLayout", {Parent = self.Content, Padding = UDim.new(0, 8)})

    for _, tab in ipairs({"Combat", "Visuals", "Movement", "Spoofer", "Allies"}) do self:CreateTabBtn(tab) end
    
    self:LoadTab("Combat")
    self:MakeDraggable()
end

function UI:CreateTabBtn(name)
    local btn = Utils:Create("TextButton", {
        Text = name, Size = UDim2.new(0.85, 0, 0, 35),
        BackgroundColor3 = Color3.fromRGB(35, 25, 50), -- [NEW] Dark purple tone
        TextColor3 = Color3.new(1,1,1), Font = Enum.Font.GothamMedium,
        Parent = self.TabHolder, AutoButtonColor = true
    })
    Utils:Create("UICorner", {CornerRadius = UDim.new(0, 6), Parent = btn})
    btn.MouseButton1Click:Connect(function() self:LoadTab(name) end)
end

function UI:LoadTab(name)
    for _, v in pairs(self.Content:GetChildren()) do if not v:IsA("UIListLayout") then v:Destroy() end end
    
    if name == "Combat" then
        self:AddToggle("Aimbot Master", "Aimbot")
        self:AddToggle("Teleport Behind Target", "TPBehind")
        self:AddToggle("Triggerbot Logic", "Triggerbot")
        self:AddToggle("Auto Fire", "AutoFire")
        self:AddToggle("Wall Detection", "WallCheck")
        self:AddToggle("Team Check", "TeamCheck")
        self:AddSlider("AutoFire Reaction (MS)", 10, 300, Settings.AutoFireReaction, function(v) Settings.AutoFireReaction = v end)
        self:AddCycle("Aim Priority", {"FOV", "Distance"}, Settings.AimPriority, function(choice)
            Settings.AimPriority = choice
        end)
        self:AddSlider("Aimbot FOV", 50, 800, Settings.TargetFOV, function(v) Settings.TargetFOV = v end)
    elseif name == "Visuals" then
        self:AddToggle("ESP Outlines", "ESP")
        self:AddToggle("Billboard Vitals", "Vitals")
        self:AddToggle("Render FOV Ring", "ShowFOV")
        self:AddToggle("Discreet Mode", "DiscreetMode") -- [NEW]
        self:AddSlider("Game FOV Changer", 30, 120, Settings.CameraFOV, function(v) Settings.CameraFOV = v end)
    elseif name == "Movement" then
        self:AddToggle("Speed Boost (x2)", "SpeedBoost")
        self:AddToggle("Fly Mode", "Fly")
        self:AddToggle("No-clip Mode", "Noclip")
        self:AddSlider("Fly Speed", 20, 300, Settings.FlySpeed, function(v) Settings.FlySpeed = v end)
    elseif name == "Spoofer" then
        self:AddSpoofBtn("Mouse & Keyboard", "MouseKeyboard")
        self:AddSpoofBtn("Gamepad (Console)", "Gamepad")
        self:AddSpoofBtn("Touch (Mobile)", "Touch")
        self:AddSpoofBtn("VR Mode", "VR")
    elseif name == "Allies" then
        self:BuildAllyList()
    end
end

function UI:AddToggle(text, key)
    local btn = Utils:Create("TextButton", {
        Text = text .. ": " .. (Settings[key] and "ON" or "OFF"),
        Size = UDim2.new(1, -5, 0, 40),
        BackgroundColor3 = Settings[key] and Settings.Accent or Color3.fromRGB(35, 35, 45), -- [NEW] Darker inactive
        TextColor3 = Settings[key] and Color3.new(1,1,1) or Color3.new(0.8,0.8,0.8),
        Font = Enum.Font.GothamBold, Parent = self.Content
    })
    Utils:Create("UICorner", {CornerRadius = UDim.new(0, 6), Parent = btn})
    btn.MouseButton1Click:Connect(function()
        Settings[key] = not Settings[key]
        btn.Text = text .. ": " .. (Settings[key] and "ON" or "OFF")
        btn.BackgroundColor3 = Settings[key] and Settings.Accent or Color3.fromRGB(35, 35, 45)
        btn.TextColor3 = Settings[key] and Color3.new(1,1,1) or Color3.new(0.8,0.8,0.8)
    end)
end

function UI:AddSlider(name, min, max, start, callback)
    local frame = Utils:Create("Frame", {Size = UDim2.new(1, -5, 0, 55), BackgroundColor3 = Color3.fromRGB(30, 30, 45), Parent = self.Content})
    Utils:Create("UICorner", {CornerRadius = UDim.new(0, 6), Parent = frame})
    local label = Utils:Create("TextLabel", {Text = name .. ": " .. math.floor(start), Size = UDim2.new(1,0,0,25), BackgroundTransparency = 1, TextColor3 = Color3.new(0.9,0.9,0.9), Parent = frame})
    local bar = Utils:Create("Frame", {Size = UDim2.new(0.9, 0, 0, 4), Position = UDim2.new(0.05, 0, 0.7, 0), BackgroundColor3 = Color3.new(0.15,0.15,0.2), Parent = frame})
    local fill = Utils:Create("Frame", {Size = UDim2.new((start-min)/(max-min), 0, 1, 0), BackgroundColor3 = Settings.Accent, Parent = bar})
    bar.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 then
            local conn; conn = RunService.RenderStepped:Connect(function()
                local rel = math.clamp((UserInputService:GetMouseLocation().X - bar.AbsolutePosition.X) / bar.AbsoluteSize.X, 0, 1)
                local val = math.floor(min + (max - min) * rel)
                fill.Size = UDim2.new(rel, 0, 1, 0)
                label.Text = name .. ": " .. val
                callback(val)
                if not UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) then conn:Disconnect() end
            end)
        end
    end)
end

function UI:AddCycle(name, options, initial, callback)
    local btn = Utils:Create("TextButton", {
        Text = name .. ": " .. initial,
        Size = UDim2.new(1, -5, 0, 40),
        BackgroundColor3 = Color3.fromRGB(35, 35, 45),
        TextColor3 = Color3.new(0.9,0.9,0.9),
        Font = Enum.Font.GothamMedium, Parent = self.Content
    })
    Utils:Create("UICorner", {CornerRadius = UDim.new(0, 6), Parent = btn})
    local currentIndex = 1
    for i, opt in ipairs(options) do
        if opt == initial then currentIndex = i break end
    end
    btn.MouseButton1Click:Connect(function()
        currentIndex = currentIndex % #options + 1
        btn.Text = name .. ": " .. options[currentIndex]
        callback(options[currentIndex])
    end)
end

function UI:AddSpoofBtn(name, device)
    local btn = Utils:Create("TextButton", {
        Text = "Spoof: " .. name, Size = UDim2.new(1, -5, 0, 40),
        BackgroundColor3 = Color3.fromRGB(40, 30, 55), -- [NEW] Purple toned
        TextColor3 = Color3.new(1,1,1), Font = Enum.Font.GothamMedium, Parent = self.Content
    })
    Utils:Create("UICorner", {CornerRadius = UDim.new(0, 6), Parent = btn})
    btn.MouseButton1Click:Connect(function()
        Utils:Spoof(device)
        btn.BackgroundColor3 = Color3.fromRGB(80, 150, 100) -- [NEW] Green on success
        task.wait(0.2)
        btn.BackgroundColor3 = Color3.fromRGB(40, 30, 55)
    end)
end

function UI:AddCheckbox(playerName, isAlly, callback)
    local frame = Utils:Create("Frame", {
        Size = UDim2.new(1, -5, 0, 35), BackgroundColor3 = Color3.fromRGB(30, 30, 45),
        Parent = self.Content
    })
    Utils:Create("UICorner", {CornerRadius = UDim.new(0, 6), Parent = frame})
    
    -- Checkbox (visual box)
    local checkbox = Utils:Create("Frame", {
        Size = UDim2.new(0, 24, 0, 24), Position = UDim2.new(0, 8, 0.5, -12),
        BackgroundColor3 = isAlly and Settings.Accent or Color3.fromRGB(50, 50, 60),
        Parent = frame
    })
    Utils:Create("UICorner", {CornerRadius = UDim.new(0, 4), Parent = checkbox})
    
    -- Checkmark if checked
    if isAlly then
        Utils:Create("TextLabel", {
            Text = "✓", Size = UDim2.new(1, 0, 1, 0),
            BackgroundTransparency = 1, TextColor3 = Color3.new(1,1,1),
            Font = Enum.Font.GothamBold, TextSize = 16, Parent = checkbox
        })
    end
    
    -- Label with player name and status
    local lbl = Utils:Create("TextLabel", {
        Text = playerName .. " (" .. (isAlly and "ALLY" or "ENEMY") .. ")",
        Size = UDim2.new(1, -50, 1, 0), Position = UDim2.new(0, 40, 0, 0),
        BackgroundTransparency = 1, TextColor3 = Color3.new(0.9, 0.9, 0.9),
        Font = Enum.Font.GothamMedium, TextSize = 14, TextXAlignment = Enum.TextXAlignment.Left,
        Parent = frame
    })
    
    -- Click handler
    frame.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 then
            isAlly = not isAlly
            callback(isAlly)
            
            -- Update checkbox appearance
            checkbox.BackgroundColor3 = isAlly and Settings.Accent or Color3.fromRGB(50, 50, 60)
            checkbox:ClearAllChildren()
            if isAlly then
                Utils:Create("TextLabel", {
                    Text = "✓", Size = UDim2.new(1, 0, 1, 0),
                    BackgroundTransparency = 1, TextColor3 = Color3.new(1,1,1),
                    Font = Enum.Font.GothamBold, TextSize = 16, Parent = checkbox
                })
            end
            lbl.Text = playerName .. " (" .. (isAlly and "ALLY" or "ENEMY") .. ")"
        end
    end)
end

function UI:AutoDetectTeam()
    if LocalPlayer.Team then
        for _, p in ipairs(Players:GetPlayers()) do
            if p ~= LocalPlayer then
                if p.Team and p.Team == LocalPlayer.Team then
                    Allies[p.Name] = true  -- Same team = ally
                else
                    Allies[p.Name] = nil  -- Different team = enemy
                end
            end
        end
    end
    SaveConfig()
    -- Rebuild the ally list after detection
    self:LoadTab("Allies")
end

function UI:CaptureAlliesInRadius()
    local char = LocalPlayer.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    
    if not hrp then
        warn("[monpaff] No character found!")
        return
    end
    
    local radius = Settings.CaptureRadius
    local captured = {}
    
    -- Find all players within radius
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer and p.Character then
            local targetHrp = p.Character:FindFirstChild("HumanoidRootPart")
            if targetHrp then
                local distance = (targetHrp.Position - hrp.Position).Magnitude
                if distance <= radius then
                    Allies[p.Name] = true  -- Mark as ally
                    table.insert(captured, p.Name)
                end
            end
        end
    end
    
    SaveConfig()
    -- Rebuild UI
    self:LoadTab("Allies")
    
    -- Visual feedback
    if #captured > 0 then
        warn("[monpaff] Captured " .. #captured .. " allies: " .. table.concat(captured, ", "))
    else
        warn("[monpaff] No players found in radius " .. radius .. "!")
    end
end

function UI:MakeDraggable()
    local dStart, sPos, dragging
    self.Main.InputBegan:Connect(function(i) if i.UserInputType == Enum.UserInputType.MouseButton1 then dragging = true dStart = i.Position sPos = self.Main.Position end end)
    UserInputService.InputChanged:Connect(function(i) if dragging and i.UserInputType == Enum.UserInputType.MouseMovement then
        local delta = i.Position - dStart
        self.Main.Position = UDim2.new(sPos.X.Scale, sPos.X.Offset + delta.X, sPos.Y.Scale, sPos.Y.Offset + delta.Y)
    end end)
    UserInputService.InputEnded:Connect(function(i) if i.UserInputType == Enum.UserInputType.MouseButton1 then dragging = false end end)
end

function UI:BuildAllyList()
    -- Add Auto-Detect Team button at the top
    local autoDetectBtn = Utils:Create("TextButton", {
        Text = "🔍 Auto-Detect Team", Size = UDim2.new(1, -5, 0, 40),
        BackgroundColor3 = Settings.Accent, TextColor3 = Color3.new(1,1,1),
        Font = Enum.Font.GothamBold, Parent = self.Content
    })
    Utils:Create("UICorner", {CornerRadius = UDim.new(0, 6), Parent = autoDetectBtn})
    autoDetectBtn.MouseButton1Click:Connect(function()
        self:AutoDetectTeam()
        autoDetectBtn.BackgroundColor3 = Color3.fromRGB(100, 200, 100)
        task.wait(0.3)
        autoDetectBtn.BackgroundColor3 = Settings.Accent
    end)
    
    -- Radius slider
    self:AddSlider("Capture Radius", 10, 200, Settings.CaptureRadius, function(v) Settings.CaptureRadius = v end)
    
    -- Capture Allies in Radius button
    local captureBtn = Utils:Create("TextButton", {
        Text = "📍 Capture Allies in Radius", Size = UDim2.new(1, -5, 0, 40),
        BackgroundColor3 = Color3.fromRGB(80, 150, 200), TextColor3 = Color3.new(1,1,1),
        Font = Enum.Font.GothamBold, Parent = self.Content
    })
    Utils:Create("UICorner", {CornerRadius = UDim.new(0, 6), Parent = captureBtn})
    captureBtn.MouseButton1Click:Connect(function()
        self:CaptureAlliesInRadius()
        captureBtn.BackgroundColor3 = Color3.fromRGB(100, 200, 100)
        task.wait(0.3)
        captureBtn.BackgroundColor3 = Color3.fromRGB(80, 150, 200)
    end)
    
    -- Label
    Utils:Create("TextLabel", {
        Text = "✓ = ALLY | ☐ = ENEMY", Size = UDim2.new(1, -5, 0, 25),
        BackgroundColor3 = Color3.fromRGB(25, 25, 35), TextColor3 = Color3.fromRGB(150, 150, 150),
        Font = Enum.Font.GothamMedium, TextSize = 13, Parent = self.Content
    })
    Utils:Create("UICorner", {CornerRadius = UDim.new(0, 4), Parent = self.Content:GetChildren()[#self.Content:GetChildren()]})
    
    -- Add checkboxes for each player
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer then
            local isAlly = Allies[p.Name]
            self:AddCheckbox(p.Name, isAlly, function(ally)
                if ally then
                    Allies[p.Name] = true
                else
                    Allies[p.Name] = nil
                end
                SaveConfig()  -- Auto-save on change
            end)
        end
    end
end

--------------------------------------------------------------------------------
-- // CORE PROCESSING //
--------------------------------------------------------------------------------

-- Character Physics / Noclip / Speed
GlobalMaid:GiveTask(RunService.Stepped:Connect(function()
    local char = LocalPlayer.Character
    if char then
        if char:FindFirstChildOfClass("Humanoid") then char.Humanoid.WalkSpeed = Settings.SpeedBoost and 32 or 16 end
        if Settings.Noclip then
            for _, p in pairs(char:GetDescendants()) do if p:IsA("BasePart") then p.CanCollide = false end end
        end
    end
end))

-- Combat / Fly / TP Loop
RunService:BindToRenderStep("monpaff_Elite_Core", Enum.RenderPriority.Camera.Value + 1, function()
    Camera.FieldOfView = Settings.CameraFOV
    local char = LocalPlayer.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")

    local target = Utils:GetTarget()

    -- TP Behind Target [NEW]
    if Settings.TPBehind and target and hrp then
        local targetRoot = target.Parent:FindFirstChild("HumanoidRootPart")
        if targetRoot then
            -- Position 4 studs behind target, matching target orientation
            hrp.CFrame = targetRoot.CFrame * CFrame.new(0, 0, 4)
        end
    end

    -- Flight
    if Settings.Fly and hrp then
        local moveDir = Vector3.new(0,0,0)
        if UserInputService:IsKeyDown(Enum.KeyCode.W) then moveDir += Camera.CFrame.LookVector end
        if UserInputService:IsKeyDown(Enum.KeyCode.S) then moveDir -= Camera.CFrame.LookVector end
        if UserInputService:IsKeyDown(Enum.KeyCode.D) then moveDir += Camera.CFrame.RightVector end
        if UserInputService:IsKeyDown(Enum.KeyCode.A) then moveDir -= Camera.CFrame.RightVector end
        if UserInputService:IsKeyDown(Enum.KeyCode.Space) then moveDir += Vector3.new(0, 1, 0) end
        if UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) then moveDir -= Vector3.new(0, 1, 0) end
        hrp.Velocity = moveDir * Settings.FlySpeed
        hrp.CFrame = CFrame.new(hrp.Position, hrp.Position + Camera.CFrame.LookVector)
    end

    -- Aimbot
    if Settings.Aimbot and UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2) and target then
        -- [IMPROVED] More natural offset system - smaller magnitude, longer intervals
        offsetChangeTimer = offsetChangeTimer + (1/60)
        if offsetChangeTimer >= OFFSET_CHANGE_INTERVAL then
            offsetChangeTimer = 0
            -- Smaller, more natural offsets for legit appearance
            currentAimOffset = Vector3.new(
                (math.random() - 0.5) * 0.25, -- [IMPROVED] Reduced from 0.4
                (math.random() - 0.5) * 0.25, -- [IMPROVED] Reduced from 0.4
                (math.random() - 0.5) * 0.15  -- [IMPROVED] Reduced from 0.2
            )
        end
        
        local targetPosition = target.Position + currentAimOffset
        -- [IMPROVED] Higher smoothness value (0.21) means slower, more natural tracking
        Camera.CFrame = Camera.CFrame:Lerp(CFrame.new(Camera.CFrame.Position, targetPosition), 1 - Settings.Smoothness)
    else
        offsetChangeTimer = 0
        currentAimOffset = Vector3.new(0, 0, 0)
    end
    
    -- [NEW] Auto Fire - Fires when target is in FOV (no manual aiming needed)
    if Settings.AutoFire and target and (tick() - lastShotTime) > Settings.AutoFireCooldown then
        -- [NEW] Human-like reaction time before shooting
        if autoFireReadyTime == 0 then
            -- Pick a random reaction time between 0 and AutoFireReaction milliseconds
            autoFireReadyTime = tick() + (Settings.AutoFireReaction / 1000)
        end
        
        if tick() >= autoFireReadyTime then
            lastShotTime = tick()
            mouse1press()
            task.wait(0.05)
            mouse1release()
            autoFireReadyTime = 0  -- Reset for next target
        end
    elseif not target then
        autoFireReadyTime = 0  -- Reset if no target
    end

    -- Trigger Logic
    if Settings.Triggerbot then
        local res = workspace:Raycast(Camera.CFrame.Position, Camera.CFrame.LookVector * 1000)
        if res and res.Instance then
            local m = res.Instance:FindFirstAncestorOfClass("Model")
            if m and m:FindFirstChildOfClass("Humanoid") and (not Settings.DeathCheck or m.Humanoid.Health > 0) then
                local flash = Utils:Create("Frame", {Size = UDim2.new(1,0,1,0), BackgroundColor3 = Color3.new(1,0,0), BackgroundTransparency = 0.9, Parent = UI.Gui})
                task.delay(0.05, function() flash:Destroy() end)
            end
        end
    end
end)

--------------------------------------------------------------------------------
-- // VISUALS //
--------------------------------------------------------------------------------

local FOVGui = Utils:Create("Frame", {
    Parent = GlobalMaid:GiveTask(Instance.new("ScreenGui", CoreGui)),
    BackgroundColor3 = Color3.new(1,1,1), BackgroundTransparency = 0.95,
    AnchorPoint = Vector2.new(0.5, 0.5), Visible = false
})
Utils:Create("UICorner", {CornerRadius = UDim.new(1,0), Parent = FOVGui})
Utils:Create("UIStroke", {Color = Settings.Accent, Thickness = 1, Parent = FOVGui})

task.spawn(function()
    while _G.monpaffRunning do
        local mouse = UserInputService:GetMouseLocation()
        FOVGui.Position = UDim2.new(0, mouse.X, 0, mouse.Y)
        FOVGui.Size = UDim2.new(0, Settings.TargetFOV * 2, 0, Settings.TargetFOV * 2)
        FOVGui.Visible = Settings.ShowFOV and not Settings.DiscreetMode

        for _, p in ipairs(Players:GetPlayers()) do
            if p ~= LocalPlayer and p.Character and (not Settings.TeamCheck or not Allies[p.Name]) then
                local char = p.Character
                local h = char:FindFirstChild("monpaff_H")
                if Settings.ESP and not Settings.DiscreetMode then
                    if not h then Utils:Create("Highlight", {Name = "monpaff_H", Parent = char, FillColor = Settings.Accent}) end
                elseif h then h:Destroy() end
                
                local v = char:FindFirstChild("monpaff_V")
                if Settings.Vitals and not Settings.DiscreetMode then
                    if not v then
                        v = Utils:Create("BillboardGui", {Name = "monpaff_V", Parent = char, Adornee = char:FindFirstChild("Head"), Size = UDim2.new(0, 60, 0, 8), AlwaysOnTop = true, ExtentsOffset = Vector3.new(0, 2.5, 0)})
                        local bg = Utils:Create("Frame", {Size = UDim2.new(1,0,1,0), BackgroundColor3 = Color3.new(0,0,0), Parent = v})
                        Utils:Create("Frame", {Name = "Bar", Size = UDim2.new(1,0,1,0), BackgroundColor3 = Settings.Accent, Parent = bg})
                    end
                    local hum = char:FindFirstChildOfClass("Humanoid")
                    if hum and v:FindFirstChild("Bar", true) then v:FindFirstChild("Bar", true).Size = UDim2.new(math.clamp(hum.Health / hum.MaxHealth, 0, 1), 0, 1, 0) end
                elseif v then v:Destroy() end
            end
        end
        task.wait(0.5)
    end
end)

GlobalMaid:GiveTask(UserInputService.InputBegan:Connect(function(i, g)
    if not g and i.KeyCode == Settings.ToggleMenuKey then
        Settings.UI_Visible = not Settings.UI_Visible
        UI.Main.Visible = Settings.UI_Visible
    end
end))

-- [NEW] Helper to recalculate allies dynamically based on Team
local function RecalculateAllies()
    if LocalPlayer.Team then
        for _, p in ipairs(Players:GetPlayers()) do
            if p ~= LocalPlayer then
                if p.Team and p.Team == LocalPlayer.Team then
                    Allies[p.Name] = true  -- Same team = ally
                else
                    Allies[p.Name] = nil  -- Different team = enemy (not saved)
                end
            end
        end
    end
end

-- Auto-update allies at each round (character spawn)
LocalPlayer.CharacterAdded:Connect(function(char)
    task.wait(2) -- [IMPROVED] Increased wait to ensure teams are properly loaded
    RecalculateAllies()
end)

-- Keep ally list synced when players join
Players.PlayerAdded:Connect(function(p)
    if p ~= LocalPlayer then
        task.wait(0.5)  -- Wait for team to be assigned
        if LocalPlayer.Team and p.Team and p.Team == LocalPlayer.Team then
            Allies[p.Name] = true
        end
    end
end)

-- Clean up when players leave
Players.PlayerRemoving:Connect(function(p)
    Allies[p.Name] = nil
end)

-- Load config on script start
LoadConfig()

-- Initial calculation on script load
task.delay(2, RecalculateAllies)

UI:Init()
warn("[monpaff] Elite Suite v9.0 Loaded. Sidebar & Spoofer Ready.")
