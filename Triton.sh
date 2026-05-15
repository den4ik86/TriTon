#!/bin/sh

# ============================================================
# ТЕРНАРНАЯ КАСКАДНАЯ НЕЙРОСЕТЬ ДЛЯ УПРАВЛЕНИЯ WIFI-РОУТЕРОМ
# ============================================================
# 
# Архитектура:
#   - Входы: RSSI, Retry ratio, Throughput (тернарные: -1/0/+1)
#   - Каскад 1: выбор канала по сканированию эфира
#   - Каскад 2: подбор оптимальной мощности (5→20 dBm)
#   - Обучение: через обратную связь (логирование успешных действий)
#   - Стигмергия: косвенная координация через изменения эфира
#
# Автор: самостоятельная разработка
# Платформа: MIPS 24KEc (MT7628), OpenWrt, Busybox
# ============================================================

# ----------------------- КОНФИГУРАЦИЯ -----------------------

INTERFACE="phy0-ap0"                    # Wi-Fi интерфейс
MIN_POWER=5                          # Минимальная мощность (dBm)
MAX_POWER=20                         # Максимальная мощность (dBm)
POWER_STEP=5                         # Шаг изменения мощности (dBm)

# Пороги для тернарной логики (-1/0/+1)
THRESHOLD_RETRY=15                   # Retry ratio > 15% → плохо (+1)
THRESHOLD_THROUGHPUT=20              # Throughput < 20 Mbps → плохо (+1)
THRESHOLD_RSSI=-75                   # RSSI < -75 dBm → плохо (+1)

# Интервалы проверки
IDLE_INTERVAL=10                     # Проверка каждые 10 секунд
SETTLE_TIME=30                       # Время стабилизации после смены канала/мощности

# Файлы для логирования и кэширования
SCAN_CACHE="/tmp/scan_cache.txt"     # Кэш сканирования эфира
CHANNEL_STATS="/tmp/channel_stats.tmp"  # Статистика по каналам
NEURAL_LOG="/tmp/neural_network.log"    # Лог действий нейросети
WEIGHTS_FILE="/tmp/weights.conf"     # Тернарные веса каскадов

# ----------------------- ИНИЦИАЛИЗАЦИЯ -----------------------

# Создаём лог с заголовком
echo "=== NEURAL NETWORK LOG ===" > $NEURAL_LOG
echo "Start time: $(date)" >> $NEURAL_LOG

# Инициализация весов (тернарные: -1, 0, +1)
# Каждый каскад имеет вес, который корректируется через обратную связь
cat > $WEIGHTS_FILE << EOF
# Формат: компонент = вес
# Вес -1: подавляет действие
# Вес 0:  не влияет
# Вес +1: способствует действию
cascade_rssi=1
cascade_retry=1
cascade_throughput=1
cascade_channel=1
power_increase=0
power_decrease=0
channel_switch=0
EOF

# ----------------------- ФУНКЦИИ -----------------------

# Функция 1: Парсинг сканирования эфира с учётом RSSI соседей
# Возвращает: для каждого канала (1-13) три состояния и статистику
parse_scan() {
    local scan_file="$1"
    local stats_file="$2"
    
    awk '
    BEGIN {
        RS="BSS ";
        FS="\n";
        # Пороги RSSI для тернарного веса соседа
        RSSI_GOOD = -60;   # > -60 → сильный сигнал (мешает, вес +1)
        RSSI_BAD  = -75;   # < -75 → слабый сигнал (почти не мешает, вес -1)
    }
    {
        if (NR==1) next;
        
        # --- ИНИЦИАЛИЗАЦИЯ ДЛЯ ТЕКУЩЕГО BSS ---
        channel = 0;
        station_count = 0;
        utilisation = 0;
        rssi = 0;
        rssi_weight = 0;
        ht40_offset = "";
        
        # --- ПАРСИМ СТРОКИ БЛОКА ---
        for(i=1; i<=NF; i++) {
            line = $i;
            
            # Канал (primary channel)
            if (match(line, /primary channel: ([0-9]+)/, arr)) {
                channel = arr[1];
            }
            
            # Количество клиентов у соседа
            if (match(line, /station count: ([0-9]+)/, arr)) {
                station_count = arr[1];
            }
            
            # Загруженность канала (0-255, чем выше, тем грязнее)
            if (match(line, /channel utilisation: ([0-9]+)/, arr)) {
                utilisation = arr[1];
            }
            
            # RSSI соседней AP (громкость)
            if (match(line, /signal: ([+-]?[0-9.]+) dBm/, arr)) {
                rssi = arr[1] + 0;
                # Тернарный вес по громкости
                if (rssi > RSSI_GOOD) {
                    rssi_weight = 1;    # Громкий сосед → сильно мешает
                } else if (rssi < RSSI_BAD) {
                    rssi_weight = -1;   # Тихий сосед → почти не мешает
                } else {
                    rssi_weight = 0;    # Средний
                }
            }
            
            # HT40 (захват соседнего канала)
            if (match(line, /secondary channel offset: (above|below)/, arr)) {
                ht40_offset = arr[1];
            }
        }
        
        # --- НАКОПЛЕНИЕ СТАТИСТИКИ ПО КАНАЛУ ---
        if (channel >= 1 && channel <= 13) {
            # Суммируем
            bss_count[channel]++;
            clients_total[channel] += station_count;
            util_sum[channel] += utilisation;
            rssi_sum[channel] += rssi_weight;
            
            # Влияние HT40 на соседний канал (занимает два канала)
            if (ht40_offset == "above") {
                neighbor = channel + 4;
                if (neighbor <= 13) {
                    bss_count[neighbor] += 0.5;
                    clients_total[neighbor] += station_count / 2;
                    util_sum[neighbor] += utilisation / 2;
                    rssi_sum[neighbor] += rssi_weight / 2;
                }
            }
            if (ht40_offset == "below") {
                neighbor = channel - 4;
                if (neighbor >= 1) {
                    bss_count[neighbor] += 0.5;
                    clients_total[neighbor] += station_count / 2;
                    util_sum[neighbor] += utilisation / 2;
                    rssi_sum[neighbor] += rssi_weight / 2;
                }
            }
        }
    }
    END {
        # --- ВЫЧИСЛЕНИЕ ТЕРНАРНОЙ ОЦЕНКИ ДЛЯ КАЖДОГО КАНАЛА ---
        for(c=1; c<=13; c++) {
            # Округление до целых
            bss_int = int(bss_count[c] + 0.5);
            clients = int(clients_total[c] + 0.5);
            util = int(util_sum[c] / 4);        # /255 → /4 для диапазона 0-63
            rssi_weight_total = int(rssi_sum[c] + 0.5);
            
            # Тернарная оценка: начинаем с -1 (чистый)
            state = -1;
            if (bss_int >= 3 || clients >= 5 || util >= 30 || rssi_weight_total >= 2) {
                state = 0;   # Средний
            }
            if (bss_int >= 5 || clients >= 10 || util >= 60 || rssi_weight_total >= 4) {
                state = 1;   # Грязный
            }
            
            # Вывод в формате для source
            printf("ch%d=%d\n", c, state);
            printf("ch%d_bss=%d\n", c, bss_int);
            printf("ch%d_clients=%d\n", c, clients);
            printf("ch%d_util=%d\n", c, util);
            printf("ch%d_rssi_weight=%d\n", c, rssi_weight_total);
        }
    }
    ' "$scan_file" > "$stats_file"
}

# Функция 2: Получение лучшего канала по сканированию
get_best_channel() {
    local best=""
    local best_state=99
    
    # Свежее сканирование
    iw dev $INTERFACE scan > $SCAN_CACHE
    parse_scan $SCAN_CACHE $CHANNEL_STATS
    
    # Загружаем переменные
    . $CHANNEL_STATS
    
    # Ищем канал с состоянием -1 (чистый), с наименьшим количеством AP
    for ch in 1 2 3 4 5 6 7 8 9 10 11; do
        eval "state=\$ch$ch"
        eval "bss=\$ch${ch}_bss"
        
        if [ "$state" = "-1" ]; then
            if [ -z "$best" ] || [ "$bss" -lt "$best_bss" ]; then
                best=$ch
                best_bss=$bss
                best_state=$state
            fi
        fi
    done
    
    # Если чистых каналов нет, берём канал с состоянием 0 (средний)
    if [ -z "$best" ]; then
        for ch in 1 2 3 4 5 6 7 8 9 10 11; do
            eval "state=\$ch$ch"
            if [ "$state" = "0" ]; then
                best=$ch
                break
            fi
        done
    fi
    
    # Если всё плохо, возвращаем 6 (канал по умолчанию)
    echo "${best:-6}"
}
# Функция 3: Сбор статистики клиентов через station dump
# Возвращает: max_retry_ratio, min_throughput, min_rssi_avg

get_client_stats() {
    local max_retry=0
    local min_throughput=999
    local min_rssi=999
    
    local dump_file="/tmp/station_dump.txt"
    iw dev $INTERFACE station dump > $dump_file
    
    local client_data=""
    
    while IFS= read -r line; do
        if echo "$line" | grep -q "^Station"; then
            if [ -n "$client_data" ]; then
                local retries=$(echo "$client_data" | grep "tx retries:" | awk '{print $3}')
                local packets=$(echo "$client_data" | grep "tx packets:" | awk '{print $3}')
                local throughput=$(echo "$client_data" | grep "expected throughput:" | sed 's/[^0-9.]//g')
                local rssi=$(echo "$client_data" | grep "signal avg:" | awk '{print $3}')
                
                if [ -n "$packets" ] && [ "$packets" -gt 0 ] 2>/dev/null; then
                    local ratio=$((retries * 100 / packets))
                    if [ "$ratio" -gt "$max_retry" ]; then
                        max_retry=$ratio
                    fi
                fi
                
                if [ -n "$throughput" ]; then
                    thr_int=$(echo "$throughput" | cut -d. -f1)
                    if [ "$thr_int" -gt 0 ] 2>/dev/null; then
                        if [ "$thr_int" -lt "$min_throughput" ]; then
                            min_throughput=$thr_int
                        fi
                    fi
                fi
                
                if [ -n "$rssi" ] && [ "$rssi" -ne 0 ] 2>/dev/null; then
                    if [ "$rssi" -lt "$min_rssi" ]; then
                        min_rssi=$rssi
                    fi
                fi
            fi
            client_data="$line"
        else
            client_data="$client_data"$'\n'"$line"
        fi
    done < "$dump_file"
    
    if [ -n "$client_data" ]; then
        local retries=$(echo "$client_data" | grep "tx retries:" | awk '{print $3}')
        local packets=$(echo "$client_data" | grep "tx packets:" | awk '{print $3}')
        local throughput=$(echo "$client_data" | grep "expected throughput:" | sed 's/[^0-9.]//g')
        local rssi=$(echo "$client_data" | grep "signal avg:" | awk '{print $3}')
        
        if [ -n "$packets" ] && [ "$packets" -gt 0 ] 2>/dev/null; then
            local ratio=$((retries * 100 / packets))
            if [ "$ratio" -gt "$max_retry" ]; then
                max_retry=$ratio
            fi
        fi
        
        if [ -n "$throughput" ]; then
            thr_int=$(echo "$throughput" | cut -d. -f1)
            if [ "$thr_int" -gt 0 ] 2>/dev/null; then
                if [ "$thr_int" -lt "$min_throughput" ]; then
                    min_throughput=$thr_int
                fi
            fi
        fi
        
        if [ -n "$rssi" ] && [ "$rssi" -ne 0 ] 2>/dev/null; then
            if [ "$rssi" -lt "$min_rssi" ]; then
                min_rssi=$rssi
            fi
        fi
    fi
    
    rm -f "$dump_file"
    
    # Возвращаем три числа (без лишнего вывода)
    echo "$max_retry $min_throughput $min_rssi"
}
# Функция 4: Тернарная оценка состояния клиентов
# Вход: retry_ratio, throughput, rssi
# Выход: -1 (хорошо), 0 (средне), +1 (плохо)
evaluate_state() {
    local retry=$1
    local throughput=$2
    local rssi=$3
    local score=0
    
    # Оценка retry
    if [ $retry -lt 5 ]; then
        score=$((score - 1))
    elif [ $retry -gt 15 ]; then
        score=$((score + 1))
    fi
    
    # Оценка throughput
    if [ $throughput -gt 50 ]; then
        score=$((score - 1))
    elif [ $throughput -lt 20 ]; then
        score=$((score + 1))
    fi
    
    # Оценка RSSI
    if [ $rssi -gt -60 ]; then
        score=$((score - 1))
    elif [ $rssi -lt -75 ]; then
        score=$((score + 1))
    fi
    
    # Тернарный выход
    if [ $score -lt 0 ]; then
        echo "-1"   # Хорошо
    elif [ $score -gt 0 ]; then
        echo "1"    # Плохо
    else
        echo "0"    # Средне (требуется следующий каскад)
    fi
}

# Функция 5: Логирование действия нейросети
log_action() {
    local action="$1"
    local power="$2"
    local channel="$3"
    local retry="$4"
    local throughput="$5"
    
    echo "$(date '+%Y-%m-%d %H:%M:%S') | $action | power=${power}dBm | ch=${channel} | retry=${retry}% | thr=${throughput}Mbps" >> $NEURAL_LOG
}

# ----------------------- ОСНОВНОЙ АЛГОРИТМ -----------------------

# Этап 1: Выбор канала
echo "=== КАСКАД 1: СКАНИРОВАНИЕ ЭФИРА И ВЫБОР КАНАЛА ==="
BEST_CHANNEL=$(get_best_channel)
uci set wireless.radio0.channel="$BEST_CHANNEL"
uci commit wireless
wifi reload
log_action "INITIAL_CHANNEL" "5" "$BEST_CHANNEL" "0" "0"
echo "Выбран канал: $BEST_CHANNEL"

# Этап 2-3: Подбор мощности (от 5 до 20 dBm)
echo "=== КАСКАД 2: ПОДБОР ОПТИМАЛЬНОЙ МОЩНОСТИ ==="
CURRENT_POWER=$MIN_POWER
#iw dev $INTERFACE set txpower fixed $((CURRENT_POWER * 100))
uci set wireless.radio0.txpower="$CURRENT_POWER"
uci commit wireless
wifi reload
sleep 30
while [ $CURRENT_POWER -le $MAX_POWER ]; do
    echo "Тестирование мощности: ${CURRENT_POWER} dBm на канале ${BEST_CHANNEL}"
    
    # Ждём стабилизации клиентов
    sleep $SETTLE_TIME
    
    # Собираем статистику
#    read MAX_RETRY MIN_THROUGHPUT MIN_RSSI <<< $(get_client_stats)

    stats=$(get_client_stats)
    MAX_RETRY=$(echo "$stats" | awk '{print $1}')
    MIN_THROUGHPUT=$(echo "$stats" | awk '{print $2}')
    MIN_RSSI=$(echo "$stats" | awk '{print $3}')
    
    # Проверяем, достаточно ли данных
    if [ "$MAX_RETRY" = "0" ] && [ "$MIN_THROUGHPUT" = "999" ]; then
        echo "Нет активных клиентов, ожидание..."
        sleep $IDLE_INTERVAL
        continue
    fi
    
    # Логируем замер
    log_action "MEASURE" "$CURRENT_POWER" "$BEST_CHANNEL" "$MAX_RETRY" "$MIN_THROUGHPUT"
    
    # Оцениваем состояние клиентов
    STATE=$(evaluate_state $MAX_RETRY $MIN_THROUGHPUT $MIN_RSSI)
    
    echo "  Retry: ${MAX_RETRY}% | Throughput: ${MIN_THROUGHPUT} Mbps | RSSI: ${MIN_RSSI} dBm | Состояние: ${STATE}"
    
    # Проверяем, достигнута ли цель
    if [ $MAX_RETRY -lt $THRESHOLD_RETRY ] && [ $MIN_THROUGHPUT -gt $THRESHOLD_THROUGHPUT ] && [ $MIN_RSSI -gt $THRESHOLD_RSSI ]; then
        echo "✅ ОПТИМАЛЬНАЯ МОЩНОСТЬ НАЙДЕНА: ${CURRENT_POWER} dBm"
        log_action "OPTIMAL_FOUND" "$CURRENT_POWER" "$BEST_CHANNEL" "$MAX_RETRY" "$MIN_THROUGHPUT"
        break
    fi
    
    # Проверка, не превышен ли порог для действия (обучение через подкрепление)
    if [ $MAX_RETRY -gt $THRESHOLD_RETRY ]; then
        echo "⚠️  Retry превышает порог. Требуется повышение мощности или смена канала."
        
        if [ $CURRENT_POWER -eq $MAX_POWER ]; then
            echo "🔴 Достигнута максимальная мощность, качество всё ещё плохое. Смена канала..."
            log_action "CHANNEL_SWITCH" "$CURRENT_POWER" "$BEST_CHANNEL" "$MAX_RETRY" "$MIN_THROUGHPUT"
            BEST_CHANNEL=$(get_best_channel)
#            iw dev $INTERFACE set channel $BEST_CHANNEL
            uci set wireless.radio0.channel="$BEST_CHANNEL"
            uci commit wireless
            wifi reload

            CURRENT_POWER=$MIN_POWER
#            iw dev $INTERFACE set txpower fixed $((CURRENT_POWER * 100))
            uci set wireless.radio0.txpower="$CURRENT_POWER"
            uci commit wireless
            wifi reload
            sleep 30
            echo "Переключились на канал $BEST_CHANNEL, мощность сброшена до ${MIN_POWER} dBm"
            continue
        fi
    fi
    
    # Повышаем мощность для следующей итерации
    CURRENT_POWER=$((CURRENT_POWER + POWER_STEP))
    if [ $CURRENT_POWER -le $MAX_POWER ]; then
#        iw dev $INTERFACE set txpower fixed $((CURRENT_POWER * 100))
        uci set wireless.radio0.txpower="$CURRENT_POWER"
        uci commit wireless
        wifi reload
        sleep 30    
        echo "Повышаем мощность до ${CURRENT_POWER} dBm..."
    fi
done

# ----------------------- ОСНОВНОЙ ЦИКЛ РАБОТЫ -----------------------

echo "=== НЕЙРОСЕТЬ ЗАПУЩЕНА В ОСНОВНОМ ЦИКЛЕ ==="
echo "Оптимальные параметры: канал $BEST_CHANNEL, мощность ${CURRENT_POWER} dBm"
log_action "RUNNING" "$CURRENT_POWER" "$BEST_CHANNEL" "0" "0"

# Бесконечный цикл мониторинга
# Бесконечный цикл мониторинга
while true; do
    sleep $IDLE_INTERVAL
    
    stats=$(get_client_stats)
    MAX_RETRY=$(echo "$stats" | awk '{print $1}')
    MIN_THROUGHPUT=$(echo "$stats" | awk '{print $2}')
    MIN_RSSI=$(echo "$stats" | awk '{print $3}')
    
    if [ "$MAX_RETRY" = "0" ] && [ "$MIN_THROUGHPUT" = "999" ]; then
        continue
    fi
    
    STATE=$(evaluate_state $MAX_RETRY $MIN_THROUGHPUT $MIN_RSSI)
    
    log_action "MONITOR" "$CURRENT_POWER" "$BEST_CHANNEL" "$MAX_RETRY" "$MIN_THROUGHPUT"
    
    if [ "$STATE" = "1" ]; then
        echo "⚠️  Обнаружено ухудшение качества: retry=${MAX_RETRY}%, thr=${MIN_THROUGHPUT}Mbps"
        
        if [ $CURRENT_POWER -lt $MAX_POWER ]; then
            # Пробуем повысить мощность
            CURRENT_POWER=$((CURRENT_POWER + POWER_STEP))
            uci set wireless.radio0.txpower="$CURRENT_POWER"
            uci commit wireless
            wifi reload
            sleep 30
            
            log_action "POWER_UP" "$CURRENT_POWER" "$BEST_CHANNEL" "$MAX_RETRY" "$MIN_THROUGHPUT"
            echo "Повышаем мощность до ${CURRENT_POWER} dBm"
            
            sleep $SETTLE_TIME
            
            stats=$(get_client_stats)
            NEW_RETRY=$(echo "$stats" | awk '{print $1}')
            NEW_THROUGHPUT=$(echo "$stats" | awk '{print $2}')
            NEW_RSSI=$(echo "$stats" | awk '{print $3}')
            
            if [ $NEW_RETRY -lt $MAX_RETRY ]; then
                sed -i 's/power_increase=0/power_increase=1/' $WEIGHTS_FILE
                echo "✅ Повышение мощности помогло (retry ${MAX_RETRY}% → ${NEW_RETRY}%)"
            else
                sed -i 's/power_increase=0/power_increase=-1/' $WEIGHTS_FILE
                echo "❌ Повышение мощности не помогло"
                
                # Если мощность стала максимальной - меняем канал и сбрасываем мощность на 5
                if [ $CURRENT_POWER -eq $MAX_POWER ]; then
                    echo "⚠️ Мощность достигла максимума (${MAX_POWER} dBm), но качество не улучшилось. Меняем канал..."
                    BEST_CHANNEL=$(get_best_channel)
                    uci set wireless.radio0.channel="$BEST_CHANNEL"
                    uci commit wireless
                    wifi reload
                    sleep 30
                    
                    # СБРАСЫВАЕМ МОЩНОСТЬ НА 5 dBm
                    CURRENT_POWER=$MIN_POWER
                    uci set wireless.radio0.txpower="$CURRENT_POWER"
                    uci commit wireless
                    wifi reload
                    sleep 30
                    
                    log_action "CHANNEL_SWITCH" "$CURRENT_POWER" "$BEST_CHANNEL" "$MAX_RETRY" "$MIN_THROUGHPUT"
                    echo "Переключились на канал $BEST_CHANNEL, мощность сброшена до ${MIN_POWER} dBm"
                fi
            fi
        else
            # Мощность уже максимальная - меняем канал и сбрасываем мощность на 5
            echo "Мощность уже максимальная (${MAX_POWER} dBm). Сканируем эфир..."
            BEST_CHANNEL=$(get_best_channel)
            uci set wireless.radio0.channel="$BEST_CHANNEL"
            uci commit wireless
            wifi reload
            sleep 30
            
            # СБРАСЫВАЕМ МОЩНОСТЬ НА 5 dBm
            CURRENT_POWER=$MIN_POWER
            uci set wireless.radio0.txpower="$CURRENT_POWER"
            uci commit wireless
            wifi reload
            sleep 30
            
            log_action "CHANNEL_SWITCH" "$CURRENT_POWER" "$BEST_CHANNEL" "$MAX_RETRY" "$MIN_THROUGHPUT"
            echo "Переключились на канал $BEST_CHANNEL, мощность сброшена до ${MIN_POWER} dBm"
            
            sleep $SETTLE_TIME
        fi
    fi
done