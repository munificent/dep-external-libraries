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

import 'src/patcher.dart';
import 'src/to_source_visitor.dart';

final _externalImportPattern =
    new RegExp(r'//external:\s*"([^"]+)"(\s+if\s+(.+))?');

// TODO(rnystrom): An incomplete list of things left to implement:
//
// - calling an unpatched external
// - patching private stuff
// - patching a getter with a field
// - disallow patching non-external methods
// - disallow patching non-external functions
// - nested external function
// - top level getter, setter
// - external class cannot specify superclass (superinterfaces? mixins?)
// - configuration
// - fields

// TODO(rnystrom): Make lazy.
class ExternalLibraryTransformer extends Transformer {
  ExternalLibraryTransformer.asPlugin();

  String get allowedExtensions => ".dart";

  Future apply(Transform transform) async {
    var source = await transform.primaryInput.readAsString();

    // TODO(rnystrom): Handle errors.
    var canonical = parseCompilationUnit(source,
        name: transform.primaryInput.id.toString());

    var externalUri = _parseExternalImports(canonical);

    // If the library doesn't have any external libraries, bail.
    if (externalUri == null) return;

    var externalUnit = await _readExternalLibrary(transform, externalUri);

    var canonicalUri = _pathToCanonical(transform.primaryInput.id, externalUri);
    var patcher = new Patcher(
        canonicalUri, canonical, externalUri, externalUnit);
    patcher.apply();

    _outputUnit(transform, canonical, transform.primaryInput.id);

    // Output the modified external library too.
    if (externalUnit != null) {
      var externalId = _uriToId(transform.primaryInput.id, externalUri);
      _outputUnit(transform, externalUnit, externalId);
    }
  }

  String _parseExternalImports(CompilationUnit unit) {
    if (unit.directives.isEmpty) return null;
    if (unit.directives.first is! LibraryDirective) return null;

    var libraryDirective = unit.directives.first as LibraryDirective;

    for (var comment = libraryDirective.beginToken.precedingComments;
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
    var externalId = _uriToId(transform.primaryInput.id, externalUri);
    var externalSource = await transform.readInputAsString(externalId);

    // TODO(rnystrom): Handle errors.
    return parseCompilationUnit(externalSource, name: externalUri);
  }

  /// Given the [canonicalId] and (likely relative) URI from it to the
  /// external library, returns a relative URI pointing back from the
  /// [externalUri] to the canonical one.
  String _pathToCanonical(AssetId canonicalId, String externalUri) {
    var relativeDir = p.url.relative(p.url.dirname(canonicalId.path),
        from: p.url.dirname(externalUri));

    return p.url.normalize(
        p.url.join(relativeDir, p.url.basename(canonicalId.path)));
  }

  /// Creates an AssetId from a [uri] relative to [base].
  AssetId _uriToId(AssetId base, String uri) {
    var canonicalDir = p.url.dirname(base.path);
    var externalPath = p.url.join(canonicalDir, uri);
    return new AssetId(base.package, externalPath);
  }

  /// Writes [unit] to an output with [id].
  void _outputUnit(Transform transform, CompilationUnit unit, AssetId id) {

    var writer = new PrintStringWriter();
    var toSourceVisitor = new ToSourceVisitorCopy(writer);
    unit.accept(toSourceVisitor);

    var output = writer.toString();
    output = new DartFormatter().format(output);

    transform.addOutput(new Asset.fromString(id, output));
  }
}
