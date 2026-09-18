--[[---------------------------------------------------------------------------
    LVS → Gredwitch FX : muzzle attachment resolution (client-side)

    RAY-BASED RESOLUTION (rework)

    The old resolver ranked candidate attachments by plain point-to-point
    distance to the muzzle source. On real vehicles that picks the wrong
    attachment surprisingly often:

      * attachments named "barrel" usually sit at the barrel ROOT (breech) —
        on twin/quad mounts that root can be closer to the WRONG barrel's
        muzzle source than to its own, so flashes and smoke glued to the
        wrong (often hidden) attachment,
      * hull/turret attachments near the shot line won distance ties,
      * on long-barrelled guns, named attachments are spread along the whole
        barrel axis, where point distance is meaningless.

    The reworked resolver scores candidates against the SHOT RAY: origin =
    muzzle source, direction = the bullet normal LVS passes in the EffectData
    (callers now thread it through). The firing barrel's muzzle attachment
    lies ON that ray, close to its origin; wrong attachments sit sideways
    (large perpendicular distance) or far behind (breech). Priority order:

      1. LVS-provided attachment id in the EffectData (validated: named,
         near the source, and — when the direction is known — on the ray)
      2. Authoritative LVS muzzle attachment name
         (ent.TurretBallisticsMuzzleAttachment, e.g. "muzzle") via
         ent:LookupAttachment(name), validated against the ray
      3. Attachments whose name contains "muzzle"/"barrel", ranked by
         ray-fit: perpendicular distance first (the firing barrel's tip is
         ON the ray), then closeness to the muzzle tip along the ray, then a
         small "muzzle"-name bonus over "barrel"-name matches. The per-shot
         muzzle position still deterministically selects the correct barrel
         on multi-barrel / alternating-barrel weapons.
      4. Static-barrel cache per local muzzle position (resolves once per
         physical barrel)
      5. Generic nearest attachment (ray-fit ranking when the direction is
         known; strict radius otherwise) for models with unnamed muzzles
      6. World-position fallback (only when nothing valid was found — the
         caller logs why)

    Callers that cannot supply a shot direction fall back to the old
    point-distance behaviour, so they are never worse off than before.

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
      * ray scoring is a handful of dots/lengths per candidate — cheap.
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
      muzzlePos    — world muzzle source position (bullet.Src)
      effectDataAtt— attachment id carried in the EffectData (0 if none)
      shotDir      — optional bullet direction (EffectData normal); enables
                     ray-fit scoring and dramatically reduces wrong-id picks

    Returns: attachmentID, info
      info = {
        method = "effectdata" | "lvs_muzzle_name" | "named_ray" |
                "named_nearest" | "local_cache" | "nearest_ray" |
                "nearest" | "none",
        dist   = resolution distance (or nil),
        name   = resolved attachment name (or nil),
      }

    attachmentID == 0 means "no usable attachment" — the caller must use the
    world-position fallback.
-----------------------------------------------------------------------------]]
function LVS_GRED_FX.ResolveMuzzleAttachment(ent, muzzlePos, effectDataAtt, shotDir)
    if not IsValid(ent) then return 0, { method = "none", reason = "invalid entity" } end
    if not isvector(muzzlePos) then return 0, { method = "none", reason = "invalid muzzle position" } end

    local dir = normalizeDir(shotDir)

    -- Debug: blue box = point-search area around the muzzle source; orange
    -- line = the shot ray candidates are scored against.
    if cfg.DebugEnabled() and debugoverlay then
        if debugoverlay.Box then
            debugoverlay.Box(muzzlePos, Vector(MAX_NAMED_DIST, MAX_NAMED_DIST, MAX_NAMED_DIST), 0.5, Color(0, 100, 255, 60))
        end
        if dir and debugoverlay.Line then
            debugoverlay.Line(muzzlePos, muzzlePos + dir * 256, 0.5, Color(255, 180, 0), true)
        end
    end

    local cache = GetCache(ent)

    -- 1) EffectData attachment id. LVS sometimes provides a muzzle attachment
    --    id, but it can be a stale/base-model id (e.g. lvs_2s38 sends id 1 —
    --    39 units away, empty name — which is a hull/root attachment, not the
    --    barrel). Validate it like the other paths: real name, close to the
    --    source, and on the shot ray when the direction is known.
    if effectDataAtt and effectDataAtt > 0 then
        local att = LVS_GRED_FX.GetAttachmentData(ent, effectDataAtt)
        if att and att.Name and att.Name ~= "" then
            local distSqr = att.Pos:DistToSqr(muzzlePos)
            local acceptable = distSqr <= MAX_EFFECTDATA_DIST * MAX_EFFECTDATA_DIST

            if acceptable and dir then
                local scored = scoreCandidate(att.Pos, muzzlePos, dir,
                    MAX_EFFECTDATA_PERP, -MAX_EFFECTDATA_DIST, MAX_EFFECTDATA_DIST)
                acceptable = scored ~= nil
            end

            if acceptable then
                return effectDataAtt, {
                    method = "effectdata",
                    dist = math.sqrt(distSqr),
                    name = att.Name,
                }
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
            local scored, perp = scoreCandidate(att.Pos, muzzlePos, dir,
                dir and MAX_RAY_PERP or MAX_NAMED_DIST, RAY_ALONG_MIN, RAY_ALONG_MAX)
            if scored then
                return lvsId, {
                    method = "lvs_muzzle_name",
                    dist = perp,
                    name = att.Name,
                }
            end
        end
    end

    -- 3) Named muzzle candidates ranked by ray-fit (or by point distance
    --    when no direction is known). Deterministic on multi-barrel
    --    vehicles: each shot's ray lies on ITS barrel only.
    if cache.named and #cache.named > 0 then
        local limit = dir and MAX_RAY_PERP or MAX_NAMED_DIST
        local best, bestScore, bestName, bestPerp = 0, nil, nil, nil
        local dbg = cfg.DebugEnabled() and {} or nil

        for i = 1, #cache.named do
            local id = cache.named[i]
            local att = LVS_GRED_FX.GetAttachmentData(ent, id)
            if att and att.Name and att.Name ~= "" then
                local score, perp, along = scoreCandidate(att.Pos, muzzlePos, dir,
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
            return best, {
                method = dir and "named_ray" or "named_nearest",
                dist = bestPerp,
                name = bestName,
            }
        end
    end

    -- 4) Static-barrel cache: fixed local muzzle positions resolve once.
    --    The cache stores the resolved id AND the exact local position. A
    --    cache hit is only accepted when the CURRENT muzzle local position is
    --    within a few units of the cached one — this prevents two barrels
    --    whose muzzles share an 8-unit cell (e.g. BMD-4M autocannon + main
    --    cannon) from cross-returning each other's attachment id.
    if ent.WorldToLocal then
        local localPos = ent:WorldToLocal(muzzlePos)
        local key = localKey(localPos)
        if key then
            local cached = cache.byLocal[key]
            if cached and cached.id then
                if LVS_GRED_FX.ValidAttachment(ent, cached.id) and cached.pos and isvector(cached.pos) then
                    local drift = localPos:DistToSqr(cached.pos)
                    if drift <= 4 * 4 then -- within 4 units of the cached barrel
                        return cached.id, { method = "local_cache", dist = nil, name = LVS_GRED_FX.AttachmentName(ent, cached.id) }
                    end
                end
                cache.byLocal[key] = nil
            end
        end
    end

    -- 5) Generic nearest attachment (ray-fit when the direction is known,
    --    strict point radius otherwise) for models without named muzzles.
    if cache.atts and #cache.atts > 0 then
        local limit = dir and MAX_RAY_PERP or MAX_GENERIC_DIST
        local best, bestScore, bestName, bestPerp = 0, nil, nil, nil

        for i = 1, #cache.atts do
            local id = cache.atts[i] and cache.atts[i].id
            if id and id > 0 then
                local att = LVS_GRED_FX.GetAttachmentData(ent, id)
                if att then
                    local score, perp = scoreCandidate(att.Pos, muzzlePos, dir,
                        limit, RAY_ALONG_MIN, RAY_ALONG_MAX)
                    if score and (not bestScore or score < bestScore) then
                        best, bestScore, bestName, bestPerp = id, score, att.Name or "", perp
                    end
                end
            end
        end

        if best > 0 then
            if ent.WorldToLocal then
                local localPos = ent:WorldToLocal(muzzlePos)
                local key = localKey(localPos)
                if key then
                    cache.byLocal[key] = { id = best, pos = localPos }
                end
            end
            return best, {
                method = dir and "nearest_ray" or "nearest",
                dist = bestPerp,
                name = bestName,
            }
        end
    end

    return 0, { method = "none", reason = "no attachment near muzzle position" }
end
