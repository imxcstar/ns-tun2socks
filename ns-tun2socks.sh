#!/usr/bin/env bash
set -euo pipefail

LOG_LEVEL="NONE"

log() {
  local level="$1"
  shift
  local msg="$*"

  # 定义各级别的优先级数值
  declare -A LEVELS=( ["DEBUG"]=0 ["INFO"]=1 ["WARN"]=2 ["ERROR"]=3 ["NONE"]=4 )

  # 若未定义或非法级别，则默认为 INFO
  [[ -z "${LEVELS[$level]}" ]] && level="INFO"

  # 仅当当前日志级别 <= 设置的全局级别时输出
  if (( ${LEVELS[$level]} >= ${LEVELS[$LOG_LEVEL]} )); then
    # 给不同级别添加颜色和标签
    case "$level" in
      DEBUG) echo -e "\033[36m[DEBUG]\033[0m $msg" ;;
      INFO)  echo -e "\033[32m[INFO]\033[0m  $msg" ;;
      WARN)  echo -e "\033[33m[WARN]\033[0m  $msg" ;;
      ERROR) echo -e "\033[31m[ERROR]\033[0m $msg" ;;
    esac
  fi
}

log_info()  { log INFO "$@"; }
log_warn()  { log WARN "$@"; }
log_error() { log ERROR "$@"; }
log_debug() { log DEBUG "$@"; }

# ========== 默认配置 ==========
CONFIG_FILE="./ns_tun2socks.json"
SOCKS_ADDR=""
UDP_SUPPORT=false
TUN2SOCKS_BIN="./go-tun2socks"
DNS2SOCKS_BIN=""

BYPASS_DESTS=("192.168.0.0/16")
BYPASS_PORTS=()
FORWARD_PORTS=()  # HOST_PORT:NS_PORT[:proto]

# 策略路由常量
BYPASS_FWMARK_HEX=0x1
PROXY_FLOW_FWMARK_HEX=0x66     # 给 go-tun2socks 的 fwmark
BYPASS_RT_TABLE=100
PROXY_RT_TABLE=101             # 专供到 SOCKS 的强制表/直连表

# ========== 参数解析 ==========
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG_FILE="$2"; shift 2;;
    --socks) SOCKS_ADDR="$2"; shift 2;;
    --tun2socks) TUN2SOCKS_BIN="$2"; shift 2;;
    --dns2socks) DNS2SOCKS_BIN="$2"; shift 2;;
    --forward) FORWARD_PORTS+=("$2"); shift 2;;
    --log-level) LOG_LEVEL=$(echo "$2" | tr '[:lower:]' '[:upper:]'); shift 2;;
    --) shift; break;;
    *) break;;
  esac
done

TARGET_CMD=("$@")
if [ ${#TARGET_CMD[@]} -eq 0 ]; then
  echo "用法:"
  echo "  sudo $0 [--config file] [--socks host:port] [--tun2socks path] [--dns2socks path] [--forward host_port:ns_port[:proto]] [--log-level INFO|WARN|ERROR|DEBUG] -- <命令>"
  echo "示例:"
  echo "  sudo $0 --socks 10.200.200.1:1080 --forward 8080:80 -- /usr/bin/python3 -m http.server 80"
  exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
  log_error "必须以 root 运行"
  exit 1
fi

command -v jq >/dev/null || { log_error "需要 jq 解析 JSON"; exit 1; }
command -v ip >/dev/null || { log_error "需要 ip 命令"; exit 1; }
command -v socat >/dev/null || { log_error "需要 socat 进行端口转发"; exit 1; }

# ========== 读取配置 ==========
if [ -f "$CONFIG_FILE" ]; then
  log_info "📖 读取配置文件: $CONFIG_FILE"
  SOCKS_ADDR_CONF=$(jq -r '.socks // empty' "$CONFIG_FILE" || true)
  UDP_SUPPORT=$(jq -r '.udp // false' "$CONFIG_FILE" || echo false)
  BYPASS_DESTS_JSON=$(jq -r '.bypass_dests // empty' "$CONFIG_FILE" || true)
  BYPASS_PORTS_JSON=$(jq -r '.bypass_ports // empty' "$CONFIG_FILE" || true)
  FORWARDS_JSON=$(jq -r '.forwards // empty' "$CONFIG_FILE" || true)
  TUN2SOCKS_CONF=$(jq -r '.tun2socks // empty' "$CONFIG_FILE" || true)
  DNS2SOCKS_CONF=$(jq -r '.dns2socks // empty' "$CONFIG_FILE" || true)

  [ -z "$SOCKS_ADDR" ] && [ -n "$SOCKS_ADDR_CONF" ] && SOCKS_ADDR="$SOCKS_ADDR_CONF"
  [ -z "$TUN2SOCKS_BIN" ] && [ -n "$TUN2SOCKS_CONF" ] && TUN2SOCKS_BIN="$TUN2SOCKS_CONF"
  [ -z "$DNS2SOCKS_BIN" ] && [ -n "$DNS2SOCKS_CONF" ] && DNS2SOCKS_BIN="$DNS2SOCKS_CONF"

  if [ -n "$BYPASS_DESTS_JSON" ] && [ "$BYPASS_DESTS_JSON" != "null" ]; then
    mapfile -t BYPASS_DESTS < <(jq -r '.bypass_dests[]' "$CONFIG_FILE")
  fi
  if [ -n "$BYPASS_PORTS_JSON" ] && [ "$BYPASS_PORTS_JSON" != "null" ]; then
    mapfile -t BYPASS_PORTS < <(jq -r '.bypass_ports[]' "$CONFIG_FILE")
  fi
  if [ -n "$FORWARDS_JSON" ] && [ "$FORWARDS_JSON" != "null" ]; then
    mapfile -t FORWARD_PORTS < <(jq -r '.forwards[]' "$CONFIG_FILE")
  fi
fi

# ========== 默认二进制路径 ==========
[ -z "$TUN2SOCKS_BIN" ] && TUN2SOCKS_BIN=$(command -v badvpn-tun2socks || command -v tun2socks || true)
[ -z "$DNS2SOCKS_BIN" ] && DNS2SOCKS_BIN=$(command -v dns2socks || true)

[ -z "$SOCKS_ADDR" ] && { log_error "❌ 必须指定 SOCKS5 地址"; exit 1; }
[ -z "$TUN2SOCKS_BIN" ] && { log_error "❌ 未找到 tun2socks 程序，请用 --tun2socks 指定路径"; exit 1; }

# ========== 动态命名 ==========
RAND=$RANDOM
NS_NAME="ns-tun2socks-$RAND"
VETH_HOST="veth-host-$RAND"
VETH_NS="veth-ns-$RAND"
LOG_FILE="/tmp/tun2socks_$RAND.log"
DNS2SOCKS_LOG="/tmp/dns2socks_$RAND.log"

# 随机生成 10.x.y.0/24 子网
OCTET2=$((RANDOM % 256))
OCTET3=$((RANDOM % 256))
VETH_SUBNET="10.${OCTET2}.${OCTET3}.0/24"

# 随机选择主机与NS IP
HOST_IP="10.${OCTET2}.${OCTET3}.1"
NS_IP="10.${OCTET2}.${OCTET3}.2"

# 随机生成 TUN 接口名（防冲突）
TUN_NAME="tun$((RANDOM % 9000 + 1000))"
TUN_IP="10.255.$((RANDOM % 250 + 1)).$((RANDOM % 250 + 1))"
TUN_MASK="255.255.255.0"
TUN_MTU="1480"

log_info "🧮 随机生成网络参数："
log_info "   VETH_SUBNET=$VETH_SUBNET"
log_info "   HOST_IP=$HOST_IP"
log_info "   NS_IP=$NS_IP"
log_info "   TUN_NAME=$TUN_NAME"
log_info "   TUN_IP=$TUN_IP"

# 提早检测 tun2socks 类型，以决定 DNS 策略
IS_GO_TUN2SOCKS=false
if "$TUN2SOCKS_BIN" -h 2>&1 | grep -q "\-proxy"; then
  IS_GO_TUN2SOCKS=true
fi

DNS_NS_IP="127.0.0.1" # 默认，badvpn 模式
USE_DNS2SOCKS=true

if [ "$IS_GO_TUN2SOCKS" = true ]; then
  log_info "ℹ️  检测到 go-tun2socks，将由 tun2socks 自动处理 DNS"
  DNS_NS_IP="8.8.8.8" # go-tun2socks 会拦截此流量并代理
  USE_DNS2SOCKS=false
  if [ -n "$DNS2SOCKS_BIN" ]; then
    log_warn "⚠️  --dns2socks 参数 ($DNS2SOCKS_BIN) 将被忽略"
    DNS2SOCKS_BIN="" # 强制禁用
  fi
else
  log_info "ℹ️  检测到 badvpn-tun2socks (或未知类型)，需要 dns2socks"
  if [ -z "$DNS2SOCKS_BIN" ]; then
    log_error "❌ badvpn-tun2socks 模式下必须提供 --dns2socks"
    exit 1
  fi
fi

# ========== 清理 ==========
cleanup() {
  log_info "🧹 清理中..."
  pkill -f "socat TCP-LISTEN" 2>/dev/null || true
  pkill -f "socat UDP-LISTEN" 2>/dev/null || true

  # 策略路由清理（在 netns 内）
  ip netns exec "$NS_NAME" bash -c "
    ip rule del fwmark $BYPASS_FWMARK_HEX table $BYPASS_RT_TABLE 2>/dev/null || true
    ip route flush table $BYPASS_RT_TABLE 2>/dev/null || true
    ip rule del to ${SOCKS_IP:-0.0.0.0}/32 table $PROXY_RT_TABLE pref 100 2>/dev/null || true
    ip rule del fwmark $PROXY_FLOW_FWMARK_HEX table $PROXY_RT_TABLE pref 90 2>/dev/null || true
    ip route flush table $PROXY_RT_TABLE 2>/dev/null || true
  " 2>/dev/null || true

  ip netns pids "$NS_NAME" 2>/dev/null | xargs -r kill -9  >/dev/null 2>&1 || true
  wait 2>/dev/null || true
  ip link del "$VETH_HOST" 2>/dev/null || true
  ip netns del "$NS_NAME" 2>/dev/null || true
  rm -rf /etc/netns/"$NS_NAME" 2>/dev/null || true

  # 主机侧规则回滚
  iptables -t nat -D POSTROUTING -s "$VETH_SUBNET" -j MASQUERADE 2>/dev/null || true
  iptables -D FORWARD -i "$VETH_HOST" -j ACCEPT 2>/dev/null || true
  iptables -D FORWARD -o "$VETH_HOST" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
  sysctl -w net.ipv4.ip_forward=0 >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

# ========== 创建命名空间 ==========
log_info "⚙️ 创建 network namespace: $NS_NAME"
ip netns add "$NS_NAME"
ip link add "$VETH_HOST" type veth peer name "$VETH_NS"
ip link set "$VETH_NS" netns "$NS_NAME"

ip addr add "$HOST_IP/24" dev "$VETH_HOST"
ip link set "$VETH_HOST" up
ip netns exec "$NS_NAME" ip addr add "$NS_IP/24" dev "$VETH_NS"
ip netns exec "$NS_NAME" ip link set "$VETH_NS" up
ip netns exec "$NS_NAME" ip link set lo up

# netns 内内核参数优化
ip netns exec "$NS_NAME" sysctl -qw net.ipv4.conf.all.rp_filter=0
ip netns exec "$NS_NAME" sysctl -qw net.ipv4.conf.default.rp_filter=0
ip netns exec "$NS_NAME" sysctl -qw net.ipv4.conf.$VETH_NS.rp_filter=0
ip netns exec "$NS_NAME" sysctl -qw net.ipv4.conf.all.src_valid_mark=1
ip netns exec "$NS_NAME" sysctl -qw net.ipv6.conf.all.disable_ipv6=1

# 根据 DNS 策略写入 resolv.conf
mkdir -p /etc/netns/"$NS_NAME"
log_info "DNS nameserver set to: $DNS_NS_IP"
cat >/etc/netns/"$NS_NAME"/resolv.conf <<EOF
options use-vc single-request attempts:10 timeout:10 ndots:1
nameserver $DNS_NS_IP
EOF

# ========== 启用 NAT（规则置前）==========
sysctl -w net.ipv4.ip_forward=1 >/dev/null
iptables -I FORWARD -i "$VETH_HOST" -j ACCEPT
iptables -I FORWARD -o "$VETH_HOST" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -t nat -I POSTROUTING -s "$VETH_SUBNET" -j MASQUERADE

# ========== 预设“临时默认路由”为直连（保证前期连 SOCKS 稳定）==========
ip netns exec "$NS_NAME" ip route replace default via "$HOST_IP" dev "$VETH_NS"
log_info "🛣️  临时默认路由: default via $HOST_IP dev $VETH_NS"

# ========== 启动 tun2socks ==========
log_info "🚀 启动 tun2socks..."
log_info "   命名空间: $NS_NAME"
log_info "   SOCKS 地址: $SOCKS_ADDR"
log_info "   设备: $TUN_NAME"
log_info "   日志文件: $LOG_FILE"

# 脚本中原有的 if/else 逻辑已经正确区分了 go-tun2socks 和 badvpn
if [ "$IS_GO_TUN2SOCKS" = true ]; then
  log_info "   🔧 使用 go-tun2socks 参数格式"
  ip netns exec "$NS_NAME" "$TUN2SOCKS_BIN" \
    -device "tun://$TUN_NAME" \
    -interface "$VETH_NS" \
    -proxy "socks5://$SOCKS_ADDR" \
    -fwmark "$PROXY_FLOW_FWMARK_HEX" \
    -mtu "$TUN_MTU" \
    -loglevel info >>"$LOG_FILE" 2>&1 &
else
  log_info "   🔧 使用 badvpn-tun2socks 参数格式"
  ip netns exec "$NS_NAME" "$TUN2SOCKS_BIN" \
    --tundev "$TUN_NAME" \
    --netif-ipaddr "$TUN_IP" \
    --netif-netmask "$TUN_MASK" \
    --socks-server-addr "$SOCKS_ADDR" >>"$LOG_FILE" 2>&1 &
fi

# 等 tun 设备就绪
for i in {1..20}; do
  if ip netns exec "$NS_NAME" ip link show "$TUN_NAME" >/dev/null 2>&1; then
    break
  fi
  sleep 0.25
done
if ! ip netns exec "$NS_NAME" ip link show "$TUN_NAME" >/dev/null 2>&1; then
  log_error "❌ tun2socks 启动失败 (查看日志 $LOG_FILE)"
  exit 1
fi
log_info "✅ tun2socks 已启动成功"

ip netns exec "$NS_NAME" ip link set "$TUN_NAME" up
ip netns exec "$NS_NAME" ip addr add "$TUN_IP/24" dev "$TUN_NAME" 2>/dev/null || true
ip netns exec "$NS_NAME" ip link set "$TUN_NAME" mtu "$TUN_MTU" 2>/dev/null || true

# 仅在需要时 (badvpn 模式) 才启动 DNS2SOCKS
if [ "$USE_DNS2SOCKS" = true ]; then
  log_info "🧠 准备启动 dns2socks..."
  DNS_LOCAL="127.0.0.1:53"
  DNS_REMOTE="8.8.8.8:53" # 你可以修改为你偏好的上游 DNS

  if [ "$UDP_SUPPORT" = true ]; then
    log_info "🌍 启动 DNS2SOCKS (UDP 模式)"
    ip netns exec "$NS_NAME" "$DNS2SOCKS_BIN" \
      -s "socks5://$SOCKS_ADDR" \
      -d "$DNS_REMOTE" \
      -l "$DNS_LOCAL" \
      -v info -t 8 >>"$DNS2SOCKS_LOG" 2>&1 &
  else
    log_info "🌍 启动 DNS2SOCKS (TCP 模式)"
    ip netns exec "$NS_NAME" "$DNS2SOCKS_BIN" \
      -s "socks5://$SOCKS_ADDR" \
      -d "$DNS_REMOTE" \
      -l "$DNS_LOCAL" \
      -v info -f -t 8 >>"$DNS2SOCKS_LOG" 2>&1 &
  fi

  # 等待本地 53 监听
  log_info "⏳ 等待 dns2socks 启动..."
  for i in {1..20}; do
    if ip netns exec "$NS_NAME" bash -c "timeout 1 bash -c '</dev/tcp/127.0.0.1/53'" 2>/dev/null; then
      log_info "✅ dns2socks 已监听 127.0.0.1:53"
      break
    fi
    sleep 0.25
  done

  # SOCKS 可达（直连路径，此时默认还在 veth）
  SOCKS_IP=$(echo "$SOCKS_ADDR" | cut -d: -f1)
  SOCKS_PORT=$(echo "$SOCKS_ADDR" | cut -d: -f2)
  log_info "🔌 等待 SOCKS $SOCKS_ADDR 可达..."
  ip netns exec "$NS_NAME" bash -lc '
  for i in {1..30}; do
    timeout 1 bash -lc "</dev/tcp/'"$SOCKS_IP"'/'"$SOCKS_PORT"'" && exit 0
    sleep 0.5
  done
  exit 1
  ' || { log_error "❌ 无法连接 SOCKS $SOCKS_ADDR"; exit 1; }

  # DNS 实际解析健康探测（切默认路由前）
  log_info "🔍 等待 DNS 可用（实际解析，切换前）..."
  ip netns exec "$NS_NAME" bash -lc '
  for i in {1..30}; do
    if command -v dig >/dev/null 2>&1; then
      dig +tcp +time=1 +retry=0 @127.0.0.1 example.com >/dev/null 2>&1 && exit 0
    elif command -v nslookup >/dev/null 2>&1; then
      nslookup -timeout=1 -vc example.com 127.0.0.1 >/dev/null 2>&1 && exit 0
    else
      timeout 1 bash -lc "</dev/tcp/127.0.0.1/53" && exit 0
    fi
    sleep 0.5
  done
  exit 1
  ' || { log_error "❌ DNS 仍不可用（经 socks）"; exit 1; }

  log_info "✅ dns2socks 已启动完成"
  log_info "   协议: $([ "$UDP_SUPPORT" = true ] && echo UDP || echo TCP)"
  log_info "   本地监听: $DNS_LOCAL"
  log_info "   上游 DNS: $DNS_REMOTE"
  log_info "   日志文件: $DNS2SOCKS_LOG"
else
  # go-tun2socks 模式下，我们仍然需要检查 SOCKS 可达性
  SOCKS_IP=$(echo "$SOCKS_ADDR" | cut -d: -f1)
  SOCKS_PORT=$(echo "$SOCKS_ADDR" | cut -d: -f2)
  log_info "🔌 (go-tun2socks 模式) 等待 SOCKS $SOCKS_ADDR 可达..."
  ip netns exec "$NS_NAME" bash -lc '
  for i in {1..30}; do
    timeout 1 bash -lc "</dev/tcp/'"$SOCKS_IP"'/'"$SOCKS_PORT"'" && exit 0
    sleep 0.5
  done
  exit 1
  ' || { log_error "❌ 无法连接 SOCKS $SOCKS_ADDR (go-tun2socks 模式)"; exit 1; }
  log_info "✅ SOCKS 可达"
fi

# ========== 为 SOCKS 建立强制路由表与规则（始终走 veth）==========
SOCKS_IP=$(echo "$SOCKS_ADDR" | cut -d: -f1)
ip netns exec "$NS_NAME" bash -lc "
  ip route replace default via $HOST_IP dev $VETH_NS table $PROXY_RT_TABLE
  ip rule add to $SOCKS_IP/32 table $PROXY_RT_TABLE pref 100 2>/dev/null || true
  ip rule add fwmark $PROXY_FLOW_FWMARK_HEX table $PROXY_RT_TABLE pref 90 2>/dev/null || true
  ip route replace $SOCKS_IP/32 via $HOST_IP dev $VETH_NS 2>/dev/null || true
"
log_info "🧭 已建立 SOCKS 强制路由：to $SOCKS_IP/32 table $PROXY_RT_TABLE (via $HOST_IP dev $VETH_NS) + fwmark $PROXY_FLOW_FWMARK_HEX"

# ========== 现在切换默认路由到 tun ==========
ip netns exec "$NS_NAME" ip route replace default dev "$TUN_NAME"
log_info "🛣️  默认路由切换：default dev $TUN_NAME"

# 切换后做一次真实解析健康检查，不通过则回滚
# 不再硬编码 @127.0.0.1，使其自动使用 resolv.conf
log_info "🔍 等待 DNS 可用（实际解析，切换后）..."
ip netns exec "$NS_NAME" bash -lc '
for i in {1..20}; do
  if command -v dig >/dev/null 2>&1; then
    # 使用 resolv.conf (go-tun2socks 会查 8.8.8.8, badvpn 会查 127.0.0.1)
    dig +tcp +time=2 +retry=0 google.com >/dev/null 2>&1 && exit 0
  elif command -v nslookup >/dev/null 2>&1; then
    nslookup -timeout=2 -vc google.com >/dev/null 2>&1 && exit 0
  else
    # 在 go-tun2socks 模式下，如果没有 dig/nslookup，我们无法简单检查
    # 只能假设 SOCKS 可达 = DNS 可达
    echo " (无 dig/nslookup，跳过 post-check)" >&2
    exit 0
  fi
  sleep 0.3
done
exit 1
' || {
  log_error "❌ 路由切换后 DNS 不健康，回滚默认路由到 veth";
  ip netns exec "$NS_NAME" ip route replace default via "$HOST_IP" dev "$VETH_NS"
  exit 1
}
log_info "✅ 路由切换后 DNS 健康"

# ========== 直连路由 ==========
for dest in "${BYPASS_DESTS[@]}"; do
  ip netns exec "$NS_NAME" ip route replace "$dest" via "$HOST_IP" dev "$VETH_NS" || true
done

# ========== 直连端口策略路由 ==========
if [ ${#BYPASS_PORTS[@]} -gt 0 ]; then
  log_info "🔒 设置直连端口策略路由..."
  ip netns exec "$NS_NAME" ip route replace default via "$HOST_IP" dev "$VETH_NS" table "$BYPASS_RT_TABLE"
  ip netns exec "$NS_NAME" ip rule add fwmark "$BYPASS_FWMARK_HEX" table "$BYPASS_RT_TABLE" || true
  ip netns exec "$NS_NAME" iptables -t mangle -N BYPASS_PORTS 2>/dev/null || true
  ip netns exec "$NS_NAME" iptables -t mangle -F BYPASS_PORTS || true
  for port in "${BYPASS_PORTS[@]}"; do
    ip netns exec "$NS_NAME" iptables -t mangle -A BYPASS_PORTS -p tcp --dport "$port" -j MARK --set-mark "$BYPASS_FWMARK_HEX"
    ip netns exec "$NS_NAME" iptables -t mangle -A BYPASS_PORTS -p udp --dport "$port" -j MARK --set-mark "$BYPASS_FWMARK_HEX"
  done
  ip netns exec "$NS_NAME" bash -c '
    iptables -t mangle -D OUTPUT -j BYPASS_PORTS 2>/dev/null || true
    iptables -t mangle -A OUTPUT -j BYPASS_PORTS
  '
fi

# ========== 端口转发 ==========
if [ ${#FORWARD_PORTS[@]} -gt 0 ]; then
  log_info "🔁 设置端口转发..."
  for mapping in "${FORWARD_PORTS[@]}"; do
    IFS=':' read -r HOST_PORT NS_PORT PROTO <<<"$mapping"
    PROTO=${PROTO:-tcp}
    if [ "$PROTO" = "udp" ]; then
      log_info "  ↔️ UDP $HOST_PORT -> $NS_PORT"
      socat UDP-LISTEN:"$HOST_PORT",fork,reuseaddr EXEC:"ip netns exec $NS_NAME socat STDIO UDP:127.0.0.1:$NS_PORT" &
    else
      log_info "  ↔️ TCP $HOST_PORT -> $NS_PORT"
      socat TCP-LISTEN:"$HOST_PORT",fork,reuseaddr EXEC:"ip netns exec $NS_NAME socat STDIO TCP:127.0.0.1:$NS_PORT" &
    fi
  done
fi

# ========== 运行目标命令 ==========
log_info "▶️ 启动目标程序: ${TARGET_CMD[*]}"
if ip netns exec "$NS_NAME" "${TARGET_CMD[@]}"; then
  log_info "✅ 目标程序结束，清理完成"

  # 清理日志文件（仅在正常退出时）
  log_info "🧽 清理日志文件..."
  rm -f "$LOG_FILE" "$DNS2SOCKS_LOG" 2>/dev/null || true
else
  log_error "❌ 目标程序异常退出，保留日志文件: "
  [[ -f "$LOG_FILE" ]] && log_error "❌ $LOG_FILE"
  [[ -f "$DNS2SOCKS_LOG" ]] && log_error "❌ $DNS2SOCKS_LOG"
fi