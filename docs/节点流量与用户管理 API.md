# 节点流量与用户管理 API

基础地址为 `https://de.heymypolaris.top/api/v1`，使用 HTTPS HTTP/1.1 或 HTTP/2。所有接口均需请求头 `Authorization: Bearer <管理员令牌>`。返回 JSON。

管理员令牌可以创建用户、读取所有用户的节点密码和查询流量。在 VPS 上执行 `proxy-user token` 可领取令牌，执行 `proxy-user rotate-token` 可轮换令牌。轮换后需要同步更新使用该令牌的客户端。

## 接口一览

| 方法 | 路径 | 用途 |
|---|---|---|
| POST | `/users` | 创建用户并返回 AnyTLS、Hy2 链接 |
| GET | `/users/{username}/links` | 获取指定用户现有的两条链接 |
| GET | `/users` | 查询所有用户的本期用量、额度和状态 |
| GET | `/usage` | 查询全站及各协议用量 |
| GET | `/users/{username}/usage` | 查询指定用户及各协议用量 |
| GET | `/routing` | 获取当前多出站（脱敏）与路由规则 |
| PUT | `/routing` | 原子校验、更新并热加载多出站与路由规则 |

## 创建用户 · POST /users

请求类型为 `application/json`，请求体仅接受以下字段。

| 字段 | 必填 | 说明 |
|---|---|---|
| `username` | 是 | 1–48 个字符，可用小写英文字母、数字、下划线和连字符 |
| `quota` | 否 | 两个协议共用的月额度。省略或填 `"unlimited"` 表示不限量，也可填 `"100GiB"`。支持非负整数加 `B`、`KiB`、`MiB`、`GiB`、`TiB`，区分大小写 |

以下 Bash 命令可在 VPS 上运行，后续示例沿用这两个变量。

```bash
API='https://de.heymypolaris.top/api/v1'
TOKEN="$(proxy-user token)"

curl -fsS "$API/users" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  --data '{"username":"alice","quota":"100GiB"}'
```

成功返回 **201 Created**。示例中的密码为占位符。

```json
{
  "user": "alice",
  "quota_bytes": 107374182400,
  "links": {
    "anytls": "anytls://<密码>@ats.de.heymypolaris.top:443?sni=ats.de.heymypolaris.top#alice-AnyTLS",
    "hy2": "hysteria2://<密码>@de.heymypolaris.top:443/?sni=de.heymypolaris.top#alice-Hy2"
  }
}
```

不限量用户的 `quota_bytes` 为 `null`。同名用户返回 409。若创建请求超时，先查询该用户的链接以确认创建结果。应用新用户配置时，其他在线代理连接可能短暂重连。

## 获取链接 · GET /users/{username}/links

```bash
curl -fsS -H "Authorization: Bearer $TOKEN" "$API/users/alice/links"
```

成功返回 **200 OK**，响应结构与创建用户相同。重复读取返回相同的凭据。原有两条节点链接归入用户 `owner`。

## 用户额度与流量查询

```bash
# 所有用户当前周期的额度和状态
curl -fsS -H "Authorization: Bearer $TOKEN" "$API/users"

# 全站当前周期用量
curl -fsS -H "Authorization: Bearer $TOKEN" "$API/usage"

# alice 自统计上线以来的累计用量
curl -fsS -H "Authorization: Bearer $TOKEN" "$API/users/alice/usage?period=all"

# 指定日期范围，包含首尾两日
curl -fsS -H "Authorization: Bearer $TOKEN" \
  "$API/users/alice/usage?from=2026-11-01&to=2026-11-22"
```

两个 `usage` 接口默认查询当前配额周期。可传 `period=all`，或同时传入 `from` 和 `to`，两种方式互斥。日期采用配置时区，默认为 `Asia/Shanghai`。`GET /users` 无查询参数。

流量接口响应示例：

```json
{
  "last_sample": 1795256090,
  "cycle_start": 1793462400,
  "next_reset": 1796054400,
  "timezone": "Asia/Shanghai",
  "protocols": {
    "anytls": {"up_bytes": 1000, "down_bytes": 9000, "total_bytes": 10000},
    "hy2": {"up_bytes": 2000, "down_bytes": 8000, "total_bytes": 10000}
  },
  "up_bytes": 3000,
  "down_bytes": 17000,
  "total_bytes": 20000
}
```

上传、下载和总量以字节计。顶层字段已汇总两个协议。`last_sample` 为最近一次成功采样时间，通常每 10 秒更新。`cycle_start` 和 `next_reset` 始终描述当前配额周期。时间戳均为 Unix 秒。

`GET /users` 返回相同的时间与时区字段，以及 `users` 数组。每个元素包含 `user`、`used_bytes`、`quota_bytes`、`remaining_bytes` 和 `status`。不限量时额度与剩余额度均为 `null`。状态为 `active` 或 `quota_exceeded`。

## 多出站与按用户/规则路由 · GET / PUT /routing

支持配置多个命名出站（`socks5://`、`http://`、`https://`、`vless://`、`anytls://`、`hysteria2://`、`ss://`）及有序路由规则，并自动确保所有出站服务器自身走 `direct` 防止回环。

### 查询路由 · GET /routing

```bash
curl -fsS -H "Authorization: Bearer $TOKEN" "$API/routing"
```

成功返回 **200 OK**（`uri` 中的用户名/密码/UUID 已脱敏为 `***`）：

```json
{
  "default_outbound": "direct",
  "outbounds": [
    {
      "tag": "us-socks",
      "uri": "socks5://***@1.2.3.4:1080#US",
      "protocol": "socks5",
      "server": "1.2.3.4",
      "port": 1080
    }
  ],
  "rules": [
    {
      "users": ["alice"],
      "domain_suffix": ["openai.com"],
      "geosite": ["google"],
      "outbound": "us-socks"
    }
  ]
}
```

### 更新路由 · PUT /routing

```bash
curl -fsS -X PUT "$API/routing" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  --data '{
    "default_outbound": "direct",
    "outbounds": [
      {"tag": "us-socks", "uri": "socks5://user:pass@1.2.3.4:1080#US"}
    ],
    "rules": [
      {
        "users": ["alice", "bob"],
        "domains": ["ifconfig.me"],
        "domain_suffix": ["openai.com"],
        "geosite": ["google"],
        "ip_cidr": ["1.1.1.0/24"],
        "geoip": ["us"],
        "outbound": "us-socks"
      }
    ]
  }'
```

- **保留已有凭据**：更新 `outbounds` 时若某项 `uri` 留空或保持脱敏掩码（如 `socks5://***@1.2.3.4:1080#US`），将自动沿用已保存的同 `tag` 出站原始 `uri`。
- **原子校验与回滚**：服务端先校验参数及内核配置（`sing-box check` / `xray -test`），失败自动回滚并返回 `400` 或 `503`；成功则返回更新后的脱敏配置（`200 OK`）。

## 错误码

| HTTP 状态码 | 含义 |
|---|---|
| 400 | JSON、用户名、额度或流量查询参数无效 |
| 401 | 管理员令牌缺失或无效 |
| 404 | 用户或接口不存在；给 GET /users 添加查询参数也会返回此状态 |
| 409 | 创建时用户名已存在 |
| 413 | 创建请求体超过 4096 字节 |
| 415 | 创建请求未使用 application/json |
| 503 | 创建用户时后端暂不可用 |
