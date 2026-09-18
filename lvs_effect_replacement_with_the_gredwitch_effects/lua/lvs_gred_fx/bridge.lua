--[[---------------------------------------------------------------------------
    LVS → Gredwitch FX : bridge / dispatcher (client-side)

    Single entry point consumed by the override wrapper
    (autorun/client/cl_lvs_gred_fx_override.lua). Routes every overridden LVS
    effect to the right module and exposes the policy functions the wrapper
    needs:

      * Enabled()                        — master toggle
      * ShouldRunOriginalFeedback(name)  — run original Init with visuals
                                           suppressed but screenshake/sound
                                           preserved (explosions, impacts,
                                           tracers, haubitze)
      * WantsOriginalThink(name)         — run original Think silently as the
                                           authoritative lifetime/behaviour
                                           oracle (tracers, trails, charge)
      * Init / Think / Stop / Render     — replacement lifecycle

    Contract with the wrapper:
      Init returns false  → replacement declined; wrapper runs the original.
      Init returns true   → replacement active; wrapper handles feedback +
                            lifetime oracles; Think drives the effect until it
                            returns false, then Stop is called.
      _gmode "oneshot"    → Think immediately returns false; spawned particles
                            own their lifetime (StopAfter timers) so a failed
                            particle can never break the LVS effect flow.

    This file contains NO gameplay logic: LVS damage, ballistics, projectile
    physics, weapon logic, vehicle physics, networking and firing mechanics
    are left completely untouched.
-----------------------------------------------------------------------------]]

if not CLIENT then return end

local cfg = LVS_GRED_FX.Config

-- Build a fast lookup of tracer effect names from the config mapping.
local TRACER_NAMES = {}
for name in pairs(cfg.Tracers) do
    TRACER_NAMES[name] = true
end

function LVS_GRED_FX.IsTracerName(name)
    return TRACER_NAMES[name] == true
end

function LVS_GRED_FX.Enabled()
    return cfg.Enabled()
end

--[[---------------------------------------------------------------------------
    Policy: which originals should still run their Init for non-visual
    feedback (screenshake, explosion sound timing) while particles/lights/
    decals are suppressed?
-----------------------------------------------------------------------------]]
function LVS_GRED_FX.ShouldRunOriginalFeedback(name)
    if TRACER_NAMES[name] then return true end

    return name == "lvs_haubitze_muzzle"
        or name == "lvs_explosion"
        or name == "lvs_explosion_bomb"
        or name == "lvs_explosion_small"
        or name == "lvs_explosion_nodebris"
        or name == "lvs_trailer_explosion"
        or name == "lvs_defence_explosion"
        or name == "lvs_concussion_explosion"
        or name == "lvs_proton_explosion"
        or name == "lvs_bullet_impact"
        or name == "lvs_bullet_impact_ap"
        or name == "lvs_bullet_impact_explosive"
        or name == "lvs_laser_impact"
        or name == "lvs_shield_impact"
        or name == "lvs_laser_explosion"
        or name == "lvs_laser_explosion_aat"
end

--[[---------------------------------------------------------------------------
    Policy: which originals have a Think that must keep running silently?

    Only tracers: the original LVS tracer Think fires lvs_bullet_impact_ap at
    LVS's exact timing and decides when the bullet/beam is done. All other
    overridden effects drive their own lifetime (trails follow their entity,
    the laser charge has its own DieTime, one-shots own their particles).
-----------------------------------------------------------------------------]]
function LVS_GRED_FX.WantsOriginalThink(name)
    return TRACER_NAMES[name] == true
end

--[[---------------------------------------------------------------------------
    Init dispatcher.
-----------------------------------------------------------------------------]]
function LVS_GRED_FX.Init(name, self, data)
    self._gname = name

    if not cfg.Enabled() then return false end
    if not data then return false end

    -- Tracers → gred beams following the live LVS bullet.
    if TRACER_NAMES[name] then
        return LVS_GRED_FX_TRACER.Init(name, self, data)
    end

    -- Muzzle flashes → PATTACH_POINT_FOLLOW on the resolved muzzle attachment.
    if name == "lvs_muzzle" or name == "lvs_muzzle_colorable" or name == "lvs_pulserifle_muzzle" or name == "lvs_haubitze_muzzle" then
        return LVS_GRED_FX_MUZZLEFLASH.Spawn(name, self, data)
    end

    -- Entity trails & attached fire.
    if cfg.TrailMap[name] then
        return LVS_GRED_FX_TRAILS.InitEntTrail(name, self, data)
    end
    if name == "lvs_firetrail" then
        return LVS_GRED_FX_TRAILS.InitFireTrail(name, self, data)
    end
    if name == "lvs_carengine_fire" or name == "lvs_carfueltank_fire" then
        return LVS_GRED_FX_TRAILS.InitEntFire(name, self, data)
    end
    if name:find("lvs_ammorack_fire", 1, true) then
        return LVS_GRED_FX_TRAILS.InitAmmoRack(name, self, data)
    end
    if name == "lvs_laser_charge" then
        return LVS_GRED_FX_TRAILS.InitLaserCharge(name, self, data)
    end

    -- Impacts, explosions, water, misc one-shots.
    return LVS_GRED_FX_IMPACTS.Dispatch(name, self, data)
end

function LVS_GRED_FX.Think(name, self)
    if not cfg.Enabled() then return false end

    local mode = self._gmode

    if mode == "tracer" then
        return LVS_GRED_FX_TRACER.Think(self)
    end
    if mode == "enttrail" then
        return LVS_GRED_FX_TRAILS.ThinkEntTrail(self)
    end
    if mode == "laserchg" then
        return LVS_GRED_FX_TRAILS.ThinkLaserCharge(self)
    end

    -- "oneshot" and everything else: nothing to keep alive; the spawned
    -- particle systems own their own lifetime.
    return false
end

function LVS_GRED_FX.Stop(name, self)
    if not self then return end

    if self._gmode == "tracer" then
        LVS_GRED_FX_TRACER.Stop(self)
    end

    if self._psys and IsValid(self._psys) then
        pcall(function() self._psys:StopEmission(false, false) end)
        self._psys = nil
    end
end

function LVS_GRED_FX.Render(name, self)
    -- Render is unused: all replacement visuals are particle systems, which
    -- the engine renders itself.
end
