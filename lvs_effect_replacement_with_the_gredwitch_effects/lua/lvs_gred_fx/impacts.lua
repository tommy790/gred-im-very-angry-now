--[[---------------------------------------------------------------------------
    LVS → Gredwitch FX : impacts & explosions (client-side)

    Handles normal impacts, AP impacts, HE/explosive impacts, laser impacts,
    shield impacts, water impacts and one-shot world effects.

    Duplicate-impact suppression:
      LVS autocannons/cannons fire BOTH a splash explosion (on collision) and
      lvs_bullet_impact_ap (on the tracer Think when the bullet ends) at the
      same spot. This module records every explosive/HE impact in a BOUNDED
      ring buffer (max C.ImpactBufferMax entries) that is entity-, position-
      and time-aware, and suppresses the AP impact when it matches a recent
      explosion nearby. The buffer is fixed-size and lazily overwritten, so it
      can never grow without bound.
-----------------------------------------------------------------------------]]

if not CLIENT then return end

local cfg = LVS_GRED_FX.Config
local Debug = LVS_GRED_FX.Debug

LVS_GRED_FX_IMPACTS = LVS_GRED_FX_IMPACTS or {}

--[[---------------------------------------------------------------------------
    Bounded ring buffer of recent explosive/HE impacts.
-----------------------------------------------------------------------------]]
local ring = {}
local ringNext = 1
local ringCount = 0

local function isExplosiveName(name)
    if not isstring(name) then return false end
    return string.find(name, "explosion", 1, true) ~= nil
        or string.find(name, "explosive", 1, true) ~= nil
end

local function RecordExplosion(name, ent, pos)
    if not isvector(pos) then return end

    ring[ringNext] = {
        name = name,
        ent  = ent,
        pos  = pos,
        time = CurTime(),
    }
    ringNext = ringNext % cfg.ImpactBufferMax + 1
    if ringCount < cfg.ImpactBufferMax then
        ringCount = ringCount + 1
    end
end

-- True when an explosive impact was recorded near `pos` within `window`
-- seconds. Passing `ent` tightens the match when the same entity fired both.
-- lvs_defence_explosion (flak) always pairs with an AP impact and drifts more,
-- so it uses its own wider time/space window.
local function RecentExplosionNear(pos, window, radiusSqr, ent)
    if not isvector(pos) then return false end

    local now = CurTime()

    for i = 1, ringCount do
        local e = ring[i]
        if e then
            local win = window
            local w = radiusSqr
            if e.name == "lvs_defence_explosion" then
                win = cfg.DefenceSuppressWindow
                w = cfg.DefenceSuppressRadiusSqr
            end
            if (now - e.time) <= win then
                local d = pos:DistToSqr(e.pos)
                if d <= w then
                    return true
                end
                -- Same-entity hits may drift a bit further while still being
                -- the same impact; only apply the widened check for matching
                -- entities.
                if ent and e.ent == ent and d <= w * 4 then
                    return true
                end
            end
        end
    end

    return false
end

function LVS_GRED_FX_IMPACTS.RecentExplosionNear(pos, window, radiusSqr, ent)
    return RecentExplosionNear(pos, window, radiusSqr, ent)
end

--[[---------------------------------------------------------------------------
    GredImpact — surface-aware impact.

    * 20/30/40mm → gred's own gred_particle_impact effect (surface prop 0 =
      ground hit), which plays gred_20mm / 30cal_impact / gred_40mm with
      decals and blood. Surface 0 is deliberate: it is the ground-hit branch,
      exactly like the original addon.
    * 7/12mm → gred's impact effect cannot resolve a surface index for these,
      so spawn the surface particle directly (doi_/ins_impact_<material> or
      the water impact) — always visible.
    * If the gred base is missing or the gred effect call errors, fall back to
      a directly spawned surface particle so impacts are never lost.
-----------------------------------------------------------------------------]]
local MAT_IMPACT_FALLBACK = {
    [MAT_CONCRETE] = "impact_concrete",
    [MAT_METAL]    = "impact_metal",
    [MAT_WOOD]     = "impact_wood",
    [MAT_GLASS]    = "impact_glass",
    [MAT_SAND]     = "impact_sand",
    [MAT_DIRT]     = "impact_dirt",
    [MAT_GRASS]    = "impact_grass",
    [MAT_SNOW]     = "impact_snow",
    [MAT_FLESH]    = "impact_metal",
    [MAT_ALIENFLESH] = "impact_metal",
    [MAT_BLOODYFLESH] = "impact_metal",
}

-- Spawn a directly-visible surface impact particle for small calibers.
local function spawnSmallCaliberImpact(pos, n, caliber, isWater)
    local pcf
    if isWater then
        pcf = "doi_impact_water"
    else
        local tr = util.TraceLine({
            start = pos + n * 1,
            endpos = pos - n * 12,
            mask = MASK_SHOT,
        })
        local mat = tr.MatType or MAT_METAL
        -- 7mm uses the doi_ surface set, 12mm uses the ins_ surface set
        -- (mirrors gred's own impact effect prefixes).
        local prefix = (caliber == "12mm") and "ins_" or "doi_"
        pcf = prefix .. (MAT_IMPACT_FALLBACK[mat] or "impact_metal")
    end

    -- Orient by the PROVIDED impact normal with gred's small-caliber pitch
    -- convention. Gred's own bullet code adds +90 to the pitch for 7/12mm
    -- (the ins_/doi_ impact sprites are authored expecting it); without it
    -- the autocannon AP impact rendered rotated 90 degrees. Larger calibers
    -- (fallback only) use explosion-style particles that don't need it.
    local ang = n:Angle()
    if caliber == "7mm" or caliber == "12mm" then
        ang.p = ang.p + 90
    end
    return LVS_GRED_FX.SpawnWorldOneShot(pcf, pos, ang)
end

function LVS_GRED_FX.GredImpact(pos, normal, caliber, isWater)
    if not cfg.Enabled() then return false end
    if not isvector(pos) then return false end

    local n = isvector(normal) and normal or vector_up
    local cal = isstring(caliber) and caliber or "20mm"
    local calIndex = cfg.CaliberIndex[cal] or 3

    -- Small calibers: direct surface particle (guaranteed visible).
    if calIndex <= 2 then
        return spawnSmallCaliberImpact(pos, n, cal, isWater)
    end

    -- 20/30/40mm: gred's own surface-aware impact effect (ground branch).
    if gred and gred.Calibre and gred.Calibre[calIndex] then
        local e = EffectData()
        e:SetOrigin(pos)
        e:SetAngles(n:Angle())
        e:SetFlags(calIndex)
        e:SetMaterialIndex(isWater and 0 or 1) -- 1 = ground, 0 = water
        e:SetSurfaceProp(0)

        local ok = pcall(util.Effect, "gred_particle_impact", e)
        if ok then return true end
    end

    -- Fallback: directly spawned surface particle so the impact never
    -- disappears silently.
    return spawnSmallCaliberImpact(pos, n, cal, isWater)
end

--[[---------------------------------------------------------------------------
    Water detection helper.
-----------------------------------------------------------------------------]]
function LVS_GRED_FX.IsInWater(pos)
    if not isvector(pos) then return false end

    local tr = util.TraceLine({
        start = pos + Vector(0, 0, 4),
        endpos = pos - Vector(0, 0, 4),
        mask = MASK_WATER,
    })

    return tr.Hit == true
end

--[[---------------------------------------------------------------------------
    Position-based throttle for frequently re-fired effects (smoke puffs).
    Bounded: entries older than the window are dropped lazily and the table is
    wiped once it grows past 64 keys.
-----------------------------------------------------------------------------]]
local throttles = {}
local throttleCount = 0

-- Persistent defence-smoke systems: one continuous smoke cloud per canister
-- position. Keyed by a position cell so multiple canisters coexist; a sweeper
-- fades systems a few seconds after the canister stops re-firing.
local DEFENCE_SMOKE = {}

-- Loose psys validity (particle handles are not entities).
local function PsysValidLoose(psys)
    if not psys then return false end
    if psys.IsValid then
        local ok = pcall(function() return psys:IsValid() end)
        return ok == true
    end
    return true
end

timer.Create("lvs_gred_fx_defence_smoke_sweep", 1, 0, function()
    local now = CurTime()
    for key, sys in pairs(DEFENCE_SMOKE) do
        if not PsysValidLoose(sys.psys) or (sys.expires or 0) < now then
            if PsysValidLoose(sys.psys) then
                pcall(function() sys.psys:StopEmission(false, false) end)
            end
            DEFENCE_SMOKE[key] = nil
        end
    end
end)

local function ThrottleAt(pos, keyName, window)
    if not isvector(pos) then return true end

    local key = keyName .. ":" .. math.floor(pos.x / 50) .. "," .. math.floor(pos.y / 50) .. "," .. math.floor(pos.z / 50)

    local now = CurTime()
    local expires = throttles[key]

    if throttleCount > 64 then
        -- Keep the table bounded: drop expired entries in one pass.
        local nextThrottles = {}
        local n = 0
        for k, v in pairs(throttles) do
            if v > now then
                nextThrottles[k] = v
                n = n + 1
            end
        end
        throttles = nextThrottles
        throttleCount = n
    end

    if expires and expires > now then
        return false
    end

    throttles[key] = now + window
    throttleCount = throttleCount + 1

    return true
end

--[[---------------------------------------------------------------------------
    One-shot dispatch table (world-space effects).

    Every branch returns whether a replacement particle actually spawned.
    Returning false makes the override wrapper fall back to the original LVS
    effect, so a failed replacement (missing particle system, create error)
    can never leave an impact silently missing.
-----------------------------------------------------------------------------]]
local function dispatchOneShot(name, self, data)
    local pos = data.GetOrigin and data:GetOrigin() or nil
    local nrm = data.GetNormal and data:GetNormal() or nil
    local ent = data.GetEntity and data:GetEntity() or nil

    if not isvector(pos) then return false end

    local ang = isvector(nrm) and nrm:Angle() or nil

    -- Record ANY explosive/HE effect for AP duplicate suppression.
    if isExplosiveName(name) then
        RecordExplosion(name, ent, pos)
        if cfg.DebugEnabled() then
            Debug("recorded explosion:", name, "pos:", tostring(pos))
        end
    end

    local pcf = cfg.ExplosionMap[name]

    if pcf then
        if LVS_GRED_FX.IsInWater(pos) and (name == "lvs_explosion" or name == "lvs_explosion_bomb" or name == "lvs_explosion_small" or name == "lvs_explosion_nodebris" or name == "lvs_trailer_explosion") then
            return LVS_GRED_FX.SpawnWorldOneShot(cfg.WaterExplosionPcf, pos, ang)
        end
        return LVS_GRED_FX.SpawnWorldOneShot(pcf, pos, ang)
    end

    if name == "lvs_laser_explosion" or name == "lvs_laser_explosion_aat" or name:find("lvs_laser_explosion", 1, true) then
        return LVS_GRED_FX.SpawnWorldOneShot(cfg.LaserExplosionPcf, pos, ang)
    end

    if name == "lvs_bullet_impact_explosive" then
        -- HE hit: caliber-specific explosion (visually distinct from AP).
        -- LVS's splash EffectData carries no shooter entity, so use the global
        -- last-fired caliber. Autocannons (30mm) -> gred_20mm, cannons (40mm)
        -- -> gred_40mm.
        local cal = LVS_GRED_FX_TRACER.CaliberFor(nil)
        local hePcf = cfg.HEImpactByCaliber[cal] or "gred_20mm"
        if LVS_GRED_FX.IsInWater(pos) then
            return LVS_GRED_FX.SpawnWorldOneShot(cfg.WaterExplosionPcf, pos, ang)
        end
        return LVS_GRED_FX.SpawnWorldOneShot(hePcf, pos, ang)
    end

    if name == "lvs_bullet_impact_ap" then
        -- AP impact: LVS autocannons/cannons fire BOTH a splash explosion (on
        -- collision) and lvs_bullet_impact_ap (on the next tracer Think) at
        -- the same spot, so we only want ONE visual. The explosion is recorded
        -- by dispatchOneShot; DEFER the AP particle 0.1s (like the old addon)
        -- and cancel it only if an explosion actually fired at the same spot
        -- in that window. If no explosion fired, spawn the AP particle.
        local apPos = pos
        local apNrm = isvector(nrm) and nrm or vector_up
        local apEnt = ent

        -- Use the GLOBAL last-fired caliber: the AP impact's entity is the
        -- HIT surface, whose per-entity records (if any) belong to the target,
        -- not the shooter. The most recent shot anywhere is the shot whose
        -- tracer Think fired this AP impact.
        local cal = LVS_GRED_FX_TRACER.CaliberFor(nil)
        local apPcf = cfg.APImpactPcfByCaliber[cal]

        timer.Simple(0.1, function()
            if not cfg.Enabled() then return end

            if RecentExplosionNear(apPos, cfg.SuppressWindow, cfg.SuppressRadiusSqr, apEnt) then
                if cfg.DebugEnabled() then
                    Debug("AP impact suppressed (duplicate of recent explosion) at", tostring(apPos))
                end
                return
            end

            if apPcf then
                -- Large-calibre AP (40mm+): dedicated AP spark (ParticleEffect).
                LVS_GRED_FX.SpawnWorldOneShot(apPcf, apPos + apNrm * 2, apNrm:Angle())
            else
                -- Autocannon / small-calibre AP: SMALL surface impact, clearly
                -- smaller than the HE explosion. The 12mm surface-aware profile
                -- (ins_impact_* / doi_impact_*) is subtle; routing autocannon
                -- AP through 30cal_impact made it look like a BIGGER explosion
                -- than the gred_20mm HE impact (wrong).
                LVS_GRED_FX.GredImpact(apPos, apNrm, cfg.APImpactAutocannonCaliber or "12mm", LVS_GRED_FX.IsInWater(apPos))
            end
        end)

        return true
    end

    if name == "lvs_bullet_impact" then
        -- Generic bullet / splash impact: surface-aware.
        local cal = LVS_GRED_FX_TRACER.CaliberFor(ent)
        return LVS_GRED_FX.GredImpact(pos, nrm, cal, LVS_GRED_FX.IsInWater(pos))
    end

    if name == "lvs_laser_impact" then
        return LVS_GRED_FX.SpawnWorldOneShot(cfg.LaserImpactPcf, pos, ang)
    end

    if name == "lvs_shield_impact" then
        return LVS_GRED_FX.SpawnWorldOneShot(cfg.ShieldImpactPcf, pos, ang)
    end

    if cfg.WaterByEffect[name] then
        return LVS_GRED_FX.SpawnWorldOneShot(cfg.WaterByEffect[name], pos, ang or angle_zero)
    end

    if name == "lvs_physics_scrape" or name == "lvs_physics_trackscraping" or name == "lvs_physics_turretscraping" then
        -- Scrape effects can fire every physics tick while a vehicle grinds
        -- against the ground; throttle by position so spark systems never
        -- stack up during a long scrape. Throttled repeats count as handled.
        if ThrottleAt(pos, "scrape", 0.15) then
            return LVS_GRED_FX.SpawnWorldOneShot(cfg.ScrapePcf, pos, ang or angle_zero)
        end
        return true
    end

    if name == "lvs_defence_smoke" then
        -- LVS re-fires this every 0.2s while the smoke canister is active.
        -- A canister needs a CONTINUOUS smoke cloud, not throttled one-shot
        -- puffs (which made it look like nothing). Keep ONE persistent smoke
        -- system per canister position: start/refresh it on fire, and let it
        -- fade out a few seconds after the canister stops re-firing.
        if ThrottleAt(pos, "defence_smoke", 0.2) then
            local key = "defence_smoke:" .. math.floor(pos.x / 50) .. "," .. math.floor(pos.y / 50) .. "," .. math.floor(pos.z / 50)
            local sys = DEFENCE_SMOKE[key]

            if sys and PsysValidLoose(sys.psys) then
                -- canister still active: refresh the fade-out deadline
                sys.expires = CurTime() + 3
            else
                -- start a new continuous smoke system
                local psys = LVS_GRED_FX.SpawnWorld(cfg.DefenceSmokePcf, pos, angle_zero, 3, false)
                if psys then
                    DEFENCE_SMOKE[key] = { psys = psys, expires = CurTime() + 3 }
                end
            end
        end
        return true
    end

    if name == "lvs_walker_stomp" then
        local a = LVS_GRED_FX.SpawnWorldOneShot(cfg.StompDustPcf, pos, angle_zero)
        local b = LVS_GRED_FX.SpawnWorldOneShot("ins_rpg_explosion", pos + Vector(0, 0, 8), angle_zero)
        return a or b
    end

    if name == "lvs_rotor_destruction" then
        return LVS_GRED_FX.SpawnWorldOneShot(cfg.RotorExplosionPcf, pos, angle_zero)
    end

    if name == "lvs_tire_blow" then
        return LVS_GRED_FX.SpawnWorldOneShot(cfg.StompDustPcf, pos, angle_zero)
    end

    if name:find("muzzle", 1, true) then
        -- Unknown/third-party muzzle effect: use the generic attached flash.
        return LVS_GRED_FX_MUZZLEFLASH.SpawnGeneric(name, self, data)
    end

    return false
end

function LVS_GRED_FX_IMPACTS.Dispatch(name, self, data)
    return dispatchOneShot(name, self, data)
end
