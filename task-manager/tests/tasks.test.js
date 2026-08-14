const request = require('supertest');

const app = require('../src/app');
const tasks = require('../src/tasks');

// Le store est en mémoire et partagé par le module : on repart d'un état propre
// avant chaque cas, sinon les tests deviennent dépendants de leur ordre.
beforeEach(() => {
  tasks.reset();
});

describe('GET /api/tasks', () => {
  it('responds with an empty array when no task exists', async () => {
    const response = await request(app).get('/api/tasks');

    expect(response.statusCode).toBe(200);
    expect(response.body).toEqual([]);
  });

  it('exposes created tasks, most recent first', async () => {
    await request(app).post('/add').type('form').send({ title: 'Première' });
    await request(app).post('/add').type('form').send({ title: 'Seconde' });

    const response = await request(app).get('/api/tasks');

    expect(response.statusCode).toBe(200);
    expect(response.body.map((task) => task.title)).toEqual(['Seconde', 'Première']);
  });
});

describe('POST /add', () => {
  it('creates a task and redirects to the index', async () => {
    const response = await request(app)
      .post('/add')
      .type('form')
      .send({ title: 'Rédiger le rapport', description: 'Avant vendredi', priority: 'Haute' });

    expect(response.statusCode).toBe(302);
    expect(response.headers.location).toBe('/');

    expect(tasks.list()).toHaveLength(1);
    expect(tasks.list()[0]).toMatchObject({
      title: 'Rédiger le rapport',
      description: 'Avant vendredi',
      priority: 'Haute',
      status: tasks.STATUS_TODO,
    });
  });

  it('trims whitespace around the title and description', async () => {
    await request(app)
      .post('/add')
      .type('form')
      .send({ title: '   Espaces   ', description: '  autour  ' });

    expect(tasks.list()[0]).toMatchObject({ title: 'Espaces', description: 'autour' });
  });

  it('ignores a task submitted without a title', async () => {
    const response = await request(app).post('/add').type('form').send({ title: '   ' });

    expect(response.statusCode).toBe(302);
    expect(tasks.list()).toHaveLength(0);
  });

  it('falls back to the default priority when the value is unknown', async () => {
    await request(app).post('/add').type('form').send({ title: 'Forgée', priority: 'Critique' });

    expect(tasks.list()[0].priority).toBe(tasks.DEFAULT_PRIORITY);
  });

  // app.js monte express.json() en plus de express.urlencoded() : un client
  // d'API (et pas seulement le formulaire HTML) doit donc pouvoir créer une
  // tâche. Ce chemin n'était couvert par aucun test.
  it('also accepts a JSON body, not just an HTML form', async () => {
    const response = await request(app)
      .post('/add')
      .send({ title: 'Créée en JSON', priority: 'Faible' });

    expect(response.statusCode).toBe(302);
    expect(tasks.list()[0]).toMatchObject({ title: 'Créée en JSON', priority: 'Faible' });
  });
});

describe('POST /edit/:id', () => {
  it('updates title, description, priority, and due date, then redirects', async () => {
    const created = tasks.add({ title: 'Brouillon' });

    const response = await request(app)
      .post(`/edit/${created.id}`)
      .type('form')
      .send({
        title: 'Version finale',
        description: 'Relue',
        priority: 'Haute',
        dueDate: '2026-09-01',
      });

    expect(response.statusCode).toBe(302);
    expect(response.headers.location).toBe('/');
    expect(tasks.list()[0]).toMatchObject({
      id: created.id,
      title: 'Version finale',
      description: 'Relue',
      priority: 'Haute',
      dueDate: '2026-09-01',
    });
  });

  it('redirects without failing for an unknown id', async () => {
    const response = await request(app)
      .post('/edit/4242')
      .type('form')
      .send({ title: 'Peu importe' });

    expect(response.statusCode).toBe(302);
    expect(response.headers.location).toBe('/');
  });

  it('leaves the task unchanged when the new title is blank', async () => {
    const created = tasks.add({ title: 'Titre original' });

    await request(app).post(`/edit/${created.id}`).type('form').send({ title: '   ' });

    expect(tasks.list()[0].title).toBe('Titre original');
  });
});

describe('unknown routes', () => {
  // Documente le comportement actuel : pas de handler d'erreur personnalisé,
  // c'est le 404 par défaut d'Express qui s'applique.
  it('responds with 404', async () => {
    const response = await request(app).get('/n-existe-pas');

    expect(response.statusCode).toBe(404);
  });
});

describe('POST /toggle/:id', () => {
  it('switches a task from "à faire" to "terminée" and back', async () => {
    const created = tasks.add({ title: 'À basculer' });

    await request(app).post(`/toggle/${created.id}`);
    expect(tasks.list()[0].status).toBe(tasks.STATUS_DONE);

    await request(app).post(`/toggle/${created.id}`);
    expect(tasks.list()[0].status).toBe(tasks.STATUS_TODO);
  });

  it('redirects without failing for an unknown id', async () => {
    const response = await request(app).post('/toggle/4242');

    expect(response.statusCode).toBe(302);
    expect(response.headers.location).toBe('/');
  });
});

describe('POST /delete/:id', () => {
  it('removes the task and redirects', async () => {
    const created = tasks.add({ title: 'À supprimer' });

    const response = await request(app).post(`/delete/${created.id}`);

    expect(response.statusCode).toBe(302);
    expect(tasks.list()).toHaveLength(0);
  });

  it('redirects without failing for an unknown id', async () => {
    const response = await request(app).post('/delete/4242');

    expect(response.statusCode).toBe(302);
    expect(tasks.list()).toHaveLength(0);
  });
});

describe('store', () => {
  it('returns null when add() is called without any argument', () => {
    expect(tasks.add()).toBeNull();
  });

  it('returns null when toggling an unknown id', () => {
    expect(tasks.toggle(1)).toBeNull();
  });

  it('returns false when removing an unknown id', () => {
    expect(tasks.remove(1)).toBe(false);
  });

  it('accepts a null description', () => {
    expect(tasks.add({ title: 'Sans description', description: null })).toMatchObject({
      description: '',
    });
  });

  it('does not reuse ids after a deletion', () => {
    const first = tasks.add({ title: 'Première' });
    tasks.remove(first.id);

    const second = tasks.add({ title: 'Seconde' });

    expect(second.id).not.toBe(first.id);
  });

  it('stores a valid due date on add()', () => {
    expect(tasks.add({ title: 'Avec échéance', dueDate: '2026-09-01' })).toMatchObject({
      dueDate: '2026-09-01',
    });
  });

  it('discards a malformed due date on add()', () => {
    expect(tasks.add({ title: 'Échéance invalide', dueDate: 'demain' })).toMatchObject({
      dueDate: '',
    });
  });
});

describe('update', () => {
  it('returns null for an unknown id', () => {
    expect(tasks.update(999, { title: 'Peu importe' })).toBeNull();
  });

  it('returns null when called without any changes argument', () => {
    const created = tasks.add({ title: 'Original' });

    expect(tasks.update(created.id)).toBeNull();
  });

  it('trims whitespace around the new title and description', () => {
    const created = tasks.add({ title: 'Original' });

    tasks.update(created.id, { title: '  Modifié  ', description: '  aussi  ' });

    expect(tasks.list()[0]).toMatchObject({ title: 'Modifié', description: 'aussi' });
  });

  it('falls back to the default priority when given an unknown value', () => {
    const created = tasks.add({ title: 'Original', priority: 'Faible' });

    tasks.update(created.id, { title: 'Original', priority: 'Critique' });

    expect(tasks.list()[0].priority).toBe(tasks.DEFAULT_PRIORITY);
  });

  it('clears the due date when given an invalid value', () => {
    const created = tasks.add({ title: 'Original', dueDate: '2026-09-01' });

    tasks.update(created.id, { title: 'Original', dueDate: 'pas une date' });

    expect(tasks.list()[0].dueDate).toBe('');
  });
});

describe('list: filtering', () => {
  it('matches a search query against the title or the description', () => {
    tasks.add({ title: 'Rédiger le rapport', description: 'Section budget' });
    tasks.add({ title: 'Relire le CDC', description: 'Sans rapport avec le budget' });
    tasks.add({ title: 'Autre chose', description: 'Rien à voir' });

    const byTitle = tasks.list({ query: 'rapport' });
    expect(byTitle).toHaveLength(2);

    const byDescription = tasks.list({ query: 'BUDGET' });
    expect(byDescription).toHaveLength(2);
  });

  it('filters by status', () => {
    const done = tasks.add({ title: 'Faite' });
    tasks.add({ title: 'Pas faite' });
    tasks.toggle(done.id);

    expect(tasks.list({ status: 'done' })).toHaveLength(1);
    expect(tasks.list({ status: 'todo' })).toHaveLength(1);
    expect(tasks.list({ status: 'all' })).toHaveLength(2);
    expect(tasks.list({ status: 'garbage' })).toHaveLength(2);
  });

  it('filters by priority, treating an unknown value as "all"', () => {
    tasks.add({ title: 'Une', priority: 'Haute' });
    tasks.add({ title: 'Deux', priority: 'Faible' });

    expect(tasks.list({ priority: 'Haute' })).toHaveLength(1);
    expect(tasks.list({ priority: 'garbage' })).toHaveLength(2);
  });

  it('combines query, status, and priority filters', () => {
    const match = tasks.add({ title: 'Facture client', priority: 'Haute' });
    tasks.add({ title: 'Facture fournisseur', priority: 'Faible' });
    tasks.toggle(match.id);

    const result = tasks.list({ query: 'facture', status: 'done', priority: 'Haute' });

    expect(result).toHaveLength(1);
    expect(result[0].id).toBe(match.id);
  });

  it('is not derailed by a non-string query (e.g. a repeated query-string key)', () => {
    tasks.add({ title: 'Une tâche' });

    expect(() => tasks.list({ query: ['a', 'b'] })).not.toThrow();
  });
});

describe('list: sorting', () => {
  it('sorts by due date, soonest first, with undated tasks last (most recent first among them)', () => {
    const olderUndated = tasks.add({ title: 'Sans échéance (plus ancienne)' });
    const newerUndated = tasks.add({ title: 'Sans échéance (plus récente)' });
    tasks.add({ title: 'Plus tard', dueDate: '2026-12-01' });
    tasks.add({ title: 'Bientôt', dueDate: '2026-09-01' });

    const result = tasks.list({ sortBy: 'due' });

    expect(result.map((task) => task.title)).toEqual([
      'Bientôt',
      'Plus tard',
      'Sans échéance (plus récente)',
      'Sans échéance (plus ancienne)',
    ]);
    // Both undated: falls back to most-recent-first, same tie-break as elsewhere.
    expect(result[2].id).toBe(newerUndated.id);
    expect(result[3].id).toBe(olderUndated.id);
  });

  it('tie-breaks two undated tasks by recency when sorting by due date', () => {
    const older = tasks.add({ title: 'Plus ancienne' });
    const newer = tasks.add({ title: 'Plus récente' });

    const result = tasks.list({ sortBy: 'due' });

    expect(result.map((task) => task.id)).toEqual([newer.id, older.id]);
  });

  it('sorts by priority, Haute first, and by recency within the same priority', () => {
    const olderLow = tasks.add({ title: 'Basse (ancienne)', priority: 'Faible' });
    const newerLow = tasks.add({ title: 'Basse (récente)', priority: 'Faible' });
    tasks.add({ title: 'Haute', priority: 'Haute' });
    tasks.add({ title: 'Moyenne', priority: 'Moyenne' });

    const result = tasks.list({ sortBy: 'priority' });

    expect(result.map((task) => task.priority)).toEqual(['Haute', 'Moyenne', 'Faible', 'Faible']);
    // Tie on priority: falls back to most-recent-first.
    expect(result[2].id).toBe(newerLow.id);
    expect(result[3].id).toBe(olderLow.id);
  });

  it('sorts alphabetically by title', () => {
    tasks.add({ title: 'Zèbre' });
    tasks.add({ title: 'Abricot' });

    const result = tasks.list({ sortBy: 'title' });

    expect(result.map((task) => task.title)).toEqual(['Abricot', 'Zèbre']);
  });

  it('falls back to most-recent-first for an unrecognized sort value', () => {
    const first = tasks.add({ title: 'Première' });
    const second = tasks.add({ title: 'Seconde' });

    const result = tasks.list({ sortBy: 'garbage' });

    expect(result.map((task) => task.id)).toEqual([second.id, first.id]);
  });
});
