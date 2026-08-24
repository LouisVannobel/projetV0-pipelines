# projetV0-pipelines

Workflows GitHub Actions réutilisables pour les SaaS du studio.

## Appel depuis un SaaS

Copier `examples/saas-ci.yml` vers `.github/workflows/ci.yml` et `examples/container-release.yml` vers `.github/workflows/release.yml`. Les deux workflows sont épinglés au même commit immuable :

`64e9b80ea12d6f13204a055d662ab002248611dc` (`v1.1.0`)

Le SaaS fournit `package.json`, `pnpm-lock.yaml`, un Dockerfile multi-stage et les scripts pnpm `lint`, `typecheck`, `test`, `build`, `test:a11y` et `lighthouse`. La CI exécute ces contrôles et publie le statut requis `CI / gate`.

## Release

Le push sur `main` construit une seule image GHCR, scanne ce digest immuable, puis déploie ce même digest via le tailnet Dokploy. Le caller accorde `contents: read`, `packages: write` et `id-token: write`.

Configurer les variables du dépôt `DOKPLOY_APPLICATION_ID`, `DOKPLOY_URL`, `HEALTH_URL`, `TS_WIF_CLIENT_ID` et `TS_WIF_AUDIENCE`, ainsi que `DOKPLOY_API_KEY` comme secret de l'environnement `production`. Aucun secret Dokploy n'est transmis par le caller.

L'application Dokploy doit utiliser la source Docker (`sourceType: docker`) et les identifiants de pull du registre GHCR privé doivent être configurés directement dans Dokploy. Utiliser un compte/API Dokploy dédié à cette application, limité à ce service et aux permissions minimales `service:read/create` et `deployment:read/create`. L'environnement GitHub `production` doit être protégé par les règles d'approbation adaptées au studio.

`HEALTH_URL` doit converger sans redirection vers un HTTP 200 exact avec un JSON dont `revision` est le SHA déployé. Le workflow produit une provenance et un SBOM OCI, sans revendiquer de conformité SLSA formelle.

## Appel depuis un dépôt d'infrastructure

Copier `examples/repository-ci.yml` vers `.github/workflows/ci.yml`. Le caller active le contrôle générique du dépôt puis, avec `run-infrastructure-static: true`, la syntaxe Bash, les erreurs ShellCheck, les tests de contrat locaux, les modèles Compose sans secrets et le contrat des locks d'images. Aucun accès SSH, secret de déploiement ou balayage anonyme de registre n'est utilisé.

Le workflow transverse reste épinglé à son interface immuable documentée dans `examples/repository-ci.yml`.
