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
n8n-postgres.service         n8n.service  ◀──Requires──  n8n-runners.service
postgres:16.15-alpine        n8nio/n8n              n8nio/runners（選配）
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
| `N8N_HOST`、`N8N_PROTOCOL` | `localhost`、`http` | n8n 認為自己被存取的主機與協定 |
| `N8N_EDITOR_BASE_URL`、`N8N_WEBHOOK_URL` | 未設定 | 公開網址（`--public-url` 會寫入） |
| `N8N_PROXY_HOPS` | 未設定 | 前方的 proxy 層數（Tunnel 或 NPM 為 1） |
| `GENERIC_TIMEZONE`、`TZ` | `Asia/Taipei` | 排程與日誌時區 |
| `N8N_RUNNERS_MODE` | `external` | `external` 會安裝 sidecar，`internal` 則在 n8n 內執行程式碼 |

請勿設定 `N8N_PORT`（那是容器內的埠號）或 `DB_POSTGRESDB_*`，這些由 unit 決定；
`install.sh` 會對被忽略的鍵提出警告。

**Secret**（podman secret，第一次安裝時建立，永不列印）：

| Secret | 用途 |
|---|---|
| `n8n-db-password` | `POSTGRES_PASSWORD`（initdb）與 `DB_POSTGRESDB_PASSWORD` |
| `n8n-runners-auth-token` | n8n 與 runner 共用；即使是 internal 模式也必須存在 |

**Task runner**：外部 runner 會把 Code 節點的 JavaScript 與 Python 放到獨立容器執行，這也是
上游的建議做法；internal 模式下，能編輯工作流程的人就能讀到加密金鑰與所有憑證。
`n8nio/n8n` 與 `n8nio/runners` 版本必須一致，`tests/dryrun.sh` 與 `scripts/upgrade.sh` 會強制檢查。

## 日常操作

```bash
systemctl --user status n8n.service              # 單一 unit
systemctl --user restart n8n.target              # 整個堆疊
journalctl --user -u n8n.service -f              # 日誌（LogDriver=journald）
podman exec n8n n8n --version
tests/smoke.sh                                   # 健康檢查，不會改動任何東西
tests/smoke.sh --public-url https://n8n.example.com/
```

## 升級

repo 是版本的唯一來源：同時修改 `quadlet/n8n.container` 與
`quadlet/optional/n8n-runners.container` 的 `Image=`（版本要一致），commit 之後執行：

```bash
git pull
scripts/upgrade.sh              # 跨大版本（2.x -> 3.x）需要 --allow-major
```

它會拒絕降版、n8n 與 runner 版本不一致、以及 Postgres 大版本變動；在停止任何服務之前先拉取
映像檔；備份、重啟、以 900 秒逾時執行 smoke 測試；失敗時自動還原舊 unit 並回復升級前的資料庫
（n8n 的 migration 只能往前）。

**Postgres 大版本升級**（16 -> 17）屬於獨立作業：`scripts/backup.sh --cold`、修改映像檔版本、
刪除 volume `n8n_postgres_data`、`scripts/install.sh`，最後 `scripts/restore.sh`。

## 備份與還原

```bash
scripts/backup.sh                     # 熱備份：資料庫 dump、角色、n8n_n8n_data、secret、unit
scripts/backup.sh --cold              # 另外停止服務並匯出 n8n_postgres_data
scripts/restore.sh ~/backups/n8n/<timestamp> [--yes]
```

備份目錄權限為 0700 並附上 `SHA256SUMS`，`restore.sh` 會先驗證。裡面含有**憑證加密金鑰**
（`n8n_n8n_data`）與資料庫密碼：請另存到本機以外的地方，並比照憑證本身保護。沒有加密金鑰，
還原後的資料庫裡的憑證也無法解密。

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

`--purge` 是本 repo 唯一會刪除資料的方式，而且會先把兩個 volume 與 secret 匯出到
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
