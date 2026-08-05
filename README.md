# n8n + PostgreSQL Docker Compose (Podman)

Deploy [n8n](https://n8n.io/) workflow automation platform with PostgreSQL database using Podman Compose.

[繁體中文版](README.zh-TW.md)

## Architecture

```
┌──────────────────────────────────────────────────┐
│            Cloudflare Tunnel (optional)           │
└─────────────────┬────────────────────────────────┘
                  │
                  ▼
┌──────────────────────────────────────────────────┐
│              Podman Network (n8n-network)         │
│                                                  │
│  ┌──────────────────┐    ┌────────────────────┐  │
│  │       n8n        │    │    PostgreSQL 16    │  │
│  │   (latest)       │───▶│    (Alpine)         │  │
│  │  Port: 15678     │    │  Port: 5432 (int)   │  │
│  └────────┬─────────┘    └────────┬───────────┘  │
│           │                       │              │
│           ▼                       ▼              │
│     n8n_data vol          postgres_data vol       │
└──────────────────────────────────────────────────┘
```

## Deploy to Portainer

Deploy this project instantly using Portainer's Stack feature with our GitHub repository URL.

[![Deploy to Portainer](https://img.shields.io/badge/Deploy_to-Portainer-13BEF9?style=for-the-badge&logo=portainer&logoColor=white)](#deploy-to-portainer)

### Via Git Repository (Recommended)

1. Log in to your Portainer dashboard
2. Navigate to **Stacks** → **Add stack**
3. Select **Repository**
4. Fill in the following:

   | Field | Value |
   |-------|-------|
   | **Repository URL** | `https://github.com/WOOWTECH/Woow_podman_n8n` |
   | **Repository reference** | `refs/heads/main` |
   | **Compose path** | `docker-compose.yml` |

5. Click **Deploy the stack**

### Via Web Editor

1. Copy the raw URL of `docker-compose.yml`:

   ```
   https://raw.githubusercontent.com/WOOWTECH/Woow_podman_n8n/main/docker-compose.yml
   ```

2. Log in to Portainer → **Stacks** → **Add stack** → **Web editor**
3. Fetch the content from the URL above using `curl` or your browser, paste into the editor
4. Set environment variables (refer to `.env`)
5. Click **Deploy the stack**

## Prerequisites

- Podman (v4.0+)
- podman-compose (v1.0+)

```bash
# Check versions
podman --version
podman-compose --version
```

## Project Structure

```
.
├── docker-compose.yml    # Service definitions (n8n + PostgreSQL)
├── .env.example          # Environment variable template
├── .env                  # Actual environment variables (git-ignored)
├── .gitignore            # Git ignore rules
├── README.md             # English documentation (this file)
├── README.zh-TW.md       # Chinese documentation
└── docs/
    ├── plans/
    │   └── 2026-02-17-n8n-postgres-podman-design.md
    └── skills/
        └── deploy-n8n-postgres.md   # AI deployment skill
```

## Quick Start

### Step 1: Clone the repository

```bash
git clone https://github.com/WOOWTECH/Woow_podman_n8n.git
cd Woow_podman_n8n
```

### Step 2: Configure environment

```bash
cp .env.example .env
```

Edit `.env` and update:
- `POSTGRES_PASSWORD` - Set a secure password
- `WEBHOOK_URL` - Replace with your server IP: `http://<SERVER_IP>:15678/`

### Step 3: Start services

```bash
podman-compose up -d
```

### Step 4: Verify deployment

```bash
# Check container status
podman-compose ps

# Health check
curl -s http://localhost:15678/healthz
# Expected: {"status":"ok"}
```

### Step 5: Access n8n

Open `http://<SERVER_IP>:15678` in your browser.

The first user to register becomes the **admin**.

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `POSTGRES_USER` | PostgreSQL username | `n8n` |
| `POSTGRES_PASSWORD` | PostgreSQL password | *(set in .env)* |
| `POSTGRES_DB` | Database name | `n8n` |
| `N8N_PORT` | n8n exposed port | `15678` |
| `N8N_HOST` | n8n bind address | `0.0.0.0` |
| `N8N_PROTOCOL` | Protocol (http/https) | `http` |
| `WEBHOOK_URL` | Webhook callback URL | `http://localhost:15678/` |
| `GENERIC_TIMEZONE` | Timezone | `Asia/Taipei` |

### Key Configuration Notes

- **`N8N_SECURE_COOKIE=false`** is set in `docker-compose.yml` to allow HTTP login on internal networks. If you use HTTPS (e.g., via Cloudflare Tunnel), you can remove this setting.
- **`N8N_HOST=0.0.0.0`** allows connections from any IP on the network, not just localhost.
- **Port 15678** is used to avoid conflicts with other services.

## Common Commands

```bash
# Start services (detached)
podman-compose up -d

# Stop services (keep volumes)
podman-compose down

# Stop services and delete ALL data
podman-compose down -v

# View all logs
podman-compose logs -f

# View n8n logs only
podman-compose logs -f n8n

# View PostgreSQL logs only
podman-compose logs -f postgres

# Restart all services
podman-compose restart

# Restart n8n only
podman-compose restart n8n

# Check container status
podman-compose ps

# View resolved configuration
podman-compose config
```

## Backup & Restore

### Backup PostgreSQL

```bash
podman exec n8n-postgres pg_dump -U n8n n8n > backup_$(date +%Y%m%d_%H%M%S).sql
```

### Restore PostgreSQL

```bash
podman exec -i n8n-postgres psql -U n8n n8n < backup_YYYYMMDD_HHMMSS.sql
```

### Backup n8n data volume

```bash
podman volume export n8n_n8n_data > n8n_data_backup_$(date +%Y%m%d_%H%M%S).tar
```

### Restore n8n data volume

```bash
podman volume import n8n_n8n_data n8n_data_backup_YYYYMMDD_HHMMSS.tar
```

## Update n8n

```bash
# Pull latest image
podman-compose pull n8n

# Recreate container with new image
podman-compose up -d
```

## Cloudflare Tunnel Integration

When using Cloudflare Tunnel for external access, update `.env`:

```bash
WEBHOOK_URL=https://n8n.yourdomain.com/
```

No other changes needed - the tunnel connects to `http://localhost:15678` internally.

## Troubleshooting

### Cannot login via HTTP (secure cookie error)

Ensure `N8N_SECURE_COOKIE=false` is set in `docker-compose.yml` under n8n environment.

### n8n container keeps restarting

```bash
# Check PostgreSQL health
podman-compose logs postgres

# Check n8n error logs
podman-compose logs n8n
```

### Port conflict

If port 15678 is already in use, change `N8N_PORT` in `.env`:

```bash
N8N_PORT=25678
```

Then restart: `podman-compose down && podman-compose up -d`

### Cannot connect from other devices on the network

Verify `N8N_HOST=0.0.0.0` in `.env` and check firewall rules:

```bash
# Check if port is open
ss -tlnp | grep 15678
```

---

## AI Quick Deploy

> This section is designed for AI assistants to quickly deploy n8n from this repository.

### Prerequisites

```bash
podman --version && podman-compose --version
```

### Deploy

```bash
git clone https://github.com/WOOWTECH/Woow_podman_n8n.git
cd Woow_podman_n8n
cp .env.example .env
# Update WEBHOOK_URL with actual server IP
SERVER_IP=$(hostname -I | awk '{print $1}')
sed -i "s|WEBHOOK_URL=http://localhost:15678/|WEBHOOK_URL=http://${SERVER_IP}:15678/|" .env
podman-compose up -d
```

### Verify

```bash
sleep 10 && podman-compose ps && curl -s http://localhost:15678/healthz
```

### Teardown

```bash
# Keep data
podman-compose down

# Delete everything including data
podman-compose down -v
```

### Configuration Reference

| Item | Value |
|------|-------|
| n8n URL | `http://<SERVER_IP>:15678` |
| Database | PostgreSQL 16 (internal port 5432) |
| Auth | n8n built-in (first user = admin) |
| HTTP Login | Enabled (`N8N_SECURE_COOKIE=false`) |
| Data | Named volumes (`postgres_data`, `n8n_data`) |
| Auto-restart | `unless-stopped` |
| Network | `n8n-network` |

---

## Other deployment platforms

- **K3s/Kubernetes (Helm chart)** → [Woow_k3s_n8n](https://github.com/WOOWTECH/Woow_k3s_n8n)
- **Home Assistant add-on** → [Woow_ha_n8n](https://github.com/WOOWTECH/Woow_ha_n8n)

