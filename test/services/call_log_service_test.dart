import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:family_call/services/call_log_service.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('CallLogService.loadLogs', () {
    test('returns empty list when no data stored', () async {
      final svc = CallLogService();
      expect(await svc.loadLogs(), isEmpty);
    });

    test('round-trips a saved entry', () async {
      final svc = CallLogService();
      final entry = CallLogEntry(
        callId: 'alice_bob_1000',
        role: 'caller',
        remoteUserId: 'bob',
        turnServer: 'both',
        startedAt: DateTime.now(),
      );

      await svc.saveEntry(entry);
      final logs = await svc.loadLogs();

      expect(logs, hasLength(1));
      expect(logs.first.callId, 'alice_bob_1000');
    });

    test('returns empty list and clears storage when JSON is corrupted',
        () async {
      // Inject corrupted JSON directly into SharedPreferences.
      SharedPreferences.setMockInitialValues({'call_logs': 'not-valid-json'});

      final svc = CallLogService();
      final result = await svc.loadLogs();

      expect(result, isEmpty);

      // Verify the corrupted key was cleared so the next launch is safe.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('call_logs'), isNull);
    });
  });

  group('CallLogService.saveEntry', () {
    test('does not throw when called concurrently after a corrupted state',
        () async {
      SharedPreferences.setMockInitialValues({'call_logs': '[invalid}'});

      final svc = CallLogService();
      final entry = CallLogEntry(
        callId: 'x_y_1',
        role: 'callee',
        remoteUserId: 'x',
        turnServer: 'metered',
        startedAt: DateTime.now(),
      );

      // Should not throw even though existing data is corrupt.
      await expectLater(svc.saveEntry(entry), completes);
    });
  });
}
