# TriTon
A ternary neural network for managing Wi-Fi on OpenWRT routers

Here's the English translation of your document:

**TriTon — Ternary Cascading Neural Network for WiFi Router Control**

**What is it?**
TriTon is a self-learning WiFi router control system that runs on MIPS architecture without an FPU (floating-point unit). It is written in pure Shell (Busybox/ash) and requires no external dependencies other than standard OpenWrt utilities.

Unlike cloud solutions (Cisco, Ubiquiti, TP-Link Omada), where the router sends data to a remote server for analysis, TriTon makes decisions directly on the router. This means:

- Instant reaction to changes in the air (no delays from cloud uploads)
- Works even without internet access
- No monthly fees for "cloud AI"
- Complete privacy — your data never leaves the device

**How it works:**
**Ternary logic instead of gradient descent.**
Classical neural networks use float calculations and gradient descent, requiring a powerful CPU and FPU. TriTon works differently — using three clear states:

| State | Value | RSSI | Retry ratio | Throughput |
|-------|-------|------|--------------|------------|
| -1 | Good | > -60 dBm | < 5% | > 50 Mbps |
| 0 | Medium | -60…-75 dBm | 5-15% | 20-50 Mbps |
| +1 | Bad | < -75 dBm | > 15% | < 20 Mbps |

This makes the system:
- **Fast** — only integer comparisons
- **Lightweight** — no math coprocessor required
- **Understandable** — every neuron can be traced in the code

**Cascading architecture**
The neural network makes decisions in two stages (cascades):

**Cascade 1: Channel selection**
- Scans the air using `iw dev wlan0 scan`
- Analyzes each neighbor: their channel, RSSI (strength), number of clients, channel utilization
- Computes a ternary score for each channel (-1/0/+1)
- Selects the channel with state -1 (clean)

**Cascade 2: Power tuning**
- Starts at minimum power (5 dBm)
- Waits 30 seconds for stabilization
- Measures client RSSI, retry ratio, and throughput
- If all three parameters are in the green zone (-1) — power is optimal
- If there are problems — increases power by 5 dBm
- Repeats until reaching 20 dBm

**Reinforcement learning**
The neural network doesn't just follow rules — it learns from experience:

- When quality degrades, the system increases power
- After 30 seconds, it checks: did it help or not?
- If it helped → increases the weight of the `power_increase=1` action
- If it didn't help → decreases the weight of `power_increase=-1`
- Weights are stored in `/tmp/weights.conf` and influence future decisions. The more successful power increases, the more readily the neural network will increase power in similar situations.

**Stigmergy — self-organization of multiple routers**

The most interesting part. In classical systems, routers communicate via a central controller or LAN. TriTon uses indirect coordination through changes in the air.

**Principle (like ants with pheromone trails):**

- Router A selects channel 6 and starts working
- Router B scans the air and sees: a new AP with strong signal has appeared on channel 6
- The score for channel 6 worsens (0 or +1)
- Router B selects another free channel (1 or 11)
- Router C scans and sees channels 6 and 1 are occupied → selects the remaining one

**Result:** routers automatically spread across non-overlapping channels without sending a single packet between them. This is emergence — global self-organization from simple local rules.

**Practical results:**
**Measured results (real tests)**

| Power | Avg Retry | Avg Throughput | RSSI (worst) | Verdict |
|-------|-----------|----------------|--------------|---------|
| 20 dBm | 11.7% | 38.0 Mbps | -51 | 🟡 Overkill, collisions |
| 15 dBm | 10.0% | 50.7 Mbps | -55 | 🟢 Good |
| 10 dBm | 8.5% | 53.3 Mbps | -55 | 🟢 OPTIMUM |
| 5 dBm | 8.9% | 35.4 Mbps | -52 | 🟡 Speed dropped |

The neural network found the optimal power at 10 dBm — the minimum that maintains high quality. This means:
- Neighboring routers don't suffer from excessive power
- Clients get a stable signal
- Retry ratio is minimal (8.5% — nearly ideal)
- Throughput is maximal (53 Mbps)

**How to use it**
**For a single router:** The system runs as a background daemon. Every 10 seconds it checks connection quality and adjusts power or channel if needed. Fully automatic, no user intervention required.

**For multiple routers (stigmergy):** Simply install TriTon on all routers in the coverage area. They will automatically spread across channels and adjust power to avoid interfering with each other. No central controller, no configuration needed.

**For developers:**
TriTon can be used as:
- An example of neuromorphic computing on constrained hardware
- A demonstration of cascading architecture with feedback loops
- An implementation of stigmergy in wireless networks

**Pros and cons**

**Pros:**
✅ Works on old routers (MIPS without FPU)
✅ Requires no internet or cloud
✅ No dependencies (only Busybox)
✅ Completely open source (modifiable)
✅ Self-learning based on feedback
✅ Stigmergy — routers coordinate without a center
✅ Energy efficient (CPU barely loaded)

**Cons:**
❌ No graphical interface (command line only)
❌ Requires OpenWrt (not suitable for stock firmware)
❌ Adapts to specific environments (threshold calibration may be needed)
❌ Not for beginners — basic router skills required

**What's inside (technical details)**

**Main functions:**

| Function | Purpose |
|----------|---------|
| `parse_scan()` | Parses iw scan, evaluates channels (-1/0/+1) |
| `get_best_channel()` | Selects the best channel from scan |
| `get_client_stats()` | Collects client RSSI, retry, throughput |
| `evaluate_state()` | Ternary state evaluation (-1/0/+1) |
| `log_action()` | Logging for learning |

**Files:**

| File | Contents |
|------|----------|
| `/tmp/neural_network.log` | Log of all actions (monitoring, increases, channel changes) |
| `/tmp/weights.conf` | Cascade weights (reinforcement learning) |
| `/tmp/station_dump.txt` | Cache of `iw station dump` output |
| `/tmp/scan_cache.txt` | Cache of air scan |

**Configuration**
All settings at the beginning of the script:

```shell
INTERFACE="phy0-ap0"        # Wi-Fi interface
MIN_POWER=5                 # Minimum power
MAX_POWER=20                # Maximum power
THRESHOLD_RETRY=15          # Retry threshold for "bad" rating
THRESHOLD_THROUGHPUT=20     # Throughput threshold for "bad" rating
THRESHOLD_RSSI=-75          # RSSI threshold for "bad" rating
IDLE_INTERVAL=10            # Check frequency (seconds)
SETTLE_TIME=30              # Stabilization time after changes
```

**Conclusion**
TriTon is more than just a script. It is:
- **Proof of concept** — neural networks can work without gradient descent and floats
- **Ready-to-use system** — works on real hardware, battle-tested
- **Research project** — combines ternary logic, cascading, reinforcement learning, and stigmergy
- **Contribution to the community** — OpenWrt gets a tool it didn't have before
- A neural network that runs on a $15 router, without cloud, without internet, without FPU. In Shell scripts. That is TriTon.

RU
TriTon — Тернарная каскадная нейросеть для управления WiFi-роутером  

Что это такое  
TriTon — это самообучающаяся система управления WiFi-роутером, которая работает на архитектуре MIPS без FPU (математического сопроцессора). Она написана на чистом Shell (Busybox/ash) и не требует никаких внешних зависимостей, кроме стандартных утилит OpenWrt.  
  
В отличие от облачных решений (Cisco, Ubiquiti, TP-Link Omada), где роутер отправляет данные на удалённый сервер для анализа, TriTon принимает решения прямо на роутере. Это означает:  
* Мгновенная реакция на изменение эфира (без задержек на отправку в облако)  
* Работа даже при отсутствии интернета  
* Никаких ежемесячных платежей за «облачный AI»  
* Полная приватность — ваши данные никуда не уходят  

Как это работает:  
Тернарная логика вместо градиентного спуска.  
Классические нейросети используют float-вычисления и градиентный спуск, что требует мощного процессора и FPU. TriTon работает иначе — три чётких состояния:  

Состояние ______ Значение ______ RSSI _______ Retry ratio ___	Throughput  
-1 _____________ Хорошо ______ > -60 dBm ______ < 5% _________ > 50 Mbps  
0 ______________ Средне______  -60…-75 dBm ____ 5-15% ________ 20-50 Mbps  
+1 _____________ Плохо _______ < -75 dBm ______ > 15% ________ < 20 Mbps  

Это делает систему:  
Быстрой — только целочисленные сравнения  
Лёгкой — не требует математического сопроцессора  
Понятной — каждый нейрон можно отследить в коде  

Каскадная архитектура  
Нейросеть принимает решение в два этапа (каскада):  

Каскад 1: Выбор канала  
Сканирует эфир через iw dev wlan0 scan  
Анализирует каждого соседа: его канал, RSSI (громкость), количество клиентов, загруженность канала  
Вычисляет тернарную оценку для каждого канала (-1/0/+1)  
Выбирает канал с состоянием -1 (чистый)  

Каскад 2: Подбор мощности  
Начинает с минимальной мощности (5 dBm)  
Ждёт 30 секунд стабилизации  
Измеряет RSSI, retry ratio и throughput клиентов  
Если все три параметра в зелёной зоне (-1) — мощность оптимальна  
Если есть проблемы — повышает мощность на 5 dBm  
Повторяет до достижения 20 dBm  

Обучение через подкрепление
Нейросеть не просто действует по правилам — она обучается на своём опыте:  

1. При ухудшении качества система повышает мощность  
2. Через 30 секунд проверяет: помогло или нет?  
3. Если помогло → увеличивает вес действия power_increase=1  
4. Если не помогло → уменьшает вес power_increase=-1  

Веса хранятся в /tmp/weights.conf и учитываются при следующих решениях. Чем больше успешных повышений мощности, тем охотнее нейросеть будет повышать мощность в похожих ситуациях.  

Стигмергия — самоорганизация нескольких роутеров:  

Самое интересное. В классических системах роутеры общаются через центральный контроллер или LAN. TriTon использует косвенную координацию через изменения в эфире.  

Принцип (как у муравьёв с феромонными следами):  
  
Роутер А выбирает канал 6 и начинает работать  
Роутер Б сканирует эфир и видит: на канале 6 появилась новая AP с сильным сигналом  
Оценка канала 6 ухудшается (0 или +1)  
Роутер Б выбирает другой свободный канал (1 или 11)  
Роутер В сканирует и видит занятость каналов 6 и 1 → выбирает оставшийся  
  
Результат: роутеры автоматически разъезжаются по непересекающимся каналам без единого отправленного пакета между ними. Это и есть эмерджентность — глобальная самоорганизация из простых локальных правил.  

Что получается на практике:  
Измеренные результаты (реальные тесты)  
  

Мощность ______ Средний retry ______ Средний throughput ___ RSSI (худший) ___ Вердикт  
20 dBm _________ 11.7% _______________ 38.0 Mbps ________________ -51 __________________ 🟡 Перебор, коллизии  
15 dBm _________ 10.0%________________ 50.7 Mbps ________________ -55 __________________ 🟢 Хорошо  
10 dBm _________ 8.5% ________________ 53.3 Mbps ________________ -55 __________________ 🟢 ОПТИМУМ  
5 dBm __________ 8.9% ________________ 35.4 Mbps ________________ -52 __________________ 🟡 Скорость упала  
  
Нейросеть нашла оптимальную мощность 10 dBm — минимальную, при которой качество остаётся высоким. Это значит:  
Соседние роутеры не страдают от избыточной мощности  
Клиенты получают стабильный сигнал  
Retry ratio минимален (8.5% — почти идеально)  
Throughput максимален (53 Mbps)  

Как это используют
Для роутера
Система работает как фоновый демон. Раз в 10 секунд проверяет качество связи, при необходимости подстраивает мощность или канал. Всё автоматически, без участия пользователя.

Для нескольких роутеров (стигмергия)
Достаточно установить TriTon на все роутеры в зоне покрытия. Они сами разъедутся по каналам и подстроят мощность, чтобы не мешать друг другу. Никакого центрального контроллера, никакой настройки.

Для разработчиков  
TriTon можно использовать как:  
Образец нейроморфных вычислений на ограниченном железе  
Пример каскадной архитектуры с обратными связями  
Реализацию стигмергии в беспроводных сетях  

Плюсы и минусы  
Плюсы:  
✅ Работает на старых роутерах (MIPS без FPU)  
✅ Не требует интернета или облака  
✅ Никаких зависимостей (только Busybox)  
✅ Полностью открытый код (можно модифицировать)  
✅ Самообучается на основе обратной связи  
✅ Стигмергия — роутеры координируются без центра  
✅ Энергоэффективно (процессор почти не грузится)  
  
Минусы  
❌ Не имеет графического интерфейса (только командная строка)  
❌ Требует OpenWrt (не подходит для stock-прошивок)  
❌ Адаптируется под конкретную среду (может потребоваться калибровка порогов)  
❌ Не для новичков — нужны базовые навыки работы с роутером  
  
Что внутри (технические детали)  
Основные функции:  
Функция______________________Назначение  
parse_scan()_________________Парсинг iw scan, оценка каналов (-1/0/+1)  
get_best_channel()___________Выбор лучшего канала по сканированию  
get_client_stats()___________Сбор RSSI, retry, throughput клиентов  
evaluate_state()_____________Тернарная оценка состояния (-1/0/+1)  
log_action()_________________Логирование для обучения  
  
Файлы:  
Файл _____________________________	Содержимое  
/tmp/neural_network.log __________	Лог всех действий (мониторинг, повышения, смены)  
/tmp/weights.conf	________________  Веса каскадов (обучение через подкрепление)  
/tmp/station_dump.txt ____________	Кэш вывода iw station dump  
/tmp/scan_cache.txt ______________	Кэш сканирования эфира  
  
Конфигурация  
Все настройки в начале скрипта:  

INTERFACE="phy0-ap0"        # Wi-Fi интерфейс  
MIN_POWER=5                 # Минимальная мощность  
MAX_POWER=20                # Максимальная мощность  
THRESHOLD_RETRY=15          # Порог retry для оценки "плохо"  
THRESHOLD_THROUGHPUT=20     # Порог throughput для оценки "плохо"  
THRESHOLD_RSSI=-75          # Порог RSSI для оценки "плохо"  
IDLE_INTERVAL=10            # Частота проверки (сек)  
SETTLE_TIME=30              # Время стабилизации после изменений  

Заключение  
TriTon — это не просто скрипт. Это:  
Доказательство концепции — нейросеть может работать без градиентного спуска и float  
Готовая система — работает на реальном железе, протестирована в бою  
Исследовательский проект — сочетает тернарную логику, каскадность, обучение через подкрепление и стигмергию  
Вклад в сообщество — OpenWrt получает инструмент, которого там не было  
Нейросеть, которая работает на роутере за 1500 рублей, без облака, без интернета, без FPU. На Shell-скриптах. Это и есть TriTon.

