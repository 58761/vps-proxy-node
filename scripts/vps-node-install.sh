#!/usr/bin/env bash
# ==============================================================================
# VPS 多协议代理节点一键部署脚本 (单文件自包含)
# 支持协议: anytls, hy2, vless+xhttp+tls, vless+xhttp, vless+reality, ss2022
# 特性:
#   - 443 端口 TCP/UDP 由 Caddy (caddy-l4) 按 SNI 统一转发
#   - HTTP-01 自动证书签发与续期 (自动同步至 Hysteria2)
#   - 静态伪装网页与握手失败回落
#   - 分协议分用户流量监控与配额自动管控 (每 10 秒增量采样, SQLite WAL)
#   - 完整兼容《节点流量与用户管理 API》与 proxy-user CLI
# ==============================================================================
set -euo pipefail

SCRIPT_VERSION="1.2.0"
DEFAULT_REPO="${DEFAULT_REPO:-58761/vps-proxy-node}"
SCRIPT_URL="${SCRIPT_URL:-https://raw.githubusercontent.com/${DEFAULT_REPO}/main/scripts/vps-node-install.sh}"
RELEASE_BASE_URL="${RELEASE_BASE_URL:-https://github.com/${DEFAULT_REPO}/releases/download/latest}"
INSTALLED_SCRIPT="/usr/local/bin/vps-node-install"
STACK_DIR="/etc/proxy-stack"
APP_DIR="/opt/proxy-stack"
DATA_DIR="/var/lib/proxy-stack"
WEB_ROOT="/var/www/masquerade"
CERT_DIR="${STACK_DIR}/certs"

# 内部固定本地端口
PORT_ANYTLS_LOCAL=10443
PORT_XHTTP_TLS_LOCAL=10444
PORT_HY2_LOCAL=10445
PORT_XHTTP_LOCAL=10446
PORT_CADDY_MASQ_HTTP=18080
PORT_CADDY_L7_HTTPS=18443
PORT_XRAY_STATS=10085
PORT_SINGBOX_STATS=10086
PORT_HY2_STATS=25413
PORT_API_LOCAL=19090

# 默认配置（支持环境变量覆盖）
NON_INTERACTIVE="${NON_INTERACTIVE:-0}"
MAIN_DOMAIN="${MAIN_DOMAIN:-}"
ACME_EMAIL="${ACME_EMAIL:-}"
TIMEZONE="${TIMEZONE:-Asia/Shanghai}"
RESET_DAY="${RESET_DAY:-1}"
SELECTED_PROTOCOLS="${SELECTED_PROTOCOLS:-}"
ANYTLS_DOMAIN="${ANYTLS_DOMAIN:-}"
HY2_DOMAIN="${HY2_DOMAIN:-}"
HY2_HOP_RANGE="${HY2_HOP_RANGE:-}"
XHTTP_TLS_DOMAIN="${XHTTP_TLS_DOMAIN:-}"
XHTTP_TLS_PATH="${XHTTP_TLS_PATH:-}"
XHTTP_PORT="${XHTTP_PORT:-}"
XHTTP_PATH="${XHTTP_PATH:-}"
REALITY_PORT="${REALITY_PORT:-}"
REALITY_DEST="${REALITY_DEST:-}"
REALITY_SNI="${REALITY_SNI:-}"
REALITY_PRIV="${REALITY_PRIV:-}"
REALITY_PUB="${REALITY_PUB:-}"
REALITY_SID="${REALITY_SID:-}"
SS2022_PORT="${SS2022_PORT:-}"
SS2022_SERVER_PSK="${SS2022_SERVER_PSK:-}"
HY2_STATS_SECRET="${HY2_STATS_SECRET:-}"

# 增量模式与更新状态变量
INCREMENTAL_MODE=0
EXISTING_PROTOCOLS_CSV=""
ADD_PROTOCOLS_ARG=""
REMOVE_PROTOCOLS_ARG=""
FORCE_REINSTALL=0
DO_UPGRADE=0
UPGRADE_TARGET="all"
DO_SELF_UPDATE=0

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

usage() {
  cat <<'EOF'
用法:
  sudo bash vps-node-install.sh [选项]

选项:
  --add <protos>             增量添加协议 (逗号分隔, 例: --add vless_reality,ss2022)
  --remove <protos>          增量移除协议 (逗号分隔, 例: --remove hy2)
  --upgrade [target]         手动更新已安装的内核 (all|caddy|sing-box|hy2|xray, 默认 all)
  --self-update              更新部署脚本自身到最新版本
  --non-interactive          非交互模式（通过环境变量传入参数）
  --reinstall                忽略现有配置，执行全新覆盖安装
  --uninstall                卸载所有已安装的代理服务与配置
  --version                  显示脚本版本
  -h, --help                 显示此帮助信息

说明:
  若检测到 /etc/proxy-stack/config.json 已存在（且未指定 --reinstall），脚本将
  自动进入增量模式：保留已有协议的域名、端口、路径、密钥及现有用户数据，仅补齐
  新增协议的二进制与配置并重载服务，现有用户将自动获得新协议的可用链接。

常用环境变量 (非交互模式):
  MAIN_DOMAIN                主域名 (首次安装必填, 例: de.example.com)
  ACME_EMAIL                 ACME 证书邮箱 (可选, 默认 admin@<MAIN_DOMAIN>)
  SELECTED_PROTOCOLS         逗号分隔的协议列表:
                             anytls,hy2,vless_xhttp_tls,vless_xhttp,vless_reality,ss2022
  ANYTLS_DOMAIN              AnyTLS 域名 (默认 ats.<MAIN_DOMAIN>)
  HY2_DOMAIN                 Hysteria2 域名 (默认 <MAIN_DOMAIN>)
  HY2_HOP_RANGE              Hysteria2 端口跳跃 UDP 范围 (可选, 如 20000-50000 或 none)
  XHTTP_TLS_DOMAIN           VLESS+XHTTP+TLS 域名 (默认 xhttp.<MAIN_DOMAIN>)
  XHTTP_PORT                 VLESS+XHTTP 端口 (默认随机 20000-55000)
  REALITY_PORT               VLESS+Reality 端口 (默认随机 20000-55000)
  REALITY_DEST               Reality 回落目标 (默认 127.0.0.1:18443 本机伪装站)
  REALITY_SNI                Reality SNI (默认 <MAIN_DOMAIN>)
  SS2022_PORT                SS2022 端口 (默认随机 20000-55000)
  TIMEZONE                   统计时区 (默认 Asia/Shanghai)
  RESET_DAY                  月配额重置日 1-28 (默认 1)
EOF
}

# ==============================================================================
# 参数解析与卸载
# ==============================================================================
DO_UNINSTALL=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --add)
      [[ $# -lt 2 ]] && { log_err "--add 需要指定协议列表"; exit 1; }
      ADD_PROTOCOLS_ARG="$2"; shift 2 ;;
    --remove)
      [[ $# -lt 2 ]] && { log_err "--remove 需要指定协议列表"; exit 1; }
      REMOVE_PROTOCOLS_ARG="$2"; shift 2 ;;
    --upgrade)
      DO_UPGRADE=1
      if [[ $# -ge 2 && "$2" != --* ]]; then
        UPGRADE_TARGET="$2"; shift 2
      else
        shift
      fi
      ;;
    --self-update) DO_SELF_UPDATE=1; shift ;;
    --non-interactive) NON_INTERACTIVE=1; shift ;;
    --reinstall) FORCE_REINSTALL=1; shift ;;
    --uninstall) DO_UNINSTALL=1; shift ;;
    --version) echo "vps-node-install.sh v${SCRIPT_VERSION}"; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *) log_err "未知参数: $1"; usage; exit 1 ;;
  esac
done

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    log_err "请使用 root 权限运行此脚本 (例如: sudo bash $0)"
    exit 1
  fi
}

do_uninstall() {
  require_root
  log_warn "即将停止并移除所有代理节点服务与配置..."
  local services=(proxy-manager caddy sing-box-proxy hysteria-proxy xray-proxy hy2-port-hopping)
  for svc in "${services[@]}"; do
    systemctl stop "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
    rm -f "/etc/systemd/system/${svc}.service"
  done
  systemctl daemon-reload 2>/dev/null || true
  rm -rf "$STACK_DIR" "$APP_DIR" "$DATA_DIR" "$WEB_ROOT" /usr/local/bin/proxy-user /etc/sysctl.d/99-proxy-stack.conf
  sysctl --system >/dev/null 2>&1 || true
  log_ok "卸载完成（二进制文件 /usr/local/bin/{caddy,xray,sing-box,hysteria,grpcurl} 已保留，如需彻底清理可手动删除）。"
  exit 0
}

if [[ "$DO_UNINSTALL" -eq 1 ]]; then
  do_uninstall
fi

# ==============================================================================
# 系统检查与基础依赖安装
# ==============================================================================
detect_system() {
  if ! command -v systemctl >/dev/null 2>&1; then
    log_err "未检测到 systemd，本脚本需要 systemd 环境。"
    exit 1
  fi

  local machine
  machine="$(uname -m)"
  case "$machine" in
    x86_64|amd64)
      ARCH="amd64"
      XRAY_ARCH="64"
      GRPCURL_ARCH="x86_64"
      ;;
    aarch64|arm64)
      ARCH="arm64"
      XRAY_ARCH="arm64-v8a"
      GRPCURL_ARCH="arm64"
      ;;
    *)
      log_err "不支持的 CPU 架构: ${machine} (仅支持 amd64/arm64)"
      exit 1
      ;;
  esac

  if command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
  else
    log_err "不支持的包管理器，仅支持 Debian/Ubuntu (apt) 或 RHEL/CentOS/Rocky/Alma (dnf/yum)。"
    exit 1
  fi
  log_info "系统架构: ${ARCH} | 包管理器: ${PKG_MGR}"
}

install_base_deps() {
  log_info "安装基础依赖 (curl, tar, unzip, jq, python3, sqlite3, openssl)..."
  if [[ "$PKG_MGR" == "apt" ]]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq curl tar unzip jq python3 sqlite3 openssl ca-certificates iproute2 tzdata >/dev/null
  else
    "$PKG_MGR" install -y -q curl tar unzip jq python3 sqlite openssl ca-certificates iproute tzdata >/dev/null
  fi

  local py_ok
  py_ok="$(python3 -c 'import sys; print(1 if sys.version_info >= (3, 9) else 0)')"
  if [[ "$py_ok" != "1" ]]; then
    log_err "需要 Python 3.9 及以上版本 (当前: $(python3 --version))"
    exit 1
  fi
  log_ok "基础依赖就绪 ($(python3 --version))"
}

# ==============================================================================
# 工具函数
# ==============================================================================
is_port_in_use() {
  local port="$1"
  ss -tuln 2>/dev/null | awk '{print $5}' | grep -qE "[:.]${port}$"
}

random_free_port() {
  local p
  for _ in $(seq 1 50); do
    p="$(shuf -i 20000-55000 -n 1)"
    if ! is_port_in_use "$p"; then
      echo "$p"
      return 0
    fi
  done
  echo "28443"
}

random_hex() {
  openssl rand -hex "$1"
}

random_b64_16() {
  openssl rand -base64 16
}

proto_enabled() {
  local target="$1"
  [[ ",${ENABLED_PROTOCOLS_CSV}," == *",${target},"* ]]
}

existing_proto_enabled() {
  local target="$1"
  [[ ",${EXISTING_PROTOCOLS_CSV}," == *",${target},"* ]]
}

normalize_proto_csv() {
  local raw="${1:-}"
  raw="${raw//,/ }"
  local list=()
  for item in $raw; do
    case "$item" in
      1|anytls) list+=("anytls") ;;
      2|hy2|hysteria2) list+=("hy2") ;;
      3|vless_xhttp_tls|vless+xhttp+tls) list+=("vless_xhttp_tls") ;;
      4|vless_xhttp|vless+xhttp) list+=("vless_xhttp") ;;
      5|vless_reality|vless+reality) list+=("vless_reality") ;;
      6|ss2022) list+=("ss2022") ;;
      *) log_warn "忽略无效协议选项: ${item}" ;;
    esac
  done
  if [[ "${#list[@]}" -eq 0 ]]; then
    echo ""
    return 0
  fi
  printf "%s\n" "${list[@]}" | awk '!seen[$0]++' | paste -sd, -
}

load_existing_config() {
  local cfg_file="${STACK_DIR}/config.json"
  [[ -f "$cfg_file" ]] || return 1
  eval "$(python3 - "$cfg_file" <<'PYLOAD'
import json, shlex, sys
cfg = json.load(open(sys.argv[1], encoding="utf-8"))
def emit(k, v):
    if v is not None and str(v) != "":
        print(f"{k}={shlex.quote(str(v))}")

emit("MAIN_DOMAIN", cfg.get("main_domain"))
emit("ACME_EMAIL", cfg.get("acme_email"))
emit("TIMEZONE", cfg.get("timezone"))
emit("RESET_DAY", cfg.get("reset_day"))
emit("EXISTING_PROTOCOLS_CSV", ",".join(cfg.get("enabled_protocols") or []))

if isinstance(cfg.get("anytls"), dict):
    emit("ANYTLS_DOMAIN", cfg["anytls"].get("domain"))
if isinstance(cfg.get("hy2"), dict):
    emit("HY2_DOMAIN", cfg["hy2"].get("domain"))
    emit("HY2_HOP_RANGE", cfg["hy2"].get("hop_ports"))
    emit("HY2_STATS_SECRET", cfg["hy2"].get("stats_secret"))
if isinstance(cfg.get("vless_xhttp_tls"), dict):
    emit("XHTTP_TLS_DOMAIN", cfg["vless_xhttp_tls"].get("domain"))
    emit("XHTTP_TLS_PATH", cfg["vless_xhttp_tls"].get("path"))
if isinstance(cfg.get("vless_xhttp"), dict):
    emit("XHTTP_PORT", cfg["vless_xhttp"].get("port"))
    emit("XHTTP_PATH", cfg["vless_xhttp"].get("path"))
if isinstance(cfg.get("vless_reality"), dict):
    r = cfg["vless_reality"]
    emit("REALITY_PORT", r.get("port"))
    emit("REALITY_DEST", r.get("dest"))
    emit("REALITY_SNI", r.get("sni"))
    emit("REALITY_PRIV", r.get("private_key"))
    emit("REALITY_PUB", r.get("public_key"))
    emit("REALITY_SID", r.get("short_id"))
if isinstance(cfg.get("ss2022"), dict):
    s = cfg["ss2022"]
    emit("SS2022_PORT", s.get("port"))
    emit("SS2022_SERVER_PSK", s.get("server_psk"))
PYLOAD
)"
}

validate_domain() {
  local d="$1"
  [[ "$d" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$ ]]
}

validate_port_range() {
  local r="$1"
  if [[ "$r" =~ ^([0-9]{4,5})-([0-9]{4,5})$ ]]; then
    local s="${BASH_REMATCH[1]}" e="${BASH_REMATCH[2]}"
    if (( s >= 1024 && e <= 65535 && s < e )); then
      return 0
    fi
  fi
  return 1
}

# ==============================================================================
# 交互式 / 非交互式参数收集 (支持首次安装 + 自动增量 / --add / --remove)
# ==============================================================================
fill_missing_protocol_params() {
  # 仅为已启用且尚未配置参数的新增协议收集或生成默认值，已有协议参数严格保留
  local interactive="$1"

  if proto_enabled "anytls" && [[ -z "$ANYTLS_DOMAIN" ]]; then
    if [[ "$interactive" -eq 1 ]]; then
      read -rp "请输入 AnyTLS 域名 [默认: ats.${MAIN_DOMAIN}]: " input_ats
      ANYTLS_DOMAIN="${input_ats:-ats.${MAIN_DOMAIN}}"
    else
      ANYTLS_DOMAIN="ats.${MAIN_DOMAIN}"
    fi
  fi

  if proto_enabled "hy2"; then
    if [[ -z "$HY2_DOMAIN" ]]; then
      if [[ "$interactive" -eq 1 ]]; then
        read -rp "请输入 Hysteria2 域名 [默认: ${MAIN_DOMAIN}]: " input_hy2
        HY2_DOMAIN="${input_hy2:-${MAIN_DOMAIN}}"
      else
        HY2_DOMAIN="${MAIN_DOMAIN}"
      fi
    fi
    if [[ -z "$HY2_HOP_RANGE" ]]; then
      if [[ "$interactive" -eq 1 ]]; then
        read -rp "请输入 Hysteria2 端口跳跃 UDP 范围 (如 20000-50000, 回车不启用): " input_hop
        HY2_HOP_RANGE="${input_hop:-}"
      fi
    fi
    if [[ "$HY2_HOP_RANGE" == "none" || "$HY2_HOP_RANGE" == "off" ]]; then
      HY2_HOP_RANGE=""
    elif [[ "$HY2_HOP_RANGE" == "auto" ]]; then
      HY2_HOP_RANGE="30000-45000"
    elif [[ -n "$HY2_HOP_RANGE" ]] && ! validate_port_range "$HY2_HOP_RANGE"; then
      log_err "Hysteria2 端口跳跃范围无效: ${HY2_HOP_RANGE} (格式应为 start-end，如 20000-50000)"
      exit 1
    fi
  fi

  if proto_enabled "vless_xhttp_tls" && [[ -z "$XHTTP_TLS_DOMAIN" ]]; then
    if [[ "$interactive" -eq 1 ]]; then
      read -rp "请输入 VLESS+XHTTP+TLS 域名 [默认: xhttp.${MAIN_DOMAIN}]: " input_xht
      XHTTP_TLS_DOMAIN="${input_xht:-xhttp.${MAIN_DOMAIN}}"
    else
      XHTTP_TLS_DOMAIN="xhttp.${MAIN_DOMAIN}"
    fi
  fi

  if proto_enabled "vless_xhttp" && [[ -z "$XHTTP_PORT" ]]; then
    local def_xp
    def_xp="$(random_free_port)"
    if [[ "$interactive" -eq 1 ]]; then
      read -rp "请输入 VLESS+XHTTP (无TLS) 端口 [默认随机: ${def_xp}]: " input_xp
      XHTTP_PORT="${input_xp:-${def_xp}}"
    else
      XHTTP_PORT="$def_xp"
    fi
  fi

  if proto_enabled "vless_reality"; then
    if [[ -z "$REALITY_PORT" ]]; then
      local def_rp
      def_rp="$(random_free_port)"
      if [[ "$interactive" -eq 1 ]]; then
        read -rp "请输入 VLESS+Reality 端口 [默认随机: ${def_rp}]: " input_rp
        REALITY_PORT="${input_rp:-${def_rp}}"
      else
        REALITY_PORT="$def_rp"
      fi
    fi
    if [[ -z "$REALITY_DEST" ]]; then
      if [[ "$interactive" -eq 1 ]]; then
        read -rp "请输入 Reality 回落目标 [默认本机伪装站: 127.0.0.1:${PORT_CADDY_L7_HTTPS}]: " input_rdest
        REALITY_DEST="${input_rdest:-127.0.0.1:${PORT_CADDY_L7_HTTPS}}"
      else
        REALITY_DEST="127.0.0.1:${PORT_CADDY_L7_HTTPS}"
      fi
    fi
    if [[ -z "$REALITY_SNI" ]]; then
      if [[ "$interactive" -eq 1 ]]; then
        read -rp "请输入 Reality SNI [默认: ${MAIN_DOMAIN}]: " input_rsni
        REALITY_SNI="${input_rsni:-${MAIN_DOMAIN}}"
      else
        REALITY_SNI="${MAIN_DOMAIN}"
      fi
    fi
  fi

  if proto_enabled "ss2022" && [[ -z "$SS2022_PORT" ]]; then
    local def_sp
    def_sp="$(random_free_port)"
    if [[ "$interactive" -eq 1 ]]; then
      read -rp "请输入 SS2022 端口 [默认随机: ${def_sp}]: " input_sp
      SS2022_PORT="${input_sp:-${def_sp}}"
    else
      SS2022_PORT="$def_sp"
    fi
  fi
}

collect_config() {
  echo -e "${CYAN}"
  echo "============================================================"
  echo "   VPS 多协议代理节点一键部署脚本 v${SCRIPT_VERSION}"
  echo "============================================================"
  echo -e "${NC}"

  # 检测是否已存在配置并决定是否进入增量模式
  if [[ -f "${STACK_DIR}/config.json" && "$FORCE_REINSTALL" -eq 0 ]]; then
    INCREMENTAL_MODE=1
    # 暂存用户通过环境变量显式覆盖的新增参数，加载旧配置后再补回空缺项
    local env_anytls_dom="$ANYTLS_DOMAIN" env_hy2_dom="$HY2_DOMAIN" env_hy2_hop="$HY2_HOP_RANGE" env_xht_dom="$XHTTP_TLS_DOMAIN"
    local env_xht_path="$XHTTP_TLS_PATH" env_xh_port="$XHTTP_PORT" env_xh_path="$XHTTP_PATH"
    local env_r_port="$REALITY_PORT" env_r_dest="$REALITY_DEST" env_r_sni="$REALITY_SNI" env_ss_port="$SS2022_PORT"
    load_existing_config
    # 若旧配置中未包含某协议参数，或用户显式传入 HY2_HOP_RANGE，则允许环境变量更新
    [[ -z "$ANYTLS_DOMAIN" && -n "$env_anytls_dom" ]] && ANYTLS_DOMAIN="$env_anytls_dom"
    [[ -z "$HY2_DOMAIN" && -n "$env_hy2_dom" ]] && HY2_DOMAIN="$env_hy2_dom"
    [[ -n "$env_hy2_hop" ]] && HY2_HOP_RANGE="$env_hy2_hop"
    [[ -z "$XHTTP_TLS_DOMAIN" && -n "$env_xht_dom" ]] && XHTTP_TLS_DOMAIN="$env_xht_dom"
    [[ -z "$XHTTP_TLS_PATH" && -n "$env_xht_path" ]] && XHTTP_TLS_PATH="$env_xht_path"
    [[ -z "$XHTTP_PORT" && -n "$env_xh_port" ]] && XHTTP_PORT="$env_xh_port"
    [[ -z "$XHTTP_PATH" && -n "$env_xh_path" ]] && XHTTP_PATH="$env_xh_path"
    [[ -z "$REALITY_PORT" && -n "$env_r_port" ]] && REALITY_PORT="$env_r_port"
    [[ -z "$REALITY_DEST" && -n "$env_r_dest" ]] && REALITY_DEST="$env_r_dest"
    [[ -z "$REALITY_SNI" && -n "$env_r_sni" ]] && REALITY_SNI="$env_r_sni"
    [[ -z "$SS2022_PORT" && -n "$env_ss_port" ]] && SS2022_PORT="$env_ss_port"

    log_info "检测到已有部署 (${STACK_DIR}/config.json)，进入增量模式。"
    log_info "当前主域名: ${MAIN_DOMAIN} | 已启用协议: ${EXISTING_PROTOCOLS_CSV}"
  elif [[ -n "$ADD_PROTOCOLS_ARG" || -n "$REMOVE_PROTOCOLS_ARG" ]]; then
    log_err "未找到现有配置 (${STACK_DIR}/config.json)，无法使用 --add / --remove，请先执行首次部署。"
    exit 1
  fi

  if [[ "$INCREMENTAL_MODE" -eq 1 ]]; then
    ENABLED_PROTOCOLS_CSV="$EXISTING_PROTOCOLS_CSV"

    if [[ -n "$ADD_PROTOCOLS_ARG" || -n "$REMOVE_PROTOCOLS_ARG" ]]; then
      if [[ -n "$ADD_PROTOCOLS_ARG" ]]; then
        local add_norm
        add_norm="$(normalize_proto_csv "$ADD_PROTOCOLS_ARG")"
        [[ -z "$add_norm" ]] && { log_err "--add 未包含有效协议名"; exit 1; }
        ENABLED_PROTOCOLS_CSV="$(printf "%s\n%s\n" "${ENABLED_PROTOCOLS_CSV//,/$'\n'}" "${add_norm//,/$'\n'}" | sed '/^$/d' | awk '!seen[$0]++' | paste -sd, -)"
      fi
      if [[ -n "$REMOVE_PROTOCOLS_ARG" ]]; then
        local rem_norm
        rem_norm="$(normalize_proto_csv "$REMOVE_PROTOCOLS_ARG")"
        [[ -z "$rem_norm" ]] && { log_err "--remove 未包含有效协议名"; exit 1; }
        local kept=()
        IFS=',' read -r -a cur_arr <<< "$ENABLED_PROTOCOLS_CSV"
        for p in "${cur_arr[@]}"; do
          if [[ ",${rem_norm}," != *",${p},"* ]]; then
            kept+=("$p")
          fi
        done
        if [[ "${#kept[@]}" -eq 0 ]]; then
          log_err "不能移除全部协议；如需彻底卸载请使用 --uninstall。"
          exit 1
        fi
        ENABLED_PROTOCOLS_CSV="$(printf "%s\n" "${kept[@]}" | paste -sd, -)"
      fi
      fill_missing_protocol_params "$([[ "$NON_INTERACTIVE" -eq 0 ]] && echo 1 || echo 0)"
    elif [[ "$NON_INTERACTIVE" -eq 1 ]]; then
      if [[ -n "$SELECTED_PROTOCOLS" ]]; then
        ENABLED_PROTOCOLS_CSV="$(normalize_proto_csv "$SELECTED_PROTOCOLS")"
        [[ -z "$ENABLED_PROTOCOLS_CSV" ]] && { log_err "SELECTED_PROTOCOLS 未包含有效协议"; exit 1; }
      fi
      fill_missing_protocol_params 0
    else
      echo ""
      echo "请选择增量操作:"
      echo "  1) 增量添加协议 (保留现有协议配置与所有用户)"
      echo "  2) 移除已部署协议 (保留剩余协议与所有用户)"
      echo "  3) 仅更新管理程序并重新渲染配置"
      echo "  4) 覆盖重装 (重新输入全部配置)"
      read -rp "请输入选项 [默认: 1]: " inc_action
      inc_action="${inc_action:-1}"
      case "$inc_action" in
        1)
          echo "可选协议: 1) anytls  2) hy2  3) vless+xhttp+tls  4) vless+xhttp  5) vless+reality  6) ss2022"
          read -rp "请输入要新增的协议 (编号或名称，空格/逗号分隔): " add_in
          local add_norm
          add_norm="$(normalize_proto_csv "$add_in")"
          [[ -z "$add_norm" ]] && { log_err "未选择有效协议"; exit 1; }
          ENABLED_PROTOCOLS_CSV="$(printf "%s\n%s\n" "${ENABLED_PROTOCOLS_CSV//,/$'\n'}" "${add_norm//,/$'\n'}" | sed '/^$/d' | awk '!seen[$0]++' | paste -sd, -)"
          fill_missing_protocol_params 1
          ;;
        2)
          echo "当前已启用协议: ${EXISTING_PROTOCOLS_CSV}"
          read -rp "请输入要移除的协议 (名称，空格/逗号分隔): " rem_in
          local rem_norm
          rem_norm="$(normalize_proto_csv "$rem_in")"
          [[ -z "$rem_norm" ]] && { log_err "未选择有效协议"; exit 1; }
          local kept=()
          IFS=',' read -r -a cur_arr <<< "$ENABLED_PROTOCOLS_CSV"
          for p in "${cur_arr[@]}"; do
            [[ ",${rem_norm}," != *",${p},"* ]] && kept+=("$p")
          done
          [[ "${#kept[@]}" -eq 0 ]] && { log_err "不能移除全部协议，如需卸载请运行 --uninstall"; exit 1; }
          ENABLED_PROTOCOLS_CSV="$(printf "%s\n" "${kept[@]}" | paste -sd, -)"
          ;;
        3)
          log_info "保持现有协议列表不变，仅更新管理程序与配置..."
          ;;
        4)
          INCREMENTAL_MODE=0
          FORCE_REINSTALL=1
          ;;
        *)
          log_err "无效选项: ${inc_action}"; exit 1 ;;
      esac
    fi
  fi

  # 首次全新安装 / 覆盖重装流程
  if [[ "$INCREMENTAL_MODE" -eq 0 ]]; then
    if [[ "$NON_INTERACTIVE" -eq 0 ]]; then
      echo "可选部署协议 (输入编号，用空格或逗号分隔，直接回车默认全选):"
      echo "  1) anytls            [443/TCP, Caddy SNI 转发, sing-box]"
      echo "  2) hy2               [443/UDP, Caddy QUIC SNI 转发, Hysteria2]"
      echo "  3) vless+xhttp+tls   [443/TCP, Caddy SNI 转发, Xray]"
      echo "  4) vless+xhttp       [自定义/随机端口, 无TLS, Xray]"
      echo "  5) vless+reality     [自定义/随机端口, Reality, Xray]"
      echo "  6) ss2022            [自定义/随机端口, SS2022, Xray]"
      echo ""
      read -rp "请选择要部署的协议 [默认: 1 2 3 4 5 6]: " proto_input
      proto_input="${proto_input:-1 2 3 4 5 6}"
      ENABLED_PROTOCOLS_CSV="$(normalize_proto_csv "$proto_input")"
      if [[ -z "$ENABLED_PROTOCOLS_CSV" ]]; then
        log_err "至少需要选择一个代理协议！"
        exit 1
      fi

      while true; do
        read -rp "请输入主域名 (用于伪装站/管理API/Hy2, 例: de.example.com): " MAIN_DOMAIN
        if validate_domain "$MAIN_DOMAIN"; then
          break
        fi
        log_warn "域名格式无效，请重新输入。"
      done

      read -rp "请输入 ACME 证书通知邮箱 [默认: admin@${MAIN_DOMAIN}]: " input_email
      ACME_EMAIL="${input_email:-admin@${MAIN_DOMAIN}}"

      ANYTLS_DOMAIN=""; HY2_DOMAIN=""; XHTTP_TLS_DOMAIN=""; XHTTP_PORT=""
      REALITY_PORT=""; REALITY_DEST=""; REALITY_SNI=""; SS2022_PORT=""
      fill_missing_protocol_params 1

      read -rp "请输入流量统计时区 [默认: Asia/Shanghai]: " input_tz
      TIMEZONE="${input_tz:-Asia/Shanghai}"

      read -rp "请输入月配额重置日 (1-28) [默认: 1]: " input_rd
      RESET_DAY="${input_rd:-1}"
    else
      if [[ -z "$MAIN_DOMAIN" ]] || ! validate_domain "$MAIN_DOMAIN"; then
        log_err "非交互模式必须提供有效的 MAIN_DOMAIN 环境变量。"
        exit 1
      fi
      SELECTED_PROTOCOLS="${SELECTED_PROTOCOLS:-anytls,hy2,vless_xhttp_tls,vless_xhttp,vless_reality,ss2022}"
      ENABLED_PROTOCOLS_CSV="$(normalize_proto_csv "$SELECTED_PROTOCOLS")"
      [[ -z "$ENABLED_PROTOCOLS_CSV" ]] && { log_err "SELECTED_PROTOCOLS 未包含有效协议"; exit 1; }
      ACME_EMAIL="${ACME_EMAIL:-admin@${MAIN_DOMAIN}}"
      fill_missing_protocol_params 0
    fi
  fi

  # 自动生成随机路径与密钥（已有路径不会覆盖）
  XHTTP_TLS_PATH="${XHTTP_TLS_PATH:-/$(random_hex 8)}"
  XHTTP_PATH="${XHTTP_PATH:-/$(random_hex 8)}"
  [[ "$XHTTP_TLS_PATH" != /* ]] && XHTTP_TLS_PATH="/${XHTTP_TLS_PATH}"
  [[ "$XHTTP_PATH" != /* ]] && XHTTP_PATH="/${XHTTP_PATH}"

  # 检查域名冲突：AnyTLS 必须使用独立 SNI（不能与主域名或 xhttp_tls 域名相同）
  if proto_enabled "anytls"; then
    if [[ "$ANYTLS_DOMAIN" == "$MAIN_DOMAIN" ]]; then
      log_err "AnyTLS 域名 (${ANYTLS_DOMAIN}) 不能与主域名 (${MAIN_DOMAIN}) 相同，因为 TCP 443 按 SNI 转发，请使用子域名（如 ats.${MAIN_DOMAIN}）。"
      exit 1
    fi
    if proto_enabled "vless_xhttp_tls" && [[ "$ANYTLS_DOMAIN" == "$XHTTP_TLS_DOMAIN" ]]; then
      log_err "AnyTLS 域名 (${ANYTLS_DOMAIN}) 不能与 VLESS+XHTTP+TLS 域名 (${XHTTP_TLS_DOMAIN}) 相同。"
      exit 1
    fi
  fi

  log_info "配置摘要 ($([[ "$INCREMENTAL_MODE" -eq 1 ]] && echo "增量模式" || echo "全新安装")):"
  echo "  主域名 (伪装站 & API) : ${MAIN_DOMAIN}"
  echo "  已启用协议            : ${ENABLED_PROTOCOLS_CSV}"
  proto_enabled "anytls"          && echo "  AnyTLS                : ${ANYTLS_DOMAIN}:443 (TCP)"
  if proto_enabled "hy2"; then
    if [[ -n "$HY2_HOP_RANGE" ]]; then
      echo "  Hysteria2             : ${HY2_DOMAIN}:443 (UDP, 端口跳跃=${HY2_HOP_RANGE})"
    else
      echo "  Hysteria2             : ${HY2_DOMAIN}:443 (UDP)"
    fi
  fi
  proto_enabled "vless_xhttp_tls" && echo "  VLESS+XHTTP+TLS       : ${XHTTP_TLS_DOMAIN}:443 (TCP, path=${XHTTP_TLS_PATH})"
  proto_enabled "vless_xhttp"     && echo "  VLESS+XHTTP           : ${MAIN_DOMAIN}:${XHTTP_PORT} (TCP, path=${XHTTP_PATH})"
  proto_enabled "vless_reality"   && echo "  VLESS+Reality         : ${MAIN_DOMAIN}:${REALITY_PORT} (TCP, sni=${REALITY_SNI}, dest=${REALITY_DEST})"
  proto_enabled "ss2022"          && echo "  SS2022                : ${MAIN_DOMAIN}:${SS2022_PORT} (TCP+UDP)"
  echo "  时区 / 重置日         : ${TIMEZONE} / 每月 ${RESET_DAY} 日"
}

# ==============================================================================
# 按需下载核心二进制
# ==============================================================================
need_xray() {
  proto_enabled "vless_xhttp_tls" || proto_enabled "vless_xhttp" || proto_enabled "vless_reality" || proto_enabled "ss2022"
}

github_latest_tag() {
  local repo="$1"
  curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" | jq -r '.tag_name'
}

fetch_with_auth() {
  local url="$1" out="$2"
  if [[ -n "${GH_TOKEN:-}" ]]; then
    curl -fsSL -H "Authorization: Bearer ${GH_TOKEN}" "$url" -o "$out"
  else
    curl -fsSL "$url" -o "$out"
  fi
}

configure_go_build_env() {
  local mem_kb mem_mb cores
  mem_kb="$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 1048576)"
  mem_mb=$((mem_kb / 1024))
  cores="$(nproc 2>/dev/null || echo 1)"

  if (( mem_mb < 1024 )); then
    export GOMAXPROCS=1
    export GOMEMLIMIT="300MiB"
    export GOGC=50
    log_info "检测到小内存环境 (${mem_mb}MiB RAM, ${cores}C)，启用低内存编译限制 (GOMAXPROCS=1, GOMEMLIMIT=300MiB)"
  elif (( mem_mb < 2048 )); then
    local p=$((cores < 2 ? cores : 2))
    local lim=$((mem_mb * 60 / 100))
    export GOMAXPROCS="$p"
    export GOMEMLIMIT="${lim}MiB"
    export GOGC=75
    log_info "检测到中等内存环境 (${mem_mb}MiB RAM, ${cores}C)，设置 GOMAXPROCS=${p}, GOMEMLIMIT=${lim}MiB"
  else
    unset GOMEMLIMIT 2>/dev/null || true
    export GOMAXPROCS="$cores"
    export GOGC=100
    log_info "检测到充足内存环境 (${mem_mb}MiB RAM, ${cores}C)，启用全速并发编译 (GOMAXPROCS=${cores})"
  fi
}

install_caddy() {
  local tmp="/var/tmp/caddy-download.bin"
  local url="${CADDY_BIN_URL:-${RELEASE_BASE_URL}/caddy-l4-linux-${ARCH}}"
  log_info "尝试从 URL 拉取预编译 Caddy (${ARCH}): ${url}"
  if fetch_with_auth "$url" "$tmp" 2>/dev/null && chmod +x "$tmp" && "$tmp" list-modules 2>/dev/null | grep "layer4" >/dev/null; then
    mv -f "$tmp" /usr/local/bin/caddy
    log_ok "Caddy (含 caddy-l4) 下载安装完成: $(/usr/local/bin/caddy version)"
    return 0
  fi
  rm -f "$tmp"

  if [[ -n "${CADDY_BIN_URL:-}" ]]; then
    log_err "从自定义 CADDY_BIN_URL 下载或校验 layer4 模块失败: ${CADDY_BIN_URL}"
    exit 1
  fi

  log_warn "预编译 Caddy 暂不可用，回退使用 xcaddy 本地编译 caddy-l4 (${ARCH})..."
  local need_go_install=0
  if ! command -v go >/dev/null 2>&1; then
    need_go_install=1
  fi
  if [[ "$need_go_install" -eq 1 ]]; then
    log_info "安装 Go 工具链用于构建 caddy-l4..."
    if [[ "$PKG_MGR" == "apt" ]]; then
      apt-get install -y -qq golang-go git >/dev/null
    else
      "$PKG_MGR" install -y -q golang git >/dev/null
    fi
  fi

  local xtag xver xurl xtmp
  xtag="$(github_latest_tag "caddyserver/xcaddy")"
  xver="${xtag#v}"
  xurl="https://github.com/caddyserver/xcaddy/releases/download/${xtag}/xcaddy_${xver}_linux_${ARCH}.tar.gz"
  xtmp="$(mktemp -d /var/tmp/xcaddy-build.XXXXXX)"
  curl -fsSL "$xurl" -o "${xtmp}/xcaddy.tar.gz"
  tar -xzf "${xtmp}/xcaddy.tar.gz" -C "${xtmp}"
  chmod +x "${xtmp}/xcaddy"

  (
    export TMPDIR="${xtmp}"
    export GOTOOLCHAIN=auto
    export GOPATH="${xtmp}/gopath"
    export GOCACHE="${xtmp}/gocache"
    configure_go_build_env
    "${xtmp}/xcaddy" build --with github.com/mholt/caddy-l4 --output "$tmp"
  )
  rm -rf "$xtmp"
  chmod +x "$tmp"
  if ! "$tmp" list-modules 2>/dev/null | grep "layer4" >/dev/null; then
    log_err "构建的 Caddy 二进制缺少 layer4 模块！"
    exit 1
  fi
  mv -f "$tmp" /usr/local/bin/caddy
  log_ok "Caddy (含 caddy-l4) 安装完成: $(/usr/local/bin/caddy version)"
}

install_xray() {
  log_info "下载最新 Xray-core (${XRAY_ARCH})..."
  local tag url tmpdir
  tag="$(github_latest_tag "XTLS/Xray-core")"
  url="https://github.com/XTLS/Xray-core/releases/download/${tag}/Xray-linux-${XRAY_ARCH}.zip"
  tmpdir="$(mktemp -d)"
  curl -fsSL "$url" -o "${tmpdir}/xray.zip"
  unzip -qo "${tmpdir}/xray.zip" -d "${tmpdir}"
  install -m 755 "${tmpdir}/xray" /usr/local/bin/xray
  mkdir -p /usr/local/share/xray
  [[ -f "${tmpdir}/geoip.dat" ]] && install -m 644 "${tmpdir}/geoip.dat" /usr/local/share/xray/geoip.dat
  [[ -f "${tmpdir}/geosite.dat" ]] && install -m 644 "${tmpdir}/geosite.dat" /usr/local/share/xray/geosite.dat
  rm -rf "$tmpdir"
  log_ok "Xray-core 安装完成: $(/usr/local/bin/xray version | head -n1)"
}

install_singbox() {
  local tmp="/var/tmp/sing-box-download.bin"
  local url="${SINGBOX_BIN_URL:-${RELEASE_BASE_URL}/sing-box-linux-${ARCH}}"
  log_info "尝试从 URL 拉取预编译 sing-box (${ARCH}): ${url}"
  if fetch_with_auth "$url" "$tmp" 2>/dev/null && chmod +x "$tmp" && "$tmp" version 2>/dev/null | grep "with_v2ray_api" >/dev/null; then
    mv -f "$tmp" /usr/local/bin/sing-box
    log_ok "sing-box 下载安装完成: $(/usr/local/bin/sing-box version | head -n1)"
  else
    rm -f "$tmp"
    if [[ -n "${SINGBOX_BIN_URL:-}" ]]; then
      log_err "从自定义 SINGBOX_BIN_URL 下载或校验 with_v2ray_api 失败: ${SINGBOX_BIN_URL}"
      exit 1
    fi
    log_warn "预编译 sing-box 暂不可用，回退本地编译带 with_v2ray_api 的极简 sing-box (${ARCH})..."
    if ! command -v go >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
      if [[ "$PKG_MGR" == "apt" ]]; then
        apt-get install -y -qq golang-go git >/dev/null
      else
        "$PKG_MGR" install -y -q golang git >/dev/null
      fi
    fi
    local tag tmpdir
    tag="$(github_latest_tag "SagerNet/sing-box")"
    tmpdir="$(mktemp -d /var/tmp/sb-build.XXXXXX)"
    git clone --depth=1 --branch "$tag" https://github.com/SagerNet/sing-box.git "${tmpdir}/src" >/dev/null 2>&1
    (
      cd "${tmpdir}/src"
      export TMPDIR="${tmpdir}"
      export GOPATH="${tmpdir}/gopath"
      export GOCACHE="${tmpdir}/gocache"
      export GOTOOLCHAIN=auto
      configure_go_build_env
      go build -ldflags "-s -w" -tags "with_v2ray_api" -o "$tmp" ./cmd/sing-box
    )
    rm -rf "$tmpdir"
    chmod +x "$tmp"
    if ! "$tmp" version 2>/dev/null | grep "with_v2ray_api" >/dev/null; then
      log_err "sing-box 二进制缺少 with_v2ray_api 标签！"
      exit 1
    fi
    mv -f "$tmp" /usr/local/bin/sing-box
    log_ok "sing-box 安装完成: $(/usr/local/bin/sing-box version | head -n1)"
  fi

  if [[ ! -x /usr/local/bin/grpcurl ]]; then
    log_info "下载 grpcurl (${GRPCURL_ARCH}) 用于 sing-box v2ray_api 流量采集..."
    local gtag gver gurl gtmp
    gtag="$(github_latest_tag "fullstorydev/grpcurl")"
    gver="${gtag#v}"
    gurl="https://github.com/fullstorydev/grpcurl/releases/download/${gtag}/grpcurl_${gver}_linux_${GRPCURL_ARCH}.tar.gz"
    gtmp="$(mktemp -d /var/tmp/grpcurl.XXXXXX)"
    curl -fsSL "$gurl" -o "${gtmp}/grpcurl.tar.gz"
    tar -xzf "${gtmp}/grpcurl.tar.gz" -C "${gtmp}"
    install -m 755 "${gtmp}/grpcurl" /usr/local/bin/grpcurl
    rm -rf "$gtmp"
    log_ok "grpcurl 安装完成"
  fi
}

install_hysteria() {
  log_info "下载最新 Hysteria2 (${ARCH})..."
  local tag url tmp="/var/tmp/hysteria-download.bin"
  tag="$(github_latest_tag "apernet/hysteria")"
  url="https://github.com/apernet/hysteria/releases/download/${tag}/hysteria-linux-${ARCH}"
  curl -fsSL "$url" -o "$tmp"
  chmod +x "$tmp"
  mv -f "$tmp" /usr/local/bin/hysteria
  log_ok "Hysteria2 安装完成: $(/usr/local/bin/hysteria version | head -n1)"
}

install_binaries() {
  local caddy_mods=""
  if [[ "$INCREMENTAL_MODE" -eq 1 && -x /usr/local/bin/caddy ]]; then
    caddy_mods="$(/usr/local/bin/caddy list-modules 2>/dev/null || true)"
  fi
  if [[ "$INCREMENTAL_MODE" -eq 1 && "$caddy_mods" == *"layer4"* ]]; then
    log_info "Caddy (含 caddy-l4) 已安装，跳过重复构建。"
  else
    install_caddy
  fi
  if proto_enabled "anytls"; then
    if [[ "$INCREMENTAL_MODE" -eq 1 && -x /usr/local/bin/sing-box && -x /usr/local/bin/grpcurl ]]; then
      log_info "sing-box 与 grpcurl 已安装，跳过重复下载。"
    else
      install_singbox
    fi
  fi
  if proto_enabled "hy2"; then
    if [[ "$INCREMENTAL_MODE" -eq 1 && -x /usr/local/bin/hysteria ]]; then
      log_info "Hysteria2 已安装，跳过重复下载。"
    else
      install_hysteria
    fi
  fi
  if need_xray; then
    if [[ "$INCREMENTAL_MODE" -eq 1 && -x /usr/local/bin/xray ]]; then
      log_info "Xray-core 已安装，跳过重复下载。"
    else
      install_xray
    fi
  fi
}

# ==============================================================================
# 生成静态伪装网页与协议辅助文件
# ==============================================================================
create_directories_and_assets() {
  mkdir -p "$STACK_DIR" "$APP_DIR" "$DATA_DIR" "$WEB_ROOT" "$CERT_DIR" /var/lib/caddy
  chmod 750 "$STACK_DIR" "$DATA_DIR" "$CERT_DIR"

  # 写入静态伪装网页
  cat > "${WEB_ROOT}/index.html" <<'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>Northstar Cloud Telemetry</title>
  <style>
    :root { --bg: #0f172a; --card: #1e293b; --text: #e2e8f0; --muted: #94a3b8; --accent: #38bdf8; --ok: #34d399; }
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: var(--bg); color: var(--text); min-height: 100vh; display: flex; flex-direction: column; }
    header { padding: 24px 32px; border-bottom: 1px solid #334155; display: flex; justify-content: space-between; align-items: center; }
    .brand { font-size: 1.15rem; font-weight: 600; letter-spacing: 0.02em; }
    .badge { font-size: 0.8rem; color: var(--ok); background: rgba(52,211,153,0.12); padding: 4px 10px; border-radius: 999px; }
    main { max-width: 920px; width: 100%; margin: 56px auto; padding: 0 24px; flex: 1; }
    h1 { font-size: 2rem; margin-bottom: 12px; }
    p.lead { color: var(--muted); line-height: 1.7; margin-bottom: 36px; }
    .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(240px, 1fr)); gap: 20px; }
    .card { background: var(--card); border: 1px solid #334155; border-radius: 12px; padding: 22px; }
    .card h2 { font-size: 0.9rem; color: var(--muted); font-weight: 500; margin-bottom: 10px; }
    .metric { font-size: 1.6rem; font-weight: 700; color: var(--accent); }
    .sub { font-size: 0.82rem; color: var(--muted); margin-top: 8px; }
    footer { text-align: center; padding: 24px; color: var(--muted); font-size: 0.82rem; border-top: 1px solid #1e293b; }
  </style>
</head>
<body>
  <header>
    <div class="brand">Northstar Edge Telemetry</div>
    <div class="badge">All Systems Operational</div>
  </header>
  <main>
    <h1>Edge Relay &amp; Content Delivery Node</h1>
    <p class="lead">Distributed caching and static asset edge node. Automated health probes run continuously across regional POPs to ensure low-latency content delivery.</p>
    <div class="grid">
      <div class="card">
        <h2>Edge Availability</h2>
        <div class="metric">99.98%</div>
        <div class="sub">Rolling 30-day uptime window</div>
      </div>
      <div class="card">
        <h2>TLS Handshake</h2>
        <div class="metric">TLS 1.3</div>
        <div class="sub">Automated ACME certificate lifecycle</div>
      </div>
      <div class="card">
        <h2>Cache Hit Ratio</h2>
        <div class="metric">96.4%</div>
        <div class="sub">Static edge objects &amp; compression</div>
      </div>
    </div>
  </main>
  <footer>&copy; 2026 Northstar Infrastructure Network. All rights reserved.</footer>
</body>
</html>
EOF

  # 写入 sing-box v2ray_api stats.proto (供 grpcurl 查询 AnyTLS 流量)
  cat > "${STACK_DIR}/stats.proto" <<'EOF'
syntax = "proto3";
package v2ray.core.app.stats.command;

message QueryStatsRequest {
  string pattern = 1;
  bool reset = 2;
  repeated string patterns = 3;
  bool regexp = 4;
}

message Stat {
  string name = 1;
  int64 value = 2;
}

message QueryStatsResponse {
  repeated Stat stat = 1;
}

service StatsService {
  rpc QueryStats(QueryStatsRequest) returns (QueryStatsResponse) {}
}
EOF
}

# ==============================================================================
# 写入 Python 管理守护进程 (proxy_manager.py)
# ==============================================================================
write_proxy_manager() {
  cat > "${APP_DIR}/proxy_manager.py" <<'PYEOF'
#!/usr/bin/env python3
"""Proxy Node Traffic Collector, Config Renderer, and Management HTTP API.

Implements all endpoints and error semantics specified in:
  docs/节点流量与用户管理 API.md
"""
from __future__ import annotations

import base64
import calendar
import copy
from contextlib import contextmanager
import datetime as dt
import hmac
import ipaddress
import json
import logging
import os
import re
import secrets
import shutil
import sqlite3
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo

STACK_DIR = Path(os.environ.get("PROXY_STACK_DIR", "/etc/proxy-stack"))
DATA_DIR = Path(os.environ.get("PROXY_DATA_DIR", "/var/lib/proxy-stack"))
CONFIG_PATH = STACK_DIR / "config.json"
TOKEN_PATH = STACK_DIR / "admin.token"
DB_PATH = DATA_DIR / "state.db"

USERNAME_RE = re.compile(r"^[a-z0-9_-]{1,48}$")
OUTBOUND_TAG_RE = re.compile(r"^[a-zA-Z0-9_-]{1,48}$")
RESERVED_OUTBOUND_TAGS = {"direct", "blocked", "api", "reject", "default"}
QUOTA_RE = re.compile(r"^(0|[1-9][0-9]*)(B|KiB|MiB|GiB|TiB)$")
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")

UNIT_MULT = {
    "B": 1,
    "KiB": 1024,
    "MiB": 1024 ** 2,
    "GiB": 1024 ** 3,
    "TiB": 1024 ** 4,
}

ALL_PROTOCOLS = (
    "anytls",
    "hy2",
    "vless_xhttp_tls",
    "vless_xhttp",
    "vless_reality",
    "ss2022",
)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
logger = logging.getLogger("proxy-manager")


def parse_quota(val: Any) -> tuple[bool, int | None]:
    """Return (is_valid, quota_bytes_or_none)."""
    if val is None or val == "unlimited":
        return True, None
    if not isinstance(val, str):
        return False, None
    m = QUOTA_RE.match(val)
    if not m:
        return False, None
    num = int(m.group(1))
    unit = m.group(2)
    return True, num * UNIT_MULT[unit]


def parse_date_strict(s: str) -> dt.date | None:
    if not DATE_RE.match(s):
        return None
    try:
        return dt.date.fromisoformat(s)
    except ValueError:
        return None


def compute_cycle(tz_name: str, reset_day: int, now_ts: int | None = None) -> tuple[int, int, str, str]:
    """Return (cycle_start_unix, next_reset_unix, start_date_iso, today_date_iso)."""
    tz = ZoneInfo(tz_name)
    now_dt = dt.datetime.fromtimestamp(now_ts if now_ts is not None else int(time.time()), tz=tz)
    rday = max(1, min(28, int(reset_day or 1)))

    if now_dt.day >= rday:
        start_year, start_month = now_dt.year, now_dt.month
        if start_month == 12:
            next_year, next_month = start_year + 1, 1
        else:
            next_year, next_month = start_year, start_month + 1
    else:
        next_year, next_month = now_dt.year, now_dt.month
        if next_month == 1:
            start_year, start_month = next_year - 1, 12
        else:
            start_year, start_month = next_year, next_month - 1

    start_max_day = calendar.monthrange(start_year, start_month)[1]
    next_max_day = calendar.monthrange(next_year, next_month)[1]
    cycle_start_dt = dt.datetime(start_year, start_month, min(rday, start_max_day), 0, 0, 0, tzinfo=tz)
    next_reset_dt = dt.datetime(next_year, next_month, min(rday, next_max_day), 0, 0, 0, tzinfo=tz)

    return (
        int(cycle_start_dt.timestamp()),
        int(next_reset_dt.timestamp()),
        cycle_start_dt.date().isoformat(),
        now_dt.date().isoformat(),
    )


def generate_user_credentials() -> dict[str, str]:
    return {
        "anytls_password": secrets.token_urlsafe(24),
        "hy2_password": secrets.token_urlsafe(24),
        "vless_uuid": str(uuid.uuid4()),
        "ss2022_psk": base64.b64encode(os.urandom(16)).decode("ascii"),
    }


def build_user_links(cfg: dict[str, Any], username: str, creds: dict[str, str]) -> dict[str, str]:
    enabled = cfg.get("enabled_protocols") or []
    links: dict[str, str] = {}
    main_domain = cfg["main_domain"]

    if "anytls" in enabled:
        dom = cfg["anytls"]["domain"]
        pw = urllib.parse.quote(creds["anytls_password"], safe="")
        links["anytls"] = f"anytls://{pw}@{dom}:443?sni={dom}#{username}-AnyTLS"

    if "hy2" in enabled:
        dom = cfg["hy2"]["domain"]
        pw = urllib.parse.quote(creds["hy2_password"], safe="")
        uname_q = urllib.parse.quote(username, safe="")
        hop = cfg["hy2"].get("hop_ports") or ""
        mport_q = f"&mport={hop}" if hop else ""
        links["hy2"] = f"hysteria2://{uname_q}:{pw}@{dom}:443/?sni={dom}{mport_q}#{username}-Hy2"

    if "vless_xhttp_tls" in enabled:
        dom = cfg["vless_xhttp_tls"]["domain"]
        path = urllib.parse.quote(cfg["vless_xhttp_tls"]["path"], safe="")
        uid = creds["vless_uuid"]
        links["vless_xhttp_tls"] = (
            f"vless://{uid}@{dom}:443?encryption=none&security=tls&sni={dom}"
            f"&type=xhttp&path={path}&mode=auto#{username}-VLESS-XHTTP-TLS"
        )

    if "vless_xhttp" in enabled:
        port = cfg["vless_xhttp"]["port"]
        path = urllib.parse.quote(cfg["vless_xhttp"]["path"], safe="")
        uid = creds["vless_uuid"]
        links["vless_xhttp"] = (
            f"vless://{uid}@{main_domain}:{port}?encryption=none&security=none"
            f"&type=xhttp&path={path}&mode=auto#{username}-VLESS-XHTTP"
        )

    if "vless_reality" in enabled:
        rcfg = cfg["vless_reality"]
        uid = creds["vless_uuid"]
        links["vless_reality"] = (
            f"vless://{uid}@{main_domain}:{rcfg['port']}?encryption=none&flow=xtls-rprx-vision"
            f"&security=reality&sni={rcfg['sni']}&fp=chrome&pbk={rcfg['public_key']}"
            f"&sid={rcfg['short_id']}&type=tcp#{username}-VLESS-Reality"
        )

    if "ss2022" in enabled:
        scfg = cfg["ss2022"]
        method = scfg.get("method", "2022-blake3-aes-128-gcm")
        raw_cred = f"{method}:{scfg['server_psk']}:{creds['ss2022_psk']}"
        b64_cred = base64.b64encode(raw_cred.encode("utf-8")).decode("ascii")
        links["ss2022"] = f"ss://{b64_cred}@{main_domain}:{scfg['port']}#{username}-SS2022"

    return links


# ─── Multi-Outbound URI Parser & Routing Helpers ──────────────────────────────

def _b64_decode_str(s: str) -> str:
    cleaned = re.sub(r"\s+", "", s.strip())
    padded = cleaned + ("=" * ((-len(cleaned)) % 4))
    try:
        return base64.b64decode(padded, validate=False).decode("utf-8", errors="ignore")
    except Exception:
        return base64.urlsafe_b64decode(padded).decode("utf-8", errors="ignore")


def parse_outbound_uri(uri: str) -> dict[str, Any]:
    """Parse socks5://, http(s)://, vless://, anytls://, hysteria2://, ss:// into canonical IR."""
    if not isinstance(uri, str) or "://" not in uri.strip():
        raise ValueError("invalid outbound uri")
    raw = uri.strip()
    scheme = raw.split("://", 1)[0].lower()
    if scheme == "hy2":
        scheme = "hysteria2"

    if scheme == "ss":
        body = raw[5:].split("#", 1)[0]
        if "?" in body:
            body = body.split("?", 1)[0]
        if "@" in body:
            userinfo, hostport = body.rsplit("@", 1)
            if ":" in userinfo:
                cipher, password = urllib.parse.unquote(userinfo).split(":", 1)
            else:
                decoded = _b64_decode_str(userinfo)
                if ":" not in decoded:
                    raise ValueError("invalid ss userinfo")
                cipher, password = decoded.split(":", 1)
        else:
            decoded = _b64_decode_str(body)
            if "@" not in decoded:
                raise ValueError("invalid ss uri")
            userinfo, hostport = decoded.rsplit("@", 1)
            cipher, password = userinfo.split(":", 1)
        hp = urllib.parse.urlsplit(f"ss://{hostport}")
        if not hp.hostname or not hp.port:
            raise ValueError("invalid ss host or port")
        return {
            "protocol": "ss",
            "server": hp.hostname,
            "port": int(hp.port),
            "cipher": cipher,
            "password": password,
            "raw_uri": raw,
        }

    if scheme not in ("socks5", "socks", "http", "https", "vless", "anytls", "hysteria2"):
        raise ValueError(f"unsupported outbound scheme: {scheme}")
    if scheme == "socks":
        scheme = "socks5"

    parts = urllib.parse.urlsplit(raw)
    host = parts.hostname or ""
    if not host:
        raise ValueError("missing outbound server host")
    port = parts.port
    if port is None:
        port = 443 if scheme in ("https", "vless", "anytls", "hysteria2") else (1080 if scheme == "socks5" else 80)
    qs = urllib.parse.parse_qs(parts.query, keep_blank_values=False)

    def q1(*keys: str) -> str | None:
        for k in keys:
            vals = qs.get(k)
            if vals and vals[0] != "":
                return vals[0]
        return None

    username = urllib.parse.unquote(parts.username or "")
    password = urllib.parse.unquote(parts.password or "")
    security = (q1("security") or ("tls" if scheme in ("https", "anytls", "hysteria2") else "none")).lower()
    alpn_raw = q1("alpn")
    alpn = [x.strip() for x in alpn_raw.split(",") if x.strip()] if alpn_raw else []
    insecure = (q1("insecure", "allowInsecure", "skip-cert-verify") or "").lower() in ("1", "true", "yes")

    ir: dict[str, Any] = {
        "protocol": scheme,
        "server": host,
        "port": int(port),
        "username": username,
        "password": password,
        "uuid": username if scheme == "vless" else "",
        "tls": security in ("tls", "reality") or scheme in ("https", "anytls", "hysteria2"),
        "security": security,
        "sni": q1("sni", "peer") or host,
        "insecure": insecure,
        "fp": q1("fp", "client-fingerprint") or "",
        "alpn": alpn,
        "flow": q1("flow") or "",
        "network": (q1("type") or "tcp").lower(),
        "path": q1("path") or "/",
        "host": q1("host") or "",
        "service_name": q1("serviceName", "service-name") or "",
        "mode": q1("mode") or "auto",
        "pbk": q1("pbk") or "",
        "sid": q1("sid") or "",
        "obfs": q1("obfs") or "",
        "obfs_password": q1("obfs-password") or "",
        "raw_uri": raw,
    }
    if scheme == "vless" and not ir["uuid"]:
        raise ValueError("vless outbound missing uuid")
    if scheme in ("anytls", "hysteria2") and not ir["password"] and not ir["username"]:
        raise ValueError(f"{scheme} outbound missing password")
    return ir


def mask_outbound_uri(uri: str) -> str:
    """Mask passwords/UUIDs in outbound URI while preserving scheme, host, port, query, and fragment."""
    raw = (uri or "").strip()
    if "://" not in raw:
        return "***"
    scheme = raw.split("://", 1)[0]
    if scheme.lower() == "ss":
        body = raw[5:]
        frag = ""
        if "#" in body:
            body, frag = body.split("#", 1)
            frag = "#" + frag
        if "@" in body:
            _, hostpart = body.rsplit("@", 1)
            return f"ss://***@{hostpart}{frag}"
        try:
            ir = parse_outbound_uri(raw)
            return f"ss://***@{ir['server']}:{ir['port']}{frag}"
        except Exception:
            return f"ss://***{frag}"
    parts = urllib.parse.urlsplit(raw)
    host = parts.hostname or ""
    if ":" in host and not host.startswith("["):
        host = f"[{host}]"
    netloc = f"{host}:{parts.port}" if parts.port else host
    if parts.username is not None or parts.password is not None:
        netloc = f"***@{netloc}"
    return urllib.parse.urlunsplit((parts.scheme, netloc, parts.path, parts.query, parts.fragment))


def is_masked_or_empty_uri(uri: Any, prev_uri: str | None = None) -> bool:
    if uri is None:
        return True
    if not isinstance(uri, str):
        return False
    s = uri.strip()
    if s == "" or s == "***":
        return True
    if prev_uri and s == mask_outbound_uri(prev_uri):
        return True
    if "://***@" in s:
        return True
    return False


def validate_and_normalize_routing_payload(
    payload: dict[str, Any],
    existing_outbounds: list[dict[str, Any]] | None = None,
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    """Validate PUT /api/v1/routing payload and return normalized (outbounds, routing)."""
    if not isinstance(payload, dict):
        raise ValueError("payload must be a JSON object")
    allowed_top = {"outbounds", "default_outbound", "rules"}
    if not set(payload.keys()).issubset(allowed_top):
        raise ValueError("unsupported top-level keys in routing payload")

    prev_map = {
        str(ob.get("tag")): str(ob.get("uri") or "")
        for ob in (existing_outbounds or [])
        if isinstance(ob, dict) and ob.get("tag")
    }

    raw_outbounds = payload.get("outbounds", existing_outbounds or [])
    if not isinstance(raw_outbounds, list):
        raise ValueError("outbounds must be a list")

    norm_outbounds: list[dict[str, Any]] = []
    seen_tags: set[str] = set()
    for item in raw_outbounds:
        if not isinstance(item, dict):
            raise ValueError("each outbound must be an object")
        tag = str(item.get("tag") or "").strip()
        if not OUTBOUND_TAG_RE.match(tag) or tag.lower() in RESERVED_OUTBOUND_TAGS:
            raise ValueError(f"invalid or reserved outbound tag: {tag!r}")
        if tag in seen_tags:
            raise ValueError(f"duplicate outbound tag: {tag}")
        seen_tags.add(tag)

        uri_val = item.get("uri")
        prev_uri = prev_map.get(tag)
        if is_masked_or_empty_uri(uri_val, prev_uri):
            if not prev_uri:
                raise ValueError(f"outbound {tag} requires a valid uri")
            resolved_uri = prev_uri
        else:
            resolved_uri = str(uri_val).strip()
        parse_outbound_uri(resolved_uri)
        norm_outbounds.append({"tag": tag, "uri": resolved_uri})

    valid_targets = seen_tags | {"direct"}
    default_ob = str(payload.get("default_outbound") or "direct").strip()
    if default_ob not in valid_targets:
        raise ValueError(f"default_outbound {default_ob!r} is not 'direct' or a defined outbound tag")

    raw_rules = payload.get("rules", [])
    if not isinstance(raw_rules, list):
        raise ValueError("rules must be a list")

    norm_rules: list[dict[str, Any]] = []
    allowed_rule_keys = {"users", "domains", "domain_suffix", "geosite", "ip_cidr", "geoip", "outbound"}
    for idx, r in enumerate(raw_rules):
        if not isinstance(r, dict):
            raise ValueError(f"rule[{idx}] must be an object")
        if not set(r.keys()).issubset(allowed_rule_keys):
            raise ValueError(f"rule[{idx}] contains unsupported fields")
        target_ob = str(r.get("outbound") or "").strip()
        if target_ob not in valid_targets:
            raise ValueError(f"rule[{idx}] references unknown outbound {target_ob!r}")

        nr: dict[str, Any] = {"outbound": target_ob}
        has_cond = False
        for k in ("users", "domains", "domain_suffix", "geosite", "ip_cidr", "geoip"):
            vals = r.get(k)
            if vals is None:
                continue
            if not isinstance(vals, list):
                raise ValueError(f"rule[{idx}].{k} must be a list")
            cleaned = [str(x).strip() for x in vals if str(x).strip()]
            if cleaned:
                if k == "users":
                    for u in cleaned:
                        if not USERNAME_RE.match(u):
                            raise ValueError(f"rule[{idx}].users invalid username {u!r}")
                elif k == "ip_cidr":
                    for c in cleaned:
                        try:
                            ipaddress.ip_network(c, strict=False)
                        except ValueError as exc:
                            raise ValueError(f"rule[{idx}].ip_cidr invalid CIDR {c!r}") from exc
                nr[k] = cleaned
                has_cond = True
        if not has_cond:
            raise ValueError(f"rule[{idx}] must specify at least one match condition")
        norm_rules.append(nr)

    return norm_outbounds, {"default_outbound": default_ob, "rules": norm_rules}


def outbound_ir_to_xray(tag: str, ir: dict[str, Any]) -> dict[str, Any]:
    proto = ir["protocol"]
    server, port = ir["server"], ir["port"]

    if proto == "socks5":
        srv: dict[str, Any] = {"address": server, "port": port}
        if ir.get("username") or ir.get("password"):
            srv["users"] = [{"user": ir.get("username", ""), "pass": ir.get("password", "")}]
        return {"tag": tag, "protocol": "socks", "settings": {"servers": [srv]}}

    if proto in ("http", "https"):
        srv = {"address": server, "port": port}
        if ir.get("username") or ir.get("password"):
            srv["users"] = [{"user": ir.get("username", ""), "pass": ir.get("password", "")}]
        ob: dict[str, Any] = {"tag": tag, "protocol": "http", "settings": {"servers": [srv]}}
        if proto == "https":
            ob["streamSettings"] = {
                "security": "tls",
                "tlsSettings": {"serverName": ir["sni"], "allowInsecure": bool(ir["insecure"])},
            }
        return ob

    if proto == "ss":
        return {
            "tag": tag,
            "protocol": "shadowsocks",
            "settings": {
                "servers": [{"address": server, "port": port, "method": ir["cipher"], "password": ir["password"]}]
            },
        }

    if proto == "vless":
        user_obj: dict[str, Any] = {"id": ir["uuid"], "encryption": "none"}
        if ir.get("flow"):
            user_obj["flow"] = ir["flow"]
        net = ir.get("network") or "tcp"
        stream: dict[str, Any] = {"network": "raw" if net == "tcp" else net}
        if net == "ws":
            ws_cfg: dict[str, Any] = {"path": ir.get("path") or "/"}
            if ir.get("host"):
                ws_cfg["headers"] = {"Host": ir["host"]}
            stream["wsSettings"] = ws_cfg
        elif net == "grpc":
            stream["grpcSettings"] = {"serviceName": ir.get("service_name") or ""}
        elif net == "xhttp":
            xh_cfg: dict[str, Any] = {"path": ir.get("path") or "/", "mode": ir.get("mode") or "auto"}
            if ir.get("host"):
                xh_cfg["host"] = ir["host"]
            stream["xhttpSettings"] = xh_cfg

        sec = ir.get("security") or "none"
        if sec == "tls":
            stream["security"] = "tls"
            tls_s: dict[str, Any] = {"serverName": ir["sni"], "allowInsecure": bool(ir["insecure"])}
            if ir.get("fp"):
                tls_s["fingerprint"] = ir["fp"]
            if ir.get("alpn"):
                tls_s["alpn"] = ir["alpn"]
            stream["tlsSettings"] = tls_s
        elif sec == "reality":
            stream["security"] = "reality"
            stream["realitySettings"] = {
                "serverName": ir["sni"],
                "fingerprint": ir.get("fp") or "chrome",
                "publicKey": ir.get("pbk") or "",
                "shortId": ir.get("sid") or "",
            }
        return {
            "tag": tag,
            "protocol": "vless",
            "settings": {"vnext": [{"address": server, "port": port, "users": [user_obj]}]},
            "streamSettings": stream,
        }

    raise ValueError(f"Xray outbound does not natively support protocol {proto}")


def outbound_ir_to_singbox(tag: str, ir: dict[str, Any]) -> dict[str, Any]:
    proto = ir["protocol"]
    server, port = ir["server"], ir["port"]

    if proto == "socks5":
        ob: dict[str, Any] = {"type": "socks", "tag": tag, "server": server, "server_port": port}
        if ir.get("username") or ir.get("password"):
            ob["username"] = ir.get("username", "")
            ob["password"] = ir.get("password", "")
        return ob

    if proto in ("http", "https"):
        ob = {"type": "http", "tag": tag, "server": server, "server_port": port}
        if ir.get("username") or ir.get("password"):
            ob["username"] = ir.get("username", "")
            ob["password"] = ir.get("password", "")
        if proto == "https":
            ob["tls"] = {"enabled": True, "server_name": ir["sni"], "insecure": bool(ir["insecure"])}
        return ob

    if proto == "ss":
        return {
            "type": "shadowsocks",
            "tag": tag,
            "server": server,
            "server_port": port,
            "method": ir["cipher"],
            "password": ir["password"],
        }

    if proto == "anytls":
        pw = ir["password"] if not ir.get("username") else (f"{ir['username']}:{ir['password']}" if ir.get("password") else ir["username"])
        tls_obj: dict[str, Any] = {"enabled": True, "server_name": ir["sni"], "insecure": bool(ir["insecure"])}
        if ir.get("fp"):
            tls_obj["utls"] = {"enabled": True, "fingerprint": ir["fp"]}
        if ir.get("alpn"):
            tls_obj["alpn"] = ir["alpn"]
        return {"type": "anytls", "tag": tag, "server": server, "server_port": port, "password": pw, "tls": tls_obj}

    if proto == "hysteria2":
        pw = f"{ir['username']}:{ir['password']}" if (ir.get("username") and ir.get("password")) else (ir.get("password") or ir.get("username") or "")
        tls_obj = {"enabled": True, "server_name": ir["sni"], "insecure": bool(ir["insecure"])}
        ob = {"type": "hysteria2", "tag": tag, "server": server, "server_port": port, "password": pw, "tls": tls_obj}
        if ir.get("obfs"):
            ob["obfs"] = {"type": ir["obfs"], "password": ir.get("obfs_password", "")}
        return ob

    if proto == "vless":
        ob = {"type": "vless", "tag": tag, "server": server, "server_port": port, "uuid": ir["uuid"]}
        if ir.get("flow"):
            ob["flow"] = ir["flow"]
        net = ir.get("network") or "tcp"
        if net == "ws":
            tr: dict[str, Any] = {"type": "ws", "path": ir.get("path") or "/"}
            if ir.get("host"):
                tr["headers"] = {"Host": ir["host"]}
            ob["transport"] = tr
        elif net == "grpc":
            ob["transport"] = {"type": "grpc", "service_name": ir.get("service_name") or ""}
        if ir.get("tls"):
            tls_obj = {"enabled": True, "server_name": ir["sni"], "insecure": bool(ir["insecure"])}
            if ir.get("fp"):
                tls_obj["utls"] = {"enabled": True, "fingerprint": ir["fp"]}
            if ir.get("alpn"):
                tls_obj["alpn"] = ir["alpn"]
            if ir.get("security") == "reality":
                tls_obj["reality"] = {
                    "enabled": True,
                    "public_key": ir.get("pbk") or "",
                    "short_id": ir.get("sid") or "",
                }
            ob["tls"] = tls_obj
        return ob

    raise ValueError(f"sing-box outbound does not support protocol {proto}")


def _build_hysteria_acl_match(rule: dict[str, Any]) -> str:
    parts: list[str] = []
    if rule.get("users"):
        users_lit = ", ".join(json.dumps(u) for u in rule["users"])
        parts.append(f"auth.id in [{users_lit}]")
    dest_parts: list[str] = []
    for d in rule.get("domains") or []:
        dest_parts.append(f"domain({json.dumps(d)})")
    for ds in rule.get("domain_suffix") or []:
        dest_parts.append(f"suffix({json.dumps(ds)})")
    for gs in rule.get("geosite") or []:
        dest_parts.append(f"geosite({json.dumps(gs)})")
    for cidr in rule.get("ip_cidr") or []:
        dest_parts.append(f"cidr({json.dumps(cidr)})")
    for gi in rule.get("geoip") or []:
        dest_parts.append(f"geoip({json.dumps(gi)})")
    if dest_parts:
        parts.append("(" + " || ".join(dest_parts) + ")")
    return " && ".join(parts)


def _antiloop_servers(parsed_outbounds: list[tuple[str, dict[str, Any]]]) -> tuple[list[str], list[str]]:
    ips: list[str] = []
    domains: list[str] = []
    for _, ir in parsed_outbounds:
        srv = ir["server"]
        try:
            ipaddress.ip_address(srv)
            if srv not in ips:
                ips.append(srv)
        except ValueError:
            if srv not in domains:
                domains.append(srv)
    return ips, domains


class ProxyStateStore:
    def __init__(self, db_path: Path, cfg: dict[str, Any], dry_run_reload: bool = False):
        self.db_path = db_path
        self.cfg = cfg
        self.dry_run_reload = dry_run_reload
        self.lock = threading.RLock()
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        self._init_db()

    @contextmanager
    def _conn(self):
        conn = sqlite3.connect(str(self.db_path), timeout=30.0)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA journal_mode=WAL;")
        conn.execute("PRAGMA synchronous=NORMAL;")
        try:
            yield conn
        finally:
            conn.close()

    def _init_db(self) -> None:
        with self.lock, self._conn() as conn:
            conn.executescript(
                """
                CREATE TABLE IF NOT EXISTS users (
                    username TEXT PRIMARY KEY,
                    quota_bytes INTEGER,
                    status TEXT NOT NULL DEFAULT 'active',
                    creds_json TEXT NOT NULL,
                    created_at INTEGER NOT NULL
                );
                CREATE TABLE IF NOT EXISTS daily_usage (
                    date TEXT NOT NULL,
                    username TEXT NOT NULL,
                    protocol TEXT NOT NULL,
                    up_bytes INTEGER NOT NULL DEFAULT 0,
                    down_bytes INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY (date, username, protocol)
                );
                CREATE INDEX IF NOT EXISTS idx_daily_usage_user_date
                    ON daily_usage(username, date);
                CREATE TABLE IF NOT EXISTS meta (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                );
                """
            )
            now = int(time.time())
            cycle_start, _, _, _ = compute_cycle(self.cfg["timezone"], self.cfg.get("reset_day", 1), now)
            conn.execute("INSERT OR IGNORE INTO meta(key, value) VALUES ('last_sample', ?)", (str(now),))
            conn.execute("INSERT OR IGNORE INTO meta(key, value) VALUES ('last_cycle_start', ?)", (str(cycle_start),))
            conn.commit()

    def get_meta_int(self, key: str, default: int = 0) -> int:
        with self._conn() as conn:
            row = conn.execute("SELECT value FROM meta WHERE key = ?", (key,)).fetchone()
            return int(row["value"]) if row else default

    def set_meta(self, key: str, value: str) -> None:
        with self.lock, self._conn() as conn:
            conn.execute(
                "INSERT INTO meta(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                (key, value),
            )
            conn.commit()

    def get_user(self, username: str) -> dict[str, Any] | None:
        with self._conn() as conn:
            row = conn.execute("SELECT * FROM users WHERE username = ?", (username,)).fetchone()
            if not row:
                return None
            return {
                "username": row["username"],
                "quota_bytes": row["quota_bytes"],
                "status": row["status"],
                "creds": json.loads(row["creds_json"]),
                "created_at": row["created_at"],
            }

    def list_all_users_raw(self) -> list[dict[str, Any]]:
        with self._conn() as conn:
            rows = conn.execute("SELECT * FROM users ORDER BY created_at ASC, username ASC").fetchall()
            return [
                {
                    "username": r["username"],
                    "quota_bytes": r["quota_bytes"],
                    "status": r["status"],
                    "creds": json.loads(r["creds_json"]),
                    "created_at": r["created_at"],
                }
                for r in rows
            ]

    def create_user(self, username: str, quota_bytes: int | None, reload_backends: bool = True) -> dict[str, Any]:
        with self.lock:
            if self.get_user(username) is not None:
                raise FileExistsError(username)
            creds = generate_user_credentials()
            now = int(time.time())
            status = "quota_exceeded" if (quota_bytes is not None and quota_bytes == 0) else "active"
            with self._conn() as conn:
                conn.execute(
                    "INSERT INTO users(username, quota_bytes, status, creds_json, created_at) VALUES (?, ?, ?, ?, ?)",
                    (username, quota_bytes, status, json.dumps(creds), now),
                )
                conn.commit()
            if reload_backends:
                try:
                    self.render_and_reload_backends()
                except Exception as exc:
                    logger.error("Failed to reload backends after creating user %s: %s", username, exc)
                    with self._conn() as conn:
                        conn.execute("DELETE FROM users WHERE username = ?", (username,))
                        conn.commit()
                    raise RuntimeError(f"backend reload failed: {exc}") from exc
            return {
                "user": username,
                "quota_bytes": quota_bytes,
                "links": build_user_links(self.cfg, username, creds),
            }

    def set_quota(self, username: str, quota_bytes: int | None) -> bool:
        with self.lock:
            u = self.get_user(username)
            if not u:
                return False
            _, _, start_date, end_date = compute_cycle(self.cfg["timezone"], self.cfg.get("reset_day", 1))
            used = self.get_user_total_in_range(username, start_date, end_date)
            new_status = "quota_exceeded" if (quota_bytes is not None and used >= quota_bytes) else "active"
            with self._conn() as conn:
                conn.execute(
                    "UPDATE users SET quota_bytes = ?, status = ? WHERE username = ?",
                    (quota_bytes, new_status, username),
                )
                conn.commit()
            if new_status != u["status"]:
                self.render_and_reload_backends(kick_users=[username] if new_status == "quota_exceeded" else None)
            return True

    def delete_user(self, username: str) -> bool:
        with self.lock:
            if not self.get_user(username):
                return False
            with self._conn() as conn:
                conn.execute("DELETE FROM users WHERE username = ?", (username,))
                conn.commit()
            self.render_and_reload_backends(kick_users=[username])
            return True

    def record_deltas(self, deltas: list[tuple[str, str, int, int]], sample_ts: int) -> None:
        """Record (username, protocol, up_bytes, down_bytes) and enforce quotas."""
        tz = ZoneInfo(self.cfg["timezone"])
        today_iso = dt.datetime.fromtimestamp(sample_ts, tz=tz).date().isoformat()
        cycle_start, _, start_date, end_date = compute_cycle(
            self.cfg["timezone"], self.cfg.get("reset_day", 1), sample_ts
        )

        need_reload = False
        kick_list: list[str] = []

        with self.lock:
            prev_cycle = self.get_meta_int("last_cycle_start", cycle_start)
            with self._conn() as conn:
                for uname, proto, up_b, down_b in deltas:
                    if up_b <= 0 and down_b <= 0:
                        continue
                    conn.execute(
                        """
                        INSERT INTO daily_usage(date, username, protocol, up_bytes, down_bytes)
                        VALUES (?, ?, ?, ?, ?)
                        ON CONFLICT(date, username, protocol) DO UPDATE SET
                            up_bytes = up_bytes + excluded.up_bytes,
                            down_bytes = down_bytes + excluded.down_bytes
                        """,
                        (today_iso, uname, proto, int(up_b), int(down_b)),
                    )
                conn.execute(
                    "INSERT INTO meta(key, value) VALUES ('last_sample', ?) "
                    "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                    (str(sample_ts),),
                )
                if cycle_start > prev_cycle:
                    logger.info("New billing cycle detected (%s -> %s), resetting exceeded users", prev_cycle, cycle_start)
                    conn.execute(
                        "INSERT INTO meta(key, value) VALUES ('last_cycle_start', ?) "
                        "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                        (str(cycle_start),),
                    )
                    cur = conn.execute(
                        "UPDATE users SET status = 'active' WHERE status = 'quota_exceeded' AND (quota_bytes IS NULL OR quota_bytes > 0)"
                    )
                    if cur.rowcount > 0:
                        need_reload = True
                conn.commit()

            # Check quota enforcement for active users
            users = self.list_all_users_raw()
            for u in users:
                qb = u["quota_bytes"]
                if qb is None:
                    continue
                used = self.get_user_total_in_range(u["username"], start_date, end_date)
                if u["status"] == "active" and used >= qb:
                    logger.info("User %s exceeded quota (%d >= %d), disabling", u["username"], used, qb)
                    with self._conn() as conn:
                        conn.execute("UPDATE users SET status = 'quota_exceeded' WHERE username = ?", (u["username"],))
                        conn.commit()
                    need_reload = True
                    kick_list.append(u["username"])

        if need_reload:
            try:
                self.render_and_reload_backends(kick_users=kick_list or None)
            except Exception as exc:
                logger.error("Failed to reload backends during quota enforcement: %s", exc)

    def get_user_total_in_range(self, username: str, start_date: str | None, end_date: str | None) -> int:
        with self._conn() as conn:
            if start_date and end_date:
                row = conn.execute(
                    "SELECT COALESCE(SUM(up_bytes + down_bytes), 0) AS t FROM daily_usage "
                    "WHERE username = ? AND date >= ? AND date <= ?",
                    (username, start_date, end_date),
                ).fetchone()
            else:
                row = conn.execute(
                    "SELECT COALESCE(SUM(up_bytes + down_bytes), 0) AS t FROM daily_usage WHERE username = ?",
                    (username,),
                ).fetchone()
            return int(row["t"]) if row else 0

    def query_usage(
        self,
        username: str | None = None,
        period_all: bool = False,
        date_from: str | None = None,
        date_to: str | None = None,
    ) -> dict[str, Any]:
        tz_name = self.cfg["timezone"]
        cycle_start, next_reset, c_start_iso, c_end_iso = compute_cycle(tz_name, self.cfg.get("reset_day", 1))
        last_sample = self.get_meta_int("last_sample", int(time.time()))

        where = []
        params: list[Any] = []
        if username is not None:
            where.append("username = ?")
            params.append(username)
        if period_all:
            pass
        elif date_from and date_to:
            where.append("date >= ? AND date <= ?")
            params.extend([date_from, date_to])
        else:
            where.append("date >= ? AND date <= ?")
            params.extend([c_start_iso, c_end_iso])

        sql = "SELECT protocol, COALESCE(SUM(up_bytes), 0) AS up_b, COALESCE(SUM(down_bytes), 0) AS down_b FROM daily_usage"
        if where:
            sql += " WHERE " + " AND ".join(where)
        sql += " GROUP BY protocol"

        enabled = self.cfg.get("enabled_protocols") or []
        protocols: dict[str, dict[str, int]] = {
            p: {"up_bytes": 0, "down_bytes": 0, "total_bytes": 0} for p in enabled
        }

        with self._conn() as conn:
            for row in conn.execute(sql, params).fetchall():
                p = row["protocol"]
                up_b = int(row["up_b"])
                down_b = int(row["down_b"])
                if p not in protocols:
                    protocols[p] = {"up_bytes": 0, "down_bytes": 0, "total_bytes": 0}
                protocols[p]["up_bytes"] += up_b
                protocols[p]["down_bytes"] += down_b
                protocols[p]["total_bytes"] += up_b + down_b

        total_up = sum(v["up_bytes"] for v in protocols.values())
        total_down = sum(v["down_bytes"] for v in protocols.values())
        return {
            "last_sample": last_sample,
            "cycle_start": cycle_start,
            "next_reset": next_reset,
            "timezone": tz_name,
            "protocols": protocols,
            "up_bytes": total_up,
            "down_bytes": total_down,
            "total_bytes": total_up + total_down,
        }

    def query_users_summary(self) -> dict[str, Any]:
        tz_name = self.cfg["timezone"]
        cycle_start, next_reset, c_start_iso, c_end_iso = compute_cycle(tz_name, self.cfg.get("reset_day", 1))
        last_sample = self.get_meta_int("last_sample", int(time.time()))

        with self._conn() as conn:
            usage_rows = conn.execute(
                "SELECT username, COALESCE(SUM(up_bytes + down_bytes), 0) AS total_b "
                "FROM daily_usage WHERE date >= ? AND date <= ? GROUP BY username",
                (c_start_iso, c_end_iso),
            ).fetchall()
            used_map = {r["username"]: int(r["total_b"]) for r in usage_rows}

        out_users = []
        for u in self.list_all_users_raw():
            uname = u["username"]
            qb = u["quota_bytes"]
            used = used_map.get(uname, 0)
            if qb is None:
                rem = None
                status = "active"
            else:
                rem = max(0, qb - used)
                status = "quota_exceeded" if (used >= qb or u["status"] == "quota_exceeded") else "active"
            out_users.append(
                {
                    "user": uname,
                    "used_bytes": used,
                    "quota_bytes": qb,
                    "remaining_bytes": rem,
                    "status": status,
                }
            )
        return {
            "last_sample": last_sample,
            "cycle_start": cycle_start,
            "next_reset": next_reset,
            "timezone": tz_name,
            "users": out_users,
        }

    # ─── Config Renderers & Backend Reload ─────────────────────────────────

    def render_configs(self) -> dict[str, Path]:
        """Render sing-box, xray, and hysteria2 config files atomically."""
        active_users = [u for u in self.list_all_users_raw() if u["status"] == "active"]
        enabled = self.cfg.get("enabled_protocols") or []
        rendered: dict[str, Path] = {}

        outbounds_raw = self.cfg.get("outbounds") or []
        routing_cfg = self.cfg.get("routing") or {}
        default_outbound = str(routing_cfg.get("default_outbound") or "direct")
        rules = routing_cfg.get("rules") or []

        parsed_obs: list[tuple[str, dict[str, Any]]] = []
        for ob in outbounds_raw:
            parsed_obs.append((str(ob["tag"]), parse_outbound_uri(str(ob["uri"]))))

        antiloop_ips, antiloop_domains = _antiloop_servers(parsed_obs)

        xray_protos_order = ("vless_xhttp_tls", "vless_xhttp", "vless_reality", "ss2022")
        active_xray_protos = [pr for pr in xray_protos_order if pr in enabled]
        xray_has_proxy_inbounds = len(active_xray_protos) > 0
        sb_has_proxy_inbounds = "anytls" in enabled

        # Determine which backend hosts local SOCKS5 bridges for Hysteria2
        bridge_host: str | None = None
        bridge_ports: dict[str, int] = {}
        if "hy2" in enabled and parsed_obs:
            xray_supported = all(ir["protocol"] in ("socks5", "http", "https", "ss", "vless") for _, ir in parsed_obs)
            if xray_has_proxy_inbounds and xray_supported:
                bridge_host = "xray"
            elif sb_has_proxy_inbounds:
                bridge_host = "sing-box"
            elif xray_supported and Path("/usr/local/bin/xray").exists():
                bridge_host = "xray"
            elif Path("/usr/local/bin/sing-box").exists():
                bridge_host = "sing-box"
            else:
                bridge_host = "xray" if xray_supported else "sing-box"
            for idx, (tag, _) in enumerate(parsed_obs):
                bridge_ports[tag] = 19100 + idx

        need_singbox_cfg = sb_has_proxy_inbounds or (bridge_host == "sing-box")
        need_xray_cfg = xray_has_proxy_inbounds or (bridge_host == "xray")

        if need_singbox_cfg:
            sb_inbounds: list[dict[str, Any]] = []
            if sb_has_proxy_inbounds:
                sb_inbounds.append(
                    {
                        "type": "anytls",
                        "tag": "anytls-in",
                        "listen": "127.0.0.1",
                        "listen_port": int(self.cfg["anytls"]["local_port"]),
                        "users": [
                            {"name": u["username"], "password": u["creds"]["anytls_password"]}
                            for u in active_users
                        ],
                        "tls": {"enabled": False},
                    }
                )
            if bridge_host == "sing-box":
                for tag, _ in parsed_obs:
                    sb_inbounds.append(
                        {
                            "type": "socks",
                            "tag": f"hy2-bridge-{tag}",
                            "listen": "127.0.0.1",
                            "listen_port": bridge_ports[tag],
                        }
                    )

            sb_outbounds: list[dict[str, Any]] = [{"type": "direct", "tag": "direct"}]
            for tag, ir in parsed_obs:
                sb_outbounds.append(outbound_ir_to_singbox(tag, ir))

            sb_rules: list[dict[str, Any]] = []
            if antiloop_ips or antiloop_domains:
                anti_rule: dict[str, Any] = {"outbound": "direct"}
                if antiloop_ips:
                    anti_rule["ip_cidr"] = [f"{ip}/32" if ":" not in ip else f"{ip}/128" for ip in antiloop_ips]
                if antiloop_domains:
                    anti_rule["domain"] = list(antiloop_domains)
                sb_rules.append(anti_rule)

            if bridge_host == "sing-box":
                for tag, _ in parsed_obs:
                    sb_rules.append({"inbound": [f"hy2-bridge-{tag}"], "outbound": tag})

            rule_sets: list[dict[str, Any]] = []
            seen_rs: set[str] = set()

            def _ensure_rs(kind: str, name: str) -> str:
                rs_tag = f"{kind}-{name}"
                if rs_tag not in seen_rs:
                    seen_rs.add(rs_tag)
                    repo = "sing-geosite" if kind == "geosite" else "sing-geoip"
                    rule_sets.append(
                        {
                            "tag": rs_tag,
                            "type": "remote",
                            "format": "binary",
                            "url": f"https://raw.githubusercontent.com/SagerNet/{repo}/rule-set/{rs_tag}.srs",
                            "download_detour": "direct",
                        }
                    )
                return rs_tag

            if sb_has_proxy_inbounds:
                for r in rules:
                    sr: dict[str, Any] = {"outbound": r["outbound"]}
                    if r.get("users"):
                        sr["auth_user"] = list(r["users"])
                    if r.get("domains"):
                        sr["domain"] = list(r["domains"])
                    if r.get("domain_suffix"):
                        sr["domain_suffix"] = list(r["domain_suffix"])
                    if r.get("ip_cidr"):
                        sr["ip_cidr"] = list(r["ip_cidr"])
                    rs_tags: list[str] = []
                    for gs in r.get("geosite") or []:
                        rs_tags.append(_ensure_rs("geosite", gs))
                    for gi in r.get("geoip") or []:
                        rs_tags.append(_ensure_rs("geoip", gi))
                    if rs_tags:
                        sr["rule_set"] = rs_tags
                    if sb_has_proxy_inbounds and bridge_host == "sing-box":
                        sr["inbound"] = ["anytls-in"]
                    sb_rules.append(sr)

            sb_route: dict[str, Any] = {"final": default_outbound}
            if sb_rules:
                sb_route["rules"] = sb_rules
            if rule_sets:
                sb_route["rule_set"] = rule_sets

            sb_cfg: dict[str, Any] = {
                "log": {"disabled": False, "level": "warn", "timestamp": True},
                "inbounds": sb_inbounds,
                "outbounds": sb_outbounds,
                "route": sb_route,
            }
            if sb_has_proxy_inbounds:
                sb_cfg["experimental"] = {
                    "v2ray_api": {
                        "listen": f"127.0.0.1:{int(self.cfg['anytls']['stats_port'])}",
                        "stats": {
                            "enabled": True,
                            "inbounds": ["anytls-in"],
                            "users": [u["username"] for u in active_users],
                        },
                    }
                }
            p = STACK_DIR / "sing-box.json"
            self._write_atomic(p, json.dumps(sb_cfg, indent=2))
            rendered["sing-box"] = p

        if "hy2" in enabled:
            hy2 = self.cfg["hy2"]
            lines = [
                "listen: :443",
                "tls:",
                f"  cert: {hy2['cert_path']}",
                f"  key: {hy2['key_path']}",
                "auth:",
                "  type: userpass",
                "  userpass:",
            ]
            if active_users:
                for u in active_users:
                    lines.append(f"    {u['username']}: \"{u['creds']['hy2_password']}\"")
            else:
                lines.append(f"    __disabled_placeholder__: \"{secrets.token_hex(16)}\"")
            lines.extend(
                [
                    "trafficStats:",
                    f"  listen: 127.0.0.1:{int(hy2['stats_port'])}",
                    f"  secret: \"{hy2['stats_secret']}\"",
                    "masquerade:",
                    "  type: file",
                    "  file:",
                    f"    dir: {self.cfg['web_root']}",
                ]
            )
            if parsed_obs:
                lines.append("outbounds:")
                lines.append("  - name: direct")
                lines.append("    type: direct")
                for tag, _ in parsed_obs:
                    lines.append(f"  - name: {tag}")
                    lines.append("    type: socks5")
                    lines.append("    socks5:")
                    lines.append(f"      addr: 127.0.0.1:{bridge_ports[tag]}")
            if parsed_obs and (rules or default_outbound != "direct"):
                lines.append("acl:")
                if Path("/usr/local/share/xray/geoip.dat").is_file():
                    lines.append("  geoip: /usr/local/share/xray/geoip.dat")
                if Path("/usr/local/share/xray/geosite.dat").is_file():
                    lines.append("  geosite: /usr/local/share/xray/geosite.dat")
                lines.append("  rules:")
                if antiloop_ips or antiloop_domains:
                    anti_parts = [f"ip({json.dumps(ip)})" for ip in antiloop_ips] + [
                        f"domain({json.dumps(d)})" for d in antiloop_domains
                    ]
                    lines.append("    - outbound: direct")
                    lines.append(f"      match: {' || '.join(anti_parts)}")
                for r in rules:
                    expr = _build_hysteria_acl_match(r)
                    if expr:
                        lines.append(f"    - outbound: {r['outbound']}")
                        lines.append(f"      match: {expr}")
                lines.append(f"    - outbound: {default_outbound}")

            p = STACK_DIR / "hysteria.yaml"
            self._write_atomic(p, "\n".join(lines) + "\n")
            rendered["hysteria"] = p

        if need_xray_cfg:
            inbounds: list[dict[str, Any]] = [
                {
                    "tag": "api-in",
                    "listen": "127.0.0.1",
                    "port": int(self.cfg["xray"]["stats_port"]),
                    "protocol": "dokodemo-door",
                    "settings": {"address": "127.0.0.1"},
                }
            ]
            xray_proxy_inbound_tags: list[str] = []

            if "vless_xhttp_tls" in enabled:
                xcfg = self.cfg["vless_xhttp_tls"]
                xray_proxy_inbound_tags.append("vless-xhttp-tls-in")
                inbounds.append(
                    {
                        "tag": "vless-xhttp-tls-in",
                        "listen": "127.0.0.1",
                        "port": int(xcfg["local_port"]),
                        "protocol": "vless",
                        "settings": {
                            "decryption": "none",
                            "clients": [
                                {"id": u["creds"]["vless_uuid"], "email": f"{u['username']}:vless_xhttp_tls"}
                                for u in active_users
                            ],
                        },
                        "streamSettings": {
                            "network": "xhttp",
                            "security": "none",
                            "xhttpSettings": {"path": xcfg["path"], "mode": "auto"},
                        },
                    }
                )

            if "vless_xhttp" in enabled:
                xcfg = self.cfg["vless_xhttp"]
                xray_proxy_inbound_tags.append("vless-xhttp-in")
                inbounds.append(
                    {
                        "tag": "vless-xhttp-in",
                        "listen": "127.0.0.1",
                        "port": int(xcfg["local_port"]),
                        "protocol": "vless",
                        "settings": {
                            "decryption": "none",
                            "clients": [
                                {"id": u["creds"]["vless_uuid"], "email": f"{u['username']}:vless_xhttp"}
                                for u in active_users
                            ],
                        },
                        "streamSettings": {
                            "network": "xhttp",
                            "security": "none",
                            "xhttpSettings": {"path": xcfg["path"], "mode": "auto"},
                        },
                    }
                )

            if "vless_reality" in enabled:
                rcfg = self.cfg["vless_reality"]
                xray_proxy_inbound_tags.append("vless-reality-in")
                inbounds.append(
                    {
                        "tag": "vless-reality-in",
                        "listen": "0.0.0.0",
                        "port": int(rcfg["port"]),
                        "protocol": "vless",
                        "settings": {
                            "decryption": "none",
                            "clients": [
                                {
                                    "id": u["creds"]["vless_uuid"],
                                    "flow": "xtls-rprx-vision",
                                    "email": f"{u['username']}:vless_reality",
                                }
                                for u in active_users
                            ],
                        },
                        "streamSettings": {
                            "network": "raw",
                            "security": "reality",
                            "realitySettings": {
                                "show": False,
                                "target": rcfg["dest"],
                                "xver": 0,
                                "serverNames": [rcfg["sni"]],
                                "privateKey": rcfg["private_key"],
                                "shortIds": [rcfg["short_id"]],
                            },
                        },
                    }
                )

            if "ss2022" in enabled:
                scfg = self.cfg["ss2022"]
                xray_proxy_inbound_tags.append("ss2022-in")
                inbounds.append(
                    {
                        "tag": "ss2022-in",
                        "listen": "0.0.0.0",
                        "port": int(scfg["port"]),
                        "protocol": "shadowsocks",
                        "settings": {
                            "method": scfg.get("method", "2022-blake3-aes-128-gcm"),
                            "password": scfg["server_psk"],
                            "network": "tcp,udp",
                            "clients": [
                                {"password": u["creds"]["ss2022_psk"], "email": f"{u['username']}:ss2022"}
                                for u in active_users
                            ],
                        },
                    }
                )

            if bridge_host == "xray":
                for tag, _ in parsed_obs:
                    inbounds.append(
                        {
                            "tag": f"hy2-bridge-{tag}",
                            "listen": "127.0.0.1",
                            "port": bridge_ports[tag],
                            "protocol": "socks",
                            "settings": {"auth": "noauth", "udp": True},
                        }
                    )

            xray_outbounds: list[dict[str, Any]] = [
                {"tag": "direct", "protocol": "freedom"},
                {"tag": "blocked", "protocol": "blackhole"},
            ]
            for tag, ir in parsed_obs:
                if ir["protocol"] in ("socks5", "http", "https", "ss", "vless"):
                    xray_outbounds.append(outbound_ir_to_xray(tag, ir))

            xray_rules: list[dict[str, Any]] = [
                {"type": "field", "inboundTag": ["api-in"], "outboundTag": "api"}
            ]
            if antiloop_ips or antiloop_domains:
                anti_x: dict[str, Any] = {"type": "field", "outboundTag": "direct"}
                if antiloop_ips:
                    anti_x["ip"] = list(antiloop_ips)
                if antiloop_domains:
                    anti_x["domain"] = [f"full:{d}" for d in antiloop_domains]
                xray_rules.append(anti_x)

            if bridge_host == "xray":
                for tag, _ in parsed_obs:
                    xray_rules.append(
                        {"type": "field", "inboundTag": [f"hy2-bridge-{tag}"], "outboundTag": tag}
                    )

            if xray_proxy_inbound_tags:
                for r in rules:
                    xr: dict[str, Any] = {
                        "type": "field",
                        "inboundTag": xray_proxy_inbound_tags,
                        "outboundTag": r["outbound"],
                    }
                    if r.get("users"):
                        xr["user"] = [f"{u}:{pr}" for u in r["users"] for pr in active_xray_protos]
                    dom_list: list[str] = []
                    for d in r.get("domains") or []:
                        dom_list.append(f"full:{d}")
                    for ds in r.get("domain_suffix") or []:
                        dom_list.append(f"domain:{ds}")
                    for gs in r.get("geosite") or []:
                        dom_list.append(f"geosite:{gs}")
                    if dom_list:
                        xr["domain"] = dom_list
                    ip_list: list[str] = list(r.get("ip_cidr") or [])
                    for gi in r.get("geoip") or []:
                        ip_list.append(f"geoip:{gi}")
                    if ip_list:
                        xr["ip"] = ip_list
                    xray_rules.append(xr)

                if default_outbound != "direct":
                    xray_rules.append(
                        {
                            "type": "field",
                            "inboundTag": xray_proxy_inbound_tags,
                            "outboundTag": default_outbound,
                        }
                    )

            xray_cfg = {
                "log": {"loglevel": "warning"},
                "stats": {},
                "api": {"tag": "api", "services": ["StatsService"]},
                "policy": {
                    "levels": {"0": {"statsUserUplink": True, "statsUserDownlink": True}},
                    "system": {"statsInboundUplink": True, "statsInboundDownlink": True},
                },
                "inbounds": inbounds,
                "outbounds": xray_outbounds,
                "routing": {"domainStrategy": "AsIs", "rules": xray_rules},
            }
            p = STACK_DIR / "xray.json"
            self._write_atomic(p, json.dumps(xray_cfg, indent=2))
            rendered["xray"] = p

        return rendered

    def get_routing_masked(self) -> dict[str, Any]:
        outbounds_out = []
        for ob in self.cfg.get("outbounds") or []:
            tag = str(ob.get("tag") or "")
            raw_uri = str(ob.get("uri") or "")
            try:
                ir = parse_outbound_uri(raw_uri)
                outbounds_out.append(
                    {
                        "tag": tag,
                        "uri": mask_outbound_uri(raw_uri),
                        "protocol": ir["protocol"],
                        "server": ir["server"],
                        "port": ir["port"],
                    }
                )
            except Exception:
                outbounds_out.append({"tag": tag, "uri": "***", "protocol": "unknown", "server": "", "port": 0})
        routing = self.cfg.get("routing") or {}
        return {
            "default_outbound": routing.get("default_outbound") or "direct",
            "outbounds": outbounds_out,
            "rules": routing.get("rules") or [],
        }

    def update_routing(self, payload: dict[str, Any]) -> dict[str, Any]:
        with self.lock:
            norm_obs, norm_routing = validate_and_normalize_routing_payload(
                payload, existing_outbounds=self.cfg.get("outbounds") or []
            )
            old_cfg = copy.deepcopy(self.cfg)
            cfg_file = STACK_DIR / "config.json"
            backups: dict[Path, bytes | None] = {}
            for fp in (cfg_file, STACK_DIR / "sing-box.json", STACK_DIR / "xray.json", STACK_DIR / "hysteria.yaml"):
                backups[fp] = fp.read_bytes() if fp.exists() else None

            self.cfg["outbounds"] = norm_obs
            self.cfg["routing"] = norm_routing
            try:
                self._write_atomic(cfg_file, json.dumps(self.cfg, indent=2, ensure_ascii=False))
                self.render_and_reload_backends()
            except Exception as exc:
                self.cfg = old_cfg
                for fp, data in backups.items():
                    if data is None:
                        fp.unlink(missing_ok=True)
                    else:
                        fp.write_bytes(data)
                        os.chmod(fp, 0o600)
                if isinstance(exc, ValueError):
                    raise
                raise RuntimeError(f"backend reload failed: {exc}") from exc
            return self.get_routing_masked()

    @staticmethod
    def _write_atomic(path: Path, content: str) -> None:
        tmp = path.with_suffix(path.suffix + ".tmp")
        tmp.write_text(content, encoding="utf-8")
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)

    def render_and_reload_backends(self, kick_users: list[str] | None = None) -> None:
        rendered = self.render_configs()
        if self.dry_run_reload:
            return
        if "sing-box" in rendered:
            subprocess.run(["/usr/local/bin/sing-box", "check", "-c", str(rendered["sing-box"])], check=True, timeout=15)
            subprocess.run(["systemctl", "restart", "sing-box-proxy"], check=True, timeout=20)
        if "xray" in rendered:
            subprocess.run(["/usr/local/bin/xray", "run", "-test", "-config", str(rendered["xray"])], check=True, timeout=15)
            subprocess.run(["systemctl", "restart", "xray-proxy"], check=True, timeout=20)
        if "hysteria" in rendered:
            if kick_users:
                self._kick_hy2_users(kick_users)
            subprocess.run(["systemctl", "restart", "hysteria-proxy"], check=True, timeout=20)

    def _kick_hy2_users(self, usernames: list[str]) -> None:
        hy2 = self.cfg.get("hy2") or {}
        if not hy2:
            return
        url = f"http://127.0.0.1:{int(hy2['stats_port'])}/kick"
        req = urllib.request.Request(
            url,
            data=json.dumps(usernames).encode("utf-8"),
            headers={"Authorization": hy2["stats_secret"], "Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=3):
                pass
        except Exception:
            pass


# ─── Traffic Collectors ───────────────────────────────────────────────────────

def parse_xray_stats_json(raw_json: str) -> list[tuple[str, str, int, int]]:
    """Parse `xray api statsquery --reset` output into (username, protocol, up, down)."""
    data = json.loads(raw_json or "{}")
    acc: dict[tuple[str, str], list[int]] = {}
    for item in data.get("stat") or []:
        name = str(item.get("name") or "")
        val = int(item.get("value") or 0)
        if val <= 0:
            continue
        parts = name.split(">>>")
        if len(parts) == 4 and parts[0] == "user" and parts[2] == "traffic":
            email = parts[1]
            direction = parts[3]
            if ":" not in email:
                continue
            uname, proto = email.rsplit(":", 1)
            bucket = acc.setdefault((uname, proto), [0, 0])
            if direction == "uplink":
                bucket[0] += val
            elif direction == "downlink":
                bucket[1] += val
    return [(u, p, v[0], v[1]) for (u, p), v in acc.items()]


def parse_singbox_stats_json(raw_json: str) -> list[tuple[str, str, int, int]]:
    """Parse grpcurl QueryStats JSON output into (username, 'anytls', up, down)."""
    data = json.loads(raw_json or "{}")
    acc: dict[str, list[int]] = {}
    for item in data.get("stat") or []:
        name = str(item.get("name") or "")
        val = int(item.get("value") or 0)
        if val <= 0:
            continue
        parts = name.split(">>>")
        if len(parts) == 4 and parts[0] == "user" and parts[2] == "traffic":
            uname = parts[1]
            direction = parts[3]
            bucket = acc.setdefault(uname, [0, 0])
            if direction == "uplink":
                bucket[0] += val
            elif direction == "downlink":
                bucket[1] += val
    return [(u, "anytls", v[0], v[1]) for u, v in acc.items()]


def parse_hy2_stats_json(raw_json: str) -> list[tuple[str, str, int, int]]:
    """Parse Hysteria2 GET /traffic?clear=1 JSON into (username, 'hy2', up, down).
    Note: Hysteria2 tx = client->server (uplink), rx = server->client (downlink).
    """
    data = json.loads(raw_json or "{}")
    out: list[tuple[str, str, int, int]] = []
    for uname, stats in data.items():
        if not isinstance(stats, dict):
            continue
        up_b = int(stats.get("tx") or 0)
        down_b = int(stats.get("rx") or 0)
        if up_b > 0 or down_b > 0:
            out.append((str(uname), "hy2", up_b, down_b))
    return out


class CollectorThread(threading.Thread):
    def __init__(self, store: ProxyStateStore, interval: int = 10):
        super().__init__(daemon=True, name="traffic-collector")
        self.store = store
        self.interval = interval
        self._stop = threading.Event()
        self._last_cert_sync = 0.0

    def stop(self) -> None:
        self._stop.set()

    def run(self) -> None:
        while not self._stop.is_set():
            try:
                self.collect_once()
            except Exception as exc:
                logger.warning("Traffic collect iteration error: %s", exc)
            try:
                now = time.time()
                if now - self._last_cert_sync >= 300:
                    self.sync_hy2_cert()
                    self._last_cert_sync = now
            except Exception as exc:
                logger.warning("Hy2 cert sync error: %s", exc)
            self._stop.wait(self.interval)

    def collect_once(self) -> None:
        cfg = self.store.cfg
        enabled = cfg.get("enabled_protocols") or []
        deltas: list[tuple[str, str, int, int]] = []
        any_success = False

        if any(p in enabled for p in ("vless_xhttp_tls", "vless_xhttp", "vless_reality", "ss2022")):
            try:
                res = subprocess.run(
                    [
                        "/usr/local/bin/xray",
                        "api",
                        "statsquery",
                        f"--server=127.0.0.1:{int(cfg['xray']['stats_port'])}",
                        "--reset",
                    ],
                    capture_output=True,
                    text=True,
                    timeout=5,
                    check=True,
                )
                deltas.extend(parse_xray_stats_json(res.stdout))
                any_success = True
            except Exception as exc:
                logger.debug("Xray stats query failed: %s", exc)

        if "anytls" in enabled:
            try:
                res = subprocess.run(
                    [
                        "/usr/local/bin/grpcurl",
                        "-plaintext",
                        "-import-path",
                        str(STACK_DIR),
                        "-proto",
                        "stats.proto",
                        "-d",
                        '{"pattern":"","reset":true}',
                        f"127.0.0.1:{int(cfg['anytls']['stats_port'])}",
                        "v2ray.core.app.stats.command.StatsService/QueryStats",
                    ],
                    capture_output=True,
                    text=True,
                    timeout=5,
                    check=True,
                )
                deltas.extend(parse_singbox_stats_json(res.stdout))
                any_success = True
            except Exception as exc:
                logger.debug("sing-box stats query failed: %s", exc)

        if "hy2" in enabled:
            try:
                hy2 = cfg["hy2"]
                req = urllib.request.Request(
                    f"http://127.0.0.1:{int(hy2['stats_port'])}/traffic?clear=1",
                    headers={"Authorization": hy2["stats_secret"]},
                )
                with urllib.request.urlopen(req, timeout=5) as resp:
                    deltas.extend(parse_hy2_stats_json(resp.read().decode("utf-8")))
                any_success = True
            except Exception as exc:
                logger.debug("Hysteria2 stats query failed: %s", exc)

        if any_success or not enabled:
            self.store.record_deltas(deltas, int(time.time()))

    def sync_hy2_cert(self) -> None:
        cfg = self.store.cfg
        if "hy2" not in (cfg.get("enabled_protocols") or []):
            return
        hy2_domain = cfg["hy2"]["domain"]
        caddy_cert_root = Path("/var/lib/caddy/.local/share/caddy/certificates")
        if not caddy_cert_root.exists():
            return
        found_crt: Path | None = None
        found_key: Path | None = None
        for crt in caddy_cert_root.glob(f"*/{hy2_domain}/{hy2_domain}.crt"):
            key = crt.with_suffix(".key")
            if crt.is_file() and key.is_file():
                found_crt, found_key = crt, key
                break
        if not found_crt or not found_key:
            return
        dst_crt = Path(cfg["hy2"]["cert_path"])
        dst_key = Path(cfg["hy2"]["key_path"])
        changed = (
            not dst_crt.exists()
            or not dst_key.exists()
            or dst_crt.read_bytes() != found_crt.read_bytes()
            or dst_key.read_bytes() != found_key.read_bytes()
        )
        if changed:
            dst_crt.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(found_crt, dst_crt)
            shutil.copy2(found_key, dst_key)
            os.chmod(dst_key, 0o600)
            logger.info("Synced renewed TLS certificate for Hysteria2 (%s), restarting hysteria-proxy", hy2_domain)
            subprocess.run(["systemctl", "restart", "hysteria-proxy"], check=False, timeout=20)


# ─── HTTP API Server ──────────────────────────────────────────────────────────

def load_admin_token(token_path: Path = TOKEN_PATH) -> str:
    try:
        return token_path.read_text(encoding="utf-8").strip()
    except OSError:
        return ""


def make_api_handler(store: ProxyStateStore, token_path: Path = TOKEN_PATH):
    class ApiHandler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt: str, *args: Any) -> None:
            logger.info("%s - %s", self.client_address[0], fmt % args)

        def _send_json(self, code: int, payload: dict[str, Any]) -> None:
            raw = json.dumps(payload, ensure_ascii=False).encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(raw)))
            self.send_header("Cache-Control", "no-store")
            if code >= 400:
                self.send_header("Connection", "close")
                self.close_connection = True
            self.end_headers()
            self.wfile.write(raw)

        def _check_auth(self) -> bool:
            expected = load_admin_token(token_path)
            auth = self.headers.get("Authorization") or ""
            if not expected or not auth.startswith("Bearer "):
                self._send_json(401, {"error": "unauthorized"})
                return False
            provided = auth[7:].strip()
            if not hmac.compare_digest(provided, expected):
                self._send_json(401, {"error": "unauthorized"})
                return False
            return True

        def _parse_usage_query(self, query_str: str) -> tuple[bool, bool, str | None, str | None]:
            """Return (ok, period_all, date_from, date_to)."""
            if not query_str:
                return True, False, None, None
            qs = urllib.parse.parse_qs(query_str, keep_blank_values=True)
            allowed_keys = {"period", "from", "to"}
            if not set(qs.keys()).issubset(allowed_keys):
                return False, False, None, None
            for vals in qs.values():
                if len(vals) != 1:
                    return False, False, None, None
            has_period = "period" in qs
            has_from = "from" in qs
            has_to = "to" in qs
            if has_period and (has_from or has_to):
                return False, False, None, None
            if has_period:
                if qs["period"][0] != "all":
                    return False, False, None, None
                return True, True, None, None
            if has_from or has_to:
                if not (has_from and has_to):
                    return False, False, None, None
                d_from = parse_date_strict(qs["from"][0])
                d_to = parse_date_strict(qs["to"][0])
                if not d_from or not d_to or d_from > d_to:
                    return False, False, None, None
                return True, False, d_from.isoformat(), d_to.isoformat()
            return False, False, None, None

        def do_GET(self) -> None:
            if not self._check_auth():
                return
            parsed = urllib.parse.urlsplit(self.path)
            path = parsed.path

            # GET /api/v1/users  (strictly NO query parameters; any query -> 404 per spec)
            if path == "/api/v1/users":
                if parsed.query:
                    self._send_json(404, {"error": "not found"})
                    return
                self._send_json(200, store.query_users_summary())
                return

            # GET /api/v1/usage
            if path == "/api/v1/usage":
                ok, p_all, d_from, d_to = self._parse_usage_query(parsed.query)
                if not ok:
                    self._send_json(400, {"error": "invalid usage query parameters"})
                    return
                self._send_json(200, store.query_usage(None, p_all, d_from, d_to))
                return

            # GET /api/v1/users/{username}/links
            m_links = re.fullmatch(r"/api/v1/users/([^/]+)/links", path)
            if m_links:
                if parsed.query:
                    self._send_json(404, {"error": "not found"})
                    return
                uname = urllib.parse.unquote(m_links.group(1))
                if not USERNAME_RE.match(uname):
                    self._send_json(400, {"error": "invalid username"})
                    return
                u = store.get_user(uname)
                if not u:
                    self._send_json(404, {"error": "user not found"})
                    return
                self._send_json(
                    200,
                    {
                        "user": u["username"],
                        "quota_bytes": u["quota_bytes"],
                        "links": build_user_links(store.cfg, u["username"], u["creds"]),
                    },
                )
                return

            # GET /api/v1/users/{username}/usage
            m_usage = re.fullmatch(r"/api/v1/users/([^/]+)/usage", path)
            if m_usage:
                uname = urllib.parse.unquote(m_usage.group(1))
                if not USERNAME_RE.match(uname):
                    self._send_json(400, {"error": "invalid username"})
                    return
                ok, p_all, d_from, d_to = self._parse_usage_query(parsed.query)
                if not ok:
                    self._send_json(400, {"error": "invalid usage query parameters"})
                    return
                if not store.get_user(uname):
                    self._send_json(404, {"error": "user not found"})
                    return
                self._send_json(200, store.query_usage(uname, p_all, d_from, d_to))
                return

            # GET /api/v1/routing
            if path == "/api/v1/routing":
                if parsed.query:
                    self._send_json(404, {"error": "not found"})
                    return
                self._send_json(200, store.get_routing_masked())
                return

            self._send_json(404, {"error": "not found"})

        def _drain_body(self, max_drain: int = 65536) -> None:
            try:
                clen = int(self.headers.get("Content-Length") or "0")
            except ValueError:
                clen = 0
            if 0 < clen <= max_drain:
                try:
                    self.rfile.read(clen)
                except Exception:
                    pass

        def do_POST(self) -> None:
            if not self._check_auth():
                self._drain_body()
                return
            parsed = urllib.parse.urlsplit(self.path)
            if parsed.path != "/api/v1/users" or parsed.query:
                self._drain_body()
                self._send_json(404, {"error": "not found"})
                return

            ctype = (self.headers.get("Content-Type") or "").split(";", 1)[0].strip().lower()
            if ctype != "application/json":
                self._drain_body()
                self._send_json(415, {"error": "Content-Type must be application/json"})
                return

            try:
                clen = int(self.headers.get("Content-Length") or "0")
            except ValueError:
                self._send_json(400, {"error": "invalid Content-Length"})
                return
            if clen > 4096:
                self._drain_body()
                self._send_json(413, {"error": "payload too large (max 4096 bytes)"})
                return
            raw_body = self.rfile.read(min(clen, 4097))
            if len(raw_body) > 4096:
                self._send_json(413, {"error": "payload too large (max 4096 bytes)"})
                return

            try:
                body = json.loads(raw_body.decode("utf-8"))
            except Exception:
                self._send_json(400, {"error": "invalid JSON"})
                return
            if not isinstance(body, dict) or not set(body.keys()).issubset({"username", "quota"}):
                self._send_json(400, {"error": "request body accepts only username and optional quota"})
                return

            uname = body.get("username")
            if not isinstance(uname, str) or not USERNAME_RE.match(uname):
                self._send_json(400, {"error": "invalid username"})
                return

            if "quota" in body:
                ok_q, quota_bytes = parse_quota(body["quota"])
                if not ok_q:
                    self._send_json(400, {"error": "invalid quota format"})
                    return
            else:
                quota_bytes = None

            try:
                result = store.create_user(uname, quota_bytes, reload_backends=True)
            except FileExistsError:
                self._send_json(409, {"error": "username already exists"})
                return
            except RuntimeError as exc:
                self._send_json(503, {"error": str(exc)})
                return

            self._send_json(201, result)

        def do_PUT(self) -> None:
            if not self._check_auth():
                self._drain_body()
                return
            parsed = urllib.parse.urlsplit(self.path)
            if parsed.path != "/api/v1/routing" or parsed.query:
                self._drain_body()
                self._send_json(404, {"error": "not found"})
                return

            ctype = (self.headers.get("Content-Type") or "").split(";", 1)[0].strip().lower()
            if ctype != "application/json":
                self._drain_body()
                self._send_json(415, {"error": "Content-Type must be application/json"})
                return

            try:
                clen = int(self.headers.get("Content-Length") or "0")
            except ValueError:
                self._send_json(400, {"error": "invalid Content-Length"})
                return
            if clen > 65536:
                self._drain_body(max_drain=131072)
                self._send_json(413, {"error": "payload too large (max 65536 bytes)"})
                return
            raw_body = self.rfile.read(min(clen, 65537))
            if len(raw_body) > 65536:
                self._send_json(413, {"error": "payload too large (max 65536 bytes)"})
                return

            try:
                body = json.loads(raw_body.decode("utf-8"))
            except Exception:
                self._send_json(400, {"error": "invalid JSON"})
                return

            try:
                result = store.update_routing(body)
            except ValueError as exc:
                self._send_json(400, {"error": str(exc)})
                return
            except RuntimeError as exc:
                self._send_json(503, {"error": str(exc)})
                return

            self._send_json(200, result)

        def do_DELETE(self) -> None:
            if not self._check_auth():
                return
            self._send_json(404, {"error": "not found"})

    return ApiHandler


def run_server() -> None:
    cfg = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
    store = ProxyStateStore(DB_PATH, cfg)
    store.render_configs()
    collector = CollectorThread(store, interval=10)
    collector.start()
    listen_port = int(cfg.get("api_port", 19090))
    server = ThreadingHTTPServer(("127.0.0.1", listen_port), make_api_handler(store))
    logger.info("proxy-manager API listening on 127.0.0.1:%d", listen_port)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        collector.stop()
        server.server_close()


def cli_main(argv: list[str]) -> int:
    if not argv:
        print("Usage: proxy_manager.py [serve|init-owner|render|cli ...]")
        return 1
    cmd = argv[0]
    if cmd == "serve":
        run_server()
        return 0

    cfg = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
    store = ProxyStateStore(DB_PATH, cfg)

    if cmd == "init-owner":
        if store.get_user("owner") is None:
            res = store.create_user("owner", None, reload_backends=False)
            store.render_configs()
            print(json.dumps(res, indent=2, ensure_ascii=False))
        else:
            u = store.get_user("owner")
            store.render_configs()
            print(
                json.dumps(
                    {
                        "user": "owner",
                        "quota_bytes": u["quota_bytes"],
                        "links": build_user_links(cfg, "owner", u["creds"]),
                    },
                    indent=2,
                    ensure_ascii=False,
                )
            )
        return 0

    if cmd == "render":
        store.render_and_reload_backends()
        return 0

    if cmd == "list":
        print(json.dumps(store.query_users_summary(), indent=2, ensure_ascii=False))
        return 0

    if cmd == "links" and len(argv) == 2:
        u = store.get_user(argv[1])
        if not u:
            print(f"User not found: {argv[1]}", file=sys.stderr)
            return 1
        print(
            json.dumps(
                {
                    "user": u["username"],
                    "quota_bytes": u["quota_bytes"],
                    "links": build_user_links(cfg, u["username"], u["creds"]),
                },
                indent=2,
                ensure_ascii=False,
            )
        )
        return 0

    if cmd == "create" and len(argv) in (2, 3):
        uname = argv[1]
        if not USERNAME_RE.match(uname):
            print("Invalid username", file=sys.stderr)
            return 1
        q_arg = argv[2] if len(argv) == 3 else None
        ok_q, qb = parse_quota(q_arg)
        if not ok_q:
            print("Invalid quota", file=sys.stderr)
            return 1
        res = store.create_user(uname, qb, reload_backends=True)
        print(json.dumps(res, indent=2, ensure_ascii=False))
        return 0

    if cmd == "set-quota" and len(argv) == 3:
        ok_q, qb = parse_quota(argv[2])
        if not ok_q:
            print("Invalid quota", file=sys.stderr)
            return 1
        if not store.set_quota(argv[1], qb):
            print(f"User not found: {argv[1]}", file=sys.stderr)
            return 1
        print("OK")
        return 0

    if cmd == "delete" and len(argv) == 2:
        if not store.delete_user(argv[1]):
            print(f"User not found: {argv[1]}", file=sys.stderr)
            return 1
        print("OK")
        return 0

    if cmd == "usage":
        uname = argv[1] if len(argv) >= 2 else None
        print(json.dumps(store.query_usage(uname), indent=2, ensure_ascii=False))
        return 0

    if cmd == "routing":
        if len(argv) == 1:
            print(json.dumps(store.get_routing_masked(), indent=2, ensure_ascii=False))
            return 0
        if len(argv) == 3 and argv[1] == "set":
            try:
                payload = json.loads(Path(argv[2]).read_text(encoding="utf-8"))
                res = store.update_routing(payload)
                print(json.dumps(res, indent=2, ensure_ascii=False))
                return 0
            except Exception as exc:
                print(f"Error: {exc}", file=sys.stderr)
                return 1
        print("Usage: proxy-user routing [set <json_file>]", file=sys.stderr)
        return 1

    print(f"Unknown command: {' '.join(argv)}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(cli_main(sys.argv[1:]))
PYEOF
  chmod 755 "${APP_DIR}/proxy_manager.py"
}

# ==============================================================================
# 写入 proxy-user CLI 工具
# ==============================================================================
write_proxy_user_cli() {
  cat > /usr/local/bin/proxy-user <<'CLIEOF'
#!/usr/bin/env bash
set -euo pipefail

TOKEN_FILE="/etc/proxy-stack/admin.token"
MANAGER="/opt/proxy-stack/proxy_manager.py"

case "${1:-}" in
  token)
    cat "$TOKEN_FILE"
    ;;
  rotate-token)
    NEW_TOKEN="$(openssl rand -hex 32)"
    umask 077
    printf '%s\n' "$NEW_TOKEN" > "${TOKEN_FILE}.tmp"
    mv -f "${TOKEN_FILE}.tmp" "$TOKEN_FILE"
    chmod 600 "$TOKEN_FILE"
    printf '%s\n' "$NEW_TOKEN"
    ;;
  list|links|create|set-quota|delete|usage|render|routing)
    exec python3 "$MANAGER" "$@"
    ;;
  status)
    for svc in caddy proxy-manager sing-box-proxy hysteria-proxy xray-proxy; do
      if [[ -f "/etc/systemd/system/${svc}.service" ]]; then
        printf "%-18s : %s\n" "$svc" "$(systemctl is-active "$svc" 2>/dev/null || true)"
      fi
    done
    ;;
  upgrade)
    shift
    exec bash /usr/local/bin/vps-node-install --upgrade "${1:-all}"
    ;;
  self-update)
    exec bash /usr/local/bin/vps-node-install --self-update
    ;;
  *)
    cat <<'USAGE'
用法: proxy-user <子命令>
  token                         输出当前管理员 API 令牌
  rotate-token                  轮换管理员 API 令牌并立即生效
  status                        查看各组件运行状态
  list                          查看所有用户本期用量与额度
  create <user> [quota]         创建用户 (quota 如 100GiB / unlimited)
  links <user>                  查看指定用户的全部协议链接
  set-quota <user> <quota>      修改用户月配额
  delete <user>                 删除用户
  usage [user]                  查看全站或指定用户本期各协议用量
  routing [set <json_file>]     查看当前多出站与路由规则，或从 JSON 文件应用
  render                        重新渲染配置并重载代理内核
  upgrade [target]              手动更新内核 (all|caddy|sing-box|hy2|xray)
  self-update                   更新部署脚本自身到最新版本
USAGE
    exit 1
    ;;
esac
CLIEOF
  chmod 755 /usr/local/bin/proxy-user
}

# ==============================================================================
# 生成主配置 config.json 与 Caddyfile
# ==============================================================================
generate_configs() {
  # 生成管理员令牌
  if [[ ! -f "${STACK_DIR}/admin.token" ]]; then
    umask 077
    openssl rand -hex 32 > "${STACK_DIR}/admin.token"
    chmod 600 "${STACK_DIR}/admin.token"
  fi

  # 生成或复用 Reality 密钥对（如启用）
  local reality_priv="${REALITY_PRIV:-}" reality_pub="${REALITY_PUB:-}" reality_sid="${REALITY_SID:-}"
  if proto_enabled "vless_reality"; then
    if [[ -z "$reality_priv" || -z "$reality_pub" ]]; then
      local key_out
      key_out="$(/usr/local/bin/xray x25519)"
      reality_priv="$(echo "$key_out" | awk -F': ' '/Private/ {print $2}' | tr -d '\r\n ')"
      reality_pub="$(echo "$key_out" | awk -F': ' '/Public|Password/ {print $2}' | head -n1 | tr -d '\r\n ')"
    fi
    [[ -z "$reality_sid" ]] && reality_sid="$(random_hex 8)"
  fi

  # 生成或复用 SS2022 服务端主密钥与 Hy2 stats secret
  local ss2022_server_psk="${SS2022_SERVER_PSK:-}" hy2_stats_secret="${HY2_STATS_SECRET:-}"
  if proto_enabled "ss2022" && [[ -z "$ss2022_server_psk" ]]; then
    ss2022_server_psk="$(random_b64_16)"
  fi
  if proto_enabled "hy2" && [[ -z "$hy2_stats_secret" ]]; then
    hy2_stats_secret="$(random_hex 24)"
  fi

  # 生成 /etc/proxy-stack/config.json
  python3 - <<PYGEN
import json, os
enabled = [x for x in "${ENABLED_PROTOCOLS_CSV}".split(",") if x]
cfg = {
    "main_domain": "${MAIN_DOMAIN}",
    "acme_email": "${ACME_EMAIL}",
    "timezone": "${TIMEZONE}",
    "reset_day": int("${RESET_DAY}"),
    "web_root": "${WEB_ROOT}",
    "api_port": ${PORT_API_LOCAL},
    "enabled_protocols": enabled,
    "xray": {"stats_port": ${PORT_XRAY_STATS}},
}
if "anytls" in enabled:
    cfg["anytls"] = {
        "domain": "${ANYTLS_DOMAIN}",
        "local_port": ${PORT_ANYTLS_LOCAL},
        "stats_port": ${PORT_SINGBOX_STATS},
    }
if "hy2" in enabled:
    cfg["hy2"] = {
        "domain": "${HY2_DOMAIN}",
        "hop_ports": "${HY2_HOP_RANGE}",
        "local_port": ${PORT_HY2_LOCAL},
        "stats_port": ${PORT_HY2_STATS},
        "stats_secret": "${hy2_stats_secret}",
        "cert_path": "${CERT_DIR}/hy2.crt",
        "key_path": "${CERT_DIR}/hy2.key",
    }
if "vless_xhttp_tls" in enabled:
    cfg["vless_xhttp_tls"] = {
        "domain": "${XHTTP_TLS_DOMAIN}",
        "path": "${XHTTP_TLS_PATH}",
        "local_port": ${PORT_XHTTP_TLS_LOCAL},
    }
if "vless_xhttp" in enabled:
    cfg["vless_xhttp"] = {
        "port": int("${XHTTP_PORT:-0}"),
        "path": "${XHTTP_PATH}",
        "local_port": ${PORT_XHTTP_LOCAL},
    }
if "vless_reality" in enabled:
    cfg["vless_reality"] = {
        "port": int("${REALITY_PORT:-0}"),
        "dest": "${REALITY_DEST}",
        "sni": "${REALITY_SNI}",
        "private_key": "${reality_priv}",
        "public_key": "${reality_pub}",
        "short_id": "${reality_sid}",
    }
if "ss2022" in enabled:
    cfg["ss2022"] = {
        "port": int("${SS2022_PORT:-0}"),
        "method": "2022-blake3-aes-128-gcm",
        "server_psk": "${ss2022_server_psk}",
    }
from pathlib import Path
cfg_path = Path("${STACK_DIR}/config.json")
if cfg_path.exists():
    try:
        old = json.loads(cfg_path.read_text(encoding="utf-8"))
        if isinstance(old.get("outbounds"), list):
            cfg["outbounds"] = old["outbounds"]
        if isinstance(old.get("routing"), dict):
            cfg["routing"] = old["routing"]
    except Exception:
        pass
cfg.setdefault("outbounds", [])
cfg.setdefault("routing", {"default_outbound": "direct", "rules": []})
with open(cfg_path, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
os.chmod(cfg_path, 0o600)
PYGEN

  # 生成 Caddyfile
  {
    cat <<EOF
{
    email ${ACME_EMAIL}
    http_port 80
    https_port ${PORT_CADDY_L7_HTTPS}
    servers {
        protocols h1 h2
    }

    layer4 {
        :443 {
EOF
    if proto_enabled "anytls"; then
      cat <<EOF
            @anytls tls sni ${ANYTLS_DOMAIN}
            route @anytls {
                tls
                subroute {
                    @is_http http
                    route @is_http {
                        proxy 127.0.0.1:${PORT_CADDY_MASQ_HTTP}
                    }
                    route {
                        proxy 127.0.0.1:${PORT_ANYTLS_LOCAL}
                    }
                }
            }
EOF
    fi
    cat <<EOF
            route {
                proxy 127.0.0.1:${PORT_CADDY_L7_HTTPS}
            }
        }
    }
}

# 本地明文伪装站 (供 AnyTLS 非代理 HTTP 探测回落)
http://:${PORT_CADDY_MASQ_HTTP} {
    bind 127.0.0.1
    root * ${WEB_ROOT}
    file_server
}

# 主域名: 管理 API + 静态伪装站
https://${MAIN_DOMAIN}:${PORT_CADDY_L7_HTTPS} {
    bind 127.0.0.1
    handle /api/v1/* {
        reverse_proxy 127.0.0.1:${PORT_API_LOCAL}
    }
    handle {
        root * ${WEB_ROOT}
        try_files {path} /index.html
        file_server
    }
}
EOF

    if proto_enabled "anytls"; then
      cat <<EOF

# AnyTLS 域名证书自动签发与续期占位站点
https://${ANYTLS_DOMAIN}:${PORT_CADDY_L7_HTTPS} {
    bind 127.0.0.1
    root * ${WEB_ROOT}
    file_server
}
EOF
    fi

    if proto_enabled "hy2" && [[ "$HY2_DOMAIN" != "$MAIN_DOMAIN" ]]; then
      cat <<EOF

# Hysteria2 独立域名证书自动签发与续期占位站点
https://${HY2_DOMAIN}:${PORT_CADDY_L7_HTTPS} {
    bind 127.0.0.1
    root * ${WEB_ROOT}
    file_server
}
EOF
    fi

    if proto_enabled "vless_xhttp_tls"; then
      if [[ "$XHTTP_TLS_DOMAIN" == "$MAIN_DOMAIN" ]]; then
        log_warn "VLESS+XHTTP+TLS 复用主域名，将其路径写入主域名站点块..."
      else
        cat <<EOF

# VLESS+XHTTP+TLS 站点: 匹配路径转 Xray (h2c), 其余返回伪装页
https://${XHTTP_TLS_DOMAIN}:${PORT_CADDY_L7_HTTPS} {
    bind 127.0.0.1
    handle ${XHTTP_TLS_PATH}* {
        reverse_proxy 127.0.0.1:${PORT_XHTTP_TLS_LOCAL} {
            transport http {
                versions h2c 2
            }
            flush_interval -1
        }
    }
    handle {
        root * ${WEB_ROOT}
        try_files {path} /index.html
        file_server
    }
}
EOF
      fi
    fi

    if proto_enabled "vless_xhttp"; then
      cat <<EOF

# VLESS+XHTTP (无 TLS) 自定义端口: 匹配路径转 Xray (h2c), 其余返回伪装页
http://:${XHTTP_PORT} {
    handle ${XHTTP_PATH}* {
        reverse_proxy 127.0.0.1:${PORT_XHTTP_LOCAL} {
            transport http {
                versions h2c 2
            }
            flush_interval -1
        }
    }
    handle {
        root * ${WEB_ROOT}
        try_files {path} /index.html
        file_server
    }
}
EOF
    fi
  } > "${STACK_DIR}/Caddyfile"

  # 如果 VLESS+XHTTP+TLS 复用了主域名，把 handle 块注入主域名站点
  if proto_enabled "vless_xhttp_tls" && [[ "$XHTTP_TLS_DOMAIN" == "$MAIN_DOMAIN" ]]; then
    python3 - <<PYPATCH
from pathlib import Path
p = Path("${STACK_DIR}/Caddyfile")
txt = p.read_text(encoding="utf-8")
target = "    handle /api/v1/* {"
inject = """    handle ${XHTTP_TLS_PATH}* {
        reverse_proxy 127.0.0.1:${PORT_XHTTP_TLS_LOCAL} {
            transport http {
                versions h2c 2
            }
            flush_interval -1
        }
    }
    handle /api/v1/* {"""
assert target in txt
p.write_text(txt.replace(target, inject, 1), encoding="utf-8")
PYPATCH
  fi

  # 校验 Caddyfile 语法
  /usr/local/bin/caddy validate --config "${STACK_DIR}/Caddyfile" --adapter caddyfile
  log_ok "Caddyfile 校验通过"
}

# ==============================================================================
# 创建 Systemd 服务并启动
# ==============================================================================
setup_systemd_services() {
  cat > /etc/systemd/system/caddy.service <<EOF
[Unit]
Description=Caddy Reverse Proxy & L4 SNI Router
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
Environment=HOME=/var/lib/caddy
ExecStart=/usr/local/bin/caddy run --environ --config ${STACK_DIR}/Caddyfile --adapter caddyfile
ExecReload=/usr/local/bin/caddy reload --config ${STACK_DIR}/Caddyfile --adapter caddyfile --force
TimeoutStopSec=5s
LimitNOFILE=1048576
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/proxy-manager.service <<EOF
[Unit]
Description=VPS Proxy Traffic Collector & Management API
After=network-online.target caddy.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 ${APP_DIR}/proxy_manager.py serve
Restart=always
RestartSec=3
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

  if proto_enabled "anytls"; then
    cat > /etc/systemd/system/sing-box-proxy.service <<EOF
[Unit]
Description=sing-box AnyTLS Backend
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/sing-box run -c ${STACK_DIR}/sing-box.json
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  elif [[ -f /etc/systemd/system/sing-box-proxy.service ]]; then
    systemctl stop sing-box-proxy 2>/dev/null || true
    systemctl disable sing-box-proxy 2>/dev/null || true
    rm -f /etc/systemd/system/sing-box-proxy.service "${STACK_DIR}/sing-box.json"
  fi

  if proto_enabled "hy2"; then
    cat > /etc/systemd/system/hysteria-proxy.service <<EOF
[Unit]
Description=Hysteria2 Proxy Backend
After=network-online.target caddy.service

[Service]
Type=simple
ExecStart=/usr/local/bin/hysteria server -c ${STACK_DIR}/hysteria.yaml
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  elif [[ -f /etc/systemd/system/hysteria-proxy.service ]]; then
    systemctl stop hysteria-proxy 2>/dev/null || true
    systemctl disable hysteria-proxy 2>/dev/null || true
    rm -f /etc/systemd/system/hysteria-proxy.service "${STACK_DIR}/hysteria.yaml"
  fi

  if need_xray; then
    cat > /etc/systemd/system/xray-proxy.service <<EOF
[Unit]
Description=Xray-core Multi-Protocol Backend
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/xray run -config ${STACK_DIR}/xray.json
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  elif [[ -f /etc/systemd/system/xray-proxy.service ]]; then
    systemctl stop xray-proxy 2>/dev/null || true
    systemctl disable xray-proxy 2>/dev/null || true
    rm -f /etc/systemd/system/xray-proxy.service "${STACK_DIR}/xray.json"
  fi

  systemctl daemon-reload
}

configure_sysctl_tuning() {
  if [[ "${ENABLE_SYSCTL_TUNING:-1}" == "0" ]]; then
    log_info "已跳过 BBR 与 UDP 缓冲区优化 (ENABLE_SYSCTL_TUNING=0)。"
    return 0
  fi
  log_info "配置 BBR 拥塞控制与 UDP 缓冲区优化..."
  modprobe tcp_bbr 2>/dev/null || true
  cat > /etc/sysctl.d/99-proxy-stack.conf <<'EOF'
# Proxy Stack Network Tuning (BBR + UDP Buffers)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.core.netdev_max_backlog = 16384
EOF
  if sysctl -p /etc/sysctl.d/99-proxy-stack.conf >/dev/null 2>&1; then
    local cc
    cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
    log_ok "网络调优已生效 (tcp_congestion_control=${cc}, UDP rmem/wmem_max=16MiB)"
  else
    log_warn "部分 sysctl 参数在当前内核/容器环境不可用，已尽力应用兼容项。"
  fi
}

configure_hy2_port_hopping() {
  local svc_file="/etc/systemd/system/hy2-port-hopping.service"
  local helper="${APP_DIR}/hy2-port-hopping.sh"

  if ! proto_enabled "hy2" || [[ -z "${HY2_HOP_RANGE:-}" ]]; then
    if [[ -f "$svc_file" ]]; then
      systemctl stop hy2-port-hopping 2>/dev/null || true
      systemctl disable hy2-port-hopping 2>/dev/null || true
      rm -f "$svc_file" "$helper"
      systemctl daemon-reload
      log_info "已移除 Hysteria2 端口跳跃规则。"
    fi
    return 0
  fi

  local hop_colon="${HY2_HOP_RANGE//-/:}"
  if ! command -v iptables >/dev/null 2>&1; then
    if [[ "$PKG_MGR" == "apt" ]]; then
      apt-get install -y -qq iptables >/dev/null
    else
      "$PKG_MGR" install -y -q iptables >/dev/null
    fi
  fi

  cat > "$helper" <<EOF
#!/usr/bin/env bash
set -euo pipefail
CHAIN="PROXY_HY2_HOP"
ACTION="\${1:-start}"

apply_for() {
  local bin="\$1"
  command -v "\$bin" >/dev/null 2>&1 || return 0
  "\$bin" -t nat -N "\$CHAIN" 2>/dev/null || true
  "\$bin" -t nat -F "\$CHAIN"
  while "\$bin" -t nat -D PREROUTING -p udp -j "\$CHAIN" 2>/dev/null; do :; done
  if [[ "\$ACTION" == "start" ]]; then
    "\$bin" -t nat -A "\$CHAIN" -p udp --dport ${hop_colon} -j REDIRECT --to-ports 443
    "\$bin" -t nat -I PREROUTING 1 -p udp -j "\$CHAIN"
  else
    "\$bin" -t nat -X "\$CHAIN" 2>/dev/null || true
  fi
}

apply_for iptables
apply_for ip6tables
EOF
  chmod 755 "$helper"

  cat > "$svc_file" <<EOF
[Unit]
Description=Hysteria2 UDP Port Hopping NAT Redirect (${HY2_HOP_RANGE} -> 443)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${helper} start
ExecStop=${helper} stop

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable hy2-port-hopping >/dev/null 2>&1 || true
  systemctl restart hy2-port-hopping
  log_ok "Hysteria2 端口跳跃已生效 (UDP ${HY2_HOP_RANGE} -> 443，已配置开机自启)"
}

configure_firewall() {
  local tcp_ports=(80 443)
  local udp_ports=(443)
  proto_enabled "hy2"           || udp_ports=()
  proto_enabled "vless_xhttp"   && tcp_ports+=("$XHTTP_PORT")
  proto_enabled "vless_reality" && tcp_ports+=("$REALITY_PORT")
  proto_enabled "ss2022"        && { tcp_ports+=("$SS2022_PORT"); udp_ports+=("$SS2022_PORT"); }

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    log_info "配置 UFW 防火墙放行端口..."
    for p in "${tcp_ports[@]}"; do ufw allow "${p}/tcp" >/dev/null || true; done
    for p in "${udp_ports[@]}"; do ufw allow "${p}/udp" >/dev/null || true; done
    if proto_enabled "hy2" && [[ -n "${HY2_HOP_RANGE:-}" ]]; then
      ufw allow "${HY2_HOP_RANGE//-/:}/udp" >/dev/null || true
    fi
  elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    log_info "配置 firewalld 放行端口..."
    for p in "${tcp_ports[@]}"; do firewall-cmd --permanent --add-port="${p}/tcp" >/dev/null || true; done
    for p in "${udp_ports[@]}"; do firewall-cmd --permanent --add-port="${p}/udp" >/dev/null || true; done
    if proto_enabled "hy2" && [[ -n "${HY2_HOP_RANGE:-}" ]]; then
      firewall-cmd --permanent --add-port="${HY2_HOP_RANGE}/udp" >/dev/null || true
    fi
    firewall-cmd --reload >/dev/null || true
  fi
}

wait_and_sync_hy2_cert() {
  if ! proto_enabled "hy2"; then
    return 0
  fi
  log_info "等待 Caddy 为 ${HY2_DOMAIN} 签发 TLS 证书 (最多等待 60 秒)..."
  local found=0
  for _ in $(seq 1 30); do
    local crt
    crt="$(find /var/lib/caddy/.local/share/caddy/certificates -path "*/${HY2_DOMAIN}/${HY2_DOMAIN}.crt" 2>/dev/null | head -n1 || true)"
    if [[ -n "$crt" && -f "${crt%.crt}.key" ]]; then
      cp -f "$crt" "${CERT_DIR}/hy2.crt"
      cp -f "${crt%.crt}.key" "${CERT_DIR}/hy2.key"
      chmod 600 "${CERT_DIR}/hy2.key"
      found=1
      break
    fi
    sleep 2
  done
  if [[ "$found" -eq 0 ]]; then
    log_warn "暂未获取到正式 ACME 证书（请确认域名 DNS 已解析且 80 端口可达），临时生成自签证书启动 Hysteria2，Caddy 签发成功后将自动同步。"
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
      -keyout "${CERT_DIR}/hy2.key" -out "${CERT_DIR}/hy2.crt" -days 30 \
      -subj "/CN=${HY2_DOMAIN}" 2>/dev/null
    chmod 600 "${CERT_DIR}/hy2.key"
  else
    log_ok "已同步 ${HY2_DOMAIN} 的 ACME 正式证书至 Hysteria2"
  fi
}

start_all_services() {
  # 初始化默认用户 owner（已存在则保留）并重新渲染各内核配置
  log_info "同步用户并渲染代理内核配置..."
  OWNER_JSON="$(python3 "${APP_DIR}/proxy_manager.py" init-owner)"

  # 启动或重启 Caddy（确保签发新子域名证书并释放未使用的 L4 端口）
  if systemctl is-active --quiet caddy; then
    systemctl restart caddy
  else
    systemctl enable --now caddy
  fi
  wait_and_sync_hy2_cert

  if proto_enabled "anytls"; then
    systemctl enable sing-box-proxy >/dev/null 2>&1 || true
    systemctl restart sing-box-proxy
  fi
  if proto_enabled "hy2"; then
    systemctl enable hysteria-proxy >/dev/null 2>&1 || true
    systemctl restart hysteria-proxy
  fi
  if need_xray; then
    systemctl enable xray-proxy >/dev/null 2>&1 || true
    systemctl restart xray-proxy
  fi
  systemctl enable proxy-manager >/dev/null 2>&1 || true
  systemctl restart proxy-manager
}

print_summary() {
  local token
  token="$(cat "${STACK_DIR}/admin.token")"
  echo ""
  echo -e "${GREEN}============================================================${NC}"
  echo -e "${GREEN}  部署完成！服务状态与连接信息如下：${NC}"
  echo -e "${GREEN}============================================================${NC}"
  /usr/local/bin/proxy-user status
  echo ""
  echo -e "${CYAN}管理 API 地址 :${NC} https://${MAIN_DOMAIN}/api/v1"
  echo -e "${CYAN}管理员令牌    :${NC} ${token}"
  echo -e "${CYAN}获取/轮换令牌 :${NC} proxy-user token / proxy-user rotate-token"
  echo ""
  echo -e "${CYAN}默认用户 (owner) 节点链接：${NC}"
  echo "$OWNER_JSON" | jq -r '.links | to_entries[] | "  [\(.key)] \(.value)"'
  echo ""
  echo -e "${YELLOW}提示：${NC}可使用 curl 验证 API："
  echo "  curl -fsS -H \"Authorization: Bearer \$(proxy-user token)\" \"https://${MAIN_DOMAIN}/api/v1/users\""
  echo ""
}

install_self_script() {
  local self_src="${BASH_SOURCE[0]:-$0}"
  if [[ -f "$self_src" ]]; then
    local real_src real_dst
    real_src="$(readlink -f "$self_src" 2>/dev/null || echo "$self_src")"
    real_dst="$(readlink -f "$INSTALLED_SCRIPT" 2>/dev/null || echo "$INSTALLED_SCRIPT")"
    if [[ "$real_src" != "$real_dst" ]]; then
      install -m 755 "$real_src" "$INSTALLED_SCRIPT"
    fi
  fi
}

do_self_update() {
  require_root
  local tmp_new="/var/tmp/vps-node-install.new"
  local api_url="https://api.github.com/repos/${DEFAULT_REPO}/contents/scripts/vps-node-install.sh?ref=main"
  log_info "检查并下载最新脚本 (${DEFAULT_REPO})..."
  local fetched=0
  if [[ "$SCRIPT_URL" == "https://raw.githubusercontent.com/${DEFAULT_REPO}/"* ]]; then
    if [[ -n "${GH_TOKEN:-}" ]]; then
      curl -fsSL -H "Authorization: Bearer ${GH_TOKEN}" -H "Accept: application/vnd.github.raw+json" "$api_url" -o "$tmp_new" 2>/dev/null && fetched=1 || true
    else
      curl -fsSL -H "Accept: application/vnd.github.raw+json" "$api_url" -o "$tmp_new" 2>/dev/null && fetched=1 || true
    fi
  fi
  if [[ "$fetched" -eq 0 ]]; then
    fetch_with_auth "$SCRIPT_URL" "$tmp_new"
  fi
  sed -i 's/\r$//' "$tmp_new"
  if ! bash -n "$tmp_new"; then
    rm -f "$tmp_new"
    log_err "下载的脚本语法校验失败，已放弃更新！"
    exit 1
  fi
  local new_ver
  new_ver="$(grep -m1 '^SCRIPT_VERSION=' "$tmp_new" | cut -d'"' -f2 || echo "unknown")"
  install -m 755 "$tmp_new" "$INSTALLED_SCRIPT"
  local self_src="${BASH_SOURCE[0]:-$0}"
  if [[ -f "$self_src" && "$self_src" != "$INSTALLED_SCRIPT" && "$self_src" != /dev/fd/* ]]; then
    install -m 755 "$tmp_new" "$self_src"
  fi
  rm -f "$tmp_new"
  log_ok "脚本已更新: v${SCRIPT_VERSION} -> v${new_ver} (${INSTALLED_SCRIPT})"
  exit 0
}

do_upgrade() {
  require_root
  detect_system
  local target="${UPGRADE_TARGET:-all}"
  if [[ -f "${STACK_DIR}/config.json" ]]; then
    load_existing_config
    ENABLED_PROTOCOLS_CSV="$EXISTING_PROTOCOLS_CSV"
  else
    ENABLED_PROTOCOLS_CSV="anytls,hy2,vless_xhttp_tls,vless_xhttp,vless_reality,ss2022"
  fi

  case "$target" in
    all)
      install_caddy
      systemctl is-active --quiet caddy && systemctl restart caddy || true
      if proto_enabled "anytls"; then
        install_singbox
        systemctl is-active --quiet sing-box-proxy && systemctl restart sing-box-proxy || true
      fi
      if proto_enabled "hy2"; then
        install_hysteria
        systemctl is-active --quiet hysteria-proxy && systemctl restart hysteria-proxy || true
      fi
      if need_xray; then
        install_xray
        systemctl is-active --quiet xray-proxy && systemctl restart xray-proxy || true
      fi
      ;;
    caddy)
      install_caddy
      systemctl is-active --quiet caddy && systemctl restart caddy || true
      ;;
    sing-box|singbox)
      install_singbox
      systemctl is-active --quiet sing-box-proxy && systemctl restart sing-box-proxy || true
      ;;
    hy2|hysteria|hysteria2)
      install_hysteria
      systemctl is-active --quiet hysteria-proxy && systemctl restart hysteria-proxy || true
      ;;
    xray)
      install_xray
      systemctl is-active --quiet xray-proxy && systemctl restart xray-proxy || true
      ;;
    *)
      log_err "未知更新目标: ${target} (可选: all, caddy, sing-box, hy2, xray)"
      exit 1
      ;;
  esac
  log_ok "内核更新完成 (${target})！"
  exit 0
}

# ==============================================================================
# 主流程
# ==============================================================================
main() {
  [[ "$DO_SELF_UPDATE" -eq 1 ]] && do_self_update
  [[ "$DO_UPGRADE" -eq 1 ]] && do_upgrade

  require_root
  detect_system
  install_base_deps
  collect_config
  install_binaries
  create_directories_and_assets
  write_proxy_manager
  write_proxy_user_cli
  install_self_script
  generate_configs
  setup_systemd_services
  configure_sysctl_tuning
  configure_hy2_port_hopping
  configure_firewall
  start_all_services
  print_summary
}

main "$@"
