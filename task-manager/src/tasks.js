// ==============================================================================
// Store des tâches — volontairement EN MÉMOIRE, pas de base de données.
//
// Pourquoi : le système de fichiers Fargate est éphémère et le service tourne
// avec plusieurs tâches derrière l'ALB (DesiredCount, cf. ecs-service.yaml).
// Un fichier SQLite local — comme dans la version Flask remplacée — donnerait
// un état différent par tâche, effacé à chaque déploiement Blue/Green.
// L'objet du cahier des charges est le pipeline CI/CD, pas la persistance :
// pour un stockage réellement partagé, remplacer CE SEUL module (DynamoDB ou
// RDS) sans toucher aux routes de app.js.
// ==============================================================================

const PRIORITIES = ['Faible', 'Moyenne', 'Haute'];
const DEFAULT_PRIORITY = 'Moyenne';

const STATUS_TODO = 'A faire';
const STATUS_DONE = 'Terminee';

let tasks = [];
let nextId = 1;

// Plus récentes d'abord — équivalent du "ORDER BY id DESC" de la version Flask.
function list() {
  return [...tasks].sort((first, second) => second.id - first.id);
}

function add({ title, description = '', priority = DEFAULT_PRIORITY } = {}) {
  const cleanTitle = String(title ?? '').trim();

  // Un titre vide était déjà ignoré silencieusement côté Flask : on garde ce
  // comportement, le formulaire porte déjà l'attribut HTML "required".
  if (!cleanTitle) {
    return null;
  }

  const task = {
    id: nextId,
    title: cleanTitle,
    description: String(description ?? '').trim(),
    // Une priorité inconnue (formulaire forgé à la main) retombe sur la valeur
    // par défaut plutôt que d'être stockée telle quelle.
    priority: PRIORITIES.includes(priority) ? priority : DEFAULT_PRIORITY,
    status: STATUS_TODO,
    createdAt: new Date().toISOString(),
  };

  nextId += 1;
  tasks.push(task);

  return task;
}

function toggle(id) {
  const task = tasks.find((candidate) => candidate.id === Number(id));

  if (!task) {
    return null;
  }

  task.status = task.status === STATUS_DONE ? STATUS_TODO : STATUS_DONE;

  return task;
}

function remove(id) {
  const index = tasks.findIndex((candidate) => candidate.id === Number(id));

  if (index === -1) {
    return false;
  }

  tasks.splice(index, 1);

  return true;
}

// Utilisé par les tests pour repartir d'un état propre à chaque cas.
function reset() {
  tasks = [];
  nextId = 1;
}

module.exports = {
  PRIORITIES,
  DEFAULT_PRIORITY,
  STATUS_TODO,
  STATUS_DONE,
  list,
  add,
  toggle,
  remove,
  reset,
};
