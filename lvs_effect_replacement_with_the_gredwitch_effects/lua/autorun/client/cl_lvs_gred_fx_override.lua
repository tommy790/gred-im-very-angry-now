--[[---------------------------------------------------------------------------
    LVS → Gredwitch FX : effect override wrapper (client-side)

    Replaces the registered LVS effect tables with wrappers that delegate to
    the LVS_GRED_FX bridge (lua/lvs_gred_fx/). The original effect tables are
    captured before wrapping so that:

      * when a Gredwitch replacement succeeds, the original visual is fully
        suppressed (the wrapper owns the effect registration — the original
        simply never runs),
      * when a replacement fails or is declined, the wrapper falls back to the
        original LVS effect so LVS visuals are never permanently broken,
      * useful non-visual behaviour (screenshake, explosion sound timing,
        the lvs_bullet_impact_ap trigger) is preserved by running the
        original Init/Think in a "feedback-only" mode: particles, lights,
        decals and nested effects are suppressed, screenshake and sound are
        kept.

    All temporary global overrides used for feedback mode are restored even if
    the original errors. Re-application passes run at startup and on reload so
    late-mounted effect addons are still wrapped.
-----------------------------------------------------------------------------]]

if not CLIENT then return end

LVS_GRED_FX_OVERRIDE = LVS_GRED_FX_OVERRIDE or {}
LVS_GRED_FX_OVERRIDE.OriginalEffects = LVS_GRED_FX_OVERRIDE.OriginalEffects or {}
LVS_GRED_FX_OVERRIDE.BadOriginalInit = LVS_GRED_FX_OVERRIDE.BadOriginalInit or {}

local OVERRIDE_MARKER = "__lvs_gred_fx_override"

--[[---------------------------------------------------------------------------
    Module includes (dependency order — see each file's header).
-----------------------------------------------------------------------------]]
local MODULES = {
    "lvs_gred_fx/config.lua",
    "lvs_gred_fx/debug.lua",
    "lvs_gred_fx/particles.lua",
    "lvs_gred_fx/muzzle.lua",
    "lvs_gred_fx/tracer.lua",
    "lvs_gred_fx/muzzleflash.lua",
    "lvs_gred_fx/barrelsmoke.lua",
    "lvs_gred_fx/impacts.lua",
    "lvs_gred_fx/trails.lua",
    "lvs_gred_fx/bridge.lua",
}

local function includeModules()
    for _, file in ipairs(MODULES) do
        include(file)
    end
    return include("lvs_gred_fx/effect_list.lua")
end

local function isEnabled()
    return LVS_GRED_FX and LVS_GRED_FX.Enabled and LVS_GRED_FX.Enabled() or false
end

local function debugPrint(...)
    if LVS_GRED_FX and LVS_GRED_FX.Debug then
        LVS_GRED_FX.Debug(...)
    end
end

--[[---------------------------------------------------------------------------
    Original effect capture.
-----------------------------------------------------------------------------]]
local function tryCaptureTable(effectName)
    if not effects then return nil end

    if effects.Get then
        local ok, res = pcall(effects.Get, effectName)
        if ok and istable(res) then return res end
    end

    if effects.Create then
        local ok, res = pcall(effects.Create, effectName)
        if ok and istable(res) then return res end
    end

    if effects.List then
        local res = effects.List[effectName]
        if istable(res) then return res end
    end

    return nil
end

local function captureOriginal(effectName)
    if LVS_GRED_FX_OVERRIDE.OriginalEffects[effectName] then return end

    local template = tryCaptureTable(effectName)
    if not template or template[OVERRIDE_MARKER] then return end

    LVS_GRED_FX_OVERRIDE.OriginalEffects[effectName] = {
        Init     = template.Init,
        Think    = template.Think,
        Render   = template.Render,
        Template = template,
    }
end

--[[---------------------------------------------------------------------------
    Original invocation helpers.
-----------------------------------------------------------------------------]]
local function seedOriginalFields(effectName, self)
    local orig = LVS_GRED_FX_OVERRIDE.OriginalEffects[effectName]
    local template = orig and orig.Template
    if not istable(template) then return end

    -- Original LVS effects often store materials/tables as fields on the
    -- EFFECT table (SmokeMat, MatBeam, ...). Copy non-lifecycle fields so a
    -- fallback/feedback original Init never errors on missing fields.
    for k, v in pairs(template) do
        if k ~= "Init" and k ~= "Think" and k ~= "Render" and k ~= OVERRIDE_MARKER then
            self[k] = v
        end
    end
end

local function callOriginalInit(effectName, self, data)
    if LVS_GRED_FX_OVERRIDE.BadOriginalInit[effectName] then return false end

    local orig = LVS_GRED_FX_OVERRIDE.OriginalEffects[effectName]
    if not orig or not orig.Init then return true end

    seedOriginalFields(effectName, self)

    local ok, err = pcall(orig.Init, self, data)
    if not ok then
        -- Remember broken originals so we never retry them every shot.
        LVS_GRED_FX_OVERRIDE.BadOriginalInit[effectName] = true
        ErrorNoHalt("[lvs_gred_fx] original Init failed for " .. tostring(effectName) .. ": " .. tostring(err) .. "\n")
        return false
    end

    return true
end

--[[---------------------------------------------------------------------------
    Feedback-only execution.

    Runs the original Init/Think with visual side effects suppressed but
    non-visual feedback (util.ScreenShake, sound.Play, movement/timing logic)
    preserved. Every global is restored even when the original errors.
-----------------------------------------------------------------------------]]
local function _feedbackNoop() end
local function _feedbackNil() return nil end

local FEEDBACK_DUMMY_PARTICLE = {}
setmetatable(FEEDBACK_DUMMY_PARTICLE, {
    __index = function() return _feedbackNoop end,
})

local FEEDBACK_DUMMY_EMITTER = {}
function FEEDBACK_DUMMY_EMITTER:Add() return FEEDBACK_DUMMY_PARTICLE end
function FEEDBACK_DUMMY_EMITTER:Finish() end
function FEEDBACK_DUMMY_EMITTER:SetNoDraw() end
function FEEDBACK_DUMMY_EMITTER:Draw() end
function FEEDBACK_DUMMY_EMITTER:IsValid() return true end
setmetatable(FEEDBACK_DUMMY_EMITTER, {
    __index = function() return _feedbackNoop end,
})

local SUPPRESSED_GLOBALS = {
    { "ParticleEffect",            _feedbackNoop },
    { "ParticleEffectAttach",      _feedbackNoop },
    { "CreateParticleSystem",      _feedbackNil },
    { "CreateParticleSystemNoEntity", _feedbackNil },
    { "ParticleEmitter",           function() return FEEDBACK_DUMMY_EMITTER end },
    { "DynamicLight",              _feedbackNil },
}

local function installFeedbackSuppression()
    local old = {}
    for i = 1, #SUPPRESSED_GLOBALS do
        local name = SUPPRESSED_GLOBALS[i][1]
        old[i] = _G[name]
        _G[name] = SUPPRESSED_GLOBALS[i][2]
    end

    old.utilEffect = util and util.Effect
    old.utilDecal = util and util.Decal
    old.utilDecalEx = util and util.DecalEx
    if util then
        util.Effect = _feedbackNoop
        util.Decal = _feedbackNoop
        util.DecalEx = _feedbackNoop
    end

    -- sound.Play is intentionally NOT suppressed: explosion/impact sounds are
    -- useful non-visual feedback that should be preserved.

    return old
end

local function restoreFeedbackSuppression(old)
    for i = 1, #SUPPRESSED_GLOBALS do
        _G[SUPPRESSED_GLOBALS[i][1]] = old[i]
    end
    if util then
        util.Effect = old.utilEffect
        util.Decal = old.utilDecal
        util.DecalEx = old.utilDecalEx
    end
end

local function callOriginalInitFeedbackOnly(effectName, self, data)
    local orig = LVS_GRED_FX_OVERRIDE.OriginalEffects[effectName]
    if not orig or not orig.Init then return false end

    seedOriginalFields(effectName, self)

    local old = installFeedbackSuppression()
    local ok, err = pcall(orig.Init, self, data)
    restoreFeedbackSuppression(old)

    if not ok then
        debugPrint("original feedback Init failed", effectName, err)
        return false
    end

    return true
end

-- Silent original Think: suppresses visuals; lets the nested
-- lvs_bullet_impact_ap effect through (that is where LVS triggers the AP
-- impact at its exact timing — our registered override then replaces it).
local function callOriginalThinkSilently(effectName, self)
    local orig = LVS_GRED_FX_OVERRIDE.OriginalEffects[effectName]
    if not orig or not orig.Think then return nil end

    local old = installFeedbackSuppression()
    if util then
        util.Effect = function(n, effectData, allowOverride, ignorePrediction)
            if n == "lvs_bullet_impact_ap" and old.utilEffect then
                return old.utilEffect(n, effectData, allowOverride, ignorePrediction)
            end
        end
    end

    local ok, ret = pcall(orig.Think, self)
    restoreFeedbackSuppression(old)

    if not ok then
        debugPrint("original silent Think failed", effectName, ret)
        return nil
    end

    return ret == true
end

local function callOriginalThink(effectName, self)
    local orig = LVS_GRED_FX_OVERRIDE.OriginalEffects[effectName]
    if not orig or not orig.Think then return false end

    local ok, ret = pcall(orig.Think, self)
    if not ok then return false end

    return ret == true
end

local function callOriginalRender(effectName, self)
    local orig = LVS_GRED_FX_OVERRIDE.OriginalEffects[effectName]
    if not orig or not orig.Render then return end

    local ok, err = pcall(orig.Render, self)
    if not ok then
        ErrorNoHalt("[lvs_gred_fx] original Render failed for " .. tostring(effectName) .. ": " .. tostring(err) .. "\n")
    end
end

local function stopReplacement(effectName, self)
    if LVS_GRED_FX and LVS_GRED_FX.Stop then
        pcall(LVS_GRED_FX.Stop, effectName, self)
    end
end

--[[---------------------------------------------------------------------------
    Wrapper registration.
-----------------------------------------------------------------------------]]
local function registerOverride(effectName)
    if not isstring(effectName) or effectName == "" then return end

    captureOriginal(effectName)

    local EFFECT = {}
    EFFECT[OVERRIDE_MARKER] = true
    EFFECT._lvs_gred_effect_name = effectName

    function EFFECT:Init(data)
        self._lvs_gred_effect_name = effectName
        self._lvs_gred_fx_handled = false

        if not isEnabled() then
            callOriginalInit(effectName, self, data)
            return
        end

        local ok, ret = pcall(LVS_GRED_FX.Init, effectName, self, data)

        if not ok then
            -- Replacement errored: fall back to the original so LVS visuals
            -- are never broken by a bad replacement.
            if LVS_GRED_FX.ReportError then
                LVS_GRED_FX.ReportError("replacement Init for " .. effectName, ret)
            end
            callOriginalInit(effectName, self, data)
            return
        end

        if ret == false then
            -- Replacement declined: fall back to the original.
            callOriginalInit(effectName, self, data)
            return
        end

        -- Replacement active. Preserve non-visual feedback from the original
        -- Init (screenshake, explosion sound timing).
        if LVS_GRED_FX.ShouldRunOriginalFeedback and LVS_GRED_FX.ShouldRunOriginalFeedback(effectName) then
            callOriginalInitFeedbackOnly(effectName, self, data)
        end

        self._lvs_gred_fx_handled = true
    end

    function EFFECT:Think()
        if self._lvs_gred_fx_handled and isEnabled() then
            -- Run the original Think silently where it is the authoritative
            -- lifetime/behaviour oracle (tracers: fires the AP impact and
            -- decides when the bullet is done).
            if LVS_GRED_FX.WantsOriginalThink and LVS_GRED_FX.WantsOriginalThink(effectName) then
                local alive = callOriginalThinkSilently(effectName, self)
                if alive == false then
                    stopReplacement(effectName, self)
                    return false
                end
            end

            local ok, ret = pcall(LVS_GRED_FX.Think, effectName, self)
            if not ok then
                if LVS_GRED_FX.ReportError then
                    LVS_GRED_FX.ReportError("replacement Think for " .. effectName, ret)
                end
                stopReplacement(effectName, self)
                return false
            end

            if ret ~= true then
                stopReplacement(effectName, self)
                return false
            end

            return true
        end

        return callOriginalThink(effectName, self)
    end

    function EFFECT:Render()
        if self._lvs_gred_fx_handled and isEnabled() then
            if LVS_GRED_FX.Render then
                pcall(LVS_GRED_FX.Render, effectName, self)
            end
            return
        end

        callOriginalRender(effectName, self)
    end

    effects.Register(EFFECT, effectName)
    LVS_GRED_FX_OVERRIDE.Registered = LVS_GRED_FX_OVERRIDE.Registered or {}
    LVS_GRED_FX_OVERRIDE.Registered[effectName] = true

    debugPrint("registered override", effectName)
end

local function applyOverrides()
    if not effects or not effects.Register then return end

    local names = includeModules()
    if not istable(names) then
        ErrorNoHalt("[lvs_gred_fx] failed to include lvs_gred_fx/effect_list.lua\n")
        return
    end

    for i = 1, #names do
        registerOverride(names[i])
    end
end

hook.Add("InitPostEntity", "lvs_gred_fx_override_effects", applyOverrides)
hook.Add("OnReloaded", "lvs_gred_fx_override_effects", applyOverrides)
-- Late passes: some LVS/vehicle addons register their effects after the
-- client autorun; late passes ensure our exact-name replacements remain the
-- active registered effects.
timer.Simple(0, applyOverrides)
timer.Simple(1, applyOverrides)
timer.Simple(5, applyOverrides)

--[[---------------------------------------------------------------------------
    Options menu.
-----------------------------------------------------------------------------]]
hook.Add("PopulateToolMenu", "LVS_GRED_FX_Menu", function()
    spawnmenu.AddToolMenuOption("Options", "LVS", "LVS_Gred_FX", "Gredwitch FX", "", "", function(panel)
        panel:ClearControls()
        panel:Help("Client-side LVS visual effect replacements using Gredwitch-style particle systems.")

        panel:CheckBox("Enable Gredwitch FX Overrides", "lvs_gred_fx")
        panel:ControlHelp("Replaces registered LVS client VFX. LVS damage, ballistics, physics and networking are untouched.")

        panel:CheckBox("Enable Cannon Barrel Smoke", "lvs_gred_fx_barrel_smoke")
        panel:ControlHelp("Spawns short-lived, attachment-following barrel smoke after cannon shots.")

        panel:CheckBox("Enable Debug Mode", "lvs_gred_fx_debug")
        panel:ControlHelp("Prints mapping, attachment resolution and spawn diagnostics to the console (rate-limited).")
    end)
end)
