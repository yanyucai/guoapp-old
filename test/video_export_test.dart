import 'dart:io';

import 'package:duanju_app/core_bridge.dart';
import 'package:duanju_app/media_library.dart';
import 'package:duanju_app/media_pipeline.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/video_export_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

class MockExecutor implements MediaExecutor {
  final List<List<String>> commands = [];
  bool failNextCopy = false;

  @override
  Future<MediaProbe> probe(String file) async => MediaProbe(const {});

  @override
  Future<void> run(
    List<String> arguments, {
    double duration = 0,
    void Function(double)? progress,
  }) async {
    commands.add(List.from(arguments));
    if (failNextCopy && arguments.contains('copy')) {
      failNextCopy = false;
      throw StateError('muxing error');
    }
    final outPath = arguments.last;
    if (outPath.endsWith('.mp4')) {
      File(outPath).writeAsStringSync('transcoded-video-bytes');
    }
  }

  @override
  Future<void> cancel() async {}
}

class FakeExportRepository extends AppRepository {
  final Map<String, PlaybackPlan> playbackPlans = {};

  @override
  Future<void> initialize() async {}
  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
  }) => throw UnimplementedError();
  @override
  Future<CatalogPage> cached(String source, {String category = ''}) =>
      throw UnimplementedError();
  @override
  Future<List<CatalogCategory>> categories(
    String source, {
    bool force = false,
  }) => throw UnimplementedError();
  @override
  Future<String> cover(Drama drama, {bool force = false}) =>
      throw UnimplementedError();
  @override
  Future<DramaDetail> detail(Drama drama) => throw UnimplementedError();
  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) => throw UnimplementedError();
  @override
  Future<PlaybackPlan?> localPlayback(Drama drama, Episode episode) async =>
      playbackPlans['${drama.id}:${episode.number}'];
  @override
  Future<PlaybackPlan> resolveOnline(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) => throw UnimplementedError();
  @override
  Future<PlaybackPlan> fallback(PlaybackPlan current) =>
      throw UnimplementedError();
  @override
  Future<void> cancelPlayback() async {}
  @override
  Future<void> release(String session) async {}
}

void main() {
  group('VideoExportService', () {
    test('safeFileName sanitizes and formats names safely', () {
      expect(VideoExportService.safeFileName('测试:剧名/第一季*?'), '测试_剧名_第一季__');
      expect(VideoExportService.safeFileName('   '), '短剧');
      expect(VideoExportService.safeFileName('test...   '), 'test');
      expect(
        VideoExportService.safeFileName('a' * 100).runes.length,
        lessThanOrEqualTo(80),
      );
    });

    test('exportMediaItem copies existing media item safely', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'media_export_test',
      );
      try {
        final srcFile = File(path.join(tempDir.path, 'source.mp4'));
        await srcFile.writeAsString('video content');

        final targetDir = Directory(path.join(tempDir.path, 'target'));
        await targetDir.create();

        final repo = FakeExportRepository();
        final executor = MockExecutor();
        final service = VideoExportService(repo, executor: executor);

        final drama = Drama(id: 'd1', source: 'hongguo', title: '测试短剧');
        final item = LocalMediaItem(
          id: 'm1',
          drama: drama,
          file: srcFile.path,
          kind: 'merged',
          episodes: const [1, 2, 3],
          duration: 100.0,
          bytes: 100,
          created: DateTime.now(),
        );

        await service.exportMediaItem(item, srcFile.path, targetDir.path);
        final file1 = File(path.join(targetDir.path, '测试短剧 - 第1至3集.mp4'));
        expect(file1.existsSync(), isTrue);

        await service.exportMediaItem(item, srcFile.path, targetDir.path);
        final file2 = File(path.join(targetDir.path, '测试短剧 - 第1至3集 (1).mp4'));
        expect(file2.existsSync(), isTrue);
      } finally {
        await tempDir.delete(recursive: true);
      }
    });

    test('exportJob direct copies unencrypted mp4', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'job_direct_export',
      );
      try {
        final srcMp4 = File(path.join(tempDir.path, 'downloaded.mp4'));
        await srcMp4.writeAsString('mp4-data');

        final targetDir = Directory(path.join(tempDir.path, 'out'));
        await targetDir.create();

        final drama = Drama(id: 'd2', source: 'hongguo', title: '直接复制短剧');
        final episode = Episode(const {'id': 'e1', 'currentEpisode': 1}, 1);
        final job = DownloadJob(
          id: 'j1',
          drama: drama,
          episode: episode,
          state: 'completed',
        );

        final repo = FakeExportRepository();
        repo.playbackPlans['d2:1'] = PlaybackPlan(
          url: srcMp4.path,
          local: true,
        );

        final executor = MockExecutor();
        final service = VideoExportService(repo, executor: executor);

        await service.exportJob(job, targetDir.path);
        final file = File(path.join(targetDir.path, '直接复制短剧 - 第1集.mp4'));
        expect(file.existsSync(), isTrue);
        expect(await file.readAsString(), 'mp4-data');
        expect(executor.commands.isEmpty, isTrue);
      } finally {
        await tempDir.delete(recursive: true);
      }
    });

    test(
      'exportJob invokes ffmpeg for stream formats and handles fallback',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'job_stream_export',
        );
        try {
          final srcM3u8 = File(path.join(tempDir.path, 'index.m3u8'));
          await srcM3u8.writeAsString('#EXTM3U');

          final targetDir = Directory(path.join(tempDir.path, 'out'));
          await targetDir.create();

          final drama = Drama(id: 'd3', source: 'hongguo', title: '切片短剧');
          final episode = Episode(const {'id': 'e2', 'currentEpisode': 2}, 2);
          final job = DownloadJob(
            id: 'j2',
            drama: drama,
            episode: episode,
            state: 'completed',
          );

          final repo = FakeExportRepository();
          repo.playbackPlans['d3:2'] = PlaybackPlan(
            url: srcM3u8.path,
            local: true,
          );

          final executor = MockExecutor();
          final service = VideoExportService(repo, executor: executor);

          await service.exportJob(job, targetDir.path);
          expect(executor.commands.length, 1);
          expect(executor.commands.first.contains('-c'), isTrue);
          expect(executor.commands.first.contains('copy'), isTrue);

          executor.commands.clear();
          executor.failNextCopy = true;

          await service.exportJob(job, targetDir.path);
          expect(executor.commands.length, 2);
          expect(executor.commands[1].contains('libx264'), isTrue);
        } finally {
          await tempDir.delete(recursive: true);
        }
      },
    );
  });
}
