#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Заливає CSV у таблицю локального Oracle Free.

У Free-контейнері немає APEX, на який посилаються методички, і немає
налаштованого SQL*Loader, тому таблиця створюється і наповнюється
згенерованими INSERT-ами через sqlplus. Для навчальних датасетів
(сотні-тисячі рядків) цього досить.

    python3 load_csv.py pdfo02.csv PDFO02
    python3 load_csv.py data.csv MYTAB --delimiter ';' --encoding cp1251
"""
import argparse
import csv
import io
import os
import re
import subprocess
import sys
import tempfile

DATE_FORMATS = [
    ("%m/%d/%Y", "MM/DD/YYYY"),
    ("%d.%m.%Y", "DD.MM.YYYY"),
    ("%Y-%m-%d", "YYYY-MM-DD"),
    ("%d/%m/%Y", "DD/MM/YYYY"),
]
NUM_RE = re.compile(r"^-?\d+(\.\d+)?([eE][-+]?\d+)?$")


def sniff(values):
    """Повертає ('NUMBER', None) | ('DATE', oracle_fmt) | ('VARCHAR2', width)."""
    vals = [v for v in values if v not in ("", None)]
    if not vals:
        return ("VARCHAR2", 100)
    if all(NUM_RE.match(v) for v in vals):
        return ("NUMBER", None)
    import datetime
    for py_fmt, ora_fmt in DATE_FORMATS:
        ok = True
        for v in vals:
            try:
                datetime.datetime.strptime(v, py_fmt)
            except ValueError:
                ok = False
                break
        if ok:
            return ("DATE", ora_fmt)
    return ("VARCHAR2", min(4000, max(32, max(len(v) for v in vals) * 2)))


TRANSLIT = {
    "А": "A", "Б": "B", "В": "V", "Г": "H", "Ґ": "G", "Д": "D", "Е": "E",
    "Є": "IE", "Ж": "ZH", "З": "Z", "И": "Y", "І": "I", "Ї": "I", "Й": "I",
    "К": "K", "Л": "L", "М": "M", "Н": "N", "О": "O", "П": "P", "Р": "R",
    "С": "S", "Т": "T", "У": "U", "Ф": "F", "Х": "KH", "Ц": "TS", "Ч": "CH",
    "Ш": "SH", "Щ": "SHCH", "Ь": "", "Ю": "IU", "Я": "IA", "Ы": "Y", "Э": "E",
    "Ё": "E", "Ъ": "",
}


def ident(name):
    """Назва стовпця для Oracle. Кирилиця транслітерується, бо інакше всі
    такі заголовки перетворюються на однакові підкреслення і база падає
    з ORA-00957 duplicate column name."""
    s = "".join(TRANSLIT.get(ch, ch) for ch in name.strip().upper())
    s = re.sub(r"[^A-Za-z0-9_]", "_", s)
    s = re.sub(r"_{2,}", "_", s).strip("_")
    if not s or not s[0].isalpha():
        s = "C_" + s
    return s[:30]


def unique_idents(names):
    """Гарантує унікальність після транслітерації та обрізання до 30 символів."""
    out, seen = [], {}
    for raw in names:
        base = ident(raw)
        if base not in seen:
            seen[base] = 1
            out.append(base)
        else:
            seen[base] += 1
            suffix = "_%d" % seen[base]
            out.append(base[:30 - len(suffix)] + suffix)
    return out


def q(s):
    return "'" + s.replace("'", "''") + "'"


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("csv_file")
    ap.add_argument("table")
    ap.add_argument("--delimiter", default=",")
    ap.add_argument("--encoding", default="utf-8-sig")
    ap.add_argument("--container", default=os.environ.get("ORA_CONTAINER", "oradb"))
    ap.add_argument("--pdb", default=os.environ.get("ORA_PDB", "FREEPDB1"))
    ap.add_argument("--user", default=os.environ.get("ORA_LAB_USER", "omluser"))
    ap.add_argument("--secrets", default=os.environ.get(
        "ORA_SECRETS_DIR", os.path.expanduser("~/.oml-local")))
    ap.add_argument("--dry-run", action="store_true", help="лише показати SQL, не виконувати")
    a = ap.parse_args()

    pwd_path = os.path.join(a.secrets, a.user)
    if not a.dry_run and not os.path.exists(pwd_path):
        sys.exit("не знайдено пароль %s — спочатку запустіть ./setup.sh" % pwd_path)

    with io.open(a.csv_file, encoding=a.encoding, newline="") as fh:
        rows = list(csv.reader(fh, delimiter=a.delimiter))
    if len(rows) < 2:
        sys.exit("у файлі немає даних")

    header = unique_idents(rows[0])
    width = len(header)
    body = [r for r in rows[1:] if any(x.strip() for x in r)]
    body = [r[:width] + [""] * (width - len(r)) for r in body]

    types = [sniff([r[i].strip() for r in body]) for i in range(width)]
    print("таблиця %s — %d стовпців, %d рядків" % (a.table.upper(), width, len(body)))
    for h, (t, extra) in zip(header, types):
        print("   %-22s %s%s" % (h, t, "" if extra is None else " (%s)" % extra))

    out = [
        "SET DEFINE OFF",
        "SET FEEDBACK OFF",
        "BEGIN EXECUTE IMMEDIATE 'DROP TABLE %s PURGE'; "
        "EXCEPTION WHEN OTHERS THEN NULL; END;" % a.table.upper(),
        "/",
    ]
    cols = []
    for h, (t, extra) in zip(header, types):
        # CHAR, а не типові BYTE: кирилиця в UTF-8 займає 2-3 байти на символ,
        # і при байтовій семантиці рядки не влізають (ORA-12899).
        cols.append("  %-24s %s"
                    % (h, t if t != "VARCHAR2" else "VARCHAR2(%d CHAR)" % extra))
    out.append("CREATE TABLE %s (\n%s\n);" % (a.table.upper(), ",\n".join(cols)))

    for r in body:
        vals = []
        for i, raw in enumerate(r):
            v = raw.strip()
            t, extra = types[i]
            if v == "":
                vals.append("NULL")
            elif t == "NUMBER":
                vals.append(v)
            elif t == "DATE":
                vals.append("TO_DATE(%s,%s)" % (q(v), q(extra)))
            else:
                vals.append(q(v))
        out.append("INSERT INTO %s (%s) VALUES (%s);"
                   % (a.table.upper(), ",".join(header), ",".join(vals)))
    out += ["COMMIT;", "SET FEEDBACK ON",
            "SELECT COUNT(*) AS ROWS_LOADED FROM %s;" % a.table.upper(), "EXIT"]
    sql = "\n".join(out) + "\n"

    if a.dry_run:
        print("\n".join(out[:8]) + "\n...")
        return

    tmp = tempfile.NamedTemporaryFile("w", suffix=".sql", delete=False,
                                      encoding="utf-8", newline="\n")
    tmp.write(sql)
    tmp.close()
    remote = "/tmp/%s_load.sql" % a.table.lower()
    subprocess.run(["podman", "cp", tmp.name, "%s:%s" % (a.container, remote)], check=True)
    pwd = io.open(pwd_path, encoding="utf-8").read().strip()
    cmd = 'sqlplus -s %s/"%s"@%s @%s' % (a.user, pwd, a.pdb, remote)
    # Без NLS_LANG sqlplus читає SQL-файл у однобайтовому кодуванні, і кожен
    # байт кирилиці стає символом-заповнювачем U+FFFD. Дані псуються мовчки:
    # рядки вставляються, помилки немає, але в базі замість тексту сміття.
    res = subprocess.run(["podman", "exec", "-i",
                          "-e", "NLS_LANG=AMERICAN_AMERICA.AL32UTF8",
                          a.container, "bash", "-lc", cmd],
                         capture_output=True, text=True)
    os.unlink(tmp.name)
    output = (res.stdout + res.stderr).replace("\r", "")
    print(output.strip())
    if "ORA-" in output:
        sys.exit("завантаження завершилось помилкою Oracle")


if __name__ == "__main__":
    main()
