#!/usr/bin/env bash
# Python-середовища для лабораторних.
#   ~/mlenv  — основне: scikit-learn, xgboost, lightgbm, shap, jupyterlab
#   ~/arenv  — окремо під асоціативні правила: mlxtend
# Розділені навмисно: mlxtend має власні обмеження на версію pandas
# і в спільному оточенні конфліктує з рештою пакетів.

set -euo pipefail

ML_ENV="${ML_ENV:-$HOME/mlenv}"
AR_ENV="${AR_ENV:-$HOME/arenv}"
DEEP=0

for arg in "$@"; do
  case "$arg" in
    --deep) DEEP=1 ;;
    -h|--help)
      echo "Використання: ./setup_python.sh [--deep]"
      echo
      echo "  без прапорця  базовий ML-набір, ~400 МБ"
      echo "  --deep        додає TensorFlow і PyTorch, ще ~3 ГБ"
      echo
      echo "Змінні: ML_ENV (типово ~/mlenv), AR_ENV (типово ~/arenv)"
      exit 0 ;;
    *) echo "невідомий аргумент: $arg" >&2; exit 2 ;;
  esac
done

step() { printf '\n\033[1m[%s]\033[0m %s\n' "$1" "$2"; }
info() { printf '      %s\n' "$1"; }
die()  { printf '\n\033[31mПОМИЛКА:\033[0m %s\n' "$1" >&2; exit 1; }

step 1/4 "Перевірка передумов"
command -v python3 >/dev/null 2>&1 || die "немає python3: sudo apt-get install -y python3"
PYV=$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')
info "python3 $PYV"
python3 -c 'import venv' 2>/dev/null \
  || die "немає модуля venv: sudo apt-get install -y python3-venv"

FREE_DISK=$(df -BG --output=avail "$HOME" | tail -1 | tr -dc '0-9')
NEED=$([ "$DEEP" = 1 ] && echo 6 || echo 2)
[ "$FREE_DISK" -ge "$NEED" ] || die "потрібно ~${NEED} ГБ вільних, є ${FREE_DISK} ГБ"
info "вільно на диску: ${FREE_DISK} ГБ"

step 2/4 "Основне середовище  $ML_ENV"
[ -d "$ML_ENV" ] || python3 -m venv "$ML_ENV"
"$ML_ENV/bin/python" -m pip install --quiet --upgrade pip
info "встановлення базового набору"
"$ML_ENV/bin/python" -m pip install --quiet \
  numpy pandas scipy scikit-learn matplotlib seaborn statsmodels \
  xgboost lightgbm shap openpyxl ipykernel jupyterlab
info "готово"

if [ "$DEEP" = 1 ]; then
  info "встановлення TensorFlow і PyTorch — це надовго"
  "$ML_ENV/bin/python" -m pip install --quiet tensorflow-cpu || \
    info "tensorflow-cpu не став — для нейромережевих лаб доведеться ставити вручну"
  "$ML_ENV/bin/python" -m pip install --quiet \
    torch --index-url https://download.pytorch.org/whl/cpu
  "$ML_ENV/bin/python" -m pip install --quiet transformers datasets
  info "глибоке навчання готове"
fi

step 3/4 "Середовище для асоціативних правил  $AR_ENV"
[ -d "$AR_ENV" ] || python3 -m venv "$AR_ENV"
"$AR_ENV/bin/python" -m pip install --quiet --upgrade pip
"$AR_ENV/bin/python" -m pip install --quiet pandas mlxtend openpyxl matplotlib
info "готово"

step 4/4 "Перевірка"
"$ML_ENV/bin/python" - <<'PY'
import importlib.metadata as m
names = ["numpy","pandas","scipy","scikit-learn","matplotlib","seaborn",
         "statsmodels","xgboost","lightgbm","shap","jupyterlab"]
for n in names:
    try:
        print("      %-14s %s" % (n, m.version(n)))
    except Exception:
        print("      %-14s ВІДСУТНІЙ" % n)
for n in ("tensorflow","torch","transformers"):
    try:
        print("      %-14s %s" % (n, m.version(n)))
    except Exception:
        pass
PY
echo
"$AR_ENV/bin/python" - <<'PY'
import importlib.metadata as m
from mlxtend.frequent_patterns import apriori, association_rules   # noqa: F401
print("      mlxtend        %s  (імпорт apriori пройшов)" % m.version("mlxtend"))
PY

cat <<EOF

  Запуск JupyterLab:
    $ML_ENV/bin/jupyter-lab --no-browser

  Асоціативні правила:
    $AR_ENV/bin/python my_rules.py

  Ядро для ноутбуків уже зареєстроване через ipykernel.

EOF
