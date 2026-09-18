--[[---------------------------------------------------------------------------
    LVS → Gredwitch FX : barrel smoke (client-side)

    Fully independent of the muzzle-flash system. Barrel smoke resolves its
    own muzzle attachment with the same shot direction the flash used
    (ray-based resolver, muzzle.lua), attaches with PATTACH_POINT_FOLLOW and
    stops itself after a fixed lifetime. One smoke column at a time per
    (entity, pcf): firing again replaces the previous one so rapid fire never
    stacks smoke systems.

    Spawning accepts a single PCF name or a LIST of names (every loadable one
    spawns, so cannons can keep their dual smoke look). When EVERY configured
    PCF fails to precache (e.g. the VJ smoke pack is not mounted — the #1
    reason smoke silently never played), the cfg.SmokeFallbacks chain is
    tried so the shot still emits a smoke puff instead of nothing.

    Gated by the lvs_gred_fx_barrel_smoke cvar.
-----------------------------------------------------------------------------]]

if not CLIENT then return end

local cfg = LVS_GRED_FX.Config
local Debug = LVS_GRED_FX.Debug
local DebugOnce = LVS_GRED_FX.DebugOnce

LVS_GRED_FX_BARRELSMOKE = LVS_GRED_FX_BARRELSMOKE or {}

-- Particle system handles are NOT entities: the global IsValid() returns
-- false for them. Validate via the :IsValid() method when present.
local function PsysValid(psys)
    if not psys then return false end
    if psys.IsValid then
        local ok = pcall(function() return psys:IsValid() end)
        return ok == true
    end
    return true
end


-- Weak-keyed on the ENTITY: dead entities are dropped by the GC.
-- Each entity maps to { [pcf] = { psys, expires } } so DIFFERENT smoke types
-- (vj narrow + muzzle smoke) coexist per entity; only the SAME type is
-- replaced (faded out) on re-fire.
local ACTIVE = setmetatable({}, { __mode = "k" })

-- Periodic sweeper: stop systems whose owner vanished or whose lifetime
-- expired without the StopAfter timer firing (safety net).
timer.Create("lvs_gred_fx_smoke_sweep", 2, 0, function()
    local now = CurTime()

    for ent, byPcf in pairs(ACTIVE) do
        if not IsValid(ent) then
            ACTIVE[ent] = nil
        else
            for pcf, info in pairs(byPcf) do
                if (info.expires or 0) < now then
                    if PsysValid(info.psys) then
                        pcall(function() info.psys:StopEmission(false, false) end)
                    end
                    byPcf[pcf] = nil
                end
            end
        end
    end
end)

-- Normalize the configured smoke name(s), keep only the ones that actually
-- precache, and walk the fallback chain when none of them do.
local function CollectUsablePcfs(pcfList)
    local usable = {}

    local function tryAdd(pcf)
        if isstring(pcf) and pcf ~= "" and LVS_GRED_FX.Preload(pcf) then
            usable[#usable + 1] = pcf
        end
    end

    if isstring(pcfList) then
        tryAdd(pcfList)
    elseif istable(pcfList) then
        for i = 1, #pcfList do
            tryAdd(pcfList[i])
        end
    end

    if #usable == 0 then
        local fallbacks = cfg.SmokeFallbacks or {}
        for i = 1, #fallbacks do
            local pcf = fallbacks[i]
            if isstring(pcf) and pcf ~= "" and LVS_GRED_FX.Preload(pcf) then
                usable[1] = pcf
                if DebugOnce then
                    DebugOnce("smokefallback", "configured smoke PCFs unavailable; using fallback smoke:", pcf)
                end
                break
            end
        end
    end

    return usable
end

-- Spawn ONE smoke type; throttled and tracked per (ent, pcf).
-- worldPos is only used when no attachment resolved (world fallback).
local function SpawnOne(ent, worldPos, smokeAtt, pcf, ang)
    local byPcf = ACTIVE[ent]
    if not byPcf then
        byPcf = {}
        ACTIVE[ent] = byPcf
    end

    -- RATE LIMIT: rapid fire (autocannons/MGs fire every 0.05-0.15s) would
    -- spawn a new smoke system per shot, stacking many overlapping systems
    -- before the previous ones fade. Only spawn if this smoke type was not
    -- just spawned for this entity within the throttle window.
    local lastSpawn = byPcf[pcf] and byPcf[pcf].spawnedAt or 0
    if CurTime() - lastSpawn < cfg.SmokeThrottle then
        return
    end

    -- Replacing the SAME smoke type: stop the old one from emitting and let
    -- its existing particles fade naturally (StopEmission, clear=false) — do
    -- NOT delete it instantly. Different types coexist.
    local prev = byPcf[pcf]
    if prev then
        if PsysValid(prev.psys) then
            pcall(function() prev.psys:StopEmission(false, false) end)
        end
        byPcf[pcf] = nil
    end

    local psys
    if smokeAtt and smokeAtt > 0 and LVS_GRED_FX.ValidAttachment(ent, smokeAtt) then
        -- forceHandle: smoke must be trackable so we can replace it later.
        psys = LVS_GRED_FX.SpawnAttached(pcf, ent, smokeAtt, {
            life = cfg.SmokeLife,
            clear = false,
            forceHandle = true,
            ang = ang,
        })
    end

    if not psys then
        if cfg.DebugEnabled() then
            Debug("barrel smoke world fallback:", pcf,
                "pos:", tostring(worldPos),
                "reason: no valid attachment", "att:", tostring(smokeAtt))
        end
        psys = LVS_GRED_FX.SpawnWorld(pcf, worldPos, ang or angle_zero, cfg.SmokeLife, false)
    end

    if PsysValid(psys) then
        byPcf[pcf] = {
            psys    = psys,
            att     = smokeAtt,
            spawnedAt = CurTime(),
            expires = CurTime() + cfg.SmokeLife + 0.1,
        }
    end
end

--[[---------------------------------------------------------------------------
    Spawn( ent, muzzlePos, att, pcfList, shotDir )

      ent       — entity owning the barrel (pass the VEHICLE ROOT)
      muzzlePos — world muzzle source position; MUST be the RAW EffectData
                  snapshot (snapshot compensation happens here, exactly once)
      att       — already-resolved muzzle attachment id (0/nil → re-resolve)
      pcfList   — single PCF name or a list of names
      shotDir   — optional bullet direction; feeds the ray-fit resolver so
                  smoke lands on the same barrel the flash did
-----------------------------------------------------------------------------]]
function LVS_GRED_FX_BARRELSMOKE.Spawn(ent, muzzlePos, att, pcfList, shotDir)
    if not cfg.SmokeEnabled() then return end
    if not IsValid(ent) or not isvector(muzzlePos) then return end

    local usable = CollectUsablePcfs(pcfList)
    if #usable == 0 then return end

    -- Resolve the muzzle attachment independently of the flash system, but
    -- with the same shot direction: the ray-fit resolver picks the firing
    -- barrel's attachment, not the nearest-by-point-distance guess that used
    -- to glue smoke to the wrong (often hidden) attachment. Compensation of
    -- the server-side snapshot (muzzle.lua) happens EXACTLY ONCE, on
    -- whichever path below runs — callers must pass the RAW EffectData
    -- muzzle position, never a compensated one.
    local smokeAtt = att
    local worldPos = muzzlePos -- used only if nothing attaches (fallback)

    if not smokeAtt or smokeAtt <= 0 then
        local info
        smokeAtt, info = LVS_GRED_FX.ResolveMuzzleAttachment(ent, muzzlePos, 0, shotDir)
        if istable(info) and isvector(info.correctedPos) then
            worldPos = info.correctedPos
        end
    else
        local cpos = LVS_GRED_FX.CompensateMuzzleSnapshot(ent, muzzlePos, shotDir)
        if isvector(cpos) then
            worldPos = cpos
        end
    end

    local ang = isvector(shotDir) and shotDir:Angle() or nil

    for i = 1, #usable do
        SpawnOne(ent, worldPos, smokeAtt, usable[i], ang)
    end
end
