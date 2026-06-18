#!/usr/bin/env bash
#
# onboard.sh — branche le Claude PR Reviewer sur un ou plusieurs repos.
# Pour chaque repo : (1) pose le secret CLAUDE_CODE_OAUTH_TOKEN,
#                    (2) commit le caller .github/workflows/claude-review.yml.
#
# Usage :
#   export CLAUDE_CODE_OAUTH_TOKEN="cc_oauth_xxx"     # cf. `claude setup-token`
#   ./scripts/onboard.sh owner/repo [owner/repo ...]
#   ./scripts/onboard.sh --all                        # tous tes repos non-fork, non-archivés
#
# Pré-requis : gh authentifié AVEC le scope `workflow` (sinon le commit du
# workflow est refusé) :  gh auth refresh -h github.com -s workflow
#
set -euo pipefail

REVIEWER_REPO="Ainoob59/claude-pr-reviewer"
REVIEWER_REF="v1"
CALLER_PATH=".github/workflows/claude-review.yml"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CALLER_SRC="$SCRIPT_DIR/../templates/claude-review.yml"

die() { echo "❌ $*" >&2; exit 1; }

[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] || die "Exporte d'abord CLAUDE_CODE_OAUTH_TOKEN (claude setup-token)."
[ -f "$CALLER_SRC" ] || die "Template introuvable: $CALLER_SRC"
command -v gh >/dev/null || die "gh CLI requis."

# Vérifie le scope workflow (via l'en-tête API — fiable, contrairement à `gh auth status`).
if ! gh api -i user 2>/dev/null | grep -i '^x-oauth-scopes:' | grep -q 'workflow'; then
  echo "⚠️  Le token gh n'a pas le scope 'workflow' (requis pour committer un workflow). Lance :"
  echo "    gh auth refresh -h github.com -s workflow"
  die "scope 'workflow' manquant."
fi

OWNER="$(gh api user --jq .login)"

# Construit la liste de repos.
REPOS=()
if [ "${1:-}" = "--all" ]; then
  while IFS= read -r r; do REPOS+=("$r"); done < <(
    gh repo list "$OWNER" --no-archived --source --limit 500 --json nameWithOwner --jq '.[].nameWithOwner'
  )
else
  [ "$#" -ge 1 ] || die "Donne au moins un repo (owner/repo) ou --all."
  REPOS=("$@")
fi

echo "→ ${#REPOS[@]} repo(s) à onboarder."
CALLER_B64="$(base64 -w0 < "$CALLER_SRC" 2>/dev/null || base64 < "$CALLER_SRC" | tr -d '\n')"

for repo in "${REPOS[@]}"; do
  echo ""
  echo "═══ $repo ═══"

  # 1) Secret.
  if gh secret set CLAUDE_CODE_OAUTH_TOKEN --repo "$repo" --body "$CLAUDE_CODE_OAUTH_TOKEN"; then
    echo "  ✓ secret CLAUDE_CODE_OAUTH_TOKEN posé"
  else
    echo "  ✗ échec du secret — repo ignoré"; continue
  fi

  # 2) Caller workflow (create or update via Contents API).
  branch="$(gh api "repos/$repo" --jq .default_branch)"
  sha="$(gh api "repos/$repo/contents/$CALLER_PATH?ref=$branch" --jq .sha 2>/dev/null || true)"
  args=(-X PUT "repos/$repo/contents/$CALLER_PATH"
        -f message="ci: add Claude PR reviewer caller"
        -f content="$CALLER_B64"
        -f branch="$branch")
  [ -n "$sha" ] && args+=(-f sha="$sha")
  if gh api "${args[@]}" >/dev/null; then
    echo "  ✓ caller commité sur $branch"
  else
    echo "  ✗ échec du commit du caller (scope workflow ?)"
  fi
done

echo ""
echo "✅ Terminé. Ouvre une PR de test pour vérifier (cf. README §Vérification)."
