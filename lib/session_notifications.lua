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

local json = load_json_module()

local M = {
    VERSION = '1.0'
}

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

local BASE_DIR = join_path(getWorkingDirectory(), 'config', 'session_notifications')
local STATE_FILE = join_path(BASE_DIR, 'state.json')
local RUNTIME_FILE = join_path(BASE_DIR, 'runtime.json')
local QUEUE_FILE = join_path(BASE_DIR, 'queue.jsonl')
local ACTION_QUEUE_FILE = join_path(BASE_DIR, 'actions.jsonl')
local CURSOR_DIR = join_path(BASE_DIR, 'cursors')

local callbacks = {}
local action_poll_state = {}
local ACTION_POLL_INTERVAL = 0.10

local PRESETS = {
    ocean = {
        accent = { 0.15, 0.60, 0.96, 1.0 },
        accent_soft = { 0.15, 0.60, 0.96, 0.18 },
        background = { 0.08, 0.10, 0.14, 0.96 },
        border = { 0.18, 0.24, 0.34, 1.0 },
        title = { 0.95, 0.98, 1.00, 1.0 },
        text = { 0.84, 0.89, 0.96, 1.0 },
        meta = { 0.59, 0.69, 0.81, 1.0 },
        badge = { 0.12, 0.20, 0.31, 1.0 }
    },
    ember = {
        accent = { 0.98, 0.46, 0.28, 1.0 },
        accent_soft = { 0.98, 0.46, 0.28, 0.18 },
        background = { 0.14, 0.09, 0.08, 0.96 },
        border = { 0.28, 0.18, 0.16, 1.0 },
        title = { 1.00, 0.96, 0.93, 1.0 },
        text = { 0.95, 0.84, 0.78, 1.0 },
        meta = { 0.86, 0.63, 0.53, 1.0 },
        badge = { 0.25, 0.14, 0.12, 1.0 }
    },
    emerald = {
        accent = { 0.15, 0.78, 0.52, 1.0 },
        accent_soft = { 0.15, 0.78, 0.52, 0.18 },
        background = { 0.07, 0.12, 0.10, 0.96 },
        border = { 0.13, 0.26, 0.21, 1.0 },
        title = { 0.94, 1.00, 0.97, 1.0 },
        text = { 0.80, 0.93, 0.88, 1.0 },
        meta = { 0.55, 0.77, 0.68, 1.0 },
        badge = { 0.10, 0.22, 0.18, 1.0 }
    },
    graphite = {
        accent = { 0.82, 0.84, 0.90, 1.0 },
        accent_soft = { 0.82, 0.84, 0.90, 0.16 },
        background = { 0.10, 0.11, 0.13, 0.96 },
        border = { 0.20, 0.22, 0.26, 1.0 },
        title = { 0.98, 0.98, 0.99, 1.0 },
        text = { 0.82, 0.84, 0.88, 1.0 },
        meta = { 0.58, 0.61, 0.69, 1.0 },
        badge = { 0.16, 0.17, 0.20, 1.0 }
    }
}

local function max_value(a, b)
    if a >= b then
        return a
    end
    return b
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

local function ensure_environment()
    ensure_dir(BASE_DIR)
    ensure_dir(CURSOR_DIR)
end

local function read_file(path)
    path = normalize_path(path)
    local file = io.open(path, 'r')
    if not file then
        return nil
    end

    local content = file:read('*a')
    file:close()
    return content
end

local function write_file(path, content)
    path = normalize_path(path)
    local file = assert(io.open(path, 'w'))
    file:write(content)
    file:close()
end

local function append_line(path, line)
    path = normalize_path(path)
    local file = assert(io.open(path, 'a'))
    file:write(line)
    file:close()
end

local function read_number_file(path)
    local content = read_file(path)
    if not content or content == '' then
        return 0
    end
    return tonumber(content) or 0
end

local function clone_table(value)
    if type(value) ~= 'table' then
        return value
    end

    local result = {}
    for key, item in pairs(value) do
        result[key] = clone_table(item)
    end
    return result
end

local function clamp01(value)
    value = tonumber(value) or 0
    if value < 0 then
        return 0
    end
    if value > 1 then
        return 1
    end
    return value
end

local function sanitize_color(color)
    if type(color) ~= 'table' then
        return nil
    end

    return {
        clamp01(color[1]),
        clamp01(color[2]),
        clamp01(color[3]),
        clamp01(color[4] == nil and 1 or color[4])
    }
end

local function merge_theme(base_name, override)
    local result = clone_table(PRESETS[base_name] or PRESETS.ocean)
    if type(override) ~= 'table' then
        return result
    end

    for key, color in pairs(override) do
        local sanitized = sanitize_color(color)
        if sanitized then
            result[key] = sanitized
        end
    end
    return result
end

local function make_id(prefix)
    local random_part = math.random(100000, 999999)
    local clock_part = math.floor(os.clock() * 1000000)
    return string.format('%s-%d-%d-%d', prefix, os.time(), clock_part, random_part)
end

local function safe_name(value)
    value = tostring(value or 'unknown')
    return (value:gsub('[^%w%-_]+', '_'))
end

local function get_cursor_path(script_id)
    ensure_environment()
    return join_path(CURSOR_DIR, safe_name(script_id) .. '.cursor')
end

local function read_state()
    ensure_environment()
    local raw = read_file(STATE_FILE)
    if not raw or raw == '' then
        return nil
    end

    local data = json.decode(raw)
    if type(data) ~= 'table' then
        return nil
    end

    return data
end

local function get_script_id()
    if script and script.this and script.this.name then
        return tostring(script.this.name)
    end
    return 'unknown-script'
end

local DEFAULT_MANAGER_CONFIG = {
    host_name = 'NotificationManager',
    file_name = 'NotificationManager.lua',
    required_version = '1.0',
    heartbeat_ttl = 6,
    load_timeout = 8,
    raw_url = 'https://raw.githubusercontent.com/Mister-Sand/session_notifications/main/NotificationManager.lua',
    library_file = [[lib\session_notifications.lua]],
    library_raw_url = 'https://raw.githubusercontent.com/Mister-Sand/session_notifications/main/lib/session_notifications.lua',
    path = nil
}

local manager_config = clone_table(DEFAULT_MANAGER_CONFIG)
local manager_bootstrap = {
    busy = false,
    waiters = {}
}

local function trim(value)
    return tostring(value or ''):gsub('^%s+', ''):gsub('%s+$', '')
end

local function get_scripts_directory()
    if thisScript then
        local script_info = thisScript()
        if script_info then
            if script_info.directory and script_info.directory ~= '' then
                return normalize_path(script_info.directory)
            end
            if script_info.path and script_info.path ~= '' then
                local parent = dirname(script_info.path)
                if parent and parent ~= '' then
                    return parent
                end
            end
        end
    end

    return normalize_path(getWorkingDirectory())
end

local function normalize_manager_config(spec)
    local config = clone_table(manager_config)

    if type(spec) == 'table' then
        for key, value in pairs(spec) do
            if key == 'min_version' and spec.required_version == nil then
                config.required_version = value
            elseif key == 'manager_url' and spec.raw_url == nil then
                config.raw_url = value
            else
                config[key] = clone_table(value)
            end
        end
    end

    config.host_name = trim(config.host_name)
    config.file_name = trim(config.file_name)
    config.required_version = trim(config.required_version)
    config.raw_url = trim(config.raw_url)
    config.library_file = trim(config.library_file)
    config.library_raw_url = trim(config.library_raw_url)
    config.path = config.path and normalize_path(trim(config.path)) or nil
    config.heartbeat_ttl = tonumber(config.heartbeat_ttl) or DEFAULT_MANAGER_CONFIG.heartbeat_ttl
    config.load_timeout = tonumber(config.load_timeout) or DEFAULT_MANAGER_CONFIG.load_timeout

    if config.host_name == '' then
        config.host_name = DEFAULT_MANAGER_CONFIG.host_name
    end
    if config.file_name == '' then
        config.file_name = DEFAULT_MANAGER_CONFIG.file_name
    end
    if config.required_version == '' then
        config.required_version = DEFAULT_MANAGER_CONFIG.required_version
    end
    if config.library_file == '' then
        config.library_file = DEFAULT_MANAGER_CONFIG.library_file
    end

    return config
end

local function get_manager_path(config)
    if config.path and config.path ~= '' then
        return normalize_path(config.path)
    end

    return join_path(get_scripts_directory(), config.file_name)
end

local function get_library_path(config)
    return join_path(getWorkingDirectory(), config.library_file)
end

local function extract_script_version(text)
    text = tostring(text or '')
    return text:match("script_version%(['\"]([^'\"]+)['\"]%)")
end

local function split_version(version)
    local result = {}
    for part in tostring(version or ''):gmatch('[^.]+') do
        result[#result + 1] = tonumber(part) or 0
    end
    return result
end

local function compare_versions(left, right)
    local a = split_version(left)
    local b = split_version(right)
    local count = max_value(#a, #b)

    for index = 1, count do
        local av = a[index] or 0
        local bv = b[index] or 0
        if av < bv then
            return -1
        end
        if av > bv then
            return 1
        end
    end

    return 0
end

local function get_local_manager_version(config)
    local content = read_file(get_manager_path(config))
    return extract_script_version(content)
end

local function get_local_library_version(config)
    local content = read_file(get_library_path(config))
    if not content then
        return nil
    end

    return content:match("VERSION%s*=%s*['\"]([^'\"]+)['\"]")
end

local function get_manager_runtime(config)
    return M.is_runtime_alive(config.host_name, config.heartbeat_ttl)
end

local function is_raw_url_configured(config)
    return config.raw_url ~= '' and not config.raw_url:find('<', 1, true)
end

local function is_library_url_configured(config)
    return config.library_raw_url ~= '' and not config.library_raw_url:find('<', 1, true)
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
            on_success({
                ok = true,
                status_code = tonumber(response.status_code),
                text = tostring(response.text or '')
            })
            return
        end

        if ok and type(response) == 'table' then
            on_error(string.format('HTTP %s for %s', tostring(response.status_code), url))
            return
        end

        on_error(tostring(response))
    end)
end

local function fetch_remote_manager_script(config, on_done)
    if not is_raw_url_configured(config) then
        on_done(false, nil, nil, 'manager raw_url is not configured')
        return
    end

    http_get_async(config.raw_url, function(response)
        local version = extract_script_version(response.text)
        if not version then
            on_done(false, nil, nil, 'remote manager has no script_version(...)')
            return
        end

        on_done(true, response.text, version, nil)
    end, function(err)
        on_done(false, nil, nil, tostring(err))
    end)
end

local function fetch_remote_library_script(config, on_done)
    if not is_library_url_configured(config) then
        on_done(false, nil, nil, 'library raw_url is not configured')
        return
    end

    http_get_async(config.library_raw_url, function(response)
        local version = response.text:match("VERSION%s*=%s*['\"]([^'\"]+)['\"]")
        if not version then
            on_done(false, nil, nil, 'remote library has no VERSION constant')
            return
        end

        on_done(true, response.text, version, nil)
    end, function(err)
        on_done(false, nil, nil, tostring(err))
    end)
end

local function ensure_parent_directory(path)
    local parent = dirname(path)
    if parent and parent ~= '' then
        ensure_dir(parent)
    end
end

local function save_text_file(path, content)
    ensure_parent_directory(path)
    write_file(path, content)
end

local function make_system_info(config, min_version, system_status, message)
    local info = clone_table(system_status or {})
    info.host_name = config.host_name
    info.required_version = min_version
    info.manager_required_version = config.required_version
    info.message = tostring(message or info.message or '')
    return info
end

local function get_required_version(spec)
    if type(spec) == 'string' or type(spec) == 'number' then
        return trim(spec)
    end

    if type(spec) == 'table' then
        return trim(spec.required_version or spec.min_version or manager_config.required_version)
    end

    return trim(manager_config.required_version)
end

local function make_manager_info(config, status, message)
    local info = clone_table(status or {})
    info.host_name = config.host_name
    info.required_version = config.required_version
    info.raw_url = config.raw_url
    info.path = get_manager_path(config)
    info.message = tostring(message or info.message or '')
    info.exists = not not (info.running or info.installed)
    return info
end

local function finish_manager_bootstrap(ok, info)
    local waiters = manager_bootstrap.waiters
    manager_bootstrap.waiters = {}
    manager_bootstrap.busy = false

    for _, callback in ipairs(waiters) do
        pcall(callback, ok, clone_table(info))
    end
end

local function try_load_manager(config, on_done)
    local path = get_manager_path(config)
    if not doesFileExist(path) then
        on_done(false, 'manager file is missing')
        return
    end

    local running, runtime = get_manager_runtime(config)
    local runtime_version = trim(runtime and runtime.version or '')
    if running then
        if runtime_version ~= '' and compare_versions(runtime_version, config.required_version) >= 0 then
            on_done(true, 'notification system is already running')
            return
        end

        on_done(false, string.format(
            'manager %s is running, but version %s is required',
            runtime_version ~= '' and runtime_version or 'unknown',
            config.required_version
        ))
        return
    end

    if not script or not script.load then
        on_done(false, 'script.load is unavailable in this loader')
        return
    end

    local ok, err = pcall(script.load, path)
    if not ok then
        on_done(false, 'script.load failed: ' .. tostring(err))
        return
    end

    lua_thread.create(function()
        local deadline = os.clock() + config.load_timeout
        while os.clock() < deadline do
            wait(250)

            local alive, fresh_runtime = get_manager_runtime(config)
            if alive then
                local version = trim(fresh_runtime and fresh_runtime.version or '')
                if version == '' or compare_versions(version, config.required_version) >= 0 then
                    on_done(true, 'notification system started')
                else
                    on_done(false, string.format(
                        'manager started with version %s, but %s is required',
                        version,
                        config.required_version
                    ))
                end
                return
            end
        end

        on_done(false, 'manager file was loaded, but heartbeat was not detected')
    end)
end

function M.setup_manager(spec)
    manager_config = normalize_manager_config(spec)
    return clone_table(manager_config)
end

function M.get_manager_config()
    return clone_table(manager_config)
end

function M.get_library_status(spec)
    local config = normalize_manager_config(spec)
    local path = get_library_path(config)
    local installed = doesFileExist(path)
    local version = installed and (get_local_library_version(config) or '-') or '-'

    return {
        installed = installed,
        path = path,
        version = version,
        raw_url = config.library_raw_url
    }
end

function M.get_manager_status(spec)
    local config = normalize_manager_config(spec)
    local path = get_manager_path(config)
    local installed = doesFileExist(path)
    local local_version = installed and (get_local_manager_version(config) or '-') or '-'
    local running, runtime = get_manager_runtime(config)
    local runtime_version = trim(runtime and runtime.version or '')
    local version = runtime_version ~= '' and runtime_version or local_version

    return {
        installed = installed,
        running = running,
        exists = installed or running,
        path = path,
        host_name = config.host_name,
        required_version = config.required_version,
        raw_url = config.raw_url,
        local_version = local_version,
        runtime_version = runtime_version ~= '' and runtime_version or '-',
        version = version ~= '' and version or '-',
        compatible = version ~= '' and version ~= '-' and compare_versions(version, config.required_version) >= 0 or false,
        runtime = runtime
    }
end

function M.get_system_status(spec)
    local config = normalize_manager_config(spec)
    local min_version = get_required_version(spec)
    if min_version == '' then
        min_version = config.required_version
    end

    local library = M.get_library_status(config)
    local manager = M.get_manager_status(config)

    local library_compatible = library.installed
        and library.version ~= '-'
        and compare_versions(library.version, min_version) >= 0

    local manager_compatible = manager.compatible
        and compare_versions(manager.version or '-', min_version) >= 0

    return {
        exists = library.installed,
        installed = library.installed,
        running = manager.running,
        min_version = min_version,
        version = manager.version ~= '-' and manager.version or library.version,
        compatible = library_compatible and manager_compatible,
        library = library,
        manager = manager
    }
end

M.status = M.get_system_status

function M.ensure_manager(spec, callback)
    if type(spec) == 'function' and callback == nil then
        callback = spec
        spec = nil
    end

    callback = callback or function() end
    local config = normalize_manager_config(spec)
    local status = M.get_manager_status(config)

    if status.running and status.compatible then
        callback(true, make_manager_info(config, status, 'notification system is ready'))
        return
    end

    if manager_bootstrap.busy then
        manager_bootstrap.waiters[#manager_bootstrap.waiters + 1] = callback
        return
    end

    manager_bootstrap.busy = true
    manager_bootstrap.waiters = { callback }

    if status.installed and compare_versions(status.local_version, config.required_version) >= 0 then
        try_load_manager(config, function(load_ok, load_message)
            local fresh_status = M.get_manager_status(config)
            finish_manager_bootstrap(load_ok and fresh_status.running and fresh_status.compatible, make_manager_info(config, fresh_status, load_message))
        end)
        return
    end

    fetch_remote_manager_script(config, function(fetch_ok, script_text, remote_version, err)
        if not fetch_ok then
            finish_manager_bootstrap(false, make_manager_info(config, status, err))
            return
        end

        if compare_versions(remote_version, config.required_version) < 0 then
            finish_manager_bootstrap(false, make_manager_info(config, status, string.format(
                'remote manager version %s is older than required %s',
                remote_version,
                config.required_version
            )))
            return
        end

        local path = get_manager_path(config)
        local ok, write_err = pcall(write_file, path, script_text)
        if not ok then
            finish_manager_bootstrap(false, make_manager_info(config, status, 'failed to save manager: ' .. tostring(write_err)))
            return
        end

        local running, runtime = get_manager_runtime(config)
        local running_version = trim(runtime and runtime.version or '')
        if running then
            local fresh_status = M.get_manager_status(config)
            if running_version ~= '' and compare_versions(running_version, config.required_version) >= 0 then
                finish_manager_bootstrap(true, make_manager_info(config, fresh_status, 'manager file updated; running service is compatible'))
            else
                finish_manager_bootstrap(false, make_manager_info(config, fresh_status, string.format(
                    'manager file updated to %s, but running service version is %s; reload manager',
                    remote_version,
                    running_version ~= '' and running_version or 'unknown'
                )))
            end
            return
        end

        try_load_manager(config, function(load_ok, load_message)
            local fresh_status = M.get_manager_status(config)
            finish_manager_bootstrap(load_ok and fresh_status.running and fresh_status.compatible, make_manager_info(config, fresh_status, load_message))
        end)
    end)
end

function M.ensure_system(spec, callback)
    if type(spec) == 'function' and callback == nil then
        callback = spec
        spec = nil
    end

    callback = callback or function() end

    local config = normalize_manager_config(spec)
    local min_version = get_required_version(spec)
    if min_version == '' then
        min_version = config.required_version
    end

    local library_status = M.get_library_status(config)
    if not library_status.installed then
        callback(false, make_system_info(config, min_version, M.get_system_status({
            required_version = min_version
        }), 'notification system library is missing'))
        return
    end

    if library_status.version == '-' or compare_versions(library_status.version, min_version) < 0 then
        fetch_remote_library_script(config, function(fetch_ok, script_text, remote_version, err)
            if not fetch_ok then
                callback(false, make_system_info(config, min_version, M.get_system_status({
                    required_version = min_version
                }), err))
                return
            end

            if compare_versions(remote_version, min_version) < 0 then
                callback(false, make_system_info(config, min_version, M.get_system_status({
                    required_version = min_version
                }), string.format(
                    'library version %s is required, but latest available is %s',
                    min_version,
                    remote_version
                )))
                return
            end

            local ok, write_err = pcall(save_text_file, get_library_path(config), script_text)
            if not ok then
                callback(false, make_system_info(config, min_version, M.get_system_status({
                    required_version = min_version
                }), 'failed to update library: ' .. tostring(write_err)))
                return
            end

            callback(false, make_system_info(config, min_version, M.get_system_status({
                required_version = min_version
            }), 'library was updated successfully; reload the script'))
        end)
        return
    end

    local manager_spec = clone_table(config)
    manager_spec.required_version = min_version

    M.ensure_manager(manager_spec, function(ok, info)
        local system_status = M.get_system_status({
            required_version = min_version
        })

        if not ok then
            callback(false, make_system_info(config, min_version, system_status, info and info.message or 'notification manager is unavailable'))
            return
        end

        local manager_version = trim(info and info.version or system_status.manager.version or '')
        if manager_version == '' or manager_version == '-' or compare_versions(manager_version, min_version) < 0 then
            callback(false, make_system_info(config, min_version, system_status, string.format(
                'manager version %s is lower than required %s',
                manager_version ~= '' and manager_version or '-',
                min_version
            )))
            return
        end

        callback(true, make_system_info(config, min_version, system_status, info and info.message or 'notification system is ready'))
    end)
end

M.require_system = M.ensure_system

function M.push_safe(min_version, spec, callback)
    if type(min_version) == 'table' or type(min_version) == 'nil' then
        callback = spec
        spec = min_version
        min_version = nil
    end

    callback = callback or function() end

    M.ensure_system(min_version, function(ok, info)
        if not ok then
            callback(false, info)
            return
        end

        local id, err = M.push(spec)
        if not id then
            local failed = make_system_info(
                normalize_manager_config(),
                get_required_version(min_version),
                M.get_system_status({ required_version = get_required_version(min_version) }),
                err
            )
            callback(false, failed)
            return
        end

        local result = clone_table(info)
        result.notification_id = id
        callback(true, result)
    end)
end

function M.send(min_version, spec, callback)
    return M.push_safe(min_version, spec, callback)
end

function M.get_paths()
    ensure_environment()
    return {
        base_dir = BASE_DIR,
        state_file = STATE_FILE,
        runtime_file = RUNTIME_FILE,
        queue_file = QUEUE_FILE,
        action_queue_file = ACTION_QUEUE_FILE,
        cursor_dir = CURSOR_DIR
    }
end

function M.get_presets()
    return clone_table(PRESETS)
end

function M.get_session()
    return read_state()
end

function M.get_runtime()
    ensure_environment()

    local raw = read_file(RUNTIME_FILE)
    if not raw or raw == '' then
        return nil
    end

    local data = json.decode(raw)
    if type(data) ~= 'table' then
        return nil
    end

    return data
end

function M.set_runtime(spec)
    ensure_environment()

    spec = spec or {}
    local now = os.time()
    local runtime = {
        host_name = tostring(spec.host_name or get_script_id()),
        session_id = tostring(spec.session_id or ''),
        version = tostring(spec.version or ''),
        started_at = tonumber(spec.started_at) or now,
        updated_at = now,
        heartbeat_at = now
    }

    for key, value in pairs(spec) do
        if runtime[key] == nil then
            runtime[key] = value
        end
    end

    write_file(RUNTIME_FILE, json.encode(runtime, { indent = false }))
    return runtime
end

function M.touch_runtime(spec)
    ensure_environment()

    local runtime = M.get_runtime() or {}
    spec = spec or {}

    for key, value in pairs(spec) do
        runtime[key] = value
    end

    local now = os.time()
    runtime.host_name = tostring(runtime.host_name or get_script_id())
    runtime.session_id = tostring(runtime.session_id or '')
    runtime.version = tostring(runtime.version or '')
    runtime.started_at = tonumber(runtime.started_at) or now
    runtime.updated_at = now
    runtime.heartbeat_at = now

    write_file(RUNTIME_FILE, json.encode(runtime, { indent = false }))
    return runtime
end

function M.is_runtime_alive(host_name, max_age)
    if type(host_name) == 'number' and max_age == nil then
        max_age = host_name
        host_name = nil
    end

    local runtime = M.get_runtime()
    if type(runtime) ~= 'table' then
        return false, nil
    end

    if host_name and tostring(runtime.host_name or '') ~= tostring(host_name) then
        return false, runtime
    end

    local heartbeat = tonumber(runtime.heartbeat_at or runtime.updated_at or 0) or 0
    if heartbeat <= 0 then
        return false, runtime
    end

    max_age = tonumber(max_age) or 5
    return (os.time() - heartbeat) <= max_age, runtime
end

function M.start_session(host_name)
    ensure_environment()

    local state = {
        session_id = make_id('session'),
        host_name = host_name or get_script_id(),
        started_at = os.time()
    }

    write_file(STATE_FILE, json.encode(state, { indent = false }))
    return state
end

function M.push(spec)
    ensure_environment()

    spec = spec or {}
    local session = read_state()
    if not session or not session.session_id then
        return nil, 'notification-center session is not active'
    end

    local title = tostring(spec.title or '')
    local text = tostring(spec.text or spec.message or '')
    if title == '' and text == '' then
        return nil, 'title or text is required'
    end

    local duration = tonumber(spec.duration)
    if duration == nil or duration < 0 then
        duration = 5
    end

    local base_theme = tostring(spec.theme or 'ocean')
    if not PRESETS[base_theme] then
        base_theme = 'ocean'
    end

    local payload = {
        kind = 'notification',
        version = 1,
        id = make_id('notif'),
        session_id = session.session_id,
        created_at = os.time(),
        script_id = tostring(spec.script_id or get_script_id()),
        target_script_id = tostring(spec.target_script_id or get_script_id()),
        title = title,
        text = text,
        description = tostring(spec.description or ''),
        duration = duration,
        sticky = not not spec.sticky,
        image_path = spec.image_path and tostring(spec.image_path) or '',
        theme_name = base_theme,
        theme = merge_theme(base_theme, spec.theme_override),
        action_id = '',
        action_label = '',
        action_payload = nil
    }

    if type(spec.action) == 'table' then
        payload.action_id = tostring(spec.action.id or '')
        payload.action_label = tostring(spec.action.label or '')
        payload.action_payload = spec.action.payload
    end

    append_line(QUEUE_FILE, json.encode(payload, { indent = false }) .. '\n')
    return payload.id
end

function M.register_action(label, callback, payload)
    assert(type(callback) == 'function', 'callback must be a function')

    local descriptor = {
        id = make_id('action'),
        label = tostring(label or 'Run'),
        payload = payload
    }

    callbacks[descriptor.id] = callback
    return descriptor
end

function M.emit_action(spec)
    ensure_environment()

    local session = read_state()
    if not session or not session.session_id then
        return nil, 'notification-center session is not active'
    end

    spec = spec or {}
    if not spec.target_script_id or not spec.action_id then
        return nil, 'target_script_id and action_id are required'
    end

    local payload = {
        kind = 'action',
        version = 1,
        id = make_id('click'),
        session_id = session.session_id,
        created_at = os.time(),
        target_script_id = tostring(spec.target_script_id),
        source_script_id = tostring(spec.source_script_id or get_script_id()),
        notification_id = tostring(spec.notification_id or ''),
        action_id = tostring(spec.action_id),
        action_payload = spec.action_payload
    }

    append_line(ACTION_QUEUE_FILE, json.encode(payload, { indent = false }) .. '\n')
    return payload.id
end

function M.process_actions()
    ensure_environment()

    local session = read_state()
    if not session or not session.session_id then
        return 0
    end

    local script_id = get_script_id()
    local cursor_path = get_cursor_path(script_id)
    local poll_state = action_poll_state[script_id]
    if not poll_state then
        poll_state = {
            offset = nil,
            last_poll_clock = 0
        }
        action_poll_state[script_id] = poll_state
    end

    local now_clock = os.clock()
    if (now_clock - poll_state.last_poll_clock) < ACTION_POLL_INTERVAL then
        return 0
    end
    poll_state.last_poll_clock = now_clock

    local offset = poll_state.offset
    if offset == nil then
        offset = read_number_file(cursor_path)
        poll_state.offset = offset
    end

    local file = io.open(ACTION_QUEUE_FILE, 'r')
    if not file then
        return 0
    end

    local queue_size = file:seek('end') or offset
    if queue_size <= offset then
        file:close()
        return 0
    end

    file:seek('set', offset)
    local processed = 0

    while true do
        local line = file:read('*line')
        if not line then
            break
        end

        if line ~= '' then
            local payload = json.decode(line)
            if type(payload) == 'table'
                and payload.kind == 'action'
                and payload.session_id == session.session_id
                and payload.target_script_id == script_id then
                local callback = callbacks[payload.action_id]
                if callback then
                    pcall(callback, payload)
                    processed = processed + 1
                end
            end
        end
    end

    offset = file:seek() or offset
    file:close()

    if offset ~= poll_state.offset then
        poll_state.offset = offset
        write_file(cursor_path, tostring(offset))
    end

    return processed
end

math.randomseed(os.time() + math.floor(os.clock() * 100000))

M.presets = PRESETS

return M
