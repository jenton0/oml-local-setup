#!/usr/bin/env bash
# Перевіряє весь ланцюжок OML4SQL: таблиця -> модель Time Series ESM -> прогноз.
# Якщо цей скрипт пройшов, середовище придатне для лабораторних.

set -euo pipefail

CONTAINER="${ORA_CONTAINER:-oradb}"
PDB="${ORA_PDB:-FREEPDB1}"
LAB_USER="${ORA_LAB_USER:-omluser}"
SECRETS="${ORA_SECRETS_DIR:-$HOME/.oml-local}"

[ -f "$SECRETS/$LAB_USER" ] || { echo "немає $SECRETS/$LAB_USER — спочатку ./setup.sh" >&2; exit 1; }
LAB_PWD=$(cat "$SECRETS/$LAB_USER")

cat > /tmp/.oml_smoke.sql <<'SQL'
SET DEFINE OFF
SET FEEDBACK OFF
SET LINESIZE 120
SET PAGESIZE 60

BEGIN EXECUTE IMMEDIATE 'DROP TABLE SMOKE_TS PURGE'; EXCEPTION WHEN OTHERS THEN NULL; END;
/
CREATE TABLE SMOKE_TS (TS_DATE DATE, VAL NUMBER);

-- 36 місяців: лінійний тренд + річна сезонність
INSERT INTO SMOKE_TS
SELECT ADD_MONTHS(DATE '2020-01-01', LEVEL - 1),
       100 + 2 * LEVEL + 20 * SIN(2 * 3.14159 * MOD(LEVEL - 1, 12) / 12)
  FROM dual CONNECT BY LEVEL <= 36;
COMMIT;

BEGIN DBMS_DATA_MINING.DROP_MODEL('SMOKE_ESM'); EXCEPTION WHEN OTHERS THEN NULL; END;
/
DECLARE
  v DBMS_DATA_MINING.SETTING_LIST;
BEGIN
  v('ALGO_NAME')            := 'ALGO_EXPONENTIAL_SMOOTHING';
  v('EXSM_INTERVAL')        := 'EXSM_INTERVAL_MONTH';
  v('EXSM_PREDICTION_STEP') := '3';
  v('EXSM_MODEL')           := 'EXSM_WINTERS';
  v('EXSM_SEASONALITY')     := '12';
  DBMS_DATA_MINING.CREATE_MODEL2(
    MODEL_NAME          => 'SMOKE_ESM',
    MINING_FUNCTION     => 'TIME_SERIES',
    DATA_QUERY          => 'SELECT * FROM SMOKE_TS',
    SET_LIST            => v,
    CASE_ID_COLUMN_NAME => 'TS_DATE',
    TARGET_COLUMN_NAME  => 'VAL');
END;
/
PROMPT
PROMPT === параметри моделі ===
COLUMN NAME FORMAT A14
SELECT NAME, ROUND(NUMERIC_VALUE, 4) AS VALUE
  FROM DM$VGSMOKE_ESM WHERE NAME IN ('ALPHA','BETA','GAMMA','MAE') ORDER BY NAME;

PROMPT
PROMPT === прогноз на 3 місяці вперед ===
COLUMN DT FORMAT A9
SELECT TO_CHAR(CASE_ID,'YYYY-MM') AS DT, ROUND(PREDICTION,2) AS FORECAST
  FROM DM$VPSMOKE_ESM WHERE VALUE IS NULL ORDER BY CASE_ID;

PROMPT
PROMPT SMOKE_TEST_PASSED
EXIT
SQL

podman cp /tmp/.oml_smoke.sql "$CONTAINER":/tmp/.oml_smoke.sql >/dev/null
OUT=$(podman exec -i "$CONTAINER" bash -lc \
      "sqlplus -s $LAB_USER/\"$LAB_PWD\"@$PDB @/tmp/.oml_smoke.sql" 2>&1 | tr -d '\r')
echo "$OUT"

if echo "$OUT" | grep -q SMOKE_TEST_PASSED && ! echo "$OUT" | grep -q 'ORA-'; then
  printf '\n\033[32mПройдено:\033[0m середовище придатне для лабораторних з OML4SQL.\n'
else
  printf '\n\033[31mНе пройдено.\033[0m Розберіть вивід вище.\n' >&2
  exit 1
fi
