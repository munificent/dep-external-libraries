// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

@TestOn("vm")
library dep_external_libraries.test.all_test;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:mirrors';

import 'package:analyzer/analyzer.dart';
import 'package:barback/barback.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:dep_external_libraries/transformer.dart';

final _expectComment = new RegExp("// expect: (.+)");

/// Locate the "test" directory.
///
/// Use mirrors so that this works with the test package, which loads this
/// suite into an isolate.
final testDirectory = p.dirname(currentMirrorSystem()
    .findLibrary(#dep_external_libraries.test.all_test)
    .uri
    .path);

Future main() async {
  var casesDir = p.join(testDirectory, "cases");

  var tempDir;
  setUp(() {
    tempDir = new Directory(testDirectory).createTempSync("temp-");

    // Copy the external libraries over to the build output directory so that
    // the relative imports work.
    for (var entry in new Directory(casesDir).listSync()) {
      if (!entry.path.endsWith(".dart")) continue;

      // Don't copy canonical libraries.
      if (entry.path.endsWith(".e.dart")) continue;

      var name = p.relative(entry.path, from: casesDir);
      var source = (entry as File).readAsStringSync();
      new File(p.join(tempDir.path, name)).writeAsStringSync(source);
    }
  });

  // Transform each canonical library and run it.
  var transformer = new ExternalizeTransformer.asPlugin();

  for (var entry in new Directory(casesDir).listSync()) {
    if (!entry.path.endsWith(".e.dart")) continue;

    test(entry.path, () async {
      // Read the test case canonical library.
      var name = p.relative(entry.path, from: casesDir);
      var primary = testCaseAsset(name);

      // Parse the expectation from it.
      var input = (entry as File).readAsStringSync();
      var match = _expectComment.firstMatch(input);
      assert(match != null);

      var expectation = match[1];

      // Run the transformer on it.
      var transform = new _TestTransform(primary);
      await transformer.apply(transform);
      var output = await transform.output;

      var outPath = p.join(tempDir.path, name);
      new File(outPath).writeAsStringSync(output);

      var result = Process.runSync(Platform.resolvedExecutable, [
        "--checked",
        outPath
      ]);

      expect(result.stderr.trim(), equals(""));
      expect(result.stdout.trim(), equals(expectation));
    });
  }

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });
}

Asset testCaseAsset(String name) {
  var id = new AssetId("externalize", name);
  return new Asset.fromPath(id, p.join(testDirectory, "cases", name));
}

class _TestTransform implements Transform {
  final Asset primaryInput;

  /// After the transformer has run, this will be a future that completes to
  /// the contents of the one output asset.
  Future<String> output;

  TransformLogger get logger => throw new UnsupportedError("Not supported.");

  _TestTransform(this.primaryInput);

  Future<Asset> getInput(AssetId id) async => testCaseAsset(id.path);

  Future<String> readInputAsString(AssetId id, {Encoding encoding}) async {
    var asset = await getInput(id);
    return asset.readAsString(encoding: encoding);
  }

  Stream<List<int>> readInput(AssetId id) =>
      throw new UnsupportedError("Not supported.");

  Future<bool> hasInput(AssetId id) =>
      throw new UnsupportedError("Not supported.");

  void addOutput(Asset asset) {
    // Should only produce one output.
    assert(output == null);

    output = asset.readAsString();
  }

  void consumePrimary() => throw new UnsupportedError("Not supported.");
}
