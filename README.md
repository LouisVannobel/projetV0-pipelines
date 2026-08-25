# projetV0-pipelines

Workflows GitHub Actions réutilisables pour les SaaS du studio.

## Appel depuis un SaaS

Copier `examples/saas-ci.yml` vers `.github/workflows/ci.yml` et `examples/container-release.yml` vers `.github/workflows/release.yml`. Les deux workflows sont épinglés au même commit immuable :

`aab6ec7c6201881691e38bcfb13de99514bd6fb7` (`v1.1.2`)

Le SaaS fournit `package.json`, `pnpm-lock.yaml`, un Dockerfile multi-stage et les scripts pnpm `lint`, `typecheck`, `test`, `build` et `test:a11y`. Lighthouse reste opt-in. La CI publie le statut requis `CI / gate`.

## Release

Le push sur `main` construit une seule image candidate GHCR au nom unique, scanne son digest immuable, puis déploie uniquement ce digest via le tailnet Dokploy. Le caller accorde `contents: read`, `packages: write` et `id-token: write`.

Configurer les variables du dépôt `DOKPLOY_APPLICATION_ID`, `DOKPLOY_URL`, `HEALTH_URL`, `TS_WIF_CLIENT_ID` et `TS_WIF_AUDIENCE`, ainsi que `DOKPLOY_API_KEY` comme secret de l'environnement `production`. Aucun secret Dokploy n'est transmis par le caller.

L'application Dokploy doit utiliser la source Docker (`sourceType: docker`) et déjà pointer vers le même repository GHCR que le caller. Les identifiants de pull privés sont configurés dans Dokploy. Utiliser une identité CI non personnelle, révocable et limitée au projet, à l'environnement et aux services SaaS. L'environnement GitHub `production` n'accepte que les branches protégées.

`HEALTH_URL` doit converger sans redirection vers un HTTP 200 exact avec un JSON dont `revision` est le SHA déployé. Le service Swarm utilise `FailureAction=rollback`, `Order=start-first` et `Parallelism=1`. En cas d'échec, le helper redéploie aussi l'image précédente. Le workflow produit une provenance et un SBOM OCI, sans revendiquer de conformité SLSA formelle.

## Appel depuis un dépôt d'infrastructure

Copier `examples/repository-ci.yml` vers `.github/workflows/ci.yml`. Le caller active le contrôle générique du dépôt puis, avec `run-infrastructure-static: true`, la syntaxe Bash, les erreurs ShellCheck, les tests de contrat locaux, les modèles Compose sans secrets et le contrat des locks d'images. Aucun accès SSH, secret de déploiement ou balayage anonyme de registre n'est utilisé.

Le workflow transverse reste épinglé à son interface immuable documentée dans `examples/repository-ci.yml`.
