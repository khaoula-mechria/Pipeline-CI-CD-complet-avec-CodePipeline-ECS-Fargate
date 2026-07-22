const app = require('./src/app');

const port = process.env.PORT || 3000;

if (require.main === module) {
  app.listen(port, () => {
    console.log(`Task manager listening on port ${port}`);
  });
}

module.exports = app;