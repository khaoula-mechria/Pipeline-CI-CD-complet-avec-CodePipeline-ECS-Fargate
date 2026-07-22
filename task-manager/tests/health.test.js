const request = require('supertest');

const app = require('../src/app');

describe('Healthcheck', () => {
  it('GET /health responds with 200', async () => {
    const response = await request(app).get('/health');
    expect(response.statusCode).toBe(200);
  });
});

describe('Tasks', () => {
  it('GET /api/tasks responds with an array', async () => {
    const response = await request(app).get('/api/tasks');
    expect(response.statusCode).toBe(200);
    expect(Array.isArray(response.body)).toBe(true);
  });
});