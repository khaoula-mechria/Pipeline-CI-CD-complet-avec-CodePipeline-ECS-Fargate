// ==============================================================================
// HTML rendering for the home page — ported from the old templates/index.html
// (Jinja2/Flask) to plain JavaScript, with no external template engine.
//
// No dependency added on purpose: it keeps the production image minimal
// (< 200 MB target, see the Dockerfile) and rendering stays unit-testable as
// a pure function.
// ==============================================================================

const { PRIORITIES, DEFAULT_PRIORITY, STATUS_DONE } = require('./tasks');

// Jinja2 auto-escaped interpolated variables. Here it has to be done
// explicitly: without it, a task title containing HTML would be injected
// as-is into the page (a stored XSS).
const HTML_ESCAPES = {
  '&': '&amp;',
  '<': '&lt;',
  '>': '&gt;',
  '"': '&quot;',
  "'": '&#39;',
};

function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>"']/g, (character) => HTML_ESCAPES[character]);
}

// Bootstrap badge color by priority (same mapping as the original Jinja2
// template: Faible -> green, Moyenne -> orange, Haute -> red).
function priorityVariant(priority) {
  if (priority === 'Faible') {
    return 'success';
  }

  if (priority === DEFAULT_PRIORITY) {
    return 'warning';
  }

  return 'danger';
}

// Today's date as "YYYY-MM-DD" (UTC), the same format normalizeDueDate()
// stores — plain string comparison is enough to order or compare dates.
function today() {
  return new Date().toISOString().slice(0, 10);
}

function isOverdue(task) {
  return Boolean(task.dueDate) && task.status !== STATUS_DONE && task.dueDate < today();
}

function renderPriorityOptions() {
  return PRIORITIES.map((priority) => {
    const selected = priority === DEFAULT_PRIORITY ? ' selected' : '';

    return `<option value="${escapeHtml(priority)}"${selected}>${escapeHtml(priority)}</option>`;
  }).join('\n                            ');
}

function renderDueDate(task) {
  if (!task.dueDate) {
    return '';
  }

  const overdueClass = isOverdue(task) ? ' text-danger fw-semibold' : ' text-muted';
  const overdueLabel = isOverdue(task) ? ' (en retard)' : '';

  return `<div class="small${overdueClass}">Échéance : ${escapeHtml(task.dueDate)}${overdueLabel}</div>`;
}

// Edit form for a single task, collapsed behind a native <details>: no
// client-side JS needed to open/close it, only submitting it (Save) round-trips
// to the server, same as every other action in this app.
function renderEditForm(task) {
  const priorityOptions = PRIORITIES.map((priority) => {
    const selected = priority === task.priority ? ' selected' : '';

    return `<option value="${escapeHtml(priority)}"${selected}>${escapeHtml(priority)}</option>`;
  }).join('\n                        ');

  return `<details class="mt-2">
                    <summary class="small text-primary">Modifier</summary>
                    <form method="POST" action="/edit/${task.id}" class="mt-2 p-2 border rounded bg-light">
                        <div class="mb-2">
                            <input type="text" name="title" class="form-control form-control-sm"
                                   value="${escapeHtml(task.title)}" required>
                        </div>
                        <div class="mb-2">
                            <input type="text" name="description" class="form-control form-control-sm"
                                   value="${escapeHtml(task.description)}" placeholder="Description (optionnel)">
                        </div>
                        <div class="row g-2 align-items-center">
                            <div class="col">
                                <select name="priority" class="form-select form-select-sm">
                                    ${priorityOptions}
                                </select>
                            </div>
                            <div class="col">
                                <input type="date" name="dueDate" class="form-control form-control-sm"
                                       value="${escapeHtml(task.dueDate)}">
                            </div>
                            <div class="col-auto">
                                <button type="submit" class="btn btn-sm btn-primary">Enregistrer</button>
                            </div>
                        </div>
                    </form>
                </details>`;
}

function renderTask(task) {
  const doneClass = task.status === STATUS_DONE ? 'done' : '';
  const description = task.description
    ? `<div class="text-muted small">${escapeHtml(task.description)}</div>`
    : '';

  return `        <li class="list-group-item d-flex justify-content-between align-items-start">
            <div class="${doneClass}">
                <div class="fw-semibold">${escapeHtml(task.title)}</div>
                ${description}
                <span class="badge bg-${priorityVariant(task.priority)}">${escapeHtml(task.priority)}</span>
                ${renderDueDate(task)}
                ${renderEditForm(task)}
            </div>
            <div class="d-flex gap-1">
                <form method="POST" action="/toggle/${task.id}">
                    <button type="submit" class="btn btn-sm btn-outline-success" title="Terminer / Réactiver">
                        <i class="bi">✓</i>
                    </button>
                </form>
                <form method="POST" action="/delete/${task.id}" onsubmit="return confirm('Supprimer cette tâche ?');">
                    <button type="submit" class="btn btn-sm btn-outline-danger">✕</button>
                </form>
            </div>
        </li>`;
}

// Search/status/priority/sort toolbar. A plain GET form: filtering is a
// read, not a state change, so it belongs in the URL, not behind a POST.
function renderFilterBar(filters) {
  const query = filters.query || '';
  const status = filters.status || 'all';
  const priority = filters.priority || 'all';
  const sort = filters.sort || 'created';

  const option = (currentValue, value, label) => `<option value="${value}"${currentValue === value ? ' selected' : ''}>${label}</option>`;

  const priorityOptions = PRIORITIES.map((value) => option(priority, value, value)).join('\n                        ');

  return `    <form method="GET" action="/" class="row g-2 align-items-center mb-4">
        <div class="col-sm-4">
            <input type="text" name="q" class="form-control" placeholder="Rechercher un titre ou une description"
                   value="${escapeHtml(query)}">
        </div>
        <div class="col-sm-2">
            <select name="status" class="form-select" aria-label="Statut">
                ${option(status, 'all', 'Tous les statuts')}
                ${option(status, 'todo', 'À faire')}
                ${option(status, 'done', 'Terminée')}
            </select>
        </div>
        <div class="col-sm-2">
            <select name="priority" class="form-select" aria-label="Priorité">
                ${option(priority, 'all', 'Toutes priorités')}
                ${priorityOptions}
            </select>
        </div>
        <div class="col-sm-3">
            <select name="sort" class="form-select" aria-label="Trier par">
                ${option(sort, 'created', 'Plus récentes')}
                ${option(sort, 'due', 'Échéance')}
                ${option(sort, 'priority', 'Priorité')}
                ${option(sort, 'title', 'Titre (A-Z)')}
            </select>
        </div>
        <div class="col-sm-1 d-grid">
            <button type="submit" class="btn btn-outline-secondary">OK</button>
        </div>
    </form>`;
}

function renderTaskList(tasksToRender, hasAnyTasks) {
  if (tasksToRender.length === 0) {
    const message = hasAnyTasks
      ? 'Aucune tâche ne correspond à ces filtres.'
      : 'Aucune tâche pour le moment. Ajoutez-en une !';

    return `    <p class="text-muted text-center">${message}</p>`;
  }

  return `    <ul class="list-group shadow-sm">
${tasksToRender.map(renderTask).join('\n')}
    </ul>`;
}

function renderIndex(tasksToRender, { filters = {}, hasAnyTasks } = {}) {
  const resolvedHasAnyTasks = hasAnyTasks ?? tasksToRender.length > 0;

  return `<!DOCTYPE html>
<html lang="fr">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Task Manager</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.min.css" rel="stylesheet">
    <style>
        body { background-color: #f4f6f9; }
        .done { text-decoration: line-through; color: #888; }
    </style>
</head>
<body>
<div class="container py-5" style="max-width: 700px;">
    <h1 class="mb-4 fw-bold">📋 Task Manager</h1>

    <div class="card shadow-sm mb-4">
        <div class="card-body">
            <form method="POST" action="/add">
                <div class="mb-2">
                    <input type="text" name="title" class="form-control" placeholder="Titre de la tâche" required>
                </div>
                <div class="mb-2">
                    <input type="text" name="description" class="form-control" placeholder="Description (optionnel)">
                </div>
                <div class="row g-2 align-items-center">
                    <div class="col">
                        <select name="priority" class="form-select">
                            ${renderPriorityOptions()}
                        </select>
                    </div>
                    <div class="col">
                        <input type="date" name="dueDate" class="form-control" aria-label="Échéance (optionnel)">
                    </div>
                    <div class="col-auto">
                        <button type="submit" class="btn btn-primary">Ajouter</button>
                    </div>
                </div>
            </form>
        </div>
    </div>

${renderFilterBar(filters)}

${renderTaskList(tasksToRender, resolvedHasAnyTasks)}
</div>
</body>
</html>
`;
}

module.exports = { escapeHtml, priorityVariant, isOverdue, renderIndex };
