_addon.name     = 'StunLock'
_addon.author   = 'Nsane'
_addon.version  = '2022.06.18'
_addon.commands = {'stunlock', 'sl'}

local packets = require('packets')
local res     = require('resources')

-- Runtime state
local restun_enabled     = true         -- Re-stun toggle
local start_with_stun_on = false        -- Start-with-stun (auto on claim) toggle
local stunned_once       = {}           -- mob_id -> true if we've already auto-stunned this mob

-- Small helpers
local function player() return windower.ffxi.get_player() end
local function items()  return windower.ffxi.get_items()  end
local function mob_by_id(id) return id and windower.ffxi.get_mob_by_id(id) or nil end
local function current_target() return windower.ffxi.get_mob_by_target('t') end

local function has_job(job)
    local p = player(); if not p then return false end
    return p.main_job == job or p.sub_job == job
end

local function main_job_is(job)
    local p = player(); if not p then return false end
    return p.main_job == job
end

-- UI feedback
local function print_status()
    windower.add_to_chat(207, ('[StunLock] Re-stun: %s | Start w/ stun: %s')
        :format(restun_enabled and 'ON' or 'OFF', start_with_stun_on and 'ON' or 'OFF'))
end
local function set_restun(state) restun_enabled = state and true or false; print_status() end
local function toggle_restun()   restun_enabled = not restun_enabled;    print_status() end
local function set_sws(s)        start_with_stun_on = s and true or false; print_status() end
local function toggle_sws()      start_with_stun_on = not start_with_stun_on; print_status() end

-- Range checks
local RANGES = { STUN = 20, SUDDEN_LUNGE = 6, WS = 4 }

local function target_in_range(base_range, id)
    local t = id and mob_by_id(id) or current_target(); if not t then return false end
    local dist2 = t.distance or math.huge
    local size  = t.model_size or 0
    local max   = base_range + size
    return dist2 <= (max * max)
end

-- Spell helpers
local function knows_spell(name, known)
    local sp = res.spells:with('english', name)
    return sp and known and known[sp.id] == true or false
end

local function spell_ready(name, recasts, mp)
    local sp = res.spells:with('english', name)
    if not sp then return false end
    return (recasts[sp.id] or 1) == 0 and mp >= (sp.mp_cost or 0)
end

-- Weapon skill helpers
local function knows_ws(name, learned_set)
    local ws = res.weapon_skills:with('english', name)
    return ws and learned_set and learned_set[ws.id] == true or false
end

local function tp_enough(min_tp)
    local p = player(); if not p then return false end
    return (p.vitals and p.vitals.tp or 0) >= (min_tp or 1000)
end

local WS_BY_WEAPON = {
    ["Hand-to-Hand"] = {"Shoulder Tackle"},
    ["Polearm"]      = {"Leg Sweep"},
    ["Sword"]        = {"Flat Blade"},
    ["Axe"]          = {"Smash Axe"},
    ["Great Katana"] = {"Tachi: Hobaku"},
}

local function equipped_item_id(bag, slot)
    if not bag or not slot or bag == 0 or slot == 0 then return nil end
    local e = windower.ffxi.get_items(bag, slot)
    return e and e.id or nil
end

local function weapon_skill_type()
    local it = windower.ffxi.get_items(); if not it or not it.equipment then return nil end
    local id = equipped_item_id(it.equipment.main_bag, it.equipment.main)
    if not id or id == 0 then return nil end
    local item = res.items[id]; if not item or not item.skill then return nil end
    local skill = res.skills[item.skill]
    return skill and skill.english or nil
end

local function pick_stun_ws_by_weapon(learned_set)
    local wtype = weapon_skill_type(); if not wtype then return nil end
    local choices = WS_BY_WEAPON[wtype]; if not choices then return nil end
    for i = 1, #choices do
        local name = choices[i]
        if knows_ws(name, learned_set) then return name end
    end
    return nil
end

-- Claim helpers
local function alliance_member_ids()
    local ids = {}
    local pt = windower.ffxi.get_party() or {}
    local slots = {'p0','p1','p2','p3','p4','p5','a10','a11','a12','a13','a14','a15','a20','a21','a22','a23','a24','a25'}
    for _, key in ipairs(slots) do
        local m = pt[key]
        if m then
            local id = (m.mob and m.mob.id) or m.id
            if id then ids[id] = true end
        end
    end
    return ids
end

-- Stun execution
-- Priority: Sudden Lunge (BLU) -> Stun (DRK/BLM) -> WS based on weapon
local function try_cast_spells_first(target_id)
    local p = player(); if not p then return false end
    local mp = p.vitals and p.vitals.mp or 0
    local recasts = windower.ffxi.get_spell_recasts() or {}
    local known = windower.ffxi.get_spells()

    if main_job_is('BLU') and target_in_range(RANGES.SUDDEN_LUNGE, target_id) then
        if knows_spell("Sudden Lunge", known) and spell_ready("Sudden Lunge", recasts, mp) then
            windower.send_command(('input /ma "Sudden Lunge" %d'):format(target_id))
            return true
        end
    end

    if (has_job('BLM') or has_job('DRK')) and target_in_range(RANGES.STUN, target_id) then
        if knows_spell("Stun", known) and spell_ready("Stun", recasts, mp) then
            windower.send_command(('input /ma "Stun" %d'):format(target_id))
            return true
        end
    end

    return false
end

local function try_ws_if_tp(target_id)
    if not tp_enough(1000) or not target_in_range(RANGES.WS, target_id) then return false end
    local abil = windower.ffxi.get_abilities() or {}
    local learned = abil.weapon_skills or {}
    local learned_set = {}
    for i = 1, #learned do learned_set[learned[i]] = true end
    local ws = pick_stun_ws_by_weapon(learned_set); if not ws then return false end
    windower.send_command(('input /ws "%s" %d'):format(ws, target_id))
    return true
end

local function do_stun_action(target_id)
    if not restun_enabled then return end
    if try_cast_spells_first(target_id) then return end
    try_ws_if_tp(target_id)
end

-- Re-stun trigger:
local function get_param1(act)
    return act.Param or act['Param 1'] or act.Param_1 or act.Param1
end

windower.register_event('incoming chunk', function(id, data)
    if id ~= 0x029 then return end
    local act = packets.parse('incoming', data); if not act then return end
    if act.Message ~= 204 then return end
    if get_param1(act) ~= 10 then return end
    local me = windower.ffxi.get_player()
    if me and act.Actor == me.id and act.Target then
        do_stun_action(act.Target)
    end
end)

-- Start-with-stun:
local function cleanup_stunned_once()
    for id, _ in pairs(stunned_once) do
        local m = mob_by_id(id)
        if not m or not m.valid_target or m.hpp == 0 then
            stunned_once[id] = nil
        end
    end
end

windower.register_event('prerender', function()
    if not start_with_stun_on or not restun_enabled then return end
    cleanup_stunned_once()

    local mobs = windower.ffxi.get_mob_array(); if not mobs then return end
    local ally_ids = alliance_member_ids()

    for _, m in pairs(mobs) do
        if m and m.is_npc and m.valid_target and m.hpp > 0 then
            local claim = m.claim_id or 0
            if claim ~= 0 and ally_ids[claim] and not stunned_once[m.id] then
                stunned_once[m.id] = true
                do_stun_action(m.id)
            end
        end
    end
end)

-- Commands:
--   //sl on/off/status   -> control re-stun
--   //sl sws on/off      -> control start-with-stun
-- Same for //stunlock

windower.register_event('addon command', function(cmd, arg, arg2)
    cmd  = (cmd  or ''):lower()
    arg  = (arg  or ''):lower()
    arg2 = (arg2 or ''):lower()

    -- base toggles
    if cmd == '' or cmd == 'toggle' then toggle_restun(); return end
    if cmd == 'on'  or arg == 'on'  then set_restun(true);  return end
    if cmd == 'off' or arg == 'off' then set_restun(false); return end
    if cmd == 'status' or arg == 'status' then print_status(); return end

    -- subcommand: sws
    if cmd == 'sws' or arg == 'sws' then
        local sub = arg2 ~= '' and arg2 or (arg ~= 'sws' and arg or '')
        if sub == '' or sub == 'toggle' then toggle_sws(); return end
        if sub == 'on'  then set_sws(true);  return end
        if sub == 'off' then set_sws(false); return end
        toggle_sws(); return
    end

end)
