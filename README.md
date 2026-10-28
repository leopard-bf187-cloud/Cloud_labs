# Лабораторная работа №4 — Облачные хранилища. Amazon S3

**Студент:** Пармакли Леонид  
**Группа:** IA2404ru  
**Специальность:** Прикладная информатика  
**Дисциплина:** Cloud Computing  
**Уровень:** продвинутый (задания 1–14, с оговорками по №8, №10 и отдельным тестам №12–13)  
**Регион AWS:** `eu-central-1` (Frankfurt)  
**Дата:** 28.10.2026  
**Приложение:** [Mood Diary — LaboratoryApp](https://github.com/leopard-bf187-cloud/LaboratoryApp)  
**Репозиторий отчёта:** [Cloud_labs, ветка Lab4](https://github.com/leopard-bf187-cloud/Cloud_labs/tree/Lab4)

---

## 1. Цель и результат

**Цель работы:** изучить объектное хранилище Amazon S3: создание приватного бакета, загрузку и получение объектов, Bucket Policy, Versioning, Lifecycle, Presigned URL и ограничение доступа через IAM. На продвинутом уровне — использовать S3 как постоянное хранилище файлов приложения, работающего на EC2.

**Результат:** создан приватный бакет `timecapsule-dev-uploads-leopard`, настроены защита по HTTPS, версионирование и жизненный цикл объектов. К EC2-серверу приложения привязана роль IAM с доступом только к объектам `uploads/*`. В Mood Diary реализована возможность загружать вложения в S3, сохранять их метаданные в PostgreSQL и получать файлы через короткоживущие подписанные ссылки. Проверено изменение ответа `HeadObject` с `404` на `403` после удаления права `s3:ListBucket`.

> **Адаптация приложения.** Методичка рассчитана на TimeCapsule и перенос существующей папки `storage/uploads`. В данной работе использовалось **Mood Diary**, у которого до ЛР4 не было системы вложений. Поэтому миграция старых файлов (`№10`) неприменима: вместо имитации переноса добавлен и проверен новый модуль загрузки непосредственно в S3. Тестовая роль создана, но полная таблица проверок через `sts:AssumeRole` (`№8`) не выполнялась.

## 2. Архитектура и используемые ресурсы

Инфраструктура сети и серверов сохранена из [ЛР3](https://github.com/leopard-bf187-cloud/Cloud_labs/tree/Lab3). Бакет S3 расположен в регионе Frankfurt, **вне VPC**; он используется как региональный сервис через HTTPS.

| Ресурс | Конфигурация |
|---|---|
| VPC | `vpc-student-leonid-parmacli`, `10.0.0.0/16` |
| Веб-сервер | EC2 `app-server` / `app-sv`, приватный IP `10.0.0.213`; Nginx, PHP-FPM, Mood Diary |
| Сервер БД | EC2 `db-server`, `10.0.10.12`; PostgreSQL 16, приватная подсеть |
| Администрирование | EC2 `bastion`, SSH / ProxyJump |
| Объектное хранилище | S3 `timecapsule-dev-uploads-leopard`, префикс `uploads/` |
| IAM Policy | `timecapsule-dev-app-s3`; итоговая версия без `s3:ListBucket` |
| IAM Role | `timecapsule-dev-app-role`, подключена к `app-server` |
| Lifecycle Rule | `timecapsule-dev-noncurrent` |
| DNS | `db.timecapsule.internal` → `10.0.10.12` |

**[Редактируемая архитектурная диаграмма draw.io с Amazon Architecture Icons](images/Lab4_AWS_Architecture_AmazonIcons.drawio)**  
**[ADR-0003 — обоснование выбора S3 вместо EBS и EFS](docs/adr/0003-attachment-storage.md)**

Схема показывает два отдельных потока: `app-server → S3` для `PutObject/DeleteObject` и `браузер → S3` для скачивания по `Presigned GET URL`. PostgreSQL хранит только метаданные вложений, а не их содержимое.

## 3. Часть 1 — базовые задания №1–6

### 3.1. Задание №1 — создание бакета и объектов

Создан бакет `timecapsule-dev-uploads-leopard` со следующими параметрами: `ACLs disabled`, `Block all public access`, шифрование `SSE-S3`. В корне сформированы логические префиксы `uploads/` и `backups/`.

В `uploads/` загружены `AssetEditor_art1.png` (`image/png`) и `AssetEditor.pdf`; в `backups/` — тестовый текстовый файл. Открытие постоянного `Object URL` без авторизации вернуло `AccessDenied`. Папки S3 — это префиксы ключей, а не каталоги обычной файловой системы.

Доказательства: [структура объектов](images/001-bucket-folders-created.png), [AccessDenied](images/002-img-access-denied.png), [метаданные изображения](images/003-img-props.png).

### 3.2. Задание №2 — AWS CloudShell и операции CLI

Из CloudShell проверены загрузка, синхронизация, перечисление, получение метаданных, скачивание и удаление объектов:

```bash
BUCKET=timecapsule-dev-uploads-leopard
aws s3 cp photo.txt s3://$BUCKET/uploads/photo.txt
aws s3 sync 2026 s3://$BUCKET/uploads/2026
aws s3 ls s3://$BUCKET
aws s3 ls s3://$BUCKET/uploads/
aws s3 ls s3://$BUCKET --recursive
aws s3api head-object --bucket "$BUCKET" --key "uploads/2026/10/report.txt"
aws s3 cp s3://$BUCKET/uploads/photo.txt downloaded.txt
aws s3 rm s3://$BUCKET/uploads/2026/10/report-2.txt
```

`ls` без `--recursive` показывает префиксы через `PRE`, а рекурсивная команда — полные ключи объектов. Текстовый файл `report.txt` определён как `text/plain`. Скачивание `photo.txt` и удаление `report-2.txt` проверены.

Доказательства: [список объектов и HEAD](images/004-cloudshell-output.png), [скачивание и удаление](images/005-cloudshell-file-download-delete.png).

### 3.3. Задание №3 — Bucket Policy: запрет HTTP

Добавлена ресурсная политика `DenyInsecureTransport` с условием `"aws:SecureTransport": "false"`. Она явно запрещает операции по незашифрованному HTTP для бакета и его объектов.

```bash
aws s3 ls s3://$BUCKET/uploads/
aws s3 ls s3://$BUCKET/uploads/ --endpoint-url http://s3.eu-central-1.amazonaws.com
```

**Результат:** по HTTPS запрос выполняется, по HTTP — `AccessDenied`, несмотря на полномочия пользователя. Ресурсная политика с явным `Deny` имеет приоритет над разрешениями. `Block Public Access` не запрещает подобную ограничивающую политику: она не предоставляет публике новые права.

Файл политики: [`policy.json`](policy.json). Доказательство: [проверка HTTPS и HTTP](images/006-cloudshell-policy-check.png).

### 3.4. Задание №4 — Versioning и Delete Marker

После включения Versioning объекты, загруженные до этого момента, отображались с `Version ID = null`. Файл `uploads/notes.txt` был загружен в вариантах `v1` и `v2`.

- Обычное удаление добавило `Delete Marker` и скрыло объект из текущего представления.
- Удаление маркера восстановило доступ к `v2`.
- Удаление конкретной версии `v2` сделало актуальной `v1`.

Таким образом, обычное удаление можно отменить, пока сохранены прошлые версии, а удаление конкретного `VersionId` уничтожает именно эту версию и требует более строгих прав.

Доказательства: [версии объектов](images/007-objects-with-versions.png), [история `notes.txt`](images/008-versions.png), [Delete Marker](images/009-delete-marker.png).

### 3.5. Задание №5 — S3 Lifecycle

Создано правило `timecapsule-dev-noncurrent` для префикса `uploads/`:

| Условие | Настройка |
|---|---|
| Неактуальные версии | Переход в `Standard-IA` через 30 дней |
| Очистка истории | Удаление noncurrent-версий спустя 90 дней с сохранением двух более новых |
| Incomplete Multipart Uploads | Прерывание через 7 дней |
| Префикс `backups/` | Не затрагивается правилом |

Правило ограничивает накопление старых версий и незавершённых multipart-загрузок. Переход в Standard-IA может не выполняться для слишком маленьких объектов из-за ограничений класса/перехода; реальный переход по дням не наблюдался в ходе кратковременной лабораторной.

Доказательства: [правило Lifecycle](images/010-lifecycle-rule.png), [Review transition and expiration actions](images/011-review-transition-and-expiration-actions.png).

### 3.6. Задание №6 — Presigned URL

Создана подписанная ссылка из S3 Console на 5 минут и из AWS CLI на 120 секунд:

```bash
aws s3 presign s3://$BUCKET/uploads/photo.txt --expires-in 120 --region eu-central-1
```

Приватный объект был доступен через подписанный URL в окне инкогнито. Подмена пути к объекту нарушала подпись, а после окончания срока действие исходной ссылки прекращалось.

`aws s3 presign` создаёт подпись локально с использованием имеющихся AWS credentials; S3 проверяет подпись при фактическом запросе. Полный URL, включая `X-Amz-Signature` и временный токен, в отчёт не помещён.

Доказательства: [ссылка из консоли](images/012-image-shared-url.png), [ссылка на 120 секунд](images/013-shared-url-120s.png), [истечение срока](images/014-shared-url-120s-timeout.png).

## 4. Часть 2 — продвинутые задания №7–14

### 4.1. Задания №7–9 — IAM Policy и роли

Создана политика `timecapsule-dev-app-s3`. На первоначальном этапе она разрешала `s3:ListBucket` только с префиксом `uploads/*`, а также `s3:GetObject`, `s3:PutObject` и `s3:DeleteObject` для `arn:aws:s3:::timecapsule-dev-uploads-leopard/uploads/*`.

Созданы роли `timecapsule-dev-s3-tester` (тестовая роль с доверием к аккаунту) и `timecapsule-dev-app-role` (доверие к сервису EC2). Последняя привязана к `app-server`.

**Проверка на EC2:**

```bash
aws sts get-caller-identity
```

Поле `Arn` содержало `assumed-role/timecapsule-dev-app-role/…`: сервер использовал временные учётные данные роли без постоянных ключей в `.env`. Запрос просмотра `backups/` получил `AccessDenied`.

**Ограничение по №8:** проверка всех десяти операций под `timecapsule-dev-s3-tester` через `sts:AssumeRole` не проводилась, поэтому таблица фактических результатов отсутствует; роль создана, но задание №8 полностью не закрыто.

Политики: [исходная IAM](policy_iam.json), [финальная IAM](policy_iam2.json). Доказательства: [созданные роли](images/015-roles.png), [роль на EC2](images/016-appsv-iam-role.png), [identity EC2](images/017-get-caller-identity.png).

### 4.2. Задание №10 — существующие файлы

В отличие от учебного TimeCapsule, у Mood Diary до ЛР4 **не было загрузки файлов** и директории `storage/uploads`. Проверка на сервере:

```text
ls: cannot access 'storage/uploads': No such file or directory
aws: [ERROR]: The user-provided path storage/uploads does not exist.
```

Поиск директорий `uploads`/`attachments` также не обнаружил источника для синхронизации. Поэтому реальный перенос старых вложений через `aws s3 sync` не выполнялся: выдавать тестовые файлы за прежние пользовательские данные было бы некорректно.

### 4.3. Задание №11 — интеграция S3 в Mood Diary

Изменения исходников выполнены в [ветке `feat/cloud-lab4-s3-attachments`](https://github.com/leopard-bf187-cloud/LaboratoryApp/tree/feat/cloud-lab4-s3-attachments) (см. также [Pull Request #1](https://github.com/leopard-bf187-cloud/LaboratoryApp/pull/1)).

| Компонент приложения | Назначение |
|---|---|
| `src/Service/AttachmentStorage.php` | `PutObject`, `DeleteObject`, Presigned GET URL на 5 минут |
| `src/Repository/AttachmentRepository.php` | Метаданные файлов в PostgreSQL |
| `migrations/003_create_attachments.php` | Таблица `entry_attachments` |
| `public/index.php` | Авторизация, обработка загрузки, ссылки и удаление |
| `templates_twig/entries/form.twig` | Поле файла и управление вложениями |
| `templates_twig/entries/list.twig` | Ссылки на вложения |
| `composer.json` / `composer.lock` | AWS SDK for PHP и Twig |

На EC2 установлены `aws/aws-sdk-php 3.402.2` и `twig/twig 3.30.0`. После обновления Twig проверка `composer audit` вернула `No security vulnerability advisories found`.

В `.env` добавлены `S3_BUCKET=timecapsule-dev-uploads-leopard` и `AWS_REGION=eu-central-1`, без AWS access keys. Проверка `php -l` основных модулей прошла. Миграция `003_create_attachments.php` применена успешно:

```text
Пропущена: 001_create_mood_diary_tables.php
Пропущена: 002_add_users_and_auth.php
Применена: 003_create_attachments.php
Миграции успешно применены.
```

### 4.4. Задание №12 — загрузка и подписанная ссылка

Через интерфейс Mood Diary подтверждена загрузка изображения в S3. При первом запросе Nginx вернул `413 Request Entity Too Large`; ограничение HTTP-запроса было увеличено через `client_max_body_size 16m`. В PHP настроены `upload_max_filesize = 10M` и `post_max_size = 16M`. После перезагрузки Nginx/PHP-FPM загрузка стала работать.

Для открытия вложения приложение формирует подписанный GET URL со сроком `X-Amz-Expires=300`. Ранее полученная ссылка перестала работать после истечения срока, что ожидаемо. **Отдельная успешная проверка PDF и удаления вложения через интерфейс в материалах не зафиксирована.**

Доказательства: [вложение работает](images/018-vlojenie-works.png), [недействительная ссылка/ошибка доступа](images/019-vlojenie-ne-works.png).

### 4.5. Задание №13 — сервер без постоянных локальных вложений и Least Privilege

Проверка `ls -ld storage/uploads` показала отсутствие каталога, а загрузка вложения через сайт ранее была успешна. Это подтверждает, что постоянное содержимое вложений хранится не в директории приложения.

Затем из IAM Policy удалено разрешение `s3:ListBucket`. На EC2 выполнен запрос несуществующего объекта:

```bash
aws s3api head-object --bucket timecapsule-dev-uploads-leopard --key uploads/lab4-file-does-not-exist-999.txt
```

| Состояние политики роли | Ответ S3 |
|---|---|
| До удаления `s3:ListBucket` | `404 Not Found` |
| После удаления `s3:ListBucket` | `403 Forbidden` |

S3 не раскрывает факт отсутствия объекта клиенту без разрешения `s3:ListBucket`. Также подтверждён запрет перечисления `backups/`. **Отдельное сравнение с CloudShell и повторная проверка сайта после сужения политики не документированы.**

Доказательства: [запрет доступа к backups](images/020-ceto-tut-zapresheno.png), [404 → 403](images/021-snova-ceto-zapresheno.png).

### 4.6. Задание №14 — архитектура и ADR

Обновлена архитектурная схема сети из ЛР3. На диаграмме обозначены IAM Role, S3-бакет **вне VPC**, префикс `uploads/` и потоки API-загрузки/удаления и браузерного скачивания.

- **[AWS Architecture — редактируемый .drawio с Amazon Icons](images/Lab4_AWS_Architecture_AmazonIcons.drawio)**
- **[ADR-0003 — EBS против EFS против S3](docs/adr/0003-attachment-storage.md)**

В ADR объяснены защита при случайном удалении (Versioning), ограничение накопления старых версий (Lifecycle), время действия ссылок и последствия перехода к нескольким EC2-серверам за балансировщиком.

## 5. Контрольные вопросы — краткие ответы

**Почему прямой Object URL закрыт и что означает префикс?**  
Объект приватен, а наличие прав у владельца аккаунта не делает его публичным для анонимного браузера. `uploads/` и `backups/` — части ключей объектов; кнопка `Create folder` может создавать нулевой объект-маркер.

**Почему `ls` без `--recursive` выводит `PRE`? Как определяется Content-Type?**  
Команда группирует ключи по общим префиксам. `Content-Type` задаётся при загрузке или определяется клиентом; для `report.txt` наблюдался `text/plain`.

**Почему HTTP-запрос получил AccessDenied даже при административных правах?**  
Условие `aws:SecureTransport=false` активирует явный запрет Bucket Policy. Запрет имеет приоритет перед разрешающей политикой IAM.

**Обычное удаление и удаление конкретной версии — в чём разница?**  
В версионируемом бакете обычное удаление без Version ID создаёт Delete Marker; предыдущие версии остаются и могут быть восстановлены. Удаление конкретной версии окончательно уничтожает выбранную версию, поэтому приложению не выдавали `s3:DeleteObjectVersion`.

**Зачем нужны Lifecycle и отмена незавершённых multipart uploads?**  
Старые версии объектов и загруженные части файлов расходуют оплачиваемое пространство. Lifecycle ограничивает их накопление; multipart upload может остаться незавершённым даже после прекращения загрузки со стороны клиента.

**Почему нельзя поменять ключ в Presigned URL и получить другой объект?**  
Подпись SigV4 зависит от параметров подписанного запроса, включая путь к объекту. Изменение пути или подписанных параметров делает подпись недействительной, а по истечении `X-Amz-Expires` ссылка больше не даёт доступа.

**Чем отличаются права роли и её Trust Policy?**  
Trust Policy указывает, кто может использовать роль (для приложения — сервис EC2). Permissions Policy определяет, какие действия с какими S3-ресурсами разрешены после получения временных учётных данных.

**Почему для `ListBucket` ARN бакета, а для `GetObject` — ARN объекта?**  
`ListBucket` обращается к самому бакету и его ключам; `GetObject` — к отдельному объекту. Правило с неправильным типом ARN не предоставит требуемого разрешения.

**Почему отказано в `backups/` и что даёт принцип минимальных привилегий?**  
Роль ограничена только объектами `uploads/*`. Даже получив временные credentials приложения, атакующий не должен иметь права читать другие префиксы или уничтожать конкретные версии файлов.

**Почему не 404, а 403 после удаления `ListBucket`?**  
Без `s3:ListBucket` S3 не обязан раскрывать, существует ли запрошенный объект. Поэтому несуществующий ключ может получить `403 Forbidden` вместо `404 Not Found`.

**Как работает скачивание и где проверяются права?**  
Mood Diary проверяет сессию и право доступа к записи до генерации ссылки. AWS SDK подписывает GET-запрос полномочиями IAM Role; затем браузер обращается напрямую к S3, который проверяет подпись и права.

**Почему не сделать файлы публичными?**  
Публичный доступ позволил бы открыть вложение в обход проверки пользователя приложения. Presigned URL обеспечивает ограниченный по времени доступ к конкретному объекту без раскрытия IAM-ключей.

**Что изменится при нескольких серверах или отказе региона?**  
Дополнительные EC2 могут использовать один S3-бакет и общую PostgreSQL, однако потребуется вынести локальные PHP-сессии и учесть доступность БД. Для переживания отказа целого региона понадобятся отдельные меры: репликация данных, резервная инфраструктура, переключение трафика и проверенная процедура восстановления; в ЛР4 это не разворачивалось.

## 6. Итоги и ограничения

Выполнены базовые задания №1–6, созданы IAM Policy и роли, привязана EC2 Role, реализовано и проверено сохранение изображения в S3, настроены краткосрочные подписанные ссылки, выполнена миграция таблицы метаданных, подтверждён эффект удаления `s3:ListBucket` и подготовлены схема архитектуры и ADR.

**Не следует считать выполненными без дополнительных испытаний:** полную таблицу `AssumeRole` в №8; миграцию прежних файлов в №10 (их не существовало); повторную проверку PDF, удаления вложения и прав второго пользователя; отдельное CloudShell-сравнение из №13. Остановка EC2-инстансов после завершения работы в представленных материалах не подтверждена.

**Вывод:** объектное хранилище S3 позволило отделить вложения от постоянного диска `app-server`, а IAM Role и Presigned URL — предоставить приложению и пользователю только необходимые полномочия. Versioning и Lifecycle добавляют восстановление после случайного удаления и контроль роста хранилища.

## 7. Материалы

- [Текст задания №4](cloud_lab4.md)
- [Использованные команды](commands.txt) — **в исходных заметках есть полный ранее выданный Presigned URL; перед публикацией материалов рекомендуется удалить его**.
- [Ответы на вопросы, записанные в ходе лабораторной](answers.txt)
- [Bucket Policy HTTPS-only](policy.json)
- [IAM Policy до сужения прав](policy_iam.json)
- [IAM Policy после сужения прав](policy_iam2.json)
- [AWS-диаграмма Draw.io](images/Lab4_AWS_Architecture_AmazonIcons.drawio)
- [ADR-0003](docs/adr/0003-attachment-storage.md)
- [Исходники приложения в LaboratoryApp](https://github.com/leopard-bf187-cloud/LaboratoryApp/tree/feat/cloud-lab4-s3-attachments)

Все подтверждающие скриншоты находятся в каталоге [`images/`](images/).
