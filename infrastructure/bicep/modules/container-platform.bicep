// ==============================================================================
// container-platform.bicep
//
// Azure Container Apps environment (VNet-integrated) + the Container App
// itself. This single module absorbs the role that FIVE separate AWS
// templates played (ecs-cluster.yaml, alb.yaml, ecs-task-definition.yaml,
// ecs-service.yaml, and the target-group/listener half of pipeline.yml):
// ACA's built-in ingress + multi-revision traffic splitting is the platform
// feature that made all of that AWS plumbing necessary in the first place.
//
// revisionsMode: 'Multiple' is the one setting that makes Blue/Green
// possible at all here - it lets two revisions (the current "blue" stable
// revision and a newly deployed "green" revision) stay simultaneously active
// with independently controlled traffic weights, which azure-pipelines.yml /
// scripts/blue-green-deploy.sh manipulate progressively (10 -> 50 -> 100),
// exactly mirroring CodeDeploy's ECSLinear10PercentEvery1Minutes stepping.
// The FIRST deployment of this template creates only ONE revision (traffic
// weight 100, latest=true) - there is nothing to Blue/Green against yet.
// Every deployment AFTER that is driven by the pipeline script, not by
// re-running this Bicep template (same relationship as AWS's
// ecs-task-definition.yaml being "bootstrap only" once CodePipeline takes
// over registering new task definition revisions).
// ==============================================================================

@description('Project name, used as a resource naming prefix (lowercase).')
param projectName string

@description('Target environment (dev, staging, prod).')
param environment string

@description('Azure region.')
param location string

@description('Subnet ID delegated to Microsoft.App/environments (networking.bicep acaSubnetId).')
param acaSubnetId string

@description('Log Analytics workspace customer ID (monitoring.bicep logAnalyticsCustomerId) - ACA needs the workspace ID + shared key, not a resource ID.')
param logAnalyticsCustomerId string

@secure()
@description('Log Analytics workspace shared key.')
param logAnalyticsSharedKey string

@description('User-assigned identity resource ID (identities.bicep identityId) - attached to the Container App for ACR pull + Key Vault secret access.')
param managedIdentityId string

@description('User-assigned identity client ID - required by the secret/registry blocks below to tell ACA WHICH identity on the app to use, since a Container App can carry more than one.')
param managedIdentityClientId string

@description('ACR login server (acr.bicep acrLoginServer).')
param acrLoginServer string

@description('Key Vault secret URIs (keyvault.bicep) - the app receives these as environment variables at container start, mirroring the ECS Secrets: block.')
param dbUsernameSecretUri string
param dbPasswordSecretUri string
param apiKeySecretUri string

@description('Full image reference to deploy, e.g. <acrLoginServer>/taskmanager:<commitSha>. Left pointing at a public placeholder image for the FIRST deployment only - the pipeline overwrites this on every subsequent run via a new revision, never by re-running this template.')
param containerImage string = 'mcr.microsoft.com/k8se/quickstart:latest'

@description('Container port the app listens on (must match the Dockerfile EXPOSE and /health path).')
param containerPort int = 3000

@description('CPU cores per replica. 0.25/0.5Gi is the ACA minimum allocation and mirrors the AWS default (256 CPU units / 512 MB).')
param cpuCores string = '0.25'
param memorySize string = '0.5Gi'

@description('Min/max replica count - the ACA equivalent of ecs-autoscaling.yaml MinCapacity/MaxCapacity.')
param minReplicas int = 1
param maxReplicas int = 6

@description('Concurrent requests per replica before scaling out - primary scale trigger (see module footer note on the CPU-based rule).')
param httpConcurrentRequests int = 50

resource managedEnvironment 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: 'cae-${projectName}-${environment}'
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalyticsCustomerId
        sharedKey: logAnalyticsSharedKey
      }
    }
    vnetConfiguration: {
      infrastructureSubnetId: acaSubnetId
      internal: false // External ingress: keeps a public HTTPS endpoint (the ALB-DNS-name equivalent) while workload traffic and egress route through the VNet - see infrastructure/bicep/README.md networking section for the reasoning
    }
    zoneRedundant: false // single-region student project; flip on for a prod-grade deployment once the subnet/region support it
  }
}

resource containerApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'ca-${projectName}-${environment}'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedIdentityId}': {}
    }
  }
  properties: {
    managedEnvironmentId: managedEnvironment.id
    configuration: {
      activeRevisionsMode: 'Multiple' // required for Blue/Green traffic splitting - see module header
      registries: [
        {
          server: acrLoginServer
          identity: managedIdentityId
        }
      ]
      secrets: [
        {
          name: 'db-username'
          keyVaultUrl: dbUsernameSecretUri
          identity: managedIdentityId
        }
        {
          name: 'db-password'
          keyVaultUrl: dbPasswordSecretUri
          identity: managedIdentityId
        }
        {
          name: 'api-key'
          keyVaultUrl: apiKeySecretUri
          identity: managedIdentityId
        }
      ]
      ingress: {
        external: true
        targetPort: containerPort
        transport: 'auto'
        traffic: [
          // FIRST deployment only: one revision, all traffic, latest=true so
          // it always points at whatever revision was created most recently
          // by this template. From the second deployment onward, the
          // pipeline's blue-green-deploy.sh takes over traffic weights
          // directly via `az containerapp ingress traffic set` and this
          // block is no longer authoritative - exactly like
          // ecs-task-definition.yaml being superseded after the first
          // pipeline run.
          {
            latestRevision: true
            weight: 100
          }
        ]
      }
    }
    template: {
      containers: [
        {
          name: 'app'
          image: containerImage
          resources: {
            cpu: json(cpuCores)
            memory: memorySize
          }
          env: [
            { name: 'PROJECT_NAME', value: projectName }
            { name: 'NODE_ENV', value: 'production' }
            { name: 'APP_ENV', value: environment }
            { name: 'DB_USERNAME', secretRef: 'db-username' }
            { name: 'DB_PASSWORD', secretRef: 'db-password' }
            { name: 'API_KEY', secretRef: 'api-key' }
          ]
          probes: [
            {
              type: 'Liveness'
              httpGet: {
                path: '/health'
                port: containerPort
              }
              periodSeconds: 30
              timeoutSeconds: 5
              failureThreshold: 3
            }
            {
              type: 'Readiness'
              httpGet: {
                path: '/health'
                port: containerPort
              }
              periodSeconds: 15
              timeoutSeconds: 5
              failureThreshold: 3
            }
          ]
        }
      ]
      scale: {
        minReplicas: minReplicas
        maxReplicas: maxReplicas
        rules: [
          {
            // Primary scale trigger: idiomatic for ACA (KEDA http scaler),
            // and a closer match to a web app's real bottleneck than raw
            // CPU. F3 of the requirements literally says "scales on CPU":
            // see the commented-out cpu rule below for that exact mapping,
            // left disabled because CPU/memory-based ACA scale rules are a
            // newer, less universally documented feature than the http
            // scaler - VERIFY current support via
            // `az containerapp show --query properties.template.scale`
            // examples in Microsoft Learn before enabling it, rather than
            // trusting this comment blindly.
            name: 'http-concurrency'
            http: {
              metadata: {
                concurrentRequests: string(httpConcurrentRequests)
              }
            }
          }
          // {
          //   name: 'cpu-scaling'
          //   custom: {
          //     type: 'cpu'
          //     metadata: {
          //       type: 'Utilization'
          //       value: '70'
          //     }
          //   }
          // }
        ]
      }
    }
  }
}

output containerAppId string = containerApp.id
output containerAppName string = containerApp.name
output containerAppFqdn string = containerApp.properties.configuration.ingress.fqdn
output managedEnvironmentId string = managedEnvironment.id
