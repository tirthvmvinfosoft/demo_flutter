// scripts/changelog_notion_sync.dart
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

const _notionVersion = '2022-06-28';
const _jiraBaseUrl = 'https://optery.atlassian.net/browse';

Future<void> main() async {
  try {
    await _run();
  } catch (e, st) {
    stderr.writeln('changelog-notion-sync failed: $e');
    stderr.writeln(st);
    exit(1);
  }
}

Future<void> _run() async {
  final token = _requireEnv('NOTION_TOKEN');
  final databaseId = _requireEnv('NOTION_DATABASE_ID');
  final releaseName = _requireEnv('RELEASE_NAME');
  final baseSha = _requireEnv('BASE_SHA');
  final mergeSha = _requireEnv('MERGE_SHA');
  final appVersion = _requireEnv('APP_VERSION');

  final client = http.Client();
  try {
    final addedBody = await _addedChangelogContent(baseSha, mergeSha);
    if (addedBody == null || addedBody.trim().isEmpty) {
      stdout.writeln('No new CHANGELOG.md content in this release — nothing to sync.');
      return;
    }

    final jiraTickets = _extractJiraTickets(addedBody);
    final response = await _createReleasePage(
      client,
      token: token,
      databaseId: databaseId,
      releaseName: releaseName,
      version: appVersion,
      jiraTickets: jiraTickets,
      changelogBody: addedBody,
      baseSha: baseSha,
      mergeSha: mergeSha,
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      stderr.writeln('Notion page creation failed (${response.statusCode}): ${response.body}');
      return;
    }
    stdout.writeln('Created Notion page for release "$releaseName".');
  } finally {
    client.close();
  }
}

String _requireEnv(String name) => Platform.environment[name] ?? (throw StateError('Missing $name'));

Future<String?> _addedChangelogContent(String baseSha, String mergeSha) async {
  final file = File('CHANGELOG.md');
  if (!await file.exists()) {
    stderr.writeln('CHANGELOG.md file not found.');
    return null;
  }

  final lines = await file.readAsLines();
  final addedLines = <String>[];
  var headingCount = 0;

  for (final line in lines) {
    var trimmed = line.trim();

    if (trimmed.startsWith('## ')) {
      headingCount++;
      if (headingCount > 1) break;
      continue;
    }

    if (headingCount == 1) {
      addedLines.add(line);
    }
  }

  final joined = addedLines.join('\n').trim();
  return joined.isEmpty ? null : joined;
}

List<String> _extractJiraTickets(String body) =>
    RegExp(r'\b([A-Z]+-\d+)\b').allMatches(body).map((m) => m.group(1)!).toSet().toList();

List<Map<String, dynamic>> _jiraTicketsRichText(List<String> tickets) {
  final richText = <Map<String, dynamic>>[];
  for (var i = 0; i < tickets.length; i++) {
    if (i > 0) {
      richText.add({
        'text': {'content': ', '},
      });
    }
    richText.add({
      'text': {
        'content': tickets[i],
        'link': {'url': '$_jiraBaseUrl/${tickets[i]}'},
      },
    });
  }
  return richText;
}

String _formatTitle(String rawTitle) {
  if (rawTitle.startsWith('chore(release):')) return rawTitle;
  return 'chore(release): $rawTitle';
}

String? _parseReleaseDateIso(String input) {
  final match = RegExp(r'\((\d{4}-\d{2}-\d{2})\)').firstMatch(input);
  return match?.group(1);
}

String _extractDescriptionText(String changelogBody) {
  final cleanLines = <String>[];

  for (var line in changelogBody.split('\n')) {
    var clean = line.trim();

    if (clean.isEmpty || clean.startsWith('#')) continue;

    if (clean.startsWith('- ') || clean.startsWith('* ')) {
      clean = clean.substring(2).trim();
    }

    clean = clean.replaceAll('**', '').trim();
    clean = clean.replaceFirst(
      RegExp(
        r'^(?:[A-Za-z]+\([^)]+\)!?:?\s*|[A-Za-z]+!?:?\s*|\([A-Z]+-\d+\)\s*)',
        caseSensitive: false,
      ),
      '',
    );

    if (clean.isNotEmpty) {
      cleanLines.add(clean);
    }
  }

  return cleanLines.join('; ');
}


Future<http.Response> _createReleasePage(
  http.Client client, {
  required String token,
  required String databaseId,
  required String releaseName,
  required String version,
  required List<String> jiraTickets,
  required String changelogBody,
  required String baseSha,
  required String mergeSha,
}) async {
  final structuredTitle = _formatTitle(releaseName);
  final isoDate = _parseReleaseDateIso(releaseName);
  final descriptionSummary = _extractDescriptionText(changelogBody);

  final cleanVersion = version.split('+').first;

  final Map<String, dynamic> properties = {
    'Release Name': {
      'title': [
        {'text': {'content': structuredTitle}},
      ],
    },
    'App Updated': {
      'rich_text': [
        {'text': {'content': 'mobile'}},
      ],
    },
    'Version': {
      'rich_text': [
        {'text': {'content': cleanVersion}},
      ],
    },
    'Description': {
      'rich_text': [
        {'text': {'content': descriptionSummary}},
      ],
    },
    'Jira Tickets': {
      'rich_text': _jiraTicketsRichText(jiraTickets),
    },
  };

  if (isoDate != null) {
    properties['Release Date'] = {
      'date': {'start': isoDate}
    };
  }

  final body = {
    'parent': {'database_id': databaseId},
    'properties': properties,
    'children': await _changelogToBlocksWithHashes(changelogBody, jiraTickets, baseSha, mergeSha),
  };
  return client.post(
    Uri.parse('https://api.notion.com/v1/pages'),
    headers: {
      'Authorization': 'Bearer $token',
      'Notion-Version': _notionVersion,
      'Content-Type': 'application/json',
    },
    body: jsonEncode(body),
  );
}

Future<List<Map<String, dynamic>>> _changelogToBlocksWithHashes(
  String body,
  List<String> tickets,
  String baseSha,
  String mergeSha,
) async {
  final blocks = <Map<String, dynamic>>[];

  if (tickets.isNotEmpty) {
    final jiraLineContent = <Map<String, dynamic>>[
      {
        'type': 'text',
        'text': {'content': 'Jira: '},
      }
    ];

    for (var i = 0; i < tickets.length; i++) {
      if (i > 0) {
        jiraLineContent.add({
          'type': 'text',
          'text': {'content': ', '},
        });
      }
      jiraLineContent.add({
        'type': 'text',
        'text': {
          'content': tickets[i],
          'link': {'url': '$_jiraBaseUrl/${tickets[i]}'},
        },
      });
    }

    blocks.add({
      'object': 'block',
      'type': 'paragraph',
      'paragraph': {'rich_text': jiraLineContent},
    });

    blocks.add({
      'object': 'block',
      'type': 'paragraph',
      'paragraph': {'rich_text': []},
    });
  }

  final gitLogResult = await Process.run('git', [
    'log',
    '$baseSha..$mergeSha',
    '--oneline',
    '--no-merges',
  ]);

  final gitCommits = <Map<String, String>>[];
  if (gitLogResult.exitCode == 0) {
    for (var line in (gitLogResult.stdout as String).split('\n').map((l) => l.trim())) {
      final spaceIdx = line.indexOf(' ');
      if (spaceIdx != -1) {
        gitCommits.add({
          'hash': line.substring(0, spaceIdx),
          'subject': line.substring(spaceIdx + 1).trim().toLowerCase(),
        });
      }
    }
  }

  for (var line in body.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty)) {
    if (line.startsWith('### ')) {
      blocks.add({
        'object': 'block',
        'type': 'heading_3',
        'heading_3': {
          'rich_text': [
            {'type': 'text', 'text': {'content': line.substring(4).trim()}},
          ],
        },
      });
      continue;
    }

    var isBullet = false;
    var contentLine = line;

    if (contentLine.startsWith('- ') || contentLine.startsWith('* ')) {
      isBullet = true;
      contentLine = contentLine.substring(2).trim();
    }

    contentLine = contentLine.replaceAll('**', '');

    if (isBullet) {
      var normalizedMsg = contentLine.trim().toLowerCase();

      normalizedMsg = normalizedMsg.replaceFirstMapped(
        RegExp(r'^\(([a-z]+-\d+)\)\s+'),
            (match) => '${match.group(1)}: ',
      );
      var foundHash = '';

      for (final commit in gitCommits) {
        String normalize(String text) => text
            .toLowerCase()
            .replaceAll(RegExp(r'\s*:\s*'), ': ')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();

        final subject = normalize(commit['subject'] ?? '');
        final changelog = normalize(normalizedMsg);

        if (subject.contains(changelog) || changelog.contains(subject)) {
          foundHash = commit['hash'] ?? '';
          break;
        }
      }

      if (foundHash.isNotEmpty) {
        contentLine = '$foundHash: $contentLine';
      }
    }

    final blockData = {
      'rich_text': [
        {'type': 'text', 'text': {'content': contentLine}},
      ],
    };

    if (isBullet) {
      blocks.add({'object': 'block', 'type': 'bulleted_list_item', 'bulleted_list_item': blockData});
    } else {
      blocks.add({'object': 'block', 'type': 'paragraph', 'paragraph': blockData});
    }
  }
  return blocks;
}
