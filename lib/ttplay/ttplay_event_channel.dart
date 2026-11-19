import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../media/ids.dart';
import '../media/library_change_event.dart';
import '../session/app_session_models.dart';
import '../utils/app_logger.dart';

/// Server-Sent Events push channel subscribing to `ttplay-server` `/api/v1/events`.
class TtplayEventChannel implements LibraryEventChannel {
  TtplayEventChannel({
    required this.serverId,
    required String baseUrl,
    required this.accessToken,
    this.onRawEvent,
    this.coalesceDuration = const Duration(milliseconds: 500),
  }) : baseUrl = SelfHostedSession.normalizeServerUrl(baseUrl);

  final ServerId serverId;
  final String baseUrl;
  final String accessToken;
  final void Function(String event, Map<String, dynamic> data)? onRawEvent;
  final Duration coalesceDuration;

  static const List<Duration> _backoff = [
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 15),
    Duration(seconds: 30),
  ];
  static const int _maxRetries = 6;
  static const Set<String> _libraryEvents = {'library_changed', 'scan_done', 'scrape_done', 'item_updated'};

  final _controller = StreamController<LibraryChangeEvent>.broadcast();
  HttpClient? _client;
  Timer? _reconnectTimer;
  Timer? _coalesceTimer;
  bool _running = false;
  bool _disposed = false;
  int _generation = 0;
  int _retryAttempt = 0;

  @override
  Stream<LibraryChangeEvent> get events => _controller.stream;

  @override
  void start() {
    if (_disposed || _running) return;
    _running = true;
    _retryAttempt = 0;
    final gen = ++_generation;
    unawaited(_connectLoop(gen));
  }

  @override
  void stop() {
    if (!_running && _client == null) return;
    _running = false;
    _generation++;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _coalesceTimer?.cancel();
    _coalesceTimer = null;
    _client?.close(force: true);
    _client = null;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    stop();
    if (!_controller.isClosed) {
      unawaited(_controller.close());
    }
  }

  Future<void> _connectLoop(int gen) async {
    if (_disposed || !_running || gen != _generation) return;

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    _client = client;
    var receivedData = false;

    try {
      final uri = Uri.parse('$baseUrl/api/v1/events');
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $accessToken');
      request.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
      request.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');

      final response = await request.close();
      if (!_running || _disposed || gen != _generation) return;
      if (response.statusCode == HttpStatus.unauthorized || response.statusCode == HttpStatus.forbidden) {
        appLogger.w('TtplayEventChannel unauthorized (${response.statusCode}); stopping SSE');
        stop();
        return;
      }
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('SSE HTTP ${response.statusCode}', uri: uri);
      }

      var currentEvent = '';
      final dataLines = <String>[];

      void dispatchFrame() {
        final rawData = dataLines.join('\n').trim();
        final eventName = currentEvent.trim();
        currentEvent = '';
        dataLines.clear();
        if (rawData.isEmpty && eventName.isEmpty) return;
        _handleSseFrame(eventName, rawData);
      }

      await for (final line in response.transform(utf8.decoder).transform(const LineSplitter())) {
        if (!_running || _disposed || gen != _generation) break;
        if (!receivedData) {
          receivedData = true;
          _retryAttempt = 0;
        }
        if (line.isEmpty) {
          dispatchFrame();
          continue;
        }
        if (line.startsWith(':')) continue;
        if (line.startsWith('event:')) {
          currentEvent = line.substring('event:'.length).trim();
        } else if (line.startsWith('data:')) {
          dataLines.add(line.substring('data:'.length).trimLeft());
        }
      }
      if (_running && !_disposed && gen == _generation) {
        dispatchFrame();
      }
    } catch (e) {
      if (_running && !_disposed && gen == _generation) {
        appLogger.d('TtplayEventChannel disconnected: $e');
      }
    } finally {
      client.close(force: true);
      if (identical(_client, client)) _client = null;
    }

    if (!_running || _disposed || gen != _generation) return;
    if (_retryAttempt >= _maxRetries) {
      appLogger.d('TtplayEventChannel reached max retries; stopping quietly');
      _running = false;
      return;
    }

    final delay = _backoff[_retryAttempt.clamp(0, _backoff.length - 1)];
    _retryAttempt++;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () {
      if (_running && !_disposed && gen == _generation) {
        unawaited(_connectLoop(gen));
      }
    });
  }

  void _handleSseFrame(String eventName, String rawData) {
    Map<String, dynamic> payload = const {};
    if (rawData.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawData);
        if (decoded is Map) {
          payload = Map<String, dynamic>.from(decoded);
        }
      } catch (_) {}
    }

    if (onRawEvent != null && payload.isNotEmpty) {
      try {
        onRawEvent!(eventName, payload);
      } catch (_) {}
    }

    final effectiveEvent = eventName.isNotEmpty ? eventName : (payload['event'] as String? ?? '');
    if (_libraryEvents.contains(effectiveEvent)) {
      _scheduleLibraryChange();
    }
  }

  void _scheduleLibraryChange() {
    if (_disposed || _controller.isClosed) return;
    _coalesceTimer?.cancel();
    _coalesceTimer = Timer(coalesceDuration, () {
      if (_disposed || _controller.isClosed) return;
      _controller.add(LibraryChangeEvent(serverId: serverId, itemsAdded: true, itemsUpdated: true));
    });
  }
}
