const _defaultRelayServerUrl =
    String.fromEnvironment('DEFAULT_RELAY_SERVER_URL');
const _defaultAgentEnrollmentToken =
    String.fromEnvironment('DEFAULT_AGENT_ENROLLMENT_TOKEN');
const _defaultAgentVersion = String.fromEnvironment('DEFAULT_AGENT_VERSION');
const _defaultChromePath = String.fromEnvironment('DEFAULT_CHROME_PATH');

final clientBuildDefaults = <String, String>{
  if (_defaultRelayServerUrl.isNotEmpty)
    'RELAY_SERVER_URL': _defaultRelayServerUrl,
  if (_defaultAgentEnrollmentToken.isNotEmpty)
    'AGENT_ENROLLMENT_TOKEN': _defaultAgentEnrollmentToken,
  if (_defaultAgentVersion.isNotEmpty) 'AGENT_VERSION': _defaultAgentVersion,
  if (_defaultChromePath.isNotEmpty) 'CHROME_PATH': _defaultChromePath,
};
