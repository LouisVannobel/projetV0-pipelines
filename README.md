# projetV0-pipelines

Workflows GitHub Actions réutilisables pour les dépôts du studio. Le dépôt sépare strictement la CI de pull request, en lecture seule, de la publication d'images OCI.

## Appel depuis un SaaS

Copier `examples/saas-ci.yml` vers `.github/workflows/ci.yml` dans le SaaS. Le workflow est épinglé au commit immuable :

`a9b2e878d829f1390d40ff7302993637ac74364d`

Le SaaS doit fournir les scripts pnpm `lint`, `typecheck`, `test`, `build`, `test:a11y` et `lighthouse`, un `pnpm-lock.yaml` commité et un Dockerfile multi-stage.

## Contrôles communs

- installation `pnpm --frozen-lockfile` ;
- lint, typecheck, tests et build ;
- Playwright/axe-core et Lighthouse ;
- Gitleaks téléchargé avec checksum vérifié ;
- Trivy sur le dépôt et l'image ;
- image de release avec SBOM et provenance ;
- actions tierces épinglées à leur SHA Git complet ;
- Renovate configuré sans automerge.

La publication d'image nécessite un workflow séparé, déclenché uniquement par une release protégée, utilisant `examples/container-release.yml`.

## Appel depuis un dépôt d'infrastructure

Copier `examples/repository-ci.yml` vers `.github/workflows/ci.yml`. Ce caller déclenche uniquement actionlint, une analyse Gitleaks de tout l'historique Git et l'analyse Trivy du dépôt ; il ne suppose ni Node.js, ni pnpm, ni Dockerfile.

Le workflow transverse est épinglé au commit immuable :

`148874d14d9263eba399e0d9d883fab3c2610336`
