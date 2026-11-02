# Повне розгортання середовища для лабораторних

Курс спирається на три різні середовища. Нижче — що саме ставити, в якому
порядку, і де воно ламається. Частина кроків автоматизована скриптами з цієї
папки, частина робиться руками — це чесно позначено.

## Які лабораторні якому середовищу відповідають

| Трек | Середовище | Лабораторні |
|---|---|---|
| Oracle | Oracle Database Free у podman | Data Miner, Oracle ML (класифікація, дерева рішень), Association Rules, Time Series ESM, Oracle Graph |
| Python | venv зі scikit-learn та ін. | стекінг і SHAP, нейромережі, LSTM, аналіз сентименту, виявлення аномалій, асоціативні правила в Python |
| Big Data | Hadoop + Spark + Hive + Flume | робота з HDFS, потокове завантаження, таблиці ORC |

Треки незалежні. Якщо потрібні лише лаби з Oracle ML — досить кроків 0–2.

---

## Крок 0. Windows: WSL2

У PowerShell від адміністратора:

```powershell
wsl --install -d Ubuntu
```

Після перезавантаження Ubuntu запуститься сама і попросить придумати
користувача й пароль.

**Обовʼязково налаштуйте памʼять.** Типово WSL2 забирає половину RAM хоста,
і цього не вистачає. Створіть файл `C:\Users\<Ім'я>\.wslconfig`:

```ini
[wsl2]
memory=10GB
processors=8
swap=4GB
```

Застосувати: `wsl --shutdown` у PowerShell, потім відкрити Ubuntu знову.

Перевірити всередині Ubuntu:

```bash
free -g        # рядок Mem, стовпець total
nproc
df -h ~        # має бути щонайменше 20 ГБ вільних
```

Орієнтир: **10 ГБ памʼяті WSL і 20 ГБ диска** покривають усі три треки, якщо
не запускати Oracle і Hadoop одночасно (див. розділ про граблі).

---

## Крок 1. Базові пакети Ubuntu

```bash
sudo apt-get update
sudo apt-get install -y curl wget unzip net-tools python3 python3-venv python3-pip
```

---

## Крок 2. Oracle Database Free (автоматично)

Це єдиний трек, який у методичках вимагає Oracle Cloud і платіжної картки.
Скрипт піднімає ту саму базу локально.

```bash
sudo apt-get install -y podman
chmod +x setup.sh smoke_test.sh
./setup.sh
./smoke_test.sh
```

`setup.sh` сам перевіряє передумови, тягне образ (~10 ГБ, один раз), створює
контейнер, дочікується готовності **реальним SQL-запитом**, створює схему
`omluser` з правом `CREATE MINING MODEL` і перевіряє, що пакет
`DBMS_DATA_MINING` доступний. Від запуску до готової схеми — близько хвилини,
якщо образ уже завантажено.

`smoke_test.sh` будує тестову модель `EXSM_WINTERS` і друкує прогноз. Пройшов —
трек готовий.

Завантаження датасету (APEX у Free-контейнері немає, тому через скрипт):

```bash
python3 load_csv.py pdfo02.csv PDFO02
```

Підключення:

```bash
podman exec -it oradb sqlplus omluser/"$(cat ~/.oml-local/omluser)"@FREEPDB1
```

---

## Крок 3. Python-середовища (автоматично)

```bash
chmod +x setup_python.sh
./setup_python.sh            # базовий ML: ~400 МБ
./setup_python.sh --deep     # додає TensorFlow і PyTorch: ще ~3 ГБ
```

Створюються два окремі оточення, і це навмисно:

- **`~/mlenv`** — основне: numpy, pandas, scikit-learn, scipy, matplotlib,
  seaborn, statsmodels, xgboost, lightgbm, shap, jupyterlab;
- **`~/arenv`** — тільки під асоціативні правила: mlxtend і openpyxl.

Розділення потрібне тому, що mlxtend тягне власні обмеження на версії pandas
і в спільному оточенні конфліктує з рештою.

Запуск ноутбуків:

```bash
~/mlenv/bin/jupyter-lab --no-browser
```

Посилання з токеном зʼявиться у виводі — відкрити у браузері Windows.

---

## Крок 4. Hadoop, Spark, Hive, Flume (руками)

**Цей крок не автоматизовано.** Нижче — точна конфігурація, яка працює;
її треба повторити вручну.

### 4.1. Java

```bash
sudo apt-get install -y openjdk-17-jdk-headless openssh-server
```

Hadoop 3.4 офіційно підтримує Java 17. Java 21 теж ставиться, але вузли
подекуди лаються — лишайте `JAVA_HOME` на 17.

### 4.2. Розпакування

```bash
mkdir -p ~/opt && cd ~/opt
wget https://dlcdn.apache.org/hadoop/common/hadoop-3.4.3/hadoop-3.4.3.tar.gz
wget https://dlcdn.apache.org/spark/spark-3.5.9/spark-3.5.9-bin-hadoop3.tgz
wget https://dlcdn.apache.org/hive/hive-4.2.1/apache-hive-4.2.1-bin.tar.gz
wget https://dlcdn.apache.org/flume/1.11.0/apache-flume-1.11.0-bin.tar.gz
for f in *.tar.gz *.tgz; do tar xf "$f"; done
ln -sfn hadoop-3.4.3 hadoop
ln -sfn spark-3.5.9-bin-hadoop3 spark
ln -sfn apache-hive-4.2.1-bin hive
ln -sfn apache-flume-1.11.0-bin flume
```

Символьні посилання дають змогу оновити версію, не переписуючи конфіги.

### 4.3. Змінні оточення

Файл `~/.hadoop_env`:

```bash
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
export HADOOP_HOME=$HOME/opt/hadoop
export SPARK_HOME=$HOME/opt/spark
export HADOOP_CONF_DIR=$HADOOP_HOME/etc/hadoop
export HADOOP_MAPRED_HOME=$HADOOP_HOME
export HADOOP_COMMON_HOME=$HADOOP_HOME
export HADOOP_HDFS_HOME=$HADOOP_HOME
export YARN_HOME=$HADOOP_HOME
export PATH=$PATH:$HADOOP_HOME/bin:$HADOOP_HOME/sbin:$SPARK_HOME/bin
export HIVE_HOME=$HOME/opt/hive
export FLUME_HOME=$HOME/opt/flume
export PATH=$PATH:$HIVE_HOME/bin:$FLUME_HOME/bin
```

Підключати перед роботою: `source ~/.hadoop_env`

### 4.4. Конфігурація Hadoop

`$HADOOP_HOME/etc/hadoop/core-site.xml`:

| Властивість | Значення |
|---|---|
| `fs.defaultFS` | `hdfs://localhost:9000` |
| `hadoop.tmp.dir` | `$HOME/hadoop-data/tmp` |

`hdfs-site.xml`:

| Властивість | Значення |
|---|---|
| `dfs.replication` | `1` |
| `dfs.namenode.name.dir` | `file:///$HOME/hadoop-data/nn` |
| `dfs.datanode.data.dir` | `file:///$HOME/hadoop-data/dn` |

`mapred-site.xml`:

| Властивість | Значення |
|---|---|
| `mapreduce.framework.name` | `yarn` |
| `yarn.app.mapreduce.am.env` | `HADOOP_MAPRED_HOME=$HOME/opt/hadoop` |

`yarn-site.xml`:

| Властивість | Значення |
|---|---|
| `yarn.nodemanager.aux-services` | `mapreduce_shuffle` |
| `yarn.nodemanager.resource.memory-mb` | `8192` |
| `yarn.nodemanager.resource.cpu-vcores` | `6` |
| `yarn.scheduler.maximum-allocation-mb` | `4096` |
| `yarn.nodemanager.vmem-check-enabled` | `false` |
| `yarn.resourcemanager.hostname` | `localhost` |
| `yarn.resourcemanager.address` | `localhost:8032` |
| `yarn.resourcemanager.scheduler.address` | `localhost:8030` |
| `yarn.resourcemanager.resource-tracker.address` | `localhost:8031` |

`vmem-check-enabled=false` — обовʼязково: WSL рахує віртуальну памʼять інакше,
і без цього YARN вбиває контейнери одразу після старту.

### 4.5. Перший запуск

```bash
source ~/.hadoop_env
ssh-keygen -t rsa -P '' -f ~/.ssh/id_rsa          # якщо ключа ще немає
cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys
sudo service ssh start
hdfs namenode -format                             # один раз, стирає HDFS
start-dfs.sh && start-yarn.sh
jps                                               # мають бути NameNode, DataNode, ResourceManager, NodeManager
```

Вебінтерфейси: HDFS на `http://localhost:9870`, YARN на `http://localhost:8088`.

### 4.6. Hive

`$HIVE_HOME/conf/hive-site.xml`:

| Властивість | Значення |
|---|---|
| `javax.jdo.option.ConnectionURL` | `jdbc:derby:;databaseName=$HOME/hive-meta/metastore_db;create=true` |
| `hive.metastore.warehouse.dir` | `/user/hive/warehouse` |
| `hive.execution.engine` | `mr` |
| `hive.server2.enable.doAs` | `false` |
| `hive.metastore.schema.verification` | `false` |
| `datanucleus.schema.autoCreateAll` | `true` |
| `mapreduce.framework.name` | `local` |
| `hive.exec.mode.local.auto` | `true` |

Derby як метастор обрано свідомо: не потребує окремого сервера БД. Обмеження —
до метастора може підключитись лише один процес за раз.

Ініціалізація:

```bash
schematool -dbType derby -initSchema
```

### 4.7. Flume

У `$FLUME_HOME/conf/flume-env.sh`:

```bash
export JAVA_OPTS="-Xms256m -Xmx512m"
```

Без обмеження купи Flume на машині з 10 ГБ з'їдає памʼять, потрібну YARN.

Відома несумісність: Flume 1.11 несе `guava-11.0.2.jar`, який конфліктує з
Hadoop 3.4. Приберіть стару бібліотеку з `$FLUME_HOME/lib` і підкладіть ту,
що йде з Hadoop:

```bash
mkdir -p $FLUME_HOME/lib-disabled
mv $FLUME_HOME/lib/guava-11.0.2.jar $FLUME_HOME/lib-disabled/
cp $HADOOP_HOME/share/hadoop/common/lib/guava-*.jar $FLUME_HOME/lib/
```

### 4.8. Kerberos (лише для лаб із захищеним режимом)

```bash
sudo apt-get install -y krb5-kdc krb5-admin-server krb5-user
```

Під час встановлення спитає область (realm) — вводиться великими літерами.
Далі створюються принципали і keytab (`~/hadoop.keytab`), які підключаються
у `core-site.xml` та `hdfs-site.xml`. Якщо лаба не вимагає захищеного режиму,
цей крок можна пропустити повністю.

---

## Крок 5. Допоміжні інструменти

Потрібні не для обчислень, а для оформлення робіт.

```bash
# конвертація звітів у PDF
sudo apt-get install -y libreoffice-writer fonts-liberation

# читання методичок у PDF, таблиць Excel
sudo apt-get install -y poppler-utils python3-pypdf python3-xlrd

# UML-моделі у форматі XMI без графічного середовища
sudo apt-get install -y umbrello xvfb imagemagick x11-utils openbox
```

Umbrello запускається на віртуальному X-сервері:

```bash
xvfb-run -a umbrello5 --export xmi --directory ~/out model.xmi
```

---

## Нюанси і граблі

### Памʼять: Oracle і Hadoop не живуть разом

На 10 ГБ у WSL одночасно вони не вміщаються. Перед запуском Oracle:

```bash
source ~/.hadoop_env && stop-yarn.sh && stop-dfs.sh
```

Перед запуском Hadoop:

```bash
podman stop oradb
```

`setup.sh` це перевіряє і зупиняється сам, якщо бачить запущений NameNode.

### `podman ps` показує `(starting)` на працюючій базі

Вбудована healthcheck образу може висіти в цьому стані годинами. Статус
контейнера — ненадійний сигнал.

### Рядок `DATABASE IS READY TO USE` у логах бреше

`podman logs` зберігає вивід усіх попередніх запусків. Якщо шукати цей рядок
через `grep`, він знайдеться від минулого разу, коли база ще не піднялась.
Єдина надійна перевірка готовності — виконати SQL-запит. Саме так робить
`setup.sh`.

### `podman ps` показує `Exited (0) 292 years ago`

Наслідок зсуву годинника WSL після сплячки ноутбука. На роботу не впливає.

### `$` зникає у вкладених лапках

Конструкція виду

```bash
podman exec -i oradb bash -c "sqlplus ... <<EOF
SELECT banner FROM v\$version;
EOF"
```

мовчки підставляє порожній рядок замість `$version`, і запит падає з
незрозумілою помилкою. Пишіть SQL у файл і передавайте через `podman cp`.

### Дефіс у кінці рядка в SQL*Plus

У SQL*Plus `-` в кінці рядка означає продовження команди на наступний рядок.
Тому `PROMPT --- Розділ ---` склеїться з наступною командою. Використовуйте
інші символи: `PROMPT === Розділ ===`.

### `ORA-01017: invalid username/password`

Пароль `SYSTEM` задається один раз, при створенні контейнера, через змінну
`ORACLE_PWD`. Змінити його ззовні неможливо. Якщо файл із паролем загублено —
лише перестворення:

```bash
./setup.sh --recreate     # видаляє контейнер разом з усіма даними
```

### `ORA-01031: insufficient privileges` при побудові моделі

Схемі бракує права `CREATE MINING MODEL`. Його не дає ні `CONNECT`, ні
`RESOURCE` — видавати треба окремо.

### Кирилиця мовчки перетворюється на сміття

Найпідступніша з усіх. Якщо виконувати SQL-файл через `podman exec` без
змінної `NLS_LANG`, `sqlplus` читає файл як однобайтовий і кожен байт
кирилиці перетворює на символ-заповнювач U+FFFD. **Помилки немає**, рядки
вставляються, `COMMIT` проходить — але в базі замість тексту сміття.
Виявляється лише при читанні.

Перевірити, чи постраждали дані:

```sql
SELECT LENGTH(col), LENGTHB(col), DUMP(col, 1016, 1, 14) FROM tab WHERE ROWNUM = 1;
```

Якщо в дампі повторюється `ef,bf,bd` — текст зіпсовано, таблицю треба
перезалити. Здорова кирилиця в дампі виглядає як пари `d0,xx` / `d1,xx`.

Правильний виклик:

```bash
podman exec -i -e NLS_LANG=AMERICAN_AMERICA.AL32UTF8 oradb \
  bash -lc 'sqlplus -s omluser/"PWD"@FREEPDB1 @/tmp/my.sql'
```

`load_csv.py` робить це сам. Та сама змінна потрібна й для читання, інакше
текст виводиться як `???` — але це вже лише відображення, дані цілі.

### Текстові стовпці не вміщають кирилицю

Oracle типово міряє `VARCHAR2(n)` у **байтах**, а символ кирилиці в UTF-8
займає два. Через це `VARCHAR2(32)` не приймає навіть 20 символів і падає з
`ORA-12899: value too large for column`. Оголошуйте з явною семантикою:
`VARCHAR2(32 CHAR)`. `load_csv.py` так і робить.

### Кириличні назви стовпців

Oracle не приймає їх як ідентифікатори без лапок, а просте викидання
не-латинських символів перетворює `Имя`, `Сумма` і `Дата` на однакові
підкреслення, після чого база падає з `ORA-00957: duplicate column name`.
`load_csv.py` транслітерує назви (`Имя` → `YMIA`, `Сумма` → `SUMMA`) і
додає числовий суфікс, якщо після транслітерації виникла колізія.

### У Free-контейнері немає APEX

Методички пропонують заливати CSV через вебінтерфейс APEX, якого в образі
немає. Використовуйте `load_csv.py`.

### YARN вбиває контейнери одразу після старту

Майже завжди це `yarn.nodemanager.vmem-check-enabled`, якому не поставили
`false`. WSL рахує віртуальну памʼять інакше, ніж звичайний Linux.

---

## Порядок роботи після встановлення

```bash
# Oracle-лаби
podman start oradb && ./smoke_test.sh

# Python-лаби
~/mlenv/bin/jupyter-lab --no-browser

# Big Data лаби (спочатку зупинити Oracle)
podman stop oradb
source ~/.hadoop_env && start-dfs.sh && start-yarn.sh && jps
```
