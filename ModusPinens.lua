-- !!! add commands for getting waypoint history
-- !!!    add a clickable pin for each one if possible
-- !!!        can printed pins (that aren't sent over a channel) have custom text?
-- !!! let users make lists of waypoints (make sure to only play sound once if adding a bunch of pins to the map together)
-- !!! show coords in map (and on minimap?)

-- Hooks that depend on 

local PLAYER = "player"

local moduspinens_frame = CreateFrame("Frame")
moduspinens_frame.name = "Modus Pinens"

local saved_variables = {}
local saved_variables_per_character = {}

local current_waypoint -- Stores the UiMapPoint of the current waypoint (plus a printable string and a custom desc) or nil if no waypoint

local normalized_unique_map_name_to_id = {} -- Lowered and spaces removed for searching
local map_id_to_unique_name = {} -- For displaying unique names
do
    --Create unique names for each map, disambiguating using parent maps or map IDs
    -- Get the root map
    local root_map = C_Map.GetFallbackWorldMapID()
    while true do
        local parent = C_Map.GetMapInfo(root_map).parentMapID
        if parent == 0 then
            break
        else
            root_map = parent
        end
    end
    -- Invert table and store duplicates
    local map_name_to_id = {}
    local map_data = C_Map.GetMapChildrenInfo(root_map, nil, true)
    local dupes = {}
    for _, map in ipairs(map_data) do
        local id = map.mapID
        if C_Map.CanSetUserWaypointOnMap(id) then
            local name = map.name
            if name and name ~= "" then
                if map_name_to_id[name] then
                    -- Found a duplicate
                    if not dupes[name] then
                        local first_id = map_name_to_id[name]
                        dupes[name] = {{id = first_id, parent_id = first_id}} -- initialize parent_id to id
                    end
                    tinsert(dupes[name], {id = id, parent_id = id})
                else
                    -- Not a dupe
                    map_name_to_id[name] = id
                end
            else
                -- Doesn't have a name, so just use the ID
                map_name_to_id[tostring(id)] = id
            end
        end
    end
    
    -- Disambiguate duplicates
    for name, maps in pairs(dupes) do
        map_name_to_id[name] = nil -- Clear duplicates
        repeat
            -- Get the parent map IDs
            for key, map in pairs(maps) do
                local parent_id = C_Map.GetMapInfo(map.parent_id).parentMapID
                if not parent_id or parent_id == 0 then
                    -- No more parents available to disambiguate with, so suffix is map ID and we're done with this
                    local id = map.id
                    map_name_to_id[strjoin(":", name, id)] = id
                    maps[key] = nil
                else
                    map.parent_id = parent_id
                    map.suffix = C_Map.GetMapInfo(parent_id).name or ""
                end
            end
            -- Find duplicate parent IDs among the duplicate map IDs (since this means all further ancestors will be shared too)
            local parent_ids_to_maps = {}
            for key, map in pairs(maps) do
                local parent_id = map.parent_id
                if not parent_ids_to_maps[parent_id] then
                    parent_ids_to_maps[parent_id] = {}
                end
                tinsert(parent_ids_to_maps[parent_id], {key = key, map = map})
            end
            for parent_id, child_maps in pairs(parent_ids_to_maps) do
                if #child_maps > 1 then
                    -- Duplicate parent IDs, so suffix is map ID and we're done with these
                    for child_map_key, child_map in ipairs(child_maps) do
                        local id = child_map.map.id
                        map_name_to_id[strjoin(":", name, id)] = id
                        maps[child_map.key] = nil
                    end
                end
            end
            -- Find remaining duplicate suffixes
            local suffixes_to_maps = {}
            for key, map in pairs(maps) do
                local suffix = map.suffix
                if not suffixes_to_maps[suffix] then
                    suffixes_to_maps[suffix] = {}
                end
                tinsert(suffixes_to_maps[suffix], {key = key, map = map})
            end
            local found_dupe = false
            for suffix, suffixed_maps in pairs(suffixes_to_maps) do
                if #suffixed_maps == 1 and suffix ~= "" then
                    -- Suffix is unique and non-empty
                    local unique_map_entry = suffixed_maps[1]
                    map_name_to_id[strjoin(":", name, suffix)] = unique_map_entry.map.id
                    maps[unique_map_entry.key] = nil
                else
                    found_dupe = true
                end
            end
        until not found_dupe
    end
    
    -- Build the outputs for searching and displaying
    for name, id in pairs(map_name_to_id) do
        if not tonumber(name) then
            normalized_unique_map_name_to_id[strlower(gsub(name, "%s+", ""))] = id
        end
        map_id_to_unique_name[id] = name
    end
end

-- paste_in_chat(text)
-- Hook OnEnterPressed then paste into chat (for commands that fill text into edit box)
local paste_in_chat
do
    local keeping_focus = false
    local paste
    
    hooksecurefunc("ChatEdit_OnEnterPressed", function ()
        if keeping_focus then
            local edit_box = LAST_ACTIVE_CHAT_EDIT_BOX
            if C_CVar.GetCVar("chatStyle") == "classic" then
                edit_box:Show()
            end
            edit_box:SetFocus()
            edit_box:SetText(paste)
            keeping_focus = false
        end
    end)

    function paste_in_chat(text)
        paste = text
        keeping_focus = true
    end
end

-- do_after_combat(function, args...) to call protected functions once combat ends
local do_after_combat, on_player_regen_enabled
do
    local to_do_after_combat = {}
    
    function on_player_regen_enabled() -- PLAYER_REGEN_ENABLED event detects end of combat
        for func, args in pairs(to_do_after_combat) do
            func(unpack(args))
        end
        to_do_after_combat = {}
    end
    
    function do_after_combat(func, ...)
        to_do_after_combat[func] = {...}
    end
end

-- Given a map point, returns an equivalent map point on the most local child map possible
local function to_local_map(map_point)
    local map_id = map_point.uiMapID
    local map_position = map_point.position
    while true do
        local child_map = C_Map.GetMapInfoAtPosition(map_id, map_position.x, map_position.y)
        if not child_map then
            return UiMapPoint.CreateFromVector2D(map_id, map_position)
        end
        local child_map_id = child_map.mapID
        if child_map_id == map_id or not C_Map.CanSetUserWaypointOnMap(child_map_id) then
            return UiMapPoint.CreateFromVector2D(map_id, map_position)
        else
            local continent, world_position = C_Map.GetWorldPosFromMapPos(map_id, map_position)
            if not continent then
                -- We're looking at a map that doesn't convert to more local coordinates, like a cosmic map
                return UiMapPoint.CreateFromVector2D(map_id, map_position)
            else
                map_id, map_position = C_Map.GetMapPosFromWorldPos(continent, CreateVector2D(world_position.x, world_position.y), child_map_id)
            end
        end
    end
end

local function unrotate_minimap_coords(rotated_x, rotated_y)
    local theta = GetPlayerFacing()
    local sin_theta = math.sin(theta)
    local cos_theta = math.cos(theta)
    local unrotated_x = rotated_x * cos_theta - rotated_y * sin_theta
    local unrotated_y = rotated_x * sin_theta + rotated_y * cos_theta
    return unrotated_x, unrotated_y
end

-- Used to play pin sounds if the player can see the pin on their map
local function is_pin_visible_on_open_map()
    if WorldMapFrame:IsVisible() then
        local map_position = C_Map.GetUserWaypointPositionForMap(WorldMapFrame:GetMapID())
        if map_position then
            local x, y = map_position:GetXY()
            return x >= 0 and x <= 1 and y >= 0 and y <=1
        end
    end
    return false
end

-- For clicks to chat waypoint links, use adjacent text for the waypoint desc (looks for text to the right of the link first)
hooksecurefunc("ChatFrame_OnHyperlinkShow", function (self, link, text)
    if strsub(link, 1, 8) == "worldmap" then
        local map_point = C_Map.GetUserWaypointFromHyperlink(link)
        if map_point and C_Map.CanSetUserWaypointOnMap(map_point.uiMapID) then
            -- Blizzard didn't bother to add sounds for this if the map is open, so let's add them
            if is_pin_visible_on_open_map() then
                PlaySound(SOUNDKIT.UI_MAP_WAYPOINT_CLICK_TO_PLACE, nil, SOUNDKIT_ALLOW_DUPLICATES)
            end
            -- Search through the chat frame for the message
            local i = self:GetNumMessages()
            while i > 0 do
                local chat_text = self:GetMessageInfo(i)
                local start_pos, end_pos = strfind(chat_text, text, 1, true)
                if end_pos then
                    -- First see if there's any text we can use to the right of the hyperlink
                    local right = strtrim(strsub(chat_text, end_pos + 1))
                    if right == "" then
                        -- No text to the right, so check for text to the left
                        local left = strtrim(strsub(chat_text, 1, start_pos - 1))
                        local left_strip_hyperlinks = select(4, ExtractHyperlinkString(left))
                        if left_strip_hyperlinks then
                            local colon_pos = strfind(left_strip_hyperlinks, ":", 1, true)
                            if colon_pos then
                                left = strtrim(strsub(left_strip_hyperlinks, colon_pos + 1))
                            end
                        end
                        if left ~= "" then
                            current_waypoint.desc = left
                        end
                    else
                        current_waypoint.desc = right
                    end
                    break
                end
                i = i - 1
            end
        end
    end
end)

-- Track the last 100 waypoints we've set
local waypoint_history_add, waypoint_history_last, waypoint_history_save, waypoint_history_restore
do
    -- implemented as an array with a wrap-around index
    local HISTORY_SIZE = 100
    local history = {}
    local index = 0
    
    function waypoint_history_add(waypoint)
        index = index % HISTORY_SIZE + 1
        history[index] = waypoint
    end
    
    function waypoint_history_last()
        if index ~= 0 then
            return history[index]
        end
    end
    
    -- Aligns history to an index of 1 for saving
    function waypoint_history_save()
        if history[index] then
            local waypoints = {}
            local read_index = index % HISTORY_SIZE + 1
            for _=1, HISTORY_SIZE do
                -- saved history may not be full
                local history_entry = history[read_index]
                if history_entry then
                    waypoints[#waypoints + 1] = history_entry
                end
                read_index = read_index % HISTORY_SIZE + 1
            end
            return waypoints
        end
    end
    
    function waypoint_history_restore(waypoints)
        if waypoints then
            history = waypoints
            index = #waypoints
        end
    end
end

local function can_set_waypoint(map)
    local can_set_waypoint = C_Map.CanSetUserWaypointOnMap(map)
    if not can_set_waypoint then
        -- !!! send the player an error message
    end
    return can_set_waypoint
end

local function set_waypoint(map, position, desc)
    if can_set_waypoint(map) then
        local map_point = UiMapPoint.CreateFromVector2D(map, position)
        C_Map.SetUserWaypoint(map_point)
        current_waypoint.desc = strtrim(desc)
        if is_pin_visible_on_open_map() then
            PlaySound(SOUNDKIT.UI_MAP_WAYPOINT_CLICK_TO_PLACE, nil, SOUNDKIT_ALLOW_DUPLICATES)
        end
    end
end

local function clear_waypoint()
    if current_waypoint then
        if is_pin_visible_on_open_map() then
            C_Map.ClearUserWaypoint()
            PlaySound(SOUNDKIT.UI_MAP_WAYPOINT_REMOVE, nil, SOUNDKIT_ALLOW_DUPLICATES)
        else
            C_Map.ClearUserWaypoint()
        end
    end
end

-- Round number to specified decimal places
local function round_number(number, places)
    local mult = 10 ^ places
    return floor(number * mult + 0.5) / mult -- important to round rather than truncate since C_Map.GetUserWaypoint gives back slightly different values than what you put into C_Map.SetUserWaypoint
end

-- e.g., given 1.31, 1.2, returns 2 because .31 goes to 2 decimal places (and that's more places than .2)
-- useful so we can print "1.31, 1.20" rather than "1.31, 1.2"
local function longest_fractional_length(...)
    local nums = {...}
    for places = 0, math.huge do
        local mult = 10 ^ places
        local found_fraction = false
        for _, num in ipairs(nums) do
            if num * mult % 1 > 0 then
                found_fraction = true
                break
            end
        end
        if not found_fraction then
            return places
        end
    end
end

local function get_waypoint_strings(waypoint)
    local DECIMAL_PLACES = 2
    -- x and y to 2 decimal places, or fewer when least significant digit is 0
    local x = round_number(waypoint.position.x * 100, DECIMAL_PLACES)
    local y = round_number(waypoint.position.y * 100, DECIMAL_PLACES)
    local places = longest_fractional_length(x, y)
    local format_string = strconcat("%.", places, "f")
    return map_id_to_unique_name[waypoint.uiMapID], format(format_string, x), format(format_string, y)
end

-- !!! make this accessible to user somehow
local function get_waypoint_run_string(waypoint)
    return strconcat("/run C_Map.SetUserWaypoint(", waypoint.uiMapID, ",", waypoint.position.x, ",", waypoint.position.y, ")")
end

-- Parses syntax for commands like /way and /wayl: [map name|map number] x y [description]
local function parse_waypoint_command(msg)
    local MAX_AMBIGUOUS_MAP_NAMES_TO_SHOW = 7
    
    if msg ~= "" then
        -- Strip comma or period-separated coords ("8, 15" -> "8 15")
        msg = msg:gsub("(%d)[.,] (%d)", "%1 %2")
        -- Deal with locale differences in decimal separators
        local wrong_sep
        local right_sep
        if tonumber("1.1") == nil then -- tonumber will return nil if locale doesn't use "." as decimal separator
            right_sep = ","
            wrong_sep = "."
        else
            right_sep = "."
            wrong_sep = ","
        end
        local wrong_sep_pattern = strjoin("(%d)", wrong_locale_dec, "(%d)")
        local right_step_pattern = strjoin("%1", locale_dec, "%2")
        msg = msg:gsub(wrong_sep_pattern, right_sep_pattern)

        -- Tokenize
        local tokens = {}
        for token in msg:gmatch("%S+") do
            tokens[#tokens + 1] = token
        end
        
        -- Find index of first number (could be map number or the x coord)
        local first_number_pos
        local first_number
        for i, token in ipairs(tokens) do
            local to_number = tonumber(token)
            if to_number then
                first_number_pos = i
                first_number = tonumber(token)
                break
            end
        end
        
        if first_number then
            -- second number could be x or y
            local second_number = tonumber(tokens[first_number_pos + 1])
            if second_number and second_number >= 0 and second_number <= 100 then -- second number is x or y, so we can range check it
                -- If we don't have two consecutive numbers, the syntax is definitely wrong
                -- if the first thing we got wasn't a number, it better be a map name
                if first_number_pos ~= 1 then
                    -- user provided a map name
                    if first_number >= 0 and first_number <= 100 then -- first number must be x coordinate, so range check it
                        local name_tokens = {}
                        for i = 1, first_number_pos - 1 do
                            name_tokens[#name_tokens + 1] = tokens[i]
                        end
                        local map_name = strlower(strconcat(unpack(name_tokens)))
                        local map_name_colon = strfind(map_name, ":", 1, true)
                        
                        -- find matching names in the DB
                        local matching_map_ids = {}
                        local db_probe = normalized_unique_map_name_to_id[map_name]
                        if db_probe then
                            -- exact match
                            matching_map_ids = {db_probe}
                        else
                            -- partial matching
                            if map_name_colon then
                                for db_name, db_map_id in pairs(normalized_unique_map_name_to_id) do
                                    if strfind(db_name, map_name, 1, true) then
                                        matching_map_ids[#matching_map_ids + 1] = db_map_id
                                    end
                                end
                            else
                                -- if no colon in input, first try only prefixes (don't match "Greymane Manor:Ruins of Gilneas" on the input "Gilneas")
                                for db_name, db_map_id in pairs(normalized_unique_map_name_to_id) do
                                    local db_name_colon = strfind(db_name, ":", 1, true)
                                    local prefix
                                    if db_name_colon then
                                        prefix = strsub(db_name, 1, db_name_colon - 1)
                                    else
                                        prefix = db_name
                                    end
                                    if strfind(prefix, map_name, 1, true) then
                                        matching_map_ids[#matching_map_ids + 1] = db_map_id
                                    end
                                end
                                -- if we didn't find anything, try suffixes too
                                if #matching_map_ids == 0 then
                                    for db_name, db_map_id in pairs(normalized_unique_map_name_to_id) do
                                        if strfind(db_name, map_name, 1, true) then
                                            matching_map_ids[#matching_map_ids + 1] = db_map_id
                                        end
                                    end
                                end
                            end
                        end
                        
                        -- Handle bad/ambiguous map inputs
                        local matching_map_ids_count = #matching_map_ids
                        if matching_map_ids_count > MAX_AMBIGUOUS_MAP_NAMES_TO_SHOW then
                            -- Too many matches
                            -- !!! print this better
                            print(matching_map_ids_count .. " possible matches for zone \"" .. strjoin(" ", unpack(name_tokens)) .. "\". Top results:")
                            local matching_map_names = {}
                            for _, id in ipairs(matching_map_ids) do
                                matching_map_names[#matching_map_names + 1] = map_id_to_unique_name[id]
                            end
                            sort(matching_map_names, function (a, b)
                                return #a < #b
                            end)
                            for i = 1, MAX_AMBIGUOUS_MAP_NAMES_TO_SHOW do
                                print(matching_map_names[i]) -- !!! do better than print (can we offer clickables?)
                            end
                            return nil
                        elseif matching_map_ids_count > 1 then
                            -- Multiple matches
                            -- !!!print this better
                            print(matching_map_ids_count .. " possible matches for zone \"" .. strjoin(" ", unpack(name_tokens)) .. "\". Did you mean:")
                            local matching_map_names = {}
                            for _, id in ipairs(matching_map_ids) do
                                matching_map_names[#matching_map_names + 1] = map_id_to_unique_name[id]
                            end
                            sort(matching_map_names, function (a, b)
                                return #a < #b
                            end)
                            for _, name in ipairs(matching_map_names) do
                                print(name) -- !!! do better than print (can we offer clickables?)
                            end
                            return nil
                        elseif matching_map_ids_count == 0 then
                            -- do a fuzzy search and show the best guesses for the map
                            -- !!!print this better
                            print("Couldn't find zone \"" .. strjoin(" ", unpack(name_tokens)) .. "\". Did you mean:")
                            local fuzzy_matching_map_names = {}
                            if map_name_colon then
                                for name, id in pairs(normalized_unique_map_name_to_id) do
                                    fuzzy_matching_map_names[#fuzzy_matching_map_names + 1] = {name, CalculateStringEditDistance(name, map_name)}
                                end
                            else
                                -- if search string doesn't have colon then only match on prefixes
                                for name, id in pairs(normalized_unique_map_name_to_id) do
                                    local name_colon = strfind(name, ":", 1, true)
                                    local prefix
                                    if name_colon then
                                        prefix = strsub(name, 1, name_colon - 1)
                                    else
                                        prefix = name
                                    end
                                    fuzzy_matching_map_names[#fuzzy_matching_map_names + 1] = {name, CalculateStringEditDistance(prefix, map_name)}
                                end
                            end
                            sort(fuzzy_matching_map_names, function (a,b)
                                return a[2] < b[2]
                            end)
                            
                            -- Remove fuzzy matches that are totally unrelated to input string
                            local map_name_length = #map_name
                            for i, name in ipairs(fuzzy_matching_map_names) do
                                if name[2] == max(map_name_length, #name[1]) then
                                    fuzzy_matching_map_names[i] = nil
                                end
                            end
                            
                            -- Print the fuzzy matches
                            local shown = 0
                            for _, name in pairs(fuzzy_matching_map_names) do
                                print(map_id_to_unique_name[normalized_unique_map_name_to_id[name[1]]]) -- !!! do better than print
                                shown = shown + 1
                                if shown == MAX_AMBIGUOUS_MAP_NAMES_TO_SHOW then
                                    break
                                end
                            end
                            return nil
                        end
                        
                        -- we have a map, x, and y
                        local desc_tokens = {}
                        for i = first_number_pos + 2, #tokens do
                            desc_tokens[#desc_tokens + 1] = tokens[i]
                        end
                        return {uiMapID = matching_map_ids[1], position = CreateVector2D(first_number / 100, second_number / 100), desc = strconcat(unpack(desc_tokens))}
                    end
                else
                    -- user either provided (numerical map, x, y) or just (x, y)
                    local third_number = tonumber(tokens[first_number_pos + 2])
                    if third_number and third_number >= 0 and third_number <= 100 then
                        -- user entered (numerical map, x, y)
                        local desc_tokens = {}
                        for i = first_number_pos + 3, #tokens do
                            desc_tokens[#desc_tokens + 1] = tokens[i]
                        end
                        return {uiMapID = first_number, position = CreateVector2D(second_number / 100, third_number / 100), desc = strconcat(unpack(desc_tokens))}
                    elseif first_number >= 0 and first_number <= 100 then -- first number must be x coordinate, so range check it
                        local desc_tokens = {}
                        for i = first_number_pos + 2, #tokens do
                            desc_tokens[#desc_tokens + 1] = tokens[i]
                        end
                        -- if their map is open, try pinning to map zone
                        if WorldMapFrame:IsVisible() then
                            local map = WorldMapFrame:GetMapID()
                            if C_Map.CanSetUserWaypointOnMap(map) then
                                return {uiMapID = map, position = CreateVector2D(first_number / 100, second_number / 100), desc = strconcat(unpack(desc_tokens))}
                            end
                        else
                            -- pin in the zone the player is currently in
                            return {uiMapID = C_Map.GetBestMapForUnit(PLAYER), position = CreateVector2D(first_number / 100, second_number / 100), desc = strconcat(unpack(desc_tokens))}
                        end
                    end
                end
            end
        end
    end
    return nil
end

-- Set a user-specified waypoint, /way [map name|map number] x y [description]
local function way(msg)
    local waypoint = parse_waypoint_command(msg)
    if waypoint then
        set_waypoint(waypoint.uiMapID, waypoint.position, waypoint.desc)
    else
        print("Some syntax")-- !!!
        if current_waypoint then
            print(current_waypoint.string) -- !!!
        end
    end
end

-- Waypoint at player position ("way back")
local function wayb()
    local map = C_Map.GetBestMapForUnit(PLAYER)
    set_waypoint(map, C_Map.GetPlayerMapPosition(map, PLAYER), "Wayback")
end

-- open map to current waypoint
local function waym()
    if current_waypoint then
        local map = current_waypoint.uiMapID
        if WorldMapFrame:IsVisible() then
            WorldMapFrame:SetMapID(map)
        elseif InCombatLockdown() then
            do_after_combat(waym)
        else
            OpenWorldMap(map)
        end
    else
        -- !!! send the player an error message
    end
end

-- Clear waypoint
-- !!! should probably have wayc list to clear the list, and wayc all to clear the list AND the waypoint (will need to do something so we only play one clear sound if clearing multiple pins)
local function wayc()
    if current_waypoint then
        -- !!! get a string to display to the player about the waypoint they're clearing
        clear_waypoint()
    end
end

-- Generate a link using way syntax or a link to the current waypoint, /wayl [[map name|map number] x y [description]]
local function wayl(msg)
    local waypoint = parse_waypoint_command(msg) or current_waypoint
    if waypoint then
        local x = floor(waypoint.position.x * 10000)
        local y = floor(waypoint.position.y * 10000)
        local to_paste = strconcat("|cffffff00|Hworldmap:", waypoint.uiMapID, ":", x, ":", y, "|h[", MAP_PIN_HYPERLINK, "]|h|r") -- server rejects links with text other than "Map Pin" (MAP_PIN_HYPERLINK)
        local desc = waypoint.desc
        if desc then
            to_paste = strjoin(" ", to_paste, desc)
        end
        paste_in_chat(to_paste)
    else
        print("Some kind of error message") -- !!!
    end
end

-- !!!
-- /wayr (maybe something else?)
-- given a /way, generate a copy-able /run command for people without the addon

-- Link a waypoint to the target and some target info in chat
local function wayt()
    local TARGET = "target"
    local map = C_Map.GetBestMapForUnit(PLAYER)
    if can_set_waypoint(map) then
        if UnitExists(TARGET) then
            -- If it's a rare with a map marker visible, we can get its actual position
            local target_guid = UnitGUID(TARGET)
            local vignette_guids = C_VignetteInfo.GetVignettes()
            local target_position
            for _, vignette_guid in ipairs(vignette_guids) do
                if C_VignetteInfo.GetVignetteInfo(vignette_guid).objectGUID == target_guid then
                    target_position = C_VignetteInfo.GetVignettePosition(vignette_guid, map)
                    break
                end
            end
            local x, y
            if target_position then
                x, y = target_position:GetXY()
            else
                -- Just use the player's position
                x, y = C_Map.GetPlayerMapPosition(map, PLAYER):GetXY()
            end
            x = floor(x * 10000)
            y = floor(y * 10000)
            local target_name = UnitName(TARGET)
            local target_health_proportion = UnitHealth(TARGET) / UnitHealthMax(TARGET)
            local target_health
            if target_health_proportion == 0 then
                target_health = 0
            else
                -- Default to one decimal place, but if health < .1%, then show as many decimals as necessary so we never show 0% when things aren't dead yet
                local multiplier = 100
                repeat
                    multiplier = multiplier * 10
                    target_health = floor(target_health_proportion * multiplier) / (multiplier / 100)
                until target_health > 0
            end
            paste_in_chat(strconcat("|cffffff00|Hworldmap:", map, ":", x, ":", y, "|h[|A:Waypoint-MapPin-ChatIcon:13:13:0:0|a Map Pin Location]|h|r ", target_name, " (", target_health, "%)"))
        else
            -- !!! error message, no target
        end
    end    
end

-- Paste a waypoint link to the player's position into chat
local function wayme()
    local map = C_Map.GetBestMapForUnit(PLAYER)
    if can_set_waypoint(map) then
        local x, y = C_Map.GetPlayerMapPosition(map, PLAYER):GetXY()
        x = floor(x * 10000)
        y = floor(y * 10000)
        local player_name = UnitName(PLAYER) -- UnitName has two returns, so save here to avoid strjoin including the second return too
        paste_in_chat(strconcat("|cffffff00|Hworldmap:", map, ":", x, ":", y, "|h[", MAP_PIN_HYPERLINK, "]|h|r ", player_name))
    end
end

-- Waypoint supertrack toggle
local function ways()
    if current_waypoint then
        local supertracking = not C_SuperTrack.IsSuperTrackingUserWaypoint()
        C_SuperTrack.SetSuperTrackedUserWaypoint(supertracking)
        if is_pin_visible_on_open_map() then
            PlaySound(supertracking and SOUNDKIT.UI_MAP_WAYPOINT_SUPER_TRACK_ON or SOUNDKIT.UI_MAP_WAYPOINT_SUPER_TRACK_OFF, nil, SOUNDKIT_ALLOW_DUPLICATES)
        end
    else
        -- !!!messageplayer "You don't have an active pin."
    end
end

-- Open options/help
local function wayo()
    InterfaceOptionsFrame_OpenToCategory(moduspinens_frame)
end

-- Set a waypoint to the last minimap ping
local wayp, on_minimap_ping
do
    local last_minimap_ping
    
    function wayp()
        set_waypoint(last_minimap_ping.uiMapID, last_minimap_ping.position, "Minimap Ping")
    end

    -- Event handler for MINIMAP_PING
    function on_minimap_ping(pinger, minimap_x, minimap_y)
        local map = C_Map.GetBestMapForUnit(PLAYER)
        if C_Map.CanSetUserWaypointOnMap(map) then
            if C_CVar.GetCVar("rotateMinimap") == "1" then
                minimap_x, minimap_y = unrotate_minimap_coords(minimap_x, minimap_y)
            end
            local map_width, map_height = C_Map.GetMapWorldSize(map)
            local minimap_radius = C_Minimap.GetViewRadius()
            local player_x, player_y = C_Map.GetPlayerMapPosition(map, PLAYER):GetXY()
            local map_x = player_x + minimap_x * minimap_radius / map_width
            local map_y = player_y - minimap_y * minimap_radius / map_height
            last_minimap_ping = UiMapPoint.CreateFromCoordinates(map, map_x, map_y)
        end
    end
end

local function super_tracking_changed()
    if not C_SuperTrack.IsSuperTrackingAnything() and current_waypoint and saved_variables.semi_automatic_supertrack_pins then
        C_SuperTrack.SetSuperTrackedUserWaypoint(true)
    end
end

-- Override waypoint map click handler, so it can't automatially un-supertrack added pin
do
    -- Data providers are unlabeled, so we have to find it
    local waypoint_location_data_provider
    for data_provider in pairs(WorldMapFrame.dataProviders) do
        if data_provider.CanPlacePin then
            waypoint_location_data_provider = data_provider
            break
        end
    end
    if not waypoint_location_data_provider then
        error("Couldn't find the map pin data provider.")
    end

    -- Override waypoint map click handler
    hooksecurefunc(waypoint_location_data_provider, "HandleClick", function ()
        if current_waypoint and saved_variables.semi_automatic_supertrack_pins and (saved_variables.automatic_supertrack_pins or not C_SuperTrack.IsSuperTrackingAnything()) then
            C_SuperTrack.SetSuperTrackedUserWaypoint(true)
        end
    end)
end

local function on_user_waypoint_updated()
    local waypoint = C_Map.GetUserWaypoint()
    if waypoint then
        current_waypoint = to_local_map(waypoint)
        local display_name, display_x, display_y = get_waypoint_strings(current_waypoint)
        current_waypoint.string = strconcat(display_name, " (", display_x, ", ", display_y, ")")
        waypoint_history_add(waypoint)
        if saved_variables.semi_automatic_supertrack_pins and (saved_variables.automatic_supertrack_pins or not C_SuperTrack.IsSuperTrackingAnything()) then
            C_SuperTrack.SetSuperTrackedUserWaypoint(true)
        end
    else
        current_waypoint = nil
    end
end

local function on_player_logout()
    if saved_variables.save_logout_waypoint and current_waypoint then
        saved_variables_per_character.logout_waypoint = current_waypoint
        saved_variables_per_character.logout_supertrack = C_SuperTrack.IsSuperTrackingUserWaypoint()
    end
    
    if saved_variables.keep_history then
        saved_variables_per_character.history = waypoint_history_save()
    end
    
    ModusPinensSavedVariables = saved_variables
    ModusPinensSavedVariablesPerCharacter = saved_variables_per_character
end














local function check_button_sound(check_button)
    if check_button:GetChecked() then
        PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON);
    else
        PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF);
    end
end

local function create_check_button(text, tooltip, parent)
    local check_button = CreateFrame("CheckButton", nil, parent)
    check_button:SetSize(26, 26)
    check_button:SetHitRectInsets(0, -100, 0, 0)
    check_button:SetNormalTexture("Interface/Buttons/UI-CheckBox-Up")
    check_button:SetPushedTexture("Interface/Buttons/UI-CheckBox-Down")
    check_button:SetHighlightTexture("Interface/Buttons/UI-CheckBox-Highlight", "ADD")
    check_button:SetCheckedTexture("Interface/Buttons/UI-CheckBox-Check")
    check_button:SetDisabledCheckedTexture("Interface/Buttons/UI-CheckBox-Check-Disabled")
    check_button:SetScript("OnClick", check_button_sound)
    
    local font_string = check_button:CreateFontString(nil, "ARTWORK", "GameFontHighlightLeft")
    font_string:SetPoint("LEFT", check_button, "RIGHT", 2, 1)
    font_string:SetText(text)
    check_button.label = font_string
    
    return check_button
end

local function build_options_menu()
    -- Title
    local title = moduspinens_frame:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetJustifyH("LEFT")
    title:SetJustifyV("TOP")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Modus Pinens")
    
    -- Description
    local sub_text = moduspinens_frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    sub_text:SetNonSpaceWrap(true)
    sub_text:SetMaxLines(3)
    sub_text:SetJustifyH("LEFT")
    sub_text:SetJustifyV("TOP")
    sub_text:SetSize(0, 32)
    sub_text:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    sub_text:SetPoint("RIGHT", -32, 0)
    sub_text:SetText("Customize Map Pin behavior and commands.")
    
    -- Settings
    -- Track New Pins if Not Tracking Anything
    local semi_automatic_supertrack = create_check_button("Track New Pins If Not Tracking Anything", "Switch supertracking to newly placed pins if not tracking anything else.", moduspinens_frame)
    semi_automatic_supertrack:SetPoint("TOPLEFT", sub_text, "BOTTOMLEFT", -2, -8) -- !!! 260 x divider
    semi_automatic_supertrack:SetChecked(saved_variables.semi_automatic_supertrack_pins) -- !!! this should be in refresh
    
    -- Command Prefix
    local prefix = CreateFrame("EditBox", nil, moduspinens_frame, "InputBoxTemplate") -- !!! tooltip should show in red that they'll need to reload UI
    prefix:SetAutoFocus(false)
    prefix:SetSize(146, 32)
    prefix:SetPoint("TOPLEFT", semi_automatic_supertrack, "TOPRIGHT", 265, -16)
    
    local temp_prefix -- !!! clear this on refresh !!! save this as a key on the editbox itself instead
    prefix:HookScript("OnEditFocusLost", function (edit_box)
        temp_prefix = edit_box:GetText()
    end)
    prefix:SetScript("OnShow", function()
        prefix:SetText(temp_prefix or saved_variables.prefix)
    end)
    -- Prefix can't have spaces
    prefix:SetScript("OnSpacePressed", function (edit_box)
        local cursor = edit_box:GetCursorPosition()
        local text = edit_box:GetText()
        edit_box:SetText(strsub(text, 1, cursor - 1) .. strsub(text, cursor + 1))
        edit_box:SetCursorPosition(cursor - 1)
    end)
    
    local prefix_label = prefix:CreateFontString(nil, "BACKGROUND", "GameFontNormal")
    prefix_label:SetText("Command Prefix")
    prefix_label:SetPoint("BOTTOMLEFT", prefix, "TOPLEFT", 0, 3)
    
    -- Confirm and reload buttons (have to reload for prefix to take effect)
    local prefix_okay = CreateFrame("Button", nil, moduspinens_frame, "UIPanelButtonNoTooltipTemplate")
    local prefix_reload = CreateFrame("Button", nil, moduspinens_frame, "UIPanelButtonNoTooltipTemplate")
    prefix_okay:SetSize(80, 22)
    prefix_okay:SetText("Okay")
    prefix_okay:SetScript("OnClick", function ()
        PlaySound(SOUNDKIT.GS_TITLE_OPTION_OK)
        local text = prefix:GetText()
        if text ~= "" and text ~= saved_variables.prefix then
            saved_variables.prefix = text
            -- !!! probably play a UI error message telling them they need to reload
            prefix_reload:Show() -- !!! Need to show this after Default too, if the prefix wasn't default (should probably also show a UI error message)
        end
    end)
    prefix_okay:SetPoint("LEFT", prefix, "RIGHT")
    prefix_reload:SetSize(80, 22)
    prefix_reload:SetText("Reload")
    prefix_reload:SetScript("OnClick", function ()
        C_UI.Reload()
    end)
    prefix_reload:SetPoint("LEFT", prefix_okay, "RIGHT")
    prefix_reload:Hide() -- !!! hide this again on refresh when we clear temp_prefix
    
    -- Always Track New Pins
    local automatic_supertrack = create_check_button("Always Track New Pins", "Automatically switch supertracking to newly placed pins.", moduspinens_frame)
    automatic_supertrack:SetPoint("TOPLEFT", semi_automatic_supertrack, "BOTTOMLEFT", 16, -8)
    automatic_supertrack:SetChecked(saved_variables.automatic_supertrack_pins) -- !!! this should be in refresh
    if not saved_variables.semi_automatic_supertrack_pins then -- !!! this should be in refresh
        automatic_supertrack:Disable()
        automatic_supertrack.label:SetTextColor(GRAY_FONT_COLOR.r, GRAY_FONT_COLOR.g, GRAY_FONT_COLOR.b)
        -- !!! remove tooltip
    end
    
    -- Unlimited Pin Distance
    local unlimited_pin_distance = create_check_button("Unlimited Pin Distance", "Always show on-screen UI regardless of distance to pin.", moduspinens_frame)
    unlimited_pin_distance:SetPoint("TOPLEFT", automatic_supertrack, "BOTTOMLEFT", -16, -8)
    -- !!! -8, -8 for first 
end


















local function on_addon_loaded()
    -- Fill in default options
    do
        local default_saved_variables = {
            prefix = "way",
            unlimited_pin_distance = true,
            min_pin_distance = 10,
            max_pin_distance = 1000, -- !!! should be greyed out if unlimited pin distance is on
            semi_automatic_supertrack_pins = true, -- !!! this should be greyed out if automatic is on
            automatic_supertrack_pins = true,
            save_logout_waypoint = true,
            automatic_clear = false,
            clear_distance = 10, -- !!! grey out if automatic clear is off
            better_tooltips = true,
            keep_history = true
        }
        if not ModusPinensSavedVariables then
            saved_variables = default_saved_variables
        else
            for name, default in pairs(default_saved_variables) do
                local saved = ModusPinensSavedVariables[name]
                if saved == nil then
                    -- Add default value for new option
                    saved_variables[name] = default
                else
                    saved_variables[name] = saved
                end
            end
        end
    end
    saved_variables_per_character = ModusPinensSavedVariablesPerCharacter or {}
    
    -- Build the Interface options panel
    build_options_menu()
    
    -- Add hooks that depend on options
    -- Clear active pin when user comes within user-defined distance
    hooksecurefunc(SuperTrackedFrame, "UpdateDistanceText", function ()
        if saved_variables.automatic_clear and C_Navigation.GetDistance() <= saved_variables.clear_distance then
            clear_waypoint()
        end
    end)
    
    -- More useful Map Pin tooltips
    do
        local function update_waypoint_tooltip()
            GameTooltip_SetTitle(GameTooltip, current_waypoint.desc or "Map Pin", NORMAL_FONT_COLOR)
            GameTooltip_AddColoredLine(GameTooltip, format("%d |4yard:yards away", floor(C_Navigation.GetDistance())), WHITE_FONT_COLOR)
            GameTooltip_AddColoredLine(GameTooltip, current_waypoint.string, LIGHTGRAY_FONT_COLOR)
            GameTooltip_AddInstructionLine(GameTooltip, "<Shift-Click to share pin in chat>")
            GameTooltip_AddInstructionLine(GameTooltip, MAP_PIN_REMOVE)
            GameTooltip:Show()
        end

        local in_waypoint_tooltip = false
        
        hooksecurefunc(WaypointLocationPinMixin, "OnMouseEnter", function ()
            in_waypoint_tooltip = true
            if saved_variables.better_tooltips then
                update_waypoint_tooltip()
            end
        end)

        hooksecurefunc(WaypointLocationPinMixin, "OnMouseLeave", function ()
            in_waypoint_tooltip = false
        end)

        GameTooltip:HookScript("OnUpdate", function ()
            if in_waypoint_tooltip and saved_variables.better_tooltips then
                update_waypoint_tooltip()
            end
        end)
    end
    
    -- Custom min and max viewable distance for pins
    -- GetTargetAlphaBaseValue only ends up setting widget alpha, so taint should not propagate
    do
        local old_GetTargetAlphaBaseValue = SuperTrackedFrame.GetTargetAlphaBaseValue
        function SuperTrackedFrame:GetTargetAlphaBaseValue()
            local alpha = old_GetTargetAlphaBaseValue(self)
            local distance = C_Navigation.GetDistance()
            local unlimited = saved_variables.unlimited_pin_distance
            local min_distance = saved_variables.min_pin_distance
            local max_distance = saved_variables.max_pin_distance
            if not unlimited and distance > max_distance then
                alpha = 0
            elseif distance < min_distance then
                alpha = 0
            elseif alpha == 0 then
                if distance > 500 then
                    if unlimited or distance <= max_distance then
                        alpha = 0.6
                    end
                else
                    if distance >= min_distance then
                        alpha = 1
                    end
                end
            end
            return alpha
        end
    end

    -- Set up slash commands
    do
        local slash_commands = {
            {"", way, {""}},
            {"B", wayb, {"b", "back"}},
            {"M", waym, {"m", "map"}},
            {"C", wayc, {"c", "clear"}},
            {"P", wayp, {"p", "ping"}},
            {"S", ways, {"s", "super", "supertrack"}},
            {"T", wayt, {"t", "tar", "target"}},
            {"ME", wayme, {"me"}},
            {"L", wayl, {"l", "link"}},
            {"O", wayo, {"o", "option", "options", "h", "help", "moduspinens"}}
        }
        local slash_prefix = "/" .. saved_variables.prefix
        for i, slash_command in ipairs(slash_commands) do
            for j, command in ipairs(slash_command[3]) do
                _G[strconcat("SLASH_MODUSPINENS_WAY", slash_command[1], j)] = slash_prefix .. command
            end
            SlashCmdList["MODUSPINENS_WAY" .. slash_command[1]] = slash_command[2]
        end
    end

    -- Set up event handlers
    do
        moduspinens_frame:UnregisterEvent("ADDON_LOADED")
        local events = {
            PLAYER_LOGOUT = on_player_logout,
            MINIMAP_PING = on_minimap_ping,
            SUPER_TRACKING_CHANGED = on_super_tracking_changed,
            USER_WAYPOINT_UPDATED = on_user_waypoint_updated,
            PLAYER_REGEN_ENABLED = on_player_regen_enabled
        }
        for event, handler in pairs(events) do
            moduspinens_frame:RegisterEvent(event)
        end
        moduspinens_frame:SetScript("OnEvent", function(self, event, ...)
            events[event](...)
        end)
    end
    
    -- Restore logout waypoint
    do
        if saved_variables.save_logout_waypoint then
            local logout_waypoint = saved_variables_per_character.logout_waypoint
            if logout_waypoint then
                C_Map.ClearUserWaypoint()
                C_Map.SetUserWaypoint(logout_waypoint)
                current_waypoint.desc = saved_variables_per_character.logout_waypoint.desc
                C_SuperTrack.SetSuperTrackedUserWaypoint(saved_variables_per_character.logout_supertrack)
            end
        end
    end
    saved_variables_per_character.logout_waypoint = nil
    saved_variables_per_character.logout_supertrack = nil
    
    -- Restore waypoint history (must be after restore logout waypoint to avoid a duplicate history entry)
    if saved_variables.keep_history then
        waypoint_history_restore(saved_variables.history)
    end
    saved_variables.history = nil
    
    -- Create an options panel
    -- !!! add ui
    -- !!! put a command reference here too
    InterfaceOptions_AddCategory(moduspinens_frame)
    InterfaceAddOnsList_Update() -- fix Blizzard UI bug (otherwise OpenToCategory doesn't work on first run)
    function moduspinens_frame:okay()
        print("Okay!")
    end
    function moduspinens_frame:cancel()
        print("Cancel :(")
    end
    function moduspinens_frame:default()
        print("Default!")
    end
    function moduspinens_frame:refresh()
        print("Refreshing!")
    end
end

moduspinens_frame:RegisterEvent("ADDON_LOADED")
moduspinens_frame:SetScript("OnEvent", function(self, event, addon)
    if event == "ADDON_LOADED" and addon == "ModusPinens" then
        on_addon_loaded()
    end
end)
