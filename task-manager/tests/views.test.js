const request = require('supertest');

const app = require('../src/app');
const tasks = require('../src/tasks');
const { escapeHtml, priorityVariant, isOverdue, renderIndex } = require('../src/views');

beforeEach(() => {
  tasks.reset();
});

describe('GET /', () => {
  it('renders the empty state when there is no task', async () => {
    const response = await request(app).get('/');

    expect(response.statusCode).toBe(200);
    expect(response.headers['content-type']).toMatch(/html/);
    expect(response.text).toContain('Aucune tâche pour le moment');
  });

  it('renders the tasks with their description and priority badge', async () => {
    tasks.add({ title: 'Relire le CDC', description: 'Section F3', priority: 'Haute' });

    const response = await request(app).get('/');

    expect(response.text).toContain('Relire le CDC');
    expect(response.text).toContain('Section F3');
    expect(response.text).toContain('badge bg-danger');
    expect(response.text).not.toContain('Aucune tâche pour le moment');
  });

  it('exposes the toggle and delete forms for each task', async () => {
    const created = tasks.add({ title: 'Une tâche' });

    const response = await request(app).get('/');

    expect(response.text).toContain(`action="/toggle/${created.id}"`);
    expect(response.text).toContain(`action="/delete/${created.id}"`);
  });

  it('strikes through a task that is done', async () => {
    const created = tasks.add({ title: 'Terminée' });
    tasks.toggle(created.id);

    const response = await request(app).get('/');

    expect(response.text).toContain('<div class="done">');
  });

  // Jinja2 échappait automatiquement ; la régression correspondante côté JS
  // serait une XSS stockée, donc elle est testée explicitement.
  it('escapes HTML coming from a task title', async () => {
    tasks.add({ title: '<script>alert(1)</script>' });

    const response = await request(app).get('/');

    expect(response.text).not.toContain('<script>alert(1)</script>');
    expect(response.text).toContain('&lt;script&gt;alert(1)&lt;/script&gt;');
  });

  it('escapes a task title inside its own edit form (attribute-injection XSS)', async () => {
    tasks.add({ title: '"><script>alert(1)</script>' });

    const response = await request(app).get('/');

    expect(response.text).not.toContain('<script>alert(1)</script>');
  });

  it('shows the due date on a task that has one', async () => {
    tasks.add({ title: 'Avec échéance', dueDate: '2026-09-01' });

    const response = await request(app).get('/');

    expect(response.text).toContain('2026-09-01');
  });

  it('flags an overdue task but not a done one with the same past due date', async () => {
    const overdue = tasks.add({ title: 'En retard', dueDate: '2000-01-01' });
    const doneButPast = tasks.add({ title: 'Faite quand même', dueDate: '2000-01-01' });
    tasks.toggle(doneButPast.id);

    const response = await request(app).get('/');

    expect(response.text).toContain('en retard');
    // Exactly one occurrence: the still-open task, not the done one.
    expect(response.text.match(/\(en retard\)/g)).toHaveLength(1);
  });

  it('narrows the list with a search query, reflecting the query back into the search box', async () => {
    tasks.add({ title: 'Rédiger le rapport' });
    tasks.add({ title: 'Autre chose' });

    const response = await request(app).get('/?q=rapport');

    expect(response.text).toContain('Rédiger le rapport');
    expect(response.text).not.toContain('Autre chose');
    expect(response.text).toContain('value="rapport"');
  });

  it('filters by status via the query string', async () => {
    const done = tasks.add({ title: 'Faite' });
    tasks.add({ title: 'Pas faite' });
    tasks.toggle(done.id);

    const response = await request(app).get('/?status=done');

    expect(response.text).toContain('Faite');
    expect(response.text).not.toContain('Pas faite');
  });

  it('shows a dedicated message when filters exclude every task, tasks still existing', async () => {
    tasks.add({ title: 'Une tâche' });

    const response = await request(app).get('/?q=inexistant');

    expect(response.text).toContain('Aucune tâche ne correspond à ces filtres');
    expect(response.text).not.toContain('Aucune tâche pour le moment');
  });
});

describe('escapeHtml', () => {
  it('escapes every HTML-significant character', () => {
    expect(escapeHtml(`&<>"'`)).toBe('&amp;&lt;&gt;&quot;&#39;');
  });

  it('renders null and undefined as an empty string', () => {
    expect(escapeHtml(null)).toBe('');
    expect(escapeHtml(undefined)).toBe('');
  });
});

describe('priorityVariant', () => {
  it('maps each priority to its Bootstrap colour', () => {
    expect(priorityVariant('Faible')).toBe('success');
    expect(priorityVariant('Moyenne')).toBe('warning');
    expect(priorityVariant('Haute')).toBe('danger');
  });
});

describe('isOverdue', () => {
  it('is false when the task has no due date', () => {
    expect(isOverdue({ dueDate: '', status: tasks.STATUS_TODO })).toBe(false);
  });

  it('is true for a past due date on a task that is not done', () => {
    expect(isOverdue({ dueDate: '2000-01-01', status: tasks.STATUS_TODO })).toBe(true);
  });

  it('is false for a past due date once the task is done', () => {
    expect(isOverdue({ dueDate: '2000-01-01', status: tasks.STATUS_DONE })).toBe(false);
  });

  it('is false for a due date in the future', () => {
    expect(isOverdue({ dueDate: '2999-01-01', status: tasks.STATUS_TODO })).toBe(false);
  });
});

describe('renderIndex', () => {
  it('omits the description block when the task has none', () => {
    const html = renderIndex([
      { id: 1, title: 'Sans description', description: '', priority: 'Moyenne', status: tasks.STATUS_TODO },
    ]);

    expect(html).toContain('Sans description');
    expect(html).not.toContain('text-muted small');
  });

  it('preselects the default priority in the form', () => {
    const html = renderIndex([]);

    expect(html).toContain(`<option value="${tasks.DEFAULT_PRIORITY}" selected>`);
  });

  it('preselects the current filters in the toolbar', () => {
    const html = renderIndex([], {
      filters: { query: 'facture', status: 'done', priority: 'Haute', sort: 'due' },
    });

    expect(html).toContain('value="facture"');
    expect(html).toContain('<option value="done" selected>');
    expect(html).toContain('<option value="Haute" selected>');
    expect(html).toContain('<option value="due" selected>');
  });

  it('defaults the toolbar to "all"/"created" when no filters are given', () => {
    const html = renderIndex([]);

    expect(html).toContain('<option value="all" selected>Tous les statuts</option>');
    expect(html).toContain('<option value="all" selected>Toutes priorités</option>');
    expect(html).toContain('<option value="created" selected>');
  });
});
