const request = require('supertest');

const app = require('../src/app');

describe('Version', () => {
  const originalVersion = process.env.APP_VERSION;

  afterEach(() => {
    process.env.APP_VERSION = originalVersion;
  });

  it('GET /version reports the APP_VERSION env var', async () => {
    process.env.APP_VERSION = 'abc12345';

    // app.js reads process.env.APP_VERSION at request time, not at require
    // time, so mutating it in the test is enough -- no need to re-require.
    const response = await request(app).get('/version');

    expect(response.statusCode).toBe(200);
    expect(response.body).toEqual({ version: 'abc12345' });
  });

  it('GET /version falls back to "dev" when APP_VERSION is unset', async () => {
    delete process.env.APP_VERSION;

    const response = await request(app).get('/version');

    expect(response.statusCode).toBe(200);
    expect(response.body).toEqual({ version: 'dev' });
  });
});
