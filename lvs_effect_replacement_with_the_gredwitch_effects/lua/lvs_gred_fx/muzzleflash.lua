--[[---------------------------------------------------------------------------
    LVS → Gredwitch FX : muzzle flashes (client-side)

    Every muzzle-mounted particle spawned here uses PATTACH_POINT_FOLLOW on the
    resolved muzzle attachment, so the flash stays glued to the barrel while
    the weapon traverses, elevates, recoils, animates or moves with the vehicle.

    Resolution order (see muzzle.lua):
      1. LVS EffectData attachment id (validated)
      2. Authoritative LVS muzzle attachment name (TurretBallisticsMuzzleAttachment)
      3. Named muzzle/barrel candidates nearest to the muzzle position
         (correct barrel on multi-barrel / alternating-barrel weapons)
      4. Strict nearest attachment (models without named muzzles)
      5. World-position fallback — strictly last, always logged with the reason

    The muzzle world position is used to FIND the attachment; it is never the
    preferred way to render the final effect.

    The PCF choice is driven by the most recent matching tracer shot (firing
    order), falling back to a per-effect default when the tracer has not been
    received yet — the flash itself never depends on tracer timing, so it can
    never be delayed or dropped because of pairing.
-----------------------------------------------------------------------------]]

if not CLIENT then return end

local cfg = LVS_GRED_FX.Config
local Debug = LVS_GRED_FX.Debug

LVS_GRED_FX_MUZZLEFLASH = LVS_GRED_FX_MUZZLEFLASH or {}

function LVS_GRED_FX.GetMuzzleRollFix(pcf, ent)
    if not isstring(pcf) then return nil end

    if IsValid(ent) then
        local model = ent:GetModel()
        if isstring(model) then
            local byModel = cfg.MuzzleRollFixByModel[model]
            if byModel and byModel[pcf] ~= nil then return byModel[pcf] end
        end

        local class = ent:GetClass()
        if isstring(class) then
            local byClass = cfg.MuzzleRollFixByClass[class]
            if byClass and byClass[pcf] ~= nil then return byClass[pcf] end
        end
    end

    return nil
end

-- Spawn one muzzle-mounted flash particle. Returns true on success.
local function spawnFlash(pcf, ent, muzzlePos, ang, att, life)
    if not cfg.Enabled() or not isstring(pcf) then return false end
    if not LVS_GRED_FX.Preload(pcf) then return false end

    -- The gred artillery muzzle blasts are ALWAYS spawned at the muzzle world
    -- position as a plain ParticleEffect one-shot, oriented by the LVS bullet
    -- direction — exactly how the original addon did it. Some LVS models
    -- expose muzzle attachments that are mis-rotated for these large
    -- directional effects, which made the blast spray in the wrong direction
    -- when attached. Only these two PCFs are affected; every other
    -- muzzle-mounted particle stays PATTACH_POINT_FOLLOW.
    if pcf == "gred_arti_muzzle_blast_alt" or pcf == "gred_arti_muzzle_blast" then
        if cfg.DebugEnabled() then
            Debug("muzzle flash world spawn (rotation-safe):", pcf,
                "pos:", tostring(muzzlePos),
                "attachment available:", tostring(att))
        end
        return LVS_GRED_FX.SpawnWorldOneShot(pcf, muzzlePos, ang)
    end

    local roll = LVS_GRED_FX.GetMuzzleRollFix(pcf, ent)

    if att and att > 0 and LVS_GRED_FX.ValidAttachment(ent, att) then
        local ok = LVS_GRED_FX.SpawnAttached(pcf, ent, att, {
            life = life,
            clear = true,
            ang = ang,
            roll = roll,
        })
        if ok then
            if cfg.DebugEnabled() then
                Debug("muzzle flash:", pcf, "attached att:", att,
                    "name:", LVS_GRED_FX.AttachmentName(ent, att),
                    "POINT_FOLLOW:", ok == true and "yes" or "yes(handle)")
            end
            return true
        end
    end

    -- No usable attachment: world-position fallback (documented last resort).
    if cfg.DebugEnabled() then
        Debug("muzzle flash world fallback:", pcf,
            "pos:", tostring(muzzlePos),
            "reason: no valid attachment",
            "att:", tostring(att))
    end

    return LVS_GRED_FX.SpawnWorld(pcf, muzzlePos, ang, life, true) ~= nil
end

-- Spawn the full artillery muzzle flash: a single gred artillery blast
-- (world ParticleEffect one-shot) + barrel smoke handled separately by the
-- caller. The original addon did NOT layer extra spark/glow effects on top of
-- the gred artillery blast — the gred_arti_muzzle_sparks layer made the
-- muzzle read as "just a spark effect" instead of the complete flash.
local function spawnArtillery(ent, muzzlePos, ang, att, life)
    return spawnFlash(cfg.DefaultMuzzleByEffect.lvs_haubitze_muzzle or "gred_arti_muzzle_blast_alt", ent, muzzlePos, ang, att, life)
end

-- Spawn a generic multi-layer flash for unknown lvs_*muzzle* effect names.
local function spawnGenericMuzzle(ent, muzzlePos, ang, att)
    local ok = false

    for i = 1, #cfg.GenericMuzzleFlash do
        local pcf = cfg.GenericMuzzleFlash[i]
        if pcf and pcf ~= "" then
            ok = spawnFlash(pcf, ent, muzzlePos, ang, att, cfg.FlashLife) or ok
        end
    end

    return ok
end

--[[---------------------------------------------------------------------------
    Spawn — main entry from the bridge.

    effectName: the LVS muzzle effect name (lvs_muzzle, lvs_muzzle_colorable,
                lvs_pulserifle_muzzle, lvs_haubitze_muzzle, ...)
-----------------------------------------------------------------------------]]
function LVS_GRED_FX_MUZZLEFLASH.Spawn(effectName, self, data)
    if not cfg.Enabled() then return false end

    local ent = data.GetEntity and data:GetEntity() or nil
    local muzzlePos = data.GetOrigin and data:GetOrigin() or nil
    local normal = data.GetNormal and data:GetNormal() or nil
    local dataAtt = data.GetAttachment and data:GetAttachment() or 0

    if not isvector(muzzlePos) then
        return false
    end

    local ang = isvector(normal) and normal:Angle() or nil

    if not IsValid(ent) then
        -- Without a valid entity there is nothing to attach to. Fall back to
        -- a plain world flash at the muzzle position so the shot still reads.
        Debug("muzzle effect without entity; world fallback:", effectName)
        return LVS_GRED_FX.SpawnWorldOneShot(cfg.DefaultMuzzleByEffect[effectName] or cfg.DefaultMuzzle, muzzlePos, ang)
    end

    if cfg.DebugEnabled() then
        Debug("muzzle effect:", effectName, "ent:", ent:GetClass(),
            "muzzle pos:", tostring(muzzlePos))
    end

    -- The muzzle attachment lives on the VEHICLE ROOT, not necessarily on
    -- the effect's entity: LVS fires lvs_muzzle on the gunner pod
    -- (lvs_base_gunner), whose own model has no muzzle attachments — the
    -- barrel attachment is on the parent vehicle (e.g. lvs_w50_zu_w).
    -- Resolve on the root so the flash/smoke attach to the real barrel.
    local rootEnt = LVS_GRED_FX.VehicleRoot(ent)

    -- Resolve the correct muzzle attachment (never "attachment 1" guessing).
    local att, info = LVS_GRED_FX.ResolveMuzzleAttachment(rootEnt, muzzlePos, dataAtt)

    if cfg.DebugEnabled() then
        Debug("muzzle attachment:", "id:", att, "method:", info and info.method,
            "dist:", info and info.dist and string.format("%.1f", info.dist) or "n/a",
            "name:", info and info.name or "?")
    end

    -- Choose the flash PCF from the most recent matching shot (firing order);
    -- fall back to the per-effect default when no tracer has been seen yet.
    local rec = LVS_GRED_FX_TRACER.RecentShot(rootEnt, muzzlePos)
    local map = rec and rec.map or nil

    local pcf = (map and map.muzzle)
        or cfg.DefaultMuzzleByEffect[effectName]
        or cfg.DefaultMuzzle

    local isArtillery = effectName == "lvs_haubitze_muzzle"
        or (map and (map.caliber == "40mm" or map.caliber == "50mm"))
        or pcf == "gred_arti_muzzle_blast_alt"

    local ok

    -- Spawn on rootEnt (the entity that owns the resolved attachment) so the
    -- PATTACH_POINT_FOLLOW id matches the entity.
    if isArtillery then
        ok = spawnArtillery(rootEnt, muzzlePos, ang, att, cfg.ArtilleryLife)
    else
        ok = spawnFlash(pcf, rootEnt, muzzlePos, ang, att, cfg.FlashLife)
    end

    -- Barrel smoke: separate system, resolved with its own attachment lookup,
    -- so a smoke bug can never take the muzzle flash down with it. Uses the
    -- tracer-paired PCF(s), or the per-effect default (e.g. haubitze) when no
    -- tracer record has paired yet. The smoke field can be a single string or
    -- a list (cannons spawn BOTH vj_smoke_white_narrow and weapon_muzzle_smoke
    -- at the same time).
    local smokeList = (map and map.smoke) or cfg.DefaultSmokeByEffect[effectName]
    if cfg.SmokeEnabled() and smokeList then
        if isstring(smokeList) then
            smokeList = { smokeList }
        end
        for i = 1, #smokeList do
            local pcf = smokeList[i]
            if pcf and pcf ~= "" then
                LVS_GRED_FX_BARRELSMOKE.Spawn(rootEnt, muzzlePos, att, pcf)
            end
        end
    end

    -- The tracer record sometimes arrives a frame after the muzzle effect
    -- (network ordering). The attachment is already resolved and used above;
    -- this deferred pass only upgrades the PCF (and smoke) when a matching
    -- tracer shot now exists. It runs at most once.
    if not rec then
        timer.Simple(0, function()
            if not cfg.Enabled() then return end
            if not IsValid(rootEnt) then return end

            local recNow = LVS_GRED_FX_TRACER.RecentShot(rootEnt, muzzlePos)
            local mapNow = recNow and recNow.map
            if not mapNow then return end

            local pcfNow = mapNow.muzzle
            if not pcfNow or pcfNow == pcf then return end

            local artiNow = mapNow.caliber == "40mm" or mapNow.caliber == "50mm"
                or pcfNow == "gred_arti_muzzle_blast_alt"

            if artiNow then
                spawnArtillery(rootEnt, muzzlePos, ang, att, cfg.ArtilleryLife)
            else
                spawnFlash(pcfNow, rootEnt, muzzlePos, ang, att, cfg.FlashLife)
            end

            local smokeListNow = mapNow.smoke or cfg.DefaultSmokeByEffect[effectName]
            if cfg.SmokeEnabled() and smokeListNow then
                if isstring(smokeListNow) then
                    smokeListNow = { smokeListNow }
                end
                for i = 1, #smokeListNow do
                    local pcf = smokeListNow[i]
                    if pcf and pcf ~= "" then
                        LVS_GRED_FX_BARRELSMOKE.Spawn(rootEnt, muzzlePos, att, pcf)
                    end
                end
            end
        end)
    end

    -- Haubitze: also draw a short ballistic path beam in world space (this is
    -- a tracer-like visualization, not a muzzle-mounted particle).
    if effectName == "lvs_haubitze_muzzle" and isvector(normal) then
        LVS_GRED_FX_MUZZLEFLASH.SpawnHaubitzeBeam(muzzlePos, normal)
    end

    return ok
end

-- World-space beam used by the haubitze (ballistic path visualization).
function LVS_GRED_FX_MUZZLEFLASH.SpawnHaubitzeBeam(muzzlePos, dir)
    local pcf = "gred_tracers_white_40mm"
    if not LVS_GRED_FX.Preload(pcf) then return end

    local tr = util.TraceLine({
        start = muzzlePos,
        endpos = muzzlePos + dir * 20000,
        mask = MASK_SHOT + MASK_WATER,
    })

    local endpos = tr.HitPos or (muzzlePos + dir * 20000)

    local psys = LVS_GRED_FX.SpawnWorld(pcf, muzzlePos, dir:Angle(), 0.5, true)
    if psys and IsValid(psys) then
        pcall(function() psys:SetControlPoint(1, endpos) end)
    end
end

-- Exposed for the bridge's generic "unknown muzzle effect" branch.
function LVS_GRED_FX_MUZZLEFLASH.SpawnGeneric(effectName, self, data)
    local ent = data.GetEntity and data:GetEntity() or nil
    local muzzlePos = data.GetOrigin and data:GetOrigin() or nil
    local normal = data.GetNormal and data:GetNormal() or nil
    local dataAtt = data.GetAttachment and data:GetAttachment() or 0

    if not isvector(muzzlePos) or not IsValid(ent) then return false end

    local ang = isvector(normal) and normal:Angle() or nil
    local att, info = LVS_GRED_FX.ResolveMuzzleAttachment(ent, muzzlePos, dataAtt)

    if cfg.DebugEnabled() then
        Debug("generic muzzle effect:", effectName, "att:", att,
            "method:", info and info.method, "dist:", info and info.dist)
    end

    return spawnGenericMuzzle(ent, muzzlePos, ang, att)
end
