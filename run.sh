./copilot-review-loop.zsh \
  --task-file task.md \
  --lint-cmd "ruff check ." \
  --typecheck-cmd "mypy ." \
  --test-cmd "pytest -q" \
  --commit-message "feat: strengthen registration validation"
