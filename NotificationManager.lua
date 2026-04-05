script_name('Notification Manager')
script_author('Sand')
script_version('1.0')

local imgui = require('mimgui')

local function load_json_module()
    local ok_dkjson, dkjson = pcall(require, 'dkjson')
    if ok_dkjson and type(dkjson) == 'table' then
        return {
            decode = function(text)
                local value = dkjson.decode(text)
                return value
            end,
            encode = function(value, state)
                return dkjson.encode(value, state)
            end
        }
    end

    local ok_cjson, cjson = pcall(require, 'cjson')
    if ok_cjson and type(cjson) == 'table' then
        return {
            decode = function(text)
                local ok, value = pcall(cjson.decode, text)
                if ok then
                    return value
                end
                return nil
            end,
            encode = function(value)
                return cjson.encode(value)
            end
        }
    end

    error('failed to load JSON module: dkjson and cjson are unavailable')
end

local function require_notification_library()
    local last_error = nil

    for _, module_name in ipairs({ 'session_notifications', 'lib.session_notifications' }) do
        local ok, loaded = pcall(require, module_name)
        if ok then
            return loaded
        end
        last_error = loaded
    end

    return nil, last_error
end

local function set_frame_flag(frame, key, value)
    if frame == nil then
        return
    end

    pcall(function()
        frame[key] = value
    end)
end

local json = load_json_module()
local notify = nil

local MANAGER_HOST_NAME = 'NotificationManager'
local HEARTBEAT_INTERVAL = 2
local PROJECT_REPO_URL = 'https://github.com/Mister-Sand/session_notifications'
local QUEUE_POLL_INTERVAL = 0.12
local ACTIVE_UPDATE_INTERVAL = 0.05
local IDLE_LOOP_WAIT_MS = 100
local MOBILE_TOAST_MAX_SCREEN_RATIO = 0.38
local MOBILE_TOAST_WIDTH_SCREEN_RATIO = 0.34
local DPI_SCALE = tonumber(MONET_DPI_SCALE) or 1

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

local function dpi(value)
    value = tonumber(value) or 0
    if value < 0 then
        return value
    end
    return value * DPI_SCALE
end

local function dpi_vec2(x, y)
    return imgui.ImVec2(dpi(x), dpi(y))
end

local function max_value(a, b)
    if a >= b then
        return a
    end
    return b
end

local function min_value(a, b)
    if a <= b then
        return a
    end
    return b
end

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

local PATH_SEPARATOR = detect_separator()

local function normalize_path(path)
    path = tostring(path or '')
    if PATH_SEPARATOR == '/' then
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
                result = result:gsub('[\\/]+$', '') .. PATH_SEPARATOR .. part
            end
        end
    end

    return result
end

local LIBRARY_PATH = join_path(getWorkingDirectory(), 'lib', 'session_notifications.lua')

local state = {
    history_open = imgui.new.bool(false),
    active = {},
    history = {},
    texture_cache = {},
    session = nil,
    queue_offset = 0,
    queue_file_path = nil,
    history_filter = 1
}

local to_vec4
local resolve_texture
local render_toasts
local render_history_window
local push_demo_pack

local function ensure_notification_library()
    if doesFileExist(LIBRARY_PATH) then
        return true
    end

    return false, string.format(
        'session_notifications.lua is missing. Install it manually from %s',
        PROJECT_REPO_URL
    )
end

local overlay_frame = imgui.OnFrame(
    function()
        return #state.active > 0
    end,
    function()
        render_toasts()
    end
)
set_frame_flag(overlay_frame, 'HideCursor', true)

local history_frame = imgui.OnFrame(
    function()
        return state.history_open[0]
    end,
    function()
        render_history_window()
    end
)
set_frame_flag(history_frame, 'HideCursor', false)

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

local function get_toast_width(screen_width)
    local toast_width = dpi(TOAST_WIDTH)
    if MONET_DPI_SCALE ~= nil then
        toast_width = max_value(dpi(TOAST_WIDTH), screen_width * MOBILE_TOAST_WIDTH_SCREEN_RATIO)
        toast_width = min_value(toast_width, screen_width - dpi(24))
    end
    return toast_width
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

local function draw_wrapped_text(text, color, wrap_width)
    imgui.PushStyleColor(imgui.Col.Text, to_vec4(color))
    imgui.PushTextWrapPos(imgui.GetCursorPosX() + wrap_width)
    imgui.TextWrapped(tostring(text or ''))
    imgui.PopTextWrapPos()
    imgui.PopStyleColor()
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

local function build_toast_layout(item, has_badge, toast_width)
    local content_x = has_badge and dpi(98) or dpi(16)
    local title_y = dpi(40)
    local right_pad = dpi(16)
    local action_height = dpi(26)
    local content_width = toast_width - content_x - right_pad
    local wrap_width = content_width - dpi(12)

    return {
        has_badge = has_badge,
        content_x = content_x,
        content_width = content_width,
        wrap_width = wrap_width,
        title_y = title_y,
        action_height = action_height,
        title_text = item.title ~= '' and item.title or item.text,
        body_text = item.text ~= '' and item.text or '-',
    }
end

local function get_toast_layout(item, toast_width)
    local has_badge = ensure_item_texture(item) ~= nil
    if item.layout and item.layout_badge_state == has_badge and item.layout_width == toast_width then
        return item.layout
    end

    local layout = build_toast_layout(item, has_badge, toast_width)
    item.layout = layout
    item.layout_badge_state = has_badge
    item.layout_width = toast_width
    return layout
end

to_vec4 = function(color)
    return imgui.ImVec4(color[1], color[2], color[3], color[4] or 1)
end

resolve_texture = function(path)
    path = normalize_path(path)
    if path == '' or not doesFileExist(path) then
        return nil
    end

    if not imgui.IsInitialized() then
        return nil
    end

    if state.texture_cache[path] ~= nil then
        return state.texture_cache[path]
    end

    state.texture_cache[path] = imgui.CreateTextureFromFile(path)
    return state.texture_cache[path]
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
    local filter = HISTORY_FILTERS[state.history_filter]
    if filter == 'All' then
        return true
    end
    return string.lower(filter) == string.lower(entry.status or '')
end

local function add_history(entry)
    table.insert(state.history, 1, entry)
    while #state.history > MAX_HISTORY do
        table.remove(state.history)
    end
end

local function expire_item(item, reason)
    if item.closed then
        return
    end

    item.closed = true
    item.closed_reason = reason or 'dismissed'
    item.closed_at = os.time()
end

local function make_history_entry(item)
    return {
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
    }
end

local function make_active_item(payload)
    local received_clock = os.clock()
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
        received_clock = received_clock,
        last_clock = received_clock,
        is_hovered = false,
        closed = false,
        closed_reason = nil,
        theme = payload.theme or notify.presets[payload.theme_name] or notify.presets.ocean,
        layout = nil,
        layout_badge_state = nil,
        layout_width = nil,
        measured_height = nil,
        full_height = nil,
        needs_scroll = false
    }

    item.texture = resolve_texture(item.image_path)
    item.height = dpi(TOAST_MIN_HEIGHT)
    item.expires_clock = item.sticky and math.huge or (received_clock + item.duration)
    return item
end

local function activate_notification(payload)
    local item = make_active_item(payload)
    table.insert(state.active, item)
    add_history(make_history_entry(item))
end

local function sync_history_status(item)
    for _, entry in ipairs(state.history) do
        if entry.id == item.id then
            entry.status = item.closed_reason or 'closed'
            entry.closed_at = item.closed_at or os.time()
            return
        end
    end
end

local function queue_matches_current_session(payload)
    return type(payload) == 'table'
        and payload.kind == 'notification'
        and state.session
        and payload.session_id == state.session.session_id
end

local function poll_queue()
    if not state.queue_file_path or state.queue_file_path == '' then
        return
    end

    local file = io.open(state.queue_file_path, 'r')
    if not file then
        return
    end

    local queue_size = file:seek('end') or state.queue_offset
    if queue_size <= state.queue_offset then
        file:close()
        return
    end

    file:seek('set', state.queue_offset)
    while true do
        local line = file:read('*line')
        if not line then
            break
        end

        if line ~= '' then
            local payload = json.decode(line)
            if queue_matches_current_session(payload) then
                activate_notification(payload)
            end
        end
    end

    state.queue_offset = file:seek() or state.queue_offset
    file:close()
end

local function trim_active_overflow()
    while #state.active > MAX_ACTIVE do
        local oldest = table.remove(state.active, 1)
        if oldest then
            expire_item(oldest, 'overflow')
            sync_history_status(oldest)
        end
    end
end

local function update_active(now_clock)
    for index = #state.active, 1, -1 do
        local item = state.active[index]
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
            table.remove(state.active, index)
        end
    end

    trim_active_overflow()
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
        dpi(12)
    )

    imgui.SetCursorPos(imgui.ImVec2(origin_x - imgui.GetWindowPos().x, origin_y - imgui.GetWindowPos().y))
    imgui.Image(texture, imgui.ImVec2(size, size))
end

local function draw_toast_chrome(draw_list, win_pos, win_size, theme)
    draw_list:AddRectFilled(
        imgui.ImVec2(win_pos.x, win_pos.y),
        imgui.ImVec2(win_pos.x + dpi(4), win_pos.y + win_size.y),
        imgui.GetColorU32Vec4(to_vec4(theme.accent)),
        dpi(16),
        imgui.DrawCornerFlags.TopLeft + imgui.DrawCornerFlags.BotLeft
    )

    draw_list:AddRectFilled(
        imgui.ImVec2(win_pos.x + dpi(1), win_pos.y + win_size.y - dpi(4)),
        imgui.ImVec2(win_pos.x + win_size.x - dpi(1), win_pos.y + win_size.y - dpi(1)),
        imgui.GetColorU32Vec4(to_vec4(theme.accent_soft)),
        dpi(12)
    )
end

local function render_toast_header(item, theme, toast_width, layout, draw_list, win_pos, win_size)
    draw_toast_chrome(draw_list, win_pos, win_size, theme)

    if layout.has_badge then
        draw_badge(draw_list, win_pos.x + dpi(18), win_pos.y + dpi(18), dpi(TOAST_IMAGE), theme, item)
    end

    imgui.SetCursorPos(imgui.ImVec2(layout.content_x, dpi(16)))
    imgui.PushStyleColor(imgui.Col.Text, to_vec4(theme.meta))
    imgui.Text(trim_text(item.script_id, 24) .. '  ' .. format_clock(item.created_at))
    imgui.PopStyleColor()

    imgui.SetCursorPos(imgui.ImVec2(toast_width - dpi(46), dpi(14)))
    imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0, 0, 0, 0))
    imgui.PushStyleColor(imgui.Col.ButtonHovered, to_vec4(theme.accent_soft))
    imgui.PushStyleColor(imgui.Col.ButtonActive, to_vec4(theme.accent_soft))
    if imgui.Button('x##close_' .. item.id, dpi_vec2(28, 22)) then
        expire_item(item, 'dismissed')
    end
    imgui.PopStyleColor(3)
end

local function render_toast_body(item, theme, layout, height, progress_reserved)
    local has_action = item.action_label ~= '' and item.action_id ~= ''
    local footer_height = imgui.GetTextLineHeight()
    local footer_y = layout.title_y
    local uses_scroll = item.needs_scroll or false

    if uses_scroll then
        local action_reserved = has_action and (layout.action_height + dpi(10)) or 0
        local content_height = max_value(
            dpi(34),
            height - layout.title_y - footer_height - progress_reserved - action_reserved - dpi(24)
        )

        imgui.SetCursorPos(imgui.ImVec2(layout.content_x, layout.title_y))
        imgui.BeginChild(
            '##notification_toast_content_' .. item.id,
            imgui.ImVec2(layout.content_width, content_height),
            false
        )

        draw_wrapped_text(layout.title_text, theme.title, layout.wrap_width)
        imgui.Dummy(dpi_vec2(0, 6))
        draw_wrapped_text(layout.body_text, theme.text, layout.wrap_width)

        if item.description ~= '' then
            imgui.Dummy(dpi_vec2(0, 6))
            draw_wrapped_text(item.description, theme.meta, layout.wrap_width)
        end

        item.is_hovered = item.is_hovered or imgui.IsWindowHovered()
        imgui.EndChild()
        footer_y = layout.title_y + content_height + dpi(6)
    else
        imgui.SetCursorPos(imgui.ImVec2(layout.content_x, layout.title_y))
        draw_wrapped_text(layout.title_text, theme.title, layout.wrap_width)

        imgui.Dummy(dpi_vec2(0, 6))
        imgui.SetCursorPosX(layout.content_x)
        draw_wrapped_text(layout.body_text, theme.text, layout.wrap_width)

        if item.description ~= '' then
            imgui.Dummy(dpi_vec2(0, 6))
            imgui.SetCursorPosX(layout.content_x)
            draw_wrapped_text(item.description, theme.meta, layout.wrap_width)
        end

        footer_y = imgui.GetCursorPosY() + dpi(6)
    end

    return footer_y, footer_height, has_action, uses_scroll
end

local function emit_toast_action(item)
    notify.emit_action({
        target_script_id = item.target_script_id,
        source_script_id = MANAGER_HOST_NAME,
        notification_id = item.id,
        action_id = item.action_id,
        action_payload = item.action_payload
    })
    expire_item(item, 'dismissed')
end

local function render_toast_action(item, theme, layout, footer_y)
    if item.action_label == '' or item.action_id == '' then
        return footer_y
    end

    imgui.SetCursorPos(imgui.ImVec2(layout.content_x, footer_y))
    imgui.PushStyleColor(imgui.Col.Button, to_vec4(theme.accent_soft))
    imgui.PushStyleColor(imgui.Col.ButtonHovered, to_vec4(theme.badge))
    imgui.PushStyleColor(imgui.Col.ButtonActive, to_vec4(theme.badge))
    if imgui.Button(item.action_label .. '##action_' .. item.id, imgui.ImVec2(layout.content_width, layout.action_height)) then
        emit_toast_action(item)
    end
    imgui.PopStyleColor(3)

    return footer_y + layout.action_height + dpi(8)
end

local function render_toast_status(item, theme, layout, footer_y, now_clock)
    imgui.SetCursorPos(imgui.ImVec2(layout.content_x, footer_y))
    imgui.PushStyleColor(imgui.Col.Text, to_vec4(theme.meta))
    if item.sticky then
        imgui.Text('Pinned notification')
    else
        local left = max_value(0, item.expires_clock - now_clock)
        imgui.Text(string.format('Closes in %.1fs', left))
    end
    imgui.PopStyleColor()
end

local function draw_toast_progress(draw_list, win_pos, win_size, theme, item, now_clock)
    if item.sticky or item.duration <= 0 then
        return 0
    end

    local progress = max_value(0, min_value(1, (item.expires_clock - now_clock) / item.duration))
    draw_list:AddRectFilled(
        imgui.ImVec2(win_pos.x + dpi(88), win_pos.y + win_size.y - dpi(10)),
        imgui.ImVec2(
            win_pos.x + dpi(88) + (win_size.x - dpi(112)) * progress,
            win_pos.y + win_size.y - dpi(6)
        ),
        imgui.GetColorU32Vec4(to_vec4(theme.accent)),
        dpi(3)
    )

    return dpi(12)
end

local function update_toast_measurement(item, layout, footer_y, footer_height, progress_reserved, toast_max_height, used_scroll)
    if used_scroll then
        item.needs_scroll = true
        item.full_height = max_value(item.full_height or 0, toast_max_height + dpi(1))
        item.measured_height = toast_max_height
        return
    end

    local badge_bottom = layout.has_badge and (dpi(18) + dpi(TOAST_IMAGE)) or 0
    local content_bottom = max_value(badge_bottom, footer_y + footer_height)
    local raw_height = max_value(
        dpi(TOAST_MIN_HEIGHT),
        content_bottom + dpi(16) + progress_reserved + dpi(TOAST_HEIGHT_BUFFER)
    )

    item.full_height = raw_height
    item.needs_scroll = raw_height > toast_max_height
    item.measured_height = item.needs_scroll and toast_max_height or raw_height
end

render_toasts = function()
    local sw, sh = getScreenResolution()
    local toast_width = get_toast_width(sw)
    local toast_max_height = dpi(TOAST_MAX_HEIGHT)
    if MONET_DPI_SCALE ~= nil then
        toast_max_height = min_value(dpi(TOAST_MAX_HEIGHT), sh * MOBILE_TOAST_MAX_SCREEN_RATIO)
    end
    local y = sh - dpi(TOAST_MARGIN)
    local now_clock = os.clock()

    for index = #state.active, 1, -1 do
        local item = state.active[index]
        local theme = item.theme
        local layout = get_toast_layout(item, toast_width)
        local desired_height = item.measured_height or item.height or dpi(TOAST_MIN_HEIGHT)
        local needs_scroll = item.needs_scroll or false
        local height = needs_scroll and toast_max_height or desired_height
        item.height = height
        local position = imgui.ImVec2(sw - toast_width - dpi(TOAST_MARGIN), y - height)

        imgui.SetNextWindowPos(position, imgui.Cond.Always)
        imgui.SetNextWindowSize(imgui.ImVec2(toast_width, height), imgui.Cond.Always)

        imgui.PushStyleVarFloat(imgui.StyleVar.WindowRounding, dpi(16))
        imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, dpi_vec2(16, 16))
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
        render_toast_header(item, theme, toast_width, layout, draw_list, win_pos, win_size)

        local progress_reserved = (not item.sticky and item.duration > 0) and dpi(12) or 0
        local footer_y, footer_height, has_action, used_scroll = render_toast_body(
            item,
            theme,
            layout,
            height,
            progress_reserved
        )

        if has_action then
            footer_y = render_toast_action(item, theme, layout, footer_y)
        end

        render_toast_status(item, theme, layout, footer_y, now_clock)
        draw_toast_progress(draw_list, win_pos, win_size, theme, item, now_clock)
        update_toast_measurement(
            item,
            layout,
            footer_y,
            footer_height,
            progress_reserved,
            toast_max_height,
            used_scroll
        )

        imgui.End()
        imgui.PopStyleColor(2)
        imgui.PopStyleVar(2)

        y = y - height - dpi(TOAST_GAP)
    end
end

local function history_card(entry, index)
    local theme = entry.theme or notify.presets.ocean
    local height = dpi(128)
    if entry.description and entry.description ~= '' then
        height = height + dpi(26)
    end
    if entry.image_path and entry.image_path ~= '' then
        height = height + dpi(22)
    end
    if entry.action_label and entry.action_label ~= '' then
        height = height + dpi(22)
    end

    imgui.PushStyleVarFloat(imgui.StyleVar.ChildRounding, dpi(12))
    imgui.PushStyleColor(imgui.Col.ChildBg, to_vec4(theme.background))
    imgui.PushStyleColor(imgui.Col.Border, to_vec4(theme.border))

    imgui.BeginChild('##history_card_' .. entry.id .. '_' .. index, imgui.ImVec2(0, height), true)

    local draw_list = imgui.GetWindowDrawList()
    local win_pos = imgui.GetWindowPos()
    local win_size = imgui.GetWindowSize()
    draw_list:AddRectFilled(
        imgui.ImVec2(win_pos.x, win_pos.y),
        imgui.ImVec2(win_pos.x + dpi(4), win_pos.y + win_size.y),
        imgui.GetColorU32Vec4(to_vec4(theme.accent)),
        dpi(12),
        imgui.DrawCornerFlags.TopLeft + imgui.DrawCornerFlags.BotLeft
    )
    draw_list:AddRectFilled(
        imgui.ImVec2(win_pos.x + dpi(14), win_pos.y + dpi(14)),
        imgui.ImVec2(win_pos.x + dpi(84), win_pos.y + dpi(40)),
        imgui.GetColorU32Vec4(to_vec4(theme.badge)),
        dpi(10)
    )

    imgui.SetCursorPos(dpi_vec2(22, 18))
    imgui.PushStyleColor(imgui.Col.Text, to_vec4(theme.title))
    imgui.Text(status_label(entry.status))
    imgui.PopStyleColor()

    imgui.SetCursorPos(dpi_vec2(98, 18))
    imgui.PushStyleColor(imgui.Col.Text, to_vec4(theme.meta))
    imgui.Text(string.format('%s  %s', trim_text(entry.script_id, 24), format_clock(entry.created_at)))
    imgui.PopStyleColor()

    imgui.SetCursorPos(dpi_vec2(22, 52))
    imgui.PushStyleColor(imgui.Col.Text, to_vec4(theme.title))
    imgui.Text(trim_text(entry.title ~= '' and entry.title or entry.text, 60))
    imgui.PopStyleColor()

    imgui.SetCursorPos(dpi_vec2(22, 76))
    imgui.PushStyleColor(imgui.Col.Text, to_vec4(theme.text))
    imgui.TextWrapped(entry.text ~= '' and entry.text or '-')
    imgui.PopStyleColor()

    if entry.description and entry.description ~= '' then
        imgui.SetCursorPosY(imgui.GetCursorPosY() + dpi(4))
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

local function render_history_header()
    imgui.PushStyleVarFloat(imgui.StyleVar.ChildRounding, dpi(16))
    imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0.09, 0.11, 0.14, 1.0))
    imgui.BeginChild('##history_header', dpi_vec2(0, 92), true)
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.95, 0.97, 1.0, 1.0))
    imgui.Text('Session History')
    imgui.PopStyleColor()
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.60, 0.67, 0.77, 1.0))
    imgui.Text('Session: ' .. (state.session and state.session.session_id or 'unknown'))
    imgui.Text(string.format('Visible now: %d   Stored in session: %d', #state.active, #state.history))
    imgui.PopStyleColor()
    imgui.EndChild()
    imgui.PopStyleColor()
    imgui.PopStyleVar()
end

render_history_window = function()
    imgui.PushStyleVarFloat(imgui.StyleVar.WindowRounding, dpi(18))
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, dpi_vec2(18, 18))
    imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(0.06, 0.07, 0.09, 0.98))
    imgui.PushStyleColor(imgui.Col.Border, imgui.ImVec4(0.16, 0.18, 0.22, 1.0))
    imgui.SetNextWindowSize(dpi_vec2(760, 520), imgui.Cond.FirstUseEver)
    imgui.Begin('Notification History', state.history_open,
        imgui.WindowFlags.NoCollapse
    )

    render_history_header()

    if imgui.Button('Spawn demo pack', dpi_vec2(130, 28)) then
        push_demo_pack()
    end
    imgui.SameLine()
    if imgui.Button('Clear history', dpi_vec2(110, 28)) then
        state.history = {}
    end
    imgui.SameLine()
    if imgui.Button('Close window', dpi_vec2(110, 28)) then
        state.history_open[0] = false
    end
    imgui.SameLine()
    imgui.SetNextItemWidth(dpi(140))
    if imgui.BeginCombo('##history_filter', HISTORY_FILTERS[state.history_filter]) then
        for index, label in ipairs(HISTORY_FILTERS) do
            local selected = state.history_filter == index
            if imgui.Selectable(label, selected) then
                state.history_filter = index
            end
            if selected then
                imgui.SetItemDefaultFocus()
            end
        end
        imgui.EndCombo()
    end

    imgui.Separator()

    imgui.BeginChild('##history_scroll', dpi_vec2(0, 0), false)
    local shown = 0
    if #state.history == 0 then
        imgui.Text('No notifications yet.')
    else
        for index, entry in ipairs(state.history) do
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

push_demo_pack = function()
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
        state.history_open[0] = not state.history_open[0]
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

local function bootstrap_notification_system()
    local ok, err = ensure_notification_library()
    if not ok then
        return nil, err or 'notification library is unavailable'
    end

    local loaded_notify, load_err = require_notification_library()
    if not loaded_notify then
        return nil, 'failed to load session_notifications.lua: ' .. tostring(load_err)
    end

    return loaded_notify
end

function main()
    local loaded_notify, load_err = bootstrap_notification_system()
    if not loaded_notify then
        error(load_err or 'notification library bootstrap failed')
    end

    notify = loaded_notify
    state.session = notify.start_session(MANAGER_HOST_NAME)

    local paths = notify.get_paths()
    state.queue_file_path = paths and paths.queue_file or nil
    state.queue_offset = file_size(state.queue_file_path)
    notify.set_runtime({
        host_name = MANAGER_HOST_NAME,
        session_id = state.session.session_id,
        version = get_manager_version(),
        started_at = state.session.started_at
    })

    repeat
        wait(100)
    until isSampAvailable()

    register_commands()
    local last_heartbeat = os.clock()
    local last_queue_poll_clock = 0
    local last_active_update_clock = 0

    while true do
        local is_busy = #state.active > 0 or state.history_open[0]
        wait(is_busy and 0 or IDLE_LOOP_WAIT_MS)

        local now_clock = os.clock()
        if now_clock - last_queue_poll_clock >= QUEUE_POLL_INTERVAL then
            poll_queue()
            last_queue_poll_clock = now_clock
        end

        if #state.active > 0 and (now_clock - last_active_update_clock >= ACTIVE_UPDATE_INTERVAL) then
            update_active(now_clock)
            last_active_update_clock = now_clock
        end

        if now_clock - last_heartbeat >= HEARTBEAT_INTERVAL then
            notify.touch_runtime({
                host_name = MANAGER_HOST_NAME,
                session_id = state.session.session_id,
                version = get_manager_version()
            })
            last_heartbeat = now_clock
        end
    end
end
