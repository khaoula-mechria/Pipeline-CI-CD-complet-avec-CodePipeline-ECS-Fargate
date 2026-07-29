const request = require('supertest');

const app = require('../src/app');
const tasks = require('../src/tasks');
const { escapeHtml, priorityVariant, renderIndex } = require('../src/views');

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
});
