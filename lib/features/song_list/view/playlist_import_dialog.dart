import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/music.dart';
import '../../library/state/library_controller.dart';
import '../state/song_list_controller.dart';

Future<String?> showPlaylistImportDialog(BuildContext context) {
  final controller = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('导入歌单'),
      content: TextField(
        controller: controller,
        autofocus: true,
        textInputAction: TextInputAction.done,
        onSubmitted: (value) => Navigator.pop(dialogContext, value),
        decoration: const InputDecoration(
          hintText: '粘贴网易云、酷狗、酷我、QQ 或咪咕歌单链接',
          prefixIcon: Icon(Icons.link_outlined),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, controller.text),
          child: const Text('导入'),
        ),
      ],
    ),
  ).whenComplete(controller.dispose);
}

Future<PlaylistDetail?> importPlaylistToFavorites(
  WidgetRef ref,
  String input,
) async {
  final parsed = parsePlaylistInput(input);
  if (parsed == null) return null;
  final songList = ref.read(songListProvider.notifier);
  await songList.importFromInput(input);
  final detail = ref.read(songListProvider).detail;
  if (detail == null ||
      detail.playlist.id != parsed.id ||
      (parsed.source != null && detail.playlist.source != parsed.source)) {
    return null;
  }
  await ref.read(libraryProvider.notifier).addFavoriteOnlinePlaylist(detail);
  return detail;
}
