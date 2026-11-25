SHELL := /bin/sh
.DEFAULT_GOAL := help

PLUGIN_MANIFEST := .claude-plugin/plugin.json
MARKETPLACE_MANIFEST := .claude-plugin/marketplace.json
MANIFESTS := $(PLUGIN_MANIFEST) $(MARKETPLACE_MANIFEST)
GIT_CLIFF := git-cliff
CLAUDE := claude

.PHONY: help next-version check-version validate validate-plugin validate-agent-portability validate-skill-descriptions validate-apm release

help: ## Show available commands.
	@awk 'BEGIN { FS = ":.*##"; printf "Usage:\n  make <command>\n\nCommands:\n" } /^[a-zA-Z0-9_-]+:.*##/ { printf "  %-20s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

next-version: check-version ## Show the next SemVer inferred from Conventional Commits.
	@last_tag="$$(git describe --tags --match 'v[0-9]*' --abbrev=0 2>/dev/null || true)"; \
	if [ -z "$$last_tag" ]; then \
		printf '%s\n' 'No v* release tag found.'; \
		exit 1; \
	fi; \
	range="$$last_tag..HEAD"; \
	if ! git log --format=%s "$$range" | grep -Eq '^(feat|fix|perf|refactor|docs)(\([^)]+\))?!?: .+|^[a-z]+(\([^)]+\))?!: .+' && \
		! git log --format=%B "$$range" | grep -Eq '^BREAKING[ -]CHANGE: .+'; then \
		printf 'No release bump commits found since %s. ci:, test:, and chore: do not trigger releases.\n' "$$last_tag"; \
		exit 1; \
	fi; \
	current_version="$$(sed -nE 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' $(PLUGIN_MANIFEST) | head -n 1)"; \
	new_version="$$($(GIT_CLIFF) --bumped-version)"; \
	new_version="$${new_version#v}"; \
	if [ "$$new_version" = "$$current_version" ]; then \
		printf 'No release bump: manifest version remains %s\n' "$$current_version"; \
		exit 1; \
	fi; \
	printf '%s\n' "$$new_version"

check-version: ## Check that plugin and marketplace manifest versions match.
	@plugin_version="$$(sed -nE 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' $(PLUGIN_MANIFEST) | head -n 1)"; \
	marketplace_version="$$(sed -nE 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' $(MARKETPLACE_MANIFEST) | head -n 1)"; \
	test -n "$$plugin_version" || { printf 'Missing version in %s\n' '$(PLUGIN_MANIFEST)'; exit 1; }; \
	test -n "$$marketplace_version" || { printf 'Missing version in %s\n' '$(MARKETPLACE_MANIFEST)'; exit 1; }; \
	test "$$plugin_version" = "$$marketplace_version" || { printf 'Version mismatch: %s=%s, %s=%s\n' '$(PLUGIN_MANIFEST)' "$$plugin_version" '$(MARKETPLACE_MANIFEST)' "$$marketplace_version"; exit 1; }; \
	printf 'Manifest versions match: %s\n' "$$plugin_version"

validate: check-version validate-plugin validate-agent-portability validate-skill-descriptions ## Validate manifests, the plugin, agent portability, and skill description sizes.

validate-plugin: ## Validate the plugin and marketplace manifests with Claude Code.
	@$(CLAUDE) plugin validate .

validate-agent-portability: ## Validate portable agent frontmatter and harness-neutral skill paths.
	@tests/validate-agent-portability.sh

validate-skill-descriptions: ## Validate that each model-invocable skill description is at most 400 bytes.
	@tests/validate-skill-descriptions.sh

validate-apm: ## Verify APM deploys the agents portably (APM_TARGET=claude|codex|opencode, default all).
	@tests/validate-apm.sh $(APM_TARGET)

# The release script is taken from this checkout, not from the Run commit, whose tree may be older.
RELEASE_SCRIPT := $(dir $(abspath $(firstword $(MAKEFILE_LIST))))

release: ## Cut a release from the Run commit RUN=<commit>: a Release branch with a Bump commit, and its tag, pushed without main.
	@set -e; \
	test -n "$(RUN)" || { printf '%s\n' 'Usage: make release RUN=<a commit on main you ran>'; exit 1; }; \
	script="$(RELEASE_SCRIPT).github/scripts/release.sh"; \
	git fetch --tags origin; \
	run="$$(git rev-parse --verify "$(RUN)^{commit}")" || { printf 'Not a commit: %s\n' '$(RUN)'; exit 1; }; \
	git merge-base --is-ancestor "$$run" origin/main || { printf 'The Run commit %s is not reachable from origin/main.\n' "$$run"; exit 1; }; \
	previous="$$(git tag --list 'v[0-9]*' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$$' | sort -V | tail -n 1 || true)"; \
	test -n "$$previous" || { printf '%s\n' 'No v<major>.<minor>.<patch> release tag found.'; exit 1; }; \
	version="$$(bash "$$script" bump "$$run" "$$previous")"; \
	major="$${version%%.*}"; \
	tag="v$$version"; \
	branch="release/$$tag"; \
	! git rev-parse -q --verify "refs/tags/$$tag" >/dev/null || { printf 'Tag already exists: %s\n' "$$tag"; exit 1; }; \
	! git rev-parse -q --verify "refs/heads/$$branch" >/dev/null || { printf 'Branch already exists: %s\n' "$$branch"; exit 1; }; \
	home="$$PWD"; \
	wt="$$(mktemp -d)"; \
	pushed=0; \
	cleanup() { \
		cd "$$home"; \
		git worktree remove --force "$$wt" >/dev/null 2>&1 || true; \
		if [ "$$pushed" = 0 ]; then \
			git tag -d "$$tag" >/dev/null 2>&1 || true; \
			git branch -D "$$branch" >/dev/null 2>&1 || true; \
		fi; \
	}; \
	trap cleanup EXIT; \
	git worktree add -q -b "$$branch" "$$wt" "$$run"; \
	cd "$$wt"; \
	VERSION="$$version" perl -0pi -e 's/("version"[[:space:]]*:[[:space:]]*")[^"]+(")/$$1$$ENV{VERSION}$$2/' $(MANIFESTS); \
	name="$$(jq -r .name $(PLUGIN_MANIFEST))"; \
	jq --arg n "$$name" --arg t "$$tag" '(.plugins[]? | select(.name == $$n) | select(.source | type == "object") | .source.ref) = $$t' \
		$(MARKETPLACE_MANIFEST) > "$$wt/.marketplace.tmp"; \
	mv "$$wt/.marketplace.tmp" $(MARKETPLACE_MANIFEST); \
	TAG="$$tag" MAJOR="$$major" perl -pi -e 's/#v\d+\.\d+\.\d+/#$$ENV{TAG}/g; s/#\^\d+\.0\.0/#^$$ENV{MAJOR}.0.0/g' README.md; \
	$(CLAUDE) plugin validate .; \
	git add $(MANIFESTS) README.md; \
	git commit -q -m "chore: release $$tag"; \
	git tag -a "$$tag" -m "$$tag"; \
	bash "$$script" guard "$$tag" "$$previous"; \
	git push --atomic origin "refs/heads/$$branch" "refs/tags/$$tag"; \
	pushed=1; \
	printf 'Released %s on %s above %s. Open the Back-merge PR from %s.\n' "$$tag" "$$branch" "$$run" "$$branch"
