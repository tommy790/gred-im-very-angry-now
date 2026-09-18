--[[---------------------------------------------------------------------------
    LVS → Gredwitch FX : effect list.

    Exactly these LVS effect names are overridden by the Gredwitch particle
    replacements. Everything else — including flamestream, exhaust, dust and
    the haubitze trail — is left to LVS natively.

    Each name must match util.Effect("lvs_*") exactly (lowercase).
-----------------------------------------------------------------------------]]

return {
    -- Impacts
    "lvs_bullet_impact",
    "lvs_bullet_impact_ap",
    "lvs_bullet_impact_explosive",
    "lvs_laser_impact",
    "lvs_shield_impact",

    -- Explosions
    "lvs_concussion_explosion",
    "lvs_defence_explosion",
    "lvs_explosion",
    "lvs_explosion_bomb",
    "lvs_explosion_nodebris",
    "lvs_explosion_small",
    "lvs_laser_explosion",
    "lvs_laser_explosion_aat",
    "lvs_proton_explosion",
    "lvs_trailer_explosion",

    -- Muzzle flashes
    "lvs_haubitze_muzzle",
    "lvs_muzzle",
    "lvs_muzzle_colorable",
    "lvs_pulserifle_muzzle",

    -- Fire / flame (flamestream is handled natively by LVS)
    "lvs_ammorack_fire",
    "lvs_carengine_fire",
    "lvs_carfueltank_fire",
    "lvs_firetrail",

    -- Trails (entity-attached)
    "lvs_concussion_trail",
    "lvs_missiletrail",
    "lvs_proton_trail",

    -- Smoke / exhaust
    "lvs_defence_smoke",

    -- Physics (scrape, water, etc.)
    "lvs_hover_water",
    "lvs_physics_scrape",
    "lvs_physics_trackscraping",
    "lvs_physics_turretscraping",
    "lvs_physics_water",
    "lvs_physics_water_advanced",
    "lvs_physics_wheelwatersplash",

    -- Misc
    "lvs_laser_charge",
    "lvs_rotor_destruction",
    "lvs_tire_blow",
    "lvs_walker_stomp",

    -- Tracers — replaced with Gredwitch beam particles. The original LVS
    -- tracer Think runs silently and still fires lvs_bullet_impact_ap at the
    -- exact LVS timing (handled by the override wrapper + bridge).
    "lvs_tracer_autocannon",
    "lvs_tracer_cannon",
    "lvs_tracer_green",
    "lvs_tracer_missile",
    "lvs_tracer_orange",
    "lvs_tracer_proton",
    "lvs_tracer_white",
    "lvs_tracer_yellow",
    "lvs_tracer_yellow_small",
    "lvs_pulserifle_tracer",
    "lvs_pulserifle_tracer_large",
    "lvs_laser_blue",
    "lvs_laser_blue_long",
    "lvs_laser_blue_short",
    "lvs_laser_green",
    "lvs_laser_green_short",
    "lvs_laser_red",
    "lvs_laser_red_aat",
    "lvs_laser_red_short",
}
