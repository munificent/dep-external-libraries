// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

@TestOn("vm")
library dep_external_libraries.test.all_test;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:mirrors';

import 'package:barback/barback.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:dep_external_libraries/transformer.dart';

final RegExp _expectComment = new RegExp("// expect: (.+)");

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
    tempDir = new Directory(p.join(testDirectory, "out"));
    tempDir.createSync();
  });

  // Transform each canonical library and run it.
  var transformer = new ExternalLibraryTransformer.asPlugin();

  for (var entry in new Directory(casesDir).listSync()) {
    if (!entry.path.endsWith(".dart")) continue;
    if (entry.path.endsWith("_external.dart")) continue;

    var description = p.relative(entry.path, from: casesDir);
    test(description, () async {
      // Read the test case canonical library.
      var name = p.relative(entry.path, from: casesDir);
      var primary = testCaseAsset(name);

      // Parse the expectations from it.
      var input = (entry as File).readAsStringSync();
      var matches = _expectComment.allMatches(input);
      assert(matches != null);

      var expectation = matches.map((match) => match[1]).join("\n");

      // Run the transformer on it.
      var transform = new _TestTransform(primary);
      await transformer.apply(transform);

      for (var asset in transform.outputs) {
        var output = await asset.readAsString();
        var outPath = p.join(tempDir.path, p.fromUri(asset.id.path));
        new File(outPath).writeAsStringSync(output);
      }

      var result = Process.runSync(Platform.resolvedExecutable, [
        "--checked",
        p.join(tempDir.path, name)
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
  var id = new AssetId("test", name);
  return new Asset.fromPath(id, p.join(testDirectory, "cases", name));
}

class _TestTransform implements Transform {
  final Asset primaryInput;

  /// After the transformer has run, this will be set of assets that were
  /// output.
  final Set<Asset> outputs = new Set();

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
    outputs.add(asset);
  }

  void consumePrimary() => throw new UnsupportedError("Not supported.");
}
