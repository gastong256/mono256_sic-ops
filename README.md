# ops

Infrastructure automation for a zero-cost production stack. All workflows run on GitHub Actions (public repo = unlimited minutes).

---

## Stack

| Component | Service | Notes |
|-----------|---------|-------|
| API | Django on Render (free tier) | Spins down after 15 min of inactivity |
| Cache | Redis on Render (free tier) | Also spins down with the API |
| Database | PostgreSQL on Supabase (free tier) | No automatic backups included |
| Frontend | Next.js on Vercel | CDN — no spin-down |
| Backup storage | Cloudflare R2 (free tier) | 10 GB storage, $0 egress |

---

## Workflows

| File | Schedule | Description |
|------|----------|-------------|
| `keep-alive.yml` | Every 5 minutes | Hits the Django `/health/` endpoint to keep API + Redis alive. Checks Redis status from the JSON response. Triggers Render redeploy if the API is unreachable after 3 retries. Optionally monitors the frontend. |
| `backup-supabase-r2.yml` | Daily at 3 AM UTC | Runs `pg_dump` against Supabase, compresses with gzip, uploads to Cloudflare R2, and prunes backups older than 7 days. |
| `secret-scan.yml` | Every push & PR | Runs `detect-secrets` against the repository and fails CI if new secrets are found that aren't in the baseline. |

---

## Local setup

Requires Python 3.11+ and `make`.

```bash
make setup
```

This creates a virtualenv, installs all dependencies, and installs the pre-commit hook that runs `detect-secrets` before every commit.

### Available commands

| Command | Description |
|---------|-------------|
| `make setup` | Create venv, install deps, install pre-commit hook |
| `make lint` | Validate workflow YAML syntax |
| `make scan` | Run secret scan manually against the current baseline |
| `make baseline` | Regenerate `.secrets.baseline` (after false positives) |
| `make audit` | Interactively mark false positives in the baseline |
| `make clean` | Remove the virtual environment |
| `make` | Show all commands with descriptions |

---

## Secrets configuration

Go to **Settings → Secrets and variables → Actions → New repository secret**.

### API & Render

| Secret | Description | Where to get it |
|--------|-------------|-----------------|
| `API_HEALTH_URL` | Full URL of your Django health check endpoint | Your Render service URL + `/health/` |
| `RENDER_DEPLOY_HOOK_URL` | Render deploy hook URL | Render dashboard → your service → Settings → Deploy Hook → Create Deploy Hook |

### Supabase

| Secret | Description | Where to get it |
|--------|-------------|-----------------|
| `SUPABASE_DB_HOST` | PostgreSQL host | Supabase dashboard → Project Settings → Database → Connection string → Host |
| `SUPABASE_DB_USER` | PostgreSQL user | Same page — default is `postgres` |
| `SUPABASE_DB_PASSWORD` | PostgreSQL password | Same page — the password you set when creating the project |

### Cloudflare R2

| Secret | Description | Where to get it |
|--------|-------------|-----------------|
| `R2_ACCESS_KEY_ID` | R2 API token key ID | Cloudflare dashboard → R2 → Manage R2 API Tokens → Create API Token (Object Read & Write) |
| `R2_SECRET_ACCESS_KEY` | R2 API token secret | Same page — only shown once at creation |
| `R2_ENDPOINT` | R2 S3-compatible endpoint | Format: `https://<account-id>.r2.cloudflarestorage.com` — Account ID is in the R2 overview page |
| `R2_BUCKET_NAME` | Name of the R2 bucket | The bucket you created for backups |

### Optional

| Secret | Description | Where to get it |
|--------|-------------|-----------------|
| `FRONTEND_URL` | Public URL of your Vercel frontend | Your Vercel project URL. If not set, the frontend check is skipped. |
| `DISCORD_WEBHOOK_URL` | Discord webhook for alerts | Discord → channel settings → Integrations → Webhooks → New Webhook → Copy URL. If not set, all notifications are skipped. |

---

## How the health check works

The `keep-alive` workflow expects your Django `/health/` view to return a JSON response like:

```json
{
  "status": "ok",
  "redis": true
}
```

The workflow hits this endpoint every 5 minutes. Because the Django view performs `cache.set` / `cache.get` against Redis on each request, a single HTTP call keeps **both** the API and Redis alive simultaneously.

If `redis` is `false` in the response, a Discord alert is sent specifying Redis as the failing component.

If the API returns a non-200 status or times out after 3 retries (spaced 10 seconds apart), a redeploy is triggered via the Render deploy hook, and Discord is notified.

---

## Restoring a backup from R2

### 1. List available backups

```bash
AWS_ACCESS_KEY_ID=<key> \
AWS_SECRET_ACCESS_KEY=<secret> \
AWS_DEFAULT_REGION=auto \
aws s3 ls s3://<bucket-name>/ \
  --endpoint-url https://<account-id>.r2.cloudflarestorage.com
```

### 2. Download a backup

```bash
AWS_ACCESS_KEY_ID=<key> \
AWS_SECRET_ACCESS_KEY=<secret> \
AWS_DEFAULT_REGION=auto \
aws s3 cp s3://<bucket-name>/backup_YYYYMMDD_HHMMSS.dump.gz . \
  --endpoint-url https://<account-id>.r2.cloudflarestorage.com
```

### 3. Decompress

```bash
gunzip backup_YYYYMMDD_HHMMSS.dump.gz
```

### 4. Restore with pg_restore

```bash
pg_restore \
  -h <host> \
  -U <user> \
  -d <database_name> \
  --no-owner \
  --role=<user> \
  backup_YYYYMMDD_HHMMSS.dump
```

> For a clean restore to an empty database, add `--clean --if-exists` to drop existing objects before recreating them.

---

## Security

This repo is **public** to get unlimited GitHub Actions minutes. Secrets are protected by multiple layers:

| Layer | Mechanism | Details |
|-------|-----------|---------|
| 1 | GitHub Secrets | All credentials stored as encrypted secrets, never in code. Automatically redacted from logs. |
| 2 | GitHub Push Protection | Blocks pushes that contain known secret patterns. Enable at: Settings → Code security → Push protection. |
| 3 | `detect-secrets` CI | Scans every push and PR against `.secrets.baseline`. Fails CI if new secrets are found. |
| 4 | `.gitignore` | Excludes `.env`, `*.key`, `*.pem`, `*.dump`, `*.sql`, and `credentials/` from being tracked. |

### Handling false positives in secret-scan

If `detect-secrets` flags something that is not actually a secret:

```bash
# Regenerate the baseline
make baseline

# Interactively mark false positives (press 'n' = not a secret)
make audit

# Commit the updated baseline
git add .secrets.baseline
git commit -m "chore: update secrets baseline (false positive)"
```

---

## Cost breakdown

| Service | Usage | Free tier limit | Cost |
|---------|-------|-----------------|------|
| GitHub Actions | ~8,640 runs/month (keep-alive) + ~30 backups/month | Unlimited (public repo) | $0 |
| Render API (free) | Kept alive by keep-alive workflow | 750 hours/month | $0 |
| Render Redis (free) | Kept alive via API health check | 750 hours/month | $0 |
| Supabase PostgreSQL | Production database | 500 MB storage, 2 GB transfer | $0 |
| Cloudflare R2 | ~30 backup files/month | 10 GB storage, 0 egress fees | $0 |
| Vercel (frontend) | CDN — no keep-alive needed | 100 GB bandwidth/month | $0 |
| **Total** | | | **$0/month** |
