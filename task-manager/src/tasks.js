// ==============================================================================
// Task store — deliberately IN MEMORY, no database.
//
// Why: the Fargate filesystem is ephemeral and the service runs with several
// tasks behind the ALB (DesiredCount, see ecs-service.yaml). A local SQLite
// file — like in the Flask version this replaced — would give a different
// state per task, wiped on every Blue/Green deployment. The point of the CDC
// is the CI/CD pipeline, not persistence: for real shared storage, replace
// ONLY this module (DynamoDB or RDS) without touching app.js's routes.
// ==============================================================================

const PRIORITIES = ['Faible', 'Moyenne', 'Haute'];
const DEFAULT_PRIORITY = 'Moyenne';
const PRIORITY_RANK = { Faible: 0, Moyenne: 1, Haute: 2 };

const STATUS_TODO = 'A faire';
const STATUS_DONE = 'Terminee';

const DUE_DATE_PATTERN = /^\d{4}-\d{2}-\d{2}$/;

let tasks = [];
let nextId = 1;

// HTML <input type="date"> sends "YYYY-MM-DD" or an empty string. Anything
// else (a hand-crafted request, a browser quirk) is stored as "no due date"
// rather than propagated as free-form text: the value is later compared with
// plain string operators (sort, isOverdue), which only stay correct for this
// exact format.
function normalizeDueDate(dueDate) {
  const value = String(dueDate ?? '').trim();

  return DUE_DATE_PATTERN.test(value) ? value : '';
}

function taskMatchesQuery(task, normalizedQuery) {
  if (!normalizedQuery) {
    return true;
  }

  return (
    task.title.toLowerCase().includes(normalizedQuery)
    || task.description.toLowerCase().includes(normalizedQuery)
  );
}

function taskMatchesStatus(task, status) {
  if (status === 'done') {
    return task.status === STATUS_DONE;
  }

  if (status === 'todo') {
    return task.status === STATUS_TODO;
  }

  // 'all', undefined, or any unrecognized value: don't filter.
  return true;
}

function taskMatchesPriority(task, priority) {
  // Only an exact, known priority narrows the list; 'all' and anything
  // unrecognized behave the same as "no filter" rather than matching nothing.
  return !PRIORITIES.includes(priority) || task.priority === priority;
}

function sortTasks(list, sortBy) {
  const sorted = [...list];

  if (sortBy === 'due') {
    // Undated tasks sink to the bottom regardless of direction; among dated
    // tasks, soonest first.
    sorted.sort((first, second) => {
      if (!first.dueDate && !second.dueDate) return second.id - first.id;
      if (!first.dueDate) return 1;
      if (!second.dueDate) return -1;
      return first.dueDate.localeCompare(second.dueDate);
    });
    return sorted;
  }

  if (sortBy === 'priority') {
    sorted.sort(
      (first, second) => PRIORITY_RANK[second.priority] - PRIORITY_RANK[first.priority]
        || second.id - first.id,
    );
    return sorted;
  }

  if (sortBy === 'title') {
    sorted.sort((first, second) => first.title.localeCompare(second.title));
    return sorted;
  }

  // 'created' (default) and any unrecognized value: most recent first,
  // matching this store's original (and only) behavior.
  sorted.sort((first, second) => second.id - first.id);
  return sorted;
}

function list({ query, status, priority, sortBy } = {}) {
  const normalizedQuery = String(query ?? '').trim().toLowerCase();

  const filtered = tasks.filter(
    (task) => taskMatchesQuery(task, normalizedQuery)
      && taskMatchesStatus(task, status)
      && taskMatchesPriority(task, priority),
  );

  return sortTasks(filtered, sortBy);
}

function add({ title, description = '', priority = DEFAULT_PRIORITY, dueDate = '' } = {}) {
  const cleanTitle = String(title ?? '').trim();

  // An empty title was already silently ignored on the Flask side: keep that
  // behavior, the form already carries the HTML "required" attribute.
  if (!cleanTitle) {
    return null;
  }

  const task = {
    id: nextId,
    title: cleanTitle,
    description: String(description ?? '').trim(),
    // An unknown priority (a hand-crafted form) falls back to the default
    // rather than being stored as-is.
    priority: PRIORITIES.includes(priority) ? priority : DEFAULT_PRIORITY,
    dueDate: normalizeDueDate(dueDate),
    status: STATUS_TODO,
    createdAt: new Date().toISOString(),
  };

  nextId += 1;
  tasks.push(task);

  return task;
}

function update(id, { title, description, priority, dueDate } = {}) {
  const task = tasks.find((candidate) => candidate.id === Number(id));

  if (!task) {
    return null;
  }

  const cleanTitle = String(title ?? '').trim();

  // Same rule as add(): a blank title is rejected rather than clearing the
  // existing one.
  if (!cleanTitle) {
    return null;
  }

  task.title = cleanTitle;
  task.description = String(description ?? '').trim();
  task.priority = PRIORITIES.includes(priority) ? priority : DEFAULT_PRIORITY;
  task.dueDate = normalizeDueDate(dueDate);

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

// Used by tests to start from a clean state on every case.
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
  update,
  toggle,
  remove,
  reset,
};
