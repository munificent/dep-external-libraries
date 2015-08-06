// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dep_external_libraries.src.patcher;

import 'package:analyzer/analyzer.dart';
import 'package:analyzer/src/generated/ast.dart';
import 'package:analyzer/src/generated/scanner.dart';

import 'ast.dart';

/// Takes a canonical library and an external library and merges the two
/// together.
///
/// Modifies the compiliation units for both libraries.
class Patcher {
  /// The URI to the canonical library from the external one.
  final String _canonicalUri;

  /// The parsed AST for the canonical library.
  final CompilationUnit _canonical;

  /// The URI to the external library from the canonical one.
  final String _externalUri;

  /// The parsed AST for the external library, if there is one.
  final CompilationUnit _external;

  /// The lazy-initialized map of class names to their declarations in the
  /// external library.
  Map<String, ClassDeclaration> _externalClasses;

  /// The set of classes in the canonical library that contain external members.
  final Set<ClassDeclaration> _patchedClasses = new Set();

  Patcher(
      this._canonicalUri, this._canonical, this._externalUri, this._external);

  void apply() {
    // Add an import from canonical -> external.
    _canonical.directives.add(
        Ast.directive("import '$_externalUri' as \$external;"));

    for (var declaration in _canonical.declarations) {
      if (declaration is FunctionDeclaration &&
          declaration.externalKeyword != null) {
        _patchFunction(declaration);
      } else if (declaration is ClassDeclaration) {
        // TODO(rnystrom): Require comment/annotation to indicate class is
        // patchable?
        for (var member in declaration.members) {
          // TODO(rnystrom): Constructors.
          // TODO(rnystrom): Static methods.

          if (member is MethodDeclaration && member.externalKeyword != null) {
            _patchMethod(declaration, member);
          }
        }
      }
    }

    if (_patchedClasses.isNotEmpty) {
      for (var name in _patchedClasses) {
        _patchClass(name);
      }
    }
  }

  /// Patches the top-level function [function] in the canonical library to
  /// forward to the external one.
  void _patchFunction(FunctionDeclaration function) {
    // It's not external anymore.
    function.externalKeyword = null;

    // Give it a body that forwards to the external function.
    function.functionExpression.body = _makeForwarder(
        "\$external.${function.name}", function.functionExpression.parameters);

    // TODO(rnystrom): Validate that external library has function.
    // TODO(rnystrom): Validate that signature matches.
  }

  /// Patches the [canonical] class with the external one.
  void _patchClass(ClassDeclaration canonical) {
    // TODO(rnystrom): Handle a missing external class.

    // TODO(rnystrom): Error if external class has superclass, mixins, or
    // superinterfaces.
    // TODO(rnystrom): Handle private classes.

    // Mixin the external class.
    if (canonical.withClause != null) {
      canonical.withClause.mixinTypes.add(
          Ast.typeName("\$external.${canonical.name}"));
    } else {
      if (canonical.extendsClause == null) {
        canonical.extendsClause = Ast.extendsClause("Object");
      }

      canonical.withClause = Ast.withClause("\$external.${canonical.name}");
    }
  }

  /// Patches the external [method] in [clas].
  void _patchMethod(ClassDeclaration clas, MethodDeclaration method) {
    // Just make it non-external (i.e. abstract). The external class will
    // override it.
    method.externalKeyword = null;

    // Make sure we know to wire up this class.
    _patchedClasses.add(clas);
  }

  FunctionBody _makeForwarder(String receiver, FormalParameterList parameters) {
    // Give it a body that forwards to the external function.
    var buffer = new StringBuffer();
    buffer.write(receiver);

    if (parameters != null) {
      buffer.write("(");

      for (var param in parameters.parameters) {
        if (param != parameters.parameters.first) {
          buffer.write(", ");
        }

        // TODO(rnystrom): Do we need to do anything with default values?

        if (param is DefaultFormalParameter &&
            param.kind == ParameterKind.NAMED) {
          buffer.write("${param.identifier.name}: ");
        }

        buffer.write(param.identifier.name);
      }

      buffer.write(")");
    }

    print(buffer);

    return Ast.exprBody(buffer.toString());
  }

  ClassDeclaration _findExternalClass(ClassDeclaration canonical) {
    if (_externalClasses == null) {
      _externalClasses = {};

      for (var declaration in _external.declarations) {
        if (declaration is ClassDeclaration) {
          _externalClasses[declaration.name.name] = declaration;
        }
      }
    }

    return _externalClasses[canonical.name.name];
  }
}
