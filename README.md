# Studio Pipelines

Workflows GitHub Actions réutilisables pour les SaaS du studio. Le dépôt sépare strictement la CI de pull request, en lecture seule, de la publication d'images OCI.

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
