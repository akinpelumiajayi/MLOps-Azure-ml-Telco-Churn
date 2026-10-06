// Azure ML workspace + dependencies + CPU training cluster, with managed VNet
// isolation, optional private endpoints, diagnostics and alerting.
targetScope = 'resourceGroup'

@minLength(2)
@maxLength(8)
@description('Short lowercase prefix used in resource names.')
param prefix string = 'mlops'

param location string = resourceGroup().location

@description('VM size for the training cluster.')
param computeVmSize string = 'STANDARD_DS3_V2'

param maxNodes int = 2

@description('''Managed VNet for training compute, serverless Spark (monitoring) and online deployments.
AllowInternetOutbound: isolated, internet egress allowed (simplest).
AllowOnlyApprovedOutbound: egress limited to the rules below (Azure provisions a managed firewall, which is billed).
Switching an existing workspace from Disabled requires deleting its compute first; it cannot be switched back.''')
@allowed(['Disabled', 'AllowInternetOutbound', 'AllowOnlyApprovedOutbound'])
param isolationMode string = 'AllowInternetOutbound'

@description('''Put the workspace, storage, Key Vault and ACR behind private endpoints in a customer VNet and
disable their public access. CI must then run on a self-hosted runner inside that VNet (repo variable RUNNER_LABEL).''')
param enablePrivateEndpoints bool = false

param vnetAddressPrefix string = '10.20.0.0/16'
param privateEndpointSubnetPrefix string = '10.20.0.0/24'
@description('Subnet for self-hosted GitHub runners / jump box when private endpoints are enabled.')
param runnerSubnetPrefix string = '10.20.1.0/24'

@description('Email for endpoint failure / latency alerts. Empty = no alerts.')
param alertEmail string = ''

var suffix = uniqueString(resourceGroup().id)
var storageName = take('st${prefix}${suffix}', 24)
var keyVaultName = take('kv-${prefix}-${suffix}', 24)
var acrName = take('cr${prefix}${suffix}', 50)
var workspaceName = 'mlw-${prefix}'
var clusterName = 'cpu-cluster'
var managedVnet = isolationMode != 'Disabled'
// Private endpoints to ACR (managed VNet or customer VNet) require Premium.
var acrSku = managedVnet || enablePrivateEndpoints ? 'Premium' : 'Basic'
var publicAccess = enablePrivateEndpoints ? 'Disabled' : 'Enabled'

// Package feeds the training / scoring environments install from.
var approvedOutboundFqdns = [
  'pypi.org'
  'files.pythonhosted.org'
  'conda.anaconda.org'
  'repo.anaconda.com'
  'conda-forge.org'
]

// ---------------------------------------------------------------- monitoring

resource logs 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: 'log-${prefix}'
  location: location
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: 'appi-${prefix}'
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logs.id
  }
}

// ---------------------------------------------------------- workspace deps

resource storage 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageName
  location: location
  kind: 'StorageV2'
  sku: { name: 'Standard_LRS' }
  properties: {
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    publicNetworkAccess: publicAccess
    networkAcls: {
      defaultAction: enablePrivateEndpoints ? 'Deny' : 'Allow'
      bypass: 'AzureServices'
    }
  }
}

resource keyVault 'Microsoft.KeyVault/vaults@2023-02-01' = {
  name: keyVaultName
  location: location
  properties: {
    tenantId: subscription().tenantId
    sku: { family: 'A', name: 'standard' }
    enableRbacAuthorization: true
    enableSoftDelete: true
    enablePurgeProtection: true
    publicNetworkAccess: publicAccess
    networkAcls: {
      defaultAction: enablePrivateEndpoints ? 'Deny' : 'Allow'
      bypass: 'AzureServices'
    }
  }
}

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: acrName
  location: location
  sku: { name: acrSku }
  properties: {
    adminUserEnabled: false
    publicNetworkAccess: publicAccess
    networkRuleBypassOptions: 'AzureServices'
  }
}

// ----------------------------------------------------------------- workspace

resource workspace 'Microsoft.MachineLearningServices/workspaces@2024-04-01' = {
  name: workspaceName
  location: location
  kind: 'Default'
  identity: { type: 'SystemAssigned' }
  sku: { name: 'Basic', tier: 'Basic' }
  properties: {
    friendlyName: workspaceName
    storageAccount: storage.id
    keyVault: keyVault.id
    applicationInsights: appInsights.id
    containerRegistry: acr.id
    publicNetworkAccess: publicAccess
    // With ACR reachable only privately, environment images are built on the cluster.
    imageBuildCompute: managedVnet ? clusterName : null
    managedNetwork: {
      isolationMode: isolationMode
      outboundRules: isolationMode == 'AllowOnlyApprovedOutbound'
        ? toObject(
            approvedOutboundFqdns,
            fqdn => 'allow-${replace(fqdn, '.', '-')}',
            fqdn => {
              type: 'FQDN'
              category: 'UserDefined'
              destination: fqdn
            }
          )
        : {}
    }
  }
}

resource cpuCluster 'Microsoft.MachineLearningServices/workspaces/computes@2024-04-01' = {
  parent: workspace
  name: clusterName
  location: location
  properties: {
    computeType: 'AmlCompute'
    properties: {
      vmSize: computeVmSize
      vmPriority: 'Dedicated'
      // No public IPs on nodes; egress goes through the managed VNet.
      enableNodePublicIp: !managedVnet
      scaleSettings: {
        minNodeCount: 0
        maxNodeCount: maxNodes
        nodeIdleTimeBeforeScaleDown: 'PT5M'
      }
    }
  }
}

// Workspace logs (jobs, compute, deployments) and metrics into Log Analytics.
resource workspaceDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: workspace
  properties: {
    workspaceId: logs.id
    logs: [{ categoryGroup: 'allLogs', enabled: true }]
    metrics: [{ category: 'AllMetrics', enabled: true }]
  }
}

// -------------------------------------------------------- private endpoints

var privateDnsZoneNames = [
  'privatelink.api.azureml.ms'
  'privatelink.notebooks.azure.net'
  'privatelink.blob.${environment().suffixes.storage}'
  'privatelink.file.${environment().suffixes.storage}'
  'privatelink.vaultcore.azure.net'
  'privatelink.azurecr.io'
]

// zones = indexes into privateDnsZoneNames
var privateEndpointDefs = [
  { name: 'workspace', target: workspace.id, groupId: 'amlworkspace', zones: [0, 1] }
  { name: 'blob', target: storage.id, groupId: 'blob', zones: [2] }
  { name: 'file', target: storage.id, groupId: 'file', zones: [3] }
  { name: 'vault', target: keyVault.id, groupId: 'vault', zones: [4] }
  { name: 'registry', target: acr.id, groupId: 'registry', zones: [5] }
]

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = if (enablePrivateEndpoints) {
  name: 'vnet-${prefix}'
  location: location
  properties: {
    addressSpace: { addressPrefixes: [vnetAddressPrefix] }
    subnets: [
      {
        name: 'snet-private-endpoints'
        properties: { addressPrefix: privateEndpointSubnetPrefix }
      }
      {
        name: 'snet-runners'
        properties: { addressPrefix: runnerSubnetPrefix }
      }
    ]
  }
}

resource privateDnsZones 'Microsoft.Network/privateDnsZones@2020-06-01' = [
  for zone in privateDnsZoneNames: if (enablePrivateEndpoints) {
    name: zone
    location: 'global'
  }
]

resource privateDnsLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = [
  for (zone, i) in privateDnsZoneNames: if (enablePrivateEndpoints) {
    parent: privateDnsZones[i]
    name: 'link-${prefix}'
    location: 'global'
    properties: {
      registrationEnabled: false
      virtualNetwork: { id: vnet.id }
    }
  }
]

resource privateEndpoints 'Microsoft.Network/privateEndpoints@2023-11-01' = [
  for pe in privateEndpointDefs: if (enablePrivateEndpoints) {
    name: 'pe-${prefix}-${pe.name}'
    location: location
    properties: {
      subnet: { id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnet.name, 'snet-private-endpoints') }
      privateLinkServiceConnections: [
        {
          name: pe.name
          properties: {
            privateLinkServiceId: pe.target
            groupIds: [pe.groupId]
          }
        }
      ]
    }
  }
]

resource privateDnsZoneGroups 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = [
  for (pe, i) in privateEndpointDefs: if (enablePrivateEndpoints) {
    parent: privateEndpoints[i]
    name: 'default'
    properties: {
      privateDnsZoneConfigs: [
        for z in pe.zones: {
          name: replace(privateDnsZoneNames[z], '.', '-')
          properties: { privateDnsZoneId: privateDnsZones[z].id }
        }
      ]
    }
  }
]

// -------------------------------------------------------------------- alerts
// Online deployments report requests to App Insights (app_insights_enabled: true).

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = if (!empty(alertEmail)) {
  name: 'ag-${prefix}'
  location: 'global'
  properties: {
    groupShortName: take('ml-${prefix}', 12)
    enabled: true
    emailReceivers: [
      {
        name: 'oncall'
        emailAddress: alertEmail
        useCommonAlertSchema: true
      }
    ]
  }
}

var alertDefs = [
  {
    name: 'failed-requests'
    description: 'More than 5 failed scoring requests in 15 minutes'
    metricName: 'requests/failed'
    aggregation: 'Count'
    threshold: 5
  }
  {
    name: 'slow-requests'
    description: 'Average scoring latency above 1 second over 15 minutes'
    metricName: 'requests/duration'
    aggregation: 'Average'
    threshold: 1000
  }
]

resource metricAlerts 'Microsoft.Insights/metricAlerts@2018-03-01' = [
  for a in alertDefs: if (!empty(alertEmail)) {
    name: 'alert-${prefix}-${a.name}'
    location: 'global'
    properties: {
      description: a.description
      severity: 2
      enabled: true
      scopes: [appInsights.id]
      evaluationFrequency: 'PT5M'
      windowSize: 'PT15M'
      criteria: {
        'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
        allOf: [
          {
            name: a.name
            criterionType: 'StaticThresholdCriterion'
            metricNamespace: 'microsoft.insights/components'
            metricName: a.metricName
            operator: 'GreaterThan'
            threshold: a.threshold
            timeAggregation: a.aggregation
          }
        ]
      }
      actions: [{ actionGroupId: actionGroup.id }]
    }
  }
]

output workspaceName string = workspace.name
output appInsightsName string = appInsights.name
output vnetName string = enablePrivateEndpoints ? vnet.name : ''
