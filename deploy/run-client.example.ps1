$env:RELAY_SERVER_URL = "https://debug.example.com"
$env:AGENT_ENROLLMENT_TOKEN = "replace-with-agent-enrollment-token"
$env:AGENT_VERSION = "1.0.0"

& "$PSScriptRoot\client_debug_agent.exe"
