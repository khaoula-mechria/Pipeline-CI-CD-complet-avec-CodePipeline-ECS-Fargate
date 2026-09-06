# Module 4 — Dashboard Streamlit

Tableau de bord local qui montre le deploiement en direct, puis enchaine sur
l'optimisation et l'explication dans la meme interface.

Pas d'authentification, pas de base de donnees, pas de multi-utilisateur : il
tourne en local le temps d'une demo, lit l'etat AWS en direct via boto3, et ne
persiste rien.

## Lancer

```powershell
pip install streamlit
aws sso login --profile AdministratorAccess-136609826386   # si lecture AWS en direct

streamlit run dashboard/app.py
```

L'application s'ouvre sur `http://localhost:8501`. La barre laterale permet de
changer ProjectName, Environment, region et profil AWS sans relancer.

### Demo sans AWS

Tout est visitable sans credentials :

- **Deploiement** : lancer `python -m orchestrator deploy --dry-run` dans un
  autre terminal, puis choisir « Fichier d'orchestrateur » comme source d'etat.
- **Optimisation** : cocher « Utiliser les metriques d'exemple ».
- **Explication** : necessite `ANTHROPIC_API_KEY` (seule partie qui appelle un
  service externe).

Si AWS est injoignable, l'onglet Deploiement le signale et bascule
automatiquement sur le fichier d'orchestrateur.

## Onglet 1 — Deploiement

Le graphe affiche **exactement l'objet networkx du module 1**
(`orchestrator.dependency_graph.build_graph`) : aucune structure parallele n'est
reconstruite, le dashboard ne fait que le peindre.

Couleurs des noeuds :

| Couleur | Etat |
|---|---|
| gris | en attente |
| orange (contour epais) | creation en cours |
| vert | termine |
| rouge | echec |
| violet | stack deja presente, creation ignoree |

Les aretes portent trois informations :

- **trait plein** : dependance `Fn::ImportValue` ;
- **pointilles** : dependance de cablage parametre — elle n'existe pas dans le
  template, elle vient du passage d'un export en `--parameter-overrides`
  (c'est le cas de `vpc -> alb` et `vpc -> ecs-service`) ;
- **orange** : arete menant a une stack en cours, c'est-a-dire ce qui debloque
  la suite.

En haut : stacks terminees, stacks en cours, chrono parallele en direct, et
temps sequentiel estime avec le gain en pourcentage. Quand tout est vert, le
graphe se fige et un resume final affiche duree totale, nombre de vagues et gain.

Le rafraichissement utilise `st.fragment(run_every=4)` : seul le graphe est
redessine, les autres onglets ne sont pas relances.

## Onglet 2 — Optimisation

Bouton **Analyser** qui declenche le module 2, avec les seuils reglables
directement dans l'interface (fenetre, seuil de sous-utilisation, plafond de
securite, datapoints minimum).

Affiche le tableau comparatif regle maison vs AWS Compute Optimizer, avec la
ligne « Levier » qui rappelle que les deux outils n'agissent pas sur la meme
chose (nombre de taches vs taille de tache).

## Onglet 3 — Explication

Le resultat du module 3 s'affiche dans un `st.chat_message`.

La zone **Appliquer** est separee du reste par un trait, et demande trois
gestes distincts avant que le bouton ne devienne cliquable :

1. le rapport doit etre applicable (pas de donnees d'exemple, une action reelle
   a appliquer) ;
2. une case a cocher de confirmation ;
3. la saisie du mot `APPLIQUER`.

Si la cible tombe a une seule tache, un encart rouge signale la perte de
redondance multi-AZ avant toute validation.

## Tests

```powershell
python -m pytest dashboard/ -v
```

22 tests hors ligne, sans Streamlit ni AWS : classification des statuts
CloudFormation (`ROLLBACK_COMPLETE` se termine par `_COMPLETE` mais reste un
echec), mise en evidence des aretes bloquantes, pointilles sur les aretes de
cablage, echappement des guillemets, et relecture du DOT genere par un vrai
parseur (`pydot`, test ignore s'il n'est pas installe).

## Limite connue

Les etiquettes « Vague N » sont placees dans la bonne colonne, mais leur
position verticale est laissee a graphviz : elles peuvent flotter plus haut ou
plus bas que la colonne qu'elles nomment. Cosmetique uniquement, la lecture des
vagues reste donnee par l'alignement en colonnes.

## Fichiers

| Fichier | Role |
|---|---|
| [`app.py`](app.py) | Point d'entree, les 3 onglets |
| [`graph_view.py`](graph_view.py) | Generation du DOT colore |
| [`live_state.py`](live_state.py) | Lecture de l'etat (AWS ou fichier) et chronos |
