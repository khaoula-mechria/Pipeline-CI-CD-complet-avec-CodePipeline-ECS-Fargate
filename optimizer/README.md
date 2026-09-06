# Module 2 — Optimization Engine (rightsizing comparatif)

Analyse le service ECS `taskmanager-dev-service` apres deploiement, produit une
recommandation de rightsizing maison, et la met en regard de celle d'AWS Compute
Optimizer.

Le module est **en lecture seule** : il ne modifie jamais l'infrastructure.
L'application eventuelle passe par le module 3 (`--apply` + confirmation humaine).

## Les deux avis ne portent pas sur le meme levier

C'est le point a garder en tete en lisant le tableau :

| | Regle maison | AWS Compute Optimizer |
|---|---|---|
| Levier | **nombre de taches** (`DesiredCount`) | **taille de tache** (CPU/memoire) |
| Entree | moyenne CPU/memoire sur la fenetre | historique long + pics, modele AWS |
| Borne basse | `MinCapacity` de `ecs-autoscaling.yaml` | tailles Fargate valides |

Un ecart entre les deux n'est donc pas forcement un desaccord, et les economies
ne s'additionnent pas mecaniquement. Le tableau affiche explicitement la ligne
« Levier » pour eviter cette lecture.

## La regle maison

Explicite, sans ML, entierement pilotee par des seuils :

1. Si la fenetre contient moins de `--min-datapoints` points (defaut 12), la
   regle **refuse de se prononcer** (`finding: Unknown`).
2. Sinon, on prend le maximum de (CPU moyen, memoire moyenne) comme facteur
   dimensionnant.
3. S'il est **au-dessus** de `--low-utilization` (defaut 40 %) : `Optimized`,
   aucune action.
4. S'il est **en dessous**, on cherche le plus petit nombre de taches tel que
   l'utilisation projetee reste sous `--safety-ceiling` (defaut 70 %), sans
   descendre sous `--min-capacity`.
   L'utilisation projetee suppose une charge totale constante :
   `util_projetee = util_actuelle x (taches_actuelles / taches_cible)`.
5. La confiance (`low`/`medium`/`high`) depend de la longueur de la fenetre et
   de la marge restante sous le plafond.

Le cout est estime a partir de la taille de tache reellement declaree
(256 CPU / 512 Mo sur ce projet) et du tarif Fargate a la demande de la region
(`FARGATE_PRICING` dans [`rules.py`](rules.py) — tarif public liste, a reajuster
si la grille AWS change).

## Lancer en local

### Demo hors ligne (aucun appel AWS)

```powershell
python -m optimizer analyze --sample
```

Les metriques viennent de [`sample_metrics.json`](sample_metrics.json) et sont
etiquetees `source=sample` partout dans la sortie : elles ne peuvent pas etre
confondues avec des mesures reelles.

### Sur l'infrastructure reelle

```powershell
aws sso login --profile AdministratorAccess-136609826386

python -m optimizer analyze `
  --profile AdministratorAccess-136609826386 `
  --region eu-west-2 `
  --window-days 14
```

Pour une demo juste apres un deploiement, raccourcir la fenetre et abaisser le
minimum de datapoints :

```powershell
python -m optimizer analyze --window-days 1 --min-datapoints 3 --profile ...
```

### Sortie JSON (entree du module 3)

```powershell
python -m optimizer analyze --sample --json
python -m optimizer analyze --sample --output rapport.json
```

## Options

| Option | Defaut | Role |
|---|---|---|
| `--window-days` | `14` | Fenetre CloudWatch observee |
| `--low-utilization` | `40` | Seuil (%) sous lequel on juge sur-provisionne |
| `--safety-ceiling` | `70` | Plafond (%) d'utilisation projetee apres reduction |
| `--min-capacity` | `1` | Plancher de taches (`MinCapacity` de l'autoscaling) |
| `--min-datapoints` | `12` | En dessous, la regle ne se prononce pas |
| `--sample` | — | Metriques d'exemple, aucun appel AWS |
| `--json` / `--output` | — | Rapport machine pour le module 3 |

## Variables d'environnement AWS

Aucune variable specifique. Le module utilise la chaine de credentials boto3
standard : `--profile` (recommande ici) ou `AWS_PROFILE` / `AWS_REGION`.

Si la session SSO est expiree ou l'infrastructure detruite, la CLI le signale en
clair dans le champ « Motif » plutot que de remonter une trace d'exception.

## Tests

```powershell
python -m pytest optimizer/ -v
```

12 tests hors ligne : declenchement et non-declenchement de la regle, plafond de
securite, plancher de capacite, fenetre non representative, calcul de cout
Fargate, etiquetage des donnees d'exemple, et signalement du risque de perte de
redondance multi-AZ quand la cible tombe a une seule tache.

## Fichiers

| Fichier | Role |
|---|---|
| [`metrics.py`](metrics.py) | Metriques CloudWatch + description du service ECS |
| [`rules.py`](rules.py) | Regle de rightsizing et estimation de cout |
| [`compare.py`](compare.py) | Appel Compute Optimizer et tableau comparatif |
| [`cli.py`](cli.py) | Commande `analyze` |
| [`sample_metrics.json`](sample_metrics.json) | Jeu d'exemple pour la demo hors ligne |
