--[[---------------------------------------------------------------------------
    LVS → Gredwitch FX : muzzle attachment resolution (client-side)

    SELF-VALIDATING RESOLUTION (3rd generation).

    Plain point-distance picking glued flashes to the wrong attachment, and
    even the ray-only rework could miss when the muzzle source is stale
    (see SNAPSHOT STALENESS below). This resolver is built around one rule:

      THE FLASH BELONGS AT THE MUZZLE POINT. An attachment is only a
      follower mechanism, and it is used ONLY when it unambiguously IS the
      muzzle. Otherwise the effect is spawned in world space at the muzzle
      point itself — which can never be the "wrong attachment".

    Decision pipeline:

      0. SNAPSHOT COMPENSATION hypotheses. LVS fires the muzzle effect with a
         world position snapshotted on the SERVER at fire time; the client
         resolves ping/2+interp later against moved bones (100+ units at
         speed). We compute BOTH the raw snapshot AND a rigidly
         motion-compensated source (per-entity pose history + delay estimate
         = ping/2 + max(cl_interp, cl_interp_ratio/cl_updaterate), 0 in SP),
         and score candidates under BOTH hypotheses — THE BETTER FIT WINS
         per shot. Wrong compensation (listen-host vs MP client skew
         differences) is impossible by construction: the raw hypothesis
         simply wins there.

      1. Degenerate pose detection. If EVERY attachment position on the model
         sits on top of the entity origin, the bone pose data is garbage
         (unposed matrices) — NO attachment id can be trusted. World-spawn.

      2. Unified candidate scoring. EffectData id, the authoritative LVS
         muzzle name (TurretBallisticsMuzzleAttachment), named
         "muzzle"/"barrel" attachments and generic attachments are ALL scored
         together against the shot ray (perpendicular distance dominant;
         small along-ray tie-break; authoritativeness bonuses for EffectData
         / LVS-name / "muzzle"-named ids). Ray caps reject candidates off
         the ray or far behind/ahead of the muzzle tip.

      3. Ambiguity gate. If two DIFFERENT attachments fit nearly equally
         well (score within AMBIGUITY_GAP), gluing to either is a coin flip
         — THE classic "wrong id". Decline both, world-spawn at the muzzle
         point. (Authoritative EffectData/LVS-name ids are exempt.)

      4. Attach-vs-world gate. If even the best named/generic attachment is
         further than ATTACH_PERP_MAX from the muzzle point (mirrored
         wrong-side barrel, breech-root "barrel" attachment), decline it and
         world-spawn at the muzzle point. (Authoritative ids exempt.)

      5. Static-barrel cache: gated winners are remembered per local muzzle
         position, but a cache hit is honoured ONLY when the cached id is
         still a top-2, close, unambiguous candidate THIS frame — the cache
         can accelerate, it can never decide (a blind hit pinned a garbage
         id on every shot once; never again).

    info.sourcePos (alias correctedPos for older callers) always carries the
    WINNING hypothesis position for world-space spawns.

    Performance: GetAttachmentData is memoized per resolve call; pose history
    is kept only for entities that fired within the last second.
-----------------------------------------------------------------------------]]

if not CLIENT then return end

local cfg = LVS_GRED_FX.Config
local Debug = LVS_GRED_FX.Debug

-- Candidate window tolerances (units).
local MAX_EFFECTDATA_DIST = 96   -- EffectData attachment: coarse window
local MAX_EFFECTDATA_PERP = 64   -- EffectData attachment: ray sanity check
local MAX_NAMED_DIST      = 32   -- named candidates without a direction
local MAX_GENERIC_DIST    = 48   -- strict radius for unnamed models
local MAX_RAY_PERP        = 40   -- ray-fit: max perpendicular distance
local RAY_ALONG_MIN       = -64  -- max projection BEHIND the muzzle source
                                 -- (breech-root "barrel" attachments live
                                 -- further back: reject → world-spawn at tip)
local RAY_ALONG_MAX       = 48   -- max projection ahead of the source

-- Attach-vs-world gates (units / score points).
local ATTACH_PERP_MAX     = 28   -- attachments further from the muzzle point
                                 -- than this are NOT glued; world-spawn at
                                 -- the point instead (a wrong attachment
                                 -- reads far worse than a free flash)
local AMBIGUITY_GAP       = 8    -- best vs second-best score gap (different
                                 -- ids) below which the pick is a coin flip
                                 -- → decline, world-spawn

-- Score bonuses (subtracted): authoritativeness ranking for near-ties.
local EFFECTDATA_BONUS    = 3
local LVS_NAME_BONUS      = 2
local MUZZLE_NAME_BONUS   = 2
local ALONG_TIEBREAK      = 0.1

-- Local-space quantization & drift validation for the static-barrel cache.
local LOCAL_CELL          = 8
local CACHE_DRIFT         = 4

-- Snapshot-compensation tuning.
local POSE_HISTORY_TIME   = 1.5  -- seconds of pose history kept per entity
local TRACK_IDLE_TIME     = 1.0  -- stop tracking this long after last resolve
local MAX_SNAPSHOT_DELAY  = 0.5  -- sanity clamp for the estimated delay
local COMP_MIN_SHIFT_SQR  = 1    -- ignore compensation <1 unit (noise)

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
    local namedSet = {}
    if atts then
        for i = 1, #atts do
            local id = atts[i] and atts[i].id
            local name = atts[i] and atts[i].name
            if id and id > 0 and isMuzzleName(name) then
                named[#named + 1] = id
                namedSet[id] = true
            end
        end
    end

    cache = {
        model    = model,
        atts     = atts,
        named    = named,
        namedSet = namedSet,
        byLocal  = {},   -- quantized local pos → attachment id (static barrels)
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
    entities that fired recently) + a snapshot-delay estimate. Produces the
    second ("compensated") hypothesis the resolver scores alongside the raw
    snapshot: the better fit wins each shot, so a WRONG estimate can never
    hurt (the raw hypothesis would simply win).
-----------------------------------------------------------------------------]]
local POSE_HISTORY = setmetatable({}, { __mode = "k" }) -- ent → { {t,pos,ang}, ... }
local TRACKED      = setmetatable({}, { __mode = "k" }) -- ent → last resolve time

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

-- dir_rotated ≈ (angTo * angFrom^-1) * dir, via the world↔local helpers.
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

    -- Ignore sub-unit shifts (noise; also keeps hypothesis dedup simple).
    if cpos:DistToSqr(muzzlePos) <= COMP_MIN_SHIFT_SQR then
        return muzzlePos, dir, false
    end

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
local function scoreCandidate(attPos, muzzlePos, dir, perpLimit, alongMin, alongMax)
    local to = attPos - muzzlePos

    if not dir then
        local d = to:Length()
        if d > perpLimit then return nil end
        return d, d
    end

    local along = to:Dot(dir)
    local perpSqr = to:LengthSqr() - along * along
    if perpSqr < 0 then perpSqr = 0 end
    local perp = math.sqrt(perpSqr)

    if perp > perpLimit then return nil end
    if along < alongMin or along > alongMax then return nil end

    return perp + math.abs(along) * ALONG_TIEBREAK, perp
end

--[[---------------------------------------------------------------------------
    ResolveMuzzleAttachment( ent, muzzlePos, effectDataAtt, shotDir )

      ent          — entity owning the attachments (pass the VEHICLE ROOT)
      muzzlePos    — world muzzle source position; SERVER SNAPSHOT from the
                     fire moment (compensated internally as one hypothesis)
      effectDataAtt— attachment id carried in the EffectData (0 if none)
      shotDir      — optional bullet direction (EffectData normal)

    Returns: attachmentID, info
      attachmentID == 0 → the CALLER must spawn in world space at
      info.sourcePos (never the raw muzzlePos!). Methods:
        "effectdata" / "lvs_muzzle_name"  — authoritative id accepted
        "named_ray" / "named_nearest"     — named muzzle candidate accepted
        "nearest_ray" / "nearest"         — generic nearest accepted
        "local_cache"                     — static-barrel cache hit
        "ambiguous"                       — coin-flip declined (world-spawn)
        "world"                           — best candidate too far (world-spawn)
        "degenerate"                      — garbage pose data (world-spawn)
        "none"                            — nothing usable (world-spawn)
      info also carries: dist, name, sourcePos + correctedPos (same winning
      source position; keep both names for caller compat), correctedDir,
      compensated, hypothesis ("raw" | "compensated").
-----------------------------------------------------------------------------]]
function LVS_GRED_FX.ResolveMuzzleAttachment(ent, muzzlePos, effectDataAtt, shotDir)
    if not IsValid(ent) then return 0, { method = "none", reason = "invalid entity" } end
    if not isvector(muzzlePos) then return 0, { method = "none", reason = "invalid muzzle position" } end

    local dir = normalizeDir(shotDir)

    TRACKED[ent] = CurTime()
    RecordPose(ent, CurTime())

    local cpos, cdir, compensated = CompensateSnapshot(ent, muzzlePos, dir)

    -- Hypotheses scored side by side; the better fit wins per shot.
    local sources = {
        { pos = muzzlePos, dir = dir, tag = "raw" },
    }
    if compensated then
        sources[2] = { pos = cpos, dir = cdir, tag = "compensated" }
    end

    local function pack(id, info, winSrc)
        if istable(info) then
            local sp = (winSrc and winSrc.pos) or cpos
            info.sourcePos   = sp
            info.correctedPos = sp -- compat alias for existing callers
            info.correctedDir = (winSrc and winSrc.dir) or cdir
            info.hypothesis  = winSrc and winSrc.tag or (compensated and "compensated" or "raw")
            info.compensated = (winSrc and winSrc.tag == "compensated") or false
        end
        return id, info
    end

    -- Debug: blue box = raw snapshot area; red line = raw ray; orange line =
    -- compensated ray.
    if cfg.DebugEnabled() and debugoverlay then
        if debugoverlay.Box then
            debugoverlay.Box(muzzlePos, Vector(MAX_NAMED_DIST, MAX_NAMED_DIST, MAX_NAMED_DIST), 0.5, Color(0, 100, 255, 60))
        end
        if debugoverlay.Line then
            if dir then
                debugoverlay.Line(muzzlePos, muzzlePos + dir * 256, 0.5, Color(255, 60, 30), true)
            end
            if compensated and cdir then
                debugoverlay.Line(cpos, cpos + cdir * 256, 0.5, Color(255, 180, 0), true)
            end
        end
    end

    local cache = GetCache(ent)

    -- Memoize GetAttachmentData per resolve (each id is looked up at most
    -- once, no matter how many hypotheses we score).
    local attMemo = {}
    local function getAtt(id)
        local memo = attMemo[id]
        if memo == nil then
            memo = LVS_GRED_FX.GetAttachmentData(ent, id) or false
            attMemo[id] = memo
        end
        return memo or nil
    end

    -- Degenerate pose: EVERY attachment sits on the entity origin — the bone
    -- data is garbage (unposed matrices). No id can be trusted. This check
    -- (built on the SAME per-resolve memo data as scoring) runs BEFORE the
    -- cache fast-path below: a cell validated as garbage can never poison
    -- later shots.
    if cache.atts and #cache.atts >= 3 then
        local origin = ent:GetPos()
        local degenerate = true
        for i = 1, #cache.atts do
            local att = getAtt(cache.atts[i] and cache.atts[i].id)
            if att and att.Pos:DistToSqr(origin) > 9 then
                degenerate = false
                break
            end
        end
        if degenerate then
            return pack(0, {
                method = "degenerate",
                reason = "all attachment positions degenerate (unposed bones)",
            }, nil)
        end
    end

    local cells = nil -- per-hypothesis local cells; filled lazily, reused
                      -- by the winner-store below

    -- Static-barrel fast path: a previous winner for this exact local muzzle
    -- point. CRITICALLY: the cached id is only re-used when it is still one
    -- of THIS FRAME's top-2 candidates with a credible score and no
    -- ambiguous near-tie — i.e. it passes equivalent gates to a fresh pick.
    -- (The old blind cache hit kept returning a degenerate/garbage id on
    -- EVERY shot — the "wrong id every shot" bug — because nothing
    -- re-validated it against the current frame.)
    local function cacheFastPath(bestEntry, secondEntry)
        if not ent.WorldToLocal then return end
        if not bestEntry or not bestEntry.src then return end

        local cachedId = nil

        cells = {}
        for s = 1, #sources do
            local src = sources[s]
            local localPos = ent:WorldToLocal(src.pos)
            local key = localKey(localPos)
            cells[#cells + 1] = { key = key, localPos = localPos, src = src }

            if key then
                local cached = cache.byLocal[key]
                if cached and cached.id and cached.pos and isvector(cached.pos) then
                    if localPos:DistToSqr(cached.pos) <= CACHE_DRIFT * CACHE_DRIFT then
                        cachedId = cached.id
                    else
                        cache.byLocal[key] = nil
                    end
                end
            end
        end

        if not cachedId then return end
        if not getAtt(cachedId) then return end

        -- Still among this frame's top-2 candidates?
        local isTop = bestEntry.id == cachedId
            or (secondEntry and secondEntry.id == cachedId)
        if not isTop then return end

        -- Credible muzzle distance?
        if (bestEntry.perp or 0) > ATTACH_PERP_MAX then return end

        -- Not in an ambiguous near-tie with a DIFFERENT id?
        if secondEntry and secondEntry.id ~= cachedId
            and (secondEntry.score - bestEntry.score) <= AMBIGUITY_GAP then
            return
        end

        local att = getAtt(cachedId)
        return pack(cachedId, {
            method = "local_cache",
            dist   = bestEntry.perp,
            name   = (att and att.Name) or "?",
        }, bestEntry.src)
    end

    -- Unified scoring over all candidate classes and all hypotheses.
    local effectAtt = (effectDataAtt and effectDataAtt > 0) and effectDataAtt or nil
    local lvsNameId = lookupLvsMuzzleId(ent, cache)
    lvsNameId = (lvsNameId and lvsNameId > 0) and lvsNameId or nil

    local best, second
    local dbg = cfg.DebugEnabled() and {} or nil

    local function consider(id, name, attPos, src, method, bonus, perpLimit, alongMin, alongMax)
        local limit = perpLimit or (src.dir and MAX_RAY_PERP or MAX_NAMED_DIST)
        local score, perp = scoreCandidate(attPos, src.pos, src.dir, limit, alongMin or RAY_ALONG_MIN, alongMax or RAY_ALONG_MAX)
        if not score then return end

        score = score - (bonus or 0)

        if dbg then
            dbg[#dbg + 1] = { id = id, name = name or "?", score = score, perp = perp, method = method, tag = src.tag }
        end

        -- Strictly-better wins: candidates from the RAW hypothesis (scanned
        -- first) win exact ties — wrong compensation can never displace a
        -- valid raw fit.
        if not best or score < best.score then
            second = best
            best = { id = id, score = score, perp = perp, method = method, name = name, src = src }
        elseif not second or score < second.score then
            second = { id = id, score = score, perp = perp, method = method, name = name, src = src }
        end
    end

    for s = 1, #sources do
        local src = sources[s]

        -- 1) EffectData attachment id (LVS-provided; authoritative bonus).
        if effectAtt then
            local att = getAtt(effectAtt)
            if att and att.Name and att.Name ~= "" then
                consider(effectAtt, att.Name, att.Pos, src, "effectdata",
                    EFFECTDATA_BONUS, MAX_EFFECTDATA_PERP, -MAX_EFFECTDATA_DIST, MAX_EFFECTDATA_DIST)
            end
        end

        -- 2) Authoritative LVS muzzle attachment name.
        if lvsNameId and lvsNameId ~= effectAtt then
            local att = getAtt(lvsNameId)
            if att and att.Name and att.Name ~= "" then
                consider(lvsNameId, att.Name, att.Pos, src, "lvs_muzzle_name", LVS_NAME_BONUS)
            end
        end

        -- 3) Named muzzle/barrel candidates.
        for i = 1, #cache.named do
            local id = cache.named[i]
            if id ~= effectAtt and id ~= lvsNameId then
                local att = getAtt(id)
                if att and att.Name and att.Name ~= "" then
                    local bonus = string.find(string.lower(att.Name), "muzzle", 1, true) and MUZZLE_NAME_BONUS or 0
                    consider(id, att.Name, att.Pos, src, src.dir and "named_ray" or "named_nearest", bonus)
                end
            end
        end

        -- 4) Generic attachments (models without named muzzles).
        if cache.atts then
            for i = 1, #cache.atts do
                local id = cache.atts[i] and cache.atts[i].id
                if id and id > 0 and id ~= effectAtt and id ~= lvsNameId and not cache.namedSet[id] then
                    local att = getAtt(id)
                    if att then
                        local limit = src.dir and MAX_RAY_PERP or MAX_GENERIC_DIST
                        consider(id, att.Name or "", att.Pos, src, src.dir and "nearest_ray" or "nearest", 0, limit)
                    end
                end
            end
        end
    end

    if not best then
        return pack(0, { method = "none", reason = "no attachment near muzzle position" }, nil)
    end

    if dbg then
        table.sort(dbg, function(a, b) return a.score < b.score end)
        for i = 1, math.min(#dbg, 5) do
            local c = dbg[i]
            Debug("muzzle cand:", c.name, "id:", c.id, "hyp:", c.tag,
                string.format("score=%.1f perp=%.1f meth=%s", c.score, c.perp or -1, c.method))
        end
    end

    -- Cache fast-path: hit only if the cached id survives THIS frame's
    -- gates (top-2, close, unambiguous).
    local cacheId, cacheInfo = cacheFastPath(best, second)
    if cacheId then
        return cacheId, cacheInfo
    end

    local authoritative = best.method == "effectdata" or best.method == "lvs_muzzle_name"

    -- Ambiguity gate: two DIFFERENT attachments fit nearly equally → coin
    -- flip → decline; world-spawn at the true muzzle point instead.
    if not authoritative
        and second and second.id ~= best.id
        and (second.score - best.score) <= AMBIGUITY_GAP then
        return pack(0, {
            method = "ambiguous",
            reason = "near-tie between " .. tostring(best.name) .. " and " .. tostring(second.name),
            dist = best.perp,
        }, best.src)
    end

    -- Attach-vs-world gate: best attachment sits too far from the actual
    -- muzzle point (mirrored wrong-side barrel, breech-root) → world-spawn.
    if not authoritative and (best.perp or 0) > ATTACH_PERP_MAX then
        return pack(0, {
            method = "world",
            reason = string.format("best candidate '%s' %.0fu off the muzzle point", tostring(best.name), best.perp or -1),
            dist = best.perp,
        }, best.src)
    end

    -- GATED winner: remember it as a static barrel for repeat shots. Only
    -- ids that PASSED the gates above are ever stored, and the fast-path
    -- revalidates against the current frame on every hit, so a stale cell
    -- can never outlive its evidence.
    if ent.WorldToLocal then
        if not cells then
            cells = {}
            for s = 1, #sources do
                local src = sources[s]
                local localPos = ent:WorldToLocal(src.pos)
                cells[#cells + 1] = { key = localKey(localPos), localPos = localPos, src = src }
            end
        end
        for i = 1, #cells do
            local cell = cells[i]
            if cell.src == best.src and cell.key then
                cache.byLocal[cell.key] = { id = best.id, pos = cell.localPos }
            end
        end
    end

    return pack(best.id, {
        method = best.method,
        dist   = best.perp,
        name   = best.name,
    }, best.src)
end
