import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'core_bridge.dart';
import 'media_library.dart';
import 'media_pipeline.dart';
import 'models.dart';

class VideoExportResult {
  final int total;
  final int succeeded;
  final int failed;
  final String targetDirectory;
  final List<String> errors;

  const VideoExportResult({
    required this.total,
    required this.succeeded,
    required this.failed,
    required this.targetDirectory,
    this.errors = const [],
  });
}

class VideoExportService {
  final AppRepository repository;
  final MediaExecutor executor;

  VideoExportService(this.repository, {MediaExecutor? executor})
    : executor = executor ?? FFmpegExecutor();

  static String safeFileName(String name) {
    var result = name
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
        .trim()
        .replaceAll(RegExp(r'[. ]+$'), '');
    if (result.isEmpty) result = '短剧';
    return String.fromCharCodes(result.runes.take(80));
  }

  static Future<String?> pickTargetDirectory(BuildContext context) async {
    try {
      final selected = await FilePicker.getDirectoryPath(
        dialogTitle: '选择导出视频保存目录',
      );
      if (selected != null && selected.trim().isNotEmpty) {
        return selected.trim();
      }
    } catch (_) {}

    final locations = <String, String>{};
    if (Platform.isAndroid) {
      const publicDownload = '/storage/emulated/0/Download';
      if (Directory(publicDownload).existsSync()) {
        locations[publicDownload] = '公共下载目录 (Download)';
      }
      const publicMovies = '/storage/emulated/0/Movies';
      if (Directory(publicMovies).existsSync()) {
        locations[publicMovies] = '公共视频目录 (Movies)';
      }
      final externals = await getExternalStorageDirectories() ?? [];
      for (var i = 0; i < externals.length; i++) {
        locations[externals[i].path] = i == 0 ? '设备外置存储应用目录' : 'SD 卡 ${i + 1}';
      }
    } else {
      final docs = await getApplicationDocumentsDirectory();
      locations[docs.path] = '文档目录 (Documents)';
      final downloads = await getDownloadsDirectory();
      if (downloads != null) {
        locations[downloads.path] = '下载目录 (Downloads)';
      }
    }

    if (!context.mounted || locations.isEmpty) return null;

    return showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('选择导出保存位置'),
        children: [
          for (final entry in locations.entries)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, entry.key),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.value,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    Text(entry.key, style: Theme.of(ctx).textTheme.bodySmall),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> exportJob(
    DownloadJob job,
    String targetDirectory, {
    void Function(String status)? onStatus,
  }) async {
    final plan = await repository.localPlayback(job.drama, job.episode);
    if (plan == null || !plan.local || plan.url.isEmpty) {
      throw AppFailure('第 ${job.episode.number} 集尚未完整下载或本地记录失效');
    }

    final ext = path.extension(plan.url).toLowerCase();
    final isEncrypted = plan.decryptionKey.isNotEmpty;
    final isDirectMp4 = ext == '.mp4' && !isEncrypted;

    final dramaName = safeFileName(job.drama.title);
    final baseName = '$dramaName - 第${job.episode.number}集';
    final targetDir = Directory(targetDirectory);
    if (!await targetDir.exists()) {
      await targetDir.create(recursive: true);
    }

    var finalTarget = path.join(targetDirectory, '$baseName.mp4');
    var suffix = 1;
    while (await File(finalTarget).exists()) {
      finalTarget = path.join(targetDirectory, '$baseName ($suffix).mp4');
      suffix++;
    }

    if (isDirectMp4) {
      final inputFile = File(plan.url);
      if (await inputFile.exists() && await inputFile.length() > 0) {
        onStatus?.call('正在导出视频文件...');
        await inputFile.copy(finalTarget);
        return;
      }
    }

    onStatus?.call('正在转为标准 MP4 视频文件...');
    final tempTarget = path.join(
      targetDirectory,
      '.export_tmp_${DateTime.now().microsecondsSinceEpoch}.mp4',
    );

    try {
      final inputArgs = <String>[];
      if (isEncrypted) {
        inputArgs.addAll(['-decryption_key', plan.decryptionKey]);
      }
      if (ext == '.m3u8') {
        inputArgs.addAll([
          '-allowed_extensions',
          'ALL',
          '-extension_picky',
          '0',
        ]);
      }

      var remuxSuccess = false;
      try {
        await executor.run([
          ...inputArgs,
          '-i',
          plan.url,
          '-map',
          '0:v:0',
          '-map',
          '0:a:0?',
          '-c',
          'copy',
          '-movflags',
          '+faststart',
          '-avoid_negative_ts',
          'make_zero',
          tempTarget,
        ]);
        remuxSuccess = true;
      } catch (_) {
        remuxSuccess = false;
      }

      if (!remuxSuccess) {
        final f = File(tempTarget);
        if (await f.exists()) await f.delete();
        await executor.run([
          ...inputArgs,
          '-i',
          plan.url,
          '-map',
          '0:v:0',
          '-map',
          '0:a:0?',
          '-c:v',
          'libx264',
          '-c:a',
          'aac',
          '-movflags',
          '+faststart',
          tempTarget,
        ]);
      }

      final exported = File(tempTarget);
      if (!await exported.exists() || await exported.length() == 0) {
        throw AppFailure('导出视频失败，未能生成有效视频');
      }

      await exported.rename(finalTarget);
    } catch (_) {
      final f = File(tempTarget);
      if (await f.exists()) await f.delete();
      rethrow;
    }
  }

  Future<void> exportMediaItem(
    LocalMediaItem item,
    String sourceFilePath,
    String targetDirectory, {
    void Function(String status)? onStatus,
  }) async {
    final inputFile = File(sourceFilePath);
    if (!await inputFile.exists() || await inputFile.length() == 0) {
      throw AppFailure('本地媒体文件缺失');
    }

    final dramaName = safeFileName(item.drama.title);
    final epString = item.merged
        ? (item.episodes.length > 1
              ? '第${item.episodes.first}至${item.episodes.last}集'
              : '全集')
        : '第${item.episodes.first}集';
    final baseName = '$dramaName - $epString';
    final targetDir = Directory(targetDirectory);
    if (!await targetDir.exists()) {
      await targetDir.create(recursive: true);
    }

    var finalTarget = path.join(targetDirectory, '$baseName.mp4');
    var suffix = 1;
    while (await File(finalTarget).exists()) {
      finalTarget = path.join(targetDirectory, '$baseName ($suffix).mp4');
      suffix++;
    }

    final ext = path.extension(sourceFilePath).toLowerCase();
    if (ext == '.mp4') {
      onStatus?.call('正在直接导出视频文件...');
      await inputFile.copy(finalTarget);
      return;
    }

    onStatus?.call('正在转为标准 MP4 视频文件...');
    final tempTarget = path.join(
      targetDirectory,
      '.export_tmp_${DateTime.now().microsecondsSinceEpoch}.mp4',
    );

    try {
      var remuxSuccess = false;
      try {
        await executor.run([
          '-i',
          sourceFilePath,
          '-map',
          '0:v:0',
          '-map',
          '0:a:0?',
          '-c',
          'copy',
          '-movflags',
          '+faststart',
          '-avoid_negative_ts',
          'make_zero',
          tempTarget,
        ]);
        remuxSuccess = true;
      } catch (_) {
        remuxSuccess = false;
      }

      if (!remuxSuccess) {
        final f = File(tempTarget);
        if (await f.exists()) await f.delete();
        await executor.run([
          '-i',
          sourceFilePath,
          '-map',
          '0:v:0',
          '-map',
          '0:a:0?',
          '-c:v',
          'libx264',
          '-c:a',
          'aac',
          '-movflags',
          '+faststart',
          tempTarget,
        ]);
      }

      final exported = File(tempTarget);
      if (!await exported.exists() || await exported.length() == 0) {
        throw AppFailure('导出视频失败，未能生成有效视频');
      }

      await exported.rename(finalTarget);
    } catch (_) {
      final f = File(tempTarget);
      if (await f.exists()) await f.delete();
      rethrow;
    }
  }

  Future<void> cancel() async {
    await executor.cancel();
  }
}

Future<void> showVideoExportDialog({
  required BuildContext context,
  required AppRepository repository,
  List<DownloadJob> jobs = const [],
  LocalMediaItem? mediaItem,
  String? mediaFilePath,
}) async {
  final completedJobs = jobs.where((job) => job.completed).toList()
    ..sort((a, b) => a.episode.number.compareTo(b.episode.number));

  if (completedJobs.isEmpty && mediaItem == null) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('没有已下载完成的视频可供导出')));
    return;
  }

  final targetDirectory = await VideoExportService.pickTargetDirectory(context);
  if (targetDirectory == null || !context.mounted) return;

  final total = mediaItem != null ? 1 : completedJobs.length;
  final service = VideoExportService(repository);
  var cancelled = false;

  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) {
      var current = 0;
      var status = '正在准备导出...';
      var currentItemTitle = mediaItem != null
          ? mediaItem.drama.title
          : completedJobs.first.drama.title;
      var started = false;

      void startExport(StateSetter setState) async {
        var succeeded = 0;
        var failed = 0;
        final errors = <String>[];

        if (mediaItem != null && mediaFilePath != null) {
          if (dialogContext.mounted) {
            setState(() {
              current = 1;
              currentItemTitle = mediaItem.drama.title;
              status = '正在处理...';
            });
          }
          try {
            await service.exportMediaItem(
              mediaItem,
              mediaFilePath,
              targetDirectory,
              onStatus: (s) {
                if (dialogContext.mounted) {
                  setState(() => status = s);
                }
              },
            );
            succeeded++;
          } catch (e) {
            failed++;
            errors.add(e.toString());
          }
        } else {
          for (var i = 0; i < completedJobs.length; i++) {
            if (cancelled) break;
            final job = completedJobs[i];
            if (dialogContext.mounted) {
              setState(() {
                current = i + 1;
                currentItemTitle =
                    '${job.drama.title} - 第 ${job.episode.number} 集';
                status = '正在处理...';
              });
            }
            try {
              await service.exportJob(
                job,
                targetDirectory,
                onStatus: (s) {
                  if (dialogContext.mounted) {
                    setState(() => status = s);
                  }
                },
              );
              succeeded++;
            } catch (e) {
              failed++;
              errors.add('第 ${job.episode.number} 集: $e');
            }
          }
        }

        if (dialogContext.mounted) {
          Navigator.of(dialogContext).pop();
        }

        if (context.mounted) {
          final msg = cancelled
              ? '已取消导出（已导出 $succeeded 个视频到：$targetDirectory）'
              : failed == 0
              ? '已成功导出 $succeeded 个视频到：\n$targetDirectory'
              : '导出完成：$succeeded 个成功，$failed 个失败。\n保存目录：$targetDirectory';
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(msg), duration: const Duration(seconds: 4)),
          );
        }
      }

      return StatefulBuilder(
        builder: (ctx, setState) {
          if (!started) {
            started = true;
            Timer.run(() => startExport(setState));
          }
          final progress = total > 0 ? (current / total).clamp(0.0, 1.0) : 0.0;
          return AlertDialog(
            title: const Text('正在导出视频'),
            content: SizedBox(
              width: 360,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '目标目录：$targetDirectory',
                    style: Theme.of(ctx).textTheme.bodySmall,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 12),
                  LinearProgressIndicator(value: progress),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('进度：$current / $total'),
                      Text('${(progress * 100).toInt()}%'),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    currentItemTitle,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(status, style: Theme.of(ctx).textTheme.bodySmall),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  cancelled = true;
                  service.cancel();
                  Navigator.of(ctx).pop();
                },
                child: const Text('取消导出'),
              ),
            ],
          );
        },
      );
    },
  );
}
