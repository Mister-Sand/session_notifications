# Notification System Usage

## Что входит в систему

- `NotificationManager.lua` — сервис, который отображает уведомления.
- `lib/session_notifications.lua` — общая библиотека для скриптов и самого менеджера.

## Как это работает

1. Скрипт (ваш) пытается загрузить `session_notifications`.
2. Если библиотеки нет, скрипт (ваш) получает понятную ошибку: система уведомлений не установлена.
3. Скрипт (ваш) указывает минимальную версию системы уведомлений, которая ему нужна.
4. Библиотека сама:
   - проверяет свою версию;
   - при необходимости проверяет обновление на GitHub;
   - проверяет менеджер;
   - при необходимости обновляет/запускает менеджер;
   - после этого отправляет уведомление.

## Минимальное подключение

```lua
local REQUIRED_NOTIFY_VERSION = '1.0'

local ok, notify = pcall(require, 'session_notifications')
if not ok then
    error('Notification system is not installed. Install NotificationManager.lua first: ' .. tostring(notify))
end
```

## Самый простой способ отправить уведомление

Используйте `notify.send(min_version, spec, callback)`.

```lua
notify.send(REQUIRED_NOTIFY_VERSION, {
    title = 'Привет',
    text = 'Система уведомлений работает.',
    duration = 5,
    theme = 'ocean'
}, function(success, info)
    if not success then
        sampAddChatMessage('[Notify] ' .. tostring(info.message), 0xFF7A7A)
        return
    end

    sampAddChatMessage('[Notify] Уведомление отправлено', 0x7AFF9D)
end)
```

## Структура уведомления

Поддерживаемые основные поля:

- `title` — заголовок уведомления.
- `text` — основной текст.
- `description` — дополнительное описание.
- `duration` — время жизни в секундах.
- `sticky` — если `true`, уведомление не исчезает само.
- `theme` — встроенная тема (`ocean`, `ember`, `emerald`, `graphite`).
- `script_id` — имя отправителя.
- `image_path` — путь к картинке.
- `action` — кнопка с callback.

Пример:

```lua
notify.send(REQUIRED_NOTIFY_VERSION, {
    script_id = 'My Script',
    title = 'Действие завершено',
    text = 'Данные успешно обработаны.',
    description = 'Можно продолжать работу.',
    duration = 6,
    theme = 'emerald'
})
```

## Кнопка действия

Если нужно обработать нажатие внутри вашего скрипта:

```lua
local action_button = notify.register_action('Открыть', function(payload)
    sampAddChatMessage(
        string.format('[Notify] action for %s', payload.notification_id or 'unknown'),
        -1
    )
end)

notify.send(REQUIRED_NOTIFY_VERSION, {
    script_id = 'My Script',
    title = 'Нужно подтверждение',
    text = 'Нажмите кнопку в уведомлении.',
    sticky = true,
    action = action_button
})
```

И в главном цикле скрипта нужно вызывать:

```lua
while true do
    wait(0)
    notify.process_actions()
end
```

## Проверка состояния системы

Если нужно просто узнать состояние системы уведомлений:

```lua
local status = notify.status(REQUIRED_NOTIFY_VERSION)

-- status.installed
-- status.running
-- status.version
-- status.min_version
-- status.library.version
-- status.manager.version
```

Пример:

```lua
local status = notify.status(REQUIRED_NOTIFY_VERSION)
if not status.installed then
    sampAddChatMessage('[Notify] Система уведомлений не установлена', 0xFF7A7A)
elseif not status.running then
    sampAddChatMessage('[Notify] Менеджер найден, но не запущен', 0xFFD27A)
else
    sampAddChatMessage('[Notify] Система уведомлений активна', 0x7AFF9D)
end
```

## Рекомендуемый шаблон для нового скрипта

```lua
local REQUIRED_NOTIFY_VERSION = '1.0'
local ok, notify = pcall(require, 'session_notifications')
if not ok then
    error('Notification system is not installed. Install NotificationManager.lua first: ' .. tostring(notify))
end

function main()
    repeat
        wait(100)
    until isSampAvailable()

    sampRegisterChatCommand('mytestnotify', function()
        notify.send(REQUIRED_NOTIFY_VERSION, {
            script_id = 'My Script',
            title = 'Тест',
            text = 'Тестовое уведомление.',
            duration = 5,
            theme = 'ocean'
        }, function(success, info)
            if not success then
                sampAddChatMessage('[Notify] ' .. tostring(info.message), 0xFF7A7A)
            end
        end)
    end)

    while true do
        wait(0)
        notify.process_actions()
    end
end
```

## Что важно помнить

- Для обычных скриптов основной API — это `notify.send(...)`.
- Если `session_notifications.lua` вообще отсутствует, скрипт не сможет сам себя восстановить: он должен показать ошибку пользователю.
- Если библиотека или менеджер устарели, система попытается обновить их сама.
- После обновления самой библиотеки может понадобиться перезагрузка скрипта, потому что Lua уже держит старый модуль в памяти.

## Где смотреть пример

- `NotificationProducerExample.lua` — пример использования в обычном скрипте.
- `NotificationManager.lua` — сам сервис уведомлений.
- `lib/session_notifications.lua` — общая библиотека и API.
