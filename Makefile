.PHONY: help test lint check
help:
	@echo 'test   Run all plan-and-verify script regression tests'
	@echo 'lint   Check Bash syntax and plugin JSON'
	@echo 'check  Run syntax checks and tests; never install or publish'

test:
	bash plugins/plan-and-verify/tests/run.sh

lint:
	@for f in plugins/plan-and-verify/hooks/*.sh plugins/plan-and-verify/tests/*.sh; do bash -n "$$f" || exit; done
	@jq -e . .claude-plugin/marketplace.json plugins/plan-and-verify/.claude-plugin/plugin.json plugins/plan-and-verify/hooks/hooks.json >/dev/null

check: lint test
