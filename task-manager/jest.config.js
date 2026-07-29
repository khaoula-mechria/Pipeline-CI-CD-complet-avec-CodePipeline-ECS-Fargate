// jest.config.js — configuration des tests de l'application task-manager.
// Vit à la racine de task-manager/ (même niveau que package.json), c'est de là
// que `npm test` est lancé, aussi bien par buildspec.yml que par la CI GitHub.
//
// SOURCE DE VÉRITÉ UNIQUE des reporters et du seuil de couverture : ni
// buildspec.yml ni ci.yml ne doivent passer --coverageReporters en ligne de
// commande, sinon ils ÉCRASENT la liste ci-dessous et n'obtiennent plus ni le
// rapport HTML ni le XML (c'était le cas de buildspec.yml avant le 2026-07-28,
// ce qui rendait US-02 — "un rapport HTML de couverture est disponible dans les
// artefacts CodeBuild" — littéralement impossible à satisfaire).

module.exports = {
  testEnvironment: 'node',
  testMatch: ['**/tests/**/*.test.js'],

  collectCoverage: true,
  coverageDirectory: 'coverage',

  // - text          : lisible directement dans les logs CI
  // - json-summary  : coverage/coverage-summary.json, lu par le quality gate
  //                   de buildspec.yml et de ci.yml
  // - lcov          : produit lcov.info ET le rapport HTML coverage/lcov-report/
  //                   (US-02 : rapport HTML consultable)
  // - cobertura     : coverage/cobertura-coverage.xml — format XML standard,
  //                   exploité nativement par les report groups CodeBuild
  //                   (file-format: COBERTURAXML) et par SonarQube/GitLab/etc.
  coverageReporters: ['text', 'json-summary', 'lcov', 'cobertura'],

  // Sans cette liste, Jest ne mesure QUE les fichiers atteints par un test :
  // ajouter un module non testé ne ferait pas baisser la couverture et le
  // quality gate à 80 % (F2 du cahier des charges) serait contournable.
  collectCoverageFrom: ['src/**/*.js'],

  // Seuil appliqué par Jest lui-même : `npm test` échoue sous 80 %, y compris
  // en local, avant même d'atteindre la CI. Les deux CI revérifient ensuite le
  // seuil à partir de coverage-summary.json — redondant à dessein : ça affiche
  // la valeur mesurée dans le log de build (utile au Tech Lead, US-02) et ça
  // protège le gate si quelqu'un retire ce bloc.
  coverageThreshold: {
    global: {
      lines: 80,
      statements: 80,
      functions: 80,
      branches: 80,
    },
  },

  // Génère reports/junit.xml, lu par la section "reports" de buildspec.yml
  // (nécessite : npm install --save-dev jest-junit)
  reporters: [
    'default',
    ['jest-junit', { outputDirectory: 'reports', outputName: 'junit.xml' }],
  ],
};
