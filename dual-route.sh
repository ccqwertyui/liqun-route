#!/bin/bash
# ==============================================================================
# 多出口策略路由管理脚本 (PBR) v4.5
# 支持: 双线/多线策略路由 | 端口精准分流 | NAT地址伪装 | 开机自启 | DDNS动态解析
# ==============================================================================

# --- 全局检查与环境初始化 ---
if [[ $EUID -ne 0 ]]; then
   echo "错误: 此脚本必须以 root 权限运行。"
   exit 1
fi

# 兼容 Debian 13 / Trixie 路由表路径
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
RT_TABLES_FILE="/etc/iproute2/rt_tables"
SERVICE_FILE="/etc/systemd/system/custom-routing.service"

touch "$CONFIG_FILE"
touch "$DDNS_CONFIG_FILE"

# --- 预定义线路规则 (可自行扩展) ---
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

# --- 自动安装与快捷指令绑定 ---
function check_self_install() {
    local script_base="$(basename "$0" 2>/dev/null)"
    
    if [ -f "$0" ] && [[ "$script_base" != "bash" && "$script_base" != "sh" ]]; then
        local current_script="$(realpath "$0")"
        if [ "$current_script" != "$INSTALL_PATH" ]; then
            cp -f "$current_script" "$INSTALL_PATH"
            chmod +x "$INSTALL_PATH"
        fi
    else
        # 兼容 curl 管道执行：通过检查首行判断目标文件是否损坏
        if [ ! -f "$INSTALL_PATH" ] || ! head -n 1 "$INSTALL_PATH" 2>/dev/null | grep -q "#!/bin/bash"; then
            curl -fsSL https://raw.githubusercontent.com/ccqwertyui/liqun-route/refs/heads/main/dual-route.sh -o "$INSTALL_PATH" 2>/dev/null || true
            chmod +x "$INSTALL_PATH" 2>/dev/null || true
        fi
    fi

    # 只有当安装文件正常时，才绑定 ly 快捷命令
    if [ -f "$INSTALL_PATH" ] && head -n 1 "$INSTALL_PATH" 2>/dev/null | grep -q "#!/bin/bash"; then
        if [ ! -f "$ALIAS_PATH" ] || [ "$(realpath "$ALIAS_PATH" 2>/dev/null)" != "$INSTALL_PATH" ]; then
            cat << EOF > "$ALIAS_PATH"
#!/bin/bash
exec $INSTALL_PATH "\$@"
EOF
            chmod +x "$ALIAS_PATH"
            echo -e "\033[32m[提示] 已成功安装全局快捷指令 'ly'！以后输入 ly 即可调出菜单。\033[0m\n"
        fi
    fi
}

# --- 多网关冲突修复 ---
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

# --- 动态线路检测 ---
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

# --- 初始化自定义策略路由表 ---
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
        echo "错误: 未检测到任何可用线路网关。"
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
    read -p "请输入线路对应的数字: " choice < /dev/tty
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "$count" ]; then
        echo "错误: 无效的选项数字。"
        SELECTED_ROUTE_IDX=-1
        return 1
    fi
    SELECTED_ROUTE_IDX=$((choice - 1))
    return 0
}

# --- 规则管理逻辑 ---
function add_rule() {
    select_route_group || return 1
    local selected_name="${FOUND_NAMES[$SELECTED_ROUTE_IDX]}"
    if [ -z "$selected_name" ]; then return 1; fi
    
    local cidr
    echo ""
    read -p "请输入目标IP或网段 (例如 8.8.8.8/32): " cidr < /dev/tty
    if [ -z "$cidr" ]; then echo "错误: 输入不能为空。"; return 1; fi
    if ! [[ "$cidr" == */* ]]; then cidr="${cidr}/32"; fi

    local proto
    read -p "请输入协议 (tcp/udp/all, 默认all): " proto < /dev/tty
    proto=${proto:-all}
    if [[ "$proto" != "tcp" && "$proto" != "udp" && "$proto" != "all" ]]; then
        echo "错误: 协议只能是 tcp, udp 或 all。"
        return 1
    fi

    local port="all"
    if [[ "$proto" != "all" ]]; then
        read -p "请输入目标端口 (例如 443, 留空表示所有端口): " port < /dev/tty
        port=${port:-all}
        if [[ "$port" != "all" && ! "$port" =~ ^[0-9]+$ ]]; then
            echo "错误: 端口必须是数字。"
            return 1
        fi
    fi

    local rule_line="${cidr} ${proto} ${port} ${selected_name}"

    if grep -qE "^${cidr}[[:space:]]+${proto}[[:space:]]+${port}[[:space:]]+${selected_name}$" "$CONFIG_FILE"; then
        echo "警告: 规则已存在。"
        return 1
    fi
    
    echo "$rule_line" >> "$CONFIG_FILE"
    echo "规则已保存。正在应用生效..."
    apply_saved_rules >/dev/null 2>&1
    echo "成功保存并生效。"
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

# --- 应用所有规则 (包含防火墙打标与 SNAT 地址伪装) ---
function apply_saved_rules() {
    detect_available_routes
    init_routing_tables
    
    while ip rule del priority $PRIO_STATIC 2>/dev/null; do :; done
    while ip rule del priority $PRIO_FWMARK 2>/dev/null; do :; done
    
    # 1. mangle 表链重建
    iptables -t mangle -D OUTPUT -j CUSTOM_PBR 2>/dev/null
    iptables -t mangle -D PREROUTING -j CUSTOM_PBR 2>/dev/null
    iptables -t mangle -F CUSTOM_PBR 2>/dev/null
    iptables -t mangle -X CUSTOM_PBR 2>/dev/null
    iptables -t mangle -N CUSTOM_PBR
    iptables -t mangle -A OUTPUT -j CUSTOM_PBR
    iptables -t mangle -A PREROUTING -j CUSTOM_PBR

    # 2. nat 表源地址伪装链重建
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
            local proto="all"
            local port="all"
            local name=""

            if [ "$col_count" -eq 2 ]; then
                name=$(echo "$rule" | awk '{print $2}')
            elif [ "$col_count" -ge 4 ]; then
                proto=$(echo "$rule" | awk '{print $2}')
                port=$(echo "$rule" | awk '{print $3}')
                name=$(echo "$rule" | awk '{print $4}')
            else
                continue
            fi
            
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

function list_rules() {
    echo "--- 静态规则 (${CONFIG_FILE}) ---"
    [ -s "$CONFIG_FILE" ] && cat "$CONFIG_FILE" || echo "无"
    echo -e "\n--- 防火墙端口映射规则 ---"
    iptables -t mangle -S CUSTOM_PBR 2>/dev/null || echo "无防火墙分流规则"
}

# --- 主菜单入口 ---
function main_menu() {
    check_self_install
    while true; do
        echo ""
        echo "========================================="
        echo "  多出口策略路由 v4.5"
        echo "========================================="
        echo "1. 添加静态路由 (IP/协议/端口)"
        echo "2. 添加动态路由 (DDNS 域名)"
        echo "3. 删除规则"
        echo "4. 查看所有配置"
        echo "5. 配置自动更新 (Cron/DDNS需要)"
        echo "6. 管理开机自启服务"
        echo "7. 强制刷新所有规则"
        echo "0. 退出"
        echo "-----------------------------------------"
        read -p "选择: " choice < /dev/tty
        case $choice in
            1) add_rule ;;
            2) add_ddns_rule ;;
            3) delete_rule ;;
            4) list_rules ;;
            5) manage_cron ;;
            6) manage_service ;;
            7) apply_saved_rules >/dev/null 2>&1; echo "刷新完成。" ;;
            0) exit 0 ;;
            *) echo "无效输入。" ;;
        esac
    done
}

case "$1" in
    apply) apply_saved_rules >/dev/null 2>&1 ;;
    ddns_update) refresh_ddns_rules ;;
    *) main_menu ;;
esac
