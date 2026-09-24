#!/usr/bin/env bash
# One-time setup: log this Terminal into GitHub and push the project.
# Run from anywhere:  bash ~/Developer/nexus/scripts/push_to_github.sh
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> Checking GitHub CLI"
if ! command -v gh >/dev/null 2>&1; then
  if ! command -v brew >/dev/null 2>&1; then
    echo "Homebrew isn't installed. Install it from https://brew.sh, then run this again."
    exit 1
  fi
  brew install gh
fi

echo "==> Logging in (a browser window will open, click Authorize)"
if ! gh auth status -h github.com >/dev/null 2>&1; then
  gh auth login -h github.com -p https -w
fi
gh auth setup-git

echo "==> Committing anything new"
git add -A
git diff --cached --quiet || git commit -m "Phase 1: hand-tracked pointer, snapping, real clicks, 120Hz render, logging"

echo "==> Pushing"
# --force only replaces GitHub's auto-generated starter README on the first push
if git ls-remote --exit-code --heads origin main >/dev/null 2>&1 && \
   git merge-base --is-ancestor "$(git ls-remote origin main | cut -f1)" HEAD 2>/dev/null; then
  git push -u origin main
else
  git push -u origin main --force
fi

echo "==> Visibility"
vis=$(gh repo view --json visibility -q .visibility 2>/dev/null || echo unknown)
if [ "$vis" != "PUBLIC" ]; then
  read -r -p "Repo is $vis. Make it public so recruiters can see it? [y/N] " ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    gh repo edit --visibility public --accept-visibility-change-consequences
  fi
fi

echo ""
echo "Done: $(gh repo view --json url -q .url)"
echo "From now on, just: git add . && git commit -m \"...\" && git push"
