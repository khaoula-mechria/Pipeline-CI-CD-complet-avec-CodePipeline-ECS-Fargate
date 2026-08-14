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

// Semgrep's CSRF-middleware audit rule (express-check-csurf-middleware-usage)
// always anchors on this express() initialization line, never on individual
// routes. This app has no session or auth cookie for a forged cross-site
// request to ride on, so CSRF protection does not apply; see the POST routes
// below for the state-changing actions this would otherwise flag.
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
