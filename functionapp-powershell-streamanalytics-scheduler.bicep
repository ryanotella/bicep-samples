param context object

param workloadStorageName string
param streamAnalyticsJobName string

// Create App Service Plan
resource appServicePlan 'Microsoft.Web/serverfarms@2022-09-01' = {
  name: '${context.prefix}-${context.qualifier}-scheduler-asp'
  location: context.location
  sku: {
    name: 'B1'
  }
  properties: {
    reserved: true
    zoneRedundant: false
  }
  tags: context.tags
}

resource workloadStorage 'Microsoft.Storage/storageAccounts@2021-04-01' existing = {
  name: workloadStorageName
}

// Create Function App with Managed Identity
resource functionApp 'Microsoft.Web/sites@2022-09-01' = {
  name: '${context.prefix}-${context.qualifier}-scheduler-app'
  location: context.location
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: appServicePlan.id
    siteConfig: {

      alwaysOn: true

      linuxFxVersion: 'PowerShell|7.4'
      appSettings: [
        { 
          name: 'AzureFunctionsJobHost__managedDependency__enabled'
          value: 'true'
        }
        {
          name: 'AzureWebJobsStorage'
          value: 'DefaultEndpointsProtocol=https;AccountName=${workloadStorage.name};EndpointSuffix=${environment().suffixes.storage};AccountKey=${workloadStorage.listKeys().keys[0].value}'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'powershell'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME_VERSION'
          value: '7.4'
        }
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
      ]
    }
  }
}


var setupScript = '''
param($Timer)

@'
# Dependencies
@{
    'Az.Accounts' = '2.*'
    'Az.StreamAnalytics' = '2.*'
}
'@ | Out-File 'requirements.psd1' -Force

@'
# Startup Profile

Import-Module Az.Accounts
Import-Module Az.StreamAnalytics

Connect-AzAccount -Identity

$context = Get-AzContext
$context.Account

'@ | Out-File 'profile.ps1' -Force

'''

var streamScript = '''
param($Timer)

'''

// Define all schedules
var schedules = [
  {
    name: 'setup'
    enabled: true
    schedule: '0 0 1 * * *'
    script: setupScript
  }
  {
    name: 'start_stream_analytics_tracking'
    enabled: true
    schedule: '0 0 8 * * 1-5' // 8:00 AM on weekdays
    script: concat(
      streamScript,
      'Start-AzStreamAnalyticsJob -ResourceGroupName "${resourceGroup().name}" -Name "${streamAnalyticsJobName}" -OutputStartMode CustomTimer -OutputStartTime "2020-01-01T00:00:00Z"'
    )
  }
  {
    name: 'stop_stream_analytics_tracking'
    enabled: true
    schedule: '0 0 18 * * 1-5' // 6:00 PM on weekdays
    script: concat(
      streamScript,
      'Stop-AzStreamAnalyticsJob -ResourceGroupName "${resourceGroup().name}" -Name "${streamAnalyticsJobName}"'
    )
  }
]

// Create Functions for each schedule
resource functions 'Microsoft.Web/sites/functions@2022-09-01' = [
  for schedule in schedules: {
    parent: functionApp
    name: schedule.name
    properties: {
      config: {
        disabled: !schedule.enabled
        bindings: [
          {
            name: 'Timer'
            type: 'timerTrigger'
            direction: 'in'
            schedule: schedule.schedule
            runOnStartup: schedule.name == 'setup'
          }
        ]
      }
      files: {
        'run.ps1': schedule.script
      }
    }
  }
]

// Storage Account role assignments
// Stream Analytics role assigments
