--[[---------------------------------------------------------------------------
    LVS → Gredwitch FX : server tracer relay (server-side)

    THE PROVEN TRACER MECHANISM (restored from the original addon):

    Rendering is delegated to Gredwitch's OWN base. After every mapped LVS
    shot, this module sends gred's own net message (gred_net_createtracer),
    which gred's client base renders with its own battle-tested
    gred_particle_tracer effect — the exact same path gred's tanks use. The
    addon itself never creates a tracer particle system, so there is nothing
    here that can fail to render.

      * LVS:FireBullet is called UNCHANGED first — damage, ballistics,
        projectile physics, networking and firing mechanics are untouched,
      * only then, for mapped tracer names, the gred net message is sent,
      * the beam endpoint is computed with a lightweight trace (straight line
        for non-ballistic shots, a short arc simulation for ballistic ones)
        purely for the visual; it never feeds back into LVS,
      * the whole relay is pcall-guarded so a failure can never break LVS
        firing or the weapon that called it.

    Clients with this addon suppress the original LVS tracer visual (see
    tracer.lua), so the gred beam is the single tracer. Clients without this
    addon but with gred base will also render the beam (gred owns the channel).
-----------------------------------------------------------------------------]]

if not SERVER then return end

LVS_GRED_FX_SV = LVS_GRED_FX_SV or {}

-- Mirror of the client config mapping (the client config is client-only).
local TRACER_MAP = {
    lvs_tracer_yellow_small     = { "yellow", "12mm" },
    lvs_pulserifle_tracer       = { "white",  "7mm"  },
    lvs_pulserifle_tracer_large = { "white",  "12mm" },
    lvs_tracer_orange           = { "yellow", "20mm" },
    lvs_tracer_green            = { "green",  "20mm" },
    lvs_tracer_yellow           = { "yellow", "20mm" },
    lvs_tracer_white            = { "white",  "20mm" },
    lvs_tracer_autocannon       = { "white",  "30mm" },
    lvs_tracer_missile          = { "yellow", "30mm" },
    lvs_tracer_cannon           = { "white",  "40mm" },
    lvs_tracer_proton           = { "white",  "40mm" },
    lvs_laser_blue              = { "white",  "30mm" },
    lvs_laser_blue_long         = { "white",  "30mm" },
    lvs_laser_blue_short        = { "white",  "20mm" },
    lvs_laser_green             = { "green",  "30mm" },
    lvs_laser_green_short       = { "green",  "20mm" },
    lvs_laser_red               = { "red",    "30mm" },
    lvs_laser_red_short         = { "red",    "20mm" },
    lvs_laser_red_aat           = { "red",    "40mm" },
}

-- gred caliber index (1..5) and tracer color index (1..4).
local CAL_TABLE = {
    ["wac_base_7mm"] = 1, ["wac_base_12mm"] = 2, ["wac_base_20mm"] = 3,
    ["wac_base_30mm"] = 4, ["wac_base_40mm"] = 5,
}
local COL_TABLE = {
    ["red"] = 1, ["green"] = 2, ["white"] = 3, ["yellow"] = 4,
}

-- Match LVS's own spread application so the beam lines up with the shot.
local function ApplySpread(dir, spreadVec)
    if not spreadVec or spreadVec:LengthSqr() <= 0 then return dir end
    return (dir + VectorRand() * spreadVec * 0.5):GetNormalized()
end

-- Lightweight endpoint for the tracer visual (straight trace for non-
-- ballistic shots, short arc simulation for ballistic ones so the beam lands
-- where the shell actually falls).
local function ComputeEndpoint(pos, dir, velocity, enableBallistics, filter)
    if not isvector(pos) or not isvector(dir) then return nil end

    local mask = MASK_SHOT + MASK_WATER
    local speed = velocity or 2500

    if not enableBallistics then
        local tr = util.TraceLine({ start = pos, endpos = pos + dir * 99999, filter = filter, mask = mask })
        return tr.HitPos or (pos + dir * 10000)
    end

    local grav = physenv.GetGravity() or Vector(0, 0, -600)
    local t, dt = 0, math.min(99999 / speed / 24, 0.25)
    local prev = pos

    for i = 1, 48 do
        t = t + dt
        local cur = pos + dir * speed * t + grav * (t * t * 0.5)
        local tr = util.TraceLine({ start = prev, endpos = cur, filter = filter, mask = mask })
        if tr.Hit then return tr.HitPos end
        prev = cur
        if cur.z < -20000 then break end
    end

    return prev
end

function LVS_GRED_FX_SV.SendTracer(data)
    if not istable(data) then return end
    if not isstring(data.TracerName) then return end

    local mapping = TRACER_MAP[data.TracerName]
    if not mapping then return end

    -- Gredwitch base must be present on the server (it registered the
    -- gred_net_createtracer channel).
    if not gred then return end

    local color, caliber = mapping[1], mapping[2]
    local calID, colID = CAL_TABLE["wac_base_" .. caliber], COL_TABLE[color]
    if not calID or not colID then return end

    local pos = data.Src
    if not isvector(pos) then return end

    local dir = ApplySpread(data.Dir or Vector(1, 0, 0), data.Spread)

    local filter = data.Entity
    if IsValid(filter) and filter.GetCrosshairFilterEnts then
        filter = filter:GetCrosshairFilterEnts()
    end

    local endpos = ComputeEndpoint(pos, dir, data.Velocity, data.EnableBallistics == true, filter)
    if not isvector(endpos) then return end

    net.Start("gred_net_createtracer")
        net.WriteVector(pos)
        net.WriteUInt(calID, 3)
        net.WriteUInt(colID, 3)
        net.WriteVector(endpos)

    -- Only send to clients who can actually see the shot (same as LVS's own
    -- bullet networking) — net.Broadcast would push every tracer to every
    -- player, wasting bandwidth with many vehicles firing in multiplayer.
    net.SendPVS(pos)
end

local function TryOverrideFireBullet()
    if not LVS or not LVS.FireBullet then
        timer.Simple(0.5, TryOverrideFireBullet)
        return
    end

    if LVS_GRED_FX_SV._patched then return end
    LVS_GRED_FX_SV._patched = true

    LVS_GRED_FX_SV._originalFireBullet = LVS.FireBullet

    function LVS:FireBullet(data)
        -- Run the real LVS bullet logic untouched (damage/ballistics/network).
        LVS_GRED_FX_SV._originalFireBullet(self, data)

        -- Then relay the visual tracer. Guarded: a relay failure must never
        -- break the weapon/LVS call flow.
        local ok = pcall(LVS_GRED_FX_SV.SendTracer, data)
        if not ok and not LVS_GRED_FX_SV._warned then
            LVS_GRED_FX_SV._warned = true
            ErrorNoHalt("[lvs_gred_fx] server tracer relay failed\n")
        end
    end
end

hook.Add("InitPostEntity", "lvs_gred_fx_server_tracer", TryOverrideFireBullet)
TryOverrideFireBullet()
