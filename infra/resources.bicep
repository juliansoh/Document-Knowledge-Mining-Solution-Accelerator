@description('The location used for all deployed resources')
param location string = resourceGroup().location

@description('Tags that will be applied to all resources')
param tags object = {}


param microsoftGsDpsHostExists bool
@secure()
param microsoftGsDpsHostDefinition object
param frontendAppExists bool
@secure()
param frontendAppDefinition object
param serviceExists bool
@secure()
param serviceDefinition object

@description('Id of the user or app to assign application roles')
param principalId string

var abbrs = loadJsonContent('./abbreviations.json')
var resourceToken = uniqueString(subscription().id, resourceGroup().id, location)

// Monitor application with Azure Monitor
module monitoring 'br/public:avm/ptn/azd/monitoring:0.1.0' = {
  name: 'monitoring'
  params: {
    logAnalyticsName: '${abbrs.operationalInsightsWorkspaces}${resourceToken}'
    applicationInsightsName: '${abbrs.insightsComponents}${resourceToken}'
    applicationInsightsDashboardName: '${abbrs.portalDashboards}${resourceToken}'
    location: location
    tags: tags
  }
}

// Container registry
module containerRegistry 'br/public:avm/res/container-registry/registry:0.1.1' = {
  name: 'registry'
  params: {
    name: '${abbrs.containerRegistryRegistries}${resourceToken}'
    location: location
    acrAdminUserEnabled: true
    tags: tags
    publicNetworkAccess: 'Enabled'
    roleAssignments:[
      {
        principalId: microsoftGsDpsHostIdentity.outputs.principalId
        principalType: 'ServicePrincipal'
        roleDefinitionIdOrName: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
      }
      {
        principalId: frontendAppIdentity.outputs.principalId
        principalType: 'ServicePrincipal'
        roleDefinitionIdOrName: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
      }
      {
        principalId: serviceIdentity.outputs.principalId
        principalType: 'ServicePrincipal'
        roleDefinitionIdOrName: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
      }
    ]
  }
}

// Container apps environment
module containerAppsEnvironment 'br/public:avm/res/app/managed-environment:0.4.5' = {
  name: 'container-apps-environment'
  params: {
    logAnalyticsWorkspaceResourceId: monitoring.outputs.logAnalyticsWorkspaceResourceId
    name: '${abbrs.appManagedEnvironments}${resourceToken}'
    location: location
    zoneRedundant: false
  }
}

module microsoftGsDpsHostIdentity 'br/public:avm/res/managed-identity/user-assigned-identity:0.2.1' = {
  name: 'microsoftGsDpsHostidentity'
  params: {
    name: '${abbrs.managedIdentityUserAssignedIdentities}microsoftGsDpsHost-${resourceToken}'
    location: location
  }
}

module microsoftGsDpsHostFetchLatestImage './modules/fetch-container-image.bicep' = {
  name: 'microsoftGsDpsHost-fetch-image'
  params: {
    exists: microsoftGsDpsHostExists
    name: 'microsoft-gs-dps-host'
  }
}

var microsoftGsDpsHostAppSettingsArray = filter(array(microsoftGsDpsHostDefinition.settings), i => i.name != '')
var microsoftGsDpsHostSecrets = map(filter(microsoftGsDpsHostAppSettingsArray, i => i.?secret != null), i => {
  name: i.name
  value: i.value
  secretRef: i.?secretRef ?? take(replace(replace(toLower(i.name), '_', '-'), '.', '-'), 32)
})
var microsoftGsDpsHostEnv = map(filter(microsoftGsDpsHostAppSettingsArray, i => i.?secret == null), i => {
  name: i.name
  value: i.value
})

module microsoftGsDpsHost 'br/public:avm/res/app/container-app:0.8.0' = {
  name: 'microsoftGsDpsHost'
  params: {
    name: 'microsoft-gs-dps-host'
    ingressTargetPort: 80
    corsPolicy: {
      allowedOrigins: [
        'https://frontend-app.${containerAppsEnvironment.outputs.defaultDomain}'
      ]
      allowedMethods: [
        '*'
      ]
    }
    scaleMinReplicas: 1
    scaleMaxReplicas: 10
    secrets: {
      secureList:  union([
      ],
      map(microsoftGsDpsHostSecrets, secret => {
        name: secret.secretRef
        value: secret.value
      }))
    }
    containers: [
      {
        image: microsoftGsDpsHostFetchLatestImage.outputs.?containers[?0].?image ?? 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'
        name: 'main'
        resources: {
          cpu: json('0.5')
          memory: '1.0Gi'
        }
        env: union([
          {
            name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
            value: monitoring.outputs.applicationInsightsConnectionString
          }
          {
            name: 'AZURE_CLIENT_ID'
            value: microsoftGsDpsHostIdentity.outputs.clientId
          }
          {
            name: 'PORT'
            value: '80'
          }
        ],
        microsoftGsDpsHostEnv,
        map(microsoftGsDpsHostSecrets, secret => {
            name: secret.name
            secretRef: secret.secretRef
        }))
      }
    ]
    managedIdentities:{
      systemAssigned: false
      userAssignedResourceIds: [microsoftGsDpsHostIdentity.outputs.resourceId]
    }
    registries:[
      {
        server: containerRegistry.outputs.loginServer
        identity: microsoftGsDpsHostIdentity.outputs.resourceId
      }
    ]
    environmentResourceId: containerAppsEnvironment.outputs.resourceId
    location: location
    tags: union(tags, { 'azd-service-name': 'microsoft-gs-dps-host' })
  }
}

module frontendAppIdentity 'br/public:avm/res/managed-identity/user-assigned-identity:0.2.1' = {
  name: 'frontendAppidentity'
  params: {
    name: '${abbrs.managedIdentityUserAssignedIdentities}frontendApp-${resourceToken}'
    location: location
  }
}

module frontendAppFetchLatestImage './modules/fetch-container-image.bicep' = {
  name: 'frontendApp-fetch-image'
  params: {
    exists: frontendAppExists
    name: 'frontend-app'
  }
}

var frontendAppAppSettingsArray = filter(array(frontendAppDefinition.settings), i => i.name != '')
var frontendAppSecrets = map(filter(frontendAppAppSettingsArray, i => i.?secret != null), i => {
  name: i.name
  value: i.value
  secretRef: i.?secretRef ?? take(replace(replace(toLower(i.name), '_', '-'), '.', '-'), 32)
})
var frontendAppEnv = map(filter(frontendAppAppSettingsArray, i => i.?secret == null), i => {
  name: i.name
  value: i.value
})

module frontendApp 'br/public:avm/res/app/container-app:0.8.0' = {
  name: 'frontendApp'
  params: {
    name: 'frontend-app'
    ingressTargetPort: 5900
    scaleMinReplicas: 1
    scaleMaxReplicas: 10
    secrets: {
      secureList:  union([
      ],
      map(frontendAppSecrets, secret => {
        name: secret.secretRef
        value: secret.value
      }))
    }
    containers: [
      {
        image: frontendAppFetchLatestImage.outputs.?containers[?0].?image ?? 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'
        name: 'main'
        resources: {
          cpu: json('0.5')
          memory: '1.0Gi'
        }
        env: union([
          {
            name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
            value: monitoring.outputs.applicationInsightsConnectionString
          }
          {
            name: 'AZURE_CLIENT_ID'
            value: frontendAppIdentity.outputs.clientId
          }
          {
            name: 'MICROSOFT-GS-DPS-HOST_BASE_URL'
            value: 'https://microsoft-gs-dps-host.${containerAppsEnvironment.outputs.defaultDomain}'
          }
          {
            name: 'SERVICE_BASE_URL'
            value: 'https://service.${containerAppsEnvironment.outputs.defaultDomain}'
          }
          {
            name: 'PORT'
            value: '5900'
          }
        ],
        frontendAppEnv,
        map(frontendAppSecrets, secret => {
            name: secret.name
            secretRef: secret.secretRef
        }))
      }
    ]
    managedIdentities:{
      systemAssigned: false
      userAssignedResourceIds: [frontendAppIdentity.outputs.resourceId]
    }
    registries:[
      {
        server: containerRegistry.outputs.loginServer
        identity: frontendAppIdentity.outputs.resourceId
      }
    ]
    environmentResourceId: containerAppsEnvironment.outputs.resourceId
    location: location
    tags: union(tags, { 'azd-service-name': 'frontend-app' })
  }
}

module serviceIdentity 'br/public:avm/res/managed-identity/user-assigned-identity:0.2.1' = {
  name: 'serviceidentity'
  params: {
    name: '${abbrs.managedIdentityUserAssignedIdentities}service-${resourceToken}'
    location: location
  }
}

module serviceFetchLatestImage './modules/fetch-container-image.bicep' = {
  name: 'service-fetch-image'
  params: {
    exists: serviceExists
    name: 'service'
  }
}

var serviceAppSettingsArray = filter(array(serviceDefinition.settings), i => i.name != '')
var serviceSecrets = map(filter(serviceAppSettingsArray, i => i.?secret != null), i => {
  name: i.name
  value: i.value
  secretRef: i.?secretRef ?? take(replace(replace(toLower(i.name), '_', '-'), '.', '-'), 32)
})
var serviceEnv = map(filter(serviceAppSettingsArray, i => i.?secret == null), i => {
  name: i.name
  value: i.value
})

module service 'br/public:avm/res/app/container-app:0.8.0' = {
  name: 'service'
  params: {
    name: 'service'
    ingressTargetPort: 80
    corsPolicy: {
      allowedOrigins: [
        'https://frontend-app.${containerAppsEnvironment.outputs.defaultDomain}'
      ]
      allowedMethods: [
        '*'
      ]
    }
    scaleMinReplicas: 1
    scaleMaxReplicas: 10
    secrets: {
      secureList:  union([
      ],
      map(serviceSecrets, secret => {
        name: secret.secretRef
        value: secret.value
      }))
    }
    containers: [
      {
        image: serviceFetchLatestImage.outputs.?containers[?0].?image ?? 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'
        name: 'main'
        resources: {
          cpu: json('0.5')
          memory: '1.0Gi'
        }
        env: union([
          {
            name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
            value: monitoring.outputs.applicationInsightsConnectionString
          }
          {
            name: 'AZURE_CLIENT_ID'
            value: serviceIdentity.outputs.clientId
          }
          {
            name: 'PORT'
            value: '80'
          }
        ],
        serviceEnv,
        map(serviceSecrets, secret => {
            name: secret.name
            secretRef: secret.secretRef
        }))
      }
    ]
    managedIdentities:{
      systemAssigned: false
      userAssignedResourceIds: [serviceIdentity.outputs.resourceId]
    }
    registries:[
      {
        server: containerRegistry.outputs.loginServer
        identity: serviceIdentity.outputs.resourceId
      }
    ]
    environmentResourceId: containerAppsEnvironment.outputs.resourceId
    location: location
    tags: union(tags, { 'azd-service-name': 'service' })
  }
}
// Create a keyvault to store secrets
module keyVault 'br/public:avm/res/key-vault/vault:0.6.1' = {
  name: 'keyvault'
  params: {
    name: '${abbrs.keyVaultVaults}${resourceToken}'
    location: location
    tags: tags
    enableRbacAuthorization: false
    accessPolicies: [
      {
        objectId: principalId
        permissions: {
          secrets: [ 'get', 'list' ]
        }
      }
      {
        objectId: microsoftGsDpsHostIdentity.outputs.principalId
        permissions: {
          secrets: [ 'get', 'list' ]
        }
      }
      {
        objectId: frontendAppIdentity.outputs.principalId
        permissions: {
          secrets: [ 'get', 'list' ]
        }
      }
      {
        objectId: serviceIdentity.outputs.principalId
        permissions: {
          secrets: [ 'get', 'list' ]
        }
      }
    ]
    secrets: [
    ]
  }
}
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = containerRegistry.outputs.loginServer
output AZURE_KEY_VAULT_ENDPOINT string = keyVault.outputs.uri
output AZURE_KEY_VAULT_NAME string = keyVault.outputs.name
output AZURE_RESOURCE_MICROSOFT_GS_DPS_HOST_ID string = microsoftGsDpsHost.outputs.resourceId
output AZURE_RESOURCE_FRONTEND_APP_ID string = frontendApp.outputs.resourceId
output AZURE_RESOURCE_SERVICE_ID string = service.outputs.resourceId
