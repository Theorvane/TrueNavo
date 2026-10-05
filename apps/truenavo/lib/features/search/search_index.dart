import 'package:truenas_api/truenas_api.dart';

/// Local, compiled navigation only. Never indexes server values or credentials.
enum SearchWorkspace {
  cronTasks(
    'Cron tasks',
    'Disabled-first scheduled commands, local users and scheduler impact review',
    '크론 예약 명령 예약작업 스케줄 cronjob.create cronjob.update cronjob.delete',
    'cronjob.query',
  ),
  initShutdownTasks(
    'Startup & shutdown tasks',
    'Protected lifecycle commands and explicit root-execution review',
    '시작 종료 부팅 스크립트 초기화 명령 initshutdownscript.create initshutdownscript.update initshutdownscript.delete',
    'initshutdownscript.query',
  ),
  alertPolicies(
    'Alert policies',
    'Per-class severity, notification timing and proactive support safeguards',
    '알림 정책 심각도 주기 숨김 alertclasses.update',
    'alertclasses.config',
  ),
  notificationProviders(
    'Notification providers',
    'Typed external providers, write-only credentials and reviewed enablement',
    '알림 제공자 슬랙 텔레그램 Slack Mattermost Telegram PagerDuty OpsGenie VictorOps AWSSNS InfluxDB SNMPTrap',
    null,
  ),
  alertSettings(
    'Notification services',
    'Email alert destinations, severity thresholds and reviewed enablement',
    '알림 서비스 알림설정 통지 수신자 alertservice.update alertservice.delete',
    'alertservice.query',
  ),
  emailSettings(
    'Email settings',
    'SMTP configuration, protected credentials and reviewed test mail',
    '이메일 메일 SMTP 전자우편 발송 mail.send',
    'mail.config',
  ),
  timeSettings(
    'Time settings',
    'Timezone, configured NTP sources and polling intervals',
    '시간 시간대 타임존 NTP 시간서버 timezone clock',
    'system.ntpserver.query',
  ),
  configurationReset(
    'Factory reset',
    'Review configuration loss, automatic reboot and independent recovery',
    '공장 초기화 설정초기화 factory defaults',
    'config.reset',
  ),
  configurationRestore(
    'Configuration restore',
    'Trusted configuration import, automatic reboot and recovery review',
    '시스템 설정 복원 가져오기 복구',
    'config.upload',
  ),
  configurationBackup(
    'Configuration backup',
    'Sensitive configuration export and protected file storage',
    '시스템 설정 백업 내보내기 저장',
    'config.save',
  ),
  systemPower(
    'System power',
    'Standalone reboot and shutdown readiness and interruption review',
    '시스템 전원 재부팅 종료',
    'system.reboot',
  ),
  rsync(
    'Rsync transfers',
    'SSH PUSH task schedules and explicit transfer jobs',
    '파일 동기화 전송 백업 알싱크',
    'rsynctask.query',
  ),
  administration(
    'Administration',
    'All server settings and workflows',
    '관리 설정',
    null,
  ),
  management(
    'Services & datasets',
    'Reviewed service and dataset controls',
    '서비스 데이터셋',
    null,
  ),
  disks(
    'Disks',
    'Passive inventory, raw capacities and stored settings',
    '디스크 하드 HDD SSD',
    'disk.query',
  ),
  pools(
    'Pool maintenance',
    'Scrub progress and integrity-check schedules',
    '풀 스크럽 검사 예약',
    'pool.scrub.query',
  ),
  shares(
    'File sharing overview',
    'SMB and NFS configuration summary',
    '파일 공유',
    null,
  ),
  protection(
    'Data protection overview',
    'Snapshot, replication, cloud and Rsync policies',
    '데이터 보호 백업',
    null,
  ),
  reporting(
    'Performance history',
    'Recorded metrics, graphs and sample tables',
    '성능 기록 그래프 통계',
    null,
  ),
  network(
    'Network interfaces',
    'Reviewed physical interface settings',
    '네트워크 인터페이스 랜',
    null,
  ),
  apps('Applications', 'Installed apps and catalogue', '앱 애플리케이션 설치', null),
  snapshots(
    'Snapshots',
    'Snapshot inventory and reviewed recovery actions',
    '스냅샷 복구',
    'pool.snapshot.delete',
  ),
  datasets(
    'Dataset properties',
    'Filesystem quotas and inherited properties',
    '데이터셋 속성 할당량',
    null,
  ),
  zvols('Zvols', 'Virtual block storage and provisioning', '볼륨 블록 스토리지', null),
  permissions(
    'Filesystem permissions',
    'POSIX and NFSv4 access-control editor',
    '권한 ACL',
    'filesystem.setacl',
  ),
  quotas(
    'User & group quotas',
    'Exact byte and object limits',
    '사용자 그룹 할당량',
    'pool.dataset.get_quota',
  ),
  snapshotSchedules(
    'Snapshot schedules',
    'Periodic snapshot policies and retention',
    '스냅샷 예약 보존',
    'pool.snapshottask.query',
  ),
  smb(
    'SMB shares',
    'Windows file sharing configuration',
    '윈도우 공유 삼바',
    'sharing.smb.query',
  ),
  nfs(
    'NFS shares',
    'Network filesystem exports',
    '리눅스 공유 내보내기',
    'sharing.nfs.query',
  ),
  smbSettings(
    'SMB server settings',
    'Global identity, multichannel and transport encryption review',
    'SMB 서버 설정 삼바 워크그룹 암호화 smb.update',
    'smb.config',
  ),
  nfsSettings(
    'NFS server settings',
    'Stopped-service protocols, workers, binding and logging settings',
    'NFS 서버 설정 작업자 스레드 바인딩 nfs.update',
    'nfs.config',
  ),
  replication(
    'Replication',
    'Reviewed local replication tasks',
    '복제 전송',
    'replication.query',
  ),
  cloudSync(
    'Cloud Sync',
    'Supported cloud transfer tasks',
    '클라우드 동기화',
    'cloudsync.query',
  ),
  apiKeys(
    'API keys',
    'Own-account key lifecycle and protected disclosure',
    'API 키 인증 토큰',
    'api_key.query',
  ),
  cloudCredentials(
    'Cloud credentials',
    'Protected cloud credential lifecycle',
    '클라우드 자격 인증',
    'cloudsync.credentials.query',
  ),
  ssh(
    'SSH credentials',
    'Keypair and manually trusted SSH connections',
    'SSH 키 연결 인증',
    'keychaincredential.query',
  ),
  alerts(
    'Alert center',
    'Sanitized alerts, charts and reviewed dismissal',
    '알림 경고 알람',
    'alert.list',
  ),
  accounts(
    'Users & groups',
    'Account, membership and privilege inventory',
    '사용자 계정 그룹 권한',
    'user.update',
  ),
  virtualMachines(
    'Virtual machines',
    'VM lifecycle, resources and devices',
    '가상 머신 장치 VM',
    'vm.update',
  ),
  updates(
    'System updates',
    'Release readiness and reviewed update jobs',
    '시스템 업데이트 업그레이드',
    'update.config',
  ),
  boot(
    'Boot environments',
    'Boot environment inventory and activation',
    '부팅 환경',
    'boot.environment.activate',
  ),
  activity(
    'Jobs & audit',
    'Bounded job progress and audit metadata',
    '작업 감사 로그',
    'core.job_abort',
  );

  const SearchWorkspace(
    this.title,
    this.description,
    this.aliases,
    this.method,
  );
  final String title, description, aliases;
  final String? method;
}

final class NavigationSearchEntry {
  const NavigationSearchEntry({
    required this.id,
    required this.title,
    required this.description,
    required this.keywords,
    this.workspace,
    this.domain,
    this.operation,
  });
  final String id, title, description, keywords;
  final SearchWorkspace? workspace;
  final AdminDomain? domain;
  final AdminOperationDefinition? operation;
}

final navigationSearchIndex = List<NavigationSearchEntry>.unmodifiable([
  for (final workspace in SearchWorkspace.values)
    NavigationSearchEntry(
      id: 'workspace.${workspace.name}',
      title: workspace.title,
      description: workspace.description,
      keywords: '${workspace.aliases} ${workspace.method ?? ''}',
      workspace: workspace,
    ),
  for (final domain in AdminDomain.values)
    NavigationSearchEntry(
      id: 'domain.${domain.name}',
      title: domain.label,
      description: 'Browse this administration area',
      keywords: domain.name,
      domain: domain,
    ),
  for (final operation in adminOperationDefinitions)
    NavigationSearchEntry(
      id: 'operation.${operation.id}',
      title: operation.title,
      description: operation.description,
      keywords: '${operation.domain.label} ${operation.method}',
      operation: operation,
    ),
]);

/// Matches bounded plain text, not regex or executable command syntax.
List<NavigationSearchEntry> searchNavigation(String query) {
  final normalized = query.trim().toLowerCase();
  if (normalized.length > 120) return const [];
  if (normalized.isEmpty) {
    return List.unmodifiable(
      navigationSearchIndex.where((entry) => entry.operation == null).take(50),
    );
  }
  final words = normalized.split(RegExp(r'\s+'));
  final matches = navigationSearchIndex.where((entry) {
    final haystack = '${entry.title} ${entry.description} ${entry.keywords}'
        .toLowerCase();
    return words.every(haystack.contains);
  }).toList();
  int score(NavigationSearchEntry entry) {
    final title = entry.title.toLowerCase();
    return (title == normalized
            ? 0
            : title.startsWith(normalized)
            ? 10
            : 20) +
        (entry.workspace != null
            ? 0
            : entry.domain != null
            ? 1
            : 2);
  }

  matches.sort((a, b) {
    final rank = score(a).compareTo(score(b));
    return rank != 0 ? rank : a.id.compareTo(b.id);
  });
  return List.unmodifiable(matches.take(50));
}
