# claude-pr-reviewer

Un reviewer de PR façon **CodeRabbit / Gemini Code Assist**, propulsé par Claude et **facturé sur
ton abonnement Claude Max** (token OAuth `claude setup-token`) — **zéro call API, zéro credits**.

- 👀 accuse réception à chaque PR, poste une **synthèse sticky** + des **commentaires inline** avec
  sévérités 🔴/🟠/🟡/🟢 et suggestions committables.
- 🧠 **orchestration dynamique du modèle** : Sonnet par défaut, **Opus** sur les PR grosses ou
  touchant des chemins sensibles (auth, paiement, migrations, CI…).
- 🔁 boucle **review → fix → re-vérification** : `@claude fix` corrige et pousse, le push relance une
  review qui marque chaque finding ✅/⚠️/❌.
- 🧱 **logique centrale unique** : chaque repo n'a qu'un caller de ~20 lignes pointant ici. Tu fais
  évoluer le reviewer à un seul endroit.

> Pourquoi pas le produit officiel *Claude Code Review* (GitHub App) ? Il est réservé aux plans
> **Team/Enterprise** et facturé **en credits (~15–25 $/review)**, pas sur l'abonnement. Ce repo
> reproduit l'essentiel via GitHub Actions, sur ton forfait Max.

---

## Architecture

```
Ainoob59/claude-pr-reviewer  (ce repo, PUBLIC — ne contient aucun secret)
├─ .github/workflows/review.reusable.yml   ← toute la logique (triage + review + fix + ask)
├─ prompts/review.md · fix.md · ask.md      ← la "persona" du reviewer
├─ templates/claude-review.yml              ← le caller à déposer dans chaque repo
└─ scripts/onboard.sh                       ← pose secret + caller sur N repos

Chaque repo cible (privé OK)
├─ .github/workflows/claude-review.yml      ← caller de ~20 lignes (uses: …@v1)
└─ secret CLAUDE_CODE_OAUTH_TOKEN           ← ton token d'abonnement
```

Le triage est un **gate déterministe en bash (0 token)** ; il ne réveille Claude que sur le
nécessaire et choisit Sonnet/Opus. Aligné « compiler le stable » : les prompts sont l'artefact
réutilisable, l'évolution se fait au centre (tag `v1`).

---

## Mise en route

### 1. Générer le token d'abonnement (une fois)
```bash
claude setup-token          # connecte ton compte Max → imprime un token cc_oauth_...
export CLAUDE_CODE_OAUTH_TOKEN="cc_oauth_..."
```
> ⚠️ Ne définis **jamais** `ANTHROPIC_API_KEY` dans tes repos/CI : il prendrait le dessus et
> facturerait l'API. Seul `CLAUDE_CODE_OAUTH_TOKEN` doit exister.

### 2. Donner à `gh` le scope workflow (une fois)
```bash
gh auth refresh -h github.com -s workflow
```

### 3. Brancher tes repos
```bash
./scripts/onboard.sh Ainoob59/mon-repo            # un repo
./scripts/onboard.sh Ainoob59/a Ainoob59/b        # plusieurs
./scripts/onboard.sh --all                        # tous tes repos non-fork
```

C'est tout. Ouvre une PR → 👀 puis la review apparaît.

---

## Boucle recommandée : author fixe → Claude vérifie

Le flux par défaut (et le plus sûr) :
1. Claude **review** la PR (findings + sévérités).
2. **Toi** (ou ton Claude Code local, qui a tout le contexte) corriges — en acceptant ou en
   **rejetant** les findings. Un finding « global » peut être un faux positif : tu décides.
3. Tu **push** → Claude **re-review** et réconcilie chaque finding : ✅ corrigé · ⚠️ partiel ·
   ❌ présent · 🆕 régression · 💬 rejeté par l'auteur (clos par discussion, plus re-râlé).

> Pourquoi pas tout déléguer à `@claude fix` ? Le fixer a le contexte du *code* mais pas ton
> *intention* ni le design global ; auto-corriger un faux positif modifie du code correct. `@claude fix`
> reste donc une **option** pour les corrections **mécaniques évidentes** (clé en dur, requête à
> paramétrer…), pas le défaut. Il commite sur la PR — jamais de merge auto, tu relis.

## Commandes dans une PR

| Action | Effet |
|---|---|
| *(ouvrir une PR / pousser un commit)* | Review / re-review auto (sauf PR triviale : docs-only / < 25 lignes). |
| Label **`claude-assist`** | Force une **review profonde Opus** (ignore le skip). |
| `@claude review` | Re-review à la demande (Opus). |
| `@claude <question>` | Q&A sur la PR (read-only). |
| `@claude fix` *(option)* | Corrections **mécaniques** uniquement ; commite sur la branche PR → re-review auto. À réserver aux findings évidents. |

### Régler le comportement par repo
- `CLAUDE.md` à la racine : conventions du projet (respectées nativement).
- `REVIEW.md` (optionnel) : instructions review-only (seuils de sévérité, chemins à ignorer,
  checks obligatoires). Le prompt les traite comme prioritaires.

---

## Orchestration du modèle (triage à 2 étages)

**L0 — bash (gratuit, ~5s)** : filtre grossier sur taille + chemins.
- Docs-only ou < 25 lignes (review auto) → **skip** (économie quota).
- `claude-assist` / `@claude review` / `@claude fix` → **Opus** forcé.

**L1 — Haiku (≈ gratuit, sur le contenu)** : pour les reviews auto non-triviales, Haiku lit le **vrai
diff** et tranche `OPUS` / `SONNET` / `SKIP` selon le contenu (argent, auth, sécurité, migrations,
concurrence…), pas seulement les noms de fichiers. Best-effort : si Haiku échoue, on retombe sur
l'heuristique bash ci-dessous, la review tourne quand même.

| Situation (fallback bash si Haiku indispo) | Modèle |
|---|---|
| PR normale | `claude-sonnet-4-6` |
| Diff > ~600 lignes **ou** > 12 fichiers **ou** chemin sensible | `claude-opus-4-8` |
| `claude-assist` / `@claude review` / `@claude fix` | `claude-opus-4-8` |

Seuils + prompt Haiku ajustables dans `.github/workflows/review.reusable.yml` (job `triage`).

---

## Maintenance

- **Faire évoluer le reviewer** : édite `prompts/*.md` ou le workflow ici, commit, puis **déplace le
  tag `v1`** :
  ```bash
  git commit -am "review: ..." && git tag -f v1 && git push -f origin v1
  ```
  Tous les repos (qui pointent `@v1`) en profitent au prochain run. Aucun repo à retoucher.
- **Roter le token** (~1 an) : `claude setup-token` puis `./scripts/onboard.sh --all` (re-pose le
  secret partout).

---

## Sécurité

- Déclenché sur `pull_request` (pas `pull_request_target`) : les PR de **fork** n'ont pas accès au
  secret → la review ne tourne pas pour des contributeurs externes (OK pour repos perso).
- Permissions minimales : review/ask en `contents: read` ; seul le mode **fix** a `contents: write`.
- Le corps des commentaires est passé en variable d'env (pas d'injection de script dans le triage).
- Le repo central est **public mais ne contient aucun secret** (juste des prompts) ; tes repos
  reviewés restent privés, leur secret vit chez eux.
