#!/usr/bin/env bash
# Выходим при любой ошибке, опечатке в переменной или падении в пайпе.
set -euo pipefail

# Читаем аргументы: папка логов, порог (по умолчанию 70%) и папка бэкапов.
LOG_DIR="${1:-}"
THRESHOLD="${2:-70}"
BACKUP_DIR="${BACKUP_DIR:-/backup}"

# Проверки: аргумент передан, папка существует, порог — это число от 1 до 99.
if [ -z "$LOG_DIR" ]; then
    echo "Использование: $0 <папка_log> [порог_%]" >&2
    exit 1
fi
if [ ! -d "$LOG_DIR" ]; then
    echo "Ошибка: папка не найдена: $LOG_DIR" >&2
    exit 1
fi
if ! [[ "$THRESHOLD" =~ ^[0-9]+$ ]] || [ "$THRESHOLD" -lt 1 ] || [ "$THRESHOLD" -gt 99 ]; then
    echo "Ошибка: порог должен быть числом от 1 до 99" >&2
    exit 1
fi

# Считаем сумму размеров файлов в байтах через find и awk.
get_size() {
    find "$1" -type f -printf '%s\n' | awk '{s+=$1} END{print s+0}'
}
USED=$(get_size "$LOG_DIR")

# Ёмкость: берем из переменной (для тестов) или из размера диска через df.
CAPACITY="${LOG_CAPACITY:-$(df -Pk "$LOG_DIR" | awk 'NR==2{print $2*1024}')}"
if [ "$CAPACITY" -le 0 ]; then
    echo "Ошибка: не удалось определить ёмкость" >&2
    exit 1
fi

# Считаем процент для вывода пользователю.
PERCENT=$(( USED * 100 / CAPACITY ))
echo "Папка: $LOG_DIR"
echo "Заполнение: ${PERCENT}% (порог ${THRESHOLD}%)"

# Сравниваем без деления, чтобы 70.9% не округлилось до 70%. Если порог не превышен — выходим.
if [ $(( USED * 100 )) -le $(( THRESHOLD * CAPACITY )) ]; then
    echo "Порог не превышен, архивация не нужна"
    exit 0
fi

# Считаем, сколько байт нужно освободить.
TO_FREE=$(( USED - CAPACITY * THRESHOLD / 100 ))

# Временный файл для списка. trap удалит его при любом завершении (даже с ошибкой).
LIST=$(mktemp)
trap 'rm -f "$LIST"' EXIT

# Ищем файлы, выводим время, размер и имя (через NUL-байт, чтобы не ломались пробелы). 
# Сортируем по времени (старые сверху) и набираем файлы, пока не освободим нужный объем.
FREED=0
COUNT=0
while IFS= read -r -d '' rec; do
    rest="${rec#* }"       # отрезаем время
    size="${rest%% *}"     # отрезаем размер
    path="${rest#* }"      # оставляем путь

    echo "$path" >> "$LIST"
    FREED=$(( FREED + size ))
    COUNT=$(( COUNT + 1 ))

    if [ "$FREED" -ge "$TO_FREE" ]; then
        break
    fi
done < <(cd "$LOG_DIR" && find . -type f -printf '%T@ %s %P\0' | sort -z -n)

# Если файлов нет (папка пустая) — выходим.
if [ "$COUNT" -eq 0 ]; then
    echo "Нет файлов для архивации" >&2
    exit 1
fi

echo "Нужно освободить $TO_FREE байт, в архив идут $COUNT самых старых файлов"

# Создаем папку бэкапов и уникальное имя архива (с текущей датой).
mkdir -p "$BACKUP_DIR" || { echo "Ошибка: нельзя создать $BACKUP_DIR" >&2; exit 1; }
STAMP=$(date +%Y%m%d_%H%M%S)
ARCHIVE="$BACKUP_DIR/log_backup_$STAMP.tar.gz"

# Архивация. Если tar упал — выходим с кодом 2, не трогая оригиналы.
if ! tar -C "$LOG_DIR" -czf "$ARCHIVE" -T "$LIST"; then
    echo "Ошибка: не удалось создать архив. Файлы не тронуты" >&2
    exit 2
fi

# Проверка архива на целостность. Защищает от удаления логов, если архив битый.
if ! tar -tzf "$ARCHIVE" > /dev/null; then
    echo "Ошибка: архив повреждён. Файлы не тронуты" >&2
    exit 2
fi

echo "Архив создан: $ARCHIVE"

# Удаляем только те файлы, которые успешно попали в проверенный архив.
while IFS= read -r file; do
    rm -f "$LOG_DIR/$file"
done < "$LIST"

# Считаем новый процент и выводим итог.
NEW_USED=$(get_size "$LOG_DIR")
NEW_PERCENT=$(( NEW_USED * 100 / CAPACITY ))
echo "Удалено файлов: $COUNT. Заполнение теперь: ${NEW_PERCENT}%"
exit 0
