// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dep_external_libraries.src.canonical_visitor;

import 'package:analyzer/analyzer.dart';
import 'package:analyzer/src/generated/ast.dart';

import 'ast.dart';

class CanonicalVisitor extends RecursiveAstVisitor {
  /// The URI of the external library for this canonical library, if the
  /// magic comment for one was found.
  final String externalUri;

  /// The parsed AST for the external library, if there is one.
  final CompilationUnit externalLibrary;

  CanonicalVisitor(this.externalUri, this.externalLibrary);

  void visitCompilationUnit(CompilationUnit unit) {
    super.visitCompilationUnit(unit);

    // Add an import for the external library.
    unit.directives.add(Ast.directive("import '$externalUri' as \$external;"));
  }

  void visitFunctionDeclaration(FunctionDeclaration node) {
    super.visitFunctionDeclaration(node);

    // TODO(rnystrom): Only do this for top-level functions.
    if (node.externalKeyword != null) {
      node.externalKeyword = null;

      var buffer = new StringBuffer();
      buffer.write("\$external.");
      buffer.write(node.name);
      buffer.write("(");

      for (var param in node.functionExpression.parameters.parameters) {
        if (param != node.functionExpression.parameters.parameters.first) {
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

      node.functionExpression.body = Ast.exprBody(buffer.toString());

      // TODO(rnystrom): Validate that external library has function.
      // TODO(rnystrom): Validate that signature matches.
    }
  }
}
