# projetV0-pipelines

Workflows GitHub Actions réutilisables pour les dépôts du studio. Le dépôt sépare strictement la CI de pull request, en lecture seule, de la publication d'images OCI.

## Appel depuis un SaaS

Copier `examples/saas-ci.yml` vers `.github/workflows/ci.yml` dans le SaaS. Le workflow est épinglé au commit immuable :

`399df8dcb93a28734269ad11b63e847896684487` (`v1.0.0`)

Le SaaS doit fournir les scripts pnpm `lint`, `typecheck`, `test`, `build`, `test:a11y` et `lighthouse`, un `pnpm-lock.yaml` commité et un Dockerfile multi-stage.

## Contrôles communs

- installation `pnpm --frozen-lockfile` ;
- lint, typecheck, tests et build ;
- Playwright/axe-core et Lighthouse ;
- Gitleaks téléchargé avec checksum vérifié ;
- Trivy sur le dépôt et l'image ;
- image de release avec SBOM et provenance ;
- actions tierces épinglées à leur SHA Git complet ;
- Checkout v7.0.1, Trivy CLI v0.74.0, Buildx v0.36.1 et son daemon BuildKit v0.32.2 explicitement épinglés.

La publication d'image nécessite un workflow séparé, déclenché uniquement par une release protégée, utilisant `examples/container-release.yml`.

## Appel depuis un dépôt d'infrastructure

Copier `examples/repository-ci.yml` vers `.github/workflows/ci.yml`. Le caller active le contrôle générique du dépôt puis, avec `run-infrastructure-static: true`, la syntaxe Bash, les erreurs ShellCheck, les tests de contrat locaux, les modèles Compose sans secrets et le contrat des locks d'images. Aucun accès SSH, secret de déploiement ou balayage anonyme de registre n'est utilisé.

Le workflow transverse est épinglé au commit immuable :

`399df8dcb93a28734269ad11b63e847896684487` (`v1.0.0`)
