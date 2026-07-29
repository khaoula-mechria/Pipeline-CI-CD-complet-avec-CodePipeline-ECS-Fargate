const request = require('supertest');

const app = require('../src/app');
const tasks = require('../src/tasks');

describe('Healthcheck', () => {
  it('GET /health responds with 200', async () => {
    const response = await request(app).get('/health');

    expect(response.statusCode).toBe(200);
    expect(response.body).toEqual({ status: 'ok' });
  });

  // La sonde doit répondre indépendamment de l'état applicatif : c'est elle qui
  // conditionne le health check ECS et les target groups Blue/Green de l'ALB.
  it('GET /health stays healthy once tasks exist', async () => {
    tasks.reset();
    tasks.add({ title: 'Une tâche' });

    const response = await request(app).get('/health');

    expect(response.statusCode).toBe(200);
  });
});
