--[[---------------------------------------------------------------------------
    LVS → Gredwitch FX : entity trails & attached fire (client-side)

    * lvs_missiletrail / lvs_concussion_trail / lvs_proton_trail → gred
      rocket/grenade/smoke trails, locked to the projectile entity with
      PATTACH_ABSORIGIN_FOLLOW (the trail follows the projectile exactly).
    * lvs_firetrail → burning debris trail, attached to the burning entity at
      the local fire offset, following it.
    * lvs_carengine_fire / lvs_carfueltank_fire → gred fire, attached to the
      vehicle at the fire position (PATTACH_ABSORIGIN_FOLLOW + local offset).
    * lvs_ammorack_fire → violent flame jet on the vehicle; one jet per
      vehicle, replaced on re-fire.
    * lvs_laser_charge → short sparking charge effect; sparks are attached to
      the emitter attachment with PATTACH_POINT_FOLLOW so they follow the
      weapon while charging.
-----------------------------------------------------------------------------]]

if not CLIENT then return end

local cfg = LVS_GRED_FX.Config
local Debug = LVS_GRED_FX.Debug

LVS_GRED_FX_TRAILS = LVS_GRED_FX_TRAILS or {}

--[[---------------------------------------------------------------------------
    Entity trails (missile / concussion / proton).
-----------------------------------------------------------------------------]]
function LVS_GRED_FX_TRAILS.InitEntTrail(name, self, data)
    self._gmode = "enttrail"

    local ent = data.GetEntity and data:GetEntity() or nil
    self._gent = ent

    if not IsValid(ent) or not cfg.Enabled() then return false end

    local t = cfg.TrailMap[name] or { pcf = "rockettrail", offset = vector_origin }
    local pcf = t.pcf

    if not LVS_GRED_FX.Preload(pcf) then
        return true -- handled but no visuals (original suppressed)
    end

    local ok, psys = pcall(CreateParticleSystem, ent, pcf, PATTACH_ABSORIGIN_FOLLOW, 0, t.offset)

    if ok and IsValid(psys) then
        self._psys = psys
        return true
    end

    return false
end

function LVS_GRED_FX_TRAILS.ThinkEntTrail(self)
    if cfg.Enabled() and IsValid(self._gent) and self._psys and IsValid(self._psys) then
        if (self._gdie or 0) > 0 and CurTime() >= self._gdie then
            -- Optional hard lifetime (e.g. fire trails that must end before
            -- the burning body is removed).
            if self._psys and IsValid(self._psys) then
                pcall(function() self._psys:StopEmission(false, false) end)
                self._psys = nil
            end
            return false
        end
        return true
    end

    if self._psys and IsValid(self._psys) then
        pcall(function() self._psys:StopEmission(false, false) end)
        self._psys = nil
    end

    return false
end

--[[---------------------------------------------------------------------------
    lvs_firetrail — burning vehicle/debris trail.
-----------------------------------------------------------------------------]]
function LVS_GRED_FX_TRAILS.InitFireTrail(name, self, data)
    self._gmode = "enttrail"

    local ent = data.GetEntity and data:GetEntity() or nil
    self._gent = ent

    if not IsValid(ent) or not cfg.Enabled() then return false end

    local pcf = cfg.FireTrailPcf
    if not LVS_GRED_FX.Preload(pcf) then return true end

    -- data:GetStart() is the fire position in the entity's local space
    -- (PhysObj mass center). Attach the trail at that local offset so it
    -- follows the burning body exactly.
    local offset = data.GetStart and data:GetStart() or vector_origin
    if not isvector(offset) then offset = vector_origin end

    local ok, psys = pcall(CreateParticleSystem, ent, pcf, PATTACH_ABSORIGIN_FOLLOW, 0, offset)

    if ok and IsValid(psys) then
        self._psys = psys

        -- LVS sets the lifetime via data:GetMagnitude() (time until boom);
        -- stop the trail shortly after so we never outlive the body.
        local life = data.GetMagnitude and data:GetMagnitude() or 3
        life = math.Clamp(life + 1, 1, 8)
        self._gdie = CurTime() + life
        LVS_GRED_FX.StopAfter(psys, life, false)

        return true
    end

    return false
end

--[[---------------------------------------------------------------------------
    Attached fire (engine / fuel tank).
-----------------------------------------------------------------------------]]
local FIRE_ACTIVE = setmetatable({}, { __mode = "k" })

function LVS_GRED_FX_TRAILS.InitEntFire(name, self, data)
    self._gmode = "oneshot"

    local ent = data.GetEntity and data:GetEntity() or nil
    if not IsValid(ent) or not cfg.Enabled() then return false end

    local pcf = cfg.EntFirePcf[name]
    if not pcf or not LVS_GRED_FX.Preload(pcf) then return false end

    -- Replace any previous fire on this entity (LVS re-fires periodically).
    local prev = FIRE_ACTIVE[ent]
    if prev and prev.psys and IsValid(prev.psys) then
        pcall(function() prev.psys:StopEmission(false, true) end)
        FIRE_ACTIVE[ent] = nil
    end

    local firePos = data.GetOrigin and data:GetOrigin() or ent:GetPos()
    local offset = isvector(firePos) and ent:WorldToLocal(firePos) or vector_origin

    local ok, psys = pcall(CreateParticleSystem, ent, pcf, PATTACH_ABSORIGIN_FOLLOW, 0, offset)

    if ok and IsValid(psys) then
        LVS_GRED_FX.StopAfter(psys, 1.5, false)
        FIRE_ACTIVE[ent] = { psys = psys }
        return true
    end

    return false
end

--[[---------------------------------------------------------------------------
    Ammo rack fire — violent jet, one per vehicle, replaced on re-fire.
-----------------------------------------------------------------------------]]
local AMMORACK_ACTIVE = setmetatable({}, { __mode = "k" })

function LVS_GRED_FX_TRAILS.InitAmmoRack(name, self, data)
    self._gmode = "oneshot"

    local ent = data.GetEntity and data:GetEntity() or nil
    if not IsValid(ent) or not cfg.Enabled() then return false end

    local pcf = cfg.AmmoRackPcf
    if not LVS_GRED_FX.Preload(pcf) then return false end

    local prev = AMMORACK_ACTIVE[ent]
    if prev then
        -- Already burning; keep the existing jet alive.
        if IsValid(prev.psys) then
            prev.expires = CurTime() + 2
            return true
        end
        AMMORACK_ACTIVE[ent] = nil
    end

    local firePos = data.GetOrigin and data:GetOrigin() or ent:GetPos()
    local offset = isvector(firePos) and ent:WorldToLocal(firePos) or vector_origin

    local ok, psys = pcall(CreateParticleSystem, ent, pcf, PATTACH_ABSORIGIN_FOLLOW, 0, offset)

    if ok and IsValid(psys) then
        LVS_GRED_FX.StopAfter(psys, 2.2, false)
        AMMORACK_ACTIVE[ent] = { psys = psys, expires = CurTime() + 2 }
        return true
    end

    return false
end

--[[---------------------------------------------------------------------------
    Laser charge — sparks attached to the emitter attachment.
-----------------------------------------------------------------------------]]
function LVS_GRED_FX_TRAILS.InitLaserCharge(name, self, data)
    self._gmode = "laserchg"

    local ent = data.GetEntity and data:GetEntity() or nil
    local att = data.GetAttachment and data:GetAttachment() or 0

    if not IsValid(ent) or att <= 0 then return false end
    if not LVS_GRED_FX.ValidAttachment(ent, att) then return false end

    self._gent = ent
    self._gatt = att
    self._gdie = CurTime() + cfg.ChargeLife
    self._gnext = 0

    return true
end

function LVS_GRED_FX_TRAILS.ThinkLaserCharge(self)
    if not cfg.Enabled() or (self._gdie or 0) < CurTime() or not IsValid(self._gent) then
        return false
    end

    if CurTime() < (self._gnext or 0) then return true end

    self._gnext = CurTime() + cfg.ChargeInterval

    -- Sparks follow the emitter attachment (PATTACH_POINT_FOLLOW).
    LVS_GRED_FX.SpawnAttached("muzzleflash_sparks_variant_6", self._gent, self._gatt, {
        life = 0.3,
        clear = true,
    })

    return true
end
