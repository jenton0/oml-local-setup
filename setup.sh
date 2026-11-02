#!/usr/bin/env bash
# Локальний Oracle Database Free для лабораторних з OML4SQL.
# Піднімає базу в контейнері podman замість Oracle Cloud (ATP).
# Скрипт ідемпотентний: повторний запуск нічого не ламає.

set -euo pipefail

CONTAINER="${ORA_CONTAINER:-oradb}"
PORT="${ORA_PORT:-1521}"
IMAGE="${ORA_IMAGE:-container-registry.oracle.com/database/free:latest}"
PDB="${ORA_PDB:-FREEPDB1}"
LAB_USER="${ORA_LAB_USER:-omluser}"
SECRETS="${ORA_SECRETS_DIR:-$HOME/.oml-local}"
WAIT_MIN="${ORA_WAIT_MIN:-20}"
RECREATE=0

for arg in "$@"; do
  case "$arg" in
    --recreate) RECREATE=1 ;;
    -h|--help)
      sed -n '2,4p' "$0" | sed 's/^# \?//'
      echo
      echo "Використання: ./setup.sh [--recreate]"
      echo
      echo "Змінні оточення:"
      echo "  ORA_CONTAINER   назва контейнера (типово oradb)"
      echo "  ORA_PORT        порт на хості (типово 1521)"
      echo "  ORA_LAB_USER    навчальна схема (типово omluser)"
      echo "  ORA_WAIT_MIN    скільки хвилин чекати готовності (типово 20)"
      exit 0 ;;
    *) echo "невідомий аргумент: $arg (див. --help)" >&2; exit 2 ;;
  esac
done

step() { printf '\n\033[1m[%s]\033[0m %s\n' "$1" "$2"; }
info() { printf '      %s\n' "$1"; }
die()  { printf '\n\033[31mПОМИЛКА:\033[0m %s\n' "$1" >&2; exit 1; }

# ---------------------------------------------------------------- 1. передумови
step 1/7 "Перевірка передумов"

if ! command -v podman >/dev/null 2>&1; then
  info "podman не знайдено"
  if command -v sudo >/dev/null 2>&1 && [ -t 0 ]; then
    printf '      Встановити його зараз (sudo apt-get install -y podman)? [y/N] '
    read -r ans
    case "$ans" in
      [yY]*) sudo apt-get update && sudo apt-get install -y podman ;;
      *) die "без podman далі не піде" ;;
    esac
  else
    die "podman не встановлено. Виконайте: sudo apt-get install -y podman"
  fi
fi
info "podman $(podman --version | awk '{print $3}')"

command -v python3 >/dev/null 2>&1 \
  || info "УВАГА: немає python3 — скрипт load_csv.py не працюватиме"

FREE_DISK=$(df -BG --output=avail "$HOME" | tail -1 | tr -dc '0-9')
[ "$FREE_DISK" -ge 15 ] || die "на диску вільно ${FREE_DISK} ГБ, потрібно щонайменше 15 ГБ (образ ~6 ГБ на диску + дані)"
info "вільно на диску: ${FREE_DISK} ГБ"

FREE_RAM=$(free -g | awk '/^Mem:/ {print $7}')
if [ "$FREE_RAM" -lt 3 ]; then
  info "УВАГА: вільної памʼяті ${FREE_RAM} ГБ. Oracle потребує ~2,5 ГБ."
  if pgrep -f 'NameNode|ResourceManager' >/dev/null 2>&1; then
    info "Запущено Hadoop. Памʼяті на Hadoop і Oracle одночасно не вистачить."
    info "Зупиніть його:  source ~/.hadoop_env && stop-yarn.sh && stop-dfs.sh"
    die "недостатньо вільної памʼяті"
  fi
else
  info "вільної памʼяті: ${FREE_RAM} ГБ"
fi

# ---------------------------------------------------------------- 2. паролі
step 2/7 "Паролі"
mkdir -p "$SECRETS"; chmod 700 "$SECRETS"
gen_pwd() { { openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 16; echo "Aa1"; }; }

if [ ! -f "$SECRETS/system" ]; then
  gen_pwd > "$SECRETS/system"; chmod 600 "$SECRETS/system"
  info "згенеровано пароль SYSTEM -> $SECRETS/system"
else
  info "пароль SYSTEM уже є -> $SECRETS/system"
fi
if [ ! -f "$SECRETS/$LAB_USER" ]; then
  gen_pwd > "$SECRETS/$LAB_USER"; chmod 600 "$SECRETS/$LAB_USER"
  info "згенеровано пароль $LAB_USER -> $SECRETS/$LAB_USER"
fi
SYS_PWD=$(cat "$SECRETS/system")
LAB_PWD=$(cat "$SECRETS/$LAB_USER")

# ---------------------------------------------------------------- 3. образ
step 3/7 "Образ Oracle Database Free"
if podman image exists "$IMAGE" 2>/dev/null; then
  info "образ уже завантажено"
else
  info "завантаження ~10 ГБ, це надовго — залежить від каналу"
  podman pull "$IMAGE"
fi

# ---------------------------------------------------------------- 4. контейнер
step 4/7 "Контейнер $CONTAINER"
if [ "$RECREATE" = 1 ] && podman container exists "$CONTAINER" 2>/dev/null; then
  info "--recreate: видаляю старий контейнер разом із даними"
  podman rm -f "$CONTAINER" >/dev/null
fi

if podman container exists "$CONTAINER" 2>/dev/null; then
  if [ "$(podman inspect -f '{{.State.Running}}' "$CONTAINER")" = "true" ]; then
    info "контейнер уже працює"
  else
    info "контейнер існує, запускаю"
    podman start "$CONTAINER" >/dev/null
  fi
else
  info "створюю контейнер, порт $PORT"
  podman run -d --name "$CONTAINER" -p "$PORT":1521 \
    -e ORACLE_PWD="$SYS_PWD" "$IMAGE" >/dev/null
fi

# ---------------------------------------------------------------- 5. готовність
step 5/7 "Очікування готовності бази"
info "зазвичай 30-60 секунд: база вже створена всередині образу"
DEADLINE=$(( $(date +%s) + WAIT_MIN * 60 ))
printf 'SET HEADING OFF FEEDBACK OFF PAGESIZE 0\nSELECT %s FROM dual;\nEXIT\n' "'OML_PING_OK'" > /tmp/.oml_ping.sql
podman cp /tmp/.oml_ping.sql "$CONTAINER":/tmp/.oml_ping.sql >/dev/null 2>&1 || true

READY=0
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  podman cp /tmp/.oml_ping.sql "$CONTAINER":/tmp/.oml_ping.sql >/dev/null 2>&1 || true
  OUT=$(podman exec -i "$CONTAINER" bash -lc \
        "sqlplus -s system/\"$SYS_PWD\"@$PDB @/tmp/.oml_ping.sql" 2>&1 | tr -d '\r' || true)
  case "$OUT" in
    *OML_PING_OK*) READY=1; break ;;
    *ORA-01017*)   die "невірний пароль SYSTEM. Контейнер створено з іншим паролем.
      Або відновіть $SECRETS/system, або перестворіть базу:  ./setup.sh --recreate" ;;
  esac
  printf '.'
  sleep 15
done
printf '\n'
[ "$READY" = 1 ] || die "база не відповіла за $WAIT_MIN хв. Подивіться лог:  podman logs $CONTAINER | tail -40"
info "база відповідає на SQL"

# ---------------------------------------------------------------- 6. схема
step 6/7 "Навчальна схема $LAB_USER"
cat > /tmp/.oml_user.sql <<SQL
SET DEFINE OFF
SET FEEDBACK OFF
DECLARE
  n NUMBER;
BEGIN
  SELECT COUNT(*) INTO n FROM dba_users WHERE username = UPPER('$LAB_USER');
  IF n = 0 THEN
    EXECUTE IMMEDIATE 'CREATE USER $LAB_USER IDENTIFIED BY "$LAB_PWD" QUOTA UNLIMITED ON USERS';
  ELSE
    EXECUTE IMMEDIATE 'ALTER USER $LAB_USER IDENTIFIED BY "$LAB_PWD"';
  END IF;
END;
/
GRANT CREATE SESSION, CREATE TABLE, CREATE VIEW, CREATE PROCEDURE,
      CREATE MINING MODEL, CREATE SEQUENCE TO $LAB_USER;
SET HEADING OFF PAGESIZE 0
SELECT 'DBMS_DATA_MINING: ' || status FROM dba_objects
 WHERE owner = 'SYS' AND object_name = 'DBMS_DATA_MINING' AND object_type = 'PACKAGE';
EXIT
SQL
podman cp /tmp/.oml_user.sql "$CONTAINER":/tmp/.oml_user.sql >/dev/null
RES=$(podman exec -i "$CONTAINER" bash -lc \
      "sqlplus -s system/\"$SYS_PWD\"@$PDB @/tmp/.oml_user.sql" 2>&1 | tr -d '\r')
echo "$RES" | grep -q 'DBMS_DATA_MINING: VALID' \
  || die "пакет DBMS_DATA_MINING недоступний. Вивід:
$RES"
info "схему створено, DBMS_DATA_MINING доступний"

# ---------------------------------------------------------------- 7. підсумок
step 7/7 "Готово"
cat <<EOF

  Контейнер   : $CONTAINER (порт $PORT)
  PDB         : $PDB
  Схема       : $LAB_USER
  Паролі      : $SECRETS/system , $SECRETS/$LAB_USER

  Підключення з WSL:
    podman exec -it $CONTAINER sqlplus $LAB_USER/"\$(cat $SECRETS/$LAB_USER)"@$PDB

  Перевірити весь ланцюжок (будує модель ESM на тестових даних):
    ./smoke_test.sh

  Залити CSV у таблицю:
    python3 load_csv.py pdfo02.csv PDFO02

  Зупинити базу (звільнити памʼять під Hadoop):
    podman stop $CONTAINER

EOF
