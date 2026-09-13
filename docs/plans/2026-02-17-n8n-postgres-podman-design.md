> **Superseded (2026-09).** This document describes the original podman-compose design.
> The deployment is now Quadlet + systemd (`quadlet/`, `systemd/`, `scripts/`); see README.md
> and the `compose-final` tag for the last compose revision. Kept for the rationale behind
> the port choice (15678), the named volumes and the Postgres backend.

# n8n + PostgreSQL Podman 部署設計文件

## 概覽

部署 n8n 工作流程自動化平台，使用 PostgreSQL 作為資料庫，運行於 Podman 環境。

## 需求摘要

| 項目 | 選擇 |
|------|------|
| 部署環境 | 團隊共享伺服器 |
| 容器引擎 | Podman |
| 資料持久化 | Named volumes |
| 網路存取 | 內網 IP + Cloudflare Tunnel（外部） |
| 認證方式 | n8n 內建帳號系統 |
| n8n 版本 | Latest 標籤 |
| README 格式 | 分開檔案（英文 + 繁體中文） |

## 架構圖

```
┌─────────────────────────────────────────────────┐
│              Cloudflare Tunnel                  │
│            (外部連線，自行處理)                   │
└─────────────────┬───────────────────────────────┘
                  │
                  ▼
┌─────────────────────────────────────────────────┐
│                 Podman Network                  │
│  ┌───────────────┐      ┌───────────────────┐   │
│  │     n8n       │      │    PostgreSQL     │   │
│  │  (latest)     │─────▶│    (16-alpine)    │   │
│  │  Port: 5678   │      │   Port: 5432      │   │
│  └───────────────┘      └───────────────────┘   │
│         │                        │              │
│         ▼                        ▼              │
│   n8n_data volume         postgres_data volume  │
└─────────────────────────────────────────────────┘
```

## 檔案結構

```
podman_docker_app/
├── docker-compose.yml      # Podman Compose 主配置
├── .env                    # 實際環境變數（gitignore）
├── .env.example            # 環境變數範本（版本控制）
├── .gitignore              # 忽略 .env 等敏感檔案
├── README.md               # 英文部署說明
├── README.zh-TW.md         # 中文部署說明
└── docs/
    └── plans/
        └── 2026-02-17-n8n-postgres-podman-design.md
```

## 環境變數

| 變數 | 說明 | 預設值 |
|------|------|--------|
| POSTGRES_USER | PostgreSQL 使用者 | n8n |
| POSTGRES_PASSWORD | PostgreSQL 密碼 | （需設定） |
| POSTGRES_DB | 資料庫名稱 | n8n |
| N8N_PORT | n8n 對外 port | 5678 |
| N8N_HOST | n8n 主機名稱 | localhost |
| N8N_PROTOCOL | 協定 | http |
| WEBHOOK_URL | Webhook 回呼 URL | http://localhost:5678/ |
| GENERIC_TIMEZONE | 時區 | Asia/Taipei |

## Docker Compose 配置

- PostgreSQL 16 Alpine（輕量映像）
- n8n latest（自動更新）
- Named volumes 持久化
- PostgreSQL healthcheck 確保啟動順序
- `restart: unless-stopped` 自動重啟
- 移除 Basic Auth（使用 n8n 內建帳號系統）

## README 內容

兩份 README（英文/中文）皆包含：

1. Quick Start（3 步驟部署）
2. Environment Variables（環境變數說明）
3. Common Commands（常用指令）
4. AI Quick Deploy Section（AI 快速部署區塊）
5. Backup & Restore（備份還原）
6. Troubleshooting（疑難排解）
