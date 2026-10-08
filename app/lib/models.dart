enum StatusKind { success, warning, error, neutral, pending }

StatusKind statusKindFromString(String? value) => switch (value) {
  'success' => StatusKind.success,
  'warning' => StatusKind.warning,
  'error' => StatusKind.error,
  'pending' => StatusKind.pending,
  _ => StatusKind.neutral,
};

class AdapterSummary {
  const AdapterSummary({
    required this.alias,
    required this.description,
    required this.status,
    required this.macAddress,
    required this.linkSpeed,
    required this.interfaceIndex,
    required this.adapterType,
    required this.canConfigure,
    required this.isSwitchUplink,
    required this.notice,
  });

  factory AdapterSummary.fromJson(Map<String, dynamic> json) => AdapterSummary(
    alias: json['alias'] as String? ?? '',
    description: json['description'] as String? ?? '',
    status: json['status'] as String? ?? 'Unknown',
    macAddress: json['macAddress'] as String? ?? '',
    linkSpeed: json['linkSpeed'] as String? ?? '',
    interfaceIndex: (json['interfaceIndex'] as num?)?.toInt() ?? 0,
    adapterType: json['adapterType'] as String? ?? 'Network adapter',
    canConfigure: json['canConfigure'] as bool? ?? false,
    isSwitchUplink: json['isSwitchUplink'] as bool? ?? false,
    notice: json['notice'] as String? ?? '',
  );

  final String alias;
  final String description;
  final String status;
  final String macAddress;
  final String linkSpeed;
  final int interfaceIndex;
  final String adapterType;
  final bool canConfigure;
  final bool isSwitchUplink;
  final String notice;
}

class Ipv4AddressInfo {
  const Ipv4AddressInfo({
    required this.address,
    required this.prefixLength,
    required this.subnetMask,
    required this.origin,
  });

  factory Ipv4AddressInfo.fromJson(Map<String, dynamic> json) =>
      Ipv4AddressInfo(
        address: json['address'] as String? ?? '',
        prefixLength: (json['prefixLength'] as num?)?.toInt() ?? 24,
        subnetMask: json['subnetMask'] as String? ?? '255.255.255.0',
        origin: json['origin'] as String? ?? '',
      );

  final String address;
  final int prefixLength;
  final String subnetMask;
  final String origin;
}

class DhcpDetection {
  const DhcpDetection({
    required this.kind,
    required this.label,
    required this.detail,
  });

  factory DhcpDetection.fromJson(Map<String, dynamic>? json) => DhcpDetection(
    kind: statusKindFromString(json?['state'] as String?),
    label: json?['label'] as String? ?? 'Not checked',
    detail: json?['detail'] as String? ?? '',
  );

  final StatusKind kind;
  final String label;
  final String detail;
}

class AdapterDiagnostics {
  const AdapterDiagnostics({
    required this.internet,
    required this.dns,
    required this.dhcp,
    required this.error,
  });

  factory AdapterDiagnostics.fromJson(Map<String, dynamic> json) =>
      AdapterDiagnostics(
        internet: json['internet'] as bool? ?? false,
        dns: json['dns'] as bool? ?? false,
        dhcp: DhcpDetection.fromJson(
          json['dhcp'] == null
              ? null
              : Map<String, dynamic>.from(json['dhcp'] as Map),
        ),
        error: json['error'] as String? ?? '',
      );

  final bool internet;
  final bool dns;
  final DhcpDetection dhcp;
  final String error;
}

class AdapterDetails {
  const AdapterDetails({
    required this.alias,
    required this.description,
    required this.status,
    required this.macAddress,
    required this.linkSpeed,
    required this.adapterType,
    required this.canConfigure,
    required this.notice,
    required this.ipv4,
    required this.ipv6,
    required this.internet,
    required this.dns,
    required this.dhcp,
    this.interfaceIndex = 0,
  });

  factory AdapterDetails.fromJson(Map<String, dynamic> json) => AdapterDetails(
    alias: json['alias'] as String? ?? '',
    interfaceIndex: (json['interfaceIndex'] as num?)?.toInt() ?? 0,
    description: json['description'] as String? ?? '',
    status: json['status'] as String? ?? 'Unknown',
    macAddress: json['macAddress'] as String? ?? '',
    linkSpeed: json['linkSpeed'] as String? ?? '',
    adapterType: json['adapterType'] as String? ?? 'Network adapter',
    canConfigure: json['canConfigure'] as bool? ?? false,
    notice: json['notice'] as String? ?? '',
    ipv4: ((json['ipv4'] as List<dynamic>?) ?? const [])
        .map(
          (item) =>
              Ipv4AddressInfo.fromJson(Map<String, dynamic>.from(item as Map)),
        )
        .toList(),
    ipv6: ((json['ipv6'] as List<dynamic>?) ?? const [])
        .map((item) => item.toString())
        .toList(),
    internet: json['internet'] as bool? ?? false,
    dns: json['dns'] as bool? ?? false,
    dhcp: DhcpDetection.fromJson(
      json['dhcp'] == null
          ? null
          : Map<String, dynamic>.from(json['dhcp'] as Map),
    ),
  );

  final String alias;
  final int interfaceIndex;
  final String description;
  final String status;
  final String macAddress;
  final String linkSpeed;
  final String adapterType;
  final bool canConfigure;
  final String notice;
  final List<Ipv4AddressInfo> ipv4;
  final List<String> ipv6;
  final bool internet;
  final bool dns;
  final DhcpDetection dhcp;

  Ipv4AddressInfo? get primaryIpv4 => ipv4.isEmpty ? null : ipv4.first;
}

class ScanPlan {
  const ScanPlan({
    required this.interfaceAlias,
    required this.networkAddress,
    required this.prefixLength,
    required this.hostCount,
  });

  factory ScanPlan.fromJson(Map<String, dynamic> json) => ScanPlan(
    interfaceAlias: json['interfaceAlias'] as String? ?? '',
    networkAddress: json['networkAddress'] as String? ?? '',
    prefixLength: (json['prefixLength'] as num?)?.toInt() ?? 24,
    hostCount: (json['hostCount'] as num?)?.toInt() ?? 0,
  );

  final String interfaceAlias;
  final String networkAddress;
  final int prefixLength;
  final int hostCount;
}

class ScanResult {
  const ScanResult({
    required this.ipAddress,
    required this.hostname,
    required this.macAddress,
  });

  factory ScanResult.fromJson(Map<String, dynamic> json) => ScanResult(
    ipAddress: json['ipAddress'] as String? ?? '',
    hostname: json['hostname'] as String? ?? '',
    macAddress: json['macAddress'] as String? ?? '',
  );

  final String ipAddress;
  final String hostname;
  final String macAddress;
}

class ScanStatus {
  const ScanStatus({
    required this.progress,
    required this.status,
    required this.activeCount,
    required this.complete,
    required this.cancelled,
    required this.error,
    required this.results,
  });

  factory ScanStatus.fromJson(Map<String, dynamic> json) => ScanStatus(
    progress: (json['progress'] as num?)?.toInt() ?? 0,
    status: json['status'] as String? ?? '',
    activeCount: (json['activeCount'] as num?)?.toInt() ?? 0,
    complete: json['complete'] as bool? ?? false,
    cancelled: json['cancelled'] as bool? ?? false,
    error: json['error'] as String? ?? '',
    results: ((json['results'] as List<dynamic>?) ?? const [])
        .map(
          (item) => ScanResult.fromJson(Map<String, dynamic>.from(item as Map)),
        )
        .toList(),
  );

  final int progress;
  final String status;
  final int activeCount;
  final bool complete;
  final bool cancelled;
  final String error;
  final List<ScanResult> results;
}

class DhcpDefaults {
  const DhcpDefaults({
    required this.adapterAlias,
    required this.serverAddress,
    required this.prefixLength,
    required this.subnetMask,
    required this.isStatic,
    required this.poolStart,
    required this.poolSize,
    required this.maxPoolSize,
    required this.leaseMinutes,
  });

  factory DhcpDefaults.fromJson(Map<String, dynamic> json) => DhcpDefaults(
    adapterAlias: json['adapterAlias'] as String? ?? '',
    serverAddress: json['serverAddress'] as String? ?? '',
    prefixLength: (json['prefixLength'] as num?)?.toInt() ?? 24,
    subnetMask: json['subnetMask'] as String? ?? '',
    isStatic: json['isStatic'] as bool? ?? false,
    poolStart: json['poolStart'] as String? ?? '',
    poolSize: (json['poolSize'] as num?)?.toInt() ?? 20,
    maxPoolSize: (json['maxPoolSize'] as num?)?.toInt() ?? 250,
    leaseMinutes: (json['leaseMinutes'] as num?)?.toInt() ?? 120,
  );

  final String adapterAlias;
  final String serverAddress;
  final int prefixLength;
  final String subnetMask;
  final bool isStatic;
  final String poolStart;
  final int poolSize;
  final int maxPoolSize;
  final int leaseMinutes;
}

class DhcpLease {
  const DhcpLease({
    required this.ipAddress,
    required this.macAddress,
    required this.hostName,
    required this.status,
    required this.leasedAt,
    required this.expiresAt,
  });

  factory DhcpLease.fromJson(Map<String, dynamic> json) => DhcpLease(
    ipAddress: json['ipAddress'] as String? ?? '',
    macAddress: json['macAddress'] as String? ?? '',
    hostName: json['hostName'] as String? ?? '',
    status: json['status'] as String? ?? '',
    leasedAt: json['leasedAt'] as String? ?? '',
    expiresAt: json['expiresAt'] as String? ?? '',
  );

  final String ipAddress;
  final String macAddress;
  final String hostName;
  final String status;
  final String leasedAt;
  final String expiresAt;
}

class DhcpState {
  const DhcpState({
    required this.running,
    required this.lastError,
    required this.configuration,
    required this.leases,
  });

  factory DhcpState.fromJson(Map<String, dynamic> json) => DhcpState(
    running: json['running'] as bool? ?? false,
    lastError: json['lastError'] as String? ?? '',
    configuration: json['configuration'] == null
        ? null
        : Map<String, dynamic>.from(json['configuration'] as Map),
    leases: ((json['leases'] as List<dynamic>?) ?? const [])
        .map(
          (item) => DhcpLease.fromJson(Map<String, dynamic>.from(item as Map)),
        )
        .toList(),
  );

  final bool running;
  final String lastError;
  final Map<String, dynamic>? configuration;
  final List<DhcpLease> leases;
}
