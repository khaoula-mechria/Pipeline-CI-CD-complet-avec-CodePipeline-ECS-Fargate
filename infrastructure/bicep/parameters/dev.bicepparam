using '../main.bicep'

param projectName = 'taskmanager'
param environment = 'dev'
param location = 'westeurope'

// Same intent as the AWS AlarmEmail parameter: leave empty and subscribe
// later with `az monitor action-group update` if you don't want an email
// yet, e.g. during teardown/redeploy cycles.
param alertEmail = ''

param enableAppInsights = false
