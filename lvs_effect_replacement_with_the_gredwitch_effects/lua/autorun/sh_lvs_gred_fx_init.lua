--[[---------------------------------------------------------------------------
    LVS → Gredwitch FX : shared init.

    Visual replacement logic is client-side. The single server-side module is
    a purely visual tracer relay: after every mapped LVS shot it sends gred's
    own gred_net_createtracer message so the Gredwitch base renders the tracer
    beam on clients (the proven mechanism from the original addon). LVS
    damage, ballistics, projectile physics, weapon logic, vehicle physics,
    networking and firing mechanics all run untouched.

    Client modules are shipped via AddCSLuaFile and included by
    autorun/client/cl_lvs_gred_fx_override.lua in dependency order. The server
    module is included only on the server.
-----------------------------------------------------------------------------]]

local CLIENT_FILES = {
    "lvs_gred_fx/config.lua",
    "lvs_gred_fx/debug.lua",
    "lvs_gred_fx/particles.lua",
    "lvs_gred_fx/muzzle.lua",
    "lvs_gred_fx/tracer.lua",
    "lvs_gred_fx/muzzleflash.lua",
    "lvs_gred_fx/barrelsmoke.lua",
    "lvs_gred_fx/impacts.lua",
    "lvs_gred_fx/trails.lua",
    "lvs_gred_fx/bridge.lua",
    "lvs_gred_fx/effect_list.lua",
    "autorun/client/cl_lvs_gred_fx_override.lua",
}

for _, file in ipairs(CLIENT_FILES) do
    AddCSLuaFile(file)
end

if SERVER then
    include("lvs_gred_fx/sv_tracer.lua")
end
