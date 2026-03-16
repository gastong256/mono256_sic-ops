# ops

Infra automation for a zero-cost production stack using GitHub Actions, Render,
Supabase, Vercel, and Cloudflare R2.

The repository is intentionally public so GitHub Actions minutes stay unlimited.
All credentials live in GitHub Actions secrets. No secrets belong in code.

## Stack

| Component | Service | Tier | Key limitation |
|---|---|---|---|
| API | Django on Render | Free | Spins down after 15 minutes of inactivity |
| Cache | Redis on Render | Free | Spins down with inactivity and exposes TCP only |
| Database | PostgreSQL on Supabase | Free | No automatic backups, 500 MB max, pauses after 7 idle days |
| Frontend | Vercel | Free | No spin-down needed for CDN delivery |
| Backups | Cloudflare R2 | Free | 10 GB storage, 1M Class A ops, 10M Class B ops, 0 egress |
| CI / Ops | GitHub Actions | Free for public repos | Public repos have unlimited minutes |

## Workflows

| Workflow | Schedule | Version | Description |
|---|---|---|---|
| `keep-alive.yml` | `*/5 * * * *` | v1 + v2 | Keeps Django and Redis warm through `/health/`, optionally checks frontend, triggers Render redeploy, then runs a smoke test after recovery |
| `backup-supabase-r2.yml` | `0 3 * * *` | v1 + v3 | Creates a daily compressed `pg_dump`, uploads it to R2, verifies integrity, tracks DB and R2 usage, and removes backups older than 7 days |
| `secret-scan.yml` | `push`, `pull_request` | v1 | Runs `detect-secrets` against the repository and fails when new secrets appear outside the baseline |
| `weekly-report.yml` | `0 9 * * 1` | v2 | Aggregates GitHub Actions health metrics for the previous 7 days and posts a weekly ops summary |
| `supabase-keepalive.yml` | `0 */12 * * *` | v4 | Executes a direct `SELECT 1` against Supabase every 12 hours to avoid idle project pausing |

## Required Secrets

Add these in GitHub: `Settings -> Secrets and variables -> Actions`.

| Secret | Required | Used by | Description | Where to get it |
|---|---|---|---|---|
| `API_HEALTH_URL` | Yes | `keep-alive`, `weekly-report` | Full Django health endpoint URL, usually `/health/` | Render service URL plus your health path |
| `RENDER_DEPLOY_HOOK_URL` | Yes | `keep-alive` | Render deploy hook used for auto-redeploy | Render dashboard -> service -> Settings -> Deploy Hook |
| `SUPABASE_DB_HOST` | Yes | `backup-supabase-r2`, `supabase-keepalive` | PostgreSQL host for the Supabase project | Supabase dashboard -> Project Settings -> Database |
| `SUPABASE_DB_USER` | Yes | `backup-supabase-r2`, `supabase-keepalive` | PostgreSQL username, commonly `postgres` | Supabase dashboard -> Project Settings -> Database |
| `SUPABASE_DB_PASSWORD` | Yes | `backup-supabase-r2`, `supabase-keepalive` | PostgreSQL password | Supabase dashboard -> Project Settings -> Database |
| `R2_ACCESS_KEY_ID` | Yes | `backup-supabase-r2`, `weekly-report` | R2 access key with object read/write permissions | Cloudflare dashboard -> R2 -> Manage R2 API Tokens |
| `R2_SECRET_ACCESS_KEY` | Yes | `backup-supabase-r2`, `weekly-report` | R2 secret access key | Same R2 API token screen, shown once on creation |
| `R2_ENDPOINT` | Yes | `backup-supabase-r2`, `weekly-report` | S3-compatible endpoint, for example `https://<account-id>.r2.cloudflarestorage.com` | Cloudflare dashboard -> R2 overview |
| `R2_BUCKET_NAME` | Yes | `backup-supabase-r2`, `weekly-report` | Bucket used to store backups | Name of the bucket you created in R2 |
| `FRONTEND_URL` | No | `keep-alive` | Public frontend URL to check | Vercel project URL |
| `DISCORD_WEBHOOK_URL` | No | All workflows | Discord webhook for alerts and weekly reports | Discord channel -> Integrations -> Webhooks |

## Django Health Contract

`keep-alive.yml` expects the Django health endpoint to return JSON like this:

```json
{
  "status": "ok",
  "redis": true
}
```

The endpoint should perform a `cache.set()` and `cache.get()` on each request so a
single HTTP call keeps both the Django service and the Redis instance active.

## Restore a Backup

### 1. List backups in R2

```bash
AWS_ACCESS_KEY_ID=<your-r2-key-id> \
AWS_SECRET_ACCESS_KEY=<your-r2-secret> \
AWS_DEFAULT_REGION=auto \
aws s3 ls "s3://<your-bucket>/" \
  --endpoint-url "<your-r2-endpoint>"
```

### 2. Download the backup you want

```bash
AWS_ACCESS_KEY_ID=<your-r2-key-id> \
AWS_SECRET_ACCESS_KEY=<your-r2-secret> \
AWS_DEFAULT_REGION=auto \
aws s3 cp "s3://<your-bucket>/backup_YYYYMMDD_HHMMSS.dump.gz" . \
  --endpoint-url "<your-r2-endpoint>"
```

### 3. Decompress it

```bash
gunzip backup_YYYYMMDD_HHMMSS.dump.gz
```

### 4. Restore with `pg_restore`

```bash
PGPASSWORD=<your-db-password> \
pg_restore \
  -h <your-db-host> \
  -p 5432 \
  -U <your-db-user> \
  -d postgres \
  --no-owner \
  --no-privileges \
  backup_YYYYMMDD_HHMMSS.dump
```

If you are restoring into a disposable or empty database and want a clean reset,
add `--clean --if-exists`.

## Security

This repository uses four layers of protection:

| Layer | Mechanism | Purpose |
|---|---|---|
| 1 | GitHub Actions secrets | Stores runtime credentials outside the codebase and redacts them in logs |
| 2 | GitHub Push Protection | Blocks pushes containing known secret formats before they land in the repo |
| 3 | `detect-secrets` in CI | Scans every push and pull request against `.secrets.baseline` |
| 4 | `.gitignore` rules | Prevents common local secret files, dumps, keys, and editor metadata from being committed |

Recommended GitHub settings:

1. Enable Push Protection in `Settings -> Code security`.
2. Restrict who can edit repository secrets.
3. Review every baseline change in PRs.

## False Positives

If `secret-scan.yml` flags a false positive:

```bash
make setup
make baseline
make audit
git add .secrets.baseline
git commit -m "chore: update secrets baseline"
```

`make audit` opens the interactive `detect-secrets` reviewer so you can mark the
finding as not a secret instead of weakening the scanner globally.

The baseline is intentionally opinionated for an ops repo: it enables the full
built-in detector set from `detect-secrets==1.5.0`, including GitHub, GitLab,
PyPI, OpenAI, Telegram, and high-entropy detectors, plus heuristic filters for
templated values, `${VAR}` references, lockfiles, UUID-like strings, and other
common infra false positives.

## Costs

| Service | Expected usage | Free tier limit | Status |
|---|---|---|---|
| GitHub Actions | ~8,640 keep-alive runs/month plus daily backups and weekly reports | Unlimited minutes for public repos | Fits |
| Render Web Service | Continuous warm checks to avoid spin-down | 750 hours/month | Fits if you only keep the API alive you truly need |
| Render Redis | Warmed indirectly by the Django health endpoint | 750 hours/month | Fits |
| Supabase PostgreSQL | Production app database | 500 MB storage | Tracked by `backup-supabase-r2.yml` warnings at 400 MB |
| Cloudflare R2 | Daily compressed backups retained for 7 days | 10 GB storage | Tracked by warnings at 8 GB |
| Vercel | Frontend hosting and CDN | Free hobby limits | No keep-alive needed |
| Discord webhooks | Notifications only | Free | Optional |

## Roadmap by Version

| Version | Includes |
|---|---|
| v1 | Keep-alive, Render auto-redeploy, daily Supabase backups to R2, detect-secrets CI |
| v2 | Post-redeploy smoke test and weekly consolidated ops report |
| v3 | Backup integrity verification plus DB and R2 size tracking |
| v4 | Direct Supabase keepalive query to prevent free-tier pausing during prolonged API outages |

## Local Commands

The repository already includes a small local toolchain for linting and secret
scanning:

| Command | Purpose |
|---|---|
| `make setup` | Create the virtualenv, install dependencies, install pre-commit hooks |
| `make lint` | Lint workflow YAML files |
| `make scan` | Compare the current tree against `.secrets.baseline` |
| `make baseline` | Regenerate `.secrets.baseline` using the repository plugin configuration |
| `make audit` | Interactively classify false positives |
| `make clean` | Remove the local virtualenv |
