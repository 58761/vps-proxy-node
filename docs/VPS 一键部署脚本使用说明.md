# VPS 多协议代理节点一键部署脚本使用说明

脚本路径：`scripts/vps-node-install.sh`（单文件自包含，支持 Debian / Ubuntu / CentOS / Rocky / AlmaLinux，`amd64` 与 `arm64` 架构）。

## 核心功能

1. **6 种协议按需部署**（可任选组合，未选协议不安装多余内核）：
   - `anytls`：443/TCP，由 Caddy (`caddy-l4`) 按 SNI 转发至 `sing-box`，非代理 HTTP 探测自动回落静态伪装页。
   - `hy2`：443/UDP 直连 `Hysteria2`（支持 `HY2_HOP_RANGE` 端口跳跃 NAT 重定向），握手/鉴权失败由内置 `masquerade` 返回静态伪装页。
   - `vless+xhttp+tls`：443/TCP，由 Caddy 按 SNI 与路径（`h2c`）转发至 `Xray-core`，非匹配路径返回静态伪装页。
   - `vless+xhttp`：自定义或随机 TCP 端口（无 TLS），由 Caddy 按路径（`h2c`）转发至 `Xray-core`，其余路径返回静态伪装页。
   - `vless+reality`：自定义或随机 TCP 端口，由 `Xray-core` 承载，默认回落至本机 Caddy HTTPS 伪装站（也可自定义外部回落目标）。
   - `ss2022`：自定义或随机 TCP+UDP 端口（`2022-blake3-aes-128-gcm` 多用户），由 `Xray-core` 承载。
2. **自动证书签发与续期**：基于 Caddy HTTP-01 自动签发与续期所有启用域名的 TLS 证书，并自动同步续期后的证书至 Hysteria2。
3. **分协议分用户流量监控与管理 API**：每 10 秒增量采样并写入 SQLite (WAL)，超额自动标记 `quota_exceeded` 停用并在新周期自动恢复；完整兼容 [节点流量与用户管理 API.md](file:///g:/Documents/Antigravity/vps订阅管理/docs/节点流量与用户管理%20API.md)。
4. **网络栈调优**：自动写入 `/etc/sysctl.d/99-proxy-stack.conf` 开启 `fq` + `BBR` 拥塞控制，并将 UDP 收发缓冲区提升至 16MiB（可通过 `ENABLE_SYSCTL_TUNING=0` 跳过）。

## 部署前置条件

1. Linux VPS（systemd 环境，root 权限）。
2. 将主域名及所选子域名的 `A` / `AAAA` 记录提前解析到该 VPS IP：
   - 主域名（如 `de.example.com`）：承载静态伪装站、管理 API (`/api/v1`) 及默认 Hysteria2 SNI。
   - 若启用 `anytls`：需独立子域名（默认 `ats.<主域名>`）。
   - 若启用 `vless+xhttp+tls`：推荐使用独立子域名（默认 `xhttp.<主域名>`，也支持复用主域名）。
3. 防火墙/安全组放行 TCP `80`、TCP `443`（以及启用 `hy2` 时的 UDP `443`，与所选自定义端口）。

## 一键执行

### 1. 通过 URL 一键安装（推荐，自动拉取预编译内核）

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/58761/vps-proxy-node/main/scripts/vps-node-install.sh)
```

> 首次安装会优先从 `58761/vps-proxy-node` 的 Release 下载预编译 `caddy-l4` 与 `sing-box`（`amd64`/`arm64`），仅在预编译包不可用时才回退本机自适应编译。

按提示勾选要部署的协议、输入主域名及可选参数即可完成全自动安装与初始化。安装结束后会输出：
- 管理 API 地址（`https://<主域名>/api/v1`）
- 管理员令牌
- 默认不限量用户 `owner` 的所有已启用协议节点链接

### 2. 非交互式（无人值守）部署

通过环境变量指定参数并加上 `--non-interactive`：

```bash
sudo MAIN_DOMAIN="de.example.com" \
  ACME_EMAIL="admin@example.com" \
  SELECTED_PROTOCOLS="anytls,hy2,vless_xhttp_tls,vless_xhttp,vless_reality,ss2022" \
  ANYTLS_DOMAIN="ats.de.example.com" \
  XHTTP_TLS_DOMAIN="xhttp.de.example.com" \
  HY2_HOP_RANGE="20000-50000" \
  bash vps-node-install.sh --non-interactive
```

### 3. 增量添加 / 移除协议（保留现有配置与全部用户）

当 `/etc/proxy-stack/config.json` 已存在时，再次执行脚本会自动进入**增量模式**，保留已有协议的域名、端口、路径、密钥与全部现有用户（现有用户自动获得新协议链接，无需重建）：

```bash
# 交互式增量管理菜单（添加/移除协议、重新渲染、覆盖重装）
sudo bash vps-node-install.sh

# 命令行直接增量添加协议
sudo bash vps-node-install.sh --add vless_reality,ss2022

# 非交互式增量添加协议（可同时通过环境变量指定新协议域名/端口）
sudo REALITY_PORT=28443 bash vps-node-install.sh --non-interactive --add vless_reality

# 移除指定协议（自动停用不再需要的内核服务，保留剩余协议与历史统计）
sudo bash vps-node-install.sh --non-interactive --remove hy2
```

## 日常运维命令（`proxy-user`）

```bash
# 获取管理员 API 令牌
proxy-user token

# 轮换管理员令牌（立即生效，无需重启代理内核）
proxy-user rotate-token

# 查看各组件运行状态
proxy-user status

# 列出所有用户本期用量、额度与状态
proxy-user list

# 创建用户（可选配额：B / KiB / MiB / GiB / TiB 或 unlimited）
proxy-user create alice 100GiB

# 查看用户全部节点链接
proxy-user links alice

# 修改用户月配额
proxy-user set-quota alice 200GiB

# 查看全站或指定用户分协议流量
proxy-user usage
proxy-user usage alice

# 查看或通过 JSON 文件更新多出站与路由规则
proxy-user routing
proxy-user routing set /tmp/routing.json

# 删除用户
proxy-user delete alice

# 手动更新内核（默认全部，也可指定 caddy / sing-box / hy2 / xray）
proxy-user upgrade
proxy-user upgrade xray

# 更新部署脚本自身到最新版本
proxy-user self-update
```

## 对接当前“VPS 订阅管理”系统

1. 在 VPS 上获取令牌：`proxy-user token`。
2. 在订阅管理面板进入 **API 来源** 页面，添加来源：
   - **API 基础地址**：`https://<主域名>/api/v1`
   - **管理员令牌**：粘贴上一步获取的令牌
3. 点击同步，系统将自动同步 `owner` 及后续所有用户的全协议节点链接与分协议流量统计。

## 卸载清理

```bash
sudo bash vps-node-install.sh --uninstall
```
