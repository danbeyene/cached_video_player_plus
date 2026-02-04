import 'package:cached_video_player_plus/cached_video_player_plus.dart';
import 'package:flutter/material.dart';


class _VideoInfo {
  _VideoInfo(this.url, this.title);

  final String url;
  final String title;
}

class AdvanceCacheManagementPage extends StatefulWidget {
  const AdvanceCacheManagementPage({super.key});

  @override
  State<AdvanceCacheManagementPage> createState() =>
      _AdvanceCacheManagementPageState();
}

class _AdvanceCacheManagementPageState
    extends State<AdvanceCacheManagementPage> {
  final _videoUrls = [
    _VideoInfo(
      'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerFun.mp4',
      'For Bigger Fun',
    ),
    _VideoInfo(
      'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/Sintel.mp4',
      'Sintel',
    ),
    _VideoInfo(
      'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/TearsOfSteel.mp4',
      'Tears of Steel',
    ),
    _VideoInfo(
      'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/WhatCarCanYouGetForAGrand.mp4',
      'What Car Can You Get For A Grand',
    ),
  ];

  int _selectedIndex = 0;
  String _customKey = '';
  bool _isCaching = false;
  String _statusMessage = '';

  @override
  void initState() {
    super.initState();
  }

  Future<void> _cacheVideo() async {
    if (_isCaching) return;
    setState(() {
       _isCaching = true;
       _statusMessage = 'Starting pre-cache...';
    });

    try {
      await CachedVideoPlayerPlus.preCacheVideo(
        Uri.parse(_videoUrls[_selectedIndex].url),
        cacheKey: _customKey.isNotEmpty ? _customKey : null,
      );
      setState(() => _statusMessage = 'Pre-cache request sent successfully.');
    } catch (e) {
      setState(() => _statusMessage = 'Pre-cache failed: $e');
    } finally {
      if (mounted) setState(() => _isCaching = false);
    }
  }

  Future<void> _clearAllCache() async {
    setState(() => _statusMessage = 'Clearing cache...');
    try {
      await CachedVideoPlayerPlus.clearAllCache();
       setState(() => _statusMessage = 'Clear cache requested.');
    } catch (e) {
       setState(() => _statusMessage = 'Clear cache failed: $e');
    }
  }

  Future<void> _deleteCacheFile(String cacheKey) async {
     setState(() => _statusMessage = 'Removing cache for key: $cacheKey...');
    try {
      await CachedVideoPlayerPlus.removeFileFromCacheByKey(cacheKey);
      setState(() => _statusMessage = 'Removed cache for $cacheKey');
    } catch (e) {
      setState(() => _statusMessage = 'Remove failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Advanced Cache Management')),
      resizeToAvoidBottomInset: false,
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 12),
            const Text(
              'Note: File inspection is not supported with the new caching engine. '
              'Use the controls below to manage cache.',
              style: TextStyle(fontSize: 13, color: Colors.grey),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                const Text('Select Video:'),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButton<int>(
                    value: _selectedIndex,
                    isExpanded: true,
                    items: List.generate(
                      _videoUrls.length,
                      (i) => DropdownMenuItem(
                        value: i,
                        child: Text(_videoUrls[i].title),
                      ),
                    ),
                    onChanged: (i) {
                      if (i == null) return;
                      setState(() => _selectedIndex = i);
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Text('Custom Cache Key:'),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    decoration: const InputDecoration(
                      hintText: 'Enter cache key (optional)',
                      isDense: true,
                    ),
                    onChanged: (value) {
                      _customKey = value.trim();
                      setState(() {});
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Wrap(
              spacing: 12,
              runSpacing: 4,
              children: [
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(foregroundColor: Colors.blue),
                  icon: _isCaching
                      ? _SmallLoader()
                      : const Icon(Icons.cloud_download),
                  label: const Text('Cache It'),
                  onPressed: !_isCaching ? _cacheVideo : null,
                ),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(foregroundColor: Colors.red),
                  icon: const Icon(Icons.delete),
                  label: const Text('Remove Selected'),
                  onPressed: () {
                     final key = _customKey.isNotEmpty ? _customKey : _videoUrls[_selectedIndex].url;
                     _deleteCacheFile(key);
                  },
                ),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(foregroundColor: Colors.redAccent),
                  icon: const Icon(Icons.delete_forever),
                  label: const Text('Clear All'),
                  onPressed: _clearAllCache,
                ),
              ],
            ),
            const Divider(height: 25),
            Text('Status:', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              width: double.infinity,
              decoration: BoxDecoration(
                color: Colors.grey[200],
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(_statusMessage.isEmpty ? 'Ready' : _statusMessage),
            ),
          ],
        ),
      ),
    );
  }
}

class _SmallLoader extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: 20,
      child: const CircularProgressIndicator.adaptive(strokeWidth: 2),
    );
  }
}
