#!/usr/bin/env bash
# Отключаем -e, чтобы упавшая проверка не прерывала весь прогон тестов.
set -uo pipefail

# Определяем полный путь к папке, где лежит скрипт, и путь к тестируемому backup.sh.
ROOT="$(cd "$(dirname "$0")" && pwd)"
BACKUP_SH="$ROOT/backup.sh"

if [ ! -x "$BACKUP_SH" ]; then
    echo "Ошибка: не найден или не исполняемый $BACKUP_SH" >&2
    exit 1
fi

# Создаем песочницу (временную папку) прямо в папке со скриптами.
# trap гарантирует, что она удалится при любом завершении (даже если упадем).
SANDBOX=$(mktemp -d -p "$ROOT")
trap 'rm -rf "$SANDBOX"' EXIT

PASS=0
FAIL=0

# Вспомогательная функция: генерирует тестовые файлы.
# Создает $2 файлов по 50 МБ с разным возрастом (от 1 до $2 дней).
make_logs() {
    local dir="$1"
    local count="$2"
    local i name
    mkdir -p "$dir"
    for i in $(seq 1 "$count"); do
        name=$(printf "app %02d.log" "$i")
        dd if=/dev/zero of="$dir/$name" bs=1M count=50 status=none
        touch -d "$i days ago" "$dir/$name"
    done
}

# Вспомогательная функция: считает общий размер всех файлов в папке (в байтах).
used_bytes() {
    find "$1" -type f -printf '%s\n' | awk '{s+=$1} END{printf "%.0f\n", s}'
}

# Вспомогательная функция: считает количество файлов в папке.
count_files() {
    find "$1" -type f | wc -l
}

# Вспомогательная функция: проверяет, есть ли конкретный файл внутри архива.
in_archive() {
    tar -tzf "$1" -- "$2" > /dev/null 2>&1
}

# Главная функция проверки. Выполняет команду и пишет [PASS] или [FAIL], 
# увеличивая соответствующий счетчик. Не прерывает выполнение.
check() {
    local msg="$1"
    shift
    if "$@" > /dev/null 2>&1; then
        echo "  [PASS] $msg"
        PASS=$(( PASS + 1 ))
    else
        echo "  [FAIL] $msg"
        FAIL=$(( FAIL + 1 ))
    fi
}

# Запуск тестируемого скрипта. Передает ему переменные для ёмкости и папки бэкапов,
# а вывод и код возврата сохраняет в переменные $OUT и $RC.
run_backup() {
    local log="$1" bak="$2" cap_mib="$3" thr="$4"
    OUT=$(LOG_CAPACITY=$(( cap_mib * 1024 * 1024 )) BACKUP_DIR="$bak" \
          "$BACKUP_SH" "$log" "$thr" 2>&1)
    RC=$?
}

# Тест 1: проверяет, что скрипт ничего не делает, если заполнение ниже порога.
test_below_threshold() {
    local d="$SANDBOX/t1"
    local log="$d/log" bak="$d/backup"
    mkdir -p "$bak"
    make_logs "$log" 12

    echo "  [INFO] Условия: логи 600 МБ, ёмкость 2000 МБ (30%), порог 70%"
    run_backup "$log" "$bak" 2000 70

    check "успешное завершение (код 0)" test "$RC" -eq 0
    check "архив не создан" test -z "$(find "$bak" -name '*.tar.gz')"
    check "все 12 файлов на месте" test "$(count_files "$log")" -eq 12
}

# Тест 2: проверяет базовую логику — архивацию и удаление при превышении порога.
test_above_threshold() {
    local d="$SANDBOX/t2"
    local log="$d/log" bak="$d/backup"
    mkdir -p "$bak"
    make_logs "$log" 12

    echo "  [INFO] Условия: логи 600 МБ, ёмкость 700 МБ (85%), порог 70%"
    run_backup "$log" "$bak" 700 70

    local arch
    arch=$(find "$bak" -name '*.tar.gz' | head -n 1)
    check "успешное завершение (код 0)" test "$RC" -eq 0
    check "архив создан" test -n "$arch"
    check "в архиве 3 файла" test "$(tar -tzf "$arch" | wc -l)" -eq 3
    check "в /log осталось 9 файлов" test "$(count_files "$log")" -eq 9
    check "заполнение стало <= 70%" \
        test "$(used_bytes "$log")" -le $(( 700 * 1024 * 1024 * 70 / 100 ))
}

# Тест 3: проверяет, что скрипт архивирует именно старые файлы по дате (mtime), 
# а не просто первые попавшиеся или по алфавиту.
test_oldest_first() {
    local d="$SANDBOX/t3"
    local log="$d/log" bak="$d/backup"
    mkdir -p "$bak"
    make_logs "$log" 12

    # Принудительно делаем три файла самыми старыми (2020 год), чтобы сбить порядок.
    touch -d "2020-01-01 10:00:00" "$log/app 07.log"
    touch -d "2020-01-01 11:00:00" "$log/app 02.log"
    touch -d "2020-01-01 12:00:00" "$log/app 09.log"

    echo "  [INFO] Условия: логи 600 МБ, ёмкость 700 МБ (85%), порог 70%. Самые старые: app 07, app 02, app 09"
    run_backup "$log" "$bak" 700 70

    local arch
    arch=$(find "$bak" -name '*.tar.gz' | head -n 1)
    check "в архиве app 07.log" in_archive "$arch" "app 07.log"
    check "в архиве app 02.log" in_archive "$arch" "app 02.log"
    check "в архиве app 09.log" in_archive "$arch" "app 09.log"
    check "app 07.log удалён" test ! -e "$log/app 07.log"
    check "app 02.log удалён" test ! -e "$log/app 02.log"
    check "app 09.log удалён" test ! -e "$log/app 09.log"
    check "новый app 01.log на месте" test -e "$log/app 01.log"
}

# Тест 4: проверяет защиту от потери данных. Если архив не создался (нет прав),
# скрипт должен вернуть ошибку и не удалять оригиналы.
test_archive_failure() {
    if [ "$(id -u)" -eq 0 ]; then
        echo "  [SKIP] от root нельзя сделать папку недоступной для записи"
        return
    fi
    local d="$SANDBOX/t4"
    local log="$d/log" bak="$d/backup"
    mkdir -p "$bak"
    make_logs "$log" 12
    chmod 555 "$bak"  # Запрещаем запись в папку бэкапов.

    echo "  [INFO] Условия: логи 600 МБ, ёмкость 700 МБ (85%), порог 70%. Папка бэкапов недоступна для записи"
    run_backup "$log" "$bak" 700 70
    chmod 755 "$bak"  # Возвращаем права, чтобы тест не сломал песочницу.

    check "завершение с ошибкой (код не 0)" test "$RC" -ne 0
    check "все 12 файлов на месте" test "$(count_files "$log")" -eq 12
}

# Тест 5: проверяет, что скрипт правильно реагирует на изменение порога (60% вместо 70%).
test_custom_threshold() {
    local d="$SANDBOX/t5"
    local log="$d/log" bak="$d/backup"
    mkdir -p "$bak"
    make_logs "$log" 12

    echo "  [INFO] Условия: логи 600 МБ, ёмкость 700 МБ (85%), порог 60%"
    run_backup "$log" "$bak" 700 60

    local arch
    arch=$(find "$bak" -name '*.tar.gz' | head -n 1)
    check "успешное завершение (код 0)" test "$RC" -eq 0
    check "в архиве 4 файла" test "$(tar -tzf "$arch" | wc -l)" -eq 4
    check "в /log осталось 8 файлов" test "$(count_files "$log")" -eq 8
    check "заполнение стало <= 60%" \
        test "$(used_bytes "$log")" -le $(( 700 * 1024 * 1024 * 60 / 100 ))
}

# Тест 6: проверяет, что скрипт не падает, а выдает ошибку при неверных аргументах.
test_bad_args() {
    local d="$SANDBOX/t6"
    local log="$d/log" bak="$d/backup"
    mkdir -p "$bak"
    make_logs "$log" 12

    echo "  [INFO] Условия: проверка обработки неверных аргументов"
    
    OUT=$(BACKUP_DIR="$bak" "$BACKUP_SH" 2>&1); RC=$?
    check "нет аргумента -> ошибка ввода (код 1)" test "$RC" -eq 1

    OUT=$(BACKUP_DIR="$bak" "$BACKUP_SH" "$d/nope" 70 2>&1); RC=$?
    check "нет папки -> ошибка пути (код 1)" test "$RC" -eq 1

    OUT=$(LOG_CAPACITY=$(( 700 * 1024 * 1024 )) BACKUP_DIR="$bak" \
          "$BACKUP_SH" "$log" abc 2>&1); RC=$?
    check "порог 'abc' -> ошибка формата (код 1)" test "$RC" -eq 1

    check "в /log все 12 файлов" test "$(count_files "$log")" -eq 12
    check "архив не создан" test -z "$(find "$bak" -name '*.tar.gz')"
}

# Запуск тестов.
echo "Тестируем: $BACKUP_SH"
echo "Песочница: $SANDBOX"
echo

echo "== Тест 1: Заполнение ниже порога (ничего не трогаем)"
test_below_threshold
echo

echo "== Тест 2: Заполнение выше порога (архивируем и удаляем)"
test_above_threshold
echo

echo "== Тест 3: Архивируем именно самые старые файлы (сортировка по mtime)"
test_oldest_first
echo

echo "== Тест 4: Сбой архивации (защита от потери данных)"
test_archive_failure
echo

echo "== Тест 5: Свой порог 60% (проверка аргумента)"
test_custom_threshold
echo

echo "== Тест 6: Кривые аргументы (валидация ввода)"
test_bad_args
echo

# Итог. Если $FAIL равно 0, скрипт завершится с кодом 0 (успех).
echo "Итого: пройдено $PASS, провалено $FAIL"
[ "$FAIL" -eq 0 ]
