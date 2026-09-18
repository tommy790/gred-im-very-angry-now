--[[---------------------------------------------------------------------------
    LVS → Gredwitch FX : tracer system (client-side)

    HOW TRACERS RENDER NOW (speed/drop-exact):

      * Clients RUNNING this addon render the beam themselves: every frame we
        draw a gred-flavored tracer beam at the LIVE client-simulated LVS
        bullet position/direction (bullet:GetPos()/GetDir()) — the exact same
        data LVS's own lvs_tracer_* effects use. The beam follows the real
        bullet, so SPEED and DROP always match, including ballistic arcs
        (LVS re-derives bullet:GetDir() from the arc on every sim step).
      * Clients WITHOUT the addon still get the static gred beam from the
        server's gred_net_createtracer relay (sv_tracer.lua). That gred beam
        is a one-shot CP0→CP1 line particle with a FIXED per-caliber crossing
        speed and no gravity — it can never match LVS velocity/drop, which is
        why addon clients are excluded from the relay via the
        lvs_gred_fx_client_ready handshake.

    This module also keeps its original duties:

      * SUPPRESSES the original LVS tracer visual (we render instead),
      * keeps the LVS wrapper instance alive while the LVS bullet exists, so
        the override wrapper's silent original Think keeps firing
        lvs_bullet_impact_ap at LVS's exact timing and decides when the
        tracer is over,
      * records each shot (entity, muzzle position, tracer name, mapping) so
        the muzzle-flash system can pair the correct PCF and the impact
        system can pick the correct caliber.
-----------------------------------------------------------------------------]]

if not CLIENT then return end

local cfg = LVS_GRED_FX.Config
local Debug = LVS_GRED_FX.Debug

LVS_GRED_FX_TRACER = LVS_GRED_FX_TRACER or {}

-- Recent shots per entity (weak keys). Bounded per entity; used to pair
-- muzzle flashes and to infer caliber for impacts.
local RECENT = setmetatable({}, { __mode = "k" })
local RECENT_MAX_PER_ENT = 8
-- Pairing window for muzzle-flash ↔ tracer records. 0.15s was too tight on
-- laggy multiplayer / heavy frames: the muzzle effect missed its tracer
-- record, no mapping paired, and barrel smoke (which needs the tracer's
-- smoke list) silently never spawned. 0.3s is still far below any sane fire
-- interval for two DIFFERENT weapon types on the same vehicle.
local RECENT_WINDOW = 0.3

-- Last shot per entity, no expiry — cheap caliber inference for impacts.
local LAST_SHOT = setmetatable({}, { __mode = "k" })

-- Last caliber fired by ANY entity. LVS fires lvs_bullet_impact / AP impact
-- with the HIT surface as the entity (not the shooter), so the per-entity
-- lookup cannot find the caliber there. This global fallback restores the
-- old addon's behavior: contextless impacts still get the caliber of the
-- most recent shot.
local LAST_CALIBER = "20mm"

local function getList(ent)
    local list = RECENT[ent]
    if not list then
        list = {}
        RECENT[ent] = list
    end
    return list
end

-- Record a shot so the muzzle flash and impact systems can pair with it.
function LVS_GRED_FX_TRACER.NoteShot(ent, name, srcPos, map)
    if not IsValid(ent) then return end

    local rec = {
        time   = CurTime(),
        name   = name,
        srcPos = srcPos,
        map    = map,
    }

    if map and map.caliber then
        LAST_CALIBER = map.caliber
    end

    local list = getList(ent)
    list[#list + 1] = rec
    if #list > RECENT_MAX_PER_ENT then
        table.remove(list, 1)
    end

    LAST_SHOT[ent] = rec

    if cfg.DebugEnabled() then
        Debug("tracer recorded:", name, "ent:", ent:GetClass(),
            "caliber:", map and map.caliber or "?", "src:", tostring(srcPos))
    end
end

-- Find the most recent shot for `ent` whose source position is close to
-- `muzzlePos` (within 256 units). Passing a nil muzzlePos returns the newest
-- recent record for the entity.
function LVS_GRED_FX_TRACER.RecentShot(ent, muzzlePos)
    if not IsValid(ent) then return nil end

    local list = RECENT[ent]
    if not list then return nil end

    local now = CurTime()
    local best, bestD = nil, nil

    for i = #list, 1, -1 do
        local rec = list[i]
        if not rec or (now - rec.time) > RECENT_WINDOW then
            table.remove(list, i)
        else
            local d
            local matched = false
            if isvector(muzzlePos) and isvector(rec.srcPos) then
                d = rec.srcPos:DistToSqr(muzzlePos)
                matched = d <= 65536 -- 256 units association
            else
                d = i
                matched = true
            end
            if matched and (not bestD or d < bestD) then
                best, bestD = rec, d
            end
        end
    end

    return best
end

-- Caliber string for impact effects, inferred from the last shot of `ent`,
-- falling back to the most recent shot fired by any entity.
function LVS_GRED_FX_TRACER.CaliberFor(ent)
    if IsValid(ent) then
        local rec = LAST_SHOT[ent]
        if rec and rec.map and rec.map.caliber then
            return rec.map.caliber
        end
        rec = LVS_GRED_FX_TRACER.RecentShot(ent, nil)
        if rec and rec.map and rec.map.caliber then
            return rec.map.caliber
        end
    end
    return LAST_CALIBER
end

local function getBullet(id)
    if LVS and LVS.GetBullet then
        return LVS:GetBullet(id)
    end
    return nil
end

--[[---------------------------------------------------------------------------
    Tracer effect lifecycle. `data` is the LVS tracer EffectData:
      Origin        = bullet.Src (world muzzle position)
      Normal        = bullet.Dir
      MaterialIndex = LVS bullet index

    The visual beam is rendered by the gred base from the server's
    gred_net_createtracer message; this handler only suppresses the LVS
    tracer visual and keeps the instance alive for LVS's own timing.
-----------------------------------------------------------------------------]]
function LVS_GRED_FX_TRACER.Init(name, self, data)
    self._gmode = "tracer"

    local bulletID = 0
    if data.GetMaterialIndex then
        bulletID = data:GetMaterialIndex() or 0
    end
    self._bulletID = bulletID

    local bullet = getBullet(bulletID)

    local srcPos = isvector(data:GetOrigin()) and data:GetOrigin() or nil
    if not srcPos and bullet then
        srcPos = bullet.Src
    end

    local dir = data.GetNormal and data:GetNormal() or nil

    local ent = bullet and bullet.Entity
    if not IsValid(ent) then
        ent = data.GetEntity and data:GetEntity() or nil
    end

    local map = cfg.Tracers[name] or cfg.TracerDefaults

    -- Beam style for the bullet-following renderer (color + caliber-graded
    -- length/width from config).
    self._gcol = cfg.TracerBeamColors[(map and map.color) or "white"]
        or cfg.TracerBeamColors.white
    self._gstyle = cfg.TracerBeamByCaliber[(map and map.caliber) or "20mm"]
        or { len = 1100, width = 3 }
    self._gdir = isvector(dir) and dir or (bullet and bullet.Dir) or nil

    -- Effects are only rendered when their bounds intersect the view; a
    -- tracer covers a huge flight volume (LVS's own tracer effects set the
    -- same 50000u render bounds).
    if isvector(srcPos) and self.SetRenderBoundsWS then
        local bdir = self._gdir or Vector(0, 0, 1)
        self:SetRenderBoundsWS(srcPos, srcPos + bdir * 50000)
    end

    -- Record the shot for muzzle-flash pairing and impact caliber inference.
    if IsValid(ent) and isvector(srcPos) then
        LVS_GRED_FX_TRACER.NoteShot(ent, name, srcPos, map)
    end

    -- The LVS tracer visual stays suppressed — we render in Render(). The
    -- wrapper's silent original Think still drives the lifetime and fires
    -- lvs_bullet_impact_ap when the bullet is gone.
    return true
end

function LVS_GRED_FX_TRACER.Think(self)
    -- Keep the effect instance alive while the LVS bullet exists so the
    -- wrapper's silent original Think can fire lvs_bullet_impact_ap and
    -- decide the exact end of the tracer. Once the bullet is gone, LVS says
    -- the tracer is over too.
    if not getBullet(self._bulletID) then
        LVS_GRED_FX_TRACER.Stop(self)
        return false
    end
    return true
end

function LVS_GRED_FX_TRACER.Stop(self)
    -- No client-owned particle system; nothing to stop.
end

--[[---------------------------------------------------------------------------
    Bullet-following beam renderer (the speed/drop-exact path).

    Draws exactly where the LIVE client-simulated LVS bullet is, along its
    CURRENT flight direction — the same data LVS's own lvs_tracer_* effects
    use (lvs_tracer_white.lua: bullet:GetPos()/GetDir()/GetLength() every
    frame). Speed and drop therefore match the bullet by construction,
    including ballistic arcs.

    The look mirrors LVS's own tracer: a short bright beam trailing behind
    the bullet head, drawn as outer glow + hot core.
-----------------------------------------------------------------------------]]
local beamMatCache = nil

local function BeamMaterial()
    if beamMatCache then return beamMatCache end

    local candidates = cfg.TracerBeamMaterials or { "effects/lvs_base/spark" }
    local mat
    for i = 1, #candidates do
        local m = Material(candidates[i])
        if not m:IsError() then
            mat = m
            break
        end
    end

    beamMatCache = mat or Material("effects/lvs_base/spark")
    return beamMatCache
end

function LVS_GRED_FX_TRACER.Render(self)
    local bullet = getBullet(self._bulletID)
    if not bullet then return end

    local pos = bullet.GetPos and bullet:GetPos() or bullet.Src
    local dir = bullet.GetDir and bullet:GetDir() or bullet.Dir or self._gdir
    if not isvector(pos) or not isvector(dir) then return end
    if dir:LengthSqr() < 0.01 then return end

    -- Same growth-in as LVS: shortens the beam for the first ~70ms of flight
    -- so it doesn't streak across the whole map on frame one.
    local grow = bullet.GetLength and bullet:GetLength() or 1

    local style = self._gstyle
    if not istable(style) then
        style = { len = 1100, width = 3 }
    end

    local col = self._gcol or color_white

    local len = style.len * grow
    local tail = pos - dir * len
    local head = pos + dir * len * 0.05 -- tiny hot overshoot at the head

    render.SetMaterial(BeamMaterial())
    -- outer glow, then hot core (gred beams read as bright core + halo)
    render.DrawBeam(tail, head, style.width * 3.5, 0, 1, Color(col.r, col.g, col.b, 70))
    render.DrawBeam(tail, head, style.width, 0, 1, Color(col.r, col.g, col.b, 255))
end

--[[---------------------------------------------------------------------------
    Server handshake: announce that this client renders its own tracers, so
    the server relay (sv_tracer.lua) excludes us from the static gred beam.
-----------------------------------------------------------------------------]]
hook.Add("InitPostEntity", "lvs_gred_fx_client_ready", function()
    net.Start("lvs_gred_fx_client_ready")
    net.SendToServer()
end)
