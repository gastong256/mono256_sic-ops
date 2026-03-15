VENV        := .venv
PYTHON      := $(VENV)/bin/python
PIP         := $(VENV)/bin/pip
PRE_COMMIT  := $(VENV)/bin/pre-commit
DET_SECRETS := $(VENV)/bin/detect-secrets
YAMLLINT    := $(VENV)/bin/yamllint
BASELINE    := .secrets.baseline
WORKFLOWS   := .github/workflows

.DEFAULT_GOAL := help

# ── Bootstrap ────────────────────────────────────────────────────────────────

.PHONY: setup
setup: ## Create or update venv, install/upgrade deps, install pre-commit hook
	@if [ ! -d "$(VENV)" ]; then \
		echo "→ Creating virtualenv..."; \
		python3 -m venv $(VENV); \
	else \
		echo "→ Virtualenv already exists, skipping creation."; \
	fi
	@echo "→ Installing/upgrading dependencies..."
	@$(PIP) install --quiet --upgrade pip
	@$(PIP) install --quiet -r requirements.txt
	@echo "→ Installing pre-commit hook..."
	@$(PRE_COMMIT) install
	@echo "✓ Ready."

# Ensure venv exists before running any command that needs it
.PHONY: _require_venv
_require_venv:
	@if [ ! -f "$(PIP)" ]; then \
		echo "✗ Virtualenv not found. Run: make setup"; \
		exit 1; \
	fi

# ── Linting ──────────────────────────────────────────────────────────────────

.PHONY: lint
lint: _require_venv ## Validate workflow YAML syntax
	$(YAMLLINT) -d '{extends: default, rules: {line-length: {max: 120}}}' $(WORKFLOWS)/

# ── Secret scanning ──────────────────────────────────────────────────────────

.PHONY: scan
scan: _require_venv ## Run secret scan against current baseline
	$(DET_SECRETS) scan --exclude-files '\.secrets\.baseline' > /tmp/current_scan.json
	@python3 - <<'EOF'
	import sys, json
	with open("/tmp/current_scan.json") as f:
	    current = json.load(f)
	with open("$(BASELINE)") as f:
	    baseline = json.load(f)
	baseline_secrets = {
	    (fp, s["hashed_secret"])
	    for fp, secrets in baseline.get("results", {}).items()
	    for s in secrets
	}
	new = {}
	for fp, secrets in current.get("results", {}).items():
	    for s in secrets:
	        if (fp, s["hashed_secret"]) not in baseline_secrets:
	            new.setdefault(fp, []).append(s)
	if new:
	    print("NEW SECRETS DETECTED:")
	    for fp, secrets in new.items():
	        for s in secrets:
	            print(f"  File: {fp}  |  Type: {s['type']}  |  Line: {s['line_number']}")
	    sys.exit(1)
	else:
	    print("✓ No new secrets detected.")
	EOF

.PHONY: baseline
baseline: _require_venv ## Regenerate .secrets.baseline (run after false positives)
	$(DET_SECRETS) scan --exclude-files '\.secrets\.baseline' > $(BASELINE)
	@echo "✓ Baseline updated. Review with: make audit"
	@echo "  Then: git add $(BASELINE) && git commit -m 'chore: update secrets baseline'"

.PHONY: audit
audit: _require_venv ## Interactively audit baseline (mark false positives)
	$(DET_SECRETS) audit $(BASELINE)

# ── Maintenance ───────────────────────────────────────────────────────────────

.PHONY: clean
clean: ## Remove virtual environment
	rm -rf $(VENV)
	@echo "✓ Cleaned."

# ── Help ─────────────────────────────────────────────────────────────────────

.PHONY: help
help: ## Show available commands
	@grep -E '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*##"}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
