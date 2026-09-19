--[[---------------------------------------------------------------------------
    LVS → Gredwitch FX : muzzle attachment resolution (client-side)

    OLD-SCHOOL, RUN ON THE STATIC DUMMY (7th generation).

    User decree: the fancy machinery was the problem — pose mirrors,
    fire-moment replays, dual hypotheses, ray scoring, facing gates —
    every moving part was another way for the "ray" to misalign or sweep
    the hull. So: the ORIGINAL simple method from the start, but executed
    against the hidden, stationary, NEVER-POSED ClientsideModel copy of
    the vehicle's model ("on the dummy model, maybe it works better like
    that"). The dummy has no velocity, no interpolation, no network
    lag — its attachment table is never garbage (the live BRDM-2's
    attName:"?" can never happen there).

    The old method, kept simple by decree:
      1) EffectData attachment id wins if the model has it.
      2) LVS TurretBallisticsMuzzleAttachment name wins if present.
      3) Nearest muzzle/barrel-NAMED attachment within MAX_NAMED_DIST.
      4) Nearest attachment of any name within MAX_GENERIC_DIST.
      5) Nothing within reach → world-spawn at the raw snapshot point.

    What remains cured from the original wrong-id era (by construction,
    not by gates): ungarbageable data (static dummy), the unbounded
    "nearest-anything" grab (radius caps — beyond them the resolver
    world-spawns instead of gluing far), and blind caches (none exist;
    every shot decides fresh against static data).

    What the resolver deliberately does NOT do: no pose reproduction of
    any kind (the dummy is never re-posed); no multi-frame hypotheses
    for identification; no Ray/Facing/Ambiguity gates. Compensation
    (pose history, CompensateMuzzleSnapshot) survives ONLY as the
    exported position helper barrel smoke already relied on.

    Fallback when a dummy cannot be created: candidates are read from
    the live entity in its local frame with the degenerate-pose guard.

    Known limitation: the dummy mirrors the FIRST-SEEN entity's bodygroups/
    skin only; models whose muzzle geometry changes with bodygroups after
    first sighting are rare and unaffected in practice.
-----------------------------------------------------------------------------]]

if not CLIENT then return end

local cfg = LVS_GRED_FX.Config
local Debug = LVS_GRED_FX.Debug

-- Search radii for the OLD-SCHOOL nearest lookup (units, MODEL space).
-- The original method picked "nearest attachment" with NO bound — that
-- unbounded grab was the original wrong-id disease. These caps keep the
-- old simple semantics while the static dummy guarantees the data itself
-- is never garbage or lagged: anything beyond the cap declines to
-- world-spawn instead of gluing to a far, wrong id.
local MAX_NAMED_DIST      = 32   -- nearest muzzle/barrel-NAMED attachment
local MAX_GENERIC_DIST    = 40   -- nearest attachment, unnamed models

-- Snapshot-compensation tuning (serves CompensateMuzzleSnapshot — barrel
-- smoke compensates through it; the resolver itself no longer multiplies
-- hypothesis frames — the old method had none).
local POSE_HISTORY_TIME   = 1.5
local TRACK_IDLE_TIME     = 1.0
local MAX_SNAPSHOT_DELAY  = 0.5
local COMP_MIN_SHIFT_SQR  = 1

-- Dummy fleet geometry.
local DUMMY_ORIGIN        = Vector(-30000, -30000, -30000)
local DUMMY_WARMUP        = 0.15 -- seconds before a fresh dummy's bones are trusted

local function isMuzzleName(name)
    if not isstring(name) then return false end
    local lower = string.lower(name)
    return string.find(lower, "muzzle", 1, true) ~= nil
        or string.find(lower, "barrel", 1, true) ~= nil
end

--[[---------------------------------------------------------------------------
    The stationary dummy fleet. One hidden ClientsideModel per model path,
    parked far below the map, never drawn, never moving in world space —
    a perfect reference for attachment geometry once its pose matches the
    real entity's.
-----------------------------------------------------------------------------]]
local DUMMIES    = {}  -- model → ClientsideModel
local dummyCount = 0

local function GetDummy(model, donor)
    if not isstring(model) or model == "" then return nil end

    local dummy = DUMMIES[model]
    if IsValid(dummy) then return dummy end

    local ok, ent = pcall(ClientsideModel, model, RENDERGROUP_OTHER)
    if not ok or not IsValid(ent) then
        DUMMIES[model] = nil
        return nil
    end

    dummyCount = dummyCount + 1

    ent:SetNoDraw(true)
    ent:SetPos(DUMMY_ORIGIN + Vector((dummyCount % 8) * 512, math.floor(dummyCount / 8) * 512, 0))
    ent:SetAngles(angle_zero)
    ent:SetMoveType(MOVETYPE_NONE)
    if ent.PhysicsDestroy then pcall(ent.PhysicsDestroy, ent) end

    -- Mirror the donor's appearance where it can matter for geometry.
    if IsValid(donor) then
        if donor.GetSkin and ent.SetSkin then
            pcall(function() ent:SetSkin(donor:GetSkin()) end)
        end
        if donor.GetNumBodyGroups and donor.GetBodygroup and ent.SetBodygroup then
            pcall(function()
                for i = 0, donor:GetNumBodyGroups() - 1 do
                    ent:SetBodygroup(i, donor:GetBodygroup(i))
                end
            end)
        end
    end

    ent:Spawn()
    if ent.SetupBones then pcall(ent.SetupBones, ent) end
    ent._lvsGredReady = CurTime() + DUMMY_WARMUP -- bones need a frame to pose

    DUMMIES[model] = ent
    return ent
end

local function DummyReady(dummy)
    return IsValid(dummy) and (dummy._lvsGredReady or 0) <= CurTime()
end

-- THE DUMMY IS COMPLETELY STATIC — by user decree and by design:
-- no pose parameters, no bone manipulations, no turret, no gun, nothing,
-- ever. Any pose reproduction (current, fire-moment, estimated) can lag
-- the truth on a moving turret, and a lagging reference GUARANTEES a
-- misaligned ray.
--
-- Instead the static twin acts as a geometric ORACLE for frame-stable
-- relationships only: an attachment candidate stays inside the ray window
-- for a given muzzle point ONLY if its bond with that muzzle does not
-- depend on turret pose (hull-mounted guns — fine to attach, they can
-- never fake-match). The moment anything is turret-mounted, traversing
-- rotates the muzzle point away from the frozen candidate cluster, the
-- window fails, and the resolver world-spawns the flash EXACTLY at the
-- firing point. Nothing pose-dependent can ever attach — and nothing can
-- misalign, because nothing tries to align.

-- Attachment data of the static dummy, expressed in MODEL space
-- (dummy sits at angle_zero: world - origin is the exact model-local point
-- and its Ang is the exact model-local Ang).
local function DummyAttachmentData(dummy, attID)
    if not attID or attID <= 0 then return nil end

    local ok, att = pcall(dummy.GetAttachment, dummy, attID)
    if not ok or not att or not isvector(att.Pos) then return nil end

    local lfwd = nil
    if isangle(att.Ang) then
        lfwd = att.Ang:Forward()
    end

    return att.Pos - dummy:GetPos(), att.Name, lfwd
end

--[[---------------------------------------------------------------------------
    Per-MODEL metadata cache (attachment id/name list). Identification
    results are NOT cached — only facts about the model file itself.
-----------------------------------------------------------------------------]]
local MODEL_CACHE = {} -- model → { atts, dummy }

local function GetModelCache(model, donor)
    local cache = MODEL_CACHE[model]
    if cache then
        if not IsValid(cache.dummy) then
            cache.dummy = GetDummy(model, donor)
        end
        return cache
    end

    cache = {
        atts  = nil,
        dummy = nil,
    }
    MODEL_CACHE[model] = cache

    local dummy = GetDummy(model, donor)
    if IsValid(dummy) then
        cache.dummy = dummy
        if dummy.GetAttachments then
            local ok, atts = pcall(dummy.GetAttachments, dummy)
            if ok and istable(atts) then
                cache.atts = atts
            end
        end
    end

    return cache
end

-- Get world position (and name) of an attachment on the REAL entity;
-- returns nil on any failure.
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

-- Attachment name with DUMMY metadata fallback (live entities with garbage
-- pose data report "?"; the model still knows the name).
function LVS_GRED_FX.AttachmentName(ent, attID)
    local att = LVS_GRED_FX.GetAttachmentData(ent, attID)
    if att and isstring(att.Name) and att.Name ~= "" then
        return att.Name
    end

    if IsValid(ent) then
        local cache = GetModelCache(ent:GetModel(), ent)
        if cache.atts then
            for i = 1, #cache.atts do
                if cache.atts[i] and cache.atts[i].id == attID then
                    return cache.atts[i].name or "?"
                end
            end
        end
    end

    return "?"
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

--[[---------------------------------------------------------------------------
    Snapshot-time compensation (per-entity pose history + delay estimate).
    Exported as CompensateMuzzleSnapshot for position correction (barrel
    smoke rides it); the resolver itself no longer scores hypotheses.
-----------------------------------------------------------------------------]]
local POSE_HISTORY = setmetatable({}, { __mode = "k" })
local TRACKED      = setmetatable({}, { __mode = "k" })

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
    if n > 0 and hist[n].t >= now then return end

    hist[n + 1] = { t = now, pos = ent:GetPos(), ang = ent:GetAngles() }

    while hist[1] and now - hist[1].t > POSE_HISTORY_TIME do
        table.remove(hist, 1)
    end
end

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

local function RotateDirBetween(dir, angFrom, angTo)
    local l = WorldToLocal(dir, angle_zero, vector_origin, angFrom)
    return LocalToWorld(l, angle_zero, vector_origin, angTo)
end

local function CompensateSnapshot(ent, muzzlePos, dir)
    local ago = EstimateSnapshotDelay()
    if ago <= 0.005 then return muzzlePos, dir, false end

    local pose = PoseAt(ent, ago)
    if not pose then return muzzlePos, dir, false end

    if CurTime() - pose.t <= 0.001 then return muzzlePos, dir, false end

    local pastLocal = WorldToLocal(muzzlePos, angle_zero, pose.pos, pose.ang)
    local cpos = LocalToWorld(pastLocal, angle_zero, ent:GetPos(), ent:GetAngles())

    if cpos:DistToSqr(muzzlePos) <= COMP_MIN_SHIFT_SQR then
        return muzzlePos, dir, false
    end

    local cdir = dir
    if isvector(dir) then
        cdir = RotateDirBetween(dir, pose.ang, ent:GetAngles())
    end

    return cpos, cdir, true
end

function LVS_GRED_FX.CompensateMuzzleSnapshot(ent, muzzlePos, dir)
    if not IsValid(ent) or not isvector(muzzlePos) then
        return muzzlePos, dir, false
    end
    return CompensateSnapshot(ent, muzzlePos, dir)
end
--[[---------------------------------------------------------------------------
    Candidate list for one resolve: id + name + MODEL-LOCAL position, read
    from the STATIC dummy (fallback: live entity, local-framed,
    degenerate-guarded). Built once per resolve call.
-----------------------------------------------------------------------------]]
local function BuildCandidates(ent, cache)
    local cands = {}
    local namedSet = {}

    local dummy = cache.dummy
    if DummyReady(dummy) then
        for i = 1, #(cache.atts or {}) do
            local id = cache.atts[i] and cache.atts[i].id
            if id and id > 0 then
                local lpos, name, lfwd = DummyAttachmentData(dummy, id)
                if lpos then
                    name = cache.atts[i].name or name or ""
                    cands[id] = { id = id, name = name, lpos = lpos, lfwd = lfwd }
                    if isMuzzleName(name) then namedSet[id] = true end
                end
            end
        end

        if next(cands) ~= nil then
            return cands, namedSet, "dummy"
        end
    end

    -- Fallback: live entity, local frame, degenerate-pose guard.
    local atts = cache.atts
    if not atts and ent.GetAttachments then
        local ok, res = pcall(ent.GetAttachments, ent)
        if ok and istable(res) then
            atts = res
            cache.atts = res
        end
    end

    if atts and #atts >= 3 then
        -- Degenerate check: ALL positions on the entity origin → garbage.
        local origin = ent:GetPos()
        local degenerate = true
        for i = 1, #atts do
            local ad = LVS_GRED_FX.GetAttachmentData(ent, atts[i] and atts[i].id)
            if ad and ad.Pos:DistToSqr(origin) > 9 then
                degenerate = false
                break
            end
        end
        if degenerate then
            return {}, {}, "degenerate"
        end
    end

    if atts then
        for i = 1, #atts do
            local id = atts[i] and atts[i].id
            if id and id > 0 then
                local ad = LVS_GRED_FX.GetAttachmentData(ent, id)
                if ad and ent.WorldToLocal then
                    local name = atts[i].name or ad.Name or ""
                    cands[id] = { id = id, name = name, lpos = ent:WorldToLocal(ad.Pos) }
                    if isMuzzleName(name) then namedSet[id] = true end
                end
            end
        end
    end

    return cands, namedSet, "live"
end

--[[---------------------------------------------------------------------------
    ResolveMuzzleAttachment( ent, muzzlePos, effectDataAtt, shotDir )

      ent          — entity owning the attachments (pass the VEHICLE ROOT)
      muzzlePos    — world muzzle source position (server snapshot)
      effectDataAtt— attachment id carried in the EffectData (0 if none)
      shotDir      — unused by the old method; kept in the signature for
                     caller compatibility

    THE ORIGINAL SIMPLE METHOD — run against the static dummy (user decree):
      1) EffectData attachment id, if it exists in the candidate list.
      2) LVS TurretBallisticsMuzzleAttachment NAME, if the model has it.
      3) Nearest "muzzle"/"barrel"-NAMED attachment within MAX_NAMED_DIST.
      4) Nearest attachment of any name within MAX_GENERIC_DIST.
      5) Nothing within reach → attachmentID 0 → caller world-spawns at
         info.sourcePos (the RAW snapshot point, exactly where the original
         LVS effect would draw).

    The old method's three wrong-id diseases stay cured by construction,
    not by gates: garbage lagged live pose data (the dummy never has any),
    the unbounded nearest-grab (radius caps), blind caches (none exist).
    Hypothesis frames, ray scoring, facing gates — all gone by decree.

    Returns: attachmentID, info
      attachmentID > 0 → attach to the REAL entity with PATTACH_POINT_FOLLOW.
      attachmentID == 0 → world-spawn at info.sourcePos.
      info: dist, name, sourcePos (+ correctedPos alias), method.
      Methods: "effectdata" | "lvs_muzzle_name" | "named" | "nearest" |
               "none" | "degenerate"
-----------------------------------------------------------------------------]]
function LVS_GRED_FX.ResolveMuzzleAttachment(ent, muzzlePos, effectDataAtt, shotDir)
    if not IsValid(ent) then return 0, { method = "none", reason = "invalid entity" } end
    if not isvector(muzzlePos) then return 0, { method = "none", reason = "invalid muzzle position" } end
    if not ent.WorldToLocal or not ent.LocalToWorld then
        return 0, { method = "none", reason = "entity has no local frame" }
    end

    TRACKED[ent] = CurTime()
    RecordPose(ent, CurTime())

    local function pack(id, info)
        if istable(info) then
            -- The OLD method's truth: the source point is the snapshot
            -- exactly as LVS gave it. No correction multiplication; barrel
            -- smoke compensates through its own path as before.
            info.sourcePos    = muzzlePos
            info.correctedPos = muzzlePos
            info.correctedDir = shotDir
        end
        return id, info
    end

    if cfg.DebugEnabled() and debugoverlay and debugoverlay.Line
        and isvector(shotDir) and shotDir:LengthSqr() >= 0.25 then
        debugoverlay.Line(muzzlePos, muzzlePos + shotDir:GetNormalized() * 256, 0.5, Color(255, 60, 30), true)
    end

    local model = ent:GetModel()
    local cache = GetModelCache(model, ent)

    local cands, namedSet, candSrc = BuildCandidates(ent, cache)

    if candSrc == "degenerate" then
        return pack(0, {
            method = "degenerate",
            reason = "all attachment positions degenerate (unposed bones)",
        })
    end

    if next(cands) == nil then
        return pack(0, { method = "none", reason = "no attachment data available" })
    end

    -- The muzzle point in MODEL space: localize with the root's current
    -- pose (the old method localized against the entity outright; this is
    -- the same idea with a coordinate frame that tolerates motion).
    local lpos = ent:WorldToLocal(muzzlePos)

    -- 1) EffectData attachment id — LVS's own word for it.
    local effectAtt = (effectDataAtt and effectDataAtt > 0) and effectDataAtt or nil
    if effectAtt and cands[effectAtt] then
        local cand = cands[effectAtt]
        return pack(effectAtt, {
            method = "effectdata",
            dist   = cand.lpos:DistToSqr(lpos) > 0 and math.sqrt(cand.lpos:DistToSqr(lpos)) or 0,
            name   = cand.name,
        })
    end

    -- 2) LVS TurretBallisticsMuzzleAttachment name.
    local lvsName = ent.TurretBallisticsMuzzleAttachment
    local lvsNameId = nil
    if isstring(lvsName) and lvsName ~= "" then
        local dummy = cache.dummy
        if DummyReady(dummy) and dummy.LookupAttachment then
            local ok, id = pcall(dummy.LookupAttachment, dummy, lvsName)
            lvsNameId = (ok and id and id > 0) and id or nil
        end
        if not lvsNameId and ent.LookupAttachment then
            local ok, id = pcall(ent.LookupAttachment, ent, lvsName)
            lvsNameId = (ok and id and id > 0) and id or nil
        end
        if lvsNameId and lvsNameId ~= effectAtt and cands[lvsNameId] then
            local cand = cands[lvsNameId]
            return pack(lvsNameId, {
                method = "lvs_muzzle_name",
                dist   = math.sqrt(cand.lpos:DistToSqr(lpos)),
                name   = cand.name,
            })
        end
    end

    -- 3) + 4) The old-school nearest pick, radii-capped per class — with
    -- ONE number added by the twin-cannon lesson: with two cannons on a
    -- traversing ring, the FIRED gun's point slides around the arc and
    -- ends up nearly as close to the OTHER cannon's frozen attachment —
    -- "nearest" then glues the flash to the wrong side for both guns
    -- ("slightly left → flash only on the left cannon"). So a pick only
    -- wins when it is UNAMBIGUOUS: at least 2× closer than every rival id.
    -- Anything less lands at step 5 → world-spawn at the snapshot point,
    -- which already IS the correct side (and since the spawn chain was
    -- hardened, that flash always plays instead of falling to vanilla).
    local bestNamed, bestNamedDist
    local bestAny, bestAnyDist
    local results = {}

    for id, cand in pairs(cands) do
        if id ~= effectAtt and id ~= lvsNameId then
            local d = math.sqrt(cand.lpos:DistToSqr(lpos))
            results[#results + 1] = { cand = cand, dist = d }

            if namedSet[id] then
                if not bestNamedDist or d < bestNamedDist then
                    bestNamed, bestNamedDist = cand, d
                end
            end
            if not bestAnyDist or d < bestAnyDist then
                bestAny, bestAnyDist = cand, d
            end
        end
    end

    local function rivalDist(winnerCand)
        local r
        for i = 1, #results do
            if results[i].cand ~= winnerCand then
                local d = results[i].dist
                if not r or d < r then r = d end
            end
        end
        return r
    end

    local function unambiguous(cand, dist)
        local r = rivalDist(cand)
        return (not r) or dist * 2 <= r
    end

    if bestNamed and bestNamedDist <= MAX_NAMED_DIST then
        if unambiguous(bestNamed, bestNamedDist) then
            return pack(bestNamed.id, {
                method = "named",
                dist   = bestNamedDist,
                name   = bestNamed.name,
            })
        end

        return pack(0, {
            method = "ambiguous",
            reason = string.format("'%s' only %.1fu closer than a rival",
                tostring(bestNamed.name), rivalDist(bestNamed) - bestNamedDist),
            dist   = bestNamedDist,
        })
    end

    if bestAny and bestAnyDist <= MAX_GENERIC_DIST then
        if unambiguous(bestAny, bestAnyDist) then
            return pack(bestAny.id, {
                method = "nearest",
                dist   = bestAnyDist,
                name   = bestAny.name,
            })
        end

        return pack(0, {
            method = "ambiguous",
            reason = string.format("'%s' only %.1fu closer than a rival",
                tostring(bestAny.name), rivalDist(bestAny) - bestAnyDist),
            dist   = bestAnyDist,
        })
    end

    -- 5) Out of reach of anything → world-spawn at the snapshot point.
    if cfg.DebugEnabled() then
        Debug("muzzle nearest out of range:",
            bestAny and string.format("%s id:%d at %.1fu", tostring(bestAny.name), bestAny.id or -1, bestAnyDist or -1) or "none",
            "— world fallback")
    end

    return pack(0, {
        method = "none",
        reason = string.format("nearest attachment %s over reach cap",
            bestAny and string.format("'%s' %.0fu", tostring(bestAny.name), bestAnyDist or -1) or "missing"),
        dist   = bestAnyDist,
    })
end
