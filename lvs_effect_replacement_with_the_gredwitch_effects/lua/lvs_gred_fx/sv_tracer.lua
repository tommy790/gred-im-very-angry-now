--[[---------------------------------------------------------------------------
    LVS → Gredwitch FX : server tracer relay (server-side)

    Rendering is delegated to Gredwitch's OWN base. After every mapped LVS
    shot, this module sends gred's own net message (gred_net_createtracer),
    which gred's client base renders with its gred_particle_tracer effect
    (CP0 → CP1 beam) — the exact same path gred's tanks use.

    CP1 IS ALIGNED WITH THE REAL SHOT:

      * after LVS:FireBullet runs (UNCHANGED — damage, ballistics, physics,
        networking and firing mechanics all untouched), we locate the bullet
        LVS just created and read its ACTUAL data: the POST-SPREAD direction
        (LVS applies VectorRand() internally — re-rolling spread here would
        aim the beam somewhere else), exact velocity, exact gravity and the
        ballistics flag,
      * the beam endpoint (CP1) is computed by simulating the flight with
        LVS's exact motion model (NewBullet:DoBulletFlight):
            straight:   pos(t) = Src + Dir * Velocity * t
            ballistic:  pos(t) = Src + Dir * Velocity * t + Gravity * t^2
          (NB: LVS multiplies gravity by t^2 WITHOUT the textbook 0.5
          factor — LVS bullets drop TWICE as fast as real physics. Simulating
          with 0.5*g*t^2, as the old relay did, under-predicted the drop and
          put CP1 too high.),
        marching traces along the predicted arc until it actually hits —
        so the beam lands where the shell will land,
      * purely visual: nothing ever feeds back into LVS,
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

--[[---------------------------------------------------------------------------
    Predict the flight endpoint with LVS's exact motion model.

    Mirrors NewBullet:DoBulletFlight:
      straight:   pos(t) = src + dir * velocity * t
      ballistic:  pos(t) = src + dir * velocity * t + gravity * t^2

    For ballistic shots we march small steps along the predicted arc and
    trace each segment, so the endpoint is where the shell will REALLY hit
    (walls, terrain, vehicles), not where a straight ray gets blocked.
    Straight shots keep the cheap single long trace.

    The returned endpoint only drives the VISUAL beam; LVS never reads it.
-----------------------------------------------------------------------------]]
local function ComputeEndpoint(pos, dir, velocity, ballistic, gravity, filter)
    if not isvector(pos) or not isvector(dir) then return nil end
    if dir:LengthSqr() < 0.01 then return nil end

    local speed = velocity or 2500
    local mask = MASK_SHOT + MASK_WATER

    if not ballistic then
        local tr = util.TraceLine({ start = pos, endpos = pos + dir * 99999, filter = filter, mask = mask })
        return tr.HitPos or (pos + dir * 10000)
    end

    if not isvector(gravity) then
        gravity = physenv.GetGravity() or Vector(0, 0, -600)
    end

    -- Step size: ~60 steps per 20k units of travel, clamped to sane bounds
    -- (fast shells get small steps so the arc march cannot tunnel through
    -- walls: a 25000 u/s shell steps ~420u, a slow 3000 u/s shell ~300u).
    local dt = math.Clamp(20000 / math.max(speed, 1) / 60, 0.01, 0.1)

    -- LVS hard-kills bullets after 5 seconds of flight; never predict
    -- beyond that.
    local maxTime = 5
    local maxSteps = math.floor(maxTime / dt) + 1

    local prev = pos
    local t = 0

    for i = 1, maxSteps do
        t = t + dt
        if t > maxTime then break end

        local cur = pos + dir * speed * t + gravity * (t * t)

        local tr = util.TraceLine({ start = prev, endpos = cur, filter = filter, mask = mask })
        if tr.Hit then
            return tr.HitPos
        end

        prev = cur

        if cur.z < -20000 then break end
    end

    return prev
end

--[[---------------------------------------------------------------------------
    Identify the bullet a FireBullet call just created.

    We snapshot the active-bullet table before the (untouched) original call
    and diff afterwards — the new entry is OUR shot, with LVS's final values:
    post-spread Dir, rounded Velocity, Gravity (set from physenv), Filter,
    EnableBallistics. This removes all guessing/re-rolling on our side.
-----------------------------------------------------------------------------]]
local function FindNewBullet(before, data)
    if not LVS._ActiveBullets then return nil end

    local found

    for index, bullet in pairs(LVS._ActiveBullets) do
        if not before[index] and istable(bullet) then
            -- First new bullet wins by default; prefer the one whose source
            -- position matches this shot (paranoia: nested bullet spawns).
            if not found then
                found = bullet
            end
            if isvector(data.Src) and isvector(bullet.Src)
                and bullet.Src:DistToSqr(data.Src) < 1 then
                return bullet
            end
        end
    end

    return found
end

function LVS_GRED_FX_SV.SendTracer(data, bullet)
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

    -- Prefer the live bullet LVS just created; fall back to the raw FireBullet
    -- data when the bullet could not be identified (defense in depth — the
    -- relay must degrade gracefully, never fail the shot).
    local hasBullet = istable(bullet)

    local pos = (hasBullet and isvector(bullet.Src)) and bullet.Src or data.Src
    if not isvector(pos) then return end

    -- Direction: the bullet's PostSpread direction is authoritative. (The old
    -- relay re-rolled VectorRand() with the same formula LVS uses — same
    -- distribution, DIFFERENT random result: the beam aimed away from every
    -- shot that had spread.)
    local dir = (hasBullet and isvector(bullet.Dir) and bullet.Dir) or (data.Dir or Vector(1, 0, 0))

    local velocity
    if hasBullet and isnumber(bullet.Velocity) then
        velocity = bullet.Velocity
    else
        velocity = data.Velocity
    end

    local ballistic
    if hasBullet then
        ballistic = bullet.EnableBallistics == true
    else
        ballistic = data.EnableBallistics == true
    end

    local gravity
    if hasBullet and bullet.GetGravity then
        gravity = bullet:GetGravity()
    else
        gravity = physenv.GetGravity()
    end

    -- Trace filter: prefer the bullet's own (LVS already resolved the
    -- crosshair filter entities into it); else resolve from the shooter.
    local filter = hasBullet and bullet.Filter or data.Entity
    if IsValid(filter) and filter.GetCrosshairFilterEnts then
        filter = filter:GetCrosshairFilterEnts()
    end

    local endpos = ComputeEndpoint(pos, dir, velocity, ballistic, gravity, filter)
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
        -- Snapshot active bullets so we can identify the one this call
        -- creates (the snapshot/diff is synchronous with the call — no
        -- timer or hook can interleave another bullet in between).
        local before = {}
        if LVS._ActiveBullets then
            for index in pairs(LVS._ActiveBullets) do
                before[index] = true
            end
        end

        -- Run the real LVS bullet logic untouched (damage/ballistics/network).
        LVS_GRED_FX_SV._originalFireBullet(self, data)

        local bullet = FindNewBullet(before, data or {})

        -- Then relay the visual tracer, aligned with the ACTUAL bullet.
        -- Guarded: a relay failure must never break the weapon/LVS call flow.
        local ok = pcall(LVS_GRED_FX_SV.SendTracer, data, bullet)
        if not ok and not LVS_GRED_FX_SV._warned then
            LVS_GRED_FX_SV._warned = true
            ErrorNoHalt("[lvs_gred_fx] server tracer relay failed\n")
        end
    end
end

hook.Add("InitPostEntity", "lvs_gred_fx_server_tracer", TryOverrideFireBullet)
TryOverrideFireBullet()
