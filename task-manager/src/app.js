// ==============================================================================
// "Task manager" application (Express) — the ONLY application in this repo.
//
// Built by task-manager/Dockerfile, tested by task-manager/buildspec.yml and
// .github/workflows/ci.yml, and deployed on ECS Fargate. The old Flask version
// (src/app.py + templates/index.html) was ported here then removed, to
// eliminate the drift between what CI validated and what was actually
// deployed (see CONFORMITE_CDC.md).
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

// express.json for the API, express.urlencoded for HTML forms (a
// <form method="POST"> sends application/x-www-form-urlencoded).
app.use(express.json());
app.use(express.urlencoded({ extended: false }));

// --------------------------------------------------------------------------
// Health probe. Used by THREE distinct mechanisms, never remove it or make it
// depend on application state:
//   - the Dockerfile's HEALTHCHECK,
//   - the ECS container health check (ecs-task-definition.yaml),
//   - the ALB's Blue/Green target groups (alb.yaml) — CodeDeploy's automatic
//     rollback depends on it (F3 of the requirements).
// --------------------------------------------------------------------------
app.get('/health', (_request, response) => {
  response.status(200).json({ status: 'ok' });
});

// --------------------------------------------------------------------------
// Identifies which build is actually running in production. APP_VERSION is
// baked in at image build time (buildspec.yml passes the commit-SHA IMAGE_TAG
// as a Docker build-arg) — this is what makes a Blue/Green traffic shift
// externally verifiable: hit the ALB before and after a deployment and see
// the commit SHA change once GREEN takes over.
// --------------------------------------------------------------------------
app.get('/version', (_request, response) => {
  response.status(200).json({ version: process.env.APP_VERSION || 'dev' });
});

// --------------------------------------------------------------------------
// HTML interface: list (with search/filter/sort) + add/edit/toggle/delete.
// Search, status, priority, and sort all live in the query string rather than
// server-side session state, so the page stays a single stateless GET that's
// bookmarkable and works the same after a reload or a redeploy.
// --------------------------------------------------------------------------
app.get('/', (request, response) => {
  const { q = '', status = 'all', priority = 'all', sort = 'created' } = request.query;

  const allTasks = tasks.list();
  const filteredTasks = tasks.list({ query: q, status, priority, sortBy: sort });

  response.type('html').send(
    renderIndex(filteredTasks, {
      filters: { query: q, status, priority, sort },
      // Computed from the UNFILTERED count so the empty state can tell "no
      // tasks at all" apart from "no task matches the current filters".
      hasAnyTasks: allTasks.length > 0,
    }),
  );
});

app.post('/add', (request, response) => {
  tasks.add({
    title: request.body.title,
    description: request.body.description,
    priority: request.body.priority,
    dueDate: request.body.dueDate,
  });

  response.redirect('/');
});

app.post('/edit/:id', (request, response) => {
  tasks.update(request.params.id, {
    title: request.body.title,
    description: request.body.description,
    priority: request.body.priority,
    dueDate: request.body.dueDate,
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
// JSON API (kept from the earlier version, backed by the real store)
// --------------------------------------------------------------------------
app.get('/api/tasks', (_request, response) => {
  response.status(200).json(tasks.list());
});

module.exports = app;
