script_name('Notification Manager')
script_author('Sand')
script_version('1.0')

local imgui = require('mimgui')
local json = require('dkjson')
local notify = nil

local MANAGER_HOST_NAME = 'NotificationManager'
local HEARTBEAT_INTERVAL = 2
local LIBRARY_RAW_URL = 'https://raw.githubusercontent.com/Mister-Sand/session_notifications/main/lib/session_notifications.lua'

local function detect_separator()
    local cwd = tostring(getWorkingDirectory() or '')
    if cwd:find('/', 1, true) and not cwd:find('\\', 1, true) then
        return '/'
    end
    if cwd:find('\\', 1, true) then
        return '\\'
    end
    return MONET_DPI_SCALE ~= nil and '/' or '\\'
end

local SEPORATORPATCH = detect_separator()

local function normalize_path(path)
    path = tostring(path or '')
    if SEPORATORPATCH == '/' then
        return path:gsub('\\', '/')
    end
    return path:gsub('/', '\\')
end

local function join_path(...)
    local result = ''

    for index = 1, select('#', ...) do
        local part = normalize_path(select(index, ...))
        if part ~= '' then
            if result == '' then
                result = part:gsub('[\\/]+$', '')
            else
                part = part:gsub('^[\\/]+', '')
                result = result:gsub('[\\/]+$', '') .. SEPORATORPATCH .. part
            end
        end
    end

    return result
end

local function dirname(path)
    return normalize_path(path):match('^(.*)[/\\][^/\\]+$')
end

local function ensure_dir(path)
    path = normalize_path(path)
    if path == '' or doesDirectoryExist(path) then
        return
    end

    local current = ''
    local rest = path

    if rest:match('^%a:[/\\]') then
        current = rest:sub(1, 3)
        rest = rest:sub(4)
    elseif rest:match('^[/\\]') then
        current = SEPORATORPATCH
        rest = rest:sub(2)
    end

    for part in rest:gmatch('[^/\\]+') do
        if current == '' or current == SEPORATORPATCH or current:match('^%a:[/\\]$') then
            current = current .. part
        else
            current = current .. SEPORATORPATCH .. part
        end

        if not doesDirectoryExist(current) then
            createDirectory(current)
        end
    end
end

local LIBRARY_PATH = join_path(getWorkingDirectory(), 'lib', 'session_notifications.lua')

local history_open = imgui.new.bool(false)
local active = {}
local history = {}
local texture_cache = {}
local session = nil
local queue_offset = 0
local history_filter = 1

local function ensure_parent_directory(path)
    local parent = dirname(path)
    if parent and parent ~= '' then
        ensure_dir(parent)
    end
end

local function write_text_file(path, content)
    path = normalize_path(path)
    ensure_parent_directory(path)
    local file = assert(io.open(path, 'w'))
    file:write(content)
    file:close()
end

local function is_library_url_configured()
    return LIBRARY_RAW_URL ~= '' and not LIBRARY_RAW_URL:find('<', 1, true)
end

local function http_get_async(url, on_success, on_error)
    lua_thread.create(function()
        local ok, response = pcall(function()
            local requests = require('requests')
            return requests.get(url, {
                headers = {
                    ['Accept-Encoding'] = 'identity',
                    ['Connection'] = 'close'
                },
                timeout = 15
            })
        end)

        if ok and type(response) == 'table'
            and tonumber(response.status_code)
            and response.status_code >= 200
            and response.status_code < 300 then
            on_success(tostring(response.text or ''))
            return
        end

        if ok and type(response) == 'table' then
            on_error(string.format('HTTP %s for %s', tostring(response.status_code), url))
            return
        end

        on_error(tostring(response))
    end)
end

local function ensure_notification_library(on_done)
    if doesFileExist(LIBRARY_PATH) then
        on_done(true)
        return
    end

    if not is_library_url_configured() then
        on_done(false, 'configure LIBRARY_RAW_URL in NotificationManager.lua')
        return
    end

    http_get_async(LIBRARY_RAW_URL, function(text)
        local ok, err = pcall(write_text_file, LIBRARY_PATH, text)
        if not ok then
            on_done(false, 'failed to save library: ' .. tostring(err))
            return
        end

        on_done(true)
    end, function(err)
        on_done(false, 'failed to download library: ' .. tostring(err))
    end)
end

local MAX_ACTIVE = 6
local MAX_HISTORY = 250
local TOAST_WIDTH = 370
local TOAST_IMAGE = 52
local TOAST_MIN_HEIGHT = 108
local TOAST_MAX_HEIGHT = 440
local TOAST_HEIGHT_BUFFER = 18
local TOAST_GAP = 14
local TOAST_MARGIN = 18
local HISTORY_FILTERS = { 'All', 'Active', 'Expired', 'Dismissed', 'Overflow' }

local overlay_frame = imgui.OnFrame(
    function()
        return #active > 0
    end,
    function()
        render_toasts()
    end
)
overlay_frame.HideCursor = true

local history_frame = imgui.OnFrame(
    function()
        return history_open[0]
    end,
    function()
        render_history_window()
    end
)
history_frame.HideCursor = false

local function file_size(path)
    path = normalize_path(path)
    local file = io.open(path, 'r')
    if not file then
        return 0
    end

    local size = file:seek('end') or 0
    file:close()
    return size
end

local function trim_text(text, limit)
    text = tostring(text or '')
    if #text <= limit then
        return text
    end
    if limit <= 3 then
        return text:sub(1, limit)
    end
    return text:sub(1, limit - 3) .. '...'
end

local function calc_text_size_safe(text, wrap_width)
    text = tostring(text or '')

    local ok, size = pcall(function()
        if wrap_width and wrap_width > 0 then
            return imgui.CalcTextSize(text, false, wrap_width)
        end
        return imgui.CalcTextSize(text)
    end)
    if ok and size then
        return size
    end

    ok, size = pcall(function()
        return imgui.CalcTextSize(text, nil, false, wrap_width or -1)
    end)
    if ok and size then
        return size
    end

    return imgui.ImVec2(#text * 7, imgui.GetTextLineHeight())
end

local function calc_wrapped_text_height(text, wrap_width)
    text = tostring(text or '')
    if text == '' then
        return 0
    end

    local ok, size = pcall(function()
        return calc_text_size_safe(text, wrap_width)
    end)
    if ok and size and size.y and size.y > 0 then
        return size.y
    end

    local line_height = imgui.GetTextLineHeight()
    local spacing = imgui.GetStyle().ItemSpacing.y
    local lines = 0

    for raw_line in (text .. '\n'):gmatch('(.-)\n') do
        if raw_line == '' then
            lines = lines + 1
        else
            local current = ''
            for word in raw_line:gmatch('%S+') do
                local candidate = current == '' and word or (current .. ' ' .. word)
                local width = calc_text_size_safe(candidate).x
                if current ~= '' and wrap_width > 0 and width > wrap_width then
                    lines = lines + 1
                    current = word
                else
                    current = candidate
                end
            end

            if current ~= '' then
                lines = lines + 1
            end
        end
    end

    return (lines * line_height) + math.max(0, lines - 1) * spacing
end

local function ensure_item_texture(item)
    if not item then
        return nil
    end
    if not item.texture and item.image_path ~= '' then
        item.texture = resolve_texture(item.image_path)
    end
    return item.texture
end

local function get_toast_layout(item)
    local has_badge = ensure_item_texture(item) ~= nil
    local content_x = has_badge and 98 or 16
    local top_y = 16
    local title_y = 40
    local right_pad = 16
    local action_height = 26
    local content_width = TOAST_WIDTH - content_x - right_pad
    local wrap_width = content_width - 12

    local title_text = item.title ~= '' and item.title or item.text
    local body_text = item.text ~= '' and item.text or '-'

    local title_height = math.max(imgui.GetTextLineHeight(), calc_wrapped_text_height(title_text, wrap_width))
    local text_height = math.max(imgui.GetTextLineHeight(), calc_wrapped_text_height(body_text, wrap_width))
    local description_height = 0

    local cursor_y = title_y + title_height + 8
    local text_y = cursor_y
    cursor_y = cursor_y + text_height

    local description_y = 0
    if item.description ~= '' then
        cursor_y = cursor_y + 6
        description_y = cursor_y
        description_height = math.max(imgui.GetTextLineHeight(), calc_wrapped_text_height(item.description, wrap_width))
        cursor_y = cursor_y + description_height
    end

    local action_y = 0
    if item.action_label ~= '' and item.action_id ~= '' then
        cursor_y = cursor_y + 8
        action_y = cursor_y
        cursor_y = cursor_y + action_height
    end

    cursor_y = cursor_y + 8
    local footer_y = cursor_y
    local footer_height = imgui.GetTextLineHeight()

    local badge_bottom = has_badge and (top_y + TOAST_IMAGE) or 0
    local min_content_bottom = math.max(badge_bottom, footer_y + footer_height)
    local height = math.max(TOAST_MIN_HEIGHT, min_content_bottom + 16)

    return {
        has_badge = has_badge,
        content_x = content_x,
        content_width = content_width,
        wrap_width = wrap_width,
        title_y = title_y,
        title_text = title_text,
        text_y = text_y,
        body_text = body_text,
        description_y = description_y,
        description_height = description_height,
        action_y = action_y,
        action_height = action_height,
        footer_y = footer_y,
        height = height,
    }
end

local function to_vec4(color)
    return imgui.ImVec4(color[1], color[2], color[3], color[4] or 1)
end

local function resolve_texture(path)
    path = normalize_path(path)
    if not path or path == '' or not doesFileExist(path) then
        return nil
    end

    if not imgui.IsInitialized() then
        return nil
    end

    if texture_cache[path] ~= nil then
        return texture_cache[path]
    end

    texture_cache[path] = imgui.CreateTextureFromFile(path)
    return texture_cache[path]
end

local function format_clock(timestamp)
    if not timestamp then
        return '--:--:--'
    end
    return os.date('%H:%M:%S', timestamp)
end

local function status_label(status)
    if status == 'active' then
        return 'Active'
    end
    if status == 'expired' then
        return 'Expired'
    end
    if status == 'dismissed' then
        return 'Dismissed'
    end
    if status == 'overflow' then
        return 'Overflow'
    end
    return 'Closed'
end

local function status_matches(entry)
    local filter = HISTORY_FILTERS[history_filter]
    if filter == 'All' then
        return true
    end
    return string.lower(filter) == string.lower(entry.status or '')
end

local function add_history(entry)
    table.insert(history, 1, entry)
    while #history > MAX_HISTORY do
        table.remove(history)
    end
end

local function toast_height(item)
    local layout_height = get_toast_layout(item).height + TOAST_HEIGHT_BUFFER
    return math.min(layout_height, TOAST_MAX_HEIGHT)
end

local function expire_item(item, reason)
    if item.closed then
        return
    end

    item.closed = true
    item.closed_reason = reason or 'dismissed'
    item.closed_at = os.time()
end

local function activate_notification(payload)
    local item = {
        id = payload.id,
        script_id = payload.script_id or 'unknown-script',
        target_script_id = payload.target_script_id or payload.script_id or 'unknown-script',
        title = payload.title or '',
        text = payload.text or '',
        description = payload.description or '',
        duration = tonumber(payload.duration) or 5,
        sticky = not not payload.sticky,
        image_path = payload.image_path or '',
        action_id = payload.action_id or '',
        action_label = payload.action_label or '',
        action_payload = payload.action_payload,
        created_at = payload.created_at or os.time(),
        received_clock = os.clock(),
        last_clock = os.clock(),
        is_hovered = false,
        closed = false,
        closed_reason = nil,
        theme = payload.theme or notify.presets[payload.theme_name] or notify.presets.ocean
    }

    item.texture = resolve_texture(item.image_path)
    item.height = toast_height(item)
    item.expires_clock = item.sticky and math.huge or (item.received_clock + item.duration)

    table.insert(active, item)
    add_history({
        id = item.id,
        script_id = item.script_id,
        title = item.title,
        text = item.text,
        description = item.description,
        created_at = item.created_at,
        sticky = item.sticky,
        duration = item.duration,
        image_path = item.image_path,
        action_label = item.action_label,
        theme = item.theme,
        status = 'active'
    })
end

local function sync_history_status(item)
    for _, entry in ipairs(history) do
        if entry.id == item.id then
            entry.status = item.closed_reason or 'closed'
            entry.closed_at = item.closed_at or os.time()
            return
        end
    end
end

local function poll_queue()
    local paths = notify.get_paths()
    local file = io.open(paths.queue_file, 'r')
    if not file then
        return
    end

    file:seek('set', queue_offset)
    while true do
        local line = file:read('*line')
        if not line then
            break
        end

        if line ~= '' then
            local payload = json.decode(line)
            if type(payload) == 'table'
                and payload.kind == 'notification'
                and session
                and payload.session_id == session.session_id then
                activate_notification(payload)
            end
        end
    end

    queue_offset = file:seek() or queue_offset
    file:close()
end

local function update_active()
    local now_clock = os.clock()

    for index = #active, 1, -1 do
        local item = active[index]
        local delta = now_clock - (item.last_clock or now_clock)
        item.last_clock = now_clock

        if not item.closed and not item.sticky and item.is_hovered and delta > 0 then
            item.expires_clock = item.expires_clock + delta
        end

        if not item.closed and not item.sticky and now_clock >= item.expires_clock then
            expire_item(item, 'expired')
        end

        if item.closed then
            sync_history_status(item)
            table.remove(active, index)
        end
    end

    while #active > MAX_ACTIVE do
        local oldest = active[1]
        expire_item(oldest, 'overflow')
        sync_history_status(oldest)
        table.remove(active, 1)
    end
end

local function draw_badge(draw_list, origin_x, origin_y, size, theme, item)
    local texture = ensure_item_texture(item)
    if not texture then
        return
    end

    draw_list:AddRectFilled(
        imgui.ImVec2(origin_x, origin_y),
        imgui.ImVec2(origin_x + size, origin_y + size),
        imgui.GetColorU32Vec4(to_vec4(theme.badge)),
        12
    )

    imgui.SetCursorPos(imgui.ImVec2(origin_x - imgui.GetWindowPos().x, origin_y - imgui.GetWindowPos().y))
    imgui.Image(texture, imgui.ImVec2(size, size))
end

function render_toasts()
    local sw, sh = getScreenResolution()
    local y = sh - TOAST_MARGIN
    local now_clock = os.clock()

    for index = #active, 1, -1 do
        local item = active[index]
        local theme = item.theme
        local layout = get_toast_layout(item)
        local desired_height = layout.height + TOAST_HEIGHT_BUFFER
        local needs_scroll = desired_height > TOAST_MAX_HEIGHT
        local height = needs_scroll and TOAST_MAX_HEIGHT or desired_height
        item.height = height
        local position = imgui.ImVec2(sw - TOAST_WIDTH - TOAST_MARGIN, y - height)

        imgui.SetNextWindowPos(position, imgui.Cond.Always)
        imgui.SetNextWindowSize(imgui.ImVec2(TOAST_WIDTH, height), imgui.Cond.Always)

        imgui.PushStyleVarFloat(imgui.StyleVar.WindowRounding, 16)
        imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(16, 16))
        imgui.PushStyleColor(imgui.Col.WindowBg, to_vec4(theme.background))
        imgui.PushStyleColor(imgui.Col.Border, to_vec4(theme.border))

        imgui.Begin('##notification_toast_' .. item.id, nil,
            imgui.WindowFlags.NoDecoration +
            imgui.WindowFlags.NoSavedSettings +
            imgui.WindowFlags.NoNav +
            imgui.WindowFlags.NoFocusOnAppearing +
            imgui.WindowFlags.NoScrollbar +
            imgui.WindowFlags.NoScrollWithMouse
        )

        item.is_hovered = imgui.IsWindowHovered()

        local draw_list = imgui.GetWindowDrawList()
        local win_pos = imgui.GetWindowPos()
        local win_size = imgui.GetWindowSize()

        draw_list:AddRectFilled(
            imgui.ImVec2(win_pos.x, win_pos.y),
            imgui.ImVec2(win_pos.x + 4, win_pos.y + win_size.y),
            imgui.GetColorU32Vec4(to_vec4(theme.accent)),
            16,
            imgui.DrawCornerFlags.TopLeft + imgui.DrawCornerFlags.BotLeft
        )

        draw_list:AddRectFilled(
            imgui.ImVec2(win_pos.x + 1, win_pos.y + win_size.y - 4),
            imgui.ImVec2(win_pos.x + win_size.x - 1, win_pos.y + win_size.y - 1),
            imgui.GetColorU32Vec4(to_vec4(theme.accent_soft)),
            12
        )

        if layout.has_badge then
            draw_badge(draw_list, win_pos.x + 18, win_pos.y + 18, TOAST_IMAGE, theme, item)
        end

        imgui.SetCursorPos(imgui.ImVec2(layout.content_x, 16))
        imgui.PushStyleColor(imgui.Col.Text, to_vec4(theme.meta))
        imgui.Text(trim_text(item.script_id, 24) .. '  ' .. format_clock(item.created_at))
        imgui.PopStyleColor()

        imgui.SetCursorPos(imgui.ImVec2(320, 14))
        imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0, 0, 0, 0))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, to_vec4(theme.accent_soft))
        imgui.PushStyleColor(imgui.Col.ButtonActive, to_vec4(theme.accent_soft))
        if imgui.Button('x##close_' .. item.id, imgui.ImVec2(28, 22)) then
            expire_item(item, 'dismissed')
        end
        imgui.PopStyleColor(3)

        local has_action = item.action_label ~= '' and item.action_id ~= ''
        local footer_height = imgui.GetTextLineHeight()
        local progress_reserved = (not item.sticky and item.duration > 0) and 12 or 0
        local content_top = layout.title_y
        local footer_y = content_top

        if needs_scroll then
            local action_reserved = has_action and (layout.action_height + 10) or 0
            local content_height = math.max(34, height - content_top - footer_height - progress_reserved - action_reserved - 24)

            imgui.SetCursorPos(imgui.ImVec2(layout.content_x, content_top))
            imgui.BeginChild('##notification_toast_content_' .. item.id, imgui.ImVec2(layout.content_width, content_height), false)

            imgui.PushStyleColor(imgui.Col.Text, to_vec4(theme.title))
            imgui.PushTextWrapPos(imgui.GetCursorPosX() + layout.wrap_width)
            imgui.TextWrapped(layout.title_text)
            imgui.PopTextWrapPos()
            imgui.PopStyleColor()

            imgui.Dummy(imgui.ImVec2(0, 6))

            imgui.PushStyleColor(imgui.Col.Text, to_vec4(theme.text))
            imgui.PushTextWrapPos(imgui.GetCursorPosX() + layout.wrap_width)
            imgui.TextWrapped(layout.body_text)
            imgui.PopTextWrapPos()
            imgui.PopStyleColor()

            if item.description ~= '' then
                imgui.Dummy(imgui.ImVec2(0, 6))
                imgui.PushStyleColor(imgui.Col.Text, to_vec4(theme.meta))
                imgui.PushTextWrapPos(imgui.GetCursorPosX() + layout.wrap_width)
                imgui.TextWrapped(item.description)
                imgui.PopTextWrapPos()
                imgui.PopStyleColor()
            end

            item.is_hovered = item.is_hovered or imgui.IsWindowHovered()
            imgui.EndChild()
            footer_y = content_top + content_height + 6
        else
            imgui.SetCursorPos(imgui.ImVec2(layout.content_x, content_top))

            imgui.PushStyleColor(imgui.Col.Text, to_vec4(theme.title))
            imgui.PushTextWrapPos(imgui.GetCursorPosX() + layout.wrap_width)
            imgui.TextWrapped(layout.title_text)
            imgui.PopTextWrapPos()
            imgui.PopStyleColor()

            imgui.Dummy(imgui.ImVec2(0, 6))

            imgui.SetCursorPosX(layout.content_x)
            imgui.PushStyleColor(imgui.Col.Text, to_vec4(theme.text))
            imgui.PushTextWrapPos(imgui.GetCursorPosX() + layout.wrap_width)
            imgui.TextWrapped(layout.body_text)
            imgui.PopTextWrapPos()
            imgui.PopStyleColor()

            if item.description ~= '' then
                imgui.Dummy(imgui.ImVec2(0, 6))
                imgui.SetCursorPosX(layout.content_x)
                imgui.PushStyleColor(imgui.Col.Text, to_vec4(theme.meta))
                imgui.PushTextWrapPos(imgui.GetCursorPosX() + layout.wrap_width)
                imgui.TextWrapped(item.description)
                imgui.PopTextWrapPos()
                imgui.PopStyleColor()
            end

            footer_y = imgui.GetCursorPosY() + 6
        end

        if has_action then
            imgui.SetCursorPos(imgui.ImVec2(layout.content_x, footer_y))
            imgui.PushStyleColor(imgui.Col.Button, to_vec4(theme.accent_soft))
            imgui.PushStyleColor(imgui.Col.ButtonHovered, to_vec4(theme.badge))
            imgui.PushStyleColor(imgui.Col.ButtonActive, to_vec4(theme.badge))
            if imgui.Button(item.action_label .. '##action_' .. item.id, imgui.ImVec2(layout.content_width, layout.action_height)) then
                notify.emit_action({
                    target_script_id = item.target_script_id,
                    source_script_id = 'NotificationManager',
                    notification_id = item.id,
                    action_id = item.action_id,
                    action_payload = item.action_payload
                })
                expire_item(item, 'dismissed')
            end
            imgui.PopStyleColor(3)
            footer_y = footer_y + layout.action_height + 8
        end

        imgui.SetCursorPos(imgui.ImVec2(layout.content_x, footer_y))
        imgui.PushStyleColor(imgui.Col.Text, to_vec4(theme.meta))
        if item.sticky then
            imgui.Text('Pinned notification')
        else
            local left = math.max(0, item.expires_clock - now_clock)
            imgui.Text(string.format('Closes in %.1fs', left))
        end
        imgui.PopStyleColor()

        if not item.sticky and item.duration > 0 then
            local progress = math.max(0, math.min(1, (item.expires_clock - now_clock) / item.duration))
            draw_list:AddRectFilled(
                imgui.ImVec2(win_pos.x + 88, win_pos.y + win_size.y - 10),
                imgui.ImVec2(win_pos.x + 88 + (win_size.x - 112) * progress, win_pos.y + win_size.y - 6),
                imgui.GetColorU32Vec4(to_vec4(theme.accent)),
                3
            )
        end

        imgui.End()
        imgui.PopStyleColor(2)
        imgui.PopStyleVar(2)

        y = y - height - TOAST_GAP
    end
end

local function history_card(entry, index)
    local theme = entry.theme or notify.presets.ocean
    local height = 128
    if entry.description and entry.description ~= '' then
        height = height + 26
    end
    if entry.image_path and entry.image_path ~= '' then
        height = height + 22
    end
    if entry.action_label and entry.action_label ~= '' then
        height = height + 22
    end

    imgui.PushStyleVarFloat(imgui.StyleVar.ChildRounding, 12)
    imgui.PushStyleColor(imgui.Col.ChildBg, to_vec4(theme.background))
    imgui.PushStyleColor(imgui.Col.Border, to_vec4(theme.border))

    imgui.BeginChild('##history_card_' .. entry.id .. '_' .. index, imgui.ImVec2(0, height), true)

    local draw_list = imgui.GetWindowDrawList()
    local win_pos = imgui.GetWindowPos()
    local win_size = imgui.GetWindowSize()
    draw_list:AddRectFilled(
        imgui.ImVec2(win_pos.x, win_pos.y),
        imgui.ImVec2(win_pos.x + 4, win_pos.y + win_size.y),
        imgui.GetColorU32Vec4(to_vec4(theme.accent)),
        12,
        imgui.DrawCornerFlags.TopLeft + imgui.DrawCornerFlags.BotLeft
    )
    draw_list:AddRectFilled(
        imgui.ImVec2(win_pos.x + 14, win_pos.y + 14),
        imgui.ImVec2(win_pos.x + 84, win_pos.y + 40),
        imgui.GetColorU32Vec4(to_vec4(theme.badge)),
        10
    )

    imgui.SetCursorPos(imgui.ImVec2(22, 18))
    imgui.PushStyleColor(imgui.Col.Text, to_vec4(theme.title))
    imgui.Text(status_label(entry.status))
    imgui.PopStyleColor()

    imgui.SetCursorPos(imgui.ImVec2(98, 18))
    imgui.PushStyleColor(imgui.Col.Text, to_vec4(theme.meta))
    imgui.Text(string.format('%s  %s', trim_text(entry.script_id, 24), format_clock(entry.created_at)))
    imgui.PopStyleColor()

    imgui.SetCursorPos(imgui.ImVec2(22, 52))
    imgui.PushStyleColor(imgui.Col.Text, to_vec4(theme.title))
    imgui.Text(trim_text(entry.title ~= '' and entry.title or entry.text, 60))
    imgui.PopStyleColor()

    imgui.SetCursorPos(imgui.ImVec2(22, 76))
    imgui.PushStyleColor(imgui.Col.Text, to_vec4(theme.text))
    imgui.TextWrapped(entry.text ~= '' and entry.text or '-')
    imgui.PopStyleColor()

    if entry.description and entry.description ~= '' then
        imgui.SetCursorPosY(imgui.GetCursorPosY() + 4)
        imgui.PushStyleColor(imgui.Col.Text, to_vec4(theme.meta))
        imgui.TextWrapped(entry.description)
        imgui.PopStyleColor()
    end

    if entry.image_path and entry.image_path ~= '' then
        imgui.PushStyleColor(imgui.Col.Text, to_vec4(theme.meta))
        imgui.Text('Image: ' .. entry.image_path)
        imgui.PopStyleColor()
    end

    if entry.action_label and entry.action_label ~= '' then
        imgui.PushStyleColor(imgui.Col.Text, to_vec4(theme.meta))
        imgui.Text('Action: ' .. entry.action_label)
        imgui.PopStyleColor()
    end

    imgui.EndChild()
    imgui.PopStyleColor(2)
    imgui.PopStyleVar()
end

function render_history_window()
    imgui.PushStyleVarFloat(imgui.StyleVar.WindowRounding, 18)
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(18, 18))
    imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(0.06, 0.07, 0.09, 0.98))
    imgui.PushStyleColor(imgui.Col.Border, imgui.ImVec4(0.16, 0.18, 0.22, 1.0))
    imgui.SetNextWindowSize(imgui.ImVec2(760, 520), imgui.Cond.FirstUseEver)
    imgui.Begin('Notification History', history_open,
        imgui.WindowFlags.NoCollapse
    )

    local active_count = #active
    local total_count = #history

    imgui.PushStyleVarFloat(imgui.StyleVar.ChildRounding, 16)
    imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0.09, 0.11, 0.14, 1.0))
    imgui.BeginChild('##history_header', imgui.ImVec2(0, 92), true)
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.95, 0.97, 1.0, 1.0))
    imgui.Text('Session History')
    imgui.PopStyleColor()
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.60, 0.67, 0.77, 1.0))
    imgui.Text('Session: ' .. (session and session.session_id or 'unknown'))
    imgui.Text(string.format('Visible now: %d   Stored in session: %d', active_count, total_count))
    imgui.PopStyleColor()
    imgui.EndChild()
    imgui.PopStyleColor()
    imgui.PopStyleVar()

    if imgui.Button('Spawn demo pack', imgui.ImVec2(130, 28)) then
        push_demo_pack()
    end
    imgui.SameLine()
    if imgui.Button('Clear history', imgui.ImVec2(110, 28)) then
        history = {}
    end
    imgui.SameLine()
    if imgui.Button('Close window', imgui.ImVec2(110, 28)) then
        history_open[0] = false
    end
    imgui.SameLine()
    imgui.SetNextItemWidth(140)
    if imgui.BeginCombo('##history_filter', HISTORY_FILTERS[history_filter]) then
        for index, label in ipairs(HISTORY_FILTERS) do
            local selected = history_filter == index
            if imgui.Selectable(label, selected) then
                history_filter = index
            end
            if selected then
                imgui.SetItemDefaultFocus()
            end
        end
        imgui.EndCombo()
    end

    imgui.Separator()

    imgui.BeginChild('##history_scroll', imgui.ImVec2(0, 0), false)
    local shown = 0
    if #history == 0 then
        imgui.Text('No notifications yet.')
    else
        for index, entry in ipairs(history) do
            if status_matches(entry) then
                history_card(entry, index)
                shown = shown + 1
            end
        end
        if shown == 0 then
            imgui.Text('No entries match the selected filter.')
        end
    end
    imgui.EndChild()

    imgui.End()
    imgui.PopStyleColor(2)
    imgui.PopStyleVar(2)
end

function push_demo_pack()
    notify.push({
        script_id = 'Demo Ocean',
        title = 'Market updated',
        text = 'Three new offers were parsed and added to the local cache.',
        description = 'Default ocean preset with auto close.',
        duration = 6,
        theme = 'ocean'
    })

    notify.push({
        script_id = 'Demo Ember',
        title = 'Action required',
        text = 'Storage sync needs confirmation before the next operation.',
        description = 'This one is sticky and stays until dismissed.',
        sticky = true,
        theme = 'ember'
    })

    notify.push({
        script_id = 'Demo Custom',
        title = 'Custom theme',
        text = 'Any script can send its own palette for branding.',
        description = 'Theme override example.',
        duration = 8,
        theme = 'graphite',
        theme_override = {
            accent = { 0.65, 0.48, 0.96, 1.0 },
            accent_soft = { 0.65, 0.48, 0.96, 0.18 },
            badge = { 0.18, 0.12, 0.28, 1.0 }
        }
    })
end

local function register_commands()
    sampRegisterChatCommand('notifyhistory', function()
        history_open[0] = not history_open[0]
    end)

    sampRegisterChatCommand('notifydemo', function()
        push_demo_pack()
    end)
end

local function get_manager_version()
    if thisScript then
        local script_info = thisScript()
        if script_info and script_info.version then
            return tostring(script_info.version)
        end
    end
    return '1.0'
end

function main()
    local bootstrap_done = false
    local bootstrap_error = nil

    ensure_notification_library(function(ok, err)
        if not ok then
            bootstrap_error = err or 'notification library is unavailable'
            bootstrap_done = true
            return
        end

        local ok_require, loaded_notify = pcall(require, 'session_notifications')
        if not ok_require then
            bootstrap_error = 'failed to load session_notifications.lua: ' .. tostring(loaded_notify)
            bootstrap_done = true
            return
        end

        notify = loaded_notify
        bootstrap_done = true
    end)

    while not bootstrap_done do
        wait(0)
    end

    if not notify then
        error(bootstrap_error or 'notification library bootstrap failed')
    end

    session = notify.start_session(MANAGER_HOST_NAME)
    queue_offset = file_size(notify.get_paths().queue_file)
    notify.set_runtime({
        host_name = MANAGER_HOST_NAME,
        session_id = session.session_id,
        version = get_manager_version(),
        started_at = session.started_at
    })

    repeat
        wait(100)
    until isSampAvailable()

    register_commands()
    local last_heartbeat = os.clock()

    while true do
        wait(0)
        poll_queue()
        update_active()

        local now_clock = os.clock()
        if now_clock - last_heartbeat >= HEARTBEAT_INTERVAL then
            notify.touch_runtime({
                host_name = MANAGER_HOST_NAME,
                session_id = session.session_id,
                version = get_manager_version()
            })
            last_heartbeat = now_clock
        end
    end
end
