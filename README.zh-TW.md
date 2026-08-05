# n8n + PostgreSQL Docker Compose (Podman)

使用 Podman Compose 部署 [n8n](https://n8n.io/) 工作流程自動化平台，搭配 PostgreSQL 資料庫。

[English Version](README.md)

## 架構圖

```
┌──────────────────────────────────────────────────┐
│          Cloudflare Tunnel（可選，外部存取）        │
└─────────────────┬────────────────────────────────┘
                  │
                  ▼
┌──────────────────────────────────────────────────┐
│            Podman 網路 (n8n-network)              │
│                                                  │
│  ┌──────────────────┐    ┌────────────────────┐  │
│  │       n8n        │    │   PostgreSQL 16     │  │
│  │   (latest)       │───▶│    (Alpine)         │  │
│  │  埠號: 15678     │    │  埠號: 5432（內部） │  │
│  └────────┬─────────┘    └────────┬───────────┘  │
│           │                       │              │
│           ▼                       ▼              │
│     n8n_data vol          postgres_data vol       │
└──────────────────────────────────────────────────┘
```

## 一鍵部署至 Portainer

使用 Portainer 的 Stack 功能，可透過 GitHub Repository 網址快速部署本專案。

[![Deploy to Portainer](https://img.shields.io/badge/Deploy_to-Portainer-13BEF9?style=for-the-badge&logo=portainer&logoColor=white)](#一鍵部署至-portainer)

### 使用 Git Repository 部署（推薦）

1. 登入你的 Portainer 管理介面
2. 進入 **Stacks** → **Add stack**
3. 選擇 **Repository**
4. 填入以下資訊：

   | 欄位 | 值 |
   |------|-----|
   | **Repository URL** | `https://github.com/WOOWTECH/Woow_podman_n8n` |
   | **Repository reference** | `refs/heads/main` |
   | **Compose path** | `docker-compose.yml` |

5. 點擊 **Deploy the stack**

### 使用 Web Editor 部署

1. 複製 `docker-compose.yml` 的 Raw URL：

   ```
   https://raw.githubusercontent.com/WOOWTECH/Woow_podman_n8n/main/docker-compose.yml
   ```

2. 登入 Portainer → **Stacks** → **Add stack** → **Web editor**
3. 使用 `curl` 或瀏覽器取得上述 URL 的內容，貼入編輯器
4. 設定環境變數（參考 `.env`）
5. 點擊 **Deploy the stack**

## 系統需求

- Podman（v4.0+）
- podman-compose（v1.0+）

```bash
# 檢查版本
podman --version
podman-compose --version
```

## 專案結構

```
.
├── docker-compose.yml    # 服務定義（n8n + PostgreSQL）
├── .env.example          # 環境變數範本
├── .env                  # 實際環境變數（已加入 gitignore）
├── .gitignore            # Git 忽略規則
├── README.md             # 英文說明文件
├── README.zh-TW.md       # 中文說明文件（本檔案）
└── docs/
    ├── plans/
    │   └── 2026-02-17-n8n-postgres-podman-design.md
    └── skills/
        └── deploy-n8n-postgres.md   # AI 部署技能檔
```

## 快速部署

### 步驟一：複製儲存庫

```bash
git clone https://github.com/WOOWTECH/Woow_podman_n8n.git
cd Woow_podman_n8n
```

### 步驟二：設定環境變數

```bash
cp .env.example .env
```

編輯 `.env`，更新以下項目：
- `POSTGRES_PASSWORD` - 設定安全的密碼
- `WEBHOOK_URL` - 替換為伺服器 IP：`http://<伺服器IP>:15678/`

### 步驟三：啟動服務

```bash
podman-compose up -d
```

### 步驟四：驗證部署

```bash
# 檢查容器狀態
podman-compose ps

# 健康檢查
curl -s http://localhost:15678/healthz
# 預期回應：{"status":"ok"}
```

### 步驟五：存取 n8n

在瀏覽器開啟 `http://<伺服器IP>:15678`

第一個註冊的使用者會自動成為**管理員**。

## 環境變數

| 變數 | 說明 | 預設值 |
|------|------|--------|
| `POSTGRES_USER` | PostgreSQL 使用者名稱 | `n8n` |
| `POSTGRES_PASSWORD` | PostgreSQL 密碼 | *（在 .env 中設定）* |
| `POSTGRES_DB` | 資料庫名稱 | `n8n` |
| `N8N_PORT` | n8n 對外埠號 | `15678` |
| `N8N_HOST` | n8n 綁定位址 | `0.0.0.0` |
| `N8N_PROTOCOL` | 協定（http/https） | `http` |
| `WEBHOOK_URL` | Webhook 回呼網址 | `http://localhost:15678/` |
| `GENERIC_TIMEZONE` | 時區 | `Asia/Taipei` |

### 重要設定說明

- **`N8N_SECURE_COOKIE=false`** 已在 `docker-compose.yml` 中設定，允許透過 HTTP 登入內網。若使用 HTTPS（如 Cloudflare Tunnel），可移除此設定。
- **`N8N_HOST=0.0.0.0`** 允許網路上任何 IP 連線，不僅限 localhost。
- **埠號 15678** 用於避免與其他服務衝突。

## 常用指令

```bash
# 啟動服務（背景執行）
podman-compose up -d

# 停止服務（保留資料）
podman-compose down

# 停止服務並刪除所有資料
podman-compose down -v

# 查看所有日誌
podman-compose logs -f

# 只查看 n8n 日誌
podman-compose logs -f n8n

# 只查看 PostgreSQL 日誌
podman-compose logs -f postgres

# 重啟所有服務
podman-compose restart

# 只重啟 n8n
podman-compose restart n8n

# 檢查容器狀態
podman-compose ps

# 查看解析後的設定
podman-compose config
```

## 備份與還原

### 備份 PostgreSQL

```bash
podman exec n8n-postgres pg_dump -U n8n n8n > backup_$(date +%Y%m%d_%H%M%S).sql
```

### 還原 PostgreSQL

```bash
podman exec -i n8n-postgres psql -U n8n n8n < backup_YYYYMMDD_HHMMSS.sql
```

### 備份 n8n 資料 volume

```bash
podman volume export n8n_n8n_data > n8n_data_backup_$(date +%Y%m%d_%H%M%S).tar
```

### 還原 n8n 資料 volume

```bash
podman volume import n8n_n8n_data n8n_data_backup_YYYYMMDD_HHMMSS.tar
```

## 更新 n8n

```bash
# 拉取最新映像
podman-compose pull n8n

# 用新映像重建容器
podman-compose up -d
```

## Cloudflare Tunnel 整合

使用 Cloudflare Tunnel 進行外部存取時，更新 `.env`：

```bash
WEBHOOK_URL=https://n8n.yourdomain.com/
```

無需其他修改 — Tunnel 在內部連接到 `http://localhost:15678`。

## 疑難排解

### 無法透過 HTTP 登入（secure cookie 錯誤）

確認 `docker-compose.yml` 的 n8n 環境變數中已設定 `N8N_SECURE_COOKIE=false`。

### n8n 容器持續重啟

```bash
# 檢查 PostgreSQL 健康狀態
podman-compose logs postgres

# 檢查 n8n 錯誤日誌
podman-compose logs n8n
```

### 埠號衝突

如果 15678 已被佔用，在 `.env` 中修改 `N8N_PORT`：

```bash
N8N_PORT=25678
```

然後重啟：`podman-compose down && podman-compose up -d`

### 無法從其他裝置連線

確認 `.env` 中 `N8N_HOST=0.0.0.0`，並檢查防火牆規則：

```bash
# 檢查埠號是否開放
ss -tlnp | grep 15678
```

---

## AI 快速部署

> 此區塊專為 AI 助手快速部署 n8n 設計。

### 前置檢查

```bash
podman --version && podman-compose --version
```

### 部署

```bash
git clone https://github.com/WOOWTECH/Woow_podman_n8n.git
cd Woow_podman_n8n
cp .env.example .env
# 自動替換 WEBHOOK_URL 為實際伺服器 IP
SERVER_IP=$(hostname -I | awk '{print $1}')
sed -i "s|WEBHOOK_URL=http://localhost:15678/|WEBHOOK_URL=http://${SERVER_IP}:15678/|" .env
podman-compose up -d
```

### 驗證

```bash
sleep 10 && podman-compose ps && curl -s http://localhost:15678/healthz
```

### 移除

```bash
# 保留資料
podman-compose down

# 刪除所有資料
podman-compose down -v
```

### 設定摘要

| 項目 | 值 |
|------|-----|
| n8n 網址 | `http://<伺服器IP>:15678` |
| 資料庫 | PostgreSQL 16（內部埠號 5432） |
| 認證 | n8n 內建帳號（第一位使用者 = 管理員） |
| HTTP 登入 | 已啟用（`N8N_SECURE_COOKIE=false`） |
| 資料儲存 | Named volumes（`postgres_data`、`n8n_data`） |
| 自動重啟 | `unless-stopped` |
| 網路 | `n8n-network` |

---

## 其他部署平台

- **K3s/Kubernetes(Helm chart)** → [Woow_k3s_n8n](https://github.com/WOOWTECH/Woow_k3s_n8n)
- **Home Assistant add-on** → [Woow_ha_n8n](https://github.com/WOOWTECH/Woow_ha_n8n)
