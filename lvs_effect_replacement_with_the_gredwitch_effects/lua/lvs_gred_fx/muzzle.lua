--[[---------------------------------------------------------------------------
    LVS → Gredwitch FX : muzzle attachment resolution (client-side)

    RAY-BASED RESOLUTION + SNAPSHOT-TIME COMPENSATION

    Two problems are solved here:

    (1) WRONG ATTACHMENT ID.
        Ranking candidates by plain point distance to the muzzle source
        picked "barrel"-named breech attachments, twin barrels on the wrong
        side, etc. Candidates are now scored against the SHOT RAY
        (perpendicular distance dominant, along-ray projection + "muzzle"
        name bonus as tie-breaks). Priority:

          1. LVS-provided attachment id in the EffectData (validated)
          2. Authoritative LVS muzzle attachment name
             (ent.TurretBallisticsMuzzleAttachment) via LookupAttachment
          3. Named "muzzle"/"barrel" candidates ranked by ray-fit
          4. Static-barrel cache per local muzzle position
          5. Generic nearest attachment (ray-fit ranking)
          6. World-position fallback (caller logs why)

    (2) SNAPSHOT STALENESS ("wrong id when driving fast").
        LVS fires the muzzle effect with a WORLD position snapshotted on the
        SERVER at fire time (lvs_init.lua: SetOrigin(ent:LocalToWorld(...))).
        The client resolves attachments ping/2+interp SECONDS later, against
        bones that have already moved on. At speed that skew is 100+ units —
        larger than multi-barrel spacing — so ANY world-space scoring
        (point distance or ray) misaligns and picks the wrong attachment.

        Fix: we keep a short POSE HISTORY per recently-firing entity and
        estimate the snapshot delay (ping/2 + max(cl_interp,
        cl_interp_ratio/cl_updaterate), 0 in singleplayer). Before scoring,
        the snapshot position AND direction are rigid-transformed from the
        recorded pose at "fire time" into the CURRENT pose — compensating
        translation AND rotation. Scoring then runs against current bones
        with a consistent source/ray. (Bone-level turret animation relative
        to the entity frame is unchanged — it was never the problem.)

        The corrected position is returned as info.correctedPos so callers
        can also place WORLD-space spawns (artillery blast, fallbacks) at
        where the barrel actually is right now instead of where it was on
        the server a snapshot ago.

    Callers that cannot supply a shot direction fall back to point-distance
    behaviour (with compensation still applied).

    The muzzle world position is only ever used to FIND the attachment; the
    actual particle is always spawned with PATTACH_POINT_FOLLOW once an
    attachment has been resolved.

    Performance:
      * attachment enumeration (GetAttachments) is cached per entity and
        invalidated only when the model changes,
      * static barrels (fixed local muzzle positions) are cached per local
        position so the nearest-attachment scan runs at most once per barrel,
      * LookupAttachment for the LVS muzzle name is cheap and cached per
        entity+model as well,
      * pose history is kept ONLY for entities that fired within the last
        second and pruned continuously.
-----------------------------------------------------------------------------]]

if not CLIENT then return end

local cfg = LVS_GRED_FX.Config
local Debug = LVS_GRED_FX.Debug

-- Tolerances (units) — point-distance behaviour (no shot direction known).
local MAX_EFFECTDATA_DIST = 96   -- EffectData attachment must be near the muzzle
local MAX_NAMED_DIST      = 32   -- named candidates without a direction
local MAX_GENERIC_DIST    = 48   -- strict radius for unnamed models

-- Tolerances (units) — ray-fit behaviour (bullet direction known).
local MAX_EFFECTDATA_PERP = 64   -- EffectData id: loose ray sanity check
local MAX_RAY_PERP        = 40   -- named/generic candidates: max perpendicular
                                 -- distance from the shot ray
local RAY_ALONG_MIN       = -160 -- how far BEHIND the muzzle source a candidate
                                 -- may project (long barrels, breech-side tips)
local RAY_ALONG_MAX       = 48   -- how far ahead of the source it may project

-- Score shaping: perpendicular fit dominates everything; along-ray closeness
-- to the muzzle tip only breaks near-ties, and "muzzle" beats "barrel" on an
-- exact tie.
local ALONG_TIEBREAK      = 0.1
local MUZZLE_NAME_BONUS   = 2

-- Local-space quantization for the static-barrel cache.
local LOCAL_CELL = 8

-- Snapshot-compensation tuning.
local POSE_HISTORY_TIME = 1.5  -- seconds of pose history kept per entity
local TRACK_IDLE_TIME   = 1.0  -- stop tracking this long after last resolve
local MAX_SNAPSHOT_DELAY = 0.5 -- sanity clamp for the estimated delay

local function isMuzzleName(name)
    if not isstring(name) then return false end
    local lower = string.lower(name)
    return string.find(lower, "muzzle", 1, true) ~= nil
        or string.find(lower, "barrel", 1, true) ~= nil
end

--[[---------------------------------------------------------------------------
    Per-entity attachment cache. Invalidated when the model changes so that
    toolgun model swaps can never leave stale ids behind.
-----------------------------------------------------------------------------]]
local function GetCache(ent)
    local model = ent:GetModel()

    local cache = ent._lvsGredMuzzleCache
    if cache and cache.model == model then return cache end

    local atts = nil
    if ent.GetAttachments then
        local ok, res = pcall(ent.GetAttachments, ent)
        if ok and istable(res) then atts = res end
    end

    local named = {}
    if atts then
        for i = 1, #atts do
            local id = atts[i] and atts[i].id
            local name = atts[i] and atts[i].name
            if id and id > 0 and isMuzzleName(name) then
                named[#named + 1] = id
            end
        end
    end

    cache = {
        model  = model,
        atts   = atts,
        named  = named,
        byLocal = {},  -- quantized local pos → attachment id (static barrels)
        lvsNameId = nil, -- cached id for ent.TurretBallisticsMuzzleAttachment
        lvsName  = nil,
    }

    ent._lvsGredMuzzleCache = cache
    return cache
end

local function localKey(v)
    if not isvector(v) then return nil end
    return math.floor(v.x / LOCAL_CELL + 0.5)
        .. ","
        .. math.floor(v.y / LOCAL_CELL + 0.5)
        .. ","
        .. math.floor(v.z / LOCAL_CELL + 0.5)
end

-- Get world position (and name) of an attachment; returns nil on any failure.
function LVS_GRED_FX.GetAttachmentData(ent, attID)
    if not IsValid(ent) or not ent.GetAttachment then return nil end
    if not attID or attID <= 0 then return nil end

    if ent.SetupBones then
        pcall(ent.SetupBones, ent)
    end

    local ok, att = pcall(ent.GetAttachment, ent, attID)
    if not ok or not att or not att.Pos or not isvector(att.Pos) then
        return nil
    end

    return att
end

function LVS_GRED_FX.ValidAttachment(ent, attID)
    return LVS_GRED_FX.GetAttachmentData(ent, attID) ~= nil
end

function LVS_GRED_FX.AttachmentName(ent, attID)
    local att = LVS_GRED_FX.GetAttachmentData(ent, attID)
    if not att then return "?" end
    return att.Name or "?"
end

-- Resolve the vehicle root for an entity (gunner pods → their base vehicle).
function LVS_GRED_FX.VehicleRoot(ent)
    if not IsValid(ent) then return nil end
    if ent.GetVehicle then
        local base = ent:GetVehicle()
        if IsValid(base) then return base end
    end
    return ent
end

local function lookupLvsMuzzleId(ent, cache)
    local name = ent.TurretBallisticsMuzzleAttachment

    if not isstring(name) or name == "" then
        cache.lvsName, cache.lvsNameId = nil, nil
        return 0
    end

    if cache.lvsName == name then
        return cache.lvsNameId or 0
    end

    cache.lvsName = name

    if not ent.LookupAttachment then
        cache.lvsNameId = 0
        return 0
    end

    local ok, id = pcall(ent.LookupAttachment, ent, name)
    cache.lvsNameId = (ok and id and id > 0) and id or 0
    return cache.lvsNameId
end

--[[---------------------------------------------------------------------------
    Snapshot-time compensation.

    Per-entity pose history (entity origin + angles sampled every frame for
    entities that fired recently) + a snapshot-delay estimate. Used to
    rigid-transform the server-fire-time snapshot into the current frame
    before any scoring happens.
-----------------------------------------------------------------------------]]
local POSE_HISTORY = setmetatable({}, { __mode = "k" }) -- ent → { {t,pos,ang}, ... }
local TRACKED      = setmetatable({}, { __mode = "k" }) -- ent → last resolve time

-- Estimated delay between "the server fired this shot" and "what the client
-- is rendering right now": one-way ping + the interpolation window the
-- rendered entity pose is lagging behind the server clock.
local function EstimateSnapshotDelay()
    if game.SinglePlayer() then return 0 end

    local ply = LocalPlayer()
    local ping = IsValid(ply) and ply:Ping() or 0

    local function cvarNum(name, fallback)
        local cv = GetConVar(name)
        return cv and cv:GetFloat() or fallback
    end

    local interp     = cvarNum("cl_interp", 0.1)
    local ratio      = cvarNum("cl_interp_ratio", 2)
    local updaterate = math.max(cvarNum("cl_updaterate", 20), 1)

    local lerp = math.max(interp, ratio / updaterate)

    return math.Clamp(ping / 2000 + lerp, 0, MAX_SNAPSHOT_DELAY)
end

local function RecordPose(ent, now)
    local hist = POSE_HISTORY[ent]
    if not hist then
        hist = {}
        POSE_HISTORY[ent] = hist
    end

    local n = #hist
    if n > 0 and hist[n].t >= now then return end -- already recorded this frame

    hist[n + 1] = { t = now, pos = ent:GetPos(), ang = ent:GetAngles() }

    while hist[1] and now - hist[1].t > POSE_HISTORY_TIME do
        table.remove(hist, 1)
    end
end

-- Keep pose history rolling only for entities that resolved recently.
timer.Create("lvs_gred_fx_pose_track", 0, 0, function()
    local now = CurTime()

    for ent, lastUse in pairs(TRACKED) do
        if not IsValid(ent) then
            TRACKED[ent] = nil
            POSE_HISTORY[ent] = nil
        elseif now - lastUse > TRACK_IDLE_TIME then
            TRACKED[ent] = nil
            POSE_HISTORY[ent] = nil
        else
            RecordPose(ent, now)
        end
    end
end)

-- Recorded pose closest to (now - ago); nil when we have no history at all.
local function PoseAt(ent, ago)
    local hist = POSE_HISTORY[ent]
    if not hist or #hist == 0 then return nil end

    local target = CurTime() - ago
    local best = hist[1]
    local bestDelta = math.abs(best.t - target)

    for i = 2, #hist do
        local d = math.abs(hist[i].t - target)
        if d < bestDelta then
            best, bestDelta = hist[i], d
        end
    end

    return best
end

-- dir_rotated ≈ (angTo * angFrom^-1) * dir, expressed via the world↔local
-- helpers (rotating a vector by frame inverses; the position part is unused).
local function RotateDirBetween(dir, angFrom, angTo)
    local l = WorldToLocal(dir, angle_zero, vector_origin, angFrom)
    return LocalToWorld(l, angle_zero, vector_origin, angTo)
end

-- Rigid-transform a server-fire-time snapshot position/direction into the
-- entity's CURRENT frame. Returns correctedPos, correctedDir, compensated.
local function CompensateSnapshot(ent, muzzlePos, dir)
    local ago = EstimateSnapshotDelay()
    if ago <= 0.005 then return muzzlePos, dir, false end

    local pose = PoseAt(ent, ago)
    if not pose then return muzzlePos, dir, false end

    -- History frame is the current frame: no motion to compensate.
    if CurTime() - pose.t <= 0.001 then return muzzlePos, dir, false end

    -- Snapshot → entity-local (in the past frame) → back to world (in the
    -- current frame): exact rigid compensation for translation + rotation.
    local pastLocal = WorldToLocal(muzzlePos, angle_zero, pose.pos, pose.ang)
    local cpos = LocalToWorld(pastLocal, angle_zero, ent:GetPos(), ent:GetAngles())

    local cdir = dir
    if isvector(dir) then
        cdir = RotateDirBetween(dir, pose.ang, ent:GetAngles())
    end

    return cpos, cdir, true
end

-- Public helper for callers that need the compensated world position of a
-- snapshot muzzle source (world-space spawns when no attachment resolved).
function LVS_GRED_FX.CompensateMuzzleSnapshot(ent, muzzlePos, dir)
    if not IsValid(ent) or not isvector(muzzlePos) then
        return muzzlePos, dir, false
    end
    return CompensateSnapshot(ent, muzzlePos, dir)
end

--[[---------------------------------------------------------------------------
    Shot-ray helpers.
-----------------------------------------------------------------------------]]
local function normalizeDir(shotDir)
    if not isvector(shotDir) then return nil end
    if shotDir:LengthSqr() < 0.25 then return nil end -- zero-ish normal: treat
                                                      -- as "no direction"
    return shotDir:GetNormalized()
end

-- Score a candidate attachment against the shot ray.
-- Returns nil when the candidate is unusable, otherwise:
--   score  — lower is better
--   perp   — perpendicular distance to the ray (point distance without dir)
--   along  — signed projection on the ray (nil without dir)
local function scoreCandidate(attPos, muzzlePos, dir, perpLimit, alongMin, alongMax)
    local to = attPos - muzzlePos

    if not dir then
        local d = to:Length()
        if d > perpLimit then return nil end
        return d, d, nil
    end

    local along = to:Dot(dir)
    local perpSqr = to:LengthSqr() - along * along
    if perpSqr < 0 then perpSqr = 0 end
    local perp = math.sqrt(perpSqr)

    if perp > perpLimit then return nil end
    if along < alongMin or along > alongMax then return nil end

    return perp + math.abs(along) * ALONG_TIEBREAK, perp, along
end

--[[---------------------------------------------------------------------------
    ResolveMuzzleAttachment( ent, muzzlePos, effectDataAtt, shotDir )

      ent          — entity owning the attachments (pass the VEHICLE ROOT)
      muzzlePos    — world muzzle source position; SERVER SNAPSHOT from the
                     fire moment (it is rigid-compensated internally)
      effectDataAtt— attachment id carried in the EffectData (0 if none)
      shotDir      — optional bullet direction (EffectData normal), also
                     snapshot-time; enables ray-fit scoring

    Returns: attachmentID, info
      info = {
        method       = "effectdata" | "lvs_muzzle_name" | "named_ray" |
                       "named_nearest" | "local_cache" | "nearest_ray" |
                       "nearest" | "none",
        dist         = resolution distance (or nil),
        name         = resolved attachment name (or nil),
        correctedPos = muzzlePos rigid-compensated into the current frame
                       (use for world-space spawns, NOT for attachment math),
        correctedDir = compensated direction, compensated = true/false,
      }

    attachmentID == 0 means "no usable attachment" — the caller must use the
    world-position fallback (with info.correctedPos, not raw muzzlePos!).
-----------------------------------------------------------------------------]]
function LVS_GRED_FX.ResolveMuzzleAttachment(ent, muzzlePos, effectDataAtt, shotDir)
    if not IsValid(ent) then return 0, { method = "none", reason = "invalid entity" } end
    if not isvector(muzzlePos) then return 0, { method = "none", reason = "invalid muzzle position" } end

    local dir = normalizeDir(shotDir)

    -- Keep pose history rolling for this entity, then move the stale
    -- snapshot source/direction into the current frame so scoring compares
    -- like-with-like. This is the "wrong id when driving fast" fix.
    TRACKED[ent] = CurTime()
    RecordPose(ent, CurTime())

    local cpos, cdir, compensated = CompensateSnapshot(ent, muzzlePos, dir)

    local function pack(id, info)
        if istable(info) then
            info.correctedPos = cpos
            info.correctedDir = cdir
            info.compensated = compensated
        end
        return id, info
    end

    -- Debug: blue box = raw (stale) snapshot search area; red line = stale
    -- ray; orange line = compensated ray actually used for scoring.
    if cfg.DebugEnabled() and debugoverlay then
        if debugoverlay.Box then
            debugoverlay.Box(muzzlePos, Vector(MAX_NAMED_DIST, MAX_NAMED_DIST, MAX_NAMED_DIST), 0.5, Color(0, 100, 255, 60))
        end
        if debugoverlay.Line then
            if dir then
                debugoverlay.Line(muzzlePos, muzzlePos + dir * 256, 0.5, Color(255, 60, 30), true)
            end
            if cdir then
                debugoverlay.Line(cpos, cpos + cdir * 256, 0.5, Color(255, 180, 0), true)
            end
        end
        if compensated and LVS_GRED_FX.DebugOnce then
            LVS_GRED_FX.DebugOnce("comp:" .. tostring(ent),
                "snapshot compensated by", string.format("%.1f", math.sqrt(cpos:DistToSqr(muzzlePos))),
                "units (est. delay)")
        end
    end

    local cache = GetCache(ent)

    -- 1) EffectData attachment id. LVS sometimes provides a muzzle attachment
    --    id, but it can be a stale/base-model id (e.g. lvs_2s38 sends id 1 —
    --    39 units away, empty name — which is a hull/root attachment, not the
    --    barrel). Validate it like the other paths: real name, close to the
    --    (compensated) source, and on the ray when the direction is known.
    if effectDataAtt and effectDataAtt > 0 then
        local att = LVS_GRED_FX.GetAttachmentData(ent, effectDataAtt)
        if att and att.Name and att.Name ~= "" then
            local distSqr = att.Pos:DistToSqr(cpos)
            local acceptable = distSqr <= MAX_EFFECTDATA_DIST * MAX_EFFECTDATA_DIST

            if acceptable and cdir then
                local scored = scoreCandidate(att.Pos, cpos, cdir,
                    MAX_EFFECTDATA_PERP, -MAX_EFFECTDATA_DIST, MAX_EFFECTDATA_DIST)
                acceptable = scored ~= nil
            end

            if acceptable then
                return pack(effectDataAtt, {
                    method = "effectdata",
                    dist = math.sqrt(distSqr),
                    name = att.Name,
                })
            end
        end
    end

    -- 2) Authoritative LVS muzzle attachment name on the entity.
    local lvsId = lookupLvsMuzzleId(ent, cache)
    if lvsId > 0 then
        local att = LVS_GRED_FX.GetAttachmentData(ent, lvsId)
        -- Require a real name AND ray/point fit: an unnamed or off-ray
        -- attachment is not the actual barrel muzzle (e.g. BMD-4 "muzzle" id
        -- 18u away).
        if att and att.Name and att.Name ~= "" then
            local scored, perp = scoreCandidate(att.Pos, cpos, cdir,
                cdir and MAX_RAY_PERP or MAX_NAMED_DIST, RAY_ALONG_MIN, RAY_ALONG_MAX)
            if scored then
                return pack(lvsId, {
                    method = "lvs_muzzle_name",
                    dist = perp,
                    name = att.Name,
                })
            end
        end
    end

    -- 3) Named muzzle candidates ranked by ray-fit (or by point distance
    --    when no direction is known). Deterministic on multi-barrel
    --    vehicles: each shot's (compensated) ray lies on ITS barrel only.
    if cache.named and #cache.named > 0 then
        local limit = cdir and MAX_RAY_PERP or MAX_NAMED_DIST
        local best, bestScore, bestName, bestPerp = 0, nil, nil, nil
        local dbg = cfg.DebugEnabled() and {} or nil

        for i = 1, #cache.named do
            local id = cache.named[i]
            local att = LVS_GRED_FX.GetAttachmentData(ent, id)
            if att and att.Name and att.Name ~= "" then
                local score, perp, along = scoreCandidate(att.Pos, cpos, cdir,
                    limit, RAY_ALONG_MIN, RAY_ALONG_MAX)
                if score then
                    if string.find(string.lower(att.Name), "muzzle", 1, true) then
                        score = score - MUZZLE_NAME_BONUS
                    end
                    if dbg then
                        dbg[#dbg + 1] = {
                            id = id, name = att.Name,
                            score = score, perp = perp, along = along,
                        }
                    end
                    if not bestScore or score < bestScore then
                        best, bestScore, bestName, bestPerp = id, score, att.Name, perp
                    end
                end
            end
        end

        if best > 0 then
            if dbg then
                table.sort(dbg, function(a, b) return a.score < b.score end)
                for i = 1, math.min(#dbg, 4) do
                    local c = dbg[i]
                    Debug("muzzle cand:", c.name, "id:", c.id,
                        string.format("score=%.1f perp=%.1f along=%s",
                            c.score, c.perp or -1,
                            c.along and string.format("%.1f", c.along) or "n/a"))
                end
            end
            return pack(best, {
                method = cdir and "named_ray" or "named_nearest",
                dist = bestPerp,
                name = bestName,
            })
        end
    end

    -- 4) Static-barrel cache: fixed local muzzle positions resolve once.
    --    The cache stores the resolved id AND the exact local position. A
    --    cache hit is only accepted when the CURRENT (compensated) muzzle
    --    local position is within a few units of the cached one — this
    --    prevents two barrels whose muzzles share an 8-unit cell (e.g.
    --    BMD-4M autocannon + main cannon) from cross-returning each other's
    --    attachment id.
    if ent.WorldToLocal then
        local localPos = ent:WorldToLocal(cpos)
        local key = localKey(localPos)
        if key then
            local cached = cache.byLocal[key]
            if cached and cached.id then
                if LVS_GRED_FX.ValidAttachment(ent, cached.id) and cached.pos and isvector(cached.pos) then
                    local drift = localPos:DistToSqr(cached.pos)
                    if drift <= 4 * 4 then -- within 4 units of the cached barrel
                        return pack(cached.id, { method = "local_cache", dist = nil, name = LVS_GRED_FX.AttachmentName(ent, cached.id) })
                    end
                end
                cache.byLocal[key] = nil
            end
        end
    end

    -- 5) Generic nearest attachment (ray-fit when the direction is known,
    --    strict point radius otherwise) for models without named muzzles.
    if cache.atts and #cache.atts > 0 then
        local limit = cdir and MAX_RAY_PERP or MAX_GENERIC_DIST
        local best, bestScore, bestName, bestPerp = 0, nil, nil, nil

        for i = 1, #cache.atts do
            local id = cache.atts[i] and cache.atts[i].id
            if id and id > 0 then
                local att = LVS_GRED_FX.GetAttachmentData(ent, id)
                if att then
                    local score, perp = scoreCandidate(att.Pos, cpos, cdir,
                        limit, RAY_ALONG_MIN, RAY_ALONG_MAX)
                    if score and (not bestScore or score < bestScore) then
                        best, bestScore, bestName, bestPerp = id, score, att.Name or "", perp
                    end
                end
            end
        end

        if best > 0 then
            if ent.WorldToLocal then
                local localPos = ent:WorldToLocal(cpos)
                local key = localKey(localPos)
                if key then
                    cache.byLocal[key] = { id = best, pos = localPos }
                end
            end
            return pack(best, {
                method = cdir and "nearest_ray" or "nearest",
                dist = bestPerp,
                name = bestName,
            })
        end
    end

    return pack(0, { method = "none", reason = "no attachment near muzzle position" })
end
