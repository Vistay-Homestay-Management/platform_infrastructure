$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$arguments = @(
    '-y', '@apollo/rover@1.0.1', 'supergraph', 'compose',
    '--config', (Join-Path $repositoryRoot 'router\backoffice\supergraph-config.yaml'),
    '--output', (Join-Path $repositoryRoot 'router\backoffice\supergraph.graphql'),
    '--elv2-license', 'accept'
)
& npx @arguments
if ($LASTEXITCODE -ne 0) {
    throw 'Apollo Federation composition failed.'
}
