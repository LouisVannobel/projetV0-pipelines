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
- Checkout v7.0.1, Trivy CLI v0.74.0 et Buildx v0.36.1 explicitement épinglés ;
- Renovate configuré sans automerge et avec un délai de maturation de sept jours.

La publication d'image nécessite un workflow séparé, déclenché uniquement par une release protégée, utilisant `examples/container-release.yml`.

## Appel depuis un dépôt d'infrastructure

Copier `examples/repository-ci.yml` vers `.github/workflows/ci.yml`. Le caller active le contrôle générique du dépôt puis, avec `run-infrastructure-static: true`, la syntaxe Bash, ShellCheck, les tests de contrat locaux, les modèles Compose sans secrets et la cohérence tag/digest/architecture des images. Aucun accès SSH ou secret de déploiement n'est utilisé.

Le workflow transverse est épinglé au commit immuable :

`3b3d131bfda6078c38fd2bec0c1acd58f55b8726`

## Maintenance Renovate

Renovate met à jour les actions épinglées par SHA grâce au commentaire de version placé après chaque pin. Il sait aussi suivre nativement les valeurs `with.version` de Trivy, Buildx et `pnpm/action-setup`. Des extracteurs explicites couvrent les binaires téléchargés dans les scripts de workflow et la version pnpm par défaut.

Les mises à jour ne sont jamais fusionnées automatiquement. Pour actionlint, Gitleaks et ShellCheck, Renovate ouvre la PR de version mais la somme SHA-256 doit être recalculée et revue humainement ; le pipeline reste rouge si le binaire et son checksum ne correspondent pas. Le bot ne fait rien tant que l'application Renovate n'est pas autorisée sur ce dépôt.
