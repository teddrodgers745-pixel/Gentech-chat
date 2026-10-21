# GenTech Chat

Личный Android-клиент для DeepSeek и любых OpenAI-совместимых API.
Текст на всю ширину экрана, масштаб шрифта щипком (с перестроением текста), выбор шрифтов и тем.

## Как собрать APK (бесплатно, через GitHub Actions)

1. Создайте на GitHub пустой репозиторий, например `gentech-chat`.
2. Загрузите в него содержимое этой папки. Через Termux:

```
pkg install git unzip
unzip gentech_chat.zip && cd gentech_chat
git init && git add . && git commit -m "init"
git branch -M main
git remote add origin https://github.com/ВАШ_ЛОГИН/gentech-chat.git
git push -u origin main
```

(при запросе пароля вводится personal access token, а не пароль от аккаунта)

3. На GitHub откройте вкладку **Actions**. Сборка стартует сама, занимает 5-10 минут.
4. Откройте завершённый запуск, внизу в **Artifacts** скачайте `gentech-chat-apk`, распакуйте и установите `app-release.apk` (разрешите установку из неизвестных источников).

## Первый запуск

Настройки (значок справа вверху): вставьте API-ключ, проверьте Base URL (`https://api.deepseek.com`) и название модели.

## Если сборка упала

Откройте лог шага с ошибкой во вкладке Actions и пришлите его, исправлю.
