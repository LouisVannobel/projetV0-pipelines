# projetV0-pipelines

Workflows GitHub Actions réutilisables pour les SaaS du studio.

## Appel depuis un SaaS

Copier `examples/saas-ci.yml` vers `.github/workflows/ci.yml` et `examples/container-release.yml` vers `.github/workflows/release.yml`. Les deux workflows sont épinglés au même commit immuable :

`bc5084f80c4aef7a1d1393fc3f5617fc46a6fb6d` (`v1.3.0`)

Le SaaS fournit `package.json`, `pnpm-lock.yaml`, un Dockerfile multi-stage et les scripts pnpm `lint`, `typecheck`, `test`, `build` et `test:a11y`. Lighthouse reste opt-in. La CI publie le statut requis `CI / gate`.

## Release

Le push sur `main` construit une seule image candidate GHCR au nom unique et scanne son digest immuable dans le workflow partagé. Un job `deploy` local au caller reçoit ensuite ce digest et le déploie via le tailnet Dokploy ; lui seul obtient `id-token: write` et l'environnement `production`.

Configurer les variables du dépôt `DOKPLOY_APPLICATION_ID`, `DOKPLOY_URL`, `HEALTH_URL`, `TS_WIF_CLIENT_ID` et `TS_WIF_AUDIENCE`, ainsi que `DOKPLOY_API_KEY` comme secret de l'environnement `production`. Le secret reste dans le job local `deploy` et n'est jamais transmis au workflow réutilisable.

L'application Dokploy doit utiliser la source Docker (`sourceType: docker`) et déjà pointer vers le même repository GHCR que le caller. Les identifiants de pull privés sont configurés dans Dokploy. Utiliser une identité CI non personnelle, révocable et limitée au projet, à l'environnement et aux services SaaS. L'environnement GitHub `production` n'accepte que les branches protégées.

`HEALTH_URL` doit converger sans redirection vers un HTTP 200 exact avec un JSON dont `revision` est le SHA déployé. Le service Swarm utilise `FailureAction=rollback`, `Order=start-first` et `Parallelism=1`. En cas d'échec, le helper redéploie aussi l'image précédente. Le workflow produit une provenance et un SBOM OCI, sans revendiquer de conformité SLSA formelle.

## Appel depuis un dépôt d'infrastructure

Copier `examples/repository-ci.yml` vers `.github/workflows/ci.yml`. Le caller active le contrôle générique du dépôt puis, avec `run-infrastructure-static: true`, la syntaxe Bash, les erreurs ShellCheck, les tests de contrat locaux, les modèles Compose sans secrets et le contrat des locks d'images. Aucun accès SSH, secret de déploiement ou balayage anonyme de registre n'est utilisé.

Le workflow transverse reste épinglé à son interface immuable documentée dans `examples/repository-ci.yml`.

## Release OCI transverse pour Voice

Le contrat Voice est séparé du chemin SaaS/Dokploy existant. `reusable-oci-release.yml` construit une seule fois une image `linux/amd64`, scanne son digest racine, vérifie ses attestations puis promeut ce même digest. Il ne publie pas `latest` et ne déploie rien.

Copier `examples/oci-release.yml` dans le dépôt appelant. L'exemple est épinglé à la révision immuable sérialisée `97cf6d2c5348f202c232fd872c4d4592d430297b`; le commentaire `v1.2.0` réserve le futur repère lisible. Le tag `v1.2.0` ne doit être créé qu'après un smoke GHCR réussi, une CI de PR verte, la revue finale et le merge. Tous les tags publiés sont immuables et ne doivent jamais être déplacés, notamment les tags actuels `v1.1.0`, `v1.1.1` et `v1.1.2`.

Le workflow expose `image-digest`, `image-reference` et `sbom-artifact`. Le déploiement consomme exclusivement `image-reference` (`image@sha256:...`). Les tags de version et de révision peuvent être résolus pour fournir une preuve, mais ne sont jamais une entrée de déploiement.

La promotion sérialise les écritures de tags dans le dépôt appelant avec le groupe réservé `projetv0-oci-promotion`, sans annuler les exécutions en cours et avec la file maximale GitHub (jusqu'à 100 exécutions en attente). Les callers ne doivent pas réutiliser ce groupe pour leurs propres jobs : il est réservé aux jobs `promote` de ce workflow. Les versions `latest` et toute forme exacte `sha-` suivie de 40 caractères hexadécimaux, sans distinction de casse, sont réservées. Avant l'écriture, chacune des destinations de version et de révision doit être absente ou déjà pointer vers le digest vérifié ; après l'écriture, les deux doivent pointer vers ce digest.

Une image doit avoir un seul dépôt appelant faisant autorité, et chacun de ses writers doit utiliser cette révision sérialisée : pas d'ancien pin ni d'écriture directe de tag en parallèle. Plusieurs dépôts écrivant la même image, ou tout writer non sérialisé, ne sont pas supportés sauf si le registre garantit lui-même des tags immuables ou une opération conditionnelle de type compare-and-swap. La concurrence GitHub Actions étant limitée à un dépôt, elle ne protège pas ces écritures externes.
