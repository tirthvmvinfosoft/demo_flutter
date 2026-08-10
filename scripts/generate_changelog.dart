// scripts/generate_changelog.dart
import 'dart:io';

final RegExp _eligibleCommit = RegExp(
  r'^(docs|feat|fix|bug|perf|refactor|revert)(\(([^)]*)\))?(!)?\s*:\s*(.*)$',
  caseSensitive: false,
);
final RegExp _jiraOnlyCommit = RegExp(
  r'^([A-Z]+-\d+):?\s+(.+)$',
);

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln('Usage: dart run scripts/generate_changelog.dart <merge-base-sha> "<release title>"');
    exit(1);
  }
  final mergeBase = args[0];
  final releaseTitle = args[1];

  final versionFile = File('pubspec.yaml');
  var appVersion = 'unknown';
  if (await versionFile.exists()) {
    final versionMatch = RegExp(r'^version:\s*(.+)$', multiLine: true)
        .firstMatch(await versionFile.readAsString());
    if (versionMatch != null) appVersion = versionMatch.group(1)!.trim();
  }

  final logResult = await Process.run(
    'git',
    ['log', '--pretty=format:%s', '$mergeBase..HEAD'],
  );
  if (logResult.exitCode != 0) {
    stderr.writeln('git log failed: ${logResult.stderr}');
    exit(1);
  }

  final subjects = (logResult.stdout as String).split('\n').where((l) => l.trim().isNotEmpty);
  final entries = <String>[];

  for (final subject in subjects) {
    final trimmedSubject = subject.trim();

    if (trimmedSubject.startsWith('chore(repo): update changelogs on develop')) continue;

    final match = _eligibleCommit.firstMatch(trimmedSubject);

    if (match != null) {
      final type = match.group(1)!.toUpperCase();
      final scope = match.group(3);
      final bang = match.group(4);
      final description = match.group(5)!;

      final buffer = StringBuffer('- **$type**');
      if (scope != null) buffer.write('($scope)');
      if (bang != null) buffer.write('!');
      buffer.write(': $description');
      entries.add(buffer.toString());
      continue;
    }

    final jiraMatch = _jiraOnlyCommit.firstMatch(trimmedSubject);
    if (jiraMatch != null) {
      final ticket = jiraMatch.group(1)!;
      final description = jiraMatch.group(2)!;
      entries.add('- ($ticket) $description');
      continue;
    }
  }

  if (entries.isEmpty) {
    stdout.writeln('No bump-eligible commits found since $mergeBase — nothing to add to CHANGELOG.md.');
    exit(0);
  }

  final changelogFile = File('CHANGELOG.md');
  var existing = await changelogFile.exists() ? await changelogFile.readAsString() : '';

  final baseVersion = appVersion.split('+')[0];

  final targetHeaderPattern = '## $releaseTitle (v$baseVersion';

  if (existing.contains(targetHeaderPattern)) {
    stdout.writeln('Cleaning up previous release log section for version $baseVersion...');
    final lines = existing.split('\n');
    final cleanedLines = <String>[];
    var skipMode = false;

    for (final line in lines) {
      final trimmedLine = line.trim();

      if (trimmedLine.startsWith(targetHeaderPattern)) {
        skipMode = true;
        continue;
      }
      if (trimmedLine.startsWith('## ') && !trimmedLine.startsWith(targetHeaderPattern)) {
        skipMode = false;
      }
      if (!skipMode) {
        cleanedLines.add(line);
      }
    }
    existing = cleanedLines.join('\n').trim();
  }

  final newSection = StringBuffer()
    ..writeln('## $releaseTitle (v$baseVersion)')
    ..writeln()
    ..writeln('### Changes')
    ..writeln();

  for (final entry in entries) {
    newSection.writeln(entry);
  }
  newSection.writeln();

  await changelogFile.writeAsString('$newSection\n$existing'.trim());
  stdout.writeln('Added ${entries.length} entr${entries.length == 1 ? 'y' : 'ies'} to CHANGELOG.md.');
}