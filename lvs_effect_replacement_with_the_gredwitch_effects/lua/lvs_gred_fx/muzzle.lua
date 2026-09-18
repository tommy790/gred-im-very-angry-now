--[[---------------------------------------------------------------------------
    LVS → Gredwitch FX : muzzle attachment resolution (client-side)

    STATIC-ORACLE TWIN (6th generation) — the dummy is COMPLETELY STATIC.

    User decree: don't move any bone, don't move turrets, don't move the
    hull, don't move the gun, don't move anything — the moment anything
    poses, the ray is guaranteed to misalign.

    History of the bug: point-distance picked wrong ids; ray-fit on live
    attachments picked better but still wrong when live pose data was stale
    or garbage (BRDM-2's id 21 with attName "?" is the proof some entities
    return unposed data); a blind cache froze winners; a reference-pose
    dummy let traversed turrets sweep the ray through the hull; and every
    attempt to REPRODUCE the real pose on the dummy (current-pose mirror,
    then fire-moment replay with recorded pose parameters) was one lag
    away from misaligning again — client pose params, interpolation,
    lag-comp: none of it provably equals the truth on the server at fire
    time.

    The current design accepts that and turns it into armor:

      THE DUMMY NEVER MOVES. One hidden ClientsideModel per model, parked
      far below the map, spawned once, posed once, left in reference pose
      for the rest of the session.

      THE STATIC TWIN IS AN ORACLE FOR FRAME-STABLE BONDS ONLY. The ray
      score can only succeed where an attachment's bond with the muzzle
      point does NOT depend on turret pose (hull-mounted guns): those
      candidates hug the point in every frame, forever. The moment a
      relationship is pose-dependent (turret-mounted candidates), the
      muzzle point rotates away from the frozen cluster as the turret
      traverses, the window fails, and identification declines.

      WHAT DECLINE MEANS: world-spawn at the live, motion-corrected firing
      point. Correct flash at the true muzzle, attached to nothing, wrong
      never. Not a fallback to mourn — for one-shot muzzle particles it is
      visually identical to a perfect attach.

      WHAT STILL MOVES: only the ROOT-frame compensation (hypothesis raw
      vs motion-compensated, scored side by side, raw wins ties) — that
      tracks vehicle translation/rotation, provable from pose history.
      Never bones. Never pose parameters.

    Gates:
      * facing: candidates must point along the shot (muzzle attachments
        face out of the barrel) — hull furniture in the ray's path dies
        here;
      * ambiguity: two different ids fitting near-equally → world-spawn
        (a coin-flip glue IS the wrong id);
      * attach distance: candidate perp over ATTACH_PERP_MAX → world-spawn
        (8u; frame-stable bonds sit far closer, anything further is
        pose-dependent or plain wrong);
      * authoritative ids (EffectData attachment, LVS
        TurretBallisticsMuzzleAttachment) bypass both gates — the LVS
        author's word stands;
      * degenerate live-entity pose data only matters for the no-dummy
        fallback path (the static dummy never degenerates).

    Fallback when a dummy cannot be created: candidates are read from the
    live entity in its local frame with the degenerate-pose guard.

    Known limitation: the dummy mirrors the FIRST-SEEN entity's bodygroups/
    skin only; models whose muzzle geometry changes with bodygroups after
    first sighting are rare and unaffected in practice.
-----------------------------------------------------------------------------]]

if not CLIENT then return end

local cfg = LVS_GRED_FX.Config
local Debug = LVS_GRED_FX.Debug

-- Candidate window tolerances (units, MODEL space).
local MAX_EFFECTDATA_DIST = 96   -- EffectData attachment: coarse window
local MAX_EFFECTDATA_PERP = 64   -- EffectData attachment: ray sanity check
local MAX_NAMED_DIST      = 32   -- named candidates without a direction
local MAX_GENERIC_DIST    = 48   -- strict radius for unnamed models
local MAX_RAY_PERP        = 40   -- ray-fit: max perpendicular distance
local RAY_ALONG_MIN       = -32  -- max projection BEHIND the muzzle source
                                 -- (kept shallow: deep windows let the ray
                                 -- reach into the hull and score bolts)
local RAY_ALONG_MAX       = 24   -- max projection ahead of the source

-- Facing gate: a muzzle attachment's orientation points OUT OF THE BARREL
-- — along the shot. Hull/wheel attachments in the ray's path face random
-- directions; requiring candidates to face along the shot kills the
-- "wrong id standing in the ray's path" class entirely. dot threshold ≈
-- 29° cone. Authoritative ids (EffectData/LVS name) are exempt (the LVS
-- author already declared them the muzzle) and gate politely declines to
-- world-spawn otherwise — never the wrong id.
local ATTACH_FACING_DOT   = 0.87

-- Attach-vs-world gates (units / score points).
local ATTACH_PERP_MAX     = 8    -- named/generic candidates further than this
                                 -- from the muzzle point are NOT glued (the
                                 -- BRDM-2 case: a "nearest" id 13.2u off).
                                 -- Frame-stable muzzle attachments hug the
                                 -- point; anything further is pose-dependent
                                 -- or plain wrong → world-spawn at the point
                                 -- (visually identical, wrong never).
local AMBIGUITY_GAP       = 8    -- best vs second-best gap (different ids)
                                 -- below which the pick is a coin flip
                                 -- → world-spawn instead

-- Score bonuses (subtracted): authoritativeness ranking for near-ties.
local EFFECTDATA_BONUS    = 3
local LVS_NAME_BONUS      = 2
local MUZZLE_NAME_BONUS   = 2
local ALONG_TIEBREAK      = 0.1

-- Snapshot-compensation tuning.
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
    Produces the second ("compensated") hypothesis scored alongside the raw
    snapshot: the better fit wins, so a wrong estimate can never hurt.
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
    Shot-ray helpers (coordinate-space agnostic: used in model space).
-----------------------------------------------------------------------------]]
local function normalizeDir(shotDir)
    if not isvector(shotDir) then return nil end
    if shotDir:LengthSqr() < 0.25 then return nil end
    return shotDir:GetNormalized()
end

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
    Candidate list for one resolve: id + name + MODEL-LOCAL position, read
    from the pose-matched dummy (fallback: live entity, local-framed,
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
                    local lfwd = nil
                    if isangle(ad.Ang) then
                        local p1 = ent:WorldToLocal(ad.Pos)
                        local p2 = ent:WorldToLocal(ad.Pos + ad.Ang:Forward())
                        local d = p2 - p1
                        if d:LengthSqr() > 1e-6 then lfwd = d:GetNormalized() end
                    end
                    cands[id] = { id = id, name = name, lpos = ent:WorldToLocal(ad.Pos), lfwd = lfwd }
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
      muzzlePos    — world muzzle source position; SERVER SNAPSHOT from the
                     fire moment (raw + compensated hypotheses are scored)
      effectDataAtt— attachment id carried in the EffectData (0 if none)
      shotDir      — optional bullet direction (EffectData normal)

    Returns: attachmentID, info
      attachmentID > 0 → attach to the REAL entity with PATTACH_POINT_FOLLOW.
      attachmentID == 0 → caller MUST spawn in world space at info.sourcePos.

      Methods: "effectdata" | "lvs_muzzle_name" | "named_ray" |
               "named_nearest" | "nearest_ray" | "nearest" |
               "ambiguous" | "world" | "none" | "degenerate"
      info: dist, name, sourcePos (+ correctedPos alias), correctedDir,
            hypothesis, compensated.
-----------------------------------------------------------------------------]]
function LVS_GRED_FX.ResolveMuzzleAttachment(ent, muzzlePos, effectDataAtt, shotDir)
    if not IsValid(ent) then return 0, { method = "none", reason = "invalid entity" } end
    if not isvector(muzzlePos) then return 0, { method = "none", reason = "invalid muzzle position" } end
    if not ent.WorldToLocal or not ent.LocalToWorld then
        return 0, { method = "none", reason = "entity has no local frame" }
    end

    local dir = normalizeDir(shotDir)

    TRACKED[ent] = CurTime()
    RecordPose(ent, CurTime())

    -- TWO FRAMES are scored, because the snapshot arrives ping/2+interp
    -- late: the muzzle point (and the turret) may have moved since.
    --   raw         — current root pose + current pose parameters;
    --   compensated — the FIRE-MOMENT frame from our pose history: past
    --                 root pos/ang AND the past pose-parameter values
    --                 (the turret traverse at fire time), frozen onto the
    --                 dummy while its ray is scored.
    -- The better fit wins per shot; the raw frame wins exact ties, so a
    -- wrong delay estimate can never displace a correct current fit.
    local past = nil
    do
        local delay = EstimateSnapshotDelay()
        if delay > 0.005 then
            local sample = PoseAt(ent, delay)
            if sample and CurTime() - sample.t > 0.001 then
                past = sample
            end
        end
    end

    local hyps = {
        {
            tag  = "raw",
            rpos = ent:GetPos(),
            rang = ent:GetAngles(),
            dpos = muzzlePos,  -- display / world-spawn position
            ddir = dir,
        },
    }

    if past then
        local pastLocal = WorldToLocal(muzzlePos, angle_zero, past.pos, past.ang)
        local fpos = LocalToWorld(pastLocal, angle_zero, ent:GetPos(), ent:GetAngles())
        local fdir = dir
        if isvector(dir) then
            fdir = RotateDirBetween(dir, past.ang, ent:GetAngles())
        end
        if fpos:DistToSqr(muzzlePos) > COMP_MIN_SHIFT_SQR then
            hyps[2] = {
                tag  = "compensated",
                rpos = past.pos,
                rang = past.ang,
                dpos = fpos,
                ddir = fdir,
            }
        end
    end

    local function pack(id, info, winHyp)
        if istable(info) then
            local fallback = hyps[2] or hyps[1]
            local sp = (winHyp and winHyp.dpos) or fallback.dpos
            info.sourcePos    = sp
            info.correctedPos = sp
            info.correctedDir = (winHyp and winHyp.ddir) or fallback.ddir
            info.hypothesis   = winHyp and winHyp.tag or fallback.tag
            info.compensated  = (winHyp and winHyp.tag == "compensated") or false
        end
        return id, info
    end

    if cfg.DebugEnabled() and debugoverlay and debugoverlay.Line then
        if dir then
            debugoverlay.Line(muzzlePos, muzzlePos + dir * 256, 0.5, Color(255, 60, 30), true)
        end
        if hyps[2] and hyps[2].ddir then
            debugoverlay.Line(hyps[2].dpos, hyps[2].dpos + hyps[2].ddir * 256, 0.5, Color(255, 180, 0), true)
        end
    end

    local model = ent:GetModel()
    local cache = GetModelCache(model, ent)

    -- Authoritative ids.
    local effectAtt = (effectDataAtt and effectDataAtt > 0) and effectDataAtt or nil

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
        if lvsNameId == effectAtt then lvsNameId = nil end
    end

    -- Unified scoring in MODEL space over both frames.
    local best, second
    local dbg = cfg.DebugEnabled() and {} or nil
    local candSrc

    local function consider(id, cand, lsrc, method, bonus, perpLimit, alongMin, alongMax)
        -- Facing gate: non-authoritative candidates must POINT along the
        -- shot (muzzle attachments face out of the barrel); anything in
        -- the ray's path that faces another way is hull furniture, not a
        -- muzzle — the shot line sweeping the vehicle can no longer score
        -- it just for lying there.
        if lsrc.ldir and cand.lfwd
            and method ~= "effectdata" and method ~= "lvs_muzzle_name"
            and cand.lfwd:Dot(lsrc.ldir) < ATTACH_FACING_DOT then
            if dbg then
                dbg[#dbg + 1] = { id = id, name = cand.name or "?", score = 9999, perp = -1, method = "rejected_facing", tag = lsrc.tag }
            end
            return
        end

        local limit = perpLimit or (lsrc.ldir and MAX_RAY_PERP or MAX_NAMED_DIST)
        local score, perp = scoreCandidate(cand.lpos, lsrc.lpos, lsrc.ldir, limit, alongMin or RAY_ALONG_MIN, alongMax or RAY_ALONG_MAX)
        if not score then return end

        score = score - (bonus or 0)

        if dbg then
            dbg[#dbg + 1] = { id = id, name = cand.name or "?", score = score, perp = perp, method = method, tag = lsrc.tag }
        end

        -- Strictly-better wins: candidates from the RAW frame (scanned
        -- first) win exact ties — wrong compensation can never displace a
        -- valid raw fit.
        if not best or score < best.score then
            second = best
            best = { id = id, score = score, perp = perp, method = method, cand = cand, hyp = lsrc.hyp }
        elseif not second or score < second.score then
            second = { id = id, score = score, perp = perp, method = method, cand = cand, hyp = lsrc.hyp }
        end
    end

    for h = 1, #hyps do
        local hyp = hyps[h]

        -- The dummy is NEVER re-posed (see its declaration): candidates
        -- are read from its frozen reference geometry exactly as-is.
        local cands, namedSet
        cands, namedSet, candSrc = BuildCandidates(ent, cache)

        if candSrc == "degenerate" then
            return pack(0, {
                method = "degenerate",
                reason = "all attachment positions degenerate (unposed bones)",
            }, nil)
        end

        if next(cands) == nil then
            if h == #hyps then
                return pack(0, { method = "none", reason = "no attachment data available" }, nil)
            end
        else
            -- Model-space source for this frame: localize the snapshot in
            -- THIS frame's root pose, ray dir via a second WorldToLocal.
            local lpos = WorldToLocal(muzzlePos, angle_zero, hyp.rpos, hyp.rang)
            local ldir = nil
            if dir then
                local lpos2 = WorldToLocal(muzzlePos + dir, angle_zero, hyp.rpos, hyp.rang)
                local d = lpos2 - lpos
                if d:LengthSqr() > 1e-6 then
                    ldir = d:GetNormalized()
                end
            end
            local lsrc = { lpos = lpos, ldir = ldir, tag = hyp.tag, hyp = hyp }

            if effectAtt and cands[effectAtt] then
                consider(effectAtt, cands[effectAtt], lsrc, "effectdata",
                    EFFECTDATA_BONUS, MAX_EFFECTDATA_PERP, -MAX_EFFECTDATA_DIST, MAX_EFFECTDATA_DIST)
            end

            if lvsNameId and cands[lvsNameId] then
                consider(lvsNameId, cands[lvsNameId], lsrc, "lvs_muzzle_name", LVS_NAME_BONUS)
            end

            for id, cand in pairs(cands) do
                if id ~= effectAtt and id ~= lvsNameId then
                    if namedSet[id] then
                        local bonus = string.find(string.lower(cand.name), "muzzle", 1, true) and MUZZLE_NAME_BONUS or 0
                        consider(id, cand, lsrc, lsrc.ldir and "named_ray" or "named_nearest", bonus)
                    else
                        local limit = lsrc.ldir and MAX_RAY_PERP or MAX_GENERIC_DIST
                        consider(id, cand, lsrc, lsrc.ldir and "nearest_ray" or "nearest", 0, limit)
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

    local authoritative = best.method == "effectdata" or best.method == "lvs_muzzle_name"

    -- Ambiguity gate: two different ids fitting near-equally → the pick is
    -- a coin flip → decline, world-spawn at the point.
    if not authoritative
        and second and second.id ~= best.id
        and (second.score - best.score) <= AMBIGUITY_GAP then
        return pack(0, {
            method = "ambiguous",
            reason = "near-tie between " .. tostring(best.cand.name) .. " and " .. tostring(second.cand.name),
            dist = best.perp,
        }, best.hyp)
    end

    -- Attach-vs-world gate: a flash visibly displaced from the firing
    -- point reads as the wrong attachment → world-spawn AT the point.
    if not authoritative and (best.perp or 0) > ATTACH_PERP_MAX then
        return pack(0, {
            method = "world",
            reason = string.format("best candidate '%s' %.0fu off the muzzle point", tostring(best.cand.name), best.perp or -1),
            dist = best.perp,
        }, best.hyp)
    end

    -- The id must exist on the REAL entity too (should, same model).
    if not LVS_GRED_FX.ValidAttachment(ent, best.id) then
        return pack(0, {
            method = "world",
            reason = "winning id invalid on the live entity",
            dist = best.perp,
        }, best.hyp)
    end

    return pack(best.id, {
        method = best.method,
        dist   = best.perp,
        name   = best.cand.name,
    }, best.hyp)
end
