# Sator MarketMind

MarketMind v0.1 是给 FMCG 批发商/分销商内部业务员使用的 WhatsApp 查询系统。

第一版固定闭环：

1. 管理员登录后台；
2. 配置 Sator Gateway 与 YCloud；
3. 绑定主管/业务员的普通 WhatsApp 号码；
4. 上传五表 Excel，预览并确认列映射；
5. 已授权号码通过 WhatsApp 查询；
6. 系统按角色过滤客户，从 SQLite 与固定规则生成回复；
7. 后台只读审计入站、出站、意图、客户与发送状态。

## 本地运行

```bash
npm ci
npm run build
npm start
```

默认地址为 `http://127.0.0.1:4600`。首次密码可通过
`INITIAL_ADMIN_PASSWORD` 只写入一次，或在首次打开后台时设置。

开发时可分别运行：

```bash
npm run dev
npm run dev:admin
```

后台开发服务器会把 `/api` 代理到默认后端端口 `127.0.0.1:4600`。

## 验证

```bash
npm test
npm run build
docker build -t marketmind:test .
```

`npm test` 会先编译最新 TypeScript，再执行 `dist` 测试，避免旧构建产生假通过。

## OVH 同机隔离

- 现有客服：`/opt/wa-cs`、`wacs_*`
- MarketMind：`/opt/marketmind`、`marketmind_*`
- 独立数据库与 volume：`marketmind.db`、`marketmind_data`
- MarketMind 不绑定 80/443，也不启动第二个 Caddy
- 安装脚本只把 `marketmind_app` 接入现有 Caddy 网络
- 修改 `/opt/wa-cs/Caddyfile` 前必做备份；验证失败立即恢复
- 安装和升级命令从不执行 `docker compose down`，也不更新 `wacs_app`
- 若旧 wa-cs 设置了 `admin off`，首次接入只能在明确设置
  `ALLOW_CADDY_RESTART=1` 时受控重启一次 `wacs_caddy`；不会重启应用或数据库

目标地址：`https://marketmind.139-99-89-252.sslip.io`

任何真实 API Key 都只能放在 OVH 的 `/opt/marketmind/.env` 或后台加密设置中，
不得提交到 Git。
