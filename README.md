# projetV0-pipelines

Workflows GitHub Actions réutilisables pour les SaaS du studio.

## Appel depuis un SaaS

Copier `examples/saas-ci.yml` vers `.github/workflows/ci.yml` et `examples/container-release.yml` vers `.github/workflows/release.yml`. Les deux workflows sont épinglés au même commit immuable :

`8339f7f8349d4e9824ffe95a3941cd9b691c6135` (`v1.1.1`)

Le SaaS fournit `package.json`, `pnpm-lock.yaml`, un Dockerfile multi-stage et les scripts pnpm `lint`, `typecheck`, `test`, `build`, `test:a11y` et `lighthouse`. La CI exécute ces contrôles et publie le statut requis `CI / gate`.

## Release

Le push sur `main` construit une seule image GHCR, scanne ce digest immuable, puis déploie ce même digest via le tailnet Dokploy. Le caller accorde `contents: read`, `packages: write` et `id-token: write`.

Configurer les variables du dépôt `DOKPLOY_APPLICATION_ID`, `DOKPLOY_URL`, `HEALTH_URL`, `TS_WIF_CLIENT_ID` et `TS_WIF_AUDIENCE`, ainsi que `DOKPLOY_API_KEY` comme secret de l'environnement `production`. Aucun secret Dokploy n'est transmis par le caller.

L'application Dokploy doit utiliser la source Docker (`sourceType: docker`) et les identifiants de pull du registre GHCR privé doivent être configurés directement dans Dokploy. Utiliser un compte/API Dokploy dédié à cette application, limité à ce service et aux permissions minimales `service:read/create` et `deployment:read/create`. L'environnement GitHub `production` doit être protégé par les règles d'approbation adaptées au studio.

`HEALTH_URL` doit converger sans redirection vers un HTTP 200 exact avec un JSON dont `revision` est le SHA déployé. Le workflow produit une provenance et un SBOM OCI, sans revendiquer de conformité SLSA formelle.

## Appel depuis un dépôt d'infrastructure

Copier `examples/repository-ci.yml` vers `.github/workflows/ci.yml`. Le caller active le contrôle générique du dépôt puis, avec `run-infrastructure-static: true`, la syntaxe Bash, les erreurs ShellCheck, les tests de contrat locaux, les modèles Compose sans secrets et le contrat des locks d'images. Aucun accès SSH, secret de déploiement ou balayage anonyme de registre n'est utilisé.

Le workflow transverse reste épinglé à son interface immuable documentée dans `examples/repository-ci.yml`.

## Release OCI transverse pour Voice

Le contrat Voice est séparé du chemin SaaS/Dokploy existant. `reusable-oci-release.yml` construit une seule fois une image `linux/amd64`, scanne son digest racine, vérifie ses attestations puis promeut ce même digest. Il ne publie pas `latest` et ne déploie rien.

Copier `examples/oci-release.yml` dans le dépôt appelant. L'exemple est épinglé à la révision immuable lintée `eff9cfbb1c66ed36a386f475d493ccf9daaed3c8`; le commentaire `v1.2.0` réserve le futur repère lisible. Le smoke GHCR, la CI finale du PR, la revue finale, le merge et la création du tag restent en attente. Le tag SaaS/Dokploy `v1.1.0` reste inchangé et ne doit jamais être déplacé.

Le workflow expose `image-digest`, `image-reference` et `sbom-artifact`. Le déploiement consomme exclusivement `image-reference` (`image@sha256:...`). Les tags de version et de révision peuvent être résolus pour fournir une preuve, mais ne sont jamais une entrée de déploiement.
