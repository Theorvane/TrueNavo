import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/admin/admin_workspace.dart';
import 'package:trueraid/features/search/global_search.dart';
import 'package:trueraid/features/search/search_index.dart';
import 'package:truenas_api/truenas_api.dart';

void main() {
  test('scheduled command aliases only navigate to protected workspaces', () {
    for (final query in ['크론', '예약작업', 'cronjob.update']) {
      expect(
        searchNavigation(query).first.workspace,
        SearchWorkspace.cronTasks,
      );
    }
    for (final query in ['부팅 스크립트', 'initshutdownscript.delete']) {
      expect(
        searchNavigation(query).first.workspace,
        SearchWorkspace.initShutdownTasks,
      );
    }
    expect(AdminOperationTile.nativePageForMethod('cronjob.run'), isNull);
  });
  test('global file-service aliases reach protected settings workspaces', () {
    for (final query in ['SMB 서버 설정', 'smb.update', '워크그룹']) {
      expect(
        searchNavigation(query).first.workspace,
        SearchWorkspace.smbSettings,
      );
    }
    for (final query in ['NFS 서버 설정', 'nfs.update', '바인딩']) {
      expect(
        searchNavigation(query).first.workspace,
        SearchWorkspace.nfsSettings,
      );
    }
  });
  test('policy and provider aliases reach dedicated native workspaces', () {
    for (final query in ['알림 정책', 'alertclasses.update']) {
      expect(
        searchNavigation(query).first.workspace,
        SearchWorkspace.alertPolicies,
      );
    }
    for (final query in ['알림 제공자', 'Telegram', 'SNMPTrap']) {
      expect(
        searchNavigation(query).first.workspace,
        SearchWorkspace.notificationProviders,
      );
    }
  });
  test('immutable unique index includes each compiled operation once', () {
    expect(
      navigationSearchIndex.map((e) => e.id).toSet().length,
      navigationSearchIndex.length,
    );
    expect(
      navigationSearchIndex.where((e) => e.operation != null).length,
      adminOperationDefinitions.length,
    );
    expect(() => navigationSearchIndex.clear(), throwsUnsupportedError);
    expect(() => searchNavigation('disk').clear(), throwsUnsupportedError);
  });
  test('empty query offers bounded navigation, not hundreds of actions', () {
    final entries = searchNavigation('   ');
    expect(entries.length, lessThanOrEqualTo(50));
    expect(entries.every((e) => e.operation == null), isTrue);
  });
  test('navigation outside the empty palette remains searchable', () {
    final navigation = navigationSearchIndex
        .where((entry) => entry.operation == null)
        .toList();
    expect(navigation.length, greaterThan(50));
    expect(
      searchNavigation('').map((e) => e.id),
      navigation.take(50).map((e) => e.id),
    );
    final last = navigation.last;
    expect(
      searchNavigation(last.title).any((entry) => entry.id == last.id),
      isTrue,
    );
  });
  test('exact titles, ANDed words and method names are searchable', () {
    expect(searchNavigation('Disks').first.workspace, SearchWorkspace.disks);
    expect(
      searchNavigation('  disk.query ')
          .any((e) => e.operation?.method == 'disk.query'),
      isTrue,
    );
    expect(
      searchNavigation('pool scrub')
          .any((e) => e.workspace == SearchWorkspace.pools),
      isTrue,
    );
    expect(searchNavigation('disk unrelatedword'), isEmpty);
  });
  test('Korean aliases work without private server content', () {
    for (final query in [
      '알림설정',
      '통지',
      'alertservice.update',
      'alertservice.delete',
    ]) {
      expect(
        searchNavigation(query).first.workspace,
        SearchWorkspace.alertSettings,
      );
    }
    for (final query in ['이메일', '전자우편', 'SMTP', 'mail.send']) {
      expect(
        searchNavigation(query).first.workspace,
        SearchWorkspace.emailSettings,
      );
    }
    for (final query in ['시간대', '타임존', '시간서버', 'NTP']) {
      expect(
        searchNavigation(query).first.workspace,
        SearchWorkspace.timeSettings,
      );
    }
    expect(
      searchNavigation('공장 초기화').first.workspace,
      SearchWorkspace.configurationReset,
    );
    expect(
      searchNavigation('설정 복원').first.workspace,
      SearchWorkspace.configurationRestore,
    );
    expect(
      searchNavigation('설정 백업').first.workspace,
      SearchWorkspace.configurationBackup,
    );
    expect(
      searchNavigation('재부팅').first.workspace,
      SearchWorkspace.systemPower,
    );
    expect(searchNavigation('디스크').first.workspace, SearchWorkspace.disks);
    expect(
      searchNavigation('가상 머신').first.workspace,
      SearchWorkspace.virtualMachines,
    );
    expect(searchNavigation('secret-nas-account-from-server'), isEmpty);
  });
  test('oversized text and regex-shaped text cannot run patterns', () {
    expect(searchNavigation('a' * 121), isEmpty);
    expect(searchNavigation('(a+)+[.*'), isEmpty);
    expect(searchNavigation('a').length, lessThanOrEqualTo(50));
  });
  for (final workspace in SearchWorkspace.values) {
    test('${workspace.name} has a concrete navigation destination', () {
      final entry = navigationSearchIndex.singleWhere(
        (e) => e.workspace == workspace,
      );
      final page = navigationSearchPage(entry);
      expect(page, isA<Widget>());
      if (workspace.method != null) {
        expect(
          page.runtimeType,
          AdminOperationTile.nativePageForMethod(workspace.method!)!
              .runtimeType,
        );
      }
    });
  }
}
