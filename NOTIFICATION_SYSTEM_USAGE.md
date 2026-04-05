# Notification System Usage

## Что входит в систему

- `NotificationManager.lua` - сервис, который показывает уведомления и хранит историю текущей сессии.
- `lib/session_notifications.lua` - общая библиотека для скриптов и самого менеджера.
- `NotificationProducerExample.lua` - минимальный рабочий пример интеграции.

## Как это работает

1. Ваш скрипт загружает `session_notifications`.
2. Скрипт указывает минимальную версию системы уведомлений, которая ему нужна.
3. `notify.send(...)` проверяет локальную библиотеку и локальный менеджер уведомлений.
4. Если менеджер установлен и версия подходит, библиотека может запустить его локально через `script.load(...)`.
5. Если библиотека или менеджер отсутствуют либо устарели, система возвращает ошибку и просит обновить файлы вручную.
6. После успешной проверки уведомление попадает в общую очередь, а менеджер отображает его на экране.

## Важно

Система больше не скачивает и не обновляет файлы автоматически.

- Нет автообновления `NotificationManager.lua`.
- Нет автообновления `lib/session_notifications.lua`.
- Нет автоскачивания с GitHub.
- Обновление выполняется только вручную заменой файлов.

## Минимальное подключение

```lua
local REQUIRED_NOTIFY_VERSION = '1.0'

local ok, notify = pcall(require, 'session_notifications')
if not ok then
    error('Notification system is not installed. Install NotificationManager.lua first: ' .. tostring(notify))
end
```

## Базовый способ отправки

Для обычного скрипта основной API - `notify.send(min_version, spec, callback)`.

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

## Когда использовать `notify.push(...)`

`notify.push(spec)` пишет уведомление напрямую в очередь и не делает проверку/подготовку системы.

Используйте его только если:

- менеджер уже точно запущен;
- библиотека уже проверена через `notify.send(...)` или `notify.ensure_system(...)`;
- вы находитесь внутри самого менеджера или в коде, который уже работает с активной сессией.

## Структура уведомления

Поддерживаемые поля:

- `title` - заголовок.
- `text` - основной текст.
- `description` - дополнительный текст.
- `duration` - длительность в секундах.
- `sticky` - если `true`, уведомление не закрывается автоматически.
- `theme` - одна из встроенных тем: `ocean`, `ember`, `emerald`, `graphite`.
- `theme_override` - частичное переопределение цветов поверх выбранной темы.
- `script_id` - имя отправителя.
- `target_script_id` - целевой скрипт для action callback.
- `image_path` - путь к изображению.
- `action` - кнопка действия, созданная через `notify.register_action(...)`.

Пример:

```lua
notify.send(REQUIRED_NOTIFY_VERSION, {
    script_id = 'My Script',
    title = 'Действие завершено',
    text = 'Данные успешно обработаны.',
    description = 'Можно продолжать работу.',
    duration = 6,
    theme = 'emerald',
    theme_override = {
        accent = { 0.20, 0.80, 0.55, 1.0 }
    }
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

```lua
local status = notify.status(REQUIRED_NOTIFY_VERSION)

-- status.installed
-- status.running
-- status.compatible
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
elseif not status.compatible then
    sampAddChatMessage('[Notify] Менеджер или библиотека требуют ручного обновления', 0xFFD27A)
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

## Полезные команды

Менеджер:

- `/notifyhistory` - открыть или скрыть окно истории уведомлений.
- `/notifydemo` - отправить демо-набор уведомлений.

Пример из `NotificationProducerExample.lua`:

- `/notifystatus` - показать статус системы уведомлений.
- `/notifysend` - отправить набор тестовых уведомлений.

## Что важно помнить

- Для обычных скриптов используйте `notify.send(...)` как основной вход.
- `notify.push(...)` не заменяет `notify.send(...)`, а обходит проверку готовности системы.
- Если `session_notifications.lua` вообще отсутствует, скрипт не сможет восстановить систему сам и должен показать ошибку пользователю.
- Если библиотека или менеджер устарели, их нужно обновлять вручную.
- Для обработки action callback ваш скрипт должен регулярно вызывать `notify.process_actions()`.

## Где смотреть пример

- `NotificationProducerExample.lua` - пример использования в обычном скрипте.
- `NotificationManager.lua` - реализация менеджера уведомлений.
- `lib/session_notifications.lua` - общая библиотека и публичный API.
