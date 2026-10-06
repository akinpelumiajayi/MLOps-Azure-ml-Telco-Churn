using 'main.bicep'

// Values come from GitHub repo variables via the infra workflow's env,
// falling back to these defaults for local `az deployment group create`.
param prefix = 'mlops'
param isolationMode = readEnvironmentVariable('AML_ISOLATION_MODE', 'AllowInternetOutbound')
param enablePrivateEndpoints = bool(readEnvironmentVariable('AML_PRIVATE_ENDPOINTS', 'false'))
param alertEmail = readEnvironmentVariable('ALERT_EMAIL', '')
