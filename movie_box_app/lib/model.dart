class MovieTitle {
  final String id, path, kind, title, description;
  final String? poster, backdrop, rating, releaseDate, country;
  final int? durationSeconds;
  final List<String> genres;
  final bool available;

  MovieTitle.fromJson(Map<String, dynamic> value)
    : id = '${value['id'] ?? ''}',
      path = '${value['detail_path'] ?? ''}',
      kind = '${value['kind'] ?? ''}',
      title = '${value['title'] ?? ''}',
      description = '${value['description'] ?? ''}',
      poster = value['poster_url'] as String?,
      backdrop = value['backdrop_url'] as String?,
      rating = value['rating']?.toString(),
      releaseDate = value['release_date'] as String?,
      country = value['country'] as String?,
      durationSeconds = value['duration_seconds'] is num
          ? (value['duration_seconds'] as num).round()
          : null,
      genres = (value['genres'] as List? ?? []).map((e) => '$e').toList(),
      available = value['has_resource'] == true;

  Map<String, dynamic> toJson() => {
    'id': id,
    'detail_path': path,
    'kind': kind,
    'title': title,
    'description': description,
    'poster_url': poster,
    'backdrop_url': backdrop,
    'rating': rating,
    'release_date': releaseDate,
    'country': country,
    'duration_seconds': durationSeconds,
    'genres': genres,
    'has_resource': available,
  };
}

class MoviePage {
  final List<MovieTitle> items;
  final int? next;
  MoviePage.fromJson(Map<String, dynamic> data)
    : items = (data['items'] as List? ?? [])
          .map((e) => MovieTitle.fromJson(e as Map<String, dynamic>))
          .toList(),
      next = data['next_page'] as int?;
}

class MovieSection {
  final String title;
  final List<MovieTitle> items;
  MovieSection.fromJson(Map<String, dynamic> data)
    : title = '${data['title'] ?? ''}',
      items = (data['items'] as List? ?? [])
          .map((e) => MovieTitle.fromJson(e as Map<String, dynamic>))
          .toList();
}

class MovieHome {
  final List<MovieTitle> banners;
  final List<MovieSection> sections;
  MovieHome.fromJson(Map<String, dynamic> data)
    : banners = (data['banners'] as List? ?? [])
          .map((e) => MovieTitle.fromJson(e as Map<String, dynamic>))
          .toList(),
      sections = (data['sections'] as List? ?? [])
          .map((e) => MovieSection.fromJson(e as Map<String, dynamic>))
          .toList();
}

class MoviePerson {
  final String name;
  final String? character;
  final String? image;
  MoviePerson.fromJson(Map<String, dynamic> value)
    : name = '${value['name'] ?? ''}',
      character = value['character'] as String?,
      image = value['image_url'] as String?;
}

class MovieDetail {
  final MovieTitle title;
  final List<MovieSeason> seasons;
  final List<MovieTitle> dubs;
  final List<MoviePerson> cast;
  MovieDetail.fromJson(Map<String, dynamic> data)
    : title = MovieTitle.fromJson(data['title'] as Map<String, dynamic>),
      cast = (data['cast'] as List? ?? [])
          .whereType<Map>()
          .map((e) => MoviePerson.fromJson(Map<String, dynamic>.from(e)))
          .where((person) => person.name.isNotEmpty)
          .toList(),
      seasons = (data['seasons'] as List? ?? [])
          .map((e) => MovieSeason.fromJson(e as Map<String, dynamic>))
          .where(
            (season) =>
                data['title']['kind'] != 'movie' &&
                season.number > 0 &&
                season.episodes > 0,
          )
          .toList(),
      dubs = (data['dubs'] as List? ?? [])
          .map(
            (e) => MovieTitle.fromJson({
              'id': e['id'],
              'detail_path': e['detail_path'],
              'title': e['label'],
              'kind': 'dub',
            }),
          )
          .toList();
}

class MovieSeason {
  final int number, episodes;
  final List<int> resolutions;
  MovieSeason.fromJson(Map<String, dynamic> data)
    : number = data['number'] as int,
      episodes = data['episode_count'] as int,
      resolutions = (data['resolutions'] as List? ?? []).cast<int>();
}

class MovieStream {
  final String id, format, resolution, url;
  final Map<String, String> headers;
  final int? size;
  final bool locked;
  MovieStream.fromJson(Map<String, dynamic> data)
    : id = '${data['id'] ?? ''}',
      format = '${data['format'] ?? ''}',
      resolution = '${data['resolutions'] ?? ''}',
      url = '${data['url'] ?? ''}',
      headers = (data['request_headers'] as Map? ?? {}).map(
        (key, value) => MapEntry('$key', '$value'),
      ),
      size = data['size_bytes'] as int?,
      locked = data['vip_locked'] == true;
}

class MoviePlayback {
  final List<MovieStream> streams;
  final bool locked, limited;
  MoviePlayback.fromJson(Map<String, dynamic> data)
    : streams = (data['streams'] as List? ?? [])
          .map((e) => MovieStream.fromJson(e as Map<String, dynamic>))
          .toList(),
      locked = data['vip_locked'] == true,
      limited = data['limited'] == true;
}

class MovieCaption {
  final String label, language, url;
  final Map<String, String> headers;
  MovieCaption.fromJson(Map<String, dynamic> data)
    : label = '${data['label'] ?? ''}',
      language = '${data['language'] ?? ''}',
      url = '${data['url'] ?? ''}',
      headers = (data['request_headers'] as Map? ?? {}).map(
        (key, value) => MapEntry('$key', '$value'),
      );
}

String viewingKey(String path, int season, int episode) =>
    '$path:$season:$episode';

class WatchEntry {
  final MovieTitle title;
  final int season, episode, positionSeconds, durationSeconds;
  WatchEntry(
    this.title,
    this.season,
    this.episode,
    this.positionSeconds,
    this.durationSeconds,
  );
  String get key => viewingKey(title.path, season, episode);
  Map<String, dynamic> toJson() => {
    'title': title.toJson(),
    'season': season,
    'episode': episode,
    'position': positionSeconds,
    'duration': durationSeconds,
  };
  WatchEntry.fromJson(Map<String, dynamic> data)
    : title = MovieTitle.fromJson(data['title'] as Map<String, dynamic>),
      season = data['season'] as int,
      episode = data['episode'] as int,
      positionSeconds = data['position'] as int,
      durationSeconds = data['duration'] as int;
}

class SavedDownload {
  final MovieTitle title;
  final int season, episode;
  final String resolution, path;
  final String? subtitlePath, thumbnailPath;

  /// Copy in the phone's public Downloads folder, when one was made.
  /// Android content URIs are stored as-is; other platforms never set this.
  final String? sharedPath, sharedSubtitlePath;
  SavedDownload(
    this.title,
    this.season,
    this.episode,
    this.resolution,
    this.path,
    this.subtitlePath, {
    this.thumbnailPath,
    this.sharedPath,
    this.sharedSubtitlePath,
  });
  String get key => viewingKey(title.path, season, episode);
  Map<String, dynamic> toJson() => {
    'title': title.toJson(),
    'season': season,
    'episode': episode,
    'resolution': resolution,
    'path': path,
    'subtitle_path': subtitlePath,
    'thumbnail_path': thumbnailPath,
    'shared_path': sharedPath,
    'shared_subtitle_path': sharedSubtitlePath,
  };
  SavedDownload.fromJson(Map<String, dynamic> data)
    : title = MovieTitle.fromJson(data['title'] as Map<String, dynamic>),
      season = data['season'] as int,
      episode = data['episode'] as int,
      resolution = data['resolution'] as String,
      path = data['path'] as String,
      subtitlePath = data['subtitle_path'] as String?,
      thumbnailPath = data['thumbnail_path'] as String?,
      sharedPath = data['shared_path'] as String?,
      sharedSubtitlePath = data['shared_subtitle_path'] as String?;
}
