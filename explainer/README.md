# Module 3 — Couche d'explication (LLM)

Transforme le rapport JSON du module 2 en explication en langage naturel,
comprehensible sans connaitre CloudWatch ni ECS.

Le LLM **explique une analyse deja calculee**. Il ne decide rien, ne recalcule
rien, et n'a aucun acces a l'infrastructure : les chiffres lui sont fournis, il
les met en mots.

## Deux commandes, volontairement separees

| Commande | Effet | Garde-fou |
|---|---|---|
| `explain` | Appelle le LLM, affiche l'explication | Lecture seule, n'ecrit jamais |
| `apply` | Modifie `DesiredCount` du service ECS | Exige `--apply` **et** une confirmation tapee au clavier |

Il n'existe **aucun chemin de code** qui enchaine analyse -> explication ->
application. `apply` prend un rapport en entree et redemande toujours l'accord
humain, dans la meme logique que le `ManualApproval` deja present dans le
pipeline CodePipeline.

### Ce que `apply` refuse, avant meme de poser la question

- un rapport base sur des metriques d'exemple (`--sample`) ;
- une recommandation vide (`action: none`) ;
- une cible identique a la configuration actuelle ;
- une cible a zero tache.

### Ce que `apply` affiche avant de demander l'accord

Service, cluster, changement exact, economie estimee, confiance, base de calcul,
et — si la cible tombe a une seule tache — un avertissement explicite sur la
perte de redondance multi-AZ.

Seules les reponses `o`, `oui`, `y`, `yes` valent accord. Toute autre saisie,
une ligne vide, un `Ctrl+C` ou une fin de flux valent **refus**.

## Lancer en local

### Prerequis

```powershell
pip install anthropic
$env:ANTHROPIC_API_KEY = "sk-ant-..."
```

### Voir le prompt sans appeler l'API (gratuit, sans cle)

```powershell
python -m explainer explain --sample --print-prompt
```

### Expliquer un rapport

```powershell
# Depuis les donnees d'exemple
python -m explainer explain --sample

# Depuis un rapport du module 2
python -m optimizer analyze --profile AdministratorAccess-136609826386 --output rapport.json
python -m explainer explain --report rapport.json

# En chainant par un tube
python -m optimizer analyze --sample --json | python -m explainer explain --report -
```

### Appliquer (apres validation humaine)

```powershell
python -m explainer apply --report rapport.json --apply --profile AdministratorAccess-136609826386
```

Sans `--apply`, la commande s'arrete immediatement sans rien ecrire.

## Options

| Option | Defaut | Role |
|---|---|---|
| `--report` | — | Rapport JSON du module 2 (`-` pour stdin) |
| `--sample` | — | Utilise le rapport d'exemple |
| `--model` | `claude-opus-5` | Modele Anthropic (ou `ANTHROPIC_MODEL`) |
| `--max-tokens` | `2000` | L'explication vise ~300 mots |
| `--raw-json` | — | Joint aussi le JSON brut au prompt |
| `--print-prompt` | — | Affiche le prompt sans appeler l'API |
| `--json` | — | Sortie machine (utilisee par le dashboard) |

## Variables d'environnement

| Variable | Role |
|---|---|
| `ANTHROPIC_API_KEY` | Obligatoire pour `explain` |
| `ANTHROPIC_MODEL` | Modele par defaut (surchargeable par `--model`) |
| `AWS_PROFILE` / `--profile` | Utilise par `apply` uniquement |

## Ce que le prompt impose au modele

Le prompt systeme ([`prompt.py`](prompt.py)) fixe des contraintes explicites :
expliquer sans decider, n'inventer aucun chiffre, signaler les metriques
d'exemple des la premiere phrase, rappeler qu'un humain tranche, et expliquer
que la regle maison et Compute Optimizer ne regardent pas le meme levier.

La reponse est structuree en quatre parties : ce qui a ete observe, pourquoi
cette proposition, ce que ca changerait, ce qu'il faut garder en tete.

## Tests

```powershell
python -m pytest explainer/ -v
```

12 tests hors ligne, centres sur le garde-fou humain : un refus n'appelle jamais
AWS, toute reponse ambigue vaut refus, une interruption vaut refus, les donnees
d'exemple ne peuvent pas etre appliquees, le recapitulatif est bien affiche
*avant* la question, et le prompt contient les chiffres reels du rapport.

## Fichiers

| Fichier | Role |
|---|---|
| [`prompt.py`](prompt.py) | Prompt systeme et mise en forme du rapport |
| [`client.py`](client.py) | Appel de l'API Anthropic |
| [`apply.py`](apply.py) | Garde-fou humain et appel `update_service` |
| [`cli.py`](cli.py) | Commandes `explain` et `apply` |
