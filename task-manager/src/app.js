const express = require('express');

const app = express();

app.use(express.json());

const tasks = [];

app.get('/health', (_request, response) => {
  response.status(200).json({ status: 'ok' });
});

app.get('/api/tasks', (_request, response) => {
  response.status(200).json(tasks);
});

module.exports = app;