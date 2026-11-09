# n8n on rootless Podman（Quadlet + systemd）

以 **rootless Podman Quadlet unit** 部署 [n8n](https://n8n.io/)，搭配 PostgreSQL 與外部
task runner，由使用者的 systemd 管理。unit 就是部署本身：開機自動啟動（需要 linger）、容器
當掉時自動重啟，所有版本都釘選在這個 repo 裡。

[English version](README.md)

## 架構

```
              systemctl --user start|stop|restart n8n.target
                                  │
   ┌──────────────────────────────┼───────────────────────────────┐
   │                              │                               │
n8n-postgres.service         n8n.service  ──Wants──▶    n8n-runners.service
postgres:16.15-alpine        n8nio/n8n:2.43.6        n8nio/runners:2.43.6
   │  volume                    │  volume                │
   │  n8n_postgres_data         │  n8n_n8n_data          └── JS 與 Python Code 節點
   └──────────────────── network n8n-network ──────────────────────┘
                                  │
                     PublishPort HOST_BIND:HOST_PORT -> 5678
                     （預設 127.0.0.1:15678，對外由 Cloudflare
                       Tunnel 或 NPM 負責）
```

| 檔案 | unit | 內容 |
|---|---|---|
| `quadlet/n8n.network` | `n8n-network.service` | bridge 網路 `n8n-network` |
| `quadlet/n8n-data.volume` | `n8n-data-volume.service` | volume `n8n_n8n_data`：**憑證加密金鑰** |
| `quadlet/n8n-postgres-data.volume` | `n8n-postgres-data-volume.service` | volume `n8n_postgres_data`：PGDATA |
| `quadlet/n8n-postgres.container` | `n8n-postgres.service` | PostgreSQL 16 |
| `quadlet/n8n.container` | `n8n.service` | n8n（編輯器、REST API、webhook、task broker） |
| `quadlet/optional/n8n-runners.container` | `n8n-runners.service` | 外部 task runner（預設安裝，`--no-runners` 可略過） |
| `quadlet/queue/n8n-valkey.container` 與 `n8n-valkey-data.volume` | `n8n-valkey.service` | 選用的密碼保護 queue broker 與持久化資料卷 |
| `quadlet/queue/n8n-worker.container` 與 `n8n-worker-runners.container` | worker 服務 | 選用的 queue worker 與對應 Code 節點 runner |
| `quadlet/queue/n8n-webhook.container` | `n8n-webhook.service` | 選用的正式 webhook processor |
| `config/n8n-task-runners.json` | 掛載至 runner | 與 HA add-on 相同的 JavaScript／Python 模組匯入權限 |
| `systemd/n8n.target` | `n8n.target` | 一次操作整個堆疊 |

安裝位置：`~/.config/containers/systemd/`（Quadlet）、`~/.config/systemd/user/`（target）、
`~/.config/n8n/n8n.env`（設定，權限 0600）。密碼一律使用 podman secret，不放在 env 檔。

## 系統需求

- Ubuntu 24.04 或同級系統，**podman >= 4.9.3** rootless，systemd 255 使用者 unit
- 服務帳號啟用 linger（`sudo loginctl enable-linger $USER`），登出後服務才會繼續執行
- 映像檔約需 1.5 GB 磁碟空間（n8n、runners、postgres）

```bash
podman --version && systemctl --user show-environment >/dev/null && echo "user manager ok"
```

## 安裝

```bash
git clone https://github.com/WOOWTECH/Woow_podman_n8n ~/woow-quadlet/Woow_podman_n8n
cd ~/woow-quadlet/Woow_podman_n8n
tests/dryrun.sh                 # 選用：用本機產生器驗證所有 unit
scripts/install.sh              # 第一次執行：建立 ~/.config/n8n/n8n.env 後停下
$EDITOR ~/.config/n8n/n8n.env   # 設定 HOST_BIND/HOST_PORT、時區、公開網址
scripts/install.sh              # 安裝、啟動並執行 smoke 測試
```

若前面有 Cloudflare Tunnel 或 Nginx Proxy Manager，請指定公開網址；n8n 會用它組出 webhook
網址與 OAuth callback：

```bash
scripts/install.sh --public-url https://n8n.example.com/
```

第一個打開編輯器的人就會成為管理者。**請先加上驗證（Cloudflare Access、NPM），或立刻建立
管理者帳號。**

其他選項：`--no-runners`（改用內建 runner）、`--db-password-file F`（僅第一次安裝）、
`--no-start`、`--no-smoke`、`--smoke-timeout S`、`--dry-run`（只驗證不改動）。

## 設定

`~/.config/n8n/n8n.env`，權限 0600，只能寫 `KEY=value`：不要加引號，也不要在值後面接
`# 註解`。`HOST_*` 會在安裝時寫進 unit 檔（決策 D2），其餘的鍵會傳給 n8n 容器，因此任何
[n8n 環境變數](https://docs.n8n.io/hosting/configuration/environment-variables/)都能在這裡設定。
改完之後重新執行 `scripts/install.sh`，它只會重啟有變動的部分。

| 鍵 | 預設 | 說明 |
|---|---|---|
| `HOST_BIND` | `127.0.0.1` | 發布位址，`0.0.0.0` 代表對所有網卡開放 |
| `HOST_PORT` | `15678` | 對外埠號（容器內 n8n 固定聽 5678） |
| `WEBHOOK_PORT` | `15679` | 啟用 webhook processor 時使用的另一個埠號 |
| `N8N_HOST`、`N8N_PROTOCOL` | `localhost`、`http` | n8n 認為自己被存取的主機與協定 |
| `N8N_EDITOR_BASE_URL`、`N8N_WEBHOOK_URL` | 未設定 | 公開網址（`--public-url` 會寫入） |
| `N8N_PROXY_HOPS` | 未設定 | 前方的 proxy 層數（Tunnel 或 NPM 為 1） |
| `GENERIC_TIMEZONE`、`TZ` | `Asia/Taipei` | 排程與日誌時區 |
| `N8N_RUNNERS_MODE` | `external` | `external` 會安裝 sidecar，`internal` 則在 n8n 內執行程式碼 |
| `EXECUTIONS_MODE` | `regular` | `queue` 會安裝 Valkey、一個 worker 與其 task runner；必須使用 external runner |
| `WORKER_CONCURRENCY` | `5` | worker 同時執行的 queue 工作數（1–100） |
| `N8N_QUEUE_WEBHOOK_PROCESSOR` | `false` | 在 queue 模式另啟正式 webhook processor |
| `N8N_QUEUE_DISABLE_MAIN_WEBHOOKS` | `false` | 反向代理路由驗證後，才關閉主程序接收正式 webhook |

請勿設定 `N8N_PORT`（那是容器內的埠號）或 `DB_POSTGRESDB_*`，這些由 unit 決定；
`install.sh` 會對被忽略的鍵提出警告。

**Secret**（podman secret，第一次安裝時建立，永不列印）：

| Secret | 用途 |
|---|---|
| `n8n-db-password` | PostgreSQL 使用 `POSTGRES_PASSWORD`；n8n 透過檔案掛載讀取 |
| `n8n-runners-auth-token` | n8n 透過檔案讀取，runner launcher 透過 secret 環境變數讀取；internal 模式仍需建立 |
| `n8n-valkey-password` | 選用 queue 模式時建立，由 n8n 與 Valkey 以掛載檔案讀取 |

**Task runner**：外部 runner 會把 Code 節點的 JavaScript 與 Python 放到獨立容器執行，這也是
上游的建議做法；internal 模式下，能編輯工作流程的人就能讀到加密金鑰與所有憑證。
`n8nio/n8n` 與 `n8nio/runners` 版本必須一致，`tests/dryrun.sh` 與 `scripts/upgrade.sh` 會強制檢查。
runner 會先啟動、後停止，讓 n8n 關閉前完成執行中的流程。runner 設定與 HA add-on
允許相同的 JavaScript／Python 模組匯入。實測兩種 Code node 都無法從環境變數讀到資料庫密碼
或 broker token。

範例設定的 `N8N_BLOCK_ENV_ACCESS_IN_NODE=false` 與 HA add-on 一致，讓既有流程的 `$env`
運算式繼續讀取非機密設定。工作流程編輯者也能讀到你另外放入 `n8n.env` 的環境變數；
供應商憑證應放在 n8n Credentials。

## 選用 queue 模式

在 `~/.config/n8n/n8n.env` 設定 `EXECUTIONS_MODE=queue`，依序執行
`scripts/install.sh --dry-run` 和 `scripts/install.sh`。既有安裝切換拓樸時，安裝程式會先做
**冷備份**，再停止應用程序並啟動新堆疊。資料庫仍使用 PostgreSQL；私有 Valkey 以 AOF 保存
queue 資料。各 n8n 程序在共用資料卷使用不同的事件日誌檔。一個 worker 預設併行數為 5，搭配
獨立的 JavaScript／Python runner。queue 使用 database binary storage，符合
[n8n queue 模式要求](https://docs.n8n.io/deploy/host-n8n/configure-n8n/scaling/enable-queue-mode/)。

要另外啟用 webhook processor，設定 `N8N_QUEUE_WEBHOOK_PROCESSOR=true`，並選一個未占用的
`WEBHOOK_PORT`。反向代理的 `/webhook/*` 與 `/webhook-waiting/*` 應指向
`HOST_BIND:WEBHOOK_PORT`；`/webhook-test/*`、編輯器與 API 繼續指向 `HOST_BIND:HOST_PORT`。
先從公開網址實測正式 webhook，確認路由正確後，再設定
`N8N_QUEUE_DISABLE_MAIN_WEBHOOKS=true` 並重跑 `scripts/install.sh`；這個 n8n 設定只會加到
主程序。`--public-url` 只設定 n8n 對外網址，不會修改反向代理路由。詳見
[n8n webhook processor 路由說明](https://docs.n8n.io/deploy/host-n8n/configure-n8n/scaling/enable-queue-mode/)。

切換後執行 `tests/smoke.sh`。`tests/queue-integration.py` 會用隔離的 PostgreSQL、Valkey、
兩組 runner 與真實 Code 節點 webhook 驗證 queue；需要先下載四個釘選映像檔，測試結束會
移除測試資源。若要切回 regular，將 `N8N_QUEUE_DISABLE_MAIN_WEBHOOKS=false`、
`N8N_QUEUE_WEBHOOK_PROCESSOR=false`、`EXECUTIONS_MODE=regular` 寫入 env 後執行
`scripts/install.sh`。舊 Valkey 資料卷與 secret 會保留到明確執行 purge，供後續還原。

## 日常操作

```bash
systemctl --user status n8n.service              # 單一 unit
systemctl --user restart n8n.target              # 整個堆疊
journalctl --user -u n8n.service -f              # 日誌（LogDriver=journald）
podman exec n8n n8n --version
tests/smoke.sh                                   # 健康檢查，不會改動任何東西
tests/smoke.sh --public-url https://n8n.example.com/
```

若執行過 `podman system reset`，systemd 的網路與資料卷單元可能仍顯示 active，實際 Podman
資源卻已消失。重新執行 `scripts/install.sh` 會在啟動容器前重建缺少的 n8n 資源。重建後的
資料卷是空的；需要舊資料時，請先確認可用的備份。

## 升級

repo 是版本的唯一來源：同時修改 `quadlet/n8n.container`、
`quadlet/queue/n8n-worker.container`、`quadlet/queue/n8n-webhook.container` 的 n8n 版本，
以及 `quadlet/optional/n8n-runners.container`、
`quadlet/queue/n8n-worker-runners.container` 的 runner 版本（都要一致），commit 後執行：

```bash
git pull
scripts/upgrade.sh              # 跨大版本（2.x -> 3.x）需要 --allow-major
```

它會拒絕降版、n8n 與 runner 版本不一致、以及 Postgres 大版本變動；在停止任何服務之前先拉取
映像檔；備份、重啟、以 900 秒逾時執行 smoke 測試；失敗時自動還原舊 unit 並回復升級前的資料庫
（n8n 的 migration 只能往前）。queue 升級會先做冷備份，失敗時還原資料庫與 Valkey 狀態。
既有主機的 `n8n.env` 不會自動加入新預設值；升級前請和 `config/n8n.env.example` 比對。
升到 2.43.6 後，舊 API key 若因缺少新 scope 導致公開 API 回傳 403，請重新建立。

**Postgres 大版本升級**（16 -> 17）屬於獨立作業：`scripts/backup.sh --cold`、修改映像檔版本、
刪除 volume `n8n_postgres_data`、`scripts/install.sh`，最後 `scripts/restore.sh`。

## 備份與還原

```bash
scripts/backup.sh                     # regular 為熱備份；queue 自動改為冷備份
scripts/backup.sh --cold              # 一致性資料庫 dump 與所有使用中資料卷匯出
scripts/restore.sh ~/backups/n8n/<timestamp> [--yes]
```

備份目錄權限為 0700 並附上 `SHA256SUMS`，`restore.sh` 會先驗證。裡面含有**憑證加密金鑰**
（`n8n_n8n_data`）與資料庫密碼：請另存到本機以外的地方，並比照憑證本身保護。沒有加密金鑰，
還原後的資料庫裡的憑證也無法解密。
queue 備份另含 `n8n_valkey_data` 與密碼 secret；請先安裝 queue 拓樸再還原，讓資料庫與待處理
工作保持一致。

每日備份（以服務帳號執行）：

```bash
systemd-run --user --on-calendar='*-*-* 03:30:00' --unit=n8n-backup \
  ~/woow-quadlet/Woow_podman_n8n/scripts/backup.sh
```

## 移除

```bash
scripts/uninstall.sh                  # 停止並移除 unit，資料全部保留
scripts/uninstall.sh --purge --yes    # 另外刪除 volume、網路與 secret
```

`--purge` 是本 repo 唯一會刪除資料的方式，而且會先把使用中的 volume 與 secret 匯出到
`~/backups/n8n/purge-<timestamp>/`。`~/.config/n8n/n8n.env` 永遠保留。

## 從既有 compose / podman-compose 部署遷移

`scripts/migrate-legacy.sh` 會就地沿用既有的 volume（`n8n_n8n_data`、`n8n_postgres_data`）
與網路 `n8n-network`（不搬移資料），並保留舊容器與舊 unit 以便回滾，停機約 2-3 分鐘。

```bash
# 1. 舊堆疊繼續運作時先檢查與準備（不停機）
scripts/migrate-legacy.sh --legacy-dir ~/podman/Woow_podman_n8n --dry-run
scripts/migrate-legacy.sh --legacy-dir ~/podman/Woow_podman_n8n \
    --public-url https://n8n.example.com/ --prepare-only

# 2. 切換（開始停機）：停止、冷備份、改名、安裝、smoke
scripts/migrate-legacy.sh --legacy-dir ~/podman/Woow_podman_n8n \
    --public-url https://n8n.example.com/ --yes

# 3. 有問題時回滾（約 1 分鐘，不會遺失資料）
scripts/migrate-legacy.sh --rollback --yes
```

它會：確認舊容器執行的版本與本 repo 釘選的版本相同、volume 名稱符合、
`podman-restart.service` 未啟用；用舊 `.env` 產生 `~/.config/n8n/n8n.env`；用舊的
`POSTGRES_PASSWORD` 建立 `n8n-db-password`；先做熱備份，停止後再冷匯出兩個 volume；停用
`podman-n8n.service`（檔案保留）；把容器改名為 `<name>-legacy-YYYYMMDD`；安裝新 unit；
最後比對工作流程、憑證與使用者數量。切換失敗會自動回滾（`--no-auto-rollback` 可保留現場）。

遷移刻意造成的變更：發布位址由 `0.0.0.0` 改為 `127.0.0.1`（可用 `--bind` 覆寫）、維持啟用
secure cookie、`WEBHOOK_URL` 改為 `N8N_WEBHOOK_URL`，以及 task runner 移出 n8n 行程。

**觀察期結束後**（約一週，含一次重開機）：

```bash
podman rm n8n-legacy-YYYYMMDD n8n-postgres-legacy-YYYYMMDD
rm ~/.config/systemd/user/podman-n8n.service && systemctl --user daemon-reload
podman untag docker.io/n8nio/n8n:latest docker.io/library/postgres:16-alpine
```

## 疑難排解

| 現象 | 原因與處理 |
|---|---|
| `Unit n8n.service not found` | 產生器拒絕了某個檔案。執行 `tests/dryrun.sh`，再 `systemctl --user daemon-reload` |
| 安裝被擋下並顯示 legacy container | 同名容器不是 Quadlet 建立的。Quadlet 的 `--replace` 會刪掉它：依訊息指示改名，或改用 `migrate-legacy.sh` |
| 登入一直跳回、出現 secure cookie 警告 | 你從其他機器用純 http 存取。請改用公開的 https 網址，或設定 `N8N_SECURE_COOKIE=false`（不建議） |
| webhook 指向錯誤的主機 | 設定公開網址：`scripts/install.sh --public-url https://…/` |
| 日誌出現 `Python 3 is missing` | 目前是 internal runner 模式：設定 `N8N_RUNNERS_MODE=external` 後重新執行 `install.sh` |
| 重開機後服務沒有回來 | linger 沒開：`sudo loginctl enable-linger $USER` |

## Docker Compose

本 repo 只保留 Quadlet 部署。最後一個含 `docker-compose.yml` 的版本標記為
[`compose-final`](https://github.com/WOOWTECH/Woow_podman_n8n/tree/compose-final)：

```bash
git clone --branch compose-final https://github.com/WOOWTECH/Woow_podman_n8n
```

全新的 Docker 部署建議直接參考 n8n 官方的
[Docker Compose 指南](https://docs.n8n.io/hosting/installation/server-setups/docker-compose/)。

## 其他部署平台

- **K3s / Kubernetes（Helm chart）** → [Woow_k3s_n8n](https://github.com/WOOWTECH/Woow_k3s_n8n)
- **Home Assistant add-on** → [Woow_ha_n8n](https://github.com/WOOWTECH/Woow_ha_n8n)
