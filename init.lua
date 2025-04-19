local modname = core.get_current_modname()
local S = core.get_translator(modname)
local storage = core.get_mod_storage()

local banned_words = {}

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

local function load_banned_words()
    log_info("Loading banned words from storage...")
    banned_words = {}
    local fields = storage:to_table().fields
    for key, value in pairs(fields) do
        if value ~= "" then
            local ok, data = pcall(core.parse_json, value)
            if ok and type(data) == "table" and data.word then
                local uw = data.word:upper()
                banned_words[uw] = data
                log_debug(string.format("Loaded: '%s' by %s at %s", uw, data.author, data.time))
            else
                banned_words[key:upper()] = { word = key:upper(), time = "unknown", author = "unknown" }
                log_warning("Invalid JSON for key '" .. key .. "'; defaulting word to uppercase key")
            end
        end
    end
    log_info(string.format("Total banned words loaded: %d", #(
        (function() local t={} for _ in pairs(banned_words) do table.insert(t,1) end return t end)()
    )))
end
load_banned_words()

local function add_banned_word(word, author)
    local uw = word:upper()
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    local data = { word = uw, time = timestamp, author = author }
    local ok, json = pcall(core.write_json, data)
    if not ok then
        log_warning("Failed to serialize banned word: " .. uw)
        return false
    end
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
    for uw, data in pairs(banned_words) do
        local pattern = "%f[%a]" .. uw:lower() .. "%f[%A]"
        if lt:find(pattern) then
            log_debug("Detected banned word '" .. uw .. "' in text: " .. text)
            return uw
        end
    end
    log_debug("No banned words found in text: " .. text)
    return nil
end

local function get_filter_formspec(selected, text)
    selected = selected or 0
    text = text or ""

    local key_list = {}
    for uw in pairs(banned_words) do table.insert(key_list, uw) end
    table.sort(key_list)

    local display = {}
    for _, uw in ipairs(key_list) do
        table.insert(display, core.formspec_escape(uw:lower()))
    end
    local items = table.concat(display, ",")

    local fs = table.concat({
        "size[9,6]",
        "tabheader[0,0;filter_tab;Server Filter;1;true;true]",
        "field_close_on_enter[word;false]",
        ("textlist[0,0;3,6;banned_words;%s;%d]"):format(items, selected),
        ("field[3.5,0.25;5,1;word;;%s]"):format(core.formspec_escape(text)),
        ("button[3.25,1;2,0.7;add;%s]"):format(core.formspec_escape(S("Add"))),
        ("button[5.25,1;2,0.7;remove;%s]"):format(core.formspec_escape(S("Remove"))),
    }, "")

    if selected > 0 then
        local uw = key_list[selected]
        local meta = banned_words[uw]
        local info = S("Added on @1 by @2", meta.time, meta.author)
        fs = fs .. ("hypertext[3.5,2;5,1;info;%s]"):format(core.formspec_escape(info))
    end

    local count = #key_list
    local count_text = S("Number of banned words : @1", count)
    fs = fs .. ("label[3.25,5.65;%s]"):format(core.formspec_escape(count_text))

    return fs
end

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
    local bw = contains_banned_word(message)
    if bw then
        core.chat_send_player(name,
            core.colorize("red", S("Your message was deleted due to banned word '@1'.", bw:lower()))
        )
        log_warning("Player '" .. name .. "' used banned word: " .. bw)
        return true
    end
end)

core.register_on_prejoinplayer(function(name, ip)
    log_debug("Prejoin check for '" .. name .. "' (IP: " .. ip .. ")")
    local bw = contains_banned_word(name)
    if bw then
        log_warning("Player '" .. name .. "' tried to join with banned word: " .. bw)
        return S("Your username contains banned word '@1'.", bw)
    end
end)

core.register_on_player_receive_fields(function(player, form, fields)
    if form ~= modname .. ":filter" then return end
    local name = player:get_player_name()
    log_debug("Forms received from '" .. name .. "': " .. core.serialize(fields))

    if fields.key_enter_field == "word" and fields.word then
        fields.add = true
    end

    if fields.banned_words then
        local ev = core.explode_textlist_event(fields.banned_words)
        if ev.type == "CHG" then
            log_debug(string.format("Selection changed to index %d", ev.index))
            local key_list = {}
            for uw in pairs(banned_words) do table.insert(key_list, uw) end
            table.sort(key_list)
            local selected_word = key_list[ev.index] or ""
            core.show_formspec(name, form, get_filter_formspec(ev.index, selected_word:lower()))
        end
        return
    end

    if fields.add and fields.word then
        local word = fields.word:trim()
        if word == "" then
            core.chat_send_player(name,
                core.colorize("red", S("Cannot add empty word."))
            )
        else
            local uw = word:upper()

            if banned_words[uw] then
                core.chat_send_player(name,
                    core.colorize("#e7dd12", S("Word '@1' already exists.", word:lower()))
                )
            else
                if add_banned_word(word, name) then
                    local key_list = {}
                    for uw2 in pairs(banned_words) do table.insert(key_list, uw2) end
                    table.sort(key_list)
                    local idx = table.indexof(key_list, uw) or 0
                    core.show_formspec(name, form, get_filter_formspec(idx, uw:lower()))
                end
            end
        end
        return
    end

    if fields.remove and fields.word then
        local key_list = {}
        for uw in pairs(banned_words) do table.insert(key_list, uw) end
        table.sort(key_list)
        local rem_word = fields.word:upper()
        local rem_index
        for idx, uw in ipairs(key_list) do
            if uw == rem_word then
                rem_index = idx
                break
            end
        end
        if remove_banned_word(fields.word) then
            local new_list = {}
            for uw in pairs(banned_words) do table.insert(new_list, uw) end
            table.sort(new_list)
            local new_sel = (rem_index or 2) - 1
            if new_sel < 1 and #new_list > 0 then
                new_sel = 1
            elseif #new_list == 0 then
                new_sel = 0
            elseif new_sel > #new_list then
                new_sel = #new_list
            end
            local new_text = ""
            if new_sel > 0 then
                new_text = new_list[new_sel]:lower()
            end
            core.show_formspec(name, form, get_filter_formspec(new_sel, new_text))
        else
            core.chat_send_player(name,
                core.colorize("red",
                    S("Word '@1' not found in list.", fields.word)
                )
            )
        end
    end
end)
