using '../main.bicep'

param projectName = 'taskmanager'
param environment = 'prod'
param location = 'westeurope'

// Set a real address before deploying prod - unlike dev, prod alerts should
// always have a subscriber from the first deployment onward.
param alertEmail = 'khaoula.mechria@supcom.tn'

param enableAppInsights = true
