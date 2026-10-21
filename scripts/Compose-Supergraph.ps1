$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$arguments = @(
    '-y', '@apollo/rover', 'supergraph', 'compose',
    '--config', (Join-Path $repositoryRoot 'router\supergraph-config.yaml'),
    '--output', (Join-Path $repositoryRoot 'supergraph.graphql'),
    '--elv2-license', 'accept'
)
& npx @arguments
if ($LASTEXITCODE -ne 0) {
    throw 'Apollo Federation composition failed.'
}
