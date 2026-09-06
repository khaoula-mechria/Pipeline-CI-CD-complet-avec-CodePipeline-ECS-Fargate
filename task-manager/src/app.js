// ==============================================================================
// Application "task manager" (Express) — application UNIQUE du projet.
//
// C'est la seule application du dépôt : elle est buildée par
// task-manager/Dockerfile, testée par task-manager/buildspec.yml et par
// .github/workflows/ci.yml, et déployée sur ECS Fargate. L'ancienne version
// Flask (src/app.py + templates/index.html) a été portée ici puis supprimée
// pour éliminer la divergence entre ce que la CI validait et ce qui était
// réellement déployé (voir CONFORMITE_CDC.md).
// ==============================================================================

const express = require('express');

const tasks = require('./tasks');
const { renderIndex } = require('./views');

// La règle d'audit CSRF de Semgrep (express-check-csurf-middleware-usage)
// s'ancre TOUJOURS sur cette ligne d'initialisation express(), jamais sur les
// routes individuelles — d'où la suppression ici et pas plus bas. Cette
// application n'a ni session ni cookie d'authentification sur lequel une
// requête forgée depuis un autre site pourrait s'appuyer : la protection CSRF
// ne s'applique donc pas (voir les routes POST plus bas, que la règle
// signalerait sinon).
// Le check_id est volontairement "doublé" : c'est l'identifiant réel émis par
// Semgrep, celui qu'un `nosemgrep` doit reprendre à l'identique.
// nosemgrep: javascript.express.security.audit.express-check-csurf-middleware-usage.express-check-csurf-middleware-usage
const app = express();

// express.json pour l'API, express.urlencoded pour les formulaires HTML
// (un <form method="POST"> envoie de l'application/x-www-form-urlencoded).
app.use(express.json());
app.use(express.urlencoded({ extended: false }));

// --------------------------------------------------------------------------
// Sonde de santé. Utilisée par TROIS mécanismes distincts, ne jamais la
// supprimer ni la faire dépendre de l'état applicatif :
//   - le HEALTHCHECK du Dockerfile,
//   - le health check du conteneur ECS (ecs-task-definition.yaml),
//   - les target groups Blue/Green de l'ALB (alb.yaml) — dont dépend le
//     rollback automatique CodeDeploy (F3 du cahier des charges).
// --------------------------------------------------------------------------
app.get('/health', (_request, response) => {
  response.status(200).json({ status: 'ok' });
});

// --------------------------------------------------------------------------
// Interface HTML (portée depuis Flask : liste + ajout/bascule/suppression)
// --------------------------------------------------------------------------
app.get('/', (_request, response) => {
  response.type('html').send(renderIndex(tasks.list()));
});

app.post('/add', (request, response) => {
  tasks.add({
    title: request.body.title,
    description: request.body.description,
    priority: request.body.priority,
  });

  response.redirect('/');
});

app.post('/toggle/:id', (request, response) => {
  tasks.toggle(request.params.id);

  response.redirect('/');
});

app.post('/delete/:id', (request, response) => {
  tasks.remove(request.params.id);

  response.redirect('/');
});

// --------------------------------------------------------------------------
// API JSON (conservée de la version précédente, alimentée par le vrai store)
// --------------------------------------------------------------------------
app.get('/api/tasks', (_request, response) => {
  response.status(200).json(tasks.list());
});

module.exports = app;
