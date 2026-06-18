class AgentRegistration {
  const AgentRegistration({
    required this.pcName,
    required this.windowsUser,
    required this.localChromePort,
    required this.agentVersion,
    required this.startedAt,
  });

  final String pcName;
  final String windowsUser;
  final int localChromePort;
  final String agentVersion;
  final DateTime startedAt;

  Map<String, Object?> toJson() => <String, Object?>{
        'pcName': pcName,
        'windowsUser': windowsUser,
        'localChromePort': localChromePort,
        'agentVersion': agentVersion,
        'startedAt': startedAt.toUtc().toIso8601String(),
      };

  static AgentRegistration fromJson(Map<String, Object?> json) {
    final pcName = json['pcName'];
    final windowsUser = json['windowsUser'];
    final localChromePort = json['localChromePort'];
    final agentVersion = json['agentVersion'];
    final startedAt = json['startedAt'];
    if (pcName is! String ||
        windowsUser is! String ||
        localChromePort is! int ||
        agentVersion is! String ||
        startedAt is! String) {
      throw const FormatException('Invalid agent registration.');
    }
    return AgentRegistration(
      pcName: pcName,
      windowsUser: windowsUser,
      localChromePort: localChromePort,
      agentVersion: agentVersion,
      startedAt: DateTime.parse(startedAt),
    );
  }
}
