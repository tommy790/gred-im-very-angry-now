--[[---------------------------------------------------------------------------
    LVS → Gredwitch FX : configuration module (client-side)

    Single source of truth for:
      * client cvars
      * LVS tracer name → Gredwitch (color / caliber / muzzle / smoke) mapping
      * per-effect particle mappings (explosions, impacts, water, trails, fire)
      * muzzle flash roll fixes (per model / per class)
      * tuning constants (attachment tolerances, lifetimes, budgets)

    Everything else in this addon reads from this module so that mappings can
    be adjusted in one place.
-----------------------------------------------------------------------------]]

if not CLIENT then return end

LVS_GRED_FX = LVS_GRED_FX or {}

local function getOrCreateClientConVar(name, default, helpText)
    return GetConVar(name) or CreateClientConVar(name, default, true, false, helpText or "")
end

local C = {}

C.CvarEnabled = getOrCreateClientConVar("lvs_gred_fx", "1", "Replace LVS client VFX with Gredwitch PCF particles.")
C.CvarDebug   = getOrCreateClientConVar("lvs_gred_fx_debug", "0", "Print debug info for LVS Gredwitch FX mapping.")
C.CvarSmoke   = getOrCreateClientConVar("lvs_gred_fx_barrel_smoke", "1", "Enable short-lived barrel smoke after cannon shots.")

function C.Enabled() return C.CvarEnabled:GetBool() end
function C.DebugEnabled() return C.CvarDebug:GetBool() end
function C.SmokeEnabled() return C.CvarSmoke:GetBool() end

-- Gredwitch caliber index (gred.Calibre[ i ]) and tracer color index.
C.CaliberIndex = {
    ["7mm"]  = 1,
    ["12mm"] = 2,
    ["20mm"] = 3,
    ["30mm"] = 4,
    ["40mm"] = 5,
    ["50mm"] = 5, -- gred.Calibre only defines up to 40mm; fold 50mm into 40mm
}

C.ColorIndex = {
    red    = 1,
    green  = 2,
    white  = 3,
    yellow = 4,
}

-- Fallback used when a tracer name is not in C.Tracers.
C.TracerDefaults = { color = "white", caliber = "20mm", muzzle = "muzzleflash_bar_3p" }

--[[---------------------------------------------------------------------------
    Tracer mapping — the single source of truth for tracer replacement.

    Each LVS tracer maps to:
      color   → gred tracer beam color (gred_tracers_<color>_<caliber>)
      caliber → gred caliber (also drives impact severity)
      muzzle  → preferred muzzle flash PCF when this tracer fired
      smoke   → optional barrel smoke PCF after firing
-----------------------------------------------------------------------------]]
C.Tracers = {
    -- Small arms / MGs
    lvs_tracer_yellow_small     = { color = "yellow", caliber = "12mm", muzzle = "muzzleflash_mg42_3p",       smoke = "weapon_muzzle_smoke" },
    lvs_pulserifle_tracer       = { color = "white",  caliber = "7mm",  muzzle = "muzzleflash_mg42_3p" },
    lvs_pulserifle_tracer_large = { color = "white",  caliber = "12mm", muzzle = "muzzleflash_mg42_3p" },

    -- Rifle calibre tracers
    lvs_tracer_orange           = { color = "yellow", caliber = "20mm", muzzle = "muzzleflash_bar_3p",        smoke = "weapon_muzzle_smoke" },
    lvs_tracer_green            = { color = "green",  caliber = "20mm", muzzle = "muzzleflash_bar_3p",        smoke = "weapon_muzzle_smoke" },
    lvs_tracer_yellow           = { color = "yellow", caliber = "20mm", muzzle = "muzzleflash_bar_3p",        smoke = "weapon_muzzle_smoke" },
    lvs_tracer_white            = { color = "white",  caliber = "20mm", muzzle = "muzzleflash_bar_3p",        smoke = "weapon_muzzle_smoke" },

    -- Autocannon / cannon / rockets
    lvs_tracer_autocannon       = { color = "white",  caliber = "30mm", muzzle = "muzzleflash_bar_3p",        smoke = "weapon_muzzle_smoke" },
    lvs_tracer_missile          = { color = "yellow", caliber = "30mm", muzzle = "muzzleflash_bar_3p" },
    lvs_tracer_cannon           = { color = "white",  caliber = "40mm", muzzle = "gred_arti_muzzle_blast_alt", smoke = { "vj_smoke_white_narrow", "weapon_muzzle_smoke" } },
    lvs_tracer_proton           = { color = "white",  caliber = "40mm", muzzle = "gred_arti_muzzle_blast_alt", smoke = { "vj_smoke_white_narrow", "weapon_muzzle_smoke" } },

    -- Lasers (gred has no blue beam; blue lasers read best as white tracers)
    lvs_laser_blue              = { color = "white",  caliber = "30mm", muzzle = "muzzleflash_bar_3p" },
    lvs_laser_blue_long         = { color = "white",  caliber = "30mm", muzzle = "muzzleflash_bar_3p" },
    lvs_laser_blue_short        = { color = "white",  caliber = "20mm", muzzle = "muzzleflash_bar_3p" },
    lvs_laser_green             = { color = "green",  caliber = "30mm", muzzle = "muzzleflash_bar_3p" },
    lvs_laser_green_short       = { color = "green",  caliber = "20mm", muzzle = "muzzleflash_bar_3p" },
    lvs_laser_red               = { color = "red",    caliber = "30mm", muzzle = "muzzleflash_bar_3p" },
    lvs_laser_red_short         = { color = "red",    caliber = "20mm", muzzle = "muzzleflash_bar_3p" },
    lvs_laser_red_aat           = { color = "red",    caliber = "40mm", muzzle = "gred_arti_muzzle_blast_alt" },
}

-- Muzzle flash default PCF used when no tracer record is available yet.
C.DefaultMuzzle = "muzzleflash_bar_3p"

-- Default smoke PCF per muzzle effect, used when no tracer record has paired
-- yet (matches the old addon: haubitze used vj_smoke_white_medium).
C.DefaultSmokeByEffect = {
    lvs_haubitze_muzzle = "vj_smoke_white_medium",
}

C.DefaultMuzzleByEffect = {
    lvs_muzzle_colorable = "muzzleflash_bar_3p",
    lvs_pulserifle_muzzle = "muzzleflash_mg42_3p",
    lvs_haubitze_muzzle   = "gred_arti_muzzle_blast_alt",
}

-- Generic muzzle effect fallback layers (unknown lvs_*muzzle* effect names).
C.GenericMuzzleFlash = {
    "muzzleflash_sparks_variant_6",
    "muzzleflash_1p_glow",
    "muzzleflash_m590_1p_core",
    "muzzleflash_smoke_small_variant_1",
}

-- Roll fixes for PCFs that sit sideways on specific models/classes.
-- Keyed by PCF name. Scoped tightly so one model fix cannot affect others.
C.MuzzleRollFixByModel = {
    ["models/diggercars/willys/willys_mg.mdl"] = {
        muzzleflash_mg42_3p = -90,
    },
}

C.MuzzleRollFixByClass = {
    lvs_wheeldrive_dodwillyjeep_mg = {
        muzzleflash_mg42_3p = -90,
    },
}

-- One-shot particle lifetimes (seconds).
C.FlashLife        = 0.35  -- small arms / MG muzzle flash
C.ArtilleryLife    = 0.6   -- cannon / haubitze muzzle flash
C.SmokeLife        = 2.5   -- barrel smoke
C.SmokeThrottle    = 0.35  -- min seconds between new smoke systems of the same
                           -- type per entity (rapid fire would otherwise stack)
C.ChargeLife       = 0.35  -- laser charge duration (matches LVS)
C.ChargeInterval   = 0.04  -- laser charge spark interval

--[[---------------------------------------------------------------------------
    Impact / explosion mappings.
-----------------------------------------------------------------------------]]
C.ExplosionMap = {
    lvs_explosion          = "doi_flak88_explosion",
    lvs_explosion_bomb     = "doi_flak88_explosion",
    lvs_explosion_small    = "ins_rpg_explosion",
    lvs_explosion_nodebris = "ins_rpg_explosion",
    lvs_trailer_explosion  = "gred_40mm",
    lvs_defence_explosion  = "gred_20mm",
    lvs_concussion_explosion = "napalm_explosion_midair",
    lvs_proton_explosion   = "napalm_explosion_midair",
}

C.LaserExplosionPcf = "high_explosive_air_2"
C.LaserImpactPcf    = "high_explosive_air_2"
C.ShieldImpactPcf   = "AP_impact_wall"
C.WaterExplosionPcf = "ins_water_explosion"

-- HE/explosive bullet impacts by caliber (lvs_bullet_impact_explosive).
C.HEImpactByCaliber = {
    ["30mm"] = "gred_20mm",
    ["40mm"] = "gred_40mm",
    ["50mm"] = "gred_50mm",
}

-- AP impact visual by caliber (lvs_bullet_impact_ap).
C.APImpactPcfByCaliber = {
    ["40mm"] = "gred_ap_impact",
    ["50mm"] = "gred_ap_impact",
}

-- Autocannon / small-calibre AP uses the 12mm surface-aware profile
-- (ins_impact_* / doi_impact_* small surface puffs) — clearly smaller than
-- the gred_20mm HE explosion. (30cal_impact looked like a bigger explosion
-- than the HE impact, which is wrong for AP.)
C.APImpactAutocannonCaliber = "12mm"

-- Duplicate-impact suppression tuning (bounded ring buffer, pos + time aware).
C.SuppressWindow     = 0.5   -- seconds
C.SuppressRadiusSqr  = 300 * 300 -- squared units
C.DefenceSuppressWindow = 1.5
C.DefenceSuppressRadiusSqr = 500 * 500
C.ImpactBufferMax    = 48

--[[---------------------------------------------------------------------------
    Water / scrape / misc one-shots.
-----------------------------------------------------------------------------]]
C.WaterByEffect = {
    lvs_hover_water             = "water_small",
    lvs_physics_water           = "water_small",
    lvs_physics_wheelwatersplash = "water_small",
    lvs_physics_water_advanced  = "water_medium",
}

C.ScrapePcf       = "muzzleflash_sparks_variant_6"
-- Continuous smoke cloud for smoke canisters (lvs_defence_smoke). The old
-- m203_smokegrenade was a one-shot puff, throttled so hard it looked like
-- nothing. doi_smoke_artillery is gred-precached, 0 missing materials, and a
-- continuous emitter — right for a canister that keeps re-firing.
C.DefenceSmokePcf = "doi_smoke_artillery"
C.StompDustPcf    = "doi_ceilingDust_large"
C.RotorExplosionPcf = "high_explosive_air_2"

--[[---------------------------------------------------------------------------
    Trails / attached fire.
-----------------------------------------------------------------------------]]
C.TrailMap = {
    lvs_missiletrail   = { pcf = "rockettrail",        offset = Vector(-8, 0, 0) },
    lvs_concussion_trail = { pcf = "grenadetrail",     offset = vector_origin },
    lvs_proton_trail   = { pcf = "weapon_tracers_smoke", offset = vector_origin },
}

C.FireTrailPcf = "rockettrail"

C.EntFirePcf = {
    lvs_carengine_fire    = "gred_enginefire",
    lvs_carfueltank_fire  = "gred_bigflame",
}

C.AmmoRackPcf = "flame_jet"

-- Name of the cvar gated "barrel smoke" toggle (used by the menu).
C.SmokeCvarName = "lvs_gred_fx_barrel_smoke"

LVS_GRED_FX.Config = C
