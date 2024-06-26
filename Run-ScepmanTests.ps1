$config = New-PesterConfiguration

$config.Run.Path = "./Tests"

# Enable Code Coverage
$config.CodeCoverage.Path = "./SCEPman"
$config.CodeCoverage.RecursePaths = $true
$config.CodeCoverage.Enabled = $true
$config.CodeCoverage.OutputFormat = 'CoverageGutters'
$config.CodeCoverage.OutputPath = 'cov.xml'
$config.CodeCoverage.OutputEncoding = 'UTF8'

# Run Pester tests using the configuration you've created
Invoke-Pester -Configuration $config