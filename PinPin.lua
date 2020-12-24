-- !!! add commands for getting waypoint history
-- !!!    add a clickable pin for each one if possible
-- !!!        can printed pins (that aren't sent over a channel) have custom text?
-- !!! let users make lists of waypoints (make sure to only play sound once if adding a bunch of pins to the map together)
-- !!! show coords in map (and on minimap?)
-- !!! we CAN pin to many unpinnable maps by pinning to parent instead
--  !!!can we enable to pin button on the map too?

local PLAYER = "player"

local pinpin_frame = CreateFrame("Frame")
pinpin_frame.name = "PinPin"

local saved_variables = {}
local saved_variables_per_character = {}

local current_waypoint -- Stores the UiMapPoint of the current waypoint (plus a printable string and a custom desc) or nil if no waypoint

local normalized_unique_map_name_to_id = {} -- Lowered and spaces removed for searching, uses "/" for disambiguation separator internally (since there are map names with colons in them), front-end uses ":" to match other addons
local map_id_to_unique_name = {} -- For displaying unique names
do
    -- Disambiguation is complex. It is written to be linear, fast, and in-line since it has to be done at every reload.
    -- Do not alter without understanding. If something looks complicated, or the ordering seems strange, there's probably a reason.

    -- All maps can be referenced by map ID number
    -- If maps have a name, reference is:
    --     map name if unique (e.g., "Duskwood")
    --     or zone-and-ancestor if possible to construct an unambiguous one (e.g., "Nagrand:Outland")
    --     or zone and ID (e.g., "Dalaran:212")
    -- Special rule: if a map name is doubled, like "Orgrimmar - Orgrimmar", then it disambiguates alongside any other "Orgrimmar" maps, then becomes the canonical "Orgrimmar"
    --     this elegantly handles several awkward cases like Orgrimmar and Dalaran - the double-name map is usually the main map the players want (e.g., "Orgrimmar - Orgrimmar" is the normal Orgrimmar, plain "Orgrimmar" is some other Orgrimmar, yet if the player does /way orgrimmar 52 35, we want them to get the map for "Orgrimmar - Orgrimmar", not the other random map)

    -- Get the root map by finding the furthest ancestor of the fallback world map
    local root_map = C_Map.GetFallbackWorldMapID()
    while true do
        local parent = C_Map.GetMapInfo(root_map).parentMapID
        if parent == 0 then
            break
        else
            root_map = parent
        end
    end

    -- Get the map data for all child maps
    local map_data = C_Map.GetMapChildrenInfo(root_map, nil, true)

    -- Find pinnable maps (there are some maps where API doesn't support pins, but we can pin to parent map instead)
    -- Maps that pin to a parent have a "proxy" key with the map ID of the map we pin to instead
    local map_id_to_data = {}

    for _, map in ipairs(map_data) do
        map_id_to_data[map.mapID] = map
    end

    for id, map in pairs(map_id_to_data) do
        if map.pinnable == nil then
            local chain = {} -- if we end up having to check ancestors, we can set the whole chain at the same time
            local parent_id = map.parentMapID
            while true do
                if C_Map.CanSetUserWaypointOnMap(id) then
                    -- chain is pinnable
                    map_id_to_data[id].pinnable = true
                    for _, chain_id in ipairs(chain) do
                        map_id_to_data[chain_id].pinnable = true
                        map_id_to_data[chain_id].proxy = id
                    end
                    break
                else
                    chain[#chain + 1] = id
                    if parent_id == 0 then
                        -- no more parents to check, so this chain is not pinnable
                        for _, id in ipairs(chain) do
                            map_id_to_data[id].pinnable = false
                        end
                        break
                    else
                        -- check if we can translate coords onto the parent map
                        local continent, world_pos = C_Map.GetWorldPosFromMapPos(id, CreateVector2D(0.5, 0.5))
                        if continent and C_Map.GetMapPosFromWorldPos(continent, world_pos, parent_id) then
                            -- can translate the coords to the parent map
                            local pinnable = map_id_to_data[parent_id].pinnable
                            if pinnable == true then
                                -- parent map is pinnable, so this chain must be pinnable
                                for _, id in ipairs(chain) do
                                    map_id_to_data[id].pinnable = true
                                    map_id_to_data[id].proxy = parent_id
                                end
                                break
                            elseif pinnable == false then
                                -- parent map isn't pinnable, so this chain is not pinnable
                                for _, id in ipairs(chain) do
                                    map_id_to_data[id].pinnable = false
                                end
                                break
                            else
                                -- parent map pinnability is unknown, so check next ancestor
                                id = parent_id
                                parent_id = C_Map.GetMapInfo(id).parentMapID
                            end
                        else
                            -- we can't translate pin coords to parent map, so chain is not pinnable
                            for _, id in ipairs(chain) do
                                map_id_to_data[id].pinnable = false
                            end
                            break
                        end
                    end
                end
            end
        end
    end

    -- goal is to build unique_map_name_to_id and populate with only references to map IDs and disambiguated names
    local unique_map_name_to_id = {} -- stores map id and proxy id (for maps that place pins on parent maps)

    -- first pass to find duplicates
    local is_dupe = {}
    local dupes_map_data = {}
    for id, map in pairs(map_id_to_data) do
        if map.pinnable then
            local name = map.name
            local proxy = map.proxy
            unique_map_name_to_id[tostring(id)] = {id = id, proxy = proxy} -- all maps can be referenced by ID number
            if name and name ~= "" then
                if is_dupe[name] then
                    -- it's a duplicate
                    dupes_map_data[#dupes_map_data + 1] = {name = name, id = id, proxy = proxy}
                else
                    -- it might be a duplicate
                    local maybe_dupe = unique_map_name_to_id[name]
                    if maybe_dupe then
                        -- it's the first duplicate pair for this name
                        is_dupe[name] = true
                        dupes_map_data[#dupes_map_data + 1] = {name = name, id = maybe_dupe.id, proxy = maybe_dupe.proxy}
                        dupes_map_data[#dupes_map_data + 1] = {name = name, id = id, proxy = proxy}
                        unique_map_name_to_id[name] = nil
                    else
                        -- it's not a duplicate (so far)
                        unique_map_name_to_id[name] = {id = id, proxy = proxy}
                    end
                end
            end
        end
    end

    -- Add floor names to disambiguate dupes, create inverted table for remaining dupes
    is_dupe = {}
    local double_names = {} -- keep track of names like "Orgrimmar - Orgrimmar"
    local dupe_names_to_data = {}
    for _, map in ipairs(dupes_map_data) do
        local id = map.id
        local proxy = map.proxy
        local map_group = C_Map.GetMapGroupID(id)
        local name = map.name
        -- Get floor names
        if map_group then
            local floors = C_Map.GetMapGroupMembersInfo(map_group)
            for _, floor in pairs(floors) do
                if floor.mapID == id then
                    name = strjoin(" - ", map.name, floor.name)
                    if floor.name == map.name then
                        -- It's a name like "Orgrimmar - Orgrimmar", which we handle in a special way
                        double_names[name] = true
                    end
                    break
                end
            end
        end
        if is_dupe[name] then
            -- it's a duplicate
            tinsert(dupe_names_to_data[name], {id = id, ancestor_id = id, proxy = proxy}) -- initialize ancestor to self
        else
            -- it might be a duplicate
            local maybe_dupe = unique_map_name_to_id[name]
            if maybe_dupe then
                -- it's the first duplicate pair for this name
                is_dupe[name] = true
                local maybe_dupe_id = maybe_dupe.id
                dupe_names_to_data[name] = {
                    {id = id, ancestor_id = id, proxy = proxy},
                    {id = maybe_dupe_id, ancestor_id = maybe_dupe_id, proxy = maybe_dupe.proxy}
                }
                unique_map_name_to_id[name] = nil
            else
                -- it's not a duplicate (so far)
                unique_map_name_to_id[name] = {id = id, proxy = map.proxy}
            end
        end
    end

    -- If it's a name like "Orgrimmar - Orgrimmar", and it's the only such double-name, then it ultimately gets promoted to single-name as the true "Orgrimmar"
    local to_promote_name_to_id = {}
    for double_name, _ in pairs(double_names) do
        if unique_map_name_to_id[double_name] then
            -- There was only one instance of this double-name, so we can proceed
            local dash_pos = strfind(double_name, " - ", 1, true)
            local single_name = strsub(double_name, 1, dash_pos - 1)
            local old_single_name = unique_map_name_to_id[single_name]
            if old_single_name then
                -- there's already a single name in our list of disambiguated names, we need to disambiguate both, then promote the double-name at the end by removing its suffix
                local old_single_name_id = old_single_name.id
                local double_name_id_and_proxy = unique_map_name_to_id[double_name]
                local double_name_id = double_name_id_and_proxy.id
                dupe_names_to_data[single_name] = {
                    {id = old_single_name_id, ancestor_id = old_single_name_id, proxy = old_single_name.proxy},
                    {id = double_name_id, ancestor_id = double_name_id, proxy = double_name_id_and_proxy.proxy}
                }
                unique_map_name_to_id[single_name] = nil
                to_promote_name_to_id[single_name] = double_name_id
            elseif dupe_names_to_data[single_name] then
                -- we need to add this to the dupes so the others will disambiguate, then promote at the end by removing the suffix
                local double_name_id_and_proxy = unique_map_name_to_id[double_name]
                local double_name_id = double_name_id_and_proxy.id
                tinsert(dupe_names_to_data[single_name], {id = double_name_id, ancestor_id = double_name_id, proxy = double_name_id_and_proxy.proxy})
                to_promote_name_to_id[single_name] = unique_map_name_to_id[double_name].id
            else
                -- we can promote the double-name right now
                unique_map_name_to_id[single_name] = unique_map_name_to_id[double_name]
                -- we don't need to do anything later
            end
            unique_map_name_to_id[double_name] = nil
        end
    end

    -- Try to disambiguate with other information
    for name, maps in pairs(dupe_names_to_data) do
        -- If multiple maps have the same proxy and same coordinate system, we can just use the same name for all (since that means we'll just be pinning to the same map anyway)
        -- (There might not be any such maps, but there may be some added later)
        do
            local first_map = maps[1]
            local id = first_map.id
            local proxy = first_map.proxy
            local found_unmatched = false
            if proxy then
                local _, world_pos_one, world_pos_two
                -- if two points on both maps project to the same world coords, the maps share the same space
                _, world_pos_one = C_Map.GetWorldPosFromMapPos(id, CreateVector2D(0.25, 0.25))
                _, world_pos_two = C_Map.GetWorldPosFromMapPos(id, CreateVector2D(0.75, 0.75))
                -- see if the two points match on the other maps:
                for i = 2, #maps do
                    if maps[i].proxy == proxy then
                        local test_world_pos_one, test_world_pos_two
                        _, test_world_pos_one = C_Map.GetWorldPosFromMapPos(id, CreateVector2D(0.25, 0.25))
                        _, test_world_pos_two = C_Map.GetWorldPosFromMapPos(id, CreateVector2D(0.75, 0.75))
                        if test_world_pos_one.x ~= world_pos_one.x or test_world_pos_one.y ~= world_pos_one.y or test_world_pos_two.x ~= world_pos_two.x or test_world_pos_two.y ~= world_pos_two.y then
                            found_unmatched = true
                            break
                        end
                    else
                        found_unmatched = true
                        break
                    end
                end
                if not found_unmatched then
                    unique_map_name_to_id[name] = {id = id, proxy = proxy}
                end
            end
        end
        if not proxy or found_unmatched then
            -- See if we can use ancestor maps to disambiguate (e.g., Nagrand:Outland)
            repeat
                -- Get the next ancestor map IDs
                for key, map in pairs(maps) do -- maps may have holes in it
                    local parent_id = C_Map.GetMapInfo(map.ancestor_id).parentMapID
                    if parent_id == 0 then
                        -- No more parents available to disambiguate with, so best suffix is map ID
                        local id = map.id
                        if to_promote_name_to_id[name] == id then
                            unique_map_name_to_id[name] = {id = id, proxy = map.proxy}
                        else
                            unique_map_name_to_id[strjoin("/", name, id)] = {id = id, proxy = map.proxy}
                        end
                        maps[key] = nil
                    else
                        map.ancestor_id = parent_id
                    end
                end
                -- Find duplicate ancestor IDs among the duplicate map names (since this means all further ancestors will be shared too)
                local ancestor_ids_to_maps = {}
                for key, map in pairs(maps) do
                    local ancestor_id = map.ancestor_id
                    if not ancestor_ids_to_maps[ancestor_id] then
                        ancestor_ids_to_maps[ancestor_id] = {}
                    end
                    tinsert(ancestor_ids_to_maps[ancestor_id], {key = key, map = map}) -- save the key so we can nil it in maps if there are duplicate ancestors
                end
                for ancestor_id, child_maps in pairs(ancestor_ids_to_maps) do
                    if #child_maps > 1 then
                        -- Found duplicate ancestor IDs, so best suffix is map ID
                        for child_map_key, child_map in ipairs(child_maps) do
                            local id = child_map.map.id
                            if to_promote_name_to_id[name] == id then
                                unique_map_name_to_id[name] = {id = id, proxy = child_map.map.proxy}
                            else
                                unique_map_name_to_id[strjoin("/", name, id)] = {id = id, proxy = child_map.map.proxy}
                            end
                            maps[child_map.key] = nil
                        end
                    end
                end
                -- Find remaining duplicate suffixes
                local suffixes_to_maps = {}
                for key, map in pairs(maps) do
                    local suffix = C_Map.GetMapInfo(map.ancestor_id).name
                    if suffix then
                        map.suffix = suffix
                        if not suffixes_to_maps[suffix] then
                            suffixes_to_maps[suffix] = {}
                        end
                        tinsert(suffixes_to_maps[suffix], {key = key, map = map})
                    end
                end
                local found_dupe = false
                for suffix, suffixed_maps in pairs(suffixes_to_maps) do
                    if #suffixed_maps == 1 then
                        -- Suffix is unique
                        local unique_map_entry = suffixed_maps[1]
                        if to_promote_name_to_id[name] == unique_map_entry.map.id then
                            unique_map_name_to_id[name] = {id = unique_map_entry.map.id, proxy = unique_map_entry.map.proxy}
                        else
                            unique_map_name_to_id[strjoin("/", name, suffix)] = {id = unique_map_entry.map.id, proxy = unique_map_entry.map.proxy}
                        end
                        maps[unique_map_entry.key] = nil
                    else
                        found_dupe = true
                    end
                end
            until not found_dupe
        end
    end

    -- Build the outputs for searching and displaying
    for name, id_and_proxy in pairs(unique_map_name_to_id) do
        normalized_unique_map_name_to_id[strlower(gsub(name, "%s+", ""))] = id_and_proxy

        -- Get the shortest, non-numeric (if possible) name for the map
        local id = id_and_proxy.id
        local map_id_to_unique_name_entry = map_id_to_unique_name[id]
        if map_id_to_unique_name_entry == nil or tonumber(map_id_to_unique_name_entry) then
            map_id_to_unique_name[id] = gsub(name, "/", ":") -- front-end uses ":" as separator
        end
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
        C_Map.ClearUserWaypoint() -- waypoint change event doesn't fire if setting same waypoint, but we need that to fire to update supertracking if auto-supertracking is on, so clear it first
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
    return floor(number * mult + 0.5) / mult
end

-- e.g., given 1.31, 1.2, returns 2 because .31 goes to 2 decimal places (and that's more places than .2)
-- useful so we can print "1.31, 1.20" rather than "1.31, 1.2"
local function longest_fractional_length(...)
    local nums = {...}
    local places = 0
    for _, num in ipairs(nums) do
        test_places = #tostring(num % 1) - 2
        if test_places > places then
            places = test_places
        end
    end
    return places
end

local function get_waypoint_strings(waypoint)
    local DECIMAL_PLACES = 2
    -- x and y to 2 decimal places, or fewer when least significant digit is 0
    local x = round_number(waypoint.position.x * 100, DECIMAL_PLACES)
    local y = round_number(waypoint.position.y * 100, DECIMAL_PLACES)
    local places = longest_fractional_length(x, y)
    if places > DECIMAL_PLACES then -- in case of floating precision problems
        places = DECIMAL_PLACES
    end
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
        if tonumber("1.1") == nil then -- this tonumber will return nil if locale doesn't use "." as decimal separator
            right_sep = ","
            wrong_sep = "."
        else
            right_sep = "."
            wrong_sep = ","
        end
        local wrong_sep_pattern = strconcat("(%d)", wrong_sep, "(%d)")
        local right_sep_pattern = strconcat("%1", right_sep, "%2")
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
            local second_number = tonumber(tokens[first_number_pos + 1]) -- second_number could be x or y
            if second_number and second_number >= 0 and second_number <= 100 then -- second number is x or y, so we can range check it
                -- If we don't have two consecutive numbers, the syntax is definitely wrong
                if first_number_pos ~= 1 then -- if the first thing we got wasn't a number, it better be a map name
                    -- user provided a map name
                    if first_number >= 0 and first_number <= 100 then -- first number must be x coordinate, so range check it
                        local name_tokens = {}
                        for i = 1, first_number_pos - 1 do
                            name_tokens[#name_tokens + 1] = tokens[i]
                        end
                        local input_name = strlower(strconcat(unpack(name_tokens)))
                        
                        -- find matching names in the DB
                        local matching_map_ids = {}
                        local db_probe = normalized_unique_map_name_to_id[input_name]
                        if db_probe then
                            -- exact match
                            matching_map_ids = {db_probe}
                        else
                            -- partial matching
                            -- first try only prefixes (don't match "Greymane Manor:Ruins of Gilneas" on the input "Gilneas")
                            for db_name, db_map_id in pairs(normalized_unique_map_name_to_id) do
                                local db_name_sep = strfind(db_name, "/", 1, true)
                                local prefix
                                if db_name_sep then
                                    prefix = strsub(db_name, 1, db_name_sep - 1)
                                else
                                    prefix = db_name
                                end

                                if strfind(prefix, input_name, 1, true) then
                                    matching_map_ids[#matching_map_ids + 1] = db_map_id
                                end
                            end
                            -- if we didn't find anything, try suffixes too
                            if #matching_map_ids == 0 then
                                for db_name, db_map_id in pairs(normalized_unique_map_name_to_id) do
                                    if strfind(gsub(db_name, "/", ":"), input_name, 1, true) then -- front-end separators are ":"
                                        matching_map_ids[#matching_map_ids + 1] = db_map_id
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
                            for _, id_and_proxy in ipairs(matching_map_ids) do
                                matching_map_names[#matching_map_names + 1] = map_id_to_unique_name[id_and_proxy.id]
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
                            for _, id_and_proxy in ipairs(matching_map_ids) do
                                matching_map_names[#matching_map_names + 1] = map_id_to_unique_name[id_and_proxy.id]
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
                            for name, _ in pairs(normalized_unique_map_name_to_id) do
                                -- get base edit distance
                                local edit_distance = CalculateStringEditDistance(gsub(name, "/", ":"), input_name)

                                -- see if prefix has better edit distance
                                local prefix_sep = strfind(name, "/", 1, true)
                                local prefix
                                if prefix_sep then
                                    prefix = strsub(name, 1, prefix_sep - 1)
                                    local prefix_edit_distance = CalculateStringEditDistance(prefix, input_name)
                                    if prefix_edit_distance < edit_distance then
                                        edit_distance = prefix_edit_distance
                                    end
                                else
                                    -- the name has no disambiguation - it is just a prefix (but we've already checked it)
                                    prefix = name
                                end
                                -- see if sub-parts of the prefix have better edit distance (otherwise fuzzy match, e.g., "Oriboo" will be too far from "Oribos - Ring of Fates")
                                for sub_prefix in gmatch(prefix, "(.-)%p") do
                                    local sub_prefix_edit_distance = CalculateStringEditDistance(sub_prefix, input_name)
                                    if sub_prefix_edit_distance < edit_distance then
                                        edit_distance = sub_prefix_edit_distance
                                    end
                                end
                                fuzzy_matching_map_names[#fuzzy_matching_map_names + 1] = {name, edit_distance}
                            end

                            -- Sort by edit distance
                            sort(fuzzy_matching_map_names, function (a,b)
                                return a[2] < b[2]
                            end)

                            -- Remove fuzzy matches that are totally unrelated to input string
                            local input_name_length = #input_name
                            for i, name in ipairs(fuzzy_matching_map_names) do
                                if name[2] == max(input_name_length, #name[1]) then
                                    fuzzy_matching_map_names[i] = nil
                                end
                            end

                            -- Print the fuzzy matches
                            local shown = 0
                            for _, name in pairs(fuzzy_matching_map_names) do
                                print(map_id_to_unique_name[normalized_unique_map_name_to_id[name[1]].id]) -- !!! do better than print
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
                        end
                        -- if map is closed or we can't pin to map zone, pin in the zone the player is currently in
                        return {uiMapID = C_Map.GetBestMapForUnit(PLAYER), position = CreateVector2D(first_number / 100, second_number / 100), desc = strconcat(unpack(desc_tokens))}
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
    InterfaceOptionsFrame_OpenToCategory(pinpin_frame)
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
    print("Super tracking changed") -- !!!
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
    print("Updated")
    local waypoint = C_Map.GetUserWaypoint()
    if waypoint then
        current_waypoint = to_local_map(waypoint)
        local display_name, display_x, display_y = get_waypoint_strings(current_waypoint)
        current_waypoint.string = strconcat(display_name, " (", display_x, ", ", display_y, ")")
        waypoint_history_add(waypoint)
        if saved_variables.semi_automatic_supertrack_pins and (saved_variables.automatic_supertrack_pins or not C_SuperTrack.IsSuperTrackingAnything()) then
            print("Setting supertracking to true") -- !!!
            print(C_SuperTrack.IsSuperTrackingUserWaypoint())
            C_SuperTrack.SetSuperTrackedUserWaypoint(true)
            print(C_SuperTrack.IsSuperTrackingUserWaypoint())
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
    
    PinPinSavedVariables = saved_variables
    PinPinSavedVariablesPerCharacter = saved_variables_per_character
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
    local title = pinpin_frame:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetJustifyH("LEFT")
    title:SetJustifyV("TOP")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("PinPin")
    
    -- Description
    local sub_text = pinpin_frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
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
    local semi_automatic_supertrack = create_check_button("Track New Pins If Not Tracking Anything", "Switch supertracking to newly placed pins if not tracking anything else.", pinpin_frame)
    semi_automatic_supertrack:SetPoint("TOPLEFT", sub_text, "BOTTOMLEFT", -2, -8) -- !!! 260 x divider
    semi_automatic_supertrack:SetChecked(saved_variables.semi_automatic_supertrack_pins) -- !!! this should be in refresh
    
    -- Command Prefix
    local prefix = CreateFrame("EditBox", nil, pinpin_frame, "InputBoxTemplate") -- !!! tooltip should show in red that they'll need to reload UI
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
    local prefix_okay = CreateFrame("Button", nil, pinpin_frame, "UIPanelButtonNoTooltipTemplate")
    local prefix_reload = CreateFrame("Button", nil, pinpin_frame, "UIPanelButtonNoTooltipTemplate")
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
    local automatic_supertrack = create_check_button("Always Track New Pins", "Automatically switch supertracking to newly placed pins.", pinpin_frame)
    automatic_supertrack:SetPoint("TOPLEFT", semi_automatic_supertrack, "BOTTOMLEFT", 16, -8)
    automatic_supertrack:SetChecked(saved_variables.automatic_supertrack_pins) -- !!! this should be in refresh
    if not saved_variables.semi_automatic_supertrack_pins then -- !!! this should be in refresh
        automatic_supertrack:Disable()
        automatic_supertrack.label:SetTextColor(GRAY_FONT_COLOR.r, GRAY_FONT_COLOR.g, GRAY_FONT_COLOR.b)
        -- !!! remove tooltip
    end
    
    -- Unlimited Pin Distance
    local unlimited_pin_distance = create_check_button("Unlimited Pin Distance", "Always show on-screen UI regardless of distance to pin.", pinpin_frame)
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
        if not PinPinSavedVariables then
            saved_variables = default_saved_variables
        else
            for name, default in pairs(default_saved_variables) do
                local saved = PinPinSavedVariables[name]
                if saved == nil then
                    -- Add default value for new option
                    saved_variables[name] = default
                else
                    saved_variables[name] = saved
                end
            end
        end
    end
    saved_variables_per_character = PinPinSavedVariablesPerCharacter or {}
    
    -- Build the Interface options panel
    build_options_menu()
    
    -- Add hooks that depend on options
    -- Clear active pin when user comes within user-defined distance
    hooksecurefunc(SuperTrackedFrame, "UpdateDistanceText", function ()
        if saved_variables.automatic_clear and not UnitOnTaxi(PLAYER) and C_Navigation.GetDistance() <= saved_variables.clear_distance then
            clear_waypoint()
        end
    end)
    
    -- More useful Map Pin tooltips
    do
        local function update_waypoint_tooltip()
            GameTooltip_SetTitle(GameTooltip, current_waypoint.desc or "Map Pin", NORMAL_FONT_COLOR)
            if not UnitOnTaxi(PLAYER) then
                GameTooltip_AddColoredLine(GameTooltip, format("%d |4yard:yards away", floor(C_Navigation.GetDistance())), WHITE_FONT_COLOR)
            end
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
            {"O", wayo, {"o", "option", "options", "h", "help", "pinpin"}}
        }
        local slash_prefix = "/" .. saved_variables.prefix
        for i, slash_command in ipairs(slash_commands) do
            for j, command in ipairs(slash_command[3]) do
                _G[strconcat("SLASH_PINPIN_WAY", slash_command[1], j)] = slash_prefix .. command
            end
            SlashCmdList["PINPIN_WAY" .. slash_command[1]] = slash_command[2]
        end
    end

    -- Set up event handlers
    do
        pinpin_frame:UnregisterEvent("ADDON_LOADED")
        local events = {
            PLAYER_LOGOUT = on_player_logout,
            MINIMAP_PING = on_minimap_ping,
            SUPER_TRACKING_CHANGED = on_super_tracking_changed,
            USER_WAYPOINT_UPDATED = on_user_waypoint_updated,
            PLAYER_REGEN_ENABLED = on_player_regen_enabled
        }
        for event, handler in pairs(events) do
            pinpin_frame:RegisterEvent(event)
        end
        pinpin_frame:SetScript("OnEvent", function(self, event, ...)
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
                C_SuperTrack.SetSuperTrackedUserWaypoint(saved_variables_per_character.logout_supertrack) -- the game might overwrite this when quests load in, but that's fine
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
    InterfaceOptions_AddCategory(pinpin_frame)
    InterfaceAddOnsList_Update() -- fix Blizzard UI bug (otherwise OpenToCategory doesn't work on first run)
    function pinpin_frame:okay()
        print("Okay!")
    end
    function pinpin_frame:cancel()
        print("Cancel :(")
    end
    function pinpin_frame:default()
        print("Default!")
    end
    function pinpin_frame:refresh()
        print("Refreshing!")
    end
end

pinpin_frame:RegisterEvent("ADDON_LOADED")
pinpin_frame:SetScript("OnEvent", function(self, event, addon)
    if event == "ADDON_LOADED" and addon == "PinPin" then
        on_addon_loaded()
    end
end)
