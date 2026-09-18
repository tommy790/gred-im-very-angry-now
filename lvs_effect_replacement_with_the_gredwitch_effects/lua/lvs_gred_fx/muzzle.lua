--[[---------------------------------------------------------------------------
    LVS → Gredwitch FX : muzzle attachment resolution (client-side)

    STATIONARY POSE-MATCHED TWIN (5th generation).

    History of the bug: point-distance picked wrong ids; ray-fit on live
    attachments picked better but still wrong when live pose data was stale
    or garbage (server snapshot evaluated ping/2+interp later against moved
    bones; some LVS models return unposed/unnamed attachment data on the
    live entity — BRDM-2's id 21 with attName "?" being the proof); a blind
    cache then froze whatever won; and the first dummy design identified
    attachments in the dummy's REFERENCE pose while the real turret was
    traversed — the model-space ray then swept across the hull and glued to
    whatever attachment happened to lie in its path.

    The current design:

      RENDER A MODEL THAT IS NOT MOVING — BUT POSE IT LIKE THE REAL ONE.
      For each model we lazily spawn a hidden, stationary ClientsideModel
      copy far below the map. Before scoring, we MIRROR THE REAL ENTITY'S
      POSE onto it: all pose parameters (LVS drives turrets with
      SetPoseParameter — aim_yaw/aim_pitch/vehicle_steer ... the turret
      BONE follows the pose parameter) and any bone manipulations. The
      dummy stays world-stationary (no velocity, no interpolation, no
      garbage pose data) but its turret sits at the SAME angle as the real
      one — apples to apples at any traverse.

      SCORE IN MODEL SPACE, EVERY SHOT. The muzzle snapshot is converted
      into the live entity's local frame (per hypothesis: raw + rigidly
      motion-compensated; the better fit wins, raw wins ties) and ray-scored
      against the posed dummy's attachment geometry. Geometry is memoized
      per resolve, so scoring is cheap; NOTHING about identification is
      cached across shots — a cache hit from a different turret angle is
      exactly the 'wrong id' this file exists to kill. (Static metadata —
      the attachment id/name list — is still cached per model; it never
      changes.)

      APPLY ONTO THE REAL MODEL. Attachment ids are model-static: the
      winning id is used with PATTACH_POINT_FOLLOW on the REAL entity,
      whose live turret bones the particle then follows exactly. Models
      with no true muzzle attachment calibrate to a world-space spawn at
      the live muzzle point — always at the firing barrel, never a wrong
      attachment.

    Gates:
      * ambiguity: two different ids fitting near-equally → world-spawn
        (a coin-flip glue IS the 'wrong id');
      * attach distance: named/generic candidate perp over ATTACH_PERP_MAX
        → world-spawn (a flash 10u+ off the muzzle point reads as wrong);
      * authoritative ids (EffectData attachment, LVS
        TurretBallisticsMuzzleAttachment) bypass both gates;
      * degenerate live-entity pose data only matters for the no-dummy
        fallback path (the posed dummy never degenerates).

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
local ATTACH_PERP_MAX     = 10   -- named/generic candidates further than this
                                 -- from the muzzle point are NOT glued (the
                                 -- BRDM-2 case: a "nearest" id 13u off).
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

-- Pose-parameter names are static per model; cached once so snapshotting
-- values every tick stays cheap. LVS drives turret bones with pose
-- parameters (aim_yaw / aim_pitch / vehicle_steer ...), so the values ARE
-- the turret traverse.
local function PoseParamNames(ent, modelCache)
    local names = modelCache.ppNames
    if names then return names end

    names = {}
    if ent.GetNumPoseParameters and ent.GetPoseParameterName then
        local n = ent:GetNumPoseParameters() or 0
        for i = 0, n - 1 do
            local name = ent:GetPoseParameterName(i)
            if name then names[i + 1] = name end
        end
    end

    modelCache.ppNames = names
    return names
end

-- Snapshot the current pose-parameter values (array parallel to names).
local function SnapshotPoseParams(ent, names)
    if #names == 0 or not ent.GetPoseParameter then return nil end

    local pp = {}
    for i = 1, #names do
        pp[i] = ent:GetPoseParameter(names[i])
    end
    return pp
end

-- Pose the dummy: with a recorded snapshot, freeze it at the FIRE-MOMENT
-- traverse (this is what makes the ray line up when the turret has moved
-- on since the shot was taken); without one, mirror the current pose.
-- Then copy any bone manipulations (addons that bypass pose parameters;
-- current values, rarely animated within a snapshot delay) and rebuild
-- the bone cache.
--
-- NO memoization: other resolvers (flash + smoke) share the same dummy on
-- the same frame and pose it for DIFFERENT hypotheses; a memo skip once
-- let a later resolve score its "current pose" frame against the stale
-- fire-moment pose the previous resolve left behind — a sweeping turret
-- then made the model-space ray sweep clean through the vehicle.
-- Mirroring is a handful of pose-parameter pokes + a bone rebuild: cheap.
local function MirrorPose(ent, dummy, modelCache, ppSnapshot)
    if not IsValid(dummy) then return end

    local names = PoseParamNames(ent, modelCache)
    if #names > 0 and dummy.SetPoseParameter then
        for i = 1, #names do
            local val = ppSnapshot and ppSnapshot[i] or (ent.GetPoseParameter and ent:GetPoseParameter(names[i])) or 0
            pcall(dummy.SetPoseParameter, dummy, names[i], val)
        end
    end

    if ent.GetManipulateBoneAngles and dummy.ManipulateBoneAngles then
        local count = modelCache.boneCount
        if count == nil then
            count = (ent.GetBoneCount and ent:GetBoneCount()) or 0
            modelCache.boneCount = count
        end

        for b = 0, count - 1 do
            local ang = ent:GetManipulateBoneAngles(b)
            if ang and (ang.p ~= 0 or ang.y ~= 0 or ang.r ~= 0) then
                pcall(dummy.ManipulateBoneAngles, dummy, b, ang)
            end

            if ent.GetManipulateBonePosition and dummy.ManipulateBonePosition then
                local pos = ent:GetManipulateBonePosition(b)
                if pos and (pos.x ~= 0 or pos.y ~= 0 or pos.z ~= 0) then
                    pcall(dummy.ManipulateBonePosition, dummy, b, pos)
                end
            end

            if ent.GetManipulateBoneScale and dummy.ManipulateBoneScale then
                local scl = ent:GetManipulateBoneScale(b)
                if scl and (scl.x ~= 1 or scl.y ~= 1 or scl.z ~= 1) then
                    pcall(dummy.ManipulateBoneScale, dummy, b, scl)
                end
            end
        end
    end

    if dummy.InvalidateBoneCache then pcall(dummy.InvalidateBoneCache, dummy) end
    if dummy.SetupBones then pcall(dummy.SetupBones, dummy) end
end

-- Attachment data of the posed dummy, expressed in MODEL space
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
local MODEL_CACHE = {} -- model → { atts, dummy, boneCount }

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
        boneCount = nil,
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

    -- Freeze the TURRET into the sample too: pose parameters drive the
    -- turret bones, so the fire-moment traverse is recoverable from
    -- history and can be replayed onto the dummy.
    local pp = nil
    local mc = ent.GetModel and GetModelCache(ent:GetModel(), ent) or nil
    if mc then
        pp = SnapshotPoseParams(ent, PoseParamNames(ent, mc))
    end

    hist[n + 1] = { t = now, pos = ent:GetPos(), ang = ent:GetAngles(), pp = pp }

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
            pp   = nil,        -- use current pose parameters
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
        if fpos:DistToSqr(muzzlePos) > COMP_MIN_SHIFT_SQR or past.pp ~= nil then
            hyps[2] = {
                tag  = "compensated",
                rpos = past.pos,
                rang = past.ang,
                pp   = past.pp,
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

        -- FREEZE THE DUMMY'S TURRET at this frame's traverse before
        -- touching its geometry: the recorded pose parameters are
        -- replayed so the ray scores against the turret as it sat in
        -- that moment, not as it sits now.
        if IsValid(cache.dummy) then
            MirrorPose(ent, cache.dummy, cache, hyp.pp)
        end

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
