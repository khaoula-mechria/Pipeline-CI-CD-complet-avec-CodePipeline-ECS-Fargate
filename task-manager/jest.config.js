// jest.config.js — configuration des tests de l'application task-manager.
// Vit à la racine de task-manager/ (même niveau que package.json), c'est de là
// que `npm test` est lancé, aussi bien par buildspec.yml que par la CI GitHub.

module.exports = {
  testEnvironment: 'node',
  testMatch: ['**/tests/**/*.test.js'],

  // Nécessaire pour que buildspec.yml puisse lire coverage-summary.json
  collectCoverage: true,
  coverageDirectory: 'coverage',
  coverageReporters: ['text', 'json-summary', 'lcov'],

  // Sans cette liste, Jest ne mesure QUE les fichiers atteints par un test :
  // ajouter un module non testé ne ferait pas baisser la couverture et le
  // quality gate à 80 % (F2 du cahier des charges) serait contournable.
  collectCoverageFrom: ['src/**/*.js'],

  // Génère reports/junit.xml, lu par la section "reports" de buildspec.yml
  // (nécessite : npm install --save-dev jest-junit)
  reporters: [
    'default',
    ['jest-junit', { outputDirectory: 'reports', outputName: 'junit.xml' }],
  ],
};
