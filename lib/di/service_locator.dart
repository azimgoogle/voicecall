import 'package:get_it/get_it.dart';

import '../services/call_log_service.dart';
import '../services/firebase_signaling.dart';
import '../services/settings_service.dart';
import '../services/webrtc_service.dart';

final GetIt sl = GetIt.instance;

void setupServiceLocator() {
  sl.registerLazySingleton<FirebaseSignaling>(() => FirebaseSignaling());
  sl.registerLazySingleton<WebRtcService>(() => WebRtcService());
  sl.registerLazySingleton<CallLogService>(() => CallLogService());
  sl.registerLazySingleton<SettingsService>(() => SettingsService());
}
