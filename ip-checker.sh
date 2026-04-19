#!/bin/bash

# ================= НАСТРОЙКИ =================
ZONES=("ru-central1-a" "ru-central1-b" "ru-central1-d" "ru-central1-e")

CREATED_IDS=()
SAVED_GOOD_DETAILS=()
SAVED_GOOD_IDS=()
declare -A STATS
TOTAL_ATTEMPTS=0

echo "🔍 Инициализация: сбор данных об окружении и аккаунте..."

FOLDER_ID=$(curl -s --max-time 2 -H "Metadata-Flavor: Google" http://169.254.169.254/computeMetadata/v1/instance/vendor/folder-id 2>/dev/null)
if [[ -z "$FOLDER_ID" || "$FOLDER_ID" == *"Error"* ]]; then
    FOLDER_ID=$(yc config get folder-id 2>/dev/null)
fi

if [[ -z "$FOLDER_ID" ]]; then
    echo "❌ Ошибка: Не удалось определить folder-id."
    exit 1
fi
echo "✅ Каталог: $FOLDER_ID"

CLOUD_ID=$(yc config get cloud-id 2>/dev/null)
TOTAL_QUOTA=$(yc quota-manager quota-limit list --service vpc --resource-type resource-manager.cloud --resource-id "$CLOUD_ID" --format json 2>/dev/null | jq -r '.quota_limits[]? | select(.quota_id == "vpc.externalStaticAddresses.count") | .limit')

if [[ -z "$TOTAL_QUOTA" || "$TOTAL_QUOTA" == "null" ]]; then
    TOTAL_QUOTA=5
fi

# =====================================================================
# ФУНКЦИИ УТИЛИТ
# =====================================================================
trap 'cleanup_and_exit' SIGINT SIGTERM SIGHUP

# Остановка скрипта и очистка
cleanup_and_exit() {
    echo -e "\n🛑 Скрипт прерван."
    print_stats
    if [ ${#SAVED_GOOD_DETAILS[@]} -gt 0 ]; then
        echo "💎 СОХРАНЕННЫЙ УЛОВ:"
        for detail in "${SAVED_GOOD_DETAILS[@]}"; do echo "  👉 $detail"; done
    fi
    if [ ${#CREATED_IDS[@]} -gt 0 ]; then
        yc vpc address delete "${CREATED_IDS[@]}" 2>/dev/null
    fi
    exit 0
}

# Вывод статистики
print_stats() {
    echo ""
    echo "📊 СТАТИСТИКА ПУЛОВ (Попыток: $TOTAL_ATTEMPTS | Найдено новых: ${#SAVED_GOOD_DETAILS[@]}):"
    echo "--------------------------------------------------------"
    for subnet in "${!STATS[@]}"; do
        echo "$subnet count=${STATS[$subnet]}"
    done | sort -t '=' -k 2 -nr | awk '{printf "   %-18s %s\n", $1, $2}'
    echo "--------------------------------------------------------"
}

# Зачистка зомби-IP
run_garbage_collector() {
    echo "   ⚠️ ВНИМАНИЕ: Запуск сборщика мусора..."
    
    # Получение всех внешних адресов, которые НЕ привязаны к ВМ (.used != true)
    ALL_UNUSED_IDS=$(yc vpc address list --folder-id "$FOLDER_ID" --format json 2>/dev/null | jq -r '.[] | select(has("external_ipv4_address") and .used != true) | .id')
    
    # Определение зомби-IP
    ZOMBIE_IDS=()
    for id in $ALL_UNUSED_IDS; do
        # Если этот ID не в нашем золотом списке - зомби-IP
        if [[ ! " ${SAVED_GOOD_IDS[@]} " =~ " ${id} " ]]; then
            ZOMBIE_IDS+=("$id")
        fi
    done

    # Очистка при обнаружении зомби-IP
    if [ ${#ZOMBIE_IDS[@]} -gt 0 ]; then
        echo "   ☠️ Найдено зомби-адресов: ${#ZOMBIE_IDS[@]}. Уничтожаем..."
        yc vpc address delete "${ZOMBIE_IDS[@]}" 2>/dev/null
        echo "   ✨ Очистка завершена. Квота восстановлена."
    else
        echo "   ✅ Зомби-адресов не найдено. Проблема в лимитах самого Яндекса."
    fi
}

# =====================================================================
# ГЛАВНЫЙ ЦИКЛ
# =====================================================================
EXISTING_IPS_JSON=$(yc vpc address list --folder-id "$FOLDER_ID" --format json 2>/dev/null)
EXISTING_IPS_COUNT=$(echo "$EXISTING_IPS_JSON" | jq '[.[] | select(has("external_ipv4_address"))] | length' 2>/dev/null)
FREE_SLOTS=$(( TOTAL_QUOTA - ${EXISTING_IPS_COUNT:-0} ))

echo "✅ Лимит: $TOTAL_QUOTA. Занято: $EXISTING_IPS_COUNT. Свободно: $FREE_SLOTS."

while true; do
    if [ "$FREE_SLOTS" -le 0 ]; then
        echo "========================================================"
        echo "🏆 БИНГО! КВОТА ЗАПОЛНЕНА ЭЛИТНЫМИ АДРЕСАМИ!"
        for detail in "${SAVED_GOOD_DETAILS[@]}"; do echo "👉 $detail"; done
        print_stats
        exit 0
    fi

    echo "========================================================"
    echo "⏳ Свободных слотов: $FREE_SLOTS. Запрашиваем партию..."
    
    CREATED_IDS=()
    IPS_TO_CHECK=()
    SUCCESSFUL_CREATIONS=0 # Подсчёт успешных созданий
    
    # Создание IP
    for ((i=1; i<=FREE_SLOTS; i++)); do
        zone=${ZONES[$(( RANDOM % ${#ZONES[@]} ))]}
        address_data=$(yc vpc address create --folder-id "$FOLDER_ID" --external-ipv4 zone=$zone --format json 2>/dev/null)
        
        addr_id=$(echo "$address_data" | jq -r '.id' 2>/dev/null)
        ip_addr=$(echo "$address_data" | jq -r '.external_ipv4_address.address' 2>/dev/null)
        
        if [[ -n "$addr_id" && "$addr_id" != "null" && -n "$ip_addr" ]]; then
            CREATED_IDS+=("$addr_id")
            IPS_TO_CHECK+=("$ip_addr:$addr_id")
            subnet="$(echo "$ip_addr" | cut -d. -f1,2).0.0/16"
            STATS["$subnet"]=$(( ${STATS["$subnet"]:-0} + 1 ))
            TOTAL_ATTEMPTS=$(( TOTAL_ATTEMPTS + 1 ))
            SUCCESSFUL_CREATIONS=$((SUCCESSFUL_CREATIONS + 1))
            echo "   ✅ Выдали: $ip_addr (в $zone)"
        else
            echo "   ❌ Сбой API Яндекса."
        fi
        sleep 1 
    done
    
    # Если запросы упали -> Вызов сборщика мусора
    if [ "$SUCCESSFUL_CREATIONS" -eq 0 ]; then
        echo "💤 Ни один адрес не создан. Возможно, появились фантомы."
        run_garbage_collector

        echo "   ⏳ Синхронизация квот Яндекса (5 сек)..."
        sleep 5
        
        # Пересчёт квоты
        EXISTING_IPS_JSON=$(yc vpc address list --folder-id "$FOLDER_ID" --format json 2>/dev/null)
        EXISTING_IPS_COUNT=$(echo "$EXISTING_IPS_JSON" | jq '[.[] | select(has("external_ipv4_address"))] | length' 2>/dev/null)
        FREE_SLOTS=$(( TOTAL_QUOTA - ${EXISTING_IPS_COUNT:-0} ))
        
        sleep 5; continue
    fi

    BAD_IDS=()
    JUST_IPS=""
    for item in "${IPS_TO_CHECK[@]}"; do JUST_IPS="${JUST_IPS} ${item%%:*}"; done

    # Определение чистоты IP
    WHITE_MATCHES=$(python3 -c "
import ipaddress, sys
tiers = {
    '🥇 ВЫСШИЙ ШАНС (d)': ['51.250.0.0/17', '158.160.0.0/16'],
    '🥈 ОТЛИЧНЫЙ ШАНС (b)': ['84.201.128.0/18', '84.252.128.0/20'],
    '🥉 ХОРОШИЙ ШАНС (e)': ['89.169.128.0/18', '178.154.192.0/18']
}
nets = {t: [ipaddress.ip_network(n, strict=False) for n in lst] for t, lst in tiers.items()}

for ip_str in sys.argv[1].split():
    try:
        ip = ipaddress.ip_address(ip_str)
        for tier, n_list in nets.items():
            if any(ip in n for n in n_list):
                print(f'{ip_str}|{tier}')
                break
    except Exception: pass
" "$JUST_IPS")

    for item in "${IPS_TO_CHECK[@]}"; do
        ip="${item%%:*}"
        id="${item##*:}"
        
        if echo "$WHITE_MATCHES" | grep -q "^$ip|"; then
            tier=$(echo "$WHITE_MATCHES" | grep "^$ip|" | cut -d'|' -f2)
            echo "   🎉 БЕРЕМ! Отличный IP: $ip -> $tier"
            
            SAVED_GOOD_DETAILS+=("$ip (ID: $id) [$tier]")
            SAVED_GOOD_IDS+=("$id") # Сохранение хорошего IP
            FREE_SLOTS=$(( FREE_SLOTS - 1 ))
            
            NEW_CREATED=()
            for cid in "${CREATED_IDS[@]}"; do
                if [ "$cid" != "$id" ]; then NEW_CREATED+=("$cid"); fi
            done
            CREATED_IDS=("${NEW_CREATED[@]}")
        else
            echo "   🗑  Мусор ($ip) - в топку."
            BAD_IDS+=("$id")
        fi
    done
    
    # Очистка плохого IP
    if [ ${#BAD_IDS[@]} -gt 0 ]; then
        yc vpc address delete "${BAD_IDS[@]}" 2>/dev/null
        sleep 5
    else
        sleep 3
    fi
    
    CREATED_IDS=()
    if (( TOTAL_ATTEMPTS % 20 == 0 )); then print_stats; fi
    sleep 3
done
