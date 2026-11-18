import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/models/companion_remote/remote_command.dart';
import 'package:plezy/models/mpv_config_models.dart';
import 'package:plezy/models/trakt/trakt_ids.dart';

void main() {
  group('JSON model round trips', () {
    test('MpvPreset preserves ISO timestamp shape', () {
      final createdAt = DateTime.utc(2024, 1, 2, 3, 4, 5);
      final preset = MpvPreset(name: 'Anime', text: 'profile=gpu-hq', createdAt: createdAt);

      expect(preset.toJson(), {'name': 'Anime', 'text': 'profile=gpu-hq', 'createdAt': createdAt.toIso8601String()});

      final decoded = MpvPreset.fromJson(preset.toJson());
      expect(decoded.name, preset.name);
      expect(decoded.text, preset.text);
      expect(decoded.createdAt, createdAt);
    });

    test('TraktIds omits null fields and accepts numeric ids', () {
      const ids = TraktIds(imdb: 'tt123', tmdb: 42);

      expect(ids.toJson(), {'imdb': 'tt123', 'tmdb': 42});

      final decoded = TraktIds.fromJson({'trakt': 1.0, 'slug': 'movie', 'tmdb': 42.0, 'tvdb': 9});
      expect(decoded.trakt, 1);
      expect(decoded.slug, 'movie');
      expect(decoded.tmdb, 42);
      expect(decoded.tvdb, 9);
      expect(decoded.hasAny, isTrue);
    });

    test('RemoteCommand keeps compact protocol keys and unknown fallback', () {
      const command = RemoteCommand(type: RemoteCommandType.volumeSet, data: {'value': 50});

      expect(command.toJson(), {
        't': RemoteCommandType.volumeSet.index,
        'd': {'value': 50},
      });

      final decoded = RemoteCommand.fromJson(command.toJson());
      expect(decoded.type, RemoteCommandType.volumeSet);
      expect(decoded.data, {'value': 50});

      final unknown = RemoteCommand.fromJson({'t': 999});
      expect(unknown.type, RemoteCommandType.ping);
    });
  });
}
