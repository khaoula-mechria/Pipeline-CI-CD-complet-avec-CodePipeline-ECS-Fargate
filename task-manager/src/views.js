// ==============================================================================
// Rendu HTML de la page d'accueil — portage de l'ancien templates/index.html
// (Jinja2/Flask) en JavaScript, sans moteur de template externe.
//
// Pas de dépendance ajoutée volontairement : ça garde l'image de production
// minimale (objectif < 200 Mo rappelé dans le Dockerfile) et le rendu reste
// testable unitairement comme une fonction pure.
// ==============================================================================

const { PRIORITIES, DEFAULT_PRIORITY, STATUS_DONE } = require('./tasks');

// Jinja2 échappait automatiquement les variables interpolées. Ici c'est à faire
// explicitement : sans ça, un titre de tâche contenant du HTML serait injecté
// tel quel dans la page (faille XSS stockée).
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

// Couleur du badge Bootstrap selon la priorité (même mapping que le template
// Jinja2 d'origine : Faible -> vert, Moyenne -> orange, Haute -> rouge).
function priorityVariant(priority) {
  if (priority === 'Faible') {
    return 'success';
  }

  if (priority === DEFAULT_PRIORITY) {
    return 'warning';
  }

  return 'danger';
}

function renderPriorityOptions() {
  return PRIORITIES.map((priority) => {
    const selected = priority === DEFAULT_PRIORITY ? ' selected' : '';

    return `<option value="${escapeHtml(priority)}"${selected}>${escapeHtml(priority)}</option>`;
  }).join('\n                            ');
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

function renderTaskList(tasks) {
  if (tasks.length === 0) {
    return '    <p class="text-muted text-center">Aucune tâche pour le moment. Ajoutez-en une !</p>';
  }

  return `    <ul class="list-group shadow-sm">
${tasks.map(renderTask).join('\n')}
    </ul>`;
}

function renderIndex(tasks) {
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
                    <div class="col-auto">
                        <button type="submit" class="btn btn-primary">Ajouter</button>
                    </div>
                </div>
            </form>
        </div>
    </div>

${renderTaskList(tasks)}
</div>
</body>
</html>
`;
}

module.exports = { escapeHtml, priorityVariant, renderIndex };
