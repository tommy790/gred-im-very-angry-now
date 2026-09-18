--[[---------------------------------------------------------------------------
    LVS → Gredwitch FX : debug logging (client-side)

    All debug output is gated on the lvs_gred_fx_debug cvar and additionally
    rate-limited so high-frequency events (tracer records, impacts from many
    vehicles) can never flood the console. Identical repeated messages are
    additionally throttled via DebugOnce(key, ...).
-----------------------------------------------------------------------------]]

if not CLIENT then return end

local cfg = LVS_GRED_FX and LVS_GRED_FX.Config
if not cfg then return end

local MAX_LINES_PER_SEC = 30

local budgetStart = 0
local budgetUsed   = 0
local dropped      = 0
local onceLast     = {}

local function CanLog()
    local now = CurTime()
    if now - budgetStart >= 1 then
        if dropped > 0 then
            print("[lvs_gred_fx] (debug log suppressed " .. dropped .. " lines this second)")
        end
        budgetStart = now
        budgetUsed  = 0
        dropped     = 0
    end
    if budgetUsed >= MAX_LINES_PER_SEC then
        dropped = dropped + 1
        return false
    end
    budgetUsed = budgetUsed + 1
    return true
end

function LVS_GRED_FX.Debug(...)
    if not cfg.DebugEnabled() then return end
    if not CanLog() then return end
    print("[lvs_gred_fx]", ...)
end

-- Throttle repeated messages sharing the same key (max once per 2 seconds).
function LVS_GRED_FX.DebugOnce(key, ...)
    if not cfg.DebugEnabled() then return end
    if not isstring(key) then key = tostring(key) end
    local last = onceLast[key]
    local now = CurTime()
    if last and now - last < 2 then return end
    onceLast[key] = now
    LVS_GRED_FX.Debug(...)
end

-- One-time error reporting (never spams the same error twice).
local reportedErrors = {}

function LVS_GRED_FX.ReportError(context, err)
    if not isstring(context) then context = tostring(context) end
    if reportedErrors[context] then return end
    reportedErrors[context] = true
    ErrorNoHalt("[lvs_gred_fx] " .. context .. " failed: " .. tostring(err) .. "\n")
end
