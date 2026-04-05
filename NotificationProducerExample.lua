script_name('Notification Producer Example')
script_author('Codex')
script_version('1.0')

local REQUIRED_NOTIFY_VERSION = '1.0'
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

local notify, notify_error = require_notification_library()
if not notify then
    error('Notification system is not installed. Install NotificationManager.lua first: ' .. tostring(notify_error))
end

local interactive_action = nil

local function chat(message, color)
    sampAddChatMessage('[NotifyExample] ' .. tostring(message), color or 0x8FD4FF)
end

local function print_status()
    local status = notify.status(REQUIRED_NOTIFY_VERSION)
    local state = status.running and 'running' or (status.installed and 'installed' or 'missing')
    chat(string.format(
        'system=%s version=%s required=%s library=%s manager=%s',
        state,
        status.version or '-',
        status.min_version or '-',
        status.library and status.library.version or '-',
        status.manager and status.manager.version or '-'
    ), status.running and 0x7AFF9D or 0xFFD27A)
end

local function send_examples()
    notify.send(REQUIRED_NOTIFY_VERSION, {
        script_id = 'Notification Producer Example',
        title = 'System check',
        text = 'Notification system was checked and is ready.',
        description = 'Next notifications are sent through the shared manager.',
        duration = 5,
        theme = 'ocean'
    }, function(ok, info)
        if not ok then
            chat(info and info.message or 'notification system is unavailable', 0xFF7A7A)
            return
        end

        chat(string.format(
            'system ready: version=%s notification=%s',
            info.version or '-',
            info.notification_id or '-'
        ), 0x7AFF9D)

        notify.push({
            script_id = 'Sender A',
            title = 'Background task',
            text = 'First producer sent a notification into the shared queue.',
            description = 'Use this file as a copy-paste example for other scripts.',
            duration = 5,
            theme = 'emerald'
        })

        notify.push({
            script_id = 'Sender A',
            title = 'Pinned example',
            text = 'Sticky notifications stay visible until closed manually.',
            sticky = true,
            theme = 'graphite'
        })

        notify.push({
            script_id = 'Notification Producer Example',
            title = 'Interactive notification',
            text = 'Click the button inside the toast to trigger a local callback.',
            description = 'The action will execute in this script, not in the manager.',
            duration = 12,
            theme = 'ocean',
            action = interactive_action
        })
    end)
end

function main()
    interactive_action = notify.register_action('Run action', function(payload)
        sampAddChatMessage(
            string.format('[Notify] action fired for %s', payload.notification_id or 'unknown'),
            -1
        )
    end)

    repeat
        wait(100)
    until isSampAvailable()

    sampRegisterChatCommand('notifystatus', function()
        print_status()
    end)

    sampRegisterChatCommand('notifysend', function()
        send_examples()
    end)

    while true do
        wait(0)
        notify.process_actions()
    end
end
