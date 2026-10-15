-- pot_vrcamera.lua
-- UEVR-side VR camera for Path of Titans (UE 5.7)
-- Camera: attached to the dinosaur, orbit/look-at lock removed, arm-length control.
-- Note: Native Stereo churn on PoT is a UEVR-side bug (scene-capture invalidation);
--       being fixed upstream / via PR. Use Synchronized Sequential as fallback mode.
--
-- Install: <UEVR>\scripts\pot_vrcamera.lua or %APPDATA%\UnrealVRMod\<game>\scripts\

local vr = nil
pcall(function() vr = uevr.params.vr end)

local Config = {
    Enabled = true,
    DesiredArmLength = nil,            -- nil = game owns distance (per-dino size-adjusted)
    MinArmLength = 50.0,
    DesiredRotateRate = 800.0,        -- vanilla boom yaw-follow (camera stays behind dino)
    ForceMatchGameFov = true,
    ZeroCameraDollyRate = false,      -- game animates arm length toward its own desire
    UseLegacyCameraSystem = true,
    DisableBoomControlRotation = true,   -- UEVR owns view rotation; keep this
    DisableBoomInheritRotation = false,  -- vanilla: boom inherits dino yaw (centered framing)
    DisableBoomCollisionTest = false,     -- vanilla: probe keeps camera out of terrain
    DisableCameraLag = false,             -- vanilla: lag smooths the follow (kills stutter)
    WidenDistanceRange = false,          -- game clamps per-dino; don't widen
    ReassertInterval = 2.0,
    VerboseDiagnostics = true,
    DecoupledPitch = true,

    AmbientOcclusionLevels = 0,       -- SSAO disabled by default (per-eye shimmer); Lumen AO replaces it
    LumenAO = true,                   -- Lumen GI + SSAO off: view-independent contact shading, no stereo divergenceff, 1-3 = keep AO
}

local lastPawn = nil
local saved = nil
local lastReassert = 0.0
local dirty = false
local decoupledPitchApplied = false
local matchFovForced = false

local function log(msg)
    local line = "[PoTVRCamera] " .. tostring(msg)
    local written = false
    pcall(function()
        uevr.params.functions.log_info(line)
        written = true
    end)
    if not written then
        print(line .. "\n")
    end
end

local function getGameEngine()
    local ok, engine = pcall(function()
        local c = uevr.api:find_uobject("Class /Script/Engine.GameEngine")
        if c == nil then return nil end
        return UEVR_UObjectHook.get_first_object_by_class(c)
    end)
    if ok then return engine end
    return nil
end

local function getLocalPawn()
    local engine = getGameEngine()
    if engine == nil then return nil end
    local ok, pawn = pcall(function()
        local gi = engine.GameInstance
        if gi == nil then return nil end
        local players = gi.LocalPlayers
        if players == nil then return nil end
        local player = players[1]
        if player == nil then return nil end
        local pc = player.PlayerController
        if pc == nil then return nil end
        return pc.Pawn
    end)
    if ok then return pawn end
    return nil
end

local function saveVanilla(pawn)
    saved = {}
    pcall(function() saved.rotateRate = pawn.SpringArmRotateRate end)
    pcall(function() saved.dollyRate = pawn.CameraDollyRate end)
    pcall(function() saved.newCam = pawn.bEnableNewCameraSystem end)
    pcall(function() saved.desireArm = pawn.DesireSpringArmLength end)
    local okb, boom = pcall(function() return pawn.ThirdPersonSpringArmComponent end)
    saved.boom = boom
    if boom ~= nil then
        pcall(function() saved.targetArm = boom.TargetArmLength end)
        pcall(function() saved.bUsePawnControlRotation = boom.bUsePawnControlRotation end)
        pcall(function() saved.bInheritPitch = boom.bInheritPitch end)
        pcall(function() saved.bInheritYaw = boom.bInheritYaw end)
        pcall(function() saved.bInheritRoll = boom.bInheritRoll end)
        pcall(function() saved.bDoCollisionTest = boom.bDoCollisionTest end)
        pcall(function() saved.bEnableCameraLag = boom.bEnableCameraLag end)
    end
    local okc, cam = pcall(function() return pawn.ThirdPersonCameraComponent end)
    saved.cam = cam
    if cam ~= nil then
        pcall(function() saved.camControlRot = cam.bUsePawnControlRotation end)
        pcall(function() saved.camAbsolute = cam.bAbsoluteRotation end)
    end
    if Config.VerboseDiagnostics then
        local okName, pawnName = pcall(function() return pawn:get_full_name() end)
        log("Pawn: " .. tostring(okName and pawnName or pawn))
        log("  boom found: " .. tostring(boom ~= nil) .. ", cam found: " .. tostring(cam ~= nil))
        if boom ~= nil then
            pcall(function()
                log(string.format("  vanilla: TargetArmLength=%.1f RotateRate=%.1f Dolly=%.1f Desire=%.1f ctrlRot=%s inheritPYR=%s/%s/%s",
                    boom.TargetArmLength or -1, saved.rotateRate or -1, saved.dollyRate or -1,
                    saved.desireArm or -1, tostring(saved.bUsePawnControlRotation),
                    tostring(saved.bInheritPitch), tostring(saved.bInheritYaw), tostring(saved.bInheritRoll)))
            end)
        end
        if saved.newCam ~= nil then
            log("  vanilla bEnableNewCameraSystem: " .. tostring(saved.newCam))
        end
        pcall(function()
            local range = pawn.CameraDistanceRange
            if range ~= nil then
                local lower = range.LowerBound
                local upper = range.UpperBound
                log(string.format("  game distance range: [%s, %s]",
                    lower ~= nil and tostring(lower.Value) or "?",
                    upper ~= nil and tostring(upper.Value) or "?"))
            end
        end)
    end
end

local function widenRange(pawn, wanted)
    if not Config.WidenDistanceRange then return end
    pcall(function()
        local range = pawn.CameraDistanceRange
        if range == nil then
            if Config.VerboseDiagnostics then log("no CameraDistanceRange on pawn") end
            return
        end
        local upper = range.UpperBound
        if upper ~= nil then
            local cur = upper.Value
            if cur ~= nil and wanted > cur then
                log(string.format("Range.UpperBound: %.1f -> %.1f", cur, wanted + 100.0))
                upper.Value = wanted + 100.0
            end
        end
        local lower = range.LowerBound
        if lower ~= nil then
            local cur = lower.Value
            if cur ~= nil and wanted < cur then
                local nv = math.max(Config.MinArmLength, wanted - 50.0)
                log(string.format("Range.LowerBound: %.1f -> %.1f", cur, nv))
                lower.Value = nv
            end
        end
    end)
end

local function applyArmLength(pawn, length)
    length = math.max(Config.MinArmLength, length)
    widenRange(pawn, length)
    pcall(function()
        local boom = pawn.ThirdPersonSpringArmComponent
        if boom ~= nil then boom.TargetArmLength = length end
        pawn.DesireSpringArmLength = length
    end)
    Config.DesiredArmLength = length
    log(string.format("Arm length -> %.1f", length))
end

-- CVar access via the console manager: readable, writable, and lets us
-- detect UEVR's CVar freeze enforcement (which silently reverts execute_command
-- writes every frame, making later presets look like no-ops).
local CvarCache = {}

local function getVar(name)
    local cached = CvarCache[name]
    if cached ~= nil and cached.valid then return cached.var end
    local ok, var = pcall(function()
        local cm = uevr.api:get_console_manager()
        return cm:find_variable(name)
    end)
    if ok and var ~= nil then
        CvarCache[name] = { var = var, valid = true }
        return var
    end
    CvarCache[name] = { var = nil, valid = false }
    return nil
end

local function setVarInt(name, value)
    local var = getVar(name)
    if var == nil then
        log("cannot set " .. name .. ": cvar not found")
        return false
    end
    local ok = pcall(function() var:set_int(value) end)
    if not ok then
        log("cannot set " .. name .. ": set failed (possibly frozen)")
        return false
    end
    -- Freeze-enforcement detection: read back; if UEVR's CVarManager reverts
    -- it, surface that instead of silently pretending the preset applied.
    local readBack = nil
    pcall(function() readBack = var:get_int() end)
    if readBack ~= nil and readBack ~= value then
        log(name .. " reverted to " .. tostring(readBack) .. " (frozen by UEVR CVar freeze - use Console tab > Clear Frozen CVars)")
        return false
    end
    return true
end

local function applyAmbientOcclusion()
    if Config.AmbientOcclusionLevels == nil then return end
    setVarInt("r.AmbientOcclusionLevels", Config.AmbientOcclusionLevels)
    if Config.AORadiusScale ~= nil then
        local var = getVar("r.AmbientOcclusionRadiusScale")
        if var ~= nil then
            pcall(function() var:set_float(Config.AORadiusScale) end)
        end
    end
end

-- AO presets for stereo stability: screen-space AO is computed per eye from
-- each eye's own depth buffer, so the two eyes diverge on fine surfaces.
-- Larger radius + more blur = more view-independent = less per-eye shimmer.
local function applyAOPreset(name)
    if name ~= "lumen" then
        restoreFromLumen()
    end
    if name == "off" then
        Config.AmbientOcclusionLevels = 0
        Config.AORadiusScale = nil
    elseif name == "smooth" then
        Config.AmbientOcclusionLevels = 1
        Config.AORadiusScale = 2.0
    elseif name == "full" then
        Config.AmbientOcclusionLevels = 3
        Config.AORadiusScale = 1.0
    end
    applyAmbientOcclusion()
    log(string.format("AO preset '%s': levels=%s radiusScale=%s",
        name, tostring(Config.AmbientOcclusionLevels), tostring(Config.AORadiusScale)))
end

-- Lumen path: if PoT runs Lumen GI, its AO/darkening term is view-independent
-- (ray-based), so enabling Lumen + disabling SSAO gives contact shading with
-- zero per-eye divergence. Try this if radius scaling only partials the fix.
-- Snapshot state before touching anything so "off"/"smooth"/"full" can restore.
local LumenSnapshot = nil

local function applyLumenAO()
    local aa = getVar("r.AntiAliasingMethod")
    local gi = getVar("r.DynamicGlobalIlluminationMethod")
    local ssaoQ = getVar("r.SSAO.Quality")
    local aoLevels = getVar("r.AmbientOcclusionLevels")
    if aa == nil or gi == nil then
        log("Lumen AO unavailable: required cvars not found")
        return
    end
    if LumenSnapshot == nil then
        local snap = {}
        pcall(function() snap.aa = aa:get_int() end)
        pcall(function() snap.gi = gi:get_int() end)
        if ssaoQ ~= nil then pcall(function() snap.ssaoQ = ssaoQ:get_int() end) end
        if aoLevels ~= nil then pcall(function() snap.aoLevels = aoLevels:get_int() end) end
        LumenSnapshot = snap
        log(string.format("Lumen snapshot: AA=%s GI=%s SSAO.Q=%s AOLevels=%s",
            tostring(snap.aa), tostring(snap.gi), tostring(snap.ssaoQ), tostring(snap.aoLevels)))
    end
    setVarInt("r.AntiAliasingMethod", 0)
    setVarInt("r.DynamicGlobalIlluminationMethod", 1)
    pcall(function()
        local probe = getVar("r.Lumen.ScreenProbeGather.RadianceCache.ProbeResolution")
        if probe ~= nil then probe:set_int(32) end
    end)
    setVarInt("r.AmbientOcclusionLevels", 0)
    if ssaoQ ~= nil then setVarInt("r.SSAO.Quality", 0) end
end

local function restoreFromLumen()
    if LumenSnapshot == nil then return end
    local snap = LumenSnapshot
    LumenSnapshot = nil
    if snap.gi ~= nil then setVarInt("r.DynamicGlobalIlluminationMethod", snap.gi) end
    if snap.ssaoQ ~= nil then setVarInt("r.SSAO.Quality", snap.ssaoQ) end
    if snap.aa ~= nil then setVarInt("r.AntiAliasingMethod", snap.aa) end
    log("Lumen AO disabled: restored GI/SSAO/AA to pre-Lumen state")
end

local function logVerifiedState(pawn)
    local v = {}
    pcall(function() v.rotateRate = pawn.SpringArmRotateRate end)
    pcall(function() v.newCam = pawn.bEnableNewCameraSystem end)
    pcall(function() v.desireArm = pawn.DesireSpringArmLength end)
    local boom = nil
    pcall(function() boom = pawn.ThirdPersonSpringArmComponent end)
    if boom ~= nil then
        pcall(function() v.targetArm = boom.TargetArmLength end)
        pcall(function() v.ctrlRot = boom.bUsePawnControlRotation end)
        pcall(function() v.inheritPitch = boom.bInheritPitch end)
        pcall(function() v.inheritYaw = boom.bInheritYaw end)
        pcall(function() v.inheritRoll = boom.bInheritRoll end)
        pcall(function() v.collision = boom.bDoCollisionTest end)
        pcall(function() v.lag = boom.bEnableCameraLag end)
    end
    local cam = nil
    pcall(function() cam = pawn.ThirdPersonCameraComponent end)
    if cam ~= nil then
        pcall(function() v.camCtrlRot = cam.bUsePawnControlRotation end)
    end
    log(string.format("VERIFY rotateRate=%s newCamSystem=%s desire=%s targetArm=%s ctrlRot=%s inheritPYR=%s/%s/%s collision=%s lag=%s camCtrlRot=%s",
        tostring(v.rotateRate), tostring(v.newCam), tostring(v.desireArm), tostring(v.targetArm),
        tostring(v.ctrlRot), tostring(v.inheritPitch), tostring(v.inheritYaw), tostring(v.inheritRoll),
        tostring(v.collision), tostring(v.lag), tostring(v.camCtrlRot)))
    log(string.format("EXPECT rotateRate=%s newCamSystem=false desire=<game> targetArm=<game> ctrlRot=false inheritPYR=true/true/true collision=true lag=true camCtrlRot=false",
        tostring(Config.DesiredRotateRate)))
end

local function applyCameraConfig(pawn)
    if saved == nil then saveVanilla(pawn) end

    pcall(function() pawn.SpringArmRotateRate = Config.DesiredRotateRate end)
    pcall(function() if Config.ZeroCameraDollyRate then pawn.CameraDollyRate = 0.0 end end)
    pcall(function() if Config.UseLegacyCameraSystem then pawn.bEnableNewCameraSystem = false end end)

    local boom = saved.boom
    if boom ~= nil then
        pcall(function() if Config.DisableBoomControlRotation then boom.bUsePawnControlRotation = false end end)
        pcall(function()
            if Config.DisableBoomInheritRotation then
                boom.bInheritPitch = false
                boom.bInheritYaw = false
                boom.bInheritRoll = false
            end
        end)
        pcall(function() if Config.DisableBoomCollisionTest then boom.bDoCollisionTest = false end end)
        pcall(function()
            if Config.DisableCameraLag then
                boom.bEnableCameraLag = false
                boom.bEnableCameraRotationLag = false
            end
        end)
    end

    local cam = saved.cam
    if cam ~= nil then
        pcall(function() cam.bUsePawnControlRotation = false end)
    end

    if Config.DesiredArmLength then
        applyArmLength(pawn, Config.DesiredArmLength)
    elseif saved ~= nil then
        -- game owns distance: restore its dolly + desire so it converges naturally
        pcall(function()
            if saved.dollyRate ~= nil then pawn.CameraDollyRate = saved.dollyRate end
            if saved.desireArm ~= nil then pawn.DesireSpringArmLength = saved.desireArm end
            if saved.targetArm ~= nil and saved.boom ~= nil then saved.boom.TargetArmLength = saved.targetArm end
        end)
    end

    if Config.LumenAO then
        applyLumenAO()
    end
    applyAmbientOcclusion()

    logVerifiedState(pawn)

    log("Camera configured for VR free-look")
end

local function restoreVanilla(pawn)
    if saved == nil then
        log("Nothing saved to restore")
        return
    end
    pcall(function()
        if saved.rotateRate ~= nil then pawn.SpringArmRotateRate = saved.rotateRate end
        if saved.dollyRate ~= nil then pawn.CameraDollyRate = saved.dollyRate end
        if saved.newCam ~= nil then pawn.bEnableNewCameraSystem = saved.newCam end
        if saved.desireArm ~= nil then pawn.DesireSpringArmLength = saved.desireArm end
    end)
    if saved.boom ~= nil then
        pcall(function()
            if saved.targetArm ~= nil then saved.boom.TargetArmLength = saved.targetArm end
            if saved.bUsePawnControlRotation ~= nil then saved.boom.bUsePawnControlRotation = saved.bUsePawnControlRotation end
            if saved.bInheritPitch ~= nil then saved.boom.bInheritPitch = saved.bInheritPitch end
            if saved.bInheritYaw ~= nil then saved.boom.bInheritYaw = saved.bInheritYaw end
            if saved.bInheritRoll ~= nil then saved.boom.bInheritRoll = saved.bInheritRoll end
            if saved.bDoCollisionTest ~= nil then saved.boom.bDoCollisionTest = saved.bDoCollisionTest end
            if saved.bEnableCameraLag ~= nil then saved.boom.bEnableCameraLag = saved.bEnableCameraLag end
        end)
    end
    if saved.cam ~= nil then
        pcall(function()
            if saved.camControlRot ~= nil then saved.cam.bUsePawnControlRotation = saved.camControlRot end
            if saved.camAbsolute ~= nil then saved.cam.bAbsoluteRotation = saved.camAbsolute end
        end)
    end
    log("Vanilla camera restored")
end

local function reassert(pawn)
    if saved == nil then return end
    local canary = nil
    if saved.boom ~= nil then
        pcall(function() canary = saved.boom.bUsePawnControlRotation end)
    end

    if canary == true then
        log("Game reset camera config, re-applying")
        applyCameraConfig(pawn)
        return
    end

    if Config.DesiredArmLength and saved.boom ~= nil then
        local cur = nil
        pcall(function() cur = saved.boom.TargetArmLength end)
        if cur ~= nil and math.abs(cur - Config.DesiredArmLength) > 25.0 then
            log(string.format("Arm length drifted (%.1f -> %.1f), re-applying", cur, Config.DesiredArmLength))
            applyArmLength(pawn, Config.DesiredArmLength)
        end
    end
end

UEVR_UObjectHook.activate()

uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
    if not Config.Enabled then return end

    if Config.DecoupledPitch and not decoupledPitchApplied and vr ~= nil then
        local ok = pcall(function() vr:set_decoupled_pitch_enabled(true) end)
        if ok then
            decoupledPitchApplied = true
            log("Decoupled pitch enabled")
        end
    end

    if Config.ForceMatchGameFov and not matchFovForced and vr ~= nil then
        local ok = pcall(function() vr:set_mod_value("VR_MatchGameFOV", "true") end)
        if ok then
            matchFovForced = true
            log("Match Game FOV forced on")
        end
    end

    local pawn = getLocalPawn()
    if pawn == nil then
        if lastPawn ~= nil then
            lastPawn = nil
            saved = nil
            log("Pawn lost (death/despawn), waiting for respawn")
        end
        return
    end

    if dirty or pawn ~= lastPawn then
        lastPawn = pawn
        saved = nil
        dirty = false
        applyCameraConfig(pawn)
        lastReassert = os.clock()
        return
    end

    if os.clock() - lastReassert > Config.ReassertInterval then
        reassert(pawn)
        lastReassert = os.clock()
    end
end)

uevr.lua.add_script_panel("PoT VR Camera", function()
    local changed, enabled = imgui.checkbox("Enabled", Config.Enabled)
    if changed then
        Config.Enabled = enabled
        if not enabled then dirty = true end
    end

    local currentArm = Config.DesiredArmLength
    if currentArm == nil then
        local boom = nil
        pcall(function() boom = getLocalPawn().ThirdPersonSpringArmComponent end)
        pcall(function() currentArm = boom.TargetArmLength end)
        if currentArm == nil then currentArm = 250.0 end
    end
    local chLen, len = imgui.slider_float("Arm Length (game-owned unless moved)", currentArm, 50.0, 2000.0, "%.0f")
    if chLen and len ~= Config.DesiredArmLength then
        Config.DesiredArmLength = len
        dirty = true
    end
    if Config.DesiredArmLength ~= nil then
        imgui.same_line()
        if imgui.button("Use game distance") then
            local pawn = getLocalPawn()
            if pawn ~= nil then
                pcall(function()
                    if saved.desireArm ~= nil then pawn.DesireSpringArmLength = saved.desireArm end
                    if saved.targetArm ~= nil and saved.boom ~= nil then saved.boom.TargetArmLength = saved.targetArm end
                end)
                if saved.dollyRate ~= nil then
                    pcall(function() pawn.CameraDollyRate = saved.dollyRate end)
                else
                    pcall(function() pawn.CameraDollyRate = 6000.0 end)
                end
            end
            Config.DesiredArmLength = nil
            dirty = true
            log("Arm length returned to game control")
        end
    end

    local chPitch, pitch = imgui.checkbox("Decoupled Pitch (UEVR)", Config.DecoupledPitch)
    if chPitch then
        Config.DecoupledPitch = pitch
        decoupledPitchApplied = false
    end

    local chLegacy, legacy = imgui.checkbox("Legacy camera system (5.7 rig off)", Config.UseLegacyCameraSystem)
    if chLegacy then
        Config.UseLegacyCameraSystem = legacy
        dirty = true
    end

    local chAo, ao = imgui.slider_float("SSAO Levels (0=off, 1-3=keep AO)", Config.AmbientOcclusionLevels or 0, 0, 3, "%.0f")
    if chAo then
        local newAo = math.floor(ao)
        if newAo ~= Config.AmbientOcclusionLevels then
            Config.LumenAO = false
            restoreFromLumen()
            Config.AmbientOcclusionLevels = newAo
            applyAmbientOcclusion()
            log("r.AmbientOcclusionLevels -> " .. tostring(newAo))
        end
    end

    local chRadius, radius = imgui.slider_float("AO Radius Scale (higher = stereo-stable)", Config.AORadiusScale or 1.0, 0.25, 4.0, "%.2f")
    if chRadius then
        local newRadius = math.floor(radius * 100.0 + 0.5) / 100.0
        if newRadius ~= Config.AORadiusScale then
            Config.AORadiusScale = newRadius
            local var = getVar("r.AmbientOcclusionRadiusScale")
            if var ~= nil then
                pcall(function() var:set_float(newRadius) end)
            end
            log("r.AmbientOcclusionRadiusScale -> " .. tostring(newRadius))
        end
    end

    imgui.text("AO presets (per-eye shimmer control):")
    if imgui.button("Off (low-end)") then
        Config.LumenAO = false
        applyAOPreset("off")
    end
    imgui.same_line()
    if imgui.button("Smooth (stereo-stable)") then
        Config.LumenAO = false
        applyAOPreset("smooth")
    end
    imgui.same_line()
    if imgui.button("Full") then
        Config.LumenAO = false
        applyAOPreset("full")
    end
    if imgui.button("Lumen AO (ray-based, view-independent)") then applyLumenAO() end

    local chLumen, lumen = imgui.checkbox("Use Lumen AO by default (needs GPU headroom)", Config.LumenAO)
    if chLumen then
        Config.LumenAO = lumen
        if lumen then
            applyLumenAO()
        else
            restoreFromLumen()
            Config.AmbientOcclusionLevels = 0
            Config.AORadiusScale = nil
            applyAmbientOcclusion()
            log("Lumen AO off; SSAO disabled entirely (low-end path)")
        end
    end

    local chRate, rate = imgui.slider_float("Boom Rotate Rate (0=world-fixed)", Config.DesiredRotateRate, 0.0, 800.0, "%.0f")
    if chRate and rate ~= Config.DesiredRotateRate then
        Config.DesiredRotateRate = rate
        dirty = true
    end

    local chFov, fov = imgui.checkbox("Force Match Game FOV", Config.ForceMatchGameFov)
    if chFov then
        Config.ForceMatchGameFov = fov
        if fov then matchFovForced = false end
    end

    if imgui.button("Restore vanilla") then
        local pawn = getLocalPawn()
        if pawn ~= nil then
            restoreVanilla(pawn)
            dirty = false
        else
            log("No pawn to restore")
        end
    end

    pcall(function()
        local ready = vr ~= nil and vr:is_runtime_ready()
        local active = vr ~= nil and vr:is_hmd_active()
        imgui.text(string.format("VR runtime ready: %s | HMD active: %s", tostring(ready), tostring(active)))
    end)
    imgui.text("Pawn configured: " .. tostring(lastPawn ~= nil))
end)

uevr.sdk.callbacks.on_script_reset(function()
    lastPawn = nil
    saved = nil
    dirty = false
    decoupledPitchApplied = false
    matchFovForced = false
    log("Script reset, state cleared")
end)

log("PoT VR Camera loaded (UEVR Lua)")