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
});
