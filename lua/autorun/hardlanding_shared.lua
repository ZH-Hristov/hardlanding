local cTasks = {}
local loadedConfig = {}

if file.Exists("hardlandingserverconfig.json", "DATA") and util.JSONToTable(file.Read("hardlandingserverconfig.json")) then
    print("Hard Landing - Loading saved server config")

    loadedConfig = util.JSONToTable(file.Read("hardlandingserverconfig.json"))
else
    loadedConfig = {
        enabled = 1,
        maxfallspeed = 800,
        rollwindow = 0.2,
        rollduration = 1,
        failduration = 2
    }
end

local hl_cvars = {
    enabled = CreateConVar("hardlanding_enabled", loadedConfig.enabled, FCVAR_REPLICATED, "Enable or disable Hard Landing functionality", 0, 1),
    maxfallspeed = CreateConVar("hardlanding_maxfallspeed", loadedConfig.maxfallspeed, FCVAR_REPLICATED, "Max fall speed you can hit the ground at before you take damage regardless of roll attempt", 1, 9999),
    rollwindow = CreateConVar("hardlanding_rollwindow", loadedConfig.rollwindow, FCVAR_REPLICATED, "The window for a successful roll after pressing DUCK in the air", 0.1, 2),
    rollduration = CreateConVar("hardlanding_rollduration", loadedConfig.rollduration, FCVAR_REPLICATED, "How long a successful roll needs to finish", 0.3, 2),
    failduration = CreateConVar("hardlanding_failduration", loadedConfig.failduration, FCVAR_REPLICATED, "How long the stun lasts if you fail a roll", 0.3, 5)
}

local immersivecamenabled = CreateClientConVar("hardlanding_immersivecam", 1, true, false, "Enable immersive camera while rolling or stunned. REQUIRES CVPS INSTALLED.", 0, 1)

local function saveConfig()
    if CLIENT then return end
    local t = {
        enabled = hl_cvars.enabled:GetInt(),
        maxfallspeed = hl_cvars.maxfallspeed:GetInt(),
        rollwindow = hl_cvars.rollwindow:GetFloat(),
        rollduration = hl_cvars.rollduration:GetFloat(),
        failduration = hl_cvars.failduration:GetFloat()
    }

    file.Write("hardlandingserverconfig.json", util.TableToJSON(t))
end

if SERVER then
    for _, cvar in pairs(hl_cvars) do
        cvars.AddChangeCallback(cvar:GetName(), saveConfig, "hlcs_"..cvar:GetName())
    end
end

local function RemoveCoTask(id)
    cTasks[id] = nil

    if table.IsEmpty(cTasks) then
        hook.Remove("Think", "HLanding_CTaskHandler")
    end
end

local function AddCoTask(id, func)
    if table.IsEmpty(cTasks) then
        hook.Add("Think", "HLanding_CTaskHandler", function()
            for ctaskid, ctask in pairs(cTasks) do
                if ctask() then 
                    RemoveCoTask(ctaskid)
                end
            end
        end)
    end

    cTasks[id] = coroutine.wrap(func)
end

if SERVER then
    util.AddNetworkString("HLanding_NMSG")
else
    net.Receive("HLanding_NMSG", function()
        local typ = net.ReadUInt(2)

        if typ == 1 then
            local ply = net.ReadEntity()
            local rolled = net.ReadBool()
            local dur = net.ReadFloat()

            ply:InitHardLanding(rolled, dur)

            if ply == LocalPlayer() and CalcViewPS and immersivecamenabled:GetBool() then
                local LP = LocalPlayer()
                local attId = LP:LookupAttachment("eyes")
                if attId <= 0 then return end 

                AddCoTask("HARDLANDING_CVPS_CAM", function()
                    local View = {drawviewer = true}
                    local ease = math.ease
                    local LerpProg = 0          
    
                    CalcViewPS.AddToTop("HARDLANDING_CVPS_CAM", function(ply, pos, angles, fov)
                        local att = LP:GetAttachment(attId)

                        View.origin = LerpVector(ease.OutSine(LerpProg), pos, att.Pos)
                        View.angles = LerpAngle(ease.OutSine(LerpProg), angles, att.Ang)
                        View.fov = Lerp(ease.InOutSine(LerpProg), fov, fov + 20)
                
                        return View
                    end)

                    while ply.HardLandingEnabled do
                        LerpProg = math.Approach(LerpProg, 1, FrameTime() / 0.2)
                        coroutine.yield()
                    end

                    View.drawviewer = false

                    while LerpProg > 0 do
                        LerpProg = math.Approach(LerpProg, 0, FrameTime() / 0.2)
                        coroutine.yield()
                    end

                    CalcViewPS.Remove("HARDLANDING_CVPS_CAM")

                    return true
                end)
            else
                if ply == LocalPlayer() and rolled and immersivecamenabled:GetBool() then
                    AddCoTask("HARDLANDING_NOCVPS_CAM", function()
                        local View = {}
                        local prog = 0

                        hook.Add("CalcView", "HARDLANDING_NOCVPS_CAM", function(ply, origin, ogangs)
                            View.angles = Lerp(math.ease.InOutSine(prog), ogangs, ogangs + Angle(360 * prog, 0, 0))
                            return View
                        end)

                        while prog < 1 do
                            prog = math.Approach(prog, 1, FrameTime() / dur)
                            coroutine.yield()
                        end

                        hook.Remove("CalcView", "HARDLANDING_NOCVPS_CAM")
                        return true
                    end)
                end
            end

        elseif typ == 2 then
            local ply = net.ReadEntity()
            local newprog = net.ReadFloat()

            ply.HardLandingProg = newprog
        elseif typ == 3 then
            local ply = net.ReadEntity()

            ply.HardLandingEnabled = nil
            ply.HardLandingProg = nil
        end
    end)
end

local pMeta = FindMetaTable("Player")

function pMeta:InitHardLanding(rolled, dur)
    if SERVER then

        local id = "PlayerHardLanding_"..self:EntIndex()

        if cTasks[id] then return end

        AddCoTask(id, function()
            self.HardLandingEnabled = true
            self.HardLandingProg = 0

            local rStartSpeed = 300
            local rSpeed = rStartSpeed

            net.Start("HLanding_NMSG")
            net.WriteUInt(1, 2)
            net.WriteEntity(self)
            net.WriteBool(rolled)
            net.WriteFloat(dur)
            net.Broadcast()

            self:Freeze(true)
            self:EmitSound("npc/combine_soldier/zipline_hitground"..math.random(1, 2)..".wav", 75, 100, 1, CHAN_STATIC)

            hook.Add("CalcMainActivity", id, function(ply)
                if ply ~= self then return end

                self:SetCycle(self.HardLandingProg)

                return -1, (rolled and self:LookupSequence("wos_mma_roll") or self:LookupSequence("wos_mma_hardlanding"))
            end)

            while self:Alive() and self.HardLandingProg < 1 do
                self.HardLandingProg = math.Approach(self.HardLandingProg, 1, FrameTime() / dur)

                net.Start("HLanding_NMSG")
                net.WriteUInt(2, 2)
                net.WriteEntity(self)
                net.WriteFloat(self.HardLandingProg)
                net.Broadcast()

                if rolled and self:IsOnGround() then
                    rSpeed = Lerp(math.ease.InSine(self.HardLandingProg), rStartSpeed, 0)
                    self:SetLocalVelocity(self:GetForward() * rSpeed)
                end

                coroutine.yield()
            end

            hook.Remove("CalcMainActivity", id)
            self.HardLandingEnabled = nil 
            self.HardLandingProg = nil

            self:Freeze(false)

            net.Start("HLanding_NMSG")
            net.WriteUInt(3, 2)
            net.WriteEntity(self)
            net.Broadcast()

            return true
        end)

    else

        local id = "PlayerHardLanding_"..self:EntIndex()
        self.HardLandingEnabled = true

        AddCoTask(id, function()
            hook.Add("CalcMainActivity", id, function(ply)
                if ply ~= self then return end

                if self.HardLandingProg then
                    self:SetCycle( self.HardLandingProg * (rolled and 0.7 or 1) )
                else
                    self:SetCycle(1)
                end

                return -1, (rolled and self:LookupSequence("wos_mma_roll") or self:LookupSequence("wos_mma_hardlanding"))
            end)

            while self.HardLandingEnabled do 
                coroutine.yield()
            end

            hook.Remove("CalcMainActivity", id)
            return true
        end)

    end
end

hook.Add("KeyPress", "HardLanding_RollDetect", function(ply, key)
    if ply:IsOnGround() then return end
    if key ~= IN_DUCK then return end
    local id = "HardLanding_RollWindow_"..ply:EntIndex()
    if cTasks[id] then return end

    AddCoTask(id, function()
        ply.HLanding_RollAttempt = true
        coroutine.wait(hl_cvars.rollwindow:GetFloat())
        ply.HLanding_RollAttempt = nil

        coroutine.wait(0.4)
        return true
    end)
end)

hook.Add("GetFallDamage", "HardLanding_Detection", function(ply, speed)
    if not hl_cvars.enabled:GetBool() then return end
    local rolled = ply.HLanding_RollAttempt and speed <= hl_cvars.maxfallspeed:GetInt()

    ply:InitHardLanding( rolled, (rolled and hl_cvars.rollduration:GetFloat() or hl_cvars.failduration:GetFloat()) )

    if rolled then return false end
end)