// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';

import 'package:analyzer/analyzer.dart';
import 'package:analyzer/src/generated/ast.dart';
import 'package:analyzer/src/generated/java_core.dart';
import 'package:barback/barback.dart';
import 'package:dart_style/dart_style.dart';
import 'package:path/path.dart' as p;

import 'src/canonical_visitor.dart';
import 'src/to_source_visitor.dart';

final _externalImportPattern =
    new RegExp(r'//external:\s*"([^"]+)"(\s+if\s+(.+))?');

// TODO(rnystrom): Make lazy.
class ExternalizeTransformer extends Transformer {
  ExternalizeTransformer.asPlugin();

  String get allowedExtensions => ".e.dart";

  Future apply(Transform transform) async {
    var source = await transform.primaryInput.readAsString();

    // TODO(rnystrom): Handle errors.
    var unit = parseCompilationUnit(source,
        name: transform.primaryInput.id.toString());

    var externalUri;
    var externalUnit;

    if (unit.directives.isNotEmpty &&
        unit.directives.first is LibraryDirective) {
      externalUri = _parseExternalImports(unit.directives.first);

      if (externalUri != null) {
        externalUnit = await _readExternalLibrary(transform, externalUri);
      }
    }

    var visitor = new CanonicalVisitor(externalUri, externalUnit);
    unit.accept(visitor);

    var writer = new PrintStringWriter();
    var toSourceVisitor = new ToSourceVisitorCopy(writer);
    unit.accept(toSourceVisitor);

    var output = writer.toString();
    output = new DartFormatter().format(output);

    transform.addOutput(
        new Asset.fromString(transform.primaryInput.id, output));
  }

  String _parseExternalImports(LibraryDirective node) {
    for (var comment = node.beginToken.precedingComments;
        comment != null;
        comment = comment.next) {
      var match = _externalImportPattern.firstMatch(comment.lexeme);
      if (match == null) continue;

      var condition = match[3];
      // TODO(rnystrom): Allow configuration to configure.
      if (condition == null || condition == "dart.io") {
        return match[1];
      }
    }

    return null;
  }

  Future<CompilationUnit> _readExternalLibrary(
      Transform transform, String externalUri) async {
    var canonicalDir = p.url.dirname(transform.primaryInput.id.path);
    var externalPath = p.url.join(canonicalDir, externalUri);
    var externalId =
    new AssetId(transform.primaryInput.id.package, externalPath);

    var externalSource = await transform.readInputAsString(externalId);

    // TODO(rnystrom): Handle errors.
    return parseCompilationUnit(externalSource, name: externalUri);
  }
}
