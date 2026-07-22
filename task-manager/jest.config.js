// jest.config.js
// À placer à la racine du dépôt. Adapte "testMatch" si tes fichiers de
// test ne sont pas dans un dossier "tests/" ou en "*.test.js".

module.exports = {
  testEnvironment: 'node',
  testMatch: ['**/tests/**/*.test.js'],

  // Nécessaire pour que buildspec.yml puisse lire coverage-summary.json
  collectCoverage: true,
  coverageDirectory: 'coverage',
  coverageReporters: ['text', 'json-summary', 'lcov'],

  // Génère reports/junit.xml, lu par la section "reports" de buildspec.yml
  // (nécessite : npm install --save-dev jest-junit)
  reporters: [
    'default',
    ['jest-junit', { outputDirectory: 'reports', outputName: 'junit.xml' }],
  ],
};