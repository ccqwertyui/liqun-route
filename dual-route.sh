#!/bin/bash
# ==============================================================================
# 多出口策略路由管理脚本 (PBR) v4.10 - 改进版
# 支持: 双线/多线策略路由 | 端口精准分流 | NAT伪装 | DDNS | 智能防抖调度(MWAN)
# ==============================================================================

if [[ $EUID -ne 0 ]]; then
   echo "错误: 此脚本必须以 root 权限运行。"
   exit 1
fi

if [ -f /etc/os-release ]; then
    source /etc/os-release
    if [[ "$ID" == "debian" ]] && [[ "$VERSION_ID" == "13" || "$VERSION_CODENAME" == "trixie" ]]; then
        if [ ! -f /etc/iproute2/rt_tables ] || ! grep -q "253 default" /etc/iproute2/rt_tables; then
            mkdir -p /etc/iproute2
            echo -e "255 local\n254 main\n253 default\n0 unspec" > /etc/iproute2/rt_tables
        fi
    fi
fi

INSTALL_PATH="/usr/local/bin/dual-route.sh"
ALIAS_PATH="/usr/local/bin/ly"
CONFIG_FILE="/etc/custom_policy_routes.conf"
DDNS_CONFIG_FILE="/etc/custom_policy_ddns.conf"
MWAN_CONFIG_FILE="/etc/custom_mwan.conf"
RT_TABLES_FILE="/etc/iproute2/rt_tables"
SERVICE_FILE="/etc/systemd/system/custom-routing.service"
MWAN_SERVICE_FILE="/etc/systemd/system/liqun-mwan.service"
MWAN_LOG="/var/log/liqun_mwan.log"

touch "$CONFIG_FILE"
touch "$DDNS_CONFIG_FILE"
touch "$MWAN_CONFIG_FILE"

RAW_DEFINITIONS="
9929 10.7.0.1 ^10\.7\.
CN2 10.8.0.1 ^10\.8\.
JPSDWAN 10.3.0.1 ^10\.3\.[0-3]\.
DESDWAN 10.3.10.1 ^10\.3\.(8|9|10|11)\.
KRSDWAN 10.4.0.1 ^10\.4\.[0-3]\.
HKSDWAN 10.3.50.1 ^10\.3\.(48|49|50|51)\.
TWSDWAN 10.3.100.1 ^10\.3\.(100|101|102|103)\.
USSDWAN-SEATTLE 10.3.160.1 ^10\.3\.(160|161)\.
MOSCOW 10.3.170.1 ^10\.3\.(170|171)\.
SINGAPORE 10.3.180.1 ^10\.3\.180\.
USSDWAN-LAX 10.3.150.1 ^10\.3\.(150|151)\.
"

PRIO_STATIC=15000
PRIO_FWMARK=14999
PRIO_DDNS=15005

declare -a FOUND_NAMES
declare -a FOUND_GWS
declare -a FOUND_IDS
SELECTED_ROUTE_IDX=-1

function check_self_install() {
    local script_base="$(basename "$0" 2>/dev/null)"
    if [ -f "$0" ] && [[ "$script_base" != "bash" && "$script_base" != "sh" ]]; then
        local current_script="$(realpath "$0")"
        if [ "$current_script" != "$INSTALL_PATH" ]; then
            cp -f "$current_script" "$INSTALL_PATH"
            chmod +x "$INSTALL_PATH"
        fi
    fi
    if [ -f "$INSTALL_PATH" ]; then
        if [ ! -f "$ALIAS_PATH" ] || [ "$(realpath "$ALIAS_PATH" 2>/dev/null)" != "$INSTALL_PATH" ]; then
            cat << EOF > "$ALIAS_PATH"
#!/bin/bash
exec $INSTALL_PATH "\$@"
EOF
            chmod +x "$ALIAS_PATH"
        fi
    fi
}

function fix_multigateway_conflict() {
    local current_defaults=$(ip route show default)
    local default_count=$(echo "$current_defaults" | grep -c "default" || true)
    if [ "$default_count" -le 1 ]; then return; fi
    echo "$RAW_DEFINITIONS" | while read -r name gw pattern; do
        if [[ -z "$name" ]]; then continue; fi
        if echo "$current_defaults" | grep -q "via $gw"; then
            local remaining=$(ip route show default | grep -v "via $gw" | wc -l)
            if [ "$remaining" -ge 1 ]; then
                ip route del default via "$gw" 2>/dev/null
            fi
        fi
    done
}

function detect_available_routes() {
    fix_multigateway_conflict
    FOUND_NAMES=()
    FOUND_GWS=()
    FOUND_IDS=()
    local table_base_id=101 
    local added_count=0
    local all_ips=$(ip -4 addr show | awk '/inet / {print $2}' | cut -d/ -f1)

    while read -r def_name def_gw def_pattern; do
        if [[ -z "$def_name" || "$def_name" =~ ^# ]]; then continue; fi
        local matched=0
        for ip in $all_ips; do
            if [[ "$ip" =~ $def_pattern ]]; then matched=1; break; fi
        done

        if [[ $matched -eq 1 ]]; then
            FOUND_NAMES+=("$def_name")
            FOUND_GWS+=("$def_gw")
            local current_id=$((table_base_id + added_count))
            FOUND_IDS+=("$current_id")
            if ! grep -qE "^[0-9]+[[:space:]]+T_${def_name}([[:space:]]|$)" "$RT_TABLES_FILE"; then
                echo "$current_id T_${def_name}" >> "$RT_TABLES_FILE"
            fi
            ((added_count++))
        fi
    done <<< "$RAW_DEFINITIONS"
}

function init_routing_tables() {
    for ((i=0; i<${#FOUND_NAMES[@]}; i++)); do
        local table_id="${FOUND_IDS[$i]}"
        local gateway="${FOUND_GWS[$i]}"
        local route_info=$(ip route get "$gateway" 2>/dev/null | head -n 1)
        local dev=$(echo "$route_info" | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
        local src=$(echo "$route_info" | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')
        if [[ -n "$dev" && -n "$src" ]]; then
            local subnet=$(ip route show dev "$dev" scope link 2>/dev/null | awk '{print $1}' | head -n 1)
            if [ -n "$subnet" ]; then
                ip route replace "$subnet" dev "$dev" scope link src "$src" table "$table_id" 2>/dev/null
            fi
            ip route replace default via "$gateway" dev "$dev" src "$src" table "$table_id" 2>/dev/null
        else
            ip route replace default via "$gateway" table "$table_id" 2>/dev/null
        fi
    done
}

function select_route_group() {
    detect_available_routes
    local count=${#FOUND_NAMES[@]}
    if [ "$count" -eq 0 ]; then
        echo "错误: 未检测到可用网关。"
        SELECTED_ROUTE_IDX=-1
        return 1
    fi
    echo "----------------------------------------------------"
    printf "%-4s %-15s %-15s\n" "No." "线路名" "网关IP"
    echo "---- --------------- ---------------"
    for ((i=0; i<count; i++)); do
        printf "%-4d %-15s %-15s\n" "$((i+1))" "${FOUND_NAMES[$i]}" "${FOUND_GWS[$i]}"
    done
    echo "----------------------------------------------------"
    local choice
    read -p "请输入对应数字: " choice < /dev/tty
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "$count" ]; then
        echo "错误: 无效输入。"
        SELECTED_ROUTE_IDX=-1
        return 1
    fi
    SELECTED_ROUTE_IDX=$((choice - 1))
    return 0
}

function add_rule() {
    select_route_group || return 1
    local selected_name="${FOUND_NAMES[$SELECTED_ROUTE_IDX]}"
    if [ -z "$selected_name" ]; then return 1; fi
    local cidr; read -p "输入目标IP/网段 (例 8.8.8.8/32): " cidr < /dev/tty
    if [ -z "$cidr" ]; then return 1; fi
    if ! [[ "$cidr" == */* ]]; then cidr="${cidr}/32"; fi
    local proto; read -p "输入协议 (tcp/udp/all, 默认all): " proto < /dev/tty
    proto=${proto:-all}
    local port="all"
    if [[ "$proto" != "all" ]]; then
        read -p "输入端口 (留空为all): " port < /dev/tty
        port=${port:-all}
    fi
    local rule_line="${cidr} ${proto} ${port} ${selected_name}"
    if grep -qE "^${cidr}[[:space:]]+${proto}[[:space:]]+${port}[[:space:]]+${selected_name}$" "$CONFIG_FILE"; then
        echo "规则已存在。"
        return 1
    fi
    echo "$rule_line" >> "$CONFIG_FILE"
    apply_saved_rules >/dev/null 2>&1
    echo "保存并生效。"
}

function add_ddns_rule() {
    select_route_group || return 1
    local selected_name="${FOUND_NAMES[$SELECTED_ROUTE_IDX]}"
    if [ -z "$selected_name" ]; then return 1; fi
    
    local domain
    echo ""
    read -p "请输入域名 (A Record): " domain < /dev/tty
    if [ -z "$domain" ]; then echo "错误: 输入不能为空。"; return 1; fi

    echo "${domain} ${selected_name}" >> "$DDNS_CONFIG_FILE"
    echo "规则已保存。正在执行解析更新..."
    refresh_ddns_rules
}

function delete_rule() {
    echo "1) 删除静态 IP/端口 规则"
    echo "2) 删除 DDNS 域名规则"
    read -p "请选择: " dtype < /dev/tty
    local target_file=""
    if [ "$dtype" == "1" ]; then target_file="$CONFIG_FILE"; 
    elif [ "$dtype" == "2" ]; then target_file="$DDNS_CONFIG_FILE"; 
    else return; fi
    
    if [ ! -s "$target_file" ]; then echo "配置文件为空。"; return; fi
    
    awk '{print NR") "$0}' "$target_file"
    local line_num
    read -p "输入要删除的编号: " line_num < /dev/tty
    if [[ "$line_num" =~ ^[0-9]+$ ]]; then
        sed -i "${line_num}d" "$target_file"
        echo "配置已删除。正在重新应用规则..."
        apply_saved_rules >/dev/null 2>&1
        echo "刷新完成。"
    else
        echo "错误: 无效的编号输入。"
    fi
}

function refresh_ddns_rules() {
    while ip rule del priority $PRIO_DDNS 2>/dev/null; do :; done
    if [ ! -s "$DDNS_CONFIG_FILE" ]; then return; fi
    detect_available_routes
    init_routing_tables
    
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        local domain=$(echo "$line" | awk '{print $1}')
        local group=$(echo "$line" | awk '{print $2}')
        
        local found_idx=-1
        for ((i=0; i<${#FOUND_NAMES[@]}; i++)); do
            if [[ "${FOUND_NAMES[$i]}" == "$group" ]]; then found_idx=$i; break; fi
        done
        
        if [ $found_idx -ge 0 ]; then
            local ips=$(getent hosts "$domain" | awk '{ print $1 }' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
            if [ -n "$ips" ]; then
                for ip_addr in $ips; do
                    ip rule add to "${ip_addr}/32" table "T_${group}" priority $PRIO_DDNS
                done
            fi
        fi
    done < "$DDNS_CONFIG_FILE"
    ip route flush cache 2>/dev/null || true
}

function manage_cron() {
    echo "=== DDNS 自动更新配置 (Crontab) ==="
    local cron_cmd="$INSTALL_PATH ddns_update"
    local current_cron=$(crontab -l 2>/dev/null)
    if echo "$current_cron" | grep -q "$cron_cmd"; then
        echo "状态: [已启用]"
        read -p "是否移除自动更新? (y/n): " remove_opt < /dev/tty
        if [[ "$remove_opt" == "y" ]]; then
            crontab -l | grep -v "$cron_cmd" | crontab -
            echo "已移除。"
        fi
    else
        echo "状态: [未启用]"
        read -p "是否添加每 5 分钟自动更新任务? (y/n): " add_opt < /dev/tty
        if [[ "$add_opt" == "y" ]]; then
            (crontab -l 2>/dev/null; echo "*/5 * * * * $cron_cmd >/dev/null 2>&1") | crontab -
            echo "已添加。"
        fi
    fi
}

function manage_service() {
    if [ -f "$SERVICE_FILE" ]; then
        echo "服务状态: $(systemctl is-active custom-routing.service 2>/dev/null || echo '未知')"
        read -p "是否卸载开机自启服务? (y/n): " opt < /dev/tty
        if [[ "$opt" == "y" ]]; then
            systemctl stop custom-routing.service 2>/dev/null
            systemctl disable custom-routing.service 2>/dev/null
            rm -f "$SERVICE_FILE"
            systemctl daemon-reload
            echo "已卸载。"
        fi
    else
        read -p "是否安装开机自启服务? (y/n): " opt < /dev/tty
        if [[ "$opt" == "y" ]]; then
            cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Apply Custom Policy-Based Routing Rules
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${INSTALL_PATH} apply
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload
            systemctl enable custom-routing.service
            systemctl start custom-routing.service
            echo "已成功安装并启动开机自启服务。"
        fi
    fi
}

function apply_saved_rules() {
    detect_available_routes
    init_routing_tables
    
    while ip rule del priority $PRIO_STATIC 2>/dev/null; do :; done
    while ip rule del priority $PRIO_FWMARK 2>/dev/null; do :; done
    
    iptables -t mangle -D OUTPUT -j CUSTOM_PBR 2>/dev/null
    iptables -t mangle -D PREROUTING -j CUSTOM_PBR 2>/dev/null
    iptables -t mangle -F CUSTOM_PBR 2>/dev/null
    iptables -t mangle -X CUSTOM_PBR 2>/dev/null
    iptables -t mangle -N CUSTOM_PBR
    iptables -t mangle -A OUTPUT -j CUSTOM_PBR
    iptables -t mangle -A PREROUTING -j CUSTOM_PBR

    iptables -t nat -D POSTROUTING -j CUSTOM_PBR_NAT 2>/dev/null
    iptables -t nat -F CUSTOM_PBR_NAT 2>/dev/null
    iptables -t nat -X CUSTOM_PBR_NAT 2>/dev/null
    iptables -t nat -N CUSTOM_PBR_NAT
    iptables -t nat -A POSTROUTING -j CUSTOM_PBR_NAT

    for ((i=0; i<${#FOUND_NAMES[@]}; i++)); do
        local table_id="${FOUND_IDS[$i]}"
        local name="${FOUND_NAMES[$i]}"
        ip rule add fwmark "$table_id" table "T_${name}" priority $PRIO_FWMARK 2>/dev/null
        iptables -t nat -A CUSTOM_PBR_NAT -m mark --mark "$table_id" -j MASQUERADE 2>/dev/null
    done

    if [ -s "$CONFIG_FILE" ]; then
        while IFS= read -r rule || [[ -n "$rule" ]]; do
            [[ -z "$rule" || "$rule" =~ ^[[:space:]]*# ]] && continue
            local col_count=$(echo "$rule" | awk '{print NF}')
            local cidr=$(echo "$rule" | awk '{print $1}')
            local proto="all"; local port="all"; local name=""
            if [ "$col_count" -eq 2 ]; then name=$(echo "$rule" | awk '{print $2}')
            elif [ "$col_count" -ge 4 ]; then
                proto=$(echo "$rule" | awk '{print $2}'); port=$(echo "$rule" | awk '{print $3}'); name=$(echo "$rule" | awk '{print $4}')
            else continue; fi
            
            local found_idx=-1
            for ((i=0; i<${#FOUND_NAMES[@]}; i++)); do
                if [[ "${FOUND_NAMES[$i]}" == "$name" ]]; then found_idx=$i; break; fi
            done
            if [ $found_idx -ge 0 ]; then
                local table_id="${FOUND_IDS[$found_idx]}"
                if [[ "$proto" == "all" && "$port" == "all" ]]; then
                    ip rule add to "$cidr" table "T_${name}" priority $PRIO_STATIC 2>/dev/null
                else
                    if [[ "$port" == "all" ]]; then
                        iptables -t mangle -A CUSTOM_PBR -d "$cidr" -p "$proto" -j MARK --set-mark "$table_id"
                    else
                        iptables -t mangle -A CUSTOM_PBR -d "$cidr" -p "$proto" --dport "$port" -j MARK --set-mark "$table_id"
                    fi
                fi
            fi
        done < "$CONFIG_FILE"
    fi
    refresh_ddns_rules
    ip route flush cache 2>/dev/null || true
}

# ==========================================
# 智能调度引擎 (MWAN) 
# ==========================================
function mwan_daemon() {
    echo "=== 启动利群智能调度(MWAN)精细防抖守护进程 ===" > "$MWAN_LOG"
    declare -A GW_MAP; declare -A SRC_MAP; declare -A ID_MAP
    detect_available_routes
    for ((i=0; i<${#FOUND_NAMES[@]}; i++)); do
        name="${FOUND_NAMES[$i]}"
        gw="${FOUND_GWS[$i]}"
        id="${FOUND_IDS[$i]}"
        src=$(ip route get "$gw" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')
        GW_MAP["$name"]="$gw"; SRC_MAP["$name"]="$src"; ID_MAP["$name"]="$id"
    done
    declare -A CURRENT_ROUTE_MAP
    declare -A STRIKE_COUNT
    
    while true; do
        if [ ! -s "$MWAN_CONFIG_FILE" ]; then sleep 5; continue; fi
        while IFS= read -r rule || [[ -n "$rule" ]]; do
            [[ -z "$rule" || "$rule" =~ ^[[:space:]]*# ]] && continue
            read -r cidr proto port main_route backup_route mode strikes <<< "$rule"
            target_ip=$(echo "$cidr" | cut -d/ -f1)
            rule_key="${cidr}_${proto}_${port}"
            strikes=${strikes:-3}
            
            if [[ -z "${CURRENT_ROUTE_MAP[$rule_key]}" ]]; then
                CURRENT_ROUTE_MAP[$rule_key]="$main_route"
            fi
            curr_route="${CURRENT_ROUTE_MAP[$rule_key]}"
            
            main_src="${SRC_MAP[$main_route]}"
            if [[ -n "$main_src" ]]; then
                # 原汁原味还原 v4.9 的底层发包逻辑
                raw_main=$(ping -c 3 -I "$main_src" "$target_ip" -W 2 2>/dev/null)
                loss_main=$(echo "$raw_main" | grep "packet loss" | awk -F'packet loss' '{print $1}' | awk '{print $NF}' | tr -d '%')
                [[ -z "$loss_main" ]] && loss_main=100
                if [[ "$loss_main" -lt 100 ]]; then
                    ping_main=$(echo "$raw_main" | tail -1 | awk -F '/' '{print $5}' | cut -d. -f1)
                else ping_main=9999; fi
            else loss_main=100; ping_main=9999; fi

            backup_src="${SRC_MAP[$backup_route]}"
            if [[ -n "$backup_src" ]]; then
                raw_backup=$(ping -c 3 -I "$backup_src" "$target_ip" -W 2 2>/dev/null)
                loss_backup=$(echo "$raw_backup" | grep "packet loss" | awk -F'packet loss' '{print $1}' | awk '{print $NF}' | tr -d '%')
                [[ -z "$loss_backup" ]] && loss_backup=100
                if [[ "$loss_backup" -lt 100 ]]; then
                    ping_backup=$(echo "$raw_backup" | tail -1 | awk -F '/' '{print $5}' | cut -d. -f1)
                else ping_backup=9999; fi
            else loss_backup=100; ping_backup=9999; fi
            
            target_switch=""
            switch_reason=""
            
            if [[ "$curr_route" == "$main_route" ]]; then
                let lat_diff=ping_main-ping_backup
                case "$mode" in
                    1) 
                        if [[ "$loss_main" -eq 100 && "$loss_backup" -lt 100 ]]; then 
                            target_switch="$backup_route"; switch_reason="$main_route 彻底断连 (丢包 100%)"
                        fi ;;
                    2) 
                        if [[ "$loss_main" -ge 20 && "$loss_backup" -lt 20 ]]; then 
                            target_switch="$backup_route"; switch_reason="$main_route 丢包率飙升至 ${loss_main}%"
                        fi ;;
                    3) 
                        if [[ "$loss_main" -eq 100 && "$loss_backup" -lt 100 ]]; then 
                            target_switch="$backup_route"; switch_reason="$main_route 彻底断连 (丢包 100%)"
                        elif [[ "$loss_main" -ge $((loss_backup + 10)) ]]; then 
                            target_switch="$backup_route"; switch_reason="$main_route 丢包率(${loss_main}%)显著高于备用"
                        elif [[ "$loss_main" -eq "$loss_backup" && "$lat_diff" -ge 15 ]]; then 
                            target_switch="$backup_route"; switch_reason="$main_route 延迟劣化，慢了 ${lat_diff}ms"
                        fi ;;
                    4) 
                        if [[ "$loss_main" -eq 100 && "$loss_backup" -lt 100 ]]; then 
                            target_switch="$backup_route"; switch_reason="$main_route 彻底断连 (丢包 100%)"
                        elif [[ "$loss_main" -ge 30 && "$loss_backup" -lt 30 ]]; then 
                            target_switch="$backup_route"; switch_reason="$main_route 丢包率恶化至 ${loss_main}%"
                        elif [[ "$lat_diff" -ge 15 ]]; then 
                            target_switch="$backup_route"; switch_reason="$main_route 延迟劣化，慢了 ${lat_diff}ms"
                        fi ;;
                esac
            else
                let lat_diff_rev=ping_backup-ping_main
                case "$mode" in
                    1|2) 
                        if [[ "$loss_main" -eq 0 ]]; then 
                            target_switch="$main_route"; switch_reason="主路由 $main_route 丢包恢复为 0%"
                        fi ;;
                    3|4) 
                        if [[ "$loss_main" -eq 0 && "$lat_diff_rev" -ge -5 ]]; then 
                            target_switch="$main_route"; switch_reason="主路由 $main_route 延迟与丢包已完全恢复健康"
                        fi ;;
                esac
            fi

            switch_to=""
            if [[ -n "$target_switch" ]]; then
                let STRIKE_COUNT["${rule_key}"]++
                if [[ ${STRIKE_COUNT["${rule_key}"]} -ge "$strikes" ]]; then
                    switch_to="$target_switch"
                    STRIKE_COUNT["${rule_key}"]=0
                    if [[ "$switch_to" == "$backup_route" ]]; then
                        echo "$(date '+%m-%d %H:%M:%S') | 🚨 [切换] $switch_reason，已切至 $backup_route" >> "$MWAN_LOG"
                    else
                        echo "$(date '+%m-%d %H:%M:%S') | ✅ [恢复] $switch_reason，流量已切回 $main_route" >> "$MWAN_LOG"
                    fi
                fi
            else
                STRIKE_COUNT["${rule_key}"]=0
            fi
            
            if [[ -n "$switch_to" ]]; then
                old_id="${ID_MAP[$curr_route]}"; new_id="${ID_MAP[$switch_to]}"
                if [[ "$port" == "all" ]]; then
                    iptables -t mangle -D CUSTOM_PBR -d "$cidr" -p "$proto" -j MARK --set-mark "$old_id" 2>/dev/null
                    iptables -t mangle -A CUSTOM_PBR -d "$cidr" -p "$proto" -j MARK --set-mark "$new_id"
                else
                    iptables -t mangle -D CUSTOM_PBR -d "$cidr" -p "$proto" --dport "$port" -j MARK --set-mark "$old_id" 2>/dev/null
                    iptables -t mangle -A CUSTOM_PBR -d "$cidr" -p "$proto" --dport "$port" -j MARK --set-mark "$new_id"
                fi
                ip route flush cache 2>/dev/null || true
                CURRENT_ROUTE_MAP[$rule_key]="$switch_to"
            fi
        done < "$MWAN_CONFIG_FILE"
        sleep 3
    done
}

function manage_mwan() {
    while true; do
        echo ""
        echo "=== 智能调度与故障转移 (MWAN) ==="
        echo "1. 添加自动调度任务 (多模式可选)"
        echo "2. 删除指定的调度任务"
        echo "3. 完全停止守护进程并清空所有调度"
        echo "4. 查看当前调度任务 (可视化列表)"
        echo "5. 查看实时切换日志"
        echo "0. 返回主菜单"
        echo "--------------------------------"
        read -p "选择: " mopt < /dev/tty
        case $mopt in
            1)
                echo "请选择 [主用线路]:"
                select_route_group || continue
                local main_rt="${FOUND_NAMES[$SELECTED_ROUTE_IDX]}"
                echo "请选择 [备用线路]:"
                select_route_group || continue
                local back_rt="${FOUND_NAMES[$SELECTED_ROUTE_IDX]}"
                
                read -p "目标IP (例 8.8.8.8/32): " cidr < /dev/tty
                read -p "协议 (tcp/udp): " proto < /dev/tty
                read -p "端口 (留空为all): " port < /dev/tty
                port=${port:-all}
                
                echo "--------------------------------"
                echo "选择调度模式:"
                echo "1) 纯故障转移 (仅主线彻底断连时切换)"
                echo "2) 纯丢包容灾 (主线丢包>20%时切换)"
                echo "3) 综合稳定模式 (优先防丢包，丢包差不多时再比延迟)"
                echo "4) 极限电竞模式 (死保低延迟，只要不断线就无视轻微丢包)"
                read -p "输入模式编号 (1-4): " mode < /dev/tty
                if ! [[ "$mode" =~ ^[1-4]$ ]]; then echo "无效输入。"; continue; fi

                echo "--------------------------------"
                echo "设置切换灵敏度 (防抖缓冲):"
                echo "说明: 请输入一个正整数，代表连续探测异常多少次才触发切换 (1次探测约3-4秒)。"
                echo "例如填 1: 发现异常立刻秒切 (极度敏感，适合追求极限)"
                echo "例如填 3: 连续3次异常才切 (约等待10秒，过滤拥堵抖动，推荐)"
                echo "例如填 5: 连续5次异常才切 (约等待20秒，极度稳健)"
                read -p "请输入连续异常次数 (任意正整数，默认 3): " strikes < /dev/tty
                strikes=${strikes:-3}
                if ! [[ "$strikes" =~ ^[1-9][0-9]*$ ]]; then strikes=3; fi
                
                if ! grep -qE "^${cidr}[[:space:]]+${proto}[[:space:]]+${port}[[:space:]]+${main_rt}$" "$CONFIG_FILE"; then
                    echo "${cidr} ${proto} ${port} ${main_rt}" >> "$CONFIG_FILE"
                    apply_saved_rules >/dev/null 2>&1
                fi
                
                echo "${cidr} ${proto} ${port} ${main_rt} ${back_rt} ${mode} ${strikes}" >> "$MWAN_CONFIG_FILE"
                
                cat > "$MWAN_SERVICE_FILE" << EOF
[Unit]
Description=Liqun MWAN Daemon
After=network.target

[Service]
Type=simple
ExecStart=$INSTALL_PATH mwan_daemon
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
                systemctl daemon-reload
                systemctl enable liqun-mwan.service >/dev/null 2>&1
                systemctl restart liqun-mwan.service
                echo "调度任务添加完成，守护进程已更新。"
                ;;
            2)
                if [ ! -s "$MWAN_CONFIG_FILE" ]; then echo "当前无调度任务。"; continue; fi
                awk '{print NR") "$0}' "$MWAN_CONFIG_FILE"
                read -p "输入要删除的规则编号: " dnum < /dev/tty
                if [[ "$dnum" =~ ^[0-9]+$ ]]; then
                    local rule_to_del=$(sed -n "${dnum}p" "$MWAN_CONFIG_FILE")
                    read -r r_cidr r_proto r_port r_main rest_of_line <<< "$rule_to_del"
                    
                    sed -i "${dnum}d" "$MWAN_CONFIG_FILE"
                    
                    grep -v "^${r_cidr} ${r_proto} ${r_port} ${r_main}$" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp"
                    mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
                    
                    apply_saved_rules >/dev/null 2>&1
                    systemctl restart liqun-mwan.service 2>/dev/null
                    echo "已删除调度规则，并清理了底层静态关联规则。"
                else
                    echo "无效输入。"
                fi
                ;;
            3)
                if [ -s "$MWAN_CONFIG_FILE" ]; then
                    while IFS= read -r line || [[ -n "$line" ]]; do
                        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
                        read -r r_cidr r_proto r_port r_main rest_of_line <<< "$line"
                        grep -v "^${r_cidr} ${r_proto} ${r_port} ${r_main}$" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp"
                        mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
                    done < "$MWAN_CONFIG_FILE"
                fi
                systemctl stop liqun-mwan.service 2>/dev/null
                systemctl disable liqun-mwan.service 2>/dev/null
                rm -f "$MWAN_SERVICE_FILE" "$MWAN_CONFIG_FILE"
                systemctl daemon-reload
                apply_saved_rules >/dev/null 2>&1
                echo "已彻底停用 MWAN，所有相关静态保底配置已同步清空。"
                ;;
            4)
                if [ ! -s "$MWAN_CONFIG_FILE" ]; then 
                    echo "当前无调度任务。"
                else
                    echo "--------------------------------------------------------"
                    echo "当前正在运行的调度任务："
                    awk '{
                        mode_str="未知";
                        if($6==1) mode_str="纯故障转移";
                        if($6==2) mode_str="纯丢包容灾";
                        if($6==3) mode_str="综合稳定模式";
                        if($6==4) mode_str="极限电竞模式";
                        strikes=$7; if(strikes=="") strikes=3;
                        printf "[任务 %d] 目标IP: %s | 端口: %s | 主路由: %s / 备路由: %s | 模式: %s | 灵敏度: %s次\n", NR, $1, $3, $4, $5, mode_str, strikes
                    }' "$MWAN_CONFIG_FILE"
                    echo "--------------------------------------------------------"
                fi
                ;;
            5)
                if [ -f "$MWAN_LOG" ]; then
                    echo "按 Ctrl+C 退出日志查看..."
                    tail -f "$MWAN_LOG"
                else
                    echo "暂无日志。"
                fi
                ;;
            0) break ;;
            *) echo "无效输入。" ;;
        esac
    done
}

function list_rules() {
    echo "--- 静态规则 ---"
    [ -s "$CONFIG_FILE" ] && cat "$CONFIG_FILE" || echo "无"
    echo "--- DDNS 动态解析规则 ---"
    [ -s "$DDNS_CONFIG_FILE" ] && cat "$DDNS_CONFIG_FILE" || echo "无"
}

function main_menu() {
    check_self_install
    while true; do
        echo ""
        echo "========================================="
        echo "  多出口策略路由 v4.10 (改进版)"
        echo "========================================="
        echo "1. 添加静态路由 (IP/协议/端口)"
        echo "2. 添加动态路由 (DDNS 域名)"
        echo "3. 删除规则 (支持删静态和DDNS)"
        echo "4. 查看当前所有配置"
        echo "5. 配置自动更新 (Cron/DDNS需要)"
        echo "6. 管理开机自启服务"
        echo "7. 强制刷新所有静态/动态规则"
        echo "-----------------------------------------"
        echo "8. 智能调度与故障转移 (MWAN)"
        echo "0. 退出"
        echo "========================================="
        read -p "选择: " choice < /dev/tty
        case $choice in
            1) add_rule ;;
            2) add_ddns_rule ;;
            3) delete_rule ;;
            4) list_rules ;;
            5) manage_cron ;;
            6) manage_service ;;
            7) apply_saved_rules >/dev/null 2>&1; echo "刷新完成。" ;;
            8) manage_mwan ;;
            0) exit 0 ;;
            *) echo "无效输入。" ;;
        esac
    done
}

case "$1" in
    apply) apply_saved_rules >/dev/null 2>&1 ;;
    ddns_update) refresh_ddns_rules ;;
    mwan_daemon) mwan_daemon ;;
    *) main_menu ;;
esac
