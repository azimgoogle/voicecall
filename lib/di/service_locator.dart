import 'package:get_it/get_it.dart';

import '../interfaces/call_log_repository.dart';
import '../interfaces/peer_connection_service.dart';
import '../interfaces/settings_repository.dart';
import '../interfaces/signaling_service.dart';
import '../services/call_log_service.dart';
import '../services/firebase_signaling.dart';
import '../services/settings_service.dart';
import '../services/webrtc_service.dart';
import '../viewmodels/home_view_model.dart';

final GetIt sl = GetIt.instance;

/// Register all services and view-models against their interfaces.
///
/// To swap an implementation, change only the right-hand side here —
/// no screen or business logic needs to change.
///
/// Examples:
///   sl.registerLazySingleton<SignalingService>(() => WebSocketSignaling());
///   sl.registerLazySingleton<PeerConnectionService>(() => NativePeerConnection());
void setupServiceLocator() {
  sl.registerLazySingleton<SignalingService>(() => FirebaseSignaling());
  sl.registerLazySingleton<PeerConnectionService>(() => WebRtcService());
  sl.registerLazySingleton<CallLogRepository>(() => CallLogService());
  sl.registerLazySingleton<SettingsRepository>(() => SettingsService());

  // ViewModel: factory so each HomeScreen mount gets a fresh instance,
  // while still receiving the singleton services it depends on.
  sl.registerFactory<HomeViewModel>(() => HomeViewModel(
        signaling: sl<SignalingService>(),
        peerConnection: sl<PeerConnectionService>(),
        logRepository: sl<CallLogRepository>(),
        settings: sl<SettingsRepository>(),
      ));
}
