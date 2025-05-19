local modname = core.get_current_modname()
local S = core.get_translator(modname)
local storage = core.get_mod_storage()

local banned_words = {}
local warn_stats = {}

local function log_info(text)
    core.log("info", text)
end

local function log_debug(text)
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    local formatted = timestamp .. ": DEBUG[Server]: " .. text
    core.log("verbose", formatted)
end

local function log_warning(text)
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    local formatted = timestamp .. ": WARNING[Server]: " .. text
    core.log("warning", formatted)
    return core.colorize("#e7dd12", formatted)
end

local function load_data()
    log_info("Loading banned words and warning stats from storage...")
    banned_words = {}
    local fields = storage:to_table().fields
    for key, value in pairs(fields) do
        if value ~= "" and key ~= "warn_stats" then
            local ok, data = pcall(core.parse_json, value)
            if ok and type(data) == "table" and data.word then
                local uw = data.word:upper()
                banned_words[uw] = data
                log_debug(string.format("Loaded banned word: '%s' by %s at %s", uw, data.author, data.time))
            else
                banned_words[key:upper()] = { word = key:upper(), time = "unknown", author = "unknown" }
                log_warning("Invalid JSON for key '" .. key .. "' (ignored)")
            end
        end
    end
    local raw = storage:get_string("warn_stats")
    if raw and raw ~= "" then
        local ok, data = pcall(core.parse_json, raw)
        if ok and type(data) == "table" then warn_stats = data
        else warn_stats = {}
            log_warning("Invalid warning stats JSON; resetting stats")
        end
    else warn_stats = {} end
    log_info(string.format("Total banned words: %d", # (function() local t={} for _ in pairs(banned_words) do table.insert(t,1) end return t end)()))
end

local function save_warn_stats()
    local ok, json = pcall(core.write_json, warn_stats)
    if ok then storage:set_string("warn_stats", json)
    else log_warning("Failed to serialize warning stats")
    end
end

local function add_banned_word(word, author)
    local uw = word:upper()
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    local data = { word = uw, time = timestamp, author = author }
    local ok, json = pcall(core.write_json, data)
    if not ok then log_warning("Failed to serialize banned word: " .. uw) return false end
    banned_words[uw] = data
    storage:set_string(uw, json)
    log_info(string.format("Banned word added: '%s' by %s at %s", uw, author, timestamp))
    return true
end

local function remove_banned_word(word)
    local uw = word:upper()
    if banned_words[uw] then
        banned_words[uw] = nil
        storage:set_string(uw, "")
        log_info("Banned word removed: " .. uw)
        return true
    end
    log_warning("Attempted to remove non-existent banned word: " .. uw)
    return false
end

local function contains_banned_word(text)
    local lt = text:lower()
    for uw in pairs(banned_words) do
        local pattern = "%f[%a]" .. uw:lower() .. "%f[%A]"
        if lt:find(pattern) then log_debug("Detected banned word '" .. uw .. "' in text: " .. text) return uw
        end
    end
    log_debug("No banned words found in text: " .. text)
    return nil
end

local function build_warnings_body(player_search)
    local stats_list = {}
    for player, count in pairs(warn_stats) do
        if player_search == "" or player:lower():find(player_search:lower(), 1, true) then
            table.insert(stats_list, ("%s (%d)"):format(player, count))
        end
    end
    table.sort(stats_list)
    local escaped = {}
    for _, entry in ipairs(stats_list) do
        table.insert(escaped, core.formspec_escape(entry))
    end
    local items = table.concat(escaped, ",")
    local result_count = #stats_list
    return table.concat{
        ("field[4.5,0.25;4,1;player_search;;%s]"):format(core.formspec_escape(player_search)),
        ("button[4.25,1;2,0.7;search;%s]"):format(core.formspec_escape(S("Search"))),
        ("textlist[0,0;4,6;warnings_list;%s;0]"):format(items),
        ("label[4.25,5.65;%s]"):format(core.formspec_escape(S("Results found: @1", result_count))),
    }
end

local function get_filter_formspec(tab_index, selected, word_text, player_search)
    tab_index = tab_index or 1
    selected = selected or 0
    word_text = word_text or ""
    player_search = player_search or ""
    local fs = {
        "size[9,6]",
        ("tabheader[0,0;filter_tab;Server Filter,Warnings;%d;true;true]"):format(tab_index),
    }
    if tab_index == 1 then
        local key_list = {}
        for uw in pairs(banned_words) do table.insert(key_list, uw) end
        table.sort(key_list)
        local display = {}
        for _, uw in ipairs(key_list) do
            table.insert(display, core.formspec_escape(uw:lower()))
        end
        local items = table.concat(display, ",")
        table.insert(fs, ("textlist[0,0;3,6;banned_words;%s;%d]"):format(items, selected))
        table.insert(fs, ("field[3.5,0.25;5,1;word;;%s]"):format(core.formspec_escape(word_text)))
        table.insert(fs, ("button[3.25,1;2,0.7;add;%s]"):format(core.formspec_escape(S("Add"))))
        table.insert(fs, ("button[5.25,1;2,0.7;remove;%s]"):format(core.formspec_escape(S("Remove"))))
        if selected > 0 then
            local uw = key_list[selected]
            local meta = banned_words[uw]
            table.insert(fs, ("hypertext[3.5,2;5,1;info;%s]"):format(core.formspec_escape(S("Added on @1 by @2", meta.time, meta.author))))
        end
        local count = #key_list
        table.insert(fs, ("label[3.25,5.65;%s]"):format(core.formspec_escape(S("Number of banned words: @1", count))))
    else table.insert(fs, build_warnings_body(player_search))
    end
    return table.concat(fs, "")
end

core.register_on_player_receive_fields(function(player, form, fields)
    if form ~= modname .. ":filter" then return end
    local name = player:get_player_name()
    if fields.filter_tab then
        local idx = tonumber(fields.filter_tab)
        core.show_formspec(name, form, get_filter_formspec(idx))
        return
    end
    if fields.search or fields.key_enter_field == "player_search" then
        local search = fields.player_search or ""
        local header = table.concat{
            "size[9,6]",
            "tabheader[0,0;filter_tab;Server Filter,Warnings;2;true;true]",
        }
        core.show_formspec(name, form, header .. build_warnings_body(search))
        return
    end
end)

core.register_chatcommand("filter", {
    description = S("Open filter UI."),
    privs = { ban = true },
    func = function(name)
        log_info("Player '" .. name .. "' opened filter UI")
        core.show_formspec(name, modname .. ":filter", get_filter_formspec())
        return true
    end,
})

core.register_on_chat_message(function(name, message)
    log_debug("Chat message from '" .. name .. "': " .. message)
    local banned_word = contains_banned_word(message)
    if banned_word then
        warn_stats[name] = (warn_stats[name] or 0) + 1
        save_warn_stats()
        core.chat_send_player(name, core.colorize("red", S("Your message was deleted due to banned word '@1'.", banned_word:lower())))
        log_warning("Player '" .. name .. "' used banned word: " .. banned_word)

        local player = core.get_player_by_name(name)
        if player then local hp = player:get_hp() or 0 player:set_hp(hp - 2) end -- In order to avoid massive spam
        return true
    end
end)

core.register_on_prejoinplayer(function(name, ip)
    log_debug("Prejoin check for '" .. name .. "' (IP: " .. ip .. ")")
    local banned_word = contains_banned_word(name)
    if banned_word then
        log_warning("Player '" .. name .. "' tried to join with banned word: " .. banned_word)
        return S("Your username contains banned word '@1'.", banned_word)
    end
end)

core.register_on_player_receive_fields(function(player, form, fields)
    if form ~= modname .. ":filter" then return end
    local name = player:get_player_name()
    log_debug("Forms received from '" .. name .. "': " .. core.serialize(fields))
    if fields.filter_tab then
        local ev = tonumber(fields.filter_tab)
        core.show_formspec(name, form, get_filter_formspec(ev))
        return
    elseif fields.banned_words then
        local ev = core.explode_textlist_event(fields.banned_words)
        if ev.type == "CHG" then
            local key_list = {}
            for uw in pairs(banned_words) do table.insert(key_list, uw) end
            table.sort(key_list)
            local selected_word = key_list[ev.index] or ""
            core.show_formspec(name, form, get_filter_formspec(1, ev.index, selected_word:lower()))
        end
        return
    elseif fields.add or fields.key_enter_field == "word" then
        if fields.word then
            local word = fields.word:trim()
            if word == "" then
                core.chat_send_player(name, core.colorize("red", S("Cannot add empty word.")))
            else
                local uw = word:upper()
                if banned_words[uw] then
                    core.chat_send_player(name, core.colorize("#e7dd12", S("Word '@1' already exists.", word:lower())))
                else
                    if add_banned_word(word, name) then
                        local key_list = {}
                        for uw2 in pairs(banned_words) do table.insert(key_list, uw2) end
                        table.sort(key_list)
                        local idx = table.indexof(key_list, uw) or 0
                        core.show_formspec(name, form, get_filter_formspec(1, idx, uw:lower()))
                    end
                end
            end
        end
        return
    end
    if fields.remove then
        if fields.word then
            local rem = fields.word:upper()
            remove_banned_word(rem)
            core.show_formspec(name, form, get_filter_formspec(1))
        end
        return
    elseif fields.search or fields.key_enter_field == "player_search" then
        local search = fields.player_search or ""
        core.show_formspec(name, form, get_filter_formspec(2, 0, nil, search))
        return
    end
end)

load_data()