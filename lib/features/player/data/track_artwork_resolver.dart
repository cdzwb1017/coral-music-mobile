import '../../../domain/music.dart';
import '../../leaderboard/data/online_catalog_service.dart';

/// Resolves missing cover artwork by searching online catalogs by song name.
final class TrackArtworkResolver {
  const TrackArtworkResolver(this._services);

  final Map<OnlineSource, OnlineCatalogService> _services;

  Future<Uri?> resolve(Track track) async {
    if (track.coverUri != null) return track.coverUri;
    final sources = track.sourceKind == TrackSourceKind.online
        ? [_sourceFor(track.sourceId)].whereType<OnlineSource>()
        : track.sourceKind == TrackSourceKind.webdav ||
                track.sourceKind == TrackSourceKind.local
            ? OnlineSource.values.where(_services.containsKey)
            : const <OnlineSource>[];
    final query = '${track.title} ${track.artist}'.trim();
    if (query.isEmpty) return null;
    for (final source in sources) {
      final service = _services[source];
      if (service == null) continue;
      try {
        final result = await service.searchTracks(source, query, 1);
        for (final candidate in result.items) {
          if (candidate.coverUri != null) return candidate.coverUri;
        }
      } on Object {
        // Best-effort artwork lookup; failures are not user-facing.
      }
    }
    return null;
  }

  static OnlineSource? _sourceFor(String sourceId) => switch (sourceId) {
        'kw' => OnlineSource.kuwo,
        'kg' => OnlineSource.kugou,
        'tx' => OnlineSource.qq,
        'wy' => OnlineSource.netease,
        'mg' => OnlineSource.migu,
        _ => null,
      };
}
