# projetV0-pipelines

Workflows GitHub Actions réutilisables pour les SaaS du studio.

## Gate SaaS et indépendance des contrôles

Le check agrégé `CI / gate` s'exécute même après un échec ou un job sauté. Sécurité source et qualité doivent réussir. Pour `run-a11y` et `run-container`, une option activée exige `success` ; une option désactivée exige `skipped`. Un échec, une annulation ou un contrôle activé mais sauté garde le gate rouge. Le caller doit rendre le nom complet de ce check obligatoire sur sa branche principale ; le workflow seul ne protège pas une branche.

La version CI qualifiée `v1.5.0` pointe vers `5b464b9b2d47bc867d3c046c924244c3f9c2d609`. Son arbre fusionné est identique au candidat examiné et qualifié dans `projetv0-saas-smoke` : échec Fallow avec scan d'image réussi et gate rouge, options explicitement désactivées acceptées, puis run final entièrement vert. `examples/saas-ci.yml` utilise ce SHA immuable. Le pin du template attendu par le générateur est coordonné séparément après sa fusion ; il ne faut pas exécuter une ancienne copie du générateur contre un nouveau `main` du template.

La construction et le scan Trivy de l'image dépendent uniquement de la sécurité source. Un échec de lint, de tests, de couverture ou de Fallow ne les empêche donc plus de démarrer. Une image ne peut être scannée que si sa construction réussit. Les qualifications natives supplémentaires restent dans chaque produit ; le workflow générique conserve une seule exécution de son script de test.

Les contrats locaux exécutent le vrai script du gate sur les résultats activés, désactivés, échoués et sautés, et vérifient ses dépendances. Avant de propager une nouvelle révision ou politique aux templates, qualifier le commit exact dans `projetv0-saas-smoke` : complexité advisory visible avec gate vert, erreur structurelle Fallow avec produit vert mais audit/gate rouges et scan d'image réussi, cas mixte rouge, puis état final sans canaries entièrement vert. Les tests locaux ne remplacent pas cette preuve GitHub Actions. Un changement de sévérité propre aux consommateurs ne nécessite pas de déplacer le tag CI immuable ; un changement du workflow demande une nouvelle version.

## Qualité SaaS et couverture mesurée

Le job qualité installe les dépendances verrouillées, lint, construit la production puis exécute une seule fois `pnpm run test`, avant Fallow, React Doctor et le typecheck. Chaque caller conserve son script de test et ses prérequis spécifiques ; ce workflow n'installe ni provider de couverture ni décodeur audio pour les autres dépôts.

La couverture est opt-in via un chemin non null dans `health.coverage` de la `.fallowrc.json` du caller. Le test doit alors produire un JSON Istanbul non vide dans ce même checkout. Le contrôle refuse une carte manquante, malformée, périmée, liée ou extérieure, des chemins source non canoniques ou différents du checkout courant, ainsi que des positions/maps/counters incohérents. Les counters zéro sont valides : une fonction réellement non couverte ne devient pas couverte. Sans ce champ ou avec son défaut natif `null`, le script de test existant est conservé sans provider imposé ; toute autre valeur malformée est refusée.

Les clés source et leur champ `path` doivent être identiques et absolument canoniques pour la plateforme courante. Sur Windows, la forme native et sa forme exacte avec `/`, produite par Istanbul, désignent la même identité source ; les mélanges de séparateurs, segments relatifs et doublons entre ces deux formes restent refusés. Le contrôle ne réécrit pas la carte.

Le format natif `ast-v8-to-istanbul` peut sérialiser une colonne de fin Infinity en `null` : elle représente uniquement la fin de cette ligne source valide ; la colonne de début reste entière et bornée. Une alternative else implicite peut avoir exactement `{start:{},end:{}}`, seulement en seconde position des deux alternatives d'une branche `if` dont le range principal et la première alternative sont valides, avec deux counters entiers non négatifs. Ces deux formes ne réécrivent ni la carte ni ses counters ; les autres positions null/manquantes et ranges vides restent refusés.

Ce contrôle de carte ne garantit pas que toutes les fonctions sont mesurées. Les callbacks de tests, sous-processus et SSR peuvent rester hors de la session de couverture du producer ; leur absence ne doit pas être remplacée par des counters fabriqués. Le caller doit vérifier les correspondances natives avec Fallow. L'audit PR propage les erreurs de son binaire et les règles de niveau `error`, avec le SHA de base exact ; le workflow ne change ni seuil ni sévérité et n'exécute pas une deuxième suite.

Le template historique et son smoke épinglent Fallow `3.31.0` et mettent uniquement `complexity-cyclomatic`, `complexity-cognitive` et `complexity-crap` en `warn`. Les seuils natifs et les erreurs structurelles existantes sont conservés. Les gros hotspots introduits doivent faire l'objet d'une courte disposition dans la PR : correction, conservation justifiée et tests pertinents, ou suivi concret. La visibilité du warning ne constitue pas une approbation humaine ni une preuve de sûreté. Les contrats plus stricts propres à un produit restent à la charge de ce consommateur.

## Nouveau SaaS

```powershell
pwsh -File scripts/new-saas.ps1 invoice-ai
```

Cette commande crée le dépôt privé depuis le template, une application Dokploy et une identité dédiée, applique les protections GitHub, puis attend la première release saine. Le profil standard est volontairement fixe : stateless, `ops01`, `/health`, 512 MiB, 1 CPU, sans domaine public, base, Redis ni stockage.

Le générateur courant attend exactement le template accepté `b7415a7fa72ae0baebf2eced6d21efcc941c0ae8`, dont le caller CI utilise `v1.5.0`. Les refus de dérive du template et des fichiers critiques restent actifs. Cette coordination ne modifie ni le helper installé ni le pin du workflow de release ; les qualifications produit du candidat TanStack/Effect restent distinctes de ce profil historique.

L'installation ou la mise à jour root du helper est une opération de plateforme séparée : `pwsh -File scripts/install-studio-saas.ps1`. Elle ne fait pas partie de la création normale d'un SaaS.

## Release

Le push sur `main` construit une seule image GHCR sans tag, puis scanne son digest immuable dans le workflow partagé. Un job `deploy` local au caller reçoit ensuite ce digest et le déploie via le tailnet Dokploy ; lui seul obtient `id-token: write` et l'environnement `production`.

Configurer `DOKPLOY_URL`, `HEALTH_URL`, `TS_WIF_CLIENT_ID` et `TS_WIF_AUDIENCE` comme variables du dépôt, `DOKPLOY_APPLICATION_ID` comme variable de l'environnement GitHub `production`, et `DOKPLOY_API_KEY` comme secret de ce même environnement. Le secret reste dans le job local `deploy` et n'est jamais transmis au workflow réutilisable.

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
