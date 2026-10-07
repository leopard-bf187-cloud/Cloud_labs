#!/bin/bash
set -euo pipefail

cd /var/www/mood-diary

echo "==> Забираем новый код из GitHub"
git pull --ff-only

echo "==> Устанавливаем зависимости"
composer install --no-dev --optimize-autoloader --no-interaction

echo "==> Применяем миграции"
php migrate.php

echo "==> Перезагружаем PHP-FPM"
sudo systemctl reload php-fpm

echo "Готово. На сервере коммит: $(git log -1 --oneline)"